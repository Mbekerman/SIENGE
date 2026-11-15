-- Primeiro grant a `authenticated` (aval do Moises, 15/11/2026): o esquema `erp` abre ao
-- usuário logado, com RLS por perfil (núcleo econômico × centro de custo × natureza, natureza
-- restrita isolada, como a folha PJ).
--
-- 1. Quem conta como usuário: só quem tem cadastro ativo no ERP (erp.eu() não nulo) e não é
--    só da sucessão (erp.membro()). Login sem cadastro, de outro sistema do mesmo Auth, lê
--    zero linhas e não grava nada (S-045, S-087).
-- 2. As funções de acesso que recebem a pessoa (acesso, ve_linha, lanca_linha,
--    natureza_liberada, atribuicoes_no_nucleo) são definer de erp_conferencia e ficam sem
--    EXECUTE para a API (S-079). As políticas chamam as versões que usam erp.eu(): vejo, lanco,
--    vejo_titulo e as outras daqui.
-- 3. Políticas por classe de tabela, só para `authenticated`:
--    - catálogo e configuração: lê quem é membro; grava só o administrador ou o master, e os
--      gatilhos de cada tabela decidem o resto;
--    - cadastro de pessoas: lê quem é membro; grava quem edita;
--    - linhas com núcleo × centro × natureza (rateios, previsões, livro, orçamento): pelo
--      perfil (erp.ve_linha, erp.lanca_linha);
--    - título, nota e contrato: vê quem vê alguma linha do rateio, desde que nenhuma linha
--      de natureza restrita fique escondida dele; quem aprova o título também vê; grava quem
--      lança em todas as linhas;
--    - filhos (parcelas, alçadas, aprovações, retenções, caução...): pelo pai;
--    - tabelas de acesso: a própria linha, e quem administra ou aprova acesso;
--    - auditoria: o administrador e o master. Avisos da sucessão: só o sistema.
-- 4. EXECUTE: todas as funções invoker (rodam com o RLS de quem chama) e uma lista explícita
--    das definer que são RPC ou conferência sem a pessoa como parâmetro. As internas (_aplicar,
--    os saldos com _, as do servidor da sucessão) ficam fora.
-- 5. Nenhum privilégio para anon, service_role nem authenticator. Nenhum papel da API é
--    membro de papel nosso (teste de catálogo).
-- Portabilidade: SQL puro; `authenticated` é o nome do papel do usuário logado no PostgREST.

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Quem age e o que pode
-- ---------------------------------------------------------------------------------------------
create function erp.membro() returns boolean language sql stable as
  $$ select exists (select 1 from erp.usuarios where id = erp.eu() and not so_sucessao) $$;
create function erp.sou_admin() returns boolean language sql stable as
  $$ select erp.membro() and (coalesce((select administrador from erp.usuarios where id = erp.eu()), false) or erp.sou_master()) $$;
-- grava: membro com papel acima de leitura, ou o administrador (configuração)
create function erp.escrevo() returns boolean language sql stable as
  $$ select erp.membro() and (coalesce((select papel from erp.usuarios where id = erp.eu()), 'leitura') <> 'leitura' or erp.sou_admin()) $$;
-- financeiro: quem está numa lista AF, AO ou AD
create function erp.financeiro() returns boolean language sql stable as
  $$ select erp.membro() and exists (select 1 from erp.listas_financeiro where user_id = erp.eu()) $$;
-- administra ou aprova acesso: vê os pedidos e o acesso dos outros
create function erp.gere_acesso() returns boolean language sql stable as
  $$ select erp.sou_admin() or (erp.membro() and (exists (select 1 from erp.aprovadores_acesso where user_id = erp.eu())
                                                or exists (select 1 from erp.delegados_acesso where user_id = erp.eu()))) $$;

-- Vê a linha pelo perfil. Linha sem núcleo e sem centro (movimento entre sócios) não entra em
-- perfil nenhum: vê a diretoria e o financeiro, e a de natureza restrita só com liberação.
create function erp._ve(p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language sql stable as $$
  select case when p_nucleo is null and p_centro is null
              then (coalesce(erp.meu_papel(), '') = 'diretor' or erp.financeiro())
                   and (p_natureza is null or not erp.natureza_restrita(p_natureza)
                        or erp.natureza_liberada(erp.eu(), null, null, p_natureza))
              else erp.ve_linha(erp.eu(), p_nucleo, p_centro, p_natureza, p_autor, p_divisao) end $$;

-- A linha classificada: vê e lança pelo perfil de quem está logado; o master vê e lança tudo.
create function erp.vejo(p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language sql stable as
  $$ select erp.membro() and (erp.sou_master() or erp._ve(p_nucleo, p_centro, p_natureza, p_autor, p_divisao)) $$;
-- lança: tem o nível de lançar e vê a linha (o lançador restrito só mexe no que ele lançou)
create function erp.lanco(p_nucleo uuid, p_centro uuid, p_natureza uuid, p_autor uuid, p_divisao uuid default null)
returns boolean language sql stable as
  $$ select erp.escrevo() and (erp.sou_master() or (erp.lanca_linha(erp.eu(), p_nucleo, p_centro, p_natureza, p_divisao)
                                                   and erp._ve(p_nucleo, p_centro, p_natureza, p_autor, p_divisao))) $$;

-- Quem aprova o título na rodada atual (lista da fase, diretoria, gestor do centro) ou já decidiu.
create function erp.aprovo_titulo(p_titulo uuid) returns boolean language sql stable as $$
  select erp.membro() and (
    exists (select 1 from erp.titulo_alcadas a join erp.titulos t on t.id = a.titulo_id and t.rodada = a.rodada
             where a.titulo_id = p_titulo
               and (erp.estou_nas_listas(a.fases) or coalesce(erp.meu_papel(), '') = 'diretor'
                    or exists (select 1 from unnest(a.fases) e where erp._ocupa_vaga(e, a.centro_custo_id, erp.eu()))))
    or exists (select 1 from erp.titulo_aprovacoes x where x.titulo_id = p_titulo and x.por = erp.eu())) $$;

-- Título: vê quem vê alguma linha do rateio e nenhuma linha restrita fica escondida dele; sem
-- rateio ainda, só quem lançou; e quem aprova.
-- pela linha (id e autor), para a política da própria tabela: o INSERT ... RETURNING confere a
-- linha nova, que ainda não está na tabela
create function erp._vejo_titulo(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.membro() and (
    erp.sou_master() or erp.aprovo_titulo(p_id)
    or (p_autor = erp.eu() and not exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id))
    or (exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id
                 and erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id))
        and not exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id and erp.natureza_restrita(r.natureza_id)
                         and not erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.vejo_titulo(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._vejo_titulo(t.id, t.criado_por) from erp.titulos t where t.id = p_id), false) $$;
-- grava no título quem lança em todas as linhas (sem rateio ainda, quem lançou)
create function erp._lanco_titulo(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.escrevo() and (
    erp.sou_master()
    -- sem linha nenhuma: quem lançou, ou, no meio do ajuste da revisão, quem pode ajustar
    or (not exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id)
        and (p_autor = erp.eu() or (erp.em_revisao(p_id) and erp.pode_ajustar(p_id))))
    or (exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id)
        and not exists (select 1 from erp.titulo_rateios r where r.titulo_id = p_id
                         and not erp.lanco(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.lanco_titulo(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._lanco_titulo(t.id, t.criado_por) from erp.titulos t where t.id = p_id), false) $$;

create function erp._vejo_documento(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.membro() and (
    erp.sou_master()
    or exists (select 1 from erp.titulos t where t.documento_id = p_id and erp.aprovo_titulo(t.id))
    or (p_autor = erp.eu() and not exists (select 1 from erp.documento_rateios r where r.documento_id = p_id))
    or (exists (select 1 from erp.documento_rateios r where r.documento_id = p_id
                 and erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id))
        and not exists (select 1 from erp.documento_rateios r where r.documento_id = p_id and erp.natureza_restrita(r.natureza_id)
                         and not erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.vejo_documento(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._vejo_documento(d.id, d.criado_por) from erp.documentos_fiscais d where d.id = p_id), false) $$;
create function erp._lanco_documento(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.escrevo() and (
    erp.sou_master()
    or (not exists (select 1 from erp.documento_rateios r where r.documento_id = p_id)
        and (p_autor = erp.eu() or coalesce(erp.pode_ajustar(erp._titulo_em_revisao_da_nota(p_id)), false)))
    or (exists (select 1 from erp.documento_rateios r where r.documento_id = p_id)
        and not exists (select 1 from erp.documento_rateios r where r.documento_id = p_id
                         and not erp.lanco(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.lanco_documento(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._lanco_documento(d.id, d.criado_por) from erp.documentos_fiscais d where d.id = p_id), false) $$;

create function erp._vejo_compromisso(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.membro() and (
    erp.sou_master()
    or (p_autor = erp.eu() and not exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id))
    or (exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id
                 and erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id))
        and not exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id and erp.natureza_restrita(r.natureza_id)
                         and not erp._ve(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.vejo_compromisso(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._vejo_compromisso(c.id, c.criado_por) from erp.compromissos c where c.id = p_id), false) $$;
create function erp._lanco_compromisso(p_id uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.escrevo() and (
    erp.sou_master()
    or (p_autor = erp.eu() and not exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id))
    or (exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id)
        and not exists (select 1 from erp.compromisso_rateios r where r.compromisso_id = p_id
                         and not erp.lanco(r.nucleo_economico_id, r.centro_custo_id, r.natureza_id, p_autor, r.divisao_id)))) $$;
create function erp.lanco_compromisso(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._lanco_compromisso(c.id, c.criado_por) from erp.compromissos c where c.id = p_id), false) $$;

create function erp.vejo_previsao(p_id uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.previsoes p where p.id = p_id
                  and erp.vejo(p.nucleo_economico_id, p.centro_custo_id, p.natureza_id, p.criada_por, p.divisao_id)) $$;

-- Pagamento: o financeiro (AF, AO, AD), quem lançou, ou quem vê o núcleo × centro dele ou um
-- título que ele quita; nunca se ele quita um título que a pessoa não vê (folha PJ).
create function erp._vejo_pagamento(p_id uuid, p_nucleo uuid, p_centro uuid, p_autor uuid, p_divisao uuid default null) returns boolean language sql stable as $$
  select erp.membro() and (
    erp.sou_master() or erp.financeiro() or p_autor = erp.eu()
    or ((   (p_nucleo is not null and erp._ve(p_nucleo, p_centro, null, p_autor, p_divisao))
         or exists (select 1 from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id
                     where q.pagamento_id = p_id and erp.vejo_titulo(pa.titulo_id)))
        and not exists (select 1 from erp.quitacoes q join erp.parcelas pa on pa.id = q.parcela_id
                         where q.pagamento_id = p_id and not erp.vejo_titulo(pa.titulo_id)))) $$;
create function erp.vejo_pagamento(p_id uuid) returns boolean language sql stable as
  $$ select coalesce((select erp._vejo_pagamento(g.id, g.nucleo_economico_id, g.centro_custo_id, g.criado_por, g.divisao_id)
                        from erp.pagamentos g where g.id = p_id), false) $$;
-- grava: o financeiro, ou quem lança no núcleo × centro do carimbo
create function erp._lanco_pagamento(p_nucleo uuid, p_centro uuid, p_autor uuid) returns boolean language sql stable as $$
  select erp.escrevo() and (erp.sou_master() or erp.financeiro()) $$;

create function erp.vejo_reclassificacao(p_id uuid) returns boolean language sql stable as $$
  select erp.membro() and exists (select 1 from erp.reclassificacoes r where r.id = p_id and (
    erp.sou_master() or r.solicitante = erp.eu() or coalesce(erp.meu_papel(), '') = 'diretor'
    or coalesce((select contador from erp.usuarios where id = erp.eu()), false)
    or exists (select 1 from erp.reclassificacao_votos v where v.reclassificacao_id = r.id and v.user_id = erp.eu()))) $$;

-- sucessão do master: o master, o grupo de sucessão e o indicado (o grupo pode ser só da sucessão)
create function erp.vejo_sucessao() returns boolean language sql stable as
  $$ select erp.eu() is not null and (erp.sou_master() or exists (select 1 from erp.grupo_sucessao where user_id = erp.eu())) $$;

-- As funções de acesso que recebem a pessoa: definer, sem EXECUTE para a API (S-079).
-- As novas daqui: definer, com EXECUTE (só olham quem está logado).
do $$
declare f text;
begin
  foreach f in array array[
    'erp.acesso(uuid, uuid, uuid, uuid)', 'erp.ve_linha(uuid, uuid, uuid, uuid, uuid, uuid)', 'erp.lanca_linha(uuid, uuid, uuid, uuid, uuid)',
    'erp.natureza_liberada(uuid, uuid, uuid, uuid, uuid)', 'erp.atribuicoes_no_nucleo(uuid, uuid)',
    'erp.natureza_restrita(uuid)', 'erp.galhos_acima(uuid)',
    -- trava que lê o uso da natureza em todo o livro: por baixo do RLS, senão quem não vê os
    -- lançamentos acharia a natureza sem uso
    'erp.natureza_em_uso(uuid)',
    -- a classificação lê a empresa do registro pai: por baixo do RLS, senão quem não vê o pai
    -- recebe "núcleo de outra empresa" no lugar da recusa da política
    'erp.tg_classificacao()',
    'erp._ve(uuid, uuid, uuid, uuid, uuid)', 'erp.membro()', 'erp.sou_admin()', 'erp.escrevo()', 'erp.financeiro()', 'erp.gere_acesso()',
    'erp.vejo(uuid, uuid, uuid, uuid, uuid)', 'erp.lanco(uuid, uuid, uuid, uuid, uuid)', 'erp.aprovo_titulo(uuid)',
    'erp.vejo_titulo(uuid)', 'erp.lanco_titulo(uuid)', 'erp.vejo_documento(uuid)', 'erp.lanco_documento(uuid)',
    'erp.vejo_compromisso(uuid)', 'erp.lanco_compromisso(uuid)', 'erp.vejo_previsao(uuid)', 'erp.vejo_pagamento(uuid)',
    'erp._vejo_titulo(uuid, uuid)', 'erp._lanco_titulo(uuid, uuid)', 'erp._vejo_documento(uuid, uuid)', 'erp._lanco_documento(uuid, uuid)',
    'erp._vejo_compromisso(uuid, uuid)', 'erp._lanco_compromisso(uuid, uuid)',
    'erp._vejo_pagamento(uuid, uuid, uuid, uuid, uuid)', 'erp._lanco_pagamento(uuid, uuid, uuid)', 'erp.vejo_reclassificacao(uuid)', 'erp.vejo_sucessao()',
    'erp.previsao_saldo(uuid)', 'erp.parcela_saldo(uuid)', 'erp.pagamento_saldo(uuid)'] loop
    execute format('alter function %s security definer set search_path = erp, pg_catalog, pg_temp', f);
    execute format('alter function %s owner to erp_conferencia', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Cadastro de pessoas (S-089): com auditoria; a empresa do grupo só o master muda; de pessoa já
-- usada (título, nota, contrato, previsão, pagamento), documento, nome, tipo, a marca de ativa e o
-- papel de fornecedor só o financeiro ou o master. Definer: confere o uso por baixo do RLS.
-- ---------------------------------------------------------------------------------------------
create function erp.tg_pessoa_protegida() returns trigger language plpgsql
security definer set search_path = erp, pg_catalog, pg_temp as $$
declare v_id uuid; v_grupo boolean; v_usada boolean; v_muda boolean;
begin
  -- o papel não muda de pessoa nem de nome: tira um e põe outro (cada um passa pela trava)
  if tg_table_name = 'pessoa_papeis' and tg_op = 'UPDATE' and not erp.sistema() then
    raise exception 'O papel da pessoa não se altera; tire e inclua';
  end if;
  if erp.sistema() or erp.sou_master() then return coalesce(new, old); end if;
  if tg_table_name = 'pessoas' then v_id := old.id; else v_id := coalesce(new.pessoa_id, old.pessoa_id); end if;
  v_grupo := exists (select 1 from erp.empresas where pessoa_id = v_id);
  v_usada := exists (select 1 from erp.titulos where pessoa_id = v_id)
          or exists (select 1 from erp.documentos_fiscais where emitente_id = v_id)
          or exists (select 1 from erp.compromissos where pessoa_id = v_id)
          or exists (select 1 from erp.previsoes where pessoa_id = v_id)
          or exists (select 1 from erp.pagamentos where pessoa_id = v_id);
  if tg_table_name = 'pessoas' then
    v_muda := tg_op = 'DELETE' or new.documento is distinct from old.documento or new.nome is distinct from old.nome
              or new.tipo is distinct from old.tipo or new.ativa is distinct from old.ativa;
    if v_grupo and (v_muda or new is distinct from old) then
      raise exception 'O cadastro de empresa do grupo só o master muda';
    end if;
    if v_usada and v_muda and not erp.financeiro() then
      raise exception 'Documento, nome, tipo e situação de pessoa já usada só o financeiro muda';
    end if;
  else  -- pessoa_papeis
    if v_grupo then raise exception 'O cadastro de empresa do grupo só o master muda'; end if;
    if tg_op <> 'INSERT' and v_usada and old.papel = 'fornecedor' and not erp.financeiro() then
      raise exception 'Só o financeiro tira o papel de fornecedor de pessoa já usada';
    end if;
  end if;
  return coalesce(new, old);
end $$;
alter function erp.tg_pessoa_protegida() owner to erp_conferencia;
create trigger t_protegida before update or delete on erp.pessoas
  for each row execute function erp.tg_pessoa_protegida();
create trigger t_protegida before insert or update or delete on erp.pessoa_papeis
  for each row execute function erp.tg_pessoa_protegida();
create trigger t_aud_pessoas after insert or update or delete on erp.pessoas
  for each row execute function erp.tg_auditoria('id');
create trigger t_aud_pessoa_papeis after insert or update or delete on erp.pessoa_papeis
  for each row execute function erp.tg_auditoria('pessoa_id');

-- ---------------------------------------------------------------------------------------------
-- Políticas para `authenticated`
-- ---------------------------------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select * from (values
    -- catálogo e configuração: lê o membro, grava o administrador (os gatilhos decidem o resto)
    ('empresas', 'erp.membro()', 'erp.sou_admin()'),
    ('participacoes', 'erp.membro()', 'erp.sou_admin()'),
    ('empreendimentos', 'erp.membro()', 'erp.sou_admin()'),
    ('empreendimento_atributos', 'erp.membro()', 'erp.sou_admin()'),
    ('atributos', 'erp.membro()', 'erp.sou_admin()'),
    ('atributo_opcoes', 'erp.membro()', 'erp.sou_admin()'),
    ('naturezas', 'erp.membro()', 'erp.sou_admin()'),
    -- configuração que mexe em dinheiro e aprovação (S-090; Moises, 15/11/2026: "só o master por
    -- ora", até essas mudanças do administrador passarem por aprovação): grava só o master
    ('naturezas_sistema', 'erp.membro()', 'erp.sou_master()'),
    ('centros_custo', 'erp.membro()', 'erp.sou_admin()'),
    ('divisoes', 'erp.membro()', null),                       -- só pelo pedido aprovado (S-101)
    ('nucleos_economicos', 'erp.membro()', 'erp.sou_admin()'),
    ('nucleo_centros', 'erp.membro()', 'erp.sou_admin()'),
    -- naturezas liberadas por divisão: o master, o administrador e AF, AO, AD, na hora (Moises, 15/11/2026)
    ('naturezas_liberadas', 'erp.membro()', 'erp.sou_admin() or erp.financeiro()'),
    ('modelos_naturezas', 'erp.membro()', 'erp.sou_admin() or erp.financeiro()'),
    ('modelo_naturezas', 'erp.membro()', 'erp.sou_admin() or erp.financeiro()'),
    ('linhas_dre', 'erp.membro()', 'erp.sou_admin()'),
    ('niveis_aprovacao', 'erp.membro()', 'erp.sou_master()'),
    ('alcadas_pagamento', 'erp.membro()', 'erp.sou_master()'),
    ('alcadas_reclassificacao', 'erp.membro()', 'erp.sou_master()'),
    ('regra_adiantamento', 'erp.membro()', 'erp.sou_master()'),
    ('regra_alcada_pagamento', 'erp.membro()', 'erp.sou_master()'),
    ('regras_ajuste', 'erp.membro()', 'erp.sou_master()'),
    ('contas_bancarias', 'erp.membro()', 'erp.sou_master()'),
    ('codigos_externos', 'erp.membro()', 'erp.sou_master()'),
    ('meses_fechados', 'erp.membro()', null),
    ('tipos_nucleo', 'erp.membro()', null),
    -- quem é quem: todo membro vê os colegas; o só da sucessão vê a si mesmo
    ('usuarios', 'erp.membro() or id = erp.eu()', 'erp.sou_admin()'),
    ('master', 'erp.eu() is not null', null),
    ('listas_financeiro', 'erp.membro()', null),
    ('centro_aprovadores', 'erp.membro()', null),
    ('centro_diretores', 'erp.membro()', null),
    ('perfis_modelo', 'erp.membro()', null),
    ('perfil_centros', 'erp.membro()', null),
    ('perfil_centro_divisoes', 'erp.membro()', null),
    ('perfil_naturezas', 'erp.membro()', null),
    ('aprovadores_acesso', 'erp.membro()', null),
    ('regra_acesso', 'erp.membro()', null),
    ('regras_mudanca_acesso', 'erp.membro()', 'erp.sou_admin()'),
    ('regras_nivel_acesso', 'erp.membro()', 'erp.sou_admin()'),
    ('delegados_acesso', 'erp.membro()', 'erp.sou_admin()'),
    -- acesso de cada pessoa: a própria linha e quem administra ou aprova acesso
    ('atribuicoes', 'user_id = erp.eu() or erp.gere_acesso()', null),
    ('atribuicao_tipos', 'exists (select 1 from erp.atribuicoes a where a.id = atribuicao_id)', null),
    ('atribuicao_nucleos', 'exists (select 1 from erp.atribuicoes a where a.id = atribuicao_id)', null),
    ('excecoes_centro', 'user_id = erp.eu() or erp.gere_acesso()', null),
    ('excecoes_divisao', 'user_id = erp.eu() or erp.gere_acesso()', null),
    ('excecoes_natureza', 'user_id = erp.eu() or erp.gere_acesso()', null),
    ('mudancas_acesso', 'erp.gere_acesso() or (erp.membro() and (pedida_por = erp.eu() or erp.eu() = any(beneficiarios)))', null),
    ('mudanca_acesso_votos', 'exists (select 1 from erp.mudancas_acesso m where m.id = mudanca_id)', null),
    ('grupo_sucessao', 'erp.vejo_sucessao()', 'erp.sou_master()'),
    ('sucessoes_master', 'erp.vejo_sucessao() or novo_id = erp.eu()', null),
    ('sucessao_votos', 'exists (select 1 from erp.sucessoes_master s where s.id = sucessao_id)', null),
    ('auditoria', 'erp.sou_admin()', null),
    -- pessoas (fornecedores, clientes, sócios): lê o membro, cadastra quem edita
    ('pessoas', 'erp.membro()', 'erp.escrevo()'),
    ('pessoa_papeis', 'erp.membro()', 'erp.escrevo()'),
    -- linhas classificadas
    ('lancamentos', 'erp.vejo(nucleo_economico_id, centro_custo_id, natureza_id, null, divisao_id)', null),
    ('previsoes', 'erp.vejo(nucleo_economico_id, centro_custo_id, natureza_id, criada_por, divisao_id)',
                  'erp.lanco(nucleo_economico_id, centro_custo_id, natureza_id, criada_por, divisao_id)'),
    ('orcamento_versoes', 'erp.membro()', 'erp.escrevo()'),
    ('orcamento_linhas', 'erp.vejo(nucleo_economico_id, centro_custo_id, natureza_id, null, divisao_id)',
                         'erp.lanco(nucleo_economico_id, centro_custo_id, natureza_id, null, divisao_id)'),
    -- título e filhos
    ('titulos', 'erp._vejo_titulo(id, criado_por)', 'erp._lanco_titulo(id, criado_por)'),
    ('titulo_rateios', 'erp.vejo_titulo(titulo_id)',
                       'erp.lanco_titulo(titulo_id) and erp.lanco(nucleo_economico_id, centro_custo_id, natureza_id, (select t.criado_por from erp.titulos t where t.id = titulo_id), divisao_id)'),
    ('parcelas', 'erp.vejo_titulo(titulo_id)', 'erp.lanco_titulo(titulo_id)'),
    ('titulo_alcadas', 'erp.vejo_titulo(titulo_id)', null),
    ('titulo_aprovacoes', 'erp.vejo_titulo(titulo_id)', null),
    ('titulo_coberturas', 'erp.vejo_titulo(titulo_id)', null),
    ('titulo_revisoes', 'erp.vejo_titulo(titulo_id)', null),
    ('titulo_ajustes', 'erp.vejo_titulo(titulo_id)', null),
    ('titulo_previsoes', 'erp.vejo_titulo(titulo_id)', null),
    ('liberacoes_sem_abater', 'erp.vejo_titulo(titulo_id)', 'erp.escrevo() and erp.vejo_titulo(titulo_id)'),
    ('abatimentos_cruzados', 'erp.vejo_titulo(titulo_id)', 'erp.escrevo() and erp.vejo_titulo(titulo_id) and erp.vejo_pagamento(pagamento_id)'),
    ('excecoes_competencia', 'erp.vejo_titulo(titulo_id) or erp.vejo_documento(documento_id)',
                             'erp.escrevo() and (erp.vejo_titulo(titulo_id) or erp.vejo_documento(documento_id))'),
    ('movimentos_societarios', 'erp.vejo_titulo(titulo_pagar_id) or erp.vejo_titulo(titulo_receber_id)', null),
    -- nota e filhos
    ('documentos_fiscais', 'erp._vejo_documento(id, criado_por)', 'erp._lanco_documento(id, criado_por)'),
    ('documento_rateios', 'erp.vejo_documento(documento_id)',
                          'erp.lanco_documento(documento_id) and erp.lanco(nucleo_economico_id, centro_custo_id, natureza_id, (select d.criado_por from erp.documentos_fiscais d where d.id = documento_id), divisao_id)'),
    ('documento_retencoes', 'erp.vejo_documento(documento_id)', 'erp.lanco_documento(documento_id)'),
    -- contrato e filhos
    ('compromissos', 'erp._vejo_compromisso(id, criado_por)', 'erp._lanco_compromisso(id, criado_por)'),
    ('compromisso_rateios', 'erp.vejo_compromisso(compromisso_id)',
                            'erp.lanco_compromisso(compromisso_id) and erp.lanco(nucleo_economico_id, centro_custo_id, natureza_id, (select c.criado_por from erp.compromissos c where c.id = compromisso_id), divisao_id)'),
    ('caucao_movimentos', 'erp.vejo_compromisso(compromisso_id)', null),
    -- pagamento
    ('pagamentos', 'erp._vejo_pagamento(id, nucleo_economico_id, centro_custo_id, criado_por, divisao_id)',
                    'erp._lanco_pagamento(nucleo_economico_id, centro_custo_id, criado_por)'),
    ('quitacoes', 'erp.vejo_titulo((select pa.titulo_id from erp.parcelas pa where pa.id = parcela_id))',
                  'erp.escrevo() and (erp.sou_master() or erp.financeiro()) and erp.vejo_pagamento(pagamento_id) and erp.vejo_titulo((select pa.titulo_id from erp.parcelas pa where pa.id = parcela_id))'),
    ('lotes_bancarios', 'erp.sou_master() or erp.financeiro()', null),
    -- reclassificação: só pelas funções dela; lê quem pediu, quem aprova e quem votou
    ('reclassificacoes', 'erp.vejo_reclassificacao(id)', null),
    ('reclassificacao_itens', 'erp.vejo_reclassificacao(reclassificacao_id)', null),
    ('reclassificacao_votos', 'erp.vejo_reclassificacao(reclassificacao_id)', null),
    -- avisos da sucessão: só o sistema (o link do veto passa pelo servidor)
    ('avisos_sucessao', null, null)
  ) v(tabela, le, grava) loop
    if t.le is not null then
      execute format('create policy perfil_le on erp.%I for select to authenticated using (%s)', t.tabela, t.le);
      execute format('grant select on erp.%I to authenticated', t.tabela);
    end if;
    if t.grava is not null then
      -- no INSERT a linha nova já passou pelos gatilhos BEFORE (o autor já está posto)
      execute format('create policy perfil_inclui on erp.%I for insert to authenticated with check (%s)', t.tabela, t.grava);
      execute format('create policy perfil_altera on erp.%I for update to authenticated using (%s) with check (%s)', t.tabela, t.grava, t.grava);
      execute format('create policy perfil_apaga on erp.%I for delete to authenticated using (%s)', t.tabela, t.grava);
      execute format('grant insert, update, delete on erp.%I to authenticated', t.tabela);
    end if;
  end loop;
end $$;

-- Toda tabela do esquema tem a sua linha acima (teste de catálogo confere): nenhuma fica aberta
-- por esquecimento, nem fechada sem querer.
grant usage on schema erp to authenticated;
grant select on erp.v_naturezas, erp.v_parcelas, erp.v_titulo_alcadas, erp.v_adiantamentos, erp.v_caucao, erp.v_previsoes,
                erp.v_fluxo_caixa, erp.v_lancamentos_bi to authenticated;

-- ---------------------------------------------------------------------------------------------
-- EXECUTE para `authenticated`
-- ---------------------------------------------------------------------------------------------
-- O Postgres dá EXECUTE a PUBLIC em toda função nova (o privilégio padrão por esquema não tira
-- isso); as criadas aqui também perdem, e só ganha quem está abaixo.
revoke execute on all functions in schema erp from public;
grant execute on all functions in schema erp to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
-- As invoker rodam com o RLS e os privilégios de quem chama: não abrem nada além do que a
-- pessoa já pode. As de gatilho não se chamam direto, e as internas (com _) só rodam por
-- dentro das operações.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'erp' and not p.prosecdef and p.prorettype <> 'trigger'::regtype
              and p.proname not like '\_%' loop
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- As definer com EXECUTE: RPCs que conferem quem chama, e conferências que só olham quem está
-- logado (ou recebem só ids e não devolvem dado). Fica fora: o que recebe a pessoa
-- (acesso, ve_linha...), os saldos internos (_previsao_saldo...), o que aplica sem conferir
-- (_aplicar_mudanca_acesso, _sucessao_unanime) e o que é do servidor
-- (gerar_avisos_sucessao, registrar_envio_aviso, vetar_sucessao_por_link).
grant execute on function
  -- quem age
  erp.eu(), erp.autor(), erp.meu_usuario(), erp.meu_papel(), erp.sou_master(), erp.membro(), erp.sou_admin(),
  erp.escrevo(), erp.financeiro(), erp.gere_acesso(),
  erp.exigir_editor(), erp.exigir_diretor(), erp.estou_nas_listas(text[]),
  erp.natureza_restrita(uuid), erp.galhos_acima(uuid), erp.natureza_em_uso(uuid),
  -- visibilidade de quem está logado
  erp.vejo(uuid, uuid, uuid, uuid, uuid), erp.lanco(uuid, uuid, uuid, uuid, uuid), erp.aprovo_titulo(uuid),
  erp.vejo_titulo(uuid), erp.lanco_titulo(uuid), erp.vejo_documento(uuid), erp.lanco_documento(uuid),
  erp.vejo_compromisso(uuid), erp.lanco_compromisso(uuid), erp.vejo_previsao(uuid),
  erp.vejo_pagamento(uuid), erp._vejo_titulo(uuid, uuid), erp._lanco_titulo(uuid, uuid), erp._vejo_documento(uuid, uuid),
  erp._lanco_documento(uuid, uuid), erp._vejo_compromisso(uuid, uuid), erp._lanco_compromisso(uuid, uuid),
  erp._vejo_pagamento(uuid, uuid, uuid, uuid, uuid), erp._lanco_pagamento(uuid, uuid, uuid), erp.vejo_reclassificacao(uuid), erp.vejo_sucessao(),
  -- saldos só do que a pessoa vê
  erp.previsao_saldo(uuid), erp.parcela_saldo(uuid), erp.pagamento_saldo(uuid),
  -- conferências das travas (chamadas pelos gatilhos invoker)
  erp.regra_adiantamento_atual(), erp.autor_lancamento(text, uuid), erp.abatimento_aprovado(uuid, uuid), erp.gestor_abate_divisao(uuid, uuid),
  erp.adiantamento_anterior_em_aberto(uuid, uuid), erp.centro_ligado(uuid, uuid), erp.natureza_presa(uuid, uuid, uuid),
  erp.checar_natureza(uuid, uuid, uuid, boolean), erp.checar_centro(uuid, uuid, uuid),
  erp.em_revisao(uuid), erp.pode_ajustar(uuid), erp._ajustavel(uuid), erp._nota_ajustavel(uuid),
  erp._titulo_em_revisao_da_nota(uuid), erp.cadeia_titulo(uuid), erp.conferir_ajuste(uuid, text, jsonb, jsonb),
  erp.alcada_fase(uuid), erp.alcada_pendente(uuid), erp.alcada_recusada(uuid), erp.titulos_do_acumulado(uuid),
  erp.checar_competencia(text, uuid, date, date),
  -- chamada pelos gatilhos do ajuste; recusa chamada direta (fora de gatilho) e quem não ajusta
  erp._registrar_ajuste(uuid, text, jsonb, jsonb),
  erp.recusar_so_sucessao(uuid), erp.recusar_admin_aprovador(uuid), erp._beneficiarios_acesso(text, jsonb, jsonb),
  -- operações
  erp.confirmar_titulo(uuid), erp.lancar_documento(uuid, date[], uuid[]),
  erp.liberar_caucao(uuid, numeric, date, uuid, text), erp.publicar_orcamento(uuid),
  erp.decidir_titulo(uuid, boolean, text, boolean, uuid, uuid), erp.reenviar_titulo(uuid, text, date[], uuid[]),
  erp.registrar_movimento_societario(text, uuid, uuid, numeric, date, text),
  erp.fechar_mes(uuid, date), erp.reabrir_mes(uuid, date),
  erp.pedir_reclassificacao(uuid, uuid, text, jsonb, boolean), erp.decidir_reclassificacao(uuid, boolean, text),
  erp.cancelar_reclassificacao(uuid),
  erp.pedir_mudanca_acesso(text, text, jsonb, text), erp.decidir_mudanca_acesso(uuid, boolean, text),
  erp.cancelar_mudanca_acesso(uuid), erp.passar_master(uuid, text), erp.pedir_sucessao_master(uuid, text),
  erp.decidir_sucessao_master(uuid, boolean, text), erp.vetar_sucessao_master(uuid), erp.efetivar_sucessao_master(uuid)
to authenticated;
