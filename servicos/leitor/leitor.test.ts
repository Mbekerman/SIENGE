// Testes do leitor, só com dados inventados (nada das amostras reais entra no repositório, que é público).
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { pdfCriptografado, senhasCandidatas, tentarSenhas, tipoPelosBytes } from './arquivo.ts';
import { conferirLinha } from './boleto.ts';
import { type Bucket, type Deps, Recusa, abrirComSenha, baixar, pedidoIdentificar, subir } from './fluxo.ts';
import { chaveValida, converter, ESQUEMA } from './ia.ts';
import { Limite } from './limite.ts';
import { lerXml } from './xml.ts';
import { analisar } from './xml.ts';
import { createServer, request } from 'node:http';
import { tratador } from './rotas.ts';

const NFE = `<?xml version="1.0" encoding="UTF-8"?>
<nfeProc versao="4.00" xmlns="http://www.portalfiscal.inf.br/nfe"><NFe><infNFe Id="NFe35261111222333000181550010000012341000012345" versao="4.00">
<ide><mod>55</mod><serie>1</serie><nNF>1234</nNF><dhEmi>2026-11-03T10:00:00-03:00</dhEmi><natOp>VENDA &amp; REMESSA</natOp></ide>
<emit><CNPJ>11222333000181</CNPJ><xNome>FORNECEDOR TESTE LTDA</xNome></emit>
<dest><CNPJ>44555666000199</CNPJ><xNome>SPE TESTE</xNome></dest>
<total><ICMSTot><vNF>1500.50</vNF></ICMSTot><retTrib><vIRRF>15.00</vIRRF></retTrib></total>
<cobr><dup><nDup>001</nDup><dVenc>2026-12-03</dVenc><vDup>750.25</vDup></dup><dup><nDup>002</nDup><dVenc>2027-01-03</dVenc><vDup>750.25</vDup></dup></cobr>
</infNFe></NFe><protNFe><infProt><chNFe>35261111222333000181550010000012341000012345</chNFe><cStat>100</cStat></infProt></protNFe></nfeProc>`;

test('NF-e: campos, parcelas, entidade e retenção', () => {
  const l = lerXml(NFE)!;
  assert.equal(l.origem, 'xml'); assert.equal(l.tipo, 'nfe');
  assert.deepEqual(l.emitente, { documento: '11222333000181', nome: 'FORNECEDOR TESTE LTDA' });
  assert.equal(l.tomador?.documento, '44555666000199');
  assert.equal(l.numero, '1234'); assert.equal(l.serie, '1'); assert.equal(l.emissao, '2026-11-03');
  assert.equal(l.valor, 1500.5); assert.equal(l.descricao, 'VENDA & REMESSA');
  assert.equal(l.chave_acesso, '35261111222333000181550010000012341000012345');
  assert.deepEqual(l.parcelas, [{ numero: '001', vencimento: '2026-12-03', valor: 750.25 }, { numero: '002', vencimento: '2027-01-03', valor: 750.25 }]);
  assert.deepEqual(l.retencoes, { irrf: 15 });
  assert.equal(l.avisos, undefined);
});

test('NF-e sem protocolo e cancelada geram aviso', () => {
  assert.match(lerXml(NFE.replace(/<protNFe>.*<\/protNFe>/s, ''))!.avisos!.join(), /sem o protocolo/);
  assert.match(lerXml(NFE.replace('<cStat>100', '<cStat>101'))!.avisos!.join(), /Situação na SEFAZ: 101/);
});

test('NFS-e de São Paulo: ISS só quando retido', () => {
  const x = (ret: string) => `<RetornoConsulta><NFe><ChaveNFe><NumeroNFe>987</NumeroNFe><CodigoVerificacao>AB12CD34</CodigoVerificacao></ChaveNFe>
    <DataEmissaoNFe>2026-10-31T08:00:00</DataEmissaoNFe><CPFCNPJPrestador><CNPJ>11222333000181</CNPJ></CPFCNPJPrestador>
    <RazaoSocialPrestador>AGENCIA TESTE</RazaoSocialPrestador><CPFCNPJTomador><CNPJ>44555666000199</CNPJ></CPFCNPJTomador>
    <ValorServicos>10000</ValorServicos><ValorISS>500</ValorISS><ISSRetido>${ret}</ISSRetido><Discriminacao>Mídia</Discriminacao></NFe></RetornoConsulta>`;
  const l = lerXml(x('true'))!;
  assert.equal(l.tipo, 'nfse'); assert.equal(l.numero, '987'); assert.equal(l.valor, 10000); assert.equal(l.retencoes?.iss, 500);
  assert.equal(l.emitente?.documento, '11222333000181'); assert.equal(l.emissao, '2026-10-31');
  assert.equal(lerXml(x('false'))!.retencoes, undefined);
});

test('NFS-e ABRASF', () => {
  const l = lerXml(`<CompNfse><Nfse><InfNfse><Numero>55</Numero><DataEmissao>2026-09-01T00:00:00</DataEmissao><Competencia>2026-08-01</Competencia>
    <Servico><Valores><ValorServicos>200.00</ValorServicos><IssRetido>2</IssRetido><ValorIss>10</ValorIss></Valores><Discriminacao>Serviço</Discriminacao></Servico>
    <PrestadorServico><IdentificacaoPrestador><CpfCnpj><Cnpj>11222333000181</Cnpj></CpfCnpj></IdentificacaoPrestador><RazaoSocial>P</RazaoSocial></PrestadorServico>
    <TomadorServico><IdentificacaoTomador><CpfCnpj><Cnpj>44555666000199</Cnpj></CpfCnpj></IdentificacaoTomador></TomadorServico></InfNfse></Nfse></CompNfse>`)!;
  assert.equal(l.numero, '55'); assert.equal(l.competencia, '2026-08'); assert.equal(l.valor, 200);
  assert.equal(l.retencoes, undefined, 'IssRetido 2 = não retido');
  assert.equal(l.tomador?.documento, '44555666000199');
});

test('XML: desconhecido volta nulo; DOCTYPE e malformado são recusados', () => {
  assert.equal(lerXml('<outro><a>1</a></outro>'), null);
  assert.throws(() => lerXml('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>'), /DOCTYPE/);
  assert.throws(() => lerXml('<a><b></a>'), /malformado/);
});

// Monta uma linha de cobrança válida a partir de um código de barras inventado.
function linhaCobranca(banco: string, fator: string, valor: string, livre: string): string {
  const mod10 = (n: string) => { let s = 0, p = 2; for (let i = n.length - 1; i >= 0; i--) { let x = +n[i] * p; if (x > 9) x -= 9; s += x; p = 3 - p; } return (10 - s % 10) % 10; };
  const sem = banco + '9' + fator + valor + livre;
  let s = 0, p = 2; for (let i = sem.length - 1; i >= 0; i--) { s += +sem[i] * p; p = p === 9 ? 2 : p + 1; }
  let dv = 11 - (s % 11); if (dv === 0 || dv >= 10) dv = 1;
  const c1 = banco + '9' + livre.slice(0, 5), c2 = livre.slice(5, 15), c3 = livre.slice(15, 25);
  return c1 + mod10(c1) + c2 + mod10(c2) + c3 + mod10(c3) + dv + fator + valor;
}

test('boleto de cobrança: dígitos, valor e vencimento pelo fator novo', () => {
  const l = linhaCobranca('341', '1636', '0000123456', '1234567890123456789012345');
  const b = conferirLinha(l, new Date('2026-11-20'))!;
  assert.equal(b.valida, true); assert.equal(b.banco, '341'); assert.equal(b.valor, 1234.56);
  assert.equal(b.vencimento, '2026-11-20');   // 22/2/2025 + 636 dias
  const errada = l.slice(0, 40) + ((+l[40] + 1) % 10) + l.slice(41);
  assert.equal(conferirLinha(errada)!.valida, false);
  assert.equal(conferirLinha('123'), null);
  assert.equal(conferirLinha(linhaCobranca('001', '0000', '0000000000', '1'.repeat(25)))!.vencimento, undefined);
});

test('boleto de arrecadação (concessionária) em módulo 10', () => {
  const mod10 = (n: string) => { let s = 0, p = 2; for (let i = n.length - 1; i >= 0; i--) { let x = +n[i] * p; if (x > 9) x -= 9; s += x; p = 3 - p; } return (10 - s % 10) % 10; };
  const sem = '836' + '00000009876' + '0000' + '1'.repeat(25);   // 8, segmento 3, id 6 (valor efetivo, mod 10)
  const barras = sem.slice(0, 3) + mod10(sem) + sem.slice(3);
  const linha = [0, 11, 22, 33].map((i) => barras.slice(i, i + 11)).map((b) => b + mod10(b)).join('');
  const b = conferirLinha(linha)!;
  assert.equal(b.valida, true); assert.equal(b.valor, 98.76);
  assert.equal(conferirLinha(linha.slice(0, 47) + ((+linha[47] + 1) % 10))!.valida, false);
});

test('tipo pelos bytes, não pelo nome', () => {
  assert.equal(tipoPelosBytes(Buffer.from('%PDF-1.7 ...')), 'application/pdf');
  assert.equal(tipoPelosBytes(Buffer.from('\uFEFF  <?xml version="1.0"?><a/>')), 'application/xml');
  assert.equal(tipoPelosBytes(Buffer.from([0xff, 0xd8, 0xff, 0xe0])), 'image/jpeg');
  assert.equal(tipoPelosBytes(Buffer.from('MZ executável')), null);
  assert.equal(tipoPelosBytes(Buffer.from([0x3c, 0xff, 0xfe])), null, 'começa com < mas não é UTF-8');
  assert.equal(pdfCriptografado(Buffer.from('%PDF-1.4\ntrailer << /Encrypt 5 0 R >>')), true);
  assert.equal(pdfCriptografado(Buffer.from('%PDF-1.4\ntrailer << /Root 1 0 R >>')), false);
  const c = senhasCandidatas(['44.555.666/0001-99', '1', '44555666000199', '11222333000144']);
  assert.equal(c.length, 2 * (12 + 11), 'CNPJ curto e repetido ficam de fora');
  assert.deepEqual(c.slice(0, 3), ['445', '4455', '44555']);
  assert.equal(c[11], '44555666000199'); assert.equal(c[12], '112');
  assert.deepEqual(c.slice(24, 27), ['199', '0199', '00199']);
  assert.equal(c[34], '4555666000199', 'o último final é todos menos o primeiro dígito');
  assert.equal(c.at(-1), '1222333000144');
});

test('resposta da IA: nulos somem, valores zerados viram não informado, linha conferida', () => {
  const linha = linhaCobranca('341', '1638', '0000123456', '1234567890123456789012345');
  const l = converter({ tipo: 'fatura', emitente: { documento: '11.222.333/0001-81', nome: 'ENERGIA' }, tomador: { documento: null, nome: null },
    numero: null, valor: 0, emissao: '2026-11-01', competencia: '2026-10', retencoes: { iss: null }, parcelas: [],
    linhas_digitaveis: [linha, '9'.repeat(47)], consumo: { instalacao: '12345', referencia: '2026-10', vencimento: '2026-11-20' },
    observacoes: [] }, 'claude-opus-5-5');
  assert.equal(l.origem, 'ia'); assert.equal(l.tipo, 'fatura'); assert.equal(l.valor, undefined);
  assert.equal(l.emitente?.documento, '11222333000181'); assert.equal(l.tomador, undefined);
  assert.equal(l.boletos?.length, 2); assert.equal(l.boletos?.[0].valida, true); assert.equal(l.boletos?.[1].valida, false);
  assert.match(l.avisos!.join(), /dígito verificador errado/);
  assert.deepEqual(l.consumo, { instalacao: '12345', referencia: '2026-10', vencimento: '2026-11-20' });
  assert.equal(converter({ tipo: 'qualquer' }, 'm').tipo, 'outro');
});

test('esquema da IA: no máximo 16 campos com union (limite da API), todos obrigatórios e sem campo a mais', () => {
  let unioes = 0;
  const andar = (n: any) => {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n.type) || n.anyOf) unioes++;
    if (n.type === 'object' || (Array.isArray(n.type) && n.type.includes('object'))) {
      assert.equal(n.additionalProperties, false); assert.deepEqual(n.required, Object.keys(n.properties));
    }
    for (const v of Object.values(n.properties ?? {})) andar(v);
    andar(n.items);
  };
  andar(ESQUEMA);
  assert.ok(unioes <= 16, `${unioes} campos com union`);
});

test('resposta da IA: texto vazio é ausente; retenções em lista somam por tributo', () => {
  const l = converter({ tipo: 'nfse', emitente: { documento: '', nome: '  ' }, numero: '', serie: '', emissao: '', competencia: '',
    descricao: '', pix: { chave: '', copia_e_cola: '' }, consumo: { instalacao: '', referencia: '', vencimento: '' },
    parcelas: [{ numero: '', vencimento: '', valor: null }], valor: 1000,
    retencoes: [{ tributo: 'ISS', valor: 50 }, { tributo: 'irrf', valor: 15 }, { tributo: 'irrf', valor: 0.5 },
                { tributo: 'outro', valor: 9 }, { tributo: 'pis', valor: 0 }] }, 'm');
  assert.equal(l.emitente, undefined); assert.equal(l.numero, undefined); assert.equal(l.emissao, undefined);
  assert.equal(l.descricao, undefined); assert.equal(l.pix, undefined); assert.equal(l.consumo, undefined);
  assert.deepEqual(l.retencoes, { iss: 50, irrf: 15.5 });
  assert.equal(converter({ tipo: 'nfse', retencoes: [] }, 'm').retencoes, undefined);
});

test('resposta da IA: sem total impresso, o valor é a soma das parcelas (se todas têm valor)', () => {
  const dez = Array.from({ length: 10 }, (_, i) => ({ numero: String(i + 1), vencimento: `2026-${String(i + 1).padStart(2, '0')}-10`, valor: 1088.8 }));
  assert.equal(converter({ tipo: 'boleto', valor: null, parcelas: dez }, 'm').valor, 10888);
  assert.equal(converter({ tipo: 'boleto', valor: null, parcelas: [{ valor: 10 }, { valor: null }] }, 'm').valor, undefined);
  assert.equal(converter({ tipo: 'nfe', valor: 26908.48, parcelas: [{ valor: 1 }] }, 'm').valor, 26908.48);
  const l = converter({ tipo: 'nfe', valor: 26908.48, parcelas: [{ valor: 8969.49 }, { valor: 8969.49 }, { valor: 8969.5 }] }, 'm');
  assert.deepEqual(l.parcelas?.map((p) => p.valor), [8969.49, 8969.49, 8969.5]);
});

function falsos(extra: Partial<Deps> = {}) {
  const chamadas: string[] = [];
  const guardados = new Map<string, Buffer>();
  const bucket: Bucket = {
    async gravar(n, _m, d) { chamadas.push(`gravar ${n}`); if (guardados.has(n)) throw new Error('já existe'); guardados.set(n, d); },
    async ler(n) { return guardados.get(n) ?? null; },
  };
  const deps: Deps = {
    banco: { async rpc(jwt, fn, args) {
      chamadas.push(`${fn} ${jwt}`);
      if (jwt !== 'ok') throw new Recusa(401, 'Entre de novo');
      if (fn === 'registrar_anexo') return { id: '00000000-0000-4000-8000-000000000001', repetido_em: [] } as never;
      if (fn === 'identificar_nota') return { recebido: args.p } as never;
      if (fn === 'lancamento_opcoes') return { empresas: [{ documento: '44555666000199' }] } as never;
      if (fn === 'anexo') return (args.p_id === '00000000-0000-4000-8000-000000000001'
        ? { id: args.p_id, nome: (extra as any).nomeAnexo ?? 'n.xml', tipo_mime: (extra as any).mimeAnexo ?? 'application/xml', sha256: (extra as any).sha ?? 'x' } : null) as never;
      if (fn === 'meus_anexos_soltos') return ((extra as any).soltos ?? [{ id: '00000000-0000-4000-8000-000000000001' }]) as never;
      return null as never;
    } },
    bucket, ia: async () => { chamadas.push('ia'); return { origem: 'ia', tipo: 'nfse', valor: 10 }; },
    asaas: null, abrirPdf: null, log: () => {}, ...extra,
  };
  return { deps, chamadas, guardados };
}

test('subir: registra com o login, guarda com o id, lê e identifica, nessa ordem', async () => {
  const { deps, chamadas } = falsos();
  const r = await subir(deps, 'ok', 'C:\\pasta\\nota.xml', Buffer.from(NFE));
  assert.deepEqual(chamadas, ['registrar_anexo ok', 'gravar 00000000-0000-4000-8000-000000000001', 'gravar_leitura ok', 'identificar_nota ok']);
  assert.equal(r.anexo.nome, 'nota.xml'); assert.equal(r.anexo.tipo_mime, 'application/xml');
  assert.deepEqual(r.identificacao, { recebido: { tomador: '44555666000199', emitente: '11222333000181', tipo: 'nfe', numero: '1234',
    serie: '1', valor: 1500.5, emissao: '2026-11-03', vencimento: '2026-12-03' } });
});

test('subir: sem login válido não guarda nem chama a IA', async () => {
  const { deps, chamadas } = falsos();
  await assert.rejects(subir(deps, 'outro', 'a.pdf', Buffer.from('%PDF-1.7')), (e: Recusa) => e.status === 401);
  assert.deepEqual(chamadas, ['registrar_anexo outro']);
});

test('subir: tipo e tamanho recusados antes de tudo', async () => {
  const { deps, chamadas } = falsos();
  await assert.rejects(subir(deps, 'ok', 'a.exe', Buffer.from('MZ')), (e: Recusa) => e.status === 415);
  await assert.rejects(subir(deps, 'ok', 'a.pdf', Buffer.alloc(0)), (e: Recusa) => e.status === 400);
  assert.deepEqual(chamadas, []);
});

test('subir: falha da IA não perde o arquivo e não grava leitura', async () => {
  const { deps, chamadas } = falsos({ ia: async () => { throw new Error('rede'); } });
  const r = await subir(deps, 'ok', 'a.pdf', Buffer.from('%PDF-1.7'));
  assert.equal(r.leitura, null); assert.equal(r.erro_leitura, 'Não consegui ler o arquivo'); assert.equal(r.identificacao, null);
  assert.ok(!chamadas.some((c) => c.startsWith('gravar_leitura')));
});

// o falso do qpdf: tenta as senhas em ordem, como o servidor
const uma = (f: (s: string) => Promise<Buffer | null>) => async (_p: Buffer, ss: string[]) => {
  for (const s of ss) { const r = await f(s); if (r) return r; }
  return null;
};

test('subir: PDF com senha tenta os CNPJs das empresas e só então chama a IA', async () => {
  const tentadas: string[] = [];
  const { deps } = falsos({ abrirPdf: uma(async (s) => { tentadas.push(s); return s === '44555' ? Buffer.from('%PDF-aberto') : null; }) });
  const r = await subir(deps, 'ok', 'f.pdf', Buffer.from('%PDF-1.4\ntrailer << /Encrypt 5 0 R >>'));
  assert.deepEqual(tentadas, ['', '445', '4455', '44555']); assert.equal(r.leitura?.valor, 10);
  const { deps: d2 } = falsos({ abrirPdf: async () => null });
  const r2 = await subir(d2, 'ok', 'f.pdf', Buffer.from('%PDF-1.4\ntrailer << /Encrypt 5 0 R >>'));
  assert.match(r2.erro_leitura!, /senha/); assert.equal(r2.pede_senha, true);
});

test('senha do PDF: a digitada abre o guardado e lê; errada pede de novo; sem chamar a IA à toa', async () => {
  const { createHash } = await import('node:crypto');
  const pdf = Buffer.from('%PDF-1.4\ntrailer << /Encrypt 5 0 R >>');
  const sha = createHash('sha256').update(pdf).digest('hex');
  const id = '00000000-0000-4000-8000-000000000001';
  const tentadas: string[] = [];
  const { deps, chamadas } = falsos({ sha, mimeAnexo: 'application/pdf', nomeAnexo: 'f.pdf',
    abrirPdf: uma(async (s) => { tentadas.push(s); return s === 'x9!' ? Buffer.from('%PDF-aberto') : null; }) } as never);
  const r0 = await subir(deps, 'ok', 'f.pdf', pdf);
  assert.equal(r0.pede_senha, true);
  chamadas.length = 0;
  const r1 = await abrirComSenha(deps, 'ok', id, 'errada');
  assert.equal(r1.pede_senha, true); assert.equal(r1.erro_leitura, 'A senha não abriu o PDF'); assert.equal(r1.leitura, null);
  assert.ok(!chamadas.includes('ia'));
  const r2 = await abrirComSenha(deps, 'ok', id, 'x9!');
  assert.equal(r2.leitura?.valor, 10); assert.equal(r2.pede_senha, undefined); assert.equal(r2.anexo.nome, 'f.pdf');
  assert.ok(chamadas.includes('gravar_leitura ok'));
  assert.deepEqual(tentadas.slice(-2), ['errada', 'x9!']);
  await assert.rejects(abrirComSenha(deps, 'ok', id, ''), (e: Recusa) => e.status === 400);
  await assert.rejects(abrirComSenha(deps, 'ok', id, 'a\nb'), (e: Recusa) => e.status === 400);
  await assert.rejects(abrirComSenha(deps, 'ok', id, 'x'.repeat(101)), (e: Recusa) => e.status === 400);
});

test('senha do PDF: só no anexo solto da própria pessoa, conferido antes de ler o arquivo', async () => {
  const { deps, chamadas } = falsos({ soltos: [], mimeAnexo: 'application/pdf', abrirPdf: async () => Buffer.from('%PDF') } as never);
  await assert.rejects(abrirComSenha(deps, 'ok', '00000000-0000-4000-8000-000000000001', 's'), (e: Recusa) => e.status === 404);
  assert.deepEqual(chamadas, ['meus_anexos_soltos ok']);
});

test('senha do PDF: arquivo sem senha é recusado', async () => {
  const { createHash } = await import('node:crypto');
  const sha = createHash('sha256').update(NFE).digest('hex');
  const { deps } = falsos({ sha } as never);
  await subir(deps, 'ok', 'n.xml', Buffer.from(NFE));
  await assert.rejects(abrirComSenha(deps, 'ok', '00000000-0000-4000-8000-000000000001', 's'), (e: Recusa) => e.status === 400);
});

test('baixar: só quem vê o anexo, e o arquivo confere com o sha256', async () => {
  const { createHash } = await import('node:crypto');
  const sha = createHash('sha256').update(NFE).digest('hex');
  const { deps } = falsos({ sha } as never);
  await subir(deps, 'ok', 'n.xml', Buffer.from(NFE));
  const a = await baixar(deps, 'ok', '00000000-0000-4000-8000-000000000001');
  assert.equal(a.dados.toString(), NFE);
  await assert.rejects(baixar(deps, 'ok', '00000000-0000-4000-8000-000000000002'), (e: Recusa) => e.status === 404);
  await assert.rejects(baixar(deps, 'ok', '../segredo'), (e: Recusa) => e.status === 404);
  await assert.rejects(baixar(deps, 'outro', '00000000-0000-4000-8000-000000000001'), (e: Recusa) => e.status === 401);
  const { deps: d2 } = falsos({ sha: 'f'.repeat(64) } as never);
  await subir(d2, 'ok', 'n.xml', Buffer.from(NFE));
  await assert.rejects(baixar(d2, 'ok', '00000000-0000-4000-8000-000000000001'), (e: Recusa) => e.status === 409);
});

test('identificar: vencimento do boleto quando a nota não tem parcela', () => {
  assert.equal(pedidoIdentificar({ origem: 'ia', boletos: [{ linha: 'x', valida: false, vencimento: '2026-01-01' }, { linha: 'y', valida: true, vencimento: '2026-02-02' }] }).vencimento, '2026-02-02');
  assert.equal(pedidoIdentificar({ origem: 'ia', tipo: 'outro' }).tipo, null);
});

test('limite por pessoa', () => {
  const l = new Limite(2, 1000);
  assert.ok(l.passa('a', undefined, 0)); assert.ok(l.passa('a', undefined, 1)); assert.ok(!l.passa('a', undefined, 2));
  assert.ok(l.passa('b', undefined, 2)); assert.ok(l.passa('a', undefined, 1001));
  // o limite da pessoa vale no lugar do padrão; valor inválido cai no padrão
  const m = new Limite(2, 1000);
  for (let i = 0; i < 5; i++) assert.ok(m.passa('c', 5, i)); assert.ok(!m.passa('c', 5, 6));
  assert.ok(m.passa('d', 0, 0)); assert.ok(m.passa('d', -1, 1)); assert.ok(!m.passa('d', 1.5, 2));
});

test('XML malformado com muito lixo é recusado em tempo linear', () => {
  const casos = ['<'.repeat(50_000), '<!--'.repeat(300_000), '<?'.repeat(300_000), '<![CDATA['.repeat(100_000), '<a>' + '<b x="1'.repeat(100_000)];
  for (const c of casos) {
    const t = performance.now();
    assert.throws(() => analisar(c), /XML malformado/);
    assert.ok(performance.now() - t < 500, `levou ${Math.round(performance.now() - t)} ms`);
  }
  assert.throws(() => analisar('<a>texto</a> <lixo'), /XML malformado/);
});

test('subir: XML acima de 2 MB não é lido, mas o arquivo fica', async () => {
  const { deps, chamadas } = falsos();
  const r = await subir(deps, 'ok', 'grande.xml', Buffer.from('<a>' + 'x'.repeat(2 * 1024 * 1024) + '</a>'));
  assert.equal(r.leitura, null); assert.match(r.erro_leitura ?? '', /2 MB/);
  assert.ok(!chamadas.includes('ia'));
});

// Sobe o tratador numa porta livre e faz um pedido; conta quantos bytes do corpo o servidor leu.
async function pedido(quem: (j: string) => Promise<{ id: string; limite?: number } | null>, cab: Record<string, string>, corpo: Buffer, limite = new Limite(30, 60_000)) {
  const { deps, chamadas } = falsos();
  const h = tratador({ deps, limite, origens: new Set(['https://erp.exemplo']), quem });
  let lidos = 0;
  const srv = createServer((req, res) => { req.on('data', (c: Buffer) => { lidos += c.length; }); return h(req, res); });
  await new Promise<void>((ok) => srv.listen(0, ok));
  const porta = (srv.address() as { port: number }).port;
  const status = await new Promise<number>((ok) => {
    const r = request({ port: porta, method: 'POST', path: '/anexos', headers: { 'content-length': String(corpo.length), ...cab } }, (res) => { res.resume(); ok(res.statusCode ?? 0); });
    r.on('error', () => ok(-1));
    r.end(corpo);
  });
  srv.close();
  return { status, chamadas, lidos };
}

test('rotas: sem login ou com login inválido, recusa sem guardar e sem conferir no banco', async () => {
  let perguntou = 0;
  const quem = async (j: string) => { perguntou++; return j === 'bom' ? { id: 'u1' } : null; };
  const sem = await pedido(quem, {}, Buffer.from(NFE));
  assert.equal(sem.status, 401); assert.equal(perguntou, 0); assert.deepEqual(sem.chamadas, []);
  const ruim = await pedido(quem, { authorization: 'Bearer forjado' }, Buffer.from(NFE));
  assert.equal(ruim.status, 401); assert.deepEqual(ruim.chamadas, []);
});

test('rotas: o limite usa o id conferido, não o sub do JWT', async () => {
  const limite = new Limite(1, 60_000);
  const quem = async (j: string) => (j.startsWith('bom') ? { id: 'u1' } : null);
  const a = await pedido(quem, { authorization: 'Bearer bom-a' }, Buffer.from('%PDF-1.7'), limite);
  const b = await pedido(quem, { authorization: 'Bearer bom-b' }, Buffer.from('%PDF-1.7'), limite);
  assert.notEqual(a.status, 429); assert.equal(b.status, 429);
});

test('rotas: o limite configurado da pessoa vale no lugar do padrão', async () => {
  const limite = new Limite(1, 60_000);
  const quem = async (j: string) => (j === 'bom' ? { id: 'u2', limite: 3 } : null);
  const st: number[] = [];
  for (let i = 0; i < 4; i++) st.push((await pedido(quem, { authorization: 'Bearer bom' }, Buffer.from('%PDF-1.7'), limite)).status);
  assert.ok(st.slice(0, 3).every((s) => s !== 429), st.join()); assert.equal(st[3], 429);
});

test('senhas do PDF: para na que abre, segue na errada, desiste em código estranho e no prazo total', async () => {
  const vistas: string[] = [];
  const conf = (codigos: Record<string, number>) => async (s: string) => { vistas.push(s); return codigos[s] ?? 0; };
  assert.equal(await tentarSenhas(['a', 'b', 'c'], conf({ b: 3 })), 'b');
  assert.deepEqual(vistas, ['a', 'b']);
  vistas.length = 0;
  assert.equal(await tentarSenhas(['a', 'b', 'c'], conf({ a: 2 })), null, '2 = não cifrado ou danificado');
  assert.deepEqual(vistas, ['a'], 'sai na primeira tentativa');
  vistas.length = 0;
  assert.equal(await tentarSenhas(['a', 'b'], conf({ a: -1 })), null, 'tempo esgotado ou erro');
  assert.deepEqual(vistas, ['a']);
  // prazo: cada tentativa "leva" 6 s num relógio falso; com 15 s, a terceira já não roda
  let t = 0; const restos: number[] = []; vistas.length = 0;
  const lenta = async (s: string, resta: number) => { vistas.push(s); restos.push(resta); t += 6000; return 0; };
  assert.equal(await tentarSenhas(['a', 'b', 'c', 'd'], lenta, 15_000, () => t), null);
  assert.deepEqual(vistas, ['a', 'b', 'c']);
  assert.deepEqual(restos, [15_000, 9_000, 3_000], 'cada qpdf recebe só o tempo que resta');
});

test('chave de acesso lida pela IA: dígito verificador conferido, errada sai com aviso', () => {
  const base = '3526111122233300018155001000001234100001234';
  const certas = [...'0123456789'].filter((d) => chaveValida(base + d));
  assert.equal(certas.length, 1, 'um só dígito verificador fecha');
  const boa = base + certas[0];
  const ruim = base + ((Number(certas[0]) + 1) % 10);
  const l1 = converter({ tipo: 'nfe', chave_acesso: boa.replace(/(\d{4})/g, '$1 ').trim() }, 'm');
  assert.equal(l1.chave_acesso, boa, 'com espaços, guarda só os dígitos');
  assert.equal(l1.avisos, undefined);
  const l2 = converter({ tipo: 'nfe', chave_acesso: ruim }, 'm');
  assert.equal(l2.chave_acesso, undefined);
  assert.match(l2.avisos![0], /dígito verificador/);
  assert.equal(converter({ tipo: 'nfse', chave_acesso: 'AB12-CD34' }, 'm').chave_acesso, 'AB12-CD34', 'NFS-e passa como veio');
  assert.equal(chaveValida('123'), false);
});
