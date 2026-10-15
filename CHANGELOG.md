# Changelog

## 4.3.0 (workflow release v3.2), 2026-10-15

No migration; schema stays 0.6.0. Upgrading is uploading the new zip: existing deadlines
do not move, and a pack only changes an installation when it is chosen in setup or
reconfigure.

### Added
- Language packs `pl`, `fr`, `es`, `it`, `nl`, `ru`, `pt` 1.0.0 are complete and stable:
  every binder label and folder name, keywords for all 10 categories, action, deadline
  and amount phrases, `formats.json` (dates, amounts, month names) and synthetic
  `examples.json` that pass `tests/test_packs.py`. Review by native speakers is welcome.
- Region packs (beta) `ch` Switzerland, `be` Belgium, `ie` Ireland and `ru` Russia, each
  with term rules, examples, annual tax dates or facts, and authority mail rules. Switzerland
  has no general online withdrawal right, so its pack has no `consumer_withdrawal` rule and
  `v_purchase_rights` reports the return window as unknown there.
- `DISCLAIMER.md`: Life OS is not legal, tax or financial advice, and the author and
  contributors accept no liability. It ships in the zip, every README has a "Not legal
  advice" section, setup says so before the first question, and answers about legal
  rights or deadlines say it once.

### Workflow versions
setup v1.4, email-intake v3.2, drive-file-intake v3.2, nightly-check v1.1,
context-lookup v2.2, life-review v2.2.

## 4.2.0 (workflow release v3.2), 2026-10-14

Schema 0.6.0. Upgrading from 4.1.x is additive: no open deadline moves, every view keeps
its columns, and a 4.1 skill keeps working against the new database until the new zip is
uploaded. `tests/upgrade_check.sh` proves it in CI on every push.

### Fixed
- **Deadline recount could move a hard deadline into the past.** `rederive_deadlines()`
  counted every rule from the document's issue date, whatever the rule's start was. A
  residence-permit "apply by" date (counted from expiry) would have been recounted from
  the card's issue date the first time a region pack was updated. It now uses the start
  the rule names, never moves a stated or manual date (`deadlines.date_basis`), and never
  moves a date of unknown origin later (`later_kept`). (0010)
- **Unattended writes no longer hang.** The Supabase connector holds large UPDATEs and any
  row removal for confirmation. Bulky text now goes in through `skill_writebacks`
  (INSERT, applied by trigger as the skill, refuses a missing row) or an upsert; locks are
  released by expiring them; nothing removes rows in normal operation (cleared staging
  rows are marked, text chunks are reused, `ingest_assemble()` reads only chunks 1..n).
  Every write-back ends in `returning`, and zero rows is an `errors` entry. No migration
  contains a top-level DROP or a row removal, so the doctor applies upgrades unattended;
  a test enforces it. (0011, SKILL.md)
- `v_system_health.text_coverage_pct` could exceed 100. (0015)
- Doctor reported `pg_trgm` extension functions as executable by anon. (setup)
- `ingest_assemble()` was executable by anyone holding the public key. (0010)
- A database with data but an older or missing `schema_version` is never sent to install
  again; the decision is made from the data. (SKILL.md, setup)

### Added
- Long document texts: md5-verified chunk upload (`text_ingest_chunks`,
  `ingest_assemble()`), page-level OCR for partly scanned PDFs, a hard cap that marks
  oversized files `skipped` with a human action, rules for what may never be condensed.
- Document types `authority_letter`, `insurance_correspondence`, `utility_notice`;
  `utility_contract` now expects a notice period; `document_types.successor_types` and
  `v_expired_without_successor` (a settlement permit succeeds a temporary one).
- `v_auto_renew_unwatched`: auto-renewing payments with no end, no notice period and no
  deadline, which no view reported before. `contract_cancel_by()`, `contract_term_end()`.
- `v_schedule_drift` with `life_settings.schedule_slots`: a night job that starts hours
  away from its slot is reported before it misses a night.
- Every snapshot includes `life_settings` (trigger on `backup_snapshots`).
- Emergency binder: overdue next actions say so, unknown persons are labelled, a document
  whose Drive file is gone is marked instead of linked. Bridge 3.1 rewrites the binder
  only when its content changed and checks daily that indexed Drive files still exist
  (`drive_check_batch()`, `mark_drive_check()`, `documents.drive_missing_since`).
- `v_unmapped_folders` and `documents.drive_parent_id`; `life_settings.area_aliases`.
- `v_address_audit` matches masked addresses; `v_purchase_rights` counts the withdrawal
  period from the delivery mail when there is one.
- Region pack de 1.2.0: telecom carrier mail rules. Language packs en/de/uk 1.1.0: new
  binder labels.
- Backups are due-based (any night when the last one is over 30 days old).
- Tasks are claimed before they are created, so overlapping intakes never create two.
- Claude Code routines are documented again, and the skill is linked at
  `.claude/skills/life-os` for routines that start from a clone.

### Development
- Tests: `tests/test_release.py` (VERSION, CHANGELOG, SKILL.md, workflow versions,
  migration lists, bridge version and packaging agree), `tests/sql/feature_checks.sql`
  (every new database feature end to end), `tests/sql/release_checks.sql`,
  `tests/upgrade_check.sh` (previous release with data, upgraded, nothing moves).
- CI runs on every pull request: unit tests, fresh install twice, rules, release and
  feature checks, the upgrade test, deny-all checks, a downloadable `life-os.zip`, and a
  guard that a change which ships raises `VERSION`.
- Releases: the tag is exactly `v<VERSION>`, published only when a merge to main brings a
  new `VERSION` and CI passed on that commit; the notes are this file's section. The patch
  number no longer counts up by itself (that is why 4.1.0 shipped as v4.1.5).

### Workflow versions
setup v1.3, email-intake v3.2, drive-file-intake v3.2, nightly-check v1.1,
context-lookup v2.2, life-review v2.2.
