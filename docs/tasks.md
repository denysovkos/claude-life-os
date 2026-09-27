# Tasks in your task manager

The system never keeps its to-do list in the task manager. Every obligation lives first
in Supabase (a row in `deadlines`, or an email with `action_needed`), and only then is
mirrored as a task. The task's id is written back to the row. So:

- deleting Todoist, or switching to "no task manager", loses nothing: the daily brief
  still lists every open item on its reminder ladder;
- completing a task is how you tell the system something is done;
- the system never creates the same task twice, because it checks the id on the row
  before creating one.

Todoist is the one provider built in today (`task_provider = 'todoist'`). With
`task_provider = 'none'`, the same items arrive by email and in the daily brief instead.

## Every kind of task the system creates

All titles start with an emoji, so you can tell the system's tasks from your own and
filter them.

| Title | Created by | When | Due | Where |
|---|---|---|---|---|
| `📅 Daily brief 2026-10-03: Tax objection ends in 7 days` | email-intake | nightly, only if something matters today | today | system project |
| `💌 bills_payments Stadtwerke Beispiel: pay 61.20 by 15 Oct` | email-intake | a mail needs you to act | the due date in the mail, if any | default project (or a per-category one) |
| `⚠️ Passport expires 2026-12-01: Anna_passport.pdf` | drive-file-intake | a document expires within 30 days and has no task | 7 days before expiry | default project (or per area) |
| `🧾 Review 2026-09: cancel the old parking contract?` | life-review | monthly | in 3 days | system project |
| `⚠️ email-intake failed 2026-10-03` | email-intake, drive-file-intake | a run had errors | today | system project |

Hard deadlines (objection windows, residence permits, cancellation dates) also appear
in the brief on every rung of their ladder, typically 90, 60, 30, 14, 7, 3 and 1 days
before, whether or not they have a task.

### The daily brief

One task per day at most, and only on days with something in it. The description is the
whole brief: overdue items, what is coming up on today's rung, money due in the next 14
days, new mail that needs action, and anything wrong with the system. Nothing to say
means no task at all; a brief that speaks every day stops being read.

The title keeps the English words `Daily brief` in every language, because the rule
that stops the system from filing its own brief as incoming mail matches on them (when
the brief arrives by email).

### Mail that needs action

Title `💌 <category> <sender>: <what to do>`. The description holds the Gmail link and
the database row id. Todoist's own deadline field is a premium feature, so a hard date
goes into the title and the due date.

### Expiring documents

Title `⚠️ <document type> expires <date>: <file name>`, due a week before. Billing-period
ends of auto-renewing subscriptions are deliberately not tasks: that is not an expiry.

### The monthly review

One task with the decisions only a human can make, as a numbered list with links:
contracts that stopped debiting, prices that changed without a letter, notice periods
nobody knows, addresses to update. The report itself goes to Craft or a Google Doc.

### Failures

One task per failing job, not one per night: a week-long outage leaves one task.

## Closing the loop

| You do | The system does |
|---|---|
| complete a `⚠️ … expires` or deadline task | the next Drive intake marks the deadline `done`, with the completion time in its notes |
| complete a `💌` task | the email row keeps its history; the linked deadline, if any, closes as above |
| ignore a direct-debit bill | nothing to do: the nightly database job closes passive payment deadlines three days after the due date |
| leave an overdue task open | it stays overdue, and the brief escalates it by name after 7 days |
| want quiet for a while | `snoozed_until` on the deadline silences it in the brief without closing it |
| delete a task | the row keeps the dead task id; the brief still lists the deadline. Tell Claude "recreate the task for X" |

## Settings

```json
"task_provider": "todoist",
"task_targets": {
  "system_project": "<Todoist project id for briefs, reviews and failures>",
  "default_project": "<project id for mail and document tasks>",
  "label": "mail"
}
```

The setup skill creates the projects and writes the ids. To split mail by category, add
a key per category (for example `"bills_payments": "<project id>"`); the intake skills
use it when present and fall back to `default_project`.

## Another task manager

The skills talk to the task manager in five operations: create a task (title,
description, due date, project, label), read whether a task is completed, update a due
date, find an open task by title, and write the id back. Any task manager with a Claude
connector that can do those five can be a provider: add its name as a `task_provider`
value and the matching branch in the three skills that create tasks. Until then,
`none` works everywhere.
