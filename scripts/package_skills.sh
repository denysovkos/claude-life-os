#!/usr/bin/env bash
# Builds one upload-ready zip per skill into dist/.
#
# claude.ai takes a skill as a zip whose top folder contains SKILL.md. life-os-setup also
# needs the database migrations, the packs and the Apps Script, so they are copied into
# its assets/ folder here. That way the setup skill never depends on the person
# downloading the repository or on the repository being public.
#
# Usage: scripts/package_skills.sh     (needs zip)
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf dist && mkdir -p dist/stage
for dir in skills/*/; do
  name=$(basename "$dir")
  cp -R "$dir" "dist/stage/$name"
done

assets=dist/stage/life-os-setup/assets
mkdir -p "$assets"
cp -R supabase/migrations supabase/seed "$assets/"
cp -R packs "$assets/packs"
cp -R docs "$assets/docs"
mkdir -p "$assets/apps-script" && cp apps-script/Code.gs apps-script/appsscript.json "$assets/apps-script/"

for dir in dist/stage/*/; do
  name=$(basename "$dir")
  (cd dist/stage && zip -qr "../$name.zip" "$name")
  echo "dist/$name.zip"
done
rm -rf dist/stage
