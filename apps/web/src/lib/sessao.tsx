// Sessão do login (como o BKM Terrenos, lib/sessao.tsx) e o cadastro da pessoa no ERP (api.eu).
import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { useQuery } from '@tanstack/react-query';
import { rpc, supabase } from './supabase';
import type { Eu } from './tipos';

interface Ctx { sessao: Session | null; carregando: boolean; eu: Eu | null; euCarregando: boolean; euErro: unknown; sair: () => Promise<void> }
const SessaoCtx = createContext<Ctx>({ sessao: null, carregando: true, eu: null, euCarregando: false, euErro: null, sair: async () => {} });

export function SessaoProvider({ children }: { children: ReactNode }) {
  const [sessao, setSessao] = useState<Session | null>(null);
  const [carregando, setCarregando] = useState(true);
  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => { setSessao(data.session); setCarregando(false); });
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSessao(s));
    return () => data.subscription.unsubscribe();
  }, []);
  const uid = sessao?.user.id;
  const eu = useQuery({ queryKey: ['eu', uid], queryFn: () => rpc<Eu | null>('eu'), enabled: Boolean(uid) });
  const sair = async () => { await supabase.auth.signOut(); };
  return (
    <SessaoCtx.Provider value={{ sessao, carregando, eu: eu.data ?? null, euCarregando: eu.isLoading, euErro: eu.error, sair }}>
      {children}
    </SessaoCtx.Provider>
  );
}

export const useSessao = () => useContext(SessaoCtx);
