# The night schedule

[Українською](scheduling.uk.md)

Claude does not start by itself. Four scheduled runs make the system automatic:

| When (your time zone) | Prompt | What it does |
|---|---|---|
| every day **01:05** | `Run the life-os email-intake workflow.` | reads new mail, categorises it, creates tasks for anything you must do |
| every day **02:05** | `Run the life-os drive-file-intake workflow.` | indexes new documents, files them, writes deadlines |
| every day **03:05** | `Run the life-os nightly-check workflow.` | updates derived deadlines, checks the system, sends the one daily brief |
| 1st of the month **04:05** | `Run the life-os life-review workflow.` | monthly review of money, contracts, tax and system quality |

Two more things run without Claude and need no setup here: the Apps Script bridge every
15 minutes, and the database's own job `nightly-derivations` (`pg_cron`, 01:15 UTC).

## Why at night, and why in this order

**Night**, because nothing else is happening: no new mail being read by you, no
documents being moved, no competition with your own use of Claude, and the brief is
ready when you wake up.

**Email first.** The bridge copies attachments only for mail the email intake has
already sorted into an important category (bills, contracts, authorities, bank). It runs
every 15 minutes, so by 01:20 tonight's attachments are in the Drive inbox.

**Drive an hour later.** The Drive intake then finds those attachments and indexes them
the same night. Run it first and every attachment waits a full day.

**The check last.** It builds the brief from everything that happened in the two runs
before, so tonight's letter with a one-month objection window is in tomorrow morning's
brief, not the day after.

**Five past the hour.** Scheduled runs that start exactly on the hour can start several
minutes late because everyone else's start then too. Five past avoids it; the hour
between runs leaves room for a slow night.

**The review on the 1st.** It reviews a finished month. Any time after the nightly check
works; 04:05 keeps it apart from the other runs.

## Option A: Claude Code routines (recommended)

Routines run in Anthropic's cloud, so your computer can be off. They are available on
Pro, Max, Team and Enterprise plans.

A routine clones a GitHub repository at the start of every run and loads the skills
committed in it. This repository ships the skill at `.claude/skills/life-os`, so the
routine needs a copy of it on your GitHub:

1. On GitHub open the claude-life-os repository and click **Fork** (or **Use this
   template** → **Create a new repository**). Private is fine. It contains no personal
   data: everything personal is in your Supabase project.
2. Make sure your Google, Gmail and Supabase connectors (and Todoist or Craft if you use
   them) are connected at claude.ai/customize/connectors. Routines use the same
   connectors as your chats.

### In the browser

Open **claude.ai/code/routines** → **New routine**, and fill the form four times:

| Field | Value |
|---|---|
| Name | `Life OS: email` (then `Life OS: files`, `Life OS: nightly check`, `Life OS: monthly review`) |
| Instructions (prompt) | the prompt from the table above |
| Repository | your copy of claude-life-os |
| Environment | **Default** |
| Trigger | **Schedule** → **Daily** at the time from the table (entered in your local time) |
| Connectors | keep Gmail, Google Drive, Supabase, Google Calendar, and Todoist / Craft if you use them; remove every other one |

Click **Create**. For the monthly review choose any preset, save, then set the exact
schedule from the Claude Code command line with `/schedule update` and the cron
expression `5 4 1 * *` (04:05 on the 1st of every month).

To try one immediately, open it and click **Run now**, then open the run to read what
Claude did. A green status only means the session ran; the transcript tells you whether
the work succeeded.

### From the Claude Code command line

In any Claude Code session signed in with your claude.ai account:

```
/schedule every day at 01:05 in the <your repo> repository: Run the life-os email-intake workflow.
/schedule every day at 02:05 in the <your repo> repository: Run the life-os drive-file-intake workflow.
/schedule every day at 03:05 in the <your repo> repository: Run the life-os nightly-check workflow.
/schedule on the 1st of every month at 04:05 in the <your repo> repository: Run the life-os life-review workflow.
```

Claude asks follow-up questions (connectors, environment) and saves each routine to your
account; it shows up at claude.ai/code/routines too. `/schedule list` shows them all.

### Limits worth knowing

- Routines count against your plan's usage and a daily number of routine runs per
  account. Life OS is three runs a day plus one a month; check
  your remaining runs at claude.ai/code/routines.
- A routine can do everything its connectors allow without asking. That is why the
  connectors list should hold only what Life OS needs.
- If your GitHub connection expires, routines skip runs until you reconnect (up to 72
  hours), then switch off.

## Option B: scheduled tasks in the Claude desktop app

The desktop app can run the same prompts as local scheduled tasks. They need your
computer switched on and awake at those times, so for night runs they only suit a
computer that stays on. Create four tasks with the times and prompts from the table.

## When a night is missed

Each run starts where the previous one stopped, so the next run catches up everything.
The database keeps a watchdog (`v_intake_watchdog`): if the email intake or the nightly
check has not run for 36 hours, or the Drive intake for 30, the Apps Script bridge emails
you, independently of Claude. "life os doctor" shows the same in a table.
