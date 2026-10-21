-- Functions. Bodies are not validated at creation, so order does not matter.
-- Exported from the reference deployment. Do not edit by hand; add a new migration instead.

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.ask_documents(q text, n integer DEFAULT 8)
 RETURNS TABLE(kind text, id uuid, title text, url text, rank real, snippet text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with query as (select websearch_to_tsquery('simple', q) as tq)
  select * from (
    select 'document'::text, d.id, d.name, d.drive_url, ts_rank_cd(t.tsv, query.tq),
           ts_headline('simple', t.body, query.tq, 'MaxFragments=3,MaxWords=35,MinWords=12,FragmentDelimiter= … ')
    from document_texts t join documents d on d.id = t.document_id, query
    where t.tsv @@ query.tq and d.duplicate_of is null
    union all
    select 'email', e.id, e.subject, e.gmail_url, ts_rank_cd(e.tsv, query.tq),
           ts_headline('simple', coalesce(e.summary,'') || ' ' || coalesce(e.content_excerpt,''), query.tq, 'MaxFragments=2,MaxWords=30,MinWords=10')
    from emails e, query
    where e.tsv @@ query.tq
  ) x order by 5 desc limit n
$function$;

CREATE OR REPLACE FUNCTION public.bridge_in_scope(cat text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select cat = any (array['legal_notary','government','bank_finance','bills_payments'])
$function$;

CREATE OR REPLACE FUNCTION public.brief_item_count()
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select (build_briefing(current_date)->>'item_count')::int;
$function$;

CREATE OR REPLACE FUNCTION public.briefing_should_send(p_date date DEFAULT CURRENT_DATE)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select
    (build_briefing(p_date)->>'item_count')::int > 0
    or extract(isodow from p_date) = 1;  -- Monday heartbeat, so silence stays trustworthy
$function$;

CREATE OR REPLACE FUNCTION public.briefing_text(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare
  b jsonb := build_briefing(p_date);
  out text := '';
  it jsonb;
  k text;
begin
  if jsonb_array_length(b->'overdue_hard') > 0 then
    out := out || 'OVERDUE (hard)' || E'\n';
    for it in select * from jsonb_array_elements(b->'overdue_hard') loop
      out := out || format('  · %s — %s days past %s%s',
        it->>'title', it->>'days_overdue', it->>'due_on',
        case when it->>'person' is not null then ' (' || (it->>'person') || ')' else '' end) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'overdue_soft') > 0 then
    out := out || 'OVERDUE (soft, weekly reminder)' || E'\n';
    for it in select * from jsonb_array_elements(b->'overdue_soft') loop
      out := out || format('  · %s — %s days past %s', it->>'title', it->>'days_overdue', it->>'due_on') || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'due_now') > 0 then
    out := out || 'COMING UP' || E'\n';
    for it in select * from jsonb_array_elements(b->'due_now') loop
      out := out || format('  · %s — in %s days (%s)%s%s',
        it->>'title', it->>'days_left', it->>'due_on',
        case when (it->>'hard')::boolean then '  [hard]' else '' end,
        case when (it->>'has_task')::boolean then '' else '  [no task yet]' end) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'money_next_14d') > 0 then
    out := out || 'MONEY — next 14 days' || E'\n';
    for it in select * from jsonb_array_elements(b->'money_next_14d') loop
      out := out || format('  · %s %s — %s, due %s',
        it->>'amount', coalesce(it->>'currency','EUR'), it->>'vendor', it->>'due_date') || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'new_actions') > 0 then
    out := out || 'NEW SINCE YESTERDAY' || E'\n';
    for it in select * from jsonb_array_elements(b->'new_actions') loop
      out := out || format('  · %s — %s%s', it->>'sender', it->>'note',
        case when (it->>'has_task')::boolean then '' else '  [no task yet]' end) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if b->'anomalies' is not null and b->'anomalies' <> '{}'::jsonb then
    out := out || 'SYSTEM' || E'\n';
    for k in select * from jsonb_object_keys(b->'anomalies') loop
      out := out || format('  · %s: %s', replace(k,'_',' '), b->'anomalies'->>k) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if out = '' then
    out := 'Nothing due, nothing owed, nothing broken.' || E'\n';
  end if;

  return out;
end;
$function$;

CREATE OR REPLACE FUNCTION public.build_briefing(p_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
with
overdue_hard as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', subject_person, 'type', deadline_type) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and hard
    and (snoozed_until is null or snoozed_until <= p_date)
),
overdue_soft as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', subject_person, 'type', deadline_type) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and not hard
    and (snoozed_until is null or snoozed_until <= p_date) and (p_date - due_on) % 7 = 0
),
due_now as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_left', due_on - p_date,
    'hard', hard, 'person', subject_person, 'type', deadline_type,
    'has_task', todoist_task_id is not null) order by due_on)
  from deadlines where status = 'open' and due_on >= p_date
    and (snoozed_until is null or snoozed_until <= p_date)
    and ((due_on - p_date) = any(lead_days) or (due_on - p_date) <= 1)
),
money as (
  select jsonb_agg(jsonb_build_object('vendor', coalesce(vendor, sender_name), 'what', coalesce(item, subject),
    'amount', amount, 'currency', currency, 'due_date', due_date) order by due_date)
  from emails where due_date between p_date and p_date + 14 and amount is not null
),
new_actions as (
  select jsonb_agg(jsonb_build_object('subject', subject, 'sender', sender_name, 'category', category,
    'note', action_note, 'due_date', due_date, 'has_task', todoist_task_id is not null) order by received_at desc)
  from emails where action_needed and received_at > (p_date - 1)::timestamptz
),
anomalies as (
  select jsonb_strip_nulls(jsonb_build_object(
    'expired_but_current', nullif((select count(*) from documents where expiry_date < p_date and status = 'current'), 0),
    'contracts_without_notice_period', nullif((select count(*) from v_missing_notice_period), 0),
    'untyped_documents', nullif((select count(*) from v_untyped_documents), 0),
    'documents_needing_review', nullif((select count(*) from documents where needs_review), 0),
    'attachment_backlog', nullif((select count(*) from v_attachment_backlog), 0),
    'deadlines_without_task', nullif((select count(*) from v_deadlines_due where todoist_task_id is null), 0),
    'intake_overdue', nullif((select count(*) from v_intake_watchdog where overdue), 0),
    'email_runs_last_7d_expected_7', (select runs_7d from v_intake_watchdog where skill='email-intake'),
    'errors_last_7d', nullif((select coalesce(sum(jsonb_array_length(errors)),0)
                              from email_processing_runs where run_at > p_date::timestamptz - interval '7 days')::int, 0),
    'snapshot_age_hours', (select case when max(taken_at) < now() - interval '48 hours'
        then round(extract(epoch from now() - max(taken_at))/3600.0) end from backup_snapshots),
    'open_proposals', nullif((select count(*) from improvement_proposals where status = 'open'), 0),
    'hard_deadlines_unguarded', nullif((select count(*) from v_hard_deadline_guard), 0),
    'legal_decisions_without_date', nullif((select failing from v_system_invariants where invariant = 'legal_decision_without_date'), 0),
    'payment_exceptions', nullif((select failing from v_system_invariants where invariant = 'payment_exceptions'), 0),
    'bank_data_stale', nullif((select failing from v_system_invariants where invariant = 'bank_data_stale'), 0),
    'nightly_derivations_failed', (select case when max(ran_at) filter (where error is null) < now() - interval '36 hours'
                                             or max(ran_at) is null then 1 end from derivation_runs)
  )) as a
)
select jsonb_build_object(
  'date', p_date,
  'overdue_hard', coalesce((select * from overdue_hard), '[]'::jsonb),
  'overdue_soft', coalesce((select * from overdue_soft), '[]'::jsonb),
  'due_now', coalesce((select * from due_now), '[]'::jsonb),
  'money_next_14d', coalesce((select * from money), '[]'::jsonb),
  'new_actions', coalesce((select * from new_actions), '[]'::jsonb),
  'anomalies', (select a from anomalies),
  'item_count',
    jsonb_array_length(coalesce((select * from overdue_hard), '[]'::jsonb)) +
    jsonb_array_length(coalesce((select * from overdue_soft), '[]'::jsonb)) +
    jsonb_array_length(coalesce((select * from due_now), '[]'::jsonb)) +
    jsonb_array_length(coalesce((select * from money), '[]'::jsonb)) +
    jsonb_array_length(coalesce((select * from new_actions), '[]'::jsonb)) +
    (select count(*) from jsonb_object_keys((select a from anomalies)))
);
$function$;

CREATE OR REPLACE FUNCTION public.daily_brief()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select build_briefing(current_date);
$function$;

CREATE OR REPLACE FUNCTION public.derive_deadlines()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer := 0; r record; base date; due date; basis text;
begin
  for r in
    select d.id, d.name, d.document_type_key, d.issued_on, d.subject_person, d.issuer,
           (select e.received_at::date from emails e where e.id = d.source_email_id) as email_date
    from documents d
    where d.document_type_key in ('official_decision','tax_assessment')
      and d.duplicate_of is null and d.status = 'current'
      and d.added_at > now() - interval '120 days'
      and not exists (select 1 from deadlines dl where dl.source_kind = 'document' and dl.source_id = d.id
                        and dl.deadline_type = 'legal_response')
  loop
    if r.issued_on is not null then
      base := r.issued_on + 4; basis := 'Bescheiddatum ' || to_char(r.issued_on,'DD.MM.YYYY') || ' + 4 Tage Bekanntgabefiktion';
    elsif r.email_date is not null then
      base := r.email_date; basis := 'Eingang per E-Mail ' || to_char(r.email_date,'DD.MM.YYYY');
    else
      continue;
    end if;
    due := (base + interval '1 month')::date;
    if due < current_date - 7 then continue; end if;
    insert into deadlines (title, deadline_type, due_on, hard, lead_days, subject_person, source_kind, source_id, status, notes)
    values (case when r.document_type_key = 'tax_assessment' then 'Einspruchsfrist' else 'Widerspruchsfrist (prüfen, ob nötig)' end
              || ': ' || coalesce(r.issuer, '') || ' ' || r.name,
            'legal_response', due, true, array[30,14,7,3,1], r.subject_person, 'document', r.id, 'open',
            'Derived by derive_deadlines(): ' || basis || ' + 1 Monat (§ 355 AO / § 70 VwGO). '
            || 'Ohne Rechtsbehelfsbelehrung gilt 1 Jahr. Bei positivem Bescheid einfach schließen.');
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.emergency_dossier()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select concat_ws(E'\n',
 '# Notfallordner (згенеровано ' || to_char(now() at time zone 'Europe/Berlin','DD.MM.YYYY') || ')',
 'Автоматично зібрано з індексу документів. Якщо щось не так, найсвіжіше джерело це Supabase і Google Drive.',
 '', '## Відкриті справи і що з ними робити',
 coalesce((select string_agg('- ' || m.name || coalesce(' (' || m.reference || ')','') || coalesce(': ' || m.next_action,'')
                             || coalesce(' до ' || to_char(m.next_action_on,'DD.MM.YYYY'),''), E'\n' order by m.next_action_on nulls last)
           from matters m where m.status not in ('closed','done')), '- немає'),
 '', '## Незворотні строки (hard deadlines)',
 coalesce((select string_agg('- ' || to_char(d.due_on,'DD.MM.YYYY') || ': ' || d.title, E'\n' order by d.due_on)
           from deadlines d where d.status = 'open' and d.hard and d.due_on >= current_date - 30), '- немає'),
 '', '## Кредити і лізинг',
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' EUR/' || rp.period
                             || coalesce(', до ' || to_char(rp.contract_end,'DD.MM.YYYY'),'') || coalesce(', Ref. ' || rp.reference,''), E'\n')
           from recurring_payments rp where rp.status='active' and rp.category='loan'), '- немає'),
 '', '## Страховки',
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' EUR/' || rp.period
                             || coalesce(', Ref. ' || rp.reference,'') || coalesce(', Kündigung ' || rp.notice_period_months || ' Mon.',''), E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category in ('insurance','pension') and rp.amount > 0), '- немає'),
 '', '## Житло, зв''язок, підписки (що можна призупинити або скасувати)',
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' EUR/' || rp.period
                             || case when rp.notice_period_months is not null then ', Kündigung ' || rp.notice_period_months || ' Mon.' else ', строк розірвання невідомий' end, E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category not in ('loan','insurance','pension') and rp.amount > 0), '- немає'),
 '', 'Разом регулярних зобов''язань: ' || (select round(sum(monthly_equivalent),2) from recurring_payments where status='active') || ' EUR на місяць.',
 '', '## Документи особи і де оригінали',
 coalesce((select string_agg('- ' || coalesce(d.subject_person,'?') || ': ' || t.label || coalesce(', дійсний до ' || to_char(d.expiry_date,'DD.MM.YYYY'),'')
                             || coalesce(', оригінал: ' || d.physical_location,'') || ' — ' || d.drive_url, E'\n' order by d.subject_person, t.label)
           from documents d join document_types t on t.key = d.document_type_key
           where t.domain = 'identity' and d.duplicate_of is null and d.status = 'current'), '- немає'),
 '', '## Нерухомість',
 coalesce((select string_agg('- ' || t.label || ': ' || d.name || coalesce(', оригінал: ' || d.physical_location,'') || ' — ' || d.drive_url, E'\n' order by t.label)
           from documents d join document_types t on t.key = d.document_type_key
           where t.domain = 'property' and d.duplicate_of is null and d.status = 'current'
             and t.key in ('purchase_contract','land_registry_extract','mortgage_contract','mortgage_deed','weg_document')), '- немає'),
 '', '## Контакти',
 coalesce((select string_agg('- ' || (c->>'name') || ' (' || (c->>'role') || ')' || coalesce(', ' || (c->>'contact'), '') , E'\n')
           from life_settings s, jsonb_array_elements(s.value) c where s.key = 'emergency_contacts'), ''),
 coalesce((select string_agg(distinct '- ' || e.name || coalesce(' (' || e.role || ')','') || coalesce(', ' || array_to_string(e.emails, ', '),''), E'\n')
           from entities e
           where e.id in (select vendor_entity_id from recurring_payments where status='active')
              or e.role ~* 'lawyer|anwält|notar|hausverwalt|bank|berater|advisor'), '- немає')
)
$function$;

CREATE OR REPLACE FUNCTION public.guard_staging_delete()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if exists (select 1 from documents d where d.drive_file_id = old.drive_file_id) then
    raise exception 'attachment_staging % backs document %, refusing delete', old.id,
      (select d.id from documents d where d.drive_file_id = old.drive_file_id limit 1);
  end if;
  return old;
end $function$;

CREATE OR REPLACE FUNCTION public.link_bank_transactions()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  with cand as (
    select t.id as tx_id, rp.id as rp_id,
           abs(t.amount - rp.amount) as amount_diff,
           greatest(similarity(lower(t.counterparty), lower(rp.vendor)),
                    similarity(lower(t.counterparty), lower(rp.name)),
                    case when t.counterparty_entity_id is not null and t.counterparty_entity_id = rp.vendor_entity_id then 1 else 0 end,
                    case when rp.reference is not null and length(rp.reference) >= 6
                              and coalesce(t.reference,'') ilike '%' || rp.reference || '%' then 1 else 0 end) as sim
    from bank_transactions t
    join recurring_payments rp on rp.amount > 0
    where t.recurring_payment_id is null and t.direction = 'debit'
      and abs(t.amount - rp.amount) <= greatest(1.0, rp.amount * 0.25)
  ),
  ranked as (
    select *, row_number() over (partition by tx_id order by sim desc, amount_diff) rn,
              count(*) over (partition by tx_id) as n_cand
    from cand where sim >= 0.35
  )
  update bank_transactions t set recurring_payment_id = r.rp_id
  from ranked r where r.tx_id = t.id and r.rn = 1;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.log_correction()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  k text; oldv jsonb; newv jsonb;
  actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'human');
begin
  if new.last_intake_at is distinct from old.last_intake_at
     or new.last_intake_at >= transaction_timestamp() then
    return new;
  end if;
  oldv := to_jsonb(old); newv := to_jsonb(new);
  for k in select jsonb_object_keys(newv) loop
    if k in ('updated_at','added_at','last_intake_at','id','content_fingerprint','body_fingerprint',
             'todoist_task_id','calendar_event_id','attachments_extracted') then
      continue;
    end if;
    if (oldv -> k) is distinct from (newv -> k) then
      insert into corrections (table_name, row_id, field, old_value, new_value, source)
      values (tg_table_name, new.id, k, oldv ->> k, newv ->> k, actor);
    end if;
  end loop;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.match_rules(p_scope text, p_sender_email text DEFAULT NULL::text, p_sender_name text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_file_name text DEFAULT NULL::text, p_issuer text DEFAULT NULL::text)
 RETURNS SETOF classification_rules
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select r.* from classification_rules r
  where r.active and r.scope = p_scope
    and case r.match_field
      when 'sender_email'  then lower(coalesce(p_sender_email,'')) = lower(r.match_value)
      when 'sender_domain' then lower(coalesce(p_sender_email,'')) like '%@%' || lower(r.match_value)
      when 'sender_name'   then lower(coalesce(p_sender_name,'')) like '%' || lower(r.match_value) || '%'
      when 'subject'       then lower(coalesce(p_subject,'')) like '%' || lower(r.match_value) || '%'
      when 'file_name'     then lower(coalesce(p_file_name,'')) like '%' || lower(r.match_value) || '%'
      when 'issuer'        then lower(coalesce(p_issuer,'')) like '%' || lower(r.match_value) || '%'
      else false end
  order by r.priority, r.created_at;
$function$;

CREATE OR REPLACE FUNCTION public.monthly_review(p_month date DEFAULT (date_trunc('month'::text, (CURRENT_DATE - '1 day'::interval)))::date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
with m as (select date_trunc('month', p_month)::date as s, (date_trunc('month', p_month) + interval '1 month')::date as e)
select jsonb_build_object(
 'month', to_char(m.s, 'YYYY-MM'),
 'obligations', jsonb_build_object(
    'monthly_total', (select round(sum(monthly_equivalent),2) from recurring_payments where status='active'),
    'added', (select coalesce(jsonb_agg(name), '[]') from recurring_payments where created_at >= m.s and created_at < m.e),
    'exit_unknown', (select count(*) from v_notice_calendar where not exit_known),
    'cancel_by_next_90d', (select coalesce(jsonb_agg(jsonb_build_object('name',name,'cancel_by',cancel_by)), '[]')
                           from v_notice_calendar where cancel_by between current_date and current_date + 90 and contract_end is not null)),
 'bank', jsonb_build_object(
    'coverage', (select coalesce(jsonb_agg(c), '[]') from v_bank_coverage c),
    'spend_by_counterparty', (select coalesce(jsonb_agg(x), '[]') from (
        select counterparty, round(sum(amount),2) as total, count(*) as n from bank_transactions
        where direction = 'debit' and booked_on >= m.s and booked_on < m.e and recurring_payment_id is null
          and method not in ('transfer')
        group by counterparty order by 2 desc limit 12) x),
    'payment_exceptions', (select coalesce(jsonb_agg(x), '[]') from (select exception, name, expected, last_amount, last_seen, explanation from v_payment_exceptions) x),
    'invoices_unmatched', (select count(*) from v_invoice_reconciliation where period_covered and matched_tx is null)),
 'deadlines', jsonb_build_object(
    'closed', (select count(*) from deadlines where status = 'done' and updated_at >= m.s and updated_at < m.e),
    'missed_hard', (select count(*) from v_hard_deadline_guard where problem = 'overdue')),
 'address_audit', (select coalesce(jsonb_agg(counterparty), '[]') from v_address_audit),
 'tax', (select coalesce(jsonb_agg(x), '[]') from (select tax_relevance, name, paid_per_bank, annual_estimate from v_tax_items) x),
 'system_quality', jsonb_build_object(
    'human_corrections', (select coalesce(jsonb_object_agg(field, n), '{}') from (select field, count(*) n from corrections where source = 'human' and corrected_at >= m.s and corrected_at < m.e group by field) c),
    'emails_other_pct', (select round(100.0 * count(*) filter (where category = 'other') / nullif(count(*),0), 1) from emails where received_at >= m.s and received_at < m.e),
    'rules_zero_hits', (select count(*) from classification_rules where coalesce(hits,0) = 0),
    'documents_needs_review', (select count(*) from documents where needs_review),
    'unresolved_entities', (select count(*) from v_unresolved_entities),
    'recall_miss_pct', (select round(100.0 * sum(missed) / nullif(sum(sample_size),0), 1) from recall_samples where checked_at >= m.s - interval '30 days'))
) from m
$function$;

CREATE OR REPLACE FUNCTION public.reconcile_passive_deadlines()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n integer;
begin
  update deadlines
     set status = 'done',
         notes = coalesce(notes || E'\n', '') || 'Auto-closed ' || to_char(clock_timestamp(), 'YYYY-MM-DD')
                 || ': passive payment_due, no task, due + 3 days passed.'
   where status = 'open' and deadline_type = 'payment_due' and todoist_task_id is null
     and due_on + 3 < current_date;
  get diagnostics n = row_count;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.resolve_document_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if new.document_type_key is null and new.document_type is not null then
    select type_key into new.document_type_key
    from document_type_aliases where alias = lower(new.document_type);
  end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.run_nightly_derivations()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a int; b int; c int;
begin
  perform set_config('app.actor', 'skill', true);
  a := reconcile_passive_deadlines();
  b := link_bank_transactions();
  c := derive_deadlines();
  insert into derivation_runs (passive_closed, tx_linked, deadlines_derived) values (a, b, c);
exception when others then
  insert into derivation_runs (error) values (sqlerrm);
end $function$;

CREATE OR REPLACE FUNCTION public.search_all(q text, max_results integer DEFAULT 10)
 RETURNS TABLE(source text, ref uuid, title text, context text, dated date, url text, rank real, snippet text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select 'document', document_id, name,
         concat_ws(' · ', type_label, issuer, subject_person, status), expiry_date, drive_url, rank, snippet
  from search_documents(q, max_results)
  union all
  select 'email', email_id, subject,
         concat_ws(' · ', sender_name, category, nullif(amount::text,'')), received_at::date, gmail_url, rank, snippet
  from search_emails(q, max_results)
  union all
  select 'note', note_id, title, concat_ws(' · ', kind, matter), decided_on, null, rank, snippet
  from search_notes(q, max_results)
  order by rank desc limit greatest(1, max_results);
$function$;

CREATE OR REPLACE FUNCTION public.search_documents(q text, max_results integer DEFAULT 10)
 RETURNS TABLE(document_id uuid, name text, type_label text, issuer text, subject_person text, status text, expiry_date date, drive_url text, rank real, match_kind text, snippet text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with qq as (select websearch_to_tsquery('simple', q) as tsq),
  fts as (
    select t.document_id, ts_rank_cd(t.tsv, qq.tsq)::real as rank, 'fts'::text as kind,
           ts_headline('simple', coalesce(t.body, t.search_title), qq.tsq,
                       'MaxFragments=2,MinWords=6,MaxWords=22,FragmentDelimiter= … ') as snip
    from document_texts t, qq
    where qq.tsq is not null and t.tsv @@ qq.tsq
  ),
  trg as (
    select t.document_id,
           (0.3 * similarity(coalesce(t.body,'') , q))::real as rank, 'substring'::text as kind,
           substring(t.body from greatest(1, position(lower(q) in lower(t.body)) - 60) for 200) as snip
    from document_texts t
    where length(q) >= 4
      and (t.body ilike '%' || q || '%' or t.search_title ilike '%' || q || '%')
      and not exists (select 1 from fts where fts.document_id = t.document_id)
  ),
  hits as (select * from fts union all select * from trg)
  select d.id, d.name, dt.label, d.issuer, d.subject_person, d.status, d.expiry_date,
         d.drive_url, h.rank, h.kind, h.snip
  from hits h
  join documents d on d.id = h.document_id
  left join document_types dt on dt.key = d.document_type_key
  where d.duplicate_of is null
  order by h.rank desc, d.added_at desc
  limit greatest(1, max_results);
$function$;

CREATE OR REPLACE FUNCTION public.search_emails(q text, max_results integer DEFAULT 10)
 RETURNS TABLE(email_id uuid, subject text, sender_name text, category text, received_at timestamp with time zone, amount numeric, gmail_url text, rank real, snippet text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with qq as (select websearch_to_tsquery('simple', q) as tsq)
  select e.id, e.subject, e.sender_name, e.category, e.received_at, e.amount, e.gmail_url,
         ts_rank_cd(e.tsv, qq.tsq)::real,
         ts_headline('simple', coalesce(e.summary, e.content_excerpt, e.subject), qq.tsq,
                     'MaxFragments=1,MinWords=6,MaxWords=24')
  from emails e, qq
  where qq.tsq is not null and e.tsv @@ qq.tsq
  order by ts_rank_cd(e.tsv, qq.tsq) desc, e.received_at desc
  limit greatest(1, max_results);
$function$;

CREATE OR REPLACE FUNCTION public.search_notes(q text, max_results integer DEFAULT 10)
 RETURNS TABLE(note_id uuid, title text, kind text, matter text, decided_on date, rank real, snippet text)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  with qq as (select websearch_to_tsquery('simple', q) as tsq)
  select n.id, n.title, n.kind, m.name, n.decided_on,
         ts_rank_cd(n.tsv, qq.tsq)::real,
         ts_headline('simple', n.body, qq.tsq, 'MaxFragments=1,MinWords=6,MaxWords=24')
  from notes n left join matters m on m.id = n.matter_id, qq
  where qq.tsq is not null and n.tsv @@ qq.tsq
  order by 6 desc limit greatest(1, max_results);
$function$;

CREATE OR REPLACE FUNCTION public.set_emails_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.snapshot_diff(p_snapshot_id uuid)
 RETURNS TABLE(tbl text, in_snapshot integer, now_present integer, delta integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select k as tbl,
         (s.row_counts ->> k)::int as in_snapshot,
         case k
           when 'documents' then (select count(*)::int from documents)
           when 'emails' then (select count(*)::int from emails)
           when 'deadlines' then (select count(*)::int from deadlines)
           when 'corrections' then (select count(*)::int from corrections)
           when 'improvement_proposals' then (select count(*)::int from improvement_proposals)
           when 'skill_revisions' then (select count(*)::int from skill_revisions)
         end as now_present,
         case k
           when 'documents' then (select count(*)::int from documents)
           when 'emails' then (select count(*)::int from emails)
           when 'deadlines' then (select count(*)::int from deadlines)
           when 'corrections' then (select count(*)::int from corrections)
           when 'improvement_proposals' then (select count(*)::int from improvement_proposals)
           when 'skill_revisions' then (select count(*)::int from skill_revisions)
         end - (s.row_counts ->> k)::int as delta
  from backup_snapshots s, jsonb_object_keys(s.row_counts) k
  where s.id = p_snapshot_id;
$function$;

CREATE OR REPLACE FUNCTION public.sync_body_fingerprint()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform set_config('app.actor', 'skill', true);
  update documents
     set body_fingerprint = case when coalesce(length(new.body), 0) >= 200
                                 then md5(lower(regexp_replace(new.body, '\s+', '', 'g'))) end
   where id = new.document_id;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.sync_staging_flags()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.drive_file_id is null then return new; end if;
  perform set_config('app.actor', 'skill', true);
  update attachment_staging
     set claimed = true, claimed_at = clock_timestamp()
   where drive_file_id = new.drive_file_id and not claimed;
  update emails e
     set attachments_extracted = true
   where e.gmail_message_id in (select gmail_message_id from attachment_staging where drive_file_id = new.drive_file_id)
     and not e.attachments_extracted
     and not exists (select 1 from attachment_staging s
                      where s.gmail_message_id = e.gmail_message_id
                        and s.resolved_at is null and not s.claimed);
  return new;
end $function$;

CREATE OR REPLACE FUNCTION public.take_snapshot(p_reason text DEFAULT NULL::text)
 RETURNS TABLE(snapshot_id uuid, taken timestamp with time zone, counts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
  v_counts jsonb;
begin
  v_counts := jsonb_build_object(
    'documents', (select count(*) from documents),
    'emails', (select count(*) from emails),
    'deadlines', (select count(*) from deadlines),
    'corrections', (select count(*) from corrections),
    'improvement_proposals', (select count(*) from improvement_proposals),
    'skill_revisions', (select count(*) from skill_revisions));

  insert into backup_snapshots (reason, row_counts, payload)
  values (
    p_reason,
    v_counts,
    jsonb_build_object(
      'documents', (select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) from documents d),
      'emails', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from emails e),
      'deadlines', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from deadlines x),
      'corrections', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from corrections c),
      'improvement_proposals', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from improvement_proposals p),
      'skill_revisions', (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from skill_revisions r)))
  returning id into v_id;

  -- keep the last 12 snapshots, they are cheap but not free
  delete from backup_snapshots
  where id in (select id from backup_snapshots order by taken_at desc offset 12);

  return query select v_id, now(), v_counts;
end;
$function$;

reset check_function_bodies;
