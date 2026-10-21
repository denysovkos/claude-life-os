-- 0008: the nightly-check workflow is watched like the intakes.
--
-- The daily brief moved from email-intake to nightly-check, which runs last each night.
-- Its heartbeat is the one briefings row it writes per day (suppressed or not), so a
-- night where it did not run is visible here, in the daily brief's anomalies, and to the
-- Apps Script bridge, which emails the owner after 36 hours.

create or replace view public.v_intake_watchdog with (security_invoker = on) as
select 'email-intake'::text as skill,
       (select max(run_at) from email_processing_runs) as last_run,
       round(extract(epoch from now() - (select max(run_at) from email_processing_runs)) / 3600.0, 1) as hours_since,
       36 as sla_hours,
       ((select max(run_at) from email_processing_runs) < now() - interval '36 hours') as overdue,
       (select coalesce(sum(jsonb_array_length(errors)), 0) from email_processing_runs
         where run_at > now() - interval '7 days') as errors_7d,
       (select count(*) from email_processing_runs where run_at > now() - interval '7 days') as runs_7d,
       7 as runs_7d_expected
union all
select 'drive-file-intake',
       (select max(run_at) from processing_runs),
       round(extract(epoch from now() - (select max(run_at) from processing_runs)) / 3600.0, 1),
       30,
       ((select max(run_at) from processing_runs) < now() - interval '30 hours'),
       (select coalesce(sum(jsonb_array_length(errors)), 0) from processing_runs
         where run_at > now() - interval '7 days'),
       (select count(*) from processing_runs where run_at > now() - interval '7 days'),
       7
union all
select 'nightly-check',
       (select max(generated_at) from briefings),
       round(extract(epoch from now() - (select max(generated_at) from briefings)) / 3600.0, 1),
       36,
       ((select max(generated_at) from briefings) < now() - interval '36 hours'),
       0::bigint,
       (select count(*) from briefings where generated_at > now() - interval '7 days'),
       7
union all
select 'attachment-bridge',
       (select max(finished_at) from bridge_runs),
       round(extract(epoch from now() - (select max(finished_at) from bridge_runs)) / 3600.0, 1),
       1,
       coalesce(((select max(finished_at) from bridge_runs) < now() - interval '1 hour'), true),
       (select coalesce(sum(jsonb_array_length(errors)), 0) from bridge_runs
         where started_at > now() - interval '7 days'),
       (select count(*) from bridge_runs where started_at > now() - interval '7 days'),
       672;
comment on view public.v_intake_watchdog is 'Liveness check for the scheduled jobs: email-intake 36h, drive-file-intake 30h, nightly-check 36h (its heartbeat is the daily briefings row), attachment-bridge 1h. A job that silently stopped looks identical to a job with nothing to do, which is why runs_7d matters as much as last_run.';

update public.life_settings set value = '"0.4.0"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"');
