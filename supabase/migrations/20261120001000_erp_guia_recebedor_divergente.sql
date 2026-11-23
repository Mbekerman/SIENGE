-- Guia com CNPJ do emitente diferente do dono do código de arrecadação (revisão de segurança do #112, 20/nov/2026).
-- Na guia, quem recebe é o dono do código do recebedor na linha, não o CNPJ impresso. Se a leitura trouxe um CNPJ e o
-- código está em erp.recebedores_arrecadacao com outra raiz (8 primeiros dígitos), a leitura ganha um aviso. O CNPJ
-- lido fica como veio: o aviso é para quem confere, não troca nada. Mesma raiz (outra filial do órgão) não avisa.

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
