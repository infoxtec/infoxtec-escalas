import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, ExternalLink, Info, Loader2, RefreshCw, XCircle } from 'lucide-react'
import { Button, ErrorBox } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import type { ChecklistSaude, EstadoSaude, ItemSaude } from '../lib/types'

// Checklist Sistema. Hoje com uma seção só (Checklist); as próximas entram em SECOES.
const SECOES = [{ id: 'checklist', label: 'Checklist' }] as const
type Secao = typeof SECOES[number]['id']

export default function AdminPage() {
  const [secao, setSecao] = useState<Secao>('checklist')
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2">
        <h1 className="text-lg font-semibold">Checklist Sistema</h1>
        {SECOES.length > 1 && <span className="text-muted-foreground">›</span>}
        {SECOES.length > 1 && <div className="flex gap-1">
          {SECOES.map(s => (
            <button key={s.id} onClick={() => setSecao(s.id)}
              className={`rounded-md px-2.5 py-1 text-sm ${secao === s.id ? 'bg-muted font-medium' : 'text-muted-foreground hover:bg-muted'}`}>
              {s.label}
            </button>
          ))}
        </div>}
      </div>
      {secao === 'checklist' && <Checklist />}
    </div>
  )
}

const REPO = 'https://github.com/infoxtec/infoxtec-escalas'
const GRUPOS = ['Supabase', 'Evolution (WhatsApp)', 'Erros em tabelas', 'Twilio (ligações)', 'GitHub', 'Vercel']
const espera = (ms: number) => new Promise(ok => setTimeout(ok, ms))

// Toda verificação é feita pelo banco (app_checklist_saude); a tela só desenha a lista.
function Checklist() {
  const [dados, setDados] = useState<ChecklistSaude | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    try { setDados(await api.checklistSaude()) } catch (e) { setErro(erroMsg(e)) }
  }, [])

  // "Testar agora": o banco enfileira as consultas externas; as respostas chegam em segundos
  const testar = useCallback(async () => {
    setOcupado(true); setErro(null)
    try {
      const r = await api.checklistTestar()
      if (r.erro) setErro(r.erro)
      await espera(4000)
      await carregar()
    } catch (e) { setErro(erroMsg(e)) } finally { setOcupado(false) }
  }, [carregar])

  useEffect(() => { void carregar().then(testar) }, [carregar, testar])

  const itens: ItemSaude[] = [
    ...(dados?.itens ?? []),
    { grupo: 'Vercel', item: 'Painel publicado', estado: 'ok', detalhe: `Esta página está no ar: versão ${__APP_VERSION__}, build ${__APP_BUILD__}.` },
    { grupo: 'GitHub', item: 'CI e backup diário', estado: 'info', detalhe: 'O repositório é privado: confira as execuções no GitHub Actions (link ao lado).' },
  ]
  const contagem = (e: EstadoSaude) => itens.filter(i => i.estado === e).length

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-2">
        <Resumo estado="ok" n={contagem('ok')} rotulo="ok" />
        <Resumo estado="atencao" n={contagem('atencao')} rotulo="atenção" />
        <Resumo estado="falha" n={contagem('falha')} rotulo="falha" />
        <div className="flex-1" />
        {dados && <span className="text-xs text-muted-foreground">Atualizado às {new Date(dados.gerado_em).toLocaleTimeString('pt-BR')}</span>}
        <Button variant="outline" size="sm" onClick={() => void testar()} disabled={ocupado}>
          {ocupado ? <Loader2 className="h-4 w-4 animate-spin" /> : <RefreshCw className="h-4 w-4" />} Testar agora
        </Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!dados && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>}
      <div className="grid gap-4 lg:grid-cols-2">
        {GRUPOS.map(g => {
          const doGrupo = itens.filter(i => i.grupo === g)
          if (!dados || !doGrupo.length) return null
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
