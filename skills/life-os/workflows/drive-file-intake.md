# Drive file intake

Workflow `drive-file-intake` v3.1 of the `life-os` skill: nightly document intake. The shared rules in
`../SKILL.md` apply; this file adds what is specific to this workflow.

Write `v3.1` into `processing_runs.skill_version` on every run, so the monthly review can
attribute a change in a metric to a revision.

This job usually runs unattended at night. The same three rules as `email-intake` apply:
whatever you would say in chat goes into `processing_runs.notes`; a failure becomes a
task (or, with no task provider, an `errors` entry the daily brief surfaces); the window
starts at the last run, never at "yesterday".

## Why it works this way

Each rule below exists because the simpler version failed in real use.

- **Scan on `createdTime` as well as `modifiedTime`.** A file moved or re-uploaded keeps
  its old `modifiedTime` and gets a fresh `createdTime`. A `modifiedTime`-only scan
  missed a whole folder reorganisation, permanently.
- **Never upload a file by regenerating its bytes.** A PDF re-uploaded through a tool
  call as base64 came out silently corrupted. Attachments reach Drive through the Apps
  Script bridge, natively. The one exception (a file attached in chat) is hash-verified.
- **Deduplicate on the full text, not on an excerpt.** Two different contracts from the
  same provider shared their first 500 characters, so the excerpt fingerprint merged
  them. `body_fingerprint` covers the whole text.
- **Nothing closes itself unless something closes it.** Deadlines stayed open forever
  until closing became an explicit step here and a nightly database job.
- **Never clear the inbox folder by hand.** Files the bridge staged there may not be
  indexed yet. Only this skill moves them out, one by one, after indexing.

## Step 0: settings, snapshot, lock

```sql
select key, value from life_settings
where key in ('timezone','output_locale','input_locales','region','region_rules',
              'owner_name','task_provider','task_targets','drive_folders','lang_hints');
select * from take_snapshot('drive-file-intake pre-run');

insert into run_locks (skill_name, expires_at, holder)
values ('drive-file-intake', now() + interval '30 minutes', :holder)
on conflict (skill_name) do update set locked_at = now(),
  expires_at = excluded.expires_at, holder = excluded.holder
where run_locks.expires_at < now()
returning skill_name;
```

Zero rows from the lock: another run holds it, stop and say so. Delete the lock row at
the end. `pg_advisory_lock` does not work here: every MCP call is its own session.
If `schema_version` is missing, the database was never set up: point to the setup workflow.

`drive_folders` gives `inbox` (where the bridge and manual drops land), `catch_all`
(where a document goes when its area has no folder), `backups` and `emergency`. The
folder-to-area map is the `drive_folder_areas` table. Never hard-code a folder id.

## Step 1: open the run

```sql
select coalesce(max(run_at), now() - interval '7 days') from processing_runs;
```

That timestamp is the lower bound for "new". Record `capabilities` for the run row: the
views and functions this file relies on (`v_bridge_queue`, `v_duplicate_candidates`,
`v_overdue_deadlines`, `reconcile_passive_deadlines`, `v_sweepable_staging`,
`v_text_extraction_queue`), so one query shows which skill file was live.

## Step 1b: check the feeder before the scan

An empty scan means nothing unless the bridge is alive.

```sql
select * from v_intake_watchdog;              -- attachment-bridge overdue?
select * from v_attachment_backlog;           -- in-scope mail never bridged
select * from v_attachment_pending_index;     -- bridged, waiting for this run
```

`attachment-bridge` overdue, or a backlog row received more than 24 hours before
`email-intake` last ran, is an `errors` entry with the message ids. Every row of
`v_attachment_pending_index` must be indexed by this run (its file is in the inbox), so
its absence from the scan is itself an error.

## Step 2: list candidates

Drive `search_files` with `(modifiedTime > :watermark or createdTime > :watermark)`,
excluding folders and trashed items. Do not restrict to one folder unless the person
asked. Skip what is plainly not a document of the person's (code, shared files owned by
someone else, media libraries), and record every skip as `{item, reason}` in `skipped`.
A silent skip is invisible to the monthly review and can never be fixed.

## Step 3: rules before judgement

```sql
select * from match_rules('document', null, null, null, :file_name, :issuer) limit 1;
```

A hit gives type, entity and matter deterministically and guarantees the same file
classifies the same way next month. Increment `hits`, set `last_hit_at`. When you
classify something by hand that will clearly recur, propose a rule.

## Step 4: read and classify each candidate

A candidate belongs in `documents` if it is a formal document: contract, certificate,
invoice, identity or residence paper, policy, lease, official letter. Working files
(templates, comparison sheets, drafts) go in the same table with `kind = 'reference_file'`.

For each:

- **Metadata:** name, id, `webViewLink`, `mimeType`, `parentId`.
- **Text.** `read_file_content` (Drive runs OCR on scanned PDFs). Keep ~500 characters in
  `content_excerpt` and the full text in `document_texts` (`extraction_method =
  'drive_ocr'` when the PDF had no text layer, `'drive_text'` when it did,
  `extraction_status = 'done'`). On failure write `'failed'` with the error, never leave
  the row absent, so `v_text_extraction_queue` stays an honest backlog.
  `read_file_content` can return only `Page 1 … Page N` placeholders for large scans,
  with no error. That is a failure, not an empty document. Fallback: `download_file_content`
  (it spills to a file), decode in a subprocess, `pdftoppm -r 200 -png`, then `tesseract`
  with the languages of `input_locales` (install `tesseract-ocr-<lang>` first; the sandbox
  ships English only). Documents over ~60,000 characters are left `pending` and named in
  the notes: extraction costs about twice the length in tokens.
  Boilerplate repeated across documents (standard clause catalogues, generic terms) may
  be condensed. Anything specific to the person, the contract, the amounts or the dates
  is stored verbatim.
- **The file name is evidence too.** `Anna_passport.pdf` states `subject_person` and half
  the type before you open it. Content wins on conflict, but never leave a field null
  that the name plainly answers.
- **`issued_on`** is the date the document carries (decision date, invoice date, the date
  line of a letter). For `official_decision` and `tax_assessment` it is mandatory: it is
  the only input the objection deadline is derived from (`derive_deadlines()` nightly,
  `region_rules.term_rules` for how it is counted).
- **Type, issuer, description, expiry.** Read for meaning, not for a keyword list.
  `expiry_date` only if the text states one ("valid until", "gültig bis", "дійсний до",
  a policy or contract end).
- **Area, deterministically first.** Check `parentId` and its ancestors against
  `drive_folder_areas`. A hit sets `area_name` and `para_category` outright. Only when
  the file is not under a mapped folder, infer them.
- **Classify into the registry, never into a new string.**
  `select key, label, domain, expiry_expected, notice_period_expected, hints from document_types where active;`
  Pick exactly one `document_type_key`. Put the observed wording in `document_type` if it
  adds detail. `hints` break ties; they are not a regex. Nothing fits: leave the key
  null, set `needs_review`, and file an `improvement_proposals` row with
  `autonomy = 'ask'` proposing the type. Adding a type is a schema decision.
- **The registry decides whether a date is expected.** `expiry_expected` means a null
  `expiry_date` is a failed extraction. `notice_period_expected` means the real deadline
  is a cancellation date, not an expiry: those contracts renew silently and never appear
  in an expiry check, which is what `v_missing_notice_period` catches.
- **Resolve entities, do not write strings.** `select entity_id from entity_aliases where alias = lower(:value);`
  for `issuer_entity_id` and `subject_entity_id`. No alias: the string goes to
  `v_unresolved_entities` for the monthly review. Do not create entities mid-run for
  one-off correspondents.
- **Attach to a matter** with a `matter_links` row when the document belongs to a live
  one. `v_matter_overview` is only as good as this step.
- **Originals.** Record `physical_location` and `has_original` when known. Authorities
  and notaries ask for originals; an index that only knows the scan fails on that day.
- **Uncertain?** `needs_review = true` with a `review_reason`. Never guess a date or a
  type into the field.
- **Low-confidence calls** go into `decisions` as `{item, field, chose, alternative, confidence}`.
- **File it out of the inbox.** Only when `parentId` is `drive_folders.inbox`:
  ```sql
  select drive_folder_id, folder_path, document_domain_hint, is_filing_default
  from drive_folder_areas where area_name = :area_name
  order by is_filing_default desc;
  ```
  Prefer a non-default row when the document's type matches it more specifically (a tax
  assessment goes to the taxes folder, not its parent finance folder); otherwise take the
  default. A hit: `update_file` with that parent. No hit: move it to
  `drive_folders.catch_all`. Either way, store the new location. Never reorganise files
  that already live elsewhere: that is a separate, explicit task.

## Step 5: deduplicate after the text is stored

`drive_file_id` catches the same file seen twice. It does not catch the same paper
uploaded twice under different ids.

```sql
select * from v_duplicate_candidates where :id = any(document_ids);
```

It groups on `body_fingerprint` (full text) and falls back to the excerpt fingerprint
only for documents without text. On a hit: no second row. Set `duplicate_of` to the
canonical row, `status = 'to_archive'`, and carry over any field the canonical row lacks.
Never delete a duplicate; its `drive_file_id` must stay resolvable.

## Step 6: upsert

Insert or update on `drive_file_id` with `last_intake_at = clock_timestamp()` in the same
statement. That marks the write as the machine's; a later change without it moving is
logged by trigger to `corrections`, which is how the system learns what it got wrong.
`clock_timestamp()`, not `now()`: `now()` is transaction-stable, so a double write would
look like a human correction.

## Step 7: transition state

`select * from v_stale_status;` and set `status = 'expired'` on each (with
`last_intake_at = clock_timestamp()`). The view must be empty when the run ends,
otherwise "what is valid right now" returns expired papers.

## Step 8: deadlines, not just dates

Every dated obligation goes into `deadlines`, the one place the system answers "what is
coming up".

- Document expiry: `source_kind = 'document'`, `source_id` = the row,
  `deadline_type = 'document_expiry'`.
- `hard = true` where missing the date is legally irreversible: residence titles,
  objection windows, cancellation dates of auto-renewing contracts. Ladder
  `{90,60,30,14,7,1}`. Soft dates `{30,7}`. When `region_rules.term_rules` has a rule
  for the document type, count the date with `apply_term_rule(<rule>, <start date>)` (the
  database's own interpreter, so the skill and the nightly job never disagree), use the
  rule's `deadline_type`, `hard` and `lead_days`, put its `basis` in `notes`, and set
  `rule_key` and `rule_version` (`region_rules.version`). A deadline with a `rule_key` is
  recounted automatically when the rules change; one without is left alone.
  Objection deadlines for official decisions and tax assessments are not written here at
  all: set `issued_on` and the nightly `derive_deadlines()` makes them.
- For every document whose type has `notice_period_expected`, there must be a
  `notice_period` deadline with `hard = true`, dated at renewal minus the notice period.
  `select * from v_missing_notice_period;` at the end of every run.
- A source that becomes stale, `to_archive` or a duplicate gets its deadlines set to
  `cancelled` rather than left to fire.

## Step 8a: work the text queue, every run

Including a run whose scan found nothing. `select * from v_text_extraction_queue;` take up
to five `pending` rows under ~60,000 characters, highest-value types first, and record
the remaining depth in `processing_runs.text_queue_depth`. Never re-extract a `done` row
unless the Drive file changed.

## Step 8b: close what is finished

Passive direct debits, bank linking and legal-deadline derivation run in the database
every night. This step handles what needs the task provider.

```sql
select * from derivation_runs order by ran_at desc limit 1;   -- ran, no error
select * from v_overdue_deadlines;
```

`reconcile_rule = 'check_todoist'` (only with `task_provider = 'todoist'`): fetch the task;
completed means `status = 'done'` with the completion time appended to `notes`. An open
task is real overdue work. `escalate` rows more than 7 days overdue, and any open overdue
p1 task, go into the run notes by name, not as a count. Every write here starts with
`select set_config('app.actor','skill',true);`.

## Step 9: expiring and untasked

Documents with `status = 'current'`, `duplicate_of is null`, no task,
`expiry_date <= current_date + 30`, excluding `software_license` and documents linked from
an auto-renewing `recurring_payments` row (a billing-period end is not an expiry):

- `task_provider = 'todoist'`: one task, `⚠️ <type label> expires <date>: <name>`, due seven
  days before expiry, project from `task_targets` (`default_project`, or an area-specific
  project if the setting maps one), description = `drive_url` plus the row id. Write the
  id back to `documents.todoist_task_id`.
- `task_provider = 'none'`: create nothing. The deadline exists and the daily brief
  surfaces it on its ladder.

## Step 10: expired without a successor

An expired document where an application or renewal for the same `subject_person` and
type exists but no successor document does is a distinct alert: say it by name in the
notes and, with a task provider, as a task. It is the most expensive thing to miss.

## Step 11: bundles and recurring payments

- **Bundles.** A named set of papers for one event (a permit application, a tax filing,
  a loan). Requirements point at document types, so a bundle survives a renewal.
  `select * from v_bundle_summary;` `blocking > 0` on an open bundle with a near `due_on`
  is worth a task naming exactly what is missing. `v_bundle_status` tells MISSING from
  NOT CURRENT from TOO OLD; the last matters because authorities reject papers that are
  valid but older than their cutoff.
- **Recurring payments.** A document that turns out to be a standing obligation (policy,
  pension, loan, rent, subscription) gets a `recurring_payments` row with amount,
  period, `contract_end`, `notice_period_months`. Then `select * from v_renewal_watch;`
  every `deadline_recorded = false` is a contract that will renew itself unannounced:
  create the `notice_period` deadline and link it back.

## Step 12: log and report

One `processing_runs` row: `skill_version`, `started_at`, counts, `text_queue_depth`,
`capabilities`, and the `errors` / `skipped` / `decisions` arrays. `errors` is `[]` only if
nothing failed; an unreported failure is the one defect the review can never find. Report
into `notes`: scanned, added, updated, expiring flagged, errors. If a human started the
run, answer in chat too, short. If `errors` is not empty, one failure task
"⚠️ drive-file-intake failed <date>" in the system project, unless an open one exists.

## Weekly extras (Sunday run)

- **Off-site backup, first Sunday of the month.** Export `documents` and `deadlines` as
  CSV to `drive_folders.backups`, named `backup_YYYY-MM-DD_documents_deadlines.csv`, and
  log a `backups` row with `row_counts`. This is the only tier that survives losing the
  Supabase project (free projects have no point-in-time recovery). Emails are left out:
  Gmail can rebuild them. Monthly, not weekly: it is the one step that passes through
  context, so it is expensive.
- **Attachment staging audit.** The bridge copies, heals and sets flags; this is audit
  only. `v_attachment_backlog` should be empty and
  `select * from bridge_runs order by started_at desc limit 5;` should show recent runs
  without errors. Sweep only what `select * from v_sweepable_staging;` returns: trash the
  Drive copy, then delete the row. A delete trigger refuses any row that backs a document.
- **Recall sample.** Draw 20 random Drive files modified in the last month and assert
  each is in `documents` or named in a run's `skipped`. Log it in `recall_samples`. It is
  the one metric the skill cannot flatter.
- **Folder check.** List the folders under the Life OS root and diff against
  `drive_folder_areas`. A new folder not in the table: add a row, asking the person for
  `area_name` if it is not obvious.

## A document attached in chat

The file is already on disk in the chat's uploads folder, so reading it needs no Drive
round trip. Saving it into Drive means generating its bytes in a tool call, which is
exactly how the corrupted upload happened. Treat every upload as unverified:

1. Decide the destination as in step 4 (ask once if the area is unclear).
2. `sha256sum` the local file.
3. Upload with `create_file` and `base64Content` in the same turn you read it.
4. Download it back (`download_file_content`) and compare the hash. Mismatch: trash the
   Drive file and tell the person. Do not retry; a second attempt has the same risk.
5. Only once verified, run steps 3 to 8 for it using the local file for content.
6. Multi-megabyte scans: do not try. Ask the person to drag the file into the Drive
   inbox, and offer to index it the moment it lands.

## Never

- Invent an expiry date, an issue date or a type. Leave it null and set `needs_review`.
- Clear or bulk-move the inbox folder.
- Delete a `documents` row.
- Edit this file during a run. Changes go through `improvement_proposals` and are
  archived in `skill_revisions`.
- Use `gws-*` command-line skills. They do not work in the Claude sandbox; use the Drive
  and Supabase connectors.

## Reference

`document_types`: closed registry: `key`, `label`, `domain`, `expiry_expected`,
`notice_period_expected`, `hard_deadline`, `hints`. `document_type_aliases` maps old
free-text labels onto keys, and a trigger resolves them on write.

`drive_folder_areas`: `drive_folder_id` (PK), `folder_path`, `area_name`,
`para_category`, `document_domain_hint`, `is_filing_default`.

`documents`: `drive_file_id` (unique), `name`, `drive_url`, `mime_type`, `para_category`,
`area_name`, `document_type_key`, `document_type`, `issuer`, `issuer_entity_id`,
`subject_person`, `subject_entity_id`, `description`, `tags`, `issued_on`, `expiry_date`,
`status`, `kind`, `content_excerpt`, `body_fingerprint`, `duplicate_of`, `needs_review`,
`review_reason`, `physical_location`, `has_original`, `source_email_id`,
`todoist_task_id`, `last_intake_at`.

```sql
insert into documents (drive_file_id, name, drive_url, mime_type, para_category, area_name,
  document_type, document_type_key, issuer, subject_person, description, tags, issued_on,
  expiry_date, content_excerpt, needs_review, review_reason, kind, last_intake_at)
values (..., clock_timestamp())
on conflict (drive_file_id) do update set
  name = excluded.name, drive_url = excluded.drive_url, description = excluded.description,
  document_type = excluded.document_type, document_type_key = excluded.document_type_key,
  issuer = excluded.issuer,
  subject_person = coalesce(excluded.subject_person, documents.subject_person),
  issued_on = coalesce(excluded.issued_on, documents.issued_on),
  expiry_date = excluded.expiry_date, content_excerpt = excluded.content_excerpt,
  tags = excluded.tags, needs_review = excluded.needs_review,
  review_reason = excluded.review_reason,
  last_intake_at = clock_timestamp(), updated_at = now();

-- must all be empty at the end of a run
select * from v_stale_status;
select * from v_untyped_documents;
select * from v_missing_expiry;
select * from v_missing_notice_period;

insert into processing_runs (skill_version, started_at, files_scanned, files_added,
  files_updated, expiring_flagged, text_queue_depth, capabilities, errors, skipped,
  decisions, notes)
values ('v3.1', :started_at, ..., :capabilities::jsonb, :errors::jsonb, :skipped::jsonb,
        :decisions::jsonb, :notes);
```
