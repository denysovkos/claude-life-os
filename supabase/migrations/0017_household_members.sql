-- 0017: household members. The partner's and the children's papers are tracked as theirs.
--
-- Until now the person a document, deadline or contract is about was free text
-- (subject_person), so "Anna", "Anna Beispiel" and "A. Beispiel" were three people, the
-- brief never said whose passport expires, and nothing could answer "what does Max have
-- expiring". This migration adds:
--
-- 1. household_members: the people whose paperwork this system handles, one row each
--    (self, partner, child, parent, other), with the spellings they appear under
--    (aliases) and an optional birth date. Rows are deactivated, never removed. Only the
--    person changes this table, in setup or reconfigure; a night run never does.
-- 2. member_id on documents, deadlines, recurring_payments, emails, matters and bundles.
--    A trigger fills it from subject_person (owner_person on matters) when the name
--    resolves to exactly one member, and fills the name from the member when only the id
--    is given. A deadline inherits its source document's or mail's member, a payment its
--    document's. So an older skill that writes only subject_person keeps working, and
--    rows a name cannot place (a joint document, an unknown name) stay with member_id null.
-- 3. link_household_members(apply): rows written before a member existed (or before an
--    alias was added), as a dry run or applied. v_unassigned_people: names in the index
--    that match no member, for the person to place. v_household_overview: per member,
--    documents, identity papers and the next expiry, open deadlines, monthly costs.
-- 4. The brief names whose deadline or letter it is (never the owner's own), the
--    emergency binder lists the household and whose hard deadline is whose, a successor
--    document counts for the same member however the name was spelled, and snapshots
--    include the household.
--
-- Additive only; this file neither drops an object nor removes a row, and moves no date.
-- Safe to run twice.

-- 1. The household ---------------------------------------------------------------------

create table if not exists public.household_members (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  relation    text not null default 'other',
  birth_date  date,
  aliases     text[] not null default '{}',
  active      boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint household_members_relation_check check (relation in ('self','partner','child','parent','other')),
  constraint household_members_name_check check (length(btrim(name)) between 1 and 120)
);
create unique index if not exists household_members_name_uidx on public.household_members (lower(btrim(name)));
create unique index if not exists household_members_self_uidx on public.household_members (relation) where relation = 'self';
alter table public.household_members enable row level security;
-- nothing outside the skill's own connection reads who lives in the household: the
-- bridge sees the members only through emergency_dossier(), which runs as its owner
revoke all on public.household_members from anon, authenticated, service_role;
comment on table public.household_members is 'The people whose paperwork this system handles: the owner (relation self, at most one), partner, children, parents, others. aliases holds every other spelling a document or letter uses for them (full legal name, maiden name, nickname). Written only by setup and reconfigure, with the person; a night run never adds or changes a member. Deactivate (active = false) instead of removing, so their documents keep a name.';
comment on column public.household_members.aliases is 'Other spellings, matched case-insensitively and whole: "Anna Maria Beispiel", "A. Beispiel". A name that two members share resolves to neither.';
comment on column public.household_members.birth_date is 'Optional. Shown in the emergency binder and used for age; a child''s papers often expire sooner and need both parents.';

create or replace trigger household_members_set_updated_at before update on public.household_members
  for each row execute function public.set_updated_at();

insert into public.household_members (name, relation, notes)
select btrim(setting_text('owner_name')), 'self', 'created from owner_name by 0017'
where coalesce(btrim(setting_text('owner_name')), '') <> ''
  and not exists (select 1 from public.household_members
                  where relation = 'self' or lower(btrim(name)) = lower(btrim(setting_text('owner_name'))));

-- 2. Who a row is about ------------------------------------------------------------------

alter table public.documents          add column if not exists member_id uuid references public.household_members(id) on delete set null;
alter table public.deadlines          add column if not exists member_id uuid references public.household_members(id) on delete set null;
alter table public.recurring_payments add column if not exists member_id uuid references public.household_members(id) on delete set null;
alter table public.emails             add column if not exists member_id uuid references public.household_members(id) on delete set null;
alter table public.matters            add column if not exists member_id uuid references public.household_members(id) on delete set null;
alter table public.bundles            add column if not exists member_id uuid references public.household_members(id) on delete set null;

create index if not exists documents_member_idx          on public.documents (member_id) where member_id is not null;
create index if not exists deadlines_member_idx          on public.deadlines (member_id) where member_id is not null;
create index if not exists recurring_payments_member_idx on public.recurring_payments (member_id) where member_id is not null;
create index if not exists emails_member_idx             on public.emails (member_id) where member_id is not null;

comment on column public.documents.member_id is 'The household member the document is about. Filled by trigger from subject_person when that names exactly one member; null for joint documents and for people outside the household.';
comment on column public.deadlines.member_id is 'Whose deadline. From subject_person, else inherited from the source document or mail.';
comment on column public.recurring_payments.member_id is 'Whose contract (a child''s insurance, the partner''s phone). From subject_person, else from the linked document.';
comment on column public.emails.member_id is 'The household member a mail is about (a school letter for a child, a letter addressed to the partner). Set by the email intake; null for the owner''s own mail is fine.';
comment on column public.matters.member_id is 'Whose matter. From owner_person.';
comment on column public.bundles.member_id is 'Whose application or filing. From subject_person.';

create or replace function public.household_member_for(p_name text)
returns uuid language sql stable set search_path to 'public' as $$
  -- exactly one member whose name or alias is p_name (case and outer spaces ignored);
  -- none or more than one: null, never a guess
  select case when count(distinct m.id) = 1 then (array_agg(m.id))[1] end
  from household_members m
  where coalesce(btrim(p_name), '') <> ''
    and (lower(btrim(m.name)) = lower(btrim(p_name))
         or exists (select 1 from unnest(m.aliases) a where lower(btrim(a)) = lower(btrim(p_name))))
$$;

create or replace function public.household_person_label(p_member uuid, p_person text)
returns text language sql stable set search_path to 'public' as $$
  -- how the brief and the binder name whose item it is: the member's name, the stored
  -- text when it names nobody in the household, nothing for the owner's own items
  with x as (select coalesce(p_member, household_member_for(p_person)) as mid)
  select case when m.id is null then nullif(btrim(p_person), '')
              when m.relation = 'self' then null
              else m.name end
  from x left join household_members m on m.id = x.mid
$$;

create or replace function public.resolve_household_member()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
-- Keeps member_id and the person's name in step on documents, deadlines,
-- recurring_payments, matters and bundles:
--   * an explicitly set member_id wins, and the name follows it unless it already names
--     that member (so "Anna Maria Beispiel" stays as written);
--   * a new or changed name resolves to its member, or to null when it names nobody or
--     more than one (a joint document);
--   * a deadline with no member takes its source document's or mail's, a payment its
--     document's.
-- security definer: a writer that may not read household_members (the bridge's role)
-- still gets its row linked rather than an error.
declare
  person text; old_person text; m uuid;
  member_changed boolean := false;
begin
  if tg_op = 'UPDATE' then member_changed := new.member_id is distinct from old.member_id; end if;
  if tg_table_name = 'matters' then
    person := new.owner_person;
    if tg_op = 'UPDATE' then old_person := old.owner_person; end if;
  else
    person := new.subject_person;
    if tg_op = 'UPDATE' then old_person := old.subject_person; end if;
  end if;

  if member_changed and new.member_id is not null then
    if household_member_for(person) is distinct from new.member_id then
      select name into person from household_members where id = new.member_id;
    end if;
  elsif tg_op = 'INSERT' then
    if new.member_id is null then new.member_id := household_member_for(person); end if;
  elsif person is distinct from old_person and not member_changed then
    new.member_id := household_member_for(person);
  end if;

  -- nested, not "and": a field this table lacks must never be evaluated
  if new.member_id is null and not member_changed then
    if tg_table_name = 'deadlines' then
      if new.source_kind = 'document' then
        select d.member_id into m from documents d where d.id = new.source_id;
      elsif new.source_kind = 'email' then
        select e.member_id into m from emails e where e.id = new.source_id;
      end if;
      new.member_id := m;
    elsif tg_table_name = 'recurring_payments' then
      select d.member_id into m from documents d where d.id = new.document_id;
      new.member_id := m;
    end if;
  end if;

  if new.member_id is not null and coalesce(btrim(person), '') = '' then
    select name into person from household_members where id = new.member_id;
  end if;

  if tg_table_name = 'matters' then new.owner_person := person; else new.subject_person := person; end if;
  return new;
end $function$;

create or replace trigger documents_resolve_member before insert or update on public.documents
  for each row execute function public.resolve_household_member();
create or replace trigger deadlines_resolve_member before insert or update on public.deadlines
  for each row execute function public.resolve_household_member();
create or replace trigger recurring_payments_resolve_member before insert or update on public.recurring_payments
  for each row execute function public.resolve_household_member();
create or replace trigger matters_resolve_member before insert or update on public.matters
  for each row execute function public.resolve_household_member();
create or replace trigger bundles_resolve_member before insert or update on public.bundles
  for each row execute function public.resolve_household_member();

-- 3. Linking what was written before, and what is left over ----------------------------

create or replace function public.link_household_members(p_apply boolean default false)
returns table(table_name text, row_id uuid, label text, person text, member_id uuid, member text)
language plpgsql set search_path to 'public' as $function$
-- Rows with no member whose name now resolves to one (a member or alias added after they
-- were written), and deadlines and payments whose source has a member. p_apply = false
-- only lists them; true also links them, as setup. Dates, statuses and names are not
-- touched beyond the name following the member.
begin
  return query
  with cand as (
    select 'documents'::text as t, d.id, d.name as lbl, d.subject_person as p,
           household_member_for(d.subject_person) as mid
    from documents d where d.member_id is null
    union all
    select 'deadlines', x.id, x.title, x.subject_person,
           coalesce(household_member_for(x.subject_person),
                    case x.source_kind
                      when 'document' then (select coalesce(d.member_id, household_member_for(d.subject_person))
                                            from documents d where d.id = x.source_id)
                      when 'email' then (select e.member_id from emails e where e.id = x.source_id) end)
    from deadlines x where x.member_id is null
    union all
    select 'recurring_payments', r.id, r.name, r.subject_person,
           coalesce(household_member_for(r.subject_person),
                    (select coalesce(d.member_id, household_member_for(d.subject_person))
                     from documents d where d.id = r.document_id))
    from recurring_payments r where r.member_id is null
    union all
    select 'matters', mt.id, mt.name, mt.owner_person, household_member_for(mt.owner_person)
    from matters mt where mt.member_id is null
    union all
    select 'bundles', b.id, b.name, b.subject_person, household_member_for(b.subject_person)
    from bundles b where b.member_id is null
  )
  select c.t, c.id, c.lbl, c.p, c.mid, hm.name
  from cand c join household_members hm on hm.id = c.mid
  order by c.t, hm.name, c.lbl;

  if not p_apply then return; end if;
  perform set_config('app.actor', 'setup', true);

  update documents d set member_id = household_member_for(d.subject_person)
  where d.member_id is null and household_member_for(d.subject_person) is not null;

  update deadlines x set member_id = coalesce(household_member_for(x.subject_person),
         case x.source_kind
           when 'document' then (select d.member_id from documents d where d.id = x.source_id)
           when 'email' then (select e.member_id from emails e where e.id = x.source_id) end)
  where x.member_id is null
    and coalesce(household_member_for(x.subject_person),
         case x.source_kind
           when 'document' then (select d.member_id from documents d where d.id = x.source_id)
           when 'email' then (select e.member_id from emails e where e.id = x.source_id) end) is not null;

  update recurring_payments r set member_id = coalesce(household_member_for(r.subject_person),
         (select d.member_id from documents d where d.id = r.document_id))
  where r.member_id is null
    and coalesce(household_member_for(r.subject_person),
         (select d.member_id from documents d where d.id = r.document_id)) is not null;

  update matters mt set member_id = household_member_for(mt.owner_person)
  where mt.member_id is null and household_member_for(mt.owner_person) is not null;

  update bundles b set member_id = household_member_for(b.subject_person)
  where b.member_id is null and household_member_for(b.subject_person) is not null;
end $function$;

create or replace view public.v_unassigned_people with (security_invoker = on) as
select min(btrim(p.person)) as person,
       count(*) as rows,
       count(*) filter (where p.t = 'documents') as documents,
       count(*) filter (where p.t = 'deadlines' and p.open) as open_deadlines,
       count(*) filter (where p.t = 'recurring_payments') as contracts,
       min(p.example) as example
from (
  select 'documents' as t, d.subject_person as person, d.name as example, false as open
  from documents d where d.member_id is null and d.duplicate_of is null
  union all
  select 'deadlines', x.subject_person, x.title, x.status = 'open'
  from deadlines x where x.member_id is null
  union all
  select 'recurring_payments', r.subject_person, r.name, false
  from recurring_payments r where r.member_id is null and r.status = 'active'
) p
where coalesce(btrim(p.person), '') <> ''
  and household_member_for(p.person) is null      -- a member's name not linked yet is link_household_members' job
group by lower(btrim(p.person))
order by count(*) desc, min(btrim(p.person));
comment on view public.v_unassigned_people is 'Names in the index that match no household member: someone to add (or an alias to add to an existing member), a joint document ("Anna, Max"), or a person outside the household. The monthly review and the doctor ask the person about each; nothing here is acted on unattended.';

create or replace view public.v_household_overview with (security_invoker = on) as
select m.id, m.name, m.relation, m.birth_date,
       case when m.birth_date is not null then extract(year from age(current_date, m.birth_date))::int end as age,
       m.active,
       (select count(*) from documents d
        where d.member_id = m.id and d.duplicate_of is null and d.status = 'current') as documents,
       (select count(*) from documents d join document_types t on t.key = d.document_type_key
        where d.member_id = m.id and d.duplicate_of is null and d.status = 'current' and t.domain = 'identity') as identity_documents,
       nx.expiry_date as next_identity_expiry,
       nx.label as next_identity_document,
       (select count(*) from deadlines x where x.member_id = m.id and x.status = 'open') as open_deadlines,
       (select count(*) from deadlines x where x.member_id = m.id and x.status = 'open' and x.hard) as open_hard_deadlines,
       nd.due_on as next_due_on,
       nd.title as next_deadline,
       (select round(sum(r.monthly_equivalent), 2) from recurring_payments r
        where r.member_id = m.id and r.status = 'active') as monthly_costs
from household_members m
left join lateral (
  select d.expiry_date, t.label from documents d join document_types t on t.key = d.document_type_key
  where d.member_id = m.id and d.duplicate_of is null and d.status = 'current'
    and t.domain = 'identity' and d.expiry_date is not null
  order by d.expiry_date limit 1) nx on true
left join lateral (
  select x.due_on, x.title from deadlines x
  where x.member_id = m.id and x.status = 'open' and x.due_on >= current_date
  order by x.due_on limit 1) nd on true
order by m.active desc,
         case m.relation when 'self' then 0 when 'partner' then 1 when 'child' then 2 when 'parent' then 3 else 4 end,
         m.birth_date nulls last, m.name;
comment on view public.v_household_overview is 'One row per household member: current documents, identity papers and the next one to expire, open (and hard) deadlines with the next one, monthly cost of their active contracts. identity_documents = 0 for an active member is worth a question in the monthly review.';

-- the same person, however the name was spelled, can hold the successor
create or replace view public.v_expired_without_successor with (security_invoker = on) as
select d.id, d.name, d.document_type_key, t.label, d.subject_person, d.expiry_date, d.drive_url,
       exists (select 1 from documents a join document_types at on at.key = a.document_type_key
               where at.domain = t.domain and a.document_type_key like '%application%'
                 and a.duplicate_of is null
                 and (a.member_id = d.member_id
                      or lower(trim(a.subject_person)) = lower(trim(d.subject_person)))
                 and coalesce(a.issued_on, a.added_at::date) >= d.expiry_date - 180) as application_on_file
from documents d
join document_types t on t.key = d.document_type_key
where t.expiry_expected and (t.hard_deadline or t.domain = 'identity')
  and d.duplicate_of is null and d.superseded_by is null
  and d.status in ('current','expired')
  and d.expiry_date < current_date
  and d.subject_person is not null
  and not exists (
    select 1 from documents s
    where s.id <> d.id and s.duplicate_of is null
      and s.status in ('current','expired')
      and s.document_type_key = any (coalesce(t.successor_types, array[t.key]))
      and (s.member_id = d.member_id
           or lower(trim(s.subject_person)) = lower(trim(d.subject_person)))
      and (s.expiry_date is null or s.expiry_date > d.expiry_date))
order by d.expiry_date;

-- 4. The brief says whose it is ----------------------------------------------------------

create or replace function public.build_briefing(p_date date default current_date)
returns jsonb language sql stable set search_path to 'public' as $function$
with
overdue_hard as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', household_person_label(member_id, subject_person), 'type', deadline_type) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and hard
    and (snoozed_until is null or snoozed_until <= p_date)
),
overdue_soft as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_overdue', p_date - due_on,
    'person', household_person_label(member_id, subject_person), 'type', deadline_type) order by due_on)
  from deadlines where status in ('open','missed') and due_on < p_date and not hard
    and (snoozed_until is null or snoozed_until <= p_date) and (p_date - due_on) % 7 = 0
),
due_now as (
  select jsonb_agg(jsonb_build_object('title', title, 'due_on', due_on, 'days_left', due_on - p_date,
    'hard', hard, 'person', household_person_label(member_id, subject_person), 'type', deadline_type,
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
      out := out || format('  · %s — %s days past %s%s',
        it->>'title', it->>'days_overdue', it->>'due_on',
        coalesce(' (' || (it->>'person') || ')', '')) || E'\n';
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
      out := out || format('  · %s — in %s days (%s)%s%s%s',
        it->>'title', it->>'days_left', it->>'due_on',
        coalesce(' (' || (it->>'person') || ')', ''),
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

-- 5. The binder lists the household ---------------------------------------------------

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
      'born',             'born'
    ) ->> p_key,
    p_key)
$$;

create or replace function public.emergency_dossier()
returns text language sql stable security definer set search_path to 'public' as $function$
select concat_ws(E'\n',
 '# ' || dossier_label('title') || ' (' || dossier_label('generated') || ' '
      || to_char(now() at time zone setting_text('timezone','UTC'),'YYYY-MM-DD') || ')',
 dossier_label('intro'),
 -- the household, only when one is recorded
 (select E'\n## ' || dossier_label('household') || E'\n'
         || string_agg('- ' || hm.name || ' (' || dossier_label('rel_' || hm.relation) || ')'
                       || coalesce(', ' || dossier_label('born') || ' ' || to_char(hm.birth_date,'YYYY-MM-DD'), ''),
                       E'\n' order by case hm.relation when 'self' then 0 when 'partner' then 1 when 'child' then 2
                                                       when 'parent' then 3 else 4 end, hm.birth_date nulls last, hm.name)
  from household_members hm where hm.active
  having count(*) > 0),
 '', '## ' || dossier_label('matters'),
 coalesce((select string_agg('- ' || m.name || coalesce(' (' || m.reference || ')','') || coalesce(': ' || m.next_action,'')
                             || case
                                  when m.next_action_on is null then ''
                                  when m.next_action_on < current_date
                                    then ' ' || dossier_label('overdue_since') || ' ' || to_char(m.next_action_on,'YYYY-MM-DD')
                                         || ' (' || dossier_label('close_or_reschedule') || ')'
                                  else ' ' || dossier_label('until') || ' ' || to_char(m.next_action_on,'YYYY-MM-DD') end,
                             E'\n' order by m.next_action_on nulls last)
           from matters m where m.status not in ('closed','done')), dossier_label('none')),
 '', '## ' || dossier_label('hard_deadlines'),
 coalesce((select string_agg('- ' || to_char(d.due_on,'YYYY-MM-DD') || ': ' || d.title
                             || coalesce(' (' || household_person_label(d.member_id, d.subject_person) || ')', ''),
                             E'\n' order by d.due_on)
           from deadlines d where d.status = 'open' and d.hard and d.due_on >= current_date - 30), dossier_label('none')),
 '', '## ' || dossier_label('loans'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || coalesce(', ' || dossier_label('until') || ' ' || to_char(rp.contract_end,'YYYY-MM-DD'),'') || coalesce(', Ref. ' || rp.reference,''), E'\n')
           from recurring_payments rp where rp.status='active' and rp.category='loan'), dossier_label('none')),
 '', '## ' || dossier_label('insurance'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || coalesce(', Ref. ' || rp.reference,'')
                             || coalesce(', ' || dossier_label('notice') || ' ' || rp.notice_period_months || ' ' || dossier_label('months'),'')
                             || coalesce(' (' || household_person_label(rp.member_id, rp.subject_person) || ')', ''),
                             E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category in ('insurance','pension') and rp.amount > 0), dossier_label('none')),
 '', '## ' || dossier_label('subscriptions'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || case when rp.notice_period_months is not null
                                     then ', ' || dossier_label('notice') || ' ' || rp.notice_period_months || ' ' || dossier_label('months')
                                     else ', ' || dossier_label('notice_unknown') end, E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category not in ('loan','insurance','pension') and rp.amount > 0), dossier_label('none')),
 '', dossier_label('total') || ': ' || coalesce((select round(sum(monthly_equivalent),2) from recurring_payments where status='active'),0) || ' ' || dossier_label('per_month') || '.',
 '', '## ' || dossier_label('identity'),
 coalesce((select string_agg('- ' || coalesce(hm.name, nullif(trim(d.subject_person), ''), dossier_label('subject_unknown')) || ': ' || t.label
                             || coalesce(', ' || dossier_label('valid_until') || ' ' || to_char(d.expiry_date,'YYYY-MM-DD'),'')
                             || coalesce(', ' || dossier_label('original') || ': ' || d.physical_location,'')
                             || case when d.drive_missing_since is not null
                                     then ' | ' || dossier_label('file_missing') || ' ' || to_char(d.drive_missing_since,'YYYY-MM-DD')
                                     else ' | ' || d.drive_url end, E'\n'
                             order by coalesce(hm.name, d.subject_person) nulls last, t.label)
           from documents d join document_types t on t.key = d.document_type_key
           left join household_members hm on hm.id = d.member_id
           where t.domain = 'identity' and d.duplicate_of is null and d.status = 'current'), dossier_label('none')),
 '', '## ' || dossier_label('property'),
 coalesce((select string_agg('- ' || t.label || ': ' || d.name || coalesce(', ' || dossier_label('original') || ': ' || d.physical_location,'')
                             || case when d.drive_missing_since is not null
                                     then ' | ' || dossier_label('file_missing') || ' ' || to_char(d.drive_missing_since,'YYYY-MM-DD')
                                     else ' | ' || d.drive_url end, E'\n' order by t.label)
           from documents d join document_types t on t.key = d.document_type_key
           where t.domain = 'property' and d.duplicate_of is null and d.status = 'current'
             and t.key in ('purchase_contract','land_registry_extract','mortgage_contract','mortgage_deed','weg_document')), dossier_label('none')),
 '', '## ' || dossier_label('contacts'),
 coalesce((select string_agg('- ' || (c->>'name') || ' (' || (c->>'role') || ')' || coalesce(', ' || (c->>'contact'), '') , E'\n')
           from life_settings s, jsonb_array_elements(s.value) c where s.key = 'emergency_contacts'), ''),
 coalesce((select string_agg(distinct '- ' || e.name || coalesce(' (' || e.role || ')','') || coalesce(', ' || array_to_string(e.emails, ', '),''), E'\n')
           from entities e
           where e.id in (select vendor_entity_id from recurring_payments where status='active')
              or e.role ~* 'lawyer|anwält|notar|hausverwalt|bank|berater|advisor'), dossier_label('none'))
)
$function$;

-- 6. Snapshots include the household ----------------------------------------------------

create or replace function public.backup_snapshot_add_settings()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  new.payload := coalesce(new.payload, '{}'::jsonb)
    || jsonb_build_object(
         'life_settings', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from life_settings s),
         'household_members', (select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from household_members h));
  new.row_counts := coalesce(new.row_counts, '{}'::jsonb)
    || jsonb_build_object('life_settings', (select count(*) from life_settings),
                          'household_members', (select count(*) from household_members));
  return new;
end $function$;

revoke execute on function public.household_member_for(text), public.household_person_label(uuid, text),
  public.resolve_household_member(), public.link_household_members(boolean),
  public.build_briefing(date), public.briefing_text(date), public.dossier_label(text),
  public.emergency_dossier(), public.backup_snapshot_add_settings()
  from anon, authenticated, public;

-- 7. Version ----------------------------------------------------------------------------

update public.life_settings set value = '"0.8.0"', updated_at = now()
where key = 'schema_version'
  and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"', '"0.7.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                -- "0.8.0"
--   select name, relation from household_members;                               -- the owner as self, once owner_name is set
--   select count(*) from link_household_members(false);                         -- rows a member or alias would link
--   select * from v_unassigned_people;                                          -- names that match no member
--   select * from v_household_overview;
--   select household_member_for('nobody at all');                               -- null
--   select count(*) from information_schema.role_table_grants
--   where table_name = 'household_members' and grantee in ('anon','authenticated','service_role');  -- 0
