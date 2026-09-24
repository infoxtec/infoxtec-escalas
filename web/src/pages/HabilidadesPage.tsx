import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle, CalendarClock, ChevronDown, ChevronRight, Edit2, ListChecks, Plus, RefreshCw, ShieldCheck, Trash2, Users,
} from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, Textarea, ToggleRow, useToast } from '../components/ui'
import DocumentosArquivos from '../components/DocumentosArquivos'
import { api, erroMsg } from '../lib/api'
import { CATEGORIA_LABEL, NIVEL_LABEL, SITUACAO_HAB, diasAte, formatDate } from '../lib/types'
import type { Habilidade, Nivel, TecnicoAgrupado, Tecnico, TipoAtividade } from '../lib/types'

type Secao = 'tecnicos' | 'documentos' | 'catalogo' | 'tipos'

export default function HabilidadesPage({ tecnicos, podeEditar }: { tecnicos: Tecnico[]; podeEditar: boolean }) {
  const [secao, setSecao] = useState<Secao>('tecnicos')
  const [agrupado, setAgrupado] = useState<TecnicoAgrupado[]>([])
  const [catalogo, setCatalogo] = useState<Habilidade[]>([])
  const [tipos, setTipos] = useState<TipoAtividade[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try {
      const [a, c, t] = await Promise.all([api.habilidadesPorTecnico(), api.habilidades(), api.tiposAtividade()])
      setAgrupado(a); setCatalogo(c); setTipos(t)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const pendencias = agrupado.filter(t => t.ativo && (t.vencidos > 0 || t.vencendo > 0 || t.sem_data > 0))
  const totalVencidos = agrupado.reduce((s, t) => s + (t.ativo ? t.vencidos : 0), 0)

  const aba = (s: Secao, rotulo: string, badge?: number) => (
    <button type="button" onClick={() => setSecao(s)}
      className={`flex items-center gap-1.5 rounded px-3 py-1.5 text-sm font-medium ${secao === s ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
      {rotulo}
      {!!badge && badge > 0 && (
        <span className={`rounded-full px-1.5 text-[10px] font-bold ${secao === s ? 'bg-primary-foreground/20' : 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300'}`}>{badge}</span>
      )}
    </button>
  )

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex flex-wrap items-center gap-1 rounded-md border p-0.5">
          {aba('tecnicos', 'Por técnico')}
          {aba('documentos', 'Documentos', pendencias.length)}
          {aba('catalogo', 'Habilidades')}
          {aba('tipos', 'Tipos de atividade')}
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      {totalVencidos > 0 && secao !== 'documentos' && (
        <button type="button" onClick={() => setSecao('documentos')}
          className="flex w-full items-start gap-2 rounded-md bg-red-50 p-3 text-left text-sm text-red-800 hover:bg-red-100 dark:bg-red-900/20 dark:text-red-300">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <span><strong>{totalVencidos} documento(s) vencido(s)</strong> entre os técnicos ativos. Clique para ver.</span>
        </button>
      )}

      {secao === 'tecnicos' && <PorTecnico agrupado={agrupado} catalogo={catalogo} tecnicos={tecnicos} podeEditar={podeEditar} recarregar={carregar} />}
      {secao === 'documentos' && <><Documentos agrupado={agrupado} /><DocumentosArquivos tecnicos={tecnicos} catalogo={catalogo} podeEditar={podeEditar} /></>}
      {secao === 'catalogo' && <Catalogo catalogo={catalogo} podeEditar={podeEditar} recarregar={carregar} />}
      {secao === 'tipos' && <Tipos tipos={tipos} catalogo={catalogo} podeEditar={podeEditar} recarregar={carregar} />}
    </div>
  )
}

function Chip({ situacao, validade }: { situacao: keyof typeof SITUACAO_HAB; validade: string | null }) {
  const dias = diasAte(validade)
  const s = SITUACAO_HAB[situacao]
  return (
    <span className={`inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-medium ${s.classe}`}>
      {s.label}
      {validade && <span className="opacity-80">· {formatDate(validade)}{dias !== null && dias >= 0 && dias <= 60 ? ` (${dias}d)` : ''}</span>}
    </span>
  )
}

// ------------------------------------------------------------------ por técnico (agrupado)
interface Selecao { habilidade_id: string; nivel: Nivel; validade: string }

function PorTecnico({ agrupado, catalogo, tecnicos, podeEditar, recarregar }: {
  agrupado: TecnicoAgrupado[]; catalogo: Habilidade[]; tecnicos: Tecnico[]
  podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const toast = useToast()
  const [filtro, setFiltro] = useState('')
  const [abertos, setAbertos] = useState<Set<string>>(new Set())
  const [edit, setEdit] = useState<{ tecnico_id: string; travado: boolean; itens: Selecao[] } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const lista = useMemo(() => {
    const q = filtro.trim().toLocaleLowerCase('pt-BR')
    if (!q) return agrupado
    return agrupado.filter(t =>
      `${t.tecnico} ${t.funcao} ${t.habilidades.map(h => h.habilidade).join(' ')}`.toLocaleLowerCase('pt-BR').includes(q))
  }, [agrupado, filtro])

  const alternarLinha = (id: string) => setAbertos(s => {
    const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n
  })

  const abrir = (tecnico_id: string, travado: boolean) => {
    setErro(null)
    const atual = agrupado.find(t => t.tecnico_id === tecnico_id)
    setEdit({
      tecnico_id, travado,
      itens: (atual?.habilidades ?? []).map(h => ({ habilidade_id: h.habilidade_id, nivel: h.nivel, validade: h.validade ?? '' })),
    })
  }

  const alternar = (habilidade_id: string) => setEdit(e => {
    if (!e) return e
    const tem = e.itens.some(i => i.habilidade_id === habilidade_id)
    return { ...e, itens: tem ? e.itens.filter(i => i.habilidade_id !== habilidade_id) : [...e.itens, { habilidade_id, nivel: 'basico', validade: '' }] }
  })
  const mudar = (habilidade_id: string, campo: 'nivel' | 'validade', valor: string) => setEdit(e =>
    e ? { ...e, itens: e.itens.map(i => i.habilidade_id === habilidade_id ? { ...i, [campo]: valor } : i) } : e)

  const salvar = async () => {
    if (!edit) return
    setErro(null)
    if (!edit.tecnico_id) return setErro('Escolha o técnico.')
    const faltaData = edit.itens.find(i => !i.validade && catalogo.find(h => h.id === i.habilidade_id)?.exige_validade)
    if (faltaData) return setErro(`${catalogo.find(h => h.id === faltaData.habilidade_id)?.nome} exige a data de validade.`)
    setSalvando(true)
    try {
      const n = await api.definirHabilidades(edit.tecnico_id, edit.itens.map(i => ({ ...i, validade: i.validade || null })))
      toast(n === 0 ? 'Habilidades removidas.' : `${n} habilidade(s) salvas.`)
      setEdit(null); await recarregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const tecnicoEditado = tecnicos.find(t => t.id === edit?.tecnico_id)

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input placeholder="Buscar por técnico, função ou habilidade..." value={filtro} onChange={e => setFiltro(e.target.value)} className="w-80" />
        <div className="flex-1" />
        {podeEditar && <Button size="sm" onClick={() => abrir('', false)}><Plus className="h-4 w-4" /> Atribuir habilidades</Button>}
      </div>

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="w-8 px-2 py-2.5" />
              <th className="px-3 py-2.5">Técnico</th>
              <th className="px-3 py-2.5">Função</th>
              <th className="px-3 py-2.5">Habilidades</th>
              <th className="px-3 py-2.5">Documentos</th>
              <th className="w-16 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lista.length === 0 && (
              <tr><td colSpan={6} className="py-12 text-center text-muted-foreground">Nenhum técnico encontrado</td></tr>
            )}
            {lista.map(t => {
              const aberto = abertos.has(t.tecnico_id)
              const docs = t.habilidades.filter(h => h.exige_validade)
              return (
                <>
                  <tr key={t.tecnico_id} className={`border-b cursor-pointer hover:bg-muted/30 ${!t.ativo ? 'opacity-50' : ''}`} onClick={() => alternarLinha(t.tecnico_id)}>
                    <td className="px-2 py-2.5 text-muted-foreground">
                      {aberto ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
                    </td>
                    <td className="px-3 py-2.5 font-medium">{t.tecnico}{!t.ativo && <span className="ml-2 text-xs text-muted-foreground">(inativo)</span>}</td>
                    <td className="px-3 py-2.5 text-xs text-muted-foreground">{t.funcao}</td>
                    <td className="px-3 py-2.5 text-xs">
                      {t.total === 0 ? <span className="text-muted-foreground">nenhuma</span> : `${t.total} habilidade(s)`}
                    </td>
                    <td className="px-3 py-2.5">
                      <div className="flex flex-wrap gap-1">
                        {docs.length === 0 && <span className="text-xs text-muted-foreground">—</span>}
                        {t.vencidos > 0 && <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-900/30 dark:text-red-300">{t.vencidos} vencido(s)</span>}
                        {t.vencendo > 0 && <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900/30 dark:text-amber-300">{t.vencendo} vencendo</span>}
                        {docs.length > 0 && t.vencidos === 0 && t.vencendo === 0 && (
                          <span className="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900/30 dark:text-green-300">
                            <ShieldCheck className="h-3 w-3" />{docs.length} em dia
                          </span>
                        )}
                      </div>
                    </td>
                    <td className="px-3 py-2.5 text-right" onClick={e => e.stopPropagation()}>
                      {podeEditar && (
                        <Button variant="ghost" size="icon" aria-label="Editar habilidades" title="Editar habilidades deste técnico" onClick={() => abrir(t.tecnico_id, true)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                      )}
                    </td>
                  </tr>
                  {aberto && (
                    <tr key={`${t.tecnico_id}-det`} className="border-b bg-muted/20">
                      <td />
                      <td colSpan={5} className="px-3 py-3">
                        {t.habilidades.length === 0 ? (
                          <p className="text-xs text-muted-foreground">Nenhuma habilidade atribuída.{podeEditar && ' Use o lápis para cadastrar.'}</p>
                        ) : (
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-left text-muted-foreground">
                                <th className="py-1 pr-3">Habilidade</th><th className="py-1 pr-3">Categoria</th>
                                <th className="py-1 pr-3">Nível</th><th className="py-1 pr-3">Validade</th>
                              </tr>
                            </thead>
                            <tbody>
                              {t.habilidades.map(h => (
                                <tr key={h.habilidade_id} className="border-t border-border/50">
                                  <td className="py-1.5 pr-3 font-medium">{h.habilidade}</td>
                                  <td className="py-1.5 pr-3 text-muted-foreground">{CATEGORIA_LABEL[h.categoria] ?? h.categoria}</td>
                                  <td className="py-1.5 pr-3">{NIVEL_LABEL[h.nivel]}</td>
                                  <td className="py-1.5 pr-3">
                                    {h.exige_validade ? <Chip situacao={h.situacao} validade={h.validade} /> : <span className="text-muted-foreground">não expira</span>}
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        )}
                      </td>
                    </tr>
                  )}
                </>
              )
            })}
          </tbody>
        </table>
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} width="max-w-2xl"
        title={<span className="flex items-center gap-2"><Users className="h-4 w-4" />{tecnicoEditado ? `Habilidades de ${tecnicoEditado.nome}` : 'Atribuir habilidades'}</span>}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando || !edit?.tecnico_id}>
            {salvando ? 'Salvando...' : `Salvar ${edit?.itens.length ?? 0} habilidade(s)`}
          </Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="Técnico *">
              <Select className="w-full" value={edit.tecnico_id} disabled={edit.travado || salvando}
                onChange={e => {
                  const id = e.target.value
                  const atual = agrupado.find(t => t.tecnico_id === id)
                  setEdit({ tecnico_id: id, travado: false, itens: (atual?.habilidades ?? []).map(h => ({ habilidade_id: h.habilidade_id, nivel: h.nivel, validade: h.validade ?? '' })) })
                }}>
                <option value="">Selecione...</option>
                {tecnicos.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome} — {t.funcao}</option>)}
              </Select>
            </Field>

            <p className="text-xs font-medium text-muted-foreground">Marque tudo o que ele tem. NRs, CNH e ASO exigem a data de validade.</p>

            <div className="max-h-96 space-y-1 overflow-y-auto rounded-md border p-2">
              {catalogo.filter(h => h.ativo).map(h => {
                const sel = edit.itens.find(i => i.habilidade_id === h.id)
                return (
                  <div key={h.id} className={`flex flex-wrap items-center gap-2 rounded px-1.5 py-1 text-sm ${sel ? 'bg-muted/60' : ''}`}>
                    <input type="checkbox" checked={!!sel} disabled={!edit.tecnico_id || salvando} onChange={() => alternar(h.id)} />
                    <span className="min-w-[160px] flex-1">
                      {h.nome}
                      <span className="ml-1 text-xs text-muted-foreground">{CATEGORIA_LABEL[h.categoria]}</span>
                    </span>
                    {sel && (
                      <>
                        <Select className="h-7 text-xs" value={sel.nivel} disabled={salvando} onChange={e => mudar(h.id, 'nivel', e.target.value)}>
                          <option value="basico">Básico</option>
                          <option value="intermediario">Intermediário</option>
                          <option value="avancado">Avançado</option>
                        </Select>
                        {h.exige_validade && (
                          <Input type="date" className={`h-7 w-40 text-xs ${!sel.validade ? 'border-destructive' : ''}`}
                            value={sel.validade} disabled={salvando} onChange={e => mudar(h.id, 'validade', e.target.value)} />
                        )}
                      </>
                    )}
                  </div>
                )
              })}
            </div>

            <p className="text-xs text-muted-foreground">O que ficar desmarcado é removido do técnico ao salvar.</p>
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}

// ------------------------------------------------------------------ documentos
function Documentos({ agrupado }: { agrupado: TecnicoAgrupado[] }) {
  const [incluirInativos, setIncluirInativos] = useState(false)

  const linhas = useMemo(() => agrupado
    .filter(t => incluirInativos || t.ativo)
    .flatMap(t => t.habilidades.filter(h => h.exige_validade).map(h => ({ ...h, tecnico: t.tecnico, funcao: t.funcao, ativo: t.ativo })))
    .sort((a, b) => {
      const peso = (s: string) => (s === 'vencida' || s === 'sem_validade' ? 0 : s === 'vencendo' ? 1 : 2)
      return peso(a.situacao) - peso(b.situacao) || (a.validade ?? '').localeCompare(b.validade ?? '')
    }), [agrupado, incluirInativos])

  const conta = (s: string) => linhas.filter(l => l.situacao === s).length

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Cartao titulo="Vencidos" valor={conta('vencida')} cor="text-red-700 dark:text-red-400" />
        <Cartao titulo="Sem data" valor={conta('sem_validade')} cor="text-red-700 dark:text-red-400" />
        <Cartao titulo="Vencem em 30 dias" valor={conta('vencendo')} cor="text-amber-700 dark:text-amber-400" />
        <Cartao titulo="Em dia" valor={conta('valida')} cor="text-green-700 dark:text-green-400" />
      </div>

      <label className="flex items-center gap-2 text-xs text-muted-foreground">
        <input type="checkbox" checked={incluirInativos} onChange={e => setIncluirInativos(e.target.checked)} />
        Incluir técnicos inativos
      </label>

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Técnico</th><th className="px-3 py-2.5">Documento</th>
              <th className="px-3 py-2.5">Validade</th><th className="px-3 py-2.5">Situação</th>
            </tr>
          </thead>
          <tbody>
            {linhas.length === 0 && (
              <tr><td colSpan={4} className="py-12 text-center text-muted-foreground">Nenhum documento com controle de validade cadastrado</td></tr>
            )}
            {linhas.map(l => (
              <tr key={`${l.tecnico}-${l.habilidade_id}`} className={`border-b last:border-0 ${!l.ativo ? 'opacity-50' : ''}`}>
                <td className="px-3 py-2.5 font-medium">{l.tecnico}<span className="ml-2 text-xs text-muted-foreground">{l.funcao}</span></td>
                <td className="px-3 py-2.5">{l.habilidade}</td>
                <td className="px-3 py-2.5 font-mono text-xs">{l.validade ? formatDate(l.validade) : '—'}</td>
                <td className="px-3 py-2.5"><Chip situacao={l.situacao} validade={l.validade} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="flex items-start gap-2 text-xs text-muted-foreground">
        <CalendarClock className="mt-0.5 h-3.5 w-3.5 shrink-0" />
        Toda segunda às 8h os supervisores recebem no WhatsApp a lista de documentos vencidos e a vencer em 30 dias.
        O prazo de aviso e o dia da semana ficam na tabela de configuração.
      </p>
    </div>
  )
}

function Cartao({ titulo, valor, cor }: { titulo: string; valor: number; cor: string }) {
  return (
    <div className="rounded-lg border bg-card p-3">
      <p className="text-xs text-muted-foreground">{titulo}</p>
      <p className={`mt-0.5 text-2xl font-bold ${cor}`}>{valor}</p>
    </div>
  )
}

// ------------------------------------------------------------------ catálogo
function Catalogo({ catalogo, podeEditar, recarregar }: { catalogo: Habilidade[]; podeEditar: boolean; recarregar: () => Promise<void> }) {
  const toast = useToast()
  const [edit, setEdit] = useState<Partial<Habilidade> | null>(null)
  const [alvo, setAlvo] = useState<Habilidade | null>(null)
  const [forcar, setForcar] = useState(false)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [erroExcluir, setErroExcluir] = useState<string | null>(null)

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.salvarHabilidade(edit); setEdit(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const excluir = async () => {
    if (!alvo) return
    setErroExcluir(null); setSalvando(true)
    try {
      const r = await api.excluirHabilidade(alvo.id, forcar)
      toast(r.tecnicos_afetados > 0
        ? `${r.nome} excluída. Removida de ${r.tecnicos_afetados} técnico(s).`
        : `${r.nome} excluída.`)
      setAlvo(null); setForcar(false); await recarregar()
    } catch (e) { setErroExcluir(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <p className="text-xs text-muted-foreground">Marque <strong>Exige validade</strong> em NRs, CNH, ASO e qualquer documento que vença.</p>
        {podeEditar && <Button size="sm" onClick={() => { setEdit({ nome: '', categoria: 'tecnica', exige_validade: false, ativo: true }); setErro(null) }}><Plus className="h-4 w-4" /> Nova habilidade</Button>}
      </div>
      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Habilidade</th><th className="px-3 py-2.5">Categoria</th>
              <th className="px-3 py-2.5">Exige validade</th><th className="px-3 py-2.5">Descrição</th>
              <th className="px-3 py-2.5 text-center">Ativa</th><th className="w-20 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {catalogo.map(h => (
              <tr key={h.id} className={`border-b last:border-0 ${!h.ativo ? 'opacity-50' : ''}`}>
                <td className="px-3 py-2.5 font-medium">{h.nome}</td>
                <td className="px-3 py-2.5 text-xs">{CATEGORIA_LABEL[h.categoria]}</td>
                <td className="px-3 py-2.5 text-xs">{h.exige_validade ? 'Sim' : 'Não'}</td>
                <td className="px-3 py-2.5 text-xs text-muted-foreground">{h.descricao ?? '—'}</td>
                <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${h.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                <td className="px-3 py-2.5 text-right">
                  {podeEditar && (
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...h }); setErro(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>
                      <Button variant="ghost" size="icon" aria-label="Excluir" className="text-destructive hover:bg-destructive/10"
                        onClick={() => { setAlvo(h); setForcar(false); setErroExcluir(null) }}><Trash2 className="h-3.5 w-3.5" /></Button>
                    </div>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar habilidade' : 'Nova habilidade'} width="max-w-md"
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="Nome *"><Input value={edit.nome ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, nome: e.target.value })} placeholder="Ex: NR-13" /></Field>
            <Field label="Categoria">
              <Select className="w-full" value={edit.categoria ?? 'tecnica'} disabled={salvando}
                onChange={e => setEdit({ ...edit, categoria: e.target.value as Habilidade['categoria'] })}>
                <option value="tecnica">Técnica</option><option value="seguranca">Segurança</option>
                <option value="habilitacao">Habilitação</option><option value="outra">Outra</option>
              </Select>
            </Field>
            <Field label="Descrição"><Textarea rows={2} value={edit.descricao ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, descricao: e.target.value })} /></Field>
            <ToggleRow label="Exige validade" description="O sistema cobra a data no cadastro e avisa quando vencer."
              checked={!!edit.exige_validade} onChange={v => setEdit({ ...edit, exige_validade: v })} disabled={salvando} />
            <ToggleRow label="Ativa" description="Habilidade inativa não aparece para atribuição nem nos requisitos."
              checked={edit.ativo !== false} onChange={v => setEdit({ ...edit, ativo: v })} disabled={salvando} />
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Excluir habilidade" confirmLabel={forcar ? 'Excluir mesmo assim' : 'Excluir'} destructive
        busy={salvando} onCancel={() => { setAlvo(null); setForcar(false) }} onConfirm={() => void excluir()}>
        <p><strong className="text-foreground">{alvo?.nome}</strong> sai do catálogo. Se estiver atribuída a técnicos ou exigida por tipos de atividade, essas ligações também são apagadas.</p>
        <p>Para apenas tirá-la de uso mantendo o histórico, edite e desmarque <strong className="text-foreground">Ativa</strong>.</p>
        <label className="flex items-center gap-2 text-xs">
          <input type="checkbox" checked={forcar} onChange={e => setForcar(e.target.checked)} disabled={salvando} />
          Excluir mesmo estando em uso
        </label>
        {erroExcluir && <ErrorBox>{erroExcluir}</ErrorBox>}
      </Confirm>
    </div>
  )
}

// ------------------------------------------------------------------ tipos de atividade
function Tipos({ tipos, catalogo, podeEditar, recarregar }: {
  tipos: TipoAtividade[]; catalogo: Habilidade[]; podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const [edit, setEdit] = useState<{ id?: string; nome: string; descricao: string; ativo: boolean; requisitos: { habilidade_id: string; nivel_minimo: Nivel }[] } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const alternar = (habilidade_id: string) => setEdit(e => {
    if (!e) return e
    const existe = e.requisitos.find(r => r.habilidade_id === habilidade_id)
    return { ...e, requisitos: existe ? e.requisitos.filter(r => r.habilidade_id !== habilidade_id) : [...e.requisitos, { habilidade_id, nivel_minimo: 'basico' }] }
  })

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.salvarTipoAtividade(edit); setEdit(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <p className="text-xs text-muted-foreground">O tipo de atividade define quais habilidades o técnico precisa ter. Ao montar a escala, quem não atende aparece com aviso.</p>
        {podeEditar && <Button size="sm" onClick={() => { setEdit({ nome: '', descricao: '', ativo: true, requisitos: [] }); setErro(null) }}><Plus className="h-4 w-4" /> Novo tipo</Button>}
      </div>
      <div className="grid gap-3 md:grid-cols-2">
        {tipos.map(t => (
          <div key={t.id} className={`rounded-lg border bg-card p-4 ${!t.ativo ? 'opacity-50' : ''}`}>
            <div className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <p className="font-medium">{t.nome}</p>
                {t.descricao && <p className="text-xs text-muted-foreground">{t.descricao}</p>}
              </div>
              {podeEditar && (
                <Button variant="ghost" size="icon" aria-label="Editar"
                  onClick={() => { setEdit({ id: t.id, nome: t.nome, descricao: t.descricao ?? '', ativo: t.ativo, requisitos: t.requisitos.map(r => ({ habilidade_id: r.habilidade_id, nivel_minimo: r.nivel_minimo })) }); setErro(null) }}>
                  <Edit2 className="h-3.5 w-3.5" />
                </Button>
              )}
            </div>
            <div className="mt-2 flex flex-wrap gap-1.5">
              {t.requisitos.length === 0 && <span className="text-xs text-muted-foreground">Sem habilidade exigida</span>}
              {t.requisitos.map(r => (
                <span key={r.habilidade_id} className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-xs">
                  <ListChecks className="h-3 w-3" />{r.habilidade} · {NIVEL_LABEL[r.nivel_minimo]}
                </span>
              ))}
            </div>
          </div>
        ))}
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar tipo de atividade' : 'Novo tipo de atividade'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="Nome *"><Input value={edit.nome} disabled={salvando} onChange={e => setEdit({ ...edit, nome: e.target.value })} /></Field>
            <Field label="Descrição"><Input value={edit.descricao} disabled={salvando} onChange={e => setEdit({ ...edit, descricao: e.target.value })} /></Field>
            <div className="space-y-2">
              <p className="text-xs font-medium text-muted-foreground">Habilidades exigidas</p>
              <div className="max-h-60 space-y-1 overflow-y-auto rounded-md border p-2">
                {catalogo.filter(h => h.ativo).map(h => {
                  const req = edit.requisitos.find(r => r.habilidade_id === h.id)
                  return (
                    <div key={h.id} className="flex items-center gap-2 text-sm">
                      <input type="checkbox" checked={!!req} disabled={salvando} onChange={() => alternar(h.id)} />
                      <span className="flex-1">{h.nome}</span>
                      {req && (
                        <Select className="h-7 text-xs" value={req.nivel_minimo} disabled={salvando}
                          onChange={e => setEdit({ ...edit, requisitos: edit.requisitos.map(r => r.habilidade_id === h.id ? { ...r, nivel_minimo: e.target.value as Nivel } : r) })}>
                          <option value="basico">Básico</option><option value="intermediario">Intermediário</option><option value="avancado">Avançado</option>
                        </Select>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
            <ToggleRow label="Ativo" checked={edit.ativo} onChange={v => setEdit({ ...edit, ativo: v })} disabled={salvando} />
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
