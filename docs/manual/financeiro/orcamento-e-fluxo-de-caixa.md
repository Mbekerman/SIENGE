# Orçamento, previsões e fluxo de caixa

[← Sumário](../README.md)

## O que muda em relação ao Sienge

Hoje, para ter orçamento de uma área administrativa, a BKM cadastra a área como uma obra. O orçamento da obra é feito fora e depois lançado no Sienge. O Moises quer fazer tudo dentro do sistema, desde o zero (7/nov/2026).

## Os quatro estágios de todo valor

✅ **Decidido** (Moises, 7/nov/2026). Todo valor do sistema está num destes estágios, e todos ficam no mesmo livro, com a mesma classificação:

| Estágio | De onde vem | Exemplo |
| --- | --- | --- |
| **Orçado** | Versões do orçamento | "Marketing do Vila Maria: R$ 300 mil em 2027" |
| **Previsto** | Previsões (assinaturas, saldo de contrato, cronograma) | "Internet de março: R$ 400" |
| **Comprometido** | Títulos em aberto e caução retida | "Parcela de R$ 3.000 vence em 10/03" |
| **Realizado** | Pagamentos | "Pago R$ 3.000 em 10/03" |

## Versões do orçamento

✅ **Decidido** (7/nov/2026). O orçamento de cada empreendimento tem versões datadas, e nenhuma é sobrescrita:

1. **Viabilidade**: vem do estudo válido do BKM Terrenos.
2. **Aprovado**: a base de comparação.
3. **Reprojeções**: as revisões ao longo do tempo.

✅ Publicada, a versão não muda mais: não volta a rascunho, não se edita e não se apaga. Para mudar, cria-se uma reprojeção (trava autorizada pelo Moises, 14/nov/2026). Publicar uma nova viabilidade ou um novo aprovado substitui a vigente do mesmo tipo, e a anterior fica no histórico.

O **custo de capital** (permuta financeira, pagamento do terreno) existe só no orçado, porque nunca vira pagamento. 🟡 Proposta, uma das 4 divergências da árvore ainda em aberto.

## Fluxo de caixa

✅ **Decidido** (7/nov/2026). O fluxo de caixa não é um cadastro que alguém alimenta: é uma **visão** que soma, por data de caixa, o previsto em aberto, o comprometido em aberto e o realizado. Serve para curto, médio e longo prazo, por empresa ou para o grupo.

## Orçamento de área

✅ **Decidido** (Moises, 23/nov/2026). Serve para planejar a despesa de uma área (Marketing, Administrativo...) sem fornecedor: o quanto se espera gastar por mês em cada natureza, num centro de custo ou num nível dele (por exemplo, Marketing › Mídia Online). Com ele, o fluxo de caixa já mostra a despesa antes de a nota chegar, e depois dá para comparar o previsto com o realizado.

> ⏳ As telas ainda não existem. O banco já faz tudo o que está abaixo.

- **Um orçamento por empresa, centro de custo e ano**, com linhas de natureza, nível do centro e mês. O nível pode ser o próprio centro ou qualquer divisão, inclusive uma com níveis abaixo: aí ele vale para a soma dos de baixo.
- **É informativo.** Não aprova nada antes: a nota que passa do orçado segue a alçada normal, como se o orçamento não existisse. O orçamento também não conta no acumulado do mês da alçada.
- **Quem cria e revisa:** o gestor do centro (ou o master).
- **Quem aprova:** a AF junto com um AO ligado ao centro, ou o AD sozinho (o master também). Quem montou ou mexeu por último não aprova o próprio orçamento (o master pode). Recusar exige justificativa e o orçamento volta para a montagem.
- **Cada mês vira uma previsão sem fornecedor**, do mês corrente em diante, e cada previsão vai ao Sienge como título PRV (todos os meses do ano, não só os próximos).
- **A nota abate o orçado sozinha:** ao lançar a nota, ela consome a previsão do orçamento da mesma natureza e do mesmo mês, no nível em que a despesa foi lançada ou num nível acima (o mais próximo primeiro). Não é preciso escolher nada.
- **Na hora em que uma nota consome (ou é cancelada),** a previsão daquela linha é refeita com o saldo: a antiga vai para a lista de PRV a apagar no Sienge e entra uma nova com o que sobrou. Se não sobrar nada, só sai. O Sienge não aceita título com valor negativo, então o que passa do orçado não vira previsão. Até alguém apagar o PRV antigo no Sienge, o fluxo de caixa do Sienge mostra os dois.
- **Fora do orçamento:** quem lança a nota pode marcá-la como fora do orçamento, com o motivo, antes de enviar. Ela não abate nada.
- **Revisão:** cria-se uma cópia da versão vigente, muda-se o que for preciso e envia-se para aprovar de novo. Aprovada, só as linhas que mudaram trocam de PRV no Sienge. Os meses que já passaram não mudam.
- **Sobra do mês:** o que não foi gasto sai das previsões 10 dias depois do fim do mês (prazo configurável, de 0 a 60 dias).

**O que não dá, nesta versão:** o título lançado sem nota não abate o orçado; a nota lançada antes de o orçamento (ou uma linha nova da revisão) ser aprovado também não; o aviso de orçamento enviado chega a todos os AO, embora só o AO do centro possa aprovar.

### Tarefa: montar o orçamento de área

> ⏳ As telas ainda não existem; os nomes são provisórios.

**Para que serve:** pôr no fluxo de caixa a despesa prevista da sua área.
**Quem faz:** o gestor do centro de custo.
**Antes de começar:** tenha os valores por natureza e por mês, e saiba em que nível do centro cada um fica.

1. Abra **Financeiro › Orçamentos de área** e clique em **Novo orçamento**.
2. Escolha a empresa, o centro de custo e o ano.
3. Inclua as linhas: natureza, nível, mês e valor (a data de pagamento é opcional; sem ela, vale o fim do mês).
4. Clique em **Enviar para aprovar**.

**O que o sistema confere:** a natureza precisa estar liberada no nível escolhido; natureza restrita (PJ) e de "só orçado" não entram; o mês tem de ser do ano do orçamento; não se repete natureza, nível e mês; o valor é positivo.

**E depois?** A AF e um AO do centro (ou o AD) recebem o aviso para aprovar. Aprovado, as previsões nascem e vão ao Sienge.

### Tarefa: aprovar um orçamento de área

**Quem faz:** AF, AO ligado ao centro ou AD.

1. Abra o orçamento pelo aviso.
2. Confira as linhas e clique em **Aprovar**, ou em **Recusar** com a justificativa.

**E depois?** Com a AF e o AO (ou o AD), o orçamento vira o vigente. Com recusa, volta para o gestor.

### AO do centro na alçada de pagamento

✅ **Decidido** (Moises, 23/nov/2026). Cada AO pode ficar ligado a um ou mais centros. Nas faixas da alçada de pagamento há uma vaga nova, opcional, **AO do centro**: só um AO ligado ao centro do título (ou o AD) a ocupa. A vaga **AO** continua aceitando qualquer AO. Assim dá para ter faixas em que o gestor aprova sozinho e faixas que pedem também o AO do centro.

## Orçamento de obra

⏳ **A definir** (sessão de engenharia). O que já se sabe: o orçamento de obra (serviços, composições, insumos, cronograma) entra no orçamento do empreendimento convertido em dinheiro mês a mês. O detalhe em quantidades fica no módulo de engenharia, que também vai gerar a curva de compras e permitir ver sobra de material de uma obra quando outra pede.

## Tarefa: comparar viabilidade, orçado e realizado de um empreendimento

> ⏳ As telas ainda não existem.

1. Abra **Relatórios › Orçado × realizado**.
2. Escolha o empreendimento e o período.
3. Escolha as versões a comparar (por exemplo, Viabilidade e Aprovado).
4. Veja as colunas: viabilidade, orçado, previsto, comprometido, realizado e a diferença.
5. Clique numa natureza para abrir os galhos de baixo, até chegar aos lançamentos.

## Tarefa: ver o fluxo de caixa

1. Abra **Financeiro › Fluxo de caixa**.
2. Escolha a empresa (ou o grupo inteiro) e o período.
3. Veja, por dia, semana ou mês, o previsto, o comprometido e o realizado.
4. Clique num valor para ver as previsões, os títulos ou os pagamentos que o compõem.
