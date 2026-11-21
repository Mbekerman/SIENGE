// Teste de cobertura do ADN (NFS-e nacional), Edge Function do Supabase (Deno), só no bkm_dev.
// Pedido do Moises em 20/11/2026: ver se as notas de serviço que a BKM recebe aparecem no ambiente nacional
// antes de decidir construir a busca de notas aqui em vez de contratar.
// Só LÊ o ADN (GET com o certificado da empresa). Não grava nada em banco nenhum nem manda nada ao Sienge.
// Segredos (Edge Functions › Secrets), cadastrados pelo Moises, nunca no repositório:
//   ADN_CERT_PFX_B64 (o arquivo .pfx em base64), ADN_CERT_SENHA, ADN_CNPJ (14 dígitos) e TESTE_ADN_CHAVE
//   (chave de quem chama, cabeçalho x-teste-chave). Apagar os segredos ao fim do teste, se o Moises decidir.
// Chamada: POST /teste-adn?nsu=0&lotes=20  → devolve o resumo e o NSU para continuar.
import forge from 'npm:node-forge@1.3.1';
import { lerLote, lerNota, resumir, type Nota } from './logica.ts';

const BASE = Deno.env.get('ADN_BASE') ?? 'https://adn.nfse.gov.br/contribuintes';

function pem(): { cert: string; key: string } {
  const b64 = Deno.env.get('ADN_CERT_PFX_B64'), senha = Deno.env.get('ADN_CERT_SENHA');
  if (!b64 || senha === undefined) throw new Error('faltam os segredos ADN_CERT_PFX_B64 e ADN_CERT_SENHA');
  const p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.decode64(b64)), senha);
  const chave = p12.getBags({ bagType: forge.pki.oids.pkcs8ShroudedKeyBag })[forge.pki.oids.pkcs8ShroudedKeyBag]?.[0]?.key;
  const certs = p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] ?? [];
  if (!chave || !certs.length) throw new Error('certificado sem chave ou sem cadeia');
  return { key: forge.pki.privateKeyToPem(chave), cert: certs.map((c) => forge.pki.certificateToPem(c.cert!)).join('') };
}

async function gunzipB64(b64: string): Promise<string> {
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const s = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
  return await new Response(s).text();
}

function iguais(a: string, b: string): boolean {
  if (!a || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  const chave = Deno.env.get('TESTE_ADN_CHAVE') ?? '';
  if (!iguais(req.headers.get('x-teste-chave') ?? '', chave)) return new Response('não autorizado', { status: 401 });
  const cnpj = (Deno.env.get('ADN_CNPJ') ?? '').replace(/\D/g, '');
  if (cnpj.length !== 14) return Response.json({ erro: 'ADN_CNPJ ausente ou inválido' }, { status: 500 });
  const u = new URL(req.url);
  let nsu = Number(u.searchParams.get('nsu') ?? '0');
  const lotes = Math.min(Number(u.searchParams.get('lotes') ?? '20'), 60);
  try {
    const client = Deno.createHttpClient(pem());
    const notas: (Nota | null)[] = [];
    const respostas: { nsu: number; http: number; status: string; docs: number }[] = [];
    for (let i = 0; i < lotes; i++) {
      const r = await fetch(`${BASE}/DFe/${nsu}?cnpjConsulta=${cnpj}&lote=true`,
        { method: 'GET', client, headers: { Accept: 'application/json' }, signal: AbortSignal.timeout(60_000) });
      const corpo = await r.json().catch(() => ({}));
      const l = lerLote(corpo);
      respostas.push({ nsu, http: r.status, status: l.status, docs: l.docs.length });
      if (!r.ok || !l.docs.length) break;
      for (const d of l.docs) {
        if (d.tipo && !/nfse/i.test(d.tipo)) continue; // eventos (cancelamento etc.) ficam de fora da contagem
        notas.push(d.xmlGzipB64 ? lerNota(await gunzipB64(d.xmlGzipB64)) : null);
      }
      nsu = (l.maiorNsu ?? nsu) + 1;
      await new Promise((ok) => setTimeout(ok, 1000)); // sem pressa: o limite do ADN não é documentado
    }
    return Response.json({ proximoNsu: nsu, respostas, resumo: resumir(notas, cnpj) });
  } catch (e) {
    return Response.json({ erro: String((e as Error).message ?? e) }, { status: 500 });
  }
});
