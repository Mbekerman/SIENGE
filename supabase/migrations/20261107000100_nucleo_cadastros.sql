-- Núcleo do ERP BKM: cadastros da raiz (pessoas, empresas, sócios, empreendimentos,
-- centros de custo) e a árvore de naturezas.
-- Desenho: https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt (sabatina de 7/nov/2026).
-- Fica no esquema `nucleo`, acima do espelho do Sienge (`sienge_bruto`, `sienge`).

create schema if not exists nucleo;

-- ---------------------------------------------------------------------
-- Usuários e papéis do ERP
-- ---------------------------------------------------------------------
create table nucleo.usuarios (
  user_id       uuid primary key,              -- auth.users.id
  nome          text not null,
  papel         text not null check (papel in ('diretor','gestor','analista','leitura')),
  contador      boolean not null default false, -- vota nas alçadas que pedem o contador
  administrador boolean not null default false, -- mexe na configuração (árvore, alçadas, listas)
  ativo         boolean not null default true,
  criado_em     timestamptz not null default now()
);

-- Quem está agindo. Nulo = rotina do sistema ou migration (passa nas checagens de papel).
create function nucleo.eu() returns uuid language sql stable as
  $$ select auth.uid() $$;

create function nucleo.meu_papel() returns text language sql stable as
  $$ select papel from nucleo.usuarios where user_id = nucleo.eu() and ativo $$;

create function nucleo.exigir_admin() returns void language plpgsql stable as $$
begin
  if nucleo.eu() is null then return; end if;
  if not exists (select 1 from nucleo.usuarios where user_id = nucleo.eu() and ativo and administrador) then
    raise exception 'Só o administrador pode mudar a configuração';
  end if;
end $$;

create function nucleo.exigir_editor() returns void language plpgsql stable as $$
begin
  if nucleo.eu() is null then return; end if;
  if coalesce(nucleo.meu_papel(), 'leitura') = 'leitura' then
    raise exception 'Seu papel só permite consulta';
  end if;
end $$;

create function nucleo.exigir_diretor() returns void language plpgsql stable as $$
begin
  if nucleo.eu() is null then return; end if;
  if coalesce(nucleo.meu_papel(), '') <> 'diretor' then
    raise exception 'Só a diretoria pode fazer isso';
  end if;
end $$;

-- Auditoria das tabelas de configuração e de estrutura.
create table nucleo.auditoria (
  id       bigint generated always as identity primary key,
  tabela   text not null,
  registro text not null,
  acao     text not null,
  antes    jsonb,
  depois   jsonb,
  por      uuid,
  em       timestamptz not null default clock_timestamp()
);

create function nucleo.tg_auditoria() returns trigger language plpgsql as $$
declare v_old jsonb; v_new jsonb;
begin
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  insert into nucleo.auditoria (tabela, registro, acao, antes, depois, por)
  values (tg_table_name, coalesce(v_new, v_old)->>(tg_argv[0]), lower(tg_op), v_old, v_new, nucleo.eu());
  return coalesce(new, old);
end $$;

-- Códigos de outros sistemas (Sienge, CRM, BKM Terrenos) para cada registro do núcleo.
-- Trocar de ERP é trocar as linhas desta tabela, não o modelo.
create table nucleo.codigos_externos (
  sistema     text not null,          -- 'sienge', 'crm', 'bkm_terrenos'
  tabela      text not null,          -- tabela do núcleo: 'pessoas', 'titulos'...
  registro_id uuid not null,
  codigo      text not null,          -- código lá fora
  primary key (sistema, tabela, codigo),
  unique (sistema, tabela, registro_id)
);

-- ---------------------------------------------------------------------
-- Pessoas: uma só tabela, com papéis (fornecedor, cliente, sócio...)
-- ---------------------------------------------------------------------
create table nucleo.pessoas (
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

create table nucleo.pessoa_papeis (
  pessoa_id uuid not null references nucleo.pessoas on delete cascade,
  papel     text not null check (papel in ('fornecedor','cliente','socio','corretor','funcionario','orgao_publico','banco')),
  primary key (pessoa_id, papel)
);

-- ---------------------------------------------------------------------
-- Empresas do grupo e participações (quem é sócio de quem, quanto, desde quando)
-- ---------------------------------------------------------------------
create table nucleo.empresas (
  id        uuid primary key default gen_random_uuid(),
  pessoa_id uuid not null unique references nucleo.pessoas,
  tipo      text not null check (tipo in ('holding','incorporadora','construtora','spe','outra')),
  ativa     boolean not null default true
);

create table nucleo.participacoes (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references nucleo.empresas,
  socio_id   uuid not null references nucleo.pessoas,   -- pessoa física ou empresa (do grupo ou não)
  percentual numeric(7,4) not null check (percentual > 0 and percentual <= 100),
  inicio     date not null,
  fim        date,
  check (fim is null or fim >= inicio)
);
create index on nucleo.participacoes (empresa_id);

-- O mesmo sócio não tem duas participações no mesmo período, e a soma em qualquer dia não passa de 100%.
create function nucleo.tg_participacao() returns trigger language plpgsql as $$
declare d date; v_soma numeric;
begin
  if new.socio_id = (select pessoa_id from nucleo.empresas where id = new.empresa_id) then
    raise exception 'A empresa não pode ser sócia de si mesma';
  end if;
  if exists (select 1 from nucleo.participacoes p
             where p.empresa_id = new.empresa_id and p.socio_id = new.socio_id and p.id <> new.id
               and daterange(p.inicio, p.fim, '[]') && daterange(new.inicio, new.fim, '[]')) then
    raise exception 'Este sócio já tem participação nesse período; encerre a anterior antes';
  end if;
  for d in
    select new.inicio
    union select p.inicio from nucleo.participacoes p
      where p.empresa_id = new.empresa_id and p.id <> new.id
        and p.inicio between new.inicio and coalesce(new.fim, 'infinity')
  loop
    select new.percentual + coalesce(sum(p.percentual), 0) into v_soma
    from nucleo.participacoes p
    where p.empresa_id = new.empresa_id and p.id <> new.id
      and d between p.inicio and coalesce(p.fim, 'infinity');
    if v_soma > 100 then
      raise exception 'As participações somariam % por cento em %', v_soma, d;
    end if;
  end loop;
  return new;
end $$;
create trigger t_participacao before insert or update on nucleo.participacoes
  for each row execute function nucleo.tg_participacao();
create trigger t_aud_participacao after insert or update or delete on nucleo.participacoes
  for each row execute function nucleo.tg_auditoria('id');

-- ---------------------------------------------------------------------
-- Empreendimento: sempre uma SPE (1 para 1), em tabelas separadas
-- ---------------------------------------------------------------------
create table nucleo.empreendimentos (
  id           uuid primary key default gen_random_uuid(),
  spe_id       uuid not null unique references nucleo.empresas,
  codigo       text not null unique,
  nome         text not null,
  municipio    text,
  uf           char(2),
  terreno_ref  text,                -- código do terreno no BKM Terrenos (A123)
  situacao     text not null default 'estudo'
               check (situacao in ('estudo','lancamento','obra','entregue','encerrado')),
  criado_em    timestamptz not null default now()
);

create function nucleo.tg_empreendimento() returns trigger language plpgsql as $$
begin
  if (select tipo from nucleo.empresas where id = new.spe_id) <> 'spe' then
    raise exception 'O empreendimento precisa estar numa empresa do tipo SPE';
  end if;
  return new;
end $$;
create trigger t_empreendimento before insert or update on nucleo.empreendimentos
  for each row execute function nucleo.tg_empreendimento();

-- Atributos para BI (praça, regional, linha de produto, faixa MCMV...): lista extensível
-- pelo administrador, com histórico por vigência em cada empreendimento.
create table nucleo.atributos (
  id     uuid primary key default gen_random_uuid(),
  codigo text not null unique check (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome   text not null,
  tipo   text not null check (tipo in ('lista','texto','numero')),
  ativo  boolean not null default true
);

create table nucleo.atributo_opcoes (
  id          uuid primary key default gen_random_uuid(),
  atributo_id uuid not null references nucleo.atributos on delete cascade,
  valor       text not null,
  ordem       int not null default 0,
  ativa       boolean not null default true,
  unique (atributo_id, valor)
);

create table nucleo.empreendimento_atributos (
  id                uuid primary key default gen_random_uuid(),
  empreendimento_id uuid not null references nucleo.empreendimentos on delete cascade,
  atributo_id       uuid not null references nucleo.atributos,
  opcao_id          uuid references nucleo.atributo_opcoes,
  valor             text,              -- texto ou número; na lista, copiado da opção
  inicio            date not null,
  fim               date,
  check (fim is null or fim >= inicio)
);

create function nucleo.tg_emp_atributo() returns trigger language plpgsql as $$
declare v_tipo text;
begin
  select tipo into v_tipo from nucleo.atributos where id = new.atributo_id;
  if v_tipo = 'lista' then
    if new.opcao_id is null then raise exception 'Atributo de lista precisa de uma opção da lista'; end if;
    select valor into new.valor from nucleo.atributo_opcoes where id = new.opcao_id and atributo_id = new.atributo_id;
    if new.valor is null then raise exception 'A opção não pertence a este atributo'; end if;
  elsif new.opcao_id is not null then
    raise exception 'Só atributo de lista usa opção';
  elsif v_tipo = 'numero' and new.valor !~ '^-?[0-9]+([.][0-9]+)?$' then
    raise exception 'Valor numérico inválido: %', new.valor;
  end if;
  if exists (select 1 from nucleo.empreendimento_atributos a
             where a.empreendimento_id = new.empreendimento_id and a.atributo_id = new.atributo_id and a.id <> new.id
               and daterange(a.inicio, a.fim, '[]') && daterange(new.inicio, new.fim, '[]')) then
    raise exception 'Já existe valor deste atributo nesse período; encerre o anterior antes';
  end if;
  return new;
end $$;
create trigger t_emp_atributo before insert or update on nucleo.empreendimento_atributos
  for each row execute function nucleo.tg_emp_atributo();

-- Centro de custo: o empreendimento ou uma área da empresa (Marketing, Administrativo...).
-- A área deixa de ser cadastrada como obra fingida.
create table nucleo.centros_custo (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references nucleo.empresas,
  tipo              text not null check (tipo in ('empreendimento','area')),
  empreendimento_id uuid unique references nucleo.empreendimentos,
  nome              text not null,
  ativo             boolean not null default true,
  unique (empresa_id, nome),
  check ((tipo = 'empreendimento') = (empreendimento_id is not null))
);

create function nucleo.tg_centro() returns trigger language plpgsql as $$
begin
  if new.empreendimento_id is not null
     and new.empresa_id <> (select spe_id from nucleo.empreendimentos where id = new.empreendimento_id) then
    raise exception 'O centro de custo do empreendimento fica na SPE dele';
  end if;
  return new;
end $$;
create trigger t_centro before insert or update on nucleo.centros_custo
  for each row execute function nucleo.tg_centro();

-- Dimensões de lista: departamento (quem responde) e fase (momento do projeto).
create table nucleo.departamentos (
  id    uuid primary key default gen_random_uuid(),
  nome  text not null unique,
  ativo boolean not null default true
);
create table nucleo.fases (
  id    uuid primary key default gen_random_uuid(),
  nome  text not null unique,
  ordem int not null default 0,
  ativa boolean not null default true
);

-- ---------------------------------------------------------------------
-- Árvore de naturezas (dinâmica: o administrador cria, renomeia, move e desativa)
-- ---------------------------------------------------------------------
create table nucleo.linhas_dre (
  codigo text primary key,
  nome   text not null,
  ordem  int not null
);

create table nucleo.naturezas (
  id         uuid primary key default gen_random_uuid(),
  mae_id     uuid references nucleo.naturezas,
  codigo     text unique,
  nome       text not null,
  -- características: herdadas da mãe quando não informadas; valem para tudo que for lançado no galho
  tipo       text not null check (tipo in ('operacional','nao_operacional','movimentacao')),
  linha_dre  text not null references nucleo.linhas_dre,
  linha_dfc  text not null check (linha_dfc in ('operacional','investimento','financiamento','nenhuma')),
  so_orcado  boolean not null,       -- custo de oportunidade: aparece no orçado, nunca vira pagamento
  redutora   boolean not null,
  ativa      boolean not null default true,
  ordem      int not null default 0,
  criada_em  timestamptz not null default now(),
  criada_por uuid,
  unique nulls not distinct (mae_id, nome)
);
create index on nucleo.naturezas (mae_id);

-- Naturezas que o próprio sistema usa (adiantamentos, juros pagos...): o administrador
-- pode trocar o galho, mas a chave não some.
create table nucleo.naturezas_sistema (
  chave       text primary key check (chave in ('adiantamentos','juros_multas','descontos_obtidos','entre_socios')),
  natureza_id uuid not null references nucleo.naturezas
);

create function nucleo.natureza_folha(p_id uuid) returns boolean language sql stable as
  $$ select not exists (select 1 from nucleo.naturezas where mae_id = p_id) $$;

-- A natureza (ou algum galho abaixo dela) já foi usada em algum registro?
-- As tabelas de movimento ainda não existem aqui; a função é refeita na migration delas.
create function nucleo.natureza_em_uso(p_id uuid) returns boolean language sql stable as
  $$ select false $$;

create function nucleo.tg_natureza() returns trigger language plpgsql as $$
declare m nucleo.naturezas; v_ciclo boolean;
begin
  perform nucleo.exigir_admin();
  if tg_op = 'DELETE' then
    if nucleo.natureza_em_uso(old.id) then
      raise exception 'A natureza "%" tem lançamentos: use a reclassificação para esvaziá-la antes de apagar', old.nome;
    end if;
    return old;
  end if;

  if new.mae_id is not null then
    select * into m from nucleo.naturezas where id = new.mae_id;
    -- herança das características
    new.tipo      := coalesce(new.tipo, m.tipo);
    new.linha_dre := coalesce(new.linha_dre, m.linha_dre);
    new.linha_dfc := coalesce(new.linha_dfc, m.linha_dfc);
    new.so_orcado := coalesce(new.so_orcado, m.so_orcado);
    new.redutora  := coalesce(new.redutora, m.redutora);
  end if;

  if tg_op = 'INSERT' then
    new.criada_por := nucleo.eu();
    if new.mae_id is not null and nucleo.natureza_em_uso(new.mae_id) and nucleo.natureza_folha(new.mae_id) then
      raise exception 'A natureza "%" já tem lançamentos: reclassifique-os antes de criar galhos abaixo dela (só se lança no último nível)', m.nome;
    end if;
    return new;
  end if;

  -- UPDATE
  if new.mae_id is distinct from old.mae_id then
    with recursive sub as (
      select id from nucleo.naturezas where id = new.id
      union all select n.id from nucleo.naturezas n join sub on n.mae_id = sub.id)
    select exists (select 1 from sub where id = new.mae_id) into v_ciclo;
    if v_ciclo then raise exception 'Uma natureza não pode ficar abaixo dela mesma'; end if;
    if new.mae_id is not null and nucleo.natureza_em_uso(new.mae_id) and nucleo.natureza_folha(new.mae_id) then
      raise exception 'A natureza de destino já tem lançamentos: reclassifique-os antes';
    end if;
  end if;
  -- mexer no que muda relatório do passado (lugar na árvore, tipo, DRE, fluxo) com lançamentos: só diretoria
  if (new.mae_id is distinct from old.mae_id or new.tipo <> old.tipo or new.linha_dre <> old.linha_dre
      or new.linha_dfc <> old.linha_dfc or new.so_orcado <> old.so_orcado or new.redutora <> old.redutora)
     and nucleo.natureza_em_uso(new.id) then
    perform nucleo.exigir_diretor();
  end if;
  return new;
end $$;
create trigger t_natureza before insert or update or delete on nucleo.naturezas
  for each row execute function nucleo.tg_natureza();
create trigger t_aud_natureza after insert or update or delete on nucleo.naturezas
  for each row execute function nucleo.tg_auditoria('id');

-- Caminho legível de cada natureza ("Comerciais › Marketing › Online").
create view nucleo.v_naturezas with (security_invoker = true) as
with recursive t as (
  select n.id, n.mae_id, n.nome, n.id as raiz_id, 1 as nivel, n.nome::text as caminho,
         array[n.nome] as nomes, array[n.ordem] as ordem_caminho
  from nucleo.naturezas n where n.mae_id is null
  union all
  select n.id, n.mae_id, n.nome, t.raiz_id, t.nivel + 1, t.caminho || ' › ' || n.nome,
         t.nomes || n.nome, t.ordem_caminho || n.ordem
  from nucleo.naturezas n join t on n.mae_id = t.id
)
select t.id, t.mae_id, t.raiz_id, t.nivel, t.nome, t.caminho,
       t.nomes[1] as nivel1, t.nomes[2] as nivel2, t.nomes[3] as nivel3, t.nomes[4] as nivel4,
       n.codigo, n.tipo, n.linha_dre, n.linha_dfc, n.so_orcado, n.redutora, n.ativa,
       nucleo.natureza_folha(t.id) as folha, t.ordem_caminho
from t join nucleo.naturezas n on n.id = t.id;
