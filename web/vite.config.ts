import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Carimbo de versao exibido no topo do painel: mostra qual build esta no ar
const build = new Date().toLocaleString('pt-BR', {
  timeZone: 'America/Bahia', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
}) + '.' + Math.random().toString(36).slice(2, 6)  // sufixo distingue deploys no mesmo minuto

export default defineConfig({
  plugins: [
    react(),
    {
      // marca da publicacao: o painel aberto compara com a sua e recarrega sozinho
      name: 'versao-publicada',
      generateBundle() {
        this.emitFile({ type: 'asset', fileName: 'version.json', source: JSON.stringify({ build }) })
      },
    },
  ],
  define: {
    __APP_VERSION__: JSON.stringify('2.0'),
    __APP_BUILD__: JSON.stringify(build),
  },
})
