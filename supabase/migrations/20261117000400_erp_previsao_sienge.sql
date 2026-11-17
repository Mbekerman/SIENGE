-- Previsão aprovada no Sienge como título PRV (Moises, 14/11/2026: previsões na transição; 17/11/2026:
-- "e o lançamento das previsões?").
--
-- 1. A previsão a pagar aberta e aprovada entra na fila erp.sienge_previsoes e vira, no Sienge, um título
--    do documento PRV, de uma parcela, sem forma de pagamento, com o marcador "ERP <id>" nas observações.
--    Credor: o da previsão; sem credor, o credor genérico "PREVISÃO BKM" (criado à mão no Sienge; código em
--    erp.sienge_parametros, chave credor_previsao; nos testes, o 823).
-- 2. Quando a previsão sai de aberta (consumida pela nota, encerrada como saldo ou saving, cancelada), a
--    linha PRV tem de sair do Sienge. O usuário da API não apaga: a linha entra na lista
--    erp.v_sienge_prv_apagar (que vai para a planilha só leitura do financeiro) e o programa confere, a
--    cada passagem, se o título sumiu do Sienge (GET 404) e marca apagado.
-- 3. A previsão que sai de aberta antes de ir ao Sienge é descartada da fila.
--
-- Fica para o passo seguinte: a planilha Google, o aviso por e-mail e o cruzamento que recria linha
-- faltante e marca linha estranha. Uma previsão que deixa de estar aprovada mas continua aberta (contrato
-- em nova versão) mantém a linha PRV até sair de aberta.
-- Portabilidade: SQL puro.

-- ---------------------------------------------------------------------------------------------
-- Parâmetros do Sienge: o credor genérico da previsão
-- ---------------------------------------------------------------------------------------------
create table erp.sienge_parametros (
  chave text primary key check (chave in ('credor_previsao')),
  valor text not null check (valor ~ '^[0-9]{1,9}$')
);
create trigger t_sienge_depara before insert or update or delete on erp.sienge_parametros
  for each row execute function erp.tg_sienge_depara();
create trigger t_aud_sienge_parametros after insert or update or delete on erp.sienge_parametros
  for each row execute function erp.tg_auditoria('chave');

create or replace function erp._chave_config(p_tabela text) returns text[] language sql immutable as $$
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
    when 'regras_notificacao' then '{id}'
    when 'tipos_evento' then '{codigo}'
    when 'sienge_centros' then '{nucleo_economico_id,centro_custo_id}'
    when 'sienge_contas' then '{natureza_id,centro_custo_id}'
    when 'sienge_parametros' then '{chave}'
  end $$;
insert into erp.regras_mudanca_config (tabela, rotulo) values ('sienge_parametros', 'Parâmetros do Sienge (credor da previsão)');

create or replace function erp.tg_evento_config() returns trigger language plpgsql as $$
declare v_tipo text; v_old jsonb; v_new jsonb;
begin
  if tg_table_name = 'codigos_externos' and erp.sistema() then return null; end if;   -- o adaptador do Sienge
  v_tipo := case
    when tg_table_name = 'contas_bancarias' then 'conta_bancaria_alterada'
    when tg_table_name in ('codigos_externos','sienge_centros','sienge_contas','sienge_parametros') then 'codigo_externo_alterado'
    when tg_table_name = 'naturezas_sistema' then 'natureza_sistema_alterada'
    when tg_table_name in ('aprovadores_config','regras_mudanca_config') then 'regra_config_alterada'
    else 'alcada_alterada' end;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  perform erp.registrar_evento(v_tipo, tg_table_name,
    (select string_agg(coalesce(v_new, v_old)->>k, '|') from unnest(erp._chave_config(tg_table_name)) k),
    null, case when tg_table_name in ('alcadas_pagamento','sienge_centros','sienge_contas')
               then (coalesce(v_new, v_old)->>'centro_custo_id')::uuid end,
    jsonb_build_object('acao', lower(tg_op), 'antes', v_old, 'depois', v_new)
      || coalesce(erp._contexto_mudanca_config(tg_table_name), '{}'));
  return null;
end $$;
alter function erp.tg_evento_config() security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.tg_evento_config() owner to erp_eventos;
create trigger t_evento after insert or update or delete on erp.sienge_parametros
  for each row execute function erp.tg_evento_config();

-- ---------------------------------------------------------------------------------------------
-- A fila das previsões
-- ---------------------------------------------------------------------------------------------
create table erp.sienge_previsoes (
  previsao_id   uuid primary key references erp.previsoes,
  situacao      text not null default 'pendente' check (situacao in ('pendente','enviado','erro','manual','descartado')),
  sienge_id     int unique,
  passo         text,
  tentativas    int not null default 0,
  proxima_em    timestamptz not null default now(),
  erro          text,
  apagar_desde  timestamptz,            -- a previsão saiu de aberta: a linha PRV tem de sair do Sienge
  apagado_em    timestamptz,            -- o programa viu o título sumir do Sienge (GET 404)
  conferido_em  timestamptz,            -- a última conferência de apagado
  criado_em     timestamptz not null default clock_timestamp(),
  atualizado_em timestamptz not null default clock_timestamp(),
  check (situacao <> 'enviado' or sienge_id is not null),
  check (apagar_desde is null or sienge_id is not null),
  check (apagado_em is null or apagar_desde is not null)
);
create index on erp.sienge_previsoes (proxima_em) where situacao in ('pendente','erro');
create index on erp.sienge_previsoes (conferido_em) where apagar_desde is not null and apagado_em is null;

create function erp.tg_sienge_previsao() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'A fila do Sienge só é escrita pelo sistema'; end if;
  if tg_op = 'DELETE' then raise exception 'A fila do Sienge não se apaga'; end if;
  if tg_op = 'UPDATE' then
    if new.previsao_id <> old.previsao_id or new.criado_em <> old.criado_em then raise exception 'Previsão e data da fila não mudam'; end if;
    if old.sienge_id is not null and new.sienge_id is distinct from old.sienge_id then
      raise exception 'A previsão já tem id no Sienge (%); não troca', old.sienge_id;
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
create trigger t_sienge_previsao before insert or update or delete on erp.sienge_previsoes
  for each row execute function erp.tg_sienge_previsao();
create trigger t_aud_sienge_previsoes after insert or update on erp.sienge_previsoes
  for each row execute function erp.tg_auditoria('previsao_id');

-- Enfileirar: os títulos aprovados (com o alerta da chave PIX nova, como antes) e as previsões abertas
-- e aprovadas; marca a apagar a linha PRV da previsão que saiu de aberta e descarta a que não chegou a ir.
create or replace function erp.sienge_enfileirar() returns int language plpgsql as $$
declare n int := 0; m int; r record;
begin
  if not erp.sistema() then raise exception 'Só o sistema enfileira o envio ao Sienge'; end if;
  for r in
    with novos as (
      insert into erp.sienge_envios (titulo_id)
      select t.id from erp.titulos t
       where t.sentido = 'pagar' and t.tipo in ('fornecedor','avulso') and t.situacao = 'aberto'
         and not exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id)
         and erp.titulo_aprovado(t.id)
      on conflict do nothing
      returning titulo_id)
    select x.titulo_id, t.pessoa_id,
           (select jsonb_agg(jsonb_build_object('numero', g.numero, 'pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave) order by g.numero)
              from erp.parcela_pagamentos g
             where g.titulo_id = x.titulo_id and g.forma = 'pix'
               and not erp._chave_pix_conhecida(t.pessoa_id, g.pix_chave, x.titulo_id)) as chaves,
           (select array[r2.nucleo_economico_id, r2.centro_custo_id] from erp.titulo_rateios r2
             where r2.titulo_id = x.titulo_id order by r2.percentual desc, r2.id limit 1) as onde
      from novos x join erp.titulos t on t.id = x.titulo_id
  loop
    n := n + 1;
    if r.chaves is not null then
      perform erp.registrar_evento('chave_pix_nova', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id, 'parcelas', r.chaves,
                           'motivo', 'Chave PIX nunca usada com este credor: '
                                     || (select string_agg(c->>'pix_chave', ', ') from jsonb_array_elements(r.chaves) c)));
    end if;
  end loop;

  insert into erp.sienge_previsoes (previsao_id)
  select p.id from erp.previsoes p
   where p.sentido = 'pagar' and p.situacao = 'aberta'
     and not exists (select 1 from erp.sienge_previsoes s where s.previsao_id = p.id)
     and erp.previsao_aprovada(p.id)
  on conflict do nothing;
  get diagnostics m = row_count;

  update erp.sienge_previsoes s set apagar_desde = clock_timestamp()
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is not null and s.apagar_desde is null;
  update erp.sienge_previsoes s set situacao = 'descartado', erro = 'A previsão saiu de aberta antes de ir ao Sienge'
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is null and s.situacao <> 'descartado';
  return n + m;
end $$;

-- O pedido da previsão: o corpo do POST /bills do título PRV e a parcela única, sem forma de pagamento.
create function erp._sienge_pedido_previsao(p_previsao uuid) returns jsonb language plpgsql stable as $$
declare p erp.previsoes; v_empresa text; v_credor text; v_centro int; v_conta text; v_saldo numeric;
begin
  if not erp.sistema() then raise exception 'Só o sistema monta o envio ao Sienge'; end if;
  select * into p from erp.previsoes where id = p_previsao;
  if p.id is null then raise exception 'Previsão não existe'; end if;
  if p.sentido <> 'pagar' then raise exception 'Só previsão a pagar vai ao Sienge'; end if;
  if p.situacao <> 'aberta' then raise exception 'A previsão não está aberta'; end if;
  if not erp.previsao_aprovada(p.id) then raise exception 'A previsão não está aprovada'; end if;
  v_saldo := erp._previsao_saldo(p.id);
  if v_saldo <= 0 then raise exception 'A previsão não tem saldo'; end if;

  select codigo into v_empresa from erp.codigos_externos where sistema = 'sienge' and tabela = 'empresas' and registro_id = p.empresa_id;
  if v_empresa is null or v_empresa !~ '^[0-9]+$' then raise exception 'A empresa da previsão não tem código no Sienge'; end if;
  if p.pessoa_id is not null then
    select codigo into v_credor from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and registro_id = p.pessoa_id;
    if v_credor is null or v_credor !~ '^[0-9]+$' then raise exception 'O credor da previsão não tem código no Sienge'; end if;
  else
    select valor into v_credor from erp.sienge_parametros where chave = 'credor_previsao';
    if v_credor is null then raise exception 'Falta o credor genérico da previsão no Sienge (parâmetro credor_previsao)'; end if;
  end if;
  if p.nucleo_economico_id is null or p.centro_custo_id is null then raise exception 'A previsão não tem núcleo e centro'; end if;
  select sienge_centro into v_centro from erp.sienge_centros where nucleo_economico_id = p.nucleo_economico_id and centro_custo_id = p.centro_custo_id;
  select sienge_conta into v_conta from erp.sienge_contas where natureza_id = p.natureza_id and centro_custo_id = p.centro_custo_id;
  if v_centro is null then raise exception 'De-para do Sienge incompleto: núcleo + centro sem centro de custo do Sienge'; end if;
  if v_conta is null then raise exception 'De-para do Sienge incompleto: natureza + centro sem conta do Sienge'; end if;

  return jsonb_build_object(
    'titulo_id', p.id,
    'empresa', v_empresa::int,
    'titulo', jsonb_build_object(
      'debtorId', v_empresa::int,
      'creditorId', v_credor::int,
      'documentIdentificationId', 'PRV',
      'documentNumber', 'PRV-' || upper(left(replace(p.id::text, '-', ''), 12)),
      'issueDate', (p.criada_em at time zone 'America/Sao_Paulo')::date,
      'billDate', (p.criada_em at time zone 'America/Sao_Paulo')::date,
      'baseDate', p.competencia,
      'dueDate', p.data_prevista,
      'indexId', 0,
      'installmentsNumber', 1,
      'totalInvoiceAmount', v_saldo,
      'discount', 0,
      'notes', left('ERP ' || p.id || ' · Previsão' || coalesce(' · ' || nullif(trim(p.descricao), ''), ''), 500),
      'budgetCategories', jsonb_build_array(jsonb_build_object('costCenterId', v_centro, 'paymentCategoriesId', v_conta, 'percentage', 100))),
    'parcelas', jsonb_build_array(jsonb_build_object('numero', 1, 'vencimento', p.data_prevista, 'valor', v_saldo)));
end $$;

-- ---------------------------------------------------------------------------------------------
-- O que o programa chama: um item da fila é um título ou uma previsão (o id diz qual)
-- ---------------------------------------------------------------------------------------------
-- Pega o item vencido mais antigo das duas filas e o reserva por 15 minutos.
create function erp.sienge_pegar() returns table (item_id uuid, sienge_id int, tentativas int) language plpgsql as $$
declare v_tit uuid; v_tit_em timestamptz; v_prev uuid; v_prev_em timestamptz;
begin
  if not erp.sistema() then raise exception 'Só o sistema pega a fila do Sienge'; end if;
  select e.titulo_id, e.proxima_em into v_tit, v_tit_em from erp.sienge_envios e
   where e.situacao in ('pendente','erro') and e.proxima_em <= now() order by e.proxima_em limit 1 for update skip locked;
  select s.previsao_id, s.proxima_em into v_prev, v_prev_em from erp.sienge_previsoes s
   where s.situacao in ('pendente','erro') and s.proxima_em <= now() order by s.proxima_em limit 1 for update skip locked;
  if v_tit is not null and (v_prev is null or v_tit_em <= v_prev_em) then
    return query update erp.sienge_envios e set proxima_em = now() + interval '15 minutes' where e.titulo_id = v_tit
      returning e.titulo_id, e.sienge_id, e.tentativas;
  elsif v_prev is not null then
    return query update erp.sienge_previsoes s set proxima_em = now() + interval '15 minutes' where s.previsao_id = v_prev
      returning s.previsao_id, s.sienge_id, s.tentativas;
  end if;
end $$;

create function erp.sienge_pedido_item(p_id uuid) returns jsonb language plpgsql stable as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema monta o envio ao Sienge'; end if;
  if exists (select 1 from erp.sienge_previsoes where previsao_id = p_id) then return erp._sienge_pedido_previsao(p_id); end if;
  return erp.sienge_pedido(p_id);
end $$;

create function erp.sienge_registrar_item(p_id uuid, p_sienge_id int) returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema registra o envio ao Sienge'; end if;
  if not exists (select 1 from erp.sienge_previsoes where previsao_id = p_id) then
    perform erp.sienge_registrar(p_id, p_sienge_id);
    return;
  end if;
  update erp.sienge_previsoes set sienge_id = p_sienge_id, passo = 'criado' where previsao_id = p_id;
  insert into erp.codigos_externos (sistema, tabela, registro_id, codigo)
  values ('sienge', 'previsoes', p_id, p_sienge_id::text)
  on conflict (sistema, tabela, registro_id) do nothing;
  if (select codigo from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes' and registro_id = p_id)
     <> p_sienge_id::text then
    raise exception 'A previsão já está ligada a outro título do Sienge';
  end if;
end $$;

create function erp.sienge_terminar(p_id uuid, p_situacao text, p_passo text, p_erro text, p_tentativas int, p_proxima timestamptz)
returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema mexe na fila do Sienge'; end if;
  if p_situacao not in ('enviado','erro','manual') then raise exception 'Situação da fila inválida'; end if;
  update erp.sienge_envios set situacao = p_situacao, passo = coalesce(p_passo, passo), erro = p_erro,
                               tentativas = p_tentativas, proxima_em = p_proxima
   where titulo_id = p_id;
  if found then return; end if;
  update erp.sienge_previsoes set situacao = p_situacao, passo = coalesce(p_passo, passo), erro = p_erro,
                                  tentativas = p_tentativas, proxima_em = p_proxima
   where previsao_id = p_id and situacao <> 'descartado';
  if not found then raise exception 'Item fora da fila do Sienge'; end if;
end $$;

-- Os ids do Sienge criados por este programa (a trava de teste só grava neles).
create function erp.sienge_ids() returns setof int language sql stable as $$
  select sienge_id from erp.sienge_envios where sienge_id is not null and erp.sistema()
  union all
  select sienge_id from erp.sienge_previsoes where sienge_id is not null and apagado_em is null and erp.sistema() $$;

-- Conferência do apagado: a linha a apagar mais antiga sem conferência há 30 minutos.
create function erp.sienge_pegar_conferencia() returns table (item_id uuid, sienge_id int) language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema confere o Sienge'; end if;
  return query
    update erp.sienge_previsoes s set conferido_em = clock_timestamp()
     where s.previsao_id = (select s2.previsao_id from erp.sienge_previsoes s2
                             where s2.apagar_desde is not null and s2.apagado_em is null
                               and (s2.conferido_em is null or s2.conferido_em < now() - interval '30 minutes')
                             order by s2.conferido_em nulls first, s2.apagar_desde limit 1 for update skip locked)
    returning s.previsao_id, s.sienge_id;
end $$;

create function erp.sienge_marcar_apagado(p_id uuid) returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema confere o Sienge'; end if;
  update erp.sienge_previsoes set apagado_em = clock_timestamp() where previsao_id = p_id and apagar_desde is not null and apagado_em is null;
  if not found then raise exception 'A previsão não está na lista do que apagar'; end if;
end $$;

-- A lista do que o financeiro apaga à mão no Sienge (vai para a planilha só leitura).
create view erp.v_sienge_prv_apagar with (security_invoker = true) as
  select s.previsao_id, s.sienge_id, e.codigo as empresa_sienge, p.data_prevista, p.valor, p.situacao as situacao_previsao,
         s.apagar_desde, s.conferido_em
    from erp.sienge_previsoes s
    join erp.previsoes p on p.id = s.previsao_id
    left join erp.codigos_externos e on e.sistema = 'sienge' and e.tabela = 'empresas' and e.registro_id = p.empresa_id
   where s.apagar_desde is not null and s.apagado_em is null;

-- ---------------------------------------------------------------------------------------------
-- Segurança
-- ---------------------------------------------------------------------------------------------
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['v_sienge_prv_apagar'] loop
    execute format('revoke all on erp.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
    execute format('revoke all on erp.%I from authenticated', t);
  end loop;
  foreach t in array array['sienge_parametros','sienge_previsoes'] loop
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
            where n.nspname = 'erp' and p.proname in ('tg_sienge_previsao','_sienge_pedido_previsao','sienge_pegar','sienge_pedido_item',
              'sienge_registrar_item','sienge_terminar','sienge_ids','sienge_pegar_conferencia','sienge_marcar_apagado',
              'sienge_enfileirar','_chave_config','tg_evento_config') loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
  end loop;
end $$;
-- o parâmetro: como o de-para (todo membro lê, só o master grava direto, o resto pelo pedido)
grant select, insert, update, delete on erp.sienge_parametros to erp_config;
create policy config on erp.sienge_parametros to erp_config using (erp.agindo_como('erp_config')) with check (erp.agindo_como('erp_config'));
create policy perfil_le on erp.sienge_parametros for select to authenticated using (erp.membro());
create policy perfil_inclui on erp.sienge_parametros for insert to authenticated with check (erp.sou_master());
create policy perfil_altera on erp.sienge_parametros for update to authenticated using (erp.sou_master()) with check (erp.sou_master());
create policy perfil_apaga on erp.sienge_parametros for delete to authenticated using (erp.sou_master());
grant select, insert, update, delete on erp.sienge_parametros to authenticated;
-- a fila: quem vê a previsão lê; ninguém grava pela API
create policy perfil_le on erp.sienge_previsoes for select to authenticated using (erp.vejo_previsao(previsao_id));
grant select on erp.sienge_previsoes to authenticated;
grant select on erp.v_sienge_prv_apagar to authenticated;

grant execute on function erp._chave_config(text) to erp_config, erp_conferencia;
grant execute on function erp.tg_sienge_previsao(), erp._sienge_pedido_previsao(uuid), erp.sienge_pegar(), erp.sienge_pedido_item(uuid),
                          erp.sienge_registrar_item(uuid, int), erp.sienge_terminar(uuid, text, text, text, int, timestamptz),
                          erp.sienge_ids(), erp.sienge_pegar_conferencia(), erp.sienge_marcar_apagado(uuid), erp.sienge_enfileirar()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
