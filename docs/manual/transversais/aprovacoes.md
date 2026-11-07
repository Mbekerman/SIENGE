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

> ⏳ Ainda só no desenho, sem tela. A conciliação depende do módulo de Bancos, que não foi desenhado.

**Para que serve:** pagar os funcionários contratados como PJ mantendo o valor de cada um o mais anônimo possível.

✅ **Pedido e decisões do Moises** (7/nov/2026):

- O **RH** mantém a lista de quem está ativo e o controle dos benefícios.
- Uma **tabela de remuneração**, à parte, guarda o valor de cada um "a 7 chaves".
- O **financeiro** vê só um pseudônimo (por exemplo, "PJ-017") e o valor a pagar, nunca o nome.
- O funcionário sobe a nota num **portal**; se tudo bate com as duas tabelas, ela segue direto para pagamento.
- **Todo mês, as duas tabelas são conferidas.** Se um dos dois responsáveis não der o "ok" do mês, **ninguém recebe**.
- Os dois responsáveis e os **substitutos temporários** de cada um são definidos na própria plataforma.
- O **usuário master** vê tudo, pode trocar o aprovador e também pode aprovar.
- A folha PJ entra no financeiro, nos relatórios e no BI **somada por centro de custo e por mês**, sem valor por pessoa. O detalhe fica só na área restrita.
- As **notas dos PJ ficam guardadas na área restrita** ("a 7 chaves") e vão direto ao contador. O contador também tem um **portal** para baixá-las.

🟡 **Propostas** ainda sem resposta (7/nov/2026):

- Conciliação automática: o extrato vem direto do banco e, antes de qualquer pessoa ver, os dados do PJ são trocados pelo pseudônimo. O Moises sugeriu a ideia; o desenho depende do módulo de Bancos.
- O pseudônimo é um código aleatório, e não um "hash" do CPF, que se descobre testando todos os CPFs.
- Ninguém do financeiro digita o Pix nem entra no internet banking da conta usada para os PJ, que seria uma conta separada; o lote vai ao banco pela integração.
- Toda leitura do master fica registrada, e há dois masters, para trocar um aprovador não depender de uma pessoa só.
- Aviso aos responsáveis alguns dias antes do vencimento.
- A chave Pix não aparece para o financeiro: ela só é buscada na hora de mandar o pagamento ao banco.
- O portal do contador tem login próprio, mostra só as notas e registra cada download.
- ⏳ Sem resposta: se os pagamentos PJ continuarem passando pelo Sienge durante a transição, o nome e o valor ficam visíveis lá como credor.

**O que não dá para garantir:** o anonimato total. A chave Pix, o extrato e o comprovante do banco e a nota que vai ao contador identificam a pessoa. O que o sistema garante é que quase ninguém veja, e que toda leitura fique registrada.

⚠️ **Ponto levantado e sem resposta:** registrar benefícios de PJ no sistema pode servir de prova de vínculo empregatício. A sugestão é passar o desenho pelo jurídico antes.

### Tarefa: conferir e liberar o pagamento dos PJ do mês

> ⏳ As telas ainda não existem.

1. **Responsável do RH:** abra **Pessoal › Conferência do mês**, confira quem está ativo e os benefícios, e clique em **Dar ok**.
2. **Responsável pela remuneração:** abra a mesma tela, confira os valores e clique em **Dar ok**.
3. Com os dois "ok", as notas que os PJ subiram no portal e que batem com as tabelas seguem para pagamento.
4. **Financeiro:** vê os pagamentos só pelo pseudônimo e o valor.
5. **Contador:** recebe as notas e, se precisar, baixa pelo portal dele.

**Se der errado:** se um responsável estiver ausente, o substituto temporário dá o "ok". Se nenhum dos dois puder, o master pode aprovar ou trocar o aprovador.

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
