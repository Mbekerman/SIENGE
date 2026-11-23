# erp-busca-notas, Cloud Run Job do bkm-erp. Contexto do build: servicos/busca-notas.
# Mesma imagem do leitor (node:22-alpine fixada pelo digest). Só o postgres.js de dependência.
# O certificado entra em PEM (chave + certificado), sem PKCS#12: dispensa o --openssl-legacy-provider.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a
WORKDIR /app
COPY --chown=node:node package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY --chown=node:node xml.ts notas.ts ciclo.ts banco.ts job.ts ./
USER node
ENV NODE_ENV=production
CMD ["node", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "job.ts"]
