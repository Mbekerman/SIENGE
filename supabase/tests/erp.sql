-- Testes das regras do ERP BKM.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = warning;

-- Com login, a sessão age como o papel da API (authenticated), sob RLS e só com os grants dela;
-- sem login (null), é o dono do esquema sem SET ROLE, isto é, o sistema.
create function pg_temp.como(u text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce(u, ''), false),
            set_config('role', case when coalesce(u, '') = '' then 'none' else 'authenticated' end, false) $$;
-- como o dono do esquema, com o login posto: sem RLS e com todos os privilégios, mas os gatilhos
-- veem a pessoa (para testar a trava de tabela que a API nem alcança)
create function pg_temp.como_dono(u text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', coalesce(u, ''), false), set_config('role', 'none', false) $$;
create function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if not coalesce(cond,false) then raise exception 'FALHOU: %', msg; end if; raise notice 'ok  %', msg; end $$;
-- Barrado: dá erro, ou, num UPDATE ou DELETE, a RLS não deixa a linha ao alcance (nada muda).
create function pg_temp.falha(sqlcmd text, msg text) returns void language plpgsql as $$
declare n bigint;
begin
  begin execute sqlcmd; get diagnostics n = row_count;
  exception when others then raise notice 'ok  % (%)', msg, sqlerrm; return; end;
  if n = 0 and lower(ltrim(sqlcmd)) ~ '^(update|delete)' then raise notice 'ok  % (nada mudou)', msg; return; end if;
  raise exception 'FALHOU: esperava erro em %', msg;
end $$;
-- O mesmo comando como o dono do esquema com o login posto (sem o RLS e com todos os
-- privilégios, como as operações do banco): devolve o erro, ou nulo se passou (e desfaz).
-- Serve para testar o gatilho de tabela que a API nem alcança.
create function pg_temp.erro_como_dono(sqlcmd text) returns text language plpgsql as $f$
declare v_role text := current_setting('role'); v_err text;
begin
  perform set_config('role', 'none', false);
  begin
    begin execute sqlcmd; exception when others then v_err := sqlerrm; end;
    if v_err is null then raise exception 'passou_como_dono'; end if;
  exception when others then if sqlerrm <> 'passou_como_dono' then raise; end if;
  end;
  perform set_config('role', v_role, false);
  return v_err;
end $f$;
-- erro com a mensagem exata (o falha aceita qualquer erro). Se a API nem tem o privilégio, confere
-- também o gatilho, pelo dono.
create function pg_temp.erro_igual(sqlcmd text, esperado text, msg text) returns void language plpgsql as $f$
declare v text; n bigint;
begin
  begin execute sqlcmd; get diagnostics n = row_count; exception when others then
    if sqlerrm = esperado then raise notice 'ok  %', msg; return; end if;
    if sqlerrm like 'permission denied for %' then
      v := pg_temp.erro_como_dono(sqlcmd);
      if v = esperado then raise notice 'ok  % (a API não tem o privilégio; o gatilho também barra)', msg; return; end if;
      raise exception 'FALHOU: % (sem privilégio pela API, mas pelo dono o erro foi: %)', msg, coalesce(v, 'passou');
    end if;
    raise exception 'FALHOU: % (erro foi: %)', msg, sqlerrm;
  end;
  -- UPDATE ou DELETE em linha que a RLS deixa fora do alcance: nada muda; confere o gatilho pelo dono
  if n = 0 and lower(ltrim(sqlcmd)) ~ '^(update|delete)' then
    v := pg_temp.erro_como_dono(sqlcmd);
    if v = esperado then raise notice 'ok  % (a RLS deixa a linha fora do alcance; o gatilho também barra)', msg; return; end if;
    raise exception 'FALHOU: % (nada mudou pela API, mas pelo dono o erro foi: %)', msg, coalesce(v, 'passou');
  end if;
  raise exception 'FALHOU: % (passou)', msg;
end $f$;
-- tabelas de acesso só mudam por pedido aprovado; no preparo dos testes, grava como o sistema e volta
create function pg_temp.sis() returns void language sql as
  $$ select set_config('teste.antes', coalesce(current_setting('request.jwt.claim.sub', true), ''), false),
            set_config('request.jwt.claim.sub', '', false), set_config('role', 'none', false) $$;
create function pg_temp.volta() returns void language sql as
  $$ select pg_temp.como(nullif(current_setting('teste.antes', true), '')) $$;
-- As funções de acesso que recebem a pessoa não têm EXECUTE para a API (S-079); os testes delas
-- chamam pelo dono e voltam ao papel de antes.
create function pg_temp.dono_ini() returns text language plpgsql as
  $$ declare r text := current_setting('role'); begin perform set_config('role', 'none', false); return r; end $$;
create function pg_temp.acesso(u uuid, n uuid, c uuid, out ve_tudo boolean, out lanca boolean) language plpgsql as $$
declare r text := pg_temp.dono_ini();
begin select a.ve_tudo, a.lanca into ve_tudo, lanca from erp.acesso(u, n, c) a; perform set_config('role', r, false); end $$;
create function pg_temp.ve_linha(u uuid, n uuid, c uuid, nat uuid, autor uuid) returns boolean language plpgsql as $$
declare r text := pg_temp.dono_ini(); v boolean;
begin v := erp.ve_linha(u, n, c, nat, autor); perform set_config('role', r, false); return v; end $$;
create function pg_temp.lanca_linha(u uuid, n uuid, c uuid, nat uuid) returns boolean language plpgsql as $$
declare r text := pg_temp.dono_ini(); v boolean;
begin v := erp.lanca_linha(u, n, c, nat); perform set_config('role', r, false); return v; end $$;
create function pg_temp.natureza_liberada(u uuid, n uuid, c uuid, nat uuid) returns boolean language plpgsql as $$
declare r text := pg_temp.dono_ini(); v boolean;
begin v := erp.natureza_liberada(u, n, c, nat); perform set_config('role', r, false); return v; end $$;
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
\set ti       '00000000-0000-0000-0000-000000000011'
\set analista2 '00000000-0000-0000-0000-000000000013'

-- no teste, o login de cada um é o próprio id em texto (pg_temp.como põe o login na sessão)
insert into erp.usuarios (id, login_id, nome, papel, administrador, contador) values
  (:'diretor', :'diretor', 'Moises', 'diretor', false, false),   -- master: faz o que o administrador faz, sem ser administrador
  (:'ti', :'ti', 'TI', 'leitura', true, false),
  (:'diretor2', :'diretor2', 'Sócia', 'diretor', false, false),
  (:'gestor', :'gestor', 'Paula', 'gestor', false, false),
  (:'analista', :'analista', 'Rafael', 'analista', false, false),
  (:'leitor', :'leitor', 'Consulta', 'leitura', false, false),
  (:'contador', :'contador', 'Contador', 'analista', false, true),
  (:'analista2', :'analista2', 'Analista sem lista', 'analista', false, false);
insert into erp.master (user_id) values (:'diretor');   -- o master entra pelo sistema (implantação)
-- quem registra pagamento é o financeiro (S-091): o analista dos testes está na AO
insert into erp.listas_financeiro (lista, user_id) values ('AO', :'analista');

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
-- Perfil amplo dos testes de regra: todos lançam em todos os centros de todos os núcleos (o
-- master vê tudo). Os testes de quem vê e quem não vê tiram este perfil e montam os seus.
\set tudo 'a0000000-0000-0000-0000-0000000000ff'
insert into erp.perfis_modelo (id, nome) values (:'tudo', 'Tudo (testes)');
insert into erp.perfil_centros select :'tudo', id, 'lancador' from erp.centros_custo;
insert into erp.atribuicoes (user_id, perfil_id, escopo)
select u, :'tudo', 'todos' from unnest(array[:'diretor2', :'gestor', :'analista', :'leitor', :'contador', :'analista2']::uuid[]) u;
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
-- parcela 1 (4.500) paga em duas vezes; pagamento e quitações na mesma transação (o que sobra é adiantamento)
begin;
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000001', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', '2026-02-20', 2000);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000001', :'p1', 2000);
commit;
select pg_temp.ok(erp.parcela_saldo(:'p1') = 2500, 'pagamento parcial: a parcela fica com saldo');
begin;
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('80000000-0000-0000-0000-000000000002', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', '2026-02-25', 2530);
insert into erp.quitacoes (pagamento_id, parcela_id, principal, juros, multa) values ('80000000-0000-0000-0000-000000000002', :'p1', 2500, 10, 20);
commit;
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
select pg_temp.como(:'analista2');   -- lança em todos os centros, mas não está no financeiro
select pg_temp.falha(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, data, valor)
  select %L, %L, pessoa_id, '2026-03-01', 1 from erp.empresas where id = %L$$, :'spe', :'conta_spe', :'spe'),
  'pagamento sem núcleo e centro (transferência) não é de quem só lança no centro');
select pg_temp.falha(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor)
  select %L, %L, pessoa_id, %L, %L, '2026-03-01', 1 from erp.empresas where id = %L$$, :'spe', :'conta_spe', :'ne_vm', :'cc_obra', :'spe'),
  'S-091: quem não está no financeiro não registra pagamento, nem no centro onde lança');
select pg_temp.como(:'diretor');   -- o master (ou o financeiro: AF, AO, AD)
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, data, valor)
select :'spe', :'conta_spe', pessoa_id, '2026-03-01', 1 from erp.empresas where id = :'spe';
select pg_temp.ok(true, 'transferência entre contas próprias dispensa o carimbo');
rollback;
-- o adiantamento sai ligado ao pedido de adiantamento confirmado (S-061)
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000001', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000005', '2026-03-01', '2026-03-01', 6000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('81000000-0000-0000-0000-000000000001', 1, '2026-03-01', 6000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000001');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, compromisso_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('80000000-0000-0000-0000-000000000003', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005',
   '60000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_obra', '2026-03-01', 6000, '81000000-0000-0000-0000-000000000001');
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
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AF', :'analista'), ('AF', :'contador'), ('AD', :'diretor2'); select pg_temp.volta();
select pg_temp.como(null); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor') on conflict do nothing; select pg_temp.como(:'diretor');  -- o próprio acesso só pelo sistema
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
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2'); select pg_temp.volta();
select pg_temp.como(null); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor') on conflict do nothing; select pg_temp.como(:'diretor2');  -- o próprio acesso só pelo sistema
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000008', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '108', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000008', array['2026-03-20']::date[]) as tit8 \gset
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
select pg_temp.falha(format($$insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (%L, 'x')$$, :'tit8'),
  'quem lançou o título não libera pagá-lo sem abater');
select pg_temp.como(:'diretor');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (:'tit8', 'Adiantamento será usado na próxima medição');
select pg_temp.como(:'diretor');
select erp.pagar_parcela(:'p8', :'conta_spe', '2026-03-20') is not null as pagou \gset
select pg_temp.ok(:'pagou' and erp.parcela_saldo(:'p8') = 0, 'com a liberação da AD, o título se paga sem abater o adiantamento');
rollback;
begin;
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2'); select pg_temp.volta();
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
select current_setting('request.jwt.claim.sub', true) as quem_antes \gset
select pg_temp.como(:'analista2');
select pg_temp.erro_igual($$select erp.registrar_movimento_societario('aporte', '20000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000003', 1, '2026-02-01')$$,
  'Movimento entre sócios só pela diretoria ou pelo financeiro', 'movimento entre sócios: quem só lança nos centros não registra');
select pg_temp.como(:'diretor2');
select erp.registrar_movimento_societario('aporte', :'incorp', :'spe', 50000, '2026-02-01', 'Aporte inicial') as ms \gset
select pg_temp.ok((select count(*) from erp.titulos t join erp.movimentos_societarios m on t.id in (m.titulo_pagar_id, m.titulo_receber_id) where m.id = :'ms') = 2,
  'aporte vira par ligado: a pagar na incorporadora, a receber na SPE');
select pg_temp.ok((select sum(l.valor) from erp.lancamentos l join erp.movimentos_societarios m on l.titulo_id in (m.titulo_pagar_id, m.titulo_receber_id) where m.id = :'ms') = 0,
  'no consolidado do grupo o par se anula');
select pg_temp.como(nullif(:'quem_antes', ''));

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
select pg_temp.como(:'ti');
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
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_reclassificacao(:'r5', true) = 'pendente', 'só a diretoria não basta');
select pg_temp.falha(format($$select erp.decidir_reclassificacao(%L, true)$$, :'r5'), 'o diretor não vota de novo no lugar do contador');
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
-- S-045: login do Auth comum sem cadastro no ERP (outro sistema) lê zero linhas e não grava
select pg_temp.como('login-sem-cadastro');
select pg_temp.ok((select count(*) from erp.pessoas) = 0 and (select count(*) from erp.titulos) = 0
                  and (select count(*) from erp.usuarios) = 0 and (select count(*) from erp.lancamentos) = 0
                  and (select count(*) from erp.naturezas) = 0,
  'S-045: logado sem cadastro no ERP lê zero linhas');
select pg_temp.falha($$insert into erp.pessoas (tipo, nome, documento) values ('juridica', 'Intruso', '99999999000199')$$,
  'S-045: logado sem cadastro no ERP não cadastra');
select pg_temp.falha($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-03-01', '2026-03-01', 10)$$,
  'S-045: logado sem cadastro no ERP não lança título');
select pg_temp.como(null);
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

-- catálogo: nenhum privilégio de public, anon ou service_role em nada do esquema (pega migration futura).
-- service_role fica de fora (S-015): o projeto Supabase é compartilhado e a chave de serviço do monitor passaria como sistema.
select pg_temp.ok(not exists (
  select 1 from unnest(array['public','anon','service_role']) r(papel)
  where (r.papel <> 'public' and has_schema_privilege(r.papel, 'erp', 'USAGE'))
     or exists (select 1 from information_schema.role_table_grants g
                where g.table_schema = 'erp' and g.grantee in ('PUBLIC', 'anon', 'service_role'))
     or exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
                       lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                where n.nspname = 'erp' and a.privilege_type = 'EXECUTE'
                  and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon','service_role'))))
     or exists (select 1 from pg_namespace n, lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) a
                where n.nspname = 'erp' and a.grantee = 0)),
  'catálogo: o esquema `erp` não dá nenhum privilégio a public, anon ou service_role');
-- primeiro grant: authenticated só tem o que a migration _erp_api dá
select pg_temp.ok(not exists (select 1 from information_schema.role_table_grants g
                               where g.table_schema = 'erp' and g.grantee = 'authenticated'
                                 and g.privilege_type not in ('SELECT','INSERT','UPDATE','DELETE')),
  'catálogo: authenticated não tem TRUNCATE, REFERENCES nem TRIGGER em nada');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               where n.nspname = 'erp' and c.relkind in ('r','p')
                                 and has_table_privilege('authenticated', c.oid, 'INSERT,UPDATE,DELETE')
                                 and not exists (select 1 from pg_policies p where p.schemaname = 'erp' and p.tablename = c.relname
                                                  and p.policyname = 'perfil_inclui' and 'authenticated' = any(p.roles))),
  'catálogo: authenticated só grava em tabela com política de gravação por perfil');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               where n.nspname = 'erp' and c.relkind in ('r','p') and c.relname not in ('avisos_sucessao','eventos')
                                 and not exists (select 1 from pg_policies p where p.schemaname = 'erp' and p.tablename = c.relname
                                                  and p.policyname = 'perfil_le' and 'authenticated' = any(p.roles))),
  'catálogo: toda tabela tem a política de leitura por perfil (só os avisos da sucessão e os eventos ficam fora da API)');
select pg_temp.ok(not has_table_privilege('authenticated', 'erp.lancamentos', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.auditoria', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.caucao_movimentos', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.avisos_sucessao', 'SELECT,INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.eventos', 'SELECT,INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.mudancas_config', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.mudanca_config_votos', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.mudancas_acesso', 'INSERT,UPDATE,DELETE')
                  and not has_table_privilege('authenticated', 'erp.atribuicoes', 'INSERT,UPDATE,DELETE'),
  'catálogo: livro, auditoria, caução e acesso não têm gravação direta pela API');
-- EXECUTE: as invoker (rodam com o RLS de quem chama) e, das definer, só a lista abaixo
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and p.prosecdef and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     and p.proname not in (
       'eu','autor','meu_usuario','meu_papel','sou_master','membro','sou_admin','escrevo','financeiro','gere_acesso',
       'exigir_editor','exigir_diretor','estou_nas_listas','natureza_restrita','galhos_acima','natureza_em_uso',
       'vejo','lanco','aprovo_titulo','vejo_titulo','lanco_titulo','vejo_documento','lanco_documento','vejo_compromisso',
       'lanco_compromisso','vejo_previsao','vejo_pagamento','vejo_reclassificacao','vejo_sucessao',
       '_vejo_titulo','_lanco_titulo','_vejo_documento','_lanco_documento','_vejo_compromisso','_lanco_compromisso',
       '_vejo_pagamento','_lanco_pagamento',
       'previsao_saldo','parcela_saldo','pagamento_saldo',
       'regra_adiantamento_atual','autor_lancamento','abatimento_aprovado','adiantamento_anterior_em_aberto','centro_ligado',
       'checar_natureza','checar_centro','em_revisao','pode_ajustar','_ajustavel','_nota_ajustavel','_titulo_em_revisao_da_nota',
       'cadeia_titulo','conferir_ajuste','alcada_etapa','alcada_pendente','alcada_recusada','titulos_do_acumulado',
       'checar_competencia','_registrar_ajuste','recusar_so_sucessao','recusar_admin_aprovador','_beneficiarios_acesso',
       'confirmar_titulo','lancar_documento','liberar_caucao','publicar_orcamento','decidir_titulo','reenviar_titulo',
       'registrar_movimento_societario','fechar_mes','reabrir_mes','pedir_reclassificacao','decidir_reclassificacao',
       'cancelar_reclassificacao','pedir_mudanca_acesso','decidir_mudanca_acesso','cancelar_mudanca_acesso','passar_master',
       'pedir_sucessao_master','decidir_sucessao_master','vetar_sucessao_master','efetivar_sucessao_master',
       'pedir_mudanca_config','decidir_mudanca_config','cancelar_mudanca_config')),
  'catálogo: das funções security definer, authenticated só executa as da lista (RPCs e conferências de quem está logado)');
select pg_temp.ok(not has_function_privilege('authenticated', 'erp._aplicar_mudanca_acesso(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.gerar_avisos_sucessao()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.vetar_sucessao_por_link(text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._pagamento_saldo(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._aplicar_mudanca_config(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.registrar_evento(text, text, text, uuid, uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._executar_config(text, text, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._contexto_mudanca_config(text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._criar_titulo(uuid, text, text, uuid, uuid, uuid, date, date, numeric, date[], text, uuid, text)', 'EXECUTE'),
  'catálogo: o que aplica sem conferir, os saldos internos e as rotinas do servidor ficam sem EXECUTE para a API');
-- S-079: nenhuma função que recebe a pessoa (p_user) é executável pela API
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'erp' and 'p_user' = any(p.proargnames) and has_function_privilege('authenticated', p.oid, 'EXECUTE')
     -- estas só recusam (erro) o administrador e o só da sucessão, o que todo membro já lê em usuarios
     and p.proname not in ('recusar_admin_aprovador', 'recusar_so_sucessao')),
  'S-079: nenhuma função que devolve o acesso de uma pessoa dada tem EXECUTE para a API');
select pg_temp.ok((select bool_and(p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_conferencia')
                     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'erp' and p.proname in ('acesso','ve_linha','lanca_linha','natureza_liberada','atribuicoes_no_nucleo')),
  'S-079: as funções de acesso que recebem a pessoa são definer de erp_conferencia');
-- nenhum papel da API é membro de papel nosso (senão o login viraria sistema ou dono das operações)
select pg_temp.ok(not exists (
  select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid join pg_roles u on u.oid = m.member
   where r.rolname like 'erp\_%' and u.rolname in ('anon','authenticated','authenticator','service_role')),
  'catálogo: anon, authenticated, authenticator e service_role não são membros de nenhum papel erp_*');
select pg_temp.ok(not exists (
  select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid join pg_roles u on u.oid = m.member
   where r.rolname in ('anon','authenticated','authenticator','service_role') and u.rolname like 'erp\_%'),
  'catálogo: nenhum papel erp_* é membro de papel da API');

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
  and not (policyname = 'operacao' and roles::text[] @> '{erp_situacao,erp_reclassificacao,erp_acesso}' and cardinality(roles) = 3)
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
  -- pela API nem chega ao gatilho: o livro não tem UPDATE para authenticated
  if sqlerrm not in ('O livro não muda; a natureza só muda pela reclassificação', 'permission denied for table lancamentos') then
    raise exception 'livro: %', sqlerrm;
  end if;
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
-- pela API, a reclassificação nem tem gravação direta; daqui em diante, o gatilho, pelo dono
select pg_temp.como_dono(:'diretor');
select pg_temp.falha($$update erp.reclassificacoes set situacao = 'aprovada' where id = current_setting('teste.rc37')::uuid$$,
  'S-037: pedido não se aprova por UPDATE direto (nem pelo gatilho)');
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
select pg_temp.falha($$select erp._aplicar_reclassificacao(current_setting('teste.rc')::uuid)$$,
  'a função interna que aplica a reclassificação não tem EXECUTE para a API');
select pg_temp.como_dono(:'diretor');   -- e mesmo por dentro, sem o voto, a trava do livro barra
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
select pg_temp.como(null); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor') on conflict do nothing; select pg_temp.como(:'diretor');  -- o próprio acesso só pelo sistema
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
    and (grantee = 0 or (select rolname from pg_roles where oid = grantee) not like 'erp\_%')
    and (select rolname from pg_roles where oid = grantee) is distinct from 'authenticated'),
  'catálogo: nenhum privilégio no `erp` para papel que não seja o dono, erp_* ou authenticated (o usuário logado, sob RLS)');
-- catálogo: todo security definer do `erp` tem search_path fixo e é do erp_conferencia (não do superusuário)
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'erp' and p.prosecdef
    and (not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search\_path=%' and c like '%pg\_temp')
         or p.proowner not in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole, 'erp_acesso'::regrole, 'erp_config'::regrole, 'erp_eventos'::regrole))),
  'catálogo: todo security definer do `erp` tem search_path fixo e é de erp_conferencia, erp_situacao ou erp_reclassificacao');
select pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'erp' and p.prosecdef) >= 37,
  'catálogo: as funções de conferência são security definer');
select pg_temp.ok((select count(*) = 8 and bool_and(not rolcanlogin and not rolsuper and not rolbypassrls) from pg_roles
                   where rolname in ('erp_sistema', 'erp_conferencia', 'erp_situacao', 'erp_reclassificacao', 'erp_auditoria', 'erp_acesso',
                                     'erp_config', 'erp_eventos'))
                  and not exists (select 1 from pg_auth_members
                                  where roleid in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole, 'erp_acesso'::regrole,
                                                   'erp_config'::regrole, 'erp_eventos'::regrole)),
  'catálogo: os papéis erp_* não entram, não ignoram RLS, e conferência, situação e reclassificação não têm membros');
select pg_temp.ok(not exists (
  select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid join pg_roles u on u.oid = m.member
  where r.rolname like 'erp\_%' and u.rolname in ('anon', 'authenticated', 'authenticator', 'service_role', 'public')),
  'catálogo: nenhum papel da API é membro de erp_sistema nem de outro papel erp_*');
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
  where n.nspname = 'erp' and p.prosecdef and a.privilege_type = 'EXECUTE'
    and (a.grantee = 0 or a.grantee in (select oid from pg_roles where rolname in ('anon', 'authenticator', 'service_role')))),
  'catálogo: funções definer fora do EXECUTE de anon, authenticator e service_role (authenticated: só a lista)');
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
    and not (policyname = 'operacao' and cmd = 'ALL' and roles::text[] @> '{erp_situacao,erp_reclassificacao,erp_acesso}' and cardinality(roles) = 3)
    and not (policyname = 'auditoria_grava' and tablename = 'auditoria' and cmd = 'INSERT' and roles = '{erp_auditoria}')
    -- o pedido da configuração de dinheiro (só dentro das funções dele) e o registro dos eventos
    and not (policyname = 'config' and roles = '{erp_config}' and coalesce(qual, with_check) ~ 'agindo_como\(''erp_config''::text\)'
             and tablename in ('naturezas_sistema','niveis_aprovacao','alcadas_pagamento','alcadas_reclassificacao',
                               'regra_adiantamento','regra_alcada_pagamento','regras_ajuste','contas_bancarias',
                               'codigos_externos','aprovadores_config','regras_mudanca_config','mudancas_config',
                               'mudanca_config_votos','usuarios','auditoria')
             and (cmd = 'ALL' or (cmd = 'SELECT' and tablename in ('usuarios','auditoria'))))
    and not (policyname = 'eventos_grava' and tablename = 'eventos' and cmd = 'INSERT' and roles = '{erp_eventos}')
    and not (policyname in ('perfil_le', 'perfil_inclui', 'perfil_altera', 'perfil_apaga') and roles = '{authenticated}')),
  'catálogo: no `erp` só há as políticas sistema, conferencia, operacao e as de perfil, estas só para authenticated');

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
select pg_temp.erro_igual(format($$update erp.usuarios set papel = 'gestor' where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: nem o master muda o próprio papel');
select pg_temp.erro_igual(format($$update erp.usuarios set login_id = 'outro' where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: nem o master muda o próprio login');
select pg_temp.erro_igual(format($$delete from erp.usuarios where id = %L$$, :'diretor'),
  'Ninguém muda o próprio papel, acesso ou login', 'S-055: o master não se apaga');
update erp.usuarios set nome = 'Moises B.' where id = :'diretor';
update erp.usuarios set papel = 'gestor' where id = :'analista';
select pg_temp.ok((select papel = 'gestor' from erp.usuarios where id = :'analista')
                  and exists (select 1 from erp.auditoria where tabela = 'usuarios' and registro = :'analista' and por = :'diretor'),
  'S-055: o master muda o papel de outra pessoa na hora, e fica na auditoria');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$update erp.usuarios set papel = 'leitura' where id = %L$$, :'ti'),
  'Só o master cria e administra os administradores', 'S-081: o administrador não muda o próprio cadastro');
select pg_temp.erro_igual(format($$update erp.usuarios set papel = 'diretor' where id = %L$$, :'analista'),
  'Papel e contador só mudam por pedido aprovado (erp.pedir_mudanca_acesso)', 'S-081: o administrador não muda papel direto');
select pg_temp.erro_igual(format($$update erp.usuarios set contador = true where id = %L$$, :'analista'),
  'Papel e contador só mudam por pedido aprovado (erp.pedir_mudanca_acesso)', 'S-081: o administrador não muda contador direto');
select pg_temp.erro_igual(format($$update erp.usuarios set login_id = 'outro' where id = %L$$, :'gestor'),
  'Só o master muda o login ou a situação de um usuário', 'S-081: o administrador não troca o login de ninguém');
select pg_temp.erro_igual(format($$update erp.usuarios set ativo = false where id = %L$$, :'gestor'),
  'Só o master muda o login ou a situação de um usuário', 'S-081: o administrador não desativa ninguém');
select pg_temp.erro_igual(format($$delete from erp.usuarios where id = %L$$, :'leitor'),
  'Só o master apaga usuário', 'S-081: o administrador não apaga usuário');
update erp.usuarios set nome = 'Paula G.' where id = :'gestor';
select pg_temp.ok((select nome from erp.usuarios where id = :'gestor') = 'Paula G.', 'S-081: o administrador muda o nome de quem não é administrador');
select pg_temp.como(:'diretor');
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
  'De fora das operações só se cria título avulso ou pedido de adiantamento, sem nota nem contrato', 'S-057: segundo título para a nota lançada não nasce');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, documento_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000001', '2026-02-05', '2026-02-01', 9000)$$,
  'De fora das operações só se cria título avulso ou pedido de adiantamento, sem nota nem contrato', 'S-057: título avulso não aponta para nota');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, compromisso_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002', '2026-02-05', '2026-02-01', 9000)$$,
  'De fora das operações só se cria título avulso ou pedido de adiantamento, sem nota nem contrato', 'S-057: título avulso não aponta para contrato');
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
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_reclassificacao(current_setting('teste.rc59')::uuid, true) = 'pendente',
  'S-059: diretoria e contador: o voto da diretoria sozinho deixa pendente');
select pg_temp.erro_igual(format($$select erp.decidir_reclassificacao(%L, true)$$, current_setting('teste.rc59')),
  'Você já votou neste pedido', 'S-059: ninguém vota duas vezes');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(current_setting('teste.rc59')::uuid, true) = 'aprovada',
  'master: o voto do master basta na reclassificação, no lugar do contador');
select pg_temp.como(:'analista');
select set_config('teste.rc59b', erp.pedir_reclassificacao(pg_temp.nat('04.03'), pg_temp.nat('04.02'), 'S-059 volta')::text, true);
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_reclassificacao(current_setting('teste.rc59b')::uuid, true) = 'aprovada',
  'master: sozinho, o master aprova a reclassificação de diretoria e contador');
select set_config('teste.rc59c', erp.pedir_reclassificacao(pg_temp.nat('04.02'), pg_temp.nat('04.03'), 'S-059 do master')::text, true);
select pg_temp.ok(erp.decidir_reclassificacao(current_setting('teste.rc59c')::uuid, true) = 'aprovada',
  'master: o master aprova a reclassificação que ele mesmo pediu');
rollback;
-- ---------------------------------------------------------------------
\echo '# alçada de pagamento (piloto Marketing)'
begin;
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.alcadas_pagamento set ate = 1000000 where ate = 50000$$,
  'Só o administrador pode mudar a configuração', 'alçada: analista não muda as faixas');
select pg_temp.erro_igual(format($$insert into erp.centro_aprovadores values (%L, %L)$$, :'cc_mkt', :'analista'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'alçada: analista não se faz gestor da área');
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor'); select pg_temp.volta();
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AF', :'contador'), ('AD', :'diretor2') on conflict do nothing; select pg_temp.volta();
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
-- o próprio lançamento: o master aprova o dele; na AD, pessoa a pessoa (Moises, 7/nov e 14/11/2026)
savepoint proprio;
select pg_temp.como(:'diretor2');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000091', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 700);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000091', 1, '2026-05-20', 700);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values ('82000000-0000-0000-0000-000000000091', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000091');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('82000000-0000-0000-0000-000000000091', true);
select pg_temp.como(:'contador'); select erp.decidir_titulo('82000000-0000-0000-0000-000000000091', true);
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000091', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'próprio: na AD sem a marca, quem lançou não aprova');
select pg_temp.sis(); update erp.listas_financeiro set aprova_proprio = true where lista = 'AD' and user_id = :'diretor2'; select pg_temp.volta();
select erp.decidir_titulo('82000000-0000-0000-0000-000000000091', true) as r_p \gset
select pg_temp.ok(:'r_p' = 'aprovado' and (select proprio from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000091' and lista = 'AD'),
  'próprio: a AD com a marca aprova o próprio lançamento, marcado para o aviso');
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.listas_financeiro set aprova_proprio = true where lista = 'AF' and user_id = %L$$, :'gestor'),
  'new row for relation "listas_financeiro" violates check constraint "listas_financeiro_check"', 'próprio: só a AD tem a marca');
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000092', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 800);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000092', 1, '2026-05-20', 800);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values ('82000000-0000-0000-0000-000000000092', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000092');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000092', true) as r_p2 \gset
select pg_temp.ok(:'r_p2' = 'aprovado' and (select bool_and(proprio) from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000092'),
  'próprio: o master aprova o próprio lançamento, e todas as etapas de uma vez');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000092', 'x');
insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000092', 'x');
select pg_temp.ok(true, 'próprio: o master libera e aprova exceção do próprio lançamento');
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000091', 'x');
select pg_temp.ok(true, 'próprio: a AD com a marca libera o próprio título sem abater');
-- a marca vale só na etapa da AD: na do AF, quem lançou continua não aprovando
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'diretor2'); select pg_temp.volta();
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000093', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 900);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000093', 1, '2026-05-20', 900);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values ('82000000-0000-0000-0000-000000000093', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000093');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('82000000-0000-0000-0000-000000000093', true);
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000093', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'próprio: a marca da AD não vale na etapa do AF');
-- S-088: a marca da AD não vale numa aprovação cuja lista não tem a AD
select pg_temp.sis(); update erp.regra_alcada_pagamento set excecao_competencia = '{AF}'; select pg_temp.volta();
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000091', 'x')$$,
  'Quem lançou não aprova o próprio lançamento', 'S-088: sem a AD na lista, a marca da AD não aprova o próprio lançamento');
rollback to savepoint proprio;
select pg_temp.ok(not exists (select 1 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000004'),
  'alçada: centro sem gestor aprovador (fora do piloto) não tem alçada');
select pg_temp.erro_igual($$insert into erp.titulo_aprovacoes (titulo_id, etapa, lista, aprovado, por) values ('82000000-0000-0000-0000-000000000001', 1, 'AREA', true, '00000000-0000-0000-0000-00000000000e')$$,
  'A alçada do título só se grava pela confirmação e pela aprovação', 'alçada: aprovação não entra por INSERT direto');
select pg_temp.erro_igual($$delete from erp.titulo_alcadas$$, 'A alçada do título não se altera nem se apaga', 'alçada: não se apaga');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('83000000-0000-0000-0000-000000000001', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', '2026-05-20', 30000);
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '83000000-0000-0000-0000-000000000001', id, 30000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000001'$$,
  'O título ainda não foi aprovado: falta AREA', 'alçada: não se paga antes da aprovação');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'alçada: quem lançou não aprova');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Esta etapa é do gestor da área', 'alçada: a primeira etapa é do gestor da área, nem a diretoria pula');
savepoint so_master;
select pg_temp.como(:'diretor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) as r_m \gset
select pg_temp.ok(:'r_m' = 'aprovado' and erp.alcada_pendente('82000000-0000-0000-0000-000000000001') is null
                  and (select count(*) > 1 and bool_and(por = :'diretor'::uuid) from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000001'),
  'master: um voto do master aprova todas as etapas que faltam (gestor, AF, AD...)');
rollback to savepoint so_master;
select pg_temp.como(:'diretor2');
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
  'O título não está aberto', 'alçada: recusado é cancelado e não se paga');
select pg_temp.ok((select situacao = 'cancelado' and cancelamento = 'recusa' from erp.titulos where id = '82000000-0000-0000-0000-000000000003')
                  and pg_temp.livro('comprometido', '82000000-0000-0000-0000-000000000003') = 0,
  'alçada: recusado sai do comprometido do livro, por estorno');
select pg_temp.ok((select count(*) > 1 from erp.lancamentos where titulo_id = '82000000-0000-0000-0000-000000000003'),
  'alçada: o lançamento original fica no livro; o estorno é outra linha');
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
-- S-065 e S-066
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'leitor') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.regra_alcada_pagamento set acumulado = 'nucleo_centro'$$,
  'Só o administrador pode mudar a configuração', 'alçada: analista não muda o modo do acumulado');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$insert into erp.regra_alcada_pagamento (id) values (true)$$,
  'A regra da alçada de pagamento é uma só; altere os valores', 'alçada: a regra é uma linha só');
select pg_temp.sis();
select pg_temp.erro_igual(format($$delete from erp.centro_aprovadores where centro_custo_id = %L$$, :'cc_mkt'),
  'O centro tem títulos esperando o gestor da área; cadastre outro gestor antes', 'alçada: o último gestor não sai com título esperando por ele');
select pg_temp.volta();
-- o título 7 (junho) espera o gestor; o gestor aprova e o leitor, mesmo no AF, não aprova
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000007', true);
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000007', true)$$,
  'Seu papel só permite consulta', 'alçada: papel de leitura não aprova, nem estando no AF');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = false where id = :'gestor';
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000006', true)$$,
  'Seu papel só permite consulta', 'alçada: gestor inativo não aprova');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = true where id = :'gestor';
select pg_temp.ok((select titulos = array['82000000-0000-0000-0000-000000000006', '82000000-0000-0000-0000-000000000007']::uuid[]
                   from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000007'),
  'alçada: guarda os títulos que formaram o acumulado (a lista de quem aprova é a mesma da soma)');
-- rateio em dois centros com gestor: vale o maior acumulado
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_obra', :'diretor2'); select pg_temp.volta();
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000008', :'spe', 'avulso', '10000000-0000-0000-0000-000000000008', '2026-07-02', '2026-07-01', 60000),
  ('82000000-0000-0000-0000-000000000009', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-07-03', '2026-07-01', 1000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000008', 1, '2026-07-20', 60000), ('82000000-0000-0000-0000-000000000009', 1, '2026-07-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100),
  ('82000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50),
  ('82000000-0000-0000-0000-000000000009', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000008');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000009');
-- obra: 60000 + 500; o mesmo fornecedor soma a outra metade (500): 61000
select pg_temp.ok((select centro_custo_id = :'cc_obra' and acumulado = 61000 and etapas = '{AREA,AF,AD}'
                   from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000009'),
  'alçada: rateio em dois centros com gestor usa o de maior acumulado');
-- imposto retido não entra na alçada
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000650', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '650', '2026-07-05', '2026-07-01', 1000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000650', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-000000000650', 'iss', 50, '10000000-0000-0000-0000-000000000006', '2026-08-10');
select erp.lancar_documento('70000000-0000-0000-0000-000000000650', array['2026-07-20']::date[]) is not null as lancou \gset
select pg_temp.ok((select count(*) filter (where t.tipo = 'fornecedor') = 1 and count(*) filter (where t.tipo = 'imposto') = 0
                   from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id
                   where t.documento_id = '70000000-0000-0000-0000-000000000650'),
  'alçada: o título do fornecedor entra; o imposto retido não');
-- sem faixa que cubra o acumulado, o título não se confirma
select pg_temp.como(:'diretor');
delete from erp.alcadas_pagamento where ate is null;
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000010', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-08-02', '2026-08-01', 60000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000010', 1, '2026-08-20', 60000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000010', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.erro_igual($$select erp.confirmar_titulo('82000000-0000-0000-0000-000000000010')$$,
  'Não há alçada de pagamento configurada para 60000.00', 'alçada: sem faixa para o acumulado, o título não se confirma');
select pg_temp.como(:'diretor');
insert into erp.alcadas_pagamento (ate, etapas) values (null, '{AREA,AF,AD}');
select pg_temp.como(:'analista');
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
-- SPE em maio: 30000 + 100 em Marketing (o título 3, recusado, foi cancelado), mais 500 do mesmo fornecedor em Obra
select pg_temp.ok((select acumulado = 30600 and etapas = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000005'),
  'alçada: somando só a empresa, a Incorporadora fica de fora (configurável)');
-- S-063: o mesmo fornecedor soma (padrão); desligado, só o centro
select pg_temp.como(:'diretor');
update erp.regra_alcada_pagamento set soma_fornecedor = false;
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000011', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000011', 1, '2026-05-20', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000011', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000011');
select pg_temp.ok((select acumulado = 30200 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000011'),
  'alçada: sem somar o fornecedor, o que ele tem em Obra fica de fora (configurável)');
-- S-063: competência no máximo um mês antes ou depois da emissão, salvo exceção
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000012', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-02', '2026-07-01', 100),
  ('82000000-0000-0000-0000-000000000013', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-02', '2026-03-01', 100),
  ('82000000-0000-0000-0000-000000000014', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-31', '2026-04-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000012', 1, '2026-07-20', 100), ('82000000-0000-0000-0000-000000000013', 1, '2026-05-20', 100),
  ('82000000-0000-0000-0000-000000000014', 1, '2026-06-20', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000012', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000013', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000014', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.erro_igual($$select erp.confirmar_titulo('82000000-0000-0000-0000-000000000012')$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'competência: dois meses depois da emissão não se confirma');
select pg_temp.erro_igual($$select erp.confirmar_titulo('82000000-0000-0000-0000-000000000013')$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'competência: dois meses antes da emissão não se confirma');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000014');
select pg_temp.ok((select situacao = 'aberto' from erp.titulos where id = '82000000-0000-0000-0000-000000000014'),
  'competência: um mês antes da emissão ainda passa');
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000012', 'serviço de julho')$$,
  'Só quem está em AF, AD aprova isto', 'competência: fora das listas não aprova exceção');
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000012', 'serviço de julho')$$,
  'Quem lançou não aprova o próprio lançamento', 'competência: quem lançou não aprova a própria exceção');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000012', 'serviço de julho')$$,
  'Seu papel só permite consulta', 'competência: papel de leitura não aprova exceção, nem estando no AF');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000012', ' ')$$,
  'new row for relation "excecoes_competencia" violates check constraint "excecoes_competencia_justificativa_check"', 'competência: exceção exige justificativa');
insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000012', 'serviço de julho');
select pg_temp.erro_igual($$delete from erp.excecoes_competencia where titulo_id = '82000000-0000-0000-0000-000000000012'$$,
  'Exceção de competência não se altera nem se apaga', 'competência: a exceção não se apaga');
select pg_temp.como(:'analista');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000012');
select pg_temp.ok((select situacao = 'aberto' from erp.titulos where id = '82000000-0000-0000-0000-000000000012'),
  'competência: com a exceção aprovada, o título se confirma');
-- a nota também; a exceção vale só para a competência aprovada
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000651', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '651', '2026-07-05', '2026-09-01', 1000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000651', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000651', array['2026-09-20']::date[])$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'competência: a nota fora da janela não se lança');
select pg_temp.como(:'contador');
insert into erp.excecoes_competencia (documento_id, justificativa) values ('70000000-0000-0000-0000-000000000651', 'medição de setembro');
select pg_temp.como(:'analista');
update erp.documentos_fiscais set competencia = '2026-10-01' where id = '70000000-0000-0000-0000-000000000651';
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000651', array['2026-10-20']::date[])$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'competência: mudou a competência, a exceção não vale');
update erp.documentos_fiscais set competencia = '2026-09-01' where id = '70000000-0000-0000-0000-000000000651';
select pg_temp.ok(erp.lancar_documento('70000000-0000-0000-0000-000000000651', array['2026-09-20']::date[]) is not null,
  'competência: com a exceção da competência aprovada, a nota se lança');
-- S-067: a exceção é do registro, quem aprova e a competência vêm do servidor, o autor da nota não aprova
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000015', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-02', '2026-07-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000015', 1, '2026-07-20', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000015', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.erro_igual($$select erp.confirmar_titulo('82000000-0000-0000-0000-000000000015')$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'competência: a exceção de outro título não vale para este');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000652', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '652', '2026-07-05', '2026-09-01', 1000);
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (documento_id, justificativa) values ('70000000-0000-0000-0000-000000000652', 'medição')$$,
  'Quem lançou não aprova o próprio lançamento', 'competência: quem lançou a nota não aprova a exceção dela');
select pg_temp.como(:'contador');
insert into erp.excecoes_competencia (titulo_id, justificativa, aprovado_por, competencia)
values ('82000000-0000-0000-0000-000000000015', 'serviço de julho', :'diretor', '2026-05-01');
select pg_temp.ok((select aprovado_por = :'contador' and competencia = '2026-07-01' from erp.excecoes_competencia
                   where titulo_id = '82000000-0000-0000-0000-000000000015'),
  'competência: quem aprovou e a competência aprovada vêm do servidor');
-- S-061: adiantamento passa pela alçada e conta uma vez no acumulado
select pg_temp.como(:'diretor');
update erp.regra_alcada_pagamento set soma_fornecedor = true;
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000010', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000007', '2026-09-01', '2026-09-01', 20000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('81000000-0000-0000-0000-000000000010', 1, '2026-09-05', 20000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000010', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50),
  ('81000000-0000-0000-0000-000000000010', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50);
select pg_temp.erro_igual($$select erp.confirmar_titulo('81000000-0000-0000-0000-000000000010')$$,
  'O pedido de adiantamento tem um núcleo e um centro de custo só', 'adiantamento: o pedido tem um carimbo só');
delete from erp.titulo_rateios where titulo_id = '81000000-0000-0000-0000-000000000010' and centro_custo_id = :'cc_obra';
update erp.titulo_rateios set percentual = 100 where titulo_id = '81000000-0000-0000-0000-000000000010';
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000010');
-- setembro já tem a nota 651 (1.000) do mesmo fornecedor
select pg_temp.ok((select acumulado = 21000 and etapas = '{AREA,AF}' and centro_custo_id = :'cc_mkt'
                   from erp.titulo_alcadas where titulo_id = '81000000-0000-0000-0000-000000000010'),
  'adiantamento: o pedido entra na alçada pelo acumulado do centro');
select pg_temp.ok(not exists (select 1 from erp.lancamentos where titulo_id = '81000000-0000-0000-0000-000000000010'),
  'adiantamento: o pedido não compromete o livro; quem lança é o pagamento');
select pg_temp.erro_igual($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007',
   '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000002', '2026-09-05', 20000, '81000000-0000-0000-0000-000000000010')$$,
  'O título ainda não foi aprovado: falta AREA', 'adiantamento: o dinheiro não sai antes da aprovação');
-- a conferência roda no fim da transação; aqui, antecipada com SET CONSTRAINTS
select pg_temp.erro_igual($$do $x$ begin
  insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007',
   '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000002', '2026-09-05', 20000);
  set constraints erp.t_adiantamento_pedido immediate; end $x$ $$,
  'Adiantamento só sai ligado a um pedido de adiantamento aprovado na alçada', 'adiantamento: pagamento que sobra sem pedido não sai');
set constraints erp.t_adiantamento_pedido deferred;
select pg_temp.como(:'gestor');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000010', true);
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('81000000-0000-0000-0000-000000000010', true) = 'aprovado', 'adiantamento: gestor e AF aprovam o pedido');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000007', %L, %L, '2026-09-05', 100, '81000000-0000-0000-0000-000000000010')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_obra'),
  'O pagamento sai com o núcleo e o centro de custo do pedido de adiantamento', 'adiantamento: o pagamento sai com o carimbo do pedido');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000008', %L, %L, '2026-09-05', 100, '81000000-0000-0000-0000-000000000010')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_mkt'),
  'O pagamento é de outra empresa ou outro favorecido que o pedido de adiantamento', 'adiantamento: o pagamento vai para o favorecido do pedido');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000007', %L, %L, '2026-09-05', 100, '82000000-0000-0000-0000-000000000012')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_mkt'),
  'O pagamento não está ligado a um pedido de adiantamento', 'adiantamento: o pagamento só se liga a pedido de adiantamento');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('83000000-0000-0000-0000-000000000010', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', '2026-09-05', 15000, '81000000-0000-0000-0000-000000000010');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '83000000-0000-0000-0000-000000000010', id, 1 from erp.parcelas where titulo_id = '81000000-0000-0000-0000-000000000010'$$,
  'O pedido de adiantamento se paga pelo pagamento ligado a ele', 'adiantamento: a parcela do pedido não se quita');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000007', %L, %L, '2026-09-06', 6000, '81000000-0000-0000-0000-000000000010')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_mkt'),
  'O pagamento passa do valor do pedido de adiantamento (20000.00)', 'adiantamento: os pagamentos não passam do pedido');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('83000000-0000-0000-0000-000000000011', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', '2026-09-06', 5000, '81000000-0000-0000-0000-000000000010');
select pg_temp.ok((select situacao = 'quitado' from erp.titulos where id = '81000000-0000-0000-0000-000000000010'), 'adiantamento: pago por inteiro, o pedido fica quitado');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000007', %L, %L, '2026-09-07', 1, '81000000-0000-0000-0000-000000000010')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_mkt'),
  'O pedido de adiantamento não está aberto', 'adiantamento: pedido quitado não paga de novo');
-- a nota do mesmo fornecedor soma só o que passa do adiantamento pago
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000020', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-10', '2026-09-01', 25000),
  ('82000000-0000-0000-0000-000000000021', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-11', '2026-09-01', 10000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000020', 1, '2026-09-20', 25000), ('82000000-0000-0000-0000-000000000021', 1, '2026-09-20', 10000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000020', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000021', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000020');
select pg_temp.ok((select acumulado = 26000 and etapas = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000020'),
  'adiantamento: conta uma vez (1 mil da nota 651, 20 mil do pedido e só os 5 mil da nota que passam dele)');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000021');
select pg_temp.ok((select acumulado = 36000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000021'),
  'adiantamento: já usado para cobrir uma nota, não cobre a seguinte');
select pg_temp.como(:'gestor');
select pg_temp.ok((select valor_no_centro = 5000 and valor_total = 25000 from erp.titulos_do_acumulado('82000000-0000-0000-0000-000000000021')
                   where titulo_id = '82000000-0000-0000-0000-000000000020'),
  'adiantamento: quem aprova vê a parte da nota coberta pelo adiantamento');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$insert into erp.titulo_coberturas (rateio_id, adiantamento_id, valor)
  select id, '81000000-0000-0000-0000-000000000010', 1 from erp.titulo_rateios where titulo_id = '82000000-0000-0000-0000-000000000021'$$,
  'A alçada do título só se grava pela confirmação e pela aprovação', 'adiantamento: a cobertura só se grava pela confirmação');
-- pedido aprovado e ainda não pago não cobre nada
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000011', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000008', '2026-10-01', '2026-10-01', 10000),
  ('82000000-0000-0000-0000-000000000022', :'spe', 'avulso', '10000000-0000-0000-0000-000000000008', '2026-10-02', '2026-10-01', 10000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('81000000-0000-0000-0000-000000000011', 1, '2026-10-05', 10000), ('82000000-0000-0000-0000-000000000022', 1, '2026-10-20', 10000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000011', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000022', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000011');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000022');
select pg_temp.ok((select acumulado = 20000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000022'),
  'adiantamento: pedido ainda não pago não cobre a nota');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000011', false, 'sem contrato');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (%L, %L, '10000000-0000-0000-0000-000000000008', %L, %L, '2026-10-05', 100, '81000000-0000-0000-0000-000000000011')$$, :'spe', :'conta_spe', :'ne_vm', :'cc_mkt'),
  'O pedido de adiantamento não está aberto', 'adiantamento: pedido recusado é cancelado e não paga');
-- a transferência entre contas próprias passa a conferência (o 'passou' só vem depois dela)
select pg_temp.erro_igual(format($$do $x$ begin
  insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, data, valor)
  select %L, %L, pessoa_id, '2026-10-05', 1 from erp.empresas where id = %L;
  set constraints erp.t_adiantamento_pedido immediate; raise exception 'passou'; end $x$ $$, :'spe', :'conta_spe', :'spe'),
  'passou', 'adiantamento: transferência entre contas próprias não pede pedido');
select pg_temp.erro_igual(format($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  (%L, 'fornecedor', '10000000-0000-0000-0000-000000000008', '2026-11-01', '2026-11-01', 10)$$, :'spe'),
  'De fora das operações só se cria título avulso ou pedido de adiantamento, sem nota nem contrato', 'adiantamento: de fora, título de fornecedor sem nota não nasce');
-- o pedido também respeita a janela da competência
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000013', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000008', '2026-11-01', '2027-01-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('81000000-0000-0000-0000-000000000013', 1, '2026-11-05', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000013', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.erro_igual($$select erp.confirmar_titulo('81000000-0000-0000-0000-000000000013')$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD', 'adiantamento: o pedido fora da janela da competência não se confirma');
-- adiantamento pago na Obra não cobre a nota de Marketing do mesmo fornecedor
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000012', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000008', '2026-11-01', '2026-11-01', 5000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('81000000-0000-0000-0000-000000000012', 1, '2026-11-05', 5000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000012', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000012');
select pg_temp.como(:'diretor2');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000012', true);
select pg_temp.como(:'contador');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000012', true);
select pg_temp.como(:'analista');
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  (:'spe', :'conta_spe', '10000000-0000-0000-0000-000000000008', :'ne_vm', :'cc_obra', '2026-11-05', 5000, '81000000-0000-0000-0000-000000000012');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000023', :'spe', 'avulso', '10000000-0000-0000-0000-000000000008', '2026-11-02', '2026-11-01', 5000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000023', 1, '2026-11-20', 5000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000023', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000023');
-- 5.000 da nota + 5.000 do pedido (mesmo fornecedor) + 200 da caução usada com ele em novembro
select pg_temp.ok((select acumulado = 10200 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000023'),
  'adiantamento: só cobre nota do mesmo núcleo e centro do pedido');
-- S-069 e S-070, em dezembro, com o fornecedor 05: outro núcleo não cobre; a cobertura não passa da
-- linha; o que foi abatido num título sem cobertura já foi usado
select pg_temp.como(:'diretor');
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome) values ('40000000-0000-0000-0000-000000000019', :'spe', 'outro', 'Loja 2');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values ('40000000-0000-0000-0000-000000000019', :'cc_mkt', true);
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000020', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000005', '2026-12-01', '2026-12-01', 1000),
  ('81000000-0000-0000-0000-000000000021', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000005', '2026-12-01', '2026-12-01', 3000),
  ('82000000-0000-0000-0000-000000000030', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-12-01', '2026-12-01', 2000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('81000000-0000-0000-0000-000000000020', 1, '2026-12-02', 1000), ('81000000-0000-0000-0000-000000000021', 1, '2026-12-02', 3000),
  ('82000000-0000-0000-0000-000000000030', 1, '2026-12-20', 2000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000020', '40000000-0000-0000-0000-000000000019', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('81000000-0000-0000-0000-000000000021', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000030', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
-- o título 30 é confirmado antes de o adiantamento sair: fica sem cobertura
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000030');
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000020');
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000021');
select pg_temp.como(:'gestor');
select erp.decidir_titulo(x, true) from unnest(array['81000000-0000-0000-0000-000000000020', '81000000-0000-0000-0000-000000000021',
  '82000000-0000-0000-0000-000000000030']::uuid[]) x;
select pg_temp.como(:'contador');
select erp.decidir_titulo(x, true) from unnest(array['81000000-0000-0000-0000-000000000020', '81000000-0000-0000-0000-000000000021',
  '82000000-0000-0000-0000-000000000030']::uuid[]) x;
select pg_temp.como(:'analista');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('83000000-0000-0000-0000-000000000020', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000019', :'cc_mkt', '2026-12-02', 1000, '81000000-0000-0000-0000-000000000020'),
  ('83000000-0000-0000-0000-000000000021', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', '2026-12-02', 3000, '81000000-0000-0000-0000-000000000021');
-- 2.000 do adiantamento de 3.000 são abatidos no título 30, que não tinha cobertura (os adiantamentos
-- mais antigos do fornecedor ficam para depois, com a liberação do AD)
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000030', 'abater o de dezembro');
select pg_temp.como(:'analista');
insert into erp.quitacoes (pagamento_id, parcela_id, principal)
select '83000000-0000-0000-0000-000000000021', id, 2000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000030';
-- a nota 31 (5.000, no ne_vm) só tem 1.000 de cobertura: os 2.000 abatidos já foram usados e o da Loja 2 é de outro núcleo
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000031', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-12-03', '2026-12-01', 5000),
  ('82000000-0000-0000-0000-000000000032', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-12-03', '2026-12-01', 500);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000031', 1, '2026-12-20', 5000), ('82000000-0000-0000-0000-000000000032', 1, '2026-12-20', 500);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000031', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000032', '40000000-0000-0000-0000-000000000019', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000031');
select pg_temp.ok((select sum(c.valor) = 1000 and min(c.adiantamento_id::text) = '81000000-0000-0000-0000-000000000021'
                   from erp.titulo_coberturas c join erp.titulo_rateios tr on tr.id = c.rateio_id
                   where tr.titulo_id = '82000000-0000-0000-0000-000000000031'),
  'adiantamento: o abatido num título sem cobertura já foi usado, e pedido de outro núcleo não cobre');
-- dez/26: 2.000 + 1.000 + 3.000 + (5.000 − 1.000) = 10.000
select pg_temp.ok((select acumulado = 10000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000031'),
  'adiantamento: o acumulado desconta só a cobertura que houve');
-- a nota 32, na Loja 2, é coberta só até a própria parte (500 dos 1.000)
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000032');
select pg_temp.ok((select sum(c.valor) = 500 from erp.titulo_coberturas c join erp.titulo_rateios tr on tr.id = c.rateio_id
                   where tr.titulo_id = '82000000-0000-0000-0000-000000000032')
                  and (select acumulado = 10000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000032'),
  'adiantamento: a cobertura não passa da parte da linha');
-- título coberto e depois abatido pelo mesmo adiantamento consome uma vez só
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('81000000-0000-0000-0000-000000000022', :'spe', 'adiantamento', '10000000-0000-0000-0000-000000000005', '2026-12-04', '2026-12-01', 3000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('81000000-0000-0000-0000-000000000022', 1, '2026-12-05', 3000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('81000000-0000-0000-0000-000000000022', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('81000000-0000-0000-0000-000000000022');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000022', true);
select pg_temp.como(:'contador');
select erp.decidir_titulo('81000000-0000-0000-0000-000000000022', true);
select pg_temp.como(:'analista');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('83000000-0000-0000-0000-000000000022', :'spe', :'conta_spe', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', '2026-12-05', 3000, '81000000-0000-0000-0000-000000000022');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000033', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-12-06', '2026-12-01', 2000),
  ('82000000-0000-0000-0000-000000000034', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-12-07', '2026-12-01', 1000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('82000000-0000-0000-0000-000000000033', 1, '2026-12-20', 2000), ('82000000-0000-0000-0000-000000000034', 1, '2026-12-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000033', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('82000000-0000-0000-0000-000000000034', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000033');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000033', true);
select pg_temp.como(:'contador');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000033', true);
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000033', 'abater o de dezembro');
select pg_temp.como(:'analista');
insert into erp.quitacoes (pagamento_id, parcela_id, principal)
select '83000000-0000-0000-0000-000000000022', id, 2000 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000033';
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000034');
select pg_temp.ok((select sum(c.valor) = 1000 from erp.titulo_coberturas c join erp.titulo_rateios tr on tr.id = c.rateio_id
                   where tr.titulo_id = '82000000-0000-0000-0000-000000000034'),
  'adiantamento: título coberto e depois abatido pelo mesmo adiantamento não consome duas vezes');
-- revisão de título coberto: a volta nova cobre de novo, e só a cobertura da volta atual conta
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000034', false, 'conferir o valor', true);
select pg_temp.como(:'analista');
select erp.reenviar_titulo('82000000-0000-0000-0000-000000000034', 'valor conferido');
select pg_temp.ok((select erp.cobertura(tr.id) = 1000 from erp.titulo_rateios tr where tr.titulo_id = '82000000-0000-0000-0000-000000000034')
                  and (select sum(valor) = 2000 and count(distinct rodada) = 2 from erp.titulo_coberturas
                        where titulo_id = '82000000-0000-0000-0000-000000000034'),
  'revisão: a cobertura de outra volta não conta; a volta nova cobre o mesmo valor uma vez');
-- pedir revisão: o título fica aberto e no livro; quem lançou, o gestor da área ou o AF ajustam
-- qualquer coisa e reenviam; a alçada recomeça do zero numa volta nova
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor, descricao) values
  ('82000000-0000-0000-0000-000000000040', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2027-01-04', '2027-01-01', 1000, 'campanha');
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000040', 1, '2027-01-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000040', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000040');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', false, 'trocar a natureza', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'revisão: quem lançou não pede revisão do próprio título');
select pg_temp.erro_igual($$update erp.titulos set valor = 1200 where id = '82000000-0000-0000-0000-000000000040'$$,
  'Título confirmado não se edita', 'revisão: sem pedido de revisão, o título não se edita');
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', 'x')$$,
  'O título não está em revisão', 'revisão: sem pedido de revisão, não há reenvio');
select pg_temp.erro_igual($$insert into erp.titulo_revisoes (titulo_id, rodada, etapa, motivo, pedida_por)
  values ('82000000-0000-0000-0000-000000000040', 1, 1, 'x', '00000000-0000-0000-0000-00000000000e')$$,
  'A revisão do título só se grava pela aprovação e pelo reenvio', 'revisão: o pedido só se grava pela aprovação');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true) = 'pendente', 'revisão: o gestor aprova a etapa dele');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', false, ' ', true)$$,
  'Pedir revisão exige o motivo', 'revisão: pedir revisão exige o motivo');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000040', false, 'o valor é 1.200 e a natureza é 05.01.02', true) = 'revisao',
  'revisão: o AF pede revisão');
select pg_temp.ok(erp.em_revisao('82000000-0000-0000-0000-000000000040')
                  and (select situacao = 'aberto' from erp.titulos where id = '82000000-0000-0000-0000-000000000040')
                  and pg_temp.livro('comprometido', '82000000-0000-0000-0000-000000000040') = -1000,
  'revisão: o título continua aberto e no livro');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true)$$,
  'O título está em revisão; aguarde o ajuste de quem lançou', 'revisão: em revisão, ninguém aprova');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '83000000-0000-0000-0000-000000000001', id, 1 from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000040'$$,
  'O título está em revisão', 'revisão: em revisão, não se paga');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$update erp.titulos set valor = 1200 where id = '82000000-0000-0000-0000-000000000040'$$,
  'Título confirmado não se edita', 'revisão: quem não lançou, não é gestor da área nem AF não ajusta');
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', 'feito')$$,
  'Quem reenvia é quem lançou, o gestor da área ou o AF', 'revisão: nem reenvia');
-- o AF ajusta tudo: valor, parcela, vencimento, natureza e observação
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$update erp.titulos set empresa_id = '20000000-0000-0000-0000-000000000001' where id = '82000000-0000-0000-0000-000000000040'$$,
  'A empresa do registro não muda; crie outro', 'revisão: a empresa do título não muda no ajuste');
update erp.titulos set valor = 1200, descricao = 'campanha de janeiro' where id = '82000000-0000-0000-0000-000000000040';
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', 'valor corrigido')$$,
  'As parcelas não somam o valor do título', 'revisão: o reenvio confere o título como a confirmação');
update erp.parcelas set valor = 1200, vencimento = '2027-01-25' where titulo_id = '82000000-0000-0000-0000-000000000040';
update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.02') where titulo_id = '82000000-0000-0000-0000-000000000040';
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', '')$$,
  'Reenviar exige a resposta ao pedido', 'revisão: reenviar exige a resposta');
select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', 'valor e natureza corrigidos');
select pg_temp.ok(not erp.em_revisao('82000000-0000-0000-0000-000000000040')
                  and (select rodada = 2 from erp.titulos where id = '82000000-0000-0000-0000-000000000040')
                  and (select reenviada_por = :'contador' and pedida_por = :'contador' and etapa = 2 and rodada = 1
                       from erp.titulo_revisoes where titulo_id = '82000000-0000-0000-0000-000000000040'),
  'revisão: o pedido e o reenvio ficam registrados, e o título passa à volta 2');
select pg_temp.ok(pg_temp.livro('comprometido', '82000000-0000-0000-0000-000000000040') = -1200
                  and (select sum(valor) from erp.lancamentos where titulo_id = '82000000-0000-0000-0000-000000000040'
                       and natureza_id = pg_temp.nat('05.01.02') and data_caixa = '2027-01-25') = -1200
                  and (select sum(valor) from erp.lancamentos where titulo_id = '82000000-0000-0000-0000-000000000040'
                       and natureza_id = pg_temp.nat('05.01.04')) = 0,
  'revisão: o livro estorna o comprometido antigo e lança o ajustado');
select pg_temp.ok(erp.alcada_pendente('82000000-0000-0000-0000-000000000040') = 'AREA'
                  and (select acumulado = 1200 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000040' and rodada = 2),
  'revisão: a alçada recomeça do zero, recalculada pelo título ajustado');
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000040', 'de novo')$$,
  'O título não está em revisão', 'revisão: reenviado, não reenvia de novo');
select pg_temp.ok((select por = :'contador' and origem = 'ajuste' and lista = 'AF' and etapa = 2 from erp.titulo_aprovacoes
                    where titulo_id = '82000000-0000-0000-0000-000000000040' and rodada = 2),
  'revisão: o ajuste do AF conta como a aprovação dele; o título volta para a gestora');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem ajustou e reenviou não aprova outra etapa');
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'diretor2') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true) as dec40 \gset
select pg_temp.ok(:'dec40' = 'aprovado'
                  and (select count(*) = 1 from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000040' and rodada = 1)
                  and (select count(*) = 2 from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000040' and rodada = 2),
  'revisão: a gestora aprova e o título fica aprovado; as decisões da volta 1 ficam no histórico');
-- regras do ajuste: o admin diz o que cada um muda e, em número e data, para que lado
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.regras_ajuste set direcao = 'menor' where campo = 'titulos.valor'$$,
  'Só o administrador pode mudar a configuração', 'ajuste: só o admin muda as regras do ajuste');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$insert into erp.regras_ajuste (campo, quem, rotulo, tipo) values ('titulos.empresa_id', 'AF', 'a empresa', 'outro')$$,
  'As regras do ajuste são fixas; altere só se pode e para que lado', 'ajuste: as linhas das regras são fixas');
select pg_temp.falha($$update erp.regras_ajuste set direcao = 'maior' where campo = 'titulos.descricao'$$,
  'ajuste: só número e data têm lado');
update erp.regras_ajuste set direcao = 'menor' where campo = 'titulos.valor' and quem = 'AUTOR';
update erp.regras_ajuste set permitido = false where campo = 'parcelas.vencimento' and quem = 'AUTOR';
update erp.regras_ajuste set permitido = false where campo = 'titulo_rateios.natureza_id' and quem = 'AREA';
update erp.regras_ajuste set direcao = 'maior' where campo = 'titulos.emissao' and quem = 'AUTOR';
-- cada um com um papel só, para ver a regra de cada papel (quem tem mais de um pode o que algum deles pode)
select string_agg(user_id::text, ',') as af_antes from erp.listas_financeiro where lista = 'AF' \gset
select pg_temp.sis(); delete from erp.listas_financeiro where lista = 'AF' and user_id in (:'gestor', :'analista'); select pg_temp.volta();
select pg_temp.ok((select count(*) = 4 from erp.auditoria where tabela = 'regras_ajuste'), 'ajuste: mudar as regras fica na auditoria');
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor, descricao) values
  ('82000000-0000-0000-0000-000000000041', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2027-01-04', '2027-01-01', 1000, 'evento');
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000041', 1, '2027-01-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000041', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000041');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000041', false, 'rever valor e vencimento', true);
select pg_temp.erro_igual($$update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.02') where titulo_id = '82000000-0000-0000-0000-000000000041'$$,
  'No ajuste, você não pode mudar a natureza do rateio', 'ajuste: campo travado para o gestor da área não muda');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.titulos set valor = 1100 where id = '82000000-0000-0000-0000-000000000041'$$,
  'No ajuste, o valor do título só pode mudar para menos', 'ajuste: só para menos recusa aumentar');
select pg_temp.erro_igual($$update erp.parcelas set vencimento = '2027-01-25' where titulo_id = '82000000-0000-0000-0000-000000000041'$$,
  'No ajuste, você não pode mudar o vencimento da parcela', 'ajuste: campo travado para quem lançou não muda');
select pg_temp.erro_igual($$update erp.titulos set emissao = '2027-01-03' where id = '82000000-0000-0000-0000-000000000041'$$,
  'No ajuste, a emissão do título só pode mudar para mais', 'ajuste: só para mais recusa voltar a data');
update erp.titulos set valor = 900, descricao = 'evento menor', emissao = '2027-01-05' where id = '82000000-0000-0000-0000-000000000041';
update erp.parcelas set valor = 900 where titulo_id = '82000000-0000-0000-0000-000000000041';
update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.02') where titulo_id = '82000000-0000-0000-0000-000000000041';
select pg_temp.ok((select valor = 900 from erp.titulos where id = '82000000-0000-0000-0000-000000000041'),
  'ajuste: quem lançou diminui o valor e muda o que segue liberado');
select pg_temp.como(:'contador');
update erp.parcelas set vencimento = '2027-01-25' where titulo_id = '82000000-0000-0000-0000-000000000041';
select pg_temp.ok((select vencimento = '2027-01-25' from erp.parcelas where titulo_id = '82000000-0000-0000-0000-000000000041'),
  'ajuste: o AF segue com o que a regra dele libera');
select pg_temp.erro_igual($$select erp.conferir_ajuste('82000000-0000-0000-0000-000000000041', 'titulos', '{"novo": 1}', '{"novo": 2}')$$,
  'O ajuste não muda titulos.novo', 'ajuste: coluna que não está nas regras (uma nova, no futuro) não muda');
select pg_temp.erro_igual($$update erp.titulos set rodada = 2 where id = '82000000-0000-0000-0000-000000000041'$$,
  'A volta da alçada muda pelo reenvio da revisão', 'revisão: a volta não sobe à mão (ficaria sem alçada)');
select pg_temp.erro_igual($$update erp.titulos set substitui_id = '82000000-0000-0000-0000-000000000040' where id = '82000000-0000-0000-0000-000000000041'$$,
  'A volta da alçada muda pelo reenvio da revisão', 'revisão: o título substituído não se muda à mão');
select pg_temp.erro_igual($$update erp.titulos set cancelamento = 'recusa' where id = '82000000-0000-0000-0000-000000000041'$$,
  'A situação do título muda pelas quitações', 'revisão: o motivo do cancelamento não se muda à mão');
update erp.titulos set competencia = '2027-06-01' where id = '82000000-0000-0000-0000-000000000041';
select pg_temp.erro_igual($$select erp.reenviar_titulo('82000000-0000-0000-0000-000000000041', 'competência')$$,
  'A competência está fora da janela da emissão; peça a exceção a quem está em AF, AD',
  'revisão: o reenvio do avulso confere a janela da competência');
update erp.titulos set competencia = '2027-01-01' where id = '82000000-0000-0000-0000-000000000041';
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'); select pg_temp.volta();
select pg_temp.como(:'gestor');
update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.04') where titulo_id = '82000000-0000-0000-0000-000000000041';
select pg_temp.ok(true, 'ajuste: o gestor que também é AF pode o que o AF pode');
-- quem ajustou e saiu antes do reenvio não ganha a aprovação pelo ajuste
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = false where id = :'contador';
select pg_temp.como(:'analista');
select erp.reenviar_titulo('82000000-0000-0000-0000-000000000041', 'ajustado');
select pg_temp.ok(not exists (select 1 from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000041' and origem = 'ajuste' and por = :'contador'),
  'revisão: o ajuste de quem foi desativado não vira aprovação');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = true where id = :'contador';
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id)
select 'AF', x::uuid from unnest(string_to_array(:'af_antes', ',')) x on conflict do nothing; select pg_temp.volta();
update erp.regras_ajuste set direcao = 'ambos', permitido = true;
-- a gestora que ajusta já aprova a etapa da área; quem mais ajustou não aprova; tudo fica registrado
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor, descricao) values
  ('82000000-0000-0000-0000-000000000042', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2027-01-04', '2027-01-01', 1000, 'brindes');
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000042', 1, '2027-01-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000042', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
-- com a etapa do AD nesta faixa, para ver as três etapas
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set etapas = '{AREA,AF,AD}' where ate = 50000;
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(null); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor') on conflict do nothing; select pg_temp.como(:'diretor');  -- o próprio acesso só pelo sistema
select pg_temp.como(:'analista');
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000042');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000042', false, 'trocar a descrição e o valor', true);
update erp.titulos set descricao = 'brindes de janeiro' where id = '82000000-0000-0000-0000-000000000042';
select pg_temp.como(:'contador');
update erp.titulos set valor = 800 where id = '82000000-0000-0000-0000-000000000042';
update erp.parcelas set valor = 800 where titulo_id = '82000000-0000-0000-0000-000000000042';
select pg_temp.erro_igual($$insert into erp.titulo_ajustes (revisao_id, titulo_id, tabela, por)
  select id, titulo_id, 'titulos', '00000000-0000-0000-0000-00000000000c' from erp.titulo_revisoes where titulo_id = '82000000-0000-0000-0000-000000000042'$$,
  'O registro do ajuste só é escrito pelas travas do ajuste', 'ajuste: o registro do ajuste não se grava à mão');
-- linha nova no ajuste: cada campo dela passa pela regra (S-072)
select pg_temp.como(:'diretor');
update erp.regras_ajuste set permitido = false where campo = 'titulo_rateios.centro_custo_id';
update erp.regras_ajuste set direcao = 'menor' where campo = 'parcelas.valor';
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$do $y$ begin
    delete from erp.titulo_rateios where titulo_id = '82000000-0000-0000-0000-000000000042';
    insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
    values ('82000000-0000-0000-0000-000000000042', %L, %L, pg_temp.nat('05.01.04'), 100);
  end $y$ $$, :'ne_vm', :'cc_obra'),
  'No ajuste, você não pode mudar o centro de custo do rateio', 'ajuste: tirar e incluir a linha não contorna a regra do campo');
select pg_temp.erro_igual($$insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000042', 2, '2027-02-20', 100)$$,
  'No ajuste, o valor da parcela só muda para um lado; não entra em linha nova', 'ajuste: linha nova não contorna o lado da mudança');
select pg_temp.como(:'diretor');
update erp.regras_ajuste set direcao = 'ambos', permitido = true;
select pg_temp.como(:'diretor2');
select erp.reenviar_titulo('82000000-0000-0000-0000-000000000042', 'ajustado');
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set etapas = '{AREA,AF}' where ate = 50000;
select pg_temp.ok((select count(*) = 3 and bool_and(por is not null) from erp.titulo_ajustes where titulo_id = '82000000-0000-0000-0000-000000000042')
                  and exists (select 1 from erp.titulo_ajustes where titulo_id = '82000000-0000-0000-0000-000000000042'
                               and por = :'gestor' and depois ->> 'descricao' = 'brindes de janeiro'),
  'ajuste: cada mudança fica registrada com quem fez, antes e depois');
select pg_temp.ok((select string_agg(lista || ':' || (por = case lista when 'AREA' then :'gestor'::uuid else :'contador'::uuid end)::text, ',' order by etapa)
                     = 'AREA:true,AF:true' from erp.titulo_aprovacoes
                    where titulo_id = '82000000-0000-0000-0000-000000000042' and rodada = 2 and origem = 'ajuste')
                  and erp.alcada_pendente('82000000-0000-0000-0000-000000000042') = 'AD'
                  and erp.autor_lancamento('titulo', '82000000-0000-0000-0000-000000000042') = :'analista',
  'revisão: o ajuste da gestora e o do AF contam como as aprovações deles; quem lançou continua o autor, e o título segue para o AD');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000042', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem ajustou (sem reenviar) não aprova outra etapa');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000042', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem só reenviou também não aprova outra etapa');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000042', true) = 'aprovado', 'revisão: o AD aprova e o título fica aprovado');
-- revisão de título de nota: ajusta-se a nota, e o reenvio a relança
select pg_temp.como(:'analista');
select erp.previsao_saldo(id) as prev0 from erp.previsoes where compromisso_id = '60000000-0000-0000-0000-000000000002' \gset
select erp.caucao_saldo('60000000-0000-0000-0000-000000000002') as cau0 \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000661', :'spe', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002',
        'nfse', '661', '2027-01-05', '2027-01-01', 1000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000661', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-000000000661', 'iss', 50, '10000000-0000-0000-0000-000000000006', '2027-02-10');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-000000000661', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2027-01-01', '2027-01-20', 1000);
select erp.lancar_documento('70000000-0000-0000-0000-000000000661', array['2027-01-20']::date[], array['68000000-0000-0000-0000-000000000661'::uuid]) as tit661 \gset
select pg_temp.erro_igual($$update erp.documento_retencoes set valor = 60 where documento_id = '70000000-0000-0000-0000-000000000661'$$,
  'A nota já foi lançada; documento_retencoes não muda', 'revisão: sem revisão, a nota lançada não muda');
select pg_temp.como(:'diretor2');
select erp.decidir_titulo(:'tit661', false, 'o ISS é de 60', true);
select pg_temp.erro_igual(format($$update erp.titulos set valor = 1 where id = %L$$, :'tit661'),
  'Título confirmado não se edita', 'revisão: título de nota não se edita direto; ajusta-se a nota');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.documentos_fiscais set lancado_em = now() + interval '1 day' where id = '70000000-0000-0000-0000-000000000661'$$,
  'A situação do documento muda pelo lançamento', 'revisão: a data do lançamento da nota não muda no ajuste');
select pg_temp.erro_igual($$update erp.documentos_fiscais set cancelamento = 'recusa' where id = '70000000-0000-0000-0000-000000000661'$$,
  'A situação do documento muda pelo lançamento', 'revisão: o cancelamento da nota não muda no ajuste');
select pg_temp.como(:'diretor2');
select pg_temp.como(:'diretor');
update erp.regras_ajuste set direcao = 'menor' where campo = 'documento_retencoes.valor';
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.documento_retencoes set valor = 60 where documento_id = '70000000-0000-0000-0000-000000000661'$$,
  'No ajuste, o valor da retenção só pode mudar para menos', 'ajuste: a regra vale também na nota');
select pg_temp.como(:'diretor');
update erp.regras_ajuste set direcao = 'ambos' where campo = 'documento_retencoes.valor';
update erp.regras_ajuste set permitido = false where campo = 'documentos_fiscais.valor_bruto';
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.documentos_fiscais set valor_bruto = 1100 where id = '70000000-0000-0000-0000-000000000661'$$,
  'No ajuste, você não pode mudar o valor bruto da nota', 'ajuste: a regra vale no cabeçalho da nota');
select pg_temp.como(:'diretor');
update erp.regras_ajuste set permitido = true where campo = 'documentos_fiscais.valor_bruto' and quem = 'AUTOR';
select pg_temp.sis(); delete from erp.listas_financeiro where lista = 'AF' and user_id = :'analista'; select pg_temp.volta();
select pg_temp.como(:'analista');
update erp.documentos_fiscais set valor_bruto = 1100 where id = '70000000-0000-0000-0000-000000000661';
update erp.documentos_fiscais set valor_bruto = 1000 where id = '70000000-0000-0000-0000-000000000661';
select pg_temp.ok(true, 'ajuste: na nota, quem lançou pode o que a regra dele libera');
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista'); select pg_temp.volta();
update erp.regras_ajuste set permitido = true where campo = 'documentos_fiscais.valor_bruto';
select pg_temp.como(:'analista');
update erp.documento_retencoes set valor = 60 where documento_id = '70000000-0000-0000-0000-000000000661';
update erp.documentos_fiscais set competencia = '2027-01-01' where id = '70000000-0000-0000-0000-000000000661';
select erp.reenviar_titulo(:'tit661', 'ISS corrigido') as tit661b \gset
select pg_temp.ok(:'tit661b' <> :'tit661'
                  and (select situacao = 'cancelado' and cancelamento = 'revisao' from erp.titulos where id = :'tit661')
                  and (select substitui_id = :'tit661' and valor = 890 and situacao = 'aberto' from erp.titulos where id = :'tit661b')
                  and (select valor = 60 from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000661'
                       and tipo = 'imposto' and situacao = 'aberto')
                  and (select situacao = 'lancado' from erp.documentos_fiscais where id = '70000000-0000-0000-0000-000000000661'),
  'revisão: a nota ajustada é relançada e os títulos dela refeitos (1.000 − 60 de ISS − 50 de caução)');
select pg_temp.ok(erp.caucao_saldo('60000000-0000-0000-0000-000000000002') = :'cau0'::numeric + 50
                  and (select erp.previsao_saldo(id) from erp.previsoes where compromisso_id = '60000000-0000-0000-0000-000000000002') = :'prev0'::numeric
                  and erp.previsao_saldo('68000000-0000-0000-0000-000000000661') = 0
                  and (select sum(tp.valor) = 1000 from erp.titulo_previsoes tp where tp.titulo_id = :'tit661b')
                  and (select coalesce(sum(l.valor), 0) = -950 from erp.lancamentos l join erp.titulos t on t.id = l.titulo_id
                       where t.documento_id = '70000000-0000-0000-0000-000000000661' and l.estagio = 'comprometido'),
  'revisão: caução, previsão e livro contam a nota uma vez só depois do relançamento');
select pg_temp.ok(erp.alcada_pendente(:'tit661b') = 'AREA'
                  and not exists (select 1 from erp.titulo_aprovacoes where titulo_id = :'tit661b' and origem = 'ajuste'),
  'revisão: o título refeito recomeça a alçada; quem lançou e ajustou (mesmo sendo AF) não ganha aprovação pelo ajuste');
select pg_temp.erro_igual(format($$select erp.decidir_titulo(%L, true)$$, :'tit661b'),
  'Quem lançou não aprova o próprio lançamento', 'revisão: quem lançou e ajustou a nota não aprova o título refeito');
-- nova revisão que muda a natureza: a previsão que não casa mais fica livre, e o relançamento segue
select pg_temp.como(:'diretor2');
select erp.decidir_titulo(:'tit661b', false, 'a natureza é 04.02', true);
select pg_temp.como(:'analista');
update erp.documento_rateios set natureza_id = pg_temp.nat('04.02') where documento_id = '70000000-0000-0000-0000-000000000661';
select erp.reenviar_titulo(:'tit661b', 'natureza corrigida') as tit661c \gset
select pg_temp.ok(erp.previsao_saldo('68000000-0000-0000-0000-000000000661') = 1000
                  and not exists (select 1 from erp.titulo_previsoes where titulo_id = :'tit661c'),
  'revisão: no relançamento, a previsão que deixou de casar com a nota volta a ficar livre');
-- quem lançou alguma nota da cadeia não aprova, mesmo depois de outros reenvios
select pg_temp.como(:'diretor2');
select erp.decidir_titulo(:'tit661c', false, 'conferir o vencimento', true);
select pg_temp.como(:'contador');
select erp.reenviar_titulo(:'tit661c', 'conferido') as tit661d \gset
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.decidir_titulo(%L, true)$$, :'tit661d'),
  'Quem lançou não aprova o próprio lançamento', 'revisão: quem lançou o título substituído não aprova o refeito');
select pg_temp.como(:'diretor2');
select erp.decidir_titulo(:'tit661d', false, 'conferir de novo', true);
select pg_temp.como(:'gestor');
update erp.documento_retencoes set vencimento = '2027-02-11' where documento_id = '70000000-0000-0000-0000-000000000661';
select pg_temp.como(:'contador');
select erp.reenviar_titulo(:'tit661d', 'conferido de novo') as tit661e \gset
select pg_temp.ok((select string_agg(lista || ':' || (por = :'gestor')::text, ',') = 'AF:true' from erp.titulo_aprovacoes
                    where titulo_id = :'tit661e' and origem = 'ajuste')
                  and erp.alcada_pendente(:'tit661e') = 'AREA'
                  and (select lista = 'AF' and por = :'contador' from erp.titulo_aprovacoes where titulo_id = :'tit661d' and origem = 'ajuste')
                  and erp.autor_lancamento('titulo', :'tit661d') = :'contador',
  'revisão: na nota relançada também; quem é gestor de outro centro ajusta como AF, e a etapa da área fica para o gestor dela');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.decidir_titulo(%L, true)$$, :'tit661e'),
  'Quem lançou não aprova o próprio lançamento', 'revisão: a cadeia de substituições inteira conta, não só a anterior');
-- dois gestores da área ajustam: o primeiro ganha a área; o outro, fora do AF, não ganha a do AF
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_obra', :'gestor'); select pg_temp.volta();
select pg_temp.sis(); delete from erp.listas_financeiro where lista = 'AF' and user_id = :'gestor'; select pg_temp.volta();
select pg_temp.como(:'diretor2');
select erp.decidir_titulo(:'tit661e', false, 'conferir a série', true);
update erp.documento_retencoes set vencimento = '2027-02-12' where documento_id = '70000000-0000-0000-0000-000000000661';
select pg_temp.como(:'gestor');
update erp.documentos_fiscais set serie = 'A' where id = '70000000-0000-0000-0000-000000000661';
select pg_temp.como(:'contador');
select erp.reenviar_titulo(:'tit661e', 'série conferida') as tit661f \gset
select pg_temp.ok((select string_agg(lista || ':' || por::text, ',' order by etapa) from erp.titulo_aprovacoes
                    where titulo_id = :'tit661f' and origem = 'ajuste') = 'AREA:' || :'diretor2' || ',AF:' || :'contador',
  'revisão: a etapa do AF só vai para quem está no AF');
select pg_temp.como(:'diretor');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'); select pg_temp.volta();
-- recusar o título de uma nota cancela a nota inteira: impostos, previsão e caução voltam
select pg_temp.como(:'analista');
select erp.previsao_saldo(id) as prev_antes from erp.previsoes where compromisso_id = '60000000-0000-0000-0000-000000000002' \gset
select erp.caucao_saldo('60000000-0000-0000-0000-000000000002') as caucao_antes \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000660', :'spe', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002',
        'nfse', '660', '2027-01-05', '2027-01-01', 1000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000660', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-000000000660', 'iss', 50, '10000000-0000-0000-0000-000000000006', '2027-02-10');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-000000000660', :'spe', 'manual', '10000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2027-01-01', '2027-01-20', 1000);
select erp.lancar_documento('70000000-0000-0000-0000-000000000660', array['2027-01-20']::date[], array['68000000-0000-0000-0000-000000000660'::uuid]) as tit660 \gset
select pg_temp.ok(erp.caucao_saldo('60000000-0000-0000-0000-000000000002') = :'caucao_antes'::numeric + 50
                  and erp.previsao_saldo('68000000-0000-0000-0000-000000000660') = 0,
  'recusa: (antes) a nota retém caução e consome a previsão');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$do $y$ begin
    insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
      ('83000000-0000-0000-0000-000000000660', %L, %L, '10000000-0000-0000-0000-000000000006', %L, %L, '2027-02-10', 50);
    insert into erp.quitacoes (pagamento_id, parcela_id, principal)
      select '83000000-0000-0000-0000-000000000660', pa.id, 50 from erp.parcelas pa join erp.titulos t on t.id = pa.titulo_id
       where t.documento_id = '70000000-0000-0000-0000-000000000660' and t.tipo = 'imposto';
    perform pg_temp.como(%L);
    perform erp.decidir_titulo(%L, false, 'serviço não medido');
  end $y$ $$, :'spe', :'conta_spe', :'ne_vm', :'cc_obra', :'diretor2', :'tit660'),
  'O título ou a nota dele já tem pagamento; o estorno do pagamento fica para o módulo de bancos',
  'recusa: com o imposto da nota já pago, a nota não se desfaz');
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_titulo(:'tit660', false, 'serviço não medido') = 'recusado', 'recusa: o gestor da obra recusa o título da nota');
select pg_temp.ok((select situacao = 'cancelado' and cancelamento = 'recusa' from erp.documentos_fiscais where id = '70000000-0000-0000-0000-000000000660')
                  and (select bool_and(situacao = 'cancelado') and count(*) = 2 from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000660'),
  'recusa: a nota e todos os títulos dela (fornecedor e imposto) são cancelados');
select pg_temp.ok((select coalesce(sum(l.valor), 0) = 0 from erp.lancamentos l join erp.titulos t on t.id = l.titulo_id
                   where t.documento_id = '70000000-0000-0000-0000-000000000660'),
  'recusa: o livro estorna o comprometido dos títulos e o consumo da previsão');
select pg_temp.ok(erp.caucao_saldo('60000000-0000-0000-0000-000000000002') = :'caucao_antes'::numeric
                  and erp.previsao_saldo('68000000-0000-0000-0000-000000000660') = 1000
                  and (select situacao = 'aberta' from erp.previsoes where id = '68000000-0000-0000-0000-000000000660'),
  'recusa: a caução retida é estornada e a previsão volta a ter o saldo');
select pg_temp.como(:'analista');
insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
values (:'spe', '10000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000002', 'nfse', '660', '2027-01-05', '2027-01-01', 900);
select pg_temp.ok(true, 'recusa: a nota recusada libera o número para lançar a versão certa');
rollback;
-- ---------------------------------------------------------------------
\echo '# perfis de acesso: tipos de núcleo, modelos, atribuições, exceções'
begin;
delete from erp.atribuicoes where perfil_id = :'tudo';   -- aqui o acesso de cada um é o do teste
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$insert into erp.tipos_nucleo (codigo, nome) values ('stand', 'Stand de vendas')$$,
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'tipos de núcleo: ninguém cria tipo direto na tabela');
select pg_temp.como(null);  -- preparo como o sistema; o pedido com aprovação é testado no fim do bloco
insert into erp.tipos_nucleo (codigo, nome) values ('stand', 'Stand de vendas');
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'tipos_nucleo' and registro = 'stand'), 'tipos de núcleo: o administrador cria tipo novo, com auditoria');
select pg_temp.erro_igual($$delete from erp.tipos_nucleo where codigo = 'stand'$$, 'Não se apaga o tipo de núcleo; desative', 'tipos de núcleo: não se apagam');
select pg_temp.erro_igual($$update erp.tipos_nucleo set exige_empreendimento = false where codigo = 'empreendimento'$$,
  'O tipo já tem núcleos; a exigência de empreendimento não muda', 'tipos de núcleo: tipo com núcleos não muda a exigência de empreendimento');
select pg_temp.erro_igual(format($$insert into erp.nucleos_economicos (empresa_id, tipo, nome) values (%L, 'empreendimento', 'Sem obra')$$, :'spe'),
  'O núcleo deste tipo precisa de um empreendimento', 'tipos de núcleo: o tipo que exige empreendimento recusa núcleo sem ele');
select pg_temp.erro_igual(format($$insert into erp.nucleos_economicos (empresa_id, tipo, empreendimento_id, nome) values (%L, 'stand', '30000000-0000-0000-0000-000000000001', 'Stand VM')$$, :'spe'),
  'Só o núcleo de tipo com empreendimento aponta para um empreendimento', 'tipos de núcleo: tipo sem empreendimento não aponta para um');
update erp.tipos_nucleo set ativo = false where codigo = 'stand';
select pg_temp.erro_igual(format($$insert into erp.nucleos_economicos (empresa_id, tipo, nome) values (%L, 'stand', 'Stand VM')$$, :'spe'),
  'O tipo de núcleo está desativado', 'tipos de núcleo: tipo desativado não recebe núcleo novo');

-- núcleos: uma loja de hoje
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome) values ('40000000-0000-0000-0000-000000000031', :'spe', 'loja', 'Loja hoje');
\set ne_loja '40000000-0000-0000-0000-000000000031'

-- modelos
insert into erp.perfis_modelo (id, nome) values
  ('a0000000-0000-0000-0000-000000000001', 'Analista de Marketing'),
  ('a0000000-0000-0000-0000-000000000002', 'Leitor de Obra'),
  ('a0000000-0000-0000-0000-000000000003', 'Leitor de Marketing'),
  ('a0000000-0000-0000-0000-000000000004', 'Coordenador de Marketing');
insert into erp.perfil_centros values
  ('a0000000-0000-0000-0000-000000000001', :'cc_mkt', 'lancador_restrito'),
  ('a0000000-0000-0000-0000-000000000002', :'cc_obra', 'leitor'),
  ('a0000000-0000-0000-0000-000000000003', :'cc_mkt', 'leitor'),
  ('a0000000-0000-0000-0000-000000000004', :'cc_mkt', 'lancador');
insert into erp.perfil_naturezas values ('a0000000-0000-0000-0000-000000000004', pg_temp.nat('05.01'));
update erp.naturezas set restrita = true where codigo = '05.01.04';

-- ninguém grava direto nas tabelas de acesso, nem o administrador
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$insert into erp.atribuicoes (user_id, perfil_id, escopo) values (%L, 'a0000000-0000-0000-0000-000000000004', 'todos')$$, :'analista'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: o administrador não atribui modelo direto na tabela');
select pg_temp.erro_igual($$update erp.perfil_centros set nivel = 'lancador'$$,
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: o administrador não muda o modelo direto na tabela');
select pg_temp.erro_igual(format($$insert into erp.listas_financeiro (lista, user_id) values ('AO', %L)$$, :'analista'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: o administrador não põe ninguém em AF, AO ou AD direto na tabela');
select pg_temp.erro_igual(format($$insert into erp.centro_diretores values (%L, %L)$$, :'cc_mkt', :'analista'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: o administrador não faz diretor da área direto na tabela');
select pg_temp.erro_igual($$update erp.naturezas set restrita = false where codigo = '05.01.04'$$,
  'Marcar natureza restrita ou mudá-la de galho restrito só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: a marca restrita não muda direto na tabela');
select pg_temp.como(null);

-- analista: Analista de Marketing na lista (Vila Maria)
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000001', :'analista', 'a0000000-0000-0000-0000-000000000001', 'lista');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000001', :'ne_vm', true);
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'atribuicoes' and registro = 'a1000000-0000-0000-0000-000000000001'),
  'perfis: atribuição entra na auditoria');
select pg_temp.ok((select not ve_tudo and lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt')),
  'perfis: lançador restrito lança e não vê tudo do centro');
select pg_temp.ok(pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'), :'analista')
                  and not pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'), :'gestor'),
  'perfis: lançador restrito vê o que lançou e não vê o lançamento de outro');
select pg_temp.ok((select not ve_tudo and not lanca from pg_temp.acesso(:'analista', :'ne_corp', :'cc_mkt'))
                  and (select not ve_tudo and not lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_obra')),
  'perfis: fora da lista ou fora dos centros do modelo, nada');
select pg_temp.ok(pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'))
                  and not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and not pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), :'analista'),
  'perfis: natureza restrita fica fechada mesmo dentro do centro, até liberação');
select pg_temp.erro_igual($$insert into erp.atribuicao_tipos values ('a1000000-0000-0000-0000-000000000099', 'loja')$$,
  'insert or update on table "atribuicao_tipos" violates foreign key constraint "atribuicao_tipos_atribuicao_id_fkey"', 'perfis: tipo só em atribuição que existe');

-- analista: Leitor de Obra em todos, inclusive os futuros, exceto o Corporativo
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000002', :'analista', 'a0000000-0000-0000-0000-000000000002', 'todos');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000002', :'ne_corp', false);
select pg_temp.erro_igual($$insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000031', true)$$,
  'Só o escopo lista inclui núcleos; nos outros, o núcleo marcado fica de fora', 'perfis: escopo todos só exclui núcleos');
select pg_temp.erro_igual($$insert into erp.atribuicao_tipos values ('a1000000-0000-0000-0000-000000000002', 'loja')$$,
  'O escopo todos não escolhe tipos', 'perfis: escopo todos não escolhe tipos');
select pg_temp.como(null);  -- só o sistema grava a data de criação; aqui, para simular o futuro
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome, criado_em) values
  ('40000000-0000-0000-0000-000000000032', :'spe', 'loja', 'Loja futura', now() + interval '1 day'),
  ('40000000-0000-0000-0000-000000000033', :'incorp', 'outro', 'Outro futuro', now() + interval '1 day');
select pg_temp.como(:'diretor');
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome, criado_em) values
  ('40000000-0000-0000-0000-000000000034', :'spe', 'loja', 'Loja datada à mão', now() + interval '1 day');
select pg_temp.ok((select criado_em = now() from erp.nucleos_economicos where id = '40000000-0000-0000-0000-000000000034'),
  'perfis: quem cadastra o núcleo não escolhe a data de criação (não o faz parecer futuro)');
select pg_temp.erro_igual(format($$update erp.nucleos_economicos set tipo = 'outro' where id = %L$$, :'ne_loja'),
  'Mudar o tipo do núcleo só por pedido aprovado (erp.pedir_mudanca_acesso)', 'perfis: o tipo do núcleo não muda direto na tabela');
select pg_temp.como(null);
\set ne_loja2 '40000000-0000-0000-0000-000000000032'
\set ne_outro2 '40000000-0000-0000-0000-000000000033'
select pg_temp.ok((select ve_tudo and not lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_obra'))
                  and (select ve_tudo from pg_temp.acesso(:'analista', :'ne_loja2', :'cc_obra'))
                  and (select not ve_tudo from pg_temp.acesso(:'analista', :'ne_corp', :'cc_obra')),
  'perfis: todos, inclusive os futuros, exceto os marcados');

-- sobreposição: Leitor de Marketing nos empreendimentos (tipo) soma com o lançador restrito
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000003', :'analista', 'a0000000-0000-0000-0000-000000000003', 'tipos');
insert into erp.atribuicao_tipos values ('a1000000-0000-0000-0000-000000000003', 'empreendimento');
select pg_temp.ok((select ve_tudo and lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt'))
                  and pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'), :'gestor'),
  'perfis: atribuições que se sobrepõem valem pelo maior (leitor + lançador restrito = lançador)');
select pg_temp.ok((select not ve_tudo from pg_temp.acesso(:'analista', :'ne_loja', :'cc_mkt')),
  'perfis: escopo por tipo não pega núcleo de outro tipo');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000003', :'ne_vm', false);
select pg_temp.ok((select not ve_tudo and lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt')),
  'perfis: escopo por tipo exceto os marcados');

-- exceção da pessoa vence o modelo
insert into erp.excecoes_centro values (:'analista', :'ne_vm', :'cc_mkt', 'nenhum', null);
select pg_temp.ok((select not ve_tudo and not lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt')),
  'perfis: exceção nenhum tira o acesso que o modelo dá');
update erp.excecoes_centro set nivel = 'leitor' where user_id = :'analista';
select pg_temp.ok((select ve_tudo and not lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt')),
  'perfis: exceção troca o nível do modelo');
update erp.excecoes_centro set fim = current_date - 1 where user_id = :'analista';
select pg_temp.ok((select not ve_tudo and lanca from pg_temp.acesso(:'analista', :'ne_vm', :'cc_mkt')),
  'perfis: exceção vencida deixa de valer');

-- naturezas: liberação e bloqueio da pessoa
insert into erp.excecoes_natureza (user_id, natureza_id, centro_custo_id, efeito) values (:'analista', pg_temp.nat('05.01.04'), :'cc_mkt', 'liberar');
select pg_temp.ok(pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and not pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.04'), :'gestor'),
  'perfis: natureza restrita liberada só no centro da liberação');
insert into erp.excecoes_natureza (user_id, natureza_id, centro_custo_id, efeito) values (:'analista', pg_temp.nat('05.01'), null, 'bloquear');
select pg_temp.ok(not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'))
                  and not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'perfis: bloqueio do galho vence a liberação e vale nas naturezas de baixo');

-- modelo que libera natureza restrita: só nos centros do modelo
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000004', :'leitor', 'a0000000-0000-0000-0000-000000000004', 'lista');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000004', :'ne_vm', true);
select pg_temp.ok(pg_temp.lanca_linha(:'leitor', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and not pg_temp.natureza_liberada(:'leitor', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.04')),
  'perfis: o modelo libera a natureza restrita só nos centros dele');

-- lista com os marcados agora + os futuros dos tipos escolhidos (foto na hora)
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000005', :'gestor', 'a0000000-0000-0000-0000-000000000003', 'lista');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000005', :'ne_corp', true);
insert into erp.atribuicao_tipos values ('a1000000-0000-0000-0000-000000000005', 'loja');
select pg_temp.ok((select ve_tudo from pg_temp.acesso(:'gestor', :'ne_corp', :'cc_mkt'))
                  and (select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_loja', :'cc_mkt'))
                  and (select ve_tudo from pg_temp.acesso(:'gestor', :'ne_loja2', :'cc_mkt'))
                  and (select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_outro2', :'cc_mkt'))
                  and (select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_vm', :'cc_mkt')),
  'perfis: lista = os marcados na hora + os núcleos criados depois nos tipos escolhidos');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000005', :'ne_loja2', false);
select pg_temp.ok((select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_loja2', :'cc_mkt')),
  'perfis: o futuro do tipo também se exclui');
select pg_temp.erro_igual($$update erp.atribuicoes set escopo = 'todos' where id = 'a1000000-0000-0000-0000-000000000005'$$,
  'Tire os tipos e núcleos incluídos que não valem no escopo novo antes de trocar', 'perfis: troca de escopo não deixa marca que não vale');
select pg_temp.erro_igual($$update erp.atribuicoes set criado_em = now() - interval '1 year' where id = 'a1000000-0000-0000-0000-000000000005'$$,
  'A atribuição não muda de pessoa nem de data de criação', 'perfis: a foto da atribuição não volta no tempo');
select pg_temp.erro_igual(format($$update erp.nucleos_economicos set criado_em = now() + interval '2 days' where id = %L$$, :'ne_loja'),
  'A data de criação do núcleo não muda', 'perfis: núcleo existente não vira futuro');

-- validade e modelo desativado
update erp.atribuicoes set inicio = current_date - 10, fim = current_date - 1 where id = 'a1000000-0000-0000-0000-000000000005';
select pg_temp.ok((select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_corp', :'cc_mkt')), 'perfis: atribuição vencida deixa de valer');
update erp.atribuicoes set inicio = current_date + 1, fim = null where id = 'a1000000-0000-0000-0000-000000000005';
select pg_temp.ok((select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_corp', :'cc_mkt')), 'perfis: atribuição que ainda não começou não vale');
update erp.atribuicoes set inicio = current_date where id = 'a1000000-0000-0000-0000-000000000005';
update erp.perfis_modelo set ativo = false where id = 'a0000000-0000-0000-0000-000000000003';
select pg_temp.ok((select not ve_tudo from pg_temp.acesso(:'gestor', :'ne_corp', :'cc_mkt')), 'perfis: modelo desativado não dá acesso');
update erp.perfis_modelo set ativo = true where id = 'a0000000-0000-0000-0000-000000000003';
update erp.perfil_centros set nivel = 'lancador' where perfil_id = 'a0000000-0000-0000-0000-000000000003';
select pg_temp.ok((select lanca from pg_temp.acesso(:'gestor', :'ne_corp', :'cc_mkt')), 'perfis: mudar o modelo muda quem está ligado a ele');
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values
  ('a1000000-0000-0000-0000-000000000006', :'contador', 'a0000000-0000-0000-0000-000000000003', 'lista');
select pg_temp.erro_igual(format($$update erp.atribuicoes set user_id = %L where id = 'a1000000-0000-0000-0000-000000000006'$$, :'leitor'),
  'A atribuição não muda de pessoa nem de data de criação', 'perfis: a atribuição não muda de pessoa');
update erp.tipos_nucleo set ativo = true where codigo = 'stand';
select pg_temp.erro_igual($$update erp.tipos_nucleo set codigo = 'stand2' where codigo = 'stand'$$,
  'O código do tipo de núcleo não muda', 'tipos de núcleo: o código não muda, nem sem núcleos');

-- exceção lançador restrito: lança e não vê tudo
insert into erp.excecoes_centro values (:'contador', :'ne_corp', :'cc_obra', 'lancador_restrito', null);
select pg_temp.ok((select not ve_tudo and lanca from pg_temp.acesso(:'contador', :'ne_corp', :'cc_obra')),
  'perfis: exceção lançador restrito lança e não vê tudo');

-- exceção de natureza vencida deixa de valer (bloquear e liberar)
update erp.excecoes_natureza set fim = current_date - 1 where user_id = :'analista' and efeito = 'bloquear';
select pg_temp.ok(pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'))
                  and pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'perfis: bloqueio de natureza vencido deixa de valer');
update erp.excecoes_natureza set fim = current_date - 1 where user_id = :'analista' and efeito = 'liberar';
select pg_temp.ok(not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'perfis: liberação de natureza vencida deixa de valer');

-- mudança de acesso com aprovação (S-078): lista de aprovadores, master, sucessão
select pg_temp.como(null);
insert into erp.aprovadores_acesso values (:'diretor2'), (:'leitor');
update erp.regra_acesso set minimo = 1;
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$insert into erp.mudancas_acesso (tabela, operacao, dados, motivo, pedida_por, minimo) values ('atribuicoes', 'incluir', '{}', 'x', %L, 0)$$, :'diretor'),
  'Mudança de acesso só pelo pedido (erp.pedir_mudanca_acesso) e pela decisão (erp.decidir_mudanca_acesso)', 'acesso: ninguém grava pedido direto na tabela');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AO', 'user_id', %L), 'teste')$$, :'analista'),
  'Só o administrador pode mudar a configuração', 'acesso: só o administrador pede mudança de acesso');

-- atribuição nova com o núcleo, em dois pedidos; cada um vale quando aprovado
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('atribuicoes', 'incluir',
  jsonb_build_object('user_id', :'contador', 'perfil_id', 'a0000000-0000-0000-0000-000000000004', 'escopo', 'lista'), 'Coordenação de Marketing') as m_atr \gset
select dados->>'id' as atr_nova from erp.mudancas_acesso where id = :'m_atr' \gset
select erp.pedir_mudanca_acesso('atribuicao_nucleos', 'incluir',
  jsonb_build_object('atribuicao_id', :'atr_nova', 'nucleo_economico_id', :'ne_corp', 'incluir', true), 'Corporativo') as m_nuc \gset
select pg_temp.ok((select beneficiarios = array[:'contador'::uuid] from erp.mudancas_acesso where id = :'m_nuc'),
  'acesso: núcleo de atribuição ainda pedida já sabe quem ganha acesso');
select pg_temp.ok(not exists (select 1 from erp.atribuicoes where id = :'atr_nova'::uuid), 'acesso: o pedido não vale antes da aprovação');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_atr'),
  'Só um aprovador de acesso decide o pedido', 'acesso: quem não está na lista de aprovadores não decide');
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_mudanca_acesso(:'m_atr', true) = 'aplicada', 'acesso: aprovado pelo mínimo, o pedido vale na hora');
select pg_temp.ok((select criado_em = now() and inicio = current_date from erp.atribuicoes where id = :'atr_nova'::uuid),
  'acesso: a foto da atribuição é do momento em que ela vale');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_atr'),
  'O pedido de acesso já está aplicada', 'acesso: pedido decidido não se decide de novo');
select pg_temp.como(:'leitor');
select erp.decidir_mudanca_acesso(:'m_nuc', true);
select pg_temp.ok((select ve_tudo and lanca from pg_temp.acesso(:'contador', :'ne_corp', :'cc_mkt')), 'acesso: atribuição aprovada dá o acesso');
select pg_temp.sis();   -- a auditoria só o administrador e o master leem
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'atribuicoes' and registro = :'atr_nova' and por = :'diretor2'::uuid),
  'acesso: a auditoria registra quem aprovou');
select pg_temp.volta();

-- quem pediu e quem ganha acesso não aprovam; recusa precisa de justificativa
select pg_temp.como(null);
insert into erp.aprovadores_acesso values (:'diretor');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('centro_aprovadores', 'incluir', jsonb_build_object('centro_custo_id', :'cc_obra', 'user_id', :'leitor'), 'Leitor gestor da Obra') as m_ao \gset
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_ao'),
  'Só um aprovador de acesso decide o pedido', 'acesso: quem pediu (o administrador) não está na lista e não aprova');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_ao'),
  'Quem ganha acesso com a mudança não a aprova', 'acesso: quem ganha acesso não aprova');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, false)$$, :'m_ao'),
  'Recusar o pedido de acesso precisa de justificativa', 'acesso: recusa sem justificativa não passa');
select erp.decidir_mudanca_acesso(:'m_ao', false, 'Leitor não aprova pagamento') as r_ao \gset
select pg_temp.ok(:'r_ao' = 'recusada'
                  and not exists (select 1 from erp.centro_aprovadores where centro_custo_id = :'cc_obra' and user_id = :'leitor'),
  'acesso: recusado, o pedido não vale');
-- o modelo: quem está ligado a ele não aprova a mudança
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('perfil_centros', 'alterar',
  jsonb_build_object('perfil_id', 'a0000000-0000-0000-0000-000000000001', 'centro_custo_id', :'cc_mkt', 'nivel', 'lancador'), 'Analista lança e vê') as m_mod \gset
select pg_temp.ok((select :'analista'::uuid = any (beneficiarios) from erp.mudancas_acesso where id = :'m_mod'),
  'acesso: mudar o modelo beneficia quem está ligado a ele');
select pg_temp.como(null);
insert into erp.atribuicoes (user_id, perfil_id, escopo) values (:'diretor2', 'a0000000-0000-0000-0000-000000000001', 'todos');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_mod'),
  'Quem ganha acesso com a mudança não a aprova', 'acesso: quem se ligou ao modelo depois do pedido também não aprova');
select pg_temp.como(null);
delete from erp.atribuicoes where user_id = :'diretor2';
select pg_temp.como(:'ti');
-- AF, AO e AD: só com a aprovação do master (Moises, 14/11/2026)
select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AO', 'user_id', :'diretor2'), 'Sócia no AO') as m_eu \gset
select pg_temp.ok((select situacao = 'pendente' and minimo = 1 from erp.mudancas_acesso where id = :'m_eu'), 'AF/AO/AD: o pedido do administrador fica pendente');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_eu'),
  'Só o master decide este pedido', 'AF/AO/AD: aprovador de acesso que não é o master não decide');
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_acesso(:'m_eu', true) as r_eu \gset
select pg_temp.ok(:'r_eu' = 'aplicada'
                  and exists (select 1 from erp.listas_financeiro where lista = 'AO' and user_id = :'diretor2'),
  'AF/AO/AD: a aprovação do master basta e aplica');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AO', 'user_id', %L), 'x')$$, :'diretor'),
  'O master ganha acesso com a mudança: ele mesmo a faz', 'AF/AO/AD: o master não aprova o próprio acesso');
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AO', 'user_id', :'diretor'), 'Moises no AO') as m_eu2 \gset
select pg_temp.ok(exists (select 1 from erp.listas_financeiro where lista = 'AO' and user_id = :'diretor'), 'AF/AO/AD: o master põe a si mesmo, na hora');
select pg_temp.como(:'ti');

-- mínimo de aprovações e pedido que fica velho
select pg_temp.como(null);
update erp.regra_acesso set minimo = 2;
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('excecoes_centro', 'incluir',
  jsonb_build_object('user_id', :'gestor', 'nucleo_economico_id', :'ne_vm', 'centro_custo_id', :'cc_obra', 'nivel', 'leitor'), 'Gestor vê obra') as m_dois \gset
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_mudanca_acesso(:'m_dois', true) = 'pendente', 'acesso: com mínimo 2, uma aprovação não basta');
select pg_temp.como(:'leitor');
select pg_temp.ok(erp.decidir_mudanca_acesso(:'m_dois', true) = 'aplicada', 'acesso: com mínimo 2, a segunda aprovação aplica');
select pg_temp.como(null); update erp.regra_acesso set minimo = 3; select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('excecoes_centro', 'incluir', jsonb_build_object('user_id', %L, 'nucleo_economico_id', %L, 'centro_custo_id', %L, 'nivel', 'leitor'), 'x')$$, :'leitor', :'ne_corp', :'cc_obra'),
  'Não há aprovadores de acesso suficientes para esta mudança (precisa de 3, há 2)', 'acesso: sem aprovadores suficientes, o pedido nem abre');
select pg_temp.como(null); update erp.regra_acesso set minimo = 1; select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('excecoes_centro', 'alterar',
  jsonb_build_object('user_id', :'gestor', 'nucleo_economico_id', :'ne_vm', 'centro_custo_id', :'cc_obra', 'nivel', 'lancador'), 'Gestor lança obra') as m_velho \gset
select pg_temp.como(null);
update erp.excecoes_centro set fim = current_date + 30 where user_id = :'gestor' and centro_custo_id = :'cc_obra';
select pg_temp.como(:'leitor');
select erp.decidir_mudanca_acesso(:'m_velho', true) as r_velho \gset
select pg_temp.ok(:'r_velho' = 'obsoleta'
                  and (select nivel = 'leitor' from erp.excecoes_centro where user_id = :'gestor' and centro_custo_id = :'cc_obra'),
  'acesso: o registro mudou depois do pedido; a aprovação não aplica a versão velha');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.cancelar_mudanca_acesso(%L)$$, :'m_mod'),
  'Só quem pediu cancela o pedido pendente', 'acesso: só quem pediu cancela');
select pg_temp.como(:'ti');
select erp.cancelar_mudanca_acesso(:'m_mod');
select pg_temp.ok((select situacao = 'cancelada' from erp.mudancas_acesso where id = :'m_mod'), 'acesso: quem pediu cancela o pedido pendente');

-- marca restrita, galho restrito e tipo do núcleo também passam pelo pedido
select erp.pedir_mudanca_acesso('naturezas', 'alterar', jsonb_build_object('id', pg_temp.nat('05.01.04'), 'restrita', false), 'Agência deixa de ser restrita') as m_res \gset
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('naturezas', 'alterar', jsonb_build_object('id', %L, 'nome', 'x'), 'x')$$, pg_temp.nat('05.01.04')),
  'O pedido de natureza só muda a marca restrita e o galho', 'acesso: o pedido de natureza não muda outras colunas');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_res'),
  'Quem ganha acesso com a mudança não a aprova', 'acesso: quem tem acesso a algum centro não aprova tirar a marca restrita');
select pg_temp.como(:'diretor2');
select erp.decidir_mudanca_acesso(:'m_res', true);
select pg_temp.ok(not (select restrita from erp.naturezas where codigo = '05.01.04'), 'acesso: a marca restrita muda pelo pedido aprovado');
select pg_temp.como(null);
update erp.naturezas set restrita = true where codigo = '05.01';
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$update erp.naturezas set mae_id = (select id from erp.naturezas where codigo = '05.01') where codigo = '05.02'$$,
  'Marcar natureza restrita ou mudá-la de galho restrito só por pedido aprovado (erp.pedir_mudanca_acesso)', 'acesso: pôr natureza dentro de galho restrito só pelo pedido');
select erp.pedir_mudanca_acesso('nucleos_economicos', 'alterar', jsonb_build_object('id', :'ne_loja', 'tipo', 'outro'), 'Loja vira outro') as m_tipo \gset
select pg_temp.como(:'diretor2');
select erp.decidir_mudanca_acesso(:'m_tipo', true);
select pg_temp.ok((select tipo = 'outro' from erp.nucleos_economicos where id = :'ne_loja'), 'acesso: o tipo do núcleo muda pelo pedido aprovado');

-- a lista de aprovadores: o master muda sozinho; os outros, com a unanimidade da lista
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('aprovadores_acesso', 'incluir', jsonb_build_object('user_id', :'analista'), 'Analista aprova acesso') as m_lista \gset
select pg_temp.ok((select situacao = 'aplicada' and minimo = 0 from erp.mudancas_acesso where id = :'m_lista')
                  and exists (select 1 from erp.aprovadores_acesso where user_id = :'analista'),
  'acesso: o master muda a lista de aprovadores sozinho');
select pg_temp.como(:'ti');      -- administrador, não master
select erp.pedir_mudanca_acesso('regra_acesso', 'alterar', jsonb_build_object('minimo', 2), 'Duas chaves') as m_regra \gset
select pg_temp.ok((select minimo = 4 from erp.mudancas_acesso where id = :'m_regra'),
  'acesso: fora do master, mudar a lista ou o mínimo pede a unanimidade da lista');
select pg_temp.como(:'diretor2'); select erp.decidir_mudanca_acesso(:'m_regra', true);
select pg_temp.como(:'leitor'); select erp.decidir_mudanca_acesso(:'m_regra', true);
select pg_temp.como(:'analista');
select pg_temp.ok(erp.decidir_mudanca_acesso(:'m_regra', true) = 'pendente', 'acesso: sem todos da lista, a mudança da lista não vale');
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_acesso(:'m_regra', true) as r_regra \gset
select pg_temp.ok(:'r_regra' = 'aplicada' and (select minimo = 2 from erp.regra_acesso),
  'acesso: com todos da lista, a mudança da lista vale');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('aprovadores_acesso', 'excluir', jsonb_build_object('user_id', %L), 'x')$$, :'leitor'),
  'Só o administrador pode mudar a configuração', 'acesso: quem não é administrador nem master não pede mudança na lista');

-- master: administradores, grupo de sucessão, passar o papel; sucessão com unanimidade, prazos e veto
\set ti2 '00000000-0000-0000-0000-000000000012'
select pg_temp.como(:'diretor');
insert into erp.usuarios (id, login_id, nome, papel, administrador) values (:'ti2', :'ti2', 'TI 2', 'leitura', true);
select pg_temp.ok(exists (select 1 from erp.usuarios where id = :'ti2' and administrador), 'master: o master cria administrador');
select pg_temp.erro_igual(format($$update erp.usuarios set administrador = true where id = %L$$, :'diretor2'),
  'Administrador não aprova nada no ERP: tire a pessoa das listas de aprovação antes', 'S-081: nem o master faz administrador quem está numa lista de aprovação');
-- S-081: o administrador (TI) não aprova nada; o master configura o que precisa de aprovação
select pg_temp.como(null);
select pg_temp.erro_igual(format($$insert into erp.listas_financeiro values ('AF', %L)$$, :'ti'), 'Administrador não aprova nada no ERP', 'S-081: administrador não entra em AF, AO ou AD');
select pg_temp.erro_igual(format($$insert into erp.centro_aprovadores (centro_custo_id, user_id) values (%L, %L)$$, :'cc_mkt', :'ti'), 'Administrador não aprova nada no ERP', 'S-081: administrador não é gestor de área');
select pg_temp.erro_igual(format($$insert into erp.centro_diretores values (%L, %L)$$, :'cc_mkt', :'ti'), 'Administrador não aprova nada no ERP', 'S-081: administrador não é diretor de área');
select pg_temp.erro_igual(format($$insert into erp.aprovadores_acesso values (%L)$$, :'ti'), 'Administrador não aprova nada no ERP', 'S-081: administrador não aprova acesso');
select pg_temp.erro_igual(format($$insert into erp.grupo_sucessao values (%L)$$, :'ti'), 'Administrador não aprova nada no ERP', 'S-081: administrador não está no grupo de sucessão');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AO', 'user_id', %L), 'x')$$, :'ti'),
  'Administrador não aprova nada no ERP', 'S-081: nem o master põe o administrador numa lista');
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$update erp.regras_mudanca_acesso set exige_aprovacao = false where tabela = 'excecoes_centro'$$,
  'Só o master decide quais mudanças precisam de aprovação', 'S-081: o administrador não dispensa a própria aprovação');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$update erp.regras_mudanca_acesso set rotulo = 'x' where tabela = 'excecoes_centro'$$,
  'As regras são fixas; mude só a exigência', 'S-081: o master muda só a exigência');
select pg_temp.erro_igual($$delete from erp.regras_mudanca_acesso where tabela = 'excecoes_centro'$$,
  'As regras são fixas; mude só a exigência', 'S-081: as regras não se apagam');
update erp.regras_mudanca_acesso set exige_aprovacao = false where tabela in ('excecoes_centro', 'aprovadores_acesso', 'listas_financeiro');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('excecoes_centro', 'incluir',
  jsonb_build_object('user_id', :'leitor', 'nucleo_economico_id', :'ne_vm', 'centro_custo_id', :'cc_obra', 'nivel', 'leitor'), 'Leitor vê obra') as m_disp \gset
select pg_temp.ok((select situacao = 'aplicada' from erp.mudancas_acesso where id = :'m_disp')
                  and exists (select 1 from erp.excecoes_centro where user_id = :'leitor' and centro_custo_id = :'cc_obra'),
  'S-081: tipo dispensado pelo master: a mudança do administrador vale na hora, registrada');
select erp.pedir_mudanca_acesso('aprovadores_acesso', 'excluir', jsonb_build_object('user_id', :'leitor'), 'x') as m_ld \gset
select pg_temp.ok((select situacao = 'pendente' from erp.mudancas_acesso where id = :'m_ld'),
  'S-081: a lista de aprovadores nunca se dispensa da unanimidade fora do master');
select erp.cancelar_mudanca_acesso(:'m_ld');
select erp.pedir_mudanca_acesso('listas_financeiro', 'incluir', jsonb_build_object('lista', 'AF', 'user_id', :'leitor'), 'x') as m_lfd \gset
select pg_temp.ok((select situacao = 'pendente' from erp.mudancas_acesso where id = :'m_lfd'),
  'AF/AO/AD: a aprovação do master nunca se dispensa');
select erp.cancelar_mudanca_acesso(:'m_lfd');
select erp.pedir_mudanca_acesso('excecoes_natureza', 'incluir',
  jsonb_build_object('user_id', :'leitor', 'natureza_id', pg_temp.nat('05.01.04'), 'centro_custo_id', :'cc_mkt', 'efeito', 'liberar'), 'x') as m_nd \gset
select pg_temp.ok((select situacao = 'pendente' from erp.mudancas_acesso where id = :'m_nd'), 'S-081: tipo não dispensado continua pedindo aprovação');
select erp.cancelar_mudanca_acesso(:'m_nd');
-- papel e contador: pedido aprovado (login, situação e sucessor, só o master)
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', %L, 'login_id', 'outro'), 'x')$$, :'gestor'),
  'O pedido de usuário só muda o papel e o contador e ativa o usuário novo (login, desativar e marca de sucessor: só o master)', 'S-081: o pedido não troca o login');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('usuarios', 'incluir', jsonb_build_object('id', %L, 'papel', 'diretor'), 'x')$$, :'gestor'),
  'Em usuarios o pedido só altera', 'S-081: o pedido não cria usuário');
insert into erp.usuarios (id, login_id, nome, papel, ativo) values ('00000000-0000-0000-0000-000000000096', 'novo2', 'Novo 2', 'leitura', false);
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000096', 'papel', 'analista', 'contador', true), 'Novo analista') as m_pap \gset
select pg_temp.ok((select situacao = 'pendente' and beneficiarios = array['00000000-0000-0000-0000-000000000096'::uuid] from erp.mudancas_acesso where id = :'m_pap')
                  and (select papel = 'leitura' from erp.usuarios where id = '00000000-0000-0000-0000-000000000096'),
  'S-081: o pedido de papel só vale depois da aprovação, e o usuário é quem ganha');
select pg_temp.como(:'diretor2'); select erp.decidir_mudanca_acesso(:'m_pap', true);
select pg_temp.como(:'leitor'); select erp.decidir_mudanca_acesso(:'m_pap', true);
select pg_temp.como(:'analista');
select pg_temp.ok(erp.decidir_mudanca_acesso(:'m_pap', true) = 'pendente', 'níveis: lista é todos os aprovadores (E); faltando um, não vale');
select pg_temp.como(:'diretor'); select erp.decidir_mudanca_acesso(:'m_pap', true);
select pg_temp.ok((select papel = 'analista' and contador from erp.usuarios where id = '00000000-0000-0000-0000-000000000096'),
  'S-081: papel e contador mudam pelo pedido aprovado');
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('excecoes_natureza', 'incluir',
  jsonb_build_object('user_id', :'leitor', 'natureza_id', pg_temp.nat('05.01.04'), 'centro_custo_id', :'cc_mkt', 'efeito', 'liberar'), 'x') as m_mst \gset
select pg_temp.ok((select situacao = 'aplicada' from erp.mudancas_acesso where id = :'m_mst'), 'S-081: o que o master pede vale na hora, em qualquer tabela');

select pg_temp.como(:'ti');      -- administrador, não master
select pg_temp.erro_igual(format($$update erp.usuarios set administrador = true where id = %L$$, :'analista'),
  'Só o master cria e administra os administradores', 'master: só o master cria administrador');
select pg_temp.erro_igual(format($$update erp.usuarios set nome = 'x' where id = %L$$, :'ti2'),
  'Só o master cria e administra os administradores', 'master: só o master mexe no cadastro de um administrador');
select pg_temp.erro_igual($$insert into erp.usuarios (id, login_id, nome, papel) values ('00000000-0000-0000-0000-000000000098', 'novo', 'Novo', 'diretor')$$,
  'Usuário novo nasce como leitura; papel e contador só por pedido aprovado (erp.pedir_mudanca_acesso)', 'S-081: o administrador não cria usuário já diretor');
select pg_temp.erro_igual($$insert into erp.usuarios (id, login_id, nome, papel) values ('00000000-0000-0000-0000-000000000098', 'novo', 'Novo', 'leitura')$$,
  'Usuário novo nasce inativo; só o master ativa', 'S-086: o administrador não cria usuário já ativo');
insert into erp.usuarios (id, login_id, nome, papel, ativo) values ('00000000-0000-0000-0000-000000000098', 'novo', 'Novo', 'leitura', false);
select pg_temp.ok((select papel = 'leitura' and not ativo from erp.usuarios where id = '00000000-0000-0000-0000-000000000098'), 'S-081: o administrador cria usuário como leitura e inativo');
select pg_temp.como('novo');
select pg_temp.ok(erp.eu() is null, 'S-086: usuário inativo não age (o login dele não é ninguém)');
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$update erp.usuarios set ativo = true where id = '00000000-0000-0000-0000-000000000098'$$,
  'Só o master muda o login ou a situação de um usuário', 'S-086: o administrador não ativa o usuário que criou');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = true where id = '00000000-0000-0000-0000-000000000098';
select pg_temp.como('novo');
select pg_temp.ok(erp.eu() = '00000000-0000-0000-0000-000000000098', 'S-086: o master ativa e o login passa a valer');
-- níveis: quem aprova cada nível de usuário e de papel de aprovação; delegados (Moises, 14/11/2026)
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$insert into erp.delegados_acesso values (%L)$$, :'diretor2'),
  'Só o master define os delegados', 'níveis: só o master define os delegados');
select pg_temp.erro_igual($$update erp.regras_nivel_acesso set aprovacao = 'nenhuma' where nivel = 'leitura'$$,
  'Só o master decide quem aprova cada nível', 'níveis: só o master decide quem aprova cada nível');
insert into erp.usuarios (id, login_id, nome, papel, ativo) values ('00000000-0000-0000-0000-000000000094', 'novo3', 'Novo 3', 'leitura', false);
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000094', 'ativo', true), 'Novo leitor') as m_at \gset
select pg_temp.ok((select situacao = 'pendente' and aprovacao = 'delegado' from erp.mudancas_acesso where id = :'m_at'),
  'níveis: ativar usuário leitura pede um delegado (padrão)');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$insert into erp.delegados_acesso values (%L)$$, :'ti'),
  'Administrador não aprova nada no ERP', 'níveis: administrador não é delegado');
insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values ('00000000-0000-0000-0000-000000000092', 'f92', 'Familiar 92', 'leitura', true);
select pg_temp.erro_igual($$insert into erp.delegados_acesso values ('00000000-0000-0000-0000-000000000092')$$,
  'Usuário só de sucessão não recebe acesso no ERP', 'níveis: usuário só de sucessão não é delegado');
insert into erp.delegados_acesso values (:'diretor2');
select pg_temp.erro_igual($$update erp.regras_nivel_acesso set rotulo = 'x' where nivel = 'leitura'$$,
  'Os níveis são fixos; mude só quem aprova', 'níveis: o master muda só quem aprova');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_at'),
  'Só um delegado do master decide este pedido', 'níveis: quem não é delegado não decide o pedido delegado');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$update erp.usuarios set ativo = true where id = '00000000-0000-0000-0000-000000000094'$$,
  'Só o administrador pode mudar a configuração', 'níveis: o delegado não ativa direto na tabela');
select erp.decidir_mudanca_acesso(:'m_at', true) as r_at \gset
select pg_temp.ok(:'r_at' = 'aplicada' and (select ativo and ativado_em is not null from erp.usuarios where id = '00000000-0000-0000-0000-000000000094'),
  'níveis: o delegado aprova e o usuário novo é ativado');
select pg_temp.como(:'diretor');
update erp.usuarios set ativo = false where id = '00000000-0000-0000-0000-000000000094';
select pg_temp.erro_igual($$update erp.usuarios set ativado_em = null where id = '00000000-0000-0000-0000-000000000094'$$,
  'A data de ativação do usuário não muda', 'níveis: a data da primeira ativação não muda, nem pelo master');
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000094', 'ativo', true), 'x')$$,
  'Pelo pedido, só se ativa o usuário novo (nunca ativado); desativar e reativar: só o master', 'níveis: reativar quem foi desativado é só do master');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', %L, 'ativo', false), 'x')$$, :'gestor'),
  'Pelo pedido, só se ativa o usuário novo (nunca ativado); desativar e reativar: só o master', 'níveis: o pedido não desativa ninguém');
-- papel: vale o nível mais exigente entre o de antes e o novo
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000094', 'papel', 'gestor'), 'x') as m_g \gset
select pg_temp.ok((select aprovacao = 'unanime' from erp.mudancas_acesso where id = :'m_g'), 'níveis: leitura para gestor vale pelo nível gestor (lista: todos aprovam)');
select erp.cancelar_mudanca_acesso(:'m_g');
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000096', 'papel', 'diretor'), 'x') as m_d \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_acesso where id = :'m_d'), 'níveis: virar diretor pede o master (padrão)');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_d'),
  'Só o master decide este pedido', 'níveis: o nível master só o master decide');
select pg_temp.como(:'ti');
select erp.cancelar_mudanca_acesso(:'m_d');
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', :'diretor2', 'papel', 'leitura'), 'x') as m_d2 \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_acesso where id = :'m_d2'), 'níveis: tirar alguém de diretor também pede o nível diretor');
select erp.cancelar_mudanca_acesso(:'m_d2');
select pg_temp.erro_igual($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000096', 'ativo', false), 'x')$$,
  'Pelo pedido, só se ativa o usuário novo (nunca ativado); desativar e reativar: só o master', 'níveis: o pedido só ativa (ativo = true)');
select erp.pedir_mudanca_acesso('centro_diretores', 'incluir', jsonb_build_object('centro_custo_id', :'cc_obra', 'user_id', :'leitor'), 'x') as m_da \gset
select pg_temp.ok((select aprovacao = 'unanime' from erp.mudancas_acesso where id = :'m_da'), 'níveis: diretor da área segue o nível dele (lista: todos)');
select erp.cancelar_mudanca_acesso(:'m_da');
-- o master dispensa a aprovação de um nível
select pg_temp.como(:'diretor');
update erp.regras_nivel_acesso set aprovacao = 'nenhuma' where nivel = 'leitura';
select pg_temp.como(:'ti');
insert into erp.usuarios (id, login_id, nome, papel, ativo, ativado_em) values ('00000000-0000-0000-0000-000000000093', 'novo4', 'Novo 4', 'leitura', false, now() - interval '1 year');
select pg_temp.ok((select ativado_em is null from erp.usuarios where id = '00000000-0000-0000-0000-000000000093'), 'níveis: quem cria não inventa a data de ativação');
select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', '00000000-0000-0000-0000-000000000093', 'ativo', true), 'Novo leitor') as m_at2 \gset
select pg_temp.ok((select situacao = 'aplicada' from erp.mudancas_acesso where id = :'m_at2')
                  and (select ativo from erp.usuarios where id = '00000000-0000-0000-0000-000000000093'),
  'níveis: leitura sem aprovação, o administrador ativa na hora');
-- gestor da área pelo nível; o master decide qualquer pedido
select pg_temp.como(:'diretor');
update erp.regras_nivel_acesso set aprovacao = 'delegado' where nivel = 'gestor_area';
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('centro_aprovadores', 'incluir', jsonb_build_object('centro_custo_id', :'cc_mkt', 'user_id', :'leitor'), 'x') as m_ga \gset
select pg_temp.ok((select aprovacao = 'delegado' from erp.mudancas_acesso where id = :'m_ga'), 'níveis: gestor da área segue o nível dele');
select pg_temp.como(:'diretor2'); select erp.decidir_mudanca_acesso(:'m_ga', true);
select pg_temp.ok(exists (select 1 from erp.centro_aprovadores where centro_custo_id = :'cc_mkt' and user_id = :'leitor'), 'níveis: o delegado aprova o gestor da área');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('excecoes_natureza', 'incluir',
  jsonb_build_object('user_id', :'leitor', 'natureza_id', pg_temp.nat('05.01.01'), 'centro_custo_id', :'cc_mkt', 'efeito', 'bloquear'), 'x') as m_lm \gset
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_acesso(:'m_lm', true) as r_lm \gset
select pg_temp.ok(:'r_lm' = 'aplicada', 'níveis: o voto do master basta em qualquer pedido');
delete from erp.delegados_acesso where user_id = :'diretor2';
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('centro_aprovadores', 'incluir', jsonb_build_object('centro_custo_id', :'cc_obra', 'user_id', :'analista'), 'x') as m_ga2 \gset
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_ga2'),
  'Só um delegado do master decide este pedido', 'níveis: o master tira o delegado');
select pg_temp.como(:'ti');
-- S-085: administrador não vota nem pelo papel
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$update erp.usuarios set papel = 'gestor' where id = %L$$, :'ti2'),
  'new row for relation "usuarios" violates check constraint "usuarios_admin_sem_voto"', 'S-085: administrador não tem papel gestor ou diretor, nem pelo master');
select pg_temp.erro_igual($$update erp.usuarios set administrador = true, papel = 'diretor' where id = '00000000-0000-0000-0000-000000000098'$$,
  'new row for relation "usuarios" violates check constraint "usuarios_admin_sem_voto"', 'S-085: diretor não vira administrador');
select pg_temp.erro_igual($$update erp.usuarios set administrador = true, contador = true where id = '00000000-0000-0000-0000-000000000098'$$,
  'new row for relation "usuarios" violates check constraint "usuarios_admin_sem_voto"', 'S-085: administrador não é contador');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', %L, 'papel', 'diretor'), 'x')$$, :'ti2'),
  'Administrador não aprova nada no ERP: só papel analista ou leitura, sem contador', 'S-085: o pedido não dá papel de voto a um administrador');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('usuarios', 'alterar', jsonb_build_object('id', %L, 'contador', true), 'x')$$, :'ti2'),
  'Administrador não aprova nada no ERP: só papel analista ou leitura, sem contador', 'S-085: o pedido não faz contador um administrador');

select pg_temp.erro_igual(format($$insert into erp.grupo_sucessao values (%L)$$, :'leitor'),
  'Só o master define o grupo de sucessão', 'master: só o master define o grupo de sucessão');
select pg_temp.como(:'diretor');
insert into erp.grupo_sucessao values (:'leitor'), (:'analista'), (:'diretor2');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_sucessao_master(%L, 'x')$$, :'diretor2'),
  'Só quem está no grupo de sucessão pede a sucessão do master', 'master: só quem está no grupo de sucessão pede a sucessão');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.passar_master(%L, 'x')$$, :'analista'),
  'Só o master passa o papel de master', 'master: só o master passa o papel');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$update erp.usuarios set administrador = false where id = %L$$, :'ti2'),
  'Só o master cria e administra os administradores', 'master: só o master tira um administrador');
-- usuário só de sucessão (pode ser de fora da empresa) não recebe outro acesso
select pg_temp.como(:'diretor');
insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values ('00000000-0000-0000-0000-000000000099', '00000000-0000-0000-0000-000000000099', 'Familiar', 'leitura', true);
insert into erp.grupo_sucessao values ('00000000-0000-0000-0000-000000000099');
select pg_temp.como(null);
select pg_temp.erro_igual($$insert into erp.listas_financeiro values ('AD', '00000000-0000-0000-0000-000000000099')$$,
  'Usuário só de sucessão não recebe acesso no ERP', 'master: usuário só de sucessão não entra em AF, AO ou AD');
select pg_temp.erro_igual($$insert into erp.atribuicoes (user_id, perfil_id, escopo) values ('00000000-0000-0000-0000-000000000099', 'a0000000-0000-0000-0000-000000000003', 'todos')$$,
  'Usuário só de sucessão não recebe acesso no ERP', 'master: usuário só de sucessão não recebe modelo de acesso');
insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values ('00000000-0000-0000-0000-000000000097', '00000000-0000-0000-0000-000000000097', 'Familiar 2', 'leitura', true);
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values ('00000000-0000-0000-0000-000000000095', 'f3', 'Familiar 3', 'leitura', true)$$,
  'Só o master cria e muda usuário de sucessão', 'S-081: o administrador não cria usuário de sucessão');
select pg_temp.erro_igual($$update erp.usuarios set nome = 'x' where id = '00000000-0000-0000-0000-000000000097'$$,
  'Só o master cria e muda usuário de sucessão', 'S-081: o administrador não mexe em usuário de sucessão');
select pg_temp.erro_igual(format($$update erp.usuarios set so_sucessao = true, papel = 'leitura' where id = %L$$, :'leitor'),
  'Só o master cria e muda usuário de sucessão', 'S-081: o administrador não marca ninguém como sucessor');
select pg_temp.erro_igual($$update erp.usuarios set so_sucessao = false where id = '00000000-0000-0000-0000-000000000097'$$,
  'Só o master cria e muda usuário de sucessão', 'S-081: o administrador não tira a marca de sucessor (para depois dar acesso)');
select pg_temp.como(null);
select pg_temp.erro_igual($$update erp.usuarios set administrador = true where id = '00000000-0000-0000-0000-000000000097'$$,
  'new row for relation "usuarios" violates check constraint "usuarios_check"', 'master: usuário só de sucessão não vira administrador');

-- sucessão: sem prazo para a unanimidade; da unanimidade, 7 dias para o veto, com avisos
select pg_temp.como(:'leitor');
select erp.pedir_sucessao_master(:'diretor2', 'Moises indisponível') as suc1 \gset
select pg_temp.ok((select unanime_em is null and vale_em is null
                     and aprovadores = array(select unnest(array[:'leitor'::uuid, :'analista'::uuid, '00000000-0000-0000-0000-000000000099'::uuid]) order by 1)
                   from erp.sucessoes_master where id = :'suc1'),
  'master: todo o grupo aprova (menos o master e o novo master), sem prazo correndo antes da unanimidade');
select pg_temp.como(null); select erp.gerar_avisos_sucessao(); select pg_temp.como(:'leitor');
select pg_temp.sis();  -- os avisos da sucessão só o sistema lê
select pg_temp.ok(not exists (select 1 from erp.avisos_sucessao where sucessao_id = :'suc1'), 'master: sem unanimidade, nenhum aviso ainda');
select pg_temp.volta();
select pg_temp.como(:'analista'); select erp.decidir_sucessao_master(:'suc1', true);
select pg_temp.erro_igual(format($$select erp.efetivar_sucessao_master(%L)$$, :'suc1'),
  'A sucessão precisa da aprovação de todo o grupo de sucessão', 'master: sem o grupo inteiro, não há sucessão');
select pg_temp.como('00000000-0000-0000-0000-000000000099');
select erp.decidir_sucessao_master(:'suc1', true);
select pg_temp.ok((select unanime_em is not null and vale_em is null from erp.sucessoes_master where id = :'suc1'),
  'S-083: a unanimidade não começa o prazo; ele espera o primeiro aviso enviado');
select pg_temp.sis();  -- os avisos da sucessão só o sistema lê
select pg_temp.ok((select count(*) = 2 and bool_and(para = :'diretor'::uuid) from erp.avisos_sucessao where sucessao_id = :'suc1'),
  'master: a unanimidade já gera o aviso ao master (e-mail e WhatsApp)');
select pg_temp.volta();
select pg_temp.falha($$select erp.gerar_avisos_sucessao()$$, 'master: gerar os avisos é rotina do servidor, sem EXECUTE para a API');
select pg_temp.sis(); select erp.gerar_avisos_sucessao(); select pg_temp.volta();
select pg_temp.sis();  -- os avisos da sucessão só o sistema lê
select pg_temp.ok((select count(*) = 2 from erp.avisos_sucessao where sucessao_id = :'suc1'), 'master: um aviso por turno e canal, sem repetir');
select pg_temp.volta();
select pg_temp.erro_igual(format($$select erp.efetivar_sucessao_master(%L)$$, :'suc1'),
  'O prazo da sucessão só corre depois do primeiro aviso enviado ao master', 'S-083: sem aviso enviado, a sucessão não vale');
select pg_temp.erro_igual(format($$select erp.vetar_sucessao_master(%L)$$, :'suc1'),
  'Só o master veta a sucessão', 'master: só o master veta');
-- veto de um clique pelo link do aviso (o servidor chama, sem login)
select pg_temp.como(null);
select pg_temp.sis();  -- os avisos da sucessão só o sistema lê
\set tok 'b1e3c0a5d9f84e27a6c4b8d2e0f1a3c5b7d9e1f3a5c7e9b1'
select dia as av_dia, turno as av_turno from erp.avisos_sucessao where sucessao_id = :'suc1' and canal = 'whatsapp' \gset
select pg_temp.volta();
select pg_temp.erro_igual(format($$select erp.registrar_envio_aviso(%L, %L, %L, 'whatsapp', 'curto')$$, :'suc1', :'av_dia', :'av_turno'),
  'O token do link precisa ter pelo menos 32 caracteres', 'master: o token do link é longo');
select erp.registrar_envio_aviso(:'suc1', :'av_dia', :'av_turno', 'whatsapp', :'tok');
select pg_temp.sis();  -- os avisos da sucessão só o sistema lê
select pg_temp.ok((select enviado_em is not null and token_hash = erp.hash_token(:'tok') and token_hash <> :'tok'
                   from erp.avisos_sucessao where sucessao_id = :'suc1' and canal = 'whatsapp'),
  'master: o envio fica registrado e o banco guarda só o hash do token');
select pg_temp.volta();
select pg_temp.ok((select vale_em::date = current_date + 7 from erp.sucessoes_master where id = :'suc1'),
  'S-083: o primeiro aviso enviado começa os 7 dias');
select vale_em as vale1 from erp.sucessoes_master where id = :'suc1' \gset
select erp.registrar_envio_aviso(:'suc1', :'av_dia', :'av_turno', 'email', 'c2f4e6a8b0d2f4a6c8e0b2d4f6a8c0e2d4f6a8');
select pg_temp.ok((select vale_em = :'vale1'::timestamptz from erp.sucessoes_master where id = :'suc1'),
  'S-083: os avisos seguintes não mudam o prazo');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.efetivar_sucessao_master(%L)$$, :'suc1'),
  (select format('A sucessão só vale depois de %s', vale_em) from erp.sucessoes_master where id = :'suc1'), 'master: a sucessão não vale antes dos 7 dias');
select pg_temp.como(null);
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.vetar_sucessao_por_link(%L)$$, :'tok'), 'Só o servidor recebe o veto pelo link', 'master: o veto pelo link é só pelo servidor');
select pg_temp.erro_igual(format($$select erp.registrar_envio_aviso(%L, %L, %L, 'email', %L)$$, :'suc1', :'av_dia', :'av_turno', :'tok'),
  'Só o servidor registra o envio do aviso', 'master: só o servidor registra o envio');
select pg_temp.como(null);
select pg_temp.erro_igual($$select erp.vetar_sucessao_por_link('nao-e-um-token')$$, 'Link inválido ou sucessão já encerrada', 'master: link inválido não veta');
select erp.vetar_sucessao_por_link(:'tok');
select pg_temp.ok((select situacao = 'vetada' from erp.sucessoes_master where id = :'suc1'), 'master: o link do aviso veta a sucessão');
select pg_temp.erro_igual(format($$select erp.vetar_sucessao_por_link(%L)$$, :'tok'), 'Link inválido ou sucessão já encerrada', 'master: o link não vale de novo');
-- veto pelo master logado
select pg_temp.como(:'leitor');
select erp.pedir_sucessao_master(:'diretor2', 'Moises indisponível') as suc4 \gset
select pg_temp.como(:'diretor');
select erp.vetar_sucessao_master(:'suc4');
select pg_temp.ok((select situacao = 'vetada' from erp.sucessoes_master where id = :'suc4'), 'master: o master atual veta a sucessão');
-- sucessão até o fim
select pg_temp.como(:'analista');
select erp.pedir_sucessao_master(:'diretor2', 'Moises indisponível') as suc2 \gset
select pg_temp.como(:'leitor'); select erp.decidir_sucessao_master(:'suc2', true);
select pg_temp.como('00000000-0000-0000-0000-000000000099'); select erp.decidir_sucessao_master(:'suc2', true);
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.decidir_sucessao_master(%L, true)$$, :'suc2'),
  'Só o grupo de sucessão da hora do pedido decide a sucessão', 'master: o master atual não vota na própria sucessão');
select pg_temp.como(null);
update erp.sucessoes_master set vale_em = now() - interval '1 second' where id = :'suc2';
select pg_temp.como(:'analista');
select erp.efetivar_sucessao_master(:'suc2');
select pg_temp.ok((select user_id = :'diretor2'::uuid from erp.master) and (select situacao = 'aplicada' from erp.sucessoes_master where id = :'suc2'),
  'master: passados os 7 dias da unanimidade, sem veto, o novo master assume');
select pg_temp.como(:'diretor2');
select erp.passar_master(:'diretor', 'Moises voltou');
select pg_temp.ok((select user_id = :'diretor'::uuid from erp.master), 'master: o master passa o papel na hora');
rollback;
select pg_temp.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'erp' and c.relkind in ('r', 'p')
    and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and (t.tgtype & 32) = 32 and (t.tgtype & 2) = 2)),
  'catálogo: toda tabela do `erp` recusa TRUNCATE');
select pg_temp.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'erp' and p.prosecdef
    and p.proowner in ('erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole, 'erp_acesso'::regrole)
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

-- ---------------------------------------------------------------------
\echo '# quem vê e quem não vê: perfis por núcleo × centro × natureza, PJ isolado'
begin;
select pg_temp.sis();
delete from erp.atribuicao_nucleos; delete from erp.atribuicao_tipos; delete from erp.atribuicoes;   -- só o acesso montado aqui
\set u1 'b0000000-0000-0000-0000-000000000001'
\set u2 'b0000000-0000-0000-0000-000000000002'
\set u3 'b0000000-0000-0000-0000-000000000003'
\set u4 'b0000000-0000-0000-0000-000000000004'
\set u5 'b0000000-0000-0000-0000-000000000005'
\set u6 'b0000000-0000-0000-0000-000000000006'
\set u7 'b0000000-0000-0000-0000-000000000007'
\set u8 'b0000000-0000-0000-0000-000000000008'
\set u9 'b0000000-0000-0000-0000-000000000009'
\set u10 'b0000000-0000-0000-0000-000000000010'
insert into erp.usuarios (id, login_id, nome, papel, ativo, so_sucessao) values
  (:'u1', :'u1', 'Leitor Mkt', 'analista', true, false),
  (:'u2', :'u2', 'Restrito Mkt', 'analista', true, false),
  (:'u3', :'u3', 'Obra VM', 'analista', true, false),
  (:'u4', :'u4', 'Mkt com PJ', 'analista', true, false),
  (:'u5', :'u5', 'Sem perfil', 'analista', true, false),
  (:'u6', :'u6', 'Inativo', 'analista', false, false),
  (:'u7', :'u7', 'AD sem perfil', 'analista', true, false),
  (:'u8', :'u8', 'Só sucessão', 'leitura', true, true),
  (:'u9', :'u9', 'Mkt sem PJ', 'analista', true, false),
  (:'u10', :'u10', 'Leitura com perfil', 'leitura', true, false);
update erp.usuarios set ativo = true where id in (:'u1', :'u2', :'u3', :'u4', :'u5', :'u7', :'u8', :'u9', :'u10');
update erp.usuarios set ativo = false where id = :'u6';
insert into erp.naturezas (codigo, mae_id, nome, restrita) values ('06.07', pg_temp.nat('06'), 'Folha PJ (teste)', true);
insert into erp.perfis_modelo (id, nome) values
  ('a1000000-0000-0000-0000-000000000001', 'V leitor Mkt'), ('a1000000-0000-0000-0000-000000000002', 'V restrito Mkt'),
  ('a1000000-0000-0000-0000-000000000003', 'V obra'), ('a1000000-0000-0000-0000-000000000004', 'V Mkt com PJ'),
  ('a1000000-0000-0000-0000-000000000009', 'V Mkt');
insert into erp.perfil_centros values
  ('a1000000-0000-0000-0000-000000000001', :'cc_mkt', 'leitor'), ('a1000000-0000-0000-0000-000000000002', :'cc_mkt', 'lancador_restrito'),
  ('a1000000-0000-0000-0000-000000000003', :'cc_obra', 'lancador'), ('a1000000-0000-0000-0000-000000000004', :'cc_mkt', 'lancador'),
  ('a1000000-0000-0000-0000-000000000009', :'cc_mkt', 'lancador');
insert into erp.perfil_naturezas values ('a1000000-0000-0000-0000-000000000004', pg_temp.nat('06.07'));
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values
  ('a2000000-0000-0000-0000-000000000001', :'u1', 'a1000000-0000-0000-0000-000000000001', 'todos'),
  ('a2000000-0000-0000-0000-000000000002', :'u2', 'a1000000-0000-0000-0000-000000000002', 'todos'),
  ('a2000000-0000-0000-0000-000000000003', :'u3', 'a1000000-0000-0000-0000-000000000003', 'lista'),
  ('a2000000-0000-0000-0000-000000000004', :'u4', 'a1000000-0000-0000-0000-000000000004', 'todos'),
  ('a2000000-0000-0000-0000-000000000009', :'u9', 'a1000000-0000-0000-0000-000000000009', 'todos'),
  ('a2000000-0000-0000-0000-000000000010', :'u10', 'a1000000-0000-0000-0000-000000000009', 'todos');
insert into erp.atribuicao_nucleos values ('a2000000-0000-0000-0000-000000000003', :'ne_vm', true);
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'u7'), ('AO', :'u4');   -- quem paga é o financeiro (S-091)
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.pessoas (id, tipo, nome, documento) values ('10000000-0000-0000-0000-0000000000c1', 'juridica', 'Fornecedor V', '12121212000112');
select pg_temp.volta();

-- títulos, cada um lançado por quem tem o acesso
\set ta 'c1000000-0000-0000-0000-0000000000a1'
\set tb 'c1000000-0000-0000-0000-0000000000b1'
\set tc 'c1000000-0000-0000-0000-0000000000c1'
\set td 'c1000000-0000-0000-0000-0000000000d1'
\set te 'c1000000-0000-0000-0000-0000000000e1'
create function pg_temp.tit(u uuid, t uuid, emp uuid, val numeric, linhas jsonb) returns void language plpgsql as $f$
declare l jsonb;
begin
  perform pg_temp.como(u::text);
  insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
  values (t, emp, 'avulso', '10000000-0000-0000-0000-0000000000c1', '2027-09-05', '2027-09-01', val);
  insert into erp.parcelas (id, titulo_id, numero, vencimento, valor) values (t, t, 1, '2027-10-10', val);
  for l in select * from jsonb_array_elements(linhas) loop
    insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
    values (t, (l->>'n')::uuid, (l->>'c')::uuid, pg_temp.nat(l->>'nat'), (l->>'p')::numeric);
  end loop;
end $f$;
select pg_temp.tit(:'u2', :'ta', :'incorp', 1000, jsonb_build_array(jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '05.01.04', 'p', 100)));
select pg_temp.tit(:'u9', :'tb', :'incorp', 40000, jsonb_build_array(jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '05.01.04', 'p', 100)));
select pg_temp.tit(:'u3', :'tc', :'spe', 3000, jsonb_build_array(jsonb_build_object('n', :'ne_vm', 'c', :'cc_obra', 'nat', '04.01', 'p', 100)));
select pg_temp.tit(:'u4', :'td', :'incorp', 20000, jsonb_build_array(jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '06.07', 'p', 100)));
select pg_temp.tit(:'u4', :'te', :'incorp', 2000, jsonb_build_array(
  jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '05.01.04', 'p', 50), jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '06.07', 'p', 50)));
select pg_temp.ok(true, 'acesso: cada um lança o título nas linhas em que lança');

create function pg_temp.vejo_tits() returns text language sql as $$
  select coalesce(string_agg(upper(substr(id::text, 35, 1)), '' order by id::text), '')
    from erp.titulos where id::text like 'c1000000-%' $$;
select pg_temp.como(:'u1'); select pg_temp.ok(pg_temp.vejo_tits() = 'AB', 'acesso: o leitor do Marketing vê os títulos do Marketing, sem o que tem linha PJ (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.como(:'u2'); select pg_temp.ok(pg_temp.vejo_tits() = 'A', 'acesso: o lançador restrito vê só o que ele lançou (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.como(:'u3'); select pg_temp.ok(pg_temp.vejo_tits() = 'C', 'acesso: quem tem a Obra da Vila Maria não vê o Marketing (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.como(:'u4'); select pg_temp.ok(pg_temp.vejo_tits() = 'ABDE', 'acesso: com a natureza PJ liberada, vê o PJ do centro (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.como(:'u9'); select pg_temp.ok(pg_temp.vejo_tits() = 'AB', 'acesso: lançador do Marketing sem PJ não vê o título PJ nem o que mistura PJ (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.como(:'u5'); select pg_temp.ok(pg_temp.vejo_tits() = '' and not exists (select 1 from erp.lancamentos) and not exists (select 1 from erp.parcelas),
  'acesso: sem perfil, não vê título, parcela nem livro');
select pg_temp.como(:'u1');
select pg_temp.ok(not exists (select 1 from erp.parcelas where titulo_id = :'tc') and not exists (select 1 from erp.titulo_rateios where titulo_id in (:'tc', :'td', :'te')),
  'acesso: as parcelas e o rateio seguem o título');
select pg_temp.ok(erp.parcela_saldo(:'tc') is null, 'acesso: o saldo da parcela que não vê volta vazio');
select pg_temp.falha(format($$select * from erp.acesso(%L, %L, %L)$$, :'u3', :'ne_vm', :'cc_obra'), 'acesso: o usuário não consulta o acesso de outra pessoa');
select pg_temp.ok(not exists (select 1 from erp.auditoria), 'acesso: a auditoria é só do administrador');
select pg_temp.ok((select count(*) = 1 from erp.atribuicoes) and (select user_id = :'u1'::uuid from erp.atribuicoes),
  'acesso: cada um vê só a própria atribuição');

-- gravar: só onde lança
select pg_temp.falha(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values (%L, %L, %L, %L, 10)$$,
  :'ta', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04')), 'acesso: o leitor não lança no rateio');
select pg_temp.como(:'u3');
select pg_temp.falha(format($$update erp.titulo_rateios set centro_custo_id = %L, natureza_id = %L where titulo_id = %L$$, :'cc_mkt', pg_temp.nat('05.01.04'), :'tc'),
  'acesso: não leva a linha para um centro onde não lança');
select pg_temp.falha(format($$update erp.titulo_rateios set percentual = 100 where titulo_id = %L$$, :'ta'), 'acesso: não mexe no rateio de título que não vê');
select pg_temp.falha(format($$select erp.confirmar_titulo(%L)$$, :'ta'), 'acesso: não confirma título que não vê');
select pg_temp.como(:'u2');
select pg_temp.falha(format($$update erp.titulo_rateios set percentual = 100 where titulo_id = %L$$, :'tb'),
  'acesso: o lançador restrito não mexe no rateio que outra pessoa lançou, mesmo no centro dele');
select pg_temp.erro_igual(format($$select erp.confirmar_titulo(%L)$$, :'tb'), 'Você não lança em todas as linhas deste título',
  'acesso: o lançador restrito não confirma o título que outra pessoa lançou');
select pg_temp.como(:'u10');
select pg_temp.falha($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000002', 'avulso', '10000000-0000-0000-0000-0000000000c1', '2027-09-05', '2027-09-01', 10)$$,
  'acesso: papel leitura não grava, mesmo com perfil de lançador');
select pg_temp.como(:'u9');
select pg_temp.erro_igual(format($$select erp.confirmar_titulo(%L)$$, :'te'), 'Você não lança em todas as linhas deste título',
  'acesso: não confirma título com linha onde não lança (mesmo vendo pelo definer)');
select pg_temp.como(:'u6');
select pg_temp.ok(pg_temp.vejo_tits() = '' and not exists (select 1 from erp.pessoas), 'S-087: usuário inativo não lê nada');
select pg_temp.erro_igual($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor)
  values ('20000000-0000-0000-0000-000000000002', 'avulso', '10000000-0000-0000-0000-0000000000c1', '2027-09-05', '2027-09-01', 10)$$,
  'Só quem tem cadastro ativo no ERP grava', 'S-087: usuário inativo não grava');
select pg_temp.como(:'u8');
select pg_temp.ok((select count(*) = 1 from erp.usuarios) and not exists (select 1 from erp.pessoas) and pg_temp.vejo_tits() = '',
  'acesso: quem está só para a sucessão vê o próprio cadastro e nada mais');

-- confirma na ordem: o acumulado do Marketing no mês passa dos 50 mil no título B
select pg_temp.como(:'u2'); select erp.confirmar_titulo(:'ta');
select pg_temp.como(:'u4'); select erp.confirmar_titulo(:'td');
select pg_temp.como(:'u9'); select erp.confirmar_titulo(:'tb');
select pg_temp.como(:'u3'); select erp.confirmar_titulo(:'tc');
select pg_temp.como(:'u1');
select pg_temp.ok(exists (select 1 from erp.lancamentos where titulo_id = :'ta') and not exists (select 1 from erp.lancamentos where titulo_id in (:'tc', :'td')),
  'acesso: no livro, o leitor vê o Marketing e não vê a Obra nem o PJ');
select pg_temp.como(:'u4');
select pg_temp.ok(exists (select 1 from erp.lancamentos where titulo_id = :'td'), 'acesso: com o PJ liberado, vê o PJ no livro');
select pg_temp.como(:'u7');
select pg_temp.ok(pg_temp.vejo_tits() = 'B', 'acesso: quem aprova na AD vê o título da alçada dele, e só ele (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.ok((select count(*) = 2 and count(*) filter (where titulo_id = :'tb') = 1
                     and bool_or(titulo_id is null and pessoa = 'Outros 2 títulos (sem acesso)' and valor_no_centro = 21000 and empresa_id is null)
                   from erp.titulos_do_acumulado(:'tb')),
  'S-062: no acumulado, quem aprova vê em detalhe o que vê e o resto numa linha só, com a soma');
select pg_temp.como(:'u3');
select pg_temp.erro_igual(format($$select erp.pedir_reclassificacao(%L, %L, 'x')$$, pg_temp.nat('05.01.04'), pg_temp.nat('05.01.02')),
  'O pedido leva lançamentos fora do seu acesso (núcleo, centro ou natureza); filtre pelo que você lança',
  'acesso: a reclassificação não leva lançamento fora do acesso de quem pede');
select pg_temp.erro_igual(format($$select erp._registrar_ajuste(%L, 'titulo_rateios', null, null)$$, :'tc'), 'O ajuste só se registra pela mudança na tabela',
  'acesso: o rastro do ajuste não se forja chamando a função direto');
-- S-073: o gestor da área pede revisão do B, mas não lança no Marketing: não ajusta
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo(:'tb', false, 'conferir a natureza', true) = 'revisao', 'S-073: o gestor da área pede a revisão');
select pg_temp.ok(not erp.pode_ajustar(:'tb'), 'S-073: o gestor da área que não lança nas linhas do título não ajusta');
select pg_temp.erro_igual(format($$update erp.titulos set descricao = 'x' where id = %L$$, :'tb'), 'Título confirmado não se edita',
  'S-073: nem pela tabela');
select pg_temp.como(:'u9');
select pg_temp.ok(erp.pode_ajustar(:'tb'), 'S-073: quem lançou e lança nas linhas ajusta');
-- sucessão: quem está fora do grupo não vê nem efetiva
select pg_temp.sis();
insert into erp.grupo_sucessao (user_id) values (:'u5');
select pg_temp.como(:'u5');
select erp.pedir_sucessao_master(:'diretor2', 'teste de acesso') as suc_v \gset
select pg_temp.como(:'u1');
select pg_temp.ok(not exists (select 1 from erp.grupo_sucessao) and not exists (select 1 from erp.sucessoes_master),
  'acesso: quem está fora do grupo de sucessão não vê o grupo nem os pedidos');
select pg_temp.erro_igual(format($$select erp.efetivar_sucessao_master(%L)$$, :'suc_v'),
  'Só o grupo de sucessão ou o indicado efetivam a sucessão', 'acesso: quem está fora do grupo não efetiva a sucessão');
-- pagamento carimbado no Marketing que quita o título PJ: some para quem não vê o PJ
select pg_temp.como(:'gestor'); select erp.decidir_titulo(:'td', true);
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'contador'); select erp.decidir_titulo(:'td', true);
select pg_temp.como(:'u4');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('c2000000-0000-0000-0000-0000000000d1', :'incorp', :'conta_inc', '10000000-0000-0000-0000-0000000000c1', :'ne_corp', :'cc_mkt', '2027-10-10', 20000);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('c2000000-0000-0000-0000-0000000000d1', :'td', 20000);
select pg_temp.ok(exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1'), 'acesso: quem tem o PJ vê o pagamento do PJ');
select pg_temp.como(:'u9');
select pg_temp.ok(not exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1')
                  and not exists (select 1 from erp.quitacoes where pagamento_id = 'c2000000-0000-0000-0000-0000000000d1'),
  'acesso: o pagamento que quita título PJ some para quem vê o centro mas não o PJ');
-- S-093: cada trava das políticas com o seu teste
select pg_temp.como(:'u7');
select pg_temp.ok(not erp.vejo(null, null, pg_temp.nat('06.07'), null) and erp.vejo(null, null, pg_temp.nat('05.01.04'), null),
  'acesso: linha sem núcleo e centro de natureza restrita fica fechada até para o financeiro, sem liberação');
select pg_temp.como(:'u5');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('c1000000-0000-0000-0000-0000000000f1', :'incorp', 'avulso', '10000000-0000-0000-0000-0000000000c1', '2027-09-05', '2027-09-01', 10);
select pg_temp.ok(exists (select 1 from erp.titulos where id = 'c1000000-0000-0000-0000-0000000000f1'), 'acesso: quem lançou vê o título ainda sem rateio');
select pg_temp.sis();
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('c1000000-0000-0000-0000-0000000000f1', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.volta();
select pg_temp.ok(not exists (select 1 from erp.titulos where id = 'c1000000-0000-0000-0000-0000000000f1'),
  'acesso: com o rateio num centro que ele não vê, quem lançou deixa de ver o título');
select pg_temp.como(:'u4');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('c3000000-0000-0000-0000-000000000001', :'incorp', '10000000-0000-0000-0000-0000000000c1', 'nfse', 'V1', '2027-09-05', '2027-09-01', 100);
select pg_temp.como(:'u9');
select pg_temp.falha(format($$insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values ('c3000000-0000-0000-0000-000000000001', %L, %L, %L, 100)$$,
  :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04')), 'acesso: na nota sem rateio de outra pessoa, fora da revisão, ninguém mais lança');
select pg_temp.como(:'u4');
select erp.pedir_reclassificacao(pg_temp.nat('05.01.04'), pg_temp.nat('05.01.02'), 'teste de acesso', jsonb_build_object('de', '2027-09-01', 'ate', '2027-09-01'));
select pg_temp.sis();
insert into erp.excecoes_natureza (user_id, natureza_id, centro_custo_id, efeito) values (:'u4', pg_temp.nat('05.01.03'), :'cc_mkt', 'bloquear');
insert into erp.lotes_bancarios (conta_id) values (:'conta_inc');
insert into erp.mudancas_acesso (tabela, operacao, dados, motivo, pedida_por, minimo) values ('excecoes_natureza', 'incluir', '{}', 'teste', :'ti', 1);
insert into erp.orcamento_versoes (id, empresa_id, tipo, nome, data_base) values ('c4000000-0000-0000-0000-000000000001', :'incorp', 'viabilidade', 'V', '2027-09-01');
select pg_temp.volta();
select pg_temp.como(:'u1');
select pg_temp.ok(not exists (select 1 from erp.reclassificacoes) and not exists (select 1 from erp.reclassificacao_itens),
  'acesso: o pedido de reclassificação de outra pessoa não aparece para quem não pediu, não vota nem é da diretoria');
select pg_temp.ok(not exists (select 1 from erp.excecoes_natureza), 'acesso: a exceção de natureza de outra pessoa não aparece');
select pg_temp.ok(not exists (select 1 from erp.mudancas_acesso), 'acesso: o pedido de mudança de acesso não aparece para quem não pediu, não aprova nem ganha com ele');
select pg_temp.ok(not exists (select 1 from erp.lotes_bancarios), 'acesso: o lote bancário só o financeiro vê');
select pg_temp.falha(format($$insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, valor) values ('c4000000-0000-0000-0000-000000000001', %L, %L, %L, '2027-09-01', -10)$$,
  :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04')), 'acesso: quem só lê o centro não lança linha de orçamento');
select pg_temp.falha(format($$insert into erp.previsoes (empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values (%L, 'manual', '10000000-0000-0000-0000-0000000000c1', %L, %L, %L, '2027-09-01', '2027-09-30', 10)$$,
  :'incorp', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04')), 'acesso: quem só lê o centro não lança previsão');
select pg_temp.como(:'u9');
insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, valor)
values ('c4000000-0000-0000-0000-000000000001', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), '2027-09-01', -10);
insert into erp.previsoes (empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values (:'incorp', 'manual', '10000000-0000-0000-0000-0000000000c1', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), '2027-09-01', '2027-09-30', 10);
select pg_temp.ok(true, 'acesso: quem lança no centro lança orçamento e previsão');
select pg_temp.erro_igual(format($$select erp.pagar_parcela(%L, %L, '2027-10-10')$$, :'tb', :'conta_inc'),
  'Só o financeiro (AF, AO ou AD) registra pagamento', 'S-091: quem lança no centro, fora do financeiro, não paga a parcela');
select pg_temp.falha(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values (%L, %L, '10000000-0000-0000-0000-0000000000c1', %L, %L, '2027-10-10', 100)$$,
  :'incorp', :'conta_inc', :'ne_corp', :'cc_mkt'), 'S-091: nem registra o pagamento direto na tabela');
select pg_temp.como(:'u7');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('c2000000-0000-0000-0000-0000000000a7', :'incorp', :'conta_inc', '10000000-0000-0000-0000-0000000000c1', :'ne_corp', :'cc_mkt', '2027-10-10', 100);
-- sem o vejo_titulo na política, o gatilho da quitação também recusa ("O título não está aberto"):
-- ele lê o título com o acesso de quem paga, e o título PJ não aparece
select pg_temp.falha(format($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('c2000000-0000-0000-0000-0000000000a7', %L, 100)$$, :'td'),
  'acesso: nem o financeiro quita título que não vê (PJ)');
-- S-091: quem vê o adiantamento (o pagamento de 100 no Marketing) e o título, mas não é do
-- financeiro, não abate o adiantamento com uma quitação direta
select pg_temp.como(:'gestor'); select erp.decidir_titulo(:'ta', true);
select pg_temp.como(:'contador'); select erp.decidir_titulo(:'ta', true);
select pg_temp.como(:'u9');
select pg_temp.ok(exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000a7') and pg_temp.vejo_tits() like '%A%',
  'S-091: o lançador do Marketing vê o adiantamento e o título aprovado');
select pg_temp.falha(format($$insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('c2000000-0000-0000-0000-0000000000a7', %L, 100)$$, :'ta'),
  'S-091: quem não é do financeiro não abate adiantamento com quitação direta');
select pg_temp.como(:'diretor2');
select pg_temp.sis(); delete from erp.listas_financeiro where user_id = :'diretor2'; select pg_temp.volta();
select pg_temp.erro_igual(format($$select erp.pagar_parcela(%L, %L, '2027-10-10')$$, :'ta', :'conta_inc'),
  'Só o financeiro (AF, AO ou AD) registra pagamento', 'S-091: diretor fora das listas do financeiro não paga a parcela');
-- papel leitura na AD: a lista não dá o direito de gravar
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'u10'); select pg_temp.volta();
select pg_temp.como(:'u10');
select pg_temp.falha(format($$insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values (%L, 'x')$$, :'tb'),
  'acesso: papel leitura não libera título sem abater, nem estando na AD');
-- S-089: cadastro de pessoas protegido e auditado
select pg_temp.sis();
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000002', 'cliente');
insert into erp.pessoas (id, tipo, nome, documento) values ('10000000-0000-0000-0000-0000000000c2', 'juridica', 'Só pagamento V', '13131313000113');
select pg_temp.volta();
select pg_temp.como(:'u9');
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-0000000000c1', 'fornecedor');
select pg_temp.erro_igual($$insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000003', 'fornecedor')$$,
  'O cadastro de empresa do grupo só o master muda', 'S-089: o analista não põe papel em empresa do grupo');
select pg_temp.erro_igual($$update erp.pessoas set nome = 'Outra' where id = '10000000-0000-0000-0000-000000000001'$$,
  'O cadastro de empresa do grupo só o master muda', 'S-089: o analista não muda o cadastro de empresa do grupo');
select pg_temp.erro_igual($$delete from erp.pessoa_papeis where pessoa_id = '10000000-0000-0000-0000-000000000002'$$,
  'O cadastro de empresa do grupo só o master muda', 'S-089: nem os papéis dela');
select pg_temp.erro_igual($$update erp.pessoas set documento = '98989898000198' where id = '10000000-0000-0000-0000-0000000000c1'$$,
  'Documento, nome, tipo e situação de pessoa já usada só o financeiro muda', 'S-089: o analista não troca o CNPJ de fornecedor já usado');
select pg_temp.erro_igual($$update erp.pessoas set nome = 'Outro nome' where id = '10000000-0000-0000-0000-0000000000c1'$$,
  'Documento, nome, tipo e situação de pessoa já usada só o financeiro muda', 'S-089: nem o nome');
select pg_temp.erro_igual($$update erp.pessoas set ativa = false where id = '10000000-0000-0000-0000-0000000000c1'$$,
  'Documento, nome, tipo e situação de pessoa já usada só o financeiro muda', 'S-089: nem desativa');
select pg_temp.como(:'u7');
insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('20000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-0000000000c2',
   '40000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000002', '2027-10-10', 50);
select pg_temp.como(:'u9');
select pg_temp.erro_igual($$update erp.pessoas set documento = '14141414000114' where id = '10000000-0000-0000-0000-0000000000c2'$$,
  'Documento, nome, tipo e situação de pessoa já usada só o financeiro muda', 'S-089: pessoa usada só num pagamento também conta como usada');
select pg_temp.erro_igual($$delete from erp.pessoa_papeis where pessoa_id = '10000000-0000-0000-0000-0000000000c1' and papel = 'fornecedor'$$,
  'Só o financeiro tira o papel de fornecedor de pessoa já usada', 'S-089: nem tira o papel de fornecedor');
select pg_temp.erro_igual($$update erp.pessoa_papeis set pessoa_id = '10000000-0000-0000-0000-0000000000c2' where pessoa_id = '10000000-0000-0000-0000-0000000000c1' and papel = 'fornecedor'$$,
  'O papel da pessoa não se altera; tire e inclua', 'S-089: o papel de fornecedor não passa para outra pessoa');
select pg_temp.erro_igual($$update erp.pessoa_papeis set pessoa_id = '10000000-0000-0000-0000-0000000000c2' where pessoa_id = '10000000-0000-0000-0000-000000000002'$$,
  'O papel da pessoa não se altera; tire e inclua', 'S-089: nem sai da empresa do grupo');
update erp.pessoas set email = 'contato@fornecedor.test' where id = '10000000-0000-0000-0000-0000000000c1';
select pg_temp.ok(true, 'S-089: o analista muda o contato do fornecedor');
select pg_temp.como(:'u7');
update erp.pessoas set documento = '98989898000198' where id = '10000000-0000-0000-0000-0000000000c1';
select pg_temp.sis();
select pg_temp.ok((select count(*) = 2 from erp.auditoria where tabela = 'pessoas' and registro = '10000000-0000-0000-0000-0000000000c1' and acao = 'update')
                  and exists (select 1 from erp.auditoria where tabela = 'pessoa_papeis' and registro = '10000000-0000-0000-0000-0000000000c1'),
  'S-089: o financeiro troca o CNPJ, e pessoas e papéis ficam na auditoria');
select pg_temp.volta();
-- S-090 (Moises, 15/11: só o master por ora): o TI não muda a configuração de dinheiro e aprovação
select pg_temp.como(:'ti');
select pg_temp.falha($$update erp.regra_adiantamento set trava = false$$, 'S-090: o TI não desliga a trava do adiantamento');
select pg_temp.falha($$update erp.alcadas_pagamento set etapas = '{AREA,AF}' where ate is null$$, 'S-090: o TI não tira o AD da alçada');
select pg_temp.falha($$update erp.regra_alcada_pagamento set acumulado = 'nucleo_centro'$$, 'S-090: nem muda como se soma o acumulado');
select pg_temp.falha(format($$insert into erp.contas_bancarias (empresa_id, banco, agencia, conta) values (%L, 'Itaú', '0001', '77777-7')$$, :'incorp'),
  'S-090: o TI não cadastra conta bancária');
select pg_temp.falha(format($$update erp.contas_bancarias set conta = '00000-0' where id = %L$$, :'conta_inc'), 'S-090: nem troca a conta');
select pg_temp.falha(format($$insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'pessoas', '10000000-0000-0000-0000-0000000000c1', 'X1')$$),
  'S-090: o TI não mexe nos códigos do Sienge');
select pg_temp.falha($$update erp.regras_ajuste set permitido = permitido$$, 'S-090: nem nas regras de ajuste da revisão');
select pg_temp.falha($$update erp.niveis_aprovacao set nome = nome || ' ' where codigo = 'gestor'$$, 'S-090: nem nos níveis de aprovação');
select pg_temp.falha($$insert into erp.alcadas_reclassificacao (criterio, faixa, ate, nivel) values ('acumulado_mes', null, 99999, 'gestor')$$,
  'S-090: nem na alçada da reclassificação');
select pg_temp.falha($$update erp.naturezas_sistema set natureza_id = (select id from erp.naturezas where codigo = '05.01.02') where chave = 'descontos_obtidos'$$,
  'S-090: nem nas naturezas do sistema');
select pg_temp.ok((select trava from erp.regra_adiantamento) and exists (select 1 from erp.alcadas_pagamento where ate is null and 'AD' = any(etapas)),
  'S-090: a trava e o AD continuam');
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set etapas = etapas where ate is null;
select pg_temp.ok(true, 'S-090: o master muda a alçada');
-- quem lançou o pagamento continua vendo, mesmo sem o perfil
select pg_temp.sis(); delete from erp.atribuicoes where user_id = :'u4'; delete from erp.listas_financeiro where user_id = :'u4'; select pg_temp.volta();
select pg_temp.como(:'u4');
select pg_temp.ok(exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1') and pg_temp.vejo_tits() = '',
  'acesso: sem o perfil, quem lançou o pagamento ainda o vê, e não vê mais os títulos');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# configuração de dinheiro: pedido do AF e do AD, aprovadores por tabela, modo livre, eventos'
begin;
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AD', :'diretor2') on conflict do nothing;
insert into erp.aprovadores_config (tabela, user_id) values ('alcadas_pagamento', :'analista2'), ('alcadas_pagamento', :'diretor2');
select id as faixa50 from erp.alcadas_pagamento where ate = 50000 \gset
select id as faixa_topo from erp.alcadas_pagamento where ate is null \gset
select pg_temp.volta();

-- quem pede
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "%s", "ate": 52000}', 'subir')$$, :'faixa50'),
  'Só o AF, o AD, o administrador ou o master pedem mudança na configuração de dinheiro', 'config: quem não é AF, AD, administrador nem master não pede');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "%s", "ate": 52000}', 'subir')$$, :'faixa50'),
  'Só o AF, o AD, o administrador ou o master pedem mudança na configuração de dinheiro', 'config: o AO não pede');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.pedir_mudanca_config('listas_financeiro', 'incluir', '{"lista": "AD", "user_id": "00000000-0000-0000-0000-00000000000e"}', 'eu')$$,
  'A tabela listas_financeiro não é da configuração de dinheiro', 'config: AF, AO e AD não entram por aqui (são acesso)');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "%s", "xpto": 1}', 'x')$$, :'faixa50'),
  'Campo que não existe em alcadas_pagamento', 'config: campo desconhecido é recusado');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "%s", "ate": 52000}', ' ')$$, :'faixa50'),
  'O pedido precisa de motivo', 'config: pedido sem motivo é recusado');
-- a trava da tabela vale já no pedido
select pg_temp.erro_igual($$select erp.pedir_mudanca_config('regras_ajuste', 'excluir', '{"campo": "documento_retencoes.valor", "quem": "AF"}', 'tirar')$$,
  'As regras do ajuste são fixas; altere só se pode e para que lado', 'config: o pedido que a trava da tabela recusa nem nasce');
select pg_temp.ok(not exists (select 1 from erp.mudancas_config), 'config: nenhum pedido ficou das recusas');

-- modo aprovação (padrão): o AF pede, a lista aprova
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 52000), 'reajuste') as m1 \gset
select pg_temp.ok((select aprovacao = 'lista' and minimo = 1 and situacao = 'pendente' from erp.mudancas_config where id = :'m1')
                  and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 50000,
  'config: o pedido do AF fica pendente da lista e a alçada não muda');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m1'), 'Quem pediu a mudança não a aprova', 'config: quem pediu não aprova');
select pg_temp.falha(format($$update erp.mudancas_config set situacao = 'aplicada' where id = %L$$, :'m1'), 'config: o pedido não muda pela API');
select pg_temp.como(:'leitor');
select pg_temp.ok(not exists (select 1 from erp.mudancas_config), 'config: quem não pede nem aprova não vê os pedidos');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m1'), 'Só um aprovador desta configuração decide o pedido',
  'config: nem decide');
select pg_temp.como(:'analista');      -- AO, fora da lista da tabela
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m1'), 'Só um aprovador desta configuração decide o pedido',
  'config: fora da lista da tabela não decide');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, false)$$, :'m1'), 'Recusar o pedido precisa de justificativa',
  'config: recusar pede justificativa');
select erp.decidir_mudanca_config(:'m1', true) as d1 \gset
select pg_temp.ok(:'d1' = 'aplicada' and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 52000,
  'config: o aprovador da lista aprova e a alçada muda');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m1'), 'O pedido já está aplicada', 'config: pedido encerrado não se decide de novo');
select pg_temp.falha($$select * from erp.eventos$$, 'config: os eventos não se leem pela API');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'mudanca_config_pedida' and dados->>'mudanca_id' = :'m1' and por = :'gestor'),
  'config: o pedido vira evento, com quem pediu');
select pg_temp.ok((select count(*) = 1 from erp.eventos e join erp.tipos_evento t on t.codigo = e.tipo
                    where e.tipo = 'alcada_alterada' and t.critico and e.dados->>'mudanca_id' = :'m1' and e.por = :'analista2'
                      and e.dados->>'pedida_por' = :'gestor' and e.dados->'aprovada_por' ? :'analista2'
                      and (e.dados->'antes'->>'ate')::numeric = 50000 and (e.dados->'depois'->>'ate')::numeric = 52000),
  'config: a mudança aplicada vira um evento crítico de alçada, com antes, depois, quem pediu e quem aprovou');
-- os eventos só crescem
select pg_temp.erro_igual($$update erp.eventos set dados = '{}'$$, 'O evento não se altera nem se apaga', 'config: o evento não se altera, nem pelo sistema');
select pg_temp.erro_igual($$delete from erp.eventos$$, 'O evento não se altera nem se apaga', 'config: nem se apaga');
select pg_temp.erro_igual($$insert into erp.eventos (tipo) values ('alcada_alterada')$$, 'Evento só pelo erp.registrar_evento', 'config: evento só pela função');
select pg_temp.volta();

-- recusa e cancelamento
select pg_temp.como(:'diretor2');      -- AD
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 90000), 'subir muito') as m2 \gset
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 80000), 'outra') as m3 \gset
select pg_temp.como(:'analista2');
select erp.decidir_mudanca_config(:'m2', false, 'alto demais') as d2 \gset
select pg_temp.ok(:'d2' = 'recusada' and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 52000,
  'config: a recusa encerra o pedido e nada muda');
select pg_temp.erro_igual(format($$select erp.cancelar_mudanca_config(%L)$$, :'m3'), 'Só quem pediu cancela o pedido pendente', 'config: só quem pediu cancela');
select pg_temp.como(:'diretor2');
select erp.cancelar_mudanca_config(:'m3');
select pg_temp.sis();
select pg_temp.ok((select situacao from erp.mudancas_config where id = :'m3') = 'cancelada'
                  and exists (select 1 from erp.eventos where tipo = 'mudanca_config_encerrada' and dados->>'mudanca_id' = :'m2' and dados->>'situacao' = 'recusada')
                  and exists (select 1 from erp.eventos where tipo = 'mudanca_config_encerrada' and dados->>'mudanca_id' = :'m3' and dados->>'situacao' = 'cancelada'),
  'config: recusa e cancelamento viram evento');
select pg_temp.erro_igual(format($$delete from erp.mudancas_config where id = %L$$, :'m3'), 'O histórico de mudanças da configuração não se apaga',
  'config: o histórico dos pedidos não se apaga');
select pg_temp.volta();

-- obsoleto: a linha mudou depois do pedido
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 60000), 'a') as m4 \gset
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 61000), 'b') as m5 \gset
select pg_temp.como(:'analista2');
select erp.decidir_mudanca_config(:'m4', true);
select erp.decidir_mudanca_config(:'m5', true) as d5 \gset
select pg_temp.ok(:'d5' = 'obsoleta' and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 60000,
  'config: o pedido feito sobre a linha antiga fica obsoleto');

-- mínimo de 2 votos
select pg_temp.como(:'diretor');
update erp.regras_mudanca_config set minimo = 2 where tabela = 'alcadas_pagamento';
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 49000), 'voltar') as m6 \gset
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.decidir_mudanca_config(:'m6', true) = 'pendente', 'config: com mínimo 2, um voto não basta');
select pg_temp.como(:'diretor2');
select erp.decidir_mudanca_config(:'m6', true) as d6 \gset
select pg_temp.ok(:'d6' = 'aplicada' and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 49000,
  'config: o segundo voto aplica');
-- S-095: o voto de quem saiu da lista não conta
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 48000), 'saiu') as m6b \gset
select pg_temp.como(:'analista2');
select erp.decidir_mudanca_config(:'m6b', true);
select pg_temp.como(:'diretor');
delete from erp.aprovadores_config where tabela = 'alcadas_pagamento' and user_id = :'analista2';
insert into erp.aprovadores_config values ('alcadas_pagamento', :'contador');
select pg_temp.como(:'diretor2');
select erp.decidir_mudanca_config(:'m6b', true) as d6b \gset
select pg_temp.ok(:'d6b' = 'pendente', 'S-095: o voto de quem saiu da lista de aprovadores não conta para o mínimo');
select pg_temp.como(:'diretor');
insert into erp.aprovadores_config values ('alcadas_pagamento', :'analista2');
delete from erp.aprovadores_config where tabela = 'alcadas_pagamento' and user_id = :'contador';
select pg_temp.como(:'gestor'); select erp.cancelar_mudanca_config(:'m6b'); select pg_temp.como(:'diretor2');
-- quem pede sai da conta: com o AD pedindo, sobra um aprovador para 2 votos, e decide o master
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 51000), 'c') as m7 \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_config where id = :'m7'), 'config: sem aprovadores bastantes além de quem pede, decide o master');
select pg_temp.sis();
select pg_temp.ok((select falta_aprovadores from erp.mudancas_config where id = :'m7')
                  and exists (select 1 from erp.eventos where tipo = 'mudanca_config_pedida' and dados->>'mudanca_id' = :'m7'
                                 and (dados->>'falta_aprovadores')::boolean and (dados->>'aprovadores_disponiveis')::int = 1
                                 and (dados->>'minimo_da_lista')::int = 2)
                  and not (select falta_aprovadores from erp.mudancas_config where id = :'m6'),
  'config: o aviso diz que foi ao master por falta de aprovadores qualificados (quantos há e quantos a lista pede)');
select pg_temp.volta();
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m7'), 'Só o master decide este pedido', 'config: e a lista não decide');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_mudanca_config(:'m7', true) = 'aplicada', 'config: o voto do master basta');
update erp.regras_mudanca_config set minimo = 1 where tabela = 'alcadas_pagamento';

-- só o master define a lista e o modo
select pg_temp.como(:'gestor');
select pg_temp.falha($$update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 100, meses = 1 where tabela = 'alcadas_pagamento'$$,
  'config: o AF não muda o modo da tabela');
select pg_temp.erro_igual($$update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 100, meses = 1 where tabela = 'alcadas_pagamento'$$,
  'Só o master decide quem aprova a configuração de dinheiro', 'config: nem pelo dono do banco com o login dele');
select pg_temp.falha(format($$insert into erp.aprovadores_config values ('alcadas_pagamento', %L)$$, :'gestor'), 'config: nem se põe na lista');
select pg_temp.como(:'ti');
select pg_temp.falha(format($$delete from erp.aprovadores_config where user_id = %L$$, :'analista2'), 'config: o TI não tira aprovador');
select erp.pedir_mudanca_config('aprovadores_config', 'incluir', jsonb_build_object('tabela', 'contas_bancarias', 'user_id', :'analista2'), 'cobrir férias') as m8 \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_config where id = :'m8'), 'config: o pedido do TI para a lista vai ao master');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_config('aprovadores_config', 'incluir', '{"tabela": "contas_bancarias", "user_id": "%s"}', 'eu')$$, :'ti'),
  'Administrador não aprova nada no ERP', 'config: administrador não entra na lista de aprovadores');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'m8'), 'Só o master decide este pedido', 'config: a lista de aprovadores só com o master');
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_config(:'m8', true);
select pg_temp.ok(exists (select 1 from erp.aprovadores_config where tabela = 'contas_bancarias' and user_id = :'analista2'), 'config: o master aprova e a lista muda');
select pg_temp.falha($$update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 5, meses = 3 where tabela = 'contas_bancarias'$$,
  'config: conta bancária não tem modo livre');
select pg_temp.falha($$update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 5, meses = 3 where tabela = 'regra_alcada_pagamento'$$,
  'config: regra sem valor de faixa também não');
select pg_temp.erro_igual($$update erp.regras_mudanca_config set tabela = 'outra' where tabela = 'contas_bancarias'$$,
  'As tabelas da configuração são fixas; mude só o modo, o percentual, os meses e o mínimo', 'config: as tabelas da regra são fixas');
update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 10, meses = 3 where tabela = 'alcadas_pagamento';
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'regra_config_alterada' and tabela = 'regras_mudanca_config' and por = :'diretor'
                           and not dados ? 'mudanca_id'),
  'config: a mudança direta do master também vira evento');
select pg_temp.volta();

-- modo livre: até 10% de todo valor da faixa nos últimos 3 meses
select pg_temp.sis();
select pg_temp.ok(erp._valor_config_em('alcadas_pagamento', :'faixa50', 'ate', clock_timestamp() - interval '3 months') = 50000,
  'config: o valor de 3 meses atrás vem da auditoria (o de antes da primeira mudança: 50 mil, o da carga)');
-- as mudanças de até aqui ficam de mais de 3 meses atrás: a janela começa limpa, em 51 mil
alter table erp.auditoria disable trigger t_auditoria_guarda;
update erp.auditoria set em = em - interval '4 months' where tabela = 'alcadas_pagamento' and registro = :'faixa50';
alter table erp.auditoria enable trigger t_auditoria_guarda;
select pg_temp.volta();
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 54000), 'livre') as l1 \gset
select pg_temp.ok((select aprovacao = 'livre' and situacao = 'aplicada' and (referencia->>'valor_antes')::numeric = 51000 from erp.mudancas_config where id = :'l1')
                  and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 54000,
  'config: dentro de 10% do valor de 3 meses atrás, o pedido do AF vale na hora');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 57000), 'mais um pouco') as l2 \gset
select pg_temp.ok((select aprovacao = 'lista' and situacao = 'pendente' from erp.mudancas_config where id = :'l2'),
  'config: 6% sobre o de hoje, mas 12% sobre o de 3 meses atrás: pede aprovação (não se fatia)');
select erp.cancelar_mudanca_config(:'l2');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 49000), 'baixar') as l3 \gset
select pg_temp.ok((select aprovacao = 'livre' from erp.mudancas_config where id = :'l3'), 'config: baixar até 10% também é livre');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 46000), 'baixar mais') as l4 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l4'), 'config: abaixo de 10% de algum valor da janela pede aprovação');
select erp.cancelar_mudanca_config(:'l4');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa_topo', 'etapas', '{AREA,AF}'::text[]), 'tirar AD') as l5 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l5') and exists (select 1 from erp.alcadas_pagamento where id = :'faixa_topo' and 'AD' = any(etapas)),
  'config: tirar uma etapa sempre pede aprovação, mesmo no modo livre');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 50000, 'etapas', '{AREA}'::text[]), 'junto') as l6 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l6'), 'config: valor e etapas juntos também pedem aprovação');
select erp.pedir_mudanca_config('alcadas_pagamento', 'incluir', '{"ate": 20000, "etapas": ["AREA"]}', 'faixa nova') as l7 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l7'), 'config: faixa nova pede aprovação');
select erp.pedir_mudanca_config('alcadas_pagamento', 'excluir', jsonb_build_object('id', :'faixa50'), 'tirar faixa') as l8 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l8'), 'config: tirar faixa pede aprovação');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 50000), 'TI') as l9 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l9'), 'config: o pedido do TI nunca é livre');
select pg_temp.como(:'diretor2');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 53000), 'AD') as l10 \gset
select pg_temp.ok((select aprovacao = 'livre' and situacao = 'aplicada' from erp.mudancas_config where id = :'l10'), 'config: o do AD também é livre');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'alcada_alterada' and dados->>'mudanca_id' = :'l10' and dados->>'aprovacao' = 'livre'),
  'config: a mudança livre também avisa (evento crítico de alçada)');
-- a janela anda: as mudanças de mais de 3 meses atrás viram a referência
alter table erp.auditoria disable trigger t_auditoria_guarda;
update erp.auditoria set em = em - interval '4 months' where tabela = 'alcadas_pagamento' and registro = :'faixa50';
alter table erp.auditoria enable trigger t_auditoria_guarda;
select pg_temp.volta();
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 58000), 'janela nova') as l11 \gset
select pg_temp.ok((select aprovacao = 'livre' and (referencia->>'valor_antes')::numeric = 53000 from erp.mudancas_config where id = :'l11'),
  'config: passados os 3 meses, a referência é o valor de 3 meses atrás (53 mil)');
-- S-094: um aperto recente não se desfaz sem aprovação
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set ate = 20000 where id = :'faixa50';
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 58000), 'desfazer') as l11b \gset
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 21000), 'um pouco') as l11c \gset
select pg_temp.ok((select bool_and(aprovacao = 'lista' and situacao = 'pendente') from erp.mudancas_config where id in (:'l11b', :'l11c'))
                  and (select ate from erp.alcadas_pagamento where id = :'faixa50') = 20000,
  'S-094: depois de o master apertar a faixa, o AF não a desfaz nem a mexe no modo livre (a até 10% de todo valor da janela)');
select erp.cancelar_mudanca_config(:'l11b'); select erp.cancelar_mudanca_config(:'l11c');
-- faixa que não existia há 3 meses: sem referência, pede aprovação
select pg_temp.sis(); insert into erp.alcadas_pagamento (ate, etapas) values (10000, '{AREA}'); select pg_temp.volta();
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', (select id from erp.alcadas_pagamento where ate = 10000), 'ate', 10500), 'nova') as l12 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l12'), 'config: faixa criada dentro da janela não tem referência: pede aprovação');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'alcada_alterada' and por is null and (dados->'depois'->>'ate')::numeric = 10000),
  'config: a mudança feita pelo sistema também vira evento de alçada');
insert into erp.aprovadores_config (tabela, user_id) values ('contas_bancarias', :'contador');
select pg_temp.volta();
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_config(%L, true)$$, :'l12'), 'Só um aprovador desta configuração decide o pedido',
  'config: aprovador de outra tabela não decide o pedido da alçada');
select pg_temp.como(:'diretor2');

-- conta bancária e código do Sienge: sempre aprovação
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('contas_bancarias', 'alterar', jsonb_build_object('id', :'conta_inc', 'conta', '99999-9'), 'troca') as c1 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'c1')
                  and (select conta from erp.contas_bancarias where id = :'conta_inc') is distinct from '99999-9',
  'config: trocar a conta bancária pede aprovação');
select pg_temp.como(:'analista2');
select erp.decidir_mudanca_config(:'c1', true);
select pg_temp.ok((select conta from erp.contas_bancarias where id = :'conta_inc') = '99999-9', 'config: aprovada, a conta muda');
select pg_temp.como(:'gestor');
select erp.pedir_mudanca_config('codigos_externos', 'incluir', '{"sistema": "sienge", "tabela": "pessoas", "registro_id": "10000000-0000-0000-0000-000000000005", "codigo": "X77"}', 'credor') as c2 \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_config where id = :'c2'), 'config: código do Sienge sem lista na tabela vai ao master');
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_config(:'c2', true);
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'conta_bancaria_alterada' and dados->>'mudanca_id' = :'c1')
                  and exists (select 1 from erp.eventos where tipo = 'codigo_externo_alterado' and dados->>'mudanca_id' = :'c2' and por = :'diretor'),
  'config: conta e código mudados viram eventos críticos');
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'pessoas', '10000000-0000-0000-0000-000000000007', 'X78');
select pg_temp.ok(not exists (select 1 from erp.eventos where tipo = 'codigo_externo_alterado' and registro like '%X78'),
  'config: o código gravado pelo sistema (adaptador do Sienge) não vira evento');
select pg_temp.volta();

-- tipos de evento: só o master
select pg_temp.como(:'ti');
select pg_temp.falha($$update erp.tipos_evento set critico = false where codigo = 'alcada_alterada'$$, 'config: o TI não tira o crítico do evento de alçada');
select pg_temp.erro_igual($$update erp.tipos_evento set critico = false where codigo = 'alcada_alterada'$$, 'Só o master muda os tipos de evento',
  'config: nem pelo dono do banco com o login dele');
select pg_temp.como(null);
rollback;

\echo '# alçada por centro de custo: limite do título e do acumulado, vagas por papel ou pessoa, paralelo, falta de aprovadores'
begin;
create function pg_temp.tit(p_id uuid, p_cc uuid, p_nat text, p_valor numeric) returns void language sql as $$
  insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
    (p_id, '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', p_valor);
  insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (p_id, 1, '2026-09-20', p_valor);
  insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values (p_id, '40000000-0000-0000-0000-000000000001', p_cc, pg_temp.nat(p_nat), 100);
  select erp.confirmar_titulo(p_id); $$;
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor');
insert into erp.centro_diretores (centro_custo_id, user_id) values (:'cc_mkt', :'diretor2');
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador');
-- as vagas: papel conhecido ou pessoa que pode aprovar, cada pessoa numa vaga só
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, etapas) values (%L, 1, '{AREA,XX}')$$, :'cc_mkt'),
  'Vaga de aprovação inválida: XX (use AREA, DIRETOR_AREA, AF, AO, AD ou P: e o usuário)', 'alçada por centro: vaga com código desconhecido é recusada');
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, etapas) values (%L, 1, array['P:' || %L])$$, :'cc_mkt', :'ti'),
  'Administrador não aprova nada no ERP', 'alçada por centro: o administrador não ocupa vaga');
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, etapas) values (%L, 1, array['P:' || %L, 'AF', 'P:' || %L])$$, :'cc_mkt', :'analista2', :'analista2'),
  'A mesma pessoa não ocupa duas vagas da faixa', 'alçada por centro: a mesma pessoa não ocupa duas vagas');
select pg_temp.falha(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, etapas) values (%L, 1, '{P:99999999-0000-0000-0000-000000000000}')$$, :'cc_mkt'),
  'alçada por centro: pessoa que não existe não ocupa vaga');
-- Marketing: até 2 mil no título e 10 mil no mês, 1 aprovador; até 100 mil e 200 mil, 2 em paralelo;
-- acima, gestor, diretor da área e AF em sequência. Obra: até 5 mil, uma pessoa pelo nome; acima, AF e outra pessoa.
insert into erp.alcadas_pagamento (id, centro_custo_id, ate, ate_titulo, etapas, paralelo) values
  ('86000000-0000-0000-0000-000000000001', :'cc_mkt', 10000, 2000, '{AREA}', false),
  ('86000000-0000-0000-0000-000000000002', :'cc_mkt', 200000, 100000, '{AF,AREA}', true),
  ('86000000-0000-0000-0000-000000000003', :'cc_mkt', null, null, '{AREA,DIRETOR_AREA,AF}', false),
  ('86000000-0000-0000-0000-000000000004', :'cc_obra', null, 5000, array['P:' || :'analista2'], false),
  ('86000000-0000-0000-0000-000000000005', :'cc_obra', null, null, array['AF', 'P:' || :'contador'], false);
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000001', :'cc_mkt', '05.01.04', 1500);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000001' and etapas = '{AREA}' and not falta_aprovadores
                     from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000001'),
  'alçada por centro: o centro com faixas próprias usa as dele (1 aprovador até 2 mil)');
select pg_temp.tit('84000000-0000-0000-0000-000000000002', :'cc_mkt', '05.01.04', 3000);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000002' and paralelo from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000002'),
  'alçada por centro: o valor do título passa do limite e sobe de faixa, mesmo com o acumulado baixo');
select pg_temp.tit('84000000-0000-0000-0000-000000000003', :'cc_mkt', '05.01.04', 6000);
select pg_temp.tit('84000000-0000-0000-0000-000000000004', :'cc_mkt', '05.01.04', 1000);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000002' and acumulado > 10000 from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000004'),
  'alçada por centro: título pequeno com o acumulado acima do limite também sobe (vale o mais exigente)');
-- o gestor não sai enquanto a vaga dele espera, mesmo que não seja a da vez (os outros títulos
-- já passaram por ele)
select pg_temp.como(:'gestor');
select erp.decidir_titulo('84000000-0000-0000-0000-000000000001', true);
select erp.decidir_titulo('84000000-0000-0000-0000-000000000003', true);
select erp.decidir_titulo('84000000-0000-0000-0000-000000000004', true);
select pg_temp.sis();
select pg_temp.erro_igual(format($$delete from erp.centro_aprovadores where centro_custo_id = %L and user_id = %L$$, :'cc_mkt', :'gestor'),
  'O centro tem títulos esperando o gestor da área; cadastre outro gestor antes', 'alçada por centro: o gestor com vaga pendente em paralelo não sai do centro');
select pg_temp.volta();
-- em paralelo: o gestor (segunda vaga) aprova antes do AF
select pg_temp.como(:'gestor');
select erp.decidir_titulo('84000000-0000-0000-0000-000000000002', true) as r_par \gset
select pg_temp.ok(:'r_par' = 'pendente'
                  and exists (select 1 from erp.titulo_aprovacoes where titulo_id = '84000000-0000-0000-0000-000000000002' and etapa = 2 and por = :'gestor'),
  'alçada por centro: em paralelo, o gestor aprova a vaga dele antes da vaga do AF');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000002', true)$$,
  'Você já aprovou uma etapa deste título', 'alçada por centro: em paralelo, a mesma pessoa não aprova duas vagas');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000002', true) = 'aprovado', 'alçada por centro: em paralelo, com as duas vagas, o título fica aprovado');
-- em sequência, com o diretor da área
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000005', :'cc_mkt', '05.01.04', 150000);
select pg_temp.ok((select cardinality(etapas) = 3 and not paralelo and not falta_aprovadores from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000005'),
  'alçada por centro: acima de 100 mil, três aprovadores em sequência');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true)$$,
  'Esta etapa é do gestor da área', 'alçada por centro: em sequência, o AF espera a vez');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true);
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true)$$,
  'Esta etapa é do diretor da área', 'alçada por centro: a vaga do diretor da área é só dele');
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.aprovo_titulo('84000000-0000-0000-0000-000000000005'), 'alçada por centro: o diretor da área vê o título');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true) = 'pendente',
  'alçada por centro: o diretor da área aprova a vaga dele');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true) = 'aprovado', 'alçada por centro: o AF fecha a sequência');
-- Obra: o centro sem gestor entra na alçada pelas faixas próprias; a vaga de uma pessoa pelo nome
select pg_temp.como(:'diretor'); update erp.usuarios set ativo = false where id = :'analista2';
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000014', :'cc_obra', '04.01', 100);
select pg_temp.ok((select falta_aprovadores from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000014'),
  'alçada por centro: usuário inativo não ocupa a vaga');
select pg_temp.como(:'diretor'); update erp.usuarios set ativo = true where id = :'analista2';
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000011', :'cc_obra', '04.01', 4000);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000004' and not falta_aprovadores from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000011'),
  'alçada por centro: centro sem gestor aprovador, com faixas próprias, tem alçada');
select pg_temp.como(:'leitor');
select pg_temp.ok(not erp.aprovo_titulo('84000000-0000-0000-0000-000000000011'), 'alçada por centro: quem não ocupa vaga não aprova o título');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000011', true)$$,
  'Esta etapa é de outra pessoa', 'alçada por centro: a vaga com o nome de uma pessoa é só dela');
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.aprovo_titulo('84000000-0000-0000-0000-000000000011')
                  and (select count(*) from erp.titulos_do_acumulado('84000000-0000-0000-0000-000000000011')) >= 1,
  'alçada por centro: a pessoa da vaga, sem cargo, vê o título e o acumulado');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000011', true) = 'aprovado', 'alçada por centro: a pessoa da vaga aprova');
-- falta de aprovadores: quem lançou é a pessoa da vaga
select pg_temp.tit('84000000-0000-0000-0000-000000000012', :'cc_obra', '04.01', 3000);
select pg_temp.ok((select falta_aprovadores and vagas_sem_gente = array['P:' || :'analista2'] from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000012'),
  'alçada por centro: sem gente qualificada (a pessoa da vaga lançou), o título fica marcado para o master');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000012', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'alçada por centro: quem lançou continua não aprovando');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos e join erp.tipos_evento te on te.codigo = e.tipo
                           where e.tipo = 'alcada_falta_aprovadores' and te.critico and e.dados->>'titulo_id' = '84000000-0000-0000-0000-000000000012'
                             and e.dados->>'motivo' like 'Faltam aprovadores qualificados%'),
  'alçada por centro: a falta de aprovadores vira evento crítico, com o motivo');
select pg_temp.ok(not exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and dados->>'titulo_id' = '84000000-0000-0000-0000-000000000011'),
  'alçada por centro: com gente para as vagas, não há evento');
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000012', true) = 'aprovado', 'alçada por centro: o master aprova o título que veio por falta de aprovadores');
-- a mesma pessoa não conta duas vezes: o único AF é também a pessoa da outra vaga
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000013', :'cc_obra', '04.01', 8000);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000005' and falta_aprovadores and cardinality(vagas_sem_gente) = 1
                     from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000013'),
  'alçada por centro: a mesma pessoa em duas vagas conta uma vez só (falta um aprovador)');
-- quem passa a ocupar a vaga depois também decide
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'); select pg_temp.volta();
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000013', true) = 'pendente', 'alçada por centro: o AF que entrou depois aprova a vaga');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000013', true) = 'aprovado', 'alçada por centro: e a pessoa da outra vaga fecha');
-- centro sem faixas próprias continua nas gerais
select pg_temp.sis(); delete from erp.alcadas_pagamento where centro_custo_id = :'cc_mkt'; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000006', :'cc_mkt', '05.01.04', 1500);
select pg_temp.ok((select etapas = '{AREA,AF,AD}' and alcada_id = (select id from erp.alcadas_pagamento where centro_custo_id is null and ate is null)
                     from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000006'),
  'alçada por centro: sem faixas próprias, o centro usa as gerais (acima de 50 mil no mês, com a AD)');
-- empate de vagas entre centros do rateio: vale o centro de maior acumulado
select id as cc_a from erp.centros_custo where nome not in ('Obra', 'Marketing') order by nome limit 1 \gset
select id as cc_b from erp.centros_custo where nome not in ('Obra', 'Marketing') order by nome offset 1 limit 1 \gset
select pg_temp.como(:'diretor');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values (:'ne_vm', :'cc_a', true), (:'ne_vm', :'cc_b', true)
  on conflict (nucleo_economico_id, centro_custo_id) do update set ligado = true;
select pg_temp.sis();
insert into erp.alcadas_pagamento (centro_custo_id, etapas) values (:'cc_a', '{AF}'), (:'cc_b', '{AF}');
select pg_temp.volta();
create function pg_temp.tit2(p_id uuid, p_c1 uuid, p_c2 uuid, p_valor numeric) returns void language sql as $$
  insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
    (p_id, '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000008', '2026-09-02', '2026-09-01', p_valor);
  insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (p_id, 1, '2026-09-20', p_valor);
  insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values (p_id, '40000000-0000-0000-0000-000000000001', p_c1, pg_temp.nat('05.01.04'), 50),
         (p_id, '40000000-0000-0000-0000-000000000001', p_c2, pg_temp.nat('05.01.04'), 50);
  select erp.confirmar_titulo(p_id); $$;
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000021', :'cc_a', '05.01.04', 5000);
select pg_temp.tit2('84000000-0000-0000-0000-000000000022', :'cc_a', :'cc_b', 1000);
select pg_temp.ok((select centro_custo_id = :'cc_a' from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000022'),
  'alçada por centro: no empate de vagas, vale o centro de maior acumulado (o primeiro)');
select pg_temp.tit('84000000-0000-0000-0000-000000000023', :'cc_b', '05.01.04', 20000);
select pg_temp.tit2('84000000-0000-0000-0000-000000000024', :'cc_a', :'cc_b', 1000);
select pg_temp.ok((select centro_custo_id = :'cc_b' from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000024'),
  'alçada por centro: no empate de vagas, vale o centro de maior acumulado (o segundo)');
-- modo livre também no limite do título
select pg_temp.como(:'diretor');
update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 10, meses = 3 where tabela = 'alcadas_pagamento';
select pg_temp.sis();
alter table erp.auditoria disable trigger t_auditoria_guarda;
update erp.auditoria set em = em - interval '4 months' where tabela = 'alcadas_pagamento' and registro = '86000000-0000-0000-0000-000000000004';
alter table erp.auditoria enable trigger t_auditoria_guarda;
select pg_temp.volta();
select pg_temp.como(:'contador');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "86000000-0000-0000-0000-000000000004", "ate_titulo": 5400}', 'livre') as lt1 \gset
select pg_temp.ok((select aprovacao = 'livre' and situacao = 'aplicada' from erp.mudancas_config where id = :'lt1')
                  and (select ate_titulo from erp.alcadas_pagamento where id = '86000000-0000-0000-0000-000000000004') = 5400,
  'alçada por centro: no modo livre, o limite do título muda na hora dentro do percentual');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "86000000-0000-0000-0000-000000000004", "ate_titulo": 6000}', 'mais') as lt2 \gset
select pg_temp.ok((select aprovacao <> 'livre' and situacao = 'pendente' from erp.mudancas_config where id = :'lt2'),
  'alçada por centro: acima do percentual, o limite do título pede aprovação');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "86000000-0000-0000-0000-000000000004", "paralelo": true}', 'paralelo') as lt3 \gset
select pg_temp.ok((select aprovacao <> 'livre' and situacao = 'pendente' from erp.mudancas_config where id = :'lt3'),
  'alçada por centro: mudar paralelo ou vagas nunca é livre');
select pg_temp.como(null);
rollback;

\echo '# fim'
do $$ begin raise notice 'TODOS OS TESTES PASSARAM'; end $$;
