-- Perfis de acesso (decisões do Moises, 14/11/2026).
--
-- Acesso = o que a pessoa vê e lança, por núcleo econômico × centro de custo, com naturezas:
--   - Nível por centro: Leitor (vê tudo do centro), Lançador restrito (lança e vê só o que
--     lançou), Lançador (lança e vê tudo). Comentar é ação de quem vê, não nível.
--   - Perfil-modelo: nível por centro + naturezas restritas liberadas, sem núcleo. A pessoa fica
--     ligada ao modelo: mudar o modelo muda todos que o usam.
--   - Atribuição: pessoa + modelo + escopo de núcleos + validade. Uma pessoa tem várias. Escopos:
--     lista (os marcados agora, e opcionalmente os núcleos criados depois nos tipos escolhidos);
--     todos, inclusive os futuros, exceto alguns; todos dos tipos escolhidos (os de hoje e os
--     futuros), exceto alguns. Os tipos de núcleo são a tabela erp.tipos_nucleo, editável.
--   - Quando atribuições se sobrepõem no mesmo núcleo × centro, vale o maior: ver tudo e lançar
--     se somam (Leitor + Lançador restrito = Lançador), e as liberações de natureza também.
--   - A exceção da pessoa vence o modelo: nível próprio num núcleo × centro (inclusive nenhum),
--     e liberar ou bloquear uma natureza.
--   - Natureza liberada dentro do centro; a restrita (naturezas.restrita, no galho) só com
--     liberação.
-- Papéis de aprovação ficam fora dos modelos, nominais: gestor da área (centro_aprovadores),
-- diretor da área (centro_diretores), AF, AO e AD (listas_financeiro, do grupo).
-- Tudo isto só o administrador muda, com auditoria; ninguém concede acesso a si mesmo.
-- As políticas de RLS que usam este acesso entram com o primeiro grant a `authenticated`.

create table erp.perfis_modelo (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null unique check (length(trim(nome)) > 0),
  descricao text,
  ativo     boolean not null default true
);
create table erp.perfil_centros (
  perfil_id       uuid not null references erp.perfis_modelo,
  centro_custo_id uuid not null references erp.centros_custo,
  nivel           text not null check (nivel in ('leitor','lancador_restrito','lancador')),
  primary key (perfil_id, centro_custo_id)
);
-- naturezas restritas que o modelo libera (o galho inteiro), nos centros do modelo
create table erp.perfil_naturezas (
  perfil_id   uuid not null references erp.perfis_modelo,
  natureza_id uuid not null references erp.naturezas,
  primary key (perfil_id, natureza_id)
);

create table erp.atribuicoes (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references erp.usuarios,
  perfil_id   uuid not null references erp.perfis_modelo,
  -- lista: os núcleos incluídos + os criados depois da atribuição nos tipos escolhidos (se houver);
  -- todos: todos, inclusive os futuros; tipos: todos dos tipos escolhidos, inclusive os futuros.
  -- Em todos os escopos, os núcleos excluídos ficam de fora.
  escopo      text not null check (escopo in ('lista','todos','tipos')),
  inicio      date not null default current_date,
  fim         date,                                        -- vazio: sem fim
  criado_em   timestamptz not null default now(),          -- "futuro" = núcleo criado depois disto
  check (fim is null or fim >= inicio)
);
create table erp.atribuicao_tipos (             -- escopo tipos: os tipos; escopo lista: os futuros desses tipos
  atribuicao_id uuid not null references erp.atribuicoes,
  tipo_nucleo   text not null references erp.tipos_nucleo,
  primary key (atribuicao_id, tipo_nucleo)
);
create table erp.atribuicao_nucleos (           -- incluir: só no escopo lista; excluir: em qualquer um
  atribuicao_id       uuid not null references erp.atribuicoes,
  nucleo_economico_id uuid not null references erp.nucleos_economicos,
  incluir             boolean not null,
  primary key (atribuicao_id, nucleo_economico_id)
);
create function erp.tg_atribuicao_escopo() returns trigger language plpgsql as $$
declare v_escopo text;
begin
  if tg_table_name = 'atribuicoes' then
    if tg_op = 'INSERT' and not erp.sistema() then new.criado_em := now(); end if;   -- a foto é sempre de agora
    if tg_op = 'UPDATE' and (new.criado_em <> old.criado_em or new.user_id <> old.user_id) then
      raise exception 'A atribuição não muda de pessoa nem de data de criação';
    end if;
    if tg_op = 'UPDATE' and new.escopo <> old.escopo
       and (exists (select 1 from erp.atribuicao_tipos where atribuicao_id = new.id and new.escopo = 'todos')
            or exists (select 1 from erp.atribuicao_nucleos where atribuicao_id = new.id and incluir and new.escopo <> 'lista')) then
      raise exception 'Tire os tipos e núcleos incluídos que não valem no escopo novo antes de trocar';
    end if;
    return new;
  end if;
  select escopo into v_escopo from erp.atribuicoes where id = new.atribuicao_id;
  if tg_table_name = 'atribuicao_tipos' then
    if v_escopo = 'todos' then raise exception 'O escopo todos não escolhe tipos'; end if;
  elsif (to_jsonb(new)->>'incluir')::boolean and v_escopo <> 'lista' then
    raise exception 'Só o escopo lista inclui núcleos; nos outros, o núcleo marcado fica de fora';
  end if;
  return new;
end $$;
create trigger t_atribuicao_escopo before insert or update on erp.atribuicoes
  for each row execute function erp.tg_atribuicao_escopo();
create trigger t_atribuicao_escopo before insert or update on erp.atribuicao_tipos
  for each row execute function erp.tg_atribuicao_escopo();
create trigger t_atribuicao_escopo before insert or update on erp.atribuicao_nucleos
  for each row execute function erp.tg_atribuicao_escopo();

-- exceção de nível num núcleo × centro: vence os modelos; 'nenhum' tira o acesso
create table erp.excecoes_centro (
  user_id             uuid not null references erp.usuarios,
  nucleo_economico_id uuid not null references erp.nucleos_economicos,
  centro_custo_id     uuid not null references erp.centros_custo,
  nivel               text not null check (nivel in ('nenhum','leitor','lancador_restrito','lancador')),
  fim                 date,
  primary key (user_id, nucleo_economico_id, centro_custo_id)
);
-- exceção de natureza: libera (restrita) ou bloqueia o galho, num centro ou em todos (centro vazio)
create table erp.excecoes_natureza (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references erp.usuarios,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  efeito          text not null check (efeito in ('liberar','bloquear')),
  fim             date,
  unique nulls not distinct (user_id, natureza_id, centro_custo_id)
);

-- diretor da área: papel nominal por centro, entre o gestor e os C-level (ainda fora da alçada)
create table erp.centro_diretores (
  centro_custo_id uuid not null references erp.centros_custo,
  user_id         uuid not null references erp.usuarios,
  primary key (centro_custo_id, user_id)
);

-- só o administrador, e nunca para si mesmo
create function erp.tg_acesso_admin() returns trigger language plpgsql as $$
declare v_eu uuid := erp.eu(); v_old jsonb; v_new jsonb;
begin
  perform erp.exigir_admin();
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  -- confere o dono de antes e o de depois: trocar a pessoa ou a atribuição da linha também é mudar acesso
  if v_eu is not null and (
       (tg_table_name in ('atribuicoes','excecoes_centro','excecoes_natureza','centro_diretores')
        and v_eu::text in (v_old->>'user_id', v_new->>'user_id'))
    or (tg_table_name in ('atribuicao_nucleos','atribuicao_tipos')
        and exists (select 1 from erp.atribuicoes a
                     where a.id::text in (v_old->>'atribuicao_id', v_new->>'atribuicao_id') and a.user_id = v_eu))) then
    raise exception 'Ninguém muda o próprio acesso';
  end if;
  return coalesce(new, old);
end $$;
do $$
declare t record;
begin
  for t in select * from (values ('perfis_modelo', 'id'), ('perfil_centros', 'perfil_id'), ('perfil_naturezas', 'perfil_id'),
                                 ('atribuicoes', 'id'), ('atribuicao_nucleos', 'atribuicao_id'), ('atribuicao_tipos', 'atribuicao_id'),
                                 ('excecoes_centro', 'user_id'), ('excecoes_natureza', 'id'),
                                 ('centro_diretores', 'user_id')) v(tabela, chave) loop
    execute format('create trigger t_acesso_admin before insert or update or delete on erp.%I
                      for each row execute function erp.tg_acesso_admin()', t.tabela);
    execute format('create trigger t_aud_%s after insert or update or delete on erp.%I
                      for each row execute function erp.tg_auditoria(%L)', t.tabela, t.tabela, t.chave);
  end loop;
end $$;
-- quem dá a si mesmo o papel de aprovador também não passa (as tabelas já são só do admin)
create function erp.tg_aprovador_nao_si() returns trigger language plpgsql as $$
begin
  perform erp.exigir_admin();
  if erp.eu() is not null and erp.eu() in (case when tg_op <> 'INSERT' then old.user_id end, case when tg_op <> 'DELETE' then new.user_id end) then
    raise exception 'Ninguém muda o próprio acesso';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_aprovador_nao_si before insert or update or delete on erp.centro_aprovadores
  for each row execute function erp.tg_aprovador_nao_si();
create trigger t_aprovador_nao_si before insert or update or delete on erp.listas_financeiro
  for each row execute function erp.tg_aprovador_nao_si();

-- A natureza (ou um galho acima dela) é restrita?
create function erp.natureza_restrita(p_natureza uuid) returns boolean language sql stable as $$
  with recursive g(id, mae_id, restrita) as (
    select id, mae_id, restrita from erp.naturezas where id = p_natureza
    union all select n.id, n.mae_id, n.restrita from erp.naturezas n join g on n.id = g.mae_id)
  select coalesce(bool_or(restrita), false) from g $$;
-- os galhos acima da natureza, ela inclusive
create function erp.galhos_acima(p_natureza uuid) returns setof uuid language sql stable as $$
  with recursive g(id, mae_id) as (
    select id, mae_id from erp.naturezas where id = p_natureza
    union all select n.id, n.mae_id from erp.naturezas n join g on n.id = g.mae_id)
  select id from g $$;

-- As atribuições vigentes da pessoa que cobrem o núcleo.
create function erp.atribuicoes_no_nucleo(p_user uuid, p_nucleo uuid) returns setof erp.atribuicoes
language sql stable as $$
  select a.* from erp.atribuicoes a join erp.perfis_modelo m on m.id = a.perfil_id and m.ativo
   where a.user_id = p_user and current_date >= a.inicio and (a.fim is null or current_date <= a.fim)
     and not exists (select 1 from erp.atribuicao_nucleos x
                      where x.atribuicao_id = a.id and x.nucleo_economico_id = p_nucleo and not x.incluir)
     and case a.escopo
           when 'todos' then true
           when 'tipos' then exists (select 1 from erp.atribuicao_tipos t join erp.nucleos_economicos n on n.tipo = t.tipo_nucleo
                                      where t.atribuicao_id = a.id and n.id = p_nucleo)
           else exists (select 1 from erp.atribuicao_nucleos x
                         where x.atribuicao_id = a.id and x.nucleo_economico_id = p_nucleo and x.incluir)
             or exists (select 1 from erp.atribuicao_tipos t join erp.nucleos_economicos n on n.tipo = t.tipo_nucleo
                         where t.atribuicao_id = a.id and n.id = p_nucleo and n.criado_em > a.criado_em)
         end $$;

-- O acesso da pessoa num núcleo × centro: vê tudo do centro? lança? (vê só o que lançou = lança
-- sem ver tudo). A exceção vence; sem exceção, a soma dos modelos que cobrem o núcleo.
create function erp.acesso(p_user uuid, p_nucleo uuid, p_centro uuid, out ve_tudo boolean, out lanca boolean)
language plpgsql stable as $$
declare v_exc text;
begin
  select e.nivel into v_exc from erp.excecoes_centro e
   where e.user_id = p_user and e.nucleo_economico_id = p_nucleo and e.centro_custo_id = p_centro
     and (e.fim is null or current_date <= e.fim);
  if v_exc is not null then
    ve_tudo := v_exc in ('leitor','lancador');
    lanca := v_exc in ('lancador_restrito','lancador');
    return;
  end if;
  select coalesce(bool_or(pc.nivel in ('leitor','lancador')), false), coalesce(bool_or(pc.nivel in ('lancador_restrito','lancador')), false)
    into ve_tudo, lanca
    from erp.atribuicoes_no_nucleo(p_user, p_nucleo) a
    join erp.perfil_centros pc on pc.perfil_id = a.perfil_id and pc.centro_custo_id = p_centro;
end $$;

-- A natureza está liberada para a pessoa no núcleo × centro? Bloqueio da pessoa vence; restrita
-- só com liberação (do modelo que dá o centro naquele núcleo, ou da pessoa).
create function erp.natureza_liberada(p_user uuid, p_nucleo uuid, p_centro uuid, p_natureza uuid)
returns boolean language plpgsql stable as $$
begin
  if exists (select 1 from erp.excecoes_natureza e
              where e.user_id = p_user and e.efeito = 'bloquear' and (e.fim is null or current_date <= e.fim)
                and (e.centro_custo_id is null or e.centro_custo_id = p_centro)
                and e.natureza_id in (select erp.galhos_acima(p_natureza))) then
    return false;
  end if;
  if not erp.natureza_restrita(p_natureza) then return true; end if;
  return exists (select 1 from erp.excecoes_natureza e
                  where e.user_id = p_user and e.efeito = 'liberar' and (e.fim is null or current_date <= e.fim)
                    and (e.centro_custo_id is null or e.centro_custo_id = p_centro)
                    and e.natureza_id in (select erp.galhos_acima(p_natureza)))
      or exists (select 1 from erp.atribuicoes_no_nucleo(p_user, p_nucleo) a
                   join erp.perfil_centros pc on pc.perfil_id = a.perfil_id and pc.centro_custo_id = p_centro
                   join erp.perfil_naturezas pn on pn.perfil_id = a.perfil_id
                  where pn.natureza_id in (select erp.galhos_acima(p_natureza)));
end $$;

-- A pessoa vê uma linha classificada em núcleo × centro × natureza, lançada por p_autor?
create function erp.ve_linha(p_user uuid, p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid)
returns boolean language plpgsql stable as $$
declare a record;
begin
  select * into a from erp.acesso(p_user, p_nucleo, p_centro);
  if not (a.ve_tudo or (a.lanca and p_autor = p_user)) then return false; end if;
  return p_natureza is null or erp.natureza_liberada(p_user, p_nucleo, p_centro, p_natureza);
end $$;

-- A pessoa pode lançar em núcleo × centro × natureza?
create function erp.lanca_linha(p_user uuid, p_nucleo uuid, p_centro uuid, p_natureza uuid)
returns boolean language plpgsql stable as $$
begin
  return (select lanca from erp.acesso(p_user, p_nucleo, p_centro))
     and (p_natureza is null or erp.natureza_liberada(p_user, p_nucleo, p_centro, p_natureza));
end $$;

-- ---------------------------------------------------------------------------------------------
-- Mudança de acesso com aprovação (S-078; decisão do Moises, 14/11/2026: "precisa da aprovação,
-- configurado, de quem ou quem's").
-- Ninguém grava direto nas tabelas de acesso. O administrador pede a mudança
-- (erp.pedir_mudanca_acesso). Ela vale quando o mínimo de aprovadores de acesso aprova
-- (erp.decidir_mudanca_acesso). Os aprovadores ficam numa lista configurável e não precisam ser
-- administradores. Quem pediu e quem ganha acesso com a mudança não aprovam. A própria lista e o
-- mínimo também só mudam assim. A primeira lista entra pelo sistema (implantação).
-- Entram no pedido:
--   - os modelos, as atribuições e as exceções;
--   - os papéis (gestor da área, diretor da área, AF, AO e AD);
--   - os tipos de núcleo;
--   - a marca de natureza restrita e a mudança de galho que entra ou sai de um galho restrito;
--   - o tipo de um núcleo que já existe.
-- Quem aplica é erp._aplicar_mudanca_acesso, definer de dono erp_acesso; os gatilhos das tabelas
-- conferem erp.agindo_como('erp_acesso').

create table erp.aprovadores_acesso (
  user_id uuid primary key references erp.usuarios
);
create table erp.regra_acesso (
  id     boolean primary key default true check (id),     -- uma linha só
  minimo int not null default 1 check (minimo >= 1),
  sucessao_dias        int not null default 7 check (sucessao_dias >= 1)   -- da unanimidade à troca, para o master vetar
);
-- O master (Moises, 14/11/2026): um usuário só.
--   - Muda sozinho a lista de aprovadores de acesso e as regras dela; os outros só mudam a lista
--     com a unanimidade dela.
--   - É o único que cria e administra os administradores.
--   - Define o grupo de sucessão.
-- Troca de master: o próprio master passa o papel, ou a sucessão. Na sucessão, o pedido aponta o
-- novo master e precisa da aprovação de todo o grupo de sucessão, sem prazo. Da unanimidade em
-- diante, o master tem 7 dias para vetar e recebe 2 avisos por dia (erp.avisos_sucessao; o envio
-- por e-mail e WhatsApp é do servidor); sem veto, o novo master assume. O grupo de sucessão pode
-- ter usuários só para isso (usuarios.so_sucessao), inclusive de fora da empresa, sem nenhum
-- outro acesso no ERP.
create table erp.master (
  id      boolean primary key default true check (id),
  user_id uuid not null references erp.usuarios
);
create table erp.grupo_sucessao (       -- quem aprova a sucessão do master; só o master define
  user_id uuid primary key references erp.usuarios
);
-- quem o master autoriza a aprovar os níveis marcados "delegado" (Moises, 14/11/2026); só o master define
create table erp.delegados_acesso (
  user_id uuid primary key references erp.usuarios
);
create table erp.sucessoes_master (
  id           uuid primary key default gen_random_uuid(),
  novo_id      uuid not null references erp.usuarios,
  master_id    uuid not null references erp.usuarios,      -- o master na hora do pedido
  motivo       text not null check (length(trim(motivo)) > 0),
  pedida_por   uuid not null references erp.usuarios,
  pedida_em    timestamptz not null default clock_timestamp(),
  unanime_em   timestamptz,                                  -- quando todo o grupo aprovou
  vale_em      timestamptz,                                  -- primeiro aviso enviado + 7 dias: a troca vale daqui, sem veto (S-083)
  aprovadores  uuid[] not null,                              -- o grupo na hora do pedido: todos precisam aprovar
  situacao     text not null default 'pendente' check (situacao in ('pendente','aplicada','recusada','vetada','obsoleta')),
  encerrada_em timestamptz
);
-- avisos ao master enquanto a sucessão está pendente: 2 por dia (manhã e tarde), por canal
create table erp.avisos_sucessao (
  sucessao_id uuid not null references erp.sucessoes_master,
  dia         date not null,
  turno       text not null check (turno in ('manha','tarde')),
  canal       text not null check (canal in ('email','whatsapp')),
  para        uuid not null references erp.usuarios,
  criado_em   timestamptz not null default clock_timestamp(),
  enviado_em  timestamptz,                                    -- o servidor marca ao enviar
  -- link de veto de um clique (Moises, 14/11/2026): o link abre uma página com o botão
  -- Interromper, porque antivírus de e-mail e prévia do WhatsApp abrem links sozinhos; o botão
  -- chama erp.vetar_sucessao_por_link. O servidor gera o token ao enviar e o banco guarda só o
  -- hash dele (S-084), em erp.registrar_envio_aviso.
  token_hash  text unique,
  primary key (sucessao_id, dia, turno, canal)
);
create table erp.sucessao_votos (
  sucessao_id   uuid not null references erp.sucessoes_master,
  user_id       uuid not null references erp.usuarios,
  aprova        boolean not null,
  justificativa text,
  em            timestamptz not null default clock_timestamp(),
  primary key (sucessao_id, user_id),
  check (aprova or length(trim(coalesce(justificativa, ''))) > 0)
);
insert into erp.regra_acesso default values;

-- Quais mudanças do administrador precisam de aprovação (Moises, 14/11/2026: "determinar aprovação
-- para as mudanças, uma a uma, principalmente as mais sensíveis"). Só o master muda. Começa tudo
-- exigindo aprovação. O master nunca precisa; a lista de aprovadores, fora do master, sempre
-- precisa da unanimidade dela.
create table erp.regras_mudanca_acesso (
  tabela          text primary key,
  rotulo          text not null,
  exige_aprovacao boolean not null default true
);
insert into erp.regras_mudanca_acesso (tabela, rotulo) values
  ('perfis_modelo', 'Modelos de acesso'), ('perfil_centros', 'Centros de um modelo'),
  ('perfil_naturezas', 'Naturezas restritas liberadas por um modelo'), ('atribuicoes', 'Atribuições de modelo a pessoas'),
  ('atribuicao_tipos', 'Tipos de núcleo de uma atribuição'), ('atribuicao_nucleos', 'Núcleos de uma atribuição'),
  ('excecoes_centro', 'Exceções de centro'), ('excecoes_natureza', 'Exceções de natureza'),
  ('tipos_nucleo', 'Tipos de núcleo'),
  ('aprovadores_acesso', 'Aprovadores de acesso'), ('regra_acesso', 'Mínimo de aprovações e prazo da sucessão'),
  ('naturezas', 'Marca restrita e galho restrito de natureza'), ('nucleos_economicos', 'Tipo de um núcleo');
create function erp.tg_regras_mudanca_acesso() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.sou_master() then
    if not erp.sistema() and (tg_op in ('INSERT', 'DELETE', 'TRUNCATE') or new.tabela <> old.tabela or new.rotulo <> old.rotulo) then
      raise exception 'As regras são fixas; mude só a exigência';
    end if;
    return coalesce(new, old);
  end if;
  raise exception 'Só o master decide quais mudanças precisam de aprovação';
end $$;
create trigger t_regras_mudanca_acesso before insert or update or delete on erp.regras_mudanca_acesso
  for each row execute function erp.tg_regras_mudanca_acesso();
create trigger t_aud_regras_mudanca_acesso after insert or update or delete on erp.regras_mudanca_acesso
  for each row execute function erp.tg_auditoria('tabela');

-- Usuários e papéis de aprovação (Moises, 14/11/2026): para cada nível, quem aprova antes de valer.
--   nenhuma: o pedido do administrador vale na hora; delegado: um dos delegados do master
--   (erp.delegados_acesso), qualquer um (OU); lista: todos os aprovadores de acesso (E), menos
--   quem pede e quem ganha; master: só o master.
-- Usuário novo (nasce inativo) se ativa pelo nível do papel dele; mudar o papel vale pelo maior
-- entre o papel de antes e o novo; o contador, pelo nível contador. AF, AO e AD: sempre o master.
create table erp.regras_nivel_acesso (
  nivel     text primary key,
  rotulo    text not null,
  aprovacao text not null check (aprovacao in ('nenhuma','delegado','lista','master'))
);
insert into erp.regras_nivel_acesso (nivel, rotulo, aprovacao) values
  ('leitura', 'Usuário leitura', 'delegado'), ('analista', 'Usuário analista (lança)', 'delegado'),
  ('gestor', 'Usuário gestor', 'lista'), ('diretor', 'Usuário diretor', 'master'),
  ('contador', 'Contador', 'lista'), ('gestor_area', 'Gestor da área', 'lista'),
  ('diretor_area', 'Diretor da área', 'lista');
create function erp.tg_regras_nivel_acesso() returns trigger language plpgsql as $$
begin
  if erp.sistema() then return coalesce(new, old); end if;
  if not erp.sou_master() then raise exception 'Só o master decide quem aprova cada nível'; end if;
  if tg_op <> 'UPDATE' or new.nivel <> old.nivel or new.rotulo <> old.rotulo then
    raise exception 'Os níveis são fixos; mude só quem aprova';
  end if;
  return new;
end $$;
create trigger t_regras_nivel_acesso before insert or update or delete on erp.regras_nivel_acesso
  for each row execute function erp.tg_regras_nivel_acesso();
create trigger t_aud_regras_nivel_acesso after insert or update or delete on erp.regras_nivel_acesso
  for each row execute function erp.tg_auditoria('nivel');
create function erp._nivel_aprovacao(p_nivel text) returns text language sql stable as
  $$ select aprovacao from erp.regras_nivel_acesso where nivel = p_nivel $$;
-- o mais exigente de dois tipos de aprovação
create function erp._maior_aprovacao(a text, b text) returns text language sql immutable as $$
  select case when array_position(array['nenhuma','delegado','lista','unanime','master'], coalesce(a, 'nenhuma'))
                 >= array_position(array['nenhuma','delegado','lista','unanime','master'], coalesce(b, 'nenhuma'))
              then coalesce(a, 'nenhuma') else b end $$;

create table erp.mudancas_acesso (
  id            uuid primary key default gen_random_uuid(),
  tabela        text not null,
  operacao      text not null check (operacao in ('incluir','alterar','excluir')),
  dados         jsonb not null,          -- a linha inteira como fica (incluir, alterar) ou a chave (excluir)
  antes         jsonb,                   -- a linha no momento do pedido (alterar, excluir)
  beneficiarios uuid[] not null default '{}',   -- quem pode ganhar acesso com a mudança: não aprova
  motivo        text not null check (length(trim(motivo)) > 0),
  pedida_por    uuid not null references erp.usuarios,
  pedida_em     timestamptz not null default clock_timestamp(),
  minimo        int not null,            -- aprovações exigidas, fixadas no pedido (0: aplicada na hora)
  aprovacao     text not null default 'lista' check (aprovacao in ('nenhuma','delegado','lista','unanime','master')),
  situacao      text not null default 'pendente' check (situacao in ('pendente','aplicada','recusada','cancelada','obsoleta')),
  encerrada_em  timestamptz
);
create table erp.mudanca_acesso_votos (
  mudanca_id    uuid not null references erp.mudancas_acesso,
  user_id       uuid not null references erp.usuarios,
  aprova        boolean not null,
  justificativa text,
  em            timestamptz not null default clock_timestamp(),
  primary key (mudanca_id, user_id),
  check (aprova or length(trim(coalesce(justificativa, ''))) > 0)
);
-- pedidos e votos só pelas funções, e não se apagam
create function erp.tg_mudanca_acesso() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.agindo_como('erp_acesso') then
    if tg_op in ('DELETE', 'TRUNCATE') then raise exception 'O histórico de mudanças de acesso não se apaga'; end if;
    return new;
  end if;
  raise exception 'Mudança de acesso só pelo pedido (erp.pedir_mudanca_acesso) e pela decisão (erp.decidir_mudanca_acesso)';
end $$;
create trigger t_mudanca_acesso before insert or update or delete on erp.mudancas_acesso
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_mudanca_acesso before insert or update or delete on erp.mudanca_acesso_votos
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_mudanca_acesso before insert or update or delete on erp.master
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_mudanca_acesso before insert or update or delete on erp.sucessoes_master
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_mudanca_acesso before insert or update or delete on erp.sucessao_votos
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_mudanca_acesso before insert or update or delete on erp.avisos_sucessao
  for each row execute function erp.tg_mudanca_acesso();
create trigger t_aud_master after insert or update on erp.master
  for each row execute function erp.tg_auditoria('user_id');
create trigger t_aud_delegados_acesso after insert or update or delete on erp.delegados_acesso
  for each row execute function erp.tg_auditoria('user_id');
create trigger t_aud_grupo_sucessao after insert or update or delete on erp.grupo_sucessao
  for each row execute function erp.tg_auditoria('user_id');
create trigger t_aud_sucessoes_master after insert or update on erp.sucessoes_master
  for each row execute function erp.tg_auditoria('id');

create function erp.sou_master() returns boolean language sql stable as
  $$ select exists (select 1 from erp.master where user_id = erp.eu()) $$;

-- grupo de sucessão e administradores: só o master (ou o sistema)
create function erp.tg_so_master() returns trigger language plpgsql as $$
begin
  if tg_table_name = 'delegados_acesso' and tg_op <> 'DELETE' then perform erp.recusar_so_sucessao(new.user_id); end if;
  if tg_table_name = 'usuarios' and tg_op <> 'DELETE' then
    -- a data da primeira ativação nasce sozinha e não muda
    if new.ativo and (tg_op = 'INSERT' or (not old.ativo and old.ativado_em is null)) then
      new.ativado_em := clock_timestamp();
    elsif tg_op = 'INSERT' then
      new.ativado_em := null;
    elsif new.ativado_em is distinct from old.ativado_em then
      raise exception 'A data de ativação do usuário não muda';
    end if;
  end if;
  if not (erp.sistema() or erp.sou_master()) then
    if tg_table_name = 'usuarios' then
      if tg_op = 'DELETE' then raise exception 'Só o master apaga usuário'; end if;
      if new.administrador or (tg_op = 'UPDATE' and old.administrador) then
        raise exception 'Só o master cria e administra os administradores';
      end if;
      if new.so_sucessao or (tg_op = 'UPDATE' and old.so_sucessao) then
        raise exception 'Só o master cria e muda usuário de sucessão';
      end if;
      -- a única exceção: o pedido aprovado ativa o usuário novo (nunca ativado)
      if tg_op = 'UPDATE' and (new.login_id <> old.login_id or new.ativo <> old.ativo)
         and not (erp.agindo_como('erp_acesso') and new.login_id = old.login_id
                  and new.ativo and not old.ativo and old.ativado_em is null) then
        raise exception 'Só o master muda o login ou a situação de um usuário';
      end if;
      -- usuário novo nasce sem papel; o papel e o contador vêm pelo pedido aprovado
      if tg_op = 'INSERT' and (new.papel <> 'leitura' or new.contador) then
        raise exception 'Usuário novo nasce como leitura; papel e contador só por pedido aprovado (erp.pedir_mudanca_acesso)';
      end if;
      -- e inativo: o login novo só passa a valer quando o master ativa (S-086)
      if tg_op = 'INSERT' and new.ativo then
        raise exception 'Usuário novo nasce inativo; só o master ativa';
      end if;
      if tg_op = 'UPDATE' and (new.papel <> old.papel or new.contador <> old.contador) and not erp.agindo_como('erp_acesso') then
        raise exception 'Papel e contador só mudam por pedido aprovado (erp.pedir_mudanca_acesso)';
      end if;
      return new;
    end if;
    if tg_table_name = 'grupo_sucessao' then raise exception 'Só o master define o grupo de sucessão'; end if;
    raise exception 'Só o master define os delegados';
  end if;
  -- o administrador é o TI: não aprova nada (Moises, 14/11/2026), nem quando o master o cria
  if tg_table_name <> 'usuarios' or tg_op = 'DELETE' then return coalesce(new, old); end if;
  if new.administrador and (tg_op = 'INSERT' or not old.administrador)
     and (exists (select 1 from erp.listas_financeiro where user_id = new.id)
          or exists (select 1 from erp.centro_aprovadores where user_id = new.id)
          or exists (select 1 from erp.centro_diretores where user_id = new.id)
          or exists (select 1 from erp.aprovadores_acesso where user_id = new.id)
          or exists (select 1 from erp.grupo_sucessao where user_id = new.id)) then
    raise exception 'Administrador não aprova nada no ERP: tire a pessoa das listas de aprovação antes';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_so_master before insert or update or delete on erp.grupo_sucessao
  for each row execute function erp.tg_so_master();
create trigger t_so_master before insert or update or delete on erp.delegados_acesso
  for each row execute function erp.tg_so_master();
create trigger t_so_master before insert or update or delete on erp.usuarios
  for each row execute function erp.tg_so_master();

-- tabelas de acesso: só pela mudança aprovada (ou pelo sistema)
-- usuário só de sucessão não recebe nenhum acesso
create function erp.recusar_so_sucessao(p_user uuid) returns void language plpgsql stable as $$
begin
  if exists (select 1 from erp.usuarios where id = p_user and so_sucessao) then
    raise exception 'Usuário só de sucessão não recebe acesso no ERP';
  end if;
end $$;
-- administrador (o TI) não aprova nada no ERP (Moises, 14/11/2026)
create function erp.recusar_admin_aprovador(p_user uuid) returns void language plpgsql stable as $$
begin
  if exists (select 1 from erp.usuarios where id = p_user and administrador) then
    raise exception 'Administrador não aprova nada no ERP';
  end if;
end $$;
create function erp.tg_aprovador_nao_admin() returns trigger language plpgsql as $$
begin
  if tg_op <> 'DELETE' then perform erp.recusar_admin_aprovador(new.user_id); end if;
  return coalesce(new, old);
end $$;
create or replace function erp.tg_acesso_admin() returns trigger language plpgsql as $$
begin
  if tg_op <> 'DELETE' and tg_table_name in ('atribuicoes','excecoes_centro','excecoes_natureza','centro_diretores','aprovadores_acesso') then
    perform erp.recusar_so_sucessao((to_jsonb(new)->>'user_id')::uuid);
  end if;
  if erp.agindo_como('erp_acesso') or erp.sistema() then return coalesce(new, old); end if;
  raise exception 'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)';
end $$;
create or replace function erp.tg_aprovador_nao_si() returns trigger language plpgsql as $$
begin
  if tg_op <> 'DELETE' then perform erp.recusar_so_sucessao(new.user_id); end if;
  if erp.agindo_como('erp_acesso') or erp.sistema() then return coalesce(new, old); end if;
  raise exception 'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)';
end $$;
create trigger t_acesso_admin before insert or update or delete on erp.tipos_nucleo
  for each row execute function erp.tg_acesso_admin();
create trigger t_acesso_admin before insert or update or delete on erp.aprovadores_acesso
  for each row execute function erp.tg_acesso_admin();
create trigger t_acesso_admin before insert or update or delete on erp.regra_acesso
  for each row execute function erp.tg_acesso_admin();
create trigger t_aud_aprovadores_acesso after insert or update or delete on erp.aprovadores_acesso
  for each row execute function erp.tg_auditoria('user_id');
create trigger t_aud_regra_acesso after insert or update or delete on erp.regra_acesso
  for each row execute function erp.tg_auditoria('minimo');
create trigger t_aud_mudancas_acesso after insert or update on erp.mudancas_acesso
  for each row execute function erp.tg_auditoria('id');

-- marca restrita, galho restrito e tipo de núcleo: só pela mudança aprovada
create function erp.tg_natureza_acesso() returns trigger language plpgsql as $$
begin
  if erp.agindo_como('erp_acesso') or erp.sistema() then return new; end if;
  if (tg_op = 'INSERT' and new.restrita)
     or (tg_op = 'UPDATE' and (new.restrita <> old.restrita
         or (new.mae_id is distinct from old.mae_id
             and coalesce(erp.natureza_restrita(new.mae_id), false) <> coalesce(erp.natureza_restrita(old.mae_id), false)))) then
    raise exception 'Marcar natureza restrita ou mudá-la de galho restrito só por pedido aprovado (erp.pedir_mudanca_acesso)';
  end if;
  return new;
end $$;
create trigger t_natureza_acesso before insert or update on erp.naturezas
  for each row execute function erp.tg_natureza_acesso();
create function erp.tg_nucleo_acesso() returns trigger language plpgsql as $$
begin
  if erp.agindo_como('erp_acesso') or erp.sistema() then return new; end if;
  if new.tipo <> old.tipo then
    raise exception 'Mudar o tipo do núcleo só por pedido aprovado (erp.pedir_mudanca_acesso)';
  end if;
  return new;
end $$;
create trigger t_nucleo_acesso before update on erp.nucleos_economicos
  for each row execute function erp.tg_nucleo_acesso();

-- A linha atual de uma tabela de acesso, pela chave em p_dados (nula se não existe).
create function erp._linha_acesso(p_tabela text, d jsonb) returns jsonb language plpgsql stable as $$
begin
  return case p_tabela
    when 'perfis_modelo' then (select to_jsonb(t) from erp.perfis_modelo t where id = (d->>'id')::uuid)
    when 'perfil_centros' then (select to_jsonb(t) from erp.perfil_centros t where perfil_id = (d->>'perfil_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid)
    when 'perfil_naturezas' then (select to_jsonb(t) from erp.perfil_naturezas t where perfil_id = (d->>'perfil_id')::uuid and natureza_id = (d->>'natureza_id')::uuid)
    when 'atribuicoes' then (select to_jsonb(t) from erp.atribuicoes t where id = (d->>'id')::uuid)
    when 'atribuicao_tipos' then (select to_jsonb(t) from erp.atribuicao_tipos t where atribuicao_id = (d->>'atribuicao_id')::uuid and tipo_nucleo = d->>'tipo_nucleo')
    when 'atribuicao_nucleos' then (select to_jsonb(t) from erp.atribuicao_nucleos t where atribuicao_id = (d->>'atribuicao_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid)
    when 'excecoes_centro' then (select to_jsonb(t) from erp.excecoes_centro t where user_id = (d->>'user_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid)
    when 'excecoes_natureza' then (select to_jsonb(t) from erp.excecoes_natureza t where id = (d->>'id')::uuid)
    when 'centro_diretores' then (select to_jsonb(t) from erp.centro_diretores t where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid)
    when 'centro_aprovadores' then (select to_jsonb(t) from erp.centro_aprovadores t where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid)
    when 'listas_financeiro' then (select to_jsonb(t) from erp.listas_financeiro t where lista = d->>'lista' and user_id = (d->>'user_id')::uuid)
    when 'tipos_nucleo' then (select to_jsonb(t) from erp.tipos_nucleo t where codigo = d->>'codigo')
    when 'aprovadores_acesso' then (select to_jsonb(t) from erp.aprovadores_acesso t where user_id = (d->>'user_id')::uuid)
    when 'regra_acesso' then (select to_jsonb(t) from erp.regra_acesso t)
    when 'naturezas' then (select jsonb_build_object('id', id, 'mae_id', mae_id, 'restrita', restrita) from erp.naturezas where id = (d->>'id')::uuid)
    when 'nucleos_economicos' then (select jsonb_build_object('id', id, 'tipo', tipo) from erp.nucleos_economicos where id = (d->>'id')::uuid)
    when 'usuarios' then (select jsonb_build_object('id', id, 'papel', papel, 'contador', contador, 'ativo', ativo, 'ativado_em', ativado_em) from erp.usuarios where id = (d->>'id')::uuid)
  end;
end $$;

-- Quem pode ganhar acesso com a mudança (não aprova). Calculado no pedido e de novo na decisão
-- (S-082), porque quem está ligado ao modelo ou tem acesso ao centro muda com o tempo.
--   - linha de uma pessoa: a pessoa (antes e depois); filhas da atribuição: a dona dela, inclusive
--     a de uma atribuição ainda pedida;
--   - modelo: quem está ligado a ele;
--   - marca restrita e galho: quem tem acesso a algum centro (atribuição ou exceção de centro);
--   - tipo de um núcleo: quem tem atribuição pelo tipo novo;
--   - tipos de núcleo e regra da lista: ninguém além de quem pede.
create function erp._beneficiarios_acesso(p_tabela text, d jsonb, a jsonb) returns uuid[] language plpgsql stable as $$
begin
  if p_tabela in ('atribuicoes','excecoes_centro','excecoes_natureza','centro_diretores','centro_aprovadores','listas_financeiro','aprovadores_acesso') then
    return array_remove(array[(d->>'user_id')::uuid, (a->>'user_id')::uuid], null);
  elsif p_tabela = 'usuarios' then
    return array[(d->>'id')::uuid];
  elsif p_tabela in ('atribuicao_tipos','atribuicao_nucleos') then
    return array(select user_id from erp.atribuicoes where id = (d->>'atribuicao_id')::uuid
                 union select (m.dados->>'user_id')::uuid from erp.mudancas_acesso m
                        where m.tabela = 'atribuicoes' and m.dados->>'id' = d->>'atribuicao_id' and m.situacao = 'pendente');
  elsif p_tabela in ('perfis_modelo','perfil_centros','perfil_naturezas') then
    return array(select distinct user_id from erp.atribuicoes where perfil_id = coalesce(d->>'perfil_id', d->>'id')::uuid);
  elsif p_tabela = 'naturezas' then
    return array(select user_id from erp.atribuicoes union select user_id from erp.excecoes_centro where nivel <> 'nenhum');
  elsif p_tabela = 'nucleos_economicos' then
    return array(select a2.user_id from erp.atribuicoes a2 join erp.atribuicao_tipos t on t.atribuicao_id = a2.id
                  where t.tipo_nucleo = d->>'tipo');
  end if;
  return '{}';
end $$;

-- Pede uma mudança de acesso. O administrador ou o master pedem. Devolve o id do pedido.
-- p_dados: a linha (incluir), os campos que mudam com a chave (alterar) ou a chave (excluir).
-- Em naturezas, só restrita e mae_id; em nucleos_economicos, só tipo; em usuarios, papel,
-- contador e a ativação do usuário novo (ativo = true).
-- Quem aprova (aprovacao): o master, na hora, o que ele pede; AF, AO e AD, o master; a lista
-- de aprovadores e as regras dela, a unanimidade da lista; usuários, gestor e diretor da área,
-- pelo nível (erp.regras_nivel_acesso); o resto, a lista, salvo o que o master dispensou
-- (erp.regras_mudanca_acesso).
create function erp.pedir_mudanca_acesso(p_tabela text, p_operacao text, p_dados jsonb, p_motivo text)
returns uuid language plpgsql as $$
declare v_eu uuid := erp.eu(); v_antes jsonb; v_dados jsonb := p_dados; v_benef uuid[] := '{}'; v_min int;
        v_id uuid; v_aprov int; v_tipo text;
begin
  if v_eu is null then raise exception 'O pedido precisa de um usuário'; end if;
  -- dentro desta definer a marca erp_acesso vale; o administrador é conferido pelo cadastro
  if not coalesce((erp.meu_usuario()).administrador, false) and not erp.sou_master() then
    raise exception 'Só o administrador pode mudar a configuração';
  end if;
  if not exists (select 1 from erp.regras_mudanca_acesso where tabela = p_tabela)
     and p_tabela not in ('usuarios','centro_aprovadores','centro_diretores','listas_financeiro') then
    raise exception 'A tabela % não é de acesso', p_tabela;
  end if;
  if p_operacao not in ('incluir','alterar','excluir') then raise exception 'Operação inválida: %', p_operacao; end if;
  if p_tabela in ('naturezas','nucleos_economicos','regra_acesso','usuarios') and p_operacao <> 'alterar' then
    raise exception 'Em % o pedido só altera', p_tabela;
  end if;
  if p_tabela = 'usuarios' and exists (select 1 from jsonb_object_keys(p_dados) k where k not in ('id','papel','contador','ativo')) then
    raise exception 'O pedido de usuário só muda o papel e o contador e ativa o usuário novo (login, desativar e marca de sucessor: só o master)';
  end if;
  if p_tabela = 'usuarios' and p_dados ? 'ativo' and not (
       coalesce((p_dados->>'ativo')::boolean, false)
       and exists (select 1 from erp.usuarios where id = (p_dados->>'id')::uuid and not ativo and ativado_em is null)) then
    raise exception 'Pelo pedido, só se ativa o usuário novo (nunca ativado); desativar e reativar: só o master';
  end if;
  if p_tabela = 'usuarios' and exists (select 1 from erp.usuarios where id = (p_dados->>'id')::uuid and administrador)
     and (coalesce(p_dados->>'papel', 'leitura') not in ('analista','leitura') or coalesce((p_dados->>'contador')::boolean, false)) then
    raise exception 'Administrador não aprova nada no ERP: só papel analista ou leitura, sem contador';
  end if;
  if p_tabela = 'naturezas' and exists (select 1 from jsonb_object_keys(p_dados) k where k not in ('id','restrita','mae_id')) then
    raise exception 'O pedido de natureza só muda a marca restrita e o galho';
  end if;
  if p_tabela = 'nucleos_economicos' and exists (select 1 from jsonb_object_keys(p_dados) k where k not in ('id','tipo')) then
    raise exception 'O pedido de núcleo só muda o tipo';
  end if;
  -- chaves geradas no pedido, para o pedido de uma atribuição nova já poder levar núcleos e tipos
  if p_operacao = 'incluir' and p_tabela in ('perfis_modelo','atribuicoes','excecoes_natureza') and not (v_dados ? 'id') then
    v_dados := v_dados || jsonb_build_object('id', gen_random_uuid());
  end if;
  v_antes := erp._linha_acesso(p_tabela, v_dados);
  if p_operacao = 'incluir' and v_antes is not null then raise exception 'Já existe: altere em vez de incluir'; end if;
  if p_operacao <> 'incluir' and v_antes is null then raise exception 'Não existe o registro a %', p_operacao; end if;
  if p_operacao = 'alterar' then v_dados := v_antes || v_dados; end if;

  v_benef := erp._beneficiarios_acesso(p_tabela, v_dados, v_antes);

  -- quem aprova
  if erp.sou_master() then
    v_tipo := 'nenhuma';                                     -- o master faz qualquer mudança na hora
  elsif p_tabela = 'listas_financeiro' then
    v_tipo := 'master';                                      -- AF, AO e AD (Moises, 14/11/2026), nunca dispensado
  elsif p_tabela in ('aprovadores_acesso','regra_acesso') then
    v_tipo := 'unanime';
  elsif p_tabela = 'centro_aprovadores' then
    v_tipo := erp._nivel_aprovacao('gestor_area');
  elsif p_tabela = 'centro_diretores' then
    v_tipo := erp._nivel_aprovacao('diretor_area');
  elsif p_tabela = 'usuarios' then
    v_tipo := 'nenhuma';
    if not (v_antes->>'ativo')::boolean and (v_dados->>'ativo')::boolean then
      v_tipo := erp._maior_aprovacao(v_tipo, erp._nivel_aprovacao(v_antes->>'papel'));
    end if;
    if v_dados->>'papel' <> v_antes->>'papel' then
      v_tipo := erp._maior_aprovacao(v_tipo, erp._maior_aprovacao(erp._nivel_aprovacao(v_antes->>'papel'), erp._nivel_aprovacao(v_dados->>'papel')));
    end if;
    if v_dados->>'contador' <> v_antes->>'contador' then
      v_tipo := erp._maior_aprovacao(v_tipo, erp._nivel_aprovacao('contador'));
    end if;
  elsif (select exige_aprovacao from erp.regras_mudanca_acesso where tabela = p_tabela) then
    v_tipo := 'lista';                                       -- o mínimo da regra_acesso
  else
    v_tipo := 'nenhuma';                                     -- o master dispensou
  end if;

  -- nos níveis, "lista" é todos da lista (E) e "delegado" é um dos delegados (OU) (Moises, 14/11/2026)
  if p_tabela in ('usuarios','centro_aprovadores','centro_diretores') and v_tipo = 'lista' then v_tipo := 'unanime'; end if;
  if v_tipo = 'nenhuma' then
    insert into erp.mudancas_acesso (tabela, operacao, dados, antes, beneficiarios, motivo, pedida_por, minimo, aprovacao)
    values (p_tabela, p_operacao, v_dados, v_antes, v_benef, p_motivo, v_eu, 0, v_tipo) returning id into v_id;
    perform erp._aplicar_mudanca_acesso(v_id);
    return v_id;
  end if;
  if v_tipo = 'master' then
    if (select user_id from erp.master) = any (v_benef) then
      raise exception 'O master ganha acesso com a mudança: ele mesmo a faz';
    end if;
    v_min := 1;
  elsif v_tipo = 'delegado' then
    select count(*) into v_aprov from erp.delegados_acesso a join erp.usuarios u on u.id = a.user_id and u.ativo and not u.so_sucessao
     where a.user_id <> v_eu and a.user_id <> all (v_benef);
    if v_aprov = 0 and (select user_id from erp.master) = any (v_benef) then
      raise exception 'Não há delegado que possa aprovar esta mudança';
    end if;
    v_min := 1;
  else
    select count(*) into v_aprov from erp.aprovadores_acesso a join erp.usuarios u on u.id = a.user_id and u.ativo
     where a.user_id <> v_eu and a.user_id <> all (v_benef);
    if v_tipo = 'unanime' then
      v_min := v_aprov;                                       -- unanimidade de quem pode aprovar
      if v_min = 0 then raise exception 'Sem outro aprovador na lista, só o master muda a lista'; end if;
    else
      select minimo into v_min from erp.regra_acesso;
    end if;
    if v_aprov < v_min then
      raise exception 'Não há aprovadores de acesso suficientes para esta mudança (precisa de %, há %)', v_min, v_aprov;
    end if;
  end if;
  insert into erp.mudancas_acesso (tabela, operacao, dados, antes, beneficiarios, motivo, pedida_por, minimo, aprovacao)
  values (p_tabela, p_operacao, v_dados, v_antes, v_benef, p_motivo, v_eu, v_min, v_tipo) returning id into v_id;
  return v_id;
end $$;

-- Aplica a mudança aprovada (dono erp_acesso). Os gatilhos de cada tabela continuam valendo.
create function erp._aplicar_mudanca_acesso(p_id uuid) returns void language plpgsql as $$
declare m erp.mudancas_acesso; d jsonb;
begin
  select * into m from erp.mudancas_acesso where id = p_id for update;
  d := m.dados;
  if m.operacao <> 'incluir' and erp._linha_acesso(m.tabela, d) is distinct from m.antes then
    update erp.mudancas_acesso set situacao = 'obsoleta', encerrada_em = clock_timestamp() where id = p_id;
    return;
  end if;
  case m.tabela
  when 'perfis_modelo' then
    if m.operacao = 'incluir' then insert into erp.perfis_modelo select * from jsonb_populate_record(null::erp.perfis_modelo, d || jsonb_build_object('ativo', coalesce((d->>'ativo')::boolean, true)));
    elsif m.operacao = 'alterar' then update erp.perfis_modelo t set nome = r.nome, descricao = r.descricao, ativo = r.ativo from jsonb_populate_record(null::erp.perfis_modelo, d) r where t.id = r.id;
    else delete from erp.perfis_modelo where id = (d->>'id')::uuid; end if;
  when 'perfil_centros' then
    if m.operacao = 'incluir' then insert into erp.perfil_centros select * from jsonb_populate_record(null::erp.perfil_centros, d);
    elsif m.operacao = 'alterar' then update erp.perfil_centros t set nivel = r.nivel from jsonb_populate_record(null::erp.perfil_centros, d) r where t.perfil_id = r.perfil_id and t.centro_custo_id = r.centro_custo_id;
    else delete from erp.perfil_centros where perfil_id = (d->>'perfil_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid; end if;
  when 'perfil_naturezas' then
    if m.operacao = 'incluir' then insert into erp.perfil_naturezas select * from jsonb_populate_record(null::erp.perfil_naturezas, d);
    elsif m.operacao = 'excluir' then delete from erp.perfil_naturezas where perfil_id = (d->>'perfil_id')::uuid and natureza_id = (d->>'natureza_id')::uuid;
    else raise exception 'Linha de natureza do modelo não se altera: exclua e inclua'; end if;
  when 'atribuicoes' then
    if m.operacao = 'incluir' then
      insert into erp.atribuicoes (id, user_id, perfil_id, escopo, inicio, fim)
      select r.id, r.user_id, r.perfil_id, r.escopo, coalesce((d->>'inicio')::date, current_date), r.fim
        from jsonb_populate_record(null::erp.atribuicoes, d) r;
    elsif m.operacao = 'alterar' then update erp.atribuicoes t set perfil_id = r.perfil_id, escopo = r.escopo, inicio = r.inicio, fim = r.fim from jsonb_populate_record(null::erp.atribuicoes, d) r where t.id = r.id;
    else delete from erp.atribuicoes where id = (d->>'id')::uuid; end if;
  when 'atribuicao_tipos' then
    if m.operacao = 'incluir' then insert into erp.atribuicao_tipos select * from jsonb_populate_record(null::erp.atribuicao_tipos, d);
    elsif m.operacao = 'excluir' then delete from erp.atribuicao_tipos where atribuicao_id = (d->>'atribuicao_id')::uuid and tipo_nucleo = d->>'tipo_nucleo';
    else raise exception 'Tipo da atribuição não se altera: exclua e inclua'; end if;
  when 'atribuicao_nucleos' then
    if m.operacao = 'incluir' then insert into erp.atribuicao_nucleos select * from jsonb_populate_record(null::erp.atribuicao_nucleos, d);
    elsif m.operacao = 'alterar' then update erp.atribuicao_nucleos t set incluir = r.incluir from jsonb_populate_record(null::erp.atribuicao_nucleos, d) r where t.atribuicao_id = r.atribuicao_id and t.nucleo_economico_id = r.nucleo_economico_id;
    else delete from erp.atribuicao_nucleos where atribuicao_id = (d->>'atribuicao_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid; end if;
  when 'excecoes_centro' then
    if m.operacao = 'incluir' then insert into erp.excecoes_centro select * from jsonb_populate_record(null::erp.excecoes_centro, d);
    elsif m.operacao = 'alterar' then update erp.excecoes_centro t set nivel = r.nivel, fim = r.fim from jsonb_populate_record(null::erp.excecoes_centro, d) r where t.user_id = r.user_id and t.nucleo_economico_id = r.nucleo_economico_id and t.centro_custo_id = r.centro_custo_id;
    else delete from erp.excecoes_centro where user_id = (d->>'user_id')::uuid and nucleo_economico_id = (d->>'nucleo_economico_id')::uuid and centro_custo_id = (d->>'centro_custo_id')::uuid; end if;
  when 'excecoes_natureza' then
    if m.operacao = 'incluir' then insert into erp.excecoes_natureza select * from jsonb_populate_record(null::erp.excecoes_natureza, d);
    elsif m.operacao = 'alterar' then update erp.excecoes_natureza t set efeito = r.efeito, fim = r.fim from jsonb_populate_record(null::erp.excecoes_natureza, d) r where t.id = r.id;
    else delete from erp.excecoes_natureza where id = (d->>'id')::uuid; end if;
  when 'centro_diretores' then
    if m.operacao = 'incluir' then insert into erp.centro_diretores select * from jsonb_populate_record(null::erp.centro_diretores, d);
    elsif m.operacao = 'excluir' then delete from erp.centro_diretores where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid;
    else raise exception 'Diretor da área não se altera: exclua e inclua'; end if;
  when 'centro_aprovadores' then
    if m.operacao = 'incluir' then insert into erp.centro_aprovadores select * from jsonb_populate_record(null::erp.centro_aprovadores, d);
    elsif m.operacao = 'excluir' then delete from erp.centro_aprovadores where centro_custo_id = (d->>'centro_custo_id')::uuid and user_id = (d->>'user_id')::uuid;
    else raise exception 'Gestor da área não se altera: exclua e inclua'; end if;
  when 'listas_financeiro' then
    if m.operacao = 'incluir' then insert into erp.listas_financeiro select * from jsonb_populate_record(null::erp.listas_financeiro, d);
    elsif m.operacao = 'excluir' then delete from erp.listas_financeiro where lista = d->>'lista' and user_id = (d->>'user_id')::uuid;
    else raise exception 'Lista do financeiro não se altera: exclua e inclua'; end if;
  when 'tipos_nucleo' then
    if m.operacao = 'incluir' then
      insert into erp.tipos_nucleo (codigo, nome, exige_empreendimento, ativo)
      select r.codigo, r.nome, coalesce(r.exige_empreendimento, false), coalesce(r.ativo, true) from jsonb_populate_record(null::erp.tipos_nucleo, d) r;
    elsif m.operacao = 'alterar' then update erp.tipos_nucleo t set nome = r.nome, exige_empreendimento = r.exige_empreendimento, ativo = r.ativo from jsonb_populate_record(null::erp.tipos_nucleo, d) r where t.codigo = r.codigo;
    else delete from erp.tipos_nucleo where codigo = d->>'codigo'; end if;
  when 'aprovadores_acesso' then
    if m.operacao = 'incluir' then insert into erp.aprovadores_acesso values ((d->>'user_id')::uuid);
    elsif m.operacao = 'excluir' then delete from erp.aprovadores_acesso where user_id = (d->>'user_id')::uuid;
    else raise exception 'Aprovador de acesso não se altera: exclua e inclua'; end if;
  when 'regra_acesso' then update erp.regra_acesso set minimo = (d->>'minimo')::int, sucessao_dias = (d->>'sucessao_dias')::int;
  when 'naturezas' then update erp.naturezas set restrita = (d->>'restrita')::boolean, mae_id = (d->>'mae_id')::uuid where id = (d->>'id')::uuid;
  when 'nucleos_economicos' then update erp.nucleos_economicos set tipo = d->>'tipo' where id = (d->>'id')::uuid;
  when 'usuarios' then update erp.usuarios set papel = d->>'papel', contador = (d->>'contador')::boolean, ativo = (d->>'ativo')::boolean where id = (d->>'id')::uuid;
  end case;
  update erp.mudancas_acesso set situacao = 'aplicada', encerrada_em = clock_timestamp() where id = p_id;
end $$;

-- Aprovador de acesso decide o pedido. Recusa precisa de justificativa e encerra o pedido.
-- Com o mínimo de aprovações, a mudança é aplicada na hora.
create function erp.decidir_mudanca_acesso(p_id uuid, p_aprova boolean, p_justificativa text default null)
returns text language plpgsql as $$
declare v_eu uuid := erp.eu(); m erp.mudancas_acesso; v_sim int; v_master boolean := erp.sou_master();
begin
  select * into m from erp.mudancas_acesso where id = p_id for update;
  if m.id is null then raise exception 'Pedido de acesso não encontrado'; end if;
  if m.situacao <> 'pendente' then raise exception 'O pedido de acesso já está %', m.situacao; end if;
  -- o master decide qualquer pedido; os outros, pelo tipo de aprovação do pedido
  if v_master then
    null;
  elsif m.aprovacao = 'master' then
    raise exception 'Só o master decide este pedido';
  elsif m.aprovacao = 'delegado' then
    if not exists (select 1 from erp.delegados_acesso a join erp.usuarios u on u.id = a.user_id and u.ativo and not u.so_sucessao
                    where a.user_id = v_eu) then
      raise exception 'Só um delegado do master decide este pedido';
    end if;
  elsif not exists (select 1 from erp.aprovadores_acesso a join erp.usuarios u on u.id = a.user_id and u.ativo where a.user_id = v_eu) then
    raise exception 'Só um aprovador de acesso decide o pedido';
  end if;
  if v_eu = m.pedida_por then raise exception 'Quem pediu a mudança de acesso não a aprova'; end if;
  if v_eu = any (m.beneficiarios) or v_eu = any (erp._beneficiarios_acesso(m.tabela, m.dados, m.antes)) then
    raise exception 'Quem ganha acesso com a mudança não a aprova';
  end if;
  if not p_aprova and length(trim(coalesce(p_justificativa, ''))) = 0 then
    raise exception 'Recusar o pedido de acesso precisa de justificativa';
  end if;
  insert into erp.mudanca_acesso_votos (mudanca_id, user_id, aprova, justificativa) values (p_id, v_eu, p_aprova, p_justificativa);
  if not p_aprova then
    update erp.mudancas_acesso set situacao = 'recusada', encerrada_em = clock_timestamp() where id = p_id;
    return 'recusada';
  end if;
  if v_master or m.aprovacao in ('master','delegado') then     -- um voto basta
    perform erp._aplicar_mudanca_acesso(p_id);
    return (select situacao from erp.mudancas_acesso where id = p_id);
  end if;
  -- lista: conta só quem ainda é aprovador ativo
  select count(*) into v_sim from erp.mudanca_acesso_votos v
    join erp.aprovadores_acesso a on a.user_id = v.user_id join erp.usuarios u on u.id = v.user_id and u.ativo
   where v.mudanca_id = p_id and v.aprova;
  if v_sim >= m.minimo then
    perform erp._aplicar_mudanca_acesso(p_id);
    return (select situacao from erp.mudancas_acesso where id = p_id);
  end if;
  return 'pendente';
end $$;

-- Quem pediu cancela o pedido pendente.
create function erp.cancelar_mudanca_acesso(p_id uuid) returns void language plpgsql as $$
begin
  if not exists (select 1 from erp.mudancas_acesso where id = p_id and situacao = 'pendente' and pedida_por = erp.eu()) then
    raise exception 'Só quem pediu cancela o pedido pendente';
  end if;
  update erp.mudancas_acesso set situacao = 'cancelada', encerrada_em = clock_timestamp() where id = p_id;
end $$;

-- O master passa o papel a outra pessoa (vale na hora).
create function erp.passar_master(p_novo uuid, p_motivo text) returns void language plpgsql as $$
begin
  if not erp.sou_master() then raise exception 'Só o master passa o papel de master'; end if;
  if not exists (select 1 from erp.usuarios where id = p_novo and ativo) then raise exception 'O novo master precisa ser um usuário ativo'; end if;
  if length(trim(coalesce(p_motivo, ''))) = 0 then raise exception 'Passar o master precisa de motivo'; end if;
  update erp.master set user_id = p_novo;
  update erp.sucessoes_master set situacao = 'obsoleta', encerrada_em = clock_timestamp() where situacao = 'pendente';
end $$;

-- Sucessão do master indisponível (morte, doença): um aprovador de acesso pede; todos os
-- aprovadores da lista na hora do pedido aprovam (o novo master, se estiver na lista, não vota);
-- vale depois da espera, e o master atual pode vetar até lá.
create function erp.pedir_sucessao_master(p_novo uuid, p_motivo text) returns uuid language plpgsql as $$
declare v_eu uuid := erp.eu(); v_master uuid; v_lista uuid[]; v_id uuid;
begin
  select user_id into v_master from erp.master;
  if v_master is null then raise exception 'Não há master cadastrado'; end if;
  if not exists (select 1 from erp.grupo_sucessao g join erp.usuarios u on u.id = g.user_id and u.ativo where g.user_id = v_eu) then
    raise exception 'Só quem está no grupo de sucessão pede a sucessão do master';
  end if;
  if p_novo = v_master then raise exception 'O novo master já é o master'; end if;
  if not exists (select 1 from erp.usuarios where id = p_novo and ativo) then raise exception 'O novo master precisa ser um usuário ativo'; end if;
  if exists (select 1 from erp.sucessoes_master where situacao = 'pendente') then raise exception 'Já há uma sucessão do master pendente'; end if;
  v_lista := array(select g.user_id from erp.grupo_sucessao g join erp.usuarios u on u.id = g.user_id and u.ativo
                    where g.user_id not in (v_master, p_novo) order by g.user_id);
  if cardinality(v_lista) = 0 then raise exception 'Sem ninguém no grupo de sucessão além do master e do novo master, não há sucessão'; end if;
  insert into erp.sucessoes_master (novo_id, master_id, motivo, pedida_por, aprovadores)
  values (p_novo, v_master, p_motivo, v_eu, v_lista)
  returning id into v_id;
  if v_eu = any (v_lista) then
    insert into erp.sucessao_votos (sucessao_id, user_id, aprova) values (v_id, v_eu, true);   -- quem pede já aprova
    perform erp._sucessao_unanime(v_id);
  end if;
  return v_id;
end $$;

create function erp.decidir_sucessao_master(p_id uuid, p_aprova boolean, p_justificativa text default null)
returns void language plpgsql as $$
declare v_eu uuid := erp.eu(); s erp.sucessoes_master;
begin
  select * into s from erp.sucessoes_master where id = p_id for update;
  if s.id is null or s.situacao <> 'pendente' then raise exception 'Não há essa sucessão pendente'; end if;
  if not v_eu = any (s.aprovadores) then raise exception 'Só o grupo de sucessão da hora do pedido decide a sucessão'; end if;
  if not p_aprova and length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Recusar a sucessão precisa de justificativa'; end if;
  insert into erp.sucessao_votos (sucessao_id, user_id, aprova, justificativa) values (p_id, v_eu, p_aprova, p_justificativa);
  if not p_aprova then
    update erp.sucessoes_master set situacao = 'recusada', encerrada_em = clock_timestamp() where id = p_id;
  else
    perform erp._sucessao_unanime(p_id);
  end if;
end $$;

-- Todo o grupo aprovou: saem os avisos ao master. O prazo de veto conta do primeiro aviso
-- enviado (S-083, Moises 14/11/2026), não da unanimidade.
create function erp._sucessao_unanime(p_id uuid) returns void language plpgsql as $$
begin
  update erp.sucessoes_master s
     set unanime_em = clock_timestamp()
   where s.id = p_id and s.unanime_em is null
     and not exists (select 1 from unnest(s.aprovadores) a(u)
                      where not exists (select 1 from erp.sucessao_votos v where v.sucessao_id = s.id and v.user_id = a.u and v.aprova));
  if found then perform erp.gerar_avisos_sucessao(); end if;    -- o primeiro aviso sai na hora
end $$;

-- O master atual veta a sucessão pendente (prova de que não está indisponível).
create function erp.vetar_sucessao_master(p_id uuid) returns void language plpgsql as $$
begin
  if not erp.sou_master() then raise exception 'Só o master veta a sucessão'; end if;
  update erp.sucessoes_master set situacao = 'vetada', encerrada_em = clock_timestamp() where id = p_id and situacao = 'pendente';
  if not found then raise exception 'Não há essa sucessão pendente'; end if;
end $$;

-- Efetiva a sucessão: passada a espera, com todos os aprovadores a favor e o master ainda o mesmo.
create function erp.efetivar_sucessao_master(p_id uuid) returns void language plpgsql as $$
declare s erp.sucessoes_master;
begin
  select * into s from erp.sucessoes_master where id = p_id for update;
  if s.id is null or s.situacao <> 'pendente' then raise exception 'Não há essa sucessão pendente'; end if;
  if s.unanime_em is null then raise exception 'A sucessão precisa da aprovação de todo o grupo de sucessão'; end if;
  if s.vale_em is null then raise exception 'O prazo da sucessão só corre depois do primeiro aviso enviado ao master'; end if;
  if clock_timestamp() < s.vale_em then raise exception 'A sucessão só vale depois de %', s.vale_em; end if;
  if (select user_id from erp.master) <> s.master_id then
    update erp.sucessoes_master set situacao = 'obsoleta', encerrada_em = clock_timestamp() where id = p_id;
    return;
  end if;
  update erp.master set user_id = s.novo_id;
  update erp.sucessoes_master set situacao = 'aplicada', encerrada_em = clock_timestamp() where id = p_id;
end $$;

-- Avisos ao master das sucessões unânimes ainda no prazo de veto, 2 por dia (manhã e tarde) por
-- canal. Roda na rotina do servidor (a cada hora, por exemplo).
create function erp.gerar_avisos_sucessao() returns void language plpgsql as $$
declare v_turno text := case when extract(hour from now() at time zone 'America/Sao_Paulo') < 12 then 'manha' else 'tarde' end;
begin
  insert into erp.avisos_sucessao (sucessao_id, dia, turno, canal, para)
  select s.id, (now() at time zone 'America/Sao_Paulo')::date, v_turno, c.canal, s.master_id
    from erp.sucessoes_master s cross join (values ('email'), ('whatsapp')) c(canal)
   where s.situacao = 'pendente' and s.unanime_em is not null
  on conflict do nothing;
end $$;

create function erp.hash_token(p_token text) returns text language sql immutable as
  $$ select encode(sha256(convert_to(p_token, 'UTF8')), 'hex') $$;

-- O servidor registra o envio do aviso, com o token do link (o banco guarda só o hash).
create function erp.registrar_envio_aviso(p_sucessao uuid, p_dia date, p_turno text, p_canal text, p_token text)
returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o servidor registra o envio do aviso'; end if;
  if length(coalesce(p_token, '')) < 32 then raise exception 'O token do link precisa ter pelo menos 32 caracteres'; end if;
  update erp.avisos_sucessao set enviado_em = clock_timestamp(), token_hash = erp.hash_token(p_token)
   where sucessao_id = p_sucessao and dia = p_dia and turno = p_turno and canal = p_canal and enviado_em is null;
  if not found then raise exception 'Aviso não encontrado ou já enviado'; end if;
  -- o primeiro aviso enviado começa o prazo de veto; os seguintes não o mudam
  update erp.sucessoes_master
     set vale_em = clock_timestamp() + make_interval(days => (select sucessao_dias from erp.regra_acesso))
   where id = p_sucessao and vale_em is null and situacao = 'pendente';
end $$;

-- Veto pelo link do aviso, sem login (o servidor chama com o token do link).
create function erp.vetar_sucessao_por_link(p_token text) returns void language plpgsql as $$
declare v_id uuid;
begin
  if not erp.sistema() then raise exception 'Só o servidor recebe o veto pelo link'; end if;
  select a.sucessao_id into v_id from erp.avisos_sucessao a join erp.sucessoes_master s on s.id = a.sucessao_id
   where a.token_hash = erp.hash_token(p_token) and s.situacao = 'pendente' and s.master_id = (select user_id from erp.master);
  if v_id is null then raise exception 'Link inválido ou sucessão já encerrada'; end if;
  update erp.sucessoes_master set situacao = 'vetada', encerrada_em = clock_timestamp() where id = v_id;
end $$;

do $$
declare t text;
begin
  foreach t in array array['listas_financeiro','centro_aprovadores','centro_diretores','aprovadores_acesso','grupo_sucessao','delegados_acesso'] loop
    execute format('create trigger t_aprovador_nao_admin before insert or update on erp.%I
                      for each row execute function erp.tg_aprovador_nao_admin()', t);
  end loop;
end $$;
