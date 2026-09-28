-- 0005: configuration lives in Supabase, the emergency binder speaks the owner's language,
-- the system ignores its own mail, and the nightly derivations run on pg_cron.
--
-- Every value the skills and the Apps Script need (folder ids, time zone, languages, task
-- provider) is a row in life_settings. The setup skill fills them in. Nothing personal is
-- hard-coded anywhere else.

-- 1. Read helpers -----------------------------------------------------------------------

create or replace function public.setting(p_key text)
returns jsonb language sql stable set search_path to 'public' as $$
  select value from life_settings where key = p_key
$$;

create or replace function public.setting_text(p_key text, p_default text default null)
returns text language sql stable set search_path to 'public' as $$
  select coalesce((select value #>> '{}' from life_settings where key = p_key), p_default)
$$;

-- 2. Defaults. `on conflict do nothing`, so re-running never overwrites a real setting. --

insert into public.life_settings (key, value) values
  ('schema_version',          '"0.1.0"'),
  ('timezone',                '"UTC"'),
  ('output_locale',           '"en"'),
  ('input_locales',           '["en"]'),
  ('region',                  'null'),
  ('owner_name',              'null'),
  ('owner_email',             'null'),
  ('drive_folders',           '{"inbox": null, "emergency": null, "backups": null, "catch_all": null}'),
  ('task_provider',           '"none"'),
  ('task_targets',            '{"system_project": null, "default_project": null, "label": "mail"}'),
  ('notes_provider',          '"none"'),
  ('notes_targets',           '{"reports_folder": null}'),
  ('bridge_categories',       '["legal_notary","government","bank_finance","bills_payments"]'),
  ('current_address',         'null'),
  ('former_address_patterns', '[]'),
  ('address_audit_ignore',    '[]'),
  ('tax_year',                to_jsonb(extract(year from now())::int)),
  ('emergency_contacts',      '[]'),
  ('dossier_labels',          '{}')
on conflict (key) do nothing;

-- 3. The bridge scope follows the setting instead of a hard-coded list. -----------------

create or replace function public.bridge_in_scope(cat text)
returns boolean language sql stable set search_path to 'public' as $$
  select cat = any (
    coalesce(
      (select array_agg(x) from jsonb_array_elements_text(setting('bridge_categories')) x),
      array['legal_notary','government','bank_finance','bills_payments']
    )
  )
$$;

-- 4. Localized emergency binder. -------------------------------------------------------
-- Labels come from packs/lang/<locale>/dossier.json, which the setup skill writes into
-- life_settings.dossier_labels. Missing keys fall back to English.

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
      'none',             '- none'
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
                             || coalesce(' ' || dossier_label('until') || ' ' || to_char(m.next_action_on,'YYYY-MM-DD'),''), E'\n' order by m.next_action_on nulls last)
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
 coalesce((select string_agg('- ' || coalesce(d.subject_person,'?') || ': ' || t.label
                             || coalesce(', ' || dossier_label('valid_until') || ' ' || to_char(d.expiry_date,'YYYY-MM-DD'),'')
                             || coalesce(', ' || dossier_label('original') || ': ' || d.physical_location,'') || ' | ' || d.drive_url, E'\n' order by d.subject_person, t.label)
           from documents d join document_types t on t.key = d.document_type_key
           where t.domain = 'identity' and d.duplicate_of is null and d.status = 'current'), dossier_label('none')),
 '', '## ' || dossier_label('property'),
 coalesce((select string_agg('- ' || t.label || ': ' || d.name || coalesce(', ' || dossier_label('original') || ': ' || d.physical_location,'') || ' | ' || d.drive_url, E'\n' order by t.label)
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

-- 5. The system never files its own mail. --------------------------------------------

insert into public.classification_rules (scope, priority, match_field, match_op, match_value, set_category, notes)
select * from (values
  ('email', 1, 'subject', 'contains', 'attachment-bridge:',       'none', 'Error alerts from the Apps Script bridge'),
  ('email', 1, 'subject', 'contains', 'has not run for',          'none', 'Watchdog alerts from the Apps Script bridge'),
  ('email', 1, 'subject', 'contains', 'Daily brief',              'none', 'The system''s own daily brief')
) v(scope, priority, match_field, match_op, match_value, set_category, notes)
where not exists (select 1 from public.classification_rules r
                  where r.scope = v.scope and r.match_field = v.match_field and r.match_value = v.match_value);

-- 6. Nightly deterministic work, only where pg_cron exists (it does on Supabase). --------

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if not exists (select 1 from cron.job where jobname = 'nightly-derivations') then
      perform cron.schedule('nightly-derivations', '15 1 * * *', 'select public.run_nightly_derivations()');
    end if;
  else
    raise notice 'pg_cron not available: schedule run_nightly_derivations() yourself';
  end if;
end $$;

revoke execute on function public.setting(text), public.setting_text(text, text),
  public.dossier_label(text), public.bridge_in_scope(text), public.emergency_dossier()
  from anon, authenticated, public;
