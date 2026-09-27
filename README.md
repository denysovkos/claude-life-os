# claude-life-os

[Українською](README.uk.md)

A personal system for paperwork. It reads your Gmail and Google Drive, keeps an index of
every formal document, letter, contract and bill in a database you own, and makes sure
no deadline, renewal or expiry slips by. You ask it questions in plain language, in any
Claude chat: "when does my passport expire", "can I still cancel the gym", "what does
the lease say about pets".

It was built by one person for their own life over a month of daily use, and is now
being turned into something anyone can install. No programming needed: Claude walks
you through every step.

## What it does for you

- **Every night**, it reads new mail, sorts it into 10 categories (bills, authorities,
  bank, contracts, travel, …), pulls out amounts and due dates, and creates a task when
  you need to act. Travel and appointments become calendar events.
- **Important attachments** (bills, contracts, letters from authorities) are copied into
  Google Drive automatically, filed into the right folder, and indexed with their full
  text.
- **Deadlines are tracked, not just dates.** A residence permit that expires, a letter
  you can object to within a month, an insurance that renews itself unless cancelled
  three months before: each becomes a deadline with reminders that grow more frequent
  as it gets closer.
- **A short daily brief**, only on days something matters. No "all clear" messages.
- **A monthly review**: what you pay every month, what changed, what you can cancel and
  by when, what goes into your tax return, and anything that looks wrong.
- **An emergency binder**: a Google Doc, rewritten daily, with your open matters,
  deadlines, contracts, insurance, where your original documents are, and who to call.

## What you need

- A Google account (Gmail and Google Drive).
- A Claude plan with connectors (Supabase, Google Drive, Gmail; Google Calendar
  recommended).
- A free [Supabase](https://supabase.com) account. Supabase is the database that stores
  the index. The free plan is enough.
- Optional: Todoist for tasks, Craft for the monthly report. Without them, tasks and
  reports arrive by email and as Google Docs.

About 30 minutes for the setup.

## Install

1. **Get the skills.** Download the latest release, or build it yourself with
   `scripts/package_skills.sh`. You get five zip files:
   `life-os-setup.zip`, `email-intake.zip`, `drive-file-intake.zip`,
   `context-lookup.zip`, `life-review.zip`.
2. **Add them to Claude.** In Claude: Settings → Capabilities → Skills → Upload skill,
   once per zip.
3. **Connect your accounts.** Settings → Connectors: Supabase, Google Drive, Gmail, and
   if you like Google Calendar, Todoist, Craft.
4. **Start a new chat and say "set up life os".** Claude asks a few questions (your
   language, your country, which apps you use), creates the database, the Drive
   folders, and gives you one piece of code to paste into Google Apps Script with
   click-by-click instructions. It checks each step before moving on.
5. **Create three scheduled tasks** in Claude when it asks you to: email at night, Drive
   after it, the review once a month.

Later, at any time: say **"life os doctor"** and it checks the whole system and tells
you exactly what to fix.

## Languages and countries

The system reads mail in any language. Its own output (briefs, tasks, reports, the
emergency binder, folder names) is fully translated in **English, German and
Ukrainian**. Polish, French, Spanish, Italian, Dutch, Russian and Portuguese have a
starter translation and fall back to English where it is incomplete.

Legal rules (how an objection deadline is counted, when a phone contract can be
cancelled, when the tax return is due) come in a **region pack**. **Germany** is
complete. Everywhere else the system still tracks every date it reads, but asks you
about local rules instead of knowing them. See [packs/README.md](packs/README.md) to
add a language or a country.

## Privacy and security

Your data stays in your own accounts: your Gmail, your Drive, your Supabase project.
There is no server in between and nobody else has access. The database is locked so its
public interface returns nothing at all; only Claude (through your own connector) and
your own Apps Script can read it. Files never pass through the AI: Google moves them
directly from Gmail to Drive. Details in [docs/security.md](docs/security.md).

## How it works

Everything that has to happen on time is done by things that do not forget: Google
Apps Script every 15 minutes, and scheduled jobs inside the database every night.
Claude does only what needs judgement: reading a letter and understanding what it
means. The database is the single source of truth; Todoist, Craft and the calendar only
mirror it.

- [docs/architecture.md](docs/architecture.md): components, data model, a letter's path
  through the system, known gaps.
- [docs/security.md](docs/security.md): keys, permissions, what the AI sees, backups.
- [docs/troubleshooting.md](docs/troubleshooting.md): every failure the original ran
  into, and what fixes it.

## Repository

```
skills/            the five Claude skills
apps-script/       the Google Apps Script bridge (Code.gs)
supabase/          database migrations and the document type registry
packs/             language and region packs
docs/              architecture, security, troubleshooting
tests/             contract tests for the packs
scripts/           packaging
```

For contributors: `python3 -m unittest discover -s tests -v` runs the pack contract
tests. CI also applies every migration and pack to a fresh Postgres 16 twice and checks
that the database stays closed to the public API.

## Status

Early. The database, the bridge and the email intake have run daily for a month in the
original private version and were then generalised. The setup skill and the packs are
new. Expect rough edges and please report them.
