import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, Clock, ExternalLink, MapPin, RefreshCw, XCircle } from 'lucide-react'
import { Button, ErrorBox, Input } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import { addDays, formatDate, hojeBahia, SEMAFORO_CLASSES, STATUS_LABEL } from '../lib/types'
import type { EstadoMotor, PainelLocal, StatusEscala } from '../lib/types'

const STATUS_CLASSE: Record<string, string> = {
  confirmada: SEMAFORO_CLASSES.verde, em_execucao: SEMAFORO_CLASSES.verde, concluida: SEMAFORO_CLASSES.verde,
  recusada: SEMAFORO_CLASSES.vermelho, cancelada: SEMAFORO_CLASSES.vermelho,
  notificada: SEMAFORO_CLASSES.ambar, agendada: SEMAFORO_CLASSES.cinza, rascunho: SEMAFORO_CLASSES.cinza,
  reagendada: SEMAFORO_CLASSES.ambar,
}

function Barra({ pct, cor }: { pct: number; cor: string }) {
  return (
    <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
      <div className={`h-full rounded-full ${cor}`} style={{ width: `${Math.max(0, Math.min(100, pct))}%` }} />
    </div>
  )
}

/** Situação do motor de envio: em dia, parado ou não agendado neste ambiente (migration 44). */
function QuadroMotor({ m }: { m: EstadoMotor }) {
  const hora = new Date(m.ultima_execucao_ok).toLocaleTimeString('pt-BR', { timeZone: 'America/Bahia', hour: '2-digit', minute: '2-digit' })
  const [classe, icone, texto] = !m.motor_agendado
    ? ['border-muted bg-muted/40 text-muted-foreground', <Clock key="i" className="h-4 w-4" />,
       'Motor de envio não agendado neste ambiente (normal na homologação).']
    : m.em_dia
      ? ['border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/30 dark:text-green-300', <CheckCircle2 key="i" className="h-4 w-4" />,
         `Motor de envio em dia · última execução às ${hora}.`]
      : ['border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950/30 dark:text-red-300', <XCircle key="i" className="h-4 w-4" />,
         `Motor de envio parado há ${m.minutos} min (última execução às ${hora}). Escalas não estão saindo. ${m.alerta_ativo ? 'Supervisores avisados.' : 'Supervisores serão avisados.'}`]
  return (
    <div className={`flex flex-wrap items-center gap-2 rounded-lg border px-3 py-2 text-sm ${classe}`}>
      {icone}<span>{texto}</span>
      {m.motor_agendado && !m.vigia_agendado && (
        <span className="text-xs">Vigia não agendado: rode a linha "vigia-motor" de supabase/setup/cron.sql.</span>
      )}
    </div>
  )
}

/** Item 3: acompanhamento do dia agrupado por local. */
export default function OperacaoPage() {
  const [data, setData] = useState(hojeBahia())
  const [locais, setLocais] = useState<PainelLocal[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [motor, setMotor] = useState<EstadoMotor | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    api.estadoMotor().then(setMotor).catch(() => setMotor(null))
    try { setLocais(await api.painelLocais(data)) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [data])

  useEffect(() => { void carregar() }, [carregar])
  useEffect(() => { const t = setInterval(() => void carregar(), 60000); return () => clearInterval(t) }, [carregar])

  const somar = (campo: keyof PainelLocal) => locais.reduce((s, l) => s + (l[campo] as number), 0)
  const total = somar('total')
  const confirmadas = somar('confirmadas')
  const concluidas = somar('concluidas')

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <div><label className="mb-1 block text-xs text-muted-foreground">Dia</label>
          <Input type="date" value={data} className="w-40" onChange={e => setData(e.target.value)} /></div>
        <div className="flex gap-1">
          <Button variant="outline" size="sm" onClick={() => setData(hojeBahia())}>Hoje</Button>
          <Button variant="outline" size="sm" onClick={() => setData(addDays(hojeBahia(), 1))}>Amanhã</Button>
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
        <div className="flex-1" />
        <p className="text-xs text-muted-foreground">{formatDate(data)} · atualiza sozinho a cada minuto</p>
      </div>

      {motor && <QuadroMotor m={motor} />}

      {erro && <ErrorBox>{erro}</ErrorBox>}

      {total > 0 && (
        <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
          <div className="rounded-lg border bg-card p-3">
            <p className="text-xs text-muted-foreground">Locais</p>
            <p className="mt-0.5 text-2xl font-bold">{locais.length}</p>
          </div>
          <div className="rounded-lg border bg-card p-3">
            <p className="text-xs text-muted-foreground">Escalas no dia</p>
            <p className="mt-0.5 text-2xl font-bold">{total}</p>
          </div>
          <div className="rounded-lg border bg-card p-3">
            <p className="text-xs text-muted-foreground">Aceite</p>
            <p className="mt-0.5 text-2xl font-bold text-green-700 dark:text-green-400">{Math.round(100 * confirmadas / total)}%</p>
            <Barra pct={100 * confirmadas / total} cor="bg-green-500" />
          </div>
          <div className="rounded-lg border bg-card p-3">
            <p className="text-xs text-muted-foreground">Concluído</p>
            <p className="mt-0.5 text-2xl font-bold text-primary">{Math.round(100 * concluidas / total)}%</p>
            <Barra pct={100 * concluidas / total} cor="bg-primary" />
          </div>
        </div>
      )}

      {locais.length === 0 && !carregando && (
        <div className="rounded-lg border bg-card py-12 text-center text-muted-foreground">Nenhuma escala neste dia</div>
      )}

      <div className="grid gap-3 xl:grid-cols-2">
        {locais.map(l => (
          <div key={l.local_id ?? l.local} className="rounded-lg border bg-card">
            <div className="flex flex-wrap items-start gap-3 border-b px-4 py-3">
              <MapPin className="mt-0.5 h-4 w-4 shrink-0 text-muted-foreground" />
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-semibold">{l.local}</span>
                  {l.primeira_hora && <span className="text-xs text-muted-foreground">a partir das {l.primeira_hora}</span>}
                  {l.criticas > 0 && (
                    <span className="inline-flex items-center gap-1 rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-900/30 dark:text-red-300">
                      <AlertTriangle className="h-3 w-3" />{l.criticas} crítica(s)
                    </span>
                  )}
                </div>
                {l.endereco && <p className="truncate text-xs text-muted-foreground">{l.endereco}</p>}
              </div>
              {l.link_maps && (
                <a href={l.link_maps} target="_blank" rel="noopener noreferrer" className="text-primary" title="Ver no mapa">
                  <ExternalLink className="h-4 w-4" />
                </a>
              )}
            </div>

            <div className="space-y-2 px-4 py-3">
              <div className="flex items-center gap-3 text-xs">
                <span className="w-16 shrink-0 text-muted-foreground">Aceite</span>
                <Barra pct={l.pct_aceite} cor="bg-green-500" />
                <span className="w-10 shrink-0 text-right font-medium">{l.pct_aceite}%</span>
              </div>
              <div className="flex items-center gap-3 text-xs">
                <span className="w-16 shrink-0 text-muted-foreground">Concluído</span>
                <Barra pct={l.pct_conclusao} cor="bg-primary" />
                <span className="w-10 shrink-0 text-right font-medium">{l.pct_conclusao}%</span>
              </div>
              <p className="pt-1 text-xs text-muted-foreground">
                {l.total} escala(s) · {l.confirmadas} aceita(s) · {l.aguardando} aguardando
                {l.recusadas > 0 && ` · ${l.recusadas} recusada(s)`}
              </p>
            </div>

            <ul className="divide-y border-t">
              {l.tecnicos.map(t => (
                <li key={t.escala_id} className="flex items-center gap-3 px-4 py-2 text-sm">
                  <span className="w-24 shrink-0 font-mono text-xs text-muted-foreground">
                    {t.hora}{t.fim ? `–${t.fim}` : ''}
                  </span>
                  <span className="min-w-0 flex-1 truncate" title={t.tarefa}>
                    <span className="font-medium">{t.tecnico}</span>
                    {t.tipo && <span className="text-xs text-muted-foreground"> · {t.tipo}</span>}
                  </span>
                  <span className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_CLASSE[t.status] ?? ''}`}>
                    {t.status === 'concluida' && <CheckCircle2 className="mr-1 inline h-3 w-3" />}
                    {t.status === 'recusada' && <XCircle className="mr-1 inline h-3 w-3" />}
                    {(t.status === 'notificada' || t.status === 'agendada') && <Clock className="mr-1 inline h-3 w-3" />}
                    {STATUS_LABEL[t.status as StatusEscala] ?? t.status}
                  </span>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>

      <p className="text-xs text-muted-foreground">
        O percentual de <strong>conclusão</strong> considera escalas marcadas como concluídas no painel.
        Quando o checklist pelo WhatsApp existir (item 1 do backlog), ele passa a alimentar esse número sozinho.
      </p>
    </div>
  )
}
