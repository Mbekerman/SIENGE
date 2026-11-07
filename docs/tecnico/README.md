# Documentação técnica do ERP BKM (as built)

Documentação para desenvolvedores e administradores do sistema que a BKM está construindo em volta do Sienge. Funciona como o "as built" de uma obra: é atualizada ao longo do desenvolvimento e descreve o que **existe de fato**, separado do que ainda é só desenho.

O manual do usuário (regras de negócio, telas, fluxos para quem usa) é outro documento. Aqui só entra o que alguém precisa para manter, operar ou evoluir o sistema.

## Situação em 7/nov/2026

O único código escrito é o esquema `nucleo` v0 (SQL e testes), num branch ainda não integrado. Nenhum banco, servidor ou tela existe.

| O quê | Situação |
| --- | --- |
| Cópia da documentação da API do Sienge (`Mbekerman/sienge-api-docs`) | Construído, com scripts de atualização |
| Acesso à API do Sienge da BKM (usuário de API, segredo no ambiente de nuvem do Claude) | Construído e testado |
| Testes manuais da API no contrato CTP/28 (6/nov/2026) | Feitos; resultados em [04-integracao-sienge.md](04-integracao-sienge.md) |
| Núcleo do ERP BKM (esquema `nucleo`: 42 tabelas, regras em funções, 108 testes) | Construído no branch `claude/project-thread-dknc98` (7/nov/2026; commits até `89c1202`); não integrado na `develop`, não aplicado em banco nenhum |
| Banco espelho do Sienge (camadas `sienge_bruto` e `sienge`) | Desenhado e aprovado pelo Moises (7/nov/2026); não criado |
| Contas a pagar: envio ao Sienge, leitura de PDF, aprovação, telas | Desenhado; não construído |
| Banco Supabase, adaptador (servidor), front, CI, deploy | Nada criado |

## Como ler

Cada afirmação leva uma destas marcas:

- **[Construído]**: existe e está em uso. Diz onde está.
- **[Testado]**: comportamento conferido na prática (API do Sienge, banco), com data.
- **[Desenhado]**: decidido ou proposto, ainda sem código. Diz se o Moises já aprovou.
- **[A decidir]**: pergunta aberta. Fica também em [07-pendencias.md](07-pendencias.md).

## Índice

1. [Visão geral e arquitetura](01-arquitetura.md)
2. [Ambientes, repositórios e segredos](02-ambientes-e-segredos.md)
3. [Banco de dados](03-banco-de-dados.md)
4. [Integração com a API do Sienge](04-integracao-sienge.md)
5. [Fluxo técnico do contas a pagar](05-contas-a-pagar.md)
6. [Registro de decisões](06-decisoes.md)
7. [Pendências, riscos e lixo de teste](07-pendencias.md)
8. [Segurança: revisões e falhas](08-seguranca.md)

## Fontes

- Threads do projeto SIENGE no Claude: "Desenhar ecossistema em volta do SIENGE" (6/nov/2026) e "Desenhar o banco do ERP BKM" (6 e 7/nov/2026).
- Documentos de desenho (Claude Docs):
  - [Ecossistema em volta do Sienge: levantamento da API e projeto](https://claude.ai/artifact/NYYXN6TeeCscmPrKoToLz4)
  - [Banco espelho do Sienge: desenho pela API](https://claude.ai/artifact/EgDt6HJJREERJBsYKrvLsE)
  - [Núcleo do ERP BKM: modelo v1](https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt)
- Documentação oficial da API: `Mbekerman/sienge-api-docs` (coleta de 6/nov/2026, YAMLs em `oficial/yaml-files/`).
- BKM Terrenos (`Mbekerman/bkm_terrenos-claude`): stack, convenções e o projeto Supabase compartilhado.

Quando um documento de desenho e este repositório divergirem, vale o que estiver mais recente; se for o documento de desenho, este repositório deve ser corrigido.

## Como manter

1. **Toda mudança que altera o sistema atualiza esta pasta no mesmo PR.** Migration nova → [03-banco-de-dados.md](03-banco-de-dados.md). Chamada nova à API do Sienge ou comportamento descoberto → [04-integracao-sienge.md](04-integracao-sienge.md). Variável de ambiente ou segredo novo → [02-ambientes-e-segredos.md](02-ambientes-e-segredos.md). Decisão → [06-decisoes.md](06-decisoes.md). Código novo passa pela revisão de segurança e entra no histórico de [08-seguranca.md](08-seguranca.md).
2. Ao construir algo que estava **[Desenhado]**, troque a marca para **[Construído]** e aponte o arquivo, a função ou a tabela. Se o construído ficou diferente do desenho, descreva o que foi feito e registre a mudança em [06-decisoes.md](06-decisoes.md).
3. Nunca escreva valor de senha, token ou chave aqui. Escreva o **nome** do segredo e onde ele mora.
4. Datas por extenso no formato dia/mês/ano (7/nov/2026). Idioma: português.
5. O histórico de mudanças desta documentação é o histórico do git desta pasta.
