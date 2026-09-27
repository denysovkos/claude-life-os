# Nightly check

Workflow `nightly-check` v1.0 of the `life-os` skill: the last run of the night. The
shared rules in `../SKILL.md` apply; this file adds what is specific to this workflow.

It runs after both intakes (typically 03:05, after email at 01:05 and Drive at 02:05), so
everything it reports includes tonight's mail and documents. It does three things:
brings the derived data up to date, checks the system, and delivers the one daily brief.
It does not read mail or files and does not change documents or emails.

## Step 0: settings and lock

```sql
select key, value from life_settings
where key in ('timezone','output_locale','region','owner_email','task_provider','task_targets');

insert into run_locks (skill_name, expires_at, holder)
values ('nightly-check', now() + interval '20 minutes', :holder)
on conflict (skill_name) do update set locked_at = now(),
  expires_at = excluded.expires_at, holder = excluded.holder
where run_locks.expires_at < now()
returning skill_name;
```

No snapshot: nothing here edits indexed data.

## Step 1: derivations

```sql
select run_nightly_derivations();
select ran_at, passive_closed, tx_linked, deadlines_derived, error
from derivation_runs order by ran_at desc limit 1;
```

The database also runs this on its own schedule (`pg_cron`); running it here again is
harmless (every part is idempotent) and makes sure deadlines from documents indexed an
hour ago exist before the brief is built. An `error` goes into step 2's findings.

## Step 2: health check

The read-only checks of setup's doctor mode, without the connector calls:

```sql
select invariant, severity, failing, meaning from v_system_invariants where failing > 0;
select skill, hours_since, sla_hours, overdue, runs_7d, runs_7d_expected from v_intake_watchdog;
select started_at, errors from bridge_runs order by started_at desc limit 3;
select jobname, active from cron.job where jobname = 'nightly-derivations';
select hours_since_snapshot, days_since_offsite_backup, attachment_backlog from v_system_health;
```

Keep a short list of findings, each one line in `output_locale` with what to do:
`high` invariants, overdue jobs, bridge errors in the last runs, an inactive or missing
cron job, a derivation error, a snapshot older than 48 hours, an off-site backup older
than 35 days. Name things ("the Drive intake has not run for 41 hours"), never a bare
count. Ignore `low` invariants here; the monthly review deals with them.

## Step 3: the daily brief

```sql
select (build_briefing()->>'item_count')::int as item_count, briefing_text() as text;
```

Add the findings from step 2 that the brief does not already mention under its
`SYSTEM` heading, then translate the whole text into `output_locale`, keeping dates,
amounts and names exactly as they are.

- **Nothing to say** (zero items and no findings): write a `briefings` row with
  `suppressed = true` and deliver nothing. No "all clear" messages: a brief that talks
  every day stops being read, and then it is ignored on the one day it matters.
- **Something to say**: with `task_provider = 'todoist'`, one task in
  `task_targets.system_project`, due today, titled
  `📅 Daily brief <date>: <the single most important fact>`, the text as its description.
  Without a task provider, an email to `owner_email` with the same subject. Keep the words
  `Daily brief` in English whatever the language: the rule that stops the system from
  filing its own brief as incoming mail matches on them.

Either way write exactly one `briefings` row for today (`briefings_date_uidx` keeps it at
one): `should_send`, `sent`, `suppressed`, `item_count`, `payload` = `build_briefing()`,
`channel`, and `todoist_task_id` or `gmail_message_id`. That row is also this workflow's
heartbeat: `v_intake_watchdog` watches it, and the Apps Script bridge emails the owner if
it is missing for 36 hours.

Deadlines speak only when today hits a rung of their own `lead_days` ladder;
`deadlines.snoozed_until` silences one without closing it.

## Step 4: finish

Delete the lock row. If this workflow itself failed before step 3 (for example the
database was unreachable), create one task `⚠️ nightly-check failed <date>` in the system
project, or send it by email without a task provider, unless an open one exists.

If a human started this run, show them the brief in chat as well.
