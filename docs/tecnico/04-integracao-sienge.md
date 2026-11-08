# 4. Integração com a API do Sienge

Fonte de verdade da API: os YAMLs em `Mbekerman/sienge-api-docs/oficial/yaml-files/` (coleta de 6/nov/2026). Antes de prometer um comportamento, confira no YAML; os guias gerais estão em `guias/` do mesmo repositório. Esta página junta o que a documentação diz com o que **foi testado na base da BKM**.

## 4.1 Conexão [Testado, 6/nov/2026]

| Item | Valor |
| --- | --- |
| REST | `https://api.sienge.com.br/bkmincorporadora/public/api/v1/{recurso}` |
| Bulk Data (massa) | `https://api.sienge.com.br/bkmincorporadora/public/api/bulk-data/v1/{recurso}` |
| Autenticação | Basic, usuário de API `bkmincorporadora-apibkm` (senha: ver [02](02-ambientes-e-segredos.md)) |
| Paginação | listas de 200 em 200 |
| Responsável nas ações | aparece como "Sienge Api" no Sienge |

## 4.2 Limites (`guias/limites-de-requisicoes-rate-limits.md`, `guias/pacotes-de-apis.md`)

- Por minuto, por subdomínio, somando **todos** os sistemas que usam a API da BKM (CRM incluído): 200 REST e 20 Bulk. Estourou: `429 Too Many Requests`.
- Por dia, conforme o pacote: REST de 100 (Free) a 200.000 (Infinity); Bulk de 10 a 40.000, com bloqueio ao estourar.
- **O pacote contratado pela BKM ainda não é conhecido** [A decidir]. Ele decide se a cópia diária completa cabe no dia.
- **Testado em 8/nov/2026, 19h55:** depois de umas 3 chamadas só de leitura, o Sienge respondeu `429` com `Ratelimit-Limit: 200`, `X-Ratelimit-Remaining-Minute: 0`, `X-Ratelimit-Limit-Second: 100` e `Retry-After: 36`. Isso confirma que a cota de 200 por minuto é do subdomínio, dividida entre as integrações, e que outra integração (provavelmente o CRM) gastava quase toda. Também existe um limite por segundo (100). Para o adaptador: fila com nova tentativa que respeita o `Retry-After` (a nova tentativa de `POST /bills` passa pela idempotência da S-021); criar título e gravar pagamento têm prioridade sobre as leituras do espelho; leitura pesada pela API em massa ou fora do horário. Falta saber quanto o CRM consome e em que horários.
- **De-para para o envio (passo 1, transição):** cada combinação centro × área × natureza do nosso lado tem de mapear para exatamente uma conta e um centro do Sienge, numa tabela de mapeamento aprovada; o envio recusa o pedido sem mapeamento ou com mais de um. A empresa 1 do Sienge é a Muchmore Tecnologia (centros SSG, SSB e FCA); falta saber se ela entra no ERP.
- `GET /purchase-orders` funciona (testado em 8/nov: 556 pedidos); casar com o pedido fica para o módulo de Compras.
- Custo típico: um título a pagar completo são ~6 chamadas REST (título, impostos, 3 apropriações, unidades), mais anexos e forma de pagamento. 500 títulos alterados num dia ≈ 3.000 chamadas.

## 4.3 O que a API faz e não faz (documentação, conferida em 6/nov/2026)

| Área | Escreve | Só lê ou aprova | Não tem |
| --- | --- | --- | --- |
| Títulos a pagar (`bill-debt-v1.yaml`) | `POST /bills`; `POST /eletronic-invoice-bills` (NF-e capturada da SEFAZ); alterar documento e parcelas; forma de pagamento da parcela (boleto, Pix, TED, DARF, GARE, FGTS, INSS, DDA); apropriações; unidades; anexos; dados fiscais (`tax-information-v1.yaml`) | lista por período, `/bills/by-change-date`, impostos (`/bills/{id}/taxes`), parcelas em massa (`bulk-data-parcelas-a-pagar.yaml`, `/outcome`) | autorizar pagamento, ciência, baixa, estorno, remessa, apagar título |
| Medições (`measurement-v1.yaml`) | criar medição de contrato existente (itens folha com quantidade; `makeUnauthorized`), anexos, autorizar, reprovar | medições, itens, liberação (`/supply-contracts/measurements/clearing`, devolve os títulos gerados) | **liberar medição**, apagar medição, medir por valor |
| Contratos de suprimentos (`contracts-v1.yaml`) | anexos, autorizar, reprovar | contrato, itens, obras, aditivos | criar ou mudar contrato, criar aditivo |
| Pedidos de compra | anexos, autorizar, reprovar, avaliar | pedido, itens, entregas, apropriações | criar pedido (só nasce por solicitação com acordo de preços ou negociação de cotação autorizada) |
| Notas de compra | cabeçalho + itens a partir de entrega de pedido | notas, NF-e recebidas da SEFAZ | nota sem pedido; **leitura de NFS-e recebida** |
| Credores | criar, mudar, dados bancários, Pix, ativar, desativar | lista | — |
| Cadastros de apoio | — | empresas, obras, centros de custo, planos financeiros, documentos, indexadores, contas | criar qualquer um; listar usuários; listar filiais |
| Contabilidade | lançamentos e lotes | contas, saldos, balancete | — |
| Comercial | clientes, unidades, reservas, contratos de venda, comissões | tabela de preços, saldo devedor, parcelas a receber | — |

## 4.4 Comportamentos testados na base da BKM

Testes feitos em 6/nov/2026 no contrato de teste **CTP/28**: empresa 2 (BKM Incorporadora e Construtora S.A.), obra 13 (Escritório Central BKMSP), credor 27, item 1 "vb" a R$ 1,00 por unidade.

| Teste | Resultado |
| --- | --- |
| Criar medição pela API (medição 2, R$ 1,50, "TESTE API Claude") | Funcionou; nasceu desautorizada |
| Anexar PDF na medição | Funcionou (201) |
| Autorizar pela API | Um único `PATCH authorize` deixou autorizada. Não se sabe se o contrato tinha os 2 níveis dos gestores; **trate como se a API pulasse os níveis**: a aprovação dos gestores tem de acontecer no nosso sistema antes da chamada |
| Consultar liberação antes de liberar | "Não existe liberação para a medição 2" |
| Liberação | **Manual, no Sienge** (feita pelo Moises). Gerou o título 8417 (origem ME, situação N, documento BLT 111, Pix do credor por padrão) |
| Título de medição (8417): mudar tipo e número do documento | Funcionou (BLT 111 → NFSE 112) |
| Título de medição: mudar vencimento da parcela | Funcionou (10/12/2026) |
| Título de medição: anexar PDF; ler Pix | Funcionou |
| `tax-information` no título | Bloqueado: exige CFOP, natureza do serviço e **código da filial** da empresa; nenhuma API lista filiais e 0, 1, 2, 3 foram recusados. Falta o código com a BKM |
| Título criado pela API (8422, PRV, R$ 1,00, origem SE = Sienge Api): mudar tipo, número ou valor | **Recusado**: "O Título com origem no SE não pode ser alterado para chamadas do SE". Só o vencimento mudou |
| Documento NFSE da BKM | Modelo 55, `blockDuplicateNumberForSameCreditor = false`: aceita número repetido do mesmo credor |
| Tipos de documento ativos com ciência no contas a pagar | Nenhum (6/nov/2026) |
| Tipos NFSE e PRV | Exigem unidade do empreendimento no título; despesa do escritório central vai precisar de unidade padrão |

Consequências que o código deve respeitar:

1. **Título lançado pela API nasce completo e certo** (número, valor, emissão, impostos). Depois só o vencimento muda. Empresa, credor, emissão, competência, observação, quantidade de parcelas e impostos retidos não mudam por API em nenhum título.
2. **Previsão no Sienge não vira título real.** As previsões ficam no nosso banco; título no Sienge só nasce quando a nota chega.
3. **Trava de duplicidade do nosso lado é obrigatória** (credor + tipo + número). Também protege contra nova tentativa após falha de rede, porque `POST /bills` não recusa repetição.
4. **Título nascido de medição aceita completar** documento, vencimento, forma de pagamento e anexo depois da liberação.
5a. **Passo 1, testes de 8/nov/2026:** `PATCH /bills/8422/installments/1/payment-information/pix` num título de origem SE devolveu **204**: o PIX foi gravado (`paymentTypeId` 14, `isUsingCreditorData` S) e a parcela passou a `paymentType` PIX. Ou seja, depois de criado o título aceita dados de pagamento, mas não aceita tipo, número nem valor (teste de 6/nov). O `BillInsert` aceita `taxes` (`BillTaxInsert`) já na criação. Continua sem API a autorização do pagamento no Sienge, que é manual. O anexo **tem** API: `POST /bills/{billId}/attachments` (`bill-debt-v1.yaml`, seção "Anexo do título"), testado no título 8417 em 6/nov. O `bill-debt-v1.yaml` não tem operação para bloquear ou suspender uma parcela. O título 8422 (com PIX, vencimento em 15/03/2027) precisa ser apagado à mão.
5. **Medição só por quantidade.** Valor da nota vira quantidade = valor ÷ preço unitário, com no máximo 4 casas. Com item a R$ 1,00 não há perda; com preço alto pode sobrar até alguns centavos (item de R$ 5.000,00 e nota de R$ 4.873,22 dá R$ 0,22 de diferença). O código deve avisar antes de lançar quando o valor não fechar.
6. **Os passos sem API são três:** liberação de medição, ciência e autorização de pagamento do título. O sistema acompanha por webhook e mostra o que espera ação no Sienge.

## 4.5 Webhooks (`guias/webhooks.md`, `hooks-v1.yaml`, `guias/webhooks-index.md`) [Desenhado; não cadastrado]

- Cadastro por `POST /hooks` com URL, eventos e token. 104 eventos.
- O Sienge espera 2,5 s pela resposta; depois tenta em 10 min, 30 min, 1 h, 3 h e 5 h, e desiste (~10 h). Aviso perdido não volta.
- Cabeçalhos: `x-sienge-tenant`, `x-sienge-event`, `x-sienge-hook-id`, `x-sienge-id` (único por evento: usar para não processar duas vezes), `user-agent: sienge-hooks`.
- O corpo traz só o identificador (ex.: `{ "billId": 123 }`). Sem assinatura documentada nem garantia de ordem; a documentação não diz como o token chega. **Testar no primeiro cadastro.**
- Faltam eventos de: título criado (vem pela parcela criada), medição criada, contrato criado ou alterado, aditivo, pedido criado à mão, nota de compra.
- Eventos úteis do contas a pagar: parcela criada/alterada/removida, autorização disponível e alterada, ciência pendente e feita, baixa feita/alterada/cancelada, estorno, medição autorizada/desautorizada, `CLEARING_*` (liberação finalizada e apagada), credor, movimento bancário.

Recebedor [Desenhado]: grava o aviso cru com `x-sienge-id` único, responde 200 na hora e enfileira; um processo separado relê o registro na API e atualiza `sienge_bruto` e `sienge`.

## 4.6 Sincronização do espelho [Desenhado]

Três pernas, porque o aviso sozinho não basta:

| Jeito | Entidades | Como |
| --- | --- | --- |
| Pelo que mudou | títulos a pagar (`/bills/by-change-date`), clientes e contratos de venda (`modifiedAfter`), parcelas a receber e saldo devedor (massa, `changeStartDate`) | guardar a data da última leitura |
| Janela de datas | parcelas a pagar e baixas (massa `/outcome`), movimentos bancários, notas, pedidos, medições, contratos, lançamentos contábeis | reler janela móvel (ex.: últimos 90 dias e próximos 365 de vencimento), comparar pela impressão digital |
| Inteiro | cadastros pequenos | diário ou semanal |
| Aviso | 104 eventos | relê o registro na hora |

- Exclusões só por aviso (`*_REMOVED`, `*_DELETED`, `CLEARING_DELETED`) ou comparação completa semanal; o que sumiu ganha `removido_em`.
- Saldo, autorização e baixas das parcelas a pagar só vêm pela massa `/outcome`. Títulos a receber só se listam por cliente (usar a massa `/income`). Indexador só traz o último valor (guardar o de cada dia).
- Primeira carga com todo o histórico: uma vez, aos poucos, fora do horário de uso.

## 4.7 Envio ao Sienge [Desenhado]

Fila no banco (pedido de envio com estado pendente, enviado, erro, e o id devolvido pelo Sienge), processada pelo adaptador no servidor, respeitando 200/min e com nova tentativa. Antes de criar título, procurar o mesmo credor + número no espelho e na fila. Credenciais lidas do Vault. Nenhum desses componentes existe ainda.
