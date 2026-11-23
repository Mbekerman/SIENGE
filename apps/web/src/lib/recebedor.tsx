// O selo "recebedor não confere" (Moises, 20/11/2026: "mesmo se aprovado com justificativa aquele processo deve ter um
// alerta em toda sua vida até o pagamento mostrando a todos que não bate o recebedor com o fornecedor"). Quem decide é
// o banco (erp.recebedor_divergente): chave CPF/CNPJ de outra pessoa, PIX copia e cola ou boleto sem o fornecedor
// conferido como quem recebe; some quando o título é pago ou cancelado.
import { useQuery } from '@tanstack/react-query';
import { Alerta, Chip } from '../components/Comum';
import { rpc } from './supabase';

/** Os títulos a pagar com o recebedor que não bate, que a pessoa vê (chave ['titulos', …]: recarrega com a lista). */
export function useDivergentes(): Map<string, string[]> {
  const q = useQuery({ queryKey: ['titulos', 'recebedores-divergentes'], queryFn: () => rpc<{ id: string; motivos: string[] }[]>('recebedores_divergentes') });
  return new Map((q.data ?? []).map(d => [d.id, d.motivos]));
}

export function SeloRecebedor({ motivos }: { motivos?: string[] }) {
  return motivos?.length ? <span title={motivos.join('\n')}><Chip t="Recebedor não confere" c="cr" /></span> : null;
}

export function AlertaRecebedor({ motivos }: { motivos?: string[] | null }) {
  if (!motivos?.length) return null;
  return <Alerta c="cr" t={<><b>Quem recebe não é o fornecedor conferido.</b> Fica marcado até o pagamento.{motivos.map(m => <span key={m} style={{ display: 'block' }}>{m}</span>)}</>} />;
}

// O selo "credor novo" (S-140, Moises, 20/11/2026): o credor nunca teve outro título que foi ao Sienge ou foi pago. Quem
// decide é o banco (erp.credor_novo). Serve para quem aprova olhar com mais cuidado o cadastro (documento e nome).
/** Os títulos a pagar de credor novo que a pessoa vê, com o dia do cadastro do credor. */
export function useCredoresNovos(): Map<string, string> {
  const q = useQuery({ queryKey: ['titulos', 'credores-novos'], queryFn: () => rpc<{ id: string; desde: string }[]>('credores_novos') });
  return new Map((q.data ?? []).map(d => [d.id, d.desde]));
}

const dia = (d: string) => d.split('-').reverse().join('/');

export function SeloCredorNovo({ desde }: { desde?: string | null }) {
  return desde ? <span title={`Cadastrado em ${dia(desde)}, sem pagamento anterior pelo sistema`}><Chip t="Credor novo" c="at" /></span> : null;
}

export function AlertaCredorNovo({ desde }: { desde?: string | null }) {
  if (!desde) return null;
  return <Alerta c="at" t={<><b>Credor novo.</b> Cadastrado em {dia(desde)} e sem pagamento anterior pelo sistema. Confira se o CPF/CNPJ é mesmo do fornecedor antes de aprovar.</>} />;
}
