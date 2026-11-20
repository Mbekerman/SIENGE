-- Cadastro das contas recorrentes pela tela (Moises, 19/11/2026: "a criação de contas recorrentes e contratos").
--
-- 1. Conta de consumo (luz, água, telefone, internet), tipo próprio decidido pelo Moises em 18/11/2026: número da
--    instalação (é por ele que a fatura se acha), faixa por mês (o valor aceitável no mês) e teto no ano. Aprova como
--    o contrato: gestor de cada centro do rateio e AF ou AO; mudar instalação, faixa ou teto pede aprovação de novo.
--    Não gera previsões sozinha (o valor muda todo mês); o que a nota fora da faixa faz fica para o PR das notas.
-- 2. api.salvar_conta grava o contrato de serviço (valor total), a assinatura (valor por período) e a conta de
--    consumo, com o rateio, pelo RLS de quem chama; api.conta devolve o cadastro para a tela de alterar.
--
-- Mesma regra do esquema api: SECURITY INVOKER, só authenticated. Portabilidade: SQL e plpgsql padrão.

-- ---------------------------------------------------------------------------------------------
-- 1. Conta de consumo
-- ---------------------------------------------------------------------------------------------
alter table erp.compromissos drop constraint compromissos_tipo_check;
alter table erp.compromissos
  add constraint compromissos_tipo_check check (tipo in ('contrato','pedido','assinatura','avulsa','guia','folha','consumo')),
  add column instalacao   text check (length(trim(instalacao)) > 0),
  add column faixa_mensal numeric(15,2) check (faixa_mensal > 0),
  add column teto_anual   numeric(15,2) check (teto_anual > 0),
  add constraint compromissos_consumo check (tipo <> 'consumo'
    or (instalacao is not null and faixa_mensal is not null and teto_anual is not null and periodicidade is not null
        and dia_vencimento is not null and valor_total is null and valor_periodo is null)),
  add constraint compromissos_so_consumo check (tipo = 'consumo' or (instalacao is null and faixa_mensal is null and teto_anual is null));

-- a mesma instalação do mesmo fornecedor na mesma empresa é uma conta só enquanto ativa
create unique index compromissos_instalacao on erp.compromissos (empresa_id, pessoa_id, upper(regexp_replace(instalacao, '[^0-9A-Za-z]', '', 'g')))
  where tipo = 'consumo' and situacao = 'ativo';

create or replace function erp.compromisso_precisa_aprovacao(p_tipo text) returns boolean language sql immutable as
  $$ select p_tipo in ('contrato','assinatura','consumo') $$;

-- A versão e quem alterou: só o gatilho põe. Mudou o que pede aprovação, versão nova (agora também instalação,
-- faixa e teto da conta de consumo).
create or replace function erp.tg_compromisso_versao() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.aprovacao_versao := 1;
    new.alterado_por := erp.autor();
    return new;
  end if;
  if new.aprovacao_versao <> old.aprovacao_versao and not erp.agindo_como('erp_situacao') then
    raise exception 'A versão da aprovação do contrato só muda pela alteração do contrato';
  end if;
  if new.alterado_por is distinct from old.alterado_por and not erp.agindo_como('erp_situacao') then
    raise exception 'Quem alterou o contrato é posto pelo sistema';
  end if;
  if (new.empresa_id, new.tipo, new.pessoa_id, new.inicio, new.fim, new.valor_total, new.periodicidade, new.valor_periodo,
      new.dia_vencimento, new.caucao_percentual, new.instalacao, new.faixa_mensal, new.teto_anual)
     is distinct from
     (old.empresa_id, old.tipo, old.pessoa_id, old.inicio, old.fim, old.valor_total, old.periodicidade, old.valor_periodo,
      old.dia_vencimento, old.caucao_percentual, old.instalacao, old.faixa_mensal, old.teto_anual) then
    new.aprovacao_versao := old.aprovacao_versao + 1;
    new.alterado_por := erp.autor();
  end if;
  return new;
end $$;

-- A tela Para aprovar e a identificação da nota passam a ver a conta de consumo (valor = a faixa por mês).
do $$
declare v text;
begin
  v := pg_get_functiondef('api.aprovacoes()'::regprocedure);
  if position($x$c.tipo in ('contrato', 'assinatura')$x$ in v) = 0 or position('coalesce(c.valor_periodo, c.valor_total)' in v) = 0 then
    raise exception 'api.aprovacoes mudou: refazer o remendo';
  end if;
  v := replace(v, $x$c.tipo in ('contrato', 'assinatura')$x$, $x$c.tipo in ('contrato', 'assinatura', 'consumo')$x$);
  v := replace(v, 'coalesce(c.valor_periodo, c.valor_total)', 'coalesce(c.valor_periodo, c.faixa_mensal, c.valor_total)');
  execute v;
  v := pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure);
  if position($x$case when c.tipo = 'assinatura' then c.valor_periodo$x$ in v) = 0 then
    raise exception 'api.identificar_nota mudou: refazer o remendo';
  end if;
  v := replace(v, $x$case when c.tipo = 'assinatura' then c.valor_periodo$x$,
                  $x$case when c.tipo in ('assinatura', 'consumo') then coalesce(c.valor_periodo, c.faixa_mensal)$x$);
  execute v;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Lista, cadastro e gravação pela API
-- ---------------------------------------------------------------------------------------------
drop function api.contratos();
create function api.contratos()
returns table (id uuid, tipo text, situacao text, aprovado boolean, fornecedor text, numero text, descricao text,
               inicio date, fim date, periodicidade text, valor_periodo numeric, valor_total numeric, dia_vencimento int,
               instalacao text, faixa_mensal numeric, teto_anual numeric,
               areas text, naturezas text, empresa text, previsoes_abertas int, lancado_por text, meu boolean, posso_alterar boolean)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select c.id, c.tipo, c.situacao, erp.contrato_aprovado_visto(c.id), pe.nome, c.numero, c.descricao,
         c.inicio, c.fim, c.periodicidade, c.valor_periodo, c.valor_total, c.dia_vencimento,
         c.instalacao, c.faixa_mensal, c.teto_anual,
         (select string_agg(distinct erp.area_linha(r.centro_custo_id, r.divisao_id, r.subdivisao_id), ', ')
            from erp.compromisso_rateios r where r.compromisso_id = c.id),
         (select string_agg(distinct vn.nome, ', ') from erp.compromisso_rateios r join erp.v_naturezas vn on vn.id = r.natureza_id
           where r.compromisso_id = c.id),
         (select x.nome from erp.empresas em join erp.pessoas x on x.id = em.pessoa_id where em.id = c.empresa_id),
         (select count(*)::int from erp.previsoes p where p.compromisso_id = c.id and p.situacao = 'aberta'),
         (select u.nome from erp.usuarios u where u.id = c.criado_por), c.criado_por = erp.eu(),
         erp.escrevo() and erp.lanco_compromisso(c.id) and c.situacao = 'ativo'
    from erp.compromissos c
    left join erp.pessoas pe on pe.id = c.pessoa_id
   where c.tipo in ('contrato', 'assinatura', 'consumo') $$;

-- O cadastro de uma conta, para a tela de alterar (o rateio com a divisão de último nível, como a tela grava).
create function api.conta(p_id uuid) returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('id', c.id, 'empresa', c.empresa_id, 'tipo', c.tipo, 'numero', c.numero, 'descricao', c.descricao,
           'fornecedor', (select jsonb_build_object('id', pe.id, 'nome', pe.nome, 'nome_fantasia', pe.nome_fantasia,
                                                    'documento', pe.documento, 'tipo', pe.tipo)
                            from erp.pessoas pe where pe.id = c.pessoa_id),
           'inicio', c.inicio, 'fim', c.fim, 'periodicidade', c.periodicidade, 'valor_periodo', c.valor_periodo,
           'valor_total', c.valor_total, 'dia_vencimento', c.dia_vencimento, 'caucao_percentual', c.caucao_percentual,
           'instalacao', c.instalacao, 'faixa_mensal', c.faixa_mensal, 'teto_anual', c.teto_anual, 'situacao', c.situacao,
           'rateio', coalesce((select jsonb_agg(jsonb_build_object('nucleo', r.nucleo_economico_id, 'centro', r.centro_custo_id,
                                 'divisao', coalesce(r.subdivisao_id, r.divisao_id), 'natureza', r.natureza_id,
                                 'percentual', r.percentual) order by r.percentual desc, r.id)
                                from erp.compromisso_rateios r where r.compromisso_id = c.id), '[]'::jsonb))
    from erp.compromissos c
   where c.id = p_id and c.tipo in ('contrato', 'assinatura', 'consumo') $$;

-- Grava a conta nova (sem id) ou a alteração (com id). Tudo pelo RLS de quem chama: lança no núcleo, centro e
-- natureza de cada linha, e altera só o que lança. O rateio só é refeito se mudou (refazer reabre a aprovação).
create function api.salvar_conta(p jsonb) returns uuid language plpgsql volatile security invoker
set search_path = pg_catalog, pg_temp as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_tipo text := p->>'tipo'; l jsonb; v_div uuid; v_raiz uuid;
        v_novo jsonb; v_velho jsonb; n int;
begin
  perform erp.exigir_editor();
  if v_tipo is null or v_tipo not in ('contrato', 'assinatura', 'consumo') then raise exception 'Tipo de conta inválido'; end if;
  if nullif(p->>'fornecedor', '') is null then raise exception 'Informe o fornecedor'; end if;
  if length(trim(coalesce(p->>'descricao', ''))) = 0 then raise exception 'Informe a descrição'; end if;
  if jsonb_typeof(p->'rateio') <> 'array' or jsonb_array_length(p->'rateio') = 0 then raise exception 'Informe o rateio'; end if;
  if v_tipo = 'contrato' and nullif(p->>'valor_total', '') is null then raise exception 'Informe o valor do contrato'; end if;
  if v_tipo = 'assinatura' and (nullif(p->>'valor_periodo', '') is null or nullif(p->>'periodicidade', '') is null) then
    raise exception 'Informe o valor e a periodicidade';
  end if;
  if v_tipo = 'consumo' and (length(trim(coalesce(p->>'instalacao', ''))) = 0 or nullif(p->>'faixa_mensal', '') is null
                              or nullif(p->>'teto_anual', '') is null or nullif(p->>'dia_vencimento', '') is null) then
    raise exception 'Informe a instalação, a faixa por mês, o teto no ano e o dia do vencimento';
  end if;

  if v_id is null then
    insert into erp.compromissos (empresa_id, tipo, pessoa_id, numero, descricao, inicio, fim, valor_total, periodicidade,
                                  valor_periodo, dia_vencimento, caucao_percentual, instalacao, faixa_mensal, teto_anual)
    values ((p->>'empresa')::uuid, v_tipo, (p->>'fornecedor')::uuid, nullif(trim(p->>'numero'), ''), trim(p->>'descricao'),
            (p->>'inicio')::date, nullif(p->>'fim', '')::date,
            case when v_tipo = 'contrato' then nullif(p->>'valor_total', '')::numeric end,
            case when v_tipo = 'consumo' then coalesce(nullif(p->>'periodicidade', ''), 'mensal') else nullif(p->>'periodicidade', '') end,
            case when v_tipo = 'assinatura' then nullif(p->>'valor_periodo', '')::numeric end,
            nullif(p->>'dia_vencimento', '')::int,
            case when v_tipo = 'contrato' then coalesce(nullif(p->>'caucao_percentual', '')::numeric, 0) else 0 end,
            case when v_tipo = 'consumo' then trim(p->>'instalacao') end,
            case when v_tipo = 'consumo' then nullif(p->>'faixa_mensal', '')::numeric end,
            case when v_tipo = 'consumo' then nullif(p->>'teto_anual', '')::numeric end)
    returning id into v_id;
  else
    -- o tipo não muda: é outra conta
    update erp.compromissos c set
      empresa_id = (p->>'empresa')::uuid, pessoa_id = (p->>'fornecedor')::uuid, numero = nullif(trim(p->>'numero'), ''),
      descricao = trim(p->>'descricao'), inicio = (p->>'inicio')::date, fim = nullif(p->>'fim', '')::date,
      valor_total = case when c.tipo = 'contrato' then nullif(p->>'valor_total', '')::numeric end,
      periodicidade = case when c.tipo = 'consumo' then coalesce(nullif(p->>'periodicidade', ''), 'mensal') else nullif(p->>'periodicidade', '') end,
      valor_periodo = case when c.tipo = 'assinatura' then nullif(p->>'valor_periodo', '')::numeric end,
      dia_vencimento = nullif(p->>'dia_vencimento', '')::int,
      caucao_percentual = case when c.tipo = 'contrato' then coalesce(nullif(p->>'caucao_percentual', '')::numeric, 0) else 0 end,
      instalacao = case when c.tipo = 'consumo' then trim(p->>'instalacao') end,
      faixa_mensal = case when c.tipo = 'consumo' then nullif(p->>'faixa_mensal', '')::numeric end,
      teto_anual = case when c.tipo = 'consumo' then nullif(p->>'teto_anual', '')::numeric end
     where c.id = v_id and c.tipo = v_tipo and c.situacao = 'ativo';
    get diagnostics n = row_count;
    if n = 0 then raise exception 'Conta não encontrada, encerrada ou sem permissão para alterar'; end if;
  end if;

  -- o rateio como a tela manda (divisão de último nível) e como está gravado, para comparar
  select coalesce(jsonb_agg(x order by x::text), '[]'::jsonb) into v_novo
    from (select jsonb_build_object('n', nullif(e.r->>'nucleo', ''), 'c', nullif(e.r->>'centro', ''), 'd', nullif(e.r->>'divisao', ''),
                                    'a', e.r->>'natureza', 'p', (e.r->>'percentual')::numeric) x
            from jsonb_array_elements(p->'rateio') e(r)) s;
  select coalesce(jsonb_agg(x order by x::text), '[]'::jsonb) into v_velho
    from (select jsonb_build_object('n', r.nucleo_economico_id::text, 'c', r.centro_custo_id::text,
                                    'd', coalesce(r.subdivisao_id, r.divisao_id)::text, 'a', r.natureza_id::text, 'p', r.percentual) x
            from erp.compromisso_rateios r where r.compromisso_id = v_id) s;
  if v_novo is distinct from v_velho then
    delete from erp.compromisso_rateios where compromisso_id = v_id;
    for l in select * from jsonb_array_elements(p->'rateio') loop
      v_div := nullif(l->>'divisao', '')::uuid;
      select coalesce(d.raiz_id, d.id) into v_raiz from erp.divisoes d where d.id = v_div;
      if v_div is not null and v_raiz is null then raise exception 'Divisão não encontrada'; end if;
      insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
      values (v_id, nullif(l->>'nucleo', '')::uuid, nullif(l->>'centro', '')::uuid, v_raiz,
              case when v_div is distinct from v_raiz then v_div end, (l->>'natureza')::uuid, (l->>'percentual')::numeric);
    end loop;
  end if;
  if not erp.rateio_completo('compromisso', v_id) then raise exception 'O rateio precisa somar 100%%'; end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa
-- ---------------------------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  foreach f in array array['api.contratos()', 'api.conta(uuid)', 'api.salvar_conta(jsonb)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
