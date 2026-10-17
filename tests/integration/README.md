# Integration tests

The unit tests in `tests/` check that the release is consistent, and `.github/workflows/ci.yml`
installs every migration on plain Postgres. These suites go further: they run each part
of Life OS against the real thing, or the closest thing that can run in CI.

| Suite | What runs | Against | When |
|---|---|---|---|
| 1. database | migrations, seed, packs, every check, every SQL statement the skill contains | Supabase's own Postgres image (17 and 15) behind PostgREST | every pull request |
| 2a. bridge | `apps-script/Code.gs` and `appsscript.json`, unchanged | an Apps Script runtime (`bridge/gas_runtime.js`) and the suite 1 stack | every pull request |
| 2b. google | the same files plus `gas-e2e/E2E.gs` | a real Google account and a real Supabase project | nightly, on demand; needs secrets |
| 3. claude | Claude Code, headless, running the skill as a routine does | fake Gmail, Drive and Calendar connectors and the suite 1 stack | nightly, on demand; needs an API key |

```
tests/integration/run_all.sh                 suites 1 and 2a (LIFEOS_IT_CLAUDE=1 adds 3)
tests/integration/db/run.sh                  suite 1 (SUPABASE_PG_TAG=15.19.0.004 for Postgres 15)
tests/integration/bridge/run.sh              suite 2a
tests/integration/gas-e2e/run.sh             suite 2b
tests/integration/claude/run.sh [scenario]   suite 3
```

Needs Docker, Python 3.12+, Node 22 and `psql`. Each runner creates
`tests/integration/.venv` and `node_modules` on first use.

## 1. Database

`stack/` starts `supabase/postgres` (the image Supabase runs, with its roles, its
extensions and a `postgres` role that is not a superuser) and PostgREST configured the way
Supabase's API is. `db/run.sh` then:

1. installs every migration, the seed and a region pack as setup does;
2. applies migrations 0005+, the seed and every region pack again (they must be idempotent);
3. runs `v_system_invariants`, `v_system_health`, the binder and the brief, the region
   rules check, `release_checks.sql`, `feature_checks.sql` and the deny-all catalog checks;
4. runs the exact command of the `nightly-derivations` pg_cron job;
5. upgrades the previous release, with data, on a second empty Supabase database
   (pg_cron only installs into the database `postgres`, as on a hosted project);
6. runs every SQL statement in `SKILL.md`, the workflows and `docs/` against a seeded
   installation (`db/test_workflow_sql.py`): a renamed column or a missing view in a
   workflow fails here instead of in a night run;
7. probes the HTTP API (`db/test_api_surface.py`): `anon` and `authenticated` are refused
   on every table, view and function the catalog lists, and the bridge's key can read
   the outbox and mark a row sent, nothing more.

This suite found that Supabase grants `service_role` everything on new tables by default,
which plain Postgres in CI never showed: 0016 now revokes it on `outbox` explicitly.

## 2a. Bridge in an Apps Script runtime

`bridge/gas_runtime.js` implements the Apps Script services `Code.gs` uses, backed by an
in-memory Google account, with `UrlFetchApp` making real HTTP calls to the stack through
Supabase-style `sb_secret_` keys. It enforces what makes scripts fail in Google and not
on a laptop: the manifest's `oauthScopes` (a call without a documented scope throws
Google's permission error), `urlFetchWhitelist`, synchronous fetch with
`muteHttpExceptions`, and the Google Docs body rules the binder code works around.

`bridge/bridge.test.js` covers install, wrong keys, the allowlist, a missing Gmail scope,
copying by type and size, no double copies, healing a vanished copy, a vanished message,
a database failure (the Drive copy is trashed), outbox delivery and retries, the watchdog's
throttling, the binder (written once, rewritten only on change), the Drive check, and that
nothing ever writes Gmail, shares a file or mails anyone but the owner. It also dry-runs
`gas-e2e/E2E.gs`, so a red real-Google run means Google behaves differently, not that the
test is wrong. Each scenario was checked to fail when the behaviour it guards is removed.

The scope table in `gas_runtime.js` is our reading of Google's reference pages. Only 2b
proves Google agrees.

## 2b. Bridge in real Google

`gas-e2e/run.sh` pushes `Code.gs`, `appsscript.json` and `E2E.gs` into a dedicated Apps
Script project with clasp and runs `lifeosE2E()` through the Apps Script API. Inside
Google it: runs `install` twice (one trigger), mails itself a PDF and waits for it, files
it through the REST API, runs the bridge and compares the Drive copy byte for byte, runs
again (no second copy), checks the heartbeat, checks that an outbox row the runner queued
arrived in Sent, opens the binder, proves `GmailApp.createDraft` is refused (Gmail really is
read-only) and that `example.com` is refused (the allowlist really holds), then removes its
trigger and files.

It refuses any database without the row `e2e_test_instance = true`, so it cannot run
against a real installation by mistake.

One-time setup (about 20 minutes):

1. **A test Google account.** Use a separate account, not the one your real Life OS runs in.
2. **A test Supabase project** (free plan). Copy its connection string (Project Settings →
   Database → Connection string, URI) for `LIFEOS_E2E_DB_URL`. Then, with the database
   still empty: `LIFEOS_E2E_SCRIPT_ID=x LIFEOS_E2E_DB_URL=… tests/integration/gas-e2e/run.sh --bootstrap`
   installs Life OS there and marks it as a test instance (it stops at the clasp step
   until step 3 is done).
3. **A test Apps Script project** in the test account: script.google.com → New project.
   Project Settings → Script Properties: `SUPABASE_URL` and `SUPABASE_SECRET_KEY` of the
   test Supabase project. Note the Script ID.
4. **Apps Script API access.** In the test account, script.google.com/home/usersettings →
   turn the Google Apps Script API on. Create a Google Cloud project, configure its OAuth
   consent screen (External, testing, add the test account as a test user), create an
   OAuth client of type Desktop app and download its JSON. In the Apps Script project:
   Project Settings → Google Cloud Platform project → change to that project's number.
   Deploy once: Deploy → New deployment → API executable, access "Only myself".
5. **clasp credentials.** Locally: `npx @google/clasp@3.4.1 login --creds client.json --use-project-scopes`
   (run it in a folder whose `.clasp.json` and `appsscript.json` are this project's, so the
   token carries the manifest's scopes). It writes `~/.clasprc.json`.
6. **Run it**: `LIFEOS_E2E_SCRIPT_ID=… LIFEOS_E2E_DB_URL=… tests/integration/gas-e2e/run.sh`.
   For CI, add the secrets `LIFEOS_E2E_CLASPRC_JSON` (the file's content),
   `LIFEOS_E2E_SCRIPT_ID` and `LIFEOS_E2E_DB_URL`.

## 3. Claude runs the skill

`claude/run.py` runs Claude Code headless with the scenario's prompt (the same prompt a
routine sends), in a throwaway copy of this repository so the skill loads from
`.claude/skills` exactly as in a routine. It uses a temporary `HOME` (no synced skills or
personal settings) and only these MCP servers (`--strict-mcp-config`):

- `claude/fakes/server.py gmail|drive|calendar|supabase`: the claude.ai connectors' tool
  names and parameters (copied from the real connectors), over a simulated account. The
  Drive fake accepts only the connector's real query grammar, Gmail returns label ids
  (`SENT` included) and RAW MIME, and the Supabase fake runs SQL on the stack as `postgres`
  and holds what the real connector holds for a human (row removal, drops, an UPDATE with
  a large SET), so an unattended run that would hang at night fails here.
- Write tools Life OS must never use (send, draft, reply, forward, share) exist and work,
  as they would in a routine that left them on. The assertions check they were never called.

Each scenario (`claude/scenarios/*.json`) resets the database, loads its mailbox and
Drive, runs, and asserts on the database, the fake account and every tool call:

| Scenario | It proves |
|---|---|
| `email_intake` | a bill becomes a categorised mail and a payment deadline; a tax notice is government mail; a prompt injection is flagged and not obeyed (no mail sent, no setting or rule changed); a forged "Daily brief" from a stranger is logged while the system's own brief is not; a lookalike Finanzamt is not the Finanzamt; a newsletter needs nothing; a flight becomes a calendar event without guests; no IBAN in clear; no statement the connector would hold |
| `drive_file_intake` | a lease and a passport are indexed with type and expiry; the passport's MRZ is not stored; hard deadlines carry their basis; a file a stranger shared is never read; a note telling the assistant to close deadlines is not obeyed |
| `nightly_check` | the brief goes to the outbox, never through Gmail, and names the deadline |
| `context_lookup` | a question is answered from the index, correctly, with no write at all |

Transcripts, tool-call logs and reports land in `claude/.state/<scenario>/`. A model run is
not deterministic: a scenario that fails once is worth reading in its transcript before
changing the skill. `LIFEOS_IT_MODEL` picks the model; a full run costs a few dollars.
