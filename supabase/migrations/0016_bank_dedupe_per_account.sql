-- 0016: bank transaction dedupe per account.
--
-- bank_transactions_dedupe_idx was (booked_on, amount, direction, reference): two
-- accounts with an identical booking and an empty reference on the same day silently
-- lost one row. The new index adds the account (IBAN, or a masked card number for card
-- statements). It is strictly looser than the old one, so building it cannot fail.
--
-- This is its own migration because it drops an index: a life-review run of skill 4.1 or
-- older may name the old index's columns as its ON CONFLICT target. Apply it after the
-- v3.2 skill is installed (the doctor offers it then: schema 0.6.0 -> 0.6.1). The v3.2
-- life-review inserts with a target-less "on conflict do nothing".

create unique index if not exists bank_transactions_dedupe_acct_idx
  on public.bank_transactions (coalesce(account_iban, ''), booked_on, amount, direction, coalesce(reference, ''));
drop index if exists public.bank_transactions_dedupe_idx;
comment on column public.bank_transactions.account_iban is 'The account key: an IBAN, or for card statements a masked card number (CARD-<scheme>-<masked>). Part of the dedupe index.';

update public.life_settings set value = '"0.6.1"', updated_at = now()
where key = 'schema_version' and value in ('"0.1.0"', '"0.2.0"', '"0.3.0"', '"0.4.0"', '"0.5.0"', '"0.6.0"');

-- Verification:
--   select indexname from pg_indexes where tablename = 'bank_transactions' and indexname like '%dedupe%';  -- only bank_transactions_dedupe_acct_idx
--   select value from life_settings where key = 'schema_version';                                          -- "0.6.1"
