---
name: life-os
description: >-
  claude-life-os, a personal paperwork system on Gmail, Google Drive and a Supabase
  database: indexes documents and mail, tracks deadlines, contracts and payments, sends a
  daily brief. Use for installing or checking it ("set up life os", "life os doctor",
  "налаштуй life os"), for its scheduled night runs ("run the life-os email-intake /
  drive-file-intake / nightly-check / life-review workflow"), for processing mail or
  files on request ("check my mail", "process my files", "перевір пошту", "обробити
  файли"), for the monthly review ("monthly review", "what can I cancel", "місячний
  огляд"), and for any question about the person's own documents, bills, contracts,
  deadlines, notice periods, returns, taxes or the emergency binder ("when does my
  passport expire", "what does the lease say", "коли можу розірвати", "чи можу
  повернути", "wann kann ich kündigen"). Answer such questions from the index before
  searching Drive or Gmail by hand.
compatibility: Requires Supabase, Google Drive and Gmail connectors. Google Calendar recommended. Todoist and Craft optional.
metadata:
  version: v4.2
  product: claude-life-os
  schema_version: 0.6.0
---

# Life OS

One skill, six workflows. This file decides which workflow runs and holds the rules they
all share. Read the chosen workflow file completely before doing anything, and only that
one: they are long, and the others are not needed.

## Pick the workflow

| The person or the schedule says | Workflow | File |
|---|---|---|
| set up / install / "налаштуй life os"; life os doctor / is everything working; change language, country, task app, contacts | setup (modes install, doctor, reconfigure) | `workflows/setup.md` |
| run the email-intake workflow; check my mail; what came in | email-intake | `workflows/email-intake.md` |
| run the drive-file-intake workflow; process my files; a document attached in chat to be filed | drive-file-intake | `workflows/drive-file-intake.md` |
| run the nightly-check workflow; send me today's brief | nightly-check | `workflows/nightly-check.md` |
| run the life-review workflow; monthly review; import this bank statement; what can I cancel | life-review | `workflows/life-review.md` |
| any question about their own documents, mail, money, deadlines (read only) | context-lookup | `workflows/context-lookup.md` |

A question is always `context-lookup`, even if it mentions mail or files: it never writes.
When two fit ("check my mail and tell me what's due"), run the writing one, then answer.

## Rules every workflow follows

**Settings first.** Every run starts by reading `life_settings` (the keys each workflow
lists). Nothing personal is ever hard-coded: folders, time zone, language, country rules,
task targets all come from there.

**Installed or not.** `schema_version` is a key in `life_settings`, not a table. Decide
from the data, never from that key alone:

```sql
select (select value #>> '{}' from life_settings where key = 'schema_version') as schema_version,
       (select count(*) from documents) + (select count(*) from emails)
     + (select count(*) from deadlines) as indexed_rows;
```

- The query fails because the tables do not exist, or `indexed_rows = 0` and there is no
  `schema_version`: the database was never set up. Say so and offer the setup workflow.
- `indexed_rows > 0`: this is a live installation, whatever the version says. Never run
  install against it. A missing or older `schema_version` (older than `schema_version` in
  the metadata above) means an upgrade is due: run the workflow anyway, use the fallback
  each step names for an object that does not exist yet, and add one `errors` entry
  "schema <found> is older than <expected>: run life os doctor".

**Language.** Write briefs, tasks, reports and notes in `output_locale`; answer a person in
the language they wrote in. Read mail and documents in any language.

**Unattended runs.** The four night workflows usually run with nobody reading the chat.

1. Whatever you would have said in chat goes into the run's log row (`notes`).
2. A failure becomes a task, or with `task_provider = 'none'` an `errors` entry the daily
   brief surfaces. Never a sentence nobody reads.
3. Never assume "yesterday". A run starts where the last one stopped, so a run after
   missed nights covers all of them.

**Safety before writes.** A writing run takes `take_snapshot('<workflow> pre-run')`, then a
row in `run_locks` (zero rows back means another run holds it: stop). At the end it
releases the lock by expiring it, never by removing the row:

```sql
update run_locks set expires_at = now() - interval '1 second'
where skill_name = :skill and holder = :holder returning skill_name;
```

The next acquisition takes over any expired row. Every write that is not an intake upsert
starts with `select set_config('app.actor','skill',true);` in the same `execute_sql`, so
`corrections` and `settings_history` can tell the machine from a human. Intake upserts mark
themselves with `last_intake_at = clock_timestamp()` instead.

**Writes that pass the connector unattended.** The Supabase connector holds two kinds of
statement for a human to confirm: an UPDATE whose SET carries a sizeable payload, and any
statement that removes rows. At night nobody confirms: the call hangs 180 s and commits
nothing. So:

1. An UPDATE sets short values only: ids, statuses, dates, numbers, booleans, timestamps,
   one or two per statement, never prose. `status = 'expired', last_intake_at =
   clock_timestamp()` is fine; a 300-character description is not.
2. Anything bulky (a description, notes, evidence, extracted text) goes in as an INSERT:
   `insert ... on conflict (...) do update` on the row's natural key where the workflow
   has one (`documents.drive_file_id`, `emails.gmail_message_id`), otherwise one row per
   field in `skill_writebacks`, which applies it as the skill and refuses a missing target:
   ```sql
   insert into skill_writebacks (target_table, target_id, column_name, value, mode, run_ref)
   values ('deadlines', :id, 'notes', to_jsonb(:text::text), 'append', :holder)
   returning applied_at;
   ```
   Long document text goes through `text_ingest_chunks` (see drive-file-intake step 4).
3. Every write-back ends in `returning` something. Zero rows back, an exception or a
   timeout is an `errors` entry naming the row; never assume it landed.
4. Nothing removes rows in normal operation. A staging row whose Drive copy is gone is
   marked (`drive_trashed_at`) and leaves the sweep view; text chunks and expired lock rows
   simply stay and are reused. A migration must not contain a top-level DROP or row
   removal either: the connector holds it, and an unattended upgrade would stall. Before
   schema 0.6.0 `skill_writebacks` does not exist: fall back to the short UPDATE and put
   the bulky text in the run's `notes`.

**Tasks are created once.** Both intakes write to the task app and can overlap. Before
creating a task for a row, claim it with a short UPDATE that only succeeds while the row
has no task: `update deadlines set todoist_task_id = 'pending:' || :holder where id = :id
and todoist_task_id is null returning id`. Zero rows: someone else has it, skip. Then create
the task (its description carries the row id), then write the real id back. A row still
`pending:` from a crashed run: search the task app for the row id before creating anything.

**Rules before judgement.** `match_rules()` and `region_rules` come before reasoning.
`match_rules()` returns rules by `priority` ascending: the lowest number wins, so a
personal rule meant to override a pack rule needs a smaller number than the pack's (packs
use 50 and 60). A legal date is counted with `apply_term_rule()` (or
`contract_cancel_by()` / `contract_term_end()` for a contract's own term), never by hand.
A date the document states in words wins over any computation: store it with
`deadlines.date_basis = 'stated'`; a counted one gets `'derived'`. If the two disagree,
keep the stated one and say so in the deadline's notes.

**Never**: invent an amount, date, type or category (leave it null and flag it); delete a
document, email or deadline row; upload a file by regenerating its bytes; contact a
vendor or send mail to anyone but the owner; edit these files during a run; use `gws-*`
command-line skills (they do not work here; use the connectors).

## Files

```
SKILL.md                     this file
workflows/setup.md           install, doctor, reconfigure
workflows/email-intake.md    nightly mail intake
workflows/drive-file-intake.md  nightly document intake
workflows/nightly-check.md   nightly derivations, health check, daily brief
workflows/life-review.md     monthly review
workflows/context-lookup.md  read-only answers
assets/                      migrations, packs, Apps Script, docs (in the release zip;
                             in a repository clone they are at the repository root)
```
