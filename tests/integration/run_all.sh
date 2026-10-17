#!/usr/bin/env bash
# Every integration suite that runs without Google credentials, in order, on one stack:
#   1. database (Supabase Postgres + PostgREST)   2. bridge (Apps Script runtime)
#   3. Claude (only with LIFEOS_IT_CLAUDE=1, it calls the model)
# The real-Google suite needs its own credentials: tests/integration/gas-e2e/run.sh
set -euo pipefail
it="$(cd "$(dirname "$0")" && pwd)"
"$it/db/run.sh"
KEEP_STACK=1 "$it/bridge/run.sh"
if [ "${LIFEOS_IT_CLAUDE:-0}" = "1" ]; then KEEP_STACK=1 "$it/claude/run.sh"; fi
