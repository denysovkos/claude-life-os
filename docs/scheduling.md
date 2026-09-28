# The night schedule

[Українською](scheduling.uk.md)

Claude does not start by itself. Four scheduled tasks in Claude make the system
automatic:

| When (your time zone) | Prompt | What it does |
|---|---|---|
| every day **01:05** | `Run the life-os email-intake workflow.` | reads new mail, categorises it, creates tasks for anything you must do |
| every day **02:05** | `Run the life-os drive-file-intake workflow.` | indexes new documents, files them, writes deadlines |
| every day **03:05** | `Run the life-os nightly-check workflow.` | updates derived deadlines, checks the system, sends the one daily brief |
| 1st of the month **04:05** | `Run the life-os life-review workflow.` | monthly review of money, contracts, tax and system quality |

The prompts stay in English so the skill recognises the workflow without doubt. Answers,
tasks and the brief come in the language you chose.

Two more things run without Claude and need no setup here: the Apps Script bridge every
15 minutes, and the database's own job `nightly-derivations` (`pg_cron`, 01:15 UTC).

## Create the tasks

In Claude, open **Scheduled tasks** and create a new task four times: the prompt from the
table, the frequency (daily, or monthly for the review) and the time. The setup workflow
walks you through it at the end of "set up life os" and checks afterwards that the first
runs arrived.

To try one immediately, run it once by hand from the task list, or just write its prompt
in a chat.

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

## When a night is missed

Each run starts where the previous one stopped, so the next run catches up everything.
The database keeps a watchdog (`v_intake_watchdog`): if the email intake or the nightly
check has not run for 36 hours, or the Drive intake for 30, the Apps Script bridge emails
you, independently of Claude. "life os doctor" shows the same in a table.
