-- Alçada sem centro (Moises, 18/11/2026).
--
-- 1. Linha do rateio sem centro (natureza de movimentação, como 10.01 Bens da empresa): aprovação conjunta
--    da AO e da AF, ou da AD sozinha. Antes, a linha sem centro não entrava em alçada nenhuma.
-- 2. Título de imposto: aprovação da AF. Título societário: aprovação da AD. Antes, os dois nasciam sem alçada.
-- 3. Regra geral: a AD sempre pode fazer uma aprovação que cabe à AF ou à AO (no título, na previsão e
--    no contrato). Cada pessoa continua aprovando uma fase só de cada alçada; na alçada sem centro, o
--    voto da AD vale pela alçada inteira (a coluna basta).
-- Previsão sem centro: a mesma regra do item 1. O master continua decidindo qualquer alçada.
-- Vale para título e previsão confirmados daqui em diante; o que já foi confirmado não muda.
-- Portabilidade: SQL puro.

-- A alçada sem centro: centro e divisão nulos; basta = a lista cujo voto decide a alçada inteira.
alter table erp.titulo_alcadas
  alter column centro_custo_id drop not null,
  add column basta text check (basta = 'AD'),
  add constraint titulo_alcadas_sem_centro check (centro_custo_id is not null or divisao_id is null),
  add constraint titulo_alcadas_basta check (basta is null or centro_custo_id is null);
alter table erp.titulo_aprovacoes alter column centro_custo_id drop not null;
alter table erp.previsao_alcadas
  alter column centro_custo_id drop not null,
  add column basta text check (basta = 'AD'),
  add constraint previsao_alcadas_sem_centro check (centro_custo_id is not null or divisao_id is null),
  add constraint previsao_alcadas_basta check (basta is null or centro_custo_id is null);
-- uma alçada sem centro por previsão (a chave única trata nulos como distintos)
create unique index previsao_alcadas_uma_sem_centro on erp.previsao_alcadas (previsao_id) where centro_custo_id is null;

-- A AD ocupa também a vaga da AF e da AO (Moises, 18/11/2026).
create or replace function erp._ocupa_vaga(p_vaga text, p_centro uuid, p_user uuid) returns boolean language plpgsql stable as $$
begin
  if not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then return false; end if;
  return case
    when p_vaga = 'AREA' then exists (select 1 from erp.centro_aprovadores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga = 'DIRETOR_AREA' then exists (select 1 from erp.centro_diretores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga in ('AF','AO') then exists (select 1 from erp.listas_financeiro where lista in (p_vaga, 'AD') and user_id = p_user)
    when p_vaga = 'AD' then exists (select 1 from erp.listas_financeiro where lista = 'AD' and user_id = p_user)
    when p_vaga like 'P:%' then substr(p_vaga, 3)::uuid = p_user
    else false end;
end $$;

-- A alçada sem centro do título, sem faixa: fases fixas, em paralelo. Falta aprovador quando as vagas
-- não se preenchem e nem a lista do basta tem quem aprove; aí vai ao master, com o aviso.
create function erp._fixar_alcada_sem_centro(t erp.titulos, p_fases text[], p_basta text, p_valor numeric) returns void
language plpgsql as $$
declare v_falta text[];
begin
  v_falta := erp._vagas_sem_gente(p_fases, null, t.criado_por);
  if cardinality(v_falta) > 0 and p_basta is not null
     and cardinality(erp._vagas_sem_gente(array[p_basta], null, t.criado_por)) = 0 then
    v_falta := '{}';
  end if;
  insert into erp.titulo_alcadas (titulo_id, rodada, centro_custo_id, divisao_id, fases, paralelo, valor_no_centro, acumulado, titulos,
                                  alcada_id, falta_aprovadores, vagas_sem_gente, basta)
  values (t.id, t.rodada, null, null, p_fases, true, p_valor, p_valor, array[t.id], null, cardinality(v_falta) > 0, v_falta, p_basta);
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'titulos', t.id::text, null, null,
      jsonb_build_object('titulo_id', t.id, 'rodada', t.rodada, 'fases', p_fases, 'vagas_sem_gente', v_falta,
                         'valor_no_centro', p_valor, 'valor', t.valor,
                         'motivo', 'Faltam aprovadores qualificados: o título vai ao master'));
  end if;
end $$;

create or replace function erp._definir_alcada(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos; cc record; dv record; f erp.alcadas_pagamento; v_centro boolean; v_sem numeric;
begin
  select * into t from erp.titulos where id = p_titulo;
  if t.sentido <> 'pagar' then return; end if;
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

create or replace function erp.decidir_titulo(p_titulo uuid, p_aprovar boolean, p_justificativa text default null,
                                   p_revisao boolean default false, p_centro uuid default null,
                                   p_divisao uuid default null)
returns text language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare a erp.titulo_alcadas; v_fase int; v_lista text; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master();
        v_proprio boolean; v_autor boolean; v_rodada int; v_basta boolean := false;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select t0.rodada into v_rodada from erp.titulos t0 where t0.id = p_titulo for update;
  if not exists (select 1 from erp.titulo_alcadas where titulo_id = p_titulo and rodada = v_rodada) then
    raise exception 'Este título não tem alçada de pagamento';
  end if;
  if erp.alcada_recusada(p_titulo) then raise exception 'O título foi recusado na alçada'; end if;
  if erp.em_revisao(p_titulo) then raise exception 'O título está em revisão; aguarde o ajuste de quem lançou'; end if;
  if erp.alcada_fase(p_titulo) is null then raise exception 'O título já foi aprovado em todas as fases de aprovação'; end if;
  -- a alçada (centro ou divisão): a pedida, senão a primeira que falta aprovar em que a pessoa
  -- tem a vaga da vez (em paralelo, qualquer vaga pendente) e ainda não aprovou; senão a
  -- primeira que falta aprovar
  if p_centro is not null then
    select * into a from erp.titulo_alcadas where titulo_id = p_titulo and rodada = v_rodada and centro_custo_id = p_centro
                                              and divisao_id is not distinct from p_divisao;
    if a.titulo_id is null then
      if p_divisao is null then raise exception 'Este centro não está na alçada do título'; end if;
      raise exception 'Esta divisão não tem alçada própria neste título';
    end if;
    if erp._fase_da_alcada(a) is null then
      if p_divisao is null then raise exception 'Este centro já aprovou o título'; end if;
      raise exception 'Esta divisão já aprovou o título';
    end if;
  elsif p_divisao is not null then
    raise exception 'Diga o centro de custo da divisão';
  else
    select a0.* into a from erp.titulo_alcadas a0
     where a0.titulo_id = p_titulo and a0.rodada = v_rodada and erp._fase_da_alcada(a0) is not null
     order by (not v_master and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.por = v_eu)
                and (exists (select 1 from generate_subscripts(a0.fases, 1) i
                              where (a0.paralelo or i = erp._fase_da_alcada(a0))
                                and erp._ocupa_vaga(a0.fases[i], a0.centro_custo_id, v_eu)
                                and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.fase = i and v.aprovado))
                     or (a0.basta is not null and erp._ocupa_vaga(a0.basta, a0.centro_custo_id, v_eu)))) desc,
              -- sem a vez em nenhuma: a alçada em que a pessoa já aprovou (a recusa diz isso), depois a primeira
              exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.por = v_eu) desc,
              a0.centro_custo_id, a0.divisao_id nulls first
     limit 1;
  end if;
  -- em sequência, a vaga da vez; em paralelo, a primeira vaga pendente que a pessoa ocupa
  v_fase := erp._fase_da_alcada(a);
  if a.paralelo and not v_master then
    -- a vaga da própria lista antes da que a AD ocupa no lugar da AF ou da AO (senão a AD gastaria
    -- o voto na vaga da AF e não poderia mais aprovar na dela)
    v_fase := coalesce((select i from generate_subscripts(a.fases, 1) i
                          where erp._ocupa_vaga(a.fases[i], a.centro_custo_id, v_eu)
                            and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado)
                          order by (a.fases[i] in ('AF','AO')
                                    and not exists (select 1 from erp.listas_financeiro lf where lf.lista = a.fases[i] and lf.user_id = v_eu)), i
                          limit 1), v_fase);
  end if;
  v_lista := a.fases[v_fase];
  -- a alçada sem centro (AO + AF, ou a AD sozinha; Moises, 18/11/2026): o voto de quem está na AD
  -- decide a alçada inteira
  if not v_master and a.basta is not null and erp._ocupa_vaga(a.basta, a.centro_custo_id, v_eu) then
    v_basta := true;
    v_lista := a.basta;
  end if;
  -- quem lançou não aprova, salvo o master e a AD autorizada (na fase da AD)
  v_proprio := v_master or (v_lista = 'AD' and erp.aprova_proprio(array['AD']));
  v_autor := erp.autor_lancamento('titulo', p_titulo) = v_eu
             or exists (select 1 from erp.cadeia_titulo(p_titulo) c(id) where erp.autor_lancamento('titulo', c.id) = v_eu);
  if coalesce(v_autor, false) and not v_proprio then raise exception 'Quem lançou não aprova o próprio lançamento'; end if;
  -- na nota relançada, quem lançou qualquer título da cadeia também não (S-075); e quem ajustou
  -- ou reenviou em alguma revisão da cadeia não aprova (S-071; quem ajusta já aprova a própria
  -- fase no reenvio)
  if not v_master and (exists (select 1 from erp.titulo_revisoes r where r.titulo_id in (select erp.cadeia_titulo(p_titulo)) and r.reenviada_por = v_eu)
     or exists (select 1 from erp.titulo_ajustes j where j.titulo_id in (select erp.cadeia_titulo(p_titulo)) and j.por = v_eu)) then
    raise exception 'Quem ajustou não aprova o ajuste';
  end if;
  -- uma fase por pessoa em cada alçada; quem tem vaga em dois centros aprova nos dois; na divisão
  -- e no centro, a aprovação vale pelas duas (_aprovacao_vale_nas_duas)
  if not v_master and exists (select 1 from erp.titulo_aprovacoes where alcada_id = a.id and por = v_eu) then
    raise exception 'Você já aprovou uma fase de aprovação deste título';
  end if;
  -- o master decide qualquer fase; aprovando, a decisão dele vale por todas as que faltam, em
  -- todas as alçadas (Moises, 14/11/2026). Quem lançou ou ajustou continua não aprovando, nem o master.
  if v_master then
    null;
  elsif v_lista = 'AREA' then
    if not exists (select 1 from erp.centro_aprovadores c join erp.usuarios u on u.id = c.user_id
                    where c.centro_custo_id = a.centro_custo_id and c.user_id = v_eu and u.ativo) then
      raise exception 'Esta fase de aprovação é do gestor da área';
    end if;
  elsif v_lista = 'DIRETOR_AREA' then
    if not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then raise exception 'Esta fase de aprovação é do diretor da área'; end if;
  elsif v_lista like 'P:%' then
    if not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then raise exception 'Esta fase de aprovação é de outra pessoa'; end if;
  elsif not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then   -- a AD ocupa também a vaga da AF e da AO
    raise exception 'Esta fase de aprovação é de quem está em %', v_lista;
  end if;
  if p_revisao then
    if length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Pedir revisão exige o motivo'; end if;
    insert into erp.titulo_revisoes (titulo_id, rodada, centro_custo_id, alcada_id, fase, motivo, pedida_por)
    values (p_titulo, a.rodada, a.centro_custo_id, a.id, v_fase, p_justificativa, v_eu);
    return 'revisao';
  end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then
    raise exception 'Recusar exige justificativa';
  end if;
  if v_master and p_aprovar then
    insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, proprio)
    select a2.id, p_titulo, a2.rodada, a2.centro_custo_id, i, a2.fases[i], true, p_justificativa, v_eu, coalesce(v_autor, false)
      from erp.titulo_alcadas a2, generate_subscripts(a2.fases, 1) i
     where a2.titulo_id = p_titulo and a2.rodada = v_rodada
       and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a2.id and v.fase = i);
    return 'aprovado';
  end if;
  if v_basta and p_aprovar then
    insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, proprio)
    select a.id, p_titulo, a.rodada, a.centro_custo_id, i, a.basta, true, p_justificativa, v_eu, coalesce(v_autor, false)
      from generate_subscripts(a.fases, 1) i
     where not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i);
    return case when erp.alcada_pendente(p_titulo) is null then 'aprovado' else 'pendente' end;
  end if;
  insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, proprio)
  values (a.id, p_titulo, a.rodada, a.centro_custo_id, v_fase, v_lista, p_aprovar, p_justificativa, v_eu, coalesce(v_autor, false));
  if not p_aprovar then
    perform erp._cancelar_recusado(p_titulo);
    return 'recusado';
  end if;
  perform erp._aprovacao_vale_nas_duas(p_titulo);
  return case when erp.alcada_pendente(p_titulo) is null then 'aprovado' else 'pendente' end;
end $$;


create or replace function erp._aprovar_pelo_ajuste(p_titulo uuid, p_revisao uuid) returns void language plpgsql as $$
declare a erp.titulo_alcadas; i int; v_quem uuid; v_usados uuid[];
begin
  -- em cada alçada do título (centro ou divisão); quem tem a vaga em duas aprova nas duas
  for a in select a0.* from erp.titulo_alcadas a0 join erp.titulos t0 on t0.id = a0.titulo_id and t0.rodada = a0.rodada
            where a0.titulo_id = p_titulo order by a0.centro_custo_id, a0.divisao_id nulls first loop
    v_usados := '{}';
    for i in select generate_subscripts(a.fases, 1) loop
      continue when a.fases[i] not in ('AREA','AF');
      select q.por into v_quem from (
          select reenviada_por as por, reenviada_em as em from erp.titulo_revisoes where id = p_revisao
          union all select por, em from erp.titulo_ajustes where revisao_id = p_revisao) q
       join erp.usuarios u on u.id = q.por and u.ativo
       where q.por <> all(v_usados)
         -- quem lançou de verdade é o autor do primeiro título da cadeia; os relançados pela revisão
         -- da nota têm como autor técnico quem reenviou
         and q.por is distinct from (select erp.autor_lancamento('titulo', c.id) from erp.cadeia_titulo(p_titulo) c(id)
                                      join erp.titulos t on t.id = c.id where t.substitui_id is null)
         and case a.fases[i]
               when 'AREA' then exists (select 1 from erp.centro_aprovadores c where c.user_id = q.por and c.centro_custo_id = a.centro_custo_id)
               else erp._ocupa_vaga('AF', a.centro_custo_id, q.por) end   -- a AD ocupa a vaga da AF
       order by q.em limit 1;
      continue when v_quem is null;
      insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, origem)
      values (a.id, p_titulo, a.rodada, a.centro_custo_id, i, a.fases[i], true, 'Aprovado pelo ajuste na revisão', v_quem, 'ajuste');
      v_usados := v_usados || v_quem;
    end loop;
  end loop;
end $$;


-- A alçada sem centro da previsão: AO + AF, ou a AD sozinha (Moises, 18/11/2026).
create function erp._fixar_alcada_previsao_sem_centro(p erp.previsoes) returns void language plpgsql as $$
declare v_falta text[];
begin
  v_falta := erp._vagas_sem_gente(array['AF','AO'], null, p.criada_por);
  if cardinality(v_falta) > 0 and cardinality(erp._vagas_sem_gente(array['AD'], null, p.criada_por)) = 0 then v_falta := '{}'; end if;
  insert into erp.previsao_alcadas (previsao_id, centro_custo_id, divisao_id, fases, paralelo, valor, acumulado, alcada_id,
                                    falta_aprovadores, vagas_sem_gente, basta)
  values (p.id, null, null, array['AF','AO'], true, p.valor, p.valor, null, cardinality(v_falta) > 0, v_falta, 'AD');
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'previsoes', p.id::text, null, null,
      jsonb_build_object('previsao_id', p.id, 'fases', array['AF','AO'], 'vagas_sem_gente', v_falta, 'valor', p.valor,
                         'motivo', 'Faltam aprovadores qualificados: a previsão vai ao master'));
  end if;
end $$;

create or replace function erp.tg_previsao_alcada() returns trigger language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare f erp.alcadas_pagamento; v_centro boolean := false;
begin
  if new.sentido <> 'pagar' or erp.previsao_do_contrato(new.id) is not null
     or new.origem_previsao_id is not null then return null; end if;
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

create or replace function erp.decidir_previsao(p_previsao uuid, p_aprovar boolean, p_justificativa text default null,
                                     p_centro uuid default null, p_divisao uuid default null)
returns text language plpgsql
  security definer set search_path = erp, pg_catalog, pg_temp as $$
declare p erp.previsoes; a erp.previsao_alcadas; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master();
        v_fase int; v_lista text; r record; v_basta boolean := false;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select * into p from erp.previsoes where id = p_previsao for update;
  if p.id is null or not erp.vejo_previsao(p.id) then raise exception 'Previsão não existe'; end if;
  if erp.previsao_do_contrato(p.id) is not null then raise exception 'A previsão do contrato segue a aprovação do contrato'; end if;
  if p.origem_previsao_id is not null then raise exception 'O saldo segue a aprovação da previsão original'; end if;
  if p.situacao <> 'aberta' then raise exception 'Só previsão aberta se aprova'; end if;
  if not exists (select 1 from erp.previsao_alcadas where previsao_id = p.id) then raise exception 'Esta previsão não passa pela alçada'; end if;
  if erp.previsao_aprovada(p.id) then raise exception 'A previsão já foi aprovada'; end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Recusar exige justificativa'; end if;
  if p_centro is not null then
    select * into a from erp.previsao_alcadas where previsao_id = p.id and centro_custo_id = p_centro and divisao_id is not distinct from p_divisao;
    if a.id is null then raise exception 'Este centro ou divisão não está na alçada da previsão'; end if;
    if erp._fase_previsao(a) is null then raise exception 'Este centro ou divisão já aprovou a previsão'; end if;
  else
    select a0.* into a from erp.previsao_alcadas a0
     where a0.previsao_id = p.id and erp._fase_previsao(a0) is not null
     order by (not v_master and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a0.id and v.por = v_eu)
                and (exists (select 1 from generate_subscripts(a0.fases, 1) i
                              where (a0.paralelo or i = erp._fase_previsao(a0))
                                and erp._ocupa_vaga(a0.fases[i], a0.centro_custo_id, v_eu)
                                and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a0.id and v.fase = i))
                     or (a0.basta is not null and erp._ocupa_vaga(a0.basta, a0.centro_custo_id, v_eu)))) desc,
              a0.centro_custo_id, a0.divisao_id nulls first
     limit 1;
  end if;
  v_fase := erp._fase_previsao(a);
  if a.paralelo and not v_master then
    -- a vaga da própria lista antes da que a AD ocupa no lugar da AF ou da AO (senão a AD gastaria
    -- o voto na vaga da AF e não poderia mais aprovar na dela)
    v_fase := coalesce((select i from generate_subscripts(a.fases, 1) i
                          where erp._ocupa_vaga(a.fases[i], a.centro_custo_id, v_eu)
                            and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i)
                          order by (a.fases[i] in ('AF','AO')
                                    and not exists (select 1 from erp.listas_financeiro lf where lf.lista = a.fases[i] and lf.user_id = v_eu)), i
                          limit 1), v_fase);
  end if;
  v_lista := a.fases[v_fase];
  -- a alçada sem centro: o voto de quem está na AD decide a alçada inteira (Moises, 18/11/2026)
  if not v_master and a.basta is not null and erp._ocupa_vaga(a.basta, a.centro_custo_id, v_eu) then
    v_basta := true;
    v_lista := a.basta;
  end if;
  -- quem lançou não aprova, salvo o master e a AD autorizada (na fase da AD)
  if p.criada_por = v_eu and not v_master and not (v_lista = 'AD' and erp.aprova_proprio(array['AD'])) then
    raise exception 'Quem lançou não aprova o próprio lançamento';
  end if;
  if not v_master and exists (select 1 from erp.previsao_aprovacoes where alcada_id = a.id and por = v_eu) then
    raise exception 'Você já aprovou uma fase de aprovação desta previsão';
  end if;
  if not v_master and not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then
    raise exception 'Esta fase de aprovação é de quem está em %', v_lista;
  end if;
  if v_master and p_aprovar then
    insert into erp.previsao_aprovacoes (alcada_id, previsao_id, fase, lista, aprovado, justificativa, por)
    select a2.id, p.id, i, a2.fases[i], true, p_justificativa, v_eu
      from erp.previsao_alcadas a2, generate_subscripts(a2.fases, 1) i
     where a2.previsao_id = p.id and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a2.id and v.fase = i);
    return 'aprovado';
  end if;
  if v_basta and p_aprovar then
    insert into erp.previsao_aprovacoes (alcada_id, previsao_id, fase, lista, aprovado, justificativa, por)
    select a.id, p.id, i, a.basta, true, p_justificativa, v_eu
      from generate_subscripts(a.fases, 1) i
     where not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i);
    return case when erp.previsao_aprovada(p.id) then 'aprovado' else 'pendente' end;
  end if;
  insert into erp.previsao_aprovacoes (alcada_id, previsao_id, fase, lista, aprovado, justificativa, por)
  values (a.id, p.id, v_fase, v_lista, p_aprovar, p_justificativa, v_eu);
  if not p_aprovar then
    update erp.previsoes set situacao = 'cancelada' where id = p.id;
    return 'recusado';
  end if;
  -- a aprovação vale pela divisão e pelo centro (Moises, 15/11/2026), na vaga que a pessoa ocupa lá,
  -- quando é a da vez (em paralelo, qualquer uma)
  for r in select a2.id, i, a2.fases[i] as vaga from erp.previsao_alcadas a2 cross join lateral generate_subscripts(a2.fases, 1) i
            where a2.previsao_id = p.id and a2.id <> a.id and a2.centro_custo_id = a.centro_custo_id
              and (a.divisao_id is null or a2.divisao_id is null)
              and (a2.paralelo or i = erp._fase_previsao(a2))
              and erp._ocupa_vaga(a2.fases[i], a2.centro_custo_id, v_eu)
              and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a2.id and (v.fase = i or v.por = v_eu))
            order by a2.id, i loop
    continue when exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = r.id and v.por = v_eu);
    insert into erp.previsao_aprovacoes (alcada_id, previsao_id, fase, lista, aprovado, justificativa, por, vale_de)
    values (r.id, p.id, r.i, r.vaga, true, 'Vale a aprovação na outra alçada do centro', v_eu, a.id);
  end loop;
  return case when erp.previsao_aprovada(p.id) then 'aprovado' else 'pendente' end;
end $$;


-- O acompanhamento: a alçada sem centro aparece com o centro nulo e o basta.
create or replace view erp.v_titulo_alcadas with (security_invoker = true) as
select a.id as alcada_id, a.titulo_id, a.rodada, a.centro_custo_id, c.nome as centro, a.divisao_id, d.nome as divisao,
       a.valor_no_centro, a.acumulado, a.fases, a.paralelo,
       case when exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and not v.aprovado) then 'recusado'
            when cardinality(p.pendentes) = 0 then 'aprovado' else 'pendente' end as situacao,
       p.pendentes as vagas_pendentes,
       a.falta_aprovadores, a.vagas_sem_gente, a.basta
from erp.titulo_alcadas a
join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
left join erp.centros_custo c on c.id = a.centro_custo_id
left join erp.divisoes d on d.id = a.divisao_id
cross join lateral (
  select coalesce(array_agg(a.fases[i] order by i), '{}') as pendentes from generate_subscripts(a.fases, 1) i
   where not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado)) p;

-- Quem aprova vê o título: também a AD na alçada sem centro.
create or replace function erp.aprovo_titulo(p_titulo uuid) returns boolean language sql stable
  security definer set search_path = erp, pg_catalog, pg_temp as $$
  select erp.membro() and (
    exists (select 1 from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
             where a.titulo_id = p_titulo
               and (erp.estou_nas_listas(a.fases) or coalesce(erp.meu_papel(), '') = 'diretor'
                    or exists (select 1 from unnest(array_append(a.fases, a.basta)) e where erp._ocupa_vaga(e, a.centro_custo_id, erp.eu()))))
    or exists (select 1 from erp.titulo_aprovacoes x where x.titulo_id = p_titulo and x.por = erp.eu())) $$;

-- As duas funções novas são internas: só os papéis do banco as executam (como as outras da alçada).
do $$
declare f regprocedure;
begin
  foreach f in array array['erp._fixar_alcada_sem_centro(erp.titulos, text[], text, numeric)'::regprocedure,
                           'erp._fixar_alcada_previsao_sem_centro(erp.previsoes)'::regprocedure] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
end $$;
