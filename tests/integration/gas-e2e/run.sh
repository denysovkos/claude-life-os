#!/usr/bin/env bash
# Suite 2, real half: the bridge in a real Google account against a real Supabase project.
#
# Pushes apps-script/Code.gs + appsscript.json (unchanged) + E2E.gs into a DEDICATED test
# Apps Script project with clasp, then runs lifeosE2E() through the Apps Script API.
# Passing means: the manifest's scopes are enough for everything the bridge does, Gmail is
# read-only for it, the fetch allowlist holds, and every step works on Google's servers.
#
# Never point this at your real installation. It refuses any database that does not carry
# the marker row `e2e_test_instance = true` (set by --bootstrap on an empty database).
#
# Required environment (see tests/integration/README.md for the one-time setup):
#   LIFEOS_E2E_SCRIPT_ID     id of the dedicated test Apps Script project
#   LIFEOS_E2E_DB_URL        Postgres connection string of a dedicated Supabase test project
#   CLASPRC_JSON or ~/.clasprc.json   clasp credentials from `clasp login --creds … --use-project-scopes`
# The test project's Script Properties must hold SUPABASE_URL and SUPABASE_SECRET_KEY of
# the same Supabase test project (set once by hand, never passed through here).
#
# Usage: tests/integration/gas-e2e/run.sh [--bootstrap]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../.." && pwd)"
: "${LIFEOS_E2E_SCRIPT_ID:?set LIFEOS_E2E_SCRIPT_ID}" "${LIFEOS_E2E_DB_URL:?set LIFEOS_E2E_DB_URL}"
db() { psql "$LIFEOS_E2E_DB_URL" -v ON_ERROR_STOP=1 -qtAX "$@"; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
clasp() { npx --yes @google/clasp@3.4.1 "$@"; }
if [ -n "${CLASPRC_JSON:-}" ]; then printf '%s' "$CLASPRC_JSON" > "$work/.clasprc.json"; export clasp_config_auth="$work/.clasprc.json"; fi

if [ "${1:-}" = "--bootstrap" ]; then
  n="$(db -c "select count(*) from pg_tables where schemaname = 'public'")"
  [ "$n" = "0" ] || { echo "refusing to bootstrap: the database already has $n tables"; exit 1; }
  for f in "$root"/supabase/migrations/*.sql "$root"/supabase/seed/*.sql "$root"/packs/region/de/classification_rules.sql; do
    db -f "$f" >/dev/null
  done
  python3 "$root/tests/integration/lib/configure.py" de | db >/dev/null
  db -c "insert into life_settings (key, value) values ('e2e_test_instance', 'true')" >/dev/null
  echo "bootstrapped"
fi

marker="$(db -c "select value::text from life_settings where key = 'e2e_test_instance'" 2>/dev/null || true)"
[ "$marker" = "true" ] || { echo "refusing: LIFEOS_E2E_DB_URL is not marked as a test instance (run with --bootstrap on an empty project)"; exit 1; }

echo "== upgrade the test database to this checkout (migrations are additive and rerunnable from 0005)"
for f in $(ls "$root"/supabase/migrations/*.sql | awk -F/ '$NF >= "0005"'); do db -f "$f" >/dev/null; done

echo "== push Code.gs, appsscript.json and E2E.gs to the test project"
mkdir -p "$work/src"
cp "$root/apps-script/Code.gs" "$root/apps-script/appsscript.json" "$here/E2E.gs" "$work/src/"
printf '{"scriptId":"%s","rootDir":"%s"}' "$LIFEOS_E2E_SCRIPT_ID" "$work/src" > "$work/.clasp.json"
(cd "$work" && clasp push --force)

echo "== test folders"
# clasp prints the function's return value; ours return one JSON object as a string
report_json() { python3 -c 'import json,re,sys; t=sys.stdin.read(); m=re.search(r"\{.*\}", t, re.S); m or sys.exit("no JSON in clasp output:\n" + t); print(m.group(0))'; }
setup="$(cd "$work" && clasp run-function lifeosE2ESetup | report_json)"
folders="$(printf '%s' "$setup" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["folders"]))')"
db -c "select set_config('app.actor','test',true); update life_settings set value = '$folders' where key = 'drive_folders'" >/dev/null

nonce="n$(date +%s)$RANDOM"
db -c "insert into outbox (kind, subject, body, source) values ('notice', 'e2e outbox $nonce', 'Life OS end-to-end test. Safe to delete.', 'e2e-$nonce')" >/dev/null

echo "== run lifeosE2E in Google"
out="$(cd "$work" && clasp run-function lifeosE2E --params "[\"$nonce\"]")"
printf '%s\n' "$out" > "$here/.last_report.txt"
python3 - "$out" <<'PY'
import json, re, sys
text = sys.argv[1]
m = re.search(r"\{.*\}", text, re.S)
if not m:
    print(text); sys.exit("no report from lifeosE2E (see the clasp output above)")
report = json.loads(m.group(0))
report = json.loads(report) if isinstance(report, str) else report
for c in report["checks"]:
    print(("PASS " if c["ok"] else "FAIL ") + c["name"] + ("" if c["ok"] else "\n     " + str(c["detail"])[:400]))
sys.exit(0 if report["ok"] else 1)
PY

echo "== database side"
test "$(db -c "select count(*) from outbox where source = 'e2e-$nonce' and sent_at is not null")" = "1"
test "$(db -c "select script_version from bridge_runs order by started_at desc limit 1")" = "bridge-3.2"
echo "suite 2 (real Google): PASS"
