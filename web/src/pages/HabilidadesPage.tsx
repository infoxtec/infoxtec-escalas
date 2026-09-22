import { useCallback, useEffect, useMemo, useState } from 'react'
import { Edit2, ListChecks, Plus, RefreshCw, Trash2, Users } from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, Textarea, ToggleRow, useToast } from '../components/ui'
import { SortableTh, useSortable } from '../components/SortableTh'
import { api, erroMsg } from '../lib/api'
import { CATEGORIA_LABEL, NIVEL_LABEL } from '../lib/types'
import type { Habilidade, Nivel, TecnicoHabilidade, Tecnico, TipoAtividade } from '../lib/types'

type Secao = 'tecnicos' | 'catalogo' | 'tipos'

export default function HabilidadesPage({ tecnicos, podeEditar }: { tecnicos: Tecnico[]; podeEditar: boolean }) {
  const [secao, setSecao] = useState<Secao>('tecnicos')
  const [lista, setLista] = useState<TecnicoHabilidade[]>([])
  const [catalogo, setCatalogo] = useState<Habilidade[]>([])
  const [tipos, setTipos] = useState<TipoAtividade[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try {
      const [l, c, t] = await Promise.all([api.tecnicoHabilidades(), api.habilidades(), api.tiposAtividade()])
      setLista(l); setCatalogo(c); setTipos(t)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const aba = (s: Secao, rotulo: string) => (
    <button type="button" onClick={() => setSecao(s)}
      className={`rounded px-3 py-1.5 text-sm font-medium ${secao === s ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
      {rotulo}
    </button>
  )

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <div className="flex items-center gap-1 rounded-md border p-0.5">
          {aba('tecnicos', 'Por técnico')}
          {aba('catalogo', 'Habilidades')}
          {aba('tipos', 'Tipos de atividade')}
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      {secao === 'tecnicos' && <PorTecnico lista={lista} catalogo={catalogo} tecnicos={tecnicos} podeEditar={podeEditar} recarregar={carregar} />}
      {secao === 'catalogo' && <Catalogo catalogo={catalogo} podeEditar={podeEditar} recarregar={carregar} />}
      {secao === 'tipos' && <Tipos tipos={tipos} catalogo={catalogo} podeEditar={podeEditar} recarregar={carregar} />}
    </div>
  )
}

// ------------------------------------------------------------------ por técnico
interface Selecao { habilidade_id: string; nivel: Nivel }

function PorTecnico({ lista, catalogo, tecnicos, podeEditar, recarregar }: {
  lista: TecnicoHabilidade[]; catalogo: Habilidade[]; tecnicos: Tecnico[]
  podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const toast = useToast()
  const [filtro, setFiltro] = useState('')
  const [edit, setEdit] = useState<{ tecnico_id: string; travado: boolean; itens: Selecao[] } | null>(null)
  const [alvo, setAlvo] = useState<TecnicoHabilidade | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const filtrada = useMemo(() => {
    const q = filtro.trim().toLocaleLowerCase('pt-BR')
    if (!q) return lista
    return lista.filter(h => `${h.tecnico} ${h.habilidade} ${h.funcao}`.toLocaleLowerCase('pt-BR').includes(q))
  }, [lista, filtro])

  const { sorted, thProps } = useSortable(filtrada, {
    tecnico: h => h.tecnico, habilidade: h => h.habilidade,
    categoria: h => h.categoria, nivel: h => h.nivel_valor,
  }, { key: 'tecnico' })

  const abrir = (tecnico_id: string, travado: boolean) => {
    setErro(null)
    setEdit({
      tecnico_id, travado,
      itens: lista.filter(h => h.tecnico_id === tecnico_id).map(h => ({ habilidade_id: h.habilidade_id, nivel: h.nivel })),
    })
  }

  const alternar = (habilidade_id: string) => setEdit(e => {
    if (!e) return e
    const tem = e.itens.some(i => i.habilidade_id === habilidade_id)
    return { ...e, itens: tem ? e.itens.filter(i => i.habilidade_id !== habilidade_id) : [...e.itens, { habilidade_id, nivel: 'basico' }] }
  })

  const nivelDe = (habilidade_id: string, nivel: Nivel) => setEdit(e =>
    e ? { ...e, itens: e.itens.map(i => i.habilidade_id === habilidade_id ? { ...i, nivel } : i) } : e)

  const marcarTodas = (marcar: boolean) => setEdit(e =>
    e ? { ...e, itens: marcar ? catalogo.filter(h => h.ativo).map(h => ({ habilidade_id: h.id, nivel: (e.itens.find(i => i.habilidade_id === h.id)?.nivel ?? 'basico') as Nivel })) : [] } : e)

  const salvar = async () => {
    if (!edit) return
    setErro(null)
    if (!edit.tecnico_id) return setErro('Escolha o técnico.')
    setSalvando(true)
    try {
      const n = await api.definirHabilidades(edit.tecnico_id, edit.itens)
      toast(n === 0 ? 'Habilidades removidas.' : `${n} habilidade(s) salvas.`)
      setEdit(null); await recarregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const remover = async () => {
    if (!alvo) return
    setSalvando(true)
    try { await api.removerTecnicoHabilidade(alvo.tecnico_id, alvo.habilidade_id); setAlvo(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const tecnicoEditado = tecnicos.find(t => t.id === edit?.tecnico_id)

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input placeholder="Buscar por técnico ou habilidade..." value={filtro} onChange={e => setFiltro(e.target.value)} className="w-72" />
        <div className="flex-1" />
        {podeEditar && (
          <Button size="sm" onClick={() => abrir('', false)}>
            <Plus className="h-4 w-4" /> Atribuir habilidades
          </Button>
        )}
      </div>

      <div className="overflow-hidden rounded-md border">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50">
                <SortableTh {...thProps('tecnico')}>Técnico</SortableTh>
                <SortableTh {...thProps('habilidade')}>Habilidade</SortableTh>
                <SortableTh {...thProps('categoria')}>Categoria</SortableTh>
                <SortableTh {...thProps('nivel')}>Nível</SortableTh>
                <th className="w-24 px-3 py-2.5" />
              </tr>
            </thead>
            <tbody>
              {sorted.length === 0 ? (
                <tr><td colSpan={5} className="py-12 text-center text-muted-foreground">Nenhuma habilidade atribuída ainda</td></tr>
              ) : sorted.map(h => (
                <tr key={`${h.tecnico_id}-${h.habilidade_id}`} className={`border-b last:border-0 ${!h.tecnico_ativo ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2.5 font-medium">{h.tecnico}</td>
                  <td className="px-3 py-2.5">{h.habilidade}</td>
                  <td className="px-3 py-2.5 text-xs text-muted-foreground">{CATEGORIA_LABEL[h.categoria] ?? h.categoria}</td>
                  <td className="px-3 py-2.5 text-xs">{NIVEL_LABEL[h.nivel]}</td>
                  <td className="px-3 py-2.5 text-right">
                    {podeEditar && (
                      <div className="flex justify-end gap-1">
                        <Button variant="ghost" size="icon" aria-label="Editar habilidades deste técnico" title="Editar todas as habilidades deste técnico"
                          onClick={() => abrir(h.tecnico_id, true)}>
                          <Edit2 className="h-3.5 w-3.5" />
                        </Button>
                        <Button variant="ghost" size="icon" aria-label="Remover" className="text-destructive hover:bg-destructive/10" onClick={() => setAlvo(h)}>
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} width="max-w-lg"
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
                onChange={e => { const id = e.target.value; setEdit({ tecnico_id: id, travado: false, itens: lista.filter(h => h.tecnico_id === id).map(h => ({ habilidade_id: h.habilidade_id, nivel: h.nivel })) }) }}>
                <option value="">Selecione...</option>
                {tecnicos.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome} — {t.funcao}</option>)}
              </Select>
            </Field>

            <div className="flex items-center justify-between">
              <p className="text-xs font-medium text-muted-foreground">Marque todas as habilidades que ele tem</p>
              <div className="flex gap-1">
                <button type="button" className="text-xs text-primary" onClick={() => marcarTodas(true)} disabled={salvando}>Marcar todas</button>
                <span className="text-xs text-muted-foreground">·</span>
                <button type="button" className="text-xs text-primary" onClick={() => marcarTodas(false)} disabled={salvando}>Limpar</button>
              </div>
            </div>

            <div className="max-h-80 space-y-1 overflow-y-auto rounded-md border p-2">
              {catalogo.filter(h => h.ativo).map(h => {
                const sel = edit.itens.find(i => i.habilidade_id === h.id)
                return (
                  <div key={h.id} className={`flex items-center gap-2 rounded px-1.5 py-1 text-sm ${sel ? 'bg-muted/60' : ''}`}>
                    <input type="checkbox" checked={!!sel} disabled={!edit.tecnico_id || salvando} onChange={() => alternar(h.id)} />
                    <span className="flex-1">
                      {h.nome}
                      <span className="ml-1 text-xs text-muted-foreground">{CATEGORIA_LABEL[h.categoria]}</span>
                    </span>
                    {sel && (
                      <Select className="h-7 text-xs" value={sel.nivel} disabled={salvando}
                        onChange={e => nivelDe(h.id, e.target.value as Nivel)}>
                        <option value="basico">Básico</option>
                        <option value="intermediario">Intermediário</option>
                        <option value="avancado">Avançado</option>
                      </Select>
                    )}
                  </div>
                )
              })}
            </div>

            <p className="text-xs text-muted-foreground">
              O que ficar desmarcado é removido do técnico ao salvar.
            </p>
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Remover habilidade" confirmLabel="Remover" destructive busy={salvando}
        onCancel={() => setAlvo(null)} onConfirm={() => void remover()}>
        <p><strong className="text-foreground">{alvo?.habilidade}</strong> deixa de constar para {alvo?.tecnico}. Ele passa a aparecer como não apto nas atividades que exigem essa habilidade.</p>
      </Confirm>
    </div>
  )
}

// ------------------------------------------------------------------ catálogo
function Catalogo({ catalogo, podeEditar, recarregar }: { catalogo: Habilidade[]; podeEditar: boolean; recarregar: () => Promise<void> }) {
  const [edit, setEdit] = useState<Partial<Habilidade> | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.salvarHabilidade({ ...edit, exige_validade: false }); setEdit(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        {podeEditar && <Button size="sm" onClick={() => { setEdit({ nome: '', categoria: 'tecnica', ativo: true }); setErro(null) }}><Plus className="h-4 w-4" /> Nova habilidade</Button>}
      </div>
      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Habilidade</th><th className="px-3 py-2.5">Categoria</th>
              <th className="px-3 py-2.5">Descrição</th>
              <th className="px-3 py-2.5 text-center">Ativa</th><th className="w-12 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {catalogo.map(h => (
              <tr key={h.id} className={`border-b last:border-0 ${!h.ativo ? 'opacity-50' : ''}`}>
                <td className="px-3 py-2.5 font-medium">{h.nome}</td>
                <td className="px-3 py-2.5 text-xs">{CATEGORIA_LABEL[h.categoria]}</td>
                <td className="px-3 py-2.5 text-xs text-muted-foreground">{h.descricao ?? '—'}</td>
                <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${h.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                <td className="px-3 py-2.5 text-right">
                  {podeEditar && <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...h }); setErro(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>}
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
            <Field label="Nome *"><Input value={edit.nome ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, nome: e.target.value })} placeholder="Ex: NR-12" /></Field>
            <Field label="Categoria">
              <Select className="w-full" value={edit.categoria ?? 'tecnica'} disabled={salvando}
                onChange={e => setEdit({ ...edit, categoria: e.target.value as Habilidade['categoria'] })}>
                <option value="tecnica">Técnica</option><option value="seguranca">Segurança</option>
                <option value="habilitacao">Habilitação</option><option value="outra">Outra</option>
              </Select>
            </Field>
            <Field label="Descrição"><Textarea rows={2} value={edit.descricao ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, descricao: e.target.value })} /></Field>
            <ToggleRow label="Ativa" description="Habilidade inativa não aparece para atribuição nem nos requisitos."
              checked={edit.ativo !== false} onChange={v => setEdit({ ...edit, ativo: v })} disabled={salvando} />
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
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
