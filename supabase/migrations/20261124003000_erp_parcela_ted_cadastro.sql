-- Forma de pagamento do cadastro da conta recorrente no título, com a TED (Moises, 23/nov/2026: "inclua a opção" de TED;
-- "Abre a opção para o Aprovador final escolher (AF)" quando a cobrança vem de forma diferente da cadastrada).
--
-- 1. TED na parcela (erp.parcela_pagamentos, forma 'ted'): banco, agência, conta com o dígito, corrente ou poupança e
--    o CPF/CNPJ do titular. Como a chave PIX por CPF/CNPJ (S-125): o titular é o credor do título, ou a parcela só
--    entra com a justificativa da exceção (ted_excecao), que quem aprova vê. A conta nunca usada com o credor aparece
--    para quem aprova e gera o alerta crítico conta_ted_nova (para a AF) quando o título vai ao Sienge, como a chave
--    PIX nova. Ao Sienge vai pela forma 6 (TED, lida nos títulos 8471 e 8459 em 24/nov/2026) no
--    PATCH /bills/{id}/installments/{n}/payment-information/bank-transfer (bill-debt-v1.yaml, BankTransfer).
-- 2. api.lancar_titulo aceita a forma "cadastro": a parcela recebe o PIX fixo ou a TED da conta, com a justificativa
--    aprovada no cadastro. Passa pelas mesmas conferências de qualquer parcela: não herda o aprovado.
-- 3. A parcela de título de conta recorrente com forma diferente da cadastrada aparece para quem aprova com o aviso.
--    A AF (ou a AD, ou o master) escolhe: aprova a que veio, ou usa a do cadastro (erp.usar_forma_do_cadastro), que
--    troca as parcelas diferentes pela forma cadastrada mesmo depois do voto do gestor, fica registrado em
--    erp.titulo_forma_cadastro e só vale para a forma do cadastro. Quem lançou não escolhe (o master pode).
--    Na conta "vem com cada cobrança", o que vale é o boleto ou o PIX copia e cola da nota.
--
-- O mesmo corpo roda no bkm_dev (supabase/dev/ com o mesmo nome). Portabilidade: SQL e plpgsql padrão.

-- ---------------------------------------------------------------------------------------------
-- 1. TED na parcela
-- ---------------------------------------------------------------------------------------------
alter table erp.parcela_pagamentos drop constraint parcela_pagamentos_forma_check;
alter table erp.parcela_pagamentos
  add constraint parcela_pagamentos_forma_check check (forma in ('pix','boleto','ted')),
  add column ted_banco             text check (ted_banco ~ '^[0-9]{3}$'),
  add column ted_agencia           text check (ted_agencia ~ '^[0-9]{1,6}$'),
  add column ted_agencia_digito    text check (ted_agencia_digito ~ '^[0-9X]$'),
  add column ted_conta             text check (ted_conta ~ '^[0-9]{1,14}$'),
  add column ted_conta_digito      text check (ted_conta_digito ~ '^[0-9X]$'),
  add column ted_conta_tipo        text check (ted_conta_tipo in ('corrente','poupanca')),
  add column ted_titular_documento text check (ted_titular_documento ~ '^[0-9]{11}$' or erp.cnpj_aceito(ted_titular_documento)),
  add column ted_excecao           text,   -- justificativa da conta que não é do credor
  add constraint parcela_pagamentos_ted check ((forma = 'ted') = (ted_banco is not null and ted_agencia is not null and ted_conta is not null
                                                and ted_conta_digito is not null and ted_conta_tipo is not null and ted_titular_documento is not null)),
  add constraint parcela_pagamentos_so_ted check (forma = 'ted' or (ted_agencia_digito is null and ted_excecao is null)),
  add constraint parcela_pagamentos_ted_sem_pix check (forma <> 'ted' or pix_copia_cola is null),
  add constraint parcela_pagamentos_ted_excecao check (ted_excecao is null or length(trim(ted_excecao)) > 0);

-- O titular da TED é o credor do título, ou a parcela entra com a justificativa (a que sobra, some).
create function erp.tg_parcela_ted() returns trigger language plpgsql security definer
set search_path = erp, pg_catalog, pg_temp as $$
declare v_doc text;
begin
  if new.forma <> 'ted' then return new; end if;
  select p.documento into v_doc from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = new.titulo_id;
  if new.ted_titular_documento = v_doc then
    new.ted_excecao := null;
  elsif length(trim(coalesce(new.ted_excecao, ''))) = 0 then
    raise exception 'A conta da TED da parcela % não é do credor do título (só com a justificativa da exceção)', new.numero;
  end if;
  return new;
end $$;
create trigger t_parcela_ted before insert or update on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_ted();

-- De novo no pedido ao Sienge (a parcela pode ter mudado na revisão).
create function erp._conferir_ted(p_titulo uuid) returns void language plpgsql stable as $$
declare v_n int;
begin
  select min(g.numero) into v_n from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id join erp.pessoas p on p.id = t.pessoa_id
   where g.titulo_id = p_titulo and g.forma = 'ted' and g.ted_titular_documento is distinct from p.documento
     and length(trim(coalesce(g.ted_excecao, ''))) = 0;
  if v_n is not null then
    raise exception 'A conta da TED da parcela % não é do credor do título (só com a justificativa da exceção)', v_n;
  end if;
end $$;

-- Conta já usada com o credor: numa parcela de outro título dele que já foi ao Sienge, com o mesmo titular (como a chave
-- PIX; a mesma conta com outro titular é conta nova).
create function erp._conta_ted_conhecida(p_pessoa uuid, p_banco text, p_agencia text, p_conta text, p_digito text, p_titular text, p_titulo uuid)
returns boolean language sql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
  select exists (select 1 from erp.parcela_pagamentos g
                   join erp.titulos t on t.id = g.titulo_id
                   join erp.sienge_envios e on e.titulo_id = t.id and e.sienge_id is not null
                  where t.pessoa_id = p_pessoa and g.forma = 'ted' and g.ted_banco = p_banco and g.ted_agencia = p_agencia
                    and g.ted_conta = p_conta and g.ted_conta_digito = p_digito and g.ted_titular_documento = p_titular
                    and g.titulo_id <> p_titulo) $$;

insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('conta_ted_nova', 'Título vai ao Sienge com conta de TED nunca usada com o credor', 'pagar', true);
insert into erp.regras_notificacao (tipo, destino, lista) values ('conta_ted_nova', 'lista', 'AF');

-- ---------------------------------------------------------------------------------------------
-- 2. A forma cadastrada na conta recorrente
-- ---------------------------------------------------------------------------------------------
-- A parcela tem a forma que o cadastro da conta aceita? Nulo: o título não é de conta com forma cadastrada, ou o
-- cadastro está esperando aprovação (a versão pendente nunca vale como "a cadastrada"; revisão de segurança, 24/11).
-- Lê o cadastro por baixo do RLS (quem aprova pode não ver a conta).
create function erp._cadastro_aceita(g erp.parcela_pagamentos, p_compromisso uuid) returns boolean
language sql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
  select case c.modo
    when 'pix' then g.forma = 'pix' and g.pix_tipo = c.pix_tipo and g.pix_chave = c.pix_chave
    when 'ted' then g.forma = 'ted' and g.ted_banco = c.banco and g.ted_agencia = c.agencia
                    and g.ted_agencia_digito is not distinct from c.agencia_digito and g.ted_conta = c.conta
                    and g.ted_conta_digito = c.conta_digito and g.ted_conta_tipo = c.conta_tipo
                    and g.ted_titular_documento = c.titular_documento
    when 'cobranca' then g.forma = 'boleto' or (g.forma = 'pix' and g.pix_copia_cola is not null) end
    from erp.compromisso_pagamentos c where c.compromisso_id = p_compromisso and erp.compromisso_aprovado(p_compromisso) $$;

-- A forma cadastrada em poucas palavras, para o aviso.
create function erp._texto_forma_cadastro(p_compromisso uuid) returns text
language sql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
  select case c.modo when 'pix' then 'PIX fixo (' || c.pix_chave || ')'
                     when 'ted' then 'TED (banco ' || c.banco || ', agência ' || c.agencia || ', conta ' || c.conta || '-' || c.conta_digito || ')'
                     else 'vem com cada cobrança (boleto ou PIX copia e cola)' end
    from erp.compromisso_pagamentos c where c.compromisso_id = p_compromisso and erp.compromisso_aprovado(p_compromisso) $$;

-- A escolha da AF: a forma do cadastro no lugar da que veio, por rodada da alçada.
create table erp.titulo_forma_cadastro (
  titulo_id uuid not null references erp.titulos,
  rodada    int not null,
  por       uuid not null references erp.usuarios,
  em        timestamptz not null default clock_timestamp(),
  txid      bigint not null default txid_current(),   -- a troca das parcelas só vale nesta transação
  primary key (titulo_id, rodada)
);
do $$ begin
  revoke all on erp.titulo_forma_cadastro from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.titulo_forma_cadastro from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then revoke all on erp.titulo_forma_cadastro from service_role; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on erp.titulo_forma_cadastro from authenticated; end if;
end $$;
alter table erp.titulo_forma_cadastro enable row level security;
alter table erp.titulo_forma_cadastro force row level security;
create policy sistema on erp.titulo_forma_cadastro using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.titulo_forma_cadastro for select to erp_conferencia using (true);
create policy operacao on erp.titulo_forma_cadastro to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true);
create policy perfil_le on erp.titulo_forma_cadastro for select to authenticated using (erp.vejo_titulo(titulo_id));
create trigger t_nao_trunca before truncate on erp.titulo_forma_cadastro for each statement execute function erp.tg_recusa_truncate();
grant select, insert on erp.titulo_forma_cadastro to erp_sistema, erp_situacao;
grant select on erp.titulo_forma_cadastro to erp_conferencia, authenticated;
create trigger t_aud_titulo_forma_cadastro after insert or update or delete on erp.titulo_forma_cadastro
  for each row execute function erp.tg_auditoria('titulo_id');

-- A AF (ou a AD, ou o master) troca as parcelas diferentes pela forma cadastrada, com o título em aprovação.
create function erp.usar_forma_do_cadastro(p_titulo uuid) returns int language plpgsql
security definer set search_path = erp, pg_catalog, pg_temp as $$
declare t erp.titulos; c erp.compromisso_pagamentos; v_eu uuid := erp.eu(); n int;
begin
  perform erp.exigir_editor();
  select * into t from erp.titulos where id = p_titulo for update;
  if t.id is null or not erp.vejo_titulo(t.id) then raise exception 'Título não encontrado'; end if;
  if t.situacao <> 'aberto' or erp.titulo_aprovado(t.id) or erp.alcada_recusada(t.id) or erp.em_revisao(t.id)
     or exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id) then
    raise exception 'A forma só se troca com o título em aprovação';
  end if;
  if not erp.sou_master() and not erp._ocupa_vaga('AF', null, v_eu) then
    raise exception 'A escolha da forma de pagamento é da AF';
  end if;
  if t.criado_por = v_eu and not erp.sou_master() then raise exception 'Quem lançou não escolhe a forma de pagamento'; end if;
  select * into c from erp.compromisso_pagamentos where compromisso_id = t.compromisso_id;
  if c.modo is null then raise exception 'O título não é de conta recorrente com forma de pagamento cadastrada'; end if;
  if not erp.compromisso_aprovado(t.compromisso_id) then raise exception 'O cadastro da forma está esperando aprovação'; end if;
  if c.modo = 'cobranca' then raise exception 'Na conta, a forma vem com cada cobrança: vale a desta nota'; end if;
  if not exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = t.id and not coalesce(erp._cadastro_aceita(g, t.compromisso_id), true)) then
    raise exception 'As parcelas já estão com a forma cadastrada';
  end if;
  insert into erp.titulo_forma_cadastro (titulo_id, rodada, por) values (t.id, t.rodada, v_eu);
  update erp.parcela_pagamentos g
     set forma = c.modo, pix_tipo = case when c.modo = 'pix' then c.pix_tipo end, pix_chave = case when c.modo = 'pix' then c.pix_chave end,
         pix_excecao = case when c.modo = 'pix' then c.excecao end, boleto_linha = null, boleto_excecao = null,
         pix_copia_cola = null, pix_copia_cola_excecao = null,
         ted_banco = case when c.modo = 'ted' then c.banco end, ted_agencia = case when c.modo = 'ted' then c.agencia end,
         ted_agencia_digito = case when c.modo = 'ted' then c.agencia_digito end, ted_conta = case when c.modo = 'ted' then c.conta end,
         ted_conta_digito = case when c.modo = 'ted' then c.conta_digito end, ted_conta_tipo = case when c.modo = 'ted' then c.conta_tipo end,
         ted_titular_documento = case when c.modo = 'ted' then c.titular_documento end, ted_excecao = case when c.modo = 'ted' then c.excecao end
   where g.titulo_id = t.id and not coalesce(erp._cadastro_aceita(g, t.compromisso_id), true);
  get diagnostics n = row_count;
  return n;
end $$;

-- Pela tela.
create function api.usar_forma_do_cadastro(p_titulo uuid) returns int language sql volatile security invoker
set search_path = pg_catalog, pg_temp as $$ select erp.usar_forma_do_cadastro(p_titulo) $$;

-- ---------------------------------------------------------------------------------------------
-- 3. As funções de sempre, com a TED e o cadastro (mesmos corpos de antes, com as linhas novas)
-- ---------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION api.lancar_titulo(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
declare v_doc uuid; v_tit uuid; l jsonb; c erp.compromisso_pagamentos; v_div uuid; v_raiz uuid; v_venc date[]; v_prev uuid[]; v_val numeric[]; i int := 0;
begin
  perform erp.exigir_editor();
  if jsonb_typeof(p->'rateio') <> 'array' or jsonb_array_length(p->'rateio') = 0 then raise exception 'Informe o rateio'; end if;
  if jsonb_typeof(p->'parcelas') <> 'array' or jsonb_array_length(p->'parcelas') = 0 then raise exception 'Informe ao menos uma parcela'; end if;
  if coalesce(p->>'tipo', '') not in ('nfse','nfe','fatura','boleto','iptu','itbi','darf','darm','dare','recibo','outro') then raise exception 'Tipo de documento inválido'; end if;
  if length(trim(coalesce(p->>'numero', ''))) = 0 then raise exception 'Informe o número do documento'; end if;

  insert into erp.documentos_fiscais (empresa_id, emitente_id, compromisso_id, tipo, numero, serie, emissao, competencia, valor_bruto)
  values ((p->>'empresa')::uuid, (p->>'fornecedor')::uuid, nullif(p->>'compromisso', '')::uuid, p->>'tipo', trim(p->>'numero'),
          coalesce(trim(p->>'serie'), ''), (p->>'emissao')::date, (p->>'competencia')::date, (p->>'valor')::numeric)
  returning id into v_doc;

  for l in select * from jsonb_array_elements(p->'rateio') loop
    v_div := nullif(l->>'divisao', '')::uuid;
    select coalesce(d.raiz_id, d.id) into v_raiz from erp.divisoes d where d.id = v_div;
    if v_div is not null and v_raiz is null then raise exception 'Divisão não encontrada'; end if;
    insert into erp.documento_rateios (documento_id, nucleo_economico_id, centro_custo_id, divisao_id, subdivisao_id, natureza_id, percentual)
    values (v_doc, nullif(l->>'nucleo', '')::uuid, nullif(l->>'centro', '')::uuid, v_raiz,
            case when v_div is distinct from v_raiz then v_div end, (l->>'natureza')::uuid, (l->>'percentual')::numeric);
  end loop;

  select array_agg((x->>'vencimento')::date order by n) into v_venc from jsonb_array_elements(p->'parcelas') with ordinality a(x, n);
  if exists (select 1 from unnest(v_venc) d where d is null) then raise exception 'Informe o vencimento de cada parcela'; end if;
  select array_agg(x::uuid) into v_prev from jsonb_array_elements_text(coalesce(p->'previsoes', '[]'::jsonb)) x;
  select count(*) filter (where nullif(x->>'valor', '') is not null)::int into i from jsonb_array_elements(p->'parcelas') x;
  if i > 0 and i < jsonb_array_length(p->'parcelas') then raise exception 'Informe o valor de todas as parcelas, ou de nenhuma'; end if;
  if i > 0 then
    select array_agg((x->>'valor')::numeric order by n) into v_val from jsonb_array_elements(p->'parcelas') with ordinality a(x, n);
  end if;
  i := 0;
  v_tit := erp.lancar_documento(v_doc, v_venc, v_prev, v_val);

  for l in select x from jsonb_array_elements(p->'parcelas') x loop
    i := i + 1;
    -- "cadastro": a forma cadastrada na conta recorrente (PIX fixo ou TED), com a justificativa aprovada no cadastro;
    -- passa pelas mesmas conferências da parcela (não herda o aprovado)
    if l->>'forma' = 'cadastro' then
      select * into c from erp.compromisso_pagamentos where compromisso_id = nullif(p->>'compromisso', '')::uuid;
      if c.modo is null or c.modo = 'cobranca' then
        raise exception 'A conta não tem PIX fixo nem TED no cadastro: informe a forma de pagamento desta cobrança';
      end if;
      if not coalesce(erp.contrato_aprovado_visto(nullif(p->>'compromisso', '')::uuid), false) then
        raise exception 'O cadastro da forma está esperando aprovação: informe a forma de pagamento desta cobrança';
      end if;
      l := case c.modo when 'pix' then jsonb_build_object('forma', 'pix', 'pix_tipo', c.pix_tipo, 'pix_chave', c.pix_chave, 'pix_excecao', c.excecao)
           else jsonb_build_object('forma', 'ted', 'ted_banco', c.banco, 'ted_agencia', c.agencia, 'ted_agencia_digito', c.agencia_digito,
                                   'ted_conta', c.conta, 'ted_conta_digito', c.conta_digito, 'ted_conta_tipo', c.conta_tipo,
                                   'ted_titular_documento', c.titular_documento, 'ted_excecao', c.excecao) end;
    end if;
    insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao, pix_copia_cola, pix_copia_cola_excecao, boleto_excecao,
                                        ted_banco, ted_agencia, ted_agencia_digito, ted_conta, ted_conta_digito, ted_conta_tipo, ted_titular_documento, ted_excecao)
    values (v_tit, i, l->>'forma', nullif(l->>'pix_tipo', ''), nullif(trim(l->>'pix_chave'), ''),
            nullif(regexp_replace(coalesce(l->>'boleto_linha', ''), '[^0-9]', '', 'g'), ''), nullif(trim(l->>'pix_excecao'), ''),
            nullif(regexp_replace(coalesce(l->>'pix_copia_cola', ''), '^\s+|\s+$', '', 'g'), ''),
            nullif(trim(l->>'pix_copia_cola_excecao'), ''), nullif(trim(l->>'boleto_excecao'), ''),
            nullif(regexp_replace(coalesce(l->>'ted_banco', ''), '[^0-9]', '', 'g'), ''),
            nullif(regexp_replace(coalesce(l->>'ted_agencia', ''), '[^0-9]', '', 'g'), ''),
            nullif(upper(trim(l->>'ted_agencia_digito')), ''),
            nullif(regexp_replace(coalesce(l->>'ted_conta', ''), '[^0-9]', '', 'g'), ''),
            nullif(upper(trim(l->>'ted_conta_digito')), ''), nullif(l->>'ted_conta_tipo', ''),
            nullif(upper(regexp_replace(coalesce(l->>'ted_titular_documento', ''), '[^0-9A-Za-z]', '', 'g')), ''),
            nullif(trim(l->>'ted_excecao'), ''));
  end loop;

  insert into erp.titulo_etiquetas (titulo_id, etiqueta_id)
  select v_tit, x::uuid from jsonb_array_elements_text(coalesce(p->'etiquetas', '[]'::jsonb)) x;

  perform erp._ligar_anexos(v_doc, p->'anexos');

  return v_tit;
end $function$;

CREATE OR REPLACE FUNCTION erp.sienge_pedido(p_titulo uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
  perform erp._conferir_forma_pagamento(g.titulo_id, g.numero, g.forma, g.pix_tipo, g.pix_chave, g.boleto_linha, g.pix_excecao)
     from erp.parcela_pagamentos g where g.titulo_id = t.id;
  perform erp._conferir_recebedores(t.id);
  perform erp._conferir_ted(t.id);
  -- boleto do mesmo banco de uma conta ativa da empresa: "próprio banco" (1); senão "outros bancos" (2)
  select array_agg(distinct substring(cb.banco from '^[0-9]{3}')) into v_banco
    from erp.contas_bancarias cb where cb.empresa_id = t.empresa_id and cb.ativa;
  select jsonb_agg(jsonb_build_object('numero', p.numero, 'vencimento', p.vencimento, 'valor', p.valor, 'forma', g.forma)
                   || case g.forma
                        when 'pix' then jsonb_build_object('pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave)
                        when 'ted' then jsonb_build_object('ted', jsonb_build_object(
                          'banco', g.ted_banco, 'agencia', g.ted_agencia, 'agencia_digito', g.ted_agencia_digito,
                          'conta', g.ted_conta, 'conta_digito', g.ted_conta_digito, 'conta_tipo', g.ted_conta_tipo,
                          'titular_documento', g.ted_titular_documento,
                          -- o nome vai só quando a conta é do credor (o de outra pessoa o ERP não tem)
                          'titular_nome', (select x.nome from erp.pessoas x where x.id = t.pessoa_id and x.documento = g.ted_titular_documento)))
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
      'billDate', t.competencia,
      'baseDate', t.emissao,
      'dueDate', (select min(vencimento) from erp.parcelas where titulo_id = t.id),
      'indexId', 0,
      'installmentsNumber', v_n,
      'totalInvoiceAmount', t.valor,
      'discount', 0,
      'notes', left('ERP ' || t.id || coalesce(' · ' || nullif(trim(t.descricao), ''), ''), 500),
      'budgetCategories', v_rateio),
    'parcelas', v_parcelas);
end $function$;

CREATE OR REPLACE FUNCTION erp.avisos_forma_pagamento(p_titulo uuid)
 RETURNS TABLE(numero integer, avisos text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
  select g.numero,
         array_remove(array[
           case when g.pix_tipo in ('email','telefone','aleatoria') then 'A chave não é do documento do credor' end,
           case when g.pix_excecao is not null then 'Chave CPF/CNPJ de outra pessoa: ' || g.pix_excecao end,
           case when g.forma = 'pix' and not erp._chave_pix_conhecida(t.pessoa_id, g.pix_chave, t.id)
                then 'Chave nova para este credor' end,
           case when g.ted_excecao is not null then 'Conta da TED de outra pessoa: ' || g.ted_excecao end,
           case when g.forma = 'ted' and not erp._conta_ted_conhecida(t.pessoa_id, g.ted_banco, g.ted_agencia, g.ted_conta, g.ted_conta_digito, g.ted_titular_documento, t.id)
                then 'Conta da TED nova para este credor' end,
           case when not erp._cadastro_aceita(g, t.compromisso_id)
                then 'Diferente da forma cadastrada na conta recorrente: ' || erp._texto_forma_cadastro(t.compromisso_id)
                     || '. A AF escolhe qual vale' end,
           case when exists (select 1 from erp.compromisso_pagamentos c where c.compromisso_id = t.compromisso_id)
                     and not erp.compromisso_aprovado(t.compromisso_id)
                then 'O cadastro da forma de pagamento da conta está esperando aprovação' end,
           case when exists (select 1 from erp.titulo_forma_cadastro f where f.titulo_id = t.id and f.rodada = t.rodada)
                then 'A AF trocou para a forma cadastrada na conta recorrente' end], null)
    from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id
   where g.titulo_id = p_titulo and (erp.sistema() or erp.vejo_titulo(p_titulo))
   order by g.numero $function$;

CREATE OR REPLACE FUNCTION erp.sienge_enfileirar()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare n int := 0; m int; r record;
begin
  if not erp.sistema() then raise exception 'Só o sistema enfileira o envio ao Sienge'; end if;
  perform erp.orcamento_vencer();   -- a sobra do mês do orçamento de área, depois da carência
  for r in
    with novos as (
      insert into erp.sienge_envios (titulo_id)
      select t.id from erp.titulos t
       where t.sentido = 'pagar' and t.tipo in ('fornecedor','avulso') and t.situacao = 'aberto'
         and not exists (select 1 from erp.sienge_envios e where e.titulo_id = t.id)
         and erp.titulo_aprovado(t.id)
      on conflict do nothing
      returning titulo_id)
    select x.titulo_id, t.pessoa_id,
           (select jsonb_agg(jsonb_build_object('numero', g.numero, 'pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave) order by g.numero)
              from erp.parcela_pagamentos g
             where g.titulo_id = x.titulo_id and g.forma = 'pix'
               and not erp._chave_pix_conhecida(t.pessoa_id, g.pix_chave, x.titulo_id)) as chaves,
           (select array[r2.nucleo_economico_id, r2.centro_custo_id] from erp.titulo_rateios r2
             where r2.titulo_id = x.titulo_id order by r2.percentual desc, r2.id limit 1) as onde
      from novos x join erp.titulos t on t.id = x.titulo_id
  loop
    n := n + 1;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null) then
      perform erp.registrar_evento('boleto_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'conferido', erp.boleto_conferido(g.boleto_linha),
                                                           'justificativa', g.boleto_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.boleto_excecao is not null),
          'motivo', 'Boleto com beneficiário não conferido'));
    end if;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null) then
      perform erp.registrar_evento('pix_copia_cola_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'recebedor', erp.pix_copia_cola_recebedor(g.pix_copia_cola),
                                                           'conferido', erp.pix_conferido(g.pix_copia_cola),
                                                           'justificativa', g.pix_copia_cola_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null),
          'motivo', 'PIX copia e cola com recebedor não conferido'));
    end if;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.forma = 'ted'
                and not erp._conta_ted_conhecida(r.pessoa_id, g.ted_banco, g.ted_agencia, g.ted_conta, g.ted_conta_digito, g.ted_titular_documento, r.titulo_id)) then
      perform erp.registrar_evento('conta_ted_nova', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(g.numero order by g.numero) from erp.parcela_pagamentos g
                        where g.titulo_id = r.titulo_id and g.forma = 'ted'
                          and not erp._conta_ted_conhecida(r.pessoa_id, g.ted_banco, g.ted_agencia, g.ted_conta, g.ted_conta_digito, g.ted_titular_documento, r.titulo_id)),
          'motivo', 'Conta da TED nunca usada com este credor'));
    end if;
    if r.chaves is not null then
      perform erp.registrar_evento('chave_pix_nova', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id, 'parcelas', r.chaves,
                           'motivo', 'Chave PIX nunca usada com este credor: '
                                     || (select string_agg(c->>'pix_chave', ', ') from jsonb_array_elements(r.chaves) c)));
    end if;
  end loop;

  insert into erp.sienge_previsoes (previsao_id)
  select p.id from erp.previsoes p
   where p.sentido = 'pagar' and p.situacao = 'aberta'
     and not exists (select 1 from erp.sienge_previsoes s where s.previsao_id = p.id)
     and erp.previsao_aprovada(p.id)
  on conflict do nothing;
  get diagnostics m = row_count;

  update erp.sienge_previsoes s set apagar_desde = clock_timestamp()
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is not null and s.apagar_desde is null;
  update erp.sienge_previsoes s set situacao = 'descartado', erro = 'A previsão saiu de aberta antes de ir ao Sienge'
    from erp.previsoes p
   where p.id = s.previsao_id and p.situacao <> 'aberta' and s.sienge_id is null and s.situacao <> 'descartado';
  return n + m;
end $function$;

CREATE OR REPLACE FUNCTION erp.tg_parcela_pagamento()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'erp', 'pg_catalog', 'pg_temp'
AS $function$
declare t erp.titulos; v_id uuid := case when tg_op = 'DELETE' then old.titulo_id else new.titulo_id end;
begin
  if tg_op = 'UPDATE' and new.titulo_id <> old.titulo_id then
    raise exception 'A forma de pagamento não muda de título';
  end if;
  select * into t from erp.titulos where id = v_id;
  -- S-125: o boleto é da parcela e a chave CPF/CNPJ é do credor (ou vem com a justificativa da exceção)
  if tg_op <> 'DELETE' then
    -- a exceção só existe quando a chave CPF/CNPJ não é a do credor; fora disso, some
    if new.pix_tipo is distinct from 'cpf_cnpj'
       or new.pix_chave = (select p.documento from erp.pessoas p where p.id = t.pessoa_id) then
      new.pix_excecao := null;
    end if;
    perform erp._conferir_forma_pagamento(new.titulo_id, new.numero, new.forma, new.pix_tipo, new.pix_chave, new.boleto_linha,
                                          new.pix_excecao);
  end if;
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
  -- a AF escolheu a forma cadastrada na conta recorrente (erp.usar_forma_do_cadastro, nesta mesma transação): só
  -- para a forma do cadastro
  if tg_op = 'UPDATE' and exists (select 1 from erp.titulo_forma_cadastro f
                                   where f.titulo_id = t.id and f.rodada = t.rodada and f.txid = txid_current())
     and erp._cadastro_aceita(new, t.compromisso_id) and new.pix_copia_cola is null and new.boleto_linha is null then
    return new;
  end if;
  raise exception 'A forma de pagamento só muda antes do primeiro voto da alçada (ou na revisão do título)';
end $function$;

-- ---------------------------------------------------------------------------------------------
-- 4. Donos e EXECUTE
-- ---------------------------------------------------------------------------------------------
do $$
declare f regprocedure;
begin
  foreach f in array array['erp.tg_parcela_ted()', 'erp._conferir_ted(uuid)', 'erp._conta_ted_conhecida(uuid, text, text, text, text, text, uuid)',
                           'erp._cadastro_aceita(erp.parcela_pagamentos, uuid)', 'erp._texto_forma_cadastro(uuid)',
                           'erp.usar_forma_do_cadastro(uuid)', 'api.usar_forma_do_cadastro(uuid)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    if exists (select 1 from pg_roles where rolname = 'authenticated') then execute format('revoke execute on function %s from authenticated', f); end if;
  end loop;
  foreach f in array array['erp.tg_parcela_ted()', 'erp._conferir_ted(uuid)', 'erp._conta_ted_conhecida(uuid, text, text, text, text, text, uuid)',
                           'erp._cadastro_aceita(erp.parcela_pagamentos, uuid)', 'erp._texto_forma_cadastro(uuid)', 'erp.usar_forma_do_cadastro(uuid)']::regprocedure[] loop
    execute format('grant execute on function %s to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso', f);
  end loop;
  -- a tela chama a escolha da AF (a função confere quem chama)
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    grant execute on function erp.usar_forma_do_cadastro(uuid), api.usar_forma_do_cadastro(uuid) to authenticated;
  end if;
end $$;
alter function erp.tg_parcela_ted() owner to erp_conferencia;
alter function erp._conta_ted_conhecida(uuid, text, text, text, text, text, uuid) owner to erp_conferencia;
alter function erp._cadastro_aceita(erp.parcela_pagamentos, uuid) owner to erp_conferencia;
alter function erp._texto_forma_cadastro(uuid) owner to erp_conferencia;
alter function erp.usar_forma_do_cadastro(uuid) owner to erp_situacao;
