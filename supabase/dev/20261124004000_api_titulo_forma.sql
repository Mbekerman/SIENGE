-- bkm_dev, 24/nov/2026: a tela do título com a TED e os avisos da forma de pagamento (migration 20261124004000).
-- Colar inteiro no SQL Editor depois do script da TED (20261124003000). Se algo falhar, dá erro e nada fica.
-- Pode rodar de novo sem estrago: a função só é trocada se estiver na versão de antes (conferido no bkm_dev em 24/11)
-- ou já na nova. Nenhum papel é concedido: api.titulo é do postgres e roda como quem chama.
begin;
do $$ declare v text := md5(regexp_replace(regexp_replace(pg_get_functiondef('api.titulo(uuid)'::regprocedure), '--[^' || chr(10) || ']*', '', 'g'), '\s+', '', 'g'));
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'erp' and table_name = 'parcela_pagamentos' and column_name = 'ted_banco') then
    raise exception 'Falta o script da TED (20261124003000); nada foi mudado';
  end if;
  if v <> '451f0da00f3bddde668504cae987099b' and pg_get_functiondef('api.titulo(uuid)'::regprocedure) not like '%avisos_forma_pagamento%' then
    raise exception 'A versão de api.titulo no banco não é a esperada; nada foi mudado';
  end if;
end $$;

create or replace function api.titulo(p_id uuid) returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
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
                   'pix_excecao', f.pix_excecao, 'pix_copia_cola', f.pix_copia_cola,
                   'pix_copia_cola_recebedor', erp.pix_copia_cola_recebedor(f.pix_copia_cola),
                   'pix_copia_cola_conferido', erp.pix_conferido(f.pix_copia_cola), 'pix_copia_cola_excecao', f.pix_copia_cola_excecao,
                   'boleto_conferido', erp.boleto_conferido(f.boleto_linha), 'boleto_excecao', f.boleto_excecao,
                   'ted', case when f.forma = 'ted' then jsonb_build_object('banco', f.ted_banco, 'agencia', f.ted_agencia,
                            'agencia_digito', f.ted_agencia_digito, 'conta', f.ted_conta, 'conta_digito', f.ted_conta_digito,
                            'conta_tipo', f.ted_conta_tipo, 'titular_documento', f.ted_titular_documento, 'excecao', f.ted_excecao) end,
                   'avisos', (select a.avisos from erp.avisos_forma_pagamento(t.id) a where a.numero = pa.numero)) order by pa.numero)
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
    'recebedor_divergente', erp.recebedor_divergente(t.id), 'credor_novo', erp.credor_novo(t.id),
    'sienge_erro', (select e.erro from erp.sienge_envios e where e.titulo_id = t.id))
    from api.titulos() c join erp.titulos t on t.id = c.id
   where c.id = p_id $$;

do $$ begin
  if pg_get_functiondef('api.titulo(uuid)'::regprocedure) not like '%avisos_forma_pagamento(t.id)%'
     or (select prosecdef from pg_proc where oid = 'api.titulo(uuid)'::regprocedure)
     or not has_function_privilege('authenticated', 'api.titulo(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'api.titulo(uuid)', 'EXECUTE') then
    raise exception 'Conferência: api.titulo';
  end if;
end $$;
commit;
