# Pessoas: fornecedores, clientes, sócios e corretores

[← Sumário](../README.md)

## A regra principal: uma pessoa, vários papéis

✅ **Decidido** (Moises, 7/nov/2026, no documento do modelo v1): cada pessoa ou empresa com quem a BKM se relaciona tem **um cadastro só**, com os papéis que ela exerce: fornecedor, cliente, sócio, corretor, funcionário, proprietário de terreno.

No Sienge, credor e cliente são cadastros separados, e o mesmo CNPJ aparece duas vezes. No ERP BKM, o vendedor de um terreno que também comprou uma unidade é a mesma pessoa, com dois papéis. Quando o sistema manda dados ao Sienge, ele separa em credor e cliente por trás; você não precisa fazer isso.

O cadastro guarda: CPF ou CNPJ, nome, contatos, dados bancários e Pix.

## Tarefa: cadastrar um fornecedor

> ⏳ As telas ainda não existem.

1. Abra **Cadastros › Pessoas** e procure pelo CPF ou CNPJ. Se a pessoa já existe (como cliente, por exemplo), abra o cadastro dela; não crie outro.
2. Se não existe, clique em **Nova pessoa** e informe o CPF ou CNPJ e o nome.
3. Em **Papéis**, marque **Fornecedor**.
4. Informe os dados bancários e o Pix. Eles serão a forma de pagamento padrão das notas desse fornecedor.
5. Salve.

**O que o sistema confere:** CPF ou CNPJ válido e não repetido.

**Bom saber:** no teste de 6/nov/2026, o título gerado no Sienge já veio com o Pix do fornecedor puxado do cadastro dele.
