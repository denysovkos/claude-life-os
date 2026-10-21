#!/usr/bin/env bash
# Suite 2, local half: apps-script/Code.gs in an Apps Script runtime against the stack.
#   tests/integration/bridge/run.sh        (KEEP_STACK=1 reuses a running stack)
set -euo pipefail
it="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${KEEP_STACK:-0}" != "1" ]; then "$it/stack/down.sh" >/dev/null 2>&1 || true; "$it/stack/up.sh"; fi
source "$it/stack/env.sh"
(cd "$it" && npm ci --silent && node --test --test-concurrency=1 bridge/*.test.js)
