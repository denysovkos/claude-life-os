#!/usr/bin/env bash
# Installs Life OS into database $1 as setup does, then configures it like a real
# installation (region pack settings, owner, folders). Prints nothing on success.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../../.." && pwd)"
source "$here/env.sh"
db="$1"; region="${LIFEOS_IT_REGION:-de}"
run() { PGDATABASE="$db" psql -v ON_ERROR_STOP=1 -q -f "$1" >/dev/null 2>"$here/.last_error" || { echo "FAILED: $1"; grep -v NOTICE "$here/.last_error" | tail -5; exit 1; }; }
for f in "$root"/supabase/migrations/*.sql "$root"/supabase/seed/*.sql "$root/packs/region/$region/classification_rules.sql"; do run "$f"; done
python3 "$here/../lib/configure.py" "$region" | PGDATABASE="$db" psql -v ON_ERROR_STOP=1 -q >/dev/null
