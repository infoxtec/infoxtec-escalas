import { useCallback, useEffect, useState } from 'react'
import { ExternalLink, Mail, RefreshCw } from 'lucide-react'
import { Button, Input, useToast } from './ui'
import { api, erroMsg } from '../lib/api'

// Alertas da plataforma no Checklist Sistema (só a plataforma vê): queda do WhatsApp por e-mail (migration 135) e o
// monitor externo do healthchecks.io (migration 136), que avisa quando o Supabase ou o motor param.
export default function AlertasPlataforma() {
  const toast = useToast()
  const [alertas, setAlertas] = useState<Awaited<ReturnType<typeof api.plataformaAlertas>> | null>(null)
  const [monitor, setMonitor] = useState<{ ligado: boolean; final: string | null } | null>(null)
  const [testando, setTestando] = useState(false)
  const [pingUrl, setPingUrl] = useState('')

  const carregar = useCallback(async () => {
    api.plataformaAlertas().then(setAlertas).catch(() => setAlertas(null))
    api.plataformaMonitor().then(setMonitor).catch(() => setMonitor(null))
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const testarAlerta = async () => {
    setTestando(true)
    try { await api.plataformaTestarAlerta(); toast('Teste enviado. Confira a caixa em 1 a 2 minutos e clique em Atualizar.') }
    catch (e) { toast(erroMsg(e)) }
    finally { setTestando(false) }
  }
  const salvarMonitor = async (url: string) => {
    try { await api.plataformaSalvarMonitor(url); setPingUrl(''); toast(url ? 'Monitor externo ligado.' : 'Monitor externo desligado.'); await carregar() }
    catch (e) { toast(erroMsg(e)) }
  }
  const quando = (t: string | null) => t ? new Date(t).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—'

  if (!alertas && !monitor) return null
  return (
    <div className="space-y-3 rounded-md border p-3 text-xs">
      <div className="flex items-center justify-between">
        <p className="text-sm font-semibold">Alertas da plataforma</p>
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>

      {alertas && (
        <div className="space-y-1">
          <div className="flex items-center justify-between">
            <p className="font-medium text-foreground">Queda do WhatsApp por e-mail</p>
            <Button variant="outline" size="sm" onClick={() => void testarAlerta()} disabled={testando}><Mail className="h-3.5 w-3.5" /> Testar e-mail</Button>
          </div>
          <p className="text-muted-foreground">
            {alertas.vigia
              ? <>Última verificação {quando(alertas.vigia.verificado_em)}: <strong className={alertas.vigia.estado === 'open' ? 'text-green-700' : 'text-amber-600'}>{alertas.vigia.estado === 'open' ? 'conectado' : alertas.vigia.estado ?? 'aguardando'}</strong>{alertas.vigia.fora_desde && <> · fora desde {quando(alertas.vigia.fora_desde)}</>}</>
              : 'O vigia ainda não rodou (roda a cada 5 minutos).'}
          </p>
          {alertas.alertas.map((a, i) => (
            <p key={i} className="text-muted-foreground">{quando(a.criado_em)} · {a.assunto} · {a.enviado_em ? <span className="text-green-700">enviado</span> : a.erro ? <span className="text-amber-600">não enviado: {a.erro}</span> : 'na fila'}</p>
          ))}
        </div>
      )}

      {monitor && (
        <div className="space-y-1 border-t pt-2">
          <p className="font-medium text-foreground">Monitor externo: {monitor.ligado ? <span className="text-green-700">ligado (endereço terminado em …{monitor.final})</span> : <span className="text-amber-600">desligado</span>}</p>
          <p className="text-muted-foreground">
            Avisa por e-mail quando o Supabase ou o motor param. Crie o check em{' '}
            <a href="https://healthchecks.io/projects/" target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-0.5 text-primary underline">
              healthchecks.io <ExternalLink className="h-3 w-3" />
            </a>{' '}
            e cole aqui o endereço de ping (https://hc-ping.com/...). Por segurança, o endereço salvo não volta à tela.
          </p>
          <div className="flex gap-2">
            <Input value={pingUrl} onChange={e => setPingUrl(e.target.value)} placeholder="https://hc-ping.com/..." className="h-8 text-xs" />
            <Button size="sm" onClick={() => void salvarMonitor(pingUrl.trim())} disabled={!pingUrl.trim()}>Salvar</Button>
            {monitor.ligado && <Button variant="outline" size="sm" onClick={() => void salvarMonitor('')}>Desligar</Button>}
          </div>
        </div>
      )}
    </div>
  )
}
