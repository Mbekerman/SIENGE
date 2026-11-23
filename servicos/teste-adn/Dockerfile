# erp-teste-adn, Cloud Run Job do bkm-erp (teste único, apagado no fim). Contexto do build: servicos/teste-adn.
# Mesma imagem do leitor (node:22-alpine fixada pelo digest). Sem dependências: só node:https e node:zlib.
# --openssl-legacy-provider: certificado A1 costuma vir em PKCS#12 com RC2/3DES, que o OpenSSL 3 do Node 22 recusa sem ele.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a
WORKDIR /app
COPY --chown=node:node package.json logica.ts job.ts ./
USER node
ENV NODE_ENV=production
CMD ["node", "--openssl-legacy-provider", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "job.ts"]
