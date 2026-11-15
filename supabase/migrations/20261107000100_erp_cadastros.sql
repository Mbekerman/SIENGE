-- ERP BKM: cadastros da raiz (pessoas, empresas, sócios, empreendimentos,
-- centros de custo) e a árvore de naturezas.
-- Desenho: https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt (sabatina de 7/nov/2026).
-- Fica no esquema `erp`, acima do espelho do Sienge (`sienge_bruto`, `sienge`).

create schema if not exists erp;

-- ---------------------------------------------------------------------
-- Usuários e papéis do ERP
-- ---------------------------------------------------------------------
create table erp.usuarios (
  id            uuid primary key default gen_random_uuid(), -- id nosso, não o do provedor de login
  login_id      text not null unique,          -- quem o provedor de login diz que é (o `sub` do token)
  nome          text not null,
  papel         text not null check (papel in ('diretor','gestor','analista','leitura')),
  contador      boolean not null default false, -- vota nas alçadas que pedem o contador
  administrador boolean not null default false, -- mexe na configuração (árvore, alçadas, listas)
  ativo         boolean not null default true,
  -- só para a sucessão do master (Moises, 14/11/2026: pode ser de fora da empresa, um familiar):
  -- nenhum outro acesso no ERP
  so_sucessao   boolean not null default false,
  ativado_em    timestamptz,                    -- primeira ativação (o usuário novo nasce inativo; S-086)
  criado_em     timestamptz not null default now(),
  check (not so_sucessao or (papel = 'leitura' and not administrador and not contador)),
  -- o administrador é o TI: não aprova nada, nem pelo papel (S-085)
  constraint usuarios_admin_sem_voto check (not administrador or (papel in ('analista','leitura') and not contador))
);

-- Portabilidade (regra do Moises, 14/11/2026): o ERP não chama auth.uid() nem aponta para
-- auth.users. O único ponto de contato com o provedor de login é erp.login_atual(), que lê o
-- `sub` do token que o PostgREST põe na sessão (o mesmo que o auth.uid() do Supabase lê).
-- Trocar de provedor é trocar só esta função.
create function erp.login_atual() returns text language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                  nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub') $$;

-- Quem está agindo: o usuário do ERP com esse login (security definer na migration _erp_rls,
-- para ler erp.usuarios por baixo do RLS).
create function erp.eu() returns uuid language sql stable as
  $$ select id from erp.usuarios where login_id = erp.login_atual() and ativo $$;   -- inativo não age (S-086)

-- Rotina do sistema (S-033): sem login e só em dois casos, (1) o papel nosso `erp_sistema`
-- (o servidor e o adaptador do Sienge recebem esse papel; a chave de serviço do Supabase
-- não é sistema), ou (2) a sessão do dono do esquema sem SET ROLE (migration e cron).
-- Qualquer outro papel sem login, de qualquer provedor, não é sistema. Não se usa
-- current_user, que dentro de função security definer é o dono; o `role` da sessão não muda
-- dentro dela.
create function erp.sistema() returns boolean language sql stable as $$
  select erp.login_atual() is null
     and (current_setting('role', true) = 'erp_sistema'
          or (coalesce(nullif(current_setting('role', true), ''), 'none') = 'none'
              and session_user::text = (select r.rolname::text from pg_namespace n join pg_roles r on r.oid = n.nspowner
                                         where n.nspname = 'erp'))) $$;

-- O próprio cadastro de quem está agindo (security definer na migration _erp_rls).
-- Quem grava (S-087): fora do sistema, só quem tem cadastro ativo no ERP. Os gatilhos que põem o
-- autor (criado_por, por, pedida_por, aprovado_por...) usam esta, e não erp.eu(), para nunca
-- gravar uma linha sem autor, o que pularia "quem lançou não aprova".
create function erp.autor() returns uuid language plpgsql stable as $$
declare v uuid := erp.eu();
begin
  if v is null and not erp.sistema() then
    raise exception 'Só quem tem cadastro ativo no ERP grava';
  end if;
  return v;
end $$;

create function erp.meu_usuario() returns erp.usuarios language sql stable as
  $$ select * from erp.usuarios where id = erp.eu() and ativo $$;

create function erp.meu_papel() returns text language sql stable as
  $$ select papel from erp.usuarios where id = erp.eu() and ativo $$;

-- Marca de função do banco (S-035): o código roda dentro de uma função security definer cujo
-- dono é o papel dado (erp_situacao, erp_reclassificacao). Esses papéis não entram e não têm
-- membros, então só o banco põe a marca; não há variável de sessão que o cliente possa setar.
-- Invoker de propósito: dentro de uma definer, current_user é o dono dela.
create function erp.agindo_como(p_papel text) returns boolean language sql stable as
  $$ select current_user::text = p_papel $$;

-- Invoker (lê o cadastro pelo erp.meu_usuario, que é definer) para enxergar a marca de quem chama.
create function erp.exigir_admin() returns void language plpgsql stable as $$
begin
  if erp.sistema() then return; end if;
  -- o master faz qualquer coisa (Moises, 14/11/2026); erp.master entra na migration _erp_perfis
  if not coalesce((erp.meu_usuario()).administrador, false) and not erp.sou_master() then
    raise exception 'Só o administrador pode mudar a configuração';
  end if;
end $$;

create function erp.exigir_editor() returns void language plpgsql stable as $$
begin
  if erp.sistema() then return; end if;
  if coalesce(erp.meu_papel(), 'leitura') = 'leitura' then
    raise exception 'Seu papel só permite consulta';
  end if;
end $$;

create function erp.exigir_diretor() returns void language plpgsql stable as $$
begin
  if erp.sistema() then return; end if;
  if coalesce(erp.meu_papel(), '') <> 'diretor' then
    raise exception 'Só a diretoria pode fazer isso';
  end if;
end $$;

-- Auditoria das tabelas de configuração e de estrutura.
create table erp.auditoria (
  id       bigint generated always as identity primary key,
  tabela   text not null,
  registro text not null,
  acao     text not null,
  antes    jsonb,
  depois   jsonb,
  por      uuid,
  em       timestamptz not null default clock_timestamp()
);

-- A auditoria só cresce, e só pelo erp.tg_auditoria (definer erp_auditoria, migration
-- _erp_rls); ninguém altera nem apaga, nem o sistema (S-052). Quem e quando, o banco põe.
create function erp.tg_auditoria_guarda() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'A auditoria não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_auditoria') then raise exception 'A auditoria só é escrita pelo sistema'; end if;
  new.por := erp.eu();
  new.em := clock_timestamp();
  return new;
end $$;

create function erp.tg_auditoria() returns trigger language plpgsql as $$
declare v_old jsonb; v_new jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  insert into erp.auditoria (tabela, registro, acao, antes, depois, por)
  values (tg_table_name, coalesce(v_new, v_old)->>(tg_argv[0]), lower(tg_op), v_old, v_new, erp.eu());
  return coalesce(new, old);
end $$;
-- o gatilho erp.tg_auditoria_guarda entra na migration _erp_rls, depois que o tg_auditoria vira definer

-- Códigos de outros sistemas (Sienge, CRM, BKM Terrenos) para cada registro do ERP.
-- Trocar de ERP é trocar as linhas desta tabela, não o modelo.
create table erp.codigos_externos (
  sistema     text not null,          -- 'sienge', 'crm', 'bkm_terrenos'
  tabela      text not null,          -- tabela do ERP: 'pessoas', 'titulos'...
  registro_id uuid not null,
  codigo      text not null,          -- código lá fora
  primary key (sistema, tabela, codigo),
  unique (sistema, tabela, registro_id)
);

-- ---------------------------------------------------------------------
-- Pessoas: uma só tabela, com papéis (fornecedor, cliente, sócio...)
-- ---------------------------------------------------------------------
create table erp.pessoas (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null check (tipo in ('fisica','juridica')),
  nome          text not null,
  nome_fantasia text,
  documento     text unique,           -- CPF ou CNPJ, só dígitos
  email         text,
  telefone      text,
  ativa         boolean not null default true,
  criada_em     timestamptz not null default now(),
  check (documento is null or (documento ~ '^[0-9]+$' and length(documento) = case tipo when 'fisica' then 11 else 14 end))
);

create table erp.pessoa_papeis (
  pessoa_id uuid not null references erp.pessoas on delete cascade,
  papel     text not null check (papel in ('fornecedor','cliente','socio','corretor','funcionario','orgao_publico','banco')),
  primary key (pessoa_id, papel)
);

-- ---------------------------------------------------------------------
-- Empresas do grupo e participações (quem é sócio de quem, quanto, desde quando)
-- ---------------------------------------------------------------------
create table erp.empresas (
  id        uuid primary key default gen_random_uuid(),
  pessoa_id uuid not null unique references erp.pessoas,
  tipo      text not null check (tipo in ('holding','incorporadora','construtora','spe','outra')),
  ativa     boolean not null default true
);

create table erp.participacoes (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references erp.empresas,
  socio_id   uuid not null references erp.pessoas,   -- pessoa física ou empresa (do grupo ou não)
  percentual numeric(7,4) not null check (percentual > 0 and percentual <= 100),
  inicio     date not null,
  fim        date,
  check (fim is null or fim >= inicio)
);
create index on erp.participacoes (empresa_id);

-- O mesmo sócio não tem duas participações no mesmo período, e a soma em qualquer dia não passa de 100%.
create function erp.tg_participacao() returns trigger language plpgsql as $$
declare d date; v_soma numeric;
begin
  if new.socio_id = (select pessoa_id from erp.empresas where id = new.empresa_id) then
    raise exception 'A empresa não pode ser sócia de si mesma';
  end if;
  if exists (select 1 from erp.participacoes p
             where p.empresa_id = new.empresa_id and p.socio_id = new.socio_id and p.id <> new.id
               and daterange(p.inicio, p.fim, '[]') && daterange(new.inicio, new.fim, '[]')) then
    raise exception 'Este sócio já tem participação nesse período; encerre a anterior antes';
  end if;
  for d in
    select new.inicio
    union select p.inicio from erp.participacoes p
      where p.empresa_id = new.empresa_id and p.id <> new.id
        and p.inicio between new.inicio and coalesce(new.fim, 'infinity')
  loop
    select new.percentual + coalesce(sum(p.percentual), 0) into v_soma
    from erp.participacoes p
    where p.empresa_id = new.empresa_id and p.id <> new.id
      and d between p.inicio and coalesce(p.fim, 'infinity');
    if v_soma > 100 then
      raise exception 'As participações somariam % por cento em %', v_soma, d;
    end if;
  end loop;
  return new;
end $$;
create trigger t_participacao before insert or update on erp.participacoes
  for each row execute function erp.tg_participacao();
create trigger t_aud_participacao after insert or update or delete on erp.participacoes
  for each row execute function erp.tg_auditoria('id');

-- ---------------------------------------------------------------------
-- Empreendimento: sempre uma SPE (1 para 1), em tabelas separadas
-- ---------------------------------------------------------------------
create table erp.empreendimentos (
  id           uuid primary key default gen_random_uuid(),
  spe_id       uuid not null unique references erp.empresas,
  codigo       text not null unique,
  nome         text not null,
  municipio    text,
  uf           char(2),
  terreno_ref  text,                -- código do terreno no BKM Terrenos (A123)
  situacao     text not null default 'estudo'
               check (situacao in ('estudo','lancamento','obra','entregue','encerrado')),
  criado_em    timestamptz not null default now()
);

create function erp.tg_empreendimento() returns trigger language plpgsql as $$
begin
  if (select tipo from erp.empresas where id = new.spe_id) <> 'spe' then
    raise exception 'O empreendimento precisa estar numa empresa do tipo SPE';
  end if;
  return new;
end $$;
create trigger t_empreendimento before insert or update on erp.empreendimentos
  for each row execute function erp.tg_empreendimento();

-- Atributos para BI (praça, regional, linha de produto, faixa MCMV...): lista extensível
-- pelo administrador, com histórico por vigência em cada empreendimento.
create table erp.atributos (
  id     uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome   text not null,
  tipo   text not null check (tipo in ('lista','texto','numero')),
  ativo  boolean not null default true
);

create table erp.atributo_opcoes (
  id          uuid primary key default gen_random_uuid(),
  atributo_id uuid not null references erp.atributos on delete cascade,
  valor       text not null,
  ordem       int not null default 0,
  ativa       boolean not null default true,
  unique (atributo_id, valor)
);

create table erp.empreendimento_atributos (
  id                uuid primary key default gen_random_uuid(),
  empreendimento_id uuid not null references erp.empreendimentos on delete cascade,
  atributo_id       uuid not null references erp.atributos,
  opcao_id          uuid references erp.atributo_opcoes,
  valor             text,              -- texto ou número; na lista, copiado da opção
  inicio            date not null,
  fim               date,
  check (fim is null or fim >= inicio)
);

create function erp.tg_emp_atributo() returns trigger language plpgsql as $$
declare v_tipo text;
begin
  select tipo into v_tipo from erp.atributos where id = new.atributo_id;
  if v_tipo = 'lista' then
    if new.opcao_id is null then raise exception 'Atributo de lista precisa de uma opção da lista'; end if;
    select valor into new.valor from erp.atributo_opcoes where id = new.opcao_id and atributo_id = new.atributo_id;
    if new.valor is null then raise exception 'A opção não pertence a este atributo'; end if;
  elsif new.opcao_id is not null then
    raise exception 'Só atributo de lista usa opção';
  elsif v_tipo = 'numero' and new.valor !~ '^-?[0-9]+([.][0-9]+)?$' then
    raise exception 'Valor numérico inválido: %', new.valor;
  end if;
  if exists (select 1 from erp.empreendimento_atributos a
             where a.empreendimento_id = new.empreendimento_id and a.atributo_id = new.atributo_id and a.id <> new.id
               and daterange(a.inicio, a.fim, '[]') && daterange(new.inicio, new.fim, '[]')) then
    raise exception 'Já existe valor deste atributo nesse período; encerre o anterior antes';
  end if;
  return new;
end $$;
create trigger t_emp_atributo before insert or update on erp.empreendimento_atributos
  for each row execute function erp.tg_emp_atributo();

-- Núcleo econômico (decisão do Moises, 14/11/2026): a SPE ou obra, o Corporativo, uma loja.
-- É onde a despesa mora; os centros de custo (Marketing, Obra...) ficam dentro dele.
-- Tipos de núcleo (Moises, 14/11/2026): lista editável pelo administrador, com auditoria.
-- O tipo que exige empreendimento liga o núcleo a um empreendimento (a SPE ou obra).
create table erp.tipos_nucleo (
  codigo               text primary key check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome                 text not null unique check (length(trim(nome)) > 0),
  exige_empreendimento boolean not null default false,
  ativo                boolean not null default true
);
insert into erp.tipos_nucleo (codigo, nome, exige_empreendimento) values
  ('empreendimento', 'Empreendimento (SPE ou obra)', true),
  ('corporativo', 'Corporativo', false),
  ('loja', 'Loja', false),
  ('outro', 'Outro', false);
create function erp.tg_tipos_nucleo() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_acesso') then perform erp.exigir_admin(); end if;  -- pedido de acesso aprovado
  if tg_op in ('DELETE', 'TRUNCATE') then raise exception 'Não se apaga o tipo de núcleo; desative'; end if;
  if tg_op = 'UPDATE' and new.codigo <> old.codigo then raise exception 'O código do tipo de núcleo não muda'; end if;
  if tg_op = 'UPDATE' and new.exige_empreendimento <> old.exige_empreendimento
     and exists (select 1 from erp.nucleos_economicos where tipo = old.codigo) then
    raise exception 'O tipo já tem núcleos; a exigência de empreendimento não muda';
  end if;
  return new;
end $$;
create trigger t_tipos_nucleo before insert or update or delete on erp.tipos_nucleo
  for each row execute function erp.tg_tipos_nucleo();
create trigger t_tipos_nucleo_truncate before truncate on erp.tipos_nucleo
  for each statement execute function erp.tg_tipos_nucleo();
create trigger t_aud_tipos_nucleo after insert or update or delete on erp.tipos_nucleo
  for each row execute function erp.tg_auditoria('codigo');

create table erp.nucleos_economicos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references erp.empresas,
  tipo              text not null references erp.tipos_nucleo,
  empreendimento_id uuid unique references erp.empreendimentos,
  nome              text not null,
  ativo             boolean not null default true,
  criado_em         timestamptz not null default now(),   -- o escopo "futuros dos tipos" compara com ele
  unique (empresa_id, nome)
);

create function erp.tg_nucleo_economico() returns trigger language plpgsql as $$
declare t erp.tipos_nucleo;
begin
  select * into t from erp.tipos_nucleo where codigo = new.tipo;
  if tg_op = 'INSERT' and not t.ativo then raise exception 'O tipo de núcleo está desativado'; end if;
  if tg_op = 'INSERT' and not erp.sistema() then new.criado_em := now(); end if;   -- ninguém escolhe a data de criação
  if tg_op = 'UPDATE' and new.criado_em <> old.criado_em then raise exception 'A data de criação do núcleo não muda'; end if;
  if t.exige_empreendimento and new.empreendimento_id is null then
    raise exception 'O núcleo deste tipo precisa de um empreendimento';
  elsif not t.exige_empreendimento and new.empreendimento_id is not null then
    raise exception 'Só o núcleo de tipo com empreendimento aponta para um empreendimento';
  end if;
  if new.empreendimento_id is not null
     and new.empresa_id <> (select spe_id from erp.empreendimentos where id = new.empreendimento_id) then
    raise exception 'O núcleo econômico do empreendimento fica na SPE dele';
  end if;
  return new;
end $$;
create trigger t_nucleo_economico before insert or update on erp.nucleos_economicos
  for each row execute function erp.tg_nucleo_economico();

-- Centro de custo: a área de apropriação (Marketing, Terreno, Incorporação, Obra,
-- Assistência técnica, Administrativo...). Lista raiz única, igual para todos os núcleos.
create table erp.centros_custo (
  id    uuid primary key default gen_random_uuid(),
  nome  text not null unique,
  ativo boolean not null default true
);

-- Divisão: a subdivisão de um centro de custo (Marketing > PDV, Online, Offline, Eventos;
-- Moises, 15/11/2026). Opcional: centro sem divisão ativa segue como antes. Com divisão ativa,
-- toda linha de rateio, previsão e orçamento daquele centro diz a divisão. O acesso e a alçada
-- podem descer até ela. Só o administrador cria e muda, com auditoria; não se apaga, desativa.
create table erp.divisoes (
  id              uuid primary key default gen_random_uuid(),
  centro_custo_id uuid not null references erp.centros_custo,
  nome            text not null check (length(trim(nome)) > 0),
  ativa           boolean not null default true,
  criado_em       timestamptz not null default clock_timestamp(),   -- "futura" = criada depois do escopo
  unique (centro_custo_id, nome),
  unique (id, centro_custo_id)
);
create function erp.tg_divisao() returns trigger language plpgsql as $$
begin
  perform erp.exigir_admin();
  if tg_op in ('DELETE', 'TRUNCATE') then raise exception 'Divisão não se apaga; desative'; end if;
  if tg_op = 'INSERT' then new.criado_em := clock_timestamp();
  elsif new.centro_custo_id <> old.centro_custo_id or new.criado_em <> old.criado_em then
    raise exception 'A divisão não muda de centro de custo nem de data de criação';
  end if;
  return new;
end $$;
create trigger t_divisao before insert or update or delete on erp.divisoes
  for each row execute function erp.tg_divisao();
create trigger t_divisao_truncate before truncate on erp.divisoes
  for each statement execute function erp.tg_divisao();
create trigger t_aud_divisoes after insert or update or delete on erp.divisoes
  for each row execute function erp.tg_auditoria('id');

-- Quais centros de custo estão ligados em cada núcleo (o Corporativo não tem Obra; uma loja
-- não tem Incorporação). Sem linha = desligado. Ligar e desligar é configuração, com auditoria;
-- desligar não apaga o histórico, só impede lançamentos novos.
create table erp.nucleo_centros (
  nucleo_economico_id uuid not null references erp.nucleos_economicos,
  centro_custo_id     uuid not null references erp.centros_custo,
  ligado              boolean not null default true,
  primary key (nucleo_economico_id, centro_custo_id)
);
create function erp.tg_nucleo_centros() returns trigger language plpgsql as $$
begin
  perform erp.exigir_admin();
  if tg_op in ('DELETE', 'TRUNCATE') then raise exception 'Não se apaga o vínculo; desligue o centro de custo no núcleo'; end if;
  if tg_op = 'UPDATE' and (new.nucleo_economico_id <> old.nucleo_economico_id or new.centro_custo_id <> old.centro_custo_id) then
    raise exception 'O vínculo não muda de núcleo nem de centro; desligue este e ligue outro';
  end if;
  return new;
end $$;
create trigger t_nucleo_centros before insert or update or delete on erp.nucleo_centros
  for each row execute function erp.tg_nucleo_centros();
create trigger t_nucleo_centros_truncate before truncate on erp.nucleo_centros
  for each statement execute function erp.tg_nucleo_centros();
create trigger t_aud_nucleo_centros after insert or update or delete on erp.nucleo_centros
  for each row execute function erp.tg_auditoria('nucleo_economico_id');

create function erp.centro_ligado(p_nucleo uuid, p_centro uuid) returns boolean
language sql stable as $$
  select exists (select 1 from erp.nucleo_centros nc join erp.centros_custo c on c.id = nc.centro_custo_id
                 where nc.nucleo_economico_id = p_nucleo and nc.centro_custo_id = p_centro
                   and nc.ligado and c.ativo)
$$;

-- Fase do empreendimento (o momento do projeto; antes chamada fase): coluna de relatório, não entra no acesso nem na aprovação.
create table erp.etapas (
  id    uuid primary key default gen_random_uuid(),
  nome  text not null unique,
  ordem int not null default 0,
  ativa boolean not null default true
);

-- ---------------------------------------------------------------------
-- Árvore de naturezas (dinâmica: o administrador cria, renomeia, move e desativa)
-- ---------------------------------------------------------------------
create table erp.linhas_dre (
  codigo text primary key,
  nome   text not null,
  ordem  int not null
);

create table erp.naturezas (
  id         uuid primary key default gen_random_uuid(),
  mae_id     uuid references erp.naturezas,
  codigo     text unique,
  nome       text not null,
  -- características: herdadas da mãe quando não informadas; valem para tudo que for lançado no galho
  tipo       text not null check (tipo in ('operacional','nao_operacional','movimentacao')),
  linha_dre  text not null references erp.linhas_dre,
  linha_dfc  text not null check (linha_dfc in ('operacional','investimento','financiamento','nenhuma')),
  so_orcado  boolean not null,       -- custo de oportunidade: aparece no orçado, nunca vira pagamento
  redutora   boolean not null,
  -- restrita (pró-labore, folha PJ...): fechada a todos, mesmo dentro do centro, até liberação
  -- no perfil ou na exceção da pessoa; vale para o galho inteiro
  restrita   boolean not null default false,
  ativa      boolean not null default true,
  ordem      int not null default 0,
  criada_em  timestamptz not null default now(),
  criada_por uuid,
  unique nulls not distinct (mae_id, nome)
);
create index on erp.naturezas (mae_id);

-- Naturezas que o próprio sistema usa (adiantamentos, juros pagos...): o administrador
-- pode trocar o galho, mas a chave não some.
create table erp.naturezas_sistema (
  chave       text primary key check (chave in ('adiantamentos','juros_multas','descontos_obtidos','entre_socios')),
  natureza_id uuid not null references erp.naturezas
);

create function erp.natureza_folha(p_id uuid) returns boolean language sql stable as
  $$ select not exists (select 1 from erp.naturezas where mae_id = p_id) $$;

-- A natureza (ou algum galho abaixo dela) já foi usada em algum registro?
-- As tabelas de movimento ainda não existem aqui; a função é refeita na migration delas.
create function erp.natureza_em_uso(p_id uuid) returns boolean language sql stable as
  $$ select false $$;

create function erp.tg_natureza() returns trigger language plpgsql as $$
declare m erp.naturezas; v_ciclo boolean;
begin
  if not erp.agindo_como('erp_acesso') then perform erp.exigir_admin(); end if;  -- pedido de acesso aprovado
  if tg_op = 'DELETE' then
    if erp.natureza_em_uso(old.id) then
      raise exception 'A natureza "%" tem lançamentos: use a reclassificação para esvaziá-la antes de apagar', old.nome;
    end if;
    return old;
  end if;

  if new.mae_id is not null then
    select * into m from erp.naturezas where id = new.mae_id;
    -- herança das características
    new.tipo      := coalesce(new.tipo, m.tipo);
    new.linha_dre := coalesce(new.linha_dre, m.linha_dre);
    new.linha_dfc := coalesce(new.linha_dfc, m.linha_dfc);
    new.so_orcado := coalesce(new.so_orcado, m.so_orcado);
    new.redutora  := coalesce(new.redutora, m.redutora);
  end if;

  if tg_op = 'INSERT' then
    new.criada_por := erp.autor();
    if new.mae_id is not null and erp.natureza_em_uso(new.mae_id) and erp.natureza_folha(new.mae_id) then
      raise exception 'A natureza "%" já tem lançamentos: reclassifique-os antes de criar galhos abaixo dela (só se lança no último nível)', m.nome;
    end if;
    return new;
  end if;

  -- UPDATE
  if new.mae_id is distinct from old.mae_id then
    with recursive sub as (
      select id from erp.naturezas where id = new.id
      union all select n.id from erp.naturezas n join sub on n.mae_id = sub.id)
    select exists (select 1 from sub where id = new.mae_id) into v_ciclo;
    if v_ciclo then raise exception 'Uma natureza não pode ficar abaixo dela mesma'; end if;
    if new.mae_id is not null and erp.natureza_em_uso(new.mae_id) and erp.natureza_folha(new.mae_id) then
      raise exception 'A natureza de destino já tem lançamentos: reclassifique-os antes';
    end if;
  end if;
  -- mexer no que muda relatório do passado (lugar na árvore, tipo, DRE, fluxo) com lançamentos: só diretoria
  if (new.mae_id is distinct from old.mae_id or new.tipo <> old.tipo or new.linha_dre <> old.linha_dre
      or new.linha_dfc <> old.linha_dfc or new.so_orcado <> old.so_orcado or new.redutora <> old.redutora)
     and erp.natureza_em_uso(new.id) then
    perform erp.exigir_diretor();
  end if;
  return new;
end $$;
create trigger t_natureza before insert or update or delete on erp.naturezas
  for each row execute function erp.tg_natureza();
create trigger t_aud_natureza after insert or update or delete on erp.naturezas
  for each row execute function erp.tg_auditoria('id');

-- Caminho legível de cada natureza ("Comerciais › Marketing › Online").
create view erp.v_naturezas with (security_invoker = true) as
with recursive t as (
  select n.id, n.mae_id, n.nome, n.id as raiz_id, 1 as nivel, n.nome::text as caminho,
         array[n.nome] as nomes, array[n.ordem] as ordem_caminho
  from erp.naturezas n where n.mae_id is null
  union all
  select n.id, n.mae_id, n.nome, t.raiz_id, t.nivel + 1, t.caminho || ' › ' || n.nome,
         t.nomes || n.nome, t.ordem_caminho || n.ordem
  from erp.naturezas n join t on n.mae_id = t.id
)
select t.id, t.mae_id, t.raiz_id, t.nivel, t.nome, t.caminho,
       t.nomes[1] as nivel1, t.nomes[2] as nivel2, t.nomes[3] as nivel3, t.nomes[4] as nivel4,
       n.codigo, n.tipo, n.linha_dre, n.linha_dfc, n.so_orcado, n.redutora, n.ativa,
       erp.natureza_folha(t.id) as folha, t.ordem_caminho
from t join erp.naturezas n on n.id = t.id;
