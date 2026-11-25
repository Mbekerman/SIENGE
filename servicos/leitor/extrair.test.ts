import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dvChave, extrair, temTexto } from './extrair.ts';
import { type Deps, Recusa, chaveDeNota, juntar, subir } from './fluxo.ts';
import { crc16Pix } from './ia.ts';
import { lerArquivo } from './lote.ts';

// Dados inventados. A chave da NF-e de teste do leitor.test.ts (CNPJ do emitente 11.222.333/0001-81).
const CHAVE = '35261111222333000181550010000012341000012345';
const comDv = (d: string) => {
  let s = 0; for (let i = d.length - 1, p = 2; i >= 0; i--, p = p === 9 ? 2 : p + 1) s += Number(d[i]) * p;
  const r = s % 11; return d + (r < 2 ? 0 : 11 - r);
};
// NFS-e nacional: município (7), ambiente, tipo de inscrição, CNPJ (14), número (13), AAMM, código (9) e DV.
const CHAVE_NFSE = comDv('3550308' + '1' + '2' + '11222333000181' + '0000000000077' + '2611' + '123456789');
function linhaCobranca(banco: string, fator: string, valor: string, livre: string): string {
  const mod10 = (n: string) => { let s = 0, p = 2; for (let i = n.length - 1; i >= 0; i--) { let x = +n[i] * p; if (x > 9) x -= 9; s += x; p = 3 - p; } return (10 - s % 10) % 10; };
  const sem = banco + '9' + fator + valor + livre;
  let s = 0, p = 2; for (let i = sem.length - 1; i >= 0; i--) { s += +sem[i] * p; p = p === 9 ? 2 : p + 1; }
  let dv = 11 - (s % 11); if (dv === 0 || dv >= 10) dv = 1;
  const c1 = banco + '9' + livre.slice(0, 5), c2 = livre.slice(5, 15), c3 = livre.slice(15, 25);
  return c1 + mod10(c1) + c2 + mod10(c2) + c3 + mod10(c3) + dv + fator + valor;
}
const LINHA = linhaCobranca('341', '1638', '0000123456', '1234567890123456789012345');
const impressa = (l: string) => `${l.slice(0, 5)}.${l.slice(5, 10)} ${l.slice(10, 15)}.${l.slice(15, 21)} ${l.slice(21, 26)}.${l.slice(26, 32)} ${l[32]} ${l.slice(33)}`;
const PIX0 = '00020126360014BR.GOV.BCB.PIX0114+5511999999999520400005303986540510.005802BR5913FORNECEDOR TE6009SAO PAULO62070503***6304';
const PIX = PIX0 + crc16Pix(PIX0);
const DANFE = `DANFE  DOCUMENTO AUXILIAR DA NOTA FISCAL ELETRÔNICA  FORNECEDOR TESTE LTDA  CNPJ 11.222.333/0001-81
DESTINATÁRIO SPE TESTE CNPJ 11.444.777/0001-61   VALOR TOTAL DA NOTA 1.500,50
CHAVE DE ACESSO
${CHAVE.match(/.{4}/g)!.join(' ')}
Consulta de autenticidade no portal nacional da NF-e www.nfe.fazenda.gov.br/portal ou no site da Sefaz Autorizadora`;

test('texto: chave da DANFE em grupos de 4, CNPJs com DV, linha do boleto impressa e PIX quebrado', () => {
  assert.ok(dvChave(CHAVE) && dvChave(CHAVE_NFSE));
  const e = extrair(`${DANFE}\nLinha digitável: ${impressa(LINHA)}\nPIX: ${PIX.slice(0, 60)}\n${PIX.slice(60)}\nCPF 111.111.111-11`);
  assert.deepEqual(e.chaves, [CHAVE]);
  assert.deepEqual(e.documentos, ['11222333000181', '11444777000161']);   // CPF repetido não confere
  assert.deepEqual(e.boletos.map((b) => b.linha), [LINHA]);
  assert.deepEqual(e.pix, [PIX]);
  assert.deepEqual(extrair(`chave ${CHAVE_NFSE}`).chaves, [CHAVE_NFSE]);
  assert.deepEqual(extrair(`CHAVE DE ACESSO ${CHAVE.match(/.{4}/g)!.join(' ')} Protocolo`).chaves, [CHAVE]);
  assert.deepEqual(extrair(`9 ${CHAVE.match(/.{4}/g)!.join(' ')}`).chaves, [], 'grupo a mais na frente não é a chave');
});

test('texto: dígito errado, número maior e código de barras do boleto não viram chave', () => {
  const errada = CHAVE.slice(0, 43) + ((Number(CHAVE[43]) + 1) % 10);
  assert.deepEqual(extrair(`x ${errada} ${CHAVE}9 ${LINHA.slice(0, 46)}`).chaves, []);
  assert.equal(chaveDeNota(CHAVE), true);
  assert.equal(chaveDeNota(comDv('3426' + '9'.repeat(39))), false, 'UF 34 não existe');
  assert.equal(chaveDeNota(comDv('35261111222333000181' + '57' + '0'.repeat(21))), false, 'CT-e não é nota recebida');
  assert.equal(temTexto('pouco'), false);
  assert.equal(temTexto(DANFE), true);
});

test('juntar: linha do texto entra no lugar da lida errada; chave e PIX só quando únicos', () => {
  const l = juntar({ origem: 'ia', boletos: [{ linha: '1'.repeat(47), valida: false }] }, extrair(`${DANFE} ${impressa(LINHA)} ${PIX}`));
  assert.deepEqual(l.boletos!.map((b) => [b.linha, b.valida]), [[LINHA, true]]);
  assert.equal(l.chave_acesso, CHAVE);
  assert.equal(l.pix?.copia_e_cola, PIX);
  assert.match(l.avisos!.join(), /Linha do boleto conferida pelo texto/);
  const m = juntar({ origem: 'ia', chave_acesso: 'outra' }, extrair(`${DANFE} chave ${CHAVE_NFSE}`));
  assert.equal(m.chave_acesso, 'outra', 'a da leitura fica');
  assert.equal(m.boletos, undefined);
});

const XML = `<nfeProc><NFe><infNFe Id="NFe${CHAVE}" versao="4.00"><ide><mod>55</mod><nNF>1234</nNF><dhEmi>2026-11-03T10:00:00-03:00</dhEmi></ide>
<emit><CNPJ>11222333000181</CNPJ></emit><dest><CNPJ>44555666000199</CNPJ></dest><total><ICMSTot><vNF>1500.50</vNF></ICMSTot></total>
</infNFe></NFe><protNFe><infProt><chNFe>${CHAVE}</chNFe><cStat>100</cStat></infProt></protNFe></nfeProc>`;

function falsos(texto: string | null, busca: (args: Record<string, unknown>) => unknown) {
  const chamadas: string[] = [];
  const deps: Deps = {
    banco: { async rpc(jwt, fn, args) {
      chamadas.push(fn);
      if (fn === 'registrar_anexo') return { id: '00000000-0000-4000-8000-000000000001', repetido_em: [] } as never;
      if (fn === 'buscar_nota_recebida') return busca(args) as never;
      return null as never;
    } },
    bucket: { async gravar() {}, async ler() { return null; } },
    ia: async () => { chamadas.push('ia'); return { origem: 'ia', tipo: 'nfe', valor: 9 }; },
    asaas: null, abrirPdf: null, textoPdf: async () => texto, log: () => {},
  };
  return { deps, chamadas };
}
const PDF = Buffer.from('%PDF-1.7 de teste');

test('PDF com a chave de uma nota recebida: lê o XML, sem IA, e junta a linha do boleto', async () => {
  const { deps, chamadas } = falsos(`${DANFE}\n${impressa(LINHA)}`, (a) => (a.p_chave === CHAVE ? { xml: XML } : null));
  const r = await subir(deps, 'ok', 'danfe.pdf', PDF);
  assert.equal(r.leitura?.origem, 'xml');
  assert.equal(r.leitura?.valor, 1500.5);
  assert.deepEqual(r.leitura?.boletos?.map((b) => b.linha), [LINHA]);
  assert.match(r.leitura!.avisos!.join(), /busca automática/);
  assert.ok(!chamadas.includes('ia'));
});

test('PDF: sem a nota, com erro do banco, com duas chaves ou com o emitente fora do texto, a IA lê', async () => {
  for (const [texto, busca] of [
    [DANFE, () => null],                                                         // nota não chegou (ou é de PJ e a pessoa não vê)
    [DANFE, () => { throw new Recusa(422, 'Sem permissão para lançar'); }],
    [`${DANFE}\nreferenciada ${CHAVE_NFSE}`, () => ({ xml: XML })],              // ambíguo
    [DANFE.replace('11.222.333/0001-81', ''), () => ({ xml: XML })],             // o emitente da chave não aparece
    [DANFE, () => ({ xml: XML.replaceAll(CHAVE, CHAVE_NFSE) })],                 // XML de outra chave
    ['escaneado', () => ({ xml: XML })],                                         // sem texto: nem busca
  ] as [string, () => unknown][]) {
    const { deps, chamadas } = falsos(texto, busca);
    const r = await subir(deps, 'ok', 'a.pdf', PDF);
    assert.equal(r.leitura?.origem, 'ia', texto.slice(-30));
    assert.ok(chamadas.includes('ia'));
  }
  const { deps, chamadas } = falsos(null, () => ({ xml: XML }));
  deps.textoPdf = async () => { throw new Error('pdftotext'); };
  assert.equal((await subir(deps, 'ok', 'a.pdf', PDF)).leitura?.origem, 'ia');
  assert.ok(!chamadas.includes('buscar_nota_recebida'));
});

test('lote no modo texto: só o que sai do texto, sem IA e sem guardar o texto', async () => {
  const ia = async () => { throw new Error('não chama a IA'); };
  const r = await lerArquivo('a.pdf', PDF, ia as never, async () => null, async () => `${DANFE} ${impressa(LINHA)}`);
  assert.deepEqual(r.texto, { tem: true, chaves: [CHAVE], boletos: [LINHA], documentos: ['11222333000181', '11444777000161'], pix: 0 });
  assert.equal(r.erro, undefined);
  assert.ok(!JSON.stringify(r).includes('DESTINATÁRIO'));
  const f = await lerArquivo('a.png', Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]), ia as never, async () => null, async () => 'x');
  assert.equal(f.texto?.tem, false);
});

test('texto: só os primeiros 200 mil caracteres são procurados', () => {
  assert.deepEqual(extrair('x'.repeat(200_000) + ` ${CHAVE}`).chaves, []);
  assert.deepEqual(extrair('000201'.repeat(300_000)).pix, []);
});
