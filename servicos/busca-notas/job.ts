// Busca das notas recebidas (Moises, 23/11/2026), Cloud Run Job do bkm-erp, rodado de hora em hora pelo Cloud Scheduler.
// Para cada empresa com certificado: NFS-e no ADN, NF-e na SEFAZ e a ciência das NF-e que chegaram em resumo.
// Grava só pela caixa de notas (login erp_busca_notas). O log sai só com contagens: sem CNPJ, chave nem XML.
// Variáveis: NOTAS_DB_URL (segredo: a URL do banco com o login erp_busca_notas); NOTAS_CERTS (pasta, padrão /certs),
// com uma subpasta por empresa, com o nome do id dela no ERP e o arquivo pem dentro (chave privada e certificado A1
// em PEM, montados do Secret Manager); NOTAS_UF (código IBGE da UF do autor na SEFAZ, padrão 35); NOTAS_CA (opcional:
// PEM com as raízes da ICP-Brasil, que a SEFAZ usa e o Node não traz).
import { Agent, request } from 'node:https';
import { createHash, createPrivateKey, createSign, X509Certificate } from 'node:crypto';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { rootCertificates } from 'node:tls';
import { join } from 'node:path';
import { bancoPg } from './banco.ts';
import { rodadaAdn, rodadaSefaz, rodadaCiencia, type Rede, type Resumo } from './ciclo.ts';

const ADN = process.env.NOTAS_ADN ?? 'https://adn.nfse.gov.br/contribuintes';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Separa o PEM em chave e certificados (só o primeiro certificado assina; os outros são a cadeia).
export function lerPem(pem: string) {
  const blocos = [...pem.matchAll(/-----BEGIN ([A-Z ]+)-----[\s\S]+?-----END \1-----/g)];
  const chave = blocos.find((b) => /PRIVATE KEY/.test(b[1]))?.[0];
  const certs = blocos.filter((b) => b[1] === 'CERTIFICATE').map((b) => b[0]);
  if (!chave || !certs.length) throw new Error('o pem precisa da chave privada e do certificado');
  return { chave, certs };
}

function http(agent: Agent, url: string, metodo: 'GET' | 'POST', cabecalhos: Record<string, string>, corpo?: string) {
  return new Promise<{ status: number; corpo: string }>((ok, falha) => {
    const r = request(url, { method: metodo, agent, headers: { ...cabecalhos, ...(corpo ? { 'Content-Length': Buffer.byteLength(corpo) } : {}) },
      timeout: 90_000 }, (res) => {
      const partes: Buffer[] = [];
      let tam = 0;
      res.on('data', (p: Buffer) => { tam += p.length; if (tam > 50 * 1024 * 1024) r.destroy(new Error('resposta grande demais')); else partes.push(p); });
      res.on('end', () => ok({ status: res.statusCode ?? 0, corpo: Buffer.concat(partes).toString('utf8') }));
    });
    r.on('timeout', () => r.destroy(new Error('tempo esgotado')));
    r.on('error', falha);
    r.end(corpo);
  });
}

async function main() {
  const url = process.env.NOTAS_DB_URL;
  if (!url) throw new Error('falta NOTAS_DB_URL');
  const dir = process.env.NOTAS_CERTS ?? '/certs';
  const uf = process.env.NOTAS_UF ?? '35';
  const extra = process.env.NOTAS_CA && existsSync(process.env.NOTAS_CA) ? [readFileSync(process.env.NOTAS_CA, 'utf8')] : [];
  const empresas = readdirSync(dir).filter((d) => UUID.test(d) && existsSync(join(dir, d, 'pem')));
  if (!empresas.length) throw new Error('nenhum certificado em ' + dir);
  const banco = bancoPg(url);
  const ritmo = { lotesAdn: 40, lotesSefaz: 20, lotesCiencia: 5, pausa: (ms: number) => new Promise<void>((ok) => setTimeout(ok, ms)), agora: () => new Date() };
  const sha1b64 = (s: string) => createHash('sha1').update(s, 'utf8').digest('base64');
  let falhou = false;
  try {
    for (const id of empresas) {
      const log: Record<string, unknown> = { empresa: id.slice(0, 8) };
      try {
        const { chave, certs } = lerPem(readFileSync(join(dir, id, 'pem'), 'utf8'));
        const x = new X509Certificate(certs[0]);
        const dias = Math.floor((new Date(x.validTo).getTime() - Date.now()) / 86_400_000);
        log.certificadoVenceEmDias = dias;
        if (dias < 0) throw new Error('certificado vencido');
        const cnpj = await banco.cnpj(id);
        if (!cnpj || !/^\d{14}$/.test(cnpj)) throw new Error('empresa sem CNPJ ou inativa no ERP');
        // o e-CNPJ da ICP-Brasil traz o CNPJ no nome; a SEFAZ e o ADN aceitam a mesma raiz (8 primeiros dígitos)
        if (!`${x.subject}\n${x.subjectAltName ?? ''}`.includes(cnpj.slice(0, 8))) throw new Error('o certificado não é desta empresa');
        const agent = new Agent({ key: chave, cert: certs.join('\n'), ca: [...rootCertificates, ...extra], keepAlive: true, maxSockets: 1 });
        const chavePriv = createPrivateKey(chave);
        const assinador = { certificadoB64: x.raw.toString('base64'), assinar: (s: string) => createSign('RSA-SHA1').update(s, 'utf8').sign(chavePriv, 'base64') };
        const rede: Rede = {
          adn: async (nsu, c) => {
            const r = await http(agent, `${ADN}/DFe/${nsu}?cnpjConsulta=${c}&lote=true`, 'GET', { Accept: 'application/json' });
            let corpo: unknown = {};
            try { corpo = JSON.parse(r.corpo); } catch { /* corpo não JSON fica vazio */ }
            return { status: r.status, corpo };
          },
          soap: (u, acao, corpo) => http(agent, u, 'POST', { 'Content-Type': `application/soap+xml; charset=utf-8; action="${acao}"` }, corpo),
        };
        const emp = { id, cnpj, uf };
        const rodadas: Resumo[] = [];
        rodadas.push(await rodadaAdn(banco, rede, emp, ritmo));
        rodadas.push(await rodadaSefaz(banco, rede, emp, ritmo));
        rodadas.push(await rodadaCiencia(banco, rede, emp, ritmo, assinador, sha1b64));
        log.rodadas = rodadas;
        agent.destroy();
      } catch (e) {
        falhou = true;
        log.erro = String((e as Error)?.message ?? e).slice(0, 300);
      }
      console.log(JSON.stringify(log));
    }
  } finally {
    await banco.fechar();
  }
  if (falhou) process.exitCode = 1;
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(JSON.stringify({ erro: String((e as Error)?.message ?? e) })); process.exit(1); });
