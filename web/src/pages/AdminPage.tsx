import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, ExternalLink, Info, Loader2, RefreshCw, XCircle, Zap } from 'lucide-react'
import { Button, ErrorBox } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import type { ChecklistSaude, EstadoSaude, ItemSaude } from '../lib/types'

// Administração do Sistema. Hoje com uma seção só (Checklist); as próximas entram em SECOES.
const SECOES = [{ id: 'checklist', label: 'Checklist' }] as const
type Secao = typeof SECOES[number]['id']

export default function AdminPage() {
  const [secao, setSecao] = useState<Secao>('checklist')
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <h1 className="text-lg font-semibold">Administração do Sistema</h1>
        <span className="text-muted-foreground">›</span>
        <div className="flex gap-1">
          {SECOES.map(s => (
            <button key={s.id} onClick={() => setSecao(s.id)}
              className={`rounded-md px-2.5 py-1 text-sm ${secao === s.id ? 'bg-muted font-medium' : 'text-muted-foreground hover:bg-muted'}`}>
              {s.label}
            </button>
          ))}
        </div>
      </div>
      {secao === 'checklist' && <Checklist />}
    </div>
  )
}

// Páginas públicas de status (Atlassian Statuspage), lidas pelo navegador: nenhuma chave envolvida
const STATUS_EXTERNOS = [
  { grupo: 'Supabase', nome: 'Status do Supabase', api: 'https://status.supabase.com/api/v2/status.json', site: 'https://status.supabase.com' },
  { grupo: 'Twilio (ligações)', nome: 'Status da Twilio', api: 'https://status.twilio.com/api/v2/status.json', site: 'https://status.twilio.com' },
  { grupo: 'GitHub', nome: 'Status do GitHub', api: 'https://www.githubstatus.com/api/v2/status.json', site: 'https://www.githubstatus.com' },
  { grupo: 'Vercel', nome: 'Status da Vercel', api: 'https://www.vercel-status.com/api/v2/status.json', site: 'https://www.vercel-status.com' },
]
const REPO = 'https://github.com/infoxtec/infoxtec-escalas'

async function lerStatus(url: string): Promise<{ estado: EstadoSaude; detalhe: string }> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(8000) })
    const j = await r.json()
    const ind: string = j?.status?.indicator ?? 'unknown'
    const desc: string = j?.status?.description ?? ''
    const estado: EstadoSaude = ind === 'none' ? 'ok' : ind === 'minor' ? 'atencao' : ind === 'unknown' ? 'info' : 'falha'
    return { estado, detalhe: ind === 'none' ? 'Todos os sistemas operando.' : desc || 'Situação desconhecida.' }
  } catch {
    return { estado: 'info', detalhe: 'Não foi possível consultar a página de status agora.' }
  }
}

async function lerEvolution(base: string): Promise<{ estado: EstadoSaude; detalhe: string }> {
  try {
    const r = await fetch(base.replace(/\/+$/, '') + '/', { signal: AbortSignal.timeout(8000) })
    const j = await r.json().catch(() => ({}))
    return r.ok
      ? { estado: 'ok', detalhe: `Servidor respondendo${j?.version ? ` (versão ${j.version})` : ''}.` }
      : { estado: 'falha', detalhe: `Servidor respondeu HTTP ${r.status}.` }
  } catch {
    return { estado: 'falha', detalhe: 'Servidor não respondeu ao navegador (fora do ar ou bloqueado).' }
  }
}

function Checklist() {
  const [dados, setDados] = useState<ChecklistSaude | null>(null)
  const [externos, setExternos] = useState<ItemSaude[]>([])
  const [carregando, setCarregando] = useState(false)
  const [testando, setTestando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try {
      const d = await api.checklistSaude()
      setDados(d)
      const lidos = await Promise.all(STATUS_EXTERNOS.map(async s => ({ grupo: s.grupo, item: s.nome, ...(await lerStatus(s.api)) })))
      const extras: ItemSaude[] = [
        ...(d.evolution_url ? [{ grupo: 'Evolution (WhatsApp)', item: 'Servidor (visto pelo navegador)', ...(await lerEvolution(d.evolution_url)) }] : []),
        ...lidos,
        { grupo: 'Vercel', item: 'Painel publicado', estado: 'ok', detalhe: `Esta página está no ar: versão ${__APP_VERSION__}, build ${__APP_BUILD__}.` },
        { grupo: 'GitHub', item: 'CI e backup diário', estado: 'info', detalhe: 'O repositório é privado: confira as execuções no GitHub Actions (link ao lado).' },
      ]
      setExternos(extras)
    } catch (e) { setErro(erroMsg(e)) } finally { setCarregando(false) }
  }, [])

  useEffect(() => { void carregar() }, [carregar])

  const testar = async () => {
    setTestando(true)
    try {
      const r = await api.checklistTestar()
      if (r.erro) setErro(r.erro)
      await new Promise(ok => setTimeout(ok, 4000))   // o pg_net responde em segundo plano
      await carregar()
    } catch (e) { setErro(erroMsg(e)) } finally { setTestando(false) }
  }

  const itens = [...(dados?.itens ?? []), ...externos]
  const grupos = ['Supabase', 'Evolution (WhatsApp)', 'Erros em tabelas', 'Twilio (ligações)', 'GitHub', 'Vercel']
  const contagem = (e: EstadoSaude) => itens.filter(i => i.estado === e).length

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Resumo estado="ok" n={contagem('ok')} rotulo="ok" />
        <Resumo estado="atencao" n={contagem('atencao')} rotulo="atenção" />
        <Resumo estado="falha" n={contagem('falha')} rotulo="falha" />
        <div className="flex-1" />
        {dados && <span className="text-xs text-muted-foreground">Atualizado às {new Date(dados.gerado_em).toLocaleTimeString('pt-BR')}</span>}
        <Button variant="outline" size="sm" onClick={testar} disabled={testando || carregando}>
          {testando ? <Loader2 className="h-4 w-4 animate-spin" /> : <Zap className="h-4 w-4" />} Testar Evolution agora
        </Button>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          {carregando ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Atualizar
        </Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!dados && carregando && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {grupos.map(g => {
          const doGrupo = itens.filter(i => i.grupo === g)
          if (!doGrupo.length) return null
          return (
            <section key={g} className="rounded-lg border bg-card">
              <header className="flex items-center justify-between border-b px-4 py-2">
                <h2 className="text-sm font-semibold">{g}</h2>
                {g === 'GitHub' && <a href={`${REPO}/actions`} target="_blank" rel="noreferrer" className="flex items-center gap-1 text-xs text-primary hover:underline">Actions <ExternalLink className="h-3 w-3" /></a>}
              </header>
              <ul className="divide-y">
                {doGrupo.map(i => (
                  <li key={i.item} className="flex gap-3 px-4 py-2.5">
                    <Icone estado={i.estado} />
                    <div className="min-w-0">
                      <p className="text-sm font-medium">{i.item}</p>
                      <p className="break-words text-xs text-muted-foreground">{i.detalhe}</p>
                    </div>
                  </li>
                ))}
              </ul>
            </section>
          )
        })}
      </div>
    </div>
  )
}

function Icone({ estado }: { estado: EstadoSaude }) {
  if (estado === 'ok') return <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0 text-emerald-600" />
  if (estado === 'atencao') return <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-amber-500" />
  if (estado === 'falha') return <XCircle className="mt-0.5 h-4 w-4 shrink-0 text-red-600" />
  return <Info className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
}

function Resumo({ estado, n, rotulo }: { estado: EstadoSaude; n: number; rotulo: string }) {
  return (
    <span className="flex items-center gap-1.5 rounded-md border px-2.5 py-1 text-sm">
      <Icone estado={estado} /><strong>{n}</strong> {rotulo}
    </span>
  )
}
