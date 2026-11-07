-- Núcleo do ERP BKM: carga inicial (linhas da DRE, árvore de naturezas, listas e atributos de BI).
-- Tudo aqui é dado, editável pelo administrador depois.

insert into nucleo.linhas_dre (codigo, nome, ordem) values
  ('receita_bruta', 'Receita bruta', 10),
  ('deducoes', 'Deduções', 20),
  ('custo_terreno', 'Custo do terreno', 30),
  ('custo_obra', 'Custo de obra', 40),
  ('despesas_comerciais', 'Despesas comerciais', 50),
  ('despesas_gerais', 'Despesas gerais', 60),
  ('taxas', 'Taxas de gestão', 70),
  ('resultado_financeiro', 'Resultado financeiro', 80),
  ('outras_receitas', 'Outras receitas', 90),
  ('outras_despesas', 'Outras despesas', 95),
  ('fora', 'Fora da DRE', 100);

-- Carga inicial da árvore de naturezas: rascunho v0 do doc (7/nov/2026), a ajustar pelo administrador.
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, redutora, ordem) values
  ('01', null, 'Receitas', 'operacional', 'receita_bruta', 'operacional', false, false, 1),
  ('02', null, 'Deduções', 'operacional', 'deducoes', 'operacional', false, true, 2),
  ('03', null, 'Terreno', 'operacional', 'custo_terreno', 'operacional', false, false, 3),
  ('04', null, 'Obras', 'operacional', 'custo_obra', 'operacional', false, false, 4),
  ('05', null, 'Comerciais', 'operacional', 'despesas_comerciais', 'operacional', false, false, 5),
  ('06', null, 'Gerais', 'operacional', 'despesas_gerais', 'operacional', false, false, 6),
  ('07', null, 'Taxas de gestão', 'operacional', 'taxas', 'operacional', false, false, 7),
  ('08', null, 'Financeiras', 'nao_operacional', 'resultado_financeiro', 'operacional', false, false, 8),
  ('09', null, 'Não operacionais', 'nao_operacional', 'outras_despesas', 'operacional', false, false, 9),
  ('10', null, 'Investimentos', 'movimentacao', 'fora', 'investimento', false, false, 10),
  ('11', null, 'Movimentações', 'movimentacao', 'fora', 'nenhuma', false, false, 11);
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '01.01', id, 'Venda de unidades', null, null, null, null, 1 from nucleo.naturezas where codigo = '01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '01.02', id, 'Permuta em unidades', null, null, 'nenhuma', null, 2 from nucleo.naturezas where codigo = '01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '01.03', id, 'Encargos de clientes', null, null, null, null, 3 from nucleo.naturezas where codigo = '01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '01.04', id, 'Outras receitas', 'nao_operacional', 'outras_receitas', null, null, 4 from nucleo.naturezas where codigo = '01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '02.01', id, 'Impostos sobre a receita', null, null, null, null, 1 from nucleo.naturezas where codigo = '02';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '02.02', id, 'Distratos e descontos', null, null, null, null, 2 from nucleo.naturezas where codigo = '02';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '03.01', id, 'Aquisição', null, null, null, null, 1 from nucleo.naturezas where codigo = '03';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '03.02', id, 'Impostos e registro', null, null, null, null, 2 from nucleo.naturezas where codigo = '03';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '03.03', id, 'Diligência', null, null, null, null, 3 from nucleo.naturezas where codigo = '03';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '03.04', id, 'Corretagem do terreno', null, null, null, null, 4 from nucleo.naturezas where codigo = '03';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '03.05', id, 'Manutenção do terreno', null, null, null, null, 5 from nucleo.naturezas where codigo = '03';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.01', id, 'Custo incidente', null, null, null, null, 1 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.02', id, 'Custo atípico', null, null, null, null, 2 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.03', id, 'Administração local', null, null, null, null, 3 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.04', id, 'Não incidente', null, null, null, null, 4 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.05', id, 'Projetos e aprovações', null, null, null, null, 5 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '04.06', id, 'Pós-obra', null, null, null, null, 6 from nucleo.naturezas where codigo = '04';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '05.01', id, 'Marketing', null, null, null, null, 1 from nucleo.naturezas where codigo = '05';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '05.01.01', id, 'Online', 1 from nucleo.naturezas where codigo = '05.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '05.01.02', id, 'Offline', 2 from nucleo.naturezas where codigo = '05.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '05.01.03', id, 'Ações e promoções', 3 from nucleo.naturezas where codigo = '05.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '05.01.04', id, 'Agência', 4 from nucleo.naturezas where codigo = '05.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '05.01.05', id, 'Produção de material', 5 from nucleo.naturezas where codigo = '05.01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '05.02', id, 'Ponto de venda', null, null, null, null, 2 from nucleo.naturezas where codigo = '05';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '05.03', id, 'Equipe comercial', null, null, null, null, 3 from nucleo.naturezas where codigo = '05';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '05.04', id, 'Corretagem', null, null, null, null, 4 from nucleo.naturezas where codigo = '05';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '05.05', id, 'Custos de repasse', null, null, null, null, 5 from nucleo.naturezas where codigo = '05';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.01', id, 'Incorporação', null, null, null, null, 1 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.02', id, 'Caixa (CEF)', null, null, null, null, 2 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.03', id, 'Pessoal', null, null, null, null, 3 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.04', id, 'Administrativo', null, null, null, null, 4 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.05', id, 'Serviços de terceiros', null, null, null, null, 5 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '06.06', id, 'Impostos e taxas', null, null, null, null, 6 from nucleo.naturezas where codigo = '06';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '07.01', id, 'Taxas internas do grupo', null, null, null, null, 1 from nucleo.naturezas where codigo = '07';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '08.01', id, 'Despesas financeiras', null, null, null, null, 1 from nucleo.naturezas where codigo = '08';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '08.01.01', id, 'Juros de financiamentos', 1 from nucleo.naturezas where codigo = '08.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '08.01.02', id, 'Juros e multas pagos', 2 from nucleo.naturezas where codigo = '08.01';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '08.01.03', id, 'Tarifas e IOF', 3 from nucleo.naturezas where codigo = '08.01';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '08.02', id, 'Receitas financeiras', null, null, null, null, 2 from nucleo.naturezas where codigo = '08';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '08.02.01', id, 'Rendimentos de aplicações', 1 from nucleo.naturezas where codigo = '08.02';
insert into nucleo.naturezas (codigo, mae_id, nome, ordem) select '08.02.02', id, 'Descontos obtidos', 2 from nucleo.naturezas where codigo = '08.02';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '08.03', id, 'Custo de capital', null, null, 'nenhuma', true, 3 from nucleo.naturezas where codigo = '08';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '09.01', id, 'Eventuais', null, null, null, null, 1 from nucleo.naturezas where codigo = '09';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '10.01', id, 'Bens da empresa', null, null, null, null, 1 from nucleo.naturezas where codigo = '10';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '11.01', id, 'Entre contas próprias', null, null, null, null, 1 from nucleo.naturezas where codigo = '11';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '11.02', id, 'Adiantamentos a fornecedores', null, null, 'operacional', null, 2 from nucleo.naturezas where codigo = '11';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '11.03', id, 'Financiamentos', null, null, 'financiamento', null, 3 from nucleo.naturezas where codigo = '11';
insert into nucleo.naturezas (codigo, mae_id, nome, tipo, linha_dre, linha_dfc, so_orcado, ordem) select '11.04', id, 'Entre sócios', null, null, 'financiamento', null, 4 from nucleo.naturezas where codigo = '11';

insert into nucleo.naturezas_sistema (chave, natureza_id)
select 'adiantamentos', id from nucleo.naturezas where codigo = '11.02'
union all select 'juros_multas', id from nucleo.naturezas where codigo = '08.01.02'
union all select 'descontos_obtidos', id from nucleo.naturezas where codigo = '08.02.02'
union all select 'entre_socios', id from nucleo.naturezas where codigo = '11.04';

insert into nucleo.fases (nome, ordem) values
  ('Terreno', 1), ('Aprovação de projetos', 2), ('Incorporação', 3), ('Lançamento', 4),
  ('Obra', 5), ('Pós-obra', 6), ('Corporativo', 9);

insert into nucleo.departamentos (nome) values
  ('Novos negócios'), ('Projetos'), ('Engenharia'), ('Comercial'), ('Marketing'),
  ('Financeiro'), ('Administrativo'), ('Jurídico'), ('Diretoria');

-- Atributos de BI do empreendimento (cidade e UF já são colunas do empreendimento).
insert into nucleo.atributos (codigo, nome, tipo) values
  ('praca', 'Praça', 'lista'),
  ('regional', 'Regional', 'lista'),
  ('linha_produto', 'Linha de produto', 'lista'),
  ('faixa_mcmv', 'Faixa MCMV', 'lista');
insert into nucleo.atributo_opcoes (atributo_id, valor, ordem)
select a.id, o.valor, o.ordem from nucleo.atributos a
join (values ('faixa_mcmv', 'Faixa 1', 1), ('faixa_mcmv', 'Faixa 2', 2), ('faixa_mcmv', 'Faixa 3', 3),
             ('faixa_mcmv', 'Faixa 4', 4), ('faixa_mcmv', 'Fora do MCMV', 5)) o(attr, valor, ordem)
  on o.attr = a.codigo;
