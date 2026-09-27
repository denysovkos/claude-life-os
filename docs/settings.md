# Settings

## Where they live

In one table of your own Supabase project: `life_settings`, one row per setting, the
value as JSON. Nothing personal is stored anywhere else:

- not in the skills (they read the table at the start of every run),
- not in Claude's memory,
- not in the Apps Script (it holds only the database URL and key, in Script
  Properties, and reads everything else from the table on every run),
- not in this repository.

Every change goes through a trigger into `settings_history`: the key, the old value,
the new value, when, and who (`life-os-setup`, `skill`, or `human` for an edit made by
hand in the Supabase dashboard). Any setting can be read as of a date and put back.

```sql
select key, value from life_settings order by key;
select changed_at, key, actor, old_value, new_value from settings_history order by changed_at desc limit 20;
```

## How they get there and how to change them

First run: the `life-os-setup` skill asks a few questions, reads the packs you chose,
and writes every setting in one statement.

Later: say it in any chat, for example "change my language to German", "I moved to
another country", "add my sister to the emergency binder", "switch tasks to Todoist".
The same skill in reconfigure mode writes the change, shows you what changed from
`settings_history`, and handles the side effects listed below. Editing a row by hand in
the Supabase dashboard also works; the history then shows `human`.

## Every setting

| Key | Example | Written by | Read by |
|---|---|---|---|
| `schema_version` | `"0.3.0"` | migrations | setup (doctor, upgrades) |
| `owner_name` | `"Anna Beispiel"` | setup | reports |
| `owner_email` | `"anna@example.com"` | setup | brief and review by email |
| `timezone` | `"Europe/Berlin"` | setup | every skill, the bridge, the binder date |
| `output_locale` | `"uk"` | setup | every skill: language of briefs, tasks, reports |
| `input_locales` | `["de","en","uk"]` | setup | intake: which language hints to load |
| `region` | `"de"` | setup | database and skills: whose law applies |
| `region_rules` | contents of `packs/region/de/rules.json` plus `region`, `version` | setup | `derive_deadlines()`, `v_purchase_rights`, `v_tax_items`, skills |
| `lang_hints` | keywords and date/amount formats per input locale | setup | intake |
| `dossier_labels` | contents of `packs/lang/uk/dossier.json` | setup | `emergency_dossier()` |
| `installed_packs` | `{"lang":{"uk":"1.0.0"},"region":{"de":"1.1.0"}}` | setup | doctor (pack updates) |
| `drive_folders` | ids of inbox, emergency, backups, catch_all | setup | bridge, Drive intake, review |
| `task_provider` | `"todoist"` or `"none"` | setup | every skill that creates tasks |
| `task_targets` | project ids and label | setup | same |
| `notes_provider`, `notes_targets` | `"craft"`, folder id | setup | review |
| `bridge_categories` | `["legal_notary","government","bank_finance","bills_payments"]` | setup (defaults in 0005) | bridge, which attachments to copy |
| `current_address`, `former_address_patterns`, `address_audit_ignore` | street fragments | setup, review | `v_address_audit` |
| `tax_year` | `2026` | setup, review | `v_tax_items` |
| `emergency_contacts` | `[{"name":"…","role":"sister","contact":"+49…"}]` | setup | `emergency_dossier()` |

The folder-to-area map is a table of its own, `drive_folder_areas`, because it has many
rows; it is written by setup and read by the Drive intake.

## When a setting changes what was already computed

Most settings only affect what happens next. The legal rules are the exception: a
deadline already in the database was counted with the rules that were current then.
That matters in three situations:

1. **You move to another country.** Objection windows, notice periods and return
   windows are different.
2. **A region pack is updated** (the law changed, or the pack had a mistake).
3. **The database is upgraded** to a version that reads a setting it did not read
   before.

So every deadline that was counted from a rule remembers it: `deadlines.rule_key` (for
example `objection_tax`) and `deadlines.rule_version` (the pack version). After the
rules change, `rederive_deadlines()` recounts every open deadline that has a rule key:

```sql
select * from rederive_deadlines(false);  -- dry run: what would move, and to when
select * from rederive_deadlines(true);   -- apply
```

| action | meaning |
|---|---|
| `moved` | the new rules give a different date; applying moves it and notes both dates |
| `unchanged` | same date under the new rules |
| `rule_gone` | the new rules have no such rule (for example after moving country); the deadline is left as it is for you to keep or cancel |
| `no_start_date` | the source document has no date to count from |

The setup skill runs the dry run for you, shows the moves (earlier dates first), and
applies only when you say yes. It also moves the due dates of the matching Todoist tasks.
Deadlines that were not counted from a rule (a date printed in a letter, a date you
entered) are never touched.

A database upgrade works the same way: apply the new migrations, then "life os doctor"
checks `installed_packs` against the packs shipped with the skill and offers the update
and the recount. Until the region pack is synced after an upgrade from 0.2.0, the
invariant `region_rules_missing` is raised and no legal deadline is derived at all,
rather than one derived with the wrong law. The nightly job records the same message
in `derivation_runs.error`, so the daily brief reports it.

## No region pack

If your country has no pack yet, `region` stays empty. The system still tracks every
date it reads in your documents and letters. For an official decision without a stated
deadline it creates a deliberately early placeholder, 14 days after the date on the
letter, marked `objection_generic`, so you look at the letter in time. Return and
warranty windows show `unknown`. See [packs/README.md](../packs/README.md) to add a
country.
