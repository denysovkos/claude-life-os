-- Runs once when the test database is created. PostgREST logs in as authenticator,
-- as Supabase's API does, and switches to anon or service_role from the JWT.
alter role authenticator with password 'authpass';
