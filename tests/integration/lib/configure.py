"""Prints the SQL that setup step 5 and step 6 write, for a test installation.

The values are what a person in the given region would end up with: the region pack's
rules and version, English output, the pack's input languages, a fixed owner and the
Drive folder ids the fake Drive (tests/integration/claude/fakes) and the bridge harness
use. Usage: python3 configure.py <region>   |   psql
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
OWNER = {"name": "Test Owner", "email": "owner@lifeos.test"}
FOLDERS = {"inbox": "fld-inbox", "emergency": "fld-emergency", "backups": "fld-backups",
           "catch_all": "fld-catch-all"}


def pack(kind, code):
    base = ROOT / "packs" / kind / code
    return {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in base.glob("*.json")}


def lit(value):
    return "$j$" + json.dumps(value, ensure_ascii=False) + "$j$::jsonb"


def main(region):
    rp = pack("region", region)
    rules = dict(rp["rules"], region=region, version=rp["pack"]["version"])
    inputs = rp["pack"].get("default_input_locales", ["en"])
    hints = {}
    for loc in inputs:
        lp = pack("lang", loc) if (ROOT / "packs" / "lang" / loc).exists() else {}
        if lp:
            hints[loc] = {"keywords": lp["keywords"], **({"formats": lp["formats"]} if "formats" in lp else {})}
    installed = {"lang": {loc: pack("lang", loc)["pack"]["version"] for loc in hints},
                 "region": {region: rp["pack"]["version"]}}
    values = {
        "owner_name": json.dumps(OWNER["name"]),
        "owner_email": json.dumps(OWNER["email"]),
        "timezone": json.dumps(rp["pack"].get("default_timezone", "UTC")),
        "output_locale": json.dumps("en"),
        "input_locales": json.dumps(inputs),
        "region": json.dumps(region),
        "task_provider": json.dumps("none"),
        "notes_provider": json.dumps("none"),
        "dossier_labels": "{}",
        "lang_hints": json.dumps(hints, ensure_ascii=False),
        "region_rules": json.dumps(rules, ensure_ascii=False),
        "installed_packs": json.dumps(installed),
        "current_address": json.dumps("Neue Strasse 1"),
        "former_address_patterns": json.dumps(["musterallee"]),
        "emergency_contacts": json.dumps([{"name": "Test Contact", "role": "sibling", "contact": "+49 30 000000"}]),
        "drive_folders": json.dumps(FOLDERS),
    }
    print("begin;")
    print("select set_config('app.actor','setup',true);")
    print("insert into life_settings (key, value) values")
    print(",\n".join(f"  ('{k}', {lit(json.loads(v))})" for k, v in values.items()))
    print("on conflict (key) do update set value = excluded.value, updated_at = now();")
    print("commit;")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "de")
