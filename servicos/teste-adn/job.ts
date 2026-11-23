// Teste de cobertura do ADN (NFS-e nacional), Cloud Run Job do bkm-erp, rodado uma vez e apagado
// (pedido do Moises em 20/11/2026; guarda escolhida por ele em 21/11/2026: Secret Manager + conta própria).
// Só LÊ o ADN (GET com o certificado da empresa). Não grava em banco, bucket nem Sienge, e não tem endereço público.
// O resultado sai no log do job, só o resumo (contagens por mês e por município): sem XML e sem CNPJ de terceiros.
// Variáveis: ADN_CERT_PFX_B64 e ADN_CERT_SENHA (do Secret Manager, montadas pelo rodar-dev.sh), ADN_CNPJ,
// ADN_NSU (de onde começar, padrão 0) e ADN_LOTES (quantos lotes de até 50, padrão 200, máximo 400).
import { request } from 'node:https';
import { gunzipSync } from 'node:zlib';
import { lerLote, lerNota, resumir, type Nota } from './logica.ts';

const BASE = process.env.ADN_BASE ?? 'https://adn.nfse.gov.br/contribuintes';

function obter(url: string, pfx: Buffer, passphrase: string): Promise<{ status: number; corpo: unknown }> {
  return new Promise((ok, falha) => {
    const r = request(url, { method: 'GET', pfx, passphrase, headers: { Accept: 'application/json' }, timeout: 60_000 }, (res) => {
      const partes: Buffer[] = [];
      res.on('data', (p) => partes.push(p));
      res.on('end', () => {
        let corpo: unknown = {};
        try { corpo = JSON.parse(Buffer.concat(partes).toString('utf8')); } catch { /* corpo não JSON fica vazio */ }
        ok({ status: res.statusCode ?? 0, corpo });
      });
    });
    r.on('timeout', () => r.destroy(new Error('tempo esgotado')));
    r.on('error', falha);
    r.end();
  });
}

async function main() {
  const b64 = process.env.ADN_CERT_PFX_B64, senha = process.env.ADN_CERT_SENHA;
  if (!b64 || senha === undefined) throw new Error('faltam ADN_CERT_PFX_B64 e ADN_CERT_SENHA');
  const cnpj = (process.env.ADN_CNPJ ?? '').replace(/\D/g, '');
  if (cnpj.length !== 14) throw new Error('ADN_CNPJ ausente ou inválido');
  const pfx = Buffer.from(b64, 'base64');
  let nsu = Number(process.env.ADN_NSU ?? '0');
  const lotes = Math.min(Number(process.env.ADN_LOTES ?? '200'), 400);
  const notas: (Nota | null)[] = [];
  const respostas: { nsu: number; http: number; status: string; docs: number }[] = [];
  for (let i = 0; i < lotes; i++) {
    const { status, corpo } = await obter(`${BASE}/DFe/${nsu}?cnpjConsulta=${cnpj}&lote=true`, pfx, senha);
    const l = lerLote(corpo);
    respostas.push({ nsu, http: status, status: l.status, docs: l.docs.length });
    if (status < 200 || status >= 300 || !l.docs.length) break;
    for (const d of l.docs) {
      if (d.tipo && !/nfse/i.test(d.tipo)) continue; // eventos (cancelamento etc.) ficam fora da contagem
      notas.push(d.xmlGzipB64 ? lerNota(gunzipSync(Buffer.from(d.xmlGzipB64, 'base64')).toString('utf8')) : null);
    }
    nsu = (l.maiorNsu ?? nsu) + 1;
    await new Promise((ok) => setTimeout(ok, 1000)); // sem pressa: o limite do ADN não é documentado
  }
  // Só o resumo no log; as primeiras e as últimas respostas bastam para ver se parou por erro ou por fim.
  console.log(JSON.stringify({ proximoNsu: nsu, lotesLidos: respostas.length,
    respostas: respostas.length > 6 ? [...respostas.slice(0, 3), ...respostas.slice(-3)] : respostas,
    resumo: resumir(notas, cnpj) }));
}

main().catch((e) => { console.error(JSON.stringify({ erro: String((e as Error).message ?? e) })); process.exit(1); });
