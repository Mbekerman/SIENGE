-- Aprovação do contrato recorrente e da previsão (Moises, 17/11/2026: "e o lançamento das previsões?";
-- "O contrato aprovado já aprova as previsões dele").
--
-- Só previsão aprovada vai ao Sienge (regra de 14/11/2026: previsão aprovada = pedido). Esta migration
-- diz quando uma previsão a pagar está aprovada:
--
-- 1. Contrato recorrente (compromisso do tipo contrato ou assinatura): aprovado pelo gestor de cada
--    centro do rateio (o que tem gestor) e por alguém da AF ou da AO, em qualquer ordem (decisão de
--    8/11/2026, contas recorrentes). Quem lançou o contrato e quem o alterou por último não aprovam; o
--    master aprova tudo de uma vez (inclusive o que ele lançou, como no título). Mudar fornecedor,
--    valor, período, vencimento, datas ou o rateio (menos a natureza, que muda pela reclassificação)
--    abre uma versão nova e a aprovação recomeça. A previsão gerada pelo contrato está aprovada quando
--    o contrato está aprovado na versão atual.
-- 2. Previsão lançada à mão (ou de pedido, orçamento, cronograma): passa pela alçada de pagamento do
--    centro e da divisão, como o título (faixas, vagas, paralelo ou sequência, o master por todas, quem
--    lançou não aprova). Sem faixa configurada, só o master aprova (falta de aprovador vai ao master).
--    Centro sem gestor e sem faixas próprias: a previsão nasce aprovada, como o título nasce sem alçada.
--    Recusar cancela a previsão.
-- 3. Acumulado do mês: a previsão aprovada conta no mês dela; a nota que a consome conta só o que
--    passa do saldo da previsão (a parte consumida sai do saldo, e o título conta inteiro).
--
-- Fica para depois (já registrado): a AD a mais para nota sem previsão, a verba livre e as travas de data.
-- Portabilidade: SQL puro.

-- ---------------------------------------------------------------------------------------------
-- 1. Contrato recorrente
-- ---------------------------------------------------------------------------------------------
alter table erp.compromissos
  add column aprovacao_versao int not null default 1,
  add column alterado_por     uuid;                 -- quem mudou por último o que pede aprovação de novo

create table erp.compromisso_aprovacoes (
  compromisso_id  uuid not null references erp.compromissos,
  versao          int not null,
  vaga            text not null check (vaga in ('AREA','FIN')),  -- AREA: gestor do centro; FIN: AF ou AO
  centro_custo_id uuid references erp.centros_custo,             -- o centro da vaga AREA
  aprovado        boolean not null,
  justificativa   text,
  por             uuid not null,
  em              timestamptz not null default clock_timestamp(),
  check ((vaga = 'AREA') = (centro_custo_id is not null)),
  check (aprovado or length(trim(coalesce(justificativa, ''))) > 0)
);
create unique index compromisso_aprovacoes_vaga on erp.compromisso_aprovacoes
  (compromisso_id, versao, vaga, coalesce(centro_custo_id, '00000000-0000-0000-0000-000000000000'));

-- A versão e quem alterou: só o gatilho põe. Mudou o que pede aprovação, versão nova.
create function erp.tg_compromisso_versao() returns trigger language plpgsql as $$
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
      new.dia_vencimento, new.caucao_percentual)
     is distinct from
     (old.empresa_id, old.tipo, old.pessoa_id, old.inicio, old.fim, old.valor_total, old.periodicidade, old.valor_periodo,
      old.dia_vencimento, old.caucao_percentual) then
    new.aprovacao_versao := old.aprovacao_versao + 1;
    new.alterado_por := erp.autor();
  end if;
  return new;
end $$;
create trigger t_versao before insert or update on erp.compromissos
  for each row execute function erp.tg_compromisso_versao();

-- O rateio mudou (centro, divisão, núcleo ou percentual; a natureza muda pela reclassificação e não
-- reabre a aprovação): versão nova do contrato. Definer erp_situacao (abaixo), para pôr a versão.
create function erp.tg_rateio_versao() returns trigger language plpgsql as $$
declare v_id uuid := coalesce(new.compromisso_id, old.compromisso_id);
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then return null; end if;
  update erp.compromissos set aprovacao_versao = aprovacao_versao + 1, alterado_por = erp.autor() where id = v_id;
  if tg_op = 'UPDATE' and new.compromisso_id <> old.compromisso_id then
    update erp.compromissos set aprovacao_versao = aprovacao_versao + 1, alterado_por = erp.autor() where id = old.compromisso_id;
  end if;
  return null;
end $$;
create trigger t_versao after insert or update or delete on erp.compromisso_rateios
  for each row execute function erp.tg_rateio_versao();

create function erp.compromisso_precisa_aprovacao(p_tipo text) returns boolean language sql immutable as
  $$ select p_tipo in ('contrato','assinatura') $$;

-- As vagas da versão atual: o gestor de cada centro do rateio que tem gestor, e uma vaga do financeiro.
create function erp.compromisso_vagas(p_id uuid) returns table (vaga text, centro_custo_id uuid) language sql stable as $$
  select 'AREA', r.centro_custo_id
    from (select distinct centro_custo_id from erp.compromisso_rateios where compromisso_id = p_id and centro_custo_id is not null) r
   where exists (select 1 from erp.centro_aprovadores a where a.centro_custo_id = r.centro_custo_id)
  union all
  select 'FIN', null::uuid $$;

create function erp.compromisso_aprovado(p_id uuid) returns boolean language sql stable as $$
  select coalesce((
    select case when not erp.compromisso_precisa_aprovacao(c.tipo) then true
                when c.situacao <> 'ativo' then false
                else not exists (select 1 from erp.compromisso_aprovacoes x
                                  where x.compromisso_id = c.id and x.versao = c.aprovacao_versao and not x.aprovado)
                     and not exists (select 1 from erp.compromisso_vagas(c.id) v
                                      where not exists (select 1 from erp.compromisso_aprovacoes x
                                                         where x.compromisso_id = c.id and x.versao = c.aprovacao_versao and x.aprovado
                                                           and x.vaga = v.vaga and x.centro_custo_id is not distinct from v.centro_custo_id)) end
      from erp.compromissos c where c.id = p_id), false) $$;

create function erp.tg_compromisso_aprovacao() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Aprovação de contrato não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then raise exception 'O contrato só se aprova por erp.decidir_compromisso'; end if;
  return new;
end $$;
create trigger t_guarda before insert or update or delete on erp.compromisso_aprovacoes
  for each row execute function erp.tg_compromisso_aprovacao();

-- Aprovar ou recusar o contrato recorrente na versão atual. Recusar exige justificativa; a recusa vale
-- até o contrato mudar (versão nova).
create function erp.decidir_compromisso(p_compromisso uuid, p_aprovar boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare c erp.compromissos; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master(); v record;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select * into c from erp.compromissos where id = p_compromisso for update;
  if c.id is null or not erp.vejo_compromisso(c.id) then raise exception 'Contrato não existe'; end if;
  if not erp.compromisso_precisa_aprovacao(c.tipo) then raise exception 'Só contrato e assinatura recorrente passam por aprovação'; end if;
  if c.situacao <> 'ativo' then raise exception 'Só contrato ativo se aprova'; end if;
  if exists (select 1 from erp.compromisso_aprovacoes where compromisso_id = c.id and versao = c.aprovacao_versao and not aprovado) then
    raise exception 'O contrato foi recusado; mude o contrato para pedir a aprovação de novo';
  end if;
  if erp.compromisso_aprovado(c.id) then raise exception 'O contrato já está aprovado'; end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Recusar exige justificativa'; end if;
  if not v_master and v_eu in (c.criado_por, c.alterado_por) then
    raise exception 'Quem lançou ou alterou o contrato não aprova';
  end if;
  if not v_master and exists (select 1 from erp.compromisso_aprovacoes
                               where compromisso_id = c.id and versao = c.aprovacao_versao and por = v_eu) then
    raise exception 'Você já aprovou este contrato';
  end if;
  if v_master then
    insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, centro_custo_id, aprovado, justificativa, por)
    select c.id, c.aprovacao_versao, x.vaga, x.centro_custo_id, p_aprovar, p_justificativa, v_eu
      from erp.compromisso_vagas(c.id) x
     where not exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = c.id and a.versao = c.aprovacao_versao
                         and a.vaga = x.vaga and a.centro_custo_id is not distinct from x.centro_custo_id)
     order by x.vaga, x.centro_custo_id
     limit case when p_aprovar then null else 1 end;
    return case when p_aprovar then 'aprovado' else 'recusado' end;
  end if;
  -- a primeira vaga pendente que a pessoa ocupa (o gestor do centro, ou a AF ou AO no financeiro)
  select x.* into v from erp.compromisso_vagas(c.id) x
   where not exists (select 1 from erp.compromisso_aprovacoes a where a.compromisso_id = c.id and a.versao = c.aprovacao_versao
                       and a.vaga = x.vaga and a.centro_custo_id is not distinct from x.centro_custo_id)
     and case when x.vaga = 'AREA' then erp._ocupa_vaga('AREA', x.centro_custo_id, v_eu)
              else erp._ocupa_vaga('AF', null, v_eu) or erp._ocupa_vaga('AO', null, v_eu) end
   order by x.vaga, x.centro_custo_id limit 1;
  if v.vaga is null then
    raise exception 'A aprovação deste contrato é do gestor de cada centro e da AF ou da AO';
  end if;
  insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, centro_custo_id, aprovado, justificativa, por)
  values (c.id, c.aprovacao_versao, v.vaga, v.centro_custo_id, p_aprovar, p_justificativa, v_eu);
  return case when not p_aprovar then 'recusado' when erp.compromisso_aprovado(c.id) then 'aprovado' else 'pendente' end;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 2. Alçada da previsão
-- ---------------------------------------------------------------------------------------------
-- Origem: o saldo de uma previsão encerrada aponta para ela; só a rotina grava as origens que valem
-- aprovação sem alçada (assinatura e saldo_previsao).
alter table erp.previsoes add column origem_previsao_id uuid references erp.previsoes;
alter table erp.previsoes drop constraint previsoes_origem_check,
  add constraint previsoes_origem_check check (origem in ('orcamento','assinatura','saldo_contrato','cronograma','manual','saldo_previsao'));
alter table erp.previsoes drop constraint previsoes_situacao_check,
  add constraint previsoes_situacao_check check (situacao in ('aberta','consumida','cancelada','encerrada'));
alter table erp.previsoes add constraint previsoes_saldo_check check ((origem = 'saldo_previsao') = (origem_previsao_id is not null));
create function erp.tg_previsao_origem() returns trigger language plpgsql as $$
begin
  if new.origem in ('assinatura','saldo_previsao') and not erp.agindo_como('erp_situacao') and not erp.sistema() then
    raise exception 'A previsão de origem % nasce da rotina (contrato ou saldo), não à mão', new.origem;
  end if;
  return new;
end $$;
create trigger t_origem before insert on erp.previsoes for each row execute function erp.tg_previsao_origem();

create table erp.previsao_alcadas (
  id                uuid primary key default gen_random_uuid(),
  previsao_id       uuid not null references erp.previsoes,
  centro_custo_id   uuid not null references erp.centros_custo,
  divisao_id        uuid,
  fases             text[] not null,
  paralelo          boolean not null,
  valor             numeric(15,2) not null,
  acumulado         numeric(15,2) not null,
  alcada_id         uuid references erp.alcadas_pagamento,   -- nula quando não havia faixa (vai ao master)
  falta_aprovadores boolean not null default false,
  vagas_sem_gente   text[] not null default '{}',
  criada_em         timestamptz not null default clock_timestamp(),
  unique (previsao_id, centro_custo_id, divisao_id)
);
create table erp.previsao_aprovacoes (
  alcada_id     uuid not null references erp.previsao_alcadas,
  previsao_id   uuid not null references erp.previsoes,
  fase          int not null,
  lista         text not null,
  aprovado      boolean not null,
  justificativa text,
  por           uuid not null,
  em            timestamptz not null default clock_timestamp(),
  vale_de       uuid references erp.previsao_alcadas,   -- aprovação de quem está na divisão e no centro
  primary key (alcada_id, fase),
  check (aprovado or length(trim(coalesce(justificativa, ''))) > 0),
  check (vale_de is null or aprovado)
);

create function erp.tg_previsao_alcada_guarda() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Alçada e aprovação da previsão não se alteram nem se apagam'; end if;
  if not erp.agindo_como('erp_situacao') then raise exception 'A alçada da previsão só é escrita pelo banco'; end if;
  return new;
end $$;
create trigger t_guarda before insert or update or delete on erp.previsao_alcadas
  for each row execute function erp.tg_previsao_alcada_guarda();
create trigger t_guarda before insert or update or delete on erp.previsao_aprovacoes
  for each row execute function erp.tg_previsao_alcada_guarda();

-- A previsão segue o contrato quando é de contrato ou assinatura recorrente.
-- Só a previsão que a rotina do contrato gerou (origem assinatura, que só a rotina grava) segue a
-- aprovação do contrato; a lançada à mão com o contrato ao lado (inclusive o saldo do contrato, que
-- ainda não tem rotina) passa pela alçada.
create function erp.previsao_do_contrato(p_id uuid) returns uuid language sql stable as $$
  select c.id from erp.previsoes p join erp.compromissos c on c.id = p.compromisso_id
   where p.id = p_id and p.origem = 'assinatura' and erp.compromisso_precisa_aprovacao(c.tipo) $$;

create function erp._fase_previsao(a erp.previsao_alcadas) returns int language sql stable as $$
  select min(i) from generate_subscripts(a.fases, 1) i
   where not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado) $$;

-- Aprovada: a pagar aberta (ou já consumida), do contrato aprovado, ou sem fase pendente nem recusa na alçada.
create function erp.previsao_aprovada(p_id uuid) returns boolean language sql stable as $$
  select coalesce((
    select case when p.sentido <> 'pagar' then true
                when p.situacao = 'cancelada' then false
                -- o saldo de uma previsão encerrada vale a aprovação da original (Moises, 17/11/2026)
                when p.origem_previsao_id is not null then erp.previsao_aprovada(p.origem_previsao_id)
                when erp.previsao_do_contrato(p.id) is not null then erp.compromisso_aprovado(erp.previsao_do_contrato(p.id))
                else not exists (select 1 from erp.previsao_aprovacoes v where v.previsao_id = p.id and not v.aprovado)
                     and not exists (select 1 from erp.previsao_alcadas a where a.previsao_id = p.id and erp._fase_previsao(a) is not null) end
      from erp.previsoes p where p.id = p_id), false) $$;

-- O saldo das previsões aprovadas no mês, para o acumulado da alçada: as do centro (ou da divisão) e,
-- com soma_fornecedor, as do mesmo fornecedor; no modo por núcleo, só as do núcleo pedido.
create function erp._previsoes_no_acumulado(p_empresa uuid, p_pessoa uuid, p_mes date, p_centro uuid, p_divisao uuid,
                                            p_nucleo uuid, p_excluir uuid) returns numeric language sql stable as $$
  select coalesce(sum(erp._previsao_saldo(q.id)), 0)
    from erp.previsoes q, erp.regra_alcada_pagamento g
   where q.sentido = 'pagar' and q.situacao = 'aberta' and erp.mes(q.competencia) = erp.mes(p_mes)
     and q.id is distinct from p_excluir
     and ((q.centro_custo_id = p_centro and (p_divisao is null or q.divisao_id = p_divisao))
          or (g.soma_fornecedor and p_pessoa is not null and q.pessoa_id = p_pessoa))
     and (g.acumulado = 'centro' or q.empresa_id = p_empresa)
     and (g.acumulado <> 'nucleo_centro' or q.centro_custo_id <> p_centro
          or (p_divisao is not null and q.divisao_id is distinct from p_divisao)
          or q.nucleo_economico_id is not distinct from p_nucleo)
     and erp.previsao_aprovada(q.id) $$;

-- Uma alçada da previsão (centro, ou divisão com faixas próprias): o acumulado do mês é o dos títulos
-- do centro (como no título) mais as previsões aprovadas e esta; o limite por título usa o valor dela.
create function erp._fixar_alcada_previsao(p erp.previsoes, p_centro uuid, p_divisao uuid) returns erp.alcadas_pagamento
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

-- Na criação da previsão a pagar que não é de contrato recorrente: a alçada da divisão com faixas
-- próprias e a do centro (se a faixa da divisão manda passar por ele, ou se a linha não tem divisão com
-- faixas e o centro tem gestor ou faixas). Definer erp_situacao (abaixo).
create function erp.tg_previsao_alcada() returns trigger language plpgsql as $$
declare f erp.alcadas_pagamento; v_centro boolean := false;
begin
  if new.sentido <> 'pagar' or new.centro_custo_id is null or erp.previsao_do_contrato(new.id) is not null
     or new.origem_previsao_id is not null then return null; end if;
  perform 1 from erp.centros_custo where id = new.centro_custo_id for update;   -- como no título (S-060)
  if new.divisao_id is not null and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id) then
    f := erp._fixar_alcada_previsao(new, new.centro_custo_id, new.divisao_id);
    v_centro := coalesce(f.passa_pelo_centro, true);
  end if;
  if v_centro
     or ((new.divisao_id is null or not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = new.divisao_id))
         and (exists (select 1 from erp.centro_aprovadores a where a.centro_custo_id = new.centro_custo_id)
              or exists (select 1 from erp.alcadas_pagamento ap where ap.centro_custo_id = new.centro_custo_id and ap.divisao_id is null))) then
    perform erp._fixar_alcada_previsao(new, new.centro_custo_id, null);
  end if;
  return null;
end $$;
create trigger t_alcada after insert on erp.previsoes
  for each row execute function erp.tg_previsao_alcada();

-- Aprovar ou recusar a previsão na fase da vez (em paralelo, qualquer vaga pendente que a pessoa ocupa).
-- O master aprova todas as fases de uma vez. Recusar exige justificativa e cancela a previsão.
create function erp.decidir_previsao(p_previsao uuid, p_aprovar boolean, p_justificativa text default null,
                                     p_centro uuid default null, p_divisao uuid default null)
returns text language plpgsql as $$
declare p erp.previsoes; a erp.previsao_alcadas; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master();
        v_fase int; v_lista text; r record;
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
                and exists (select 1 from generate_subscripts(a0.fases, 1) i
                             where (a0.paralelo or i = erp._fase_previsao(a0))
                               and erp._ocupa_vaga(a0.fases[i], a0.centro_custo_id, v_eu)
                               and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a0.id and v.fase = i))) desc,
              a0.centro_custo_id, a0.divisao_id nulls first
     limit 1;
  end if;
  v_fase := erp._fase_previsao(a);
  if a.paralelo and not v_master then
    v_fase := coalesce((select min(i) from generate_subscripts(a.fases, 1) i
                          where erp._ocupa_vaga(a.fases[i], a.centro_custo_id, v_eu)
                            and not exists (select 1 from erp.previsao_aprovacoes v where v.alcada_id = a.id and v.fase = i)), v_fase);
  end if;
  v_lista := a.fases[v_fase];
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

-- ---------------------------------------------------------------------------------------------
-- 3. Acumulado do título: soma as previsões aprovadas do mês (a parte consumida já saiu do saldo)
-- ---------------------------------------------------------------------------------------------
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
    -- a parte de cada título no centro (ou na divisão); com soma_fornecedor, o mesmo fornecedor conta inteiro
    select round(coalesce(sum(t2.valor * r2.percentual / 100 - erp.cobertura(r2.id)), 0), 2), array_agg(distinct t2.id) into v_soma, v_ids
      from erp.titulos t2 join erp.titulo_rateios r2 on r2.titulo_id = t2.id
     where ((r2.centro_custo_id = p_centro and (p_divisao is null or r2.divisao_id = p_divisao))
            or (v_forn and t2.pessoa_id = t.pessoa_id))
       and t2.sentido = 'pagar' and t2.tipo not in ('imposto','societario')
       and (t2.situacao in ('aberto','quitado') or t2.id = t.id)
       and erp.mes(t2.competencia) = erp.mes(t.competencia)
       and (v_modo = 'centro' or t2.empresa_id = t.empresa_id)
       and (v_modo <> 'nucleo_centro' or r2.centro_custo_id <> p_centro
            or (p_divisao is not null and r2.divisao_id is distinct from p_divisao)
            or r2.nucleo_economico_id is not distinct from r.nucleo_economico_id);
    -- as previsões aprovadas do mês, pelo saldo (a parte já consumida por nota está no título)
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

-- A nota consome as previsões antes de a alçada do título ser fixada (antes era depois), para o
-- acumulado não contar duas vezes a parte consumida.
create or replace function erp.lancar_documento(p_documento uuid, p_vencimentos date[], p_previsoes uuid[] default null)
returns uuid language plpgsql as $$
declare d erp.documentos_fiscais; v_ret numeric; v_liquido numeric; v_tit uuid; v_imp uuid; r record;
        v_resta numeric; v_cons numeric; v_lim numeric; p record;
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

-- ---------------------------------------------------------------------------------------------
-- 4. Assinatura pela rotina, e saldo × saving (Moises, 17/11/2026)
-- ---------------------------------------------------------------------------------------------
-- A rotina da assinatura grava como erp_situacao (a origem "assinatura" vale a aprovação do contrato);
-- confere antes se quem chama lança no contrato, que o RLS conferia quando ela era invoker.
create or replace function erp.gerar_previsoes_assinatura(p_compromisso uuid, p_ate date) returns int
language plpgsql as $$
declare c erp.compromissos; d date; v_passo interval; n int := 0; r record;
begin
  perform erp.exigir_editor();
  select * into c from erp.compromissos where id = p_compromisso;
  if c.id is null or not (erp.sistema() or erp.lanco_compromisso(c.id)) then raise exception 'Contrato não existe'; end if;
  if c.tipo <> 'assinatura' or c.situacao <> 'ativo' then raise exception 'Só assinatura ativa gera previsões'; end if;
  if not erp.rateio_completo('compromisso', c.id) then raise exception 'O rateio da assinatura não soma 100%%'; end if;
  v_passo := case c.periodicidade when 'mensal' then '1 month' when 'bimestral' then '2 months'
             when 'trimestral' then '3 months' when 'semestral' then '6 months' else '1 year' end::interval;
  d := erp.mes(c.inicio);
  while d <= least(p_ate, coalesce(c.fim, p_ate)) loop
    if not exists (select 1 from erp.previsoes where compromisso_id = c.id and competencia = d and situacao <> 'cancelada') then
      for r in select * from erp.ratear('compromisso', c.id, c.valor_periodo) loop
        insert into erp.previsoes (empresa_id, origem, compromisso_id, pessoa_id, nucleo_economico_id, natureza_id,
                                      centro_custo_id, divisao_id, subdivisao_id, competencia, data_prevista, valor, descricao)
        values (c.empresa_id, 'assinatura', c.id, c.pessoa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id, r.subdivisao_id,
                d, least(d + (coalesce(c.dia_vencimento, 1) - 1), (d + interval '1 month - 1 day')::date),
                r.valor, c.descricao);
      end loop;
      n := n + 1;
    end if;
    d := (d + v_passo)::date;
  end loop;
  return n;
end $$;

-- O livro: encerrar estorna o saldo do previsto, como cancelar.
create or replace function erp.tg_previsao() returns trigger language plpgsql as $$
declare v_saldo numeric;
begin
  if tg_op = 'INSERT' then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id,
                                    competencia, data_caixa, valor, previsao_id)
    values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.centro_custo_id, new.divisao_id, new.subdivisao_id,
            new.competencia, new.data_prevista, erp.sinal(new.sentido) * new.valor, new.id);
    return new;
  end if;
  if new.situacao in ('cancelada','encerrada') and old.situacao = 'aberta' then
    v_saldo := erp._previsao_saldo(new.id);
    if v_saldo > 0 then
      insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id,
                                      competencia, data_caixa, valor, previsao_id)
      values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.centro_custo_id, new.divisao_id, new.subdivisao_id,
              new.competencia, new.data_prevista, -erp.sinal(new.sentido) * v_saldo, new.id);
    end if;
  end if;
  return new;
end $$;

-- A nota veio menor que a previsão: quem lança decide se a diferença ainda será paga (saldo, com a
-- data que informar: nasce outra previsão, aprovada como a original) ou se foi economia (saving). Nos
-- dois casos a previsão é encerrada (e a linha PRV dela sai do Sienge).
create function erp.encerrar_previsao(p_previsao uuid, p_destino text, p_data date default null) returns uuid
language plpgsql as $$
declare p erp.previsoes; v_saldo numeric; v_nova uuid;
begin
  perform erp.exigir_editor();
  select * into p from erp.previsoes where id = p_previsao for update;
  if p.id is null or not erp.vejo_previsao(p.id) then raise exception 'Previsão não existe'; end if;
  if not erp.lanco(p.nucleo_economico_id, p.centro_custo_id, p.natureza_id, p.criada_por, p.divisao_id) then
    raise exception 'Você não lança nesta previsão';
  end if;
  if p.situacao <> 'aberta' then raise exception 'Só previsão aberta se encerra'; end if;
  if not exists (select 1 from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
                  where tp.previsao_id = p.id and t.situacao <> 'cancelado') then
    raise exception 'A previsão ainda não foi consumida por nenhuma nota; para desistir, cancele';
  end if;
  v_saldo := erp._previsao_saldo(p.id);
  if p_destino = 'saving' then
    if p_data is not null then raise exception 'Saving não tem data'; end if;
  elsif p_destino = 'saldo' then
    if p_data is null then raise exception 'Informe a data em que o saldo será pago'; end if;
    if p_data < (now() at time zone 'America/Sao_Paulo')::date then raise exception 'A data do saldo já passou'; end if;
    if not erp.previsao_aprovada(p.id) then raise exception 'A previsão original não está aprovada; lance o saldo como previsão nova'; end if;
  else
    raise exception 'Destino é saldo ou saving';
  end if;
  update erp.previsoes set situacao = 'encerrada' where id = p.id;
  if p_destino = 'saldo' then
    insert into erp.previsoes (empresa_id, sentido, origem, origem_previsao_id, compromisso_id, pessoa_id, nucleo_economico_id,
                               natureza_id, centro_custo_id, divisao_id, subdivisao_id, competencia, data_prevista, valor, descricao)
    values (p.empresa_id, p.sentido, 'saldo_previsao', p.id, p.compromisso_id, p.pessoa_id, p.nucleo_economico_id,
            p.natureza_id, p.centro_custo_id, p.divisao_id, p.subdivisao_id, erp.mes(p_data), p_data, v_saldo,
            left('Saldo · ' || coalesce(p.descricao, ''), 500))
    returning id into v_nova;
  end if;
  return v_nova;
end $$;

-- As previsões que esperam a decisão: consumidas em parte por nota, com saldo e ainda abertas.
create view erp.v_previsoes_a_decidir with (security_invoker = true) as
  select v.id, v.empresa_id, v.pessoa_id, v.centro_custo_id, v.divisao_id, v.natureza_id, v.competencia, v.data_prevista,
         v.valor, v.consumido, v.saldo
    from erp.v_previsoes v
   where v.situacao = 'aberta' and v.sentido = 'pagar' and v.consumido > 0 and v.saldo > 0;

-- ---------------------------------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['compromisso_aprovacoes','previsao_alcadas','previsao_aprovacoes'] loop
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
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'erp' and p.proname in ('tg_compromisso_versao','tg_rateio_versao','compromisso_precisa_aprovacao',
              'compromisso_vagas','compromisso_aprovado','tg_compromisso_aprovacao','decidir_compromisso','tg_previsao_alcada_guarda',
              'previsao_do_contrato','_fase_previsao','previsao_aprovada','_previsoes_no_acumulado','_fixar_alcada_previsao',
              'tg_previsao_alcada','decidir_previsao','tg_previsao_origem','encerrar_previsao') loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
end $$;

-- Lê quem vê o contrato ou a previsão; ninguém grava pela API (só pelas decisões).
create policy perfil_le on erp.compromisso_aprovacoes for select to authenticated using (erp.vejo_compromisso(compromisso_id));
create policy perfil_le on erp.previsao_alcadas for select to authenticated using (erp.vejo_previsao(previsao_id));
create policy perfil_le on erp.previsao_aprovacoes for select to authenticated using (erp.vejo_previsao(previsao_id));
grant select on erp.compromisso_aprovacoes, erp.previsao_alcadas, erp.previsao_aprovacoes to authenticated;

-- Quem escreve na alçada e nas aprovações (S-035): as decisões e os gatilhos que põem a versão e
-- fixam a alçada. As conferências leem por baixo do RLS (a aprovação de outro centro conta).
do $$
declare r record;
begin
  for r in select * from (values
    ('erp.decidir_compromisso(uuid, boolean, text)', 'erp_situacao'),
    ('erp.decidir_previsao(uuid, boolean, text, uuid, uuid)', 'erp_situacao'),
    ('erp.tg_rateio_versao()', 'erp_situacao'),
    ('erp.tg_previsao_alcada()', 'erp_situacao'),
    ('erp.encerrar_previsao(uuid, text, date)', 'erp_situacao'),
    ('erp.gerar_previsoes_assinatura(uuid, date)', 'erp_situacao'),   -- a origem "assinatura" só pela rotina
    ('erp.tg_previsao()', 'erp_situacao'),                             -- o create or replace acima volta a invoker
    ('erp.lancar_documento(uuid, date[], uuid[])', 'erp_situacao'),   -- o create or replace acima volta a invoker
    ('erp.compromisso_aprovado(uuid)', 'erp_conferencia'),
    ('erp.previsao_aprovada(uuid)', 'erp_conferencia')) v(f, dono) loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', r.f);
    execute format('alter function %s owner to %I', r.f, r.dono);
  end loop;
end $$;
-- A API decide; as conferências que respondem sobre qualquer id ficam só para o banco (S-126).
grant execute on function erp.decidir_compromisso(uuid, boolean, text), erp.decidir_previsao(uuid, boolean, text, uuid, uuid),
                          erp.compromisso_precisa_aprovacao(text), erp.tg_compromisso_versao(), erp.tg_compromisso_aprovacao(),
                          erp.tg_previsao_alcada_guarda(), erp.encerrar_previsao(uuid, text, date), erp.tg_previsao_origem()
  to authenticated;
grant select on erp.v_previsoes_a_decidir to authenticated;
