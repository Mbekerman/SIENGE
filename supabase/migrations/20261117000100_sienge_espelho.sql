-- Banco espelho do Sienge: camada bruta (`sienge_bruto`) e espelho (`sienge`).
-- Desenho aprovado pelo Moises em 7/nov/2026 (https://claude.ai/artifact/EgDt6HJJREERJBsYKrvLsE);
-- carga de todo o histórico pedida em 15/nov/2026 ("cada vírgula"), sem a Muchmore (empresa 1).
--
-- Regras desta migration:
-- 1. A camada bruta guarda cada resposta do Sienge como veio (só leitura depois de gravada).
-- 2. O espelho guarda o registro com os códigos ORIGINAIS do Sienge (conta do plano financeiro e
--    centro de custo). Nenhum de-para aqui: ele mora numa camada de cima, que lê o CSV da tarefa
--    do plano de naturezas.
-- 3. Mudou o registro (impressão digital diferente)? A versão anterior vai para sienge.historico.
--    Sumiu de uma leitura completa de uma janela? Ganha removido_em, nunca é apagado.
-- 4. Empresas fora (sienge.empresas_fora; a Muchmore) não entram no espelho.
-- 5. Ninguém da API (anon, authenticated, service_role) vê nada. Só o papel sienge_carga, sem
--    login, usado pelo programa de carga no servidor. RLS ligado e forçado em toda tabela.
-- Portabilidade: SQL puro, sem extensão (impressão digital por md5).

create schema sienge_bruto;
create schema sienge;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'sienge_carga') then
    create role sienge_carga nologin;
  end if;
end $$;

revoke all on schema sienge_bruto, sienge from public;

-- ---------------------------------------------------------------- controle da carga
create table sienge.empresas_fora (
  empresa_id int primary key,
  motivo text not null
);
insert into sienge.empresas_fora values
  (1, 'Muchmore Tecnologia: não entra no ERP (Moises, 15/11/2026)');

create table sienge.cargas (
  id bigint generated always as identity primary key,
  recurso text not null,                       -- ex.: 'bulk:outcome', 'rest:bills'
  parametros jsonb not null default '{}',      -- consulta pedida (sem credencial)
  janela_inicio date,                          -- período que a carga cobre por inteiro
  janela_fim date,
  situacao text not null default 'pendente'
    check (situacao in ('pendente', 'rodando', 'pausada', 'concluida', 'erro')),
  pedido_assincrono text,                      -- identificador da consulta de massa assíncrona
  pedacos int,
  pedacos_lidos int not null default 0,
  proxima_pagina int not null default 0,       -- offset da próxima página (consultas normais)
  tentativas int not null default 0,
  ultimo_erro text,
  retomar_depois timestamptz,                  -- Retry-After do Sienge
  criada_em timestamptz not null default now(),
  iniciada_em timestamptz,
  concluida_em timestamptz,
  check (janela_inicio is null or janela_fim is null or janela_inicio <= janela_fim)
);

-- Última cota lida nos cabeçalhos do Sienge (massa: X-Ratelimit-Limit-Day e Remaining-Day).
-- A cota é da BKM inteira, dividida com o CRM; o programa deixa uma reserva para ele.
create table sienge.cota_api (
  tipo text primary key check (tipo in ('massa', 'rest')),
  limite_dia int,
  restante_dia int,
  lido_em timestamptz not null
);

-- ---------------------------------------------------------------- camada bruta
create table sienge_bruto.respostas (
  id bigint generated always as identity primary key,
  carga_id bigint references sienge.cargas(id),
  recurso text not null,
  consulta text not null,                      -- caminho e parâmetros, nunca a credencial
  pedaco int,                                  -- número do pedaço (massa assíncrona) ou da página
  status_http int not null,
  cabecalhos jsonb not null default '{}',
  corpo jsonb not null,
  sha256 text not null,                        -- do corpo como chegou (calculado pelo programa)
  linhas int,                                  -- registros no corpo, depois do filtro de empresas
  descartadas int not null default 0,          -- registros de empresas fora, tirados antes de gravar
  lido_em timestamptz not null,
  gravado_em timestamptz not null default now(),
  processado_em timestamptz,
  unique (carga_id, consulta, pedaco, sha256),
  check (consulta !~* '(senha|password|authorization|token)=')
);

create function sienge_bruto.tg_so_insere() returns trigger language plpgsql as $$
begin
  -- só a marca de processado pode mudar; o resto da resposta é imutável
  if tg_op = 'UPDATE'
     and (new.id, new.carga_id, new.recurso, new.consulta, new.pedaco, new.status_http, new.cabecalhos,
          new.corpo, new.sha256, new.linhas, new.descartadas, new.lido_em, new.gravado_em)
         is not distinct from
         (old.id, old.carga_id, old.recurso, old.consulta, old.pedaco, old.status_http, old.cabecalhos,
          old.corpo, old.sha256, old.linhas, old.descartadas, old.lido_em, old.gravado_em) then
    return new;
  end if;
  raise exception 'resposta do Sienge não se altera nem se apaga';
end $$;
create trigger t_so_insere before update or delete on sienge_bruto.respostas
  for each row execute function sienge_bruto.tg_so_insere();

-- ---------------------------------------------------------------- espelho: parcelas a pagar
-- Fonte: massa /outcome (bulk-data-parcelas-a-pagar.yaml), uma linha por parcela.
create table sienge.pagar_parcelas (
  titulo_id int not null,                      -- billId
  parcela_id int not null,                     -- installmentId
  empresa_id int not null,                     -- companyId
  credor_id int,
  credor_nome text,
  documento_tipo text,                         -- documentIdentificationId (ex.: NFSE, PRV)
  documento_numero text,
  previsao boolean,                            -- forecastDocument
  origem text,                                 -- originId (CP, ME, SE...)
  emissao date,
  data_titulo date,                            -- billDate
  vencimento date,
  data_base date,                              -- installmentBaseDate
  valor_original numeric(18,2),
  saldo numeric(18,2),
  saldo_corrigido numeric(18,2),
  desconto numeric(18,2),
  imposto numeric(18,2),
  indexador_id int,
  situacao_autorizacao text,                   -- S ou N
  situacao_consistencia text,                  -- S, N, I
  cadastrado_por_id text,                      -- login no Sienge
  cadastrado_por text,
  cadastrado_em timestamp,
  dados jsonb not null,                        -- a parcela inteira, como veio
  impressao text not null,                     -- md5 de dados
  resposta_id bigint not null references sienge_bruto.respostas(id),
  lido_em timestamptz not null,
  removido_em timestamptz,                     -- sumiu de uma leitura completa da janela
  primary key (titulo_id, parcela_id)
);
create index on sienge.pagar_parcelas (empresa_id, emissao);
create index on sienge.pagar_parcelas (credor_id);

-- Rateio por conta do plano financeiro e centro de custo (paymentsCategories): os ORIGINAIS.
create table sienge.pagar_rateios (
  titulo_id int not null,
  parcela_id int not null,
  ordem int not null,
  centro_custo_id int,                         -- costCenterId (no Sienge, a obra/empresa)
  centro_custo_nome text,
  conta text,                                  -- financialCategoryId (conta do plano financeiro)
  conta_nome text,
  percentual numeric(9,4),
  redutora text,
  conta_tipo text,
  primary key (titulo_id, parcela_id, ordem),
  foreign key (titulo_id, parcela_id) references sienge.pagar_parcelas on delete cascade
);
create index on sienge.pagar_rateios (conta);
create index on sienge.pagar_rateios (centro_custo_id);

-- Rateio por obra, unidade e planilha do orçamento (buildingsCosts).
create table sienge.pagar_rateios_obra (
  titulo_id int not null,
  parcela_id int not null,
  ordem int not null,
  obra_id int,
  obra_nome text,
  unidade_id int,
  unidade_nome text,
  planilha_id text,
  planilha_nome text,
  percentual numeric(9,4),
  primary key (titulo_id, parcela_id, ordem),
  foreign key (titulo_id, parcela_id) references sienge.pagar_parcelas on delete cascade
);

-- Rateio por departamento (departamentsCosts; vazio em toda a base em 16/11/2026).
create table sienge.pagar_rateios_departamento (
  titulo_id int not null,
  parcela_id int not null,
  ordem int not null,
  dados jsonb not null,
  primary key (titulo_id, parcela_id, ordem),
  foreign key (titulo_id, parcela_id) references sienge.pagar_parcelas on delete cascade
);

create table sienge.pagar_autorizacoes (
  titulo_id int not null,
  parcela_id int not null,
  ordem int not null,
  autorizado_em timestamp,
  usuario_id text,
  usuario_nome text,
  ultimo boolean,
  primary key (titulo_id, parcela_id, ordem),
  foreign key (titulo_id, parcela_id) references sienge.pagar_parcelas on delete cascade
);

create table sienge.pagar_baixas (
  titulo_id int not null,
  parcela_id int not null,
  sequencia int not null,                      -- ordem da baixa na resposta
  numero_sienge int,                           -- sequencialNumber (repete em 6 parcelas da base)
  pago_em date,
  calculado_em date,
  operacao_id int,
  operacao_nome text,
  valor_bruto numeric(18,2),
  valor_liquido numeric(18,2),
  valor_liquido_corrigido numeric(18,2),
  juros numeric(18,2),
  multa numeric(18,2),
  desconto numeric(18,2),
  correcao numeric(18,2),
  imposto numeric(18,2),
  autenticacao text,
  primary key (titulo_id, parcela_id, sequencia),
  foreign key (titulo_id, parcela_id) references sienge.pagar_parcelas on delete cascade
);

-- Movimento bancário de cada baixa, com o rateio dele (paymentCategories) dentro de dados.
create table sienge.pagar_baixa_movimentos (
  titulo_id int not null,
  parcela_id int not null,
  sequencia int not null,
  movimento_id int not null,
  empresa_conta_id int,
  conta_numero text,
  conta_tipo text,
  valor numeric(18,2),
  movimentado_em date,
  operacao_tipo text,
  conciliado text,
  dados jsonb not null,
  primary key (titulo_id, parcela_id, sequencia, movimento_id),
  foreign key (titulo_id, parcela_id, sequencia) references sienge.pagar_baixas on delete cascade
);

-- Versões anteriores de qualquer registro do espelho (nunca se altera nem se apaga).
create table sienge.historico (
  id bigint generated always as identity primary key,
  tabela text not null,
  chave jsonb not null,
  dados jsonb not null,
  impressao text not null,
  resposta_id bigint references sienge_bruto.respostas(id),
  lido_em timestamptz not null,
  substituido_em timestamptz not null default now()
);
create index on sienge.historico (tabela, chave);

create function sienge.tg_historico_imutavel() returns trigger language plpgsql as $$
begin raise exception 'histórico do espelho não se altera nem se apaga'; end $$;
create trigger t_imutavel before update or delete on sienge.historico
  for each row execute function sienge.tg_historico_imutavel();

create function sienge.tg_recusa_truncate() returns trigger language plpgsql as $$
begin raise exception 'tabela do espelho do Sienge não se apaga por TRUNCATE'; end $$;

-- ---------------------------------------------------------------- funções da carga
create function sienge._data(t text) returns date language sql immutable as
  $$ select case when t ~ '^\d{4}-\d{2}-\d{2}' then left(t, 10)::date end $$;
create function sienge._momento(t text) returns timestamp language sql immutable as
  $$ select case when t ~ '^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}' then replace(left(t, 19), 'T', ' ')::timestamp
                 when t ~ '^\d{4}-\d{2}-\d{2}' then left(t, 10)::timestamp end $$;
create function sienge._sn(t text) returns boolean language sql immutable as
  $$ select case upper(t) when 'S' then true when 'N' then false end $$;

-- Grava uma resposta do Sienge na camada bruta. Registros de empresas fora (campo companyId
-- ou debtorId) saem antes de gravar, e a contagem fica em `descartadas`.
-- A impressão (sha256) é do corpo como chegou, antes do filtro. Mesma resposta de novo = mesmo id.
create function sienge.gravar_resposta(p_carga_id bigint, p_recurso text, p_consulta text, p_pedaco int,
                                       p_status int, p_cabecalhos jsonb, p_corpo text, p_lido_em timestamptz)
returns bigint language plpgsql set search_path = sienge, pg_temp as $$
declare v_corpo jsonb; v_hash text; v_lista jsonb; v_fora int := 0; v_id bigint; v_chave text;
begin
  if p_consulta ~* '(senha|password|authorization|token)=' then
    raise exception 'consulta com credencial não se grava';
  end if;
  v_hash := encode(sha256(convert_to(p_corpo, 'UTF8')), 'hex');
  select id into v_id from sienge_bruto.respostas
   where carga_id is not distinct from p_carga_id and consulta = p_consulta
     and pedaco is not distinct from p_pedaco and sha256 = v_hash;
  if found then return v_id; end if;

  v_corpo := p_corpo::jsonb;
  v_chave := case when jsonb_typeof(v_corpo -> 'data') = 'array' then 'data'
                  when jsonb_typeof(v_corpo -> 'results') = 'array' then 'results' end;
  if v_chave is not null then
    select coalesce(jsonb_agg(x), '[]'::jsonb) into v_lista
      from jsonb_array_elements(v_corpo -> v_chave) x
     where not exists (select 1 from empresas_fora f
                        where f.empresa_id::text in (x ->> 'companyId', x ->> 'debtorId'));
    v_fora := jsonb_array_length(v_corpo -> v_chave) - jsonb_array_length(v_lista);
    v_corpo := jsonb_set(v_corpo, array[v_chave], v_lista);
  end if;

  insert into sienge_bruto.respostas (carga_id, recurso, consulta, pedaco, status_http, cabecalhos, corpo,
                                      sha256, linhas, descartadas, lido_em)
  values (p_carga_id, p_recurso, p_consulta, p_pedaco, p_status, coalesce(p_cabecalhos, '{}'), v_corpo,
          v_hash, case when v_chave is not null then jsonb_array_length(v_corpo -> v_chave) end, v_fora, p_lido_em)
  returning id into v_id;
  return v_id;
end $$;

-- Grava as parcelas a pagar de uma resposta bruta da massa /outcome no espelho.
-- Devolve as contagens. Pode rodar de novo na mesma resposta sem duplicar nada.
create function sienge.carregar_parcelas_pagar(p_resposta_id bigint) returns jsonb
language plpgsql set search_path = sienge, pg_temp as $$
declare
  r sienge_bruto.respostas;
  p jsonb; v_imp text; v_atual sienge.pagar_parcelas;
  n_novas int := 0; n_mudadas int := 0; n_iguais int := 0; n_fora int := 0;
  i int; b jsonb; m jsonb; k int;
begin
  select * into r from sienge_bruto.respostas where id = p_resposta_id;
  if not found then raise exception 'resposta % não existe', p_resposta_id; end if;
  if r.status_http <> 200 then raise exception 'resposta % não é 200 (%)', p_resposta_id, r.status_http; end if;
  if jsonb_typeof(r.corpo -> 'data') is distinct from 'array' then
    raise exception 'resposta % sem a lista data', p_resposta_id;
  end if;

  for p in select x from jsonb_array_elements(r.corpo -> 'data') x loop
    if (p ->> 'billId') is null or (p ->> 'installmentId') is null then
      raise exception 'parcela sem billId ou installmentId na resposta %', p_resposta_id;
    end if;
    if exists (select 1 from empresas_fora where empresa_id = (p ->> 'companyId')::int) then
      n_fora := n_fora + 1; continue;
    end if;
    v_imp := md5(p::text);
    select * into v_atual from pagar_parcelas
      where titulo_id = (p ->> 'billId')::int and parcela_id = (p ->> 'installmentId')::int for update;

    if found and v_atual.impressao = v_imp then
      update pagar_parcelas set lido_em = r.lido_em, removido_em = null, resposta_id = r.id
        where titulo_id = v_atual.titulo_id and parcela_id = v_atual.parcela_id;
      n_iguais := n_iguais + 1; continue;
    end if;

    if found then
      insert into historico (tabela, chave, dados, impressao, resposta_id, lido_em)
        values ('pagar_parcelas', jsonb_build_object('titulo_id', v_atual.titulo_id, 'parcela_id', v_atual.parcela_id),
                v_atual.dados, v_atual.impressao, v_atual.resposta_id, v_atual.lido_em);
      delete from pagar_parcelas where titulo_id = v_atual.titulo_id and parcela_id = v_atual.parcela_id;
      n_mudadas := n_mudadas + 1;
    else
      n_novas := n_novas + 1;
    end if;

    insert into pagar_parcelas values (
      (p ->> 'billId')::int, (p ->> 'installmentId')::int, (p ->> 'companyId')::int,
      (p ->> 'creditorId')::int, p ->> 'creditorName',
      nullif(trim(p ->> 'documentIdentificationId'), ''), p ->> 'documentNumber',
      _sn(p ->> 'forecastDocument'), p ->> 'originId',
      _data(p ->> 'issueDate'), _data(p ->> 'billDate'), _data(p ->> 'dueDate'), _data(p ->> 'installmentBaseDate'),
      (p ->> 'originalAmount')::numeric, (p ->> 'balanceAmount')::numeric, (p ->> 'correctedBalanceAmount')::numeric,
      (p ->> 'discountAmount')::numeric, (p ->> 'taxAmount')::numeric, (p ->> 'indexerId')::int,
      p ->> 'authorizationStatus', p ->> 'consistencyStatus',
      p ->> 'registeredUserId', p ->> 'registeredBy', _momento(p ->> 'registeredDate'),
      p, v_imp, r.id, r.lido_em, null);

    i := 0;
    for b in select x from jsonb_array_elements(coalesce(p -> 'paymentsCategories', '[]')) x loop
      i := i + 1;
      insert into pagar_rateios values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, i,
        (b ->> 'costCenterId')::int, b ->> 'costCenterName', b ->> 'financialCategoryId', b ->> 'financialCategoryName',
        (b ->> 'financialCategoryRate')::numeric, b ->> 'financialCategoryReducer', b ->> 'financialCategoryType');
    end loop;
    i := 0;
    for b in select x from jsonb_array_elements(coalesce(p -> 'buildingsCosts', '[]')) x loop
      i := i + 1;
      insert into pagar_rateios_obra values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, i,
        (b ->> 'buildingId')::int, b ->> 'buildingName', (b ->> 'buildingUnitId')::int, b ->> 'buildingUnitName',
        b ->> 'costEstimationSheetId', b ->> 'costEstimationSheetName', (b ->> 'rate')::numeric);
    end loop;
    i := 0;
    for b in select x from jsonb_array_elements(coalesce(p -> 'departamentsCosts', '[]')) x loop
      i := i + 1;
      insert into pagar_rateios_departamento values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, i, b);
    end loop;
    i := 0;
    for b in select x from jsonb_array_elements(coalesce(p -> 'authorizations', '[]')) x loop
      i := i + 1;
      insert into pagar_autorizacoes values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, i,
        _momento(b ->> 'authorizationDate'), b ->> 'authorizationUserId', b ->> 'authorizationUserName',
        _sn(b ->> 'isLastToAuthorize'));
    end loop;
    i := 0;
    for b in select x from jsonb_array_elements(coalesce(p -> 'payments', '[]')) x loop
      i := i + 1;
      k := i;
      insert into pagar_baixas values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, k,
        (b ->> 'sequencialNumber')::int, _data(b ->> 'paymentDate'), _data(b ->> 'calculationDate'), (b ->> 'operationTypeId')::int, b ->> 'operationTypeName',
        (b ->> 'grossAmount')::numeric, (b ->> 'netAmount')::numeric, (b ->> 'correctedNetAmount')::numeric,
        (b ->> 'interestAmount')::numeric, (b ->> 'fineAmount')::numeric, (b ->> 'discountAmount')::numeric,
        (b ->> 'monetaryCorrectionAmount')::numeric, (b ->> 'taxAmount')::numeric, nullif(b ->> 'paymentAuthentication', ''));
      for m in select x from jsonb_array_elements(coalesce(b -> 'bankMovements', '[]')) x loop
        insert into pagar_baixa_movimentos values ((p ->> 'billId')::int, (p ->> 'installmentId')::int, k,
          (m ->> 'id')::int, (m ->> 'accountCompanyId')::int, m ->> 'accountNumber', m ->> 'accountType',
          (m ->> 'amount')::numeric, _data(m ->> 'bankMovementDate'), m ->> 'operationType', m ->> 'reconcile', m);
      end loop;
    end loop;
  end loop;

  update sienge_bruto.respostas set processado_em = now() where id = p_resposta_id;
  return jsonb_build_object('novas', n_novas, 'mudadas', n_mudadas, 'iguais', n_iguais, 'empresas_fora', n_fora);
end $$;

-- Depois de uma carga que leu a janela INTEIRA (por data de emissão), marca como removidas as
-- parcelas da janela que não vieram em nenhuma resposta dela. Nada é apagado.
create function sienge.marcar_ausentes_pagar(p_carga_id bigint) returns int
language plpgsql set search_path = sienge, pg_temp as $$
declare c sienge.cargas; n int;
begin
  select * into c from cargas where id = p_carga_id;
  if not found then raise exception 'carga % não existe', p_carga_id; end if;
  if c.situacao <> 'concluida' then raise exception 'carga % não está concluída', p_carga_id; end if;
  if c.janela_inicio is null or c.janela_fim is null then raise exception 'carga % sem janela', p_carga_id; end if;
  if coalesce(c.parametros ->> 'selectionType', '') <> 'I' then
    raise exception 'só carga por data de emissão (selectionType I) marca ausentes';
  end if;
  if exists (select 1 from sienge_bruto.respostas where carga_id = p_carga_id and processado_em is null) then
    raise exception 'carga % tem resposta ainda não processada', p_carga_id;
  end if;
  -- sem nenhuma resposta, tudo pareceria ausente: recusa (pedido que voltou vazio por erro do Sienge)
  if not exists (select 1 from sienge_bruto.respostas where carga_id = p_carga_id) then
    raise exception 'carga % sem nenhuma resposta: não marca ausentes', p_carga_id;
  end if;
  update pagar_parcelas pp set removido_em = now()
   where pp.removido_em is null
     and pp.emissao between c.janela_inicio and c.janela_fim
     and not exists (select 1 from sienge_bruto.respostas r
                      where r.carga_id = p_carga_id and r.id = pp.resposta_id);
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- segurança
grant usage on schema sienge_bruto, sienge to sienge_carga;
grant select, insert, update, delete on all tables in schema sienge_bruto, sienge to sienge_carga;
grant execute on all functions in schema sienge_bruto, sienge to sienge_carga;
revoke execute on all functions in schema sienge_bruto, sienge from public;
-- no Supabase, privilégios padrão podem dar acesso aos papéis da API: tira tudo explicitamente
do $$
declare r text;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'authenticator'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on all tables in schema sienge_bruto, sienge from %I', r);
      execute format('revoke all on all sequences in schema sienge_bruto, sienge from %I', r);
      execute format('revoke all on all functions in schema sienge_bruto, sienge from %I', r);
      execute format('revoke all on schema sienge_bruto, sienge from %I', r);
    end if;
  end loop;
end $$;

do $$
declare t record;
begin
  for t in select n.nspname, c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname in ('sienge_bruto', 'sienge') and c.relkind in ('r', 'p') loop
    execute format('alter table %I.%I enable row level security', t.nspname, t.relname);
    execute format('alter table %I.%I force row level security', t.nspname, t.relname);
    execute format('create policy carga on %I.%I to sienge_carga using (true) with check (true)', t.nspname, t.relname);
    execute format('create trigger t_nao_trunca before truncate on %I.%I for each statement execute function sienge.tg_recusa_truncate()', t.nspname, t.relname);
  end loop;
end $$;
