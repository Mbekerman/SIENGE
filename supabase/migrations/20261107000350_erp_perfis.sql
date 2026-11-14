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
