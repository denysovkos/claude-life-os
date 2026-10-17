# Integration tests

The unit tests in `tests/` check that the release is consistent, and `.github/workflows/ci.yml`
installs every migration on plain Postgres. These suites go further: they run each part
of Life OS against the real thing, or the closest thing that can run in CI.

| Suite | What runs | Against | When |
|---|---|---|---|
| 1. database | migrations, seed, packs, every check, every SQL statement the skill contains | Supabase's own Postgres image (17 and 15) behind PostgREST | every pull request |
| 2a. bridge | `apps-script/Code.gs` and `appsscript.json`, unchanged | an Apps Script runtime (`bridge/gas_runtime.js`) and the suite 1 stack | every pull request |
| 2b. google | the same files plus `gas-e2e/E2E.gs` | a real Google account and a real Supabase project | nightly, on demand; needs secrets |
| 3. agent | a scripted agent in Claude's place: one follows the workflows, one obeys an injected letter | fake Gmail, Drive, Calendar and Supabase connectors and the suite 1 stack | every pull request; no model |

```
tests/integration/run_all.sh                 suites 1, 2a and 3
tests/integration/db/run.sh                  suite 1 (SUPABASE_PG_TAG=15.19.0.004 for Postgres 15)
tests/integration/bridge/run.sh              suite 2a
tests/integration/gas-e2e/run.sh             suite 2b
tests/integration/agent/run.sh [scenario]    suite 3
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

## 3. A scripted agent in Claude's place

No model runs in these tests: a model is not deterministic, costs money and needs a
secret, and a test that fails for reasons unrelated to the code teaches people to ignore
it. What Life OS needs from its tests is two different guarantees, and neither needs the
model itself.

`agent/mcp_client.py` talks MCP over stdio to the fake connectors exactly as Claude Code
does. `agent/personas.py` has two agents:

- **compliant** runs a workflow the way its file says: settings, snapshot, lock, rules
  first (`match_rules`, the SENT label for the system's own mail), upserts, deadlines
  through `apply_term_rule`, chunked text through `ingest_assemble`, calendar events,
  the run log, the lock released by expiring it. Where the workflow asks for judgement
  (the category, whether a mail is suspicious, a stated due date) the answer comes from
  the scenario's `decisions`: the test fixes what a correct model decides and proves
  everything around that decision works. The Drive query is read out of
  `drive-file-intake.md`, so a wrong instruction fails the test.
- **compromised** is a model that obeys an injected letter: after the run's normal start
  (snapshot, lock) it tries to send, forward and share, to address mail to the attacker,
  to silence a sender, to write outside the write-back whitelist, to delete, truncate,
  drop and overwrite, to close every deadline and to change the owner address. Each
  attempt must be blocked by something that is not the model, or be listed as a known
  limit with the reason it is acceptable.

`agent/fakes/server.py` are the connectors: the claude.ai tool names and parameters, a
simulated Gmail, Drive and Calendar, and a Supabase connector that runs SQL on the stack
and holds what the real one holds for a human (row removal, drops, an UPDATE with a large
SET). With `routine_tools: closed` the fakes offer only what a routine configured as
setup step 10 offers, without Gmail's write tools or Drive sharing.

| Scenario | It proves |
|---|---|
| `email_intake` | rules before judgement; the system's own brief is skipped by self-only rule plus SENT label, a forged one is logged and the database alone refuses to silence it; a bill becomes a payment deadline; the tax notice's objection deadline is counted by the database; the IBAN is masked; the flight event has no guests; no statement the connector would hold |
| `drive_file_intake` | only owned files are listed; text goes in through md5-checked chunks; the MRZ is not stored and no raw chunk stays behind; the passport deadline is hard and carries its basis |
| `nightly_check` | the brief goes to the outbox, with one `briefings` row pointing at it |
| `context_lookup` | the answer comes from the index with no write at all |
| `compromised` | 11 attacks blocked: no send, forward or share tool; no recipient column; write-back whitelist; the connector holds deletes, truncates, drops, mass overwrites, snapshot removal. 3 known limits, each bounded: a silencing rule is forced to self-only by a trigger; closing deadlines is restorable from the pre-run snapshot; an owner address change is on record and moves no mail, because the bridge mails only its own account |

What this cannot prove is that a real model makes the right judgement, or resists an
injection. That is why the guarantees above are built so they hold even when it does not.

Each scenario was checked to fail when the behaviour it guards is removed (a wrong Drive
query in the workflow, `match_rules` ignoring self-only, an outbox recipient column, no
self-only trigger). Calls and reports land in `agent/.state/<scenario>/`.
