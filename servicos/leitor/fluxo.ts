// O fluxo do leitor, com as dependências de fora (banco, bucket, IA, Asaas, qpdf) injetadas para os testes.
// Toda chamada ao banco vai com o login da pessoa (o JWT dela), pelo esquema api: o RLS decide o que ela pode.
import { LIMITE, type Mime, nomeLimpo, pdfCriptografado, senhasCandidatas, sha256, textoUtf8, tipoPelosBytes } from './arquivo.ts';
import type { Entrada } from './ia.ts';
import type { Boleto, Leitura } from './leitura.ts';
import { lerXml } from './xml.ts';

// Uma NF-e tem dezenas de KB; acima disso o XML não é lido (nem pelo analisador, nem pela IA).
export const LIMITE_XML = 2 * 1024 * 1024;

export class Recusa extends Error {
  status: number;
  constructor(status: number, msg: string) { super(msg); this.status = status; }
}
// PDF com senha que não abriu: a tela pede a senha à pessoa (POST /anexos/<id>/senha).
export class SemSenha extends Recusa { constructor(msg: string) { super(422, msg); } }

export interface Banco { rpc<T = unknown>(jwt: string, fn: string, args: Record<string, unknown>): Promise<T> }
export interface Bucket {
  gravar(nome: string, mime: Mime, dados: Buffer): Promise<void>;   // falha se o nome já existe
  ler(nome: string): Promise<Buffer | null>;
}
export interface Deps {
  banco: Banco;
  bucket: Bucket;
  ia: ((e: Entrada) => Promise<Leitura>) | null;
  asaas: ((linha: string) => Promise<NonNullable<Boleto['conferido_asaas']>>) | null;
  abrirPdf: ((pdf: Buffer, senha: string) => Promise<Buffer | null>) | null;  // null = senha errada
  log: (msg: string, extra?: Record<string, unknown>) => void;
}

export interface Resultado {
  anexo: { id: string; nome: string; tipo_mime: Mime; tamanho: number };
  repetido_em: unknown[];
  leitura: Leitura | null;
  erro_leitura?: string;
  pede_senha?: boolean;   // PDF com senha que os CNPJs não abriram: a tela pede a senha
  identificacao: unknown;
}

export async function subir(d: Deps, jwt: string, nomeOriginal: string, dados: Buffer): Promise<Resultado> {
  if (!dados.length) throw new Recusa(400, 'Arquivo vazio');
  if (dados.length > LIMITE) throw new Recusa(413, 'O arquivo passa de 20 MB');
  const mime = tipoPelosBytes(dados);
  if (!mime) throw new Recusa(415, 'Só PDF, XML, JPEG ou PNG');
  const nome = nomeLimpo(nomeOriginal, mime);
  const hash = sha256(dados);

  // 1. registra com o login da pessoa (recusa quem não lança) e 2. guarda com o nome igual ao id, uma vez só
  const reg = await d.banco.rpc<{ id: string; repetido_em: unknown[] }>(jwt, 'registrar_anexo',
    { p_nome: nome, p_tipo_mime: mime, p_tamanho: dados.length, p_sha256: hash });
  await d.bucket.gravar(reg.id, mime, dados);

  // 3. lê; uma falha de leitura não perde o arquivo: a pessoa preenche à mão
  return concluir(d, jwt, { id: reg.id, nome, tipo_mime: mime, tamanho: dados.length }, reg.repetido_em ?? [],
    () => ler(d, jwt, mime, dados));
}

// Lê, confere os boletos no Asaas, grava a leitura e pergunta ao banco o que casa com ela.
async function concluir(d: Deps, jwt: string, anexo: Resultado['anexo'], repetido: unknown[], lendo: () => Promise<Leitura>): Promise<Resultado> {
  let leitura: Leitura | null = null, erro: string | undefined, pedeSenha = false;
  try { leitura = await lendo(); }
  catch (e) {
    erro = e instanceof Recusa ? e.message : 'Não consegui ler o arquivo';
    pedeSenha = e instanceof SemSenha;
    if (!pedeSenha) d.log('leitura falhou', { anexo: anexo.id, erro: String(e) });
  }

  if (leitura) {
    if (d.asaas) for (const b of leitura.boletos ?? []) {
      if (!b.valida) continue;
      try { b.conferido_asaas = await d.asaas(b.linha); } catch (e) { d.log('asaas falhou', { erro: String(e) }); }
    }
    await d.banco.rpc(jwt, 'gravar_leitura', { p_anexo: anexo.id, p_leitura: leitura });
  }

  const identificacao = leitura ? await d.banco.rpc(jwt, 'identificar_nota', { p: pedidoIdentificar(leitura) }) : null;
  return { anexo, repetido_em: repetido, leitura, erro_leitura: erro, ...(pedeSenha ? { pede_senha: true } : {}), identificacao };
}

// A senha que a pessoa digitou para o PDF que os CNPJs não abriram. O arquivo é o guardado (o banco diz, com o login
// dela, que ela vê o anexo; o sha256 confere). A senha só vai ao qpdf: não é gravada nem vai ao registro.
export async function abrirComSenha(d: Deps, jwt: string, id: string, senha: string): Promise<Resultado> {
  if (typeof senha !== 'string' || !senha.length || senha.length > 100 || /[\u0000-\u001f\u007f]/.test(senha)) {
    throw new Recusa(400, 'Senha inválida');
  }
  // só o anexo que a pessoa subiu e ainda não ligou a uma nota (é o que gravar_leitura aceita); antes da IA
  const soltos = await d.banco.rpc<{ id: string }[] | null>(jwt, 'meus_anexos_soltos', {});
  if (!(soltos ?? []).some((x) => x.id === id)) throw new Recusa(404, 'Anexo não encontrado ou já ligado a uma nota');
  const a = await baixar(d, jwt, id);
  if (a.mime !== 'application/pdf' || !pdfCriptografado(a.dados)) throw new Recusa(400, 'Este arquivo não é um PDF com senha');
  if (!d.ia) throw new Recusa(503, 'Leitura por IA indisponível');
  return concluir(d, jwt, { id, nome: a.nome, tipo_mime: 'application/pdf', tamanho: a.dados.length }, [], async () => {
    const aberto = d.abrirPdf ? await d.abrirPdf(a.dados, senha) : null;
    if (!aberto) throw new SemSenha('A senha não abriu o PDF');
    return d.ia!({ tipo: 'pdf', dados: aberto });
  });
}

async function ler(d: Deps, jwt: string, mime: Mime, dados: Buffer): Promise<Leitura> {
  if (mime === 'application/xml') {
    if (dados.length > LIMITE_XML) throw new Recusa(413, 'XML maior que 2 MB não é nota fiscal; suba o PDF');
    const texto = textoUtf8(dados)!;
    const l = lerXml(texto);
    if (l) return l;
    if (!d.ia) throw new Recusa(503, 'XML de formato desconhecido e leitura por IA indisponível');
    return d.ia({ tipo: 'texto', dados: texto.slice(0, 400_000) });
  }
  if (!d.ia) throw new Recusa(503, 'Leitura por IA indisponível');
  if (mime === 'application/pdf') {
    let pdf = dados;
    if (pdfCriptografado(dados)) {
      const aberto = await abrir(d, jwt, dados);
      if (!aberto) throw new SemSenha('O PDF tem senha e nenhum CNPJ das empresas abriu; digite a senha');
      pdf = aberto;
    }
    return d.ia({ tipo: 'pdf', dados: pdf });
  }
  return d.ia({ tipo: 'imagem', mime, dados });
}

// PDF com senha: tenta os primeiros dígitos do CNPJ das empresas que a pessoa vê (a sem senha de usuário abre direto).
async function abrir(d: Deps, jwt: string, pdf: Buffer): Promise<Buffer | null> {
  if (!d.abrirPdf) return null;
  const sem = await d.abrirPdf(pdf, '');
  if (sem) return sem;
  const op = await d.banco.rpc<{ empresas?: { documento?: string }[] } | null>(jwt, 'lancamento_opcoes', {});
  for (const s of senhasCandidatas((op?.empresas ?? []).map((e) => e.documento ?? ''))) {
    const r = await d.abrirPdf(pdf, s);
    if (r) return r;
  }
  return null;
}

// O corpo de api.identificar_nota: o vencimento é o primeiro da nota, do boleto ou da fatura.
export function pedidoIdentificar(l: Leitura) {
  const venc = l.parcelas?.find((p) => p.vencimento)?.vencimento ?? l.boletos?.find((b) => b.valida && b.vencimento)?.vencimento
    ?? l.consumo?.vencimento;
  return { tomador: l.tomador?.documento ?? null, emitente: l.emitente?.documento ?? null,
           tipo: l.tipo && l.tipo !== 'outro' ? l.tipo : null, numero: l.numero ?? null, serie: l.serie ?? null,
           valor: l.valor ?? null, emissao: l.emissao ?? null, vencimento: venc ?? null };
}

// Entregar o arquivo: só depois de o banco dizer, com o login da pessoa, que ela vê o anexo.
export async function baixar(d: Deps, jwt: string, id: string) {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Recusa(404, 'Anexo não encontrado');
  const a = await d.banco.rpc<{ id: string; nome: string; tipo_mime: string; sha256: string } | null>(jwt, 'anexo', { p_id: id });
  if (!a) throw new Recusa(404, 'Anexo não encontrado');
  const dados = await d.bucket.ler(a.id);
  if (!dados) throw new Recusa(404, 'Arquivo não encontrado');
  if (sha256(dados) !== a.sha256) { d.log('sha256 do arquivo não bate com o anexo', { anexo: a.id }); throw new Recusa(409, 'Arquivo alterado'); }
  return { nome: a.nome, mime: a.tipo_mime, dados };
}
