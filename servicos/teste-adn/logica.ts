// Teste de cobertura do Ambiente de Dados Nacional da NFS-e (ADN), pedido do Moises em 20/11/2026.
// Pergunta que o teste responde: as notas de serviço que a BKM recebe aparecem no ADN?
// Aqui só a parte pura (sem rede): ler a resposta do ADN, tirar do XML o que interessa e resumir por mês.
// Nada é gravado: o resultado sai na resposta da função e é comparado à mão com os títulos NFSE do Sienge.

export type DocAdn = { nsu: number; chave: string | null; tipo: string | null; xmlGzipB64: string | null };
export type Lote = { status: string; docs: DocAdn[]; maiorNsu: number | null };

// Resposta de GET {base}/DFe/{NSU}?cnpjConsulta=...&lote=true. O ADN usa nomes com maiúscula
// (LoteDFe, NSU, ChaveAcesso, TipoDocumento, ArquivoXml, StatusProcessamento); aceita também minúscula
// porque o leiaute ainda muda (ver docs/tecnico, data do teste).
export function lerLote(corpo: unknown): Lote {
  const o = (corpo ?? {}) as Record<string, unknown>;
  const pega = (x: Record<string, unknown>, ...ks: string[]) => { for (const k of ks) if (x[k] !== undefined) return x[k]; return undefined; };
  const lista = (pega(o, 'LoteDFe', 'loteDFe', 'lote') ?? []) as Record<string, unknown>[];
  const docs = lista.map((d) => ({
    nsu: Number(pega(d, 'NSU', 'nsu')),
    chave: (pega(d, 'ChaveAcesso', 'chaveAcesso') as string) ?? null,
    tipo: (pega(d, 'TipoDocumento', 'tipoDocumento') as string) ?? null,
    xmlGzipB64: (pega(d, 'ArquivoXml', 'arquivoXml') as string) ?? null,
  })).filter((d) => Number.isFinite(d.nsu));
  const maiorNsu = docs.length ? Math.max(...docs.map((d) => d.nsu)) : null;
  return { status: String(pega(o, 'StatusProcessamento', 'statusProcessamento') ?? ''), docs, maiorNsu };
}

// Primeiro valor de <tag> dentro do bloco <bloco>...</bloco> (sem prefixo de namespace).
function dentro(xml: string, bloco: string, tag: string): string | null {
  const b = new RegExp(`<(?:\\w+:)?${bloco}[\\s>][\\s\\S]*?</(?:\\w+:)?${bloco}>`).exec(xml);
  if (!b) return null;
  const t = new RegExp(`<(?:\\w+:)?${tag}>([^<]*)</(?:\\w+:)?${tag}>`).exec(b[0]);
  return t ? t[1].trim() : null;
}
function primeiro(xml: string, tag: string): string | null {
  const t = new RegExp(`<(?:\\w+:)?${tag}>([^<]*)</(?:\\w+:)?${tag}>`).exec(xml);
  return t ? t[1].trim() : null;
}

export type Nota = { prestador: string | null; tomador: string | null; competencia: string | null; municipio: string | null; valor: number | null };

// Leiaute nacional (DPS dentro da NFS-e): prest/CNPJ, toma/CNPJ, dCompet, cLocIncid ou cLocEmi, vServ.
export function lerNota(xml: string): Nota {
  const v = primeiro(xml, 'vServ');
  return {
    prestador: dentro(xml, 'prest', 'CNPJ') ?? dentro(xml, 'emit', 'CNPJ'),
    tomador: dentro(xml, 'toma', 'CNPJ'),
    competencia: primeiro(xml, 'dCompet'),
    municipio: primeiro(xml, 'cLocIncid') ?? primeiro(xml, 'cLocEmi'),
    valor: v === null ? null : Number(v),
  };
}

export type Resumo = { recebidas: Record<string, number>; emitidas: number; outras: number; porMunicipio: Record<string, number>; semXml: number };

// Recebida = o CNPJ consultado é o tomador. Mês pela competência (AAAA-MM).
export function resumir(notas: (Nota | null)[], cnpj: string): Resumo {
  const r: Resumo = { recebidas: {}, emitidas: 0, outras: 0, porMunicipio: {}, semXml: 0 };
  for (const n of notas) {
    if (!n) { r.semXml++; continue; }
    if (n.tomador === cnpj) {
      const mes = (n.competencia ?? 'sem data').slice(0, 7);
      r.recebidas[mes] = (r.recebidas[mes] ?? 0) + 1;
      const m = n.municipio ?? 'sem município';
      r.porMunicipio[m] = (r.porMunicipio[m] ?? 0) + 1;
    } else if (n.prestador === cnpj) r.emitidas++;
    else r.outras++;
  }
  return r;
}
