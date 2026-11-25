#!/usr/bin/env bash
# ERP BKM, leitor de notas (dev), passo 2: publica o serviço erp-leitor-dev a partir da develop e liga a tela a ele.
# Rodar no Cloud Shell do projeto bkm-erp, depois do passo 1 (conta erp-leitor, bucket, segredo) e da regra no Console da
# Anthropic. Os IDs da regra vêm do ambiente (não são segredo):
#   git clone --depth 1 --branch develop https://github.com/Mbekerman/SIENGE.git ~/SIENGE   (a main ainda não tem o leitor)
#   FEDERACAO=fdrl_... ORGANIZACAO=... CONTA_ANTHROPIC=svac_... WORKSPACE=wrkspc_... bash ~/SIENGE/servicos/leitor/publicar-dev.sh
# Pode rodar de novo (publica uma revisão nova com o código atual da develop).
# Para desfazer: gcloud run services delete erp-leitor-dev --region southamerica-east1 ;
#                gcloud run services update erp-web-dev --region southamerica-east1 --remove-env-vars LEITOR_URL
set -euo pipefail
P=bkm-erp-515119
R=southamerica-east1
SA=erp-leitor@$P.iam.gserviceaccount.com
B=bkm-erp-515119-anexos-dev

# IDs da regra de federação no Console da Anthropic (não são segredo)
FEDERACAO=${FEDERACAO:-}
ORGANIZACAO=${ORGANIZACAO:-}
CONTA_ANTHROPIC=${CONTA_ANTHROPIC:-}
WORKSPACE=${WORKSPACE:-}
# Asaas: a chave dá acesso à conta inteira (pagar, PIX, transferir). Só ligue (USAR_ASAAS=sim) com a chave de uma conta
# SEM SALDO e sem poder transferir, só para a simulação do boleto. Desligado, o boleto fica só com a conferência dos dígitos.
USAR_ASAAS=${USAR_ASAAS:-nao}
ASAAS_URL=https://api.asaas.com

for v in "$FEDERACAO" "$ORGANIZACAO" "$CONTA_ANTHROPIC" "$WORKSPACE"; do
  case "$v" in ""|__*) echo "Faltam os IDs da regra da Anthropic (FEDERACAO, ORGANIZACAO, CONTA_ANTHROPIC, WORKSPACE)." >&2; exit 1 ;; esac
done
gcloud config set project "$P"
ASAAS_ENV=""; ASAAS_SEGREDO=()
if [ "$USAR_ASAAS" = sim ]; then
  gcloud secrets versions describe latest --secret=asaas-chave >/dev/null 2>&1 \
    || { echo "O segredo asaas-chave ainda não tem versão: ponha a chave no Secret Manager antes." >&2; exit 1; }
  ASAAS_ENV="|ASAAS_URL=$ASAAS_URL"; ASAAS_SEGREDO=(--set-secrets ASAAS_CHAVE=asaas-chave:latest)
fi

# O endereço e a chave publicável do Supabase são os mesmos do front de dev (a chave publicável não é segredo)
WEB_URL=$(gcloud run services describe erp-web-dev --region "$R" --format='value(status.url)')
# O serviço tem dois endereços (o curto e o com o número do projeto): o leitor aceita os dois
ORIGENS=$(gcloud run services describe erp-web-dev --region "$R" --format=json | python3 -c "import json,sys
d=json.load(sys.stdin); u=json.loads(d['metadata'].get('annotations',{}).get('run.googleapis.com/urls','[]') or '[]')
print(','.join(dict.fromkeys([d['status']['url'], *u])))")
envweb() { gcloud run services describe erp-web-dev --region "$R" --format=json \
  | python3 -c "import json,sys; e=json.load(sys.stdin)['spec']['template']['spec']['containers'][0].get('env',[]); print(next((x.get('value','') for x in e if x['name']=='$1'),''))"; }
SUPABASE_URL=$(envweb SUPABASE_URL); SUPABASE_KEY=$(envweb SUPABASE_KEY)
case "$SUPABASE_KEY" in sb_publishable_*) ;; *) echo "Não achei a chave publicável no erp-web-dev." >&2; exit 1 ;; esac

# Código da develop (o repositório é público)
DIR=$(mktemp -d); git clone --depth 1 --branch develop https://github.com/Mbekerman/SIENGE.git "$DIR/SIENGE"

# O navegador chama o serviço direto (o serviço confere o login em cada pedido), por isso sem checagem de IAM. A política
# da organização bloqueia allUsers, então é --no-invoker-iam-check, como no erp-web-dev, e não --allow-unauthenticated.
# Uma instância sempre de pé (Moises, 25/11/2026): a primeira leitura não espera o servidor subir (3 a 4 s).
gcloud run deploy erp-leitor-dev --source "$DIR/SIENGE/servicos/leitor" --region "$R" \
  --service-account "$SA" --no-invoker-iam-check \
  --min-instances 1 --max-instances 2 --memory 1Gi --cpu 1 --timeout 300 --concurrency 10 \
  --set-env-vars "^|^SUPABASE_URL=$SUPABASE_URL|SUPABASE_KEY=$SUPABASE_KEY|BUCKET=$B|ORIGENS=$ORIGENS$ASAAS_ENV|ANTHROPIC_FEDERATION_RULE_ID=$FEDERACAO|ANTHROPIC_ORGANIZATION_ID=$ORGANIZACAO|ANTHROPIC_SERVICE_ACCOUNT_ID=$CONTA_ANTHROPIC|ANTHROPIC_WORKSPACE_ID=$WORKSPACE" \
  "${ASAAS_SEGREDO[@]}"

LEITOR=$(gcloud run services describe erp-leitor-dev --region "$R" --format='value(status.url)')
curl -fsS "$LEITOR/saude" && echo

# Liga a tela de dev ao leitor (a variável fica nas próximas publicações do front)
gcloud run services update erp-web-dev --region "$R" --update-env-vars "LEITOR_URL=$LEITOR"
rm -rf "$DIR"
echo
echo "Pronto. Leitor: $LEITOR"
echo "Abra $WEB_URL/titulos?novo=1 e suba uma nota."
