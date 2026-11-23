-- Limite do leitor: teto do master sobe de 1000 para 10000 arquivos a cada 10 minutos (Moises, 20/11/2026: "mude o
-- código pra que o meu possa ser 10.000 em 10 minutos"). O administrador continua até 100 (t_limite_leitor, sem
-- mudança); só o master passa de 100. O padrão continua 30. Cada PDF ou foto é uma chamada paga à IA: a trava de
-- verdade do custo é o limite de gasto do workspace da Anthropic.
-- Portabilidade: SQL puro.

alter table erp.usuarios drop constraint usuarios_limite_leitor_check;
alter table erp.usuarios add constraint usuarios_limite_leitor_check check (limite_leitor between 1 and 10000);

create or replace function api.definir_limite_leitor(p_usuario uuid, p_limite integer) returns void
  language plpgsql security invoker set search_path = pg_catalog, pg_temp as $$
begin
  if not (erp.sou_admin() or erp.sou_master()) then
    raise exception 'Só o administrador ou o master muda o limite do leitor';
  end if;
  if p_usuario = erp.eu() then raise exception 'Ninguém muda o próprio limite do leitor'; end if;
  if p_limite is not null and (p_limite < 1 or p_limite > 10000) then
    raise exception 'O limite do leitor vai de 1 a 10000 arquivos a cada 10 minutos';
  end if;
  if p_limite > 100 and not erp.sou_master() then
    raise exception 'Acima de 100 arquivos a cada 10 minutos, só o master muda o limite do leitor';
  end if;
  update erp.usuarios set limite_leitor = p_limite where id = p_usuario;
  if not found then raise exception 'Usuário não encontrado'; end if;
end $$;
-- o create or replace mantém os privilégios (só authenticated, da 20261120000400)
