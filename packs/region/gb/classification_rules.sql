-- Region pack gb: authority entities, their domain aliases and email rules.
-- Idempotent: safe to run again. Generated from rules.json "authorities"; only
-- senders whose domain is known go here, everything else is classified by judgement.

insert into public.entities (kind, name, domains, role)
select v.kind, v.name, v.domains, 'authority'
from (values
  ('authority', 'GOV.UK Notify (government services)', array['notifications.service.gov.uk'])
) v(kind, name, domains)
where not exists (select 1 from public.entities e where e.name = v.name);

insert into public.entity_aliases (alias, entity_id)
select lower(d), e.id
from public.entities e, unnest(e.domains) d
where e.name in ('GOV.UK Notify (government services)')
on conflict (alias) do nothing;

insert into public.classification_rules (scope, priority, match_field, match_op, match_value, set_category, set_entity_id, notes)
select 'email', 50, 'sender_domain', 'domain', v.domain, v.category,
       (select id from public.entities e where e.name = v.entity limit 1),
       'region pack gb'
from (values
  ('notifications.service.gov.uk', 'government', 'GOV.UK Notify (government services)')
) v(domain, category, entity)
where not exists (select 1 from public.classification_rules r
                  where r.scope = 'email' and r.match_field = 'sender_domain' and r.match_value = v.domain);
