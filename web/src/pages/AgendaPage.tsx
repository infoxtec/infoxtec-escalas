import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react'
import type { ReactNode } from 'react'
import { AlertCircle, CheckCircle, Clock, Columns3, Flame, Moon, Percent, Plus, RefreshCw, Upload } from 'lucide-react'
import { Button, ErrorBox, Input, Select } from '../components/ui'
import { SortableTh, useColumnWidths, useSortable } from '../components/SortableTh'
import EscalaDrawer from '../components/EscalaDrawer'
import NovaEscalaModal from '../components/NovaEscalaModal'
import SemEscalaPanel from '../components/SemEscalaPanel'
import { api, erroMsg } from '../lib/api'
import {
  addDays, descricaoJornada, ENVIO_LABEL, formatDate, formatDateTime, formatTime, hojeBahia,
  SEMAFORO_CLASSES, SEMAFORO_DOT, STATUS_LABEL,
} from '../lib/types'
import type { EscalaPainel, Local, Resumo, StatusEscala, Tecnico } from '../lib/types'

// Carregado sob demanda: a biblioteca de planilhas e grande
const ImportarEscalas = lazy(() => import('../components/ImportarEscalas'))

const RESPOSTA_LABEL: Record<string, string> = {
  confirmacao: 'Confirmou', problema: 'Problema', motivo: 'Detalhou problema', texto_livre: 'Mensagem',
}

const LARGURAS = { data: 100, hora: 125, tecnico: 190, local: 170, tarefa: 260, status: 140, envio: 120, resposta: 140 }

export default function AgendaPage({ tecnicos, locais, podeEditar }: { tecnicos: Tecnico[]; locais: Local[]; podeEditar: boolean }) {
  const hoje = hojeBahia()
  const [inicio, setInicio] = useState(hoje)
  const [fim, setFim] = useState(addDays(hoje, 7))
  const [escalas, setEscalas] = useState<EscalaPainel[]>([])
  const [resumo, setResumo] = useState<Resumo | null>(null)
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [filtroTecnico, setFiltroTecnico] = useState('')
  const [filtroStatus, setFiltroStatus] = useState('')
  const [selecionada, setSelecionada] = useState<EscalaPainel | null>(null)
  const [nova, setNova] = useState<{ ids?: string[]; data?: string } | null>(null)
  const [importarAberto, setImportarAberto] = useState(false)
  const [versao, setVersao] = useState(0)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try {
      const [e, r] = await Promise.all([api.escalas(inicio, fim), api.resumo(inicio, fim)])
      setEscalas(e); setResumo(r); setVersao(v => v + 1)
      setSelecionada(s => (s ? e.find(x => x.id === s.id) ?? s : s))
    } catch (x) { setErro(erroMsg(x)) }
    finally { setCarregando(false) }
  }, [inicio, fim])

  useEffect(() => { void carregar() }, [carregar])
  // Atualiza sozinho a cada 60s para acompanhar entregas e respostas do WhatsApp
  useEffect(() => { const t = setInterval(() => void carregar(), 60000); return () => clearInterval(t) }, [carregar])

  const tecnicosNaLista = useMemo(() => Array.from(new Set(escalas.map(e => e.tecnico))).sort((a, b) => a.localeCompare(b, 'pt-BR')), [escalas])
  const statusNaLista = useMemo(() => Array.from(new Set(escalas.map(e => e.status))), [escalas])
  const filtradas = useMemo(() => escalas.filter(e =>
    (!filtroTecnico || e.tecnico === filtroTecnico) && (!filtroStatus || e.status === filtroStatus)), [escalas, filtroTecnico, filtroStatus])

  const { sorted, thProps } = useSortable(filtradas, {
    data: e => `${e.data_servico} ${e.hora_inicio}`,
    hora: e => e.hora_inicio,
    tecnico: e => e.tecnico,
    local: e => e.local,
    tarefa: e => e.descricao_tarefa,
    status: e => STATUS_LABEL[e.status] ?? e.status,
    envio: e => e.status_envio,
    resposta: e => e.resposta,
  }, { key: 'data' })
  const { col, total, restaurarTudo } = useColumnWidths('agenda', LARGURAS)
  const th = (k: keyof typeof LARGURAS) => ({ ...thProps(k), ...col(k) })

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-3">
        <div><label className="mb-1 block text-xs text-muted-foreground">De</label>
          <Input type="date" value={inicio} className="w-40" onChange={e => setInicio(e.target.value)} /></div>
        <div><label className="mb-1 block text-xs text-muted-foreground">Até</label>
          <Input type="date" value={fim} className="w-40" onChange={e => setFim(e.target.value)} /></div>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
        <div className="flex-1" />
        {podeEditar && <>
          <Button variant="outline" size="sm" onClick={() => setImportarAberto(true)}><Upload className="h-4 w-4" /> Importar</Button>
          <Button size="sm" onClick={() => setNova({})}><Plus className="h-4 w-4" /> Nova escala</Button>
        </>}
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-5">
        <Kpi icone={<AlertCircle className="h-5 w-5 text-muted-foreground" />} label="Total" valor={resumo?.total} />
        <Kpi icone={<CheckCircle className="h-5 w-5 text-green-600" />} label="Confirmadas" valor={resumo?.confirmadas} cor="text-green-700 dark:text-green-400" />
        <Kpi icone={<Clock className="h-5 w-5 text-amber-600" />} label="Aguardando" valor={resumo?.aguardando} cor="text-amber-700 dark:text-amber-400" />
        <Kpi icone={<Flame className="h-5 w-5 text-red-600" />} label="Críticas" valor={resumo?.criticas} cor="text-red-700 dark:text-red-400" />
        <Kpi icone={<Percent className="h-5 w-5 text-primary" />} label="% Confirmação" valor={resumo ? `${resumo.pct_confirmacao}%` : undefined} cor="text-primary" />
      </div>

      <SemEscalaPanel podeEditar={podeEditar} atualizarEm={versao} onCriar={(ids, data) => setNova({ ids, data })} />

      <div className="flex flex-wrap items-end gap-3">
        <div><label className="mb-1 block text-xs text-muted-foreground">Técnico</label>
          <Select value={filtroTecnico} onChange={e => setFiltroTecnico(e.target.value)}>
            <option value="">Todos</option>{tecnicosNaLista.map(t => <option key={t}>{t}</option>)}
          </Select></div>
        <div><label className="mb-1 block text-xs text-muted-foreground">Status</label>
          <Select value={filtroStatus} onChange={e => setFiltroStatus(e.target.value)}>
            <option value="">Todos</option>{statusNaLista.map(s => <option key={s} value={s}>{STATUS_LABEL[s]}</option>)}
          </Select></div>
        {(filtroTecnico || filtroStatus) && <Button variant="ghost" size="sm" onClick={() => { setFiltroTecnico(''); setFiltroStatus('') }}>Limpar filtros</Button>}
        <div className="flex-1" />
        <Button variant="ghost" size="sm" onClick={restaurarTudo} title="Voltar todas as colunas à largura padrão">
          <Columns3 className="h-3.5 w-3.5" /> Larguras padrão
        </Button>
      </div>

      <div className="overflow-hidden rounded-md border">
        <div className="overflow-x-auto">
          <table className="table-fixed text-sm" style={{ width: total, minWidth: '100%' }}>
            <thead>
              <tr className="border-b bg-muted/50">
                <SortableTh {...th('data')}>Data</SortableTh>
                <SortableTh {...th('hora')}>Horário</SortableTh>
                <SortableTh {...th('tecnico')}>Técnico</SortableTh>
                <SortableTh {...th('local')}>Local</SortableTh>
                <SortableTh {...th('tarefa')}>Tarefa</SortableTh>
                <SortableTh {...th('status')}>Status</SortableTh>
                <SortableTh {...th('envio')}>Envio</SortableTh>
                <SortableTh {...th('resposta')}>Resposta</SortableTh>
              </tr>
            </thead>
            <tbody>
              {carregando && escalas.length === 0 ? (
                <tr><td colSpan={8} className="py-12 text-center text-muted-foreground">Carregando escalas...</td></tr>
              ) : sorted.length === 0 ? (
                <tr><td colSpan={8} className="py-12 text-center text-muted-foreground">Nenhuma escala neste período</td></tr>
              ) : sorted.map(e => {
                const horario = `${formatTime(e.hora_inicio)}${e.hora_fim_prevista ? `–${formatTime(e.hora_fim_prevista)}` : ''}`
                return (
                  <tr key={e.id} onClick={() => setSelecionada(e)} className="cursor-pointer border-b transition-colors last:border-0 hover:bg-muted/40">
                    <td className="truncate px-3 py-2.5 font-mono text-xs">{formatDate(e.data_servico)}</td>
                    <td className="truncate px-3 py-2.5 font-mono text-xs" title={descricaoJornada(e.turno, e.duracao_prevista_min, e.intervalo_min)}>
                      <span className="inline-flex items-center gap-1">
                        {e.turno && e.turno !== 'diurno' && <Moon className="h-3 w-3 shrink-0 text-indigo-500" />}{horario}
                      </span>
                    </td>
                    <td className="truncate px-3 py-2.5" title={e.tecnico}>{e.tecnico}</td>
                    <td className="truncate px-3 py-2.5 text-xs text-muted-foreground" title={e.local}>{e.local}</td>
                    <td className="truncate px-3 py-2.5 text-xs" title={e.descricao_tarefa}>{e.descricao_tarefa}</td>
                    <td className="truncate px-3 py-2.5">
                      <span className={`inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ${SEMAFORO_CLASSES[e.semaforo]}`}>
                        <span className={`h-1.5 w-1.5 rounded-full ${SEMAFORO_DOT[e.semaforo]}`} />{STATUS_LABEL[e.status as StatusEscala] ?? e.status}
                      </span>
                    </td>
                    <td className="truncate px-3 py-2.5 text-xs text-muted-foreground">
                      {e.status_envio ? `${ENVIO_LABEL[e.status_envio] ?? e.status_envio}${e.tentativa ? ` · ${e.tentativa}` : ''}` : '—'}
                    </td>
                    <td className="truncate px-3 py-2.5 text-xs" title={e.respondida_em ? formatDateTime(e.respondida_em) : ''}>
                      {e.resposta ? (RESPOSTA_LABEL[e.resposta] ?? e.resposta) : '—'}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>
      {sorted.length > 0 && <p className="text-right text-xs text-muted-foreground">{sorted.length} escala{sorted.length !== 1 ? 's' : ''} · arraste a borda dos títulos para alargar as colunas · atualiza sozinho a cada minuto</p>}

      <EscalaDrawer escala={selecionada} open={!!selecionada} onClose={() => setSelecionada(null)} onRefresh={() => void carregar()} podeEditar={podeEditar} />
      <NovaEscalaModal open={!!nova} onClose={() => setNova(null)} onSuccess={() => void carregar()}
        tecnicos={tecnicos} locais={locais} inicialIds={nova?.ids} inicialData={nova?.data} />
      {importarAberto && (
        <Suspense fallback={null}>
          <ImportarEscalas open={importarAberto} onClose={() => setImportarAberto(false)} onSuccess={() => void carregar()} tecnicos={tecnicos} locais={locais} />
        </Suspense>
      )}
    </div>
  )
}

function Kpi({ icone, label, valor, cor = 'text-foreground' }: { icone: ReactNode; label: string; valor?: number | string; cor?: string }) {
  return (
    <div className="flex items-start gap-3 rounded-lg border bg-card p-3">
      <div className="mt-0.5 shrink-0">{icone}</div>
      <div><p className="text-xs text-muted-foreground">{label}</p><p className={`mt-0.5 text-2xl font-bold ${cor}`}>{valor ?? '…'}</p></div>
    </div>
  )
}
