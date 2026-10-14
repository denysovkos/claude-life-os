-- 0012: auto-renewing contracts can no longer hide.
--
-- * utility_contract expects a notice period (supply contracts with a minimum term renew
--   themselves). Grid-operator and meter letters move to the new type utility_notice.
-- * v_auto_renew_unwatched lists auto-renewing payments with no notice_period deadline
--   and neither a contract end nor a notice period on record: the one combination that
--   no other view reported.
-- * contract_cancel_by() / contract_term_end(): the arithmetic for a contract's own term
--   and notice period, through apply_term_rule(), so nobody counts it by hand.
--
-- Additive. v_renewal_watch is unchanged (it lists fixed-term contracts, as before),
-- because a skill one version older reads it with that meaning.

-- 1. Registry -------------------------------------------------------------------------------

insert into public.document_types select * from json_populate_record(null::public.document_types, '{"key":"utility_notice","label":"Utility / grid operator notice","domain":"services","expiry_expected":false,"notice_period_expected":false,"hard_deadline":false,"applies_to_kind":"document","description":"Grid operator or metering letters, meter readings, price notices without a contract of their own. No notice period.","hints":["Netzbetreiber","Messstellenbetreiber","Zählerstand","Zählerwechsel","Ablesung"],"active":true}') on conflict (key) do nothing;

update public.document_types set notice_period_expected = true
where key = 'utility_contract' and not notice_period_expected;

-- the old default label and hints covered both kinds; change them only if nobody edited them
update public.document_types
set label = 'Utility supply contract',
    description = 'Electricity, gas, heating or water supply contract with a term. Usually renews itself; the cancellation date is the deadline.',
    hints = array['Stromliefervertrag','Gasliefervertrag','Vertragsbestätigung','Mindestvertragslaufzeit','Abschlag']
where key = 'utility_contract' and label = 'Utility / grid operator contract or notice';

-- 2. Contract arithmetic -------------------------------------------------------------------

create or replace function public.contract_term_end(p_start date, p_term_months integer)
returns date language sql immutable set search_path to 'public' as $$
  -- last day of a term that starts on p_start (§ 188 BGB style: the day before the
  -- corresponding day, or the month's last day when there is none)
  select apply_term_rule(jsonb_build_object('steps', jsonb_build_array(jsonb_build_object('term_months', p_term_months))),
                         p_start, true)
$$;

create or replace function public.contract_cancel_by(p_start date, p_term_months integer, p_notice_months integer)
returns date language sql immutable set search_path to 'public' as $$
  -- last day the cancellation must arrive to end the contract at the end of its first term
  select apply_term_rule(jsonb_build_object('steps', jsonb_build_array(
                           jsonb_build_object('term_months', p_term_months),
                           jsonb_build_object('add_months', -p_notice_months))),
                         p_start, true)
$$;

revoke execute on function public.contract_term_end(date, integer), public.contract_cancel_by(date, integer, integer)
  from anon, authenticated, public;
grant execute on function public.contract_term_end(date, integer), public.contract_cancel_by(date, integer, integer)
  to service_role;

-- 3. The gap no view reported --------------------------------------------------------------

create or replace view public.v_auto_renew_unwatched with (security_invoker = on) as
select rp.id, rp.name, rp.vendor, rp.amount, rp.period, rp.monthly_equivalent, rp.document_id,
       rp.contract_start, rp.contract_end, rp.notice_period_months
from recurring_payments rp
where rp.status = 'active' and rp.auto_renews
  and rp.contract_end is null and rp.notice_period_months is null
  and not exists (select 1 from deadlines dl
                  where dl.deadline_type = 'notice_period' and dl.status in ('open','done')
                    and (dl.id = rp.deadline_id
                         or (rp.document_id is not null and dl.source_kind = 'document' and dl.source_id = rp.document_id)))
order by rp.monthly_equivalent desc nulls last, rp.name;
comment on view public.v_auto_renew_unwatched is 'Auto-renewing payments with no notice_period deadline, no contract_end and no notice period: nothing can warn before they renew. Fill them from the contract (life-review step 5), or record notice_period_months for a contract cancellable any time.';

-- Verification:
--   select contract_cancel_by('2026-08-24', 24, 1);   -- 2028-07-23 (Telekom, carrier-stated)
--   select contract_cancel_by('2026-08-22', 12, 1);   -- 2027-07-21 (gas supply, stated)
--   select notice_period_expected from document_types where key = 'utility_contract';  -- true
--   select count(*) from v_auto_renew_unwatched;
