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
  pix_tipo: string | null; pix_chave: string | null; boleto_linha: string | null; pix_excecao: string | null; pix_copia_cola?: string | null;
  pix_copia_cola_recebedor?: { chave: string | null; url: string | null; nome: string | null } | null; pix_copia_cola_excecao?: string | null;
  pix_copia_cola_conferido?: { cpf_cnpj: string | null; nome: string | null; banco: string | null; valor: number | null; em: string } | null;
  boleto_conferido?: { cpf_cnpj: string | null; nome: string | null; valor: number | null; vencimento: string | null; em: string } | null; boleto_excecao?: string | null;
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
  /** o que não bate entre quem recebe e o fornecedor, até o pagamento (erp.recebedor_divergente) */
  recebedor_divergente?: string[];
  /** dia do cadastro do credor quando ele nunca teve título que foi ao Sienge ou foi pago (erp.credor_novo) */
  credor_novo?: string | null;
}

export type AprovacaoPrevisao = 'aprovada' | 'esperando' | 'cancelada';
export interface Previsao {
  id: string; origem: string; situacao: 'aberta' | 'consumida' | 'cancelada' | 'encerrada'; aprovacao: AprovacaoPrevisao;
  fornecedor: string | null; natureza: string | null; area: string | null; nucleo: string | null; empresa: string | null;
  competencia: string; data_prevista: string; valor: number; saldo: number | null; descricao: string | null;
  contrato_id: string | null; contrato: string | null; sienge_id: number | null; lancado_por: string | null; meu: boolean;
}

export interface Contrato {
  id: string; tipo: 'contrato' | 'assinatura' | 'consumo'; situacao: 'ativo' | 'encerrado' | 'cancelado'; aprovado: boolean | null;
  fornecedor: string | null; numero: string | null; descricao: string; inicio: string; fim: string | null;
  periodicidade: string | null; valor_periodo: number | null; valor_total: number | null; dia_vencimento: number | null;
  instalacao: string | null; faixa_mensal: number | null; teto_anual: number | null;
  areas: string | null; naturezas: string | null; empresa: string | null; previsoes_abertas: number; lancado_por: string | null; meu: boolean; posso_alterar: boolean;
}
/** O cadastro de uma conta para alterar (api.conta): o rateio vem com a divisão de último nível. */
export interface ContaCadastro {
  id: string; empresa: string; tipo: Contrato['tipo']; numero: string | null; descricao: string; fornecedor: FornecedorBusca | null;
  inicio: string; fim: string | null; periodicidade: string | null; valor_periodo: number | null; valor_total: number | null; dia_vencimento: number | null;
  caucao_percentual: number | null; instalacao: string | null; faixa_mensal: number | null; teto_anual: number | null; situacao: string;
  rateio: { nucleo: string | null; centro: string | null; divisao: string | null; natureza: string; percentual: number }[];
  /** previsão mês a mês (vazio = valor igual) e o primeiro mês que ainda muda (nulo = todos) */
  meses: { mes: string; valor: number }[]; trava_antes: string | null;
}

/** Rastro do título (api.titulo_rastro): de onde veio, quem aprovou, o que mudou, os anexos, o contrato e o fornecedor. */
export interface Rastro {
  origem: {
    compromisso: { id: string; tipo: string; numero: string | null; descricao: string; inicio: string; fim: string | null;
                   valor_total: number | null; valor_periodo: number | null; periodicidade: string | null; situacao: string; lancado_por: string | null } | null;
    nota: { tipo: string; numero: string; serie: string | null; emissao: string; valor_bruto: number; lancada_por: string | null; lancada_em: string | null } | null;
    previsoes: { id: string; sienge: string | null; data_prevista: string; valor: number; aprovada_por: string | null }[];
    substitui: { numero: string | null; motivo: string | null } | null;
  };
  aprovacoes: { rodada: number; area: string | null; fase: number; lista: string; aprovado: boolean; justificativa: string | null; por: string | null; em: string; origem: string }[];
  rodada_atual: number;
  alteracoes: { rodada: number; area: string | null; motivo: string; pedida_por: string | null; pedida_em: string; resposta: string | null;
                reenviada_por: string | null; reenviada_em: string | null; ajustes: { campo: string; antes: string | null; depois: string | null }[] }[];
  historico: { em: string; por: string | null; texto: string }[];
  anexos: { id: string; nome: string; tipo_mime: string; tamanho: number; enviado_por: string | null; enviado_em: string }[];
  contrato: { tipo: string; numero: string | null; descricao: string; valor_total: number | null; valor_periodo: number | null; periodicidade: string | null;
              lancado: number; pago: number; saldo: number | null;
              titulos: { id: string; documento: string | null; competencia: string; valor: number; etapa: EtapaTitulo; pago_em: string | null; este: boolean }[] } | null;
  fornecedor: { nome: string; documento: string | null; email: string | null; telefone: string | null; endereco: string | null; desde: string | null;
                contas: { descricao: string }[]; titulos: number; total_12m: number; pago_total: number; contratos_ativos: number;
                ultimos: { id: string; documento: string | null; emissao: string; valor: number; etapa: EtapaTitulo; area: string | null; este: boolean }[] };
}

// Lançar título (migration 20261119000200_api_lancar_titulo.sql)
export interface OpcoesLancamento {
  empresas: { id: string; nome: string; documento: string | null; nucleos: { id: string; nome: string; centros: string[] }[] }[];
  centros: { id: string; nome: string; divisoes: { id: string; caminho: string }[] }[];
  etiquetas: { id: string; nome: string }[];
}
export interface NaturezaLancavel { id: string; codigo: string | null; caminho: string; restrita: boolean }
export interface FornecedorBusca { id: string; nome: string; nome_fantasia: string | null; documento: string | null; tipo: 'fisica' | 'juridica' }
export interface PrevisaoParaNota {
  id: string; data_prevista: string; competencia: string; valor: number; saldo: number; descricao: string | null;
  natureza: string | null; area: string | null; contrato: string | null; compromisso_id: string | null; sienge: string | null; aprovada: boolean | null;
}

// Para aprovar (migration 20261119000500_api_aprovar.sql): uma linha por alçada pendente (título e previsão) ou por contrato
export type TipoAprovacao = 'titulo' | 'previsao' | 'contrato';
export interface Aprovacao {
  tipo: TipoAprovacao; id: string; centro_id: string | null; divisao_id: string | null; area: string | null;
  /** valor que cabe a esta alçada quando o título ou a previsão tem rateio; nulo no contrato */
  parte: number | null; valor: number; fornecedor: string | null; descricao: string | null; data: string | null; empresa: string | null;
  lancado_por: string | null; lancado_em: string | null; esperando: string | null;
  /** é a vez de quem vê; `motivo` diz por que não (a mesma mensagem que a decisão daria) */
  vez: boolean; motivo: string | null;
}

// Leitor de notas (servicos/leitor): o que volta de POST /anexos. A Leitura é a mesma de servicos/leitor/leitura.ts.
export interface Leitura {
  origem: 'xml' | 'ia'; modelo?: string; formato?: string;
  tipo?: 'nfe' | 'nfse' | 'fatura' | 'boleto' | 'iptu' | 'itbi' | 'darf' | 'darm' | 'dare' | 'recibo' | 'outro';
  emitente?: { documento?: string; nome?: string }; tomador?: { documento?: string; documento_mascara?: string; nome?: string };
  numero?: string; serie?: string; chave_acesso?: string; emissao?: string; competencia?: string;
  valor?: number; valor_liquido?: number;
  retencoes?: { iss?: number; irrf?: number; inss?: number; pis?: number; cofins?: number; csll?: number };
  descricao?: string;
  parcelas?: { numero?: string; vencimento?: string; valor?: number; pix_copia_cola?: string }[];
  boletos?: { linha: string; valida: boolean; valor?: number; vencimento?: string; banco?: string;
              conferido_asaas?: { ok: boolean; valor?: number; vencimento?: string; beneficiario?: string; beneficiario_documento?: string; erro?: string } }[];
  pix?: { chave?: string; copia_e_cola?: string };
  consumo?: { instalacao?: string; referencia?: string; vencimento?: string };
  avisos?: string[];
}
/** api.identificar_nota (migration 20261119000400_erp_anexos.sql) */
export interface Identificacao {
  empresa: { id: string; nome: string; documento: string } | null;
  fornecedor: { id: string; nome: string; documento: string | null; fornecedor: boolean } | null;
  nota_repetida: { documento_id: string; titulo_id: string | null; tipo: string; numero: string; serie: string | null; emissao: string; valor: number; situacao: string }[];
  candidatos: { tipo: 'previsao' | 'contrato'; id: string; compromisso_id: string | null; compromisso_tipo: string | null; numero: string | null;
                descricao: string | null; valor: number | null; data: string | null; empresa_id: string; pontos: number; motivos: string[];
                rateio: { nucleo: string; centro: string; divisao: string | null; natureza: string; percentual: number }[] }[];
  pagamento: { forma: 'pix' | 'boleto'; pix_tipo: 'cpf_cnpj' | 'email' | 'telefone' | 'aleatoria' | null; pix_chave: string | null; de_titulo: string } | null;
}
export interface ResultadoLeitor {
  anexo: { id: string; nome: string; tipo_mime: string; tamanho: number };
  repetido_em: { documento_id: string; tipo: string; numero: string; emissao: string; valor: number; titulo_id: string | null }[];
  leitura: Leitura | null;
  erro_leitura?: string;
  pede_senha?: boolean;   // PDF com senha que os CNPJs das empresas não abriram
  identificacao: Identificacao | null;
}
