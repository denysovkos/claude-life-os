#!/usr/bin/env bash
# Every integration suite that runs without Google credentials, in order, on one stack:
#   1. database (Supabase Postgres + PostgREST)   2. bridge (Apps Script runtime)
#   3. scripted agent (compliant and compromised personas, no model)
# The real-Google suite needs its own credentials: tests/integration/gas-e2e/run.sh
set -euo pipefail
it="$(cd "$(dirname "$0")" && pwd)"
"$it/db/run.sh"
KEEP_STACK=1 "$it/bridge/run.sh"
KEEP_STACK=1 "$it/agent/run.sh"
