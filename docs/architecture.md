# Architecture

claude-life-os keeps one person's paperwork, mail, deadlines, contracts and payments in
a single Postgres database, and uses Claude only where a rule cannot do the job.

## The one principle

A month of running the private version produced one lesson: anything that depends on
Claude acting as a scheduler or doing mechanical work is unreliable. Claude's scheduled
tasks skipped six nights in three weeks. A lock around the timer did not prevent two
runs from colliding. Deadlines never closed themselves, because closing them was a step
in a prompt and prompts get skipped.

So the work is split by what it needs:

| Work | Runs on | Why there |
|---|---|---|
| Copy attachments Gmail → Drive, re-copy lost ones | Google Apps Script, time trigger every 15 min | Runs inside Google whether Claude is up or not; moves files natively, so bytes never pass through a model |
| Alert when a Claude job has not run | Apps Script | The thing that failed cannot report its own failure |
| Rewrite the emergency binder | Apps Script daily, text built by `emergency_dossier()` | Must exist on the day Claude is unavailable |
| Close passive deadlines, link bank debits, derive objection deadlines | Supabase `pg_cron`, nightly | Pure SQL, deterministic, same answer every night |
| Classify mail and documents, read dates and amounts, decide what needs action | Claude skills | Judgement: the only part a rule cannot do |
| Answer questions about the index | Claude, `context-lookup` | Read-only, any chat |

**Supabase is the single source of truth.** Todoist, Craft, Google Calendar and the
emergency binder are projections. A task exists first as a row in `deadlines` (or an
`action_needed` email), and only then as a Todoist task whose id is written back. If
Todoist disappeared tomorrow, nothing would be lost; the daily brief would still list
every open obligation.

## Components

```
            Gmail ──────────────┐                        ┌──── Google Drive
              │                 │ attachments (native)   │     originals, Inbox,
              │ read            ▼                        │     emergency binder
              │         ┌────────────────┐   files       │
              │         │  Apps Script   │───────────────┤
              │         │  bridge-3.0    │               │
              │         └──────┬─────────┘               │
              │                │ REST (secret key)       │ read, file, move
              ▼                ▼                         ▼
     ┌────────────────┐  ┌────────────────────────────────────────┐
     │ email-intake   │  │              Supabase (Postgres)        │
     │ drive-file-    │─▶│  documents · emails · deadlines ·       │
     │   intake       │  │  recurring_payments · entities · …      │
     │ life-review    │  │  life_settings · views · pg_cron        │
     │ context-lookup │◀─│                                          │
     └──────┬─────────┘  └────────────────────────────────────────┘
            │ projections (ids written back)
            ▼
     Todoist · Craft · Google Calendar
```

### Apps Script bridge (`apps-script/Code.gs`)

Every 15 minutes, under a script lock:

1. **Queue.** `v_bridge_queue` lists mail that `email-intake` put into an in-scope
   category (`life_settings.bridge_categories`, default: legal, government, bank,
   bills) whose attachments were never copied. Each allowed attachment (PDF, images,
   Word, at most 25 MB) is copied into the Drive inbox and recorded in
   `attachment_staging`.
2. **Heal.** `v_bridge_heal` lists staged files not yet indexed. If the Drive copy is
   gone, it is copied again from Gmail. If Gmail no longer has it either, the row is
   resolved as `drive_file_missing` and reported.
3. **Watchdog.** `v_intake_watchdog` rows that are overdue produce at most one email per
   job per 12 hours.
4. **Emergency binder.** Once a day, `emergency_dossier()` is written into a Google Doc
   in the emergency folder.
5. **Heartbeat.** Every run writes a `bridge_runs` row; the watchdog treats the bridge
   as a job with a one-hour SLA.

Copying is idempotent on `(gmail_message_id, filename)` and fails closed: if the lookup
of what is already staged errors, nothing is copied. A Drive file is trashed again if
its database row cannot be written, so there is never a Drive copy the index does not
know about.

### Database (`supabase/migrations`)

35 tables, 35 views, about 35 functions, row level security on every table with no
policies.

The core objects:

- `documents` + `document_texts`: every formal paper, its type from the closed
  `document_types` registry, dates, status, full text, and `body_fingerprint` for
  deduplication.
- `emails`: one row per message, one of 10 categories, extracted facts, links to tasks
  and events.
- `deadlines`: every dated obligation, hard or soft, with its own reminder ladder
  (`lead_days`). The daily brief speaks about a deadline only on a rung of its ladder.
- `recurring_payments`: standing obligations with contract end and notice period, so an
  unwanted auto-renewal is visible before it happens (`v_renewal_watch`,
  `v_notice_calendar`).
- `entities` + `entity_aliases`: people, companies, authorities. Strings resolve to one
  entity deterministically.
- `matters`, `matter_links`: a thread of real life (a permit, a purchase, a dispute) that
  documents, emails and deadlines attach to.
- `bundles`, `bundle_requirements`: the papers one event needs, pointing at document
  types rather than files, so a bundle survives a renewal.
- `classification_rules`: deterministic rules applied before any judgement.
- `corrections`: every field a human changed after a skill wrote it (a trigger compares
  `last_intake_at`; skills mark their own non-intake writes with `app.actor = 'skill'`).
- `improvement_proposals`, `skill_revisions`: how the system changes itself, with a
  human deciding anything structural.
- `run_locks`, `backup_snapshots`, `backups`: coordination and recovery.
- `life_settings` + `settings_history`: all configuration, and every change to it. Nothing
  personal is hard-coded anywhere else. See [settings.md](settings.md).

Two views answer "is it working" in one query: `v_system_invariants` (named conditions
that must be zero) and `v_system_health` (the numbers).

### The skill (`skills/life-os/`)

One skill, `life-os`, installed as one zip. Its `SKILL.md` routes each request to one of
six workflows and holds the rules they share; each workflow is a file in `workflows/` that
Claude reads only when it runs that workflow.

| Workflow | When | Writes |
|---|---|---|
| `email-intake` | nightly 01:05 | `emails`, `deadlines`, tasks, calendar events |
| `drive-file-intake` | nightly 02:05 | `documents`, `document_texts`, `deadlines`, tasks, Drive filing |
| `nightly-check` | nightly 03:05 | derived deadlines, the one daily brief |
| `life-review` | monthly | bank imports, contract fixes, one report, one decision task |
| `context-lookup` | on demand, any chat | nothing |
| `setup` | once, then as doctor | the installation itself |

The same folder is linked at `.claude/skills/life-os`, so Claude Code and its cloud
routines load it from a clone of the repository. See [scheduling.md](scheduling.md).

Every writing workflow follows the same shape: load settings, `take_snapshot()`, take a row
in `run_locks`, work from the last run's timestamp (never "yesterday"), apply
`classification_rules` before judgement, log every skip and low-confidence decision,
write a run row whose `errors` is empty only when nothing failed.

### Packs (`packs/`)

Two independent axes. A language pack says how mail looks in a language and how the
system talks back. A region pack says what the paperwork means legally: which letters
start a deadline and how it is counted. The setup workflow copies the chosen packs into
`life_settings`, so the workflows never need the repository at run time. See
`packs/README.md`.

## A letter's path through the system

1. 14:02, an official decision arrives by email with a PDF.
2. 01:05, `email-intake` classifies it `government`, extracts the sender and the
   decision date if the mail states it, marks `action_needed`, creates a task.
3. 01:15, the bridge sees the row in `v_bridge_queue` and copies the PDF into the Drive
   inbox, recording it in `attachment_staging`.
4. 02:05, `drive-file-intake` finds the new file, reads its full text, classifies it
   `official_decision`, sets `issued_on`, links `source_email_id`, files it into the
   legal folder. A trigger flips `emails.attachments_extracted` and
   `attachment_staging.claimed`.
5. 03:05, `nightly-check` runs `derive_deadlines()` (the database's own `pg_cron` job runs
   it again at 01:15 UTC as a safety net): a hard `legal_response` deadline counted by the region pack's rule (in Germany: one month after the fourth day
   after posting, moved off a weekend), ladder `{30,14,7,3,1}`, `rule_key =
   objection_administrative`.
6. The same run builds the daily brief, so the deadline is in it that morning and again
   on each rung of its ladder. If a scheduled run does not fire for 36 hours, the bridge
   emails the person.

## Known gaps, stated rather than hidden

- Legal rules are data. `derive_deadlines()`, `v_purchase_rights` and `v_tax_items` read
  `life_settings.region_rules` (the region pack) through one interpreter,
  `apply_term_rule()`, which CI checks against the same examples as the Python pack
  tests. Every derived deadline records its `rule_key`, and `rederive_deadlines()`
  recounts open ones when the rules change (see [settings.md](settings.md)). Without a
  region pack, objection deadlines are an early 14-day placeholder and return windows are
  `unknown`. Public holidays are not modelled; weekends are.
- `briefing_text()` builds the brief in English. The skills deliver it unchanged.
- The Drive inbox can be emptied by hand, which removes files before they are indexed.
  The bridge heals them from Gmail, but a file dropped into the inbox manually has no
  second copy. See `troubleshooting.md`.
