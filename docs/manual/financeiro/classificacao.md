# Como todo valor é classificado

[← Sumário](../README.md)

## As cinco perguntas

✅ **Decidido** (7/nov/2026). Todo valor do sistema (orçamento, previsão, título, pagamento) responde às mesmas cinco perguntas, cada uma com um campo próprio:

| Pergunta | Campo | Exemplo |
| --- | --- | --- |
| De quem é o gasto? | Empresa e núcleo econômico | SPE Vila Maria / núcleo Vila Maria |
| Onde ele é apropriado? | Centro de custo | Marketing |
| Que gasto é? | Natureza | Comerciais › Marketing › Marketing online |
| Quando? | Competência e data de caixa | competência out/2027, pago em nov/2027 |
| Em que momento do projeto? | Etapa, antes chamada fase (calculada sozinha, só para relatório) | Obras |

> ⚠️ **Nomes trocados em 14/nov/2026** (Moises). O que este manual chamava de **centro de custo** (a obra, o Corporativo) agora é **núcleo econômico**. O que chamava de **área** (Marketing, Comercial, Administrativo) agora é **centro de custo**. As regras não mudaram com a troca. No Sienge, "centro de custo" continua sendo a obra, ou seja, o nosso núcleo econômico. Cuidado na transição.

### O que muda em relação a hoje

Hoje a BKM usa no Sienge "centro de custo Marketing, natureza MKT Online, motivo verba Google", com cerca de 9 centros de custo por SPE. No ERP BKM:

| Hoje no Sienge | No ERP BKM |
| --- | --- |
| Centro de custo: a obra, ou uma obra fingida para a área administrativa | Núcleo econômico: a SPE ou a obra, o Corporativo, uma loja |
| Centro de custo: Marketing (um por SPE) | Centro de custo: Marketing, da lista única, ligado no núcleo |
| Natureza: MKT Online | Natureza: Comerciais › Marketing › **Marketing online** |
| Motivo: verba de mídia Google | Mais um nível da natureza (… › Mídia Google) **ou** só a descrição do lançamento |

**Regra para decidir se o "motivo" vira nível da natureza:** se você quer orçar e comparar por ele ("quanto previ e quanto gastei de Google no ano"), ele é um nível. Se só explica aquele gasto ("campanha de março"), ele vai na descrição.

**Por que os centros de custo são uma lista única:** com 30 empreendimentos e 10 centros cada, seriam 300 cadastros, e cada regra ou relatório teria de listar os que entram. Com uma lista única ligada nos núcleos, "marketing da empresa inteira", "marketing do Vila Maria" e "tudo o que o Marketing gastou" viram filtros sobre os mesmos dados.

## Três dimensões: núcleo econômico, centro de custo e natureza

✅ **Decidido** (Moises, 14/nov/2026, renomeando e ajustando o que foi decidido em 8/nov/2026). Cada lançamento leva três classificações separadas:

- **Núcleo econômico:** de quem é o gasto. É **a SPE ou a obra**, o **Corporativo** (escritório central, holding, novos negócios antes de virar SPE) ou outro negócio, como uma **loja**. Os núcleos ficam numa árvore **estado › cidade › região › núcleo**, e **cada núcleo está num lugar só** da árvore (senão os relatórios somariam em dobro). O tipo de produto é um filtro do relatório, não um nível da árvore.
- **Centro de custo:** onde a despesa é apropriada dentro do núcleo, por exemplo **Marketing, Terreno, Incorporação, Obra, Assistência técnica, Administrativo**. Todos os centros de custo ficam numa **lista única (raiz)** da empresa, e cada um é **ligado ou desligado em cada núcleo**: o Corporativo não tem Obra nem Pós-obra; uma loja não tem Incorporação. Cada centro de custo tem **aprovadores escolhidos pelo nome** e diz **quantos deles precisam aprovar**.
- **Natureza:** o plano de contas, só o tipo de gasto (Marketing online, Vigilância, Energia...).

**O centro de custo precisa estar ligado no núcleo**, senão o lançamento é recusado. 🟡 Quem liga e desliga: no banco já construído, só o administrador (regra técnica ainda sem confirmação do Moises).

**Travas, alçadas e aprovações** podem ser dadas em qualquer das três dimensões. Também se pode **liberar ou bloquear cada pessoa para lançar** em cada uma delas.

A **etapa** (até 15/nov/2026 chamada "fase") é o momento do empreendimento: Terreno, Aprovação de projetos, Incorporação, Lançamento, Obra, Pós-obra e Corporativo. **É calculada sozinha**, a partir do núcleo e da data, e serve só para os relatórios. Ninguém a escolhe no lançamento, e ela não entra no acesso nem na aprovação (Moises, 15/nov/2026).

🟡 Como o sistema sabe a etapa (em revisão, ainda não está na versão de desenvolvimento): o administrador marca, em cada núcleo, a etapa e a data em que ela começa. Por exemplo, Incorporação até março e Obra a partir de 1º de abril. Nos relatórios, cada lançamento aparece com a etapa que o núcleo tinha no mês de competência dele, mesmo que a etapa mude depois. Toda mudança de etapa fica registrada, com quem mudou e quando.

✅ **Divisão** é a subdivisão de um centro de custo, por exemplo Marketing › PDV, Online, Offline e Eventos. Decisões do Moises de 15/nov/2026 (no código a partir do PR #41):

- O administrador só **pede** para criar, renomear ou desativar uma divisão. A mudança vale quando os aprovadores de acesso aprovam; o pedido do master vale na hora. Quem tem acesso ao centro não aprova. Divisão não se apaga.
- Com divisão ativa no centro, **toda linha de rateio, previsão e orçamento precisa dizer a divisão**.
- **Acesso:** pode descer até a divisão. O modelo dá todas as divisões (inclusive as futuras, menos as excluídas) ou uma lista (com as futuras, se marcado). Cada divisão incluída pode ter nível próprio. A exceção da pessoa na divisão vence a do centro. Quem tem só algumas divisões não vê a linha do centro sem divisão.
- **Alçada:** a divisão pode ter faixas próprias, com o acumulado só da divisão. Cada faixa diz se aprova só na divisão ou se passa também pelo centro, cujo acumulado soma o centro inteiro. Divisão sem faixas segue o centro. Na alçada da divisão, o gestor da área é o gestor do centro, e o responsável da divisão entra como vaga nominal. Quem tem vaga na alçada da divisão e na do centro **aprova uma vez só**, e a aprovação vale pelas duas; em sequência, ela entra no centro quando chegar a vez dele lá. Entre duas divisões, uma aprovação não vale pela outra (Moises, 15/nov/2026).
- 🟡 **Naturezas da divisão** (em revisão, ainda não está na versão de desenvolvimento): ao criar a divisão, escolhem-se as naturezas em que se pode lançar nela. Dá para marcar todas, desmarcar todas ou escolher uma a uma. Depois, o master, o administrador e o AF, o AO e o AD ligam e desligam cada natureza na hora, sem aprovação, e toda mudança fica registrada. No centro sem divisão vale a lista do próprio centro. No centro com divisões vale a lista de cada divisão. Natureza nova nasce desligada em todas as divisões. Desligar não mexe no que já foi lançado: só impede lançar nela ou trocar para ela. Quem desliga vê os títulos em aberto que ficaram nela. O administrador (TI) também muda na hora, como exceção à regra de que as mudanças dele passam por aprovação (confirmado pelo Moises, 15/nov/2026). **Modelos de naturezas:** são listas prontas, por exemplo "Marketing online". Ao criar uma divisão, ou ao ajustar uma que já existe, aplica-se um modelo e as naturezas dele ficam marcadas de uma vez; depois dá para ajustar uma a uma. Quem cria e muda modelos são os mesmos que ligam as naturezas: master, administrador, AF, AO e AD. Tudo fica registrado.

✅ Para não confundir: cada passo de uma aprovação (gestor, AF, AD) se chama **fase de aprovação** (Moises, 15/nov/2026). "Etapa" fica só para o momento do empreendimento.

**Mover um núcleo de lugar na árvore, ou ligar e desligar um centro de custo num núcleo, exige aprovação** e fica registrado, porque muda quem vê e quem aprova. (A aprovação de ligar e desligar é 🟡 proposta, por extensão da regra de 8/nov.)

🟡 Em aberto: Terreno, Incorporação, Obra e Assistência técnica, como centros de custo, lembram a etapa do empreendimento (que é calculada sozinha) e a natureza. É preciso combinar a regra: o centro de custo diz quem responde pelo gasto, a natureza diz o que foi comprado e a etapa diz quando.

Hoje o Sienge tem 97 centros de custo, que misturam obra, tipo de gasto e momento. Eles viram cerca de 25 núcleos econômicos na árvore, mais a lista de centros de custo. ⏳ O de-para com o Sienge está em rascunho. Enquanto os títulos forem criados lá, cada combinação núcleo × centro de custo × natureza tem de apontar para exatamente uma conta e um centro de custo (obra) do Sienge, senão o título não sobe.

## A árvore de naturezas

✅ **Decidido** (7/nov/2026):

- **Uma árvore só** para a empresa inteira, com quantos níveis cada galho precisar.
- **O topo da árvore é o mesmo da viabilidade do BKM Terrenos** (Terreno, Obras, Comerciais, Gerais, Financeiras, Taxas...), para que viabilidade, orçamento e realizado se comparem sem conversão.
- **A árvore é dinâmica:** novas naturezas são criadas pela tela, sem programador (Moises, 7/nov/2026).
- **O topo também é editável** (Moises, no documento do modelo v1: "concordo, mas tem que ser editável"). Isso substitui a proposta de travar o topo.
- **A árvore é feita do zero**, não copiada do plano financeiro do Sienge (Moises, 7/nov/2026). O plano do Sienge fica ligado a ela por correspondência, por trás.

🟡 **Propostas** ainda sem confirmação:

- Só o administrador (ou o controller) cria naturezas, para não surgir "MKT Online", "Marketing online" e "Mkt digital" lado a lado.
- Só se lança no último nível (não se lança em "Comerciais", só em "Marketing online").
- A natureza nova herda as características da mãe (ver abaixo), e pode ser mudada.
- Natureza com lançamentos não se apaga direto: primeiro se reclassifica (ver [Reclassificação](reclassificacao-e-fechamento.md)).
- Natureza desativada não recebe lançamentos novos; os antigos continuam onde estão.
- Mover um galho com lançamentos para outra mãe mostra antes quanto do histórico muda de lugar.
- Mudar o lugar, o tipo, a linha da DRE ou a do fluxo de caixa de uma natureza que já tem lançamentos é só com a diretoria, porque mexe nos relatórios do passado.
- Como o topo é editável: quem edita o topo e o que acontece com a comparação com a viabilidade quando ele muda. ⏳

### Características de cada natureza

✅ **Decidido** (7/nov/2026): a classificação contábil-gerencial é **característica da natureza**, não uma escolha a cada lançamento. Quem lança escolhe só "Mídia Google", e o sistema já sabe o resto.

| Característica | Valores |
| --- | --- |
| Tipo | operacional, não operacional, movimentação |
| Linha da DRE | receita, dedução, custo, despesa comercial... |
| Linha do fluxo de caixa | operacional, investimento, financiamento |
| Redutora | sim ou não (devolução, estorno, desconto obtido) |

**Movimentação não é despesa:** transferência entre contas próprias, aplicação, resgate, aporte e distribuição entre sócios mexem no saldo do banco, mas ficam fora da DRE.

**Regra:** se uma mesma natureza às vezes é operacional e às vezes não, na verdade são duas naturezas.

### A carga inicial da árvore

🟡 Existe um rascunho (v0) com 11 grupos e cerca de 45 galhos no [documento do modelo v1](https://claude.ai/artifact/YXuHgVNLaMPRtpxJ8YWCPt). ⏳ Quatro pontos em que ele difere da viabilidade atual aguardam decisão do Moises:

1. Impostos sobre a receita passam de Financeiras para Deduções.
2. Custo de capital fica só no orçado, porque nunca vira pagamento.
3. Taxas de gestão entre empresas do grupo viram um par de lançamentos (despesa numa, receita na outra).
4. ITBI e registro das unidades vendidas vão para Comerciais › Custos de repasse.

## Rateio

✅ **Decidido** (7/nov/2026): um gasto que serve a vários núcleos, centros de custo ou naturezas (campanha institucional, aluguel da sede) é dividido em percentuais. Cada parte conta para o seu núcleo e o seu centro de custo.

## Tarefa: criar uma natureza nova

> ⏳ As telas ainda não existem.

1. Abra **Configurações › Naturezas**.
2. Encontre na árvore o galho onde a nova natureza vai ficar e clique em **Adicionar dentro**.
3. Dê o nome. Antes de salvar, confira na árvore se não existe outra com o mesmo sentido.
4. Confira o tipo, a linha da DRE e a do fluxo de caixa, que vêm da mãe. Mude só se for diferente.
5. Salve. A natureza já aparece para lançamento e para orçamento.

## Tarefa: lançar um gasto com rateio

1. No lançamento (nota, previsão ou orçamento), em **Classificação**, clique em **Ratear**.
2. Inclua uma linha por parte: núcleo econômico, centro de custo, natureza e percentual.
3. Confira que a soma dá 100%.
4. Salve. Cada parte aparece no relatório do seu núcleo e do seu centro de custo.
