-- Views, in dependency order, all security_invoker.
-- Exported from the reference deployment. Do not edit by hand; add a new migration instead.

create or replace view public.v_address_audit with (security_invoker = on) as
WITH pat AS (
         SELECT jsonb_array_elements_text(life_settings.value) AS p
           FROM life_settings
          WHERE (life_settings.key = 'former_address_patterns'::text)
        ), ign AS (
         SELECT jsonb_array_elements_text(life_settings.value) AS p
           FROM life_settings
          WHERE (life_settings.key = 'address_audit_ignore'::text)
        ), latest AS (
         SELECT DISTINCT ON (COALESCE((e.vendor_entity_id)::text, lower(COALESCE(e.vendor, e.sender_name)))) COALESCE(e.vendor, e.sender_name) AS counterparty,
            e.received_at,
            e.subject,
            e.gmail_url,
            (EXISTS ( SELECT 1
                   FROM pat
                  WHERE ((e.content_excerpt ~~* (('%'::text || pat.p) || '%'::text)) OR (e.subject ~~* (('%'::text || pat.p) || '%'::text))))) AS old_address
           FROM emails e
          WHERE ((e.received_at > (now() - '180 days'::interval)) AND (e.category <> ALL (ARRAY['orders_delivery'::text, 'purchases'::text, 'other'::text])))
          ORDER BY COALESCE((e.vendor_entity_id)::text, lower(COALESCE(e.vendor, e.sender_name))), e.received_at DESC
        )
 SELECT counterparty,
    (received_at)::date AS last_mail,
    subject,
    gmail_url
   FROM latest
  WHERE (old_address AND (NOT (EXISTS ( SELECT 1
           FROM ign
          WHERE (latest.counterparty ~~* (('%'::text || ign.p) || '%'::text))))))
  ORDER BY received_at DESC;

create or replace view public.v_attachment_backlog with (security_invoker = on) as
SELECT e.id,
    (e.received_at)::date AS received,
    e.category,
    e.sender_name,
    e.subject,
    e.attachment_names,
    COALESCE((b.processed_at)::text, 'never'::text) AS bridge_seen
   FROM (emails e
     LEFT JOIN bridge_messages b ON ((b.gmail_message_id = e.gmail_message_id)))
  WHERE (e.has_attachments AND (NOT e.attachments_extracted) AND bridge_in_scope(e.category) AND (NOT (EXISTS ( SELECT 1
           FROM attachment_staging s
          WHERE ((s.gmail_message_id = e.gmail_message_id) AND (s.resolved_at IS NULL))))) AND (NOT ((b.gmail_message_id IS NOT NULL) AND (b.copied = 0) AND (jsonb_array_length(b.skipped) = 0))))
  ORDER BY e.received_at DESC;

create or replace view public.v_attachment_pending_index with (security_invoker = on) as
SELECT e.id,
    (e.received_at)::date AS received,
    e.category,
    s.filename,
    s.drive_file_id,
    s.saved_at,
    round((EXTRACT(epoch FROM (now() - s.saved_at)) / 3600.0), 1) AS hours_waiting
   FROM (attachment_staging s
     JOIN emails e ON ((e.gmail_message_id = s.gmail_message_id)))
  WHERE ((NOT s.claimed) AND (s.resolved_at IS NULL) AND bridge_in_scope(e.category))
  ORDER BY s.saved_at;

create or replace view public.v_bank_coverage with (security_invoker = on) as
SELECT account_iban,
    min(booked_on) AS first_booked,
    max(booked_on) AS last_booked,
    (CURRENT_DATE - max(booked_on)) AS days_stale,
    count(*) AS transactions,
    count(*) FILTER (WHERE (recurring_payment_id IS NOT NULL)) AS linked
   FROM bank_transactions
  GROUP BY account_iban;

create or replace view public.v_bank_statement_backlog with (security_invoker = on) as
SELECT id,
    name,
    drive_url,
    (added_at)::date AS added_at
   FROM documents d
  WHERE ((document_type_key = 'bank_statement'::text) AND (duplicate_of IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM bank_statement_imports i
          WHERE (i.document_id = d.id)))))
  ORDER BY d.added_at;

create or replace view public.v_bridge_heal with (security_invoker = on) as
SELECT s.id,
    s.gmail_message_id,
    s.filename,
    s.drive_file_id,
    s.last_verified_at
   FROM (attachment_staging s
     JOIN emails e ON ((e.gmail_message_id = s.gmail_message_id)))
  WHERE ((NOT s.claimed) AND (s.resolved_at IS NULL) AND bridge_in_scope(e.category) AND ((s.last_verified_at IS NULL) OR (s.last_verified_at < (now() - '01:00:00'::interval))))
  ORDER BY s.last_verified_at NULLS FIRST;

create or replace view public.v_bridge_queue with (security_invoker = on) as
SELECT e.gmail_message_id,
    e.category,
    e.received_at,
    e.attachment_names
   FROM (emails e
     LEFT JOIN bridge_messages b ON ((b.gmail_message_id = e.gmail_message_id)))
  WHERE (e.has_attachments AND (NOT e.attachments_extracted) AND bridge_in_scope(e.category) AND ((b.gmail_message_id IS NULL) OR (EXISTS ( SELECT 1
           FROM jsonb_array_elements(b.skipped) x(value)
          WHERE (((x.value ->> 'reason'::text) ~~ 'mime %octet-stream%'::text) AND (lower((x.value ->> 'filename'::text)) ~ '\.(pdf|jpe?g|png|docx?)$'::text) AND (NOT (EXISTS ( SELECT 1
                   FROM attachment_staging s
                  WHERE ((s.gmail_message_id = e.gmail_message_id) AND (s.filename = (x.value ->> 'filename'::text)) AND (s.resolved_at IS NULL))))))))))
  ORDER BY e.received_at DESC;

create or replace view public.v_bundle_status with (security_invoker = on) as
SELECT b.id AS bundle_id,
    b.name AS bundle,
    b.due_on,
    b.status,
    r.id AS requirement_id,
    r.label,
    r.required,
    r.subject_person AS needs_person,
    r.document_type_key,
    COALESCE(r.document_id, d.id) AS resolved_document_id,
        CASE
            WHEN r.satisfied_manually THEN 'satisfied (manual)'::text
            WHEN (COALESCE(r.document_id, d.id) IS NULL) THEN 'MISSING'::text
            WHEN ((r.max_age_days IS NOT NULL) AND (COALESCE(dd.added_at, d.added_at) < (now() - ((r.max_age_days || ' days'::text))::interval))) THEN 'TOO OLD'::text
            WHEN (r.must_be_current AND (COALESCE(dd.status, d.status) <> 'current'::text)) THEN 'NOT CURRENT'::text
            ELSE 'ok'::text
        END AS state,
    COALESCE(dd.name, d.name) AS document_name,
    COALESCE(dd.drive_url, d.drive_url) AS drive_url
   FROM (((bundles b
     JOIN bundle_requirements r ON ((r.bundle_id = b.id)))
     LEFT JOIN documents dd ON ((dd.id = r.document_id)))
     LEFT JOIN LATERAL ( SELECT d2.id,
            d2.drive_file_id,
            d2.name,
            d2.drive_url,
            d2.mime_type,
            d2.para_category,
            d2.document_type,
            d2.issuer,
            d2.description,
            d2.tags,
            d2.expiry_date,
            d2.status,
            d2.content_excerpt,
            d2.added_at,
            d2.updated_at,
            d2.todoist_task_id,
            d2.subject_person,
            d2.needs_review,
            d2.review_reason,
            d2.area_name,
            d2.kind,
            d2.last_intake_at,
            d2.content_fingerprint,
            d2.duplicate_of,
            d2.source_email_id,
            d2.document_type_key
           FROM documents d2
          WHERE ((r.document_id IS NULL) AND (d2.document_type_key = r.document_type_key) AND (d2.duplicate_of IS NULL) AND ((r.subject_person IS NULL) OR (d2.subject_person = r.subject_person)))
          ORDER BY (d2.status = 'current'::text) DESC, d2.expiry_date DESC NULLS LAST, d2.added_at DESC
         LIMIT 1) d ON (true));

create or replace view public.v_bundle_summary with (security_invoker = on) as
SELECT bundle_id,
    bundle,
    due_on,
    status,
    count(*) FILTER (WHERE required) AS required_items,
    count(*) FILTER (WHERE (required AND (state = 'ok'::text))) AS ready,
    count(*) FILTER (WHERE (required AND (state <> 'ok'::text))) AS blocking,
    array_agg(label ORDER BY label) FILTER (WHERE (required AND (state <> 'ok'::text))) AS missing
   FROM v_bundle_status
  GROUP BY bundle_id, bundle, due_on, status;

create or replace view public.v_deadline_triggers with (security_invoker = on) as
SELECT id,
    title,
    deadline_type,
    due_on,
    hard,
    subject_person,
    todoist_task_id,
    notes,
    (due_on - CURRENT_DATE) AS days_left
   FROM deadlines d
  WHERE ((status = 'open'::text) AND ((snoozed_until IS NULL) OR (snoozed_until <= CURRENT_DATE)) AND ((due_on - CURRENT_DATE) = ANY (lead_days)));
comment on view public.v_deadline_triggers is 'Deadlines whose distance from today exactly matches one rung of their lead_days ladder. This is what the brief reports, not everything that is merely open.';

create or replace view public.v_deadlines_due with (security_invoker = on) as
SELECT id,
    title,
    deadline_type,
    due_on,
    hard,
    lead_days,
    subject_person,
    source_kind,
    source_id,
    status,
    todoist_task_id,
    notes,
    created_at,
    updated_at,
    last_intake_at,
    (due_on - CURRENT_DATE) AS days_left
   FROM deadlines d
  WHERE ((status = 'open'::text) AND (due_on <= (CURRENT_DATE + COALESCE(( SELECT max(x.x) AS max
           FROM unnest(d.lead_days) x(x)), 7))))
  ORDER BY hard DESC, due_on;
comment on view public.v_deadlines_due is 'Open deadlines that have entered their reminder window. Hard ones first. Should drive task creation on every run.';

create or replace view public.v_deadlines_missed with (security_invoker = on) as
SELECT id,
    title,
    deadline_type,
    due_on,
    hard,
    status,
    subject_person,
    (CURRENT_DATE - due_on) AS days_overdue,
    todoist_task_id
   FROM deadlines
  WHERE ((status = ANY (ARRAY['open'::text, 'missed'::text])) AND (due_on < CURRENT_DATE))
  ORDER BY hard DESC, due_on;
comment on view public.v_deadlines_missed is 'Anything past its date that has not been closed out. status=missed does not hide it: a missed hard deadline stays visible until explicitly resolved or cancelled.';

create or replace view public.v_duplicate_candidates with (security_invoker = on) as
SELECT COALESCE(body_fingerprint, ('excerpt:'::text || content_fingerprint)) AS fingerprint,
    (body_fingerprint IS NOT NULL) AS from_full_text,
    array_agg(id ORDER BY added_at) AS document_ids,
    array_agg(name ORDER BY added_at) AS names
   FROM documents d
  WHERE ((duplicate_of IS NULL) AND (status <> 'to_archive'::text))
  GROUP BY COALESCE(body_fingerprint, ('excerpt:'::text || content_fingerprint)), (body_fingerprint IS NOT NULL)
 HAVING (count(*) > 1);

create or replace view public.v_entity_overview with (security_invoker = on) as
SELECT id,
    kind,
    name,
    role,
    ( SELECT count(*) AS count
           FROM documents d
          WHERE ((d.issuer_entity_id = e.id) OR (d.subject_entity_id = e.id))) AS documents,
    ( SELECT count(*) AS count
           FROM emails m
          WHERE ((m.sender_entity_id = e.id) OR (m.vendor_entity_id = e.id))) AS emails,
    ( SELECT round(sum(r.monthly_equivalent), 2) AS round
           FROM recurring_payments r
          WHERE ((r.vendor_entity_id = e.id) AND (r.status = 'active'::text))) AS monthly_cost,
    ( SELECT count(*) AS count
           FROM deadlines d
          WHERE ((d.entity_id = e.id) AND (d.status = 'open'::text))) AS open_deadlines
   FROM entities e
  ORDER BY kind, name;

create or replace view public.v_hard_deadline_guard with (security_invoker = on) as
SELECT id,
    title,
    due_on,
    (due_on - CURRENT_DATE) AS days_left,
    todoist_task_id,
        CASE
            WHEN (due_on < CURRENT_DATE) THEN 'overdue'::text
            ELSE 'no_task'::text
        END AS problem
   FROM deadlines d
  WHERE ((status = 'open'::text) AND hard AND ((snoozed_until IS NULL) OR (snoozed_until < CURRENT_DATE)) AND ((due_on < CURRENT_DATE) OR ((due_on <= (CURRENT_DATE + 30)) AND (todoist_task_id IS NULL))))
  ORDER BY due_on;

create or replace view public.v_intake_watchdog with (security_invoker = on) as
SELECT 'email-intake'::text AS skill,
    ( SELECT max(email_processing_runs.run_at) AS max
           FROM email_processing_runs) AS last_run,
    round((EXTRACT(epoch FROM (now() - ( SELECT max(email_processing_runs.run_at) AS max
           FROM email_processing_runs))) / 3600.0), 1) AS hours_since,
    36 AS sla_hours,
    (( SELECT max(email_processing_runs.run_at) AS max
           FROM email_processing_runs) < (now() - '36:00:00'::interval)) AS overdue,
    ( SELECT COALESCE(sum(jsonb_array_length(email_processing_runs.errors)), (0)::bigint) AS "coalesce"
           FROM email_processing_runs
          WHERE (email_processing_runs.run_at > (now() - '7 days'::interval))) AS errors_7d,
    ( SELECT count(*) AS count
           FROM email_processing_runs
          WHERE (email_processing_runs.run_at > (now() - '7 days'::interval))) AS runs_7d,
    7 AS runs_7d_expected
UNION ALL
 SELECT 'drive-file-intake'::text AS skill,
    ( SELECT max(processing_runs.run_at) AS max
           FROM processing_runs) AS last_run,
    round((EXTRACT(epoch FROM (now() - ( SELECT max(processing_runs.run_at) AS max
           FROM processing_runs))) / 3600.0), 1) AS hours_since,
    30 AS sla_hours,
    (( SELECT max(processing_runs.run_at) AS max
           FROM processing_runs) < (now() - '30:00:00'::interval)) AS overdue,
    ( SELECT COALESCE(sum(jsonb_array_length(processing_runs.errors)), (0)::bigint) AS "coalesce"
           FROM processing_runs
          WHERE (processing_runs.run_at > (now() - '7 days'::interval))) AS errors_7d,
    ( SELECT count(*) AS count
           FROM processing_runs
          WHERE (processing_runs.run_at > (now() - '7 days'::interval))) AS runs_7d,
    7 AS runs_7d_expected
UNION ALL
 SELECT 'attachment-bridge'::text AS skill,
    ( SELECT max(bridge_runs.finished_at) AS max
           FROM bridge_runs) AS last_run,
    round((EXTRACT(epoch FROM (now() - ( SELECT max(bridge_runs.finished_at) AS max
           FROM bridge_runs))) / 3600.0), 1) AS hours_since,
    1 AS sla_hours,
    COALESCE((( SELECT max(bridge_runs.finished_at) AS max
           FROM bridge_runs) < (now() - '01:00:00'::interval)), true) AS overdue,
    ( SELECT COALESCE(sum(jsonb_array_length(bridge_runs.errors)), (0)::bigint) AS "coalesce"
           FROM bridge_runs
          WHERE (bridge_runs.started_at > (now() - '7 days'::interval))) AS errors_7d,
    ( SELECT count(*) AS count
           FROM bridge_runs
          WHERE (bridge_runs.started_at > (now() - '7 days'::interval))) AS runs_7d,
    672 AS runs_7d_expected;
comment on view public.v_intake_watchdog is 'Liveness check for the intake jobs. Each job has its own SLA in the view (email-intake 36h, drive-intake 30h, attachment-bridge 1h). A job that silently stopped running looks identical to a job with nothing to do, which is why runs_7d matters as much as last_run.';

create or replace view public.v_invoice_reconciliation with (security_invoker = on) as
WITH cov AS (
         SELECT max(bank_transactions.booked_on) AS last_booked
           FROM bank_transactions
        )
 SELECT e.id AS email_id,
    (e.received_at)::date AS received,
    COALESCE(e.vendor, e.sender_name) AS vendor,
    e.amount,
    e.due_date,
    ( SELECT t.id
           FROM bank_transactions t
          WHERE ((t.direction = 'debit'::text) AND (abs((t.amount - e.amount)) < 0.01) AND ((t.booked_on >= ((e.received_at)::date - 5)) AND (t.booked_on <= (COALESCE(e.due_date, (e.received_at)::date) + 20))))
          ORDER BY (similarity(lower(t.counterparty), lower(COALESCE(e.vendor, e.sender_name, ''::text)))) DESC
         LIMIT 1) AS matched_tx,
    ((COALESCE(e.due_date, (e.received_at)::date) + 20) <= cov.last_booked) AS period_covered
   FROM (emails e
     CROSS JOIN cov)
  WHERE ((e.category = 'bills_payments'::text) AND (e.amount IS NOT NULL) AND (e.amount > (0)::numeric));

create or replace view public.v_matter_overview with (security_invoker = on) as
SELECT id,
    name,
    kind,
    status,
    reference,
    next_action,
    next_action_on,
    ( SELECT count(*) AS count
           FROM matter_links l
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'document'::text))) AS documents,
    ( SELECT count(*) AS count
           FROM matter_links l
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'email'::text))) AS emails,
    ( SELECT count(*) AS count
           FROM (matter_links l
             JOIN deadlines d ON ((d.id = l.object_id)))
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'deadline'::text) AND (d.status = 'open'::text))) AS open_deadlines,
    ( SELECT min(d.due_on) AS min
           FROM (matter_links l
             JOIN deadlines d ON ((d.id = l.object_id)))
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'deadline'::text) AND (d.status = 'open'::text))) AS next_deadline,
    ( SELECT count(*) AS count
           FROM (matter_links l
             JOIN deadlines d ON ((d.id = l.object_id)))
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'deadline'::text) AND d.hard AND (d.due_on < CURRENT_DATE) AND (d.status = ANY (ARRAY['open'::text, 'missed'::text])))) AS hard_overdue,
    ( SELECT round(sum(r.monthly_equivalent), 2) AS round
           FROM (matter_links l
             JOIN recurring_payments r ON ((r.id = l.object_id)))
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'recurring_payment'::text) AND (r.status = 'active'::text))) AS monthly_cost,
    ( SELECT sum(bs.blocking) AS sum
           FROM (matter_links l
             JOIN v_bundle_summary bs ON ((bs.bundle_id = l.object_id)))
          WHERE ((l.matter_id = m.id) AND (l.object_kind = 'bundle'::text))) AS bundle_blocking,
    ( SELECT count(*) AS count
           FROM notes n
          WHERE (n.matter_id = m.id)) AS notes
   FROM matters m
  WHERE (status = ANY (ARRAY['active'::text, 'waiting'::text]))
  ORDER BY kind, name;
comment on view public.v_matter_overview is 'One row per live thread of real life. This is the "where does everything stand" query the system previously could not answer at all.';

create or replace view public.v_missing_expiry with (security_invoker = on) as
SELECT d.id,
    d.name,
    d.document_type_key,
    t.label,
    d.subject_person,
    d.status
   FROM (documents d
     JOIN document_types t ON ((t.key = d.document_type_key)))
  WHERE (t.expiry_expected AND (d.expiry_date IS NULL) AND (d.duplicate_of IS NULL))
  ORDER BY t.label;
comment on view public.v_missing_expiry is 'Types that should carry a validity date but do not. This, not the raw null count, is the extraction-quality signal.';

create or replace view public.v_missing_notice_period with (security_invoker = on) as
SELECT d.id,
    d.name,
    d.document_type_key,
    t.label,
    d.issuer,
    d.subject_person
   FROM (documents d
     JOIN document_types t ON ((t.key = d.document_type_key)))
  WHERE (t.notice_period_expected AND (d.duplicate_of IS NULL) AND (d.status <> ALL (ARRAY['stale'::text, 'to_archive'::text, 'expired'::text])) AND (NOT (EXISTS ( SELECT 1
           FROM deadlines dl
          WHERE ((dl.source_kind = 'document'::text) AND (dl.source_id = d.id) AND (dl.deadline_type = 'notice_period'::text) AND (dl.status = ANY (ARRAY['open'::text, 'done'::text])))))) AND (NOT (EXISTS ( SELECT 1
           FROM recurring_payments rp
          WHERE ((rp.document_id = d.id) AND (rp.contract_end IS NULL) AND (rp.notice_period_months IS NOT NULL))))))
  ORDER BY t.label;
comment on view public.v_missing_notice_period is 'Auto-renewing contracts with no Kuendigungsfrist deadline recorded. These are invisible to every expiry-based check, which is exactly how an unwanted renewal happens.';

create or replace view public.v_monthly_costs with (security_invoker = on) as
SELECT recurring_payments.category,
    count(*) AS items,
    round(sum(recurring_payments.monthly_equivalent), 2) AS monthly,
    round((sum(recurring_payments.monthly_equivalent) * (12)::numeric), 2) AS annual
   FROM recurring_payments
  WHERE (recurring_payments.status = 'active'::text)
  GROUP BY recurring_payments.category
UNION ALL
 SELECT 'TOTAL'::text AS category,
    count(*) AS items,
    round(sum(recurring_payments.monthly_equivalent), 2) AS monthly,
    round((sum(recurring_payments.monthly_equivalent) * (12)::numeric), 2) AS annual
   FROM recurring_payments
  WHERE (recurring_payments.status = 'active'::text);

create or replace view public.v_notice_calendar with (security_invoker = on) as
SELECT id,
    name,
    vendor,
    amount,
    period,
    monthly_equivalent,
    contract_end,
    notice_period_months,
    auto_renews,
        CASE
            WHEN ((contract_end IS NOT NULL) AND (notice_period_months IS NOT NULL)) THEN ((contract_end - make_interval(months => notice_period_months)))::date
            WHEN ((contract_end IS NULL) AND (notice_period_months IS NOT NULL)) THEN CURRENT_DATE
            ELSE NULL::date
        END AS cancel_by,
        CASE
            WHEN ((contract_end IS NOT NULL) AND (notice_period_months IS NOT NULL)) THEN contract_end
            WHEN ((contract_end IS NULL) AND (notice_period_months IS NOT NULL)) THEN ((date_trunc('month'::text, (CURRENT_DATE + make_interval(months => notice_period_months))) + '1 mon -1 days'::interval))::date
            ELSE NULL::date
        END AS earliest_exit,
    (notice_period_months IS NOT NULL) AS exit_known
   FROM recurring_payments rp
  WHERE ((status = 'active'::text) AND (amount > (0)::numeric))
  ORDER BY (notice_period_months IS NOT NULL),
        CASE
            WHEN ((contract_end IS NOT NULL) AND (notice_period_months IS NOT NULL)) THEN ((contract_end - make_interval(months => notice_period_months)))::date
            WHEN ((contract_end IS NULL) AND (notice_period_months IS NOT NULL)) THEN CURRENT_DATE
            ELSE NULL::date
        END;

create or replace view public.v_overdue_deadlines with (security_invoker = on) as
SELECT id,
    due_on,
    (CURRENT_DATE - due_on) AS days_overdue,
    deadline_type,
    title,
    todoist_task_id,
        CASE
            WHEN (todoist_task_id IS NOT NULL) THEN 'check_todoist'::text
            WHEN (deadline_type = 'payment_due'::text) THEN 'passive_debit'::text
            ELSE 'escalate'::text
        END AS reconcile_rule
   FROM deadlines d
  WHERE ((status = 'open'::text) AND (due_on < CURRENT_DATE) AND ((snoozed_until IS NULL) OR (snoozed_until < CURRENT_DATE)))
  ORDER BY due_on;

create or replace view public.v_payment_exceptions with (security_invoker = on) as
WITH cov AS (
         SELECT max(bank_transactions.booked_on) AS last_booked
           FROM bank_transactions
        ), last_tx AS (
         SELECT DISTINCT ON (bank_transactions.recurring_payment_id) bank_transactions.recurring_payment_id,
            bank_transactions.booked_on,
            bank_transactions.amount
           FROM bank_transactions
          WHERE (bank_transactions.recurring_payment_id IS NOT NULL)
          ORDER BY bank_transactions.recurring_payment_id, bank_transactions.booked_on DESC
        )
 SELECT rp.id AS payment_id,
    rp.name,
    rp.vendor,
    rp.amount AS expected,
    rp.period,
    lt.booked_on AS last_seen,
    lt.amount AS last_amount,
        CASE
            WHEN (lt.recurring_payment_id IS NULL) THEN 'never_observed'::text
            WHEN (abs((lt.amount - rp.amount)) > 0.5) THEN 'amount_changed'::text
            WHEN ((rp.period = 'monthly'::text) AND (lt.booked_on < (cov.last_booked - 40))) THEN 'missing'::text
            WHEN ((rp.period = 'quarterly'::text) AND (lt.booked_on < (cov.last_booked - 100))) THEN 'missing'::text
            WHEN ((rp.period = 'annual'::text) AND (lt.booked_on < (cov.last_booked - 380))) THEN 'missing'::text
            ELSE NULL::text
        END AS exception,
        CASE
            WHEN ((lt.recurring_payment_id IS NULL) AND (COALESCE(rp.payment_method, ''::text) ~* 'paypal|card|mastercard|visa'::text)) THEN 'paid via card/PayPal, not visible as its own bank line'::text
            WHEN ((lt.recurring_payment_id IS NULL) AND (rp.contract_start > cov.last_booked)) THEN 'starts after bank data ends'::text
            ELSE NULL::text
        END AS explanation
   FROM ((recurring_payments rp
     CROSS JOIN cov)
     LEFT JOIN last_tx lt ON ((lt.recurring_payment_id = rp.id)))
  WHERE ((rp.status = 'active'::text) AND (rp.amount > (0)::numeric) AND ((lt.recurring_payment_id IS NULL) OR (abs((lt.amount - rp.amount)) > 0.5) OR ((rp.period = 'monthly'::text) AND (lt.booked_on < (cov.last_booked - 40))) OR ((rp.period = 'quarterly'::text) AND (lt.booked_on < (cov.last_booked - 100))) OR ((rp.period = 'annual'::text) AND (lt.booked_on < (cov.last_booked - 380)))));

create or replace view public.v_payment_reconciliation with (security_invoker = on) as
SELECT id AS payment_id,
    name,
    vendor,
    amount AS expected,
    period,
    monthly_equivalent,
    ( SELECT max(t.booked_on) AS max
           FROM bank_transactions t
          WHERE (t.recurring_payment_id = r.id)) AS last_seen,
    ( SELECT count(*) AS count
           FROM bank_transactions t
          WHERE ((t.recurring_payment_id = r.id) AND (t.booked_on > (CURRENT_DATE - 90)))) AS hits_90d,
        CASE
            WHEN (NOT (EXISTS ( SELECT 1
               FROM bank_transactions t
              WHERE (t.recurring_payment_id = r.id)))) THEN 'never observed'::text
            WHEN (( SELECT max(t.booked_on) AS max
               FROM bank_transactions t
              WHERE (t.recurring_payment_id = r.id)) < (CURRENT_DATE -
            CASE period
                WHEN 'monthly'::text THEN 45
                WHEN 'quarterly'::text THEN 120
                WHEN 'semiannual'::text THEN 210
                ELSE 400
            END)) THEN 'stopped'::text
            ELSE 'ok'::text
        END AS state
   FROM recurring_payments r
  WHERE (status = 'active'::text);
comment on view public.v_payment_reconciliation is 'never observed means the obligation exists on paper only. stopped means it was being paid and is not any more, which is either a cancelled contract nobody recorded or a failed direct debit.';

create or replace view public.v_purchase_rights with (security_invoker = on) as
SELECT id,
    (received_at)::date AS bought,
    COALESCE(vendor, sender_name) AS vendor,
    item,
    amount,
    currency,
    ((received_at)::date + 14) AS widerruf_until_approx,
    ((received_at + '2 years'::interval))::date AS gewaehrleistung_until,
        CASE
            WHEN (CURRENT_DATE <= ((received_at)::date + 14)) THEN 'return_possible'::text
            WHEN (CURRENT_DATE <= ((received_at + '2 years'::interval))::date) THEN 'warranty'::text
            ELSE 'expired'::text
        END AS state,
    gmail_url
   FROM emails e
  WHERE ((category = 'purchases'::text) AND (amount >= (50)::numeric) AND (COALESCE(vendor, sender_name, ''::text) !~* 'wolt|lieferando|uber eats|flink|getir'::text) AND (received_at > (now() - '2 years'::interval)))
  ORDER BY received_at DESC;

create or replace view public.v_renewal_watch with (security_invoker = on) as
SELECT id,
    name,
    vendor,
    amount,
    period,
    monthly_equivalent,
    contract_end,
    notice_period_months,
    ((contract_end - ((notice_period_months || ' months'::text))::interval))::date AS cancel_by,
    (((contract_end - ((notice_period_months || ' months'::text))::interval))::date - CURRENT_DATE) AS days_left,
    (deadline_id IS NOT NULL) AS deadline_recorded
   FROM recurring_payments r
  WHERE ((status = 'active'::text) AND auto_renews AND (contract_end IS NOT NULL) AND (notice_period_months IS NOT NULL))
  ORDER BY (((contract_end - ((notice_period_months || ' months'::text))::interval))::date);
comment on view public.v_renewal_watch is 'Contracts that renew themselves unless cancelled, with the real date: contract_end minus the notice period. deadline_recorded false means the date exists only here and nothing will remind you.';

create or replace view public.v_stale_status with (security_invoker = on) as
SELECT id,
    name,
    document_type,
    subject_person,
    expiry_date,
    status
   FROM documents
  WHERE ((expiry_date IS NOT NULL) AND (expiry_date < CURRENT_DATE) AND (status = 'current'::text) AND (duplicate_of IS NULL));
comment on view public.v_stale_status is 'Documents whose expiry has passed but which are still marked current. Should always be empty right after an intake run.';

create or replace view public.v_sweepable_staging with (security_invoker = on) as
SELECT id,
    gmail_message_id,
    filename,
    drive_file_id,
    drive_url,
    mime_type,
    size_bytes,
    saved_at,
    claimed,
    claimed_at,
    resolved_at,
    resolution,
    heal_count,
    last_verified_at
   FROM attachment_staging s
  WHERE ((NOT claimed) AND (saved_at < (now() - '30 days'::interval)) AND (NOT (EXISTS ( SELECT 1
           FROM documents d
          WHERE (d.drive_file_id = s.drive_file_id)))) AND ((resolution = ANY (ARRAY['out_of_scope'::text, 'drive_file_missing'::text, 'superseded'::text])) OR (NOT (EXISTS ( SELECT 1
           FROM emails e
          WHERE ((e.gmail_message_id = s.gmail_message_id) AND bridge_in_scope(e.category)))))));

create or replace view public.v_untyped_documents with (security_invoker = on) as
SELECT id,
    name,
    document_type,
    kind,
    (added_at)::date AS added_at
   FROM documents
  WHERE (document_type_key IS NULL)
  ORDER BY ((added_at)::date) DESC;
comment on view public.v_untyped_documents is 'Documents whose free-text type matched no registry key. Should be empty; anything here is either a classification miss or a genuine gap in the registry worth a proposal.';

create or replace view public.v_text_extraction_queue with (security_invoker = on) as
SELECT d.id,
    d.name,
    d.document_type_key,
    d.mime_type,
    d.drive_url,
    COALESCE(t.extraction_status, 'pending'::text) AS status,
    t.extraction_error
   FROM (documents d
     LEFT JOIN document_texts t ON ((t.document_id = d.id)))
  WHERE ((d.duplicate_of IS NULL) AND ((t.document_id IS NULL) OR (t.extraction_status = ANY (ARRAY['pending'::text, 'failed'::text]))))
  ORDER BY
        CASE d.document_type_key
            WHEN 'official_decision'::text THEN 0
            WHEN 'purchase_contract'::text THEN 1
            WHEN 'insurance_policy'::text THEN 1
            WHEN 'mortgage_contract'::text THEN 1
            WHEN 'residence_permit_temporary'::text THEN 1
            WHEN 'notary_letter'::text THEN 2
            ELSE 5
        END, d.added_at DESC;
comment on view public.v_text_extraction_queue is 'Documents with no usable full text yet, highest-value types first. Extraction is incremental and idempotent: work the queue in batches, never re-extract a done row unless the Drive file changed.';

create or replace view public.v_system_health with (security_invoker = on) as
SELECT ( SELECT count(*) AS count
           FROM documents
          WHERE (documents.kind = 'document'::text)) AS docs_formal,
    ( SELECT count(*) AS count
           FROM v_untyped_documents) AS docs_untyped,
    ( SELECT count(*) AS count
           FROM v_missing_expiry) AS docs_missing_expected_expiry,
    ( SELECT count(*) AS count
           FROM v_missing_notice_period) AS contracts_missing_notice_period,
    round(((100.0 * (( SELECT count(*) AS count
           FROM document_texts
          WHERE (document_texts.extraction_status = 'done'::text)))::numeric) / (NULLIF(( SELECT count(*) AS count
           FROM documents
          WHERE (documents.duplicate_of IS NULL)), 0))::numeric), 1) AS text_coverage_pct,
    ( SELECT count(*) AS count
           FROM v_text_extraction_queue) AS text_queue,
    ( SELECT count(*) AS count
           FROM documents
          WHERE ((documents.expiry_date < CURRENT_DATE) AND (documents.status = 'current'::text))) AS docs_expired_still_current,
    round(((100.0 * (( SELECT count(*) AS count
           FROM emails
          WHERE ((emails.category = 'bills_payments'::text) AND (emails.amount IS NOT NULL))))::numeric) / (NULLIF(( SELECT count(*) AS count
           FROM emails
          WHERE (emails.category = 'bills_payments'::text)), 0))::numeric), 1) AS bills_amount_extraction_pct,
    ( SELECT count(*) AS count
           FROM emails
          WHERE (emails.action_needed AND (emails.todoist_task_id IS NULL))) AS emails_action_no_task,
    ( SELECT count(*) AS count
           FROM v_attachment_backlog) AS attachment_backlog,
    ( SELECT count(*) AS count
           FROM deadlines
          WHERE (deadlines.status = 'open'::text)) AS deadlines_open,
    ( SELECT count(*) AS count
           FROM v_deadlines_due
          WHERE (v_deadlines_due.todoist_task_id IS NULL)) AS deadlines_no_task,
    ( SELECT count(*) AS count
           FROM v_deadlines_missed
          WHERE v_deadlines_missed.hard) AS hard_deadlines_missed,
    ( SELECT round(sum(recurring_payments.monthly_equivalent), 2) AS round
           FROM recurring_payments
          WHERE (recurring_payments.status = 'active'::text)) AS monthly_committed,
    ( SELECT count(*) AS count
           FROM v_renewal_watch
          WHERE (NOT v_renewal_watch.deadline_recorded)) AS renewals_unwatched,
    ( SELECT count(*) AS count
           FROM v_bundle_summary
          WHERE ((v_bundle_summary.status = 'open'::text) AND (v_bundle_summary.blocking > 0))) AS bundles_blocked,
    ( SELECT count(*) AS count
           FROM briefings
          WHERE ((briefings.briefing_date > (CURRENT_DATE - 7)) AND briefings.sent)) AS briefings_sent_7d,
    ( SELECT count(*) AS count
           FROM corrections
          WHERE (corrections.corrected_at > (now() - '30 days'::interval))) AS corrections_30d,
    ( SELECT count(*) AS count
           FROM improvement_proposals
          WHERE (improvement_proposals.status = 'open'::text)) AS open_proposals,
    ( SELECT count(*) AS count
           FROM v_intake_watchdog
          WHERE v_intake_watchdog.overdue) AS intakes_overdue,
    ( SELECT v_intake_watchdog.runs_7d
           FROM v_intake_watchdog
          WHERE (v_intake_watchdog.skill = 'email-intake'::text)) AS email_runs_7d,
    ( SELECT round((EXTRACT(epoch FROM (now() - max(backup_snapshots.taken_at))) / 3600.0), 1) AS round
           FROM backup_snapshots) AS hours_since_snapshot,
    ( SELECT round((EXTRACT(epoch FROM (now() - max(backups.run_at))) / 86400.0), 1) AS round
           FROM backups) AS days_since_offsite_backup,
    ( SELECT round(((100.0 * (sum(recall_samples.missed))::numeric) / (NULLIF(sum(recall_samples.sample_size), 0))::numeric), 1) AS round
           FROM recall_samples
          WHERE (recall_samples.checked_at > (now() - '60 days'::interval))) AS recall_miss_pct_60d,
    (( SELECT COALESCE(sum(jsonb_array_length(processing_runs.errors)), (0)::bigint) AS "coalesce"
           FROM processing_runs
          WHERE (processing_runs.run_at > (now() - '35 days'::interval))) + ( SELECT COALESCE(sum(jsonb_array_length(email_processing_runs.errors)), (0)::bigint) AS "coalesce"
           FROM email_processing_runs
          WHERE (email_processing_runs.run_at > (now() - '35 days'::interval)))) AS errors_35d;

create or replace view public.v_system_invariants with (security_invoker = on) as
SELECT invariant,
    severity,
    failing,
    meaning
   FROM ( VALUES ('hard_deadline_unguarded'::text,'high'::text,( SELECT count(*) AS count
                   FROM v_hard_deadline_guard),'Hard deadline overdue or <30 days without a Todoist task'::text), ('legal_decision_without_date'::text,'high'::text,( SELECT count(*) AS count
                   FROM documents d
                  WHERE ((d.document_type_key = ANY (ARRAY['official_decision'::text, 'tax_assessment'::text])) AND (d.issued_on IS NULL) AND (d.source_email_id IS NULL) AND (d.duplicate_of IS NULL) AND (d.status = 'current'::text) AND (d.added_at > (now() - '120 days'::interval)))),'Bescheid without issued_on, so no Widerspruch/Einspruch deadline could be derived'::text), ('intake_overdue'::text,'high'::text,( SELECT count(*) AS count
                   FROM v_intake_watchdog
                  WHERE v_intake_watchdog.overdue),'A scheduled skill or the bridge did not run'::text), ('attachment_backlog'::text,'high'::text,( SELECT count(*) AS count
                   FROM v_attachment_backlog),'In-scope mail the bridge has not copied'::text), ('payment_exceptions'::text,'medium'::text,( SELECT count(*) AS count
                   FROM v_payment_exceptions
                  WHERE (v_payment_exceptions.exception = ANY (ARRAY['amount_changed'::text, 'missing'::text]))),'Contract and bank disagree'::text), ('bank_data_stale'::text,'medium'::text,( SELECT
                        CASE
                            WHEN (min(v_bank_coverage.days_stale) > 40) THEN 1
                            ELSE 0
                        END AS "case"
                   FROM v_bank_coverage),'Latest bank statement older than 40 days'::text), ('invoices_unmatched'::text,'medium'::text,( SELECT count(*) AS count
                   FROM v_invoice_reconciliation
                  WHERE (v_invoice_reconciliation.period_covered AND (v_invoice_reconciliation.matched_tx IS NULL))),'Billed amount with no matching debit'::text), ('bundles_blocked'::text,'medium'::text,( SELECT count(*) AS count
                   FROM v_bundle_summary
                  WHERE ((v_bundle_summary.status = 'open'::text) AND (v_bundle_summary.blocking > 0) AND (v_bundle_summary.due_on IS NOT NULL) AND (v_bundle_summary.due_on <= (CURRENT_DATE + 60)))),'Bundle due within 60 days missing a required document'::text), ('stale_status'::text,'medium'::text,( SELECT count(*) AS count
                   FROM v_stale_status),'Expired documents still marked current'::text), ('exit_unknown'::text,'low'::text,( SELECT count(*) AS count
                   FROM v_notice_calendar
                  WHERE (NOT v_notice_calendar.exit_known)),'Obligations with no known Kündigungsfrist'::text), ('address_outdated'::text,'low'::text,( SELECT count(*) AS count
                   FROM v_address_audit),'Counterparties still writing to a former address'::text), ('untyped_documents'::text,'low'::text,( SELECT count(*) AS count
                   FROM v_untyped_documents),'Documents outside the registry'::text)) v(invariant, severity, failing, meaning);

create or replace view public.v_tax_items with (security_invoker = on) as
WITH y AS (
         SELECT ((life_settings.value #>> '{}'::text[]))::integer AS yr
           FROM life_settings
          WHERE (life_settings.key = 'tax_year'::text)
        )
 SELECT tax_relevance,
    name,
    vendor,
    amount,
    period,
    ( SELECT round(sum(t.amount), 2) AS round
           FROM bank_transactions t,
            y
          WHERE ((t.recurring_payment_id = rp.id) AND (EXTRACT(year FROM t.booked_on) = (y.yr)::numeric))) AS paid_per_bank,
    round((monthly_equivalent * (12)::numeric), 2) AS annual_estimate,
        CASE tax_relevance
            WHEN 'vorsorge_basisrente'::text THEN 'Anlage Vorsorgeaufwand, Basisrente (Bescheinigung vom Anbieter)'::text
            WHEN 'vorsorge_sonstige'::text THEN 'Anlage Vorsorgeaufwand, sonstige (Haftpflicht/Unfall-Anteil)'::text
            WHEN 'werbungskosten_candidate'::text THEN 'Anlage N, Werbungskosten, nur beruflicher Anteil'::text
            WHEN '35a_candidate'::text THEN 'Anlage Haushaltsnahe Aufwendungen, aus Hausgeld-Jahresabrechnung'::text
            ELSE NULL::text
        END AS where_it_goes
   FROM recurring_payments rp
  WHERE ((status = 'active'::text) AND (tax_relevance IS NOT NULL) AND (tax_relevance <> 'none'::text))
  ORDER BY tax_relevance, name;

create or replace view public.v_unresolved_entities with (security_invoker = on) as
SELECT 'email sender'::text AS source,
    emails.sender_email AS value,
    count(*) AS n
   FROM emails
  WHERE ((emails.sender_entity_id IS NULL) AND (emails.sender_email IS NOT NULL))
  GROUP BY emails.sender_email
UNION ALL
 SELECT 'document issuer'::text AS source,
    documents.issuer AS value,
    count(*) AS n
   FROM documents
  WHERE ((documents.issuer_entity_id IS NULL) AND (documents.issuer IS NOT NULL))
  GROUP BY documents.issuer
  ORDER BY 3 DESC;
comment on view public.v_unresolved_entities is 'Strings that should be entities but are not yet. The monthly review promotes the frequent ones and leaves one-offs alone.';

