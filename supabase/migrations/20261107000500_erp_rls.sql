-- Segurança do esquema `erp` (S-003, S-033, S-034 e S-035; aval do Moises em 14/11/2026).
--
-- 1. Papéis nossos, sem login e sem membros aqui:
--    - erp_sistema: rotina do servidor (adaptador do Sienge, funções do servidor). Quem recebe
--      esse papel é decidido na implantação; sem login (erp.login_atual() nulo) ele é sistema.
--      Nenhum papel da API (anon, authenticated, authenticator, service_role) é membro dele.
--    - erp_conferencia: dono das funções de conferência (security definer). Só lê, e só por
--      dentro dessas funções.
--    - erp_auditoria (S-052): dono só do erp.tg_auditoria; só insere na auditoria, que ninguém
--      altera nem apaga.
--    - erp_acesso (S-078): dono das funções do pedido de mudança de acesso; só ele (e o sistema)
--      grava nas tabelas de acesso.
--    - erp_situacao e erp_reclassificacao (S-035): donos das operações que mudam o que o
--      cliente não muda direto: a situação de título e previsão (confirmar, quitar, consumir) e
--      a natureza já lançada (reclassificação aprovada). As travas conferem
--      erp.agindo_como(papel), isto é, se o código roda dentro dessas funções. Nenhum desses
--      papéis entra ou tem membros, então ninguém de fora põe a marca (antes eram variáveis de
--      sessão que qualquer SET ligava).
-- 2. RLS ligado e forçado em toda tabela, negando por padrão. Políticas:
--    - sistema: tudo, só quando erp.sistema();
--    - conferencia: só SELECT, só para erp_conferencia;
--    - operacao: tudo, só para erp_situacao e erp_reclassificacao.
--    As políticas por perfil (núcleo econômico × centro de custo × natureza, com PJ isolado)
--    entram junto com o primeiro grant a `authenticated`, no mesmo PR. Quando entrarem, as
--    operações (confirmar_titulo, decidir_reclassificacao, as quitações) conferem por conta
--    própria se quem chama vê o registro, porque por dentro elas enxergam tudo.
-- 3. Conferências das travas em security definer, donas erp_conferencia, search_path fixo:
--    a trava enxerga o que quem lança não vê. Recebem só ids; nenhuma escolhe empresa nem usuário.
-- Superusuário ignora RLS mesmo forçado; por isso o dono das funções não é o superusuário.
-- Implantação: ALTER FUNCTION ... OWNER exige poder agir como o novo dono e CREATE no esquema;
-- sem superusuário, conferir no projeto antes de aplicar.
-- Portabilidade: SQL puro, sem extensão nem papel do Supabase.

do $$
declare p text;
begin
  foreach p in array array['erp_sistema', 'erp_conferencia', 'erp_situacao', 'erp_reclassificacao', 'erp_auditoria', 'erp_acesso'] loop
    if not exists (select 1 from pg_roles where rolname = p) then
      execute format('create role %I nologin', p);
    end if;
  end loop;
end $$;

grant usage on schema erp to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
grant select, insert, update, delete on all tables in schema erp to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso;
grant execute on all functions in schema erp to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso;
grant select on all tables in schema erp to erp_conferencia;
grant execute on all functions in schema erp to erp_conferencia;
-- erp_auditoria (S-052): dono só do erp.tg_auditoria; só insere na auditoria.
grant usage on schema erp to erp_auditoria;
grant insert on erp.auditoria to erp_auditoria;
grant execute on function erp.eu(), erp.agindo_como(text) to erp_auditoria;

do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'erp' and c.relkind in ('r', 'p') loop
    execute format('alter table erp.%I enable row level security', t.relname);
    execute format('alter table erp.%I force row level security', t.relname);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t.relname);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t.relname);
    execute format('create policy operacao on erp.%I to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true)', t.relname);
    -- nenhuma tabela se apaga por TRUNCATE (o TRUNCATE passa por cima dos gatilhos de linha)
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t.relname);
  end loop;
end $$;
create policy auditoria_grava on erp.auditoria for insert to erp_auditoria with check (true);

do $$
declare r record;
begin
  for r in select * from (values
    ('erp.eu()', 'erp_conferencia'), ('erp.meu_usuario()', 'erp_conferencia'), ('erp.meu_papel()', 'erp_conferencia'),
    ('erp.exigir_editor()', 'erp_conferencia'), ('erp.exigir_diretor()', 'erp_conferencia'),
    ('erp.estou_nas_listas(text[])', 'erp_conferencia'), ('erp.regra_adiantamento_atual()', 'erp_conferencia'),
    ('erp.autor_lancamento(text, uuid)', 'erp_conferencia'), ('erp.abatimento_aprovado(uuid, uuid)', 'erp_conferencia'),
    ('erp.adiantamento_anterior_em_aberto(uuid, uuid)', 'erp_conferencia'),
    ('erp._previsao_saldo(uuid)', 'erp_conferencia'), ('erp._parcela_saldo(uuid)', 'erp_conferencia'),
    ('erp._pagamento_saldo(uuid)', 'erp_conferencia'), ('erp.centro_ligado(uuid, uuid)', 'erp_conferencia'),
    ('erp.checar_natureza(uuid, uuid, uuid, boolean)', 'erp_conferencia'), ('erp.checar_centro(uuid, uuid, uuid)', 'erp_conferencia'),
    ('erp.tg_nucleo_economico()', 'erp_conferencia'),
    -- operações que mudam situação (S-035)
    ('erp.confirmar_titulo(uuid)', 'erp_situacao'), ('erp._confirmar_titulo(uuid)', 'erp_situacao'), ('erp.tg_quitacao()', 'erp_situacao'),
    ('erp.tg_titulo_previsao()', 'erp_situacao'),
    -- reclassificação aprovada (S-035); os votos também são lidos por baixo do RLS
    ('erp.decidir_reclassificacao(uuid, boolean, text)', 'erp_reclassificacao'),
    ('erp.pedir_reclassificacao(uuid, uuid, text, jsonb, boolean)', 'erp_reclassificacao'),
    ('erp.cancelar_reclassificacao(uuid)', 'erp_reclassificacao'),
    -- lançar a nota muda a situação dela (S-036)
    ('erp.lancar_documento(uuid, date[], uuid[])', 'erp_situacao'),
    -- quem escreve no livro e na caução (S-051, S-052)
    ('erp.tg_previsao()', 'erp_situacao'), ('erp.tg_pagamento()', 'erp_situacao'),
    ('erp.liberar_caucao(uuid, numeric, date, uuid, text)', 'erp_situacao'),
    ('erp.publicar_orcamento(uuid)', 'erp_situacao'),
    -- alçada de pagamento: decidir grava a etapa; as conferências leem por baixo do RLS
    ('erp.decidir_titulo(uuid, boolean, text, boolean, uuid)', 'erp_situacao'),
    ('erp.reenviar_titulo(uuid, text, date[], uuid[])', 'erp_situacao'),
    ('erp.em_revisao(uuid)', 'erp_conferencia'), ('erp.pode_ajustar(uuid)', 'erp_conferencia'),
    ('erp._ajustavel(uuid)', 'erp_conferencia'), ('erp._nota_ajustavel(uuid)', 'erp_conferencia'),
    ('erp._titulo_em_revisao_da_nota(uuid)', 'erp_conferencia'), ('erp.cadeia_titulo(uuid)', 'erp_conferencia'),
    ('erp._registrar_ajuste(uuid, text, jsonb, jsonb)', 'erp_situacao'),
    ('erp.conferir_ajuste(uuid, text, jsonb, jsonb)', 'erp_conferencia'),
    ('erp.alcada_etapa(uuid)', 'erp_conferencia'), ('erp.alcada_pendente(uuid)', 'erp_conferencia'),
    ('erp.alcada_recusada(uuid)', 'erp_conferencia'), ('erp.titulos_do_acumulado(uuid)', 'erp_conferencia'),
    ('erp.checar_competencia(text, uuid, date, date)', 'erp_conferencia'),
    ('erp.tg_adiantamento_sem_pedido()', 'erp_conferencia'),
    -- movimento entre sócios cria os títulos ligados (S-057)
    ('erp.registrar_movimento_societario(text, uuid, uuid, numeric, date, text)', 'erp_situacao'),
    -- fechar e reabrir o mês (S-053)
    ('erp.fechar_mes(uuid, date)', 'erp_situacao'), ('erp.reabrir_mes(uuid, date)', 'erp_situacao'),
    -- mudança de acesso com aprovação (S-078)
    ('erp.pedir_mudanca_acesso(text, text, jsonb, text)', 'erp_acesso'),
    ('erp.decidir_mudanca_acesso(uuid, boolean, text)', 'erp_acesso'),
    ('erp.cancelar_mudanca_acesso(uuid)', 'erp_acesso'), ('erp._aplicar_mudanca_acesso(uuid)', 'erp_acesso'),
    ('erp.passar_master(uuid, text)', 'erp_acesso'), ('erp.pedir_sucessao_master(uuid, text)', 'erp_acesso'),
    ('erp.decidir_sucessao_master(uuid, boolean, text)', 'erp_acesso'), ('erp.vetar_sucessao_master(uuid)', 'erp_acesso'),
    ('erp.efetivar_sucessao_master(uuid)', 'erp_acesso'), ('erp.sou_master()', 'erp_conferencia'),
    ('erp.gerar_avisos_sucessao()', 'erp_acesso'), ('erp._sucessao_unanime(uuid)', 'erp_acesso'), ('erp.vetar_sucessao_por_link(text)', 'erp_acesso'), ('erp.registrar_envio_aviso(uuid, date, text, text, text)', 'erp_acesso'),
    ('erp.recusar_so_sucessao(uuid)', 'erp_conferencia'), ('erp.recusar_admin_aprovador(uuid)', 'erp_conferencia'), ('erp._beneficiarios_acesso(text, jsonb, jsonb)', 'erp_conferencia'),
    -- quem escreve na auditoria (S-052)
    ('erp.tg_auditoria()', 'erp_auditoria')) v(f, dono) loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', r.f);
    execute format('alter function %s owner to %I', r.f, r.dono);
  end loop;
end $$;

-- Daqui em diante, só o erp.tg_auditoria (definer erp_auditoria) escreve na auditoria (S-052).
create trigger t_auditoria_guarda before insert or update or delete on erp.auditoria
  for each row execute function erp.tg_auditoria_guarda();
