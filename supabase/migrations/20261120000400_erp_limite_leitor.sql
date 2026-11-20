-- Limite do leitor de notas por pessoa (Moises, 20/11/2026: "Coloca esse valor configurável e por usuário. O default
-- pode ser 30"). É quantos arquivos a pessoa sobe ao leitor a cada 10 minutos; cada PDF ou foto é uma chamada paga à
-- IA, então o limite segura login roubado ou script com erro.
--   - erp.usuarios.limite_leitor: nulo = o padrão (30); de 1 a 1000.
--   - Quem muda: o administrador ou o master, como os outros dados do usuário (RLS e erp.tg_so_admin); ninguém muda o
--     próprio (erp.tg_usuario); fica na auditoria (t_aud_usuarios). Não é configuração de dinheiro.
--   - api.eu() passa a trazer limite_leitor (o da pessoa ou o padrão): o leitor lê com o login da pessoa.
--   - api.definir_limite_leitor(usuário, limite): a mesma regra, com erro claro quando não pode (o RLS só zeraria).
-- Portabilidade: SQL puro.

alter table erp.usuarios add column limite_leitor integer check (limite_leitor between 1 and 1000);
comment on column erp.usuarios.limite_leitor is
  'Arquivos que a pessoa sobe ao leitor de notas a cada 10 minutos; nulo = o padrão (30)';

create or replace function api.eu() returns jsonb language sql stable security invoker set search_path = pg_catalog, pg_temp as $$
  select jsonb_build_object(
           'id', u.id, 'nome', u.nome, 'papel', u.papel, 'administrador', u.administrador,
           'master', erp.sou_master(), 'escreve', erp.escrevo(),
           'listas', coalesce((select jsonb_agg(l.lista order by l.lista) from erp.listas_financeiro l where l.user_id = u.id), '[]'::jsonb),
           'limite_leitor', coalesce(u.limite_leitor, 30))
    from erp.usuarios u
   where u.id = erp.eu() and erp.membro() $$;

create function api.definir_limite_leitor(p_usuario uuid, p_limite integer) returns void
  language plpgsql security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not (erp.sou_admin() or erp.sou_master()) then
    raise exception 'Só o administrador ou o master muda o limite do leitor';
  end if;
  if p_usuario = erp.eu() then raise exception 'Ninguém muda o próprio limite do leitor'; end if;
  if p_limite is not null and (p_limite < 1 or p_limite > 1000) then
    raise exception 'O limite do leitor vai de 1 a 1000 arquivos a cada 10 minutos';
  end if;
  update erp.usuarios set limite_leitor = p_limite where id = p_usuario;
  if not found then raise exception 'Usuário não encontrado'; end if;
end $$;
-- só authenticated executa (os privilégios padrão do Supabase dão a anon e service_role)
do $$
declare f text := 'api.definir_limite_leitor(uuid, integer)';
begin
  execute format('revoke execute on function %s from public', f);
  if exists (select 1 from pg_roles where rolname = 'anon') then execute format('revoke execute on function %s from anon', f); end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute format('revoke execute on function %s from service_role', f); end if;
  execute format('grant execute on function %s to authenticated', f);
end $$;
