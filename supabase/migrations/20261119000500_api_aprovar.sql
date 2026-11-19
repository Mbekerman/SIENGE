-- Tela Para aprovar (Moises, 19/11/2026: a tela de aprovação vem antes das contas recorrentes e do leitor). Junta numa
-- lista só o que espera aprovação e a pessoa vê: títulos (uma linha por centro ou divisão da alçada), previsões
-- lançadas à mão (idem) e contratos recorrentes, cada um com "é a sua vez?".
--
-- A vez não é recalculada aqui: api.aprovacoes() SIMULA a aprovação, chamando a própria erp.decidir_titulo,
-- erp.decidir_previsao ou erp.decidir_compromisso dentro de um bloco que sempre desfaz (subtransação). Se a decisão
-- passaria, é a vez da pessoa; se não, o motivo é a mensagem que ela receberia ao clicar (quem lançou não aprova, a
-- fase é do gestor da área, já aprovou...). Assim a tela nunca diverge da regra, que mora só nas funções de decisão.
-- Nada da simulação fica gravado (aprovação, aviso, fila do Sienge, auditoria: tudo some com a subtransação), e as
-- funções de decisão não falam com nada fora do banco.
--
-- Mesma regra do esquema api: SECURITY INVOKER (cada leitura passa pelo RLS de quem chama; as decisões são as RPCs
-- definer de sempre, que conferem quem chama). Portabilidade: SQL e plpgsql padrão.

-- Nome legível de uma vaga da alçada.
create function erp.rotulo_vaga(p_vaga text) returns text language sql stable set search_path = pg_catalog, pg_temp as $$
  select case p_vaga
    when 'AREA' then 'gestor do centro' when 'DIRETOR_AREA' then 'diretor da área' when 'FIN' then 'AF ou AO'
    when 'AF' then 'AF' when 'AO' then 'AO' when 'AD' then 'AD' when 'PJ' then 'master ou designado do PJ'
    when 'MASTER' then 'master'
    else case when p_vaga like 'P:%' then coalesce((select u.nome from erp.usuarios u where u.id::text = substr(p_vaga, 3)), 'pessoa indicada')
              else p_vaga end end $$;

-- A decisão passaria? (null = sim; senão a mensagem da recusa). Sempre desfaz.
create function erp._simular_decisao(p_tipo text, p_id uuid, p_centro uuid, p_divisao uuid) returns text
language plpgsql volatile set search_path = pg_catalog, pg_temp as $$
begin
  begin
    if p_tipo = 'titulo' then perform erp.decidir_titulo(p_id, true, null, false, p_centro, p_divisao);
    elsif p_tipo = 'previsao' then perform erp.decidir_previsao(p_id, true, null, p_centro, p_divisao);
    elsif p_tipo = 'contrato' then perform erp.decidir_compromisso(p_id, true, null);
    else raise exception 'Tipo inválido';
    end if;
    raise exception using errcode = 'P0B01', message = 'simulação';
  exception
    when sqlstate 'P0B01' then return null;
    when others then return sqlerrm;
  end;
end $$;

-- O que espera aprovação e a pessoa vê. Uma linha por alçada pendente (centro ou divisão) no título e na previsão;
-- uma por contrato. `vez` diz se a pessoa decide agora; `motivo`, por que não.
create function api.aprovacoes()
returns table (tipo text, id uuid, centro_id uuid, divisao_id uuid, area text, parte numeric, valor numeric,
               fornecedor text, descricao text, data date, empresa text, lancado_por text, lancado_em timestamptz,
               esperando text, vez boolean, motivo text)
language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
declare r record; v_motivo text;
begin
  if not erp.escrevo() then return; end if;
  for r in
    -- títulos em aprovação: cada alçada da rodada atual que ainda falta aprovar
    select 'titulo'::text as tipo, t.id, a.centro_custo_id as centro_id, a.divisao_id,
           erp.area_linha(a.centro_custo_id, a.divisao_id, null) as area, a.valor_no_centro as parte, t.valor,
           pe.nome as fornecedor,
           coalesce((select case d.tipo when 'nfse' then 'NFS-e' when 'nfe' then 'NF-e' when 'fatura' then 'Fatura'
                                        when 'boleto' then 'Boleto' when 'guia' then 'Guia' when 'recibo' then 'Recibo' else 'Documento' end
                            || ' ' || d.numero from erp.documentos_fiscais d where d.id = t.documento_id), t.descricao) as descricao,
           coalesce((select min(pa.vencimento) from erp.parcelas pa where pa.titulo_id = t.id and erp.parcela_saldo(pa.id) > 0),
                    (select max(pa.vencimento) from erp.parcelas pa where pa.titulo_id = t.id)) as data,
           (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = t.empresa_id) as empresa,
           (select u.nome from erp.usuarios u where u.id = t.criado_por) as lancado_por, t.criado_em as lancado_em,
           (select string_agg(erp.rotulo_vaga(v), case when a.paralelo then ' e ' else ', depois ' end order by o)
              from unnest(a.vagas_pendentes) with ordinality x(v, o)) as esperando
      from erp.titulos t
      join erp.v_titulo_alcadas a on a.titulo_id = t.id and a.situacao = 'pendente'
      join erp.pessoas pe on pe.id = t.pessoa_id
     where t.sentido = 'pagar' and t.situacao = 'aberto' and erp.etapa_titulo(t.id) = 'aprovacao'
    union all
    -- previsões lançadas à mão: cada alçada que falta aprovar
    select 'previsao', p.id, a.centro_custo_id, a.divisao_id, erp.area_linha(a.centro_custo_id, a.divisao_id, null), a.valor, p.valor,
           (select x.nome from erp.pessoas x where x.id = p.pessoa_id),
           coalesce(p.descricao, (select vn.caminho from erp.v_naturezas vn where vn.id = p.natureza_id)),
           p.data_prevista,
           (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = p.empresa_id),
           (select u.nome from erp.usuarios u where u.id = p.criada_por), p.criada_em,
           (select string_agg(erp.rotulo_vaga(a.fases[i]), case when a.paralelo then ' e ' else ', depois ' end order by i)
              from generate_subscripts(a.fases, 1) i
             where not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado))
      from erp.previsoes p
      join erp.previsao_alcadas a on a.previsao_id = p.id
     where p.sentido = 'pagar' and p.situacao = 'aberta' and not erp.previsao_aprovada_vista(p.id)
       and not exists (select 1 from erp.previsao_aprovacoes v where v.previsao_id = p.id and not v.aprovado)
       and exists (select 1 from generate_subscripts(a.fases, 1) i
                    where not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado))
    union all
    -- contratos recorrentes ativos, na versão atual, ainda não aprovados nem recusados
    select 'contrato', c.id, null, null,
           (select string_agg(distinct erp.area_linha(cr.centro_custo_id, cr.divisao_id, cr.subdivisao_id), ', ')
              from erp.compromisso_rateios cr where cr.compromisso_id = c.id),
           null, coalesce(c.valor_periodo, c.valor_total),
           (select x.nome from erp.pessoas x where x.id = c.pessoa_id), c.descricao, c.inicio,
           (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = c.empresa_id),
           (select u.nome from erp.usuarios u where u.id = c.criado_por), c.criado_em,
           (select string_agg(case when v.vaga = 'AREA' then 'gestor de ' || (select cc.nome from erp.centros_custo cc where cc.id = v.centro_custo_id)
                                   else erp.rotulo_vaga(v.vaga) end, ' e ' order by v.vaga, v.centro_custo_id)
              from (select 'AREA'::text as vaga, r0.centro_custo_id
                      from (select distinct cr.centro_custo_id from erp.compromisso_rateios cr
                             where cr.compromisso_id = c.id and cr.centro_custo_id is not null) r0
                     where exists (select 1 from erp.centro_aprovadores ca where ca.centro_custo_id = r0.centro_custo_id)
                    union all select 'FIN', null::uuid) v   -- as vagas de erp.compromisso_vagas, que só o banco executa
             where not exists (select 1 from erp.compromisso_aprovacoes x where x.compromisso_id = c.id and x.versao = c.aprovacao_versao
                                 and x.aprovado and x.vaga = v.vaga and x.centro_custo_id is not distinct from v.centro_custo_id))
      from erp.compromissos c
     where c.tipo in ('contrato', 'assinatura') and c.situacao = 'ativo' and not erp.contrato_aprovado_visto(c.id)
       and not exists (select 1 from erp.compromisso_aprovacoes x where x.compromisso_id = c.id and x.versao = c.aprovacao_versao and not x.aprovado)
  loop
    v_motivo := erp._simular_decisao(r.tipo, r.id, r.centro_id, r.divisao_id);
    tipo := r.tipo; id := r.id; centro_id := r.centro_id; divisao_id := r.divisao_id; area := r.area; parte := r.parte;
    valor := r.valor; fornecedor := r.fornecedor; descricao := r.descricao; data := r.data; empresa := r.empresa;
    lancado_por := r.lancado_por; lancado_em := r.lancado_em; esperando := r.esperando;
    vez := v_motivo is null; motivo := v_motivo;
    return next;
  end loop;
end $$;

-- Decide (aprovar, recusar ou, no título, pedir revisão) pela RPC de sempre. p_centro e p_divisao escolhem a alçada no
-- título e na previsão com rateio (nulos = a primeira em que é a vez da pessoa). Devolve 'aprovado', 'pendente',
-- 'recusado' ou 'revisao'.
create function api.decidir(p_tipo text, p_id uuid, p_decisao text, p_justificativa text default null,
                            p_centro uuid default null, p_divisao uuid default null)
returns text language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if p_decisao not in ('aprovar', 'recusar', 'revisao') then raise exception 'Decisão inválida'; end if;
  if p_decisao = 'revisao' and p_tipo <> 'titulo' then raise exception 'Só o título volta para revisão'; end if;
  return case p_tipo
    when 'titulo' then erp.decidir_titulo(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''), p_decisao = 'revisao', p_centro, p_divisao)
    when 'previsao' then erp.decidir_previsao(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''), p_centro, p_divisao)
    when 'contrato' then erp.decidir_compromisso(p_id, p_decisao = 'aprovar', nullif(trim(p_justificativa), ''))
    else null end;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa as da api; a simulação só roda por dentro de api.aprovacoes
-- ---------------------------------------------------------------------------------------------
revoke execute on function erp.rotulo_vaga(text), erp._simular_decisao(text, uuid, uuid, uuid) from public;
grant execute on function erp.rotulo_vaga(text), erp._simular_decisao(text, uuid, uuid, uuid)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
grant execute on function erp.rotulo_vaga(text), erp._simular_decisao(text, uuid, uuid, uuid) to authenticated;
do $$
declare f regprocedure;
begin
  foreach f in array array['api.aprovacoes()', 'api.decidir(text, uuid, text, text, uuid, uuid)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
