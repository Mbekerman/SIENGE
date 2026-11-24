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
-- Nada é aprovado sem aprovador (18/11/2026): o título de centro sem gestor vai ao master. Nos testes
-- que não tratam de aprovação, o master aprova o que falta e o papel de antes volta.
create function pg_temp.aprova(t uuid, m text) returns void language plpgsql as $$
declare antes text := coalesce(current_setting('request.jwt.claim.sub', true), ''); r text := current_setting('role');
begin
  perform pg_temp.como(m);
  for i in 1..10 loop exit when erp.alcada_fase(t) is null; perform erp.decidir_titulo(t, true); end loop;
  perform set_config('request.jwt.claim.sub', antes, false); perform set_config('role', r, false);
end $$;
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
create function pg_temp.folhas() returns jsonb language sql as $$ select jsonb_agg(id) from erp.naturezas n where erp.natureza_folha(n.id) $$;
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
-- Naturezas liberadas por divisão: nos testes de antes da regra, toda natureza, centro e divisão
-- novos nascem com tudo liberado (a seção própria desliga este atalho). Grava como o sistema e
-- volta a quem estava.
create function public.teste_libera_tudo() returns trigger language plpgsql as $$
declare v_sub text := coalesce(current_setting('request.jwt.claim.sub', true), '');
        v_role text := coalesce(nullif(current_setting('role', true), ''), 'none');
begin
  -- dentro de uma função definer do ERP (o pedido aprovado) já grava como ela
  if current_user::text not like 'erp\_%' then
    perform set_config('request.jwt.claim.sub', '', true), set_config('role', 'none', true);
  end if;
  if tg_table_name = 'naturezas' then
    insert into erp.naturezas_liberadas (centro_custo_id, natureza_id) select id, new.id from erp.centros_custo on conflict do nothing;
    insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) select centro_custo_id, id, new.id from erp.divisoes on conflict do nothing;
  elsif tg_table_name = 'centros_custo' then
    insert into erp.naturezas_liberadas (centro_custo_id, natureza_id) select new.id, id from erp.naturezas on conflict do nothing;
  else
    insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) select new.centro_custo_id, new.id, id from erp.naturezas on conflict do nothing;
  end if;
  if current_user::text not like 'erp\_%' then
    perform set_config('request.jwt.claim.sub', v_sub, true), set_config('role', v_role, true);
  end if;
  return null;
end $$;
create trigger t_teste_libera after insert on erp.naturezas for each row execute function public.teste_libera_tudo();
create trigger t_teste_libera after insert on erp.centros_custo for each row execute function public.teste_libera_tudo();
create trigger t_teste_libera after insert on erp.divisoes for each row execute function public.teste_libera_tudo();
select pg_temp.ok((select count(*) from erp.naturezas_liberadas) = (select count(*) from erp.centros_custo)
                  * (select count(*) from erp.naturezas n where erp.natureza_folha(n.id)),
  'carga: os centros nascem com todas as naturezas do último nível liberadas');
delete from erp.naturezas_liberadas;   -- os testes trocam o id dos centros; libera de novo depois

\echo '# raiz: empresas, sócios, empreendimento'
-- antes de qualquer teste mexer no anon: as migrations não deixam função do erp para ele (S-127)
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'erp' and has_function_privilege('anon', p.oid, 'EXECUTE')),
  'S-127: anon não executa nenhuma função do erp');
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
insert into erp.naturezas_liberadas (centro_custo_id, natureza_id)
  select c.id, n.id from erp.centros_custo c cross join erp.naturezas n on conflict do nothing;
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
select pg_temp.aprova(:'tit9', :'diretor');
select pg_temp.ok((select sum(valor) from erp.titulo_previsoes where titulo_id = :'tit9') = 50,
  'previsão sem fornecedor casa, e só consome a parte do rateio igual a ela (50 de 100)');
rollback;
select erp.lancar_documento('70000000-0000-0000-0000-000000000001', array['2026-02-20','2026-03-20']::date[]) as tit \gset
select pg_temp.aprova(:'tit', :'diretor');
select pg_temp.ok((select valor from erp.titulos where id = :'tit') = 9000, 'título do fornecedor pelo líquido: 10.000 − 500 de ISS − 500 de caução');
select pg_temp.ok((select count(*) = 2 and sum(valor) = 9000 from erp.parcelas where titulo_id = :'tit'), 'em 2 parcelas');
-- um título por nota, fatura ou boleto (Moises, 18/11/2026): a nota gera um título só do fornecedor,
-- em parcelas; não se lança de novo; o mesmo número do mesmo emitente não entra duas vezes
select pg_temp.ok((select count(*) from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000001' and tipo = 'fornecedor') = 1,
  'um título por nota: a nota gera um título só do fornecedor');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000001', array['2026-04-20']::date[])$$,
  'O documento já foi lançado', 'um título por nota: a nota lançada não gera outro título');
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'nfse', '101', '2026-02-05', '2026-02-01', 10)$$, :'spe'),
  'duplicate key value violates unique constraint "documentos_fiscais_unico"',
  'um título por nota: a mesma nota não entra duas vezes');
-- número do documento (Moises, 24/11/2026): a trava compara a chave do número (maiúsculas, só letras e dígitos, sem
-- zeros à esquerda), e repetido é recusado
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'nfse', '00.101', '2026-02-05', '2026-02-01', 10)$$, :'spe'),
  'duplicate key value violates unique constraint "documentos_fiscais_unico"',
  'número do documento: zeros à esquerda e pontuação não fazem outro número (00.101 = 101)');
select pg_temp.ok(erp.numero_documento_chave('1303890-1/') = erp.numero_documento_chave('1303890-1')
                  and erp.numero_documento_chave('bkm-0001') = 'BKM0001' and erp.numero_documento_chave('000') = '0'
                  and erp.numero_documento_chave('29') <> erp.numero_documento_chave('290')
                  and erp.numero_documento_chave('') is null and erp.numero_documento_chave('S/N') is null and erp.numero_documento_chave('-/') is null,
  'número do documento: a chave tira pontuação e zeros à esquerda, iguala maiúsculas e não junta números diferentes');
begin;
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'boleto', 'BKM-0001', '2026-02-05', '2026-02-01', 10) returning id as bol \gset
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'boleto', 'bkm0001', '2026-02-06', '2026-02-01', 10)$$, :'spe'),
  'duplicate key value violates unique constraint "documentos_fiscais_unico"',
  'número do documento: o mesmo boleto do mesmo fornecedor não entra duas vezes (maiúsculas e traço não contam)');
select pg_temp.ok((select count(*) = 1 from (select 1 from erp.documentos_fiscais where emitente_id = '10000000-0000-0000-0000-000000000005'
                     and erp.numero_documento_chave(numero) = 'BKM0001') x),
  'número do documento: o repetido não ficou gravado');
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'fatura', 'BKM-0001', '2026-02-05', '2026-02-01', 10);
select pg_temp.ok(true, 'número do documento: o mesmo número em outro tipo de documento entra');
set local role erp_situacao;
update erp.documentos_fiscais set situacao = 'cancelado' where id = :'bol';
reset role;
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'boleto', 'BKM0001', '2026-02-06', '2026-02-01', 10);
select pg_temp.ok(true, 'número do documento: o documento cancelado libera o número para a versão certa');
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'nfe', '29', '1', '2026-02-05', '2026-02-01', 10);
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'nfe', '29', '001', '2026-02-05', '2026-02-01', 10)$$, :'spe'),
  'duplicate key value violates unique constraint "documentos_fiscais_unico"',
  'número do documento: a série passa pela mesma chave (série 1 = 001)');
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'nfe', '29', '2', '2026-02-05', '2026-02-01', 10);
select pg_temp.ok(true, 'número do documento: o mesmo número em outra série entra');
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'recibo', 's/n', '2026-02-05', '2026-02-01', 10),
         (:'spe', '10000000-0000-0000-0000-000000000005', 'recibo', 'S/N', '2026-02-06', '2026-02-01', 20),
         (:'spe', '10000000-0000-0000-0000-000000000005', 'recibo', '-/', '2026-02-07', '2026-02-01', 30);
select pg_temp.ok(true, 'número do documento: documento sem número (s/n, -/) fica fora da trava (Moises, 24/11)');
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'nfse', 's/n', '2026-02-05', '2026-02-01', 10)$$, :'spe'),
  'new row for relation "documentos_fiscais" violates check constraint "documentos_fiscais_nota_com_numero"',
  'número do documento: NFS-e sem número é recusada (a trava não tem porta de saída nas notas)');
select pg_temp.erro_igual(format($$update erp.documentos_fiscais set numero = '-' where emitente_id = '10000000-0000-0000-0000-000000000005'
  and tipo = 'nfe' and numero = '29'$$),
  'new row for relation "documentos_fiscais" violates check constraint "documentos_fiscais_nota_com_numero"',
  'número do documento: NF-e não troca o número por sem número');
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (:'spe', '10000000-0000-0000-0000-000000000005', 'nfe', '30', '2026-02-05', '2026-02-01', 10);
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values (%L, '10000000-0000-0000-0000-000000000005', 'nfe', '30', '0', '2026-02-05', '2026-02-01', 10)$$, :'spe'),
  'duplicate key value violates unique constraint "documentos_fiscais_unico"',
  'número do documento: sem série e série 0 são a mesma série');
rollback;
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
select pg_temp.aprova('81000000-0000-0000-0000-000000000001', :'diretor');
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
select pg_temp.aprova(:'tit8', :'diretor');
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000007', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '107', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000007', array['2026-03-20']::date[]) as tit7 \gset
select pg_temp.aprova(:'tit7', :'diretor');
select id as p7 from erp.parcelas where titulo_id = :'tit7' \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000006', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', '106', '2026-03-05', '2026-03-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000006', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-000000000006', array['2026-03-20']::date[]) as tit6 \gset
select pg_temp.aprova(:'tit6', :'diretor');
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
select pg_temp.aprova(:'tit8', :'diretor');
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
select pg_temp.aprova(:'tit8', :'diretor');
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
select pg_temp.aprova(:'tit5', :'diretor');
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
select pg_temp.aprova(:'tit8', :'diretor');
select id as p8 from erp.parcelas where titulo_id = :'tit8' \gset
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('80000000-0000-0000-0000-000000000003', :'p8', 100);
select pg_temp.ok(erp.parcela_saldo(:'p8') = 0, 'com a trava desligada pelo administrador, o abatimento cruzado passa');
rollback;
select pg_temp.falha($$delete from erp.quitacoes$$, 'quitação não se apaga');
select pg_temp.falha($$delete from erp.lancamentos$$, 'o livro não apaga linhas');
select pg_temp.falha($$update erp.lancamentos set valor = 1$$, 'o livro não se edita');

-- pagar o ISS pelo atalho (o imposto passa pela AF desde 18/11/2026)
select pg_temp.aprova((select id from erp.titulos where tipo = 'imposto'), :'diretor');
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
select pg_temp.sis();
select pg_temp.ok((select count(*) = 1 and bool_and(a.centro_custo_id is null and a.fases = '{AD}' and a.basta is null and a.titulo_id = m.titulo_pagar_id)
                   from erp.titulo_alcadas a join erp.movimentos_societarios m on a.titulo_id in (m.titulo_pagar_id, m.titulo_receber_id) where m.id = :'ms'),
  'movimento entre sócios: o título a pagar pede a AD, sem centro; o a receber não tem alçada (18/11/2026)');
select pg_temp.volta();
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
                               where n.nspname = 'erp' and c.relkind in ('r','p') and c.relname not in ('avisos_sucessao','eventos','envios_notificacao','pix_conferencias','conferencia_tentativas','boleto_conferencias','recebedores_arrecadacao')
                                 and not exists (select 1 from pg_policies p where p.schemaname = 'erp' and p.tablename = c.relname
                                                  and p.policyname = 'perfil_le' and 'authenticated' = any(p.roles))),
  'catálogo: toda tabela tem a política de leitura por perfil (só os avisos da sucessão, os eventos, a fila de envio e a conferência do PIX, lida pelo erp.pix_conferido, e os órgãos das guias, lidos pelo erp.completar_recebedor, ficam fora da API)');
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
select pg_temp.ok(not exists (select 1 from pg_roles where rolname like 'erp\_%' and has_schema_privilege(rolname, 'erp', 'CREATE')),
  'catálogo: nenhum papel erp_* fica com CREATE no esquema erp (dado só durante a troca de dono)');
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'erp' and p.prosecdef
                                 and (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0 and a.privilege_type = 'EXECUTE'))),
  'catálogo: nenhuma definer do erp executável por PUBLIC (nem pelo grant que o dono dá ao criar)');
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
       'regra_adiantamento_atual','autor_lancamento','abatimento_aprovado','gestor_abate_divisao','adiantamento_anterior_em_aberto','centro_ligado','natureza_presa',
       'checar_natureza','checar_centro','em_revisao','pode_ajustar','_ajustavel','_nota_ajustavel','_titulo_em_revisao_da_nota',
       'cadeia_titulo','conferir_ajuste','prv_apagar_pagina','alcada_fase','alcada_pendente','alcada_recusada','titulos_do_acumulado',
       'checar_competencia','_registrar_ajuste','recusar_so_sucessao','recusar_admin_aprovador','_beneficiarios_acesso',
       'confirmar_titulo','lancar_documento','liberar_caucao','publicar_orcamento','decidir_titulo','reenviar_titulo',
       'registrar_movimento_societario','fechar_mes','reabrir_mes','pedir_reclassificacao','decidir_reclassificacao','avisos_forma_pagamento','decidir_compromisso','decidir_previsao','encerrar_previsao','gerar_previsoes_assinatura',
       'cancelar_reclassificacao','pedir_mudanca_acesso','decidir_mudanca_acesso','cancelar_mudanca_acesso','passar_master',
       'pedir_sucessao_master','decidir_sucessao_master','vetar_sucessao_master','efetivar_sucessao_master',
       'pedir_mudanca_config','decidir_mudanca_config','cancelar_mudanca_config','marcar_notificacoes_lidas',
       'designar_pj','retirar_pj','vejo_pj','vejo_auditoria','previsao_aprovada_vista','contrato_aprovado_visto','contrato_confere','compromisso_vinculos','pix_conferido','boleto_conferido','completar_recebedor','credor_novo',
       'criar_orcamento_area','salvar_orcamento_area','enviar_orcamento','descartar_orcamento','decidir_orcamento','minha_vaga_orcamento',
       '_vejo_nota_recebida','_vejo_leitura_notas','buscar_nota_recebida','ignorar_nota_recebida','voltar_nota_recebida',
       'liberar_notas_recebidas','retirar_notas_recebidas','_libero_notas_recebidas','_lanco_na_empresa','usar_forma_do_cadastro')),
  'catálogo: das funções security definer, authenticated só executa as da lista (RPCs e conferências de quem está logado)');
select pg_temp.ok(not has_function_privilege('authenticated', 'erp._aplicar_mudanca_acesso(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.gerar_avisos_sucessao()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.vetar_sucessao_por_link(text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._pagamento_saldo(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._aplicar_mudanca_config(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.registrar_evento(text, text, text, uuid, uuid, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._executar_config(text, text, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._contexto_mudanca_config(text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._criar_titulo(uuid, text, text, uuid, uuid, uuid, date, date, numeric, date[], text, uuid, text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._fixar_alcada_sem_centro(erp.titulos, text[], text, numeric)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._fixar_alcada_previsao_sem_centro(erp.previsoes)', 'EXECUTE'),
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
  update erp.titulos set situacao = 'quitado' where id = (select id from erp.titulos where situacao = 'aberto' and criado_por = auth.uid() limit 1);
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
select pg_temp.aprova(:'tit8', :'diretor');
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
         or p.proowner not in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole, 'erp_acesso'::regrole, 'erp_config'::regrole, 'erp_eventos'::regrole, 'erp_notificacoes'::regrole))),
  'catálogo: todo security definer do `erp` tem search_path fixo e é de erp_conferencia, erp_situacao ou erp_reclassificacao');
select pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'erp' and p.prosecdef) >= 37,
  'catálogo: as funções de conferência são security definer');
select pg_temp.ok((select count(*) = 9 and bool_and(not rolcanlogin and not rolsuper and not rolbypassrls) from pg_roles
                   where rolname in ('erp_sistema', 'erp_conferencia', 'erp_situacao', 'erp_reclassificacao', 'erp_auditoria', 'erp_acesso',
                                     'erp_config', 'erp_eventos', 'erp_notificacoes'))
                  and not exists (select 1 from pg_auth_members
                                  where roleid in ('erp_conferencia'::regrole, 'erp_situacao'::regrole, 'erp_reclassificacao'::regrole, 'erp_auditoria'::regrole, 'erp_acesso'::regrole,
                                                   'erp_config'::regrole, 'erp_eventos'::regrole, 'erp_notificacoes'::regrole)),
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
                               'mudanca_config_votos','usuarios','auditoria','regras_notificacao','tipos_evento',
                               'sienge_centros','sienge_contas','sienge_parametros')
             and (cmd = 'ALL' or (cmd = 'SELECT' and tablename in ('usuarios','auditoria'))))
    and not (policyname = 'eventos_grava' and tablename = 'eventos' and cmd = 'INSERT' and roles = '{erp_eventos}')
    -- a distribuição das notificações: lê quem recebe, grava só o sino e a fila
    and not (policyname = 'notificacoes' and roles = '{erp_notificacoes}' and coalesce(qual, with_check) ~ 'agindo_como\(''erp_notificacoes''::text\)'
             and ((cmd = 'ALL' and tablename in ('notificacoes','envios_notificacao'))
                  or (cmd = 'SELECT' and tablename in ('usuarios','master','tipos_evento','regras_notificacao','preferencias_notificacao',
                                                       'listas_financeiro','centro_aprovadores','centro_diretores','aprovadores_config','nucleo_centros',
                                                       'divisoes'))))
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
select pg_temp.aprova('80000000-0000-0000-0000-000000000591', :'diretor');
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
select pg_temp.ok((select fases = '{AREA,AF}' and acumulado = 30000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000001'),
  'alçada: até 50 mil no mês do centro, gestor da área e AF');
select pg_temp.ok((select fases = '{AREA,AF,AD}' and acumulado = 55000 from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000002'),
  'alçada: o título que passa dos 50 mil (somando o centro em todos os núcleos e empresas) vai ao AD');
select pg_temp.ok((select fases = '{AREA,AF,AD}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000003'),
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
  'próprio: o master aprova o próprio lançamento, e todas as fases de uma vez');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000092', 'x');
insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000092', 'x');
select pg_temp.ok(true, 'próprio: o master libera e aprova exceção do próprio lançamento');
select pg_temp.como(:'diretor2');
insert into erp.liberacoes_sem_abater (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000091', 'x');
select pg_temp.ok(true, 'próprio: a AD com a marca libera o próprio título sem abater');
-- a marca vale só na fase da AD: na do AF, quem lançou continua não aprovando
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'diretor2'); select pg_temp.volta();
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-000000000093', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 900);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000093', 1, '2026-05-20', 900);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values ('82000000-0000-0000-0000-000000000093', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-000000000093');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('82000000-0000-0000-0000-000000000093', true);
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000093', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'próprio: a marca da AD não vale na fase do AF');
-- S-088: a marca da AD não vale numa aprovação cuja lista não tem a AD
select pg_temp.sis(); update erp.regra_alcada_pagamento set excecao_competencia = '{AF}'; select pg_temp.volta();
select pg_temp.erro_igual($$insert into erp.excecoes_competencia (titulo_id, justificativa) values ('82000000-0000-0000-0000-000000000091', 'x')$$,
  'Quem lançou não aprova o próprio lançamento', 'S-088: sem a AD na lista, a marca da AD não aprova o próprio lançamento');
rollback to savepoint proprio;
select pg_temp.sis();
select pg_temp.ok((select falta_aprovadores and 'AREA' = any (vagas_sem_gente) from erp.titulo_alcadas
                    where titulo_id = '82000000-0000-0000-0000-000000000004')
                  and erp.alcada_pendente('82000000-0000-0000-0000-000000000004') is not null
                  and exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = '82000000-0000-0000-0000-000000000004'),
  'alçada: centro sem gestor aprovador (fora do piloto) não aprova sozinho: vai ao master, com o aviso (18/11/2026)');
select pg_temp.volta();
select pg_temp.erro_igual($$insert into erp.titulo_aprovacoes (titulo_id, fase, lista, aprovado, por) values ('82000000-0000-0000-0000-000000000001', 1, 'AREA', true, '00000000-0000-0000-0000-00000000000e')$$,
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
  'Esta fase de aprovação é do gestor da área', 'alçada: a primeira fase é do gestor da área, nem a diretoria pula');
savepoint so_master;
select pg_temp.como(:'diretor');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) as r_m \gset
select pg_temp.ok(:'r_m' = 'aprovado' and erp.alcada_pendente('82000000-0000-0000-0000-000000000001') is null
                  and (select count(*) > 1 and bool_and(por = :'diretor'::uuid) from erp.titulo_aprovacoes where titulo_id = '82000000-0000-0000-0000-000000000001'),
  'master: um voto do master aprova todas as fases que faltam (gestor, AF, AD...)');
rollback to savepoint so_master;
select pg_temp.como(:'diretor2');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) = 'pendente', 'alçada: o gestor da área aprova a fase dele');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Você já aprovou uma fase de aprovação deste título', 'alçada: a mesma pessoa não aprova duas fases (o gestor também está no AF)');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true)$$,
  'Esta fase de aprovação é de quem está em AF', 'alçada: AF vem depois do gestor, em sequência');
-- a AD sempre pode fazer a aprovação da AF ou da AO (Moises, 18/11/2026)
savepoint ad_no_af;
select pg_temp.como(:'diretor2');
select erp.decidir_titulo('82000000-0000-0000-0000-000000000001', true) as r_ad \gset
select pg_temp.ok(:'r_ad' = 'aprovado'
                  and (select por = :'diretor2'::uuid and lista = 'AF' from erp.titulo_aprovacoes
                        where titulo_id = '82000000-0000-0000-0000-000000000001' and fase = 2),
  'alçada: a AD aprova na vaga da AF (18/11/2026)');
rollback to savepoint ad_no_af;
-- linha sem centro (movimentação): AO + AF juntos, ou a AD sozinha, em qualquer valor (Moises, 18/11/2026)
savepoint sem_centro;
select pg_temp.como(:'diretor');   -- só o master lança linha sem núcleo e sem centro
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-0000000000a1', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 1000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-0000000000a1', 1, '2026-05-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-0000000000a1', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 60),
  ('82000000-0000-0000-0000-0000000000a1', null, null, pg_temp.nat('11.02'), 40);
select erp.confirmar_titulo('82000000-0000-0000-0000-0000000000a1');
select pg_temp.ok((select count(*) = 2
                          and count(*) filter (where centro_custo_id is null and fases = '{AF,AO}' and basta = 'AD' and paralelo
                                                 and alcada_id is null and not falta_aprovadores) = 1
                          and count(*) filter (where centro_custo_id = :'cc_mkt' and basta is null) = 1
                   from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000000a1'),
  'sem centro: o título misto tem a alçada do centro e a alçada sem centro (AF e AO, ou a AD)');
select pg_temp.ok((select basta = 'AD' from erp.v_titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000000a1' and centro_custo_id is null),
  'sem centro: a visão das alçadas mostra a alçada sem centro');
-- o centro aprova pelo gestor (AREA), pela AF e pela AD; depois a alçada sem centro
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true, null, false, :'cc_mkt') = 'pendente', 'sem centro: o gestor aprova o centro');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true, null, false, :'cc_mkt') = 'pendente', 'sem centro: a AF aprova o centro');
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true, null, false, :'cc_mkt') = 'pendente', 'sem centro: a AD fecha o centro');
select pg_temp.sis();
select pg_temp.ok((select count(*) = 1 and bool_and(centro_custo_id is null) from erp.titulo_alcadas a
                    where a.titulo_id = '82000000-0000-0000-0000-0000000000a1' and erp._fase_da_alcada(a) is not null),
  'sem centro: falta só a alçada sem centro (' || (select string_agg(coalesce(centro_custo_id::text,'-') || array_to_string(fases, ','), ' ') from erp.titulo_alcadas a
    where a.titulo_id = '82000000-0000-0000-0000-0000000000a1' and erp._fase_da_alcada(a) is not null) || ')');
select pg_temp.volta();
savepoint sem_centro_ad;
select pg_temp.como(:'diretor2');
select erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true) as r_sc \gset
select pg_temp.ok(:'r_sc' = 'aprovado'
                  and (select count(*) = 2 and bool_and(lista = 'AD' and por = :'diretor2'::uuid) from erp.titulo_aprovacoes v
                        join erp.titulo_alcadas a on a.id = v.alcada_id
                        where v.titulo_id = '82000000-0000-0000-0000-0000000000a1' and a.centro_custo_id is null),
  'sem centro: o voto da AD sozinho aprova a alçada sem centro');
rollback to savepoint sem_centro_ad;
select pg_temp.como(:'gestor');   -- AF (já aprovou o centro como gestor: na alçada sem centro, vota de novo)
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true) = 'pendente', 'sem centro: a AF sozinha não basta');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true)$$,
  'Você já aprovou uma fase de aprovação deste título', 'sem centro: a AF não ocupa as duas vagas');
select pg_temp.como(:'analista');  -- AO
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'sem centro: AF + AO aprovam');
rollback to savepoint sem_centro;
-- sem ninguém na AF e na AO, com uma pessoa só na AD (que não preenche as duas vagas): não falta
-- aprovador, porque a AD sozinha basta
savepoint sem_centro_sem_ao;
select pg_temp.sis(); delete from erp.listas_financeiro where lista in ('AF','AO'); select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-0000000000a3', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 10);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-0000000000a3', 1, '2026-05-20', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-0000000000a3', null, null, pg_temp.nat('11.02'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-0000000000a3');
select pg_temp.sis();
select pg_temp.ok((select not falta_aprovadores from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000000a3')
                  and not exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = '82000000-0000-0000-0000-0000000000a3'),
  'sem centro: sem AF e AO, com uma pessoa na AD, não falta aprovador nem vai ao master');
select pg_temp.volta();
rollback to savepoint sem_centro_sem_ao;
-- sem AO e sem AD (com a AF): falta aprovador
savepoint sem_centro_sem_ao_ad;
select pg_temp.sis(); delete from erp.listas_financeiro where lista in ('AO','AD') and user_id <> :'diretor'; select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-0000000000a4', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 10);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-0000000000a4', 1, '2026-05-20', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-0000000000a4', null, null, pg_temp.nat('11.02'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-0000000000a4');
select pg_temp.sis();
select pg_temp.ok((select falta_aprovadores and vagas_sem_gente = '{AO}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000000a4')
                  and exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = '82000000-0000-0000-0000-0000000000a4'),
  'sem centro: sem AO e sem AD, falta aprovador e vai ao master');
select pg_temp.volta();
rollback to savepoint sem_centro_sem_ao_ad;
-- sem centro, sem ninguém na AF e na AO e com a AD vazia: vai ao master, com o aviso
savepoint sem_centro_falta;
select pg_temp.sis(); delete from erp.listas_financeiro where lista in ('AF','AO','AD') and user_id <> :'diretor'; select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-0000000000a2', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-05-05', '2026-05-01', 10);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-0000000000a2', 1, '2026-05-20', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-0000000000a2', null, null, pg_temp.nat('11.02'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-0000000000a2');
select pg_temp.sis();
select pg_temp.ok((select falta_aprovadores from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000000a2')
                  and exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = '82000000-0000-0000-0000-0000000000a2'),
  'sem centro: sem AF, AO nem AD, vai ao master com o aviso');
rollback to savepoint sem_centro_falta;
-- a previsão sem centro segue a mesma regra: AO + AF, ou a AD sozinha
savepoint prev_sem_centro;
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-0000000000a1', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', null, null, pg_temp.nat('11.02'), '2026-05-01', '2026-05-20', 500);
select pg_temp.sis();
select pg_temp.ok((select count(*) = 1 and bool_and(centro_custo_id is null and fases = '{AF,AO}' and basta = 'AD')
                   from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000a1'),
  'sem centro: a previsão sem centro pede AF e AO, ou a AD');
select pg_temp.volta();
savepoint prev_sem_centro_ad;
select pg_temp.como(:'diretor2');
select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true) as r_psc \gset
select pg_temp.sis();
select pg_temp.ok(:'r_psc' = 'aprovado' and erp.previsao_aprovada('68000000-0000-0000-0000-0000000000a1'),
  'sem centro: a AD sozinha aprova a previsão sem centro');
select pg_temp.volta();
rollback to savepoint prev_sem_centro_ad;
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true) = 'pendente', 'sem centro: na previsão, a AF sozinha não basta');
select pg_temp.como(:'analista');
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'sem centro: na previsão, AF + AO aprovam');
rollback to savepoint prev_sem_centro;
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
  'O título foi recusado na alçada', 'alçada: recusado não segue para as próximas fases');
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
select pg_temp.ok((select acumulado = 50000 and fases = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000007'),
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
-- rateio em dois centros com gestor: uma alçada em cada centro, com o acumulado e a parte de cada um
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
select pg_temp.ok((select acumulado = 61000 and valor_no_centro = 500 and fases = '{AREA,AF,AD}'
                   from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000009' and centro_custo_id = :'cc_obra')
                  and (select count(*) from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000009') = 2,
  'alçada: rateio em dois centros com gestor tem uma alçada em cada centro, com o acumulado e a parte de cada um');
-- imposto retido não entra na alçada
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000650', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '650', '2026-07-05', '2026-07-01', 1000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-000000000650', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-000000000650', 'iss', 50, '10000000-0000-0000-0000-000000000006', '2026-08-10');
select erp.lancar_documento('70000000-0000-0000-0000-000000000650', array['2026-07-20']::date[]) is not null as lancou \gset
select pg_temp.ok((select count(*) filter (where t.tipo = 'fornecedor' and a.centro_custo_id is not null) = 1
                          and count(*) filter (where t.tipo = 'imposto' and a.centro_custo_id is null and a.fases = '{AF}' and a.basta is null) = 1
                          and count(*) = 2
                   from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id
                   where t.documento_id = '70000000-0000-0000-0000-000000000650'),
  'alçada: o título do fornecedor pela alçada do centro; o imposto retido pelo AF, sem centro');
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
insert into erp.alcadas_pagamento (ate, fases) values (null, '{AREA,AF,AD}');
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
select pg_temp.ok((select acumulado = 30600 and fases = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000005'),
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
select pg_temp.ok((select acumulado = 21000 and fases = '{AREA,AF}' and centro_custo_id = :'cc_mkt'
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
  'O pagamento sai com o núcleo, o centro de custo e a divisão do pedido de adiantamento', 'adiantamento: o pagamento sai com o carimbo do pedido');
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
select pg_temp.ok((select acumulado = 26000 and fases = '{AREA,AF}' from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-000000000020'),
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
select pg_temp.erro_igual($$insert into erp.titulo_revisoes (titulo_id, rodada, fase, motivo, pedida_por)
  values ('82000000-0000-0000-0000-000000000040', 1, 1, 'x', '00000000-0000-0000-0000-00000000000e')$$,
  'A revisão do título só se grava pela aprovação e pelo reenvio', 'revisão: o pedido só se grava pela aprovação');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true) = 'pendente', 'revisão: o gestor aprova a fase dele');
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
                  and (select reenviada_por = :'contador' and pedida_por = :'contador' and fase = 2 and rodada = 1
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
select pg_temp.ok((select por = :'contador' and origem = 'ajuste' and lista = 'AF' and fase = 2 from erp.titulo_aprovacoes
                    where titulo_id = '82000000-0000-0000-0000-000000000040' and rodada = 2),
  'revisão: o ajuste do AF conta como a aprovação dele; o título volta para a gestora');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000040', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem ajustou e reenviou não aprova outra fase');
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
-- a gestora que ajusta já aprova a fase da área; quem mais ajustou não aprova; tudo fica registrado
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor, descricao) values
  ('82000000-0000-0000-0000-000000000042', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2027-01-04', '2027-01-01', 1000, 'brindes');
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-000000000042', 1, '2027-01-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-000000000042', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
-- com a fase do AD nesta faixa, para ver as três fases
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set fases = '{AREA,AF,AD}' where ate = 50000;
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
update erp.alcadas_pagamento set fases = '{AREA,AF}' where ate = 50000;
select pg_temp.ok((select count(*) = 3 and bool_and(por is not null) from erp.titulo_ajustes where titulo_id = '82000000-0000-0000-0000-000000000042')
                  and exists (select 1 from erp.titulo_ajustes where titulo_id = '82000000-0000-0000-0000-000000000042'
                               and por = :'gestor' and depois ->> 'descricao' = 'brindes de janeiro'),
  'ajuste: cada mudança fica registrada com quem fez, antes e depois');
-- o rastro do título mostra o pedido, o antes e o depois de cada campo e a volta (api.titulo_rastro, 19/11/2026)
select pg_temp.ok((select a->>'motivo' = 'trocar a descrição e o valor' and a->>'resposta' = 'ajustado'
                          and a->'ajustes' @> '[{"campo": "Descrição", "antes": "brindes", "depois": "brindes de janeiro"}]'
                          and a->'ajustes' @> '[{"campo": "Valor", "antes": "1000.00", "depois": "800.00"}]'
                          and a->'ajustes' @> '[{"campo": "1ª parcela · valor", "antes": "1000.00", "depois": "800.00"}]'
                          and j->'historico' @> '[{"texto": "pediu alteração: trocar a descrição e o valor"}]'
                          and j->'historico' @> '[{"texto": "reenviou para aprovação: ajustado"}]'
                     from api.titulo_rastro('82000000-0000-0000-0000-000000000042') j, jsonb_array_elements(j->'alteracoes') a),
  'rastro: o pedido de alteração traz o motivo, a resposta e o antes e o depois de cada campo, e entra no histórico');
select pg_temp.ok((select string_agg(lista || ':' || (por = case lista when 'AREA' then :'gestor'::uuid else :'contador'::uuid end)::text, ',' order by fase)
                     = 'AREA:true,AF:true' from erp.titulo_aprovacoes
                    where titulo_id = '82000000-0000-0000-0000-000000000042' and rodada = 2 and origem = 'ajuste')
                  and erp.alcada_pendente('82000000-0000-0000-0000-000000000042') = 'AD'
                  and erp.autor_lancamento('titulo', '82000000-0000-0000-0000-000000000042') = :'analista',
  'revisão: o ajuste da gestora e o do AF contam como as aprovações deles; quem lançou continua o autor, e o título segue para o AD');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000042', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem ajustou (sem reenviar) não aprova outra fase');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual($$select erp.decidir_titulo('82000000-0000-0000-0000-000000000042', true)$$,
  'Quem ajustou não aprova o ajuste', 'revisão: quem só reenviou também não aprova outra fase');
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
  'revisão: na nota relançada também; quem é gestor de outro centro ajusta como AF, e a fase da área fica para o gestor dela');
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
select pg_temp.ok((select string_agg(lista || ':' || por::text, ',' order by fase) from erp.titulo_aprovacoes
                    where titulo_id = :'tit661f' and origem = 'ajuste') = 'AREA:' || :'diretor2' || ',AF:' || :'contador',
  'revisão: a fase do AF só vai para quem está no AF');
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
    perform pg_temp.aprova((select id from erp.titulos where documento_id = '70000000-0000-0000-0000-000000000660' and tipo = 'imposto'), %L);
    insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
      ('83000000-0000-0000-0000-000000000660', %L, %L, '10000000-0000-0000-0000-000000000006', %L, %L, '2027-02-10', 50);
    insert into erp.quitacoes (pagamento_id, parcela_id, principal)
      select '83000000-0000-0000-0000-000000000660', pa.id, 50 from erp.parcelas pa join erp.titulos t on t.id = pa.titulo_id
       where t.documento_id = '70000000-0000-0000-0000-000000000660' and t.tipo = 'imposto';
    perform pg_temp.como(%L);
    perform erp.decidir_titulo(%L, false, 'serviço não medido');
  end $y$ $$, :'gestor', :'spe', :'conta_spe', :'ne_vm', :'cc_obra', :'diretor2', :'tit660'),
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
-- desde 18/11/2026 a exceção não libera natureza restrita (PJ): só o master e os designados por ele
select pg_temp.ok(not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and not pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), :'gestor'),
  'PJ: a exceção de natureza não libera a natureza restrita');
insert into erp.designados_pj (user_id, motivo, por) values (:'analista', 'teste', :'gestor');
select pg_temp.ok(pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.04'), :'gestor')
                  and not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.04')),
  'PJ: o designado vê o PJ em qualquer centro e lança só onde lança');
insert into erp.excecoes_natureza (user_id, natureza_id, centro_custo_id, efeito) values (:'analista', pg_temp.nat('05.01'), null, 'bloquear');
select pg_temp.ok(not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'))
                  and not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'perfis: bloqueio do galho vence a liberação e vale nas naturezas de baixo');
select pg_temp.ok(not pg_temp.ve_linha(:'analista', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.04'), :'gestor'),
  'PJ: o bloqueio da pessoa vale também para o designado');
delete from erp.designados_pj where user_id = :'analista';

-- modelo que libera natureza restrita: só nos centros do modelo
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a1000000-0000-0000-0000-000000000004', :'leitor', 'a0000000-0000-0000-0000-000000000004', 'lista');
insert into erp.atribuicao_nucleos values ('a1000000-0000-0000-0000-000000000004', :'ne_vm', true);
select pg_temp.ok(not pg_temp.lanca_linha(:'leitor', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'))
                  and not pg_temp.natureza_liberada(:'leitor', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'PJ: o modelo de acesso não libera a natureza restrita (sem acesso por papel, Moises 18/11/2026)');

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
-- (a 05.01.04 é restrita: sem designação do master, a liberação da exceção não vale)
select pg_temp.ok(pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.01'))
                  and not pg_temp.lanca_linha(:'analista', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
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
-- desde 18/11/2026 a marca restrita (o que é PJ) só muda com o voto do master
select pg_temp.ok((select aprovacao = 'master' and minimo = 1 from erp.mudancas_acesso where id = :'m_res'),
  'PJ: o pedido que muda a marca restrita vai ao master');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_res'),
  'Só o master decide este pedido', 'PJ: aprovador de acesso não decide a marca restrita');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'m_res'),
  'Só o master decide este pedido', 'PJ: nem outro diretor decide a marca restrita');
select pg_temp.como(:'diretor');
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
-- o modelo com a natureza PJ não libera o PJ (Moises, 18/11/2026): quem vê o PJ é o designado pelo master
insert into erp.perfil_naturezas values ('a1000000-0000-0000-0000-000000000004', pg_temp.nat('06.07'));
insert into erp.designados_pj (user_id, motivo, por) values (:'u4', 'Lança a folha PJ do Marketing', :'u7');
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
-- o E já misturou Marketing e PJ; desde 18/11/2026 o PJ sobe sozinho, então o E é só PJ
select pg_temp.tit(:'u4', :'te', :'incorp', 2000, jsonb_build_array(jsonb_build_object('n', :'ne_corp', 'c', :'cc_mkt', 'nat', '06.07', 'p', 100)));
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
-- desde 18/11/2026 a Obra (sem gestor) também tem alçada, pelas faixas gerais (a AD vê o C), e a AD ocupa
-- as vagas do AF e do AO (vê o A); o D é PJ e só o master e os designados o veem e aprovam (Moises,
-- 18/11/2026); o E, que ninguém confirmou, fica de fora
select pg_temp.ok(pg_temp.vejo_tits() = 'ABC', 'acesso: quem aprova na AD vê os títulos das alçadas dele, e só eles, sem o PJ (vê ' || pg_temp.vejo_tits() || ')');
select pg_temp.sis();
select pg_temp.ok((select fases = '{PJ}' and centro_custo_id is null from erp.titulo_alcadas where titulo_id = :'td')
                  and not exists (select 1 from erp.titulo_alcadas where titulo_id = :'td' and fases <> '{PJ}'),
  'PJ: o título PJ tem uma alçada só, a vaga PJ, sem as vagas de papel');
select pg_temp.volta(); select pg_temp.como(:'u7');
select pg_temp.erro_igual(format($$select erp.decidir_titulo(%L, true)$$, :'td'), 'Esta fase de aprovação é de quem está em PJ',
  'PJ: a AD não aprova o título PJ');
select pg_temp.como(:'u1');
select pg_temp.ok(not erp.aprovo_titulo(:'td'), 'PJ: quem não vê o PJ não é aprovador dele');
-- S-062: sem a alçada do A, a AD deixa de vê-lo e ele vai para a linha sem detalhe; o D (PJ) nem entra
-- no acumulado do centro (Moises, 18/11/2026)
savepoint s062;
select pg_temp.sis(); set local session_replication_role = replica;
delete from erp.titulo_alcadas where titulo_id in (:'ta', :'td');
set local session_replication_role = origin; select pg_temp.volta();
select pg_temp.como(:'u7');
select pg_temp.ok((select count(*) = 2 and count(*) filter (where titulo_id = :'tb') = 1
                     and bool_or(titulo_id is null and pessoa = 'Outros 1 títulos (sem acesso)' and valor_no_centro = 1000 and empresa_id is null)
                   from erp.titulos_do_acumulado(:'tb')),
  'S-062: no acumulado, quem aprova vê em detalhe o que vê e o resto numa linha só, com a soma');
rollback to savepoint s062;
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
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select erp.decidir_titulo(%L, true)$$, :'td'), 'Esta fase de aprovação é de quem está em PJ',
  'PJ: o gestor do centro não aprova o título PJ');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_titulo(:'td', true) = 'aprovado', 'PJ: o master aprova o título PJ');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'u4');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor) values
  ('c2000000-0000-0000-0000-0000000000d1', :'incorp', :'conta_inc', '10000000-0000-0000-0000-0000000000c1', :'ne_corp', :'cc_mkt', '2027-10-10', 20000);
insert into erp.quitacoes (pagamento_id, parcela_id, principal) values ('c2000000-0000-0000-0000-0000000000d1', :'td', 20000);
select pg_temp.ok(exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1'), 'acesso: quem tem o PJ vê o pagamento do PJ');
select pg_temp.como(:'u9');
select pg_temp.ok(not exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1')
                  and not exists (select 1 from erp.quitacoes where pagamento_id = 'c2000000-0000-0000-0000-0000000000d1'),
  'acesso: o pagamento que quita título PJ some para quem vê o centro mas não o PJ');
select pg_temp.como(:'u7');
select pg_temp.ok(not exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1'),
  'PJ: nem o financeiro (AD) vê o pagamento que quita título PJ');
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
select pg_temp.falha($$update erp.alcadas_pagamento set fases = '{AREA,AF}' where ate is null$$, 'S-090: o TI não tira o AD da alçada');
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
select pg_temp.ok((select trava from erp.regra_adiantamento) and exists (select 1 from erp.alcadas_pagamento where ate is null and 'AD' = any(fases)),
  'S-090: a trava e o AD continuam');
select pg_temp.como(:'diretor');
update erp.alcadas_pagamento set fases = fases where ate is null;
select pg_temp.ok(true, 'S-090: o master muda a alçada');
-- quem lançou o pagamento continua vendo, mesmo sem o perfil
select pg_temp.sis(); delete from erp.atribuicoes where user_id = :'u4'; delete from erp.listas_financeiro where user_id = :'u4'; select pg_temp.volta();
select pg_temp.como(:'u4');
select pg_temp.ok(exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1') and pg_temp.vejo_tits() = 'DE',
  'acesso: sem o perfil, quem lançou o pagamento ainda o vê, e só vê os títulos PJ (designado pelo master)');
select pg_temp.sis(); delete from erp.designados_pj where user_id = :'u4'; select pg_temp.volta();
select pg_temp.como(:'u4');
select pg_temp.ok(not exists (select 1 from erp.pagamentos where id = 'c2000000-0000-0000-0000-0000000000d1') and pg_temp.vejo_tits() = '',
  'PJ: retirado da designação, nem quem lançou vê o pagamento que quita título PJ');
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
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa_topo', 'fases', '{AREA,AF}'::text[]), 'tirar AD') as l5 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l5') and exists (select 1 from erp.alcadas_pagamento where id = :'faixa_topo' and 'AD' = any(fases)),
  'config: tirar uma fase sempre pede aprovação, mesmo no modo livre');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', jsonb_build_object('id', :'faixa50', 'ate', 50000, 'fases', '{AREA}'::text[]), 'junto') as l6 \gset
select pg_temp.ok((select aprovacao = 'lista' from erp.mudancas_config where id = :'l6'), 'config: valor e fases juntos também pedem aprovação');
select erp.pedir_mudanca_config('alcadas_pagamento', 'incluir', '{"ate": 20000, "fases": ["AREA"]}', 'faixa nova') as l7 \gset
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
select pg_temp.sis(); insert into erp.alcadas_pagamento (ate, fases) values (10000, '{AREA}'); select pg_temp.volta();
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
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (%L, 1, '{AREA,XX}')$$, :'cc_mkt'),
  'Vaga de aprovação inválida: XX (use AREA, DIRETOR_AREA, AF, AO, AO_CENTRO, AD ou P: e o usuário)', 'alçada por centro: vaga com código desconhecido é recusada');
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (%L, 1, array['P:' || %L])$$, :'cc_mkt', :'ti'),
  'Administrador não aprova nada no ERP', 'alçada por centro: o administrador não ocupa vaga');
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (%L, 1, array['P:' || %L, 'AF', 'P:' || %L])$$, :'cc_mkt', :'analista2', :'analista2'),
  'A mesma pessoa não ocupa duas vagas da faixa', 'alçada por centro: a mesma pessoa não ocupa duas vagas');
select pg_temp.falha(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (%L, 1, '{P:99999999-0000-0000-0000-000000000000}')$$, :'cc_mkt'),
  'alçada por centro: pessoa que não existe não ocupa vaga');
-- Marketing: até 2 mil no título e 10 mil no mês, 1 aprovador; até 100 mil e 200 mil, 2 em paralelo;
-- acima, gestor, diretor da área e AF em sequência. Obra: até 5 mil, uma pessoa pelo nome; acima, AF e outra pessoa.
insert into erp.alcadas_pagamento (id, centro_custo_id, ate, ate_titulo, fases, paralelo) values
  ('86000000-0000-0000-0000-000000000001', :'cc_mkt', 10000, 2000, '{AREA}', false),
  ('86000000-0000-0000-0000-000000000002', :'cc_mkt', 200000, 100000, '{AF,AREA}', true),
  ('86000000-0000-0000-0000-000000000003', :'cc_mkt', null, null, '{AREA,DIRETOR_AREA,AF}', false),
  ('86000000-0000-0000-0000-000000000004', :'cc_obra', null, 5000, array['P:' || :'analista2'], false),
  ('86000000-0000-0000-0000-000000000005', :'cc_obra', null, null, array['AF', 'P:' || :'contador'], false);
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000001', :'cc_mkt', '05.01.04', 1500);
select pg_temp.ok((select alcada_id = '86000000-0000-0000-0000-000000000001' and fases = '{AREA}' and not falta_aprovadores
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
                  and exists (select 1 from erp.titulo_aprovacoes where titulo_id = '84000000-0000-0000-0000-000000000002' and fase = 2 and por = :'gestor'),
  'alçada por centro: em paralelo, o gestor aprova a vaga dele antes da vaga do AF');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000002', true)$$,
  'Você já aprovou uma fase de aprovação deste título', 'alçada por centro: em paralelo, a mesma pessoa não aprova duas vagas');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000002', true) = 'aprovado', 'alçada por centro: em paralelo, com as duas vagas, o título fica aprovado');
-- em paralelo, a AD aprova na vaga dela, não na da AF que ela também ocupa (18/11/2026)
savepoint par_ad;
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2') on conflict do nothing;
update erp.alcadas_pagamento set fases = '{AF,AD}' where id = '86000000-0000-0000-0000-000000000002';
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-0000000000a0', :'cc_mkt', '05.01.04', 3000);
select pg_temp.como(:'diretor2');
select erp.decidir_titulo('84000000-0000-0000-0000-0000000000a0', true) as r_pad \gset
select pg_temp.ok(:'r_pad' = 'pendente'
                  and exists (select 1 from erp.titulo_aprovacoes where titulo_id = '84000000-0000-0000-0000-0000000000a0' and fase = 2 and lista = 'AD' and por = :'diretor2'),
  'alçada por centro: em paralelo, a AD aprova a vaga dela antes da vaga da AF');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-0000000000a0', true) = 'aprovado', 'alçada por centro: e a AF fecha');
rollback to savepoint par_ad;
-- em sequência, com o diretor da área
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000005', :'cc_mkt', '05.01.04', 150000);
select pg_temp.ok((select cardinality(fases) = 3 and not paralelo and not falta_aprovadores from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000005'),
  'alçada por centro: acima de 100 mil, três aprovadores em sequência');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true)$$,
  'Esta fase de aprovação é do gestor da área', 'alçada por centro: em sequência, o AF espera a vez');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true);
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000005', true)$$,
  'Esta fase de aprovação é do diretor da área', 'alçada por centro: a vaga do diretor da área é só dele');
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
  'Esta fase de aprovação é de outra pessoa', 'alçada por centro: a vaga com o nome de uma pessoa é só dela');
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
select pg_temp.ok((select n.detalhe from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                    where e.tipo = 'alcada_falta_aprovadores' and e.dados->>'titulo_id' = '84000000-0000-0000-0000-000000000012'
                      and n.user_id = '00000000-0000-0000-0000-00000000000a') = 'Veio para você por falta de aprovadores mínimos qualificados',
  'notificações: o master recebe o título que veio por falta de aprovadores mínimos qualificados, com esse texto');
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
select pg_temp.ok((select fases = '{AREA,AF,AD}' and alcada_id = (select id from erp.alcadas_pagamento where centro_custo_id is null and ate is null)
                     from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000006'),
  'alçada por centro: sem faixas próprias, o centro usa as gerais (acima de 50 mil no mês, com a AD)');
-- rateio em vários centros (Moises, 15/11/2026): uma aprovação por centro, com o valor de cada um
-- e o rito de cada um; o título só aprova quando todos os centros aprovaram
select id as cc_a from erp.centros_custo where nome not in ('Obra', 'Marketing') order by nome limit 1 \gset
select id as cc_b from erp.centros_custo where nome not in ('Obra', 'Marketing') order by nome offset 1 limit 1 \gset
select pg_temp.como(:'diretor');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values (:'ne_vm', :'cc_a', true), (:'ne_vm', :'cc_b', true)
  on conflict (nucleo_economico_id, centro_custo_id) do update set ligado = true;
select pg_temp.sis();
insert into erp.alcadas_pagamento (centro_custo_id, ate, ate_titulo, fases) values
  (:'cc_a', null, 1000, '{AF}'), (:'cc_a', null, null, array['AF', 'P:' || :'analista2']), (:'cc_b', null, null, '{AF}');
select pg_temp.volta();
create function pg_temp.tit2(p_id uuid, p_c1 uuid, p_c2 uuid, p_valor numeric, p_pct1 numeric) returns void language sql as $$
  insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
    (p_id, '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000008', '2026-09-02', '2026-09-01', p_valor);
  insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (p_id, 1, '2026-09-20', p_valor);
  insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values (p_id, '40000000-0000-0000-0000-000000000001', p_c1, pg_temp.nat('05.01.04'), p_pct1),
         (p_id, '40000000-0000-0000-0000-000000000001', p_c2, pg_temp.nat('05.01.04'), 100 - p_pct1);
  select erp.confirmar_titulo(p_id); $$;
select pg_temp.como(:'analista');
select pg_temp.tit2('84000000-0000-0000-0000-000000000022', :'cc_a', :'cc_b', 10000, 95);
select pg_temp.ok((select count(*) = 2 from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000022')
                  and (select valor_no_centro = 9500 and cardinality(fases) = 2 from erp.titulo_alcadas
                        where titulo_id = '84000000-0000-0000-0000-000000000022' and centro_custo_id = :'cc_a')
                  and (select valor_no_centro = 500 and fases = '{AF}' from erp.titulo_alcadas
                        where titulo_id = '84000000-0000-0000-0000-000000000022' and centro_custo_id = :'cc_b'),
  'alçada por centro: rateio em dois centros tem uma alçada em cada um, com o valor do centro e a faixa dele');
select pg_temp.tit2('84000000-0000-0000-0000-000000000023', :'cc_a', :'cc_b', 1800, 50);
select pg_temp.ok((select cardinality(fases) = 2 and valor_no_centro = 900 from erp.titulo_alcadas
                    where titulo_id = '84000000-0000-0000-0000-000000000023' and centro_custo_id = :'cc_a'),
  'S-098: o limite do título olha o título inteiro em cada centro (dividir no rateio não baixa a faixa)');
-- quem tem vaga nos dois centros aprova nos dois
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000022', true) = 'pendente', 'alçada por centro: o AF aprova no primeiro centro');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000022', true) = 'pendente', 'alçada por centro: e aprova também no segundo');
select pg_temp.erro_igual($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000022', true)$$,
  'Você já aprovou uma fase de aprovação deste título', 'alçada por centro: dentro do centro, a mesma pessoa não aprova duas vagas');
select pg_temp.como(:'analista');
select pg_temp.ok((select situacao = 'pendente' and vagas_pendentes = array['P:' || :'analista2'] from erp.v_titulo_alcadas
                    where titulo_id = '84000000-0000-0000-0000-000000000022' and centro_custo_id = :'cc_a')
                  and (select situacao = 'aprovado' and vagas_pendentes = '{}' from erp.v_titulo_alcadas
                        where titulo_id = '84000000-0000-0000-0000-000000000022' and centro_custo_id = :'cc_b'),
  'alçada por centro: quem lançou acompanha quais centros e quais vagas faltam');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select erp.decidir_titulo('84000000-0000-0000-0000-000000000022', true, null, false, %L)$$, :'cc_b'),
  'Este centro já aprovou o título', 'alçada por centro: o centro que já aprovou não decide de novo');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000022', true) = 'aprovado',
  'alçada por centro: aprovado em todos os centros, o título está aprovado');
-- o master aprova todos os centros de uma vez
select pg_temp.como(:'diretor');
select erp.decidir_titulo('84000000-0000-0000-0000-000000000023', true) as r_mc \gset
select pg_temp.ok(:'r_mc' = 'aprovado' and not exists (select 1 from erp.v_titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000023' and situacao <> 'aprovado'),
  'alçada por centro: o voto do master aprova todos os centros');
-- o acompanhamento de um centro não conta a aprovação de outro
select pg_temp.como(:'analista');
select pg_temp.tit2('84000000-0000-0000-0000-000000000024', :'cc_a', :'cc_b', 900, 50);
select pg_temp.como(:'contador');
select erp.decidir_titulo('84000000-0000-0000-0000-000000000024', true, null, false, :'cc_a');
select pg_temp.ok((select situacao = 'aprovado' from erp.v_titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000024' and centro_custo_id = :'cc_a')
                  and (select situacao = 'pendente' and vagas_pendentes = '{AF}' from erp.v_titulo_alcadas
                        where titulo_id = '84000000-0000-0000-0000-000000000024' and centro_custo_id = :'cc_b')
                  and erp.alcada_pendente('84000000-0000-0000-0000-000000000024') = 'AF',
  'alçada por centro: a aprovação num centro não conta no outro');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000024', true) = 'aprovado', 'alçada por centro: o AF aprova também no outro centro');
-- paralelo: a vaga pendente é a do centro, não a de outro centro com a mesma posição
select pg_temp.sis();
update erp.alcadas_pagamento set fases = array['P:' || :'analista2', 'AF'], paralelo = true where centro_custo_id = :'cc_a' and ate_titulo is null;
update erp.alcadas_pagamento set fases = array['AF', 'P:' || :'gestor'] where centro_custo_id = :'cc_b';
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit2('84000000-0000-0000-0000-000000000025', :'cc_a', :'cc_b', 10000, 95);
select pg_temp.como(:'contador'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000025', true, null, false, :'cc_b');
select pg_temp.como(:'gestor'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000025', true, null, false, :'cc_b');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('84000000-0000-0000-0000-000000000025', true) = 'pendente'
                  and erp.alcada_pendente('84000000-0000-0000-0000-000000000025') = 'P:' || :'analista2',
  'alçada por centro: em paralelo, o AF aprova a vaga dele no centro, mesmo com a mesma posição aprovada em outro');
-- revisão: quem ajustou aprova a própria vaga em cada centro
select pg_temp.como(:'analista');
select pg_temp.tit2('84000000-0000-0000-0000-000000000026', :'cc_a', :'cc_b', 900, 50);
select pg_temp.sis(); update erp.alcadas_pagamento set fases = '{AF}' where centro_custo_id = :'cc_b'; select pg_temp.volta();
select pg_temp.como(:'contador');
select erp.decidir_titulo('84000000-0000-0000-0000-000000000026', false, 'conferir', true);
select erp.reenviar_titulo('84000000-0000-0000-0000-000000000026', 'conferido');
select pg_temp.ok((select count(*) = 2 and bool_and(origem = 'ajuste' and por = :'contador') from erp.titulo_aprovacoes a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
                    where a.titulo_id = '84000000-0000-0000-0000-000000000026'),
  'alçada por centro: no reenvio, o AF que ajustou já aprova a vaga dele nos dois centros');
-- o último gestor e o último diretor da área não saem com a vaga deles pendente em algum centro
select pg_temp.como(:'diretor'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000006', true);
select pg_temp.como(:'analista');
select pg_temp.tit2('84000000-0000-0000-0000-000000000027', :'cc_b', :'cc_mkt', 1000, 50);
select pg_temp.como(:'contador'); select erp.decidir_titulo('84000000-0000-0000-0000-000000000027', true, null, false, :'cc_b');
select pg_temp.sis();
select pg_temp.erro_igual(format($$delete from erp.centro_aprovadores where centro_custo_id = %L and user_id = %L$$, :'cc_mkt', :'gestor'),
  'O centro tem títulos esperando o gestor da área; cadastre outro gestor antes', 'alçada por centro: a vaga aprovada em outro centro não libera a saída do gestor');
update erp.alcadas_pagamento set fases = '{DIRETOR_AREA}' where centro_custo_id = :'cc_b';
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit('84000000-0000-0000-0000-000000000028', :'cc_b', '05.01.04', 100);
select pg_temp.sis();
insert into erp.centro_diretores (centro_custo_id, user_id) values (:'cc_b', :'diretor2');
select pg_temp.erro_igual(format($$delete from erp.centro_diretores where centro_custo_id = %L and user_id = %L$$, :'cc_b', :'diretor2'),
  'O centro tem títulos esperando o diretor da área; cadastre outro diretor antes', 'alçada por centro: o último diretor da área não sai com a vaga dele pendente');
-- a vaga de papel é do centro; administrador e só da sucessão não ocupam vaga
select pg_temp.ok(not erp._ocupa_vaga('AREA', :'cc_obra', :'gestor') and not erp._ocupa_vaga('DIRETOR_AREA', :'cc_obra', :'diretor2')
                  and erp._ocupa_vaga('DIRETOR_AREA', :'cc_mkt', :'diretor2') and not erp._ocupa_vaga('P:' || :'ti', :'cc_mkt', :'ti'),
  'alçada por centro: gestor e diretor da área só ocupam a vaga no centro deles; o administrador não ocupa vaga');
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values ('00000000-0000-0000-0000-000000000098', '00000000-0000-0000-0000-000000000098', 'Familiar 98', 'leitura', true);
select pg_temp.sis();
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (%L, 2, '{P:00000000-0000-0000-0000-000000000098}')$$, :'cc_mkt'),
  'Usuário só de sucessão não recebe acesso no ERP', 'alçada por centro: usuário só da sucessão não ocupa vaga');
select pg_temp.volta();
-- no modo por núcleo, o acumulado do centro é o do núcleo do rateio que soma mais
select pg_temp.como(:'diretor');
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome) values ('40000000-0000-0000-0000-0000000000a9', :'spe', 'outro', 'Loja 3');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values ('40000000-0000-0000-0000-0000000000a9', :'cc_b', true);
update erp.regra_alcada_pagamento set acumulado = 'nucleo_centro', soma_fornecedor = false;
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('84000000-0000-0000-0000-000000000029', :'spe', 'avulso', '10000000-0000-0000-0000-000000000006', '2026-09-02', '2026-09-01', 5000),
  ('84000000-0000-0000-0000-000000000030', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-09-02', '2026-09-01', 1000);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values
  ('84000000-0000-0000-0000-000000000029', 1, '2026-09-20', 5000), ('84000000-0000-0000-0000-000000000030', 1, '2026-09-20', 1000);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('84000000-0000-0000-0000-000000000029', '40000000-0000-0000-0000-0000000000a9', :'cc_b', pg_temp.nat('05.01.04'), 100),
  ('84000000-0000-0000-0000-000000000030', :'ne_vm', :'cc_b', pg_temp.nat('05.01.04'), 50),
  ('84000000-0000-0000-0000-000000000030', '40000000-0000-0000-0000-0000000000a9', :'cc_b', pg_temp.nat('05.01.04'), 50);
select erp.confirmar_titulo('84000000-0000-0000-0000-000000000029');
select erp.confirmar_titulo('84000000-0000-0000-0000-000000000030');
select pg_temp.ok((select acumulado = 5500 and valor_no_centro = 1000 from erp.titulo_alcadas where titulo_id = '84000000-0000-0000-0000-000000000030'),
  'alçada por centro: no modo por núcleo, vale o núcleo do rateio de maior acumulado');
select pg_temp.como(:'diretor');
update erp.regra_alcada_pagamento set acumulado = 'centro', soma_fornecedor = true;
-- modo livre também no limite do título
select pg_temp.como(:'diretor');
update erp.regras_mudanca_config set modo = 'livre_ate', percentual = 10, meses = 3 where tabela = 'alcadas_pagamento';
select pg_temp.sis();
insert into erp.alcadas_pagamento (id, centro_custo_id, ate, ate_titulo, fases) values ('86000000-0000-0000-0000-000000000006', :'cc_obra', 999999, 3000, '{AF}');
alter table erp.auditoria disable trigger t_auditoria_guarda;
update erp.auditoria set em = em - interval '4 months' where tabela = 'alcadas_pagamento' and registro in ('86000000-0000-0000-0000-000000000004', '86000000-0000-0000-0000-000000000006');
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
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "86000000-0000-0000-0000-000000000006", "ate_titulo": null}', 'sem limite') as lt4 \gset
select pg_temp.ok((select aprovacao <> 'livre' and situacao = 'pendente' from erp.mudancas_config where id = :'lt4'),
  'alçada por centro: tirar o limite do título nunca é livre');
select erp.pedir_mudanca_config('alcadas_pagamento', 'alterar', '{"id": "86000000-0000-0000-0000-000000000004", "paralelo": true}', 'paralelo') as lt3 \gset
select pg_temp.ok((select aprovacao <> 'livre' and situacao = 'pendente' from erp.mudancas_config where id = :'lt3'),
  'alçada por centro: mudar paralelo ou vagas nunca é livre');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# divisões do centro de custo: cadastro, divisão na linha, acesso até a divisão, alçada na divisão e no centro'
begin;
\set dv_pdv '87000000-0000-0000-0000-000000000001'
\set dv_onl '87000000-0000-0000-0000-000000000002'
\set dv_evt '87000000-0000-0000-0000-000000000003'
\set dv_obra '87000000-0000-0000-0000-000000000009'
\set ne1 '40000000-0000-0000-0000-000000000001'
create function pg_temp.tit_div(p_id uuid, p_valor numeric, p_d1 uuid, p_pct1 numeric default 100, p_d2 uuid default null) returns void language sql as $$
  insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
    (p_id, '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', p_valor);
  insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (p_id, 1, '2026-09-20', p_valor);
  insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  select p_id, '40000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000002', d, pg_temp.nat('05.01.04'), pct
    from (values (p_d1, p_pct1), (p_d2, 100 - p_pct1)) v(d, pct) where pct > 0;
  select erp.confirmar_titulo(p_id); $$;
create function pg_temp.acesso_d(u uuid, n uuid, c uuid, d uuid) returns text language plpgsql as $$
declare r text := pg_temp.dono_ini(); a record;
begin select * into a from erp.acesso(u, n, c, d); perform set_config('role', r, false);
  return case when a.ve_tudo and a.lanca then 'lancador' when a.ve_tudo then 'leitor' when a.lanca then 'lancador_restrito' else 'nenhum' end; end $$;

-- cadastro: só por pedido aprovado, como o acesso (S-101), com auditoria; não se apaga nem muda de centro
select pg_temp.como(:'analista');
select pg_temp.falha(format($$insert into erp.divisoes (centro_custo_id, nome) values (%L, 'PDV')$$, :'cc_mkt'), 'divisão: analista não cria divisão');
select pg_temp.ok(pg_temp.erro_como_dono(format($$insert into erp.divisoes (centro_custo_id, nome) values (%L, 'PDV')$$, :'cc_mkt'))
                  = 'Divisão só se cria, renomeia ou desativa por pedido aprovado (erp.pedir_mudanca_acesso)', 'divisão: o gatilho também barra a gravação direta');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$insert into erp.divisoes (centro_custo_id, nome) values (%L, 'PDV')$$, :'cc_mkt'),
  'Divisão só se cria, renomeia ou desativa por pedido aprovado (erp.pedir_mudanca_acesso)', 'divisão: nem o administrador cria direto (S-101)');
select pg_temp.como(null);
-- aprovador: um usuário que não ganha acesso com a divisão nova
\set apv '00000000-0000-0000-0000-0000000000a7'
insert into erp.usuarios (id, login_id, nome, papel) values (:'apv', :'apv', 'Aprovadora de acesso', 'leitura');
delete from erp.aprovadores_acesso;
insert into erp.aprovadores_acesso values (:'apv');
update erp.regra_acesso set minimo = 1;
update erp.regras_mudanca_acesso set exige_aprovacao = true where tabela = 'divisoes';
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'dv_pdv', 'centro_custo_id', :'cc_mkt', 'nome', 'PDV', 'naturezas', pg_temp.folhas()), 'PDV') as mdv \gset
select pg_temp.ok(not exists (select 1 from erp.divisoes where id = :'dv_pdv'), 'divisão: o pedido não vale antes da aprovação (S-101)');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'excluir', jsonb_build_object('id', %L), 'x')$$, :'dv_pdv'),
  'Divisão não se apaga; desative', 'divisão: o pedido não apaga divisão');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('centro_custo_id', %L, 'nome', 'X', 'criado_em', '2000-01-01'), 'x')$$, :'cc_mkt'),
  'O pedido de divisão só cria (centro, nível de cima, nome e naturezas), renomeia e desativa', 'divisão: o pedido não escolhe a data de criação');
select pg_temp.como(:'apv');
select erp.decidir_mudanca_acesso(:'mdv', true) as mdv_sit \gset
select pg_temp.como(null);
select pg_temp.ok(:'mdv_sit' = 'aplicada' and exists (select 1 from erp.divisoes where id = :'dv_pdv' and ativa),
  'divisão: aprovado o pedido, a divisão nasce ativa (S-101)');
-- quem tem o Marketing num modelo ou exceção ganha a divisão nova (futuras) e não aprova o pedido
select b as benef from unnest(erp._beneficiarios_acesso('divisoes', jsonb_build_object('centro_custo_id', :'cc_mkt'), null)) b
  join erp.usuarios u on u.id = b and u.ativo and not u.administrador and not u.so_sucessao order by b limit 1 \gset
insert into erp.aprovadores_acesso values (:'benef');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('centro_custo_id', :'cc_mkt', 'nome', 'Feiras', 'naturezas', pg_temp.folhas()), 'Feiras') as mdv3 \gset
select pg_temp.como(:'benef');
select pg_temp.erro_igual(format($$select erp.decidir_mudanca_acesso(%L, true)$$, :'mdv3'),
  'Quem ganha acesso com a mudança não a aprova', 'divisão: quem tem acesso ao centro não aprova a divisão nova dele');
select pg_temp.como(null);
delete from erp.aprovadores_acesso where user_id = :'benef';
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', %L, 'centro_custo_id', %L), 'x')$$, :'dv_pdv', :'cc_obra'),
  'O pedido de divisão só cria (centro, nível de cima, nome e naturezas), renomeia e desativa', 'divisão: o pedido não muda a divisão de centro');
select pg_temp.como(null);
select user_id as mst from erp.master \gset
select pg_temp.como(:'mst');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'dv_onl', 'centro_custo_id', :'cc_mkt', 'nome', 'Online', 'naturezas', pg_temp.folhas()), 'Online');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'dv_obra', 'centro_custo_id', :'cc_obra', 'nome', 'Fundação', 'naturezas', pg_temp.folhas()), 'Fundação');
select pg_temp.ok((select count(*) from erp.divisoes where id in (:'dv_onl', :'dv_obra')) = 2, 'divisão: o pedido do master vale na hora');
select pg_temp.como(null);
select pg_temp.ok((select count(*) from erp.auditoria where tabela = 'divisoes') = 3, 'divisão: criar divisão fica na auditoria');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$delete from erp.divisoes where id = %L$$, :'dv_onl'), 'Divisão não se apaga; desative', 'divisão: não se apaga');
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.divisoes set centro_custo_id = %L where id = %L$$, :'cc_obra', :'dv_onl'),
  'A divisão não muda de centro de custo, de nível de cima nem de data de criação', 'divisão: não muda de centro');
select pg_temp.falha(format($$insert into erp.divisoes (centro_custo_id, nome) values (%L, 'PDV')$$, :'cc_mkt'), 'divisão: nome repetido no mesmo centro é recusado');
select pg_temp.volta();

-- a linha: o centro com divisão ativa exige a divisão; a divisão é do centro e está ativa
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('88000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', 100);
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('88000000-0000-0000-0000-000000000001', %L, %L, %L, 100)$$, :'ne1', :'cc_mkt', pg_temp.nat('05.01.04')),
  'O centro de custo "Marketing" tem divisões: diga a divisão da linha', 'divisão: centro com divisões exige a divisão na linha');
select pg_temp.falha(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  values ('88000000-0000-0000-0000-000000000001', %L, %L, %L, %L, 100)$$, :'ne1', :'cc_mkt', :'dv_obra', pg_temp.nat('05.01.04')),
  'divisão: divisão de outro centro não entra na linha');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values ('20000000-0000-0000-0000-000000000003', 'manual', %L, %L, %L, '2026-09-01', '2026-09-10', 50)$$, :'ne1', :'cc_mkt', pg_temp.nat('05.01.04')),
  'O centro de custo "Marketing" tem divisões: diga a divisão da linha', 'divisão: a previsão também diz a divisão');
select pg_temp.como(:'ti');
select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', :'dv_onl', 'ativa', false), 'Online pausado') as mdv2 \gset
select pg_temp.como(:'apv'); select erp.decidir_mudanca_acesso(:'mdv2', true); select pg_temp.como(null);
select pg_temp.ok((select not ativa and nome = 'Online' from erp.divisoes where id = :'dv_onl'), 'divisão: desativar também é pedido aprovado (S-101)');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  values ('88000000-0000-0000-0000-000000000001', %L, %L, %L, %L, 100)$$, :'ne1', :'cc_mkt', :'dv_onl', pg_temp.nat('05.01.04')),
  'A divisão está desativada', 'divisão: a desativada não recebe linha nova');
select pg_temp.sis(); update erp.divisoes set ativa = true where id = :'dv_onl'; select pg_temp.volta(); select pg_temp.como(:'analista');
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values ('88000000-0000-0000-0000-000000000001', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('88000000-0000-0000-0000-000000000001', 1, '2026-09-20', 100);
select erp.confirmar_titulo('88000000-0000-0000-0000-000000000001');
select pg_temp.aprova('88000000-0000-0000-0000-000000000001', :'diretor');
select pg_temp.ok((select bool_and(divisao_id = :'dv_pdv') and count(*) > 0 from erp.lancamentos where titulo_id = '88000000-0000-0000-0000-000000000001'),
  'divisão: o livro leva a divisão da linha');
-- pagamento e adiantamento saem carimbados também com a divisão (Moises, 15/11/2026) — num savepoint, para não somar no acumulado da alçada adiante
savepoint div_pagamento;
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000a4', 30, :'dv_onl');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a4', :'diretor');
select erp.pagar_parcela((select id from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a4'),
                         '50000000-0000-0000-0000-000000000001', '2026-09-04') as pg_a4 \gset
select pg_temp.ok((select divisao_id = :'dv_onl' from erp.pagamentos where id = :'pg_a4'),
  'divisão: o pagamento do dia a dia leva a divisão da linha de maior peso');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8a000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-000000000003', 'adiantamento', '10000000-0000-0000-0000-000000000007', '2026-09-03', '2026-09-01', 500);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8a000000-0000-0000-0000-0000000000a1', 1, '2026-09-05', 500);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values ('8a000000-0000-0000-0000-0000000000a1', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('8a000000-0000-0000-0000-0000000000a1');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a1', :'diretor');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor, adiantamento_id) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007', %L, %L, '2026-09-05', 500,
   '8a000000-0000-0000-0000-0000000000a1')$$, :'ne1', :'cc_mkt'),
  'O centro de custo "Marketing" tem divisões: diga a divisão da linha', 'divisão: o pagamento num centro com divisões diz a divisão');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, data, valor, adiantamento_id) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007', %L, %L, %L, '2026-09-05', 500,
   '8a000000-0000-0000-0000-0000000000a1')$$, :'ne1', :'cc_mkt', :'dv_onl'),
  'O pagamento sai com o núcleo, o centro de custo e a divisão do pedido de adiantamento', 'divisão: o adiantamento sai com a divisão do pedido');
select pg_temp.falha(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, data, valor, adiantamento_id) values
  ('20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007', %L, %L, %L, '2026-09-05', 500,
   '8a000000-0000-0000-0000-0000000000a1')$$, :'ne1', :'cc_obra', :'dv_pdv'),
  'divisão: o pagamento não leva divisão de outro centro');
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, data, valor, adiantamento_id) values
  ('8a000000-0000-0000-0000-0000000000b1', '20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007',
   :'ne1', :'cc_mkt', :'dv_pdv', '2026-09-05', 500, '8a000000-0000-0000-0000-0000000000a1');
select pg_temp.ok((select divisao_id = :'dv_pdv' from erp.lancamentos where pagamento_id = '8a000000-0000-0000-0000-0000000000b1' and quitacao_id is null),
  'divisão: o adiantamento entra no livro com a divisão');
select pg_temp.ok((select divisao_id = :'dv_pdv' from erp.v_adiantamentos where pagamento_id = '8a000000-0000-0000-0000-0000000000b1'),
  'divisão: a lista de adiantamentos mostra a divisão');
-- abate só na mesma divisão; em outra, como em outro centro, só com aprovação
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000a2', 50, :'dv_onl');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a2', :'diretor');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 50 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a2'$$,
  'Este pagamento é de outra divisão do mesmo centro; abater aqui precisa de aprovação do gestor do centro ou de AF, AO, AD',
  'divisão: o adiantamento não abate título de outra divisão sem aprovação');
-- em outra divisão do mesmo centro, o gestor do centro também aprova (Moises, 15/11/2026)
select b as gst from unnest(erp._beneficiarios_acesso('divisoes', jsonb_build_object('centro_custo_id', :'cc_mkt'), null)) b
  join erp.usuarios u on u.id = b and u.ativo and not u.administrador and not u.so_sucessao
 where b <> (select user_id from erp.master) and not exists (select 1 from erp.listas_financeiro l where l.user_id = b)
 order by b limit 1 \gset
-- S-103: com uma linha fora do carimbo, o título todo pede a aprovação; o gestor só aprova se tudo é do centro dele
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000a7', 60, :'dv_pdv', 50, :'dv_onl');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a7', :'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8a000000-0000-0000-0000-0000000000a6', '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', 60);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8a000000-0000-0000-0000-0000000000a6', 1, '2026-09-20', 60);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual) values
  ('8a000000-0000-0000-0000-0000000000a6', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 99),
  ('8a000000-0000-0000-0000-0000000000a6', :'ne1', :'cc_obra', :'dv_obra', pg_temp.nat('04.01'), 1);
select erp.confirmar_titulo('8a000000-0000-0000-0000-0000000000a6');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a6', :'diretor');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 60 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a6'$$,
  'Este pagamento é de outro núcleo ou centro de custo; abater aqui precisa de aprovação de AF, AO, AD',
  'S-103: título 99% no carimbo e 1% em outro centro não abate sem aprovação');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 60 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a7'$$,
  'Este pagamento é de outra divisão do mesmo centro; abater aqui precisa de aprovação do gestor do centro ou de AF, AO, AD',
  'S-103: título metade em outra divisão também pede a aprovação');
-- S-104: todo no mesmo centro e divisão, mas com uma linha em outro núcleo: pede o financeiro
select pg_temp.sis();
insert into erp.nucleos_economicos (id, empresa_id, tipo, nome) values ('40000000-0000-0000-0000-0000000000d1', '20000000-0000-0000-0000-000000000003', 'outro', 'Loja D');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values ('40000000-0000-0000-0000-0000000000d1', :'cc_mkt', true);
select pg_temp.volta();
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8a000000-0000-0000-0000-0000000000a8', '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', 60);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8a000000-0000-0000-0000-0000000000a8', 1, '2026-09-20', 60);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual) values
  ('8a000000-0000-0000-0000-0000000000a8', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 99),
  ('8a000000-0000-0000-0000-0000000000a8', '40000000-0000-0000-0000-0000000000d1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 1);
select erp.confirmar_titulo('8a000000-0000-0000-0000-0000000000a8');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a8', :'diretor');
select pg_temp.erro_igual($$insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 60 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a8'$$,
  'Este pagamento é de outro núcleo ou centro de custo; abater aqui precisa de aprovação de AF, AO, AD',
  'S-104: com uma linha em outro núcleo, mesmo no mesmo centro, o abatimento pede AF, AO ou AD');
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_mkt', :'gst'); select pg_temp.volta();
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8a000000-0000-0000-0000-0000000000a5', '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', 40);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8a000000-0000-0000-0000-0000000000a5', 1, '2026-09-20', 40);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values ('8a000000-0000-0000-0000-0000000000a5', :'ne1', :'cc_obra', :'dv_obra', pg_temp.nat('04.01'), 100);
select pg_temp.como(:'apv');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
  values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a2', 'x')$$) = 'Só quem está em AF, AO, AD aprova isto',
  'divisão: quem não é gestor do centro nem do financeiro não aprova abater em outra divisão');
select pg_temp.como(:'gst');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
  values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a5', 'x')$$) = 'Só quem está em AF, AO, AD aprova isto',
  'divisão: o gestor do centro não aprova abater em outro centro');
select pg_temp.como(:'gst');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
  values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a6', 'x')$$) = 'Só quem está em AF, AO, AD aprova isto',
  'S-103: com linha em outro centro, o gestor do centro não aprova');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
  values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a8', 'x')$$) = 'Só quem está em AF, AO, AD aprova isto',
  'S-104: com linha em outro núcleo, o gestor do centro não aprova');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
  values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a7', 'x')$$) is null,
  'S-103: com tudo no centro dele, o gestor aprova');
insert into erp.abatimentos_cruzados (pagamento_id, titulo_id, justificativa)
values ('8a000000-0000-0000-0000-0000000000b1', '8a000000-0000-0000-0000-0000000000a2', 'Online usa o adiantamento do PDV');
select pg_temp.como(:'analista');
insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 50 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a2';
select pg_temp.ok(erp.parcela_saldo((select id from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a2')) = 0,
  'divisão: com a aprovação do gestor do centro, o adiantamento abate o título da outra divisão');
-- o gestor só sai sem título esperando por ele: o master aprova os desta parte antes
select pg_temp.sis(); select pg_temp.aprova(id, :'diretor') from erp.titulos where id::text like '8a000000-%' and erp.alcada_fase(id) is not null; select pg_temp.volta();
select pg_temp.sis(); delete from erp.centro_aprovadores where centro_custo_id = :'cc_mkt' and user_id = :'gst'; select pg_temp.volta();
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000a3', 80, :'dv_pdv');
select pg_temp.aprova('8a000000-0000-0000-0000-0000000000a3', :'diretor');
select pg_temp.ok((select coalesce(sum(valor), 0) = 80 from erp.titulo_coberturas where titulo_id = '8a000000-0000-0000-0000-0000000000a3')
                  and not exists (select 1 from erp.titulo_coberturas where titulo_id = '8a000000-0000-0000-0000-0000000000a2'),
  'divisão: o adiantamento cobre só o título da mesma divisão');
insert into erp.quitacoes (pagamento_id, parcela_id, principal)
  select '8a000000-0000-0000-0000-0000000000b1', id, 80 from erp.parcelas where titulo_id = '8a000000-0000-0000-0000-0000000000a3';
select pg_temp.ok((select bool_and(divisao_id = :'dv_pdv') and count(*) = 2 from erp.lancamentos
                    where pagamento_id = '8a000000-0000-0000-0000-0000000000b1' and quitacao_id is not null
                      and natureza_id = erp.natureza_sistema('adiantamentos')),
  'divisão: o abatimento sai de Adiantamentos com a divisão');
rollback to savepoint div_pagamento;
-- centro sem divisão continua sem pedir divisão
select pg_temp.ok((select count(*) = 0 from erp.divisoes where centro_custo_id = (select id from erp.centros_custo where nome = 'Jurídico')),
  'divisão: os outros centros seguem sem divisão');

-- acesso até a divisão, no esquema dos núcleos: modelo Leitor no Marketing, só a lista (PDV como Lançador)
\set m_pdv 'a0000000-0000-0000-0000-0000000000d1'
select pg_temp.sis();
delete from erp.atribuicoes where user_id = :'analista2';
insert into erp.perfis_modelo (id, nome) values (:'m_pdv', 'Marketing PDV');
insert into erp.perfil_centros (perfil_id, centro_custo_id, nivel, divisoes) values (:'m_pdv', :'cc_mkt', 'leitor', 'lista');
insert into erp.perfil_centro_divisoes (perfil_id, centro_custo_id, divisao_id, incluir, nivel) values (:'m_pdv', :'cc_mkt', :'dv_pdv', true, 'lancador');
insert into erp.atribuicoes (user_id, perfil_id, escopo) values (:'analista2', :'m_pdv', 'todos');
select pg_temp.volta();
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_pdv') = 'lancador'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_onl') = 'nenhum',
  'divisão: na lista, a divisão incluída com nível próprio; a outra fica de fora');
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', null) = 'nenhum',
  'divisão: quem só tem a lista não vê a linha do centro sem divisão');
savepoint div_ve_pagamento;
select pg_temp.sis();
insert into erp.pagamentos (id, empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, divisao_id, data, valor) values
  ('8a000000-0000-0000-0000-0000000000c1', '20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007',
   :'ne1', :'cc_mkt', :'dv_pdv', '2026-09-05', 10),
  ('8a000000-0000-0000-0000-0000000000c2', '20000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000007',
   :'ne1', :'cc_mkt', :'dv_onl', '2026-09-05', 10);
select pg_temp.como(:'analista2');
select pg_temp.ok((select array_agg(id order by id) from erp.pagamentos where id in ('8a000000-0000-0000-0000-0000000000c1', '8a000000-0000-0000-0000-0000000000c2'))
                  = array['8a000000-0000-0000-0000-0000000000c1'::uuid],
  'divisão: quem tem só o PDV vê o pagamento do PDV e não o do Online');
rollback to savepoint div_ve_pagamento;
select pg_temp.sis(); insert into erp.divisoes (id, centro_custo_id, nome, criado_em) values (:'dv_evt', :'cc_mkt', 'Eventos', '2000-01-01'); select pg_temp.volta();
select pg_temp.ok((select criado_em > '2026-01-01' from erp.divisoes where id = :'dv_evt'),
  'divisão: a data de criação é sempre a do cadastro (é o corte das futuras; S-102)');
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_evt') = 'nenhum',
  'divisão: na lista sem a marca das futuras, a divisão nova não entra (S-102)');
select pg_temp.sis(); update erp.perfil_centros set divisoes_futuras = true where perfil_id = :'m_pdv'; select pg_temp.volta();
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_evt') = 'leitor'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_onl') = 'nenhum',
  'divisão: na lista com as futuras, a divisão criada depois entra com o nível do centro; a de antes não');
select pg_temp.sis();
update erp.perfil_centros set divisoes = 'todas', divisoes_futuras = false where perfil_id = :'m_pdv';
insert into erp.perfil_centro_divisoes (perfil_id, centro_custo_id, divisao_id, incluir) values (:'m_pdv', :'cc_mkt', :'dv_onl', false);
select pg_temp.volta();
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_onl') = 'nenhum'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_evt') = 'leitor'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', null) = 'leitor'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_pdv') = 'lancador',
  'divisão: em todas, a excluída fica de fora e as outras (e a linha sem divisão) seguem o centro');
select pg_temp.falha(format($$insert into erp.perfil_centro_divisoes (perfil_id, centro_custo_id, divisao_id, incluir) values (%L, %L, %L, true)$$, :'m_pdv', :'cc_mkt', :'dv_obra'),
  'divisão: o modelo não marca divisão de outro centro');
-- exceção vencida ou de outro núcleo não vale (S-102)
select pg_temp.sis();
insert into erp.excecoes_divisao (user_id, nucleo_economico_id, divisao_id, nivel, fim) values (:'analista2', :'ne1', :'dv_pdv', 'nenhum', current_date - 1);
insert into erp.excecoes_divisao (user_id, nucleo_economico_id, divisao_id, nivel) values (:'analista2', '40000000-0000-0000-0000-000000000002', :'dv_pdv', 'nenhum');
select pg_temp.volta();
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_pdv') = 'lancador',
  'divisão: a exceção vencida e a de outro núcleo não valem (S-102)');
select pg_temp.sis(); delete from erp.excecoes_divisao where user_id = :'analista2'; select pg_temp.volta();
-- natureza restrita liberada pelo modelo só onde o modelo dá a divisão; lançar confere a divisão (S-102)
select pg_temp.sis();
update erp.naturezas set restrita = true where codigo = '05.01.02';
insert into erp.perfil_naturezas values (:'m_pdv', pg_temp.nat('05.01.02'));
select pg_temp.volta();
create function pg_temp.lib_d(u uuid, n uuid, c uuid, nat uuid, d uuid, out lib boolean, out lanca boolean) language plpgsql as $$
declare r text := pg_temp.dono_ini();
begin lib := erp.natureza_liberada(u, n, c, nat, d); lanca := erp.lanca_linha(u, n, c, null, d); perform set_config('role', r, false); end $$;
-- desde 18/11/2026 o modelo não libera a restrita (PJ, só o master e os designados); o lançar segue a divisão
select pg_temp.ok((select not lib and lanca from pg_temp.lib_d(:'analista2', :'ne1', :'cc_mkt', pg_temp.nat('05.01.02'), :'dv_pdv'))
                  and (select not lib and not lanca from pg_temp.lib_d(:'analista2', :'ne1', :'cc_mkt', pg_temp.nat('05.01.02'), :'dv_onl')),
  'divisão: o lançar vale só nas divisões que o modelo dá, e o modelo não libera a restrita (S-102)');
select pg_temp.sis(); delete from erp.perfil_naturezas where perfil_id = :'m_pdv'; update erp.naturezas set restrita = false where codigo = '05.01.02'; select pg_temp.volta();
-- exceção da divisão vence a do centro
select pg_temp.sis();
insert into erp.excecoes_centro (user_id, nucleo_economico_id, centro_custo_id, nivel) values (:'analista2', :'ne1', :'cc_mkt', 'lancador');
insert into erp.excecoes_divisao (user_id, nucleo_economico_id, divisao_id, nivel) values (:'analista2', :'ne1', :'dv_pdv', 'nenhum');
select pg_temp.volta();
select pg_temp.ok(pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_pdv') = 'nenhum'
                  and pg_temp.acesso_d(:'analista2', :'ne1', :'cc_mkt', :'dv_onl') = 'lancador',
  'divisão: a exceção da divisão vence a do centro, que vale nas outras divisões');
-- pela API, com o PDV tirado pela exceção: a previsão, o orçamento e o título do PDV seguem a divisão (S-102)
select pg_temp.sis();
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
values ('8a000000-0000-0000-0000-0000000000a1', '20000000-0000-0000-0000-000000000003', 'manual', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), '2026-09-01', '2026-09-10', 50);
insert into erp.orcamento_versoes (id, empresa_id, tipo, nome, data_base) values ('88000000-0000-0000-0000-0000000000a2', '20000000-0000-0000-0000-000000000003', 'viabilidade', 'div', '2026-01-01');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('88000000-0000-0000-0000-0000000000a3', '20000000-0000-0000-0000-000000000003', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-09-02', '2026-09-01', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values ('88000000-0000-0000-0000-0000000000a3', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), 100);
select pg_temp.volta();
select pg_temp.como(:'analista2');
select pg_temp.ok(not exists (select 1 from erp.previsoes where id = '8a000000-0000-0000-0000-0000000000a1'),
  'divisão: a previsão da divisão tirada some (S-102)');
select pg_temp.falha(format($$insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, valor)
  values ('88000000-0000-0000-0000-0000000000a2', %L, %L, %L, %L, '2026-09-01', -10)$$, :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04')),
  'divisão: não lança orçamento na divisão tirada (S-102)');
insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, valor)
values ('88000000-0000-0000-0000-0000000000a2', :'ne1', :'cc_mkt', :'dv_onl', pg_temp.nat('05.01.04'), '2026-09-01', -10);
select pg_temp.ok(not erp.lanco_titulo('88000000-0000-0000-0000-0000000000a3'),
  'divisão: não grava no título com linha na divisão tirada (S-102)');
select pg_temp.como(:'analista');
select pg_temp.ok(not exists (select 1 from erp.excecoes_divisao where user_id = :'analista2'),
  'divisão: a exceção da divisão de outra pessoa não aparece para quem não cuida de acesso (S-102)');
-- pela API: o título do PDV some para quem perdeu o PDV
select pg_temp.como(:'analista2');
select pg_temp.ok(not erp.vejo_titulo('88000000-0000-0000-0000-000000000001')
                  and not exists (select 1 from erp.lancamentos where titulo_id = '88000000-0000-0000-0000-000000000001'),
  'divisão: sem acesso à divisão, a pessoa não vê o título nem o livro dele');
select pg_temp.sis(); delete from erp.excecoes_divisao where user_id = :'analista2'; select pg_temp.volta();
select pg_temp.ok(erp.vejo_titulo('88000000-0000-0000-0000-000000000001'), 'divisão: com a divisão de volta, vê o título');
-- as tabelas de acesso da divisão só mudam por pedido aprovado; a data do corte das futuras é a de quando vale
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$insert into erp.excecoes_divisao (user_id, nucleo_economico_id, divisao_id, nivel) values (%L, %L, %L, 'leitor')$$, :'leitor', :'ne1', :'dv_pdv'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'divisão: exceção da divisão só por pedido');
select pg_temp.erro_igual(format($$insert into erp.perfil_centro_divisoes (perfil_id, centro_custo_id, divisao_id, incluir) values (%L, %L, %L, false)$$, :'tudo', :'cc_mkt', :'dv_evt'),
  'Mudança de acesso só por pedido aprovado (erp.pedir_mudanca_acesso)', 'divisão: divisão do modelo só por pedido');
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('perfil_centros', 'incluir',
  jsonb_build_object('perfil_id', :'m_pdv', 'centro_custo_id', :'cc_obra', 'nivel', 'leitor', 'divisoes', 'lista', 'divisoes_futuras', true, 'criado_em', '2000-01-01'), 'teste') as pc1 \gset
select pg_temp.ok((select criado_em > '2026-01-01' and divisoes = 'lista' and divisoes_futuras from erp.perfil_centros where perfil_id = :'m_pdv' and centro_custo_id = :'cc_obra'),
  'divisão: o corte das divisões futuras é a data em que o pedido vale, nunca a do pedido');
select pg_temp.ok(pg_temp.acesso_d(:'analista2', '40000000-0000-0000-0000-000000000001', :'cc_obra', :'dv_obra') = 'nenhum',
  'divisão: a divisão criada antes do corte não entra pelas futuras');
select erp.pedir_mudanca_acesso('excecoes_divisao', 'incluir',
  jsonb_build_object('user_id', :'leitor', 'nucleo_economico_id', :'ne1', 'divisao_id', :'dv_pdv', 'nivel', 'lancador'), 'teste') as ed1 \gset
select pg_temp.ok((select situacao = 'aplicada' and beneficiarios = array[:'leitor']::uuid[] from erp.mudancas_acesso where id = :'ed1'),
  'divisão: o pedido de exceção da divisão aplica e marca quem ganha o acesso');

-- alçada na divisão: o PDV tem faixas próprias; até 5 mil no mês, só a divisão; acima, a divisão e o centro
select pg_temp.sis();
-- a previsão do PDV do teste da S-102 nasceu sem alçada (aprovada) e entraria no acumulado; aqui conta só o título
update erp.previsoes set situacao = 'cancelada' where id = '8a000000-0000-0000-0000-0000000000a1';
update erp.regra_alcada_pagamento set soma_fornecedor = false;
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor');
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador');
insert into erp.alcadas_pagamento (id, centro_custo_id, divisao_id, ate, fases, passa_pelo_centro) values
  ('86000000-0000-0000-0000-0000000000d1', :'cc_mkt', :'dv_pdv', 5000, array['P:' || :'analista2'], false),
  ('86000000-0000-0000-0000-0000000000d2', :'cc_mkt', :'dv_pdv', null, array['P:' || :'analista2'], true),
  ('86000000-0000-0000-0000-0000000000d3', :'cc_mkt', null, 1000000, '{AREA,AF}', false);
select pg_temp.ok((select count(*) = 3 and bool_and(centro_id = :'cc_mkt') from erp.eventos
                    where tipo = 'alcada_alterada' and registro like '86000000-0000-0000-0000-0000000000d_'),
  'divisão: o evento da faixa leva o centro dela (S-100)');
delete from erp.alcadas_pagamento where id = '86000000-0000-0000-0000-0000000000d1';
select pg_temp.ok((select centro_id = :'cc_mkt' from erp.eventos where tipo = 'alcada_alterada' and dados->>'acao' = 'delete'
                    and registro = '86000000-0000-0000-0000-0000000000d1'),
  'divisão: no delete, o evento leva o centro da faixa apagada (S-100)');
insert into erp.alcadas_pagamento (id, centro_custo_id, divisao_id, ate, fases, passa_pelo_centro) values
  ('86000000-0000-0000-0000-0000000000d1', :'cc_mkt', :'dv_pdv', 5000, array['P:' || :'analista2'], false);
-- previsão na divisão com faixas próprias: a faixa que manda passar pelo centro leva também à alçada do centro (18/11/2026)
savepoint div_prev_centro;
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-0000000000f2', '20000000-0000-0000-0000-000000000003', 'manual', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-20', 50);
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor) values
  ('68000000-0000-0000-0000-0000000000f3', '20000000-0000-0000-0000-000000000003', 'manual', :'ne1', :'cc_mkt', :'dv_pdv', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-20', 6000);
select pg_temp.ok((select array_agg(divisao_id is null order by divisao_id is null) = '{f}' from erp.previsao_alcadas
                    where previsao_id = '68000000-0000-0000-0000-0000000000f2'),
  'previsão: na divisão com faixa que não passa pelo centro, só a alçada da divisão');
select pg_temp.ok((select array_agg(divisao_id is null order by divisao_id is null) = '{f,t}' from erp.previsao_alcadas
                    where previsao_id = '68000000-0000-0000-0000-0000000000f3'),
  'previsão: na divisão com faixa que passa pelo centro, a alçada da divisão e a do centro');
rollback to savepoint div_prev_centro;
select pg_temp.falha($$insert into erp.alcadas_pagamento (ate, fases, passa_pelo_centro) values (7, '{AF}', true)$$,
  'divisão: só a faixa da divisão passa pelo centro');
select pg_temp.falha(format($$insert into erp.alcadas_pagamento (centro_custo_id, divisao_id, ate, fases) values (%L, %L, 7, '{AF}')$$, :'cc_obra', :'dv_pdv'),
  'divisão: a faixa da divisão é do centro dela');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('88000000-0000-0000-0000-000000000002', 1000, :'dv_pdv');
select pg_temp.ok((select count(*) = 1 and bool_and(divisao_id = :'dv_pdv' and alcada_id = '86000000-0000-0000-0000-0000000000d1' and acumulado = 1100)
                     from erp.titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000002'),
  'divisão: até o limite, só a alçada da divisão, com o acumulado só da divisão');
select pg_temp.tit_div('88000000-0000-0000-0000-000000000003', 300, :'dv_onl');
select pg_temp.ok((select count(*) = 1 and bool_and(divisao_id is null and acumulado = 1400 and fases = '{AREA,AF}' and alcada_id = '86000000-0000-0000-0000-0000000000d3')
                     from erp.titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000003'),
  'divisão: a divisão sem faixas segue a alçada do centro, que soma o centro inteiro');
select pg_temp.tit_div('88000000-0000-0000-0000-000000000004', 4000, :'dv_pdv');
select pg_temp.ok((select count(*) = 2
                          and bool_or(divisao_id = :'dv_pdv' and alcada_id = '86000000-0000-0000-0000-0000000000d2' and acumulado = 5100)
                          and bool_or(divisao_id is null and acumulado = 5400 and valor_no_centro = 4000)
                     from erp.titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000004'),
  'divisão: acima do limite da divisão, a faixa manda passar também pelo centro');
-- quem aprova: a pessoa da vaga na divisão, o gestor e o AF no centro; cada alçada com a sua aprovação
select pg_temp.como(:'analista2');
select erp.decidir_titulo('88000000-0000-0000-0000-000000000004', true) as dbg \gset
select pg_temp.ok(:'dbg' = 'pendente'
                  and (select situacao = 'aprovado' from erp.v_titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000004' and divisao = 'PDV')
                  and (select situacao = 'pendente' from erp.v_titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000004' and divisao_id is null),
  'divisão: a divisão aprova e o acompanhamento mostra o centro ainda pendente');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select erp.decidir_titulo('88000000-0000-0000-0000-000000000004', true, null, false, %L, %L)$$, :'cc_mkt', :'dv_pdv'),
  'Esta divisão já aprovou o título', 'divisão: a alçada pedida já aprovada é recusada');
select pg_temp.erro_igual(format($$select erp.decidir_titulo('88000000-0000-0000-0000-000000000004', true, null, false, %L, %L)$$, :'cc_mkt', :'dv_onl'),
  'Esta divisão não tem alçada própria neste título', 'divisão: divisão sem alçada no título é recusada');
select erp.decidir_titulo('88000000-0000-0000-0000-000000000004', true, null, false, :'cc_mkt');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('88000000-0000-0000-0000-000000000004', true) = 'aprovado', 'divisão: com a divisão e o centro, o título fica aprovado');
-- rateio entre duas divisões: o PDV com a alçada dele (a parte dele) e o centro pela linha do Online
select pg_temp.como(:'analista');
select pg_temp.tit_div('88000000-0000-0000-0000-000000000005', 2000, :'dv_pdv', 50, :'dv_onl');
select pg_temp.ok((select count(*) = 2
                          and bool_or(divisao_id = :'dv_pdv' and valor_no_centro = 1000)
                          and bool_or(divisao_id is null and valor_no_centro = 2000)
                     from erp.titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000005'),
  'divisão: no rateio entre divisões, a do PDV pela parte dele e o centro pelo centro inteiro');
select pg_temp.como(:'contador');
select pg_temp.ok((select count(*) = 1 and bool_and(divisao_id is null) from erp.titulos_do_acumulado('88000000-0000-0000-0000-000000000005')
                    where titulo_id is not null and titulo_id = '88000000-0000-0000-0000-000000000005'),
  'divisão: o AF vê o acumulado só da alçada em que aprova');
select pg_temp.como(:'diretor');
select erp.decidir_titulo('88000000-0000-0000-0000-000000000005', true) as dbg5 \gset
select pg_temp.ok(:'dbg5' = 'aprovado'
                  and (select count(*) = 2 from erp.v_titulo_alcadas where titulo_id = '88000000-0000-0000-0000-000000000005' and situacao = 'aprovado'),
  'divisão: o master aprova a divisão e o centro de uma vez');
-- quem tem vaga na divisão e no centro aprova uma vez só, e vale pelas duas (Moises, 15/11/2026)
savepoint div_duas;
select pg_temp.sis(); update erp.alcadas_pagamento set fases = '{AREA}' where id = '86000000-0000-0000-0000-0000000000d2'; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000e1', 3000, :'dv_pdv');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e1', true) as e1 \gset
select pg_temp.ok(:'e1' = 'pendente'
                  and (select count(*) = 2 and bool_and(lista = 'AREA' and por = :'gestor'::uuid) and count(*) filter (where origem = 'outra_alcada') = 1
                         from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e1'),
  'divisão: a aprovação do gestor na divisão vale também na vaga dele no centro');
-- mesmo pelo papel das operações do banco, a aprovação de outra alçada tem de ser da mesma pessoa
select set_config('role', 'erp_situacao', false);
select pg_temp.erro_igual(format($$insert into erp.titulo_aprovacoes (alcada_id, fase, lista, aprovado, por, origem, vale_de)
  select a.id, 2, 'AF', true, %L, 'outra_alcada', d.id from erp.titulo_alcadas a join erp.titulo_alcadas d on d.titulo_id = a.titulo_id and d.divisao_id is not null
   where a.titulo_id = '8a000000-0000-0000-0000-0000000000e1' and a.divisao_id is null$$, :'contador'),
  'A aprovação na outra alçada precisa ser da mesma pessoa, no mesmo centro do título',
  'divisão: só vale na outra alçada a aprovação que a mesma pessoa deu');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e1', true) = 'aprovado', 'divisão: falta só o AF, e o título fica aprovado');
-- em sequência, a vaga do gestor no centro chega depois do AF: a aprovação dele na divisão vale quando ela chega
select pg_temp.sis(); update erp.alcadas_pagamento set fases = '{AF,AREA}' where id = '86000000-0000-0000-0000-0000000000d3'; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000e2', 3000, :'dv_pdv');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e2', true) as e2 \gset
select pg_temp.ok(:'e2' = 'pendente'
                  and (select count(*) = 1 from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e2'),
  'divisão: em sequência, a aprovação não pula a vez do AF no centro');
select pg_temp.erro_igual($$select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e2', true)$$,
  'Esta fase de aprovação é de quem está em AF', 'divisão: o gestor não aprova de novo nem fura a vez do AF');
select pg_temp.como(:'contador');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e2', true) as e2b \gset
select pg_temp.ok(:'e2b' = 'aprovado'
                  and (select origem = 'outra_alcada' from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e2' and lista = 'AREA' and divisao_id is null),
  'divisão: depois do AF, a aprovação do gestor na divisão vale no centro');
-- S-104: não vale entre duas divisões (o PDV e o Online com alçada própria cada um)
select pg_temp.sis();
update erp.alcadas_pagamento set fases = '{AREA,AF}', paralelo = true where id = '86000000-0000-0000-0000-0000000000d3';
insert into erp.alcadas_pagamento (id, centro_custo_id, divisao_id, ate, fases, passa_pelo_centro) values
  ('86000000-0000-0000-0000-0000000000d4', :'cc_mkt', :'dv_onl', null, '{AREA}', false);
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000e3', 2000, :'dv_pdv', 50, :'dv_onl');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e3', true, null, false, :'cc_mkt', :'dv_pdv') as e3 \gset
select pg_temp.ok(:'e3' = 'pendente'
                  and (select count(*) = 1 from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e3' and divisao_id is null)
                  and not exists (select 1 from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e3' and divisao_id = :'dv_onl'),
  'S-104: a aprovação na divisão vale no centro, mas não na outra divisão');
-- S-104: em paralelo, quem tem duas vagas no centro ganha só uma pela aprovação na divisão
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000e4', 2000, :'dv_pdv');
select pg_temp.como(:'gestor');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e4', true, null, false, :'cc_mkt', :'dv_pdv') as e4 \gset
select pg_temp.ok(:'e4' = 'pendente'
                  and (select count(*) = 1 from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e4' and divisao_id is null),
  'S-104: a aprovação na divisão vale por uma vaga só no centro');
-- S-104: a AD que aprova o próprio lançamento na divisão não ganha a vaga dela no centro
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id, aprova_proprio) values ('AD', :'analista', true)
  on conflict (lista, user_id) do update set aprova_proprio = true;
update erp.alcadas_pagamento set fases = '{AD}' where id = '86000000-0000-0000-0000-0000000000d2';
update erp.alcadas_pagamento set fases = '{AD,AF}' where id = '86000000-0000-0000-0000-0000000000d3';
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.tit_div('8a000000-0000-0000-0000-0000000000e5', 2000, :'dv_pdv');
select erp.decidir_titulo('8a000000-0000-0000-0000-0000000000e5', true, null, false, :'cc_mkt', :'dv_pdv') as e5 \gset
select pg_temp.ok(:'e5' = 'pendente'
                  and (select bool_and(proprio) and count(*) = 1 from erp.titulo_aprovacoes where titulo_id = '8a000000-0000-0000-0000-0000000000e5'),
  'S-104: a aprovação do próprio lançamento não vale na outra alçada');
rollback to savepoint div_duas;
-- a aprovação sempre aponta a alçada dela, com o centro e a divisão copiados dela
select pg_temp.ok((select bool_and(v.centro_custo_id = a.centro_custo_id and v.divisao_id is not distinct from a.divisao_id and v.titulo_id = a.titulo_id)
                     from erp.titulo_aprovacoes v join erp.titulo_alcadas a on a.id = v.alcada_id),
  'divisão: a aprovação leva o centro e a divisão da alçada');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# notificações: painel, sino e fila (Moises, 15/11/2026)'
begin;
\set u_n '00000000-0000-0000-0000-000000000021'
-- crítico vai ao master por e-mail e WhatsApp, sem regra
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista2');
select pg_temp.ok(exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                           where e.tipo = 'lista_financeiro_alterada' and e.registro = :'analista2' and n.user_id = :'diretor' and n.critico)
                  and (select count(*) from erp.envios_notificacao v join erp.notificacoes n on n.id = v.notificacao_id
                        join erp.eventos e on e.id = n.evento_id
                        where e.tipo = 'lista_financeiro_alterada' and e.registro = :'analista2' and n.user_id = :'diretor') = 2,
  'notificações: entrar alguém na AF avisa o master no sino, no e-mail e no WhatsApp');
insert into erp.usuarios (id, login_id, nome, papel, administrador) values (:'u_n', :'u_n', 'TI 2', 'leitura', true);
select pg_temp.ok(exists (select 1 from erp.notificacoes where tipo = 'administrador_alterado' and user_id = :'diretor'),
  'notificações: administrador novo avisa o master');
select pg_temp.volta();

-- preferência: crítico só desliga o WhatsApp
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$insert into erp.preferencias_notificacao (user_id, tipo, canal) values ('00000000-0000-0000-0000-00000000000a', 'lista_financeiro_alterada', 'email')$$,
  'Aviso crítico não se desliga no e-mail; só no WhatsApp', 'notificações: o aviso crítico não se desliga no e-mail');
insert into erp.preferencias_notificacao (user_id, tipo, canal) values (:'diretor', 'lista_financeiro_alterada', 'whatsapp');
select pg_temp.falha($$insert into erp.preferencias_notificacao (user_id, tipo, canal) values ('00000000-0000-0000-0000-00000000000b', 'natureza_sistema_alterada', 'email')$$,
  'notificações: ninguém mexe na preferência de outra pessoa');
select pg_temp.sis();
delete from erp.listas_financeiro where lista = 'AF' and user_id = :'analista2';
select pg_temp.ok((select array_agg(v.canal) from erp.envios_notificacao v join erp.notificacoes n on n.id = v.notificacao_id
                    join erp.eventos e on e.id = n.evento_id
                   where e.tipo = 'lista_financeiro_alterada' and e.dados->>'acao' = 'delete' and n.user_id = :'diretor') = '{email}',
  'notificações: com o WhatsApp desligado, o crítico segue no sino e no e-mail');
select pg_temp.volta();

-- o painel: o administrador não grava direto; pede, e o master aprova
select pg_temp.como(:'ti');
select pg_temp.erro_igual($$insert into erp.regras_notificacao (tipo, destino, user_id) values ('natureza_sistema_alterada', 'pessoa', '00000000-0000-0000-0000-00000000000b')$$,
  'O painel de notificações muda pelo pedido (erp.pedir_mudanca_config), que o master aprova',
  'notificações: o administrador não muda o painel direto');
select erp.pedir_mudanca_config('regras_notificacao', 'incluir',
  jsonb_build_object('tipo', 'natureza_sistema_alterada', 'destino', 'pessoa', 'user_id', :'analista'), 'avisar o Rafael') as pn \gset
select pg_temp.ok((select aprovacao = 'master' from erp.mudancas_config where id = :'pn')
                  and not exists (select 1 from erp.regras_notificacao where tipo = 'natureza_sistema_alterada'),
  'notificações: o pedido do administrador no painel vai ao master e não vale antes');
select pg_temp.ok(not exists (select 1 from erp.notificacoes where tipo = 'mudanca_config_pedida'),
  'notificações: quem pediu não é avisado do próprio pedido (e não vê o sino dos outros)');
select pg_temp.sis();
select pg_temp.ok((select detalhe from erp.notificacoes where tipo = 'mudanca_config_pedida' and user_id = :'diretor') = 'Motivo: avisar o Rafael',
  'notificações: o master recebe o pedido com o motivo, sem "falta de aprovadores" (no painel, quem aprova é ele)');
select pg_temp.volta();
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_config(:'pn', true);
select pg_temp.ok(exists (select 1 from erp.regras_notificacao where tipo = 'natureza_sistema_alterada' and user_id = :'analista'),
  'notificações: aprovado pelo master, o painel muda');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'notificacoes_alteradas' and tabela = 'regras_notificacao' and por = :'diretor' and dados->>'mudanca_id' = :'pn')
                  and not exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                                   where e.tipo = 'notificacoes_alteradas' and n.user_id = :'diretor'),
  'notificações: a mudança do painel vira evento crítico; quem agiu (o master) não é avisado do que fez');
select pg_temp.volta();

-- a lista de críticos: o administrador pede, o master aprova
select pg_temp.como(:'ti');
select erp.pedir_mudanca_config('tipos_evento', 'alterar', '{"codigo": "natureza_sistema_alterada", "critico": true}', 'é sensível') as pc \gset
select pg_temp.como(:'diretor');
select erp.decidir_mudanca_config(:'pc', true);
select pg_temp.ok((select critico from erp.tipos_evento where codigo = 'natureza_sistema_alterada'),
  'notificações: a lista de críticos muda pelo pedido aprovado pelo master');
select pg_temp.falha($$insert into erp.tipos_evento (codigo, rotulo, modulo) values ('x', 'X', 'x')$$,
  'notificações: tipo de evento novo só pela carga');

-- ninguém recebe o que não pode ver
select pg_temp.sis();
insert into erp.regras_notificacao (tipo, destino, user_id) values ('natureza_sistema_alterada', 'pessoa', :'ti');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'com-centro', :'ne_vm', :'cc_mkt', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'sem-centro', null, null, '{}');
select pg_temp.ok(exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id where e.registro = 'com-centro' and n.user_id = :'analista')
                  and not exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id where e.registro = 'com-centro' and n.user_id = :'ti')
                  and exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id where e.registro = 'sem-centro' and n.user_id = :'ti'),
  'notificações: o evento do centro não vai a quem não vê o centro; o de configuração vai');
select pg_temp.volta();

-- o sino
select pg_temp.como(:'analista');
select pg_temp.ok((select count(*) from erp.notificacoes) > 0 and not exists (select 1 from erp.notificacoes where user_id <> :'analista'),
  'notificações: cada um vê só o próprio sino');
select erp.marcar_notificacoes_lidas() as lidas \gset
select pg_temp.ok(:lidas > 0 and not exists (select 1 from erp.notificacoes where lida_em is null), 'notificações: marcar como lidas');
select pg_temp.falha($$update erp.notificacoes set titulo = 'x'$$, 'notificações: a notificação não se altera pela API');
select pg_temp.falha($$select * from erp.envios_notificacao$$, 'notificações: a fila de envio não se lê pela API');
select pg_temp.falha($$select erp.registrar_envio_notificacao(1, 'email')$$, 'notificações: só o servidor registra o envio');

-- o servidor marca o envio
select pg_temp.sis();
select v.notificacao_id as nv from erp.envios_notificacao v join erp.notificacoes n on n.id = v.notificacao_id
 where n.user_id = :'diretor' and v.canal = 'email' limit 1 \gset
select erp.registrar_envio_notificacao(:nv, 'email', 'caixa cheia');
select erp.registrar_envio_notificacao(:nv, 'email');
select pg_temp.ok((select tentativas = 2 and enviado_em is not null and erro is null from erp.envios_notificacao where notificacao_id = :nv and canal = 'email'),
  'notificações: a tentativa que falhou fica contada e o envio é marcado');
select pg_temp.falha(format($$select erp.registrar_envio_notificacao(%s, 'email')$$, :nv), 'notificações: envio já feito não se registra de novo');

-- S-099: quem recebe, por destino e filtro
\set u_vm  '00000000-0000-0000-0000-000000000022'
\set u_ina '00000000-0000-0000-0000-000000000023'
\set u_suc '00000000-0000-0000-0000-000000000024'
insert into erp.usuarios (id, login_id, nome, papel, ativo) values
  (:'u_vm', :'u_vm', 'Só Vila Maria Marketing', 'analista', true),
  (:'u_ina', :'u_ina', 'Inativo', 'leitura', false);
insert into erp.usuarios (id, login_id, nome, papel, so_sucessao) values (:'u_suc', :'u_suc', 'Só da sucessão', 'leitura', true);
insert into erp.perfis_modelo (id, nome) values ('a2000000-0000-0000-0000-000000000099', 'Só Marketing (notificações)');
insert into erp.perfil_centros values ('a2000000-0000-0000-0000-000000000099', :'cc_mkt', 'leitor');
insert into erp.atribuicoes (id, user_id, perfil_id, escopo) values ('a3000000-0000-0000-0000-000000000099', :'u_vm', 'a2000000-0000-0000-0000-000000000099', 'lista');
insert into erp.atribuicao_nucleos values ('a3000000-0000-0000-0000-000000000099', :'ne_vm', true);
insert into erp.centro_aprovadores values (:'cc_obra', :'gestor');
insert into erp.aprovadores_config values ('contas_bancarias', :'contador');
insert into erp.regras_notificacao (tipo, destino, user_id) values ('natureza_sistema_alterada', 'pessoa', :'u_vm');
insert into erp.regras_notificacao (tipo, destino, papel) values ('natureza_sistema_alterada', 'papel', 'leitura');
insert into erp.regras_notificacao (tipo, destino, user_id, ativa) values ('natureza_sistema_alterada', 'pessoa', :'diretor2', false);
insert into erp.regras_notificacao (tipo, destino, user_id, centro_id) values ('natureza_sistema_alterada', 'pessoa', :'analista2', :'cc_obra');
insert into erp.regras_notificacao (tipo, destino, user_id, nucleo_id) values ('natureza_sistema_alterada', 'pessoa', :'analista2', :'ne_corp');
insert into erp.regras_notificacao (tipo, destino) values ('natureza_sistema_alterada', 'gestor_centro'), ('natureza_sistema_alterada', 'aprovadores_config');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'vm-mkt', :'ne_vm', :'cc_mkt', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'vm-obra', :'ne_vm', :'cc_obra', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'corp-mkt', :'ne_corp', :'cc_mkt', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'so-obra', null, :'cc_obra', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'so-corp', :'ne_corp', null, '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'contas_bancarias', 'geral', null, null, '{}');
create function pg_temp.recebeu(u uuid, reg text) returns boolean language sql as
  $$ select exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id where n.user_id = u and e.registro = reg) $$;
select pg_temp.ok(pg_temp.recebeu(:'u_vm', 'vm-mkt') and not pg_temp.recebeu(:'u_vm', 'vm-obra') and not pg_temp.recebeu(:'u_vm', 'corp-mkt')
                  and not pg_temp.recebeu(:'u_vm', 'so-obra') and not pg_temp.recebeu(:'u_vm', 'so-corp') and pg_temp.recebeu(:'u_vm', 'geral'),
  'S-099: quem vê só um núcleo × centro recebe só os eventos dele (centro e núcleo conferidos)');
select pg_temp.ok(pg_temp.recebeu(:'leitor', 'geral') and not pg_temp.recebeu(:'u_ina', 'geral') and not pg_temp.recebeu(:'u_suc', 'geral'),
  'S-099: o inativo e o só da sucessão não recebem, mesmo pelo papel');
select pg_temp.ok(not pg_temp.recebeu(:'diretor2', 'geral'), 'S-099: regra desligada não vale');
select pg_temp.ok(pg_temp.recebeu(:'analista2', 'vm-obra') and pg_temp.recebeu(:'analista2', 'corp-mkt')
                  and not pg_temp.recebeu(:'analista2', 'vm-mkt') and not pg_temp.recebeu(:'analista2', 'geral'),
  'S-099: a regra com centro ou núcleo vale só para eventos dele');
select pg_temp.ok(pg_temp.recebeu(:'gestor', 'vm-obra') and not pg_temp.recebeu(:'gestor', 'vm-mkt'),
  'S-099: o gestor do centro recebe só os eventos do centro dele');
select pg_temp.ok(pg_temp.recebeu(:'contador', 'geral') and not pg_temp.recebeu(:'contador', 'vm-mkt'),
  'S-099: o aprovador da configuração recebe só os eventos da tabela dele');
-- a divisão do evento: quem só tem o PDV recebe o do PDV, não o do Online nem o do Marketing inteiro
\set dvn_pdv 'd1000000-0000-0000-0000-0000000000a1'
\set dvn_onl 'd1000000-0000-0000-0000-0000000000a2'
\set dvn_obr 'd1000000-0000-0000-0000-0000000000a3'
\set u_pdv   '00000000-0000-0000-0000-000000000025'
insert into erp.divisoes (id, centro_custo_id, nome) values (:'dvn_pdv', :'cc_mkt', 'PDV n'), (:'dvn_onl', :'cc_mkt', 'Online n'), (:'dvn_obr', :'cc_obra', 'Obra n');
insert into erp.usuarios (id, login_id, nome, papel) values (:'u_pdv', :'u_pdv', 'Só o PDV', 'analista');
insert into erp.perfis_modelo (id, nome) values ('a2000000-0000-0000-0000-000000000098', 'Só o PDV (notificações)');
insert into erp.perfil_centros (perfil_id, centro_custo_id, nivel, divisoes) values ('a2000000-0000-0000-0000-000000000098', :'cc_mkt', 'leitor', 'lista');
insert into erp.perfil_centro_divisoes (perfil_id, centro_custo_id, divisao_id, incluir) values ('a2000000-0000-0000-0000-000000000098', :'cc_mkt', :'dvn_pdv', true);
insert into erp.atribuicoes (user_id, perfil_id, escopo) values (:'u_pdv', 'a2000000-0000-0000-0000-000000000098', 'todos');
insert into erp.regras_notificacao (tipo, destino, user_id) values ('natureza_sistema_alterada', 'pessoa', :'u_pdv');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-pdv', null, :'cc_mkt', jsonb_build_object('divisao_id', :'dvn_pdv'));
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-onl', null, :'cc_mkt', jsonb_build_object('divisao_id', :'dvn_onl'));
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-centro', null, :'cc_mkt', '{}');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-depois', null, :'cc_mkt',
  jsonb_build_object('antes', jsonb_build_object('divisao_id', :'dvn_onl'), 'depois', jsonb_build_object('divisao_id', :'dvn_pdv')));
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-antes', null, :'cc_mkt',
  jsonb_build_object('antes', jsonb_build_object('divisao_id', :'dvn_pdv'), 'depois', jsonb_build_object('divisao_id', null)));
-- a exceção que tira a divisão da Obra não pode valer num evento do Marketing
insert into erp.excecoes_divisao (user_id, nucleo_economico_id, divisao_id, nivel) values (:'u_vm', :'ne_vm', :'dvn_obr', 'nenhum');
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-fora', null, :'cc_mkt', jsonb_build_object('divisao_id', :'dvn_obr'));
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'div-lixo', null, :'cc_mkt', jsonb_build_object('divisao_id', 'x'));
select pg_temp.ok(pg_temp.recebeu(:'u_pdv', 'div-pdv') and not pg_temp.recebeu(:'u_pdv', 'div-onl') and not pg_temp.recebeu(:'u_pdv', 'div-centro'),
  'aviso por divisão: quem só tem o PDV recebe o do PDV, não o do Online nem o do centro sem divisão');
select pg_temp.ok(pg_temp.recebeu(:'u_pdv', 'div-depois') and pg_temp.recebeu(:'u_pdv', 'div-antes'),
  'aviso por divisão: a faixa que entra ou sai do PDV avisa quem cuida do PDV');
select pg_temp.ok(not pg_temp.recebeu(:'u_pdv', 'div-fora') and not pg_temp.recebeu(:'u_pdv', 'div-lixo')
                  and pg_temp.recebeu(:'u_vm', 'div-fora') and pg_temp.recebeu(:'u_vm', 'div-lixo'),
  'aviso por divisão: divisão de outro centro ou inválida vale como sem divisão');
select pg_temp.ok(pg_temp.recebeu(:'u_vm', 'div-centro') and pg_temp.recebeu(:'u_vm', 'div-pdv') and pg_temp.recebeu(:'u_vm', 'div-onl'),
  'aviso por divisão: quem tem o Marketing inteiro recebe o de todas as divisões');
-- crítico com a regra sem e-mail: o e-mail vai mesmo assim
insert into erp.regras_notificacao (tipo, destino, user_id, email) values ('conta_bancaria_alterada', 'pessoa', :'analista2', false);
select erp.registrar_evento('conta_bancaria_alterada', 'teste', 'critico-sem-email', null, null, '{}');
select pg_temp.ok((select array_agg(v.canal) from erp.envios_notificacao v join erp.notificacoes n on n.id = v.notificacao_id
                    join erp.eventos e on e.id = n.evento_id where e.registro = 'critico-sem-email' and n.user_id = :'analista2') = '{email}',
  'S-099: aviso crítico sai no e-mail mesmo com a regra sem e-mail');
-- desligado o e-mail quando o tipo não era crítico: virando crítico, o e-mail volta
update erp.tipos_evento set critico = false where codigo = 'natureza_sistema_alterada';
insert into erp.preferencias_notificacao (user_id, tipo, canal) values (:'u_vm', 'natureza_sistema_alterada', 'email');
update erp.tipos_evento set critico = true where codigo = 'natureza_sistema_alterada';
select erp.registrar_evento('natureza_sistema_alterada', 'teste', 'virou-critico', null, null, '{}');
select pg_temp.ok((select array_agg(v.canal) from erp.envios_notificacao v join erp.notificacoes n on n.id = v.notificacao_id
                    join erp.eventos e on e.id = n.evento_id where e.registro = 'virou-critico' and n.user_id = :'u_vm') = '{email}',
  'S-099: a preferência antiga de e-mail não desliga o tipo que virou crítico');
select pg_temp.erro_igual(format($$insert into erp.regras_notificacao (tipo, destino, user_id) values ('natureza_sistema_alterada', 'pessoa', %L)$$, :'u_suc'),
  'Usuário só de sucessão não recebe acesso no ERP', 'S-099: o painel não aponta para quem é só da sucessão');
insert into erp.grupo_sucessao values (:'diretor2');
insert into erp.delegados_acesso values (:'diretor2');
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'aprovadores_alterados' and tabela = 'grupo_sucessao')
                  and exists (select 1 from erp.eventos where tipo = 'aprovadores_alterados' and tabela = 'delegados_acesso'),
  'S-099: mudar o grupo de sucessão e os delegados de acesso vira evento crítico');
-- a guarda do sino
select n.id as n_ana from erp.notificacoes n join erp.eventos e on e.id = n.evento_id where e.registro = 'vm-obra' and n.user_id = :'analista2' \gset
select pg_temp.erro_igual(format($$update erp.notificacoes set titulo = 'x' where id = %s$$, :n_ana), 'Da notificação só muda a leitura',
  'S-099: da notificação só muda a leitura, nem pelo sistema');
select pg_temp.erro_igual(format($$delete from erp.notificacoes where id = %s$$, :n_ana), 'Notificação não se apaga', 'S-099: notificação não se apaga');
select pg_temp.volta();

-- o que é de cada um
select pg_temp.como(:'analista2');
insert into erp.preferencias_notificacao (user_id, tipo, canal) values (:'analista2', 'natureza_sistema_alterada', 'whatsapp');
select pg_temp.como(:'diretor2');
select pg_temp.ok(not exists (select 1 from erp.preferencias_notificacao where user_id = :'analista2'), 'S-099: ninguém lê a preferência de outro');
delete from erp.preferencias_notificacao where user_id = :'analista2';
delete from erp.preferencias_notificacao;   -- sem where: a leitura não entra, só a política de apagar
select erp.marcar_notificacoes_lidas(array[:n_ana]::bigint[]) as lidas_outro \gset
select pg_temp.ok(:lidas_outro = 0, 'S-099: ninguém marca como lida a notificação de outro');
select pg_temp.ok(not exists (select 1 from erp.regras_notificacao), 'S-099: o painel não se lê fora do administrador e do master');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.preferencias_notificacao where user_id = :'analista2')
                  and (select lida_em is null from erp.notificacoes where id = :n_ana),
  'S-099: a preferência e o sino do outro ficam como estavam');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select erp.registrar_envio_notificacao(%s, 'email')$$, :n_ana), 'Só o servidor registra o envio da notificação',
  'S-099: o registro do envio confere que é o servidor');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# naturezas liberadas por divisão (e no centro sem divisão)'
begin;
alter table erp.divisoes disable trigger t_teste_libera;
alter table erp.naturezas disable trigger t_teste_libera;
\set dv_inf '87000000-0000-0000-0000-0000000000c1'
\set tit_nl '88000000-0000-0000-0000-0000000000c2'
\set dv_inf2 '87000000-0000-0000-0000-0000000000c3'
\set doc_nl '70000000-0000-0000-0000-0000000000c4'
\set cmp_nl '60000000-0000-0000-0000-0000000000c5'
\set tit_sd '88000000-0000-0000-0000-0000000000c6'
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('centro_custo_id', %L, 'nome', 'Sem naturezas'), 'x')$$, :'cc_mkt'),
  'Diga as naturezas liberadas para lançamento no nível novo (marcadas, por modelo ou copiadas de uma irmã)', 'naturezas: a divisão nova nasce dizendo as naturezas liberadas');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('centro_custo_id', %L, 'nome', 'Vazia', 'naturezas', '[]'::jsonb), 'x')$$, :'cc_mkt'),
  'Diga as naturezas liberadas para lançamento no nível novo (marcadas, por modelo ou copiadas de uma irmã)', 'naturezas: lista vazia não cria divisão');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'dv_inf', 'centro_custo_id', :'cc_mkt', 'nome', 'Influencer',
  'naturezas', jsonb_build_array(pg_temp.nat('05.01.04'))), 'Influencer');
select pg_temp.ok((select array_agg(natureza_id) from erp.naturezas_liberadas where divisao_id = :'dv_inf') = array[pg_temp.nat('05.01.04')]
                  and (select centro_custo_id from erp.naturezas_liberadas where divisao_id = :'dv_inf') = :'cc_mkt',
  'naturezas: a divisão criada pelo pedido já vem com as naturezas escolhidas, e só elas');
select pg_temp.ok(not exists (select 1 from erp.naturezas_liberadas where centro_custo_id = :'cc_mkt' and divisao_id is null),
  'naturezas: com a primeira divisão, o centro deixa de ter lista própria (vale a soma das divisões)');
-- o que já estava lançado no centro sem divisão segue pela soma: uma divisão com tudo cobre
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', '87000000-0000-0000-0000-0000000000cf', 'centro_custo_id', :'cc_mkt',
  'nome', 'Geral', 'naturezas', pg_temp.folhas()), 'Geral');
-- quem lança só usa natureza liberada na divisão
select pg_temp.como(:'analista');
insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
values (:'spe', 'manual', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04'), '2026-10-01', '2026-10-10', 70);
select pg_temp.ok(exists (select 1 from erp.previsoes where divisao_id = :'dv_inf'), 'naturezas: lança na natureza liberada da divisão');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, '2026-10-01', '2026-10-10', 70)$$, :'spe', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.01')),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Influencer"', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'naturezas: natureza não liberada na divisão é recusada');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  (:'tit_nl', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-10-02', '2026-10-01', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'tit_nl', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04'), 100);
select pg_temp.falha(format($$update erp.titulo_rateios set natureza_id = %L where titulo_id = %L$$, pg_temp.nat('04.01'), :'tit_nl'),
  'naturezas: não troca a linha para natureza não liberada');
-- a trava vale também no contrato e na nota
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, numero, descricao, inicio, valor_total)
values (:'cmp_nl', :'spe', 'contrato', '10000000-0000-0000-0000-000000000005', 'CT-NL', 'Influência', '2026-10-01', 1000);
select pg_temp.erro_igual(format($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  values (%L, %L, %L, %L, %L, 100)$$, :'cmp_nl', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.02')),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Influencer"', (select nome from erp.naturezas where id = pg_temp.nat('04.02'))),
  'naturezas: o rateio do contrato só usa natureza liberada');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values (:'doc_nl', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', 'NL-1', '2026-10-02', '2026-10-01', 30);
select pg_temp.erro_igual(format($$insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  values (%L, %L, %L, %L, %L, 100)$$, :'doc_nl', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.02')),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Influencer"', (select nome from erp.naturezas where id = pg_temp.nat('04.02'))),
  'naturezas: o rateio da nota só usa natureza liberada');
-- a nota em rascunho, na natureza ainda liberada (o lançar copia depois que ela for desligada)
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'doc_nl', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04'), 100);
-- quem liga e desliga: master, administrador, AF, AO e AD, na hora
select pg_temp.como(:'analista2');
select pg_temp.falha(format($$insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (%L, %L, %L)$$,
  :'cc_mkt', :'dv_inf', pg_temp.nat('04.01')), 'naturezas: quem não é master, administrador nem financeiro não liga natureza');
select pg_temp.ok((select count(*) from erp.naturezas_liberadas where divisao_id = :'dv_inf') = 1, 'naturezas: todo membro lê as naturezas liberadas');
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$delete from erp.naturezas_liberadas where divisao_id = %L$$, :'dv_inf'), 'naturezas: leitura não desliga natureza');
select pg_temp.como(null);
alter table erp.naturezas_liberadas disable trigger t_natureza_liberada_cfg;
select pg_temp.como(:'analista2');
select pg_temp.falha(format($$insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (%L, %L, %L)$$,
  :'cc_mkt', :'dv_inf', pg_temp.nat('04.01')), 'naturezas: a regra de acesso da tabela, sozinha, já recusa quem não pode');
select pg_temp.como(null);
alter table erp.naturezas_liberadas enable trigger t_natureza_liberada_cfg;
select pg_temp.como(:'analista2');
select pg_temp.ok(pg_temp.erro_como_dono(format($$insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (%L, %L, %L)$$,
  :'cc_mkt', :'dv_inf', pg_temp.nat('04.01'))) = 'Só o master, o administrador e AF, AO ou AD ligam e desligam naturezas',
  'naturezas: o gatilho também barra quem não pode, por baixo da API');
select pg_temp.como(:'ti');
insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (:'cc_mkt', :'dv_inf', pg_temp.nat('04.01'));
select pg_temp.como(null);
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'naturezas_liberadas' and acao = 'insert' and registro = :'cc_mkt'
                          and depois->>'divisao_id' = :'dv_inf' and depois->>'natureza_id' = pg_temp.nat('04.01')::text),
  'naturezas: ligar fica na auditoria, com o centro, a divisão e a natureza');
select pg_temp.como(:'analista');
update erp.titulo_rateios set natureza_id = pg_temp.nat('04.01') where titulo_id = :'tit_nl';
select pg_temp.ok((select natureza_id from erp.titulo_rateios where titulo_id = :'tit_nl') = pg_temp.nat('04.01'),
  'naturezas: ligada pelo administrador, já se lança nela');
update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.04') where titulo_id = :'tit_nl';
select pg_temp.falha(format($$update erp.naturezas_liberadas set natureza_id = %L where divisao_id = %L and natureza_id = %L$$,
  pg_temp.nat('04.02'), :'dv_inf', pg_temp.nat('04.01')), 'naturezas: linha liberada não se altera');
-- desligar (o analista está na AF): o que já foi lançado segue; só não se lança de novo
delete from erp.naturezas_liberadas where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('05.01.04');
select pg_temp.ok(not exists (select 1 from erp.naturezas_liberadas where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('05.01.04')),
  'naturezas: AF desliga na hora');
select pg_temp.ok(array(select erp.titulos_abertos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04'))) = array[:'tit_nl'::uuid]
                  and not exists (select erp.titulos_abertos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('04.01'))),
  'naturezas: quem desliga vê os títulos em aberto que ficaram na natureza');
-- o título que o sistema cria da nota segue a nota, mesmo com a natureza já desligada
select erp.lancar_documento(:'doc_nl', array['2026-10-20']::date[]) as tit_doc_nl \gset
select pg_temp.ok((select natureza_id from erp.titulo_rateios where titulo_id = :'tit_doc_nl') = pg_temp.nat('05.01.04'),
  'naturezas: a cópia do sistema (nota para título) segue a origem com a natureza desligada');
select pg_temp.ok((select array_agg(x order by x) from erp.titulos_abertos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04')) x)
                    = (select array_agg(x order by x) from unnest(array[:'tit_nl'::uuid, :'tit_doc_nl'::uuid]) x)
                  and not exists (select erp.titulos_abertos_na_natureza(:'cc_mkt', null, pg_temp.nat('05.01.04'))),
  'naturezas: a lista dos em aberto filtra pela divisão');
select pg_temp.sis(); select set_config('role', 'erp_situacao', true);
update erp.titulos set situacao = 'cancelado', cancelamento = 'recusa' where id = :'tit_doc_nl';
select set_config('role', 'none', true); select pg_temp.volta();
select pg_temp.ok(array(select erp.titulos_abertos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04'))) = array[:'tit_nl'::uuid],
  'naturezas: título cancelado sai da lista dos em aberto');
-- divisão criada com várias naturezas: entram todas; mudar a linha de divisão confere a lista da nova
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'dv_inf2', 'centro_custo_id', :'cc_mkt', 'nome', 'Influencer 2',
  'naturezas', jsonb_build_array(pg_temp.nat('04.01'), pg_temp.nat('04.02'), pg_temp.nat('04.01'))), 'Influencer 2');
select pg_temp.ok((select array_agg(natureza_id order by natureza_id) from erp.naturezas_liberadas where divisao_id = :'dv_inf2')
                    = (select array_agg(x order by x) from unnest(array[pg_temp.nat('04.01'), pg_temp.nat('04.02')]) x),
  'naturezas: a divisão criada com várias naturezas recebe todas, sem repetir');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$update erp.titulo_rateios set divisao_id = %L where titulo_id = %L$$, :'dv_inf2', :'tit_nl'),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Influencer 2"', (select nome from erp.naturezas where id = pg_temp.nat('05.01.04'))),
  'naturezas: mover a linha para divisão sem a natureza é recusado');
-- a reclassificação só apaga linha liberada (quando a natureza esvaziada se apaga), nunca liga
select pg_temp.como(null);
select set_config('role', 'erp_reclassificacao', true);
select pg_temp.falha(format($$insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (%L, %L, %L)$$,
  :'cc_mkt', :'dv_inf', pg_temp.nat('04.02')), 'naturezas: a reclassificação não liga natureza');
select set_config('role', 'none', true);
select pg_temp.como(:'analista');
update erp.titulo_rateios set centro_custo_id = :'cc_mkt', divisao_id = :'dv_inf', percentual = 100 where titulo_id = :'tit_nl';
update erp.titulos set valor = 20 where id = :'tit_nl';
select pg_temp.ok((select valor from erp.titulos where id = :'tit_nl') = 20
                  and exists (select 1 from erp.previsoes where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('05.01.04')),
  'naturezas: o que já foi lançado na natureza desligada segue e se edita');
select pg_temp.falha(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, '2026-10-01', '2026-10-10', 70)$$, :'spe', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('05.01.04')),
  'naturezas: na natureza desligada não se lança de novo');
-- modelos de naturezas: lista pronta para marcar de uma vez
select pg_temp.como(:'ti');
insert into erp.modelos_naturezas (id, nome) values ('8b000000-0000-0000-0000-0000000000c7', 'Marketing digital');
insert into erp.modelo_naturezas (modelo_id, natureza_id) values
  ('8b000000-0000-0000-0000-0000000000c7', pg_temp.nat('05.01.04')), ('8b000000-0000-0000-0000-0000000000c7', pg_temp.nat('04.02'));
update erp.modelos_naturezas set nome = 'Marketing online' where id = '8b000000-0000-0000-0000-0000000000c7';
select pg_temp.ok((select count(*) from erp.modelo_naturezas where modelo_id = '8b000000-0000-0000-0000-0000000000c7') = 2
                  and exists (select 1 from erp.auditoria where tabela = 'modelo_naturezas' and registro = '8b000000-0000-0000-0000-0000000000c7'),
  'naturezas: o administrador salva modelo de naturezas, com auditoria, e o renomeia');
select pg_temp.falha($$update erp.modelo_naturezas set natureza_id = natureza_id where modelo_id = '8b000000-0000-0000-0000-0000000000c7'$$,
  'naturezas: a linha do modelo não se altera: tire e ponha');
select pg_temp.como(:'analista');
insert into erp.modelo_naturezas (modelo_id, natureza_id) values ('8b000000-0000-0000-0000-0000000000c7', pg_temp.nat('04.01'));
select pg_temp.ok((select count(*) from erp.modelo_naturezas where modelo_id = '8b000000-0000-0000-0000-0000000000c7') = 3,
  'naturezas: AF também mexe no modelo');
select pg_temp.como(:'analista2');
select pg_temp.ok((select count(*) from erp.modelo_naturezas where modelo_id = '8b000000-0000-0000-0000-0000000000c7') = 3,
  'naturezas: todo membro lê os modelos');
select pg_temp.falha($$insert into erp.modelos_naturezas (nome) values ('Meu modelo')$$, 'naturezas: quem não liga natureza não cria modelo');
select pg_temp.falha($$delete from erp.modelo_naturezas where modelo_id = '8b000000-0000-0000-0000-0000000000c7'$$, 'naturezas: quem não liga natureza não mexe no modelo');
select pg_temp.como(null);
alter table erp.modelo_naturezas disable trigger t_natureza_liberada_cfg;
select pg_temp.como(:'analista2');
select pg_temp.falha(format($$insert into erp.modelo_naturezas (modelo_id, natureza_id) values ('8b000000-0000-0000-0000-0000000000c7', %L)$$, pg_temp.nat('04.03')),
  'naturezas: a regra de acesso do modelo, sozinha, já recusa quem não pode');
select pg_temp.como(null);
alter table erp.modelo_naturezas enable trigger t_natureza_liberada_cfg;
alter table erp.modelos_naturezas disable trigger t_natureza_liberada_cfg;
select pg_temp.como(:'analista2');
select pg_temp.falha($$insert into erp.modelos_naturezas (nome) values ('Outro modelo')$$,
  'naturezas: a regra de acesso dos modelos, sozinha, já recusa quem não pode');
select pg_temp.como(null);
alter table erp.modelos_naturezas enable trigger t_natureza_liberada_cfg;
-- natureza nova nasce desligada
select pg_temp.como(:'ti');
insert into erp.naturezas (codigo, mae_id, nome) values ('05.01.97', pg_temp.nat('05.01'), 'Natureza nova (teste)');
select pg_temp.ok(not exists (select 1 from erp.naturezas_liberadas where natureza_id = pg_temp.nat('05.01.97')),
  'naturezas: natureza nova nasce desligada em todos os centros e divisões');
-- centro sem divisão: vale a lista do próprio centro
select id as cc_sd from erp.centros_custo c where not exists (select 1 from erp.divisoes d where d.centro_custo_id = c.id)
  and nome not in ('Obra', 'Marketing') order by nome limit 1 \gset
select pg_temp.como(:'diretor');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values (:'ne_vm', :'cc_sd', true)
  on conflict (nucleo_economico_id, centro_custo_id) do update set ligado = true;
delete from erp.naturezas_liberadas where centro_custo_id = :'cc_sd' and natureza_id = pg_temp.nat('04.02');
select pg_temp.como(:'analista');
insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values (:'spe', 'manual', :'ne_vm', :'cc_sd', pg_temp.nat('04.01'), '2026-10-01', '2026-10-10', 5);
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, '2026-10-01', '2026-10-10', 5)$$, :'spe', :'ne_vm', :'cc_sd', pg_temp.nat('04.02')),
  format('A natureza "%s" não está liberada para lançamento em "%s"', (select nome from erp.naturezas where id = pg_temp.nat('04.02')),
         (select nome from erp.centros_custo where id = :'cc_sd')),
  'naturezas: no centro sem divisão vale a lista do próprio centro');
-- mover a linha para outro centro sem a natureza é recusado
select id as cc_sd2 from erp.centros_custo c where not exists (select 1 from erp.divisoes d where d.centro_custo_id = c.id)
  and nome not in ('Obra', 'Marketing') and id <> :'cc_sd' order by nome limit 1 \gset
select pg_temp.como(:'diretor');
insert into erp.nucleo_centros (nucleo_economico_id, centro_custo_id, ligado) values (:'ne_vm', :'cc_sd2', true)
  on conflict (nucleo_economico_id, centro_custo_id) do update set ligado = true;
delete from erp.naturezas_liberadas where centro_custo_id = :'cc_sd2' and natureza_id = pg_temp.nat('04.01');
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  (:'tit_sd', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-10-02', '2026-10-01', 10);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values (:'tit_sd', :'ne_vm', :'cc_sd', pg_temp.nat('04.01'), 100);
select pg_temp.erro_igual(format($$update erp.titulo_rateios set centro_custo_id = %L where titulo_id = %L$$, :'cc_sd2', :'tit_sd'),
  format('A natureza "%s" não está liberada para lançamento em "%s"', (select nome from erp.naturezas where id = pg_temp.nat('04.01')),
         (select nome from erp.centros_custo where id = :'cc_sd2')),
  'naturezas: mover a linha para centro sem a natureza é recusado');
-- a lista do centro não vale para as divisões dele
select pg_temp.como(:'diretor');
delete from erp.naturezas_liberadas where centro_custo_id = :'cc_mkt' and divisao_id is null and natureza_id = pg_temp.nat('04.01');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, '2026-10-01', '2026-10-10', 70)$$, :'spe', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.02')),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Influencer"', (select nome from erp.naturezas where id = pg_temp.nat('04.02'))),
  'naturezas: com divisão, a natureza liberada no centro não basta');
insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
values (:'spe', 'manual', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.01'), '2026-10-01', '2026-10-10', 9);
select pg_temp.ok(exists (select 1 from erp.previsoes where divisao_id = :'dv_inf' and valor = 9),
  'naturezas: com divisão, vale a lista da divisão mesmo com a natureza desligada no centro');
-- reclassificação para natureza desligada no centro e divisão das linhas: recusada no pedido e
-- de novo ao aprovar (Moises, 15/11/2026)
select pg_temp.erro_igual(format($$select erp.pedir_reclassificacao(%L, %L, 'x', jsonb_build_object('lancamentos',
    (select jsonb_agg(id) from erp.lancamentos where divisao_id = %L and natureza_id = %L)))$$,
    pg_temp.nat('04.01'), pg_temp.nat('04.02'), :'dv_inf', pg_temp.nat('04.01')),
  'A natureza de destino não está liberada em "Marketing > Influencer": ligue-a lá ou filtre o pedido',
  'naturezas: não se reclassifica para natureza desligada na divisão das linhas');
select pg_temp.como(:'ti');
insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (:'cc_mkt', :'dv_inf', pg_temp.nat('04.02'));
select pg_temp.como(:'analista');
select erp.pedir_reclassificacao(pg_temp.nat('04.01'), pg_temp.nat('04.02'), 'teste', jsonb_build_object('lancamentos',
    (select jsonb_agg(id) from erp.lancamentos where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('04.01')))) as r_nl \gset
select pg_temp.como(:'ti');
delete from erp.naturezas_liberadas where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('04.02');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.decidir_reclassificacao(%L, true)$$, :'r_nl'),
  'A natureza de destino não está liberada em "Marketing > Influencer": ligue-a lá ou filtre o pedido',
  'naturezas: desligada depois do pedido, a reclassificação não se aplica');
-- natureza presa: com contrato ou pedido ativo nela, no centro e na divisão, não se desliga
select pg_temp.como(:'analista');
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'cmp_nl', :'ne_vm', :'cc_mkt', :'dv_inf', pg_temp.nat('04.01'), 100);
select pg_temp.ok(array(select erp.compromissos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('04.01'))) = array[:'cmp_nl'::uuid],
  'naturezas: quem vai desligar vê os contratos e pedidos ativos que a prendem');
select pg_temp.como(:'ti');
select pg_temp.ok(not exists (select 1 from erp.compromissos where id = :'cmp_nl'), 'naturezas: (o administrador não vê o contrato)');
select pg_temp.erro_igual(format($$delete from erp.naturezas_liberadas where divisao_id = %L and natureza_id = %L$$, :'dv_inf', pg_temp.nat('04.01')),
  format('A natureza "%s" tem contrato ou pedido ativo neste centro e divisão: reclassifique antes de desligar', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'naturezas: não se desliga natureza com contrato ativo na divisão, mesmo que quem desliga não veja o contrato');
select pg_temp.ok(not exists (select erp.compromissos_na_natureza(:'cc_mkt', null, pg_temp.nat('04.01')))
                  and not erp.natureza_presa(:'cc_mkt', null, pg_temp.nat('04.01')),
  'naturezas: o contrato prende só no centro e na divisão dele');
select pg_temp.sis(); update erp.compromissos set situacao = 'encerrado' where id = :'cmp_nl'; select pg_temp.volta();
delete from erp.naturezas_liberadas where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('04.01');
select pg_temp.ok(not exists (select 1 from erp.naturezas_liberadas where divisao_id = :'dv_inf' and natureza_id = pg_temp.nat('04.01')),
  'naturezas: contrato encerrado não prende a natureza');
select pg_temp.como(:'analista');
select pg_temp.ok(not exists (select erp.compromissos_na_natureza(:'cc_mkt', :'dv_inf', pg_temp.nat('04.01'))),
  'naturezas: contrato encerrado sai da lista dos que prendem');
select pg_temp.ok(erp.natureza_ligada(null, null, pg_temp.nat('04.01')), 'naturezas: linha sem centro (movimentação) não depende da lista');
-- reclassificação da natureza inteira: confere também os rateios de contrato e de nota, que mudam junto
select pg_temp.como(:'ti');
insert into erp.naturezas (codigo, mae_id, nome) values
  ('05.01.96', pg_temp.nat('05.01'), 'Origem contrato (teste)'), ('05.01.95', pg_temp.nat('05.01'), 'Origem nota (teste)');
insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values
  (:'cc_mkt', :'dv_inf2', pg_temp.nat('05.01.96')), (:'cc_mkt', :'dv_inf2', pg_temp.nat('05.01.95'));
select pg_temp.sis(); update erp.compromissos set situacao = 'ativo' where id = :'cmp_nl'; select pg_temp.volta();
select pg_temp.como(:'analista');
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'cmp_nl', :'ne_vm', :'cc_mkt', :'dv_inf2', pg_temp.nat('05.01.96'), 100);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000000c8', :'spe', '10000000-0000-0000-0000-000000000005', 'nfse', 'NL-2', '2026-10-02', '2026-10-01', 30);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values ('70000000-0000-0000-0000-0000000000c8', :'ne_vm', :'cc_mkt', :'dv_inf2', pg_temp.nat('05.01.95'), 100);
select pg_temp.erro_igual(format($$select erp.pedir_reclassificacao(%L, %L, 'x', '{}', true)$$, pg_temp.nat('05.01.96'), pg_temp.nat('05.01.04')),
  'A natureza de destino não está liberada em "Marketing > Influencer 2": ligue-a lá ou filtre o pedido',
  'naturezas: a reclassificação da natureza inteira confere os rateios de contrato');
select pg_temp.erro_igual(format($$select erp.pedir_reclassificacao(%L, %L, 'x', '{}', true)$$, pg_temp.nat('05.01.95'), pg_temp.nat('05.01.04')),
  'A natureza de destino não está liberada em "Marketing > Influencer 2": ligue-a lá ou filtre o pedido',
  'naturezas: a reclassificação da natureza inteira confere os rateios de nota');
select pg_temp.como(null);
rollback;

\echo '# divisão nível 1 a 4: naturezas no último nível, soma nos de cima, cópia de irmã, etiquetas (Moises, 15/11/2026)'
begin;
alter table erp.divisoes disable trigger t_teste_libera;
alter table erp.naturezas disable trigger t_teste_libera;
\set d_mid '87000000-0000-0000-0000-0000000000d1'
\set d_onl '87000000-0000-0000-0000-0000000000d2'
\set d_goo '87000000-0000-0000-0000-0000000000d3'
\set d_met '87000000-0000-0000-0000-0000000000d4'
\set d_gse '87000000-0000-0000-0000-0000000000d5'
\set d_eve '87000000-0000-0000-0000-0000000000d6'
\set d_pdv '87000000-0000-0000-0000-0000000000d7'
\set d_x5  '87000000-0000-0000-0000-0000000000d8'
\set d_tik '87000000-0000-0000-0000-0000000000dd'
\set t_niv '88000000-0000-0000-0000-0000000000d9'
\set c_niv '60000000-0000-0000-0000-0000000000da'
\set t_pdv '88000000-0000-0000-0000-0000000000db'
\set c_pdv '60000000-0000-0000-0000-0000000000de'
\set et_bf '8c000000-0000-0000-0000-0000000000dc'
\set c_met '60000000-0000-0000-0000-0000000000df'
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_mid', 'centro_custo_id', :'cc_mkt', 'nome', 'Mídia',
  'naturezas', jsonb_build_array(pg_temp.nat('05.01.04'), pg_temp.nat('04.01'))), 'Mídia');
-- o primeiro nível abaixo copia a lista de quem está em cima, que passa a ser a soma das de baixo
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_onl', 'mae_id', :'d_mid', 'nome', 'Online',
  'copiar_de', :'d_mid'), 'Online');
select pg_temp.ok((select (centro_custo_id, mae_id, raiz_id, nivel) = (:'cc_mkt'::uuid, :'d_mid'::uuid, :'d_mid'::uuid, 2) from erp.divisoes where id = :'d_onl'),
  'níveis: o nível 2 nasce no centro, na raiz e no nível do de cima');
select pg_temp.ok((select count(*) from erp.naturezas_liberadas where divisao_id = :'d_onl') = 2
                  and not exists (select 1 from erp.naturezas_liberadas where divisao_id = :'d_mid'),
  'níveis: o primeiro nível abaixo leva a lista, e o de cima fica sem lista própria');
select pg_temp.ok(erp.natureza_ligada(:'cc_mkt', :'d_mid', pg_temp.nat('04.01')) and not erp.natureza_ligada(:'cc_mkt', :'d_mid', pg_temp.nat('04.02')),
  'níveis: as naturezas do nível de cima são a soma das de baixo');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_goo', 'mae_id', :'d_onl', 'nome', 'Google', 'copiar_de', :'d_onl'), 'Google');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_met', 'mae_id', :'d_onl', 'nome', 'Meta', 'copiar_de', :'d_goo'), 'Meta');
select pg_temp.ok((select array_agg(natureza_id order by natureza_id) from erp.naturezas_liberadas where divisao_id = :'d_met')
                    = (select array_agg(natureza_id order by natureza_id) from erp.naturezas_liberadas where divisao_id = :'d_goo'),
  'níveis: copia a lista de uma irmã');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_tik', 'mae_id', :'d_onl', 'nome', 'TikTok',
  'naturezas', jsonb_build_array(pg_temp.nat('04.01'))), 'TikTok');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_gse', 'mae_id', :'d_goo', 'nome', 'Google Search', 'copiar_de', :'d_goo'), 'Google Search');
select pg_temp.ok((select nivel from erp.divisoes where id = :'d_gse') = 4, 'níveis: quatro níveis abaixo do centro');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', %L, 'mae_id', %L, 'nome', 'Quinto',
  'naturezas', jsonb_build_array(%L)), 'x')$$, :'d_x5', :'d_gse', pg_temp.nat('04.01')),
  'A divisão vai até 4 níveis abaixo do centro de custo', 'níveis: não há quinto nível');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Prima', 'copiar_de', %L), 'x')$$,
  :'d_onl', :'d_gse'),
  'Copie as naturezas de uma irmã ativa do nível novo (ou, no primeiro nível abaixo, do nível de cima)', 'níveis: só copia de irmã');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Filha', 'copiar_de', %L), 'x')$$,
  :'d_onl', :'d_onl'),
  'Copie as naturezas de uma irmã ativa do nível novo (ou, no primeiro nível abaixo, do nível de cima)', 'níveis: o nível de cima com níveis abaixo não tem lista para copiar');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Dois',
  'copiar_de', %L, 'naturezas', jsonb_build_array(%L)), 'x')$$, :'d_onl', :'d_goo', pg_temp.nat('04.01')),
  'Diga a lista de naturezas ou de quem copiar, não os dois', 'níveis: lista e cópia juntas são recusadas');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Sem'), 'x')$$, :'d_onl'),
  'Diga as naturezas liberadas para lançamento no nível novo (marcadas, por modelo ou copiadas de uma irmã)',
  'níveis: todo nível novo nasce dizendo as naturezas');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', %L, 'nome', 'Online', 'ativa', false), 'x')$$, :'d_onl'),
  'Desative antes os subníveis desta divisão', 'níveis: não se desativa nível com níveis abaixo ativos');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$insert into erp.naturezas_liberadas (centro_custo_id, divisao_id, natureza_id) values (%L, %L, %L)$$,
  :'cc_mkt', :'d_onl', pg_temp.nat('04.02')),
  'Este nível tem níveis abaixo: as naturezas dele são a soma das de baixo; ligue-a no último nível', 'níveis: nível com níveis abaixo não tem lista própria');
select pg_temp.erro_igual(format($$insert into erp.naturezas_liberadas (centro_custo_id, natureza_id) values (%L, %L)$$, :'cc_mkt', pg_temp.nat('04.02')),
  'Este nível tem níveis abaixo: as naturezas dele são a soma das de baixo; ligue-a no último nível', 'níveis: o centro com divisões também não');
delete from erp.naturezas_liberadas where divisao_id = :'d_met' and natureza_id = pg_temp.nat('04.01');
-- lançamento: divisão de nível 1 na linha, o último nível no subnível
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, '2026-10-01', '2026-10-10', 10)$$, :'spe', :'ne_vm', :'cc_mkt', :'d_mid', pg_temp.nat('05.01.04')),
  'A divisão "Mídia" tem subníveis: diga o último nível da linha', 'níveis: divisão com níveis abaixo pede o último nível');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, '2026-10-01', '2026-10-10', 10)$$, :'spe', :'ne_vm', :'cc_mkt', :'d_onl', pg_temp.nat('05.01.04')),
  'A linha leva a divisão de primeiro nível; o subnível vai no campo do subnível', 'níveis: o nível 2 não vai no lugar da divisão');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, %L, '2026-10-01', '2026-10-10', 10)$$, :'spe', :'ne_vm', :'cc_mkt', :'d_mid', :'d_goo', pg_temp.nat('05.01.04')),
  'Lance no último nível: "Google" tem subníveis', 'níveis: só se lança no último nível');
insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia, data_prevista, valor)
values (:'spe', 'manual', :'ne_vm', :'cc_mkt', :'d_mid', :'d_met', pg_temp.nat('05.01.04'), '2026-10-01', '2026-10-10', 11),
       (:'spe', 'manual', :'ne_vm', :'cc_mkt', :'d_mid', :'d_gse', pg_temp.nat('04.01'), '2026-10-01', '2026-10-10', 13);
select pg_temp.ok((select count(*) from erp.lancamentos where subdivisao_id in (:'d_met', :'d_gse') and divisao_id = :'d_mid') = 2,
  'níveis: lança no último nível, e o livro guarda a divisão e o subnível');
select pg_temp.ok((select (divisao, subdivisao) = ('Mídia', 'Online > Google > Google Search') from erp.v_lancamentos_bi b join erp.lancamentos l on l.id = b.id
                    where l.subdivisao_id = :'d_gse'),
  'níveis: o BI mostra a divisão e o caminho dos níveis abaixo');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, %L, '2026-10-01', '2026-10-10', 10)$$, :'spe', :'ne_vm', :'cc_mkt', :'d_mid', :'d_met', pg_temp.nat('04.01')),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Meta"', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'níveis: a lista do último nível vale só para ele');
-- rateio entre níveis do mesmo título
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  (:'t_niv', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-10-02', '2026-10-01', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
values (:'t_niv', :'ne_vm', :'cc_mkt', :'d_mid', :'d_gse', pg_temp.nat('04.01'), 60),
       (:'t_niv', :'ne_vm', :'cc_mkt', :'d_mid', :'d_met', pg_temp.nat('05.01.04'), 40);
select pg_temp.ok((select array_agg(subdivisao_id order by valor) from erp.ratear('titulo', :'t_niv', 100)) = array[:'d_met'::uuid, :'d_gse'::uuid],
  'níveis: o rateio divide o título entre níveis e leva o último nível adiante');
-- trocar só o último nível também passa pelas travas
select pg_temp.erro_igual(format($$update erp.titulo_rateios set subdivisao_id = %L where titulo_id = %L and subdivisao_id = %L$$, :'d_goo', :'t_niv', :'d_met'),
  'Lance no último nível: "Google" tem subníveis', 'níveis: trocar só o subnível confere o último nível');
select pg_temp.erro_igual(format($$update erp.titulo_rateios set subdivisao_id = %L where titulo_id = %L and subdivisao_id = %L$$, :'d_met', :'t_niv', :'d_gse'),
  format('A natureza "%s" não está liberada para lançamento em "Marketing > Meta"', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'níveis: trocar só o subnível confere a natureza no novo nível');
select pg_temp.ok(not exists (select erp.titulos_abertos_na_natureza(:'cc_mkt', :'d_met', pg_temp.nat('04.01')))
                  and array(select erp.titulos_abertos_na_natureza(:'cc_mkt', :'d_gse', pg_temp.nat('04.01'))) = array[:'t_niv'::uuid],
  'níveis: os títulos em aberto da natureza são os do próprio nível, não os da irmã');
select pg_temp.erro_igual(format($$select erp.pedir_reclassificacao(%L, %L, 'x', jsonb_build_object('lancamentos',
    (select jsonb_agg(id) from erp.lancamentos where subdivisao_id = %L and natureza_id = %L)))$$,
    pg_temp.nat('05.01.04'), pg_temp.nat('04.01'), :'d_met', pg_temp.nat('05.01.04')),
  'A natureza de destino não está liberada em "Marketing > Meta": ligue-a lá ou filtre o pedido',
  'níveis: a reclassificação confere o destino no último nível da linha, não na soma');
-- natureza presa no último nível
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, numero, descricao, inicio, valor_total)
values (:'c_niv', :'spe', 'contrato', '10000000-0000-0000-0000-000000000005', 'CT-NIV', 'Mídia', '2026-10-01', 1000);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
values (:'c_niv', :'ne_vm', :'cc_mkt', :'d_mid', :'d_gse', pg_temp.nat('04.01'), 100);
-- um contrato da irmã (Meta) em natureza que não vale lá, gravado pelo sistema: não conta para o Google Search
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, numero, descricao, inicio, valor_total)
values (:'c_met', :'spe', 'pedido', '10000000-0000-0000-0000-000000000005', 'PC-MET', 'Meta', '2026-10-01', 500);
select pg_temp.sis();
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
values (:'c_met', :'ne_vm', :'cc_mkt', :'d_mid', :'d_met', pg_temp.nat('04.01'), 100);
select pg_temp.volta();
select pg_temp.ok(array(select erp.compromissos_na_natureza(:'cc_mkt', :'d_gse', pg_temp.nat('04.01'))) = array[:'c_niv'::uuid],
  'níveis: quem vai desligar vê o contrato do último nível');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$delete from erp.naturezas_liberadas where divisao_id = %L and natureza_id = %L$$, :'d_gse', pg_temp.nat('04.01')),
  format('A natureza "%s" tem contrato ou pedido ativo neste centro e divisão: reclassifique antes de desligar', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'níveis: não se desliga no último nível natureza com contrato ativo');
delete from erp.naturezas_liberadas where divisao_id = :'d_tik' and natureza_id = pg_temp.nat('04.01');
select pg_temp.ok(erp.natureza_ligada(:'cc_mkt', :'d_onl', pg_temp.nat('04.01')),
  'níveis: desligar numa irmã não tira da soma o que outra ainda tem');
-- acesso, alçada e carimbo ficam no nível 1
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$insert into erp.alcadas_pagamento (centro_custo_id, divisao_id, ate, fases) values (%L, %L, 1000, '{AF}')$$, :'cc_mkt', :'d_onl'),
  'Aqui vale a divisão de primeiro nível; o subnível só entra no lançamento', 'níveis: a alçada não desce abaixo do nível 1');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('excecoes_divisao', 'incluir', jsonb_build_object('user_id', %L, 'nucleo_economico_id', %L, 'divisao_id', %L, 'nivel', 'leitor'), 'x')$$,
  :'analista2', :'ne_vm', :'d_onl'),
  'Aqui vale a divisão de primeiro nível; o subnível só entra no lançamento', 'níveis: o acesso não desce abaixo do nível 1');
-- PDV: a linha que já estava na divisão fica e segue pela soma; a nova pede o último nível
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_eve', 'centro_custo_id', :'cc_mkt', 'nome', 'Eventos',
  'naturezas', jsonb_build_array(pg_temp.nat('05.01.04'), pg_temp.nat('04.01'))), 'Eventos');
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  (:'t_pdv', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-10-02', '2026-10-01', 50);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'t_pdv', :'ne_vm', :'cc_mkt', :'d_eve', pg_temp.nat('05.01.04'), 100);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, numero, descricao, inicio, valor_total)
values (:'c_pdv', :'spe', 'contrato', '10000000-0000-0000-0000-000000000005', 'CT-PDV', 'Eventos', '2026-10-01', 1000);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
values (:'c_pdv', :'ne_vm', :'cc_mkt', :'d_eve', pg_temp.nat('04.01'), 100);
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', %L, 'mae_id', %L, 'nome', 'Feira',
  'naturezas', jsonb_build_array(%L)), 'x')$$, :'d_pdv', :'d_eve', pg_temp.nat('05.01.04')),
  format('A natureza "%s" tem contrato ou pedido ativo neste centro e divisão: reclassifique antes de desligar', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'níveis: o primeiro nível abaixo precisa cobrir o contrato ativo que ficou no de cima');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'d_pdv', 'mae_id', :'d_eve', 'nome', 'Feira', 'copiar_de', :'d_eve'), 'Feira');
select pg_temp.como(:'analista');
update erp.titulo_rateios set natureza_id = pg_temp.nat('04.01') where titulo_id = :'t_pdv';
select pg_temp.ok((select (divisao_id, subdivisao_id, natureza_id) is not distinct from (:'d_eve'::uuid, null::uuid, pg_temp.nat('04.01')) from erp.titulo_rateios where titulo_id = :'t_pdv'),
  'níveis: a linha antiga fica na divisão que ganhou níveis abaixo e se ajusta pela soma');
select pg_temp.ok(array(select erp.compromissos_na_natureza(:'cc_mkt', :'d_pdv', pg_temp.nat('04.01'))) = array[:'c_pdv'::uuid],
  'níveis: quem vai desligar no nível de baixo vê o contrato antigo do de cima');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$delete from erp.naturezas_liberadas where divisao_id = %L and natureza_id = %L$$, :'d_pdv', pg_temp.nat('04.01')),
  format('A natureza "%s" tem contrato ou pedido ativo neste centro e divisão: reclassifique antes de desligar', (select nome from erp.naturezas where id = pg_temp.nat('04.01'))),
  'níveis: não se tira da soma a natureza do contrato antigo do nível de cima');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual)
  values (%L, %L, %L, %L, %L, 1)$$, :'t_niv', :'ne_vm', :'cc_mkt', :'d_eve', pg_temp.nat('04.01')),
  'A divisão "Eventos" tem subníveis: diga o último nível da linha', 'níveis: linha nova na divisão com níveis abaixo precisa do último nível');
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
  values (%L, %L, %L, %L, %L, %L, 1)$$, :'t_niv', :'ne_vm', :'cc_mkt', :'d_mid', :'d_pdv', pg_temp.nat('04.01')),
  'O subnível não fica dentro da divisão da linha', 'níveis: nível de outra divisão é recusado');
-- nível desativado
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', :'d_tik', 'nome', 'TikTok', 'ativa', false), 'TikTok saiu');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', %L, %L, %L, %L, %L, '2026-10-01', '2026-10-10', 10)$$, :'spe', :'ne_vm', :'cc_mkt', :'d_mid', :'d_tik', pg_temp.nat('04.01')),
  'O subnível está desativado', 'níveis: não se lança em nível desativado');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Neta', 'naturezas', jsonb_build_array(%L)), 'x')$$,
  :'d_tik', pg_temp.nat('04.01')),
  'O nível de cima está desativado', 'níveis: não se cria abaixo de nível desativado');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Kwai', 'copiar_de', %L), 'x')$$,
  :'d_onl', :'d_tik'),
  'Copie as naturezas de uma irmã ativa do nível novo (ou, no primeiro nível abaixo, do nível de cima)', 'níveis: não copia de irmã desativada');
select pg_temp.como(:'ti');
delete from erp.naturezas_liberadas where divisao_id = :'d_met';
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('mae_id', %L, 'nome', 'Kwai', 'copiar_de', %L), 'x')$$,
  :'d_onl', :'d_met'),
  'O nível de onde copiar não tem naturezas liberadas', 'níveis: não copia de quem não tem lista');
-- filho desativado não conta: o de cima volta a ser último nível, e a lista do desativado sai da soma
select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', :'d_gse', 'nome', 'Google Search', 'ativa', false), 'x');
select pg_temp.ok(erp.divisao_folha(:'d_goo') and not erp.natureza_ligada(:'cc_mkt', :'d_goo', pg_temp.nat('04.01')),
  'níveis: filho desativado não conta no último nível nem na soma');
select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', :'d_goo', 'nome', 'Google', 'ativa', false), 'x');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('divisoes', 'alterar', jsonb_build_object('id', %L, 'nome', 'Google Search', 'ativa', true), 'x')$$, :'d_gse'),
  'O nível de cima está desativado', 'níveis: não se reativa abaixo de nível desativado');
-- a árvore não muda de lugar (é o que impede ciclo)
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.divisoes set mae_id = %L where id = %L$$, :'d_met', :'d_gse'),
  'A divisão não muda de centro de custo, de nível de cima nem de data de criação', 'níveis: a mãe não muda');
select pg_temp.erro_igual(format($$update erp.divisoes set raiz_id = %L where id = %L$$, :'d_eve', :'d_gse'),
  'A divisão não muda de centro de custo, de nível de cima nem de data de criação', 'níveis: a raiz não muda');
select pg_temp.volta();
select pg_temp.como(:'analista');
-- etiquetas livres: só AF, AD e o master criam e mudam; quem lança usa as que existem
select pg_temp.erro_igual($$insert into erp.etiquetas (nome) values ('Natal')$$,
  'Só AF, AD e o master criam e mudam etiquetas; use uma das que existem', 'etiquetas: quem lança (na AO) não cria etiqueta');
select pg_temp.como(null);
alter table erp.etiquetas disable trigger t_etiqueta;
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.etiquetas (nome) values ('Natal')$$, 'etiquetas: a regra de acesso, sozinha, também recusa');
select pg_temp.como(null);
alter table erp.etiquetas enable trigger t_etiqueta;
select pg_temp.como(:'analista');
select pg_temp.ok(pg_temp.erro_como_dono($$insert into erp.etiquetas (nome) values ('Natal')$$)
                  = 'Só AF, AD e o master criam e mudam etiquetas; use uma das que existem',
  'etiquetas: o gatilho barra por baixo da API');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista2'); select pg_temp.volta();
select pg_temp.como(:'analista2');
insert into erp.etiquetas (id, nome) values (:'et_bf', 'Black Friday');
select pg_temp.ok(exists (select 1 from erp.etiquetas where id = :'et_bf'), 'etiquetas: AF cria etiqueta');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'gestor'); select pg_temp.volta();
select pg_temp.como(:'gestor');
insert into erp.etiquetas (nome) values ('Dia das Mães');
update erp.etiquetas set nome = 'Dia das Mães 2026' where nome = 'Dia das Mães';
select pg_temp.ok(exists (select 1 from erp.etiquetas where nome = 'Dia das Mães 2026'), 'etiquetas: AD cria e renomeia etiqueta');
select pg_temp.como(:'analista');
select pg_temp.falha(format($$update erp.etiquetas set nome = 'Black Week' where id = %L$$, :'et_bf'), 'etiquetas: quem lança não renomeia etiqueta');
select pg_temp.ok(pg_temp.erro_como_dono(format($$update erp.etiquetas set nome = 'Black Week' where id = %L$$, :'et_bf'))
                  = 'Só AF, AD e o master criam e mudam etiquetas; use uma das que existem',
  'etiquetas: o gatilho barra renomear por baixo da API');
select pg_temp.como(:'diretor');
select pg_temp.falha($$insert into erp.etiquetas (nome) values ('  black friday ')$$, 'etiquetas: o nome não se repete');
select pg_temp.como(:'analista');
insert into erp.titulo_etiquetas (titulo_id, etiqueta_id) values (:'t_niv', :'et_bf');
select pg_temp.ok(exists (select 1 from erp.titulo_etiquetas where titulo_id = :'t_niv'), 'etiquetas: quem lança põe etiqueta no título');
select pg_temp.erro_igual(format($$update erp.titulo_etiquetas set titulo_id = %L where titulo_id = %L$$, :'t_pdv', :'t_niv'),
  'Etiqueta do título não se altera: tire e ponha', 'etiquetas: a etiqueta do título não se altera');
-- quem não vê o título não vê nem põe etiqueta nele
select pg_temp.sis(); delete from erp.atribuicoes where user_id = :'analista2'; select pg_temp.volta();
select pg_temp.como(:'analista2');
select pg_temp.ok(not exists (select 1 from erp.titulos where id = :'t_niv') and not exists (select 1 from erp.titulo_etiquetas where titulo_id = :'t_niv')
                  and exists (select 1 from erp.etiquetas where id = :'et_bf'),
  'etiquetas: quem não vê o título não vê as etiquetas dele (a lista de etiquetas, todos veem)');
select pg_temp.falha(format($$insert into erp.titulo_etiquetas (titulo_id, etiqueta_id) values (%L, %L)$$, :'t_pdv', :'et_bf'),
  'etiquetas: quem não lança no título não põe etiqueta nele');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$delete from erp.etiquetas where id = %L$$, :'et_bf'), 'Etiqueta não se apaga; desative', 'etiquetas: não se apaga');
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$delete from erp.titulo_etiquetas where titulo_id = %L$$, :'t_niv'), 'etiquetas: leitura não tira etiqueta');
select pg_temp.falha($$insert into erp.etiquetas (nome) values ('Leitura')$$, 'etiquetas: leitura não cria etiqueta');
select pg_temp.como(:'diretor');
update erp.etiquetas set ativa = false where id = :'et_bf';
select pg_temp.ok(not (select ativa from erp.etiquetas where id = :'et_bf'), 'etiquetas: o master desativa');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.titulo_etiquetas (titulo_id, etiqueta_id) values (%L, %L)$$, :'t_pdv', :'et_bf'),
  'A etiqueta está desativada', 'etiquetas: desativada não entra em título novo');
select pg_temp.como(null);
rollback;

\echo '# camada de leitura bi (relatórios e painéis)'
begin;
select pg_temp.como(null);
-- calendário único
select pg_temp.ok((select min(data) = '2015-01-01' and max(data) = make_date(extract(year from bi.hoje())::int + 15, 12, 31)
                     and count(*) = max(data) - min(data) + 1 from bi.d_calendario),
  'bi: calendário de 2015 até 31/12 do 15º ano à frente, um dia por linha');
select pg_temp.ok(bi.estender_calendario() = 0, 'bi: rodar a rotina de novo não cria nada');
select bi.estender_calendario(16) as bi_novos \gset
select pg_temp.ok(:bi_novos = (make_date(extract(year from bi.hoje())::int + 16, 12, 31) - make_date(extract(year from bi.hoje())::int + 16, 1, 1) + 1)
                  and (select feriado from bi.d_calendario where data = make_date(extract(year from bi.hoje())::int + 16, 12, 25)) = 'Natal'
                  and not exists (select 1 from (select uteis_ate, (count(*) filter (where util) over (order by data))::int as u from bi.d_calendario) x where x.uteis_ate <> x.u),
  'bi: a rotina cria o ano novo inteiro, com feriados, e refaz a contagem de dias úteis');
select pg_temp.ok((select feriado from bi.d_calendario where data = '2026-04-03') = 'Sexta-feira Santa'
                  and (select feriado from bi.d_calendario where data = '2026-02-17') = 'Carnaval'
                  and (select feriado from bi.d_calendario where data = '2026-06-04') = 'Corpus Christi',
  'bi: feriados móveis pela Páscoa (Sexta-feira Santa, Carnaval, Corpus Christi de 2026)');
select pg_temp.ok((select feriado is not null from bi.d_calendario where data = '2026-11-20')
                  and (select feriado is null from bi.d_calendario where data = '2023-11-20'),
  'bi: Consciência Negra é feriado nacional a partir de 2024');
select pg_temp.ok((select not util and fim_de_semana and dia_semana = 6 from bi.d_calendario where data = '2026-11-14')
                  and (select util and dia_semana = 1 and semana_inicio = '2026-11-16' from bi.d_calendario where data = '2026-11-16'),
  'bi: sábado não é útil; segunda é dia 1 da semana ISO');
select pg_temp.ok((select ano_mes = '2026-11' and mes_nome = 'novembro' and trimestre_nome = '2026-T4' and mes_inicio = '2026-11-01'
                     and mes_fim = '2026-11-30' from bi.d_calendario where data = '2026-11-15'),
  'bi: o dia leva mês, trimestre, início e fim do mês');
select pg_temp.ok(bi.dias_uteis('2026-11-13', '2026-11-23') = 5,
  'bi: dias úteis entre duas datas descontam fim de semana e feriado (13 a 23/11/2026: 5)');
select pg_temp.ok(bi.data_sp('2026-11-15 01:30:00+00') = '2026-11-14' and bi.data_sp('2026-11-15 03:30:00+00') = '2026-11-15',
  'bi: a data de um instante é a de São Paulo');

-- sinal da DRE
select pg_temp.ok((select subtrai from erp.linhas_dre where codigo = 'custo_obra') and not (select subtrai from erp.linhas_dre where codigo = 'receita_bruta'),
  'bi: custo e despesa marcados para inverter na DRE; receita não');
select pg_temp.ok((select count(*) from bi.f_livro where valor_dre <> case when (select subtrai from erp.linhas_dre ld join erp.naturezas n on n.linha_dre = ld.codigo where n.id = natureza_id) then -valor else valor end) = 0,
  'bi: valor_dre inverte o sinal só nas linhas de custo e despesa (sem valor absoluto)');

-- nada se perde: o livro do bi soma o mesmo que o livro do ERP, com o mesmo número de linhas fora da natureza restrita
select pg_temp.ok((select sum(valor) from bi.f_livro) = (select sum(valor) from erp.lancamentos)
                  and (select count(*) from bi.f_livro) = (select count(*) from erp.lancamentos),
  'bi: o livro do bi bate com o livro do ERP');
select pg_temp.ok((select sum(valor) from bi.f_parcelas) = (select sum(p.valor) from erp.parcelas p join erp.titulos t on t.id = p.titulo_id where t.situacao <> 'rascunho'),
  'bi: o rateio das parcelas soma o valor de cada parcela, sem centavo perdido');
select pg_temp.ok((select count(*) from bi.f_pagamentos) = (select count(*) from erp.quitacoes),
  'bi: uma linha de pagamento por quitação');
select pg_temp.ok((select count(*) from bi.f_titulo_eventos where evento in ('aprovacao','recusa')) = (select count(*) from erp.titulo_aprovacoes)
                  and (select count(*) from bi.f_titulo_eventos where evento = 'titulo_lancado') = (select count(*) from erp.titulos),
  'bi: os eventos do título trazem cada lançamento e cada voto da alçada');
select pg_temp.ok(not exists (select 1 from bi.f_titulo_eventos where em is null or data is null or data <> bi.data_sp(em)),
  'bi: todo evento tem o instante e a data em São Paulo');

-- toda data dos fatos é um dia do calendário
select pg_temp.ok(not exists (
  select d from (select competencia d from bi.f_livro union select data_caixa from bi.f_livro union select lancado_data from bi.f_livro
                 union select emissao from bi.f_parcelas union select vencimento from bi.f_parcelas union select competencia from bi.f_parcelas
                 union select data_pagamento from bi.f_pagamentos union select vencimento from bi.f_pagamentos
                 union select data from bi.f_adiantamentos union select data from bi.f_titulo_eventos) x
  where d is not null and not exists (select 1 from bi.d_calendario c where c.data = x.d)),
  'bi: toda data dos fatos está no calendário');

-- atributos: o atual e a foto do mês
select pg_temp.ok((select valor from bi.d_nucleo_atributos where nucleo_economico_id = :'ne_vm' and atributo = 'faixa_mcmv' and mes = '2026-03-01') = 'Faixa 2'
                  and (select valor from bi.d_nucleo_atributos where nucleo_economico_id = :'ne_vm' and atributo = 'faixa_mcmv' and mes = '2026-08-01') = 'Faixa 3'
                  and (select atributos->>'faixa_mcmv' from bi.d_nucleo where nucleo_economico_id = :'ne_vm') = 'Faixa 3',
  'bi: o atributo do empreendimento tem a foto de cada mês e o valor atual');
-- CPF mascarado
insert into erp.pessoas (id, tipo, nome, documento) values ('10000000-0000-0000-0000-0000000000f1', 'fisica', 'Pessoa BI', '12345678901');
select pg_temp.ok((select documento from bi.d_pessoa where pessoa_id = '10000000-0000-0000-0000-0000000000f1') = '***.456.789-**',
  'bi: o CPF aparece só com os dígitos do meio (S-022)');
-- divisão em níveis e etiquetas
select pg_temp.ok(not exists (select 1 from bi.d_divisao where nivel1 is null or array_length(string_to_array(caminho, ' > '), 1) <> nivel)
                  and not exists (select 1 from bi.d_divisao d where d.nivel > 1 and d.nivel2 is null),
  'bi: cada divisão traz o nome de cada nível acima e o caminho');
select pg_temp.ok((select count(*) from bi.d_etiqueta) = (select count(*) from erp.etiquetas)
                  and (select count(*) from bi.f_titulo_etiquetas) = (select count(*) from erp.titulo_etiquetas),
  'bi: etiquetas como dimensão e a ponte com o título');
select pg_temp.ok((select count(*) from bi.f_livro where subdivisao_id is not null) = (select count(*) from erp.lancamentos where subdivisao_id is not null),
  'bi: o livro leva o subnível da divisão');
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'linhas_dre') is not null, 'bi: (linhas_dre tem gatilho de auditoria)');

-- quem vê o quê: o acesso do ERP; natureza restrita só com liberação e somada por mês
delete from erp.atribuicao_nucleos; delete from erp.atribuicao_tipos; delete from erp.atribuicoes;
\set bi1 'b1000000-0000-0000-0000-000000000001'
\set bi2 'b1000000-0000-0000-0000-000000000002'
\set bi3 'b1000000-0000-0000-0000-000000000003'
\set bi4 'b1000000-0000-0000-0000-000000000004'
insert into erp.usuarios (id, login_id, nome, papel) values
  (:'bi1', :'bi1', 'BI Mkt', 'leitura'), (:'bi2', :'bi2', 'BI Mkt com PJ', 'leitura'), (:'bi3', :'bi3', 'BI Obra', 'leitura'), (:'bi4', :'bi4', 'BI sem perfil', 'leitura');
insert into erp.naturezas (codigo, mae_id, nome, restrita) values ('06.77', pg_temp.nat('06'), 'Folha PJ (bi)', true);
insert into erp.perfis_modelo (id, nome) values
  ('a3000000-0000-0000-0000-000000000001', 'BI Mkt'), ('a3000000-0000-0000-0000-000000000002', 'BI Mkt PJ'), ('a3000000-0000-0000-0000-000000000003', 'BI Obra');
insert into erp.perfil_centros values
  ('a3000000-0000-0000-0000-000000000001', :'cc_mkt', 'leitor'), ('a3000000-0000-0000-0000-000000000002', :'cc_mkt', 'leitor'),
  ('a3000000-0000-0000-0000-000000000003', :'cc_obra', 'leitor');
insert into erp.perfil_naturezas values ('a3000000-0000-0000-0000-000000000002', pg_temp.nat('06.77'));
insert into erp.atribuicoes (user_id, perfil_id, escopo) values
  (:'bi1', 'a3000000-0000-0000-0000-000000000001', 'todos'), (:'bi2', 'a3000000-0000-0000-0000-000000000002', 'todos'),
  (:'bi3', 'a3000000-0000-0000-0000-000000000003', 'todos');
-- o livro só recebe linhas das operações (S-052): aqui, como o papel delas
set role erp_situacao;
insert into erp.lancamentos (estagio, empresa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_caixa, valor) values
  ('realizado', :'incorp', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), '2031-01-01', '2031-01-10', -1000),
  ('realizado', :'incorp', :'ne_corp', :'cc_mkt', pg_temp.nat('06.77'), '2031-01-01', '2031-01-05', -5000),
  ('realizado', :'incorp', :'ne_corp', :'cc_mkt', pg_temp.nat('06.77'), '2031-01-01', '2031-01-20', -3000),
  ('realizado', :'spe', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), '2031-01-01', '2031-01-15', -2000);
select pg_temp.como(null);
create function pg_temp.bi_soma() returns numeric language sql as $$ select coalesce(sum(valor), 0) from bi.f_livro where competencia = '2031-01-01' $$;
select pg_temp.ok((select count(*) from bi.f_livro where restrita and competencia = '2031-01-01') = 1
                  and (select valor = -8000 and valor_dre = 8000 and data_caixa = '2031-01-01' and lancamento_id is null and titulo_id is null and divisao_id is null
                         from bi.f_livro where restrita and competencia = '2031-01-01'),
  'bi: a natureza restrita entra no livro somada por centro e mês, sem lançamento, título, dia nem divisão');
select pg_temp.como(:'bi1');
select pg_temp.ok(pg_temp.bi_soma() = -1000 and not exists (select 1 from bi.f_livro where restrita),
  'bi: quem vê o Marketing sem a natureza PJ soma só o Marketing, sem o PJ (soma ' || pg_temp.bi_soma() || ')');
select pg_temp.como(:'bi2');
select pg_temp.ok(pg_temp.bi_soma() = -1000 and not exists (select 1 from bi.f_livro where restrita),
  'bi: o modelo com a natureza PJ não mostra o PJ (só o master e os designados; soma ' || pg_temp.bi_soma() || ')');
select pg_temp.como(null);
insert into erp.designados_pj (user_id, motivo, por) values (:'bi2', 'BI do PJ', :'diretor');
select pg_temp.como(:'bi2');
select pg_temp.ok(pg_temp.bi_soma() = -9000 and (select count(*) from bi.f_livro where restrita and competencia = '2031-01-01') = 1,
  'bi: designado pelo master, vê o PJ do centro somado no mês (soma ' || pg_temp.bi_soma() || ')');
select pg_temp.como(:'bi3');
select pg_temp.ok(pg_temp.bi_soma() = -2000, 'bi: quem vê a Obra não soma o Marketing (soma ' || pg_temp.bi_soma() || ')');
select pg_temp.como(:'bi4');
select pg_temp.ok(pg_temp.bi_soma() = 0 and not exists (select 1 from bi.f_parcelas) and not exists (select 1 from bi.f_pagamentos)
                  and not exists (select 1 from bi.f_titulo_eventos),
  'bi: sem perfil, nenhum fato aparece');
select pg_temp.como('ffffffff-0000-0000-0000-00000000dead');
select pg_temp.ok(not exists (select 1 from bi.d_calendario) and not exists (select 1 from bi.d_nucleo) and not exists (select 1 from bi.f_livro),
  'bi: login sem cadastro no ERP não lê nem o calendário');
select pg_temp.como(:'bi1');
select pg_temp.falha($$insert into bi.d_calendario (data) values ('2041-01-01')$$, 'bi: ninguém grava no calendário');
select pg_temp.falha($$update bi.d_calendario set util = false where data = '2031-01-02'$$, 'bi: ninguém muda o calendário');
select pg_temp.falha($$select bi.estender_calendario(20)$$, 'bi: só o sistema estende o calendário');
select pg_temp.como(null);

-- título com linha restrita sai das parcelas, dos pagamentos e das etapas (o livro guarda a soma)
select count(*) as bi_parc_obra from bi.f_parcelas where natureza_id = pg_temp.nat('04.01') \gset
select pg_temp.ok(:bi_parc_obra > 0, 'bi: (há parcelas de obra para o teste: ' || :bi_parc_obra || ')');
-- rascunho não entra nas parcelas
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('c2000000-0000-0000-0000-0000000000b1', :'incorp', 'avulso', '10000000-0000-0000-0000-000000000007', '2031-01-05', '2031-01-01', 700);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('c2000000-0000-0000-0000-0000000000b1', 1, '2031-02-10', 700);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('c2000000-0000-0000-0000-0000000000b1', :'ne_corp', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.ok(exists (select 1 from erp.parcelas where titulo_id = 'c2000000-0000-0000-0000-0000000000b1')
                  and not exists (select 1 from bi.f_parcelas where titulo_id = 'c2000000-0000-0000-0000-0000000000b1'),
  'bi: título em rascunho não entra nas parcelas');
-- quem vê o título só por ter votado na alçada (sem perfil) não vê, nas parcelas, as linhas que não vê
-- (a alçada inventada vai num centro em que o título ainda não tem alçada: desde 18/11/2026 todo centro do rateio tem)
select t.id as bi_tit_alc, t.rodada as bi_rod,
       (select c.id from erp.centros_custo c where not exists (select 1 from erp.titulo_alcadas a where a.titulo_id = t.id and a.rodada = t.rodada
                                                                  and a.centro_custo_id = c.id and a.divisao_id is null) order by c.id limit 1) as bi_cc_alc
  from erp.titulos t where t.situacao <> 'rascunho' and exists (select 1 from erp.parcelas p where p.titulo_id = t.id)
   and exists (select 1 from erp.titulo_rateios r where r.titulo_id = t.id and r.centro_custo_id is not null)
 order by t.criado_em limit 1 \gset
set role erp_situacao;
insert into erp.titulo_alcadas (id, titulo_id, rodada, centro_custo_id, fases, valor_no_centro, acumulado, titulos)
values ('c3000000-0000-0000-0000-0000000000a1', :'bi_tit_alc', :bi_rod, :'bi_cc_alc', array['AF'], 1, 1, array[:'bi_tit_alc'::uuid]);
reset role;
select set_config('request.jwt.claim.sub', :'bi4', false);
set role erp_situacao;
insert into erp.titulo_aprovacoes (alcada_id, fase, lista, aprovado) values ('c3000000-0000-0000-0000-0000000000a1', 1, 'AF', true);
select pg_temp.como(:'bi4');
select pg_temp.ok(exists (select 1 from erp.parcelas where titulo_id = :'bi_tit_alc')
                  and not exists (select 1 from bi.f_parcelas where titulo_id = :'bi_tit_alc'),
  'bi: quem vê o título por ter votado não soma nas parcelas a linha de centro que não vê');
select pg_temp.como(null);
-- uma etiqueta num título pago, de natureza comum (o título pago tem linha que vai virar restrita)
insert into erp.etiquetas (id, nome) values ('c4000000-0000-0000-0000-0000000000e1', 'Campanha BI');
insert into erp.titulo_etiquetas (titulo_id, etiqueta_id)
select p.titulo_id, 'c4000000-0000-0000-0000-0000000000e1' from erp.quitacoes q join erp.parcelas p on p.id = q.parcela_id limit 1;
-- natureza restrita: torna restritas a obra e as naturezas de um título pago e de um com etiqueta
select (select r.natureza_id from erp.titulo_rateios r join erp.parcelas p on p.titulo_id = r.titulo_id
          join erp.quitacoes q on q.parcela_id = p.id limit 1) as bi_nat_pag,
       (select r.natureza_id from erp.titulo_rateios r join erp.titulo_etiquetas te on te.titulo_id = r.titulo_id limit 1) as bi_nat_et \gset
select pg_temp.ok(exists (select 1 from bi.f_pagamentos g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and r.natureza_id = :'bi_nat_pag'))
                  and exists (select 1 from bi.f_titulo_etiquetas g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and r.natureza_id = :'bi_nat_et')),
  'bi: (há título pago e título com etiqueta para o teste da natureza restrita)');
update erp.naturezas set restrita = true where codigo = '04.01' or id in (:'bi_nat_pag', :'bi_nat_et');
select pg_temp.ok(not exists (select 1 from bi.f_pagamentos g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and erp.natureza_restrita(r.natureza_id)))
                  and not exists (select 1 from bi.f_titulo_etiquetas g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and erp.natureza_restrita(r.natureza_id)))
                  and not exists (select 1 from bi.f_parcelas g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and erp.natureza_restrita(r.natureza_id)))
                  and not exists (select 1 from bi.f_titulo_eventos g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and erp.natureza_restrita(r.natureza_id))),
  'bi: título com qualquer linha restrita, mesmo misturada com linha comum, sai de parcelas, pagamentos, eventos e etiquetas (S-113)');
select pg_temp.ok(not exists (select 1 from bi.f_parcelas where natureza_id = pg_temp.nat('04.01'))
                  and not exists (select 1 from bi.f_titulo_eventos e where exists (select 1 from erp.titulo_rateios r where r.titulo_id = e.titulo_id and r.natureza_id = pg_temp.nat('04.01')))
                  and not exists (select 1 from bi.f_pagamentos g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and r.natureza_id = pg_temp.nat('04.01')))
                  and not exists (select 1 from bi.f_titulo_etiquetas g where exists (select 1 from erp.titulo_rateios r where r.titulo_id = g.titulo_id and r.natureza_id = pg_temp.nat('04.01'))),
  'bi: título com linha de natureza restrita não aparece em parcelas, pagamentos, eventos nem etiquetas');
select pg_temp.ok((select sum(valor) from bi.f_livro) = (select sum(valor) from erp.lancamentos),
  'bi: somada, a natureza restrita não muda o total do livro');

-- catálogo: só leitura, só para o usuário logado, sempre com o RLS de quem consulta
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               where n.nspname = 'bi' and c.relkind = 'v'
                                 and not (coalesce(c.reloptions, '{}') @> array['security_invoker=true', 'security_barrier=true'])),
  'bi: toda visão é security_invoker e security_barrier');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               where n.nspname = 'bi' and c.relkind = 'r' and not (c.relrowsecurity and c.relforcerowsecurity)),
  'bi: toda tabela tem RLS forçado');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
                               where n.nspname = 'bi' and c.relkind in ('r','v') and has_table_privilege('authenticated', c.oid, p.priv)),
  'bi: o usuário logado não grava em nada do bi');
select pg_temp.ok(not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                               cross join (values ('anon'), ('service_role')) r(papel)
                               where n.nspname = 'bi' and c.relkind in ('r','v') and exists (select 1 from pg_roles where rolname = r.papel)
                                 and has_table_privilege(r.papel, c.oid, 'SELECT'))
                  and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace, aclexplode(c.relacl) a
                                   where n.nspname = 'bi' and a.grantee = 0)
                  and not has_schema_privilege('public', 'bi', 'USAGE'),
  'bi: nada para anon, service_role nem public');
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'bi' and p.prosecdef),
  'bi: nenhuma função definer (o acesso é só o RLS de quem consulta)');
rollback;

-- ---------------------------------------------------------------------
\echo '# envio ao Sienge: forma de pagamento, de-para, fila e pedido'
begin;
select pg_temp.ok(erp.linha_digitavel_valida('34191090080000000212134567890008799990000000100'), 'sienge: linha digitável com os DVs certos vale');
select pg_temp.ok(not erp.linha_digitavel_valida('34191090080000000212134567890008799990000000101')
                  and not erp.linha_digitavel_valida('34191090090000000212134567890008799990000000100')
                  and not erp.linha_digitavel_valida('3419109008'),
  'sienge: linha com DV geral, DV de campo ou tamanho errado é recusada');
select pg_temp.ok(erp.chave_pix_valida('cpf_cnpj', '29732041000154') and erp.chave_pix_valida('email', 'teste@example.com')
                  and erp.chave_pix_valida('telefone', '+5511987654321') and not erp.chave_pix_valida('email', 'Teste@Example.com')
                  and not erp.chave_pix_valida('cpf_cnpj', '29.732.041/0001-54') and not erp.chave_pix_valida('outro', 'x'),
  'sienge: chave PIX conferida pelo tipo (só dígitos, e-mail minúsculo, telefone com +55)');

-- a nota sem retenção vira título aberto, na alçada, sem voto ainda
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000000e1', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9001', '2026-06-02', '2026-06-01', 300);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000e1', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 66.6667),
  ('70000000-0000-0000-0000-0000000000e1', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 33.3333);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000e1', array['2026-06-20','2026-07-20']::date[]) as tse \gset
select pg_temp.sis();
select pg_temp.ok(erp.alcada_fase(:'tse') is not null and not erp.titulo_aprovado(:'tse'), 'sienge: o título lançado espera a alçada');
select pg_temp.volta();
select pg_temp.ok(not has_function_privilege('authenticated', 'erp.titulo_aprovado(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._conferir_forma_pagamento(uuid, int, text, text, text, text, text)', 'EXECUTE'),
  'S-126: titulo_aprovado e a conferência da forma de pagamento não são executáveis pela API');
-- o beneficiário dos boletos dos testes, conferido pelo sistema (20/11/2026: sem conferência, o boleto só entra com a
-- justificativa; os testes do beneficiário ficam no bloco do PIX copia e cola)
select pg_temp.sis();
select erp.registrar_boleto_conferencia(l, d, n, v, null, (select login_id from erp.usuarios where id = :'diretor'))
  from (values ('34191090080000000212134567890008199990000000000', '77777777000177', 'AGENCIA BETA LTDA', null::numeric),
               ('34191090080000000212134567890008899990000015000', '29.732.041/0001-54', 'FORNECEDOR EXEMPLO LTDA', 150)) x(l, d, n, v);
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'tse', 1, 'pix', 'email', 'teste@example.com');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', '34191090080000000212134567890008999990000015000')$$, :'tse'),
  'sienge: boleto com linha digitável errada não entra');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo) values (%L, 2, 'pix', 'email')$$, :'tse'),
  'sienge: PIX sem chave não entra');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (%L, 2, 'pix', 'email', 'Teste@Example.com')$$, :'tse'),
  'sienge: chave PIX fora do formato do tipo não entra (a validação da chave)');
-- S-125 (Moises, 17/11/2026): o valor impresso no boleto é o da parcela (ou zero) e a chave CPF/CNPJ é do credor,
-- salvo a exceção com justificativa
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', '34191090080000000212134567890008799990000000100')$$, :'tse'),
  'O valor do boleto (1.00) não é o da parcela 2 (150.00)', 'S-125: boleto de outro valor não entra');
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (%L, 2, 'pix', 'cpf_cnpj', '29732041000154')$$, :'tse'),
  'A chave PIX por CPF/CNPJ da parcela 2 não é o documento do credor do título (só com a justificativa da exceção)',
  'S-125: chave CPF/CNPJ de outra pessoa não entra sem justificativa');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_excecao) values (%L, 2, 'pix', 'cpf_cnpj', '29732041000154', '  ')$$, :'tse'),
  'S-125: justificativa em branco não vale');
savepoint sp_exc;
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_excecao)
values (:'tse', 2, 'pix', 'cpf_cnpj', '29732041000154', 'Pagamento ao sócio, pedido por escrito');
select pg_temp.ok((select avisos = array['Chave CPF/CNPJ de outra pessoa: Pagamento ao sócio, pedido por escrito', 'Chave nova para este credor']
                     from erp.avisos_forma_pagamento(:'tse') where numero = 2)
                  and (select avisos = array['A chave não é do documento do credor', 'Chave nova para este credor']
                     from erp.avisos_forma_pagamento(:'tse') where numero = 1),
  'S-125: a exceção entra com a justificativa e quem aprova vê os avisos: outra pessoa, chave que não é do documento, chave nova');
update erp.parcela_pagamentos set pix_chave = '77777777000177' where titulo_id = :'tse' and numero = 2;
select pg_temp.ok((select pix_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'S-125: com a chave do próprio credor, a exceção some');
update erp.parcela_pagamentos set pix_tipo = 'email', pix_chave = 'b@example.com', pix_excecao = 'x' where titulo_id = :'tse' and numero = 2;
select pg_temp.ok((select pix_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'S-125: a exceção só existe na chave CPF/CNPJ');
rollback to savepoint sp_exc;
savepoint sp_forma;
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'tse', 2, 'boleto', '34191090080000000212134567890008199990000000000');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'tse', 2, 'pix', 'cpf_cnpj', '77777777000177')
  on conflict (titulo_id, numero) do update set forma = excluded.forma, pix_tipo = excluded.pix_tipo, pix_chave = excluded.pix_chave, boleto_linha = null;
select pg_temp.ok((select pix_chave = '77777777000177' from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'S-125: boleto sem valor impresso entra, e a chave CPF/CNPJ do próprio credor também');
rollback to savepoint sp_forma;
-- PIX copia e cola da parcela (20/11/2026): formato e CRC conferidos, e o valor do código é o da parcela
savepoint sp_pixcc;
select pg_temp.ok(erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6') and erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63045E2F')
                  and not erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E7') and not erp.pix_copia_cola_valido('26390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6')
                  and not erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E60') and erp.pix_copia_cola_valor('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6') = 150
                  and erp.pix_copia_cola_valor('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63045E2F') is null,
  'pix copia e cola: CRC, começo e campos conferidos; o valor vem do campo 54');
select pg_temp.ok(not erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005406100.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO6304A6FD')
                  and not erp.pix_copia_cola_valido('00020126610014br.gov.bcb.pix0117teste@example.com0118fraude@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO6304C06D')
                  and not erp.pix_copia_cola_valido('00020126390014br.gov.bcb.pix0117teste@example.com26390014br.gov.bcb.pix0117fraud@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO63049946'),
  'pix copia e cola: campo repetido é recusado (dois 54, duas chaves na conta PIX, dois 26), mesmo com o CRC certo');
update erp.parcela_pagamentos set pix_copia_cola = '00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6' where titulo_id = :'tse' and numero = 1;
select pg_temp.ok((select pix_copia_cola is not null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 1),
  'pix copia e cola: entra na parcela com o valor dela (150 de 300 em duas)');
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126410014br.gov.bcb.pix0119agencia@example.com5204000053039865406100.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63046CD8' where titulo_id = %L and numero = 1$$, :'tse'),
  'O valor do PIX copia e cola (100.00) não é o da parcela 1 (150.00)', 'pix copia e cola: valor diferente do da parcela é recusado');
select pg_temp.falha(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E7' where titulo_id = %L and numero = 1$$, :'tse'),
  'pix copia e cola: CRC errado é recusado');
-- o recebedor (revisão de segurança, 20/11/2026): o código leva quem recebe, e ele tem de ser o da parcela ou do credor
select pg_temp.ok(erp.pix_copia_cola_recebedor('00020126390014br.gov.bcb.pix0117outra@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304168B') = '{"chave": "outra@example.com", "url": null, "nome": "FORNECEDOR EXEMPLO", "contas": 1}'::jsonb
                  and erp.pix_copia_cola_recebedor('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF')->>'url' = 'pix.example.com/qr/v2/cobv/0123456789abcdef'
                  and erp.pix_copia_cola_recebedor('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF')->>'chave' is null,
  'pix copia e cola: o recebedor sai do campo 26 (chave no estático, URL no dinâmico) e o nome do 59');
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126390014br.gov.bcb.pix0117outra@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304168B' where titulo_id = %L and numero = 1$$, :'tse'),
  'A chave do PIX copia e cola da parcela 1 não é a chave PIX da parcela (só com a justificativa da exceção)',
  'pix copia e cola: chave de outro no código da parcela PIX é recusada sem justificativa');
update erp.parcela_pagamentos set pix_copia_cola = '00020126390014br.gov.bcb.pix0117outra@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304168B', pix_copia_cola_excecao = 'Pedido do fornecedor por escrito' where titulo_id = :'tse' and numero = 1;
select pg_temp.ok((select pix_copia_cola_excecao = 'Pedido do fornecedor por escrito' from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 1)
                  and (select j->'parcelas'->0->'pix_copia_cola_recebedor'->>'chave' = 'outra@example.com'
                          and j->'parcelas'->0->>'pix_copia_cola_excecao' = 'Pedido do fornecedor por escrito' from api.titulo(:'tse') j),
  'pix copia e cola: com a justificativa entra, e o título mostra a quem aprova o recebedor e a justificativa');
update erp.parcela_pagamentos set pix_copia_cola = '00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6' where titulo_id = :'tse' and numero = 1;
select pg_temp.ok((select pix_copia_cola_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 1),
  'pix copia e cola: voltando à chave da parcela, a exceção some');
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, pix_copia_cola) values (%L, 2, 'boleto', '34191090080000000212134567890008199990000000000', '00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63045E2F')$$, :'tse'),
  'A chave do PIX copia e cola da parcela 2 não é a do CPF/CNPJ do credor (só com a justificativa da exceção)',
  'pix copia e cola: no boleto, chave que não é o CPF/CNPJ do credor é recusada sem justificativa');
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, pix_copia_cola) values (%L, 2, 'boleto', '34191090080000000212134567890008199990000000000', '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF')$$, :'tse'),
  'O PIX copia e cola da parcela 2 é dinâmico e quem recebe não foi conferido (só com a justificativa da exceção)',
  'pix copia e cola: código dinâmico sem justificativa é recusado');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, pix_copia_cola, pix_copia_cola_excecao) values (%L, 2, 'boleto', '34191090080000000212134567890008199990000000000', '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '   ')$$, :'tse'),
  'pix copia e cola: justificativa em branco não vale');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, pix_copia_cola) values (:'tse', 2, 'boleto', '34191090080000000212134567890008199990000000000', '00020126360014br.gov.bcb.pix0114777777770001775204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63049C9D');
select pg_temp.ok((select pix_copia_cola is not null and pix_copia_cola_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'pix copia e cola: entra também no boleto (o QR do boleto híbrido) com o CNPJ do credor, e sem valor no código passa');
-- segunda revisão: chave do credor com URL é dinâmico (o banco paga a quem a URL indicar), e duas contas PIX não entram
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126730014br.gov.bcb.pix0114777777770001772533pix.example.com/qr/v2/cobv/fraude5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304AA19' where titulo_id = %L and numero = 2$$, :'tse'),
  'O PIX copia e cola da parcela 2 é dinâmico e quem recebe não foi conferido (só com a justificativa da exceção)',
  'pix copia e cola: a chave do credor com uma URL junto é tratada como dinâmico e pede a justificativa');
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126360014br.gov.bcb.pix01147777777700017727400014br.gov.bcb.pix0118fraude@example.com5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304D94E', pix_copia_cola_excecao = 'x' where titulo_id = %L and numero = 2$$, :'tse'),
  'O PIX copia e cola da parcela 2 traz mais de uma conta PIX', 'pix copia e cola: código com duas contas PIX é recusado, mesmo com justificativa');
-- a conferência pelo Asaas: só o sistema grava, e com o documento do credor dispensa a justificativa (também no dinâmico)
select pg_temp.falha(format($$select erp.registrar_pix_conferencia(%L, '77777777000177', 'X', 'Banco', null, 150, 'x')$$, '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF'),
  'pix conferência: pela API, ninguém grava a conferência pela função');
select pg_temp.falha(format($$insert into erp.pix_conferencias (codigo, cpf_cnpj) values (%L, '77777777000177')$$, '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF'),
  'pix conferência: pela API, ninguém grava a conferência direto na tabela');
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '77.777.777/0001-77', 'AGENCIA BETA LTDA', 'Banco Exemplo', null, 100,
  (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.ok(erp.conferencia_tentativa((select login_id from erp.usuarios where id = :'diretor')) = 1
                  and erp.conferencia_tentativa((select login_id from erp.usuarios where id = :'diretor')) = 2
                  and erp.conferencia_tentativa('login-que-nao-existe') is null,
  'pix conferência: o sistema conta cada pedido da pessoa (o limite da função), e quem não é usuário ativo não segue');
select pg_temp.volta();
select pg_temp.falha($$select erp.conferencia_tentativa('x')$$, 'pix conferência: pela API, ninguém registra pedido');
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = %L, pix_copia_cola_excecao = null where titulo_id = %L and numero = 2$$, '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', :'tse'),
  'O PIX copia e cola da parcela 2 é dinâmico e quem recebe não foi conferido (só com a justificativa da exceção)',
  'pix conferência: a conferência com o valor cobrado diferente do da parcela não dispensa a justificativa');
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '77.777.777/0001-77', 'AGENCIA BETA LTDA', 'Banco Exemplo', null, 150,
  (select login_id from erp.usuarios where id = :'diretor'));
update erp.pix_conferencias set conferido_em = clock_timestamp() - interval '25 hours' where codigo = '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF';
select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola = %L, pix_copia_cola_excecao = null where titulo_id = %L and numero = 2$$, '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', :'tse'),
  'O PIX copia e cola da parcela 2 é dinâmico e quem recebe não foi conferido (só com a justificativa da exceção)',
  'pix conferência: conferência de mais de 1 dia não dispensa a justificativa');
select pg_temp.sis();
update erp.pix_conferencias set conferido_em = clock_timestamp() where codigo = '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF';
select pg_temp.volta();
update erp.parcela_pagamentos set pix_copia_cola = '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', pix_copia_cola_excecao = null where titulo_id = :'tse' and numero = 2;
select pg_temp.ok((select pix_copia_cola_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2)
                  and (select j->'parcelas'->1->'pix_copia_cola_conferido'->>'cpf_cnpj' = '77777777000177' from api.titulo(:'tse') j),
  'pix conferência: o dinâmico conferido no Asaas com o documento do credor entra sem justificativa, e o título mostra a conferência');
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '29732041000154', 'OUTRA PESSOA', 'Banco Exemplo', null, 150,
  (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola_excecao = null, boleto_linha = boleto_linha where titulo_id = %L and numero = 2$$, :'tse'),
  'Quem recebe pelo PIX copia e cola da parcela 2 (OUTRA PESSOA, conferido) não é o credor (só com a justificativa da exceção)',
  'pix conferência: quem recebe conferido no Asaas sendo outra pessoa pede a justificativa');
-- S-140: o mesmo CPF/CNPJ do credor, mas outro nome (o credor cadastrado com o documento de quem frauda)
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '77777777000177', 'JOAO DA SILVA', 'Banco Exemplo', null, 150,
  (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_copia_cola_excecao = null, boleto_linha = boleto_linha where titulo_id = %L and numero = 2$$, :'tse'),
  'Quem recebe pelo PIX copia e cola da parcela 2 (JOAO DA SILVA, conferido) não é o credor (só com a justificativa da exceção)',
  'S-140: PIX copia e cola conferido com o documento do credor e outro nome pede a justificativa');
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '77777777000177', 'AGENCIA BETA COMUNICACAO E PUBLICIDADE LTDA', 'Banco Exemplo', null, 150,
  (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
update erp.parcela_pagamentos set pix_copia_cola_excecao = null, boleto_linha = boleto_linha where titulo_id = :'tse' and numero = 2;
select pg_temp.ok((select pix_copia_cola_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'S-140: o nome completo do banco confere com o nome curto do cadastro (a primeira palavra)');
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '29732041000154', 'OUTRA PESSOA', 'Banco Exemplo', null, 150,
  (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
update erp.parcela_pagamentos set pix_copia_cola = '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', pix_copia_cola_excecao = 'QR dinâmico do banco do boleto' where titulo_id = :'tse' and numero = 2;
select pg_temp.ok((select pix_copia_cola_excecao is not null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2),
  'pix copia e cola: o dinâmico entra com a justificativa');
select pg_temp.ok(not has_function_privilege('anon', 'erp.pix_copia_cola_valido(text)', 'EXECUTE'),
  'pix copia e cola: a conferência não é de public');
rollback to savepoint sp_pixcc;
-- beneficiário do boleto conferido (Moises, 20/11/2026: o mesmo esquema do PIX), e o selo até o pagamento
savepoint sp_bol;
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', %L)$$, :'tse', '34191090080000000212134567890008899990000015000'),
  'O beneficiário do boleto da parcela 2 (FORNECEDOR EXEMPLO LTDA, conferido) não é o credor (só com a justificativa da exceção)',
  'boleto: beneficiário conferido que não é o credor pede a justificativa');
select pg_temp.falha(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, boleto_excecao) values (%L, 2, 'boleto', %L, '  ')$$, :'tse', '34191090080000000212134567890008899990000015000'),
  'boleto: justificativa em branco não vale');
select pg_temp.falha(format($$select erp.registrar_boleto_conferencia(%L, '77777777000177', 'X', 150, null, 'x')$$, '34191090080000000212134567890008899990000015000'),
  'boleto: pela API, ninguém grava a conferência pela função');
select pg_temp.falha(format($$insert into erp.boleto_conferencias (linha, cpf_cnpj) values (%L, '77777777000177')$$, '34191090080000000212134567890008899990000015000'),
  'boleto: pela API, ninguém grava a conferência direto na tabela');
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'AGENCIA BETA LTDA', 100, null, (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', %L)$$, :'tse', '34191090080000000212134567890008899990000015000'),
  'O beneficiário do boleto da parcela 2 não foi conferido (só com a justificativa da exceção)',
  'boleto: conferência com o valor registrado diferente do da parcela não vale');
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'AGENCIA BETA LTDA', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
update erp.boleto_conferencias set conferido_em = clock_timestamp() - interval '25 hours' where linha = '34191090080000000212134567890008899990000015000';
select pg_temp.volta();
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', %L)$$, :'tse', '34191090080000000212134567890008899990000015000'),
  'O beneficiário do boleto da parcela 2 não foi conferido (só com a justificativa da exceção)',
  'boleto: conferência de mais de 1 dia não vale');
select pg_temp.sis();
update erp.boleto_conferencias set conferido_em = clock_timestamp() where linha = '34191090080000000212134567890008899990000015000';
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, boleto_excecao) values (:'tse', 2, 'boleto', '34191090080000000212134567890008899990000015000', 'x');
select pg_temp.ok((select boleto_excecao is null from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2)
                  and (select j->'parcelas'->1->'boleto_conferido'->>'cpf_cnpj' = '77777777000177' and j->'recebedor_divergente' = '[]'::jsonb from api.titulo(:'tse') j)
                  and not exists (select 1 from api.recebedores_divergentes() where id = :'tse'),
  'boleto: com o credor conferido, entra sem justificativa (a que veio some), o título mostra a conferência e não ganha o selo');
rollback to savepoint sp_bol;
savepoint sp_bol;
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_excecao) values (:'tse', 2, 'pix', 'cpf_cnpj', '29732041000154', 'Pagamento ao sócio');
select pg_temp.ok((select j->'recebedor_divergente' = '["Parcela 2: chave PIX de outra pessoa (Pagamento ao sócio)"]'::jsonb from api.titulo(:'tse') j)
                  and exists (select 1 from api.recebedores_divergentes() where id = :'tse'),
  'selo: a chave CPF/CNPJ de outra pessoa (S-125) também mostra que o recebedor não bate');
rollback to savepoint sp_bol;
savepoint sp_bol;
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, boleto_excecao) values (:'tse', 2, 'boleto', '34191090080000000212134567890008899990000015000', 'Cobrança pela financeira');
select pg_temp.sis(); set local role erp_situacao; update erp.titulos set situacao = 'quitado' where id = :'tse'; select pg_temp.volta();
select pg_temp.ok((select j->'recebedor_divergente' = '[]'::jsonb from api.titulo(:'tse') j) and not exists (select 1 from api.recebedores_divergentes() where id = :'tse'),
  'selo: pago, o título deixa de mostrar o selo');
rollback to savepoint sp_bol;
-- S-140: o boleto conferido com o documento do credor e outro nome
savepoint sp_bol;
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'JOAO DA SILVA ME', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', '34191090080000000212134567890008899990000015000')$$, :'tse'),
  'O beneficiário do boleto da parcela 2 (JOAO DA SILVA ME, conferido) não é o credor (só com a justificativa da exceção)',
  'S-140: boleto conferido com o documento do credor e outro nome pede a justificativa');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, boleto_excecao) values (:'tse', 2, 'boleto', '34191090080000000212134567890008899990000015000', 'Conta no nome do sócio');
select pg_temp.ok(exists (select 1 from api.recebedores_divergentes() where id = :'tse'),
  'S-140: com a justificativa entra, e o selo do recebedor fica até o pagamento');
select pg_temp.sis();
update erp.boleto_conferencias set nome = 'Agência Beta' where linha = '34191090080000000212134567890008899990000015000';
select pg_temp.volta();
update erp.parcela_pagamentos set boleto_excecao = null where titulo_id = :'tse' and numero = 2;
select pg_temp.sis();
update erp.boleto_conferencias set nome = 'JOAO DA SILVA ME' where linha = '34191090080000000212134567890008899990000015000';
select pg_temp.erro_igual(format($$select erp._conferir_recebedores(%L)$$, :'tse'),
  'O beneficiário do boleto da parcela 2 não confere com o credor do título (confira o boleto de novo ou justifique a exceção)',
  'S-140: a conferência de novo (troca do credor e pedido do Sienge) também compara o nome');
select pg_temp.volta();
-- revisão do #115: o nome fantasia (que quem cadastra escolhe) não vale para a conferência
select pg_temp.sis();
update erp.pessoas set nome_fantasia = 'JOAO DA SILVA' where id = '10000000-0000-0000-0000-000000000007';
select pg_temp.volta();
delete from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2;
select pg_temp.erro_igual(format($$insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (%L, 2, 'boleto', '34191090080000000212134567890008899990000015000')$$, :'tse'),
  'O beneficiário do boleto da parcela 2 (JOAO DA SILVA ME, conferido) não é o credor (só com a justificativa da exceção)',
  'S-140: credor com o nome fantasia igual ao nome conferido e outra razão social é recusado sem justificativa');
rollback to savepoint sp_bol;
select pg_temp.ok(erp.nome_confere('ACME ENG LTDA', 'Acme Engenharia Ltda.')
                  and erp.nome_confere('CONSTRUTORA ACME', 'Acme Construções e Serviços Ltda')
                  and erp.nome_confere(null, 'Acme')
                  and not erp.nome_confere('JOAO DA SILVA', 'Acme Engenharia Ltda')
                  and not erp.nome_confere('CONSTRUTORA SILVA', 'Construtora Acme')
                  and not erp.nome_confere('LTDA', 'Acme')
                  and erp.nome_confere('SERVICOS GERAIS', 'Servicos Gerais ME'),
  'S-140: o nome confere pela primeira palavra que identifica (forma jurídica, ligações e palavras genéricas não contam)');
-- S-140: o selo "credor novo" (nunca teve outro título que foi ao Sienge ou foi pago)
savepoint sp_novo;
select pg_temp.sis();
insert into erp.pessoas (id, tipo, nome, documento) values ('10000000-0000-0000-0000-0000000000c1', 'juridica', 'Credor Recém Cadastrado', '12345678000195');
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-0000000000c1', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'primeiro do credor novo') as tnovo1 \gset
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-0000000000c1', null, null, '2026-06-03', '2026-06-01',
  90, array['2026-07-02']::date[], null, null, 'segundo do credor novo') as tnovo2 \gset
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.credor_novo(:'tnovo1') = current_date and exists (select 1 from api.credores_novos() where id = :'tnovo1' and desde = current_date)
                  and (select (j->>'credor_novo')::date = current_date from api.titulo(:'tnovo1') j),
  'S-140: credor sem título que já foi ao Sienge ou foi pago aparece como novo, nas listas e na gaveta');
select pg_temp.como(:'analista2');
select pg_temp.ok(not erp.vejo_titulo(:'tnovo1') and erp.credor_novo(:'tnovo1') is null and not exists (select 1 from api.credores_novos() where id = :'tnovo1'),
  'S-140: sobre título que a pessoa não vê, a função não responde');
savepoint sp_quit;
select pg_temp.sis(); set local role erp_situacao; update erp.titulos set situacao = 'quitado' where id = :'tnovo2'; select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.credor_novo(:'tnovo1') is null, 'S-140: credor com título já pago (mesmo fora do Sienge) não é novo');
rollback to savepoint sp_quit;
select pg_temp.sis(); insert into erp.sienge_envios (titulo_id, situacao, sienge_id) values (:'tnovo2', 'enviado', 999001); select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.credor_novo(:'tnovo1') is null and (select j->'credor_novo' = 'null'::jsonb from api.titulo(:'tnovo1') j),
  'S-140: depois que outro título do credor foi ao Sienge, ele deixa de ser novo');
select pg_temp.ok(erp.credor_novo(:'tnovo2') = current_date,
  'S-140: o próprio título que foi ao Sienge não conta para ele mesmo');
rollback to savepoint sp_novo;
-- revisão do #108: o credor trocado depois da conferência (o fraudador conferido, o fornecedor de verdade no título)
savepoint sp_bol;
set constraints erp.t_titulo_recebedor immediate;
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'AGÊNCIA BETA', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'rascunho do credor trocado') as trasc \gset
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'trasc', 1, 'boleto', '34191090080000000212134567890008899990000015000');
select pg_temp.erro_igual(format($$update erp.titulos set pessoa_id = '10000000-0000-0000-0000-000000000008' where id = %L$$, :'trasc'),
  'O beneficiário do boleto da parcela 1 não confere com o credor do título (confira o boleto de novo ou justifique a exceção)',
  'boleto: no rascunho, trocar o credor depois do boleto conferido é recusado');
delete from erp.parcela_pagamentos where titulo_id = :'trasc';
update erp.titulos set pessoa_id = '10000000-0000-0000-0000-000000000008' where id = :'trasc';
select pg_temp.ok((select pessoa_id = '10000000-0000-0000-0000-000000000008' from erp.titulos where id = :'trasc'),
  'boleto: sem a forma conferida, o credor muda (a forma nova se confere com ele)');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'tse', 2, 'boleto', '34191090080000000212134567890008899990000015000');
select pg_temp.sis();
update erp.boleto_conferencias set cpf_cnpj = '88888888000188' where linha = '34191090080000000212134567890008899990000015000';
select pg_temp.volta();
select pg_temp.erro_igual(format($$select erp._conferir_recebedores(%L)$$, :'tse'),
  'permission denied for function _conferir_recebedores', 'recebedor: a nova conferência não é da API');
select pg_temp.sis();
select pg_temp.erro_igual(format($$select erp._conferir_recebedores(%L)$$, :'tse'),
  'O beneficiário do boleto da parcela 2 não confere com o credor do título (confira o boleto de novo ou justifique a exceção)',
  'boleto: a conferência de novo pega o beneficiário que deixou de ser o credor');
select pg_temp.ok(pg_get_functiondef('erp.sienge_pedido(uuid)'::regprocedure) like '%perform erp._conferir_recebedores(t.id);%',
  'boleto: o pedido do Sienge confere de novo quem recebe contra o credor de agora');
select pg_temp.volta();
rollback to savepoint sp_bol;
savepoint sp_bol;
set constraints erp.t_titulo_recebedor immediate;
select pg_temp.sis();
select erp.registrar_pix_conferencia('00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', '77777777000177', 'AGÊNCIA BETA', 'Banco Exemplo', null, 150, (select login_id from erp.usuarios where id = :'diretor'));
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'rascunho do credor trocado') as trasc \gset
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_copia_cola)
values (:'trasc', 1, 'pix', 'email', 'teste@example.com', '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF');
select pg_temp.erro_igual(format($$update erp.titulos set pessoa_id = '10000000-0000-0000-0000-000000000008' where id = %L$$, :'trasc'),
  'Quem recebe pelo PIX copia e cola da parcela 1 não confere com o credor do título (confira o código de novo ou justifique a exceção)',
  'pix copia e cola: trocar o credor depois do código conferido é recusado');
rollback to savepoint sp_bol;
-- mutações da revisão do #108: o valor da parcela que muda depois da forma, o número trocado e o lançamento que troca
-- credor e formas juntos
savepoint sp_bol;
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'AGÊNCIA BETA', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'rascunho do valor trocado') as trasc \gset
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'trasc', 1, 'boleto', '34191090080000000212134567890008899990000015000');
select pg_temp.sis();
update erp.parcelas set valor = 100 where titulo_id = :'trasc';
select pg_temp.erro_igual(format($$select erp._conferir_recebedores(%L)$$, :'trasc'),
  'O beneficiário do boleto da parcela 1 não confere com o credor do título (confira o boleto de novo ou justifique a exceção)',
  'boleto: a parcela que muda de valor depois do boleto conferido não passa na conferência de novo');
select pg_temp.volta();
rollback to savepoint sp_bol;
savepoint sp_bol;
select pg_temp.sis();
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'rascunho do valor trocado') as trasc \gset
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_copia_cola)
values (:'trasc', 1, 'pix', 'email', 'teste@example.com', '00020126390014br.gov.bcb.pix0117teste@example.com5204000053039865406150.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***630485E6');
select pg_temp.sis();
update erp.parcelas set valor = 100 where titulo_id = :'trasc';
select pg_temp.erro_igual(format($$select erp._conferir_recebedores(%L)$$, :'trasc'),
  'Quem recebe pelo PIX copia e cola da parcela 1 não confere com o credor do título (confira o código de novo ou justifique a exceção)',
  'pix copia e cola: a parcela que muda de valor depois do código (campo 54) não passa na conferência de novo');
select pg_temp.volta();
rollback to savepoint sp_bol;
savepoint sp_bol;
select pg_temp.sis();
-- linha sem valor (o banco registra o valor): só a conferência pega a outra parcela
select erp.registrar_boleto_conferencia('34191090080000000212134567890008199990000000000', '77777777000177', 'AGÊNCIA BETA', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'tse', 2, 'boleto', '34191090080000000212134567890008199990000000000');
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set numero = 3 where titulo_id = %L and numero = 2$$, :'tse'),
  'O beneficiário do boleto da parcela 3 não foi conferido (só com a justificativa da exceção)',
  'boleto: trocar o número da parcela confere de novo o boleto contra o valor da outra parcela');
rollback to savepoint sp_bol;
savepoint sp_bol;
select pg_temp.sis();
select erp.registrar_boleto_conferencia('34191090080000000212134567890008899990000015000', '77777777000177', 'AGÊNCIA BETA', 150, null, (select login_id from erp.usuarios where id = :'diretor'));
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  150, array['2026-07-01']::date[], null, null, 'rascunho trocado inteiro') as trasc \gset
select pg_temp.volta();
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha) values (:'trasc', 1, 'boleto', '34191090080000000212134567890008899990000015000');
set constraints erp.t_titulo_recebedor deferred;
update erp.titulos set pessoa_id = '10000000-0000-0000-0000-000000000008' where id = :'trasc';
delete from erp.parcela_pagamentos where titulo_id = :'trasc';
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'trasc', 1, 'pix', 'email', 'conserta@example.com');
set constraints erp.t_titulo_recebedor immediate;
select pg_temp.ok((select pessoa_id = '10000000-0000-0000-0000-000000000008' from erp.titulos where id = :'trasc'),
  'recebedor: o lançamento que troca o credor e as formas juntos passa (a conferência é no fim da transação)');
rollback to savepoint sp_bol;
select pg_temp.ok(not has_function_privilege('anon', 'erp.boleto_conferido(text)', 'EXECUTE') and not has_function_privilege('anon', 'api.recebedores_divergentes()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.registrar_boleto_conferencia(text,text,text,numeric,date,text)', 'EXECUTE')
                  and (select p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_conferencia' from pg_proc p where p.oid = 'erp.tg_parcela_boleto_recebedor()'::regprocedure),
  'boleto: a conferência não é de public nem da API, e o gatilho lê o credor por baixo do RLS');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, boleto_linha, boleto_excecao, pix_copia_cola, pix_copia_cola_excecao)
values (:'tse', 2, 'boleto', '34191090080000000212134567890008899990000015000', 'Cobrança pela financeira do fornecedor', '00020126650014br.gov.bcb.pix2543pix.example.com/qr/v2/cobv/0123456789abcdef5204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***6304BFDF', 'QR dinâmico do banco do boleto');
select pg_temp.ok((select count(*) = 2 from erp.parcela_pagamentos where titulo_id = :'tse'),
  'sienge: antes do primeiro voto, quem lança informa a forma de pagamento de cada parcela');
select pg_temp.ok((select count(*) = 1 from erp.auditoria where tabela = 'parcela_pagamentos' and registro = :'tse' and acao = 'insert' and depois->>'forma' = 'pix'),
  'sienge: a forma de pagamento fica na auditoria');
-- a forma não muda de título (outro título com a parcela 1, ainda em rascunho)
select pg_temp.sis();
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  10, array['2026-07-01']::date[], null, null, 'outro') as touto \gset
select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set titulo_id = %L where titulo_id = %L and numero = 1$$, :'touto', :'tse'),
  'A forma de pagamento não muda de título', 'sienge: a forma de pagamento não passa para outro título');
-- com o título na fila (mesmo sem voto), a forma não muda mais
savepoint sp_fila;
select pg_temp.sis(); insert into erp.sienge_envios (titulo_id) values (:'tse'); select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_chave = 'fraude@example.com' where titulo_id = %L and numero = 1$$, :'tse'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'sienge: com o título na fila do Sienge, quem lançou não troca a chave, mesmo sem voto');
rollback to savepoint sp_fila;
select pg_temp.ok((select p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_conferencia' from pg_proc p
                    where p.oid = 'erp.tg_parcela_pagamento()'::regprocedure),
  'sienge: a trava da forma de pagamento lê aprovações e fila por baixo do RLS (definer de erp_conferencia)');
-- o título que espera a alçada não entra na fila
savepoint sp_enf;
select pg_temp.sis(); select erp.sienge_enfileirar(); select pg_temp.volta();
select pg_temp.ok(not exists (select 1 from erp.sienge_envios where titulo_id = :'tse'), 'sienge: título que espera a alçada não entra na fila');
rollback to savepoint sp_enf;
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$update erp.parcela_pagamentos set pix_chave = 'fraude@example.com' where titulo_id = %L and numero = 1$$, :'tse'),
  'sienge: quem não lança no título não troca a chave');
select pg_temp.como(:'diretor');
select erp.decidir_titulo(:'tse', true) as r_se \gset
select pg_temp.sis();
select pg_temp.ok(:'r_se' = 'aprovado' and erp.titulo_aprovado(:'tse'), 'sienge: o master aprova o título');
select pg_temp.volta();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_chave = 'fraude@example.com' where titulo_id = %L and numero = 1$$, :'tse'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'sienge: depois do voto, nem quem lançou troca a chave PIX');
select pg_temp.erro_igual(format($$delete from erp.parcela_pagamentos where titulo_id = %L$$, :'tse'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'sienge: depois do voto, a forma de pagamento não se apaga');

-- a fila e o pedido são do sistema
select pg_temp.falha($$select erp.sienge_enfileirar()$$, 'sienge: a API não enfileira');
select pg_temp.falha(format($$select erp.sienge_pedido(%L)$$, :'tse'), 'sienge: a API não monta o pedido');
select pg_temp.falha(format($$insert into erp.sienge_envios (titulo_id) values (%L)$$, :'tse'), 'sienge: a API não grava na fila');
-- um papel nosso que passa pela política "operacao" e tem EXECUTE: a função e o gatilho recusam sozinhos
select pg_temp.como(null);
select set_config('role', 'erp_situacao', false);
select pg_temp.erro_igual($$select erp.sienge_enfileirar()$$, 'Só o sistema enfileira o envio ao Sienge', 'sienge: fora do sistema, enfileirar é recusado pela própria função');
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse'), 'Só o sistema monta o envio ao Sienge', 'sienge: fora do sistema, o pedido é recusado pela própria função');
select pg_temp.erro_igual(format($$select erp.sienge_registrar(%L, 1)$$, :'tse'), 'Só o sistema registra o envio ao Sienge', 'sienge: fora do sistema, registrar é recusado pela própria função');
select pg_temp.erro_igual(format($$insert into erp.sienge_envios (titulo_id) values (%L)$$, :'tse'), 'A fila do Sienge só é escrita pelo sistema',
  'sienge: o gatilho da fila recusa quem não é o sistema, mesmo com a política aberta');
select pg_temp.erro_igual(format($$insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (%L, %L, '1')$$, pg_temp.nat('04.01'), :'cc_obra'),
  'O de-para do Sienge muda pelo pedido (erp.pedir_mudanca_config)', 'sienge: o gatilho do de-para recusa sozinho quem não é master');
select pg_temp.como(null);
select pg_temp.ok((select bool_and(coalesce(with_check, qual, '') = 'erp.sou_master()' and coalesce(qual, 'erp.sou_master()') = 'erp.sou_master()')
                          and count(*) = 6 from pg_policies
                    where schemaname = 'erp' and tablename in ('sienge_centros','sienge_contas')
                      and policyname in ('perfil_inclui','perfil_altera','perfil_apaga')),
  'sienge: pela API, a política do de-para só deixa o master gravar');
select pg_temp.como(:'analista');
select pg_temp.falha(format($$insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (%L, %L, '1')$$, pg_temp.nat('04.01'), :'cc_obra'),
  'sienge: quem não é master não grava o de-para direto');
select pg_temp.como(null);
select erp.sienge_enfileirar() as n_fila \gset
select pg_temp.ok(:n_fila >= 1 and exists (select 1 from erp.sienge_envios where titulo_id = :'tse' and situacao = 'pendente'),
  'sienge: o título aprovado entra na fila');
select pg_temp.ok((select count(*) = 1 and bool_and(e.dados->'parcelas' = '[{"numero": 1, "pix_tipo": "email", "pix_chave": "teste@example.com"}]'
                                                    and e.centro_id = :'cc_mkt')
                     from erp.eventos e where e.tipo = 'chave_pix_nova' and e.registro = :'tse')
                  and exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                               where e.tipo = 'chave_pix_nova' and e.registro = :'tse' and n.critico and n.user_id = :'diretor')
                  and (select critico from erp.tipos_evento where codigo = 'chave_pix_nova')
                  and exists (select 1 from erp.regras_notificacao where tipo = 'chave_pix_nova' and destino = 'lista' and lista = 'AF' and ativa),
  'S-125: título com chave PIX nunca usada com o credor gera o alerta crítico, para o master e a AF, só da chave nova');
select pg_temp.ok((select count(*) = 1 and bool_and(e.dados->'parcelas'->0->>'numero' = '2'
                                                    and e.dados->'parcelas'->0->'recebedor'->>'url' = 'pix.example.com/qr/v2/cobv/0123456789abcdef'
                                                    and e.dados->'parcelas'->0->>'justificativa' = 'QR dinâmico do banco do boleto')
                     from erp.eventos e where e.tipo = 'pix_copia_cola_excecao' and e.registro = :'tse')
                  and exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                               where e.tipo = 'pix_copia_cola_excecao' and e.registro = :'tse' and n.critico and n.user_id = :'diretor'),
  'pix copia e cola: título com recebedor não conferido gera o alerta crítico ao ir para a fila do Sienge');
select pg_temp.ok((select count(*) = 1 and bool_and(e.dados->'parcelas'->0->>'numero' = '2'
                                                    and e.dados->'parcelas'->0->'conferido'->>'cpf_cnpj' = '29732041000154'
                                                    and e.dados->'parcelas'->0->>'justificativa' = 'Cobrança pela financeira do fornecedor')
                     from erp.eventos e where e.tipo = 'boleto_excecao' and e.registro = :'tse')
                  and exists (select 1 from erp.notificacoes n join erp.eventos e on e.id = n.evento_id
                               where e.tipo = 'boleto_excecao' and e.registro = :'tse' and n.critico and n.user_id = :'diretor'),
  'boleto: título com beneficiário que não é o credor gera o alerta crítico ao ir para a fila do Sienge');
select pg_temp.ok((select p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_conferencia' from pg_proc p
                    where p.oid = 'erp.tg_parcela_pix_copia_cola()'::regprocedure)
                  and not has_schema_privilege('erp_conferencia', 'erp', 'create'),
  'pix copia e cola: a conferência do recebedor lê o credor por baixo do RLS (definer de erp_conferencia), sem CREATE no esquema');
select pg_temp.ok(erp.sienge_enfileirar() = 0, 'sienge: enfileirar de novo não repete');
select pg_temp.ok(not exists (select 1 from erp.sienge_envios e join erp.titulos t on t.id = e.titulo_id
                               where t.tipo not in ('fornecedor','avulso') or not erp.titulo_aprovado(t.id)),
  'sienge: só título de fornecedor ou avulso aprovado entra na fila (imposto e o que espera a alçada, não)');
select pg_temp.erro_igual(format($$update erp.sienge_envios set titulo_id = %L where titulo_id = %L$$, :'touto', :'tse'),
  'Título e data da fila não mudam', 'sienge: a linha da fila não troca de título');
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse'), 'A empresa do título não tem código no Sienge',
  'sienge: sem o código da empresa, o pedido é recusado');
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values
  ('sienge', 'empresas', :'spe', '11'), ('sienge', 'pessoas', '10000000-0000-0000-0000-000000000007', '823');
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse'),
  'De-para do Sienge incompleto: núcleo + centro sem centro de custo do Sienge',
  'sienge: sem o de-para, o pedido diz o que falta');
insert into erp.sienge_centros (nucleo_economico_id, centro_custo_id, sienge_centro) values (:'ne_vm', :'cc_mkt', 100), (:'ne_vm', :'cc_obra', 100);
insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values
  (pg_temp.nat('05.01.04'), :'cc_mkt', '2030224'), (pg_temp.nat('04.01'), :'cc_obra', '2010101');
select pg_temp.ok((select count(*) = 4 from erp.eventos where tipo = 'codigo_externo_alterado' and tabela in ('sienge_centros','sienge_contas')),
  'sienge: cada linha do de-para vira evento crítico de código externo');
select erp.sienge_pedido(:'tse') as ped \gset
select pg_temp.ok((:'ped'::jsonb->'titulo'->>'debtorId')::int = 11 and (:'ped'::jsonb->'titulo'->>'creditorId')::int = 823
                  and :'ped'::jsonb->'titulo'->>'documentIdentificationId' = 'NFSE' and :'ped'::jsonb->'titulo'->>'documentNumber' = '9001'
                  and (:'ped'::jsonb->'titulo'->>'totalInvoiceAmount')::numeric = 300 and (:'ped'::jsonb->'titulo'->>'installmentsNumber')::int = 2
                  and :'ped'::jsonb->'titulo'->>'dueDate' = '2026-06-20' and :'ped'::jsonb->'titulo'->>'billDate' = '2026-06-01'
                  and :'ped'::jsonb->'titulo'->>'baseDate' = (select emissao::text from erp.titulos where id = :'tse')
                  and :'ped'::jsonb->'titulo'->>'notes' like 'ERP ' || :'tse' || '%',
  'sienge: o corpo do título leva empresa, credor, documento, valor, parcelas, vencimento, a competência em billDate, a emissão como data base e o marcador do ERP');
select pg_temp.ok((select sum((x->>'percentage')::numeric) = 100 and count(*) = 2 and bool_and(x->>'percentage' ~ '^[0-9]+(\.[0-9]{1,2})?$')
                     from jsonb_array_elements(:'ped'::jsonb->'titulo'->'budgetCategories') x),
  'sienge: o rateio vai em centro e conta do Sienge, com 2 casas e somando 100');
select pg_temp.ok((select jsonb_agg(x->>'forma' order by (x->>'numero')::int) = '["pix","boleto"]'
                          and (array_agg((x->>'boleto_tipo')::int) filter (where x->>'forma' = 'boleto'))[1] = 2
                     from jsonb_array_elements(:'ped'::jsonb->'parcelas') x),
  'sienge: cada parcela leva a forma de pagamento; boleto de banco sem conta da empresa é "outros bancos"');
-- o pedido confere de novo o boleto (a parcela pode mudar na revisão) e a forma que falta
savepoint sp_ped;
alter table erp.parcela_pagamentos disable trigger t_parcela_pagamento;
alter table erp.parcela_pagamentos disable trigger t_parcela_recebedor_boleto;
update erp.parcela_pagamentos set boleto_linha = '34191090080000000212134567890008799990000000100' where titulo_id = :'tse' and numero = 2;
alter table erp.parcela_pagamentos enable trigger t_parcela_pagamento;
alter table erp.parcela_pagamentos enable trigger t_parcela_recebedor_boleto;
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse'), 'O valor do boleto (1.00) não é o da parcela 2 (150.00)',
  'S-125: o pedido confere de novo o valor do boleto com a parcela');
rollback to savepoint sp_ped;
savepoint sp_ped;
alter table erp.parcela_pagamentos disable trigger t_parcela_pagamento;
delete from erp.parcela_pagamentos where titulo_id = :'tse' and numero = 2;
alter table erp.parcela_pagamentos enable trigger t_parcela_pagamento;
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse'), 'Falta a forma de pagamento da parcela 2',
  'sienge: parcela sem forma de pagamento não vai ao Sienge');
rollback to savepoint sp_ped;
-- percentuais que arredondam para 100,01: o resto sai da maior linha
savepoint sp_ped;
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000000e2', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9002', '2026-06-02', '2026-06-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000e2', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50.005),
  ('70000000-0000-0000-0000-0000000000e2', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 49.995);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000e2', array['2026-06-20']::date[]) as tse2 \gset
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'tse2', 1, 'pix', 'email', 'teste@example.com');
select erp.decidir_titulo(:'tse2', true);
select pg_temp.como(null);
select erp.sienge_pedido(:'tse2') as ped2 \gset
select pg_temp.ok((select sum((x->>'percentage')::numeric) = 100 and array_agg((x->>'percentage')::numeric order by (x->>'percentage')::numeric) = array[50.00, 50.00]
                     from jsonb_array_elements(:'ped2'::jsonb->'titulo'->'budgetCategories') x),
  'sienge: 50,01 + 50,00 arredondados viram 50,00 + 50,00 (o resto sai da maior linha)');
rollback to savepoint sp_ped;
-- nota com retenção ainda não vai ao Sienge
savepoint sp_ped;
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000000e3', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9003', '2026-06-02', '2026-06-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000e3', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
values ('70000000-0000-0000-0000-0000000000e3', 'iss', 5, '10000000-0000-0000-0000-000000000006', '2026-07-10');
select erp.lancar_documento('70000000-0000-0000-0000-0000000000e3', array['2026-06-20']::date[]) as tse3 \gset
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'tse3', 1, 'pix', 'email', 'teste@example.com');
select erp.decidir_titulo(:'tse3', true);
select pg_temp.como(null);
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tse3'), 'Nota com retenção de imposto ou caução ainda não vai ao Sienge pelo adaptador',
  'sienge: nota com retenção fica de fora do envio');
rollback to savepoint sp_ped;
-- o título já ligado a outro título do Sienge não é registrado com outro id
savepoint sp_ped;
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'titulos', :'tse', '5555');
select pg_temp.erro_igual(format($$select erp.sienge_registrar(%L, 9001)$$, :'tse'), 'O título já está ligado a outro título do Sienge',
  'sienge: registrar não liga o título a um segundo id do Sienge');
rollback to savepoint sp_ped;
-- na fila, sem id do Sienge ainda, a chave não conta como usada
savepoint sp_fila2;
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'touto', 1, 'pix', 'email', 'teste@example.com');
select pg_temp.ok((select 'Chave nova para este credor' = any (avisos) from erp.avisos_forma_pagamento(:'touto') where numero = 1),
  'S-125: a chave de título que ainda não chegou ao Sienge continua nova');
rollback to savepoint sp_fila2;
select erp.sienge_registrar(:'tse', 9001);
select pg_temp.ok((select codigo = '9001' from erp.codigos_externos where sistema = 'sienge' and tabela = 'titulos' and registro_id = :'tse')
                  and (select sienge_id = 9001 and passo = 'criado' from erp.sienge_envios where titulo_id = :'tse'),
  'sienge: o id do Sienge fica na fila e nos códigos externos');
select pg_temp.erro_igual(format($$select erp.sienge_registrar(%L, 9002)$$, :'tse'), 'O título já tem id no Sienge (9001); não troca',
  'sienge: o id do Sienge não se troca');
select pg_temp.erro_igual(format($$delete from erp.sienge_envios where titulo_id = %L$$, :'tse'), 'A fila do Sienge não se apaga',
  'sienge: a fila não se apaga');
-- a chave do título que já foi ao Sienge deixa de ser nova para o credor
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'touto', 1, 'pix', 'email', 'teste@example.com');
select pg_temp.ok((select avisos = array['A chave não é do documento do credor'] from erp.avisos_forma_pagamento(:'touto') where numero = 1)
                  and (select avisos = array['A chave não é do documento do credor', 'Chave nova para este credor']
                         from erp.avisos_forma_pagamento(:'tse') where numero = 1),
  'S-125: a chave usada em outro título do credor já enviado ao Sienge não é mais nova (o próprio título não conta)');
-- o alerta lista só a chave nova: a já usada com o credor fica de fora
savepoint sp_ped;
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000000e4', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9004', '2026-06-02', '2026-06-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000e4', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000e4', array['2026-06-20','2026-07-20']::date[]) as tse4 \gset
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values
  (:'tse4', 1, 'pix', 'email', 'teste@example.com');
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, pix_excecao) values
  (:'tse4', 2, 'pix', 'cpf_cnpj', '29732041000154', 'Cessão de crédito');
select erp.decidir_titulo(:'tse4', true);
select pg_temp.como(null);
select erp.sienge_enfileirar();
select pg_temp.ok((select dados->'parcelas' = '[{"numero": 2, "pix_tipo": "cpf_cnpj", "pix_chave": "29732041000154"}]'
                     from erp.eventos where tipo = 'chave_pix_nova' and registro = :'tse4'),
  'S-125: o alerta lista só a chave nova do título');
select pg_temp.ok((select x->>'pix_chave' = '29732041000154' from jsonb_array_elements(erp.sienge_pedido(:'tse4')->'parcelas') x
                    where (x->>'numero')::int = 2),
  'S-127: a exceção justificada vai até o pedido ao Sienge');
-- a mesma chave, já enviada para outro credor, continua nova para este (S-127)
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000006', null, null, '2026-06-02', '2026-06-01',
  10, array['2026-07-01']::date[], null, null, 'outro credor') as toutro \gset
insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave) values (:'toutro', 1, 'pix', 'email', 'teste@example.com');
select pg_temp.ok((select 'Chave nova para este credor' = any (avisos) from erp.avisos_forma_pagamento(:'toutro') where numero = 1),
  'S-127: a chave usada com outro credor é nova para este');
rollback to savepoint sp_ped;
select pg_temp.como(:'leitor');
select pg_temp.ok((select count(*) = 2 from erp.avisos_forma_pagamento(:'tse')), 'S-125: quem vê o título vê os avisos');
select pg_temp.como('00000000-0000-0000-0000-0000000000ff');   -- login sem cadastro no ERP: não vê o título
select pg_temp.ok(not exists (select 1 from erp.avisos_forma_pagamento(:'tse')), 'S-125: os avisos só respondem sobre título que a pessoa vê');
select pg_temp.como(null);
select pg_temp.erro_igual(format($$select erp.sienge_pedido(%L)$$, :'tit'), 'O título não está aprovado',
  'sienge: título que espera a alçada não monta pedido');
select erp._criar_titulo(:'spe', 'pagar', 'avulso', '10000000-0000-0000-0000-000000000007', null, null, '2026-06-02', '2026-06-01',
  1, array['2026-07-01','2026-08-01','2026-09-01']::date[], null, null, 'arredondamento') as tarr \gset
select pg_temp.ok((select array_agg(valor order by numero) = array[0.34, 0.33, 0.33]::numeric[] from erp.parcelas where titulo_id = :'tarr'),
  'sienge: o centavo que sobra fica na primeira parcela, como no Sienge');
rollback;


-- ---------------------------------------------------------------------
\echo '# aprovação do contrato recorrente e da previsão'
begin;
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing;
select pg_temp.volta();

-- contrato recorrente: gestor do centro + AF ou AD (Moises, 23/11/2026; antes AF ou AO); quem lançou não aprova
select pg_temp.como(:'analista');
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, valor_periodo, dia_vencimento)
values ('61000000-0000-0000-0000-0000000000a1', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Assinatura de teste',
        '2026-06-01', 'mensal', 200, 10);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('61000000-0000-0000-0000-0000000000a1', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.sis();
select erp.gerar_previsoes_assinatura('61000000-0000-0000-0000-0000000000a1', '2026-07-31');
select pg_temp.ok(not erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1'), 'contrato: a assinatura nasce esperando aprovação');
select pg_temp.ok((select count(*) = 2 and bool_and(not erp.previsao_aprovada(id)) from erp.previsoes where compromisso_id = '61000000-0000-0000-0000-0000000000a1')
                  and not exists (select 1 from erp.previsao_alcadas a join erp.previsoes p on p.id = a.previsao_id
                                   where p.compromisso_id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: as previsões da assinatura não têm alçada própria e esperam o contrato');
select (select aprovacao_versao from erp.compromissos where id = '61000000-0000-0000-0000-0000000000a1') as v1 \gset
select pg_temp.volta();
select pg_temp.ok(not has_function_privilege('authenticated', 'erp.compromisso_aprovado(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.previsao_aprovada(uuid)', 'EXECUTE'),
  'contrato: as conferências de aprovação não são executáveis pela API (respondem sobre qualquer id)');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'Quem lançou ou alterou o contrato não aprova', 'contrato: quem lançou não aprova');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'Seu papel só permite consulta', 'contrato: leitura não aprova');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'A aprovação deste contrato é do gestor de cada centro e da AF ou da AD', 'contrato: quem não é gestor do centro nem AF/AD não aprova');
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AO', :'analista2'); select pg_temp.volta();
select pg_temp.como(:'analista2');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'A aprovação deste contrato é do gestor de cada centro e da AF ou da AD', 'contrato: a AO não aprova o cadastro (Moises, 23/11/2026)');
select pg_temp.sis(); delete from erp.listas_financeiro where lista = 'AO' and user_id = :'analista2'; select pg_temp.volta();
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true) = 'pendente', 'contrato: o gestor do centro aprova a vaga dele');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'Você já aprovou este contrato', 'contrato: uma vaga por pessoa');
select pg_temp.erro_igual($$insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, aprovado, por)
                            values ('61000000-0000-0000-0000-0000000000a1', 1, 'FIN', true, '00000000-0000-0000-0000-00000000000e')$$,
  'O contrato só se aprova por erp.decidir_compromisso', 'contrato: a aprovação não se grava direto');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', false)$$,
  'Recusar exige justificativa', 'contrato: recusar exige justificativa');
select pg_temp.ok(erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'contrato: a AF completa a aprovação');
select pg_temp.sis();
select pg_temp.ok(erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1')
                  and (select bool_and(erp.previsao_aprovada(id)) from erp.previsoes where compromisso_id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: aprovado o contrato, as previsões dele ficam aprovadas');
select pg_temp.volta();

-- mudou o que pede aprovação: versão nova, aprovação de novo, e quem mudou não aprova
select pg_temp.como(:'gestor');
update erp.compromissos set valor_periodo = 250 where id = '61000000-0000-0000-0000-0000000000a1';
select pg_temp.sis();
select pg_temp.ok((select aprovacao_versao = :v1 + 1 and alterado_por = :'gestor' from erp.compromissos where id = '61000000-0000-0000-0000-0000000000a1')
                  and not erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1')
                  and (select bool_and(not erp.previsao_aprovada(id)) from erp.previsoes where compromisso_id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: mudar o valor abre versão nova; o contrato e as previsões voltam a esperar');
update erp.compromissos set descricao = 'Assinatura de teste (nome)' where id = '61000000-0000-0000-0000-0000000000a1';
select pg_temp.ok((select aprovacao_versao = :v1 + 1 from erp.compromissos where id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: mudar só a descrição não pede aprovação de novo');
select pg_temp.volta();
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'Quem lançou ou alterou o contrato não aprova', 'contrato: quem alterou não aprova a alteração');
select pg_temp.erro_igual($$update erp.compromissos set aprovacao_versao = 1 where id = '61000000-0000-0000-0000-0000000000a1'$$,
  'A versão da aprovação do contrato só muda pela alteração do contrato', 'contrato: a versão não se põe à mão');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'Quem lançou ou alterou o contrato não aprova', 'contrato: quem lançou continua sem aprovar nas versões seguintes');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', false, 'valor acima do combinado') = 'recusado',
  'contrato: a AF recusa com justificativa');
select pg_temp.erro_igual($$select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true)$$,
  'O contrato foi recusado; mude o contrato para pedir a aprovação de novo', 'contrato: recusado fica recusado até mudar');
-- o rateio também abre versão nova (menos a natureza, que muda pela reclassificação)
select pg_temp.como(:'analista');
update erp.compromisso_rateios set percentual = 100 where compromisso_id = '61000000-0000-0000-0000-0000000000a1';
select pg_temp.sis();
select pg_temp.ok((select aprovacao_versao = :v1 + 1 from erp.compromissos where id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: gravar o rateio sem mudar nada não abre versão');
select pg_temp.volta();
update erp.compromisso_rateios set nucleo_economico_id = :'ne_vm', percentual = 100.0000, centro_custo_id = :'cc_mkt'
 where compromisso_id = '61000000-0000-0000-0000-0000000000a1';
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('61000000-0000-0000-0000-0000000000a1', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50);
update erp.compromisso_rateios set percentual = 50 where compromisso_id = '61000000-0000-0000-0000-0000000000a1' and centro_custo_id = :'cc_mkt';
select pg_temp.sis();
select pg_temp.ok((select aprovacao_versao = :v1 + 3 and alterado_por = :'analista' from erp.compromissos where id = '61000000-0000-0000-0000-0000000000a1'),
  'contrato: incluir ou mudar linha do rateio abre versão nova');
select pg_temp.volta();
select pg_temp.sis(); insert into erp.listas_financeiro (lista, user_id) values ('AD', :'diretor2') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'diretor2');
select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true) as r_ad \gset
select pg_temp.sis();
select pg_temp.ok(:'r_ad' = 'pendente'
                  and exists (select 1 from erp.compromisso_aprovacoes where compromisso_id = '61000000-0000-0000-0000-0000000000a1'
                                and versao = :v1 + 3 and vaga = 'FIN' and por = :'diretor2'),
  'contrato: a AD aprova a vaga do financeiro do cadastro (Moises, 23/11/2026)');
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_compromisso('61000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'contrato: o master aprova todas as vagas de uma vez');
select pg_temp.sis();
select pg_temp.ok(erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1'), 'contrato: aprovado pelo master');
select pg_temp.volta();

-- previsão lançada à mão: alçada de pagamento do centro
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor, descricao)
values ('68000000-0000-0000-0000-0000000000a1', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-09-01', '2026-09-20', 1000, 'Feira');
select pg_temp.sis();
select pg_temp.ok((select fases = '{AREA,AF}' from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000a1' and divisao_id is null)
                  and not erp.previsao_aprovada('68000000-0000-0000-0000-0000000000a1'),
  'previsão: a lançada à mão ganha a alçada do centro e espera');
select acumulado as acum1 from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000a1' \gset
select pg_temp.volta();
select pg_temp.erro_igual($$select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true)$$,
  'Quem lançou não aprova o próprio lançamento', 'previsão: quem lançou não aprova');
select pg_temp.erro_igual($$insert into erp.previsao_aprovacoes (alcada_id, previsao_id, fase, lista, aprovado, por)
                            select id, previsao_id, 1, 'AREA', true, '00000000-0000-0000-0000-00000000000e' from erp.previsao_alcadas
                             where previsao_id = '68000000-0000-0000-0000-0000000000a1'$$,
  'A alçada da previsão só é escrita pelo banco', 'previsão: a aprovação não se grava direto');
select pg_temp.como(:'contador');
select pg_temp.erro_igual($$select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true)$$,
  'Esta fase de aprovação é de quem está em AREA', 'previsão: em sequência, a AF espera o gestor');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true) = 'pendente', 'previsão: o gestor aprova a fase dele');
select pg_temp.erro_igual($$select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true)$$,
  'Você já aprovou uma fase de aprovação desta previsão', 'previsão: cada pessoa aprova uma fase só');
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'previsão: a AF completa');
select pg_temp.sis();
select pg_temp.ok(erp.previsao_aprovada('68000000-0000-0000-0000-0000000000a1'), 'previsão: aprovada');
select pg_temp.volta();
-- nada é aprovado sem aprovador (Moises, 18/11/2026): centro sem gestor e sem faixas próprias não aprova sozinho
savepoint sem_aprovador;
select pg_temp.sis();
select c.id as cc_sem from erp.centros_custo c join erp.nucleo_centros nc on nc.centro_custo_id = c.id and nc.nucleo_economico_id = :'ne_vm'
 where not exists (select 1 from erp.centro_aprovadores a where a.centro_custo_id = c.id)
   and not exists (select 1 from erp.alcadas_pagamento ap where ap.centro_custo_id = c.id)
   and not exists (select 1 from erp.divisoes d where d.centro_custo_id = c.id)
 order by c.id limit 1 \gset
select pg_temp.como_dono(:'analista');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor, descricao)
values ('68000000-0000-0000-0000-0000000000f1', :'spe', 'manual', :'ne_vm', :'cc_sem', pg_temp.nat('05.01.04'), '2026-09-01', '2026-09-20', 100, 'Sem gestor');
select pg_temp.sis();
select pg_temp.ok((select falta_aprovadores and 'AREA' = any (vagas_sem_gente) from erp.previsao_alcadas
                    where previsao_id = '68000000-0000-0000-0000-0000000000f1' and centro_custo_id = :'cc_sem' and divisao_id is null)
                  and not erp.previsao_aprovada('68000000-0000-0000-0000-0000000000f1')
                  and exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = '68000000-0000-0000-0000-0000000000f1'),
  'previsão: centro sem gestor e sem faixas próprias não nasce aprovada; vai ao master, com o aviso');
select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000f1', true) = 'aprovado', 'previsão: o master aprova a do centro sem gestor');
select pg_temp.sis();
select pg_temp.ok(erp.previsao_aprovada('68000000-0000-0000-0000-0000000000f1'), 'previsão: do centro sem gestor, aprovada só pelo master');
select pg_temp.volta();
rollback to savepoint sem_aprovador;
select pg_temp.erro_igual($$select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a1', true)$$,
  'A previsão já foi aprovada', 'previsão: aprovada não se decide de novo');

-- acumulado: a aprovada conta no mês dela
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-0000000000a2', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-09-01', '2026-09-25', 500);
select pg_temp.sis();
select pg_temp.ok((select acumulado = :acum1 + 500 from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000a2' and divisao_id is null),
  'previsão: o acumulado da previsão nova soma a aprovada do mês');
select pg_temp.volta();
-- S-129: a que espera também conta; dividir em duas não baixa a faixa (Moises, 17/11/2026)
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-0000000000c1', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2027-01-01', '2027-01-10', 30000);
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-0000000000c2', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2027-01-01', '2027-01-20', 30000);
select pg_temp.sis();
select acumulado as acum_c1, fases as fases_c1 from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000c1' and divisao_id is null \gset
select acumulado as acum_c2, fases as fases_c2 from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000c2' and divisao_id is null \gset
select pg_temp.ok(not erp.previsao_aprovada('68000000-0000-0000-0000-0000000000c1') and :acum_c2 = :acum_c1 + 30000,
  'previsão: a segunda previsão do mês soma a primeira, que ainda espera aprovação');
select pg_temp.ok(:'fases_c1' = '{AREA,AF}' and :'fases_c2' = '{AREA,AF,AD}',
  'previsão: com a soma acima de 50 mil, a segunda pega a faixa da soma (gestor, AF e AD)');
select pg_temp.volta();
-- a nota que consome a previsão que espera conta só o que passa do saldo dela
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000000f5', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9105', '2027-01-05', '2027-01-01', 30000);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000f5', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000f5', array['2027-01-20']::date[],
                            array['68000000-0000-0000-0000-0000000000c1']::uuid[]) as tf5 \gset
select pg_temp.sis();
select acumulado as acum_f5 from erp.titulo_alcadas where titulo_id = :'tf5' and divisao_id is null \gset
select pg_temp.ok(:acum_f5 = :acum_c2, 'previsão: a nota que consome a que espera não conta duas vezes');
select pg_temp.volta();
-- recusa cancela a previsão
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a2', false)$$,
  'Recusar exige justificativa', 'previsão: recusar exige justificativa');
select erp.decidir_previsao('68000000-0000-0000-0000-0000000000a2', false, 'sem verba') as r_prev \gset
select pg_temp.ok(:'r_prev' = 'recusado'
                  and (select situacao = 'cancelada' from erp.previsoes where id = '68000000-0000-0000-0000-0000000000a2'),
  'previsão: recusada é cancelada');
-- o master aprova tudo de uma vez, inclusive a que lançou
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-0000000000a3', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-10-01', '2026-10-25', 300);
select pg_temp.ok(erp.decidir_previsao('68000000-0000-0000-0000-0000000000a3', true) = 'aprovado', 'previsão: o master aprova todas as fases, mesmo a dele');

-- o título do mês soma a previsão aprovada; a nota que consome a previsão conta só o que passa do saldo
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000000f1', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9101', '2026-09-02', '2026-09-01', 100),
  ('70000000-0000-0000-0000-0000000000f2', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9102', '2026-09-03', '2026-09-01', 400);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000f1', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100),
  ('70000000-0000-0000-0000-0000000000f2', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000f1', array['2026-09-20']::date[]) as tf1 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000000f2', array['2026-09-20']::date[],
                            array['68000000-0000-0000-0000-0000000000a1']::uuid[]) as tf2 \gset
select pg_temp.sis();
select acumulado as acum_f1 from erp.titulo_alcadas where titulo_id = :'tf1' and divisao_id is null \gset
select acumulado as acum_f2 from erp.titulo_alcadas where titulo_id = :'tf2' and divisao_id is null \gset
select pg_temp.ok(:acum_f1 = :acum1 + 100, 'previsão: o acumulado do título soma a previsão aprovada do mês');
select pg_temp.ok(:acum_f2 = :acum_f1 + 400 - 400, 'previsão: a nota que consome a previsão não conta duas vezes (só o saldo que sobra)');
select pg_temp.volta();

-- só a rotina grava as origens que valem aprovação sem alçada
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'assinatura', '61000000-0000-0000-0000-0000000000a1', %L, %L, %L, '2026-11-01', '2026-11-10', 99999)$$, :'spe', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'A previsão de origem assinatura nasce da rotina (contrato ou saldo), não à mão', 'previsão: ninguém lança à mão a origem do contrato');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, origem_previsao_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'saldo_previsao', '68000000-0000-0000-0000-0000000000a1', %L, %L, %L, '2026-11-01', '2026-11-10', 99999)$$, :'spe', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04')),
  'A previsão de origem saldo_previsao nasce da rotina (contrato ou saldo), não à mão', 'previsão: ninguém lança à mão o saldo de outra previsão');
insert into erp.previsoes (id, empresa_id, origem, compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('68000000-0000-0000-0000-0000000000a4', :'spe', 'manual', '61000000-0000-0000-0000-0000000000a1', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-11-01', '2026-11-10', 700);
select pg_temp.sis();
select pg_temp.ok(erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1') and not erp.previsao_aprovada('68000000-0000-0000-0000-0000000000a4')
                  and exists (select 1 from erp.previsao_alcadas where previsao_id = '68000000-0000-0000-0000-0000000000a4'),
  'previsão: a lançada à mão ao lado de um contrato aprovado passa pela alçada (não pega a aprovação do contrato)');
select pg_temp.volta();
select pg_temp.como(:'leitor');
select pg_temp.falha($$select erp.gerar_previsoes_assinatura('61000000-0000-0000-0000-0000000000a1', '2026-12-31')$$,
  'previsão: quem não lança no contrato não gera as previsões dele');

-- saldo × saving: a nota (400) veio menor que a previsão (1000)
select pg_temp.como(:'analista');
select pg_temp.ok((select saldo = 600 from erp.v_previsoes_a_decidir where id = '68000000-0000-0000-0000-0000000000a1'),
  'previsão: a consumida em parte aparece para decidir, com o saldo');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saving')$$,
  'Seu papel só permite consulta', 'saldo: leitura não encerra');
savepoint sp_lanca;
select pg_temp.sis();
update erp.perfil_centros set nivel = 'leitor' where perfil_id = :'tudo' and centro_custo_id = :'cc_mkt';
select pg_temp.como(:'analista');
select pg_temp.ok(erp.vejo_previsao('68000000-0000-0000-0000-0000000000a1'), 'saldo: (o analista ainda vê a previsão)');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saving')$$,
  'Você não lança nesta previsão', 'saldo: quem vê mas não lança no centro não encerra');
rollback to savepoint sp_lanca;
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saldo')$$,
  'Informe a data em que o saldo será pago', 'saldo: o saldo pede a data');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saldo', '2020-01-01')$$,
  'A data do saldo já passou', 'saldo: a data não fica no passado');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saving', '2030-01-01')$$,
  'Saving não tem data', 'saving: sem data');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'outro')$$,
  'Destino é saldo ou saving', 'saldo: só os dois destinos');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a3', 'saving')$$,
  'A previsão ainda não foi consumida por nenhuma nota; para desistir, cancele', 'saving: só previsão consumida em parte');
savepoint sp_saving;
select pg_temp.como(:'analista');
select pg_temp.ok(erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saving') is null, 'saving: não cria outra previsão');
select pg_temp.sis();
select pg_temp.ok((select situacao = 'encerrada' from erp.previsoes where id = '68000000-0000-0000-0000-0000000000a1')
                  and (select sum(valor) = 0 from erp.lancamentos where previsao_id = '68000000-0000-0000-0000-0000000000a1' and estagio = 'previsto')
                  and not exists (select 1 from erp.previsoes where origem_previsao_id = '68000000-0000-0000-0000-0000000000a1'),
  'saving: a previsão é encerrada e o saldo sai do previsto');
rollback to savepoint sp_saving;
select pg_temp.como(:'analista');
select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saldo', '2030-03-15') as psaldo \gset
select pg_temp.sis();
select pg_temp.ok((select situacao = 'encerrada' from erp.previsoes where id = '68000000-0000-0000-0000-0000000000a1')
                  and (select valor = 600 and origem = 'saldo_previsao' and situacao = 'aberta' and competencia = '2030-03-01' and data_prevista = '2030-03-15'
                         from erp.previsoes where id = :'psaldo' and origem_previsao_id = '68000000-0000-0000-0000-0000000000a1')
                  and erp.previsao_aprovada(:'psaldo')
                  and not exists (select 1 from erp.previsao_alcadas where previsao_id = :'psaldo'),
  'saldo: encerra a original e nasce a previsão do saldo na data informada, aprovada como a original e sem alçada própria');
select pg_temp.volta();
select pg_temp.erro_igual(format($$select erp.decidir_previsao(%L, true)$$, :'psaldo'),
  'O saldo segue a aprovação da previsão original', 'saldo: não se decide à parte');
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a1', 'saving')$$,
  'Só previsão aberta se encerra', 'saldo: encerrada não se encerra de novo');
-- a original sem aprovação não vira saldo; o saldo perde a aprovação quando a original perde
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000000f3', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', '9103', '2026-11-03', '2026-11-01', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000000f3', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000000f3', array['2026-11-20']::date[],
                            array['68000000-0000-0000-0000-0000000000a4']::uuid[]);
select pg_temp.sis();
select pg_temp.ok(not erp.previsao_aprovada('68000000-0000-0000-0000-0000000000a4')
                  and erp._previsao_saldo('68000000-0000-0000-0000-0000000000a4') > 0,
  'saldo: (a4 consumida em parte e sem aprovação)');
select pg_temp.volta();
select pg_temp.erro_igual($$select erp.encerrar_previsao('68000000-0000-0000-0000-0000000000a4', 'saldo', '2030-03-15')$$,
  'A previsão original não está aprovada; lance o saldo como previsão nova', 'saldo: a original sem aprovação não vira saldo');
select pg_temp.sis();
select id as pcontr from erp.previsoes where compromisso_id = '61000000-0000-0000-0000-0000000000a1' and origem = 'assinatura'
 order by data_prevista limit 1 \gset
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
select '70000000-0000-0000-0000-0000000000f4', p.empresa_id, p.pessoa_id, 'nfse', '9104', p.competencia, p.competencia, 1
  from erp.previsoes p where p.id = :'pcontr';
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
select '70000000-0000-0000-0000-0000000000f4', p.nucleo_economico_id, p.centro_custo_id, p.natureza_id, 100 from erp.previsoes p where p.id = :'pcontr';
select erp.lancar_documento('70000000-0000-0000-0000-0000000000f4', array[(select data_prevista from erp.previsoes where id = :'pcontr')]::date[],
                            array[:'pcontr']::uuid[]);
select erp.encerrar_previsao(:'pcontr', 'saldo', '2030-04-15') as psaldo2 \gset
select pg_temp.sis();
select pg_temp.ok(erp.previsao_aprovada(:'psaldo2'), 'saldo: o saldo da previsão do contrato aprovado nasce aprovado');
select pg_temp.volta();
select pg_temp.como(:'gestor');
update erp.compromissos set valor_periodo = valor_periodo + 1 where id = '61000000-0000-0000-0000-0000000000a1';
select pg_temp.sis();
select pg_temp.ok(not erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000a1') and not erp.previsao_aprovada(:'psaldo2'),
  'saldo: o contrato voltou a esperar aprovação, e o saldo da previsão dele também');
select pg_temp.volta();
rollback;

\echo '# previsão no Sienge: título PRV, fila e lista do que apagar'
begin;
select pg_temp.sis();
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values
  ('sienge', 'empresas', :'spe', '11'), ('sienge', 'pessoas', '10000000-0000-0000-0000-000000000007', '823')
  on conflict do nothing;
insert into erp.sienge_centros (nucleo_economico_id, centro_custo_id, sienge_centro) values (:'ne_vm', :'cc_mkt', 100) on conflict do nothing;
insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (pg_temp.nat('05.01.04'), :'cc_mkt', '2030224') on conflict do nothing;
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;   -- o centro entra na alçada
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor, descricao)
values ('69000000-0000-0000-0000-0000000000b1', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 250, 'Mídia de dezembro'),
       ('69000000-0000-0000-0000-0000000000b2', :'spe', 'manual', null, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-15', 80, null);
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor, descricao)
values ('69000000-0000-0000-0000-0000000000b3', :'spe', 'manual', null, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-20', 60, null);
select pg_temp.como(:'diretor');
select erp.decidir_previsao(p.id, true) from erp.previsoes p
 where p.id in ('69000000-0000-0000-0000-0000000000b1', '69000000-0000-0000-0000-0000000000b2')
   and exists (select 1 from erp.previsao_alcadas a where a.previsao_id = p.id);
select pg_temp.sis();
-- b3, lançada pelo analista, fica esperando a alçada
select pg_temp.ok(not has_function_privilege('authenticated', 'erp.sienge_pegar()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_pedido_item(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_registrar_item(uuid, int)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_terminar(uuid, text, text, text, int, timestamptz)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_ids()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_pegar_conferencia()', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_marcar_apagado(uuid)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._sienge_pedido_previsao(uuid)', 'EXECUTE'),
  'prv: a fila e o pedido da previsão não são executáveis pela API');
select erp.sienge_enfileirar();
select pg_temp.ok((select count(*) = 2 and bool_and(situacao = 'pendente') from erp.sienge_previsoes
                    where previsao_id in ('69000000-0000-0000-0000-0000000000b1', '69000000-0000-0000-0000-0000000000b2')),
  'prv: a previsão aberta e aprovada entra na fila');
select pg_temp.ok(not erp.previsao_aprovada('69000000-0000-0000-0000-0000000000b3')
                  and (select situacao = 'aberta' from erp.previsoes where id = '69000000-0000-0000-0000-0000000000b3')
                  and not exists (select 1 from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b3'),
  'prv: a previsão aberta sem aprovação não entra na fila');
select pg_temp.erro_igual($$select erp._sienge_pedido_previsao('69000000-0000-0000-0000-0000000000b3')$$,
  'A previsão não está aprovada', 'prv: o pedido confere a aprovação de novo');
select pg_temp.erro_igual($$select erp.sienge_pedido_item('69000000-0000-0000-0000-0000000000b2')$$,
  'Falta o credor genérico da previsão no Sienge (parâmetro credor_previsao)', 'prv: sem credor e sem o genérico, não vai');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.sienge_parametros (chave, valor) values ('credor_previsao', '823')$$,
  'prv: quem não é master não grava o credor genérico');
select pg_temp.como(:'diretor');
insert into erp.sienge_parametros (chave, valor) values ('credor_previsao', '823');
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'codigo_externo_alterado' and tabela = 'sienge_parametros' and registro = 'credor_previsao'),
  'prv: o credor genérico vira evento crítico de código externo');
select erp.sienge_pedido_item('69000000-0000-0000-0000-0000000000b2') as pb2 \gset
select pg_temp.ok((:'pb2'::jsonb->'titulo'->>'creditorId')::int = 823 and :'pb2'::jsonb->'titulo'->>'documentIdentificationId' = 'PRV'
                  and :'pb2'::jsonb->'titulo'->>'documentNumber' = 'PRV-690000000000'
                  and (:'pb2'::jsonb->'titulo'->>'installmentsNumber')::int = 1 and (:'pb2'::jsonb->'titulo'->>'totalInvoiceAmount')::numeric = 80
                  and :'pb2'::jsonb->'titulo'->>'dueDate' = '2026-12-15' and :'pb2'::jsonb->'titulo'->>'billDate' = '2026-12-01'
                  and :'pb2'::jsonb->'titulo'->>'baseDate' = (now() at time zone 'America/Sao_Paulo')::date::text
                  and :'pb2'::jsonb->'titulo'->>'notes' = 'ERP 69000000-0000-0000-0000-0000000000b2 · Previsão'
                  and :'pb2'::jsonb->'titulo'->'budgetCategories' = '[{"costCenterId": 100, "percentage": 100, "paymentCategoriesId": "2030224"}]'
                  and :'pb2'::jsonb->'parcelas' = '[{"numero": 1, "valor": 80.00, "vencimento": "2026-12-15"}]',
  'prv: o pedido leva o documento PRV, o credor genérico, uma parcela sem forma de pagamento e o marcador do ERP');
select pg_temp.ok((erp.sienge_pedido_item('69000000-0000-0000-0000-0000000000b1')->'titulo'->>'creditorId')::int = 823,
  'prv: com credor, vai o credor da previsão');
select item_id as it1 from erp.sienge_pegar() \gset
select pg_temp.ok(exists (select 1 from erp.sienge_previsoes where previsao_id = :'it1' and proxima_em > now() + interval '14 minutes'),
  'prv: a fila entrega uma previsão e a reserva por 15 minutos');
select erp.sienge_registrar_item('69000000-0000-0000-0000-0000000000b1', 7001);
select erp.sienge_terminar('69000000-0000-0000-0000-0000000000b1', 'enviado', 'pagamento', null, 1, now());
select pg_temp.ok((select situacao = 'enviado' and sienge_id = 7001 from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b1')
                  and (select codigo = '7001' from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes'
                         and registro_id = '69000000-0000-0000-0000-0000000000b1')
                  and 7001 in (select erp.sienge_ids()),
  'prv: o id do Sienge fica na fila e nos códigos externos, e entra nos ids da trava');
select pg_temp.erro_igual($$select erp.sienge_terminar('69000000-0000-0000-0000-0000000000b1', 'apagado', null, null, 1, now())$$,
  'Situação da fila inválida', 'prv: terminar só com as situações da fila');
select pg_temp.erro_igual($$update erp.sienge_previsoes set sienge_id = 7002 where previsao_id = '69000000-0000-0000-0000-0000000000b1'$$,
  'A previsão já tem id no Sienge (7001); não troca', 'prv: o id do Sienge não se troca');
select pg_temp.erro_igual($$delete from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b1'$$,
  'A fila do Sienge não se apaga', 'prv: a fila não se apaga');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_conferencia()), 'prv: nada a conferir enquanto a previsão está aberta');
select erp.sienge_enfileirar();
select pg_temp.ok((select apagar_desde is null from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b1'),
  'prv: a enviada ainda aberta não vai para a lista do que apagar');
select pg_temp.erro_igual($$select erp.sienge_marcar_apagado('69000000-0000-0000-0000-0000000000b1')$$,
  'A previsão não está na lista do que apagar', 'prv: só se marca apagada a que está na lista do que apagar');
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'previsoes', '69000000-0000-0000-0000-0000000000b2', '9999');
select pg_temp.erro_igual($$select erp.sienge_registrar_item('69000000-0000-0000-0000-0000000000b2', 7002)$$,
  'A previsão já está ligada a outro título do Sienge', 'prv: o registro não liga a previsão a um segundo título do Sienge');
delete from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes' and registro_id = '69000000-0000-0000-0000-0000000000b2';
-- a previsão sai de aberta: a enviada vai para a lista do que apagar, a que não foi é descartada
select pg_temp.volta();
select pg_temp.como(:'diretor');
update erp.previsoes set situacao = 'cancelada' where id in ('69000000-0000-0000-0000-0000000000b1', '69000000-0000-0000-0000-0000000000b2');
select pg_temp.sis();
select erp.sienge_enfileirar();
select pg_temp.ok((select apagar_desde is not null and apagado_em is null from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b1')
                  and (select situacao = 'descartado' and apagar_desde is null from erp.sienge_previsoes where previsao_id = '69000000-0000-0000-0000-0000000000b2'),
  'prv: a enviada que saiu de aberta vai para a lista do que apagar; a que não foi é descartada');
select pg_temp.erro_igual($$update erp.sienge_previsoes set apagar_desde = null where previsao_id = '69000000-0000-0000-0000-0000000000b1'$$,
  'A marca de apagar não muda', 'prv: a marca de apagar não se desfaz');
select pg_temp.erro_igual($$select erp.sienge_terminar('69000000-0000-0000-0000-0000000000b2', 'erro', null, 'x', 2, now())$$,
  'Item fora da fila do Sienge', 'prv: a descartada não volta para a fila');
select pg_temp.erro_igual($$select erp.sienge_pedido_item('69000000-0000-0000-0000-0000000000b1')$$,
  'A previsão não está aberta', 'prv: a previsão que saiu de aberta não monta pedido');
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok((select sienge_id = 7001 and empresa_sienge = '11' from erp.v_sienge_prv_apagar where previsao_id = '69000000-0000-0000-0000-0000000000b1'),
  'prv: quem vê a previsão vê a linha a apagar, com o id e a empresa do Sienge');
select pg_temp.falha($$update erp.sienge_previsoes set apagado_em = now() where previsao_id = '69000000-0000-0000-0000-0000000000b1'$$,
  'prv: pela API ninguém marca apagado');
select pg_temp.sis();
select pg_temp.ok((select item_id = '69000000-0000-0000-0000-0000000000b1' and sienge_id = 7001 from erp.sienge_pegar_conferencia()),
  'prv: a conferência entrega a linha a apagar');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_conferencia()), 'prv: a mesma linha só volta à conferência depois de 30 minutos');
update erp.sienge_previsoes set conferido_em = now() - interval '29 minutes' where previsao_id = '69000000-0000-0000-0000-0000000000b1';
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_conferencia()), 'prv: conferida há 29 minutos, ainda não volta');
update erp.sienge_previsoes set conferido_em = now() - interval '31 minutes' where previsao_id = '69000000-0000-0000-0000-0000000000b1';
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_conferencia()), 'prv: conferida há 31 minutos, volta');
select erp.sienge_marcar_apagado('69000000-0000-0000-0000-0000000000b1');
select pg_temp.ok(not exists (select 1 from erp.v_sienge_prv_apagar where previsao_id = '69000000-0000-0000-0000-0000000000b1')
                  and 7001 not in (select erp.sienge_ids()),
  'prv: apagada no Sienge, sai da lista e dos ids da trava');
select pg_temp.erro_igual($$select erp.sienge_marcar_apagado('69000000-0000-0000-0000-0000000000b1')$$,
  'A previsão não está na lista do que apagar', 'prv: não se marca apagado duas vezes');
-- um papel nosso que passa pela política "operacao": as funções recusam sozinhas
select pg_temp.como(null);
select set_config('role', 'erp_situacao', false);
select pg_temp.erro_igual($$select * from erp.sienge_pegar()$$, 'Só o sistema pega a fila do Sienge', 'prv: fora do sistema, pegar é recusado');
select pg_temp.erro_igual($$select erp.sienge_pedido_item('69000000-0000-0000-0000-0000000000b1')$$, 'Só o sistema monta o envio ao Sienge', 'prv: fora do sistema, o pedido é recusado');
select pg_temp.erro_igual($$select erp.sienge_registrar_item('69000000-0000-0000-0000-0000000000b1', 1)$$, 'Só o sistema registra o envio ao Sienge', 'prv: fora do sistema, registrar é recusado');
select pg_temp.erro_igual($$select erp.sienge_terminar('69000000-0000-0000-0000-0000000000b1', 'erro', null, null, 1, now())$$, 'Só o sistema mexe na fila do Sienge', 'prv: fora do sistema, terminar é recusado');
select pg_temp.erro_igual($$select * from erp.sienge_pegar_conferencia()$$, 'Só o sistema confere o Sienge', 'prv: fora do sistema, a conferência é recusada');
select pg_temp.erro_igual($$select erp.sienge_marcar_apagado('69000000-0000-0000-0000-0000000000b1')$$, 'Só o sistema confere o Sienge', 'prv: fora do sistema, marcar apagado é recusado');
select pg_temp.erro_igual($$insert into erp.sienge_previsoes (previsao_id) values ('69000000-0000-0000-0000-0000000000b3')$$,
  'A fila do Sienge só é escrita pelo sistema', 'prv: o gatilho da fila recusa quem não é o sistema');
select pg_temp.como(null);
rollback;

\echo '# cruzamento das linhas PRV com o Sienge'
begin;
select pg_temp.sis();
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'empresas', :'spe', '11') on conflict do nothing;
insert into erp.sienge_centros (nucleo_economico_id, centro_custo_id, sienge_centro) values (:'ne_vm', :'cc_mkt', 100) on conflict do nothing;
insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (pg_temp.nat('05.01.04'), :'cc_mkt', '2030224') on conflict do nothing;
insert into erp.sienge_parametros (chave, valor) values ('credor_previsao', '823') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('6b000000-0000-0000-0000-0000000000c1', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 40);
select erp.decidir_previsao('6b000000-0000-0000-0000-0000000000c1', true)
 where exists (select 1 from erp.previsao_alcadas where previsao_id = '6b000000-0000-0000-0000-0000000000c1');
select pg_temp.sis();
select erp.sienge_enfileirar();
select erp.sienge_registrar_item('6b000000-0000-0000-0000-0000000000c1', 7101);
select erp.sienge_terminar('6b000000-0000-0000-0000-0000000000c1', 'enviado', 'pagamento', null, 1, now());
select pg_temp.ok(not has_function_privilege('authenticated', 'erp.sienge_pegar_cruzamento(timestamptz)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_prv_nossas(int)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_recriar_prv(uuid, int, text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_terminar_cruzamento(int, jsonb, jsonb, text, timestamptz)', 'EXECUTE')
                  and not has_table_privilege('authenticated', 'erp.sienge_prv_estranhas', 'INSERT')
                  and not has_table_privilege('authenticated', 'erp.sienge_prv_trocas', 'INSERT')
                  and not has_table_privilege('authenticated', 'erp.sienge_cruzamentos', 'UPDATE'),
  'cruzamento: as funções e as tabelas não se escrevem pela API');
select pg_temp.ok(has_table_privilege('erp_sistema', 'erp.v_sienge_prv_apagar', 'SELECT')
                  and not has_table_privilege('erp_sistema', 'erp.v_sienge_prv_apagar', 'INSERT'),
  'planilha: o sistema lê a lista do que apagar (e só lê)');
-- só de madrugada (2h às 6h em São Paulo), uma empresa por vez, uma vez por dia
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-18 15:00Z')), 'cruzamento: de dia, não cruza');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-18 04:59Z')), 'cruzamento: antes das 2h, não cruza');
select empresa_sienge as emp, desde from erp.sienge_pegar_cruzamento('2026-11-18 06:00Z') \gset
select pg_temp.ok(:emp = 11 and :'desde'::date = (now() at time zone 'America/Sao_Paulo')::date,
  'cruzamento: às 3h pega a empresa, desde a emissão da linha PRV mais antiga dela');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-18 06:10Z') where empresa_sienge = 11),
  'cruzamento: a empresa em andamento não é pega de novo');
select pg_temp.ok((select esperada from erp.sienge_prv_nossas(11) where sienge_id = 7101), 'cruzamento: a linha enviada de previsão aberta é esperada no Sienge');
-- faltante: recria
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7999, 'x')$$,
  'A previsão não está ligada a este título do Sienge', 'cruzamento: recria só o id que é da previsão');
select pg_temp.erro_igual($$update erp.sienge_previsoes set sienge_id = null where previsao_id = '6b000000-0000-0000-0000-0000000000c1'$$,
  'A previsão já tem id no Sienge (7101); não troca', 'cruzamento: sem a troca registrada, o id não se solta');
select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7101, 'Fora da lista e 404 no Sienge');
select pg_temp.ok((select sienge_id is null and situacao = 'pendente' and tentativas = 0 from erp.sienge_previsoes where previsao_id = '6b000000-0000-0000-0000-0000000000c1')
                  and exists (select 1 from erp.sienge_prv_trocas where previsao_id = '6b000000-0000-0000-0000-0000000000c1' and sienge_id = 7101)
                  and not exists (select 1 from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes' and registro_id = '6b000000-0000-0000-0000-0000000000c1')
                  and exists (select 1 from erp.eventos where tipo = 'prv_recriada' and registro = '6b000000-0000-0000-0000-0000000000c1'),
  'cruzamento: a linha que sumiu volta à fila, com o id antigo guardado e o aviso à AF');
select pg_temp.ok((select not esperada from erp.sienge_prv_nossas(11) where sienge_id = 7101), 'cruzamento: o id antigo continua conhecido (não vira estranha)');
select erp.sienge_registrar_item('6b000000-0000-0000-0000-0000000000c1', 7102);
select erp.sienge_terminar('6b000000-0000-0000-0000-0000000000c1', 'enviado', 'pagamento', null, 1, now());
select pg_temp.ok((select codigo = '7102' from erp.codigos_externos where sistema = 'sienge' and tabela = 'previsoes' and registro_id = '6b000000-0000-0000-0000-0000000000c1'),
  'cruzamento: a linha nova ganha o id novo');
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7102, '')$$,
  'new row for relation "sienge_prv_trocas" violates check constraint "sienge_prv_trocas_motivo_check"', 'cruzamento: recriar pede o motivo');
-- estranhas
select pg_temp.erro_igual($$select erp.sienge_terminar_cruzamento(11, '[{"sienge_id": 7102, "motivo": "x"}]', '{}', null, '2026-11-18 06:20Z')$$,
  'Linha do ERP marcada como estranha', 'cruzamento: linha do ERP nunca vira estranha');
select pg_temp.erro_igual($$select erp.sienge_terminar_cruzamento(11, '[{"sienge_id": 7101, "motivo": "x"}]', '{}', null, '2026-11-18 06:20Z')$$,
  'Linha do ERP marcada como estranha', 'cruzamento: nem a linha antiga trocada');
select pg_temp.ok(erp.sienge_terminar_cruzamento(11, '[{"sienge_id": 8001, "numero": "PRV-X", "emissao": "2025-03-01", "valor": 10, "motivo": "não é do ERP"},
                                                  {"sienge_id": 8002, "numero": "PRV-Y", "motivo": "não é do ERP"}]', '{"lidos": 3}', null, '2026-11-18 06:20Z') = 2,
  'cruzamento: as estranhas novas entram');
select pg_temp.ok((select situacao = 'ok' and (resumo->>'novas')::int = 2 and (resumo->>'lidos')::int = 3 from erp.sienge_cruzamentos where dia = '2026-11-18' and empresa_sienge = 11)
                  and exists (select 1 from erp.eventos where tipo = 'prv_estranhas' and registro = '11' and dados->>'novas' = '2'),
  'cruzamento: a passada fecha e a AF é avisada com a quantidade');
select pg_temp.erro_igual($$select erp.sienge_terminar_cruzamento(11, '[]', '{}', null, '2026-11-18 06:30Z')$$,
  'Cruzamento fora de hora', 'cruzamento: não fecha passada que não está rodando');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-18 07:00Z') where empresa_sienge = 11), 'cruzamento: uma passada por dia');
-- no dia seguinte: a 8001 continua (não avisa de novo), a 8002 sumiu
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-19 06:00Z') where empresa_sienge = 11), 'cruzamento: no outro dia, passa de novo');
select pg_temp.ok(erp.sienge_terminar_cruzamento(11, '[{"sienge_id": 8001, "motivo": "não é do ERP"}]', '{}', null, '2026-11-19 06:20Z') = 0,
  'cruzamento: estranha já vista não conta como nova');
select pg_temp.ok((select count(*) = 1 from erp.eventos where tipo = 'prv_estranhas' and registro = '11'),
  'cruzamento: estranha já vista não avisa de novo');
select pg_temp.ok((select sumiu_em is not null from erp.sienge_prv_estranhas where sienge_id = 8002)
                  and (select array_agg(sienge_id) = '{8001}' from erp.v_sienge_prv_estranhas),
  'cruzamento: a que não aparece mais sai da lista');
-- cada trava da recriação sozinha (S-134): a marca de apagar, a previsão fora de aberta e o gatilho da fila
savepoint sp_cruz2;
update erp.sienge_previsoes set apagar_desde = now() where previsao_id = '6b000000-0000-0000-0000-0000000000c1';
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7102, 'x')$$,
  'Só a linha PRV enviada de previsão aberta se recria', 'cruzamento: linha marcada para apagar não se recria, mesmo com a previsão aberta');
insert into erp.sienge_prv_trocas (previsao_id, sienge_id, motivo) values ('6b000000-0000-0000-0000-0000000000c1', 7102, 'teste');
select pg_temp.erro_igual($$update erp.sienge_previsoes set sienge_id = null where previsao_id = '6b000000-0000-0000-0000-0000000000c1'$$,
  'A previsão já tem id no Sienge (7102); não troca', 'cruzamento: a fila não solta o id da linha marcada para apagar, nem com a troca registrada');
-- a planilha lê como erp_sistema, sem login: a linha a apagar aparece
select set_config('role', 'erp_sistema', false);
select pg_temp.ok((select count(*) = 1 from erp.v_sienge_prv_apagar where sienge_id = 7102) and erp.login_atual() is null,
  'planilha: como erp_sistema, a linha a apagar aparece na lista');
select pg_temp.sis();
rollback to savepoint sp_cruz2;
savepoint sp_cruz3;
update erp.previsoes set situacao = 'cancelada' where id = '6b000000-0000-0000-0000-0000000000c1';
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7102, 'x')$$,
  'Só a linha PRV enviada de previsão aberta se recria', 'cruzamento: previsão que não está aberta não se recria, mesmo sem a marca de apagar');
rollback to savepoint sp_cruz3;
-- só a linha enviada é esperada e se recria
savepoint sp_cruz;
select erp.sienge_terminar('6b000000-0000-0000-0000-0000000000c1', 'erro', 'pagamento', 'x', 2, now());
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7102, 'x')$$,
  'Só a linha PRV enviada de previsão aberta se recria', 'cruzamento: linha da fila em erro não se recria');
select pg_temp.ok((select not esperada from erp.sienge_prv_nossas(11) where sienge_id = 7102), 'cruzamento: linha da fila em erro não é esperada');
rollback to savepoint sp_cruz;
-- erro: tenta de novo 30 minutos depois, até 3 vezes
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-20 06:00Z')), 'cruzamento: (passada do dia 20)');
select erp.sienge_terminar_cruzamento(11, null, '{}', 'Sienge GET /bills respondeu 500', '2026-11-20 06:05Z');
select pg_temp.ok((select situacao = 'erro' from erp.sienge_cruzamentos where dia = '2026-11-20' and empresa_sienge = 11)
                  and not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-20 06:20Z'))
                  and exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-20 06:40Z')),
  'cruzamento: com erro, tenta de novo depois de 30 minutos');
select erp.sienge_terminar_cruzamento(11, null, '{}', 'de novo', '2026-11-20 06:41Z');
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-20 07:20Z')), 'cruzamento: (terceira tentativa)');
select erp.sienge_terminar_cruzamento(11, null, '{}', 'de novo', '2026-11-20 07:21Z');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-20 08:00Z')), 'cruzamento: depois de 3 tentativas, só no outro dia');
-- a que sumiu e voltou volta à lista, sem aviso novo
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_cruzamento('2026-11-21 06:00Z')), 'cruzamento: (passada do dia 21)');
select pg_temp.ok(erp.sienge_terminar_cruzamento(11, '[{"sienge_id": 8001, "motivo": "a"}, {"sienge_id": 8002, "motivo": "b"}]', '{}', null, '2026-11-21 06:20Z') = 0,
  'cruzamento: a estranha que voltou não é nova');
select pg_temp.ok((select count(*) = 2 from erp.v_sienge_prv_estranhas), 'cruzamento: a estranha que voltou aparece de novo na lista');
-- quem vê
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.v_sienge_prv_estranhas), 'cruzamento: o master vê as estranhas');
select pg_temp.como(:'leitor');
select pg_temp.ok(not exists (select 1 from erp.v_sienge_prv_estranhas) and not exists (select 1 from erp.sienge_cruzamentos),
  'cruzamento: quem não está na AF não vê as estranhas nem as passadas');
select pg_temp.falha($$update erp.sienge_prv_estranhas set sumiu_em = now()$$, 'cruzamento: ninguém mexe nas estranhas pela API');
select pg_temp.como(null);
select set_config('role', 'erp_situacao', false);
select pg_temp.erro_igual($$select * from erp.sienge_pegar_cruzamento('2026-11-22 06:00Z')$$, 'Só o sistema cruza o Sienge', 'cruzamento: fora do sistema, pegar é recusado');
select pg_temp.erro_igual($$select erp.sienge_recriar_prv('6b000000-0000-0000-0000-0000000000c1', 7102, 'x')$$, 'Só o sistema cruza o Sienge', 'cruzamento: fora do sistema, recriar é recusado');
select pg_temp.erro_igual($$select erp.sienge_terminar_cruzamento(11, '[]', '{}')$$, 'Só o sistema cruza o Sienge', 'cruzamento: fora do sistema, fechar é recusado');
select pg_temp.erro_igual($$select * from erp.sienge_prv_nossas(11)$$, 'Só o sistema cruza o Sienge', 'cruzamento: fora do sistema, a lista das nossas é recusada');
select pg_temp.erro_igual($$insert into erp.sienge_prv_trocas (previsao_id, sienge_id, motivo) values ('6b000000-0000-0000-0000-0000000000c1', 1, 'x')$$,
  'O histórico do Sienge só é escrito pelo sistema', 'cruzamento: o histórico de troca só pelo sistema');
select pg_temp.erro_igual($$insert into erp.sienge_cruzamentos (dia, empresa_sienge) values ('2026-11-21', 11)$$,
  'O cruzamento do Sienge só é escrito pelo sistema', 'cruzamento: as passadas só pelo sistema');
select pg_temp.como(null);
select pg_temp.erro_igual($$delete from erp.sienge_prv_trocas$$, 'O histórico do Sienge não se altera nem se apaga', 'cruzamento: o histórico de troca não se apaga');
rollback;

\echo '# aviso do Sienge (webhook) para a linha PRV apagada'
begin;
select pg_temp.sis();
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values ('sienge', 'empresas', :'spe', '11') on conflict do nothing;
insert into erp.sienge_centros (nucleo_economico_id, centro_custo_id, sienge_centro) values (:'ne_vm', :'cc_mkt', 100) on conflict do nothing;
insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (pg_temp.nat('05.01.04'), :'cc_mkt', '2030224') on conflict do nothing;
insert into erp.sienge_parametros (chave, valor) values ('credor_previsao', '823') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'diretor');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('6c000000-0000-0000-0000-0000000000d1', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 41),
       ('6c000000-0000-0000-0000-0000000000d2', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 42);
select erp.decidir_previsao(x, true) from unnest(array['6c000000-0000-0000-0000-0000000000d1', '6c000000-0000-0000-0000-0000000000d2']::uuid[]) x
 where exists (select 1 from erp.previsao_alcadas where previsao_id = x);
select pg_temp.sis();
select erp.sienge_enfileirar();
select erp.sienge_registrar_item('6c000000-0000-0000-0000-0000000000d1', 7201);
select erp.sienge_terminar('6c000000-0000-0000-0000-0000000000d1', 'enviado', 'pagamento', null, 1, now());
select erp.sienge_registrar_item('6c000000-0000-0000-0000-0000000000d2', 7202);
select erp.sienge_terminar('6c000000-0000-0000-0000-0000000000d2', 'enviado', 'pagamento', null, 1, now());
update erp.sienge_previsoes set apagar_desde = now() where previsao_id = '6c000000-0000-0000-0000-0000000000d2';
-- a página das PRV a apagar (pagina.prv_apagar): só login Google com e-mail @bkm.com.br
create function pg_temp.login(c text) returns void language sql as
  $$ select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claims', coalesce(c, ''), false),
            set_config('role', 'authenticated', false) $$;
select pg_temp.login('{"role":"authenticated","email":"Fulano.Tal@BKM.com.br","app_metadata":{"provider":"google"}}');
select pg_temp.ok((select count(*) = 1 and bool_and(empresa_sienge = '11' and valor = 42 and data_prevista = '2026-12-10'
                                                     and documento = 'PRV-6C0000000000' and na_lista_desde is not null)
                     from pagina.prv_apagar() where titulo_sienge = 7202)
                  and not exists (select 1 from pagina.prv_apagar() where titulo_sienge = 7201),
  'página PRV: login Google da BKM vê a linha a apagar (e só ela), sem cadastro no ERP');
savepoint pagina_apagada;
select pg_temp.sis();
select erp.sienge_marcar_apagado('6c000000-0000-0000-0000-0000000000d2');
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm.com.br","app_metadata":{"provider":"google"}}');
select pg_temp.ok(not exists (select 1 from pagina.prv_apagar() where titulo_sienge = 7202),
  'página PRV: linha já apagada no Sienge sai da página');
rollback to savepoint pagina_apagada;
savepoint pagina_pj;
select pg_temp.sis();
update erp.naturezas set restrita = true where codigo = '05.01.04';
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm.com.br","app_metadata":{"provider":"google"}}');
select pg_temp.ok(not exists (select 1 from pagina.prv_apagar() where titulo_sienge = 7202),
  'página PRV: a PRV de natureza que virou PJ sai da página');
rollback to savepoint pagina_pj;
select pg_temp.login('{"role":"authenticated","email":"fulano@bkmxcom.br","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: domínio parecido (bkmxcom.br) não entra');
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm-com.br","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: domínio parecido (bkm-com.br) não entra');
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm.com.br","app_metadata":{"provider":"email"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: e-mail da BKM com senha não entra');
select pg_temp.login('{"role":"authenticated","email":"fulano@gmail.com","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: Google de fora da BKM não entra');
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm.com.br.outro.com","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: domínio que só começa com bkm.com.br não entra');
select pg_temp.login('{"role":"authenticated","email":"fulano@sub.bkm.com.br","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: subdomínio não entra');
select pg_temp.login('{"role":"anon","email":"fulano@bkm.com.br","app_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: claims sem papel authenticated não entram');
select pg_temp.login('{"role":"authenticated","email":"fulano@bkm.com.br","user_metadata":{"provider":"google"}}');
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: provider fora do app_metadata não vale');
select pg_temp.login(null);
select pg_temp.erro_igual($$select * from pagina.prv_apagar()$$, 'Entre com a conta Google da BKM', 'página PRV: sem login não entra');
select set_config('request.jwt.claims', '', false), set_config('role', 'none', false);
select pg_temp.ok(not has_function_privilege('anon', 'pagina.prv_apagar()', 'EXECUTE')
                  and not has_schema_privilege('anon', 'pagina', 'USAGE')
                  and not has_function_privilege('anon', 'erp.prv_apagar_pagina()', 'EXECUTE')
                  and not has_function_privilege('service_role', 'erp.prv_apagar_pagina()', 'EXECUTE')
                  and has_function_privilege('authenticated', 'pagina.prv_apagar()', 'EXECUTE')
                  and (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'pagina') = 1
                  and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pagina'),
  'página PRV: anon não chega ao esquema; o `pagina` só tem a função, sem tabela');
select pg_temp.sis();
select pg_temp.ok(not has_function_privilege('authenticated', 'erp.sienge_registrar_aviso(uuid, text, text, jsonb)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_pegar_aviso(timestamptz, int)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.sienge_terminar_aviso(uuid, text, boolean)', 'EXECUTE')
                  and not has_table_privilege('authenticated', 'erp.sienge_avisos', 'INSERT')
                  and not has_table_privilege('authenticated', 'erp.sienge_avisos_excesso', 'INSERT')
                  and not has_table_privilege('anon', 'erp.sienge_avisos', 'SELECT'),
  'aviso: as funções e a tabela não se escrevem pela API');
-- registrar
select pg_temp.ok(erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000001', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 9999, "installmentId": 1}'),
  'aviso: o aviso novo entra');
select pg_temp.ok(not erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000001', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 9999, "installmentId": 1}')
                  and (select count(*) = 1 from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000001'),
  'aviso: o mesmo aviso repetido não entra de novo');
select pg_temp.ok((select processado_em is not null and resultado = 'não é linha PRV do ERP' from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000001'),
  'aviso: título que não é linha PRV do ERP fecha sem chamar o Sienge');
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000002', 'PAYMENT_INSTALLMENT_CREATED', 'h', '{"billId": 7201, "installmentId": 1}');
select pg_temp.ok((select processado_em is not null and resultado = 'evento sem ação' from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000002'),
  'aviso: outro evento de linha nossa só fica registrado');
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000003', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": "7202"}');
select pg_temp.ok((select bill_id is null and processado_em is not null from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000003'),
  'aviso: billId que não é número não liga a nada');
select pg_temp.erro_igual($$select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000009', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '[1]')$$,
  'Aviso do Sienge inválido', 'aviso: corpo que não é objeto é recusado');
savepoint sp_av1;
update erp.previsoes set situacao = 'cancelada' where id = '6c000000-0000-0000-0000-0000000000d1';
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000004', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7201}');
select pg_temp.ok((select processado_em is not null and resultado = 'não é linha PRV do ERP' from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000004'),
  'aviso: linha enviada de previsão que não está aberta (sem a marca de apagar) não é esperada');
rollback to savepoint sp_av1;
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000011', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7202, "installmentId": 1}');
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000012', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7202, "installmentId": 2}');
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000013', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7201, "installmentId": 1}');
select pg_temp.ok((select count(*) = 3 from erp.sienge_avisos where processado_em is null), 'aviso: as remoções de linha nossa ficam pendentes');
-- pegar e processar
-- relógio fixo no começo de uma hora cheia: o excesso é contado por hora do relógio (date_trunc), e com now() o teste
-- falhava quando +70 e +71 minutos caíam em horas diferentes (minutos 49 e 50 de cada hora)
select date_trunc('hour', now()) + interval '1 hour' as t0 \gset
select evento_id as av1, bill_id as b1, previsao_id as p1, tipo as t1 from erp.sienge_pegar_aviso(:'t0'::timestamptz) \gset
select pg_temp.ok(:'av1' = 'a1000000-0000-0000-0000-000000000011' and :b1 = 7202 and :'p1' = '6c000000-0000-0000-0000-0000000000d2' and :'t1' = 'apagar',
  'aviso: o mais antigo vem com a previsão e o tipo (linha a apagar)');
select evento_id as av2 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '1 minute') \gset
select pg_temp.ok(:'av2' = 'a1000000-0000-0000-0000-000000000013'
                  and (select processado_em is not null and resultado = 'título conferido há menos de 30 minutos por outro aviso: sem chamada'
                         from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000012'),
  'aviso: o reservado não é pego de novo; o outro aviso do mesmo título fecha sem chamada (S-136)');
-- a outra parcela chega enquanto o primeiro aviso está sendo tratado
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000014', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7202, "installmentId": 3}');
select erp.sienge_marcar_apagado('6c000000-0000-0000-0000-0000000000d2');
select erp.sienge_terminar_aviso('a1000000-0000-0000-0000-000000000011', 'apagado no Sienge (404)');
select pg_temp.erro_igual($$select erp.sienge_terminar_aviso('a1000000-0000-0000-0000-000000000011', 'x')$$,
  'Aviso do Sienge inexistente ou já processado', 'aviso: o processado não fecha de novo');
select erp.sienge_terminar_aviso('a1000000-0000-0000-0000-000000000013', 'Sienge respondeu 500', false);
select count(*) as n3 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '3 minutes') \gset
select pg_temp.ok(:n3 = 0 and (select resultado = 'a linha já não está pendente no ERP' and processado_em is not null
                                 from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000014'),
  'aviso: o da outra parcela do título já apagado fecha sozinho');
-- sem resposta: tenta de novo depois de 5 minutos, até 5 vezes
select pg_temp.ok(exists (select 1 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '7 minutes') where tipo = 'esperada'
                            and previsao_id = '6c000000-0000-0000-0000-0000000000d1'),
  'aviso: vem a linha esperada');
select pg_temp.ok(not exists (select 1 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '9 minutes'))
                  and exists (select 1 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '13 minutes')),
  'aviso: sem resposta, volta depois de 5 minutos');
select erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '19 minutes');
select erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '25 minutes');
select not exists (select 1 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '31 minutes')) as nada5 \gset
select pg_temp.ok(:'nada5'::boolean
                  and (select processado_em is not null and resultado like 'erro: 5 tentativas%' and tentativas = 5
                         from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000013'),
  'aviso: depois de 5 tentativas fecha com erro (a conferência e o cruzamento resolvem)');
-- teto por hora (S-136): o 13 foi pego aos 25 minutos
savepoint sp_av2;
select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000015', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7201, "installmentId": 2}');
select count(*) as n4 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '70 minutes', 1) \gset
select count(*) as n5 from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '71 minutes', 1) \gset
select pg_temp.ok(:n4 = 0 and :n5 = 0
                  and (select processado_em is null and pegado_em is null from erp.sienge_avisos where evento_id = 'a1000000-0000-0000-0000-000000000015')
                  and (select count(*) = 1 and min(pegos) = 1 from erp.sienge_avisos_excesso)
                  and (select count(*) = 1 from erp.eventos where tipo = 'sienge_avisos_excesso'),
  'aviso: acima do teto por hora não pega (o aviso espera) e avisa a AF uma vez por hora');
select pg_temp.ok((select evento_id = 'a1000000-0000-0000-0000-000000000015' from erp.sienge_pegar_aviso(:'t0'::timestamptz + interval '72 minutes', 2)),
  'aviso: abaixo do teto pega');
select pg_temp.erro_igual($$select * from erp.sienge_pegar_aviso(now(), 0)$$, 'Limite de avisos por hora inválido', 'aviso: teto inválido é recusado');
rollback to savepoint sp_av2;
-- o aviso recebido não muda nem se apaga
select pg_temp.erro_igual($$update erp.sienge_avisos set corpo = '{}' where evento_id = 'a1000000-0000-0000-0000-000000000011'$$,
  'O aviso recebido não muda', 'aviso: o corpo recebido não muda');
select pg_temp.erro_igual($$update erp.sienge_avisos set resultado = 'x' where evento_id = 'a1000000-0000-0000-0000-000000000011'$$,
  'O aviso já foi processado', 'aviso: o processado não muda');
select pg_temp.erro_igual($$delete from erp.sienge_avisos$$, 'Os avisos do Sienge não se apagam', 'aviso: não se apaga');
-- quem vê e quem escreve
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.sienge_avisos), 'aviso: o master lê os avisos');
select pg_temp.como(:'leitor');
select pg_temp.ok(not exists (select 1 from erp.sienge_avisos), 'aviso: quem não é master nem AF não lê');
select pg_temp.como(null);
select set_config('role', 'erp_situacao', false);
select pg_temp.erro_igual($$select erp.sienge_registrar_aviso('a1000000-0000-0000-0000-000000000099', 'PAYMENT_INSTALLMENT_REMOVED', 'h', '{"billId": 7201}')$$,
  'Só o sistema registra aviso do Sienge', 'aviso: fora do sistema, registrar é recusado');
select pg_temp.erro_igual($$select * from erp.sienge_pegar_aviso()$$, 'Só o sistema processa aviso do Sienge', 'aviso: fora do sistema, pegar é recusado');
select pg_temp.como(null);
rollback;

\echo '# PJ: só o master e quem ele designar (Moises, 18/11/2026)'
begin;
select pg_temp.sis();
update erp.naturezas set restrita = true where codigo = '05.01.03';
insert into erp.regras_notificacao (tipo, destino, user_id, email, whatsapp) values ('alcada_falta_aprovadores', 'pessoa', :'gestor', false, false);
select pg_temp.volta();
-- designar: só o master, com motivo e histórico
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.designar_pj(%L, 'x')$$, :'analista'), 'Só o master designa quem vê o PJ',
  'PJ: quem não é master não designa');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select erp.designar_pj(%L, ' ')$$, :'analista'), 'Designar para o PJ precisa de motivo',
  'PJ: designar sem motivo é recusado');
select erp.designar_pj(:'analista', 'Lança a folha PJ');
select pg_temp.ok(exists (select 1 from erp.designados_pj where user_id = :'analista')
                  and exists (select 1 from erp.designados_pj_historico where user_id = :'analista' and acao = 'designado' and por = :'diretor'),
  'PJ: o master designa, com o histórico');
select pg_temp.como(:'gestor');
select pg_temp.ok(not exists (select 1 from erp.designados_pj) and not exists (select 1 from erp.designados_pj_historico),
  'PJ: quem não é master nem o designado não vê a lista');
select pg_temp.falha(format($$insert into erp.designados_pj (user_id, motivo, por) values (%L, 'x', %L)$$, :'gestor', :'gestor'),
  'PJ: ninguém se designa pela tabela');
-- a previsão PJ: lançada pelo designado, alçada só da vaga PJ
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('6a000000-0000-0000-0000-0000000000a1', :'spe', 'manual', null, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), '2026-12-01', '2026-12-10', 700),
  ('6a000000-0000-0000-0000-0000000000a2', :'spe', 'manual', null, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 30);
select pg_temp.ok(exists (select 1 from erp.previsoes where id = '6a000000-0000-0000-0000-0000000000a1'), 'PJ: o designado lança e vê a previsão PJ');
select pg_temp.sis();
select pg_temp.ok((select count(*) = 1 and bool_and(fases = '{PJ}' and centro_custo_id is null and not falta_aprovadores)
                   from erp.previsao_alcadas where previsao_id = '6a000000-0000-0000-0000-0000000000a1'),
  'PJ: a previsão PJ tem só a vaga PJ (o master aprova)');
select pg_temp.ok(erp.registro_pj('previsoes', '6a000000-0000-0000-0000-0000000000a1') and not erp.registro_pj('previsoes', '6a000000-0000-0000-0000-0000000000a2')
                  and not erp.registro_pj('titulos', 'x'),
  'PJ: o evento sabe se o registro é PJ');
select pg_temp.volta();
select pg_temp.como(:'gestor');
select pg_temp.ok(not exists (select 1 from erp.previsoes where id = '6a000000-0000-0000-0000-0000000000a1'),
  'PJ: o AF não vê a previsão PJ');
select pg_temp.erro_igual($$select erp.decidir_previsao('6a000000-0000-0000-0000-0000000000a1', true)$$, 'Previsão não existe',
  'PJ: o AF não aprova a previsão PJ');
select pg_temp.como(:'diretor2');
select pg_temp.ok(not exists (select 1 from erp.previsoes where id = '6a000000-0000-0000-0000-0000000000a1'),
  'PJ: nem a AD vê a previsão PJ');
-- o aviso: o da previsão PJ não vai ao AF; o mesmo aviso de outra previsão vai
select pg_temp.sis();
select erp.registrar_evento('alcada_falta_aprovadores', 'previsoes', '6a000000-0000-0000-0000-0000000000a1', :'ne_vm', :'cc_mkt', '{}');
select erp.registrar_evento('alcada_falta_aprovadores', 'previsoes', '6a000000-0000-0000-0000-0000000000a2', :'ne_vm', :'cc_mkt', '{}');
select max(id) filter (where registro = '6a000000-0000-0000-0000-0000000000a1') as ev_pj,
       max(id) filter (where registro = '6a000000-0000-0000-0000-0000000000a2') as ev_comum from erp.eventos \gset
select pg_temp.ok(exists (select 1 from erp.notificacoes n where n.evento_id = :'ev_comum' and not erp.ve_pj(n.user_id))
                  and not exists (select 1 from erp.notificacoes n where n.evento_id = :'ev_pj' and not erp.ve_pj(n.user_id)),
  'PJ: o aviso de título ou previsão PJ só vai a quem vê o PJ');
-- o PJ fica fora do acumulado: a previsão PJ não soma no acumulado das outras
select erp._previsoes_no_acumulado(:'spe', null, '2026-12-01', :'cc_mkt', null, :'ne_vm', '6a000000-0000-0000-0000-0000000000a2') as acum_sem \gset
update erp.naturezas set restrita = false where codigo = '05.01.03';
select pg_temp.ok(erp._previsoes_no_acumulado(:'spe', null, '2026-12-01', :'cc_mkt', null, :'ne_vm', '6a000000-0000-0000-0000-0000000000a2') = :'acum_sem'::numeric + 700,
  'PJ: a previsão PJ não entra no acumulado do mês (sem a marca, entraria)');
update erp.naturezas set restrita = true where codigo = '05.01.03';
-- o designado vê o PJ mesmo em centro em que não tem acesso
savepoint pj_sem_acesso;
insert into erp.designados_pj (user_id, motivo, por) values (:'ti', 'Teste', :'diretor');
select pg_temp.ok(not erp.ve_linha(:'ti', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), :'diretor')
                  and erp.ve_linha(:'ti', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), :'diretor'),
  'PJ: o designado vê o PJ num centro em que não tem acesso, e só o PJ');
rollback to savepoint pj_sem_acesso;
-- designado inativo ou só da sucessão não vê o PJ
savepoint pj_inativo;
update erp.usuarios set ativo = false where id = :'analista';
select pg_temp.ok(not erp.ve_pj(:'analista'), 'PJ: designado inativo não vê o PJ');
rollback to savepoint pj_inativo;
savepoint pj_sucessao;
set local session_replication_role = replica;
update erp.usuarios set so_sucessao = true, papel = 'leitura' where id = :'analista';
set local session_replication_role = origin;
select pg_temp.ok(not erp.ve_pj(:'analista'), 'PJ: designado só da sucessão não vê o PJ');
rollback to savepoint pj_sucessao;
select pg_temp.ok(erp.ve_pj(:'analista'), 'PJ: designado ativo vê o PJ');
-- o pagamento de PJ sobe sozinho: o rateio não mistura PJ com outra natureza (Moises, 18/11/2026)
select pg_temp.sis();
savepoint pj_sozinho;
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('6b000000-0000-0000-0000-000000000001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-12-01', '2026-12-01', 100);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('6b000000-0000-0000-0000-000000000002', :'spe', '10000000-0000-0000-0000-000000000007', 'recibo', 'PJ-1', '2026-12-01', '2026-12-01', 100);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, valor_total) values
  ('6b000000-0000-0000-0000-000000000003', :'spe', 'avulsa', '10000000-0000-0000-0000-000000000007', 'Teste PJ', '2026-12-01', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000003', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 50);
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6b000000-0000-0000-0000-000000000001', %L, %L, pg_temp.nat('05.01.03'), 50)$$, :'ne_vm', :'cc_mkt'),
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: o título não mistura linha PJ com linha comum');
select pg_temp.erro_igual(format($$insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6b000000-0000-0000-0000-000000000002', %L, %L, pg_temp.nat('05.01.03'), 50)$$, :'ne_vm', :'cc_mkt'),
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: a nota não mistura linha PJ com linha comum');
select pg_temp.erro_igual(format($$insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6b000000-0000-0000-0000-000000000003', %L, %L, pg_temp.nat('05.01.03'), 50)$$, :'ne_vm', :'cc_mkt'),
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: o contrato não mistura linha PJ com linha comum');
-- trocar a natureza da linha comum para PJ, com outra linha comum no título, também é recusado
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 50);
select pg_temp.erro_igual($$update erp.titulo_rateios set natureza_id = pg_temp.nat('05.01.03') where titulo_id = '6b000000-0000-0000-0000-000000000001' and natureza_id = pg_temp.nat('04.01')$$,
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: trocar uma linha para PJ ao lado de linha comum é recusado');
-- levar uma linha PJ de um pai só PJ para um pai com linha comum também é recusado (revisão do #86)
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('6b000000-0000-0000-0000-000000000004', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-12-01', '2026-12-01', 100);
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('6b000000-0000-0000-0000-000000000005', :'spe', '10000000-0000-0000-0000-000000000007', 'recibo', 'PJ-2', '2026-12-01', '2026-12-01', 100);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, valor_total) values
  ('6b000000-0000-0000-0000-000000000006', :'spe', 'avulsa', '10000000-0000-0000-0000-000000000007', 'Teste PJ 2', '2026-12-01', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000004', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000005', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), 100);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000006', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), 100);
select pg_temp.erro_igual($$update erp.titulo_rateios set titulo_id = '6b000000-0000-0000-0000-000000000001' where titulo_id = '6b000000-0000-0000-0000-000000000004'$$,
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: levar a linha PJ para um título com linha comum é recusado');
select pg_temp.erro_igual($$update erp.documento_rateios set documento_id = '6b000000-0000-0000-0000-000000000002' where documento_id = '6b000000-0000-0000-0000-000000000005'$$,
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: levar a linha PJ para uma nota com linha comum é recusado');
select pg_temp.erro_igual($$update erp.compromisso_rateios set compromisso_id = '6b000000-0000-0000-0000-000000000003' where compromisso_id = '6b000000-0000-0000-0000-000000000006'$$,
  'O pagamento de PJ sobe sozinho: o rateio não mistura natureza PJ com outra natureza', 'PJ: levar a linha PJ para um contrato com linha comum é recusado');
-- só PJ, em mais de uma linha, passa
delete from erp.titulo_rateios where titulo_id = '6b000000-0000-0000-0000-000000000001';
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('6b000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.03'), 50),
  ('6b000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('05.01.03'), 50);
select pg_temp.ok((select count(*) from erp.titulo_rateios where titulo_id = '6b000000-0000-0000-0000-000000000001') = 2,
  'PJ: título só de PJ, em mais de uma linha, passa');
rollback to savepoint pj_sozinho;
-- aprovada pelo master, a previsão PJ não vira linha PRV no Sienge
select pg_temp.volta(); select pg_temp.como(:'diretor');
select pg_temp.ok(erp.decidir_previsao('6a000000-0000-0000-0000-0000000000a1', true) = 'aprovado', 'PJ: o master aprova a previsão PJ');
select pg_temp.sis();
select erp.sienge_enfileirar();
select pg_temp.ok(not exists (select 1 from erp.sienge_previsoes where previsao_id = '6a000000-0000-0000-0000-0000000000a1'),
  'PJ: a previsão PJ não vai ao Sienge como linha PRV');
select pg_temp.volta();
-- retirado, o designado deixa de ver
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select erp.retirar_pj(%L, 'x')$$, :'analista'), 'Só o master retira quem vê o PJ',
  'PJ: quem não é master não retira');
select pg_temp.como(:'diretor');
select erp.retirar_pj(:'analista', 'Mudou de área');
select pg_temp.como(:'analista');
select pg_temp.ok(not exists (select 1 from erp.previsoes where id = '6a000000-0000-0000-0000-0000000000a1'),
  'PJ: retirado, deixa de ver o PJ');
select pg_temp.sis();
select pg_temp.ok((select count(*) = 2 from erp.designados_pj_historico where user_id = :'analista'), 'PJ: designar e retirar ficam no histórico');
-- mudar a marca restrita: sem o master, nem pelo pedido dispensado
update erp.regras_mudanca_acesso set exige_aprovacao = false where tabela = 'naturezas';
select pg_temp.volta();
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('naturezas', 'alterar', jsonb_build_object('id', %L, 'restrita', false), 'x')$$, pg_temp.nat('05.01.03')),
  'Só o master muda o que é PJ (a marca restrita da natureza)', 'PJ: com o pedido de natureza dispensado, a marca restrita continua só com o master');
select pg_temp.erro_igual(format($$select erp.pedir_mudanca_acesso('naturezas', 'alterar', jsonb_build_object('id', %L, 'mae_id', %L), 'x')$$,
                                  pg_temp.nat('05.01.04'), pg_temp.nat('05.01.03')),
  'Só o master muda o que é PJ (a marca restrita da natureza)', 'PJ: levar uma natureza para dentro do galho PJ também só com o master');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# api das telas (esquema api, 18/11/2026)'
-- A tela vê exatamente o que o RLS do erp deixa: compara, para cada usuário, o que a função da API devolve com
-- o que a mesma pessoa lê direto nas tabelas.
select pg_temp.como(null);
begin;
-- um título com natureza restrita (como a folha PJ), lançado pelo master, que os outros não veem
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8a000000-0000-0000-0000-000000000001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-11-01', '2026-11-01', 777);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8a000000-0000-0000-0000-000000000001', 1, '2026-11-30', 777);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('8a000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select pg_temp.sis(); update erp.naturezas set restrita = true where codigo = '04.01'; select pg_temp.volta();
create temp table api_usuarios as select unnest(array[:'diretor', :'diretor2', :'gestor', :'analista', :'leitor', :'contador', :'analista2', :'ti']::text[]) u;
grant select on api_usuarios to authenticated;
do $$
declare r record; v_api bigint; v_erp bigint;
begin
  for r in select u from api_usuarios loop
    perform pg_temp.como(r.u);
    select count(*) into v_api from api.titulos();
    select count(*) into v_erp from erp.titulos where sentido = 'pagar';
    if v_api <> v_erp or exists (select id from api.titulos() except select id from erp.titulos where sentido = 'pagar') then
      raise exception 'FALHOU: api.titulos difere do RLS para %', r.u;
    end if;
    if exists (select id from api.previsoes() except select id from erp.previsoes where sentido = 'pagar')
       or exists (select id from erp.previsoes where sentido = 'pagar' except select id from api.previsoes()) then
      raise exception 'FALHOU: api.previsoes difere do RLS para %', r.u;
    end if;
    if exists (select id from api.contratos() except select id from erp.compromissos where tipo in ('contrato','assinatura','consumo'))
       or exists (select id from erp.compromissos where tipo in ('contrato','assinatura','consumo') except select id from api.contratos()) then
      raise exception 'FALHOU: api.contratos difere do RLS para %', r.u;
    end if;
  end loop;
  perform pg_temp.como(null);
end $$;
select pg_temp.ok(true, 'api: títulos, previsões e contratos são, para cada usuário, os mesmos que o RLS do erp deixa ler');
select pg_temp.como(:'diretor');
select pg_temp.ok((select count(*) from api.titulos()) >= 5 and (select count(*) from api.previsoes()) >= 3
                  and (select count(*) from api.contratos()) >= 2 and (select count(distinct etapa) from api.titulos()) >= 3,
  'api: a comparação acima não é vazia (o master vê títulos em várias etapas, previsões e contratos)');
insert into erp.previsoes (id, empresa_id, origem, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('8a000000-0000-0000-0000-0000000000a1', :'spe', 'manual', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-12-01', '2026-12-10', 55);
select pg_temp.ok((select aprovacao = 'esperando' from api.previsoes() where id = '8a000000-0000-0000-0000-0000000000a1')
                  or not exists (select 1 from erp.previsao_alcadas where previsao_id = '8a000000-0000-0000-0000-0000000000a1'),
  'api: previsão manual com alçada aparece esperando aprovação');
select erp.decidir_previsao('8a000000-0000-0000-0000-0000000000a1', true)
 where exists (select 1 from erp.previsao_alcadas where previsao_id = '8a000000-0000-0000-0000-0000000000a1');
select pg_temp.ok((select aprovacao = 'aprovada' and saldo = 55 from api.previsoes() where id = '8a000000-0000-0000-0000-0000000000a1'),
  'api: aprovada pelo master, a previsão aparece aprovada, com o saldo');
select pg_temp.ok((select etapa = 'rascunho' and valor = 777 and fornecedor = 'Construtora Alfa' and meu and parcelas = 1
                          and areas = 'Obra' and vencimento = '2026-11-30' from api.titulos() where id = '8a000000-0000-0000-0000-000000000001'),
  'api: o master vê o título restrito, com etapa, valor, fornecedor, área e vencimento');
select pg_temp.ok((select (j->>'valor')::numeric = 777 and jsonb_array_length(j->'parcelas') = 1 and jsonb_array_length(j->'rateio') = 1
                          and j->'rateio'->0->>'area' = 'Obra' from api.titulo('8a000000-0000-0000-0000-000000000001') j),
  'api: a gaveta traz parcelas e rateio');
select pg_temp.como(:'analista');
select pg_temp.ok(not exists (select 1 from api.titulos() where id = '8a000000-0000-0000-0000-000000000001')
                  and api.titulo('8a000000-0000-0000-0000-000000000001') is null,
  'api: natureza restrita (folha PJ) não aparece na lista nem na gaveta de quem não a tem liberada');
select pg_temp.ok((select (j->>'nome') = 'Rafael' and (j->>'papel') = 'analista' and (j->'listas') = '["AO"]'::jsonb and (j->>'escreve')::boolean
                     from api.eu() j), 'api: eu() traz nome, papel e listas de quem está logado');
select pg_temp.como('login-sem-cadastro');
select pg_temp.ok(api.eu() is null and not exists (select 1 from api.titulos()) and not exists (select 1 from api.previsoes())
                  and not exists (select 1 from api.contratos()),
  'api: login sem cadastro no ERP não tem perfil nem lê nada');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# rastro do título (api.titulo_rastro, 19/11/2026)'
select pg_temp.como(null);
begin;
-- o mesmo título restrito (como a folha PJ) do bloco anterior, para provar que não vaza pelo fornecedor nem pelo contrato
select pg_temp.como(:'diretor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('8b000000-0000-0000-0000-000000000001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', '2026-11-01', '2026-11-01', 778);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('8b000000-0000-0000-0000-000000000001', 1, '2026-11-30', 778);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('8b000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select pg_temp.sis(); update erp.naturezas set restrita = true where codigo = '04.01';
create temp table rastro_ids as select id from erp.titulos where sentido = 'pagar';
grant select on rastro_ids to authenticated;
select pg_temp.volta();
create temp table rastro_usuarios as select unnest(array[:'diretor', :'diretor2', :'gestor', :'analista', :'leitor', :'contador', :'analista2', :'ti']::text[]) u;
grant select on rastro_usuarios to authenticated;
do $$
declare r record; x record; j jsonb; n_vis bigint;
begin
  for r in select u from rastro_usuarios loop
    perform pg_temp.como(r.u);
    for x in select id from rastro_ids loop
      j := api.titulo_rastro(x.id);
      if (j is null) <> not exists (select 1 from erp.titulos where id = x.id) then
        raise exception 'FALHOU: rastro de % para % não segue o RLS do título', x.id, r.u;
      end if;
      continue when j is null;
      select count(*) into n_vis from erp.titulos t join erp.titulos e on e.id = x.id
       where t.pessoa_id = e.pessoa_id and t.sentido = 'pagar' and t.situacao <> 'cancelado';
      if (j->'fornecedor'->>'titulos')::bigint <> n_vis then
        raise exception 'FALHOU: histórico do fornecedor de % para % conta títulos que a pessoa não vê', x.id, r.u;
      end if;
      if exists (select 1 from jsonb_array_elements(coalesce(j->'contrato'->'titulos', '[]') || (j->'fornecedor'->'ultimos')) e
                  where not exists (select 1 from erp.titulos t where t.id = (e->>'id')::uuid)) then
        raise exception 'FALHOU: rastro de % para % lista título que a pessoa não vê', x.id, r.u;
      end if;
    end loop;
  end loop;
  perform pg_temp.como(null);
end $$;
select pg_temp.ok(true, 'rastro: para cada usuário e cada título, o rastro só existe se a pessoa vê o título, e o contrato e o fornecedor só contam e listam títulos que ela vê');
select pg_temp.como(:'diretor');
select pg_temp.ok((select (j->'fornecedor'->>'titulos')::int >= 1 and j->'fornecedor'->>'nome' = 'Construtora Alfa'
                          and jsonb_typeof(j->'historico') = 'array' and j->'historico' @> '[{"texto": "lançou o título."}]'
                          and j->'anexos' = '[]'::jsonb
                     from api.titulo_rastro('8b000000-0000-0000-0000-000000000001') j),
  'rastro: o master vê o título restrito, com o fornecedor e o lançamento no histórico');
select pg_temp.como(:'analista');
select pg_temp.ok(api.titulo_rastro('8b000000-0000-0000-0000-000000000001') is null
                  and not exists (select 1 from rastro_ids i cross join lateral api.titulo_rastro(i.id) j
                                   where j is not null and (j::text like '%8b000000-0000-0000-0000-000000000001%' or j::text ~ '"valor": 778[,}]')),
  'rastro: o título restrito (folha PJ) não aparece no rastro de nenhum outro título para quem não o vê');
select pg_temp.como(null);
rollback;
\echo '# lançar título pela tela (api.lancar_titulo, 19/11/2026)'
select pg_temp.como(null);
begin;
select pg_temp.sis();
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
insert into erp.etiquetas (id, nome) values ('8c000000-0000-0000-0000-000000000001', 'Teste da tela');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('8c000000-0000-0000-0000-000000000002', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-11-01', '2026-11-20', 500);
select pg_temp.volta();
select pg_temp.como(:'leitor');
select pg_temp.ok(api.lancamento_opcoes() is null, 'lançar: quem só consulta não recebe as opções de lançamento');
select pg_temp.falha($$select api.lancar_titulo('{}')$$, 'lançar: quem só consulta não lança');
select pg_temp.como(:'diretor');
select pg_temp.ok((select jsonb_array_length(j->'empresas') > 0 and j->'etiquetas' @> '[{"nome": "Teste da tela"}]' from api.lancamento_opcoes() j)
                  and exists (select 1 from api.naturezas_lancaveis(:'ne_vm', :'cc_mkt', null) where codigo = '05.01.04')
                  and exists (select 1 from api.fornecedores('agência') where id = '10000000-0000-0000-0000-000000000007')
                  and exists (select 1 from api.fornecedores('777.777') where id = '10000000-0000-0000-0000-000000000007'),
  'lançar: opções, naturezas do perfil e busca de fornecedor pelo nome ou pelo documento');
select pg_temp.ok(exists (select 1 from api.previsoes_para_nota(:'spe', '10000000-0000-0000-0000-000000000007',
                                 jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'))))
                           where id = '8c000000-0000-0000-0000-000000000002' and saldo = 500)
                  and not exists (select 1 from api.previsoes_para_nota(:'spe', '10000000-0000-0000-0000-000000000007',
                                 jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_obra', 'natureza', pg_temp.nat('05.01.04'))))
                           where id = '8c000000-0000-0000-0000-000000000002'),
  'lançar: a previsão aparece para a nota só com o mesmo núcleo, centro e natureza de uma linha');
-- uma parcela com boleto inválido recusa tudo: nem a nota fica
select pg_temp.falha(format($$select api.lancar_titulo(%L)$$, jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-881',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 900,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
                {"vencimento": "2026-12-20", "forma": "boleto", "boleto_linha": "1234"}]'::jsonb)),
  'lançar: boleto inválido numa parcela recusa o lançamento');
select pg_temp.ok(not exists (select 1 from erp.documentos_fiscais where numero = 'T-881'), 'lançar: a recusa não deixa a nota pela metade');
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-881',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 900.01,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
                {"vencimento": "2026-12-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb,
  'previsoes', '["8c000000-0000-0000-0000-000000000002"]'::jsonb,
  'etiquetas', '["8c000000-0000-0000-0000-000000000001"]'::jsonb)) as tlt \gset
select pg_temp.ok((select t.situacao = 'aberto' and t.valor = 900.01 and t.criado_por = :'diretor'
                     from erp.titulos t where t.id = :'tlt')
                  and (select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tlt') = array[450.01, 450]::numeric[]
                  and (select count(*) from erp.parcela_pagamentos where titulo_id = :'tlt') = 2
                  and exists (select 1 from erp.titulo_etiquetas where titulo_id = :'tlt' and etiqueta_id = '8c000000-0000-0000-0000-000000000001')
                  and (select valor from erp.titulo_previsoes where titulo_id = :'tlt' and previsao_id = '8c000000-0000-0000-0000-000000000002') = 500
                  and (select d.situacao from erp.documentos_fiscais d join erp.titulos t on t.documento_id = d.id where t.id = :'tlt') = 'lancado',
  'lançar: a nota vira título aberto, com as parcelas (o centavo na primeira, como o Sienge), a forma de pagamento, a etiqueta e a previsão consumida');
select pg_temp.falha(format($$select api.lancar_titulo(%L)$$, jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-881',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 900,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb)),
  'lançar: a mesma nota do mesmo fornecedor não entra duas vezes');
-- parcelas com o valor do documento (boletos de valores diferentes; pedido do Moises, 20/11/2026)
create temp table nota_val as select jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-885',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 300,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100))) j;
grant select on nota_val to public;
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || jsonb_build_object('parcelas',
  '[{"vencimento": "2026-11-20", "valor": 100, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
    {"vencimento": "2026-12-20", "valor": 150, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) from nota_val)),
  'As parcelas somam 250,00, e o valor líquido do título é 300,00', 'parcelas: os valores têm de somar o valor líquido');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || jsonb_build_object('parcelas',
  '[{"vencimento": "2026-11-20", "valor": 100, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
    {"vencimento": "2026-12-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) from nota_val)),
  'Informe o valor de todas as parcelas, ou de nenhuma', 'parcelas: valor em todas ou em nenhuma');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || jsonb_build_object('parcelas',
  '[{"vencimento": "2026-11-20", "valor": 300, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
    {"vencimento": "2026-12-20", "valor": 0, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) from nota_val)),
  'O valor de cada parcela é maior que zero, com até 2 casas', 'parcelas: parcela zerada não entra');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || jsonb_build_object('parcelas',
  '[{"vencimento": "2026-11-20", "valor": 100.005, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"},
    {"vencimento": "2026-12-20", "valor": 199.995, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) from nota_val)),
  'O valor de cada parcela é maior que zero, com até 2 casas', 'parcelas: mais de 2 casas não entra');
select pg_temp.ok(not exists (select 1 from erp.documentos_fiscais where numero = 'T-885'), 'parcelas: a recusa não deixa a nota');
select api.lancar_titulo((select j || jsonb_build_object('parcelas',
  '[{"vencimento": "2026-11-20", "valor": 100, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com", "pix_copia_cola": " 00020126410014br.gov.bcb.pix0119agencia@example.com5204000053039865406100.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63046CD8 "},
    {"vencimento": "2026-12-20", "valor": 200, "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) from nota_val)) as tval \gset
select pg_temp.ok((select valor = 300 from erp.titulos where id = :'tval')
                  and (select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tval') = array[100, 200]::numeric[]
                  and (select coalesce(sum(l.valor), 0) = -300 from erp.lancamentos l where l.titulo_id = :'tval' and l.estagio = 'comprometido'),
  'parcelas: cada parcela fica com o valor do documento, e o comprometido é o do título');
select pg_temp.ok((select pix_copia_cola = '00020126410014br.gov.bcb.pix0119agencia@example.com5204000053039865406100.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63046CD8' from erp.parcela_pagamentos where titulo_id = :'tval' and numero = 1)
                  and (select j->'parcelas'->0->>'pix_copia_cola' = '00020126410014br.gov.bcb.pix0119agencia@example.com5204000053039865406100.005802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63046CD8' and j->'parcelas'->1->'pix_copia_cola' = 'null'::jsonb from api.titulo(:'tval') j),
  'pix copia e cola: o Lançar título grava o código da parcela (sem os espaços das pontas) e a gaveta do título mostra');
select pg_temp.erro_igual(format($$select erp.lancar_documento(%L, array['2026-11-20','2026-12-20']::date[], null, array[300]::numeric[])$$,
                                 (select documento_id from erp.titulos where id = :'tval')),
  'O documento já foi lançado', 'parcelas: a função da nota continua recusando nota já lançada');
-- revisão de segurança do #102: a quantidade de valores e o líquido (com retenção) são conferidos
select pg_temp.como(null);
select pg_temp.sis();
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-000000000886', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', 'T-886', '2026-11-05', '2026-11-01', 300);
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento) values
  ('70000000-0000-0000-0000-000000000886', 'iss', 30, '10000000-0000-0000-0000-000000000006', '2026-12-10');
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-000000000886', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000886', array['2026-11-20','2026-12-20']::date[], null, array[270]::numeric[])$$,
  'Informe o valor de cada parcela', 'parcelas: menos valores que vencimentos é recusado, mesmo somando o líquido');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000886', array['2026-11-20','2026-12-20']::date[], null, array[100, 100, 70]::numeric[])$$,
  'Informe o valor de cada parcela', 'parcelas: mais valores que vencimentos é recusado, mesmo somando o líquido');
select pg_temp.erro_igual($$select erp.lancar_documento('70000000-0000-0000-0000-000000000886', array['2026-11-20','2026-12-20']::date[], null, array[100, 200]::numeric[])$$,
  'As parcelas somam 300,00, e o valor líquido do título é 270,00', 'parcelas: com retenção, a soma igual ao bruto é recusada');
select erp.lancar_documento('70000000-0000-0000-0000-000000000886', array['2026-11-20','2026-12-20']::date[], null, array[100, 170]::numeric[]) as tret \gset
select pg_temp.ok((select valor = 270 from erp.titulos where id = :'tret')
                  and (select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tret') = array[100, 170]::numeric[],
  'parcelas: com retenção, a soma igual ao líquido entra');
-- na revisão, o reenvio relança a nota com os mesmos valores
select pg_temp.como(null);
select pg_temp.sis(); insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing; select pg_temp.volta();
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'tval', false, 'conferir o fornecedor', true);
select pg_temp.como(:'diretor');
select erp.reenviar_titulo(:'tval', 'conferido') as tval2 \gset
select pg_temp.ok(:'tval2' <> :'tval' and (select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tval2') = array[100, 200]::numeric[],
  'parcelas: o reenvio da revisão mantém o valor de cada parcela');
-- outra quantidade de parcelas no reenvio: a divisão igual
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'tval2', false, 'três parcelas', true);
select pg_temp.como(:'diretor');
select erp.reenviar_titulo(:'tval2', 'em três', array['2026-11-20','2026-12-20','2027-01-20']::date[]) as tval3 \gset
select pg_temp.ok((select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tval3') = array[100, 100, 100]::numeric[],
  'parcelas: o reenvio com outra quantidade de parcelas volta à divisão igual');
-- retenção nova na revisão muda o líquido: os valores antigos não fecham e as parcelas saem iguais
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'tret', false, 'falta o IRRF', true);
select pg_temp.como(:'diretor');
insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento) values
  ('70000000-0000-0000-0000-000000000886', 'irrf', 20, '10000000-0000-0000-0000-000000000006', '2026-12-20');
select erp.reenviar_titulo(:'tret', 'IRRF incluído') as tret2 \gset
select pg_temp.ok((select valor = 250 from erp.titulos where id = :'tret2')
                  and (select array_agg(valor order by numero) from erp.parcelas where titulo_id = :'tret2') = array[125, 125]::numeric[],
  'parcelas: líquido mudado na revisão faz as parcelas saírem iguais, sem travar o reenvio');
select pg_temp.como(null);
select pg_temp.ok(erp._parcelas_iguais(1, 3) = array[0.34, 0.33, 0.33]::numeric[] and erp._parcelas_iguais(900.01, 2) = array[450.01, 450]::numeric[],
  'parcelas: a divisão igual é a do Sienge');
select pg_temp.ok(not has_function_privilege('authenticated', 'erp._parcelas_iguais(numeric, int)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp._liquido_documento(uuid)', 'EXECUTE')
                  and has_function_privilege('authenticated', 'erp.lancar_documento(uuid, date[], uuid[], numeric[])', 'EXECUTE')
                  and (select prosecdef and pg_get_userbyid(proowner) = 'erp_situacao' from pg_proc
                        where oid = 'erp.lancar_documento(uuid, date[], uuid[], numeric[])'::regprocedure)
                  and (select prosecdef and pg_get_userbyid(proowner) = 'erp_situacao' from pg_proc
                        where oid = 'erp.reenviar_titulo(uuid, text, date[], uuid[])'::regprocedure)
                  and not exists (select 1 from pg_proc where oid::regprocedure::text = 'erp.lancar_documento(uuid,date[],uuid[])'),
  'parcelas: a função da nota continua definer de erp_situacao, e a versão antiga saiu');
select pg_temp.como(:'diretor');
-- quem não lança na linha não lança pela tela (o perfil do erp vale aqui também)
select pg_temp.como(:'analista2');
select pg_temp.ok(not exists (select 1 from api.naturezas_lancaveis(:'ne_vm', :'cc_obra', null) n
                               where not erp.lanco(:'ne_vm', :'cc_obra', n.id, erp.eu())),
  'lançar: só aparecem as naturezas em que a pessoa lança');
-- o contrato preso à nota é conferido contra ela (revisão de segurança do #93)
select pg_temp.como(null);
select pg_temp.como(:'analista2');
select n.id as nat_a2 from api.naturezas_lancaveis(:'ne_vm', :'cc_obra', null) n order by n.codigo limit 1 \gset
select pg_temp.como(null);
select pg_temp.sis();
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, fim, periodicidade, valor_periodo, dia_vencimento)
values ('8c000000-0000-0000-0000-000000000003', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007',
        'Contrato que a pessoa não vê', '2026-01-01', '2026-12-31', 'mensal', 100, 10),
       ('8c000000-0000-0000-0000-000000000004', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007',
        'Contrato encerrado', '2026-01-01', '2026-12-31', 'mensal', 100, 10);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('8c000000-0000-0000-0000-000000000004', :'ne_vm', :'cc_obra', :'nat_a2', 100);
update erp.compromissos set situacao = 'encerrado' where id = '8c000000-0000-0000-0000-000000000004';
select pg_temp.volta();
select pg_temp.como(:'analista2');
create temp table nota_a2 as select jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-882',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 100,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_obra', 'natureza', :'nat_a2', 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) j;
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || '{"compromisso": "60000000-0000-0000-0000-000000000002"}' from nota_a2)),
  'O contrato é de outro fornecedor', 'lançar: a nota não se prende a contrato de outro fornecedor (CT-1)');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || '{"compromisso": "60000000-0000-0000-0000-000000000001"}' from nota_a2)),
  'O contrato é de outra empresa', 'lançar: a nota não se prende a contrato de outra empresa');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || '{"compromisso": "8c000000-0000-0000-0000-000000000003"}' from nota_a2)),
  'Contrato não encontrado', 'lançar: a nota não se prende a contrato que a pessoa não vê, e a resposta não diz de quem ele é');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || '{"compromisso": "8c000000-0000-0000-0000-000000000004"}' from nota_a2)),
  'O contrato não está ativo', 'lançar: a nota não se prende a contrato encerrado');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || '{"compromisso": "8c000000-0000-0000-0000-0000000000ff"}' from nota_a2)),
  'Contrato não encontrado', 'lançar: contrato que não existe é recusado');
select pg_temp.erro_igual(format($$insert into erp.titulos (empresa_id, tipo, pessoa_id, compromisso_id, emissao, competencia, valor)
  values (%L, 'avulso', '10000000-0000-0000-0000-000000000007', '60000000-0000-0000-0000-000000000002', '2026-11-05', '2026-11-01', 100)$$, :'spe'),
  'O contrato é de outro fornecedor', 'lançar: o título avulso também não se prende a contrato de outro credor');
-- o gatilho vale também na troca do contrato (ou do emitente, ou do credor) depois de gravado
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('8c000000-0000-0000-0000-000000000005', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', 'T-883', '2026-11-05', '2026-11-01', 100);
select pg_temp.erro_igual($$update erp.documentos_fiscais set compromisso_id = '60000000-0000-0000-0000-000000000002'
                             where id = '8c000000-0000-0000-0000-000000000005'$$,
  'O contrato é de outro fornecedor', 'lançar: a nota em rascunho não passa a apontar para contrato de outro fornecedor');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor)
values ('8c000000-0000-0000-0000-000000000006', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-11-05', '2026-11-01', 100);
select pg_temp.erro_igual($$update erp.titulos set compromisso_id = '60000000-0000-0000-0000-000000000002'
                             where id = '8c000000-0000-0000-0000-000000000006'$$,
  'O contrato é de outro fornecedor', 'lançar: o título avulso não passa a apontar para contrato de outro credor');
select pg_temp.como(:'analista2');
select pg_temp.ok(api.lancar_titulo((select j from nota_a2)) is not null, 'lançar: sem contrato, a mesma nota entra');
select pg_temp.como(null);
rollback;
-- a conferência da aprovação só responde sobre o que a pessoa vê (S-126)
select pg_temp.como(:'analista');
select pg_temp.ok(erp.previsao_aprovada_vista('00000000-0000-0000-0000-000000000000') is null
                  and erp.contrato_aprovado_visto('00000000-0000-0000-0000-000000000000') is null,
  'api: aprovação de previsão ou contrato que a pessoa não vê volta nula');
select pg_temp.como(null);
-- catálogo: o esquema api é todo invoker, e só authenticated executa
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'api' and p.prosecdef),
  'api: nenhuma função do esquema api passa por cima do RLS (todas são invoker)');
select pg_temp.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                               where n.nspname = 'api' and (has_function_privilege('anon', p.oid, 'EXECUTE')
                                                            or has_function_privilege('service_role', p.oid, 'EXECUTE')))
                  and not has_schema_privilege('anon', 'api', 'USAGE')
                  and not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'api'),
  'api: anon e service_role não executam nada do esquema api, e ele não tem tabela nem visão');

\echo '# anexo do título e o que casa com a nota lida (19/11/2026)'
select pg_temp.como(null);
begin;
select pg_temp.sis();
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor) values
  ('8d000000-0000-0000-0000-000000000001', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-11-01', '2026-11-20', 900),
  ('8d000000-0000-0000-0000-000000000002', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), '2026-03-01', '2026-03-20', 50);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, fim, periodicidade, valor_periodo, dia_vencimento)
values ('8d000000-0000-0000-0000-000000000003', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007',
        'Assinatura da agência', '2026-01-01', '2026-12-31', 'mensal', 950, 18);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('8d000000-0000-0000-0000-000000000003', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select pe.documento as doc_spe from erp.empresas e join erp.pessoas pe on pe.id = e.pessoa_id where e.id = :'spe' \gset
select pe.documento as doc_forn from erp.pessoas pe where pe.id = '10000000-0000-0000-0000-000000000007' \gset
select pg_temp.volta();
select pg_temp.como(:'leitor');
select pg_temp.falha($$select api.registrar_anexo('nota.pdf', 'application/pdf', 1000, repeat('a', 64))$$, 'anexo: quem só consulta não sobe arquivo');
select pg_temp.ok(api.identificar_nota('{}') is null, 'anexo: quem só consulta não recebe a identificação da nota');
select pg_temp.como(:'diretor');
select (api.registrar_anexo('NF 881.pdf', 'application/pdf', 1000, repeat('a', 64))->>'id') as anx \gset
select pg_temp.falha($$select api.registrar_anexo('nota.exe', 'application/x-msdownload', 1000, repeat('b', 64))$$, 'anexo: só PDF, XML e imagem');
select pg_temp.falha($$select api.registrar_anexo('nota.pdf', 'application/pdf', 1000, 'abc')$$, 'anexo: o sha256 tem 64 dígitos hexadecimais');
select pg_temp.falha(format($$insert into erp.anexos (nome, tipo_mime, tamanho, sha256, documento_id) values ('x.pdf', 'application/pdf', 1, %L, %L)$$,
                            repeat('c', 64), '8c000000-0000-0000-0000-000000000005'),
  'anexo: não nasce ligado a uma nota (a ligação é no lançamento)');
select api.gravar_leitura(:'anx', jsonb_build_object('valor', 900, 'emitente', :'doc_forn'));
select pg_temp.ok((select a.criado_por = :'diretor' and a.lido_em is not null and a.leitura->>'valor' = '900' from erp.anexos a where a.id = :'anx'),
  'anexo: o banco põe quem subiu e grava a leitura');
-- guias (Moises, 20/11/2026): tipos próprios e o CNPJ do órgão pelo código do recebedor na linha da guia
select pg_temp.ok(erp.sienge_documento('itbi') = 'ITBI' and erp.sienge_documento('darm') = 'DARM' and erp.sienge_documento('dare') = 'DARE'
                  and (select pg_get_constraintdef(oid) like '%darf%' from pg_constraint where conname = 'documentos_fiscais_tipo_check'),
  'guias: IPTU, ITBI, DARF, DARM e DARE são tipos de documento, com o documento de mesmo nome no Sienge');
select pg_temp.ok((select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'api' and p.prosrc like '%Tipo de documento inválido%' and p.prosrc like '%''darm''%')
                  and (select count(*) >= 2 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                        where n.nspname = 'api' and p.prosrc like '%when ''itbi'' then ''ITBI''%'),
  'guias: o Lançar título aceita os tipos novos e as telas mostram o nome deles');
select pg_temp.ok(erp.codigo_arrecadacao('816000000000100099990000000000000000000000000000') = array['1', '9999']
                  and erp.codigo_arrecadacao('86' || substr('816000000000100099990000000000000000000000000000', 3)) is null
                  and erp.codigo_arrecadacao('34191090080000000212134567890008899990000015000') is null,
  'guias: o código do recebedor sai da linha de arrecadação (segmento 6 e boleto de cobrança ficam de fora)');
select pg_temp.ok(erp.completar_recebedor('{"boletos": [{"linha": "826700000068278700970918102694590609329178721737"}]}')->'emitente'->>'documento' = '43776517000180',
  'guias: a carga inicial traz os órgãos que o financeiro usa no Sienge (código 0097 da conta de água)');
select pg_temp.como(:'analista');
select pg_temp.falha($$insert into erp.recebedores_arrecadacao values ('1', '9999', '11222333000181', 'PREFEITURA EXEMPLO')$$,
  'guias: ninguém pela API cadastra o órgão de um código (só por migration ou SQL do master)');
select pg_temp.como(:'diretor');
select pg_temp.falha($$insert into erp.recebedores_arrecadacao values ('1', '9999', '11222333000181', 'PREFEITURA EXEMPLO')$$,
  'guias: nem o master pela API');
select pg_temp.como_dono(null);
insert into erp.recebedores_arrecadacao values ('1', '9999', '11222333000181', 'PREFEITURA EXEMPLO');
select pg_temp.como(:'diretor');
select api.gravar_leitura(:'anx', jsonb_build_object('tipo', 'darm', 'emitente', jsonb_build_object('nome', ''),
                                                     'boletos', jsonb_build_array(jsonb_build_object('linha', '816000000000100099990000000000000000000000000000'))));
select pg_temp.ok((select a.leitura->'emitente'->>'documento' = '11222333000181' and a.leitura->'emitente'->>'nome' = 'PREFEITURA EXEMPLO'
                          and a.leitura->'avisos'->>0 like 'CNPJ do emitente pelo código do recebedor%' from erp.anexos a where a.id = :'anx'),
  'guias: sem o CNPJ lido, o emitente vem do código da guia, com aviso');
select api.gravar_leitura(:'anx', jsonb_build_object('emitente', jsonb_build_object('documento', :'doc_forn'),
                                                     'boletos', jsonb_build_array(jsonb_build_object('linha', '816000000000100099990000000000000000000000000000'))));
select pg_temp.ok((select a.leitura->'emitente'->>'documento' = :'doc_forn'
                          and a.leitura->'avisos'->>0 like 'O código do recebedor na linha da guia é de PREFEITURA EXEMPLO, e não do CNPJ%'
                          and jsonb_array_length(a.leitura->'avisos') = 1 from erp.anexos a where a.id = :'anx'),
  'guias: o CNPJ que o leitor achou fica como veio, com aviso quando o código da guia é de outro CNPJ');
select api.gravar_leitura(:'anx', jsonb_build_object('emitente', jsonb_build_object('documento', '11.222.333/0002-62'),
                                                     'boletos', jsonb_build_array(jsonb_build_object('linha', '816000000000100099990000000000000000000000000000'))));
select pg_temp.ok((select a.leitura->'emitente'->>'documento' = '11.222.333/0002-62' and a.leitura->'avisos' is null from erp.anexos a where a.id = :'anx'),
  'guias: outra filial do mesmo órgão (mesma raiz do CNPJ) não avisa');
select pg_temp.ok(erp.completar_recebedor(jsonb_build_object('emitente', jsonb_build_object('documento', :'doc_forn'),
                    'boletos', jsonb_build_array(jsonb_build_object('linha', '34191090080000000212134567890008899990000015000')))) ->'avisos' is null,
  'guias: boleto de cobrança não avisa divergência');
select api.gravar_leitura(:'anx', jsonb_build_object('valor', 900, 'emitente', :'doc_forn'));
select pg_temp.erro_igual(format($$update erp.anexos set sha256 = %L where id = %L$$, repeat('d', 64), :'anx'),
  'O arquivo do anexo não muda: suba outro', 'anexo: o arquivo (sha256, nome, tamanho) não muda depois de gravado');
-- quem não subiu não vê, não lê pela api, não muda a leitura nem apaga
select pg_temp.como(:'analista2');
select pg_temp.ok(not exists (select 1 from erp.anexos where id = :'anx') and api.anexo(:'anx') is null,
  'anexo: o anexo solto só quem subiu vê');
select pg_temp.erro_igual(format($$select api.gravar_leitura(%L, '{}')$$, :'anx'), 'Anexo não encontrado', 'anexo: outra pessoa não muda a leitura');
delete from erp.anexos where id = :'anx';
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.anexos where id = :'anx'), 'anexo: outra pessoa não apaga o anexo solto');
-- o que casa com a nota
select api.identificar_nota(jsonb_build_object('tomador', :'doc_spe', 'emitente', :'doc_forn', 'tipo', 'nfse', 'numero', '881',
                                                'valor', 900, 'emissao', '2026-11-05', 'vencimento', '2026-11-20')) as idn \gset
select pg_temp.ok((:'idn'::jsonb)->'empresa'->>'id' = :'spe' and (:'idn'::jsonb)->'fornecedor'->>'id' = '10000000-0000-0000-0000-000000000007'
                  and ((:'idn'::jsonb)->'fornecedor'->>'fornecedor')::boolean,
  'identificar: acha a empresa pelo CNPJ do tomador e o fornecedor pelo do emitente');
select pg_temp.ok((select c->>'id' from jsonb_array_elements((:'idn'::jsonb)->'candidatos') c limit 1) = '8d000000-0000-0000-0000-000000000001'
                  and (select (c->>'pontos')::int = 10 and c->'motivos' @> '["mesmo fornecedor", "mesmo valor", "data próxima"]'
                              and c->'rateio'->0->>'natureza' = pg_temp.nat('05.01.04')::text
                         from jsonb_array_elements((:'idn'::jsonb)->'candidatos') c where c->>'id' = '8d000000-0000-0000-0000-000000000001'),
  'identificar: a previsão do mesmo fornecedor, valor e data vem primeiro, com o rateio para preencher');
select pg_temp.ok(exists (select 1 from jsonb_array_elements((:'idn'::jsonb)->'candidatos') c
                           where c->>'id' = '8d000000-0000-0000-0000-000000000003' and c->>'tipo' = 'contrato'
                             and c->>'data' = '2026-11-18' and c->'motivos' @> '["valor próximo", "vencimento do contrato"]'
                             and jsonb_array_length(c->'rateio') = 1),
  'identificar: a assinatura do fornecedor entra, com o vencimento no dia dela e o valor do período');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements((:'idn'::jsonb)->'candidatos') c where c->>'id' = '8d000000-0000-0000-0000-000000000002'),
  'identificar: previsão de valor e data longe (só o fornecedor bate) fica de fora');
select pg_temp.ok(jsonb_array_length((:'idn'::jsonb)->'nota_repetida') = 0, 'identificar: sem nota repetida');
select pg_temp.ok((api.identificar_nota(jsonb_build_object('tomador', '00000000000000', 'emitente', '00000000000191', 'valor', 900)) ->> 'fornecedor') is null,
  'identificar: CNPJ que não está no cadastro volta sem empresa e sem fornecedor');
-- lança com o anexo; o anexo fica ligado e entra no rastro
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', '0881',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 900,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb,
  'previsoes', '["8d000000-0000-0000-0000-000000000001"]'::jsonb,
  'anexos', jsonb_build_array(:'anx'))) as tan \gset
select pg_temp.ok((select a.documento_id = t.documento_id and a.ligado_em is not null from erp.anexos a, erp.titulos t where a.id = :'anx' and t.id = :'tan')
                  and (select r->'anexos'->0->>'id' = :'anx' and r->'anexos'->0->>'nome' = 'NF 881.pdf' from api.titulo_rastro(:'tan') r),
  'anexo: o lançamento liga o anexo à nota, e o rastro do título mostra o arquivo');
select pg_temp.erro_igual(format($$select api.gravar_leitura(%L, '{}')$$, :'anx'), 'Anexo não encontrado', 'anexo: ligado à nota, nem quem subiu muda a leitura');
delete from erp.anexos where id = :'anx';
select pg_temp.ok(exists (select 1 from erp.anexos where id = :'anx'), 'anexo: ligado à nota, nem quem subiu apaga');
select pg_temp.ok((select jsonb_array_length(j->'repetido_em') = 1 and j->'repetido_em'->0->>'titulo_id' = :'tan'
                     from api.registrar_anexo('copia.pdf', 'application/pdf', 1000, repeat('a', 64)) j),
  'anexo: subir de novo o mesmo arquivo avisa a nota em que ele já está');
select pg_temp.ok((select jsonb_array_length(j->'nota_repetida') = 1 and j->'nota_repetida'->0->>'titulo_id' = :'tan'
                     from api.identificar_nota(jsonb_build_object('tomador', :'doc_spe', 'emitente', :'doc_forn', 'tipo', 'nfse', 'numero', '881')) j),
  'identificar: a nota com o mesmo número do mesmo emitente (zeros à esquerda não contam) volta como repetida');
select pg_temp.ok((select jsonb_array_length(j->'nota_repetida') = 1
                     from api.identificar_nota(jsonb_build_object('tomador', :'doc_spe', 'emitente', :'doc_forn', 'tipo', 'nfse', 'numero', '0.881')) j),
  'identificar: o aviso de nota repetida usa a mesma chave da trava (0.881 = 881)');
select pg_temp.como(null);
insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  select empresa_id, emitente_id, 'recibo', 's/n', '2026-11-05', '2026-11-01', 321 from erp.documentos_fiscais
   where id = (select documento_id from erp.titulos where id = :'tan') returning id as rsn \gset
select pg_temp.como(:'diretor');
select pg_temp.ok((select jsonb_array_length(j->'nota_repetida') = 1 and j->'nota_repetida'->0->>'documento_id' = :'rsn'
                     from api.identificar_nota(jsonb_build_object('tomador', :'doc_spe', 'emitente', :'doc_forn', 'tipo', 'recibo', 'numero', 'S/N',
                                                                  'valor', 321, 'emissao', '2026-11-05')) j)
                  and (select jsonb_array_length(j->'nota_repetida') = 0
                     from api.identificar_nota(jsonb_build_object('tomador', :'doc_spe', 'emitente', :'doc_forn', 'tipo', 'recibo', 'numero', 's/n',
                                                                  'valor', 322, 'emissao', '2026-11-05')) j),
  'identificar: sem número, avisa o documento do mesmo emitente e tipo com o mesmo valor e a mesma emissão');
select pg_temp.como(null);
delete from erp.documentos_fiscais where id = :'rsn';
select pg_temp.como(:'diretor');
select pg_temp.ok((select not p.prosecdef and not exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0)
                          and has_function_privilege('authenticated', p.oid, 'EXECUTE')
                     from pg_proc p where p.oid = 'api.identificar_nota(jsonb)'::regprocedure),
  'identificar: depois da troca da chave continua invoker e sem EXECUTE para public');
select pg_temp.ok((select j->'pagamento'->>'forma' = 'pix' and j->'pagamento'->>'pix_chave' = 'agencia@example.com'
                     from api.identificar_nota(jsonb_build_object('emitente', :'doc_forn')) j),
  'identificar: a última chave PIX usada com o fornecedor vem pré-selecionada');
-- quem não vê a nota não vê o anexo dela nem a repetição; o anexo de outra pessoa não se liga
select pg_temp.como(:'analista2');
create temp table anexo_ids as select :'anx'::uuid as anx, :'tan'::uuid as tit, (select documento_id from erp.titulos where id = :'tan') as doc;
grant select on anexo_ids to public;
select pg_temp.como(null);
do $$
declare r record; i record; j jsonb; c jsonb; n int := 0;
begin
  select * into i from anexo_ids;
  for r in select u.id::text as id from erp.usuarios u where u.ativo loop
    perform pg_temp.como(r.id);
    j := api.identificar_nota(jsonb_build_object('emitente', '77777777000177', 'tipo', 'nfse', 'numero', '881', 'valor', 950, 'vencimento', '2026-11-18'));
    if not erp.vejo_documento(i.doc) then
      n := n + 1;
      if exists (select 1 from erp.anexos where id = i.anx) or api.anexo(i.anx) is not null then
        raise exception 'FALHOU: % vê o anexo de uma nota que não vê', r.id; end if;
      if j is not null and (j->'nota_repetida')::text like '%' || i.doc || '%' then
        raise exception 'FALHOU: % recebe como repetida uma nota que não vê', r.id; end if;
    end if;
    if j is not null and not erp.vejo_titulo(i.tit) and j->'pagamento'->>'de_titulo' = i.tit::text then
      raise exception 'FALHOU: % recebe a chave PIX de um título que não vê', r.id; end if;
    for c in select x from jsonb_array_elements(coalesce(j->'candidatos', '[]')) x loop
      if (c->>'tipo' = 'previsao' and not erp.vejo_previsao((c->>'id')::uuid))
         or (c->>'tipo' = 'contrato' and not erp.vejo_compromisso((c->>'id')::uuid)) then
        raise exception 'FALHOU: % recebe candidato que não vê (%)', r.id, c->>'id'; end if;
    end loop;
  end loop;
  perform pg_temp.como(null);
  if n = 0 then raise exception 'FALHOU: (teste) nenhum usuário deixa de ver a nota'; end if;
end $$;
select pg_temp.ok(true, 'identificar: para cada usuário, o anexo, a nota repetida, a chave PIX e os candidatos só aparecem para quem os vê');
-- quem não vê nada do Marketing não recebe os candidatos dele
select pg_temp.como(:'analista2');
select (api.registrar_anexo('meu.pdf', 'application/pdf', 10, repeat('e', 64))->>'id') as anx2 \gset
select n.id as nat_b2 from api.naturezas_lancaveis(:'ne_vm', :'cc_obra', null) n order by n.codigo limit 1 \gset
create temp table nota_a2_anx as select jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'T-891',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 100,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_obra', 'natureza', :'nat_b2', 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb) j;
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, (select j || jsonb_build_object('anexos', jsonb_build_array(:'anx')) from nota_a2_anx)),
  'Anexo não encontrado ou já ligado a outra nota', 'anexo: o anexo de outra pessoa (ou já ligado) não entra no lançamento');
select pg_temp.falha(format($$update erp.anexos set documento_id = (select documento_id from erp.titulos where id = %L) where id = %L$$, :'tan', :'anx2'),
  'anexo: não se liga a nota de outra pessoa, mesmo uma em que ela lança');
select api.lancar_titulo((select j || jsonb_build_object('anexos', jsonb_build_array(:'anx2')) from nota_a2_anx)) as tan2 \gset
select pg_temp.ok((select a.documento_id = t.documento_id from erp.anexos a, erp.titulos t where a.id = :'anx2' and t.id = :'tan2'),
  'anexo: o próprio anexo solto entra no lançamento');
-- o rastro de um título não traz o anexo de outra nota; o aviso de arquivo repetido ignora nota cancelada
select pg_temp.como(:'diretor');
select pg_temp.ok((select jsonb_array_length(r->'anexos') = 1 and r->'anexos'->0->>'id' = :'anx' from api.titulo_rastro(:'tan') r)
                  and (select jsonb_array_length(r->'anexos') = 1 and r->'anexos'->0->>'id' = :'anx2' from api.titulo_rastro(:'tan2') r),
  'anexo: o rastro de cada título lista só os anexos da própria nota');
select pg_temp.sis();
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('8d000000-0000-0000-0000-000000000009', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', 'T-899', '2026-11-05', '2026-11-01', 100);
insert into erp.anexos (id, nome, tipo_mime, tamanho, sha256) values ('8d000000-0000-0000-0000-00000000000a', 'cancelada.pdf', 'application/pdf', 10, repeat('f', 64));
update erp.anexos set documento_id = '8d000000-0000-0000-0000-000000000009' where id = '8d000000-0000-0000-0000-00000000000a';
set local role erp_situacao;
update erp.documentos_fiscais set situacao = 'cancelado' where id = '8d000000-0000-0000-0000-000000000009';
reset role;
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.ok((select jsonb_array_length(j->'repetido_em') = 0 from api.registrar_anexo('de novo.pdf', 'application/pdf', 10, repeat('f', 64)) j)
                  and exists (select 1 from erp.anexos where id = '8d000000-0000-0000-0000-00000000000a'),
  'anexo: o mesmo arquivo de uma nota cancelada não conta como repetido');
select pg_temp.como(null);
rollback;

\echo '# tela Para aprovar (api.aprovacoes e api.decidir, 19/11/2026)'
select pg_temp.como(null);
-- transação só de leitura (GET do PostgREST): erro claro, nunca "não é a vez" em tudo (revisão de segurança do #95)
select pg_temp.como(:'gestor');
begin read only;
select pg_temp.erro_igual('select * from api.aprovacoes()', 'api.aprovacoes precisa de transação de escrita (chamar por POST)', 'aprovar: só leitura dá erro claro');
rollback;
select pg_temp.como(null);
begin;
select pg_temp.sis();
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'analista');
select n.id as nat_ap from api.naturezas_lancaveis(:'ne_vm', :'cc_mkt', null) n order by n.codigo limit 1 \gset
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'AP-1',
  'emissao', '2026-11-05', 'competencia', '2026-11-01', 'valor', 900,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', :'nat_ap', 'percentual', 100)),
  'parcelas', '[{"vencimento": "2026-11-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb)) as tap \gset
select pg_temp.como(null);
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing;
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, fim, periodicidade, valor_periodo, dia_vencimento)
values ('8e000000-0000-0000-0000-000000000001', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007',
        'Assinatura para aprovar', '2026-01-01', '2026-12-31', 'mensal', 300, 10);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
values ('8e000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_mkt', :'nat_ap', 100);
select pg_temp.volta();
create temp table apr_conta as select (select count(*) from erp.titulo_aprovacoes) + (select count(*) from erp.compromisso_aprovacoes)
                                      + (select count(*) from erp.previsao_aprovacoes) as n;
grant select on apr_conta to public;
-- quem só consulta não recebe nada; quem não vê o título não recebe a linha dele
select pg_temp.como(:'leitor');
select pg_temp.ok(not exists (select 1 from api.aprovacoes()), 'aprovar: quem só consulta não recebe a lista');
select pg_temp.falha(format($$select api.decidir('titulo', %L, 'aprovar')$$, :'tap'), 'aprovar: quem só consulta não decide');
-- a vez: o gestor do centro primeiro; quem lançou vê o motivo
select pg_temp.como(:'gestor');
select pg_temp.ok((select a.vez and a.esperando = 'gestor do centro, depois AF' and a.area = 'Marketing' and a.valor = 900
                     from api.aprovacoes() a where a.tipo = 'titulo' and a.id = :'tap'),
  'aprovar: é a vez do gestor do centro, e a linha diz quem ainda falta');
select pg_temp.como(:'analista');
select pg_temp.ok((select not a.vez and a.motivo = 'Quem lançou não aprova o próprio lançamento' from api.aprovacoes() a where a.tipo = 'titulo' and a.id = :'tap'),
  'aprovar: quem lançou vê a linha sem a vez, com o motivo');
select pg_temp.como(:'contador');
select pg_temp.ok((select not a.vez and a.motivo = 'Esta fase de aprovação é do gestor da área' from api.aprovacoes() a where a.tipo = 'titulo' and a.id = :'tap'),
  'aprovar: a AF espera a fase do gestor (em sequência)');
-- a simulação não grava nada (master aprovaria tudo de uma vez)
select pg_temp.como(:'diretor');
select pg_temp.ok((select bool_and(a.vez) from api.aprovacoes() a where a.id in (:'tap', '8e000000-0000-0000-0000-000000000001'))
                  and (select n from apr_conta) = (select count(*) from erp.titulo_aprovacoes) + (select count(*) from erp.compromisso_aprovacoes)
                                                   + (select count(*) from erp.previsao_aprovacoes)
                  and erp.etapa_titulo(:'tap') = 'aprovacao',
  'aprovar: listar simula a decisão e não deixa nenhuma aprovação gravada (nem a do master)');
-- decidir pela api
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select api.decidir('titulo', %L, 'recusar')$$, :'tap'), 'Recusar exige justificativa', 'aprovar: recusar exige justificativa');
select pg_temp.erro_igual(format($$select api.decidir('titulo', %L, 'talvez')$$, :'tap'), 'Decisão inválida', 'aprovar: decisão desconhecida é recusada');
select pg_temp.erro_igual($$select api.decidir('contrato', '8e000000-0000-0000-0000-000000000001', 'revisao', 'x')$$, 'Só o título volta para revisão',
  'aprovar: só o título volta para revisão');
select pg_temp.ok(api.decidir('titulo', :'tap', 'aprovar') = 'pendente', 'aprovar: o gestor aprova e falta a AF');
select pg_temp.ok((select not a.vez from api.aprovacoes() a where a.tipo = 'titulo' and a.id = :'tap'), 'aprovar: depois de aprovar, a vez sai do gestor');
select pg_temp.como(:'contador');
select pg_temp.ok((select a.vez and a.esperando = 'AF' from api.aprovacoes() a where a.tipo = 'titulo' and a.id = :'tap'), 'aprovar: agora é a vez da AF');
select api.decidir('titulo', :'tap', 'aprovar') as dec_af \gset
select pg_temp.ok(:'dec_af' = 'aprovado' and erp.etapa_titulo(:'tap') = 'aprovado'
                  and not exists (select 1 from api.aprovacoes() a where a.id = :'tap'),
  'aprovar: a AF aprova, o título sai da lista e segue para o Sienge');
-- contrato recorrente: gestor do centro e AF ou AD, em qualquer ordem
select pg_temp.ok((select a.vez and a.esperando like '%gestor de Marketing%' and a.esperando like '%AF ou AD%'
                     from api.aprovacoes() a where a.tipo = 'contrato' and a.id = '8e000000-0000-0000-0000-000000000001'),
  'aprovar: o contrato recorrente aparece com as vagas que faltam');
select pg_temp.ok(api.decidir('contrato', '8e000000-0000-0000-0000-000000000001', 'aprovar') = 'pendente', 'aprovar: a AF aprova o contrato e falta o gestor');
select pg_temp.como(:'gestor');
select api.decidir('contrato', '8e000000-0000-0000-0000-000000000001', 'recusar', 'Valor acima do combinado') as dec_ct \gset
select pg_temp.ok(:'dec_ct' = 'recusado'
                  and not exists (select 1 from api.aprovacoes() a where a.id = '8e000000-0000-0000-0000-000000000001'),
  'aprovar: o gestor recusa com justificativa e o contrato sai da lista');
-- previsão lançada à mão: a mesma alçada do título
select pg_temp.como(:'analista');
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
values ('8e000000-0000-0000-0000-000000000002', :'spe', 'manual', '10000000-0000-0000-0000-000000000007', :'ne_vm', :'cc_mkt', :'nat_ap', '2026-12-01', '2026-12-10', 400);
select pg_temp.ok((select not a.vez and a.motivo is not null from api.aprovacoes() a where a.tipo = 'previsao' and a.id = '8e000000-0000-0000-0000-000000000002'),
  'aprovar: quem lançou a previsão vê a linha sem a vez');
select pg_temp.como(:'gestor');
select pg_temp.ok((select a.vez and a.data = '2026-12-10' and a.valor = 400 from api.aprovacoes() a where a.tipo = 'previsao' and a.id = '8e000000-0000-0000-0000-000000000002'),
  'aprovar: a previsão à mão aparece na vez do gestor do centro');
select pg_temp.ok(api.decidir('previsao', '8e000000-0000-0000-0000-000000000002', 'aprovar') in ('pendente', 'aprovado'), 'aprovar: o gestor aprova a previsão pela api');
-- para cada usuário, a lista só tem o que ele vê
select pg_temp.como(null);
do $$
declare r record; x record;
begin
  for r in select u.id::text as id from erp.usuarios u where u.ativo loop
    perform pg_temp.como(r.id);
    for x in select * from api.aprovacoes() loop
      if (x.tipo = 'titulo' and not erp.vejo_titulo(x.id)) or (x.tipo = 'previsao' and not erp.vejo_previsao(x.id))
         or (x.tipo = 'contrato' and not erp.vejo_compromisso(x.id)) then
        raise exception 'FALHOU: % recebe na lista de aprovação % que não vê', r.id, x.id;
      end if;
    end loop;
  end loop;
  perform pg_temp.como(null);
end $$;
select pg_temp.ok(true, 'aprovar: para cada usuário, a lista só traz títulos, previsões e contratos que ele vê');
select pg_temp.como(null);
rollback;

\echo '# contas recorrentes pela tela (api.salvar_conta e conta de consumo, 20/11/2026)'
select pg_temp.como(null);
begin;
select pg_temp.sis();
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'analista');
select n.id as nat_cr from api.naturezas_lancaveis(:'ne_vm', :'cc_mkt', null) n order by n.codigo limit 1 \gset
select jsonb_build_object('empresa', :'spe', 'tipo', 'consumo', 'fornecedor', '10000000-0000-0000-0000-000000000007',
         'descricao', 'Luz do PDV', 'inicio', '2026-11-01', 'dia_vencimento', 6, 'instalacao', '0012.345-6',
         'faixa_mensal', 1500, 'teto_anual', 16000,
         'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', :'nat_cr', 'percentual', 100))) as cbase \gset
-- quem só consulta não grava
select pg_temp.como(:'leitor');
select pg_temp.falha(format('select api.salvar_conta(%L::jsonb)', :'cbase'), 'conta: quem só consulta não cadastra');
-- a conta de consumo pede instalação, faixa e teto; o rateio soma 100%
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', (:'cbase'::jsonb - 'instalacao')::text),
  'Informe a instalação, a média esperada por mês e o teto no ano', 'conta: consumo sem instalação é recusado');
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', jsonb_set(:'cbase'::jsonb, '{rateio,0,percentual}', '60')::text),
  'O rateio precisa somar 100%', 'conta: rateio que não soma 100% é recusado');
select api.salvar_conta(:'cbase'::jsonb) as ccons \gset
select pg_temp.ok((select c.tipo = 'consumo' and c.periodicidade = 'mensal' and c.faixa_mensal = 1500
                     and c.valor_periodo is null from erp.compromissos c where c.id = :'ccons'), 'conta: consumo gravado, mensal');
select aprovacao_versao as cver from erp.compromissos where id = :'ccons' \gset
select pg_temp.ok((select not x.aprovado and x.instalacao = '0012.345-6' and x.teto_anual = 16000 and x.posso_alterar
                     from api.contratos() x where x.id = :'ccons'), 'conta: aparece na lista, em aprovação, e quem lançou altera');
-- a mesma instalação (escrita de outro jeito) do mesmo fornecedor na mesma empresa não entra duas vezes
select pg_temp.falha(format('select api.salvar_conta(%L::jsonb)', jsonb_set(:'cbase'::jsonb, '{instalacao}', '"00123456"')::text),
  'conta: a mesma instalação não entra duas vezes');
-- vai para a tela Para aprovar com a faixa como valor; o gestor tem a vez, quem lançou não
select pg_temp.como(:'gestor');
select pg_temp.ok((select a.vez and a.valor = 1500 from api.aprovacoes() a where a.tipo = 'contrato' and a.id = :'ccons'),
  'conta: consumo na tela Para aprovar, na vez do gestor, pela faixa');
select pg_temp.como(:'analista');
select pg_temp.ok((select not a.vez from api.aprovacoes() a where a.tipo = 'contrato' and a.id = :'ccons'), 'conta: quem lançou não aprova a conta');
-- api.conta devolve o cadastro para alterar
select pg_temp.ok((select (x->>'instalacao') = '0012.345-6' and jsonb_array_length(x->'rateio') = 1
                     and (x->'rateio'->0->>'percentual')::numeric = 100 from api.conta(:'ccons') x), 'conta: o cadastro volta para a tela de alterar');
-- alterar sem mudar nada não reabre a aprovação; mudar a faixa reabre
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('id', :'ccons'));
select pg_temp.ok((select aprovacao_versao = :cver from erp.compromissos where id = :'ccons'), 'conta: salvar igual não muda a versão');
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'faixa_mensal', 1800));
select pg_temp.ok((select aprovacao_versao = :cver + 1 and faixa_mensal = 1800 from erp.compromissos where id = :'ccons'), 'conta: mudar a faixa pede aprovação de novo');
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'faixa_mensal', 1800, 'instalacao', '0099'));
select pg_temp.ok((select aprovacao_versao = :cver + 2 and instalacao = '0099' from erp.compromissos where id = :'ccons'), 'conta: mudar a instalação pede aprovação de novo');
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'faixa_mensal', 1800, 'instalacao', '0099', 'teto_anual', 99000));
select pg_temp.ok((select aprovacao_versao = :cver + 3 and teto_anual = 99000 from erp.compromissos where id = :'ccons'), 'conta: mudar o teto pede aprovação de novo');
-- o vencimento do consumo é opcional e muda sem nova aprovação (é o que a fatura traz; Moises, 20/11/2026)
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'faixa_mensal', 1800, 'instalacao', '0099', 'teto_anual', 99000, 'dia_vencimento', 12));
select pg_temp.ok((select aprovacao_versao = :cver + 3 and dia_vencimento = 12 from erp.compromissos where id = :'ccons'), 'conta: mudar o vencimento do consumo não pede aprovação de novo');
select api.salvar_conta((:'cbase'::jsonb - 'dia_vencimento') || jsonb_build_object('id', :'ccons', 'faixa_mensal', 1800, 'instalacao', '0099', 'teto_anual', 99000));
select pg_temp.ok((select aprovacao_versao = :cver + 3 and dia_vencimento is null from erp.compromissos where id = :'ccons'), 'conta: o consumo fica sem vencimento');
-- quem só lê vê a conta sem poder alterar; quem não lança no centro também não
select pg_temp.como(:'leitor');
select pg_temp.ok((select coalesce(bool_and(not x.posso_alterar), true) and count(*) > 0 from api.contratos() x where x.id = :'ccons'), 'conta: quem só lê vê a conta e não altera');
select pg_temp.sis();
insert into erp.excecoes_centro (user_id, nucleo_economico_id, centro_custo_id, nivel) values (:'analista2', :'ne_vm', :'cc_mkt', 'leitor')
  on conflict (user_id, nucleo_economico_id, centro_custo_id) do update set nivel = 'leitor', fim = null;
select pg_temp.volta();
select pg_temp.como(:'analista2');
select pg_temp.ok((select coalesce(bool_and(not x.posso_alterar), true) and count(*) > 0 from api.contratos() x where x.id = :'ccons'), 'conta: quem vê e não lança no centro não altera');
select pg_temp.como(:'analista');
-- o tipo não muda pela alteração
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', (:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'tipo', 'assinatura',
  'valor_periodo', 100, 'periodicidade', 'mensal'))::text), 'Conta não encontrada, encerrada ou sem permissão para alterar', 'conta: o tipo não muda');
-- contrato de serviço por valor total e assinatura mensal
select api.salvar_conta(jsonb_build_object('empresa', :'spe', 'tipo', 'contrato', 'fornecedor', '10000000-0000-0000-0000-000000000007',
  'descricao', 'Agência 12 meses', 'inicio', '2026-12-01', 'fim', '2027-11-30', 'valor_total', 24000, 'instalacao', 'X',
  'rateio', :'cbase'::jsonb->'rateio')) as cctr \gset
select pg_temp.ok((select c.tipo = 'contrato' and c.valor_total = 24000 and c.instalacao is null from erp.compromissos c where c.id = :'cctr'),
  'conta: contrato de serviço gravado sem campos de consumo');
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', jsonb_build_object('empresa', :'spe', 'tipo', 'assinatura',
  'fornecedor', '10000000-0000-0000-0000-000000000007', 'descricao', 'Software', 'inicio', '2026-12-01', 'valor_periodo', 200,
  'rateio', :'cbase'::jsonb->'rateio')::text), 'Informe o valor e a periodicidade', 'conta: assinatura sem periodicidade é recusada');
-- conta encerrada não se altera e sai do "posso alterar"
select pg_temp.sis();
update erp.compromissos set situacao = 'encerrado' where id = :'ccons';
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', (:'cbase'::jsonb || jsonb_build_object('id', :'ccons', 'faixa_mensal', 2000))::text),
  'Conta não encontrada, encerrada ou sem permissão para alterar', 'conta: conta encerrada não se altera');
select pg_temp.ok((select not x.posso_alterar from api.contratos() x where x.id = :'ccons'), 'conta: conta encerrada sai do posso alterar');
-- contrato sem nada ligado: o fornecedor e o valor mudam (corrige cadastro errado)
select api.salvar_conta(jsonb_build_object('id', :'cctr', 'empresa', :'spe', 'tipo', 'contrato', 'fornecedor', '10000000-0000-0000-0000-000000000005',
  'descricao', 'Agência 12 meses', 'inicio', '2026-12-01', 'fim', '2027-11-30', 'valor_total', 1, 'rateio', :'cbase'::jsonb->'rateio'));
select pg_temp.ok((select pessoa_id = '10000000-0000-0000-0000-000000000005' and valor_total = 1 from erp.compromissos where id = :'cctr'),
  'conta: sem nota, título ou previsão, o fornecedor e o valor mudam');
-- contrato só com nota (cancelada): já está ligado, mas o cancelado não conta no lançado
select pg_temp.sis();
update erp.compromissos set valor_total = 10000 where id = :'cctr';
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto, situacao)
values ('70000000-0000-0000-0000-0000000096a1', :'spe', '10000000-0000-0000-0000-000000000005', :'cctr', 'nfse', '96-1', '2026-12-05', '2026-12-01', 4000, 'rascunho');
set local role erp_situacao;
update erp.documentos_fiscais set situacao = 'cancelado' where id = '70000000-0000-0000-0000-0000000096a1';
reset role;
select pg_temp.ok((select v.ligado and v.lancado = 0 from erp.compromisso_vinculos(:'cctr') v), 'conta: contrato só com nota cancelada está ligado e não tem lançado');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format('update erp.compromissos set pessoa_id = %L where id = %L', '10000000-0000-0000-0000-000000000007', :'cctr'),
  'O fornecedor não muda: o contrato já tem nota, título ou previsão; encerre e cadastre outro', 'conta: contrato só com nota não troca de fornecedor');
-- título sem nota conta no lançado; nota não cancelada também
select pg_temp.sis();
select pg_temp.como(:'analista');
set local role erp_situacao;
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, compromisso_id, emissao, competencia, valor, situacao)
values ('81000000-0000-0000-0000-0000000096a1', :'spe', 'avulso', '10000000-0000-0000-0000-000000000005', :'cctr', '2026-12-05', '2026-12-01', 300, 'rascunho');
reset role;
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
values ('70000000-0000-0000-0000-0000000096a2', :'spe', '10000000-0000-0000-0000-000000000005', :'cctr', 'nfse', '96-2', '2026-12-05', '2026-12-01', 200);
select pg_temp.ok((select v.lancado = 500 from erp.compromisso_vinculos(:'cctr') v), 'conta: lançado = título sem nota + nota não cancelada');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.falha(format('update erp.compromissos set valor_total = 499.99 where id = %L', :'cctr'), 'conta: o valor não fica abaixo do título sem nota + nota');
-- direto no banco, sem a api: consumo sem instalação é recusado
select pg_temp.falha(format($$insert into erp.compromissos (empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, dia_vencimento, faixa_mensal, teto_anual)
  values (%L, 'consumo', '10000000-0000-0000-0000-000000000007', 'X', '2026-12-01', 'mensal', 5, 10, 100)$$, :'spe'), 'conta: consumo sem instalação é recusado também direto no banco');
-- contrato com nota ligada (CT-1, revisão do #96): o fornecedor não muda e o valor não fica abaixo do lançado, em qualquer caminho
select pg_temp.sis();
select pg_temp.ok((select v.ligado and v.lancado > 1 from erp.compromisso_vinculos('60000000-0000-0000-0000-000000000002') v),
  'conta: (teste) o CT-1 tem nota ligada e valor lançado');
select (erp.compromisso_vinculos('60000000-0000-0000-0000-000000000002')).lancado as ct1_lanc \gset
select pg_temp.volta();
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$update erp.compromissos set pessoa_id = '10000000-0000-0000-0000-000000000007' where id = '60000000-0000-0000-0000-000000000002'$$,
  'O fornecedor não muda: o contrato já tem nota, título ou previsão; encerre e cadastre outro', 'conta: o fornecedor do contrato com nota não muda');
select pg_temp.falha($$update erp.compromissos set valor_total = 1 where id = '60000000-0000-0000-0000-000000000002'$$,
  'conta: o valor do contrato não fica abaixo do já lançado');
select pg_temp.falha(format('update erp.compromissos set valor_total = %s where id = %L', :ct1_lanc - 0.01, '60000000-0000-0000-0000-000000000002'),
  'conta: um centavo abaixo do lançado também é recusado');
update erp.compromissos set valor_total = :ct1_lanc where id = '60000000-0000-0000-0000-000000000002';
select pg_temp.ok((select valor_total = :ct1_lanc from erp.compromissos where id = '60000000-0000-0000-0000-000000000002'),
  'conta: o valor igual ao lançado é aceito');
-- corrida (revisão do #96): a troca de fornecedor ou valor e a nota no mesmo contrato tomam a mesma trava; não se
-- testa a espera numa conexão só, então confere que os dois gatilhos a tomam
select pg_temp.ok((select bool_and(pg_get_functiondef(f) like '%pg_advisory_xact_lock(hashtext(''erp.compromisso:''%')
                     from unnest(array['erp.tg_compromisso_vinculado()'::regprocedure, 'erp.tg_contrato_confere()'::regprocedure]) f),
  'conta: o contrato e a nota que entra nele tomam a mesma trava');

-- previsão mês a mês (Moises, 23/11/2026). A conferência do calendário roda no fim da transação; aqui, que tudo é
-- uma transação só, "set constraints ... immediate" a roda na hora.
select pg_temp.como(:'analista');
select jsonb_build_object('empresa', :'spe', 'tipo', 'contrato', 'fornecedor', '10000000-0000-0000-0000-000000000007',
         'descricao', 'Agência trimestre', 'inicio', '2027-01-01', 'fim', '2027-03-31', 'valor_total', 3000,
         'rateio', :'cbase'::jsonb->'rateio') as kbase \gset
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('meses', jsonb_build_array(
  jsonb_build_object('mes', '2027-01-01', 'valor', 1000), jsonb_build_object('mes', '2027-02-01', 'valor', 500),
  jsonb_build_object('mes', '2027-03-01', 'valor', 1500)))) as kctr \gset
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.ok((select jsonb_array_length(x->'meses') = 3 and (x->'meses'->1->>'valor')::numeric = 500 and x->'trava_antes' = 'null'::jsonb
                     from api.conta(:'kctr') x), 'mês a mês: o contrato grava um valor por mês e devolve o calendário');
select aprovacao_versao as kver from erp.compromissos where id = :'kctr' \gset
-- cada caso errado: grava, roda a conferência e volta
savepoint sp_mes;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'meses', jsonb_build_array(
  jsonb_build_object('mes', '2027-01-01', 'valor', 1000), jsonb_build_object('mes', '2027-02-01', 'valor', 500),
  jsonb_build_object('mes', '2027-03-01', 'valor', 1000))));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'A soma dos meses (R$ 2.500,00) não bate com o valor do contrato (R$ 3.000,00)', 'mês a mês: a soma tem de bater com o valor do contrato');
rollback to savepoint sp_mes;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'valor_total', 3500));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'A soma dos meses (R$ 3.000,00) não bate com o valor do contrato (R$ 3.500,00)', 'mês a mês: mudar só o valor do contrato também confere a soma');
rollback to savepoint sp_mes;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'meses', jsonb_build_array(
  jsonb_build_object('mes', '2027-01-01', 'valor', 1000), jsonb_build_object('mes', '2027-02-01', 'valor', 2000))));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'O calendário do contrato precisa ter todos os meses da vigência', 'mês a mês: o contrato tem todos os meses da vigência');
rollback to savepoint sp_mes;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'meses', jsonb_build_array(
  jsonb_build_object('mes', '2027-01-01', 'valor', 1000), jsonb_build_object('mes', '2027-02-01', 'valor', 500),
  jsonb_build_object('mes', '2027-03-01', 'valor', 1000), jsonb_build_object('mes', '2027-04-01', 'valor', 500))));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'Há mês do calendário fora da vigência', 'mês a mês: mês fora da vigência é recusado');
rollback to savepoint sp_mes;
select api.salvar_conta((:'kbase'::jsonb - 'fim') || jsonb_build_object('id', :'kctr'));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'Contrato com previsão mês a mês precisa da data de fim', 'mês a mês: contrato com calendário tem data de fim');
rollback to savepoint sp_mes;
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', (:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'meses',
  jsonb_build_array(jsonb_build_object('mes', '2027-01-01', 'valor', -1))))::text),
  'Cada mês precisa da data e de um valor (zero ou mais)', 'mês a mês: valor negativo é recusado');
rollback to savepoint sp_mes;
set constraints erp.t_meses_conferem deferred;
-- mudar um mês: versão nova (volta para a aprovação); salvar sem mandar os meses não mexe neles
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr'));
select pg_temp.ok((select aprovacao_versao = :kver from erp.compromissos where id = :'kctr')
                  and (select count(*) = 3 from erp.compromisso_meses where compromisso_id = :'kctr'),
  'mês a mês: salvar sem os meses não mexe no calendário nem na versão');
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'meses', jsonb_build_array(
  jsonb_build_object('mes', '2027-01-01', 'valor', 1200), jsonb_build_object('mes', '2027-02-01', 'valor', 500),
  jsonb_build_object('mes', '2027-03-01', 'valor', 1300))));
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.ok((select aprovacao_versao > :kver and alterado_por = :'analista' from erp.compromissos where id = :'kctr'),
  'mês a mês: mudar um mês pede aprovação de novo');
-- assinatura bimestral não tem calendário; consumo: os meses do ano até o teto
savepoint sp_mes;
select api.salvar_conta(jsonb_build_object('empresa', :'spe', 'tipo', 'assinatura', 'fornecedor', '10000000-0000-0000-0000-000000000007',
  'descricao', 'Software bimestral', 'inicio', '2027-01-01', 'valor_periodo', 200, 'periodicidade', 'bimestral', 'rateio', :'cbase'::jsonb->'rateio',
  'meses', jsonb_build_array(jsonb_build_object('mes', '2027-01-01', 'valor', 200))));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'A previsão mês a mês só vale para conta mensal', 'mês a mês: assinatura bimestral não tem calendário');
rollback to savepoint sp_mes;
select api.salvar_conta(:'cbase'::jsonb || jsonb_build_object('instalacao', 'C-2', 'faixa_mensal', 1000, 'teto_anual', 5000, 'inicio', '2027-01-01',
  'meses', (select jsonb_agg(jsonb_build_object('mes', m, 'valor', 1000)) from generate_series('2027-01-01'::date, '2027-06-01', '1 month') m)));
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'Os meses de 2027 somam R$ 6.000,00, acima do teto no ano (R$ 5.000,00)', 'mês a mês: no consumo, os meses do ano não passam do teto');
rollback to savepoint sp_mes;
set constraints erp.t_meses_conferem deferred;
-- o valor de cada mês nas previsões; sem fim, depois do último mês vale o último; mês com zero não gera previsão
select api.salvar_conta(jsonb_build_object('empresa', :'spe', 'tipo', 'assinatura', 'fornecedor', '10000000-0000-0000-0000-000000000007',
  'descricao', 'Software mensal', 'inicio', '2027-01-01', 'valor_periodo', 100, 'periodicidade', 'mensal', 'dia_vencimento', 10,
  'rateio', :'cbase'::jsonb->'rateio', 'meses', jsonb_build_array(jsonb_build_object('mes', '2027-01-01', 'valor', 100),
  jsonb_build_object('mes', '2027-02-01', 'valor', 0), jsonb_build_object('mes', '2027-03-01', 'valor', 250)))) as kass \gset
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.ok(erp.valor_do_mes(:'kass', '2027-01-15') = 100 and erp.valor_do_mes(:'kass', '2027-02-01') = 0
                  and erp.valor_do_mes(:'kass', '2027-07-01') = 250 and erp.valor_do_mes(:'kctr', '2027-03-01') = 1300,
  'mês a mês: o valor do mês é o do calendário e, sem fim, depois do último vale o último');
select pg_temp.sis();
select erp.gerar_previsoes_assinatura(:'kass', '2027-04-30');
select pg_temp.ok((select count(distinct competencia) = 3 and sum(valor) = 600
                          and bool_and(competencia in ('2027-01-01', '2027-03-01', '2027-04-01'))
                     from erp.previsoes where compromisso_id = :'kass'),
  'mês a mês: as previsões da assinatura saem com o valor de cada mês, e o mês com zero não gera previsão');
-- depois da primeira aprovação, mês que já passou não muda
select jsonb_build_object('empresa', :'spe', 'tipo', 'contrato', 'fornecedor', '10000000-0000-0000-0000-000000000007',
         'descricao', 'Contrato em curso', 'inicio', erp.mes(current_date) - interval '2 months',
         'fim', erp.mes(current_date) + interval '2 months' - interval '1 day', 'valor_total', 400, 'rateio', :'cbase'::jsonb->'rateio') as pbase,
       jsonb_build_object('mes', erp.mes(current_date) - interval '2 months', 'valor', 100) as pm2,
       jsonb_build_object('mes', erp.mes(current_date) - interval '1 month', 'valor', 100) as pm1,
       erp.mes(current_date) as p0, erp.mes((current_date + interval '1 month')::date) as p1 \gset
select pg_temp.volta();
select api.salvar_conta(:'pbase'::jsonb || jsonb_build_object('meses', jsonb_build_array(:'pm2'::jsonb, :'pm1'::jsonb,
  jsonb_build_object('mes', :'p0', 'valor', 100), jsonb_build_object('mes', :'p1', 'valor', 100)))) as kcur \gset
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.sis();
set local role erp_situacao;
insert into erp.compromisso_aprovacoes (compromisso_id, versao, vaga, aprovado, por)
select id, aprovacao_versao, 'FIN', true, :'contador' from erp.compromissos where id = :'kcur';
reset role;
select pg_temp.volta();
select pg_temp.ok((select (x->>'trava_antes')::date = :'p0'::date from api.conta(:'kcur') x), 'mês a mês: a conta aprovada diz desde que mês o calendário muda');
select pg_temp.erro_igual(format('select api.salvar_conta(%L::jsonb)', (:'pbase'::jsonb || jsonb_build_object('id', :'kcur', 'meses', jsonb_build_array(
  jsonb_set(:'pm2'::jsonb, '{valor}', '50'), :'pm1'::jsonb, jsonb_build_object('mes', :'p0', 'valor', 100), jsonb_build_object('mes', :'p1', 'valor', 150))))::text),
  'Mês que já passou não muda no calendário', 'mês a mês: depois de aprovada, mês que já passou não muda');
select api.salvar_conta(:'pbase'::jsonb || jsonb_build_object('id', :'kcur', 'meses', jsonb_build_array(:'pm2'::jsonb, :'pm1'::jsonb,
  jsonb_build_object('mes', :'p0', 'valor', 50), jsonb_build_object('mes', :'p1', 'valor', 150))));
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.ok((select valor = 150 from erp.compromisso_meses where compromisso_id = :'kcur' and competencia = :'p1'),
  'mês a mês: o mês atual e os de depois mudam');
-- quem só consulta não grava meses
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$insert into erp.compromisso_meses values (%L, '2027-01-01', 1)$$, :'kass'), 'mês a mês: quem só consulta não grava o calendário');
select pg_temp.como(:'analista');

-- como paga (Moises, 23/11/2026): PIX fixo, TED ou vem com cada cobrança; parte do cadastro aprovado. A conferência
-- (chave CPF/CNPJ e conta da TED do fornecedor) roda no fim da transação, como a do calendário.
select aprovacao_versao as kver from erp.compromissos where id = :'kctr' \gset
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'pix', 'pix_tipo', 'cpf_cnpj', 'pix_chave', '77777777000177')));
set constraints erp.t_pagamento_confere immediate;
set constraints erp.t_pagamento_confere deferred;
select pg_temp.ok((select x->'pagamento'->>'modo' = 'pix' and x->'pagamento'->>'pix_chave' = '77777777000177' from api.conta(:'kctr') x)
                  and (select aprovacao_versao > :kver from erp.compromissos where id = :'kctr'),
  'como paga: o PIX fixo entra no cadastro e pede aprovação de novo');
select aprovacao_versao as kver from erp.compromissos where id = :'kctr' \gset
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'pix', 'pix_tipo', 'cpf_cnpj', 'pix_chave', '77777777000177')));
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr'));
select pg_temp.ok((select aprovacao_versao = :kver from erp.compromissos where id = :'kctr')
                  and exists (select 1 from erp.compromisso_pagamentos where compromisso_id = :'kctr'),
  'como paga: salvar a mesma forma, ou sem mandar a forma, não pede aprovação de novo');
savepoint sp_pag;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'pix', 'pix_tipo', 'cpf_cnpj', 'pix_chave', '12345678000199')));
select pg_temp.erro_igual('set constraints erp.t_pagamento_confere immediate',
  'A chave PIX por CPF/CNPJ não é o documento do fornecedor (só com a justificativa da exceção)', 'como paga: chave CPF/CNPJ de outra pessoa sem justificativa é recusada');
rollback to savepoint sp_pag;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'ted', 'banco', '341', 'agencia', '1234', 'conta', '56789', 'conta_digito', '0',
                     'conta_tipo', 'corrente', 'titular_documento', '12345678000199')));
select pg_temp.erro_igual('set constraints erp.t_pagamento_confere immediate',
  'A conta da TED não é do fornecedor (só com a justificativa da exceção)', 'como paga: TED para conta de outra pessoa sem justificativa é recusada');
rollback to savepoint sp_pag;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'ted', 'banco', '341', 'agencia', '1234', 'conta', '56789', 'conta_digito', '0',
                     'conta_tipo', 'corrente', 'titular_documento', '12345678000199', 'excecao', 'Conta da administradora')));
set constraints erp.t_pagamento_confere immediate;
set constraints erp.t_pagamento_confere deferred;
select pg_temp.ok((select excecao = 'Conta da administradora' from erp.compromisso_pagamentos where compromisso_id = :'kctr'),
  'como paga: TED para outra pessoa entra com a justificativa, que fica para quem aprova');
rollback to savepoint sp_pag;
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'ted', 'banco', '341', 'agencia', '1234', 'agencia_digito', 'x', 'conta', '56789', 'conta_digito', '0',
                     'conta_tipo', 'poupanca', 'titular_documento', '77777777000177', 'excecao', 'sobrou')));
set constraints erp.t_pagamento_confere immediate;
set constraints erp.t_pagamento_confere deferred;
select pg_temp.ok((select excecao is null and agencia_digito = 'X' from erp.compromisso_pagamentos where compromisso_id = :'kctr'),
  'como paga: TED para a conta do fornecedor entra, e a justificativa que sobra some');
-- trocar o fornecedor confere de novo
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'fornecedor', '10000000-0000-0000-0000-000000000008'));
select pg_temp.erro_igual('set constraints erp.t_pagamento_confere immediate',
  'A conta da TED não é do fornecedor (só com a justificativa da exceção)', 'como paga: trocar o fornecedor confere a conta de novo');
rollback to savepoint sp_pag;
select pg_temp.falha(format('select api.salvar_conta(%L::jsonb)', (:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'pix', 'pix_tipo', 'email', 'pix_chave', 'nao é email')))::text), 'como paga: chave PIX inválida é recusada');
rollback to savepoint sp_pag;
select pg_temp.falha(format('select api.salvar_conta(%L::jsonb)', (:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento',
  jsonb_build_object('modo', 'ted', 'banco', '341')))::text), 'como paga: TED sem a conta inteira é recusada');
rollback to savepoint sp_pag;
select aprovacao_versao as kver from erp.compromissos where id = :'kctr' \gset
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento', jsonb_build_object('modo', 'cobranca')));
select pg_temp.ok((select x->'pagamento'->>'modo' = 'cobranca' from api.conta(:'kctr') x)
                  and (select aprovacao_versao > :kver from erp.compromissos where id = :'kctr'),
  'como paga: "vem com cada cobrança" também é forma cadastrada e pede aprovação');
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'pagamento', null));
select pg_temp.ok((select x->'pagamento' = 'null'::jsonb from api.conta(:'kctr') x), 'como paga: mandar a forma nula tira a forma');
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$insert into erp.compromisso_pagamentos (compromisso_id, modo) values (%L, 'cobranca')$$, :'kctr'),
  'como paga: quem só consulta não grava a forma');
select pg_temp.como(:'analista');

-- revisão de segurança do #119: o que muda só o calendário ou só a forma também conta como quem alterou, e a volta
-- da aprovação vale para tirar; as conferências do cadastro rodam mesmo sem passar por api.salvar_conta
select pg_temp.sis();
set local role erp_situacao;
update erp.compromissos set alterado_por = :'contador' where id = :'kctr';
reset role;
select pg_temp.volta();
update erp.compromisso_meses set valor = valor + 100 where compromisso_id = :'kctr' and competencia = '2027-01-01';
update erp.compromisso_meses set valor = valor - 100 where compromisso_id = :'kctr' and competencia = '2027-02-01';
set constraints erp.t_meses_conferem immediate;
set constraints erp.t_meses_conferem deferred;
select pg_temp.ok((select alterado_por = :'analista' from erp.compromissos where id = :'kctr'),
  'mês a mês: quem muda só o calendário passa a ser quem alterou (e não aprova a versão nova)');
select pg_temp.sis();
set local role erp_situacao;
update erp.compromissos set alterado_por = :'contador' where id = :'kctr';
reset role;
select pg_temp.volta();
insert into erp.compromisso_pagamentos (compromisso_id, modo) values (:'kctr', 'cobranca');
select pg_temp.ok((select alterado_por = :'analista' from erp.compromissos where id = :'kctr'),
  'como paga: quem muda só a forma passa a ser quem alterou (e não aprova a versão nova)');
select aprovacao_versao as kver from erp.compromissos where id = :'kctr' \gset
update erp.compromisso_pagamentos set modo = modo where compromisso_id = :'kctr';
select pg_temp.ok((select aprovacao_versao = :kver from erp.compromissos where id = :'kctr'),
  'como paga: regravar a forma igual não pede aprovação de novo');
delete from erp.compromisso_pagamentos where compromisso_id = :'kctr';
select pg_temp.ok((select aprovacao_versao > :kver from erp.compromissos where id = :'kctr'),
  'como paga: tirar a forma também volta o cadastro para a aprovação');
savepoint sp_rev;
-- mudar o valor ou o fim do contrato sem acertar os meses é recusado (sem api.salvar_conta)
select pg_temp.sis();
update erp.compromissos set valor_total = 3500 where id = :'kctr';
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'A soma dos meses (R$ 3.000,00) não bate com o valor do contrato (R$ 3.500,00)', 'mês a mês: mudar o valor do contrato direto também confere a soma');
rollback to savepoint sp_rev;
select pg_temp.sis();
update erp.compromissos set fim = '2027-04-30' where id = :'kctr';
select pg_temp.erro_igual('set constraints erp.t_meses_conferem immediate',
  'O calendário do contrato precisa ter todos os meses da vigência', 'mês a mês: mudar o fim do contrato direto também confere os meses');
rollback to savepoint sp_rev;
-- incluir um mês que já passou, depois da aprovação, é recusado
select pg_temp.sis();
delete from erp.compromisso_meses where compromisso_id = :'kcur' and competencia = (:'pm2'::jsonb->>'mes')::date;
select pg_temp.volta();
select pg_temp.erro_igual(format('insert into erp.compromisso_meses values (%L, %L, 100)', :'kcur', :'pm2'::jsonb->>'mes'),
  'Mês que já passou não muda no calendário', 'mês a mês: depois de aprovada, não se inclui mês que já passou');
rollback to savepoint sp_rev;
-- trocar o fornecedor e manter a chave CPF/CNPJ do anterior exige a exceção (sem api.salvar_conta)
select pg_temp.volta();
insert into erp.compromisso_pagamentos (compromisso_id, modo, pix_tipo, pix_chave) values (:'kctr', 'pix', 'cpf_cnpj', '77777777000177');
set constraints erp.t_pagamento_confere immediate;
set constraints erp.t_pagamento_confere deferred;
select pg_temp.sis();
update erp.compromissos set pessoa_id = '10000000-0000-0000-0000-000000000008' where id = :'kctr';
select pg_temp.erro_igual('set constraints erp.t_pagamento_confere immediate',
  'A chave PIX por CPF/CNPJ não é o documento do fornecedor (só com a justificativa da exceção)', 'como paga: trocar o fornecedor e manter a chave do anterior exige a exceção');
rollback to savepoint sp_rev;
-- fornecedor sem CPF/CNPJ: a conta da TED não tem com o que bater, então exige a exceção
select pg_temp.sis();
insert into erp.pessoas (id, tipo, nome) values ('10000000-0000-0000-0000-0000000000f1', 'juridica', 'Sem Documento');
select pg_temp.volta();
select api.salvar_conta(:'kbase'::jsonb || jsonb_build_object('id', :'kctr', 'fornecedor', '10000000-0000-0000-0000-0000000000f1', 'pagamento',
  jsonb_build_object('modo', 'ted', 'banco', '341', 'agencia', '1234', 'conta', '56789', 'conta_digito', '0',
                     'conta_tipo', 'corrente', 'titular_documento', '77777777000177')));
select pg_temp.erro_igual('set constraints erp.t_pagamento_confere immediate',
  'A conta da TED não é do fornecedor (só com a justificativa da exceção)', 'como paga: fornecedor sem documento exige a exceção');
rollback to savepoint sp_rev;
select pg_temp.como(:'analista');
rollback;
select pg_temp.como(null);

\echo '# pessoa PJ: o cadastro só o master e os designados veem (Moises, 19/11/2026)'
begin;
select pg_temp.sis();
delete from erp.designados_pj where user_id in (:'gestor', :'analista');
insert into erp.designados_pj (user_id, motivo, por) values (:'analista', 'Teste pessoa PJ', :'diretor');
select pg_temp.ok(not erp.ve_pj(:'gestor') and erp.ve_pj(:'analista') and erp.ve_pj(:'diretor'), 'pessoa PJ: (teste) o gestor não vê o PJ; o designado e o master veem');
-- quem não vê o PJ não cadastra pessoa já marcada
select pg_temp.como(:'gestor');
select pg_temp.falha($$insert into erp.pessoas (id, tipo, nome, documento, restrita) values ('6c000000-0000-0000-0000-000000000009', 'fisica', 'X', '52998224725', true)$$,
  'pessoa PJ: quem não vê o PJ não cadastra pessoa marcada');
-- o designado cadastra a pessoa PJ com o papel
select pg_temp.como(:'analista');
insert into erp.pessoas (id, tipo, nome, documento, email, restrita) values ('6c000000-0000-0000-0000-000000000001', 'fisica', 'Fulano PJ', '11144477735', 'fulano@exemplo.com', true);
insert into erp.pessoa_papeis (pessoa_id, papel) values ('6c000000-0000-0000-0000-000000000001', 'fornecedor');
select pg_temp.ok(exists (select 1 from erp.pessoas where id = '6c000000-0000-0000-0000-000000000001')
                  and exists (select 1 from erp.pessoa_papeis where pessoa_id = '6c000000-0000-0000-0000-000000000001'),
  'pessoa PJ: o designado vê a pessoa e o papel');
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.pessoas where id = '6c000000-0000-0000-0000-000000000001'), 'pessoa PJ: o master vê a pessoa');
-- o gestor não vê a pessoa, nem o papel, nem pela api
select pg_temp.como(:'gestor');
select pg_temp.ok(not exists (select 1 from erp.pessoas where id = '6c000000-0000-0000-0000-000000000001' or documento = '11144477735'),
  'pessoa PJ: quem não vê o PJ não acha a pessoa, nem pelo CPF');
select pg_temp.ok(not exists (select 1 from erp.pessoa_papeis where pessoa_id = '6c000000-0000-0000-0000-000000000001'),
  'pessoa PJ: quem não vê o PJ não vê o papel dela');
select pg_temp.falha($$update erp.pessoas set email = 'outro@exemplo.com' where id = '6c000000-0000-0000-0000-000000000001'$$,
  'pessoa PJ: quem não vê o PJ não altera a pessoa');
-- nem usa a pessoa como credor, mesmo sabendo o id (a chave estrangeira não passa pelo RLS)
select pg_temp.erro_igual(format($$insert into erp.titulos (empresa_id, tipo, pessoa_id, emissao, competencia, valor)
  values (%L, 'avulso', '6c000000-0000-0000-0000-000000000001', '2026-12-01', '2026-12-01', 10)$$, :'spe'),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não lança título para ela');
select pg_temp.erro_igual(format($$insert into erp.documentos_fiscais (empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values (%L, '6c000000-0000-0000-0000-000000000001', 'recibo', 'PJ-9', '2026-12-01', '2026-12-01', 10)$$, :'spe'),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não lança nota dela');
select pg_temp.erro_igual(format($$insert into erp.compromissos (empresa_id, tipo, pessoa_id, descricao, inicio, valor_total)
  values (%L, 'avulsa', '6c000000-0000-0000-0000-000000000001', 'x', '2026-12-01', 10)$$, :'spe'),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não faz contrato com ela');
-- trocar o credor de um título para a pessoa PJ também é barrado
select pg_temp.sis();
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('6c000000-0000-0000-0000-000000000002', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2026-12-01', '2026-12-01', 10);
select pg_temp.como_dono(:'gestor');
select pg_temp.erro_igual($$update erp.titulos set pessoa_id = '6c000000-0000-0000-0000-000000000001' where id = '6c000000-0000-0000-0000-000000000002'$$,
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: trocar o credor para a pessoa PJ é barrado');
-- o designado usa a pessoa
select pg_temp.como_dono(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('6c000000-0000-0000-0000-000000000003', :'spe', 'avulso', '6c000000-0000-0000-0000-000000000001', '2026-12-01', '2026-12-01', 10);
select pg_temp.ok(true, 'pessoa PJ: o designado lança título para a pessoa PJ');
-- o mesmo vale para previsão, pagamento, empresa do grupo, sócio e órgão da retenção
select pg_temp.como_dono(:'gestor');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', '6c000000-0000-0000-0000-000000000001', %L, %L, %L, '2026-12-01', '2026-12-20', 10)$$, :'spe', :'ne_vm', :'cc_obra', pg_temp.nat('04.01')),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não lança previsão dela');
select pg_temp.erro_igual(format($$insert into erp.pagamentos (empresa_id, conta_id, pessoa_id, nucleo_economico_id, centro_custo_id, data, valor)
  values (%L, %L, '6c000000-0000-0000-0000-000000000001', %L, %L, '2026-12-01', 10)$$, :'spe', :'conta_spe', :'ne_vm', :'cc_obra'),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não paga a ela');
select pg_temp.erro_igual(format($$insert into erp.participacoes (empresa_id, socio_id, percentual, inicio) values (%L, '6c000000-0000-0000-0000-000000000001', 1, '2026-12-01')$$, :'holding'),
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não a põe como sócia');
select pg_temp.sis();
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
  values ('6c000000-0000-0000-0000-000000000004', :'spe', '10000000-0000-0000-0000-000000000007', 'recibo', 'PJ-10', '2026-12-01', '2026-12-01', 10);
select pg_temp.como_dono(:'gestor');
select pg_temp.erro_igual($$insert into erp.documento_retencoes (documento_id, imposto, valor, orgao_id, vencimento)
  values ('6c000000-0000-0000-0000-000000000004', 'iss', 1, '6c000000-0000-0000-0000-000000000001', '2026-12-10')$$,
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não a põe como órgão da retenção');
select pg_temp.erro_igual($$insert into erp.empresas (pessoa_id, tipo) values ('6c000000-0000-0000-0000-000000000001', 'spe')$$,
  'Pessoa PJ só o master e os designados usam', 'pessoa PJ: quem não vê o PJ não a põe como empresa do grupo');
-- quem não vê o PJ não põe papel nela, nem a alcança por update ou delete sem filtro
select pg_temp.como(:'gestor');
select pg_temp.falha($$insert into erp.pessoa_papeis (pessoa_id, papel) values ('6c000000-0000-0000-0000-000000000001', 'cliente')$$,
  'pessoa PJ: quem não vê o PJ não põe papel nela');
update erp.pessoas set telefone = '11999990000' where not exists (select 1 from erp.empresas e where e.pessoa_id = pessoas.id);
select pg_temp.falha($$delete from erp.pessoas where nome = 'Fulano PJ'$$, 'pessoa PJ: quem não vê o PJ não apaga a pessoa');
select pg_temp.sis();
select pg_temp.ok((select telefone is null from erp.pessoas where id = '6c000000-0000-0000-0000-000000000001')
                  and (select telefone = '11999990000' from erp.pessoas where id = '10000000-0000-0000-0000-000000000007'),
  'pessoa PJ: o update sem filtro de quem não vê o PJ muda as outras e não a pessoa PJ');
-- pessoa PJ só em lançamento de PJ, nem pelo designado
select pg_temp.como_dono(:'analista');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values (%L, 'manual', '6c000000-0000-0000-0000-000000000001', %L, %L, %L, '2026-12-01', '2026-12-20', 10)$$, :'spe', :'ne_vm', :'cc_obra', pg_temp.nat('04.01')),
  'Pessoa PJ só em lançamento de PJ: a natureza tem de ser restrita', 'pessoa PJ: previsão de natureza comum não usa a pessoa PJ');
select pg_temp.erro_igual(format($$insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6c000000-0000-0000-0000-000000000003', %L, %L, %L, 100)$$, :'ne_vm', :'cc_obra', pg_temp.nat('04.01')),
  'Pessoa PJ só em lançamento de PJ: a natureza tem de ser restrita', 'pessoa PJ: título da pessoa PJ não ganha linha de natureza comum');
select pg_temp.sis();
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6c000000-0000-0000-0000-000000000002', :'ne_vm', :'cc_obra', pg_temp.nat('04.01'), 100);
select pg_temp.como_dono(:'analista');
select pg_temp.erro_igual($$update erp.titulos set pessoa_id = '6c000000-0000-0000-0000-000000000001' where id = '6c000000-0000-0000-0000-000000000002'$$,
  'Pessoa PJ só em lançamento de PJ: a natureza tem de ser restrita', 'pessoa PJ: título com linha comum não passa para a pessoa PJ');
-- a auditoria de título e previsão de PJ e de natureza restrita (linhas de parcela_pagamentos, sienge_previsoes e
-- naturezas_liberadas, escritas como o dono da auditoria): o TI sem designação não lê; a do título comum, lê
select pg_temp.sis();
update erp.naturezas set restrita = true where codigo = '05.01.04';
select pg_temp.nat('05.01.04') as nat_pj \gset
select pg_temp.ok(erp.natureza_restrita(:'nat_pj') and not erp.natureza_restrita(pg_temp.nat('04.01')),
  'pessoa PJ: (teste) há natureza restrita, e a 04.01 não é');
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  values ('6c000000-0000-0000-0000-000000000003', :'ne_vm', :'cc_mkt', :'nat_pj', 100);
insert into erp.previsoes (id, empresa_id, origem, pessoa_id, nucleo_economico_id, centro_custo_id, natureza_id, competencia, data_prevista, valor)
  values ('6c000000-0000-0000-0000-000000000005', :'spe', 'manual', '6c000000-0000-0000-0000-000000000001', :'ne_vm', :'cc_mkt', :'nat_pj', '2026-12-01', '2026-12-20', 10);
set local role erp_auditoria;
insert into erp.auditoria (tabela, registro, acao, depois, por) values
  ('parcela_pagamentos', '6c000000-0000-0000-0000-000000000003', 'insert', '{"titulo_id": "6c000000-0000-0000-0000-000000000003", "numero": 1, "pix_chave": "pj"}', :'diretor'),
  ('parcela_pagamentos', '6c000000-0000-0000-0000-000000000002', 'insert', '{"titulo_id": "6c000000-0000-0000-0000-000000000002", "numero": 1, "pix_chave": "comum"}', :'diretor'),
  ('sienge_previsoes', '6c000000-0000-0000-0000-000000000005', 'insert', '{"previsao_id": "6c000000-0000-0000-0000-000000000005"}', :'diretor'),
  ('naturezas_liberadas', 'pj', 'insert', jsonb_build_object('natureza_id', :'nat_pj'), :'diretor');
reset role;
select pg_temp.como(:'ti');
select pg_temp.ok(not exists (select 1 from erp.auditoria where depois ->> 'pix_chave' = 'pj')
                  and exists (select 1 from erp.auditoria where depois ->> 'pix_chave' = 'comum'),
  'pessoa PJ: o administrador sem designação não lê a auditoria da chave PIX do título PJ, e lê a do título comum');
select pg_temp.ok(not exists (select 1 from erp.auditoria where tabela = 'sienge_previsoes' and registro = '6c000000-0000-0000-0000-000000000005'),
  'pessoa PJ: o administrador sem designação não lê a auditoria da previsão PJ');
select pg_temp.ok(not exists (select 1 from erp.auditoria where tabela = 'naturezas_liberadas' and registro = 'pj'),
  'pessoa PJ: o administrador sem designação não lê a auditoria da liberação de natureza restrita');
select pg_temp.como(:'diretor');
select pg_temp.ok((select count(*) = 4 from erp.auditoria where tabela in ('parcela_pagamentos', 'sienge_previsoes', 'naturezas_liberadas')
                     and registro in ('6c000000-0000-0000-0000-000000000003', '6c000000-0000-0000-0000-000000000002', '6c000000-0000-0000-0000-000000000005', 'pj')),
  'pessoa PJ: o master lê as quatro');
-- a auditoria da pessoa PJ: o administrador (o TI) sem designação não lê; o master lê
select pg_temp.como(:'ti');
select pg_temp.ok(not exists (select 1 from erp.auditoria where tabela in ('pessoas', 'pessoa_papeis') and registro = '6c000000-0000-0000-0000-000000000001')
                  and exists (select 1 from erp.auditoria where tabela = 'pessoas' and registro = '10000000-0000-0000-0000-000000000007'),
  'pessoa PJ: o administrador sem designação não lê a auditoria da pessoa PJ, e lê a das outras');
select pg_temp.como(:'diretor');
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'pessoas' and registro = '6c000000-0000-0000-0000-000000000001')
                  and exists (select 1 from erp.auditoria where tabela = 'pessoa_papeis' and registro = '6c000000-0000-0000-0000-000000000001'),
  'pessoa PJ: o master lê a auditoria da pessoa PJ');
-- a marca só o master muda: nem o designado tira
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$update erp.pessoas set restrita = false where id = '6c000000-0000-0000-0000-000000000001'$$,
  'A marca de PJ da pessoa só o master muda', 'pessoa PJ: o designado não tira a marca');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual($$update erp.pessoas set restrita = true where id = '10000000-0000-0000-0000-000000000007'$$,
  'A marca de PJ da pessoa só o master muda', 'pessoa PJ: quem não é master não marca pessoa comum');
select pg_temp.como(:'diretor');
update erp.pessoas set restrita = false where id = '6c000000-0000-0000-0000-000000000001';
select pg_temp.como(:'gestor');
select pg_temp.ok(exists (select 1 from erp.pessoas where id = '6c000000-0000-0000-0000-000000000001'), 'pessoa PJ: o master tira a marca e a pessoa volta a aparecer');
select pg_temp.volta();
rollback;
select pg_temp.sis();

-- Limite do leitor por pessoa (Moises, 20/11/2026): padrão 30; administrador ou master mudam o dos outros
begin;
select pg_temp.como(:'analista');
select pg_temp.ok((select (j->>'limite_leitor')::int = 30 from api.eu() j), 'limite do leitor: sem valor, api.eu() traz o padrão 30');
select pg_temp.erro_igual(format($$select api.definir_limite_leitor(%L, 100)$$, :'gestor'),
  'Só o administrador ou o master muda o limite do leitor', 'limite do leitor: analista não muda o de outro');
select pg_temp.ok((select count(*) = 0 from (select 1 from erp.usuarios where id = :'gestor' and limite_leitor is not null) x),
  'limite do leitor: nada gravado');
update erp.usuarios set limite_leitor = 500 where id = :'gestor';
select pg_temp.como_dono(null);
select pg_temp.ok((select limite_leitor is null from erp.usuarios where id = :'gestor'), 'limite do leitor: update direto do analista não grava (RLS)');
select pg_temp.como(:'ti');
select pg_temp.erro_igual(format($$select api.definir_limite_leitor(%L, 100)$$, :'ti'),
  'Ninguém muda o próprio limite do leitor', 'limite do leitor: o administrador não muda o próprio');
select pg_temp.erro_igual(format($$select api.definir_limite_leitor(%L, 0)$$, :'analista'),
  'O limite do leitor vai de 1 a 10000 arquivos a cada 10 minutos', 'limite do leitor: fora de 1 a 10000 é recusado');
select pg_temp.erro_igual($$select api.definir_limite_leitor('00000000-0000-0000-0000-0000000000ff', 50)$$,
  'Usuário não encontrado', 'limite do leitor: usuário que não existe');
select pg_temp.erro_igual(format($$select api.definir_limite_leitor(%L, 101)$$, :'analista'),
  'Acima de 100 arquivos a cada 10 minutos, só o master muda o limite do leitor', 'limite do leitor: o administrador não passa de 100');
select pg_temp.como_dono(:'ti');
select pg_temp.erro_igual(format($$update erp.usuarios set limite_leitor = 500 where id = %L$$, :'analista'),
  'Acima de 100 arquivos a cada 10 minutos, só o master muda o limite do leitor', 'limite do leitor: nem por update direto o administrador passa de 100');
select pg_temp.erro_igual($$insert into erp.usuarios (login_id, nome, papel, ativo, limite_leitor) values ('novo-limite', 'Novo', 'leitura', false, 500)$$,
  'Acima de 100 arquivos a cada 10 minutos, só o master muda o limite do leitor', 'limite do leitor: nem criando usuário o administrador passa de 100');
select pg_temp.como(:'ti');
select api.definir_limite_leitor(:'analista', 100);
select pg_temp.como(:'analista');
select pg_temp.ok((select (j->>'limite_leitor')::int = 100 from api.eu() j), 'limite do leitor: o administrador muda e api.eu() traz o valor');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual($$update erp.usuarios set limite_leitor = 1000 where id = erp.eu()$$,
  'Ninguém muda o próprio papel, acesso ou login', 'limite do leitor: nem o master muda o próprio por update direto');
select pg_temp.como(:'diretor');
select api.definir_limite_leitor(:'analista', 1000);
select pg_temp.como(:'analista');
select pg_temp.ok((select (j->>'limite_leitor')::int = 1000 from api.eu() j), 'limite do leitor: o master passa de 100');
select pg_temp.como(:'diretor');
select api.definir_limite_leitor(:'analista', 10000);
select pg_temp.erro_igual(format($$select api.definir_limite_leitor(%L, 10001)$$, :'analista'),
  'O limite do leitor vai de 1 a 10000 arquivos a cada 10 minutos', 'limite do leitor: nem o master passa de 10000');
select pg_temp.como(:'analista');
select pg_temp.ok((select (j->>'limite_leitor')::int = 10000 from api.eu() j), 'limite do leitor: o master põe até 10000 (Moises, 20/11/2026)');
select pg_temp.como_dono(null);
select pg_temp.falha(format($$update erp.usuarios set limite_leitor = 10001 where id = %L$$, :'analista'),
  'limite do leitor: a coluna recusa acima de 10000');
select pg_temp.como(:'diretor');
select api.definir_limite_leitor(:'analista', null);
select pg_temp.como(:'analista');
select pg_temp.ok((select (j->>'limite_leitor')::int = 30 from api.eu() j), 'limite do leitor: o master volta ao padrão com nulo');
select pg_temp.como_dono(null);
select pg_temp.ok((select count(*) >= 2 from erp.auditoria where tabela = 'usuarios' and registro = :'analista'),
  'limite do leitor: as mudanças ficam na auditoria');
select pg_temp.como(null);
rollback;
select pg_temp.sis();

-- ---------------------------------------------------------------------
\echo '# orçamento de área (Moises, 23/11/2026)'
begin;
alter table erp.divisoes disable trigger t_teste_libera;
\set o_on  '87000000-0000-0000-0000-0000000000e1'
\set o_go  '87000000-0000-0000-0000-0000000000e2'
select erp.mes(erp._hoje_sp()) as o_m0, extract(year from erp._hoje_sp())::int as o_ano,
       (erp.mes(erp._hoje_sp()) - interval '1 month')::date as o_mp, extract(month from erp._hoje_sp()) > 1 as o_tem_passado \gset
select pg_temp.nat('05.01.04') as o_na, pg_temp.nat('05.01.03') as o_nb \gset
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador'), ('AD', :'diretor2'), ('AO', :'analista2') on conflict do nothing;
update erp.listas_financeiro set centros = array[:'cc_mkt'::uuid, :'cc_mkt'::uuid] where lista = 'AO' and user_id = :'analista';
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
select pg_temp.volta();
select pg_temp.ok((select centros = array[:'cc_mkt'::uuid] from erp.listas_financeiro where lista = 'AO' and user_id = :'analista'),
  'orçamento: o AO fica ligado ao centro (sem repetição)');
select pg_temp.sis();
select pg_temp.falha(format($$update erp.listas_financeiro set centros = array[%L::uuid] where lista = 'AF'$$, :'cc_mkt'),
  'orçamento: só o AO se liga a centros');
select pg_temp.falha($$update erp.listas_financeiro set centros = array['45000000-0000-0000-0000-0000000000ff'::uuid] where lista = 'AO'$$,
  'orçamento: centro que não existe não entra');
select pg_temp.volta();
-- a vaga AO_CENTRO da alçada: só o AO do centro (e o AD)
select pg_temp.sis();
select pg_temp.ok(erp._ocupa_vaga('AO_CENTRO', :'cc_mkt', :'analista') and not erp._ocupa_vaga('AO_CENTRO', :'cc_obra', :'analista')
                  and not erp._ocupa_vaga('AO_CENTRO', :'cc_mkt', :'analista2') and erp._ocupa_vaga('AO_CENTRO', :'cc_obra', :'diretor2')
                  and erp._ocupa_vaga('AO', :'cc_obra', :'analista2'),
  'AO do centro: a vaga é do AO ligado ao centro ou do AD; a vaga AO continua de qualquer AO');
insert into erp.alcadas_pagamento (centro_custo_id, ate, fases) values (:'cc_obra', 1, '{AREA,AO_CENTRO}');
select pg_temp.ok(exists (select 1 from erp.alcadas_pagamento where centro_custo_id = :'cc_obra' and fases = '{AREA,AO_CENTRO}'),
  'AO do centro: a faixa da alçada aceita a vaga AO_CENTRO');
delete from erp.alcadas_pagamento where centro_custo_id = :'cc_obra' and ate = 1;
select pg_temp.volta();
-- níveis do centro: Online (com filho) > Google
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'o_on', 'centro_custo_id', :'cc_mkt', 'nome', 'Online Orç',
  'naturezas', jsonb_build_array(:'o_na', :'o_nb')), 'Online');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', :'o_go', 'mae_id', :'o_on', 'nome', 'Google Orç', 'copiar_de', :'o_on'), 'Google');

-- criar: só o gestor do centro (ou o master)
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.criar_orcamento_area(%L, %L, %s)$$, :'ne_vm', :'cc_mkt', :o_ano),
  'Só o gestor do centro de custo cria o orçamento da área', 'orçamento: quem não é gestor do centro não cria');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select api.criar_orcamento_area(%L, %L, %s)$$, :'ne_corp', :'cc_obra', :o_ano),
  'Só o gestor do centro de custo cria o orçamento da área', 'orçamento: o gestor só cria no centro dele');
select api.criar_orcamento_area(:'ne_vm', :'cc_mkt', :o_ano) as o_v1 \gset
select pg_temp.erro_igual(format($$select api.criar_orcamento_area(%L, %L, %s)$$, :'ne_vm', :'cc_mkt', :o_ano),
  'Já há um orçamento em montagem para este núcleo, centro e ano', 'orçamento: um em montagem por núcleo, centro e ano');
-- a versão e as linhas não se gravam direto
select pg_temp.erro_igual(format($$update erp.orcamento_versoes set nome = 'x' where id = %L$$, :'o_v1'),
  'O orçamento de área só muda pelas operações dele (criar, salvar, enviar e decidir)', 'orçamento: a versão não muda direto');
select pg_temp.erro_igual(format($$insert into erp.orcamento_linhas (versao_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id, competencia, valor)
  values (%L, %L, %L, %L, %L, %L, %L, -1)$$, :'o_v1', :'ne_vm', :'o_na', :'cc_mkt', :'o_on', :'o_go', :'o_m0'),
  'O orçamento de área só muda pelas operações dele (criar, salvar, enviar e decidir)', 'orçamento: a linha não entra direto');
-- linhas
select pg_temp.erro_igual(format($$select api.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', -5)))$$,
  :'o_v1', :'o_na', :'o_on', :'o_m0'), 'O valor orçado é positivo (a despesa prevista)', 'orçamento: valor negativo é recusado');
select pg_temp.erro_igual(format($$select api.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', 5)))$$,
  :'o_v1', :'o_na', :'o_on', (:'o_m0'::date + interval '1 year')::date),
  format('O mês %s não é do ano do orçamento (%s)', to_char(:'o_m0'::date + interval '1 year', 'MM/YYYY'), :o_ano), 'orçamento: mês de outro ano é recusado');
select pg_temp.erro_igual(format($$select api.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', '87000000-0000-0000-0000-0000000000cf', 'competencia', %L, 'valor', 5)))$$,
  :'o_v1', :'o_na', :'o_m0'), 'O nível não é deste centro de custo', 'orçamento: nível de outro lugar é recusado');
select pg_temp.falha(format($$select api.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', 5),
                                                                                    jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', 7)))$$,
  :'o_v1', :'o_na', :'o_on', :'o_m0', :'o_na', :'o_on', :'o_m0'), 'orçamento: a mesma natureza, nível e mês não se repete');
select api.salvar_orcamento_area(:'o_v1', jsonb_build_array(
  jsonb_build_object('natureza', :'o_na', 'nivel', :'o_on', 'competencia', :'o_m0', 'valor', 1000),
  jsonb_build_object('natureza', :'o_nb', 'nivel', :'o_go', 'competencia', :'o_m0', 'valor', 500))
  || case when :'o_tem_passado' then jsonb_build_array(jsonb_build_object('natureza', :'o_na', 'nivel', :'o_go', 'competencia', :'o_mp', 'valor', 50)) else '[]'::jsonb end) as n \gset
select pg_temp.ok((select divisao_id = :'o_on' and subdivisao_id = :'o_go' and valor = -500 from erp.orcamento_linhas where versao_id = :'o_v1' and natureza_id = :'o_nb')
                  and (select divisao_id = :'o_on' and subdivisao_id is null from erp.orcamento_linhas where versao_id = :'o_v1' and natureza_id = :'o_na' and competencia = :'o_m0'),
  'orçamento: a linha guarda o nível (de cima ou de baixo) e o valor como despesa');
-- enviar e decidir
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v1'), 'O orçamento não está esperando aprovação', 'orçamento: sem enviar, ninguém aprova');
select pg_temp.como(:'gestor');
select api.enviar_orcamento(:'o_v1');
select pg_temp.como_dono(null);
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'orcamento_enviado' and registro = :'o_v1'), 'orçamento: o envio vira aviso');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v1'),
  'A aprovação do orçamento é da AF com um AO do centro, ou do AD', 'orçamento: o gestor não aprova');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v1'),
  'A aprovação do orçamento é da AF com um AO do centro, ou do AD', 'orçamento: AO que não é do centro não aprova');
select pg_temp.como(:'contador');
select pg_temp.ok((select minha_vaga = 'AF' from api.orcamentos_area() where id = :'o_v1'), 'orçamento: a lista diz a vaga de quem está logado');
select pg_temp.ok(api.decidir('orcamento', :'o_v1', 'aprovar') = 'pendente', 'orçamento: a AF aprova e falta o AO do centro');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v1'), 'Você já decidiu este orçamento', 'orçamento: cada um decide uma vez');
select pg_temp.ok(not exists (select 1 from erp.previsoes where orcamento_linha_id is not null), 'orçamento: sem aprovar, nenhuma previsão');
select pg_temp.como(:'analista');
select pg_temp.ok(api.decidir('orcamento', :'o_v1', 'aprovar') = 'aprovado', 'orçamento: AF + AO do centro aprovam');
select pg_temp.como_dono(null);
select pg_temp.ok((select situacao = 'vigente' from erp.orcamento_versoes where id = :'o_v1'), 'orçamento: aprovado, fica vigente');
select pg_temp.ok((select count(*) = 2 and bool_and(pessoa_id is null and origem = 'orcamento' and situacao = 'aberta')
                     and sum(valor) = 1500 from erp.previsoes where orcamento_linha_id is not null and competencia = :'o_m0'),
  'orçamento: cada linha do mês vira uma previsão sem fornecedor, com o valor orçado');
select pg_temp.ok(not exists (select 1 from erp.previsoes where orcamento_linha_id is not null and competencia < :'o_m0' and erp._mes_orcamento_vale(competencia) = false),
  'orçamento: o mês que já passou da carência não vira previsão');
select pg_temp.ok((select bool_and(erp.previsao_aprovada(id)) and not exists (select 1 from erp.previsao_alcadas a where a.previsao_id = any(array_agg(p.id)))
                     from erp.previsoes p where orcamento_linha_id is not null),
  'orçamento: a previsão nasce aprovada, sem alçada');
select pg_temp.ok(erp._previsoes_no_acumulado(:'spe', null, :'o_m0', :'cc_mkt', null, :'ne_vm', null)
                  = (select coalesce(sum(erp._previsao_saldo(id)), 0) from erp.previsoes where centro_custo_id = :'cc_mkt' and situacao = 'aberta'
                       and orcamento_linha_id is null and competencia = :'o_m0' and not erp.natureza_restrita(natureza_id)),
  'orçamento: a previsão do orçamento fica fora do acumulado do mês da alçada');
select pg_temp.ok(pg_temp.livro('orcado') <= -1500, 'orçamento: o orçado vai ao livro');
select id as o_pa from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_na' and competencia = :'o_m0' \gset
select id as o_pb from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_nb' and competencia = :'o_m0' \gset
-- ninguém mexe na previsão do orçamento à mão
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$update erp.previsoes set situacao = 'cancelada' where id = %L$$, :'o_pa'),
  'A previsão do orçamento de área muda só pelo orçamento (revise o orçamento)', 'orçamento: a previsão não se cancela à mão');
select pg_temp.erro_igual(format($$select erp.encerrar_previsao(%L, 'saving')$$, :'o_pa'),
  'A previsão do orçamento de área se refaz sozinha', 'orçamento: a previsão não se encerra à mão');
select pg_temp.erro_igual(format($$insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia, data_prevista, valor, orcamento_linha_id)
  values (%L, 'orcamento', %L, %L, %L, %L, %L, %L, %L, 10, (select id from erp.orcamento_linhas where versao_id = %L limit 1))$$,
  :'spe', :'ne_vm', :'cc_mkt', :'o_on', :'o_go', :'o_na', :'o_m0', :'o_m0', :'o_v1'),
  'A previsão do orçamento de área nasce da aprovação do orçamento', 'orçamento: ninguém cria previsão de orçamento à mão');
-- vão ao Sienge (a primeira já com id lá, para ver a troca)
select pg_temp.sis();
select erp.sienge_enfileirar() >= 2 as x \gset
update erp.sienge_previsoes set sienge_id = 990001, situacao = 'enviado' where previsao_id = :'o_pa';
select pg_temp.volta();
select pg_temp.como_dono(null);
select pg_temp.ok((select count(*) = 2 from erp.sienge_previsoes where previsao_id in (:'o_pa', :'o_pb')), 'orçamento: as previsões vão à fila do Sienge');

-- a nota consome o orçado: Google (abaixo de Online) consome a linha de Online da mesma natureza e mês
select pg_temp.como(:'analista');
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'ORC-1',
  'emissao', :'o_m0', 'competencia', :'o_m0', 'valor', 300,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'divisao', :'o_go', 'natureza', :'o_na', 'percentual', 100)),
  'parcelas', jsonb_build_array(jsonb_build_object('vencimento', (:'o_m0'::date + 20), 'forma', 'pix', 'pix_tipo', 'email', 'pix_chave', 'agencia@example.com')))) as o_t1 \gset
select pg_temp.como_dono(null);
select pg_temp.ok((select valor = 300 from erp.titulo_previsoes where titulo_id = :'o_t1' and previsao_id = :'o_pa'),
  'orçamento: a nota consome a previsão do nível de cima, mesma natureza e mês');
set constraints all immediate;
select pg_temp.ok((select situacao = 'encerrada' from erp.previsoes where id = :'o_pa')
                  and (select count(*) = 1 and sum(valor) = 700 from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_na'
                         and competencia = :'o_m0' and situacao = 'aberta'),
  'orçamento: na hora, a previsão consumida é encerrada e nasce outra com o saldo');
select pg_temp.ok((select pb.situacao = 'aberta' from erp.previsoes pb where pb.id = :'o_pb'), 'orçamento: a outra linha fica como estava');
set constraints all deferred;
select pg_temp.sis();
select erp.sienge_enfileirar() >= 1 as x \gset
select pg_temp.volta();
select pg_temp.como_dono(null);
select pg_temp.ok((select apagar_desde is not null from erp.sienge_previsoes where previsao_id = :'o_pa')
                  and exists (select 1 from erp.sienge_previsoes s join erp.previsoes p on p.id = s.previsao_id
                               where p.natureza_id = :'o_na' and p.situacao = 'aberta' and p.orcamento_linha_id is not null),
  'orçamento: o PRV antigo vai para a lista de apagar e o novo entra na fila');
select id as o_pa2 from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_na' and competencia = :'o_m0' and situacao = 'aberta' \gset
select pg_temp.ok((select max(a.acumulado) < 1500 from erp.titulo_alcadas a where a.titulo_id = :'o_t1'),
  'orçamento: o orçado (1.500 no mês) não entra no acumulado da alçada do título');
-- nota fora do orçamento: não consome
select pg_temp.como(:'analista');
select pg_temp.sis();
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
values ('8f000000-0000-0000-0000-0000000000e1', :'spe', '10000000-0000-0000-0000-000000000007', 'nfse', 'ORC-2', :'o_m0', :'o_m0', 100);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
values ('8f000000-0000-0000-0000-0000000000e1', :'ne_vm', :'cc_mkt', :'o_on', :'o_go', :'o_na', 100);
select pg_temp.volta();
select pg_temp.como(:'leitor');
select pg_temp.falha($$select api.fora_orcamento('8f000000-0000-0000-0000-0000000000e1', 'Evento extra')$$, 'orçamento: quem só consulta não marca fora do orçamento');
select pg_temp.como(:'analista');
select api.fora_orcamento('8f000000-0000-0000-0000-0000000000e1', 'Evento extra');
select pg_temp.ok((select por = :'analista' and motivo = 'Evento extra' from erp.documentos_fora_orcamento where documento_id = '8f000000-0000-0000-0000-0000000000e1'),
  'orçamento: quem lança marca a nota fora do orçamento, com o motivo');
select erp.lancar_documento('8f000000-0000-0000-0000-0000000000e1', array[(:'o_m0'::date + 20)]) as o_t2 \gset
set constraints all immediate;
set constraints all deferred;
select pg_temp.como_dono(null);
select pg_temp.ok(not exists (select 1 from erp.titulo_previsoes where titulo_id = :'o_t2')
                  and (select situacao = 'aberta' and valor = 700 from erp.previsoes where id = :'o_pa2'),
  'orçamento: a nota fora do orçamento não consome');
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$select api.fora_orcamento('8f000000-0000-0000-0000-0000000000e1', null)$$,
  'Só a nota ainda não lançada fica fora do orçamento', 'orçamento: depois de lançada, a marca não sai');
-- título recusado (cancelado): a linha volta ao orçado cheio
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'o_t1', false, 'Errado') is not null as x \gset
set constraints all immediate;
set constraints all deferred;
select pg_temp.como_dono(null);
select pg_temp.ok((select situacao = 'cancelado' from erp.titulos where id = :'o_t1')
                  and (select situacao = 'encerrada' from erp.previsoes where id = :'o_pa2')
                  and (select count(*) = 1 and sum(valor) = 1000 from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_na'
                         and competencia = :'o_m0' and situacao = 'aberta'),
  'orçamento: o título cancelado devolve o saldo à linha');
select id as o_pa3 from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_na' and competencia = :'o_m0' and situacao = 'aberta' \gset

-- revisão: só a linha que mudou troca de previsão
select pg_temp.como(:'gestor');
select api.criar_orcamento_area(:'ne_vm', :'cc_mkt', :o_ano) as o_v2 \gset
select pg_temp.ok((select count(*) from erp.orcamento_linhas where versao_id = :'o_v2') = (select count(*) from erp.orcamento_linhas where versao_id = :'o_v1'),
  'orçamento: a revisão começa como cópia da vigente');
select pg_temp.erro_igual(format($$select api.enviar_orcamento(%L)$$, :'o_v2'), 'A revisão está igual ao orçamento vigente', 'orçamento: revisão sem mudança não se envia');
select api.salvar_orcamento_area(:'o_v2', jsonb_build_array(
  jsonb_build_object('natureza', :'o_na', 'nivel', :'o_on', 'competencia', :'o_m0', 'valor', 1000),
  jsonb_build_object('natureza', :'o_nb', 'nivel', :'o_go', 'competencia', :'o_m0', 'valor', 800))
  || case when :'o_tem_passado' then jsonb_build_array(jsonb_build_object('natureza', :'o_na', 'nivel', :'o_go', 'competencia', :'o_mp', 'valor', 50)) else '[]'::jsonb end) as n \gset
select pg_temp.ok(not :'o_tem_passado' or pg_temp.erro_como_dono(format($$select erp.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', 99)))$$,
                    :'o_v2', :'o_na', :'o_go', :'o_mp')) is not null,
  'orçamento: o mês que já passou não muda na revisão');
select api.enviar_orcamento(:'o_v2');
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'recusar')$$, :'o_v2'), 'Recusar exige justificativa', 'orçamento: recusar exige justificativa');
select pg_temp.ok(api.decidir('orcamento', :'o_v2', 'recusar', 'Alto demais') = 'recusado', 'orçamento: a AF recusa');
select pg_temp.como_dono(null);
select pg_temp.ok((select enviado_em is null and situacao = 'rascunho' from erp.orcamento_versoes where id = :'o_v2'), 'orçamento: recusado, volta à montagem');
-- quem montou não aprova (nem estando no AD)
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'gestor');
select pg_temp.volta();
select pg_temp.como(:'gestor');
select api.enviar_orcamento(:'o_v2');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v2'), 'Quem montou ou mudou o orçamento não aprova', 'orçamento: quem montou não aprova');
select pg_temp.sis();
delete from erp.listas_financeiro where lista = 'AD' and user_id = :'gestor';
select pg_temp.volta();
-- o AD aprova sozinho (a recusa de antes não conta depois do novo envio)
select pg_temp.como(:'diretor2');
select pg_temp.ok(api.decidir('orcamento', :'o_v2', 'aprovar') = 'aprovado', 'orçamento: o AD aprova sozinho');
select pg_temp.como_dono(null);
select pg_temp.ok((select situacao = 'substituida' from erp.orcamento_versoes where id = :'o_v1')
                  and (select situacao = 'vigente' from erp.orcamento_versoes where id = :'o_v2'),
  'orçamento: a revisão aprovada substitui a vigente');
select pg_temp.ok((select situacao = 'aberta' from erp.previsoes where id = :'o_pa3')
                  and (select situacao = 'encerrada' from erp.previsoes where id = :'o_pb')
                  and (select count(*) = 1 and sum(valor) = 800 from erp.previsoes where orcamento_linha_id is not null and natureza_id = :'o_nb'
                         and competencia = :'o_m0' and situacao = 'aberta'),
  'orçamento: na revisão, só a linha que mudou troca de previsão');
-- a tela: orçado, consumido e realizado por linha
select pg_temp.como(:'gestor');
select pg_temp.ok((select (l->>'orcado')::numeric = 800 and (l->>'consumido')::numeric = 0
                     from jsonb_array_elements((api.orcamento_area(:'o_v2'))->'linhas') l where l->>'natureza' = :'o_nb'),
  'orçamento: a tela traz o orçado e o consumido de cada linha');
-- a sobra do mês sai depois da carência (aqui, a linha de um mês vencido)
select pg_temp.sis();
\if :o_tem_passado
-- (teste) a previsão do mês passado que ainda estava na carência
select pg_temp.como_dono(:'gestor');
set local role erp_situacao;
insert into erp.previsoes (empresa_id, origem, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, competencia,
                           data_prevista, valor, orcamento_linha_id)
select :'spe', 'orcamento', :'ne_vm', :'cc_mkt', l.divisao_id, l.subdivisao_id, l.natureza_id, l.competencia, l.competencia, 50, l.id
  from erp.orcamento_linhas l where l.versao_id = :'o_v2' and l.competencia = :'o_mp'
   and not exists (select 1 from erp.previsoes q where q.orcamento_linha_id is not null and q.situacao = 'aberta' and q.competencia = :'o_mp');
reset role;
select pg_temp.sis();
select pg_temp.ok(exists (select 1 from erp.previsoes where orcamento_linha_id is not null and situacao = 'aberta' and competencia = :'o_mp'),
  'orçamento: (teste) há previsão aberta do mês passado');
\endif
update erp.regra_alcada_pagamento set orcamento_carencia_dias = 0;
select erp.sienge_enfileirar() >= 0 as o_enf \gset
select pg_temp.ok(:'o_enf' and not exists (select 1 from erp.previsoes where orcamento_linha_id is not null and situacao = 'aberta'
                                                                  and competencia < :'o_m0')
                  and exists (select 1 from erp.previsoes where orcamento_linha_id is not null and situacao = 'aberta' and competencia = :'o_m0'),
  'orçamento: passada a carência, a sobra do mês sai das previsões no enfileiramento (o mês corrente fica)');
select pg_temp.falha($$update erp.regra_alcada_pagamento set orcamento_carencia_dias = 90$$, 'orçamento: carência acima de 60 dias é recusada');
select pg_temp.volta();
-- mais uma revisão, para as travas da aprovação (revisão de segurança do #122)
select pg_temp.como(:'gestor');
select api.criar_orcamento_area(:'ne_vm', :'cc_mkt', :o_ano) as o_v3 \gset
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.salvar_orcamento_area(%L, '[]'::jsonb)$$, :'o_v3'),
  'Só o gestor do centro de custo monta o orçamento da área', 'orçamento: quem não é gestor do centro não salva');
select pg_temp.sis();
update erp.naturezas set restrita = true where codigo = '04.01';
select pg_temp.volta();
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select api.salvar_orcamento_area(%L, jsonb_build_array(jsonb_build_object('natureza', %L, 'nivel', %L, 'competencia', %L, 'valor', 5)))$$,
  :'o_v3', pg_temp.nat('04.01'), :'o_on', :'o_m0'),
  format('A natureza "%s" é restrita e não entra no orçamento de área', (select nome from erp.naturezas where codigo = '04.01')),
  'orçamento: natureza restrita (PJ) não entra no orçamento de área');
-- quem mudou por último (não quem criou) também não aprova: a AF que é gestora do centro salva e tenta aprovar
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'contador') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'contador');
select (select jsonb_agg(jsonb_build_object('natureza', l.natureza_id, 'nivel', coalesce(l.subdivisao_id, l.divisao_id),
                                            'competencia', l.competencia, 'valor', -l.valor + case when l.natureza_id = :'o_nb' and l.competencia = :'o_m0' then 100 else 0 end))
          from erp.orcamento_linhas l where l.versao_id = :'o_v3') as o_l3 \gset
select api.salvar_orcamento_area(:'o_v3', :'o_l3') as n \gset
select pg_temp.como(:'gestor');
select api.enviar_orcamento(:'o_v3');
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v3'), 'Quem montou ou mudou o orçamento não aprova',
  'orçamento: quem mudou por último não aprova');
select pg_temp.sis();
delete from erp.centro_aprovadores where centro_custo_id = :'cc_mkt' and user_id = :'contador';
select pg_temp.volta();
-- salvar tira o envio, e a aprovação dada antes do envio de agora não vale
select pg_temp.como(:'gestor');
select api.salvar_orcamento_area(:'o_v3', :'o_l3') as n \gset
select pg_temp.ok((select enviado_em is null and alterado_por = :'gestor' from erp.orcamento_versoes where id = :'o_v3'), 'orçamento: salvar tira o envio');
select api.enviar_orcamento(:'o_v3');
select pg_temp.como(:'contador');
select pg_temp.ok(api.decidir('orcamento', :'o_v3', 'aprovar') = 'pendente', 'orçamento: (preparo) a AF aprova');
select pg_temp.como(:'gestor');
select api.salvar_orcamento_area(:'o_v3', :'o_l3') as n \gset
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v3'), 'O orçamento não está esperando aprovação',
  'orçamento: depois de salvar, sem novo envio ninguém aprova');
select pg_temp.como(:'gestor');
select api.enviar_orcamento(:'o_v3');
select pg_temp.como(:'analista');
select pg_temp.ok(api.decidir('orcamento', :'o_v3', 'aprovar') = 'pendente', 'orçamento: a aprovação da AF de antes do novo envio não vale (falta a AF)');
-- a mesma vaga não aprova duas vezes (dois da AF)
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista2') on conflict do nothing;
delete from erp.listas_financeiro where lista = 'AO' and user_id = :'analista2';
select pg_temp.volta();
select pg_temp.como(:'contador');
select pg_temp.ok(api.decidir('orcamento', :'o_v3', 'recusar', 'Ver o Google') = 'recusado', 'orçamento: (preparo) a AF recusa');
-- a recusa derruba a aprovação: mesmo com AF e AO aprovando no mesmo envio, há recusa e não aprova
select pg_temp.como_dono(:'gestor');
set local role erp_situacao;
update erp.orcamento_versoes set enviado_em = (select min(em) from erp.orcamento_aprovacoes where versao_id = :'o_v3') - interval '1 second' where id = :'o_v3';
insert into erp.orcamento_aprovacoes (versao_id, vaga, aprovado, por) values (:'o_v3', 'AF', true, :'analista2');
reset role;
select pg_temp.ok(not erp.orcamento_aprovado(:'o_v3')
                  and exists (select 1 from erp.orcamento_aprovacoes where versao_id = :'o_v3' and aprovado and vaga = 'AF')
                  and exists (select 1 from erp.orcamento_aprovacoes where versao_id = :'o_v3' and aprovado and vaga = 'AO'),
  'orçamento: a recusa no mesmo envio derruba a aprovação');
set local role erp_situacao;
update erp.orcamento_versoes set enviado_em = null where id = :'o_v3';
reset role;
select pg_temp.como(:'gestor');
select api.enviar_orcamento(:'o_v3');
select pg_temp.como(:'analista2');
select pg_temp.ok(api.decidir('orcamento', :'o_v3', 'aprovar') = 'pendente', 'orçamento: (preparo) uma pessoa da AF aprova');
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v3'), 'A vaga AF já aprovou este orçamento',
  'orçamento: a mesma vaga não aprova duas vezes');
-- o mês virou entre salvar e aprovar: a publicação confere de novo os meses que já passaram
\if :o_tem_passado
select pg_temp.como_dono(:'gestor');
set local role erp_situacao;
update erp.orcamento_linhas set valor = valor - 1 where versao_id = :'o_v3' and competencia = :'o_mp';
reset role;
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select api.decidir('orcamento', %L, 'aprovar')$$, :'o_v3'), 'Os meses que já passaram não mudam',
  'orçamento: a publicação recusa mês passado diferente do vigente');
select pg_temp.como_dono(:'gestor');
set local role erp_situacao;
update erp.orcamento_linhas set valor = valor + 1 where versao_id = :'o_v3' and competencia = :'o_mp';
reset role;
\endif
select pg_temp.como(:'diretor2');
select pg_temp.ok(api.decidir('orcamento', :'o_v3', 'aprovar') = 'aprovado', 'orçamento: (preparo) o AD aprova a revisão');
-- consumo só no mesmo mês e no nível igual ou acima: nem outro mês, nem o nível ao lado
select pg_temp.como(:'diretor');
select erp.pedir_mudanca_acesso('divisoes', 'incluir', jsonb_build_object('id', '87000000-0000-0000-0000-0000000000e3', 'mae_id', :'o_on', 'nome', 'Meta Orç', 'copiar_de', :'o_go'), 'Meta');
select pg_temp.como(:'analista');
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'ORC-3',
  'emissao', :'o_m0', 'competencia', (:'o_m0'::date + interval '1 month')::date, 'valor', 40,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'divisao', :'o_go', 'natureza', :'o_na', 'percentual', 100)),
  'parcelas', jsonb_build_array(jsonb_build_object('vencimento', (:'o_m0'::date + 20), 'forma', 'pix', 'pix_tipo', 'email', 'pix_chave', 'agencia@example.com')))) as o_t3 \gset
select api.lancar_titulo(jsonb_build_object(
  'empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse', 'numero', 'ORC-4',
  'emissao', :'o_m0', 'competencia', :'o_m0', 'valor', 40,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'divisao', '87000000-0000-0000-0000-0000000000e3', 'natureza', :'o_nb', 'percentual', 100)),
  'parcelas', jsonb_build_array(jsonb_build_object('vencimento', (:'o_m0'::date + 20), 'forma', 'pix', 'pix_tipo', 'email', 'pix_chave', 'agencia@example.com')))) as o_t4 \gset
select pg_temp.como_dono(null);
select pg_temp.ok(exists (select 1 from erp.previsoes where orcamento_linha_id is not null and situacao = 'aberta' and natureza_id = :'o_na' and competencia = :'o_m0')
                  and not exists (select 1 from erp.titulo_previsoes where titulo_id = :'o_t3'),
  'orçamento: a nota de outro mês não consome o orçado deste mês');
select pg_temp.ok(exists (select 1 from erp.previsoes where orcamento_linha_id is not null and situacao = 'aberta' and natureza_id = :'o_nb' and competencia = :'o_m0')
                  and not exists (select 1 from erp.titulo_previsoes where titulo_id = :'o_t4')
                  and not erp.nivel_acima(:'o_go', :'o_on') and not erp.nivel_acima(:'o_go', '87000000-0000-0000-0000-0000000000e3'),
  'orçamento: a nota do nível ao lado não consome a linha de outro nível (só o nível igual ou acima)');
-- auditoria e a API sem gravação direta na aprovação
select pg_temp.como_dono(null);
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'orcamento_aprovacoes')
                  and exists (select 1 from erp.auditoria where tabela = 'documentos_fora_orcamento'),
  'orçamento: aprovação e marca de fora do orçamento ficam na auditoria');
select pg_temp.ok(not has_table_privilege('authenticated', 'erp.orcamento_aprovacoes', 'INSERT,UPDATE,DELETE'),
  'orçamento: a aprovação não se grava pela API');
select pg_temp.como(null);
rollback;
select pg_temp.sis();

\echo '# apelido das empresas (Moises, 23/11/2026)'
begin;
select pg_temp.sis();
delete from erp.listas_financeiro where user_id in (:'gestor', :'diretor2', :'ti', :'analista2', :'leitor');
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'gestor'), ('AD', :'diretor2');
select pg_temp.como(:'gestor');
select pg_temp.ok(erp.estou_nas_listas(array['AF']), 'apelido: (preparo) a gestora está na AF');
select pg_temp.como(:'diretor2');
select pg_temp.ok(erp.estou_nas_listas(array['AD']), 'apelido: (preparo) a sócia está na AD');
-- quem pode: o master, AF, AD e o administrador; não quem lança sem lista, nem a leitura
select pg_temp.como(:'diretor');
select pg_temp.ok(api.salvar_apelido_empresa(:'spe', '  BKM   03 ') = 'BKM 03', 'apelido: o master dá o apelido, sem espaço sobrando');
select pg_temp.como(:'gestor');
select pg_temp.ok(api.salvar_apelido_empresa(:'incorp', 'Incorporadora') = 'Incorporadora', 'apelido: AF dá o apelido');
select pg_temp.como(:'diretor2');
select pg_temp.ok(api.salvar_apelido_empresa(:'incorp', 'BKM Incorp') = 'BKM Incorp', 'apelido: AD muda o apelido');
select pg_temp.como(:'ti');
select pg_temp.ok(not erp.sou_master() and erp.sou_admin(), 'apelido: (preparo) o TI é administrador e não é master');
select pg_temp.ok(api.salvar_apelido_empresa(:'spe', 'SPE 03') = 'SPE 03', 'apelido: o administrador muda o apelido (Moises, 23/11/2026)');
update erp.empresas set apelido = 'SPE 03 - Parque Itajubá' where id = :'spe';
select pg_temp.ok((select apelido = 'SPE 03 - Parque Itajubá' from erp.empresas where id = :'spe'), 'apelido: o administrador muda também por update direto');
select pg_temp.ok((select bool_and(posso_apelido) from api.empresas()), 'apelido: a tela deixa o administrador mudar');
select pg_temp.como(:'diretor');
select api.salvar_apelido_empresa(:'spe', 'BKM 03');
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, 'Outra')$$, :'spe'),
  'Só AF, AD, o administrador e o master dão e mudam o apelido da empresa', 'apelido: quem lança sem lista não muda');
select pg_temp.falha(format($$update erp.empresas set apelido = 'Outra' where id = %L$$, :'spe'), 'apelido: nem por update direto quem lança muda');
select pg_temp.ok(pg_temp.erro_como_dono(format($$update erp.empresas set apelido = 'Outra' where id = %L$$, :'spe'))
                  = 'Só AF, AD, o administrador e o master dão e mudam o apelido da empresa', 'apelido: o gatilho barra por baixo da API');
select pg_temp.como(:'leitor');
select pg_temp.falha(format($$select api.salvar_apelido_empresa(%L, 'Outra')$$, :'spe'), 'apelido: a leitura não muda');
-- AF muda só o apelido: tipo e situação da empresa seguem com o administrador
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$update erp.empresas set ativa = false where id = %L$$, :'spe'),
  'Tipo e situação da empresa só o administrador muda', 'apelido: AF não muda a situação da empresa');
select pg_temp.erro_igual(format($$update erp.empresas set tipo = 'outra', apelido = 'X1' where id = %L$$, :'spe'),
  'Tipo e situação da empresa só o administrador muda', 'apelido: AF não muda o tipo junto com o apelido');
select pg_temp.erro_igual(format($$update erp.empresas set pessoa_id = '10000000-0000-0000-0000-000000000005' where id = %L$$, :'spe'),
  'Tipo e situação da empresa só o administrador muda', 'apelido: AF não troca a pessoa (o CNPJ) da empresa');
select pg_temp.ok(pg_temp.erro_como_dono(format($$update erp.empresas set pessoa_id = '10000000-0000-0000-0000-000000000005' where id = %L$$, :'spe'))
                  = 'Tipo e situação da empresa só o administrador muda', 'apelido: nem por baixo da API AF troca a pessoa da empresa');
-- nem o nome de outra empresa do grupo
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, %L)$$, :'spe', upper((select nome from erp.pessoas where id = '10000000-0000-0000-0000-000000000002'))),
  format('O apelido %s é o nome de outra empresa do grupo', upper((select nome from erp.pessoas where id = '10000000-0000-0000-0000-000000000002'))),
  'apelido: não é a razão social de outra empresa do grupo');
-- não se repete (sem diferença de maiúscula), tamanho de 2 a 40, vazio tira
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, 'bkm incorp')$$, :'holding'),
  'Já existe uma empresa com o apelido bkm incorp', 'apelido: não se repete entre as empresas');
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, 'B')$$, :'holding'),
  'O apelido tem de 2 a 40 letras', 'apelido: no mínimo 2 letras');
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, %L)$$, :'holding', repeat('a', 41)),
  'O apelido tem de 2 a 40 letras', 'apelido: no máximo 40 letras');
select pg_temp.ok(api.salvar_apelido_empresa(:'holding', 'Holding') = 'Holding', 'apelido: a holding ganha apelido');
select pg_temp.ok(api.salvar_apelido_empresa(:'holding', '   ') is null, 'apelido: vazio tira o apelido');
select pg_temp.erro_igual(format($$select api.salvar_apelido_empresa(%L, 'Nada')$$, '20000000-0000-0000-0000-0000000000ff'),
  'Empresa não encontrada', 'apelido: empresa que não existe');
-- o administrador continua mudando o resto da empresa (e o apelido fica)
select pg_temp.como(:'ti');
update erp.empresas set ativa = true where id = :'spe';
select pg_temp.ok((select apelido = 'BKM 03' from erp.empresas where id = :'spe'), 'apelido: o administrador muda a situação e o apelido fica');
-- as telas: apelido no lugar da razão social; sem apelido, a razão social; a razão social continua ao lado
select pg_temp.como(:'diretor');
select pg_temp.ok((select count(*) >= 3 and bool_and(posso_apelido) from api.empresas()), 'apelido: a lista das empresas, e o master pode mudar');
select pg_temp.ok((select apelido = 'BKM 03' and razao_social = (select nome from erp.pessoas where id = '10000000-0000-0000-0000-000000000003')
                     from api.empresas() where id = :'spe'), 'apelido: a lista traz o apelido e a razão social');
select pg_temp.ok((select e->>'nome' = 'BKM 03' and e->>'razao_social' = (select nome from erp.pessoas where id = '10000000-0000-0000-0000-000000000003')
                     from jsonb_array_elements(api.lancamento_opcoes()->'empresas') e where e->>'id' = :'spe'),
  'apelido: Lançar título mostra o apelido, com a razão social ao lado');
select pg_temp.ok((select e->>'nome' = (select nome from erp.pessoas where id = '10000000-0000-0000-0000-000000000001')
                     from jsonb_array_elements(api.lancamento_opcoes()->'empresas') e where e->>'id' = :'holding'),
  'apelido: sem apelido, a razão social');
select pg_temp.ok(not exists (select 1 from api.titulos() t join erp.titulos x on x.id = t.id
                               where x.empresa_id = :'spe' and t.empresa is distinct from 'BKM 03')
                  and exists (select 1 from api.titulos() t join erp.titulos x on x.id = t.id where x.empresa_id = :'spe'),
  'apelido: a lista de títulos mostra o apelido');
select pg_temp.ok((select apelido = 'BKM 03' and empresa <> 'BKM 03' from bi.d_empresa where empresa_id = :'spe'),
  'apelido: o BI traz o apelido ao lado da razão social');
select pg_temp.como(:'analista2');
select pg_temp.ok((select count(*) >= 3 and not bool_or(posso_apelido) from api.empresas()), 'apelido: quem não pode vê a lista sem poder mudar');
-- a razão social continua no que confere e sai do sistema (o credor e o envio ao Sienge leem erp.pessoas, que não muda)
select pg_temp.como_dono(null);
select pg_temp.ok((select count(*) >= 3 from erp.auditoria where tabela = 'empresas' and registro = :'spe'),
  'apelido: as mudanças da empresa ficam na auditoria');
select pg_temp.como(null);
rollback;
select pg_temp.sis();

\echo '# caixa das notas recebidas (Moises, 23/11/2026)'
-- chaves de acesso fictícias: NF-e (44) e NFS-e nacional (50), com o emitente e o número dentro
create function pg_temp.chave(p_tipo text, p_doc text, p_num text) returns text language sql as $$
  select case p_tipo when 'nfe' then '352611' || lpad(p_doc, 14, '0') || '55' || '001' || lpad(p_num, 9, '0') || '1' || '12345678' || '0'
                     else '3549904' || '1' || '2' || lpad(p_doc, 14, '0') || lpad(p_num, 13, '0') || '2611' || '123456789' || '0' end $$;
create function pg_temp.nota(p_tipo text, p_doc text, p_num text, p_valor numeric, p_tomador text default '33333333000133') returns jsonb language sql as $$
  select jsonb_build_object('tipo', p_tipo, 'chave', pg_temp.chave(p_tipo, p_doc, p_num), 'nsu', 10, 'tomador', p_tomador,
    'emitente_documento', p_doc, 'emitente_nome', 'Emitente ' || p_doc, 'numero', p_num, 'serie', case p_tipo when 'nfe' then '1' else '' end,
    'emissao', '2026-11-10', 'competencia', case p_tipo when 'nfse' then '2026-10-15' end, 'valor', p_valor, 'municipio', '3549904') $$;
begin;
select pg_temp.sis();
delete from erp.listas_financeiro where user_id in (:'analista2', :'leitor', :'diretor2', :'gestor', :'contador');
-- a gestora no AD e o contador no AF; a sócia é só diretora (sem lista)
insert into erp.listas_financeiro (lista, user_id) values ('AD', :'gestor'), ('AF', :'contador');
-- o serviço da busca grava; a mesma chave não entra duas vezes
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfse', '55555555000155', '500', 1500), '<NFSe>500</NFSe>', true) as nr1 \gset
select pg_temp.ok(erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfse', '55555555000155', '500', 1500), '<NFSe>outra</NFSe>', true) = :'nr1'
                  and (select count(*) = 1 from erp.notas_recebidas where chave = pg_temp.chave('nfse', '55555555000155', '500'))
                  and (select xml = '<NFSe>500</NFSe>' from erp.notas_recebidas_xml where nota_id = :'nr1'),
  'notas recebidas: a mesma nota não entra duas vezes e o XML não é sobrescrito');
select pg_temp.ok((select situacao = 'nova' and competencia = '2026-10-01' and numero = '500' and valor = 1500 from erp.notas_recebidas where id = :'nr1'),
  'notas recebidas: entra nova, com a competência da NFS-e no primeiro dia do mês');
select pg_temp.erro_igual($$select erp.registrar_nota_recebida('20000000-0000-0000-0000-000000000002', pg_temp.nota('nfse', '55555555000155', '501', 10), '<x/>', true)$$,
  'A nota não é contra o CNPJ desta empresa', 'notas recebidas: nota de outro CNPJ não entra na caixa da empresa');
select pg_temp.erro_igual(format($$select erp.registrar_nota_recebida(%L, pg_temp.nota('nfse', '55555555000155', '502', 10) || '{"numero": "503"}', '<x/>', true)$$, :'spe'),
  'Emitente ou número não batem com a chave da NFS-e', 'notas recebidas: número que não bate com a chave da NFS-e é recusado');
select pg_temp.erro_igual(format($$select erp.registrar_nota_recebida(%L, pg_temp.nota('nfe', '77777777000177', '9', 10) || '{"emitente_documento": "55555555000155"}', '<x/>', false)$$, :'spe'),
  'Emitente, número ou série não batem com a chave da NF-e', 'notas recebidas: emitente que não bate com a chave da NF-e é recusado');
select pg_temp.erro_igual(format($$select erp.registrar_nota_recebida(%L, pg_temp.nota('nfse', '55555555000155', '504', 10), '<x/>', false)$$, :'spe'),
  'A NFS-e chega sempre completa', 'notas recebidas: NFS-e não tem resumo');
-- NF-e: o resumo dá lugar ao completo uma vez; o completo não muda
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '123', 800), '<resNFe/>', false) as nr2 \gset
select pg_temp.ok((select not completo from erp.notas_recebidas_xml where nota_id = :'nr2'), 'notas recebidas: NF-e entra pelo resumo');
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '123', 800), '<nfeProc>1</nfeProc>', true);
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '123', 800), '<nfeProc>2</nfeProc>', true);
select pg_temp.ok((select completo and xml = '<nfeProc>1</nfeProc>' from erp.notas_recebidas_xml where nota_id = :'nr2'),
  'notas recebidas: o completo substitui o resumo uma vez e depois não muda');
select pg_temp.erro_igual(format($$update erp.notas_recebidas_xml set xml = 'x' where nota_id = %L$$, :'nr2'),
  'O XML completo da nota não muda', 'notas recebidas: nem o sistema troca o XML completo');
select erp.registrar_ciencia_nota_recebida(pg_temp.chave('nfe', '77777777000177', '123'));
select pg_temp.ok((select ciencia_em is not null from erp.notas_recebidas where id = :'nr2'), 'notas recebidas: a ciência da NF-e fica registrada');
-- cancelamento pelo emitente (o repetido não entra)
select erp.registrar_evento_nota_recebida(:'spe', pg_temp.chave('nfe', '77777777000177', '123'), '110111', true, 11, '<evento/>');
select erp.registrar_evento_nota_recebida(:'spe', pg_temp.chave('nfe', '77777777000177', '123'), '110111', true, 11, '<evento/>');
select pg_temp.ok((select cancelada_em is not null from erp.notas_recebidas where id = :'nr2')
                  and (select count(*) = 1 from erp.notas_recebidas_eventos where chave = pg_temp.chave('nfe', '77777777000177', '123')),
  'notas recebidas: o cancelamento marca a nota, e o evento repetido não entra');
-- leitura: o último NSU não volta
select erp.registrar_leitura_notas(:'spe', 'adn', 950, 950, null, null);
select pg_temp.erro_igual(format($$select erp.registrar_leitura_notas(%L, 'adn', 900, 950, null, null)$$, :'spe'),
  'O último NSU lido não volta', 'notas recebidas: o último NSU lido não volta');
-- nota de PJ: o emitente tem cadastro restrito
update erp.pessoas set restrita = true where id = '10000000-0000-0000-0000-000000000008';
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfse', '88888888000188', '7', 9000), '<NFSe>PJ</NFSe>', true) as nr_pj \gset
-- uma NFS-e de outra empresa do grupo, do mesmo emitente
select em.id as emp_b, p.documento as tom_b from erp.empresas em join erp.pessoas p on p.id = em.pessoa_id
 where em.id <> :'spe' and p.documento ~ '^[0-9]{14}$' order by p.documento limit 1 \gset
select erp.registrar_nota_recebida(:'emp_b', pg_temp.nota('nfse', '55555555000155', '900', 700, :'tom_b'), '<NFSe>B</NFSe>', true) as nr_b \gset

-- só o serviço da busca grava
select pg_temp.como(:'diretor');
select pg_temp.falha(format($$select erp.registrar_nota_recebida(%L, pg_temp.nota('nfse', '55555555000155', '600', 10), '<x/>', true)$$, :'spe'),
  'notas recebidas: nem o master grava nota na caixa');
select pg_temp.erro_igual(format($$insert into erp.notas_recebidas (empresa_id, tipo, chave, nsu, emitente_documento, numero, emissao, competencia, valor)
  values (%L, 'nfse', pg_temp.chave('nfse', '55555555000155', '601'), 1, '55555555000155', '601', '2026-11-01', '2026-11-01', 1)$$, :'spe'),
  'Só o serviço da busca grava a nota recebida', 'notas recebidas: insert direto é recusado');
select pg_temp.erro_igual(format($$update erp.notas_recebidas set valor = 1 where id = %L$$, :'nr1'),
  'Os dados da nota recebida não mudam', 'notas recebidas: os dados da nota não mudam');
select pg_temp.erro_igual(format($$delete from erp.notas_recebidas where id = %L$$, :'nr1'),
  'A nota recebida não se apaga', 'notas recebidas: a nota não se apaga');
select pg_temp.erro_igual(format($$select erp.registrar_leitura_notas(%L, 'adn', 1000, 1000, null, null)$$, :'spe'),
  'Só o serviço da busca grava a leitura das notas', 'notas recebidas: a leitura só o serviço grava');

-- quem vê: master, financeiro e diretor; a de PJ, só o master e os designados
select pg_temp.ok((select count(*) = 4 from api.notas_recebidas()), 'notas recebidas: o master vê todas, inclusive a de PJ');
select pg_temp.como(:'analista');
select pg_temp.ok((select count(*) = 3 from api.notas_recebidas()) and not exists (select 1 from erp.notas_recebidas where id = :'nr_pj'),
  'notas recebidas: o AO vê a caixa, menos a nota de PJ');
select pg_temp.ok(api.nota_recebida_xml(:'nr1') = '<NFSe>500</NFSe>' and api.nota_recebida_xml(:'nr_pj') is null,
  'notas recebidas: o XML segue a nota (o da de PJ não aparece)');
select pg_temp.ok((select count(*) = 1 from api.notas_recebidas_leituras()), 'notas recebidas: o financeiro vê a última busca');
select pg_temp.como(:'diretor2');
select pg_temp.ok(not erp.financeiro() and (select count(*) = 3 from api.notas_recebidas()),
  'notas recebidas: o diretor (sem lista do financeiro) vê a caixa, menos a de PJ');
select pg_temp.como(:'analista2');
select pg_temp.ok(not exists (select 1 from api.notas_recebidas()) and not exists (select 1 from api.notas_recebidas_leituras())
                  and api.nota_recebida_xml(:'nr1') is null and not exists (select 1 from erp.notas_recebidas_eventos),
  'notas recebidas: quem lança sem liberação não vê a caixa');
select pg_temp.como(:'leitor');
select pg_temp.ok(not exists (select 1 from api.notas_recebidas()), 'notas recebidas: a leitura sem liberação não vê a caixa');

-- liberação por empresa e tipo: o master e o AD; ninguém mais
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.liberar_notas_recebidas(%L, %L, 'nfse', 'Lança as notas da obra')$$, :'analista2', :'spe'),
  'Só o master e o AD liberam quem vê as notas recebidas', 'notas recebidas: o AO não libera');
select pg_temp.erro_igual(format($$insert into erp.notas_recebidas_acessos (user_id, empresa_id, tipo, motivo, por) values (%L, %L, 'nfse', 'xxx', %L)$$, :'analista2', :'spe', :'analista'),
  'Só o master e o AD liberam quem vê as notas recebidas', 'notas recebidas: nem por baixo da API o AO libera');
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.liberar_notas_recebidas(%L, %L, 'nfse', 'Lança as notas da obra')$$, :'analista2', :'spe'),
  'Só o master e o AD liberam quem vê as notas recebidas', 'notas recebidas: o AF não libera');
select pg_temp.como(:'diretor2');
select pg_temp.erro_igual(format($$select api.liberar_notas_recebidas(%L, %L, 'nfse', 'Lança as notas da obra')$$, :'analista2', :'spe'),
  'Só o master e o AD liberam quem vê as notas recebidas', 'notas recebidas: o diretor sem AD não libera');
select pg_temp.como(:'diretor');
select pg_temp.erro_igual(format($$select api.liberar_notas_recebidas(%L, %L, 'nfse', '')$$, :'analista2', :'spe'),
  'Diga o motivo da liberação', 'notas recebidas: liberar pede o motivo');
select pg_temp.erro_igual(format($$select api.liberar_notas_recebidas(%L, %L, 'material', 'Obra')$$, :'analista2', :'spe'),
  'Tipo de nota: nfe (material) ou nfse (serviço)', 'notas recebidas: o tipo é material (nfe) ou serviço (nfse)');
select api.liberar_notas_recebidas(:'analista2', :'spe', 'nfse', 'Lança as notas de serviço da obra');
select api.liberar_notas_recebidas(:'contador', :'emp_b', 'nfse', 'Confere as notas de serviço da outra empresa');
select pg_temp.como(:'analista2');
select pg_temp.ok((select count(*) = 1 and bool_and(id = :'nr1') from api.notas_recebidas()),
  'notas recebidas: liberada para serviço, a pessoa vê as NFS-e da empresa, não as NF-e, a de PJ nem as de outra empresa');
select pg_temp.ok((select count(*) = 1 from api.notas_recebidas_leituras())
                  and (select count(*) = 1 and bool_and(user_id = :'analista2') from api.notas_recebidas_acessos()),
  'notas recebidas: a pessoa liberada vê a última busca da empresa e só a própria liberação');
select pg_temp.como(:'gestor');
select api.liberar_notas_recebidas(:'analista2', :'spe', 'nfe', 'Compra os materiais da obra');
select pg_temp.ok((select count(*) = 3 from api.notas_recebidas_acessos()), 'notas recebidas: o AD libera e vê as liberações');
select pg_temp.como(:'analista2');
select pg_temp.ok((select count(*) = 2 from api.notas_recebidas()), 'notas recebidas: liberada para material também, vê as NF-e');
select pg_temp.como(:'gestor');
select api.retirar_notas_recebidas(:'analista2', :'spe', 'nfe');
select pg_temp.erro_igual(format($$select api.retirar_notas_recebidas(%L, %L, 'nfe')$$, :'analista2', :'spe'),
  'Esta pessoa não tem essa liberação', 'notas recebidas: tirar o que não existe dá erro');
select pg_temp.como(:'analista2');
select pg_temp.ok((select count(*) = 1 from api.notas_recebidas()), 'notas recebidas: o AD tira a liberação e a NF-e some');

-- quem lança acha a nota dele: pela chave, ou CNPJ + número + valor exatos
select pg_temp.como(:'diretor');
select api.retirar_notas_recebidas(:'analista2', :'spe', 'nfse');
select pg_temp.como(:'analista2');
select pg_temp.ok((select x->>'id' = :'nr1' and x->>'xml' = '<NFSe>500</NFSe>' from api.buscar_nota_recebida(pg_temp.chave('nfse', '55555555000155', '500')) x),
  'notas recebidas: quem lança acha a nota pela chave, com o XML');
select pg_temp.ok((select x->>'id' = :'nr1' from api.buscar_nota_recebida(null, '55.555.555/0001-55', '0500', 1500) x),
  'notas recebidas: e pelo CNPJ, número e valor');
select pg_temp.ok(api.buscar_nota_recebida(null, '55555555000155', '500', 1500.01) is null,
  'notas recebidas: valor diferente não acha (não dá para adivinhar notas pela sequência)');
select pg_temp.erro_igual($$select api.buscar_nota_recebida(null, '55555555000155', '500')$$,
  'Informe a chave de acesso, ou o CNPJ do emitente com o número e o valor', 'notas recebidas: CNPJ e número sem o valor não buscam');
select pg_temp.ok(api.buscar_nota_recebida(pg_temp.chave('nfse', '88888888000188', '7')) is null,
  'notas recebidas: a nota de PJ não aparece na busca de quem não vê o PJ');
select pg_temp.ok(erp._lanco_na_empresa(:'spe') and not erp._lanco_na_empresa(:'emp_b')
                  and api.buscar_nota_recebida(null, '55555555000155', '900', 700) is null
                  and (select x->>'id' = :'nr_b' from api.buscar_nota_recebida(pg_temp.chave('nfse', '55555555000155', '900')) x),
  'notas recebidas: pelo emitente, só acha nota de empresa em que a pessoa lança (pela chave, acha)');
select pg_temp.ok((select count(*) = 6 and count(*) filter (where criterio = 'emitente') = 3 and count(nota_id) = 3
                     and bool_and(user_id = :'analista2') from erp.notas_recebidas_buscas),
  'notas recebidas: toda busca fica registrada, com o critério e a nota achada');
-- só ver (leitor) em todos os centros da empresa não basta para achar pelo emitente; pela chave, acha
select pg_temp.sis();
insert into erp.excecoes_centro (user_id, nucleo_economico_id, centro_custo_id, nivel)
select :'analista2', n.id, nc.centro_custo_id, 'leitor' from erp.nucleos_economicos n
  join erp.nucleo_centros nc on nc.nucleo_economico_id = n.id where n.empresa_id = :'spe'
on conflict (user_id, nucleo_economico_id, centro_custo_id) do update set nivel = 'leitor', fim = null;
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.escrevo() and not erp._lanco_na_empresa(:'spe')
                  and api.buscar_nota_recebida(null, '55555555000155', '500', 1500) is null
                  and (select x->>'id' = :'nr1' from api.buscar_nota_recebida(pg_temp.chave('nfse', '55555555000155', '500')) x),
  'notas recebidas: quem só vê a empresa (sem lançar) não acha pelo emitente');
select pg_temp.sis();
delete from erp.excecoes_centro where user_id = :'analista2' and nucleo_economico_id in (select id from erp.nucleos_economicos where empresa_id = :'spe');
select pg_temp.como(:'analista2');
select count(api.buscar_nota_recebida(null, '55555555000155', '9' || g, 1)) from generate_series(1, 16) g;
select pg_temp.erro_igual($$select api.buscar_nota_recebida(null, '55555555000155', '500', 1500)$$,
  'Limite de buscas pelo emitente nesta hora; busque pela chave de acesso', 'notas recebidas: a busca pelo emitente tem limite por hora');
select pg_temp.ok((select x->>'id' = :'nr1' from api.buscar_nota_recebida(pg_temp.chave('nfse', '55555555000155', '500')) x),
  'notas recebidas: a busca pela chave não entra no limite');
select pg_temp.erro_igual($$update erp.notas_recebidas_buscas set criterio = 'chave'$$,
  'O registro das buscas não muda nem se apaga', 'notas recebidas: o registro das buscas não muda');
select pg_temp.como(:'contador');
select pg_temp.ok(not exists (select 1 from erp.notas_recebidas_buscas), 'notas recebidas: o AF não vê as buscas dos outros');
select pg_temp.como(:'gestor');
select pg_temp.ok(exists (select 1 from erp.notas_recebidas_buscas where user_id = :'analista2'), 'notas recebidas: o AD vê as buscas');
select pg_temp.como(:'leitor');
select pg_temp.erro_igual(format($$select api.buscar_nota_recebida(%L)$$, pg_temp.chave('nfse', '55555555000155', '500')),
  'Sem permissão para lançar', 'notas recebidas: a leitura não busca');

-- ignorar e voltar: o financeiro e o master, com o motivo
select pg_temp.como(:'analista2');
select pg_temp.erro_igual(format($$select api.ignorar_nota_recebida(%L, 'Nota de teste')$$, :'nr1'),
  'Só o financeiro (AF, AO, AD) e o master ignoram nota recebida', 'notas recebidas: quem lança não ignora');
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.ignorar_nota_recebida(%L, '')$$, :'nr1'),
  'Diga o motivo de ignorar a nota', 'notas recebidas: ignorar pede o motivo');
select pg_temp.erro_igual(format($$select api.ignorar_nota_recebida(%L, 'Nota de PJ')$$, :'nr_pj'),
  'Nota não encontrada', 'notas recebidas: o AO não mexe na nota de PJ que ele não vê');
select api.ignorar_nota_recebida(:'nr1', 'Serviço cobrado em duplicidade, o fornecedor vai cancelar');
select pg_temp.ok((select situacao = 'ignorada' and ignorada_por = :'analista' from erp.notas_recebidas where id = :'nr1'),
  'notas recebidas: o AO ignora com o motivo');
select pg_temp.erro_igual(format($$select api.ignorar_nota_recebida(%L, 'De novo')$$, :'nr1'),
  'Só a nota nova se ignora', 'notas recebidas: a ignorada não se ignora de novo');
select pg_temp.ok(erp._lanco_na_empresa(:'spe') and api.buscar_nota_recebida(null, '55555555000155', '500', 1500) is null,
  'notas recebidas: pelo emitente, a nota ignorada não aparece');
select api.voltar_nota_recebida(:'nr1');
select pg_temp.ok((select situacao = 'nova' and ignorada_motivo is null from erp.notas_recebidas where id = :'nr1'),
  'notas recebidas: a ignorada volta a nova');

-- a auditoria (do administrador) esconde a nota de PJ
select pg_temp.como(:'ti');
select pg_temp.ok(exists (select 1 from erp.auditoria where tabela = 'notas_recebidas' and registro = :'nr1')
                  and not exists (select 1 from erp.auditoria where tabela = 'notas_recebidas' and registro = :'nr_pj'),
  'notas recebidas: o administrador vê a auditoria das notas, menos a de PJ');
select pg_temp.como(null);
rollback;

-- ligação com a nota lançada no ERP: a nota recebida acha a lançada e a lançada acha a recebida
begin;
select pg_temp.sis();
select d.id as doc_l, d.empresa_id as emp_l, d.tipo as tipo_l, d.numero as num_l, p.documento as emit_l, e.documento as tom_l,
       d.valor_bruto as val_l
  from erp.documentos_fiscais d join erp.pessoas p on p.id = d.emitente_id
  join erp.empresas em on em.id = d.empresa_id join erp.pessoas e on e.id = em.pessoa_id
 where d.situacao = 'lancado' and d.tipo = 'nfse' and d.numero ~ '^[0-9]+$' and not p.restrita
 order by d.lancado_em limit 1 \gset
select em.id as emp_outra, p.documento as tom_outra from erp.empresas em join erp.pessoas p on p.id = em.pessoa_id
 where em.id <> :'emp_l' and p.documento ~ '^[0-9]{14}$' order by p.documento limit 1 \gset
-- outra chave para o mesmo emitente e número (outro município na chave da NFS-e)
create function pg_temp.chave_b(p_doc text, p_num text) returns text language sql as $$
  select '3550308' || substr(pg_temp.chave('nfse', p_doc, p_num), 8) $$;
-- a mesma nota (emitente, número e valor) noutra empresa, com emissão mais nova: não liga ao documento desta
select erp.registrar_nota_recebida(:'emp_outra', pg_temp.nota('nfse', :'emit_l', ltrim(:'num_l', '0'), :'val_l', :'tom_outra')
         || jsonb_build_object('chave', pg_temp.chave_b(:'emit_l', ltrim(:'num_l', '0')), 'emissao', '2026-11-20'), '<NFSe/>', true) as nr_outra \gset
select pg_temp.ok((select situacao = 'nova' and documento_id is null from erp.notas_recebidas where id = :'nr_outra'),
  'notas recebidas: a nota de outra empresa, com o mesmo emitente e número, não se liga ao documento desta');
-- com outro valor, não liga: fica nova para o financeiro ver
select erp.registrar_nota_recebida(:'emp_l', pg_temp.nota('nfse', :'emit_l', ltrim(:'num_l', '0'), :'val_l'::numeric + 1, :'tom_l')
         || jsonb_build_object('chave', '3304557' || substr(pg_temp.chave('nfse', :'emit_l', ltrim(:'num_l', '0')), 8), 'emissao', '2026-11-21'), '<NFSe/>', true) as nr_valor \gset
select pg_temp.ok((select situacao = 'nova' from erp.notas_recebidas where id = :'nr_valor'),
  'notas recebidas: com valor diferente do lançado, a nota não se liga');
select erp.registrar_nota_recebida(:'emp_l', pg_temp.nota('nfse', :'emit_l', ltrim(:'num_l', '0'), :'val_l', :'tom_l'), '<NFSe/>', true) as nr_l \gset
select pg_temp.ok((select situacao = 'vinculada' and documento_id = :'doc_l' from erp.notas_recebidas where id = :'nr_l'),
  'notas recebidas: a nota que chega depois do lançamento se liga sozinha à nota lançada');
select pg_temp.erro_igual(format($$select erp.registrar_nota_recebida(%L, pg_temp.nota('nfse', %L, %L, 100, %L) || '{"nsu": 99}', '<NFSe/>', true)$$,
                                 :'emp_outra', :'emit_l', ltrim(:'num_l', '0'), :'tom_outra'),
  'A nota já está na caixa de outra empresa', 'notas recebidas: a mesma chave não entra em outra empresa');
-- a nota lançada que é cancelada solta a ligação (o cancelamento vem das operações do banco, como erp_situacao)
set role erp_situacao;
update erp.documentos_fiscais set situacao = 'cancelado', cancelamento = 'recusa' where id = :'doc_l';
reset role;
select pg_temp.ok((select situacao = 'nova' and documento_id is null from erp.notas_recebidas where id = :'nr_l'),
  'notas recebidas: a nota lançada cancelada solta a nota recebida, que volta a nova');
-- e a nota lançada depois acha a nota recebida que já estava na caixa
-- (gravado em nome do analista sem lista, que passa a ser quem lançou)
select pg_temp.como_dono(:'analista2');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, emissao, competencia, valor_bruto)
select '70000000-0000-0000-0000-0000000000a7', d.empresa_id, d.emitente_id, 'nfse', '00' || ltrim(:'num_l', '0'), d.emissao, d.competencia, d.valor_bruto
  from erp.documentos_fiscais d where d.id = :'doc_l';
select pg_temp.sis();
select pg_temp.ok((select situacao = 'nova' from erp.notas_recebidas where id = :'nr_l'), 'notas recebidas: a nota em rascunho no ERP ainda não liga');
set role erp_situacao;
update erp.documentos_fiscais set situacao = 'lancado', lancado_em = clock_timestamp() where id = '70000000-0000-0000-0000-0000000000a7';
reset role;
select pg_temp.ok((select situacao = 'vinculada' and documento_id = '70000000-0000-0000-0000-0000000000a7' from erp.notas_recebidas where id = :'nr_l')
                  and (select situacao = 'nova' from erp.notas_recebidas where id = :'nr_outra')
                  and (select situacao = 'nova' from erp.notas_recebidas where id = :'nr_valor'),
  'notas recebidas: lançada no ERP (com zeros à esquerda no número), a nota se liga à da mesma empresa e valor que já estava na caixa');
-- quem vê o documento lançado vê a nota ligada a ele; quem não vê, não
delete from erp.listas_financeiro where user_id in (:'analista2', :'leitor');
delete from erp.notas_recebidas_acessos where user_id in (:'analista2', :'leitor');
select pg_temp.como(:'analista2');
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.vejo_documento('70000000-0000-0000-0000-0000000000a7')
                  and (select count(*) = 1 and bool_and(id = :'nr_l') from api.notas_recebidas()),
  'notas recebidas: quem vê a nota lançada vê a nota recebida ligada a ela, e só ela');
select pg_temp.como(:'leitor');
select pg_temp.ok(not erp.vejo_documento('70000000-0000-0000-0000-0000000000a7') and not exists (select 1 from api.notas_recebidas()),
  'notas recebidas: quem não vê a nota lançada não vê a nota recebida ligada');
-- NF-e: a série também tem de bater, nos dois caminhos (a nota que chega depois e a lançada depois)
select pg_temp.sis();
select emitente_id as emit_id_l from erp.documentos_fiscais where id = :'doc_l' \gset
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, tipo, numero, serie, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000000b2', :'emp_l', :'emit_id_l', 'nfe', '4242', '2', '2026-11-10', '2026-11-01', 333),
  ('70000000-0000-0000-0000-0000000000b3', :'emp_l', :'emit_id_l', 'nfe', '4242', '3', '2026-11-10', '2026-11-01', 333),
  ('70000000-0000-0000-0000-0000000000b1', :'emp_l', :'emit_id_l', 'nfe', '04242', '001', '2026-11-10', '2026-11-01', 333);
set role erp_situacao;
update erp.documentos_fiscais set situacao = 'lancado', lancado_em = clock_timestamp() where id = '70000000-0000-0000-0000-0000000000b2';
reset role;
select erp.registrar_nota_recebida(:'emp_l', pg_temp.nota('nfe', :'emit_l', '4242', 333, :'tom_l'), '<resNFe/>', false) as nr_s \gset
select pg_temp.ok((select situacao = 'nova' from erp.notas_recebidas where id = :'nr_s'),
  'notas recebidas: a NF-e que chega não se liga à lançada de outra série');
set role erp_situacao;
update erp.documentos_fiscais set situacao = 'lancado', lancado_em = clock_timestamp() where id = '70000000-0000-0000-0000-0000000000b3';
reset role;
select pg_temp.ok((select situacao = 'nova' from erp.notas_recebidas where id = :'nr_s'),
  'notas recebidas: nem a lançada depois com outra série');
set role erp_situacao;
update erp.documentos_fiscais set situacao = 'lancado', lancado_em = clock_timestamp() where id = '70000000-0000-0000-0000-0000000000b1';
reset role;
select pg_temp.ok((select situacao = 'vinculada' and documento_id = '70000000-0000-0000-0000-0000000000b1' from erp.notas_recebidas where id = :'nr_s'),
  'notas recebidas: com a mesma série (zeros à esquerda não contam), a NF-e se liga');
select pg_temp.como(null);
rollback;

-- o login do serviço da busca: só as funções da caixa, e é sistema só dentro delas
begin;
select pg_temp.sis();
select pg_temp.ok(not exists (select 1 from pg_auth_members m join pg_roles r on r.oid = m.member where r.rolname = 'erp_busca_notas')
                  and not exists (select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid where r.rolname = 'erp_busca_notas')
                  and not exists (select 1 from information_schema.role_table_grants where grantee = 'erp_busca_notas')
                  and (select count(*) = 7 from pg_proc p join pg_namespace s on s.oid = p.pronamespace
                        where s.nspname not in ('pg_catalog', 'information_schema') and s.nspname !~ '^pg_(temp|toast)'
                          and has_schema_privilege('erp_busca_notas', s.oid, 'USAGE')
                          and p.prorettype <> 'trigger'::regtype   -- função de gatilho não se chama direto
                          and has_function_privilege('erp_busca_notas', p.oid, 'EXECUTE'))
                  and not has_schema_privilege('erp_busca_notas', 'net', 'USAGE'),
  'busca: o login do serviço não é membro de nada, não tem tabela e só executa as 7 funções dele (em nenhum esquema; nem o net)');
set session authorization erp_busca_notas;
select pg_temp.ok(erp.busca_notas_empresa(:'spe') = '33333333000133', 'busca: o serviço lê o CNPJ da empresa');
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '321', 450), '<resNFe/>', false) as nb \gset
select erp.registrar_leitura_notas(:'spe', 'sefaz', 40, 90, null, null);
select pg_temp.ok((select ultimo_nsu = 40 and lida from erp.busca_notas_leitura(:'spe', 'sefaz'))
                  and (select not lida and ultimo_nsu = 0 from erp.busca_notas_leitura(:'spe', 'adn'))
                  and (select array_agg(c) = array[pg_temp.chave('nfe', '77777777000177', '321')]
                         from erp.busca_notas_sem_ciencia(:'spe', 20) c) is not true,
  'busca: o serviço grava a nota e a leitura e lê onde parou');
-- ciência só até 10 dias da autorização (NT 2020.001; a SEFAZ recusa depois com 596): a nota de 10/11 já não entra;
-- as de dentro do prazo vêm da mais nova para a mais velha
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '322', 450) || jsonb_build_object('emissao', (current_date - 3)::text), '<resNFe/>', false);
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '323', 450) || jsonb_build_object('emissao', (current_date - 1)::text), '<resNFe/>', false);
select erp.registrar_nota_recebida(:'spe', pg_temp.nota('nfe', '77777777000177', '324', 450) || jsonb_build_object('emissao', (current_date - 11)::text), '<resNFe/>', false);
select pg_temp.ok((select array_agg(c) from erp.busca_notas_sem_ciencia(:'spe', 20) c)
                  = array[pg_temp.chave('nfe', '77777777000177', '323'), pg_temp.chave('nfe', '77777777000177', '322')],
  'busca: pede ciência só das NF-e em resumo dos últimos 10 dias, da mais nova para a mais velha');
select erp.registrar_ciencia_nota_recebida(pg_temp.chave('nfe', '77777777000177', '323'));
select erp.registrar_ciencia_nota_recebida(pg_temp.chave('nfe', '77777777000177', '322'));
select erp.registrar_ciencia_nota_recebida(pg_temp.chave('nfe', '77777777000177', '321'));
select pg_temp.ok(not exists (select 1 from erp.busca_notas_sem_ciencia(:'spe', 20)), 'busca: com a ciência, a nota sai da lista');
select pg_temp.erro_igual('select count(*) from erp.notas_recebidas', 'permission denied for table notas_recebidas',
  'busca: o serviço não lê a tabela direto');
select pg_temp.erro_igual('select count(*) from erp.titulos', 'permission denied for table titulos', 'busca: nem outra tabela do ERP');
select pg_temp.erro_igual(format($$select erp.ignorar_nota_recebida(%L, 'xxxx')$$, :'nb'), 'permission denied for function ignorar_nota_recebida',
  'busca: nem outra função');
-- a mesma consulta do serviço (servicos/busca-notas/banco.ts, SQL_NET_ABERTO), que ele roda no começo de cada rodada
select pg_temp.ok(not (select exists (select 1 from pg_namespace n where n.nspname = 'net'
  and (has_schema_privilege(n.oid, 'USAGE')
       or exists (select 1 from pg_class c where c.relnamespace = n.oid and has_table_privilege(c.oid, 'SELECT'))))),
  'busca: o serviço confere que não alcança o net, e consegue conferir');
select pg_temp.erro_igual($$select net.http_post('http://exemplo.invalido')$$, 'permission denied for schema net',
  'busca: o serviço não chama a rede do banco (pg_net, S-143)');
select pg_temp.erro_igual('set role erp_sistema', 'permission denied to set role "erp_sistema"', 'busca: o serviço não vira o papel do sistema');
-- com um login de usuário posto, deixa de ser sistema: não grava em nome de ninguém
select set_config('request.jwt.claim.sub', :'diretor', false);
select pg_temp.erro_igual(format($$select erp.registrar_leitura_notas(%L, 'sefaz', 50, 90, null, null)$$, :'spe'),
  'Só o serviço da busca grava a leitura das notas', 'busca: com login de usuário posto, o serviço não grava');
select set_config('request.jwt.claim.sub', '', false);
reset session authorization;
select pg_temp.sis();
select pg_temp.ok((select ciencia_em is not null from erp.notas_recebidas where id = :'nb')
                  and exists (select 1 from erp.auditoria where tabela = 'notas_recebidas' and registro = :'nb' and por is null),
  'busca: o que o serviço grava fica na auditoria como sistema');
-- a janela do login (migrations 20261123005000 e 006000): abre, fecha e derruba; com o net aberto, abre e avisa (risco aceito)
-- (a resposta num comando e o catálogo no seguinte: o mesmo comando ainda vê o catálogo de antes)
select erp.busca_notas_janela('abrir') as j \gset
select pg_temp.ok(:'j' = 'aberta' and (select rolcanlogin from pg_roles where rolname = 'erp_busca_notas'), 'janela da busca: abre o login');
select erp.busca_notas_janela('fechar') as j \gset
select pg_temp.ok(:'j' = 'fechada' and not (select rolcanlogin from pg_roles where rolname = 'erp_busca_notas'), 'janela da busca: fecha o login');
select erp.busca_notas_janela('abrir');
select erp.busca_notas_janela('encerrar') as j \gset
select pg_temp.ok(:'j' like 'fechada; 0 %' and not (select rolcanlogin from pg_roles where rolname = 'erp_busca_notas'), 'janela da busca: encerrar fecha e derruba as sessões');
grant usage on schema net to public;
select erp.busca_notas_janela('abrir') as j \gset
select pg_temp.ok(:'j' = 'aberta (net aberto)' and (select rolcanlogin from pg_roles where rolname = 'erp_busca_notas'), 'janela da busca: com o net aberto ao login, abre e avisa (S-143, risco aceito)');
select erp.busca_notas_janela('fechar');
revoke usage on schema net from public;
select pg_temp.erro_igual($$select erp.busca_notas_janela('ligar')$$, 'Ação da janela: abrir, fechar ou encerrar', 'janela da busca: só as três ações');
select pg_temp.ok(not has_function_privilege('erp_busca_notas', 'erp.busca_notas_janela(text)', 'EXECUTE')
                  and not has_function_privilege('authenticated', 'erp.busca_notas_janela(text)', 'EXECUTE')
                  and not has_function_privilege('service_role', 'erp.busca_notas_janela(text)', 'EXECUTE'),
  'janela da busca: só o dono das migrations chama');
rollback;

-- ---------------------------------------------------------------------
\echo '# CNPJ alfanumérico (Receita, desde julho/2026)'
begin;
select pg_temp.como(null);
select pg_temp.ok(erp.cnpj_valido('12ABC34501DE35') and erp.cnpj_valido('29732041000154')
                  and not erp.cnpj_valido('12ABC34501DE53') and not erp.cnpj_valido('12abc34501de35')
                  and not erp.cnpj_valido('11111111111111') and not erp.cnpj_valido('12ABC34501DE3') and not erp.cnpj_valido(null),
  'cnpj: o DV confere nos dois formatos (letra vale ASCII − 48), só em maiúsculas');
select pg_temp.ok(erp.cnpj_aceito('12ABC34501DE35') and erp.cnpj_aceito('29732041000154') and erp.cnpj_aceito('29732041000199')
                  and not erp.cnpj_aceito('12ABC34501DE53') and not erp.cnpj_aceito('12abc34501de35'),
  'cnpj: o só de dígitos continua como estava; o com letra só com o DV certo');
insert into erp.pessoas (id, tipo, nome, documento) values ('5a000000-0000-0000-0000-000000000001', 'juridica', 'Alfa Teste Ltda', '12ABC34501DE35');
insert into erp.pessoa_papeis (pessoa_id, papel) values ('5a000000-0000-0000-0000-000000000001', 'fornecedor');
select pg_temp.ok(true, 'cnpj: credor com CNPJ alfanumérico válido entra');
select pg_temp.falha($q$insert into erp.pessoas (tipo, nome, documento) values ('juridica', 'Erro', '12ABC34501DE53')$q$, 'cnpj: alfanumérico com DV errado é recusado');
select pg_temp.falha($q$insert into erp.pessoas (tipo, nome, documento) values ('juridica', 'Erro', '12abc34501de35')$q$, 'cnpj: minúsculas são recusadas');
select pg_temp.falha($q$insert into erp.pessoas (tipo, nome, documento) values ('fisica', 'Erro', '5299822472A')$q$, 'cnpj: CPF continua só com dígitos');
select pg_temp.ok(erp.chave_pix_valida('cpf_cnpj', '12ABC34501DE35') and not erp.chave_pix_valida('cpf_cnpj', '12ABC34501DE53')
                  and erp.chave_pix_valida('cpf_cnpj', '52998224725'),
  'cnpj: chave PIX CPF/CNPJ aceita o alfanumérico com o DV certo');
select pg_temp.ok((select bool_and(pg_get_constraintdef(oid) like '%A-Z%') from pg_constraint
                    where conrelid in ('erp.pix_conferencias'::regclass, 'erp.boleto_conferencias'::regclass) and contype = 'c'
                      and pg_get_constraintdef(oid) like '%cpf_cnpj ~%'),
  'cnpj: a conferência de quem recebe guarda o documento com letras');
select pg_temp.ok(exists (select 1 from api.fornecedores('12.ABC.345/01DE') where id = '5a000000-0000-0000-0000-000000000001')
                  and exists (select 1 from api.fornecedores('12abc') where id = '5a000000-0000-0000-0000-000000000001'),
  'cnpj: a busca do fornecedor pelo documento não joga fora as letras');
-- revisão do patch: as mutações que sobreviviam
select pg_temp.ok(not erp.cnpj_valido('12ABC34501DE36') and not erp.cnpj_aceito('12ABC34501DE36'), 'cnpj: o 2º DV também é conferido');
select pg_temp.falha($q$insert into erp.pessoas (tipo, nome, documento) values ('juridica', 'Erro', '12abc34501de35')$q$, 'cnpj: credor com letras minúsculas é recusado (evita credor duplicado)');
insert into erp.compromisso_pagamentos (compromisso_id, modo, banco, agencia, conta, conta_digito, conta_tipo, titular_documento, excecao)
  select c.id, 'ted', '341', '1234', '56789', '0', 'corrente', '12ABC34501DE35', 'teste do titular alfanumérico'
    from erp.compromissos c where not exists (select 1 from erp.compromisso_pagamentos g where g.compromisso_id = c.id) limit 1;
select pg_temp.ok(exists (select 1 from erp.compromisso_pagamentos where titular_documento = '12ABC34501DE35'), 'cnpj: titular da TED com CNPJ alfanumérico válido entra');
select pg_temp.falha($q$update erp.compromisso_pagamentos set titular_documento = '12ABC34501DE53' where modo = 'ted'$q$, 'cnpj: titular da TED com DV errado é recusado');
select pg_temp.ok((select bool_and(erp._credor_confere(jsonb_build_object('cpf_cnpj', p.documento, 'nome', p.nome), t.id)
                                   and not erp._credor_confere(jsonb_build_object('cpf_cnpj', 'CPF' || left(p.documento, 11), 'nome', p.nome), t.id))
                     from (select * from erp.titulos limit 5) t join erp.pessoas p on p.id = t.pessoa_id where p.documento is not null)
                  and not erp._credor_confere('{"cpf_cnpj": "CPF12345678901"}'::jsonb, null),
  'cnpj: documento da conferência com letras soltas (CPF12345678901) não casa com o credor');
select pg_temp.como(:'diretor');
select pg_temp.ok((api.identificar_nota('{"emitente": "12.ABC.345/01DE-35"}'::jsonb)->'fornecedor'->>'id') = '5a000000-0000-0000-0000-000000000001',
  'cnpj: a nota de emitente com CNPJ alfanumérico acha o fornecedor');
select pg_temp.como(null);
rollback;

-- ---------------------------------------------------------------------
\echo '# nota do mês da conta recorrente aprovada: só o rito da conta (Moises, 23/11/2026)'
begin;
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador'), ('AO', :'analista2') on conflict do nothing;
select pg_temp.volta();
select pg_temp.ok(erp.rotulo_vaga('AF_AO') = 'AF, AO ou AD' and erp.rotulo_vaga('AO_CENTRO') = 'AO do centro', 'rito: os rótulos das vagas');
select pg_temp.ok(erp._ocupa_vaga('AF_AO', null, :'analista2') and erp._ocupa_vaga('AF_AO', null, :'contador')
                  and not erp._ocupa_vaga('AF_AO', null, :'gestor') and not erp._ocupa_vaga('AF_AO', null, :'leitor'),
  'rito: a vaga AF_AO é da AF, da AO ou da AD');
select pg_temp.como(:'analista');
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, dia_vencimento, instalacao, faixa_mensal, teto_anual) values
  ('61000000-0000-0000-0000-0000000000c1', :'spe', 'consumo', '10000000-0000-0000-0000-000000000007', 'Luz do rito', '2027-01-01', 'mensal', 6, 'RITO-1', 1000, 5000),
  ('61000000-0000-0000-0000-0000000000c2', :'spe', 'consumo', '10000000-0000-0000-0000-000000000007', 'Água sem aprovação', '2027-01-01', 'mensal', 6, 'RITO-2', 1000, 5000);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, valor_periodo, dia_vencimento) values
  ('61000000-0000-0000-0000-0000000000c3', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software do rito', '2027-01-01', 'mensal', 500, 10);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  select x::uuid, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100
    from unnest(array['61000000-0000-0000-0000-0000000000c1', '61000000-0000-0000-0000-0000000000c2', '61000000-0000-0000-0000-0000000000c3']) x;
select pg_temp.como(:'gestor');
select erp.decidir_compromisso('61000000-0000-0000-0000-0000000000c1', true), erp.decidir_compromisso('61000000-0000-0000-0000-0000000000c3', true);
select pg_temp.como(:'contador');
select pg_temp.ok(erp.decidir_compromisso('61000000-0000-0000-0000-0000000000c1', true) = 'aprovado'
                  and erp.decidir_compromisso('61000000-0000-0000-0000-0000000000c3', true) = 'aprovado', 'rito: as duas contas aprovadas');
-- as notas (o número diz o caso)
select pg_temp.como(:'analista');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000c0001', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c1', 'fatura', 'R1', '2027-01-05', '2027-01-01', 1300),
  ('70000000-0000-0000-0000-0000000c0002', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c1', 'fatura', 'R2', '2027-02-05', '2027-02-01', 1300.01),
  ('70000000-0000-0000-0000-0000000c0003', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c1', 'fatura', 'R3', '2027-03-05', '2027-03-01', 1150),
  ('70000000-0000-0000-0000-0000000c0004', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c1', 'fatura', 'R4', '2027-04-05', '2027-04-01', 1250),
  ('70000000-0000-0000-0000-0000000c0005', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c2', 'fatura', 'R5', '2027-01-05', '2027-01-01', 900),
  ('70000000-0000-0000-0000-0000000c0006', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R6', '2027-01-05', '2027-01-01', 500),
  ('70000000-0000-0000-0000-0000000c0007', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R7', '2027-02-05', '2027-02-01', 500.01),
  ('70000000-0000-0000-0000-0000000c0008', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c1', 'fatura', 'R8', '2027-05-05', '2027-05-01', 500);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  select d.id, :'ne_vm', :'cc_mkt', case when d.numero = 'R8' then pg_temp.nat('04.01') else pg_temp.nat('05.01.04') end, 100
    from erp.documentos_fiscais d where d.id::text like '70000000-0000-0000-0000-0000000c000%';
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0001', array['2027-01-20']::date[]) as r1 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0002', array['2027-02-20']::date[]) as r2 \gset
select pg_temp.sis(); update erp.regra_alcada_pagamento set recorrente_tolerancia_pct = 10; select pg_temp.volta();
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0003', array['2027-03-20']::date[]) as r3 \gset
select pg_temp.sis(); update erp.regra_alcada_pagamento set recorrente_tolerancia_pct = 30; select pg_temp.volta();
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0004', array['2027-04-20']::date[]) as r4 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0005', array['2027-01-20']::date[]) as r5 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0006', array['2027-01-20']::date[]) as r6 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0007', array['2027-02-20']::date[]) as r7 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0008', array['2027-05-20']::date[]) as r8 \gset
select pg_temp.sis();
select pg_temp.ok((select count(*) = 1 and bool_and(fases = '{AF_AO}' and alcada_id is null and compromisso_id = '61000000-0000-0000-0000-0000000000c1'
                                                    and centro_custo_id = :'cc_mkt' and valor_no_centro = 1300)
                     from erp.titulo_alcadas where titulo_id = :'r1'),
  'rito: consumo até 30% acima da previsão do mês vai direto à AF, AO ou AD, sem as faixas');
select pg_temp.ok((select count(*) = 1 and bool_and(fases = '{AREA,AF_AO}' and not paralelo and compromisso_id is not null)
                     from erp.titulo_alcadas where titulo_id = :'r2'),
  'rito: consumo acima da tolerância passa antes pelo gestor do centro');
select pg_temp.ok((select fases = '{AREA,AF_AO}' from erp.titulo_alcadas where titulo_id = :'r3'), 'rito: a tolerância é configurável (10%: 1.150 passa dela)');
select pg_temp.ok((select fases = '{AREA,AF_AO}' from erp.titulo_alcadas where titulo_id = :'r4'),
  'rito: dentro da tolerância, mas o ano passaria do teto: o gestor primeiro');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null and alcada_id is not null) from erp.titulo_alcadas where titulo_id = :'r5'),
  'rito: conta ainda não aprovada segue as faixas do centro');
select pg_temp.ok((select count(*) = 1 and bool_and(fases = '{AREA,AF}' and not paralelo and compromisso_id = '61000000-0000-0000-0000-0000000000c3')
                     from erp.titulo_alcadas where titulo_id = :'r6'),
  'rito: assinatura dentro da previsão do mês: gestor, depois AF (ou AD)');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null and alcada_id is not null) from erp.titulo_alcadas where titulo_id = :'r7'),
  'rito: assinatura acima da previsão do mês segue as faixas do centro');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null and alcada_id is not null) from erp.titulo_alcadas where titulo_id = :'r8'),
  'rito: nota com natureza fora do rateio aprovado da conta segue as faixas');
select pg_temp.falha($$update erp.regra_alcada_pagamento set recorrente_tolerancia_pct = 150$$, 'rito: tolerância acima de 100% é recusada');
select pg_temp.volta();
-- a nota soma no acumulado do mês do centro para os outros títulos
select pg_temp.como(:'analista');
insert into erp.titulos (id, empresa_id, tipo, pessoa_id, emissao, competencia, valor) values
  ('82000000-0000-0000-0000-0000000c0001', :'spe', 'avulso', '10000000-0000-0000-0000-000000000007', '2027-01-06', '2027-01-01', 100);
insert into erp.parcelas (titulo_id, numero, vencimento, valor) values ('82000000-0000-0000-0000-0000000c0001', 1, '2027-01-25', 100);
insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('82000000-0000-0000-0000-0000000c0001', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.confirmar_titulo('82000000-0000-0000-0000-0000000c0001');
select pg_temp.sis();
select pg_temp.ok((select acumulado >= 100 + 1300 + 900 + 500 and :'r1'::uuid = any(titulos) and :'r6'::uuid = any(titulos)
                     from erp.titulo_alcadas where titulo_id = '82000000-0000-0000-0000-0000000c0001' and divisao_id is null),
  'rito: as notas da conta continuam no acumulado do mês do centro');
select pg_temp.volta();
-- quem aprova: na fatura dentro da tolerância, a AO sozinha; acima, a AO espera o gestor
select pg_temp.como(:'gestor');
select pg_temp.falha(format('select erp.decidir_titulo(%L, true)', :'r1'), 'rito: o gestor não ocupa a vaga AF, AO ou AD');
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.decidir_titulo(:'r1', true) = 'aprovado', 'rito: a AO aprova sozinha a fatura dentro da tolerância');
select pg_temp.falha(format('select erp.decidir_titulo(%L, true)', :'r2'), 'rito: acima da tolerância, a AO espera o gestor');
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'r2', true);
select pg_temp.como(:'analista2');
select pg_temp.ok(erp.decidir_titulo(:'r2', true) = 'aprovado', 'rito: depois do gestor, a AO completa');
select pg_temp.como(:'analista2');
select pg_temp.falha(format('select erp.decidir_titulo(%L, true)', :'r6'), 'rito: na assinatura a AO não aprova (é o gestor, depois a AF)');
-- revisão de segurança (24/11): a previsão é do mês (soma das notas), só na vigência, e os caminhos que voltam às faixas
select pg_temp.como(:'analista');
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, dia_vencimento, instalacao, faixa_mensal, teto_anual) values
  ('61000000-0000-0000-0000-0000000000c5', :'spe', 'consumo', '10000000-0000-0000-0000-000000000007', 'Luz de duas faturas', '2027-01-01', 'mensal', 6, 'RITO-5', 1000, 50000);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, fim, periodicidade, valor_periodo, valor_total, dia_vencimento) values
  ('61000000-0000-0000-0000-0000000000c6', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software até março', '2027-01-01', '2027-03-31', 'mensal', 500, null, 10),
  ('61000000-0000-0000-0000-0000000000c7', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software encerrado', '2027-01-01', null, 'mensal', 500, null, 10),
  ('61000000-0000-0000-0000-0000000000c8', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software até 700', '2027-01-01', null, 'mensal', 500, 700, 10);
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, valor_total) values
  ('61000000-0000-0000-0000-0000000000c9', :'spe', 'contrato', '10000000-0000-0000-0000-000000000007', 'Contrato sem fim', '2027-01-01', 10000);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  select ('61000000-0000-0000-0000-0000000000c' || x)::uuid, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100 from unnest(array['5','6','7','8','9']) x;
select pg_temp.como(:'gestor');
select erp.decidir_compromisso(('61000000-0000-0000-0000-0000000000c' || x)::uuid, true) from unnest(array['5','6','7','8','9']) x;
select pg_temp.como(:'contador');
select pg_temp.ok((select bool_and(erp.decidir_compromisso(('61000000-0000-0000-0000-0000000000c' || x)::uuid, true) = 'aprovado')
                     from unnest(array['5','6','7','8','9']) x), 'rito: as contas da revisão aprovadas');
select pg_temp.como(:'analista');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000c0011', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c5', 'fatura', 'R11', '2027-01-05', '2027-01-01', 800),
  ('70000000-0000-0000-0000-0000000c0012', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c5', 'fatura', 'R12', '2027-01-06', '2027-01-01', 800),
  ('70000000-0000-0000-0000-0000000c0013', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R13', '2027-01-06', '2027-01-01', 1),
  ('70000000-0000-0000-0000-0000000c0014', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c6', 'nfse', 'R14', '2027-04-05', '2027-04-01', 500),
  ('70000000-0000-0000-0000-0000000c0015', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c6', 'nfse', 'R15', '2026-12-05', '2026-12-01', 500),
  ('70000000-0000-0000-0000-0000000c0016', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c6', 'nfse', 'R16', '2027-03-05', '2027-03-01', 500),
  ('70000000-0000-0000-0000-0000000c0017', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c7', 'nfse', 'R17', '2027-01-05', '2027-01-01', 500),
  ('70000000-0000-0000-0000-0000000c0018', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c8', 'nfse', 'R18', '2027-01-05', '2027-01-01', 500),
  ('70000000-0000-0000-0000-0000000c0019', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c8', 'nfse', 'R19', '2027-02-05', '2027-02-01', 500),
  ('70000000-0000-0000-0000-0000000c0020', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c9', 'nfse', 'R20', '2027-01-05', '2027-01-01', 100),
  ('70000000-0000-0000-0000-0000000c0021', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R21', '2027-03-05', '2027-03-01', 500);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  select d.id, :'ne_vm', case when d.numero = 'R21' then :'cc_obra'::uuid else :'cc_mkt'::uuid end,
         pg_temp.nat('05.01.04'), 100
    from erp.documentos_fiscais d where d.numero in ('R11','R12','R13','R14','R15','R16','R17','R18','R19','R20','R21')
     and d.compromisso_id::text like '61000000-0000-0000-0000-0000000000c%';
-- a conta encerrada depois de a nota entrar
select pg_temp.sis(); update erp.compromissos set situacao = 'encerrado' where id = '61000000-0000-0000-0000-0000000000c7'; select pg_temp.volta();
select pg_temp.como(:'analista');
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0011', array['2027-01-20']::date[]) as r11 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0012', array['2027-01-21']::date[]) as r12 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0013', array['2027-01-21']::date[]) as r13 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0014', array['2027-04-20']::date[]) as r14 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0015', array['2026-12-20']::date[]) as r15 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0016', array['2027-03-20']::date[]) as r16 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0017', array['2027-01-20']::date[]) as r17 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0018', array['2027-01-20']::date[]) as r18 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0019', array['2027-02-20']::date[]) as r19 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0020', array['2027-01-20']::date[]) as r20 \gset
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0021', array['2027-03-20']::date[]) as r21 \gset
select pg_temp.sis();
select pg_temp.ok((select fases = '{AF_AO}' from erp.titulo_alcadas where titulo_id = :'r11')
                  and (select fases = '{AREA,AF_AO}' and compromisso_id is not null from erp.titulo_alcadas where titulo_id = :'r12'),
  'rito: duas faturas de consumo no mesmo mês somam contra a previsão (a segunda passa da tolerância e vai ao gestor)');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null and alcada_id is not null) from erp.titulo_alcadas where titulo_id = :'r13'),
  'rito: segunda nota da assinatura no mês, que passa da previsão somada, segue as faixas');
select pg_temp.ok((select bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id in (:'r14', :'r15'))
                  and (select fases = '{AREA,AF}' and compromisso_id is not null from erp.titulo_alcadas where titulo_id = :'r16'),
  'rito: só na vigência (antes do início e depois do fim, as faixas; o último mês, o rito)');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id = :'r17'),
  'rito: conta encerrada segue as faixas');
select pg_temp.ok((select fases = '{AREA,AF}' and compromisso_id is not null from erp.titulo_alcadas where titulo_id = :'r18')
                  and (select count(*) >= 1 and bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id = :'r19'),
  'rito: a nota que passaria do valor total da conta segue as faixas');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id = :'r20'),
  'rito: sem previsão do mês (contrato sem fim e sem calendário), as faixas');
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id = :'r21'),
  'rito: nota num centro fora do rateio da conta (mesma natureza) segue as faixas');
select pg_temp.volta();
-- nota de outro fornecedor presa à conta: o gatilho do contrato já recusa (t_contrato_confere), antes do rito
select pg_temp.como(:'analista');
select pg_temp.erro_igual($$insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto)
  values ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R99', '2027-01-05', '2027-01-01', 500)$$,
  'O contrato é de outro fornecedor', 'rito: nota de outro fornecedor não se prende à conta');
-- sem gente na vaga: o gestor que lança não aprova a própria nota, e a vaga vai ao master
select pg_temp.como(:'gestor');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000c0022', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R22', '2027-04-05', '2027-04-01', 500);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000c0022', :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0022', array['2027-04-20']::date[]) as r22 \gset
select pg_temp.sis();
select pg_temp.ok((select fases = '{AREA,AF}' and compromisso_id is not null and falta_aprovadores and vagas_sem_gente = '{AREA}'
                     from erp.titulo_alcadas where titulo_id = :'r22')
                  and exists (select 1 from erp.eventos where tipo = 'alcada_falta_aprovadores' and registro = :'r22'),
  'rito: sem gestor que possa aprovar (o único lançou), a vaga vai ao master com o aviso');
select pg_temp.volta();
-- divisão fora do rateio da conta
select pg_temp.sis(); insert into erp.divisoes (id, centro_custo_id, nome) values ('8d000000-0000-0000-0000-0000000000c1', :'cc_mkt', 'Divisão do rito'); select pg_temp.volta();
select pg_temp.como(:'analista');
insert into erp.documentos_fiscais (id, empresa_id, emitente_id, compromisso_id, tipo, numero, emissao, competencia, valor_bruto) values
  ('70000000-0000-0000-0000-0000000c0023', :'spe', '10000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-0000000000c3', 'nfse', 'R23', '2027-05-05', '2027-05-01', 500);
insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, natureza_id, percentual) values
  ('70000000-0000-0000-0000-0000000c0023', :'ne_vm', :'cc_mkt', '8d000000-0000-0000-0000-0000000000c1', pg_temp.nat('05.01.04'), 100);
select erp.lancar_documento('70000000-0000-0000-0000-0000000c0023', array['2027-05-20']::date[]) as r23 \gset
select pg_temp.sis();
select pg_temp.ok((select count(*) >= 1 and bool_and(compromisso_id is null) from erp.titulo_alcadas where titulo_id = :'r23'),
  'rito: nota numa divisão fora do rateio da conta segue as faixas');
select pg_temp.volta();
select pg_temp.como(null);
rollback;

\echo '# forma de pagamento do cadastro no título, com a TED (Moises, 23/11/2026)'
begin;
select pg_temp.sis();
insert into erp.centro_aprovadores values (:'cc_mkt', :'gestor') on conflict do nothing;
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'contador') on conflict do nothing;
insert into erp.pessoa_papeis values ('10000000-0000-0000-0000-000000000007', 'fornecedor') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'analista');
insert into erp.compromissos (id, empresa_id, tipo, pessoa_id, descricao, inicio, periodicidade, valor_periodo, dia_vencimento) values
  ('61000000-0000-0000-0000-0000000000d1', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software com PIX fixo', '2027-01-01', 'mensal', 500, 10),
  ('61000000-0000-0000-0000-0000000000d2', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software com TED', '2027-01-01', 'mensal', 500, 10),
  ('61000000-0000-0000-0000-0000000000d3', :'spe', 'assinatura', '10000000-0000-0000-0000-000000000007', 'Software com boleto', '2027-01-01', 'mensal', 500, 10);
insert into erp.compromisso_rateios (compromisso_id, nucleo_economico_id, centro_custo_id, natureza_id, percentual)
  select x::uuid, :'ne_vm', :'cc_mkt', pg_temp.nat('05.01.04'), 100
    from unnest(array['61000000-0000-0000-0000-0000000000d1', '61000000-0000-0000-0000-0000000000d2', '61000000-0000-0000-0000-0000000000d3']) x;
insert into erp.compromisso_pagamentos (compromisso_id, modo, pix_tipo, pix_chave) values ('61000000-0000-0000-0000-0000000000d1', 'pix', 'cpf_cnpj', '77777777000177');
insert into erp.compromisso_pagamentos (compromisso_id, modo, banco, agencia, conta, conta_digito, conta_tipo, titular_documento)
  values ('61000000-0000-0000-0000-0000000000d2', 'ted', '341', '1234', '56789', '0', 'corrente', '77777777000177');
insert into erp.compromisso_pagamentos (compromisso_id, modo) values ('61000000-0000-0000-0000-0000000000d3', 'cobranca');
select pg_temp.como(:'gestor');
select erp.decidir_compromisso(x::uuid, true)
  from unnest(array['61000000-0000-0000-0000-0000000000d1', '61000000-0000-0000-0000-0000000000d2', '61000000-0000-0000-0000-0000000000d3']) x;
select pg_temp.como(:'contador');
select pg_temp.ok((select bool_and(erp.decidir_compromisso(x::uuid, true) = 'aprovado')
                     from unnest(array['61000000-0000-0000-0000-0000000000d1', '61000000-0000-0000-0000-0000000000d2', '61000000-0000-0000-0000-0000000000d3']) x),
  'forma do cadastro: as três contas aprovadas');
select pg_temp.como(:'analista');
select jsonb_build_object('empresa', :'spe', 'fornecedor', '10000000-0000-0000-0000-000000000007', 'tipo', 'nfse',
  'emissao', '2027-01-05', 'competencia', '2027-01-01', 'valor', 500,
  'rateio', jsonb_build_array(jsonb_build_object('nucleo', :'ne_vm', 'centro', :'cc_mkt', 'natureza', pg_temp.nat('05.01.04'), 'percentual', 100)))::text as fbase \gset
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-1', 'compromisso', '61000000-0000-0000-0000-0000000000d1',
  'parcelas', '[{"vencimento": "2027-01-20", "forma": "cadastro"}]'::jsonb)) as fc1 \gset
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-2', 'compromisso', '61000000-0000-0000-0000-0000000000d2',
  'parcelas', '[{"vencimento": "2027-01-20", "forma": "cadastro"}]'::jsonb)) as fc2 \gset
select pg_temp.ok((select forma = 'pix' and pix_tipo = 'cpf_cnpj' and pix_chave = '77777777000177' and pix_excecao is null
                     from erp.parcela_pagamentos where titulo_id = :'fc1'),
  'forma do cadastro: a parcela recebe o PIX fixo da conta');
select pg_temp.ok((select forma = 'ted' and ted_banco = '341' and ted_agencia = '1234' and ted_conta = '56789' and ted_conta_digito = '0'
                          and ted_conta_tipo = 'corrente' and ted_titular_documento = '77777777000177' and ted_excecao is null
                     from erp.parcela_pagamentos where titulo_id = :'fc2'),
  'forma do cadastro: a parcela recebe a TED da conta');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, :'fbase'::jsonb || jsonb_build_object('numero', 'FC-3',
  'compromisso', '61000000-0000-0000-0000-0000000000d3', 'parcelas', '[{"vencimento": "2027-01-20", "forma": "cadastro"}]'::jsonb)),
  'A conta não tem PIX fixo nem TED no cadastro: informe a forma de pagamento desta cobrança',
  'forma do cadastro: conta "vem com cada cobrança" não tem forma para copiar');
select pg_temp.ok(not exists (select 1 from erp.avisos_forma_pagamento(:'fc1') a where array_to_string(a.avisos, '|') like '%Diferente%'),
  'forma do cadastro: a parcela com a forma da conta não tem o aviso de diferença');
select pg_temp.ok((select 'Conta da TED nova para este credor' = any (avisos) from erp.avisos_forma_pagamento(:'fc2') where numero = 1),
  'TED: a conta nunca usada com o credor aparece para quem aprova');
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-9', 'compromisso', '61000000-0000-0000-0000-0000000000d2',
  'parcelas', '[{"vencimento": "2027-01-21", "forma": "cadastro"}]'::jsonb)) as fc9 \gset
select pg_temp.ok((select 'Conta da TED nova para este credor' = any (avisos) from erp.avisos_forma_pagamento(:'fc9') where numero = 1),
  'TED: a conta de outro título que ainda não foi ao Sienge não conta como conhecida (lançar não cala o alerta)');
-- a TED na parcela: o titular é o credor, ou só com a justificativa
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set ted_titular_documento = '29732041000154' where titulo_id = %L$$, :'fc2'),
  'A conta da TED da parcela 1 não é do credor do título (só com a justificativa da exceção)',
  'TED: conta de outra pessoa sem justificativa é recusada');
update erp.parcela_pagamentos set ted_titular_documento = '29732041000154', ted_excecao = 'Conta da administradora' where titulo_id = :'fc2';
select pg_temp.ok((select 'Conta da TED de outra pessoa: Conta da administradora' = any (avisos) from erp.avisos_forma_pagamento(:'fc2') where numero = 1)
                  and (select array_to_string(avisos, '|') like '%Diferente da forma cadastrada na conta recorrente: TED (banco 341, agência 1234, conta 56789-0). A AF escolhe qual vale%'
                         from erp.avisos_forma_pagamento(:'fc2') where numero = 1),
  'TED: com a justificativa entra, e quem aprova vê a justificativa e a diferença do cadastro');
update erp.parcela_pagamentos set ted_titular_documento = '77777777000177', ted_excecao = 'sobra' where titulo_id = :'fc2';
select pg_temp.ok((select ted_excecao is null from erp.parcela_pagamentos where titulo_id = :'fc2'), 'TED: a justificativa que sobra some');
select pg_temp.falha(format($$update erp.parcela_pagamentos set ted_conta = null where titulo_id = %L$$, :'fc2'), 'TED: sem a conta é recusada');
select pg_temp.falha(format($$update erp.parcela_pagamentos set ted_banco = '34' where titulo_id = %L$$, :'fc2'), 'TED: banco com 3 dígitos');
select pg_temp.falha(format($$update erp.parcela_pagamentos set pix_copia_cola = '00020126360014br.gov.bcb.pix0114777777770001775204000053039865802BR5918FORNECEDOR EXEMPLO6009SAO PAULO62070503***63049C9D' where titulo_id = %L$$, :'fc2'),
  'TED: não leva PIX copia e cola');
select pg_temp.falha(format($$update erp.parcela_pagamentos set ted_excecao = 'x' where titulo_id = %L and forma = 'pix'$$, :'fc1'),
  'TED: os campos da TED só na TED');
-- veio de outra forma: a AF escolhe
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-4', 'compromisso', '61000000-0000-0000-0000-0000000000d1',
  'parcelas', '[{"vencimento": "2027-01-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb)) as fc4 \gset
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-5', 'compromisso', '61000000-0000-0000-0000-0000000000d3',
  'parcelas', '[{"vencimento": "2027-01-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "agencia@example.com"}]'::jsonb)) as fc5 \gset
select pg_temp.ok((select array_to_string(avisos, '|') like '%Diferente da forma cadastrada na conta recorrente: PIX fixo (77777777000177). A AF escolhe qual vale%'
                     from erp.avisos_forma_pagamento(:'fc4') where numero = 1)
                  and (select array_to_string(avisos, '|') like '%Diferente da forma cadastrada na conta recorrente: vem com cada cobrança%'
                         from erp.avisos_forma_pagamento(:'fc5') where numero = 1),
  'forma do cadastro: a forma diferente da cadastrada aparece para quem aprova');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc4'), 'A escolha da forma de pagamento é da AF',
  'forma do cadastro: quem lançou (e não é AF) não troca');
select pg_temp.como(:'gestor');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc4'), 'A escolha da forma de pagamento é da AF',
  'forma do cadastro: o gestor não troca');
select erp.decidir_titulo(:'fc4', true);
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_tipo = 'cpf_cnpj', pix_chave = '77777777000177' where titulo_id = %L$$, :'fc4'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'forma do cadastro: depois do voto, nem a forma do cadastro entra sem a escolha da AF');
select pg_temp.volta();
select pg_temp.como(:'contador');
select api.usar_forma_do_cadastro(:'fc4') as trocadas \gset
select pg_temp.ok(:trocadas = 1
                  and (select forma = 'pix' and pix_tipo = 'cpf_cnpj' and pix_chave = '77777777000177' from erp.parcela_pagamentos where titulo_id = :'fc4')
                  and exists (select 1 from erp.titulo_forma_cadastro where titulo_id = :'fc4' and por = :'contador'),
  'forma do cadastro: a AF troca, depois do voto do gestor, e fica registrado');
select pg_temp.ok((select 'A AF trocou para a forma cadastrada na conta recorrente' = any (avisos)
                          and array_to_string(avisos, '|') not like '%Diferente%' from erp.avisos_forma_pagamento(:'fc4') where numero = 1),
  'forma do cadastro: quem aprova vê que a AF trocou');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc4'), 'As parcelas já estão com a forma cadastrada',
  'forma do cadastro: trocar de novo não faz nada');
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_tipo = 'email', pix_chave = 'agencia@example.com' where titulo_id = %L$$, :'fc4'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'forma do cadastro: a escolha da AF só abre a forma do cadastro');
select pg_temp.volta();
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc5'), 'Na conta, a forma vem com cada cobrança: vale a desta nota',
  'forma do cadastro: na conta "vem com cada cobrança" não há o que trocar');
select pg_temp.ok(erp.decidir_titulo(:'fc4', true) = 'aprovado', 'forma do cadastro: a AF aprova depois de trocar');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc4'), 'A forma só se troca com o título em aprovação',
  'forma do cadastro: título aprovado não troca');
-- a TED no pedido ao Sienge
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'fc2', true);
select pg_temp.como(:'contador');
select erp.decidir_titulo(:'fc2', true);
select pg_temp.sis();
insert into erp.codigos_externos (sistema, tabela, registro_id, codigo) values
  ('sienge', 'empresas', :'spe', '11'), ('sienge', 'pessoas', '10000000-0000-0000-0000-000000000007', '823') on conflict do nothing;
insert into erp.sienge_centros (nucleo_economico_id, centro_custo_id, sienge_centro) values (:'ne_vm', :'cc_mkt', 100) on conflict do nothing;
insert into erp.sienge_contas (natureza_id, centro_custo_id, sienge_conta) values (pg_temp.nat('05.01.04'), :'cc_mkt', '2030224') on conflict do nothing;
select erp.sienge_pedido(:'fc2') as pedted \gset
select pg_temp.ok((select x->>'forma' = 'ted' and x->'ted'->>'banco' = '341' and x->'ted'->>'agencia' = '1234' and x->'ted'->>'conta' = '56789'
                          and x->'ted'->>'conta_digito' = '0' and x->'ted'->>'conta_tipo' = 'corrente'
                          and x->'ted'->>'titular_documento' = '77777777000177' and x->'ted'->>'titular_nome' = 'Agência Beta'
                     from jsonb_array_elements(:'pedted'::jsonb->'parcelas') x),
  'TED: o pedido ao Sienge leva banco, agência, conta, tipo e o titular');
select erp.sienge_enfileirar();
select pg_temp.ok(exists (select 1 from erp.eventos where tipo = 'conta_ted_nova' and registro = :'fc2'),
  'TED: conta nunca usada com o credor gera o alerta crítico ao ir para a fila do Sienge');
-- a conta já usada com o credor, mas com outro titular, é conta nova (revisão de segurança, 24/11)
select pg_temp.ok((select 'Conta da TED nova para este credor' = any (avisos) from erp.avisos_forma_pagamento(:'fc9') where numero = 1),
  'TED: na fila do Sienge, mas ainda sem o título criado lá, a conta continua nova');
update erp.sienge_envios set sienge_id = 9901 where titulo_id = :'fc2';
select pg_temp.ok(erp._conta_ted_conhecida('10000000-0000-0000-0000-000000000007', '341', '1234', '56789', '0', '77777777000177', :'fc1')
                  and not erp._conta_ted_conhecida('10000000-0000-0000-0000-000000000007', '341', '1234', '56789', '0', '29732041000154', :'fc1'),
  'TED: a conta conhecida é a mesma conta com o mesmo titular');
select pg_temp.volta();
-- a troca da AF só vale na transação dela (revisão de segurança, 24/11): com o registro de outra transação, a forma não muda
select pg_temp.como(:'analista');
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-7', 'compromisso', '61000000-0000-0000-0000-0000000000d1',
  'parcelas', '[{"vencimento": "2027-02-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "outra@example.com"}]'::jsonb)) as fc7 \gset
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-11', 'compromisso', '61000000-0000-0000-0000-0000000000d1',
  'parcelas', '[{"vencimento": "2027-02-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "outra@example.com"}]'::jsonb)) as fc11 \gset
select pg_temp.como(:'gestor');
select erp.decidir_titulo(:'fc7', true);
select pg_temp.como(:'contador');
select api.usar_forma_do_cadastro(:'fc7');
select pg_temp.como(null);
update erp.titulo_forma_cadastro set txid = txid - 1 where titulo_id = :'fc7';
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_chave = pix_chave where titulo_id = %L$$, :'fc7'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'forma do cadastro: a escolha da AF gravada em outra transação não abre a forma, nem para mantê-la');
select pg_temp.volta();
select pg_temp.como(null);
update erp.titulo_forma_cadastro set txid = txid_current() where titulo_id = :'fc7';
-- a versão do cadastro esperando aprovação nunca vale como "a cadastrada" (revisão de segurança, 24/11)
select pg_temp.como(:'analista');
update erp.compromisso_pagamentos set pix_tipo = 'email', pix_chave = 'agencia@example.com' where compromisso_id = '61000000-0000-0000-0000-0000000000d1';
select pg_temp.sis();
select pg_temp.ok(not erp.compromisso_aprovado('61000000-0000-0000-0000-0000000000d1'), 'forma do cadastro: mudar a forma volta a conta à aprovação');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.erro_igual(format($$select api.lancar_titulo(%L)$$, :'fbase'::jsonb || jsonb_build_object('numero', 'FC-8',
  'compromisso', '61000000-0000-0000-0000-0000000000d1', 'parcelas', '[{"vencimento": "2027-02-20", "forma": "cadastro"}]'::jsonb)),
  'O cadastro da forma está esperando aprovação: informe a forma de pagamento desta cobrança',
  'forma do cadastro: a versão esperando aprovação não vai ao título');
select pg_temp.sis();
select pg_temp.erro_igual(format($$update erp.parcela_pagamentos set pix_tipo = 'email', pix_chave = 'agencia@example.com' where titulo_id = %L$$, :'fc7'),
  'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)',
  'forma do cadastro: mesmo com a escolha da AF nesta transação, a forma esperando aprovação não entra depois do voto');
select pg_temp.volta();
select pg_temp.como(:'analista');
select pg_temp.ok((select 'O cadastro da forma de pagamento da conta está esperando aprovação' = any (avisos)
                          and array_to_string(avisos, '|') not like '%cadastrada%' and array_to_string(avisos, '|') not like '%agencia@%'
                     from erp.avisos_forma_pagamento(:'fc11') where numero = 1),
  'forma do cadastro: o aviso diz que o cadastro espera aprovação e não chama a versão pendente de cadastrada');
select pg_temp.como(:'contador');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc11'), 'O cadastro da forma está esperando aprovação',
  'forma do cadastro: a AF não troca para a versão esperando aprovação');
-- quem lançou não escolhe (sem ser master)
select pg_temp.sis();
insert into erp.listas_financeiro (lista, user_id) values ('AF', :'analista2') on conflict do nothing;
select pg_temp.volta();
select pg_temp.como(:'analista2');
select api.lancar_titulo(:'fbase'::jsonb || jsonb_build_object('numero', 'FC-10', 'compromisso', '61000000-0000-0000-0000-0000000000d2',
  'parcelas', '[{"vencimento": "2027-03-20", "forma": "pix", "pix_tipo": "email", "pix_chave": "outra@example.com"}]'::jsonb)) as fc10 \gset
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc10'), 'Quem lançou não escolhe a forma de pagamento',
  'forma do cadastro: quem lançou, mesmo sendo da AF, não escolhe a forma');
-- a AF vê todo título que aprova; o que ela não vê é o de PJ (natureza restrita, só do master e dos designados)
select pg_temp.sis(); update erp.naturezas set restrita = true where codigo = '05.01.04'; select pg_temp.volta();
select pg_temp.como(:'contador');
select pg_temp.ok(not erp.vejo_titulo(:'fc10'), 'forma do cadastro: (teste) a AF não vê o título de PJ');
select pg_temp.erro_igual(format($$select api.usar_forma_do_cadastro(%L)$$, :'fc10'), 'Título não encontrado',
  'forma do cadastro: a AF que não vê o título (PJ) não troca a forma dele');
select pg_temp.sis(); update erp.naturezas set restrita = false where codigo = '05.01.04'; select pg_temp.volta();
select pg_temp.sis();
select pg_temp.ok((select p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_conferencia' from pg_proc p where p.oid = 'erp.tg_parcela_ted()'::regprocedure)
                  and (select p.prosecdef and pg_get_userbyid(p.proowner) = 'erp_situacao' from pg_proc p where p.oid = 'erp.usar_forma_do_cadastro(uuid)'::regprocedure)
                  and not has_function_privilege('anon', 'erp.usar_forma_do_cadastro(uuid)', 'execute')
                  and not has_function_privilege('authenticated', 'erp._cadastro_aceita(erp.parcela_pagamentos, uuid)', 'execute')
                  and not has_table_privilege('authenticated', 'erp.titulo_forma_cadastro', 'insert'),
  'forma do cadastro: donos das funções definer e nada aberto além da função da tela');
select pg_temp.volta();
select pg_temp.como(null);
rollback;

\echo '# fim'
do $$ begin raise notice 'TODOS OS TESTES PASSARAM'; end $$;
