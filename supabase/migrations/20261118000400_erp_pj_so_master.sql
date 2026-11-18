-- PJ só com o master e quem ele designar (Moises, 18/11/2026: "AF e AO não veem os PJ, nem o AD. Vai
-- ficar com o Master e quem ele designar que pode ver também, sem acesso por cargo ou papel
-- predeterminado").
--
-- PJ = linha de natureza restrita (a marca restrita da natureza ou de um galho acima dela).
-- 1. Quem vê: o master e as pessoas que ele designa pelo nome (erp.designados_pj). Ninguém mais vê pelo
--    papel (AF, AO, AD, diretor), pelo modelo de acesso nem pela exceção de natureza: as liberações de
--    natureza restrita por modelo ou por exceção deixam de valer. O designado vê o PJ de todos os
--    núcleos e centros; para lançar, precisa também do acesso de lançar no centro.
-- 2. Quem aprova: título com alguma linha PJ e previsão de natureza PJ têm uma alçada só, a vaga PJ,
--    que o master ou um designado ocupa (quem lançou não aprova, salvo o master). Sem designado, vai
--    ao master. As vagas de papel (gestor, AF, AO, AD, diretor) não entram.
-- 3. O PJ não conta no acumulado do mês do centro (a soma "outros títulos sem acesso" mostraria o total).
-- 4. Pagamento que quita título PJ: o financeiro (AF, AO, AD) não o vê.
-- 5. Avisos sobre título ou previsão PJ só vão a quem vê o PJ.
-- 6. Previsão PJ não vai ao Sienge como linha PRV (a linha apareceria ao financeiro no Sienge e na página).
-- 7. Designar e retirar: só o master, na hora, com motivo e histórico. Mudar a marca restrita de uma
--    natureza (ou mover a natureza para dentro ou para fora de um galho restrito): só com o voto do master.
-- O título PJ continua indo ao Sienge para o pagamento: lá, quem tem acesso ao contas a pagar o vê
-- (limitação do Sienge; perfis do Sienge, S-021).
-- Portabilidade: SQL puro.

-- ---------------------------------------------------------------------------------------------
-- Os designados
-- ---------------------------------------------------------------------------------------------
create table erp.designados_pj (
  user_id uuid primary key references erp.usuarios,
  motivo  text not null check (length(trim(motivo)) > 0),
  por     uuid not null references erp.usuarios,
  em      timestamptz not null default clock_timestamp()
);
create table erp.designados_pj_historico (
  id      bigint generated always as identity primary key,
  user_id uuid not null references erp.usuarios,
  acao    text not null check (acao in ('designado','retirado')),
  motivo  text not null,
  por     uuid not null references erp.usuarios,
  em      timestamptz not null default clock_timestamp()
);

-- Vê o PJ: o master, ou um designado ativo (nem só da sucessão).
create function erp.ve_pj(p_user uuid) returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select p_user is not null and (
    exists (select 1 from erp.master m where m.user_id = p_user)
    or exists (select 1 from erp.designados_pj d join erp.usuarios u on u.id = d.user_id
                where d.user_id = p_user and u.ativo and not u.so_sucessao)) $$;

-- O título tem linha PJ? A previsão é PJ?
create function erp.titulo_pj(p_titulo uuid) returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_titulo and erp.natureza_restrita(r.natureza_id)) $$;
create function erp.previsao_pj(p_previsao uuid) returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select exists (select 1 from erp.previsoes p where p.id = p_previsao and erp.natureza_restrita(p.natureza_id)) $$;
-- O registro de um evento é PJ? (título ou previsão)
create function erp.registro_pj(p_tabela text, p_registro text) returns boolean language plpgsql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v uuid;
begin
  if p_tabela not in ('titulos','previsoes') then return false; end if;
  begin v := p_registro::uuid; exception when others then return false; end;
  return case p_tabela when 'titulos' then erp.titulo_pj(v) else erp.previsao_pj(v) end;
end $$;

-- Só o master designa e retira, na hora, com motivo.
create function erp.designar_pj(p_pessoa uuid, p_motivo text) returns void language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if not erp.sou_master() then raise exception 'Só o master designa quem vê o PJ'; end if;
  if length(trim(coalesce(p_motivo, ''))) = 0 then raise exception 'Designar para o PJ precisa de motivo'; end if;
  if not exists (select 1 from erp.usuarios where id = p_pessoa and ativo and not so_sucessao) then
    raise exception 'Só um usuário ativo do ERP é designado para o PJ';
  end if;
  if exists (select 1 from erp.designados_pj where user_id = p_pessoa) then raise exception 'Esta pessoa já vê o PJ'; end if;
  insert into erp.designados_pj (user_id, motivo, por) values (p_pessoa, trim(p_motivo), erp.eu());
  insert into erp.designados_pj_historico (user_id, acao, motivo, por) values (p_pessoa, 'designado', trim(p_motivo), erp.eu());
end $$;
create function erp.retirar_pj(p_pessoa uuid, p_motivo text) returns void language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if not erp.sou_master() then raise exception 'Só o master retira quem vê o PJ'; end if;
  if length(trim(coalesce(p_motivo, ''))) = 0 then raise exception 'Retirar do PJ precisa de motivo'; end if;
  delete from erp.designados_pj where user_id = p_pessoa;
  if not found then raise exception 'Esta pessoa não está designada para o PJ'; end if;
  insert into erp.designados_pj_historico (user_id, acao, motivo, por) values (p_pessoa, 'retirado', trim(p_motivo), erp.eu());
end $$;

-- ---------------------------------------------------------------------------------------------
-- Quem vê
-- ---------------------------------------------------------------------------------------------
-- A natureza restrita só com o master ou um designado (as liberações por modelo e por exceção saem).
create or replace function erp.natureza_liberada(p_user uuid, p_nucleo uuid, p_centro uuid, p_natureza uuid, p_divisao uuid default null)
returns boolean language plpgsql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if exists (select 1 from erp.excecoes_natureza e
              where e.user_id = p_user and e.efeito = 'bloquear' and (e.fim is null or current_date <= e.fim)
                and (e.centro_custo_id is null or e.centro_custo_id = p_centro)
                and e.natureza_id in (select erp.galhos_acima(p_natureza))) then
    return false;
  end if;
  if erp.natureza_restrita(p_natureza) then return erp.ve_pj(p_user); end if;
  return true;
end $$;

-- A linha PJ: quem vê o PJ (com o bloqueio da pessoa valendo), sem depender do acesso ao núcleo e ao centro.
create or replace function erp.ve_linha(p_user uuid, p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language plpgsql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare a record;
begin
  if p_natureza is not null and erp.natureza_restrita(p_natureza) then
    return erp.natureza_liberada(p_user, p_nucleo, p_centro, p_natureza, p_divisao);
  end if;
  select * into a from erp.acesso(p_user, p_nucleo, p_centro, p_divisao);
  if not (a.ve_tudo or (a.lanca and p_autor = p_user)) then return false; end if;
  return p_natureza is null or erp.natureza_liberada(p_user, p_nucleo, p_centro, p_natureza, p_divisao);
end $$;

-- A linha sem núcleo e sem centro: a diretoria e o financeiro; a PJ, só quem vê o PJ.
create or replace function erp._ve(p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select case when p_natureza is not null and erp.natureza_restrita(p_natureza) then erp.ve_pj(erp.eu())
              when p_nucleo is null and p_centro is null
              then coalesce(erp.meu_papel(), '') = 'diretor' or erp.financeiro()
              else erp.ve_linha(erp.eu(), p_nucleo, p_centro, p_natureza, p_autor, p_divisao) end $$;

-- Quem aprova vê o título; no título PJ, só quem vê o PJ.
create or replace function erp.aprovo_titulo(p_titulo uuid) returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select erp.membro() and (not erp.titulo_pj(p_titulo) or erp.ve_pj(erp.eu())) and (
    exists (select 1 from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
             where a.titulo_id = p_titulo
               and (erp.estou_nas_listas(a.fases) or coalesce(erp.meu_papel(), '') = 'diretor'
                    or exists (select 1 from unnest(array_append(a.fases, a.basta)) e where erp._ocupa_vaga(e, a.centro_custo_id, erp.eu()))))
    or exists (select 1 from erp.titulo_aprovacoes x where x.titulo_id = p_titulo and x.por = erp.eu())) $$;

-- Pagamento: o financeiro deixa de ver o que quita título que ele não vê (PJ).
create or replace function erp._vejo_pagamento(p_id uuid, p_nucleo uuid, p_centro uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select erp.membro() and (
    erp.sou_master()
    or ((erp.financeiro() or p_autor = erp.eu()
         or (p_nucleo is not null and erp._ve(p_nucleo, p_centro, null, p_autor, p_divisao))
         or exists (select 1 from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id
                     where q.pagamento_id = p_id and erp.vejo_titulo(pa.titulo_id)))
        and not exists (select 1 from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id
                         where q.pagamento_id = p_id and not erp.vejo_titulo(pa.titulo_id)))) $$;

-- ---------------------------------------------------------------------------------------------
-- Quem aprova
-- ---------------------------------------------------------------------------------------------
create or replace function erp._ocupa_vaga(p_vaga text, p_centro uuid, p_user uuid) returns boolean language plpgsql stable as $$
begin
  if not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then return false; end if;
  return case
    when p_vaga = 'AREA' then exists (select 1 from erp.centro_aprovadores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga = 'DIRETOR_AREA' then exists (select 1 from erp.centro_diretores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga in ('AF','AO') then exists (select 1 from erp.listas_financeiro where lista in (p_vaga, 'AD') and user_id = p_user)
    when p_vaga = 'AD' then exists (select 1 from erp.listas_financeiro where lista = 'AD' and user_id = p_user)
    when p_vaga = 'PJ' then erp.ve_pj(p_user)          -- o master ou um designado (Moises, 18/11/2026)
    when p_vaga like 'P:%' then substr(p_vaga, 3)::uuid = p_user
    else false end;
end $$;

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

-- A previsão PJ: a vaga PJ, sem centro.
create function erp._fixar_alcada_previsao_pj(p erp.previsoes) returns void language plpgsql as $$
declare v_falta text[];
begin
  v_falta := erp._vagas_sem_gente(array['PJ'], null, p.criada_por);
  insert into erp.previsao_alcadas (previsao_id, centro_custo_id, divisao_id, fases, paralelo, valor, acumulado, alcada_id,
                                    falta_aprovadores, vagas_sem_gente)
  values (p.id, null, null, array['PJ'], true, p.valor, p.valor, null, cardinality(v_falta) > 0, v_falta);
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'previsoes', p.id::text, null, null,
      jsonb_build_object('previsao_id', p.id, 'fases', array['PJ'], 'vagas_sem_gente', v_falta,
                         'motivo', 'Faltam aprovadores qualificados: a previsão vai ao master'));
  end if;
end $$;

create or replace function erp.tg_previsao_alcada() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare f erp.alcadas_pagamento; v_centro boolean := false;
begin
  if new.sentido <> 'pagar' or erp.previsao_do_contrato(new.id) is not null
     or new.origem_previsao_id is not null then return null; end if;
  if erp.natureza_restrita(new.natureza_id) then
    perform erp._fixar_alcada_previsao_pj(new);
    return null;
  end if;
  if new.centro_custo_id is null then
    perform erp._fixar_alcada_previsao_sem_centro(new);
    return null;
  end if;
  perform 1 from erp.centros_custo where id = new.centro_custo_id for update;   -- como no título (S-060)
  if new.divisao_id is not null and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    f := erp._fixar_alcada_previsao(new, new.centro_custo_id, new.divisao_id);
    v_centro := coalesce(f.passa_pelo_centro, true);
  end if;
  -- centro sem gestor e sem faixas próprias também entra: nada é aprovado sem aprovador (Moises, 18/11/2026)
  if v_centro
     or new.divisao_id is null or not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    perform erp._fixar_alcada_previsao(new, new.centro_custo_id, null);
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------
-- O acumulado do mês do centro sem o PJ
-- ---------------------------------------------------------------------------------------------
create or replace function erp._previsoes_no_acumulado(p_empresa uuid, p_pessoa uuid, p_mes date, p_centro uuid, p_divisao uuid,
                                            p_nucleo uuid, p_excluir uuid) returns numeric language sql stable as $$
  select coalesce(sum(erp._previsao_saldo(q.id)), 0)
    from erp.previsoes q, erp.regra_alcada_pagamento g
   where q.sentido = 'pagar' and q.situacao = 'aberta' and erp.mes(q.competencia) = erp.mes(p_mes)
     and q.id is distinct from p_excluir
     and not erp.natureza_restrita(q.natureza_id)
     and ((q.centro_custo_id = p_centro and (p_divisao is null or q.divisao_id = p_divisao))
          or (g.soma_fornecedor and p_pessoa is not null and q.pessoa_id = p_pessoa))
     and (g.acumulado = 'centro' or q.empresa_id = p_empresa)
     and (g.acumulado <> 'nucleo_centro' or q.centro_custo_id <> p_centro
          or (p_divisao is not null and q.divisao_id is distinct from p_divisao)
          or q.nucleo_economico_id is not distinct from p_nucleo) $$;

create or replace function erp._fixar_alcada(t erp.titulos, p_centro uuid, p_divisao uuid) returns erp.alcadas_pagamento
language plpgsql as $$
declare v_modo text := (select acumulado from erp.regra_alcada_pagamento);
        v_forn boolean := (select soma_fornecedor from erp.regra_alcada_pagamento);
        r record; v_soma numeric; v_ids uuid[]; v_acum numeric; v_titulos uuid[]; v_valor numeric;
        f erp.alcadas_pagamento; v_falta text[];
begin
  for r in select distinct tr.nucleo_economico_id from erp.titulo_rateios tr
            where tr.titulo_id = t.id and tr.centro_custo_id = p_centro
              and (p_divisao is null or tr.divisao_id = p_divisao) loop
    -- a parte de cada título no centro (ou na divisão); com soma_fornecedor, o mesmo fornecedor conta inteiro;
    -- o título com linha PJ fica de fora (Moises, 18/11/2026)
    select round(coalesce(sum(t2.valor * r2.percentual / 100 - erp.cobertura(r2.id)), 0), 2), array_agg(distinct t2.id) into v_soma, v_ids
      from erp.titulos t2 join erp.titulo_rateios r2 on r2.titulo_id = t2.id
     where ((r2.centro_custo_id = p_centro and (p_divisao is null or r2.divisao_id = p_divisao))
            or (v_forn and t2.pessoa_id = t.pessoa_id))
       and t2.sentido = 'pagar' and t2.tipo not in ('imposto','societario')
       and not erp.titulo_pj(t2.id)
       and (t2.situacao in ('aberto','quitado') or t2.id = t.id)
       and erp.mes(t2.competencia) = erp.mes(t.competencia)
       and (v_modo = 'centro' or t2.empresa_id = t.empresa_id)
       and (v_modo <> 'nucleo_centro' or r2.centro_custo_id <> p_centro
            or (p_divisao is not null and r2.divisao_id is distinct from p_divisao)
            or r2.nucleo_economico_id is not distinct from r.nucleo_economico_id);
    -- as previsões abertas do mês, pelo saldo (a parte já consumida por nota está no título)
    v_soma := v_soma + erp._previsoes_no_acumulado(t.empresa_id, t.pessoa_id, t.competencia, p_centro, p_divisao,
                                                   r.nucleo_economico_id, null);
    if v_acum is null or v_soma > v_acum then v_acum := v_soma; v_titulos := v_ids; end if;
  end loop;
  select round(coalesce(sum(t.valor * tr.percentual / 100 - erp.cobertura(tr.id)), 0), 2) into v_valor
    from erp.titulo_rateios tr where tr.titulo_id = t.id and tr.centro_custo_id = p_centro
                                 and (p_divisao is null or tr.divisao_id = p_divisao);
  -- o limite do título olha o título inteiro em cada centro: dividir no rateio não baixa a faixa
  -- (S-098, Moises, 15/11/2026); o acumulado do mês é o do centro (ou o da divisão)
  f := erp._faixa_alcada(p_centro, p_divisao, v_acum, t.valor);
  if f.id is null then raise exception 'Não há alçada de pagamento configurada para %', v_acum; end if;
  v_falta := erp._vagas_sem_gente(f.fases, p_centro, t.criado_por);
  insert into erp.titulo_alcadas (titulo_id, rodada, centro_custo_id, divisao_id, fases, paralelo, valor_no_centro, acumulado, titulos,
                                  alcada_id, falta_aprovadores, vagas_sem_gente)
  values (t.id, t.rodada, p_centro, p_divisao, f.fases, f.paralelo, v_valor, v_acum, v_titulos, f.id,
          cardinality(v_falta) > 0, v_falta);
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'titulos', t.id::text, null, p_centro,
      jsonb_build_object('titulo_id', t.id, 'rodada', t.rodada, 'divisao_id', p_divisao, 'fases', f.fases, 'vagas_sem_gente', v_falta,
                         'acumulado', v_acum, 'valor_no_centro', v_valor, 'valor', t.valor,
                         'motivo', 'Faltam aprovadores qualificados: o título vai ao master'));
  end if;
  return f;
end $$;

create or replace function erp._fixar_alcada_previsao(p erp.previsoes, p_centro uuid, p_divisao uuid) returns erp.alcadas_pagamento
language plpgsql as $$
declare v_modo text := (select acumulado from erp.regra_alcada_pagamento);
        v_forn boolean := (select soma_fornecedor from erp.regra_alcada_pagamento);
        v_titulos numeric; v_acum numeric; f erp.alcadas_pagamento; v_falta text[]; v_fases text[]; v_paralelo boolean;
begin
  select round(coalesce(sum(t2.valor * r2.percentual / 100 - erp.cobertura(r2.id)), 0), 2) into v_titulos
    from erp.titulos t2 join erp.titulo_rateios r2 on r2.titulo_id = t2.id
   where ((r2.centro_custo_id = p_centro and (p_divisao is null or r2.divisao_id = p_divisao))
          or (v_forn and p.pessoa_id is not null and t2.pessoa_id = p.pessoa_id))
     and t2.sentido = 'pagar' and t2.tipo not in ('imposto','societario') and t2.situacao in ('aberto','quitado')
     and not erp.titulo_pj(t2.id)
     and erp.mes(t2.competencia) = erp.mes(p.competencia)
     and (v_modo = 'centro' or t2.empresa_id = p.empresa_id)
     and (v_modo <> 'nucleo_centro' or r2.centro_custo_id <> p_centro
          or (p_divisao is not null and r2.divisao_id is distinct from p_divisao)
          or r2.nucleo_economico_id is not distinct from p.nucleo_economico_id);
  v_acum := v_titulos + erp._previsoes_no_acumulado(p.empresa_id, p.pessoa_id, p.competencia, p_centro, p_divisao,
                                                    p.nucleo_economico_id, p.id) + p.valor;
  f := erp._faixa_alcada(p_centro, p_divisao, v_acum, p.valor);
  -- sem faixa configurada, só o master aprova
  v_fases := coalesce(f.fases, array['MASTER']);
  v_paralelo := coalesce(f.paralelo, true);
  v_falta := case when f.id is null then array['MASTER'] else erp._vagas_sem_gente(v_fases, p_centro, p.criada_por) end;
  insert into erp.previsao_alcadas (previsao_id, centro_custo_id, divisao_id, fases, paralelo, valor, acumulado, alcada_id,
                                    falta_aprovadores, vagas_sem_gente)
  values (p.id, p_centro, p_divisao, v_fases, v_paralelo, p.valor, v_acum, f.id, cardinality(v_falta) > 0, v_falta);
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'previsoes', p.id::text, null, p_centro,
      jsonb_build_object('previsao_id', p.id, 'divisao_id', p_divisao, 'fases', v_fases, 'vagas_sem_gente', v_falta,
                         'acumulado', v_acum, 'valor', p.valor,
                         'motivo', case when f.id is null then 'Não há faixa de alçada para a previsão: vai ao master'
                                        else 'Faltam aprovadores qualificados: a previsão vai ao master' end));
  end if;
  return f;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Avisos: o de título ou previsão PJ só para quem vê o PJ
-- ---------------------------------------------------------------------------------------------
create or replace function erp.tg_distribuir_evento() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare t erp.tipos_evento; v_detalhe text; v_pediu uuid; r record; v_id bigint; v_div uuid[]; v_pj boolean;
begin
  select * into t from erp.tipos_evento where codigo = new.tipo;
  v_div := erp._divisoes_evento(new.centro_id, new.dados);
  v_pj := erp.registro_pj(new.tabela, new.registro);
  begin v_pediu := (new.dados->>'pedida_por')::uuid; exception when others then v_pediu := null; end;
  -- o motivo, sem os dados do evento
  v_detalhe := concat_ws(' · ',
    case when new.tipo = 'alcada_falta_aprovadores'
           or (coalesce((new.dados->>'falta_aprovadores')::boolean, false)
               and new.tabela not in ('regras_notificacao','tipos_evento'))
         then 'Veio para você por falta de aprovadores mínimos qualificados' end,
    case when new.tipo <> 'alcada_falta_aprovadores' and nullif(trim(new.dados->>'motivo'), '') is not null
         then 'Motivo: ' || (new.dados->>'motivo') end);

  for r in
    with destinos as (
      select d.user_id, g.email, g.whatsapp
        from erp.regras_notificacao g
        cross join lateral (
          select g.user_id where g.destino = 'pessoa'
          union select u.id from erp.usuarios u where g.destino = 'papel' and u.papel = g.papel
          union select l.user_id from erp.listas_financeiro l where g.destino = 'lista' and l.lista = g.lista
          union select a.user_id from erp.centro_aprovadores a where g.destino = 'gestor_centro' and a.centro_custo_id = new.centro_id
          union select a.user_id from erp.centro_diretores a where g.destino = 'diretores_centro' and a.centro_custo_id = new.centro_id
          union select v_pediu where g.destino = 'quem_pediu'
          union select a.user_id from erp.aprovadores_config a where g.destino = 'aprovadores_config' and a.tabela = new.tabela
          -- o pedido que vai ao master: quem aprova é ele
          union select m.user_id from erp.master m where g.destino = 'aprovadores_config' and new.dados->>'aprovacao' = 'master'
          union select u.id from erp.usuarios u where g.destino = 'administradores' and u.administrador
          union select m.user_id from erp.master m where g.destino = 'master') d(user_id)
       where g.tipo = new.tipo and g.ativa
         and (g.nucleo_id is null or g.nucleo_id = new.nucleo_id)
         and (g.centro_id is null or g.centro_id = new.centro_id)
      union all
      -- crítico: o master sempre, por e-mail e WhatsApp
      select m.user_id, true, true from erp.master m where t.critico)
    select d.user_id,
           bool_or(d.email) or t.critico as email,          -- crítico não sai do e-mail
           bool_or(d.whatsapp) as whatsapp
      from destinos d join erp.usuarios u on u.id = d.user_id and u.ativo and not u.so_sucessao
     where d.user_id is distinct from new.por                -- quem agiu não é avisado do que fez
       -- título ou previsão PJ: só quem vê o PJ (Moises, 18/11/2026)
       and (not v_pj or erp.ve_pj(d.user_id))
       and (v_pj
            or case when cardinality(v_div) = 0 then erp._ve_evento(d.user_id, new.nucleo_id, new.centro_id)
                    else exists (select 1 from unnest(v_div) x(div) where erp._ve_evento(d.user_id, new.nucleo_id, new.centro_id, x.div)) end)
     group by d.user_id
  loop
    insert into erp.notificacoes (evento_id, user_id, tipo, critico, titulo, detalhe)
    values (new.id, r.user_id, new.tipo, t.critico, t.rotulo, nullif(v_detalhe, ''))
    returning id into v_id;
    insert into erp.envios_notificacao (notificacao_id, canal)
    select v_id, c.canal from (values ('email', r.email), ('whatsapp', r.whatsapp)) c(canal, liga)
     where c.liga
       and (c.canal = 'email' and t.critico
            or not exists (select 1 from erp.preferencias_notificacao p
                            where p.user_id = r.user_id and p.tipo = new.tipo and p.canal = c.canal));
  end loop;
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Previsão PJ fora do Sienge e da página das PRV
-- ---------------------------------------------------------------------------------------------
create function erp.tg_sienge_previsao_pj() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if erp.previsao_pj(new.previsao_id) then return null; end if;   -- a previsão PJ não vira linha PRV
  return new;
end $$;
create trigger t_previsao_pj before insert on erp.sienge_previsoes
  for each row execute function erp.tg_sienge_previsao_pj();

create or replace function erp.prv_apagar_pagina()
returns table (empresa_sienge text, titulo_sienge int, documento text, valor numeric, data_prevista date,
               na_lista_desde timestamptz, conferido_em timestamptz, situacao_previsao text)
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
begin
  if not coalesce(erp.login_bkm(), false) then
    raise exception 'Entre com a conta Google da BKM' using errcode = '42501';
  end if;
  return query
  select e.codigo::text, s.sienge_id, 'PRV-' || upper(left(replace(s.previsao_id::text, '-', ''), 12)),
         p.valor, p.data_prevista, s.apagar_desde, s.conferido_em, p.situacao::text
    from erp.sienge_previsoes s
    join erp.previsoes p on p.id = s.previsao_id
    left join erp.codigos_externos e on e.sistema = 'sienge' and e.tabela = 'empresas' and e.registro_id = p.empresa_id
   where s.apagar_desde is not null and s.apagado_em is null
     and not erp.natureza_restrita(p.natureza_id)
   order by s.apagar_desde, s.sienge_id;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A marca restrita só com o master
-- ---------------------------------------------------------------------------------------------
-- O pedido que muda a marca restrita de uma natureza, ou a leva para dentro ou para fora de um galho
-- restrito, passa a depender do voto do master (o master, pedindo, faz na hora).
create function erp.tg_mudanca_pj() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
begin
  if new.tabela <> 'naturezas' or erp.sou_master() then return new; end if;
  if (new.dados->>'restrita') is distinct from (new.antes->>'restrita')
     or ((new.dados->>'mae_id') is distinct from (new.antes->>'mae_id')
         and coalesce(erp.natureza_restrita((new.dados->>'mae_id')::uuid), false)
             <> coalesce(erp.natureza_restrita((new.antes->>'mae_id')::uuid), false)) then
    if new.aprovacao = 'nenhuma' then raise exception 'Só o master muda o que é PJ (a marca restrita da natureza)'; end if;
    new.aprovacao := 'master';
    new.minimo := 1;
  end if;
  return new;
end $$;
create trigger t_mudanca_pj before insert on erp.mudancas_acesso
  for each row execute function erp.tg_mudanca_pj();

-- ---------------------------------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['designados_pj','designados_pj_historico'] loop
    execute format('revoke all on erp.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
    execute format('revoke all on erp.%I from authenticated', t);
    execute format('alter table erp.%I enable row level security', t);
    execute format('alter table erp.%I force row level security', t);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
    execute format('create policy operacao on erp.%I to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true)', t);
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
    execute format('grant select, insert, update, delete on erp.%I to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso', t);
    execute format('grant select on erp.%I to erp_conferencia', t);
  end loop;
  -- as funções novas: só os papéis do banco
  foreach f in array array['erp.ve_pj(uuid)'::regprocedure, 'erp.titulo_pj(uuid)'::regprocedure, 'erp.previsao_pj(uuid)'::regprocedure,
                           'erp.registro_pj(text, text)'::regprocedure, 'erp._fixar_alcada_previsao_pj(erp.previsoes)'::regprocedure,
                           'erp.tg_sienge_previsao_pj()'::regprocedure, 'erp.tg_mudanca_pj()'::regprocedure,
                           'erp.designar_pj(uuid, text)'::regprocedure, 'erp.retirar_pj(uuid, text)'::regprocedure] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
end $$;
-- donos: a leitura (erp_conferencia lê tudo); designar e retirar gravam (erp_acesso); os gatilhos
alter function erp.ve_pj(uuid) owner to erp_conferencia;
alter function erp.titulo_pj(uuid) owner to erp_conferencia;
alter function erp.previsao_pj(uuid) owner to erp_conferencia;
alter function erp.registro_pj(text, text) owner to erp_conferencia;
alter function erp.tg_sienge_previsao_pj() owner to erp_conferencia;
alter function erp.tg_mudanca_pj() owner to erp_conferencia;
alter function erp.designar_pj(uuid, text) owner to erp_acesso;
alter function erp.retirar_pj(uuid, text) owner to erp_acesso;
-- o sino lê quem vê o PJ; o master designa pela API; cada um lê a própria designação, o master todas
grant execute on function erp.ve_pj(uuid), erp.registro_pj(text, text) to erp_notificacoes;
grant execute on function erp.designar_pj(uuid, text), erp.retirar_pj(uuid, text) to authenticated;
create policy perfil_le on erp.designados_pj for select to authenticated using (erp.membro() and (erp.sou_master() or user_id = erp.eu()));
create policy perfil_le on erp.designados_pj_historico for select to authenticated using (erp.membro() and erp.sou_master());
grant select on erp.designados_pj, erp.designados_pj_historico to authenticated;
