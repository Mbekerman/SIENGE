-- Núcleo do ERP BKM: do compromisso ao pagamento, e o livro de lançamentos.
-- compromisso → previsão → documento fiscal → título → parcela; pagamento ↔ quitação.
-- Cada estágio escreve no livro (nucleo.lancamentos); o livro só recebe linhas novas
-- (estorno é linha de sinal contrário) e só muda a natureza, pela reclassificação.
-- Sinal no livro: entrada positiva, saída negativa. Nas tabelas de origem, valores positivos.

-- ---------------------------------------------------------------------
-- Classificação comum (centro, natureza, fase, departamento) e o rateio
-- ---------------------------------------------------------------------
-- Natureza usada em movimento: precisa ser do último nível e ativa.
create function nucleo.checar_natureza(p_natureza uuid, p_centro uuid, p_orcado boolean default false)
returns void language plpgsql stable as $$
declare n nucleo.naturezas;
begin
  select * into n from nucleo.naturezas where id = p_natureza;
  if not found then raise exception 'Natureza inexistente'; end if;
  if not nucleo.natureza_folha(p_natureza) then
    raise exception 'Só se lança no último nível da árvore; "%" tem galhos abaixo', n.nome;
  end if;
  if not n.ativa then raise exception 'A natureza "%" está desativada', n.nome; end if;
  if n.so_orcado and not p_orcado then
    raise exception 'A natureza "%" é só do orçado e não recebe previsão, título ou pagamento', n.nome;
  end if;
  if p_centro is null and n.tipo <> 'movimentacao' then
    raise exception 'Falta o centro de custo (só movimentações dispensam)';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Bancos
-- ---------------------------------------------------------------------
create table nucleo.contas_bancarias (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references nucleo.empresas,
  banco      text not null,
  agencia    text,
  conta      text,
  descricao  text,
  ativa      boolean not null default true
);

create table nucleo.lotes_bancarios (           -- só agrupamento de envio ao banco
  id         uuid primary key default gen_random_uuid(),
  conta_id   uuid not null references nucleo.contas_bancarias,
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz,
  situacao   text not null default 'aberto' check (situacao in ('aberto','enviado','retornado','cancelado'))
);

-- ---------------------------------------------------------------------
-- Compromisso: o acordo que gera gasto
-- ---------------------------------------------------------------------
create table nucleo.compromissos (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references nucleo.empresas,
  tipo              text not null check (tipo in ('contrato','pedido','assinatura','avulsa','guia','folha')),
  pessoa_id         uuid references nucleo.pessoas,      -- fornecedor
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
  criado_em         timestamptz not null default now(),
  check (fim is null or fim >= inicio),
  -- a assinatura recorrente substitui o contrato fictício: tem periodicidade e valor por período
  check (tipo <> 'assinatura' or (periodicidade is not null and valor_periodo is not null))
);

create table nucleo.compromisso_rateios (
  id              uuid primary key default gen_random_uuid(),
  compromisso_id  uuid not null references nucleo.compromissos on delete cascade,
  centro_id       uuid references nucleo.centros_custo,
  natureza_id     uuid not null references nucleo.naturezas,
  fase_id         uuid references nucleo.fases,
  departamento_id uuid references nucleo.departamentos,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
);

-- ---------------------------------------------------------------------
-- Orçamento: versões datadas, nunca sobrescritas
-- ---------------------------------------------------------------------
create table nucleo.orcamento_versoes (
  id                uuid primary key default gen_random_uuid(),
  empresa_id        uuid not null references nucleo.empresas,
  empreendimento_id uuid references nucleo.empreendimentos,
  tipo              text not null check (tipo in ('viabilidade','aprovado','reprojecao')),
  nome              text not null,
  data_base         date not null,
  situacao          text not null default 'rascunho' check (situacao in ('rascunho','vigente','substituida')),
  criada_em         timestamptz not null default now(),
  criada_por        uuid default nucleo.eu()
);

create table nucleo.orcamento_linhas (
  id              uuid primary key default gen_random_uuid(),
  versao_id       uuid not null references nucleo.orcamento_versoes on delete cascade,
  centro_id       uuid references nucleo.centros_custo,
  natureza_id     uuid not null references nucleo.naturezas,
  fase_id         uuid references nucleo.fases,
  departamento_id uuid references nucleo.departamentos,
  competencia     date not null check (extract(day from competencia) = 1),
  data_caixa      date,
  valor           numeric(15,2) not null check (valor <> 0)   -- com sinal: receita +, gasto −
);

-- ---------------------------------------------------------------------
-- Previsão: gasto esperado que ainda não é dívida (substitui o título de previsão)
-- ---------------------------------------------------------------------
create table nucleo.previsoes (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null references nucleo.empresas,
  sentido         text not null default 'pagar' check (sentido in ('pagar','receber')),
  origem          text not null check (origem in ('orcamento','assinatura','saldo_contrato','cronograma','manual')),
  compromisso_id  uuid references nucleo.compromissos,
  pessoa_id       uuid references nucleo.pessoas,
  centro_id       uuid references nucleo.centros_custo,
  natureza_id     uuid not null references nucleo.naturezas,
  fase_id         uuid references nucleo.fases,
  departamento_id uuid references nucleo.departamentos,
  competencia     date not null check (extract(day from competencia) = 1),
  data_prevista   date not null,
  valor           numeric(15,2) not null check (valor > 0),
  descricao       text,
  situacao        text not null default 'aberta' check (situacao in ('aberta','consumida','cancelada')),
  criada_em       timestamptz not null default now()
);
create index on nucleo.previsoes (compromisso_id) where situacao = 'aberta';

-- ---------------------------------------------------------------------
-- Documento fiscal: a nota, o boleto ou a guia que chegou
-- ---------------------------------------------------------------------
create table nucleo.documentos_fiscais (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references nucleo.empresas,
  emitente_id    uuid not null references nucleo.pessoas,
  compromisso_id uuid references nucleo.compromissos,
  tipo           text not null check (tipo in ('nfse','nfe','fatura','boleto','guia','recibo','outro')),
  numero         text not null,
  serie          text not null default '',
  emissao        date not null,
  competencia    date not null check (extract(day from competencia) = 1),
  valor_bruto    numeric(15,2) not null check (valor_bruto > 0),
  caucao_valor   numeric(15,2) check (caucao_valor >= 0),  -- vem do contrato; pode ser alterada aqui
  situacao       text not null default 'rascunho' check (situacao in ('rascunho','lancado','cancelado')),
  lancado_em     timestamptz,
  criado_em      timestamptz not null default now()
);
-- Trava de duplicidade que o Sienge não tem (lá a NFS-e aceita número repetido).
create unique index documentos_fiscais_unico on nucleo.documentos_fiscais (emitente_id, tipo, numero, serie)
  where situacao <> 'cancelado';

create table nucleo.documento_retencoes (
  documento_id uuid not null references nucleo.documentos_fiscais on delete cascade,
  imposto      text not null check (imposto in ('iss','inss','irrf','pis','cofins','csll','pcc','outro')),
  valor        numeric(15,2) not null check (valor > 0),
  orgao_id     uuid not null references nucleo.pessoas,   -- quem recebe a guia (prefeitura, Receita...)
  vencimento   date not null,
  primary key (documento_id, imposto)
);

create table nucleo.documento_rateios (
  id              uuid primary key default gen_random_uuid(),
  documento_id    uuid not null references nucleo.documentos_fiscais on delete cascade,
  centro_id       uuid references nucleo.centros_custo,
  natureza_id     uuid not null references nucleo.naturezas,
  fase_id         uuid references nucleo.fases,
  departamento_id uuid references nucleo.departamentos,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
);

-- ---------------------------------------------------------------------
-- Título: a dívida real (ou o direito a receber), com N parcelas
-- ---------------------------------------------------------------------
create table nucleo.titulos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references nucleo.empresas,
  sentido        text not null default 'pagar' check (sentido in ('pagar','receber')),
  tipo           text not null check (tipo in ('fornecedor','imposto','caucao','societario','avulso')),
  pessoa_id      uuid not null references nucleo.pessoas,
  documento_id   uuid references nucleo.documentos_fiscais,
  compromisso_id uuid references nucleo.compromissos,
  numero         text,
  emissao        date not null,
  competencia    date not null check (extract(day from competencia) = 1),
  valor          numeric(15,2) not null check (valor > 0),
  descricao      text,
  situacao       text not null default 'rascunho' check (situacao in ('rascunho','aberto','quitado','cancelado')),
  criado_em      timestamptz not null default now()
);

create table nucleo.titulo_rateios (
  id              uuid primary key default gen_random_uuid(),
  titulo_id       uuid not null references nucleo.titulos on delete cascade,
  centro_id       uuid references nucleo.centros_custo,
  natureza_id     uuid not null references nucleo.naturezas,
  fase_id         uuid references nucleo.fases,
  departamento_id uuid references nucleo.departamentos,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
);

create table nucleo.parcelas (
  id         uuid primary key default gen_random_uuid(),
  titulo_id  uuid not null references nucleo.titulos on delete cascade,
  numero     int not null check (numero > 0),
  vencimento date not null,
  valor      numeric(15,2) not null check (valor > 0),
  unique (titulo_id, numero)
);

-- Quanto de cada previsão o título consumiu (a diferença previsto × realizado sai daqui).
create table nucleo.titulo_previsoes (
  titulo_id   uuid not null references nucleo.titulos,
  previsao_id uuid not null references nucleo.previsoes,
  valor       numeric(15,2) not null check (valor > 0),
  primary key (titulo_id, previsao_id)
);

-- ---------------------------------------------------------------------
-- Pagamento (o dinheiro que saiu) e quitação (quanto dele quitou cada parcela)
-- ---------------------------------------------------------------------
create table nucleo.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references nucleo.empresas,
  conta_id       uuid not null references nucleo.contas_bancarias,
  pessoa_id      uuid not null references nucleo.pessoas,       -- favorecido
  compromisso_id uuid references nucleo.compromissos,           -- adiantamento vinculado a contrato
  lote_id        uuid references nucleo.lotes_bancarios,
  data           date not null,
  valor          numeric(15,2) not null check (valor > 0),
  forma          text not null default 'pix' check (forma in ('pix','ted','boleto','debito','cheque','dinheiro','outro')),
  descricao      text,
  criado_em      timestamptz not null default now()
);

create table nucleo.quitacoes (
  id           uuid primary key default gen_random_uuid(),
  pagamento_id uuid not null references nucleo.pagamentos,
  parcela_id   uuid not null references nucleo.parcelas,
  principal    numeric(15,2) not null check (principal > 0),
  juros        numeric(15,2) not null default 0 check (juros >= 0),   -- só se sabem na hora de pagar
  multa        numeric(15,2) not null default 0 check (multa >= 0),
  desconto     numeric(15,2) not null default 0 check (desconto >= 0),
  criada_em    timestamptz not null default now(),
  check (principal + juros + multa - desconto > 0)
);
create index on nucleo.quitacoes (parcela_id);
create index on nucleo.quitacoes (pagamento_id);

-- ---------------------------------------------------------------------
-- Caução: extrato por contrato
-- ---------------------------------------------------------------------
create table nucleo.caucao_movimentos (
  id             uuid primary key default gen_random_uuid(),
  compromisso_id uuid not null references nucleo.compromissos,
  tipo           text not null check (tipo in ('retencao','liberacao','uso_terceiro')),
  valor          numeric(15,2) not null check (valor > 0),
  documento_id   uuid references nucleo.documentos_fiscais,   -- na retenção
  titulo_id      uuid references nucleo.titulos,              -- na liberação e no uso
  motivo         text,
  em             timestamptz not null default now(),
  por            uuid default nucleo.eu(),
  check ((tipo = 'retencao') = (documento_id is not null)),
  check (tipo = 'retencao' or titulo_id is not null),
  check (tipo <> 'uso_terceiro' or motivo is not null)
);

-- ---------------------------------------------------------------------
-- Dinheiro entre sócios: par ligado de títulos entre duas empresas
-- ---------------------------------------------------------------------
create table nucleo.movimentos_societarios (
  id                uuid primary key default gen_random_uuid(),
  tipo              text not null check (tipo in ('aporte','integralizacao','distribuicao','mutuo','devolucao_mutuo')),
  pagadora_id       uuid not null references nucleo.empresas,
  recebedora_id     uuid not null references nucleo.empresas,
  data              date not null,
  valor             numeric(15,2) not null check (valor > 0),
  titulo_pagar_id   uuid not null references nucleo.titulos,
  titulo_receber_id uuid not null references nucleo.titulos,
  descricao         text,
  criado_em         timestamptz not null default now(),
  check (pagadora_id <> recebedora_id)
);

-- ---------------------------------------------------------------------
-- O livro de lançamentos
-- ---------------------------------------------------------------------
create table nucleo.lancamentos (
  id                  bigint generated always as identity primary key,
  estagio             text not null check (estagio in ('orcado','previsto','comprometido','realizado')),
  orcamento_versao_id uuid references nucleo.orcamento_versoes,
  empresa_id          uuid not null references nucleo.empresas,
  centro_id           uuid references nucleo.centros_custo,
  natureza_id         uuid not null references nucleo.naturezas,
  fase_id             uuid references nucleo.fases,
  departamento_id     uuid references nucleo.departamentos,
  competencia         date not null check (extract(day from competencia) = 1),
  data_caixa          date,             -- nula = sem data (caução retida)
  valor               numeric(15,2) not null check (valor <> 0),
  -- origem
  orcamento_linha_id  uuid references nucleo.orcamento_linhas,
  previsao_id         uuid references nucleo.previsoes,
  titulo_id           uuid references nucleo.titulos,
  parcela_id          uuid references nucleo.parcelas,
  quitacao_id         uuid references nucleo.quitacoes,
  pagamento_id        uuid references nucleo.pagamentos,
  caucao_movimento_id uuid references nucleo.caucao_movimentos,
  criado_em           timestamptz not null default clock_timestamp(),
  check ((estagio = 'orcado') = (orcamento_versao_id is not null))
);
create index on nucleo.lancamentos (natureza_id);
create index on nucleo.lancamentos (empresa_id, competencia);
create index on nucleo.lancamentos (titulo_id);
create index on nucleo.lancamentos (previsao_id);

create function nucleo.tg_lancamento() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'O livro não apaga linhas; estorne com uma linha de sinal contrário'; end if;
  if tg_op = 'UPDATE' then
    if current_setting('nucleo.reclassificando', true) is distinct from 'on' then
      raise exception 'O livro não muda; a natureza só muda pela reclassificação';
    end if;
    if (to_jsonb(new) - 'natureza_id') <> (to_jsonb(old) - 'natureza_id') then
      raise exception 'A reclassificação só muda a natureza';
    end if;
  end if;
  perform nucleo.checar_natureza(new.natureza_id, new.centro_id, new.estagio = 'orcado');
  return new;
end $$;
create trigger t_lancamento before insert or update or delete on nucleo.lancamentos
  for each row execute function nucleo.tg_lancamento();

-- Agora a árvore sabe dizer se uma natureza (ou galho abaixo) está em uso.
create or replace function nucleo.natureza_em_uso(p_id uuid) returns boolean language sql stable as $$
  with recursive sub as (
    select id from nucleo.naturezas where id = p_id
    union all select n.id from nucleo.naturezas n join sub on n.mae_id = sub.id)
  select exists (select 1 from nucleo.lancamentos where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.previsoes where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.titulo_rateios where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.documento_rateios where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.compromisso_rateios where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.orcamento_linhas where natureza_id in (select id from sub))
      or exists (select 1 from nucleo.naturezas_sistema where natureza_id in (select id from sub))
$$;

-- Natureza válida em toda tabela de classificação.
create function nucleo.tg_classificacao() returns trigger language plpgsql as $$
begin
  perform nucleo.checar_natureza(new.natureza_id, new.centro_id, tg_table_name = 'orcamento_linhas');
  return new;
end $$;
create trigger t_class before insert or update of natureza_id, centro_id on nucleo.compromisso_rateios
  for each row execute function nucleo.tg_classificacao();
create trigger t_class before insert or update of natureza_id, centro_id on nucleo.documento_rateios
  for each row execute function nucleo.tg_classificacao();
create trigger t_class before insert or update of natureza_id, centro_id on nucleo.titulo_rateios
  for each row execute function nucleo.tg_classificacao();
create trigger t_class before insert or update of natureza_id, centro_id on nucleo.previsoes
  for each row execute function nucleo.tg_classificacao();
create trigger t_class before insert or update of natureza_id, centro_id on nucleo.orcamento_linhas
  for each row execute function nucleo.tg_classificacao();

-- Rateio de um registro (compromisso, documento ou título) dividindo um total em centavos exatos:
-- cada parte = arredondamento do acumulado menos o do acumulado anterior, então a soma fecha.
create function nucleo.ratear(p_origem text, p_id uuid, p_total numeric)
returns table (centro_id uuid, natureza_id uuid, fase_id uuid, departamento_id uuid, valor numeric)
language sql stable as $$
  with r as (
    select centro_id, natureza_id, fase_id, departamento_id, percentual, id from nucleo.compromisso_rateios
      where p_origem = 'compromisso' and compromisso_id = p_id
    union all
    select centro_id, natureza_id, fase_id, departamento_id, percentual, id from nucleo.documento_rateios
      where p_origem = 'documento' and documento_id = p_id
    union all
    select centro_id, natureza_id, fase_id, departamento_id, percentual, id from nucleo.titulo_rateios
      where p_origem = 'titulo' and titulo_id = p_id
  ), a as (
    select r.*, sum(percentual) over (order by percentual desc, id) as acum,
           sum(percentual) over () as total_pct
    from r
  )
  select centro_id, natureza_id, fase_id, departamento_id,
         round(p_total * acum / total_pct, 2) - round(p_total * (acum - percentual) / total_pct, 2)
  from a
$$;

create function nucleo.rateio_completo(p_origem text, p_id uuid) returns boolean language sql stable as $$
  select coalesce(sum(percentual), 0) = 100 from (
    select percentual from nucleo.compromisso_rateios where p_origem = 'compromisso' and compromisso_id = p_id
    union all select percentual from nucleo.documento_rateios where p_origem = 'documento' and documento_id = p_id
    union all select percentual from nucleo.titulo_rateios where p_origem = 'titulo' and titulo_id = p_id) r
$$;

create function nucleo.mes(d date) returns date language sql immutable as
  $$ select date_trunc('month', d)::date $$;

create function nucleo.sinal(p_sentido text) returns int language sql immutable as
  $$ select case p_sentido when 'receber' then 1 else -1 end $$;

create function nucleo.natureza_sistema(p_chave text) returns uuid language sql stable as
  $$ select natureza_id from nucleo.naturezas_sistema where chave = p_chave $$;

-- ---------------------------------------------------------------------
-- Orçamento → livro (estágio orçado)
-- ---------------------------------------------------------------------
create function nucleo.tg_orcamento_linha() returns trigger language plpgsql as $$
declare v nucleo.orcamento_versoes;
begin
  select * into v from nucleo.orcamento_versoes where id = coalesce(new.versao_id, old.versao_id);
  if v.situacao <> 'rascunho' then raise exception 'Versão de orçamento % não muda; crie uma reprojeção', v.situacao; end if;
  return coalesce(new, old);
end $$;
create trigger t_orc_linha before insert or update or delete on nucleo.orcamento_linhas
  for each row execute function nucleo.tg_orcamento_linha();

-- Publicar a versão grava as linhas no livro e substitui a vigente do mesmo tipo.
create function nucleo.publicar_orcamento(p_versao uuid) returns void language plpgsql as $$
declare v nucleo.orcamento_versoes;
begin
  perform nucleo.exigir_editor();
  select * into v from nucleo.orcamento_versoes where id = p_versao for update;
  if v.situacao <> 'rascunho' then raise exception 'Só se publica versão em rascunho'; end if;
  update nucleo.orcamento_versoes set situacao = 'substituida'
   where empresa_id = v.empresa_id and empreendimento_id is not distinct from v.empreendimento_id
     and tipo = v.tipo and situacao = 'vigente' and tipo <> 'reprojecao';
  insert into nucleo.lancamentos (estagio, orcamento_versao_id, empresa_id, centro_id, natureza_id, fase_id,
                                  departamento_id, competencia, data_caixa, valor, orcamento_linha_id)
  select 'orcado', v.id, v.empresa_id, l.centro_id, l.natureza_id, l.fase_id, l.departamento_id,
         l.competencia, l.data_caixa, l.valor, l.id
  from nucleo.orcamento_linhas l where l.versao_id = v.id;
  update nucleo.orcamento_versoes set situacao = 'vigente' where id = v.id;
end $$;

-- ---------------------------------------------------------------------
-- Previsão → livro (estágio previsto)
-- ---------------------------------------------------------------------
create function nucleo.previsao_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(valor) from nucleo.titulo_previsoes where previsao_id = p.id), 0)
  from nucleo.previsoes p where p.id = p_id $$;

create function nucleo.tg_previsao() returns trigger language plpgsql as $$
declare v_saldo numeric;
begin
  if tg_op = 'INSERT' then
    insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                    competencia, data_caixa, valor, previsao_id)
    values ('previsto', new.empresa_id, new.centro_id, new.natureza_id, new.fase_id, new.departamento_id,
            new.competencia, new.data_prevista, nucleo.sinal(new.sentido) * new.valor, new.id);
    return new;
  end if;
  if (to_jsonb(new) - 'situacao' - 'natureza_id') <> (to_jsonb(old) - 'situacao' - 'natureza_id') then
    raise exception 'Previsão não se edita; cancele e crie outra';
  end if;
  if new.natureza_id <> old.natureza_id and current_setting('nucleo.reclassificando', true) is distinct from 'on' then
    raise exception 'A natureza da previsão só muda pela reclassificação';
  end if;
  if new.situacao = 'cancelada' and old.situacao = 'aberta' then
    v_saldo := nucleo.previsao_saldo(new.id);
    if v_saldo > 0 then
      insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                      competencia, data_caixa, valor, previsao_id)
      values ('previsto', new.empresa_id, new.centro_id, new.natureza_id, new.fase_id, new.departamento_id,
              new.competencia, new.data_prevista, -nucleo.sinal(new.sentido) * v_saldo, new.id);
    end if;
  elsif new.situacao <> old.situacao and current_setting('nucleo.sistema', true) is distinct from 'on' then
    raise exception 'A previsão só pode ser cancelada; ela é consumida pelos títulos';
  end if;
  return new;
end $$;
create trigger t_previsao after insert or update on nucleo.previsoes
  for each row execute function nucleo.tg_previsao();

-- Consumo da previsão pelo título: estorna o previsto na data da previsão.
create function nucleo.tg_titulo_previsao() returns trigger language plpgsql as $$
declare p nucleo.previsoes; v_saldo numeric;
begin
  select * into p from nucleo.previsoes where id = new.previsao_id for update;
  if p.situacao <> 'aberta' then raise exception 'A previsão não está aberta'; end if;
  if p.empresa_id <> (select empresa_id from nucleo.titulos where id = new.titulo_id) then
    raise exception 'Previsão e título são de empresas diferentes';
  end if;
  v_saldo := p.valor - coalesce((select sum(valor) from nucleo.titulo_previsoes
                                 where previsao_id = p.id and titulo_id <> new.titulo_id), 0);
  if new.valor > v_saldo then raise exception 'O consumo (%) passa do saldo da previsão (%)', new.valor, v_saldo; end if;
  insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                  competencia, data_caixa, valor, previsao_id, titulo_id)
  values ('previsto', p.empresa_id, p.centro_id, p.natureza_id, p.fase_id, p.departamento_id,
          p.competencia, p.data_prevista, -nucleo.sinal(p.sentido) * new.valor, p.id, new.titulo_id);
  if new.valor = v_saldo then
    perform set_config('nucleo.sistema', 'on', true);
    update nucleo.previsoes set situacao = 'consumida' where id = p.id;
    perform set_config('nucleo.sistema', 'off', true);
  end if;
  return new;
end $$;
create trigger t_titulo_previsao before insert on nucleo.titulo_previsoes
  for each row execute function nucleo.tg_titulo_previsao();
create function nucleo.tg_imutavel() returns trigger language plpgsql as $$
begin raise exception 'Registro de % não se altera nem se apaga', tg_table_name; end $$;
create trigger t_imutavel before update or delete on nucleo.titulo_previsoes
  for each row execute function nucleo.tg_imutavel();

-- Assinatura recorrente: gera as previsões de cada período até a data pedida.
create function nucleo.gerar_previsoes_assinatura(p_compromisso uuid, p_ate date) returns int
language plpgsql as $$
declare c nucleo.compromissos; d date; v_passo interval; n int := 0; r record;
begin
  perform nucleo.exigir_editor();
  select * into c from nucleo.compromissos where id = p_compromisso;
  if c.tipo <> 'assinatura' or c.situacao <> 'ativo' then raise exception 'Só assinatura ativa gera previsões'; end if;
  if not nucleo.rateio_completo('compromisso', c.id) then raise exception 'O rateio da assinatura não soma 100%%'; end if;
  v_passo := case c.periodicidade when 'mensal' then '1 month' when 'bimestral' then '2 months'
             when 'trimestral' then '3 months' when 'semestral' then '6 months' else '1 year' end::interval;
  d := nucleo.mes(c.inicio);
  while d <= least(p_ate, coalesce(c.fim, p_ate)) loop
    if not exists (select 1 from nucleo.previsoes where compromisso_id = c.id and competencia = d and situacao <> 'cancelada') then
      for r in select * from nucleo.ratear('compromisso', c.id, c.valor_periodo) loop
        insert into nucleo.previsoes (empresa_id, origem, compromisso_id, pessoa_id, centro_id, natureza_id, fase_id,
                                      departamento_id, competencia, data_prevista, valor, descricao)
        values (c.empresa_id, 'assinatura', c.id, c.pessoa_id, r.centro_id, r.natureza_id, r.fase_id, r.departamento_id,
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
create function nucleo.tg_titulo() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' then
    if (to_jsonb(new) - 'situacao') <> (to_jsonb(old) - 'situacao') then
      raise exception 'Título confirmado não se edita';
    end if;
    if current_setting('nucleo.sistema', true) is distinct from 'on' then
      raise exception 'A situação do título muda pelas quitações';
    end if;
  end if;
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then
    raise exception 'Título confirmado não se apaga';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_titulo before update or delete on nucleo.titulos
  for each row execute function nucleo.tg_titulo();

-- Parcelas e rateio só mudam com o título em rascunho (a natureza também pela reclassificação).
create function nucleo.tg_filho_titulo() returns trigger language plpgsql as $$
declare v_sit text;
begin
  select situacao into v_sit from nucleo.titulos where id = coalesce(new.titulo_id, old.titulo_id);
  if v_sit is null or v_sit = 'rascunho' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and tg_table_name = 'titulo_rateios'
     and current_setting('nucleo.reclassificando', true) = 'on'
     and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then
    return new;
  end if;
  raise exception 'O título já foi confirmado; % não muda', tg_table_name;
end $$;
create trigger t_filho before insert or update or delete on nucleo.parcelas
  for each row execute function nucleo.tg_filho_titulo();
create trigger t_filho before insert or update or delete on nucleo.titulo_rateios
  for each row execute function nucleo.tg_filho_titulo();

create function nucleo.confirmar_titulo(p_titulo uuid) returns void language plpgsql as $$
declare t nucleo.titulos; p record; r record;
begin
  perform nucleo.exigir_editor();
  select * into t from nucleo.titulos where id = p_titulo for update;
  if t.situacao <> 'rascunho' then raise exception 'O título já foi confirmado'; end if;
  if not nucleo.rateio_completo('titulo', t.id) then raise exception 'O rateio do título não soma 100%%'; end if;
  if coalesce((select sum(valor) from nucleo.parcelas where titulo_id = t.id), 0) <> t.valor then
    raise exception 'As parcelas não somam o valor do título';
  end if;
  for p in select * from nucleo.parcelas where titulo_id = t.id order by numero loop
    for r in select * from nucleo.ratear('titulo', t.id, p.valor) loop
      insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                      competencia, data_caixa, valor, titulo_id, parcela_id)
      values ('comprometido', t.empresa_id, r.centro_id, r.natureza_id, r.fase_id, r.departamento_id,
              t.competencia, p.vencimento, nucleo.sinal(t.sentido) * r.valor, t.id, p.id);
    end loop;
  end loop;
  perform set_config('nucleo.sistema', 'on', true);
  update nucleo.titulos set situacao = 'aberto' where id = t.id;
  perform set_config('nucleo.sistema', 'off', true);
end $$;

-- Cria título com parcelas iguais (o resto dos centavos na última) e o rateio dado.
create function nucleo._criar_titulo(p_empresa uuid, p_sentido text, p_tipo text, p_pessoa uuid, p_documento uuid,
  p_compromisso uuid, p_emissao date, p_competencia date, p_valor numeric, p_vencimentos date[],
  p_rateio_origem text, p_rateio_id uuid, p_descricao text) returns uuid language plpgsql as $$
declare v_id uuid; n int := array_length(p_vencimentos, 1); i int; v_parc numeric;
begin
  insert into nucleo.titulos (empresa_id, sentido, tipo, pessoa_id, documento_id, compromisso_id, emissao, competencia, valor, descricao)
  values (p_empresa, p_sentido, p_tipo, p_pessoa, p_documento, p_compromisso, p_emissao, p_competencia, p_valor, p_descricao)
  returning id into v_id;
  for i in 1..n loop
    v_parc := case when i < n then trunc(p_valor / n, 2) else p_valor - trunc(p_valor / n, 2) * (n - 1) end;
    insert into nucleo.parcelas (titulo_id, numero, vencimento, valor) values (v_id, i, p_vencimentos[i], v_parc);
  end loop;
  if p_rateio_origem is not null then
    insert into nucleo.titulo_rateios (titulo_id, centro_id, natureza_id, fase_id, departamento_id, percentual)
    select v_id, centro_id, natureza_id, fase_id, departamento_id, percentual from (
      select centro_id, natureza_id, fase_id, departamento_id, percentual from nucleo.compromisso_rateios
        where p_rateio_origem = 'compromisso' and compromisso_id = p_rateio_id
      union all
      select centro_id, natureza_id, fase_id, departamento_id, percentual from nucleo.documento_rateios
        where p_rateio_origem = 'documento' and documento_id = p_rateio_id) r;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Lançar a nota: título do fornecedor pelo líquido, um título por imposto retido
-- e a retenção da caução no extrato do contrato. Consome as previsões.
-- ---------------------------------------------------------------------
create function nucleo.lancar_documento(p_documento uuid, p_vencimentos date[], p_previsoes uuid[] default null)
returns uuid language plpgsql as $$
declare d nucleo.documentos_fiscais; v_ret numeric; v_liquido numeric; v_tit uuid; v_imp uuid; r record;
        v_resta numeric; v_cons numeric; p record;
begin
  perform nucleo.exigir_editor();
  select * into d from nucleo.documentos_fiscais where id = p_documento for update;
  if d.situacao <> 'rascunho' then raise exception 'O documento já foi lançado'; end if;
  if coalesce(array_length(p_vencimentos, 1), 0) = 0 then raise exception 'Informe ao menos um vencimento'; end if;
  if not nucleo.rateio_completo('documento', d.id) then raise exception 'O rateio do documento não soma 100%%'; end if;
  if d.caucao_valor is null then
    d.caucao_valor := round(d.valor_bruto * coalesce((select caucao_percentual from nucleo.compromissos where id = d.compromisso_id), 0) / 100, 2);
  end if;
  if d.caucao_valor > 0 and d.compromisso_id is null then raise exception 'Caução só existe com contrato'; end if;
  select coalesce(sum(valor), 0) into v_ret from nucleo.documento_retencoes where documento_id = d.id;
  v_liquido := d.valor_bruto - v_ret - d.caucao_valor;
  if v_liquido <= 0 then raise exception 'Retenções e caução passam do valor da nota'; end if;

  v_tit := nucleo._criar_titulo(d.empresa_id, 'pagar', 'fornecedor', d.emitente_id, d.id, d.compromisso_id,
                                d.emissao, d.competencia, v_liquido, p_vencimentos, 'documento', d.id, null);
  perform nucleo.confirmar_titulo(v_tit);

  for r in select * from nucleo.documento_retencoes where documento_id = d.id loop
    v_imp := nucleo._criar_titulo(d.empresa_id, 'pagar', 'imposto', r.orgao_id, d.id, d.compromisso_id,
                                  d.emissao, d.competencia, r.valor, array[r.vencimento], 'documento', d.id,
                                  upper(r.imposto) || ' retido na nota ' || d.numero);
    perform nucleo.confirmar_titulo(v_imp);
  end loop;

  if d.caucao_valor > 0 then
    insert into nucleo.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
    values (d.compromisso_id, 'retencao', d.caucao_valor, d.id);
  end if;

  -- consumo das previsões (as dadas, ou as abertas do mesmo contrato, da mais antiga), até o bruto
  v_resta := d.valor_bruto;
  for p in
    select pr.id from nucleo.previsoes pr
    where pr.situacao = 'aberta' and pr.sentido = 'pagar'
      and (case when p_previsoes is not null then pr.id = any(p_previsoes)
                else d.compromisso_id is not null and pr.compromisso_id = d.compromisso_id end)
    order by pr.data_prevista, pr.criada_em
  loop
    exit when v_resta <= 0;
    v_cons := least(v_resta, nucleo.previsao_saldo(p.id));
    insert into nucleo.titulo_previsoes (titulo_id, previsao_id, valor) values (v_tit, p.id, v_cons);
    v_resta := v_resta - v_cons;
  end loop;

  update nucleo.documentos_fiscais set situacao = 'lancado', lancado_em = now(), caucao_valor = d.caucao_valor where id = d.id;
  return v_tit;
end $$;

create function nucleo.tg_documento() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then raise exception 'Documento lançado não se apaga'; end if;
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' and (to_jsonb(new) - 'situacao') <> (to_jsonb(old) - 'situacao') then
    raise exception 'Documento lançado não se edita';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_documento before update or delete on nucleo.documentos_fiscais
  for each row execute function nucleo.tg_documento();

-- ---------------------------------------------------------------------
-- Pagamento e quitação → livro (estágio realizado)
-- O pagamento entra inteiro em "Adiantamentos" (movimentação, sem centro);
-- cada quitação tira dali e lança na natureza do título. Pagamento sem quitação
-- é adiantamento, abatido depois por novas quitações, em vários títulos.
-- ---------------------------------------------------------------------
create function nucleo.tg_pagamento() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Pagamento não se altera; o estorno virá no módulo de bancos'; end if;
  if (select empresa_id from nucleo.contas_bancarias where id = new.conta_id) <> new.empresa_id then
    raise exception 'A conta não é da empresa do pagamento';
  end if;
  insert into nucleo.lancamentos (estagio, empresa_id, natureza_id, competencia, data_caixa, valor, pagamento_id)
  values ('realizado', new.empresa_id, nucleo.natureza_sistema('adiantamentos'), nucleo.mes(new.data), new.data, -new.valor, new.id);
  return new;
end $$;
create trigger t_pagamento after insert or update or delete on nucleo.pagamentos
  for each row execute function nucleo.tg_pagamento();

create function nucleo.parcela_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(principal) from nucleo.quitacoes where parcela_id = p.id), 0)
  from nucleo.parcelas p where p.id = p_id $$;

create function nucleo.pagamento_saldo(p_id uuid) returns numeric language sql stable as $$
  select g.valor - coalesce((select sum(principal + juros + multa - desconto) from nucleo.quitacoes where pagamento_id = g.id), 0)
  from nucleo.pagamentos g where g.id = p_id $$;

create function nucleo.tg_quitacao() returns trigger language plpgsql as $$
declare g nucleo.pagamentos; pa nucleo.parcelas; t nucleo.titulos; r record; v_total numeric;
        v_centro uuid; v_fase uuid; v_dep uuid; v_comp date;
begin
  select * into g from nucleo.pagamentos where id = new.pagamento_id for update;
  select * into pa from nucleo.parcelas where id = new.parcela_id for update;
  select * into t from nucleo.titulos where id = pa.titulo_id for update;
  if t.situacao <> 'aberto' then raise exception 'O título não está aberto'; end if;
  if t.sentido <> 'pagar' then raise exception 'Recebimentos ficam para o módulo de contas a receber'; end if;
  if g.empresa_id <> t.empresa_id then raise exception 'Pagamento e título são de empresas diferentes'; end if;
  if g.pessoa_id <> t.pessoa_id then raise exception 'O pagamento foi para outra pessoa'; end if;
  -- roda depois da gravação: a própria quitação já entra nos saldos
  if nucleo.parcela_saldo(pa.id) < 0 then
    raise exception 'A quitação (%) passa do saldo da parcela (%)', new.principal, nucleo.parcela_saldo(pa.id) + new.principal;
  end if;
  v_total := new.principal + new.juros + new.multa - new.desconto;
  if nucleo.pagamento_saldo(g.id) < 0 then
    raise exception 'A quitação (%) passa do saldo do pagamento (%)', v_total, nucleo.pagamento_saldo(g.id) + v_total;
  end if;
  v_comp := nucleo.mes(g.data);

  -- sai de Adiantamentos
  insert into nucleo.lancamentos (estagio, empresa_id, natureza_id, competencia, data_caixa, valor, pagamento_id, quitacao_id, titulo_id, parcela_id)
  values ('realizado', t.empresa_id, nucleo.natureza_sistema('adiantamentos'), v_comp, g.data, v_total, g.id, new.id, t.id, pa.id);
  -- principal: realizado na natureza do título e estorno do comprometido
  for r in select * from nucleo.ratear('titulo', t.id, new.principal) loop
    insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, r.centro_id, r.natureza_id, r.fase_id, r.departamento_id,
            t.competencia, g.data, -r.valor, t.id, pa.id, new.id, g.id),
           ('comprometido', t.empresa_id, r.centro_id, r.natureza_id, r.fase_id, r.departamento_id,
            t.competencia, pa.vencimento, r.valor, t.id, pa.id, new.id, g.id);
  end loop;
  -- juros, multa e desconto: no centro de maior peso do rateio, competência do pagamento
  select centro_id, fase_id, departamento_id into v_centro, v_fase, v_dep
  from nucleo.titulo_rateios where titulo_id = t.id order by percentual desc, id limit 1;
  if new.juros + new.multa > 0 then
    insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_centro, nucleo.natureza_sistema('juros_multas'), v_fase, v_dep,
            v_comp, g.data, -(new.juros + new.multa), t.id, pa.id, new.id, g.id);
  end if;
  if new.desconto > 0 then
    insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_centro, nucleo.natureza_sistema('descontos_obtidos'), v_fase, v_dep,
            v_comp, g.data, new.desconto, t.id, pa.id, new.id, g.id);
  end if;
  -- título sem saldo vira quitado
  if not exists (select 1 from nucleo.parcelas p where p.titulo_id = t.id and nucleo.parcela_saldo(p.id) > 0) then
    perform set_config('nucleo.sistema', 'on', true);
    update nucleo.titulos set situacao = 'quitado' where id = t.id;
    perform set_config('nucleo.sistema', 'off', true);
  end if;
  return new;
end $$;
create trigger t_quitacao after insert on nucleo.quitacoes
  for each row execute function nucleo.tg_quitacao();
create trigger t_imutavel before update or delete on nucleo.quitacoes
  for each row execute function nucleo.tg_imutavel();

-- Atalho do dia a dia: um pagamento que quita uma parcela inteira.
create function nucleo.pagar_parcela(p_parcela uuid, p_conta uuid, p_data date,
  p_juros numeric default 0, p_multa numeric default 0, p_desconto numeric default 0, p_lote uuid default null)
returns uuid language plpgsql as $$
declare t nucleo.titulos; v_saldo numeric; v_pag uuid;
begin
  perform nucleo.exigir_editor();
  select t2.* into t from nucleo.titulos t2 join nucleo.parcelas p on p.titulo_id = t2.id where p.id = p_parcela;
  v_saldo := nucleo.parcela_saldo(p_parcela);
  insert into nucleo.pagamentos (empresa_id, conta_id, pessoa_id, lote_id, data, valor)
  values (t.empresa_id, p_conta, t.pessoa_id, p_lote, p_data, v_saldo + p_juros + p_multa - p_desconto)
  returning id into v_pag;
  insert into nucleo.quitacoes (pagamento_id, parcela_id, principal, juros, multa, desconto)
  values (v_pag, p_parcela, v_saldo, p_juros, p_multa, p_desconto);
  return v_pag;
end $$;

-- ---------------------------------------------------------------------
-- Caução: extrato, liberação e uso para pagar terceiro
-- ---------------------------------------------------------------------
create function nucleo.caucao_saldo(p_compromisso uuid) returns numeric language sql stable as $$
  select coalesce(sum(case tipo when 'retencao' then valor else -valor end), 0)
  from nucleo.caucao_movimentos where compromisso_id = p_compromisso $$;

-- Retida, a caução é dívida sem data (comprometido sem data de caixa); liberada ou usada,
-- sai do sem data e o título gerado passa a carregá-la com vencimento.
create function nucleo.tg_caucao() returns trigger language plpgsql as $$
declare c nucleo.compromissos; r record; v_sinal int;
begin
  if tg_op <> 'INSERT' then raise exception 'O extrato da caução não se altera'; end if;
  select * into c from nucleo.compromissos where id = new.compromisso_id;
  if nucleo.caucao_saldo(c.id) < 0 then   -- depois da gravação: o próprio movimento já conta
    raise exception 'A caução do contrato tem só % de saldo', nucleo.caucao_saldo(c.id) + new.valor;
  end if;
  if not nucleo.rateio_completo('compromisso', c.id) then
    raise exception 'O contrato com caução precisa de rateio que some 100%%';
  end if;
  v_sinal := case new.tipo when 'retencao' then -1 else 1 end;
  for r in select * from nucleo.ratear('compromisso', c.id, new.valor) loop
    insert into nucleo.lancamentos (estagio, empresa_id, centro_id, natureza_id, fase_id, departamento_id,
                                    competencia, data_caixa, valor, caucao_movimento_id)
    values ('comprometido', c.empresa_id, r.centro_id, r.natureza_id, r.fase_id, r.departamento_id,
            nucleo.mes(new.em::date), null, v_sinal * r.valor, new.id);
  end loop;
  return new;
end $$;
create trigger t_caucao after insert on nucleo.caucao_movimentos
  for each row execute function nucleo.tg_caucao();

-- Libera (para o próprio fornecedor) ou usa (para um terceiro, com motivo) parte da caução.
-- A aprovação do gestor do contrato entra no módulo de aprovação.
create function nucleo.liberar_caucao(p_compromisso uuid, p_valor numeric, p_vencimento date,
  p_terceiro uuid default null, p_motivo text default null) returns uuid language plpgsql as $$
declare c nucleo.compromissos; v_tit uuid;
begin
  perform nucleo.exigir_editor();
  select * into c from nucleo.compromissos where id = p_compromisso for update;
  if p_valor > nucleo.caucao_saldo(c.id) then
    raise exception 'A caução do contrato tem só % de saldo', nucleo.caucao_saldo(c.id);
  end if;
  v_tit := nucleo._criar_titulo(c.empresa_id, 'pagar', 'caucao', coalesce(p_terceiro, c.pessoa_id), null, c.id,
                                current_date, nucleo.mes(current_date), p_valor, array[p_vencimento], 'compromisso', c.id,
                                case when p_terceiro is null then 'Liberação de caução' else 'Caução usada: ' || p_motivo end);
  insert into nucleo.caucao_movimentos (compromisso_id, tipo, valor, titulo_id, motivo)
  values (c.id, case when p_terceiro is null then 'liberacao' else 'uso_terceiro' end, p_valor, v_tit, p_motivo);
  perform nucleo.confirmar_titulo(v_tit);
  return v_tit;
end $$;

-- ---------------------------------------------------------------------
-- Movimento entre sócios: título a pagar numa empresa e a receber na outra, ligados
-- ---------------------------------------------------------------------
create function nucleo.registrar_movimento_societario(p_tipo text, p_pagadora uuid, p_recebedora uuid,
  p_valor numeric, p_data date, p_descricao text default null) returns uuid language plpgsql as $$
declare v_pag uuid; v_rec uuid; v_id uuid; v_nat uuid := nucleo.natureza_sistema('entre_socios');
begin
  perform nucleo.exigir_editor();
  v_pag := nucleo._criar_titulo(p_pagadora, 'pagar', 'societario', (select pessoa_id from nucleo.empresas where id = p_recebedora),
                                null, null, p_data, nucleo.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  v_rec := nucleo._criar_titulo(p_recebedora, 'receber', 'societario', (select pessoa_id from nucleo.empresas where id = p_pagadora),
                                null, null, p_data, nucleo.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  insert into nucleo.titulo_rateios (titulo_id, natureza_id, percentual) values (v_pag, v_nat, 100), (v_rec, v_nat, 100);
  perform nucleo.confirmar_titulo(v_pag);
  perform nucleo.confirmar_titulo(v_rec);
  insert into nucleo.movimentos_societarios (tipo, pagadora_id, recebedora_id, data, valor, titulo_pagar_id, titulo_receber_id, descricao)
  values (p_tipo, p_pagadora, p_recebedora, p_data, p_valor, v_pag, v_rec, p_descricao) returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Visões
-- ---------------------------------------------------------------------
create view nucleo.v_parcelas with (security_invoker = true) as
select p.id, p.titulo_id, t.empresa_id, t.pessoa_id, t.sentido, t.tipo, p.numero, p.vencimento, p.valor,
       p.valor - coalesce(q.pago, 0) as saldo,
       case when t.situacao = 'cancelado' then 'cancelada'
            when p.valor - coalesce(q.pago, 0) = 0 then 'quitada'
            when p.vencimento < current_date then 'vencida' else 'aberta' end as situacao
from nucleo.parcelas p join nucleo.titulos t on t.id = p.titulo_id
left join (select parcela_id, sum(principal) as pago from nucleo.quitacoes group by 1) q on q.parcela_id = p.id
where t.situacao <> 'rascunho';

create view nucleo.v_adiantamentos with (security_invoker = true) as
select g.id as pagamento_id, g.empresa_id, g.pessoa_id, g.compromisso_id, g.data, g.valor,
       nucleo.pagamento_saldo(g.id) as saldo
from nucleo.pagamentos g where nucleo.pagamento_saldo(g.id) > 0;

create view nucleo.v_caucao with (security_invoker = true) as
select compromisso_id,
       sum(valor) filter (where tipo = 'retencao') as retido,
       coalesce(sum(valor) filter (where tipo = 'liberacao'), 0) as liberado,
       coalesce(sum(valor) filter (where tipo = 'uso_terceiro'), 0) as usado_com_terceiros,
       nucleo.caucao_saldo(compromisso_id) as saldo
from nucleo.caucao_movimentos group by compromisso_id;

-- Previsto × realizado de cada previsão.
create view nucleo.v_previsoes with (security_invoker = true) as
select p.*, coalesce(c.consumido, 0) as consumido, p.valor - coalesce(c.consumido, 0) as saldo
from nucleo.previsoes p
left join (select previsao_id, sum(valor) as consumido from nucleo.titulo_previsoes group by 1) c on c.previsao_id = p.id;

-- Fluxo de caixa: previsto em aberto + comprometido em aberto + realizado, por dia de caixa.
-- Não é tabela: é a soma do livro.
create view nucleo.v_fluxo_caixa with (security_invoker = true) as
select l.empresa_id, l.data_caixa,
       coalesce(sum(l.valor) filter (where l.estagio = 'previsto'), 0)     as previsto,
       coalesce(sum(l.valor) filter (where l.estagio = 'comprometido'), 0) as comprometido,
       coalesce(sum(l.valor) filter (where l.estagio = 'realizado'), 0)    as realizado,
       sum(l.valor) as projetado
from nucleo.lancamentos l
where l.estagio <> 'orcado' and l.data_caixa is not null
group by l.empresa_id, l.data_caixa;

-- Livro com tudo junto para BI e agentes: nomes, árvore, características da natureza
-- e os atributos do empreendimento vigentes na competência de cada linha.
create view nucleo.v_lancamentos_bi with (security_invoker = true) as
select l.id, l.estagio, ov.tipo as orcamento_tipo, ov.nome as orcamento_versao,
       l.competencia, l.data_caixa, l.valor,
       pe.nome as empresa, e.tipo as empresa_tipo,
       cc.nome as centro_custo, cc.tipo as centro_tipo,
       em.codigo as empreendimento_codigo, em.nome as empreendimento, em.municipio, em.uf,
       vn.caminho as natureza, vn.nivel1, vn.nivel2, vn.nivel3, vn.nivel4,
       vn.tipo as natureza_tipo, ld.nome as linha_dre, vn.linha_dfc,
       f.nome as fase, dp.nome as departamento,
       (select jsonb_object_agg(a.codigo, ea.valor)
          from nucleo.empreendimento_atributos ea join nucleo.atributos a on a.id = ea.atributo_id
         where ea.empreendimento_id = em.id
           and l.competencia between ea.inicio and coalesce(ea.fim, 'infinity')) as atributos,
       l.empresa_id, l.centro_id, l.natureza_id, em.id as empreendimento_id,
       l.titulo_id, l.previsao_id, l.quitacao_id, l.pagamento_id
from nucleo.lancamentos l
join nucleo.empresas e on e.id = l.empresa_id
join nucleo.pessoas pe on pe.id = e.pessoa_id
join nucleo.v_naturezas vn on vn.id = l.natureza_id
join nucleo.linhas_dre ld on ld.codigo = vn.linha_dre
left join nucleo.orcamento_versoes ov on ov.id = l.orcamento_versao_id
left join nucleo.centros_custo cc on cc.id = l.centro_id
left join nucleo.empreendimentos em on em.id = cc.empreendimento_id
left join nucleo.fases f on f.id = l.fase_id
left join nucleo.departamentos dp on dp.id = l.departamento_id;
