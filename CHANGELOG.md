# Changelog

## 4.9.0 (workflow release v3.7), 2026-10-21

Feature release. Schema 0.12.0, bridge-3.4, language packs with new labels. Upgrading is
additive: one table, two views, six functions, one setting, no row removed. After
uploading the zip, run `life os doctor` to apply 0021 and sync the language pack, then
paste the new `Code.gs` over the bridge (no new permission).

### Added
- **Every official letter explained, in your language.** Letters from authorities,
  notaries and insurers (`explain_letter_types`) get an explanation from the Drive intake
  at night: a one-line summary, what the letter says in plain words, what happens if
  nothing is done, the options with their dates, the date to act by and, for a letter
  that asks for an answer, a draft reply in the letter's language with a translation and
  its open `[[placeholders]]`. Objections are never drafted freehand: the explanation
  points at the reviewed objection template. A letter from an unknown sender that asks
  for credentials or money is flagged first. (0021, drive-file-intake step 8c)
- The bridge writes each explanation as an editable Google Doc next to the letter, and
  rewrites the same Doc when the explanation changes. Nothing sends it. (bridge-3.4)
- The daily brief has a `NEW LETTERS` section with the summary, the date and the link.
  A new letter alone is enough for a brief. (nightly-check)
- "What does this letter mean", "was will das Amt von mir", "draft a reply to the
  Finanzamt" in any chat: explained or re-drafted on the spot, placeholders filled with
  the person, the Doc rewritten. Questions about a letter are answered from its
  explanation. (letters, context-lookup)
- **Paper mail.** `docs/paper-mail.md`: scanning letters with the Google Drive app into the
  inbox, a scanning service such as Dropscan or Caya, sharing from any app, and filing a
  document attached in chat. A service that writes into its own Drive folder (Dropscan)
  is added as a scan inbox (`drive_folders.scan_inboxes`, setup reconfigure); its files
  are indexed and filed out like inbox files. (setup, drive-file-intake)
- A paper letter's deadline counts from the date printed on it, never from the scan
  date; a formally served letter (Zustellungsurkunde) is flagged so the person confirms
  the delivery date. (drive-file-intake)
- A document attached in chat is filed right away, and an authority letter explained in
  the same answer. Scans too large to pass through the chat get the inbox link and are
  indexed the moment the person says they are there. (drive-file-intake)
- Doctor: explanations the bridge has not written, and letters waiting for one;
  `scan_inboxes` folders must exist. (setup)

### Changed
- Setup merges `drive_folders` instead of replacing it, so a second run keeps
  `scan_inboxes`. (setup)

### Workflow versions
setup v1.9, email-intake v3.6, drive-file-intake v3.6, nightly-check v1.6,
context-lookup v2.7, life-review v2.6, letters v1.2.

## 4.8.0 (workflow release v3.6), 2026-10-21

Housekeeping release. Schema 0.11.0, bridge-3.3 (unchanged). Upgrading is additive: one
table, five columns, one view, one function, no row removed. After uploading the zip, run
`life os doctor` to apply 0020.

### Fixed
- **The system now closes the tasks it opened.** Every workflow knew how to create its
  task and none knew when to close it, so the system project filled up with a month of
  daily briefs, superseded reviews and failure notices of jobs that had long recovered.
  `v_tasks_to_close` lists every system task whose reason is gone: a brief of an earlier
  day, a review the next one replaced, a failure of a job that has run clean since, the
  task of a deadline that is done or cancelled, a letter sent or withdrawn, a mail that
  no longer needs action, a document replaced or found to be a duplicate, a proposal
  decided. The nightly check completes them every night (up to 50, oldest first) and
  records each with `mark_task_closed()`. (0020, nightly-check)
- **Old tasks are adopted.** Briefs already on record are registered by the migration.
  Briefs, reviews and failure tasks from earlier versions that the database never knew
  are recognised by title in the system project and closed the same way. Nothing else in
  that project is touched. (0020, nightly-check)
- **No more loose tasks.** Night runs created tasks outside the catalog for findings,
  folder questions and bundles. They now create only the six kinds in `docs/tasks.md`;
  a finding or question becomes an `improvement_proposals` row that the monthly review
  task carries, a bundle that is missing papers becomes a deadline on the brief's
  ladder. (SKILL.md, drive-file-intake, life-review)
- The monthly review carries last month's open decisions into its new task, since the
  old one is closed once the new one exists. (life-review)

### Added
- `system_tasks`: every brief, review and failure task the system opened, with when and
  why it was closed. `task_closed_at` on deadlines, emails, documents, letters and
  proposals. (0020)
- Doctor check 14: tasks waiting to be closed, and a numbered list of tasks in the system
  project the system cannot account for, for you to decide. (setup)

### Workflow versions
setup v1.8, email-intake v3.6, drive-file-intake v3.5, nightly-check v1.5,
context-lookup v2.6, life-review v2.6, letters v1.1.

## 4.7.0 (workflow release v3.5), 2026-10-21

Search release. Schema 0.10.0, bridge-3.3 (unchanged). Upgrading is additive: functions
only, no table, no data change. After uploading the zip, run `life os doctor` to apply
0019.

### Added
- **Search by meaning, in any language.** "What does the lease say about pets" now
  finds the clause on Tierhaltung. Claude turns the question into several terms
  (synonyms, the words a contract or authority would use, translations into the
  languages your papers are in), and `find_documents(terms)` ranks documents, mail and
  notes against all of them at once. Each hit comes with the terms it matched and the
  passage, so answers quote the clause and link the document. A word of five letters
  or more also finds its longer forms (Kündigung finds Kündigungsfrist); a stem ending
  in `*` finds inflected forms (догов* finds договір, договору). (0019, context-lookup)
- **Documents like this one.** `similar_documents(id)`: related papers by shared rare
  words, the same issuer, type and household member, each with its reasons. (0019)

### Not embeddings, on purpose
The only embedding model Supabase runs inside the project, gte-small, reads English
only and stops at 512 tokens, so German and Ukrainian papers would not be found by
meaning. Any other model means sending document text to an outside service, which this
system never does. The meaning comes from Claude instead, which reads every language,
and the ranking stays in your database.

### Workflow versions
setup v1.7, email-intake v3.5, drive-file-intake v3.4, nightly-check v1.4,
context-lookup v2.6, life-review v2.5, letters v1.0.

## 4.6.0 (workflow release v3.5), 2026-10-20

Letters release. Schema 0.9.0, bridge-3.3. Upgrading is additive: no deadline moves, no
row is removed, and a 4.5 skill keeps working against the new database. After uploading
the zip, run `life os doctor`: it applies 0018, writes the letter templates
(`letter_templates`) from the packs, offers the language and region pack updates, and asks
you to paste the new `Code.gs` into the Apps Script (only that file: no new permission).
Until the bridge is updated, letters are composed and shown in chat but not rendered.

### Added
- **Cancellation and objection letters.** Say "cancel the gym", "Kündigung für den
  Handyvertrag", "Widerspruch gegen den Bescheid" or "Einspruch einlegen" in any chat,
  and the new `letters` workflow writes the letter from the index: the holder (a
  household member, or you), the recipient and their address, the contract, customer or
  file number, the exit date, the date it must arrive, and the legal basis. What the
  index does not know is shown as `[[field]]` and asked for; values read from a document
  are proposals you confirm. You read the letter and say yes; within 15 minutes the PDF is
  in Drive next to the contract or decision and in your inbox, with how to send it and by
  when. You send it. Saying "I sent it", or completing its `✉️ Send by` task, closes the
  deadline it answers; a cancellation unconfirmed after three weeks is reported, and the
  email intake records a confirmation that comes from the recipient. (0018, letters v1.0,
  bridge-3.3)
- Germany (region pack de 1.3.0, `letters.json`): Kündigung with the right reference label
  and basis per contract type (§ 56 Abs. 3 TKG, § 11 VVG, § 573c BGB), Widerspruch
  (§ 70 VwGO for the form) and Einspruch (§ 347 AO), with delivery advice: Textform and
  § 312k BGB, Schriftform for a tenancy (§ 568 BGB), ELSTER and Aussetzung der Vollziehung
  (§ 361 AO) for tax. Every language pack has a generic cancellation (`letters.json`), so
  every other country gets a cancellation in its own language and no objection until its
  region pack has a reviewed one. A child's contract is signed by the owner as their
  representative.
- `compose_letter(kind, source, fields)`, `approve_letter()`, `mark_letter_sent()`,
  `mark_letter_confirmed()`, `withdraw_letter()`, `v_letters`, `v_letters_followup`. The
  person's values survive every recompose; composing a ready letter again replaces it; a
  sent letter is final. (0018)
- The brief marks each cancellation or objection deadline with its letter's state
  (`[letter ready, not sent]`) and reports letters to send within a week, letters the
  bridge did not render, and unconfirmed cancellations. The monthly review lists them and
  ends every cancel decision with how to get the letter. (0018, nightly-check, life-review)
- Doctor check 13: templates present and current, nothing stuck in rendering.
- Six language-pack labels for the note that comes with the PDF; language packs en, de,
  uk 1.3.0 and pl, fr, es, it, nl, ru, pt 1.2.0.

### Security
- Nothing sends a letter. The bridge renders an approved letter into the owner's Drive
  and mails it to its own account; `letters` has no e-mail, fax or recipient-mail column,
  and the bridge cannot read the table: it gets work from `letters_to_render()` and can
  only report a file through `letter_rendered()`. The bridge's key cannot compose,
  approve or mark a letter (Supabase grants new functions to `service_role` by default,
  so 0018 revokes them explicitly). A letter is composed and approved only in a chat, on
  the person's word; a night run may only mark one sent from its completed task. An
  address found only in a mail is shown with its source, never filled in silently.
  `release_checks.sql` asserts all of it.

### Development
- `tests/sql_letters_check.py`: the shipped templates rendered in Postgres (a German
  Kündigung, Widerspruch and Einspruch, the generic cancellation of all 10 languages)
  and a letter's whole life, 83 checks; in CI and the integration database suite. Its
  `letter_templates()` is the rule setup follows, and the integration installs use it.
- `tests/test_packs.py`: every placeholder in a template is a field `compose_letter()`
  fills, every required field is printed, every letter is signed, an objection letter
  answers a term rule of its key.
- Bridge suite: a letter becomes a PDF next to its document and reaches only the owner,
  falls back to the catch-all folder, and is retried three times, then reported.
- **The integration workflow ran nothing since 17 October.** An edit that replaced the
  Claude suite with the scripted agent cut `integration.yml` from `workflow_dispatch` to
  the agent's steps, so the file had no `jobs:` and GitHub failed every push before any
  test started (no pull request ran it at all). The database (Postgres 17 and 15),
  bridge, agent and real-Google jobs are back, and `tests/test_release.py` checks every
  workflow file still declares its jobs.

### Workflow versions
setup v1.7, email-intake v3.5, drive-file-intake v3.4, nightly-check v1.4,
context-lookup v2.5, life-review v2.5, letters v1.0.

## 4.5.0 (workflow release v3.4), 2026-10-20

Household release. Schema 0.8.0, bridge-3.2 (unchanged). Upgrading is additive: no
deadline moves, no row is removed, and a 4.4 skill keeps working against the new
database (it writes `subject_person` as before and the database links the member). After
uploading the zip, run `life os doctor`: it applies 0017, offers the language pack
update (seven new binder labels), and asks once whose papers besides yours the system
should handle.

### Added
- **Household members.** The partner's, the children's and a parent's papers are tracked
  as theirs. `household_members` holds the owner (`self`), partner, children, parents and
  others, with the other spellings their papers use (`aliases`) and an optional birth
  date. Members are only added or changed by the person, in setup or reconfigure
  ("add my son Max, born 2017-03-02"); a night run never does, and a letter naming
  someone never makes them a member. The upgrade creates the owner from `owner_name`.
  (0017, setup)
- `member_id` on documents, deadlines, contracts (`recurring_payments`), mail, matters
  and bundles. A trigger links it from the name already stored (`subject_person`,
  `owner_person`) when that name or an alias belongs to exactly one member; a joint
  paper or an unknown name stays unlinked rather than guessed. Deadlines take the member
  of their document or mail, contracts that of their document. An explicitly set member
  wins and the name follows it. (0017)
- `link_household_members(apply)`: rows written before a member or alias existed, as a
  dry run, then linked on the person's yes. `v_unassigned_people`: names in the index
  that match no member, for the doctor and the monthly review to ask about.
  `v_household_overview`: per member, current documents, identity papers and the next
  to expire, open and hard deadlines, monthly cost of their contracts. (0017)
- The daily brief names whose deadline or letter it is ("Passport renewal — in 14 days
  (Max)"); the owner's own items carry no name. Tasks for another member's document or
  mail end in ` (<name>)`. (0017, nightly-check, both intakes)
- The emergency binder lists the people in the household with relation and birth date,
  names whose hard deadline and whose insurance each line is, and groups identity papers
  by member. Language packs en, de, uk 1.2.0 and pl, fr, es, it, nl, ru, pt 1.1.0 carry
  the new labels; until a pack is updated those labels are English. (0017, packs)
- Answers by person: "Max's passport", "what does my wife have expiring", "the kids";
  "the whole family" uses the overview. (context-lookup)
- The monthly review reports each member's open deadlines, next identity expiry and
  contract costs, puts a child's passport expiring within six months on a line of its
  own, and asks about unknown names and spellings once. (life-review)
- Doctor check 12: an owner row exists, nothing is left to link, and unknown names are
  asked about. `release_checks.sql` asserts the household table is closed to every API
  role, the bridge's included, and that the member triggers exist;
  `feature_checks.sql` exercises aliases, inheritance, joint and ambiguous names,
  linking, the brief, the binder and snapshots.

### Changed
- A successor document counts for the same member however the name is spelled
  ("Maximilian Beispiel" renews "Max"'s passport). (0017, `v_expired_without_successor`)
- Snapshots include `household_members`. (0017)
- `tests/test_release.py` checks that the skill description stays within Claude's
  1024-character limit.

### Workflow versions
setup v1.6, email-intake v3.4, drive-file-intake v3.4, nightly-check v1.3,
context-lookup v2.4, life-review v2.4.

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
  real Google account (nightly, with secrets); and a scripted agent in Claude's place,
  talking MCP to fake Gmail, Drive, Calendar and Supabase connectors: one persona runs the
  workflows, a compromised one tries what an injected letter asks and must be stopped by
  something that is not the model. No model is called. They caught three defects before release:
  Supabase grants `service_role` everything on new tables, so the outbox revoke is now
  explicit; the Drive query the intake was told to use was not the connector's syntax; and
  a run talked into it could add a rule that silences any sender, so a trigger now forces
  every silencing rule to self-only.

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
