#!/usr/bin/env bash
# Suite 1: the database on Supabase's own Postgres image, through PostgREST.
#
#   tests/integration/db/run.sh                      Postgres 17 (new projects)
#   SUPABASE_PG_TAG=15.19.0.004 tests/integration/db/run.sh     Postgres 15 (older projects)
#
# 1. fresh install as setup does it (`postgres` is not a superuser here, as on Supabase)
# 2. every migration from 0005 on, the seed and every region pack, applied again
# 3. invariants, health, binder and brief answer; region rules match the packs;
#    release and feature checks; deny-all in the catalog
# 4. the pg_cron job exists and its exact command runs
# 5. the upgrade test: the previous release with data, upgraded on this image
# 6. every SQL statement in the skill and docs runs (tests/integration/db/test_workflow_sql.py)
# 7. the HTTP API: anon and authenticated get nothing (tests/integration/db/test_api_surface.py)
set -euo pipefail
it="$(cd "$(dirname "$0")/.." && pwd)"; root="$(cd "$it/../.." && pwd)"; cd "$root"
py="$it/.venv/bin/python"; [ -x "$py" ] || { python3 -m venv "$it/.venv"; "$it/.venv/bin/pip" install -q -r "$it/requirements.txt"; }
step() { printf '\n== %s\n' "$*"; }

[ "${KEEP_STACK:-0}" = "1" ] || "$it/stack/down.sh" >/dev/null 2>&1 || true
step "1. fresh install on supabase/postgres:${SUPABASE_PG_TAG:-17.11.0.004}"
"$it/stack/up.sh"
source "$it/stack/env.sh"
run() { psql -v ON_ERROR_STOP=1 -q -f "$1" >/dev/null 2>"$it/stack/.last_error" || { echo "FAILED: $1"; grep -v NOTICE "$it/stack/.last_error" | tail -5; exit 1; }; }

step "2. migrations 0005+, seed and all region packs again (idempotent)"
for f in $(ls supabase/migrations/*.sql | awk -F/ '$NF >= "0005"') supabase/seed/*.sql packs/region/*/classification_rules.sql; do run "$f"; done
test "$(psql -tAc "select value #>> '{}' from life_settings where key = 'schema_version'")" = "$(sed -n 's/^  schema_version: //p' skills/life-os/SKILL.md)"

step "3. checks"
psql -v ON_ERROR_STOP=1 -q -c "select * from v_system_invariants" -c "select * from v_system_health" \
     -c "select emergency_dossier()" -c "select briefing_text()" >/dev/null
python3 tests/sql_rules_check.py >/dev/null
psql -v ON_ERROR_STOP=1 -q -f tests/sql/release_checks.sql 2>&1 | grep -q "release checks: all passed"
psql -v ON_ERROR_STOP=1 -q -f tests/sql/feature_checks.sql 2>&1 | grep -q "feature checks: all passed"
test "$(psql -tAc "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity")" = "0"
test "$(psql -tAc "select count(*) from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon','authenticated')")" = "0"
test "$(psql -tAc "select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('anon', p.oid, 'execute') and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')")" = "0"
echo "release, feature, rules and deny-all checks passed"

step "4. pg_cron"
cmd="$(psql -tAc "select command from cron.job where jobname = 'nightly-derivations' and active")"
[ -n "$cmd" ] || { echo "nightly-derivations is not scheduled"; exit 1; }
psql -v ON_ERROR_STOP=1 -q -c "$cmd" >/dev/null
test "$(psql -tAc "select count(*) from derivation_runs where error is null and ran_at > now() - interval '1 minute'")" -ge 1
echo "job command ran: $cmd"

step "5. upgrade from the previous release, on a second empty Supabase database"
up_port=$((PGPORT + 10))
docker rm -f lifeos-it-upgrade >/dev/null 2>&1 || true
docker run -d --name lifeos-it-upgrade -e POSTGRES_PASSWORD=postgres -p "$up_port:5432" \
  "supabase/postgres:${SUPABASE_PG_TAG:-17.11.0.004}" >/dev/null
for i in $(seq 1 90); do PGPORT=$up_port psql -tAc "select 1" >/dev/null 2>&1 && break; sleep 1; done
PGPORT=$up_port PGDATABASE=postgres UPG_DB=postgres UPG_EXISTING_DB=1 tests/upgrade_check.sh 2>&1 | grep -v NOTICE | tail -2
docker rm -f lifeos-it-upgrade >/dev/null

step "6. every SQL statement in the skill and docs"
psql -v ON_ERROR_STOP=1 -q -f "$it/lib/fixtures.sql" >/dev/null 2>&1
"$py" -m unittest "$it/db/test_workflow_sql.py" 2>&1 | tail -3

step "7. the HTTP API"
"$py" -m unittest "$it/db/test_api_surface.py" 2>&1 | tail -3

printf '\nsuite 1 (database): PASS on %s\n' "$(psql -tAc 'select version()' | cut -d' ' -f1-2)"
