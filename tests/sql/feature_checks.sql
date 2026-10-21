-- Feature checks for schema 0.6.x and later: each new database behaviour, exercised end to end on
-- throwaway rows. Runs in one transaction that is rolled back, so it is safe on a live
-- installation as well as in CI:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/sql/feature_checks.sql
--
-- A failed check raises an exception naming it; a clean run ends with the notice
-- "feature checks: all passed".

begin;

do $checks$
declare
  n bigint; s text; doc uuid; perm uuid; dl uuid; rp uuid; ok boolean; j jsonb; mem uuid; mem2 uuid; m uuid;
  tag text := 'fc-' || substr(md5(random()::text), 1, 8);   -- unique names for this run
begin
  perform set_config('app.actor', 'test', true);

  -- 1. registry -----------------------------------------------------------------------------
  select count(*) into n from document_types where key = 'utility_contract' and notice_period_expected;
  if n <> 1 then raise exception 'utility_contract must expect a notice period'; end if;
  select count(*) into n from document_types
  where key in ('utility_notice','authority_letter','insurance_correspondence') and not notice_period_expected;
  if n <> 3 then raise exception 'new document types missing'; end if;

  -- 2. write-backs: append mode and jsonb values ------------------------------------------
  insert into deadlines (title, deadline_type, due_on, status, notes)
  values (tag || ' deadline', 'other', current_date + 30, 'open', 'first line') returning id into dl;
  insert into skill_writebacks (target_table, target_id, column_name, value, mode)
  values ('deadlines', dl, 'notes', to_jsonb('second line'::text), 'append');
  select notes into s from deadlines where id = dl;
  if s <> E'first line\nsecond line' then raise exception 'append write-back gave %', s; end if;

  insert into improvement_proposals (title, problem, proposed_change, autonomy)
  values (tag, 'p', 'c', 'ask') returning id into rp;
  insert into skill_writebacks (target_table, target_id, column_name, value)
  values ('improvement_proposals', rp, 'evidence', '{"probe": [1, 2, 3]}'::jsonb);
  select evidence into j from improvement_proposals where id = rp;
  if j <> '{"probe": [1, 2, 3]}'::jsonb then raise exception 'jsonb write-back gave %', j; end if;

  -- 3. stated dates are never recounted -----------------------------------------------------
  insert into documents (drive_file_id, name, drive_url, document_type_key, subject_person, issued_on, expiry_date, status)
  values (tag || '-permit', tag || ' permit', 'https://example.invalid/p', 'residence_permit_temporary',
          tag || ' Person', current_date - 800, current_date - 10, 'expired')
  returning id into doc;
  insert into deadlines (title, deadline_type, due_on, status, source_kind, source_id, rule_key, date_basis)
  values (tag || ' stated', 'document_expiry', current_date + 100, 'open', 'document', doc,
          'residence_permit_apply_by', 'stated') returning id into dl;
  select action into s from rederive_deadlines(false) where deadline_id = dl;
  if s <> 'stated_kept' then raise exception 'a stated deadline was not kept: %', s; end if;
  update deadlines set status = 'cancelled' where id = dl;

  -- 4. expired without successor, and the successor that closes it --------------------------
  select count(*) into n from v_expired_without_successor where id = doc;
  if n <> 1 then raise exception 'an expired permit without successor is not listed'; end if;
  insert into documents (drive_file_id, name, drive_url, document_type_key, subject_person, expiry_date, status)
  values (tag || '-perm', tag || ' settlement permit', 'https://example.invalid/q', 'residence_permit_permanent',
          tag || ' person', current_date + 3650, 'current')
  returning id into perm;
  select count(*) into n from v_expired_without_successor where id = doc;
  if n <> 0 then raise exception 'a permanent permit did not count as successor of a temporary one'; end if;

  -- 5. auto-renewing payments nobody watches -----------------------------------------------
  insert into recurring_payments (name, category, amount, period, auto_renews, status)
  values (tag || ' gym', 'subscription', 30, 'monthly', true, 'active') returning id into rp;
  select count(*) into n from v_auto_renew_unwatched where id = rp;
  if n <> 1 then raise exception 'v_auto_renew_unwatched misses an auto-renewal with no exit'; end if;
  update recurring_payments set notice_period_months = 1 where id = rp;
  select count(*) into n from v_auto_renew_unwatched where id = rp;
  if n <> 0 then raise exception 'a rolling contract with a known notice period is still listed'; end if;

  -- 6. contract arithmetic ------------------------------------------------------------------
  if contract_cancel_by(date '2026-01-31', 12, 1) <> date '2026-12-30' then
    raise exception 'contract_cancel_by month-end case gave %', contract_cancel_by(date '2026-01-31', 12, 1);
  end if;

  -- 7. masked addresses ---------------------------------------------------------------------
  if not ('lieferstelle: must*****llee 12' ~ address_pattern_regex('musterallee')) then
    raise exception 'masked address not matched';
  end if;
  if 'mustervertrag im abrechnungszeitraum' ~ address_pattern_regex('musterallee') then
    raise exception 'address pattern matches an unrelated word';
  end if;

  -- 8. purchase rights from the delivery mail --------------------------------------------
  insert into emails (gmail_message_id, category, vendor, item, amount, currency, received_at, subject)
  values (tag || '-order', 'purchases', tag || ' Shop', 'Lamp', 120, 'EUR', now() - interval '6 days', 'Order');
  insert into emails (gmail_message_id, category, vendor, received_at, event_date, subject)
  values (tag || '-delivered', 'orders_delivery', tag || ' Shop', now() - interval '2 days', current_date - 3, 'Delivered');
  select start_basis into s from v_purchase_rights where vendor = tag || ' Shop';
  if s is distinct from 'delivery_mail' then raise exception 'withdrawal period not counted from delivery: %', s; end if;

  -- 9. Drive resolvability and the binder ---------------------------------------------------
  update documents set drive_file_id = tag || '-perm-file' where id = perm;
  j := mark_drive_check(array[tag || '-perm-file'], array[tag || '-perm-file']);
  if (j->>'missing')::int <> 1 then raise exception 'mark_drive_check: %', j; end if;
  select count(*) into n from corrections where row_id = perm and field in ('drive_checked_at','drive_missing_since');
  if n > 0 then raise exception 'a Drive check was logged as a correction'; end if;
  s := emergency_dossier();
  if position(dossier_label('file_missing') in s) = 0 then raise exception 'binder does not mark a missing file'; end if;
  j := mark_drive_check(array[tag || '-perm-file'], array[]::text[]);
  select count(*) into n from documents where id = perm and drive_missing_since is null and drive_checked_at is not null;
  if n <> 1 then raise exception 'a resolvable file was not cleared'; end if;

  insert into documents (drive_file_id, name, drive_url, document_type_key, expiry_date, status)
  values (tag || '-pass', tag || ' passport', 'https://example.invalid/r', 'passport', current_date + 999, 'current');
  insert into matters (name, kind, status, next_action, next_action_on)
  values (tag || ' matter', 'other', 'active', 'call', current_date - 10);
  s := emergency_dossier();
  if position(dossier_label('subject_unknown') || ': ' in s) = 0 then raise exception 'binder prints "?" for an unknown person'; end if;
  if position(dossier_label('overdue_since') in s) = 0 then raise exception 'binder does not mark an overdue matter'; end if;

  -- 10. nothing needs removing: cleared staging rows leave the sweep, old chunks are ignored --
  insert into attachment_staging (gmail_message_id, filename, drive_file_id, drive_url, saved_at, resolution, drive_trashed_at)
  values (tag || '-m1', 'a.pdf', tag || '-s1', 'https://example.invalid/s1', now() - interval '40 days', 'out_of_scope', now()),
         (tag || '-m2', 'b.pdf', tag || '-s2', 'https://example.invalid/s2', now() - interval '40 days', 'out_of_scope', null);
  select count(*) into n from v_sweepable_staging where gmail_message_id = tag || '-m1';
  if n <> 0 then raise exception 'a staging row marked as cleared is still offered for sweeping'; end if;
  select count(*) into n from v_sweepable_staging where gmail_message_id = tag || '-m2';
  if n <> 1 then raise exception 'an uncleared staging row is not offered for sweeping'; end if;

  -- an earlier upload left three chunks; the new one has two: chunk 3 must not count
  insert into text_ingest_chunks (document_id, seq, chunk, expected_md5)
  values (doc, 1, 'old1', md5('old1')), (doc, 2, 'old2', md5('old2')), (doc, 3, 'old3', md5('old3'));
  insert into text_ingest_chunks (document_id, seq, chunk, expected_md5)
  values (doc, 1, 'new1', md5('new1')), (doc, 2, 'new2', md5('new2'))
  on conflict (document_id, seq) do update set chunk = excluded.chunk, expected_md5 = excluded.expected_md5;
  perform ingest_assemble(doc, 'local_text', 1, 2, md5('new1new2'));
  select count(*) into n from document_texts where document_id = doc and body = 'new1new2';
  if n <> 1 then raise exception 'ingest_assemble did not ignore a leftover chunk'; end if;

  -- 11. snapshots include settings; drift view answers; health stays within bounds ---------
  perform take_snapshot('feature checks');
  select row_counts, payload ? 'life_settings' into j, ok from backup_snapshots order by taken_at desc limit 1;
  if not (j ? 'life_settings') or not ok then raise exception 'snapshots do not cover life_settings'; end if;
  select count(*) into n from v_schedule_drift;
  if n <> 3 then raise exception 'v_schedule_drift should have 3 jobs, has %', n; end if;
  select count(*) into n from v_system_health where coalesce(text_coverage_pct, 0) > 100;
  if n > 0 then raise exception 'text coverage above 100%%'; end if;

  -- 12. household members (schema 0.8.0) -------------------------------------------------
  if to_regclass('public.household_members') is not null then
    insert into household_members (name, relation, birth_date, aliases)
    values (tag || ' Max', 'child', current_date - 3300, array[tag || ' Maximilian Beispiel'])
    returning id into mem;
    insert into household_members (name, relation) values (tag || ' Anna', 'partner') returning id into mem2;

    -- a name written as an alias, in another case and with spaces, resolves and keeps its spelling
    insert into documents (drive_file_id, name, drive_url, document_type_key, subject_person, expiry_date, status)
    values (tag || '-kidpass', tag || ' kid passport', 'https://example.invalid/k', 'passport',
            ' ' || upper(tag) || ' MAXIMILIAN BEISPIEL ', current_date + 20, 'current')
    returning id into doc;
    select member_id, subject_person into m, s from documents where id = doc;
    if m is distinct from mem then raise exception 'an alias did not resolve to its member'; end if;
    if s <> ' ' || upper(tag) || ' MAXIMILIAN BEISPIEL ' then raise exception 'resolving rewrote the stored name: %', s; end if;

    -- a deadline from that document inherits the member and gets the name; the brief says whose
    insert into deadlines (title, deadline_type, due_on, status, source_kind, source_id)
    values (tag || ' passport renewal', 'document_expiry', current_date + 14, 'open', 'document', doc)
    returning id into dl;
    select member_id, subject_person into m, s from deadlines where id = dl;
    if m is distinct from mem or s is distinct from tag || ' Max' then
      raise exception 'a deadline did not inherit its document''s member: % %', m, s;
    end if;
    if position('(' || tag || ' Max)' in briefing_text()) = 0 then raise exception 'the brief does not say whose deadline it is'; end if;

    -- a contract inherits from its document; the overview adds it up
    insert into recurring_payments (name, category, amount, period, auto_renews, status, document_id, notice_period_months)
    values (tag || ' kid insurance', 'insurance', 12, 'monthly', true, 'active', doc, 1) returning id into rp;
    select count(*) into n from recurring_payments where id = rp and member_id = mem;
    if n <> 1 then raise exception 'a payment did not inherit its document''s member'; end if;
    select count(*) into n from v_household_overview
    where id = mem and identity_documents = 1 and next_identity_expiry = current_date + 20
      and open_deadlines = 1 and next_due_on = current_date + 14 and monthly_costs = 12 and age = 9;
    if n <> 1 then raise exception 'v_household_overview is wrong for the child'; end if;

    -- an explicit member wins and the name follows it; a joint name resolves to nobody
    update documents set member_id = mem2 where id = doc;
    select subject_person into s from documents where id = doc;
    if s <> tag || ' Anna' then raise exception 'the name did not follow an explicit member: %', s; end if;
    update documents set subject_person = tag || ' Max, ' || tag || ' Anna' where id = doc;
    select count(*) into n from documents where id = doc and member_id is null;
    if n <> 1 then raise exception 'a joint name was guessed onto one member'; end if;
    update documents set subject_person = tag || ' Max' where id = doc;

    -- a name shared by two members is never guessed
    update household_members set aliases = array[tag || ' Beispiel'] where id = mem2;
    update household_members set aliases = aliases || (tag || ' Beispiel') where id = mem;
    if household_member_for(tag || ' Beispiel') is not null then raise exception 'an ambiguous alias was resolved'; end if;

    -- a name nobody owns is listed, and links once it becomes an alias
    insert into documents (drive_file_id, name, drive_url, document_type_key, subject_person, status)
    values (tag || '-cert', tag || ' certificate', 'https://example.invalid/c', 'civil_status_certificate',
            tag || ' Sophie', 'current') returning id into perm;
    insert into deadlines (title, deadline_type, due_on, status, source_kind, source_id)
    values (tag || ' certificate copy', 'other', current_date + 40, 'open', 'document', perm);
    select count(*) into n from v_unassigned_people where person = tag || ' Sophie' and documents = 1;
    if n <> 1 then raise exception 'an unknown name is not listed in v_unassigned_people'; end if;
    update household_members set aliases = aliases || (tag || ' Sophie') where id = mem;
    select count(*) into n from v_unassigned_people where person = tag || ' Sophie';
    if n <> 0 then raise exception 'a name that now matches a member is still reported as unassigned'; end if;
    select count(*) into n from link_household_members(false) where row_id = perm or label = tag || ' certificate copy';
    if n <> 2 then raise exception 'link dry run lists % rows, expected the document and its deadline', n; end if;
    select count(*) into n from documents where id = perm and member_id is null;
    if n <> 1 then raise exception 'the link dry run changed a row'; end if;
    perform link_household_members(true);
    select count(*) into n from deadlines where source_id = perm and member_id = mem;
    if n <> 1 then raise exception 'link_household_members did not link the deadline of a linked document'; end if;
    select count(*) into n from v_unassigned_people where person = tag || ' Sophie';
    if n <> 0 then raise exception 'a linked name is still unassigned'; end if;

    -- the same member holds the successor, whatever the spelling
    insert into documents (drive_file_id, name, drive_url, document_type_key, subject_person, expiry_date, status)
    values (tag || '-oldpass', tag || ' old passport', 'https://example.invalid/o', 'passport',
            tag || ' Maximilian Beispiel', current_date - 5, 'expired') returning id into perm;
    select count(*) into n from v_expired_without_successor where id = perm;
    if n <> 0 then raise exception 'a successor under another spelling of the same member was not seen'; end if;

    -- the owner's own items carry no name; the binder lists the household
    select id into m from household_members where relation = 'self';
    if m is null then
      insert into household_members (name, relation) values (tag || ' Owner', 'self') returning id into m;
    end if;
    if household_person_label(m, 'anyone') is not null then raise exception 'the owner is named in their own brief'; end if;
    s := emergency_dossier();
    if position('## ' || dossier_label('household') in s) = 0
       or position(tag || ' Max (' || dossier_label('rel_child') || '), ' || dossier_label('born') in s) = 0 then
      raise exception 'the binder does not list the household';
    end if;

    perform take_snapshot('feature checks household');
    select payload ? 'household_members' into ok from backup_snapshots order by taken_at desc limit 1;
    if not ok then raise exception 'snapshots do not cover household_members'; end if;
  end if;

  -- 13. search by meaning, in any language (schema 0.10.0) ---------------------------------
  if to_regprocedure('public.find_documents(text[],integer)') is not null then
    -- invented words, so a live installation's own documents cannot interfere
    insert into documents (drive_file_id, name, drive_url, document_type_key, issuer, status, last_intake_at)
    values (tag || '-lease', 'Mietvertrag Quokkastraße', 'https://example.invalid/l1', 'rental_contract', tag || ' Hausverwaltung', 'current', clock_timestamp())
    returning id into doc;
    insert into document_texts (document_id, body, extraction_status)
    values (doc, 'Die Quokkahaltung in der Wohnung ist nur mit schriftlicher Zustimmung des Vermieters gestattet. '
              || 'Die Kündigungsfrist für den Mieter beträgt drei Monate. Nebenkostenvorauszahlung Quokkastraße.', 'done');
    insert into documents (drive_file_id, name, drive_url, document_type_key, issuer, status, last_intake_at)
    values (tag || '-lease2', 'Nachtrag Mietvertrag', 'https://example.invalid/l2', 'rental_contract', tag || ' Hausverwaltung', 'current', clock_timestamp())
    returning id into perm;
    insert into document_texts (document_id, body, extraction_status)
    values (perm, 'Nachtrag zur Nebenkostenvorauszahlung für die Wohnung Quokkastraße. Quokkahaltung bleibt zustimmungspflichtig.', 'done');
    insert into documents (drive_file_id, name, drive_url, document_type_key, status, last_intake_at)
    values (tag || '-ua', 'Договір оренди', 'https://example.invalid/u1', 'rental_contract', 'current', clock_timestamp())
    returning id into dl;
    insert into document_texts (document_id, body, extraction_status)
    values (dl, 'Умови договору оренди квоккаквартири: орендар сплачує щомісяця.', 'done');

    -- another language and a synonym find what the words of the question would miss
    select matched_terms::text into s from find_documents(array['pets allowed', 'Quokkahaltung', 'домашні квокки'], 10) f
    where f.id = doc;
    if s is distinct from '{Quokkahaltung}' then raise exception 'find_documents: matched terms %', s; end if;
    select count(*) into n from find_documents(array['Quokkahaltung'], 10) f
    where f.id = doc and f.snippet like '%<b>Quokkahaltung</b>%' and f.url = 'https://example.invalid/l1';
    if n <> 1 then raise exception 'find_documents gives no quotable snippet with the link'; end if;
    -- a word finds its longer forms, a starred stem its inflections
    select count(*) into n from find_documents(array['Kündigung Quokkastraße'], 10) where id = doc;
    if n <> 1 then raise exception 'a word does not find its compound (Kündigung -> Kündigungsfrist)'; end if;
    select count(*) into n from find_documents(array['квоккаквартир*'], 10) where id = dl;
    if n <> 1 then raise exception 'a starred stem does not find its inflected form'; end if;
    -- more terms matched ranks higher
    select id into m from find_documents(array['Quokkahaltung', 'Kündigungsfrist', 'Nebenkostenvorauszahlung'], 10)
    where id in (doc, perm) order by score desc limit 1;
    if m is distinct from doc then raise exception 'the document matching more terms does not rank first'; end if;
    select count(*) into n from find_documents(array['', '*', '?'], 10);
    if n <> 0 then raise exception 'empty terms return rows'; end if;

    -- documents like this one: the addendum from the same landlord, not the unrelated one
    select id, reasons::text into m, s from similar_documents(doc, 20) order by score desc limit 1;
    if m is distinct from perm then raise exception 'similar_documents: % ranked first', m; end if;
    if s not like '%same issuer%' or s not like '%shared terms%' then raise exception 'similar_documents reasons: %', s; end if;
    select count(*) into n from similar_documents(doc, 50) where id = doc;
    if n <> 0 then raise exception 'a document is listed as similar to itself'; end if;
  end if;

  -- 14. the system closes the tasks it opened (schema 0.11.0) ------------------------------
  if to_regclass('public.v_tasks_to_close') is not null then
    insert into system_tasks (kind, ref, todoist_task_id, title, created_at) values
      ('brief', (current_date - 1)::text, tag || '-brief-old', 'Daily brief old', now() - interval '1 day'),
      ('brief', current_date::text, tag || '-brief-today', 'Daily brief today', now()),
      ('review', '2026-08', tag || '-review-old', 'Review 2026-08', now() - interval '40 days'),
      ('review', '2026-09', tag || '-review-new', 'Review 2026-09', now() - interval '10 days'),
      ('failure', 'email-intake', tag || '-fail-mail', 'email-intake failed', now() - interval '2 hours'),
      ('failure', 'some-other-job', tag || '-fail-other', 'other failed', now() - interval '2 hours');
    select string_agg(todoist_task_id, ',' order by todoist_task_id) into s
    from v_tasks_to_close where todoist_task_id like tag || '-%';
    if s is distinct from tag || '-brief-old,' || tag || '-review-old' then
      raise exception 'v_tasks_to_close before the job recovered: %', s;
    end if;
    -- a failing run keeps the failure task open, a clean one closes it
    insert into email_processing_runs (run_at, errors) values (now() - interval '1 hour', '[{"stage":"x","error":"y"}]');
    select count(*) into n from v_tasks_to_close where todoist_task_id = tag || '-fail-mail';
    if n <> 0 then raise exception 'a failure task closes although the job failed again'; end if;
    insert into email_processing_runs (run_at, errors) values (now(), '[]');
    select count(*) into n from v_tasks_to_close where todoist_task_id = tag || '-fail-mail';
    if n <> 1 then raise exception 'a failure task stays open after a clean run'; end if;
    select count(*) into n from v_tasks_to_close where todoist_task_id = tag || '-fail-other';
    if n <> 0 then raise exception 'a failure of an unknown job is closed on a guess'; end if;

    -- tasks of rows: a done deadline and a decided proposal close, an open or pending one does not
    insert into deadlines (title, deadline_type, due_on, status, todoist_task_id)
    values (tag || ' done', 'other', current_date + 401, 'done', tag || '-dl-done'),
           (tag || ' open', 'other', current_date + 402, 'open', tag || '-dl-open'),
           (tag || ' claimed', 'other', current_date + 403, 'done', 'pending:' || tag);
    insert into improvement_proposals (title, problem, proposed_change, autonomy, status, todoist_task_id, decided_at)
    values (tag || ' proposal', 'p', 'c', 'ask', 'applied', tag || '-prop', now());
    select string_agg(source || ':' || todoist_task_id, ',' order by todoist_task_id) into s
    from v_tasks_to_close where todoist_task_id like tag || '-%' or todoist_task_id = 'pending:' || tag;
    if s not like '%deadline:' || tag || '-dl-done%' or s not like '%proposal:' || tag || '-prop%'
       or s like '%dl-open%' or s like '%pending:%' then
      raise exception 'v_tasks_to_close for rows: %', s;
    end if;

    -- recording the close takes the task off the list, wherever it is referenced
    if mark_task_closed(tag || '-dl-done', 'test') <> 1 then raise exception 'mark_task_closed did not mark the deadline'; end if;
    if mark_task_closed(tag || '-brief-old', 'test') <> 1 then raise exception 'mark_task_closed did not mark the brief'; end if;
    if mark_task_closed(tag || '-brief-old', 'again') <> 0 then raise exception 'mark_task_closed is not idempotent'; end if;
    if mark_task_closed('pending:' || tag, 'test') <> 0 then raise exception 'mark_task_closed touched a claimed row'; end if;
    select count(*) into n from v_tasks_to_close where todoist_task_id in (tag || '-dl-done', tag || '-brief-old');
    if n <> 0 then raise exception 'closed tasks are still listed'; end if;
    select close_reason into s from system_tasks where todoist_task_id = tag || '-brief-old';
    if s is distinct from 'test' then raise exception 'the first close reason was overwritten: %', s; end if;
  end if;

  raise notice 'feature checks: all passed';
end
$checks$;

rollback;
