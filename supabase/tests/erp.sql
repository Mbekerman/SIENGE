-- Testes das regras do ERP BKM.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;

create function pg_temp.como(u text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce(u, ''), false) $$;
create function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(cond,false) then raise exception 'FALHOU: %', msg; end if; raise notice 'ok  %', msg; end $$;
create function pg_temp.falha(sqlcmd text, msg text) returns void language plpgsql as $$
begin
  begin execute sqlcmd; exception when others then raise notice 'ok  % (%)', msg, sqlerrm; return; end;
  raise exception 'FALHOU: esperava erro em %', msg;
end $$;
create function pg_temp.nat(c text) returns uuid language sql as $$ select id from erp.naturezas where codigo = c $$;
-- soma do livro por estágio, filtrando por título
create function pg_temp.livro(p_estagio text, p_titulo uuid default null) returns numeric language sql as $$
  select coalesce(sum(valor), 0) from erp.lancamentos where estagio = p_estagio and (p_titulo is null or titulo_id = p_titulo) $$;
set client_min_messages = notice;

\set diretor  '00000000-0000-0000-0000-00000000000a'
\set diretor2 '00000000-0000-0000-0000-00000000000f'
\set gestor   '00000000-0000-0000-0000-00000000000e'
\set analista '00000000-0000-0000-0000-00000000000b'
\set leitor   '00000000-0000-0000-0000-00000000000d'
\set contador '00000000-0000-0000-0000-00000000000c'

insert into erp.usuarios (user_id, nome, papel, administrador, contador) values
  (:'diretor', 'Moises', 'diretor', true, false),
  (:'diretor2', 'Sócia', 'diretor', false, false),
  (:'gestor', 'Paula', 'gestor', false, false),
  (:'analista', 'Rafael', 'analista', false, false),
  (:'leitor', 'Consulta', 'leitura', false, false),
  (:'contador', 'Contador', 'analista', false, true);

-- ---------------------------------------------------------------------
\echo '# raiz: empresas, sócios, empreendimento'
insert into erp.pessoas (id, tipo, nome, documento) values
  ('10000000-0000-0000-0000-000000000001', 'juridica', 'Holding BKM', '11111111000111'),
  ('10000000-0000-0000-0000-000000000002', 'juridica', 'BKM Incorporadora', '22222222000122'),
  ('10000000-0000-0000-0000-000000000003', 'juridica', 'SPE Vila Maria', '33333333000133'),
  ('10000000-0000-0000-0000-000000000004', 'juridica', 'Sócio Investidor', '44444444000144'),
  ('10000000-0000-0000-0000-000000000005', 'juridica', 'Construtora Alfa', '55555555000155'),
  ('10000000-0000-0000-0000-000000000006', 'juridica', 'Prefeitura de São Paulo', '46395000000139'),
  ('10000000-0000-0000-0000-000000000007', 'juridica', 'Agência Beta', '77777777000177'),
  ('10000000-0000-0000-0000-000000000008', 'juridica', 'Conserta Já', '88888888000188');
insert into erp.pessoa_papeis values
  ('10000000-0000-0000-0000-000000000005', 'fornecedor'), ('10000000-0000-0000-0000-000000000005', 'cliente'),
  ('10000000-0000-0000-0000-000000000006', 'orgao_publico');
select pg_temp.ok((select count(*) from erp.pessoa_papeis where pessoa_id = '10000000-0000-0000-0000-000000000005') = 2,
  'a mesma pessoa é fornecedora e cliente, sem cadastro duplicado');
select pg_temp.falha($$insert into erp.pessoas (tipo, nome, documento) values ('fisica', 'X', '123')$$, 'CPF com tamanho errado');

insert into erp.empresas (id, pessoa_id, tipo) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'holding'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'incorporadora'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'spe');
\set holding '20000000-0000-0000-0000-000000000001'
\set incorp  '20000000-0000-0000-0000-000000000002'
\set spe     '20000000-0000-0000-0000-000000000003'

insert into erp.participacoes (empresa_id, socio_id, percentual, inicio) values
  (:'incorp', '10000000-0000-0000-0000-000000000001', 100, '2020-01-01'),
  (:'spe', '10000000-0000-0000-0000-000000000002', 70, '2025-01-01'),
  (:'spe', '10000000-0000-0000-0000-000000000004', 30, '2025-01-01');
select pg_temp.falha($$insert into erp.participacoes (empresa_id, socio_id, percentual, inicio)
  values ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 5, '2026-01-01')$$,
  'participações da SPE não passam de 100%');
select pg_temp.falha($$insert into erp.participacoes (empresa_id, socio_id, percentual, inicio)
  values ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 1, '2019-01-01')$$,
  'empresa não é sócia de si mesma');
-- troca de sócio: encerra a participação e abre outra
update erp.participacoes set fim = '2025-12-31' where socio_id = '10000000-0000-0000-0000-000000000004';
insert into erp.participacoes (empresa_id, socio_id, percentual, inicio) values
  (:'spe', '10000000-0000-0000-0000-000000000001', 30, '2026-01-01');
select pg_temp.ok(true, 'participação com vigência: o sócio sai e outro entra sem passar de 100%');

select pg_temp.falha($$insert into erp.empreendimentos (spe_id, codigo, nome) values ('20000000-0000-0000-0000-000000000002', 'X', 'X')$$,
  'empreendimento só em empresa do tipo SPE');
insert into erp.empreendimentos (id, spe_id, codigo, nome, municipio, uf, terreno_ref)
values ('30000000-0000-0000-0000-000000000001', :'spe', 'VMA', 'Vila Maria', 'São Paulo', 'SP', 'A123');
select pg_temp.falha($$insert into erp.empreendimentos (spe_id, codigo, nome) values ('20000000-0000-0000-0000-000000000003', 'Y', 'Y')$$,
  'uma SPE tem um empreendimento só');

insert into erp.nucleos_economicos (id, empresa_id, tipo, empreendimento_id, nome) values
  ('40000000-0000-0000-0000-000000000001', :'spe', 'empreendimento', '30000000-0000-0000-0000-000000000001', 'Vila Maria'),
  ('40000000-0000-0000-0000-000000000002', :'incorp', 'corporativo', null, 'Corporativo');
\set ne_vm   '40000000-0000-0000-0000-000000000001'
\set ne_corp '40000000-0000-0000-0000-000000000002'
select pg_temp.falha($$insert into erp.nucleos_economicos (empresa_id, tipo, empreendimento_id, nome)
  values ('20000000-0000-0000-0000-000000000002', 'empreendimento', '30000000-0000-0000-0000-000000000001', 'Outro')$$,
  'núcleo econômico do empreendimento fica na SPE dele');
select pg_temp.falha($$insert into erp.nucleos_economicos (empresa_id, tipo, nome)
  values ('20000000-0000-0000-0000-000000000002', 'area', 'Marketing')$$,
  'área não é núcleo econômico (Marketing é centro de custo)');

-- centros de custo: lista raiz única, ligada ou desligada em cada núcleo
update erp.centros_custo set id = '45000000-0000-0000-0000-000000000001' where nome = 'Obra';
update erp.centros_custo set id = '45000000-0000-0000-0000-000000000002' where nome = 'Marketing';
\set cc_obra '45000000-0000-0000-0000-000000000001'
\set cc_mkt  '45000000-0000-0000-0000-000000000002'
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id)
  values ('40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001')$$,
  'analista não liga centro de custo em núcleo');
select pg_temp.como(:'diretor');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values
  (:'ne_vm', :'cc_obra', true), (:'ne_vm', :'cc_mkt', true),
  (:'ne_corp', :'cc_mkt', true), (:'ne_corp', :'cc_obra', false);
select pg_temp.ok(erp.centro_ligado(:'ne_vm', :'cc_obra') and not erp.centro_ligado(:'ne_corp', :'cc_obra'),
  'o Corporativo não tem Obra; a Vila Maria tem');
select pg_temp.ok((select count(*) from erp.auditoria where tabela = 'nucleo_centros') = 4,
  'ligar e desligar centro no núcleo fica na auditoria');
select pg_temp.falha($$delete from erp.nucleo_centros where nucleo_economico_id = '40000000-0000-0000-0000-000000000002'$$,
  'vínculo não se apaga; desliga');
select pg_temp.falha($$update erp.nucleo_centros set centro_custo_id = (select id from erp.centros_custo where nome = 'Jurídico')
  where nucleo_economico_id = '40000000-0000-0000-0000-000000000002' and centro_custo_id = '45000000-0000-0000-0000-000000000002'$$,
  'vínculo não muda de centro; desliga e liga outro');
select pg_temp.falha($$truncate erp.nucleo_centros$$, 'vínculos não se apagam nem por truncate');
select pg_temp.como(null);

-- atributos de BI com vigência
insert into erp.empreendimento_atributos (empreendimento_id, atributo_id, opcao_id, inicio, fim)
select '30000000-0000-0000-0000-000000000001', a.id, o.id, '2025-01-01', '2026-06-30'
from erp.atributos a join erp.atributo_opcoes o on o.atributo_id = a.id where a.codigo = 'faixa_mcmv' and o.valor = 'Faixa 2';
insert into erp.empreendimento_atributos (empreendimento_id, atributo_id, opcao_id, inicio)
select '30000000-0000-0000-0000-000000000001', a.id, o.id, '2026-07-01'
from erp.atributos a join erp.atributo_opcoes o on o.atributo_id = a.id where a.codigo = 'faixa_mcmv' and o.valor = 'Faixa 3';
select pg_temp.falha($$insert into erp.empreendimento_atributos (empreendimento_id, atributo_id, opcao_id, inicio)
  select '30000000-0000-0000-0000-000000000001', a.id, o.id, '2026-08-01'
  from erp.atributos a join erp.atributo_opcoes o on o.atributo_id = a.id where a.codigo = 'faixa_mcmv' and o.valor = 'Faixa 1'$$,
  'atributo não tem dois valores no mesmo período');

-- ---------------------------------------------------------------------
\echo '# árvore de naturezas'
select pg_temp.ok((select count(*) from erp.naturezas where mae_id is null) = 11, 'carga inicial com 11 grupos');
select pg_temp.ok((select caminho from erp.v_naturezas where codigo = '05.01.01') = 'Comerciais › Marketing › Online', 'caminho legível');
select pg_temp.ok((select redutora and linha_dre = 'deducoes' from erp.naturezas where codigo = '02.01'),
  'galho herda as características do grupo (Impostos sobre a receita = redutora, Deduções)');
select pg_temp.ok((select tipo = 'nao_operacional' and linha_dre = 'outras_receitas' from erp.naturezas where codigo = '01.04'),
  'galho pode trocar o que herdou (Outras receitas)');

select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.naturezas (mae_id, nome) values ((select id from erp.naturezas where codigo = '05.01'), 'TikTok')$$,
  'analista não cria natureza');
select pg_temp.como(:'diretor');
insert into erp.naturezas (codigo, mae_id, nome) values ('05.01.01.01', pg_temp.nat('05.01.01'), 'Verba de mídia Google');
select pg_temp.ok((select linha_dre = 'despesas_comerciais' and tipo = 'operacional' and not so_orcado from erp.naturezas where codigo = '05.01.01.01'),
  'administrador cria natureza nova e ela já nasce com DRE e tipo da mãe');
select pg_temp.ok((select caminho from erp.v_naturezas where codigo = '05.01.01.01') = 'Comerciais › Marketing › Online › Verba de mídia Google',
  'a árvore aceita quantos níveis precisar');
select pg_temp.falha($$update erp.naturezas set mae_id = (select id from erp.naturezas where codigo = '05.01.01.01') where codigo = '05.01'$$,
  'natureza não fica abaixo dela mesma');
update erp.naturezas set nome = 'Receitas de vendas' where codigo = '01';
select pg_temp.ok((select nome from erp.naturezas where codigo = '01') = 'Receitas de vendas', 'o topo também se edita (pelo administrador)');
update erp.naturezas set nome = 'Receitas' where codigo = '01';

-- ---------------------------------------------------------------------
\echo '# compromisso e previsão (assinatura no lugar do contrato fictício)'
select pg_temp.como(:'analista');
insert into erp.contas_bancarias (id, empresa_id, banco, agencia, conta) values
  ('50000000-0000-0000-0000-000000000001', :'spe', 'Itaú', '0001', '12345-6'),
  ('50000000-0000-0000-0000-000000000002', :'incorp', 'Itaú', '0001', '99999-0');
\set conta_spe '50000000-0000-0000-0000-000000000001'
\set conta_inc '50000000-0000-0000-0000-000000000002'

insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, fim, periodicidade, valor_periodo, dia_vencimento)
values ('60000000-0000-0000-0000-000000000001', :'incorp', 'assinatura', '10000000-0000-0000-0000-000000000007',
        'Agência de marketing', '2026-01-01', '2026-12-31', 'mensal', 10000, 10);
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000002', (select id from erp.naturezas where codigo = '05.01'), 100)$$,
  'não se lança em natureza que tem galhos abaixo (Marketing)');
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '05.01.04'), 100)$$,
  'despesa precisa de núcleo econômico');
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', (select id from erp.naturezas where codigo = '05.01.04'), 100)$$,
  'despesa precisa de centro de custo');
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '05.01.04'), 100)$$,
  'centro de custo desligado no núcleo não recebe lançamento (Obra no Corporativo)');
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', (select id from erp.centros_custo where nome = 'Jurídico'), (select id from erp.naturezas where codigo = '05.01.04'), 100)$$,
  'centro de custo sem vínculo com o núcleo conta como desligado');
select pg_temp.falha($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000002', (select id from erp.naturezas where codigo = '08.03'), 100)$$,
  'custo de capital é só do orçado');
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('60000000-0000-0000-0000-000000000001', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.ok(erp.gerar_previsoes_assinatura('60000000-0000-0000-0000-000000000001', '2026-03-31') = 3, 'assinatura gera 3 previsões mensais');
select pg_temp.ok(erp.gerar_previsoes_assinatura('60000000-0000-0000-0000-000000000001', '2026-03-31') = 0, 'gerar de novo não duplica');
select pg_temp.ok((select data_prevista from erp.previsoes where compromisso_id = '60000000-0000-0000-0000-000000000001' order by competencia limit 1) = '2026-01-10',
  'previsão no dia de vencimento da assinatura');
select pg_temp.ok(pg_temp.livro('previsto') = -30000, 'previsões no livro como saída prevista');

-- ---------------------------------------------------------------------
\echo '# nota com retenções e caução'
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, numero, descricao, inicio, valor_total, caucao_percentual)
values ('60000000-0000-0000-0000-000000000002', :'spe', 'contrato', '10000000-0000-0000-0000-000000000005', 'CT-1',
        'Fundações', '2026-01-01', 100000, 5);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('60000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
insert into erp.previsoes (empresa_id, origem, compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values (:'spe', 'saldo_contrato', '60000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 12000);

insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000001', :'spe', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002',
        'nfse', '101', '2026-02-05', '2026-02-01', 10000);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento) values
  ('70000000-0000-0000-0000-000000000001', 'iss', 500, '10000000-0000-0000-0000-000000000006', '2026-03-10');
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
-- S-030: a nota só consome previsão que casa em tudo; um caso por critério
begin;
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000009', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '109', '2026-02-05', '2026-02-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50),
  ('70000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-000000000001', :'incorp', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000002', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000003', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000004', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000005', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.02'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000006', :'spe', 'manual', null, :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000);
select pg_temp.falha($$select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000001'::uuid])$$,
  'previsão de outra empresa não casa');
select pg_temp.falha($$select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000002'::uuid])$$,
  'previsão de outro fornecedor não casa');
select pg_temp.falha($$select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000003'::uuid])$$,
  'previsão de outro núcleo econômico não casa');
select pg_temp.falha($$select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000004'::uuid])$$,
  'previsão de outro centro de custo não casa');
select pg_temp.falha($$select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000005'::uuid])$$,
  'previsão de outra natureza não casa');
select erp.lancar_documento('70000000-0000-0000-0000-000000000009', array['2026-02-20']::date[], array['68000000-0000-0000-0000-000000000006'::uuid]) as tit9 \gset
select pg_temp.ok((select sum(valor) from erp.titulo_previsoes where titulo_id = :'tit9') = 50,
  'previsão sem fornecedor casa, e só consome a parte do rateio igual a ela (50 de 100)');
rollback;
select erp.lancar_documento('70000000-0000-0000-0000-000000000001', array['2026-02-20','2026-03-20']::date[]) as tit \gset
select pg_temp.ok((select valor from erp.titulos where id = :'tit') = 9000, 'título do fornecedor pelo líquido: 10.000 − 500 de ISS − 500 de caução');
select pg_temp.ok((select count(*) = 2 and sum(valor) = 9000 from erp.parcelas where titulo_id = :'tit'), 'em 2 parcelas');
select pg_temp.ok((select pessoa_id = '10000000-0000-0000-0000-000000000006' and valor = 500 from erp.titulos
                   where documento_id = '70000000-0000-0000-0000-000000000001' and tipo = 'imposto'), 'título do ISS contra a prefeitura');
select pg_temp.ok(erp.caucao_saldo('60000000-0000-0000-0000-000000000002') = 500, 'caução de 5% do contrato no extrato');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'comprometido' and nucleo_economico_id = :'ne_vm') = -10000,
  'comprometido no livro soma o bruto (fornecedor + ISS + caução)');
select pg_temp.ok((select saldo = 2000 and situacao = 'aberta' from erp.v_previsoes where compromisso_id = '60000000-0000-0000-0000-000000000002')
  and (select sum(valor) from erp.lancamentos where estagio = 'previsto' and nucleo_economico_id = :'ne_vm') = -2000,
  'a nota de 10.000 consome a previsão de 12.000 do contrato; sobram 2.000 previstos no livro');
select pg_temp.falha($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000005', 'nfse', '101', '2026-02-06', '2026-02-01', 10)$$,
  'nota repetida do mesmo emitente é recusada (o Sienge aceita)');
select pg_temp.falha(format($$update erp.titulos set valor = 1 where id = %L$$, :'tit'), 'título confirmado não se edita');
select pg_temp.falha(format($$delete from erp.parcelas where titulo_id = %L$$, :'tit'), 'parcela de título confirmado não se apaga');

-- ---------------------------------------------------------------------
\echo '# pagamento, quitação parcial, juros e adiantamento'
select id as p1 from erp.parcelas where titulo_id = :'tit' and numero = 1 \gset
select id as p2 from erp.parcelas where titulo_id = :'tit' and numero = 2 \gset
-- parcela 1 (4.500) paga em duas vezes
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, data, valor) values
  ('80000000-0000-0000-0000-000000000001', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', '2026-02-20', 2000);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000001', :'p1', 2000);
select pg_temp.ok(erp.parcela_saldo(:'p1') = 2500, 'pagamento parcial: a parcela fica com saldo');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, data, valor) values
  ('80000000-0000-0000-0000-000000000002', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', '2026-02-25', 2530);
insert into erp.quitacoes (pagamento_id, parcela_id, principal, juros, multa) values ('80000000-0000-0000-0000-000000000002', :'p1', 2500, 10, 20);
select pg_temp.ok(erp.parcela_saldo(:'p1') = 0, 'segunda quitação zera a parcela; juros e multa entram só na hora de pagar');
select pg_temp.ok((select sum(valor) from erp.lancamentos where natureza_id = pg_temp.nat('08.01.02')) = -30,
  'juros e multa no livro, em Financeiras › Juros e multas pagos');
select pg_temp.falha($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000002',
  (select id from erp.parcelas where titulo_id = (select titulo_id from erp.parcelas where id = (select parcela_id from erp.quitacoes limit 1)) and numero = 2), 1)$$,
  'pagamento não quita mais do que o próprio valor');

-- adiantamento de 6.000 ao fornecedor, sem título
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, compromisso_id, data, valor) values
  ('80000000-0000-0000-0000-000000000003', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005',
   '60000000-0000-0000-0000-000000000002', '2026-03-01', 6000);
select pg_temp.ok((select saldo from erp.v_adiantamentos where pagamento_id = '80000000-0000-0000-0000-000000000003') = 6000,
  'adiantamento = pagamento sem quitação, com saldo a abater');
insert into erp.quitacoes (pagamento_id, parcela_id, principal, desconto) values ('80000000-0000-0000-0000-000000000003', :'p2', 4500, 100);
select pg_temp.ok(erp.pagamento_saldo('80000000-0000-0000-0000-000000000003') = 1600, 'abatido aos poucos: 4.500 − 100 de desconto saem do adiantamento');
select pg_temp.ok((select situacao from erp.titulos where id = :'tit') = 'quitado', 'título sem saldo vira quitado');
select pg_temp.ok(pg_temp.livro('comprometido', :'tit') = 0, 'título quitado não deixa comprometido em aberto');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'realizado' and natureza_id = pg_temp.nat('04.01')) = -9000,
  'realizado na natureza da obra = principal pago (9.000)');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'realizado' and natureza_id = pg_temp.nat('11.02')) = -1600,
  'saldo de adiantamento aparece no livro em Movimentações');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'realizado' and empresa_id = :'spe')
                  = -(2000 + 2530 + 6000), 'o realizado do livro bate com o dinheiro que saiu do banco');
select pg_temp.falha($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003',
  (select id from erp.parcelas where titulo_id = (select id from erp.titulos where tipo = 'imposto')), 100)$$,
  'adiantamento de um fornecedor não paga título de outra pessoa');
select pg_temp.falha($$delete from erp.quitacoes$$, 'quitação não se apaga');
select pg_temp.falha($$delete from erp.lancamentos$$, 'o livro não apaga linhas');
select pg_temp.falha($$update erp.lancamentos set valor = 1$$, 'o livro não se edita');

-- pagar o ISS pelo atalho
select erp.pagar_parcela((select p.id from erp.parcelas p join erp.titulos t on t.id = p.titulo_id where t.tipo = 'imposto'),
                            :'conta_spe', '2026-03-10') is not null as x \gset
select pg_temp.ok((select situacao from erp.titulos where tipo = 'imposto') = 'quitado', 'atalho paga a parcela inteira');

-- ---------------------------------------------------------------------
\echo '# caução: liberação e uso com terceiro'
select pg_temp.falha($$select erp.liberar_caucao('60000000-0000-0000-0000-000000000002', 600, '2026-12-01')$$, 'não libera mais do que o saldo');
select erp.liberar_caucao('60000000-0000-0000-0000-000000000002', 200, '2026-12-01',
  '10000000-0000-0000-0000-000000000008', 'Conserto da impermeabilização') as tc \gset
select pg_temp.ok((select pessoa_id from erp.titulos where id = :'tc') = '10000000-0000-0000-0000-000000000008',
  'caução usada para pagar terceiro gera título para ele');
select erp.liberar_caucao('60000000-0000-0000-0000-000000000002', 300, '2026-12-01') as tl \gset
select pg_temp.ok(erp.caucao_saldo('60000000-0000-0000-0000-000000000002') = 0, 'liberação do restante zera o extrato');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'comprometido' and data_caixa is null) = 0,
  'caução sai do comprometido sem data e passa para os títulos com vencimento');

-- ---------------------------------------------------------------------
\echo '# dinheiro entre sócios'
select erp.registrar_movimento_societario('aporte', :'incorp', :'spe', 50000, '2026-02-01', 'Aporte inicial') as ms \gset
select pg_temp.ok((select count(*) from erp.titulos t join erp.movimentos_societarios m on t.id in (m.titulo_pagar_id, m.titulo_receber_id) where m.id = :'ms') = 2,
  'aporte vira par ligado: a pagar na incorporadora, a receber na SPE');
select pg_temp.ok((select sum(l.valor) from erp.lancamentos l join erp.movimentos_societarios m on l.titulo_id in (m.titulo_pagar_id, m.titulo_receber_id) where m.id = :'ms') = 0,
  'no consolidado do grupo o par se anula');

-- ---------------------------------------------------------------------
\echo '# orçamento'
insert into erp.orcamento_versoes (id, empresa_id, empreendimento_id, tipo, nome, data_base)
values ('90000000-0000-0000-0000-000000000001', :'spe', '30000000-0000-0000-0000-000000000001', 'viabilidade', 'Viabilidade', '2025-12-01');
insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, valor) values
  ('90000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', -15000),
  ('90000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('08.03'), '2026-02-01', -800);
select pg_temp.ok(true, 'custo de capital entra no orçado');
select erp.publicar_orcamento('90000000-0000-0000-0000-000000000001');
select pg_temp.ok(pg_temp.livro('orcado') = -15800, 'publicar grava o orçado no livro');
select pg_temp.falha($$insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, valor)
  values ('90000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '04.02'), '2026-03-01', -1)$$,
  'versão publicada não muda');

-- ---------------------------------------------------------------------
\echo '# visões'
select pg_temp.ok((select realizado from erp.v_fluxo_caixa where empresa_id = :'spe' and data_caixa = '2026-02-20') = -2000,
  'fluxo de caixa: realizado do dia');
select pg_temp.ok((select atributos->>'faixa_mcmv' from erp.v_lancamentos_bi where estagio = 'orcado' limit 1) = 'Faixa 2',
  'visão de BI traz a faixa MCMV vigente na competência (fev/26 = Faixa 2, que mudou em jul)');
select pg_temp.ok((select count(*) from erp.v_lancamentos_bi) = (select count(*) from erp.lancamentos), 'visão de BI não perde linhas');
select pg_temp.ok((select count(*) from erp.v_lancamentos_bi where nucleo_economico = 'Vila Maria' and centro_custo = 'Obra') > 0,
  'visão de BI traz núcleo econômico e centro de custo separados');

-- ---------------------------------------------------------------------
\echo '# árvore com uso'
select pg_temp.como(:'diretor');
select pg_temp.falha($$insert into erp.naturezas (mae_id, nome) values ((select id from erp.naturezas where codigo = '04.01'), 'Estacas')$$,
  'natureza com lançamentos não ganha galho: reclassifique antes');
select pg_temp.falha($$delete from erp.naturezas where codigo = '04.01'$$, 'natureza com lançamentos não se apaga');
insert into erp.naturezas (codigo, mae_id, nome) values ('04.07', pg_temp.nat('04'), 'Teste vazio');
delete from erp.naturezas where codigo = '04.07';
select pg_temp.ok(pg_temp.nat('04.07') is null, 'natureza nunca usada se apaga');
update erp.naturezas set ativa = false where codigo = '04.06';
select pg_temp.falha($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values ('20000000-0000-0000-0000-000000000003', 'manual', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '04.06'), '2026-05-01', '2026-05-01', 1)$$,
  'natureza desativada não recebe lançamento novo');
update erp.naturezas set ativa = true where codigo = '04.06';
-- mover galho com lançamentos: só diretoria (o administrador não diretor não move)
update erp.usuarios set administrador = true where user_id = :'gestor';
select pg_temp.como(:'gestor');
select pg_temp.falha($$update erp.naturezas set linha_dre = 'despesas_gerais' where codigo = '04.01'$$,
  'mudar DRE de natureza com lançamentos (muda relatório do passado) só pela diretoria');
select pg_temp.como(:'diretor');
update erp.naturezas set linha_dre = 'custo_obra' where codigo = '04.01';
select pg_temp.ok(true, 'diretoria pode');

-- ---------------------------------------------------------------------
\echo '# reclassificação'
-- obra 04.01 tem orçado, comprometido e realizado. Pedido do analista: mover para 04.02 (Custo atípico)
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$select erp.pedir_reclassificacao(%L, %L, 'x')$$, pg_temp.nat('04.01'), pg_temp.nat('04.02')), 'leitura não pede reclassificação');
select pg_temp.como(:'analista');
select pg_temp.falha(format($$select erp.pedir_reclassificacao(%L, %L, 'x')$$, pg_temp.nat('04.01'), pg_temp.nat('04')), 'destino precisa ser do último nível');
select erp.pedir_reclassificacao(pg_temp.nat('04.01'), pg_temp.nat('04.02'), 'Fundação era estaca especial',
  jsonb_build_object('estagios', jsonb_build_array('realizado'), 'de', '2026-02-01', 'ate', '2026-02-01')) as r1 \gset
select pg_temp.ok((select valor from erp.reclassificacoes where id = :'r1') = 12000,
  'valor do pedido = o maior estágio movido (a previsão de 12.000 do contrato vai junto com os títulos), sem contar estornos duas vezes');
select pg_temp.ok((select count(*) from erp.reclassificacao_itens i join erp.lancamentos l on l.id = i.lancamento_id
                   where i.reclassificacao_id = :'r1' and l.estagio = 'previsto') = 2,
  'a previsão consumida pelo título vai junto, com a linha original e o estorno');
select pg_temp.ok((select nivel = 'diretor' and faixa = 'mes_aberto' from erp.reclassificacoes where id = :'r1'), 'padrão: mês aberto pela diretoria');
select pg_temp.ok((erp.previa_reclassificacao(:'r1')->>'muda_dre')::boolean = false, 'prévia mostra se a DRE muda');
select pg_temp.falha(format($$select erp.decidir_reclassificacao(%L, true)$$, :'r1'), 'quem pediu não aprova');
select pg_temp.como(:'gestor');
select pg_temp.falha(format($$select erp.decidir_reclassificacao(%L, true)$$, :'r1'), 'gestor não aprova o que pede diretoria');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(:'r1', true) = 'aprovada', 'diretoria aprova');
select pg_temp.ok(not exists (select 1 from erp.lancamentos l join erp.titulos t on t.id = l.titulo_id
                               where l.natureza_id = pg_temp.nat('04.01') and t.documento_id = '70000000-0000-0000-0000-000000000001'),
  'todas as linhas dos títulos da nota mudaram de natureza (realizado, comprometido e estornos)');
select pg_temp.ok(exists (select 1 from erp.lancamentos l join erp.titulos t on t.id = l.titulo_id
                          where l.natureza_id = pg_temp.nat('04.01') and t.tipo = 'caucao'),
  'títulos fora do filtro (liberações de caução de novembro) ficaram');
select pg_temp.ok(exists (select 1 from erp.lancamentos where natureza_id = pg_temp.nat('04.01') and estagio = 'orcado'),
  'o orçado fora do filtro ficou onde estava');
select pg_temp.ok((select count(*) from erp.reclassificacao_itens where reclassificacao_id = :'r1' and natureza_antes = pg_temp.nat('04.01')) > 0,
  'cada linha guarda a natureza antiga');
select pg_temp.ok(not exists (select 1 from erp.titulo_rateios r join erp.titulos t on t.id = r.titulo_id
                               where r.natureza_id = pg_temp.nat('04.01') and t.documento_id = '70000000-0000-0000-0000-000000000001'),
  'o rateio dos títulos movidos também mudou');

-- alçada configurável: gestor até R$ 5 mil no mês aberto
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.alcadas_reclassificacao (criterio, faixa, ate, nivel) values ('valor', 'mes_aberto', 5000, 'gestor')$$,
  'só o administrador configura alçada');
select pg_temp.como(:'diretor');
insert into erp.alcadas_reclassificacao (criterio, faixa, ate, nivel) values ('valor', 'mes_aberto', 11000, 'gestor'), ('acumulado_mes', null, 35000, 'gestor');
select pg_temp.como(:'analista');
select erp.pedir_reclassificacao(pg_temp.nat('05.01.04'), pg_temp.nat('05.01.05'), 'Era produção de material',
  jsonb_build_object('de', '2026-01-01', 'ate', '2026-01-01')) as r2 \gset
select pg_temp.ok((select nivel from erp.reclassificacoes where id = :'r2') = 'gestor', 'até R$ 11 mil no mês aberto (alçada configurada): gestor aprova');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_reclassificacao(:'r2', true) = 'aprovada', 'gestor aprova dentro da alçada');
-- acumulado da pessoa no mês sobe a alçada
select pg_temp.como(:'analista');
select erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'teste acumulado',
  jsonb_build_object('estagios', jsonb_build_array('orcado','comprometido','realizado'))) as r3 \gset
select pg_temp.ok((select nivel from erp.reclassificacoes where id = :'r3') = 'diretor', 'acima do limite de valor sobe para a diretoria');
select erp.cancelar_reclassificacao(:'r3');
select pg_temp.ok((select situacao from erp.reclassificacoes where id = :'r3') = 'cancelada', 'quem pediu cancela o pedido pendente');
-- recusa precisa de justificativa
select erp.pedir_reclassificacao(pg_temp.nat('05.01.04'), pg_temp.nat('05.01.05'), 'mais um', jsonb_build_object('de', '2026-02-01', 'ate', '2026-02-01')) as r4 \gset
select pg_temp.como(:'gestor');
select pg_temp.falha(format($$select erp.decidir_reclassificacao(%L, false)$$, :'r4'), 'recusar exige justificativa');
select pg_temp.ok(erp.decidir_reclassificacao(:'r4', false, 'Não é produção') = 'recusada', 'recusa encerra o pedido');
-- acumulado da pessoa no mês (limite 35 mil): 12 + 10 aprovados; recusado e cancelado não contam
select pg_temp.como(:'analista');
select erp.pedir_reclassificacao(pg_temp.nat('05.01.04'), pg_temp.nat('05.01.05'), 'fev', jsonb_build_object('de', '2026-02-01', 'ate', '2026-02-01')) as r7 \gset
select pg_temp.ok((select nivel = 'gestor' and acumulado_mes = 32000 from erp.reclassificacoes where id = :'r7'), 'acumulado no limite: ainda gestor');
select erp.pedir_reclassificacao(pg_temp.nat('05.01.04'), pg_temp.nat('05.01.05'), 'mar', jsonb_build_object('de', '2026-03-01', 'ate', '2026-03-01')) as r8 \gset
select pg_temp.ok((select nivel = 'diretor' and acumulado_mes = 42000 from erp.reclassificacoes where id = :'r8'),
  'valor pequeno, mas o acumulado da pessoa no mês passou do limite: diretoria (pedidos picados não escapam)');
select erp.cancelar_reclassificacao(:'r7');
select erp.cancelar_reclassificacao(:'r8');

-- mês e trimestre fechados
select pg_temp.como(:'analista');
select pg_temp.falha(format($$select erp.fechar_mes(%L, '2026-01-01')$$, :'incorp'), 'só a diretoria fecha o mês');
select pg_temp.como(:'diretor');
select pg_temp.falha(format($$select erp.fechar_mes(%L, '2026-02-01')$$, :'incorp'), 'fecha em ordem: janeiro antes de fevereiro');
select erp.fechar_mes(:'incorp', '2026-01-01');
select pg_temp.ok(erp.faixa_periodo(:'incorp', '2026-01-01') = 'trimestre_aberto', 'janeiro fechado com o trimestre aberto');
select erp.fechar_mes(:'incorp', '2026-02-01');
select erp.fechar_mes(:'incorp', '2026-03-01');
select pg_temp.ok(erp.faixa_periodo(:'incorp', '2026-01-01') = 'trimestre_fechado', 'março fechado fecha o 1º trimestre do calendário');
select pg_temp.como(:'analista');
select erp.pedir_reclassificacao(pg_temp.nat('05.01.05'), pg_temp.nat('05.01.04'), 'Volta', jsonb_build_object('de', '2026-01-01', 'ate', '2026-01-01')) as r5 \gset
select pg_temp.ok((select nivel = 'diretor_e_contador' and faixa = 'trimestre_fechado' from erp.reclassificacoes where id = :'r5'),
  'trimestre fechado pede diretoria e contador, mesmo com valor pequeno');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(:'r5', true) = 'pendente', 'só a diretoria não basta');
select pg_temp.como(:'diretor2');
select pg_temp.falha(format($$select erp.decidir_reclassificacao(%L, true)$$, :'r5'), 'segundo diretor não substitui o contador');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_reclassificacao(:'r5', true) = 'aprovada', 'com o contador, aplica');

-- esvaziar e apagar uma natureza pela reclassificação
select pg_temp.como(:'analista');
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio)
values ('60000000-0000-0000-0000-000000000003', :'incorp', 'pedido', '10000000-0000-0000-0000-000000000007', 'Folders', '2026-04-01');
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('60000000-0000-0000-0000-000000000003', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.05'), 100);
select erp.pedir_reclassificacao(pg_temp.nat('05.01.05'), pg_temp.nat('05.01.04'), 'Juntar com agência', '{}', true) as r6 \gset
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(:'r6', true) = 'aprovada', 'aprovado o pedido de apagar');
select pg_temp.ok(pg_temp.nat('05.01.05') is null, 'a natureza esvaziada foi apagada');
select pg_temp.ok((select origem_nome from erp.reclassificacoes where id = :'r6') = 'Comerciais › Marketing › Produção de material',
  'o pedido guarda o nome da natureza apagada');
select pg_temp.ok((select natureza_id from erp.compromisso_rateios where compromisso_id = '60000000-0000-0000-0000-000000000003') = pg_temp.nat('05.01.04'),
  'o pedido de compra que usava a natureza apagada passou para o destino');

select pg_temp.ok((select count(*) from erp.auditoria where tabela = 'naturezas') > 0, 'mudanças na árvore ficam na auditoria');

\echo '# acesso pela API'
select pg_temp.como(null);
set role anon;
select pg_temp.falha($$select erp.fechar_mes('20000000-0000-0000-0000-000000000002', '2026-04-01')$$, 'chamada anônima não executa função do ERP');
select pg_temp.falha($$select count(*) from erp.lancamentos$$, 'chamada anônima não lê o livro');
reset role;
set role authenticated;
select pg_temp.falha($$select count(*) from erp.pessoas$$, 'usuário logado também não lê enquanto não houver permissões por papel');
reset role;
-- mesmo que alguém dê acesso por engano, sem usuário a API não passa nas checagens de papel
grant usage on schema erp to anon;
grant execute on function erp.exigir_diretor() to anon;
grant execute on function erp.sistema() to anon;
grant execute on function erp.eu() to anon;
grant execute on function erp.meu_papel() to anon;
grant select on erp.usuarios to anon;
set role anon;
select pg_temp.falha($$select erp.exigir_diretor()$$, 'sem usuário, anon não é tratado como rotina do sistema');
reset role;
revoke all on schema erp from anon;
revoke all on erp.usuarios from anon;
revoke execute on all functions in schema erp from anon;

-- função security definer chamada sem login: current_user vira o dono, mas não vira rotina do sistema
create function public.teste_definer() returns boolean language sql security definer as $$ select erp.sistema() $$;
grant execute on function public.teste_definer() to anon;
set role anon;
select pg_temp.ok(not public.teste_definer(), 'dentro de função security definer, chamada anônima continua sem passe de sistema');
reset role;
drop function public.teste_definer();
select pg_temp.ok(erp.sistema(), 'migration e rotina do servidor (sem login, fora dos papéis da API) passam');
grant usage on schema erp to service_role;
grant execute on function erp.sistema(), erp.eu() to service_role;
set role service_role;
select pg_temp.ok(erp.sistema(), 'chave de serviço (função do servidor pela API) passa como sistema');
reset role;
revoke all on schema erp from service_role;
revoke execute on all functions in schema erp from service_role;

-- catálogo: nenhum privilégio de public, anon, authenticated ou service_role em nada do esquema (pega migration futura).
-- service_role fica de fora (S-015): o projeto Supabase é compartilhado e a chave de serviço do monitor passaria como sistema.
select pg_temp.ok(not exists (
  select 1 from unnest(array['public','anon','authenticated','service_role']) r(papel)
  where (r.papel <> 'public' and has_schema_privilege(r.papel, 'erp', 'USAGE'))
     or exists (select 1 from information_schema.role_table_grants g
                where g.table_schema = 'erp' and g.grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role'))
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
                       lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where n.nspname = 'erp' and a.privilege_type = 'EXECUTE'
                  and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon','authenticated','service_role'))))
     or exists (select 1 from pg_namespace n, lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
                where n.nspname = 'erp' and a.grantee = 0)),
  'catálogo: o esquema `erp` não dá nenhum privilégio a public, anon, authenticated ou service_role');

\echo '# fim'
do $$ begin raise notice 'TODOS OS TESTES PASSARAM'; end $$;
