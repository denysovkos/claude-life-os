-- 0006: settings the language and region packs are written into.
--
-- lang_hints    {"<locale>": {"keywords": {...}, "formats": {...}}} for every input locale,
--               copied from packs/lang/<locale>/ by the setup skill. Hints for intake.
-- region_rules  packs/region/<code>/rules.json as is: term rules, annual dates, facts.
--
-- Both default to empty, which is a valid state: intake then reads with judgement alone
-- and deadlines use the ladders written into the skills.

insert into public.life_settings (key, value) values
  ('lang_hints',   '{}'),
  ('region_rules', '{}')
on conflict (key) do nothing;

update public.life_settings set value = '"0.2.0"', updated_at = now()
where key = 'schema_version' and value = '"0.1.0"';
