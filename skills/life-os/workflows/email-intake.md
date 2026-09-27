# Email intake

Workflow `email-intake` v3.1 of the `life-os` skill: nightly mail intake. The shared rules in
`../SKILL.md` apply; this file adds what is specific to this workflow.

Write `v3.1` into `email_processing_runs.skill_version` on every run.

This job usually runs unattended, at night, with nobody reading the chat. Three rules
follow from that and are not optional.

1. Whatever you would have said in chat goes into `email_processing_runs.notes`.
2. A failure becomes a task (or, with no task provider, an `errors` entry that the daily
   brief surfaces). Never a sentence nobody reads.
3. Never assume "yesterday". The window starts at `max(run_at)`, so a run after three
   missed nights covers all three.

## Step 0: load settings, snapshot, lock

```sql
select key, value from life_settings
where key in ('timezone','output_locale','input_locales','region','owner_name',
              'owner_email','task_provider','task_targets','bridge_categories',
              'lang_hints','region_rules');
select * from take_snapshot('email-intake pre-run');

insert into run_locks (skill_name, expires_at, holder)
values ('email-intake', now() + interval '30 minutes', :holder)
on conflict (skill_name) do update set locked_at = now(),
  expires_at = excluded.expires_at, holder = excluded.holder
where run_locks.expires_at < now()
returning skill_name;
```

Zero rows from the lock means another run holds it. Stop. Delete the lock row at the end.
If `schema_version` is missing, the database was never set up: say so and point to the
setup workflow (`workflows/setup.md`).

Write the brief, tasks and notes in `output_locale`. Read mail in any language;
`lang_hints` (the language packs for `input_locales`: keywords, date and amount formats)
are hints, not filters.

## Step 1: open the run

```sql
select coalesce(max(run_at), now() - interval '2 days') from email_processing_runs;
select * from v_intake_watchdog where skill = 'email-intake';
```

The 2-day fallback is only for a brand-new, empty system. If the watchdog shows a gap,
say so in `notes`.

## Step 2: list candidates

Gmail `search_threads` with `after:YYYY/MM/DD -in:spam -in:trash`, window start rounded
down to the day. Re-reading part of the previous day is intentional: the upsert on
`gmail_message_id` makes it harmless, and it is the only way to catch mail that arrived
between the last run and midnight. Exclude drafts.

## Step 3: rules before judgement

For every thread, first:

```sql
select * from match_rules('email', :sender_email, :sender_name, :subject) limit 1;
```

A hit fixes category, entity, tags, action_needed and matter with no reasoning. That is
cheaper and gives the same answer every month. `set_category = 'none'` means "do not log
this at all" (that is how the system's own alerts and brief stay out). Increment `hits`,
set `last_hit_at`. Resolve the sender through `entity_aliases` (address or domain) into
`sender_entity_id`.

## Step 4: read and classify what is left

Skip pure automated noise (CI notifications, newsletters with no action or record value)
and record every skip as `{item, reason}` in `skipped`. When unsure, log as `other`.

For each kept thread, `get_thread` in `PLAIN_TEXT`, then pick exactly one category:

| category | What goes here |
|---|---|
| `purchases` | Receipts: what, where, when, how much |
| `orders_delivery` | Order confirmation and final delivery only. Tracking pings go to `skipped`. |
| `government` | Authorities: immigration office, tax office, city registry |
| `bank_finance` | Bank statements, advisor mail, investments |
| `bills_payments` | Bills: utilities, rent, insurance premiums, subscription invoices |
| `legal_notary` | Lawyer, notary, contracts, property paperwork |
| `work` | Employment-related mail |
| `health` | Appointments, health insurance |
| `travel` | Flights, hotels, bookings |
| `personal_social` | Friends and family |

Then:

- Extract only what is stated: `vendor`, `item`, `amount` + `currency`, `event_date`,
  `due_date`, and for travel and health a time of day if the message gives one.
- If the amount is only in the attached PDF, read the attachment read-only: `get_message`
  with `messageFormat: RAW` returns the whole MIME message. It is usually too big for the
  tool result and gets saved to a file, which is the correct path. Decode it in a
  subprocess, never pull the base64 into context:
  ```python
  import json, base64, email
  from email.header import decode_header, make_header
  d = json.load(open(spilled_tool_result_path))
  mime = base64.urlsafe_b64decode(d["raw"] + "=" * (-len(d["raw"]) % 4))
  for part in email.message_from_bytes(mime).walk():
      if part.get_filename():
          name = str(make_header(decode_header(part.get_filename())))
          open("/tmp/att/" + name, "wb").write(part.get_payload(decode=True))
  ```
  Then `pdftotext -layout`. Skip anything above ~25 MB.
- **Never upload attachments from this skill.** Set `has_attachments` and
  `attachment_names` correctly and leave `attachments_extracted = false`. The Apps Script
  bridge copies in-scope attachments to Drive within 15 minutes of this upsert, the
  document intake indexes them, and a trigger flips the flag. An upload through a tool
  call can silently corrupt the file.
- `action_needed = true` only if the person must actually do something. One-line
  `action_note`.
- Torn between two categories? Log `{item, field, chose, alternative, confidence}` in
  `decisions`. That is what the monthly review learns from.
- Upsert on `gmail_message_id` with `last_intake_at = clock_timestamp()` in the same
  statement (`clock_timestamp()`, not `now()`, or a double write looks like a human
  correction).

## Step 5: deadlines

Every `due_date` becomes a `deadlines` row, `source_kind = 'email'`, `source_id` = the
email row. `payment_due` for bills, `legal_response` for lawyers, notaries and
authorities. A response window from an authority is `hard = true` with lead ladder
`{30,14,7,3,1}` (`region_rules.term_rules` says which letters carry such windows and how
they are counted: count with `apply_term_rule(<rule>, <received date>, true)`, since an
email's receipt date is real, and set `rule_key` and `rule_version` on the deadline).
When the letter states its own deadline, the stated date wins and `rule_key` stays null. Bills are soft,
`{7,1}`. A direct-debit bill gets the record but no task: nothing can be done about it,
and the nightly job closes it three days after the due date.

## Step 6: tasks

For rows with `action_needed` and no `todoist_task_id`:

- `task_provider = 'todoist'`: create one task. Title `💌 [category] [vendor]: [action_note]`,
  due = `due_date` if any, project from `task_targets` (`default_project`, or a
  category-specific project if the setting maps one), label `task_targets.label`,
  description = `gmail_url` plus the Supabase row id. Write the id back, to the email row
  and to its deadline row if step 5 made one (`deadlines.todoist_task_id`, so completing
  the task closes the deadline), in one `execute_sql` that starts with
  `select set_config('app.actor','skill',true);`.
  Todoist's `deadlineDate` is premium-only: use `dueString` and put hard dates in the title.
- `task_provider = 'none'`: create nothing. The row stays `action_needed` and the daily
  brief lists it.

## Step 6b: calendar

`travel` and `health` rows with a concrete `event_date` and no `calendar_event_id` get a
Google Calendar event: title `[vendor]: [item]`, the stated time or an all-day event (never
a guessed time), location if given, `gmail_url` and row id in the description. Write the id
back with the same `app.actor` prefix. Other categories never get calendar events without
the person asking.

## Step 7: feeder check and run log

```sql
select reconcile_passive_deadlines();
select * from v_intake_watchdog where skill = 'attachment-bridge';
select * from v_attachment_backlog;
```

Bridge overdue, or a backlog row from an earlier run, is an `errors` entry naming the
message ids. Then one row in `email_processing_runs`: `skill_version`, `started_at`, the
counts, `category_counts`, and the `errors` / `skipped` / `decisions` arrays. `errors` is
`[]` only if nothing failed.

## Step 8: notes

Write the report into `notes`: scanned, logged per category, actions flagged, errors, any
run gap. If a human started this run, also answer in chat, short.

## Step 9: the daily brief is not delivered here

The brief goes out once a night from the `nightly-check` workflow, which runs after
both intakes, so it includes tonight's mail and tonight's documents. If the person ran
this workflow by hand and asks "what's new", answer from this run's notes; if they ask
for the brief itself, run step 3 of `workflows/nightly-check.md`.

## Step 10: failure task

If `errors` is not empty, create one task "⚠️ email-intake failed <date>" in the system
project with the details, unless an open one already exists. A week-long outage should
leave one task, not seven.

## Never

- Invent an amount, date or category. Leave it null.
- Upload attachments.
- Edit this file during a run.
- Use `gws-*` command-line skills. They do not work in the Claude sandbox; use the
  Gmail, Calendar and Drive connectors.

## Reference

`emails`: `gmail_message_id` (unique), `gmail_thread_id`, `gmail_url`, `subject`,
`sender_name`, `sender_email`, `received_at`, `category`, `summary`, `vendor`, `item`,
`amount`, `currency`, `event_date`, `due_date`, `action_needed`, `action_note`,
`has_attachments`, `attachment_names`, `attachments_extracted`, `todoist_task_id`,
`calendar_event_id`, `tags`, `content_excerpt` (~500 chars), `last_intake_at`.

```sql
insert into emails (gmail_message_id, gmail_thread_id, gmail_url, subject, sender_name,
  sender_email, received_at, category, summary, vendor, item, amount, currency,
  event_date, due_date, action_needed, action_note, has_attachments, attachment_names,
  tags, content_excerpt, last_intake_at)
values (..., clock_timestamp())
on conflict (gmail_message_id) do update set
  category = excluded.category, summary = excluded.summary, vendor = excluded.vendor,
  item = excluded.item, amount = excluded.amount, due_date = excluded.due_date,
  action_needed = excluded.action_needed, action_note = excluded.action_note,
  has_attachments = excluded.has_attachments, attachment_names = excluded.attachment_names,
  last_intake_at = clock_timestamp(), updated_at = now();

insert into email_processing_runs (skill_version, started_at, emails_scanned, emails_added,
  emails_updated, actions_flagged, category_counts, errors, skipped, decisions, notes)
values ('v3.1', :started_at, ..., :category_counts::jsonb, :errors::jsonb,
        :skipped::jsonb, :decisions::jsonb, :notes);
```
