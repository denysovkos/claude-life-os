-- 0010: capture the 2026-10-14 hot-fixes and make the deadline recount safe.
--
-- Part 1 brings five changes that were applied by hand on a live installation into the
-- migration history, so every installation has them:
--   * document types authority_letter and insurance_correspondence
--   * documents.superseded_by, and v_missing_notice_period ignores superseded documents
--   * document_texts.extraction_method accepts local_text, local_ocr, drive_text+local_ocr
--   * text_ingest_chunks + ingest_assemble(): the md5-verified chunk path for long texts
--
-- Part 2 fixes rederive_deadlines(). It counted every rule from the document's issue
-- date, whatever the rule's "start" said. A rule that starts at expiry_date (the
-- residence permit "apply by" rule) or at a contract date was therefore recounted from
-- the wrong day, which can move a hard deadline into the past. It now resolves the start
-- the rule names, leaves a deadline alone when that start is unknown, and never touches a
-- date that a document stated in words (deadlines.date_basis = 'stated').
--
-- Everything here is additive or replaces a function with the same signature, and the
-- file is safe to run twice.

-- 1. Document types ---------------------------------------------------------------------

insert into public.document_types select * from json_populate_record(null::public.document_types, '{"key":"authority_letter","label":"Authority correspondence","domain":"legal","expiry_expected":false,"notice_period_expected":false,"hard_deadline":false,"applies_to_kind":"document","description":"Letter from an authority that is not a decision (Bescheid): file transmittals, receipt confirmations, appointment notices, requests to submit papers. No objection period, so official_decision stays the narrow deadline-bearing type.","hints":["Behörde","Landesamt","Geschäftszeichen","Aktenzeichen","Eingangsbestätigung","Akteneinsicht","Schreiben"],"active":true}') on conflict (key) do nothing;
insert into public.document_types select * from json_populate_record(null::public.document_types, '{"key":"insurance_correspondence","label":"Insurer correspondence","domain":"insurance","expiry_expected":false,"notice_period_expected":false,"hard_deadline":false,"applies_to_kind":"document","description":"Insurer letters that are not the policy itself: cover confirmations, benefit decisions, claim letters. No expiry, no notice period.","hints":["Deckungszusage","Leistungsentscheidung","Schadennummer","Kostenzusage","Leistungs-Nr."],"active":true}') on conflict (key) do nothing;

-- 2. Superseded documents ---------------------------------------------------------------

alter table public.documents add column if not exists superseded_by uuid references public.documents(id);
comment on column public.documents.superseded_by is 'The document that replaces this one (a renewed contract, a new permit). Set by the intake when a successor is indexed; such a document no longer needs its own notice-period or expiry handling.';

create or replace view public.v_missing_notice_period with (security_invoker = on) as
select d.id, d.name, d.document_type_key, t.label, d.issuer, d.subject_person
from documents d
join document_types t on t.key = d.document_type_key
where t.notice_period_expected
  and d.duplicate_of is null
  and d.superseded_by is null
  and d.status <> all (array['stale','to_archive','expired'])
  and not exists (select 1 from deadlines dl
                  where dl.source_kind = 'document' and dl.source_id = d.id
                    and dl.deadline_type = 'notice_period' and dl.status in ('open','done'))
  and not exists (select 1 from recurring_payments rp
                  where rp.document_id = d.id and rp.contract_end is null
                    and rp.notice_period_months is not null)
order by t.label;

-- 3. Local extraction methods -----------------------------------------------------------

alter table public.document_texts drop constraint if exists document_texts_extraction_method_check;
alter table public.document_texts add constraint document_texts_extraction_method_check
  check (extraction_method = any (array['drive_text','drive_ocr','manual','none','apps_script',
                                        'local_text','local_ocr','drive_text+local_ocr']));

-- 4. Chunked, md5-verified text ingest --------------------------------------------------

create table if not exists public.text_ingest_chunks (
  document_id  uuid not null references public.documents(id),
  seq          integer not null,
  chunk        text not null,
  expected_md5 text not null,
  created_at   timestamptz not null default now(),
  primary key (document_id, seq)
);
alter table public.text_ingest_chunks enable row level security;
revoke all on public.text_ingest_chunks from anon, authenticated;
comment on table public.text_ingest_chunks is 'Staging for long document texts: each chunk is inserted with the md5 the sender computed, ingest_assemble() verifies and joins them. Chunks are removed by nightly_maintenance() after a successful assemble, never by the skill.';

create or replace function public.ingest_assemble(p_doc uuid, p_method text, p_pages integer,
                                                  p_expected_chunks integer, p_expected_md5 text)
returns table(char_count integer, body_md5 text)
language plpgsql set search_path to 'public' as $function$
declare v_body text; v_bad int; v_n int;
begin
  select count(*), count(*) filter (where md5(chunk) <> expected_md5) into v_n, v_bad
  from text_ingest_chunks where document_id = p_doc;
  if v_n <> p_expected_chunks then raise exception 'expected % chunks, found %', p_expected_chunks, v_n; end if;
  if v_bad > 0 then raise exception '% chunks fail md5', v_bad; end if;
  select string_agg(chunk, '' order by seq) into v_body from text_ingest_chunks where document_id = p_doc;
  if md5(v_body) <> p_expected_md5 then raise exception 'assembled body md5 mismatch'; end if;
  insert into document_texts as t (document_id, body, page_count, extraction_method, extraction_status, extraction_error, extracted_at)
  values (p_doc, v_body, p_pages, p_method, 'done', null, now())
  on conflict (document_id) do update set body = excluded.body, page_count = excluded.page_count,
    extraction_method = excluded.extraction_method, extraction_status = 'done', extraction_error = null, extracted_at = now();
  return query select length(v_body), md5(v_body);
end $function$;

revoke execute on function public.ingest_assemble(uuid, text, integer, integer, text) from anon, authenticated, public;
grant execute on function public.ingest_assemble(uuid, text, integer, integer, text) to service_role;

-- 5. Stated dates are not recounted -----------------------------------------------------

alter table public.deadlines add column if not exists date_basis text;
alter table public.deadlines drop constraint if exists deadlines_date_basis_check;
alter table public.deadlines add constraint deadlines_date_basis_check
  check (date_basis is null or date_basis in ('stated','derived','manual'));
comment on column public.deadlines.date_basis is 'stated: the document gives this date in words, it wins over any computation and rederive_deadlines() never moves it. derived: counted with apply_term_rule(). manual: set by a person, also never moved. null: unknown (older rows): a recount may move it earlier, never later.';

-- 6. rederive_deadlines() counts from the start its rule names ---------------------------

create or replace function public.rederive_deadlines(p_apply boolean default false)
returns table(deadline_id uuid, title text, rule_key text, old_due date, new_due date, action text)
language plpgsql security definer set search_path to 'public' as $function$
-- Dry run by default: shows what would move. With p_apply = true, moves open deadlines to
-- the date the current rules give. Never touches a deadline without rule_key, never one
-- whose date was stated by the document, never closes or deletes one.
-- action: moved (earlier) | moved_later (only rows with date_basis = 'derived') |
--         later_kept (would move later, provenance unknown: left alone) | unchanged |
--         stated_kept | rule_gone | no_start_date
declare r record; rule jsonb; nd date; s date; receipt boolean;
        version text := setting('region_rules')->>'version';
        prev_actor text := current_setting('app.actor', true);
begin
  if p_apply then perform set_config('app.actor', 'skill', true); end if;
  for r in
    select dl.id, dl.title, dl.rule_key, dl.due_on, dl.date_basis,
           d.issued_on, d.expiry_date,
           (select e.received_at::date from emails e where e.id = d.source_email_id) as email_date,
           (select rp.contract_start from recurring_payments rp
             where rp.deadline_id = dl.id or rp.document_id = d.id
             order by (rp.deadline_id = dl.id) desc nulls last limit 1) as contract_start,
           (select rp.contract_end from recurring_payments rp
             where rp.deadline_id = dl.id or rp.document_id = d.id
             order by (rp.deadline_id = dl.id) desc nulls last limit 1) as contract_end
    from deadlines dl join documents d on dl.source_kind = 'document' and d.id = dl.source_id
    where dl.status = 'open' and dl.rule_key is not null and dl.rule_key <> 'objection_generic'
    order by dl.due_on
  loop
    rule := region_rule(r.rule_key);
    deadline_id := r.id; title := r.title; rule_key := r.rule_key; old_due := r.due_on;
    new_due := null;
    if r.date_basis in ('stated','manual') then
      action := 'stated_kept';
    elsif rule is null then
      action := 'rule_gone';
    else
      receipt := true;
      s := case coalesce(rule->>'start', 'issued_on')
             when 'issued_on'      then coalesce(r.issued_on, r.email_date)
             when 'expiry_date'    then r.expiry_date
             when 'contract_start' then r.contract_start
             when 'contract_end'   then r.contract_end
             else null end;
      -- only a posted letter's issue date carries the notification offset
      if coalesce(rule->>'start', 'issued_on') = 'issued_on' and r.issued_on is not null then
        receipt := false;
      end if;
      nd := apply_term_rule(rule, s, receipt);
      new_due := nd;
      if nd is null then action := 'no_start_date';
      elsif nd = r.due_on then action := 'unchanged';
      elsif nd > r.due_on and r.date_basis is distinct from 'derived' then
        -- a later date on a row of unknown provenance may be a deliberately earlier
        -- choice (a card that expires before the title): report it, never apply it
        action := 'later_kept';
      else
        action := case when nd > r.due_on then 'moved_later' else 'moved' end;
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

revoke execute on function public.rederive_deadlines(boolean) from anon, authenticated, public;
grant execute on function public.rederive_deadlines(boolean) to service_role;

-- 7. derive_deadlines() marks what it counts --------------------------------------------

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
                           source_kind, source_id, status, notes, rule_key, rule_version, date_basis)
    values (coalesce(rule->>'label', 'Objection deadline') || ': ' || coalesce(r.issuer || ' ', '') || r.name,
            'legal_response', due, coalesce((rule->>'hard')::boolean, true),
            case when cardinality(lead) > 0 then lead else array[30,14,7,3,1] end,
            r.subject_person, 'document', r.id, 'open',
            'Derived by derive_deadlines(): ' || basis || ', rule ' || (rule->>'key') || '. '
              || coalesce(rule->>'basis', '') || coalesce(' ' || (rule->>'notes'), ''),
            rule->>'key', case when rule->>'key' = 'objection_generic' then 'generic' else version end, 'derived');
    n := n + 1;
  end loop;
  return n;
end $function$;


revoke execute on function public.derive_deadlines() from anon, authenticated, public;

-- Verification (run by hand after applying):
--   select key from document_types where key in ('authority_letter','insurance_correspondence');   -- 2 rows
--   select column_name from information_schema.columns
--    where table_name = 'documents' and column_name = 'superseded_by';                            -- 1 row
--   select has_function_privilege('anon', 'public.ingest_assemble(uuid,text,integer,integer,text)', 'execute');  -- false
--   select action, count(*) from rederive_deadlines(false) group by 1;                            -- no 'moved' on a consistent index
