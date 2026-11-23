// Uma rodada da busca para uma empresa: ADN (NFS-e), SEFAZ (NF-e) e a ciência das NF-e que chegaram só em resumo.
// Banco e rede entram por parâmetro (banco.ts e job.ts os montam), para os testes rodarem sem nenhum dos dois.
import {
  lerLoteAdn, lerDocAdn, pedidoDist, lerRespostaDist, lerDocZip, esperaSefaz, eventoCiencia, pedidoEventos, lerRespostaEventos,
  ACAO_DIST, ACAO_EVENTO, URL_DIST, URL_EVENTO, type Assinador, type Documento, type NotaBanco, type EventoBanco,
} from './notas.ts';

export type Origem = 'adn' | 'sefaz';
export type Leitura = { ultimoNsu: number; lida: boolean; bloqueadoAte: Date | null };
export interface Banco {
  leitura(empresa: string, origem: Origem): Promise<Leitura>;
  gravarNota(empresa: string, nota: NotaBanco, xml: string, completo: boolean): Promise<void>;
  gravarEvento(empresa: string, evento: EventoBanco, xml: string): Promise<void>;
  gravarLeitura(empresa: string, origem: Origem, ultimo: number, maximo: number | null, bloqueadoAte: Date | null, erro: string | null): Promise<void>;
  semCiencia(empresa: string, limite: number): Promise<string[]>;   // chaves de NF-e só em resumo, sem ciência
  gravarCiencia(chave: string): Promise<void>;
}
export interface Rede {
  adn(nsu: number, cnpj: string): Promise<{ status: number; corpo: unknown }>;
  soap(url: string, acao: string, corpo: string): Promise<{ status: number; corpo: string }>;
}
export type Empresa = { id: string; cnpj: string; uf: string };
export type Ritmo = { lotesAdn: number; lotesSefaz: number; lotesCiencia: number; pausa: (ms: number) => Promise<void>; agora: () => Date };
export type Resumo = { origem: Origem | 'ciencia'; lidos: number; notas: number; eventos: number; fora: number; falhas: number; parou: string };

const msg = (e: unknown) => String((e as Error)?.message ?? e).slice(0, 300);

// Grava um documento; erro de um não para os outros (fica no erro da leitura, com o NSU).
async function gravar(b: Banco, empresa: string, d: Documento, r: Resumo, erros: string[]) {
  try {
    if (d.tipo === 'nota') { await b.gravarNota(empresa, d.nota, d.xml, d.completo); r.notas++; }
    else if (d.tipo === 'evento') { await b.gravarEvento(empresa, d.evento, d.xml); r.eventos++; }
    else r.fora++;
  } catch (e) {
    r.falhas++;
    const nsu = d.tipo === 'nota' ? d.nota.nsu : d.tipo === 'evento' ? d.evento.nsu : d.nsu;
    erros.push(`NSU ${nsu}: ${msg(e)}`);
  }
}
const juntar = (erros: string[]) => (erros.length ? `${erros.length} documento(s) com erro; ${erros.slice(0, 3).join(' | ')}` : null);

// ADN: GET /DFe/{NSU} devolve o lote a partir daquele NSU. Sem documento (ou 404), acabou por agora.
export async function rodadaAdn(b: Banco, rede: Rede, emp: Empresa, ritmo: Ritmo): Promise<Resumo> {
  const r: Resumo = { origem: 'adn', lidos: 0, notas: 0, eventos: 0, fora: 0, falhas: 0, parou: 'limite de lotes' };
  const l = await b.leitura(emp.id, 'adn');
  let ultimo = l.ultimoNsu;
  for (let i = 0; i < ritmo.lotesAdn; i++) {
    const inicio = l.lida || i > 0 ? ultimo + 1 : 0;
    let resp;
    try { resp = await rede.adn(inicio, emp.cnpj); } catch (e) {
      await b.gravarLeitura(emp.id, 'adn', ultimo, null, null, `ADN: ${msg(e)}`); r.parou = 'erro de rede'; return r;
    }
    const lote = lerLoteAdn(resp.corpo);
    if (resp.status === 404 || (resp.status >= 200 && resp.status < 300 && !lote.docs.length)) {
      await b.gravarLeitura(emp.id, 'adn', ultimo, null, null, null); r.parou = 'fim'; return r;
    }
    if (resp.status < 200 || resp.status >= 300) {
      await b.gravarLeitura(emp.id, 'adn', ultimo, null, null, `ADN: HTTP ${resp.status} ${lote.status}`.trim()); r.parou = `HTTP ${resp.status}`; return r;
    }
    const erros: string[] = [];
    for (const d of lote.docs) {
      r.lidos++;
      let doc: Documento;
      try { doc = lerDocAdn(d, emp.cnpj); } catch (e) { doc = { tipo: 'outro', nsu: d.nsu, motivo: msg(e) }; }
      await gravar(b, emp.id, doc, r, erros);
    }
    ultimo = Math.max(ultimo, lote.maiorNsu ?? ultimo);
    l.lida = true;
    await b.gravarLeitura(emp.id, 'adn', ultimo, null, null, juntar(erros));
    await ritmo.pausa(1000);   // o limite do ADN não é documentado: sem pressa
  }
  return r;
}

// SEFAZ: distNSU a partir do último lido; a SEFAZ manda esperar 1 hora no fim da fila (e bloqueia quem não espera).
export async function rodadaSefaz(b: Banco, rede: Rede, emp: Empresa, ritmo: Ritmo): Promise<Resumo> {
  const r: Resumo = { origem: 'sefaz', lidos: 0, notas: 0, eventos: 0, fora: 0, falhas: 0, parou: 'limite de lotes' };
  const l = await b.leitura(emp.id, 'sefaz');
  if (l.bloqueadoAte && l.bloqueadoAte > ritmo.agora()) { r.parou = 'esperando a hora da SEFAZ'; return r; }
  let ultimo = l.ultimoNsu;
  for (let i = 0; i < ritmo.lotesSefaz; i++) {
    let resp;
    try {
      const http = await rede.soap(URL_DIST, ACAO_DIST, pedidoDist(emp.cnpj, emp.uf, ultimo));
      if (http.status < 200 || http.status >= 300) throw new Error(`HTTP ${http.status}`);
      resp = lerRespostaDist(http.corpo);
    } catch (e) {
      await b.gravarLeitura(emp.id, 'sefaz', ultimo, null, null, `SEFAZ: ${msg(e)}`); r.parou = 'erro'; return r;
    }
    if (!['137', '138', '656'].includes(resp.cStat)) {
      await b.gravarLeitura(emp.id, 'sefaz', ultimo, null, null, `SEFAZ: ${resp.cStat} ${resp.motivo}`); r.parou = `cStat ${resp.cStat}`; return r;
    }
    const erros: string[] = [];
    for (const d of resp.docs) {
      r.lidos++;
      let doc: Documento;
      try { doc = lerDocZip(d, emp.cnpj); } catch (e) { doc = { tipo: 'outro', nsu: d.nsu, motivo: msg(e) }; }
      await gravar(b, emp.id, doc, r, erros);
    }
    if (Number.isSafeInteger(resp.ultNsu) && resp.ultNsu > ultimo) ultimo = resp.ultNsu;
    const espera = esperaSefaz(resp, ritmo.agora());
    const maximo = Number.isSafeInteger(resp.maxNsu) ? resp.maxNsu : null;
    await b.gravarLeitura(emp.id, 'sefaz', ultimo, maximo, espera, resp.cStat === '656' ? `SEFAZ: 656 ${resp.motivo}` : juntar(erros));
    if (espera) { r.parou = resp.cStat === '656' ? 'bloqueio da SEFAZ (656)' : 'fim'; return r; }
    await ritmo.pausa(2000);
  }
  return r;
}

// Ciência da operação nas NF-e que chegaram só em resumo (o XML completo chega depois, por outro NSU).
export async function rodadaCiencia(b: Banco, rede: Rede, emp: Empresa, ritmo: Ritmo, assinador: Assinador,
                                    sha1b64: (s: string) => string): Promise<Resumo> {
  const r: Resumo = { origem: 'ciencia', lidos: 0, notas: 0, eventos: 0, fora: 0, falhas: 0, parou: 'limite de lotes' };
  for (let i = 0; i < ritmo.lotesCiencia; i++) {
    const chaves = await b.semCiencia(emp.id, 20);
    if (!chaves.length) { r.parou = 'fim'; return r; }
    const agora = ritmo.agora();
    const lote = Number(String(agora.getTime()).slice(-13)) + i;
    let ret;
    try {
      const http = await rede.soap(URL_EVENTO, ACAO_EVENTO, pedidoEventos(chaves.map((k) => eventoCiencia(emp.cnpj, k, agora, sha1b64, assinador)), lote));
      if (http.status < 200 || http.status >= 300) throw new Error(`HTTP ${http.status}`);
      ret = lerRespostaEventos(http.corpo);
    } catch (e) { r.parou = `erro: ${msg(e)}`; return r; }
    let feitas = 0;
    for (const k of chaves) {
      r.lidos++;
      if (ret.porChave[k]?.feito) { await b.gravarCiencia(k); feitas++; r.eventos++; } else r.falhas++;
    }
    // nenhuma aceita: não insiste na mesma leva nesta rodada (as mesmas chaves voltariam)
    if (!feitas) { r.parou = `nenhuma aceita (lote ${ret.lote}${chaves[0] && ret.porChave[chaves[0]] ? `, ${ret.porChave[chaves[0]].cStat}` : ''})`; return r; }
    await ritmo.pausa(2000);
  }
  return r;
}
