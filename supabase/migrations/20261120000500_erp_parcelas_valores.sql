-- Parcelas com o valor do documento (pedido do Moises, 20/nov/2026: "Faça 1 e 2"; teste do leitor
-- com a nota 172499, de boletos de valores diferentes). Até aqui o título sempre dividia o valor
-- igual, com o centavo que sobra na primeira, como o Sienge. Agora quem lança pode dar o valor de
-- cada parcela como está impresso (todas ou nenhuma): cada uma maior que zero, com até 2 casas, e a
-- soma igual ao valor líquido do título. Sem valores, continua a divisão igual.
--
-- erp.lancar_documento ganha p_valores (novo argumento com padrão: a função antiga sai, e a nova
-- volta a definer de erp_situacao com o mesmo EXECUTE). Os valores entram antes de a alçada ser
-- fixada (_confirmar_titulo), então o comprometido e o livro já nascem com eles.
-- erp.reenviar_titulo mantém os valores diferentes quando a quantidade de parcelas e o líquido não mudam;
-- senão, as parcelas voltam a sair iguais.
-- api.lancar_titulo aceita "valor" em cada parcela.
--
-- O envio ao Sienge não muda aqui: o POST /bills divide igual e a conferência das parcelas para
-- em "manual" quando o valor difere (servicos/sienge-escrita/envio.ts).

-- A divisão igual do Sienge (o centavo que sobra na primeira), a mesma de erp._criar_titulo.
create function erp._parcelas_iguais(p_valor numeric, p_n int) returns numeric[] language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select array_agg(case when i = 1 then p_valor - trunc(p_valor / p_n, 2) * (p_n - 1) else trunc(p_valor / p_n, 2) end order by i)
    from generate_series(1, p_n) i $$;
revoke execute on function erp._parcelas_iguais(numeric, int) from public;
grant execute on function erp._parcelas_iguais(numeric, int) to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

drop function erp.lancar_documento(uuid, date[], uuid[]);

-- O líquido do título que a nota gera (bruto − retenções − caução), a mesma conta do erp.lancar_documento.
-- O reenvio da revisão usa para saber se os valores antigos das parcelas ainda fecham.
create function erp._liquido_documento(p_documento uuid) returns numeric language sql stable as $$
  select d.valor_bruto
         - coalesce((select sum(r.valor) from erp.documento_retencoes r where r.documento_id = d.id), 0)
         - coalesce(d.caucao_valor, round(d.valor_bruto * coalesce((select c.caucao_percentual from erp.compromissos c
                                                                    where c.id = d.compromisso_id), 0) / 100, 2))
    from erp.documentos_fiscais d where d.id = p_documento
$$;
revoke execute on function erp._liquido_documento(uuid) from public;
grant execute on function erp._liquido_documento(uuid) to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

create function erp.lancar_documento(p_documento uuid, p_vencimentos date[], p_previsoes uuid[] default null,
                                     p_valores numeric[] default null)
returns uuid language plpgsql as $$
declare d erp.documentos_fiscais; v_ret numeric; v_liquido numeric; v_tit uuid; v_imp uuid; r record;
        v_resta numeric; v_cons numeric; v_lim numeric; p record; i int;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and not erp.lanco_documento(p_documento) then
    raise exception 'Você não lança em todas as linhas desta nota';
  end if;
  select * into d from erp.documentos_fiscais where id = p_documento for update;
  if d.situacao <> 'rascunho' then raise exception 'O documento já foi lançado'; end if;
  if coalesce(array_length(p_vencimentos, 1), 0) = 0 then raise exception 'Informe ao menos um vencimento'; end if;
  if not erp.rateio_completo('documento', d.id) then raise exception 'O rateio do documento não soma 100%%'; end if;
  perform erp.checar_competencia('documento', d.id, d.emissao, d.competencia);
  if d.caucao_valor is null then
    d.caucao_valor := round(d.valor_bruto * coalesce((select caucao_percentual from erp.compromissos where id = d.compromisso_id), 0) / 100, 2);
  end if;
  if d.caucao_valor > 0 and d.compromisso_id is null then raise exception 'Caução só existe com contrato'; end if;
  select coalesce(sum(valor), 0) into v_ret from erp.documento_retencoes where documento_id = d.id;
  v_liquido := d.valor_bruto - v_ret - d.caucao_valor;
  if v_liquido <= 0 then raise exception 'Retenções e caução passam do valor da nota'; end if;

  v_tit := erp._criar_titulo(d.empresa_id, 'pagar', 'fornecedor', d.emitente_id, d.id, d.compromisso_id,
                                d.emissao, d.competencia, v_liquido, p_vencimentos, 'documento', d.id, null);
  -- valor de cada parcela como está no documento (boletos de valores diferentes); sem ele, iguais
  if p_valores is not null then
    if coalesce(array_length(p_valores, 1), 0) <> array_length(p_vencimentos, 1) then
      raise exception 'Informe o valor de cada parcela';
    end if;
    if exists (select 1 from unnest(p_valores) v where v is null or v <= 0 or v <> round(v, 2)) then
      raise exception 'O valor de cada parcela é maior que zero, com até 2 casas';
    end if;
    if (select sum(v) from unnest(p_valores) v) <> v_liquido then
      raise exception 'As parcelas somam %, e o valor líquido do título é %',
        replace(to_char((select sum(v) from unnest(p_valores) v), 'FM999999999990.00'), '.', ','),
        replace(to_char(v_liquido, 'FM999999999990.00'), '.', ',');
    end if;
    for i in 1..array_length(p_valores, 1) loop
      update erp.parcelas set valor = p_valores[i] where titulo_id = v_tit and numero = i;
    end loop;
  end if;
  -- consumo das previsões (as dadas, ou as abertas do mesmo contrato, da mais antiga), até o bruto.
  -- Só casa previsão da mesma empresa, do mesmo fornecedor (ou sem fornecedor) e com o mesmo
  -- núcleo, centro de custo e natureza de uma linha do rateio da nota (S-030). Previsão dada que
  -- não casa é recusada, nunca ignorada.
  if p_previsoes is not null and exists (
       select 1 from unnest(p_previsoes) as x(id)
       where not exists (select 1 from erp.previsoes pr where pr.id = x.id and erp._previsao_casa(pr, d))) then
    raise exception 'Previsão que não é desta nota: precisa ser aberta, da mesma empresa e fornecedor, e com o mesmo núcleo, centro de custo e natureza do rateio';
  end if;
  v_resta := d.valor_bruto;
  for p in
    select pr.id, pr.nucleo_economico_id, pr.centro_custo_id, pr.natureza_id from erp.previsoes pr
    where erp._previsao_casa(pr, d)
      and (case when p_previsoes is not null then pr.id = any(p_previsoes)
                else d.compromisso_id is not null and pr.compromisso_id = d.compromisso_id end)
    order by pr.data_prevista, pr.criada_em
  loop
    exit when v_resta <= 0;
    -- só até a parte do bruto rateada no mesmo núcleo, centro e natureza da previsão,
    -- descontado o que outras previsões da mesma combinação já consumiram nesta nota
    select round(d.valor_bruto * coalesce(sum(dr.percentual), 0) / 100, 2)
           - coalesce((select sum(tp.valor) from erp.titulo_previsoes tp join erp.previsoes q on q.id = tp.previsao_id
                       where tp.titulo_id = v_tit
                         and q.nucleo_economico_id is not distinct from p.nucleo_economico_id
                         and q.centro_custo_id is not distinct from p.centro_custo_id
                         and q.natureza_id = p.natureza_id), 0)
      into v_lim
      from erp.documento_rateios dr
     where dr.documento_id = d.id
       and dr.nucleo_economico_id is not distinct from p.nucleo_economico_id
       and dr.centro_custo_id is not distinct from p.centro_custo_id
       and dr.natureza_id = p.natureza_id;
    v_cons := least(v_resta, erp._previsao_saldo(p.id), v_lim);
    continue when v_cons <= 0;
    insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (v_tit, p.id, v_cons);
    v_resta := v_resta - v_cons;
  end loop;
  -- a alçada é fixada depois do consumo: a nota conta no acumulado só o que passa do saldo da previsão
  perform erp._confirmar_titulo(v_tit);

  for r in select * from erp.documento_retencoes where documento_id = d.id loop
    v_imp := erp._criar_titulo(d.empresa_id, 'pagar', 'imposto', r.orgao_id, d.id, d.compromisso_id,
                                  d.emissao, d.competencia, r.valor, array[r.vencimento], 'documento', d.id,
                                  upper(r.imposto) || ' retido na nota ' || d.numero);
    perform erp._confirmar_titulo(v_imp);
  end loop;

  if d.caucao_valor > 0 then
    insert into erp.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
    values (d.compromisso_id, 'retencao', d.caucao_valor, d.id);
  end if;

  update erp.documentos_fiscais set situacao = 'lancado', lancado_em = now(), caucao_valor = d.caucao_valor where id = d.id;
  return v_tit;
end $$;

alter function erp.lancar_documento(uuid, date[], uuid[], numeric[]) security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.lancar_documento(uuid, date[], uuid[], numeric[]) owner to erp_situacao;
revoke execute on function erp.lancar_documento(uuid, date[], uuid[], numeric[]) from public;
grant execute on function erp.lancar_documento(uuid, date[], uuid[], numeric[])
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config, authenticated;

create or replace function erp.reenviar_titulo(p_titulo uuid, p_resposta text, p_vencimentos date[] default null,
                                    p_previsoes uuid[] default null)
returns uuid language plpgsql as $$
declare t erp.titulos; d erp.documentos_fiscais; v_venc date[]; v_prev uuid[]; v_novo uuid; v_rev uuid; v_val numeric[];
begin
  perform erp.exigir_editor();
  select * into t from erp.titulos where id = p_titulo for update;
  if not erp.em_revisao(p_titulo) then raise exception 'O título não está em revisão'; end if;
  if not erp.pode_ajustar(p_titulo) then
    raise exception 'Quem reenvia é quem lançou, o gestor da área ou o AF';
  end if;
  if length(trim(coalesce(p_resposta, ''))) = 0 then raise exception 'Reenviar exige a resposta ao pedido'; end if;
  update erp.titulo_revisoes set resposta = p_resposta where titulo_id = p_titulo and reenviada_em is null
  returning id into v_rev;
  if t.documento_id is not null then
    v_venc := coalesce(p_vencimentos,
                       (select array_agg(vencimento order by numero) from erp.parcelas where titulo_id = t.id));
    select array_agg(distinct tp.previsao_id) into v_prev
      from erp.titulo_previsoes tp join erp.titulos x on x.id = tp.titulo_id
     where x.documento_id = t.documento_id and x.situacao <> 'cancelado';
    -- parcelas de valores diferentes (do documento) continuam como estavam, se a quantidade não mudou
    select array_agg(valor order by numero) into v_val from erp.parcelas where titulo_id = t.id;
    if v_val = erp._parcelas_iguais(t.valor, array_length(v_val, 1))
       or array_length(v_val, 1) <> array_length(v_venc, 1) then
      v_val := null;
    end if;
    perform erp._desfazer_titulos(t.id, 'revisao');
    -- se o ajuste da revisão mudou o líquido (retenção ou caução), os valores antigos não fecham: saem iguais
    if v_val is not null and (select sum(v) from unnest(v_val) v) <> erp._liquido_documento(t.documento_id) then
      v_val := null;
    end if;
    if p_previsoes is null then
      select * into d from erp.documentos_fiscais where id = t.documento_id;
      select coalesce(array_agg(pr.id), '{}') into v_prev
        from erp.previsoes pr where pr.id = any(coalesce(v_prev, '{}')) and erp._previsao_casa(pr, d);
    else
      v_prev := p_previsoes;
    end if;
    v_novo := erp.lancar_documento(t.documento_id, v_venc, v_prev, v_val);
    update erp.titulos set substitui_id = t.id where id = v_novo;
    perform erp._aprovar_pelo_ajuste(v_novo, v_rev);
    return v_novo;
  end if;
  if not erp.rateio_completo('titulo', t.id) then raise exception 'O rateio do título não soma 100%%'; end if;
  if coalesce((select sum(valor) from erp.parcelas where titulo_id = t.id), 0) <> t.valor then
    raise exception 'As parcelas não somam o valor do título';
  end if;
  if t.tipo = 'adiantamento' and (select count(*) from erp.titulo_rateios where titulo_id = t.id) <> 1 then
    raise exception 'O pedido de adiantamento tem um núcleo e um centro de custo só';
  end if;
  perform erp.checar_competencia('titulo', t.id, t.emissao, t.competencia);
  perform erp._estornar_titulo(t.id, 'comprometido');
  update erp.titulos set rodada = rodada + 1 where id = t.id returning * into t;
  perform erp._comprometer_titulo(t);
  perform erp._definir_alcada(t.id);
  perform erp._aprovar_pelo_ajuste(t.id, v_rev);
  return t.id;
end $$;

-- o create or replace volta a invoker
alter function erp.reenviar_titulo(uuid, text, date[], uuid[]) security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.reenviar_titulo(uuid, text, date[], uuid[]) owner to erp_situacao;

-- api.lancar_titulo: "valor" em cada parcela (todas ou nenhuma). A função é trocada no lugar, a partir
-- da definição atual (que já liga os anexos, 20261119000400), como fez a migration dos anexos.
--   parcelas: [{vencimento, valor?, forma: pix|boleto, pix_tipo?, pix_chave?, boleto_linha?, pix_excecao?}]
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def, 'v_venc date[]; v_prev uuid[]; i int := 0;', 'v_venc date[]; v_prev uuid[]; v_val numeric[]; i int := 0;');
  v_novo := replace(v_novo, E'  v_tit := erp.lancar_documento(v_doc, v_venc, v_prev);\n', $r$  select count(*) filter (where nullif(x->>'valor', '') is not null)::int into i from jsonb_array_elements(p->'parcelas') x;
  if i > 0 and i < jsonb_array_length(p->'parcelas') then raise exception 'Informe o valor de todas as parcelas, ou de nenhuma'; end if;
  if i > 0 then
    select array_agg((x->>'valor')::numeric order by n) into v_val from jsonb_array_elements(p->'parcelas') with ordinality a(x, n);
  end if;
  i := 0;
  v_tit := erp.lancar_documento(v_doc, v_venc, v_prev, v_val);
$r$);
  if v_novo = v_def or position('v_val numeric[]' in v_novo) = 0 or position('v_prev, v_val)' in v_novo) = 0 then
    raise exception 'api.lancar_titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;
