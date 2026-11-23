# 2. Ambientes, repositórios e segredos

## Repositórios

| Repositório | Conteúdo | Situação |
| --- | --- | --- |
| `Mbekerman/SIENGE` | Código do ERP BKM (adaptador, núcleo, módulos) e esta documentação | **[Construído]** só com a documentação (7/nov/2026) |
| `Mbekerman/sienge-api-docs` | Cópia da documentação pública da API do Sienge, para consulta | **[Construído]** (coleta de 6/nov/2026) |
| `Mbekerman/bkm_terrenos-claude` | BKM Terrenos; referência de stack, visual e convenções | Em desenvolvimento |

### `sienge-api-docs` [Construído]

- `oficial/`: arquivos publicados pelo Sienge, byte a byte (91 especificações YAML em `oficial/yaml-files/`, 368 operações, 104 eventos de webhook). Conferido contra o site em 6/nov/2026: 211 arquivos idênticos.
- `INDICE.md` (por área), `OPERACOES.md` (por método e caminho), `COBERTURA.md`, `fontes.json` (URLs de origem), `SHA256SUMS`.
- `guias/`: guias gerais em Markdown (URL, autenticação, limites, pacotes, webhooks, status).
- `scripts/atualizar.sh`: baixa tudo de novo (`baixar.py`), extrai recursos (`recursos.py`), refaz os índices (`catalogar.py`) e troca as pastas. **Rotina recomendada:** rodar todo mês e revisar o diff, porque o Sienge pode mudar a API sem aviso.

## Fluxo de branches

Igual ao BKM Terrenos (instruções do projeto):

- `develop` = ambiente de desenvolvimento; `main` = produção.
- Todo trabalho num branch próprio, com PR para `develop`. Produção só por PR `develop → main`, quando o Moises pedir. Nada de PR direto na `main`, salvo correção urgente (que depois volta para a `develop`).

`main` e `develop` foram criadas em 7/nov/2026, com o aval do Moises, a partir do commit inicial vazio `5c88264`. **Pendente:** o branch padrão do GitHub ficou sendo um branch de trabalho (o primeiro enviado); trocar para `main` em Settings › General.

## Ambientes

| Ambiente | Situação |
| --- | --- |
| Banco de desenvolvimento (Supabase) | **[Construído, 14/nov/2026]** Projeto `bkm_dev` (ref `zwxvmotxnjvnoigroqds`, `sa-east-1`, Postgres 17.11), base comum a todos os sistemas, com um esquema por sistema (`erp` agora; `terrenos` depois). Esquema `erp` da `develop` aplicado: 47 tabelas com RLS forçado, nenhum privilégio para `anon`, `authenticated`, `service_role`, `authenticator` nem `PUBLIC`. Risco aceito: os sistemas do `bkm_dev` dividem o mesmo Auth. Regra (Moises, 14/nov/2026): **só dados de teste** no `bkm_dev`. Registro completo em `/mnt/project-files/erp-bkm/dev/bkm_dev_registro.md` |
| Banco de produção | Projeto Supabase **próprio do ERP**, separado do BKM_Desenvolvimento_Imobiliario (decisão do Moises, 7/nov/2026). Ainda não criado: nasce quando as tabelas forem para um banco |
| Sienge | Só existe a base de produção da BKM conhecida (`bkmincorporadora`). Não sabemos se há base de testes do Sienge **[A decidir]** |
| Front | Não criado |

Enquanto não houver base de testes do Sienge, todo teste de escrita é feito **na produção do Sienge**, com valores de R$ 1,00 a R$ 1,50, observação "TESTE API Claude" e no contrato de teste CTP/28 (ver [04-integracao-sienge.md](04-integracao-sienge.md)).

### Conta do Supabase [Testado pela API do Supabase, 7/nov/2026]

- Organização BKM no plano **Pro**. Projetos: `bkm_tarefas`, `BKM_Desenvolvimento_Imobiliario` e `BKM_autodoc`, todos em `sa-east-1`, Postgres 17.
- O Pro não tem SLA de disponibilidade (só o Enterprise). Recuperação para um instante (PITR) é adicional (cerca de US$ 100/mês, 7 dias) e não cobre os arquivos do Storage: a cópia dos arquivos precisa ser feita à parte.
- Cópias (decisão do Moises, 7/nov/2026): por ora só a cópia diária do Pro; PITR quando o ERP mandar pagamentos reais; proposta de cópia extra a cada hora no Google Cloud (requisitos em [08](08-seguranca.md), S-018).
- Os testes do `erp` rodam em Postgres 16 (`run.sh`); o `bkm_dev` é 17.11. A suíte usa `\gset` e não roda pela ferramenta do Supabase: no remoto, em 14/nov, só se fizeram as conferências de catálogo. **[A conferir]** rodar a suíte em Postgres 17.
- **Aplicar o `erp` no Supabase** (14/nov/2026): lá o `postgres` não é superusuário, e o `ALTER FUNCTION ... OWNER` da `000500` falha sem um preparo, que se faz antes e se desfaz no fim: conceder `erp_conferencia`, `erp_situacao` e `erp_reclassificacao` ao `postgres` e `CREATE` no esquema `erp` aos papéis donos. Proposta: levar o preparo para a própria `000500`. O `postgres` fica com ADMIN OPTION sobre os papéis `erp_*` (padrão do Postgres 16 ou mais novo para quem cria o papel): quem tem a senha do banco pode se conceder esses papéis e agir como as funções donas, o que é o poder normal de administrador do banco.

### Onde moram os segredos [Desenhado, 7/nov/2026]

Segredos sensíveis do ERP (senha da API do Sienge, credenciais e certificado da Nexxera, chave do esquema pessoal dos PJ) ficam no **Secret Manager do Google Cloud**, lidos só pelo servidor que usa cada um. O Vault do Supabase não serve para eles enquanto o projeto for compartilhado (ver [08](08-seguranca.md), S-015).

## Rede

- `api.sienge.com.br` liberado na rede do ambiente de nuvem do Claude desde 6/nov/2026.

## Segredos

Nenhum valor de segredo é escrito no repositório, em documento ou no chat.

| Segredo | Para quê | Onde mora hoje | Onde vai morar |
| --- | --- | --- | --- |
| Usuário e senha da API do Sienge | Autenticação Basic nas chamadas à API | Segredo do tipo **Basic** no ambiente de nuvem do Claude (Project settings › ambiente), restrito ao host `api.sienge.com.br` e ao prefixo `/bkmincorporadora/`. O proxy do ambiente injeta a autenticação; a senha nunca passa pela sessão | Vault do Supabase, lido só pelo adaptador **[Desenhado]** |
| `sienge_aviso_token` (token do webhook do Sienge) | Conferir que o aviso veio do Sienge: chega como `Authorization: Bearer <token>` (teste de 17/nov/2026) e o recebedor `sienge-aviso` compara em tempo constante | Ainda não criado; vai no Vault do `bkm_dev` (aleatório, 48 caracteres ou mais) e no cadastro do webhook no Sienge (`POST /hooks`), com o ok do Moises | Secret Manager do Google Cloud ou o cofre do projeto de produção (regra de portabilidade de 14/nov). Trocar = novo token no Vault e novo cadastro no Sienge |
| `asaas_chave` (Vault do `bkm_dev`) | A Edge Function `conferir-pagamento` (antes `pix-conferir`) pergunta ao Asaas quem recebe pelo PIX copia e cola (`POST /v3/pix/qrCodes/decode`) e o beneficiário do boleto (`POST /v3/bill/simulate`) | A mesma chave da conta sem saldo do leitor (`asaas-chave` no Secret Manager), copiada pelo Moises para o Vault (20/nov/2026) | Cofre do projeto de produção. Trocar = nova chave no Asaas, no Secret Manager e no Vault |
| `SIENGE_USUARIO`, `SIENGE_SENHA` (teste da carga) | GET do programa de carga do histórico | Segredos da Edge Function `sienge-carga` no `bkm_dev` (Edge Functions › Secrets), criados pelo Moises em 17/nov/2026 | Cofre do projeto de produção do ERP (ver S-115) |
| `sienge_carga_chave` | Chave com que o pg_cron chama a função `sienge-carga` | Vault do `bkm_dev`, gerada aleatória pelo próprio SQL (nunca escrita em lugar nenhum) | Idem na produção |
| `SIENGE_USUARIO`, `SIENGE_SENHA` (envio) | Gravação do título, das parcelas e da forma de pagamento (`servicos/sienge-escrita`) | Ainda não criados para a função `sienge-escrita`; o teste de 17/nov rodou no ambiente de nuvem do Claude (proxy) | Cofre do projeto de produção do ERP (ver S-115) |
| `ASAAS_CHAVE` (leitor de notas) | Consultar o boleto no Asaas (`/v3/bill/simulate`), `servicos/leitor` | Secret Manager do `bkm-erp-515119`, segredo `asaas-chave` (réplica em São Paulo), lido só pela conta `erp-leitor`; a chave é posta pelo Moises no Console, nunca no chat | O mesmo segredo no serviço de produção |
| Claude (leitor de notas) | Ler PDF e foto | Sem chave: federação de identidade da Anthropic, token da conta `erp-leitor` pelo servidor de metadados; regra `erp-leitor-dev` no Console da Anthropic (IDs `ANTHROPIC_*` não são segredo). O job `erp-leitor-lote` (teste em escala, `servicos/leitor/lote.ts` e `lote-dev.sh`, 20/nov/2026) usa a mesma conta e a mesma regra, lê `gs://bkm-erp-515119-anexos-dev/lote/entrada/` e grava em `lote/saida/`, sem banco e sem consultar boleto Desde 23/nov/2026 aceita `LOTE_MODELO` (outro modelo, para comparar; sem a troca de modelo do servidor) e `LOTE_SAIDA` (pasta da rodada, `lote/<nome>/`, que a regra dos 7 dias também apaga). | Regra própria para o serviço de produção |
| `SIENGE_AMBIENTE` (não é segredo) | Só a palavra exata `producao` libera gravar fora da empresa de teste; ausente ou outra palavra é teste | Não definido em lugar nenhum (teste) | Só na produção |
| `SIENGE_CREDORES_TESTE` (não é segredo) | Credores de teste aceitos pela trava em teste, separados por vírgula | Padrão 823 no código | |
| `GOOGLE_PLANILHA_CHAVE` | Era o JSON da chave da conta de serviço da planilha das PRV a apagar | **Não será criado**: a planilha foi trocada pela página (18/nov/2026) | |
| `PLANILHA_PRV_ID` (não é segredo) | Era o id da planilha das PRV a apagar | **Não será criado** (18/nov/2026) | |
| `PAGINA_SUPABASE_URL`, `PAGINA_SUPABASE_CHAVE` (não são segredo) | Endereço do Supabase e chave **publicável** (`sb_publishable_…`) que a página das PRV a apagar usa no navegador; o workflow `pagina.yml` recusa outro formato (chave secreta ou `service_role` não passam) | Variáveis do repositório no GitHub (Settings › Secrets and variables › Actions › Variables), a criar pelo Moises | Idem, apontando para a produção |
| Cliente OAuth do Google (id e segredo) | Login Google da página das PRV no Supabase Auth | O cliente "Interno" do Workspace no projeto `bkm-terrenos` do Google Cloud; o segredo fica só em Authentication › Providers › Google do `bkm_dev`, colado pelo Moises | Idem na produção |
| `sienge_escrita_chave` | Chave com que o pg_cron chama a função `sienge-escrita` | Ainda não criada (`supabase/dev/sienge_escrita_agenda.sql` cria) | Idem na produção |
| `adn-cert-pfx`, `adn-cert-senha` (teste do ADN) | Certificado A1 da BKM 03 (.pfx em base64) e a senha, para o job `erp-teste-adn` (`servicos/teste-adn`) se identificar no Ambiente de Dados Nacional da NFS-e e só LER as notas recebidas (teste aprovado pelo Moises em 20/nov/2026) | Secret Manager do `bkm-erp-515119` (réplica em São Paulo), criados pelo Moises com `servicos/teste-adn/rodar-dev.sh` (valor nunca na linha de comando, no chat, em e-mail ou na pasta do projeto). Lidos só pela conta `erp-teste-adn`, que não tem papel nenhum no projeto, só `secretAccessor` nesses dois segredos; além dela, só o Moises. **Nunca** dar a essa conta papel de deploy; a conta compute (que roda o build) não pode ter papel que leia todos os segredos, e o script para se tiver. Escolha do Moises em 21/nov/2026, depois da revisão do #117: os secrets das Edge Functions valem para o `bkm_dev` inteiro, compartilhado por todos os sistemas. Um A1 vazado assina em nome da empresa | Apagados no fim do teste (`rodar-dev.sh --apagar` apaga job, segredos e conta). Se a busca de notas for construída, a guarda definitiva se decide à parte. O A1 da BKM 03 é PKCS#12 com cifra antiga, que o Node 22 só lê com `--openssl-legacy-provider` (aceito só neste job único, 23/nov/2026). No serviço definitivo, nada de provedor legado: converter o PFX uma vez para AES antes de guardar (`openssl pkcs12 -legacy -in a.pfx -nodes | openssl pkcs12 -export -keypbe AES-256-CBC -certpbe AES-256-CBC`), num lugar efêmero, apagando o intermediário |
| Chaves do Supabase, do Google e de leitura de PDF por IA | | Não criadas | A definir com o servidor |

### Dados da conta de API do Sienge (sem segredo)

- Endereço do Sienge: `bkmincorporadora` (acesso web `bkmincorporadora.sienge.com.br`).
- Usuário de API: `bkmincorporadora-apibkm` ("Nome de acesso" no Painel de Integrações, descrição APIBKM). É um usuário próprio da API, não o e-mail de login de alguém.
- URL REST: `https://api.sienge.com.br/bkmincorporadora/public/api/v1/{recurso}`.
- URL Bulk Data: `https://api.sienge.com.br/bkmincorporadora/public/api/bulk-data/v1/{recurso}`.
- Sem senha, a API responde 401; com subdomínio inventado, 404 (é assim que se confirma o subdomínio).
- No Sienge, ações feitas pela API aparecem com o responsável "Sienge Api".
- **Trocar a senha** ("Gerar nova senha" no Painel de Integrações) derruba qualquer sistema que use esse usuário. Antes de trocar, atualizar o segredo em todos os lugares da tabela acima.
- Permissões do usuário em "Autorizações do Usuário de API" no Painel de Integrações. Para o contas a pagar precisam estar liberados: contratos de suprimentos, medições, títulos a pagar, credores e webhooks.
