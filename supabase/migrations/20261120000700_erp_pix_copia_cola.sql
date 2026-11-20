-- PIX copia e cola de cada parcela (pedido do Moises, 20/nov/2026: "Quero que inclua, mas não pro Sienge, pro nosso
-- sistema"; teste do leitor com os 10 boletos do Itaú, cada um com o QR Code PIX dele). O código fica na forma de
-- pagamento da parcela, ao lado da linha do boleto, com a mesma proteção dela (RLS de parcela_pagamentos e a trava
-- depois do primeiro voto). Não vai ao Sienge: o envio continua só com a chave ou a linha.
--
-- Conferências no banco, como na linha do boleto:
--   - o formato do BR Code (EMV): começa por 000201, campos id+tamanho+valor até o fim, termina no CRC (6304 + 4
--     hexadecimais) e o CRC16-CCITT confere;
--   - quando o código traz o valor (campo 54), ele é o da parcela. Sem valor (código que deixa o pagador digitar), passa;
--   - o recebedor (revisão de segurança, 20/nov/2026): o código leva dentro dele quem recebe, e o valor bater não protege
--     nada (quem frauda põe o valor certo). Por isso, como no S-125 da chave: código estático (campo 26, subcampo 01 =
--     chave) entra quando a chave é a da parcela (forma PIX) ou o CPF/CNPJ do credor (forma boleto); código dinâmico
--     (subcampo 25 = URL, o recebedor só o banco dele sabe) ou com a chave de outro só entra com a justificativa da
--     exceção (pix_copia_cola_excecao), que o título mostra a quem aprova e que gera o alerta crítico
--     pix_copia_cola_excecao para o AF quando o título vai à fila do Sienge. Código sem o recebedor PIX é recusado.
--   - a conferência roda na gravação da forma. Se o valor da parcela mudar depois, o gatilho não confere de novo: hoje
--     a parcela só muda no relançamento, que recria a forma de pagamento.

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

-- O valor do campo `id` de uma lista TLV (o código inteiro ou o valor de um campo com subcampos), ou nulo
create function erp._pix_campo(p text, p_id text) returns text language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare pos int := 1; n int;
begin
  while pos + 3 <= length(p) loop
    if substr(p, pos + 2, 2) !~ '^[0-9]{2}$' then return null; end if;
    n := substr(p, pos + 2, 2)::int;
    if substr(p, pos, 2) = p_id then return substr(p, pos + 4, n); end if;
    pos := pos + 4 + n;
  end loop;
  return null;
end $$;

-- Quem recebe pelo código: {chave, url, nome}. A conta do recebedor é o campo de 26 a 51 com o GUI br.gov.bcb.pix
-- (subcampo 00); a chave é o subcampo 01 (código estático), a URL o 25 (dinâmico); o nome, o campo 59. Nulo quando
-- o código não vale ou não traz conta PIX.
create function erp.pix_copia_cola_recebedor(p text) returns jsonb language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare i int; v text; c text;
begin
  if not erp.pix_copia_cola_valido(p) then return null; end if;
  for i in 26 .. 51 loop
    v := erp._pix_campo(p, i::text);
    if v is not null and lower(coalesce(erp._pix_campo(v, '00'), '')) = 'br.gov.bcb.pix' then
      c := nullif(trim(erp._pix_campo(v, '01')), '');
      -- a chave como o banco guarda a da parcela: e-mail e aleatória em minúsculas
      if c ~ '@' or c ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then c := lower(c); end if;
      return jsonb_build_object('chave', c, 'url', nullif(trim(erp._pix_campo(v, '25')), ''),
                                'nome', nullif(trim(erp._pix_campo(p, '59')), ''));
    end if;
  end loop;
  return null;
end $$;

alter table erp.parcela_pagamentos add column pix_copia_cola text
  check (pix_copia_cola is null or erp.pix_copia_cola_valido(pix_copia_cola));
alter table erp.parcela_pagamentos add column pix_copia_cola_excecao text   -- justificativa do recebedor não conferido
  check (pix_copia_cola_excecao is null or (pix_copia_cola is not null and length(trim(pix_copia_cola_excecao)) > 0));

-- O valor do código é o da parcela e o recebedor é o da parcela ou do credor, ou vem a justificativa (na gravação;
-- a trava de depois do primeiro voto continua a do t_parcela_pagamento). Lê o credor por baixo do RLS, como o
-- t_parcela_pagamento (o mesmo dono).
create function erp.tg_parcela_pix_copia_cola() returns trigger language plpgsql as $$
declare v_pix numeric; v_parcela numeric; r jsonb; v_doc text;
begin
  if new.pix_copia_cola is null then new.pix_copia_cola_excecao := null; return new; end if;
  v_pix := erp.pix_copia_cola_valor(new.pix_copia_cola);
  if v_pix is not null then
    select valor into v_parcela from erp.parcelas where titulo_id = new.titulo_id and numero = new.numero;
    if v_pix is distinct from v_parcela then
      raise exception 'O valor do PIX copia e cola (%) não é o da parcela % (%)', v_pix, new.numero, v_parcela;
    end if;
  end if;
  r := erp.pix_copia_cola_recebedor(new.pix_copia_cola);
  if r is null or (r->>'chave' is null and r->>'url' is null) then
    raise exception 'O PIX copia e cola da parcela % não traz o recebedor PIX', new.numero;
  end if;
  select p.documento into v_doc from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = new.titulo_id;
  if r->>'chave' is not null and ((new.forma = 'pix' and r->>'chave' = new.pix_chave)
                                  or (new.forma = 'boleto' and r->>'chave' = v_doc)) then
    new.pix_copia_cola_excecao := null;   -- recebedor conferido: a exceção some
    return new;
  end if;
  if length(trim(coalesce(new.pix_copia_cola_excecao, ''))) = 0 then
    if r->>'chave' is not null then
      raise exception 'A chave do PIX copia e cola da parcela % não é a % (só com a justificativa da exceção)', new.numero,
        case when new.forma = 'pix' then 'chave PIX da parcela' else 'do CPF/CNPJ do credor' end;
    end if;
    raise exception 'O PIX copia e cola da parcela % é dinâmico e o recebedor não se confere (só com a justificativa da exceção)', new.numero;
  end if;
  return new;
end $$;
create trigger t_parcela_pix_copia_cola before insert or update on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_pix_copia_cola();

revoke execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
  erp._pix_campo(text, text), erp.pix_copia_cola_recebedor(text), erp.tg_parcela_pix_copia_cola() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
      erp._pix_campo(text, text), erp.pix_copia_cola_recebedor(text), erp.tg_parcela_pix_copia_cola() from anon;
  end if;
end $$;
grant execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
  erp._pix_campo(text, text), erp.pix_copia_cola_recebedor(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.tg_parcela_pix_copia_cola()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
-- o gatilho é do mesmo dono do t_parcela_pagamento (o novo dono precisa de CREATE no esquema para receber a função:
-- dado só aqui e tirado logo depois, se ele não tinha; no Supabase o postgres não é superusuário)
alter function erp.tg_parcela_pix_copia_cola() security definer set search_path = erp, pg_catalog, pg_temp;
create temp table _pixcc_create_dado as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _pixcc_create_dado loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.tg_parcela_pix_copia_cola() owner to erp_conferencia;
do $$ declare v text; begin
  for v in select r from _pixcc_create_dado loop execute format('revoke create on schema erp from %I', v); end loop;
end $$;
drop table _pixcc_create_dado;

-- O alerta crítico da exceção: quando o título vai à fila do Sienge, como o chave_pix_nova, para o AF olhar antes de
-- o financeiro pagar
insert into erp.tipos_evento (codigo, rotulo, modulo, critico) values
  ('pix_copia_cola_excecao', 'Título vai ao Sienge com PIX copia e cola de recebedor não conferido', 'pagar', true);
insert into erp.regras_notificacao (tipo, destino, lista) values ('pix_copia_cola_excecao', 'lista', 'AF');
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('erp.sienge_enfileirar()'::regprocedure);
  v_novo := replace(v_def, $r$    n := n + 1;
$r$, $r$    n := n + 1;
    if exists (select 1 from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null) then
      perform erp.registrar_evento('pix_copia_cola_excecao', 'titulos', r.titulo_id::text, r.onde[1], r.onde[2],
        jsonb_build_object('titulo_id', r.titulo_id, 'pessoa_id', r.pessoa_id,
          'parcelas', (select jsonb_agg(jsonb_build_object('numero', g.numero, 'recebedor', erp.pix_copia_cola_recebedor(g.pix_copia_cola),
                                                           'justificativa', g.pix_copia_cola_excecao) order by g.numero)
                         from erp.parcela_pagamentos g where g.titulo_id = r.titulo_id and g.pix_copia_cola_excecao is not null),
          'motivo', 'PIX copia e cola com recebedor não conferido'));
    end if;
$r$);
  if v_novo = v_def then raise exception 'erp.sienge_enfileirar: ponto de troca não achado'; end if;
  execute v_novo;
end $$;

-- api.lancar_titulo: "pix_copia_cola" em cada parcela (opcional, com PIX ou boleto). Trocada no lugar, a partir da
-- definição atual, como nas migrations dos anexos e das parcelas.
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.lancar_titulo(jsonb)'::regprocedure);
  v_novo := replace(v_def,
    'insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao)',
    'insert into erp.parcela_pagamentos (titulo_id, numero, forma, pix_tipo, pix_chave, boleto_linha, pix_excecao, pix_copia_cola, pix_copia_cola_excecao)');
  v_novo := replace(v_novo,
    $r$nullif(trim(l->>'pix_excecao'), ''));$r$,
    $r$nullif(trim(l->>'pix_excecao'), ''),
            nullif(regexp_replace(coalesce(l->>'pix_copia_cola', ''), '^\s+|\s+$', '', 'g'), ''),
            nullif(trim(l->>'pix_copia_cola_excecao'), ''));$r$);
  if position('pix_copia_cola, pix_copia_cola_excecao)' in v_novo) = 0 or position($r$l->>'pix_copia_cola_excecao'$r$ in v_novo) = 0 then
    raise exception 'api.lancar_titulo: ponto de troca não achado';
  end if;
  execute v_novo;
end $$;

-- api.titulo: a parcela mostra o código, o recebedor dele e a justificativa (para quem vê a forma de pagamento, como a
-- linha do boleto; é a tela de quem aprova)
do $$
declare v_def text; v_novo text;
begin
  v_def := pg_get_functiondef('api.titulo(uuid)'::regprocedure);
  v_novo := replace(v_def, $r$'pix_excecao', f.pix_excecao)$r$, $r$'pix_excecao', f.pix_excecao, 'pix_copia_cola', f.pix_copia_cola,
                   'pix_copia_cola_recebedor', erp.pix_copia_cola_recebedor(f.pix_copia_cola), 'pix_copia_cola_excecao', f.pix_copia_cola_excecao)$r$);
  if v_novo = v_def then raise exception 'api.titulo: ponto de troca não achado'; end if;
  execute v_novo;
end $$;
