// Recebedor do aviso do Sienge (webhook). Sem dependência de Deno nem de Node: testado em logica.test.ts.
// O aviso é dado, não ordem: qualquer um pode mandar um POST a este endereço. O recebedor só confere o
// token do cadastro (Authorization: Bearer, comparado em tempo constante), valida o formato e registra
// (erp.sienge_registrar_aviso). Quem age é o programa de envio (servicos/sienge-escrita/fila.ts), e só
// depois de reler o título no Sienge e ver o 404.

export const EVENTOS = new Set(['PAYMENT_INSTALLMENT_REMOVED']);
export const CORPO_MAX = 8_192; // o corpo do Sienge tem uns 150 bytes
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type Aviso = { eventoId: string; evento: string; hook: string | null; corpo: Record<string, unknown> };
export type Registrar = (a: Aviso) => Promise<boolean>;

export function iguais(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a), eb = new TextEncoder().encode(b);
  let d = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) d |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return d === 0;
}

// Resposta 2xx só quando o aviso foi registrado (ou é repetido ou de evento que não usamos); erro do banco
// responde 500 para o Sienge tentar de novo (10 min, 30 min, 1 h, 3 h e 5 h).
export async function receber(req: Request, token: string | null | undefined, registrar: Registrar): Promise<Response> {
  if (req.method !== 'POST') return new Response('só POST', { status: 405 });
  // Sem token guardado, ninguém entra (nunca comparar com vazio).
  if (!token || token.length < 32) return new Response('recebedor sem token', { status: 503 });
  const aut = req.headers.get('authorization') ?? '';
  const m = aut.match(/^Bearer (.+)$/);
  if (!m || !iguais(m[1], token)) return new Response('não autorizado', { status: 401 });

  const eventoId = req.headers.get('x-sienge-id') ?? '';
  const evento = req.headers.get('x-sienge-event') ?? '';
  const hook = (req.headers.get('x-sienge-hook-id') ?? '').slice(0, 60) || null;
  if (!UUID.test(eventoId)) return new Response('x-sienge-id inválido', { status: 400 });
  if (!/^[A-Z_]{3,60}$/.test(evento)) return new Response('x-sienge-event inválido', { status: 400 });
  // Evento que não cadastramos: responde 200 para o Sienge não insistir, sem gravar.
  if (!EVENTOS.has(evento)) return Response.json({ ok: true, ignorado: evento });

  const texto = await req.text();
  if (new TextEncoder().encode(texto).length > CORPO_MAX) return new Response('corpo grande demais', { status: 413 });
  let corpo: unknown;
  try { corpo = JSON.parse(texto); } catch { return new Response('corpo não é JSON', { status: 400 }); }
  if (!corpo || typeof corpo !== 'object' || Array.isArray(corpo)) return new Response('corpo não é objeto', { status: 400 });

  try {
    const novo = await registrar({ eventoId: eventoId.toLowerCase(), evento, hook, corpo: corpo as Record<string, unknown> });
    return Response.json({ ok: true, novo });
  } catch {
    // o erro do banco não vai para quem chamou
    return new Response('erro ao registrar', { status: 500 });
  }
}
