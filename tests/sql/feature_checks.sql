-- Feature checks for schema 0.6.x: each new database behaviour, exercised end to end on
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
  n bigint; s text; doc uuid; perm uuid; dl uuid; rp uuid; ok boolean; j jsonb;
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

  raise notice 'feature checks: all passed';
end
$checks$;

rollback;
