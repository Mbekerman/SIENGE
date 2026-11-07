-- Núcleo do ERP BKM: fechamento do mês, alçadas e reclassificação de naturezas.
-- Decisões do Moises (7/nov/2026): toda reclassificação precisa de aval; a alçada depende
-- da idade (mês aberto, mês fechado com trimestre do calendário aberto, trimestre fechado),
-- do valor e do valor acumulado pela pessoa no mês; vale a mais alta das três.

-- ---------------------------------------------------------------------
-- Fechamento do mês
-- ---------------------------------------------------------------------
create table nucleo.meses_fechados (
  empresa_id  uuid not null references nucleo.empresas,
  mes         date not null check (extract(day from mes) = 1),
  fechado_em  timestamptz not null default now(),
  fechado_por uuid default nucleo.eu(),
  primary key (empresa_id, mes)
);
create trigger t_aud_mes after insert or delete on nucleo.meses_fechados
  for each row execute function nucleo.tg_auditoria('mes');

create function nucleo.fechar_mes(p_empresa uuid, p_mes date) returns void language plpgsql as $$
begin
  perform nucleo.exigir_diretor();
  if nucleo.mes(p_mes) > nucleo.mes(current_date) then raise exception 'Não se fecha mês futuro'; end if;
  if exists (select 1 from generate_series(
               coalesce((select min(competencia) from nucleo.lancamentos where empresa_id = p_empresa), nucleo.mes(p_mes)),
               nucleo.mes(p_mes) - interval '1 month', interval '1 month') g(m)
             where not exists (select 1 from nucleo.meses_fechados f where f.empresa_id = p_empresa and f.mes = g.m::date)) then
    raise exception 'Feche os meses anteriores primeiro';
  end if;
  insert into nucleo.meses_fechados (empresa_id, mes) values (p_empresa, nucleo.mes(p_mes));
end $$;

create function nucleo.reabrir_mes(p_empresa uuid, p_mes date) returns void language plpgsql as $$
begin
  perform nucleo.exigir_diretor();
  if exists (select 1 from nucleo.meses_fechados where empresa_id = p_empresa and mes > nucleo.mes(p_mes)) then
    raise exception 'Reabra antes os meses seguintes';
  end if;
  delete from nucleo.meses_fechados where empresa_id = p_empresa and mes = nucleo.mes(p_mes);
end $$;

-- Faixa de idade de uma competência: o trimestre do calendário fecha quando o último mês dele fecha.
create function nucleo.faixa_periodo(p_empresa uuid, p_competencia date) returns text language sql stable as $$
  select case
    when not exists (select 1 from nucleo.meses_fechados where empresa_id = p_empresa and mes = nucleo.mes(p_competencia))
      then 'mes_aberto'
    when exists (select 1 from nucleo.meses_fechados where empresa_id = p_empresa
                 and mes = (date_trunc('quarter', p_competencia) + interval '2 months')::date)
      then 'trimestre_fechado'
    else 'trimestre_aberto' end $$;

-- ---------------------------------------------------------------------
-- Alçadas de reclassificação (configuração do administrador)
-- ---------------------------------------------------------------------
create table nucleo.niveis_aprovacao (
  codigo text primary key,
  nome   text not null,
  peso   int not null unique
);
insert into nucleo.niveis_aprovacao values
  ('gestor', 'Gestor', 1),
  ('diretor', 'Diretoria', 2),
  ('diretor_e_contador', 'Diretoria e contador', 3);

create table nucleo.alcadas_reclassificacao (
  id       uuid primary key default gen_random_uuid(),
  criterio text not null check (criterio in ('valor','acumulado_mes')),
  faixa    text check (faixa in ('mes_aberto','trimestre_aberto','trimestre_fechado')),
  ate      numeric(15,2) check (ate > 0),     -- nulo = sem limite
  nivel    text not null references nucleo.niveis_aprovacao,
  check ((criterio = 'valor') = (faixa is not null)),
  unique nulls not distinct (criterio, faixa, ate)
);
create function nucleo.tg_alcada() returns trigger language plpgsql as $$
begin perform nucleo.exigir_admin(); return coalesce(new, old); end $$;
create trigger t_alcada before insert or update or delete on nucleo.alcadas_reclassificacao
  for each row execute function nucleo.tg_alcada();
create trigger t_aud_alcada after insert or update or delete on nucleo.alcadas_reclassificacao
  for each row execute function nucleo.tg_auditoria('id');

-- Padrão: tudo pela diretoria; trimestre fechado também pelo contador. O administrador ajusta
-- (por exemplo, gestor até R$ 5 mil no mês aberto).
insert into nucleo.alcadas_reclassificacao (criterio, faixa, ate, nivel) values
  ('valor', 'mes_aberto', null, 'diretor'),
  ('valor', 'trimestre_aberto', null, 'diretor'),
  ('valor', 'trimestre_fechado', null, 'diretor_e_contador'),
  ('acumulado_mes', null, null, 'diretor');

-- Menor nível cujo limite cobre o valor (a linha "sem limite" fecha a faixa).
create function nucleo.nivel_alcada(p_criterio text, p_faixa text, p_valor numeric) returns text
language sql stable as $$
  select nivel from nucleo.alcadas_reclassificacao
  where criterio = p_criterio and faixa is not distinct from p_faixa and (ate is null or p_valor <= ate)
  order by ate nulls last limit 1 $$;

-- ---------------------------------------------------------------------
-- Reclassificação
-- ---------------------------------------------------------------------
create table nucleo.reclassificacoes (
  id                  uuid primary key default gen_random_uuid(),
  natureza_origem_id  uuid references nucleo.naturezas on delete set null,
  natureza_destino_id uuid references nucleo.naturezas on delete set null,
  origem_nome         text not null,            -- nomes guardados: as naturezas podem ser apagadas depois
  destino_nome        text not null,
  filtro              jsonb not null default '{}',
  motivo              text not null check (length(trim(motivo)) > 0),
  apagar_origem       boolean not null default false,
  valor               numeric(15,2) not null,
  acumulado_mes       numeric(15,2) not null,   -- da pessoa no mês, contando este pedido
  faixa               text not null,            -- a mais antiga entre as linhas
  nivel               text not null references nucleo.niveis_aprovacao,
  situacao            text not null default 'pendente' check (situacao in ('pendente','aprovada','recusada','cancelada')),
  solicitante         uuid not null,
  pedida_em           timestamptz not null default now(),
  aplicada_em         timestamptz
);

create table nucleo.reclassificacao_itens (
  reclassificacao_id uuid not null references nucleo.reclassificacoes on delete cascade,
  lancamento_id      bigint not null references nucleo.lancamentos,
  natureza_antes     uuid not null,             -- sem FK: as naturezas podem ser apagadas depois
  natureza_depois    uuid not null,
  primary key (reclassificacao_id, lancamento_id)
);
create index on nucleo.reclassificacao_itens (lancamento_id);

create table nucleo.reclassificacao_votos (
  reclassificacao_id uuid not null references nucleo.reclassificacoes on delete cascade,
  user_id            uuid not null,
  como               text not null check (como in ('gestor','diretor','contador')),
  aprovou            boolean not null,
  justificativa      text,
  em                 timestamptz not null default now(),
  primary key (reclassificacao_id, user_id),
  check (aprovou or length(trim(coalesce(justificativa, ''))) > 0)
);

create function nucleo._peso(p_nivel text) returns int language sql stable as
  $$ select peso from nucleo.niveis_aprovacao where codigo = p_nivel $$;

-- Pede a reclassificação. O filtro escolhe as linhas da natureza de origem (empresa, centro,
-- competência de/até, estágios ou ids); as linhas do mesmo título ou previsão vão juntas,
-- para o título não ficar com parte numa natureza e parte noutra.
-- Valor do pedido = maior, entre os estágios, do que as linhas movidas daquele estágio somam num
-- sentido (saídas ou entradas, o maior). O mesmo gasto aparece no previsto, no comprometido e no
-- realizado, e cada estorno repete o valor com sinal trocado; assim não se conta duas ou três vezes.
create function nucleo.pedir_reclassificacao(p_origem uuid, p_destino uuid, p_motivo text,
  p_filtro jsonb default '{}', p_apagar_origem boolean default false) returns uuid
language plpgsql as $$
declare v_id uuid; v_valor numeric; v_acum numeric; v_faixa text; v_nivel text; v_n int;
begin
  perform nucleo.exigir_editor();
  if p_origem = p_destino then raise exception 'Origem e destino são a mesma natureza'; end if;
  perform nucleo.checar_natureza(p_destino, gen_random_uuid(), false);  -- destino: último nível, ativo, não só orçado
  if p_apagar_origem and p_filtro <> '{}' then
    raise exception 'Para apagar a natureza, todas as linhas dela precisam sair (sem filtro)';
  end if;

  create temp table if not exists _itens (lancamento_id bigint primary key) on commit drop;
  truncate _itens;
  insert into _itens
  select l.id from nucleo.lancamentos l
  where l.natureza_id = p_origem
    and (p_filtro->>'empresa_id' is null or l.empresa_id = (p_filtro->>'empresa_id')::uuid)
    and (p_filtro->>'centro_id' is null or l.centro_id = (p_filtro->>'centro_id')::uuid)
    and (p_filtro->>'de' is null or l.competencia >= (p_filtro->>'de')::date)
    and (p_filtro->>'ate' is null or l.competencia <= (p_filtro->>'ate')::date)
    and (p_filtro->'estagios' is null or l.estagio in (select jsonb_array_elements_text(p_filtro->'estagios')))
    and (p_filtro->'lancamentos' is null or l.id in (select (jsonb_array_elements_text(p_filtro->'lancamentos'))::bigint));
  -- leva junto o resto do mesmo título ou previsão (e a previsão que o título consumiu), até não sobrar nada
  loop
    insert into _itens
    select l.id from nucleo.lancamentos l
    where l.natureza_id = p_origem
      and (l.titulo_id in (select x.titulo_id from nucleo.lancamentos x join _itens i on i.lancamento_id = x.id)
           or l.previsao_id in (select x.previsao_id from nucleo.lancamentos x join _itens i on i.lancamento_id = x.id))
    on conflict do nothing;
    get diagnostics v_n = row_count;
    exit when v_n = 0;
  end loop;

  select count(*) into v_n from _itens;
  if v_n = 0 and not p_apagar_origem then raise exception 'Nenhum lançamento encontrado com esse filtro'; end if;

  select coalesce(max(s), 0) into v_valor from (
    select greatest(coalesce(sum(l.valor) filter (where l.valor > 0), 0), coalesce(-sum(l.valor) filter (where l.valor < 0), 0)) as s
    from nucleo.lancamentos l join _itens i on i.lancamento_id = l.id group by l.estagio) e;
  select coalesce(sum(valor), 0) + v_valor into v_acum from nucleo.reclassificacoes
   where solicitante = coalesce(nucleo.eu(), '00000000-0000-0000-0000-000000000000')
     and situacao in ('pendente','aprovada') and date_trunc('month', pedida_em) = date_trunc('month', now());
  select f into v_faixa from (
    select distinct nucleo.faixa_periodo(l.empresa_id, l.competencia) as f
    from nucleo.lancamentos l join _itens i on i.lancamento_id = l.id) x
  order by case f when 'trimestre_fechado' then 3 when 'trimestre_aberto' then 2 else 1 end desc limit 1;
  v_faixa := coalesce(v_faixa, 'mes_aberto');

  select codigo into v_nivel from nucleo.niveis_aprovacao
   where codigo in (nucleo.nivel_alcada('valor', v_faixa, v_valor), nucleo.nivel_alcada('acumulado_mes', null, v_acum))
   order by peso desc limit 1;
  if v_nivel is null then raise exception 'Não há alçada configurada para este pedido'; end if;

  insert into nucleo.reclassificacoes (natureza_origem_id, natureza_destino_id, origem_nome, destino_nome, filtro, motivo, apagar_origem,
                                       valor, acumulado_mes, faixa, nivel, solicitante)
  values (p_origem, p_destino, (select caminho from nucleo.v_naturezas where id = p_origem),
          (select caminho from nucleo.v_naturezas where id = p_destino), p_filtro, p_motivo, p_apagar_origem,
          v_valor, v_acum, v_faixa, v_nivel, coalesce(nucleo.eu(), '00000000-0000-0000-0000-000000000000'))
  returning id into v_id;
  insert into nucleo.reclassificacao_itens (reclassificacao_id, lancamento_id, natureza_antes, natureza_depois)
  select v_id, lancamento_id, p_origem, p_destino from _itens;
  return v_id;
end $$;

-- Prévia do impacto, antes de pedir: quantas linhas, quanto, quais meses, se muda DRE ou tipo.
create function nucleo.previa_reclassificacao(p_id uuid) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'linhas', count(*),
    'valor', r.valor,
    'meses', jsonb_agg(distinct to_char(l.competencia, 'YYYY-MM')),
    'empresas', count(distinct l.empresa_id),
    'faixa', r.faixa,
    'nivel', r.nivel,
    'muda_dre', (select o.linha_dre <> d.linha_dre from nucleo.naturezas o, nucleo.naturezas d
                 where o.id = r.natureza_origem_id and d.id = r.natureza_destino_id),
    'muda_tipo', (select o.tipo <> d.tipo from nucleo.naturezas o, nucleo.naturezas d
                  where o.id = r.natureza_origem_id and d.id = r.natureza_destino_id))
  from nucleo.reclassificacoes r
  left join nucleo.reclassificacao_itens i on i.reclassificacao_id = r.id
  left join nucleo.lancamentos l on l.id = i.lancamento_id
  where r.id = p_id
  group by r.id, r.valor, r.faixa, r.nivel, r.natureza_origem_id, r.natureza_destino_id $$;

create function nucleo._aplicar_reclassificacao(p_id uuid) returns void language plpgsql as $$
declare r nucleo.reclassificacoes;
begin
  select * into r from nucleo.reclassificacoes where id = p_id;
  perform set_config('nucleo.reclassificando', 'on', true);
  -- linhas do livro (só as que ainda estão na origem)
  update nucleo.lancamentos l set natureza_id = r.natureza_destino_id
    from nucleo.reclassificacao_itens i
   where i.reclassificacao_id = r.id and i.lancamento_id = l.id and l.natureza_id = r.natureza_origem_id;
  -- e as origens das linhas, para as próximas quitações já caírem no destino
  update nucleo.titulo_rateios set natureza_id = r.natureza_destino_id
   where natureza_id = r.natureza_origem_id
     and (r.filtro = '{}' or titulo_id in (select l.titulo_id from nucleo.lancamentos l join nucleo.reclassificacao_itens i
                                            on i.lancamento_id = l.id where i.reclassificacao_id = r.id));
  update nucleo.previsoes set natureza_id = r.natureza_destino_id
   where natureza_id = r.natureza_origem_id
     and (r.filtro = '{}' or id in (select l.previsao_id from nucleo.lancamentos l join nucleo.reclassificacao_itens i
                                     on i.lancamento_id = l.id where i.reclassificacao_id = r.id));
  if r.filtro = '{}' then   -- natureza inteira: contratos, notas e orçamentos em rascunho também
    update nucleo.compromisso_rateios set natureza_id = r.natureza_destino_id where natureza_id = r.natureza_origem_id;
    update nucleo.documento_rateios set natureza_id = r.natureza_destino_id where natureza_id = r.natureza_origem_id;
    update nucleo.orcamento_linhas l set natureza_id = r.natureza_destino_id
      from nucleo.orcamento_versoes v
     where v.id = l.versao_id and v.situacao = 'rascunho' and l.natureza_id = r.natureza_origem_id;
  end if;
  perform set_config('nucleo.reclassificando', 'off', true);
  update nucleo.reclassificacoes set situacao = 'aprovada', aplicada_em = now() where id = r.id;
  if r.apagar_origem then
    if nucleo.natureza_em_uso(r.natureza_origem_id) then
      raise exception 'A natureza de origem ainda tem uso (orçamento vigente ou natureza do sistema); não pode ser apagada';
    end if;
    perform set_config('nucleo.sistema_apaga', 'on', true);
    delete from nucleo.naturezas where id = r.natureza_origem_id;
    perform set_config('nucleo.sistema_apaga', 'off', true);
  end if;
end $$;

-- Voto. Quem pediu não aprova. Recusar exige justificativa e encerra o pedido.
-- gestor: um voto de gestor ou diretor; diretor: um voto de diretor;
-- diretor_e_contador: um de diretor e um de contador (pessoas diferentes).
create function nucleo.decidir_reclassificacao(p_id uuid, p_aprovar boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare r nucleo.reclassificacoes; u nucleo.usuarios; v_como text; v_ok boolean;
begin
  select * into r from nucleo.reclassificacoes where id = p_id for update;
  if r.situacao <> 'pendente' then raise exception 'O pedido não está pendente'; end if;
  select * into u from nucleo.usuarios where user_id = nucleo.eu() and ativo;
  if u.user_id is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  if u.user_id = r.solicitante then raise exception 'Quem pediu a reclassificação não pode aprová-la'; end if;
  if exists (select 1 from nucleo.reclassificacao_votos where reclassificacao_id = r.id and user_id = u.user_id) then
    raise exception 'Você já votou neste pedido';
  end if;

  v_como := case
    when r.nivel = 'gestor' and u.papel in ('gestor','diretor') then u.papel
    when r.nivel = 'diretor' and u.papel = 'diretor' then 'diretor'
    when r.nivel = 'diretor_e_contador' and u.papel = 'diretor'
         and not exists (select 1 from nucleo.reclassificacao_votos where reclassificacao_id = r.id and como = 'diretor') then 'diretor'
    when r.nivel = 'diretor_e_contador' and u.contador
         and not exists (select 1 from nucleo.reclassificacao_votos where reclassificacao_id = r.id and como = 'contador') then 'contador'
  end;
  if v_como is null then
    raise exception 'Este pedido precisa de: %', (select nome from nucleo.niveis_aprovacao where codigo = r.nivel);
  end if;

  insert into nucleo.reclassificacao_votos (reclassificacao_id, user_id, como, aprovou, justificativa)
  values (r.id, u.user_id, v_como, p_aprovar, p_justificativa);

  if not p_aprovar then
    update nucleo.reclassificacoes set situacao = 'recusada' where id = r.id;
    return 'recusada';
  end if;
  v_ok := case r.nivel
    when 'diretor_e_contador' then
      exists (select 1 from nucleo.reclassificacao_votos where reclassificacao_id = r.id and como = 'diretor' and aprovou)
      and exists (select 1 from nucleo.reclassificacao_votos where reclassificacao_id = r.id and como = 'contador' and aprovou)
    else true end;
  if not v_ok then return 'pendente'; end if;
  perform nucleo._aplicar_reclassificacao(r.id);
  return 'aprovada';
end $$;

create function nucleo.cancelar_reclassificacao(p_id uuid) returns void language plpgsql as $$
begin
  update nucleo.reclassificacoes set situacao = 'cancelada'
   where id = p_id and situacao = 'pendente' and solicitante = coalesce(nucleo.eu(), solicitante);
  if not found then raise exception 'Só quem pediu cancela, e só pedido pendente'; end if;
end $$;

-- A natureza só se apaga pela reclassificação que a esvazia, ou se nunca foi usada
-- (a regra de uso já está no gatilho da árvore). O apagar da reclassificação passa pela
-- diretoria que aprovou, mesmo que quem aprovou não seja administrador.
create or replace function nucleo.exigir_admin() returns void language plpgsql stable as $$
begin
  if nucleo.eu() is null or current_setting('nucleo.sistema_apaga', true) = 'on' then return; end if;
  if not exists (select 1 from nucleo.usuarios where user_id = nucleo.eu() and ativo and administrador) then
    raise exception 'Só o administrador pode mudar a configuração';
  end if;
end $$;
