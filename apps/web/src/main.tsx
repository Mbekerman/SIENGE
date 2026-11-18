import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SessaoProvider } from './lib/sessao';
import { App } from './App';
import './styles.css';
import './app.css';

const qc = new QueryClient({ defaultOptions: { queries: { staleTime: 30_000, retry: 1, refetchOnWindowFocus: true } } });

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <QueryClientProvider client={qc}>
      <BrowserRouter basename={import.meta.env.BASE_URL}>
        <SessaoProvider>
          <App />
        </SessaoProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>,
);
