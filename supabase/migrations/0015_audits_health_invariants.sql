-- 0015: sharper audits, honest health numbers, the new invariants, schema 0.6.0.
--
-- * v_address_audit matches masked addresses ("Must*****llee" for "musterallee"),
--   which is how German utilities print a delivery point.
-- * v_purchase_rights counts the withdrawal period from the delivery mail when there is
--   one (§ 356 Abs. 2 BGB: from receipt of the goods), and says which start it used.
-- * v_system_health: text coverage counts only indexed documents (it could pass 100%),
--   plus four new counters appended.
-- * v_system_invariants: auto-renewals nobody watches, a stale off-site backup, a job
--   drifting from its slot, an expired title without successor, dead Drive links,
--   unmapped folders.
--
-- Views keep their columns; new ones are appended.

-- 1. Address audit: masked patterns ----------------------------------------------------

create or replace function public.address_pattern_regex(p text)
returns text language sql immutable set search_path to 'public' as $$
  -- full pattern, or (for patterns of 8+ letters) its first and last four characters
  -- around a run of letters or mask stars
  select case when length(p) >= 8
    then regexp_replace(lower(left(p, 4)), '([.^$|()\[\]{}*+?\\])', '\\\1', 'g')
         || '[[:alpha:]*]{2,}'
         || regexp_replace(lower(right(p, 4)), '([.^$|()\[\]{}*+?\\])', '\\\1', 'g')
    else regexp_replace(lower(p), '([.^$|()\[\]{}*+?\\])', '\\\1', 'g') end
$$;

create or replace view public.v_address_audit with (security_invoker = on) as
with pat as (
  select jsonb_array_elements_text(value) as p from life_settings where key = 'former_address_patterns'
), ign as (
  select jsonb_array_elements_text(value) as p from life_settings where key = 'address_audit_ignore'
), latest as (
  select distinct on (coalesce(e.vendor_entity_id::text, lower(coalesce(e.vendor, e.sender_name))))
         coalesce(e.vendor, e.sender_name) as counterparty, e.received_at, e.subject, e.gmail_url,
         exists (select 1 from pat
                 where e.content_excerpt ilike '%' || pat.p || '%'
                    or e.subject ilike '%' || pat.p || '%'
                    or lower(coalesce(e.content_excerpt, '') || ' ' || coalesce(e.subject, '')) ~ address_pattern_regex(pat.p)) as old_address
  from emails e
  where e.received_at > now() - interval '180 days'
    and e.category <> all (array['orders_delivery','purchases','other'])
  order by coalesce(e.vendor_entity_id::text, lower(coalesce(e.vendor, e.sender_name))), e.received_at desc
)
select counterparty, received_at::date as last_mail, subject, gmail_url
from latest
where old_address
  and not exists (select 1 from ign where latest.counterparty ilike '%' || ign.p || '%')
order by received_at desc;

-- 2. Purchase rights from delivery ------------------------------------------------------

create or replace view public.v_purchase_rights with (security_invoker = on) as
with rr as (select coalesce(setting('region_rules'), '{}'::jsonb) as v),
p as (
  select region_rule('consumer_withdrawal') as w,
         region_rule('statutory_warranty')  as g,
         coalesce((rr.v->>'purchase_rights_min_amount')::numeric, 50) as min_amount,
         coalesce(array(select jsonb_array_elements_text(rr.v->'purchase_rights_ignore')), '{}'::text[]) as ign
  from rr
),
e as (
  select e.*,
         (select coalesce(dm.event_date, dm.received_at::date)
            from emails dm
           where dm.category = 'orders_delivery'
             and dm.received_at >= e.received_at and dm.received_at < e.received_at + interval '60 days'
             and ((e.vendor_entity_id is not null and dm.vendor_entity_id = e.vendor_entity_id)
                  or (e.vendor is not null and lower(dm.vendor) = lower(e.vendor)))
           order by dm.received_at limit 1) as delivered_on
  from emails e, p
  where e.category = 'purchases' and e.amount >= p.min_amount
    and e.received_at > now() - interval '3 years'
    and not exists (select 1 from unnest(p.ign) i where coalesce(e.vendor, e.sender_name, '') ilike '%' || i || '%')
),
x as (
  select e.*, apply_term_rule(p.w, coalesce(e.delivered_on, e.received_at::date), true) as return_until,
              apply_term_rule(p.g, coalesce(e.delivered_on, e.received_at::date), true) as warranty_until
  from e, p
)
select id, received_at::date as bought, coalesce(vendor, sender_name) as vendor, item, amount, currency,
       return_until as return_until_approx, warranty_until,
       case when current_date <= return_until then 'return_possible'
            when current_date <= warranty_until then 'warranty'
            when warranty_until is null then 'unknown'
            else 'expired' end as state,
       gmail_url,
       delivered_on,
       case when delivered_on is not null then 'delivery_mail' else 'order_mail' end as start_basis
from x
order by received_at desc;
comment on view public.v_purchase_rights is 'Return and warranty windows for purchases, from region_rules (consumer_withdrawal, statutory_warranty). Counted from the delivery mail of the same vendor when one exists (start_basis = delivery_mail), else from the order mail, which errs early. state = unknown when the region pack has no such rule.';

-- 3. Health -------------------------------------------------------------------------------

create or replace view public.v_system_health with (security_invoker = on) as
select (select count(*) from documents where kind = 'document') as docs_formal,
       (select count(*) from v_untyped_documents) as docs_untyped,
       (select count(*) from v_missing_expiry) as docs_missing_expected_expiry,
       (select count(*) from v_missing_notice_period) as contracts_missing_notice_period,
       round(100.0 * (select count(*) from document_texts t join documents d on d.id = t.document_id
                      where t.extraction_status = 'done' and d.duplicate_of is null)::numeric
             / nullif((select count(*) from documents where duplicate_of is null), 0)::numeric, 1) as text_coverage_pct,
       (select count(*) from v_text_extraction_queue) as text_queue,
       (select count(*) from documents where expiry_date < current_date and status = 'current') as docs_expired_still_current,
       round(100.0 * (select count(*) from emails where category = 'bills_payments' and amount is not null)::numeric
             / nullif((select count(*) from emails where category = 'bills_payments'), 0)::numeric, 1) as bills_amount_extraction_pct,
       (select count(*) from emails where action_needed and todoist_task_id is null) as emails_action_no_task,
       (select count(*) from v_attachment_backlog) as attachment_backlog,
       (select count(*) from deadlines where status = 'open') as deadlines_open,
       (select count(*) from v_deadlines_due where todoist_task_id is null) as deadlines_no_task,
       (select count(*) from v_deadlines_missed where hard) as hard_deadlines_missed,
       (select round(sum(monthly_equivalent), 2) from recurring_payments where status = 'active') as monthly_committed,
       (select count(*) from v_renewal_watch where not deadline_recorded) as renewals_unwatched,
       (select count(*) from v_bundle_summary where status = 'open' and blocking > 0) as bundles_blocked,
       (select count(*) from briefings where briefing_date > current_date - 7 and sent) as briefings_sent_7d,
       (select count(*) from corrections where corrected_at > now() - interval '30 days') as corrections_30d,
       (select count(*) from improvement_proposals where status = 'open') as open_proposals,
       (select count(*) from v_intake_watchdog where overdue) as intakes_overdue,
       (select runs_7d from v_intake_watchdog where skill = 'email-intake') as email_runs_7d,
       (select round(extract(epoch from now() - max(taken_at)) / 3600.0, 1) from backup_snapshots) as hours_since_snapshot,
       (select round(extract(epoch from now() - max(run_at)) / 86400.0, 1) from backups) as days_since_offsite_backup,
       (select round(100.0 * sum(missed)::numeric / nullif(sum(sample_size), 0)::numeric, 1)
          from recall_samples where checked_at > now() - interval '60 days') as recall_miss_pct_60d,
       ((select coalesce(sum(jsonb_array_length(errors)), 0) from processing_runs where run_at > now() - interval '35 days')
        + (select coalesce(sum(jsonb_array_length(errors)), 0) from email_processing_runs where run_at > now() - interval '35 days')) as errors_35d,
       (select count(*) from v_auto_renew_unwatched) as auto_renew_unwatched,
       (select count(*) from v_expired_without_successor) as expired_without_successor,
       (select count(*) from documents where drive_missing_since is not null and duplicate_of is null and status = 'current') as docs_drive_missing,
       (select count(*) from v_unmapped_folders) as unmapped_folders;

-- 4. Invariants -----------------------------------------------------------------------------

create or replace view public.v_system_invariants with (security_invoker = on) as
select invariant, severity, failing, meaning from (values
  ('region_rules_missing', 'high', (select case when region_rules_missing() then 1 else 0 end)::bigint,
     'A region is set but its rules are not loaded, so no legal deadline is derived'),
  ('hard_deadline_unguarded', 'high', (select count(*) from v_hard_deadline_guard),
     'Hard deadline overdue or <30 days without a task'),
  ('legal_decision_without_date', 'high', (select count(*) from documents d
      where d.document_type_key in ('official_decision','tax_assessment') and d.issued_on is null
        and d.source_email_id is null and d.duplicate_of is null and d.status = 'current'
        and d.added_at > now() - interval '120 days'),
     'Official decision without issued_on, so no objection deadline could be derived'),
  ('intake_overdue', 'high', (select count(*) from v_intake_watchdog where overdue),
     'A scheduled skill or the bridge did not run'),
  ('attachment_backlog', 'high', (select count(*) from v_attachment_backlog),
     'In-scope mail the bridge has not copied'),
  ('expired_without_successor', 'high', (select count(*) from v_expired_without_successor),
     'An expired title or hard-deadline document has no successor for the same person'),
  ('payment_exceptions', 'medium', (select count(*) from v_payment_exceptions
      where exception in ('amount_changed','missing')),
     'Contract and bank disagree'),
  ('bank_data_stale', 'medium', (select case when min(days_stale) > 40 then 1 else 0 end from v_bank_coverage)::bigint,
     'Latest bank statement older than 40 days'),
  ('invoices_unmatched', 'medium', (select count(*) from v_invoice_reconciliation
      where period_covered and matched_tx is null),
     'Billed amount with no matching debit'),
  ('bundles_blocked', 'medium', (select count(*) from v_bundle_summary
      where status = 'open' and blocking > 0 and due_on is not null and due_on <= current_date + 60),
     'Bundle due within 60 days missing a required document'),
  ('stale_status', 'medium', (select count(*) from v_stale_status),
     'Expired documents still marked current'),
  ('auto_renew_unwatched', 'medium', (select count(*) from v_auto_renew_unwatched),
     'Auto-renewing contracts with no notice deadline, no end date and no notice period'),
  ('offsite_backup_stale', 'medium', (select case when coalesce(max(run_at) < now() - interval '35 days', true) then 1 else 0 end from backups)::bigint,
     'No off-site backup in the last 35 days'),
  ('intake_slot_drift', 'medium', (select count(*) from v_schedule_drift where drifted),
     'A night job started hours away from its scheduled slot'),
  ('drive_file_missing', 'medium', (select count(*) from documents
      where drive_missing_since is not null and duplicate_of is null and status = 'current'),
     'A current document whose Drive file is gone'),
  ('exit_unknown', 'low', (select count(*) from v_notice_calendar where not exit_known),
     'Obligations with no known notice period'),
  ('address_outdated', 'low', (select count(*) from v_address_audit),
     'Counterparties still writing to a former address'),
  ('untyped_documents', 'low', (select count(*) from v_untyped_documents),
     'Documents outside the registry'),
  ('unmapped_folders', 'low', (select count(*) from v_unmapped_folders),
     'Drive folders with indexed documents but no area')
) v(invariant, severity, failing, meaning);

revoke execute on function public.address_pattern_regex(text) from anon, authenticated, public;

-- 5. Version ----------------------------------------------------------------------------

update public.life_settings set value = '"0.6.0"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                         -- "0.6.0"
--   select 'must*****llee' ~ address_pattern_regex('musterallee');                 -- true
--   select invariant, failing from v_system_invariants where failing > 0;
--   select text_coverage_pct <= 100 from v_system_health;                                  -- true
