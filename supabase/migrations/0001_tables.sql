-- Tables, constraints, indexes and comments.
-- Generated from the reference deployment. Do not edit by hand; add a new migration instead.

create extension if not exists pg_trgm with schema public;
create extension if not exists pg_cron;

create table if not exists public.attachment_staging (
  id uuid default gen_random_uuid() not null,
  gmail_message_id text not null,
  filename text not null,
  drive_file_id text not null,
  drive_url text not null,
  mime_type text,
  size_bytes integer,
  saved_at timestamp with time zone default now() not null,
  claimed boolean default false not null,
  claimed_at timestamp with time zone,
  resolved_at timestamp with time zone,
  resolution text,
  heal_count integer default 0 not null,
  last_verified_at timestamp with time zone,
  constraint attachment_staging_resolution_check CHECK ((resolution = ANY (ARRAY['drive_file_missing'::text, 'out_of_scope'::text, 'superseded'::text]))),
  constraint attachment_staging_pkey PRIMARY KEY (id),
  constraint attachment_staging_gmail_message_id_filename_key UNIQUE (gmail_message_id, filename)
);
comment on table public.attachment_staging is 'Populated by the external Google Apps Script attachment-bridge (Gmail -> Drive), not by any Claude skill. email-intake reads it to link documents.source_email_id without ever handling the binary itself.';

create table if not exists public.backup_snapshots (
  id uuid default gen_random_uuid() not null,
  taken_at timestamp with time zone default now() not null,
  reason text,
  row_counts jsonb not null,
  payload jsonb not null,
  constraint backup_snapshots_pkey PRIMARY KEY (id)
);
comment on table public.backup_snapshots is 'Full server-side JSON snapshot of the extraction tables. Written by take_snapshot() in a single statement, so nothing is round-tripped through the assistant. Guards against bad migrations and bad autonomous edits, not against loss of the project itself, which is what the Drive export covers.';

create table if not exists public.backups (
  id uuid default gen_random_uuid() not null,
  run_at timestamp with time zone default now() not null,
  drive_file_id text,
  drive_url text,
  row_counts jsonb default '{}'::jsonb not null,
  bytes bigint,
  notes text,
  constraint backups_pkey PRIMARY KEY (id)
);
comment on table public.backups is 'Log of weekly JSON exports to Drive. Supabase is the single source of truth and is about to be edited by an autonomous process, so an export older than 10 days is itself a defect.';

create table if not exists public.bank_statement_imports (
  id uuid default gen_random_uuid() not null,
  document_id uuid,
  source_note text,
  account_iban text,
  period_start date,
  period_end date,
  rows_parsed integer,
  rows_inserted integer,
  imported_at timestamp with time zone default clock_timestamp() not null,
  constraint bank_statement_imports_pkey PRIMARY KEY (id)
);

create table if not exists public.bank_transactions (
  id uuid default gen_random_uuid() not null,
  booked_on date not null,
  value_date date,
  amount numeric(12,2) not null,
  currency text default 'EUR'::text not null,
  direction text not null,
  counterparty text,
  counterparty_entity_id uuid,
  reference text,
  method text,
  account_iban text,
  recurring_payment_id uuid,
  email_id uuid,
  source text default 'manual'::text not null,
  raw jsonb,
  created_at timestamp with time zone default now() not null,
  constraint bank_transactions_direction_check CHECK ((direction = ANY (ARRAY['debit'::text, 'credit'::text]))),
  constraint bank_transactions_source_check CHECK ((source = ANY (ARRAY['manual'::text, 'statement_import'::text, 'email'::text]))),
  constraint bank_transactions_pkey PRIMARY KEY (id)
);
comment on table public.bank_transactions is 'Actual money movement. Without it the system knows what was invoiced but not what was paid, so it cannot tell a working direct debit from a cancelled contract that is still billing.';

create table if not exists public.bridge_messages (
  gmail_message_id text not null,
  processed_at timestamp with time zone default clock_timestamp() not null,
  copied integer default 0 not null,
  skipped jsonb default '[]'::jsonb not null,
  constraint bridge_messages_pkey PRIMARY KEY (gmail_message_id)
);

create table if not exists public.bridge_runs (
  id uuid default gen_random_uuid() not null,
  started_at timestamp with time zone default clock_timestamp() not null,
  finished_at timestamp with time zone,
  queued integer default 0 not null,
  copied integer default 0 not null,
  healed integer default 0 not null,
  verified integer default 0 not null,
  texts_extracted integer default 0 not null,
  errors jsonb default '[]'::jsonb not null,
  script_version text,
  constraint bridge_runs_pkey PRIMARY KEY (id)
);

create table if not exists public.briefings (
  id uuid default gen_random_uuid() not null,
  briefing_date date default CURRENT_DATE not null,
  generated_at timestamp with time zone default now() not null,
  channel text default 'todoist'::text not null,
  should_send boolean default false not null,
  sent boolean default false not null,
  gmail_message_id text,
  item_count integer default 0 not null,
  payload jsonb not null,
  todoist_task_id text,
  suppressed boolean default false not null,
  constraint briefings_channel_check CHECK ((channel = ANY (ARRAY['email'::text, 'todoist'::text, 'none'::text]))),
  constraint briefings_pkey PRIMARY KEY (id)
);
comment on table public.briefings is 'One row per day. Channel is todoist: the brief is a single task in Система with the body in the description, due today. Email delivery was retired on 2026-08-31 at the person''s request, and briefings_date_uidx keeps it at one brief per day.';
comment on column public.briefings.should_send is 'Set from brief_item_count() > 0. Kept separate from sent so a delivery failure is distinguishable from a deliberate suppression.';
comment on column public.briefings.gmail_message_id is 'Legacy. Email delivery is retired; kept only so the one message that was sent stays traceable.';

create table if not exists public.bundle_requirements (
  id uuid default gen_random_uuid() not null,
  bundle_id uuid not null,
  document_type_key text,
  label text not null,
  subject_person text,
  required boolean default true not null,
  must_be_current boolean default true not null,
  max_age_days integer,
  document_id uuid,
  satisfied_manually boolean default false not null,
  notes text,
  constraint bundle_requirements_pkey PRIMARY KEY (id)
);
comment on column public.bundle_requirements.max_age_days is 'Some authorities reject anything older than N months regardless of validity: Grundbuchauszug, Arbeitgeberbescheinigung, Meldebescheinigung. A document can be current and still too old.';

create table if not exists public.bundles (
  id uuid default gen_random_uuid() not null,
  name text not null,
  purpose text,
  subject_person text,
  due_on date,
  status text default 'open'::text not null,
  submitted_on date,
  notes text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint bundles_status_check CHECK ((status = ANY (ARRAY['open'::text, 'submitted'::text, 'done'::text, 'cancelled'::text]))),
  constraint bundles_pkey PRIMARY KEY (id)
);
comment on table public.bundles is 'A named set of documents required for one event: LEA submission, tax filing, bank application. Requirements point at the type registry rather than at files, so a bundle survives a document being renewed.';

create table if not exists public.classification_rules (
  id uuid default gen_random_uuid() not null,
  scope text not null,
  priority integer default 100 not null,
  match_field text not null,
  match_op text default 'contains'::text not null,
  match_value text not null,
  set_category text,
  set_document_type_key text,
  set_entity_id uuid,
  set_tags text[],
  set_action_needed boolean,
  set_matter_id uuid,
  active boolean default true not null,
  hits integer default 0 not null,
  last_hit_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone default now() not null,
  constraint classification_rules_match_field_check CHECK ((match_field = ANY (ARRAY['sender_email'::text, 'sender_domain'::text, 'sender_name'::text, 'subject'::text, 'file_name'::text, 'issuer'::text, 'body'::text]))),
  constraint classification_rules_match_op_check CHECK ((match_op = ANY (ARRAY['equals'::text, 'contains'::text, 'domain'::text, 'prefix'::text]))),
  constraint classification_rules_scope_check CHECK ((scope = ANY (ARRAY['email'::text, 'document'::text]))),
  constraint classification_rules_pkey PRIMARY KEY (id)
);
comment on table public.classification_rules is 'Deterministic rules applied before model classification, the way Paperless and Firefly do it. Lower priority number wins. Rules cover the boring majority so judgement is spent only on what is genuinely new, and classification stops drifting between runs.';

create table if not exists public.corrections (
  id uuid default gen_random_uuid() not null,
  table_name text not null,
  row_id uuid not null,
  field text not null,
  old_value text,
  new_value text,
  corrected_at timestamp with time zone default now() not null,
  source text default 'human'::text not null,
  reviewed boolean default false not null,
  constraint corrections_pkey PRIMARY KEY (id)
);
comment on table public.corrections is 'Every field a human changed after the skill wrote it. This is the closest thing to labelled training data the system has: each row means the skill got that field wrong.';

create table if not exists public.deadlines (
  id uuid default gen_random_uuid() not null,
  title text not null,
  deadline_type text not null,
  due_on date not null,
  hard boolean default false not null,
  lead_days integer[] default '{30,14,7,1}'::integer[] not null,
  subject_person text,
  source_kind text,
  source_id uuid,
  status text default 'open'::text not null,
  todoist_task_id text,
  notes text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  last_intake_at timestamp with time zone,
  snoozed_until date,
  entity_id uuid,
  constraint deadlines_deadline_type_check CHECK ((deadline_type = ANY (ARRAY['document_expiry'::text, 'payment_due'::text, 'legal_response'::text, 'notice_period'::text, 'appointment'::text, 'contract_milestone'::text, 'other'::text]))),
  constraint deadlines_source_kind_check CHECK ((source_kind = ANY (ARRAY['document'::text, 'email'::text, 'manual'::text]))),
  constraint deadlines_status_check CHECK ((status = ANY (ARRAY['open'::text, 'done'::text, 'cancelled'::text, 'missed'::text]))),
  constraint deadlines_pkey PRIMARY KEY (id)
);
comment on table public.deadlines is 'Every dated obligation in one place, independent of where it came from. hard = missing it is legally irreversible (Widerspruchsfrist under VwGO 70, Kuendigungsfrist, court dates) and gets escalating reminders rather than one task.';
comment on column public.deadlines.lead_days is 'Days before due_on at which a reminder should exist. Hard deadlines use the full ladder, soft ones typically just {7}.';
comment on column public.deadlines.snoozed_until is 'Suppresses this deadline in the daily brief until the given date. Never changes status: the item stays open and stays in v_deadlines_missed, it is only quiet in the digest.';

create table if not exists public.derivation_runs (
  id uuid default gen_random_uuid() not null,
  ran_at timestamp with time zone default clock_timestamp() not null,
  passive_closed integer,
  tx_linked integer,
  deadlines_derived integer,
  error text,
  constraint derivation_runs_pkey PRIMARY KEY (id)
);

create table if not exists public.document_texts (
  document_id uuid not null,
  search_title text,
  body text,
  page_count integer,
  language text,
  extraction_method text,
  extraction_status text default 'pending'::text not null,
  extraction_error text,
  extracted_at timestamp with time zone,
  source_modified_at timestamp with time zone,
  char_count integer generated always as (COALESCE(length(body), 0)) stored,
  tsv tsvector generated always as ((setweight(to_tsvector('simple'::regconfig, COALESCE(search_title, ''::text)), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE(body, ''::text)), 'B'::"char"))) stored,
  constraint document_texts_extraction_method_check CHECK ((extraction_method = ANY (ARRAY['drive_text'::text, 'drive_ocr'::text, 'manual'::text, 'none'::text, 'apps_script'::text]))),
  constraint document_texts_extraction_status_check CHECK ((extraction_status = ANY (ARRAY['pending'::text, 'done'::text, 'failed'::text, 'no_text'::text, 'skipped'::text]))),
  constraint document_texts_pkey PRIMARY KEY (document_id)
);
comment on table public.document_texts is 'Full extracted text per document. Deliberately excluded from take_snapshot: regenerable from Drive, and it would bloat every snapshot. search_title carries name, type label, issuer and person so those rank above body matches.';
comment on column public.document_texts.tsv is 'Built with the simple config, not german or english. The corpus is German, English and Ukrainian mixed, so a stemmer for one language actively hurts the others. Compound words like Wohngebaeudeversicherung are handled by the trigram index instead, since the german config does not decompound.';

create table if not exists public.document_type_aliases (
  alias text not null,
  type_key text not null,
  constraint document_type_aliases_pkey PRIMARY KEY (alias)
);
comment on table public.document_type_aliases is 'Maps every historical free-text document_type string onto a registry key, so old values stay resolvable and re-runs converge instead of drifting.';

create table if not exists public.document_types (
  key text not null,
  label text not null,
  domain text not null,
  expiry_expected boolean default false not null,
  notice_period_expected boolean default false not null,
  hard_deadline boolean default false not null,
  applies_to_kind text default 'document'::text not null,
  description text,
  hints text[] default '{}'::text[] not null,
  active boolean default true not null,
  constraint document_types_applies_to_kind_check CHECK ((applies_to_kind = ANY (ARRAY['document'::text, 'reference_file'::text, 'any'::text]))),
  constraint document_types_domain_check CHECK ((domain = ANY (ARRAY['identity'::text, 'insurance'::text, 'employment'::text, 'property'::text, 'finance'::text, 'legal'::text, 'education'::text, 'reference'::text, 'services'::text, 'vehicle'::text]))),
  constraint document_types_pkey PRIMARY KEY (key)
);
comment on table public.document_types is 'Closed list. Intake must classify into one of these keys, never invent a new string. Adding a key is a schema decision and goes through improvement_proposals with autonomy=ask.';
comment on column public.document_types.expiry_expected is 'True when a document of this type carries a validity date. A null expiry here is a failed extraction; a null expiry on a false type is simply the truth.';
comment on column public.document_types.notice_period_expected is 'True when the real deadline is a Kuendigungsfrist rather than an expiry date. These need a notice_period deadline, not a document_expiry one.';
comment on column public.document_types.hints is 'Words that identify this type in a file name or body, German and English. Classification aid, not a regex: read for meaning first, use hints to break ties.';

create table if not exists public.documents (
  id uuid default gen_random_uuid() not null,
  drive_file_id text not null,
  name text not null,
  drive_url text not null,
  mime_type text,
  para_category text,
  document_type text,
  issuer text,
  description text,
  tags text[] default '{}'::text[] not null,
  expiry_date date,
  status text default 'current'::text not null,
  content_excerpt text,
  added_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  todoist_task_id text,
  subject_person text,
  needs_review boolean default false not null,
  review_reason text,
  area_name text,
  kind text default 'document'::text not null,
  last_intake_at timestamp with time zone,
  content_fingerprint text generated always as (md5(lower(regexp_replace(COALESCE(NULLIF(content_excerpt, ''::text), name), '[^a-zA-Z0-9]'::text, ''::text, 'g'::text)))) stored,
  duplicate_of uuid,
  source_email_id uuid,
  document_type_key text,
  issuer_entity_id uuid,
  subject_entity_id uuid,
  physical_location text,
  has_original boolean,
  body_fingerprint text,
  issued_on date,
  constraint documents_kind_check CHECK ((kind = ANY (ARRAY['document'::text, 'reference_file'::text]))),
  constraint documents_para_category_check CHECK ((para_category = ANY (ARRAY['project'::text, 'area'::text, 'resource'::text, 'archive'::text]))),
  constraint documents_status_check CHECK ((status = ANY (ARRAY['current'::text, 'expired'::text, 'stale'::text, 'to_archive'::text]))),
  constraint documents_pkey PRIMARY KEY (id),
  constraint documents_drive_file_id_key UNIQUE (drive_file_id)
);
comment on column public.documents.todoist_task_id is 'Todoist task id created for this document''s expiry alert, if any. Prevents duplicate task creation without relying on text search.';
comment on column public.documents.subject_person is 'Who the document pertains to (e.g. Natalia, Kostiantyn, Kateryna, or multiple names for joint documents). Null if not determinable from content — never guessed.';
comment on column public.documents.needs_review is 'True when extraction is uncertain and a human should confirm (e.g. expiry_date null on a document type that usually has one).';
comment on column public.documents.area_name is 'Specific Craft area or project name this document belongs to, for real filtering. para_category stays as the coarse PARA bucket.';
comment on column public.documents.kind is 'document = formal doc with legal/expiry significance. reference_file = working file (template, comparison sheet) the person returns to — replaces the separate Craft "File Index" collection so there is one index, not two.';
comment on column public.documents.last_intake_at is 'Set to now() by the intake skill on every upsert. If a row changes without this moving, the change came from a human and is logged to corrections.';
comment on column public.documents.content_fingerprint is 'md5 of the normalised content excerpt (falls back to name). Second dedupe axis for the same physical document stored twice in Drive under different file ids.';
comment on column public.documents.duplicate_of is 'Points at the canonical row when this record is a duplicate copy. Never delete duplicates, link them, so the Drive file id stays resolvable.';
comment on column public.documents.source_email_id is 'Set when the document arrived as an email attachment rather than being uploaded to Drive directly. Links the paper back to the letter that transmitted it.';
comment on column public.documents.document_type_key is 'Controlled type from the document_types registry. The free-text document_type column is kept as the raw observed label, but every filter and metric reads this key.';
comment on column public.documents.physical_location is 'Where the paper original actually is. LEA and notaries want originals, and the index knowing only about the scan is a real gap on the day it is asked for.';

create table if not exists public.drive_folder_areas (
  drive_folder_id text not null,
  folder_path text not null,
  area_name text not null,
  para_category text not null,
  document_domain_hint text,
  notes text,
  created_at timestamp with time zone default now() not null,
  is_filing_default boolean default true not null,
  constraint drive_folder_areas_para_category_check CHECK ((para_category = ANY (ARRAY['area'::text, 'project'::text, 'resource'::text, 'archive'::text]))),
  constraint drive_folder_areas_pkey PRIMARY KEY (drive_folder_id)
);
comment on table public.drive_folder_areas is 'Canonical folder-to-area map, both directions: read by drive_file_id to classify an existing file''s location, and by area_name (is_filing_default=true) to decide where a newly classified document should be moved to. The Drive "Inbox" folder (1CRdp10JM5qy5FezTMHk4-ZKUBVwqRo6E) is intentionally absent: it is where new files land before classification, never a destination.';

create table if not exists public.email_processing_runs (
  id uuid default gen_random_uuid() not null,
  run_at timestamp with time zone default now() not null,
  emails_scanned integer default 0 not null,
  emails_added integer default 0 not null,
  emails_updated integer default 0 not null,
  actions_flagged integer default 0 not null,
  category_counts jsonb default '{}'::jsonb not null,
  notes text,
  skill_version text,
  started_at timestamp with time zone,
  errors jsonb default '[]'::jsonb not null,
  skipped jsonb default '[]'::jsonb not null,
  decisions jsonb default '[]'::jsonb not null,
  capabilities jsonb,
  constraint email_processing_runs_pkey PRIMARY KEY (id)
);
comment on column public.email_processing_runs.errors is 'Array of {stage, item, error}.';
comment on column public.email_processing_runs.skipped is 'Array of {item, reason} for threads deliberately not logged (CI noise, newsletters).';
comment on column public.email_processing_runs.decisions is 'Array of {item, field, chose, alternative, confidence} for low-confidence categorisations.';

create table if not exists public.emails (
  id uuid default gen_random_uuid() not null,
  gmail_message_id text not null,
  gmail_thread_id text,
  gmail_url text,
  subject text,
  sender_name text,
  sender_email text,
  received_at timestamp with time zone,
  category text not null,
  summary text,
  vendor text,
  item text,
  amount numeric,
  currency text,
  event_date date,
  due_date date,
  action_needed boolean default false not null,
  action_note text,
  todoist_task_id text,
  tags text[] default '{}'::text[] not null,
  content_excerpt text,
  added_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  last_intake_at timestamp with time zone,
  content_fingerprint text generated always as (md5(lower(regexp_replace((COALESCE(NULLIF(subject, ''::text), gmail_message_id) || COALESCE(sender_email, ''::text)), '[^a-zA-Z0-9]'::text, ''::text, 'g'::text)))) stored,
  has_attachments boolean default false not null,
  attachments_extracted boolean default false not null,
  attachment_names text[] default '{}'::text[] not null,
  tsv tsvector generated always as ((setweight(to_tsvector('simple'::regconfig, ((((COALESCE(subject, ''::text) || ' '::text) || COALESCE(sender_name, ''::text)) || ' '::text) || COALESCE(vendor, ''::text))), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, ((((COALESCE(summary, ''::text) || ' '::text) || COALESCE(content_excerpt, ''::text)) || ' '::text) || COALESCE(action_note, ''::text))), 'B'::"char"))) stored,
  sender_entity_id uuid,
  vendor_entity_id uuid,
  calendar_event_id text,
  constraint emails_category_check CHECK ((category = ANY (ARRAY['purchases'::text, 'orders_delivery'::text, 'government'::text, 'bank_finance'::text, 'bills_payments'::text, 'legal_notary'::text, 'work'::text, 'health'::text, 'travel'::text, 'personal_social'::text, 'other'::text]))),
  constraint emails_pkey PRIMARY KEY (id),
  constraint emails_gmail_message_id_key UNIQUE (gmail_message_id)
);
comment on column public.emails.last_intake_at is 'Set to now() by the intake skill on every upsert. If a row changes without this moving, the change came from a human and is logged to corrections.';
comment on column public.emails.attachments_extracted is 'True once the attachments have been saved to Drive and handed to the document intake path. False on a message with has_attachments is the backlog to work through.';

create table if not exists public.entities (
  id uuid default gen_random_uuid() not null,
  kind text not null,
  name text not null,
  legal_name text,
  role text,
  emails text[] default '{}'::text[] not null,
  domains text[] default '{}'::text[] not null,
  ibans text[] default '{}'::text[] not null,
  reference text,
  address text,
  notes text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint entities_kind_check CHECK ((kind = ANY (ARRAY['person'::text, 'organization'::text, 'authority'::text, 'property'::text, 'court'::text]))),
  constraint entities_pkey PRIMARY KEY (id)
);
comment on table public.entities is 'People, organisations, authorities and properties. Everything that used to be a repeated string now points here, so "show me everything Generali" becomes one join instead of three text searches.';

create table if not exists public.entity_aliases (
  alias text not null,
  entity_id uuid not null,
  constraint entity_aliases_pkey PRIMARY KEY (alias)
);
comment on table public.entity_aliases is 'Lowercased spellings, domains and abbreviations seen in the wild. Resolution is alias-first and deterministic, so it does not drift between runs.';

create table if not exists public.improvement_proposals (
  id uuid default gen_random_uuid() not null,
  created_at timestamp with time zone default now() not null,
  skill_name text,
  title text not null,
  severity text default 'medium'::text not null,
  problem text not null,
  evidence jsonb default '{}'::jsonb not null,
  proposed_change text not null,
  autonomy text not null,
  status text default 'open'::text not null,
  applied_revision_id uuid,
  todoist_task_id text,
  decided_at timestamp with time zone,
  constraint improvement_proposals_autonomy_check CHECK ((autonomy = ANY (ARRAY['auto'::text, 'ask'::text]))),
  constraint improvement_proposals_severity_check CHECK ((severity = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text]))),
  constraint improvement_proposals_status_check CHECK ((status = ANY (ARRAY['open'::text, 'applied'::text, 'rejected'::text, 'deferred'::text]))),
  constraint improvement_proposals_pkey PRIMARY KEY (id)
);
comment on table public.improvement_proposals is 'What the monthly review found. autonomy = auto means the skill may fix it itself and report; ask means it needs a human decision (schema, categories, data loss, scope of autonomy).';

create table if not exists public.life_review_runs (
  id uuid default gen_random_uuid() not null,
  ran_at timestamp with time zone default clock_timestamp() not null,
  mode text default 'monthly'::text not null,
  review_month text,
  skill_version text,
  summary jsonb,
  errors jsonb default '[]'::jsonb not null,
  notes text,
  constraint life_review_runs_pkey PRIMARY KEY (id)
);

create table if not exists public.life_settings (
  key text not null,
  value jsonb not null,
  updated_at timestamp with time zone default now(),
  constraint life_settings_pkey PRIMARY KEY (key)
);

create table if not exists public.matter_links (
  id uuid default gen_random_uuid() not null,
  matter_id uuid not null,
  object_kind text not null,
  object_id uuid not null,
  role text,
  created_at timestamp with time zone default now() not null,
  constraint matter_links_object_kind_check CHECK ((object_kind = ANY (ARRAY['document'::text, 'email'::text, 'deadline'::text, 'bundle'::text, 'recurring_payment'::text, 'note'::text, 'entity'::text]))),
  constraint matter_links_pkey PRIMARY KEY (id)
);

create table if not exists public.matters (
  id uuid default gen_random_uuid() not null,
  name text not null,
  kind text not null,
  status text default 'active'::text not null,
  reference text,
  opened_on date,
  closed_on date,
  owner_person text,
  description text,
  next_action text,
  next_action_on date,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint matters_kind_check CHECK ((kind = ANY (ARRAY['immigration'::text, 'property'::text, 'legal'::text, 'finance'::text, 'employment'::text, 'health'::text, 'other'::text]))),
  constraint matters_status_check CHECK ((status = ANY (ARRAY['active'::text, 'waiting'::text, 'closed'::text, 'abandoned'::text]))),
  constraint matters_pkey PRIMARY KEY (id)
);
comment on table public.matters is 'A thread of real life: the LEA extension, the Friedenstrasse purchase, case 1700/26. Documents, emails, deadlines, costs and bundles attach to it, so state is readable in one query instead of reassembled from memory.';

create table if not exists public.notes (
  id uuid default gen_random_uuid() not null,
  title text not null,
  body text not null,
  kind text default 'context'::text not null,
  matter_id uuid,
  entity_id uuid,
  document_id uuid,
  decided_on date,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  tsv tsvector generated always as ((setweight(to_tsvector('simple'::regconfig, COALESCE(title, ''::text)), 'A'::"char") || setweight(to_tsvector('simple'::regconfig, COALESCE(body, ''::text)), 'B'::"char"))) stored,
  constraint notes_kind_check CHECK ((kind = ANY (ARRAY['decision'::text, 'context'::text, 'question'::text, 'call_log'::text, 'summary'::text]))),
  constraint notes_pkey PRIMARY KEY (id)
);
comment on table public.notes is 'Why a thing was decided, next to the thing. Craft keeps long-form writing; anything that explains a document, an entity or a matter belongs here so search and the briefing can see it.';

create table if not exists public.processing_runs (
  id uuid default gen_random_uuid() not null,
  run_at timestamp with time zone default now() not null,
  files_scanned integer default 0 not null,
  files_added integer default 0 not null,
  files_updated integer default 0 not null,
  expiring_flagged integer default 0 not null,
  notes text,
  skill_version text,
  started_at timestamp with time zone,
  errors jsonb default '[]'::jsonb not null,
  skipped jsonb default '[]'::jsonb not null,
  decisions jsonb default '[]'::jsonb not null,
  text_queue_depth integer,
  capabilities jsonb,
  constraint processing_runs_pkey PRIMARY KEY (id)
);
comment on column public.processing_runs.errors is 'Array of {stage, item, error} for anything that failed during the run. Empty array means a clean run, never leave it empty to hide a failure.';
comment on column public.processing_runs.skipped is 'Array of {item, reason} for candidates deliberately not indexed. Makes "what did the skill ignore" auditable.';
comment on column public.processing_runs.decisions is 'Array of {item, field, chose, alternative, confidence} for low-confidence calls (ambiguous document_type, guessed issuer, unclear PARA bucket).';

create table if not exists public.recall_samples (
  id uuid default gen_random_uuid() not null,
  checked_at timestamp with time zone default now() not null,
  source text not null,
  window_start timestamp with time zone,
  window_end timestamp with time zone,
  sample_size integer not null,
  found integer not null,
  missed integer not null,
  missed_items jsonb default '[]'::jsonb not null,
  notes text,
  constraint recall_samples_source_check CHECK ((source = ANY (ARRAY['gmail'::text, 'drive'::text]))),
  constraint recall_samples_pkey PRIMARY KEY (id)
);
comment on table public.recall_samples is 'Draw N random items from the source system and assert each is either indexed or explicitly named in a run skipped array. Measures what the skill missed, which no self-reported metric can.';

create table if not exists public.recurring_payments (
  id uuid default gen_random_uuid() not null,
  name text not null,
  vendor text,
  category text not null,
  amount numeric(12,2) not null,
  currency text default 'EUR'::text not null,
  period text not null,
  payment_method text,
  reference text,
  contract_start date,
  contract_end date,
  notice_period_months integer,
  auto_renews boolean default true not null,
  status text default 'active'::text not null,
  subject_person text,
  document_id uuid,
  deadline_id uuid,
  notes text,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  monthly_equivalent numeric(12,2) generated always as (round((amount / (
CASE period
    WHEN 'monthly'::text THEN 1
    WHEN 'quarterly'::text THEN 3
    WHEN 'semiannual'::text THEN 6
    WHEN 'annual'::text THEN 12
    ELSE NULL::integer
END)::numeric), 2)) stored,
  vendor_entity_id uuid,
  tax_relevance text,
  constraint recurring_payments_category_check CHECK ((category = ANY (ARRAY['housing'::text, 'utilities'::text, 'telecom'::text, 'insurance'::text, 'pension'::text, 'loan'::text, 'subscription'::text, 'other'::text]))),
  constraint recurring_payments_period_check CHECK ((period = ANY (ARRAY['monthly'::text, 'quarterly'::text, 'semiannual'::text, 'annual'::text]))),
  constraint recurring_payments_status_check CHECK ((status = ANY (ARRAY['active'::text, 'cancelled'::text, 'ended'::text]))),
  constraint recurring_payments_tax_relevance_check CHECK ((tax_relevance = ANY (ARRAY['vorsorge_basisrente'::text, 'vorsorge_sonstige'::text, 'werbungskosten_candidate'::text, '35a_candidate'::text, 'none'::text]))),
  constraint recurring_payments_pkey PRIMARY KEY (id)
);
comment on table public.recurring_payments is 'Every standing financial obligation, normalised to a monthly equivalent. notice_period_months plus contract_end is what makes an unwanted auto-renewal visible before it happens rather than after.';

create table if not exists public.run_locks (
  skill_name text not null,
  locked_at timestamp with time zone default now() not null,
  expires_at timestamp with time zone not null,
  holder text,
  constraint run_locks_pkey PRIMARY KEY (skill_name)
);
comment on table public.run_locks is 'Cross-connection mutex. pg_advisory_lock is useless here because every MCP call is its own session. Acquire returns zero rows when another run holds the lock.';

create table if not exists public.skill_revisions (
  id uuid default gen_random_uuid() not null,
  skill_name text not null,
  version text not null,
  changed_at timestamp with time zone default now() not null,
  change_type text not null,
  summary text not null,
  rationale text,
  diff text,
  skill_md text,
  metrics_before jsonb,
  metrics_after jsonb,
  rolled_back boolean default false not null,
  constraint skill_revisions_change_type_check CHECK ((change_type = ANY (ARRAY['autonomous'::text, 'approved'::text, 'rollback'::text, 'baseline'::text]))),
  constraint skill_revisions_pkey PRIMARY KEY (id)
);
comment on table public.skill_revisions is 'Append-only lineage of every change to a SKILL.md, with the full file snapshot so any version can be restored. Mirrors the DGM archive idea: no change without a traceable parent.';

-- Foreign keys
alter table public.bank_statement_imports add constraint bank_statement_imports_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id);
alter table public.bank_transactions add constraint bank_transactions_counterparty_entity_id_fkey FOREIGN KEY (counterparty_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.bank_transactions add constraint bank_transactions_email_id_fkey FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE SET NULL;
alter table public.bank_transactions add constraint bank_transactions_recurring_payment_id_fkey FOREIGN KEY (recurring_payment_id) REFERENCES recurring_payments(id) ON DELETE SET NULL;
alter table public.bundle_requirements add constraint bundle_requirements_bundle_id_fkey FOREIGN KEY (bundle_id) REFERENCES bundles(id) ON DELETE CASCADE;
alter table public.bundle_requirements add constraint bundle_requirements_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE SET NULL;
alter table public.bundle_requirements add constraint bundle_requirements_document_type_key_fkey FOREIGN KEY (document_type_key) REFERENCES document_types(key) ON UPDATE CASCADE;
alter table public.classification_rules add constraint classification_rules_set_document_type_key_fkey FOREIGN KEY (set_document_type_key) REFERENCES document_types(key) ON UPDATE CASCADE;
alter table public.classification_rules add constraint classification_rules_set_entity_id_fkey FOREIGN KEY (set_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.classification_rules add constraint classification_rules_set_matter_id_fkey FOREIGN KEY (set_matter_id) REFERENCES matters(id) ON DELETE SET NULL;
alter table public.deadlines add constraint deadlines_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.document_texts add constraint document_texts_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE;
alter table public.document_type_aliases add constraint document_type_aliases_type_key_fkey FOREIGN KEY (type_key) REFERENCES document_types(key) ON UPDATE CASCADE;
alter table public.documents add constraint documents_document_type_key_fkey FOREIGN KEY (document_type_key) REFERENCES document_types(key) ON UPDATE CASCADE;
alter table public.documents add constraint documents_duplicate_of_fkey FOREIGN KEY (duplicate_of) REFERENCES documents(id) ON DELETE SET NULL;
alter table public.documents add constraint documents_issuer_entity_id_fkey FOREIGN KEY (issuer_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.documents add constraint documents_source_email_id_fkey FOREIGN KEY (source_email_id) REFERENCES emails(id) ON DELETE SET NULL;
alter table public.documents add constraint documents_subject_entity_id_fkey FOREIGN KEY (subject_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.emails add constraint emails_sender_entity_id_fkey FOREIGN KEY (sender_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.emails add constraint emails_vendor_entity_id_fkey FOREIGN KEY (vendor_entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.entity_aliases add constraint entity_aliases_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE CASCADE;
alter table public.improvement_proposals add constraint improvement_proposals_applied_revision_id_fkey FOREIGN KEY (applied_revision_id) REFERENCES skill_revisions(id);
alter table public.matter_links add constraint matter_links_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE CASCADE;
alter table public.notes add constraint notes_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE SET NULL;
alter table public.notes add constraint notes_entity_id_fkey FOREIGN KEY (entity_id) REFERENCES entities(id) ON DELETE SET NULL;
alter table public.notes add constraint notes_matter_id_fkey FOREIGN KEY (matter_id) REFERENCES matters(id) ON DELETE SET NULL;
alter table public.recurring_payments add constraint recurring_payments_deadline_id_fkey FOREIGN KEY (deadline_id) REFERENCES deadlines(id) ON DELETE SET NULL;
alter table public.recurring_payments add constraint recurring_payments_document_id_fkey FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE SET NULL;
alter table public.recurring_payments add constraint recurring_payments_vendor_entity_id_fkey FOREIGN KEY (vendor_entity_id) REFERENCES entities(id) ON DELETE SET NULL;

-- Indexes
CREATE INDEX IF NOT EXISTS idx_attachment_staging_unclaimed ON public.attachment_staging USING btree (gmail_message_id) WHERE (NOT claimed);
CREATE INDEX IF NOT EXISTS backup_snapshots_taken_idx ON public.backup_snapshots USING btree (taken_at DESC);
CREATE INDEX IF NOT EXISTS bank_transactions_booked_idx ON public.bank_transactions USING btree (booked_on DESC);
CREATE UNIQUE INDEX IF NOT EXISTS bank_transactions_dedupe_idx ON public.bank_transactions USING btree (booked_on, amount, direction, COALESCE(reference, ''::text));
CREATE UNIQUE INDEX IF NOT EXISTS briefings_date_uidx ON public.briefings USING btree (briefing_date);
CREATE UNIQUE INDEX IF NOT EXISTS bundle_requirements_unique_idx ON public.bundle_requirements USING btree (bundle_id, label, COALESCE(subject_person, ''::text));
CREATE INDEX IF NOT EXISTS classification_rules_scope_idx ON public.classification_rules USING btree (scope, priority) WHERE active;
CREATE INDEX IF NOT EXISTS corrections_recent_idx ON public.corrections USING btree (corrected_at DESC);
CREATE INDEX IF NOT EXISTS corrections_unreviewed_idx ON public.corrections USING btree (reviewed) WHERE (reviewed = false);
CREATE INDEX IF NOT EXISTS deadlines_open_idx ON public.deadlines USING btree (due_on) WHERE (status = 'open'::text);
CREATE UNIQUE INDEX IF NOT EXISTS deadlines_dedupe_idx ON public.deadlines USING btree (COALESCE(source_kind, 'manual'::text), COALESCE(source_id, '00000000-0000-0000-0000-000000000000'::uuid), deadline_type, due_on);
CREATE INDEX IF NOT EXISTS document_texts_status_idx ON public.document_texts USING btree (extraction_status);
CREATE INDEX IF NOT EXISTS document_texts_trgm_idx ON public.document_texts USING gin (body gin_trgm_ops);
CREATE INDEX IF NOT EXISTS document_texts_tsv_idx ON public.document_texts USING gin (tsv);
CREATE INDEX IF NOT EXISTS documents_body_fingerprint_idx ON public.documents USING btree (body_fingerprint);
CREATE INDEX IF NOT EXISTS documents_expiry_idx ON public.documents USING btree (expiry_date) WHERE (expiry_date IS NOT NULL);
CREATE INDEX IF NOT EXISTS documents_fingerprint_idx ON public.documents USING btree (content_fingerprint);
CREATE INDEX IF NOT EXISTS documents_search_idx ON public.documents USING gin (to_tsvector('simple'::regconfig, ((((COALESCE(name, ''::text) || ' '::text) || COALESCE(description, ''::text)) || ' '::text) || COALESCE(content_excerpt, ''::text))));
CREATE INDEX IF NOT EXISTS documents_type_key_idx ON public.documents USING btree (document_type_key);
CREATE INDEX IF NOT EXISTS emails_action_idx ON public.emails USING btree (action_needed) WHERE (action_needed = true);
CREATE INDEX IF NOT EXISTS emails_category_idx ON public.emails USING btree (category);
CREATE INDEX IF NOT EXISTS emails_due_date_idx ON public.emails USING btree (due_date) WHERE (due_date IS NOT NULL);
CREATE INDEX IF NOT EXISTS emails_fingerprint_idx ON public.emails USING btree (content_fingerprint);
CREATE INDEX IF NOT EXISTS emails_search_idx ON public.emails USING gin (to_tsvector('simple'::regconfig, ((((((COALESCE(subject, ''::text) || ' '::text) || COALESCE(summary, ''::text)) || ' '::text) || COALESCE(vendor, ''::text)) || ' '::text) || COALESCE(content_excerpt, ''::text))));
CREATE INDEX IF NOT EXISTS emails_tsv_idx ON public.emails USING gin (tsv);
CREATE INDEX IF NOT EXISTS improvement_proposals_open_idx ON public.improvement_proposals USING btree (status) WHERE (status = 'open'::text);
CREATE INDEX IF NOT EXISTS matter_links_object_idx ON public.matter_links USING btree (object_kind, object_id);
CREATE UNIQUE INDEX IF NOT EXISTS matter_links_unique_idx ON public.matter_links USING btree (matter_id, object_kind, object_id);
CREATE INDEX IF NOT EXISTS notes_tsv_idx ON public.notes USING gin (tsv);
CREATE INDEX IF NOT EXISTS skill_revisions_skill_idx ON public.skill_revisions USING btree (skill_name, changed_at DESC);
