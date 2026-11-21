-- PR #113: aviso quando o CNPJ lido na guia não é o do dono do código. Rodar DEPOIS do bkm_dev_guias_2026-11-20.sql.
begin;
grant erp_conferencia to current_user with inherit false, set true;
grant create on schema erp to erp_conferencia;
set local role erp_conferencia;
create or replace function erp.completar_recebedor(p_leitura jsonb) returns jsonb
language plpgsql stable security definer set search_path = pg_catalog, pg_temp as $$
declare b jsonb; c text[]; r erp.recebedores_arrecadacao; v_doc text; v_avisos jsonb;
begin
  if p_leitura is null then return p_leitura; end if;
  v_doc := regexp_replace(coalesce(p_leitura->'emitente'->>'documento', ''), '\D', '', 'g');
  v_avisos := coalesce(case when jsonb_typeof(p_leitura->'avisos') = 'array' then p_leitura->'avisos' end, '[]');
  for b in select * from jsonb_array_elements(case when jsonb_typeof(p_leitura->'boletos') = 'array'
                                                   then p_leitura->'boletos' else '[]' end) loop
    c := erp.codigo_arrecadacao(b->>'linha');
    if c is null then continue; end if;
    select * into r from erp.recebedores_arrecadacao where segmento = c[1] and codigo = c[2];
    if r.cpf_cnpj is null then continue; end if;
    if v_doc = '' then
      return jsonb_set(jsonb_set(p_leitura, '{emitente}',
               coalesce(p_leitura->'emitente', '{}') || jsonb_build_object('documento', r.cpf_cnpj,
                 'nome', coalesce(nullif(p_leitura->'emitente'->>'nome', ''), r.nome))),
             '{avisos}', v_avisos || to_jsonb('CNPJ do emitente pelo código do recebedor na linha da guia (' || r.nome || ')'));
    end if;
    if left(v_doc, 8) <> left(r.cpf_cnpj, 8) then
      return jsonb_set(p_leitura, '{avisos}', v_avisos
        || to_jsonb('O código do recebedor na linha da guia é de ' || r.nome || ', e não do CNPJ do emitente lido. Confira a guia antes de pagar'));
    end if;
    return p_leitura;
  end loop;
  return p_leitura;
end $$;
do $$ begin
  if coalesce(erp.completar_recebedor('{"emitente":{"documento":"11222333000181"},"boletos":[{"linha":"826700000068278700970918102694590609329178721737"}]}')->'avisos'->>0, '')
     not like 'O código do recebedor%' then raise exception 'Conferência: não avisou a divergência'; end if;
end $$;
reset role;
revoke create on schema erp from erp_conferencia;
revoke erp_conferencia from current_user;
commit;

-- Conferência: as 2 linhas devem dar true (o aviso já foi conferido antes do commit)
select pg_get_userbyid(p.proowner) = 'erp_conferencia' and p.prosecdef as dono_definer
  from pg_proc p where p.oid = 'erp.completar_recebedor(jsonb)'::regprocedure;
select not has_schema_privilege('erp_conferencia', 'erp', 'create') as sem_create;
-- Desfazer: rodar de novo a função do bkm_dev_guias_2026-11-20.sql (create or replace, com o mesmo set role).
