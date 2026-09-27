# Packs

The system has two independent configuration axes, and a pack covers exactly one of them.

**Language packs** (`lang/<locale>/`) describe how mail and documents look in a language
and how the system talks back: which words hint at a category, how dates and amounts are
written, what the emergency binder and the Drive folders are called. They never carry
law. English mail about a German tax assessment uses the `en` language pack and the `de`
region pack.

**Region packs** (`region/<code>/`) carry legal meaning: which documents start a
deadline, how that deadline is counted, when a contract can be cancelled, which
authorities send mail and from where, when the tax return is due.

Nothing in a pack runs by itself. The `life-os-setup` skill reads the packs you choose
and writes them into `life_settings` (`dossier_labels`, `lang_hints`, `region_rules`)
and, for region packs, runs `classification_rules.sql`. The intake skills read those
settings at the start of every run.

## Status

| Pack | Status |
|---|---|
| `lang/en`, `lang/de`, `lang/uk` | stable, tested |
| `lang/pl`, `fr`, `es`, `it`, `nl`, `ru`, `pt` | skeleton, community-maintained |
| `region/de` | stable, tested |

A skeleton pack is usable: whatever it does not translate falls back to English, and
intake still reads mail in any language because classification is judgement, not
keyword matching. It just gets fewer free hints.

## Language pack files

| File | Required | What it holds |
|---|---|---|
| `pack.json` | always | `locale`, `name`, `status` (`stable` or `skeleton`), `version`, `maintainers` |
| `dossier.json` | always | Labels for the emergency binder. Keys are fixed by `dossier_label()` in migration 0005. |
| `folders.json` | always | Names for the Drive folders the setup skill creates. No `/` or `\`. |
| `keywords.json` | always | `categories` (the 10 email categories → hint words), `action_phrases`, `deadline_phrases`, `amount_labels` |
| `formats.json` | stable | `decimal_separator`, `thousands_separator`, `amount_pattern` (named group `amount`), `date_patterns` (named groups `d`, `m` or `mon`, `y`), `month_names` |
| `examples.json` | stable | Synthetic dates, amounts and one email per category, with the expected result |

## Region pack files

| File | What it holds |
|---|---|
| `pack.json` | `region`, `status`, `currency`, `default_timezone`, `default_input_locales`, `tax_year_start` |
| `rules.json` | `term_rules` (below), `annual_dates`, `facts` (plain statements the skills may quote), `authorities`, `purchase_rights_min_amount` and `purchase_rights_ignore` (which purchases `v_purchase_rights` lists), `tax_relevance_labels` (where each `tax_relevance` value goes in the tax return, shown by `v_tax_items`) |
| `classification_rules.sql` | Idempotent SQL: authority entities, their domain aliases, and deterministic email rules |
| `examples.json` | For every term rule at least one start date and the expected result |

A term rule turns a start date into a deadline:

```json
{
  "key": "objection_tax",
  "applies_to": ["tax_assessment"],
  "deadline_type": "legal_response",
  "start": "issued_on",
  "notification_offset_days": 4,
  "steps": [{"add_months": 1}],
  "roll_to_business_day": true,
  "hard": true,
  "lead_days": [30, 14, 7, 3, 1],
  "basis": "the statute, in one or two sentences"
}
```

`notification_offset_days` is a legal fiction for posted letters (in Germany a letter
counts as received on the fourth day after posting). It is added to `issued_on` first,
and skipped when the start is a real receipt date, such as the day an email arrived.
Then the steps run in order. `add_days` and `add_months` are plain calendar arithmetic (a month
added to 31 January lands on the last day of February). `term_months` is a contract term
that starts on a day: it ends the day before the corresponding day, or on the last day
of the month when there is no corresponding day. `end_of_month` moves to the month's
last day. `roll_to_business_day` moves a Saturday or Sunday to Monday; public holidays
are regional and deliberately left to the `notes`.

`applies_to` must use keys from `supabase/seed/document_types.sql`. A rule that needs a
new document type needs a migration first.

The database runs these rules itself: `apply_term_rule(rule, start)` in migration 0007
is the one interpreter, used by `derive_deadlines()` for every `legal_response` rule that
starts at `issued_on`, by `v_purchase_rights` for `consumer_withdrawal` and
`statutory_warranty`, and by the skills for everything else. Rule keys are stored on the
deadlines they produce, so keep a key stable across versions of a pack: renaming it
turns every open deadline counted with it into `rule_gone` on the next recount.

## Contributing a pack

1. Copy `lang/en` (or `region/_template`) to the new code.
2. Translate or write the files. Examples are synthetic: invented names, invented
   companies, never a real letter.
3. Run `python3 -m unittest discover -s tests -v` from the repository root. For a region
   pack, also `python3 tests/sql_rules_check.py` against a Postgres with the migrations
   applied: it proves the database counts your examples the same way.
   `scripts/format_json.py` keeps the JSON layout consistent.
4. Bump `version` in `pack.json` when rules change: installations compare it with what
   they have and offer the update, with a recount of open deadlines.
5. Open a pull request. CI runs the same tests, and for region packs also applies
   `classification_rules.sql` twice to a fresh Postgres to prove it is idempotent.

A skeleton becomes stable when every file is complete and its examples pass.
