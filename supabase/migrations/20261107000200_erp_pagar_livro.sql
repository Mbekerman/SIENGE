-- ERP BKM: do compromisso ao pagamento, e o livro de lançamentos.
-- compromisso → previsão → documento fiscal → título → parcela; pagamento ↔ quitação.
-- Cada estágio escreve no livro (erp.lancamentos); o livro só recebe linhas novas
-- (estorno é linha de sinal contrário) e só muda a natureza, pela reclassificação.
-- Sinal no livro: entrada positiva, saída negativa. Nas tabelas de origem, valores positivos.

-- ---------------------------------------------------------------------
-- Classificação comum (núcleo econômico, centro de custo, natureza, fase) e o rateio
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

-- O centro de custo precisa estar ligado no núcleo econômico (erp.nucleo_centros).
create function erp.checar_centro(p_nucleo uuid, p_centro uuid)
returns void language plpgsql stable as $$
begin
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
  fase_id         uuid references erp.fases,
  centro_custo_id uuid references erp.centros_custo,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
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
  fase_id         uuid references erp.fases,
  centro_custo_id uuid references erp.centros_custo,
  competencia     date not null check (extract(day from competencia) = 1),
  data_caixa      date,
  valor           numeric(15,2) not null check (valor <> 0)   -- com sinal: receita +, gasto −
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
  fase_id         uuid references erp.fases,
  centro_custo_id uuid references erp.centros_custo,
  competencia     date not null check (extract(day from competencia) = 1),
  data_prevista   date not null,
  valor           numeric(15,2) not null check (valor > 0),
  descricao       text,
  situacao        text not null default 'aberta' check (situacao in ('aberta','consumida','cancelada')),
  criada_em       timestamptz not null default now()
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
  lancado_em     timestamptz,
  criado_em      timestamptz not null default now()
);
-- Trava de duplicidade que o Sienge não tem (lá a NFS-e aceita número repetido).
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
  fase_id         uuid references erp.fases,
  centro_custo_id uuid references erp.centros_custo,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
);

-- ---------------------------------------------------------------------
-- Título: a dívida real (ou o direito a receber), com N parcelas
-- ---------------------------------------------------------------------
create table erp.titulos (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references erp.empresas,
  sentido        text not null default 'pagar' check (sentido in ('pagar','receber')),
  tipo           text not null check (tipo in ('fornecedor','imposto','caucao','societario','avulso')),
  pessoa_id      uuid not null references erp.pessoas,
  documento_id   uuid references erp.documentos_fiscais,
  compromisso_id uuid references erp.compromissos,
  numero         text,
  emissao        date not null,
  competencia    date not null check (extract(day from competencia) = 1),
  valor          numeric(15,2) not null check (valor > 0),
  descricao      text,
  situacao       text not null default 'rascunho' check (situacao in ('rascunho','aberto','quitado','cancelado')),
  criado_em      timestamptz not null default now()
);

create table erp.titulo_rateios (
  id              uuid primary key default gen_random_uuid(),
  titulo_id       uuid not null references erp.titulos on delete cascade,
  nucleo_economico_id       uuid references erp.nucleos_economicos,
  natureza_id     uuid not null references erp.naturezas,
  fase_id         uuid references erp.fases,
  centro_custo_id uuid references erp.centros_custo,
  percentual      numeric(7,4) not null check (percentual > 0 and percentual <= 100)
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
  lote_id        uuid references erp.lotes_bancarios,
  data           date not null,
  valor          numeric(15,2) not null check (valor > 0),
  forma          text not null default 'pix' check (forma in ('pix','ted','boleto','debito','cheque','dinheiro','outro')),
  descricao      text,
  criado_em      timestamptz not null default now()
);

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
  tipo           text not null check (tipo in ('retencao','liberacao','uso_terceiro')),
  valor          numeric(15,2) not null check (valor > 0),
  documento_id   uuid references erp.documentos_fiscais,   -- na retenção
  titulo_id      uuid references erp.titulos,              -- na liberação e no uso
  motivo         text,
  em             timestamptz not null default now(),
  por            uuid default erp.eu(),
  check ((tipo = 'retencao') = (documento_id is not null)),
  check (tipo = 'retencao' or titulo_id is not null),
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
  fase_id             uuid references erp.fases,
  centro_custo_id     uuid references erp.centros_custo,
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
  check ((estagio = 'orcado') = (orcamento_versao_id is not null))
);
create index on erp.lancamentos (natureza_id);
create index on erp.lancamentos (empresa_id, competencia);
create index on erp.lancamentos (titulo_id);
create index on erp.lancamentos (previsao_id);

create function erp.tg_lancamento() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'O livro não apaga linhas; estorne com uma linha de sinal contrário'; end if;
  if tg_op = 'UPDATE' then
    if current_setting('erp.reclassificando', true) is distinct from 'on' then
      raise exception 'O livro não muda; a natureza só muda pela reclassificação';
    end if;
    if (to_jsonb(new) - 'natureza_id') <> (to_jsonb(old) - 'natureza_id') then
      raise exception 'A reclassificação só muda a natureza';
    end if;
  end if;
  if tg_op = 'INSERT' then
    perform erp.checar_natureza(new.natureza_id, new.nucleo_economico_id, new.centro_custo_id, new.estagio = 'orcado');
    perform erp.checar_centro(new.nucleo_economico_id, new.centro_custo_id);
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

-- Natureza válida em toda tabela de classificação.
create function erp.tg_classificacao() returns trigger language plpgsql as $$
begin
  perform erp.checar_natureza(new.natureza_id, new.nucleo_economico_id, new.centro_custo_id, tg_table_name = 'orcamento_linhas');
  perform erp.checar_centro(new.nucleo_economico_id, new.centro_custo_id);
  return new;
end $$;
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id on erp.compromisso_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id on erp.documento_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id on erp.titulo_rateios
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id on erp.previsoes
  for each row execute function erp.tg_classificacao();
create trigger t_class before insert or update of natureza_id, nucleo_economico_id, centro_custo_id on erp.orcamento_linhas
  for each row execute function erp.tg_classificacao();

-- Rateio de um registro (compromisso, documento ou título) dividindo um total em centavos exatos:
-- cada parte = arredondamento do acumulado menos o do acumulado anterior, então a soma fecha.
create function erp.ratear(p_origem text, p_id uuid, p_total numeric)
returns table (nucleo_economico_id uuid, natureza_id uuid, fase_id uuid, centro_custo_id uuid, valor numeric)
language sql stable as $$
  with r as (
    select nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual, id from erp.compromisso_rateios
      where p_origem = 'compromisso' and compromisso_id = p_id
    union all
    select nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual, id from erp.documento_rateios
      where p_origem = 'documento' and documento_id = p_id
    union all
    select nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual, id from erp.titulo_rateios
      where p_origem = 'titulo' and titulo_id = p_id
  ), a as (
    select r.*, sum(percentual) over (order by percentual desc, id) as acum,
           sum(percentual) over () as total_pct
    from r
  )
  select nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
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

-- Publicar a versão grava as linhas no livro e substitui a vigente do mesmo tipo.
create function erp.publicar_orcamento(p_versao uuid) returns void language plpgsql as $$
declare v erp.orcamento_versoes;
begin
  perform erp.exigir_editor();
  select * into v from erp.orcamento_versoes where id = p_versao for update;
  if v.situacao <> 'rascunho' then raise exception 'Só se publica versão em rascunho'; end if;
  update erp.orcamento_versoes set situacao = 'substituida'
   where empresa_id = v.empresa_id and empreendimento_id is not distinct from v.empreendimento_id
     and tipo = v.tipo and situacao = 'vigente' and tipo <> 'reprojecao';
  insert into erp.lancamentos (estagio, orcamento_versao_id, empresa_id, nucleo_economico_id, natureza_id, fase_id,
                                  centro_custo_id, competencia, data_caixa, valor, orcamento_linha_id)
  select 'orcado', v.id, v.empresa_id, l.nucleo_economico_id, l.natureza_id, l.fase_id, l.centro_custo_id,
         l.competencia, l.data_caixa, l.valor, l.id
  from erp.orcamento_linhas l where l.versao_id = v.id;
  update erp.orcamento_versoes set situacao = 'vigente' where id = v.id;
end $$;

-- ---------------------------------------------------------------------
-- Previsão → livro (estágio previsto)
-- ---------------------------------------------------------------------
create function erp.previsao_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(valor) from erp.titulo_previsoes where previsao_id = p.id), 0)
  from erp.previsoes p where p.id = p_id $$;

create function erp.tg_previsao() returns trigger language plpgsql as $$
declare v_saldo numeric;
begin
  if tg_op = 'INSERT' then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                    competencia, data_caixa, valor, previsao_id)
    values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.fase_id, new.centro_custo_id,
            new.competencia, new.data_prevista, erp.sinal(new.sentido) * new.valor, new.id);
    return new;
  end if;
  if (to_jsonb(new) - 'situacao' - 'natureza_id') <> (to_jsonb(old) - 'situacao' - 'natureza_id') then
    raise exception 'Previsão não se edita; cancele e crie outra';
  end if;
  if new.natureza_id <> old.natureza_id and current_setting('erp.reclassificando', true) is distinct from 'on' then
    raise exception 'A natureza da previsão só muda pela reclassificação';
  end if;
  if new.situacao = 'cancelada' and old.situacao = 'aberta' then
    v_saldo := erp.previsao_saldo(new.id);
    if v_saldo > 0 then
      insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                      competencia, data_caixa, valor, previsao_id)
      values ('previsto', new.empresa_id, new.nucleo_economico_id, new.natureza_id, new.fase_id, new.centro_custo_id,
              new.competencia, new.data_prevista, -erp.sinal(new.sentido) * v_saldo, new.id);
    end if;
  elsif new.situacao <> old.situacao and current_setting('erp.sistema', true) is distinct from 'on' then
    raise exception 'A previsão só pode ser cancelada; ela é consumida pelos títulos';
  end if;
  return new;
end $$;
create trigger t_previsao after insert or update on erp.previsoes
  for each row execute function erp.tg_previsao();

-- Consumo da previsão pelo título: estorna o previsto na data da previsão.
create function erp.tg_titulo_previsao() returns trigger language plpgsql as $$
declare p erp.previsoes; v_saldo numeric;
begin
  select * into p from erp.previsoes where id = new.previsao_id for update;
  if p.situacao <> 'aberta' then raise exception 'A previsão não está aberta'; end if;
  if p.empresa_id <> (select empresa_id from erp.titulos where id = new.titulo_id) then
    raise exception 'Previsão e título são de empresas diferentes';
  end if;
  v_saldo := p.valor - coalesce((select sum(valor) from erp.titulo_previsoes
                                 where previsao_id = p.id and titulo_id <> new.titulo_id), 0);
  if new.valor > v_saldo then raise exception 'O consumo (%) passa do saldo da previsão (%)', new.valor, v_saldo; end if;
  insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                  competencia, data_caixa, valor, previsao_id, titulo_id)
  values ('previsto', p.empresa_id, p.nucleo_economico_id, p.natureza_id, p.fase_id, p.centro_custo_id,
          p.competencia, p.data_prevista, -erp.sinal(p.sentido) * new.valor, p.id, new.titulo_id);
  if new.valor = v_saldo then
    perform set_config('erp.sistema', 'on', true);
    update erp.previsoes set situacao = 'consumida' where id = p.id;
    perform set_config('erp.sistema', 'off', true);
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
        insert into erp.previsoes (empresa_id, origem, compromisso_id, pessoa_id, nucleo_economico_id, natureza_id, fase_id,
                                      centro_custo_id, competencia, data_prevista, valor, descricao)
        values (c.empresa_id, 'assinatura', c.id, c.pessoa_id, r.nucleo_economico_id, r.natureza_id, r.fase_id, r.centro_custo_id,
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
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' then
    if (to_jsonb(new) - 'situacao') <> (to_jsonb(old) - 'situacao') then
      raise exception 'Título confirmado não se edita';
    end if;
    if current_setting('erp.sistema', true) is distinct from 'on' then
      raise exception 'A situação do título muda pelas quitações';
    end if;
  end if;
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then
    raise exception 'Título confirmado não se apaga';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_titulo before update or delete on erp.titulos
  for each row execute function erp.tg_titulo();

-- Parcelas e rateio só mudam com o título em rascunho (a natureza também pela reclassificação).
create function erp.tg_filho_titulo() returns trigger language plpgsql as $$
declare v_sit text;
begin
  select situacao into v_sit from erp.titulos where id = coalesce(new.titulo_id, old.titulo_id);
  if v_sit is null or v_sit = 'rascunho' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and tg_table_name = 'titulo_rateios'
     and current_setting('erp.reclassificando', true) = 'on'
     and (to_jsonb(new) - 'natureza_id') = (to_jsonb(old) - 'natureza_id') then
    return new;
  end if;
  raise exception 'O título já foi confirmado; % não muda', tg_table_name;
end $$;
create trigger t_filho before insert or update or delete on erp.parcelas
  for each row execute function erp.tg_filho_titulo();
create trigger t_filho before insert or update or delete on erp.titulo_rateios
  for each row execute function erp.tg_filho_titulo();

create function erp.confirmar_titulo(p_titulo uuid) returns void language plpgsql as $$
declare t erp.titulos; p record; r record;
begin
  perform erp.exigir_editor();
  select * into t from erp.titulos where id = p_titulo for update;
  if t.situacao <> 'rascunho' then raise exception 'O título já foi confirmado'; end if;
  if not erp.rateio_completo('titulo', t.id) then raise exception 'O rateio do título não soma 100%%'; end if;
  if coalesce((select sum(valor) from erp.parcelas where titulo_id = t.id), 0) <> t.valor then
    raise exception 'As parcelas não somam o valor do título';
  end if;
  for p in select * from erp.parcelas where titulo_id = t.id order by numero loop
    for r in select * from erp.ratear('titulo', t.id, p.valor) loop
      insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                      competencia, data_caixa, valor, titulo_id, parcela_id)
      values ('comprometido', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.fase_id, r.centro_custo_id,
              t.competencia, p.vencimento, erp.sinal(t.sentido) * r.valor, t.id, p.id);
    end loop;
  end loop;
  perform set_config('erp.sistema', 'on', true);
  update erp.titulos set situacao = 'aberto' where id = t.id;
  perform set_config('erp.sistema', 'off', true);
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
    insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual)
    select v_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual from (
      select nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual from erp.compromisso_rateios
        where p_rateio_origem = 'compromisso' and compromisso_id = p_rateio_id
      union all
      select nucleo_economico_id, natureza_id, fase_id, centro_custo_id, percentual from erp.documento_rateios
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
  select * into d from erp.documentos_fiscais where id = p_documento for update;
  if d.situacao <> 'rascunho' then raise exception 'O documento já foi lançado'; end if;
  if coalesce(array_length(p_vencimentos, 1), 0) = 0 then raise exception 'Informe ao menos um vencimento'; end if;
  if not erp.rateio_completo('documento', d.id) then raise exception 'O rateio do documento não soma 100%%'; end if;
  if d.caucao_valor is null then
    d.caucao_valor := round(d.valor_bruto * coalesce((select caucao_percentual from erp.compromissos where id = d.compromisso_id), 0) / 100, 2);
  end if;
  if d.caucao_valor > 0 and d.compromisso_id is null then raise exception 'Caução só existe com contrato'; end if;
  select coalesce(sum(valor), 0) into v_ret from erp.documento_retencoes where documento_id = d.id;
  v_liquido := d.valor_bruto - v_ret - d.caucao_valor;
  if v_liquido <= 0 then raise exception 'Retenções e caução passam do valor da nota'; end if;

  v_tit := erp._criar_titulo(d.empresa_id, 'pagar', 'fornecedor', d.emitente_id, d.id, d.compromisso_id,
                                d.emissao, d.competencia, v_liquido, p_vencimentos, 'documento', d.id, null);
  perform erp.confirmar_titulo(v_tit);

  for r in select * from erp.documento_retencoes where documento_id = d.id loop
    v_imp := erp._criar_titulo(d.empresa_id, 'pagar', 'imposto', r.orgao_id, d.id, d.compromisso_id,
                                  d.emissao, d.competencia, r.valor, array[r.vencimento], 'documento', d.id,
                                  upper(r.imposto) || ' retido na nota ' || d.numero);
    perform erp.confirmar_titulo(v_imp);
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
    v_cons := least(v_resta, erp.previsao_saldo(p.id), v_lim);
    continue when v_cons <= 0;
    insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (v_tit, p.id, v_cons);
    v_resta := v_resta - v_cons;
  end loop;

  update erp.documentos_fiscais set situacao = 'lancado', lancado_em = now(), caucao_valor = d.caucao_valor where id = d.id;
  return v_tit;
end $$;

create function erp.tg_documento() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' and old.situacao <> 'rascunho' then raise exception 'Documento lançado não se apaga'; end if;
  if tg_op = 'UPDATE' and old.situacao <> 'rascunho' and (to_jsonb(new) - 'situacao') <> (to_jsonb(old) - 'situacao') then
    raise exception 'Documento lançado não se edita';
  end if;
  return coalesce(new, old);
end $$;
create trigger t_documento before update or delete on erp.documentos_fiscais
  for each row execute function erp.tg_documento();

-- ---------------------------------------------------------------------
-- Pagamento e quitação → livro (estágio realizado)
-- O pagamento entra inteiro em "Adiantamentos" (movimentação, sem centro);
-- cada quitação tira dali e lança na natureza do título. Pagamento sem quitação
-- é adiantamento, abatido depois por novas quitações, em vários títulos.
-- ---------------------------------------------------------------------
create function erp.tg_pagamento() returns trigger language plpgsql as $$
begin
  if tg_op <> 'INSERT' then raise exception 'Pagamento não se altera; o estorno virá no módulo de bancos'; end if;
  if (select empresa_id from erp.contas_bancarias where id = new.conta_id) <> new.empresa_id then
    raise exception 'A conta não é da empresa do pagamento';
  end if;
  insert into erp.lancamentos (estagio, empresa_id, natureza_id, competencia, data_caixa, valor, pagamento_id)
  values ('realizado', new.empresa_id, erp.natureza_sistema('adiantamentos'), erp.mes(new.data), new.data, -new.valor, new.id);
  return new;
end $$;
create trigger t_pagamento after insert or update or delete on erp.pagamentos
  for each row execute function erp.tg_pagamento();

create function erp.parcela_saldo(p_id uuid) returns numeric language sql stable as $$
  select p.valor - coalesce((select sum(principal) from erp.quitacoes where parcela_id = p.id), 0)
  from erp.parcelas p where p.id = p_id $$;

create function erp.pagamento_saldo(p_id uuid) returns numeric language sql stable as $$
  select g.valor - coalesce((select sum(principal + juros + multa - desconto) from erp.quitacoes where pagamento_id = g.id), 0)
  from erp.pagamentos g where g.id = p_id $$;

create function erp.tg_quitacao() returns trigger language plpgsql as $$
declare g erp.pagamentos; pa erp.parcelas; t erp.titulos; r record; v_total numeric;
        v_nucleo uuid; v_fase uuid; v_dep uuid; v_comp date;
begin
  select * into g from erp.pagamentos where id = new.pagamento_id for update;
  select * into pa from erp.parcelas where id = new.parcela_id for update;
  select * into t from erp.titulos where id = pa.titulo_id for update;
  if t.situacao <> 'aberto' then raise exception 'O título não está aberto'; end if;
  if t.sentido <> 'pagar' then raise exception 'Recebimentos ficam para o módulo de contas a receber'; end if;
  if g.empresa_id <> t.empresa_id then raise exception 'Pagamento e título são de empresas diferentes'; end if;
  if g.pessoa_id <> t.pessoa_id then raise exception 'O pagamento foi para outra pessoa'; end if;
  -- roda depois da gravação: a própria quitação já entra nos saldos
  if erp.parcela_saldo(pa.id) < 0 then
    raise exception 'A quitação (%) passa do saldo da parcela (%)', new.principal, erp.parcela_saldo(pa.id) + new.principal;
  end if;
  v_total := new.principal + new.juros + new.multa - new.desconto;
  if erp.pagamento_saldo(g.id) < 0 then
    raise exception 'A quitação (%) passa do saldo do pagamento (%)', v_total, erp.pagamento_saldo(g.id) + v_total;
  end if;
  v_comp := erp.mes(g.data);

  -- sai de Adiantamentos
  insert into erp.lancamentos (estagio, empresa_id, natureza_id, competencia, data_caixa, valor, pagamento_id, quitacao_id, titulo_id, parcela_id)
  values ('realizado', t.empresa_id, erp.natureza_sistema('adiantamentos'), v_comp, g.data, v_total, g.id, new.id, t.id, pa.id);
  -- principal: realizado na natureza do título e estorno do comprometido
  for r in select * from erp.ratear('titulo', t.id, new.principal) loop
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.fase_id, r.centro_custo_id,
            t.competencia, g.data, -r.valor, t.id, pa.id, new.id, g.id),
           ('comprometido', t.empresa_id, r.nucleo_economico_id, r.natureza_id, r.fase_id, r.centro_custo_id,
            t.competencia, pa.vencimento, r.valor, t.id, pa.id, new.id, g.id);
  end loop;
  -- juros, multa e desconto: no centro de maior peso do rateio, competência do pagamento
  select nucleo_economico_id, fase_id, centro_custo_id into v_nucleo, v_fase, v_dep
  from erp.titulo_rateios where titulo_id = t.id order by percentual desc, id limit 1;
  if new.juros + new.multa > 0 then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_nucleo, erp.natureza_sistema('juros_multas'), v_fase, v_dep,
            v_comp, g.data, -(new.juros + new.multa), t.id, pa.id, new.id, g.id);
  end if;
  if new.desconto > 0 then
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                    competencia, data_caixa, valor, titulo_id, parcela_id, quitacao_id, pagamento_id)
    values ('realizado', t.empresa_id, v_nucleo, erp.natureza_sistema('descontos_obtidos'), v_fase, v_dep,
            v_comp, g.data, new.desconto, t.id, pa.id, new.id, g.id);
  end if;
  -- título sem saldo vira quitado
  if not exists (select 1 from erp.parcelas p where p.titulo_id = t.id and erp.parcela_saldo(p.id) > 0) then
    perform set_config('erp.sistema', 'on', true);
    update erp.titulos set situacao = 'quitado' where id = t.id;
    perform set_config('erp.sistema', 'off', true);
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
declare t erp.titulos; v_saldo numeric; v_pag uuid;
begin
  perform erp.exigir_editor();
  select t2.* into t from erp.titulos t2 join erp.parcelas p on p.titulo_id = t2.id where p.id = p_parcela;
  v_saldo := erp.parcela_saldo(p_parcela);
  insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, lote_id, data, valor)
  values (t.empresa_id, p_conta, t.pessoa_id, p_lote, p_data, v_saldo + p_juros + p_multa - p_desconto)
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
    insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, natureza_id, fase_id, centro_custo_id,
                                    competencia, data_caixa, valor, caucao_movimento_id)
    values ('comprometido', c.empresa_id, r.nucleo_economico_id, r.natureza_id, r.fase_id, r.centro_custo_id,
            erp.mes(new.em::date), null, v_sinal * r.valor, new.id);
  end loop;
  return new;
end $$;
create trigger t_caucao after insert on erp.caucao_movimentos
  for each row execute function erp.tg_caucao();

-- Libera (para o próprio fornecedor) ou usa (para um terceiro, com motivo) parte da caução.
-- A aprovação do gestor do contrato entra no módulo de aprovação.
create function erp.liberar_caucao(p_compromisso uuid, p_valor numeric, p_vencimento date,
  p_terceiro uuid default null, p_motivo text default null) returns uuid language plpgsql as $$
declare c erp.compromissos; v_tit uuid;
begin
  perform erp.exigir_editor();
  select * into c from erp.compromissos where id = p_compromisso for update;
  if p_valor > erp.caucao_saldo(c.id) then
    raise exception 'A caução do contrato tem só % de saldo', erp.caucao_saldo(c.id);
  end if;
  v_tit := erp._criar_titulo(c.empresa_id, 'pagar', 'caucao', coalesce(p_terceiro, c.pessoa_id), null, c.id,
                                current_date, erp.mes(current_date), p_valor, array[p_vencimento], 'compromisso', c.id,
                                case when p_terceiro is null then 'Liberação de caução' else 'Caução usada: ' || p_motivo end);
  insert into erp.caucao_movimentos (compromisso_id, tipo, valor, titulo_id, motivo)
  values (c.id, case when p_terceiro is null then 'liberacao' else 'uso_terceiro' end, p_valor, v_tit, p_motivo);
  perform erp.confirmar_titulo(v_tit);
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
  v_pag := erp._criar_titulo(p_pagadora, 'pagar', 'societario', (select pessoa_id from erp.empresas where id = p_recebedora),
                                null, null, p_data, erp.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  v_rec := erp._criar_titulo(p_recebedora, 'receber', 'societario', (select pessoa_id from erp.empresas where id = p_pagadora),
                                null, null, p_data, erp.mes(p_data), p_valor, array[p_data], null, null, p_descricao);
  insert into erp.titulo_rateios (titulo_id, natureza_id, percentual) values (v_pag, v_nat, 100), (v_rec, v_nat, 100);
  perform erp.confirmar_titulo(v_pag);
  perform erp.confirmar_titulo(v_rec);
  insert into erp.movimentos_societarios (tipo, pagadora_id, recebedora_id, data, valor, titulo_pagar_id, titulo_receber_id, descricao)
  values (p_tipo, p_pagadora, p_recebedora, p_data, p_valor, v_pag, v_rec, p_descricao) returning id into v_id;
  return v_id;
end $$;

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

create view erp.v_adiantamentos with (security_invoker = true) as
select g.id as pagamento_id, g.empresa_id, g.pessoa_id, g.compromisso_id, g.data, g.valor,
       erp.pagamento_saldo(g.id) as saldo
from erp.pagamentos g where erp.pagamento_saldo(g.id) > 0;

create view erp.v_caucao with (security_invoker = true) as
select compromisso_id,
       sum(valor) filter (where tipo = 'retencao') as retido,
       coalesce(sum(valor) filter (where tipo = 'liberacao'), 0) as liberado,
       coalesce(sum(valor) filter (where tipo = 'uso_terceiro'), 0) as usado_com_terceiros,
       erp.caucao_saldo(compromisso_id) as saldo
from erp.caucao_movimentos group by compromisso_id;

-- Previsto × realizado de cada previsão.
create view erp.v_previsoes with (security_invoker = true) as
select p.*, coalesce(c.consumido, 0) as consumido, p.valor - coalesce(c.consumido, 0) as saldo
from erp.previsoes p
left join (select previsao_id, sum(valor) as consumido from erp.titulo_previsoes group by 1) c on c.previsao_id = p.id;

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
       f.nome as fase,
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
left join erp.fases f on f.id = l.fase_id
left join erp.centros_custo cc on cc.id = l.centro_custo_id;
