create role service_role nologin bypassrls;
create role anon nologin;
create role authenticated nologin;
-- Imita o mínimo do Supabase para rodar as migrations num Postgres puro (só para os testes).
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
