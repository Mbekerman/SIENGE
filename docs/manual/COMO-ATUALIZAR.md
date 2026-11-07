# Como este manual é mantido

[← Sumário](README.md)

Esta página é para quem mantém o manual (pessoas ou sessões do Claude), não para o usuário final.

## Regras

1. **Público:** o usuário do sistema, que nunca o usou. Nada de nome de tabela, função ou código. Termos técnicos só se estiverem no [glossário](glossario.md).
2. **Toda tela nova ou alterada atualiza o manual** (Moises, 7/nov/2026). Quem cria ou muda uma tela avisa a manutenção do manual. Proposta: nenhuma tela é dada como pronta sem o trecho dela no manual, com imagens de desktop e celular.
3. **Toda regra leva marca:** ✅ Decidido (com a data), 🟡 Proposta ou ⏳ A definir. Uma decisão nova do Moises troca a marca e entra no [registro de decisões](registro-de-decisoes.md).
4. **Toda tarefa segue o formato:** Para que serve, Quem faz, Antes de começar, Passo a passo, O que o sistema confere, E depois? (e "Se der errado" quando houver avisos).
5. **Cada seção tem "o que dá" e "o que não dá"**, com o motivo. Todo passo que continua manual no Sienge fica em destaque na página e entra na tabela [O que ainda é feito à mão no Sienge](transversais/passos-manuais-no-sienge.md) (regra do projeto aprovada pelo Moises, 7/nov/2026).
6. **Enquanto a tela não existe,** os nomes de botões são provisórios e a tarefa leva o aviso "As telas ainda não existem". Quando a tela existir, os passos passam a ser os cliques reais.
7. **Fontes:** as conversas do projeto, as decisões que o coordenador repassa e os documentos de desenho. Nunca afirmar sobre o Sienge sem conferir na documentação da API (repositório sienge-api-docs) ou em teste.

## Organização

- Uma pasta por módulo (`cadastros`, `financeiro`, `suprimentos`, depois `engenharia`, `comercial`...), um arquivo por seção.
- `transversais/` para o que vale em todos os módulos.
- Imagens, quando houver, em `docs/manual/imagens/<modulo>/`.
