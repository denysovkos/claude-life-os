#!/usr/bin/env bash
# Suite 3: Claude runs the skill against fake connectors and the stack database.
#   tests/integration/claude/run.sh [scenario …]      (KEEP_STACK=1 reuses a running stack)
# Needs the `claude` CLI signed in, or ANTHROPIC_API_KEY. Costs a few dollars per full run.
set -euo pipefail
it="$(cd "$(dirname "$0")/.." && pwd)"
py="$it/.venv/bin/python"; [ -x "$py" ] || { python3 -m venv "$it/.venv"; "$it/.venv/bin/pip" install -q -r "$it/requirements.txt"; }
if [ "${KEEP_STACK:-0}" != "1" ]; then "$it/stack/down.sh" >/dev/null 2>&1 || true; "$it/stack/up.sh"; fi
source "$it/stack/env.sh"
"$py" "$it/claude/run.py" "$@"
