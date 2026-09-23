import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Carimbo de versao exibido no topo do painel: mostra qual build esta no ar
const build = new Date().toLocaleString('pt-BR', {
  timeZone: 'America/Bahia', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
})

export default defineConfig({
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify('1.4'),
    __APP_BUILD__: JSON.stringify(build),
  },
})
