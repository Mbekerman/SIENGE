-- ERP BKM: do compromisso ao pagamento, e o livro de lançamentos.
-- compromisso → previsão → documento fiscal → título → parcela; pagamento ↔ quitação.
-- Cada estágio escreve no livro (erp.lancamentos); o livro só recebe linhas novas
-- (estorno é linha de sinal contrário) e só muda a natureza, pela reclassificação.
-- Sinal no livro: entrada positiva, saída negativa. Nas tabelas de origem, valores positivos.

-- ---------------------------------------------------------------------
-- Classificação comum (núcleo econômico, centro de custo, divisão, natureza) e o rateio
-- ---------------------------------------------------------------------
-- Natureza usada em movimento: precisa ser do último nível e ativa.
create function erp.checar_natureza(p_natureza uuid, p_nucleo uuid, p_centro uuid, p_orcado boolean default false)
returns void language plpgsql stable as $$
declare n erp.naturezas;
begin
  select * into n from erp.naturezas where id = p_natureza;
  if not found then raise exception 'Natureza inexistente'; end if;
  if not erp.natureza_folha(p_natureza) then
    raise exception 'Só se lança no último nível da árvore; "%" tem galhos abaixo', n.nome;
  end if;
  if not n.ativa then raise exception 'A natureza "%" está desativada', n.nome; end if;
  if n.so_orcado and not p_orcado then
    raise exception 'A natureza "%" é só do orçado e não recebe previsão, título ou pagamento', n.nome;
  end if;
  if p_nucleo is null and n.tipo <> 'movimentacao' then
    raise exception 'Falta o núcleo econômico (só movimentações dispensam)';
  end if;
  if p_centro is null and n.tipo <> 'movimentacao' then
    raise exception 'Falta o centro de custo (só movimentações dispensam)';
  end if;
end $$;

-- O centro de custo precisa estar ligado no núcleo econômico (erp.nucleo_centros), e o núcleo
-- é da empresa do registro (S-056).
create function erp.checar_centro(p_nucleo uuid, p_centro uuid, p_empresa uuid)
returns void language plpgsql stable as $$
begin
  if p_nucleo is not null
     and (select empresa_id from erp.nucleos_economicos where id = p_nucleo) is distinct from p_empresa then
    raise exception 'O núcleo econômico é de outra empresa';
  end if;
  if p_centro is not null and p_nucleo is null then
    raise exception 'Centro de custo só vale dentro de um núcleo econômico';
  end if;
  if p_centro is not null and not erp.centro_ligado(p_nucleo, p_centro) then
    raise exception 'Este centro de custo não está ligado neste núcleo econômico';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Bancos
-- ---------------------------------------------------------------------
create table erp.contas_bancarias (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references erp.empresas,
  banco      text not null,
  agencia    text,
  conta      text,
  descricao  text,
  ativa      boolean not null default true
);

create table erp.lotes_bancarios (           -- só agrupamento de envio ao banco
  id         uuid primary key default gen_random_uuid(),
  conta_id   uuid not null references erp.contas_bancarias,
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz,
  situacao   text not null default 'aberto' check (situacao in ('aberto','enviado','retornado','cancelado'))
);

-- ---------------------------------------------------------------------
-- Compromisso: o acordo que gera gasto
-- ---------------------------------------------------------------------
create table erp.compromissos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references erp.empresas,
  tipo              text not null check (tipo in ('contrato','pedido','assinatura','avulsa','guia','folha')),
  pessoa_id         uuid references erp.pessoas,      -- fornecedor
  numero            text,
  descricao         text not null,
  inicio            date not null,
  fim               date,
  valor_total       numeric(15,2) check (valor_total > 0),
  periodicidade     text check (periodicidade in ('mensal','bimestral','trimestral','semestral','anual')),
  valor_periodo     numeric(15,2) check (valor_periodo > 0),
  dia_vencimento    int check (dia_vencimento between 1 and 31),
  caucao_percentual numeric(5,2) not null default 0 check (caucao_percentual between 0 and 100),
  situacao          text not null default 'ativo' check (situacao in ('ativo','encerrado','cancelado')),
  criado_por        uuid,                       -- quem lançou (erp.tg_autor); a RLS do lançador restrito usa
  criado_em         timestamptz not null default now(),
  check (fim is null or fim >= inicio),
  -- a assinatura recorrente substitui o contrato fictício: tem periodicidade e valor por período
  check (tipo <> 'assinatura' or (periodicidade is not null and valor_periodo is not null))
);

create table erp.compromisso_rateios (
  id              uuid primary key default gen_random_uuid(),
  compromisso_id  uuid not null references erp.compromissos on delete cascade,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  divisao_id      uuid,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100),
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);

-- ---------------------------------------------------------------------
-- Orçamento: versões datadas, nunca sobrescritas
-- ---------------------------------------------------------------------
create table erp.orcamento_versoes (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references erp.empresas,
  empreendimento_id uuid references erp.empreendimentos,
  tipo              text not null check (tipo in ('viabilidade','aprovado','reprojecao')),
  nome              text not null,
  data_base         date not null,
  situacao          text not null default 'rascunho' check (situacao in ('rascunho','vigente','substituida')),
  criada_em         timestamptz not null default now(),
  criada_por        uuid default erp.eu()
);

create table erp.orcamento_linhas (
  id              uuid primary key default gen_random_uuid(),
  versao_id       uuid not null references erp.orcamento_versoes on delete cascade,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  divisao_id      uuid,
  competencia     date not null check (extract(day from competencia) = 1),
  data_caixa      date,
  valor           numeric(15,2) not null check (valor <> 0),  -- com sinal: receita +, gasto −
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);

-- ---------------------------------------------------------------------
-- Previsão: gasto esperado que ainda não é dívida (substitui o título de previsão)
-- ---------------------------------------------------------------------
create table erp.previsoes (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references erp.empresas,
  sentido         text not null default 'pagar' check (sentido in ('pagar','receber')),
  origem          text not null check (origem in ('orcamento','assinatura','saldo_contrato','cronograma','manual')),
  compromisso_id  uuid references erp.compromissos,
  pessoa_id       uuid references erp.pessoas,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  divisao_id      uuid,
  competencia     date not null check (extract(day from competencia) = 1),
  data_prevista   date not null,
  valor           numeric(15,2) not null check (valor > 0),
  descricao       text,
  situacao        text not null default 'aberta' check (situacao in ('aberta','consumida','cancelada')),
  criada_por      uuid,                         -- quem lançou; vazio quando o sistema gera
  criada_em       timestamptz not null default now(),
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);
create index on erp.previsoes (compromisso_id) where situacao = 'aberta';

-- ---------------------------------------------------------------------
-- Documento fiscal: a nota, o boleto ou a guia que chegou
-- ---------------------------------------------------------------------
create table erp.documentos_fiscais (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references erp.empresas,
  emitente_id    uuid not null references erp.pessoas,
  compromisso_id uuid references erp.compromissos,
  tipo           text not null check (tipo in ('nfse','nfe','fatura','boleto','guia','recibo','outro')),
  numero         text not null,
  serie          text not null default '',
  emissao        date not null,
  competencia    date not null check (extract(day from competencia) = 1),
  valor_bruto    numeric(15,2) not null check (valor_bruto > 0),
  caucao_valor   numeric(15,2) check (caucao_valor >= 0),  -- vem do contrato; pode ser alterada aqui
  situacao       text not null default 'rascunho' check (situacao in ('rascunho','lancado','cancelado')),
  cancelamento   text check (cancelamento in ('recusa')),   -- cancelada porque a alçada recusou o título
  lancado_em     timestamptz,
  criado_por     uuid,
  criado_em      timestamptz not null default now()
);
-- Trava de duplicidade que o Sienge não tem (lá a NFS-e aceita número repetido).
-- A nota cancelada (inclusive a recusada na alçada) libera o número para a versão certa.
create unique index documentos_fiscais_unico on erp.documentos_fiscais (emitente_id, tipo, numero, serie)
  where situacao <> 'cancelado';

create table erp.documento_retencoes (
  documento_id uuid not null references erp.documentos_fiscais on delete cascade,
  imposto      text not null check (imposto in ('iss','inss','irrf','pis','cofins','csll','pcc','outro')),
  valor        numeric(15,2) not null check (valor > 0),
  orgao_id     uuid not null references erp.pessoas,   -- quem recebe a guia (prefeitura, Receita...)
  vencimento   date not null,
  primary key (documento_id, imposto)
);

create table erp.documento_rateios (
  id              uuid primary key default gen_random_uuid(),
  documento_id    uuid not null references erp.documentos_fiscais on delete cascade,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  divisao_id      uuid,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100),
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);

-- ---------------------------------------------------------------------
-- Título: a dívida real (ou o direito a receber), com N parcelas
-- ---------------------------------------------------------------------
create table erp.titulos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references erp.empresas,
  sentido        text not null default 'pagar' check (sentido in ('pagar','receber')),
  -- adiantamento: o pedido que passa pela alçada antes de o dinheiro sair (S-061)
  tipo           text not null check (tipo in ('fornecedor','imposto','caucao','societario','avulso','adiantamento')),
  pessoa_id      uuid not null references erp.pessoas,
  documento_id   uuid references erp.documentos_fiscais,
  compromisso_id uuid references erp.compromissos,
  numero         text,
  emissao        date not null,
  competencia    date not null check (extract(day from competencia) = 1),
  valor          numeric(15,2) not null check (valor > 0),
  descricao      text,
  situacao       text not null default 'rascunho' check (situacao in ('rascunho','aberto','quitado','cancelado')),
  -- cancelado pela alçada: recusado, ou refeito no reenvio da nota em revisão
  cancelamento   text check (cancelamento in ('recusa','revisao')),
  substitui_id   uuid references erp.titulos,     -- o título que a nota relançada na revisão refez
  rodada         int not null default 1,          -- volta da alçada; o reenvio da revisão abre outra
  criado_por     uuid,
  criado_em      timestamptz not null default clock_timestamp()
);
-- Quem lançou e quando vêm do servidor, nunca de quem grava (base de "quem lançou não aprova").
create function erp.tg_autor() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := erp.autor();
    new.criado_em := clock_timestamp();
  elsif new.criado_por is distinct from old.criado_por or new.criado_em is distinct from old.criado_em then
    raise exception 'Quem lançou e quando não mudam';
  end if;
  return new;
end $$;
create trigger t_autor before insert or update on erp.titulos
  for each row execute function erp.tg_autor();
create trigger t_autor before insert or update on erp.documentos_fiscais
  for each row execute function erp.tg_autor();
create trigger t_autor before insert or update on erp.compromissos
  for each row execute function erp.tg_autor();
-- a previsão guarda só quem lançou (criada_em já tem o padrão)
create function erp.tg_autor_previsao() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.criada_por := erp.autor();
  elsif new.criada_por is distinct from old.criada_por then raise exception 'Quem lançou não muda';
  end if;
  return new;
end $$;
create trigger t_autor before insert or update on erp.previsoes
  for each row execute function erp.tg_autor_previsao();

create table erp.titulo_rateios (
  id              uuid primary key default gen_random_uuid(),
  titulo_id       uuid not null references erp.titulos on delete cascade,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid references erp.centros_custo,
  divisao_id      uuid,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100),
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);

create table erp.parcelas (
  id         uuid primary key default gen_random_uuid(),
  titulo_id  uuid not null references erp.titulos on delete cascade,
  numero     int not null check (numero > 0),
  vencimento date not null,
  valor      numeric(15,2) not null check (valor > 0),
  unique (titulo_id, numero)
);

-- Quanto de cada previsão o título consumiu (a diferença previsto × realizado sai daqui).
create table erp.titulo_previsoes (
  titulo_id   uuid not null references erp.titulos,
  previsao_id uuid not null references erp.previsoes,
  valor       numeric(15,2) not null check (valor > 0),
  primary key (titulo_id, previsao_id)
);

-- ---------------------------------------------------------------------
-- Pagamento (o dinheiro que saiu) e quitação (quanto dele quitou cada parcela)
-- ---------------------------------------------------------------------
create table erp.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references erp.empresas,
  conta_id       uuid not null references erp.contas_bancarias,
  pessoa_id      uuid not null references erp.pessoas,       -- favorecido
  compromisso_id uuid references erp.compromissos,           -- adiantamento vinculado a contrato
  adiantamento_id uuid references erp.titulos,               -- o pedido de adiantamento aprovado (S-061)
  -- carimbo do dinheiro desde a saída (decisão do Moises, 14/11/2026): núcleo e centro de custo,
  -- obrigatórios salvo na transferência entre contas próprias (favorecido = a própria empresa)
  nucleo_economico_id uuid references erp.nucleos_economicos,
  centro_custo_id     uuid references erp.centros_custo,
  -- e a divisão, quando o centro tem divisões (Moises, 15/11/2026)
  divisao_id          uuid,
  lote_id        uuid references erp.lotes_bancarios,
  data           date not null,
  valor          numeric(15,2) not null check (valor > 0),
  forma          text not null default 'pix' check (forma in ('pix','ted','boleto','debito','cheque','dinheiro','outro')),
  descricao      text,
  criado_por     uuid,
  criado_em      timestamptz not null default clock_timestamp(),
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);
create trigger t_autor before insert or update on erp.pagamentos
  for each row execute function erp.tg_autor();

create table erp.quitacoes (
  id           uuid primary key default gen_random_uuid(),
  pagamento_id uuid not null references erp.pagamentos,
  parcela_id   uuid not null references erp.parcelas,
  principal    numeric(15,2) not null check (principal > 0),
  juros        numeric(15,2) not null default 0 check (juros >= 0),   -- só se sabem na hora de pagar
  multa        numeric(15,2) not null default 0 check (multa >= 0),
  desconto     numeric(15,2) not null default 0 check (desconto >= 0),
  criada_em    timestamptz not null default now(),
  check (principal + juros + multa - desconto > 0)
);
create index on erp.quitacoes (parcela_id);
create index on erp.quitacoes (pagamento_id);

-- ---------------------------------------------------------------------
-- Caução: extrato por contrato
-- ---------------------------------------------------------------------
create table erp.caucao_movimentos (
  id             uuid primary key default gen_random_uuid(),
  compromisso_id uuid not null references erp.compromissos,
  -- estorno: a retenção desfeita quando a nota é cancelada pela alçada
  tipo           text not null check (tipo in ('retencao','estorno','liberacao','uso_terceiro')),
  valor          numeric(15,2) not null check (valor > 0),
  documento_id   uuid references erp.documentos_fiscais,   -- na retenção
  titulo_id      uuid references erp.titulos,              -- na liberação e no uso
  motivo         text,
  em             timestamptz not null default now(),
  por            uuid default erp.eu(),
  check ((tipo in ('retencao','estorno')) = (documento_id is not null)),
  check (tipo in ('retencao','estorno') or titulo_id is not null),
  check (tipo <> 'uso_terceiro' or motivo is not null)
);

-- ---------------------------------------------------------------------
-- Dinheiro entre sócios: par ligado de títulos entre duas empresas
-- ---------------------------------------------------------------------
create table erp.movimentos_societarios (
  id                uuid primary key default gen_random_uuid(),
  tipo              text not null check (tipo in ('aporte','integralizacao','distribuicao','mutuo','devolucao_mutuo')),
  pagadora_id       uuid not null references erp.empresas,
  recebedora_id     uuid not null references erp.empresas,
  data              date not null,
  valor             numeric(15,2) not null check (valor > 0),
  titulo_pagar_id   uuid not null references erp.titulos,
  titulo_receber_id uuid not null references erp.titulos,
  descricao         text,
  criado_em         timestamptz not null default now(),
  check (pagadora_id <> recebedora_id)
);

-- ---------------------------------------------------------------------
-- O livro de lançamentos
-- ---------------------------------------------------------------------
create table erp.lancamentos (
  id                  bigint generated always as identity primary key,
  estagio             text not null check (estagio in ('orcado','previsto','comprometido','realizado')),
  orcamento_versao_id uuid references erp.orcamento_versoes,
  empresa_id          uuid not null references erp.empresas,
  nucleo_economico_id           uuid references erp.nucleos_economicos,
  natureza_id         uuid not null references erp.naturezas,
  centro_custo_id     uuid references erp.centros_custo,
  divisao_id          uuid,
  competencia         date not null check (extract(day from competencia) = 1),
  data_caixa          date,             -- nula = sem data (caução retida)
  valor               numeric(15,2) not null check (valor <> 0),
  -- origem
  orcamento_linha_id  uuid references erp.orcamento_linhas,
  previsao_id         uuid references erp.previsoes,
  titulo_id           uuid references erp.titulos,
  parcela_id          uuid references erp.parcelas,
  quitacao_id         uuid references erp.quitacoes,
  pagamento_id        uuid references erp.pagamentos,
  caucao_movimento_id uuid references erp.caucao_movimentos,
  criado_em           timestamptz not null default clock_timestamp(),
  check ((estagio = 'orcado') = (orcamento_versao_id is not null)),
  -- a divisão é do centro da linha
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null)
);
create index on erp.lancamentos (natureza_id);
create index on erp.lancamentos (empresa_id, competencia);
create index on erp.lancamentos (titulo_id);
create index on erp.lancamentos (previsao_id);

create function erp.tg_lancamento() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'O livro não apaga linhas; estorne com uma linha de sinal contrário'; end if;
  if tg_op = 'UPDATE' then
    if not erp.agindo_como('erp_reclassificacao') then
      raise exception 'O livro não muda; a natureza só muda pela reclassificação';
    end if;
    if (to_jsonb(new) - 'natureza_id') <> (to_jsonb(old) - 'natureza_id') then
      raise exception 'A reclassificação só muda a natureza';
    end if;
  end if;
  if tg_op = 'INSERT' then
    -- o livro só recebe linhas das operações do banco (S-052): nota, título, pagamento, quitação,
    -- previsão, caução e orçamento, todas definer de erp_situacao
    if not erp.agindo_como('erp_situacao') then
      raise exception 'O livro só recebe linhas pelas operações do sistema';
    end if;
    perform erp.checar_natureza(new.natureza_id, new.nucleo_economico_id, new.centro_custo_id, new.estagio = 'orcado');
    perform erp.checar_centro(new.nucleo_economico_id, new.centro_custo_id, new.empresa_id);
  else
    perform erp.checar_natureza(new.natureza_id, new.nucleo_economico_id, new.centro_custo_id, new.estagio = 'orcado');
  end if;
  return new;
end $$;
create trigger t_lancamento before insert or update or delete on erp.lancamentos
  for each row execute function erp.tg_lancamento();

-- Agora a árvore sabe dizer se uma natureza (ou galho abaixo) está em uso.
create or replace function erp.natureza_em_uso(p_id uuid) returns boolean language sql stable as $$
  with recursive sub as (
    select id from erp.naturezas where id = p_id
    union all select n.id from erp.naturezas n join sub on n.mae_id = sub.id)
  select exists (select 1 from erp.lancamentos where natureza_id in (select id from sub))
      or exists (select 1 from erp.previsoes where natureza_id in (select id from sub))
      or exists (select 1 from erp.titulo_rateios where natureza_id in (select id from sub))
      or exists (select 1 from erp.documento_rateios where natureza_id in (select id from sub))
      or exists (select 1 from erp.compromisso_rateios where natureza_id in (select id from sub))
      or exists (select 1 from erp.orcamento_linhas where natureza_id in (select id from sub))
      or exists (select 1 from erp.naturezas_sistema where natureza_id in (select id from sub))
$$;

-- Natureza válida em toda tabela de classificação, e núcleo da empresa do registro pai (S-056).
create function erp.tg_classificacao() returns trigger language plpgsql as $$
declare j jsonb := to_jsonb(new); v_empresa uuid;
begin
  v_empresa := case tg_table_name
    when 'previsoes' then (j->>'empresa_id')::uuid
    when 'compromisso_rateios' then (select empresa_id from erp.compromissos where id = (j->>'compromisso_id')::uuid)
    when 'documento_rateios' then (select empresa_id from erp.documentos_fiscais where id = (j->>'documento_id')::uuid)
    when 'titulo_rateios' then (select empresa_id from erp.titulos where id = (j->>'titulo_id')::uuid)
    when 'orcamento_linhas' then (select empresa_id from erp.orcamento_versoes where id = (j->>'versao_id')::uuid) end;
  perform erp.checar_natureza(new.natureza_id, new.nucleo_economico_id, new.centro_custo_id, tg_table_name = 'orcamento_linhas');
  perform erp.checar_centro(new.nucleo_economico_id, new.centro_custo_id, v_empresa);
  return new;
end $$;
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id, compromisso_id on erp.compromisso_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id, documento_id on erp.documento_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id, titulo_id on erp.titulo_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id, empresa_id on erp.previsoes
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id, versao_id on erp.orcamento_linhas
  for each row execute function erp.tg_classificacao();

-- A divisão (Moises, 15/11/2026): a da linha está ativa, e o centro com divisão ativa exige a
-- divisão em cada linha que uma pessoa grava. A linha que o sistema copia (título da nota,
-- previsão da assinatura) segue a de origem, para a rotina não parar quando o centro ganha
-- divisões depois. Que a divisão é do centro, a chave estrangeira composta garante.
-- Invoker de propósito: precisa saber quem grava (erp.agindo_como).
create function erp.tg_divisao_linha() returns trigger language plpgsql as $$
begin
  if new.divisao_id is not null and tg_op = 'UPDATE' and new.divisao_id is not distinct from old.divisao_id then
    return new;
  end if;
  if new.divisao_id is not null then
    if not (select ativa from erp.divisoes where id = new.divisao_id) then
      raise exception 'A divisão está desativada';
    end if;
  elsif new.centro_custo_id is not null and not (erp.agindo_como('erp_situacao') or erp.sistema())
        and exists (select 1 from erp.divisoes where centro_custo_id = new.centro_custo_id and ativa) then
    raise exception 'O centro de custo "%" tem divisões: diga a divisão da linha',
      (select nome from erp.centros_custo where id = new.centro_custo_id);
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['compromisso_rateios', 'documento_rateios', 'titulo_rateios', 'previsoes', 'orcamento_linhas', 'pagamentos'] loop
    execute format('create trigger t_divisao_linha before insert or update of centro_custo_id, divisao_id on erp.%I
                      for each row execute function erp.tg_divisao_linha()', t);
  end loop;
end $$;

-- Naturezas liberadas para lançamento em cada divisão, ou no centro sem divisão (Moises,
-- 15/11/2026). A escolha faz parte da criação da divisão; depois o master, o administrador e
-- AF, AO e AD ligam e desligam na hora, com auditoria. Natureza nova nasce desligada. Num centro
-- com divisões vale a lista de cada divisão. Desligar não mexe no que já foi lançado: só barra
-- lançar de novo ou trocar para ela.
create table erp.naturezas_liberadas (
  centro_custo_id uuid not null references erp.centros_custo on delete cascade,
  divisao_id      uuid,
  natureza_id     uuid not null references erp.naturezas on delete cascade,   -- natureza nunca usada se apaga
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  unique nulls not distinct (centro_custo_id, divisao_id, natureza_id)
);
create function erp.tg_natureza_liberada_cfg() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and tg_table_name <> 'modelos_naturezas' then
    raise exception 'Natureza liberada não se altera: desligue e ligue';
  end if;
  if erp.agindo_como('erp_acesso') or erp.sistema()
     or (tg_op = 'DELETE' and erp.agindo_como('erp_reclassificacao')) then   -- a natureza esvaziada e apagada
    return coalesce(new, old);
  end if;
  -- erp.sou_admin e erp.financeiro nascem na migration _erp_api
  if not (erp.sou_admin() or erp.financeiro()) then
    raise exception 'Só o master, o administrador e AF, AO ou AD ligam e desligam naturezas';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_natureza_liberada_cfg before insert or update or delete on erp.naturezas_liberadas
  for each row execute function erp.tg_natureza_liberada_cfg();
create trigger t_aud_naturezas_liberadas after insert or delete on erp.naturezas_liberadas
  for each row execute function erp.tg_auditoria('centro_custo_id');

-- Modelos de naturezas (Moises, 15/11/2026): listas pré-definidas para marcar de uma vez ao criar
-- a divisão (ou ao ajustar uma existente). O modelo só guarda a lista; aplicar é marcar as
-- naturezas dele. Quem mexe: os mesmos que ligam e desligam naturezas.
create table erp.modelos_naturezas (
  id    uuid primary key default gen_random_uuid(),
  nome  text not null unique check (length(trim(nome)) > 0),
  ativo boolean not null default true
);
create table erp.modelo_naturezas (
  modelo_id   uuid not null references erp.modelos_naturezas on delete cascade,
  natureza_id uuid not null references erp.naturezas on delete cascade,
  primary key (modelo_id, natureza_id)
);
do $$
declare t record;
begin
  for t in select * from (values ('modelos_naturezas', 'id'), ('modelo_naturezas', 'modelo_id')) v(tabela, chave) loop
    execute format('create trigger t_natureza_liberada_cfg before insert or update or delete on erp.%I
                      for each row execute function erp.tg_natureza_liberada_cfg()', t.tabela);
    execute format('create trigger t_aud_%s after insert or update or delete on erp.%I
                      for each row execute function erp.tg_auditoria(%L)', t.tabela, t.tabela, t.chave);
  end loop;
end $$;

-- A linha que uma pessoa grava usa natureza liberada na divisão (ou no centro sem divisão).
-- A cópia feita pelo sistema segue a origem, como a divisão. Invoker: precisa saber quem grava.
create function erp.tg_natureza_liberada() returns trigger language plpgsql as $$
begin
  if new.centro_custo_id is null or erp.agindo_como('erp_situacao') or erp.sistema() then return new; end if;
  if tg_op = 'UPDATE' and new.natureza_id is not distinct from old.natureza_id
     and new.centro_custo_id is not distinct from old.centro_custo_id
     and new.divisao_id is not distinct from old.divisao_id then
    return new;
  end if;
  if not exists (select 1 from erp.naturezas_liberadas
                  where centro_custo_id = new.centro_custo_id and divisao_id is not distinct from new.divisao_id
                    and natureza_id = new.natureza_id) then
    raise exception 'A natureza "%" não está liberada para lançamento em "%"',
      (select nome from erp.naturezas where id = new.natureza_id),
      coalesce((select c.nome || ' > ' || d.nome from erp.divisoes d join erp.centros_custo c on c.id = d.centro_custo_id
                 where d.id = new.divisao_id),
               (select nome from erp.centros_custo where id = new.centro_custo_id));
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['compromisso_rateios', 'documento_rateios', 'titulo_rateios', 'previsoes'] loop
    execute format('create trigger t_natureza_liberada before insert or update of natureza_id, centro_custo_id, divisao_id on erp.%I
                      for each row execute function erp.tg_natureza_liberada()', t);
  end loop;
end $$;

-- Títulos em aberto (ou em rascunho) com linha na natureza, no centro e na divisão: o que
-- quem desliga a natureza precisa ver. Invoker: cada um vê os títulos que já vê.
create function erp.titulos_abertos_na_natureza(p_centro uuid, p_divisao uuid, p_natureza uuid)
returns setof uuid language sql stable as $$
  select distinct t.id from erp.titulos t join erp.titulo_rateios r on r.titulo_id = t.id
   where t.situacao in ('rascunho','aberto') and r.centro_custo_id = p_centro
     and r.divisao_id is not distinct from p_divisao and r.natureza_id = p_natureza $$;

-- A empresa de um registro não muda depois de criado (S-056): o rateio, o livro e a caução
-- foram conferidos contra ela.
create function erp.tg_empresa_fixa() returns trigger language plpgsql as $$
begin
  if new.empresa_id <> old.empresa_id then raise exception 'A empresa do registro não muda; crie outro'; end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['compromissos', 'documentos_fiscais', 'titulos', 'orcamento_versoes', 'pagamentos', 'contas_bancarias'] loop
    execute format('create trigger t_empresa_fixa before update of empresa_id on erp.%I
                      for each row execute function erp.tg_empresa_fixa()', t);
  end loop;
end $$;

-- Rateio de um registro (compromisso, documento ou título) dividindo um total em centavos exatos:
-- cada parte = arredondamento do acumulado menos o do acumulado anterior, então a soma fecha.
create function erp.ratear(p_origem text, p_id uuid, p_total numeric)
returns table (nucleo_economico_id uuid, natureza_id uuid, centro_custo_id uuid, divisao_id uuid, valor numeric)
language sql stable as $$
  with r as (
    select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual, id from erp.compromisso_rateios
      where p_origem = 'compromisso' and compromisso_id = p_id
    union all
    select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual, id from erp.documento_rateios
      where p_origem = 'documento' and documento_id = p_id
    union all
    select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual, id from erp.titulo_rateios
      where p_origem = 'titulo' and titulo_id = p_id
  ), a as (
    select r.*, sum(percentual) over (order by percentual desc, id) as acum,
           sum(percentual) over () as total_pct
    from r
  )
  select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
         round(p_total * acum / total_pct, 2) - round(p_total * (acum - percentual) / total_pct, 2)
  from a
$$;

create function erp.rateio_completo(p_origem text, p_id uuid) returns boolean language sql stable as $$
  select coalesce(sum(percentual), 0) = 100 from (
    select percentual from erp.compromisso_rateios where p_origem = 'compromisso' and compromisso_id = p_id
    union all select percentual from erp.documento_rateios where p_origem = 'documento' and documento_id = p_id
    union all select percentual from erp.titulo_rateios where p_origem = 'titulo' and titulo_id = p_id) r
$$;

create function erp.mes(d date) returns date language sql immutable as
  $$ select date_trunc('month', d)::date $$;

create function erp.sinal(p_sentido text) returns int language sql immutable as
  $$ select case p_sentido when 'receber' then 1 else -1 end $$;

create function erp.natureza_sistema(p_chave text) returns uuid language sql stable as
  $$ select natureza_id from erp.naturezas_sistema where chave = p_chave $$;

-- ---------------------------------------------------------------------
-- Orçamento → livro (estágio orçado)
-- ---------------------------------------------------------------------
create function erp.tg_orcamento_linha() returns trigger language plpgsql as $$
declare v erp.orcamento_versoes;
begin
  select * into v from erp.orcamento_versoes where id = coalesce(new.versao_id, old.versao_id);
  if v.situacao <> 'rascunho' then raise exception 'Versão de orçamento % não muda; crie uma reprojeção', v.situacao; end if;
  return coalesce(new, old);
end $$;
create trigger t_orc_linha before insert or update or delete on erp.orcamento_linhas
  for each row execute function erp.tg_orcamento_linha();

-- A versão nasce em rascunho e só a publicação muda a situação dela (S-055); publicada, não se
-- edita nem se apaga.
create function erp.tg_orcamento_versao() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.situacao <> 'rascunho' then raise exception 'Versão de orçamento nasce em rascunho'; end if;
    new.criada_por := erp.autor();
    new.criada_em := clock_timestamp();
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.situacao <> 'rascunho' then raise exception 'Versão de orçamento % não se apaga', old.situacao; end if;
    return old;
  end if;
  if new.situacao <> old.situacao and not erp.agindo_como('erp_situacao') then
    raise exception 'A situação do orçamento só muda pela publicação';
  end if;
  if (to_jsonb(new) - 'situacao') <> (to_jsonb(old) - 'situacao')
     and (old.situacao <> 'rascunho' or new.id <> old.id or new.criada_por is distinct from old.criada_por
          or new.criada_em <> old.criada_em) then
    raise exception 'Versão de orçamento % não muda; crie uma reprojeção', old.situacao;
  end if;
  return new;
end $$;
create trigger t_orcamento_versao before insert or update or delete on erp.orcamento_versoes
  for each row execute function erp.tg_orcamento_versao();

-- Publicar a versão grava as linhas no livro e substitui a vigente do mesmo tipo.
create function erp.publicar_orcamento(p_versao uuid) returns void language plpgsql as $$
declare v erp.orcamento_versoes;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and exists (select 1 from erp.orcamento_linhas l where l.versao_id = p_versao
                                     and not erp.lanco(l.nucleo_economico_id, l.centro_custo_id, l.natureza_id, null, l.divisao_id)) then
    raise exception 'Você não lança em todas as linhas deste orçamento';
  end if;
  select * into v from erp.orcamento_versoes where id = p_versao for update;
  if v.situacao <> 'rascunho' then raise exception 'Só se publica versão em rascunho'; end if;
  update erp.orcamento_versoes set situacao = 'substituida'
   where empresa_id = v.empresa_id and empreendimento_id is not distinct from v.empreendimento_id
     and tipo = v.tipo and situacao = 'vigente' and tipo <> 'reprojecao';
  insert into erp.lancamentos (estagio, orcamento_versao_id, empresa_id, nucleo_economico_id, natureza_id,
                                  centro_custo_id, divisao_id, competencia, data_caixa, valor, orcamento_linha_id)
  select 'orcado', v.id, v.empresa_id, l.nucleo_economico_id, l.natureza_id, l.centro_custo_id, l.divisao_id,
         l.competencia, l.data_caixa, l.valor, l.id
  from erp.orcamento_linhas l where l.versao_id = v.id;
  update erp.orcamento_versoes set situacao = 'vigente' where id = v.id;
end $$;

-- ---------------------------------------------------------------------
-- Previsão → livro (estágio previsto)
-- ---------------------------------------------------------------------
create function erp._previsao_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(tp.valor) from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
                              where tp.previsao_id = p.id and t.situacao <> 'cancelado'), 0)
  from erp.previsoes p where p.id = p_id $$;

-- Guarda (invoker, confere a marca de quem grava) e escrita no livro (definer erp_situacao, na
-- migration _erp_rls) separadas: dentro da definer, a marca seria sempre a dela.
create function erp.tg_previsao_guarda() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.situacao <> 'aberta' then raise exception 'Previsão nasce aberta'; end if;
    return new;
  end if;
  if (to_jsonb(new) - 'situacao' - 'natureza_id') <> (to_jsonb(old) - 'situacao' - 'natureza_id') then
    raise exception 'Previsão não se edita; cancele e crie outra';
  end if;
  if new.natureza_id <> old.natureza_id and not erp.agindo_como('erp_reclassificacao') then
    raise exception 'A natureza da previsão só muda pela reclassificação';
  end if;
  if new.situacao <> old.situacao and not (new.situacao = 'cancelada' and old.situacao = 'aberta')
     and not erp.agindo_como('erp_situacao') then
    raise exception 'A previsão só pode ser cancelada; ela é consumida pelos títulos';
  end if;
  return new;
end $$;
create trigger t_previsao_guarda before insert or update on erp.previsoes
  for each row execute function erp.tg_previsao_guarda();

create function erp.tg_previsao() returns trigger language plpgsql as $$
declare v_saldo numeric;
begin
  if tg_op = 'INSERT' then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                    competencia, data_caixa, valor, previsao_id)
    values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.centro_custo_id, new.divisao_id,
            new.competencia, new.data_prevista, erp.sinal(new.sentido) * new.valor, new.id);
    return new;
  end if;
  if new.situacao = 'cancelada' and old.situacao = 'aberta' then
    v_saldo := erp._previsao_saldo(new.id);
    if v_saldo > 0 then
      insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                      competencia, data_caixa, valor, previsao_id)
      values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.centro_custo_id, new.divisao_id,
              new.competencia, new.data_prevista, -erp.sinal(new.sentido) * v_saldo, new.id);
    end if;
  end if;
  return new;
end $$;
create trigger t_previsao after insert or update on erp.previsoes
  for each row execute function erp.tg_previsao();

-- Consumo da previsão pelo título: estorna o previsto na data da previsão.
-- Só pelo lancar_documento (S-054): a guarda (invoker) confere a marca de quem grava, e o
-- consumo (definer erp_situacao, na migration _erp_rls) confere de novo se a previsão casa
-- com a nota do título.
create function erp.tg_titulo_previsao_guarda() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_situacao') then
    raise exception 'A previsão só é consumida pelo lançamento da nota';
  end if;
  return new;
end $$;
create trigger t_guarda_titulo_previsao before insert on erp.titulo_previsoes
  for each row execute function erp.tg_titulo_previsao_guarda();

create function erp.tg_titulo_previsao() returns trigger language plpgsql as $$
declare p erp.previsoes; d erp.documentos_fiscais; v_saldo numeric;
begin
  select * into p from erp.previsoes where id = new.previsao_id for update;
  if p.situacao <> 'aberta' then raise exception 'A previsão não está aberta'; end if;
  if p.empresa_id <> (select empresa_id from erp.titulos where id = new.titulo_id) then
    raise exception 'Previsão e título são de empresas diferentes';
  end if;
  select dc.* into d from erp.documentos_fiscais dc join erp.titulos t on t.documento_id = dc.id
   where t.id = new.titulo_id;
  if d.id is null or not erp._previsao_casa(p, d) then
    raise exception 'A previsão não casa com a nota do título';
  end if;
  v_saldo := p.valor - coalesce((select sum(tp.valor) from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
                                 where tp.previsao_id = p.id and tp.titulo_id <> new.titulo_id and t.situacao <> 'cancelado'), 0);
  if new.valor > v_saldo then raise exception 'O consumo (%) passa do saldo da previsão (%)', new.valor, v_saldo; end if;
  insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                  competencia, data_caixa, valor, previsao_id, titulo_id)
  values ('previsto', p.empresa_id, p.nucleo_economico_id, p.natureza_id, p.centro_custo_id, p.divisao_id,
          p.competencia, p.data_prevista, -erp.sinal(p.sentido) * new.valor, p.id, new.titulo_id);
  if new.valor = v_saldo then
    update erp.previsoes set situacao = 'consumida' where id = p.id;   -- definer erp_situacao (_erp_rls)
  end if;
  return new;
end $$;
create trigger t_titulo_previsao before insert on erp.titulo_previsoes
  for each row execute function erp.tg_titulo_previsao();
create function erp.tg_imutavel() returns trigger language plpgsql as $$
begin raise exception 'Registro de % não se altera nem se apaga', tg_table_name; end $$;
create trigger t_imutavel before update or delete on erp.titulo_previsoes
  for each row execute function erp.tg_imutavel();

-- Assinatura recorrente: gera as previsões de cada período até a data pedida.
create function erp.gerar_previsoes_assinatura(p_compromisso uuid, p_ate date) returns int
language plpgsql as $$
declare c erp.compromissos; d date; v_passo interval; n int := 0; r record;
begin
  perform erp.exigir_editor();
  select * into c from erp.compromissos where id = p_compromisso;
  if c.tipo <> 'assinatura' or c.situacao <> 'ativo' then raise exception 'Só assinatura ativa gera previsões'; end if;
  if not erp.rateio_completo('compromisso', c.id) then raise exception 'O rateio da assinatura não soma 100%%'; end if;
  v_passo := case c.periodicidade when 'mensal' then '1 month' when 'bimestral' then '2 months'
             when 'trimestral' then '3 months' when 'semestral' then '6 months' else '1 year' end::interval;
  d := erp.mes(c.inicio);
  while d <= least(p_ate, coalesce(c.fim, p_ate)) loop
    if not exists (select 1 from erp.previsoes where compromisso_id = c.id and competencia = d and situacao <> 'cancelada') then
      for r in select * from erp.ratear('compromisso', c.id, c.valor_periodo) loop
        insert into erp.previsoes (empresa_id, origem, compromisso_id, pessoa_id, nucleo_economico_id, natureza_id,
                                      centro_custo_id, divisao_id, competencia, data_prevista, valor, descricao)
        values (c.empresa_id, 'assinatura', c.id, c.pessoa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id,
                d, least(d + (coalesce(c.dia_vencimento, 1) - 1), (d + interval '1 month - 1 day')::date),
                r.valor, c.descricao);
      end loop;
      n := n + 1;
    end if;
    d := (d + v_passo)::date;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Título → livro (estágio comprometido)
-- ---------------------------------------------------------------------
create function erp.tg_titulo() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' and new.situacao <> 'rascunho' then
    raise exception 'Título nasce em rascunho; é aberto pelo confirmar_titulo';
  end if;
  -- de fora das operações (nota, caução, sócios) só nasce título avulso ou pedido de adiantamento,
  -- sem nota nem contrato (S-057, S-061)
  if tg_op = 'INSERT' and not erp.agindo_como('erp_situacao')
     and (new.tipo not in ('avulso','adiantamento') or new.documento_id is not null or new.compromisso_id is not null) then
    raise exception 'De fora das operações só se cria título avulso ou pedido de adiantamento, sem nota nem contrato';
  end if;
  if tg_op = 'UPDATE' and not erp.agindo_como('erp_situacao')
     and (new.tipo, new.documento_id, new.compromisso_id) is distinct from (old.tipo, old.documento_id, old.compromisso_id) then
    raise exception 'O título não muda de tipo, nota ou contrato';
  end if;
  -- a situação (inclusive rascunho → aberto) só muda pelas operações do banco: confirmar e quitar
  if tg_op = 'UPDATE' and (new.situacao, new.cancelamento) is distinct from (old.situacao, old.cancelamento)
     and not erp.agindo_como('erp_situacao') then
    raise exception 'A situação do título muda pelas quitações';
  end if;
  if tg_op = 'UPDATE' and (new.rodada, new.substitui_id) is distinct from (old.rodada, old.substitui_id)
     and not erp.agindo_como('erp_situacao') then
    raise exception 'A volta da alçada muda pelo reenvio da revisão';
  end if;
  -- confirmado não se edita; em revisão, quem pode ajustar muda tudo menos empresa, tipo, nota,
  -- contrato e sentido (título de nota se ajusta pela nota)
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho'
     and (to_jsonb(new) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id')
         <> (to_jsonb(old) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id')
     and not (old.documento_id is null and erp.em_revisao(old.id) and erp.pode_ajustar(old.id)
              and (new.empresa_id, new.tipo, new.sentido, new.compromisso_id) = (old.empresa_id, old.tipo, old.sentido, old.compromisso_id)
              and new.documento_id is null) then
    raise exception 'Título confirmado não se edita';
  end if;
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' and not erp.agindo_como('erp_situacao') then
    perform erp.conferir_ajuste(old.id, 'titulos',
      to_jsonb(old) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id',
      to_jsonb(new) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id');
    perform erp._registrar_ajuste(old.id, 'titulos',
      to_jsonb(old) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id',
      to_jsonb(new) - 'situacao' - 'cancelamento' - 'rodada' - 'substitui_id');
  end if;
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then
    raise exception 'Título confirmado não se apaga';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_titulo before insert or update or delete on erp.titulos
  for each row execute function erp.tg_titulo();

-- Parcelas e rateio só mudam com o título em rascunho (a natureza também pela reclassificação).
create function erp.tg_filho_titulo() returns trigger language plpgsql as $$
begin
  -- o pai de antes e o de depois (mudar o titulo_id tiraria a linha de um título confirmado)
  if not exists (select 1 from erp.titulos where situacao <> 'rascunho'
                  and id in (case when tg_op <> 'DELETE' then new.titulo_id end,
                             case when tg_op <> 'INSERT' then old.titulo_id end)) then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'titulo_rateios'
     and erp.agindo_como('erp_reclassificacao')
     and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then
    return new;
  end if;
  -- em revisão, quem pode ajustar muda parcelas e rateio do título avulso ou do pedido
  -- (parcela já lançada no livro não se apaga: ajuste o valor e o vencimento)
  if (tg_op <> 'UPDATE' or (case when tg_op = 'UPDATE' then new.titulo_id = old.titulo_id end))
     and erp._ajustavel(case when tg_op = 'DELETE' then old.titulo_id else new.titulo_id end) then
    perform erp.conferir_ajuste(case when tg_op = 'DELETE' then old.titulo_id else new.titulo_id end, tg_table_name,
      case when tg_op <> 'INSERT' then to_jsonb(old) - 'id' - 'titulo_id' end,
      case when tg_op <> 'DELETE' then to_jsonb(new) - 'id' - 'titulo_id' end);
    perform erp._registrar_ajuste(case when tg_op = 'DELETE' then old.titulo_id else new.titulo_id end, tg_table_name,
      case when tg_op <> 'INSERT' then to_jsonb(old) end, case when tg_op <> 'DELETE' then to_jsonb(new) end);
    return coalesce(new, old);
  end if;
  raise exception 'O título já foi confirmado; % não muda', tg_table_name;
end $$;

-- Rateio e retenções da nota só mudam com ela em rascunho (S-057; a natureza também pela reclassificação).
create function erp.tg_filho_documento() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from erp.documentos_fiscais where situacao <> 'rascunho'
                  and id in (case when tg_op <> 'DELETE' then new.documento_id end,
                             case when tg_op <> 'INSERT' then old.documento_id end)) then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and tg_table_name = 'documento_rateios'
     and erp.agindo_como('erp_reclassificacao')
     and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then
    return new;
  end if;
  -- em revisão, quem pode ajustar muda o rateio e as retenções da nota (relançada no reenvio)
  if (tg_op <> 'UPDATE' or (case when tg_op = 'UPDATE' then new.documento_id = old.documento_id end))
     and erp._nota_ajustavel(case when tg_op = 'DELETE' then old.documento_id else new.documento_id end) then
    perform erp.conferir_ajuste(erp._titulo_em_revisao_da_nota(case when tg_op = 'DELETE' then old.documento_id else new.documento_id end),
      tg_table_name,
      case when tg_op <> 'INSERT' then to_jsonb(old) - 'id' - 'documento_id' end,
      case when tg_op <> 'DELETE' then to_jsonb(new) - 'id' - 'documento_id' end);
    perform erp._registrar_ajuste(erp._titulo_em_revisao_da_nota(case when tg_op = 'DELETE' then old.documento_id else new.documento_id end),
      tg_table_name, case when tg_op <> 'INSERT' then to_jsonb(old) end, case when tg_op <> 'DELETE' then to_jsonb(new) end);
    return coalesce(new, old);
  end if;
  raise exception 'A nota já foi lançada; % não muda', tg_table_name;
end $$;
create trigger t_filho before insert or update or delete on erp.documento_rateios
  for each row execute function erp.tg_filho_documento();
create trigger t_filho before insert or update or delete on erp.documento_retencoes
  for each row execute function erp.tg_filho_documento();
create trigger t_filho before insert or update or delete on erp.parcelas
  for each row execute function erp.tg_filho_titulo();
create trigger t_filho before insert or update or delete on erp.titulo_rateios
  for each row execute function erp.tg_filho_titulo();

-- O comprometido do título no livro: uma linha por parcela e linha do rateio.
create function erp._comprometer_titulo(t erp.titulos) returns void language plpgsql as $$
declare p record; r record;
begin
  for p in select * from erp.parcelas where titulo_id = t.id and t.tipo <> 'adiantamento' order by numero loop
    for r in select * from erp.ratear('titulo', t.id, p.valor) loop
      insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                      competencia, data_caixa, valor, titulo_id, parcela_id)
      values ('comprometido', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id,
              t.competencia, p.vencimento, erp.sinal(t.sentido) * r.valor, t.id, p.id);
    end loop;
  end loop;
end $$;
-- Estorna o que o título deixou no livro (só cresce: linha de sinal contrário pelo saldo de cada
-- combinação). p_estagio nulo estorna tudo; 'comprometido', só o comprometido.
create function erp._estornar_titulo(p_titulo uuid, p_estagio text) returns void language plpgsql as $$
begin
  insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                               competencia, data_caixa, valor, titulo_id, parcela_id, previsao_id)
  select estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
         competencia, data_caixa, -sum(valor), p_titulo, parcela_id, previsao_id
    from erp.lancamentos
   where titulo_id = p_titulo and (p_estagio is null or estagio = p_estagio)
   group by estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
            competencia, data_caixa, parcela_id, previsao_id
  having sum(valor) <> 0;
end $$;

-- Confirmar pela API: por dentro a operação vê tudo, então confere antes que quem chama lança em
-- todas as linhas do título. As operações que criam e confirmam o título (nota, caução, sócios)
-- chamam a interna, depois de conferir o próprio registro.
create function erp.confirmar_titulo(p_titulo uuid) returns void language plpgsql as $$
begin
  perform erp.exigir_editor();
  if not erp.sistema() and not erp.lanco_titulo(p_titulo) then
    raise exception 'Você não lança em todas as linhas deste título';
  end if;
  perform erp._confirmar_titulo(p_titulo);
end $$;
create function erp._confirmar_titulo(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos;
begin
  perform erp.exigir_editor();
  select * into t from erp.titulos where id = p_titulo for update;
  if t.situacao <> 'rascunho' then raise exception 'O título já foi confirmado'; end if;
  if not erp.rateio_completo('titulo', t.id) then raise exception 'O rateio do título não soma 100%%'; end if;
  if t.tipo in ('avulso','adiantamento') then perform erp.checar_competencia('titulo', t.id, t.emissao, t.competencia); end if;
  if coalesce((select sum(valor) from erp.parcelas where titulo_id = t.id), 0) <> t.valor then
    raise exception 'As parcelas não somam o valor do título';
  end if;
  -- o pedido de adiantamento tem um carimbo só e não compromete o livro: quem lança é o pagamento
  if t.tipo = 'adiantamento' and (select count(*) from erp.titulo_rateios where titulo_id = t.id) <> 1 then
    raise exception 'O pedido de adiantamento tem um núcleo e um centro de custo só';
  end if;
  perform erp._comprometer_titulo(t);
  update erp.titulos set situacao = 'aberto' where id = t.id;   -- definer erp_situacao (_erp_rls)
  perform erp._definir_alcada(t.id);
end $$;

-- Cria título com parcelas iguais (o resto dos centavos na última) e o rateio dado.
create function erp._criar_titulo(p_empresa uuid, p_sentido text, p_tipo text, p_pessoa uuid, p_documento uuid,
  p_compromisso uuid, p_emissao date, p_competencia date, p_valor numeric, p_vencimentos date[],
  p_rateio_origem text, p_rateio_id uuid, p_descricao text) returns uuid language plpgsql as $$
declare v_id uuid; n int := array_length(p_vencimentos, 1); i int; v_parc numeric;
begin
  insert into erp.titulos (empresa_id, sentido, tipo, pessoa_id, documento_id, compromisso_id, emissao, competencia, valor, descricao)
  values (p_empresa, p_sentido, p_tipo, p_pessoa, p_documento, p_compromisso, p_emissao, p_competencia, p_valor, p_descricao)
  returning id into v_id;
  for i in 1..n loop
    v_parc := case when i < n then trunc(p_valor / n, 2) else p_valor - trunc(p_valor / n, 2) * (n - 1) end;
    insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (v_id, i, p_vencimentos[i], v_parc);
  end loop;
  if p_rateio_origem is not null then
    insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual)
    select v_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual from (
      select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual from erp.compromisso_rateios
        where p_rateio_origem = 'compromisso' and compromisso_id = p_rateio_id
      union all
      select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, percentual from erp.documento_rateios
        where p_rateio_origem = 'documento' and documento_id = p_rateio_id) r;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Lançar a nota: título do fornecedor pelo líquido, um título por imposto retido
-- e a retenção da caução no extrato do contrato. Consome as previsões.
-- ---------------------------------------------------------------------
create function erp._previsao_casa(pr erp.previsoes, d erp.documentos_fiscais) returns boolean
language sql stable as $$
  select pr.situacao = 'aberta' and pr.sentido = 'pagar' and pr.empresa_id = d.empresa_id
     and (pr.pessoa_id is null or pr.pessoa_id = d.emitente_id)
     and exists (select 1 from erp.documento_rateios r
                 where r.documento_id = d.id
                   and r.nucleo_economico_id is not distinct from pr.nucleo_economico_id
                   and r.centro_custo_id is not distinct from pr.centro_custo_id
                   and r.natureza_id = pr.natureza_id)
$$;

create function erp.lancar_documento(p_documento uuid, p_vencimentos date[], p_previsoes uuid[] default null)
returns uuid language plpgsql as $$
declare d erp.documentos_fiscais; v_ret numeric; v_liquido numeric; v_tit uuid; v_imp uuid; r record;
        v_resta numeric; v_cons numeric; v_lim numeric; p record;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and not erp.lanco_documento(p_documento) then
    raise exception 'Você não lança em todas as linhas desta nota';
  end if;
  select * into d from erp.documentos_fiscais where id = p_documento for update;
  if d.situacao <> 'rascunho' then raise exception 'O documento já foi lançado'; end if;
  if coalesce(array_length(p_vencimentos, 1), 0) = 0 then raise exception 'Informe ao menos um vencimento'; end if;
  if not erp.rateio_completo('documento', d.id) then raise exception 'O rateio do documento não soma 100%%'; end if;
  perform erp.checar_competencia('documento', d.id, d.emissao, d.competencia);
  if d.caucao_valor is null then
    d.caucao_valor := round(d.valor_bruto * coalesce((select caucao_percentual from erp.compromissos where id = d.compromisso_id), 0) / 100, 2);
  end if;
  if d.caucao_valor > 0 and d.compromisso_id is null then raise exception 'Caução só existe com contrato'; end if;
  select coalesce(sum(valor), 0) into v_ret from erp.documento_retencoes where documento_id = d.id;
  v_liquido := d.valor_bruto - v_ret - d.caucao_valor;
  if v_liquido <= 0 then raise exception 'Retenções e caução passam do valor da nota'; end if;

  v_tit := erp._criar_titulo(d.empresa_id, 'pagar', 'fornecedor', d.emitente_id, d.id, d.compromisso_id,
                                d.emissao, d.competencia, v_liquido, p_vencimentos, 'documento', d.id, null);
  perform erp._confirmar_titulo(v_tit);

  for r in select * from erp.documento_retencoes where documento_id = d.id loop
    v_imp := erp._criar_titulo(d.empresa_id, 'pagar', 'imposto', r.orgao_id, d.id, d.compromisso_id,
                                  d.emissao, d.competencia, r.valor, array[r.vencimento], 'documento', d.id,
                                  upper(r.imposto) || ' retido na nota ' || d.numero);
    perform erp._confirmar_titulo(v_imp);
  end loop;

  if d.caucao_valor > 0 then
    insert into erp.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
    values (d.compromisso_id, 'retencao', d.caucao_valor, d.id);
  end if;

  -- consumo das previsões (as dadas, ou as abertas do mesmo contrato, da mais antiga), até o bruto.
  -- Só casa previsão da mesma empresa, do mesmo fornecedor (ou sem fornecedor) e com o mesmo
  -- núcleo, centro de custo e natureza de uma linha do rateio da nota (S-030). Previsão dada que
  -- não casa é recusada, nunca ignorada.
  if p_previsoes is not null and exists (
       select 1 from unnest(p_previsoes) as x(id)
       where not exists (select 1 from erp.previsoes pr where pr.id = x.id and erp._previsao_casa(pr, d))) then
    raise exception 'Previsão que não é desta nota: precisa ser aberta, da mesma empresa e fornecedor, e com o mesmo núcleo, centro de custo e natureza do rateio';
  end if;
  v_resta := d.valor_bruto;
  for p in
    select pr.id, pr.nucleo_economico_id, pr.centro_custo_id, pr.natureza_id from erp.previsoes pr
    where erp._previsao_casa(pr, d)
      and (case when p_previsoes is not null then pr.id = any(p_previsoes)
                else d.compromisso_id is not null and pr.compromisso_id = d.compromisso_id end)
    order by pr.data_prevista, pr.criada_em
  loop
    exit when v_resta <= 0;
    -- só até a parte do bruto rateada no mesmo núcleo, centro e natureza da previsão,
    -- descontado o que outras previsões da mesma combinação já consumiram nesta nota
    select round(d.valor_bruto * coalesce(sum(dr.percentual), 0) / 100, 2)
           - coalesce((select sum(tp.valor) from erp.titulo_previsoes tp join erp.previsoes q on q.id = tp.previsao_id
                       where tp.titulo_id = v_tit
                         and q.nucleo_economico_id is not distinct from p.nucleo_economico_id
                         and q.centro_custo_id is not distinct from p.centro_custo_id
                         and q.natureza_id = p.natureza_id), 0)
      into v_lim
      from erp.documento_rateios dr
     where dr.documento_id = d.id
       and dr.nucleo_economico_id is not distinct from p.nucleo_economico_id
       and dr.centro_custo_id is not distinct from p.centro_custo_id
       and dr.natureza_id = p.natureza_id;
    v_cons := least(v_resta, erp._previsao_saldo(p.id), v_lim);
    continue when v_cons <= 0;
    insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (v_tit, p.id, v_cons);
    v_resta := v_resta - v_cons;
  end loop;

  update erp.documentos_fiscais set situacao = 'lancado', lancado_em = now(), caucao_valor = d.caucao_valor where id = d.id;
  return v_tit;
end $$;

create function erp.tg_documento() returns trigger language plpgsql as $$
begin
  -- a situação só muda pelo lancar_documento (definer erp_situacao, S-036); lançado não volta a rascunho
  if tg_op = 'INSERT' and new.situacao <> 'rascunho' then
    raise exception 'Documento nasce em rascunho; é lançado pelo lancar_documento';
  end if;
  if tg_op = 'UPDATE' and (new.situacao, new.cancelamento) is distinct from (old.situacao, old.cancelamento)
     and not erp.agindo_como('erp_situacao') then
    raise exception 'A situação do documento muda pelo lançamento';
  end if;
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then raise exception 'Documento lançado não se apaga'; end if;
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho'
     and (to_jsonb(new) - 'situacao' - 'cancelamento' - 'lancado_em') <> (to_jsonb(old) - 'situacao' - 'cancelamento' - 'lancado_em')
     and not (erp._nota_ajustavel(old.id) and new.empresa_id = old.empresa_id) then
    raise exception 'Documento lançado não se edita';
  end if;
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' and not erp.agindo_como('erp_situacao') then
    perform erp.conferir_ajuste(erp._titulo_em_revisao_da_nota(old.id), 'documentos_fiscais',
      to_jsonb(old) - 'situacao' - 'cancelamento' - 'lancado_em', to_jsonb(new) - 'situacao' - 'cancelamento' - 'lancado_em');
    perform erp._registrar_ajuste(erp._titulo_em_revisao_da_nota(old.id), 'documentos_fiscais',
      to_jsonb(old) - 'situacao' - 'cancelamento' - 'lancado_em', to_jsonb(new) - 'situacao' - 'cancelamento' - 'lancado_em');
  end if;
  if tg_op = 'UPDATE' and new.lancado_em is distinct from old.lancado_em and not erp.agindo_como('erp_situacao') then
    raise exception 'A situação do documento muda pelo lançamento';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_documento before insert or update or delete on erp.documentos_fiscais
  for each row execute function erp.tg_documento();

-- ---------------------------------------------------------------------
-- Pagamento e quitação → livro (estágio realizado)
-- O pagamento entra inteiro em "Adiantamentos" (movimentação), já carimbado com núcleo e centro;
-- cada quitação tira dali e lança na natureza do título. Pagamento sem quitação
-- é adiantamento, abatido depois por novas quitações, em vários títulos.
-- ---------------------------------------------------------------------
create function erp.tg_pagamento() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Pagamento não se altera; o estorno virá no módulo de bancos'; end if;
  if (select empresa_id from erp.contas_bancarias where id = new.conta_id) <> new.empresa_id then
    raise exception 'A conta não é da empresa do pagamento';
  end if;
  if new.pessoa_id is distinct from (select pessoa_id from erp.empresas where id = new.empresa_id)
     and (new.nucleo_economico_id is null or new.centro_custo_id is null) then
    raise exception 'Pagamento e adiantamento saem carimbados com núcleo econômico e centro de custo (e a divisão, se o centro tiver; só a transferência entre contas próprias dispensa)';
  end if;
  if new.nucleo_economico_id is not null
     and (select empresa_id from erp.nucleos_economicos where id = new.nucleo_economico_id) <> new.empresa_id then
    raise exception 'O núcleo econômico não é da empresa do pagamento';
  end if;
  perform erp.checar_centro(new.nucleo_economico_id, new.centro_custo_id, new.empresa_id);
  if new.adiantamento_id is not null then perform erp._pagar_pedido_adiantamento(new); end if;
  insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_caixa, valor, pagamento_id)
  values ('realizado', new.empresa_id, new.nucleo_economico_id, new.centro_custo_id, new.divisao_id, erp.natureza_sistema('adiantamentos'),
          erp.mes(new.data), new.data, -new.valor, new.id);
  return new;
end $$;
create trigger t_pagamento after insert or update or delete on erp.pagamentos
  for each row execute function erp.tg_pagamento();

-- Adiantamento passa pela mesma alçada (S-061): o dinheiro que sobra do pagamento depois das
-- quitações da transação é adiantamento, e só sai ligado a um pedido aprovado. Conferido no fim
-- da transação, porque o pagamento nasce antes das quitações que o consomem.
create function erp.tg_adiantamento_sem_pedido() returns trigger language plpgsql as $$
begin
  if new.adiantamento_id is null
     and new.pessoa_id is distinct from (select pessoa_id from erp.empresas where id = new.empresa_id)
     and erp._pagamento_saldo(new.id) > 0 then
    raise exception 'Adiantamento só sai ligado a um pedido de adiantamento aprovado na alçada';
  end if;
  return null;
end $$;
create constraint trigger t_adiantamento_pedido after insert on erp.pagamentos
  deferrable initially deferred for each row execute function erp.tg_adiantamento_sem_pedido();

create function erp._parcela_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(principal) from erp.quitacoes where parcela_id = p.id), 0)
  from erp.parcelas p where p.id = p_id $$;

create function erp._pagamento_saldo(p_id uuid) returns numeric language sql stable as $$
  select g.valor - coalesce((select sum(principal + juros + multa - desconto) from erp.quitacoes where pagamento_id = g.id), 0)
  from erp.pagamentos g where g.id = p_id $$;

-- Saldos para quem consulta (S-034): o mesmo número, só de registro que a pessoa vê; de outro,
-- nulo. As travas por dentro usam as versões com _, que veem tudo e não têm EXECUTE para a API.
create function erp.previsao_saldo(p_id uuid) returns numeric language plpgsql stable as $$
begin
  if erp.sistema() or erp.vejo_previsao(p_id) then return erp._previsao_saldo(p_id); end if;
  return null;
end $$;
create function erp.parcela_saldo(p_id uuid) returns numeric language plpgsql stable as $$
begin
  if erp.sistema() or erp.vejo_titulo((select titulo_id from erp.parcelas where id = p_id)) then
    return erp._parcela_saldo(p_id);
  end if;
  return null;
end $$;
create function erp.pagamento_saldo(p_id uuid) returns numeric language plpgsql stable as $$
begin
  if erp.sistema() or erp.vejo_pagamento(p_id) then return erp._pagamento_saldo(p_id); end if;
  return null;
end $$;

-- ---------------------------------------------------------------------
-- Adiantamento em aberto (decisões do Moises de 7/11 e 14/11/2026, configuráveis)
-- O título do fornecedor não é pago sem antes abater o adiantamento em aberto dele.
-- Adiantamento só abate título do mesmo núcleo e centro do carimbo; em outro, só com
-- aprovação de quem está nas listas escolhidas (padrão AF, AO ou AD). Pagar sem abater,
-- só com liberação (padrão AD). O administrador muda a regra, com auditoria.
-- ---------------------------------------------------------------------
create table erp.listas_financeiro (            -- quem está em cada lista de aprovação do financeiro
  lista   text not null check (lista in ('AF','AO','AD')),
  user_id uuid not null references erp.usuarios,
  -- quem está na AD pode, pessoa a pessoa, aprovar o próprio lançamento, com aviso (Moises, 7/nov/2026)
  aprova_proprio boolean not null default false check (not aprova_proprio or lista = 'AD'),
  avisa_proprio  boolean not null default true,
  primary key (lista, user_id)
);
create function erp.tg_so_admin() returns trigger language plpgsql as $$
begin
  -- papéis de aprovação: também pelo pedido de acesso aprovado (erp_acesso, migration _erp_perfis)
  -- configuração de dinheiro: também pelo pedido de mudança aprovado (erp_config, migration _erp_config)
  if not (erp.agindo_como('erp_acesso') and tg_table_name in ('listas_financeiro', 'centro_aprovadores', 'usuarios'))
     and not (erp.agindo_como('erp_config') and tg_table_name in ('alcadas_pagamento', 'niveis_aprovacao', 'naturezas_sistema',
                                                       'contas_bancarias', 'codigos_externos')) then
    perform erp.exigir_admin();
  end if;
  return coalesce(new, old);
end $$;
create trigger t_listas_financeiro before insert or update or delete on erp.listas_financeiro
  for each row execute function erp.tg_so_admin();
create trigger t_aud_listas_financeiro after insert or update or delete on erp.listas_financeiro
  for each row execute function erp.tg_auditoria('user_id');

-- Configuração e cadastros sensíveis (S-055): só o administrador (ou o sistema) grava, com auditoria.
-- Em usuarios, ninguém muda o próprio papel, acesso ou login, nem se apaga.
create function erp.tg_usuario() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.id <> old.id then raise exception 'O id do usuário não muda'; end if;
  if tg_op <> 'INSERT' and old.id = erp.eu()
     and (tg_op = 'DELETE' or (to_jsonb(new) - 'nome') <> (to_jsonb(old) - 'nome')) then
    raise exception 'Ninguém muda o próprio papel, acesso ou login';
  end if;
  return coalesce(new, old);
end $$;
do $$
declare t record;
begin
  for t in select * from (values ('usuarios', 'id'), ('naturezas_sistema', 'chave'),
                                 ('contas_bancarias', 'id'), ('codigos_externos', 'registro_id')) v(tabela, chave) loop
    execute format('create trigger t_so_admin before insert or update or delete on erp.%I
                      for each row execute function erp.tg_so_admin()', t.tabela);
    execute format('create trigger t_aud_%s after insert or update or delete on erp.%I
                      for each row execute function erp.tg_auditoria(%L)', t.tabela, t.tabela, t.chave);
  end loop;
end $$;
create trigger t_usuario before update or delete on erp.usuarios
  for each row execute function erp.tg_usuario();

create table erp.regra_adiantamento (
  id                  boolean primary key default true check (id),   -- uma linha só
  trava               boolean not null default true,
  aprova_cruzado      text[] not null default '{AF,AO,AD}'
                      check (cardinality(aprova_cruzado) > 0 and aprova_cruzado <@ '{AF,AO,AD}'),
  libera_sem_abater   text[] not null default '{AD}'
                      check (cardinality(libera_sem_abater) > 0 and libera_sem_abater <@ '{AF,AO,AD}')
);
insert into erp.regra_adiantamento default values;
create function erp.tg_regra_adiantamento() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_config') then perform erp.exigir_admin(); end if;   -- pedido aprovado (_erp_config)
  if tg_op <> 'UPDATE' then raise exception 'A regra do adiantamento é uma só; altere os valores'; end if;
  return new;
end $$;
create trigger t_regra_adiantamento before insert or update or delete on erp.regra_adiantamento
  for each row execute function erp.tg_regra_adiantamento();
create trigger t_aud_regra_adiantamento after update on erp.regra_adiantamento
  for each row execute function erp.tg_auditoria('id');

create function erp.estou_nas_listas(p_listas text[]) returns boolean language sql stable as $$
  select exists (select 1 from erp.listas_financeiro l join erp.usuarios u on u.id = l.user_id
                 where l.user_id = erp.eu() and u.ativo and l.lista = any(p_listas)) $$;

-- Quem aprova o próprio lançamento: o master, sempre (Moises, 14/11/2026), e quem está na AD com a
-- marca aprova_proprio, quando a AD está entre as listas da aprovação (Moises, 7/nov/2026).
create function erp.aprova_proprio(p_listas text[]) returns boolean language plpgsql stable as $$
begin
  return erp.sou_master()
      or ('AD' = any (p_listas)
          and exists (select 1 from erp.listas_financeiro l join erp.usuarios u on u.id = l.user_id and u.ativo
                       where l.lista = 'AD' and l.user_id = erp.eu() and l.aprova_proprio));
end $$;

-- A regra vigente (security definer na migration _erp_rls: a trava lê a regra por baixo do RLS).
create function erp.regra_adiantamento_atual() returns erp.regra_adiantamento language sql stable as
  $$ select * from erp.regra_adiantamento $$;

-- Abatimento de adiantamento em título de outro núcleo ou centro: aprovação registrada.
create table erp.abatimentos_cruzados (
  pagamento_id  uuid not null references erp.pagamentos,
  titulo_id     uuid not null references erp.titulos,
  justificativa text not null check (length(trim(justificativa)) > 0),
  aprovado_por  uuid not null default erp.eu(),
  aprovado_em   timestamptz not null default clock_timestamp(),
  primary key (pagamento_id, titulo_id)
);
-- Liberação para pagar o título sem abater o adiantamento em aberto do fornecedor. Cobre só os
-- adiantamentos que já existiam na hora da liberação; um novo pede nova liberação.
create table erp.liberacoes_sem_abater (
  id            uuid primary key default gen_random_uuid(),
  titulo_id     uuid not null references erp.titulos,
  justificativa text not null check (length(trim(justificativa)) > 0),
  aprovado_por  uuid not null default erp.eu(),
  aprovado_em   timestamptz not null default clock_timestamp()
);
-- ---------------------------------------------------------------------
-- Alçada de pagamento (decisão do Moises, 14/11/2026; piloto no Marketing)
-- Vale para o título a pagar com rateio num centro de custo que tem gestor aprovador cadastrado.
-- Pelo acumulado do mês do centro (somando o próprio título): até 50 mil, gestor da área e
-- depois AF; acima, gestor da área, AF e AD. Faixas, fases e como se soma o acumulado são
-- configuração do administrador, com auditoria. A alçada é fixada quando o título é confirmado;
-- as fases são em sequência, quem lançou não aprova, e cada pessoa aprova uma fase só.
-- O título não é quitado sem a alçada completa.
-- ---------------------------------------------------------------------
create table erp.centro_aprovadores (          -- gestor da área (aprovador nominal do centro)
  centro_custo_id uuid not null references erp.centros_custo,
  user_id         uuid not null references erp.usuarios,
  primary key (centro_custo_id, user_id)
);
create trigger t_so_admin before insert or update or delete on erp.centro_aprovadores
  for each row execute function erp.tg_so_admin();
create trigger t_aud_centro_aprovadores after insert or update or delete on erp.centro_aprovadores
  for each row execute function erp.tg_auditoria('centro_custo_id');
-- O último gestor do centro não sai enquanto houver título esperando por ele (S-066); o mesmo
-- vale para o último diretor da área (centro_diretores, migration _erp_perfis), com a vaga
-- DIRETOR_AREA pendente.
create function erp.tg_centro_aprovador() returns trigger language plpgsql as $$
declare v_vaga text := case tg_table_name when 'centro_diretores' then 'DIRETOR_AREA' else 'AREA' end;
begin
  if not (case v_vaga when 'AREA' then exists (select 1 from erp.centro_aprovadores
                                                where centro_custo_id = old.centro_custo_id and user_id <> old.user_id)
                      else exists (select 1 from erp.centro_diretores
                                    where centro_custo_id = old.centro_custo_id and user_id <> old.user_id) end)
     and exists (select 1 from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id
                  where a.centro_custo_id = old.centro_custo_id and t.situacao = 'aberto' and t.rodada = a.rodada
                    and not erp.alcada_recusada(a.titulo_id)
                    and exists (select 1 from generate_subscripts(a.fases, 1) i
                                 where a.fases[i] = v_vaga
                                   and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id
                                                    and v.fase = i and v.aprovado))) then
    if v_vaga = 'AREA' then raise exception 'O centro tem títulos esperando o gestor da área; cadastre outro gestor antes'; end if;
    raise exception 'O centro tem títulos esperando o diretor da área; cadastre outro diretor antes';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_centro_aprovador before update or delete on erp.centro_aprovadores
  for each row execute function erp.tg_centro_aprovador();

-- Faixas por centro de custo (Moises, 15/11/2026): o centro com faixas próprias usa as dele; os
-- outros, as gerais (centro nulo). Cada faixa tem dois limites, o acumulado do mês no centro e o
-- valor do título; o título cai na faixa mais exigente das duas contas. Cada faixa tem as vagas de
-- aprovação (fases): um papel (AREA = gestor da área, DIRETOR_AREA = diretor da área, AF, AO, AD)
-- ou uma pessoa pelo nome ('P:' e o id do usuário), que não precisa ter cargo. O número de
-- aprovadores é o número de vagas; a mesma pessoa não ocupa duas. Em sequência (padrão) ou em
-- paralelo. Sem gente qualificada para preencher as vagas, o título vai ao master, com o motivo.
-- Faixas da divisão (Moises, 15/11/2026): a divisão com faixas próprias tem a alçada dela, com o
-- acumulado do mês só da divisão; a faixa diz se a linha também passa pela alçada do centro
-- (passa_pelo_centro), que soma o centro inteiro. Divisão sem faixas próprias segue o centro.
create table erp.alcadas_pagamento (
  id              uuid primary key default gen_random_uuid(),
  centro_custo_id uuid references erp.centros_custo,   -- nulo: as faixas gerais
  divisao_id      uuid,                                   -- nulo: faixa do centro (ou geral)
  ate             numeric(15,2) check (ate > 0),          -- acumulado do mês até este valor; nulo = sem limite
  ate_titulo      numeric(15,2) check (ate_titulo > 0),   -- valor do título até este valor; nulo = sem limite
  fases          text[] not null check (cardinality(fases) > 0),
  paralelo        boolean not null default false,
  passa_pelo_centro boolean not null default false,       -- só na faixa da divisão
  unique nulls not distinct (centro_custo_id, divisao_id, ate, ate_titulo),
  foreign key (divisao_id, centro_custo_id) references erp.divisoes (id, centro_custo_id),
  check (divisao_id is null or centro_custo_id is not null),
  check (divisao_id is not null or not passa_pelo_centro)
);
-- a vaga: um papel ou uma pessoa ativa que pode aprovar (nem administrador, nem só da sucessão)
create function erp.tg_alcada_vagas() returns trigger language plpgsql as $$
declare e text; v_user uuid;
begin
  if tg_op = 'DELETE' then return old; end if;
  foreach e in array new.fases loop
    if e in ('AREA','DIRETOR_AREA','AF','AO','AD') then continue; end if;
    if e !~ '^P:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      raise exception 'Vaga de aprovação inválida: % (use AREA, DIRETOR_AREA, AF, AO, AD ou P: e o usuário)', e;
    end if;
    v_user := substr(e, 3)::uuid;
    if not exists (select 1 from erp.usuarios where id = v_user) then raise exception 'Aprovador da vaga não existe: %', v_user; end if;
    perform erp.recusar_admin_aprovador(v_user);
    perform erp.recusar_so_sucessao(v_user);
  end loop;
  if (select count(*) from unnest(new.fases) x where x like 'P:%') <> (select count(distinct x) from unnest(new.fases) x where x like 'P:%') then
    raise exception 'A mesma pessoa não ocupa duas vagas da faixa';
  end if;
  return new;
end $$;
insert into erp.alcadas_pagamento (ate, fases) values (50000, '{AREA,AF}'), (null, '{AREA,AF,AD}');
create trigger t_so_admin before insert or update or delete on erp.alcadas_pagamento
  for each row execute function erp.tg_so_admin();
create trigger t_alcada_vagas before insert or update on erp.alcadas_pagamento
  for each row execute function erp.tg_alcada_vagas();
create trigger t_aud_alcadas_pagamento after insert or update or delete on erp.alcadas_pagamento
  for each row execute function erp.tg_auditoria('id');

create table erp.regra_alcada_pagamento (
  id        boolean primary key default true check (id),   -- uma linha só
  -- como somar o acumulado do mês: o centro no grupo todo (padrão), o centro na empresa,
  -- ou o centro dentro do núcleo econômico
  acumulado text not null default 'centro' check (acumulado in ('centro','empresa_centro','nucleo_centro')),
  -- o acumulado do centro soma também o que o mesmo fornecedor tem no mês em outros centros (S-063)
  soma_fornecedor boolean not null default true,
  -- competência da nota e do título avulso: no máximo N meses antes ou depois do mês da emissão;
  -- fora disso, só com exceção aprovada por quem está nas listas (S-063)
  competencia_meses_antes  int not null default 1 check (competencia_meses_antes >= 0),
  competencia_meses_depois int not null default 1 check (competencia_meses_depois >= 0),
  excecao_competencia      text[] not null default '{AF,AD}'
                           check (cardinality(excecao_competencia) > 0 and excecao_competencia <@ '{AF,AO,AD}')
);
insert into erp.regra_alcada_pagamento default values;
create function erp.tg_regra_alcada() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_config') then perform erp.exigir_admin(); end if;   -- pedido aprovado (_erp_config)
  if tg_op <> 'UPDATE' then raise exception 'A regra da alçada de pagamento é uma só; altere os valores'; end if;
  return new;
end $$;
create trigger t_regra_alcada before insert or update or delete on erp.regra_alcada_pagamento
  for each row execute function erp.tg_regra_alcada();
create trigger t_aud_regra_alcada after update on erp.regra_alcada_pagamento
  for each row execute function erp.tg_auditoria('id');

-- A alçada fixada na confirmação, uma por centro de custo do rateio (Moises, 15/11/2026): cada
-- centro tem a sua aprovação, com o valor do título no centro, o acumulado do centro e o rito
-- (as vagas) da faixa do centro. O título só está aprovado quando todos os centros aprovaram; a
-- mesma pessoa que ocupa vaga em dois centros aprova nos dois. A divisão com faixas próprias tem
-- a alçada dela (divisao_id), além da do centro quando a faixa manda passar pelo centro.
create table erp.titulo_alcadas (
  id              uuid primary key default gen_random_uuid(),
  titulo_id       uuid not null references erp.titulos,
  rodada          int not null default 1,       -- a volta da alçada (titulos.rodada)
  centro_custo_id uuid not null references erp.centros_custo,
  divisao_id      uuid references erp.divisoes, -- nulo: a alçada do centro
  fases          text[] not null,
  paralelo        boolean not null default false,
  valor_no_centro numeric(15,2) not null,       -- a parte do título no centro ou na divisão (o limite do título olha o título inteiro)
  acumulado       numeric(15,2) not null,
  titulos         uuid[] not null,              -- os títulos que formaram o acumulado (S-064)
  alcada_id       uuid,                         -- a faixa que decidiu
  -- sem gente qualificada para todas as vagas na confirmação: vai ao master (que sempre decide),
  -- com o aviso do motivo; quem passar a ocupar a vaga depois também decide
  falta_aprovadores boolean not null default false,
  vagas_sem_gente   text[] not null default '{}',
  definida_em     timestamptz not null default clock_timestamp(),
  unique nulls not distinct (titulo_id, rodada, centro_custo_id, divisao_id)
);
create table erp.titulo_aprovacoes (
  alcada_id     uuid not null references erp.titulo_alcadas,   -- a alçada (centro ou divisão) em que a fase está
  titulo_id     uuid not null references erp.titulos,           -- titulo_id, rodada, centro e divisão: copiados da alçada
  rodada        int not null default 1,
  centro_custo_id uuid not null,
  divisao_id    uuid,
  fase         int not null,                    -- posição em titulo_alcadas.fases, de 1
  lista         text not null,
  aprovado      boolean not null,
  justificativa text,
  por           uuid not null,
  em            timestamptz not null default clock_timestamp(),
  primary key (alcada_id, fase),
  -- decisao: quem decidiu é quem gravou; ajuste: quem ajustou na revisão (_aprovar_pelo_ajuste);
  -- outra_alcada: a aprovação da mesma pessoa na divisão vale no centro, e vice-versa (vale_de)
  origem        text not null default 'decisao' check (origem in ('decisao','ajuste','outra_alcada')),
  vale_de       uuid references erp.titulo_alcadas,
  check ((origem = 'outra_alcada') = (vale_de is not null)),
  proprio       boolean not null default false,  -- quem aprovou lançou o título (master ou AD autorizada): sai o aviso
  check (aprovado or length(trim(coalesce(justificativa, ''))) > 0),
  check (origem <> 'ajuste' or (aprovado and lista in ('AREA','AF'))),
  check (origem <> 'outra_alcada' or aprovado)
);
-- só pelas operações do banco (confirmar_titulo e decidir_titulo), e não mudam
create function erp.tg_alcada_titulo() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'A alçada do título não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then
    raise exception 'A alçada do título só se grava pela confirmação e pela aprovação';
  end if;
  if tg_table_name = 'titulo_aprovacoes' then
    if new.origem = 'decisao' then new.por := erp.autor(); end if;
    if new.origem = 'outra_alcada' and not exists (
         select 1 from erp.titulo_aprovacoes v join erp.titulo_alcadas a1 on a1.id = v.alcada_id
           join erp.titulo_alcadas a2 on a2.id = new.alcada_id
          where v.alcada_id = new.vale_de and v.por = new.por and v.aprovado and v.origem = 'decisao'
            and a1.titulo_id = a2.titulo_id and a1.rodada = a2.rodada and a1.centro_custo_id = a2.centro_custo_id
            and a1.id <> a2.id and (a1.divisao_id is null or a2.divisao_id is null)) then
      raise exception 'A aprovação na outra alçada precisa ser da mesma pessoa, no mesmo centro do título';
    end if;
    new.em := clock_timestamp();
    select a.titulo_id, a.rodada, a.centro_custo_id, a.divisao_id into new.titulo_id, new.rodada, new.centro_custo_id, new.divisao_id
      from erp.titulo_alcadas a where a.id = new.alcada_id;
  end if;
  return new;
end $$;
create trigger t_alcada_titulo before insert or update or delete on erp.titulo_alcadas
  for each row execute function erp.tg_alcada_titulo();
create trigger t_alcada_titulo before insert or update or delete on erp.titulo_aprovacoes
  for each row execute function erp.tg_alcada_titulo();

-- Pedido de revisão (decisões do Moises, 14/11/2026): o aprovador da fase pede um ajuste com
-- motivo; o título fica aberto e no livro, não é aprovado nem pago enquanto a revisão está
-- aberta. Quem lançou, o gestor da área e o AF ajustam qualquer coisa (o título avulso direto; o
-- de nota, pela nota) e reenviam; a alçada recomeça do zero, numa volta nova.
create table erp.titulo_revisoes (
  id            uuid primary key default gen_random_uuid(),
  titulo_id     uuid not null references erp.titulos,
  rodada        int not null,
  centro_custo_id uuid,                          -- o centro da fase que pediu
  alcada_id     uuid references erp.titulo_alcadas,  -- a alçada (centro ou divisão) da fase que pediu
  fase         int not null,
  motivo        text not null check (length(trim(motivo)) > 0),
  pedida_por    uuid not null,
  pedida_em     timestamptz not null default clock_timestamp(),
  resposta      text,
  reenviada_por uuid,
  reenviada_em  timestamptz,
  check ((reenviada_em is null) = (reenviada_por is null) and (reenviada_em is null) = (resposta is null))
);
create unique index titulo_revisoes_aberta on erp.titulo_revisoes (titulo_id) where reenviada_em is null;
create function erp.tg_titulo_revisao() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'A revisão do título não se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then
    raise exception 'A revisão do título só se grava pela aprovação e pelo reenvio';
  end if;
  if tg_op = 'INSERT' then
    new.pedida_por := erp.autor();
    new.pedida_em := clock_timestamp();
    new.resposta := null; new.reenviada_por := null; new.reenviada_em := null;
  else
    if old.reenviada_em is not null
       or (to_jsonb(new) - 'resposta' - 'reenviada_por' - 'reenviada_em') <> (to_jsonb(old) - 'resposta' - 'reenviada_por' - 'reenviada_em') then
      raise exception 'A revisão do título já foi respondida';
    end if;
    new.reenviada_por := erp.autor();
    new.reenviada_em := clock_timestamp();
  end if;
  return new;
end $$;
create trigger t_titulo_revisao before insert or update or delete on erp.titulo_revisoes
  for each row execute function erp.tg_titulo_revisao();
create function erp.em_revisao(p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.titulo_revisoes where titulo_id = p_titulo and reenviada_em is null) $$;
-- Quem ajusta o título em revisão: quem lançou, quem está no AF e o gestor ativo de um centro do
-- rateio. (O escopo de núcleo, centro e natureza de cada um entra com os perfis, no primeiro grant.)
-- S-073: além do papel, o escopo: quem ajusta lança em todas as linhas que o título tem agora
-- (no meio do ajuste, sem linha nenhuma, não há o que conferir: tirar as linhas já exigiu lançar
-- nelas); as linhas novas, a política de gravação do rateio confere uma a uma.
create function erp.pode_ajustar(p_titulo uuid) returns boolean language plpgsql stable as $$
begin return (erp.eu() is not null
    and (erp.sou_master() or not exists (select 1 from erp.titulo_rateios r join erp.titulos t on t.id = r.titulo_id
                                          where r.titulo_id = p_titulo
                                            and not erp.lanco(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, t.criado_por, r.divisao_id)))
    and (
         erp.autor_lancamento('titulo', p_titulo) = erp.eu()
      or erp.estou_nas_listas(array['AF'])
      or exists (select 1 from erp.titulo_rateios tr join erp.centro_aprovadores c on c.centro_custo_id = tr.centro_custo_id
                 join erp.usuarios u on u.id = c.user_id and u.ativo
                  where tr.titulo_id = p_titulo and c.user_id = erp.eu()))); end $$;
-- Título avulso ou pedido em revisão, e quem grava pode ajustar?
create function erp._ajustavel(p_titulo uuid) returns boolean language plpgsql stable as $$
begin return (exists (select 1 from erp.titulos where id = p_titulo and documento_id is null)
     and erp.em_revisao(p_titulo) and erp.pode_ajustar(p_titulo)); end $$;
-- O título do fornecedor da nota que está em revisão.
create function erp._titulo_em_revisao_da_nota(p_documento uuid) returns uuid language plpgsql stable as $$
begin return (select t.id from erp.titulos t where t.documento_id = p_documento and t.tipo = 'fornecedor'
                 and t.situacao = 'aberto' and erp.em_revisao(t.id)); end $$;
-- Nota com o título do fornecedor em revisão, e quem grava pode ajustar?
create function erp._nota_ajustavel(p_documento uuid) returns boolean language plpgsql stable as $$
begin return (exists (select 1 from erp.titulos t where t.documento_id = p_documento and t.tipo = 'fornecedor'
                  and t.situacao = 'aberto' and erp.em_revisao(t.id) and erp.pode_ajustar(t.id))); end $$;

-- O que cada um pode mudar no ajuste da revisão: uma linha por campo e por quem ajusta (AF, o
-- gestor da área, quem lançou). Em número e data, também para que lado: só para mais, só para
-- menos ou os dois. "linhas" é incluir ou tirar parcela, linha do rateio ou retenção. O admin muda
-- os valores (com auditoria); as linhas são fixas. Começa tudo liberado, para os dois lados
-- (decisão do Moises, 14/11). Quem tem mais de um papel pode o que algum deles pode.
create table erp.regras_ajuste (
  campo     text not null,                 -- tabela.coluna, ou tabela.linhas
  quem      text not null check (quem in ('AF','AREA','AUTOR')),
  rotulo    text not null,
  tipo      text not null check (tipo in ('numero','data','outro')),
  permitido boolean not null default true,
  direcao   text not null default 'ambos' check (direcao in ('ambos','maior','menor')),
  primary key (campo, quem),
  check (direcao = 'ambos' or tipo in ('numero','data'))
);
insert into erp.regras_ajuste (campo, quem, rotulo, tipo)
select c.campo, q.quem, c.rotulo, c.tipo from (values
  ('titulos.pessoa_id', 'o fornecedor do título', 'outro'), ('titulos.numero', 'o número do título', 'outro'),
  ('titulos.emissao', 'a emissão do título', 'data'), ('titulos.competencia', 'a competência do título', 'data'),
  ('titulos.valor', 'o valor do título', 'numero'), ('titulos.descricao', 'a descrição do título', 'outro'),
  ('parcelas.linhas', 'as parcelas (incluir ou tirar)', 'outro'), ('parcelas.numero', 'o número da parcela', 'outro'),
  ('parcelas.vencimento', 'o vencimento da parcela', 'data'), ('parcelas.valor', 'o valor da parcela', 'numero'),
  ('titulo_rateios.linhas', 'as linhas do rateio (incluir ou tirar)', 'outro'),
  ('titulo_rateios.nucleo_economico_id', 'o núcleo econômico do rateio', 'outro'),
  ('titulo_rateios.centro_custo_id', 'o centro de custo do rateio', 'outro'),
  ('titulo_rateios.natureza_id', 'a natureza do rateio', 'outro'),
  ('titulo_rateios.divisao_id', 'a divisão do rateio', 'outro'),
  ('titulo_rateios.percentual', 'o percentual do rateio', 'outro'),
  ('documentos_fiscais.emitente_id', 'o emitente da nota', 'outro'), ('documentos_fiscais.tipo', 'o tipo da nota', 'outro'),
  ('documentos_fiscais.numero', 'o número da nota', 'outro'), ('documentos_fiscais.serie', 'a série da nota', 'outro'),
  ('documentos_fiscais.emissao', 'a emissão da nota', 'data'), ('documentos_fiscais.competencia', 'a competência da nota', 'data'),
  ('documentos_fiscais.valor_bruto', 'o valor bruto da nota', 'numero'), ('documentos_fiscais.caucao_valor', 'a caução da nota', 'numero'),
  ('documento_rateios.linhas', 'as linhas do rateio da nota (incluir ou tirar)', 'outro'),
  ('documento_rateios.nucleo_economico_id', 'o núcleo econômico do rateio da nota', 'outro'),
  ('documento_rateios.centro_custo_id', 'o centro de custo do rateio da nota', 'outro'),
  ('documento_rateios.natureza_id', 'a natureza do rateio da nota', 'outro'),
  ('documento_rateios.divisao_id', 'a divisão do rateio da nota', 'outro'),
  ('documento_rateios.percentual', 'o percentual do rateio da nota', 'outro'),
  ('documento_retencoes.linhas', 'as retenções da nota (incluir ou tirar)', 'outro'),
  ('documento_retencoes.imposto', 'o imposto retido', 'outro'), ('documento_retencoes.orgao_id', 'o órgão da retenção', 'outro'),
  ('documento_retencoes.valor', 'o valor da retenção', 'numero'), ('documento_retencoes.vencimento', 'o vencimento da retenção', 'data')
) c(campo, rotulo, tipo) cross join (values ('AF'), ('AREA'), ('AUTOR')) q(quem);
create function erp.tg_regras_ajuste() returns trigger language plpgsql as $$
begin
  if not erp.agindo_como('erp_config') then perform erp.exigir_admin(); end if;   -- pedido aprovado (_erp_config)
  if tg_op <> 'UPDATE' or (new.campo, new.quem, new.rotulo, new.tipo) is distinct from (old.campo, old.quem, old.rotulo, old.tipo) then
    raise exception 'As regras do ajuste são fixas; altere só se pode e para que lado';
  end if;
  return new;
end $$;
create trigger t_regras_ajuste before insert or update or delete on erp.regras_ajuste
  for each row execute function erp.tg_regras_ajuste();
create trigger t_aud_regras_ajuste after update on erp.regras_ajuste
  for each row execute function erp.tg_auditoria('campo');

-- O título e todos os que ele substituiu na revisão de nota (substitui_id, a cadeia inteira; S-075).
create function erp.cadeia_titulo(p_titulo uuid) returns setof uuid language sql stable as $$
  with recursive c(id) as (select p_titulo union select t.substitui_id from erp.titulos t join c on t.id = c.id
                                                    where t.substitui_id is not null)
  select id from c $$;

-- O que cada pessoa mudou no ajuste de cada revisão (S-071): a trilha do ajuste, e quem ajustou
-- não aprova a volta nova. Só cresce, e só pelas travas do ajuste.
create table erp.titulo_ajustes (
  id         uuid primary key default gen_random_uuid(),
  revisao_id uuid not null references erp.titulo_revisoes,
  titulo_id  uuid not null references erp.titulos,
  tabela     text not null,
  antes      jsonb,                                -- nulo: linha incluída
  depois     jsonb,                                -- nulo: linha tirada
  por        uuid not null,
  em         timestamptz not null default clock_timestamp()
);
create function erp.tg_titulo_ajuste() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'O registro do ajuste não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then raise exception 'O registro do ajuste só é escrito pelas travas do ajuste'; end if;
  new.por := erp.autor();
  new.em := clock_timestamp();
  return new;
end $$;
create trigger t_titulo_ajuste before insert or update or delete on erp.titulo_ajustes
  for each row execute function erp.tg_titulo_ajuste();
-- registra a linha mudada (security definer erp_situacao na migration _erp_rls)
create function erp._registrar_ajuste(p_titulo uuid, p_tabela text, p_antes jsonb, p_depois jsonb)
returns void language plpgsql as $$
declare v_rev uuid := (select id from erp.titulo_revisoes where titulo_id = p_titulo and reenviada_em is null);
begin
  -- Os gatilhos das tabelas ajustáveis chamam esta função, por isso a API pode chamá-la. Chamada
  -- direta (fora de gatilho) forjaria a trilha e a aprovação pelo ajuste: recusada. Dentro do
  -- gatilho, só quem pode ajustar o título em revisão.
  if not erp.sistema() and pg_trigger_depth() = 0 then
    raise exception 'O ajuste só se registra pela mudança na tabela';
  end if;
  if v_rev is null or p_antes is not distinct from p_depois then return; end if;
  if not erp.sistema() and not erp.pode_ajustar(p_titulo) then
    raise exception 'Só quem pode ajustar registra o ajuste';
  end if;
  insert into erp.titulo_ajustes (revisao_id, titulo_id, tabela, antes, depois, por)
  values (v_rev, p_titulo, p_tabela, p_antes, p_depois, erp.eu());
end $$;

-- Confere uma linha mudada no ajuste da revisão contra as regras (security definer na migration
-- _erp_rls). p_titulo é o título em revisão (o do fornecedor, quando o ajuste é na nota).
create function erp.conferir_ajuste(p_titulo uuid, p_tabela text, p_antes jsonb, p_depois jsonb)
returns void language plpgsql stable as $$
declare v_papeis text[] := '{}'; v_doc uuid; k text; v_campo text; v_sent int; v_tipo text; v_rotulo text; v_dir text[];
begin
  select documento_id into v_doc from erp.titulos where id = p_titulo;
  if erp.estou_nas_listas(array['AF']) then v_papeis := v_papeis || 'AF'::text; end if;
  if exists (select 1 from erp.titulo_rateios tr join erp.centro_aprovadores c on c.centro_custo_id = tr.centro_custo_id
             join erp.usuarios u on u.id = c.user_id and u.ativo
              where tr.titulo_id = p_titulo and c.user_id = erp.eu()) then
    v_papeis := v_papeis || 'AREA'::text;
  end if;
  if erp.eu() in (erp.autor_lancamento('titulo', p_titulo), erp.autor_lancamento('documento', v_doc)) then
    v_papeis := v_papeis || 'AUTOR'::text;
  end if;
  -- linha incluída: "linhas" e cada campo dela, comparado a nada (S-072); tirada: só "linhas"
  for k in
    select '.linhas' where p_antes is null or p_depois is null
    union all
    select '.' || n.key from jsonb_each(p_depois) n
     where n.value is distinct from coalesce(p_antes -> n.key, case when p_antes is null then 'null'::jsonb end)
  loop
    v_campo := p_tabela || k;
    select min(tipo), min(rotulo) into v_tipo, v_rotulo from erp.regras_ajuste where campo = v_campo;
    if v_tipo is null then raise exception 'O ajuste não muda %', v_campo; end if;
    v_sent := 0;
    if k <> '.linhas' and p_antes is not null and v_tipo = 'numero' then
      v_sent := sign((p_depois ->> substr(k, 2))::numeric - (p_antes ->> substr(k, 2))::numeric);
    elsif k <> '.linhas' and p_antes is not null and v_tipo = 'data' then
      v_sent := sign((p_depois ->> substr(k, 2))::date - (p_antes ->> substr(k, 2))::date);
    end if;
    select array_agg(distinct direcao) into v_dir from erp.regras_ajuste
     where campo = v_campo and quem = any(v_papeis) and permitido;
    if v_dir is null then
      raise exception 'No ajuste, você não pode mudar %', v_rotulo;
    end if;
    if k <> '.linhas' and p_antes is null and not 'ambos' = any(v_dir) then
      raise exception 'No ajuste, % só muda para um lado; não entra em linha nova', v_rotulo;
    end if;
    if v_sent <> 0 and not ('ambos' = any(v_dir) or (v_sent > 0 and 'maior' = any(v_dir)) or (v_sent < 0 and 'menor' = any(v_dir))) then
      raise exception 'No ajuste, % só pode mudar para %', v_rotulo,
        case when v_sent > 0 then 'menos' else 'mais' end;
    end if;
  end loop;
end $$;

-- Exceção à janela da competência, para uma nota ou um título avulso (S-063).
create table erp.excecoes_competencia (
  id            uuid primary key default gen_random_uuid(),
  documento_id  uuid references erp.documentos_fiscais,
  titulo_id     uuid references erp.titulos,
  competencia   date,                            -- a competência aprovada; mudou, a exceção não vale
  justificativa text not null check (length(trim(justificativa)) > 0),
  aprovado_por  uuid,
  aprovado_em   timestamptz not null default clock_timestamp(),
  check (num_nonnulls(documento_id, titulo_id) = 1)
);
create function erp.tg_excecao_competencia() returns trigger language plpgsql as $$
declare v_listas text[] := (select excecao_competencia from erp.regra_alcada_pagamento);
begin
  if tg_op <> 'INSERT' then raise exception 'Exceção de competência não se altera nem se apaga'; end if;
  perform erp.exigir_editor();
  if not erp.estou_nas_listas(v_listas) and not erp.sou_master() then      -- o master sempre aprova
    raise exception 'Só quem está em % aprova isto', array_to_string(v_listas, ', ');
  end if;
  if erp.eu() = coalesce(erp.autor_lancamento('documento', new.documento_id),
                         erp.autor_lancamento('titulo', new.titulo_id))
     and not erp.aprova_proprio(v_listas) then
    raise exception 'Quem lançou não aprova o próprio lançamento';
  end if;
  new.competencia := coalesce((select competencia from erp.documentos_fiscais where id = new.documento_id),
                              (select competencia from erp.titulos where id = new.titulo_id));
  new.aprovado_por := erp.autor();
  new.aprovado_em := clock_timestamp();
  return new;
end $$;
create trigger t_excecao_competencia before insert or update or delete on erp.excecoes_competencia
  for each row execute function erp.tg_excecao_competencia();

-- A competência está na janela da emissão, ou tem exceção aprovada?
create function erp.checar_competencia(p_tipo text, p_id uuid, p_emissao date, p_competencia date)
returns void language plpgsql stable as $$
declare g erp.regra_alcada_pagamento := (select g0 from erp.regra_alcada_pagamento g0);
begin
  if p_competencia between (erp.mes(p_emissao) - make_interval(months => g.competencia_meses_antes))::date
                       and (erp.mes(p_emissao) + make_interval(months => g.competencia_meses_depois))::date then
    return;
  end if;
  if exists (select 1 from erp.excecoes_competencia
              where ((p_tipo = 'documento' and documento_id = p_id) or (p_tipo = 'titulo' and titulo_id = p_id))
                and erp.mes(competencia) = erp.mes(p_competencia)) then
    return;
  end if;
  raise exception 'A competência está fora da janela da emissão; peça a exceção a quem está em %',
    array_to_string(g.excecao_competencia, ', ');
end $$;

-- Adiantamento conta uma vez no acumulado (decisão do Moises, 14/11/2026; S-061): o pedido soma
-- como qualquer título; a linha do rateio do título do mesmo fornecedor, no mesmo núcleo e centro,
-- fica coberta pelo que já foi pago dos pedidos e ainda não cobriu outro título (o mais antigo
-- primeiro), e soma só o que passa dele.
create table erp.titulo_coberturas (
  titulo_id       uuid not null references erp.titulos,
  rodada          int not null,                  -- vale só na volta atual do título
  rateio_id       uuid not null,                 -- a linha do rateio (pode sair no ajuste da revisão)
  adiantamento_id uuid not null references erp.titulos,
  valor           numeric(15,2) not null check (valor > 0),
  primary key (rateio_id, adiantamento_id, rodada)
);
create trigger t_alcada_titulo before insert or update or delete on erp.titulo_coberturas
  for each row execute function erp.tg_alcada_titulo();

create function erp.cobertura(p_rateio uuid) returns numeric language sql stable as $$
  select coalesce(sum(c.valor), 0) from erp.titulo_coberturas c join erp.titulos t on t.id = c.titulo_id
   where c.rateio_id = p_rateio and c.rodada = t.rodada $$;

create function erp._cobrir_adiantamento(t erp.titulos) returns void language plpgsql as $$
declare r record; a record; v_resto numeric; v_disp numeric; v_c numeric;
begin
  if t.tipo not in ('fornecedor','avulso') then return; end if;
  for r in select tr.id, tr.nucleo_economico_id, tr.centro_custo_id, tr.divisao_id, round(t.valor * tr.percentual / 100, 2) as parte
             from erp.titulo_rateios tr where tr.titulo_id = t.id order by tr.id loop
    v_resto := r.parte;
    for a in select a0.id, a0.valor from erp.titulos a0 join erp.titulo_rateios ar on ar.titulo_id = a0.id
              where a0.tipo = 'adiantamento' and a0.empresa_id = t.empresa_id and a0.pessoa_id = t.pessoa_id
                and a0.situacao in ('aberto','quitado')   -- recusado nunca é pago, então não cobre
                and ar.nucleo_economico_id is not distinct from r.nucleo_economico_id
                and ar.centro_custo_id is not distinct from r.centro_custo_id
                and ar.divisao_id is not distinct from r.divisao_id
              order by a0.emissao, a0.criado_em, a0.id for update of a0 loop
      exit when v_resto <= 0;
      -- só o que já saiu cobre: pedido aprovado e não pago não abate nada. Cada título já atendido
      -- pelo adiantamento consome o maior entre o que ele cobriu e o que foi abatido nele (S-069:
      -- o abatido num título que não recebeu cobertura também já foi usado)
      v_disp := coalesce((select sum(valor) from erp.pagamentos where adiantamento_id = a.id), 0)
              - coalesce((select sum(greatest(coalesce(cob.v, 0), coalesce(ab.v, 0)))
                            from (select c.titulo_id as t, sum(c.valor) as v
                                    from erp.titulo_coberturas c join erp.titulos tc on tc.id = c.titulo_id
                                   where c.adiantamento_id = a.id and tc.situacao <> 'cancelado' and c.rodada = tc.rodada
                                   group by c.titulo_id) cob
                            full join (select pa.titulo_id as t, sum(q.principal + q.juros + q.multa - q.desconto) as v
                                         from erp.quitacoes q join erp.pagamentos g on g.id = q.pagamento_id
                                         join erp.parcelas pa on pa.id = q.parcela_id
                                        where g.adiantamento_id = a.id group by pa.titulo_id) ab using (t)), 0);
      v_c := least(v_resto, v_disp);
      if v_c > 0 then
        insert into erp.titulo_coberturas (titulo_id, rodada, rateio_id, adiantamento_id, valor) values (t.id, t.rodada, r.id, a.id, v_c);
        v_resto := v_resto - v_c;
      end if;
    end loop;
  end loop;
end $$;

-- O pagamento ligado ao pedido de adiantamento (chamada pelo tg_pagamento, que é definer).
create function erp._pagar_pedido_adiantamento(g erp.pagamentos) returns void language plpgsql as $$
declare a erp.titulos; v_pago numeric;
begin
  select * into a from erp.titulos where id = g.adiantamento_id for update;
  if a.tipo is distinct from 'adiantamento' then raise exception 'O pagamento não está ligado a um pedido de adiantamento'; end if;
  if a.situacao <> 'aberto' then raise exception 'O pedido de adiantamento não está aberto'; end if;
  if a.empresa_id <> g.empresa_id or a.pessoa_id <> g.pessoa_id then
    raise exception 'O pagamento é de outra empresa ou outro favorecido que o pedido de adiantamento';
  end if;
  if not exists (select 1 from erp.titulo_rateios where titulo_id = a.id
                  and nucleo_economico_id is not distinct from g.nucleo_economico_id
                  and centro_custo_id is not distinct from g.centro_custo_id
                  and divisao_id is not distinct from g.divisao_id) then
    raise exception 'O pagamento sai com o núcleo, o centro de custo e a divisão do pedido de adiantamento';
  end if;
  if erp.alcada_recusada(a.id) then raise exception 'O título foi recusado na alçada'; end if;
  if erp.alcada_pendente(a.id) is not null then
    raise exception 'O título ainda não foi aprovado: falta %', erp.alcada_pendente(a.id);
  end if;
  v_pago := (select sum(valor) from erp.pagamentos where adiantamento_id = a.id);
  if v_pago > a.valor then
    raise exception 'O pagamento passa do valor do pedido de adiantamento (%)', a.valor;
  end if;
  if v_pago = a.valor then update erp.titulos set situacao = 'quitado' where id = a.id; end if;
end $$;

-- Fixa a alçada do título na confirmação (chamada pelo confirmar_titulo, que é definer).
-- O título de imposto retido e o movimento entre sócios seguem a nota e o aporte; não entram.
create function erp._definir_alcada(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos; cc record; dv record; f erp.alcadas_pagamento; v_centro boolean;
begin
  select * into t from erp.titulos where id = p_titulo;
  if t.sentido <> 'pagar' or t.tipo in ('imposto','societario') then return; end if;
  -- dois títulos do mesmo centro confirmados ao mesmo tempo se enxergam (S-060): trava os
  -- centros do rateio, sempre na mesma ordem, até o fim da transação
  perform 1 from erp.centros_custo c
   where c.id in (select tr.centro_custo_id from erp.titulo_rateios tr where tr.titulo_id = t.id)
   order by c.id for update;
  perform erp._cobrir_adiantamento(t);
  for cc in select distinct tr.centro_custo_id from erp.titulo_rateios tr
            where tr.titulo_id = t.id and tr.centro_custo_id is not null order by tr.centro_custo_id loop
    -- a alçada da divisão com faixas próprias; a faixa diz se a linha passa também pelo centro
    v_centro := false;
    for dv in select distinct tr.divisao_id from erp.titulo_rateios tr
               where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                 and exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id)
               order by tr.divisao_id loop
      f := erp._fixar_alcada(t, cc.centro_custo_id, dv.divisao_id);
      v_centro := v_centro or f.passa_pelo_centro;
    end loop;
    -- a alçada do centro: as linhas sem divisão com faixas próprias, ou a faixa da divisão que
    -- manda passar pelo centro; centro sem gestor e sem faixas próprias fica fora, como antes
    if v_centro
       or (exists (select 1 from erp.titulo_rateios tr
                    where tr.titulo_id = t.id and tr.centro_custo_id = cc.centro_custo_id
                      and not exists (select 1 from erp.alcadas_pagamento ap where ap.divisao_id = tr.divisao_id))
           and (exists (select 1 from erp.centro_aprovadores a where a.centro_custo_id = cc.centro_custo_id)
                or exists (select 1 from erp.alcadas_pagamento ap where ap.centro_custo_id = cc.centro_custo_id and ap.divisao_id is null))) then
      perform erp._fixar_alcada(t, cc.centro_custo_id, null);
    end if;
  end loop;
end $$;

-- Uma alçada do título: a do centro (p_divisao nulo), com a parte do título no centro inteiro e o
-- acumulado do centro, ou a da divisão, com a parte e o acumulado só da divisão (no modo por
-- núcleo, o maior dos núcleos do rateio). Devolve a faixa que decidiu.
create function erp._fixar_alcada(t erp.titulos, p_centro uuid, p_divisao uuid) returns erp.alcadas_pagamento
language plpgsql as $$
declare v_modo text := (select acumulado from erp.regra_alcada_pagamento);
        v_forn boolean := (select soma_fornecedor from erp.regra_alcada_pagamento);
        r record; v_soma numeric; v_ids uuid[]; v_acum numeric; v_titulos uuid[]; v_valor numeric;
        f erp.alcadas_pagamento; v_falta text[];
begin
  for r in select distinct tr.nucleo_economico_id from erp.titulo_rateios tr
            where tr.titulo_id = t.id and tr.centro_custo_id = p_centro
              and (p_divisao is null or tr.divisao_id = p_divisao) loop
    -- a parte de cada título no centro (ou na divisão); com soma_fornecedor, o mesmo fornecedor conta inteiro
    select round(coalesce(sum(t2.valor * r2.percentual / 100 - erp.cobertura(r2.id)), 0), 2), array_agg(distinct t2.id) into v_soma, v_ids
      from erp.titulos t2 join erp.titulo_rateios r2 on r2.titulo_id = t2.id
     where ((r2.centro_custo_id = p_centro and (p_divisao is null or r2.divisao_id = p_divisao))
            or (v_forn and t2.pessoa_id = t.pessoa_id))
       and t2.sentido = 'pagar' and t2.tipo not in ('imposto','societario')
       and (t2.situacao in ('aberto','quitado') or t2.id = t.id)
       and erp.mes(t2.competencia) = erp.mes(t.competencia)
       and (v_modo = 'centro' or t2.empresa_id = t.empresa_id)
       and (v_modo <> 'nucleo_centro' or r2.centro_custo_id <> p_centro
            or (p_divisao is not null and r2.divisao_id is distinct from p_divisao)
            or r2.nucleo_economico_id is not distinct from r.nucleo_economico_id);
    if v_acum is null or v_soma > v_acum then v_acum := v_soma; v_titulos := v_ids; end if;
  end loop;
  select round(coalesce(sum(t.valor * tr.percentual / 100 - erp.cobertura(tr.id)), 0), 2) into v_valor
    from erp.titulo_rateios tr where tr.titulo_id = t.id and tr.centro_custo_id = p_centro
                                 and (p_divisao is null or tr.divisao_id = p_divisao);
  -- o limite do título olha o título inteiro em cada centro: dividir no rateio não baixa a faixa
  -- (S-098, Moises, 15/11/2026); o acumulado do mês é o do centro (ou o da divisão)
  f := erp._faixa_alcada(p_centro, p_divisao, v_acum, t.valor);
  if f.id is null then raise exception 'Não há alçada de pagamento configurada para %', v_acum; end if;
  v_falta := erp._vagas_sem_gente(f.fases, p_centro, t.criado_por);
  insert into erp.titulo_alcadas (titulo_id, rodada, centro_custo_id, divisao_id, fases, paralelo, valor_no_centro, acumulado, titulos,
                                  alcada_id, falta_aprovadores, vagas_sem_gente)
  values (t.id, t.rodada, p_centro, p_divisao, f.fases, f.paralelo, v_valor, v_acum, v_titulos, f.id,
          cardinality(v_falta) > 0, v_falta);
  if cardinality(v_falta) > 0 then
    perform erp.registrar_evento('alcada_falta_aprovadores', 'titulos', t.id::text, null, p_centro,
      jsonb_build_object('titulo_id', t.id, 'rodada', t.rodada, 'divisao_id', p_divisao, 'fases', f.fases, 'vagas_sem_gente', v_falta,
                         'acumulado', v_acum, 'valor_no_centro', v_valor, 'valor', t.valor,
                         'motivo', 'Faltam aprovadores qualificados: o título vai ao master'));
  end if;
  return f;
end $$;

-- A faixa do título: as da divisão, quando pedida (só se chama para divisão com faixas); no
-- centro, as dele, se ele tem, senão as gerais. A faixa pelo acumulado e a faixa pelo valor do
-- título; vale a mais alta (a mais exigente).
create function erp._faixa_alcada(p_centro uuid, p_divisao uuid, p_acumulado numeric, p_valor numeric) returns erp.alcadas_pagamento
language plpgsql stable as $$
declare v_centro uuid; v_ia int; v_it int; v erp.alcadas_pagamento;
begin
  v_centro := case when p_divisao is not null
                     or exists (select 1 from erp.alcadas_pagamento where centro_custo_id = p_centro and divisao_id is null)
                   then p_centro end;
  with f as (select a.*, row_number() over (order by a.ate nulls last, a.ate_titulo nulls last) n
               from erp.alcadas_pagamento a where a.centro_custo_id is not distinct from v_centro
                                              and a.divisao_id is not distinct from p_divisao)
  select min(n) filter (where ate is null or p_acumulado <= ate),
         min(n) filter (where ate_titulo is null or p_valor <= ate_titulo) into v_ia, v_it from f;
  if v_ia is null or v_it is null then return null; end if;
  select a.* into v from (select a0.*, row_number() over (order by a0.ate nulls last, a0.ate_titulo nulls last) n
                            from erp.alcadas_pagamento a0 where a0.centro_custo_id is not distinct from v_centro
                                                            and a0.divisao_id is not distinct from p_divisao) a
   where a.n = greatest(v_ia, v_it);
  return v;
end $$;

-- Quem pode ocupar a vaga no centro (papel ou pessoa pelo nome), ativo.
create function erp._ocupa_vaga(p_vaga text, p_centro uuid, p_user uuid) returns boolean language plpgsql stable as $$
begin
  if not exists (select 1 from erp.usuarios where id = p_user and ativo and not administrador and not so_sucessao) then return false; end if;
  return case
    when p_vaga = 'AREA' then exists (select 1 from erp.centro_aprovadores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga = 'DIRETOR_AREA' then exists (select 1 from erp.centro_diretores where centro_custo_id = p_centro and user_id = p_user)
    when p_vaga in ('AF','AO','AD') then exists (select 1 from erp.listas_financeiro where lista = p_vaga and user_id = p_user)
    when p_vaga like 'P:%' then substr(p_vaga, 3)::uuid = p_user
    else false end;
end $$;

-- As vagas que não têm quem as ocupe: cada pessoa numa vaga só, e quem lançou fora (menos a AD
-- que aprova o próprio). Preenche primeiro as vagas com menos candidatos.
create function erp._vagas_sem_gente(p_fases text[], p_centro uuid, p_autor uuid) returns text[] language plpgsql stable as $$
declare r record; v_usados uuid[] := '{}'; v_quem uuid; v_falta text[] := '{}';
begin
  for r in select i, p_fases[i] as vaga,
                  (select count(*) from erp.usuarios u where erp._ocupa_vaga(p_fases[i], p_centro, u.id)) as n
             from generate_subscripts(p_fases, 1) i order by 3, 1 loop
    select u.id into v_quem from erp.usuarios u
     where erp._ocupa_vaga(r.vaga, p_centro, u.id) and u.id <> all (v_usados)
       and (u.id is distinct from p_autor
            or (r.vaga = 'AD' and exists (select 1 from erp.listas_financeiro l where l.lista = 'AD' and l.user_id = u.id and l.aprova_proprio)))
     order by u.id limit 1;
    if v_quem is null then v_falta := v_falta || r.vaga; else v_usados := v_usados || v_quem; end if;
  end loop;
  return v_falta;
end $$;

-- Fase da vez de uma alçada (centro ou divisão): a primeira sem aprovação; nula quando ela aprovou todas.
-- Tudo da alçada vale na volta atual do título (titulos.rodada); as anteriores ficam no histórico.
create function erp._fase_da_alcada(a erp.titulo_alcadas) returns int language sql stable as $$
  select min(i) from generate_subscripts(a.fases, 1) i
   where not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado) $$;
-- O título: a fase da vez da primeira alçada que falta aprovar (por centro, a do centro antes
-- das divisões); nula quando todas aprovaram (ou sem alçada).
create function erp.alcada_fase(p_titulo uuid) returns int language sql stable as $$
  select erp._fase_da_alcada(a) from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
   where a.titulo_id = p_titulo and erp._fase_da_alcada(a) is not null
   order by a.centro_custo_id, a.divisao_id nulls first limit 1 $$;
create function erp.alcada_pendente(p_titulo uuid) returns text language sql stable as $$
  select a.fases[erp._fase_da_alcada(a)] from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
   where a.titulo_id = p_titulo and erp._fase_da_alcada(a) is not null
   order by a.centro_custo_id, a.divisao_id nulls first limit 1 $$;
create function erp.alcada_recusada(p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.titulo_aprovacoes v join erp.titulos t on t.id = v.titulo_id and t.rodada = v.rodada
                  where v.titulo_id = p_titulo and not v.aprovado) $$;

-- Os títulos do mês que formaram o acumulado do centro até este título (só consulta), para quem
-- aprova o título: o gestor da área, quem está numa lista das fases dele, ou a diretoria.
create function erp.titulos_do_acumulado(p_titulo uuid)
returns table (titulo_id uuid, empresa_id uuid, pessoa text, competencia date, valor_no_centro numeric,
               valor_total numeric, situacao text, centro_custo_id uuid, divisao_id uuid)
language plpgsql stable as $$
declare a erp.titulo_alcadas; v_algum boolean := false;
begin
  if not exists (select 1 from erp.titulo_alcadas a0 join erp.titulos t0 on t0.id = a0.titulo_id and t0.rodada = a0.rodada
                  where a0.titulo_id = p_titulo) then
    raise exception 'Este título não tem alçada de pagamento';
  end if;
  -- cada centro do título: o acumulado dele, para quem aprova naquele centro
  for a in select a0.* from erp.titulo_alcadas a0 join erp.titulos t0 on t0.id = a0.titulo_id and t0.rodada = a0.rodada
            where a0.titulo_id = p_titulo order by a0.centro_custo_id, a0.divisao_id nulls first loop
    continue when not (erp.estou_nas_listas(a.fases) or coalesce(erp.meu_papel(), '') = 'diretor' or erp.sou_master()
                       or exists (select 1 from unnest(a.fases) e where erp._ocupa_vaga(e, a.centro_custo_id, erp.eu())));
    v_algum := true;
    -- exatamente os títulos que entraram na soma, com a parte deles no centro. S-062: em detalhe só
    -- os que quem pergunta vê; os outros numa linha só, com a soma no centro (fecha o acumulado
    -- sem mostrar fornecedor, empresa nem natureza)
    return query
      with t as (
        select t2.id, t2.empresa_id, p.nome, t2.competencia, t2.valor, t2.situacao, t2.criado_em, erp.vejo_titulo(t2.id) as ve,
               round(coalesce(sum(t2.valor * r2.percentual / 100 - erp.cobertura(r2.id)) filter (where r2.centro_custo_id = a.centro_custo_id
                                                                                    and (a.divisao_id is null or r2.divisao_id = a.divisao_id)), 0), 2) as no_centro
          from erp.titulos t2 join erp.titulo_rateios r2 on r2.titulo_id = t2.id
          join erp.pessoas p on p.id = t2.pessoa_id
         where t2.id = any(a.titulos)
         group by t2.id, t2.empresa_id, p.nome, t2.competencia, t2.valor, t2.situacao, t2.criado_em)
      select x.id, x.empresa_id, x.nome, x.competencia, x.no_centro, x.valor, x.situacao, a.centro_custo_id, a.divisao_id from (
        select t.id, t.empresa_id, t.nome, t.competencia, t.no_centro, t.valor, t.situacao from t where t.ve
        union all
        select null::uuid, null::uuid, format('Outros %s títulos (sem acesso)', count(*)), null::date, sum(t.no_centro), null::numeric, null::text
          from t where not t.ve having count(*) > 0) x
       order by x.id is null, (select t3.criado_em from erp.titulos t3 where t3.id = x.id);
  end loop;
  if not v_algum then raise exception 'Só quem aprova o título vê o acumulado'; end if;
end $$;

-- Uma aprovação vale pela divisão e pelo centro (Moises, 15/11/2026): quem aprovou na alçada da
-- divisão e ocupa uma vaga pendente na alçada do centro (ou o contrário) fica aprovado lá também,
-- na vaga que ocupa, quando ela é a da vez (em paralelo, qualquer uma). Roda depois de cada
-- aprovação, porque em sequência a vaga pode só chegar depois. Não vale entre duas divisões, nem a
-- aprovação de quem lançou (master ou AD autorizada), nem a que veio pelo ajuste da revisão.
create function erp._aprovacao_vale_nas_duas(p_titulo uuid) returns void language plpgsql as $$
declare r record; v_n int;
begin
  loop
    v_n := 0;
    for r in select a2.id as alcada, i as fase, a2.fases[i] as vaga, v.por, v.alcada_id as de
               from erp.titulos t
               join erp.titulo_alcadas a2 on a2.titulo_id = t.id and a2.rodada = t.rodada
               join erp.titulo_alcadas a1 on a1.titulo_id = t.id and a1.rodada = t.rodada and a1.id <> a2.id
                                         and a1.centro_custo_id = a2.centro_custo_id and (a1.divisao_id is null or a2.divisao_id is null)
               join erp.titulo_aprovacoes v on v.alcada_id = a1.id and v.aprovado and v.origem = 'decisao' and not v.proprio
               cross join lateral generate_subscripts(a2.fases, 1) i
              where t.id = p_titulo
                and (a2.paralelo or i = erp._fase_da_alcada(a2))
                and erp._ocupa_vaga(a2.fases[i], a2.centro_custo_id, v.por)
              order by a2.centro_custo_id, a2.divisao_id nulls first, i loop
      continue when exists (select 1 from erp.titulo_aprovacoes x where x.alcada_id = r.alcada and (x.fase = r.fase or x.por = r.por));
      continue when not exists (select 1 from erp.titulo_alcadas a where a.id = r.alcada
                                  and (a.paralelo or r.fase = erp._fase_da_alcada(a)));
      insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, origem, vale_de)
      select r.alcada, a.titulo_id, a.rodada, a.centro_custo_id, r.fase, r.vaga, true, 'Vale a aprovação na outra alçada do centro', r.por,
             'outra_alcada', r.de
        from erp.titulo_alcadas a where a.id = r.alcada;
      v_n := v_n + 1;
    end loop;
    exit when v_n = 0;
  end loop;
end $$;

-- Aprovar ou recusar a fase da vez. Recusar exige justificativa e trava o título.
-- p_revisao: em vez de decidir, pede o ajuste (p_aprovar é ignorado; o motivo vai em p_justificativa).
-- Recusar cancela o título (e a nota dele) com estorno no livro.
create function erp.decidir_titulo(p_titulo uuid, p_aprovar boolean, p_justificativa text default null,
                                   p_revisao boolean default false, p_centro uuid default null,
                                   p_divisao uuid default null)
returns text language plpgsql as $$
declare a erp.titulo_alcadas; v_fase int; v_lista text; v_eu uuid := erp.eu(); v_master boolean := erp.sou_master();
        v_proprio boolean; v_autor boolean; v_rodada int;
begin
  perform erp.exigir_editor();
  if v_eu is null then raise exception 'Usuário sem cadastro no ERP'; end if;
  select t0.rodada into v_rodada from erp.titulos t0 where t0.id = p_titulo for update;
  if not exists (select 1 from erp.titulo_alcadas where titulo_id = p_titulo and rodada = v_rodada) then
    raise exception 'Este título não tem alçada de pagamento';
  end if;
  if erp.alcada_recusada(p_titulo) then raise exception 'O título foi recusado na alçada'; end if;
  if erp.em_revisao(p_titulo) then raise exception 'O título está em revisão; aguarde o ajuste de quem lançou'; end if;
  if erp.alcada_fase(p_titulo) is null then raise exception 'O título já foi aprovado em todas as fases de aprovação'; end if;
  -- a alçada (centro ou divisão): a pedida, senão a primeira que falta aprovar em que a pessoa
  -- tem a vaga da vez (em paralelo, qualquer vaga pendente) e ainda não aprovou; senão a
  -- primeira que falta aprovar
  if p_centro is not null then
    select * into a from erp.titulo_alcadas where titulo_id = p_titulo and rodada = v_rodada and centro_custo_id = p_centro
                                              and divisao_id is not distinct from p_divisao;
    if a.titulo_id is null then
      if p_divisao is null then raise exception 'Este centro não está na alçada do título'; end if;
      raise exception 'Esta divisão não tem alçada própria neste título';
    end if;
    if erp._fase_da_alcada(a) is null then
      if p_divisao is null then raise exception 'Este centro já aprovou o título'; end if;
      raise exception 'Esta divisão já aprovou o título';
    end if;
  elsif p_divisao is not null then
    raise exception 'Diga o centro de custo da divisão';
  else
    select a0.* into a from erp.titulo_alcadas a0
     where a0.titulo_id = p_titulo and a0.rodada = v_rodada and erp._fase_da_alcada(a0) is not null
     order by (not v_master and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.por = v_eu)
                and exists (select 1 from generate_subscripts(a0.fases, 1) i
                             where (a0.paralelo or i = erp._fase_da_alcada(a0))
                               and erp._ocupa_vaga(a0.fases[i], a0.centro_custo_id, v_eu)
                               and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.fase = i and v.aprovado))) desc,
              -- sem a vez em nenhuma: a alçada em que a pessoa já aprovou (a recusa diz isso), depois a primeira
              exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a0.id and v.por = v_eu) desc,
              a0.centro_custo_id, a0.divisao_id nulls first
     limit 1;
  end if;
  -- em sequência, a vaga da vez; em paralelo, a primeira vaga pendente que a pessoa ocupa
  v_fase := erp._fase_da_alcada(a);
  if a.paralelo and not v_master then
    v_fase := coalesce((select min(i) from generate_subscripts(a.fases, 1) i
                          where erp._ocupa_vaga(a.fases[i], a.centro_custo_id, v_eu)
                            and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado)), v_fase);
  end if;
  v_lista := a.fases[v_fase];
  -- quem lançou não aprova, salvo o master e a AD autorizada (na fase da AD)
  v_proprio := v_master or (v_lista = 'AD' and erp.aprova_proprio(array['AD']));
  v_autor := erp.autor_lancamento('titulo', p_titulo) = v_eu
             or exists (select 1 from erp.cadeia_titulo(p_titulo) c(id) where erp.autor_lancamento('titulo', c.id) = v_eu);
  if coalesce(v_autor, false) and not v_proprio then raise exception 'Quem lançou não aprova o próprio lançamento'; end if;
  -- na nota relançada, quem lançou qualquer título da cadeia também não (S-075); e quem ajustou
  -- ou reenviou em alguma revisão da cadeia não aprova (S-071; quem ajusta já aprova a própria
  -- fase no reenvio)
  if not v_master and (exists (select 1 from erp.titulo_revisoes r where r.titulo_id in (select erp.cadeia_titulo(p_titulo)) and r.reenviada_por = v_eu)
     or exists (select 1 from erp.titulo_ajustes j where j.titulo_id in (select erp.cadeia_titulo(p_titulo)) and j.por = v_eu)) then
    raise exception 'Quem ajustou não aprova o ajuste';
  end if;
  -- uma fase por pessoa em cada alçada; quem tem vaga em dois centros aprova nos dois; na divisão
  -- e no centro, a aprovação vale pelas duas (_aprovacao_vale_nas_duas)
  if not v_master and exists (select 1 from erp.titulo_aprovacoes where alcada_id = a.id and por = v_eu) then
    raise exception 'Você já aprovou uma fase de aprovação deste título';
  end if;
  -- o master decide qualquer fase; aprovando, a decisão dele vale por todas as que faltam, em
  -- todas as alçadas (Moises, 14/11/2026). Quem lançou ou ajustou continua não aprovando, nem o master.
  if v_master then
    null;
  elsif v_lista = 'AREA' then
    if not exists (select 1 from erp.centro_aprovadores c join erp.usuarios u on u.id = c.user_id
                    where c.centro_custo_id = a.centro_custo_id and c.user_id = v_eu and u.ativo) then
      raise exception 'Esta fase de aprovação é do gestor da área';
    end if;
  elsif v_lista = 'DIRETOR_AREA' then
    if not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then raise exception 'Esta fase de aprovação é do diretor da área'; end if;
  elsif v_lista like 'P:%' then
    if not erp._ocupa_vaga(v_lista, a.centro_custo_id, v_eu) then raise exception 'Esta fase de aprovação é de outra pessoa'; end if;
  elsif not erp.estou_nas_listas(array[v_lista]) then
    raise exception 'Esta fase de aprovação é de quem está em %', v_lista;
  end if;
  if p_revisao then
    if length(trim(coalesce(p_justificativa, ''))) = 0 then raise exception 'Pedir revisão exige o motivo'; end if;
    insert into erp.titulo_revisoes (titulo_id, rodada, centro_custo_id, alcada_id, fase, motivo, pedida_por)
    values (p_titulo, a.rodada, a.centro_custo_id, a.id, v_fase, p_justificativa, v_eu);
    return 'revisao';
  end if;
  if not p_aprovar and length(trim(coalesce(p_justificativa, ''))) = 0 then
    raise exception 'Recusar exige justificativa';
  end if;
  if v_master and p_aprovar then
    insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, proprio)
    select a2.id, p_titulo, a2.rodada, a2.centro_custo_id, i, a2.fases[i], true, p_justificativa, v_eu, coalesce(v_autor, false)
      from erp.titulo_alcadas a2, generate_subscripts(a2.fases, 1) i
     where a2.titulo_id = p_titulo and a2.rodada = v_rodada
       and not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a2.id and v.fase = i);
    return 'aprovado';
  end if;
  insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, proprio)
  values (a.id, p_titulo, a.rodada, a.centro_custo_id, v_fase, v_lista, p_aprovar, p_justificativa, v_eu, coalesce(v_autor, false));
  if not p_aprovar then
    perform erp._cancelar_recusado(p_titulo);
    return 'recusado';
  end if;
  perform erp._aprovacao_vale_nas_duas(p_titulo);
  return case when erp.alcada_pendente(p_titulo) is null then 'aprovado' else 'pendente' end;
end $$;

-- Desfaz o título na alçada, com estorno no livro. Título de nota desfaz a nota inteira
-- (fornecedor e impostos), devolve as previsões consumidas e estorna a caução retida.
-- 'recusa': a nota fica cancelada (o número fica livre); 'revisao': a nota volta a rascunho para
-- ser relançada no reenvio. Nada pago volta por aqui: o estorno de pagamento fica para bancos.
create function erp._desfazer_titulos(p_titulo uuid, p_motivo text) returns void language plpgsql as $$
declare t erp.titulos; d erp.documentos_fiscais; v_ids uuid[]; x uuid;
begin
  select * into t from erp.titulos where id = p_titulo for update;
  if t.documento_id is not null then
    select * into d from erp.documentos_fiscais where id = t.documento_id for update;
    select array_agg(id order by id) into v_ids from erp.titulos where documento_id = d.id and situacao <> 'cancelado';
  else
    v_ids := array[t.id];
  end if;
  if exists (select 1 from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id where pa.titulo_id = any(v_ids))
     or exists (select 1 from erp.pagamentos where adiantamento_id = any(v_ids)) then
    raise exception 'O título ou a nota dele já tem pagamento; o estorno do pagamento fica para o módulo de bancos';
  end if;
  foreach x in array v_ids loop
    perform erp._estornar_titulo(x, null);
    update erp.previsoes set situacao = 'aberta'
     where situacao = 'consumida' and id in (select previsao_id from erp.titulo_previsoes where titulo_id = x);
    update erp.titulos set situacao = 'cancelado', cancelamento = p_motivo where id = x;
  end loop;
  if d.id is not null then
    if coalesce(d.caucao_valor, 0) > 0 then
      insert into erp.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
      values (d.compromisso_id, 'estorno', d.caucao_valor, d.id);
    end if;
    if p_motivo = 'recusa' then
      update erp.documentos_fiscais set situacao = 'cancelado', cancelamento = 'recusa' where id = d.id;
    else
      update erp.documentos_fiscais set situacao = 'rascunho', lancado_em = null where id = d.id;
    end if;
  end if;
end $$;
create function erp._cancelar_recusado(p_titulo uuid) returns void language plpgsql as $$
begin perform erp._desfazer_titulos(p_titulo, 'recusa'); end $$;

-- Reenvio depois do ajuste: a alçada recomeça do zero, numa volta nova. Título avulso ou pedido:
-- confere de novo o que a confirmação confere, estorna o comprometido e lança o ajustado. Título
-- de nota: a nota é relançada (p_vencimentos, ou os vencimentos de antes) e os títulos refeitos,
-- consumindo p_previsoes ou, sem elas, as previsões que a nota consumia e que ainda casam com ela
-- ajustada (vazio = nenhuma; nunca outras do contrato que a nota não consumia).
create function erp.reenviar_titulo(p_titulo uuid, p_resposta text, p_vencimentos date[] default null,
                                    p_previsoes uuid[] default null)
returns uuid language plpgsql as $$
declare t erp.titulos; d erp.documentos_fiscais; v_venc date[]; v_prev uuid[]; v_novo uuid; v_rev uuid;
begin
  perform erp.exigir_editor();
  select * into t from erp.titulos where id = p_titulo for update;
  if not erp.em_revisao(p_titulo) then raise exception 'O título não está em revisão'; end if;
  if not erp.pode_ajustar(p_titulo) then
    raise exception 'Quem reenvia é quem lançou, o gestor da área ou o AF';
  end if;
  if length(trim(coalesce(p_resposta, ''))) = 0 then raise exception 'Reenviar exige a resposta ao pedido'; end if;
  update erp.titulo_revisoes set resposta = p_resposta where titulo_id = p_titulo and reenviada_em is null
  returning id into v_rev;
  if t.documento_id is not null then
    v_venc := coalesce(p_vencimentos,
                       (select array_agg(vencimento order by numero) from erp.parcelas where titulo_id = t.id));
    select array_agg(distinct tp.previsao_id) into v_prev
      from erp.titulo_previsoes tp join erp.titulos x on x.id = tp.titulo_id
     where x.documento_id = t.documento_id and x.situacao <> 'cancelado';
    perform erp._desfazer_titulos(t.id, 'revisao');
    if p_previsoes is null then
      select * into d from erp.documentos_fiscais where id = t.documento_id;
      select coalesce(array_agg(pr.id), '{}') into v_prev
        from erp.previsoes pr where pr.id = any(coalesce(v_prev, '{}')) and erp._previsao_casa(pr, d);
    else
      v_prev := p_previsoes;
    end if;
    v_novo := erp.lancar_documento(t.documento_id, v_venc, v_prev);
    update erp.titulos set substitui_id = t.id where id = v_novo;
    perform erp._aprovar_pelo_ajuste(v_novo, v_rev);
    return v_novo;
  end if;
  if not erp.rateio_completo('titulo', t.id) then raise exception 'O rateio do título não soma 100%%'; end if;
  if coalesce((select sum(valor) from erp.parcelas where titulo_id = t.id), 0) <> t.valor then
    raise exception 'As parcelas não somam o valor do título';
  end if;
  if t.tipo = 'adiantamento' and (select count(*) from erp.titulo_rateios where titulo_id = t.id) <> 1 then
    raise exception 'O pedido de adiantamento tem um núcleo e um centro de custo só';
  end if;
  perform erp.checar_competencia('titulo', t.id, t.emissao, t.competencia);
  perform erp._estornar_titulo(t.id, 'comprometido');
  update erp.titulos set rodada = rodada + 1 where id = t.id returning * into t;
  perform erp._comprometer_titulo(t);
  perform erp._definir_alcada(t.id);
  perform erp._aprovar_pelo_ajuste(t.id, v_rev);
  return t.id;
end $$;

-- Quem ajustou ou reenviou na revisão já aprova a própria fase na volta nova (decisões do Moises,
-- 14/11): a gestora da área, a fase da área; o AF, a fase do AF. As outras fases seguem a ordem.
-- Cada pessoa cobre uma fase só, e quem lançou algum título da cadeia nunca aprova.
create function erp._aprovar_pelo_ajuste(p_titulo uuid, p_revisao uuid) returns void language plpgsql as $$
declare a erp.titulo_alcadas; i int; v_quem uuid; v_usados uuid[];
begin
  -- em cada alçada do título (centro ou divisão); quem tem a vaga em duas aprova nas duas
  for a in select a0.* from erp.titulo_alcadas a0 join erp.titulos t0 on t0.id = a0.titulo_id and t0.rodada = a0.rodada
            where a0.titulo_id = p_titulo order by a0.centro_custo_id, a0.divisao_id nulls first loop
    v_usados := '{}';
    for i in select generate_subscripts(a.fases, 1) loop
      continue when a.fases[i] not in ('AREA','AF');
      select q.por into v_quem from (
          select reenviada_por as por, reenviada_em as em from erp.titulo_revisoes where id = p_revisao
          union all select por, em from erp.titulo_ajustes where revisao_id = p_revisao) q
       join erp.usuarios u on u.id = q.por and u.ativo
       where q.por <> all(v_usados)
         -- quem lançou de verdade é o autor do primeiro título da cadeia; os relançados pela revisão
         -- da nota têm como autor técnico quem reenviou
         and q.por is distinct from (select erp.autor_lancamento('titulo', c.id) from erp.cadeia_titulo(p_titulo) c(id)
                                      join erp.titulos t on t.id = c.id where t.substitui_id is null)
         and case a.fases[i]
               when 'AREA' then exists (select 1 from erp.centro_aprovadores c where c.user_id = q.por and c.centro_custo_id = a.centro_custo_id)
               else exists (select 1 from erp.listas_financeiro l where l.user_id = q.por and l.lista = 'AF') end
       order by q.em limit 1;
      continue when v_quem is null;
      insert into erp.titulo_aprovacoes (alcada_id, titulo_id, rodada, centro_custo_id, fase, lista, aprovado, justificativa, por, origem)
      values (a.id, p_titulo, a.rodada, a.centro_custo_id, i, a.fases[i], true, 'Aprovado pelo ajuste na revisão', v_quem, 'ajuste');
      v_usados := v_usados || v_quem;
    end loop;
  end loop;
end $$;

-- Conferências da trava do adiantamento (S-034): security definer na migration _erp_rls, para
-- enxergar pagamentos, quitações e aprovações de núcleos e centros que quem lança não vê.
-- Recebem só ids de pagamento e título; não escolhem empresa nem usuário.
create function erp.autor_lancamento(p_tipo text, p_id uuid) returns uuid language sql stable as $$
  select case p_tipo when 'pagamento' then (select criado_por from erp.pagamentos where id = p_id)
                     when 'titulo'    then (select criado_por from erp.titulos where id = p_id)
                     when 'documento' then (select criado_por from erp.documentos_fiscais where id = p_id) end $$;
create function erp.abatimento_aprovado(p_pagamento uuid, p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.abatimentos_cruzados where pagamento_id = p_pagamento and titulo_id = p_titulo) $$;
-- O título está todo no núcleo e no centro do pagamento (com alguma linha em outra divisão) e quem
-- aprova é gestor do centro (Moises, 15/11/2026: o gestor geral do centro aprova abater em outra
-- divisão dele; S-103: com linha em outro centro, só o financeiro).
create function erp.gestor_abate_divisao(p_pagamento uuid, p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.pagamentos g
                   join erp.centro_aprovadores c on c.centro_custo_id = g.centro_custo_id and c.user_id = erp.eu()
                  where g.id = p_pagamento and g.centro_custo_id is not null
                    and exists (select 1 from erp.titulo_rateios tr where tr.titulo_id = p_titulo)
                    and not exists (select 1 from erp.titulo_rateios tr where tr.titulo_id = p_titulo
                                     and not (tr.nucleo_economico_id is not distinct from g.nucleo_economico_id
                                              and tr.centro_custo_id = g.centro_custo_id))) $$;
-- Há adiantamento mais antigo do mesmo fornecedor, na mesma empresa, com saldo, sem liberação do
-- título feita depois dele?
create function erp.adiantamento_anterior_em_aberto(p_pagamento uuid, p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.pagamentos g join erp.pagamentos g2
                   on g2.empresa_id = g.empresa_id and g2.pessoa_id = g.pessoa_id and g2.id <> g.id
                 where g.id = p_pagamento and g2.criado_em < g.criado_em and erp._pagamento_saldo(g2.id) > 0
                   and not exists (select 1 from erp.liberacoes_sem_abater l
                                   where l.titulo_id = p_titulo and l.aprovado_em >= g2.criado_em)) $$;

create function erp.tg_aprovacao_adiantamento() returns trigger language plpgsql as $$
declare v_listas text[]; v_lancou uuid; v_gestor boolean := false;
begin
  if tg_op <> 'INSERT' then raise exception 'Aprovação não se altera nem se apaga'; end if;
  if tg_table_name = 'abatimentos_cruzados' then
    v_listas := (erp.regra_adiantamento_atual()).aprova_cruzado;
    v_lancou := erp.autor_lancamento('pagamento', new.pagamento_id);
    v_gestor := erp.gestor_abate_divisao(new.pagamento_id, new.titulo_id);
  else
    v_listas := (erp.regra_adiantamento_atual()).libera_sem_abater;
    v_lancou := erp.autor_lancamento('titulo', new.titulo_id);
  end if;
  if not erp.estou_nas_listas(v_listas) and not erp.sou_master()           -- o master sempre aprova
     and not v_gestor then
    raise exception 'Só quem está em % aprova isto', array_to_string(v_listas, ', ');
  end if;
  if v_lancou is not null and v_lancou = erp.eu() and not erp.aprova_proprio(v_listas) then
    raise exception 'Quem lançou não aprova o próprio lançamento';
  end if;
  new.aprovado_por := erp.autor();
  new.aprovado_em := clock_timestamp();
  return new;
end $$;
create trigger t_aprovacao before insert or update or delete on erp.abatimentos_cruzados
  for each row execute function erp.tg_aprovacao_adiantamento();
create trigger t_aprovacao before insert or update or delete on erp.liberacoes_sem_abater
  for each row execute function erp.tg_aprovacao_adiantamento();
create function erp.tg_recusa_truncate() returns trigger language plpgsql as $$
begin raise exception 'Esta tabela não se apaga'; end $$;
create trigger t_sem_truncate before truncate on erp.abatimentos_cruzados
  for each statement execute function erp.tg_recusa_truncate();
create trigger t_sem_truncate before truncate on erp.liberacoes_sem_abater
  for each statement execute function erp.tg_recusa_truncate();
create trigger t_sem_truncate before truncate on erp.titulo_ajustes
  for each statement execute function erp.tg_recusa_truncate();

create function erp.tg_quitacao() returns trigger language plpgsql as $$
declare g erp.pagamentos; pa erp.parcelas; t erp.titulos; r record; v_total numeric;
        v_nucleo uuid; v_dep uuid; v_div uuid; v_comp date;
begin
  select * into g from erp.pagamentos where id = new.pagamento_id for update;
  select * into pa from erp.parcelas where id = new.parcela_id for update;
  select * into t from erp.titulos where id = pa.titulo_id for update;
  if t.situacao <> 'aberto' then raise exception 'O título não está aberto'; end if;
  if t.tipo = 'adiantamento' then raise exception 'O pedido de adiantamento se paga pelo pagamento ligado a ele'; end if;
  if t.sentido <> 'pagar' then raise exception 'Recebimentos ficam para o módulo de contas a receber'; end if;
  if g.empresa_id <> t.empresa_id then raise exception 'Pagamento e título são de empresas diferentes'; end if;
  if g.pessoa_id <> t.pessoa_id then raise exception 'O pagamento foi para outra pessoa'; end if;
  if erp.alcada_recusada(t.id) then raise exception 'O título foi recusado na alçada'; end if;
  if erp.em_revisao(t.id) then raise exception 'O título está em revisão'; end if;
  if erp.alcada_pendente(t.id) is not null then
    raise exception 'O título ainda não foi aprovado: falta %', erp.alcada_pendente(t.id);
  end if;
  if (erp.regra_adiantamento_atual()).trava then
    -- adiantamento só abate título do mesmo núcleo e centro do carimbo; em outro, só aprovado
    -- S-103 (Moises, 15/11/2026): sem aprovação, só abate o título que está inteiro no carimbo;
    -- com uma linha fora dele, o título todo pede a aprovação
    if g.nucleo_economico_id is not null
       and exists (select 1 from erp.titulo_rateios tr where tr.titulo_id = t.id
                    and not (tr.nucleo_economico_id is not distinct from g.nucleo_economico_id
                             and tr.centro_custo_id is not distinct from g.centro_custo_id
                             and tr.divisao_id is not distinct from g.divisao_id))
       and not erp.abatimento_aprovado(g.id, t.id) then
      if not exists (select 1 from erp.titulo_rateios tr where tr.titulo_id = t.id
                      and not (tr.nucleo_economico_id is not distinct from g.nucleo_economico_id
                               and tr.centro_custo_id is not distinct from g.centro_custo_id)) then
        raise exception 'Este pagamento é de outra divisão do mesmo centro; abater aqui precisa de aprovação do gestor do centro ou de %',
          array_to_string((erp.regra_adiantamento_atual()).aprova_cruzado, ', ');
      end if;
      raise exception 'Este pagamento é de outro núcleo ou centro de custo; abater aqui precisa de aprovação de %',
        array_to_string((erp.regra_adiantamento_atual()).aprova_cruzado, ', ');
    end if;
    -- o título não é pago com dinheiro novo enquanto o fornecedor tiver adiantamento em aberto
    if erp.adiantamento_anterior_em_aberto(g.id, t.id) then
      raise exception 'O fornecedor tem adiantamento em aberto: abata-o primeiro ou peça a liberação de %',
        array_to_string((erp.regra_adiantamento_atual()).libera_sem_abater, ', ');
    end if;
  end if;
  -- roda depois da gravação: a própria quitação já entra nos saldos
  if erp._parcela_saldo(pa.id) < 0 then
    raise exception 'A quitação (%) passa do saldo da parcela (%)', new.principal, erp._parcela_saldo(pa.id) + new.principal;
  end if;
  v_total := new.principal + new.juros + new.multa - new.desconto;
  if erp._pagamento_saldo(g.id) < 0 then
    raise exception 'A quitação (%) passa do saldo do pagamento (%)', v_total, erp._pagamento_saldo(g.id) + v_total;
  end if;
  v_comp := erp.mes(g.data);

  -- sai de Adiantamentos
  insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_caixa, valor,
                               pagamento_id, quitacao_id, titulo_id, parcela_id)
  values ('realizado', t.empresa_id, g.nucleo_economico_id, g.centro_custo_id, g.divisao_id, erp.natureza_sistema('adiantamentos'), v_comp, g.data, v_total,
          g.id, new.id, t.id, pa.id);
  -- principal: realizado na natureza do título e estorno do comprometido
  for r in select * from erp.ratear('titulo', t.id, new.principal) loop
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id,
            t.competencia, g.data, -r.valor, t.id, pa.id, new.id, g.id),
           ('comprometido', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id,
            t.competencia, pa.vencimento, r.valor, t.id, pa.id, new.id, g.id);
  end loop;
  -- juros, multa e desconto: no centro de maior peso do rateio, competência do pagamento
  select nucleo_economico_id, centro_custo_id, divisao_id into v_nucleo, v_dep, v_div
  from erp.titulo_rateios where titulo_id = t.id order by percentual desc, id limit 1;
  if new.juros + new.multa > 0 then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_nucleo, erp.natureza_sistema('juros_multas'), v_dep, v_div,
            v_comp, g.data, -(new.juros + new.multa), t.id, pa.id, new.id, g.id);
  end if;
  if new.desconto > 0 then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_nucleo, erp.natureza_sistema('descontos_obtidos'), v_dep, v_div,
            v_comp, g.data, new.desconto, t.id, pa.id, new.id, g.id);
  end if;
  -- título sem saldo vira quitado
  if not exists (select 1 from erp.parcelas p where p.titulo_id = t.id and erp._parcela_saldo(p.id) > 0) then
    update erp.titulos set situacao = 'quitado' where id = t.id;   -- definer erp_situacao (_erp_rls)
  end if;
  return new;
end $$;
create trigger t_quitacao after insert on erp.quitacoes
  for each row execute function erp.tg_quitacao();
create trigger t_imutavel before update or delete on erp.quitacoes
  for each row execute function erp.tg_imutavel();

-- Atalho do dia a dia: um pagamento que quita uma parcela inteira.
create function erp.pagar_parcela(p_parcela uuid, p_conta uuid, p_data date,
  p_juros numeric default 0, p_multa numeric default 0, p_desconto numeric default 0, p_lote uuid default null)
returns uuid language plpgsql as $$
declare t erp.titulos; v_saldo numeric; v_pag uuid; v_nucleo uuid; v_centro uuid; v_div uuid;
begin
  perform erp.exigir_editor();
  -- S-091 (Moises, 15/11/2026): pagamento só pelo sistema (o adaptador do Sienge) e pelo financeiro
  if not (erp.sistema() or erp.sou_master() or erp.estou_nas_listas(array['AF','AO','AD'])) then
    raise exception 'Só o financeiro (AF, AO ou AD) registra pagamento';
  end if;
  select t2.* into t from erp.titulos t2 join erp.parcelas p on p.titulo_id = t2.id where p.id = p_parcela;
  v_saldo := erp.parcela_saldo(p_parcela);
  if t.id is null or v_saldo is null then raise exception 'Parcela não encontrada'; end if;
  -- carimbo: o núcleo, o centro e a divisão da linha de maior peso no rateio do título
  select nucleo_economico_id, centro_custo_id, divisao_id into v_nucleo, v_centro, v_div
  from erp.titulo_rateios where titulo_id = t.id order by percentual desc, id limit 1;
  insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, lote_id, data, valor)
  values (t.empresa_id, p_conta, t.pessoa_id, v_nucleo, v_centro, v_div, p_lote, p_data, v_saldo + p_juros + p_multa - p_desconto)
  returning id into v_pag;
  insert into erp.quitacoes (pagamento_id, parcela_id, principal, juros, multa, desconto)
  values (v_pag, p_parcela, v_saldo, p_juros, p_multa, p_desconto);
  return v_pag;
end $$;

-- ---------------------------------------------------------------------
-- Caução: extrato, liberação e uso para pagar terceiro
-- ---------------------------------------------------------------------
create function erp.caucao_saldo(p_compromisso uuid) returns numeric language sql stable as $$
  select coalesce(sum(case tipo when 'retencao' then valor else -valor end), 0)
  from erp.caucao_movimentos where compromisso_id = p_compromisso $$;

-- Retida, a caução é dívida sem data (comprometido sem data de caixa); liberada ou usada,
-- sai do sem data e o título gerado passa a carregá-la com vencimento.
-- O extrato só cresce, e só pelo lancar_documento (retenção) e pelo liberar_caucao (S-051).
create function erp.tg_caucao_guarda() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'O extrato da caução não se altera'; end if;
  if not erp.agindo_como('erp_situacao') then
    raise exception 'A caução só se movimenta pelo lançamento da nota e pela liberação';
  end if;
  new.por := erp.autor();
  new.em := now();
  return new;
end $$;
create trigger t_caucao_guarda before insert or update or delete on erp.caucao_movimentos
  for each row execute function erp.tg_caucao_guarda();

create function erp.tg_caucao() returns trigger language plpgsql as $$
declare c erp.compromissos; r record; v_sinal int;
begin
  if tg_op <> 'INSERT' then raise exception 'O extrato da caução não se altera'; end if;
  select * into c from erp.compromissos where id = new.compromisso_id;
  if erp.caucao_saldo(c.id) < 0 then   -- depois da gravação: o próprio movimento já conta
    raise exception 'A caução do contrato tem só % de saldo', erp.caucao_saldo(c.id) + new.valor;
  end if;
  if not erp.rateio_completo('compromisso', c.id) then
    raise exception 'O contrato com caução precisa de rateio que some 100%%';
  end if;
  v_sinal := case new.tipo when 'retencao' then -1 else 1 end;
  for r in select * from erp.ratear('compromisso', c.id, new.valor) loop
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id,
                                    competencia, data_caixa, valor, caucao_movimento_id)
    values ('comprometido', c.empresa_id, r.nucleo_economico_id, r.natureza_id, r.centro_custo_id, r.divisao_id,
            erp.mes(new.em::date), null, v_sinal * r.valor, new.id);
  end loop;
  return new;
end $$;
create trigger t_caucao after insert on erp.caucao_movimentos
  for each row execute function erp.tg_caucao();

-- Com caução retida, o rateio do contrato não muda (S-057): a liberação usa esse rateio.
create function erp.tg_filho_compromisso() returns trigger language plpgsql as $$
begin
  if not exists (select 1 from erp.caucao_movimentos
                  where compromisso_id in (case when tg_op <> 'DELETE' then new.compromisso_id end,
                                           case when tg_op <> 'INSERT' then old.compromisso_id end)) then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and erp.agindo_como('erp_reclassificacao')
     and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then
    return new;
  end if;
  raise exception 'O contrato já tem caução retida; o rateio não muda';
end $$;
create trigger t_filho before insert or update or delete on erp.compromisso_rateios
  for each row execute function erp.tg_filho_compromisso();

-- Libera (para o próprio fornecedor) ou usa (para um terceiro, com motivo) parte da caução.
-- A aprovação do gestor do contrato entra no módulo de aprovação.
create function erp.liberar_caucao(p_compromisso uuid, p_valor numeric, p_vencimento date,
  p_terceiro uuid default null, p_motivo text default null) returns uuid language plpgsql as $$
declare c erp.compromissos; v_tit uuid;
begin
  perform erp.exigir_editor();
  if not erp.sistema() and not erp.lanco_compromisso(p_compromisso) then
    raise exception 'Você não lança em todas as linhas deste contrato';
  end if;
  select * into c from erp.compromissos where id = p_compromisso for update;
  if p_valor > erp.caucao_saldo(c.id) then
    raise exception 'A caução do contrato tem só % de saldo', erp.caucao_saldo(c.id);
  end if;
  v_tit := erp._criar_titulo(c.empresa_id, 'pagar', 'caucao', coalesce(p_terceiro, c.pessoa_id), null, c.id,
                                current_date, erp.mes(current_date), p_valor, array[p_vencimento], 'compromisso', c.id,
                                case when p_terceiro is null then 'Liberação de caução' else 'Caução usada: ' || p_motivo end);
  insert into erp.caucao_movimentos (compromisso_id, tipo, valor, titulo_id, motivo)
  values (c.id, case when p_terceiro is null then 'liberacao' else 'uso_terceiro' end, p_valor, v_tit, p_motivo);
  perform erp._confirmar_titulo(v_tit);
  return v_tit;
end $$;

-- ---------------------------------------------------------------------
-- Movimento entre sócios: título a pagar numa empresa e a receber na outra, ligados
-- ---------------------------------------------------------------------
create function erp.registrar_movimento_societario(p_tipo text, p_pagadora uuid, p_recebedora uuid,
  p_valor numeric, p_data date, p_descricao text default null) returns uuid language plpgsql as $$
declare v_pag uuid; v_rec uuid; v_id uuid; v_nat uuid := erp.natureza_sistema('entre_socios');
begin
  perform erp.exigir_editor();
  -- os títulos entre sócios não têm núcleo nem centro: são da diretoria e do financeiro
  if not (erp.sistema() or coalesce(erp.meu_papel(), '') = 'diretor' or erp.financeiro() or erp.sou_master()) then
    raise exception 'Movimento entre sócios só pela diretoria ou pelo financeiro';
  end if;
  v_pag := erp._criar_titulo(p_pagadora, 'pagar', 'societario', (select pessoa_id from erp.empresas where id = p_recebedora),
                                null, null, p_data, erp.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  v_rec := erp._criar_titulo(p_recebedora, 'receber', 'societario', (select pessoa_id from erp.empresas where id = p_pagadora),
                                null, null, p_data, erp.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  insert into erp.titulo_rateios (titulo_id, natureza_id, percentual) values (v_pag, v_nat, 100), (v_rec, v_nat, 100);
  perform erp._confirmar_titulo(v_pag);
  perform erp._confirmar_titulo(v_rec);
  insert into erp.movimentos_societarios (tipo, pagadora_id, recebedora_id, data, valor, titulo_pagar_id, titulo_receber_id, descricao)
  values (p_tipo, p_pagadora, p_recebedora, p_data, p_valor, v_pag, v_rec, p_descricao) returning id into v_id;
  return v_id;
end $$;
-- O movimento entre sócios só se registra pela função acima (definer erp_situacao, S-057) e não muda.
create function erp.tg_movimento_societario() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Movimento entre sócios não se altera nem se apaga'; end if;
  if not erp.agindo_como('erp_situacao') then
    raise exception 'O movimento entre sócios só se registra pelo registrar_movimento_societario';
  end if;
  return new;
end $$;
create trigger t_movimento_societario before insert or update or delete on erp.movimentos_societarios
  for each row execute function erp.tg_movimento_societario();

-- ---------------------------------------------------------------------
-- Visões
-- ---------------------------------------------------------------------
create view erp.v_parcelas with (security_invoker = true) as
select p.id, p.titulo_id, t.empresa_id, t.pessoa_id, t.sentido, t.tipo, p.numero, p.vencimento, p.valor,
       p.valor - coalesce(q.pago, 0) as saldo,
       case when t.situacao = 'cancelado' then 'cancelada'
            when p.valor - coalesce(q.pago, 0) = 0 then 'quitada'
            when p.vencimento < current_date then 'vencida' else 'aberta' end as situacao
from erp.parcelas p join erp.titulos t on t.id = p.titulo_id
left join (select parcela_id, sum(principal) as pago from erp.quitacoes group by 1) q on q.parcela_id = p.id
where t.situacao <> 'rascunho';

-- Acompanhamento da alçada do título por centro de custo (Moises, 15/11/2026): para quem lançou
-- e quem aprova, cada centro (e cada divisão com alçada própria) com a situação, o valor nele e
-- as vagas que faltam aprovar; o título está aprovado quando todas estão aprovadas. Só a volta atual.
create view erp.v_titulo_alcadas with (security_invoker = true) as
select a.id as alcada_id, a.titulo_id, a.rodada, a.centro_custo_id, c.nome as centro, a.divisao_id, d.nome as divisao,
       a.valor_no_centro, a.acumulado, a.fases, a.paralelo,
       case when exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and not v.aprovado) then 'recusado'
            when cardinality(p.pendentes) = 0 then 'aprovado' else 'pendente' end as situacao,
       p.pendentes as vagas_pendentes,
       a.falta_aprovadores, a.vagas_sem_gente
from erp.titulo_alcadas a
join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
join erp.centros_custo c on c.id = a.centro_custo_id
left join erp.divisoes d on d.id = a.divisao_id
cross join lateral (
  select coalesce(array_agg(a.fases[i] order by i), '{}') as pendentes from generate_subscripts(a.fases, 1) i
   where not exists (select 1 from erp.titulo_aprovacoes v where v.alcada_id = a.id and v.fase = i and v.aprovado)) p;

create view erp.v_adiantamentos with (security_invoker = true) as
select g.id as pagamento_id, g.empresa_id, g.pessoa_id, g.compromisso_id, g.data, g.valor,
       g.nucleo_economico_id, g.centro_custo_id, g.divisao_id,
       erp.pagamento_saldo(g.id) as saldo
from erp.pagamentos g where erp.pagamento_saldo(g.id) > 0;

create view erp.v_caucao with (security_invoker = true) as
select compromisso_id,
       sum(valor) filter (where tipo = 'retencao') - coalesce(sum(valor) filter (where tipo = 'estorno'), 0) as retido,
       coalesce(sum(valor) filter (where tipo = 'liberacao'), 0) as liberado,
       coalesce(sum(valor) filter (where tipo = 'uso_terceiro'), 0) as usado_com_terceiros,
       erp.caucao_saldo(compromisso_id) as saldo
from erp.caucao_movimentos group by compromisso_id;

-- Previsto × realizado de cada previsão.
create view erp.v_previsoes with (security_invoker = true) as
select p.*, coalesce(c.consumido, 0) as consumido, p.valor - coalesce(c.consumido, 0) as saldo
from erp.previsoes p
left join (select tp.previsao_id, sum(tp.valor) as consumido from erp.titulo_previsoes tp join erp.titulos t on t.id = tp.titulo_id
           where t.situacao <> 'cancelado' group by 1) c on c.previsao_id = p.id;

-- Fluxo de caixa: previsto em aberto + comprometido em aberto + realizado, por dia de caixa.
-- Não é tabela: é a soma do livro.
create view erp.v_fluxo_caixa with (security_invoker = true) as
select l.empresa_id, l.data_caixa,
       coalesce(sum(l.valor) filter (where l.estagio = 'previsto'), 0)     as previsto,
       coalesce(sum(l.valor) filter (where l.estagio = 'comprometido'), 0) as comprometido,
       coalesce(sum(l.valor) filter (where l.estagio = 'realizado'), 0)    as realizado,
       sum(l.valor) as projetado
from erp.lancamentos l
where l.estagio <> 'orcado' and l.data_caixa is not null
group by l.empresa_id, l.data_caixa;

-- Livro com tudo junto para BI e agentes: nomes, árvore, características da natureza
-- e os atributos do empreendimento vigentes na competência de cada linha.
create view erp.v_lancamentos_bi with (security_invoker = true) as
select l.id, l.estagio, ov.tipo as orcamento_tipo, ov.nome as orcamento_versao,
       l.competencia, l.data_caixa, l.valor,
       pe.nome as empresa, e.tipo as empresa_tipo,
       ne.nome as nucleo_economico, ne.tipo as nucleo_tipo, cc.nome as centro_custo,
       em.codigo as empreendimento_codigo, em.nome as empreendimento, em.municipio, em.uf,
       vn.caminho as natureza, vn.nivel1, vn.nivel2, vn.nivel3, vn.nivel4,
       vn.tipo as natureza_tipo, ld.nome as linha_dre, vn.linha_dfc,
       (select jsonb_object_agg(a.codigo, ea.valor)
          from erp.empreendimento_atributos ea join erp.atributos a on a.id = ea.atributo_id
         where ea.empreendimento_id = em.id
           and l.competencia between ea.inicio and coalesce(ea.fim, 'infinity')) as atributos,
       l.empresa_id, l.nucleo_economico_id, l.centro_custo_id, l.natureza_id, em.id as empreendimento_id,
       l.titulo_id, l.previsao_id, l.quitacao_id, l.pagamento_id
from erp.lancamentos l
join erp.empresas e on e.id = l.empresa_id
join erp.pessoas pe on pe.id = e.pessoa_id
join erp.v_naturezas vn on vn.id = l.natureza_id
join erp.linhas_dre ld on ld.codigo = vn.linha_dre
left join erp.orcamento_versoes ov on ov.id = l.orcamento_versao_id
left join erp.nucleos_economicos ne on ne.id = l.nucleo_economico_id
left join erp.empreendimentos em on em.id = ne.empreendimento_id
left join erp.centros_custo cc on cc.id = l.centro_custo_id;
