#!/usr/bin/env python3
"""Proves apply_term_rule() in Postgres counts every region pack example the same way as
tests/test_packs.py, then exercises derive_deadlines(), rederive_deadlines(),
v_purchase_rights and settings_history end to end.

Needs a database with all migrations applied; the connection comes from the usual PG*
environment variables. Everything runs in one transaction that is rolled back, so it
leaves no data behind.

Usage: python3 tests/sql_rules_check.py
"""
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def lit(value):
    """A SQL string literal."""
    return "'" + str(value).replace("'", "''") + "'"


def jsonb(obj):
    return lit(json.dumps(obj, ensure_ascii=False)) + "::jsonb"


def main():
    steps = []                       # (sql, None) runs; (sql, (name, expected)) checks

    def run(sql):
        if sql.startswith("update life_settings"):
            # triggers elsewhere (sync_staging_flags) switch app.actor to 'skill'
            sql = "select set_config('app.actor', 'test', true); " + sql
        steps.append((sql, None))

    def check(name, sql, expected):
        steps.append((sql, (name, expected)))

    # 1. Every example of every region pack, through the SQL interpreter.
    for pack in sorted((ROOT / "packs" / "region").iterdir()):
        if pack.name.startswith("_"):
            continue
        rules = {r["key"]: r for r in json.loads((pack / "rules.json").read_text())["term_rules"]}
        for ex in json.loads((pack / "examples.json").read_text())["term_rules"]:
            check(f"{pack.name}/{ex['rule']}/{ex['start']}",
                  f"select apply_term_rule({jsonb(rules[ex['rule']])}, {lit(ex['start'])})::text",
                  ex["expect"])

    # 2. End to end with the de pack, the way the setup skill writes it.
    de = json.loads((ROOT / "packs/region/de/rules.json").read_text())
    de.update(region="de", version=json.loads((ROOT / "packs/region/de/pack.json").read_text())["version"])

    run("select set_config('app.actor', 'test', true)")
    run("update life_settings set value = '\"de\"' where key = 'region'")
    run("update life_settings set value = '{}' where key = 'region_rules'")
    run("insert into documents (drive_file_id, name, drive_url, document_type_key, issued_on, issuer) "
        "values ('t1', 'Bescheid.pdf', 'https://drive.example/t1', 'official_decision', current_date - 3, 'Test Amt')")
    check("region set, rules missing: nothing derived", "select derive_deadlines()::text", "0")
    check("region set, rules missing: invariant fires",
          "select failing::text from v_system_invariants where invariant = 'region_rules_missing'", "1")

    run(f"update life_settings set value = {jsonb(de)} where key = 'region_rules'")
    check("de rules: one deadline derived", "select derive_deadlines()::text", "1")
    check("de rules: rule key and version recorded",
          "select rule_key || '/' || rule_version from deadlines "
          "where source_id = (select id from documents where drive_file_id = 't1')",
          f"objection_administrative/{de['version']}")
    check("same rules: nothing moves", "select count(*)::text from rederive_deadlines() where action = 'moved'", "0")

    changed = json.loads(json.dumps(de))
    for r in changed["term_rules"]:
        if r["key"] == "objection_administrative":
            r["steps"] = [{"add_days": 14}]
    changed["version"] = "test"
    run(f"update life_settings set value = {jsonb(changed)} where key = 'region_rules'")
    check("changed rules: dry run shows the move",
          "select count(*)::text from rederive_deadlines(false) where action = 'moved'", "1")
    check("changed rules: dry run changed nothing",
          "select count(*)::text from rederive_deadlines(false) where action = 'moved'", "1")
    check("changed rules: apply moves it",
          "select count(*)::text from rederive_deadlines(true) where action = 'moved'", "1")
    check("changed rules: nothing left to move",
          "select count(*)::text from rederive_deadlines(false) where action = 'moved'", "0")

    run(f"update life_settings set value = {jsonb(de)} where key = 'region_rules'")
    run("insert into emails (gmail_message_id, category, amount, currency, vendor, received_at) values "
        "('p1', 'purchases', 100, 'EUR', 'Beispiel Shop', now()), "
        "('p2', 'purchases', 100, 'EUR', 'Lieferando', now())")
    check("purchase rights from the region", "select string_agg(vendor || ':' || state, ',') from v_purchase_rights",
          "Beispiel Shop:return_possible")
    run("update life_settings set value = '{}' where key = 'region_rules'")
    run("update life_settings set value = 'null' where key = 'region'")
    check("no region: purchase rights unknown", "select string_agg(distinct state, ',') from v_purchase_rights", "unknown")
    run("delete from deadlines where source_id = (select id from documents where drive_file_id = 't1')")
    check("no region: generic early placeholder", "select derive_deadlines()::text", "1")
    check("no region: placeholder is 14 days after the letter",
          "select (due_on - (current_date - 3))::text || '/' || rule_key from deadlines "
          "where source_id = (select id from documents where drive_file_id = 't1')",
          "14/objection_generic")
    check("settings history records the test's changes",
          "select (count(*) >= 5)::text from settings_history where actor = 'test'", "true")

    script = ["begin;"]
    for sql, spec in steps:
        if spec is None:
            script.append(sql + ";")
        else:
            script.append(f"select 'CHECK|' || {lit(spec[0])} || '|' || coalesce(({sql}), 'NULL');")
    script.append("rollback;")

    res = subprocess.run(["psql", "-X", "-q", "-t", "-A", "-v", "ON_ERROR_STOP=1"],
                         input="\n".join(script) + "\n", capture_output=True, text=True)
    if res.returncode:
        print(res.stdout, res.stderr, sep="\n")
        return 1

    got = [line.split("|", 2)[1:] for line in res.stdout.splitlines() if line.startswith("CHECK|")]
    expected = [spec for _, spec in steps if spec is not None]
    failed = 0
    for (name, want), (_, value) in zip(expected, got):
        ok = value == want
        failed += not ok
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {value!r}, expected {want!r}"))
    if len(got) != len(expected):
        print(f"FAIL expected {len(expected)} checks, got {len(got)}")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
