# erp-teste-adn, Cloud Run Job do bkm-erp (teste único, apagado no fim). Contexto do build: servicos/teste-adn.
# Mesma imagem do leitor (node:22-alpine fixada pelo digest). Sem dependências: só node:https e node:zlib.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a
WORKDIR /app
COPY package.json logica.ts job.ts ./
USER node
ENV NODE_ENV=production
CMD ["node", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "job.ts"]
