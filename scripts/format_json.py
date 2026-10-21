#!/usr/bin/env python3
"""Pretty-prints pack JSON with short scalar lists and one-key objects on one line.

Usage: scripts/format_json.py packs/region/de/rules.json [...]
"""
import json
import sys


def fmt(v, ind=0):
    pad = "  " * ind
    if isinstance(v, dict):
        if len(v) == 1 and not isinstance(next(iter(v.values())), (dict, list)):
            return json.dumps(v, ensure_ascii=False)
        items = [f'{pad}  {json.dumps(k, ensure_ascii=False)}: {fmt(x, ind + 1)}' for k, x in v.items()]
        return "{\n" + ",\n".join(items) + f"\n{pad}}}" if items else "{}"
    if isinstance(v, list):
        if all(not isinstance(x, (dict, list)) for x in v) or all(
                isinstance(x, dict) and len(x) == 1 and not isinstance(next(iter(x.values())), (dict, list)) for x in v):
            return "[" + ", ".join(fmt(x) for x in v) + "]"
        return "[\n" + ",\n".join(f"{pad}  {fmt(x, ind + 1)}" for x in v) + f"\n{pad}]"
    return json.dumps(v, ensure_ascii=False)


for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    with open(path, "w", encoding="utf-8") as f:
        f.write(fmt(data) + "\n")
