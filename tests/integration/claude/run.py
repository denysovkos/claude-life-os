"""Suite 3: Claude runs the skill, unattended, the way a routine does, in a simulated account.

For each scenario in scenarios/*.json:
 1. the stack database is reset to a fresh installation (every table emptied, migrations
    0005+, seed, region pack and setup's settings applied again), then the scenario's
    db_setup runs;
 2. the scenario's Gmail, Drive and Calendar contents become the fake account;
 3. Claude Code runs headless in a throwaway copy of this repository, with the skill from
    .claude/skills (as a routine loads it), only the fake connectors (--strict-mcp-config),
    no user settings or synced skills (a temporary HOME), and the scenario's prompt as
    the routine's prompt;
 4. assertions run on the database, the fake account and the log of every tool call.

    tests/integration/claude/run.py                 every scenario
    tests/integration/claude/run.py email_intake    one scenario
    LIFEOS_IT_MODEL=<model id>                      model to run (default: the CLI's)

Results and transcripts land in tests/integration/claude/.state/<scenario>/.
This calls the model and costs money: about a few dollars for all four scenarios.
"""
import datetime as dt
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time
import zoneinfo

import psycopg

HERE = pathlib.Path(__file__).resolve().parent
IT = HERE.parent
ROOT = IT.parent.parent
PY = sys.executable
TZ = zoneinfo.ZoneInfo("Europe/Berlin")
FAKE_SERVERS = {"Gmail": "gmail", "Google_Drive": "drive", "Google_Calendar": "calendar", "Supabase": "supabase"}


# ---- templates: {{ts-6h}} {{date}} {{date+14|dd.mm.yyyy}} ---------------------------------

def resolve(value, now):
    if isinstance(value, dict):
        return {k: resolve(v, now) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, now) for v in value]
    if not isinstance(value, str):
        return value

    def sub(m):
        kind, sign, n, unit, fmt = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
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


# ---- running Claude -------------------------------------------------------------------------

def prepare(state):
    if state.exists():
        shutil.rmtree(state)
    (state / "home").mkdir(parents=True)
    repo = state / "repo"
    shutil.copytree(ROOT, repo, symlinks=True, ignore=shutil.ignore_patterns(
        ".git", ".venv", "node_modules", ".state", "dist", "__pycache__"))
    env = {k: v for k, v in os.environ.items() if k.startswith(("PG", "LIFEOS_"))}
    env.update({"LIFEOS_FAKE_STATE": str(state), "LIFEOS_HOLD_SECONDS": os.environ.get("LIFEOS_HOLD_SECONDS", "5")})
    config = {"mcpServers": {name: {"type": "stdio", "command": PY,
                                    "args": [str(HERE / "fakes" / "server.py"), svc], "env": env}
                             for name, svc in FAKE_SERVERS.items()}}
    (state / "mcp.json").write_text(json.dumps(config, indent=1))
    return repo


def run_claude(state, repo, prompt):
    allowed = ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Skill", "TodoWrite"] + [f"mcp__{n}" for n in FAKE_SERVERS]
    cmd = ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--mcp-config", str(state / "mcp.json"), "--strict-mcp-config",
           "--setting-sources", "project", "--allowedTools", *allowed, "--max-turns", "250"]
    if os.environ.get("LIFEOS_IT_MODEL"):
        cmd += ["--model", os.environ["LIFEOS_IT_MODEL"]]
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CLAUDE_CODE_SYNC_", "CLAUDE_CODE_SESSION", "CLAUDE_CODE_REMOTE_SESSION"))}
    env["HOME"] = str(state / "home")
    started = time.time()
    with open(state / "transcript.jsonl", "w") as out:
        proc = subprocess.run(cmd, cwd=repo, env=env, stdout=out, stderr=subprocess.PIPE, text=True,
                              timeout=int(os.environ.get("LIFEOS_IT_TIMEOUT", "2700")))
    result = {}
    for line in (state / "transcript.jsonl").read_text().splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "result":
            result = ev
    result["exit_code"] = proc.returncode
    result["stderr"] = proc.stderr[-2000:]
    result["seconds"] = round(time.time() - started)
    return result


# ---- assertions ------------------------------------------------------------------------------

READ_ONLY = re.compile(r"(?i)\b(insert|update|delete|truncate|alter|create|drop|grant|revoke)\b")


def calls(state):
    path = state / "calls.jsonl"
    return [json.loads(l) for l in path.read_text().splitlines()] if path.exists() else []


def check(scenario, state, result, before_counts, started):
    a = scenario["assert"]
    out = []

    def record(name, ok, detail=""):
        out.append({"check": name, "ok": bool(ok), "detail": detail})

    record("Claude finished the run", result.get("subtype") == "success" and not result.get("is_error"),
           f"subtype={result.get('subtype')} exit={result.get('exit_code')} {result.get('stderr', '')[-300:]}")
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
                  and READ_ONLY.search(re.sub(r"'(?:[^']|'')*'", "''", c["args"]["query"]))
                  and "set_config" not in c["args"]["query"]]
        record("no SQL that writes", not writes, " | ".join(w[:150] for w in writes))
        record("no row changed anywhere", table_counts() == before_counts)
    if a.get("answer_matches"):
        answer = result.get("result", "")
        for pattern in a["answer_matches"]:
            record(f"the answer matches /{pattern}/", re.search(pattern, answer, re.I), answer[:300])
    cal = a.get("calendar")
    if cal:
        world = json.loads((state / "world.json").read_text())
        events = world.get("calendar", {}).get("events", [])
        record(f"at most {cal['max_events']} calendar event(s)", len(events) <= cal["max_events"], json.dumps(events)[:400])
        if cal.get("no_attendees"):
            record("calendar events have no attendees",
                   all(not e.get("attendees") and not e.get("attendeeEmails") for e in events), json.dumps(events)[:400])
    sql_calls = [c for c in log if c["tool"] == "execute_sql" and c["outcome"] == "ok"]
    record("the skill answered from the database", len(sql_calls) >= 1, f"{len(sql_calls)} successful execute_sql calls")
    return out


def main(names):
    scenarios = sorted((HERE / "scenarios").glob("*.json"))
    if names:
        scenarios = [s for s in scenarios if s.stem in names]
    summary, failed = [], 0
    for path in scenarios:
        scenario = json.loads(path.read_text())
        now = dt.datetime.now(TZ)
        scenario = resolve(scenario, now)
        state = HERE / ".state" / path.stem
        print(f"\n=== {scenario['name']}: {scenario['about']}", flush=True)
        repo = prepare(state)
        (state / "world.json").write_text(json.dumps(scenario["world"], ensure_ascii=False, indent=1))
        reset_database(scenario.get("db_setup", []))
        before = table_counts()
        started = dt.datetime.now(dt.timezone.utc)
        result = run_claude(state, repo, scenario["prompt"])
        checks = check(scenario, state, result, before, started)
        bad = [c for c in checks if not c["ok"]]
        failed += bool(bad)
        for c in checks:
            print(("  PASS " if c["ok"] else "  FAIL ") + c["check"] + ("" if c["ok"] else f"\n       {c['detail']}"))
        info = {"scenario": scenario["name"], "ok": not bad, "turns": result.get("num_turns"),
                "cost_usd": result.get("total_cost_usd"), "seconds": result.get("seconds"),
                "tool_calls": len(calls(state)), "checks": checks}
        (state / "report.json").write_text(json.dumps(info, indent=1, ensure_ascii=False))
        print(f"  -> {'PASS' if not bad else 'FAIL'}  turns={info['turns']} tool_calls={info['tool_calls']} "
              f"cost=${info['cost_usd']} time={info['seconds']}s  ({state}/transcript.jsonl)")
        summary.append(info)
    print(f"\nsuite 3 (Claude): {len(summary) - failed}/{len(summary)} scenarios passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
