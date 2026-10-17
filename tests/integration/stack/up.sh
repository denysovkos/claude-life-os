#!/usr/bin/env bash
# Starts the stack and installs Life OS the way setup does: every migration, the seed,
# and a region pack (LIFEOS_IT_REGION, default de), as `postgres`, which on Supabase
# is not a superuser. NO_INSTALL=1 starts an empty database (for the upgrade test).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../.." && pwd)"
docker compose -f "$here/docker-compose.yml" up -d --wait db
source "$here/env.sh"
for i in $(seq 1 60); do psql -tAc "select 1" >/dev/null 2>&1 && break; sleep 1; done
if [ "${NO_INSTALL:-0}" != "1" ]; then
  "$here/install.sh" "$PGDATABASE"
fi
docker compose -f "$here/docker-compose.yml" up -d --wait rest
for i in $(seq 1 30); do curl -sf "$LIFEOS_REST_URL/" -H "Authorization: Bearer $LIFEOS_SERVICE_KEY" >/dev/null && break; sleep 1; done
echo "stack up: db $PGHOST:$PGPORT, rest $LIFEOS_REST_URL ($(psql -tAc 'select version()' | cut -d' ' -f1-2))"
