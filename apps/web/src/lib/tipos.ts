// O que as funções do esquema api devolvem (migration 20261118000500_api_telas.sql). Escrito à mão.

export interface Eu {
  id: string; nome: string; papel: 'diretor' | 'gestor' | 'analista' | 'leitura'; administrador: boolean;
  master: boolean; escreve: boolean; listas: ('AF' | 'AO' | 'AD')[];
}

export type EtapaTitulo = 'rascunho' | 'aprovacao' | 'recusado' | 'revisao' | 'aprovado' | 'sienge' | 'erro_sienge' | 'pago' | 'cancelado';

export interface Titulo {
  id: string; tipo: string; etapa: EtapaTitulo; fornecedor: string; fornecedor_documento: string | null; documento: string | null;
  numero: string | null; emissao: string; competencia: string; valor: number; vencimento: string | null; parcelas: number;
  areas: string | null; empresa: string | null; lancado_por: string | null; lancado_em: string; aprovacao_pendente: string | null;
  sienge_id: number | null; meu: boolean;
}

export interface ParcelaDetalhe {
  numero: number; vencimento: string; valor: number; saldo: number | null; forma: 'pix' | 'boleto' | null;
  pix_tipo: string | null; pix_chave: string | null; boleto_linha: string | null; pix_excecao: string | null;
}

/* api.titulo: a linha da lista mais o detalhe; ali `parcelas` é a lista das parcelas, não a contagem. */
export interface TituloDetalhe extends Omit<Titulo, 'parcelas'> {
  descricao: string | null;
  nota: { tipo: string; numero: string; serie: string | null; emissao: string; valor_bruto: number; caucao: number | null;
          retencoes: { imposto: string; valor: number; vencimento: string | null }[] } | null;
  parcelas: ParcelaDetalhe[];
  rateio: { nucleo: string | null; area: string | null; natureza: string | null; percentual: number; valor: number }[];
  aprovacoes: { area: string | null; lista: string | null; aprovado: boolean; justificativa: string | null; por: string | null; em: string }[];
  etiquetas: string[];
  previsoes: { id: string; valor: number; data_prevista: string }[];
  sienge_erro: string | null;
}

export type AprovacaoPrevisao = 'aprovada' | 'esperando' | 'cancelada';
export interface Previsao {
  id: string; origem: string; situacao: 'aberta' | 'consumida' | 'cancelada' | 'encerrada'; aprovacao: AprovacaoPrevisao;
  fornecedor: string | null; natureza: string | null; area: string | null; nucleo: string | null; empresa: string | null;
  competencia: string; data_prevista: string; valor: number; saldo: number | null; descricao: string | null;
  contrato_id: string | null; contrato: string | null; sienge_id: number | null; lancado_por: string | null; meu: boolean;
}

export interface Contrato {
  id: string; tipo: 'contrato' | 'assinatura'; situacao: 'ativo' | 'encerrado' | 'cancelado'; aprovado: boolean | null;
  fornecedor: string | null; numero: string | null; descricao: string; inicio: string; fim: string | null;
  periodicidade: string | null; valor_periodo: number | null; valor_total: number | null; dia_vencimento: number | null;
  areas: string | null; naturezas: string | null; empresa: string | null; previsoes_abertas: number; lancado_por: string | null; meu: boolean;
}
