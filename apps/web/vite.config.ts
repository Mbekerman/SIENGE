import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

/* Política de conteúdo (CSP) só no build: o servidor de desenvolvimento do Vite injeta script em linha.
   Script só do próprio site; conexões só com o Supabase; fontes do Google; foto do perfil do Google. */
const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' https://fonts.googleapis.com",
  "font-src https://fonts.gstatic.com",
  "img-src 'self' data: https://*.googleusercontent.com",
  "connect-src 'self' https://*.supabase.co wss://*.supabase.co",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
].join('; ');

const csp = (): Plugin => ({
  name: 'csp',
  apply: 'build',
  transformIndexHtml: html => html.replace('<head>', `<head>\n    <meta http-equiv="Content-Security-Policy" content="${CSP}" />`),
});

export default defineConfig({
  plugins: [react(), csp()],
  server: { port: 5174, host: true },
});
