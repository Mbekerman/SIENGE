# 8. Segurança: revisões e falhas

Desde 7/nov/2026 esta documentação também revisa a segurança de cada código novo (pedido do Moises): por onde alguém de fora poderia entrar, permissões no Supabase, regras de acesso das tabelas, chamadas sem login, segredos expostos, entradas sem validação e a integração com o Sienge. Os testes do repositório são rodados a cada revisão.

Uma falha encontrada vai na hora para a tarefa que fez o código. Esta página guarda a lista: abertas em cima, corrigidas embaixo.

Gravidade: **crítica** (explorável hoje por quem está fora), **alta** (explorável assim que o sistema for ao ar como está), **média** (depende de uma mudança futura plausível), **baixa** (boa prática).

## Falhas abertas

| Id | Gravidade | Onde | Falha | Correção sugerida | Desde |
| --- | --- | --- | --- | --- | --- |
| S-003 | Alta (bloqueia o primeiro `grant`) | Todo o `nucleo` | Não há RLS em nenhuma tabela. Hoje o esquema está fechado a `anon` e `authenticated`, então não é explorável. No primeiro `grant` para as telas, qualquer usuário logado leria tudo, de todas as empresas, inclusive folha e movimentos entre sócios | Criar a RLS no mesmo PR do primeiro `grant`, com teste por papel e por empresa ou empreendimento. Preferir dar `grant` só em funções e visões, não nas tabelas | 7/nov/2026 |

## A conferir quando o código existir

Ainda não há código para revisar nestes pontos; ficam como requisito para quem construir:

- **Recebedor de webhooks do Sienge:** a documentação não fala de assinatura. Exigir o token cadastrado, recusar o resto, gravar `x-sienge-id` com chave única, nunca confiar no corpo (sempre reler pela API), limitar o tamanho do corpo e a taxa.
- **Adaptador do Sienge:** senha da API só no Vault, lida pelo servidor; nunca em log, erro devolvido ao navegador ou `sienge_bruto`. Registro de cada chamada sem o cabeçalho `Authorization`.
- **Upload de notas (PDF/XML):** limite de tamanho e tipo, armazenamento com caminho que a RLS do Storage confere, XML lido sem entidades externas (XXE), o texto lido por IA tratado como dado e não como instrução.
- **Telas:** nada de chave de serviço no navegador; só a chave publicável.
- **Consequência da correção S-002 para o adaptador:** chamadas pela API do Supabase (PostgREST) entram com `session_user = authenticator`, inclusive com a chave de serviço, e por isso **nunca** contam como rotina do sistema. Rotinas que precisem passar pelas checagens têm de rodar por conexão direta ao Postgres ou pelo pg_cron.

## Falhas corrigidas

| Id | Gravidade | Falha | Correção | Conferido |
| --- | --- | --- | --- | --- |
| S-002 | Média (latente) | `nucleo.sistema()` decidia "rotina do sistema" por `current_user`; dentro de uma função `security definer` ele é o dono, e uma chamada sem login passaria nas checagens (reproduzido em Postgres de teste: devolvia `true`) | Commit `ae75175`: `sistema()` exige `eu()` nulo, `session_user` fora de `authenticator`, `anon` e `authenticated`, e o papel da sessão (`role`) fora de `anon` e `authenticated`; teste com função `security definer` chamada como `anon` | 7/nov/2026: a mesma reprodução agora devolve `false`; 111 testes passando |
| S-004 | Média | Nenhum teste conferia os privilégios do `nucleo`, e uma migration futura poderia reabrir o esquema | Commit `ae75175`: teste de catálogo que falha se `PUBLIC`, `anon` ou `authenticated` tiverem `USAGE` no esquema, grant em tabela ou `EXECUTE` em função, inclusive pelo ACL padrão | 7/nov/2026: 111 testes passando |
| S-001 | Alta | Na v0 inicial do `nucleo` (commit `649ae60`), `nucleo.eu()` nulo passava em `exigir_admin`, `exigir_editor` e `exigir_diretor`. Uma chamada anônima pela API do Supabase também tem `auth.uid()` nulo, e o esquema não tinha `revoke`: exposto como estava, qualquer pessoa sem login mudaria a configuração e os lançamentos | Commits `5c71b57` e `89c1202` (branch `claude/project-thread-dknc98`): `nucleo.sistema()` exclui `anon` e `authenticated`; esquema, tabelas e funções revogados de `public`, `anon` e `authenticated`, inclusive nos privilégios padrão; 4 testes de acesso | 7/nov/2026: 108 testes passando |

## Histórico de revisões

| Data | O que foi revisado | Testes |
| --- | --- | --- |
| 7/nov/2026 | `nucleo` v0 até o commit `89c1202`: permissões, papéis, funções, `revoke` | 108 passando |
| 7/nov/2026 | Correções S-002 e S-004 (commit `ae75175`) | 111 passando |
