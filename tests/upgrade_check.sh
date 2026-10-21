#!/usr/bin/env bash
# Upgrade test: an installation of the previous release, with data, upgraded to this one.
#
# 1. Builds a database from the BASE release (a git tag; default: the previous release): its migrations,
#    seed and the de region pack, and configures region de the way setup does.
# 2. Adds fixture data shaped like real installations: a residence permit whose "apply by"
#    deadline was set deliberately before the expiry date, a telecom contract with a
#    carrier-stated cancellation date, an official decision with a derived objection
#    deadline, an auto-renewing payment with no exit on record.
# 3. Applies this checkout's migrations, seed and packs, twice.
# 4. Asserts: no open deadline moved, the recount dry run moves nothing later or into the
#    past, schema_version is current, the owner became the household's `self` member and
#    linking the existing rows to it moves nothing, and tests/sql/release_checks.sql and
#    tests/sql/feature_checks.sql pass on the upgraded data.
#
# Needs git with the BASE tag fetched and a Postgres reachable through the PG* variables
# (CI: the service container). Creates and drops the database $UPG_DB (KEEP_DB=1 keeps it).
# UPG_EXISTING_DB=1 uses $UPG_DB as it is and leaves it: for Supabase's image, where
# pg_cron only installs into the database `postgres` (tests/integration/db/run.sh).
#
# Usage: tests/upgrade_check.sh [base-tag]      e.g. tests/upgrade_check.sh v4.1.5
set -euo pipefail
cd "$(dirname "$0")/.."

# default: the newest release tag that is not this checkout's own version
BASE="${1:-$(git tag -l 'v*' --sort=-v:refname | grep -vx "v$(tr -d '[:space:]' < VERSION)" | head -1)}"
[ -n "$BASE" ] || { echo "no previous release tag found (fetch tags: git fetch --tags)"; exit 1; }
DB="${UPG_DB:-lifeos_upgrade_check}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

[ -n "${UPG_EXISTING_DB:-}" ] || psql -v ON_ERROR_STOP=1 -qd postgres -c "drop database if exists $DB" -c "create database $DB"
export PGDATABASE="$DB"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;
SQL

run() { psql -v ON_ERROR_STOP=1 -q -f "$1" >/dev/null; }

echo "== base $BASE"
git archive "$BASE" supabase packs | tar -x -C "$work"
for f in "$work"/supabase/migrations/*.sql "$work"/supabase/seed/*.sql "$work"/packs/region/de/classification_rules.sql; do
  run "$f"
done

python3 - "$work/packs/region/de" > "$work/settings.sql" <<'PY'
import json, pathlib, sys
pack = pathlib.Path(sys.argv[1])
rules = json.loads((pack / "rules.json").read_text(encoding="utf-8"))
meta = json.loads((pack / "pack.json").read_text(encoding="utf-8"))
rules["region"], rules["version"] = meta["region"], meta["version"]
lit = "'" + json.dumps(rules, ensure_ascii=False).replace("'", "''") + "'"
print("select set_config('app.actor','setup',true);")
print("update life_settings set value = '\"de\"' where key = 'region';")
print("update life_settings set value = '\"Europe/Berlin\"' where key = 'timezone';")
print("update life_settings set value = '\"Person A\"' where key = 'owner_name';")
print(f"update life_settings set value = {lit}::jsonb where key = 'region_rules';")
PY
run "$work/settings.sql"

echo "== fixture data"
psql -v ON_ERROR_STOP=1 -q <<'SQL'
select set_config('app.actor','test',true);
-- residence permit: card expires 2027-08-16, the title 2027-08-31; the deadline was set to the card date
-- (issued_on is what the 4.1 recount wrongly counted from: it would move this into the past)
insert into documents (id, drive_file_id, name, drive_url, document_type_key, subject_person, issued_on, expiry_date, status, last_intake_at)
values ('00000000-0000-0000-0000-0000000000a1', 'fx-permit', 'eAT.pdf', 'https://example.invalid/a1',
        'residence_permit_temporary', 'Person A', '2025-09-01', '2027-08-31', 'current', clock_timestamp());
insert into deadlines (id, title, deadline_type, due_on, hard, source_kind, source_id, status, rule_key, rule_version)
values ('00000000-0000-0000-0000-0000000000d1', 'Apply by (card date)', 'document_expiry', '2027-08-16', true,
        'document', '00000000-0000-0000-0000-0000000000a1', 'open', 'residence_permit_apply_by', '1.1.0');
-- telecom contract with a carrier-stated cancellation date
insert into documents (id, drive_file_id, name, drive_url, document_type_key, status, last_intake_at)
values ('00000000-0000-0000-0000-0000000000a2', 'fx-telecom', 'Auftragsbestaetigung.pdf', 'https://example.invalid/a2',
        'telecom_contract', 'current', clock_timestamp());
insert into deadlines (id, title, deadline_type, due_on, hard, source_kind, source_id, status, rule_key, rule_version)
values ('00000000-0000-0000-0000-0000000000d2', 'Kuendigen bis', 'notice_period', '2028-07-23', false,
        'document', '00000000-0000-0000-0000-0000000000a2', 'open', 'telecom_cancel_by', '1.1.0');
insert into recurring_payments (name, category, amount, period, contract_start, auto_renews, status, document_id, deadline_id)
values ('Mobile', 'telecom', 20, 'monthly', '2026-08-24', true, 'active',
        '00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000d2');
-- official decision with its derived objection deadline
insert into documents (id, drive_file_id, name, drive_url, document_type_key, issued_on, status, last_intake_at)
values ('00000000-0000-0000-0000-0000000000a3', 'fx-decision', 'Bescheid.pdf', 'https://example.invalid/a3',
        'official_decision', current_date - 5, 'current', clock_timestamp());
select derive_deadlines();
-- an auto-renewing payment nobody recorded an exit for
insert into recurring_payments (name, category, amount, period, auto_renews, status)
values ('Gym', 'subscription', 30, 'monthly', true, 'active');
SQL

psql -tAc "select id, due_on from deadlines where status = 'open' order by id" > "$work/before.txt"

echo "== upgrade to this checkout, twice"
for pass in 1 2; do
  for f in supabase/migrations/*.sql; do
    n="$(basename "$f" | cut -c1-4)"
    if [ "$pass" = 1 ] && git cat-file -e "$BASE:$f" 2>/dev/null; then continue; fi   # already in base
    if [ "$pass" = 2 ] && [ "$n" \< "0005" ]; then continue; fi                         # 0001-0004 are not re-runnable by design
    run "$f"
  done
  for f in supabase/seed/*.sql packs/region/*/classification_rules.sql; do run "$f"; done
done

echo "== assertions"
psql -tAc "select id, due_on from deadlines where status = 'open' order by id" > "$work/after.txt"
if ! diff -u "$work/before.txt" "$work/after.txt"; then echo "FAIL: the upgrade moved open deadlines"; exit 1; fi

moved="$(psql -tAc "select count(*) from rederive_deadlines(false) where action in ('moved','moved_later')")"
[ "$moved" = "0" ] || { echo "FAIL: recount dry run would move $moved deadline(s)"; psql -c "select * from rederive_deadlines(false)"; exit 1; }

kept="$(psql -tAc "select action from rederive_deadlines(false) where deadline_id = '00000000-0000-0000-0000-0000000000d1'")"
[ "$kept" = "later_kept" ] || { echo "FAIL: the card-date deadline should be kept, got '$kept'"; exit 1; }

version="$(psql -tAc "select value #>> '{}' from life_settings where key = 'schema_version'")"
expected="$(sed -n 's/^  schema_version: //p' skills/life-os/SKILL.md)"
[ "$version" = "$expected" ] || { echo "FAIL: schema_version $version, SKILL.md says $expected"; exit 1; }

unwatched="$(psql -tAc "select count(*) from v_auto_renew_unwatched where name = 'Gym'")"
[ "$unwatched" = "1" ] || { echo "FAIL: v_auto_renew_unwatched misses the gym"; exit 1; }

if psql -tAc "select to_regclass('public.household_members') is not null" | grep -q t; then
  owner="$(psql -tAc "select count(*) from household_members where relation = 'self' and name = 'Person A'")"
  [ "$owner" = "1" ] || { echo "FAIL: the upgrade did not make owner_name the household's self member"; exit 1; }
  linked="$(psql -tAc "select count(*) from link_household_members(true) where member = 'Person A'")"
  [ "$linked" -ge 2 ] || { echo "FAIL: linking found $linked rows for the owner, expected the permit and its deadline"; exit 1; }
  psql -tAc "select id, due_on from deadlines where status = 'open' order by id" > "$work/linked.txt"
  if ! diff -u "$work/before.txt" "$work/linked.txt"; then echo "FAIL: linking household members moved open deadlines"; exit 1; fi
fi

psql -v ON_ERROR_STOP=1 -q -f tests/sql/release_checks.sql 2>&1 | grep -v '^$'
psql -v ON_ERROR_STOP=1 -q -f tests/sql/feature_checks.sql 2>&1 | grep -v '^$'

[ -n "${KEEP_DB:-}${UPG_EXISTING_DB:-}" ] || psql -qd postgres -c "drop database $DB"
echo "upgrade $BASE -> $(cat VERSION): ok"
