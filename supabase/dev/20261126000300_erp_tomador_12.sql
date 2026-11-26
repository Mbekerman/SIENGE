-- bkm_dev, 26/nov/2026: justificativa do tomador com pelo menos 12 caracteres (migration 20261126000300). Colar inteiro no SQL Editor.
begin;
-- Justificativa do tomador com pelo menos 12 caracteres (Moises, 26/11/2026: "o botão Lançar deve estar desabilitado até
-- ter uma justificativa de pelo menos 12 caracteres"). Antes eram 5; no bkm_dev não havia nenhuma (conferido 26/11).
alter table erp.documentos_fiscais drop constraint documentos_fiscais_tomador_excecao_check;
alter table erp.documentos_fiscais
  add constraint documentos_fiscais_tomador_excecao_check check (tomador_excecao is null or length(trim(tomador_excecao)) between 12 and 500);
commit;
