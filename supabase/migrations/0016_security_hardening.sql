-- 0016: security hardening. Mail and documents are untrusted input; nothing they say may
-- widen what the system does or where its data goes.
--
-- 1. outbox: the only way a workflow sends mail. A row has a subject and a body and no
--    recipient: the Apps Script bridge delivers it to the Google account it runs as
--    (Session.getEffectiveUser), which no text in the database can change. The skills no
--    longer need Gmail's send, draft or forward tools at all, so a letter that talks the
--    model into "forwarding" something has no tool to do it with.
-- 2. Self-only rules. The rules that keep the system from filing its own mail matched on
--    the subject alone, so any sender could hide a letter by putting "Daily brief" in its
--    subject. A rule with self_only = true now matches only mail from owner_email; the
--    email intake also requires Gmail's SENT label, which a spoofed From cannot add.
-- 3. sender_domain matches the domain or a subdomain of it, never a lookalike:
--    "finanzamt.de" matched "x@fake-finanzamt.de" before.
-- 4. Identifier redaction. IBANs and card numbers (checksum-verified) and machine-readable
--    zones of passports and ID cards are masked before document text and mail excerpts
--    are stored. The original stays in Drive and Gmail. Setting redact_identifiers.
--    Upload chunks are emptied once their text is assembled, so no raw copy stays behind.
--
-- Additive only; this file neither drops an object nor removes a row. Safe to run twice.

-- 1. Outbox -------------------------------------------------------------------------------

create table if not exists public.outbox (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  kind        text not null,
  subject     text not null,
  body        text not null,
  source      text,
  sent_at     timestamptz,
  attempts    integer not null default 0,
  last_error  text,
  constraint outbox_kind_check check (kind in ('brief','review','failure','notice')),
  constraint outbox_subject_check check (length(subject) between 1 and 250),
  constraint outbox_body_check check (length(body) <= 100000)
);
alter table public.outbox enable row level security;
revoke all on public.outbox from anon, authenticated;
grant select on public.outbox to service_role;
grant update (sent_at, attempts, last_error) on public.outbox to service_role;
comment on table public.outbox is 'Mail to the owner, and only the owner. There is deliberately no recipient column: the Apps Script bridge sends each row to the Google account it runs as and marks it sent. Workflows insert here instead of using a Gmail send tool.';

create or replace view public.v_outbox_pending with (security_invoker = on) as
select id, kind, subject, body, attempts, created_at
from outbox
where sent_at is null and attempts < 5
order by created_at;
revoke all on public.v_outbox_pending from anon, authenticated;
grant select on public.v_outbox_pending to service_role;

alter table public.briefings add column if not exists outbox_id uuid;
comment on column public.briefings.outbox_id is 'The outbox row that carries this brief when there is no task provider (channel = email).';

-- 2. Self-only rules ------------------------------------------------------------------------

alter table public.classification_rules add column if not exists self_only boolean not null default false;
comment on column public.classification_rules.self_only is 'Matches only mail whose sender is life_settings.owner_email. Every rule that silences mail (set_category = none) on a subject must be self_only, or any sender could hide a letter.';

update public.classification_rules set self_only = true
where scope = 'email' and set_category = 'none' and match_field = 'subject' and not self_only
  and match_value in ('attachment-bridge:', 'has not run for', 'Daily brief')
returning id;

insert into public.classification_rules (scope, priority, match_field, match_op, match_value, set_category, self_only, notes)
select 'email', 1, 'subject', 'contains', '[Life OS]', 'none', true, 'Everything the system sends itself (outbox, bridge alerts)'
where not exists (select 1 from public.classification_rules
                  where scope = 'email' and match_field = 'subject' and match_value = '[Life OS]');

-- 3. Domain matching ----------------------------------------------------------------------

create or replace function public.sender_domain_matches(p_email text, p_domain text)
returns boolean language sql immutable set search_path to 'public' as $$
  -- the address's host is the domain, or a subdomain of it; a lookalike never matches
  with x as (
    select lower(substring(coalesce(p_email, '') from '@([^@<>[:space:]]+)[>[:space:]]*$')) as host,
           lower(btrim(btrim(coalesce(p_domain, '')), '@.')) as d
  )
  select x.d <> '' and x.host is not null
         and (x.host = x.d or right(x.host, length(x.d) + 1) = '.' || x.d)
  from x
$$;

create or replace function public.match_rules(p_scope text, p_sender_email text default null::text,
  p_sender_name text default null::text, p_subject text default null::text,
  p_file_name text default null::text, p_issuer text default null::text)
returns setof classification_rules language sql stable set search_path to 'public' as $function$
  select r.* from classification_rules r
  where r.active and r.scope = p_scope
    and (not r.self_only
         or (coalesce(setting_text('owner_email'), '') <> ''
             and lower(btrim(coalesce(p_sender_email, ''))) = lower(btrim(setting_text('owner_email')))))
    and case r.match_field
      when 'sender_email'  then lower(btrim(coalesce(p_sender_email,''))) = lower(btrim(r.match_value))
      when 'sender_domain' then sender_domain_matches(p_sender_email, r.match_value)
      when 'sender_name'   then lower(coalesce(p_sender_name,'')) like '%' || lower(r.match_value) || '%'
      when 'subject'       then lower(coalesce(p_subject,'')) like '%' || lower(r.match_value) || '%'
      when 'file_name'     then lower(coalesce(p_file_name,'')) like '%' || lower(r.match_value) || '%'
      when 'issuer'        then lower(coalesce(p_issuer,'')) like '%' || lower(r.match_value) || '%'
      else false end
  order by r.priority, r.created_at;
$function$;

-- 4. Identifier redaction -----------------------------------------------------------------

insert into public.life_settings (key, value) values ('redact_identifiers', 'true')
on conflict (key) do nothing;

create or replace function public.iban_valid(p text)
returns boolean language plpgsql immutable set search_path to 'public' as $$
declare s text := upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'));
        r text; c text; m int := 0;
begin
  if length(s) < 15 or length(s) > 34 or s !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]+$' then return false; end if;
  r := substr(s, 5) || substr(s, 1, 4);
  foreach c in array regexp_split_to_array(r, '') loop
    if c ~ '[0-9]' then m := (m * 10 + c::int) % 97;
    else m := (m * 100 + ascii(c) - 55) % 97; end if;
  end loop;
  return m = 1;
end $$;

create or replace function public.luhn_valid(p text)
returns boolean language plpgsql immutable set search_path to 'public' as $$
declare s text := regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g');
        i int; d int; total int := 0; dbl boolean := false;
begin
  if length(s) < 13 or length(s) > 19 then return false; end if;
  for i in reverse length(s)..1 loop
    d := substr(s, i, 1)::int;
    if dbl then d := d * 2; if d > 9 then d := d - 9; end if; end if;
    total := total + d; dbl := not dbl;
  end loop;
  return total % 10 = 0;
end $$;

create or replace function public.redact_identifiers(p text)
returns text language plpgsql immutable set search_path to 'public' as $$
-- IBAN -> DE89 …3000, card -> •••• 0366, MRZ line -> [MRZ redacted].
-- Only checksum-valid IBANs and card numbers are touched, so an invoice or customer number
-- that merely looks similar stays as it is.
declare r text := p; m text; digits text;
begin
  if r is null or r = '' then return r; end if;
  for m in select distinct x[1] from regexp_matches(r,
      '\m([A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?)\M', 'g') as x loop
    if iban_valid(m) then
      r := replace(r, m, left(m, 4) || ' …' || right(regexp_replace(m, ' ', '', 'g'), 4));
    end if;
  end loop;
  for m in select distinct x[1] from regexp_matches(r,
      '\m((?:[0-9]{4}[ -]?){3}[0-9]{1,4})\M', 'g') as x loop
    digits := regexp_replace(m, '[^0-9]', '', 'g');
    if length(digits) between 15 and 16 and luhn_valid(digits) then
      r := replace(r, m, '•••• ' || right(digits, 4));
    end if;
  end loop;
  r := regexp_replace(r, '^[ \t]*(?=[A-Z0-9<]{28,}[ \t]*$)[A-Z0-9<]*<<[A-Z0-9<]*[ \t]*$', '[MRZ redacted]', 'gn');
  return r;
end $$;

create or replace function public.redact_on_write()
returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if coalesce(setting_text('redact_identifiers', 'true'), 'true') <> 'true' then return new; end if;
  if tg_table_name = 'document_texts' then
    new.body := redact_identifiers(new.body);
  else
    new.content_excerpt := redact_identifiers(new.content_excerpt);
  end if;
  return new;
end $function$;

create or replace trigger document_texts_redact before insert or update of body on public.document_texts
  for each row execute function public.redact_on_write();
create or replace trigger documents_redact before insert or update of content_excerpt on public.documents
  for each row execute function public.redact_on_write();
create or replace trigger emails_redact before insert or update of content_excerpt on public.emails
  for each row execute function public.redact_on_write();

-- Upload chunks are staging, not a second copy of the text: once a body is assembled, its
-- chunks are emptied (kept as rows, so nothing is removed). A later upload overwrites
-- 1..n as before, and the whole-body md5 still catches a chunk that was not re-sent.
create or replace function public.ingest_assemble(p_doc uuid, p_method text, p_pages integer,
                                                  p_expected_chunks integer, p_expected_md5 text)
returns table(char_count integer, body_md5 text)
language plpgsql set search_path to 'public' as $function$
declare v_body text; v_bad int; v_n int;
begin
  select count(*), count(*) filter (where md5(chunk) <> expected_md5) into v_n, v_bad
  from text_ingest_chunks where document_id = p_doc and seq between 1 and p_expected_chunks;
  if v_n <> p_expected_chunks then raise exception 'expected % chunks, found %', p_expected_chunks, v_n; end if;
  if v_bad > 0 then raise exception '% chunks fail md5', v_bad; end if;
  select string_agg(chunk, '' order by seq) into v_body
  from text_ingest_chunks where document_id = p_doc and seq between 1 and p_expected_chunks;
  if md5(v_body) <> p_expected_md5 then raise exception 'assembled body md5 mismatch'; end if;
  insert into document_texts as t (document_id, body, page_count, extraction_method, extraction_status, extraction_error, extracted_at)
  values (p_doc, v_body, p_pages, p_method, 'done', null, now())
  on conflict (document_id) do update set body = excluded.body, page_count = excluded.page_count,
    extraction_method = excluded.extraction_method, extraction_status = 'done', extraction_error = null, extracted_at = now();
  update text_ingest_chunks set chunk = '', expected_md5 = md5('')
  where document_id = p_doc and chunk <> '';
  return query select length(v_body), md5(v_body);
end $function$;

revoke execute on function public.ingest_assemble(uuid, text, integer, integer, text) from anon, authenticated, public;
grant execute on function public.ingest_assemble(uuid, text, integer, integer, text) to service_role;

create or replace function public.redact_stored_texts(p_limit integer default 200)
returns integer language plpgsql set search_path to 'public' as $function$
-- Redacts text stored before 0016, a batch at a time; returns how many rows changed.
-- The doctor offers it once; run it until it returns 0. Snapshots taken earlier keep
-- their copy until they age out.
declare n int := 0; k int;
begin
  perform set_config('app.actor', 'skill', true);
  update document_texts t set body = redact_identifiers(t.body)
  where t.document_id in (select document_id from document_texts
                          where body is not null and body <> redact_identifiers(body) limit p_limit);
  get diagnostics k = row_count; n := n + k;
  update documents d set content_excerpt = redact_identifiers(d.content_excerpt)
  where d.id in (select id from documents
                 where content_excerpt is not null and content_excerpt <> redact_identifiers(content_excerpt) limit p_limit);
  get diagnostics k = row_count; n := n + k;
  update emails e set content_excerpt = redact_identifiers(e.content_excerpt)
  where e.id in (select id from emails
                 where content_excerpt is not null and content_excerpt <> redact_identifiers(content_excerpt) limit p_limit);
  get diagnostics k = row_count; n := n + k;
  update text_ingest_chunks c set chunk = '', expected_md5 = md5('')
  where c.chunk <> '' and exists (select 1 from document_texts t
                                  where t.document_id = c.document_id and t.extraction_status = 'done');
  get diagnostics k = row_count; n := n + k;
  return n;
end $function$;

revoke execute on function public.sender_domain_matches(text, text), public.iban_valid(text),
  public.luhn_valid(text), public.redact_identifiers(text), public.redact_on_write(),
  public.redact_stored_texts(integer), public.match_rules(text, text, text, text, text, text)
  from anon, authenticated, public;

-- 5. Version ----------------------------------------------------------------------------

update public.life_settings set value = '"0.7.0"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                         -- "0.7.0"
--   select count(*) from classification_rules where set_category = 'none'
--     and match_field = 'subject' and not self_only;                                     -- 0
--   select sender_domain_matches('a@fake-finanzamt.de', 'finanzamt.de');                 -- false
--   select sender_domain_matches('a@post.finanzamt.de', 'finanzamt.de');                 -- true
--   select redact_identifiers('IBAN DE89 3704 0044 0532 0130 00');                        -- IBAN DE89 …3000
--   select count(*) from information_schema.columns
--   where table_name = 'outbox' and column_name ~ '(^to$|recipient|address)';            -- 0
