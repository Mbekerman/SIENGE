#!/usr/bin/env bash
# ERP BKM, teste em escala do leitor (dev; pedido do Moises, 20/11/2026): publica o job erp-leitor-lote com o código da
# develop, a mesma conta (erp-leitor) e a mesma regra da Anthropic do erp-leitor-dev, e roda uma rodada.
# Rodar no Cloud Shell do projeto bkm-erp, depois de subir os arquivos para gs://bkm-erp-515119-anexos-dev/lote/entrada/:
#   gcloud storage cp -r <pasta com os arquivos>/* gs://bkm-erp-515119-anexos-dev/lote/entrada/
#   LOTE_LIMITE=20 bash ~/SIENGE/servicos/leitor/lote-dev.sh        (piloto: 20 arquivos, para medir o custo)
#   LOTE_LIMITE=5000 bash ~/SIENGE/servicos/leitor/lote-dev.sh      (o resto; continua de onde parou)
# Os resultados ficam em gs://bkm-erp-515119-anexos-dev/lote/saida/ (um .json por arquivo). Para trazê-los:
#   gcloud storage cp -r gs://bkm-erp-515119-anexos-dev/lote/saida ./saida && zip -qr saida.zip saida
# O job não toca o banco nem consulta boleto; só lê com a IA e grava o resultado. A trava do custo é o limite de gasto
# do workspace da Anthropic. Para desfazer: gcloud run jobs delete erp-leitor-lote --region southamerica-east1 ;
# os arquivos e resultados saem com gcloud storage rm -r gs://bkm-erp-515119-anexos-dev/lote/ (a conta do leitor não apaga).
set -euo pipefail
P=bkm-erp-515119
R=southamerica-east1
SA=erp-leitor@$P.iam.gserviceaccount.com
B=bkm-erp-515119-anexos-dev
LOTE_LIMITE=${LOTE_LIMITE:-20}
LOTE_PARALELO=${LOTE_PARALELO:-4}
gcloud config set project "$P"

# As variáveis da federação são as do erp-leitor-dev (não são segredo)
envleitor() { gcloud run services describe erp-leitor-dev --region "$R" --format=json \
  | python3 -c "import json,sys; e=json.load(sys.stdin)['spec']['template']['spec']['containers'][0].get('env',[]); print(next((x.get('value','') for x in e if x['name']=='$1'),''))"; }
FED=$(envleitor ANTHROPIC_FEDERATION_RULE_ID); ORG=$(envleitor ANTHROPIC_ORGANIZATION_ID)
CONTA=$(envleitor ANTHROPIC_SERVICE_ACCOUNT_ID); WS=$(envleitor ANTHROPIC_WORKSPACE_ID)
[ -n "$FED" ] && [ -n "$ORG" ] || { echo "Não achei a regra da Anthropic no erp-leitor-dev." >&2; exit 1; }
# CNPJs das empresas, para abrir PDF com senha como o leitor (opcional, não é segredo)
LOTE_CNPJS=${LOTE_CNPJS:-}

DIR=$(mktemp -d); git clone --depth 1 --branch develop https://github.com/Mbekerman/SIENGE.git "$DIR/SIENGE"
gcloud run jobs deploy erp-leitor-lote --source "$DIR/SIENGE/servicos/leitor" --region "$R" \
  --service-account "$SA" --tasks 1 --max-retries 0 --task-timeout 24h --memory 1Gi --cpu 1 \
  --command node --args=--experimental-strip-types,--disable-warning=ExperimentalWarning,lote.ts \
  --set-env-vars "^|^BUCKET=$B|LOTE_PARALELO=$LOTE_PARALELO|LOTE_CNPJS=$LOTE_CNPJS|ANTHROPIC_FEDERATION_RULE_ID=$FED|ANTHROPIC_ORGANIZATION_ID=$ORG|ANTHROPIC_SERVICE_ACCOUNT_ID=$CONTA|ANTHROPIC_WORKSPACE_ID=$WS"
gcloud run jobs execute erp-leitor-lote --region "$R" --update-env-vars "LOTE_LIMITE=$LOTE_LIMITE" --wait
echo "Resultados: gcloud storage ls gs://$B/lote/saida/ | wc -l"
