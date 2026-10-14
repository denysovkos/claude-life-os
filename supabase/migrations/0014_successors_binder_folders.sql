-- 0014: successors, a truthful emergency binder, Drive resolvability, unmapped folders.
--
-- * document_types.successor_types: which types replace an expired document of this
--   type. A temporary residence permit is replaced by a new temporary one or by a
--   permanent one; without this, a settlement permit read as "expired without successor".
--   v_expired_without_successor applies it.
-- * documents.drive_parent_id (the folder the intake saw), drive_checked_at and
--   drive_missing_since (set by the Apps Script bridge through mark_drive_check(), or by
--   the intake when Drive says "not found"). A document whose file is gone stays in the
--   index (its row is history), but the binder stops presenting the dead link as a file.
-- * emergency_dossier(): overdue next actions are labelled overdue, an identity document
--   with no subject says so instead of "?", and missing files are marked.
-- * v_unmapped_folders: folders that hold indexed documents but have no
--   drive_folder_areas row, which is why those documents have no area.
--
-- Additive; the binder function keeps its signature. Safe to run twice.

-- 1. Successor types --------------------------------------------------------------------

alter table public.document_types add column if not exists successor_types text[];
comment on column public.document_types.successor_types is 'Types that count as the successor of an expired document of this type (null: only the same type). Used by v_expired_without_successor.';

update public.document_types set successor_types = array['residence_permit_temporary','residence_permit_permanent']
where key = 'residence_permit_temporary' and successor_types is null;
update public.document_types set successor_types = array['fiktionsbescheinigung','residence_permit_temporary','residence_permit_permanent']
where key = 'fiktionsbescheinigung' and successor_types is null;

-- 2. Drive location and resolvability ---------------------------------------------------

alter table public.documents add column if not exists drive_parent_id text;
alter table public.documents add column if not exists drive_checked_at timestamptz;
alter table public.documents add column if not exists drive_missing_since timestamptz;
comment on column public.documents.drive_parent_id is 'Drive folder the file was in when last indexed. Feeds v_unmapped_folders.';
comment on column public.documents.drive_missing_since is 'First time Drive answered "not found" (or trashed) for drive_file_id. Null when the file resolves. The row is kept; the binder marks the link as missing.';

-- the bookkeeping columns are not human corrections
create or replace function public.log_correction()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
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
             'todoist_task_id','calendar_event_id','attachments_extracted',
             'drive_checked_at','drive_missing_since','drive_parent_id') then
      continue;
    end if;
    if (oldv -> k) is distinct from (newv -> k) then
      insert into corrections (table_name, row_id, field, old_value, new_value, source)
      values (tg_table_name, new.id, k, oldv ->> k, newv ->> k, actor);
    end if;
  end loop;
  return new;
end $function$;

create or replace function public.drive_check_batch(p_limit integer default 100)
returns table(drive_file_id text) language sql stable security definer set search_path to 'public' as $$
  select d.drive_file_id from documents d
  where d.duplicate_of is null and d.drive_file_id is not null
  order by (d.status = 'current') desc, d.drive_checked_at nulls first
  limit greatest(p_limit, 1)
$$;

create or replace function public.mark_drive_check(p_checked text[], p_missing text[] default '{}')
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare ok int; gone int;
begin
  perform set_config('app.actor', 'bridge', true);
  update documents set drive_checked_at = now(), drive_missing_since = null
  where drive_file_id = any (p_checked) and not drive_file_id = any (coalesce(p_missing, '{}'));
  get diagnostics ok = row_count;
  update documents set drive_checked_at = now(), drive_missing_since = coalesce(drive_missing_since, now())
  where drive_file_id = any (coalesce(p_missing, '{}'));
  get diagnostics gone = row_count;
  return jsonb_build_object('resolvable', ok, 'missing', gone);
end $function$;

revoke execute on function public.drive_check_batch(integer), public.mark_drive_check(text[], text[])
  from anon, authenticated, public;
grant execute on function public.drive_check_batch(integer), public.mark_drive_check(text[], text[]) to service_role;

-- 3. Expired without a successor --------------------------------------------------------

create or replace view public.v_expired_without_successor with (security_invoker = on) as
select d.id, d.name, d.document_type_key, t.label, d.subject_person, d.expiry_date, d.drive_url,
       exists (select 1 from documents a join document_types at on at.key = a.document_type_key
               where at.domain = t.domain and a.document_type_key like '%application%'
                 and a.duplicate_of is null
                 and lower(trim(a.subject_person)) = lower(trim(d.subject_person))
                 and coalesce(a.issued_on, a.added_at::date) >= d.expiry_date - 180) as application_on_file
from documents d
join document_types t on t.key = d.document_type_key
where t.expiry_expected and (t.hard_deadline or t.domain = 'identity')
  and d.duplicate_of is null and d.superseded_by is null
  and d.status in ('current','expired')
  and d.expiry_date < current_date
  and d.subject_person is not null
  -- no successor: nothing of a successor type for the same person that runs longer
  and not exists (
    select 1 from documents s
    where s.id <> d.id and s.duplicate_of is null
      and s.status in ('current','expired')
      and s.document_type_key = any (coalesce(t.successor_types, array[t.key]))
      and lower(trim(s.subject_person)) = lower(trim(d.subject_person))
      and (s.expiry_date is null or s.expiry_date > d.expiry_date))
order by d.expiry_date;
comment on view public.v_expired_without_successor is 'Expired identity or hard-deadline documents with no successor (document_types.successor_types) for the same person. application_on_file: an application for the same domain exists, which is the expensive case: the title lapsed while the decision is pending.';

-- 4. Folders that hold documents but map to no area ------------------------------------

create or replace view public.v_unmapped_folders with (security_invoker = on) as
select d.drive_parent_id, count(*) as documents, min(d.name) as example
from documents d
where d.duplicate_of is null and d.drive_parent_id is not null and d.area_name is null
  and not exists (select 1 from drive_folder_areas a where a.drive_folder_id = d.drive_parent_id)
  and d.drive_parent_id is distinct from (setting('drive_folders') ->> 'inbox')
group by d.drive_parent_id
order by count(*) desc;
comment on view public.v_unmapped_folders is 'Drive folders holding indexed documents with no area. The intake also checks ancestors, so mapping a parent folder covers its subfolders. The weekly folder check asks the person for an area name per row.';

-- 5. The emergency binder tells the truth ----------------------------------------------

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
      'file_missing',     'file missing in Drive since'
    ) ->> p_key,
    p_key)
$$;

create or replace function public.emergency_dossier()
returns text language sql stable security definer set search_path to 'public' as $function$
select concat_ws(E'\n',
 '# ' || dossier_label('title') || ' (' || dossier_label('generated') || ' '
      || to_char(now() at time zone setting_text('timezone','UTC'),'YYYY-MM-DD') || ')',
 dossier_label('intro'),
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
 coalesce((select string_agg('- ' || to_char(d.due_on,'YYYY-MM-DD') || ': ' || d.title, E'\n' order by d.due_on)
           from deadlines d where d.status = 'open' and d.hard and d.due_on >= current_date - 30), dossier_label('none')),
 '', '## ' || dossier_label('loans'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || coalesce(', ' || dossier_label('until') || ' ' || to_char(rp.contract_end,'YYYY-MM-DD'),'') || coalesce(', Ref. ' || rp.reference,''), E'\n')
           from recurring_payments rp where rp.status='active' and rp.category='loan'), dossier_label('none')),
 '', '## ' || dossier_label('insurance'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || coalesce(', Ref. ' || rp.reference,'')
                             || coalesce(', ' || dossier_label('notice') || ' ' || rp.notice_period_months || ' ' || dossier_label('months'),''), E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category in ('insurance','pension') and rp.amount > 0), dossier_label('none')),
 '', '## ' || dossier_label('subscriptions'),
 coalesce((select string_agg('- ' || rp.name || ', ' || rp.vendor || ', ' || rp.amount || ' ' || coalesce(rp.currency,'EUR') || '/' || rp.period
                             || case when rp.notice_period_months is not null
                                     then ', ' || dossier_label('notice') || ' ' || rp.notice_period_months || ' ' || dossier_label('months')
                                     else ', ' || dossier_label('notice_unknown') end, E'\n' order by rp.monthly_equivalent desc)
           from recurring_payments rp where rp.status='active' and rp.category not in ('loan','insurance','pension') and rp.amount > 0), dossier_label('none')),
 '', dossier_label('total') || ': ' || coalesce((select round(sum(monthly_equivalent),2) from recurring_payments where status='active'),0) || ' ' || dossier_label('per_month') || '.',
 '', '## ' || dossier_label('identity'),
 coalesce((select string_agg('- ' || coalesce(nullif(trim(d.subject_person), ''), dossier_label('subject_unknown')) || ': ' || t.label
                             || coalesce(', ' || dossier_label('valid_until') || ' ' || to_char(d.expiry_date,'YYYY-MM-DD'),'')
                             || coalesce(', ' || dossier_label('original') || ': ' || d.physical_location,'')
                             || case when d.drive_missing_since is not null
                                     then ' | ' || dossier_label('file_missing') || ' ' || to_char(d.drive_missing_since,'YYYY-MM-DD')
                                     else ' | ' || d.drive_url end, E'\n' order by d.subject_person nulls last, t.label)
           from documents d join document_types t on t.key = d.document_type_key
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

revoke execute on function public.dossier_label(text), public.emergency_dossier() from anon, authenticated, public;

-- Verification:
--   select count(*) from v_expired_without_successor;                      -- 0 when every lapsed title has a successor
--   select emergency_dossier() ~ '\?: ';                                   -- false
--   select mark_drive_check(array[]::text[], array[]::text[]);             -- {"missing": 0, "resolvable": 0}
--   select * from v_unmapped_folders;
