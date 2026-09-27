# claude-life-os

**English** · [Українська](README.uk.md) · [Deutsch](README.de.md) · [Polski](README.pl.md) · [Français](README.fr.md) · [Español](README.es.md) · [Italiano](README.it.md) · [Nederlands](README.nl.md) · [Русский](README.ru.md) · [Português](README.pt.md)

A personal system for paperwork. It reads your Gmail and Google Drive, keeps an index of
every formal document, letter, contract and bill in a database you own, and makes sure
no deadline, renewal or expiry slips by. You ask it questions in plain language, in any
Claude chat: "when does my passport expire", "can I still cancel the gym", "what does
the lease say about pets".

It was built by one person for their own life over a month of daily use, and is now
being turned into something anyone can install. No programming needed: Claude walks
you through every step.

## Install

This is for the normal Claude app: claude.ai in the browser, or the Claude desktop or
mobile app. Not Claude Code.

**1. Download the skill: [life-os.zip](https://github.com/denysovkos/claude-life-os/releases/latest/download/life-os.zip)** (do not unpack it). It is one skill that
contains everything: setup, mail, files, the nightly check, the monthly review and the
answers to your questions. The link always points to the newest version
([all releases](https://github.com/denysovkos/claude-life-os/releases)).

**2. Add it to Claude.** In Claude open **Settings** → **Capabilities**, turn on
**Code execution and file creation** (skills need it), then under **Skills** click
**Upload skill** and choose `life-os.zip`.

**3. Connect your accounts.** **Settings** → **Connectors**: Google Drive, Gmail and
Supabase; if you like also Google Calendar, Todoist, Craft.

**4. Open a new chat and write: `set up life os`.** From here Claude leads. It asks a few
questions (your language, your country, which apps you use), creates the database and
the Drive folders, and checks every step before the next one.

**5. Install the Google Apps Script bridge** when Claude asks. It is one file that runs
in your Google account every 15 minutes, even when Claude does not:

- script.google.com → **New project** → paste the code Claude shows you → save;
- **Project Settings** → **Script Properties** → add `SUPABASE_URL` and
  `SUPABASE_SECRET_KEY` (Claude says where to find them; the key goes only there, never
  into a chat);
- choose the function `install` → **Run** → **Review permissions** → your account →
  "Google hasn't verified this app" → **Advanced** → **Go to Life OS bridge (unsafe)** →
  **Select all** → **Allow**. The warning is normal: it is your own script, running only
  in your account.

Step by step with every permission explained: [docs/apps-script.md](docs/apps-script.md).

**6. Let it run every night.** Claude does not start by itself, so create four scheduled
runs, best at night and in this order: mail at **01:05**, files at **02:05**, the nightly
check with your daily brief at **03:05**, and the monthly review on the 1st at **04:05**.
Mail goes first because its sorting tells the bridge which attachments to copy; an hour
later the file run indexes them the same night; the check comes last so the morning brief
includes everything. The easiest way is Claude Code routines, which run in the cloud with
your computer off: [docs/scheduling.md](docs/scheduling.md) has every click and the
`/schedule` commands.

That is all, about 30 minutes. Later, at any time, write **`life os doctor`**: it checks
the whole system and tells you exactly what to fix.

**Updating:** download the new `life-os.zip` and upload it again the same way (remove the
old skill first if Claude does not replace it). Then write `life os doctor`; it applies
database updates and new rules for you.

### What you need

- A Google account (Gmail and Google Drive).
- A Claude plan that includes skills and connectors.
- A free [Supabase](https://supabase.com) account. Supabase is the database that stores
  the index; the free plan is enough. Claude creates the project for you.
- Optional: Todoist for tasks, Craft for the monthly report. Without them, tasks and
  reports arrive by email and as Google Docs.

## What it does for you

- **Every night** it reads new mail, sorts it into 10 categories (bills, authorities,
  bank, contracts, travel and so on), pulls out amounts and due dates, and creates a task
  when you need to act. Travel and appointments become calendar events.
- **Important attachments** (bills, contracts, letters from authorities) are copied into
  Google Drive automatically, filed into the right folder, and indexed with their full
  text.
- **It tracks deadlines, not just dates.** A residence permit that expires, a letter you
  can object to within a month, an insurance that renews itself unless cancelled three
  months before: each becomes a deadline with reminders that come more often as it gets
  closer. How a deadline is counted depends on your country.
- **A short daily brief**, only on days when something matters. No "all clear" messages.
- **A monthly review**: what you pay every month, what changed, what you can cancel and
  by when, what goes into your tax return, and anything that looks wrong.
- **An emergency binder**: a Google Doc, rewritten daily, with your open matters,
  deadlines, contracts, insurance, where your original documents are, and who to call.

## Tasks in your task manager

The database keeps the list; the task manager only mirrors it, so nothing is lost if you
switch apps or use none. With Todoist you get:

| Task | When |
|---|---|
| `📅 Daily brief <date>: <most important thing>` | only on days something matters; the brief is in the description |
| `💌 <category> <sender>: <what to do>` | a letter needs you to act |
| `⚠️ <document> expires <date>: <file>` | a document expires within 30 days |
| `🧾 Review <month>: <main decision>` | once a month, the decisions only you can make |
| `⚠️ <job> failed <date>` | a nightly job had errors |

Completing a task closes the deadline behind it. More in [docs/tasks.md](docs/tasks.md).

## Settings

All settings are stored in one table of your own database, `life_settings`, and every
change is recorded in `settings_history`, so it can be seen and undone. To change
something, just say it: "change my language to German", "I moved to Spain", "add my
sister to the emergency binder". When your country or its rules change, deadlines that
were already counted are recounted, after Claude shows you what moves. Details in
[docs/settings.md](docs/settings.md).

## Languages and countries

The system reads mail in any language. Its own output (briefs, tasks, reports, the
emergency binder, folder names) comes in these languages:

| Language | Status |
|---|---|
| English, Deutsch, Українська | complete and tested |
| Polski, Français, Español, Italiano, Nederlands, Русский, Português | starter translation, English where incomplete |

Legal rules (how an objection deadline is counted, when a phone contract can be
cancelled, when to return a purchase, when the tax return is due) come in a **region
pack**. **Germany** is complete. Everywhere else the system still tracks every date it
reads, but uses cautious placeholders and asks you about local rules. See
[packs/README.md](packs/README.md) to add a language or a country.

## Privacy and security

Your data stays in your own accounts: your Gmail, your Drive, your Supabase project.
There is no server in between and nobody else has access. The database is locked so its
public interface returns nothing at all; only Claude (through your own connector) and
your own Apps Script can read it. Files never pass through the AI: Google moves them
directly from Gmail to Drive. Details in [docs/security.md](docs/security.md).

## How it works

Everything that has to happen on time is done by things that do not forget: Google
Apps Script every 15 minutes and scheduled jobs inside the database every night. Claude
does only what needs judgement: reading a letter and understanding what it means. The
database is the single source of truth; Todoist, Craft and the calendar only mirror it.

- [docs/architecture.md](docs/architecture.md): components, data model, a letter's path
  through the system.
- [docs/apps-script.md](docs/apps-script.md): installing the bridge.
- [docs/scheduling.md](docs/scheduling.md): night schedule: routines, times, order.
- [docs/tasks.md](docs/tasks.md): what lands in your task manager and how it closes.
- [docs/settings.md](docs/settings.md): every setting, and what happens when one changes.
- [docs/security.md](docs/security.md): keys, permissions, what the AI sees, backups.
- [docs/troubleshooting.md](docs/troubleshooting.md): every failure the original ran
  into, and what fixes it.

## Repository

```
skills/life-os/    the Claude skill: SKILL.md and its six workflows
.claude/skills/    link to it, so Claude Code and routines load it from a clone
apps-script/       the Google Apps Script bridge (Code.gs)
supabase/          database migrations and the document type registry
packs/             language and region packs
docs/              documentation
tests/             pack contract tests and the SQL rule check
scripts/           packaging and JSON formatting
```

For contributors: `python3 -m unittest discover -s tests -v` runs the pack tests. Every
push to `main` is a new version: CI tags it and publishes a GitHub release with
`life-os.zip` (`.github/workflows/release.yml`). The patch number counts up by itself;
set `VERSION` to a new MAJOR.MINOR.0 to start a new line. CI also
applies every migration and pack to a fresh Postgres 16 twice, checks that the database
counts deadlines exactly like the pack examples, and that it stays closed to the public
API.

## Status

Early. The database, the bridge and the email intake ran daily for a month in the
original private version and were then generalised. The setup skill and the packs are
new. Expect rough edges and please report them.
