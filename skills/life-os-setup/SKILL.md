---
name: life-os-setup
description: >-
  Installs, checks and reconfigures claude-life-os, the personal system that files
  documents from Gmail and Google Drive into a Supabase database and tracks deadlines,
  contracts and payments. Walks a non-technical person through every step in plain
  language: connectors, the Supabase project and its database, the Drive folders, the
  Google Apps Script bridge, optional Todoist and Craft, and the scheduled tasks. The
  same skill in doctor mode re-checks the whole system and says exactly what to fix.
  Use when the person says "set up life os", "install claude-life-os", "налаштуй life
  os", "richte Life OS ein", "life os doctor", "check my life os", "is everything
  working", "перевір систему", "change my language / country / task app", or when
  another claude-life-os skill reports that the database was never set up.
compatibility: Requires Supabase, Google Drive and Gmail connectors. Google Calendar recommended. Todoist and Craft optional.
metadata:
  version: v1.0
  product: claude-life-os
  schema_version: 0.2.0
---

# Life OS setup

Three modes. Pick from what the person said; if unclear, ask.

- **install**: first-time setup, or finishing one that stopped halfway.
- **doctor**: read-only health check with one concrete fix per problem.
- **reconfigure**: change language, country, task or notes app, folders, contacts.

## How to talk during setup

The person may never have used a database or a script editor. So:

- One step at a time. Each step ends with exactly one thing for them to do, or nothing.
- Say where to click and what to paste, with the exact text. No jargon without a
  half-sentence explanation ("Supabase, the database that stores the index").
- Speak the person's language from the first message. Once `output_locale` is chosen,
  use it.
- Never ask for, accept or repeat the Supabase **secret** key in chat. It goes only into
  Google Apps Script. If they paste it anyway: tell them to create a new secret key in
  Supabase and delete the pasted one, because chat history is not a safe place for it.
- Resume by checking reality, not memory. Before every step, run its check; if it is
  already done, say so in one line and move on. Running install twice must be harmless.

## Where the files are

The database migrations, the packs and the Apps Script ship in this skill's own folder:

```
assets/migrations/0001_tables.sql … 0006_pack_settings.sql
assets/seed/document_types.sql
assets/packs/lang/<locale>/{dossier,folders,keywords,formats}.json
assets/packs/region/<code>/{rules.json,classification_rules.sql}
assets/apps-script/Code.gs
assets/docs/troubleshooting.md
```

Find the folder with `find / -type d -path '*life-os-setup/assets' 2>/dev/null | head -1`.
If there is none (the skill was installed without assets), ask the person to download
the repository as a ZIP (on GitHub: the green "Code" button, then "Download ZIP") and
drop it into this chat. Unzip it in the sandbox and use `supabase/`, `packs/`,
`apps-script/` and `docs/` from there.

---

# Mode: install

## Step 1: connectors

Try one harmless call on each and report a single checklist:

| Connector | Check | Needed |
|---|---|---|
| Supabase | `list_organizations` | yes |
| Google Drive | `search_files` for one file | yes |
| Gmail | `search_threads` with `in:inbox`, one result | yes |
| Google Calendar | `list_calendars` | recommended (travel and appointments become events) |
| Todoist | `find-projects` | optional (tasks) |
| Craft | a read of the root | optional (monthly report) |

Missing a required one: "In Claude, open Settings → Connectors, find <name>, click
Connect and sign in. Then tell me 'done'." Stop until it works.

## Step 2: questions

Ask these in one message, with the defaults filled in so they can just say "yes":

1. Your name, as it should appear in reports.
2. The Gmail address this runs on. It must be the same Google account as Drive and the
   Apps Script (the bridge sends alerts to it).
3. Time zone. Default: the one Google Calendar reports (`list_calendars`, primary).
4. The language you want briefs, tasks and reports in (`output_locale`). Offer the stable
   packs `en`, `de`, `uk` first; others work with English fallbacks.
5. The languages your mail and documents arrive in (`input_locales`).
6. The country whose rules apply to your paperwork (`region`). Available: `de`. Anything
   else: the system still works, but deadlines are counted with generic ladders and the
   skills will ask about local rules instead of knowing them.
7. Task app: Todoist or none. Without one, the daily brief and review arrive by email.
8. Notes app for the monthly report: Craft or none (then a Google Doc).
9. Optional now, easy later: current address and old addresses still in use by some
   senders; people for the emergency binder (name, role, phone or email).

Read the available packs from `assets/packs/lang/*/pack.json` and
`assets/packs/region/*/pack.json` rather than from this list, in case newer ones ship.

## Step 3: the Supabase project

Check first: `list_projects`. If one is named `life-os` (or the person names one), look
inside with `list_tables` (schema `public`):

- has `life_settings` and `schema_version` is set: the database exists. Skip to step 5
  (or run the upgrade in doctor mode if the version is older than `0.2.0`).
- has other tables: it is not ours. Do not install into it. Create a new project.
- empty: use it.

Otherwise create one: `list_organizations`, then `create_project` named `life-os` in the
region closest to the person (for example `eu-central-1` for central Europe). The free
plan is enough. If the tool asks to confirm a cost, confirm the free plan's $0 only;
anything else goes to the person first. Wait until `get_project` reports
`ACTIVE_HEALTHY` (a minute or two; tell them it is working).

Tell them one fact now so it is not a surprise later: free Supabase projects pause
after a week without activity. The bridge talks to the database every 15 minutes,
which keeps it awake.

## Step 4: the database

Apply in this order with `apply_migration`, each named after its file without `.sql`:

```
0001_tables, 0002_functions, 0003_views, 0004_triggers_and_security,
0005_settings_and_localization, 0006_pack_settings
```

Then run `assets/seed/document_types.sql` with `execute_sql` (or as migration
`seed_document_types`), then `assets/packs/region/<region>/classification_rules.sql` if a
region pack was chosen. Stop at the first error, show it, and look for it in
`assets/docs/troubleshooting.md`. Never "fix" a migration by editing it on the fly.

Verify:

```sql
select value from life_settings where key = 'schema_version';            -- "0.2.0"
select count(*) from pg_tables where schemaname = 'public';              -- 34
select count(*) from pg_views  where schemaname = 'public';              -- 35
select count(*) from document_types;                                     -- 40
select jobname, schedule, active from cron.job;                          -- nightly-derivations
```

`get_advisors` (security) will list `rls_enabled_no_policy` for every table. That is the
design: row level security on, no policies, so the public API can read nothing. Say so
in one line if the person sees it in the dashboard. Do not add policies.

## Step 5: settings

Build the values from the answers and the packs, then write them in one `execute_sql`.
Use dollar quoting for JSON, because translations contain apostrophes:

```sql
insert into life_settings (key, value) values
  ('owner_name',        to_jsonb(:name::text)),
  ('owner_email',       to_jsonb(:email::text)),
  ('timezone',          to_jsonb(:tz::text)),
  ('output_locale',     to_jsonb(:out::text)),
  ('input_locales',     $j$[...]$j$::jsonb),
  ('region',            to_jsonb(:region::text)),          -- or 'null'::jsonb
  ('task_provider',     to_jsonb(:tasks::text)),           -- 'todoist' | 'none'
  ('notes_provider',    to_jsonb(:notes::text)),           -- 'craft' | 'none'
  ('dossier_labels',    $j${...}$j$::jsonb),
  ('lang_hints',        $j${...}$j$::jsonb),
  ('region_rules',      $j${...}$j$::jsonb),
  ('current_address',   to_jsonb(:address::text)),        -- or 'null'::jsonb
  ('former_address_patterns', $j$[...]$j$::jsonb),
  ('emergency_contacts',      $j$[...]$j$::jsonb),
  ('tax_year',          to_jsonb(extract(year from now())::int))
on conflict (key) do update set value = excluded.value, updated_at = now();
```

- `dossier_labels`: `packs/lang/<output_locale>/dossier.json` as is. English: `{}` (the
  built-in labels are English).
- `lang_hints`: for each input locale, `{"<locale>": {"keywords": <keywords.json>,
  "formats": <formats.json or omitted>}}`.
- `region_rules`: `packs/region/<region>/rules.json` as is, or `{}`.
- `former_address_patterns`: short, distinctive fragments (a street name and house
  number), never a whole address, so they match however a sender formats it.

Check: `select emergency_dossier();` should come back in the chosen language.

## Step 6: Drive folders

Names come from `packs/lang/<output_locale>/folders.json`, falling back per key to
`packs/lang/en/folders.json`. First search Drive for an existing root folder with that
name owned by the person; reuse it and its children if found, so a second run creates
nothing twice. Otherwise create, with `create_file` and mime type
`application/vnd.google-apps.folder`:

```
<root>/
  <inbox>          landing zone for the bridge and for files you drop in
  <emergency>      the emergency binder Google Doc lives here
  <backups>        monthly CSV exports
  <catch_all>      documents whose area has no folder yet
  <identity>  <finance>/<taxes>  <housing>  <insurance>  <work>
  <legal>  <health>  <vehicle>  <education>
```

Then:

```sql
update life_settings set value = jsonb_build_object(
  'inbox', :inbox_id, 'emergency', :emergency_id, 'backups', :backups_id,
  'catch_all', :catch_all_id), updated_at = now()
where key = 'drive_folders';

insert into drive_folder_areas (drive_folder_id, folder_path, area_name, para_category,
  document_domain_hint, is_filing_default, notes) values
  (:identity_id,  '<root>/<identity>',          '<identity>',  'area', 'identity',   true,  null),
  (:finance_id,   '<root>/<finance>',           '<finance>',   'area', 'finance',    true,  null),
  (:taxes_id,     '<root>/<finance>/<taxes>',   '<finance>',   'area', 'finance',    false, 'tax assessments, wage tax certificates, tax returns'),
  (:housing_id,   '<root>/<housing>',           '<housing>',   'area', 'property',   true,  null),
  (:insurance_id, '<root>/<insurance>',         '<insurance>', 'area', 'insurance',  true,  null),
  (:work_id,      '<root>/<work>',              '<work>',      'area', 'employment', true,  null),
  (:legal_id,     '<root>/<legal>',             '<legal>',     'area', 'legal',      true,  null),
  (:health_id,    '<root>/<health>',            '<health>',    'area', null,         true,  null),
  (:vehicle_id,   '<root>/<vehicle>',           '<vehicle>',   'area', 'vehicle',    true,  null),
  (:education_id, '<root>/<education>',         '<education>', 'area', 'education',  true,  null),
  (:catch_all_id, '<root>/<catch_all>',         '<catch_all>', 'resource', null,     true,  null)
on conflict (drive_folder_id) do nothing;
```

The inbox, emergency and backups folders are deliberately not in `drive_folder_areas`:
they are never a destination for a document.

Ask once: "Do you already keep documents in other Drive folders?" If yes, map each
existing folder with one more `drive_folder_areas` row (asking which area it is) instead
of moving anything. The intake indexes them where they are.

## Step 7: the Apps Script bridge

This is the part that runs inside the person's Google account every 15 minutes, without
Claude: it copies important attachments from Gmail into the Drive inbox, re-copies any
that go missing, emails them if a Claude job stops running, and rewrites the emergency
binder daily. It reads everything else from the database, so the code needs no editing.

Get the project URL with `get_project_url`. Then walk them through it, one message:

1. Open **script.google.com** (signed in as the Gmail address from step 2), click
   **New project**. Click "Untitled project" at the top and name it `Life OS bridge`.
2. Delete everything in the editor and paste the code below. Click the save icon.
   (Show `assets/apps-script/Code.gs` in one code block, unchanged.)
3. Click the gear icon **Project Settings** on the left. Scroll to **Script Properties**,
   click **Add script property** twice:
   - `SUPABASE_URL` = `<the project URL>`
   - `SUPABASE_SECRET_KEY` = the secret key. To get it: supabase.com → your project →
     **Project Settings** → **API Keys** → **Secret keys** → **Create new secret key**
     (name it `apps-script`), click copy. It starts with `sb_secret_`. Paste it only
     here, never into the chat.
   Click **Save script properties**.
4. Back in the editor (the `< >` icon), choose `install` in the function dropdown at the
   top and click **Run**. Google asks for permission: **Review permissions** → your
   account → if it says "Google hasn't verified this app", click **Advanced** → **Go to
   Life OS bridge (unsafe)**. It is your own script, running in your own account.
   Click **Allow**.
5. The log at the bottom says "Installed." Come back here and say "done".

Timezone of the script itself does not matter; it reads `timezone` from the database.

## Step 8: first heartbeat

```sql
select started_at, finished_at, errors, script_version
from bridge_runs order by started_at desc limit 1;
```

A row from the last few minutes with `finished_at` set, `errors = []` and
`script_version = 'bridge-3.0'` means the bridge works. Say so plainly.

No row at all: `install` did not reach the database. Ask what the log said. Common:

| Log says | Meaning | Fix |
|---|---|---|
| `Script Property SUPABASE_URL is missing` | property name or value missing | re-check step 7.3, names are case-sensitive |
| `That is the publishable key` | the wrong key was pasted | use the `sb_secret_…` key |
| `-> 401` | key revoked or from another project | create a new secret key in this project |
| `life_settings.drive_folders.inbox is empty` | step 6 did not finish | run step 6, then `install` again |
| `No item with the given ID could be found` | inbox folder id wrong or not owned by this account | check the Google account; re-run step 6 |

A row with errors: read them; `fatal:` lines block everything, others are per message.

## Step 9: Todoist and Craft (only if chosen)

Todoist: find or create a project `Life OS` (system project: briefs, reviews, failures)
and, if the person wants mail tasks separate, a second one; find or create the label
`mail`. Write the ids:

```sql
update life_settings set value = jsonb_build_object(
  'system_project', :system_id, 'default_project', :default_id, 'label', 'mail'),
  updated_at = now()
where key = 'task_targets';
```

Craft: find or create a folder `Life OS reports` and write its id into
`notes_targets.reports_folder`.

## Step 10: scheduled tasks

The Claude side does not start by itself. Ask the person to create three scheduled tasks
in Claude (Claude app → Scheduled tasks → New), with these exact prompts:

| When (their time zone) | Prompt |
|---|---|
| every day 02:00 | `Run email-intake.` |
| every day 03:00 | `Run drive-file-intake.` |
| monthly, first Sunday 10:00 | `Run life-review.` |

Email before Drive on purpose: the bridge needs the email intake's categories to know
which attachments to copy, and it has an hour to do so before the Drive intake runs.

Say honestly: scheduled tasks sometimes skip a night. That is why the database keeps a
watchdog and the bridge emails them when a job has not run within its window (36 hours
for email, 30 for Drive). A missed night is caught up by the next run, because each run
starts where the last one stopped.

## Step 11: first run and baseline

Offer to run `email-intake` now (it covers the last two days on an empty system) and
then `drive-file-intake`. Then record the installed versions:

```sql
insert into skill_revisions (skill_name, version, change_type, summary)
values ('life-os-setup', 'v1.0', 'baseline', 'installed'),
       ('email-intake', 'v3.0', 'baseline', 'installed by life-os-setup'),
       ('drive-file-intake', 'v3.0', 'baseline', 'installed by life-os-setup'),
       ('context-lookup', 'v2.0', 'baseline', 'installed by life-os-setup'),
       ('life-review', 'v2.0', 'baseline', 'installed by life-os-setup');
```

Finish with doctor mode, then a three-line summary: what runs when, where the emergency
binder is, and "ask me anything about your documents in any chat" (that is
`context-lookup`).

---

# Mode: doctor

Read-only. Run every check, then answer with one short table in `output_locale`:
check, status (ok / warning / problem), and for every non-ok row exactly one fix. Never
apply a fix without the person saying yes.

1. **Connectors**: the calls from install step 1.
2. **Schema version**: `select value from life_settings where key = 'schema_version';`
   Older than this skill's `schema_version`: an upgrade is available. `list_migrations`
   shows what is applied; the fix is to apply the missing files from `assets/migrations`
   in order (after a `take_snapshot('pre-upgrade')`).
3. **Settings complete**: `owner_email`, `timezone`, `output_locale`, and all four
   `drive_folders` set. Each folder id exists and is not trashed (`get_file_metadata`).
   `task_provider = 'todoist'` needs `task_targets.system_project` to exist in Todoist.
4. **Security**:
   ```sql
   select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;     -- empty
   select table_name, grantee, privilege_type from information_schema.role_table_grants
   where table_schema = 'public' and grantee in ('anon','authenticated');       -- empty
   select p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');  -- empty
   ```
   Plus `get_advisors` (security), ignoring `rls_enabled_no_policy`.
5. **Nightly database job**:
   ```sql
   select jobname, schedule, active from cron.job;
   select status, start_time from cron.job_run_details
   where jobid = (select jobid from cron.job where jobname = 'nightly-derivations')
   order by start_time desc limit 3;
   select ran_at, error from derivation_runs order by ran_at desc limit 3;
   ```
6. **Jobs running on time**: `select * from v_intake_watchdog;` Every `overdue` row is a
   problem; `runs_7d` well below `runs_7d_expected` is a warning even if the last run is
   recent (a job that runs every other night looks fine on `last_run`).
7. **Bridge**: `select started_at, errors, script_version from bridge_runs order by started_at desc limit 5;`
   Errors in the last runs, or a `script_version` other than `bridge-3.0`.
8. **Invariants**: `select invariant, severity, failing, meaning from v_system_invariants where failing > 0 order by severity;`
9. **Health numbers**: `select * from v_system_health;` Flag
   `hours_since_snapshot > 48`, `days_since_offsite_backup > 35`, `attachment_backlog > 0`,
   `text_coverage_pct < 80`, `recall_miss_pct_60d > 10`, `hard_deadlines_missed > 0`.

The fixes for recurring patterns are in `assets/docs/troubleshooting.md`; use the same
wording. Order the answer by severity: anything that can make a hard
deadline slip comes first.

---

# Mode: reconfigure

Each change is a settings write plus its side effects:

- **Output language**: rewrite `output_locale` and `dossier_labels`. Folder names do not
  change (renaming Drive folders is harmless, but ask first).
- **Input languages**: rewrite `input_locales` and `lang_hints`.
- **Country**: rewrite `region` and `region_rules`, run the new pack's
  `classification_rules.sql`. Old region rules stay (they are only rules); list them and
  offer to deactivate (`active = false`), never delete.
- **Task app**: switching to Todoist runs install step 9. Switching to none: set
  `task_provider = 'none'`; existing tasks stay in Todoist.
- **Addresses and emergency contacts**: update the setting, then
  `select emergency_dossier();` to show the result.
- **Bridge categories**: `bridge_categories` lists which email categories get their
  attachments copied. Adding `health` or `work` is common; say that it copies more files
  into Drive.

## Uninstalling

Nothing here deletes data. To stop everything: in the Apps Script run `uninstall`
(removes the trigger), delete the three Claude scheduled tasks, and pause the Supabase
project from its dashboard. Drive files and the database stay intact until the person
deletes them.
