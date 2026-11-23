create role service_role nologin bypassrls;
create role anon nologin;
create role authenticated nologin;
-- Imita o mínimo do Supabase para rodar as migrations num Postgres puro (só para os testes).
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
-- pg_net, como vem no Supabase: o schema net aberto a PUBLIC (S-143; a migration da caixa de notas fecha)
create schema net;
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}', headers jsonb default '{}',
                              timeout_milliseconds int default 5000) returns bigint language sql as $$ select 1::bigint $$;
create function net.http_get(url text, params jsonb default '{}', headers jsonb default '{}', timeout_milliseconds int default 5000)
  returns bigint language sql as $$ select 1::bigint $$;
grant usage on schema net to public;
