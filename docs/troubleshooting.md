# Troubleshooting

Start with the doctor: in any Claude chat, say **"life os doctor"**. It runs every check
below and names the fix. This page explains the failures behind those checks. Each
section is written from a real incident in the private version of the system; names,
companies, amounts and dates are invented.

Two queries answer most questions:

```sql
select invariant, severity, failing, meaning from v_system_invariants where failing > 0;
select * from v_intake_watchdog;
```

---

## A nightly job did not run

**Symptom.** An email "email-intake has not run for 41h (SLA 36h)". Or the daily brief
shows `intake overdue: 1`.

**What happened in the original.** Claude's scheduled task skipped six nights in three
weeks. Nothing reported it, because the job that failed was the job that would have
reported. The first anyone noticed was a missing reminder.

**Why it is safe now.** Each run starts at `max(run_at)` of the previous run, not at
"yesterday", so the next run covers every missed night. The watchdog view knows each
job's SLA (email 36h, Drive 30h, bridge 1h), and the Apps Script bridge, which runs in
Google independently of Claude, emails you at most every 12 hours per job.

**Fix.** Open Claude and say "run email-intake" (or the named job). Then check the
routine (claude.ai/code/routines) or scheduled task still exists and is enabled, see
[scheduling.md](scheduling.md). A job that runs but less often than
expected shows as `runs_7d` below `runs_7d_expected` in `v_intake_watchdog`.

## Two runs at once

**Symptom.** Duplicate tasks for the same letter, or `run_locks` complaints in a run's
notes.

**What happened.** A manual "check my mail" started while the scheduled run was still
going. A lock around the timer did not help, because every MCP call is its own database
session, so advisory locks are released immediately.

**Now.** Each skill takes a row in `run_locks` with an expiry. A second run gets zero
rows back and stops. A crashed run's lock expires after 30 minutes (60 for the review).
If a lock is stuck and you are sure nothing is running:

```sql
delete from run_locks where skill_name = 'email-intake';
```

## Five copies of every attachment

**Symptom.** The Drive inbox holds `18c2f…_invoice.pdf` five times.

**What happened.** The first bridge checked "is this already copied?" and, when that
check itself failed (a timeout talking to the database), assumed "no" and copied. Under
load, every retry produced another copy: 5 copies of each attachment in one afternoon.

**Now.** The check fails closed: if the lookup errors, nothing is copied and the error is
reported. Copying is keyed on `(gmail_message_id, filename)`, unique in
`attachment_staging`. If the database write after a copy fails, the Drive copy is
trashed again, so Drive never holds a file the index does not know.

**Cleaning up old duplicates.** `drive-file-intake` links identical documents through
`v_duplicate_candidates` (`duplicate_of`, `status = 'to_archive'`). Nothing is deleted
automatically; you can trash `to_archive` copies in Drive yourself.

## Files vanished from the inbox before they were indexed

**Symptom.** `v_attachment_pending_index` lists files, but Drive does not have them. Or a
bridge error `Drive copy gone and Gmail original not found`.

**What happened.** Someone tidied the Drive inbox by hand, moving everything to the
trash, between the bridge's copy and the nightly Drive intake. Eleven letters were never
indexed.

**Now.** Every 15 minutes the bridge re-checks staged, unindexed files
(`v_bridge_heal`) and copies any missing one again from Gmail. If Gmail no longer has
it either (deleted mail), the staging row is resolved as `drive_file_missing` and the
error names it.

**Still open, by design.** A file you drop into the inbox yourself has no Gmail
original, so if you then delete it before the nightly run, it is gone. The rule is
simple: never empty the inbox by hand. The Drive intake moves every file out of it
after indexing; an empty inbox means everything was filed.

## A deadline never closed

**Symptom.** The brief keeps listing an electricity bill from three months ago as
overdue.

**What happened.** Closing deadlines was a step in a skill prompt. When the step was
skipped, or when there was nothing to close via a task (a direct debit needs no action),
deadlines stayed open forever and the brief became noise that nobody read.

**Now.** `pg_cron` runs `run_nightly_derivations()` at 01:15 UTC: passive `payment_due`
deadlines without a task close three days after the due date. Deadlines with a Todoist
task close when `drive-file-intake` sees the task completed. Everything else overdue is
escalated by name.

**Check the job.**

```sql
select jobname, schedule, active from cron.job;
select ran_at, passive_closed, tx_linked, deadlines_derived, error
from derivation_runs order by ran_at desc limit 5;
```

No `nightly-derivations` job: `pg_cron` was not enabled when migration 0005 ran. Enable
the extension in Supabase (Database → Extensions → pg_cron) and run
`select cron.schedule('nightly-derivations', '15 1 * * *', 'select public.run_nightly_derivations()');`

A deadline that is real but not urgent can be silenced without closing it:
`update deadlines set snoozed_until = '2026-11-01' where id = '…';`

## No objection deadline for a letter from an authority

**Symptom.** The brief says `nightly derivations failed`, or the doctor reports
`region_rules_missing`, and a new official decision has no deadline.

**Cause.** A region is set but its rules are not loaded. It is what an installation
upgraded from schema 0.2.0 looks like until "life os doctor" syncs the region pack. The
database refuses to count with no rules rather than count with the wrong law.

**Fix.** Say "life os doctor" and accept the region pack update. The next night derives
the missing deadlines. Documents without a date on them (`legal_decision_without_date`)
still need the date set; the monthly review does that.

## Deadlines look wrong after moving country or a pack update

Open deadlines keep the date they were counted with until you recount them. Say "I moved
to <country>" or "update the region pack" and the setup skill shows a dry run of what
moves before changing anything. See [settings.md](settings.md).

## Two different contracts merged into one

**Symptom.** Your phone contract shows the details of your internet contract with the
same provider, or a document is marked duplicate of something it is not.

**What happened.** Deduplication used an md5 of the first 500 characters. Two contracts
from one telecom provider, "Mobilfunk" and "Festnetz", started with the same two pages
of boilerplate, so they got the same fingerprint and one was linked as a duplicate of
the other.

**Now.** `body_fingerprint` is the md5 of the full extracted text, maintained by trigger,
and `v_duplicate_candidates` uses it. The excerpt fingerprint is only a fallback for
documents with no text yet.

**Fix an old wrong link.** `update documents set duplicate_of = null, status = 'current' where id = '…';`
The change is logged in `corrections` as yours, which is how the review learns.

## The system filed its own alerts

**Symptom.** The `other` category fills up with "attachment-bridge: 2 error(s)" and
daily briefs.

**What happened.** The bridge's alert mails and the daily brief arrived in the same
Gmail the intake reads, and were classified like any other mail, creating tasks about
tasks.

**Now.** Migration 0005 adds `classification_rules` with `set_category = 'none'` for
subjects containing `attachment-bridge:`, `has not run for` and `Daily brief`. The brief
keeps the English words "Daily brief" in its subject in every language for this reason.
If you renamed it, add a rule for the new subject.

## The secret key was in the code

**Symptom.** None, until someone you shared the script with used it.

**What happened.** The first bridge had the Supabase service key in a constant at the
top of `Code.gs`. Sharing the script to get help meant sharing full database access.

**Now.** The key lives only in Script Properties. See `security.md` for rotation.

## The bridge reports errors

| Error text | Cause | Fix |
|---|---|---|
| `Script Property SUPABASE_URL is missing` | property not set or misspelled | Apps Script → Project Settings → Script Properties |
| `That is the publishable key` | `sb_publishable_…` pasted | use the `sb_secret_…` key |
| `-> 401` | key revoked, or from another project | new secret key, update the property |
| `-> 404 … /rest/v1/v_bridge_queue` | migrations not applied, or wrong project URL | say "life os doctor" |
| `life_settings.drive_folders.inbox is empty` | setup did not finish the folders step | say "set up life os" again |
| `No item with the given ID could be found` | inbox folder deleted, or the script runs under another Google account | check the account; recreate the folder with setup |
| `message_not_found` in `bridge_messages.skipped` | the mail was deleted before the bridge ran | nothing to copy; the email row stays |
| `mime application/zip` in skipped | not an allowed file type | expected; open the mail yourself |
| `You do not have permission to call …` or `Required permissions: …` | a permission box was left unticked when authorising | run `install` again, tick **Select all**, see [apps-script.md](apps-script.md) |
| `Service invoked too many times` | Google's daily quota for Apps Script | transient; the next day catches up |

## A document is "untyped" or "missing expiry"

`v_untyped_documents`: the intake could not place a document in the 40-type registry.
Either it misread it (open it, and correct `document_type_key`; the correction is
logged) or the registry lacks a type, in which case an `improvement_proposals` row asks
you whether to add one.

`v_missing_expiry`: a document type that normally carries a validity date (passport,
residence permit) was indexed without one. Usually a bad scan. Fix the date by hand,
or replace the scan in Drive; the next run re-reads it.

## Supabase paused the project

Free projects pause after a week with no activity. The bridge's 15-minute heartbeat
counts as activity, so a pause means the bridge stopped too. Restore the project in the
Supabase dashboard, then check the Apps Script trigger exists (Apps Script → Triggers,
one time-driven trigger for `run`). Running `install` again recreates it.

## Starting over

Nothing is lost by running "set up life os" again: every step checks what exists first. To
rebuild the index from scratch, keep Drive and Gmail (they are the originals), create a
new Supabase project, run setup, and let the intakes run with a wide window. Documents
and mail are re-indexed; your manual corrections, notes and matters are not, so export
those first if they matter.
