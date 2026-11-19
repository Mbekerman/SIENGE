-- Lançar título a partir do arquivo (Moises, 18/11/2026: "O primeiro passo deve ser subir o arquivo do título [...] o
-- sistema tentasse identificar dados chave [...] identificaria possíveis matchs entre as previsões, contratos
-- recorrentes e contratos, pedidos de compra [...] puxa-se de lá todos os dados [...] Se o fornecedor já tiver chave
-- Pix cadastrada ou outra forma de pagamento padrão, o sistema já pré seleciona. Tudo pode ser alterado").
--
-- 1. erp.anexos: o registro do arquivo (nome, tipo, tamanho, sha256 e o que o leitor tirou dele). O arquivo em si não
--    fica no banco nem no Storage do Supabase: fica no bucket do nosso serviço de leitura (Cloud Run, projeto
--    bkm-erp), com o nome igual ao id da linha (regra de portabilidade, doc 06: arquivos atrás de camada nossa, sem
--    regra em política de Storage). O serviço só entrega o arquivo a quem lê a linha aqui (pergunta ao banco com o
--    login da pessoa), então quem pode baixar é quem vê o anexo pelo RLS abaixo.
--    - Antes da nota: só quem subiu (e o master) vê e apaga. Depois de ligado à nota, vê quem vê a nota
--      (erp.vejo_documento, que já esconde o PJ), e ninguém apaga nem troca: o anexo da nota lançada fica.
--    - A ligação à nota é uma vez só, pela própria pessoa que subiu, numa nota que ela mesma lançou.
--    - Nome, tipo, tamanho, sha256 e autor não mudam depois de gravados; a leitura muda só antes da nota.
--    - Sem auditoria em erp.auditoria: a leitura traz CNPJ e valor de uma nota que pode ser PJ, e o administrador
--      (que lê a auditoria) não pode ver PJ; a linha guarda quem subiu e quando, e a ligação à nota aparece no
--      rastro do título.
-- 2. api.identificar_nota: com o que o leitor tirou do arquivo (CNPJ do tomador e do emitente, número, valor, datas),
--    acha a empresa, o fornecedor, a nota repetida e os processos que podem ter gerado o título: previsões abertas e
--    contratos ativos (contrato, assinatura recorrente, pedido), com pontos por fornecedor, valor e data, e o rateio
--    de cada um para preencher a tela; e a última forma de pagamento usada com esse fornecedor. Tudo SECURITY
--    INVOKER: só aparece o que a pessoa já vê.
-- 3. api.lancar_titulo liga os anexos à nota (campo "anexos": [uuid]) e api.titulo_rastro devolve os anexos.
-- Portabilidade: SQL puro.

create table erp.anexos (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null check (length(trim(nome)) between 1 and 255),
  tipo_mime    text not null check (tipo_mime in ('application/pdf', 'application/xml', 'text/xml', 'image/jpeg', 'image/png')),
  tamanho      bigint not null check (tamanho > 0 and tamanho <= 20971520),   -- até 20 MB
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  leitura      jsonb check (leitura is null or jsonb_typeof(leitura) = 'object'),  -- o que o leitor tirou
  lido_em      timestamptz,
  documento_id uuid references erp.documentos_fiscais,
  ligado_em    timestamptz,
  criado_por   uuid,
  criado_em    timestamptz not null default now(),
  check ((documento_id is null) = (ligado_em is null))
);
create index on erp.anexos (documento_id) where documento_id is not null;
create index on erp.anexos (sha256);
create index on erp.anexos (criado_por) where documento_id is null;

-- Autor posto pelo banco; o que é do arquivo não muda; a ligação é uma vez só.
create function erp.tg_anexo() returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.criado_por := erp.autor();
    new.criado_em := clock_timestamp();
    if new.documento_id is not null then raise exception 'O anexo se liga à nota no lançamento'; end if;
    new.ligado_em := null;
    new.lido_em := case when new.leitura is not null then clock_timestamp() end;
    return new;
  end if;
  if new.nome is distinct from old.nome or new.tipo_mime is distinct from old.tipo_mime or new.tamanho is distinct from old.tamanho
     or new.sha256 is distinct from old.sha256 or new.criado_por is distinct from old.criado_por or new.criado_em is distinct from old.criado_em then
    raise exception 'O arquivo do anexo não muda: suba outro';
  end if;
  if old.documento_id is not null then raise exception 'Anexo já ligado à nota não muda'; end if;
  if new.leitura is distinct from old.leitura then new.lido_em := clock_timestamp(); end if;
  new.ligado_em := case when new.documento_id is not null then clock_timestamp() end;
  return new;
end $$;
create trigger t_anexo before insert or update on erp.anexos for each row execute function erp.tg_anexo();

alter table erp.anexos enable row level security;
alter table erp.anexos force row level security;
create policy sistema on erp.anexos using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.anexos for select to erp_conferencia using (true);
create policy operacao on erp.anexos to erp_situacao, erp_reclassificacao, erp_acesso using (true) with check (true);
create trigger t_nao_trunca before truncate on erp.anexos for each statement execute function erp.tg_recusa_truncate();
grant select, insert, update, delete on erp.anexos to erp_sistema, erp_situacao, erp_reclassificacao, erp_acesso;
grant select on erp.anexos to erp_conferencia;

create policy perfil_le on erp.anexos for select to authenticated
  using (erp.membro() and (case when documento_id is null then criado_por = erp.eu() or erp.sou_master()
                                else erp.vejo_documento(documento_id) end));
create policy perfil_inclui on erp.anexos for insert to authenticated
  with check (erp.escrevo() and documento_id is null and criado_por = erp.eu());
-- antes da nota: quem subiu muda a leitura e liga o anexo a uma nota que ele mesmo lançou (e em que lança)
create policy perfil_altera on erp.anexos for update to authenticated
  using (erp.escrevo() and documento_id is null and criado_por = erp.eu())
  with check (erp.escrevo() and criado_por = erp.eu()
              and (documento_id is null
                   or (erp.lanco_documento(documento_id)
                       and exists (select 1 from erp.documentos_fiscais d where d.id = documento_id and d.criado_por = erp.eu()))));
create policy perfil_apaga on erp.anexos for delete to authenticated
  using (erp.escrevo() and documento_id is null and criado_por = erp.eu());
grant select, insert, update, delete on erp.anexos to authenticated;

-- ---------------------------------------------------------------------------------------------
-- api: registrar o arquivo e a leitura (o serviço de leitura chama com o login da pessoa)
-- ---------------------------------------------------------------------------------------------
-- Registra o arquivo e devolve o id (que é o nome do arquivo no bucket) e as notas, que a pessoa vê, com o mesmo
-- arquivo (mesmo sha256) já anexado.
create function api.registrar_anexo(p_nome text, p_tipo_mime text, p_tamanho bigint, p_sha256 text)
returns jsonb language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
declare v uuid;
begin
  perform erp.exigir_editor();
  insert into erp.anexos (nome, tipo_mime, tamanho, sha256) values (trim(p_nome), lower(p_tipo_mime), p_tamanho, lower(p_sha256))
  returning id into v;
  return jsonb_build_object('id', v,
    'repetido_em', coalesce((select jsonb_agg(distinct jsonb_build_object('documento_id', d.id, 'tipo', d.tipo, 'numero', d.numero,
                                    'emissao', d.emissao, 'valor', d.valor_bruto,
                                    'titulo_id', (select t.id from erp.titulos t where t.documento_id = d.id and t.tipo = 'fornecedor'
                                                    and t.situacao <> 'cancelado' order by t.criado_em desc limit 1)))
                               from erp.anexos a join erp.documentos_fiscais d on d.id = a.documento_id
                              where a.sha256 = lower(p_sha256) and d.situacao <> 'cancelado'), '[]'::jsonb));
end $$;

-- Grava o que o leitor tirou do arquivo (só antes da nota, só quem subiu).
create function api.gravar_leitura(p_anexo uuid, p_leitura jsonb) returns void
language plpgsql volatile security invoker set search_path = pg_catalog, pg_temp as $$
begin
  perform erp.exigir_editor();
  update erp.anexos set leitura = p_leitura where id = p_anexo;
  if not found then raise exception 'Anexo não encontrado'; end if;
end $$;

-- Os anexos que a pessoa subiu e ainda não ligou a nota nenhuma (para retomar um lançamento).
create function api.meus_anexos_soltos()
returns table (id uuid, nome text, tipo_mime text, tamanho bigint, leitura jsonb, criado_em timestamptz)
language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select a.id, a.nome, a.tipo_mime, a.tamanho, a.leitura, a.criado_em
    from erp.anexos a where a.documento_id is null and a.criado_por = erp.eu()
   order by a.criado_em desc limit 50 $$;

-- Um anexo que a pessoa vê (o serviço de leitura pergunta antes de entregar o arquivo). Nulo se não vê.
create function api.anexo(p_id uuid) returns jsonb language sql stable security invoker
set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object('id', a.id, 'nome', a.nome, 'tipo_mime', a.tipo_mime, 'tamanho', a.tamanho, 'sha256', a.sha256,
                            'documento_id', a.documento_id, 'criado_em', a.criado_em)
    from erp.anexos a where a.id = p_id $$;

-- ---------------------------------------------------------------------------------------------
-- api: o que casa com a nota lida
-- ---------------------------------------------------------------------------------------------
-- Pontos de um candidato (0 a 10): fornecedor certo 3 (previsão sem fornecedor, 1); valor a até 1% 4, a até 10% 2;
-- data a até 15 dias 3, a até 45 dias 1. A data da previsão é a prevista; a do contrato, o dia do vencimento no mês
-- do vencimento lido (sem dia, fica sem os pontos da data). O valor do contrato é o do período (assinatura) ou o
-- saldo (contrato e pedido). Volta só quem tem 4 pontos ou mais (o fornecedor sozinho não basta), os 10 melhores;
-- no empate, a previsão antes do contrato (ela é o mês certo do contrato).
create function erp.pontos_candidato(p_fornecedor_certo boolean, p_sem_fornecedor boolean, p_valor numeric,
                                     p_lido numeric, p_data date, p_lida date) returns int
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select (case when p_fornecedor_certo then 3 when p_sem_fornecedor then 1 else 0 end)
       + (case when p_valor is null or p_lido is null or p_lido <= 0 then 0
               when abs(p_valor - p_lido) <= p_lido * 0.01 then 4
               when abs(p_valor - p_lido) <= p_lido * 0.10 then 2 else 0 end)
       + (case when p_data is null or p_lida is null then 0
               when abs(p_data - p_lida) <= 15 then 3
               when abs(p_data - p_lida) <= 45 then 1 else 0 end) $$;

-- Corpo: { tomador: CNPJ/CPF, emitente: CNPJ/CPF, tipo?, numero?, serie?, valor?, emissao?, vencimento? }
-- (formatado ou não). Devolve:
-- { empresa: {id, nome, documento} | null, fornecedor: {id, nome, documento, fornecedor: bool} | null,
--   nota_repetida: [{documento_id, titulo_id, tipo, numero, serie, emissao, valor, situacao}],
--   candidatos: [{tipo: previsao|contrato, id, compromisso_id, compromisso_tipo, numero, descricao, valor, data,
--                 pontos, motivos: [texto], rateio: [{nucleo, centro, divisao (o último nível), natureza, percentual}]}],
--   pagamento: {forma, pix_tipo?, pix_chave?, de_titulo} | null }
create function api.identificar_nota(p jsonb) returns jsonb language plpgsql stable security invoker
set search_path = pg_catalog, pg_temp as $$
declare
  v_tom text := nullif(regexp_replace(coalesce(p->>'tomador', ''), '[^0-9]', '', 'g'), '');
  v_emi text := nullif(regexp_replace(coalesce(p->>'emitente', ''), '[^0-9]', '', 'g'), '');
  v_valor numeric := nullif(p->>'valor', '')::numeric;
  v_venc date := nullif(p->>'vencimento', '')::date;
  v_emissao date := nullif(p->>'emissao', '')::date;
  v_ref date;
  v_emp uuid; v_forn uuid;
  r jsonb := '{}'::jsonb;
begin
  if not erp.escrevo() then return null; end if;
  v_ref := coalesce(v_venc, v_emissao);

  select e.id into v_emp from erp.empresas e join erp.pessoas pe on pe.id = e.pessoa_id where pe.documento = v_tom and e.ativa;
  select pe.id into v_forn from erp.pessoas pe where pe.documento = v_emi and pe.ativa;

  r := r || jsonb_build_object(
    'empresa', (select jsonb_build_object('id', e.id, 'nome', pe.nome, 'documento', pe.documento)
                  from erp.empresas e join erp.pessoas pe on pe.id = e.pessoa_id where e.id = v_emp),
    'fornecedor', (select jsonb_build_object('id', pe.id, 'nome', pe.nome, 'documento', pe.documento,
                            'fornecedor', exists (select 1 from erp.pessoa_papeis pp where pp.pessoa_id = pe.id and pp.papel = 'fornecedor'))
                     from erp.pessoas pe where pe.id = v_forn),
    'nota_repetida', coalesce((select jsonb_agg(jsonb_build_object('documento_id', d.id, 'tipo', d.tipo, 'numero', d.numero,
                                 'serie', nullif(d.serie, ''), 'emissao', d.emissao, 'valor', d.valor_bruto, 'situacao', d.situacao,
                                 'titulo_id', (select t.id from erp.titulos t where t.documento_id = d.id and t.tipo = 'fornecedor'
                                                 and t.situacao <> 'cancelado' order by t.criado_em desc limit 1)))
                                 from erp.documentos_fiscais d
                                where v_forn is not null and d.emitente_id = v_forn and d.situacao <> 'cancelado'
                                  and ltrim(d.numero, '0') = ltrim(trim(coalesce(p->>'numero', '')), '0')
                                  and length(trim(coalesce(p->>'numero', ''))) > 0
                                  and (coalesce(p->>'tipo', '') = '' or d.tipo = p->>'tipo')), '[]'::jsonb));

  -- candidatos: previsões abertas e contratos ativos da empresa (ou de qualquer empresa, se ela não foi achada)
  r := r || jsonb_build_object('candidatos', coalesce((select jsonb_agg(c.j order by c.pontos desc, c.prev desc, c.data nulls last) from (
    select x.pontos, x.data, x.tipo = 'previsao' as prev, jsonb_build_object('tipo', x.tipo, 'id', x.id, 'compromisso_id', x.compromisso_id,
             'compromisso_tipo', x.compromisso_tipo, 'numero', x.numero, 'descricao', x.descricao, 'valor', x.valor,
             'data', x.data, 'empresa_id', x.empresa_id, 'pontos', x.pontos, 'motivos', x.motivos, 'rateio', x.rateio) as j
      from (
        -- previsão aberta com saldo
        select 'previsao' as tipo, v.id, v.compromisso_id, (select c.tipo from erp.compromissos c where c.id = v.compromisso_id) as compromisso_tipo,
               (select c.numero from erp.compromissos c where c.id = v.compromisso_id) as numero,
               coalesce(v.descricao, (select vn.caminho from erp.v_naturezas vn where vn.id = v.natureza_id)) as descricao,
               v.saldo as valor, v.data_prevista as data, v.empresa_id,
               erp.pontos_candidato(v.pessoa_id = v_forn, v.pessoa_id is null, v.saldo, v_valor, v.data_prevista, v_ref) as pontos,
               to_jsonb(array_remove(array[
                 case when v.pessoa_id = v_forn then 'mesmo fornecedor' when v.pessoa_id is null then 'previsão sem fornecedor' end,
                 case when v_valor > 0 and abs(v.saldo - v_valor) <= v_valor * 0.01 then 'mesmo valor'
                      when v_valor > 0 and abs(v.saldo - v_valor) <= v_valor * 0.10 then 'valor próximo' end,
                 case when v_ref is not null and abs(v.data_prevista - v_ref) <= 15 then 'data próxima' end], null)) as motivos,
               jsonb_build_array(jsonb_build_object('nucleo', v.nucleo_economico_id, 'centro', v.centro_custo_id,
                                   'divisao', coalesce(v.subdivisao_id, v.divisao_id), 'natureza', v.natureza_id, 'percentual', 100)) as rateio
          from erp.v_previsoes v
         where v.situacao = 'aberta' and v.sentido = 'pagar' and v.saldo > 0
           and (v_emp is null or v.empresa_id = v_emp)
           and (v.pessoa_id is null or v.pessoa_id = v_forn)
        union all
        -- contrato ativo do fornecedor
        select 'contrato', c.id, c.id, c.tipo, c.numero, c.descricao, x.valor, x.data, c.empresa_id,
               erp.pontos_candidato(true, false, x.valor, v_valor, x.data, v_ref),
               to_jsonb(array_remove(array['mesmo fornecedor',
                 case when v_valor > 0 and abs(x.valor - v_valor) <= v_valor * 0.01 then 'mesmo valor'
                      when v_valor > 0 and abs(x.valor - v_valor) <= v_valor * 0.10 then 'valor próximo' end,
                 case when v_ref is not null and x.data is not null and abs(x.data - v_ref) <= 15 then 'vencimento do contrato' end], null)),
               coalesce((select jsonb_agg(jsonb_build_object('nucleo', cr.nucleo_economico_id, 'centro', cr.centro_custo_id,
                                  'divisao', coalesce(cr.subdivisao_id, cr.divisao_id), 'natureza', cr.natureza_id,
                                  'percentual', cr.percentual) order by cr.percentual desc)
                           from erp.compromisso_rateios cr where cr.compromisso_id = c.id), '[]'::jsonb)
          from erp.compromissos c
          cross join lateral (select case when c.tipo = 'assinatura' then c.valor_periodo
                                          else c.valor_total - coalesce((select sum(t.valor) from erp.titulos t
                                                                          where t.compromisso_id = c.id and t.situacao <> 'cancelado'), 0) end as valor,
                                     case when c.dia_vencimento is not null and v_ref is not null
                                          then least(date_trunc('month', v_ref)::date + (c.dia_vencimento - 1),
                                                     (date_trunc('month', v_ref) + interval '1 month - 1 day')::date) end as data) x
         where v_forn is not null and c.pessoa_id = v_forn and c.situacao = 'ativo'
           and (v_emp is null or c.empresa_id = v_emp)
           and (c.fim is null or v_ref is null or c.fim >= v_ref - 60)
      ) x where x.pontos >= 4
     order by x.pontos desc, x.tipo = 'previsao' desc, x.data nulls last limit 10) c), '[]'::jsonb));

  -- a última forma de pagamento usada com o fornecedor, num título que a pessoa vê (a chave PIX se repete; a linha
  -- do boleto, não: do boleto volta só a forma)
  r := r || jsonb_build_object('pagamento', (
    select jsonb_build_object('forma', g.forma, 'pix_tipo', g.pix_tipo, 'pix_chave', g.pix_chave, 'de_titulo', t.id)
      from erp.parcela_pagamentos g join erp.titulos t on t.id = g.titulo_id
     where v_forn is not null and t.pessoa_id = v_forn and t.sentido = 'pagar' and t.situacao <> 'cancelado'
     order by t.criado_em desc, g.numero desc limit 1));
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------
-- api.lancar_titulo: liga os anexos à nota ("anexos": [uuid], os que a pessoa subiu e ainda estão soltos)
-- ---------------------------------------------------------------------------------------------
create function erp._ligar_anexos(p_documento uuid, p_anexos jsonb) returns void language plpgsql
set search_path = pg_catalog, pg_temp as $$
declare v_ids uuid[]; v_n int;
begin
  select array_agg(distinct x::uuid) into v_ids from jsonb_array_elements_text(coalesce(p_anexos, '[]'::jsonb)) x;
  if v_ids is null then return; end if;
  update erp.anexos set documento_id = p_documento where id = any(v_ids) and documento_id is null and criado_por = erp.eu();
  get diagnostics v_n = row_count;
  if v_n <> cardinality(v_ids) then raise exception 'Anexo não encontrado ou já ligado a outra nota'; end if;
end $$;

do $$
declare v_def text; v_novo text;
begin
  -- lancar_titulo: depois das etiquetas, liga os anexos
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def, E'  return v_tit;\nend',
                    E'  perform erp._ligar_anexos(v_doc, p->''anexos'');\n\n  return v_tit;\nend');
  if v_novo = v_def then raise exception 'api.lancar_titulo: ponto de troca não achado'; end if;
  execute v_novo;
  -- titulo_rastro: a lista dos anexos da nota do título (só se a pessoa vê o anexo)
  v_def := pg_get_functiondef('api.titulo_rastro(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$'anexos', '[]'::jsonb,$r$,
    $r$'anexos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'nome', a.nome, 'tipo_mime', a.tipo_mime,
                              'tamanho', a.tamanho, 'enviado_por', (select n.nome from nome n where n.id = a.criado_por),
                              'enviado_em', a.criado_em) order by a.criado_em)
                            from erp.anexos a where t.documento_id is not null and a.documento_id = t.documento_id), '[]'::jsonb),$r$);
  if v_novo = v_def then raise exception 'api.titulo_rastro: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Segurança: só o usuário logado executa as da api; as do erp seguem a regra do esquema
-- ---------------------------------------------------------------------------------------------
revoke execute on function erp.tg_anexo(), erp._ligar_anexos(uuid, jsonb), erp.pontos_candidato(boolean, boolean, numeric, numeric, date, date) from public;
grant execute on function erp.tg_anexo(), erp._ligar_anexos(uuid, jsonb), erp.pontos_candidato(boolean, boolean, numeric, numeric, date, date)
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
grant execute on function erp._ligar_anexos(uuid, jsonb), erp.pontos_candidato(boolean, boolean, numeric, numeric, date, date) to authenticated;
do $$
declare f regprocedure;
begin
  foreach f in array array['api.registrar_anexo(text, text, bigint, text)', 'api.gravar_leitura(uuid, jsonb)',
                           'api.meus_anexos_soltos()', 'api.anexo(uuid)', 'api.identificar_nota(jsonb)']::regprocedure[] loop
    execute format('revoke execute on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
    if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
