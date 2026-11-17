// Envio de títulos aprovados ao Sienge (Edge Function do Supabase, Deno). Cada chamada põe na fila os
// títulos recém-aprovados e envia UM título (fila.ts); quem chama de minuto em minuto é o pg_cron
// (supabase/dev/sienge_escrita_agenda.sql). Toda gravação passa pela trava (trava.ts).
// Segredos (Edge Functions › Secrets): SIENGE_USUARIO e SIENGE_SENHA; SIENGE_AMBIENTE só na produção,
// com a palavra exata "producao" (sem ela, a trava só deixa gravar na empresa 11 com credor de teste);
// SIENGE_CREDORES_TESTE (padrão 823). SUPABASE_DB_URL vem do Supabase.
// A chave de quem chama fica no Vault do banco (sienge_escrita_chave), lida aqui e pelo pg_cron.
// Com o corpo {"tarefa": "planilha"}, em vez de enviar, reescreve a planilha do Google das linhas PRV a
// apagar (planilha.ts; segredos GOOGLE_PLANILHA_CHAVE, o JSON da conta de serviço, e PLANILHA_PRV_ID).
import postgres from 'npm:postgres@3.4.4';
import { bancoPostgres, httpSienge, processarUm } from './fila.ts';
import { atualizarPlanilha, idPlanilha, lerChave } from './planilha.ts';

const SUB = Deno.env.get('SIENGE_SUBDOMINIO') ?? 'bkmincorporadora';
const BASE = `https://api.sienge.com.br/${SUB}/public/api/v1`;

function credencial(): string {
  const u = Deno.env.get('SIENGE_USUARIO'), s = Deno.env.get('SIENGE_SENHA');
  if (!u || !s) throw new Error('faltam os segredos SIENGE_USUARIO e SIENGE_SENHA');
  return 'Basic ' + btoa(`${u}:${s}`);
}

function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  const sql = postgres(Deno.env.get('SUPABASE_DB_URL')!, { max: 1, prepare: false });
  try {
    const [k] = await sql`select decrypted_secret as v from vault.decrypted_secrets where name = 'sienge_escrita_chave'`;
    if (!k?.v || !iguais(req.headers.get('x-escrita-chave') ?? '', k.v)) return new Response('não autorizado', { status: 401 });
    const pedido = await req.json().catch(() => ({}));
    if (pedido?.tarefa === 'planilha') {
      const banco = bancoPostgres(sql);
      return Response.json(await atualizarPlanilha(() => banco.linhasApagar(), lerChave(Deno.env.get('GOOGLE_PLANILHA_CHAVE')),
        idPlanilha(Deno.env.get('PLANILHA_PRV_ID')), new Date()));
    }
    const credores = (Deno.env.get('SIENGE_CREDORES_TESTE') ?? '823').split(',').map((x) => Number(x.trim())).filter(Number.isInteger);
    const r = await processarUm(bancoPostgres(sql), httpSienge(BASE, credencial()), {
      ambiente: Deno.env.get('SIENGE_AMBIENTE'), credoresTeste: credores,
    });
    return Response.json(r);
  } catch (err) {
    return Response.json({ erro: String((err as Error)?.message ?? err).slice(0, 500) }, { status: 500 });
  } finally {
    await sql.end();
  }
});
