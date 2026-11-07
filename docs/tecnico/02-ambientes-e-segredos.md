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
| Banco de desenvolvimento (Supabase) | Não criado **[A decidir]** |
| Banco de produção | Será o projeto Supabase BKM_Desenvolvimento_Imobiliario (mesmo do BKM Terrenos e do monitor de mercado). Nenhum esquema deste projeto aplicado |
| Sienge | Só existe a base de produção da BKM conhecida (`bkmincorporadora`). Não sabemos se há base de testes do Sienge **[A decidir]** |
| Front | Não criado |

Enquanto não houver base de testes do Sienge, todo teste de escrita é feito **na produção do Sienge**, com valores de R$ 1,00 a R$ 1,50, observação "TESTE API Claude" e no contrato de teste CTP/28 (ver [04-integracao-sienge.md](04-integracao-sienge.md)).

### Conta do Supabase [Testado pela API do Supabase, 7/nov/2026]

- Organização BKM no plano **Pro**. Projetos: `bkm_tarefas`, `BKM_Desenvolvimento_Imobiliario` e `BKM_autodoc`, todos em `sa-east-1`, Postgres 17.
- O Pro não tem SLA de disponibilidade (só o Enterprise). Recuperação para um instante (PITR) é adicional (cerca de US$ 100/mês, 7 dias) e não cobre os arquivos do Storage: a cópia dos arquivos precisa ser feita à parte.
- Os testes do `nucleo` rodam em Postgres 16 (`run.sh`); o projeto é 17. **[A conferir]** rodar a suíte em 17 antes de aplicar.

## Rede

- `api.sienge.com.br` liberado na rede do ambiente de nuvem do Claude desde 6/nov/2026.

## Segredos

Nenhum valor de segredo é escrito no repositório, em documento ou no chat.

| Segredo | Para quê | Onde mora hoje | Onde vai morar |
| --- | --- | --- | --- |
| Usuário e senha da API do Sienge | Autenticação Basic nas chamadas à API | Segredo do tipo **Basic** no ambiente de nuvem do Claude (Project settings › ambiente), restrito ao host `api.sienge.com.br` e ao prefixo `/bkmincorporadora/`. O proxy do ambiente injeta a autenticação; a senha nunca passa pela sessão | Vault do Supabase, lido só pelo adaptador **[Desenhado]** |
| Token do webhook do Sienge | Conferir que o aviso veio do Sienge | Não criado | Vault do Supabase. A documentação não diz como o token chega ao nosso servidor: testar ao cadastrar o primeiro webhook |
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
