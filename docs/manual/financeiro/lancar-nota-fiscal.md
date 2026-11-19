# Lançar uma nota fiscal para pagamento

[← Sumário](../README.md)

## Como o Moises quer que seja

✅ **Pedido do Moises** (6/nov/2026): a pessoa recebe a nota, entra no sistema, clica em **Lançar nota fiscal** e sobe o PDF. O sistema lê a nota, descobre sozinho a qual contrato ela se refere e abre o formulário já preenchido: valores, número, impostos retidos e a forma de pagamento padrão do fornecedor. A pessoa confere, ajusta o que precisar e confirma. Daí a nota vai para o financeiro conferir e mandar pagar.

## O que acontece quando você lança uma nota

✅ **Decidido** (7/nov/2026). Uma nota lançada gera três coisas de uma vez:

1. **O título do fornecedor**, pelo valor líquido: valor da nota menos impostos retidos, caução e adiantamento abatido.
2. **Um título por imposto retido**, contra o órgão que recebe (ISS para a prefeitura, INSS, IR, PIS/COFINS/CSLL para a Receita).
   - ✅ **A retenção não é natureza** (Moises, 16/nov/2026). Ela fica registrada no título da nota, com tipo, base, alíquota, valor e a guia que a recolheu. A despesa entra pelo valor cheio: uma consultoria de R$ 10 mil com R$ 1,5 mil retidos custa R$ 10 mil. Saem do plano as contas "(-) Retenção" (2080101 a 2080105 e 1020301 a 1020305), que não tiveram lançamento no último ano.
   - ✅ **A guia de recolhimento continua como natureza**, no grupo Movimentações: IRRF, INSS, ISS e PIS/COFINS/CSLL de terceiros.
   - ✅ **Conferência:** o sistema mostra três coisas:
     - o retido contra o recolhido por mês, imposto e centro, com a diferença em destaque;
     - para cada fornecedor, as notas com o valor retido e a guia que pagou cada uma;
     - um aviso para guia sem nota e para nota retida sem guia.
3. **Uma entrada no extrato de caução** do contrato, se houver caução (ver [Caução](caucao.md)).

E ainda **consome as previsões** do contrato ou da assinatura, da mais antiga para a mais nova, até o valor da nota.

### Exemplo

Nota de serviço de R$ 10.000,00, com ISS de 5% retido e caução de 5% do contrato:

| Item | Valor |
| --- | --- |
| Valor da nota | R$ 10.000,00 |
| ISS retido (5%) | − R$ 500,00 → título para a prefeitura |
| Caução (5%) | − R$ 500,00 → extrato de caução do contrato |
| **Título do fornecedor** | **R$ 9.000,00** |

---

## Competência da nota

- ✅ A competência da nota (e do título avulso) fica **no máximo no mês seguinte ao da emissão**. O administrador pode mudar essa janela (Moises, 14/nov/2026).
- 🟡 A conferir com o Moises: o código também aceita até **1 mês antes** da emissão. Ele falou só do mês seguinte.
- ✅ Fora da janela, só com uma **exceção aprovada por alguém da AF ou da AD**, com justificativa. Quem lançou não aprova. Se a competência mudar depois, a exceção deixa de valer e é preciso outra.

## Tarefa: lançar uma nota fiscal

> 🟡 **Primeira tela de lançamento, no PR #93** (ainda não juntado). Ela é mais simples que o desenho de 6/nov/2026, que segue abaixo como o destino.

### O que a tela do PR #93 já faz

O botão **Lançar título** fica na página Títulos e abre uma janela com estas seções, nesta ordem:

1. **Documento:** empresa, fornecedor (busca por nome, nome fantasia ou CNPJ), tipo (NFS-e, NF-e, Fatura, Boleto, Recibo ou Outro), número, série, emissão, competência e valor.
2. **Onde entra:** núcleo, centro, divisão do último nível e natureza. A lista de naturezas traz só as que a pessoa pode lançar ali. O botão "Ratear" acrescenta linhas, cada uma com o seu percentual.
3. **Previsões que a nota consome:** as previsões abertas do fornecedor com o mesmo núcleo, centro e natureza. Cada uma mostra o número PRV no Sienge, a data e o saldo, e aparece "Esperando aprovação" quando for o caso. A pessoa marca quais a nota consome.
4. **Pagamento:** a nota se divide em parcelas iguais, e cada parcela é PIX ou boleto. A chave PIX sugerida é o CNPJ do fornecedor; outra chave de CPF ou CNPJ pede justificativa. O centavo que sobra vai na primeira parcela, como no Sienge (por exemplo, R$ 900,01 em 2 parcelas fica R$ 450,01 + R$ 450,00).
5. **Etiquetas.**

Ao clicar em **Lançar**, o título vai para a aprovação e abre na gaveta. Se faltar alguma coisa, o pé da janela diz o quê.

**Ainda não dá para fazer:**
- ler o PDF ou o XML;
- reter impostos ou caução;
- adiantar sem nota;
- salvar rascunho;
- escrever uma descrição.

### O desenho completo (6/nov/2026)

Alguns pontos dependem de decisões em aberto, indicadas abaixo.

**Quem faz:** 🟡 alguém da BKM, normalmente o responsável pelo contrato. Abrir para o próprio fornecedor subir a nota fica para depois (proposta de 6/nov/2026, sem confirmação).

**Antes de começar:** o PDF da nota (e o XML, se o fornecedor mandou); o contrato ou a assinatura já cadastrados.

**Passo a passo:**

1. Clique em **Lançar nota fiscal**.
2. Arraste o PDF da nota. Se tiver o XML, suba junto: ele é exato, enquanto o PDF depende da leitura automática.
3. Espere a leitura. O sistema extrai emitente, tomador, número, data, valores, impostos retidos e descrição.
4. Veja o contrato que o sistema encontrou. Ele procura pelo par **CNPJ de quem emitiu + CNPJ de quem foi cobrado** (o tomador diz qual empresa ou SPE da BKM, ou seja, qual obra).
   - Se ele não encontrar, ou se houver mais de um contrato possível, escolha na lista. A lista mostra só os contratos ligados ao seu perfil.
5. Confira o formulário: número, data, valor, impostos retidos, caução (vem a do contrato, e você pode mudar nesta nota) e vencimento.
6. Confira a forma de pagamento. Vem a padrão do fornecedor (Pix ou conta). Se for boleto, suba o boleto ou digite o código de barras.
7. Confira a classificação (núcleo econômico, centro de custo e natureza), que vem do contrato.
8. Clique em **Confirmar**.

**O que o sistema confere:**

| Situação | O que acontece |
| --- | --- |
| Nota já lançada (mesmo emitente, tipo, número e série) | Recusa |
| Tomador não é empresa da BKM | Recusa |
| Valor acima do saldo do contrato | 🟡 Bloqueia, porque o aditivo só se faz no Sienge |
| Imposto retido na nota diferente do esperado | 🟡 Segue com alerta e o financeiro decide (proposta de 6/nov/2026) |
| Valor que não fecha no centavo ao converter para a medição | Avisa antes de lançar (ver [Medições](../suprimentos/contratos-e-medicoes.md)) |

**Não dá para detectar:** nota falsa ou adulterada em PDF. Conferir na prefeitura ou na SEFAZ é um passo a avaliar.

**E depois?** A nota segue para aprovação e para o financeiro. O caminho até o Sienge depende de uma decisão em aberto:

## ⏳ Em aberto: como a nota chega ao Sienge

| Caminho | Como funciona | Custo |
| --- | --- | --- |
| **Medição do contrato** | O sistema cria a medição no Sienge, os 2 gestores aprovam no ERP BKM, o sistema autoriza no Sienge, o analista **libera à mão no Sienge** (com a ficha pronta), e o sistema completa o título depois | Sobra um passo manual, a liberação. O Sienge controla o saldo do contrato |
| **Título avulso** | O sistema cria o título completo no Sienge, já com os impostos | Tudo automático, mas o saldo do contrato passa a ser controlado só pelo ERP BKM |

✅ **Na primeira etapa da implantação, fora a obra, vale o título avulso** (Moises, 8/nov/2026): o fluxo roda no ERP BKM até a nota, e o título é criado completo no Sienge pela API. Ver [Contas a pagar › Primeira etapa](contas-a-pagar.md#primeira-etapa-da-implantação-o-pedido-de-pagamento). ⏳ Para a obra (medições), o caminho continua em aberto. Foi sugerido também perguntar ao suporte do Sienge se existe liberação automática ou API de liberação.
