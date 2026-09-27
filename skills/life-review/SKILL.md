---
name: life-review
description: >-
  Monthly (and on-demand) review of the whole claude-life-os system: import bank
  statements into bank_transactions, reconcile contracts against bank debits and
  invoices, fill unknown notice periods from indexed contracts, audit addresses after a
  move, track the tax year, check backups, review system quality, and deliver one report
  plus one task with the decisions that need a human. Use when the person says "monthly
  review", "how are my finances", "what can I cancel", "reconcile the bank", "import this
  statement", "tax year", "emergency binder", "місячний огляд", "що можна скасувати",
  "звір банк", "Kontoauszug importieren", "Steuer", or when the monthly scheduled task
  fires (first Sunday of the month). Not for the nightly intake (drive-file-intake,
  email-intake) and not for single lookups (context-lookup).
compatibility: Requires Supabase and Google Drive connectors. A task provider (Todoist) and a notes provider (Craft) are optional.
metadata:
  version: v2.0
  product: claude-life-os
---

# Life review

Write `v2.0` into `life_review_runs.skill_version`.

## How the work is split, and why this skill exists

Deterministic work runs without Claude. The `pg_cron` job `nightly-derivations` calls
`run_nightly_derivations()`: it closes passive direct-debit deadlines, links bank
transactions to `recurring_payments`, and derives objection deadlines from official
decisions. The Apps Script bridge copies attachments every 15 minutes and rewrites the
emergency binder daily. The daily brief reads `v_system_invariants`.

This skill does the part that needs judgement: reading statements and contracts,
deciding whether a mismatch is a data error or a real problem, and turning the month
into a short list of decisions for the person.

Never delete rows. Never cancel or change anything with a vendor. Every write that is not
an insert starts with `select set_config('app.actor','skill',true);` in the same
`execute_sql` call, so `corrections` records it as the skill's, not a human's.

## Step 0: settings, snapshot, lock

```sql
select key, value from life_settings
where key in ('timezone','output_locale','region','region_rules','owner_name','owner_email',
              'task_provider','task_targets','notes_provider','notes_targets','drive_folders',
              'current_address','former_address_patterns','address_audit_ignore',
              'tax_year','emergency_contacts');
select * from take_snapshot('life-review pre-run');

insert into run_locks (skill_name, expires_at, holder)
values ('life-review', now() + interval '60 minutes', :holder)
on conflict (skill_name) do update set locked_at = now(),
  expires_at = excluded.expires_at, holder = excluded.holder
where run_locks.expires_at < now()
returning skill_name;
```

Zero rows from the lock: another run holds it, stop. Delete the lock row at the end.
Write everything for the person in `output_locale`. Legal statements come from
`region_rules` (its `basis`, `notes` and `facts`), never from memory; with no region
pack, say that a local rule applies and ask.

## Monthly run

1. **Import bank statements.** `select * from v_bank_statement_backlog;` lists indexed
   `bank_statement` documents with no `bank_statement_imports` row. For each, oldest
   first, at most three per run:
   - Read the text (`document_texts.body`, else Drive `read_file_content`, else the OCR
     fallback described in `drive-file-intake`). Identify the account (IBAN or account
     number) and the period.
   - **Already covered?** If `bank_transactions` already has rows for that account
     spanning the whole period (for example from a CSV import done earlier), record an
     import row with `rows_inserted = 0` and `source_note = 'pre-existing'`. Do not
     import twice.
   - Otherwise extract every line: `booked_on`, `value_date`, `amount` (always positive),
     `direction` (`debit`/`credit`), `counterparty`, `reference`, `method`
     (`sepa_direct_debit`, `transfer`, `card`, `fee`, `cash_deposit`), `account_iban`,
     `source = 'statement_import'`. Insert with `on conflict do nothing` against the
     dedupe index. Record the import with parsed and inserted counts. A parsed count
     that does not match the statement's own line count is an `errors` entry, never a
     silent pass.
   - Many people pay from more than one account. A contract paid from an account whose
     statements were never imported reads as `never_observed`. Say which accounts have
     data (`v_bank_coverage`) instead of reporting such contracts as missing.
   - Then `select link_bank_transactions();`
   Nothing to import and `v_bank_coverage.days_stale > 40`: that is the first line of
   the report, asking the person to drop the latest statements into the Drive inbox.

2. **Run the derivations once more** (idempotent): `select run_nightly_derivations();`
   then `select * from derivation_runs order by ran_at desc limit 3;` must show no
   `error`. Also `select jobname, schedule, active from cron.job;` where `pg_cron` exists:
   a missing or inactive `nightly-derivations` is an `errors` entry.

3. **Collect the month.** `select monthly_review();` (previous month by default).

4. **Triage payment exceptions.** `select * from v_payment_exceptions;`
   - `amount_changed`: find the evidence, a price-change letter in `emails` or
     `documents` (`ask_documents('<vendor> <price change words in the letter''s language>', 8)`).
     Evidence found: update `recurring_payments.amount` and cite the source in `notes`.
     None: it goes to the person.
   - `missing`: a contract that stopped debiting. Look for a cancellation confirmation
     from the vendor. Found: `status = 'ended'` with a note. Otherwise it goes to the
     person; a savings or insurance contract that silently stopped is exactly the case
     worth a question.
   - `never_observed` with an `explanation`: fine, skip. Without one: probably paid from
     another account or a wrong record. List it for the person once, not every month.
   - `select * from v_invoice_reconciliation where period_covered and matched_tx is null;`
     same treatment.

5. **Fill unknown exits.** `select * from v_notice_calendar where not exit_known;` For up
   to five rows with a `document_id`, read the contract for the notice period, minimum
   term and contract term, and write `notice_period_months`, `contract_end`,
   `auto_renews` only if stated. Quote the clause in `notes`. Where the law answers it
   rather than the contract, use the matching `region_rules.term_rules` entry (for
   example `telecom_cancel_by`, `insurance_cancel_by`) or `facts` entry (for example an
   obligation that cannot be cancelled at all), cite its `basis` in `notes`, and write
   the result. Everything else goes to the person as one list, highest monthly amount
   first.

6. **Things that should have ended.** Look for active obligations tied to a situation
   that is over: a former flat (deposit guarantees, utilities, parking), a phone number
   that was ported to another provider, a finished course, a sold car. Propose, never
   change status without evidence (a confirmation letter in the index).

7. **Address audit.** `select * from v_address_audit;` Every counterparty listed gets one
   line in the person's task: "update address at X". Confirmed false positives (the old
   landlord, a closed account) go into `life_settings.address_audit_ignore`.

8. **Tax year.** `select * from v_tax_items;` and the open tax bundle, if one exists:
   `select * from v_bundle_status where bundle ilike '%tax%' or bundle ilike '%steuer%';`
   Tag new obligations with `tax_relevance` when obvious. Candidate categories are
   candidates: the person, or their adviser, decides the share. From January on, chase
   the missing annual certificates by name. `region_rules.annual_dates` holds the filing
   deadline; when it is within 90 days and the bundle is still blocked, that is the
   first line of the report.

9. **Legal dates.** `select * from v_system_invariants where invariant = 'legal_decision_without_date';`
   For each official decision without `issued_on`, read the date from the text and set
   it. The nightly job then derives the deadline. If the window has clearly passed, leave
   it: `derive_deadlines()` ignores dates more than 7 days gone.

10. **Backup check (first Sunday).** Latest `backups` row: download the CSV from the
    backups folder in `drive_folders.backups`, count data rows per table, compare with
    `row_counts`. Mismatch, or no backup in 35 days, is an `errors` entry.

11. **System quality.** From `monthly_review()->'system_quality'`: human corrections by
    field (where does intake misjudge?), `emails_other_pct`, `rules_zero_hits`,
    `unresolved_entities`. Propose at most three concrete changes as
    `improvement_proposals` with `autonomy = 'ask'`, for example a `classification_rules`
    row for a sender that keeps landing in `other`, or promoting a frequent unresolved
    entity.

12. **Report and decisions.**
    - The report: prose, short. Money (total committed, what changed, exceptions), exits
      coming up (`v_notice_calendar` with `cancel_by` within 90 days), legal and
      immigration dates, tax status, system quality. Numbers, not adjectives.
      - `notes_provider = 'craft'`: a document "Monthly review YYYY-MM" in
        `notes_targets.reports_folder`.
      - otherwise: a Google Doc with the same title in the `drive_folders.catch_all`
        folder, or, if Drive writes are not possible, the report text in
        `life_review_runs.notes`.
    - The decisions: exactly one item, due in three days, titled
      `🧾 Review YYYY-MM: <the most important decision>`, body = the decisions as a
      numbered list, each with its evidence link.
      - `task_provider = 'todoist'`: a task in `task_targets.system_project`.
      - otherwise: an email to `owner_email` with that subject.
    - Log `life_review_runs` (`mode`, `review_month`, `skill_version`, `summary` jsonb,
      `errors`, `notes`).
    - Release the lock.

## On-demand modes

- "What can I cancel / when can I cancel X": `v_notice_calendar`, answer with
  `cancel_by` and `earliest_exit`, flag unknowns.
- "Can I return it / warranty": `v_purchase_rights`.
- "Taxes": step 8 only.
- "Import this statement": step 1 only, then `v_payment_exceptions`.
- "Emergency binder": `select emergency_dossier();` shows the current text. The Google
  Doc in the emergency folder is rewritten daily by the bridge. To add people to it,
  update `life_settings.emergency_contacts` (a list of `{name, role, contact}`).
- Content questions ("what does the contract say about X") belong to `context-lookup`;
  use `ask_documents` from here only inside a review.

On-demand modes that write still take the snapshot and the lock.

## Reference

Views: `v_bank_coverage`, `v_bank_statement_backlog`, `v_payment_exceptions`,
`v_payment_reconciliation`, `v_invoice_reconciliation`, `v_notice_calendar`,
`v_purchase_rights`, `v_tax_items`, `v_address_audit`, `v_hard_deadline_guard`,
`v_system_invariants`, `v_bundle_status`, `v_bundle_summary`.
Functions: `monthly_review(date)`, `link_bank_transactions()`, `derive_deadlines()`,
`run_nightly_derivations()`, `emergency_dossier()`, `ask_documents(text, int)`,
`reconcile_passive_deadlines()`, `take_snapshot(text)`.
Tables: `life_settings`, `bank_statement_imports`, `bank_transactions`,
`recurring_payments`, `life_review_runs`, `derivation_runs`, `improvement_proposals`.
