-- Competência no Sienge (17/11/2026). Na API do Sienge, billDate é a "Data de competência" e baseDate
-- é a "Data base" do indexador (bills-v1.yaml, BillInsert e BillInstallment). Os pedidos do título
-- (20261117000200) e da previsão (20261117000400) mandavam os dois trocados: o título PRV de teste 8591
-- foi gravado com a competência no dia do lançamento. Agora billDate = competência e baseDate = emissão
-- (na previsão, que não tem emissão, o dia em que ela foi lançada). Com indexId 0 a data base não corrige
-- nada. Portabilidade: SQL puro.

create or replace function erp.sienge_pedido(p_titulo uuid) returns jsonb language plpgsql stable as $$
declare t erp.titulos; d erp.documentos_fiscais; v_empresa text; v_credor text; v_rateio jsonb; v_parcelas jsonb;
        v_falta text; v_n int; v_numero text; v_soma numeric; v_banco text[];
begin
  if not erp.sistema() then raise exception 'Só o sistema monta o envio ao Sienge'; end if;
  select * into t from erp.titulos where id = p_titulo;
  if t.id is null then raise exception 'Título não existe'; end if;
  if t.sentido <> 'pagar' or t.tipo not in ('fornecedor','avulso') then
    raise exception 'Só título a pagar de fornecedor ou avulso vai ao Sienge por aqui';
  end if;
  if not erp.titulo_aprovado(t.id) then raise exception 'O título não está aprovado'; end if;
  if t.documento_id is null then raise exception 'O título não tem documento (nota, boleto, fatura, guia ou recibo)'; end if;
  select * into d from erp.documentos_fiscais where id = t.documento_id;
  if erp.sienge_documento(d.tipo) is null then raise exception 'Documento do tipo % não tem código no Sienge', d.tipo; end if;
  if exists (select 1 from erp.documento_retencoes where documento_id = d.id) or coalesce(d.caucao_valor, 0) > 0 then
    raise exception 'Nota com retenção de imposto ou caução ainda não vai ao Sienge pelo adaptador';
  end if;
  v_numero := d.numero || case when d.serie <> '' then '-' || d.serie else '' end;
  if length(v_numero) > 20 then raise exception 'Número do documento passa de 20 caracteres: %', v_numero; end if;

  select codigo into v_empresa from erp.codigos_externos where sistema = 'sienge' and tabela = 'empresas' and registro_id = t.empresa_id;
  if v_empresa is null or v_empresa !~ '^[0-9]+$' then raise exception 'A empresa do título não tem código no Sienge'; end if;
  select codigo into v_credor from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and registro_id = t.pessoa_id;
  if v_credor is null or v_credor !~ '^[0-9]+$' then raise exception 'O credor do título não tem código no Sienge'; end if;

  -- rateio: centro e conta do Sienge de cada linha, somando as linhas que caem no mesmo par
  select string_agg(distinct case when r.nucleo_economico_id is null or r.centro_custo_id is null then 'linha sem núcleo ou centro'
                                  when c.sienge_centro is null then 'núcleo + centro sem centro de custo do Sienge'
                                  when k.sienge_conta is null then 'natureza + centro sem conta do Sienge' end, '; ')
    into v_falta
    from erp.titulo_rateios r
    left join erp.sienge_centros c on c.nucleo_economico_id = r.nucleo_economico_id and c.centro_custo_id = r.centro_custo_id
    left join erp.sienge_contas k on k.natureza_id = r.natureza_id and k.centro_custo_id = r.centro_custo_id
   where r.titulo_id = t.id;
  if v_falta is not null then raise exception 'De-para do Sienge incompleto: %', v_falta; end if;
  -- percentual com 2 casas; o resto do arredondamento vai para a maior linha
  with g as (
    select c.sienge_centro, k.sienge_conta, sum(r.percentual) as pct
      from erp.titulo_rateios r
      join erp.sienge_centros c on c.nucleo_economico_id = r.nucleo_economico_id and c.centro_custo_id = r.centro_custo_id
      join erp.sienge_contas k on k.natureza_id = r.natureza_id and k.centro_custo_id = r.centro_custo_id
     where r.titulo_id = t.id group by 1, 2),
  a as (select *, round(pct, 2) as p2, row_number() over (order by pct desc, sienge_centro, sienge_conta) as ordem from g)
  select jsonb_agg(jsonb_build_object('costCenterId', sienge_centro, 'paymentCategoriesId', sienge_conta,
                                      'percentage', p2 + case when ordem = 1 then 100 - (select sum(p2) from a) else 0 end)
                   order by ordem)
    into v_rateio from a;

  -- parcelas, cada uma com a forma de pagamento
  select count(*), sum(p.valor) into v_n, v_soma from erp.parcelas p where p.titulo_id = t.id;
  if v_n = 0 or v_soma <> t.valor then raise exception 'As parcelas não somam o valor do título'; end if;
  select string_agg(p.numero::text, ', ' order by p.numero) into v_falta
    from erp.parcelas p where p.titulo_id = t.id
     and not exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = p.titulo_id and g.numero = p.numero);
  if v_falta is not null then raise exception 'Falta a forma de pagamento da parcela %', v_falta; end if;
  perform erp._conferir_forma_pagamento(g.titulo_id, g.numero, g.forma, g.pix_tipo, g.pix_chave, g.boleto_linha, g.pix_excecao)
     from erp.parcela_pagamentos g where g.titulo_id = t.id;
  -- boleto do mesmo banco de uma conta ativa da empresa: "próprio banco" (1); senão "outros bancos" (2)
  select array_agg(distinct substring(cb.banco from '^[0-9]{3}')) into v_banco
    from erp.contas_bancarias cb where cb.empresa_id = t.empresa_id and cb.ativa;
  select jsonb_agg(jsonb_build_object('numero', p.numero, 'vencimento', p.vencimento, 'valor', p.valor, 'forma', g.forma)
                   || case g.forma
                        when 'pix' then jsonb_build_object('pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave)
                        else jsonb_build_object('boleto_linha', g.boleto_linha,
                                                'boleto_tipo', case when substr(g.boleto_linha, 1, 3) = any (coalesce(v_banco, '{}')) then 1 else 2 end)
                      end
                   order by p.numero)
    into v_parcelas
    from erp.parcelas p join erp.parcela_pagamentos g on g.titulo_id = p.titulo_id and g.numero = p.numero
   where p.titulo_id = t.id;

  return jsonb_build_object(
    'titulo_id', t.id,
    'empresa', v_empresa::int,
    'titulo', jsonb_build_object(
      'debtorId', v_empresa::int,
      'creditorId', v_credor::int,
      'documentIdentificationId', erp.sienge_documento(d.tipo),
      'documentNumber', v_numero,
      'issueDate', t.emissao,
      'billDate', t.competencia,
      'baseDate', t.emissao,
      'dueDate', (select min(vencimento) from erp.parcelas where titulo_id = t.id),
      'indexId', 0,
      'installmentsNumber', v_n,
      'totalInvoiceAmount', t.valor,
      'discount', 0,
      'notes', left('ERP ' || t.id || coalesce(' · ' || nullif(trim(t.descricao), ''), ''), 500),
      'budgetCategories', v_rateio),
    'parcelas', v_parcelas);
end $$;

create or replace function erp._sienge_pedido_previsao(p_previsao uuid) returns jsonb language plpgsql stable as $$
declare p erp.previsoes; v_empresa text; v_credor text; v_centro int; v_conta text; v_saldo numeric;
begin
  if not erp.sistema() then raise exception 'Só o sistema monta o envio ao Sienge'; end if;
  select * into p from erp.previsoes where id = p_previsao;
  if p.id is null then raise exception 'Previsão não existe'; end if;
  if p.sentido <> 'pagar' then raise exception 'Só previsão a pagar vai ao Sienge'; end if;
  if p.situacao <> 'aberta' then raise exception 'A previsão não está aberta'; end if;
  if not erp.previsao_aprovada(p.id) then raise exception 'A previsão não está aprovada'; end if;
  v_saldo := erp._previsao_saldo(p.id);
  if v_saldo <= 0 then raise exception 'A previsão não tem saldo'; end if;

  select codigo into v_empresa from erp.codigos_externos where sistema = 'sienge' and tabela = 'empresas' and registro_id = p.empresa_id;
  if v_empresa is null or v_empresa !~ '^[0-9]+$' then raise exception 'A empresa da previsão não tem código no Sienge'; end if;
  if p.pessoa_id is not null then
    select codigo into v_credor from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and registro_id = p.pessoa_id;
    if v_credor is null or v_credor !~ '^[0-9]+$' then raise exception 'O credor da previsão não tem código no Sienge'; end if;
  else
    select valor into v_credor from erp.sienge_parametros where chave = 'credor_previsao';
    if v_credor is null then raise exception 'Falta o credor genérico da previsão no Sienge (parâmetro credor_previsao)'; end if;
  end if;
  if p.nucleo_economico_id is null or p.centro_custo_id is null then raise exception 'A previsão não tem núcleo e centro'; end if;
  select sienge_centro into v_centro from erp.sienge_centros where nucleo_economico_id = p.nucleo_economico_id and centro_custo_id = p.centro_custo_id;
  select sienge_conta into v_conta from erp.sienge_contas where natureza_id = p.natureza_id and centro_custo_id = p.centro_custo_id;
  if v_centro is null then raise exception 'De-para do Sienge incompleto: núcleo + centro sem centro de custo do Sienge'; end if;
  if v_conta is null then raise exception 'De-para do Sienge incompleto: natureza + centro sem conta do Sienge'; end if;

  return jsonb_build_object(
    'titulo_id', p.id,
    'empresa', v_empresa::int,
    'titulo', jsonb_build_object(
      'debtorId', v_empresa::int,
      'creditorId', v_credor::int,
      'documentIdentificationId', 'PRV',
      'documentNumber', 'PRV-' || upper(left(replace(p.id::text, '-', ''), 12)),
      'issueDate', (p.criada_em at time zone 'America/Sao_Paulo')::date,
      'billDate', p.competencia,
      'baseDate', (p.criada_em at time zone 'America/Sao_Paulo')::date,
      'dueDate', p.data_prevista,
      'indexId', 0,
      'installmentsNumber', 1,
      'totalInvoiceAmount', v_saldo,
      'discount', 0,
      'notes', left('ERP ' || p.id || ' · Previsão' || coalesce(' · ' || nullif(trim(p.descricao), ''), ''), 500),
      'budgetCategories', jsonb_build_array(jsonb_build_object('costCenterId', v_centro, 'paymentCategoriesId', v_conta, 'percentage', 100))),
    'parcelas', jsonb_build_array(jsonb_build_object('numero', 1, 'vencimento', p.data_prevista, 'valor', v_saldo)));
end $$;
