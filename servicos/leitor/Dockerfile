# erp-leitor no Cloud Run (projeto bkm-erp). Contexto do build: servicos/leitor.
# Mesma imagem do front (node:22-alpine fixada pelo digest, 18/11/2026), o qpdf para abrir PDF com senha e o
# pdftotext (poppler-utils) para ler o texto do PDF sem IA.
FROM node:22-alpine@sha256:1314fb30ec37592d5845e5a160d522c0e680972aa534549940b8d73bde88481a
RUN apk add --no-cache qpdf poppler-utils
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY *.ts ./
RUN rm -f *.test.ts
USER node
ENV NODE_ENV=production PORT=8080
EXPOSE 8080
CMD ["node", "--experimental-strip-types", "--disable-warning=ExperimentalWarning", "servidor.ts"]
