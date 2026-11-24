-- Notas de PJ e de emitente não classificado blindadas (S-144, achado pelo Moises em 24/nov/2026: "As notas dos PJ's
-- devem ir para ambiente blindado visualizado só pelo Master e quem ele liberar").
--
-- Antes, a nota só contava como de PJ quando o emitente era pessoa marcada `restrita`. Sem ninguém marcado (o caso
-- do bkm_dev), toda nota de PJ caía na caixa do financeiro. A proteção agora falha fechada.
--
-- Decisões do Moises (24/nov/2026):
--   - Retém só a NFS-e (cartão): NFS-e de emitente ainda não classificado fica fora da caixa; a NF-e (material)
--     segue como antes (o PJ cobra por NFS-e).
--   - Dois grupos de designados, separados do grupo de quem vê o PJ (erp.designados_pj): o que vê as notas de PJ (a
--     princípio só o master) e o que vê as notas de emitente não classificado (a triagem; pode ter mais gente). Pôr e
--     tirar gente: só o master, sem motivo (a auditoria registra quem e quando).
--   - Tirar um emitente do PJ, e também incluir, pode quem cuida da lista de PJ (quem vê o PJ), sempre com a aprovação
--     do master ou de um aprovador que ele designe (terceiro grupo). O salário continua só com o master.
--
-- 1. erp.notas_grupos: quem está em cada grupo (pj, triagem, aprova). Usuário ativo, nem só da sucessão; o
--    administrador (o TI) não entra no de aprovar.
-- 2. erp.emitentes_classificacao: a classe do emitente pelo CPF/CNPJ (comum ou pj). Sem linha = não classificado,
--    também para os credores importados do Sienge (credor conhecido não prova que não é PJ).
-- 3. erp.emitentes_pedidos: incluir no PJ e tirar do PJ, pedidos por quem não é o master, esperando a aprovação.
--    Enquanto o pedido de incluir espera, o emitente já conta como PJ; recusado, volta ao que era. O de tirar só
--    vale depois de aprovado.
-- 4. A classe que vale (erp._classe_emitente): pj se a pessoa é restrita, se há pedido de incluir esperando ou se a
--    linha diz pj; comum se a linha diz comum; senão, não classificado.
-- 5. Quem vê (erp._vejo_blindagem, usada pela política, pela busca, pelo ignorar e voltar e pela auditoria): nota de
--    PJ, só o master e o grupo pj; NFS-e de não classificado, só o master e a triagem; o resto, como antes. O XML e os
--    eventos seguem a política da nota. A triagem não vê nota de PJ; o grupo pj não vê a não classificada.
-- 6. A NFS-e de não classificado não se liga sozinha a nota lançada; ao virar comum, as dela se ligam.
-- 7. A triagem classifica como comum, ou pede o PJ, só emitente que tem NFS-e na triagem (ou já comum, para pedir o
--    PJ): assim ninguém usa a classificação para perguntar se um CNPJ qualquer é PJ (o erro é o mesmo).
--
-- Fica para o próximo passo: o aviso de emitente novo não classificado (a tela e os avisos da caixa).
-- Portabilidade: SQL puro.
--
-- O mesmo corpo roda no bkm_dev (supabase/dev/ com o mesmo nome), onde o postgres não é superusuário.

-- ---------------------------------------------------------------------------------------------
-- 0. Ferramentas da migration (só nesta sessão)
-- ---------------------------------------------------------------------------------------------
create function pg_temp.trocar(p_fn regprocedure, variadic p_pares text[]) returns void language plpgsql as $$
declare v text := pg_get_functiondef(p_fn); i int; v_n int; v_dono text; v_esq text; v_dar boolean;
begin
  for i in 1 .. coalesce(array_length(p_pares, 1), 0) by 2 loop
    v_n := (length(v) - length(replace(v, p_pares[i], ''))) / length(p_pares[i]);
    if v_n <> 1 then raise exception '%: trecho achado % vezes (esperado 1): %', p_fn, v_n, left(p_pares[i], 120); end if;
    v := replace(v, p_pares[i], p_pares[i + 1]);
  end loop;
  select pg_get_userbyid(p.proowner), n.nspname into v_dono, v_esq
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_fn;
  if v_dono = current_user then execute v; return; end if;
  v_dar := not has_schema_privilege(v_dono, v_esq, 'create');
  if v_dar then execute format('grant create on schema %I to %I', v_esq, v_dono); end if;
  execute format('set local role %I', v_dono);
  execute v;
  reset role;
  if v_dar then execute format('revoke create on schema %I from %I', v_esq, v_dono); end if;
end $$;
create function pg_temp.dono(p_fn regprocedure, p_dono text) returns void language plpgsql as $$
declare v_esq text := (select n.nspname from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_fn);
        v_dar boolean := not has_schema_privilege(p_dono, v_esq, 'create');
begin
  if v_dar then execute format('grant create on schema %I to %I', v_esq, p_dono); end if;
  execute format('alter function %s owner to %I', p_fn, p_dono);
  if v_dar then execute format('revoke create on schema %I from %I', v_esq, p_dono); end if;
end $$;
create function pg_temp.auditar(p_tabela text, p_chave text) returns void language plpgsql as $$
begin
  execute format('grant trigger on erp.%I to erp_conferencia', p_tabela);
  set local role erp_conferencia;
  execute format('create trigger %I after insert or update or delete on erp.%I for each row execute function erp.tg_auditoria(%L)',
                 't_aud_' || p_tabela, p_tabela, p_chave);
  reset role;
  execute format('revoke trigger on erp.%I from erp_conferencia', p_tabela);
end $$;
create function pg_temp.tabela(t text) returns void language plpgsql as $$
begin
  execute format('revoke all on erp.%I from public', t);
  if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke all on erp.%I from authenticated', t); end if;
  execute format('alter table erp.%I enable row level security', t);
  execute format('alter table erp.%I force row level security', t);
  execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
  execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
  execute format('create policy operacao on erp.%I to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true)', t);
  execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
  execute format('grant select, insert, update, delete on erp.%I to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso', t);
  execute format('grant select on erp.%I to erp_conferencia', t);
end $$;


-- ---------------------------------------------------------------------------------------------
-- 1. As tabelas
-- ---------------------------------------------------------------------------------------------
create table erp.notas_grupos (
  user_id uuid not null references erp.usuarios,
  grupo   text not null check (grupo in ('pj', 'triagem', 'aprova')),
  por     uuid not null references erp.usuarios,
  em      timestamptz not null default clock_timestamp(),
  primary key (user_id, grupo)
);

create table erp.emitentes_classificacao (
  documento text primary key check (documento ~ '^[0-9A-Z]{11,14}$'),
  classe    text not null check (classe in ('comum', 'pj')),
  por       uuid not null references erp.usuarios,
  em        timestamptz not null default clock_timestamp()
);

create table erp.emitentes_pedidos (
  id           uuid primary key default gen_random_uuid(),
  documento    text not null check (documento ~ '^[0-9A-Z]{11,14}$'),
  para         text not null check (para in ('comum', 'pj')),
  de           text check (de in ('comum', 'pj')),                 -- a classe antes do pedido (nulo = não classificado)
  pedido_por   uuid not null references erp.usuarios,
  pedido_em    timestamptz not null default clock_timestamp(),
  situacao     text not null default 'pendente' check (situacao in ('pendente', 'aprovado', 'recusado')),
  decidido_por uuid references erp.usuarios,
  decidido_em  timestamptz,
  check ((situacao = 'pendente') = (decidido_por is null)),
  check ((decidido_por is null) = (decidido_em is null))
);
create unique index emitentes_pedidos_um_pendente on erp.emitentes_pedidos (documento) where situacao = 'pendente';

-- grupos: só o master (ou o sistema); a entrada não muda, sai e entra de novo
create function erp.tg_nota_grupo() returns trigger language plpgsql as $$
begin
  if not (erp.sistema() or erp.sou_master()) then raise exception 'Só o master põe e tira gente dos grupos das notas'; end if;
  if tg_op = 'UPDATE' then raise exception 'A entrada no grupo não muda: tire e ponha de novo'; end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger t_nota_grupo before insert or update or delete on erp.notas_grupos
  for each row execute function erp.tg_nota_grupo();

-- classificação e pedidos: nada se apaga; o pedido decidido não muda
create function erp.tg_emitente_classe() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'A classificação do emitente não se apaga'; end if;
  if tg_table_name = 'emitentes_pedidos' and tg_op = 'UPDATE' then
    if old.situacao <> 'pendente' then raise exception 'O pedido já foi decidido'; end if;
    if (new.id, new.documento, new.para, new.de, new.pedido_por, new.pedido_em)
       is distinct from (old.id, old.documento, old.para, old.de, old.pedido_por, old.pedido_em) then
      raise exception 'O pedido não muda, só se decide';
    end if;
  end if;
  return new;
end $$;
create trigger t_emitente_classe before update or delete on erp.emitentes_classificacao
  for each row execute function erp.tg_emitente_classe();
create trigger t_emitente_classe before update or delete on erp.emitentes_pedidos
  for each row execute function erp.tg_emitente_classe();

-- ---------------------------------------------------------------------------------------------
-- 2. Quem vê
-- ---------------------------------------------------------------------------------------------
-- quem está logado está no grupo (usuário ativo, nem só da sucessão)?
create function erp._no_grupo_notas(p_grupo text) returns boolean language sql stable as $$
  select exists (select 1 from erp.notas_grupos g join erp.usuarios u on u.id = g.user_id
                  where g.user_id = erp.eu() and g.grupo = p_grupo and u.ativo and not u.so_sucessao) $$;

-- a classe que vale: 'pj', 'comum' ou nulo (não classificado)
create function erp._classe_emitente(p_documento text) returns text language sql stable as $$
  select case
    when exists (select 1 from erp.pessoas p where p.documento = p_documento and p.restrita) then 'pj'
    when exists (select 1 from erp.emitentes_pedidos q where q.documento = p_documento and q.situacao = 'pendente' and q.para = 'pj') then 'pj'
    else (select c.classe from erp.emitentes_classificacao c where c.documento = p_documento) end $$;

-- a blindagem da nota: 'pj', 'triagem' (NFS-e de não classificado) ou nulo (nota da caixa)
create function erp._blindagem(p_tipo text, p_documento text) returns text language sql stable as $$
  select case erp._classe_emitente(p_documento) when 'pj' then 'pj' when 'comum' then null
              else case when p_tipo = 'nfse' then 'triagem' end end $$;
-- a nota deste tipo e deste emitente passa pela blindagem para quem está logado?
create function erp._vejo_blindagem(p_tipo text, p_documento text) returns boolean language sql stable as $$
  select case erp._blindagem(p_tipo, p_documento) when 'pj' then erp.sou_master() or erp._no_grupo_notas('pj')
              when 'triagem' then erp.sou_master() or erp._no_grupo_notas('triagem') else true end $$;

-- vê quem cuida dos PJ (vê o PJ, o grupo pj ou o de aprovar)?
create function erp._cuido_pj() returns boolean language sql stable as $$
  select erp.membro() and (erp.sou_master() or erp.ve_pj(erp.eu()) or erp._no_grupo_notas('pj') or erp._no_grupo_notas('aprova')) $$;

-- A política da caixa (e o ignorar e voltar) usam _vejo_nota_recebida: troca a regra do PJ pela blindagem.
-- A nota blindada: só quem passa pela blindagem, e para ela não vale a caixa (liberação, financeiro, nota lançada).
select pg_temp.trocar('erp._vejo_nota_recebida(uuid, text, text, uuid)'::regprocedure,
  'and (not erp._nota_recebida_pj(p_documento) or erp.vejo_pj())', 'and erp._vejo_blindagem(p_tipo, p_documento)',
  'and (erp.sou_master() or erp.financeiro()', 'and (erp._blindagem(p_tipo, p_documento) is not null or erp.sou_master() or erp.financeiro()');
-- A nota de PJ: a classe que vale (pessoa restrita, pedido de incluir esperando ou classificada como pj).
select pg_temp.trocar('erp._nota_recebida_pj(text)'::regprocedure,
  'select exists (select 1 from erp.pessoas p where p.documento = p_documento and p.restrita)',
  'select coalesce(erp._classe_emitente(p_documento) = ''pj'', false)');
-- A busca de quem lança, pela chave e pelo emitente: a mesma blindagem.
select pg_temp.trocar('erp.buscar_nota_recebida(text, text, text, numeric)'::regprocedure,
  'if n.id is not null and erp._nota_recebida_pj(n.emitente_documento) and not erp.vejo_pj() then n := null; end if;',
  'if n.id is not null and not erp._vejo_blindagem(n.tipo, n.emitente_documento) then n := null; end if;');
-- A ligação com a nota lançada: a NFS-e de não classificado não se liga (nos dois caminhos).
select pg_temp.trocar('erp._casar_nota_recebida(uuid)'::regprocedure,
  $x$if n.situacao is distinct from 'nova' then return; end if;$x$,
  $x$if n.situacao is distinct from 'nova' then return; end if;
  if n.tipo = 'nfse' and erp._classe_emitente(n.emitente_documento) is null then return; end if;$x$);
select pg_temp.trocar('erp.tg_documento_nota_recebida()'::regprocedure,
  $x$and r.numero = ltrim(new.numero, '0') and r.valor = new.valor_bruto$x$,
  $x$and r.numero = ltrim(new.numero, '0') and r.valor = new.valor_bruto
       and (r.tipo = 'nfe' or erp._classe_emitente(r.emitente_documento) is not null)$x$);

-- A auditoria (lida pelo administrador): a linha da nota segue a blindagem (vale também para o administrador que vê o
-- PJ: o grupo das notas é outro); a classificação e os pedidos, só o master e o grupo pj.
create function erp._vejo_auditoria_nota(p_tabela text, p_antes jsonb, p_depois jsonb) returns boolean language plpgsql stable as $$
declare d jsonb;
begin
  if p_tabela <> 'notas_recebidas' then return erp.sou_master() or erp._no_grupo_notas('pj'); end if;
  foreach d in array array[p_antes, p_depois] loop
    continue when d is null;
    if not erp._vejo_blindagem(d ->> 'tipo', d ->> 'emitente_documento') then return false; end if;
  end loop;
  return true;
end $$;
select pg_temp.trocar('erp.vejo_auditoria(text, text, jsonb, jsonb)'::regprocedure,
  'if erp.ve_pj(erp.eu()) then return true; end if;',
  $x$if p_tabela in ('notas_recebidas', 'emitentes_classificacao', 'emitentes_pedidos') then
    return erp._vejo_auditoria_nota(p_tabela, p_antes, p_depois);
  end if;
  if erp.ve_pj(erp.eu()) then return true; end if;$x$);

-- ---------------------------------------------------------------------------------------------
-- 3. Os grupos (só o master, sem motivo)
-- ---------------------------------------------------------------------------------------------
create function erp.designar_notas(p_pessoa uuid, p_grupo text) returns void language plpgsql as $$
begin
  if not erp.sou_master() then raise exception 'Só o master põe gente nos grupos das notas'; end if;
  if p_grupo is null or p_grupo not in ('pj', 'triagem', 'aprova') then
    raise exception 'Grupo: pj (vê as notas de PJ), triagem (vê as de emitente não classificado) ou aprova (aprova a lista de PJ)';
  end if;
  if not exists (select 1 from erp.usuarios where id = p_pessoa and ativo and not so_sucessao) then
    raise exception 'Só um usuário ativo do ERP entra nos grupos das notas';
  end if;
  if p_grupo = 'aprova' then perform erp.recusar_admin_aprovador(p_pessoa); end if;
  if exists (select 1 from erp.notas_grupos where user_id = p_pessoa and grupo = p_grupo) then
    raise exception 'Esta pessoa já está no grupo';
  end if;
  insert into erp.notas_grupos (user_id, grupo, por) values (p_pessoa, p_grupo, erp.eu());
end $$;

create function erp.retirar_notas(p_pessoa uuid, p_grupo text) returns void language plpgsql as $$
begin
  if not erp.sou_master() then raise exception 'Só o master tira gente dos grupos das notas'; end if;
  delete from erp.notas_grupos where user_id = p_pessoa and grupo = p_grupo;
  if not found then raise exception 'Esta pessoa não está no grupo'; end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 4. Classificar o emitente
-- ---------------------------------------------------------------------------------------------
-- grava a classe e liga as notas que ficaram de fora (a NFS-e de não classificado não se ligava)
create function erp._gravar_classe_emitente(p_documento text, p_classe text) returns void language plpgsql as $$
declare v uuid;
begin
  insert into erp.emitentes_classificacao (documento, classe, por) values (p_documento, p_classe, erp.eu())
  on conflict (documento) do update set classe = excluded.classe, por = excluded.por, em = clock_timestamp();
  for v in select id from erp.notas_recebidas where emitente_documento = p_documento and situacao = 'nova' loop
    perform erp._casar_nota_recebida(v);
  end loop;
end $$;

-- p_classe: 'comum' ou 'pj'. Devolve 'feito' (valeu na hora) ou 'pedido' (espera a aprovação).
--   não classificado → comum: o master ou a triagem, na hora.
--   não classificado ou comum → pj: o master na hora; a triagem e quem vê o PJ, por pedido (some da caixa na hora).
--   pj → comum: o master na hora; quem vê o PJ, por pedido (fica blindada até a aprovação).
-- A triagem só age em emitente com NFS-e na triagem (ou já comum, para pedir o PJ); fora disso, o erro é o mesmo de
-- um CNPJ sem nota, para ninguém usar a classificação para perguntar se um CNPJ é PJ.
create function erp.classificar_emitente(p_documento text, p_classe text) returns text language plpgsql as $$
declare v_doc text := upper(regexp_replace(coalesce(p_documento, ''), '[^0-9A-Za-z]', '', 'g'));
        v_atual text; v_pend boolean; v_restrita boolean; v_master boolean := erp.sou_master();
        v_triagem boolean := erp._no_grupo_notas('triagem'); v_cuida boolean := erp._cuido_pj();
        v_na_triagem boolean;
begin
  if not erp.membro() then raise exception 'Sem permissão'; end if;
  if p_classe is null or p_classe not in ('comum', 'pj') then raise exception 'Classe: comum ou pj'; end if;
  if v_doc !~ '^[0-9A-Z]{11,14}$' then raise exception 'Informe o CPF ou CNPJ do emitente'; end if;
  if not (v_master or v_triagem or erp.ve_pj(erp.eu())) then raise exception 'Sem permissão para classificar emitentes'; end if;
  perform pg_advisory_xact_lock(hashtext('erp.emitente_classe:' || v_doc));
  v_restrita := exists (select 1 from erp.pessoas p where p.documento = v_doc and p.restrita);
  v_pend := exists (select 1 from erp.emitentes_pedidos where documento = v_doc and situacao = 'pendente');
  v_atual := (select classe from erp.emitentes_classificacao where documento = v_doc);
  v_na_triagem := v_atual is null and not v_restrita and not v_pend
                  and exists (select 1 from erp.notas_recebidas where emitente_documento = v_doc and tipo = 'nfse');
  -- quem não cuida dos PJ só vê o que a triagem mostra
  if not v_cuida and not (v_na_triagem or (p_classe = 'pj' and v_atual = 'comum' and not v_restrita and not v_pend)) then
    raise exception 'Este emitente não está na triagem';
  end if;
  if v_restrita then
    raise exception 'O emitente está no cadastro de PJ: a marca da pessoa só o master muda, pelo cadastro';
  end if;
  if v_pend then raise exception 'Já há um pedido para este emitente esperando a aprovação'; end if;
  if v_atual is not distinct from p_classe then raise exception 'O emitente já está nesta classe'; end if;

  if p_classe = 'comum' and v_atual is null then
    if not (v_master or v_triagem) then raise exception 'Só o master e a triagem classificam o emitente como comum'; end if;
    perform erp._gravar_classe_emitente(v_doc, 'comum');
    return 'feito';
  end if;
  if p_classe = 'comum' and not (v_master or erp.ve_pj(erp.eu())) then
    raise exception 'Tirar do PJ é com quem cuida da lista de PJ';
  end if;
  if v_master then
    perform erp._gravar_classe_emitente(v_doc, p_classe);
    return 'feito';
  end if;
  insert into erp.emitentes_pedidos (documento, para, de, pedido_por) values (v_doc, p_classe, v_atual, erp.eu());
  return 'pedido';
end $$;

-- Aprovar ou recusar: o master ou o grupo de aprovar, nunca quem pediu (o master pode, mas o dele já vale na hora).
create function erp.decidir_pedido_emitente(p_pedido uuid, p_aprovar boolean) returns void language plpgsql as $$
declare q erp.emitentes_pedidos;
begin
  if not (erp.membro() and (erp.sou_master() or erp._no_grupo_notas('aprova'))) then
    raise exception 'Só o master e quem ele designou aprovam a lista de PJ';
  end if;
  if p_aprovar is null then raise exception 'Diga se aprova ou recusa'; end if;
  select * into q from erp.emitentes_pedidos where id = p_pedido;
  if q.id is null then raise exception 'Pedido não encontrado'; end if;
  perform pg_advisory_xact_lock(hashtext('erp.emitente_classe:' || q.documento));
  select * into q from erp.emitentes_pedidos where id = p_pedido for update;
  if q.situacao <> 'pendente' then raise exception 'O pedido já foi decidido'; end if;
  if q.pedido_por = erp.eu() and not erp.sou_master() then raise exception 'Quem pediu não aprova o próprio pedido'; end if;
  update erp.emitentes_pedidos set situacao = case when p_aprovar then 'aprovado' else 'recusado' end,
                                   decidido_por = erp.eu(), decidido_em = clock_timestamp()
   where id = p_pedido;
  if p_aprovar then perform erp._gravar_classe_emitente(q.documento, q.para); end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 5. API
-- ---------------------------------------------------------------------------------------------
create function api.notas_grupos()
returns table (user_id uuid, usuario text, grupo text, por text, em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select g.user_id, u.nome, g.grupo, p.nome, g.em
    from erp.notas_grupos g join erp.usuarios u on u.id = g.user_id join erp.usuarios p on p.id = g.por
   order by 3, 2 $$;
create function api.designar_notas(p_pessoa uuid, p_grupo text) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.designar_notas(p_pessoa, p_grupo) $$;
create function api.retirar_notas(p_pessoa uuid, p_grupo text) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.retirar_notas(p_pessoa, p_grupo) $$;
create function api.emitentes_classificacao()
returns table (documento text, classe text, por text, em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select c.documento, c.classe, u.nome, c.em from erp.emitentes_classificacao c join erp.usuarios u on u.id = c.por order by 1 $$;
create function api.emitentes_pedidos()
returns table (id uuid, documento text, para text, de text, pedido_por text, pedido_em timestamptz, situacao text,
               decidido_por text, decidido_em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select q.id, q.documento, q.para, q.de, u.nome, q.pedido_em, q.situacao, d.nome, q.decidido_em
    from erp.emitentes_pedidos q join erp.usuarios u on u.id = q.pedido_por left join erp.usuarios d on d.id = q.decidido_por
   order by q.situacao <> 'pendente', q.pedido_em desc $$;
create function api.classificar_emitente(p_documento text, p_classe text) returns text
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.classificar_emitente(p_documento, p_classe) $$;
create function api.decidir_pedido_emitente(p_pedido uuid, p_aprovar boolean) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.decidir_pedido_emitente(p_pedido, p_aprovar) $$;

-- ---------------------------------------------------------------------------------------------
-- 6. Segurança
-- ---------------------------------------------------------------------------------------------
select pg_temp.tabela('notas_grupos');
select pg_temp.tabela('emitentes_classificacao');
select pg_temp.tabela('emitentes_pedidos');
-- grupos: o master vê todos; cada um, as próprias entradas
create policy perfil_le on erp.notas_grupos for select to authenticated
  using (erp.membro() and (erp.sou_master() or user_id = erp.eu()));
-- classificação: quem cuida dos PJ vê toda; a triagem, só os comuns (os que ela mesma libera)
create policy perfil_le on erp.emitentes_classificacao for select to authenticated
  using (erp._cuido_pj() or (classe = 'comum' and erp._no_grupo_notas('triagem')));
-- pedidos: o master e o grupo de aprovar veem todos; cada um, os próprios
create policy perfil_le on erp.emitentes_pedidos for select to authenticated
  using (erp.membro() and (erp.sou_master() or erp._no_grupo_notas('aprova') or pedido_por = erp.eu()));
grant select on erp.notas_grupos, erp.emitentes_classificacao, erp.emitentes_pedidos to authenticated;
select pg_temp.auditar('notas_grupos', 'user_id');
select pg_temp.auditar('emitentes_classificacao', 'documento');
select pg_temp.auditar('emitentes_pedidos', 'id');

do $$
declare f regprocedure;
begin
  foreach f in array array['erp.tg_nota_grupo()', 'erp.tg_emitente_classe()', 'erp._no_grupo_notas(text)',
    'erp._classe_emitente(text)', 'erp._blindagem(text, text)', 'erp._vejo_blindagem(text, text)', 'erp._cuido_pj()',
    'erp._vejo_auditoria_nota(text, jsonb, jsonb)', 'erp.designar_notas(uuid, text)', 'erp.retirar_notas(uuid, text)',
    'erp._gravar_classe_emitente(text, text)', 'erp.classificar_emitente(text, text)',
    'erp.decidir_pedido_emitente(uuid, boolean)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke execute on function %s from authenticated', f); end if;
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
  foreach f in array array['api.notas_grupos()', 'api.designar_notas(uuid, text)', 'api.retirar_notas(uuid, text)',
    'api.emitentes_classificacao()', 'api.emitentes_pedidos()', 'api.classificar_emitente(text, text)',
    'api.decidir_pedido_emitente(uuid, boolean)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;
-- quem está logado: as conferências das políticas e as operações
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp._no_grupo_notas(text), erp._cuido_pj(), erp.designar_notas(uuid, text), erp.retirar_notas(uuid, text),
      erp.classificar_emitente(text, text), erp.decidir_pedido_emitente(uuid, boolean) to authenticated;
  end if;
end $$;
do $$
declare f text;
begin
  foreach f in array array['erp._no_grupo_notas(text)', 'erp._classe_emitente(text)', 'erp._blindagem(text, text)', 'erp._vejo_blindagem(text, text)',
    'erp._cuido_pj()', 'erp._vejo_auditoria_nota(text, jsonb, jsonb)', 'erp.designar_notas(uuid, text)',
    'erp.retirar_notas(uuid, text)', 'erp._gravar_classe_emitente(text, text)', 'erp.classificar_emitente(text, text)',
    'erp.decidir_pedido_emitente(uuid, boolean)'] loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', f);
  end loop;
end $$;
-- as conferências leem por baixo do RLS (erp_conferencia); classificar e decidir gravam como erp_situacao (ligam as
-- notas); os grupos, como erp_acesso (como a designação do PJ)
select pg_temp.dono(f::regprocedure, 'erp_conferencia') from unnest(array[
  'erp._no_grupo_notas(text)', 'erp._classe_emitente(text)', 'erp._blindagem(text, text)', 'erp._vejo_blindagem(text, text)', 'erp._cuido_pj()',
  'erp._vejo_auditoria_nota(text, jsonb, jsonb)']) f;
select pg_temp.dono(f::regprocedure, 'erp_situacao') from unnest(array[
  'erp._gravar_classe_emitente(text, text)', 'erp.classificar_emitente(text, text)', 'erp.decidir_pedido_emitente(uuid, boolean)']) f;
select pg_temp.dono(f::regprocedure, 'erp_acesso') from unnest(array[
  'erp.designar_notas(uuid, text)', 'erp.retirar_notas(uuid, text)']) f;
