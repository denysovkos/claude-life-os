---
name: context-lookup
description: >-
  Read-only lookup in the claude-life-os Supabase index of documents, emails, contracts,
  payments, deadlines and bank transactions. Use for any question about the person's own
  paperwork, money or obligations, in any chat, before searching Drive or Gmail by hand:
  a certificate, a clause, a bill, an expiry, when a contract can be cancelled, whether
  something can still be returned, what goes into the tax return, which documents a
  bundle still lacks, who still writes to the old address, what a contract says, whether
  a payment went through, the emergency binder, or whether the system is healthy.
  Examples: "when does my insurance end", "can I still return the headphones", "what
  does the lease say about pets", "коли можу розірвати", "що можна скасувати", "чи можу
  повернути", "wann kann ich kündigen", "was steht im Mietvertrag". Never writes.
  Monthly reviews and imports belong to life-review, nightly sync to drive-file-intake
  and email-intake.
compatibility: Requires the Supabase connector (read-only use). Google Drive and Gmail are optional, only to open a source link when asked.
metadata:
  version: v2.0
  product: claude-life-os
---

# Context lookup (read-only, scope first)

Other chats regularly need one fact out of the person's documents or mail (is the
registration certificate still valid, what is the notice period on the gym contract,
when is the next insurance premium due) without knowing the index exists. The intake
skills are write-heavy jobs with locks, snapshots and task side effects; asking them to
"just answer a question" drags all of that in. This skill is the narrow read path:
resolve the question to one scope, query only that scope, answer, touch nothing.

## Step 0: settings

```sql
select key, value from life_settings
where key in ('output_locale','timezone','region','schema_version');
```

Answer in the language the person asked in. `output_locale` is only the fallback. If
`schema_version` is missing, the system was never installed: say so and point to the
`life-os-setup` skill.

## Scope before query

Classify every question into exactly one scope (rarely two) before touching the
database. Never run an unscoped `select *` and filter afterwards, and never report beyond
the resolved scope even when a join returns more. A finance question gets finance rows.

The scope vocabulary is read from the controlled vocabularies the intake skills
maintain, so this skill cannot drift from them:

```sql
select distinct domain from document_types where active;
select distinct category from emails;               -- the fixed 10 + 'other'
select distinct area_name from drive_folder_areas;
select name, kind, status from matters where status in ('active','waiting');
```

| Scope | Asked like | `documents` filter | `emails` filter | Also check |
|---|---|---|---|---|
| identity | passport, ID card, birth or marriage certificate, residence permit | `document_types.domain = 'identity'` | — | `deadlines` |
| finance | account, investment, loan, card | `domain = 'finance'` | `category = 'bank_finance'` | `bank_transactions` |
| bills | utilities, rent payment, subscriptions | `domain in ('finance','property','services')`, type-specific | `category = 'bills_payments'` | `recurring_payments` |
| legal | contract, notary, lawyer, court | `domain = 'legal'` | `category = 'legal_notary'` | `matters` |
| government | tax office, immigration office, city registry | issuer resolves to an entity of `kind = 'authority'`, or `domain = 'identity'` from a government issuer | `category = 'government'` | `matters`, `deadlines` |
| employment | employment contract, payslip, employer letters | `domain = 'employment'` | `category = 'work'` | — |
| insurance | policy, premium, claim | `domain = 'insurance'` | `category in ('bills_payments','health')` with `tags @> '{insurance}'` | `recurring_payments` |
| property | flat, lease, condominium, mortgage | `domain = 'property'` | `category in ('legal_notary','bills_payments')` | `matters` |
| vehicle | car lease, registration, car insurance | `domain = 'vehicle'` | — | `recurring_payments` |
| services | phone, internet, electricity, gas | `domain = 'services'` | `category = 'bills_payments'` | `recurring_payments` |
| education | diploma, course or language certificate | `domain = 'education'` | — | — |
| health | doctor, prescriptions, health insurance letters | — | `category = 'health'` | — |
| travel | tickets, hotels, bookings | — | `category = 'travel'` | — |
| personal | purchases, deliveries, private mail | — | `category in ('purchases','orders_delivery','personal_social')` | — |
| reference | templates, comparison sheets | `kind = 'reference_file'` | — | — |

A question that straddles two scopes ("when does the lease end and how much do I pay
for it", property + bills) gets both queried explicitly and both named in the answer. A
question that maps to none: say so and ask which scope, do not guess broad.

## How to answer

1. **Classify** against the table. Genuinely ambiguous: ask once.
2. **Query only that scope**, for example "do I have my marriage certificate":
   ```sql
   select d.name, d.drive_url, t.label, d.issuer, d.expiry_date, d.status, d.physical_location
   from documents d join document_types t on t.key = d.document_type_key
   where t.domain = 'identity' and d.duplicate_of is null
     and (d.document_type_key = 'civil_status_certificate' or d.name ilike '%marriage%')
   order by d.expiry_date nulls last;
   ```
3. For "what do I have under X", filter by the scope column, not free text.
4. `search_all(query)` is fine for *locating* a row, but the scope still governs what is
   *reported*. A hit outside the scope is not the answer; mention it in passing only when
   clearly useful.
5. **Answer first, source second.** Lead with the field that was asked for (status, date,
   amount), then `drive_url` or `gmail_url`. No excerpts or unrelated columns unless asked.
6. **Nothing found: say so.** Do not silently broaden. Offer the neighbouring scope if
   that seems to be what was meant.
7. A deadline is reported as stored (`deadlines.due_on`, `documents.expiry_date`). Do not
   recompute the brief's ladder logic and never touch `snoozed_until`.

## Content, rights and exits

Some questions are "what does X say" or "can I still do Y". Each has a view or function;
use it instead of reasoning from scratch.

- **What does a document say** ("what does the lease say about pets", "who pays for the
  roof"): `select * from ask_documents('<keywords in the document''s language>', 8);`
  Returns documents and emails with a highlighted snippet and the link. Answer from the
  snippet, quote the clause, give the link. Query in the document's language (German
  keywords for a German contract). No snippet answers it: say so, offer to open the full
  text.
- **Can I cancel, and when**: `select * from v_notice_calendar where name ilike '%X%' or vendor ilike '%X%';`
  `cancel_by` is the last day the cancellation must arrive, `earliest_exit` the first day
  it takes effect. `exit_known = false` means the index does not know: say so.
- **Can I return it / warranty**: `select * from v_purchase_rights where vendor ilike '%X%' or item ilike '%X%';`
  The return window is approximate, counted from the order mail rather than delivery, so
  it errs early. The windows themselves come from the region; `region_rules.facts` and
  `term_rules` (`consumer_withdrawal`, `statutory_warranty`) explain them if asked.
- **Who still uses my old address**: `select * from v_address_audit;` Counterparty, date of
  the last mail that still carries a former address, link. Empty means nobody.
- **Did a payment go through / what got more expensive**: `select * from v_payment_exceptions;`
  and `select * from v_bank_coverage;` for how recent the bank data is. Older than a
  month: say so, the answer may be stale.
- **Tax**: `select * from v_tax_items;` These are candidates. The person, or their tax
  adviser, decides.
- **Is anything broken**: `select invariant, severity, failing, meaning from v_system_invariants where failing > 0;`
- **Emergency overview**: `select emergency_dossier();` The same text the bridge writes
  daily into the "Emergency binder" Google Doc in the emergency folder.

## Never

- Insert, update or delete any row in any table.
- Create a task or calendar event, even for a deadline found along the way. Say "this
  one has no task yet" and leave it to the person or the intake skills.
- Fetch file content or upload anything speculatively. Hand over `drive_url` / `gmail_url`.
- Widen the scope "just in case".

## Notes

- Holds no run state and writes no run log.
- If Supabase is not connected in this chat, say so plainly and give the exact query.
- A genuinely unscoped ask ("is there anything anywhere about X") is the one exception:
  search everything, but label each result with the scope it belongs to.
- A new `document_types` domain or `emails` category that is not in the table above: add
  a row here in the next skill revision rather than guessing every time.
