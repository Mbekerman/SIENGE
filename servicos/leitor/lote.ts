// Teste em escala do leitor (Cloud Run Job, pedido do Moises, 20/11/2026): lê os arquivos de gs://BUCKET/lote/entrada/
// com a mesma IA do leitor e grava, por arquivo, o que leu e os tokens gastos em gs://BUCKET/lote/saida/<arquivo>.json.
// Não toca o banco, não usa login de pessoa e não consulta boleto em lugar nenhum: só mede a leitura e o custo.
// Quem compara com o gabarito é outro passo, fora daqui.
//
// Variáveis: BUCKET, as ANTHROPIC_* do leitor (federação, sem chave guardada), LOTE_LIMITE (quantos arquivos ainda sem
// resultado ler nesta rodada; padrão 20), LOTE_PARALELO (padrão 4) e LOTE_CNPJS (CNPJs das empresas, separados por
// vírgula, para abrir PDF com senha como o leitor faz; opcional). Rodar de novo continua de onde parou.
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { LIMITE, pdfCriptografado, senhasCandidatas, tentarSenhas, textoUtf8, tipoPelosBytes } from './arquivo.ts';
import { type Entrada, clienteFederado, lerComIaDetalhe } from './ia.ts';
import { lerXml } from './xml.ts';
import type { Leitura } from './leitura.ts';

export const ENTRADA = 'lote/entrada/';
export const SAIDA = 'lote/saida/';

export interface Resultado {
  arquivo: string;
  bytes: number;
  ms: number;
  origem?: 'xml' | 'ia';
  modelo?: string;
  uso?: { entrada: number; saida: number; cache_lido: number; cache_criado: number };
  leitura?: Leitura;
  erro?: string;
  erro_ia?: boolean;   // falha da chamada à IA: não grava, para a rodada seguinte tentar de novo
}

// O nome do resultado: o do arquivo, sem a pasta de entrada.
export const nomeSaida = (objeto: string) => SAIDA + objeto.slice(ENTRADA.length) + '.json';

// O que falta ler: os da entrada sem resultado, na ordem do nome, até o limite.
export function pendentes(entrada: string[], saidas: Set<string>, limite: number): string[] {
  return entrada.filter((o) => o !== ENTRADA && !o.endsWith('/') && !saidas.has(nomeSaida(o))).sort().slice(0, limite);
}

// Lê um arquivo como o leitor lê (XML de nota sem IA; PDF, foto e XML desconhecido pela IA), sem banco.
export async function lerArquivo(nome: string, dados: Buffer, ia: (e: Entrada) => ReturnType<typeof lerComIaDetalhe>,
                                 abrir: (pdf: Buffer) => Promise<Buffer | null>): Promise<Resultado> {
  const t0 = Date.now();
  const r: Resultado = { arquivo: nome, bytes: dados.length, ms: 0 };
  try {
    if (!dados.length) throw new Error('arquivo vazio');
    if (dados.length > LIMITE) throw new Error('passa de 20 MB');
    const mime = tipoPelosBytes(dados);
    if (!mime) throw new Error('não é PDF, XML, JPEG nem PNG');
    let entrada: Entrada;
    if (mime === 'application/xml') {
      const texto = textoUtf8(dados)!;
      const l = lerXml(texto);
      if (l) { r.origem = 'xml'; r.leitura = l; return r; }
      entrada = { tipo: 'texto', dados: texto.slice(0, 400_000) };
    } else if (mime === 'application/pdf') {
      let pdf = dados;
      if (pdfCriptografado(dados)) {
        const aberto = await abrir(dados);
        if (!aberto) throw new Error('PDF com senha que os CNPJs não abriram');
        pdf = aberto;
      }
      entrada = { tipo: 'pdf', dados: pdf };
    } else {
      entrada = { tipo: 'imagem', mime, dados };
    }
    const x = await ia(entrada).catch((e) => { r.erro_ia = true; throw e; });
    r.origem = 'ia'; r.modelo = x.modelo; r.leitura = x.leitura;
    r.uso = { entrada: x.uso.input_tokens ?? 0, saida: x.uso.output_tokens ?? 0,
              cache_lido: x.uso.cache_read_input_tokens ?? 0, cache_criado: x.uso.cache_creation_input_tokens ?? 0 };
  } catch (e) {
    r.erro = e instanceof Error ? e.message : String(e);
  } finally {
    r.ms = Date.now() - t0;
  }
  return r;
}

// ---------- o job ----------

let token: { v: string; ate: number } | null = null;
async function gcs(): Promise<string> {
  if (token && token.ate > Date.now() + 60_000) return token.v;
  const r = await fetch('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token',
    { headers: { 'Metadata-Flavor': 'Google' }, signal: AbortSignal.timeout(5_000) });
  if (!r.ok) throw new Error(`metadados: ${r.status}`);
  const j = await r.json() as { access_token: string; expires_in: number };
  token = { v: j.access_token, ate: Date.now() + j.expires_in * 1000 };
  return token.v;
}

async function listar(bucket: string, prefixo: string): Promise<string[]> {
  const nomes: string[] = [];
  let pagina = '';
  do {
    const u = `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o?fields=items(name),nextPageToken`
      + `&prefix=${encodeURIComponent(prefixo)}${pagina ? `&pageToken=${encodeURIComponent(pagina)}` : ''}`;
    const r = await fetch(u, { headers: { authorization: `Bearer ${await gcs()}` }, signal: AbortSignal.timeout(30_000) });
    if (!r.ok) throw new Error(`listar ${prefixo}: ${r.status}`);
    const j = await r.json() as { items?: { name: string }[]; nextPageToken?: string };
    nomes.push(...(j.items ?? []).map((i) => i.name));
    pagina = j.nextPageToken ?? '';
  } while (pagina);
  return nomes;
}

async function baixar(bucket: string, nome: string): Promise<Buffer> {
  const u = `https://storage.googleapis.com/storage/v1/b/${encodeURIComponent(bucket)}/o/${encodeURIComponent(nome)}?alt=media`;
  const r = await fetch(u, { headers: { authorization: `Bearer ${await gcs()}` }, signal: AbortSignal.timeout(60_000) });
  if (!r.ok) throw new Error(`baixar: ${r.status}`);
  return Buffer.from(await r.arrayBuffer());
}

// ifGenerationMatch=0: o resultado é gravado uma vez só (a conta do leitor só cria objetos, não sobrescreve)
async function gravar(bucket: string, nome: string, corpo: string): Promise<void> {
  const u = `https://storage.googleapis.com/upload/storage/v1/b/${encodeURIComponent(bucket)}/o?uploadType=media`
    + `&name=${encodeURIComponent(nome)}&ifGenerationMatch=0`;
  const r = await fetch(u, { method: 'POST', headers: { authorization: `Bearer ${await gcs()}`, 'content-type': 'application/json' },
    body: corpo, signal: AbortSignal.timeout(60_000) });
  if (!r.ok && r.status !== 412) throw new Error(`gravar: ${r.status}`);
}

// PDF com senha: o mesmo caminho do servidor (qpdf sem shell, pasta temporária apagada ao fim; senhas nunca no log)
const qpdf = (args: string[], prazoMs = 20_000) => new Promise<number>((res) =>
  execFile('qpdf', args, { timeout: Math.max(1, Math.min(prazoMs, 20_000)) },
    (err) => res(err ? (typeof (err as { code?: unknown }).code === 'number' ? (err as { code: number }).code : -1) : 0)));
async function abrirPdf(pdf: Buffer, senhas: string[]): Promise<Buffer | null> {
  const dir = await mkdtemp(join(tmpdir(), 'pdf-'));
  try {
    const e = join(dir, 'e.pdf'), o = join(dir, 's.pdf');
    await writeFile(e, pdf);
    const senha = await tentarSenhas(senhas, (s, resta) => qpdf(['--requires-password', `--password=${s}`, e], resta));
    if (senha === null) return null;
    const r = await qpdf([`--password=${senha}`, '--decrypt', e, o]);
    return r === 0 || r === 3 ? await readFile(o) : null;
  } catch { return null; } finally { await rm(dir, { recursive: true, force: true }); }
}

const log = (msg: string, extra: Record<string, unknown> = {}) => console.log(JSON.stringify({ severity: 'INFO', msg, ...extra }));

async function main() {
  const bucket = process.env.BUCKET;
  if (!bucket) throw new Error('Falta a variável BUCKET');
  const limite = Math.max(1, Number(process.env.LOTE_LIMITE ?? 20) || 20);
  const paralelo = Math.min(16, Math.max(1, Number(process.env.LOTE_PARALELO ?? 4) || 4));
  const senhas = ['', ...senhasCandidatas((process.env.LOTE_CNPJS ?? '').split(',').map((s) => s.replace(/\D/g, '')).filter(Boolean))];
  const cliente = await clienteFederado();

  const fila = pendentes(await listar(bucket, ENTRADA), new Set(await listar(bucket, SAIDA)), limite);
  log('lote começou', { arquivos: fila.length, paralelo });
  let feitos = 0, erros = 0, entrada = 0, saida = 0;
  const trabalhar = async () => {
    for (let o = fila.shift(); o; o = fila.shift()) {
      const r = await lerArquivo(o.slice(ENTRADA.length), await baixar(bucket, o), (e) => lerComIaDetalhe(cliente, e),
        (pdf) => abrirPdf(pdf, senhas));
      feitos++; if (r.erro) erros++;
      if (r.erro_ia) { log('a IA falhou; fica para a próxima rodada', { arquivo: r.arquivo, erro: r.erro }); continue; }
      await gravar(bucket, nomeSaida(o), JSON.stringify(r));
      entrada += r.uso?.entrada ?? 0; saida += r.uso?.saida ?? 0;
      if (feitos % 20 === 0) log('andamento', { feitos, erros, tokens_entrada: entrada, tokens_saida: saida });
    }
  };
  await Promise.all(Array.from({ length: paralelo }, trabalhar));
  log('lote terminou', { feitos, erros, tokens_entrada: entrada, tokens_saida: saida });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e) => { console.error(JSON.stringify({ severity: 'ERROR', msg: 'lote falhou', erro: String(e) })); process.exit(1); });
}
