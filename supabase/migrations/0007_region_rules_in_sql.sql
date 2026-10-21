-- 0007: legal rules come from the region pack, not from SQL; settings keep a history;
-- deadlines remember which rule made them, so they can be recounted when the rules change.
--
-- Before this migration derive_deadlines(), v_purchase_rights and v_tax_items carried
-- German law in their code (one month plus four days, 14 days, two years, German tax
-- forms). Now they read life_settings.region_rules, which the setup skill fills from
-- packs/region/<code>/rules.json.
--
--   region set, rules present   the region's rules apply
--   region null                 a generic, deliberately early placeholder applies
--   region set, rules empty     nothing is derived and the nightly run reports an error:
--                               an installation upgraded from 0.2.0 must sync its pack first
--                               ("life os doctor" does it), rather than silently fall back.

-- 1. Settings history ------------------------------------------------------------------

create table if not exists public.settings_history (
  id uuid default gen_random_uuid() not null,
  key text not null,
  old_value jsonb,
  new_value jsonb,
  changed_at timestamp with time zone default clock_timestamp() not null,
  actor text,
  constraint settings_history_pkey primary key (id)
);
comment on table public.settings_history is 'Every change to life_settings, written by trigger. actor comes from app.actor (the setup skill sets life-os-setup); a change without it is a human edit. Lets any setting be read as of a date and rolled back.';
create index if not exists settings_history_key_idx on public.settings_history (key, changed_at desc);
alter table public.settings_history enable row level security;
revoke all on public.settings_history from anon, authenticated;
grant all on public.settings_history to service_role;

create or replace function public.log_setting_change()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if tg_op = 'UPDATE' and new.value is not distinct from old.value then
    return new;
  end if;
  insert into settings_history (key, old_value, new_value, actor)
  values (coalesce(new.key, old.key),
          case when tg_op = 'INSERT' then null else old.value end,
          case when tg_op = 'DELETE' then null else new.value end,
          coalesce(nullif(current_setting('app.actor', true), ''), 'human'));
  return coalesce(new, old);
end $$;

drop trigger if exists life_settings_history on public.life_settings;
create trigger life_settings_history after insert or update or delete on public.life_settings
  for each row execute function public.log_setting_change();

insert into public.life_settings (key, value) values
  ('installed_packs', '{"lang": {}, "region": {}}')
on conflict (key) do nothing;

-- 2. Deadlines remember their rule -----------------------------------------------------

alter table public.deadlines add column if not exists rule_key text;
alter table public.deadlines add column if not exists rule_version text;
comment on column public.deadlines.rule_key is 'The region_rules.term_rules key that computed due_on, if any. rederive_deadlines() recounts open deadlines by it when the rules change.';
comment on column public.deadlines.rule_version is 'region_rules.version at the time due_on was computed.';

-- Deadlines made by the old, German-only derive_deadlines() get their rule key back.
update public.deadlines dl
   set rule_key = case d.document_type_key when 'tax_assessment' then 'objection_tax'
                                           else 'objection_administrative' end,
       rule_version = 'sql-0.2'
  from public.documents d
 where dl.source_kind = 'document' and dl.source_id = d.id
   and dl.deadline_type = 'legal_response' and dl.rule_key is null
   and dl.notes like 'Derived by derive_deadlines()%';

-- 3. One interpreter for term rules, the same semantics as tests/test_packs.py ----------

create or replace function public.apply_term_rule(p_rule jsonb, p_start date,
                                                  p_actual_receipt boolean default false)
returns date language plpgsql immutable set search_path to 'public' as $$
-- p_actual_receipt: the start is the real day of receipt (an email), so the
-- notification_offset_days fiction for posted letters does not apply.
declare d date := p_start; s jsonb; t date;
begin
  if p_rule is null or p_start is null then return null; end if;
  if not p_actual_receipt then
    d := d + coalesce((p_rule->>'notification_offset_days')::int, 0);
  end if;
  for s in select * from jsonb_array_elements(coalesce(p_rule->'steps', '[]'::jsonb)) loop
    if s ? 'add_days' then
      d := d + (s->>'add_days')::int;
    elsif s ? 'add_months' then
      d := (d + make_interval(months => (s->>'add_months')::int))::date;
    elsif s ? 'term_months' then
      -- a term ends the day before the corresponding day, or on the last day of the
      -- month when there is no corresponding day
      t := (d + make_interval(months => (s->>'term_months')::int))::date;
      d := case when extract(day from t) < extract(day from d) then t else t - 1 end;
    elsif s ? 'end_of_month' then
      d := (date_trunc('month', d) + interval '1 month - 1 day')::date;
    else
      raise exception 'apply_term_rule: unknown step %', s;
    end if;
  end loop;
  if coalesce((p_rule->>'roll_to_business_day')::boolean, false) then
    while extract(isodow from d) >= 6 loop d := d + 1; end loop;
  end if;
  return d;
end $$;

create or replace function public.region_rule(p_key text)
returns jsonb language sql stable set search_path to 'public' as $$
  select x from jsonb_array_elements(coalesce(setting('region_rules')->'term_rules', '[]'::jsonb)) x
  where x->>'key' = p_key limit 1
$$;

create or replace function public.region_rules_missing()
returns boolean language sql stable set search_path to 'public' as $$
  select setting_text('region') is not null
     and jsonb_array_length(coalesce(setting('region_rules')->'term_rules', '[]'::jsonb)) = 0
$$;

-- 4. derive_deadlines() reads the rules ------------------------------------------------

create or replace function public.derive_deadlines()
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare
  n integer := 0; r record; rule jsonb; due date; basis text; lead int[];
  rules jsonb := coalesce(setting('region_rules')->'term_rules', '[]'::jsonb);
  version text := setting('region_rules')->>'version';
  no_region boolean := setting_text('region') is null;
  generic constant jsonb := '{
    "key": "objection_generic",
    "label": "Objection deadline (no region rules, check the letter)",
    "deadline_type": "legal_response", "start": "issued_on",
    "steps": [{"add_days": 14}], "roll_to_business_day": false,
    "hard": true, "lead_days": [7, 3, 1],
    "basis": "No region pack is installed. 14 days after the date on the letter is a deliberately early placeholder; the appeal instructions in the letter decide."
  }';
begin
  if region_rules_missing() then return 0; end if;

  for r in
    select d.id, d.name, d.document_type_key, d.issued_on, d.subject_person, d.issuer,
           (select e.received_at::date from emails e where e.id = d.source_email_id) as email_date
    from documents d
    where d.duplicate_of is null and d.status = 'current'
      and d.added_at > now() - interval '120 days'
      and (d.document_type_key in (select jsonb_array_elements_text(x->'applies_to')
                                   from jsonb_array_elements(rules) x
                                   where x->>'deadline_type' = 'legal_response' and x->>'start' = 'issued_on')
           or (no_region and d.document_type_key in ('official_decision','tax_assessment')))
      and not exists (select 1 from deadlines dl where dl.source_kind = 'document' and dl.source_id = d.id
                        and dl.deadline_type = 'legal_response')
  loop
    select x into rule from jsonb_array_elements(rules) x
     where x->>'deadline_type' = 'legal_response' and x->>'start' = 'issued_on'
       and x->'applies_to' ? r.document_type_key
     limit 1;
    if rule is null then rule := generic; end if;

    if r.issued_on is not null then
      due := apply_term_rule(rule, r.issued_on, false);
      basis := 'dated ' || to_char(r.issued_on, 'YYYY-MM-DD');
    elsif r.email_date is not null then
      due := apply_term_rule(rule, r.email_date, true);
      basis := 'received by email ' || to_char(r.email_date, 'YYYY-MM-DD');
    else
      continue;
    end if;
    if due < current_date - 7 then continue; end if;

    lead := array(select jsonb_array_elements_text(rule->'lead_days')::int);
    insert into deadlines (title, deadline_type, due_on, hard, lead_days, subject_person,
                           source_kind, source_id, status, notes, rule_key, rule_version)
    values (coalesce(rule->>'label', 'Objection deadline') || ': ' || coalesce(r.issuer || ' ', '') || r.name,
            'legal_response', due, coalesce((rule->>'hard')::boolean, true),
            case when cardinality(lead) > 0 then lead else array[30,14,7,3,1] end,
            r.subject_person, 'document', r.id, 'open',
            'Derived by derive_deadlines(): ' || basis || ', rule ' || (rule->>'key') || '. '
              || coalesce(rule->>'basis', '') || coalesce(' ' || (rule->>'notes'), ''),
            rule->>'key', case when rule->>'key' = 'objection_generic' then 'generic' else version end);
    n := n + 1;
  end loop;
  return n;
end $function$;

create or replace function public.run_nightly_derivations()
returns void language plpgsql security definer set search_path to 'public' as $function$
declare a int; b int; c int;
begin
  perform set_config('app.actor', 'skill', true);
  a := reconcile_passive_deadlines();
  b := link_bank_transactions();
  c := derive_deadlines();
  insert into derivation_runs (passive_closed, tx_linked, deadlines_derived, error)
  values (a, b, c, case when region_rules_missing()
                        then 'region is ' || setting_text('region') || ' but region_rules is empty: run "life os doctor" to sync the region pack'
                   end);
exception when others then
  insert into derivation_runs (error) values (sqlerrm);
end $function$;

-- 5. Recount open deadlines when the rules change --------------------------------------

create or replace function public.rederive_deadlines(p_apply boolean default false)
returns table (deadline_id uuid, title text, rule_key text, old_due date, new_due date, action text)
language plpgsql security definer set search_path to 'public' as $function$
-- Dry run by default: shows what would move. With p_apply = true, moves open deadlines to
-- the date the current rules give. Never touches a deadline without rule_key, never
-- closes or deletes one. action: moved | unchanged | rule_gone | no_start_date
declare r record; rule jsonb; nd date; version text := setting('region_rules')->>'version';
        prev_actor text := current_setting('app.actor', true);
begin
  if p_apply then perform set_config('app.actor', 'skill', true); end if;
  for r in
    select dl.id, dl.title, dl.rule_key, dl.due_on, d.issued_on,
           (select e.received_at::date from emails e where e.id = d.source_email_id) as email_date
    from deadlines dl join documents d on dl.source_kind = 'document' and d.id = dl.source_id
    where dl.status = 'open' and dl.rule_key is not null and dl.rule_key <> 'objection_generic'
    order by dl.due_on
  loop
    rule := region_rule(r.rule_key);
    deadline_id := r.id; title := r.title; rule_key := r.rule_key; old_due := r.due_on;
    if rule is null then
      new_due := null; action := 'rule_gone';
    else
      nd := case when r.issued_on is not null then apply_term_rule(rule, r.issued_on, false)
                 when r.email_date is not null then apply_term_rule(rule, r.email_date, true) end;
      new_due := nd;
      if nd is null then action := 'no_start_date';
      elsif nd = r.due_on then action := 'unchanged';
      else
        action := 'moved';
        if p_apply then
          update deadlines set due_on = nd, rule_version = version,
                 notes = coalesce(notes || E'\n', '') || 'Re-derived ' || to_char(clock_timestamp(), 'YYYY-MM-DD')
                         || ': ' || to_char(r.due_on, 'YYYY-MM-DD') || ' -> ' || to_char(nd, 'YYYY-MM-DD')
                         || ' (region_rules ' || coalesce(version, '?') || ').'
           where id = r.id;
        end if;
      end if;
    end if;
    return next;
  end loop;
  if p_apply then perform set_config('app.actor', coalesce(prev_actor, ''), true); end if;
end $function$;

-- 6. Purchase rights from the region ---------------------------------------------------

drop view if exists public.v_purchase_rights;
create view public.v_purchase_rights with (security_invoker = on) as
with rr as (select coalesce(setting('region_rules'), '{}'::jsonb) as v),
p as (
  select region_rule('consumer_withdrawal') as w,
         region_rule('statutory_warranty')  as g,
         coalesce((rr.v->>'purchase_rights_min_amount')::numeric, 50) as min_amount,
         coalesce(array(select jsonb_array_elements_text(rr.v->'purchase_rights_ignore')), '{}'::text[]) as ign
  from rr
),
e as (
  select e.*, apply_term_rule(p.w, e.received_at::date, true) as return_until,
              apply_term_rule(p.g, e.received_at::date, true) as warranty_until
  from emails e, p
  where e.category = 'purchases' and e.amount >= p.min_amount
    and e.received_at > now() - interval '3 years'
    and not exists (select 1 from unnest(p.ign) i where coalesce(e.vendor, e.sender_name, '') ilike '%' || i || '%')
)
select id, received_at::date as bought, coalesce(vendor, sender_name) as vendor, item, amount, currency,
       return_until as return_until_approx, warranty_until,
       case when current_date <= return_until then 'return_possible'
            when current_date <= warranty_until then 'warranty'
            when warranty_until is null then 'unknown'
            else 'expired' end as state,
       gmail_url
from e
order by received_at desc;
comment on view public.v_purchase_rights is 'Return and warranty windows for purchases, from region_rules (consumer_withdrawal, statutory_warranty), counted from the order mail, so they err early. state = unknown when the region pack has no such rule.';

-- 7. Tax labels from the region --------------------------------------------------------

create or replace view public.v_tax_items with (security_invoker = on) as
with y as (select (value #>> '{}')::integer as yr from life_settings where key = 'tax_year')
select tax_relevance, name, vendor, amount, period,
       (select round(sum(t.amount), 2) from bank_transactions t, y
         where t.recurring_payment_id = rp.id and extract(year from t.booked_on) = y.yr) as paid_per_bank,
       round(monthly_equivalent * 12, 2) as annual_estimate,
       setting('region_rules')->'tax_relevance_labels'->>tax_relevance as where_it_goes
from recurring_payments rp
where status = 'active' and tax_relevance is not null and tax_relevance <> 'none'
order by tax_relevance, name;

-- 8. The invariant that catches an unsynced pack ---------------------------------------

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
  ('exit_unknown', 'low', (select count(*) from v_notice_calendar where not exit_known),
     'Obligations with no known notice period'),
  ('address_outdated', 'low', (select count(*) from v_address_audit),
     'Counterparties still writing to a former address'),
  ('untyped_documents', 'low', (select count(*) from v_untyped_documents),
     'Documents outside the registry')
) v(invariant, severity, failing, meaning);

-- 9. Privileges and version ------------------------------------------------------------

revoke execute on function public.log_setting_change(), public.apply_term_rule(jsonb, date, boolean),
  public.region_rule(text), public.region_rules_missing(), public.derive_deadlines(),
  public.run_nightly_derivations(), public.rederive_deadlines(boolean)
  from anon, authenticated, public;
grant execute on function public.apply_term_rule(jsonb, date, boolean), public.region_rule(text),
  public.region_rules_missing(), public.rederive_deadlines(boolean) to service_role;

update public.life_settings set value = '"0.3.0"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"');
