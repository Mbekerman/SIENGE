# Scripts do bkm_dev

Um arquivo por migration, com o mesmo nome dela: é o que se cola no SQL Editor do `bkm_dev` para aplicá-la.

No Supabase o `postgres` não é superusuário: não executa as funções do `erp`, não cria gatilho com `erp.tg_auditoria`
e não troca função de outro dono. Por isso o script se dá `erp_conferencia` (sem herdar, só `set`) e o `create` no
esquema durante a transação, faz a troca com `set local role erp_conferencia` e tira tudo antes do `commit`.

O `supabase/tests/run.sh` roda cada script daqui no lugar da migration, com o `postgres` sem superusuário e com
`ADMIN` sobre os papéis `erp_*` (como no `bkm_dev`, onde ele os criou). Se o script quebra por permissão, o CI fica
vermelho. Depois do script, a suíte inteira roda, o que também confere que ele faz o mesmo que a migration.

Sem segredos aqui: o repositório é público.
