-- Region pack de: federal authorities and the broadcasting fee, as entities and as
-- deterministic email rules. Idempotent: safe to run again. Local authorities
-- (Ausländerbehörde, Bürgeramt, your Finanzamt's own address) differ per city; the
-- setup skill asks for them and adds rows the same way.

insert into public.entities (kind, name, domains, role)
select v.kind, v.name, v.domains, 'authority'
from (values
  ('authority',    'Finanzamt (ELSTER)',                       array['elster.de']),
  ('authority',    'Bundeszentralamt für Steuern',             array['bzst.de','bzst.bund.de']),
  ('authority',    'Deutsche Rentenversicherung',              array['drv-bund.de','deutsche-rentenversicherung.de']),
  ('authority',    'Bundesagentur für Arbeit / Familienkasse', array['arbeitsagentur.de']),
  ('authority',    'Kraftfahrt-Bundesamt',                     array['kba.de']),
  ('organization', 'ARD ZDF Deutschlandradio Beitragsservice', array['rundfunkbeitrag.de','beitragsservice.de'])
) v(kind, name, domains)
where not exists (select 1 from public.entities e where e.name = v.name);

insert into public.entity_aliases (alias, entity_id)
select lower(d), e.id
from public.entities e, unnest(e.domains) d
where e.name in ('Finanzamt (ELSTER)', 'Bundeszentralamt für Steuern', 'Deutsche Rentenversicherung',
                 'Bundesagentur für Arbeit / Familienkasse', 'Kraftfahrt-Bundesamt',
                 'ARD ZDF Deutschlandradio Beitragsservice')
on conflict (alias) do nothing;

insert into public.classification_rules (scope, priority, match_field, match_op, match_value, set_category, set_entity_id, notes)
select 'email', 50, 'sender_domain', 'domain', v.domain, v.category,
       (select id from public.entities e where e.name = v.entity limit 1),
       'region pack de'
from (values
  ('elster.de',                      'government',     'Finanzamt (ELSTER)'),
  ('bzst.de',                        'government',     'Bundeszentralamt für Steuern'),
  ('drv-bund.de',                    'government',     'Deutsche Rentenversicherung'),
  ('deutsche-rentenversicherung.de', 'government',     'Deutsche Rentenversicherung'),
  ('arbeitsagentur.de',              'government',     'Bundesagentur für Arbeit / Familienkasse'),
  ('kba.de',                         'government',     'Kraftfahrt-Bundesamt'),
  ('rundfunkbeitrag.de',             'bills_payments', 'ARD ZDF Deutschlandradio Beitragsservice'),
  ('beitragsservice.de',             'bills_payments', 'ARD ZDF Deutschlandradio Beitragsservice')
) v(domain, category, entity)
where not exists (select 1 from public.classification_rules r
                  where r.scope = 'email' and r.match_field = 'sender_domain' and r.match_value = v.domain);
