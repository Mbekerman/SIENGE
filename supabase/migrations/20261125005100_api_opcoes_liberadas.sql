-- Opções de lançamento filtradas pela liberação de quem lança (Moises, 25/11/2026, na Nova previsão: "Os centros de
-- custos, núcleos e naturezas devem ser filtrados pela lista de liberação do usuário"). Até aqui só a natureza era
-- filtrada (api.naturezas_lancaveis); núcleos e centros vinham todos os ativos e a gravação é que recusava.
-- Agora api.lancamento_opcoes só traz, em cada empresa, os núcleos em que a pessoa lança em algum centro; em cada
-- núcleo, os centros em que ela lança (no centro inteiro ou em alguma divisão); e, novo, a lista "divisoes" do núcleo
-- com os últimos níveis em que ela lança. Empresa sem núcleo liberado sai. A conferência é a mesma do RLS (erp.lanco
-- sem natureza): o master lança em tudo, e as regras continuam no banco (a lista só esconde o que seria recusado).
-- Vale para as três janelas que usam esta lista: Lançar título, Nova conta e Nova previsão.
-- SECURITY INVOKER, como antes; o formato das empresas e dos centros não muda (só ganha "divisoes" em cada núcleo).
create or replace function api.lancamento_opcoes() returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  with liberado as (
    -- núcleo × centro × último nível (nulo = o centro sem divisão ou o centro inteiro) em que a pessoa lança
    select n.empresa_id, n.id as nucleo, c.id as centro, d.id as divisao
      from erp.nucleos_economicos n
      join erp.nucleo_centros nc on nc.nucleo_economico_id = n.id and nc.ligado
      join erp.centros_custo c on c.id = nc.centro_custo_id and c.ativo
      left join erp.divisoes d on d.centro_custo_id = c.id and d.ativa and erp.divisao_folha(d.id)
     where n.ativo
       and erp.lanco(n.id, c.id, null, erp.eu(), case when d.id is not null then coalesce(d.raiz_id, d.id) end)
  )
  select case when erp.escrevo() then jsonb_build_object(
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', coalesce(e.apelido, p.nome), 'razao_social', p.nome,
                   'documento', p.documento,
                   'nucleos', (select jsonb_agg(jsonb_build_object('id', n.id, 'nome', n.nome,
                                   'centros', (select jsonb_agg(distinct l.centro) from liberado l where l.nucleo = n.id),
                                   'divisoes', coalesce((select jsonb_agg(distinct l.divisao) from liberado l
                                                          where l.nucleo = n.id and l.divisao is not null), '[]'::jsonb))
                                   order by n.nome)
                                 from erp.nucleos_economicos n
                                where n.empresa_id = e.id and n.ativo and exists (select 1 from liberado l where l.nucleo = n.id)))
                   order by coalesce(e.apelido, p.nome))
                 from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id
                where e.ativa and exists (select 1 from liberado l where l.empresa_id = e.id)), '[]'::jsonb),
    'centros', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome,
                   'divisoes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', erp.caminho_divisao(d.id))
                                           order by erp.caminho_divisao(d.id))
                                          from erp.divisoes d where d.centro_custo_id = c.id and d.ativa and erp.divisao_folha(d.id)), '[]'::jsonb))
                   order by c.nome)
                 from erp.centros_custo c where c.ativo and exists (select 1 from liberado l where l.centro = c.id)), '[]'::jsonb),
    'etiquetas', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.nome) order by x.nome)
                             from erp.etiquetas x where x.ativa), '[]'::jsonb))
  end $$;
