-- Segurança do esquema `erp` (S-003, S-033 e S-034; aval do Moises em 14/11/2026).
--
-- 1. Papéis nossos, sem login e sem membros aqui:
--    - erp_sistema: rotina do servidor (adaptador do Sienge, funções do servidor). Quem recebe
--      esse papel é decidido na implantação; sem login (erp.login_atual() nulo) ele é sistema.
--    - erp_conferencia: dono das funções de conferência (security definer). Só lê, e só por
--      dentro dessas funções; ninguém entra com ele.
-- 2. RLS ligado e forçado em toda tabela, negando por padrão. Políticas:
--    - sistema: tudo, só quando erp.sistema();
--    - conferencia: só SELECT, só para o papel erp_conferencia.
--    As políticas por perfil (núcleo econômico × centro de custo × natureza, com PJ isolado)
--    entram junto com o primeiro grant a `authenticated`, no mesmo PR.
-- 3. As conferências que as travas usam passam a security definer, donas erp_conferencia, com
--    search_path fixo: assim a trava enxerga o que quem lança não vê (adiantamento de outro
--    núcleo, quitações, listas, regra). Recebem só ids; nenhuma escolhe empresa nem usuário.
-- Superusuário ignora RLS mesmo forçado; por isso o dono das funções não é o superusuário.
-- Portabilidade: SQL puro, sem extensão nem papel do Supabase.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'erp_sistema') then
    create role erp_sistema nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'erp_conferencia') then
    create role erp_conferencia nologin;
  end if;
end $$;

grant usage on schema erp to erp_sistema, erp_conferencia;
grant select, insert, update, delete on all tables in schema erp to erp_sistema;
grant execute on all functions in schema erp to erp_sistema;
grant select on all tables in schema erp to erp_conferencia;
grant execute on all functions in schema erp to erp_conferencia;

do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'erp' and c.relkind in ('r', 'p') loop
    execute format('alter table erp.%I enable row level security', t.relname);
    execute format('alter table erp.%I force row level security', t.relname);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t.relname);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t.relname);
  end loop;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'erp.eu()', 'erp.meu_usuario()', 'erp.meu_papel()',
    'erp.exigir_admin()', 'erp.exigir_editor()', 'erp.exigir_diretor()',
    'erp.estou_nas_listas(text[])', 'erp.regra_adiantamento_atual()',
    'erp.autor_lancamento(text, uuid)', 'erp.abatimento_aprovado(uuid, uuid)',
    'erp.adiantamento_anterior_em_aberto(uuid, uuid)',
    'erp.previsao_saldo(uuid)', 'erp.parcela_saldo(uuid)', 'erp.pagamento_saldo(uuid)',
    'erp.centro_ligado(uuid, uuid)'] loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog', f);
    execute format('alter function %s owner to erp_conferencia', f);
  end loop;
end $$;
