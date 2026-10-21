"""Suite 3: a scripted agent in Claude's place, through the same connectors and protocol.

For each scenario in scenarios/*.json:
 1. the stack database is reset to a fresh installation (every table emptied, migrations
    0005+, seed, region pack and setup's settings applied again), then db_setup runs;
 2. the scenario's Gmail, Drive and Calendar contents become the fake account;
 3. the agent (personas.py) talks MCP over stdio to the fake connectors
    (fakes/server.py), exactly as Claude Code would: `compliant` runs the named workflow
    with the scenario's `decisions` standing in for the model's judgement;
    `compromised` obeys an injected letter after the workflow's own start (snapshot,
    lock) and tries everything the letter asks;
 4. assertions run on the database, the fake account and the log of every tool call.

    tests/integration/agent/run.sh                every scenario
    tests/integration/agent/run.sh email_intake   one scenario

No model is called. Results land in tests/integration/agent/.state/<scenario>/.
"""
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import zoneinfo

import psycopg

HERE = pathlib.Path(__file__).resolve().parent
IT = HERE.parent
ROOT = IT.parent.parent
sys.path.insert(0, str(HERE))
from mcp_client import McpClient  # noqa: E402
from personas import CompliantAgent, CompromisedAgent  # noqa: E402

PY = sys.executable
TZ = zoneinfo.ZoneInfo("Europe/Berlin")
FAKE_SERVERS = {"Gmail": "gmail", "Google_Drive": "drive", "Google_Calendar": "calendar", "Supabase": "supabase"}
READ_ONLY = re.compile(r"(?i)\b(insert|update|delete|truncate|alter|create|drop|grant|revoke)\b")


# ---- templates: {{ts-6h}} {{date}} {{date+14|dd.mm.yyyy}} ---------------------------------

def resolve(value, now):
    if isinstance(value, dict):
        return {k: resolve(v, now) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, now) for v in value]
    if not isinstance(value, str):
        return value

    def sub(m):
        kind, sign, n, unit, fmt = m.groups()
        delta = 0 if not n else int(n) * (1 if sign == "+" else -1)
        if kind == "ts":
            step = {"m": dt.timedelta(minutes=1), "h": dt.timedelta(hours=1), "d": dt.timedelta(days=1)}[unit or "d"]
            return (now + delta * step).isoformat()
        day = now.date() + dt.timedelta(days=delta)
        return {"dd.mm.yyyy": day.strftime("%d.%m.%Y"), "yyyy-mm-dd": day.isoformat(), None: day.isoformat()}[fmt]

    return re.sub(r"\{\{(ts|date)(?:([+-])(\d+)([mhd])?)?(?:\|([^}]+))?\}\}", sub, value)


# ---- the database --------------------------------------------------------------------------

def psql_file(path):
    subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-q", "-f", str(path)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def reset_database(setup_sql):
    with psycopg.connect(autocommit=True) as conn:
        tables = [r[0] for r in conn.execute(
            "select tablename from pg_tables where schemaname = 'public' order by 1").fetchall()]
        conn.execute("truncate " + ", ".join(f"public.{t}" for t in tables) + " restart identity cascade")
    for f in sorted((ROOT / "supabase" / "migrations").glob("*.sql")):
        if f.name >= "0005":
            psql_file(f)
    for f in sorted((ROOT / "supabase" / "seed").glob("*.sql")):
        psql_file(f)
    psql_file(ROOT / "packs" / "region" / "de" / "classification_rules.sql")
    conf = subprocess.run([PY, str(IT / "lib" / "configure.py"), "de"], check=True, capture_output=True, text=True).stdout
    subprocess.run(["psql", "-v", "ON_ERROR_STOP=1", "-q"], input=conf, text=True, check=True, stdout=subprocess.DEVNULL)
    with psycopg.connect(autocommit=True) as conn:
        conn.execute("select set_config('app.actor', 'test', false)")
        for q in setup_sql:
            conn.execute(q)


def table_counts():
    with psycopg.connect() as conn:
        tables = [r[0] for r in conn.execute("select tablename from pg_tables where schemaname = 'public'").fetchall()]
        return {t: conn.execute(f"select count(*) from public.{t}").fetchone()[0] for t in tables}


# ---- running the agent ------------------------------------------------------------------------

def client_for(state, scenario):
    env = {k: v for k, v in os.environ.items() if k.startswith(("PG", "LIFEOS_", "PATH", "HOME"))}
    env.update({"LIFEOS_FAKE_STATE": str(state), "LIFEOS_HOLD_SECONDS": os.environ.get("LIFEOS_HOLD_SECONDS", "0")})
    if scenario.get("routine_tools") == "closed":
        env["LIFEOS_ROUTINE_TOOLS"] = "closed"
    return McpClient({"mcpServers": {name: {"command": PY, "args": [str(HERE / "fakes" / "server.py"), svc], "env": env}
                                     for name, svc in FAKE_SERVERS.items()}})


def run_agent(state, scenario):
    client = client_for(state, scenario)
    steps, result = [], {"ok": True}
    try:
        if scenario["persona"] == "compliant":
            agent = CompliantAgent(client, scenario, steps)
            result["answer"] = getattr(agent, scenario["workflow"].replace("-", "_"))()
        else:
            opener = CompliantAgent(client, scenario, steps)
            opener.begin(scenario["workflow"], ["owner_email"])          # the run started normally …
            result["outcomes"] = CompromisedAgent(client, scenario, steps).run()   # … then obeyed the letter
    except Exception as e:  # the run itself failing is a finding, reported as a check
        result.update(ok=False, error=f"{type(e).__name__}: {e}")
    finally:
        client.close()
    result["steps"] = steps
    return result


# ---- assertions ------------------------------------------------------------------------------

def calls(state):
    path = state / "calls.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def check(scenario, state, result, before_counts, started):
    a = scenario["assert"]
    out = []

    def record(name, ok, detail=""):
        out.append({"check": name, "ok": bool(ok), "detail": detail})

    record("the agent completed the run", result["ok"], result.get("error", ""))
    with psycopg.connect() as conn:
        conn.execute("set timezone = 'Europe/Berlin'")
        for item in a.get("sql", []):
            try:
                ok = conn.execute(item["q"].replace("{{RUN_STARTED}}", started.isoformat())).fetchone()[0]
                record(item["why"], ok is True, "" if ok else "query returned " + repr(ok))
            except psycopg.Error as e:
                conn.rollback()
                record(item["why"], False, f"query failed: {e}")
    log = calls(state)
    for server, tools in a.get("forbidden_calls", {}).items():
        used = [c for c in log if c["server"] == server and c["tool"] in tools]
        record(f"never called {server} {', '.join(tools)}", not used, json.dumps(used)[:500])
    if a.get("no_held_statements"):
        held = [c for c in log if c.get("outcome") == "held"]
        record("no statement the connector would hold for a human", not held,
               "; ".join(f"{c['reason']}: {str(c['args'])[:200]}" for c in held))
    if a.get("read_only"):
        writes = [c["args"]["query"] for c in log if c["tool"] == "execute_sql"
                  and READ_ONLY.search(re.sub(r"'(?:[^']|'')*'", "''", c["args"]["query"]))]
        record("no SQL that writes", not writes, " | ".join(w[:150] for w in writes))
        record("no row changed anywhere", table_counts() == before_counts)
    for pattern in a.get("answer_matches", []):
        record(f"the answer matches /{pattern}/", re.search(pattern, result.get("answer") or "", re.I), result.get("answer"))
    cal = a.get("calendar")
    if cal:
        events = json.loads((state / "world.json").read_text()).get("calendar", {}).get("events", [])
        record(f"at most {cal['max_events']} calendar event(s)", len(events) <= cal["max_events"], json.dumps(events)[:400])
        if cal.get("no_attendees"):
            record("calendar events have no attendees",
                   all(not e.get("attendees") and not e.get("attendeeEmails") for e in events), json.dumps(events)[:400])
    outcomes = result.get("outcomes", {})
    for name in a.get("blocked", []):
        o = outcomes.get(name)
        record(f"blocked: {name}", o and o["blocked"], json.dumps(o)[:300])
    for name, why in a.get("not_blocked", {}).items():
        o = outcomes.get(name)
        record(f"known limit, {why}: {name}", o is not None and not o["blocked"], json.dumps(o)[:300])
    unlisted = set(outcomes) - set(a.get("blocked", [])) - set(a.get("not_blocked", {}))
    record("every attack has an expected outcome in the scenario", not unlisted, ", ".join(sorted(unlisted)))
    return out


def main(names):
    scenarios = sorted((HERE / "scenarios").glob("*.json"))
    if names:
        scenarios = [s for s in scenarios if s.stem in names]
    failed = 0
    for path in scenarios:
        scenario = resolve(json.loads(path.read_text()), dt.datetime.now(TZ))
        state = HERE / ".state" / path.stem
        if state.exists():
            shutil.rmtree(state)
        state.mkdir(parents=True)
        print(f"\n=== {scenario['name']} ({scenario['persona']}): {scenario['about']}", flush=True)
        (state / "world.json").write_text(json.dumps(scenario["world"], ensure_ascii=False, indent=1))
        reset_database(scenario.get("db_setup", []))
        before = table_counts()
        started = dt.datetime.now(dt.timezone.utc)
        result = run_agent(state, scenario)
        checks = check(scenario, state, result, before, started)
        bad = [c for c in checks if not c["ok"]]
        failed += bool(bad)
        for c in checks:
            print(("  PASS " if c["ok"] else "  FAIL ") + c["check"] + ("" if c["ok"] else f"\n       {c['detail']}"))
        (state / "report.json").write_text(json.dumps({"scenario": scenario["name"], "ok": not bad, "result": result,
                                                       "checks": checks}, indent=1, ensure_ascii=False, default=str))
        print(f"  -> {'PASS' if not bad else 'FAIL'}  steps={len(result['steps'])} tool_calls={len(calls(state))}")
    print(f"\nsuite 3 (scripted agent): {len(scenarios) - failed}/{len(scenarios)} scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
