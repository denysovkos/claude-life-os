-- 0009: term rules can count working days.
--
-- Some countries count legal periods in working days (Ukraine: ten working days to
-- contest a tax assessment; Portugal: administrative complaints in dias úteis). The
-- step {"add_business_days": n} adds n Monday-to-Friday days. Public holidays are
-- regional and stay in each rule's notes, exactly like the weekend roll.
-- Same semantics as tests/test_packs.py; tests/sql_rules_check.py proves they agree.

create or replace function public.apply_term_rule(p_rule jsonb, p_start date,
                                                  p_actual_receipt boolean default false)
returns date language plpgsql immutable set search_path to 'public' as $$
-- p_actual_receipt: the start is the real day of receipt (an email), so the
-- notification_offset_days fiction for posted letters does not apply.
declare d date := p_start; s jsonb; t date; left_days int;
begin
  if p_rule is null or p_start is null then return null; end if;
  if not p_actual_receipt then
    d := d + coalesce((p_rule->>'notification_offset_days')::int, 0);
  end if;
  for s in select * from jsonb_array_elements(coalesce(p_rule->'steps', '[]'::jsonb)) loop
    if s ? 'add_days' then
      d := d + (s->>'add_days')::int;
    elsif s ? 'add_months' then
      d := (d + make_interval(months => (s->>'add_months')::int))::date;
    elsif s ? 'term_months' then
      -- a term ends the day before the corresponding day, or on the last day of the
      -- month when there is no corresponding day
      t := (d + make_interval(months => (s->>'term_months')::int))::date;
      d := case when extract(day from t) < extract(day from d) then t else t - 1 end;
    elsif s ? 'add_business_days' then
      left_days := (s->>'add_business_days')::int;
      while left_days > 0 loop
        d := d + 1;
        if extract(isodow from d) < 6 then left_days := left_days - 1; end if;
      end loop;
    elsif s ? 'end_of_month' then
      d := (date_trunc('month', d) + interval '1 month - 1 day')::date;
    else
      raise exception 'apply_term_rule: unknown step %', s;
    end if;
  end loop;
  if coalesce((p_rule->>'roll_to_business_day')::boolean, false) then
    while extract(isodow from d) >= 6 loop d := d + 1; end loop;
  end if;
  return d;
end $$;

revoke execute on function public.apply_term_rule(jsonb, date, boolean) from anon, authenticated, public;
grant execute on function public.apply_term_rule(jsonb, date, boolean) to service_role;

update public.life_settings set value = '"0.5.0"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"');
