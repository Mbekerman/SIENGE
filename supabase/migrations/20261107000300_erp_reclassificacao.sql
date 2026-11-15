-- ERP BKM: fechamento do mês, alçadas e reclassificação de naturezas.
-- Decisões do Moises (7/nov/2026): toda reclassificação precisa de aval; a alçada depende
-- da idade (mês aberto, mês fechado com trimestre do calendário aberto, trimestre fechado),
-- do valor e do valor acumulado pela pessoa no mês; vale a mais alta das três.

-- ---------------------------------------------------------------------
-- Fechamento do mês
-- ---------------------------------------------------------------------
create table erp.meses_fechados (
  empresa_id  uuid not null references erp.empresas,
  mes         date not null check (extract(day from mes) = 1),
  fechado_em  timestamptz not null default now(),
  fechado_por uuid default erp.eu(),
  primary key (empresa_id, mes)
);
create trigger t_aud_mes after insert or delete on erp.meses_fechados
  for each row execute function erp.tg_auditoria('mes');
-- O mês só fecha e reabre por fechar_mes e reabrir_mes (definer erp_situacao, S-053).
create function erp.tg_mes_fechado() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then raise exception 'Mês fechado não se altera'; end if;
  if not erp.agindo_como('erp_situacao') then
    raise exception 'O mês só fecha e reabre pela diretoria';
  end if;
  if tg_op = 'INSERT' then
    new.fechado_por := erp.autor();
    new.fechado_em := clock_timestamp();
  end if;
  return coalesce(new, old);
end $$;
create trigger t_mes_fechado before insert or update or delete on erp.meses_fechados
  for each row execute function erp.tg_mes_fechado();

create function erp.fechar_mes(p_empresa uuid, p_mes date) returns void language plpgsql as $$
begin
  perform erp.exigir_diretor();
  if erp.mes(p_mes) > erp.mes(current_date) then raise exception 'Não se fecha mês futuro'; end if;
  if exists (select 1 from generate_series(
               coalesce((select min(competencia) from erp.lancamentos where empresa_id = p_empresa), erp.mes(p_mes)),
               erp.mes(p_mes) - interval '1 month', interval '1 month') g(m)
             where not exists (select 1 from erp.meses_fechados f where f.empresa_id = p_empresa and f.mes = g.m::date)) then
    raise exception 'Feche os meses anteriores primeiro';
  end if;
  insert into erp.meses_fechados (empresa_id, mes) values (p_empresa, erp.mes(p_mes));
end $$;

create function erp.reabrir_mes(p_empresa uuid, p_mes date) returns void language plpgsql as $$
begin
  perform erp.exigir_diretor();
  if exists (select 1 from erp.meses_fechados where empresa_id = p_empresa and mes > erp.mes(p_mes)) then
    raise exception 'Reabra antes os meses seguintes';
  end if;
  delete from erp.meses_fechados where empresa_id = p_empresa and mes = erp.mes(p_mes);
end $$;

-- Faixa de idade de uma competência: o trimestre do calendário fecha quando o último mês dele fecha.
create function erp.faixa_periodo(p_empresa uuid, p_competencia date) returns text language sql stable as $$
  select case
    when not exists (select 1 from erp.meses_fechados where empresa_id = p_empresa and mes = erp.mes(p_competencia))
      then 'mes_aberto'
    when exists (select 1 from erp.meses_fechados where empresa_id = p_empresa
                 and mes = (date_trunc('quarter', p_competencia) + interval '2 months')::date)
      then 'trimestre_fechado'
    else 'trimestre_aberto' end $$;

-- ---------------------------------------------------------------------
-- Alçadas de reclassificação (configuração do administrador)
-- ---------------------------------------------------------------------
create table erp.niveis_aprovacao (
  codigo text primary key,
  nome   text not null,
  peso   int not null unique
);
insert into erp.niveis_aprovacao values
  ('gestor', 'Gestor', 1),
  ('diretor', 'Diretoria', 2),
  ('diretor_e_contador', 'Diretoria e contador', 3);
create trigger t_so_admin before insert or update or delete on erp.niveis_aprovacao
  for each row execute function erp.tg_so_admin();
create trigger t_aud_niveis_aprovacao after insert or update or delete on erp.niveis_aprovacao
  for each row execute function erp.tg_auditoria('codigo');

create table erp.alcadas_reclassificacao (
  id       uuid primary key default gen_random_uuid(),
  criterio text not null check (criterio in ('valor','acumulado_mes')),
  faixa    text check (faixa in ('mes_aberto','trimestre_aberto','trimestre_fechado')),
  ate      numeric(15,2) check (ate > 0),     -- nulo = sem limite
  nivel    text not null references erp.niveis_aprovacao,
  check ((criterio = 'valor') = (faixa is not null)),
  unique nulls not distinct (criterio, faixa, ate)
);
create function erp.tg_alcada() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_config') then perform erp.exigir_admin(); end if;   -- pedido aprovado (_erp_config)
  return coalesce(new, old);
end $$;
create trigger t_alcada before insert or update or delete on erp.alcadas_reclassificacao
  for each row execute function erp.tg_alcada();
create trigger t_aud_alcada after insert or update or delete on erp.alcadas_reclassificacao
  for each row execute function erp.tg_auditoria('id');

-- Padrão: tudo pela diretoria; trimestre fechado também pelo contador. O administrador ajusta
-- (por exemplo, gestor até R$ 5 mil no mês aberto).
insert into erp.alcadas_reclassificacao (criterio, faixa, ate, nivel) values
  ('valor', 'mes_aberto', null, 'diretor'),
  ('valor', 'trimestre_aberto', null, 'diretor'),
  ('valor', 'trimestre_fechado', null, 'diretor_e_contador'),
  ('acumulado_mes', null, null, 'diretor');

-- Menor nível cujo limite cobre o valor (a linha "sem limite" fecha a faixa).
create function erp.nivel_alcada(p_criterio text, p_faixa text, p_valor numeric) returns text
language sql stable as $$
  select nivel from erp.alcadas_reclassificacao
  where criterio = p_criterio and faixa is not distinct from p_faixa and (ate is null or p_valor <= ate)
  order by ate nulls last limit 1 $$;

-- ---------------------------------------------------------------------
-- Reclassificação
-- ---------------------------------------------------------------------
create table erp.reclassificacoes (
  id                  uuid primary key default gen_random_uuid(),
  natureza_origem_id  uuid references erp.naturezas on delete set null,
  natureza_destino_id uuid references erp.naturezas on delete set null,
  origem_nome         text not null,            -- nomes guardados: as naturezas podem ser apagadas depois
  destino_nome        text not null,
  filtro              jsonb not null default '{}',
  motivo              text not null check (length(trim(motivo)) > 0),
  apagar_origem       boolean not null default false,
  valor               numeric(15,2) not null,
  acumulado_mes       numeric(15,2) not null,   -- da pessoa no mês, contando este pedido
  faixa               text not null,            -- a mais antiga entre as linhas
  nivel               text not null references erp.niveis_aprovacao,
  situacao            text not null default 'pendente' check (situacao in ('pendente','aprovada','recusada','cancelada')),
  solicitante         uuid not null,
  pedida_em           timestamptz not null default now(),
  aplicada_em         timestamptz
);

create table erp.reclassificacao_itens (
  reclassificacao_id uuid not null references erp.reclassificacoes on delete cascade,
  lancamento_id      bigint not null references erp.lancamentos,
  natureza_antes     uuid not null,             -- sem FK: as naturezas podem ser apagadas depois
  natureza_depois    uuid not null,
  primary key (reclassificacao_id, lancamento_id)
);
create index on erp.reclassificacao_itens (lancamento_id);

create table erp.reclassificacao_votos (
  reclassificacao_id uuid not null references erp.reclassificacoes on delete cascade,
  user_id            uuid not null,
  como               text not null check (como in ('gestor','diretor','contador','master')),
  aprovou            boolean not null,
  justificativa      text,
  em                 timestamptz not null default now(),
  primary key (reclassificacao_id, user_id),
  check (aprovou or length(trim(coalesce(justificativa, ''))) > 0)
);

-- O pedido, suas linhas e os votos só mudam pelas funções da reclassificação (pedir, decidir,
-- cancelar), definer de erp_reclassificacao (S-037, S-038). Fora delas, não se gravam, alteram
-- nem apagam: voto forjado em nome de outra pessoa não entra.
create function erp.tg_reclassificacao_protegida() returns trigger language plpgsql as $$
begin
  -- a única mudança de fora: a chave estrangeira apagando a natureza que já não existe
  if tg_op = 'UPDATE' and tg_table_name = 'reclassificacoes'
     and (to_jsonb(new) - 'natureza_origem_id' - 'natureza_destino_id') = (to_jsonb(old) - 'natureza_origem_id' - 'natureza_destino_id') then
    if ((to_jsonb(new)->>'natureza_origem_id') is not distinct from (to_jsonb(old)->>'natureza_origem_id')
        or ((to_jsonb(new)->>'natureza_origem_id') is null
            and not exists (select 1 from erp.naturezas where id = (to_jsonb(old)->>'natureza_origem_id')::uuid)))
       and ((to_jsonb(new)->>'natureza_destino_id') is not distinct from (to_jsonb(old)->>'natureza_destino_id')
        or ((to_jsonb(new)->>'natureza_destino_id') is null
            and not exists (select 1 from erp.naturezas where id = (to_jsonb(old)->>'natureza_destino_id')::uuid))) then
      return new;
    end if;
  end if;
  if not erp.agindo_como('erp_reclassificacao') then
    raise exception 'O pedido de reclassificação só muda pelas funções dele (pedir, decidir, cancelar)';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_protegida before insert or update or delete on erp.reclassificacoes
  for each row execute function erp.tg_reclassificacao_protegida();
create trigger t_protegida before insert or update or delete on erp.reclassificacao_itens
  for each row execute function erp.tg_reclassificacao_protegida();
create trigger t_protegida before insert or update or delete on erp.reclassificacao_votos
  for each row execute function erp.tg_reclassificacao_protegida();
create trigger t_sem_truncate before truncate on erp.reclassificacao_votos
  for each statement execute function erp.tg_recusa_truncate();
create trigger t_sem_truncate before truncate on erp.reclassificacoes
  for each statement execute function erp.tg_recusa_truncate();
create trigger t_sem_truncate before truncate on erp.reclassificacao_itens
  for each statement execute function erp.tg_recusa_truncate();

create function erp._peso(p_nivel text) returns int language sql stable as
  $$ select peso from erp.niveis_aprovacao where codigo = p_nivel $$;

-- O destino da reclassificação está liberado em cada centro e divisão das linhas que mudam
-- (Moises, 15/11/2026): as do livro em _itens e, na natureza inteira, os rateios de contrato e de
-- nota que também mudam. Roda dentro das funções definer da reclassificação.
create function erp._reclass_destino_liberado(p_destino uuid, p_origem uuid, p_inteira boolean) returns void language plpgsql as $$
declare v record;
begin
  select x.centro_custo_id, x.divisao_id into v from (
    select l.centro_custo_id, l.divisao_id from erp.lancamentos l join _itens i on i.lancamento_id = l.id
    union select centro_custo_id, divisao_id from erp.compromisso_rateios where p_inteira and natureza_id = p_origem
    union select centro_custo_id, divisao_id from erp.documento_rateios where p_inteira and natureza_id = p_origem) x
   where not erp.natureza_ligada(x.centro_custo_id, x.divisao_id, p_destino) limit 1;
  if found then
    raise exception 'A natureza de destino não está liberada em "%": ligue-a lá ou filtre o pedido',
      coalesce((select c.nome || ' > ' || d.nome from erp.divisoes d join erp.centros_custo c on c.id = d.centro_custo_id where d.id = v.divisao_id),
               (select nome from erp.centros_custo where id = v.centro_custo_id));
  end if;
end $$;

-- Pede a reclassificação. O filtro escolhe as linhas da natureza de origem (empresa, centro,
-- competência de/até, estágios ou ids); as linhas do mesmo título ou previsão vão juntas,
-- para o título não ficar com parte numa natureza e parte noutra.
-- Valor do pedido = maior, entre os estágios, do que as linhas movidas daquele estágio somam num
-- sentido (saídas ou entradas, o maior). O mesmo gasto aparece no previsto, no comprometido e no
-- realizado, e cada estorno repete o valor com sinal trocado; assim não se conta duas ou três vezes.
create function erp.pedir_reclassificacao(p_origem uuid, p_destino uuid, p_motivo text,
  p_filtro jsonb default '{}', p_apagar_origem boolean default false) returns uuid
language plpgsql as $$
declare v_id uuid; v_valor numeric; v_acum numeric; v_faixa text; v_nivel text; v_n int;
begin
  perform erp.exigir_editor();
  if erp.eu() is null then raise exception 'A reclassificação é pedida por quem tem cadastro no ERP'; end if;
  if p_origem = p_destino then raise exception 'Origem e destino são a mesma natureza'; end if;
  perform erp.checar_natureza(p_destino, gen_random_uuid(), gen_random_uuid(), false);  -- destino: último nível, ativo, não só orçado
  if p_apagar_origem and p_filtro <> '{}' then
    raise exception 'Para apagar a natureza, todas as linhas dela precisam sair (sem filtro)';
  end if;

  create temp table if not exists _itens (lancamento_id bigint primary key) on commit drop;
  truncate _itens;
  insert into _itens
  select l.id from erp.lancamentos l
  where l.natureza_id = p_origem
    and (p_filtro->>'empresa_id' is null or l.empresa_id = (p_filtro->>'empresa_id')::uuid)
    and (p_filtro->>'nucleo_economico_id' is null or l.nucleo_economico_id = (p_filtro->>'nucleo_economico_id')::uuid)
    and (p_filtro->>'de' is null or l.competencia >= (p_filtro->>'de')::date)
    and (p_filtro->>'ate' is null or l.competencia <= (p_filtro->>'ate')::date)
    and (p_filtro->'estagios' is null or l.estagio in (select jsonb_array_elements_text(p_filtro->'estagios')))
    and (p_filtro->'lancamentos' is null or l.id in (select (jsonb_array_elements_text(p_filtro->'lancamentos'))::bigint));
  -- leva junto o resto do mesmo título ou previsão (e a previsão que o título consumiu), até não sobrar nada
  loop
    insert into _itens
    select l.id from erp.lancamentos l
    where l.natureza_id = p_origem
      and (l.titulo_id in (select x.titulo_id from erp.lancamentos x join _itens i on i.lancamento_id = x.id)
           or l.previsao_id in (select x.previsao_id from erp.lancamentos x join _itens i on i.lancamento_id = x.id))
    on conflict do nothing;
    get diagnostics v_n = row_count;
    exit when v_n = 0;
  end loop;

  select count(*) into v_n from _itens;
  if v_n = 0 and not p_apagar_origem then raise exception 'Nenhum lançamento encontrado com esse filtro'; end if;
  -- por dentro a função vê o livro todo: o pedido só leva o que quem pede vê na origem e lança no destino
  if not erp.sistema() and exists (select 1 from erp.lancamentos l join _itens i on i.lancamento_id = l.id
                                    where not (erp.vejo(l.nucleo_economico_id, l.centro_custo_id, l.natureza_id, null, l.divisao_id)
                                               and erp.lanco(l.nucleo_economico_id, l.centro_custo_id, p_destino, null, l.divisao_id))) then
    raise exception 'O pedido leva lançamentos fora do seu acesso (núcleo, centro ou natureza); filtre pelo que você lança';
  end if;
  perform erp._reclass_destino_liberado(p_destino, p_origem, p_filtro = '{}');

  select coalesce(max(s), 0) into v_valor from (
    select greatest(coalesce(sum(l.valor) filter (where l.valor > 0), 0), coalesce(-sum(l.valor) filter (where l.valor < 0), 0)) as s
    from erp.lancamentos l join _itens i on i.lancamento_id = l.id group by l.estagio) e;
  select coalesce(sum(valor), 0) + v_valor into v_acum from erp.reclassificacoes
   where solicitante = erp.eu()
     and situacao in ('pendente','aprovada') and date_trunc('month', pedida_em) = date_trunc('month', now());
  select f into v_faixa from (
    select distinct erp.faixa_periodo(l.empresa_id, l.competencia) as f
    from erp.lancamentos l join _itens i on i.lancamento_id = l.id) x
  order by case f when 'trimestre_fechado' then 3 when 'trimestre_aberto' then 2 else 1 end desc limit 1;
  v_faixa := coalesce(v_faixa, 'mes_aberto');

  select codigo into v_nivel from erp.niveis_aprovacao
   where codigo in (erp.nivel_alcada('valor', v_faixa, v_valor), erp.nivel_alcada('acumulado_mes', null, v_acum))
   order by peso desc limit 1;
  if v_nivel is null then raise exception 'Não há alçada configurada para este pedido'; end if;

  insert into erp.reclassificacoes (natureza_origem_id, natureza_destino_id, origem_nome, destino_nome, filtro, motivo, apagar_origem,
                                       valor, acumulado_mes, faixa, nivel, solicitante)
  values (p_origem, p_destino, (select caminho from erp.v_naturezas where id = p_origem),
          (select caminho from erp.v_naturezas where id = p_destino), p_filtro, p_motivo, p_apagar_origem,
          v_valor, v_acum, v_faixa, v_nivel, erp.eu())
  returning id into v_id;
  insert into erp.reclassificacao_itens (reclassificacao_id, lancamento_id, natureza_antes, natureza_depois)
  select v_id, lancamento_id, p_origem, p_destino from _itens;
  return v_id;
end $$;

-- Prévia do impacto, antes de pedir: quantas linhas, quanto, quais meses, se muda DRE ou tipo.
create function erp.previa_reclassificacao(p_id uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'linhas', count(*),
    'valor', r.valor,
    'meses', jsonb_agg(distinct to_char(l.competencia, 'YYYY-MM')),
    'empresas', count(distinct l.empresa_id),
    'faixa', r.faixa,
    'nivel', r.nivel,
    'muda_dre', (select o.linha_dre <> d.linha_dre from erp.naturezas o, erp.naturezas d
                 where o.id = r.natureza_origem_id and d.id = r.natureza_destino_id),
    'muda_tipo', (select o.tipo <> d.tipo from erp.naturezas o, erp.naturezas d
                  where o.id = r.natureza_origem_id and d.id = r.natureza_destino_id))
  from erp.reclassificacoes r
  left join erp.reclassificacao_itens i on i.reclassificacao_id = r.id
  left join erp.lancamentos l on l.id = i.lancamento_id
  where r.id = p_id
  group by r.id, r.valor, r.faixa, r.nivel, r.natureza_origem_id, r.natureza_destino_id $$;

-- Roda dentro do erp.decidir_reclassificacao, que é security definer do erp_reclassificacao
-- (migration _erp_rls): é essa marca que deixa o livro, as previsões e o rateio do título
-- confirmado mudarem só a natureza, e a natureza esvaziada ser apagada. Chamada direta, fora
-- dela, cai nas travas.
create function erp._aplicar_reclassificacao(p_id uuid) returns void language plpgsql as $$
declare r erp.reclassificacoes;
begin
  select * into r from erp.reclassificacoes where id = p_id;
  -- a natureza de destino pode ter sido desligada depois do pedido
  create temp table if not exists _itens (lancamento_id bigint primary key) on commit drop;
  truncate _itens;
  insert into _itens select lancamento_id from erp.reclassificacao_itens where reclassificacao_id = r.id;
  perform erp._reclass_destino_liberado(r.natureza_destino_id, r.natureza_origem_id, r.filtro = '{}');
  -- linhas do livro (só as que ainda estão na origem)
  update erp.lancamentos l set natureza_id = r.natureza_destino_id
    from erp.reclassificacao_itens i
   where i.reclassificacao_id = r.id and i.lancamento_id = l.id and l.natureza_id = r.natureza_origem_id;
  -- e as origens das linhas, para as próximas quitações já caírem no destino
  update erp.titulo_rateios set natureza_id = r.natureza_destino_id
   where natureza_id = r.natureza_origem_id
     and (r.filtro = '{}' or titulo_id in (select l.titulo_id from erp.lancamentos l join erp.reclassificacao_itens i
                                            on i.lancamento_id = l.id where i.reclassificacao_id = r.id));
  update erp.previsoes set natureza_id = r.natureza_destino_id
   where natureza_id = r.natureza_origem_id
     and (r.filtro = '{}' or id in (select l.previsao_id from erp.lancamentos l join erp.reclassificacao_itens i
                                     on i.lancamento_id = l.id where i.reclassificacao_id = r.id));
  if r.filtro = '{}' then   -- natureza inteira: contratos, notas e orçamentos em rascunho também
    update erp.compromisso_rateios set natureza_id = r.natureza_destino_id where natureza_id = r.natureza_origem_id;
    update erp.documento_rateios set natureza_id = r.natureza_destino_id where natureza_id = r.natureza_origem_id;
    update erp.orcamento_linhas l set natureza_id = r.natureza_destino_id
      from erp.orcamento_versoes v
     where v.id = l.versao_id and v.situacao = 'rascunho' and l.natureza_id = r.natureza_origem_id;
  end if;
  update erp.reclassificacoes set situacao = 'aprovada', aplicada_em = now() where id = r.id;
  if r.apagar_origem then
    if erp.natureza_em_uso(r.natureza_origem_id) then
      raise exception 'A natureza de origem ainda tem uso (orçamento vigente ou natureza do sistema); não pode ser apagada';
    end if;
    delete from erp.naturezas where id = r.natureza_origem_id;
  end if;
end $$;

-- Voto. Quem pediu não aprova. Recusar exige justificativa e encerra o pedido.
-- gestor: um voto de gestor ou diretor; diretor: um voto de diretor;
-- diretor_e_contador: um de diretor e um de contador (pessoas diferentes).
create function erp.decidir_reclassificacao(p_id uuid, p_aprovar boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare r erp.reclassificacoes; u erp.usuarios; v_como text; v_ok boolean;
begin
  select * into r from erp.reclassificacoes where id = p_id for update;
  if r.situacao <> 'pendente' then raise exception 'O pedido não está pendente'; end if;
  select * into u from erp.meu_usuario();
  if u.id is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  if u.id = r.solicitante and not erp.sou_master() then raise exception 'Quem pediu a reclassificação não pode aprová-la'; end if;   -- o master aprova o dele
  if u.administrador then raise exception 'Administrador não aprova nada no ERP'; end if;   -- S-085
  if exists (select 1 from erp.reclassificacao_votos where reclassificacao_id = r.id and user_id = u.id) then
    raise exception 'Você já votou neste pedido';
  end if;

  v_como := case
    when erp.sou_master() then 'master'          -- o voto do master basta, em qualquer nível (Moises, 14/11/2026)
    when r.nivel = 'gestor' and u.papel in ('gestor','diretor') then u.papel
    when r.nivel = 'diretor' and u.papel = 'diretor' then 'diretor'
    when r.nivel = 'diretor_e_contador' and u.papel = 'diretor'
         and not exists (select 1 from erp.reclassificacao_votos where reclassificacao_id = r.id and como = 'diretor') then 'diretor'
    when r.nivel = 'diretor_e_contador' and u.contador
         and not exists (select 1 from erp.reclassificacao_votos where reclassificacao_id = r.id and como = 'contador') then 'contador'
  end;
  if v_como is null then
    raise exception 'Este pedido precisa de: %', (select nome from erp.niveis_aprovacao where codigo = r.nivel);
  end if;

  insert into erp.reclassificacao_votos (reclassificacao_id, user_id, como, aprovou, justificativa)
  values (r.id, u.id, v_como, p_aprovar, p_justificativa);

  if not p_aprovar then
    update erp.reclassificacoes set situacao = 'recusada' where id = r.id;
    return 'recusada';
  end if;
  v_ok := case when v_como = 'master' then true else case r.nivel
    when 'diretor_e_contador' then
      exists (select 1 from erp.reclassificacao_votos where reclassificacao_id = r.id and como = 'diretor' and aprovou)
      and exists (select 1 from erp.reclassificacao_votos where reclassificacao_id = r.id and como = 'contador' and aprovou)
    else true end end;
  if not v_ok then return 'pendente'; end if;
  perform erp._aplicar_reclassificacao(r.id);
  return 'aprovada';
end $$;

create function erp.cancelar_reclassificacao(p_id uuid) returns void language plpgsql as $$
begin
  -- só quem pediu, com cadastro no ERP (S-058): erp.eu() nulo não é igual a ninguém
  perform erp.exigir_editor();
  update erp.reclassificacoes set situacao = 'cancelada'
   where id = p_id and situacao = 'pendente' and solicitante = erp.eu();
  if not found then raise exception 'Só quem pediu cancela, e só pedido pendente'; end if;
end $$;

-- A natureza só se apaga pela reclassificação que a esvazia, ou se nunca foi usada
-- (a regra de uso já está no gatilho da árvore). O apagar da reclassificação passa pela
-- diretoria que aprovou, mesmo que quem aprovou não seja administrador.
create or replace function erp.exigir_admin() returns void language plpgsql stable as $$
begin
  if erp.sistema() or erp.agindo_como('erp_reclassificacao') then return; end if;
  -- o master faz qualquer coisa (Moises, 14/11/2026); erp.sou_master entra na migration _erp_perfis
  if not coalesce((erp.meu_usuario()).administrador, false) and not erp.sou_master() then
    raise exception 'Só o administrador pode mudar a configuração';
  end if;
end $$;
