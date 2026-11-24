-- A nota do mês de uma conta recorrente aprovada segue só o rito da conta (Moises, 23/nov/2026, no cartão "A nota
-- mensal de conta recorrente aprovada segue só o rito dela ou também as faixas do centro?": "Só o rito da conta").
--
-- O rito, por centro do rateio da nota:
--   - Contrato de serviço e assinatura: o gestor do centro, depois a AF (a AD ocupa a vaga da AF).
--   - Conta de consumo: fatura até X% acima da previsão do mês (padrão 30%, configurável) e o ano ainda dentro do teto:
--     direto a AF, a AO ou a AD (uma delas). Acima disso, ou passando do teto do ano: o gestor do centro primeiro,
--     depois a AF, a AO ou a AD.
--   - Sem gente para alguma vaga, vai ao master, como em toda alçada (nada é aprovado sem aprovador).
-- A nota continua somando no acumulado do mês do centro, para os outros títulos (a varredura de erp._fixar_alcada já a
-- conta: o título dela é aberto e do mesmo centro).
--
-- Quando o rito NÃO vale (a nota segue as faixas do centro, como antes):
--   - a conta não está ativa, não precisa de aprovação ou não está aprovada na versão atual;
--   - o título não é do fornecedor da conta, ou não é o título do fornecedor (imposto e caução seguem o caminho deles);
--   - alguma linha do rateio da nota não está no rateio aprovado da conta (núcleo, centro, divisão, subnível e natureza),
--     ou a nota tem linha sem centro;
--   - contrato e assinatura: a nota passa da previsão do mês, ou o contrato passa do valor total; sem previsão do mês
--     (contrato sem fim e sem calendário), também. Leitura minha, a confirmar com o Moises: a tolerância é só do consumo.
-- O que vale é o bruto da nota (antes de retenções e caução), que é o que a previsão do mês e o teto medem.
--
-- Vaga nova "AF_AO" (a AF, a AO ou a AD), só para o rito; não entra nas faixas da alçada. O rótulo da vaga AO_CENTRO
-- ("AO do centro"), que faltava, entra junto.
--
-- O mesmo corpo roda no bkm_dev (supabase/dev/ com o mesmo nome). Portabilidade: SQL e plpgsql padrão.

-- ---------------------------------------------------------------------------------------------
-- 1. A tolerância do consumo e a marca na alçada
-- ---------------------------------------------------------------------------------------------
alter table erp.regra_alcada_pagamento
  add column recorrente_tolerancia_pct numeric(5,2) not null default 30 check (recorrente_tolerancia_pct between 0 and 100);
comment on column erp.regra_alcada_pagamento.recorrente_tolerancia_pct is
  'Conta de consumo aprovada: a fatura até este % acima da previsão do mês (e o ano dentro do teto) vai direto à AF, AO ou AD';

alter table erp.titulo_alcadas add column compromisso_id uuid references erp.compromissos;
comment on column erp.titulo_alcadas.compromisso_id is
  'Preenchido quando a alçada é o rito da conta recorrente aprovada (sem faixa: alcada_id nulo)';
alter table erp.titulo_alcadas
  add constraint titulo_alcadas_rito check (compromisso_id is null or (alcada_id is null and centro_custo_id is not null));

-- ---------------------------------------------------------------------------------------------
-- 2. A vaga AF_AO e os rótulos
-- ---------------------------------------------------------------------------------------------
create or replace function erp._ocupa_vaga(p_vaga text, p_centro uuid, p_user uuid) returns boolean language plpgsql stable as $$
begin
  if not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then return false; end if;
  return case
    when p_vaga = 'AREA' then exists (select 1 from erp.centro_aprovadores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga = 'DIRETOR_AREA' then exists (select 1 from erp.centro_diretores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga in ('AF','AO') then exists (select 1 from erp.listas_financeiro where lista in (p_vaga, 'AD') and user_id = p_user)
    when p_vaga = 'AF_AO' then exists (select 1 from erp.listas_financeiro where lista in ('AF','AO','AD') and user_id = p_user)
    when p_vaga = 'AO_CENTRO' then exists (select 1 from erp.listas_financeiro
                                            where user_id = p_user and (lista = 'AD' or (lista = 'AO' and p_centro = any(centros))))
    when p_vaga = 'AD' then exists (select 1 from erp.listas_financeiro where lista = 'AD' and user_id = p_user)
    when p_vaga = 'PJ' then erp.ve_pj(p_user)          -- o master ou um designado (Moises, 18/11/2026)
    when p_vaga like 'P:%' then substr(p_vaga, 3)::uuid = p_user
    else false end;
end $$;

create or replace function erp.rotulo_vaga(p_vaga text) returns text language sql stable set search_path = pg_catalog, pg_temp as $$
  select case p_vaga
    when 'AREA' then 'gestor do centro' when 'DIRETOR_AREA' then 'diretor da área' when 'FIN' then 'AF ou AD'
    when 'AF' then 'AF' when 'AO' then 'AO' when 'AD' then 'AD' when 'PJ' then 'master ou designado do PJ'
    when 'AF_AO' then 'AF, AO ou AD' when 'AO_CENTRO' then 'AO do centro'
    when 'MASTER' then 'master'
    else case when p_vaga like 'P:%' then coalesce((select u.nome from erp.usuarios u where u.id::text = substr(p_vaga, 3)), 'pessoa indicada')
              else p_vaga end end $$;

-- ---------------------------------------------------------------------------------------------
-- 3. O rito da conta
-- ---------------------------------------------------------------------------------------------
-- Fixa a alçada do título pelo rito da conta, quando ele vale; devolve false (e não grava nada) quando não vale.
create function erp._rito_da_conta(t erp.titulos) returns boolean language plpgsql as $$
declare c erp.compromissos; v_bruto numeric; v_prev numeric; v_tol numeric; v_outras numeric;
        v_fases text[]; cc record; v_valor numeric; v_falta text[];
begin
  if t.compromisso_id is null or t.tipo <> 'fornecedor' then return false; end if;
  -- trava a conta: duas notas dela confirmadas juntas não passam as duas pelo teto
  select * into c from erp.compromissos where id = t.compromisso_id for update;
  if c.tipo not in ('contrato','assinatura','consumo') or c.situacao <> 'ativo' or c.pessoa_id is distinct from t.pessoa_id
     or not erp.compromisso_aprovado(c.id) then
    return false;
  end if;
  -- toda linha da nota tem de estar no rateio aprovado da conta (o percentual pode mudar)
  if exists (select 1 from erp.titulo_rateios tr where tr.titulo_id = t.id
              and (tr.centro_custo_id is null
                   or not exists (select 1 from erp.compromisso_rateios cr
                                   where cr.compromisso_id = c.id
                                     and cr.nucleo_economico_id is not distinct from tr.nucleo_economico_id
                                     and cr.centro_custo_id = tr.centro_custo_id
                                     and cr.divisao_id is not distinct from tr.divisao_id
                                     and cr.subdivisao_id is not distinct from tr.subdivisao_id
                                     and cr.natureza_id = tr.natureza_id))) then
    return false;
  end if;
  v_bruto := coalesce((select d.valor_bruto from erp.documentos_fiscais d where d.id = t.documento_id), t.valor);
  v_prev := erp.valor_do_mes(c.id, t.competencia);
  if v_prev is null then return false; end if;
  if c.tipo = 'consumo' then
    v_tol := (select recorrente_tolerancia_pct from erp.regra_alcada_pagamento);
    -- as outras notas da conta no mesmo ano (lançadas, não canceladas)
    select coalesce(sum(d.valor_bruto), 0) into v_outras from erp.documentos_fiscais d
     where d.compromisso_id = c.id and d.situacao = 'lancado' and d.id is distinct from t.documento_id
       and extract(year from d.competencia) = extract(year from t.competencia);
    v_fases := case when v_bruto <= round(v_prev * (1 + v_tol / 100), 2) and v_outras + v_bruto <= c.teto_anual
                    then array['AF_AO'] else array['AREA','AF_AO'] end;
  else
    if v_bruto > v_prev then return false; end if;
    if c.valor_total is not null then
      select coalesce(sum(d.valor_bruto), 0) into v_outras from erp.documentos_fiscais d
       where d.compromisso_id = c.id and d.situacao = 'lancado' and d.id is distinct from t.documento_id;
      if v_outras + v_bruto > c.valor_total then return false; end if;
    end if;
    v_fases := array['AREA','AF'];
  end if;
  for cc in select distinct tr.centro_custo_id from erp.titulo_rateios tr where tr.titulo_id = t.id order by 1 loop
    select round(coalesce(sum(t.valor * tr.percentual / 100 - erp.cobertura(tr.id)), 0), 2) into v_valor
      from erp.titulo_rateios tr where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id;
    v_falta := erp._vagas_sem_gente(v_fases, cc.centro_custo_id, t.criado_por);
    insert into erp.titulo_alcadas (titulo_id, rodada, centro_custo_id, divisao_id, fases, paralelo, valor_no_centro, acumulado, titulos,
                                    alcada_id, falta_aprovadores, vagas_sem_gente, compromisso_id)
    values (t.id, t.rodada, cc.centro_custo_id, null, v_fases, false, v_valor, v_valor, array[t.id], null,
            cardinality(v_falta) > 0, v_falta, c.id);
    if cardinality(v_falta) > 0 then
      perform erp.registrar_evento('alcada_falta_aprovadores', 'titulos', t.id::text, null, cc.centro_custo_id,
        jsonb_build_object('titulo_id', t.id, 'rodada', t.rodada, 'fases', v_fases, 'vagas_sem_gente', v_falta,
                           'valor_no_centro', v_valor, 'valor', t.valor, 'compromisso_id', c.id,
                           'motivo', 'Faltam aprovadores qualificados: o título vai ao master'));
    end if;
  end loop;
  return true;
end $$;
revoke execute on function erp._rito_da_conta(erp.titulos) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp._rito_da_conta(erp.titulos) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke execute on function erp._rito_da_conta(erp.titulos) from authenticated; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke execute on function erp._rito_da_conta(erp.titulos) from service_role; end if;
end $$;
grant execute on function erp._rito_da_conta(erp.titulos) to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- Mesmo corpo do 20261118000400, com o rito da conta depois do adiantamento e antes das faixas.
create or replace function erp._definir_alcada(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos; cc record; dv record; f erp.alcadas_pagamento; v_centro boolean; v_sem numeric;
begin
  select * into t from erp.titulos where id = p_titulo;
  if t.sentido <> 'pagar' then return; end if;
  -- título com linha PJ: uma alçada só, a do PJ (o master ou um designado; Moises, 18/11/2026)
  if erp.titulo_pj(t.id) then perform erp._fixar_alcada_sem_centro(t, array['PJ'], null, t.valor); return; end if;
  -- imposto: a AF aprova; societário: a AD (Moises, 18/11/2026). Uma alçada sem centro, sem faixa.
  if t.tipo = 'imposto' then perform erp._fixar_alcada_sem_centro(t, array['AF'], null, t.valor); return; end if;
  if t.tipo = 'societario' then perform erp._fixar_alcada_sem_centro(t, array['AD'], null, t.valor); return; end if;
  -- dois títulos do mesmo centro confirmados ao mesmo tempo se enxergam (S-060): trava os
  -- centros do rateio, sempre na mesma ordem, até o fim da transação
  perform 1 from erp.centros_custo c
   where c.id in (select tr.centro_custo_id from erp.titulo_rateios tr where tr.titulo_id = t.id)
   order by c.id for update;
  perform erp._cobrir_adiantamento(t);
  -- a nota do mês da conta recorrente aprovada: só o rito da conta (Moises, 23/11/2026)
  if erp._rito_da_conta(t) then return; end if;
  for cc in select distinct tr.centro_custo_id from erp.titulo_rateios tr
            where tr.titulo_id = t.id and tr.centro_custo_id is not null order by tr.centro_custo_id loop
    -- a alçada da divisão com faixas próprias; a faixa diz se a linha passa também pelo centro
    v_centro := false;
    for dv in select distinct tr.divisao_id from erp.titulo_rateios tr
               where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                 and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id)
               order by tr.divisao_id loop
      f := erp._fixar_alcada(t, cc.centro_custo_id, dv.divisao_id);
      v_centro := v_centro or f.passa_pelo_centro;
    end loop;
    -- a alçada do centro: as linhas sem divisão com faixas próprias, ou a faixa da divisão que
    -- manda passar pelo centro. Centro sem gestor e sem faixas próprias também entra, pelas faixas
    -- gerais: a vaga sem gente vai ao master (nada é aprovado sem aprovador, Moises, 18/11/2026)
    if v_centro
       or exists (select 1 from erp.titulo_rateios tr
                   where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                     and not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id)) then
      perform erp._fixar_alcada(t, cc.centro_custo_id, null);
    end if;
  end loop;
  -- a parte sem centro (natureza de movimentação, como 10.01 Bens da empresa): AO + AF, ou a AD
  -- sozinha, em qualquer valor (Moises, 18/11/2026)
  select round(sum(t.valor * tr.percentual / 100), 2) into v_sem from erp.titulo_rateios tr
   where tr.titulo_id = t.id and tr.centro_custo_id is null;
  if v_sem is not null then perform erp._fixar_alcada_sem_centro(t, array['AF','AO'], 'AD', v_sem); end if;
end $$;
