-- Imita o mínimo do Supabase para rodar as migrations num Postgres puro (só para os testes).
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
