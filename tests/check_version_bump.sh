#!/usr/bin/env bash
# Pull-request guard: a change that ships to users must carry a new version.
#
# The release workflow publishes exactly v<VERSION> when a merge to main brings a VERSION
# that has no tag yet, and does nothing otherwise. So a pull request that changes what
# ends up in life-os.zip (the skill, migrations, seed, packs, Apps Script, docs, the
# packaging script) without raising VERSION would merge and never reach anyone. This
# check fails such a pull request with the fix spelled out. Changes only to tests, CI,
# READMEs or brand assets need no new version.
#
# Usage: tests/check_version_bump.sh <base-ref>     (CI passes origin/<base branch>)
set -euo pipefail
cd "$(dirname "$0")/.."

base="${1:?usage: tests/check_version_bump.sh <base-ref>}"
version="$(tr -d '[:space:]' < VERSION)"

shipped="$(git diff --name-only "$base"...HEAD -- skills supabase packs apps-script docs scripts/package_skills.sh || true)"
if [ -z "$shipped" ]; then
  echo "No shipped files changed: no new version needed."
  exit 0
fi
echo "Shipped files changed:"
echo "$shipped" | sed 's/^/  /'

latest="$(git tag -l 'v*' --sort=-v:refname | head -1 | sed 's/^v//')"
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
  echo "::error file=VERSION::VERSION is $version, which is already released (tag v$version). Raise VERSION (patch for fixes, minor for features) and add a '## <version>' section on top of CHANGELOG.md."
  exit 1
fi
if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
  echo "::error file=VERSION::VERSION $version is lower than the latest release $latest."
  exit 1
fi
echo "VERSION $version is new (latest release: ${latest:-none}): merging this publishes v$version."
