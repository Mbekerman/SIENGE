import { iniciar } from './prv.js';

let cfg = null;
try { cfg = (await import('./config.js')).default; } catch { /* sem config.js: lerConfig avisa */ }
const $ = (id) => document.getElementById(id);
iniciar(cfg, {
  raiz: $('raiz'), aviso: $('aviso'), entrar: $('entrar'), sair: $('sair'), quem: $('quem'), atualizar: $('atualizar'),
  total: $('total'), lido: $('lido'), vazio: $('vazio'), tabela: $('tabela'),
});
