# Changelog

## 4.4.0 (workflow release v3.3), 2026-10-17

Security release. Schema 0.7.0, bridge-3.2. Upgrading is additive: no deadline moves, no
row is removed, and a 4.3 skill keeps working against the new database. After uploading
the zip, run `life os doctor`: it applies 0016, then asks you to paste the new `Code.gs`
and `appsscript.json` into the Apps Script and run `install` (Google asks for a new,
shorter permission list). Until the bridge is updated, a brief without a task app is
kept in the outbox, not lost.

### Fixed
- **Any sender could hide a letter.** The rules that keep the system's own mail out of
  the index matched on the subject alone, so a mail with "Daily brief" in its subject was
  silently dropped, whoever sent it. Silencing rules are now `self_only`: they match only
  mail from `owner_email`, and the email intake also requires Gmail's `SENT` label, which
  a forged From cannot add. (0016, email-intake)
- **Lookalike domains matched authority rules.** `sender_domain` matched any address
  ending in the domain, so `x@fake-elster.de` was filed as the tax office. It now matches
  the domain or its subdomains only. (0016)
- The instruction not to follow text inside a letter existed only in `docs/security.md`,
  which no workflow reads. It is now a shared rule in `SKILL.md`, with what a night run
  may never change. (SKILL.md)
- A test fixture used a real street name; it is now a placeholder.

### Changed
- **Claude never sends mail.** The brief, the monthly review and failure notices are
  rows in the new `outbox` table, which has no recipient column; the Apps Script bridge
  delivers them to the Google account it runs in. Gmail's send, draft and forward tools
  can (and should) be switched off for the night routines. (0016, bridge-3.2, all
  workflows, docs/scheduling.md)
- **The bridge can only read Gmail.** `appsscript.json` now declares its scopes
  (Gmail read-only, Drive, Docs, mail to self, triggers) and limits outgoing requests to
  `*.supabase.co`. `install` checks the read-only scope is enough and says what to change
  if it is not. All its own mail is prefixed `[Life OS]`. (bridge-3.2)
- The Drive intake indexes only files the person owns (`owner = 'me'`), so a file
  someone shares with them is never read at night. Documents already indexed stay.
- Calendar events are created without attendees; nothing is shared from Drive.
- Hard deadlines carry their basis (`basis: stated "…"` or `basis: <rule> from <date>`)
  in notes and task, so the one input a model chose is quick to check.
- Unattended runs never change settings, never add silencing rules or authority aliases;
  the address-audit ignore list changes only when the person confirms.
- CI runs with a read-only token.

### Added
- **Identifier redaction** (`redact_identifiers`, on by default): checksum-valid IBANs and
  card numbers keep only their last four characters, and passport and ID-card
  machine-readable lines are replaced, before document text and mail excerpts are
  stored. Files in Drive keep everything. `redact_stored_texts()` masks text stored
  earlier; the doctor offers it. Tax and social security numbers are not covered yet.
- Mail that tries to instruct the assistant is tagged `suspicious` and named in the
  daily brief; senders claiming an authority from an unknown domain are tagged
  `unverified_sender`.
- Doctor checks: silencing rules that are not `self_only`, mail stuck in the outbox,
  unredacted text, and whether the routines' connectors still offer send or share tools.
  `release_checks.sql` asserts the same on every upgrade.
- `docs/security.md`: an "Untrusted input" section listing what a letter could try and
  why it cannot, and advice to keep Life OS in its own Supabase organization.
- Integration tests (`tests/integration`, workflow `integration.yml`): the database on
  Supabase's own Postgres 17 and 15 images behind PostgREST, including every SQL statement
  the skill and docs contain and a probe of the HTTP API; the bridge, unchanged, in an
  Apps Script runtime that enforces the manifest's scopes and allowlist; the bridge in a
  real Google account (nightly, with secrets); and Claude running the skill headless
  against fake Gmail, Drive and Calendar connectors and the Supabase connector's
  confirmation holds (nightly, with an API key). They caught two defects before release:
  Supabase grants `service_role` everything on new tables, so the outbox revoke is now
  explicit, and the Drive query the intake was told to use was not the connector's syntax.

### Workflow versions
setup v1.5, email-intake v3.3, drive-file-intake v3.3, nightly-check v1.2,
context-lookup v2.3, life-review v2.3.

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
