import { defineConfig, loadEnv } from 'vite'
import react from '@vitejs/plugin-react'

// Carimbo de versao exibido no topo do painel: mostra qual build esta no ar
const build = new Date().toLocaleString('pt-BR', {
  timeZone: 'America/Bahia', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
}) + '.' + Math.random().toString(36).slice(2, 6)  // sufixo distingue deploys no mesmo minuto

// trava do build por ambiente (etapa 17): variável VITE_* do sistema vence o .env, então o banco embutido é
// conferido aqui e o build da homologação nunca sai com a produção (nem o da produção com a homologação)
const BANCO = { homologacao: 'oruwnlxyvznpigbpjjbx', producao: 'zpckrxydqqmmcrphrkxz' } as const

export default defineConfig(({ mode }) => {
  const url = loadEnv(mode, '.', 'VITE_').VITE_SUPABASE_URL ?? ''
  const esperado = BANCO[mode as keyof typeof BANCO]
  if (esperado && !url.includes(`//${esperado}.`))
    throw new Error(`Build "${mode}" com VITE_SUPABASE_URL de outro banco (${url || 'vazia'}). Apague as variáveis VITE_* do serviço de hospedagem.`)
  return {
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
    __APP_VERSION__: JSON.stringify('3.56.0'),
    __APP_BUILD__: JSON.stringify(build),
  },
  }
})
