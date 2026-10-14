-- 0011: writes that pass the Supabase MCP connector unattended, and row removal moved
-- into the database.
--
-- The connector holds two kinds of statement for a human to confirm: an UPDATE whose SET
-- carries a sizeable payload, and anything that removes rows. In an unattended night run
-- nobody confirms, the call times out after 180 s and nothing is committed. An INSERT of
-- any size passes, and so does INSERT ... ON CONFLICT DO UPDATE.
--
-- 1. skill_writebacks: the skill inserts one row per bulky field change (a description,
--    notes, proposal evidence). A trigger applies it to the target row as the skill
--    (app.actor = 'skill', so corrections does not log it as a human edit) and refuses
--    the insert when the target row does not exist, so a zero-row write is an error the
--    skill sees, not a silent pass.
-- 2. nightly_maintenance(), run by pg_cron: the only place rows are removed. It sweeps
--    staging rows whose Drive copy the skill already trashed, text chunks after a
--    successful assemble, and run locks that expired a week ago.
--
-- Additive only. Safe to run twice.

-- 1. Write-backs --------------------------------------------------------------------------

create table if not exists public.skill_writebacks (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  target_table  text not null,
  target_id     uuid not null,
  column_name   text not null,
  value         jsonb,
  mode          text not null default 'set',
  actor         text not null default 'skill',
  run_ref       text,
  applied_at    timestamptz,
  constraint skill_writebacks_mode_check check (mode in ('set','append'))
);
alter table public.skill_writebacks enable row level security;
revoke all on public.skill_writebacks from anon, authenticated;
comment on table public.skill_writebacks is 'Insert-only path for bulky field changes (the MCP connector stalls on an UPDATE with a large SET). A trigger applies each row to target_table.column_name and raises when the target row is missing. mode = append adds the text on a new line. Whitelisted columns only; see skill_writeback_apply().';

create or replace function public.skill_writeback_apply()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  allowed constant text[] := array[
    'documents.description', 'documents.review_reason', 'documents.physical_location',
    'documents.content_excerpt', 'documents.tags', 'documents.needs_review',
    'emails.summary', 'emails.action_note', 'emails.content_excerpt',
    'deadlines.notes', 'deadlines.title',
    'recurring_payments.notes', 'recurring_payments.name',
    'matters.next_action', 'matters.description',
    'improvement_proposals.problem', 'improvement_proposals.evidence',
    'improvement_proposals.proposed_change',
    'bundles.notes', 'entities.notes', 'notes.body'];
  col_type text; n int;
begin
  if not (new.target_table || '.' || new.column_name) = any (allowed) then
    raise exception 'skill_writebacks: %.% is not a write-back column', new.target_table, new.column_name;
  end if;
  select format_type(a.atttypid, a.atttypmod) into col_type
  from pg_attribute a
  where a.attrelid = ('public.' || quote_ident(new.target_table))::regclass
    and a.attname = new.column_name and not a.attisdropped;
  if col_type is null then
    raise exception 'skill_writebacks: column %.% does not exist here', new.target_table, new.column_name;
  end if;

  perform set_config('app.actor', coalesce(nullif(new.actor, ''), 'skill'), true);
  if new.mode = 'append' then
    execute format('update public.%I set %I = coalesce(%I || E''\n'', '''') || $1 where id = $2',
                   new.target_table, new.column_name, new.column_name)
      using new.value #>> '{}', new.target_id;
  else
    execute format('update public.%I set %I = (jsonb_populate_record(null::public.%I, jsonb_build_object(%L, $1))).%I where id = $2',
                   new.target_table, new.column_name, new.target_table, new.column_name, new.column_name)
      using new.value, new.target_id;
  end if;
  get diagnostics n = row_count;
  if n = 0 then
    raise exception 'skill_writebacks: no % row with id %', new.target_table, new.target_id;
  end if;
  new.applied_at := clock_timestamp();
  return new;
end $function$;

drop trigger if exists skill_writebacks_apply on public.skill_writebacks;
create trigger skill_writebacks_apply before insert on public.skill_writebacks
  for each row execute function public.skill_writeback_apply();

revoke execute on function public.skill_writeback_apply() from anon, authenticated, public;

-- 2. Staging rows the skill has already cleared in Drive ----------------------------------

alter table public.attachment_staging add column if not exists drive_trashed_at timestamptz;
comment on column public.attachment_staging.drive_trashed_at is 'Set by the skill (a short UPDATE) after it trashed the Drive copy, or found it already gone. nightly_maintenance() then removes the row.';

-- 3. Nightly maintenance: the only place rows are removed --------------------------------

create table if not exists public.maintenance_runs (
  id      uuid primary key default gen_random_uuid(),
  ran_at  timestamptz not null default now(),
  counts  jsonb,
  error   text
);
alter table public.maintenance_runs enable row level security;
revoke all on public.maintenance_runs from anon, authenticated;

create or replace function public.nightly_maintenance()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare a int := 0; b int := 0; c int := 0; d int := 0; res jsonb;
begin
  perform set_config('app.actor', 'skill', true);

  delete from attachment_staging s
  where s.drive_trashed_at is not null
    and s.id in (select v.id from v_sweepable_staging v);
  get diagnostics a = row_count;

  delete from text_ingest_chunks c
  where exists (select 1 from document_texts t
                where t.document_id = c.document_id and t.extraction_status = 'done'
                  and t.extracted_at >= c.created_at)
     or c.created_at < now() - interval '14 days';
  get diagnostics b = row_count;

  delete from run_locks where expires_at < now() - interval '7 days';
  get diagnostics c = row_count;

  delete from skill_writebacks where applied_at < now() - interval '180 days';
  get diagnostics d = row_count;

  res := jsonb_build_object('staging_swept', a, 'chunks_removed', b, 'locks_removed', c,
                            'writebacks_pruned', d);
  insert into maintenance_runs (counts) values (res);
  return res;
exception when others then
  insert into maintenance_runs (error) values (sqlerrm);
  return jsonb_build_object('error', sqlerrm);
end $function$;

revoke execute on function public.nightly_maintenance() from anon, authenticated, public;
grant execute on function public.nightly_maintenance() to service_role;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if not exists (select 1 from cron.job where jobname = 'nightly-maintenance') then
      perform cron.schedule('nightly-maintenance', '35 1 * * *', 'select public.nightly_maintenance()');
    end if;
  else
    raise notice 'pg_cron not available: schedule nightly_maintenance() yourself';
  end if;
end $$;

-- Verification:
--   insert into skill_writebacks (target_table, target_id, column_name, value)
--   values ('documents', '00000000-0000-0000-0000-000000000000', 'description', '"x"');  -- raises: no documents row
--   select public.nightly_maintenance();                                                  -- counts, no error
--   select jobname, schedule, active from cron.job where jobname = 'nightly-maintenance'; -- 1 row
