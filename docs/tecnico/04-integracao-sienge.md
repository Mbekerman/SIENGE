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
- **Pacote contratado: provavelmente o Start** (inferido em 16/nov/2026 pela cota de massa de 20 por dia, que é a do Start na tabela de pacotes; falta a confirmação do Sienge ou do contrato). Pela tabela, o REST do Start tem 1.000 chamadas por dia, mas nenhum cabeçalho REST mostra essa cota para conferir. Na tabela, só as cotas de massa têm a marca "com bloqueio" (429 ao atingir); o que acontece acima das 1.000 REST por dia (bloqueio, cobrança à parte ou nada) não está documentado [a perguntar ao Sienge], e isso pesa, porque o CRM usa a mesma cota. Isso decide se a cópia diária completa cabe no dia.
- **Testado em 8/nov/2026, 19h55:** depois de umas 3 chamadas só de leitura, o Sienge respondeu `429` com `Ratelimit-Limit: 200`, `X-Ratelimit-Remaining-Minute: 0`, `X-Ratelimit-Limit-Second: 100` e `Retry-After: 36`. Isso confirma que a cota de 200 por minuto é do subdomínio, dividida entre as integrações, e que outra integração (provavelmente o CRM) gastava quase toda. Também existe um limite por segundo (100). Para o adaptador: fila com nova tentativa que respeita o `Retry-After` (a nova tentativa de `POST /bills` passa pela idempotência da S-021); criar título e gravar pagamento têm prioridade sobre as leituras do espelho; leitura pesada pela API em massa ou fora do horário. Falta saber quanto o CRM consome e em que horários.
- **De-para para o envio (passo 1, transição):** o `costCenter` do Sienge (a obra) corresponde ao nosso **núcleo econômico**, e o nosso centro de custo (Marketing, Obra, Incorporação...) não tem campo próprio no título, então o de-para indica como ele é representado no Sienge (a conferir: departamento ou apropriação). Cada combinação núcleo × centro de custo × natureza do nosso lado tem de mapear para exatamente uma conta e um centro do Sienge, numa tabela de mapeamento aprovada; o envio recusa o pedido sem mapeamento ou com mais de um. A empresa 1 do Sienge é a Muchmore Tecnologia (centros SSG, SSB e FCA); ela fica fora do ERP (Moises, 15/nov/2026).
- **Credores, testado em 8/nov/2026 (só leitura):** `GET /creditors` (811) não tem filtro `modifiedAfter`; `/customers` (277) tem. A conta e o PIX ficam em `/creditors/{id}/bank-informations` e `/creditors/{id}/pix-informations`; o PIX responde 404 quando não há chave, e nenhum dos dois traz autor nem data da mudança. Existe o webhook `CREDITORS_UPDATED`, mas não se sabe se ele dispara quando muda a conta ou o PIX (a testar). Reler todos os credores custa cerca de 2.400 chamadas, na cota dividida com o CRM. O espelho ainda não existe.
- **Dados de pagamento ficam na parcela, testado em 8/nov/2026 (só leitura):** de 30 credores com título recente, 12 têm conta no cadastro, 7 têm PIX e 18 não têm nenhum dos dois. De 40 títulos sorteados, as parcelas se dividem em 16 PIX, 13 boleto, 4 guia e 7 sem forma. Nas 6 parcelas PIX, `GET /bills/{id}/installments/{n}/payment-information/pix` traz a chave; em 4 delas `isUsingCreditorData` = N, ou seja, a chave foi digitada no próprio título. A permissão do usuário da API está ok.
- **Testado em 15/nov/2026 (só leitura, usuário da API, só GET; thread do de-para do Marketing):**
  - `GET /v1/departments` responde `404 Resource not found`. Provavelmente o recurso está fora do pacote contratado (a conferir com a Softplan). Sem ele, o departamento não serve de hoje para representar o nosso centro de custo.
  - `GET /bulk-data/v1/outcome` (`selectionType=I`, 1/11/2025 a 15/11/2026, `correctionIndexerId=0`) devolveu 8.192 parcelas de 5.145 títulos numa chamada. O total bate com o de `GET /bills` no mesmo período, e as parcelas por título bateram com `installmentsNumber` em 8 amostras; o número redondo parece coincidência, não teto (a conferir na carga). Consulta em massa de um mês passou de 300 s: usar `_async=true`.
  - Na segunda e na terceira consulta em massa, `429` com `Retry-After: 10415` (cerca de 2,9 h), e chamadas de um mês passaram de 5 min. O 429 veio às 21:06:25Z e o `Retry-After` termina exatamente à 00:00Z (21h em Brasília). Isso indica uma **cota diária** da API em massa, renovada à meia-noite UTC, que se esgotou depois de 1 ou 2 chamadas (a primeira, às 20:31Z, trouxe 16,6 MB). A cota conta chamadas (ver o item abaixo). Para o adaptador: carga em massa só na madrugada, uma de cada vez, e uma fila que guarda o `Retry-After` de horas, sem tentar de novo antes e sem travar o envio de títulos, que vai pela cota REST.
  - **Confirmado em 16/nov/2026, 00:11Z (só leitura):** a API em massa responde `X-Ratelimit-Limit-Day: 20` e `Ratelimit-Reset` com os segundos até 00:00Z. A cota conta chamadas, não volume: cada consulta assíncrona gasta 1 pelo pedido, 1 por consulta de andamento e 1 por pedaço baixado. O `/outcome` de toda a história (`selectionType=I`, 1/1/2000 a 31/12/2026, `withAuthorizations` e `withBankMovements`) gastou 7 (pedido, 2 andamentos, 4 pedaços de 8 MB), terminou em cerca de 2 min e trouxe 11.625 parcelas de 7.786 títulos (só ficaram de fora os 14 emitidos em 2027 ou depois), 9.257 baixas, 9.678 autorizações e 7.182 movimentos bancários. Isso confirma que as 8.192 parcelas da primeira consulta não eram teto. Cada parcela já traz `buildingsCosts`, `departamentsCosts` e `paymentsCategories`, o que dispensa as chamadas REST de apropriação. Para o adaptador: consultar o andamento com intervalo largo, porque cada consulta custa da cota de 20. Atenção: com `selectionType=I`, o `/outcome` traz também todas as parcelas futuras dos contratos (consórcios até 2042). Por isso ele não responde "o que foi pago no período"; para isso, usar as baixas.
  - As respostas REST trazem só `X-Ratelimit-Limit-Minute: 200` e `X-Ratelimit-Limit-Second: 100` (`Ratelimit-Limit: 100`); nenhum cabeçalho mostra a cota diária, então o adaptador só a descobre pelo 429.
  - `GET /bills` aceita o período de 2000 a 2030 numa consulta só; cada título traz `registeredUserId`/`registeredBy` e `changedUserId`/`changedBy`, a única fonte de usuários do Sienge.
  - Volumes na data (com a Muchmore): 7.800 títulos a pagar (885 da empresa 1), 14.681 movimentos de extrato, cerca de 25.900 lançamentos contábeis (22.366 da empresa 5), 819 credores, 278 clientes, 188 contratos de venda, 562 pedidos, 894 notas de compra, 447 NF-e, 129 contratos de suprimentos, 677 medições e 1.786 movimentos de estoque; patrimônio, locação e tabela de preços vazios. Inventário: https://claude.ai/artifact/8z7NqNByYSHEHCSW2ix8WC.
  - **Já há 6 webhooks cadastrados** no Sienge, que não são do ERP: todos do CV CRM (`bkm.cvcrm.com.br`), conferido em 17/nov/2026 (ver 4.5).
  - Cadastros na data: 98 centros de custo (`/cost-centers`; novos 98 e 99, "SPE 07 ADM FINANCEIRO" e "SPE 08 ADM FINANCEIRO"), 99 empreendimentos (`/enterprises`), 10 empresas (`/companies`; nova a 10, BKM 08 SPE). O espelho precisa aceitar cadastro novo sem mudar código.
- **De-para principal (Moises, 15/nov/2026):** a conta do Sienge sai da chave natureza + centro de custo nossos (mais a divisão em Veiculação); o centro de custo do Sienge sai de núcleo + divisão (por exemplo, a divisão PDV vai para "SPE 0X - PONTO DE VENDA"). O histórico guarda a conta e o centro originais do Sienge. Nunca se lança em conta inativa. A Muchmore (empresa 1) fica fora do ERP. Proposta em conferência: https://claude.ai/artifact/3CeNQB6kTJv8PekMp4fvb6.
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
| Cadastros de apoio | — | empresas, obras, centros de custo, planos financeiros, documentos, indexadores, contas | criar qualquer um; listar usuários; listar filiais. Conferido de novo em 17/nov/2026: `company-v1`, `enterprise-v1`, `centro-de-custos` e `checking-accounts-v1` só têm `GET`, e os `post` do `enterprise-v1` são webhooks que o Sienge envia (`COST_CENTER_CREATED` e outros). Por isso, empresa, obra e conta corrente de teste se criam à mão na tela do Sienge, e o usuário de API tem de ser liberado na empresa nova antes de gravar nela. |
| Contabilidade | lançamentos e lotes | contas, saldos, balancete | — |
| Comercial | clientes, unidades, reservas, contratos de venda, comissões | tabela de preços, saldo devedor, parcelas a receber | — |

## 4.4 Comportamentos testados na base da BKM

**Área de testes desde 17/nov/2026** (criada pela tela, a pedido do Moises): empresa 11 "BKM TESTES - NAO USAR" (grupo de empresas 5 - TESTES), obra e centro de custo 100 "TESTES API - NAO USAR" (configuração copiada da obra 13) e conta corrente TESTE-API "CONTA TESTE - NAO PAGAR" (banco gerencial, fora do disponível). O Sienge criou sozinho as contas CAIXA e EMISSAOCHQ na empresa. **Daqui em diante, toda gravação de teste pela API vai na empresa 11 / obra 100, não mais na empresa 2 / obra 13.** Fatos vistos na criação:

- A API não cria empresa, obra nem conta corrente (ver 4.3).
- O usuário de API **não tem trava por empresa**: logo depois de criados, `GET /companies`, `/cost-centers/100` e `/checking-accounts` já mostraram os cadastros novos, e o usuário de API nem aparece em Autorizações › Usuários › Empresas. Ou seja, a credencial da API alcança todas as empresas, inclusive a Muchmore; só o nosso código a deixa de fora. Gravar na empresa 11 foi testado no mesmo dia (abaixo). Risco coberto pela S-021, pela S-115 e pela trava de empresa (abaixo).
- Na tela, o usuário só vê a empresa com "Acesso aos dados da empresa" marcado; empresa nova nasce sem ninguém autorizado.
- A área de negócio é por empresa.
- Ao digitar o CNPJ no cadastro de obra, o Sienge busca na Receita e preenche endereço e e-mail sozinho. Conferir o CNPJ antes de salvar: na criação, um CNPJ de terceiro ficou gravado alguns minutos e foi trocado, sem nenhum lançamento nesse intervalo.

**Primeira gravação na área de testes (17/nov/2026, com ok do Moises).** `POST /bills` na empresa 11 / centro de custo 100 criou o título 8547 (PRV, TESTEAPI11, R$ 1,00, credor 27, conta 2030224). Isso confirma que o usuário de API grava numa empresa nova sem nenhuma liberação.

- A primeira tentativa voltou 400: "Devido ao parâmetro 665 não é possível cadastrar esse título, o plano financeiro não está autorizado para o centro de custo informado". O parâmetro 665 limita as contas do plano financeiro por centro de custo (a pagar, a receber, caixa e bancos). A lista fica na aba "Plano financeiro" do cadastro da obra/centro de custo, e um centro novo nasce sem nenhuma conta. No centro 100 foram liberadas as 399 contas de movimento. **Para o ERP:** o de-para natureza → conta tem de respeitar as contas liberadas em cada centro (ler e guardar essa lista no espelho e conferir antes do envio); senão, o título é recusado no envio.
- O centro 100 tem o código interno 104 (`entity.empreendPK.cdEmpreend`). A API e a tela usam o código de exibição, 100.
- Cota: três vezes, entre 11h22 e 11h27, a primeira chamada voltou 429 com `X-Ratelimit-Remaining-Minute: 0`. Outro sistema, provavelmente o CRM, esgota os 200 por minuto. O cliente tem de esperar o `Ratelimit-Reset` e tentar de novo, com a idempotência da S-021.
- A API não apaga título: o 8547 fica na empresa 11 até alguém apagar pela tela.

**Trava de gravação no código (17/nov/2026, pedido do Moises; S-120 e S-121 aprovadas por ele).** Como a credencial grava em qualquer empresa, toda gravação ao Sienge (POST, PUT, PATCH, DELETE e qualquer método que não seja leitura) passa antes por `gravarComTrava()` em `servicos/sienge-escrita/trava.ts`, e a chamada não sai se ela recusar. Só a palavra exata `producao` é produção; qualquer outro valor, inclusive ausente, é teste.
- **Empresa:** em teste, só as empresas de teste (hoje a 11). Em produção, nunca a 11 nem a Muchmore (1). Sem empresa conhecida ou com empresas divergentes, recusa.
- **Registro novo** (POST na coleção): a empresa vem do corpo (`debtorId` ou `companyId`). Em teste, o `creditorId` tem de ser um credor de teste, criado à mão pela tela.
- **Registro que já existe** (rota com id: parcela, PIX ou boleto da parcela, anexo, autorizar, DELETE): a empresa é lida no próprio registro no Sienge antes da gravação (hoje só `/bills`, pelo `debtorId`), nunca só a declarada por quem chama. Recurso sem leitura conhecida recusa. Em teste, o registro também tem de estar na lista dos criados pelo próprio teste, para um id digitado errado não alcançar outro título.
- **Credor:** PIX e conta bancária de credor nunca se gravam pela API, em ambiente nenhum. Em teste, nenhuma gravação em credor. Em produção, só a inclusão de credor novo (`POST /creditors`).

A própria trava envia o pedido que conferiu: o adaptador entrega só a função que envia método, caminho e corpo, para não haver uma chamada pronta apontando para outro id (S-123). Medição e contrato ainda não têm leitura de empresa e ficam recusados até ganharem uma. O adaptador do passo 1 (`servicos/sienge-escrita`, 4.7) manda toda gravação por essa função (testes em `trava.test.ts`, `envio.test.ts` e `fila.test.ts`, no CI).

**Envio de ponta a ponta (17/nov/2026, empresa 11, credor 823; programa da seção 4.7):**

| Teste | Resultado |
| --- | --- |
| `POST /bills` NFSE com rateio em duas contas (66,67% 2030224 e 33,33% 2030115, centro 100) e 2 parcelas | 201, título 8558. NFSE na empresa 11 **não** pediu unidade (na empresa 2 pediu, ver abaixo) |
| Como o Sienge cria as parcelas | Não há campo de parcelas no `BillInsert`: o Sienge divide o total igual, um mês entre cada vencimento a partir do `dueDate`, e o centavo que sobra fica na **primeira** (R$ 1,00 em 3 → 0,34 + 0,33 + 0,33; título 8559) |
| `PATCH /bills/{id}/installments/{n}` com `dueDate` em título de origem SE | 204; o vencimento mudou (título 8560, parcelas 2 e 3). O número da parcela na rota é o `installmentNumber` |
| PIX da parcela com chave e-mail e com CNPJ formatado (`keyPixType` C) | 204; parcela passa a `paymentTypeId` 14, PIX |
| Boleto da parcela (`/payment-information/boleto-bancario`, `paymentTypeId` 2, código de barras de 44 e linha de 47 dígitos) | 204; parcela passa a "Bloqueto Bancário Outros Bancos". O 1 é "próprio banco" |
| `GET /bills` com filtro que não acha nada | **404** "Resource not found", não lista vazia. Com resultado, 200 e `notes` em cada título; o filtro de data é pela emissão |
| `documentIdentificationId` lido de volta | Vem com espaço à direita quando o código tem 3 letras ("PRV ") |

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
2. **Previsão no Sienge não vira título real.** As previsões ficam no nosso banco; título no Sienge só nasce quando a nota chega. **Mudança de 14/nov/2026 (Moises):** na transição, cada previsão de despesa lançada no ERP vira um **título de previsão** no Sienge pela API, guardando a ligação título × previsão. Quando a previsão é substituída pelo título definitivo ou excluída, o ERP escreve numa planilha do Google qual título de previsão o financeiro deve apagar à mão (apagar título não tem API). Verificação das previsões a apagar (Moises, 14/nov, 14h35): a cada 30 minutos no horário comercial e uma conferência completa de madrugada, por causa da cota de 200 por minuto dividida com o CRM. Ainda a testar: o tipo de documento de previsão aceito no `POST /bills` e como detectar o título apagado (consulta por id, ou ausência em `/bills/by-change-date`).
3. **Trava de duplicidade do nosso lado é obrigatória** (credor + tipo + número). Também protege contra nova tentativa após falha de rede, porque `POST /bills` não recusa repetição.
4. **Título nascido de medição aceita completar** documento, vencimento, forma de pagamento e anexo depois da liberação.
5a. **Passo 1, testes de 8/nov/2026:** `PATCH /bills/8422/installments/1/payment-information/pix` num título de origem SE devolveu **204**: o PIX foi gravado (`paymentTypeId` 14, `isUsingCreditorData` S) e a parcela passou a `paymentType` PIX. Ou seja, depois de criado o título aceita dados de pagamento, mas não aceita tipo, número nem valor (teste de 6/nov). O `BillInsert` aceita `taxes` (`BillTaxInsert`) já na criação. Continua sem API a autorização do pagamento no Sienge, que é manual. O anexo **tem** API: `POST /bills/{billId}/attachments` (`bill-debt-v1.yaml`, seção "Anexo do título"), testado no título 8417 em 6/nov. O `bill-debt-v1.yaml` não tem operação para bloquear ou suspender uma parcela. O título 8422 (com PIX, vencimento em 15/03/2027) precisa ser apagado à mão.
5. **Medição só por quantidade.** Valor da nota vira quantidade = valor ÷ preço unitário, com no máximo 4 casas. Com item a R$ 1,00 não há perda; com preço alto pode sobrar até alguns centavos (item de R$ 5.000,00 e nota de R$ 4.873,22 dá R$ 0,22 de diferença). O código deve avisar antes de lançar quando o valor não fechar.
6. **Os passos sem API são três:** liberação de medição, ciência e autorização de pagamento do título. O sistema acompanha por webhook e mostra o que espera ação no Sienge.

## 4.5 Webhooks (`guias/webhooks.md`, `hooks-v1.yaml`, `guias/webhooks-index.md`) [Desenhado; testado em 17/nov/2026, sem cadastro permanente]

- Cadastro por `POST /hooks` com URL, eventos e token. 104 eventos.
- O Sienge espera 2,5 s pela resposta; depois tenta em 10 min, 30 min, 1 h, 3 h e 5 h, e desiste (~10 h). Aviso perdido não volta.
- Cabeçalhos: `x-sienge-tenant`, `x-sienge-event`, `x-sienge-hook-id`, `x-sienge-id` (único por evento: usar para não processar duas vezes), `user-agent: sienge-hooks`.
- O corpo traz só o identificador (ex.: `{ "billId": 123 }`). Sem assinatura documentada nem garantia de ordem.
- **Testado em 17/nov/2026 (empresa 11, ok do Moises):** webhook cadastrado com `PAYMENT_INSTALLMENT_CREATED`, `PAYMENT_INSTALLMENT_REMOVED` e `PAYMENT_BILL_UPDATED`, para um receptor de teste no `bkm_dev` que só registrava o que chegava; descadastrado no fim.
  - O **token do cadastro chega no cabeçalho `Authorization: Bearer <token>`** (conferido pelo hash). É o que autentica o aviso: o recebedor recusa sem ele, comparando em tempo constante. O `user-agent` veio `axios/0.19.2`, não `sienge-hooks` como diz o guia.
  - Título PRV de 2 parcelas criado pela API (8593): 2 avisos `PAYMENT_INSTALLMENT_CREATED` em 1 segundo, um por parcela, com `{"billId", "installmentId", "billOrigin": "Sistemas Externos", "documentType": "PREVISÃO DE PAGAMENTO/RECEBIMENTO"}`.
  - Título apagado pela tela: 2 avisos `PAYMENT_INSTALLMENT_REMOVED` em 1 segundo, com o mesmo corpo. Isso detecta a linha PRV apagada pelo financeiro na hora (a conferência de 30 minutos e o cruzamento continuam como rede de segurança, porque aviso perdido não volta).
  - O PATCH do vencimento da parcela não gerou `PAYMENT_BILL_UPDATED` (esse caso seria o `PAYMENT_INSTALLMENT_UPDATED`, não cadastrado no teste).
  - Os 6 webhooks que já existiam são do **CV CRM** (`bkm.cvcrm.com.br`): cliente alterado, contrato de venda emitido e cancelado, cessão de direitos, unidade alterada e antecipação de parcelas.
- Faltam eventos de: título criado (vem pela parcela criada), medição criada, contrato criado ou alterado, aditivo, pedido criado à mão, nota de compra.
- Eventos úteis do contas a pagar: parcela criada/alterada/removida, autorização disponível e alterada, ciência pendente e feita, baixa feita/alterada/cancelada, estorno, medição autorizada/desautorizada, `CLEARING_*` (liberação finalizada e apagada), credor, movimento bancário.

Recebedor do espelho [Desenhado]: grava o aviso cru com `x-sienge-id` único, responde 200 na hora e enfileira; um processo separado relê o registro na API e atualiza `sienge_bruto` e `sienge`.

**Recebedor da parcela removida [Construído, 17/nov/2026; testado no banco e no programa, não instalado nem cadastrado no Sienge]** (`servicos/sienge-aviso`, ver 4.7.3): a Edge Function só aceita `POST` com `Authorization: Bearer <token>` igual ao do Vault (`sienge_aviso_token`, comparado em tempo constante; sem token guardado, ou com menos de 32 caracteres, recusa tudo com 503), `x-sienge-id` uuid, `x-sienge-event` só `PAYMENT_INSTALLMENT_REMOVED` (outro evento responde 200 sem gravar) e corpo JSON objeto de até 8 KB. Sem `Bearer` de 32 caracteres ou mais, recusa antes de abrir o banco; o token do Vault fica em memória por 5 minutos. Registra pelo `erp.sienge_registrar_aviso` como `erp_sistema` e responde 200; erro do banco responde 500 sem o detalhe, para o Sienge tentar de novo. Não usa o `x-sienge-tenant` (o valor não foi anotado no teste). Instalar com `verify_jwt` desligado: o Sienge não manda o JWT do Supabase. Risco: o Sienge espera 2,5 s; a partida a frio da função pode passar disso, e o aviso repetido não entra duas vezes (o `x-sienge-id` é a chave).

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

## 4.6.1 Programa de carga do histórico [Construído, 17/nov/2026; em teste no `bkm_dev`]

Código em `servicos/sienge-carga/` (`index.ts` e `logica.ts`; testes de `logica.ts` em `logica.test.ts`, `node --test --experimental-strip-types`). Roda como Edge Function `sienge-carga` do Supabase, porque o banco e o Sienge são alcançáveis de lá. O pg_cron chama a função a cada minuto (`supabase/dev/sienge_carga_agenda.sql`, só no `bkm_dev`; não é migration, pela regra de portabilidade).

- **Só lê o Sienge:** a única chamada de rede é `lerSienge`, sempre GET. Credencial nos segredos `SIENGE_USUARIO` e `SIENGE_SENHA` da função; a consulta gravada nunca leva credencial.
- **Um passo por chamada:** pega a primeira carga pendente ou rodando e vencida (`for update skip locked`) e faz um passo do modo assíncrono da massa: pedir (`_async=true`, pedaços de 8.192), acompanhar o andamento a cada minuto, baixar cada pedaço (grava em `sienge_bruto` e carrega no espelho na mesma transação) e concluir (marca ausentes).
- **Cota de massa:** guarda `X-Ratelimit-Remaining-Day` a cada resposta e para quando sobram 6 (`SIENGE_RESERVA_MASSA`), deixando-as para o CRM; volta às 00:05Z. Num 429, espera o `Retry-After`.
- **Falhas:** pedido expirado (404 no assíncrono) recomeça do zero; "Failed" da massa espera 30 minutos; massa "Finished" sem pedaços é erro (não conclui); outro erro espera 5 minutos e, na 5ª tentativa, a carga fica em `erro`.
- **Quem chama:** a função não pede JWT; confere o cabeçalho `x-carga-chave` contra o segredo `sienge_carga_chave` do Vault, em tempo constante.
- **Custo da carga de todo o contas a pagar (2000 a 2026):** cerca de 7 chamadas de massa (1 pedido, 1 a 4 andamentos, 2 pedaços), das 20 do dia.
- Um erro conta na carga daquele passo; um passo bem-sucedido zera as tentativas.
- Ao concluir, só a carga por emissão (`selectionType` I), sem filtro e com `startDate`/`endDate` chama `marcar_ausentes_pagar` (`marcaAusentes` em `logica.ts`); as outras concluem sem marcar nada.
- **Primeira execução no `bkm_dev` [Testado, 17/nov/2026]:** 08h59 recusada com 401 (credencial; sem cabeçalho de cota, não gastou); 09h03 pedido aceito; um 502 do Sienge no andamento, refeito sozinho; 4 pedaços (3.243 + 889 da Muchmore, 3.537, 3.338, 643 linhas; o pedaço não chega a 8.192 linhas, o corte é por outro critério); concluída às 09h15. Gastou 5 das 20 chamadas de massa. 10.761 parcelas de 6.922 títulos, 11.204 rateios (todos somam 100%), 8.813 autorizações, 8.400 baixas, 6.239 movimentos. Batem com o arquivo de 16/11 (10.736 sem a Muchmore) mais 25 parcelas lançadas depois; os títulos 8300 a 8510 conferidos um a um.

## 4.7 Envio ao Sienge [Construído, 17/nov/2026; testado de ponta a ponta na empresa 11; ainda não instalado]

Pedido do Moises (17/nov/2026): "Faça a adaptação da escrita". Só o título a pagar de fornecedor ou avulso aprovado, com a forma de pagamento de cada parcela.

**No banco** (migration `20261117000200_erp_envio_sienge.sql`; dicionário em `docs/erp.md`):

- `erp.parcela_pagamentos`: PIX ou boleto de cada parcela, conferido no banco (chave pelo tipo; linha digitável pelos dígitos; o valor impresso no boleto, os 10 últimos dígitos, igual ao da parcela ou zero; a chave PIX por CPF/CNPJ igual ao documento do credor do título, ou de outra pessoa só com a justificativa da exceção em `pix_excecao`, S-125). Quem aprova vê os avisos de cada parcela em `erp.avisos_forma_pagamento(título)`: chave de e-mail, telefone ou aleatória (não é do documento do credor), exceção com a justificativa e chave nova para o credor (nunca usada num outro título dele que já tem id no Sienge). Ao entrar na fila, o título com chave nova gera o evento crítico `chave_pix_nova` (master sempre; regra padrão para a lista AF), com só as chaves novas. Trava no primeiro voto da alçada e quando o título entra na fila. O pedido ao Sienge confere tudo de novo, porque a parcela pode mudar na revisão.
- `erp.sienge_centros` e `erp.sienge_contas`: de-para núcleo + centro → centro do Sienge e natureza + centro → conta do Sienge. Empresa e credor saem de `erp.codigos_externos` (`sienge`, `empresas` e `pessoas`).
- `erp.sienge_envios`: a fila. `erp.sienge_enfileirar()` põe os aprovados; `erp.sienge_pedido(título)` monta o corpo do `POST /bills` e as parcelas, ou recusa dizendo o que falta; `erp.sienge_registrar(título, id)` guarda o id do Sienge na fila e em `codigos_externos`. Tudo só pelo sistema.
- O corpo: `debtorId` (empresa), `creditorId`, documento (NFSE, NFE, FAT, BLT, GUIA, REC pelo tipo da nota), número (número-série, até 20), emissão, `billDate` = competência (na API do Sienge, "Data de competência"), `baseDate` = emissão ("Data base" do indexador; com `indexId` 0 não corrige nada; até a migration `20261117000500` os dois iam trocados, e o PRV de teste 8591 ficou com a competência no dia do lançamento), `dueDate` = primeiro vencimento, `indexId` 0, valor, `budgetCategories` agrupadas por centro e conta com 2 casas somando 100 (a diferença do arredondamento vai à maior linha) e `notes` começando com o **marcador** `ERP <id do título>`.

**O programa** (`servicos/sienge-escrita/`): `envio.ts` fala com o Sienge, `fila.ts` cuida da fila, `index.ts` é a Edge Function `sienge-escrita` (pg_cron a cada minuto, `supabase/dev/sienge_escrita_agenda.sql`, chave `x-escrita-chave`). Cada chamada enfileira e envia **um** título vencido:

1. **Reserva:** `update ... where titulo_id = (select ... for update skip locked)` adia a próxima tentativa em 15 minutos, para outra chamada não pegar o mesmo título (S-044).
2. **Achar ou criar:** sem id na fila, procura no Sienge (`GET /bills` por empresa, credor, número e emissão até hoje) o título com o marcador. Achou: é o nosso (o programa caiu entre o POST e o registro) e não cria outro. Achou só título do mesmo credor e número **sem** o marcador: lançado fora do ERP, vai para `manual`. Não achou (404): `POST /bills`, lê o id no `Location` e registra **antes** de seguir.
3. **Parcelas:** lê as do Sienge e compara com as nossas. Quantidade ou valor diferente: `manual` (o valor não se corrige pela API). Vencimento diferente: `PATCH` da parcela.
4. **Pagamento:** `PATCH` PIX (sempre `isUsingCreditorData` N, chave com a máscara do Sienge) ou boleto (código de barras calculado da linha, `paymentTypeId` 1 se o banco do boleto é o de uma conta da empresa, senão 2). Sobrescreve, então repetir não duplica.
5. Fim: `enviado`. Erro de rede, recusa do Sienge, 429 ou pedido recusado pelo banco: `erro`, nova tentativa em 1, 2, 4... minutos, até 6 horas; se o Sienge mandar `Retry-After` (429 ou 503), espera o maior dos dois. Recusa 4xx (menos 408 e 429) três vezes seguidas: `manual`, porque o pedido está errado e repetir não resolve. Divergência: `manual`, ninguém tenta de novo.

Toda gravação passa por `gravarComTrava()`; em teste, a lista de "criados pelo teste" é a dos ids da fila, então um id errado nunca alcança título de fora dela. Cada `PATCH` custa uma leitura a mais (a trava lê a empresa no título). Um título de 3 parcelas gasta cerca de 12 chamadas.

**Instalado no `bkm_dev` (18/nov/2026):** a função, o pg_cron de minuto em minuto e as chaves no Vault; a conexão das funções (usuário `postgres`) assume `erp_sistema` pelo `grant erp_sistema to postgres with inherit false, set true` (sem ele, todo passo responde 500 com "permission denied to set role"; o pacote da produção precisa do mesmo grant, com `set true` e `inherit false`, ao papel que chamar as funções). Sem `SIENGE_AMBIENTE`, a trava fica no modo de teste (empresa 11, credor 823). **Ainda não feito:** conferir antes do envio se a conta está liberada no centro (parâmetro 665; hoje o Sienge recusa e o título fica em `erro` com a mensagem); anexo do PDF; nota com retenção (falta a filial); aviso a quem lançou quando o envio vai para `erro` ou `manual`; tela da fila.

## 4.7.1 Previsão no Sienge (título PRV) [Construído, 17/nov/2026; testado no banco e no programa, não no Sienge]

Decisão do Moises (14/nov/2026): sem módulo de orçamento por ora, a previsão aprovada vai ao Sienge como título PRV sem forma de pagamento, ligada à nossa; a que sai de aberta (cancelada, encerrada ou trocada) vira linha para o financeiro apagar à mão, e o sistema marca quando ela some.

**No banco** (migration `20261117000400_erp_previsao_sienge.sql`):

- `erp.sienge_parametros`: chave `credor_previsao`, o credor genérico "PREVISÃO BKM" do Sienge, usado quando a previsão não tem credor com código. Muda só o master (política de configuração, evento `codigo_externo_alterado`).
- `erp.sienge_previsoes`: a fila das previsões, com as mesmas situações da dos títulos e mais `descartado` (saiu de aberta antes de ser enviada). `apagar_desde` marca a enviada que deixou de ser aberta; `apagado_em`, a que sumiu do Sienge. Id do Sienge, `apagar_desde` e `apagado_em` não mudam depois de gravados; nada se apaga.
- `erp.sienge_enfileirar()` põe os títulos aprovados e as previsões aprovadas abertas (`erp.previsao_aprovada`), marca para apagar as enviadas que deixaram de ser abertas e descarta as não enviadas.
- `erp._sienge_pedido_previsao`: documento `PRV`, número `PRV-` + 12 primeiros caracteres do id, credor da previsão ou o genérico (sem ele, recusa com "Falta o credor genérico..."), de-para da natureza com 100% numa conta, uma parcela com o saldo na data prevista e o marcador `ERP <id>` nas observações.
- As funções da fila passaram a servir aos dois tipos: `erp.sienge_pegar()` (o mais vencido dos dois, cada tabela com `for update skip locked`), `sienge_pedido_item`, `sienge_registrar_item`, `sienge_terminar`, `sienge_ids()`. Para a conferência, `sienge_pegar_conferencia()` (a mais antiga a apagar sem conferência há 30 minutos) e `sienge_marcar_apagado`. `erp.v_sienge_prv_apagar` é a lista do que apagar.

**O programa:** o mesmo `processarUm()`. Parcela sem forma não tem passo de pagamento. Quando não há item vencido, confere uma linha a apagar: `GET /bills/{id}` com 404 marca apagada; outro erro fica para a próxima conferência. Só leitura, não passa pela trava.

**Limites conhecidos (S-131, revisão de 17/nov/2026):** a linha PRV vai com o saldo do momento do envio e não muda depois. A nota que consome a previsão em parte deixa a PRV inteira e o título da nota no Sienge ao mesmo tempo: o valor conta duas vezes no Sienge até a previsão ser encerrada (saldo ou saving), quando a PRV vai para a lista do que apagar. A natureza reclassificada também não chega à PRV. A conferência marca apagado em qualquer 404, sem antes confirmar que um título que sabidamente existe responde 200 (um caminho errado ou uma mudança da API marcaria tudo). O cruzamento (4.7.2) só recria com duas provas, fora da lista e 404; o consumo parcial, a reclassificação e o 404 da conferência continuam em aberto.

**Planilha do financeiro** (`servicos/sienge-escrita/planilha.ts`, construído em 17/nov/2026, sem a planilha real): com o corpo `{"tarefa": "planilha"}`, a função reescreve a aba `PRV a apagar` a partir de `erp.v_sienge_prv_apagar`. Colunas: empresa, título no Sienge, documento, valor, data prevista, desde quando está na lista e situação da previsão. A gravação é por cima e só depois limpa o que sobrou embaixo, então a planilha nunca fica vazia por falha. Usa uma conta de serviço do Google (escolha do Moises, 17/nov/2026), com token pedido por JWT RS256 assinado no próprio programa e escopo só de planilhas; a conta só alcança a planilha compartilhada com ela. O pg_cron roda a cada 30 minutos no horário comercial e às 6h30 (`supabase/dev/sienge_escrita_agenda.sql`). O financeiro tem acesso só de leitura; quem apaga no Sienge não mexe na planilha, e a linha some quando a conferência vê o 404.

**Ainda não feito:** criar a conta de serviço e a planilha (Moises; passos no 02); aviso por e-mail (os eventos `prv_recriada` e `prv_estranhas` já vão à lista AF pelo sino; o e-mail sai pelo canal geral, quando existir); criar o credor "PREVISÃO BKM" no Sienge e gravar o parâmetro.

## 4.7.2 Cruzamento das linhas PRV [Construído, 17/nov/2026; testado no banco e no programa, não no Sienge]

Decisão do Moises (14/nov/2026): o cruzamento recria a linha PRV que falta e marca a estranha, avisando a AF; verificação completa de madrugada.

**No banco** (migration `20261117000600_erp_prv_cruzamento_sienge.sql`):

- `erp.sienge_pegar_cruzamento(agora)`: só das 2h às 6h em São Paulo; devolve a próxima empresa do de-para que ainda não passou no dia (ou a que falhou, 30 minutos depois, até 3 tentativas; ou a que ficou rodando mais de 1 hora) e a data inicial da lista: a emissão da primeira linha PRV do ERP na empresa, no máximo 3 anos para trás. Reserva a passada em `erp.sienge_cruzamentos` (dia × empresa, situação, tentativas, resumo, erro).
- `erp.sienge_prv_nossas(empresa)`: as linhas do ERP na empresa, com `esperada` (enviada, previsão aberta, fora da lista do que apagar) e as antigas que já foram trocadas.
- `erp.sienge_recriar_prv(previsão, id, motivo)`: só a esperada; guarda o id antigo em `erp.sienge_prv_trocas` (só insere), apaga o código externo e devolve a previsão à fila como pendente, que cria outra linha. Evento `prv_recriada` para a lista AF. A fila só deixa soltar o id quando a troca está registrada.
- `erp.sienge_terminar_cruzamento(empresa, estranhas, resumo, erro)`: com erro, marca a passada para tentar de novo; sem erro, grava as estranhas em `erp.sienge_prv_estranhas` (recusa qualquer id do ERP), marca `sumiu_em` nas que não vieram mais e avisa a AF só das novas (evento crítico `prv_estranhas`, com a quantidade). `erp.v_sienge_prv_estranhas` é a lista das que continuam no Sienge, que só o master e a lista AF leem.

**O programa** (`cruzarPrv` em `fila.ts`): roda quando a fila está vazia e não há linha a apagar para conferir. Lista `GET /bills?startDate&endDate&debtorId&documentsIdentificationId=PRV&limit=200&offset` (lista vazia responde 404; 404 em página seguinte é erro; até 50 páginas). A esperada que não está na lista e cujo `GET /bills/{id}` responde 404 é recriada; fora da lista sem 404 não se mexe (conta como não confirmada no resumo). A linha da lista que não é nossa vira estranha, com o motivo "sem a marca do ERP" ou, com `ERP <uuid>` nas observações, "provável duplicada". Erro em qualquer passo fecha a passada com o erro. Só leitura no Sienge; a recriação é um envio normal da fila, pela trava.

**A conferir no Sienge:** se a lista filtra mesmo pelo `documentsIdentificationId` (lido de volta com espaço à direita, "PRV ") e se o `issueDate` volta como foi enviado (o `baseDate` volta no dia 1 do mês).

## 4.7.3 Aviso do Sienge para a linha PRV apagada [Construído, 17/nov/2026; testado no banco e no programa, não instalado]

Pedido do Moises (17/nov/2026, depois do teste do webhook): marcar a PRV apagada na hora, pelo aviso `PAYMENT_INSTALLMENT_REMOVED`, sem tirar a conferência de 30 minutos nem o cruzamento da madrugada (aviso perdido não volta).

**No banco** (migration `20261117000700_erp_sienge_avisos.sql`): `erp.sienge_avisos` guarda cada aviso pelo `x-sienge-id` (chave; o repetido não entra), com o evento, o hook, o `billId` (só número inteiro), o corpo, as tentativas e o resultado. O recebido não muda, o processado não muda e nada se apaga. `erp.sienge_registrar_aviso` já fecha o aviso de título que não é linha PRV do ERP ("não é linha PRV do ERP") e o de outro evento ("evento sem ação"), sem o programa chamar o Sienge. `erp.sienge_pegar_aviso(agora)` devolve o pendente mais antigo com a previsão e o tipo (`apagar`: na lista do que apagar; `esperada`: enviada, sem a marca de apagar, previsão aberta), reserva por 5 minutos e fecha sozinho o que já não tem linha pendente (a outra parcela do mesmo título) e o que passou de 5 tentativas. Limites (S-136, migration `20261117000800`): um GET por título a cada 30 minutos (o outro aviso do mesmo título fecha sem chamada) e no máximo 10 avisos pegos por hora; acima disso os avisos esperam, a conferência e o cruzamento rodam e a lista AF recebe o evento crítico `sienge_avisos_excesso`, uma vez por hora. `erp.sienge_terminar_aviso` fecha com o resultado ou deixa para tentar de novo. Só o master e a lista AF leem os avisos.

**O programa** (`processarAviso` em `fila.ts`): roda quando a fila está vazia, antes da conferência. O aviso não é ordem: relê `GET /bills/{id}` e só com 404 age: `apagar` → `erp.sienge_marcar_apagado`; `esperada` → `erp.sienge_recriar_prv` (outra linha vai pela fila, pela trava). Título que responde 200 fecha "o título ainda existe no Sienge: nada feito". Outro erro deixa o aviso aberto. Nada grava no Sienge.

**Para ligar (com o ok do Moises):** instalar `sienge-aviso` no `bkm_dev` sem `verify_jwt`; criar no Vault `sienge_aviso_token` (aleatório, 48 caracteres ou mais); cadastrar no Sienge `POST /hooks` com a URL da função, o mesmo token e só o evento `PAYMENT_INSTALLMENT_REMOVED` (mudança de configuração no Sienge de produção; o aviso vem de todas as empresas, e o de título que não é nosso só fica registrado).

**Instalado no `bkm_dev` (18/nov/2026), sem cadastro no Sienge:** o recebedor responde 401 sem token ou com token errado e 400 com cabeçalho inválido. O primeiro aviso de verdade, mandado pelo próprio banco, voltou 500: o corpo ia como `JSON.stringify(...)::jsonb`, e o postgres.js o manda como texto JSON, que vira jsonb do tipo string, então `erp.sienge_registrar_aviso` recusava todo aviso. O mesmo erro estava em `terminarCruzamento` (a lista das estranhas chegaria como string e todo cruzamento iria para erro). Os dois passam o JSON por `tx.json`, com teste que derruba a volta do `JSON.stringify` (PR #78).
