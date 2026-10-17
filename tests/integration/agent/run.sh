#!/usr/bin/env bash
# Suite 3: a scripted agent in Claude's place, against fake connectors and the stack.
#   tests/integration/agent/run.sh [scenario …]      (KEEP_STACK=1 reuses a running stack)
# Deterministic, no model, no API key.
set -euo pipefail
it="$(cd "$(dirname "$0")/.." && pwd)"
py="$it/.venv/bin/python"; [ -x "$py" ] || { python3 -m venv "$it/.venv"; "$it/.venv/bin/pip" install -q -r "$it/requirements.txt"; }
if [ "${KEEP_STACK:-0}" != "1" ]; then "$it/stack/down.sh" >/dev/null 2>&1 || true; "$it/stack/up.sh"; fi
source "$it/stack/env.sh"
"$py" "$it/agent/run.py" "$@"
