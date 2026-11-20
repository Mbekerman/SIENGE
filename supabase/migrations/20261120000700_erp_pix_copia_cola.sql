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
--     pix_copia_cola_excecao para o AF quando o título vai à fila do Sienge. Código sem o recebedor PIX é recusado, e
--     o com mais de uma conta PIX também (o app do banco pode escolher a outra). Código com URL é dinâmico mesmo que
--     traga uma chave: quem paga paga a quem a URL indicar (segunda revisão, 20/nov/2026);
--   - a conferência pelo Asaas (Moises, 20/nov/2026): a função pix-conferir (Edge Function, papel do sistema) pergunta
--     ao Asaas quem recebe pelo código (POST /v3/pix/qrCodes/decode, receiver.cpfCnpj) e grava em
--     erp.pix_conferencias; quando o documento de quem recebe é o do credor, a justificativa não é pedida, também no
--     código dinâmico. Só o sistema grava a conferência: a tela não consegue dizer que conferiu;
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

-- Uma lista TLV bem formada (id de 2 dígitos, tamanho de 2, o valor) que cobre o texto inteiro sem repetir id
create function erp._tlv_ids_unicos(p text) returns boolean language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare pos int := 1; n int; vistos text[] := '{}';
begin
  while pos <= length(p) loop
    if substr(p, pos, 4) !~ '^[0-9]{4}$' then return false; end if;
    n := substr(p, pos + 2, 2)::int;
    if pos + 4 + n - 1 > length(p) or substr(p, pos, 2) = any(vistos) then return false; end if;
    vistos := vistos || substr(p, pos, 2);
    pos := pos + 4 + n;
  end loop;
  return true;
end $$;

-- Revisão do #106: campo repetido é recusado, no código e dentro da conta PIX (quem lê pegaria um, o banco outro)
create function erp.pix_copia_cola_valido(p text) returns boolean language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare pos int := 1; n int; id text; vistos text[] := '{}';
begin
  if p is null or length(p) < 30 or length(p) > 512 or p !~ '^000201' or p !~ '6304[0-9A-F]{4}$' or p ~ '[^ -~]' then
    return false;
  end if;
  -- os campos id(2) + tamanho(2) + valor cobrem o código inteiro, e o último é o CRC
  while pos <= length(p) loop
    id := substr(p, pos, 2);
    if substr(p, pos + 2, 2) !~ '^[0-9]{2}$' then return false; end if;
    n := substr(p, pos + 2, 2)::int;
    if pos + 4 + n - 1 > length(p) or id = any(vistos) then return false; end if;
    vistos := vistos || id;
    if id between '26' and '51' and substr(p, pos + 4, n) ~* 'br\.gov\.bcb\.pix' and not erp._tlv_ids_unicos(substr(p, pos + 4, n)) then
      return false;
    end if;
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
-- `contas` diz quantos campos trazem o GUI: com mais de um, chave e URL são as do primeiro, e o código é recusado.
create function erp.pix_copia_cola_recebedor(p text) returns jsonb language plpgsql immutable
set search_path = pg_catalog, pg_temp as $$
declare i int; v text; c text; u text; n int := 0;
begin
  if not erp.pix_copia_cola_valido(p) then return null; end if;
  for i in 26 .. 51 loop
    v := erp._pix_campo(p, i::text);
    if v is not null and lower(coalesce(erp._pix_campo(v, '00'), '')) = 'br.gov.bcb.pix' then
      n := n + 1;
      if n = 1 then
        c := nullif(trim(erp._pix_campo(v, '01')), '');
        -- a chave como o banco guarda a da parcela: e-mail e aleatória em minúsculas
        if c ~ '@' or c ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then c := lower(c); end if;
        u := nullif(trim(erp._pix_campo(v, '25')), '');
      end if;
    end if;
  end loop;
  if n = 0 then return null; end if;
  return jsonb_build_object('chave', c, 'url', u, 'nome', nullif(trim(erp._pix_campo(p, '59')), ''), 'contas', n);
end $$;

-- Quem recebe pelo código segundo o Asaas (o mesmo que o banco mostra ao pagar). Só o sistema grava, pela função
-- pix-conferir; a leitura passa pelo erp.pix_conferido (definer), que devolve só a conferência do código que a pessoa
-- já tem nas mãos.
create table erp.pix_conferencias (
  codigo       text primary key check (erp.pix_copia_cola_valido(codigo)),
  cpf_cnpj     text check (cpf_cnpj ~ '^[0-9*]{11,14}$'),   -- como o Asaas devolve (pode vir mascarado no CPF)
  nome         text,
  banco        text,
  chave        text,
  valor        numeric(15,2),   -- o valor que o banco do recebedor cobra pelo código (o do código dinâmico)
  por          uuid references erp.usuarios,
  conferido_em timestamptz not null default clock_timestamp()
);
alter table erp.pix_conferencias enable row level security;
alter table erp.pix_conferencias force row level security;
create policy sistema on erp.pix_conferencias using (erp.sistema()) with check (erp.sistema());
create policy conferencia on erp.pix_conferencias for select to erp_conferencia using (true);
revoke all on erp.pix_conferencias from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.pix_conferencias from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on erp.pix_conferencias from authenticated; end if;
end $$;
grant select, insert, update on erp.pix_conferencias to erp_sistema;
grant select on erp.pix_conferencias to erp_conferencia;
create trigger t_nao_trunca before truncate on erp.pix_conferencias for each statement execute function erp.tg_recusa_truncate();

-- Grava a conferência (só o sistema, pela pix-conferir). p_login é o id do login de quem pediu; o limite de pedidos
-- fica em erp.conferencia_tentativa.
create function erp.registrar_pix_conferencia(p_codigo text, p_cpf_cnpj text, p_nome text, p_banco text, p_chave text, p_valor numeric, p_login text)
returns void language plpgsql as $$
declare v_por uuid;
begin
  if not erp.sistema() then raise exception 'Só o sistema grava a conferência do PIX'; end if;
  select id into v_por from erp.usuarios where login_id = p_login and ativo;
  if v_por is null then raise exception 'Quem pediu a conferência não é usuário ativo do ERP'; end if;
  insert into erp.pix_conferencias (codigo, cpf_cnpj, nome, banco, chave, valor, por)
  values (p_codigo, nullif(regexp_replace(coalesce(p_cpf_cnpj, ''), '[^0-9*]', '', 'g'), ''), nullif(trim(p_nome), ''),
          nullif(trim(p_banco), ''), nullif(trim(p_chave), ''), case when p_valor > 0 then round(p_valor, 2) end, v_por)
  on conflict (codigo) do update set cpf_cnpj = excluded.cpf_cnpj, nome = excluded.nome, banco = excluded.banco,
    chave = excluded.chave, valor = excluded.valor, por = excluded.por, conferido_em = clock_timestamp();
end $$;

-- Cada pedido de conferência de quem é usuário ativo do ERP (o limite da função conta os pedidos, também os que o
-- banco do recebedor recusou; revisão do #106). Só o sistema grava e lê.
create table erp.conferencia_tentativas (
  id  bigint generated always as identity primary key,
  por uuid not null references erp.usuarios,
  em  timestamptz not null default clock_timestamp()
);
create index on erp.conferencia_tentativas (por, em);
alter table erp.conferencia_tentativas enable row level security;
alter table erp.conferencia_tentativas force row level security;
create policy sistema on erp.conferencia_tentativas using (erp.sistema()) with check (erp.sistema());
revoke all on erp.conferencia_tentativas from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then revoke all on erp.conferencia_tentativas from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then revoke all on erp.conferencia_tentativas from authenticated; end if;
end $$;
grant select, insert on erp.conferencia_tentativas to erp_sistema;
create trigger t_nao_trunca before truncate on erp.conferencia_tentativas for each statement execute function erp.tg_recusa_truncate();

-- Primeira coisa da função: registra o pedido e devolve quantos o login fez nos últimos 10 minutos, contando este;
-- nulo quando o login não é de usuário ativo do ERP (aí nada mais acontece: nem a conferência guardada volta)
create function erp.conferencia_tentativa(p_login text) returns int language plpgsql as $$
declare v_por uuid; n int;
begin
  if not erp.sistema() then raise exception 'Só o sistema registra o pedido de conferência'; end if;
  select id into v_por from erp.usuarios where login_id = p_login and ativo;
  if v_por is null then return null; end if;
  insert into erp.conferencia_tentativas (por) values (v_por);
  select count(*)::int into n from erp.conferencia_tentativas where por = v_por and em > clock_timestamp() - interval '10 minutes';
  return n;
end $$;

-- A conferência do código, para o gatilho, a tela e o título
create function erp.pix_conferido(p_codigo text) returns jsonb language sql stable as $$
  select jsonb_build_object('cpf_cnpj', c.cpf_cnpj, 'nome', c.nome, 'banco', c.banco, 'valor', c.valor, 'em', c.conferido_em)
    from erp.pix_conferencias c where c.codigo = p_codigo $$;

alter table erp.parcela_pagamentos add column pix_copia_cola text
  check (pix_copia_cola is null or erp.pix_copia_cola_valido(pix_copia_cola));
alter table erp.parcela_pagamentos add column pix_copia_cola_excecao text   -- justificativa do recebedor não conferido
  check (pix_copia_cola_excecao is null or (pix_copia_cola is not null and length(trim(pix_copia_cola_excecao)) > 0));

-- O valor do código é o da parcela e o recebedor é o da parcela ou do credor, ou vem a justificativa (na gravação;
-- a trava de depois do primeiro voto continua a do t_parcela_pagamento). Lê o credor por baixo do RLS, como o
-- t_parcela_pagamento (o mesmo dono).
create function erp.tg_parcela_pix_copia_cola() returns trigger language plpgsql as $$
declare v_pix numeric; v_parcela numeric; r jsonb; c jsonb; v_doc text;
begin
  if new.pix_copia_cola is null then new.pix_copia_cola_excecao := null; return new; end if;
  v_pix := erp.pix_copia_cola_valor(new.pix_copia_cola);
  select valor into v_parcela from erp.parcelas where titulo_id = new.titulo_id and numero = new.numero;
  if v_pix is not null then
    if v_pix is distinct from v_parcela then
      raise exception 'O valor do PIX copia e cola (%) não é o da parcela % (%)', v_pix, new.numero, v_parcela;
    end if;
  end if;
  r := erp.pix_copia_cola_recebedor(new.pix_copia_cola);
  if r is null or (r->>'chave' is null and r->>'url' is null) then
    raise exception 'O PIX copia e cola da parcela % não traz o recebedor PIX', new.numero;
  end if;
  if (r->>'contas')::int > 1 then
    raise exception 'O PIX copia e cola da parcela % traz mais de uma conta PIX', new.numero;
  end if;
  select p.documento into v_doc from erp.titulos t join erp.pessoas p on p.id = t.pessoa_id where t.id = new.titulo_id;
  c := erp.pix_conferido(new.pix_copia_cola);
  -- a conferência só vale com até 1 dia e com o valor cobrado igual ao da parcela (revisão do #106)
  if c is not null and ((c->>'em')::timestamptz <= clock_timestamp() - interval '1 day'
                        or (c->>'valor')::numeric is distinct from v_parcela) then
    c := null;
  end if;
  if (c is not null and c->>'cpf_cnpj' = v_doc)   -- o Asaas diz que quem recebe é o credor
     or (r->>'url' is null and r->>'chave' is not null    -- estático: a chave é a da parcela ou o documento do credor
         and ((new.forma = 'pix' and r->>'chave' = new.pix_chave) or (new.forma = 'boleto' and r->>'chave' = v_doc))) then
    new.pix_copia_cola_excecao := null;   -- recebedor conferido: a exceção some
    return new;
  end if;
  if length(trim(coalesce(new.pix_copia_cola_excecao, ''))) = 0 then
    if c is not null then
      raise exception 'Quem recebe pelo PIX copia e cola da parcela % (%, conferido) não é o credor (só com a justificativa da exceção)',
        new.numero, coalesce(c->>'nome', c->>'cpf_cnpj');
    end if;
    if r->>'url' is null then
      raise exception 'A chave do PIX copia e cola da parcela % não é a % (só com a justificativa da exceção)', new.numero,
        case when new.forma = 'pix' then 'chave PIX da parcela' else 'do CPF/CNPJ do credor' end;
    end if;
    raise exception 'O PIX copia e cola da parcela % é dinâmico e quem recebe não foi conferido (só com a justificativa da exceção)', new.numero;
  end if;
  return new;
end $$;
create trigger t_parcela_pix_copia_cola before insert or update on erp.parcela_pagamentos
  for each row execute function erp.tg_parcela_pix_copia_cola();

revoke execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
  erp._pix_campo(text, text), erp._tlv_ids_unicos(text), erp.pix_copia_cola_recebedor(text), erp.tg_parcela_pix_copia_cola() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
      erp._pix_campo(text, text), erp._tlv_ids_unicos(text), erp.pix_copia_cola_recebedor(text), erp.tg_parcela_pix_copia_cola() from anon;
  end if;
end $$;
grant execute on function erp.pix_copia_cola_valido(text), erp._crc16_pix(text), erp.pix_copia_cola_valor(text),
  erp._pix_campo(text, text), erp._tlv_ids_unicos(text), erp.pix_copia_cola_recebedor(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
grant execute on function erp.tg_parcela_pix_copia_cola()
  to erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
revoke execute on function erp.registrar_pix_conferencia(text, text, text, text, text, numeric, text), erp.conferencia_tentativa(text),
  erp.pix_conferido(text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.registrar_pix_conferencia(text, text, text, text, text, numeric, text), erp.conferencia_tentativa(text),
      erp.pix_conferido(text) from anon;
  end if;
end $$;
grant execute on function erp.registrar_pix_conferencia(text, text, text, text, text, numeric, text), erp.conferencia_tentativa(text)
  to erp_sistema;
grant execute on function erp.pix_conferido(text)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso, erp_config;
alter function erp.pix_conferido(text) security definer set search_path = erp, pg_catalog, pg_temp;
-- o gatilho é do mesmo dono do t_parcela_pagamento (o novo dono precisa de CREATE no esquema para receber a função:
-- dado só aqui e tirado logo depois, se ele não tinha; no Supabase o postgres não é superusuário)
alter function erp.tg_parcela_pix_copia_cola() security definer set search_path = erp, pg_catalog, pg_temp;
create temp table _pixcc_create_dado as
  select r from unnest(array['erp_conferencia']) r where not has_schema_privilege(r, 'erp', 'create');
do $$ declare v text; begin
  for v in select r from _pixcc_create_dado loop execute format('grant create on schema erp to %I', v); end loop;
end $$;
alter function erp.tg_parcela_pix_copia_cola() owner to erp_conferencia;
alter function erp.pix_conferido(text) owner to erp_conferencia;
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
                                                           'conferido', erp.pix_conferido(g.pix_copia_cola),
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
                   'pix_copia_cola_recebedor', erp.pix_copia_cola_recebedor(f.pix_copia_cola),
                   'pix_copia_cola_conferido', erp.pix_conferido(f.pix_copia_cola), 'pix_copia_cola_excecao', f.pix_copia_cola_excecao)$r$);
  if v_novo = v_def then raise exception 'api.titulo: ponto de troca não achado'; end if;
  execute v_novo;
end $$;
