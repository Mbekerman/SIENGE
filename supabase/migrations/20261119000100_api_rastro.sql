-- Rastro do título (pedido do Moises, 18/11/2026: "Os títulos tem que trazer toda rastreabilidade"): uma função só,
-- api.titulo_rastro, que a gaveta chama quando a pessoa abre um dos botões (Origem, Aprovações, Alterações,
-- Histórico, Anexos, Contrato, Fornecedor).
--
-- Mesma regra do esquema api (migration _api_telas): SECURITY INVOKER, então cada pedaço passa pelo RLS do erp.
-- - O título que a pessoa não vê volta nulo.
-- - O contrato, a nota, as previsões e os pagamentos aparecem só se a pessoa os vê (senão, nulos ou fora da lista).
-- - Os títulos do contrato e o histórico com o fornecedor contam só os títulos que a pessoa vê: a folha PJ e os
--   centros fora do perfil ficam de fora também dos totais.
-- - O log bruto (erp.auditoria) só o administrador lê; para os demais, o histórico se monta com o que o título já
--   guarda (lançamento, aprovações, pedidos de alteração, envio ao Sienge, pagamentos).
-- - Dados bancários do fornecedor não entram aqui: a chave PIX e o boleto ficam só na parcela, para quem pode vê-los.
-- - Anexos: ainda não há onde guardar arquivos; a lista volta vazia até a migration dos anexos.
-- Portabilidade: SQL puro.

-- Nome legível do campo mudado no ajuste da revisão
create function erp.rotulo_campo(p_tabela text, p_campo text, p_linha jsonb) returns text language sql immutable as $$
  select case p_tabela
    when 'titulos' then case p_campo when 'competencia' then 'Competência' when 'emissao' then 'Emissão' when 'valor' then 'Valor'
                                     when 'descricao' then 'Descrição' when 'numero' then 'Número' when 'pessoa_id' then 'Fornecedor' else p_campo end
    when 'parcelas' then coalesce((p_linha->>'numero') || 'ª parcela · ', 'Parcela · ')
                         || case p_campo when 'vencimento' then 'vencimento' when 'valor' then 'valor' else p_campo end
    when 'titulo_rateios' then 'Rateio · ' || case p_campo when 'percentual' then 'percentual' when 'natureza_id' then 'natureza'
                                                         when 'centro_custo_id' then 'centro' when 'divisao_id' then 'divisão'
                                                         when 'nucleo_economico_id' then 'núcleo' else p_campo end
    when 'parcela_pagamentos' then coalesce((p_linha->>'numero') || 'ª parcela · ', '') || 'forma de pagamento'
    when 'documentos_fiscais' then 'Nota · ' || p_campo
    else p_tabela || ' · ' || p_campo end $$;

create function api.titulo_rastro(p_id uuid) returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  with t as (select * from erp.titulos where id = p_id),
  nome as (select u.id, u.nome from erp.usuarios u),
  pago as (  -- o que já foi baixado de cada título visível, pela parcela (o RLS da quitação é o do título)
    select pa.titulo_id, sum(q.principal) as valor, max(pg.data) as em
      from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id left join erp.pagamentos pg on pg.id = q.pagamento_id
     group by pa.titulo_id)
  select jsonb_build_object(
    'rodada_atual', t.rodada,
    'origem', jsonb_build_object(
      'compromisso', (select jsonb_build_object('id', c.id, 'tipo', c.tipo, 'numero', c.numero, 'descricao', c.descricao,
                              'inicio', c.inicio, 'fim', c.fim, 'valor_total', c.valor_total, 'valor_periodo', c.valor_periodo,
                              'periodicidade', c.periodicidade, 'situacao', c.situacao,
                              'lancado_por', (select n.nome from nome n where n.id = c.criado_por))
                        from erp.compromissos c where c.id = t.compromisso_id),
      'nota', (select jsonb_build_object('tipo', d.tipo, 'numero', d.numero, 'serie', nullif(d.serie, ''), 'emissao', d.emissao,
                       'valor_bruto', d.valor_bruto, 'lancada_por', (select n.nome from nome n where n.id = d.criado_por),
                       'lancada_em', d.lancado_em)
                 from erp.documentos_fiscais d where d.id = t.documento_id),
      'previsoes', coalesce((select jsonb_agg(jsonb_build_object('id', p.id,
                       'sienge', (select 'PRV ' || s.sienge_id from erp.sienge_previsoes s where s.previsao_id = p.id),
                       'data_prevista', p.data_prevista, 'valor', tp.valor,
                       'aprovada_por', (select string_agg(n.nome, ', ' order by a.em) from erp.previsao_aprovacoes a
                                          join nome n on n.id = a.por where a.previsao_id = p.id and a.aprovado))
                       order by p.data_prevista)
                     from erp.titulo_previsoes tp join erp.previsoes p on p.id = tp.previsao_id where tp.titulo_id = t.id), '[]'::jsonb),
      'substitui', (select jsonb_build_object('numero', s.numero,
                            'motivo', (select r.motivo from erp.titulo_revisoes r where r.titulo_id = s.id order by r.pedida_em desc limit 1))
                      from erp.titulos s where s.id = t.substitui_id)),
    'aprovacoes', coalesce((select jsonb_agg(jsonb_build_object(
                     'rodada', v.rodada, 'area', erp.area_linha(v.centro_custo_id, v.divisao_id, null), 'fase', v.fase, 'lista', v.lista,
                     'aprovado', v.aprovado, 'justificativa', v.justificativa, 'por', (select n.nome from nome n where n.id = v.por),
                     'em', v.em, 'origem', v.origem) order by v.rodada, v.em)
                   from erp.titulo_aprovacoes v where v.titulo_id = t.id), '[]'::jsonb),
    'alteracoes', coalesce((select jsonb_agg(jsonb_build_object(
                     'rodada', r.rodada, 'area', erp.area_linha(r.centro_custo_id, null, null), 'motivo', r.motivo,
                     'pedida_por', (select n.nome from nome n where n.id = r.pedida_por), 'pedida_em', r.pedida_em,
                     'resposta', r.resposta, 'reenviada_por', (select n.nome from nome n where n.id = r.reenviada_por), 'reenviada_em', r.reenviada_em,
                     'ajustes', coalesce((
                        select jsonb_agg(jsonb_build_object('campo', erp.rotulo_campo(a.tabela, k.campo, coalesce(a.depois, a.antes)),
                                                            'antes', a.antes->>k.campo, 'depois', a.depois->>k.campo) order by a.em, k.campo)
                          from erp.titulo_ajustes a
                          cross join lateral (select x as campo from jsonb_object_keys(coalesce(a.depois, a.antes)) x) k
                         where a.revisao_id = r.id
                           and k.campo not in ('id', 'titulo_id', 'documento_id', 'criado_em', 'criado_por', 'rodada', 'situacao', 'cancelamento')
                           and (a.antes->k.campo) is distinct from (a.depois->k.campo)), '[]'::jsonb))
                     order by r.pedida_em desc)
                   from erp.titulo_revisoes r where r.titulo_id = t.id), '[]'::jsonb),
    'historico', coalesce((select jsonb_agg(jsonb_build_object('em', h.em, 'por', h.por, 'texto', h.texto) order by h.em desc, h.ordem desc)
                  from (
                    select t.criado_em as em, (select n.nome from nome n where n.id = t.criado_por) as por, 1 as ordem,
                           'lançou o título' || coalesce(' a partir da nota ' || (select d.numero from erp.documentos_fiscais d where d.id = t.documento_id), '') || '.' as texto
                    union all
                    select v.em, (select n.nome from nome n where n.id = v.por), 3,
                           case when v.aprovado then 'aprovou como ' || v.lista || ' (fase ' || v.fase || coalesce(', ' || erp.area_linha(v.centro_custo_id, v.divisao_id, null), '') || ').'
                                else 'recusou: ' || v.justificativa end
                      from erp.titulo_aprovacoes v where v.titulo_id = t.id
                    union all
                    select r.pedida_em, (select n.nome from nome n where n.id = r.pedida_por), 2, 'pediu alteração: ' || r.motivo
                      from erp.titulo_revisoes r where r.titulo_id = t.id
                    union all
                    select r.reenviada_em, (select n.nome from nome n where n.id = r.reenviada_por), 2,
                           'reenviou para aprovação' || coalesce(': ' || r.resposta, '.')
                      from erp.titulo_revisoes r where r.titulo_id = t.id and r.reenviada_em is not null
                    union all
                    select e.atualizado_em, null, 4,
                           case e.situacao when 'enviado' then 'o título entrou no Sienge (nº ' || e.sienge_id || ').'
                                           when 'erro' then 'o título não chegou ao Sienge: ' || coalesce(e.erro, 'erro sem detalhe') || '.'
                                           when 'manual' then 'o envio ao Sienge ficou para ser feito à mão' || coalesce(': ' || e.erro, '.') end
                      from erp.sienge_envios e where e.titulo_id = t.id and e.situacao in ('enviado', 'erro', 'manual')
                    union all
                    select coalesce(pg.data::timestamptz, q.criada_em), null, 5,
                           'pagamento de R$ ' || to_char(q.principal + q.juros + q.multa - q.desconto, 'FM999G999G990D00') || ' na ' || pa.numero || 'ª parcela.'
                      from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id left join erp.pagamentos pg on pg.id = q.pagamento_id
                     where pa.titulo_id = t.id
                    union all  -- o log bruto: só o administrador lê (RLS de erp.auditoria)
                    select au.em, (select n.nome from nome n where n.id = au.por), 6,
                           'alterou ' || (select string_agg(k, ', ' order by k) from jsonb_object_keys(au.depois) k
                                           where (au.antes->k) is distinct from (au.depois->k)) || '.'
                      from erp.auditoria au
                     where au.tabela = 'titulos' and au.registro = t.id::text and au.acao = 'update'
                       and exists (select 1 from jsonb_object_keys(au.depois) k where (au.antes->k) is distinct from (au.depois->k))
                  ) h where h.em is not null), '[]'::jsonb),
    'anexos', '[]'::jsonb,
    'contrato', (select jsonb_build_object('tipo', c.tipo, 'numero', c.numero, 'descricao', c.descricao, 'valor_total', c.valor_total,
                          'valor_periodo', c.valor_periodo, 'periodicidade', c.periodicidade,
                          'lancado', coalesce((select sum(x.valor) from erp.titulos x where x.compromisso_id = c.id and x.situacao <> 'cancelado'), 0),
                          'pago', coalesce((select sum(pg.valor) from pago pg join erp.titulos x on x.id = pg.titulo_id where x.compromisso_id = c.id), 0),
                          'saldo', c.valor_total - coalesce((select sum(x.valor) from erp.titulos x where x.compromisso_id = c.id and x.situacao <> 'cancelado'), 0),
                          'titulos', coalesce((select jsonb_agg(jsonb_build_object(
                                        'id', x.id, 'documento', (select coalesce(d.tipo || ' ', '') || d.numero from erp.documentos_fiscais d where d.id = x.documento_id),
                                        'competencia', x.competencia, 'valor', x.valor, 'etapa', erp.etapa_titulo(x.id),
                                        'pago_em', (select pg.em from pago pg where pg.titulo_id = x.id), 'este', x.id = t.id)
                                        order by x.competencia desc, x.emissao desc)
                                      from erp.titulos x where x.compromisso_id = c.id), '[]'::jsonb))
                   from erp.compromissos c where c.id = t.compromisso_id),
    'fornecedor', (select jsonb_build_object('nome', pe.nome, 'documento', pe.documento, 'email', pe.email, 'telefone', pe.telefone,
                            'endereco', null, 'contas', '[]'::jsonb,
                            'desde', (select min(x.emissao) from erp.titulos x where x.pessoa_id = pe.id and x.sentido = 'pagar'),
                            'titulos', (select count(*) from erp.titulos x where x.pessoa_id = pe.id and x.sentido = 'pagar' and x.situacao <> 'cancelado'),
                            'total_12m', coalesce((select sum(x.valor) from erp.titulos x where x.pessoa_id = pe.id and x.sentido = 'pagar'
                                                     and x.situacao <> 'cancelado' and x.emissao >= current_date - interval '12 months'), 0),
                            'pago_total', coalesce((select sum(pg.valor) from pago pg join erp.titulos x on x.id = pg.titulo_id where x.pessoa_id = pe.id), 0),
                            'contratos_ativos', (select count(*) from erp.compromissos c where c.pessoa_id = pe.id and c.situacao = 'ativo'),
                            'ultimos', coalesce((select jsonb_agg(u.j order by u.emissao desc, u.criado_em desc) from (
                                          select x.emissao, x.criado_em, jsonb_build_object(
                                                   'id', x.id, 'documento', (select coalesce(d.tipo || ' ', '') || d.numero from erp.documentos_fiscais d where d.id = x.documento_id),
                                                   'emissao', x.emissao, 'valor', x.valor, 'etapa', erp.etapa_titulo(x.id),
                                                   'area', (select string_agg(distinct erp.area_linha(r.centro_custo_id, r.divisao_id, r.subdivisao_id), ', ')
                                                              from erp.titulo_rateios r where r.titulo_id = x.id),
                                                   'este', x.id = t.id) as j
                                            from erp.titulos x where x.pessoa_id = pe.id and x.sentido = 'pagar'
                                           order by x.emissao desc, x.criado_em desc limit 10) u), '[]'::jsonb))
                     from erp.pessoas pe where pe.id = t.pessoa_id))
    from t $$;

-- Só o usuário logado executa (mesma regra do resto do esquema api)
revoke execute on function api.titulo_rastro(uuid), erp.rotulo_campo(text, text, jsonb) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function api.titulo_rastro(uuid), erp.rotulo_campo(text, text, jsonb) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke execute on function api.titulo_rastro(uuid), erp.rotulo_campo(text, text, jsonb) from service_role; end if;
end $$;
grant execute on function api.titulo_rastro(uuid), erp.rotulo_campo(text, text, jsonb) to authenticated;
