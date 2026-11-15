-- Mudança da configuração de dinheiro por pedido (Moises, 15/11/2026: "AF e AD podem pedir e quem
-- aprova eu ou o admin selecionamos na configuração. Quero poder selecionar pra não ter aprovação
-- livre ou para mudança de até um determinado percentual (por período, por exemplo a cada 3 meses).
-- Qualquer mudança de alçada eu quero ser notificado."; pontos 1 a 3 aprovados no mesmo dia).
--
-- Tabelas (as 9 do S-090): naturezas_sistema, niveis_aprovacao, alcadas_pagamento,
-- alcadas_reclassificacao, regra_adiantamento, regra_alcada_pagamento, regras_ajuste,
-- contas_bancarias e codigos_externos. Pela API, só o master grava nelas direto (S-090).
--
-- 1. Quem pede: o AF, o AD, o administrador e o master (erp.pedir_mudanca_config). O pedido do
--    master vale na hora.
-- 2. Quem aprova: por tabela, a lista de aprovadores (erp.aprovadores_config) e o mínimo de votos
--    (erp.regras_mudanca_config). Só o master define a lista e o mínimo (ponto 1); o administrador e
--    o financeiro podem pedir a mudança deles, e só o master aprova. O master aprova qualquer pedido,
--    e o voto dele basta. Quem pediu não aprova. Sem aprovadores suficientes na lista, decide o master.
--    Administrador não entra na lista (ele não aprova nada no ERP).
-- 3. Modo de cada tabela: "aprovacao" (padrão, sempre com aprovação) ou "livre_ate": o pedido do AF
--    ou do AD que só muda o valor (o "até") de uma faixa de alçada vale na hora se o valor novo fica
--    a até X% de todo valor que a faixa teve nos últimos N meses (o de N meses atrás, os do meio e
--    o atual): várias mudanças pequenas seguidas não passam de X% na janela, e um aperto recente
--    não se desfaz sem aprovação (S-094). Incluir ou
--    tirar faixa e mudar as etapas (tirar o AD, por exemplo) sempre pedem aprovação (ponto 2). Só as
--    duas tabelas de faixas aceitam o modo livre; conta bancária e código do Sienge sempre pedem
--    aprovação (ponto 3). O pedido do administrador sempre pede aprovação.
-- 4. Aviso: toda mudança nessas tabelas, por pedido ou direta do master ou do sistema, vira um
--    evento (erp.eventos). Mudança de alçada, de conta bancária, de código externo e de quem aprova
--    são eventos críticos. O painel de notificações (quem recebe o quê) é de outra migration.
--    Código externo gravado pelo sistema (o adaptador do Sienge) não vira evento.
--
-- Papéis novos, sem login e sem membros:
--   - erp_config: dono do pedido, da decisão e da aplicação; só ele (e o sistema e o master, pela
--     política de S-090) grava nas 9 tabelas e nas do pedido;
--   - erp_eventos: dono do erp.registrar_evento e do gatilho dos eventos; só ele insere em
--     erp.eventos, que só cresce.
-- Portabilidade: SQL puro.

do $$
declare p text;
begin
  foreach p in array array['erp_config', 'erp_eventos'] loop
    if not exists (select 1 from pg_roles where rolname = p) then
      execute format('create role %I nologin', p);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Eventos (formato combinado com o painel de notificações, 15/11/2026)
-- ---------------------------------------------------------------------------------------------
create table erp.tipos_evento (
  codigo  text primary key,
  rotulo  text not null,
  modulo  text not null,
  critico boolean not null default false
);
insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('alcada_alterada', 'Alçada ou regra de aprovação alterada', 'configuracao', true),
  ('conta_bancaria_alterada', 'Conta bancária alterada', 'configuracao', true),
  ('codigo_externo_alterado', 'Código de outro sistema (Sienge) alterado', 'configuracao', true),
  ('natureza_sistema_alterada', 'Natureza do sistema alterada', 'configuracao', false),
  ('regra_config_alterada', 'Quem aprova a configuração de dinheiro alterado', 'configuracao', true),
  ('mudanca_config_pedida', 'Pedido de mudança da configuração de dinheiro', 'configuracao', false),
  ('mudanca_config_encerrada', 'Pedido de mudança da configuração recusado, cancelado ou superado', 'configuracao', false);

create table erp.eventos (
  id        bigint generated always as identity primary key,
  tipo      text not null references erp.tipos_evento,
  em        timestamptz not null default clock_timestamp(),
  por       uuid references erp.usuarios,       -- quem agiu (nulo: o sistema)
  tabela    text,
  registro  text,
  nucleo_id uuid references erp.nucleos_economicos,
  centro_id uuid references erp.centros_custo,
  dados     jsonb not null default '{}'
);
create index on erp.eventos (tipo, em);

-- os tipos: só o master (ou o sistema) muda
create function erp.tg_tipos_evento() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.sou_master() then
    if tg_op = 'DELETE' and exists (select 1 from erp.eventos where tipo = old.codigo) then
      raise exception 'Tipo de evento já usado não se apaga';
    end if;
    if tg_op = 'UPDATE' and new.codigo <> old.codigo then raise exception 'O código do tipo de evento não muda'; end if;
    return coalesce(new, old);
  end if;
  raise exception 'Só o master muda os tipos de evento';
end $$;
create trigger t_tipos_evento before insert or update or delete on erp.tipos_evento
  for each row execute function erp.tg_tipos_evento();
create trigger t_aud_tipos_evento after insert or update or delete on erp.tipos_evento
  for each row execute function erp.tg_auditoria('codigo');

-- os eventos só crescem, e só pelo erp.registrar_evento; quem e quando, o banco põe
create function erp.tg_evento_guarda() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'O evento não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_eventos') then raise exception 'Evento só pelo erp.registrar_evento'; end if;
  new.por := erp.eu();
  new.em := clock_timestamp();
  return new;
end $$;
create trigger t_evento_guarda before insert or update or delete on erp.eventos
  for each row execute function erp.tg_evento_guarda();

create function erp.registrar_evento(p_tipo text, p_tabela text, p_registro text, p_nucleo uuid, p_centro uuid, p_dados jsonb)
returns void language plpgsql as $$
begin
  -- sem RETURNING: quem grava não lê os eventos
  insert into erp.eventos (tipo, tabela, registro, nucleo_id, centro_id, dados)
  values (p_tipo, p_tabela, p_registro, p_nucleo, p_centro, coalesce(p_dados, '{}'));
end $$;

-- ---------------------------------------------------------------------------------------------
-- Quem aprova e como, por tabela
-- ---------------------------------------------------------------------------------------------
create table erp.regras_mudanca_config (
  tabela     text primary key,
  rotulo     text not null,
  modo       text not null default 'aprovacao' check (modo in ('aprovacao','livre_ate')),
  percentual numeric(5,2) check (percentual > 0 and percentual <= 100),   -- livre até X% ...
  meses      int check (meses between 1 and 36),                          -- ... do valor de N meses atrás
  minimo     int not null default 1 check (minimo >= 1),                  -- votos da lista
  check ((modo = 'livre_ate') = (percentual is not null and meses is not null)),
  -- só as faixas de alçada têm um valor para medir (ponto 2); conta e código, sempre aprovação (ponto 3)
  check (modo = 'aprovacao' or tabela in ('alcadas_pagamento','alcadas_reclassificacao'))
);
insert into erp.regras_mudanca_config (tabela, rotulo) values
  ('naturezas_sistema', 'Naturezas do sistema'), ('niveis_aprovacao', 'Níveis de aprovação'),
  ('alcadas_pagamento', 'Alçada de pagamento'), ('alcadas_reclassificacao', 'Alçada de reclassificação'),
  ('regra_adiantamento', 'Regra do adiantamento'), ('regra_alcada_pagamento', 'Regra da alçada de pagamento'),
  ('regras_ajuste', 'Regras de ajuste da revisão'), ('contas_bancarias', 'Contas bancárias'),
  ('codigos_externos', 'Códigos de outros sistemas (Sienge)');

create table erp.aprovadores_config (
  tabela  text not null references erp.regras_mudanca_config,
  user_id uuid not null references erp.usuarios,
  primary key (tabela, user_id)
);

-- a regra e a lista: só o master (ou o sistema), ou o pedido que o master aprovou
create function erp.tg_regras_config() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'aprovadores_config' and tg_op <> 'DELETE' then
    perform erp.recusar_so_sucessao(new.user_id);
    perform erp.recusar_admin_aprovador(new.user_id);
  end if;
  if tg_table_name = 'regras_mudanca_config' and not erp.sistema() then
    if tg_op in ('INSERT', 'DELETE') then
      raise exception 'As tabelas da configuração são fixas; mude só o modo, o percentual, os meses e o mínimo';
    elsif new.tabela <> old.tabela or new.rotulo <> old.rotulo then
      raise exception 'As tabelas da configuração são fixas; mude só o modo, o percentual, os meses e o mínimo';
    end if;
  end if;
  if erp.sistema() or erp.sou_master() or erp.agindo_como('erp_config') then return coalesce(new, old); end if;
  raise exception 'Só o master decide quem aprova a configuração de dinheiro';
end $$;
create trigger t_regras_config before insert or update or delete on erp.regras_mudanca_config
  for each row execute function erp.tg_regras_config();
create trigger t_regras_config before insert or update or delete on erp.aprovadores_config
  for each row execute function erp.tg_regras_config();
create trigger t_aud_regras_mudanca_config after insert or update or delete on erp.regras_mudanca_config
  for each row execute function erp.tg_auditoria('tabela');
create trigger t_aud_aprovadores_config after insert or update or delete on erp.aprovadores_config
  for each row execute function erp.tg_auditoria('tabela');

-- ---------------------------------------------------------------------------------------------
-- Pedidos e votos
-- ---------------------------------------------------------------------------------------------
create table erp.mudancas_config (
  id            uuid primary key default gen_random_uuid(),
  tabela        text not null,
  operacao      text not null check (operacao in ('incluir','alterar','excluir')),
  dados         jsonb not null,          -- a linha inteira como fica (incluir, alterar) ou a chave (excluir)
  antes         jsonb,                   -- a linha no momento do pedido (alterar, excluir)
  motivo        text not null check (length(trim(motivo)) > 0),
  pedida_por    uuid not null references erp.usuarios,
  pedida_em     timestamptz not null default clock_timestamp(),
  -- nenhuma: o master pediu; livre: dentro do percentual; lista: a lista da tabela; master: só o master
  aprovacao     text not null check (aprovacao in ('nenhuma','livre','lista','master')),
  minimo        int not null,            -- votos exigidos, fixados no pedido (0: aplicada na hora)
  referencia    jsonb,                   -- no modo livre: o valor de N meses atrás e o percentual
  -- foi ao master por falta de aprovadores qualificados na lista (o aviso diz o motivo; Moises, 15/11/2026)
  falta_aprovadores boolean not null default false,
  situacao      text not null default 'pendente' check (situacao in ('pendente','aplicada','recusada','cancelada','obsoleta')),
  encerrada_em  timestamptz,
  aplicada_txid bigint                   -- a transação que aplicou (o evento da mudança acha o pedido)
);
create table erp.mudanca_config_votos (
  mudanca_id    uuid not null references erp.mudancas_config,
  user_id       uuid not null references erp.usuarios,
  aprova        boolean not null,
  justificativa text,
  em            timestamptz not null default clock_timestamp(),
  primary key (mudanca_id, user_id),
  check (aprova or length(trim(coalesce(justificativa, ''))) > 0)
);
create function erp.tg_mudanca_config() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.agindo_como('erp_config') then
    if tg_op = 'DELETE' then raise exception 'O histórico de mudanças da configuração não se apaga'; end if;
    return new;
  end if;
  raise exception 'Mudança da configuração só pelo pedido (erp.pedir_mudanca_config) e pela decisão (erp.decidir_mudanca_config)';
end $$;
create trigger t_mudanca_config before insert or update or delete on erp.mudancas_config
  for each row execute function erp.tg_mudanca_config();
create trigger t_mudanca_config before insert or update or delete on erp.mudanca_config_votos
  for each row execute function erp.tg_mudanca_config();
create trigger t_aud_mudancas_config after insert or update on erp.mudancas_config
  for each row execute function erp.tg_auditoria('id');

-- A chave de cada tabela do pedido.
create function erp._chave_config(p_tabela text) returns text[] language sql immutable as $$
  select case p_tabela
    when 'naturezas_sistema' then '{chave}'::text[]
    when 'niveis_aprovacao' then '{codigo}'
    when 'alcadas_pagamento' then '{id}'
    when 'alcadas_reclassificacao' then '{id}'
    when 'regra_adiantamento' then '{id}'
    when 'regra_alcada_pagamento' then '{id}'
    when 'regras_ajuste' then '{campo,quem}'
    when 'contas_bancarias' then '{id}'
    when 'codigos_externos' then '{sistema,tabela,codigo}'
    when 'aprovadores_config' then '{tabela,user_id}'
    when 'regras_mudanca_config' then '{tabela}'
  end $$;

-- a condição "t.chave = r.chave" de uma tabela (o nome da tabela já foi conferido na lista)
create function erp._onde_chave_config(p_tabela text) returns text language sql immutable as
  $$ select string_agg(format('t.%1$I = r.%1$I', k), ' and ') from unnest(erp._chave_config(p_tabela)) k $$;

-- A linha atual pela chave em d (nula se não existe).
create function erp._linha_config(p_tabela text, d jsonb) returns jsonb language plpgsql stable as $$
declare v jsonb;
begin
  execute format('select to_jsonb(t) from erp.%I t, jsonb_populate_record(null::erp.%I, $1) r where %s',
                 p_tabela, p_tabela, erp._onde_chave_config(p_tabela))
     into v using d;
  return v;
end $$;

-- Grava a mudança na tabela. Os gatilhos de cada tabela continuam valendo.
create function erp._executar_config(p_tabela text, p_operacao text, d jsonb) returns void language plpgsql as $$
declare v_cols text;
begin
  if p_operacao = 'incluir' then
    -- só as colunas informadas: as outras ficam com o padrão da tabela
    select string_agg(format('%I', k), ', ') into v_cols from jsonb_object_keys(d) k;
    execute format('insert into erp.%I (%s) select %s from jsonb_populate_record(null::erp.%I, $1)',
                   p_tabela, v_cols, v_cols, p_tabela) using d;
  elsif p_operacao = 'alterar' then
    select string_agg(format('%1$I = r.%1$I', k), ', ') into v_cols
      from jsonb_object_keys(d) k where k <> all (erp._chave_config(p_tabela));
    if v_cols is null then return; end if;
    execute format('update erp.%I t set %s from jsonb_populate_record(null::erp.%I, $1) r where %s',
                   p_tabela, v_cols, p_tabela, erp._onde_chave_config(p_tabela)) using d;
  else
    execute format('delete from erp.%I t using jsonb_populate_record(null::erp.%I, $1) r where %s',
                   p_tabela, p_tabela, erp._onde_chave_config(p_tabela)) using d;
  end if;
end $$;

-- O valor de uma coluna de uma faixa num instante passado, pela auditoria. Nulo se a faixa não
-- existia então. Sem nenhuma mudança registrada, a faixa está como nasceu (na carga).
create function erp._valor_config_em(p_tabela text, p_id uuid, p_coluna text, p_em timestamptz) returns numeric
language plpgsql stable as $$
declare a erp.auditoria; v numeric;
begin
  -- a última mudança até o instante: o estado dela
  select * into a from erp.auditoria where tabela = p_tabela and registro = p_id::text and em <= p_em
   order by em desc, id desc limit 1;
  if a.id is not null then return (a.depois->>p_coluna)::numeric; end if;
  -- nenhuma até lá: o estado de antes da primeira depois do instante
  select * into a from erp.auditoria where tabela = p_tabela and registro = p_id::text
   order by em, id limit 1;
  if a.id is not null then return (a.antes->>p_coluna)::numeric; end if;
  -- nenhuma mudança registrada
  execute format('select (to_jsonb(t)->>%L)::numeric from erp.%I t where id = $1', p_coluna, p_tabela) into v using p_id;
  return v;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Pedir, aplicar, decidir, cancelar
-- ---------------------------------------------------------------------------------------------
-- p_dados: a linha (incluir), os campos que mudam com a chave (alterar) ou a chave (excluir).
create function erp.pedir_mudanca_config(p_tabela text, p_operacao text, p_dados jsonb, p_motivo text)
returns uuid language plpgsql as $$
declare v_eu uuid := erp.eu(); v_master boolean := erp.sou_master();
        v_admin boolean := coalesce((erp.meu_usuario()).administrador, false);
        v_fin boolean := erp.estou_nas_listas('{AF,AD}');
        v_dados jsonb := coalesce(p_dados, '{}'); v_antes jsonb; v_regra erp.regras_mudanca_config;
        v_tipo text; v_min int := 0; v_ref numeric; v_novo numeric; v_referencia jsonb; v_aprov int; v_id uuid;
        v_cols text[]; v_falta boolean := false; v_janela numeric[];
begin
  if v_eu is null then raise exception 'O pedido precisa de um usuário'; end if;
  if not (v_master or v_admin or v_fin) then
    raise exception 'Só o AF, o AD, o administrador ou o master pedem mudança na configuração de dinheiro';
  end if;
  if erp._chave_config(p_tabela) is null then raise exception 'A tabela % não é da configuração de dinheiro', p_tabela; end if;
  if p_operacao not in ('incluir','alterar','excluir') then raise exception 'Operação inválida: %', p_operacao; end if;
  if length(trim(coalesce(p_motivo, ''))) = 0 then raise exception 'O pedido precisa de motivo'; end if;
  select array_agg(attname::text) into v_cols from pg_attribute
   where attrelid = format('erp.%I', p_tabela)::regclass and attnum > 0 and not attisdropped;
  if exists (select 1 from jsonb_object_keys(v_dados) k where k <> all (v_cols)) then
    raise exception 'Campo que não existe em %', p_tabela;
  end if;
  -- as regras de uma linha só e a chave gerada no pedido
  if p_tabela in ('regra_adiantamento','regra_alcada_pagamento') then v_dados := v_dados || '{"id": true}'; end if;
  if p_operacao = 'incluir' and 'id' = any (erp._chave_config(p_tabela)) and not (v_dados ? 'id') then
    v_dados := v_dados || jsonb_build_object('id', gen_random_uuid());
  end if;
  if exists (select 1 from unnest(erp._chave_config(p_tabela)) k where not (v_dados ? k) or v_dados->>k is null) then
    raise exception 'O pedido precisa da chave de % (%)', p_tabela, array_to_string(erp._chave_config(p_tabela), ', ');
  end if;
  v_antes := erp._linha_config(p_tabela, v_dados);
  if p_operacao = 'incluir' and v_antes is not null then raise exception 'Já existe: altere em vez de incluir'; end if;
  if p_operacao <> 'incluir' and v_antes is null then raise exception 'Não existe o registro a %', p_operacao; end if;
  if p_operacao = 'alterar' then
    v_dados := v_antes || v_dados;
    if v_dados = v_antes then raise exception 'O pedido não muda nada'; end if;
  elsif p_operacao = 'excluir' then
    v_dados := (select jsonb_object_agg(k, v_antes->k) from unnest(erp._chave_config(p_tabela)) k);
  end if;

  -- confere a mudança nas travas da tabela antes de pedir (desfeita em seguida)
  begin
    perform erp._executar_config(p_tabela, p_operacao, v_dados);
    raise exception using errcode = 'P0001', message = '__config_conferida__';
  exception when others then
    if sqlerrm <> '__config_conferida__' then raise; end if;
  end;

  -- quem aprova
  if v_master then
    v_tipo := 'nenhuma';
  elsif p_tabela in ('aprovadores_config','regras_mudanca_config') then
    v_tipo := 'master';                       -- quem aprova a configuração, só o master define (ponto 1)
  else
    select * into v_regra from erp.regras_mudanca_config where tabela = p_tabela;
    -- modo livre: o AF ou o AD, só o valor de uma faixa que já existe, a até X% do de N meses atrás
    if v_regra.modo = 'livre_ate' and v_fin and p_operacao = 'alterar'
       and (v_dados - 'ate') = (v_antes - 'ate') and v_antes->>'ate' is not null and v_dados->>'ate' is not null then
      -- o valor novo fica a até X% de todo valor que a faixa teve na janela: o de N meses atrás,
      -- os que vieram depois e o atual (S-094: o AF não desfaz sozinho um aperto aprovado)
      v_ref := erp._valor_config_em(p_tabela, (v_dados->>'id')::uuid, 'ate',
                                    clock_timestamp() - make_interval(months => v_regra.meses));
      v_novo := (v_dados->>'ate')::numeric;
      select array_agg(x) into v_janela from (
        select v_ref as x
        union all select (a.depois->>'ate')::numeric from erp.auditoria a
         where a.tabela = p_tabela and a.registro = v_dados->>'id'
           and a.em > clock_timestamp() - make_interval(months => v_regra.meses)
        union all select (v_antes->>'ate')::numeric) j;
      if v_ref is not null and not exists (select 1 from unnest(v_janela) x
                                            where x is null or abs(v_novo - x) > x * v_regra.percentual / 100) then
        v_tipo := 'livre';
      end if;
      v_referencia := jsonb_build_object('valor_antes', v_ref, 'meses', v_regra.meses, 'percentual', v_regra.percentual,
                                         'janela', to_jsonb(v_janela));
    end if;
    if v_tipo is null then
      select count(*) into v_aprov from erp.aprovadores_config a join erp.usuarios u on u.id = a.user_id and u.ativo
       where a.tabela = p_tabela and a.user_id <> v_eu;
      if v_aprov >= v_regra.minimo then v_tipo := 'lista'; v_min := v_regra.minimo;
      else v_tipo := 'master'; v_falta := true; end if;     -- sem aprovadores bastantes, decide o master
    end if;
  end if;
  if v_tipo = 'master' then v_min := 1; end if;

  insert into erp.mudancas_config (tabela, operacao, dados, antes, motivo, pedida_por, aprovacao, minimo, referencia, falta_aprovadores)
  values (p_tabela, p_operacao, v_dados, v_antes, p_motivo, v_eu, v_tipo, v_min, v_referencia, v_falta)
  returning id into v_id;
  if v_tipo in ('nenhuma','livre') then
    perform erp._aplicar_mudanca_config(v_id);
  else
    perform erp.registrar_evento('mudanca_config_pedida', p_tabela, v_id::text, null, null,
      jsonb_build_object('mudanca_id', v_id, 'operacao', p_operacao, 'antes', v_antes, 'depois', v_dados,
                         'motivo', p_motivo, 'aprovacao', v_tipo, 'minimo', v_min)
      || case when v_falta then jsonb_build_object('falta_aprovadores', true, 'aprovadores_disponiveis', v_aprov,
                                                  'minimo_da_lista', v_regra.minimo) else '{}' end);
  end if;
  return v_id;
end $$;

-- Aplica o pedido aprovado. Se a linha mudou desde o pedido, o pedido fica obsoleto.
create function erp._aplicar_mudanca_config(p_id uuid) returns void language plpgsql as $$
declare m erp.mudancas_config; v_atual jsonb;
begin
  select * into m from erp.mudancas_config where id = p_id for update;
  v_atual := erp._linha_config(m.tabela, m.dados);
  if (m.operacao = 'incluir' and v_atual is not null) or (m.operacao <> 'incluir' and v_atual is distinct from m.antes) then
    update erp.mudancas_config set situacao = 'obsoleta', encerrada_em = clock_timestamp() where id = p_id;
    perform erp.registrar_evento('mudanca_config_encerrada', m.tabela, p_id::text, null, null,
      jsonb_build_object('mudanca_id', p_id, 'situacao', 'obsoleta'));
    return;
  end if;
  -- antes de gravar: o evento da mudança acha o pedido pela transação
  update erp.mudancas_config set situacao = 'aplicada', encerrada_em = clock_timestamp(), aplicada_txid = txid_current()
   where id = p_id;
  perform erp._executar_config(m.tabela, m.operacao, m.dados);
end $$;

create function erp.decidir_mudanca_config(p_id uuid, p_aprova boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare v_eu uuid := erp.eu(); m erp.mudancas_config; v_sim int; v_master boolean := erp.sou_master();
begin
  select * into m from erp.mudancas_config where id = p_id for update;
  if m.id is null then raise exception 'Pedido de mudança da configuração não encontrado'; end if;
  if m.situacao <> 'pendente' then raise exception 'O pedido já está %', m.situacao; end if;
  if v_eu = m.pedida_por and not v_master then raise exception 'Quem pediu a mudança não a aprova'; end if;
  if not v_master then
    if m.aprovacao = 'master' then raise exception 'Só o master decide este pedido'; end if;
    if not exists (select 1 from erp.aprovadores_config a join erp.usuarios u on u.id = a.user_id and u.ativo
                    where a.tabela = m.tabela and a.user_id = v_eu) then
      raise exception 'Só um aprovador desta configuração decide o pedido';
    end if;
  end if;
  if not p_aprova and length(trim(coalesce(p_justificativa, ''))) = 0 then
    raise exception 'Recusar o pedido precisa de justificativa';
  end if;
  insert into erp.mudanca_config_votos (mudanca_id, user_id, aprova, justificativa) values (p_id, v_eu, p_aprova, p_justificativa);
  if not p_aprova then
    update erp.mudancas_config set situacao = 'recusada', encerrada_em = clock_timestamp() where id = p_id;
    perform erp.registrar_evento('mudanca_config_encerrada', m.tabela, p_id::text, null, null,
      jsonb_build_object('mudanca_id', p_id, 'situacao', 'recusada', 'justificativa', p_justificativa));
    return 'recusada';
  end if;
  -- o voto do master basta; na lista, conta só quem ainda é aprovador ativo
  select count(*) into v_sim from erp.mudanca_config_votos v
    join erp.aprovadores_config a on a.user_id = v.user_id and a.tabela = m.tabela
    join erp.usuarios u on u.id = v.user_id and u.ativo
   where v.mudanca_id = p_id and v.aprova and v.user_id <> m.pedida_por;
  if v_master or v_sim >= m.minimo then
    perform erp._aplicar_mudanca_config(p_id);
    return (select situacao from erp.mudancas_config where id = p_id);
  end if;
  return 'pendente';
end $$;

create function erp.cancelar_mudanca_config(p_id uuid) returns void language plpgsql as $$
declare m erp.mudancas_config;
begin
  select * into m from erp.mudancas_config where id = p_id and situacao = 'pendente' and pedida_por = erp.eu() for update;
  if m.id is null then raise exception 'Só quem pediu cancela o pedido pendente'; end if;
  update erp.mudancas_config set situacao = 'cancelada', encerrada_em = clock_timestamp() where id = p_id;
  perform erp.registrar_evento('mudanca_config_encerrada', m.tabela, p_id::text, null, null,
    jsonb_build_object('mudanca_id', p_id, 'situacao', 'cancelada'));
end $$;

-- ---------------------------------------------------------------------------------------------
-- Evento de toda mudança nas tabelas da configuração
-- ---------------------------------------------------------------------------------------------
-- O pedido aplicado nesta transação para a tabela, com quem pediu e quem aprovou (nulo: mudança
-- direta do master ou do sistema).
create function erp._contexto_mudanca_config(p_tabela text) returns jsonb language sql stable as $$
  select jsonb_build_object('mudanca_id', m.id, 'pedida_por', m.pedida_por, 'motivo', m.motivo,
                            'aprovacao', m.aprovacao, 'referencia', m.referencia,
                            'aprovada_por', coalesce((select jsonb_agg(v.user_id order by v.em) from erp.mudanca_config_votos v
                                                       where v.mudanca_id = m.id and v.aprova), '[]'))
    from erp.mudancas_config m
   where m.tabela = p_tabela and m.aplicada_txid = txid_current()
   order by m.encerrada_em desc limit 1 $$;

create function erp.tg_evento_config() returns trigger language plpgsql as $$
declare v_tipo text; v_old jsonb; v_new jsonb;
begin
  if tg_table_name = 'codigos_externos' and erp.sistema() then return null; end if;   -- o adaptador do Sienge
  v_tipo := case
    when tg_table_name = 'contas_bancarias' then 'conta_bancaria_alterada'
    when tg_table_name = 'codigos_externos' then 'codigo_externo_alterado'
    when tg_table_name = 'naturezas_sistema' then 'natureza_sistema_alterada'
    when tg_table_name in ('aprovadores_config','regras_mudanca_config') then 'regra_config_alterada'
    else 'alcada_alterada' end;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  perform erp.registrar_evento(v_tipo, tg_table_name,
    (select string_agg(coalesce(v_new, v_old)->>k, '|') from unnest(erp._chave_config(tg_table_name)) k),
    null, null,
    jsonb_build_object('acao', lower(tg_op), 'antes', v_old, 'depois', v_new)
      || coalesce(erp._contexto_mudanca_config(tg_table_name), '{}'));
  return null;
end $$;
do $$
declare t text;
begin
  foreach t in array array['naturezas_sistema','niveis_aprovacao','alcadas_pagamento','alcadas_reclassificacao',
                           'regra_adiantamento','regra_alcada_pagamento','regras_ajuste','contas_bancarias',
                           'codigos_externos','aprovadores_config','regras_mudanca_config'] loop
    execute format('create trigger t_evento after insert or update or delete on erp.%I
                      for each row execute function erp.tg_evento_config()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: RLS, donos, políticas e privilégios
-- ---------------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['tipos_evento','eventos','regras_mudanca_config','aprovadores_config','mudancas_config','mudanca_config_votos'] loop
    execute format('alter table erp.%I enable row level security', t);
    execute format('alter table erp.%I force row level security', t);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
    execute format('grant select, insert, update, delete on erp.%I to erp_sistema', t);
    execute format('grant select on erp.%I to erp_conferencia', t);
  end loop;
end $$;

-- erp_config: grava nas 9 tabelas e nas do pedido; lê o cadastro e a auditoria (o valor de antes)
grant usage on schema erp to erp_config, erp_eventos;
do $$
declare t text;
begin
  foreach t in array array['naturezas_sistema','niveis_aprovacao','alcadas_pagamento','alcadas_reclassificacao',
                           'regra_adiantamento','regra_alcada_pagamento','regras_ajuste','contas_bancarias',
                           'codigos_externos','aprovadores_config','regras_mudanca_config','mudancas_config',
                           'mudanca_config_votos'] loop
    execute format('grant select, insert, update, delete on erp.%I to erp_config', t);
    execute format('create policy config on erp.%I to erp_config using (erp.agindo_como(''erp_config'')) with check (erp.agindo_como(''erp_config''))', t);
  end loop;
  foreach t in array array['usuarios','auditoria'] loop
    execute format('grant select on erp.%I to erp_config', t);
    execute format('create policy config on erp.%I for select to erp_config using (erp.agindo_como(''erp_config''))', t);
  end loop;
end $$;
-- erp_eventos: só insere nos eventos
grant insert on erp.eventos to erp_eventos;
create policy eventos_grava on erp.eventos for insert to erp_eventos with check (erp.agindo_como('erp_eventos'));

do $$
declare r record;
begin
  for r in select * from (values
    ('erp.pedir_mudanca_config(text, text, jsonb, text)', 'erp_config'),
    ('erp.decidir_mudanca_config(uuid, boolean, text)', 'erp_config'),
    ('erp.cancelar_mudanca_config(uuid)', 'erp_config'),
    ('erp._aplicar_mudanca_config(uuid)', 'erp_config'),
    ('erp._contexto_mudanca_config(text)', 'erp_conferencia'),
    ('erp.registrar_evento(text, text, text, uuid, uuid, jsonb)', 'erp_eventos'),
    ('erp.tg_evento_config()', 'erp_eventos')) v(f, dono) loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', r.f);
    execute format('alter function %s owner to %I', r.f, r.dono);
  end loop;
end $$;

-- Políticas para `authenticated`
create policy perfil_le on erp.tipos_evento for select to authenticated using (erp.membro());
create policy perfil_le on erp.regras_mudanca_config for select to authenticated using (erp.membro());
create policy perfil_le on erp.aprovadores_config for select to authenticated using (erp.membro());
-- os pedidos: quem pede, quem aprova e quem administra
create policy perfil_le on erp.mudancas_config for select to authenticated using (
  erp.membro() and (erp.sou_admin() or erp.financeiro() or pedida_por = erp.eu()
                    or exists (select 1 from erp.aprovadores_config a where a.user_id = erp.eu())));
create policy perfil_le on erp.mudanca_config_votos for select to authenticated using (
  exists (select 1 from erp.mudancas_config m where m.id = mudanca_id));
do $$
declare t text;
begin
  foreach t in array array['tipos_evento','regras_mudanca_config','aprovadores_config'] loop
    execute format('create policy perfil_inclui on erp.%I for insert to authenticated with check (erp.sou_master())', t);
    execute format('create policy perfil_altera on erp.%I for update to authenticated using (erp.sou_master()) with check (erp.sou_master())', t);
    execute format('create policy perfil_apaga on erp.%I for delete to authenticated using (erp.sou_master())', t);
    execute format('grant select, insert, update, delete on erp.%I to authenticated', t);
  end loop;
end $$;
grant select on erp.mudancas_config, erp.mudanca_config_votos to authenticated;
-- erp.eventos: sem leitura pela API (o painel de notificações decide quem vê o quê)

-- EXECUTE: nada novo para public; as funções nossas para os papéis erp_*; para a API, só os pedidos
revoke execute on all functions in schema erp from public;
grant execute on all functions in schema erp to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.eu(), erp.agindo_como(text), erp.login_atual(), erp.sistema(),
  erp._chave_config(text), erp._contexto_mudanca_config(text), erp.registrar_evento(text, text, text, uuid, uuid, jsonb)
  to erp_eventos;
grant execute on function
  erp.pedir_mudanca_config(text, text, jsonb, text), erp.decidir_mudanca_config(uuid, boolean, text),
  erp.cancelar_mudanca_config(uuid)
to authenticated;
