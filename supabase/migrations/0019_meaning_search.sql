-- 0019: search by meaning, in any language, and documents like this one.
--
-- ask_documents() matches the words of one query in one language: "pets" never finds a
-- lease that says "Tierhaltung", and "Kündigung" misses "Kündigungsfrist". Embeddings
-- would help, but the only model Supabase runs inside the project (gte-small) reads
-- English only, and any other one means sending the documents to an outside service,
-- which this system never does. So the meaning comes from where it already is: the
-- model asking. It passes the question as several terms (synonyms, the words a contract
-- or an authority would use, translations into the languages the papers are in), and
-- the database ranks everything against all of them at once:
--
-- 1. find_documents(terms): documents, mail and notes, each with the terms it matched,
--    a quotable snippet and its link. A word of five letters or more also matches its
--    longer forms (kündigung finds kündigungsfrist); a word ending in * always does
--    (догов* finds договір and договору).
-- 2. similar_documents(document): other documents by shared rare words, the same
--    issuer, type and household member, each with the reasons.
--
-- Functions only: no table, no view, no data changes. Safe to run twice.

create or replace function public.search_terms_query(p_terms text[])
returns tsquery language sql immutable set search_path to 'public' as $$
  -- each term is a phrase whose words must all occur; the terms are alternatives
  select to_tsquery('simple', string_agg('(' || q || ')', ' | '))
  from (
    select string_agg(case when star or length(w) >= 5 then w || ':*' else w end, ' & ') as q
    from (select t.ord, x.raw like '%*' as star,
                 lower(regexp_replace(x.raw, '[^[:alnum:]]', '', 'g')) as w
          from unnest(p_terms) with ordinality t(term, ord),
               regexp_split_to_table(coalesce(t.term, ''), '\s+') x(raw)) words
    where length(w) >= 2
    group by ord
  ) per_term
  where q is not null
$$;

create or replace function public.find_documents(p_terms text[], p_limit integer default 10)
returns table(kind text, id uuid, title text, url text, person text, document_type text,
              dated date, score real, matched_terms text[], snippet text)
language sql stable security definer set search_path to 'public' as $function$
  with q as (select search_terms_query(p_terms) as tq),
  terms as (select t.term, search_terms_query(array[t.term]) as tq
            from unnest(p_terms) t(term) where search_terms_query(array[t.term]) is not null),
  docs as (
    select 'document'::text as kind, d.id, d.name as title, d.drive_url as url,
           coalesce(hm.name, nullif(btrim(d.subject_person), '')) as person, dt.label as document_type,
           coalesce(d.issued_on, d.added_at::date) as dated,
           coalesce(t.tsv, ''::tsvector) || to_tsvector('simple', concat_ws(' ', d.name, d.description, d.issuer, d.document_type))
             as v,
           coalesce(nullif(t.body, ''), concat_ws('. ', d.description, d.content_excerpt), d.name) as text
    from documents d
    left join document_texts t on t.document_id = d.id
    left join document_types dt on dt.key = d.document_type_key
    left join household_members hm on hm.id = d.member_id
    where d.duplicate_of is null
    union all
    select 'email', e.id, e.subject, e.gmail_url, hm.name, e.category,
           coalesce(e.received_at::date, e.added_at::date), e.tsv,
           concat_ws('. ', e.summary, e.content_excerpt)
    from emails e left join household_members hm on hm.id = e.member_id
    union all
    select 'note', n.id, n.title, null, null, n.kind, coalesce(n.decided_on, n.created_at::date), n.tsv, n.body
    from notes n
  ),
  ranked as (
    select x.*, array(select terms.term from terms where x.v @@ terms.tq) as matched
    from docs x, q
    where q.tq is not null and x.v @@ q.tq
  )
  -- a document matching more of the terms ranks first; the snippet shows where
  select r.kind, r.id, r.title, r.url, r.person, r.document_type, r.dated,
         (ts_rank_cd(r.v, q.tq) + 0.2 * cardinality(r.matched))::real as score,
         r.matched,
         ts_headline('simple', r.text, q.tq,
                     'MaxFragments=2,MaxWords=40,MinWords=15,FragmentDelimiter= … ')
  from ranked r, q
  order by score desc, r.dated desc nulls last
  limit greatest(1, least(coalesce(p_limit, 10), 50))
$function$;

create or replace function public.similar_documents(p_document uuid, p_limit integer default 8)
returns table(id uuid, title text, url text, document_type text, issuer text, dated date,
              score real, reasons text[], shared_terms text[])
language sql stable security definer set search_path to 'public' as $function$
  with src as (
    select d.*, coalesce(t.tsv, ''::tsvector) || to_tsvector('simple', concat_ws(' ', d.name, d.description, d.issuer)) as v
    from documents d left join document_texts t on t.document_id = d.id
    where d.id = p_document
  ),
  corpus as (select count(*)::real as n from document_texts where tsv is not null),
  -- the source's words that are frequent in it and rare elsewhere
  words as (
    select u.lexeme as w, coalesce(array_length(u.positions, 1), 1) as tf
    from src, unnest(src.v) u
    where length(u.lexeme) >= 5 and u.lexeme !~ '^[0-9]+$'
    order by 2 desc, length(u.lexeme) desc limit 40
  ),
  weighted as (
    select w.w, w.tf * ln((corpus.n + 1) / (1 + (select count(*) from document_texts t
                                                  where t.tsv @@ to_tsquery('simple', quote_literal(w.w))))) as weight
    from words w, corpus
  ),
  key_words as (select * from weighted where weight > 0 order by weight desc limit 15),
  cand as (
    select d.id, d.name, d.drive_url, dt.label, d.issuer, coalesce(d.issued_on, d.added_at::date) as dated,
           array(select k.w from key_words k
                 where coalesce(t.tsv, ''::tsvector) || to_tsvector('simple', concat_ws(' ', d.name, d.description, d.issuer))
                       @@ to_tsquery('simple', quote_literal(k.w))
                 order by k.weight desc) as shared,
           (d.issuer_entity_id is not null and d.issuer_entity_id = src.issuer_entity_id)
             or (d.issuer_entity_id is null and lower(btrim(d.issuer)) = lower(btrim(src.issuer))) as same_issuer,
           d.document_type_key = src.document_type_key as same_type,
           d.member_id is not null and d.member_id = src.member_id as same_person
    from documents d
    join src on d.id <> src.id
    left join document_texts t on t.document_id = d.id
    left join document_types dt on dt.key = d.document_type_key
    where d.duplicate_of is null and d.id is distinct from src.duplicate_of
  )
  select c.id, c.name, c.drive_url, c.label, c.issuer, c.dated,
         ((select coalesce(sum(k.weight), 0) from key_words k where k.w = any (c.shared))
          / greatest((select sum(weight) from key_words), 1)
          + case when c.same_issuer then 0.5 else 0 end
          + case when c.same_type then 0.3 else 0 end
          + case when c.same_person then 0.2 else 0 end)::real as score,
         array_remove(array[case when c.same_issuer then 'same issuer' end,
                            case when c.same_type then 'same type' end,
                            case when c.same_person then 'same person' end,
                            case when cardinality(c.shared) > 0 then cardinality(c.shared) || ' shared terms' end], null),
         c.shared[1:8]
  from cand c
  where cardinality(c.shared) > 0 or c.same_issuer or c.same_type
  order by score desc, c.dated desc nulls last
  limit greatest(1, least(coalesce(p_limit, 8), 50))
$function$;

revoke execute on function public.search_terms_query(text[]), public.find_documents(text[], integer),
  public.similar_documents(uuid, integer) from anon, authenticated, public, service_role;

update public.life_settings set value = '"0.10.0"', updated_at = now()
where key = 'schema_version'
  and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"', '"0.7.0"', '"0.8.0"', '"0.9.0"');

-- Verification:
--   select value from life_settings where key = 'schema_version';                     -- "0.10.0"
--   select search_terms_query(array['Kündigung', 'pets', 'догов*']);                  -- 'kündigung':* | 'pets' | 'догов':*
--   select kind, title, matched_terms from find_documents(array['Kündigung', 'cancel'], 5);
