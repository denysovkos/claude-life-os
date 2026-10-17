"""The simulated account a scenario runs in: Gmail, Drive and Calendar contents, shared by
all fake connector processes through one JSON file, plus a log of every tool call.

state/
  world.json      the account (mutated by tool calls: labels, created files, events)
  calls.jsonl     one line per tool call: {"t", "server", "tool", "args", "outcome"}
"""
import contextlib
import fcntl
import json
import os
import time

STATE = os.environ.get("LIFEOS_FAKE_STATE", ".state")


@contextlib.contextmanager
def world(write=False):
    path = os.path.join(STATE, "world.json")
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        yield data
        if write:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
            os.replace(tmp, path)


def log_call(server, tool, args, outcome="ok", **extra):
    entry = {"t": time.time(), "server": server, "tool": tool, "args": args, "outcome": outcome}
    entry.update(extra)
    with open(os.path.join(STATE, "calls.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")


def new_id(prefix):
    return prefix + os.urandom(8).hex()
