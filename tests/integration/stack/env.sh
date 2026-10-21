# Source this: connection settings for the integration stack.
export PGHOST=localhost PGPORT="${LIFEOS_IT_DB_PORT:-54322}" PGUSER=postgres PGPASSWORD=postgres PGDATABASE=postgres
export LIFEOS_REST_URL="http://localhost:${LIFEOS_IT_REST_PORT:-54321}"
_it_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LIFEOS_ANON_KEY="$(python3 "$_it_dir/lib/jwt.py" anon)"
export LIFEOS_SERVICE_KEY="$(python3 "$_it_dir/lib/jwt.py" service_role)"
export NO_PROXY="localhost,127.0.0.1,${NO_PROXY:-}" no_proxy="localhost,127.0.0.1,${no_proxy:-}"
