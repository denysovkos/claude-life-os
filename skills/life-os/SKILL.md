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
  version: v4.0
  product: claude-life-os
  schema_version: 0.4.0
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
task targets all come from there. No `schema_version` row means the database was never
set up: say so and offer the setup workflow.

**Language.** Write briefs, tasks, reports and notes in `output_locale`; answer a person in
the language they wrote in. Read mail and documents in any language.

**Unattended runs.** The four night workflows usually run with nobody reading the chat.

1. Whatever you would have said in chat goes into the run's log row (`notes`).
2. A failure becomes a task, or with `task_provider = 'none'` an `errors` entry the daily
   brief surfaces. Never a sentence nobody reads.
3. Never assume "yesterday". A run starts where the last one stopped, so a run after
   missed nights covers all of them.

**Safety before writes.** A writing run takes `take_snapshot('<workflow> pre-run')`, then a
row in `run_locks` (zero rows back means another run holds it: stop), and deletes the
lock at the end. Every write that is not an intake upsert starts with
`select set_config('app.actor','skill',true);` in the same `execute_sql`, so
`corrections` and `settings_history` can tell the machine from a human.

**Rules before judgement.** `match_rules()` and `region_rules` come before reasoning; a
legal date is counted with `apply_term_rule()`, never by hand.

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
assets/                      migrations, packs, Apps Script, docs
```
