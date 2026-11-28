import { Navigate, Route, Routes } from 'react-router-dom';
import { useSessao } from './lib/sessao';
import { configurado, mensagemErro } from './lib/supabase';
import { CHAVE_RECUSADA } from './lib/config';
import { Entrar, SemCadastro } from './pages/Entrar';
import { Moldura } from './components/Moldura';
import { Titulos } from './pages/Titulos';
import { Aprovar } from './pages/Aprovar';
import { Previsoes } from './pages/Previsoes';
import { Contratos } from './pages/Contratos';
import { ContasPagar } from './pages/ContasPagar';
import { Empresas } from './pages/Empresas';
import { Centros } from './pages/Centros';

export function App() {
  const { sessao, carregando, eu, euCarregando, euErro } = useSessao();
  if (CHAVE_RECUSADA) return <Aviso texto="A chave configurada no servidor não é a publicável. O sistema não abre com ela: avise o TI." />;
  if (!configurado) return <Aviso texto="Falta configurar o endereço e a chave do Supabase (SUPABASE_URL e SUPABASE_KEY)." />;
  if (carregando) return <Aviso texto="Carregando…" />;
  if (!sessao) return <Entrar />;
  if (euCarregando) return <Aviso texto="Carregando…" />;
  if (euErro) return <Aviso texto={mensagemErro(euErro)} />;
  if (!eu) return <SemCadastro />;
  return (
    <Moldura>
      <Routes>
        <Route path="/" element={<Navigate to="/contas-a-pagar" replace />} />
        <Route path="/contas-a-pagar" element={<ContasPagar />} />
        <Route path="/aprovar/:id?" element={<Aprovar />} />
        <Route path="/titulos/:id?" element={<Titulos />} />
        <Route path="/previsoes/:id?" element={<Previsoes />} />
        <Route path="/contratos/:id?" element={<Contratos />} />
        <Route path="/empresas/:id?" element={<Empresas />} />
        <Route path="/centros/:id?" element={<Centros />} />
        <Route path="*" element={<Navigate to="/contas-a-pagar" replace />} />
      </Routes>
    </Moldura>
  );
}

function Aviso({ texto }: { texto: string }) {
  return <div className="m-auth"><div className="m-auth-card"><p className="sec">{texto}</p></div></div>;
}
