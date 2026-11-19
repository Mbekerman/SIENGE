-- Lançar título pela tela (Moises, 18/11/2026: "vamos pelas telas de Lançar título, previsões e contratos
-- recorrentes"; "Título de previsão tb deve ser exibido quando tiver"). A tela lança a nota (com nota): o
-- documento, o rateio, as parcelas com a forma de pagamento de cada uma, as etiquetas e as previsões que ela consome.
--
-- Mesma regra do esquema api (migration _api_telas): SECURITY INVOKER. As opções que a tela mostra passam pelo RLS
-- do erp e pelo perfil de quem lança (erp.lanco); a gravação passa pelos mesmos gatilhos e políticas de quem grava
-- direto no erp e chama erp.lancar_documento, numa transação só: se algo for recusado, nada fica gravado.
-- Fora desta versão (como no envio ao Sienge, doc 05, 5.2): retenção, caução, adiantamento sem nota, rascunho e a
-- descrição do título (o título confirmado não se edita, e erp.lancar_documento não recebe descrição).
-- Portabilidade: SQL puro.

-- O que quem lança pode escolher: as empresas com os núcleos ativos e os centros ligados em cada um, os centros com
-- os últimos níveis das divisões ativas, e as etiquetas ativas. Nulo para quem não grava.
create function api.lancamento_opcoes() returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  select case when erp.escrevo() then jsonb_build_object(
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', p.nome, 'documento', p.documento,
                   'nucleos', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'nome', n.nome,
                                   'centros', coalesce((select jsonb_agg(nc.centro_custo_id)
                                                          from erp.nucleo_centros nc join erp.centros_custo c on c.id = nc.centro_custo_id
                                                         where nc.nucleo_economico_id = n.id and nc.ligado and c.ativo), '[]'::jsonb))
                                   order by n.nome)
                                 from erp.nucleos_economicos n where n.empresa_id = e.id and n.ativo), '[]'::jsonb))
                   order by p.nome)
                 from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id where e.ativa), '[]'::jsonb),
    'centros', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome,
                   'divisoes', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'caminho', erp.caminho_divisao(d.id))
                                           order by erp.caminho_divisao(d.id))
                                          from erp.divisoes d where d.centro_custo_id = c.id and d.ativa and erp.divisao_folha(d.id)), '[]'::jsonb))
                   order by c.nome)
                 from erp.centros_custo c where c.ativo), '[]'::jsonb),
    'etiquetas', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.nome) order by x.nome)
                             from erp.etiquetas x where x.ativa), '[]'::jsonb))
  end $$;

-- Naturezas em que a pessoa lança naquele núcleo, centro e último nível da divisão (nulo = centro sem divisão):
-- as do último nível, ativas, que não são só de orçamento e que o perfil dela libera.
create function api.naturezas_lancaveis(p_nucleo uuid, p_centro uuid, p_divisao uuid)
returns table (id uuid, codigo text, caminho text, restrita boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select vn.id, vn.codigo, vn.caminho, n.restrita
    from erp.v_naturezas vn join erp.naturezas n on n.id = vn.id
   where vn.ativa and not vn.so_orcado and erp.natureza_folha(vn.id)
     and erp.natureza_ligada(p_centro, p_divisao, vn.id)
     and erp.lanco(p_nucleo, p_centro, vn.id, erp.eu(),
                   (select coalesce(d.raiz_id, d.id) from erp.divisoes d where d.id = p_divisao))
   order by vn.caminho $$;

-- Fornecedores ativos pelo nome, nome fantasia ou documento (até 30).
create function api.fornecedores(p_busca text)
returns table (id uuid, nome text, nome_fantasia text, documento text, tipo text)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select p.id, p.nome, p.nome_fantasia, p.documento, p.tipo
    from erp.pessoas p
   where p.ativa and exists (select 1 from erp.pessoa_papeis pp where pp.pessoa_id = p.id and pp.papel = 'fornecedor')
     and (coalesce(trim(p_busca), '') = ''
          or p.nome ilike '%' || trim(p_busca) || '%' or p.nome_fantasia ilike '%' || trim(p_busca) || '%'
          or (length(regexp_replace(p_busca, '[^0-9]', '', 'g')) >= 3
              and p.documento like '%' || regexp_replace(p_busca, '[^0-9]', '', 'g') || '%'))
   order by p.nome
   limit 30 $$;

-- Previsões abertas que a nota pode consumir: da empresa, do fornecedor (ou sem fornecedor) e com o núcleo, o
-- centro e a natureza de uma linha do rateio (a mesma regra de erp.lancar_documento), com o título PRV do Sienge
-- quando houver. p_linhas = [{"nucleo": uuid, "centro": uuid, "natureza": uuid}, ...]. Só as que a pessoa vê.
create function api.previsoes_para_nota(p_empresa uuid, p_fornecedor uuid, p_linhas jsonb)
returns table (id uuid, data_prevista date, competencia date, valor numeric, saldo numeric, descricao text,
               natureza text, area text, contrato text, compromisso_id uuid, sienge text, aprovada boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select v.id, v.data_prevista, v.competencia, v.valor, v.saldo, v.descricao,
         (select vn.caminho from erp.v_naturezas vn where vn.id = v.natureza_id),
         erp.area_linha(v.centro_custo_id, v.divisao_id, v.subdivisao_id),
         (select c.numero from erp.compromissos c where c.id = v.compromisso_id), v.compromisso_id,
         (select 'PRV ' || s.sienge_id from erp.sienge_previsoes s where s.previsao_id = v.id and s.sienge_id is not null),
         erp.previsao_aprovada_vista(v.id)
    from erp.v_previsoes v
   where v.situacao = 'aberta' and v.sentido = 'pagar' and v.saldo > 0 and v.empresa_id = p_empresa
     and (v.pessoa_id is null or v.pessoa_id = p_fornecedor)
     and exists (select 1 from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) l
                  where (l->>'nucleo')::uuid is not distinct from v.nucleo_economico_id
                    and (l->>'centro')::uuid is not distinct from v.centro_custo_id
                    and (l->>'natureza')::uuid = v.natureza_id)
   order by v.data_prevista, v.criada_em $$;

-- Lança a nota e devolve o título do fornecedor. Corpo:
-- { empresa, fornecedor, compromisso?, tipo, numero, serie?, emissao, competencia (AAAA-MM-01), valor,
--   rateio: [{nucleo, centro, divisao? (o último nível), natureza, percentual}],
--   parcelas: [{vencimento, forma: pix|boleto, pix_tipo?, pix_chave?, boleto_linha?, pix_excecao?}],
--   previsoes?: [uuid], etiquetas?: [uuid] }
-- As parcelas saem iguais (o centavo que sobra na primeira, como o Sienge; erp._criar_titulo). Sem "previsoes", a nota
-- consome as previsões abertas do contrato, da mais antiga; com a lista, só as da lista (a tela manda as do
-- contrato marcadas junto com as que a pessoa escolheu).
create function api.lancar_titulo(p jsonb) returns uuid language plpgsql volatile security invoker
set search_path = pg_catalog, pg_temp as $$
declare v_doc uuid; v_tit uuid; l jsonb; v_div uuid; v_raiz uuid; v_venc date[]; v_prev uuid[]; i int := 0;
begin
  perform erp.exigir_editor();
  if jsonb_typeof(p->'rateio') <> 'array' or jsonb_array_length(p->'rateio') = 0 then raise exception 'Informe o rateio'; end if;
  if jsonb_typeof(p->'parcelas') <> 'array' or jsonb_array_length(p->'parcelas') = 0 then raise exception 'Informe ao menos uma parcela'; end if;
  if coalesce(p->>'tipo', '') not in ('nfse','nfe','fatura','boleto','recibo','outro') then raise exception 'Tipo de documento inválido'; end if;
  if length(trim(coalesce(p->>'numero', ''))) = 0 then raise exception 'Informe o número do documento'; end if;

  insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values ((p->>'empresa')::uuid, (p->>'fornecedor')::uuid, nullif(p->>'compromisso', '')::uuid, p->>'tipo', trim(p->>'numero'),
          coalesce(trim(p->>'serie'), ''), (p->>'emissao')::date, (p->>'competencia')::date, (p->>'valor')::numeric)
  returning id into v_doc;

  for l in select * from jsonb_array_elements(p->'rateio') loop
    v_div := nullif(l->>'divisao', '')::uuid;
    select coalesce(d.raiz_id, d.id) into v_raiz from erp.divisoes d where d.id = v_div;
    if v_div is not null and v_raiz is null then raise exception 'Divisão não encontrada'; end if;
    insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
    values (v_doc, nullif(l->>'nucleo', '')::uuid, nullif(l->>'centro', '')::uuid, v_raiz,
            case when v_div is distinct from v_raiz then v_div end, (l->>'natureza')::uuid, (l->>'percentual')::numeric);
  end loop;

  select array_agg((x->>'vencimento')::date order by n) into v_venc from jsonb_array_elements(p->'parcelas') with ordinality a(x, n);
  if exists (select 1 from unnest(v_venc) d where d is null) then raise exception 'Informe o vencimento de cada parcela'; end if;
  select array_agg(x::uuid) into v_prev from jsonb_array_elements_text(coalesce(p->'previsoes', '[]'::jsonb)) x;
  v_tit := erp.lancar_documento(v_doc, v_venc, v_prev);

  for l in select x from jsonb_array_elements(p->'parcelas') x loop
    i := i + 1;
    insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao)
    values (v_tit, i, l->>'forma', nullif(l->>'pix_tipo', ''), nullif(trim(l->>'pix_chave'), ''),
            nullif(regexp_replace(coalesce(l->>'boleto_linha', ''), '[^0-9]', '', 'g'), ''), nullif(trim(l->>'pix_excecao'), ''));
  end loop;

  insert into erp.titulo_etiquetas (titulo_id, etiqueta_id)
  select v_tit, x::uuid from jsonb_array_elements_text(coalesce(p->'etiquetas', '[]'::jsonb)) x;

  return v_tit;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa
-- ---------------------------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  foreach f in array array['api.lancamento_opcoes()', 'api.naturezas_lancaveis(uuid, uuid, uuid)', 'api.fornecedores(text)',
                           'api.previsoes_para_nota(uuid, uuid, jsonb)', 'api.lancar_titulo(jsonb)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
