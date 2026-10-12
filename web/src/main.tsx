import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import PontoApp from './ponto/PontoApp'
import VerificarEspelho from './verificar/VerificarEspelho'
import { ToastProvider } from './components/ui'
import './index.css'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <ToastProvider>
      {window.location.pathname.startsWith('/ponto') ? <PontoApp />
        : window.location.pathname.replace(/\/$/, '') === '/v' ? <VerificarEspelho />
        : <App />}
    </ToastProvider>
  </React.StrictMode>,
)
