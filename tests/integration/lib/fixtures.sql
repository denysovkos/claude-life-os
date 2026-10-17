-- A small, realistic installation for integration tests: one of everything the
-- workflows read and write. Fixed ids (…-0000000000xx) so tests can refer to rows.
-- Apply after stack/install.sh. Idempotent.
select set_config('app.actor', 'test', true);

insert into entities (id, kind, name, role) values
  ('00000000-0000-0000-0000-0000000000e1', 'organization', 'Stadtwerke Test', 'utility'),
  ('00000000-0000-0000-0000-0000000000e2', 'organization', 'Mobilfunk Test', 'telecom')
on conflict (id) do nothing;
insert into entity_aliases (alias, entity_id) values
  ('stadtwerke-test.de', '00000000-0000-0000-0000-0000000000e1')
on conflict (alias) do nothing;

insert into documents (id, drive_file_id, name, drive_url, document_type_key, subject_person,
                       issued_on, expiry_date, status, content_excerpt, last_intake_at, drive_parent_id)
values
  ('00000000-0000-0000-0000-0000000000a1', 'fx-passport', 'Passport_Test_Owner.pdf', 'https://drive.test/fx-passport',
   'passport', 'Test Owner', current_date - 3000, current_date + 20, 'current',
   'Reisepass. Gültig bis …', clock_timestamp(), 'fld-identity'),
  ('00000000-0000-0000-0000-0000000000a2', 'fx-telecom', 'Auftragsbestaetigung_Mobilfunk.pdf', 'https://drive.test/fx-telecom',
   'telecom_contract', 'Test Owner', current_date - 200, null, 'current',
   'Mindestvertragslaufzeit 24 Monate. Lieferstelle: Must*****llee 12', clock_timestamp(), 'fld-housing'),
  ('00000000-0000-0000-0000-0000000000a3', 'fx-decision', 'Bescheid_Finanzamt.pdf', 'https://drive.test/fx-decision',
   'tax_assessment', 'Test Owner', current_date - 5, null, 'current',
   'Einkommensteuerbescheid 2025', clock_timestamp(), 'fld-taxes')
on conflict (id) do nothing;

insert into document_texts (document_id, body, extraction_status, extraction_method)
values ('00000000-0000-0000-0000-0000000000a2',
        repeat('Allgemeine Geschaeftsbedingungen. ', 10) || 'Kuendigungsfrist ein Monat zum Ende der Mindestvertragslaufzeit.',
        'done', 'drive_text')
on conflict (document_id) do nothing;

insert into emails (id, gmail_message_id, gmail_thread_id, gmail_url, subject, sender_name, sender_email,
                    received_at, category, summary, vendor, amount, currency, due_date, action_needed,
                    action_note, has_attachments, attachment_names, content_excerpt, last_intake_at)
values
  ('00000000-0000-0000-0000-0000000000b1', 'fx-msg-bill', 'fx-thr-bill', 'https://mail.test/fx-msg-bill',
   'Ihre Rechnung Oktober', 'Stadtwerke Test', 'rechnung@stadtwerke-test.de', now() - interval '2 days',
   'bills_payments', 'Electricity bill October', 'Stadtwerke Test', 84.20, 'EUR', current_date + 12, true,
   'Pay electricity bill', true, array['Rechnung_Oktober.pdf'], 'Rechnung Oktober, 84,20 EUR', clock_timestamp())
on conflict (id) do nothing;

insert into deadlines (id, title, deadline_type, due_on, hard, source_kind, source_id, status, notes, date_basis)
values
  ('00000000-0000-0000-0000-0000000000d1', 'Pay electricity bill', 'payment_due', current_date + 12, false,
   'email', '00000000-0000-0000-0000-0000000000b1', 'open', 'basis: stated "zahlbar bis"', 'stated'),
  ('00000000-0000-0000-0000-0000000000d2', 'Passport expires', 'document_expiry', current_date + 20, true,
   'document', '00000000-0000-0000-0000-0000000000a1', 'open', null, 'stated')
on conflict (id) do nothing;

insert into recurring_payments (id, name, category, amount, period, contract_start, auto_renews, status,
                                document_id, vendor_entity_id)
values ('00000000-0000-0000-0000-0000000000c1', 'Mobile contract', 'telecom', 19.99, 'monthly',
        current_date - 200, true, 'active', '00000000-0000-0000-0000-0000000000a2',
        '00000000-0000-0000-0000-0000000000e2')
on conflict (id) do nothing;

insert into attachment_staging (id, gmail_message_id, filename, drive_file_id, drive_url, saved_at)
values ('00000000-0000-0000-0000-0000000000f1', 'fx-msg-bill', 'Rechnung_Oktober.pdf', 'fx-staged-1',
        'https://drive.test/fx-staged-1', now() - interval '1 day')
on conflict (id) do nothing;

insert into drive_folder_areas (drive_folder_id, folder_path, area_name, para_category)
select v.* from (values ('fld-identity', 'Life OS/Identity', 'Identity', 'area'),
                        ('fld-housing', 'Life OS/Housing', 'Housing', 'area'),
                        ('fld-taxes', 'Life OS/Finance/Taxes', 'Taxes', 'area')) v(a, b, c, d)
where not exists (select 1 from drive_folder_areas f where f.drive_folder_id = v.a);

insert into bundles (id, name) values ('00000000-0000-0000-0000-000000000011', 'Tax return 2025')
on conflict (id) do nothing;
insert into notes (id, title, body) values ('00000000-0000-0000-0000-000000000021', 'Test note', 'Body')
on conflict (id) do nothing;
insert into matters (id, name, kind) values ('00000000-0000-0000-0000-000000000031', 'Residence permit renewal', 'immigration')
on conflict (id) do nothing;
insert into run_locks (skill_name, expires_at, holder) values ('email-intake', now() - interval '1 hour', 'old-run')
on conflict (skill_name) do nothing;
insert into outbox (id, kind, subject, body, source)
values ('00000000-0000-0000-0000-000000000041', 'notice', 'Fixture notice', 'Body', 'fixtures')
on conflict (id) do nothing;

-- one uploaded chunk, as drive-file-intake step 5 leaves it before ingest_assemble()
insert into text_ingest_chunks (document_id, seq, chunk, expected_md5)
values ('00000000-0000-0000-0000-0000000000a2', 1, '...', md5('...'))
on conflict (document_id, seq) do update set chunk = excluded.chunk, expected_md5 = excluded.expected_md5;
