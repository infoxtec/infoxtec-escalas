import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Ban, Building2, CheckCircle2, Clock, Edit2, KanbanSquare, List, Plus, RefreshCw, Rocket, ShieldAlert, Wrench } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, Select, Textarea, useToast } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import Kanban from '../components/Kanban'
import { ESFORCO_LABEL, GRUPO_BACKLOG, STATUS_BACKLOG, formatDate, grupoDe, numeroBacklog } from '../lib/types'
import type { ColunaKanban, ItemBacklog, StatusBacklog } from '../lib/types'

const ICONE: Record<StatusBacklog, JSX.Element> = {
  concluido: <CheckCircle2 className="h-4 w-4" />,
  parcial: <Clock className="h-4 w-4" />,
  em_andamento: <Clock className="h-4 w-4" />,
  bloqueado: <Ban className="h-4 w-4" />,
  planejado: <Clock className="h-4 w-4" />,
}
const ICONE_GRUPO: Record<string, JSX.Element> = {
  backlog: <Rocket className="h-4 w-4" />,
  entrega: <CheckCircle2 className="h-4 w-4" />,
  divida: <Wrench className="h-4 w-4" />,
  seguranca: <ShieldAlert className="h-4 w-4" />,
  saas: <Building2 className="h-4 w-4" />,
}

export default function RoadmapPage({ podeEditar }: { podeEditar: boolean }) {
  const toast = useToast()
  const [itens, setItens] = useState<ItemBacklog[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [edit, setEdit] = useState<Partial<ItemBacklog> | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erroForm, setErroForm] = useState<string | null>(null)
  const [visao, setVisao] = useState<'kanban' | 'lista'>('kanban')

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try { setItens(await api.backlog()) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const backlog = useMemo(() => itens.filter(i => i.tipo === 'backlog'), [itens])
  // grupos presentes nos dados, na ordem conhecida e com os desconhecidos no fim
  const gruposPresentes = useMemo(() => {
    const ordem = Object.keys(GRUPO_BACKLOG)
    const vistos = Array.from(new Set(itens.map(i => i.tipo)))
    return vistos.sort((a, b) => {
      const ia = ordem.indexOf(a), ib = ordem.indexOf(b)
      return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib)
    })
  }, [itens])
  const conta = (s: StatusBacklog) => backlog.filter(i => i.status === s).length
  const progresso = backlog.length === 0 ? 0
    : Math.round(100 * (conta('concluido') + conta('parcial') * 0.5) / backlog.length)

  const mover = async (id: string, coluna: ColunaKanban) => {
    // move na tela primeiro; se o banco recusar, recarrega e mostra o erro
    setItens(l => l.map(i => (i.id === id ? { ...i, coluna } : i)))
    try { await api.moverBacklogItem(id, coluna) } catch (e) { setErro(erroMsg(e)); await carregar() }
    await carregar()
  }

  const salvar = async () => {
    if (!edit) return
    setErroForm(null); setSalvando(true)
    try { await api.salvarBacklogItem(edit); toast('Item atualizado.'); setEdit(null); await carregar() }
    catch (e) { setErroForm(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center gap-3">
        <h2 className="text-base font-semibold">Roadmap</h2>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
        <div className="flex items-center gap-1 rounded-md border p-0.5">
          <button type="button" onClick={() => setVisao('kanban')}
            className={`flex items-center gap-1 rounded px-2.5 py-1 text-sm font-medium ${visao === 'kanban' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
            <KanbanSquare className="h-3.5 w-3.5" /> Kanban
          </button>
          <button type="button" onClick={() => setVisao('lista')}
            className={`flex items-center gap-1 rounded px-2.5 py-1 text-sm font-medium ${visao === 'lista' ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
            <List className="h-3.5 w-3.5" /> Visão geral
          </button>
        </div>
        <div className="flex-1" />
        {podeEditar && (
          <Button size="sm" onClick={() => { setEdit({ tipo: 'backlog', status: 'planejado', ordem: 100 }); setErroForm(null) }}>
            <Plus className="h-4 w-4" /> Novo item
          </Button>
        )}
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="rounded-lg border bg-card p-4">
        <div className="mb-3 flex items-end justify-between">
          <div>
            <p className="text-xs text-muted-foreground">Progresso do backlog</p>
            <p className="text-3xl font-bold">{progresso}%</p>
          </div>
          <p className="text-xs text-muted-foreground">
            {conta('concluido')} concluídos · {conta('parcial')} parciais · {conta('bloqueado')} bloqueados · {conta('planejado') + conta('em_andamento')} a fazer
          </p>
        </div>
        <div className="flex h-2.5 w-full overflow-hidden rounded-full bg-muted">
          {(['concluido', 'parcial', 'em_andamento', 'bloqueado', 'planejado'] as StatusBacklog[]).map(s => {
            const n = conta(s)
            return n === 0 ? null : (
              <div key={s} className={STATUS_BACKLOG[s].barra} style={{ width: `${(100 * n) / backlog.length}%` }} title={`${STATUS_BACKLOG[s].label}: ${n}`} />
            )
          })}
        </div>
        <div className="mt-2 flex flex-wrap gap-3 text-xs text-muted-foreground">
          {(['concluido', 'parcial', 'em_andamento', 'bloqueado', 'planejado'] as StatusBacklog[]).map(s => (
            <span key={s} className="inline-flex items-center gap-1">
              <span className={`inline-block h-2 w-2 rounded-full ${STATUS_BACKLOG[s].barra}`} />{STATUS_BACKLOG[s].label}
            </span>
          ))}
        </div>
      </div>

      {visao === 'kanban' && (
        <>
          <Kanban itens={itens} podeEditar={podeEditar}
            onMover={(id, coluna) => void mover(id, coluna)}
            onAbrir={i => { setEdit({ ...i }); setErroForm(null) }} />
          <p className="text-xs text-muted-foreground">
            Arraste o cartão entre as colunas. Ao cair em <strong>Feito</strong>, o item vira concluído e ganha a data de entrega;
            em <strong>Fazendo</strong>, vira em andamento. Clique no cartão para editar.
          </p>
        </>
      )}

      {visao === 'lista' && gruposPresentes.map(tipo => {
        const lista = itens.filter(i => i.tipo === tipo)
        if (lista.length === 0) return null
        return (
          <div key={tipo} className="space-y-2">
            <p className="flex items-center gap-2 text-sm font-semibold">
              {ICONE_GRUPO[tipo] ?? <Rocket className="h-4 w-4" />}{grupoDe(tipo).titulo}
              <span className="text-xs font-normal text-muted-foreground">({lista.length})</span>
            </p>
            <div className="grid gap-2 xl:grid-cols-2">
              {lista.map(i => {
                const st = STATUS_BACKLOG[i.status]
                return (
                  <div key={i.id} className="rounded-lg border bg-card p-3">
                    <div className="flex items-start gap-2">
                      <div className="min-w-0 flex-1">
                        <p className="font-medium">
                          {i.numero !== null && <span className="mr-1.5 font-mono text-muted-foreground">{numeroBacklog(i.numero)}</span>}
                          {i.titulo}
                        </p>
                        {i.descricao && <p className="mt-0.5 text-xs text-muted-foreground">{i.descricao}</p>}
                      </div>
                      <span className={`inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-0.5 text-xs font-medium ${st.classe}`}>
                        {ICONE[i.status]}{st.label}
                      </span>
                      {podeEditar && (
                        <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...i }); setErroForm(null) }}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                    </div>

                    {i.observacao && (
                      <p className="mt-2 flex items-start gap-1.5 rounded bg-muted/50 p-2 text-xs">
                        <AlertTriangle className="mt-0.5 h-3 w-3 shrink-0 text-muted-foreground" />{i.observacao}
                      </p>
                    )}

                    <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-muted-foreground">
                      {i.esforco && <span>Esforço: {i.esforco} · {ESFORCO_LABEL[i.esforco]}</span>}
                      {i.depende_de && <span>Depende de: {i.depende_de}</span>}
                      {i.entregue_em && <span>Entregue em {formatDate(i.entregue_em)}</span>}
                    </div>
                  </div>
                )
              })}
            </div>
          </div>
        )
      })}

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} width="max-w-lg"
        title={edit?.id ? 'Editar item' : 'Novo item'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <div className="grid grid-cols-3 gap-3">
              <Field label="Nº"><Input value={edit.id ? numeroBacklog(edit.numero ?? null) : 'automático'} disabled
                title="Numerado pelo banco, em sequência" /></Field>
              <Field label="Grupo">
                <Select className="w-full" value={edit.tipo ?? 'backlog'} disabled={salvando}
                  onChange={e => setEdit({ ...edit, tipo: e.target.value as ItemBacklog['tipo'] })}>
                  <option value="backlog">Backlog</option>
                  <option value="entrega">Já implantado</option>
                  <option value="divida">Dívida técnica</option>
                  <option value="seguranca">Segurança e homologação</option>
                  <option value="saas">Transformação em SaaS</option>
                </Select>
              </Field>
              <Field label="Ordem"><Input type="number" value={edit.ordem ?? 100} disabled={salvando}
                onChange={e => setEdit({ ...edit, ordem: Number(e.target.value) })} /></Field>
            </div>
            <Field label="Título *"><Input value={edit.titulo ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, titulo: e.target.value })} /></Field>
            <Field label="Descrição"><Textarea rows={2} value={edit.descricao ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, descricao: e.target.value })} /></Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Status">
                <Select className="w-full" value={edit.status ?? 'planejado'} disabled={salvando}
                  onChange={e => setEdit({ ...edit, status: e.target.value as StatusBacklog })}>
                  <option value="planejado">Planejado</option><option value="em_andamento">Em andamento</option>
                  <option value="parcial">Parcial</option><option value="bloqueado">Bloqueado</option>
                  <option value="concluido">Concluído</option>
                </Select>
              </Field>
              <Field label="Esforço">
                <Select className="w-full" value={edit.esforco ?? ''} disabled={salvando}
                  onChange={e => setEdit({ ...edit, esforco: (e.target.value || null) as ItemBacklog['esforco'] })}>
                  <option value="">—</option><option value="P">P — até 3 dias</option>
                  <option value="M">M — 1 a 2 semanas</option><option value="G">G — 3 semanas ou mais</option>
                </Select>
              </Field>
            </div>
            <Field label="Depende de"><Input value={edit.depende_de ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, depende_de: e.target.value })} /></Field>
            <Field label="Observação"><Textarea rows={2} value={edit.observacao ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, observacao: e.target.value })} /></Field>
            <Field label="Entregue em"><Input type="date" value={edit.entregue_em ?? ''} disabled={salvando}
              onChange={e => setEdit({ ...edit, entregue_em: e.target.value || null })} /></Field>
            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
