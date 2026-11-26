// O fluxo do leitor, com as dependências de fora (banco, bucket, IA, Asaas, qpdf) injetadas para os testes.
// Toda chamada ao banco vai com o login da pessoa (o JWT dela), pelo esquema api: o RLS decide o que ela pode.
import { LIMITE, type Mime, nomeLimpo, pdfCriptografado, senhasCandidatas, sha256, textoUtf8, tipoPelosBytes } from './arquivo.ts';
import type { Entrada } from './ia.ts';
import { type Boleto, type Leitura, limpar, soDigitos } from './leitura.ts';
import { type Extraido, extrair, temTexto } from './extrair.ts';
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
  abrirPdf: ((pdf: Buffer, senhas: string[]) => Promise<Buffer | null>) | null;  // a primeira que abre; null = nenhuma
  textoPdf?: ((pdf: Buffer) => Promise<string | null>) | null;                  // pdftotext; null = sem texto
  log: (msg: string, extra?: Record<string, unknown>) => void;
}

export interface Resultado {
  anexo: { id: string; nome: string; tipo_mime: Mime; tamanho: number };
  repetido_em: unknown[];
  leitura: Leitura | null;
  erro_leitura?: string;
  pede_senha?: boolean;   // PDF com senha que os CNPJs não abriram: a tela pede a senha
  identificacao: unknown;
  previa?: boolean;       // a primeira resposta, só com o que o texto e o Asaas dão; a leitura completa vem depois
}

// O que vale para um envio: a prévia (quem pediu a resposta em duas etapas) e as consultas ao Asaas já feitas, para a
// linha não ser consultada duas vezes (na prévia e depois da IA).
interface Envio {
  anexo: Resultado['anexo'];
  repetido: unknown[];
  previa?: (r: Resultado) => void;
  asaas: Map<string, Promise<NonNullable<Boleto['conferido_asaas']>>>;
  fim: boolean;           // a leitura completa ficou pronta: prévia atrasada não sai mais
}

export async function subir(d: Deps, jwt: string, nomeOriginal: string, dados: Buffer,
  previa?: (r: Resultado) => void): Promise<Resultado> {
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
  const envio = novoEnvio({ id: reg.id, nome, tipo_mime: mime, tamanho: dados.length }, reg.repetido_em ?? [], previa);
  return concluir(d, jwt, envio, () => ler(d, jwt, envio, mime, dados));
}

const novoEnvio = (anexo: Resultado['anexo'], repetido: unknown[], previa?: (r: Resultado) => void): Envio =>
  ({ anexo, repetido, previa, asaas: new Map(), fim: false });

function conferirAsaas(d: Deps, envio: Envio, linha: string) {
  let p = envio.asaas.get(linha);
  if (!p) { p = d.asaas!(linha); envio.asaas.set(linha, p); }
  return p;
}

// Lê, confere os boletos no Asaas, grava a leitura e pergunta ao banco o que casa com ela.
async function concluir(d: Deps, jwt: string, envio: Envio, lendo: () => Promise<Leitura>): Promise<Resultado> {
  const { anexo, repetido } = envio;
  let leitura: Leitura | null = null, erro: string | undefined, pedeSenha = false;
  try { leitura = await lendo(); }
  catch (e) {
    erro = e instanceof Recusa ? e.message : 'Não consegui ler o arquivo';
    pedeSenha = e instanceof SemSenha;
    if (!pedeSenha) d.log('leitura falhou', { anexo: anexo.id, erro: String(e) });
  } finally { envio.fim = true; }

  if (leitura) {
    if (d.asaas) for (const b of leitura.boletos ?? []) {
      if (!b.valida) continue;
      try { b.conferido_asaas = await conferirAsaas(d, envio, b.linha); } catch (e) { d.log('asaas falhou', { erro: String(e) }); }
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
  const envio = novoEnvio({ id, nome: a.nome, tipo_mime: 'application/pdf', tamanho: a.dados.length }, []);
  return concluir(d, jwt, envio, async () => {
    const aberto = d.abrirPdf ? await d.abrirPdf(a.dados, [senha]) : null;
    if (!aberto) throw new SemSenha('A senha não abriu o PDF');
    return lerPdf(d, jwt, envio, aberto);
  });
}

async function ler(d: Deps, jwt: string, envio: Envio, mime: Mime, dados: Buffer): Promise<Leitura> {
  if (mime === 'application/xml') {
    if (dados.length > LIMITE_XML) throw new Recusa(413, 'XML maior que 2 MB não é nota fiscal; suba o PDF');
    const texto = textoUtf8(dados)!;
    const l = lerXml(texto);
    if (l) return l;
    if (!d.ia) throw new Recusa(503, 'XML de formato desconhecido e leitura por IA indisponível');
    return d.ia({ tipo: 'texto', dados: texto.slice(0, 400_000) });
  }
  if (mime === 'application/pdf') {
    let pdf = dados;
    if (pdfCriptografado(dados)) {
      const aberto = await abrir(d, jwt, dados);
      if (!aberto) throw new SemSenha('O PDF tem senha e nenhum CNPJ das empresas abriu; digite a senha');
      pdf = aberto;
    }
    return lerPdf(d, jwt, envio, pdf);
  }
  if (!d.ia) throw new Recusa(503, 'Leitura por IA indisponível');
  return d.ia({ tipo: 'imagem', mime, dados });
}

// PDF: primeiro o texto, sem IA (pedido do Moises, 25/11/2026: ler em cerca de 1 s quando dá). Com a chave de uma
// nota que já chegou pela busca automática e que a pessoa vê (o banco decide, com o login dela; a de PJ não volta para
// quem não cuida de PJ), a leitura é a do XML. Senão a IA lê o PDF, e o que o texto traz conferido pelos dígitos
// (linha do boleto, chave, PIX) completa o que ela não achou.
async function lerPdf(d: Deps, jwt: string, envio: Envio, pdf: Buffer): Promise<Leitura> {
  let texto: string | null = null;
  if (d.textoPdf) {
    try { texto = await d.textoPdf(pdf); } catch (e) { d.log('texto do PDF falhou', { erro: String(e).slice(0, 200) }); }
  }
  const ext = temTexto(texto) ? extrair(texto) : null;
  if (ext) {
    const x = await pelaNotaRecebida(d, jwt, ext);
    if (x) return juntar(x, ext);
  }
  if (!d.ia) throw new Recusa(503, 'Leitura por IA indisponível');
  // a prévia corre junto com a IA, sem atrasá-la
  if (ext) void mandarPrevia(d, jwt, envio, ext);
  const l = await d.ia({ tipo: 'pdf', dados: pdf });
  return ext ? juntar(l, ext) : l;
}

// Prévia do boleto (pedido do Moises, 26/11/2026: ler o boleto em cerca de 1 s): enquanto a IA lê, a tela já recebe o
// que o texto dá conferido pelos dígitos (linha, valor, vencimento, chave, PIX), o beneficiário que o Asaas diz que o
// banco registrou (o fornecedor sugerido) e a empresa que paga (o CNPJ do texto que é de uma das empresas da pessoa).
// Não é gravada: a leitura gravada é a completa, que a tela usa para completar o que a pessoa não mexeu. Qualquer falha
// aqui só tira a prévia; a leitura completa vem do mesmo jeito.
async function mandarPrevia(d: Deps, jwt: string, envio: Envio, ext: Extraido): Promise<void> {
  if (!envio.previa || !ext.boletos.length) return;
  try {
    const [conf, op] = await Promise.all([
      Promise.all(ext.boletos.map((b) => (d.asaas ? conferirAsaas(d, envio, b.linha).catch(() => undefined) : undefined))),
      d.banco.rpc<{ empresas?: { documento?: string }[] } | null>(jwt, 'lancamento_opcoes', {}).catch(() => null),
    ]);
    const boletos = ext.boletos.map((b, i) => (conf[i] ? { ...b, conferido_asaas: conf[i] } : { ...b }));
    const nossos = new Set((op?.empresas ?? []).map((e) => soDigitos(e.documento)).filter(Boolean));
    const tomador = ext.documentos.find((x) => nossos.has(x));
    const benef = conf.find((c) => c?.ok && c.beneficiario_documento && !nossos.has(c.beneficiario_documento));
    const valores = boletos.map((b) => (b.conferido_asaas?.ok ? b.conferido_asaas.valor : undefined) ?? b.valor);
    const chaves = ext.chaves.filter(chaveDeNota);
    const leitura = limpar<Leitura>({
      origem: 'texto',
      tomador: tomador ? { documento: tomador } : undefined,
      emitente: benef ? { documento: benef.beneficiario_documento, nome: benef.beneficiario } : undefined,
      valor: valores.every((v) => v && v > 0) ? Math.round(valores.reduce<number>((a, v) => a + v!, 0) * 100) / 100 : undefined,
      boletos,
      chave_acesso: chaves.length === 1 ? chaves[0] : undefined,
      pix: ext.pix.length === 1 ? { copia_e_cola: ext.pix[0] } : undefined,
      avisos: ['Prévia pelo texto do PDF e pelo banco do boleto; o resto da leitura chega em seguida'],
    });
    if (envio.fim) return;
    const identificacao = await d.banco.rpc(jwt, 'identificar_nota', { p: pedidoIdentificar(leitura) }).catch(() => null);
    if (envio.fim) return;
    envio.previa({ anexo: envio.anexo, repetido_em: envio.repetido, leitura, identificacao, previa: true });
  } catch (e) {
    d.log('prévia falhou', { erro: String(e).slice(0, 200) });
  }
}

const UFS = new Set(['11', '12', '13', '14', '15', '16', '17', '21', '22', '23', '24', '25', '26', '27', '28', '29', '31', '32',
                     '33', '35', '41', '42', '43', '50', '51', '52', '53']);
// A chave que pode ser de uma nota recebida: NF-e (44 dígitos, UF válida, modelo 55) ou NFS-e nacional (50, começando
// pelo código IBGE do município). O código de barras do boleto também tem 44 dígitos, mas não passa nessa conferência.
export function chaveDeNota(c: string): boolean {
  if (c.length === 44) return UFS.has(c.slice(0, 2)) && c.slice(20, 22) === '55';
  return c.length === 50 && UFS.has(c.slice(0, 2));
}
// O CNPJ do emitente dentro da chave (posição fixa no leiaute).
const cnpjDaChave = (c: string) => (c.length === 44 ? c.slice(6, 20) : c.slice(9, 23));

// Uma chave só (mais de uma, como a nota que cita outra, é ambíguo e fica com a IA), e o emitente dela tem de aparecer
// no texto. Qualquer erro do banco deixa a leitura com a IA: o arquivo nunca deixa de subir por causa disso.
async function pelaNotaRecebida(d: Deps, jwt: string, ext: Extraido): Promise<Leitura | null> {
  const chaves = ext.chaves.filter(chaveDeNota);
  if (chaves.length !== 1 || !ext.documentos.includes(cnpjDaChave(chaves[0]))) return null;
  try {
    const n = await d.banco.rpc<{ xml?: string | null } | null>(jwt, 'buscar_nota_recebida', { p_chave: chaves[0] });
    const l = typeof n?.xml === 'string' && n.xml.length <= LIMITE_XML ? lerXml(n.xml) : null;
    if (!l || l.chave_acesso !== chaves[0]) return null;
    return { ...l, avisos: [...(l.avisos ?? []), 'Lida pelo XML da nota, que já tinha chegado pela busca automática'] };
  } catch (e) {
    d.log('busca da nota pela chave falhou', { erro: String(e).slice(0, 200) });
    return null;
  }
}

// O que o texto trouxe conferido entra onde a leitura não tem: as linhas de boleto que faltam, a chave (se só há uma)
// e o PIX copia e cola (se só há um).
export function juntar(l: Leitura, ext: Extraido): Leitura {
  const tem = new Set((l.boletos ?? []).filter((b) => b.valida).map((b) => b.linha));
  const novos = ext.boletos.filter((b) => !tem.has(b.linha));
  const chaves = ext.chaves.filter(chaveDeNota);
  const r: Leitura = { ...l };
  if (novos.length) {
    // uma linha que a leitura trouxe com o dígito errado e o texto trouxe certa sai, para não ficar repetida
    r.boletos = [...(l.boletos ?? []).filter((b) => b.valida), ...novos];
    r.avisos = [...(l.avisos ?? []), `${novos.length === 1 ? 'Linha do boleto conferida' : `${novos.length} linhas de boleto conferidas`} pelo texto do PDF`];
  }
  if (!r.chave_acesso && chaves.length === 1) r.chave_acesso = chaves[0];
  if (!r.pix?.copia_e_cola && ext.pix.length === 1) r.pix = { ...(r.pix ?? {}), copia_e_cola: ext.pix[0] };
  return r;
}

// PDF com senha: tenta os primeiros dígitos do CNPJ das empresas que a pessoa vê (a sem senha de usuário abre direto).
async function abrir(d: Deps, jwt: string, pdf: Buffer): Promise<Buffer | null> {
  if (!d.abrirPdf) return null;
  const op = await d.banco.rpc<{ empresas?: { documento?: string }[] } | null>(jwt, 'lancamento_opcoes', {});
  return d.abrirPdf(pdf, ['', ...senhasCandidatas((op?.empresas ?? []).map((e) => e.documento ?? ''))]);
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
