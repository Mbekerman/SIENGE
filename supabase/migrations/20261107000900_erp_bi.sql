-- Camada de leitura para relatórios e painéis: o esquema `bi` (decisões do Moises, 8 e 15/11/2026).
--
-- O objetivo é um banco amigável para qualquer relatório ou painel feito no próprio sistema,
-- sem Power BI. É um esquema estrela: fatos (o que aconteceu, com valor ou instante) e
-- dimensões (empresa, núcleo econômico, centro de custo, divisão, natureza, pessoa, calendário).
--
-- Regras:
-- 1. Só leitura. Nada aqui grava; cada visão lê as tabelas do `erp` com o RLS de quem consulta
--    (security_invoker) e com security_barrier. Os totais somam só o que a pessoa vê, e quem não
--    tem cadastro no ERP lê zero linhas (S-023, S-045).
-- 2. Acesso: o mesmo do ERP (perfis, atribuições, exceções, divisões). Nenhuma tabela nova de
--    liberação.
-- 3. Natureza restrita (folha PJ, pró-labore...): segue a regra atual; só quem tem a natureza
--    liberada vê (decisão do Moises, 15/11/2026). Mesmo para essa pessoa, no livro ela aparece
--    somada por empresa, núcleo, centro, natureza e mês, sem título, pessoa, dia nem divisão;
--    fora do livro, o título que tem linha restrita não aparece (parcelas, pagamentos, etapas).
-- 4. Toda data é uma data do calendário único `bi.d_calendario`. Instante (timestamptz) vem
--    acompanhado da data no horário de São Paulo (`bi.data_sp`).
-- 5. Valor com sinal (saída negativa, entrada positiva, como o livro) e `valor_dre`, que inverte
--    o sinal das linhas de custo e despesa (`linhas_dre.subtrai`) para a DRE ler positivo. Não é
--    valor absoluto: um estorno continua com o sinal contrário.
-- 6. Atributo do empreendimento (regional, faixa MCMV...): o atual em `d_nucleo` e a foto de cada
--    mês em `d_nucleo_atributos`.
-- 7. Eventos do título: os instantes já gravados pelo servidor nas tabelas do ERP (quem e quando);
--    `f_titulo_eventos` só os junta numa linha por evento. Passo novo do processo grava o próprio
--    instante e a pessoa pelo servidor, e entra aqui. ("Etapa" não se usa: saiu do sistema.)
-- Portabilidade: SQL puro, sem extensão.

create schema bi;
revoke all on schema bi from public;
grant usage on schema bi to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Funções de data
-- ---------------------------------------------------------------------------------------------
-- A data no horário de São Paulo de um instante.
create function bi.data_sp(p_em timestamptz) returns date language sql immutable
set search_path = pg_catalog as
  $$ select (p_em at time zone 'America/Sao_Paulo')::date $$;
-- Hoje em São Paulo (o current_date depende do fuso da sessão).
create function bi.hoje() returns date language sql stable
set search_path = pg_catalog as
  $$ select (now() at time zone 'America/Sao_Paulo')::date $$;
-- Domingo de Páscoa (algoritmo de Meeus, calendário gregoriano).
create function bi.pascoa(p_ano int) returns date language plpgsql immutable
set search_path = pg_catalog as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int;
begin
  a := p_ano % 19; b := p_ano / 100; c := p_ano % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3; h := (19 * a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  return make_date(p_ano, (h + l - 7 * m + 114) / 31, ((h + l - 7 * m + 114) % 31) + 1);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Calendário único (de 2015 até 15 anos à frente do ano de hoje)
-- ---------------------------------------------------------------------------------------------
-- Feriados nacionais do calendário bancário (o da ANBIMA): os da lei, mais Carnaval (segunda e
-- terça) e Corpus Christi, em que o banco não abre. Consciência Negra a partir de 2024 (Lei
-- 14.759/2023). Feriado estadual e municipal fica para quando o sistema pedir.
create table bi.d_calendario (
  data            date primary key,
  ano             int not null,
  semestre        int not null,
  trimestre       int not null,
  trimestre_nome  text not null,          -- 2026-T4
  mes             int not null,
  mes_nome        text not null,          -- novembro
  mes_abrev       text not null,          -- nov
  ano_mes         text not null,          -- 2026-11
  mes_inicio      date not null,          -- a competência do mês
  mes_fim         date not null,
  ano_iso         int not null,
  semana_iso      int not null,
  semana_inicio   date not null,          -- segunda-feira da semana
  dia             int not null,
  dia_ano         int not null,
  dia_semana      int not null,           -- 1 = segunda ... 7 = domingo (ISO)
  dia_semana_nome text not null,
  fim_de_semana   boolean not null,
  feriado         text,                   -- nome do feriado nacional, ou nulo
  util            boolean not null,       -- dia útil bancário: nem fim de semana nem feriado
  uteis_ate       int not null            -- dias úteis desde o início do calendário até este dia, inclusive
);

-- Cria os dias que faltam, de 2015 até 31/12 do ano de hoje + p_anos (padrão: sempre 15 anos à
-- frente; decisão do Moises, 15/11/2026), e refaz a contagem de dias úteis. Não muda dia que já
-- existe. Devolve quantos dias criou. Roda na migration e pela rotina mensal (abaixo); só o
-- sistema grava (RLS do calendário).
create function bi.estender_calendario(p_anos int default 15) returns int language plpgsql
set search_path = pg_catalog as $$
declare v_ate date := make_date(extract(year from bi.hoje())::int + p_anos, 12, 31); n int;
begin
  if p_anos < 1 then raise exception 'O calendário vai pelo menos um ano à frente'; end if;
  insert into bi.d_calendario
  with dias as (
    select d::date as data from generate_series('2015-01-01'::date, v_ate, interval '1 day') d
    where not exists (select 1 from bi.d_calendario c where c.data = d::date)
  ), fer as (
    select x.data, x.nome from generate_series(2015, extract(year from v_ate)::int) y
    cross join lateral (values
      (make_date(y, 1, 1), 'Confraternização Universal'),
      (bi.pascoa(y) - 48, 'Carnaval'),
      (bi.pascoa(y) - 47, 'Carnaval'),
      (bi.pascoa(y) - 2, 'Sexta-feira Santa'),
      (make_date(y, 4, 21), 'Tiradentes'),
      (make_date(y, 5, 1), 'Dia do Trabalho'),
      (bi.pascoa(y) + 60, 'Corpus Christi'),
      (make_date(y, 9, 7), 'Independência do Brasil'),
      (make_date(y, 10, 12), 'Nossa Senhora Aparecida'),
      (make_date(y, 11, 2), 'Finados'),
      (make_date(y, 11, 15), 'Proclamação da República'),
      (case when y >= 2024 then make_date(y, 11, 20) end, 'Dia Nacional de Zumbi e da Consciência Negra'),
      (make_date(y, 12, 25), 'Natal')) x(data, nome)
    where x.data is not null
  ), b as (
    select d.data, (select string_agg(f.nome, ' e ') from fer f where f.data = d.data) as feriado from dias d
  )
  select b.data,
         extract(year from b.data)::int,
         case when extract(month from b.data) <= 6 then 1 else 2 end,
         extract(quarter from b.data)::int,
         extract(year from b.data)::int || '-T' || extract(quarter from b.data)::int,
         extract(month from b.data)::int,
         (array['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'])[extract(month from b.data)::int],
         (array['jan','fev','mar','abr','mai','jun','jul','ago','set','out','nov','dez'])[extract(month from b.data)::int],
         to_char(b.data, 'YYYY-MM'),
         date_trunc('month', b.data)::date,
         (date_trunc('month', b.data) + interval '1 month - 1 day')::date,
         extract(isoyear from b.data)::int,
         extract(week from b.data)::int,
         (b.data - (extract(isodow from b.data)::int - 1)),
         extract(day from b.data)::int,
         extract(doy from b.data)::int,
         extract(isodow from b.data)::int,
         (array['segunda-feira','terça-feira','quarta-feira','quinta-feira','sexta-feira','sábado','domingo'])[extract(isodow from b.data)::int],
         extract(isodow from b.data) >= 6,
         b.feriado,
         extract(isodow from b.data) < 6 and b.feriado is null,
         0
  from b;
  get diagnostics n = row_count;
  if n > 0 then
    update bi.d_calendario c set uteis_ate = x.u
      from (select data, (count(*) filter (where util) over (order by data))::int as u from bi.d_calendario) x
     where x.data = c.data and c.uteis_ate <> x.u;
  end if;
  return n;
end $$;
select bi.estender_calendario();

-- Dias úteis entre duas datas: os do intervalo (de, até], como o prazo bancário conta.
create function bi.dias_uteis(p_de date, p_ate date) returns int language sql stable
set search_path = pg_catalog as
  $$ select (select uteis_ate from bi.d_calendario where data = p_ate) - (select uteis_ate from bi.d_calendario where data = p_de) $$;

alter table bi.d_calendario enable row level security;
alter table bi.d_calendario force row level security;
create policy sistema on bi.d_calendario using (erp.sistema()) with check (erp.sistema());
create policy perfil_le on bi.d_calendario for select to authenticated using (erp.membro());
-- Rotina: no dia 1 de cada mês, às 3h, cria o que faltar (no ano novo, o 15º ano à frente). Com o
-- pg_cron, agenda aqui; sem ele, o servidor chama bi.estender_calendario() pela rotina dele.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('bi_estender_calendario', '0 6 1 * *', 'select bi.estender_calendario()');  -- 6h UTC = 3h em SP
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Sinal da DRE: quais linhas são custo ou despesa (configuração, editada pelo administrador)
-- ---------------------------------------------------------------------------------------------
alter table erp.linhas_dre add column subtrai boolean not null default false;
update erp.linhas_dre set subtrai = true
 where codigo in ('deducoes','custo_terreno','custo_obra','despesas_comerciais','despesas_gerais','taxas','outras_despesas');
-- a linha da DRE muda o sinal dos relatórios: toda mudança fica na auditoria
create trigger t_aud_linhas_dre after insert or update or delete on erp.linhas_dre
  for each row execute function erp.tg_auditoria('codigo');
comment on column erp.linhas_dre.subtrai is
  'Linha de custo ou despesa: no bi, valor_dre = -valor (a saída lê positivo; o estorno, negativo)';

-- ---------------------------------------------------------------------------------------------
-- Dimensões
-- ---------------------------------------------------------------------------------------------
create view bi.d_empresa with (security_invoker = true, security_barrier = true) as
select e.id as empresa_id, p.nome as empresa, p.nome_fantasia, e.tipo as empresa_tipo, p.documento as cnpj, e.ativa
from erp.empresas e join erp.pessoas p on p.id = e.pessoa_id;

create view bi.d_nucleo with (security_invoker = true, security_barrier = true) as
select n.id as nucleo_economico_id, n.nome as nucleo_economico, n.tipo as nucleo_tipo, tn.nome as nucleo_tipo_nome,
       n.empresa_id, pe.nome as empresa, n.ativo,
       em.id as empreendimento_id, em.codigo as empreendimento_codigo, em.nome as empreendimento,
       em.municipio, em.uf, em.situacao as empreendimento_situacao, em.terreno_ref,
       -- atributos vigentes hoje (a foto de cada mês está em d_nucleo_atributos)
       (select jsonb_object_agg(a.codigo, ea.valor)
          from erp.empreendimento_atributos ea join erp.atributos a on a.id = ea.atributo_id
         where ea.empreendimento_id = em.id and bi.hoje() between ea.inicio and coalesce(ea.fim, 'infinity')) as atributos,
       bi.data_sp(n.criado_em) as criado_data
from erp.nucleos_economicos n
join erp.tipos_nucleo tn on tn.codigo = n.tipo
join erp.empresas e on e.id = n.empresa_id
join erp.pessoas pe on pe.id = e.pessoa_id
left join erp.empreendimentos em on em.id = n.empreendimento_id;

-- Foto mensal dos atributos do empreendimento: uma linha por núcleo, mês e atributo, com o valor
-- vigente no primeiro dia do mês. Liga ao fato pelo núcleo e pela competência.
create view bi.d_nucleo_atributos with (security_invoker = true, security_barrier = true) as
select n.id as nucleo_economico_id, c.data as mes, a.codigo as atributo, a.nome as atributo_nome, ea.valor
from erp.nucleos_economicos n
join erp.empreendimento_atributos ea on ea.empreendimento_id = n.empreendimento_id
join erp.atributos a on a.id = ea.atributo_id
join bi.d_calendario c on c.dia = 1 and c.data between ea.inicio and coalesce(ea.fim, 'infinity');

create view bi.d_centro_custo with (security_invoker = true, security_barrier = true) as
select c.id as centro_custo_id, c.nome as centro_custo, c.ativo from erp.centros_custo c;

-- Divisão em até 4 níveis abaixo do centro: cada nível com o nome achatado (nivel1 é a divisão
-- de primeiro nível, onde ficam o acesso e a alçada) e o caminho legível.
create view bi.d_divisao with (security_invoker = true, security_barrier = true) as
select d.id as divisao_id, d.nome as divisao, d.centro_custo_id, c.nome as centro_custo,
       d.mae_id, d.raiz_id, d.nivel,
       n.nomes[1] as nivel1, n.nomes[2] as nivel2, n.nomes[3] as nivel3, n.nomes[4] as nivel4,
       array_to_string(n.nomes, ' > ') as caminho,
       erp.divisao_folha(d.id) as ultimo_nivel,   -- sem subnível ativo: é onde se lança
       d.ativa, bi.data_sp(d.criado_em) as criado_data
from erp.divisoes d
join erp.centros_custo c on c.id = d.centro_custo_id
cross join lateral (
  with recursive a as (
    select x.id, x.mae_id, x.nome, x.nivel from erp.divisoes x where x.id = d.id
    union all
    select x.id, x.mae_id, x.nome, x.nivel from erp.divisoes x join a on x.id = a.mae_id)
  select array_agg(a.nome order by a.nivel) as nomes from a) n;

create view bi.d_etiqueta with (security_invoker = true, security_barrier = true) as
select e.id as etiqueta_id, e.nome as etiqueta, e.ativa from erp.etiquetas e;

create view bi.d_linha_dre with (security_invoker = true, security_barrier = true) as
select codigo as linha_dre, nome as linha_dre_nome, ordem, subtrai from erp.linhas_dre;

create view bi.d_natureza with (security_invoker = true, security_barrier = true) as
select vn.id as natureza_id, vn.codigo, vn.nome, vn.caminho, vn.nivel, vn.nivel1, vn.nivel2, vn.nivel3, vn.nivel4,
       vn.mae_id, vn.folha, vn.tipo as natureza_tipo, vn.linha_dre, ld.nome as linha_dre_nome, ld.ordem as linha_dre_ordem,
       vn.linha_dfc, vn.so_orcado, vn.redutora, erp.natureza_restrita(vn.id) as restrita, vn.ativa,
       array_to_string(vn.ordem_caminho, '.') as ordem
from erp.v_naturezas vn join erp.linhas_dre ld on ld.codigo = vn.linha_dre;

-- Fornecedor, cliente, órgão: CPF mascarado (só os dígitos do meio, ***.456.789-**; S-022);
-- CNPJ inteiro, que é público. A máscara vale para os relatórios; o cadastro erp.pessoas ainda
-- dá o documento inteiro a todo membro (fechar lá é outra decisão).
create view bi.d_pessoa with (security_invoker = true, security_barrier = true) as
select p.id as pessoa_id, p.nome, p.nome_fantasia, p.tipo as pessoa_tipo,
       case when p.tipo = 'fisica' and p.documento is not null
            then '***.' || substr(p.documento, 4, 3) || '.' || substr(p.documento, 7, 3) || '-**'
            else p.documento end as documento,
       p.ativa
from erp.pessoas p;

create view bi.d_usuario with (security_invoker = true, security_barrier = true) as
select u.id as usuario_id, u.nome, u.papel, u.ativo from erp.usuarios u;

-- ---------------------------------------------------------------------------------------------
-- Fatos
-- ---------------------------------------------------------------------------------------------
-- O livro: uma linha por lançamento (orçado, previsto, comprometido, realizado). A natureza
-- restrita só chega a quem a tem liberada (RLS) e, ainda assim, somada por mês (regra 3).
create view bi.f_livro with (security_invoker = true, security_barrier = true) as
with l as (
  select l.*, erp.natureza_restrita(l.natureza_id) as restrita, ld.subtrai
  from erp.lancamentos l
  join erp.naturezas n on n.id = l.natureza_id
  join erp.linhas_dre ld on ld.codigo = n.linha_dre
)
select l.id as lancamento_id, l.estagio, l.orcamento_versao_id, l.empresa_id, l.nucleo_economico_id,
       l.centro_custo_id, l.divisao_id, l.subdivisao_id, l.natureza_id, l.competencia, l.data_caixa,
       l.valor, case when l.subtrai then -l.valor else l.valor end as valor_dre,
       l.titulo_id, l.parcela_id, l.previsao_id, l.quitacao_id, l.pagamento_id,
       l.criado_em as lancado_em, bi.data_sp(l.criado_em) as lancado_data, false as restrita
from l where not l.restrita
union all
select null, l.estagio, l.orcamento_versao_id, l.empresa_id, l.nucleo_economico_id,
       l.centro_custo_id, null, null, l.natureza_id, l.competencia, date_trunc('month', l.data_caixa)::date,
       sum(l.valor), sum(case when l.subtrai then -l.valor else l.valor end),
       null, null, null, null, null, null, null, true
from l where l.restrita
group by l.estagio, l.orcamento_versao_id, l.empresa_id, l.nucleo_economico_id, l.centro_custo_id,
         l.natureza_id, l.competencia, date_trunc('month', l.data_caixa);

-- Parcelas a pagar e a receber, uma linha por parcela e linha do rateio (para somar por centro),
-- com o pago e o saldo na mesma proporção. Sem rascunho e sem título com linha restrita.
create view bi.f_parcelas with (security_invoker = true, security_barrier = true) as
select p.id as parcela_id, t.id as titulo_id, t.empresa_id, t.pessoa_id, t.sentido, t.tipo as titulo_tipo,
       t.numero as titulo_numero, t.documento_id, t.compromisso_id, t.situacao as titulo_situacao,
       r.nucleo_economico_id, r.centro_custo_id, r.divisao_id, r.subdivisao_id, r.natureza_id,
       t.emissao, t.competencia, p.numero as parcela_numero, p.vencimento,
       p.valor as valor_parcela, r.valor as valor,
       round(coalesce(q.pago, 0) * r.valor / p.valor, 2) as pago,
       r.valor - round(coalesce(q.pago, 0) * r.valor / p.valor, 2) as saldo,
       erp.sinal(t.sentido) * r.valor as valor_sinal,
       case when t.situacao = 'cancelado' then 'cancelada'
            when p.valor - coalesce(q.pago, 0) = 0 then 'quitada'
            when p.vencimento < bi.hoje() then 'vencida' else 'aberta' end as situacao,
       q.ultimo_pagamento,
       t.criado_por as lancado_por, t.criado_em as lancado_em, bi.data_sp(t.criado_em) as lancado_data
from erp.parcelas p
join erp.titulos t on t.id = p.titulo_id
cross join lateral erp.ratear('titulo', t.id, p.valor) r
left join (select qq.parcela_id, sum(qq.principal) as pago, max(g.data) as ultimo_pagamento
             from erp.quitacoes qq join erp.pagamentos g on g.id = qq.pagamento_id group by 1) q on q.parcela_id = p.id
where t.situacao <> 'rascunho'
  and not exists (select 1 from erp.titulo_rateios x where x.titulo_id = t.id and erp.natureza_restrita(x.natureza_id))
  -- a linha do rateio que a pessoa vê (quem aprova vê o título, não necessariamente cada linha)
  and (erp.sistema() or erp.vejo(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, t.criado_por, r.divisao_id));

-- Pagamentos: uma linha por quitação (quanto de cada pagamento quitou cada parcela), com os
-- prazos. dias_atraso conta só o atraso (0 em dia ou antes); dias_antes_vencimento, a folga.
create view bi.f_pagamentos with (security_invoker = true, security_barrier = true) as
select q.id as quitacao_id, g.id as pagamento_id, p.id as parcela_id, t.id as titulo_id,
       g.empresa_id, t.pessoa_id, t.sentido, t.tipo as titulo_tipo, g.conta_id, g.forma, g.lote_id,
       g.nucleo_economico_id as pagamento_nucleo_id, g.centro_custo_id as pagamento_centro_id,
       g.data as data_pagamento, p.vencimento, t.emissao, t.competencia,
       q.principal, q.juros, q.multa, q.desconto, q.principal + q.juros + q.multa - q.desconto as valor_pago,
       greatest(g.data - p.vencimento, 0) as dias_atraso,
       greatest(p.vencimento - g.data, 0) as dias_antes_vencimento,
       g.data - t.emissao as prazo_pagamento,
       g.criado_por as registrado_por, g.criado_em as registrado_em, bi.data_sp(g.criado_em) as registrado_data
from erp.quitacoes q
join erp.pagamentos g on g.id = q.pagamento_id
join erp.parcelas p on p.id = q.parcela_id
join erp.titulos t on t.id = p.titulo_id
where not exists (select 1 from erp.titulo_rateios x where x.titulo_id = t.id and erp.natureza_restrita(x.natureza_id));

-- Adiantamentos (o dinheiro que saiu antes da nota), com o carimbo de núcleo, centro e divisão.
create view bi.f_adiantamentos with (security_invoker = true, security_barrier = true) as
select g.id as pagamento_id, g.adiantamento_id as pedido_titulo_id, g.empresa_id, g.pessoa_id, g.compromisso_id,
       g.nucleo_economico_id, g.centro_custo_id, g.divisao_id, g.data, g.valor,
       erp.pagamento_saldo(g.id) as saldo, g.valor - erp.pagamento_saldo(g.id) as abatido,
       g.criado_por as registrado_por, g.criado_em as registrado_em, bi.data_sp(g.criado_em) as registrado_data
from erp.pagamentos g
where g.adiantamento_id is not null;

-- Eventos do título: uma linha por evento, do instante gravado pelo servidor. Base dos prazos
-- (quanto tempo levou de um evento ao outro, com quanta antecedência a nota chegou). Sem título
-- com linha restrita.
create view bi.f_titulo_eventos with (security_invoker = true, security_barrier = true) as
with e as (
  -- a nota chegou ao sistema (quem pede anexa a nota)
  select t.id as titulo_id, 1 as ordem, 'nota_postada' as evento, t.rodada, d.criado_em as em, d.criado_por as por,
         null::uuid as centro_custo_id, null::uuid as divisao_id, null::int as fase, null::text as lista, null::boolean as aprovado
    from erp.titulos t join erp.documentos_fiscais d on d.id = t.documento_id
  union all
  select t.id, 2, 'nota_lancada', t.rodada, d.lancado_em, null, null, null, null, null, null
    from erp.titulos t join erp.documentos_fiscais d on d.id = t.documento_id where d.lancado_em is not null
  union all
  select t.id, 3, 'titulo_lancado', 1, t.criado_em, t.criado_por, null, null, null, null, null from erp.titulos t
  union all
  -- confirmado: a alçada de cada centro (e divisão) foi definida
  select a.titulo_id, 4, 'alcada_definida', a.rodada, a.definida_em, null, a.centro_custo_id, a.divisao_id, null, null, null
    from erp.titulo_alcadas a
  union all
  select v.titulo_id, 5, case when v.aprovado then 'aprovacao' else 'recusa' end, v.rodada, v.em, v.por,
         v.centro_custo_id, v.divisao_id, v.fase, v.lista, v.aprovado
    from erp.titulo_aprovacoes v
  union all
  select r.titulo_id, 6, 'revisao_pedida', r.rodada, r.pedida_em, r.pedida_por, r.centro_custo_id, null, r.fase, null, null
    from erp.titulo_revisoes r
  union all
  select r.titulo_id, 7, 'revisao_reenviada', r.rodada, r.reenviada_em, r.reenviada_por, r.centro_custo_id, null, r.fase, null, null
    from erp.titulo_revisoes r where r.reenviada_em is not null
  union all
  select p.titulo_id, 8, 'pagamento', null, g.criado_em, g.criado_por, null, null, null, null, null
    from erp.quitacoes q join erp.pagamentos g on g.id = q.pagamento_id join erp.parcelas p on p.id = q.parcela_id
)
select e.titulo_id, t.empresa_id, e.evento, e.ordem as evento_ordem, e.rodada, e.em, bi.data_sp(e.em) as data, e.por,
       e.centro_custo_id, e.divisao_id, e.fase, e.lista, e.aprovado
from e join erp.titulos t on t.id = e.titulo_id
where not exists (select 1 from erp.titulo_rateios x where x.titulo_id = t.id and erp.natureza_restrita(x.natureza_id));

-- Ponte título × etiqueta (a campanha, por exemplo): filtra e agrupa parcelas, pagamentos e o
-- livro pelo titulo_id. Sem título com linha restrita.
create view bi.f_titulo_etiquetas with (security_invoker = true, security_barrier = true) as
select te.titulo_id, te.etiqueta_id
from erp.titulo_etiquetas te
where not exists (select 1 from erp.titulo_rateios x where x.titulo_id = te.titulo_id and erp.natureza_restrita(x.natureza_id));

-- ---------------------------------------------------------------------------------------------
-- Privilégios: só leitura para o usuário logado; nada para anon, service_role nem public
-- ---------------------------------------------------------------------------------------------
revoke all on all tables in schema bi from public;
grant select on all tables in schema bi to authenticated;
revoke execute on all functions in schema bi from public;
grant execute on all functions in schema bi to authenticated;
-- estender o calendário é só do sistema (o RLS já barra; sem EXECUTE, nem chega lá)
revoke execute on function bi.estender_calendario(int) from authenticated;
