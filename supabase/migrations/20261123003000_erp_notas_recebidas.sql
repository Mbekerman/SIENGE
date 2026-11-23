-- Caixa das notas recebidas: as notas fiscais emitidas contra os CNPJs das empresas do grupo, buscadas pelo serviço
-- do servidor (NF-e na SEFAZ, NFS-e no Ambiente de Dados Nacional, ADN).
--
-- Decisões do Moises:
--   - 17/11/2026: "um buscador de notas de material e, se possível, de serviço, emitidas contra nossos CNPJs".
--   - 23/11/2026, depois do teste do ADN com a BKM 03 (jan a out/2026: 684 notas no ADN × 652 títulos NFSE no Sienge):
--     "pode seguir" = fazer por conta própria a busca da NF-e e da NFS-e; ciência da operação automática em toda NF-e
--     (para baixar o XML completo).
--   - 23/11/2026 (cartão): AF, AO, AD, diretor e master veem a caixa inteira; quem lança acha a nota dele pela chave de
--     acesso, ou pelo CNPJ do emitente com o número (e o valor, para ninguém adivinhar notas de outros centros pela
--     sequência), sem ver as dos outros centros. Nota de PJ (emitente com cadastro restrito), só o master e os
--     designados veem, como o resto do PJ.
--   - 23/11/2026, logo depois: a caixa agrupada por empresa (não por núcleo: a nota só traz o CNPJ da empresa, e uma
--     empresa tem vários núcleos), e o master libera, além do financeiro, quem vê as notas, por empresa e por tipo
--     (Material = NF-e, Serviço = NFS-e). "AD pode liberar tb".
--
-- 1. erp.notas_recebidas: uma linha por nota (pela chave de acesso), com a empresa, o emitente (CNPJ ou CPF e nome,
--    como vieram na nota), número, série, emissão, competência, valor e município. Os dados da nota nunca mudam
--    nem se apagam. Situação: nova, vinculada (a uma nota lançada no ERP) ou ignorada (com o motivo).
-- 2. erp.notas_recebidas_xml: o XML, à parte (não vai para a auditoria). Na NF-e chega primeiro o resumo; depois da
--    ciência chega o completo, que substitui o resumo uma vez só. O completo nunca muda.
-- 3. erp.notas_recebidas_eventos: os eventos (cancelamento pelo emitente e outros), guardados como vieram. O
--    cancelamento marca a nota como cancelada pelo emitente.
-- 4. erp.notas_recebidas_leituras: onde a busca parou em cada empresa e origem (último NSU), para a tela mostrar a
--    última busca e o serviço continuar de onde parou.
-- 5. A nota se liga sozinha à nota lançada no ERP da mesma empresa, tipo, emitente e número (o que chegar depois,
--    a nota da caixa ou o lançamento, faz a ligação). Nota lançada que é cancelada solta a ligação.
-- 6. erp.notas_recebidas_acessos: quem, além do financeiro, do diretor e do master, vê as notas de uma empresa e de um
--    tipo. O master e o AD liberam e tiram (com o motivo, na auditoria).
-- 7. Só o sistema (o serviço da busca) grava as notas, os eventos e as leituras. Ignorar e voltar a nota: o
--    financeiro (AF, AO, AD) e o master.
--
-- Fica para o próximo passo: o serviço da busca (job do servidor), o aviso de nota nova ou cancelada e a tela.
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
create table erp.notas_recebidas (
  id                 uuid primary key default gen_random_uuid(),
  empresa_id         uuid not null references erp.empresas,
  tipo               text not null check (tipo in ('nfe', 'nfse')),
  chave              text not null unique,
  nsu                bigint not null check (nsu >= 0),
  emitente_documento text not null check (emitente_documento ~ '^([0-9]{11}|[0-9]{14})$'),
  emitente_nome      text check (length(emitente_nome) <= 255),
  numero             text not null check (numero ~ '^[1-9][0-9]{0,14}$'),     -- sem zeros à esquerda
  serie              text not null default '' check (serie ~ '^[0-9]{0,3}$'),
  emissao            date not null,
  competencia        date not null check (extract(day from competencia) = 1),
  valor              numeric(15,2) not null check (valor >= 0),
  municipio          text check (municipio ~ '^[0-9]{7}$'),                    -- código IBGE (NFS-e: incidência)
  ciencia_em         timestamptz,                                               -- NF-e: ciência da operação feita
  cancelada_em       timestamptz,                                               -- o emitente cancelou
  situacao           text not null default 'nova' check (situacao in ('nova', 'vinculada', 'ignorada')),
  documento_id       uuid references erp.documentos_fiscais,
  vinculada_em       timestamptz,
  ignorada_motivo    text check (length(trim(ignorada_motivo)) between 3 and 500),
  ignorada_por       uuid,
  ignorada_em        timestamptz,
  recebida_em        timestamptz not null default clock_timestamp(),
  atualizada_em      timestamptz not null default clock_timestamp(),
  check (tipo <> 'nfe' or chave ~ '^[0-9]{44}$'),
  check (tipo <> 'nfse' or chave ~ '^[0-9]{50}$'),
  check ((situacao = 'vinculada') = (documento_id is not null)),
  check ((documento_id is null) = (vinculada_em is null)),
  check ((situacao = 'ignorada') = (ignorada_motivo is not null)),
  check ((ignorada_motivo is null) = (ignorada_em is null))
);
create unique index notas_recebidas_documento on erp.notas_recebidas (documento_id) where documento_id is not null;
create index on erp.notas_recebidas (empresa_id, situacao, emissao);
create index on erp.notas_recebidas (emitente_documento, numero);

create table erp.notas_recebidas_xml (
  nota_id     uuid primary key references erp.notas_recebidas,
  xml         text not null check (length(xml) between 1 and 5242880),       -- até 5 MB
  sha256      text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  completo    boolean not null,                                               -- NF-e: false = só o resumo
  gravado_em  timestamptz not null default clock_timestamp()
);

create table erp.notas_recebidas_eventos (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references erp.empresas,
  chave       text not null check (chave ~ '^([0-9]{44}|[0-9]{50})$'),       -- da nota (pode chegar antes dela)
  codigo      text not null check (codigo ~ '^[0-9]{6}$'),                   -- tipo do evento (110111, 101101...)
  cancelamento boolean not null,
  nsu         bigint not null check (nsu >= 0),
  xml         text not null check (length(xml) between 1 and 1048576),
  recebido_em timestamptz not null default clock_timestamp(),
  unique (chave, codigo, nsu)
);
create index on erp.notas_recebidas_eventos (chave);

create table erp.notas_recebidas_leituras (
  empresa_id    uuid not null references erp.empresas,
  origem        text not null check (origem in ('sefaz', 'adn')),
  ultimo_nsu    bigint not null default 0 check (ultimo_nsu >= 0),
  maximo_nsu    bigint check (maximo_nsu >= 0),
  consultado_em timestamptz,
  bloqueado_ate timestamptz,              -- SEFAZ: consumo indevido (656) bloqueia a empresa por 1 hora
  erro          text check (length(erro) <= 1000),
  primary key (empresa_id, origem)
);

create table erp.notas_recebidas_acessos (
  user_id    uuid not null references erp.usuarios,
  empresa_id uuid not null references erp.empresas,
  tipo       text not null check (tipo in ('nfe', 'nfse')),
  motivo     text not null check (length(trim(motivo)) between 3 and 500),
  por        uuid not null references erp.usuarios,
  em         timestamptz not null default clock_timestamp(),
  primary key (user_id, empresa_id, tipo)
);

-- 1.6 erp.notas_recebidas_buscas: cada busca de quem lança (revisão do #126, 23/11/2026): quem, por qual critério e se
-- achou. Serve ao limite por hora da busca pelo emitente e à conferência do financeiro. Só cresce.
create table erp.notas_recebidas_buscas (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references erp.usuarios,
  em       timestamptz not null default clock_timestamp(),
  criterio text not null check (criterio in ('chave', 'emitente')),
  nota_id  uuid references erp.notas_recebidas
);
create index on erp.notas_recebidas_buscas (user_id, em);

-- ---------------------------------------------------------------------------------------------
-- 2. Travas das tabelas
-- ---------------------------------------------------------------------------------------------
-- Os dados da nota nunca mudam; a situação muda pelas operações; ciência e cancelamento, uma vez só.
create function erp.tg_nota_recebida() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'A nota recebida não se apaga'; end if;
  if tg_op = 'INSERT' then
    if not erp.sistema() then raise exception 'Só o serviço da busca grava a nota recebida'; end if;
    if new.situacao <> 'nova' then raise exception 'A nota recebida entra como nova'; end if;
    new.recebida_em := clock_timestamp();
    new.atualizada_em := new.recebida_em;
    return new;
  end if;
  if (new.id, new.empresa_id, new.tipo, new.chave, new.nsu, new.emitente_documento, new.emitente_nome, new.numero,
      new.serie, new.emissao, new.competencia, new.valor, new.municipio, new.recebida_em)
     is distinct from
     (old.id, old.empresa_id, old.tipo, old.chave, old.nsu, old.emitente_documento, old.emitente_nome, old.numero,
      old.serie, old.emissao, old.competencia, old.valor, old.municipio, old.recebida_em) then
    raise exception 'Os dados da nota recebida não mudam';
  end if;
  if old.ciencia_em is not null and new.ciencia_em is distinct from old.ciencia_em then raise exception 'A ciência já foi registrada'; end if;
  if old.cancelada_em is not null and new.cancelada_em is distinct from old.cancelada_em then raise exception 'O cancelamento já foi registrado'; end if;
  if (new.ciencia_em is distinct from old.ciencia_em or new.cancelada_em is distinct from old.cancelada_em) and not erp.sistema() then
    raise exception 'Ciência e cancelamento só o serviço da busca registra';
  end if;
  new.atualizada_em := clock_timestamp();
  return new;
end $$;
create trigger t_nota_recebida before insert or update or delete on erp.notas_recebidas
  for each row execute function erp.tg_nota_recebida();

-- O XML: só o sistema grava; o resumo vira o completo uma vez; o completo nunca muda; nada se apaga.
create function erp.tg_nota_recebida_xml() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'O XML da nota recebida não se apaga'; end if;
  if not erp.sistema() then raise exception 'Só o serviço da busca grava o XML da nota'; end if;
  if tg_op = 'UPDATE' then
    if new.nota_id <> old.nota_id then raise exception 'O XML não troca de nota'; end if;
    if old.completo then raise exception 'O XML completo da nota não muda'; end if;
    if not new.completo then raise exception 'O resumo só é trocado pelo XML completo'; end if;
  end if;
  new.gravado_em := clock_timestamp();
  return new;
end $$;
create trigger t_nota_recebida_xml before insert or update or delete on erp.notas_recebidas_xml
  for each row execute function erp.tg_nota_recebida_xml();

create function erp.tg_nota_recebida_evento() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'O evento da nota recebida não muda nem se apaga'; end if;
  if not erp.sistema() then raise exception 'Só o serviço da busca grava o evento da nota'; end if;
  new.recebido_em := clock_timestamp();
  return new;
end $$;
create trigger t_nota_recebida_evento before insert or update or delete on erp.notas_recebidas_eventos
  for each row execute function erp.tg_nota_recebida_evento();

create function erp.tg_nota_recebida_leitura() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'A leitura das notas não se apaga'; end if;
  if not erp.sistema() then raise exception 'Só o serviço da busca grava a leitura das notas'; end if;
  if tg_op = 'UPDATE' and new.ultimo_nsu < old.ultimo_nsu then raise exception 'O último NSU lido não volta'; end if;
  return new;
end $$;
create trigger t_nota_recebida_leitura before insert or update or delete on erp.notas_recebidas_leituras
  for each row execute function erp.tg_nota_recebida_leitura();

create function erp.tg_nota_recebida_busca() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'O registro das buscas não muda nem se apaga'; end if;
  return new;
end $$;
create trigger t_nota_recebida_busca before insert or update or delete on erp.notas_recebidas_buscas
  for each row execute function erp.tg_nota_recebida_busca();

-- ---------------------------------------------------------------------------------------------
-- 3. Quem vê
-- ---------------------------------------------------------------------------------------------
-- A nota é de PJ quando o emitente tem cadastro restrito (lido por baixo do RLS de pessoas, que esconde justamente
-- essas pessoas de quem não vê o PJ). Vale o cadastro de hoje: a pessoa marcada depois esconde as notas antigas.
create function erp._nota_recebida_pj(p_documento text) returns boolean language sql stable as $$
  select exists (select 1 from erp.pessoas p where p.documento = p_documento and p.restrita) $$;

-- Vê a nota: o financeiro (AF, AO, AD), o diretor e o master; quem o master liberou para a empresa e o tipo; quem vê a
-- nota lançada a que ela está ligada. A de PJ, só quem vê o PJ.
create function erp._vejo_nota_recebida(p_empresa uuid, p_tipo text, p_documento text, p_lancada uuid) returns boolean
language sql stable as $$
  select erp.membro()
     and (not erp._nota_recebida_pj(p_documento) or erp.vejo_pj())
     and (erp.sou_master() or erp.financeiro() or coalesce(erp.meu_papel(), '') = 'diretor'
          or exists (select 1 from erp.notas_recebidas_acessos a where a.user_id = erp.eu() and a.empresa_id = p_empresa and a.tipo = p_tipo)
          or (p_lancada is not null and erp.vejo_documento(p_lancada))) $$;

-- A última busca da empresa: quem vê a caixa inteira e quem foi liberado para a empresa.
create function erp._vejo_leitura_notas(p_empresa uuid) returns boolean language sql stable as $$
  select erp.membro() and (erp.sou_master() or erp.financeiro() or coalesce(erp.meu_papel(), '') = 'diretor'
                           or exists (select 1 from erp.notas_recebidas_acessos a where a.user_id = erp.eu() and a.empresa_id = p_empresa)) $$;

-- Lança em alguma linha da empresa (algum núcleo dela × centro ligado).
create function erp._lanco_na_empresa(p_empresa uuid) returns boolean language sql stable as $$
  select erp.escrevo() and (erp.sou_master() or exists (
    select 1 from erp.nucleos_economicos n join erp.nucleo_centros nc on nc.nucleo_economico_id = n.id and nc.ligado
     where n.empresa_id = p_empresa and n.ativo and (erp.acesso(erp.eu(), n.id, nc.centro_custo_id)).lanca)) $$;

-- Limite da busca pelo emitente, por pessoa e por hora (a busca pela chave não tem limite: a chave não se adivinha).
create function erp.limite_busca_notas() returns int language sql immutable as $$ select 20 $$;

-- Quem lança acha a nota dele: pela chave de acesso, ou pelo CNPJ ou CPF do emitente com o número e o valor exatos.
-- Pelo emitente (revisão do #126): só a nota nova, de empresa em que a pessoa lança, e no máximo erp.limite_busca_notas()
-- buscas por hora. Toda busca fica registrada. Volta a nota (com o XML se ainda está nova) ou nada. A de PJ, só para quem vê o PJ.
create function erp.buscar_nota_recebida(p_chave text, p_emitente text, p_numero text, p_valor numeric) returns jsonb
language plpgsql as $$
declare n erp.notas_recebidas; v_chave text := regexp_replace(coalesce(p_chave, ''), '\D', '', 'g');
        v_doc text := regexp_replace(coalesce(p_emitente, ''), '\D', '', 'g');
        v_num text := ltrim(regexp_replace(coalesce(p_numero, ''), '\D', '', 'g'), '0');
        v_crit text;
begin
  if not erp.escrevo() then raise exception 'Sem permissão para lançar'; end if;
  if v_chave <> '' then
    v_crit := 'chave';
    select * into n from erp.notas_recebidas where chave = v_chave;
  elsif length(v_doc) in (11, 14) and v_num <> '' and p_valor is not null then
    v_crit := 'emitente';
    if (select count(*) from erp.notas_recebidas_buscas b where b.user_id = erp.eu() and b.criterio = 'emitente'
         and b.em > clock_timestamp() - interval '1 hour') >= erp.limite_busca_notas() then
      raise exception 'Limite de buscas pelo emitente nesta hora; busque pela chave de acesso';
    end if;
    select * into n from erp.notas_recebidas r
     where r.emitente_documento = v_doc and r.numero = v_num and r.valor = round(p_valor, 2) and r.situacao = 'nova'
       and erp._lanco_na_empresa(r.empresa_id)
     order by r.emissao desc limit 1;
  else
    raise exception 'Informe a chave de acesso, ou o CNPJ do emitente com o número e o valor';
  end if;
  if n.id is not null and erp._nota_recebida_pj(n.emitente_documento) and not erp.vejo_pj() then n := null; end if;
  insert into erp.notas_recebidas_buscas (user_id, criterio, nota_id) values (erp.eu(), v_crit, n.id);
  if n.id is null then return null; end if;
  return jsonb_build_object('id', n.id, 'empresa', n.empresa_id, 'tipo', n.tipo, 'chave', n.chave,
    'emitente_documento', n.emitente_documento, 'emitente_nome', n.emitente_nome, 'numero', n.numero, 'serie', n.serie,
    'emissao', n.emissao, 'competencia', n.competencia, 'valor', n.valor, 'municipio', n.municipio,
    'situacao', n.situacao, 'cancelada', n.cancelada_em is not null,
    'xml', case when n.situacao = 'nova' then (select x.xml from erp.notas_recebidas_xml x where x.nota_id = n.id) end);
end $$;

-- A auditoria (lida pelo administrador) esconde as linhas das notas de PJ, como as outras linhas de PJ.
select pg_temp.trocar('erp.vejo_auditoria(text, text, jsonb, jsonb)'::regprocedure,
  $x$    if p_tabela = 'pessoas' and coalesce((d ->> 'restrita')::boolean, false) then return false; end if;$x$,
  $x$    if p_tabela = 'pessoas' and coalesce((d ->> 'restrita')::boolean, false) then return false; end if;
    if p_tabela = 'notas_recebidas' and erp._nota_recebida_pj(d ->> 'emitente_documento') then return false; end if;$x$);

-- ---------------------------------------------------------------------------------------------
-- 4. Ligação com a nota lançada no ERP
-- ---------------------------------------------------------------------------------------------
-- Liga a nota recebida nova à nota lançada (não cancelada) da mesma empresa, tipo, emitente, número, série (NF-e) e
-- valor (revisão do #126: com outro valor, ou outra série, não liga e a nota fica nova para o financeiro ver).
create function erp._casar_nota_recebida(p_nota uuid) returns void language plpgsql as $$
declare n erp.notas_recebidas; v_doc uuid;
begin
  select * into n from erp.notas_recebidas where id = p_nota for update;
  if n.situacao is distinct from 'nova' then return; end if;
  select d.id into v_doc from erp.documentos_fiscais d join erp.pessoas p on p.id = d.emitente_id
   where d.situacao = 'lancado' and d.empresa_id = n.empresa_id and d.tipo = n.tipo
     and p.documento = n.emitente_documento and ltrim(d.numero, '0') = n.numero and d.valor_bruto = n.valor
     and (n.tipo = 'nfse' or ltrim(d.serie, '0') = n.serie)
     and not exists (select 1 from erp.notas_recebidas x where x.documento_id = d.id)
   order by d.lancado_em limit 1;
  if v_doc is not null then
    update erp.notas_recebidas set situacao = 'vinculada', documento_id = v_doc, vinculada_em = clock_timestamp() where id = p_nota;
  end if;
end $$;

-- A nota lançada no ERP acha a nota recebida; a cancelada (inclusive a recusada na alçada) solta.
create function erp.tg_documento_nota_recebida() returns trigger language plpgsql as $$
declare v_nota uuid;
begin
  if new.situacao = 'cancelado' then
    update erp.notas_recebidas set situacao = 'nova', documento_id = null, vinculada_em = null where documento_id = new.id;
  elsif new.situacao = 'lancado' and new.tipo in ('nfe', 'nfse')
        and not exists (select 1 from erp.notas_recebidas x where x.documento_id = new.id) then
    select r.id into v_nota from erp.notas_recebidas r join erp.pessoas p on p.documento = r.emitente_documento
     where p.id = new.emitente_id and r.situacao = 'nova' and r.empresa_id = new.empresa_id and r.tipo = new.tipo
       and r.numero = ltrim(new.numero, '0') and r.valor = new.valor_bruto
       and (r.tipo = 'nfse' or r.serie = ltrim(new.serie, '0'))
     order by r.emissao desc limit 1;
    if v_nota is not null then
      update erp.notas_recebidas set situacao = 'vinculada', documento_id = new.id, vinculada_em = clock_timestamp() where id = v_nota;
    end if;
  end if;
  return null;
end $$;
create trigger t_documento_nota_recebida after insert or update of situacao on erp.documentos_fiscais
  for each row execute function erp.tg_documento_nota_recebida();

-- ---------------------------------------------------------------------------------------------
-- 5. O serviço da busca (sistema)
-- ---------------------------------------------------------------------------------------------
-- Grava a nota que o serviço baixou. p_nota: tipo, chave, nsu, tomador (o CNPJ da empresa na nota), emitente_documento,
-- emitente_nome, numero, serie, emissao, competencia (opcional; sem ela, o mês da emissão), valor, municipio.
-- A nota que já existe não muda: só o XML do resumo dá lugar ao completo. Devolve o id da nota.
create function erp.registrar_nota_recebida(p_empresa uuid, p_nota jsonb, p_xml text, p_completo boolean) returns uuid
language plpgsql as $$
declare v_id uuid; v_tipo text := p_nota ->> 'tipo'; v_chave text := p_nota ->> 'chave';
        v_doc text := p_nota ->> 'emitente_documento'; v_num text := ltrim(coalesce(p_nota ->> 'numero', ''), '0');
        v_serie text := coalesce(ltrim(p_nota ->> 'serie', '0'), ''); v_x erp.notas_recebidas_xml;
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca grava a nota recebida'; end if;
  if p_xml is null or p_completo is null then raise exception 'Falta o XML da nota'; end if;
  if v_tipo = 'nfse' and not p_completo then raise exception 'A NFS-e chega sempre completa'; end if;
  if coalesce(p_nota ->> 'tomador', '') is distinct from
     (select p.documento from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id where e.id = p_empresa) then
    raise exception 'A nota não é contra o CNPJ desta empresa';
  end if;
  -- a chave de acesso traz o emitente e o número: a nota tem de bater com ela
  if v_tipo = 'nfe' and (substr(v_chave, 7, 14) <> lpad(coalesce(v_doc, ''), 14, '0')
                         or ltrim(substr(v_chave, 26, 9), '0') <> v_num or ltrim(substr(v_chave, 23, 3), '0') <> v_serie) then
    raise exception 'Emitente, número ou série não batem com a chave da NF-e';
  end if;
  if v_tipo = 'nfse' and (substr(v_chave, 10, 14) <> lpad(coalesce(v_doc, ''), 14, '0') or ltrim(substr(v_chave, 24, 13), '0') <> v_num) then
    raise exception 'Emitente ou número não batem com a chave da NFS-e';
  end if;

  select id into v_id from erp.notas_recebidas where chave = v_chave;
  if v_id is null then
    insert into erp.notas_recebidas (empresa_id, tipo, chave, nsu, emitente_documento, emitente_nome, numero, serie, emissao,
                                     competencia, valor, municipio)
    values (p_empresa, v_tipo, v_chave, (p_nota ->> 'nsu')::bigint, v_doc, nullif(trim(p_nota ->> 'emitente_nome'), ''), v_num, v_serie,
            (p_nota ->> 'emissao')::date, date_trunc('month', coalesce((p_nota ->> 'competencia')::date, (p_nota ->> 'emissao')::date))::date,
            (p_nota ->> 'valor')::numeric, nullif(p_nota ->> 'municipio', ''))
    returning id into v_id;
  elsif (select empresa_id from erp.notas_recebidas where id = v_id) <> p_empresa then
    raise exception 'A nota já está na caixa de outra empresa';
  end if;

  select * into v_x from erp.notas_recebidas_xml where nota_id = v_id;
  if v_x.nota_id is null then
    insert into erp.notas_recebidas_xml (nota_id, xml, sha256, completo)
    values (v_id, p_xml, encode(sha256(convert_to(p_xml, 'UTF8')), 'hex'), p_completo);
  elsif not v_x.completo and p_completo then
    update erp.notas_recebidas_xml set xml = p_xml, sha256 = encode(sha256(convert_to(p_xml, 'UTF8')), 'hex'), completo = true
     where nota_id = v_id;
  end if;
  perform erp._casar_nota_recebida(v_id);
  return v_id;
end $$;

-- Grava o evento da nota (o mesmo evento repetido não entra de novo). O cancelamento marca a nota, se ela já chegou;
-- se ela chegar depois, o serviço registra o evento de novo (repetido não entra) e a marca entra.
create function erp.registrar_evento_nota_recebida(p_empresa uuid, p_chave text, p_codigo text, p_cancelamento boolean,
                                                   p_nsu bigint, p_xml text) returns void
language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca grava o evento da nota'; end if;
  insert into erp.notas_recebidas_eventos (empresa_id, chave, codigo, cancelamento, nsu, xml)
  values (p_empresa, p_chave, p_codigo, coalesce(p_cancelamento, false), p_nsu, p_xml)
  on conflict (chave, codigo, nsu) do nothing;
  if p_cancelamento then
    update erp.notas_recebidas set cancelada_em = clock_timestamp()
     where chave = p_chave and empresa_id = p_empresa and cancelada_em is null;
  end if;
end $$;

-- A ciência da operação feita na SEFAZ (só NF-e).
create function erp.registrar_ciencia_nota_recebida(p_chave text) returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca registra a ciência'; end if;
  update erp.notas_recebidas set ciencia_em = clock_timestamp() where chave = p_chave and tipo = 'nfe' and ciencia_em is null;
end $$;

-- Onde a busca parou (o último NSU nunca volta).
create function erp.registrar_leitura_notas(p_empresa uuid, p_origem text, p_ultimo_nsu bigint, p_maximo_nsu bigint,
                                            p_bloqueado_ate timestamptz, p_erro text) returns void
language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o serviço da busca grava a leitura das notas'; end if;
  insert into erp.notas_recebidas_leituras as l (empresa_id, origem, ultimo_nsu, maximo_nsu, consultado_em, bloqueado_ate, erro)
  values (p_empresa, p_origem, p_ultimo_nsu, p_maximo_nsu, clock_timestamp(), p_bloqueado_ate, left(p_erro, 1000))
  on conflict (empresa_id, origem) do update
    set ultimo_nsu = excluded.ultimo_nsu, maximo_nsu = excluded.maximo_nsu, consultado_em = excluded.consultado_em,
        bloqueado_ate = excluded.bloqueado_ate, erro = excluded.erro;
end $$;

-- ---------------------------------------------------------------------------------------------
-- 6. Ignorar e voltar (financeiro e master)
-- ---------------------------------------------------------------------------------------------
create function erp.ignorar_nota_recebida(p_nota uuid, p_motivo text) returns void language plpgsql as $$
declare n erp.notas_recebidas;
begin
  if not (erp.escrevo() and (erp.sou_master() or erp.financeiro())) then
    raise exception 'Só o financeiro (AF, AO, AD) e o master ignoram nota recebida';
  end if;
  select * into n from erp.notas_recebidas where id = p_nota for update;
  if n.id is null or not erp._vejo_nota_recebida(n.empresa_id, n.tipo, n.emitente_documento, n.documento_id) then raise exception 'Nota não encontrada'; end if;
  if n.situacao <> 'nova' then raise exception 'Só a nota nova se ignora'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Diga o motivo de ignorar a nota'; end if;
  update erp.notas_recebidas set situacao = 'ignorada', ignorada_motivo = trim(p_motivo), ignorada_por = erp.autor(),
                                 ignorada_em = clock_timestamp()
   where id = p_nota;
end $$;

create function erp.voltar_nota_recebida(p_nota uuid) returns void language plpgsql as $$
declare n erp.notas_recebidas;
begin
  if not (erp.escrevo() and (erp.sou_master() or erp.financeiro())) then
    raise exception 'Só o financeiro (AF, AO, AD) e o master voltam nota ignorada';
  end if;
  select * into n from erp.notas_recebidas where id = p_nota for update;
  if n.id is null or not erp._vejo_nota_recebida(n.empresa_id, n.tipo, n.emitente_documento, n.documento_id) then raise exception 'Nota não encontrada'; end if;
  if n.situacao <> 'ignorada' then raise exception 'Só a nota ignorada volta'; end if;
  update erp.notas_recebidas set situacao = 'nova', ignorada_motivo = null, ignorada_por = null, ignorada_em = null where id = p_nota;
  perform erp._casar_nota_recebida(p_nota);
end $$;

-- ---------------------------------------------------------------------------------------------
-- 7. Liberar e tirar quem vê (o master e o AD)
-- ---------------------------------------------------------------------------------------------
create function erp._libero_notas_recebidas() returns boolean language sql stable as $$
  select erp.membro() and erp.escrevo() and (erp.sou_master() or erp.estou_nas_listas(array['AD'])) $$;

create function erp.liberar_notas_recebidas(p_pessoa uuid, p_empresa uuid, p_tipo text, p_motivo text) returns void
language plpgsql as $$
begin
  if not erp._libero_notas_recebidas() then raise exception 'Só o master e o AD liberam quem vê as notas recebidas'; end if;
  if p_tipo not in ('nfe', 'nfse') or p_tipo is null then raise exception 'Tipo de nota: nfe (material) ou nfse (serviço)'; end if;
  if length(trim(coalesce(p_motivo, ''))) < 3 then raise exception 'Diga o motivo da liberação'; end if;
  if not exists (select 1 from erp.usuarios where id = p_pessoa and ativo and not so_sucessao) then
    raise exception 'Só um usuário ativo do ERP é liberado';
  end if;
  if not exists (select 1 from erp.empresas where id = p_empresa) then raise exception 'Empresa não encontrada'; end if;
  if exists (select 1 from erp.notas_recebidas_acessos where user_id = p_pessoa and empresa_id = p_empresa and tipo = p_tipo) then
    raise exception 'Esta pessoa já vê essas notas';
  end if;
  insert into erp.notas_recebidas_acessos (user_id, empresa_id, tipo, motivo, por) values (p_pessoa, p_empresa, p_tipo, trim(p_motivo), erp.eu());
end $$;

create function erp.retirar_notas_recebidas(p_pessoa uuid, p_empresa uuid, p_tipo text) returns void language plpgsql as $$
begin
  if not erp._libero_notas_recebidas() then raise exception 'Só o master e o AD tiram quem vê as notas recebidas'; end if;
  delete from erp.notas_recebidas_acessos where user_id = p_pessoa and empresa_id = p_empresa and tipo = p_tipo;
  if not found then raise exception 'Esta pessoa não tem essa liberação'; end if;
end $$;

create function erp.tg_nota_recebida_acesso() returns trigger language plpgsql as $$
begin
  if not (erp.sistema() or erp._libero_notas_recebidas()) then raise exception 'Só o master e o AD liberam quem vê as notas recebidas'; end if;
  if tg_op = 'UPDATE' then raise exception 'A liberação não muda: tire e libere de novo'; end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger t_nota_recebida_acesso before insert or update or delete on erp.notas_recebidas_acessos
  for each row execute function erp.tg_nota_recebida_acesso();

-- ---------------------------------------------------------------------------------------------
-- 8. API
-- ---------------------------------------------------------------------------------------------
-- A caixa: as notas que a pessoa vê (pelo RLS), com a empresa pelo apelido e se o emitente já é cadastrado.
create function api.notas_recebidas(p_situacao text default null)
returns table (id uuid, empresa_id uuid, empresa text, tipo text, chave text, emitente_documento text, emitente_nome text,
               emitente_cadastrado boolean, numero text, serie text, emissao date, competencia date, valor numeric,
               municipio text, situacao text, documento_id uuid, ignorada_motivo text, cancelada boolean, ciencia boolean,
               xml_completo boolean, recebida_em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select n.id, n.empresa_id, coalesce(e.apelido, pe.nome), n.tipo, n.chave, n.emitente_documento, n.emitente_nome,
         exists (select 1 from erp.pessoas p where p.documento = n.emitente_documento), n.numero, n.serie, n.emissao,
         n.competencia, n.valor, n.municipio, n.situacao, n.documento_id, n.ignorada_motivo, n.cancelada_em is not null,
         n.ciencia_em is not null, coalesce((select x.completo from erp.notas_recebidas_xml x where x.nota_id = n.id), false),
         n.recebida_em
    from erp.notas_recebidas n
    join erp.empresas e on e.id = n.empresa_id
    join erp.pessoas pe on pe.id = e.pessoa_id
   where p_situacao is null or n.situacao = p_situacao
   order by n.emissao desc, n.recebida_em desc $$;

create function api.nota_recebida_xml(p_nota uuid) returns text
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select x.xml from erp.notas_recebidas_xml x where x.nota_id = p_nota $$;

-- A última busca de cada empresa e origem (para a tela dizer se a busca está em dia).
create function api.notas_recebidas_leituras()
returns table (empresa_id uuid, empresa text, origem text, ultimo_nsu bigint, maximo_nsu bigint, consultado_em timestamptz,
               bloqueado_ate timestamptz, erro text)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select l.empresa_id, coalesce(e.apelido, pe.nome), l.origem, l.ultimo_nsu, l.maximo_nsu, l.consultado_em, l.bloqueado_ate, l.erro
    from erp.notas_recebidas_leituras l join erp.empresas e on e.id = l.empresa_id join erp.pessoas pe on pe.id = e.pessoa_id
   order by 2, 3 $$;

create function api.buscar_nota_recebida(p_chave text, p_emitente text default null, p_numero text default null,
                                         p_valor numeric default null) returns jsonb
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$
  select erp.buscar_nota_recebida(p_chave, p_emitente, p_numero, p_valor) $$;
create function api.ignorar_nota_recebida(p_nota uuid, p_motivo text) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.ignorar_nota_recebida(p_nota, p_motivo) $$;
create function api.voltar_nota_recebida(p_nota uuid) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$ select erp.voltar_nota_recebida(p_nota) $$;
-- As liberações (o master e o AD veem todas; cada um, as suas).
create function api.notas_recebidas_acessos()
returns table (user_id uuid, usuario text, empresa_id uuid, empresa text, tipo text, motivo text, por text, em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select a.user_id, u.nome, a.empresa_id, coalesce(e.apelido, pe.nome), a.tipo, a.motivo, p.nome, a.em
    from erp.notas_recebidas_acessos a join erp.usuarios u on u.id = a.user_id join erp.usuarios p on p.id = a.por
    join erp.empresas e on e.id = a.empresa_id join erp.pessoas pe on pe.id = e.pessoa_id
   order by 2, 4, 5 $$;
create function api.liberar_notas_recebidas(p_pessoa uuid, p_empresa uuid, p_tipo text, p_motivo text) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$
  select erp.liberar_notas_recebidas(p_pessoa, p_empresa, p_tipo, p_motivo) $$;
create function api.retirar_notas_recebidas(p_pessoa uuid, p_empresa uuid, p_tipo text) returns void
language sql volatile security invoker set search_path = pg_catalog, pg_temp as $$
  select erp.retirar_notas_recebidas(p_pessoa, p_empresa, p_tipo) $$;

-- ---------------------------------------------------------------------------------------------
-- 9. Segurança
-- ---------------------------------------------------------------------------------------------
select pg_temp.tabela('notas_recebidas');
select pg_temp.tabela('notas_recebidas_xml');
select pg_temp.tabela('notas_recebidas_eventos');
select pg_temp.tabela('notas_recebidas_leituras');
select pg_temp.tabela('notas_recebidas_acessos');
select pg_temp.tabela('notas_recebidas_buscas');
-- só leitura pela API, sempre pela regra de quem vê a nota
create policy perfil_le on erp.notas_recebidas for select to authenticated
  using (erp._vejo_nota_recebida(empresa_id, tipo, emitente_documento, documento_id));
create policy perfil_le on erp.notas_recebidas_xml for select to authenticated
  using (exists (select 1 from erp.notas_recebidas n where n.id = nota_id));
create policy perfil_le on erp.notas_recebidas_eventos for select to authenticated
  using (exists (select 1 from erp.notas_recebidas n where n.chave = notas_recebidas_eventos.chave));
create policy perfil_le on erp.notas_recebidas_leituras for select to authenticated using (erp._vejo_leitura_notas(empresa_id));
create policy perfil_le on erp.notas_recebidas_acessos for select to authenticated
  using (erp.membro() and (erp.sou_master() or erp.estou_nas_listas(array['AD']) or user_id = erp.eu()));
create policy perfil_le on erp.notas_recebidas_buscas for select to authenticated
  using (erp.membro() and (erp.sou_master() or erp.estou_nas_listas(array['AD']) or user_id = erp.eu()));
grant select on erp.notas_recebidas, erp.notas_recebidas_xml, erp.notas_recebidas_eventos, erp.notas_recebidas_leituras,
  erp.notas_recebidas_acessos, erp.notas_recebidas_buscas to authenticated;
select pg_temp.auditar('notas_recebidas', 'id');
select pg_temp.auditar('notas_recebidas_leituras', 'empresa_id');
select pg_temp.auditar('notas_recebidas_acessos', 'user_id');

do $$
declare f regprocedure;
begin
  -- de dentro do banco (gatilhos, conferências internas e o serviço da busca): fora da API
  foreach f in array array['erp.tg_nota_recebida()', 'erp.tg_nota_recebida_xml()', 'erp.tg_nota_recebida_evento()',
    'erp.tg_nota_recebida_leitura()', 'erp._nota_recebida_pj(text)', 'erp._casar_nota_recebida(uuid)',
    'erp.tg_documento_nota_recebida()', 'erp.registrar_nota_recebida(uuid, jsonb, text, boolean)',
    'erp.registrar_evento_nota_recebida(uuid, text, text, boolean, bigint, text)', 'erp.registrar_ciencia_nota_recebida(text)',
    'erp.registrar_leitura_notas(uuid, text, bigint, bigint, timestamptz, text)', 'erp._vejo_nota_recebida(uuid, text, text, uuid)',
    'erp._vejo_leitura_notas(uuid)', 'erp.buscar_nota_recebida(text, text, text, numeric)', 'erp.ignorar_nota_recebida(uuid, text)',
    'erp.voltar_nota_recebida(uuid)', 'erp.liberar_notas_recebidas(uuid, uuid, text, text)',
    'erp.retirar_notas_recebidas(uuid, uuid, text)', 'erp.tg_nota_recebida_acesso()', 'erp._libero_notas_recebidas()',
    'erp.tg_nota_recebida_busca()', 'erp._lanco_na_empresa(uuid)', 'erp.limite_busca_notas()']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke execute on function %s from authenticated', f); end if;
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config', f);
  end loop;
  foreach f in array array['api.notas_recebidas(text)', 'api.nota_recebida_xml(uuid)', 'api.notas_recebidas_leituras()',
    'api.buscar_nota_recebida(text, text, text, numeric)', 'api.ignorar_nota_recebida(uuid, text)',
    'api.voltar_nota_recebida(uuid)', 'api.notas_recebidas_acessos()', 'api.liberar_notas_recebidas(uuid, uuid, text, text)',
    'api.retirar_notas_recebidas(uuid, uuid, text)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('grant execute on function %s to authenticated', f); end if;
  end loop;
end $$;
-- quem está logado: as conferências das políticas e as operações (o gatilho não precisa de EXECUTE para disparar)
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp._vejo_nota_recebida(uuid, text, text, uuid), erp._vejo_leitura_notas(uuid),
      erp.buscar_nota_recebida(text, text, text, numeric), erp.ignorar_nota_recebida(uuid, text), erp.voltar_nota_recebida(uuid),
      erp.liberar_notas_recebidas(uuid, uuid, text, text), erp.retirar_notas_recebidas(uuid, uuid, text), erp._libero_notas_recebidas(),
      erp._lanco_na_empresa(uuid), erp.limite_busca_notas() to authenticated;
  end if;
end $$;
do $$
declare f text;
begin
  foreach f in array array['erp._nota_recebida_pj(text)', 'erp._vejo_nota_recebida(uuid, text, text, uuid)', 'erp._vejo_leitura_notas(uuid)',
    'erp.buscar_nota_recebida(text, text, text, numeric)', 'erp.ignorar_nota_recebida(uuid, text)', 'erp.voltar_nota_recebida(uuid)',
    'erp._casar_nota_recebida(uuid)', 'erp.tg_documento_nota_recebida()', 'erp.liberar_notas_recebidas(uuid, uuid, text, text)',
    'erp.retirar_notas_recebidas(uuid, uuid, text)', 'erp._libero_notas_recebidas()', 'erp._lanco_na_empresa(uuid)'] loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', f);
  end loop;
end $$;
-- As conferências leem por baixo do RLS (erp_conferencia); o que liga, ignora e volta grava como erp_situacao (quem lança
-- a nota no ERP não grava na caixa, mas o lançamento dele liga a nota).
select pg_temp.dono(f::regprocedure, 'erp_conferencia') from unnest(array[
  'erp._nota_recebida_pj(text)', 'erp._vejo_nota_recebida(uuid, text, text, uuid)', 'erp._vejo_leitura_notas(uuid)',
  'erp._libero_notas_recebidas()', 'erp._lanco_na_empresa(uuid)']) f;
select pg_temp.dono(f::regprocedure, 'erp_situacao') from unnest(array[
  'erp.ignorar_nota_recebida(uuid, text)', 'erp.voltar_nota_recebida(uuid)', 'erp._casar_nota_recebida(uuid)',
  'erp.tg_documento_nota_recebida()', 'erp.buscar_nota_recebida(text, text, text, numeric)']) f;
-- liberar e tirar gravam como erp_acesso, como a designação do PJ
select pg_temp.dono(f::regprocedure, 'erp_acesso') from unnest(array[
  'erp.liberar_notas_recebidas(uuid, uuid, text, text)', 'erp.retirar_notas_recebidas(uuid, uuid, text)']) f;
