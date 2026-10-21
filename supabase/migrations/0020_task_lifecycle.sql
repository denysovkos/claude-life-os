-- 0020: the system closes the tasks it opened.
--
-- Until now every workflow knew how to create its task and none knew when to close it.
-- A daily brief is due today and stays open forever after; a monthly review is replaced
-- by the next one and both stay open; a failure task outlives the outage it reported;
-- a letter withdrawn in chat or a deadline closed by the database keeps its task. After
-- a month the system project holds thirty tasks nobody will ever complete, and the few
-- that need the person drown in them.
--
-- 1. system_tasks: every brief, review and failure task the system opened, with when
--    and why it was closed. The tasks that mirror a row (a deadline, a mail, a document,
--    a letter, a proposal) keep their id on that row and get task_closed_at instead.
-- 2. v_tasks_to_close: open tasks whose reason to exist is gone: a brief of an earlier
--    day, a review a newer one replaced, a failure of a job that has run clean since,
--    and tasks of rows that are done, cancelled, sent, withdrawn, superseded or no
--    longer need action. The nightly check completes them in the task app and records it.
-- 3. mark_task_closed(task id, reason): records that a task is closed, wherever it is
--    referenced. Also used when the person completed a task and a workflow noticed.
--
-- The briefs already on record are registered here, so the first nightly check after
-- the upgrade closes the backlog of old briefs. Additive: one table, five columns, one
-- view, one function. Safe to run twice.

create table if not exists public.system_tasks (
  id              uuid default gen_random_uuid() not null,
  kind            text not null,
  ref             text,
  todoist_task_id text not null,
  title           text,
  created_at      timestamptz default now() not null,
  closed_at       timestamptz,
  close_reason    text,
  constraint system_tasks_kind_check check (kind in ('brief','review','failure')),
  constraint system_tasks_pkey primary key (id),
  constraint system_tasks_task_key unique (todoist_task_id)
);
create index if not exists system_tasks_open_idx on public.system_tasks (kind, ref) where closed_at is null;
alter table public.system_tasks enable row level security;
revoke all on public.system_tasks from anon, authenticated, service_role;
comment on table public.system_tasks is 'Tasks the system opened that mirror no row: the daily brief (ref = its date), the monthly review (ref = its month) and failure notices (ref = the failing workflow). Registered when created, closed by the nightly check through v_tasks_to_close.';

alter table public.deadlines            add column if not exists task_closed_at timestamptz;
alter table public.emails               add column if not exists task_closed_at timestamptz;
alter table public.documents            add column if not exists task_closed_at timestamptz;
alter table public.letters              add column if not exists task_closed_at timestamptz;
alter table public.improvement_proposals add column if not exists task_closed_at timestamptz;
comment on column public.deadlines.task_closed_at is 'When the task in todoist_task_id was completed, by the person or by the nightly check. Null with a task id means the task is still open.';

-- briefs delivered as tasks before this migration
insert into public.system_tasks (kind, ref, todoist_task_id, title, created_at)
select 'brief', b.briefing_date::text, b.todoist_task_id, 'Daily brief ' || b.briefing_date, b.generated_at
from public.briefings b
where b.todoist_task_id is not null and b.todoist_task_id not like 'pending:%'
on conflict (todoist_task_id) do nothing;

create or replace view public.v_tasks_to_close with (security_invoker = on) as
select 'brief'::text as source, t.id::text as row_id, t.todoist_task_id, t.title,
       'the brief of ' || coalesce(t.ref, t.created_at::date::text) || ' was replaced by a newer one' as reason,
       t.created_at as since
from system_tasks t
where t.kind = 'brief' and t.closed_at is null and t.created_at::date < current_date
union all
select 'review', t.id::text, t.todoist_task_id, t.title,
       'replaced by the review of ' || n.ref, t.created_at
from system_tasks t
join lateral (select n.ref from system_tasks n
              where n.kind = 'review' and n.created_at > t.created_at
              order by n.created_at desc limit 1) n on true
where t.kind = 'review' and t.closed_at is null
union all
select 'failure', t.id::text, t.todoist_task_id, t.title,
       t.ref || ' has run without errors since', t.created_at
from system_tasks t
where t.kind = 'failure' and t.closed_at is null
  and case t.ref
        when 'email-intake' then exists (select 1 from email_processing_runs r
                                         where r.run_at > t.created_at and r.errors = '[]'::jsonb)
        when 'drive-file-intake' then exists (select 1 from processing_runs r
                                              where r.run_at > t.created_at and r.errors = '[]'::jsonb)
        when 'life-review' then exists (select 1 from life_review_runs r
                                        where r.ran_at > t.created_at and r.errors = '[]'::jsonb)
        when 'nightly-check' then exists (select 1 from briefings b where b.generated_at > t.created_at)
        else false
      end
union all
select 'deadline', d.id::text, d.todoist_task_id, d.title, 'the deadline is ' || d.status, d.updated_at
from deadlines d
where d.status in ('done','cancelled') and d.task_closed_at is null
  and d.todoist_task_id is not null and d.todoist_task_id not like 'pending:%'
union all
select 'email', e.id::text, e.todoist_task_id, e.subject, 'the mail no longer needs action', e.updated_at
from emails e
where not e.action_needed and e.task_closed_at is null
  and e.todoist_task_id is not null and e.todoist_task_id not like 'pending:%'
  and not exists (select 1 from deadlines d where d.todoist_task_id = e.todoist_task_id and d.status = 'open')
union all
select 'document', d.id::text, d.todoist_task_id, d.name,
       case when d.duplicate_of is not null then 'the document is a duplicate'
            when d.superseded_by is not null then 'the document was replaced by a newer one'
            else 'the document is ' || d.status end, d.updated_at
from documents d
where (d.duplicate_of is not null or d.superseded_by is not null or d.status in ('stale','to_archive'))
  and d.task_closed_at is null
  and d.todoist_task_id is not null and d.todoist_task_id not like 'pending:%'
  and not exists (select 1 from deadlines x where x.todoist_task_id = d.todoist_task_id and x.status = 'open')
union all
select 'letter', l.id::text, l.todoist_task_id, l.subject, 'the letter is ' || l.status, l.updated_at
from letters l
where l.status in ('sent','confirmed','withdrawn') and l.task_closed_at is null
  and l.todoist_task_id is not null and l.todoist_task_id not like 'pending:%'
union all
select 'proposal', p.id::text, p.todoist_task_id, p.title, 'the proposal is ' || p.status, p.decided_at
from improvement_proposals p
where p.status <> 'open' and p.task_closed_at is null
  and p.todoist_task_id is not null and p.todoist_task_id not like 'pending:%';
comment on view public.v_tasks_to_close is 'Open tasks the system created whose reason to exist is gone. The nightly check completes each in the task app (or finds it already completed or deleted) and calls mark_task_closed().';

create or replace function public.mark_task_closed(p_task_id text, p_reason text default null)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare n integer := 0; c integer;
begin
  if p_task_id is null or p_task_id like 'pending:%' then
    return 0;
  end if;
  update system_tasks set closed_at = coalesce(closed_at, now()), close_reason = coalesce(close_reason, p_reason)
  where todoist_task_id = p_task_id and closed_at is null;
  get diagnostics c = row_count; n := n + c;
  update deadlines set task_closed_at = now() where todoist_task_id = p_task_id and task_closed_at is null;
  get diagnostics c = row_count; n := n + c;
  update emails set task_closed_at = now() where todoist_task_id = p_task_id and task_closed_at is null;
  get diagnostics c = row_count; n := n + c;
  update documents set task_closed_at = now() where todoist_task_id = p_task_id and task_closed_at is null;
  get diagnostics c = row_count; n := n + c;
  update letters set task_closed_at = now() where todoist_task_id = p_task_id and task_closed_at is null;
  get diagnostics c = row_count; n := n + c;
  update improvement_proposals set task_closed_at = now() where todoist_task_id = p_task_id and task_closed_at is null;
  get diagnostics c = row_count; n := n + c;
  return n;
end
$function$;

revoke all on public.v_tasks_to_close from anon, authenticated, service_role;
revoke execute on function public.mark_task_closed(text, text) from anon, authenticated, public, service_role;

update public.life_settings set value = '"0.11.0"', updated_at = now()
where key = 'schema_version'
  and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"', '"0.7.0"', '"0.8.0"', '"0.9.0"', '"0.10.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                     -- "0.11.0"
--   select kind, count(*) filter (where closed_at is null) as open from system_tasks group by kind;
--   select source, count(*) from v_tasks_to_close group by source;                    -- old briefs right after the upgrade
--   select mark_task_closed('no-such-task', 'test');                                  -- 0
