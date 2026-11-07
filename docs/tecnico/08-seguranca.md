# 8. Segurança: revisões e falhas

Desde 7/nov/2026 esta documentação também revisa a segurança de cada código novo (pedido do Moises): por onde alguém de fora poderia entrar, permissões no Supabase, regras de acesso das tabelas, chamadas sem login, segredos expostos, entradas sem validação e a integração com o Sienge. Os testes do repositório são rodados a cada revisão.

Uma falha encontrada vai na hora para a tarefa que fez o código. Esta página guarda a lista: abertas em cima, corrigidas embaixo.

Gravidade: **crítica** (explorável hoje por quem está fora), **alta** (explorável assim que o sistema for ao ar como está), **média** (depende de uma mudança futura plausível), **baixa** (boa prática).

## Checklist de cada revisão

Adaptado em 7/nov/2026 da skill "security-and-hardening" de Addy Osmani ([addyosmani/agent-skills](https://github.com/addyosmani/agent-skills/blob/main/skills/security-and-hardening/SKILL.md), lida em 7/nov/2026). A skill foi escrita para apps web com servidor próprio. Aqui ficou só o que vale para Supabase + Postgres + React + adaptador do Sienge, traduzido para os nossos termos.

**1. Fronteiras de confiança.** Antes de revisar, liste por onde entra dado que não escrevemos e passe por cada uma as seis perguntas STRIDE: alguém se passa por outro? Altera o dado? Nega o que fez? Lê o que não devia? Derruba o serviço? Ganha poder que não tem? As fronteiras conhecidas:

| Fronteira | O que entra |
| --- | --- |
| API do Supabase (PostgREST) | Toda chamada das telas, logadas ou não |
| Webhook do Sienge | Aviso sem assinatura documentada |
| Respostas da API do Sienge | Dado de terceiro gravado no `sienge_bruto` |
| Upload de nota (PDF, XML) | Arquivo do fornecedor |
| Leitura da nota por IA | Texto gerado pelo modelo a partir de um PDF que qualquer fornecedor escreve |
| CRM e BKM Terrenos | Dado de outro sistema |

**2. Acesso.** Toda função e visão aberta às telas confere quem pede **e** se a pessoa pode mexer naquele registro específico (empresa, empreendimento, natureza), e não só se ela está logada. Na nossa stack isso é RLS + checagem de papel nas funções, com teste por papel. Nenhum privilégio para `anon`. `service_role` só com o que o adaptador usa.

**3. Entrada.** Valida no banco, na função que grava: tipo, tamanho, lista de valores, formato (CPF, CNPJ, valores, datas). A validação da tela é conforto, não proteção. SQL dinâmico (`execute`) só com `format('%I', ...)`/`%L` ou parâmetros, nunca concatenando texto.

**4. Segredos.** Nada de senha, token ou chave no repositório, em log, em mensagem de erro, no `sienge_bruto` ou na janela de contexto de uma IA. `.env.example` com valores falsos; `.env*` reais no `.gitignore`. Antes de cada commit, procurar segredo no diff. Segredo que chegou ao GitHub está vazado: trocar primeiro, limpar o histórico depois.

**5. Upload.** Lista de tipos aceitos (PDF, XML) conferida pelo conteúdo, não pela extensão; limite de tamanho; caminho no Storage conferido pela RLS; XML lido sem entidades externas.

**6. Saída da IA.** O que o modelo devolve é dado não confiável: valida por esquema (valores, CNPJ, datas) antes de usar, e nunca vai para SQL, HTML cru ou caminho de arquivo. Um PDF pode trazer instruções escondidas para o modelo; quem decide a permissão é o código, nunca o prompt. A IA não recebe segredo nem dado de outra empresa.

**7. Erros e logs.** Mensagem ao usuário sem detalhe interno (pilha, SQL, nome de tabela do Sienge); o detalhe vai para o log do servidor, sem dado sensível.

**8. Abuso e volume.** Limite de tamanho e de taxa no recebedor do webhook e no upload; tempo máximo nas chamadas ao Sienge. O limite do próprio Sienge (200 por minuto) não protege o nosso lado.

**9. Rastro.** Ação que mexe em dinheiro, permissão ou configuração fica na auditoria com quem fez (ver S-005).

**10. Dependências.** Quando houver `package.json`: `npm audit` no lockfile antes de cada entrega, triagem do que é crítico ou alto pelo que de fato roda, nunca `npm audit fix --force` automático, e revisão de toda dependência nova (dono, manutenção, nome parecido com outro pacote).

**11. Telas.** Cabeçalhos de segurança no servidor web (CSP começando de `default-src 'self'`, HSTS, `X-Frame-Options`, `X-Content-Type-Options`), nada de `dangerouslySetInnerHTML` com dado de usuário ou do Sienge, só a chave publicável do Supabase no navegador.

**12. Dados pessoais (LGPD).** CPF, dados bancários e Pix de fornecedores, folha e dados de sócios: cada campo novo é classificado (comum, pessoal, sensível), só se guarda o que tem finalidade, e o desenho precisa permitir achar e apagar os dados de uma pessoa. Mandar dado pessoal para um serviço de IA ou de terceiros exige contrato com ele.

O que ficou de fora da skill, e por quê:

- **Senhas com bcrypt e cookies de sessão:** o login é do Supabase Auth com Google; não guardamos senha nem montamos sessão.
- **Configuração de CORS e cabeçalhos via Express/helmet:** não há servidor Express. O CORS da API é do Supabase; os cabeçalhos vão no servidor web do front (item 11).
- **Operações destrutivas em arquivos e SSRF:** o sistema não apaga arquivos por caminho nem busca URL informada pelo usuário. Volta para o checklist se isso aparecer.
- **"Nunca guardar o token de sessão no localStorage":** o supabase-js guarda a sessão no navegador por padrão, como no BKM Terrenos. Aceitamos essa troca e compensamos com CSP rígida e sem HTML cru (item 11). **[A decidir]** se um dia valer usar cookies pelo servidor.

## Falhas abertas

| Id | Gravidade | Onde | Falha | Correção sugerida | Desde |
| --- | --- | --- | --- | --- | --- |
| S-005 | Baixa | `nucleo.sistema()` + auditoria | O que uma rotina do sistema faz (chave de serviço, pg_cron) fica na auditoria e no livro sem autor (`por` nulo). Quando o adaptador agir por pedido de alguém (ex.: lançar a nota que um analista aprovou), não fica registrado quem pediu | O adaptador grava o autor do pedido na fila de envio e passa esse autor às funções (parâmetro ou configuração de sessão lida pela auditoria), com teste | 7/nov/2026 |
| S-003 | Alta (bloqueia o primeiro `grant`) | Todo o `nucleo` | Não há RLS em nenhuma tabela. Hoje o esquema está fechado a `anon` e `authenticated`, então não é explorável. No primeiro `grant` para as telas, qualquer usuário logado leria tudo, de todas as empresas, inclusive folha e movimentos entre sócios | Criar a RLS no mesmo PR do primeiro `grant`, com teste por papel e por empresa ou empreendimento. Preferir dar `grant` só em funções e visões, não nas tabelas | 7/nov/2026 |

## A conferir quando o código existir

Ainda não há código para revisar nestes pontos; ficam como requisito para quem construir:

- **Recebedor de webhooks do Sienge:** a documentação não fala de assinatura. Exigir o token cadastrado, recusar o resto, gravar `x-sienge-id` com chave única, nunca confiar no corpo (sempre reler pela API), limitar o tamanho do corpo e a taxa.
- **Adaptador do Sienge:** senha da API só no Vault, lida pelo servidor; nunca em log, erro devolvido ao navegador ou `sienge_bruto`. Registro de cada chamada sem o cabeçalho `Authorization`.
- **Upload de notas (PDF/XML):** limite de tamanho e tipo, armazenamento com caminho que a RLS do Storage confere, XML lido sem entidades externas (XXE), o texto lido por IA tratado como dado e não como instrução.
- **Telas:** nada de chave de serviço no navegador; só a chave publicável.
- **Rotinas do servidor (commit `f659cfe`):** contam como sistema a conexão direta ao Postgres, o pg_cron e a chave de serviço (papel `service_role`, pela API do Supabase). A chave de serviço passa em todas as checagens de papel e, no Supabase, também ignora a RLS: vazou, vale tudo. Ela fica só no servidor (Vault ou segredo da Edge Function), nunca no navegador, em log ou no repositório.
- **Grants do `service_role`:** as migrations ainda não dão nenhum privilégio no `nucleo` ao `service_role` (o teste dá e tira). Quando o adaptador for construído, dar só o `execute` das funções que ele chama, não `all`.

## Falhas corrigidas

| Id | Gravidade | Falha | Correção | Conferido |
| --- | --- | --- | --- | --- |
| S-002 | Média (latente) | `nucleo.sistema()` decidia "rotina do sistema" por `current_user`; dentro de uma função `security definer` ele é o dono, e uma chamada sem login passaria nas checagens (reproduzido em Postgres de teste: devolvia `true`) | Commit `ae75175`: `sistema()` exige `eu()` nulo, `session_user` fora de `authenticator`, `anon` e `authenticated`, e o papel da sessão (`role`) fora de `anon` e `authenticated`; teste com função `security definer` chamada como `anon` | 7/nov/2026: a mesma reprodução agora devolve `false`; 111 testes passando |
| S-004 | Média | Nenhum teste conferia os privilégios do `nucleo`, e uma migration futura poderia reabrir o esquema | Commit `ae75175`: teste de catálogo que falha se `PUBLIC`, `anon` ou `authenticated` tiverem `USAGE` no esquema, grant em tabela ou `EXECUTE` em função, inclusive pelo ACL padrão | 7/nov/2026: 111 testes passando |
| S-006 | Baixa | O workflow do CI não declarava `permissions:` e o token do Actions herdava o padrão do repositório | Commit `d19edbb`: `permissions: contents: read` | 7/nov/2026 (conferido no arquivo; o CI ainda não roda, ver [03](03-banco-de-dados.md)) |
| S-001 | Alta | Na v0 inicial do `nucleo` (commit `649ae60`), `nucleo.eu()` nulo passava em `exigir_admin`, `exigir_editor` e `exigir_diretor`. Uma chamada anônima pela API do Supabase também tem `auth.uid()` nulo, e o esquema não tinha `revoke`: exposto como estava, qualquer pessoa sem login mudaria a configuração e os lançamentos | Commits `5c71b57` e `89c1202` (branch `claude/project-thread-dknc98`): `nucleo.sistema()` exclui `anon` e `authenticated`; esquema, tabelas e funções revogados de `public`, `anon` e `authenticated`, inclusive nos privilégios padrão; 4 testes de acesso | 7/nov/2026: 108 testes passando |

## Histórico de revisões

| Data | O que foi revisado | Testes |
| --- | --- | --- |
| 7/nov/2026 | `nucleo` v0 até o commit `89c1202`: permissões, papéis, funções, `revoke` | 108 passando |
| 7/nov/2026 | Correções S-002 e S-004 (commit `ae75175`) | 111 passando |
| 7/nov/2026 | Chave de serviço como rotina do sistema (commit `f659cfe`): sem falha nova grave; anotada a S-005 | 112 passando |
| 7/nov/2026 | CI (commit `a252fbe`): anotada a S-006 | 112 passando |
