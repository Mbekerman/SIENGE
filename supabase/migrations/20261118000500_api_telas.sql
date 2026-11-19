-- Esquema `api`: a porta do front do ERP (Moises, 18/11/2026: "vamos pelas telas de Lançar título, previsões e
-- contratos recorrentes. e consultar").
--
-- 1. O `erp` continua fora da API do Supabase (Exposed schemas). O front só enxerga o esquema `api`, com funções
--    finas, cada uma devolvendo só as colunas que a tela usa. Nada de tabela nem visão exposta: a lista do que o
--    navegador alcança é a lista de funções deste arquivo.
-- 2. Toda função do `api` é SECURITY INVOKER: roda com o login e o RLS de quem chama. A tela vê exatamente o que a
--    pessoa já veria no `erp` (perfil núcleo × centro × divisão × natureza, natureza restrita como a folha PJ,
--    quem aprova o título), sem regra de acesso no navegador nem aqui. Gravação, quando vier, passa pelos
--    gatilhos e políticas do `erp`, numa transação só.
-- 3. Duas conferências do `erp` respondem sobre qualquer id e por isso não têm EXECUTE para a API (S-126):
--    erp.previsao_aprovada e erp.compromisso_aprovado. As telas usam as versões "_vista" daqui, definer do
--    erp_conferencia, que só respondem se a pessoa vê a previsão ou o contrato (senão, nulo).
-- 4. Ninguém além de `authenticated` executa: nem anon, nem service_role, nem public.
-- Portabilidade: SQL puro; `authenticated` é o papel do usuário logado no PostgREST.

-- ---------------------------------------------------------------------------------------------
-- Conferências que só respondem sobre o que a pessoa vê
-- ---------------------------------------------------------------------------------------------
create function erp.previsao_aprovada_vista(p_id uuid) returns boolean language sql stable
security definer set search_path = erp, pg_catalog, pg_temp as
  $$ select case when erp.vejo_previsao(p_id) then erp.previsao_aprovada(p_id) end $$;
alter function erp.previsao_aprovada_vista(uuid) owner to erp_conferencia;

create function erp.contrato_aprovado_visto(p_id uuid) returns boolean language sql stable
security definer set search_path = erp, pg_catalog, pg_temp as
  $$ select case when erp.vejo_compromisso(p_id) then erp.compromisso_aprovado(p_id) end $$;
alter function erp.contrato_aprovado_visto(uuid) owner to erp_conferencia;

-- O caminho da divisão até o último nível ("Online › Mídia paga › Google"); só o nome, que todo membro lê.
create function erp.caminho_divisao(p_id uuid) returns text language sql stable as $$
  with recursive c as (
    select d.id, d.mae_id, d.nome::text as caminho from erp.divisoes d where d.id = p_id
    union all
    select m.id, m.mae_id, m.nome || ' › ' || c.caminho from erp.divisoes m join c on m.id = c.mae_id)
  select caminho from c where mae_id is null $$;

-- "Marketing › Online › Google": o centro e, se houver, a divisão do último nível da linha
create function erp.area_linha(p_centro uuid, p_divisao uuid, p_subdivisao uuid) returns text language sql stable as $$
  select c.nome || coalesce(' › ' || erp.caminho_divisao(coalesce(p_subdivisao, p_divisao)), '')
    from erp.centros_custo c where c.id = p_centro $$;

-- ---------------------------------------------------------------------------------------------
-- O esquema da API
-- ---------------------------------------------------------------------------------------------
create schema api;
revoke all on schema api from public;

-- Quem está usando: nulo para quem entrou mas não tem cadastro ativo no ERP (a tela diz isso).
create function api.eu() returns jsonb language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object(
           'id', u.id, 'nome', u.nome, 'papel', u.papel, 'administrador', u.administrador,
           'master', erp.sou_master(), 'escreve', erp.escrevo(),
           'listas', coalesce((select jsonb_agg(l.lista order by l.lista) from erp.listas_financeiro l where l.user_id = u.id), '[]'::jsonb))
    from erp.usuarios u
   where u.id = erp.eu() and erp.membro() $$;

-- Etapa do título na vida dele, na ordem em que a pessoa acompanha: rascunho, aprovação (ou recusado, ou em
-- revisão), aprovado esperando o Sienge, no Sienge, pago; cancelado à parte.
create function erp.etapa_titulo(p_id uuid) returns text language sql stable as $$
  select case
    when t.situacao = 'cancelado' then 'cancelado'
    when t.situacao = 'quitado' then 'pago'
    when t.situacao = 'rascunho' then 'rascunho'
    when erp.em_revisao(t.id) then 'revisao'
    when erp.alcada_recusada(t.id) then 'recusado'
    when erp.alcada_fase(t.id) is not null then 'aprovacao'
    when e.situacao = 'enviado' then 'sienge'
    when e.situacao in ('erro', 'manual') then 'erro_sienge'
    else 'aprovado' end
    from erp.titulos t left join erp.sienge_envios e on e.titulo_id = t.id
   where t.id = p_id $$;

-- Títulos a pagar que a pessoa vê (o RLS do erp decide quais).
create function api.titulos()
returns table (id uuid, tipo text, etapa text, fornecedor text, fornecedor_documento text, documento text, numero text,
               emissao date, competencia date, valor numeric, vencimento date, parcelas int, areas text, empresa text,
               lancado_por text, lancado_em timestamptz, aprovacao_pendente text, sienge_id int, meu boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select t.id, t.tipo, erp.etapa_titulo(t.id), p.nome, p.documento,
         case when d.id is not null then
           (case d.tipo when 'nfse' then 'NFS-e' when 'nfe' then 'NF-e' when 'fatura' then 'Fatura' when 'boleto' then 'Boleto'
                        when 'guia' then 'Guia' when 'recibo' then 'Recibo' else 'Documento' end) || ' ' || d.numero end,
         t.numero, t.emissao, t.competencia, t.valor,
         coalesce((select min(pa.vencimento) from erp.parcelas pa where pa.titulo_id = t.id and erp.parcela_saldo(pa.id) > 0),
                  (select max(pa.vencimento) from erp.parcelas pa where pa.titulo_id = t.id)),
         (select count(*)::int from erp.parcelas pa where pa.titulo_id = t.id),
         (select string_agg(distinct erp.area_linha(r.centro_custo_id, r.divisao_id, r.subdivisao_id), ', ')
            from erp.titulo_rateios r where r.titulo_id = t.id),
         (select pe.nome from erp.empresas em join erp.pessoas pe on pe.id = em.pessoa_id where em.id = t.empresa_id),
         (select u.nome from erp.usuarios u where u.id = t.criado_por), t.criado_em,
         erp.alcada_pendente(t.id), e.sienge_id, t.criado_por = erp.eu()
    from erp.titulos t
    join erp.pessoas p on p.id = t.pessoa_id
    left join erp.documentos_fiscais d on d.id = t.documento_id
    left join erp.sienge_envios e on e.titulo_id = t.id
   where t.sentido = 'pagar' $$;

-- O título aberto na gaveta: cabeçalho, parcelas com a forma de pagamento, rateio, aprovações, etiquetas e
-- previsões consumidas. Nulo quando a pessoa não vê o título.
create function api.titulo(p_id uuid) returns jsonb language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select to_jsonb(c) || jsonb_build_object(
    'descricao', t.descricao,
    'nota', (select jsonb_build_object('tipo', d.tipo, 'numero', d.numero, 'serie', d.serie, 'emissao', d.emissao,
                                       'valor_bruto', d.valor_bruto, 'caucao', d.caucao_valor,
                                       'retencoes', coalesce((select jsonb_agg(jsonb_build_object('imposto', x.imposto, 'valor', x.valor,
                                                            'vencimento', x.vencimento) order by x.imposto)
                                                     from erp.documento_retencoes x where x.documento_id = d.id), '[]'::jsonb))
               from erp.documentos_fiscais d where d.id = t.documento_id),
    'parcelas', coalesce((select jsonb_agg(jsonb_build_object(
                   'numero', pa.numero, 'vencimento', pa.vencimento, 'valor', pa.valor, 'saldo', erp.parcela_saldo(pa.id),
                   'forma', f.forma, 'pix_tipo', f.pix_tipo, 'pix_chave', f.pix_chave, 'boleto_linha', f.boleto_linha,
                   'pix_excecao', f.pix_excecao) order by pa.numero)
                 from erp.parcelas pa left join erp.parcela_pagamentos f on f.titulo_id = pa.titulo_id and f.numero = pa.numero
                where pa.titulo_id = t.id), '[]'::jsonb),
    'rateio', coalesce((select jsonb_agg(jsonb_build_object(
                   'nucleo', n.nome, 'area', erp.area_linha(r.centro_custo_id, r.divisao_id, r.subdivisao_id),
                   'natureza', vn.caminho, 'percentual', r.percentual, 'valor', round(t.valor * r.percentual / 100, 2))
                   order by r.percentual desc, vn.caminho)
                 from erp.titulo_rateios r left join erp.nucleos_economicos n on n.id = r.nucleo_economico_id
                 left join erp.v_naturezas vn on vn.id = r.natureza_id
                where r.titulo_id = t.id), '[]'::jsonb),
    'aprovacoes', coalesce((select jsonb_agg(jsonb_build_object(
                   'area', erp.area_linha(v.centro_custo_id, v.divisao_id, null), 'lista', v.lista, 'aprovado', v.aprovado,
                   'justificativa', v.justificativa, 'por', (select u.nome from erp.usuarios u where u.id = v.por), 'em', v.em)
                   order by v.em)
                 from erp.titulo_aprovacoes v where v.titulo_id = t.id and v.rodada = t.rodada), '[]'::jsonb),
    'etiquetas', coalesce((select jsonb_agg(g.nome order by g.nome) from erp.titulo_etiquetas te
                             join erp.etiquetas g on g.id = te.etiqueta_id where te.titulo_id = t.id), '[]'::jsonb),
    'previsoes', coalesce((select jsonb_agg(jsonb_build_object('id', tp.previsao_id, 'valor', tp.valor,
                             'data_prevista', pr.data_prevista) order by pr.data_prevista)
                 from erp.titulo_previsoes tp join erp.previsoes pr on pr.id = tp.previsao_id where tp.titulo_id = t.id), '[]'::jsonb),
    'sienge_erro', (select e.erro from erp.sienge_envios e where e.titulo_id = t.id))
    from api.titulos() c join erp.titulos t on t.id = c.id
   where c.id = p_id $$;

-- Previsões a pagar que a pessoa vê.
create function api.previsoes()
returns table (id uuid, origem text, situacao text, aprovacao text, fornecedor text, natureza text, area text, nucleo text,
               empresa text, competencia date, data_prevista date, valor numeric, saldo numeric, descricao text,
               contrato_id uuid, contrato text, sienge_id int, lancado_por text, meu boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select p.id, p.origem, p.situacao,
         case when p.situacao = 'cancelada' then 'cancelada'
              when erp.previsao_aprovada_vista(p.id) then 'aprovada' else 'esperando' end,
         pe.nome, vn.caminho, erp.area_linha(p.centro_custo_id, p.divisao_id, p.subdivisao_id), n.nome,
         (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = p.empresa_id),
         p.competencia, p.data_prevista, p.valor, erp.previsao_saldo(p.id), p.descricao,
         p.compromisso_id, c.descricao, s.sienge_id,
         (select u.nome from erp.usuarios u where u.id = p.criada_por), p.criada_por = erp.eu()
    from erp.previsoes p
    left join erp.pessoas pe on pe.id = p.pessoa_id
    left join erp.v_naturezas vn on vn.id = p.natureza_id
    left join erp.nucleos_economicos n on n.id = p.nucleo_economico_id
    left join erp.compromissos c on c.id = p.compromisso_id
    left join erp.sienge_previsoes s on s.previsao_id = p.id
   where p.sentido = 'pagar' $$;

-- Contas recorrentes (contrato de serviço e assinatura) que a pessoa vê.
create function api.contratos()
returns table (id uuid, tipo text, situacao text, aprovado boolean, fornecedor text, numero text, descricao text,
               inicio date, fim date, periodicidade text, valor_periodo numeric, valor_total numeric, dia_vencimento int,
               areas text, naturezas text, empresa text, previsoes_abertas int, lancado_por text, meu boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select c.id, c.tipo, c.situacao, erp.contrato_aprovado_visto(c.id), pe.nome, c.numero, c.descricao,
         c.inicio, c.fim, c.periodicidade, c.valor_periodo, c.valor_total, c.dia_vencimento,
         (select string_agg(distinct erp.area_linha(r.centro_custo_id, r.divisao_id, r.subdivisao_id), ', ')
            from erp.compromisso_rateios r where r.compromisso_id = c.id),
         (select string_agg(distinct vn.nome, ', ') from erp.compromisso_rateios r join erp.v_naturezas vn on vn.id = r.natureza_id
           where r.compromisso_id = c.id),
         (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = c.empresa_id),
         (select count(*)::int from erp.previsoes p where p.compromisso_id = c.id and p.situacao = 'aberta'),
         (select u.nome from erp.usuarios u where u.id = c.criado_por), c.criado_por = erp.eu()
    from erp.compromissos c
    left join erp.pessoas pe on pe.id = c.pessoa_id
   where c.tipo in ('contrato', 'assinatura') $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa; as definer daqui, só pela API e pelo banco
-- ---------------------------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'api'
               or (n.nspname = 'erp' and p.proname in ('previsao_aprovada_vista', 'contrato_aprovado_visto', 'caminho_divisao',
                                                        'area_linha', 'etapa_titulo')) loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema api from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'revoke all on schema api from service_role'; end if;
end $$;
grant usage on schema api to authenticated;
grant execute on function erp.caminho_divisao(uuid), erp.area_linha(uuid, uuid, uuid), erp.etapa_titulo(uuid)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
