# 8. Segurança: revisões e falhas

Desde 7/nov/2026 esta documentação também revisa a segurança de cada código novo (pedido do Moises): por onde alguém de fora poderia entrar, permissões no Supabase, regras de acesso das tabelas, chamadas sem login, segredos expostos, entradas sem validação e a integração com o Sienge. Os testes do repositório são rodados a cada revisão.

Uma falha encontrada vai na hora para a tarefa que fez o código. Esta página guarda a lista: abertas em cima, corrigidas embaixo.

Gravidade: **crítica** (explorável hoje por quem está fora), **alta** (explorável assim que o sistema for ao ar como está), **média** (depende de uma mudança futura plausível), **baixa** (boa prática).

## Como a revisão cresce

Decisão do Moises (8/nov/2026): quando o projeto crescer, ou seja, quando começarem as primeiras telas ou acontecer o primeiro deploy, a revisão de segurança se divide em dois agentes auxiliares em paralelo. Um cuida do banco; o outro, do front, do servidor e do GitHub. Os dois usam o método completo da skill security-and-hardening de Addy Osmani: mapa de ameaças, STRIDE, casos de abuso e gravidade. Nesse momento, esta revisão avisa o coordenador e começa. Achado grave não se corrige sem antes falar com o Moises, pelo coordenador. Até lá, vale o checklist abaixo, numa revisão só.

## Checklist de cada revisão

Adaptado em 7/nov/2026 da skill "security-and-hardening" de Addy Osmani ([addyosmani/agent-skills](https://github.com/addyosmani/agent-skills/blob/main/skills/security-and-hardening/SKILL.md), lida em 7/nov/2026). A skill foi escrita para apps web com servidor próprio. Aqui ficou só o que vale para Supabase + Postgres + React + adaptador do Sienge, traduzido para os nossos termos.

**1. Fronteiras de confiança.** Antes de revisar, liste por onde entra dado que não escrevemos e passe por cada uma as seis perguntas STRIDE: alguém se passa por outro? Altera o dado? Nega o que fez? Lê o que não devia? Derruba o serviço? Ganha poder que não tem? As fronteiras conhecidas:

| Fronteira | O que entra |
| --- | --- |
| API do Supabase (PostgREST) | Toda chamada das telas, logadas ou não |
| Webhook do Sienge | Aviso sem assinatura documentada |
| Respostas da API do Sienge | Dado de terceiro gravado no `sienge_bruto` |
| Nexxera (decidida em 7/nov/2026) | Arquivos de remessa e retorno bancários |
| Upload de nota (PDF, XML) | Arquivo do fornecedor |
| Leitura da nota por IA | Texto gerado pelo modelo a partir de um PDF que qualquer fornecedor escreve |
| CRM e BKM Terrenos | Dado de outro sistema |
| Portal do PJ (desenhado, 7/nov/2026) | Nota fiscal (PDF/XML) enviada pelo próprio prestador |
| Portal do contador (desenhado, 7/nov/2026) | Login de fora da BKM lendo notas e retenções dos PJ |

**2. Acesso.** Toda função e visão aberta às telas confere quem pede **e** se a pessoa pode mexer naquele registro específico (empresa, empreendimento, natureza), e não só se ela está logada. Na nossa stack isso é RLS + checagem de papel nas funções, com teste por papel. Nenhum privilégio para `anon`. `service_role` só com o que o adaptador usa. **Regra do Moises de 14/nov/2026 (RLS com atenção máxima em todo passo):** RLS ligado e forçado (`enable` + `force row level security`) em toda tabela do `erp`, negando por padrão; teste de catálogo que falha com tabela sem RLS ou com política `using (true)` ou `with check (true)`; toda mudança de tabela ou política vem com teste de quem vê e de quem **não** vê, por núcleo × centro × natureza, com os PJ isolados; `security definer` só com `set search_path` fixo e revisão; nada aberto à API sem política. Conferência de regra de negócio dentro de trigger não pode depender do que o usuário enxerga (S-034).

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

Regra do Moises (8/nov/2026): controles, segurança da informação e SLA são analisados pelo **estado final**, com tudo no nosso sistema. As falhas que só existem enquanto o Sienge paga ou guarda dados ficam marcadas como **transição** (hoje S-010, S-021 e S-029) e não entram nas análises do estado final; voltam à mesa uma vez, antes de o primeiro pagamento real passar pelo passo 1 (aprovado pelo Moises, 8/nov, 02h30).

**Repositório público** (decisão do Moises, 14/nov/2026): aqui fica só o id, a gravidade e o lugar de cada falha aberta. A descrição, o caminho de exploração e a correção ficam fora do repositório, na pasta do projeto (`erp-bkm/seguranca/falhas-abertas.md`), e voltam para cá quando a falha for corrigida.

| Id | Gravidade | Onde | Desde |
| --- | --- | --- | --- |
| S-050 | Baixa | Deploy do `bkm_dev` colado à mão | 14/nov/2026 |
| S-049 | Baixa | CI e repositório | 14/nov/2026 |
| S-048 | Média (desenho) | Portal PJ no mesmo Auth | 14/nov/2026 |
| S-047 | Média (desenho) | Upload de notas | 14/nov/2026 |
| S-046 | Média (desenho) | Logs e `sienge_bruto` com dado bancário | 14/nov/2026 |
| S-045 | Alta (latente; primeiro grant) | Auth compartilhado do `bkm_dev` e funções que só conferem "logado" | 14/nov/2026 |
| S-044 | Alta (desenho) · **transição** | Fila de envio ao Sienge | 14/nov/2026 |
| S-043 | Alta (desenho) | Adaptador do Sienge: releitura pelo id do webhook | 14/nov/2026 |
| S-042 | Alta · **transição** | Senha da API do Sienge injetada pelo proxy do ambiente de nuvem do Claude | 14/nov/2026 |
| S-041 | Alta | Proteção de branch no GitHub | 14/nov/2026 |
| S-040 | Crítica · **risco aceito pelo Moises** (14/nov/2026: o repositório fica público "por um bom tempo"; ele liga o secret scanning e o push protection) | Repositório Mbekerman/SIENGE público; secret scanning e push protection desligados | 14/nov/2026 |
| S-039 | Média (latente; banco de desenvolvimento, 14/nov/2026; aviso 0011 do Supabase) | 49 funções `security invoker` do `erp` sem `search_path` fixo | 14/nov/2026 |
| S-032 | Média (código, 14/nov/2026; corrigido no PR #1, `5bff23f`, `25d9737` e `438daca`, todas as mutações pegas) | Pagamento de título com adiantamento em aberto do mesmo fornecedor | 14/nov/2026 |
| S-031 | Média (desenho, 14/nov/2026) | Travas de data da nota de serviço e exceção pela AF ou AD | 14/nov/2026 |
| S-030 | Alta (desenho e código, 14/nov/2026; (a) corrigido no PR #1, `ec047b8` e `45292ca`, com teste por critério; (b), (c) e (d) abertos) | Previsão aprovada como autorização prévia, que dispensa a AD | 14/nov/2026 |
| S-029 | Média (desenho, 14/nov/2026) · **transição** | Planilha do Google que manda apagar títulos de previsão no Sienge | 14/nov/2026 |
| S-028 | Alta (desenho, 8/nov/2026) | Escolha do aprovador pela classificação | 8/nov/2026 |
| S-027 | Média (desenho, 8/nov/2026) | Entrada única de notas por e-mail e WhatsApp (`erp.notas_recebidas`; proposta da thread do banco) | 8/nov/2026 |
| S-026 | Média (desenho, 8/nov/2026) | Contratos recorrentes: nota que monta o pedido sozinha (proposta da thread do banco) | 8/nov/2026 |
| S-025 | Média (desenho, 8/nov/2026) | Histórico de comunicação (`erp.conversas`, `erp.mensagens`; proposta da thread do banco) | 8/nov/2026 |
| S-024 | Média (desenho, 8/nov/2026) | Drill-down do aprovador, do título à origem | 8/nov/2026 |
| S-023 | Média (desenho, 8/nov/2026) | Relatórios como telas do sistema, com acesso por empresa e centro | 8/nov/2026 |
| S-021 | Alta (limitação do passo 1, 8/nov/2026) · **transição** | Pagamento pelo Sienge no passo 1 | 8/nov/2026 |
| S-020 | Média (desenho, 8/nov/2026) | Camada extra para pagamento vencido ou com encargos | 8/nov/2026 |
| S-019 | Alta (desenho, rev 1196 do documento de aprovação) | Regras "supertrunfo" e duas contas do Moises | 7/nov/2026 |
| S-018 | Média (desenho) | Portal único com projetos separados; cópia horária | 7/nov/2026 |
| S-017 | Alta (desenho) | Dados bancários e PIX do fornecedor; lote e escalada | 8/nov/2026 |
| S-016 | Média (risco aceito pelo Moises, 7/nov/2026, com controle fixo proposto) | Quem lança e aprova nas listas AF, AO e AD | 7/nov/2026 |
| S-014 | Média (desenho) | Papéis de exceção (gestor + CFO/COO, CEO sozinho, pagamento sem regra) | 7/nov/2026 |
| S-013 | Média (desenho) | Aprovação configurável ponto a ponto | 7/nov/2026 |
| S-012 | Média (desenho; correção aprovada) | Nomeação de aprovadores | 7/nov/2026 |
| S-011 | Média (risco aceito pelo Moises, 7/nov/2026) | Folha PJ no livro e no BI | 8/nov/2026 |
| S-010 | Alta (limitação aceita pelo Moises, 7/nov/2026) · **transição** | PJ durante a transição | 7/nov/2026 |
| S-008 | Alta (desenho; parte do master aceita pelo Moises, 7/nov/2026) | Conferência em duas chaves dos PJ ([06](06-decisoes.md)) | 7/nov/2026 |
| S-009 | Média (desenho) | Aprovação como regra-dado | 7/nov/2026 |
| S-007 | Alta (desenho) | Esquema pessoal dos PJ ([03](03-banco-de-dados.md), 3.3) | 7/nov/2026 |
| S-005 | Baixa | `erp.sistema()` + auditoria | 7/nov/2026 |
| S-003 | Alta (bloqueia o primeiro `grant`; negar por padrão feito no PR #1, `cf15ed8`; faltam as políticas por perfil) | Todo o `erp` | 7/nov/2026 |

## A conferir quando o código existir

Ainda não há código para revisar nestes pontos; ficam como requisito para quem construir:

- **Recebedor de webhooks do Sienge:** a documentação não fala de assinatura. Exigir o token cadastrado, recusar o resto, gravar `x-sienge-id` com chave única, nunca confiar no corpo (sempre reler pela API), limitar o tamanho do corpo e a taxa.
- **Adaptador do Sienge:** senha da API num cofre lido só pelo servidor (Secret Manager do Google; o Vault do Supabase só serve se o projeto for próprio do ERP, ver S-015); nunca em log, erro devolvido ao navegador ou `sienge_bruto`. Registro de cada chamada sem o cabeçalho `Authorization`.
- **Upload de notas (PDF/XML):** limite de tamanho e tipo, armazenamento com caminho que a RLS do Storage confere, XML lido sem entidades externas (XXE), o texto lido por IA tratado como dado e não como instrução.
- **Telas:** nada de chave de serviço no navegador; só a chave publicável.
- **Rotinas do servidor (commit `f659cfe`):** contam como sistema a conexão direta ao Postgres, o pg_cron e a chave de serviço (papel `service_role`, pela API do Supabase). A chave de serviço passa em todas as checagens de papel e, no Supabase, também ignora a RLS: vazou, vale tudo. Ela fica só no servidor (Vault ou segredo da Edge Function), nunca no navegador, em log ou no repositório.
- **Portal do PJ (desenhado, 7/nov/2026):** acesso externo que recebe arquivo. Vale o item 5 do checklist (tipo pelo conteúdo, tamanho, XML sem entidades externas, caminho conferido no Storage) e o item 6 se a nota for lida por IA. O PJ só vê e envia as próprias notas e nunca vê a remuneração de outro (nem o valor cadastrado, se não for preciso). Uma conta por PJ, com segundo fator, desligada quando ele sair do cadastro de ativos. Se a NFS-e tiver XML, conferir pela chave na prefeitura, não pelo PDF.
- **Portal do contador (desenhado, 7/nov/2026):** é o primeiro acesso de fora da BKM, e o login do projeto hoje é só Google do Workspace. Requisitos: conta por pessoa (nunca login compartilhado do escritório), com segundo fator; papel próprio que só executa as funções de leitura das notas e retenções, sem `grant` em tabela; escopo pelas empresas que o contador atende; arquivo entregue por link assinado de poucos minutos, gerado pela função que grava o download no log; limite de taxa e de volume para notar download em massa; desligar o acesso no mesmo dia em que o contrato acabar, com revisão periódica de quem ainda entra; mensagem de erro sem detalhe interno. LGPD: o escritório contábil precisa de contrato que cubra os dados pessoais.
- **Grants do `service_role`:** as migrations ainda não dão nenhum privilégio no `erp` ao `service_role` (o teste dá e tira). Quando o adaptador for construído, dar só o `execute` das funções que ele chama, não `all`.

## Falhas corrigidas

| Id | Gravidade | Falha | Correção | Conferido |
| --- | --- | --- | --- | --- |
| S-038 | Alta (latente) | Votos da reclassificação forjáveis por INSERT direto, em nome de qualquer pessoa e papel, completando a alçada sem diretor nem contador | `tg_reclassificacao_protegida` em `reclassificacoes`, `reclassificacao_itens` e `reclassificacao_votos`: só passa com `erp.agindo_como('erp_reclassificacao')` (exceção só para o ON DELETE SET NULL da natureza); TRUNCATE recusado; `pedir_reclassificacao` e `cancelar_reclassificacao` definer de `erp_reclassificacao` (PR #8, `201a1ab`) | 14/nov/2026, na `develop` (merge `dadf8db`), 217 testes; sondagem de INSERT direto recusada |
| S-037 | Média (latente) | Situação da reclassificação mudava por UPDATE direto, sem voto | Mesma proteção da S-038 (PR #8) | 14/nov/2026, na `develop` (merge `dadf8db`); sondagem recusada |
| S-036 | Alta (latente) | Documento fiscal lançado voltava a rascunho e tinha o valor editado com os títulos já criados; rascunho virava lançado sem título | `tg_documento`: a nota nasce em rascunho e a situação só muda dentro de `erp.lancar_documento`, definer de `erp_situacao`; título nasce em rascunho e previsão nasce aberta; `search_path` das definer termina em `pg_temp` (PR #8, `74b5841`) | 14/nov/2026, na `develop` (merge `dadf8db`); sondagem recusada |
| S-035 | Média (latente) | Variáveis de sessão (`erp.sistema`, `erp.sistema_apaga`, `erp.reclassificando`) usadas como passe nos triggers: qualquer sessão com SQL dava SET e passava pelas travas | `erp.agindo_como(papel)` (invoker) compara `current_user` com o papel dono da função definer que faz a operação (`erp_situacao`: `confirmar_titulo`, `tg_quitacao`, `tg_titulo_previsao`; `erp_reclassificacao`: `decidir_reclassificacao`), papéis sem login nem membros, com a política `operacao`; `tg_titulo` recusa toda mudança de situação fora disso (fecha também o rascunho → aberto por UPDATE direto); catálogo sem variável `erp.*` de sessão em função nenhuma (PR #7, `b9a05a8`) | 14/nov/2026, na `develop` (merge `ee7acf9`), 201 testes |
| S-034 | Alta (latente) | Travas em trigger `security invoker` ficariam cegas com o RLS por perfil (adiantamento de outro núcleo, saldos de previsão, parcela e pagamento, listas AF/AO/AD, regra do adiantamento) | 15 funções de conferência `security definer`, donas do papel `erp_conferencia` (sem login, sem membros), com `search_path = erp, pg_catalog`; política `conferencia` só de leitura e só para esse papel; teste com usuário de um núcleo só; catálogo exige `search_path` e o dono certo em todo `security definer` (PR #4, `cb00ade`, aprovado pelo Moises 16h11) | 14/nov/2026, na `develop` (merge `086c08a`), 188 testes, mutações pegas |
| S-033 | Alta (latente) | `erp.sistema()` tratava como sistema qualquer papel sem usuário fora da lista do Supabase; o id do usuário era o do provedor | `erp.sistema()` só com o papel `erp_sistema` ou o dono sem SET ROLE; `erp.usuarios.id` nosso e `login_id text unique`, lido por `erp.login_atual()`; teste de que outro papel sem login não é sistema; catálogo: só o dono e papéis `erp_*` têm privilégio no `erp` (PR #4, `cb00ade`) | 14/nov/2026, na `develop` (merge `086c08a`), 188 testes, mutações pegas |
| S-022 | Média (desenho) | Camada `bi` para o Power BI: visões sem `security_invoker`, usuário `bi_leitor` com senha compartilhada, conexão externa ao banco, máscara de CPF | **Sem efeito (8/nov/2026, 02h26):** o Moises decidiu que não haverá Power BI, nem como ponte; não existe `bi_leitor` nem conexão externa ao banco. Continuam valendo, na S-023: a máscara única de CPF no padrão do governo e o alerta de credor de folha PJ sem a marca | 8/nov/2026 |
| S-015 | Alta (desenho) | ERP no mesmo projeto Supabase do monitor e do Terrenos: a chave de serviço do coletor do monitor passaria como rotina do sistema no `erp` assim que o `service_role` tivesse `execute`, e senha do banco, painel e Vault seriam comuns aos três sistemas | Decisão do Moises (7/nov/2026, 21h56): projeto Supabase próprio do ERP. Defesa extra no código: `revoke` do `service_role` na carga e teste de catálogo que falha com qualquer privilégio dele no `erp` (commits `be52aa9` e `bdd515f`); o adaptador terá papel próprio | 7/nov/2026: resolvida no desenho; 112 testes passando com a defesa extra. Conferir quando o projeto for criado: membros do painel só de quem opera o ERP, chaves só dele, e a consulta do teste de catálogo rodada no banco real |
| S-002 | Média (latente) | `erp.sistema()` decidia "rotina do sistema" por `current_user`; dentro de uma função `security definer` ele é o dono, e uma chamada sem login passaria nas checagens (reproduzido em Postgres de teste: devolvia `true`) | Commit `ae75175`: `sistema()` exige `eu()` nulo, `session_user` fora de `authenticator`, `anon` e `authenticated`, e o papel da sessão (`role`) fora de `anon` e `authenticated`; teste com função `security definer` chamada como `anon` | 7/nov/2026: a mesma reprodução agora devolve `false`; 111 testes passando |
| S-004 | Média | Nenhum teste conferia os privilégios do `erp`, e uma migration futura poderia reabrir o esquema | Commit `ae75175`: teste de catálogo que falha se `PUBLIC`, `anon` ou `authenticated` tiverem `USAGE` no esquema, grant em tabela ou `EXECUTE` em função, inclusive pelo ACL padrão | 7/nov/2026: 111 testes passando |
| S-006 | Baixa | O workflow do CI não declarava `permissions:` e o token do Actions herdava o padrão do repositório | Commit `d19edbb`: `permissions: contents: read` | 7/nov/2026 (conferido no arquivo; o CI ainda não roda, ver [03](03-banco-de-dados.md)) |
| S-001 | Alta | Na v0 inicial do `erp` (commit `649ae60`), `erp.eu()` nulo passava em `exigir_admin`, `exigir_editor` e `exigir_diretor`. Uma chamada anônima pela API do Supabase também tem `auth.uid()` nulo, e o esquema não tinha `revoke`: exposto como estava, qualquer pessoa sem login mudaria a configuração e os lançamentos | Commits `5c71b57` e `89c1202` (branch `claude/project-thread-dknc98`): `erp.sistema()` exclui `anon` e `authenticated`; esquema, tabelas e funções revogados de `public`, `anon` e `authenticated`, inclusive nos privilégios padrão; 4 testes de acesso | 7/nov/2026: 108 testes passando |

## Histórico de revisões

| Data | O que foi revisado | Testes |
| --- | --- | --- |
| 7/nov/2026 | `erp` v0 até o commit `89c1202`: permissões, papéis, funções, `revoke` | 108 passando |
| 7/nov/2026 | Correções S-002 e S-004 (commit `ae75175`) | 111 passando |
| 7/nov/2026 | Chave de serviço como rotina do sistema (commit `f659cfe`): sem falha nova grave; anotada a S-005 | 112 passando |
| 7/nov/2026 | CI (commit `a252fbe`): anotada a S-006 | 112 passando |
| 7/nov/2026 | Desenho do esquema pessoal dos PJ (sem código): anotada a S-007 | não se aplica |
| 7/nov/2026 | Duas chaves dos PJ, portais e aprovação como regra-dado (sem código): anotadas a S-008 e a S-009 | não se aplica |
| 7/nov/2026 | PJ pelo Sienge na transição e Nexxera: anotada a S-010 | não se aplica |
| 7/nov/2026 | Soma da folha PJ por centro com um PJ só: S-011, risco aceito | não se aplica |
| 7/nov/2026 | Master aprova as duas chaves: parte da S-008 aceita, com controles que compensam | não se aplica |
| 7/nov/2026 | Nomeação de aprovadores pelo master ou admin: anotada a S-012 | não se aplica |
| 7/nov/2026 | Aprovação configurável ponto a ponto: anotada a S-013 | não se aplica |
| 7/nov/2026 | Papéis de exceção e pagamento sem regra: anotada a S-014 | não se aplica |
| 7/nov/2026 | Estudo Supabase × AWS: anotada a S-015; corrigida a S-007 (f) sobre o Vault | não se aplica |
| 7/nov/2026 | Mitigação parcial da S-015 (commit `be52aa9`): teste de catálogo com `service_role`, conferido com mutação | 112 passando |
| 7/nov/2026 | `revoke` do `service_role` na carga (commit `bdd515f`) | 112 passando (conferido no branch) |
| 7/nov/2026 | AF, AO e AD lançam e aprovam: anotada a S-016 | não se aplica |
| 7/nov/2026 | Desenho de aprovação v1 (documento): anotada a S-017 | não se aplica |
| 7/nov/2026 | Portal único e cópia horária: anotada a S-018 | não se aplica |
| 7/nov/2026 | Projeto Supabase próprio do ERP: S-015 passa para corrigidas (no desenho) | não se aplica |
| 7/nov/2026 | Documento de aprovação consolidado (rev 543): travas fixas confirmadas; S-017 (d) recusada; revisão trimestral | não se aplica |
| 7/nov/2026 | Documento de aprovação rev 1196: supertrunfo e duas contas como duas pessoas, anotada a S-019 | não se aplica |
| 8/nov/2026 | Camada extra para pagamento vencido ou com encargos: anotada a S-020 | não se aplica |
| 8/nov/2026 | Passo 1 da implantação (pagamento pelo Sienge): anotada a S-021 | não se aplica |
| 8/nov/2026 | Desenho da camada `bi` para o Power BI: anotada a S-022 | não se aplica |
| 8/nov/2026 | Relatórios em telas do sistema (sai o Power BI): anotada a S-023; S-011 decidida; S-022 condicionada | não se aplica |
| 8/nov/2026 | Sem Power BI (Moises, 02h26): S-022 sem efeito; pontos de CPF e marca PJ passam à S-023 | não se aplica |
| 8/nov/2026 | Drill-down do aprovador e agente de recomendação: anotada a S-024 | não se aplica |
| 8/nov/2026 | Histórico de comunicação (conversas e mensagens): anotada a S-025 | não se aplica |
| 8/nov/2026 | Contratos recorrentes com pedido montado pela nota: anotada a S-026 | não se aplica |
| 8/nov/2026 | Entrada única de notas (e-mail e WhatsApp): anotada a S-027 | não se aplica |
| 8/nov/2026 | Escolha do aprovador pela classificação e pares centro × natureza: anotada a S-028 | não se aplica |
| 14/nov/2026 | Previsões como títulos no Sienge e planilha de exclusão: anotada a S-029 (transição) | não se aplica |
| 14/nov/2026 | Renomeação (commits `61467f6`, `402ec3c`): esquema `nucleo` vira `erp`, núcleo econômico × centro de custo, `erp.nucleo_centros` e `erp.checar_centro`; revoke e teste de catálogo conferidos no esquema novo | 121 passando (rodado no branch da doc) |
| 14/nov/2026 | `erp.nucleo_centros` (commit `392155a`): UPDATE recusa mudar a chave, TRUNCATE recusado; mutação (tirar o trigger de TRUNCATE) faz o teste falhar | 123 passando |
| 14/nov/2026 | Decisões de 15h02 (previsão aprovada, travas de data, operações entre empresas, "baixa"): anotadas S-030 (vínculo livre de previsão em `erp.lancar_documento`, que passa a valer aprovação) e S-031 | não se aplica |
| 14/nov/2026 | S-030 (a), commit `ec047b8`: `erp._previsao_casa` confere empresa, fornecedor, núcleo, centro e natureza. Mutação: tirar **qualquer um** dos cinco critérios, um de cada vez, e os testes continuam passando, porque o único teste novo muda empresa e natureza juntas. Falta um teste por critério. Também ficou aberto: basta uma linha do rateio casar para a nota consumir a previsão até o valor bruto inteiro, e não só até a parte daquela linha | 124 passando; 5 mutações não pegas |
| 14/nov/2026 | S-030 (a), commit `45292ca`: um teste por critério e consumo limitado à parte do bruto rateada na combinação da previsão. Mutações refeitas: fornecedor, núcleo, centro e natureza derrubam o teste; empresa sozinha não, porque o trigger `erp.tg_titulo_previsao` também barra; tirando as duas camadas, o teste cai | 129 passando; mutações pegas |
| 14/nov/2026 | Adiantamento carimbado (commit `ffa90d8`): `erp.tg_pagamento` exige núcleo e centro fora da transferência própria (`pessoa_id` é obrigatório no pagamento e único na empresa, então não há brecha pelo nulo). Mutações: tirar a exigência do centro e a conferência da empresa do núcleo derrubam o teste; tirar `checar_centro` do trigger não, porque `erp.tg_lancamento` confere de novo no livro (duas camadas). O abatimento entre núcleos fica permitido (decisão de 7/nov, segundo a thread do banco); a lacuna é a contrária, S-032 | 136 passando |
| 14/nov/2026 | S-032 e regra do adiantamento (commit `5bff23f`): `erp.regra_adiantamento`, `erp.listas_financeiro`, `erp.abatimentos_cruzados`, `erp.liberacoes_sem_abater` e as travas em `erp.tg_quitacao`. 15 mutações; caem: listas configuradas, aprovação que não se apaga, carimbo de centro, admin na regra. **Não caem (falta teste):** (1) tirar `exigir_admin` de `erp.listas_financeiro`, o que deixaria qualquer editor se pôr na AD; (2) quem lançou aprovando o próprio abatimento; (3) usuário inativo nas listas; (4) aprovação de abatimento de um título servindo para outro título do mesmo pagamento; (5) a ordem pelo `criado_em`; (6) a empresa no teste do adiantamento em aberto; (7) os dois triggers de TRUNCATE. **Ajustes de código:** (a) `pagamentos.criado_por` e `criado_em` são só padrão, e quem grava o pagamento pode mandar outro valor, fugindo da regra de quem lançou e da ordem dos adiantamentos; um trigger BEFORE deve forçar `erp.eu()` e `clock_timestamp()`; (b) a liberação sem abater não confere quem lançou o título; (c) a liberação vale para sempre no título, inclusive para adiantamento que surgir depois dela | 147 passando; 7 mutações não pegas |
| 14/nov/2026 | S-032, commit `25d9737`: os 7 testes que faltavam e os 3 ajustes (`erp.tg_autor` em títulos e pagamentos, quem lançou o título não libera, liberação só cobre adiantamento anterior a ela). Mutações novas: caem o autor do servidor, o lançador do título, o lançador do pagamento e a data da liberação. **Ainda não caem:** forçar `criado_em` no INSERT (sem isso a ordem dos adiantamentos volta a ser do cliente) e recusar mudança de autor ou data no UPDATE de títulos | 160 passando; 2 mutações não pegas |
| 14/nov/2026 | S-032, commit `438daca`: testes do `erp.tg_autor` (valores do cliente ignorados no INSERT, autor e data recusados no UPDATE). As duas mutações restantes agora derrubam a suíte | 164 passando |
| 14/nov/2026 | PR #1 (commit `438daca`) contra as regras de portabilidade e de RLS: 47 tabelas no `erp`, nenhuma com RLS (S-003, ainda não explorável com o esquema fechado); nenhuma função `security definer`; `auth.uid()` só em `erp.eu()`; sem extensão, Storage, cron nem Vault. Anotadas S-033 (lista de papéis do Supabase em `erp.sistema()`) e S-034 (travas em trigger invoker cegas pelo RLS) | 164 passando |
| 14/nov/2026 | S-003, commit `cf15ed8` (`20261107000500_erp_rls.sql`): RLS ligado e forçado nas 47 tabelas, uma política só (`erp.sistema()`), teste de catálogo (RLS forçado, nenhuma política `true`) e teste de papel comum que lê 0 linhas. Mutação sem o `force` cai. Observações: (a) a suíte roda como superusuário, que ignora o RLS, então os demais testes não passam pela política; (b) o teste "papel comum sem usuário lê como sistema" mostra a S-033 na prática: qualquer papel fora da lista do Supabase vira sistema. Moises aprovou corrigir S-033 e S-034 (16h11) | 169 passando |
| 14/nov/2026 | PRs #1, #2 e #3 juntados na `develop` (`044915f`) a pedido do Moises. Conferido na `develop`: 5 migrations, 169 testes passando. S-033 e S-034 seguem abertas lá até o PR novo | 169 passando |
| 14/nov/2026 | PR #4 (commit `cb00ade`): S-033 (`erp_sistema`, `usuarios.login_id`, `erp.login_atual()`) e S-034 (15 funções `security definer` do papel `erp_conferencia`, `search_path` fixo, política `conferencia` só de leitura e só para esse papel). Mutações conferidas aqui: dono das funções e `previsao_saldo` sem definer derrubam a suíte; as 8 da thread do banco também. Abertos: S-035 (variáveis de sessão como passe, também `erp.reclassificando`); `checar_natureza`, `checar_centro`, `tg_nucleo_economico` e os votos da reclassificação ainda invoker; os saldos `security definer` devolvem o valor de qualquer id, e no primeiro grant a `authenticated` precisam ficar fora do EXECUTE ou conferir a visibilidade; falta teste de que `erp_sistema` não tem como membro nenhum papel da API (só o adaptador) | 188 passando |
| 14/nov/2026 | PRs #4 e #5 juntados na `develop` (`086c08a`, `180a6b5`) a pedido do Moises; S-033 e S-034 passam a corrigidas. Conferido na `develop`: 188 testes | 188 passando |
| 14/nov/2026 | PR #7 (S-035, `b9a05a8`, merge `ee7acf9`): 201 testes na `develop`; nenhuma leitura de variável `erp.*` de sessão nas migrations. Sondagem da situação de `documentos_fiscais` e `reclassificacoes` (fora do escopo do PR #7): UPDATE direto passa nas duas, anotadas S-036 (alta) e S-037 (média). Para a implantação: dono das funções sem superusuário exige CREATE no esquema; com a RLS por perfil, as operações definer conferem se quem chama vê o registro | 201 passando |
| 14/nov/2026 | PR #8 (S-036, S-037, S-038; `74b5841`, `201a1ab`): 217 testes. Sondagem refeita no head do PR: documento lançado não volta a rascunho, voto forjado por INSERT direto é recusado, situação da reclassificação não muda por UPDATE direto. `search_path` das definer termina em `pg_temp` | 217 passando |
| 14/nov/2026 | PR #8 juntado na `develop` (`dadf8db`); S-036, S-037 e S-038 passam a corrigidas | 217 passando |
| 14/nov/2026 | Primeiro deploy: `erp` da `develop` aplicado no `bkm_dev` (desenvolvimento, sem dado real). Conferências de catálogo no remoto (RLS forçado nas 47 tabelas, nenhum grant à API, donos das definer); suíte só local. Aviso do Supabase sobre 49 invoker sem `search_path`: anotada S-039. `public.rls_auto_enable()` executável por `anon` e `authenticated` é do Supabase e devolve `event_trigger` (não se chama por RPC). Começa a revisão em duas frentes (ver "Como a revisão cresce") | não se aplica |
| 14/nov/2026 | Revisão em duas frentes, frente GitHub, servidor e front (método completo, agente auxiliar; nada alterado): S-040 a S-050. Conferido e ok: workflow sem `pull_request_target`, `contents: read`, sem segredo nem expressão do evento em `run:`; 244 commits sem segredo; nenhum `.env` commitado; nenhum dado pessoal real. Repositório público mantido pelo Moises: falhas abertas passam a ficar só com id e gravidade aqui | não se aplica |
