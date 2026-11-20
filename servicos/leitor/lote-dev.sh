#!/usr/bin/env bash
# ERP BKM, teste em escala do leitor (dev; pedido do Moises, 20/11/2026): publica o job erp-leitor-lote com o código da
# develop, a mesma conta (erp-leitor) e a mesma regra da Anthropic do erp-leitor-dev, e roda uma rodada.
# Rodar no Cloud Shell do projeto bkm-erp, depois de subir os arquivos para gs://bkm-erp-515119-anexos-dev/lote/entrada/
# (só os que não são de pessoal, folha ou PJ; a lista separada pela revisão do #110):
#   for z in lote-parte-*.zip; do unzip -q -o "$z" -d lote; done
#   gcloud storage cp -r lote/* gs://bkm-erp-515119-anexos-dev/lote/entrada/
#   LOTE_LIMITE=20 bash ~/SIENGE/servicos/leitor/lote-dev.sh        (piloto: 20 arquivos, para medir o custo)
#   LOTE_LIMITE=5000 bash ~/SIENGE/servicos/leitor/lote-dev.sh      (o resto; continua de onde parou)
# O script confere antes que o bucket não é público e liga a regra que apaga lote/ em 7 dias.
# Os resultados ficam em gs://bkm-erp-515119-anexos-dev/lote/saida/ (um .json por arquivo). Para trazê-los:
#   gcloud storage cp -r gs://bkm-erp-515119-anexos-dev/lote/saida ./saida && zip -qr saida.zip saida
# O saida.zip tem dados pessoais (CPF, valores, contas): não vai ao repositório e se apaga depois da análise.
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

# Condições da revisão do #110: o bucket não pode ser público, e lote/ se apaga sozinho em 7 dias
POL=$(gcloud storage buckets get-iam-policy "gs://$B" --format=json)
if echo "$POL" | grep -qE '"allUsers"|"allAuthenticatedUsers"'; then
  echo "O bucket $B tem acesso público (allUsers ou allAuthenticatedUsers): tire antes de subir os arquivos." >&2; exit 1
fi
echo "Quem acessa o bucket $B:"; echo "$POL" | python3 -c "import json,sys
for b in json.load(sys.stdin).get('bindings',[]): print(' ', b['role'], ', '.join(b['members']))"
T=$(mktemp)
gcloud storage buckets describe "gs://$B" --format=json | python3 -c "import json,sys
d=json.load(sys.stdin); regras=(d.get('lifecycle_config') or {}).get('rule', [])
nova={'action': {'type': 'Delete'}, 'condition': {'age': 7, 'matchesPrefix': ['lote/']}}
if nova not in regras: regras.append(nova)
json.dump({'rule': regras}, open('$T', 'w'))"
gcloud storage buckets update "gs://$B" --lifecycle-file="$T"
echo "Regra de ciclo de vida: lote/ some 7 dias depois de subir."

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
