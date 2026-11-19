// Árvore de navegação do ERP: módulo (menu lateral) › submódulo (coluna ao lado do menu) › abas da página.
// Lista de módulos do passo 1 (doc de telas de 8/11/2026). Submódulo sem `to` ainda não existe e aparece apagado.
import type { NomeIcone } from './icones';

export type Sub = { r: string; to?: string; rotas?: string[]; filhos?: { r: string; to: string }[] };
export type Modulo = { k: string; r: string; ic: NomeIcone; subs: Sub[] };

export const MODULOS: Modulo[] = [
  { k: 'inicio', r: 'Início', ic: 'casa', subs: [] },
  {
    k: 'fin', r: 'Financeiro', ic: 'money', subs: [
      { r: 'Contas a pagar', to: '/contas-a-pagar', rotas: ['/contas-a-pagar', '/titulos', '/previsoes', '/contratos'], filhos: [
        { r: 'Visão geral', to: '/contas-a-pagar' }, { r: 'Títulos', to: '/titulos' }, { r: 'Previsões', to: '/previsoes' }, { r: 'Contas recorrentes', to: '/contratos' }] },
      { r: 'Recebimento de notas' },
      { r: 'Retenções' },
      { r: 'Plano financeiro' },
    ],
  },
  { k: 'cad', r: 'Cadastros', ic: 'lista', subs: [{ r: 'Fornecedores' }, { r: 'Núcleos e centros' }, { r: 'Naturezas' }] },
  { k: 'rel', r: 'Relatórios', ic: 'grafico', subs: [{ r: 'Contas a pagar' }] },
  { k: 'adm', r: 'Admin', ic: 'escudo', subs: [{ r: 'Pessoas e acessos' }, { r: 'Alçadas' }, { r: 'Notificações' }] },
];

/** Módulo e submódulo da rota atual. */
export function ondeEstou(caminho: string): { m?: Modulo; s?: Sub } {
  for (const m of MODULOS) for (const s of m.subs) if (s.rotas?.some(r => caminho.startsWith(r))) return { m, s };
  return {};
}
