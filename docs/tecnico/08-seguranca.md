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
| Nexxera (decidida em 7/nov/2026) | Arquivos de remessa e retorno bancários |
| Upload de nota (PDF, XML) | Arquivo do fornecedor |
| Leitura da nota por IA | Texto gerado pelo modelo a partir de um PDF que qualquer fornecedor escreve |
| CRM e BKM Terrenos | Dado de outro sistema |
| Portal do PJ (desenhado, 7/nov/2026) | Nota fiscal (PDF/XML) enviada pelo próprio prestador |
| Portal do contador (desenhado, 7/nov/2026) | Login de fora da BKM lendo notas e retenções dos PJ |

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
| S-011 | Média (risco aceito pelo Moises, 7/nov/2026) | Folha PJ no livro e no BI | A folha PJ entra somada por centro de custo e mês. Num centro com um PJ só (ou com o rateio de um PJ só numa SPE), a soma é a remuneração dessa pessoa, visível a quem lê o livro ou o BI daquele centro. A proposta de juntar grupos com menos de três PJ foi recusada pelo Moises ("pode deixar só os do centro de custos mesmo") | Aceito como está. O que ainda reduz a exposição sem mudar a decisão: quando houver RLS (S-003), limitar quem lê a natureza da folha PJ por centro; nunca mandar essas linhas a IA nem a planilha exportada sem filtro. Reavaliar se o acesso ao BI se abrir além da diretoria | 7/nov/2026 |
| S-010 | Alta (limitação aceita pelo Moises, 7/nov/2026) | PJ durante a transição | Enquanto os pagamentos PJ passarem pelo Sienge, credor, CNPJ, nota e valor de cada PJ ficam lá, visíveis a quem acessa o contas a pagar do Sienge. Pior: o nosso espelho (`sienge_bruto` e `sienge`) copia esses títulos e credores, e daí para o `nucleo`, o livro e o BI, o que anula o esquema pessoal antes mesmo de ele existir. A Nexxera recebe e devolve arquivos com CPF ou CNPJ, chave PIX e valor | No Sienge: restringir pelos perfis de usuário quem vê os credores ou o tipo de documento dos PJ. No espelho: marcar os credores PJ e gravar os títulos deles (bruto incluído) numa área restrita, sem ir para o livro por pessoa nem para o BI (só a soma por centro e mês). Nexxera: credenciais e certificado só no Vault; arquivos de remessa e retorno gravados só no esquema pessoal, nunca numa pasta comum. Reavaliar quando o Sienge sair. **Situação (7/nov):** proposta aprovada pelo Moises (credores PJ marcados, títulos em área restrita, livro e BI só com a soma por centro e mês); a nota do PJ é conferida pelo sistema contra SPE, % e valor do cadastro mensal. Falta construir; vale para o primeiro código do espelho | 7/nov/2026 |
| S-008 | Alta (desenho; parte do master aceita pelo Moises, 7/nov/2026) | Conferência em duas chaves dos PJ ([06](06-decisoes.md)) | O master vê tudo, troca o aprovador e também aprova. Assim uma pessoa só pode se pôr como substituta das duas chaves (ou aprovar pelas duas) e liberar o pagamento sozinha: as duas chaves viram uma. O mesmo vale para um substituto temporário que já é o outro responsável. E "estando tudo ok com as duas tabelas, vai direto para pagamento" depende de a conferência ser feita pelo sistema, não pela nota que o PJ enviou | No banco: o mesmo usuário nunca dá os dois checks do mesmo mês, nem como substituto nem como master; troca de aprovador ou substituto só vale para o mês seguinte, ou exige o aval do outro responsável, e sempre avisa os dois e fica no log; substituição com data de fim. O valor a pagar vem da tabela de remuneração, nunca da nota: nota com valor ou CNPJ diferente do cadastro trava e vai para os responsáveis. Teste por papel cobrindo master e substituto. **Situação (7/nov):** o Moises aceitou que o master (só ele) aprove tudo, inclusive as duas chaves; as demais regras (substituto nunca dá os dois checks, troca com aviso, valor da tabela e não da nota) ele aprovou. Controles que compensam sem bloquear: quando o master dá os dois checks ou troca um aprovador, isso fica marcado no log e destacado no histórico, e o responsável titular é avisado; o papel de master só se dá ou tira por migration ou pelo próprio master, sempre auditado e avisado; conta do master pessoal, com segundo fator no Google, nunca compartilhada, e a chave de serviço nunca vale como master. O Moises terá duas contas (7/nov/2026): uma normal, do dia a dia, e uma de master, usada só para o que exige master, com segundo fator próprio. As duas ficam ligadas à mesma pessoa no cadastro, e as regras de separação (quem lança não aprova, os dois checks, aprovar o próprio pedido) conferem a pessoa, não a conta; a exceção é o master aprovando, marcada no log. Teste: lançar com a conta normal e aprovar com a de master conta como a mesma pessoa e fica marcado. Fica no desenho dos PJ, adiado até o Sienge sair | 7/nov/2026 |
| S-009 | Média (desenho) | Aprovação como regra-dado | A marca "substitui as gerais" permite que uma regra específica afrouxe as regras gerais. Quem puder criar ou editar regra pode tirar a própria despesa da aprovação (por exemplo, uma regra para o seu fornecedor, com uma camada só, marcada como substituta). No rateio, partir um valor em pedaços pequenos pode deixar cada parte abaixo da faixa que pede aprovação | Criar, editar ou marcar uma regra como substituta exige aprovação de outra pessoa (a mesma lógica das alçadas), com auditoria e efeito só daqui para frente; uma regra substituta nunca tem menos camadas que as gerais que ela substitui, ou isso é recusado; faixa de valor conferida também pelo total do lançamento e pelo acumulado no mês, não só por parte do rateio; quem lança nunca aprova o próprio lançamento. **Situação (7/nov):** a thread do banco aceitou as três primeiras regras e quem lança não aprova; o acumulado no mês está em discussão com o Moises. **Aprovadores nomeados** (decisão do Moises, 7/nov/2026: a camada aponta para pessoas, não para papéis). Proposta para quem construir, [A decidir] com o Moises: a função que decide confere na hora que o aprovador está ativo; quem sai da empresa perde a aprovação no mesmo ato de desligar a conta, e as camadas dele ficam marcadas "sem aprovador" e vão para o master, nunca para "qualquer um" nem aprovadas sozinhas; ausência é um substituto com data de início e de fim, dado pelo próprio aprovador ou pelo master, com aviso e log; o substituto nunca é quem lançou; se o aprovador nomeado for quem lançou, a camada passa ao substituto ou ao master; trocar o aprovador de uma regra é configuração (auditada, com o aval da S-009) e não muda pedidos já abertos | 7/nov/2026 |
| S-007 | Alta (desenho) | Esquema pessoal dos PJ ([03](03-banco-de-dados.md), 3.3) | O pseudônimo não esconde a pessoa como o desenho supõe: (a) a chave PIX que vai ao `nucleo` costuma ser CPF, e-mail ou celular, e identifica a pessoa; (b) o valor por pseudônimo no livro e em `v_lancamentos_bi` revela a remuneração de cada um a quem lê o BI, e numa equipe pequena valor + data identificam; (c) a nota fiscal do PJ traz CNPJ, nome e valor, e hoje iria para `documentos_fiscais` do `nucleo`; se o pagamento passar pelo Sienge, o credor lá tem nome e CNPJ; (d) a resposta crua do extrato tem os nomes e não pode ir para nenhuma área bruta compartilhada; (e) o Postgres não audita `select`: leitura auditada só existe se a tabela não tiver `grant` a ninguém e a leitura for por função `security definer` que grava o log antes de devolver; e o log não pode ser apagável pelos próprios masters; (f) a criptografia na coluna protege backup, cópia e `grant` errado, não quem tem a chave de serviço ou o dono do banco, se a chave de decifrar estiver no mesmo banco | Chave PIX e documento só no esquema pessoal; o `nucleo` guarda o pseudônimo e uma referência de pagamento. No livro e no BI, a folha PJ entra somada por natureza e mês, sem linha por pessoa (ou com RLS que só os responsáveis passam). Nota do PJ e retenções no esquema pessoal, com o contador lendo por função; decidir se esses pagamentos passam pelo Sienge. Extrato cru gravado só no esquema pessoal. Leitura só por função que registra quem leu; log em tabela que só cresce, revisado por quem não é master. Chave de decifrar fora do banco (Vault, lida pela função) e nunca no `service_role` comum. Preferir pseudônimo aleatório com tabela de ligação no esquema pessoal (sem chave para vazar) ao HMAC. **Situação (7/nov):** (a), (d), (e), (f) e o pseudônimo aleatório entraram no desenho; (b) e (c) decididos pelo Moises: folha somada por centro e mês; notas e retenções só no esquema pessoal, pelo portal do contador (ver "A conferir"). Soma de centro com um PJ só: ver S-011. Conferir tudo quando houver código | 7/nov/2026 |
| S-005 | Baixa | `nucleo.sistema()` + auditoria | O que uma rotina do sistema faz (chave de serviço, pg_cron) fica na auditoria e no livro sem autor (`por` nulo). Quando o adaptador agir por pedido de alguém (ex.: lançar a nota que um analista aprovou), não fica registrado quem pediu | O adaptador grava o autor do pedido na fila de envio e passa esse autor às funções (parâmetro ou configuração de sessão lida pela auditoria), com teste | 7/nov/2026 |
| S-003 | Alta (bloqueia o primeiro `grant`) | Todo o `nucleo` | Não há RLS em nenhuma tabela. Hoje o esquema está fechado a `anon` e `authenticated`, então não é explorável. No primeiro `grant` para as telas, qualquer usuário logado leria tudo, de todas as empresas, inclusive folha e movimentos entre sócios | Criar a RLS no mesmo PR do primeiro `grant`, com teste por papel e por empresa ou empreendimento. Preferir dar `grant` só em funções e visões, não nas tabelas | 7/nov/2026 |

## A conferir quando o código existir

Ainda não há código para revisar nestes pontos; ficam como requisito para quem construir:

- **Recebedor de webhooks do Sienge:** a documentação não fala de assinatura. Exigir o token cadastrado, recusar o resto, gravar `x-sienge-id` com chave única, nunca confiar no corpo (sempre reler pela API), limitar o tamanho do corpo e a taxa.
- **Adaptador do Sienge:** senha da API só no Vault, lida pelo servidor; nunca em log, erro devolvido ao navegador ou `sienge_bruto`. Registro de cada chamada sem o cabeçalho `Authorization`.
- **Upload de notas (PDF/XML):** limite de tamanho e tipo, armazenamento com caminho que a RLS do Storage confere, XML lido sem entidades externas (XXE), o texto lido por IA tratado como dado e não como instrução.
- **Telas:** nada de chave de serviço no navegador; só a chave publicável.
- **Rotinas do servidor (commit `f659cfe`):** contam como sistema a conexão direta ao Postgres, o pg_cron e a chave de serviço (papel `service_role`, pela API do Supabase). A chave de serviço passa em todas as checagens de papel e, no Supabase, também ignora a RLS: vazou, vale tudo. Ela fica só no servidor (Vault ou segredo da Edge Function), nunca no navegador, em log ou no repositório.
- **Portal do PJ (desenhado, 7/nov/2026):** acesso externo que recebe arquivo. Vale o item 5 do checklist (tipo pelo conteúdo, tamanho, XML sem entidades externas, caminho conferido no Storage) e o item 6 se a nota for lida por IA. O PJ só vê e envia as próprias notas e nunca vê a remuneração de outro (nem o valor cadastrado, se não for preciso). Uma conta por PJ, com segundo fator, desligada quando ele sair do cadastro de ativos. Se a NFS-e tiver XML, conferir pela chave na prefeitura, não pelo PDF.
- **Portal do contador (desenhado, 7/nov/2026):** é o primeiro acesso de fora da BKM, e o login do projeto hoje é só Google do Workspace. Requisitos: conta por pessoa (nunca login compartilhado do escritório), com segundo fator; papel próprio que só executa as funções de leitura das notas e retenções, sem `grant` em tabela; escopo pelas empresas que o contador atende; arquivo entregue por link assinado de poucos minutos, gerado pela função que grava o download no log; limite de taxa e de volume para notar download em massa; desligar o acesso no mesmo dia em que o contrato acabar, com revisão periódica de quem ainda entra; mensagem de erro sem detalhe interno. LGPD: o escritório contábil precisa de contrato que cubra os dados pessoais.
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
| 7/nov/2026 | Desenho do esquema pessoal dos PJ (sem código): anotada a S-007 | não se aplica |
| 7/nov/2026 | Duas chaves dos PJ, portais e aprovação como regra-dado (sem código): anotadas a S-008 e a S-009 | não se aplica |
| 7/nov/2026 | PJ pelo Sienge na transição e Nexxera: anotada a S-010 | não se aplica |
| 7/nov/2026 | Soma da folha PJ por centro com um PJ só: S-011, risco aceito | não se aplica |
| 7/nov/2026 | Master aprova as duas chaves: parte da S-008 aceita, com controles que compensam | não se aplica |
