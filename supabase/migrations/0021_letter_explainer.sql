-- 0021: the letter explainer. Every letter from an authority or a lawyer gets an
-- explanation in the person's own language: what it says, what happens if they do nothing,
-- what they can do and by when, and a draft reply in the letter's language. The bridge
-- writes it as a Google Doc next to the letter, which the person can edit and send from.
--
-- The index already knew what such a letter is and which deadline it starts. A person who
-- does not read German well still had to work out what the Ausländerbehörde wants, or
-- what "Anhörung" means for them. Now:
--
-- 1. letter_explanations: one row per letter, written by the Drive intake at night (or in
--    chat on request) through record_letter_explanation(). The fields are structured, so
--    the brief, the binder and a later question all read the same text.
-- 2. v_letters_to_explain: letters of the types in life_settings.explain_letter_types that
--    have text, are recent and have no explanation yet, or whose text changed since.
-- 3. The bridge renders each explanation into a Google Doc in the letter's folder
--    (explanations_to_render, explanation_rendered, explanation_render_failed). An
--    explanation that changes later is rewritten into the same Doc. The Doc is the
--    person's to edit: a draft reply is never sent by anything in the system.
-- 4. v_letter_explanations: what the skill and the brief read.
--
-- An objection is not drafted here. When a decision can be objected to, the explanation
-- says so and points at the letters workflow, whose template is reviewed per country.
--
-- Additive only; this file neither drops an object nor removes a row. Safe to run twice.

-- 1. Explanations -----------------------------------------------------------------------

create table if not exists public.letter_explanations (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  document_id        uuid not null references public.documents(id) on delete cascade,
  origin             text not null default 'intake',
  locale             text not null,
  letter_locale      text,
  summary            text not null,
  meaning            text not null,
  if_ignored         text not null,
  options            jsonb not null default '[]',
  act_by             date,
  reply_kind         text not null default 'none',
  draft_reply        text,
  draft_translation  text,
  draft_missing      text[] not null default '{}',
  suspicious         boolean not null default false,
  source_fingerprint text,
  skill_version      text,
  file_name          text,
  drive_doc_id       text,
  drive_url          text,
  rendered_at        timestamptz,
  render_attempts    integer not null default 0,
  render_error       text,
  constraint letter_explanations_document_key unique (document_id),
  constraint letter_explanations_origin_check check (origin in ('intake','chat')),
  constraint letter_explanations_reply_kind_check check (reply_kind in ('none','reply','objection')),
  constraint letter_explanations_options_check check (jsonb_typeof(options) = 'array'),
  constraint letter_explanations_draft_check check (reply_kind <> 'reply' or nullif(btrim(draft_reply), '') is not null)
);
create index if not exists letter_explanations_render_idx on public.letter_explanations (updated_at)
  where rendered_at is null;
alter table public.letter_explanations enable row level security;
-- the bridge reads and marks explanations only through the three functions below
revoke all on public.letter_explanations from anon, authenticated, service_role;
comment on table public.letter_explanations is 'One explanation per authority or legal letter, in output_locale: what it says (meaning), what happens if nothing is done (if_ignored), the options (options: [{title, how, until}]), the date to act by, and for a letter that asks for an answer a draft reply in the letter''s language (draft_reply) with its translation. reply_kind = objection means the letters workflow writes the reply from its reviewed template. Rendered by the bridge into an editable Google Doc next to the letter.';
comment on column public.letter_explanations.source_fingerprint is 'documents.body_fingerprint when the explanation was written. A different fingerprint means the text was re-read since, and v_letters_to_explain lists the letter again.';
comment on column public.letter_explanations.suspicious is 'The sender is not one the index knows, or the letter asks for something an authority does not (credentials, payment to a private account, a gift card). The Doc then opens with a warning.';

create or replace trigger letter_explanations_set_updated_at before update on public.letter_explanations
  for each row execute function public.set_updated_at();

insert into public.life_settings (key, value) values
  ('explain_letter_types', '["official_decision","tax_assessment","authority_letter","notary_letter","insurance_correspondence"]'::jsonb)
on conflict (key) do nothing;

create or replace function public.record_letter_explanation(p_document_id uuid, p jsonb)
returns setof public.letter_explanations
language plpgsql set search_path to 'public' as $function$
-- p: {locale, letter_locale, summary, meaning, if_ignored, options, act_by, reply_kind,
-- draft_reply, draft_translation, draft_missing, suspicious, origin, skill_version}.
-- Writing it again replaces the text; the bridge then rewrites the same Google Doc.
declare
  allowed constant text[] := array['locale','letter_locale','summary','meaning','if_ignored',
    'options','act_by','reply_kind','draft_reply','draft_translation','draft_missing',
    'suspicious','origin','skill_version'];
  d documents;
  k text;
  opt jsonb;
begin
  select * into d from documents where id = p_document_id;
  if d.id is null then raise exception 'record_letter_explanation: no document %', p_document_id; end if;
  if d.duplicate_of is not null then
    raise exception 'record_letter_explanation: document % is a duplicate of %; explain that one', d.id, d.duplicate_of;
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then raise exception 'record_letter_explanation: p must be an object'; end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(allowed) then raise exception 'record_letter_explanation: unknown field %', k; end if;
  end loop;
  foreach k in array array['locale','summary','meaning','if_ignored'] loop
    if nullif(btrim(coalesce(p ->> k, '')), '') is null then
      raise exception 'record_letter_explanation: % is required', k;
    end if;
  end loop;
  if p ? 'options' and jsonb_typeof(p -> 'options') <> 'array' then
    raise exception 'record_letter_explanation: options must be an array of {title, how, until}';
  end if;
  for opt in select * from jsonb_array_elements(coalesce(p -> 'options', '[]')) loop
    if jsonb_typeof(opt) <> 'object' or nullif(btrim(coalesce(opt ->> 'title', '')), '') is null then
      raise exception 'record_letter_explanation: every option needs a title';
    end if;
  end loop;

  return query
  insert into letter_explanations as e (document_id, origin, locale, letter_locale, summary, meaning,
    if_ignored, options, act_by, reply_kind, draft_reply, draft_translation, draft_missing,
    suspicious, source_fingerprint, skill_version, file_name)
  values (d.id, coalesce(p ->> 'origin', 'intake'), p ->> 'locale', p ->> 'letter_locale',
    btrim(p ->> 'summary'), p ->> 'meaning', p ->> 'if_ignored', coalesce(p -> 'options', '[]'),
    (p ->> 'act_by')::date, coalesce(p ->> 'reply_kind', 'none'), nullif(btrim(coalesce(p ->> 'draft_reply', '')), ''),
    nullif(btrim(coalesce(p ->> 'draft_translation', '')), ''),
    coalesce(array(select jsonb_array_elements_text(p -> 'draft_missing')), '{}'),
    coalesce((p ->> 'suspicious')::boolean, false), d.body_fingerprint, p ->> 'skill_version',
    left(dossier_label('explain_title') || ': ' || regexp_replace(d.name, '\.[A-Za-z0-9]{2,5}$', ''), 200))
  on conflict (document_id) do update set
    origin = excluded.origin, locale = excluded.locale, letter_locale = excluded.letter_locale,
    summary = excluded.summary, meaning = excluded.meaning, if_ignored = excluded.if_ignored,
    options = excluded.options, act_by = excluded.act_by, reply_kind = excluded.reply_kind,
    draft_reply = excluded.draft_reply, draft_translation = excluded.draft_translation,
    draft_missing = excluded.draft_missing, suspicious = excluded.suspicious,
    source_fingerprint = excluded.source_fingerprint, skill_version = excluded.skill_version,
    file_name = excluded.file_name,
    -- the Doc is rewritten in place, so the person keeps one link
    rendered_at = null, render_attempts = 0, render_error = null
  returning e.*;
end $function$;

-- 2. What still needs an explanation ------------------------------------------------------

create or replace view public.v_letters_to_explain with (security_invoker = on) as
select d.id as document_id, d.name, d.document_type_key, d.issuer, d.issued_on, d.subject_person,
       d.drive_url, t.language, t.char_count, (e.id is not null) as text_changed
from documents d
join document_texts t on t.document_id = d.id and t.extraction_status = 'done' and t.char_count > 0
left join letter_explanations e on e.document_id = d.id
where d.document_type_key in (select jsonb_array_elements_text(coalesce(setting('explain_letter_types'),
        '["official_decision","tax_assessment","authority_letter","notary_letter","insurance_correspondence"]'::jsonb)))
  and d.duplicate_of is null
  and d.status not in ('stale', 'to_archive')
  and coalesce(d.issued_on, d.added_at::date) >= current_date - 180
  and (e.id is null or e.source_fingerprint is distinct from d.body_fingerprint)
order by coalesce(d.issued_on, d.added_at::date) desc;
comment on view public.v_letters_to_explain is 'Authority and legal letters from the last 180 days with text and no explanation, or whose text changed since it was written. The Drive intake explains them; older letters only on request.';
revoke all on public.v_letters_to_explain from anon, authenticated, service_role;

create or replace view public.v_letter_explanations with (security_invoker = on) as
select e.id, e.document_id, d.name as letter, d.issuer, d.issued_on, d.document_type_key,
       coalesce(hm.name, d.subject_person) as person, e.summary, e.act_by, e.reply_kind,
       e.suspicious, e.draft_missing, e.origin,
       coalesce(e.drive_url, d.drive_url) as url, (e.drive_url is not null) as has_doc,
       x.due_on as objection_until, e.created_at, e.updated_at
from letter_explanations e
join documents d on d.id = e.document_id
left join household_members hm on hm.id = d.member_id
left join lateral (
  select dl.due_on from deadlines dl
  where dl.source_kind = 'document' and dl.source_id = d.id and dl.deadline_type = 'legal_response'
    and dl.status = 'open'
  order by dl.due_on limit 1) x on true
order by e.updated_at desc;
comment on view public.v_letter_explanations is 'Every explained letter with its one-line summary, the date to act by, the open objection deadline, and the link: the Google Doc once rendered, the letter itself before that.';
revoke all on public.v_letter_explanations from anon, authenticated, service_role;

-- 3. The text of the Doc ------------------------------------------------------------------

create or replace function public.explanation_text(p_id uuid)
returns text language plpgsql stable set search_path to 'public' as $function$
-- Lines starting "# ", "## " and "- " become a title, a heading and a bullet in the Doc,
-- as in the emergency binder. Text from the letter never becomes a heading.
declare
  e letter_explanations; d documents; o jsonb; out text;
  plain text;
begin
  select * into e from letter_explanations where id = p_id;
  if e.id is null then return null; end if;
  select * into d from documents where id = e.document_id;
  out := '# ' || coalesce(e.file_name, d.name) || E'\n' || e.summary || E'\n';
  if e.suspicious then out := out || E'\n' || dossier_label('explain_suspicious') || E'\n'; end if;
  if e.act_by is not null then
    out := out || E'\n' || dossier_label('explain_act_by') || ': ' || to_char(e.act_by, 'YYYY-MM-DD') || E'\n';
  end if;
  out := out || E'\n## ' || dossier_label('explain_says') || E'\n'
    || regexp_replace(e.meaning, '^(#+|- )\s*', '', 'gn') || E'\n';
  out := out || E'\n## ' || dossier_label('explain_if_ignored') || E'\n'
    || regexp_replace(e.if_ignored, '^(#+|- )\s*', '', 'gn') || E'\n';
  if jsonb_array_length(e.options) > 0 then
    out := out || E'\n## ' || dossier_label('explain_options') || E'\n';
    for o in select * from jsonb_array_elements(e.options) loop
      out := out || '- ' || replace(o ->> 'title', E'\n', ' ')
        || coalesce(': ' || replace(nullif(btrim(o ->> 'how'), ''), E'\n', ' '), '')
        || coalesce(' (' || dossier_label('until') || ' ' || nullif(btrim(o ->> 'until'), '') || ')', '') || E'\n';
    end loop;
  end if;
  if e.reply_kind = 'objection' then
    out := out || E'\n' || dossier_label('explain_objection') || E'\n';
  end if;
  if e.draft_reply is not null then
    out := out || E'\n## ' || dossier_label('explain_draft') || E'\n';
    if e.draft_missing <> '{}' then
      out := out || dossier_label('explain_draft_missing') || ': ' || array_to_string(e.draft_missing, ', ') || E'\n\n';
    end if;
    out := out || regexp_replace(e.draft_reply, '^(#+|- )\s*', '', 'gn') || E'\n';
    if e.draft_translation is not null then
      out := out || E'\n## ' || dossier_label('explain_draft_translation') || E'\n'
        || regexp_replace(e.draft_translation, '^(#+|- )\s*', '', 'gn') || E'\n';
    end if;
  end if;
  out := out || E'\n## ' || dossier_label('explain_original') || E'\n' || d.name || E'\n' || d.drive_url || E'\n';
  out := out || E'\n' || dossier_label('explain_not_advice');
  return out;
end $function$;
revoke execute on function public.explanation_text(uuid) from anon, authenticated, public;

-- 4. The bridge's side ------------------------------------------------------------------

create or replace function public.explanations_to_render(p_limit integer default 5)
returns table(id uuid, file_name text, folder_id text, doc_id text, text text)
language sql stable security definer set search_path to 'public' as $$
  select e.id, e.file_name,
         coalesce(d.drive_parent_id, setting('drive_folders') ->> 'catch_all'),
         e.drive_doc_id, explanation_text(e.id)
  from letter_explanations e join documents d on d.id = e.document_id
  where e.rendered_at is null and e.render_attempts < 3
  order by e.act_by nulls last, e.updated_at
  limit greatest(1, least(coalesce(p_limit, 5), 20))
$$;

create or replace function public.explanation_rendered(p_id uuid, p_doc_id text, p_url text)
returns void language plpgsql security definer set search_path to 'public' as $function$
begin
  perform set_config('app.actor', 'bridge', true);
  update letter_explanations set drive_doc_id = p_doc_id, drive_url = p_url, rendered_at = now(),
    render_error = null
  where letter_explanations.id = p_id;
  if not found then raise exception 'explanation_rendered: no explanation %', p_id; end if;
end $function$;

create or replace function public.explanation_render_failed(p_id uuid, p_error text)
returns void language sql security definer set search_path to 'public' as $$
  update letter_explanations set render_attempts = render_attempts + 1, render_error = left(p_error, 500)
  where id = p_id and rendered_at is null
$$;

revoke execute on function public.explanations_to_render(integer), public.explanation_rendered(uuid, text, text),
  public.explanation_render_failed(uuid, text) from anon, authenticated, public;
grant execute on function public.explanations_to_render(integer), public.explanation_rendered(uuid, text, text),
  public.explanation_render_failed(uuid, text) to service_role;
revoke execute on function public.record_letter_explanation(uuid, jsonb) from anon, authenticated, public, service_role;

-- 5. Labels -----------------------------------------------------------------------------

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
      'letter_not_advice', 'Filled in from your documents. Not legal advice: read every line, check the recipient, the number and the dates, and sign it yourself.',
      'explain_title',    'Explained',
      'explain_says',     'What this letter says',
      'explain_if_ignored', 'If you do nothing',
      'explain_options',  'What you can do',
      'explain_act_by',   'Act by',
      'explain_draft',    'Draft reply',
      'explain_draft_translation', 'What the draft says',
      'explain_draft_missing', 'Fill in before sending',
      'explain_objection', 'To object, say "write the objection" in any chat: Claude fills in the reviewed template with the file number, the decision date and the deadline.',
      'explain_suspicious', 'Check first: this letter does not come from a sender the index knows, or it asks for something unusual. Contact the sender through the address or phone number on their official website, not the one in the letter.',
      'explain_original', 'The letter',
      'explain_not_advice', 'Explained by AI from the letter and your documents. Not legal advice: when money, a right or your residence status is at stake, ask a counselling service or a lawyer before the deadline.'
    ) ->> p_key,
    p_key)
$$;
revoke execute on function public.dossier_label(text) from anon, authenticated, public;

update public.life_settings set value = '"0.12.0"', updated_at = now()
where key = 'schema_version'
  and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"', '"0.7.0"', '"0.8.0"', '"0.9.0"', '"0.10.0"', '"0.11.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                     -- "0.12.0"
--   select value from life_settings where key = 'explain_letter_types';
--   select count(*) from v_letters_to_explain;                                         -- recent letters waiting
--   select letter, summary, act_by, has_doc from v_letter_explanations limit 5;
--   select count(*) from explanations_to_render(20);                                   -- the bridge's queue
