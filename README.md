# ERP BKM

Código do ERP próprio da BKM, que substituirá o Sienge aos poucos.

- `supabase/migrations/`: esquema `nucleo` (cadastros, árvore de naturezas, contas a pagar, livro de lançamentos, reclassificação).
- `supabase/tests/run.sh`: aplica as migrations num Postgres 16 temporário e roda os testes de regra.
- `docs/nucleo.md`: dicionário das tabelas, em português.
- `docs/tecnico/`: documentação técnica "as built" para desenvolvedores e administradores (arquitetura, ambientes e segredos, banco, integração com o Sienge, pendências).

Idioma do código de domínio, da documentação e dos commits: português. Regra de negócio mora no banco, sempre com teste.
