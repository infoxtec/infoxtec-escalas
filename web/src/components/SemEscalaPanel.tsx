import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, ChevronDown, ChevronUp, Clock, Plus, UserX } from 'lucide-react'
import { Button, Input } from './ui'
import { api, erroMsg } from '../lib/api'
import { addDays, formatDate, hojeBahia } from '../lib/types'
import type { Pendencias } from '../lib/types'

type Dia = 'hoje' | 'amanha' | 'outro'

function agoraBahia(): string {
  return new Date().toLocaleTimeString('en-GB', { timeZone: 'America/Bahia', hour: '2-digit', minute: '2-digit' })
}

/** Tecnicos ativos sem nenhuma escala no dia (canceladas nao contam). */
export default function SemEscalaPanel({ podeEditar, onCriar, atualizarEm }: {
  podeEditar: boolean
  onCriar: (ids: string[], data: string) => void
  atualizarEm: number
}) {
  const hoje = hojeBahia()
  const amanha = addDays(hoje, 1)
  // Depois do meio-dia o foco natural e a escala de amanha
  const [dia, setDia] = useState<Dia>(agoraBahia() >= '12:00' ? 'amanha' : 'hoje')
  const [outra, setOutra] = useState(addDays(hoje, 2))
  const [p, setP] = useState<Pendencias | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [aberto, setAberto] = useState(true)

  const data = dia === 'hoje' ? hoje : dia === 'amanha' ? amanha : outra

  const carregar = useCallback(async () => {
    try { setP(await api.pendencias(data)); setErro(null) } catch (e) { setErro(erroMsg(e)) }
  }, [data])
  useEffect(() => { void carregar() }, [carregar, atualizarEm])

  const qtd = p?.sem_escala.length ?? 0
  const pendente = qtd > 0 || (p?.rascunhos ?? 0) > 0
  const prazo = p?.prazo ?? '18:00'
  const prazoPassou = agoraBahia() >= prazo

  let selo: { texto: string; classe: string; icone: JSX.Element } | null = null
  if (p && dia === 'amanha' && p.exige_escala) {
    if (!pendente) selo = { texto: 'Escala de amanhã completa', classe: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300', icone: <CheckCircle2 className="h-3.5 w-3.5" /> }
    else if (prazoPassou) selo = { texto: `Prazo das ${prazo} encerrado`, classe: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300', icone: <AlertTriangle className="h-3.5 w-3.5" /> }
    else selo = { texto: `Enviar até ${prazo}`, classe: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300', icone: <Clock className="h-3.5 w-3.5" /> }
  }

  const botaoDia = (d: Dia, rotulo: string) => (
    <button type="button" onClick={() => setDia(d)}
      className={`rounded px-2.5 py-1 text-xs font-medium ${dia === d ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
      {rotulo}
    </button>
  )

  return (
    <div className="rounded-lg border bg-card">
      <div className="flex flex-wrap items-center gap-3 px-4 py-3">
        <div className="flex items-center gap-2">
          <UserX className="h-4 w-4 text-muted-foreground" />
          <span className="text-sm font-semibold">Técnicos sem escala</span>
          {p && <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${qtd > 0 ? 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300' : 'bg-muted text-muted-foreground'}`}>{qtd} de {p.total_tecnicos}</span>}
        </div>
        <div className="flex items-center gap-1 rounded-md border p-0.5">
          {botaoDia('hoje', 'Hoje')}
          {botaoDia('amanha', 'Amanhã')}
          {botaoDia('outro', 'Outro dia')}
        </div>
        {dia === 'outro' && <Input type="date" value={outra} onChange={e => setOutra(e.target.value)} className="h-8 w-40" />}
        <span className="text-xs text-muted-foreground">{formatDate(data)}</span>
        {selo && <span className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${selo.classe}`}>{selo.icone}{selo.texto}</span>}
        <div className="flex-1" />
        <button type="button" onClick={() => setAberto(a => !a)} className="rounded p-1 text-muted-foreground hover:bg-muted" aria-label={aberto ? 'Recolher' : 'Expandir'}>
          {aberto ? <ChevronUp className="h-4 w-4" /> : <ChevronDown className="h-4 w-4" />}
        </button>
      </div>

      {aberto && (
        <div className="space-y-3 border-t px-4 py-3">
          {erro && <p className="text-sm text-destructive">{erro}</p>}
          {p && !p.exige_escala && <p className="text-xs text-muted-foreground">Este dia não exige escala pela configuração atual (dias úteis).</p>}
          {p && qtd === 0 && <p className="text-sm text-green-700 dark:text-green-400">Todos os técnicos ativos têm escala neste dia.</p>}
          {p && qtd > 0 && (
            <div className="flex flex-wrap gap-2">
              {p.sem_escala.map(t => (
                <button key={t.id} type="button" disabled={!podeEditar} onClick={() => onCriar([t.id], data)}
                  title={podeEditar ? 'Criar escala para este técnico' : t.funcao}
                  className="inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-xs hover:bg-muted disabled:cursor-default disabled:hover:bg-transparent">
                  {podeEditar && <Plus className="h-3 w-3 text-primary" />}
                  <span className="font-medium">{t.nome}</span>
                  <span className="text-muted-foreground">· {t.funcao}</span>
                </button>
              ))}
            </div>
          )}
          {p && p.rascunhos > 0 && (
            <p className="text-xs text-amber-700 dark:text-amber-400">{p.rascunhos} escala(s) em rascunho neste dia — ainda não foram enviadas. Libere pelo painel da escala.</p>
          )}
          {podeEditar && qtd > 1 && (
            <Button size="sm" variant="outline" onClick={() => onCriar(p!.sem_escala.map(t => t.id), data)}>
              <Plus className="h-3.5 w-3.5" /> Criar escala para os {qtd}
            </Button>
          )}
        </div>
      )}
    </div>
  )
}
