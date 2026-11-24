// Ponto de entrada da tela: gera o PDF oficial da nota a partir do XML guardado.
// NF-e (nfeProc) vira DANFE; NFS-e vira DANFSe. O resumo da NF-e (resNFe) não tem itens
// e não gera DANFE. jsPDF e a tabela de municípios só carregam quando alguém pede um PDF.

import type { Marca } from './danfse.ts';

export type TipoNota = 'nfe' | 'nfse';

export function tipoDoXml(xml: string): TipoNota | null {
  const ini = xml.slice(0, 600);
  if (/<(\w+:)?NFSe[\s>]/.test(ini)) return 'nfse';
  if (/<(\w+:)?(nfeProc|NFe)[\s>]/.test(ini)) return 'nfe';
  return null;
}

let municipios: Promise<Record<string, string>> | null = null;
const carregaMunicipios = () => (municipios ??= import('./municipios.json').then((m) => m.default as Record<string, string>));

/** PDF (DANFE ou DANFSe) da nota. `marca` põe "CANCELADA" ou "SUBSTITUÍDA" em diagonal. */
export async function pdfDaNota(xml: string, opcoes: { marca?: Marca } = {}): Promise<Blob> {
  const tipo = tipoDoXml(xml);
  if (!tipo) throw new Error('XML não é de NF-e completa nem de NFS-e');
  const { jsPDF } = await import('jspdf');
  const doc = new jsPDF({ unit: 'cm', format: 'a4', orientation: 'portrait', compress: true });
  if (tipo === 'nfse') {
    const [{ dadosDanfse, desenhaDanfse }, mun] = await Promise.all([import('./danfse.ts'), carregaMunicipios()]);
    const d = dadosDanfse(xml, { municipio: (c) => mun[c] ?? '' });
    doc.setProperties({ title: `DANFSe ${d.chave}`, creator: 'ERP BKM' });
    desenhaDanfse(doc, d, opcoes.marca);
  } else {
    const { dadosDanfe, desenhaDanfe } = await import('./danfe.ts');
    const d = dadosDanfe(xml);
    doc.setProperties({ title: `DANFE ${d.chave}`, creator: 'ERP BKM' });
    desenhaDanfe(doc, d, opcoes.marca);
  }
  return doc.output('blob');
}
