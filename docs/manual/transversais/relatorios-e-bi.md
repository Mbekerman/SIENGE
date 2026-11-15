# Relatórios e BI

[← Sumário](../README.md)

## Relatórios dentro do sistema

✅ **Decidido** (Moises, 8/nov/2026):

- Os **gráficos e as análises ficam no próprio sistema**. O Power BI deixa de ser usado.
- **Quem vê o quê é liberado no sistema, pessoa a pessoa.** Também dá para criar **grupos**: quem entra num grupo passa a ver o que o grupo vê.
- **O acesso combina núcleo econômico e centro de custo** (Moises, 8/nov/2026; nomes trocados em 14/nov/2026): a pessoa vê o que está ao mesmo tempo nos núcleos e nos centros de custo liberados para ela, **com herança para baixo** (quem tem "São Paulo" vê todos os núcleos de São Paulo). A fase não entra no acesso. ✅ Também se pode liberar ou bloquear cada pessoa para **lançar** em cada uma das três dimensões: núcleo, centro de custo e natureza (Moises, 14/nov/2026).
- A **folha PJ** aparece só somada por núcleo econômico e mês.
- Datas e horas são gravadas e mostradas no **horário de São Paulo**. (Um pagamento às 22h do dia 31 fica no dia 31, não no mês seguinte.)
- Todas as datas de um lançamento (competência, emissão, vencimento, pagamento) podem ser usadas nos relatórios; a competência é a data padrão. Também aparecem os dias de atraso (pagamento menos vencimento) e o prazo de pagamento (pagamento menos emissão).

✅ O Power BI não fica nem como ponte (Moises, 8/nov/2026).

### Perfis de acesso (Moises, 14/nov/2026)

- ✅ O acesso é dado por **perfis-modelo** salvos. Em cada centro de custo, o perfil é **Leitor**, **Lançador restrito** (vê só o que ele mesmo lançou) ou **Lançador**. A pessoa fica ligada ao modelo, e uma pessoa pode ter vários.
- ✅ Cada atribuição tem **validade** e um **escopo de núcleos**, de um de três jeitos: (a) os núcleos marcados na hora, mais os criados depois nos tipos escolhidos; (b) todos, inclusive os futuros; (c) todos dos tipos escolhidos. Os três aceitam exceções.
- ✅ Quando duas atribuições se sobrepõem, vale o nível maior. A exceção individual vence o modelo.
- ✅ Os **tipos de núcleo** são uma lista que o administrador edita.
- ✅ **Natureza restrita** é uma marca que o administrador põe na natureza; ela só abre com liberação própria. No início, pró-labore e folha PJ.
- ✅ Ninguém muda o próprio acesso.

### Quem vê e quem grava cada registro

✅ Regras no código desde 15/nov/2026 (PR #34, juntado na develop):

1. Usuário inativo não vê nada. O usuário só da sucessão vê apenas o próprio cadastro e a sucessão. Sem cadastro ativo, ninguém grava.
2. Título, nota e contrato: vê quem vê alguma linha do rateio pelo perfil (núcleo × centro × natureza). Se alguma linha é de natureza restrita (PJ) que a pessoa não vê, o registro some inteiro, e o pagamento que o baixa também.
3. O lançador restrito vê e mexe só no que ele lançou.
4. Quem aprova o título na rodada (lista da etapa, diretoria, gestor da área) vê o título, inclusive o de PJ.
5. Linha sem núcleo e sem centro: só a diretoria e o financeiro veem. Transferência entre contas: só o financeiro e o master gravam. Movimento entre sócios: só a diretoria e o financeiro registram.
6. Configuração: todos leem; só o administrador ou o master gravam.
7. O papel leitura não grava, mesmo com perfil de lançador.
8. Para confirmar título, lançar nota, liberar caução ou publicar orçamento, é preciso poder lançar em **todas** as linhas. Quem ajusta título em revisão também.
9. No acumulado da alçada, quem aprova vê em detalhe só os títulos a que tem acesso; o resto aparece numa linha só, "Outros N títulos (sem acesso)", com a soma.

🟡 Proposta ainda não decidida: a natureza PJ fica fora de qualquer combinação, com acesso próprio (a "natureza restrita" acima já cobre parte disso).

## Controle de prazos do pagamento (SLA)

✅ **Decidido** (Moises, 8/nov/2026): o sistema mede **quantos dias antes do vencimento a nota foi postada** e **quanto tempo levou cada etapa** até a nota ser paga.

- O controle só vale para o que passar pelo pedido de pagamento, a partir da implantação. O Sienge não tem esse histórico, e da última etapa ele informa só o dia do pagamento, sem a hora.
- ⏳ A definir: a antecedência mínima da postagem e a meta de cada etapa (proposta: em dias úteis, definidas pelo administrador); e se o relógio para quando a nota volta para correção.

## Um livro único para todos os números

✅ **Decidido** (7/nov/2026). Cada etapa do sistema (orçamento, previsão, título, pagamento, caução) escreve linhas num **livro de lançamentos único**, sempre com as mesmas classificações: empresa, núcleo econômico, centro de custo, natureza, fase, competência, data de caixa e estágio (orçado, previsto, comprometido, realizado).

É desse livro que saem os relatórios, o BI, o fluxo de caixa e as respostas dos agentes de IA. Perguntas como estas viram um filtro, sem montar planilha:

- "Quanto gastei de marketing na empresa inteira em 2027?"
- "Viabilidade × orçado × realizado do Vila Maria."
- "Tudo o que o centro de custo Marketing gastou, inclusive fora da natureza marketing."
- "Marketing por praça, por faixa MCMV, por mês."

✅ O livro só cresce: nenhuma linha é apagada ou editada. Desfazer é lançar uma linha de sinal contrário. A única exceção é a natureza, que muda pela [reclassificação](../financeiro/reclassificacao-e-fechamento.md) aprovada e guarda a anterior.

## Atributos dos empreendimentos nos relatórios

✅ Cidade, estado, regional, praça, linha de produto, faixa MCMV e outros atributos ficam no cadastro do empreendimento, e o relatório os mostra como colunas de cada lançamento (Moises aceitou em 7/nov/2026). ~~O relatório usa o valor que valia na data do lançamento.~~ ✅ **Mudou** (Moises, 8/nov/2026): a visão padrão é a de hoje (por exemplo, a regional atual do empreendimento), e há também uma foto de como era em cada mês, para comparar as duas.

## Tarefa: montar um relatório por natureza

> ⏳ As telas ainda não existem.

1. Abra **Relatórios › Lançamentos**.
2. Escolha o período e o estágio (orçado, previsto, comprometido ou realizado, ou vários lado a lado).
3. Filtre pela natureza (um galho inteiro, como Comerciais › Marketing) e, se quiser, por empresa, empreendimento, praça ou outro atributo.
4. Escolha como agrupar: por empreendimento, por mês, por praça...
5. Clique num número para ver os lançamentos que o compõem.
