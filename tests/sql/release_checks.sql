-- Release checks for schema 0.6.x. Run against an installed database:
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f tests/sql/release_checks.sql
--
-- or paste it into the Supabase SQL editor. Everything runs in one transaction that is
-- rolled back, so it leaves nothing behind. Any failed check raises an exception naming
-- it; a clean run ends with the notice "release checks: all passed".
--
-- What it asserts:
--   1. the intake's end-of-run views are empty (v_untyped_documents,
--      v_missing_notice_period, v_stale_status, v_missing_expiry)
--   2. apply_term_rule() counts every German rule the way the pack examples and the
--      carriers' own letters do (skipped when the installed region is not de), and
--      contract_cancel_by() reproduces stated cancellation dates
--   3. ingest_assemble() refuses a chunk with a bad md5, a missing chunk and a bad body md5,
--      and accepts a correct set
--   4. skill_writebacks refuses a write-back to a row that does not exist and applies one
--      that does, as the skill (no human correction logged)
--   5. rederive_deadlines() would not move any open deadline later, or into the past

begin;

do $checks$
declare
  n bigint; d date; doc uuid; ok boolean; corr_before bigint; corr_after bigint;
  is_de boolean := coalesce(setting_text('region'), '') = 'de';
  c1 text := 'Erste Seite. ';
  c2 text := 'Zweite Seite mit Umlauten: äöüß.';
begin
  -- 1. end-of-run views ------------------------------------------------------------------
  select count(*) into n from v_untyped_documents;     if n > 0 then raise exception 'v_untyped_documents has % rows', n; end if;
  select count(*) into n from v_missing_notice_period; if n > 0 then raise exception 'v_missing_notice_period has % rows', n; end if;
  select count(*) into n from v_stale_status;          if n > 0 then raise exception 'v_stale_status has % rows', n; end if;
  select count(*) into n from v_missing_expiry;        if n > 0 then raise exception 'v_missing_expiry has % rows', n; end if;

  -- 2. term rules --------------------------------------------------------------------------
  if is_de then
    -- pack examples (posted letters: the notification offset applies)
    if apply_term_rule(region_rule('objection_administrative'), date '2026-01-15') <> date '2026-02-19' then raise exception 'objection_administrative 2026-01-15'; end if;
    if apply_term_rule(region_rule('objection_administrative'), date '2026-02-24') <> date '2026-03-30' then raise exception 'objection_administrative weekend roll'; end if;
    if apply_term_rule(region_rule('objection_tax'), date '2026-06-01') <> date '2026-07-06' then raise exception 'objection_tax weekend roll'; end if;
    if apply_term_rule(region_rule('telecom_min_term_end'), date '2026-03-15') <> date '2028-03-14' then raise exception 'telecom_min_term_end'; end if;
    if apply_term_rule(region_rule('telecom_min_term_end'), date '2024-02-29') <> date '2026-02-28' then raise exception 'telecom_min_term_end 29 Feb'; end if;
    if apply_term_rule(region_rule('telecom_min_term_end'), date '2026-03-01') <> date '2028-02-29' then raise exception 'telecom_min_term_end leap year'; end if;
    if apply_term_rule(region_rule('telecom_cancel_by'), date '2026-03-15') <> date '2028-02-14' then raise exception 'telecom_cancel_by'; end if;
    if apply_term_rule(region_rule('insurance_cancel_by'), date '2026-12-31') <> date '2026-09-30' then raise exception 'insurance_cancel_by'; end if;
    if apply_term_rule(region_rule('rent_tenant_exit'), date '2026-04-03') <> date '2026-06-30' then raise exception 'rent_tenant_exit'; end if;
    if apply_term_rule(region_rule('consumer_withdrawal'), date '2026-05-02') <> date '2026-05-18' then raise exception 'consumer_withdrawal'; end if;
    if apply_term_rule(region_rule('statutory_warranty'), date '2026-05-02') <> date '2028-05-02' then raise exception 'statutory_warranty'; end if;
    if apply_term_rule(region_rule('residence_permit_apply_by'), date '2027-08-31') <> date '2027-08-31' then raise exception 'residence_permit_apply_by'; end if;

    -- the Telekom letters (proposal f87fdafa): the carrier states end = start + 24 months - 1 day
    -- and "Eingang der Kündigung spätestens" one month before that
    if apply_term_rule(region_rule('telecom_min_term_end'), date '2026-08-24', true) <> date '2028-08-23' then raise exception 'Telekom min term 24.08.2026'; end if;
    if apply_term_rule(region_rule('telecom_cancel_by'), date '2026-08-24', true) <> date '2028-07-23' then raise exception 'Telekom cancel-by 24.08.2026'; end if;
    if apply_term_rule(region_rule('telecom_cancel_by'), date '2026-09-08', true) <> date '2028-08-07' then raise exception 'Telekom cancel-by 08.09.2026'; end if;
    if apply_term_rule(region_rule('telecom_cancel_by'), date '2026-09-17', true) <> date '2028-08-16' then raise exception 'Telekom cancel-by 17.09.2026'; end if;
  else
    raise notice 'region is not de: German rule cases skipped';
  end if;

  -- contract terms stated by the documents (Vattenfall, proposal 623a37da)
  if contract_cancel_by(date '2026-08-22', 12, 1) <> date '2027-07-21' then raise exception 'contract_cancel_by gas 12/1'; end if;
  if contract_cancel_by(date '2026-08-11', 24, 1) <> date '2028-07-10' then raise exception 'contract_cancel_by power 24/1'; end if;
  if contract_term_end(date '2026-08-24', 24) <> date '2028-08-23' then raise exception 'contract_term_end'; end if;
  if contract_cancel_by(date '2026-08-24', 24, 1) <> date '2028-07-23' then raise exception 'contract_cancel_by Telekom'; end if;
  -- working days (0009)
  if apply_term_rule('{"steps":[{"add_business_days":10}]}'::jsonb, date '2026-10-14', true) <> date '2026-10-28' then raise exception 'add_business_days'; end if;

  -- 3. ingest_assemble ---------------------------------------------------------------------
  insert into documents (drive_file_id, name, drive_url, kind)
  values ('release-check-' || gen_random_uuid(), 'release check', 'https://example.invalid/release-check', 'reference_file')
  returning id into doc;

  insert into text_ingest_chunks (document_id, seq, chunk, expected_md5)
  values (doc, 1, c1, md5(c1)), (doc, 2, c2, md5('not the chunk'));
  ok := false;
  begin
    perform ingest_assemble(doc, 'local_text', 1, 2, md5(c1 || c2));
  exception when others then ok := sqlerrm like '%fail md5%';
  end;
  if not ok then raise exception 'ingest_assemble accepted a chunk with a bad md5'; end if;

  update text_ingest_chunks set expected_md5 = md5(c2) where document_id = doc and seq = 2;
  ok := false;
  begin
    perform ingest_assemble(doc, 'local_text', 1, 3, md5(c1 || c2));
  exception when others then ok := sqlerrm like '%expected 3 chunks%';
  end;
  if not ok then raise exception 'ingest_assemble accepted a missing chunk'; end if;

  ok := false;
  begin
    perform ingest_assemble(doc, 'local_text', 1, 2, md5('something else'));
  exception when others then ok := sqlerrm like '%body md5 mismatch%';
  end;
  if not ok then raise exception 'ingest_assemble accepted a bad body md5'; end if;

  perform ingest_assemble(doc, 'local_text', 1, 2, md5(c1 || c2));
  select count(*) into n from document_texts where document_id = doc and body = c1 || c2 and extraction_status = 'done';
  if n <> 1 then raise exception 'ingest_assemble did not store the verified body'; end if;

  -- 4. write-backs --------------------------------------------------------------------------
  ok := false;
  begin
    insert into skill_writebacks (target_table, target_id, column_name, value)
    values ('documents', gen_random_uuid(), 'description', to_jsonb('x'::text));
  exception when others then ok := sqlerrm like '%no documents row%';
  end;
  if not ok then raise exception 'skill_writebacks accepted a write-back to a missing row'; end if;

  ok := false;
  begin
    insert into skill_writebacks (target_table, target_id, column_name, value)
    values ('documents', doc, 'name', to_jsonb('x'::text));
  exception when others then ok := sqlerrm like '%not a write-back column%';
  end;
  if not ok then raise exception 'skill_writebacks accepted a column outside the whitelist'; end if;

  select count(*) into corr_before from corrections where row_id = doc;
  insert into skill_writebacks (target_table, target_id, column_name, value)
  values ('documents', doc, 'description', to_jsonb(repeat('A long description that would stall an UPDATE. ', 20)));
  select count(*) into n from documents where id = doc and description like 'A long description%';
  if n <> 1 then raise exception 'skill_writebacks did not apply the description'; end if;
  select count(*) into corr_after from corrections where row_id = doc and source = 'human';
  if corr_after > 0 then raise exception 'a skill write-back was logged as a human correction'; end if;

  -- 5. recount safety ------------------------------------------------------------------------
  select count(*) into n from rederive_deadlines(false)
  where action = 'moved_later' or (action in ('moved','moved_later') and new_due < current_date);
  if n > 0 then raise exception 'rederive_deadlines would move % open deadline(s) later or into the past', n; end if;

  raise notice 'release checks: all passed';
end
$checks$;

rollback;
