# 6. Registro de decisões

Decisões que mudam a arquitetura ou o código, da mais recente para a mais antiga. Quem decide é o Moises; "proposta" é sugestão ainda não confirmada por ele. Decisões de negócio detalhadas (regras para o usuário) ficam no manual do usuário; aqui só o que o desenvolvedor precisa saber.

## 7/nov/2026

- **Núcleo v0 construído** (branch `claude/project-thread-dknc98`): 42 tabelas no `nucleo`, 108 testes. Esquema fechado à API do Supabase (só o servidor usa) até haver RLS. Pagamento sempre passa por Adiantamentos antes da quitação.
- **Topo da árvore de naturezas é editável** (Moises, no doc do modelo v1), contrariando a proposta de topo fixo. Só o administrador mexe; mudanças que alteram o passado (mover galho, tipo, DRE, fluxo de caixa de natureza com lançamentos) só pela diretoria.
- **Árvore dinâmica:** lançamento só na folha; filha herda tipo, DRE e fluxo de caixa; desativar em vez de apagar; natureza com lançamentos só se apaga pela reclassificação.
- **Fechamento de mês** passa a existir (a BKM não fechava).
- **Reclassificação** sempre com aval; alçadas pela idade (mês aberto, trimestre do calendário aberto, trimestre fechado), pelo valor e pelo acumulado da pessoa no mês (soma absoluta, no mês da ação); vale a mais alta. Faixas de valor ficam para a sessão de aprovação.
- **Tipo operacional / não operacional / movimentação, linha da DRE e do fluxo de caixa** são características da natureza, não escolha por lançamento.
- **Atributos de BI** (cidade, praça, faixa MCMV...) ficam no empreendimento, com vigência, e a visão `v_lancamentos_bi` junta com o livro (Moises aceitou a view no lugar de colunas no livro).
- **Dimensões independentes:** empresa e centro de custo (empreendimento ou área), natureza em árvore única, competência e caixa, fase, departamento. Centro de custo nunca é um por natureza.
- **Pessoa única com papéis**, no lugar de credor e cliente separados (confirmado no doc).
- **Estágios do livro:** orçado, previsto, comprometido, realizado (confirmado no doc).
- **Gasto anterior à SPE:** o Moises abriu para aporte, integralização de capital ou empréstimo; a escolha caso a caso ainda não está no código (o v0 tem os tipos de movimento societário).
- **Empresas numa tabela só + participações com vigência**; SPE e empreendimento separados, 1 para 1; praça e regional como lista, não tag.
- **Camadas `sienge_bruto` e `sienge` aprovadas.**

## 6/nov/2026

- **Repositórios:** `Mbekerman/SIENGE` é o código do projeto; `Mbekerman/sienge-api-docs` é só a documentação da API.
- **Banco no Supabase BKM_Desenvolvimento_Imobiliario**, mesmo do BKM Terrenos (proposta aceita no plano).
- **Escopo inicial:** medições mensais sobre contratos criados à mão no Sienge.
- **Título no Sienge nasce completo quando a nota chega; previsões ficam no nosso sistema** (conclusão dos testes 8417 e 8422).
- **Aprovação acontece no nosso sistema;** a autorização de pagamento no Sienge vira o último clique do financeiro (a API não autoriza pagamento).
- **Segredo da API como Basic** no ambiente de nuvem, restrito a `api.sienge.com.br` e `/bkmincorporadora/`.
- **Ordem de migração:** espelho → contas a pagar e medições → suprimentos, orçamento e obra → contas a receber e banco → fiscal e contábil.
- **Credenciais do Sienge só no servidor**, nunca no navegador.
