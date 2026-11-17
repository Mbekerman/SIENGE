-- Envio do título aprovado ao Sienge (Moises, 17/11/2026: "Faça a adaptação da escrita").
--
-- O ERP aprova; o Sienge paga. Esta migration guarda o que falta para o título aprovado nascer no
-- Sienge completo, já com a forma de pagamento de cada parcela, e a fila do programa que envia
-- (servicos/sienge-escrita/). Toda gravação no Sienge passa pela trava (trava.ts, PR #70).
--
-- 1. Forma de pagamento da parcela (erp.parcela_pagamentos): PIX (tipo e chave) ou boleto (linha
--    digitável de 47 dígitos, com os dígitos conferidos). Quem lança o título informa. Muda só
--    enquanto o título está em rascunho, em revisão, ou aberto sem nenhum voto na rodada e ainda fora
--    da fila do Sienge: quem aprova sempre aprova a chave e o boleto que vão ao banco, e ninguém troca
--    a chave depois do primeiro voto (proteção contra fraude). O PIX do cadastro do credor não é usado
--    (regra de 8/11/2026: o adaptador manda isUsingCreditorData N).
-- 2. De-para para o Sienge (decisão do Moises de 15/11/2026, ver erp-de-para-naturezas):
--    - erp.sienge_centros: núcleo + centro de custo → centro de custo do Sienge (a obra);
--    - erp.sienge_contas: natureza + centro de custo → conta do plano financeiro do Sienge (o Sienge
--      repete contas por área, por isso a chave leva o centro).
--    Os dois entram na configuração de dinheiro: só mudam por pedido aprovado (erp.pedir_mudanca_config)
--    ou pelo master, e toda mudança vira o evento crítico "codigo_externo_alterado". O código da empresa
--    (debtorId) e do credor (creditorId) já estão em erp.codigos_externos ('sienge', 'empresas' e
--    'pessoas').
-- 3. Fila (erp.sienge_envios): um título por linha, só o sistema grava, quem vê o título lê a situação.
--    erp.sienge_enfileirar() põe na fila os títulos aprovados; erp.sienge_pedido() monta o corpo do
--    POST /bills e as parcelas a partir do banco, ou recusa com o motivo; erp.sienge_registrar() guarda
--    o id do título no Sienge (também em erp.codigos_externos, 'titulos').
--
-- Limites desta primeira versão (recusa com o motivo, nada sai pela metade):
--    - só contas a pagar de fornecedor ou avulso, com documento (nota, boleto, fatura, guia ou recibo);
--    - nota com retenção de imposto ou caução fica de fora: no ERP o título do fornecedor é o líquido,
--      e no Sienge o título leva o bruto com os impostos (falta o código da filial para o teste de
--      tax-information);
--    - boleto de concessionária (48 dígitos) e TED ficam de fora;
--    - no Sienge, título lançado pela API não aceita mudar valor de parcela (teste de 6/11/2026): as
--      parcelas do Sienge são conferidas com as nossas depois da criação, e diferença para o envio
--      em "manual".
-- Portabilidade: SQL puro.

-- ---------------------------------------------------------------------------------------------
-- Conferência dos códigos
-- ---------------------------------------------------------------------------------------------
-- Linha digitável do boleto bancário (47 dígitos): DV de cada um dos três campos (módulo 10) e DV
-- geral do código de barras (módulo 11).
create function erp.linha_digitavel_valida(p text) returns boolean language plpgsql immutable as $$
declare v_campos text[]; c text; i int; s int; d int; m int; v_dv int; v_barras text;
begin
  if p is null or p !~ '^[0-9]{47}$' then return false; end if;
  v_campos := array[substr(p, 1, 10), substr(p, 11, 11), substr(p, 22, 11)];
  foreach c in array v_campos loop
    s := 0; m := 2;
    for i in reverse length(c) - 1 .. 1 loop
      d := substr(c, i, 1)::int * m;
      s := s + d / 10 + d % 10;
      m := case m when 2 then 1 else 2 end;
    end loop;
    if (10 - s % 10) % 10 <> substr(c, length(c), 1)::int then return false; end if;
  end loop;
  -- código de barras: banco e moeda, DV geral, fator e valor, campo livre
  v_barras := substr(p, 1, 4) || substr(p, 33, 15) || substr(p, 5, 5) || substr(p, 11, 10) || substr(p, 22, 10);
  s := 0; m := 2;
  for i in reverse 44 .. 1 loop
    continue when i = 5;
    s := s + substr(v_barras, i, 1)::int * m;
    m := case m when 9 then 2 else m + 1 end;
  end loop;
  v_dv := 11 - s % 11;
  if v_dv in (0, 10, 11) then v_dv := 1; end if;
  return v_dv = substr(v_barras, 5, 1)::int;
end $$;

-- Chave PIX pelo tipo: CPF ou CNPJ (só dígitos), e-mail (minúsculo), telefone (+55 e DDD) ou aleatória.
create function erp.chave_pix_valida(p_tipo text, p_chave text) returns boolean language sql immutable as $$
  select case p_tipo
    when 'cpf_cnpj' then p_chave ~ '^([0-9]{11}|[0-9]{14})$'
    when 'email' then p_chave ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' and length(p_chave) <= 77
    when 'telefone' then p_chave ~ '^\+55[1-9][0-9][0-9]{8,9}$'
    when 'aleatoria' then p_chave ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    else false end $$;

-- ---------------------------------------------------------------------------------------------
-- Forma de pagamento de cada parcela
-- ---------------------------------------------------------------------------------------------
create table erp.parcela_pagamentos (
  titulo_id    uuid not null,
  numero       int not null,
  forma        text not null check (forma in ('pix','boleto')),
  pix_tipo     text check (pix_tipo in ('cpf_cnpj','email','telefone','aleatoria')),
  pix_chave    text,
  boleto_linha text,                     -- linha digitável, só dígitos
  primary key (titulo_id, numero),
  foreign key (titulo_id, numero) references erp.parcelas (titulo_id, numero) on delete cascade,
  check ((forma = 'pix') = (pix_tipo is not null and pix_chave is not null)),
  check ((forma = 'boleto') = (boleto_linha is not null)),
  check (pix_chave is null or erp.chave_pix_valida(pix_tipo, pix_chave)),
  check (boleto_linha is null or erp.linha_digitavel_valida(boleto_linha))
);

-- A fila (criada antes da trava da forma de pagamento, que olha para ela)
create table erp.sienge_envios (
  titulo_id     uuid primary key references erp.titulos,
  situacao      text not null default 'pendente' check (situacao in ('pendente','enviado','erro','manual')),
  sienge_id     int,                    -- o título no Sienge, assim que o POST responde
  passo         text,                   -- o último passo feito: criado, parcelas, pagamento
  tentativas    int not null default 0,
  proxima_em    timestamptz not null default now(),
  erro          text,
  criado_em     timestamptz not null default clock_timestamp(),
  atualizado_em timestamptz not null default clock_timestamp(),
  check (situacao <> 'enviado' or sienge_id is not null)
);
create index on erp.sienge_envios (proxima_em) where situacao in ('pendente','erro');

-- Quem aprova aprova a chave e o boleto: depois do primeiro voto da rodada, ou com o título na fila
-- do Sienge, a forma de pagamento não muda (na revisão, sim: o reenvio abre outra rodada).
create function erp.tg_parcela_pagamento() returns trigger language plpgsql as $$
declare t erp.titulos; v_id uuid := case when tg_op = 'DELETE' then old.titulo_id else new.titulo_id end;
begin
  if tg_op = 'UPDATE' and new.titulo_id <> old.titulo_id then
    raise exception 'A forma de pagamento não muda de título';
  end if;
  select * into t from erp.titulos where id = v_id;
  if t.situacao = 'rascunho' or erp.em_revisao(t.id) then return coalesce(new, old); end if;
  if t.situacao = 'aberto'
     and not exists (select 1 from erp.titulo_aprovacoes v where v.titulo_id = t.id and v.rodada = t.rodada)
     and not exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id) then
    return coalesce(new, old);
  end if;
  -- a parcela apagada na revisão leva junto a forma de pagamento (on delete cascade)
  if tg_op = 'DELETE' and not exists (select 1 from erp.parcelas p where p.titulo_id = old.titulo_id and p.numero = old.numero) then
    return old;
  end if;
  raise exception 'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)';
end $$;
create trigger t_parcela_pagamento before insert or update or delete on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_pagamento();
create trigger t_aud_parcela_pagamentos after insert or update or delete on erp.parcela_pagamentos
  for each row execute function erp.tg_auditoria('titulo_id');

-- ---------------------------------------------------------------------------------------------
-- De-para para o Sienge
-- ---------------------------------------------------------------------------------------------
create table erp.sienge_centros (
  nucleo_economico_id uuid not null references erp.nucleos_economicos,
  centro_custo_id     uuid not null references erp.centros_custo,
  sienge_centro       int not null check (sienge_centro > 0),
  primary key (nucleo_economico_id, centro_custo_id)
);
create table erp.sienge_contas (
  natureza_id     uuid not null references erp.naturezas,
  centro_custo_id uuid not null references erp.centros_custo,
  sienge_conta    text not null check (sienge_conta ~ '^[0-9]{1,12}$'),
  primary key (natureza_id, centro_custo_id)
);
-- Só o master grava direto; o resto, pelo pedido de mudança da configuração (S-090).
create function erp.tg_sienge_depara() returns trigger language plpgsql as $$
begin
  if erp.sistema() or erp.sou_master() or erp.agindo_como('erp_config') then return coalesce(new, old); end if;
  raise exception 'O de-para do Sienge muda pelo pedido (erp.pedir_mudanca_config)';
end $$;
create trigger t_sienge_depara before insert or update or delete on erp.sienge_centros
  for each row execute function erp.tg_sienge_depara();
create trigger t_sienge_depara before insert or update or delete on erp.sienge_contas
  for each row execute function erp.tg_sienge_depara();
create trigger t_aud_sienge_centros after insert or update or delete on erp.sienge_centros
  for each row execute function erp.tg_auditoria('centro_custo_id');
create trigger t_aud_sienge_contas after insert or update or delete on erp.sienge_contas
  for each row execute function erp.tg_auditoria('centro_custo_id');

-- Entram no pedido de mudança da configuração de dinheiro
create or replace function erp._chave_config(p_tabela text) returns text[] language sql immutable as $$
  select case p_tabela
    when 'naturezas_sistema' then '{chave}'::text[]
    when 'niveis_aprovacao' then '{codigo}'
    when 'alcadas_pagamento' then '{id}'
    when 'alcadas_reclassificacao' then '{id}'
    when 'regra_adiantamento' then '{id}'
    when 'regra_alcada_pagamento' then '{id}'
    when 'regras_ajuste' then '{campo,quem}'
    when 'contas_bancarias' then '{id}'
    when 'codigos_externos' then '{sistema,tabela,codigo}'
    when 'aprovadores_config' then '{tabela,user_id}'
    when 'regras_mudanca_config' then '{tabela}'
    when 'regras_notificacao' then '{id}'
    when 'tipos_evento' then '{codigo}'
    when 'sienge_centros' then '{nucleo_economico_id,centro_custo_id}'
    when 'sienge_contas' then '{natureza_id,centro_custo_id}'
  end $$;
insert into erp.regras_mudanca_config (tabela, rotulo) values
  ('sienge_centros', 'Centros de custo do Sienge'), ('sienge_contas', 'Contas do plano financeiro do Sienge');

-- O evento da mudança: de-para do Sienge é código de outro sistema (crítico, vai ao AF)
create or replace function erp.tg_evento_config() returns trigger language plpgsql as $$
declare v_tipo text; v_old jsonb; v_new jsonb;
begin
  if tg_table_name = 'codigos_externos' and erp.sistema() then return null; end if;   -- o adaptador do Sienge
  v_tipo := case
    when tg_table_name = 'contas_bancarias' then 'conta_bancaria_alterada'
    when tg_table_name in ('codigos_externos','sienge_centros','sienge_contas') then 'codigo_externo_alterado'
    when tg_table_name = 'naturezas_sistema' then 'natureza_sistema_alterada'
    when tg_table_name in ('aprovadores_config','regras_mudanca_config') then 'regra_config_alterada'
    else 'alcada_alterada' end;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  perform erp.registrar_evento(v_tipo, tg_table_name,
    (select string_agg(coalesce(v_new, v_old)->>k, '|') from unnest(erp._chave_config(tg_table_name)) k),
    -- a faixa da alçada leva o centro dela (o novo; no delete, o antigo), para o aviso ir a quem
    -- cuida do centro (S-100); o de-para do Sienge leva o centro da linha; as outras ficam sem centro
    null, case when tg_table_name in ('alcadas_pagamento','sienge_centros','sienge_contas')
               then (coalesce(v_new, v_old)->>'centro_custo_id')::uuid end,
    jsonb_build_object('acao', lower(tg_op), 'antes', v_old, 'depois', v_new)
      || coalesce(erp._contexto_mudanca_config(tg_table_name), '{}'));
  return null;
end $$;
alter function erp.tg_evento_config() security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.tg_evento_config() owner to erp_eventos;
create trigger t_evento after insert or update or delete on erp.sienge_centros
  for each row execute function erp.tg_evento_config();
create trigger t_evento after insert or update or delete on erp.sienge_contas
  for each row execute function erp.tg_evento_config();

-- ---------------------------------------------------------------------------------------------
-- Centavo que sobra na divisão das parcelas vai para a PRIMEIRA, como o Sienge faz (POST /bills de
-- R$ 1,00 em 3 parcelas criou 0,34 + 0,33 + 0,33; título 8559, 17/11/2026). O POST não recebe o valor
-- de cada parcela e o Sienge não aceita mudar o valor depois, então a divisão do ERP tem de ser a dele.
-- ---------------------------------------------------------------------------------------------
create or replace function erp._criar_titulo(p_empresa uuid, p_sentido text, p_tipo text, p_pessoa uuid, p_documento uuid,
  p_compromisso uuid, p_emissao date, p_competencia date, p_valor numeric, p_vencimentos date[],
  p_rateio_origem text, p_rateio_id uuid, p_descricao text) returns uuid language plpgsql as $$
declare v_id uuid; n int := array_length(p_vencimentos, 1); i int; v_parc numeric;
begin
  insert into erp.titulos (empresa_id, sentido, tipo, pessoa_id, documento_id, compromisso_id, emissao, competencia, valor, descricao)
  values (p_empresa, p_sentido, p_tipo, p_pessoa, p_documento, p_compromisso, p_emissao, p_competencia, p_valor, p_descricao)
  returning id into v_id;
  for i in 1..n loop
    v_parc := case when i = 1 then p_valor - trunc(p_valor / n, 2) * (n - 1) else trunc(p_valor / n, 2) end;
    insert into erp.parcelas (titulo_id, numero, vencimento, valor) values (v_id, i, p_vencimentos[i], v_parc);
  end loop;
  if p_rateio_origem is not null then
    insert into erp.titulo_rateios (titulo_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id, percentual)
    select v_id, nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id, percentual from (
      select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id, percentual from erp.compromisso_rateios
        where p_rateio_origem = 'compromisso' and compromisso_id = p_rateio_id
      union all
      select nucleo_economico_id, natureza_id, centro_custo_id, divisao_id, subdivisao_id, percentual from erp.documento_rateios
        where p_rateio_origem = 'documento' and documento_id = p_rateio_id) r;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A fila e o pedido
-- ---------------------------------------------------------------------------------------------
create function erp.tg_sienge_envio() returns trigger language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'A fila do Sienge só é escrita pelo sistema'; end if;
  if tg_op = 'DELETE' then raise exception 'A fila do Sienge não se apaga'; end if;
  if tg_op = 'UPDATE' then
    if new.titulo_id <> old.titulo_id or new.criado_em <> old.criado_em then raise exception 'Título e data da fila não mudam'; end if;
    if old.sienge_id is not null and new.sienge_id is distinct from old.sienge_id then
      raise exception 'O título já tem id no Sienge (%); não troca', old.sienge_id;
    end if;
    new.atualizado_em := clock_timestamp();
  end if;
  return new;
end $$;
create trigger t_sienge_envio before insert or update or delete on erp.sienge_envios
  for each row execute function erp.tg_sienge_envio();
create trigger t_aud_sienge_envios after insert or update on erp.sienge_envios
  for each row execute function erp.tg_auditoria('titulo_id');

-- O título está aprovado: aberto, sem fase pendente na alçada, sem recusa e fora da revisão.
create function erp.titulo_aprovado(p_titulo uuid) returns boolean language sql stable as $$
  select exists (select 1 from erp.titulos t where t.id = p_titulo and t.situacao = 'aberto')
     and erp.alcada_fase(p_titulo) is null and not erp.alcada_recusada(p_titulo) and not erp.em_revisao(p_titulo) $$;

-- Põe na fila os títulos a pagar aprovados (fornecedor e avulso). Devolve quantos entraram.
create function erp.sienge_enfileirar() returns int language plpgsql as $$
declare n int;
begin
  if not erp.sistema() then raise exception 'Só o sistema enfileira o envio ao Sienge'; end if;
  insert into erp.sienge_envios (titulo_id)
  select t.id from erp.titulos t
   where t.sentido = 'pagar' and t.tipo in ('fornecedor','avulso') and t.situacao = 'aberto'
     and not exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id)
     and erp.titulo_aprovado(t.id)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Tipo de documento do ERP → documento do Sienge (cadastro "Documentos" do Sienge, lido em 17/11/2026).
create function erp.sienge_documento(p_tipo text) returns text language sql immutable as $$
  select case p_tipo when 'nfse' then 'NFSE' when 'nfe' then 'NFE' when 'fatura' then 'FAT'
                     when 'boleto' then 'BLT' when 'guia' then 'GUIA' when 'recibo' then 'REC' end $$;

-- Monta o envio de um título: o corpo do POST /bills (com o marcador "ERP <id>" nas observações,
-- que o programa usa para achar o título se cair entre o POST e o registro) e cada parcela com a
-- forma de pagamento. Recusa com o motivo quando falta algo; nunca manda pela metade.
create function erp.sienge_pedido(p_titulo uuid) returns jsonb language plpgsql stable as $$
declare t erp.titulos; d erp.documentos_fiscais; v_empresa text; v_credor text; v_rateio jsonb; v_parcelas jsonb;
        v_falta text; v_n int; v_numero text; v_soma numeric; v_banco text[];
begin
  if not erp.sistema() then raise exception 'Só o sistema monta o envio ao Sienge'; end if;
  select * into t from erp.titulos where id = p_titulo;
  if t.id is null then raise exception 'Título não existe'; end if;
  if t.sentido <> 'pagar' or t.tipo not in ('fornecedor','avulso') then
    raise exception 'Só título a pagar de fornecedor ou avulso vai ao Sienge por aqui';
  end if;
  if not erp.titulo_aprovado(t.id) then raise exception 'O título não está aprovado'; end if;
  if t.documento_id is null then raise exception 'O título não tem documento (nota, boleto, fatura, guia ou recibo)'; end if;
  select * into d from erp.documentos_fiscais where id = t.documento_id;
  if erp.sienge_documento(d.tipo) is null then raise exception 'Documento do tipo % não tem código no Sienge', d.tipo; end if;
  if exists (select 1 from erp.documento_retencoes where documento_id = d.id) or coalesce(d.caucao_valor, 0) > 0 then
    raise exception 'Nota com retenção de imposto ou caução ainda não vai ao Sienge pelo adaptador';
  end if;
  v_numero := d.numero || case when d.serie <> '' then '-' || d.serie else '' end;
  if length(v_numero) > 20 then raise exception 'Número do documento passa de 20 caracteres: %', v_numero; end if;

  select codigo into v_empresa from erp.codigos_externos where sistema = 'sienge' and tabela = 'empresas' and registro_id = t.empresa_id;
  if v_empresa is null or v_empresa !~ '^[0-9]+$' then raise exception 'A empresa do título não tem código no Sienge'; end if;
  select codigo into v_credor from erp.codigos_externos where sistema = 'sienge' and tabela = 'pessoas' and registro_id = t.pessoa_id;
  if v_credor is null or v_credor !~ '^[0-9]+$' then raise exception 'O credor do título não tem código no Sienge'; end if;

  -- rateio: centro e conta do Sienge de cada linha, somando as linhas que caem no mesmo par
  select string_agg(distinct case when r.nucleo_economico_id is null or r.centro_custo_id is null then 'linha sem núcleo ou centro'
                                  when c.sienge_centro is null then 'núcleo + centro sem centro de custo do Sienge'
                                  when k.sienge_conta is null then 'natureza + centro sem conta do Sienge' end, '; ')
    into v_falta
    from erp.titulo_rateios r
    left join erp.sienge_centros c on c.nucleo_economico_id = r.nucleo_economico_id and c.centro_custo_id = r.centro_custo_id
    left join erp.sienge_contas k on k.natureza_id = r.natureza_id and k.centro_custo_id = r.centro_custo_id
   where r.titulo_id = t.id;
  if v_falta is not null then raise exception 'De-para do Sienge incompleto: %', v_falta; end if;
  -- percentual com 2 casas; o resto do arredondamento vai para a maior linha
  with g as (
    select c.sienge_centro, k.sienge_conta, sum(r.percentual) as pct
      from erp.titulo_rateios r
      join erp.sienge_centros c on c.nucleo_economico_id = r.nucleo_economico_id and c.centro_custo_id = r.centro_custo_id
      join erp.sienge_contas k on k.natureza_id = r.natureza_id and k.centro_custo_id = r.centro_custo_id
     where r.titulo_id = t.id group by 1, 2),
  a as (select *, round(pct, 2) as p2, row_number() over (order by pct desc, sienge_centro, sienge_conta) as ordem from g)
  select jsonb_agg(jsonb_build_object('costCenterId', sienge_centro, 'paymentCategoriesId', sienge_conta,
                                      'percentage', p2 + case when ordem = 1 then 100 - (select sum(p2) from a) else 0 end)
                   order by ordem)
    into v_rateio from a;

  -- parcelas, cada uma com a forma de pagamento
  select count(*), sum(p.valor) into v_n, v_soma from erp.parcelas p where p.titulo_id = t.id;
  if v_n = 0 or v_soma <> t.valor then raise exception 'As parcelas não somam o valor do título'; end if;
  select string_agg(p.numero::text, ', ' order by p.numero) into v_falta
    from erp.parcelas p where p.titulo_id = t.id
     and not exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = p.titulo_id and g.numero = p.numero);
  if v_falta is not null then raise exception 'Falta a forma de pagamento da parcela %', v_falta; end if;
  -- boleto do mesmo banco de uma conta ativa da empresa: "próprio banco" (1); senão "outros bancos" (2)
  select array_agg(distinct substring(cb.banco from '^[0-9]{3}')) into v_banco
    from erp.contas_bancarias cb where cb.empresa_id = t.empresa_id and cb.ativa;
  select jsonb_agg(jsonb_build_object('numero', p.numero, 'vencimento', p.vencimento, 'valor', p.valor, 'forma', g.forma)
                   || case g.forma
                        when 'pix' then jsonb_build_object('pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave)
                        else jsonb_build_object('boleto_linha', g.boleto_linha,
                                                'boleto_tipo', case when substr(g.boleto_linha, 1, 3) = any (coalesce(v_banco, '{}')) then 1 else 2 end)
                      end
                   order by p.numero)
    into v_parcelas
    from erp.parcelas p join erp.parcela_pagamentos g on g.titulo_id = p.titulo_id and g.numero = p.numero
   where p.titulo_id = t.id;

  return jsonb_build_object(
    'titulo_id', t.id,
    'empresa', v_empresa::int,
    'titulo', jsonb_build_object(
      'debtorId', v_empresa::int,
      'creditorId', v_credor::int,
      'documentIdentificationId', erp.sienge_documento(d.tipo),
      'documentNumber', v_numero,
      'issueDate', t.emissao,
      'billDate', (t.criado_em at time zone 'America/Sao_Paulo')::date,
      'baseDate', t.competencia,
      'dueDate', (select min(vencimento) from erp.parcelas where titulo_id = t.id),
      'indexId', 0,
      'installmentsNumber', v_n,
      'totalInvoiceAmount', t.valor,
      'discount', 0,
      'notes', left('ERP ' || t.id || coalesce(' · ' || nullif(trim(t.descricao), ''), ''), 500),
      'budgetCategories', v_rateio),
    'parcelas', v_parcelas);
end $$;

-- Guarda o id do título no Sienge assim que o POST responde (antes das parcelas e do pagamento).
create function erp.sienge_registrar(p_titulo uuid, p_sienge_id int) returns void language plpgsql as $$
begin
  if not erp.sistema() then raise exception 'Só o sistema registra o envio ao Sienge'; end if;
  update erp.sienge_envios set sienge_id = p_sienge_id, passo = 'criado' where titulo_id = p_titulo;
  if not found then raise exception 'O título não está na fila do Sienge'; end if;
  insert into erp.codigos_externos (sistema, tabela, registro_id, codigo)
  values ('sienge', 'titulos', p_titulo, p_sienge_id::text)
  on conflict (sistema, tabela, registro_id) do nothing;
  if (select codigo from erp.codigos_externos where sistema = 'sienge' and tabela = 'titulos' and registro_id = p_titulo)
     <> p_sienge_id::text then
    raise exception 'O título já está ligado a outro título do Sienge';
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: RLS, donos, políticas e privilégios
-- ---------------------------------------------------------------------------------------------
-- No Supabase o que o postgres cria nasce aberto aos papéis da API (privilégios padrão): fecha tudo
-- antes de abrir só o que vai abaixo.
do $$
declare t text; f regprocedure;
begin
  foreach t in array array['parcela_pagamentos','sienge_centros','sienge_contas','sienge_envios'] loop
    execute format('revoke all on erp.%I from public', t);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke all on erp.%I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke all on erp.%I from service_role', t); end if;
    execute format('revoke all on erp.%I from authenticated', t);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'erp' and p.proname in ('linha_digitavel_valida','chave_pix_valida','tg_parcela_pagamento',
              'tg_sienge_depara','tg_sienge_envio','titulo_aprovado','sienge_enfileirar','sienge_documento','sienge_pedido',
              'sienge_registrar','_chave_config','tg_evento_config') loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('revoke execute on function %s from authenticated', f);
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array['parcela_pagamentos','sienge_centros','sienge_contas','sienge_envios'] loop
    execute format('alter table erp.%I enable row level security', t);
    execute format('alter table erp.%I force row level security', t);
    execute format('create policy sistema on erp.%I using (erp.sistema()) with check (erp.sistema())', t);
    execute format('create policy conferencia on erp.%I for select to erp_conferencia using (true)', t);
    execute format('create policy operacao on erp.%I to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true)', t);
    execute format('create trigger t_nao_trunca before truncate on erp.%I for each statement execute function erp.tg_recusa_truncate()', t);
    execute format('grant select, insert, update, delete on erp.%I to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso', t);
    execute format('grant select on erp.%I to erp_conferencia', t);
  end loop;
  -- o de-para entra no pedido de mudança da configuração
  foreach t in array array['sienge_centros','sienge_contas'] loop
    execute format('grant select, insert, update, delete on erp.%I to erp_config', t);
    execute format('create policy config on erp.%I to erp_config using (erp.agindo_como(''erp_config'')) with check (erp.agindo_como(''erp_config''))', t);
  end loop;
end $$;

-- authenticated: a forma de pagamento como as parcelas (vê quem vê o título, grava quem lança nele);
-- o de-para, todo membro lê e só o master grava direto; a fila, quem vê o título lê e ninguém grava.
create policy perfil_le on erp.parcela_pagamentos for select to authenticated using (erp.vejo_titulo(titulo_id));
create policy perfil_inclui on erp.parcela_pagamentos for insert to authenticated with check (erp.lanco_titulo(titulo_id));
create policy perfil_altera on erp.parcela_pagamentos for update to authenticated using (erp.lanco_titulo(titulo_id)) with check (erp.lanco_titulo(titulo_id));
create policy perfil_apaga on erp.parcela_pagamentos for delete to authenticated using (erp.lanco_titulo(titulo_id));
grant select, insert, update, delete on erp.parcela_pagamentos to authenticated;
do $$
declare t text;
begin
  foreach t in array array['sienge_centros','sienge_contas'] loop
    execute format('create policy perfil_le on erp.%I for select to authenticated using (erp.membro())', t);
    execute format('create policy perfil_inclui on erp.%I for insert to authenticated with check (erp.sou_master())', t);
    execute format('create policy perfil_altera on erp.%I for update to authenticated using (erp.sou_master()) with check (erp.sou_master())', t);
    execute format('create policy perfil_apaga on erp.%I for delete to authenticated using (erp.sou_master())', t);
    execute format('grant select, insert, update, delete on erp.%I to authenticated', t);
  end loop;
end $$;
create policy perfil_le on erp.sienge_envios for select to authenticated using (erp.vejo_titulo(titulo_id));
grant select on erp.sienge_envios to authenticated;

-- A trava da forma de pagamento lê aprovações e a fila por baixo do RLS (senão uma linha escondida
-- de quem grava abriria a troca da chave depois do voto).
alter function erp.tg_parcela_pagamento() security definer set search_path = erp, pg_catalog, pg_temp;
alter function erp.tg_parcela_pagamento() owner to erp_conferencia;

-- EXECUTE: nada novo para public; as conferências puras e a trava para quem grava; a fila e o pedido
-- só para o sistema.
revoke execute on all functions in schema erp from public;
grant execute on function erp.linha_digitavel_valida(text), erp.chave_pix_valida(text, text), erp.sienge_documento(text),
                          erp.titulo_aprovado(uuid)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.sienge_enfileirar(), erp.sienge_pedido(uuid), erp.sienge_registrar(uuid, int),
                          erp.tg_parcela_pagamento(), erp.tg_sienge_depara(), erp.tg_sienge_envio()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp._chave_config(text) to erp_config, erp_conferencia;
