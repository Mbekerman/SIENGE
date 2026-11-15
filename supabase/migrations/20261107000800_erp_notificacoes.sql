-- Notificações: quem recebe cada evento e por qual canal (Moises, 15/11/2026: "a parte de
-- notificações deve ser uma seção inteira pois temos que ter um painel de habilitação de quais
-- notificações vão pra quem"; desenho em https://claude.ai/artifact/N8ReEtAuqbDJpSbXwGAujn).
--
-- Decisões do Moises (15/11/2026, 11h05 e 11h07):
--   1. O administrador configura o painel e o master aprova; o master também configura direto e
--      pode delegar a aprovação. Aqui: o painel (erp.regras_notificacao) e a lista de críticos
--      (erp.tipos_evento.critico) entram no pedido de mudança da configuração
--      (erp.pedir_mudanca_config); sem ninguém na lista de aprovadores da tabela, decide o master,
--      e delegar é o master pôr gente em erp.aprovadores_config dessas tabelas.
--   2. Aviso crítico: ninguém desliga no sino nem no e-mail, só no WhatsApp; vai sempre ao master,
--      além de quem o painel mandar.
--   3. Cada pessoa desliga para si o e-mail e o WhatsApp dos avisos que não são críticos; o sino
--      fica sempre.
--   4. Críticos também: entrar, sair ou mudar alguém nas listas AF, AO e AD
--      (lista_financeiro_alterada) e mudar aprovadores e regras de aprovação
--      (aprovadores_alterados); e, do desenho, administrador criado ou retirado e o próprio painel.
--
-- Caminho: o evento (erp.eventos, gravado por erp.registrar_evento na transação da mudança) →
-- o gatilho de distribuição monta uma notificação por pessoa (o sino, erp.notificacoes) e uma
-- linha por canal de fora na fila (erp.envios_notificacao). Quem envia e-mail e WhatsApp é o
-- servidor, atrás de uma camada nossa, e marca o envio por erp.registrar_envio_notificacao.
-- Duas travas acima do painel: ninguém recebe o que não pode ver (núcleo e centro do evento; o
-- master vê tudo) e quem agiu não é avisado do que fez.
--
-- Papel novo, sem login e sem membros: erp_notificacoes, dono da distribuição e das funções do
-- sino; só ele grava nas notificações e na fila.
-- Portabilidade: SQL puro.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'erp_notificacoes') then
    create role erp_notificacoes nologin;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Tipos de evento novos e a lista de críticos editável pelo pedido
-- ---------------------------------------------------------------------------------------------
insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('lista_financeiro_alterada', 'Pessoa incluída, retirada ou mudada nas listas AF, AO ou AD', 'acesso', true),
  ('aprovadores_alterados', 'Aprovadores ou regras de aprovação alterados', 'acesso', true),
  ('administrador_alterado', 'Administrador criado ou retirado', 'acesso', true),
  ('notificacoes_alteradas', 'Painel de notificações ou lista de avisos críticos alterado', 'configuracao', true);

-- os tipos: o sistema inclui e apaga (carga); o master e o pedido aprovado mudam nome e crítico
create or replace function erp.tg_tipos_evento() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.sou_master() or erp.agindo_como('erp_config') then
    if tg_op = 'DELETE' and exists (select 1 from erp.eventos where tipo = old.codigo) then
      raise exception 'Tipo de evento já usado não se apaga';
    end if;
    if tg_op = 'UPDATE' and (new.codigo <> old.codigo or new.modulo <> old.modulo) then
      raise exception 'O código e o módulo do tipo de evento não mudam';
    end if;
    if tg_op in ('INSERT','DELETE') and not erp.sistema() then
      raise exception 'Os tipos de evento entram e saem pela carga; mude só o nome e a marca de crítico';
    end if;
    return coalesce(new, old);
  end if;
  raise exception 'Só o master muda os tipos de evento';
end $$;

-- ---------------------------------------------------------------------------------------------
-- O painel: quem recebe cada tipo de evento
-- ---------------------------------------------------------------------------------------------
-- destino:
--   pessoa             a pessoa em user_id
--   papel              todos com o papel (diretor, gestor, analista, leitura)
--   lista              quem está na lista AF, AO ou AD
--   gestor_centro      os gestores (aprovadores nominais) do centro do evento
--   diretores_centro   os diretores do centro do evento
--   quem_pediu         quem pediu a mudança (dados.pedida_por do evento)
--   aprovadores_config quem aprova o pedido: a lista da tabela do evento na configuração de
--                      dinheiro, ou o master quando o pedido vai a ele
--   administradores    os administradores (TI)
--   master             o master
-- nucleo_id e centro_id: a regra vale só para eventos daquele núcleo ou centro (nulo: todos).
create table erp.regras_notificacao (
  id        uuid primary key default gen_random_uuid(),
  tipo      text not null references erp.tipos_evento,
  destino   text not null check (destino in ('pessoa','papel','lista','gestor_centro','diretores_centro',
                                             'quem_pediu','aprovadores_config','administradores','master')),
  user_id   uuid references erp.usuarios,
  papel     text check (papel in ('diretor','gestor','analista','leitura')),
  lista     text check (lista in ('AF','AO','AD')),
  nucleo_id uuid references erp.nucleos_economicos,
  centro_id uuid references erp.centros_custo,
  email     boolean not null default true,
  whatsapp  boolean not null default false,
  ativa     boolean not null default true,
  check ((destino = 'pessoa') = (user_id is not null)),
  check ((destino = 'papel') = (papel is not null)),
  check ((destino = 'lista') = (lista is not null))
);
create index on erp.regras_notificacao (tipo) where ativa;

create function erp.tg_regras_notificacao() returns trigger language plpgsql as $$
begin
  if tg_op <> 'DELETE' and new.user_id is not null then perform erp.recusar_so_sucessao(new.user_id); end if;
  if erp.sistema() or erp.sou_master() or erp.agindo_como('erp_config') then return coalesce(new, old); end if;
  raise exception 'O painel de notificações muda pelo pedido (erp.pedir_mudanca_config), que o master aprova';
end $$;
create trigger t_regras_notificacao before insert or update or delete on erp.regras_notificacao
  for each row execute function erp.tg_regras_notificacao();
create trigger t_aud_regras_notificacao after insert or update or delete on erp.regras_notificacao
  for each row execute function erp.tg_auditoria('id');

-- padrões do desenho; o master recebe todo crítico sem precisar de regra
insert into erp.regras_notificacao (tipo, destino, lista) values
  ('conta_bancaria_alterada', 'lista', 'AF'),
  ('codigo_externo_alterado', 'lista', 'AF');
insert into erp.regras_notificacao (tipo, destino) values
  ('mudanca_config_pedida', 'aprovadores_config'),
  ('mudanca_config_encerrada', 'quem_pediu');

-- ---------------------------------------------------------------------------------------------
-- Preferência de cada pessoa: a linha desliga o canal para aquele tipo
-- ---------------------------------------------------------------------------------------------
create table erp.preferencias_notificacao (
  user_id uuid not null references erp.usuarios,
  tipo    text not null references erp.tipos_evento,
  canal   text not null check (canal in ('email','whatsapp')),
  em      timestamptz not null default clock_timestamp(),
  primary key (user_id, tipo, canal)
);
create function erp.tg_preferencia_notificacao() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and new.canal = 'email' and (select critico from erp.tipos_evento where codigo = new.tipo) then
    raise exception 'Aviso crítico não se desliga no e-mail; só no WhatsApp';
  end if;
  if tg_op = 'UPDATE' then raise exception 'Preferência não se altera: ligue ou desligue o canal'; end if;
  return coalesce(new, old);
end $$;
create trigger t_preferencia before insert or update on erp.preferencias_notificacao
  for each row execute function erp.tg_preferencia_notificacao();

-- ---------------------------------------------------------------------------------------------
-- O sino e a fila de envio
-- ---------------------------------------------------------------------------------------------
create table erp.notificacoes (
  id        bigint generated always as identity primary key,
  evento_id bigint not null references erp.eventos,
  user_id   uuid not null references erp.usuarios,
  tipo      text not null references erp.tipos_evento,
  critico   boolean not null,
  titulo    text not null,
  detalhe   text,                  -- o motivo, sem os dados do evento (conta, valores)
  criada_em timestamptz not null default clock_timestamp(),
  lida_em   timestamptz,
  unique (evento_id, user_id)
);
create index on erp.notificacoes (user_id, criada_em desc);
create table erp.envios_notificacao (
  notificacao_id bigint not null references erp.notificacoes,
  canal          text not null check (canal in ('email','whatsapp')),
  criado_em      timestamptz not null default clock_timestamp(),
  enviado_em     timestamptz,
  tentativas     int not null default 0,
  erro           text,
  primary key (notificacao_id, canal)
);
create index on erp.envios_notificacao (criado_em) where enviado_em is null;

-- só a distribuição grava; o sino só marca a leitura; nada se apaga
create function erp.tg_notificacao_guarda() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'Notificação não se apaga'; end if;
  if not (erp.agindo_como('erp_notificacoes') or erp.sistema()) then
    raise exception 'Notificação só pela distribuição dos eventos';
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'notificacoes'
     and (to_jsonb(new) - 'lida_em') <> (to_jsonb(old) - 'lida_em') then
    raise exception 'Da notificação só muda a leitura';
  end if;
  return new;
end $$;
create trigger t_notificacao_guarda before insert or update or delete on erp.notificacoes
  for each row execute function erp.tg_notificacao_guarda();
create trigger t_notificacao_guarda before insert or update or delete on erp.envios_notificacao
  for each row execute function erp.tg_notificacao_guarda();

-- ---------------------------------------------------------------------------------------------
-- Distribuição
-- ---------------------------------------------------------------------------------------------
-- Vê o evento: o master sempre; evento sem núcleo e sem centro (configuração), todos; com centro
-- ou núcleo, quem vê algum par núcleo × centro dele.
create function erp._ve_evento(p_user uuid, p_nucleo uuid, p_centro uuid) returns boolean
language sql stable as $$
  select exists (select 1 from erp.master where user_id = p_user)
      or (p_nucleo is null and p_centro is null)
      or exists (select 1 from erp.nucleo_centros nc
                  where (p_nucleo is null or nc.nucleo_economico_id = p_nucleo)
                    and (p_centro is null or nc.centro_custo_id = p_centro)
                    and erp.ve_linha(p_user, nc.nucleo_economico_id, nc.centro_custo_id, null, null)) $$;

create function erp.tg_distribuir_evento() returns trigger language plpgsql as $$
declare t erp.tipos_evento; v_detalhe text; v_pediu uuid; r record; v_id bigint;
begin
  select * into t from erp.tipos_evento where codigo = new.tipo;
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
       and erp._ve_evento(d.user_id, new.nucleo_id, new.centro_id)
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
-- o gatilho t_distribuir em erp.eventos entra no fim, depois dos privilégios

-- O sino: marca como lidas as notificações da própria pessoa (todas, se nenhuma for dada).
create function erp.marcar_notificacoes_lidas(p_ids bigint[] default null) returns int language plpgsql as $$
declare n int;
begin
  if erp.eu() is null then raise exception 'Marcar como lida precisa de um usuário'; end if;
  update erp.notificacoes set lida_em = clock_timestamp()
   where user_id = erp.eu() and lida_em is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

-- O servidor marca o envio (ok) ou a tentativa que falhou (erro).
create function erp.registrar_envio_notificacao(p_notificacao bigint, p_canal text, p_erro text default null)
returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o servidor registra o envio da notificação'; end if;
  update erp.envios_notificacao
     set tentativas = tentativas + 1,
         enviado_em = case when p_erro is null then clock_timestamp() end,
         erro = p_erro
   where notificacao_id = p_notificacao and canal = p_canal and enviado_em is null;
  if not found then raise exception 'Envio não encontrado ou já feito'; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Eventos das mudanças de controle: listas, aprovadores, administrador e o próprio painel
-- ---------------------------------------------------------------------------------------------
create function erp.tg_evento_controle() returns trigger language plpgsql as $$
declare v_tipo text; v_old jsonb; v_new jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  if tg_table_name = 'usuarios' then
    if coalesce((v_old->>'administrador')::boolean, false) = coalesce((v_new->>'administrador')::boolean, false) then
      return null;
    end if;
    v_tipo := 'administrador_alterado';
  else
    v_tipo := case
      when tg_table_name = 'listas_financeiro' then 'lista_financeiro_alterada'
      when tg_table_name in ('regras_notificacao','tipos_evento') then 'notificacoes_alteradas'
      else 'aprovadores_alterados' end;
  end if;
  perform erp.registrar_evento(v_tipo, tg_table_name, coalesce(v_new, v_old)->>(tg_argv[0]), null, null,
    jsonb_build_object('acao', lower(tg_op), 'antes', v_old, 'depois', v_new)
      || coalesce(erp._contexto_mudanca_config(tg_table_name), '{}'));
  return null;
end $$;
do $$
declare r record;
begin
  for r in select * from (values
    ('listas_financeiro', 'user_id'), ('centro_aprovadores', 'user_id'), ('centro_diretores', 'user_id'),
    ('aprovadores_acesso', 'user_id'), ('delegados_acesso', 'user_id'), ('grupo_sucessao', 'user_id'),
    ('regras_nivel_acesso', 'nivel'), ('regras_mudanca_acesso', 'tabela'), ('regra_acesso', 'id'),
    ('usuarios', 'id'), ('regras_notificacao', 'id'), ('tipos_evento', 'codigo')) v(t, k) loop
    execute format('create trigger t_evento_controle after insert or update or delete on erp.%I
                      for each row execute function erp.tg_evento_controle(%L)', r.t, r.k);
  end loop;
end $$;

-- O painel e a lista de críticos entram no pedido de mudança da configuração
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
  end $$;
insert into erp.regras_mudanca_config (tabela, rotulo) values
  ('regras_notificacao', 'Painel de notificações'), ('tipos_evento', 'Lista de avisos críticos');

-- ---------------------------------------------------------------------------------------------
-- Segurança: RLS, donos, políticas e privilégios
-- ---------------------------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['regras_notificacao','preferencias_notificacao','notificacoes','envios_notificacao'] loop
    execute format('alter table erp.%I enable row level security', t);
    execute format('alter table erp.%I force row level security', t);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
    execute format('grant select, insert, update, delete on erp.%I to erp_sistema', t);
    execute format('grant select on erp.%I to erp_conferencia', t);
  end loop;
end $$;

-- erp_config: o pedido aprovado grava no painel e na lista de críticos
grant select, insert, update, delete on erp.regras_notificacao, erp.tipos_evento to erp_config;
create policy config on erp.regras_notificacao to erp_config
  using (erp.agindo_como('erp_config')) with check (erp.agindo_como('erp_config'));
create policy config on erp.tipos_evento to erp_config
  using (erp.agindo_como('erp_config')) with check (erp.agindo_como('erp_config'));

-- erp_notificacoes: lê quem recebe e grava o sino e a fila
grant usage on schema erp to erp_notificacoes;
do $$
declare t text;
begin
  foreach t in array array['usuarios','master','tipos_evento','regras_notificacao','preferencias_notificacao',
                           'listas_financeiro','centro_aprovadores','centro_diretores','aprovadores_config','nucleo_centros'] loop
    execute format('grant select on erp.%I to erp_notificacoes', t);
    execute format('create policy notificacoes on erp.%I for select to erp_notificacoes using (erp.agindo_como(''erp_notificacoes''))', t);
  end loop;
  foreach t in array array['notificacoes','envios_notificacao'] loop
    execute format('grant select, insert, update on erp.%I to erp_notificacoes', t);
    execute format('create policy notificacoes on erp.%I to erp_notificacoes using (erp.agindo_como(''erp_notificacoes'')) with check (erp.agindo_como(''erp_notificacoes''))', t);
  end loop;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
    ('erp.tg_distribuir_evento()', 'erp_notificacoes'),
    ('erp.marcar_notificacoes_lidas(bigint[])', 'erp_notificacoes'),
    ('erp.tg_evento_controle()', 'erp_eventos')) v(f, dono) loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', r.f);
    execute format('alter function %s owner to %I', r.f, r.dono);
  end loop;
end $$;

-- Políticas para `authenticated`
-- o painel: o administrador e o master leem; só o master grava direto (o administrador pede)
create policy perfil_le on erp.regras_notificacao for select to authenticated using (erp.sou_admin());
create policy perfil_inclui on erp.regras_notificacao for insert to authenticated with check (erp.sou_master());
create policy perfil_altera on erp.regras_notificacao for update to authenticated using (erp.sou_master()) with check (erp.sou_master());
create policy perfil_apaga on erp.regras_notificacao for delete to authenticated using (erp.sou_master());
grant select, insert, update, delete on erp.regras_notificacao to authenticated;
-- a preferência: cada um a sua
create policy perfil_le on erp.preferencias_notificacao for select to authenticated using (erp.membro() and user_id = erp.eu());
create policy perfil_inclui on erp.preferencias_notificacao for insert to authenticated with check (erp.membro() and user_id = erp.eu());
create policy perfil_apaga on erp.preferencias_notificacao for delete to authenticated using (erp.membro() and user_id = erp.eu());
grant select, insert, delete on erp.preferencias_notificacao to authenticated;
-- o sino: cada um lê as suas; a leitura se marca pela função
create policy perfil_le on erp.notificacoes for select to authenticated using (user_id = erp.eu());
grant select on erp.notificacoes to authenticated;
-- erp.envios_notificacao: sem acesso pela API (só o servidor)

-- EXECUTE: as funções novas para os papéis erp_*; para a API, só o sino
revoke execute on all functions in schema erp from public;
grant execute on all functions in schema erp to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.tg_evento_controle() to erp_eventos;
grant execute on function erp.eu(), erp.login_atual(), erp.agindo_como(text), erp.sistema(), erp._ve_evento(uuid, uuid, uuid),
  erp.ve_linha(uuid, uuid, uuid, uuid, uuid, uuid)
  to erp_notificacoes;
grant execute on function erp.marcar_notificacoes_lidas(bigint[]) to authenticated;

-- A distribuição liga por último, com os privilégios já dados.
create trigger t_distribuir after insert on erp.eventos
  for each row execute function erp.tg_distribuir_evento();
