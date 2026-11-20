-- PIX copia e cola de cada parcela (pedido do Moises, 20/nov/2026: "Quero que inclua, mas não pro Sienge, pro nosso
-- sistema"; teste do leitor com os 10 boletos do Itaú, cada um com o QR Code PIX dele). O código fica na forma de
-- pagamento da parcela, ao lado da linha do boleto, com a mesma proteção dela (RLS de parcela_pagamentos e a trava
-- depois do primeiro voto). Não vai ao Sienge: o envio continua só com a chave ou a linha.
--
-- Conferências no banco, como na linha do boleto:
--   - o formato do BR Code (EMV): começa por 000201, campos id+tamanho+valor até o fim, termina no CRC (6304 + 4
--     hexadecimais) e o CRC16-CCITT confere;
--   - quando o código traz o valor (campo 54), ele é o da parcela. Sem valor (código que deixa o pagador digitar), passa.

-- CRC16-CCITT (polinômio 0x1021, começo 0xFFFF) dos bytes do texto, como o BR Code pede
create function erp._crc16_pix(p text) returns int language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare b bytea := convert_to(p, 'UTF8'); c int := 65535; i int; k int;
begin
  for i in 0 .. length(b) - 1 loop
    c := c # (get_byte(b, i) << 8);
    for k in 1 .. 8 loop
      if (c & 32768) <> 0 then c := ((c << 1) # 4129) & 65535; else c := (c << 1) & 65535; end if;
    end loop;
  end loop;
  return c;
end $$;

create function erp.pix_copia_cola_valido(p text) returns boolean language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare pos int := 1; n int; id text;
begin
  if p is null or length(p) < 30 or length(p) > 512 or p !~ '^000201' or p !~ '6304[0-9A-F]{4}$' or p ~ '[^ -~]' then
    return false;
  end if;
  -- os campos id(2) + tamanho(2) + valor cobrem o código inteiro, e o último é o CRC
  while pos <= length(p) loop
    id := substr(p, pos, 2);
    if substr(p, pos + 2, 2) !~ '^[0-9]{2}$' then return false; end if;
    n := substr(p, pos + 2, 2)::int;
    if pos + 4 + n - 1 > length(p) then return false; end if;
    if id = '63' then
      return n = 4 and pos + 8 = length(p) + 1
         and upper(lpad(to_hex(erp._crc16_pix(substr(p, 1, length(p) - 4))), 4, '0')) = right(p, 4);
    end if;
    pos := pos + 4 + n;
  end loop;
  return false;
end $$;

-- O valor do código (campo 54), ou nulo quando ele não traz valor
create function erp.pix_copia_cola_valor(p text) returns numeric language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare pos int := 1; n int;
begin
  if not erp.pix_copia_cola_valido(p) then return null; end if;
  while pos <= length(p) loop
    n := substr(p, pos + 2, 2)::int;
    if substr(p, pos, 2) = '54' then
      return case when substr(p, pos + 4, n) ~ '^[0-9]{1,10}(\.[0-9]{1,2})?$' then substr(p, pos + 4, n)::numeric end;
    end if;
    pos := pos + 4 + n;
  end loop;
  return null;
end $$;

alter table erp.parcela_pagamentos add column pix_copia_cola text
  check (pix_copia_cola is null or erp.pix_copia_cola_valido(pix_copia_cola));

-- O valor do código é o da parcela (na gravação; a trava de depois do primeiro voto continua a do t_parcela_pagamento)
create function erp.tg_parcela_pix_copia_cola() returns trigger language plpgsql as $$
declare v_pix numeric; v_parcela numeric;
begin
  if new.pix_copia_cola is null then return new; end if;
  v_pix := erp.pix_copia_cola_valor(new.pix_copia_cola);
  if v_pix is not null then
    select valor into v_parcela from erp.parcelas where titulo_id = new.titulo_id and numero = new.numero;
    if v_pix is distinct from v_parcela then
      raise exception 'O valor do PIX copia e cola (%) não é o da parcela % (%)', v_pix, new.numero, v_parcela;
    end if;
  end if;
  return new;
end $$;
create trigger t_parcela_pix_copia_cola before insert or update of pix_copia_cola on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_pix_copia_cola();

revoke execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
  erp.tg_parcela_pix_copia_cola() from public;
grant execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;

-- api.lancar_titulo: "pix_copia_cola" em cada parcela (opcional, com PIX ou boleto). Trocada no lugar, a partir da
-- definição atual, como nas migrations dos anexos e das parcelas.
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def,
    'insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao)',
    'insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao, pix_copia_cola)');
  v_novo := replace(v_novo,
    $r$nullif(trim(l->>'pix_excecao'), ''));$r$,
    $r$nullif(trim(l->>'pix_excecao'), ''),
            nullif(regexp_replace(coalesce(l->>'pix_copia_cola', ''), '^\s+|\s+$', '', 'g'), ''));$r$);
  if position('pix_excecao, pix_copia_cola)' in v_novo) = 0 or position($r$l->>'pix_copia_cola'$r$ in v_novo) = 0 then
    raise exception 'api.lancar_titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;

-- api.titulo: a parcela mostra o código (para quem vê a forma de pagamento, como a linha do boleto)
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.titulo(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$'pix_excecao', f.pix_excecao)$r$, $r$'pix_excecao', f.pix_excecao, 'pix_copia_cola', f.pix_copia_cola)$r$);
  if v_novo = v_def then raise exception 'api.titulo: ponto de troca não achado'; end if;
  execute v_novo;
end $$;
