-- Cruzamento das linhas PRV com o Sienge (Moises, 14/11/2026: "cruzamento recria linha faltante e marca
-- estranha inválida avisando o AF"; verificação completa de madrugada; 17/11/2026: "Comece").
--
-- De madrugada (2h às 6h em São Paulo), uma empresa por vez, o programa lista no Sienge os títulos do
-- documento PRV da empresa (GET /bills por emissão, documentsIdentificationId=PRV) e compara com as nossas:
-- 1. Faltante: previsão aberta, enviada, fora da lista do que apagar, cujo título não aparece na lista e
--    responde 404 no GET /bills/{id}. O título foi apagado à mão sem a previsão sair de aberta: o banco
--    guarda o id antigo em erp.sienge_prv_trocas, solta o id e devolve a previsão à fila, que cria outra
--    linha PRV. Evento prv_recriada para a lista AF.
-- 2. Estranha: título PRV do Sienge que não é nenhum dos nossos (nem atual, nem antigo, nem de previsão a
--    apagar), ou que leva o marcador de uma previsão nossa ligada a outro título. Fica em
--    erp.sienge_prv_estranhas; as novas de cada passada geram um evento prv_estranhas para a lista AF, com
--    a quantidade. A lista vai da emissão da primeira linha PRV do ERP na empresa até hoje (no máximo 3
--    anos): as PRV lançadas antes do ERP não aparecem.
-- O banco não marca nada no Sienge (a API não edita o título); "inválida" é a marca do nosso lado.
-- O e-mail sai pelo canal geral dos eventos, quando existir.
-- Portabilidade: SQL puro.

-- ---------------------------------------------------------------------------------------------
-- Histórico de troca de id (a linha PRV recriada)
-- ---------------------------------------------------------------------------------------------
create table erp.sienge_prv_trocas (
  id            uuid primary key default gen_random_uuid(),
  previsao_id   uuid not null references erp.previsoes,
  sienge_id     int not null unique,          -- o id antigo, que sumiu do Sienge
  motivo        text not null check (length(trim(motivo)) > 0),
  em            timestamptz not null default clock_timestamp()
);
create index on erp.sienge_prv_trocas (previsao_id);

create function erp.tg_sienge_prv_troca() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'O histórico do Sienge só é escrito pelo sistema'; end if;
  if tg_op <> 'INSERT' then raise exception 'O histórico do Sienge não se altera nem se apaga'; end if;
  return new;
end $$;
create trigger t_sienge_prv_troca before insert or update or delete on erp.sienge_prv_trocas
  for each row execute function erp.tg_sienge_prv_troca();
create trigger t_aud_sienge_prv_trocas after insert on erp.sienge_prv_trocas
  for each row execute function erp.tg_auditoria('previsao_id');

-- A fila deixa soltar o id só quando a troca está registrada (e só da enviada, aberta, sem marca de apagar).
create or replace function erp.tg_sienge_previsao() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'A fila do Sienge só é escrita pelo sistema'; end if;
  if tg_op = 'DELETE' then raise exception 'A fila do Sienge não se apaga'; end if;
  if tg_op = 'UPDATE' then
    if new.previsao_id <> old.previsao_id or new.criado_em <> old.criado_em then raise exception 'Previsão e data da fila não mudam'; end if;
    if old.sienge_id is not null and new.sienge_id is distinct from old.sienge_id then
      if not (new.sienge_id is null and old.apagar_desde is null
              and exists (select 1 from erp.sienge_prv_trocas x where x.previsao_id = old.previsao_id and x.sienge_id = old.sienge_id)) then
        raise exception 'A previsão já tem id no Sienge (%); não troca', old.sienge_id;
      end if;
    end if;
    if old.apagar_desde is not null and new.apagar_desde is distinct from old.apagar_desde then
      raise exception 'A marca de apagar não muda';
    end if;
    if old.apagado_em is not null and new.apagado_em is distinct from old.apagado_em then
      raise exception 'A previsão já foi apagada do Sienge';
    end if;
    new.atualizado_em := clock_timestamp();
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Linhas estranhas e as passadas do cruzamento
-- ---------------------------------------------------------------------------------------------
create table erp.sienge_prv_estranhas (
  sienge_id       int primary key,
  empresa_sienge  int not null,
  numero          text,
  emissao         date,
  valor           numeric(15,2),
  observacoes     text,
  motivo          text not null,
  primeira_vez    timestamptz not null default clock_timestamp(),
  ultima_vez      timestamptz not null default clock_timestamp(),
  sumiu_em        timestamptz                  -- não apareceu mais numa passada da empresa
);

create table erp.sienge_cruzamentos (
  dia             date not null,               -- o dia em São Paulo
  empresa_sienge  int not null,
  situacao        text not null default 'rodando' check (situacao in ('rodando','ok','erro')),
  inicio          timestamptz not null default clock_timestamp(),
  fim             timestamptz,
  tentativas      int not null default 1,
  resumo          jsonb,
  erro            text,
  primary key (dia, empresa_sienge)
);

create function erp.tg_sienge_cruzamento() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'O cruzamento do Sienge só é escrito pelo sistema'; end if;
  if tg_op = 'DELETE' then raise exception 'O cruzamento do Sienge não se apaga'; end if;
  return new;
end $$;
create trigger t_sienge_prv_estranha before insert or update or delete on erp.sienge_prv_estranhas
  for each row execute function erp.tg_sienge_cruzamento();
create trigger t_sienge_cruzamento before insert or update or delete on erp.sienge_cruzamentos
  for each row execute function erp.tg_sienge_cruzamento();

insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('prv_recriada', 'Linha PRV apagada no Sienge com a previsão aberta: recriada', 'pagar', false),
  ('prv_estranhas', 'Linhas PRV no Sienge que não são do ERP', 'pagar', true);
insert into erp.regras_notificacao (tipo, destino, lista) values
  ('prv_recriada', 'lista', 'AF'), ('prv_estranhas', 'lista', 'AF');

-- ---------------------------------------------------------------------------------------------
-- Funções do programa (só o sistema)
-- ---------------------------------------------------------------------------------------------
-- A próxima empresa a cruzar hoje, de madrugada: a que ainda não passou hoje, ou a que falhou (até 3
-- vezes, 30 minutos depois), ou a que ficou "rodando" por mais de 1 hora. Reserva a passada.
-- desde: a menor emissão das nossas linhas esperadas na empresa, e no máximo 3 anos para trás.
create function erp.sienge_pegar_cruzamento(p_agora timestamptz default now())
returns table (empresa_sienge int, desde date) language plpgsql as $$
#variable_conflict use_column
declare v_local timestamp := p_agora at time zone 'America/Sao_Paulo'; v_dia date := v_local::date; v_emp int;
begin
  if not erp.sistema() then raise exception 'Só o sistema cruza o Sienge'; end if;
  if extract(hour from v_local) < 2 or extract(hour from v_local) >= 6 then return; end if;
  select e.codigo::int into v_emp
    from (select distinct c.codigo from erp.codigos_externos c
           where c.sistema = 'sienge' and c.tabela = 'empresas' and c.codigo ~ '^[0-9]{1,9}$') e
    left join erp.sienge_cruzamentos x on x.dia = v_dia and x.empresa_sienge = e.codigo::int
   where x.dia is null
      or (x.situacao = 'erro' and x.tentativas < 3 and x.fim < p_agora - interval '30 minutes')
      or (x.situacao = 'rodando' and x.inicio < p_agora - interval '1 hour' and x.tentativas < 3)
   order by e.codigo::int limit 1;
  if v_emp is null then return; end if;
  insert into erp.sienge_cruzamentos (dia, empresa_sienge, inicio) values (v_dia, v_emp, p_agora)
  on conflict (dia, empresa_sienge) do update
     set situacao = 'rodando', inicio = p_agora, fim = null, erro = null, tentativas = erp.sienge_cruzamentos.tentativas + 1;
  return query
  select v_emp, greatest((v_local - interval '3 years')::date,
                         coalesce((select min((p.criada_em at time zone 'America/Sao_Paulo')::date)
                                     from erp.sienge_previsoes s join erp.previsoes p on p.id = s.previsao_id
                                     join erp.codigos_externos c on c.sistema = 'sienge' and c.tabela = 'empresas' and c.registro_id = p.empresa_id
                                    where s.sienge_id is not null and c.codigo = v_emp::text), v_dia));
end $$;

-- As nossas linhas PRV na empresa: as esperadas no Sienge (enviada, aberta, sem marca de apagar) e as
-- conhecidas (atuais, a apagar, já apagadas e as trocadas), para separar o que é estranho.
create function erp.sienge_prv_nossas(p_empresa int)
returns table (sienge_id int, previsao_id uuid, esperada boolean) language plpgsql stable as $$
#variable_conflict use_column
begin
  if not erp.sistema() then raise exception 'Só o sistema cruza o Sienge'; end if;
  return query
  select s.sienge_id, s.previsao_id, (s.situacao = 'enviado' and s.apagar_desde is null and p.situacao = 'aberta')
    from erp.sienge_previsoes s join erp.previsoes p on p.id = s.previsao_id
    join erp.codigos_externos c on c.sistema = 'sienge' and c.tabela = 'empresas' and c.registro_id = p.empresa_id
   where s.sienge_id is not null and c.codigo = p_empresa::text
  union all
  select x.sienge_id, x.previsao_id, false
    from erp.sienge_prv_trocas x join erp.previsoes p on p.id = x.previsao_id
    join erp.codigos_externos c on c.sistema = 'sienge' and c.tabela = 'empresas' and c.registro_id = p.empresa_id
   where c.codigo = p_empresa::text;
end $$;

-- A linha PRV esperada sumiu do Sienge (fora da lista e 404): guarda o id antigo, solta o id e devolve a
-- previsão à fila, que cria outra linha. Só a enviada, aberta e sem marca de apagar.
create function erp.sienge_recriar_prv(p_previsao uuid, p_sienge_id int, p_motivo text) returns void language plpgsql as $$
declare s erp.sienge_previsoes; p erp.previsoes;
begin
  if not erp.sistema() then raise exception 'Só o sistema cruza o Sienge'; end if;
  select * into s from erp.sienge_previsoes where previsao_id = p_previsao for update;
  select * into p from erp.previsoes where id = p_previsao;
  if s.previsao_id is null or s.sienge_id is distinct from p_sienge_id then raise exception 'A previsão não está ligada a este título do Sienge'; end if;
  if s.situacao <> 'enviado' or s.apagar_desde is not null or p.situacao <> 'aberta' then
    raise exception 'Só a linha PRV enviada de previsão aberta se recria';
  end if;
  insert into erp.sienge_prv_trocas (previsao_id, sienge_id, motivo) values (p_previsao, p_sienge_id, p_motivo);
  delete from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes' and registro_id = p_previsao;
  update erp.sienge_previsoes
     set sienge_id = null, situacao = 'pendente', passo = null, tentativas = 0, proxima_em = now(), erro = null
   where previsao_id = p_previsao;
  perform erp.registrar_evento('prv_recriada', 'previsoes', p_previsao::text, p.nucleo_economico_id, p.centro_custo_id,
    jsonb_build_object('previsao_id', p_previsao, 'sienge_id_antigo', p_sienge_id,
                       'motivo', 'A linha PRV ' || p_sienge_id || ' sumiu do Sienge com a previsão aberta; vai outra'));
end $$;

-- Fecha a passada da empresa: grava as estranhas vistas (lista jsonb de {sienge_id, numero, emissao,
-- valor, observacoes, motivo}), marca as que sumiram e avisa a AF das novas.
create function erp.sienge_terminar_cruzamento(p_empresa int, p_estranhas jsonb, p_resumo jsonb, p_erro text default null,
                                               p_agora timestamptz default now())
returns int language plpgsql as $$
declare v_dia date := (p_agora at time zone 'America/Sao_Paulo')::date; v_novas int := 0; v_ids int[];
begin
  if not erp.sistema() then raise exception 'Só o sistema cruza o Sienge'; end if;
  if not exists (select 1 from erp.sienge_cruzamentos where dia = v_dia and empresa_sienge = p_empresa and situacao = 'rodando') then
    raise exception 'Cruzamento fora de hora';
  end if;
  if p_erro is not null then
    update erp.sienge_cruzamentos set situacao = 'erro', fim = p_agora, erro = left(p_erro, 1000), resumo = p_resumo
     where dia = v_dia and empresa_sienge = p_empresa;
    return 0;
  end if;
  if jsonb_typeof(p_estranhas) <> 'array' then raise exception 'Lista de estranhas inválida'; end if;
  select array_agg((e->>'sienge_id')::int) into v_ids from jsonb_array_elements(p_estranhas) e;
  -- a que é nossa não entra como estranha, diga o programa o que disser
  if exists (select 1 from erp.sienge_prv_nossas(p_empresa) n
              where n.sienge_id = any (coalesce(v_ids, '{}'))) then
    raise exception 'Linha do ERP marcada como estranha';
  end if;
  with ins as (
    insert into erp.sienge_prv_estranhas (sienge_id, empresa_sienge, numero, emissao, valor, observacoes, motivo, primeira_vez, ultima_vez)
    select (e->>'sienge_id')::int, p_empresa, left(e->>'numero', 50), (e->>'emissao')::date, (e->>'valor')::numeric,
           left(e->>'observacoes', 500), left(coalesce(e->>'motivo', 'não é do ERP'), 200), p_agora, p_agora
      from jsonb_array_elements(p_estranhas) e
    on conflict (sienge_id) do update set ultima_vez = excluded.ultima_vez, sumiu_em = null, motivo = excluded.motivo
    returning (xmax = 0) as nova)
  select count(*) filter (where nova) into v_novas from ins;
  update erp.sienge_prv_estranhas set sumiu_em = p_agora
   where empresa_sienge = p_empresa and sumiu_em is null and sienge_id <> all (coalesce(v_ids, '{}'));
  update erp.sienge_cruzamentos set situacao = 'ok', fim = p_agora,
         resumo = coalesce(p_resumo, '{}'::jsonb) || jsonb_build_object('estranhas', coalesce(array_length(v_ids, 1), 0), 'novas', v_novas)
   where dia = v_dia and empresa_sienge = p_empresa;
  if v_novas > 0 then
    perform erp.registrar_evento('prv_estranhas', 'sienge_prv_estranhas', p_empresa::text, null, null,
      jsonb_build_object('empresa_sienge', p_empresa, 'novas', v_novas,
                         'motivo', v_novas || ' linha(s) PRV no Sienge (empresa ' || p_empresa || ') que não são do ERP'));
  end if;
  return v_novas;
end $$;

-- A lista que a AF olha: as estranhas que ainda estão no Sienge.
create view erp.v_sienge_prv_estranhas with (security_invoker = true) as
  select sienge_id, empresa_sienge, numero, emissao, valor, observacoes, motivo, primeira_vez, ultima_vez
    from erp.sienge_prv_estranhas where sumiu_em is null;

-- ---------------------------------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['v_sienge_prv_estranhas'] loop
    execute format('revoke all on erp.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
    execute format('revoke all on erp.%I from authenticated', t);
  end loop;
  foreach t in array array['sienge_prv_trocas','sienge_prv_estranhas','sienge_cruzamentos'] loop
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
            where n.nspname = 'erp' and p.proname in ('tg_sienge_prv_troca','tg_sienge_cruzamento','tg_sienge_previsao',
              'sienge_pegar_cruzamento','sienge_prv_nossas','sienge_recriar_prv','sienge_terminar_cruzamento') loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
  end loop;
end $$;
-- quem vê a previsão vê a troca; as estranhas e as passadas, só quem está na AF ou é master
create policy perfil_le on erp.sienge_prv_trocas for select to authenticated using (erp.vejo_previsao(previsao_id));
create policy perfil_le on erp.sienge_prv_estranhas for select to authenticated using (erp.sou_master() or erp.estou_nas_listas(array['AF']));
create policy perfil_le on erp.sienge_cruzamentos for select to authenticated using (erp.sou_master() or erp.estou_nas_listas(array['AF']));
grant select on erp.sienge_prv_trocas, erp.sienge_prv_estranhas, erp.sienge_cruzamentos, erp.v_sienge_prv_estranhas to authenticated;

grant execute on function erp.tg_sienge_prv_troca(), erp.tg_sienge_cruzamento(), erp.tg_sienge_previsao(),
                          erp.sienge_pegar_cruzamento(timestamptz), erp.sienge_prv_nossas(int), erp.sienge_recriar_prv(uuid, int, text),
                          erp.sienge_terminar_cruzamento(int, jsonb, jsonb, text, timestamptz)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
