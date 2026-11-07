# Aprovações e alçadas

[← Sumário](../README.md)

⏳ **Sessão em andamento** (começou em 7/nov/2026). O Moises pediu que a aprovação seja "amplamente discutida", com várias camadas, alçadas e regras. Nada disso tem tela ainda.

## O que entra agora

✅ **Decidido** (Moises, 7/nov/2026): por ora a aprovação cobre **só o financeiro**:

- a nota ou o título, antes de virar dívida;
- o pagamento ou o lote que vai ao banco;
- o adiantamento e a liberação de caução;
- o orçamento (versão aprovada e reprojeções).

Compras (requisição, cotação, pedido e contrato) fica para depois, no mesmo mecanismo, sem um segundo sistema de aprovação.

## Como uma regra de aprovação funciona

✅ **Decidido** (Moises, 7/nov/2026):

- As regras são **editáveis pela tela**, sem programador, e podem ser dadas por centro de custo, por natureza e por quem paga. Exemplo do Moises: uma regra para marketing, outra para obra, outra para comercial.
- **Quando várias regras valem ao mesmo tempo, todas se aplicam (soma).** A mesma pessoa não aprova duas vezes. Uma regra só troca as gerais se estiver marcada **"substitui as gerais"**.
- **Título rateado:** cada parte do rateio puxa as suas regras, e o título só fica aprovado quando todas forem cumpridas. Exemplo: um título metade Marketing, metade Obra passa pela regra de marketing e pela de obra.

🟡 **Proposta** (formato sugerido em 7/nov/2026, ainda sem confirmação de cada detalhe):

- Além de centro de custo, natureza e empresa pagadora, a regra pode filtrar por fornecedor, tipo de compromisso e faixa de valor.
- Cada regra tem **camadas de aprovadores em sequência**. Cada camada diz quem aprova (um papel, uma pessoa, o gestor do centro de custo ou o responsável pela natureza) e se basta um ou precisa de todos.
- Exemplos: "Marketing acima de R$ 10 mil: gestor de marketing, depois diretoria"; "Obra: engenheiro da obra, depois gestor de obras"; "qualquer pagamento acima de R$ 200 mil: mais o diretor financeiro".

### Exemplo de soma

Um gasto de marketing de R$ 300 mil, com as regras acima, passa pelo gestor de marketing, pela diretoria e pelo diretor financeiro. Se o diretor financeiro também estiver na diretoria, ele aprova uma vez só.

## Pagamento de funcionários PJ

⏳ **Em discussão** (7/nov/2026). O Moises quer o salário de cada PJ o mais anônimo possível: o RH mantém uma lista de quem está ativo e dos benefícios, outra lista guarda a remuneração "a 7 chaves", o financeiro vê só um código do fornecedor e o Pix, o funcionário sobe a nota num portal, e nada é pago sem o "ok" mensal dos dois responsáveis. Pontos levantados e ainda sem resposta: risco trabalhista de registrar benefícios de PJ (passar pelo jurídico), limites do anonimato (o Pix, o extrato do banco e a nota que vai ao contador identificam a pessoa) e um substituto para cada responsável, para que uma pessoa de férias não pare a folha.

## Outras regras já decididas

- ✅ A aprovação será um **módulo único**, usado por todos os outros (contrato, medição, nota, pagamento, caução, reclassificação), e não uma regra espalhada em cada tela (7/nov/2026).
- ✅ As regras podem ser dadas sobre **qualquer combinação de classificações**, e a regra num galho vale para tudo abaixo dele. Exemplos (7/nov/2026):
  - "Comerciais › Marketing, em qualquer empreendimento, acima de R$ 20 mil: aprova o diretor comercial."
  - "Empreendimento Vila Maria, qualquer natureza: aprova o gestor da obra."
- ✅ O mesmo mecanismo serve para **restringir quem vê**: "Gerais › Pessoal › Folha: só RH e diretoria"; "o sócio externo da SPE X só vê a SPE X".
- ✅ A medição continua com a aprovação de **2 gestores**, que passa a ser feita no ERP BKM (processo atual da BKM, 6/nov/2026).
- ✅ Alçadas de reclassificação: idade × valor × acumulado no mês, vale a mais alta (ver [Reclassificação](../financeiro/reclassificacao-e-fechamento.md)).
- 🟡 A autorização de pagamento no Sienge continua como o último clique do financeiro, porque não tem API; a aprovação de verdade acontece no ERP BKM.

## Papéis previstos

🟡 Pelo banco de dados de 7/nov/2026: diretor, gestor, analista e leitura; à parte, administrador (configuração) e contador (vota nas alçadas que pedem o contador). Segue o modelo do BKM Terrenos, com hierarquia analista → gestor → diretor.

## O que falta decidir

- Faixas de valor e quem aprova em cada uma.
- As avaliações e a aprovação para liberar caução.
- Alçadas de pagamento.
