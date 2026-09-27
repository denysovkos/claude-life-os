#!/usr/bin/env bash
# Builds dist/life-os.zip: the one skill a person uploads to Claude.
#
# claude.ai takes a skill as a zip whose top folder contains SKILL.md. The setup workflow
# also needs the database migrations, the packs, the Apps Script and the docs, so they are
# copied into life-os/assets/ here. The person never needs the repository itself.
#
# Claude Code (and its cloud routines) load the same skill from the repository through the
# symlink .claude/skills/life-os -> skills/life-os; there the files are at the repo root.
#
# Usage: scripts/package_skills.sh     (needs zip)
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf dist && mkdir -p dist/stage
cp -R skills/life-os dist/stage/life-os

assets=dist/stage/life-os/assets
mkdir -p "$assets/apps-script"
cp -R supabase/migrations supabase/seed "$assets/"
cp -R packs "$assets/packs"
cp -R docs "$assets/docs"
cp apps-script/Code.gs apps-script/appsscript.json "$assets/apps-script/"

(cd dist/stage && zip -qr ../life-os.zip life-os)
rm -rf dist/stage
echo dist/life-os.zip
