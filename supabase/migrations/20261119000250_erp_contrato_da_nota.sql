-- O contrato preso à nota e ao título é conferido contra eles (revisão de segurança do PR #93, 19/11/2026).
--
-- Antes, documentos_fiscais.compromisso_id e titulos.compromisso_id aceitavam qualquer contrato: uma nota de um
-- fornecedor podia ser presa ao contrato de outro fornecedor ou de outra empresa, e erp.lancar_documento então
-- retinha a caução daquele contrato e consumia as previsões dele. Agora:
--   - o contrato é da mesma empresa do registro;
--   - na nota, o contrato é do fornecedor que emitiu (compromissos.pessoa_id = emitente_id);
--   - no título do fornecedor, avulso ou adiantamento, o contrato é do credor do título (o título de imposto vai ao
--     órgão e o de caução pode ir a um terceiro: esses seguem o contrato da nota, que já foi conferido);
--   - quem grava (pessoa, não o sistema nem as operações do banco) só prende a nota ou o título a contrato ativo
--     e que ela vê.
-- A conferência lê o contrato sem o RLS (definer do erp_conferencia, que lê tudo e só lê): o gatilho de quem grava
-- não enxergaria o contrato escondido e não saberia dizer por quê. Ela só responde com a mensagem do erro, nunca com
-- dado do contrato. Chamada direta com p_pessoa_grava falso diria só se um id de contrato é de outra empresa ou
-- fornecedor; o id é aleatório e quem não vê o contrato não o conhece.
-- Portabilidade: SQL puro.

create function erp.contrato_confere(p_compromisso uuid, p_empresa uuid, p_pessoa uuid, p_pessoa_grava boolean)
returns text language sql stable security definer set search_path = erp, pg_catalog, pg_temp as $$
  select case
    when c.id is null then 'Contrato não encontrado'
    -- quem grava não fica sabendo nada do contrato que não vê (nem de quem ele é)
    when p_pessoa_grava and not coalesce(erp._vejo_compromisso(c.id, c.criado_por), false) then 'Contrato não encontrado'
    when c.empresa_id <> p_empresa then 'O contrato é de outra empresa'
    when p_pessoa is not null and c.pessoa_id is distinct from p_pessoa then 'O contrato é de outro fornecedor'
    when p_pessoa_grava and c.situacao <> 'ativo' then 'O contrato não está ativo'
  end
  from (select 1) x left join erp.compromissos c on c.id = p_compromisso $$;
alter function erp.contrato_confere(uuid, uuid, uuid, boolean) owner to erp_conferencia;

-- Invoker de propósito: precisa saber quem grava (erp.agindo_como, erp.sistema).
create function erp.tg_contrato_confere() returns trigger language plpgsql as $$
declare v_pessoa uuid; v_erro text; v_grava boolean;
begin
  if new.compromisso_id is null then return new; end if;
  if tg_table_name = 'documentos_fiscais' then
    v_pessoa := new.emitente_id;
  else
    v_pessoa := case when (to_jsonb(new)->>'tipo') in ('fornecedor', 'avulso', 'adiantamento') then (to_jsonb(new)->>'pessoa_id')::uuid end;
  end if;
  v_grava := not (erp.sistema() or erp.agindo_como('erp_situacao'));
  v_erro := erp.contrato_confere(new.compromisso_id, new.empresa_id, v_pessoa, v_grava);
  if v_erro is not null then raise exception '%', v_erro; end if;
  return new;
end $$;
create trigger t_contrato_confere before insert or update of compromisso_id, emitente_id, empresa_id on erp.documentos_fiscais
  for each row execute function erp.tg_contrato_confere();
create trigger t_contrato_confere before insert or update of compromisso_id, pessoa_id, empresa_id, tipo on erp.titulos
  for each row execute function erp.tg_contrato_confere();

revoke execute on function erp.contrato_confere(uuid, uuid, uuid, boolean), erp.tg_contrato_confere() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function erp.contrato_confere(uuid, uuid, uuid, boolean) from anon; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke execute on function erp.contrato_confere(uuid, uuid, uuid, boolean) from service_role; end if;
end $$;
-- o gatilho roda com o papel de quem grava: a pessoa logada, o sistema e as operações do banco
grant execute on function erp.contrato_confere(uuid, uuid, uuid, boolean)
  to authenticated, erp_sistema, erp_conferencia, erp_situacao, erp_reclassificacao, erp_acesso;
