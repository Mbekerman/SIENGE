-- bkm_dev, 24/nov/2026: número do documento e trava de duplicidade (migration 20261124001000). Colar inteiro no SQL Editor.
-- Se já foi aplicado, para logo no começo com o aviso e nada muda. Se já houver documentos repetidos pela regra nova,
-- para e lista quais são (nada muda; resolver cancelando o repetido e colar de novo).
begin;
do $$ begin
  if to_regprocedure('erp.numero_documento_chave(text)') is not null then
    raise exception 'Este SQL já foi aplicado no bkm_dev (erp.numero_documento_chave existe). Nada foi alterado.';
  end if;
end $$;
do $$ declare v text; begin
  select string_agg(format('emitente %s, %s nº %s (%s documentos)', emitente_id, tipo, chave, n), '; ') into v
    from (select emitente_id, tipo,
                 coalesce(nullif(ltrim(sx, '0'), ''), '') as serie,
                 case when x in ('', 'SN', 'SNO', 'SNUM', 'SEMNUMERO', 'SEMNUM') then null else coalesce(nullif(ltrim(x, '0'), ''), '0') end as chave, count(*) as n
            from (select *, upper(regexp_replace(coalesce(numero, ''), '[^0-9A-Za-z]', '', 'g')) as x,
                         upper(regexp_replace(coalesce(serie, ''), '[^0-9A-Za-z]', '', 'g')) as sx
                    from erp.documentos_fiscais where situacao <> 'cancelado') d
           where x not in ('', 'SN', 'SNO', 'SNUM', 'SEMNUMERO', 'SEMNUM')
           group by 1, 2, 3, 4 having count(*) > 1) r;
  if v is not null then raise exception 'Há documentos repetidos pela regra nova; nada foi alterado: %', v; end if;
  select string_agg(format('documento %s (%s nº "%s")', id, tipo, numero), '; ') into v from erp.documentos_fiscais
   where tipo in ('nfe', 'nfse') and upper(regexp_replace(numero, '[^0-9A-Za-z]', '', 'g')) in ('', 'SN', 'SNO', 'SNUM', 'SEMNUMERO', 'SEMNUM');
  if v is not null then raise exception 'Há notas sem número; nada foi alterado: %', v; end if;
end $$;

-- Número do título = número do documento (Moises, 24/nov/2026, depois da conferência por amostra do leitor): quando o
-- arquivo não é nota (boleto, fatura, guia, IPTU), o número é o que o documento traz, nunca um rótulo nosso; o formato
-- "credor.número" foi descartado. Fornecedor, tipo e número continuam em campos separados.
-- Trava de duplicidade: já existia (documentos_fiscais_unico: emitente + tipo + número + série, fora as canceladas), mas
-- comparava o texto como digitado, e "00029" e "29", ou "1303890-1/" e "1303890-1", passavam como números diferentes.
-- Agora compara a chave do número: maiúsculas, só letras e dígitos, sem zeros à esquerda. Repetido é RECUSADO (não vai
-- a aprovação): o mesmo documento lançado duas vezes é pagamento em dobro, e a nota cancelada (inclusive a recusada na
-- alçada) continua liberando o número para a versão certa. A série passa pela mesma chave ("1" = "001"; sem série = "0").
-- Documento sem número (em branco, "-/", "s/n", "sem número") fica FORA da trava: a chave é nula (decisão do Moises,
-- 24/nov/2026, porque recibo sem número é comum; a segurança preferia abrir só com aprovação). NF-e e NFS-e sem número
-- são recusadas, e o identificar_nota avisa o sem número com o mesmo emitente, tipo, valor e emissão. O aviso "esta nota já foi lançada" da tela usa a mesma chave.

create function erp.numero_documento_chave(p text) returns text language sql immutable
set search_path = pg_catalog, pg_temp as $$
  select case when x in ('', 'SN', 'SNO', 'SNUM', 'SEMNUMERO', 'SEMNUM') then null else coalesce(nullif(ltrim(x, '0'), ''), '0') end
    from (select upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')) as x) s $$;

drop index erp.documentos_fiscais_unico;
-- NF-e e NFS-e sempre têm número: "s/n" nelas seria a porta de saída da trava (revisão da segurança, 24/nov/2026)
alter table erp.documentos_fiscais add constraint documentos_fiscais_nota_com_numero
  check (tipo not in ('nfe', 'nfse') or erp.numero_documento_chave(numero) is not null);
create unique index documentos_fiscais_unico on erp.documentos_fiscais
  (emitente_id, tipo, erp.numero_documento_chave(numero), coalesce(nullif(erp.numero_documento_chave(serie), '0'), ''))
  where situacao <> 'cancelado';

do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure);
  -- com número, pela chave; sem número (só recibo, fatura, boleto...), o mesmo valor e a mesma emissão (só aviso).
  -- Cada troca é de uma linha só: colado no SQL Editor pelo Windows, o texto vem com CRLF e um trecho de duas linhas
  -- não casaria com o corpo da função (24/nov/2026).
  if (length(v_def) - length(replace(v_def, $r$ltrim(d.numero, '0') = ltrim(trim(coalesce(p->>'numero', '')), '0')$r$, ''))) <> length($r$ltrim(d.numero, '0') = ltrim(trim(coalesce(p->>'numero', '')), '0')$r$)
     or (length(v_def) - length(replace(v_def, $r$and length(trim(coalesce(p->>'numero', ''))) > 0$r$, ''))) <> length($r$and length(trim(coalesce(p->>'numero', ''))) > 0$r$) then
    raise exception 'api.identificar_nota: ponto de troca não achado (ou achado mais de uma vez)';
  end if;
  v_novo := replace(v_def, $r$ltrim(d.numero, '0') = ltrim(trim(coalesce(p->>'numero', '')), '0')$r$,
    $r$(erp.numero_documento_chave(d.numero) = erp.numero_documento_chave(p->>'numero') or (erp.numero_documento_chave(p->>'numero') is null and erp.numero_documento_chave(d.numero) is null and v_valor is not null and v_emissao is not null and d.valor_bruto = v_valor and d.emissao = v_emissao))$r$);
  v_novo := replace(v_novo, $r$and length(trim(coalesce(p->>'numero', ''))) > 0$r$, $r$and true$r$);
  execute v_novo;
end $$;

revoke execute on function erp.numero_documento_chave(text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke execute on function erp.numero_documento_chave(text) from anon; end if;
end $$;
grant execute on function erp.numero_documento_chave(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- Conferências antes do commit
do $$ begin
  if not (erp.numero_documento_chave('00029') = '29' and erp.numero_documento_chave('1303890-1/') = '13038901'
          and erp.numero_documento_chave('bkm-0001') = 'BKM0001' and erp.numero_documento_chave('000') = '0'
          and erp.numero_documento_chave('s/n') is null) then
    raise exception 'Conferência: a chave do número';
  end if;
  if pg_get_indexdef('erp.documentos_fiscais_unico'::regclass) not like '%numero_documento_chave(serie)%'
     or not exists (select 1 from pg_constraint where conname = 'documentos_fiscais_nota_com_numero') then
    raise exception 'Conferência: o índice documentos_fiscais_unico';
  end if;
  if pg_get_functiondef('api.identificar_nota(jsonb)'::regprocedure) not like '%numero_documento_chave%' then
    raise exception 'Conferência: api.identificar_nota';
  end if;
end $$;
commit;

-- Depois do commit (devem dar true)
select has_function_privilege('authenticated', 'erp.numero_documento_chave(text)', 'EXECUTE') as chave_na_api,
       not has_function_privilege('anon', 'erp.numero_documento_chave(text)', 'EXECUTE') as fora_do_anon;

-- Para desfazer: recriar o índice documentos_fiscais_unico sobre (emitente_id, tipo, numero, serie) como na migration
-- 20261107000200, trocar no api.identificar_nota a chave de volta pelo ltrim(d.numero, '0') e apagar a função.
