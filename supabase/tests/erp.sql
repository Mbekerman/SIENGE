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
-- erro com a mensagem exata (o falha aceita qualquer erro)
create function pg_temp.erro_igual(sqlcmd text, esperado text, msg text) returns void language plpgsql as $f$
begin
  begin execute sqlcmd; exception when others then
    if sqlerrm = esperado then raise notice 'ok  %', msg; return; end if;
    raise exception 'FALHOU: % (erro foi: %)', msg, sqlerrm;
  end;
  raise exception 'FALHOU: % (passou)', msg;
end $f$;
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

-- no teste, o login de cada um é o próprio id em texto (pg_temp.como põe o login na sessão)
insert into erp.usuarios (id, login_id, nome, papel, administrador, contador) values
  (:'diretor', :'diretor', 'Moises', 'diretor', true, false),
  (:'diretor2', :'diretor2', 'Sócia', 'diretor', false, false),
  (:'gestor', :'gestor', 'Paula', 'gestor', false, false),
  (:'analista', :'analista', 'Rafael', 'analista', false, false),
  (:'leitor', :'leitor', 'Consulta', 'leitura', false, false),
  (:'contador', :'contador', 'Contador', 'analista', false, true);

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
select pg_temp.erro_igual($$insert into erp.contas_bancarias (empresa_id, banco) values ('20000000-0000-0000-0000-000000000002', 'Itaú')$$,
  'Só o administrador pode mudar a configuração', 'analista não cadastra conta bancária da empresa (S-055)');
select pg_temp.como(:'diretor');
insert into erp.contas_bancarias (id, empresa_id, banco, agencia, conta) values
  ('50000000-0000-0000-0000-000000000001', :'spe', 'Itaú', '0001', '12345-6'),
  ('50000000-0000-0000-0000-000000000002', :'incorp', 'Itaú', '0001', '99999-0');
\set conta_spe '50000000-0000-0000-0000-000000000001'
\set conta_inc '50000000-0000-0000-0000-000000000002'
select pg_temp.como(:'analista');

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
-- outro núcleo da mesma SPE, com Marketing ligado
select current_setting('request.jwt.claim.sub', true) as quem_antes \gset
select pg_temp.como(:'diretor');
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome) values ('40000000-0000-0000-0000-000000000009', :'spe', 'outro', 'Loja');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values ('40000000-0000-0000-0000-000000000009', :'cc_mkt', true);
select pg_temp.como(nullif(:'quem_antes', ''));
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000009', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '109', '2026-02-05', '2026-02-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50),
  ('70000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-000000000002', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000003', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000009', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000004', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000005', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.02'), '2026-02-01', '2026-02-20', 1000),
  ('68000000-0000-0000-0000-000000000006', :'spe', 'manual', null, :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-02-01', '2026-02-20', 1000);
select pg_temp.erro_igual($$insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values ('68000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'manual', '10000000-0000-0000-0000-000000000005',
          '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '04.01'), '2026-02-01', '2026-02-20', 1000)$$,
  'O núcleo econômico é de outra empresa', 'previsão de outra empresa nem nasce no núcleo da SPE (S-056), então não casa');
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
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000001', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', '2026-02-20', 2000);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000001', :'p1', 2000);
select pg_temp.ok(erp.parcela_saldo(:'p1') = 2500, 'pagamento parcial: a parcela fica com saldo');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000002', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', '2026-02-25', 2530);
insert into erp.quitacoes (pagamento_id, parcela_id, principal, juros, multa) values ('80000000-0000-0000-0000-000000000002', :'p1', 2500, 10, 20);
select pg_temp.ok(erp.parcela_saldo(:'p1') = 0, 'segunda quitação zera a parcela; juros e multa entram só na hora de pagar');
select pg_temp.ok((select sum(valor) from erp.lancamentos where natureza_id = pg_temp.nat('08.01.02')) = -30,
  'juros e multa no livro, em Financeiras › Juros e multas pagos');
select pg_temp.falha($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000002',
  (select id from erp.parcelas where titulo_id = (select titulo_id from erp.parcelas where id = (select parcela_id from erp.quitacoes limit 1)) and numero = 2), 1)$$,
  'pagamento não quita mais do que o próprio valor');

-- adiantamento de 6.000 ao fornecedor, sem título: sai carimbado com núcleo e centro
select pg_temp.falha($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, data, valor) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005', '2026-03-01', 1)$$,
  'adiantamento sem núcleo e centro de custo não sai');
select pg_temp.falha($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, data, valor) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005',
   '40000000-0000-0000-0000-000000000001', '2026-03-01', 1)$$,
  'adiantamento só com núcleo, sem centro de custo, não sai');
select pg_temp.falha($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005',
   '40000000-0000-0000-0000-000000000001', (select id from erp.centros_custo where nome = 'Jurídico'), '2026-03-01', 1)$$,
  'adiantamento em centro desligado no núcleo não sai');
select pg_temp.falha($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005',
   '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000002', '2026-03-01', 1)$$,
  'adiantamento não usa núcleo de outra empresa');
begin;
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, data, valor)
select :'spe', :'conta_spe', pessoa_id, '2026-03-01', 1 from erp.empresas where id = :'spe';
select pg_temp.ok(true, 'transferência entre contas próprias dispensa o carimbo');
rollback;
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, compromisso_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000003', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005',
   '60000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_obra', '2026-03-01', 6000);
select pg_temp.ok((select nucleo_economico_id = :'ne_vm' and centro_custo_id = :'cc_obra' from erp.lancamentos
                   where pagamento_id = '80000000-0000-0000-0000-000000000003' and quitacao_id is null),
  'o adiantamento entra no livro já carimbado com núcleo e centro');
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
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'realizado' and natureza_id = pg_temp.nat('11.02')
                   and nucleo_economico_id = :'ne_vm' and centro_custo_id = :'cc_obra') = -1600,
  'o saldo de adiantamento fica no núcleo e no centro do carimbo');
select pg_temp.ok((select sum(valor) from erp.lancamentos where estagio = 'realizado' and empresa_id = :'spe')
                  = -(2000 + 2530 + 6000), 'o realizado do livro bate com o dinheiro que saiu do banco');
select pg_temp.falha($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003',
  (select id from erp.parcelas where titulo_id = (select id from erp.titulos where tipo = 'imposto')), 100)$$,
  'adiantamento de um fornecedor não paga título de outra pessoa');
-- adiantamento em aberto (80..03, lançado pelo analista, carimbado na Obra da Vila Maria):
-- só abate no mesmo núcleo e centro; fora dele, aprovado; regra configurável
select pg_temp.ok((select criado_por from erp.pagamentos where id = '80000000-0000-0000-0000-000000000003') = :'analista',
  'quem lançou o pagamento vem do servidor');
-- autor e hora vêm do servidor no INSERT e não mudam no UPDATE (erp.tg_autor)
begin;
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor, criado_por, criado_em)
values ('a1000000-0000-0000-0000-000000000001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005',
        '2026-03-01', '2026-03-01', 10, '00000000-0000-0000-0000-00000000000e', '2000-01-01');
select pg_temp.ok((select criado_por = :'diretor' and criado_em > now() - interval '1 day'
                   from erp.titulos where id = 'a1000000-0000-0000-0000-000000000001'),
  'título: criado_por e criado_em mandados por quem grava são ignorados');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, criado_por, criado_em)
values ('80000000-0000-0000-0000-0000000000a1', :'spe', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005',
        :'ne_vm', :'cc_obra', '2026-03-01', 1, '00000000-0000-0000-0000-00000000000e', '2000-01-01');
select pg_temp.ok((select criado_por = :'diretor' and criado_em > now() - interval '1 day'
                   from erp.pagamentos where id = '80000000-0000-0000-0000-0000000000a1'),
  'pagamento: criado_em no passado é ignorado (a ordem dos adiantamentos não depende do cliente)');
update erp.titulos set descricao = 'ok' where id = 'a1000000-0000-0000-0000-000000000001';
select pg_temp.ok((select descricao = 'ok' from erp.titulos where id = 'a1000000-0000-0000-0000-000000000001'),
  'título em rascunho continua editável');
do $$ begin
  update erp.titulos set criado_em = '2000-01-01' where id = 'a1000000-0000-0000-0000-000000000001';
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'Quem lançou e quando não mudam' then raise exception 'mudar criado_em: %', sqlerrm; end if;
end $$;
do $$ begin
  update erp.titulos set criado_por = '00000000-0000-0000-0000-00000000000e' where id = 'a1000000-0000-0000-0000-000000000001';
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'Quem lançou e quando não mudam' then raise exception 'mudar criado_por: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'título: mudar criado_por ou criado_em é recusado pelo erp.tg_autor');
rollback;
begin;
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.listas_financeiro (lista, user_id) values ('AD', '00000000-0000-0000-0000-00000000000b')$$,
  'quem não é administrador não se põe nas listas AF, AO e AD');
select pg_temp.falha($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, criado_por)
  values ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000005',
          '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', '2026-03-01', 1, '00000000-0000-0000-0000-00000000000e')
  returning case when criado_por = '00000000-0000-0000-0000-00000000000e' then 1/0 end$$,
  'quem grava não escolhe quem lançou o pagamento');
select pg_temp.como(:'diretor');
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AF', :'analista'), ('AF', :'contador'), ('AD', :'diretor2'), ('AD', :'diretor');
update erp.usuarios set ativo = false where id = :'contador';
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000007', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '107', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000007', array['2026-03-20']::date[]) as tit7 \gset
select id as p7 from erp.parcelas where titulo_id = :'tit7' \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000006', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '106', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000006', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000006', array['2026-03-20']::date[]) as tit6 \gset
select id as p6 from erp.parcelas where titulo_id = :'tit6' \gset
select pg_temp.falha(format($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', %L, 100)$$, :'p8'),
  'adiantamento de um centro de custo não abate título de outro centro sem aprovação');
select pg_temp.falha(format($$select erp.pagar_parcela(%L, '50000000-0000-0000-0000-000000000001', '2026-03-20')$$, :'p8'),
  'título do fornecedor com adiantamento em aberto não se paga com dinheiro novo');
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa) values ('80000000-0000-0000-0000-000000000003', %L, 'x')$$, :'tit8'),
  'quem não está em AF, AO ou AD não aprova abatimento em outro centro');
select pg_temp.falha($$update erp.regra_adiantamento set trava = false$$, 'só o administrador muda a regra do adiantamento');
select pg_temp.como(:'contador');
select pg_temp.falha(format($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa) values ('80000000-0000-0000-0000-000000000003', %L, 'x')$$, :'tit8'),
  'usuário inativo na lista não aprova');
select pg_temp.como(:'analista');
select pg_temp.falha(format($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa) values ('80000000-0000-0000-0000-000000000003', %L, 'x')$$, :'tit8'),
  'quem lançou o adiantamento não aprova o abatimento dele, mesmo estando na AF');
select pg_temp.como(:'gestor');
select pg_temp.falha(format($$insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (%L, 'x')$$, :'tit8'),
  'AF não libera pagar sem abater (padrão: só AD)');
select pg_temp.falha(format($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa) values ('80000000-0000-0000-0000-000000000003', %L, ' ')$$, :'tit8'),
  'aprovação de abatimento cruzado exige justificativa');
insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
values ('80000000-0000-0000-0000-000000000003', :'tit8', 'Adiantamento da obra usado no estande, combinado com o fornecedor');
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', :'p8', 100);
select pg_temp.ok(erp.parcela_saldo(:'p8') = 0, 'AF aprova e o adiantamento abate o título do outro centro');
select pg_temp.falha(format($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', %L, 100)$$, :'p7'),
  'a aprovação de um título não vale para outro título do mesmo centro');
select pg_temp.como(:'diretor');
-- adiantamento mais novo em aberto não impede usar o mais antigo; o mais antigo impede o mais novo
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000009', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', '2026-03-10', 300);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', :'p6', 100);
select pg_temp.ok(erp.parcela_saldo(:'p6') = 0, 'o adiantamento mais antigo abate mesmo com outro mais novo em aberto');
select pg_temp.falha(format($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000009', %L, 100)$$, :'p7'),
  'com um adiantamento mais antigo em aberto, o mais novo não abate antes dele');
select pg_temp.falha($$delete from erp.abatimentos_cruzados$$, 'aprovação de abatimento não se apaga');
select pg_temp.falha($$truncate erp.abatimentos_cruzados$$, 'aprovação de abatimento não se apaga nem por truncate');
select pg_temp.falha($$truncate erp.liberacoes_sem_abater$$, 'liberação não se apaga nem por truncate');
rollback;
begin;
select pg_temp.como(:'diretor');
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2'), ('AD', :'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
select pg_temp.falha(format($$insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (%L, 'x')$$, :'tit8'),
  'quem lançou o título não libera pagá-lo sem abater');
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (:'tit8', 'Adiantamento será usado na próxima medição');
select pg_temp.como(:'diretor');
select erp.pagar_parcela(:'p8', :'conta_spe', '2026-03-20') is not null as pagou \gset
select pg_temp.ok(:'pagou' and erp.parcela_saldo(:'p8') = 0, 'com a liberação da AD, o título se paga sem abater o adiantamento');
rollback;
begin;
select pg_temp.como(:'diretor');
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (:'tit8', 'Liberado antes do adiantamento novo');
select pg_temp.como(:'diretor');
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  (:'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', '2026-03-10', 300);
select pg_temp.falha(format($$select erp.pagar_parcela(%L, '50000000-0000-0000-0000-000000000001', '2026-03-20')$$, :'p8'),
  'adiantamento que aparece depois da liberação pede nova liberação');
rollback;
begin;
-- adiantamento do mesmo fornecedor em outra empresa não trava o título desta
select pg_temp.como(:'diretor');
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  (:'incorp', :'conta_inc', '10000000-0000-0000-0000-000000000007', :'ne_corp', :'cc_mkt', '2026-03-01', 500);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000005', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '105', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000005', array['2026-03-20']::date[]) as tit5 \gset
select id as p5 from erp.parcelas where titulo_id = :'tit5' \gset
select erp.pagar_parcela(:'p5', :'conta_spe', '2026-03-20') is not null as pagou \gset
select pg_temp.ok(:'pagou', 'adiantamento do fornecedor em outra empresa não trava o pagamento nesta');
rollback;
begin;
select pg_temp.como(:'diretor');
update erp.regra_adiantamento set trava = false;
select pg_temp.ok((select count(*) from erp.auditoria where tabela = 'regra_adiantamento') = 1, 'mudança na regra do adiantamento fica na auditoria');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', :'p8', 100);
select pg_temp.ok(erp.parcela_saldo(:'p8') = 0, 'com a trava desligada pelo administrador, o abatimento cruzado passa');
rollback;
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
update erp.usuarios set administrador = true where id = :'gestor';
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
grant execute on function erp.exigir_diretor(), erp.sistema(), erp.eu(), erp.meu_papel(), erp.login_atual() to anon;
set role anon;
do $$ begin
  perform erp.exigir_diretor();
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'Só a diretoria pode fazer isso' then raise exception 'anon: %', sqlerrm; end if;
end $$;
select pg_temp.ok(not erp.sistema(), 'sem usuário, anon não é tratado como rotina do sistema (e cai na checagem de papel)');
reset role;
revoke all on schema erp from anon;
revoke execute on all functions in schema erp from anon;

-- função security definer chamada sem login: current_user vira o dono, mas não vira rotina do sistema
create function public.teste_definer() returns boolean language sql security definer as $$ select erp.sistema() $$;
grant execute on function public.teste_definer() to anon;
set role anon;
select pg_temp.ok(not public.teste_definer(), 'dentro de função security definer, chamada anônima continua sem passe de sistema');
reset role;
drop function public.teste_definer();
select pg_temp.ok(erp.sistema(), 'migration e cron (sessão do dono do esquema, sem login e sem SET ROLE) passam');

-- S-033: só o papel nosso erp_sistema, sem login, é sistema; nenhum outro papel sem login
grant usage on schema erp to service_role;
grant execute on function erp.sistema(), erp.login_atual() to service_role;
set role service_role;
select pg_temp.ok(not erp.sistema(), 'a chave de serviço do Supabase não é sistema');
reset role;
revoke all on schema erp from service_role;
revoke execute on all functions in schema erp from service_role;
begin;
create role erp_teste_outro nologin;
grant usage on schema erp to erp_teste_outro;
grant execute on function erp.sistema(), erp.login_atual() to erp_teste_outro;
set local role erp_teste_outro;
select pg_temp.ok(not erp.sistema(), 'outro papel sem login (de qualquer provedor) não é sistema');
reset role;
set local role erp_sistema;
select pg_temp.ok(erp.sistema(), 'o papel erp_sistema, sem login, é sistema');
select pg_temp.como(:'diretor');
select pg_temp.ok(not erp.sistema(), 'erp_sistema com login na sessão não é sistema: vale o usuário');
select pg_temp.como(null);
reset role;
select pg_temp.como(:'diretor');
select pg_temp.ok(not erp.sistema(), 'o dono do esquema com login na sessão não é sistema');
select pg_temp.como(null);
rollback;
-- erp.eu() resolve pelo login do provedor, não pelo id
begin;
insert into erp.usuarios (id, login_id, nome, papel) values ('00000000-0000-0000-0000-0000000000a1', 'google-oauth2|123', 'Novo', 'analista');
select pg_temp.como('google-oauth2|123');
select pg_temp.ok(erp.eu() = '00000000-0000-0000-0000-0000000000a1', 'erp.eu() acha o usuário pelo login_id');
select pg_temp.como('login-sem-cadastro');
select pg_temp.ok(erp.eu() is null and not erp.sistema(), 'login sem cadastro não é usuário nem sistema');
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', '{"sub":"google-oauth2|123"}', false);
select pg_temp.ok(erp.eu() = '00000000-0000-0000-0000-0000000000a1', 'erp.eu() também lê o sub de request.jwt.claims');
select set_config('request.jwt.claims', '', false);
rollback;

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

-- S-003: RLS ligado e forçado em toda tabela, nenhuma política que libere tudo.
select pg_temp.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'erp' and c.relkind in ('r', 'p') and not (c.relrowsecurity and c.relforcerowsecurity)),
  'catálogo: toda tabela do `erp` tem RLS ligado e forçado');
select pg_temp.ok((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'erp' and c.relkind in ('r', 'p')) >= 47,
  'catálogo: a conferência do RLS achou as tabelas do esquema');
select pg_temp.ok(not exists (
  select 1 from pg_policies where schemaname = 'erp'
  and not (policyname = 'conferencia' and cmd = 'SELECT' and roles = '{erp_conferencia}')
  and not (policyname = 'operacao' and roles::text[] @> '{erp_situacao,erp_reclassificacao}' and cardinality(roles) = 2)
  and not (policyname = 'auditoria_grava' and tablename = 'auditoria' and cmd = 'INSERT' and roles = '{erp_auditoria}')
  and (coalesce(qual, '') ~* '^\(?\s*true\s*\)?$' or coalesce(with_check, '') ~* '^\(?\s*true\s*\)?$')),
  'catálogo: nenhuma política do `erp` é using(true) ou with check(true), fora a leitura do erp_conferencia');
-- S-035: as variáveis de sessão antigas não abrem nada; só a operação do banco muda situação e natureza
begin;
select pg_temp.como(:'analista');
set local erp.sistema = 'on';
set local erp.reclassificando = 'on';
set local erp.sistema_apaga = 'on';
do $$ begin
  update erp.titulos set situacao = 'quitado' where id = (select id from erp.titulos where situacao = 'aberto' limit 1);
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'A situação do título muda pelas quitações' then raise exception 'situação do título: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-035: SET erp.sistema não deixa mudar a situação do título');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('a1000000-0000-0000-0000-000000000035', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-01', '2026-03-01', 10);
do $$ begin
  update erp.titulos set situacao = 'aberto' where id = 'a1000000-0000-0000-0000-000000000035';
  if not found then raise exception 'sem título em rascunho'; end if;
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'A situação do título muda pelas quitações' then raise exception 'rascunho: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-035: título em rascunho não vira aberto à mão (sem os lançamentos do confirmar)');
do $$ begin
  update erp.previsoes set situacao = 'consumida' where id = (select id from erp.previsoes where situacao = 'aberta' limit 1);
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'A previsão só pode ser cancelada; ela é consumida pelos títulos' then raise exception 'situação da previsão: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-035: SET erp.sistema não deixa consumir a previsão à mão');
do $$ begin
  update erp.lancamentos set natureza_id = natureza_id where id = (select id from erp.lancamentos limit 1);
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'O livro não muda; a natureza só muda pela reclassificação' then raise exception 'livro: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-035: SET erp.reclassificando não deixa mudar o livro');
do $$ begin
  perform erp.exigir_admin();
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'Só o administrador pode mudar a configuração' then raise exception 'admin: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-035: SET erp.sistema_apaga não faz do analista administrador');
select pg_temp.ok(not erp.agindo_como('erp_situacao') and not erp.agindo_como('erp_reclassificacao'),
  'S-035: fora das operações do banco, não há marca');
rollback;
-- S-036: a situação da nota só muda pelo lançamento; título, nota e previsão nascem no estado inicial
begin;
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.documentos_fiscais set situacao = 'rascunho' where situacao = 'lancado'$$,
  'A situação do documento muda pelo lançamento', 'S-036: nota lançada não volta a rascunho');
select pg_temp.erro_igual($$update erp.documentos_fiscais set situacao = 'cancelado' where situacao = 'lancado'$$,
  'A situação do documento muda pelo lançamento', 'S-036: nota lançada não se cancela por UPDATE direto');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000036', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '136', '2026-03-05', '2026-03-01', 100);
select pg_temp.erro_igual($$update erp.documentos_fiscais set situacao = 'lancado' where id = '70000000-0000-0000-0000-000000000036'$$,
  'A situação do documento muda pelo lançamento', 'S-036: nota em rascunho não vira lançada sem o lancar_documento');
select pg_temp.erro_igual($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto, situacao)
  values ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000005', 'nfse', '137', '2026-03-05', '2026-03-01', 100, 'lancado')$$,
  'Documento nasce em rascunho; é lançado pelo lancar_documento', 'S-036: nota não nasce lançada');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor, situacao)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-01', '2026-03-01', 10, 'aberto')$$,
  'Título nasce em rascunho; é aberto pelo confirmar_titulo', 'S-036: título não nasce aberto (sem os lançamentos do confirmar)');
select pg_temp.erro_igual($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor, situacao)
  values ('20000000-0000-0000-0000-000000000003', 'manual', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001',
          (select id from erp.naturezas where codigo = '04.01'), '2026-03-01', '2026-03-20', 10, 'consumida')$$,
  'Previsão nasce aberta', 'S-036: previsão não nasce consumida');
rollback;
-- S-037: o pedido de reclassificação e suas linhas só mudam pelas funções dele
begin;
select pg_temp.como(:'analista');
select set_config('teste.rc37', erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'teste S-037')::text, true);
select pg_temp.ok((select situacao from erp.reclassificacoes where id = current_setting('teste.rc37')::uuid) = 'pendente',
  'S-037: pedir_reclassificacao continua gravando o pedido');
select pg_temp.como(:'diretor');
select pg_temp.falha($$update erp.reclassificacoes set situacao = 'aprovada' where id = current_setting('teste.rc37')::uuid$$,
  'S-037: pedido não se aprova por UPDATE direto');
select pg_temp.ok((select situacao from erp.reclassificacoes where id = current_setting('teste.rc37')::uuid) = 'pendente', 'S-037: continua pendente');
do $$ begin
  update erp.reclassificacoes set nivel = 'gestor' where id = current_setting('teste.rc37')::uuid;
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'O pedido de reclassificação só muda pelas funções dele (pedir, decidir, cancelar)' then raise exception 'nível: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-037: o nível de aprovação do pedido não se baixa por UPDATE direto');
do $$ begin
  update erp.reclassificacoes set natureza_origem_id = null where id = current_setting('teste.rc37')::uuid;
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'O pedido de reclassificação só muda pelas funções dele (pedir, decidir, cancelar)' then raise exception 'origem: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-037: a natureza do pedido só some quando a natureza é apagada');
do $$ begin
  delete from erp.reclassificacao_itens where reclassificacao_id = current_setting('teste.rc37')::uuid;
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'O pedido de reclassificação só muda pelas funções dele (pedir, decidir, cancelar)' then raise exception 'itens: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-037: as linhas do pedido não se tiram por fora');
select pg_temp.falha($$delete from erp.reclassificacoes where id = current_setting('teste.rc37')::uuid$$, 'S-037: pedido não se apaga');
do $$ begin
  insert into erp.reclassificacao_votos (reclassificacao_id, user_id, como, aprovou)
  values (current_setting('teste.rc37')::uuid, '00000000-0000-0000-0000-00000000000f', 'diretor', true);
  raise exception 'passou';
exception when others then
  if sqlerrm <> 'O pedido de reclassificação só muda pelas funções dele (pedir, decidir, cancelar)' then raise exception 'voto: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-038: voto não se grava por fora (nem em nome de outra pessoa)');
select pg_temp.falha($$truncate erp.reclassificacoes cascade$$, 'S-037: pedidos não se apagam nem por truncate');
select pg_temp.como(:'analista');
select erp.cancelar_reclassificacao(current_setting('teste.rc37')::uuid);
select pg_temp.ok((select situacao from erp.reclassificacoes where id = current_setting('teste.rc37')::uuid) = 'cancelada',
  'S-037: quem pediu cancela pela função');
rollback;
-- consumir a previsão inteira (operação do banco, erp_situacao) continua funcionando
begin;
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-000000000035', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-03-01', '2026-03-20', 100);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000035', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '135', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000035', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000035', array['2026-03-20']::date[],
                            array['68000000-0000-0000-0000-000000000035']::uuid[]) is not null as lancou \gset
select pg_temp.ok((select situacao from erp.previsoes where id = '68000000-0000-0000-0000-000000000035') = 'consumida',
  'S-035: a nota que consome a previsão inteira a marca como consumida (pela operação do banco)');
rollback;
-- a reclassificação aplicada direto, sem o voto (fora do decidir_reclassificacao), cai na trava do livro
begin;
select pg_temp.como(:'analista');
select set_config('teste.rc', erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'aplicar sem voto')::text, true);
select pg_temp.ok((select count(*) from erp.reclassificacao_itens i join erp.lancamentos l on l.id = i.lancamento_id
                   where i.reclassificacao_id = current_setting('teste.rc')::uuid and l.natureza_id = pg_temp.nat('04.02')) > 0,
  'S-035: o pedido pendente tem linhas do livro na origem');
select pg_temp.como(:'diretor');
do $$ begin
  perform erp._aplicar_reclassificacao(current_setting('teste.rc')::uuid);
  raise exception 'passou';
exception when others then
  if sqlerrm not in ('O livro não muda; a natureza só muda pela reclassificação', 'A natureza da previsão só muda pela reclassificação',
                     'O título já foi confirmado; titulo_rateios não muda') then
    raise exception 'aplicar direto: %', sqlerrm;
  end if;
end $$;
select pg_temp.ok(true, 'S-035: chamar _aplicar_reclassificacao direto não muda o livro');
rollback;

-- nega por padrão: papel comum com SELECT, como usuário ou sem login, não vê nada; erp_sistema vê
begin;
create role erp_teste_rls nologin;
grant usage on schema erp to erp_teste_rls;
grant select on all tables in schema erp to erp_teste_rls;
grant execute on all functions in schema erp to erp_teste_rls;
select pg_temp.como(:'diretor');
set local role erp_teste_rls;
select pg_temp.ok((select count(*) from erp.empresas) = 0 and (select count(*) from erp.titulos) = 0
                  and (select count(*) from erp.pagamentos) = 0,
  'RLS nega por padrão: até o diretor, fora do sistema, não lê nada sem política de perfil');
reset role;
select pg_temp.como(null);
set local role erp_teste_rls;
select pg_temp.ok((select count(*) from erp.empresas) = 0, 'papel comum sem login não vira sistema e não lê (S-033)');
reset role;
set local role erp_sistema;
select pg_temp.ok((select count(*) from erp.empresas) > 0, 'a política do sistema deixa o erp_sistema sem login ler');
reset role;
rollback;

-- S-034: as travas enxergam o que quem lança não vê. Usuário comum (não superusuário) com uma
-- política provisória de teste: só vê pagamentos do centro Marketing, nenhuma quitação, nenhuma
-- previsão consumida, nem usuários, listas ou a regra. As demais tabelas ficam abertas ao papel de
-- teste para a quitação poder gravar.
begin;
create role erp_teste_perfil nologin;
grant usage on schema erp to erp_teste_perfil;
grant select, insert, update, delete on all tables in schema erp to erp_teste_perfil;
grant execute on all functions in schema erp to erp_teste_perfil;
do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'erp' and c.relkind in ('r', 'p')
             and c.relname not in ('pagamentos', 'quitacoes', 'titulo_previsoes', 'usuarios', 'listas_financeiro', 'regra_adiantamento') loop
    execute format('create policy teste on erp.%I for all to erp_teste_perfil using (true) with check (true)', t.relname);
  end loop;
end $$;
create policy teste_ver on erp.pagamentos for select to erp_teste_perfil using (centro_custo_id = '45000000-0000-0000-0000-000000000002');
create policy teste_mudar on erp.pagamentos for update to erp_teste_perfil using (centro_custo_id = '45000000-0000-0000-0000-000000000002');
create policy teste_gravar on erp.pagamentos for insert to erp_teste_perfil with check (true);
create policy teste_gravar on erp.quitacoes for insert to erp_teste_perfil with check (true);
-- o que um usuário com tudo à vista enxerga (aqui, superusuário)
select pg_temp.como(:'diretor');
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor');
select (select parcela_id from erp.quitacoes order by parcela_id limit 1) as qpar \gset
select (select previsao_id from erp.titulo_previsoes order by previsao_id limit 1) as qprev \gset
select erp.parcela_saldo(:'qpar') as ps, erp.pagamento_saldo('80000000-0000-0000-0000-000000000003') as gs,
       erp.previsao_saldo(:'qprev') as prs \gset
select pg_temp.ok(:'ps'::numeric < (select valor from erp.parcelas where id = :'qpar')
                  and :'prs'::numeric < (select valor from erp.previsoes where id = :'qprev') and :'gs'::numeric > 0,
  'S-034: há parcela com quitação, previsão consumida e adiantamento em aberto para conferir');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
select set_config('teste.p8', :'p8', true);
set local role erp_teste_perfil;
select pg_temp.ok(not exists (select 1 from erp.pagamentos where id = '80000000-0000-0000-0000-000000000003')
                  and not exists (select 1 from erp.quitacoes) and not exists (select 1 from erp.usuarios),
  'S-034: o usuário de teste não vê o adiantamento da Obra, as quitações nem os usuários');
select pg_temp.ok(erp.eu() = :'diretor' and erp.meu_papel() = 'diretor', 'S-034: erp.eu() e o papel são lidos por baixo do RLS');
select pg_temp.ok(erp.estou_nas_listas('{AD}') and (erp.regra_adiantamento_atual()).trava,
  'S-034: as listas e a regra do adiantamento são lidas por baixo do RLS');
select pg_temp.ok(erp.parcela_saldo(:'qpar') = :'ps'::numeric and erp.pagamento_saldo('80000000-0000-0000-0000-000000000003') = :'gs'::numeric
                  and erp.previsao_saldo(:'qprev') = :'prs'::numeric,
  'S-034: parcela_saldo, pagamento_saldo e previsao_saldo somam o que o usuário não vê');
do $$ begin
  perform erp.pagar_parcela(current_setting('teste.p8')::uuid, '50000000-0000-0000-0000-000000000001', '2026-03-20');
  raise exception 'passou';
exception when others then
  if sqlerrm not like 'O fornecedor tem adiantamento em aberto%' then raise exception 'trava: %', sqlerrm; end if;
end $$;
select pg_temp.ok(true, 'S-034: o adiantamento da Obra, que o usuário não vê, ainda barra pagar o título do Marketing');
reset role;
rollback;

-- catálogo: só o dono do esquema e papéis erp_* têm privilégio no `erp` (pega papel de qualquer provedor)
select pg_temp.ok(not exists (
  with dono as (select nspowner from pg_namespace where nspname = 'erp'),
  acl as (
    select a.grantee from pg_class c join pg_namespace n on n.oid = c.relnamespace,
           lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a where n.nspname = 'erp'
    union all
    select a.grantee from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
           lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where n.nspname = 'erp'
    union all
    select a.grantee from pg_namespace n, lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a where n.nspname = 'erp')
  select 1 from acl where grantee not in (select nspowner from dono)
    and (grantee = 0 or (select rolname from pg_roles where oid = grantee) not like 'erp\_%')),
  'catálogo: nenhum privilégio no `erp` para papel que não seja o dono ou erp_*');
-- catálogo: todo security definer do `erp` tem search_path fixo e é do erp_conferencia (não do superusuário)
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'erp' and p.prosecdef
    and (not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%' and c like '%pg\_temp')
         or p.proowner not in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole))),
  'catálogo: todo security definer do `erp` tem search_path fixo e é de erp_conferencia, erp_situacao ou erp_reclassificacao');
select pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'erp' and p.prosecdef) >= 37,
  'catálogo: as funções de conferência são security definer');
select pg_temp.ok((select count(*) = 5 and bool_and(not rolcanlogin and not rolsuper and not rolbypassrls) from pg_roles
                   where rolname in ('erp_sistema', 'erp_conferencia', 'erp_situacao', 'erp_reclassificacao', 'erp_auditoria'))
                  and not exists (select 1 from pg_auth_members
                                  where roleid in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole)),
  'catálogo: os papéis erp_* não entram, não ignoram RLS, e conferência, situação e reclassificação não têm membros');
select pg_temp.ok(not exists (
  select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid join pg_roles u on u.oid = m.member
  where r.rolname like 'erp\_%' and u.rolname in ('anon', 'authenticated', 'authenticator', 'service_role', 'public')),
  'catálogo: nenhum papel da API é membro de erp_sistema nem de outro papel erp_*');
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where n.nspname = 'erp' and p.prosecdef and a.privilege_type = 'EXECUTE'
    and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticated', 'authenticator', 'service_role')))),
  'catálogo: saldos e demais funções definer fora do EXECUTE de anon, authenticated, authenticator e service_role');
-- S-035: nenhuma variável de sessão serve de passe
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'erp' and (p.prosrc ~ 'current_setting\(\s*''erp\.' or p.prosrc ~ 'set_config\(\s*''erp\.')),
  'catálogo: nenhuma função do `erp` lê ou põe variável de sessão erp.* (S-035)');
select pg_temp.ok((select not prosecdef from pg_proc where oid = 'erp.agindo_como(text)'::regprocedure),
  'catálogo: erp.agindo_como é invoker (dentro de definer, current_user é o dono)');
select pg_temp.ok(not exists (
  select 1 from pg_policies where schemaname = 'erp' and policyname <> 'sistema'
    and not (policyname = 'conferencia' and cmd = 'SELECT' and roles = '{erp_conferencia}')
    and not (policyname = 'operacao' and cmd = 'ALL' and roles::text[] @> '{erp_situacao,erp_reclassificacao}' and cardinality(roles) = 2)
    and not (policyname = 'auditoria_grava' and tablename = 'auditoria' and cmd = 'INSERT' and roles = '{erp_auditoria}')),
  'catálogo: no `erp` só há as políticas sistema, conferencia e operacao (as de perfil entram com o grant a authenticated)');

-- S-051, S-052: caução, livro e auditoria só crescem, e só pelas operações do banco
begin;
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.caucao_movimentos), 'S-051: há extrato de caução para conferir');
select pg_temp.erro_igual($$update erp.caucao_movimentos set valor = valor * 1000$$,
  'O extrato da caução não se altera', 'S-051: retenção de caução não se infla por UPDATE');
select pg_temp.erro_igual($$delete from erp.caucao_movimentos$$,
  'O extrato da caução não se altera', 'S-051: extrato da caução não se apaga');
select pg_temp.erro_igual(format($$insert into erp.caucao_movimentos (compromisso_id, tipo, valor, documento_id)
  select compromisso_id, 'retencao', 900000, documento_id from erp.caucao_movimentos where tipo = 'retencao' limit 1$$),
  'A caução só se movimenta pelo lançamento da nota e pela liberação', 'S-051: retenção não entra por INSERT direto');
select pg_temp.erro_igual($$truncate erp.caucao_movimentos cascade$$, 'Esta tabela não se apaga', 'S-051: extrato da caução não se apaga por truncate');
-- mesmo dentro de uma operação, quem movimentou e quando o banco põe
set local role erp_situacao;
insert into erp.caucao_movimentos (id, compromisso_id, tipo, valor, documento_id, por, em)
select '7a000000-0000-0000-0000-000000000051', compromisso_id, 'retencao', 1, documento_id, '00000000-0000-0000-0000-00000000000e', '2000-01-01'
from erp.caucao_movimentos where tipo = 'retencao' limit 1;
reset role;
select pg_temp.ok((select por = :'diretor' and em > now() - interval '1 day' from erp.caucao_movimentos where id = '7a000000-0000-0000-0000-000000000051'),
  'S-051: quem movimentou a caução e quando, o banco grava (o valor mandado é ignorado)');
select pg_temp.erro_igual($$insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_caixa, valor)
  values ('realizado', '20000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001',
          (select id from erp.naturezas where codigo = '04.01'), '2026-03-01', '2026-03-01', 123456)$$,
  'O livro só recebe linhas pelas operações do sistema', 'S-052: linha sem origem não entra no livro por INSERT direto');
select pg_temp.erro_igual($$truncate erp.lancamentos cascade$$, 'Esta tabela não se apaga', 'S-052: o livro não se apaga por truncate');
select pg_temp.erro_igual($$insert into erp.auditoria (tabela, registro, acao, por) values ('pagamentos', 'x', 'insert', '00000000-0000-0000-0000-00000000000a')$$,
  'A auditoria só é escrita pelo sistema', 'S-052: auditoria não recebe linha por INSERT direto');
select pg_temp.erro_igual($$update erp.auditoria set por = null$$, 'A auditoria não se altera nem se apaga', 'S-052: auditoria não se altera');
select pg_temp.erro_igual($$delete from erp.auditoria$$, 'A auditoria não se altera nem se apaga', 'S-052: auditoria não se apaga');
select pg_temp.erro_igual($$truncate erp.auditoria$$, 'Esta tabela não se apaga', 'S-052: auditoria não se apaga por truncate');
select pg_temp.como(null);
set local role erp_sistema;
select pg_temp.erro_igual($$delete from erp.auditoria$$, 'A auditoria não se altera nem se apaga', 'S-052: nem o erp_sistema apaga a auditoria');
reset role;
select pg_temp.como(:'diretor');
update erp.regra_adiantamento set trava = false;
select pg_temp.ok((select por = :'diretor' and em > now() - interval '1 minute' from erp.auditoria order by id desc limit 1),
  'S-052: a auditoria grava quem fez e quando, pelo banco');
set local role erp_auditoria;
insert into erp.auditoria (tabela, registro, acao, por, em) values ('teste', 'S-052', 'insert', '00000000-0000-0000-0000-00000000000e', '2000-01-01');
reset role;
select pg_temp.ok((select por = :'diretor' and em > now() - interval '1 minute' from erp.auditoria where tabela = 'teste'),
  'S-052: nem o dono da auditoria escolhe quem fez nem quando');
rollback;
-- S-053: o mês só fecha e reabre pela diretoria, pelas funções
begin;
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$delete from erp.meses_fechados$$, 'O mês só fecha e reabre pela diretoria',
  'S-053: analista não reabre o mês apagando a linha');
select pg_temp.erro_igual(format($$select erp.reabrir_mes(%L, '2026-03-01')$$, :'incorp'), 'Só a diretoria pode fazer isso',
  'S-053: analista não reabre o mês pela função');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$insert into erp.meses_fechados (empresa_id, mes) values (%L, '2026-06-01')$$, :'incorp'),
  'O mês só fecha e reabre pela diretoria', 'S-053: mês não se fecha por INSERT direto, nem pela diretoria');
select pg_temp.erro_igual($$update erp.meses_fechados set fechado_por = null$$, 'Mês fechado não se altera',
  'S-053: mês fechado não se altera');
select erp.reabrir_mes(:'incorp', '2026-03-01');
select pg_temp.ok(not exists (select 1 from erp.meses_fechados where empresa_id = :'incorp' and mes = '2026-03-01'),
  'S-053: a diretoria reabre o mês pela função');
select erp.reabrir_mes(:'incorp', '2026-02-01');
select pg_temp.como(:'diretor2');
select erp.fechar_mes(:'incorp', '2026-02-01');
select pg_temp.ok((select fechado_por = :'diretor2' from erp.meses_fechados where empresa_id = :'incorp' and mes = '2026-02-01'),
  'S-053: quem fechou o mês fica gravado');
set local role erp_situacao;
insert into erp.meses_fechados (empresa_id, mes, fechado_por, fechado_em)
values ('20000000-0000-0000-0000-000000000002', '2026-03-01', '00000000-0000-0000-0000-00000000000b', '2000-01-01');
reset role;
select pg_temp.ok((select fechado_por = :'diretor2' and fechado_em > now() - interval '1 minute' from erp.meses_fechados
                   where empresa_id = :'incorp' and mes = '2026-03-01'),
  'S-053: quem fechou e quando, o banco grava (o valor mandado é ignorado)');
rollback;
-- S-054: a previsão só é consumida pelo lançamento da nota, e só a que casa com ela
begin;
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-000000000541', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-03-01', '2026-03-20', 100),
  ('68000000-0000-0000-0000-000000000542', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-03-01', '2026-03-20', 50);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000054', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '154', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000054', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select set_config('teste.t54', erp.lancar_documento('70000000-0000-0000-0000-000000000054', array['2026-03-20']::date[],
                  array['68000000-0000-0000-0000-000000000541']::uuid[])::text, true);
select pg_temp.erro_igual(format($$insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (%L, '68000000-0000-0000-0000-000000000542', 10)$$,
  current_setting('teste.t54')), 'A previsão só é consumida pelo lançamento da nota', 'S-054: previsão não se consome por INSERT direto');
set local role erp_situacao;
select pg_temp.erro_igual(format($$insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (%L, '68000000-0000-0000-0000-000000000542', 10)$$,
  current_setting('teste.t54')), 'A previsão não casa com a nota do título', 'S-054: nem por dentro a previsão de outro centro e natureza é consumida');
reset role;
select pg_temp.ok(erp.previsao_saldo('68000000-0000-0000-0000-000000000541') = 0 and erp.previsao_saldo('68000000-0000-0000-0000-000000000542') = 50,
  'S-054: o lançamento consome só a previsão que casa');
rollback;
-- S-055: configuração e cadastros sensíveis só pelo administrador, com auditoria; orçamento publicado não volta
begin;
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$update erp.usuarios set papel = 'diretor', administrador = true, contador = true where id = %L$$, :'analista'),
  'Só o administrador pode mudar a configuração', 'S-055: analista não se faz diretor, administrador nem contador');
select pg_temp.erro_igual($$update erp.naturezas_sistema set natureza_id = (select id from erp.naturezas where codigo = '04.01') where chave = 'adiantamentos'$$,
  'Só o administrador pode mudar a configuração', 'S-055: analista não troca a natureza de Adiantamentos');
select pg_temp.erro_igual($$update erp.niveis_aprovacao set peso = -peso$$,
  'Só o administrador pode mudar a configuração', 'S-055: analista não inverte os pesos das alçadas');
select pg_temp.erro_igual(format($$update erp.contas_bancarias set conta = '00000-0' where id = %L$$, :'conta_spe'),
  'Só o administrador pode mudar a configuração', 'S-055: analista não muda conta bancária');
select pg_temp.erro_igual(format($$insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'pessoas', %L, '999')$$, :'analista'),
  'Só o administrador pode mudar a configuração', 'S-055: analista não grava código externo');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$update erp.usuarios set administrador = false where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: nem o administrador muda o próprio acesso');
select pg_temp.erro_igual(format($$update erp.usuarios set login_id = 'outro' where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: nem o administrador muda o próprio login');
select pg_temp.erro_igual(format($$delete from erp.usuarios where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: o administrador não se apaga');
update erp.usuarios set nome = 'Moises B.' where id = :'diretor';
update erp.usuarios set papel = 'gestor' where id = :'analista';
select pg_temp.ok((select papel = 'gestor' from erp.usuarios where id = :'analista')
                  and exists (select 1 from erp.auditoria where tabela = 'usuarios' and registro = :'analista' and por = :'diretor'),
  'S-055: o administrador muda o papel de outra pessoa, e fica na auditoria');
select pg_temp.erro_igual($$update erp.orcamento_versoes set situacao = 'rascunho' where id = '90000000-0000-0000-0000-000000000001'$$,
  'A situação do orçamento só muda pela publicação', 'S-055: orçamento vigente não volta a rascunho');
select pg_temp.erro_igual($$update erp.orcamento_versoes set nome = 'outro' where id = '90000000-0000-0000-0000-000000000001'$$,
  'Versão de orçamento vigente não muda; crie uma reprojeção', 'S-055: orçamento vigente não se edita');
select pg_temp.erro_igual($$delete from erp.orcamento_versoes where id = '90000000-0000-0000-0000-000000000001'$$,
  'Versão de orçamento vigente não se apaga', 'S-055: orçamento vigente não se apaga');
select pg_temp.erro_igual(format($$insert into erp.orcamento_versoes (empresa_id, tipo, nome, data_base, situacao) values (%L, 'aprovado', 'x', '2026-01-01', 'vigente')$$, :'spe'),
  'Versão de orçamento nasce em rascunho', 'S-055: orçamento não nasce vigente');
insert into erp.orcamento_versoes (id, empresa_id, tipo, nome, data_base, criada_por, criada_em)
values ('90000000-0000-0000-0000-000000000055', :'spe', 'aprovado', 'x', '2026-01-01', :'gestor', '2000-01-01');
select pg_temp.ok((select criada_por = :'diretor' and criada_em > now() - interval '1 minute' from erp.orcamento_versoes
                   where id = '90000000-0000-0000-0000-000000000055'),
  'S-055: quem criou o orçamento e quando, o banco grava');
update erp.orcamento_versoes set nome = 'Aprovado 2026' where id = '90000000-0000-0000-0000-000000000055';
select pg_temp.ok((select nome from erp.orcamento_versoes where id = '90000000-0000-0000-0000-000000000055') = 'Aprovado 2026',
  'S-055: rascunho continua editável');
rollback;
-- S-056: o núcleo é da empresa do registro, e a empresa do registro não muda
begin;
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-000000000561', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '561', '2026-03-05', '2026-03-01', 100),
  ('70000000-0000-0000-0000-000000000562', :'incorp', '10000000-0000-0000-0000-000000000005', 'nfse', '562', '2026-03-05', '2026-03-01', 100);
select pg_temp.erro_igual($$insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('70000000-0000-0000-0000-000000000562', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '04.01'), 100)$$,
  'O núcleo econômico é de outra empresa', 'S-056: nota da Incorporadora não se rateia no núcleo da SPE');
insert into erp.documento_rateios (id, documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('71000000-0000-0000-0000-000000000561', '70000000-0000-0000-0000-000000000561', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select pg_temp.erro_igual($$update erp.documento_rateios set documento_id = '70000000-0000-0000-0000-000000000562' where id = '71000000-0000-0000-0000-000000000561'$$,
  'O núcleo econômico é de outra empresa', 'S-056: rateio não muda para nota de outra empresa');
select pg_temp.erro_igual($$update erp.documentos_fiscais set empresa_id = '20000000-0000-0000-0000-000000000002' where id = '70000000-0000-0000-0000-000000000561'$$,
  'A empresa do registro não muda; crie outro', 'S-056: a nota não muda de empresa depois de rateada');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('80000000-0000-0000-0000-000000000561', :'incorp', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-05', '2026-03-01', 100);
select pg_temp.erro_igual($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('80000000-0000-0000-0000-000000000561', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', (select id from erp.naturezas where codigo = '04.01'), 100)$$,
  'O núcleo econômico é de outra empresa', 'S-056: título da Incorporadora não se rateia no núcleo da SPE');
select pg_temp.erro_igual($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('60000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000002', (select id from erp.naturezas where codigo = '05.01.04'), 100)$$,
  'O núcleo econômico é de outra empresa', 'S-056: contrato da Incorporadora não se rateia no núcleo da SPE');
insert into erp.orcamento_versoes (id, empresa_id, tipo, nome, data_base) values ('90000000-0000-0000-0000-000000000561', :'spe', 'aprovado', 'x', '2026-01-01');
select pg_temp.erro_igual($$insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, valor)
  values ('90000000-0000-0000-0000-000000000561', '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000002', (select id from erp.naturezas where codigo = '05.01.04'), '2026-03-01', -1)$$,
  'O núcleo econômico é de outra empresa', 'S-056: orçamento da SPE não usa o núcleo da Incorporadora');
rollback;
-- S-057: de fora, só título avulso; filhos da nota lançada e do contrato com caução não mudam
begin;
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, documento_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'fornecedor', '10000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000001', '2026-02-05', '2026-02-01', 9000)$$,
  'De fora das operações só se cria título avulso, sem nota nem contrato', 'S-057: segundo título para a nota lançada não nasce');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, documento_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000001', '2026-02-05', '2026-02-01', 9000)$$,
  'De fora das operações só se cria título avulso, sem nota nem contrato', 'S-057: título avulso não aponta para nota');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, compromisso_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002', '2026-02-05', '2026-02-01', 9000)$$,
  'De fora das operações só se cria título avulso, sem nota nem contrato', 'S-057: título avulso não aponta para contrato');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('80000000-0000-0000-0000-000000000571', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-05', '2026-03-01', 100);
select pg_temp.erro_igual($$update erp.titulos set documento_id = '70000000-0000-0000-0000-000000000001' where id = '80000000-0000-0000-0000-000000000571'$$,
  'O título não muda de tipo, nota ou contrato', 'S-057: título avulso em rascunho não passa a apontar para a nota');
select pg_temp.erro_igual($$update erp.titulos set tipo = 'fornecedor' where id = '80000000-0000-0000-0000-000000000571'$$,
  'O título não muda de tipo, nota ou contrato', 'S-057: título avulso não muda de tipo');
select pg_temp.erro_igual($$update erp.titulo_rateios set titulo_id = '80000000-0000-0000-0000-000000000571'
  where titulo_id = (select id from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000001' and tipo = 'fornecedor')$$,
  'O título já foi confirmado; titulo_rateios não muda', 'S-057: rateio não sai do título confirmado para um rascunho');
select pg_temp.erro_igual($$update erp.documento_rateios set percentual = 50 where documento_id = '70000000-0000-0000-0000-000000000001'$$,
  'A nota já foi lançada; documento_rateios não muda', 'S-057: rateio da nota lançada não muda');
select pg_temp.erro_igual($$delete from erp.documento_retencoes where documento_id = '70000000-0000-0000-0000-000000000001'$$,
  'A nota já foi lançada; documento_retencoes não muda', 'S-057: retenção da nota lançada não se apaga');
select pg_temp.erro_igual($$insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
  values ('70000000-0000-0000-0000-000000000001', 'irrf', 150, '10000000-0000-0000-0000-000000000006', '2026-03-10')$$,
  'A nota já foi lançada; documento_retencoes não muda', 'S-057: nota lançada não ganha retenção');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000571', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '571', '2026-03-05', '2026-03-01', 100);
select pg_temp.erro_igual($$update erp.documento_rateios set documento_id = '70000000-0000-0000-0000-000000000571' where documento_id = '70000000-0000-0000-0000-000000000001'$$,
  'A nota já foi lançada; documento_rateios não muda', 'S-057: rateio não sai da nota lançada para um rascunho');
select pg_temp.ok(exists (select 1 from erp.caucao_movimentos where compromisso_id = '60000000-0000-0000-0000-000000000002'),
  'S-057: o contrato CT-1 tem caução retida');
select pg_temp.erro_igual($$update erp.compromisso_rateios set nucleo_economico_id = '40000000-0000-0000-0000-000000000001', centro_custo_id = '45000000-0000-0000-0000-000000000002'
  where compromisso_id = '60000000-0000-0000-0000-000000000002'$$,
  'O contrato já tem caução retida; o rateio não muda', 'S-057: rateio do contrato com caução retida não muda');
select pg_temp.erro_igual($$delete from erp.compromisso_rateios where compromisso_id = '60000000-0000-0000-0000-000000000002'$$,
  'O contrato já tem caução retida; o rateio não muda', 'S-057: rateio do contrato com caução retida não se apaga');
select pg_temp.erro_igual(format($$delete from erp.movimentos_societarios where id = %L$$, :'ms'),
  'Movimento entre sócios não se altera nem se apaga', 'S-057: movimento entre sócios não se apaga');
select pg_temp.erro_igual($$insert into erp.movimentos_societarios (tipo, pagadora_id, recebedora_id, data, valor, titulo_pagar_id, titulo_receber_id)
  select tipo, pagadora_id, recebedora_id, data, valor, titulo_pagar_id, titulo_receber_id from erp.movimentos_societarios limit 1$$,
  'O movimento entre sócios só se registra pelo registrar_movimento_societario', 'S-057: movimento entre sócios não entra por INSERT direto');
rollback;
-- S-058: cancelar e pedir reclassificação exigem cadastro no ERP
begin;
select pg_temp.como(:'analista');
select set_config('teste.rc58', erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'S-058')::text, true);
select pg_temp.como('login-de-outro-sistema');
select pg_temp.erro_igual(format($$select erp.cancelar_reclassificacao(%L)$$, current_setting('teste.rc58')),
  'Seu papel só permite consulta', 'S-058: login sem cadastro no ERP não cancela o pedido de ninguém');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select erp.cancelar_reclassificacao(%L)$$, current_setting('teste.rc58')),
  'Só quem pediu cancela, e só pedido pendente', 'S-058: outra pessoa não cancela o pedido');
select pg_temp.como(null);
select pg_temp.erro_igual(format($$select erp.cancelar_reclassificacao(%L)$$, current_setting('teste.rc58')),
  'Só quem pediu cancela, e só pedido pendente', 'S-058: nem o sistema cancela o pedido de alguém');
select pg_temp.erro_igual($$select erp.pedir_reclassificacao((select id from erp.naturezas where codigo = '04.02'), (select id from erp.naturezas where codigo = '04.03'), 'x')$$,
  'A reclassificação é pedida por quem tem cadastro no ERP', 'S-058: sem cadastro no ERP não se pede reclassificação');
select pg_temp.como(:'analista');
select erp.cancelar_reclassificacao(current_setting('teste.rc58')::uuid);
select pg_temp.ok((select situacao from erp.reclassificacoes where id = current_setting('teste.rc58')::uuid) = 'cancelada',
  'S-058: quem pediu cancela');
rollback;
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'erp' and p.prosrc ~* 'coalesce\s*\(\s*erp\.eu\(\)'),
  'catálogo: nenhuma função troca erp.eu() nulo por outro valor');
-- S-059: um teste por trava, com a mensagem exata
begin;
select pg_temp.como(:'diretor');
select id as tit101 from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000001' and tipo = 'fornecedor' \gset
-- livro
select pg_temp.erro_igual($$update erp.lancamentos set valor = valor * 2$$,
  'O livro não muda; a natureza só muda pela reclassificação', 'S-059: o livro não muda de valor');
set local role erp_reclassificacao;
select pg_temp.erro_igual($$update erp.lancamentos set valor = valor + 1 where id = (select min(id) from erp.lancamentos)$$,
  'A reclassificação só muda a natureza', 'S-059: nem a reclassificação muda outra coluna do livro');
reset role;
-- consumo de previsão
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-000000000591', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2026-03-01', '2026-03-20', 100);
set local role erp_situacao;
select pg_temp.erro_igual(format($$insert into erp.titulo_previsoes (titulo_id, previsao_id, valor)
  select %L, id, 1 from erp.previsoes where compromisso_id = '60000000-0000-0000-0000-000000000001' and situacao = 'aberta' limit 1$$, :'tit101'),
  'Previsão e título são de empresas diferentes', 'S-059: título não consome previsão de outra empresa');
select pg_temp.erro_igual(format($$insert into erp.titulo_previsoes (titulo_id, previsao_id, valor) values (%L, '68000000-0000-0000-0000-000000000591', 1000)$$, :'tit101'),
  'O consumo (1000.00) passa do saldo da previsão (100.00)', 'S-059: consumo não passa do saldo da previsão');
reset role;
-- previsão
select pg_temp.erro_igual($$update erp.previsoes set natureza_id = (select id from erp.naturezas where codigo = '04.02') where id = '68000000-0000-0000-0000-000000000591'$$,
  'A natureza da previsão só muda pela reclassificação', 'S-059: a natureza da previsão não muda por fora');
select pg_temp.erro_igual($$update erp.previsoes set valor = 200 where id = '68000000-0000-0000-0000-000000000591'$$,
  'Previsão não se edita; cancele e crie outra', 'S-059: previsão não se edita');
-- título, parcelas, rateio e quitação
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('80000000-0000-0000-0000-000000000591', :'incorp', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-05', '2026-03-01', 100),
  ('80000000-0000-0000-0000-000000000592', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-05', '2026-03-01', 100);
insert into erp.parcelas (id, titulo_id, numero, vencimento, valor) values
  ('81000000-0000-0000-0000-000000000591', '80000000-0000-0000-0000-000000000591', 1, '2026-03-20', 100),
  ('81000000-0000-0000-0000-000000000592', '80000000-0000-0000-0000-000000000592', 1, '2026-03-20', 50);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('80000000-0000-0000-0000-000000000591', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('80000000-0000-0000-0000-000000000592', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000592', 10)$$,
  'O título não está aberto', 'S-059: título em rascunho não se quita');
select pg_temp.erro_igual($$select erp.confirmar_titulo('80000000-0000-0000-0000-000000000592')$$,
  'As parcelas não somam o valor do título', 'S-059: parcelas precisam somar o título');
select erp.confirmar_titulo('80000000-0000-0000-0000-000000000591');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000591', 10)$$,
  'Pagamento e título são de empresas diferentes', 'S-059: pagamento da SPE não quita título da Incorporadora');
select pg_temp.erro_igual($$update erp.titulo_rateios set percentual = 50 where titulo_id = '80000000-0000-0000-0000-000000000591'$$,
  'O título já foi confirmado; titulo_rateios não muda', 'S-059: rateio de título confirmado não muda');
select pg_temp.erro_igual($$delete from erp.titulos where id = '80000000-0000-0000-0000-000000000591'$$,
  'Título confirmado não se apaga', 'S-059: título confirmado não se apaga');
-- pagamento
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor)
  values (%L, %L, '10000000-0000-0000-0000-000000000005', %L, %L, '2026-03-20', 10)$$, :'spe', :'conta_inc', :'ne_vm', :'cc_obra'),
  'A conta não é da empresa do pagamento', 'S-059: pagamento não sai de conta de outra empresa');
-- caução
select pg_temp.erro_igual(format($$select erp.liberar_caucao('60000000-0000-0000-0000-000000000002', %s, '2026-12-01')$$,
  erp.caucao_saldo('60000000-0000-0000-0000-000000000002') + 1),
  format('A caução do contrato tem só %s de saldo', erp.caucao_saldo('60000000-0000-0000-0000-000000000002')),
  'S-059: a caução não fica negativa');
select erp.caucao_saldo('60000000-0000-0000-0000-000000000002') as saldo_caucao \gset
set local role erp_situacao;
select pg_temp.erro_igual(format($$insert into erp.caucao_movimentos (compromisso_id, tipo, valor, titulo_id)
  values ('60000000-0000-0000-0000-000000000002', 'liberacao', %s, %L)$$, :'saldo_caucao'::numeric + 1, :'tit101'),
  format('A caução do contrato tem só %s de saldo', :'saldo_caucao'), 'S-059: nem por dentro a caução fica negativa');
reset role;
-- nota
select pg_temp.erro_igual($$delete from erp.documentos_fiscais where id = '70000000-0000-0000-0000-000000000001'$$,
  'Documento lançado não se apaga', 'S-059: nota lançada não se apaga');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000591', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '591', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000591', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-000000000591', 'iss', 150, '10000000-0000-0000-0000-000000000006', '2026-04-10');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000591', array['2026-03-20']::date[])$$,
  'Retenções e caução passam do valor da nota', 'S-059: retenções não passam do valor da nota');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000591', array['2026-03-20']::date[])$$,
  'Seu papel só permite consulta', 'S-059: leitura não lança nota');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = false where id = :'gestor';
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.meu_papel() is null, 'S-059: usuário inativo não tem papel');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000591', array['2026-03-20']::date[])$$,
  'Seu papel só permite consulta', 'S-059: usuário inativo não lança nota');
-- reclassificação
select pg_temp.como(:'diretor');
update erp.alcadas_reclassificacao set nivel = 'diretor_e_contador';
select pg_temp.como(:'analista');
select set_config('teste.rc59', erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'S-059')::text, true);
select pg_temp.erro_igual(format($$select erp.decidir_reclassificacao(%L, true)$$, current_setting('teste.rc59')),
  'Quem pediu a reclassificação não pode aprová-la', 'S-059: quem pediu não aprova');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(current_setting('teste.rc59')::uuid, true) = 'pendente',
  'S-059: diretoria e contador: o voto da diretoria sozinho deixa pendente');
select pg_temp.erro_igual(format($$select erp.decidir_reclassificacao(%L, true)$$, current_setting('teste.rc59')),
  'Você já votou neste pedido', 'S-059: ninguém vota duas vezes');
rollback;
-- ---------------------------------------------------------------------
\echo '# alçada de pagamento (piloto Marketing)'
begin;
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.alcadas_pagamento set ate = 1000000 where ate = 50000$$,
  'Só o administrador pode mudar a configuração', 'alçada: analista não muda as faixas');
select pg_temp.erro_igual(format($$insert into erp.centro_aprovadores values (%L, %L)$$, :'cc_mkt', :'analista'),
  'Só o administrador pode mudar a configuração', 'alçada: analista não se faz gestor da área');
select pg_temp.como(:'diretor');
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor');
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AF', :'contador'), ('AD', :'diretor2') on conflict do nothing;
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'centro_aprovadores'), 'alçada: gestor da área entra na auditoria');
select pg_temp.como(:'analista');
-- títulos avulsos de Marketing no mesmo mês, lançados pelo analista
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-02', '2026-05-01', 30000),
  ('82000000-0000-0000-0000-000000000002', :'incorp', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-03', '2026-05-01', 25000),
  ('82000000-0000-0000-0000-000000000003', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-04', '2026-05-01', 1000),
  ('82000000-0000-0000-0000-000000000004', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-04', '2026-05-01', 500);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000001', 1, '2026-05-20', 30000), ('82000000-0000-0000-0000-000000000002', 1, '2026-05-20', 25000),
  ('82000000-0000-0000-0000-000000000003', 1, '2026-05-20', 1000), ('82000000-0000-0000-0000-000000000004', 1, '2026-05-20', 500);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000002', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000003', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000004', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000001');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000002');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000003');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000004');
select pg_temp.ok((select etapas = '{AREA,AF}' and acumulado = 30000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000001'),
  'alçada: até 50 mil no mês do centro, gestor da área e AF');
select pg_temp.ok((select etapas = '{AREA,AF,AD}' and acumulado = 55000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000002'),
  'alçada: o título que passa dos 50 mil (somando o centro em todos os núcleos e empresas) vai ao AD');
select pg_temp.ok((select etapas = '{AREA,AF,AD}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000003'),
  'alçada: os títulos seguintes do mês também vão ao AD');
select pg_temp.ok(not exists (select 1 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000004'),
  'alçada: centro sem gestor aprovador (fora do piloto) não tem alçada');
select pg_temp.erro_igual($$insert into erp.titulo_aprovacoes (titulo_id, etapa, lista, aprovado, por) values ('82000000-0000-0000-0000-000000000001', 1, 'AREA', true, '00000000-0000-0000-0000-00000000000e')$$,
  'A alçada do título só se grava pela confirmação e pela aprovação', 'alçada: aprovação não entra por INSERT direto');
select pg_temp.erro_igual($$delete from erp.titulo_alcadas$$, 'A alçada do título não se altera nem se apaga', 'alçada: não se apaga');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('83000000-0000-0000-0000-000000000001', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', '2026-05-20', 31000);
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '83000000-0000-0000-0000-000000000001', id, 30000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000001'$$,
  'O título ainda não foi aprovado: falta AREA', 'alçada: não se paga antes da aprovação');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'alçada: quem lançou não aprova');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Esta etapa é do gestor da área', 'alçada: a primeira etapa é do gestor da área, nem a diretoria pula');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) = 'pendente', 'alçada: o gestor da área aprova a etapa dele');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Você já aprovou uma etapa deste título', 'alçada: a mesma pessoa não aprova duas etapas (o gestor também está no AF)');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Esta etapa é de quem está em AF', 'alçada: AF vem depois do gestor, em sequência');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) = 'aprovado', 'alçada: AF aprova e o título fica liberado');
select pg_temp.como(:'analista');
insert into erp.quitacoes (pagamento_id, parcela_id, principal)
select '83000000-0000-0000-0000-000000000001', id, 30000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000001';
select pg_temp.ok((select situacao from erp.titulos where id = '82000000-0000-0000-0000-000000000001') = 'quitado', 'alçada: aprovado, o título se paga');
-- acima dos 50 mil: gestor, AF e AD; o AD vê os títulos que formaram o acumulado
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000002', true);
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000002', true) = 'pendente', 'alçada: acima dos 50 mil, falta o AD');
select pg_temp.como(:'diretor2');
select pg_temp.ok((select array_agg(titulo_id order by titulo_id) from erp.titulos_do_acumulado('82000000-0000-0000-0000-000000000002'))
                  = array['82000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000002']::uuid[],
  'alçada: o AD consulta os títulos do mês que levaram o acumulado até este');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000002', true) = 'aprovado', 'alçada: AD aprova por último');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$select * from erp.titulos_do_acumulado('82000000-0000-0000-0000-000000000002')$$,
  'Só quem aprova o título vê o acumulado', 'alçada: quem não aprova não vê o acumulado');
-- recusa
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000003', false)$$,
  'Recusar exige justificativa', 'alçada: recusar exige justificativa');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000003', false, 'serviço não prestado') = 'recusado', 'alçada: o gestor recusa');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000003', true)$$,
  'O título foi recusado na alçada', 'alçada: recusado não segue para as próximas etapas');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '83000000-0000-0000-0000-000000000001', id, 1000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000003'$$,
  'O título foi recusado na alçada', 'alçada: recusado não se paga');
-- outro mês começa do zero; exatamente 50 mil ainda é a faixa de baixo
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000006', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-06-02', '2026-06-01', 20000),
  ('82000000-0000-0000-0000-000000000007', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-06-03', '2026-06-01', 30000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000006', 1, '2026-06-20', 20000), ('82000000-0000-0000-0000-000000000007', 1, '2026-06-20', 30000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000006', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000006');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000007');
select pg_temp.ok((select acumulado = 20000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000006'),
  'alçada: o acumulado é do mês; maio não conta em junho');
select pg_temp.ok((select acumulado = 50000 and etapas = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000007'),
  'alçada: chegar a 50 mil exatos ainda fica com gestor e AF');
-- modo do acumulado por empresa: a outra empresa não conta
select pg_temp.como(:'diretor');
update erp.regra_alcada_pagamento set acumulado = 'empresa_centro';
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000005', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000005', 1, '2026-05-20', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000005');
select pg_temp.ok((select acumulado = 31100 and etapas = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000005'),
  'alçada: somando só a empresa, a Incorporadora fica de fora (configurável)');
rollback;
select pg_temp.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'erp' and c.relkind in ('r', 'p')
    and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and (t.tgtype & 32) = 32 and (t.tgtype & 2) = 2)),
  'catálogo: toda tabela do `erp` recusa TRUNCATE');
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'erp' and p.prosecdef
    and p.proowner in ('erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole)
    and p.prosrc ~* '\mexecute\M'),
  'catálogo: nenhuma operação definer usa EXECUTE dinâmico');
select pg_temp.ok((select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'erp' and p.proowner = 'erp_auditoria'::regrole)
                  and has_table_privilege('erp_auditoria', 'erp.auditoria', 'INSERT')
                  and not has_table_privilege('erp_auditoria', 'erp.auditoria', 'UPDATE')
                  and not has_table_privilege('erp_auditoria', 'erp.auditoria', 'DELETE')
                  and not exists (select 1 from information_schema.role_table_grants
                                  where grantee = 'erp_auditoria' and table_schema = 'erp' and table_name <> 'auditoria'),
  'catálogo: erp_auditoria só é dono do tg_auditoria e só insere na auditoria');

\echo '# fim'
do $$ begin raise notice 'TODOS OS TESTES PASSARAM'; end $$;
