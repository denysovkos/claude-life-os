-- 0013: the watchdog notices drifting schedules, snapshots cover the settings.
--
-- * life_settings.schedule_slots holds each night job's expected start (local time) and
--   schedule_drift_hours the tolerance. v_schedule_drift reports how far the last start
--   was from its slot: a job that still runs but hours away from its slot (which is how a
--   scheduler outage starts) is visible before it misses a night. v_intake_watchdog is
--   unchanged.
-- * take_snapshot() also captures life_settings, so a bad settings write can be undone
--   from the same snapshot as the data.
-- * New settings get defaults only where the key is missing; existing values are kept.

-- 1. Defaults for the new settings -------------------------------------------------------

select set_config('app.actor', 'setup', true);
insert into public.life_settings (key, value) values
  ('schedule_slots', '{"email-intake": "01:05", "drive-file-intake": "02:05", "nightly-check": "03:05"}'::jsonb),
  ('schedule_drift_hours', '3'::jsonb),
  ('area_aliases', '{}'::jsonb)
on conflict (key) do nothing;

-- 2. Slot drift ----------------------------------------------------------------------------

create or replace function public.slot_drift_hours(p_ts timestamptz, p_slot text)
returns numeric language plpgsql stable set search_path to 'public' as $$
declare local_t time; slot_t time; diff numeric;
begin
  if p_ts is null or p_slot is null or p_slot !~ '^\d{1,2}:\d{2}$' then return null; end if;
  local_t := (p_ts at time zone setting_text('timezone', 'UTC'))::time;
  slot_t := p_slot::time;
  diff := abs(extract(epoch from (local_t - slot_t))) / 3600.0;
  return round(least(diff, 24 - diff), 1);       -- circular: 23:50 vs 00:10 is 0.3 h
end $$;
revoke execute on function public.slot_drift_hours(timestamptz, text) from anon, authenticated, public;

create or replace view public.v_schedule_drift with (security_invoker = on) as
with w(skill, last_start) as (
  select 'email-intake'::text,
         (select coalesce(started_at, run_at) from email_processing_runs order by run_at desc limit 1)
  union all
  select 'drive-file-intake',
         (select coalesce(started_at, run_at) from processing_runs order by run_at desc limit 1)
  union all
  select 'nightly-check', (select max(generated_at) from briefings)
)
select w.skill,
       setting('schedule_slots') ->> w.skill as slot,
       w.last_start,
       slot_drift_hours(w.last_start, setting('schedule_slots') ->> w.skill) as drift_hours,
       coalesce(slot_drift_hours(w.last_start, setting('schedule_slots') ->> w.skill)
                > coalesce((setting('schedule_drift_hours') #>> '{}')::numeric, 3), false) as drifted
from w;
comment on view public.v_schedule_drift is 'How far each night job''s last start was from its slot (life_settings.schedule_slots, local time). drifted: more than schedule_drift_hours away. A job that still runs but hours late is how a scheduler outage starts; v_intake_watchdog only speaks once a run is missed.';

-- 3. Snapshots include the settings ----------------------------------------------------

create or replace function public.take_snapshot(p_reason text default null::text)
returns table(snapshot_id uuid, taken timestamptz, counts jsonb)
language plpgsql security definer set search_path to 'public' as $function$
declare
  v_id uuid;
  v_counts jsonb;
begin
  v_counts := jsonb_build_object(
    'documents', (select count(*) from documents),
    'emails', (select count(*) from emails),
    'deadlines', (select count(*) from deadlines),
    'corrections', (select count(*) from corrections),
    'improvement_proposals', (select count(*) from improvement_proposals),
    'skill_revisions', (select count(*) from skill_revisions),
    'life_settings', (select count(*) from life_settings));

  insert into backup_snapshots (reason, row_counts, payload)
  values (
    p_reason,
    v_counts,
    jsonb_build_object(
      'documents', (select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) from documents d),
      'emails', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from emails e),
      'deadlines', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from deadlines x),
      'corrections', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from corrections c),
      'improvement_proposals', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from improvement_proposals p),
      'skill_revisions', (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from skill_revisions r),
      'life_settings', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from life_settings s)))
  returning id into v_id;

  -- keep the last 12 snapshots, they are cheap but not free
  delete from backup_snapshots
  where id in (select id from backup_snapshots order by taken_at desc offset 12);

  return query select v_id, now(), v_counts;
end;
$function$;

-- Verification:
--   select (counts ? 'life_settings') from take_snapshot('verify 0013');                -- true
--   select skill, slot, drift_hours, drifted from v_schedule_drift;                     -- slots filled
--   select slot_drift_hours('2026-10-14 23:50+00', '01:05');                            -- tz dependent, small
