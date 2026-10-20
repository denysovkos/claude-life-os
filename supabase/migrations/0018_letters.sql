-- 0018: letters. A cancellation (Kündigung) or an objection (Widerspruch, Einspruch),
-- written from the index, rendered to PDF in the person's Drive, and handed to them to send.
--
-- The system already knows when a contract must be cancelled (v_notice_calendar) and when
-- an objection is due (deadlines from derive_deadlines). It stopped one step short: the
-- letter. Now:
--
-- 1. letters: one row per letter, with every field it was filled from, what is still
--    missing, the text, and its life: draft -> approved -> ready (PDF in Drive) -> sent ->
--    confirmed, or withdrawn. There is deliberately no e-mail or recipient-address column
--    for sending: the recipient is a postal address printed on the letter. Nothing in the
--    system sends a letter; the person does.
-- 2. compose_letter(kind, source, fields): fills the region's template from the index:
--    the holder (the household member, or the owner), the recipient and their address
--    (entities), the contract or file number, the exit date and the date it must arrive
--    (v_notice_calendar, the deadline), the decision date, the legal basis. The template is
--    life_settings.letter_templates, written by setup from packs/region/<code>/letters.json
--    and packs/lang/<locale>/letters.json. Unknown values stay visible as [[field]] and are
--    listed in `missing`; the skill asks the person and composes again with them.
-- 3. approve_letter(id): only a complete letter, only on the person's word. The Apps Script
--    bridge then renders it (letters_to_render, letter_rendered, letter_render_failed),
--    saves the PDF next to the source document in Drive and mails it to its own account.
-- 4. mark_letter_sent / mark_letter_confirmed / withdraw_letter: sending closes the
--    deadline; a cancellation that is not confirmed within three weeks is reported
--    (v_letters_followup), and so is a finished letter that has not been sent a week
--    before it must arrive. The brief says both, and marks deadlines that have a letter.
--
-- Additive only; this file neither drops an object nor removes a row, and moves no date.
-- Safe to run twice.

-- 1. Letters ----------------------------------------------------------------------------

create table if not exists public.letters (
  id                    uuid primary key default gen_random_uuid(),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  kind                  text not null,
  status                text not null default 'draft',
  locale                text,
  region                text,
  template_version      text,
  member_id             uuid references public.household_members(id) on delete set null,
  recurring_payment_id  uuid references public.recurring_payments(id) on delete set null,
  document_id           uuid references public.documents(id) on delete set null,
  deadline_id           uuid references public.deadlines(id) on delete set null,
  recipient_entity_id   uuid references public.entities(id) on delete set null,
  fields                jsonb not null default '{}',
  overrides             jsonb not null default '{}',
  missing               text[] not null default '{}',
  header                text,
  subject               text,
  body                  text,
  send_by               date,
  effective_date        date,
  legal_basis           text,
  delivery_advice       text,
  file_name             text,
  target_folder_id      text,
  approved_at           timestamptz,
  approved_by           text,
  drive_pdf_id          text,
  drive_url             text,
  rendered_at           timestamptz,
  render_attempts       integer not null default 0,
  render_error          text,
  sent_on               date,
  sent_via              text,
  confirmed_on          date,
  confirmation_email_id uuid references public.emails(id) on delete set null,
  todoist_task_id       text,
  notes                 text,
  constraint letters_kind_check check (kind in ('cancellation','objection_administrative','objection_tax')),
  constraint letters_status_check check (status in ('draft','approved','ready','sent','confirmed','withdrawn')),
  constraint letters_sent_via_check check (sent_via is null or sent_via in
    ('post','registered_mail','fax','email','online_form','cancel_button','in_person','elster')),
  constraint letters_complete_check check (status in ('draft','withdrawn') or missing = '{}'),
  constraint letters_source_check check (recurring_payment_id is not null or document_id is not null)
);
create unique index if not exists letters_one_open_uidx on public.letters
  (kind, coalesce(recurring_payment_id, document_id)) where status in ('draft','approved','ready');
create index if not exists letters_deadline_idx on public.letters (deadline_id) where deadline_id is not null;
alter table public.letters enable row level security;
-- the bridge reads and marks letters only through letters_to_render(), letter_rendered()
-- and letter_render_failed(); it can neither read the table nor change a letter's text
revoke all on public.letters from anon, authenticated, service_role;
comment on table public.letters is 'Cancellations and objections composed from the index (compose_letter), approved by the person (approve_letter), rendered to PDF in Drive by the bridge, sent by the person. No column says where to send it by e-mail: the system never sends a letter, it hands it over. fields holds every value the text was filled from, missing what the index did not know.';
comment on column public.letters.send_by is 'The day the letter must have arrived: the cancel-by date or the end of the objection period. Post takes days: send it earlier.';
comment on column public.letters.overrides is 'Values the person supplied (an address, a file number, the grounds). They survive every recompose.';

create or replace trigger letters_set_updated_at before update on public.letters
  for each row execute function public.set_updated_at();

create or replace function public.letter_fill(p_template text, p_fields jsonb)
returns text language plpgsql immutable set search_path to 'public' as $function$
-- {{field}} becomes its value; a field with no value stays visible as [[field]]
declare r text := coalesce(p_template, ''); k text;
begin
  for k in select jsonb_object_keys(p_fields) loop
    if nullif(btrim(coalesce(p_fields ->> k, '')), '') is not null or k in ('basis_sentence', 'signature_note') then
      r := replace(r, '{{' || k || '}}', coalesce(p_fields ->> k, ''));
    end if;
  end loop;
  return regexp_replace(r, '\{\{([a-z_]+)\}\}', '[[\1]]', 'g');
end $function$;

create or replace function public.compose_letter(p_kind text, p_source uuid, p_fields jsonb default '{}'::jsonb)
returns setof public.letters
language plpgsql set search_path to 'public' as $function$
-- p_kind: 'cancellation', 'objection' (the decision's type picks administrative or tax),
-- or 'objection_administrative' / 'objection_tax'. p_source: a recurring_payments,
-- deadlines or documents id. p_fields: values the person gave; they override the index
-- and are kept for every later compose of the same letter.
declare
  known constant text[] := array['sender_name','sender_address','holder_name','recipient_name',
    'recipient_address','reference','reference_label','contract_name','effective_date',
    'effective_clause','cancel_by','decision_date','decision_title','deadline','today','grounds',
    'basis_sentence','signature_note'];
  tpl jsonb := setting('letter_templates');
  t jsonb; k text := p_kind; fmt text; cat text;
  rp recurring_payments; doc documents; dl deadlines; ent entities; hm household_members;
  nc record; ex letters; prior letters; result letters;
  f jsonb; ov jsonb; miss text[]; owner text := setting_text('owner_name');
  exit_on date; send_on date; basis text; delivery text; ref_label text; bad text;
begin
  if tpl is null or jsonb_typeof(tpl -> 'kinds') is distinct from 'object' then
    raise exception 'letter_templates is not set: run life os doctor, it installs the letter templates from the packs';
  end if;
  select string_agg(x, ', ') into bad from jsonb_object_keys(coalesce(p_fields, '{}')) x where not x = any (known);
  if bad is not null then raise exception 'compose_letter: unknown field(s) %', bad; end if;
  fmt := coalesce(tpl ->> 'date_format', 'YYYY-MM-DD');

  -- the source: a contract, a deadline or a document
  select * into rp from recurring_payments where id = p_source;
  if rp.id is null then
    select * into dl from deadlines where id = p_source;
    if dl.id is not null then
      if dl.source_kind = 'document' then select * into doc from documents where id = dl.source_id; end if;
    else
      select * into doc from documents where id = p_source;
    end if;
  end if;
  if rp.id is null and dl.id is null and doc.id is null then
    raise exception 'compose_letter: % is no contract, deadline or document', p_source;
  end if;

  if k = 'cancellation' then
    if rp.id is null then
      select * into rp from recurring_payments r
      where (dl.id is not null and r.deadline_id = dl.id) or (doc.id is not null and r.document_id = doc.id)
      order by (r.status = 'active') desc, r.created_at desc limit 1;
    end if;
    if rp.id is null then raise exception 'compose_letter: no contract (recurring_payments) behind %: record it first', p_source; end if;
    if rp.status <> 'active' then raise exception 'compose_letter: % is % already', rp.name, rp.status; end if;
    if doc.id is null and rp.document_id is not null then select * into doc from documents where id = rp.document_id; end if;
    if dl.id is null then
      select * into dl from deadlines x
      where x.status in ('open','missed')
        and (x.id = rp.deadline_id or (doc.id is not null and x.source_kind = 'document' and x.source_id = doc.id
                                       and x.deadline_type = 'notice_period'))
      order by (x.id = rp.deadline_id) desc, x.due_on limit 1;
    end if;
    select * into nc from v_notice_calendar where id = rp.id;
    exit_on := nc.earliest_exit;
    send_on := coalesce(dl.due_on, nc.cancel_by);
    cat := rp.category;
  else
    if doc.id is null then raise exception 'compose_letter: an objection needs the decision (a documents row)'; end if;
    if k = 'objection' then
      k := case doc.document_type_key when 'tax_assessment' then 'objection_tax'
                                      when 'official_decision' then 'objection_administrative' end;
      if k is null then raise exception 'compose_letter: % is a %, not a decision one can object to', doc.name, doc.document_type_key; end if;
    end if;
    if dl.id is null then
      select * into dl from deadlines x
      where x.source_kind = 'document' and x.source_id = doc.id and x.deadline_type = 'legal_response'
        and x.status in ('open','missed')
      order by x.due_on limit 1;
    end if;
    send_on := dl.due_on;
    cat := 'default';
  end if;

  t := tpl -> 'kinds' -> k;
  if t is null then
    raise exception 'compose_letter: no % template for region % (letter_templates); the region pack has none yet', k, coalesce(tpl ->> 'region', 'none');
  end if;

  -- who it is from, and to
  select * into hm from household_members where id = coalesce(rp.member_id, doc.member_id, dl.member_id);
  select * into ent from entities where id = coalesce(rp.vendor_entity_id, doc.issuer_entity_id);
  ref_label := case jsonb_typeof(t -> 'reference_label')
                 when 'object' then coalesce(t -> 'reference_label' ->> cat, t -> 'reference_label' ->> 'default')
                 else t ->> 'reference_label' end;
  delivery := case jsonb_typeof(t -> 'delivery')
                when 'object' then coalesce(t -> 'delivery' ->> cat, t -> 'delivery' ->> 'default')
                else t ->> 'delivery' end;
  basis := case when dl.rule_key is not null then region_rule(dl.rule_key) ->> 'basis' end;

  f := jsonb_build_object(
    'holder_name',       coalesce(hm.name, owner),
    'sender_name',       case when hm.relation = 'child' then owner else coalesce(hm.name, owner) end,
    'signature_note',    case when hm.relation = 'child' and tpl ? 'child_signature'
                              then E'\n' || replace(tpl ->> 'child_signature', '{{holder_name}}', hm.name) else '' end,
    'sender_address',    setting_text('current_address'),
    'recipient_name',    coalesce(nullif(btrim(ent.legal_name), ''), ent.name, rp.vendor, doc.issuer),
    'recipient_address', nullif(btrim(ent.address), ''),
    'reference',         coalesce(nullif(btrim(rp.reference), ''),
                                  (select m.reference from matter_links ml join matters m on m.id = ml.matter_id
                                   where ml.object_kind = 'document' and ml.object_id = doc.id
                                     and nullif(btrim(m.reference), '') is not null
                                   order by m.updated_at desc limit 1)),
    'reference_label',   ref_label,
    'contract_name',     rp.name,
    'effective_date',    to_char(exit_on, fmt),
    'cancel_by',         to_char(send_on, fmt),
    'deadline',          to_char(send_on, fmt),
    'decision_date',     to_char(doc.issued_on, fmt),
    'decision_title',    coalesce(nullif(btrim(doc.document_type), ''), t ->> 'decision_title'),
    'grounds',           t ->> 'grounds',
    'basis_sentence',    coalesce((t -> 'basis' ->> cat) || E'\n\n', ''),
    'today',             to_char((now() at time zone setting_text('timezone', 'UTC'))::date, fmt));

  -- an open letter for the same source is composed again in place; a sent one is final
  select * into prior from letters
  where kind = k and status in ('sent','confirmed')
    and ((rp.id is not null and recurring_payment_id = rp.id) or (rp.id is null and document_id = doc.id))
  order by sent_on desc limit 1;
  if prior.id is not null then
    raise exception 'compose_letter: a % for this was already sent on % (letter %); withdraw it first if a new one is really needed',
      k, prior.sent_on, prior.id;
  end if;
  select * into ex from letters
  where kind = k and status in ('draft','approved','ready')
    and coalesce(recurring_payment_id, document_id) = coalesce(rp.id, doc.id);

  ov := coalesce(ex.overrides, '{}'::jsonb) || coalesce(p_fields, '{}'::jsonb);
  f := f || ov;
  f := f || jsonb_build_object('effective_clause',
         case when nullif(f ->> 'effective_date', '') is not null
              then replace(coalesce(t ->> 'effective_clause', ''), '{{effective_date}}', f ->> 'effective_date')
              else t ->> 'effective_clause_unknown' end);
  f := jsonb_strip_nulls(f);
  select coalesce(array_agg(r order by r), '{}') into miss
  from jsonb_array_elements_text(coalesce(t -> 'required', '[]'::jsonb)) r
  where nullif(btrim(coalesce(f ->> r, '')), '') is null;

  perform set_config('app.actor', coalesce(nullif(current_setting('app.actor', true), ''), 'skill'), true);
  if ex.id is not null and ex.status = 'ready' then
    update letters set status = 'withdrawn',
      notes = coalesce(notes || E'\n', '') || 'replaced by a new version ' || to_char(now(), 'YYYY-MM-DD')
    where id = ex.id;
    ex := null;
  end if;

  if ex.id is null then
    insert into letters (kind, status, locale, region, template_version, member_id, recurring_payment_id,
      document_id, deadline_id, recipient_entity_id, fields, overrides, missing, header, subject, body,
      send_by, effective_date, legal_basis, delivery_advice, file_name, target_folder_id)
    values (k, 'draft', tpl ->> 'locale', tpl ->> 'region', tpl ->> 'version', hm.id, rp.id, doc.id, dl.id, ent.id,
      f, ov, miss, null, null, null, send_on, exit_on, basis, delivery, null, doc.drive_parent_id)
    returning * into result;
  else
    update letters set status = 'draft', approved_at = null, approved_by = null,
      member_id = hm.id, deadline_id = dl.id, recipient_entity_id = ent.id, fields = f, overrides = ov,
      missing = miss, send_by = send_on, effective_date = exit_on, legal_basis = basis,
      delivery_advice = delivery, target_folder_id = doc.drive_parent_id,
      locale = tpl ->> 'locale', region = tpl ->> 'region', template_version = tpl ->> 'version'
    where id = ex.id returning * into result;
  end if;

  update letters set
    header = concat_ws(E'\n', letter_fill('{{sender_name}}', f), letter_fill('{{sender_address}}', f), '',
                       letter_fill('{{recipient_name}}', f), letter_fill('{{recipient_address}}', f), '',
                       f ->> 'today'),
    subject = letter_fill(t ->> 'subject', f),
    body = letter_fill(t ->> 'body', f),
    file_name = left(regexp_replace(letter_fill(t ->> 'subject', f), '[/\\:*?"<>|\[\]]+', '-', 'g'), 120)
                || ' ' || to_char(current_date, 'YYYY-MM-DD')
  where id = result.id returning * into result;
  return next result;
end $function$;

create or replace function public.approve_letter(p_id uuid)
returns setof public.letters language plpgsql set search_path to 'public' as $function$
-- The person read the letter and said yes. Only then does the bridge render it.
declare l letters;
begin
  select * into l from letters where id = p_id;
  if l.id is null then raise exception 'approve_letter: no letter %', p_id; end if;
  if l.status <> 'draft' then raise exception 'approve_letter: letter is %, not a draft', l.status; end if;
  if l.missing <> '{}' then raise exception 'approve_letter: still missing %', array_to_string(l.missing, ', '); end if;
  return query update letters set status = 'approved', approved_at = now(),
    approved_by = coalesce(nullif(current_setting('app.actor', true), ''), 'human'),
    render_attempts = 0, render_error = null
  where id = p_id returning *;
end $function$;

create or replace function public.withdraw_letter(p_id uuid)
returns setof public.letters language plpgsql set search_path to 'public' as $function$
declare l letters;
begin
  select * into l from letters where id = p_id;
  if l.id is null then raise exception 'withdraw_letter: no letter %', p_id; end if;
  if l.status in ('sent','confirmed') then raise exception 'withdraw_letter: it was sent on %; a sent letter stays on record', l.sent_on; end if;
  return query update letters set status = 'withdrawn' where id = p_id returning *;
end $function$;

create or replace function public.mark_letter_sent(p_id uuid, p_sent_on date default current_date, p_via text default null)
returns setof public.letters language plpgsql set search_path to 'public' as $function$
-- The person sent it. The deadline it answers is done; for a cancellation the
-- confirmation is now watched for (v_letters_followup).
declare l letters;
begin
  select * into l from letters where id = p_id;
  if l.id is null then raise exception 'mark_letter_sent: no letter %', p_id; end if;
  if l.status not in ('approved','ready') then raise exception 'mark_letter_sent: letter is %', l.status; end if;
  perform set_config('app.actor', coalesce(nullif(current_setting('app.actor', true), ''), 'skill'), true);
  update deadlines set status = 'done',
    notes = coalesce(notes || E'\n', '') || 'letter sent ' || to_char(p_sent_on, 'YYYY-MM-DD')
            || coalesce(' via ' || p_via, '') || ' (letters ' || l.id || ')'
  where id = l.deadline_id and status in ('open','missed');
  return query update letters set status = 'sent', sent_on = p_sent_on, sent_via = p_via
  where id = p_id returning *;
end $function$;

create or replace function public.mark_letter_confirmed(p_id uuid, p_email_id uuid default null, p_on date default current_date)
returns setof public.letters language plpgsql set search_path to 'public' as $function$
declare l letters;
begin
  select * into l from letters where id = p_id;
  if l.id is null then raise exception 'mark_letter_confirmed: no letter %', p_id; end if;
  if l.status <> 'sent' then raise exception 'mark_letter_confirmed: letter is %, not sent', l.status; end if;
  return query update letters set status = 'confirmed', confirmed_on = p_on, confirmation_email_id = p_email_id
  where id = p_id returning *;
end $function$;

-- 2. The bridge's side ------------------------------------------------------------------

create or replace function public.letters_to_render(p_limit integer default 5)
returns table(id uuid, file_name text, header text, subject text, body text, folder_id text)
language sql stable security definer set search_path to 'public' as $$
  select l.id, l.file_name, l.header, l.subject, l.body,
         coalesce(l.target_folder_id, setting('drive_folders') ->> 'catch_all')
  from letters l
  where l.status = 'approved' and l.drive_pdf_id is null and l.render_attempts < 3
  order by l.send_by nulls last, l.approved_at
  limit greatest(1, least(coalesce(p_limit, 5), 20))
$$;

create or replace function public.letter_rendered(p_id uuid, p_pdf_id text, p_url text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
-- The bridge saved the PDF. Returns the note it mails, with the PDF attached, to its own
-- account: the subject, when it must arrive, to whom, how to send it, what to say after.
declare l letters;
begin
  perform set_config('app.actor', 'bridge', true);
  update letters set status = 'ready', drive_pdf_id = p_pdf_id, drive_url = p_url,
    rendered_at = now(), render_error = null
  where letters.id = p_id and status = 'approved'
  returning * into l;
  if l.id is null then raise exception 'letter_rendered: no approved letter %', p_id; end if;
  return jsonb_build_object(
    'subject', dossier_label('letter_ready') || ': ' || l.subject,
    'body', concat_ws(E'\n',
      l.subject,
      '',
      dossier_label('letter_to') || ': ' || coalesce(l.fields ->> 'recipient_name', ''),
      case when l.send_by is not null then dossier_label('letter_send_by') || ': ' || to_char(l.send_by, 'YYYY-MM-DD') end,
      p_url,
      '',
      case when l.delivery_advice is not null then dossier_label('letter_how') || ': ' || l.delivery_advice || E'\n' end,
      case when l.legal_basis is not null then 'basis: ' || l.legal_basis || E'\n' end,
      dossier_label('letter_after_sending'),
      '',
      dossier_label('letter_not_advice')));
end $function$;

create or replace function public.letter_render_failed(p_id uuid, p_error text)
returns void language sql security definer set search_path to 'public' as $$
  update letters set render_attempts = render_attempts + 1, render_error = left(p_error, 500)
  where id = p_id and status = 'approved'
$$;

revoke execute on function public.letters_to_render(integer), public.letter_rendered(uuid, text, text),
  public.letter_render_failed(uuid, text) from anon, authenticated, public;
grant execute on function public.letters_to_render(integer), public.letter_rendered(uuid, text, text),
  public.letter_render_failed(uuid, text) to service_role;

-- 3. What the skill and the brief read ----------------------------------------------------

create or replace view public.v_letters with (security_invoker = on) as
select l.id, l.kind, l.status, l.subject, l.fields ->> 'recipient_name' as recipient,
       coalesce(hm.name, l.fields ->> 'holder_name') as holder, l.send_by, l.effective_date,
       l.missing, l.drive_url, l.sent_on, l.sent_via, l.confirmed_on,
       l.recurring_payment_id, l.document_id, l.deadline_id, l.created_at, l.updated_at
from letters l left join household_members hm on hm.id = l.member_id
order by (l.status in ('draft','approved','ready')) desc, l.send_by nulls last, l.created_at desc;

create or replace view public.v_letters_followup with (security_invoker = on) as
select l.id, l.kind, l.status, l.subject, l.send_by, l.sent_on,
       case
         when l.status = 'ready' and l.send_by is not null and l.send_by - current_date <= 7 then 'send_now'
         when l.status = 'approved' and (l.render_attempts >= 3 or l.approved_at < now() - interval '2 hours') then 'not_rendered'
         when l.status = 'sent' and l.kind = 'cancellation' and l.sent_on < current_date - 21 then 'unconfirmed'
         when l.status = 'draft' and l.missing <> '{}' and l.updated_at < now() - interval '3 days'
              and l.send_by is not null and l.send_by - current_date <= 30 then 'draft_incomplete'
       end as issue,
       l.render_error, l.drive_url
from letters l
where (l.status = 'ready' and l.send_by is not null and l.send_by - current_date <= 7)
   or (l.status = 'approved' and (l.render_attempts >= 3 or l.approved_at < now() - interval '2 hours'))
   or (l.status = 'sent' and l.kind = 'cancellation' and l.sent_on < current_date - 21)
   or (l.status = 'draft' and l.missing <> '{}' and l.updated_at < now() - interval '3 days'
       and l.send_by is not null and l.send_by - current_date <= 30)
order by l.send_by nulls last;
comment on view public.v_letters_followup is 'Letters that need the person: send_now (the PDF is ready and must arrive within 7 days), not_rendered (approved but the bridge has not produced the PDF: old bridge or a render error), unconfirmed (a cancellation sent three weeks ago with no confirmation on record), draft_incomplete (a draft still missing a value, due within 30 days).';

create or replace function public.letter_status_for(p_deadline uuid)
returns text language sql stable set search_path to 'public' as $$
  select l.status from letters l
  where l.deadline_id = p_deadline and l.status <> 'withdrawn'
  order by l.created_at desc limit 1
$$;

-- 4. The brief knows about letters ------------------------------------------------------

create or replace function public.build_briefing(p_date date default current_date)
returns jsonb language sql stable set search_path to 'public' as $function$
with
overdue_hard as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', household_person_label(member_id, subject_person), 'type', deadline_type,
    'letter', letter_status_for(id)) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and hard
    and (snoozed_until is null or snoozed_until <= p_date)
),
overdue_soft as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', household_person_label(member_id, subject_person), 'type', deadline_type,
    'letter', letter_status_for(id)) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and not hard
    and (snoozed_until is null or snoozed_until <= p_date) and (p_date - due_on) % 7 = 0
),
due_now as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_left', due_on - p_date,
    'hard', hard, 'person', household_person_label(member_id, subject_person), 'type', deadline_type,
    'has_task', todoist_task_id is not null, 'letter', letter_status_for(id)) order by due_on)
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
    'note', action_note, 'due_date', due_date, 'has_task', todoist_task_id is not null,
    'person', household_person_label(member_id, null)) order by received_at desc)
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
    'letters_to_send', nullif((select count(*) from v_letters_followup where issue = 'send_now'), 0),
    'letters_not_rendered', nullif((select count(*) from v_letters_followup where issue = 'not_rendered'), 0),
    'cancellations_unconfirmed', nullif((select count(*) from v_letters_followup where issue = 'unconfirmed'), 0),
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

create or replace function public.briefing_text(p_date date default current_date)
returns text language plpgsql stable set search_path to 'public' as $function$
declare
  b jsonb := build_briefing(p_date);
  out text := '';
  it jsonb;
  k text;
begin
  if jsonb_array_length(b->'overdue_hard') > 0 then
    out := out || 'OVERDUE (hard)' || E'\n';
    for it in select * from jsonb_array_elements(b->'overdue_hard') loop
      out := out || format('  · %s — %s days past %s%s%s',
        it->>'title', it->>'days_overdue', it->>'due_on',
        coalesce(' (' || (it->>'person') || ')', ''),
        case it->>'letter' when 'draft' then '  [letter: draft]' when 'approved' then '  [letter: being rendered]'
          when 'ready' then '  [letter ready, not sent]' when 'sent' then '  [letter sent]'
          when 'confirmed' then '  [letter confirmed]' else '' end) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'overdue_soft') > 0 then
    out := out || 'OVERDUE (soft, weekly reminder)' || E'\n';
    for it in select * from jsonb_array_elements(b->'overdue_soft') loop
      out := out || format('  · %s — %s days past %s%s', it->>'title', it->>'days_overdue', it->>'due_on',
        coalesce(' (' || (it->>'person') || ')', '')) || E'\n';
    end loop;
    out := out || E'\n';
  end if;

  if jsonb_array_length(b->'due_now') > 0 then
    out := out || 'COMING UP' || E'\n';
    for it in select * from jsonb_array_elements(b->'due_now') loop
      out := out || format('  · %s — in %s days (%s)%s%s%s%s',
        it->>'title', it->>'days_left', it->>'due_on',
        coalesce(' (' || (it->>'person') || ')', ''),
        case when (it->>'hard')::boolean then '  [hard]' else '' end,
        case it->>'letter' when 'draft' then '  [letter: draft]' when 'approved' then '  [letter: being rendered]'
          when 'ready' then '  [letter ready, not sent]' when 'sent' then '  [letter sent]'
          when 'confirmed' then '  [letter confirmed]' else '' end,
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
      out := out || format('  · %s — %s%s%s', it->>'sender', it->>'note',
        coalesce(' (' || (it->>'person') || ')', ''),
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

-- 5. Labels for the note that comes with the PDF (dossier_labels, in output_locale) -------

create or replace function public.dossier_label(p_key text)
returns text language sql stable set search_path to 'public' as $$
  select coalesce(
    setting('dossier_labels') ->> p_key,
    jsonb_build_object(
      'title',            'Emergency binder',
      'generated',        'generated',
      'intro',            'Built automatically from the document index. If something looks wrong, Supabase and Google Drive hold the latest truth.',
      'matters',          'Open matters and what to do about them',
      'hard_deadlines',   'Deadlines that cannot be missed',
      'loans',            'Loans and leasing',
      'insurance',        'Insurance',
      'subscriptions',    'Housing, telecom, subscriptions (what can be paused or cancelled)',
      'notice',           'notice',
      'months',           'mo.',
      'notice_unknown',   'notice period unknown',
      'until',            'until',
      'total',            'Total recurring commitments',
      'per_month',        'per month',
      'identity',         'Identity documents and where the originals are',
      'valid_until',      'valid until',
      'original',         'original',
      'property',         'Property',
      'contacts',         'Contacts',
      'none',             '- none',
      'overdue_since',    'OVERDUE since',
      'close_or_reschedule', 'close the matter or set a new date',
      'subject_unknown',  'person not recorded',
      'file_missing',     'file missing in Drive since',
      'household',        'People in the household',
      'rel_self',         'owner of this binder',
      'rel_partner',      'partner',
      'rel_child',        'child',
      'rel_parent',       'parent',
      'rel_other',        'household member',
      'born',             'born',
      'letter_ready',     'Letter ready',
      'letter_to',        'To',
      'letter_send_by',   'Must arrive by',
      'letter_how',       'How to send it',
      'letter_after_sending', 'Once it is sent, tell Claude in any chat "I sent the letter" and how (post, registered mail, fax, online). The deadline then closes, and a missing confirmation is reported.',
      'letter_not_advice', 'Filled in from your documents. Not legal advice: read every line, check the recipient, the number and the dates, and sign it yourself.'
    ) ->> p_key,
    p_key)
$$;

-- 6. Snapshots include the letters --------------------------------------------------------

create or replace function public.backup_snapshot_add_settings()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  new.payload := coalesce(new.payload, '{}'::jsonb)
    || jsonb_build_object(
         'life_settings', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from life_settings s),
         'household_members', (select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from household_members h),
         'letters', (select coalesce(jsonb_agg(to_jsonb(l)), '[]'::jsonb) from letters l));
  new.row_counts := coalesce(new.row_counts, '{}'::jsonb)
    || jsonb_build_object('life_settings', (select count(*) from life_settings),
                          'household_members', (select count(*) from household_members),
                          'letters', (select count(*) from letters));
  return new;
end $function$;

revoke execute on function public.build_briefing(date), public.briefing_text(date), public.dossier_label(text),
  public.backup_snapshot_add_settings()
  from anon, authenticated, public;
-- what a letter says and whether it is approved or sent is the person's, through the
-- skill's own connection: Supabase grants service_role every new function by default,
-- so the bridge's key is named here too
revoke execute on function public.letter_fill(text, jsonb), public.compose_letter(text, uuid, jsonb),
  public.approve_letter(uuid), public.withdraw_letter(uuid), public.mark_letter_sent(uuid, date, text),
  public.mark_letter_confirmed(uuid, uuid, date), public.letter_status_for(uuid)
  from anon, authenticated, public, service_role;

-- 7. Version ----------------------------------------------------------------------------

update public.life_settings set value = '"0.9.0"', updated_at = now()
where key = 'schema_version'
  and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"', '"0.7.0"', '"0.8.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                -- "0.9.0"
--   select setting('letter_templates') ->> 'region';                            -- the region, once setup wrote the templates
--   select * from v_letters;
--   select * from v_letters_followup;                                           -- empty when nothing waits on the person
--   select count(*) from information_schema.role_table_grants
--   where table_name = 'letters' and grantee in ('anon','authenticated','service_role');  -- 0
--   select count(*) from information_schema.columns
--   where table_name = 'letters' and column_name ~ '(^to$|^cc$|^bcc$|email$)';  -- 0
