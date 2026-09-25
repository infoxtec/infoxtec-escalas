import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle, ChevronDown, ChevronRight, Edit2, FileStack, ListChecks, Paperclip, Plus, RefreshCw, ShieldCheck, Trash2,
} from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, Textarea, ToggleRow, useToast } from '../components/ui'
import DocumentosLote from '../components/DocumentosLote'
import DocumentosArquivos from '../components/DocumentosArquivos'
import { api, erroMsg } from '../lib/api'
import { CATEGORIA_LABEL, NIVEL_LABEL, SITUACAO_DOC, diasAte, formatDate } from '../lib/types'
import type { Habilidade, Nivel, Tecnico, TecnicoDocumentos, TipoAtividade, TipoDocumento } from '../lib/types'

type Secao = 'documentos' | 'habilidades' | 'tipos'

export default function HabilidadesPage({ tecnicos, podeEditar }: { tecnicos: Tecnico[]; podeEditar: boolean }) {
  const [secao, setSecao] = useState<Secao>('documentos')
  const [porTecnico, setPorTecnico] = useState<TecnicoDocumentos[]>([])
  const [tiposDoc, setTiposDoc] = useState<TipoDocumento[]>([])
  const [catalogo, setCatalogo] = useState<Habilidade[]>([])
  const [tipos, setTipos] = useState<TipoAtividade[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try {
      const [d, td, h, ta] = await Promise.all([
        api.documentosPorTecnico(), api.tiposDocumento(), api.habilidades(), api.tiposAtividade(),
      ])
      setPorTecnico(d); setTiposDoc(td); setCatalogo(h); setTipos(ta)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const vencidos = porTecnico.filter(t => t.ativo && !t.perfil_teste).reduce((s, t) => s + t.vencidos + t.sem_data, 0)

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
          {aba('documentos', 'Documentos', vencidos)}
          {aba('habilidades', 'Habilidades')}
          {aba('tipos', 'Tipos de atividade')}
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}>
          <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
        </Button>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      {secao === 'documentos' && (
        <Documentos porTecnico={porTecnico} tiposDoc={tiposDoc} tecnicos={tecnicos}
          podeEditar={podeEditar} recarregar={carregar} />
      )}
      {secao === 'habilidades' && <Catalogo catalogo={catalogo} podeEditar={podeEditar} recarregar={carregar} />}
      {secao === 'tipos' && <Tipos tipos={tipos} catalogo={catalogo} tiposDoc={tiposDoc} podeEditar={podeEditar} recarregar={carregar} />}
    </div>
  )
}

// ------------------------------------------------------------------ documentos por técnico
function Documentos({ porTecnico, tiposDoc, tecnicos, podeEditar, recarregar }: {
  porTecnico: TecnicoDocumentos[]; tiposDoc: TipoDocumento[]; tecnicos: Tecnico[]
  podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const toast = useToast()
  const [filtro, setFiltro] = useState('')
  const [soPendentes, setSoPendentes] = useState(false)
  const [abertos, setAbertos] = useState<Set<string>>(new Set())
  const [lote, setLote] = useState<{ id: string; nome: string } | null>(null)
  const [edit, setEdit] = useState<{ tecnico: string; nome: string; tipo: string; validade: string } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erroForm, setErroForm] = useState<string | null>(null)
  const [alvo, setAlvo] = useState<{ tecnico: string; tipo: string; nome: string; documento: string } | null>(null)

  const lista = useMemo(() => {
    const q = filtro.trim().toLocaleLowerCase('pt-BR')
    return porTecnico.filter(t => {
      if (soPendentes && t.vencidos + t.sem_data + t.vencendo === 0) return false
      if (!q) return true
      return `${t.tecnico} ${t.funcao} ${t.documentos.map(d => d.documento).join(' ')}`.toLocaleLowerCase('pt-BR').includes(q)
    })
  }, [porTecnico, filtro, soPendentes])

  const alternar = (id: string) => setAbertos(s => {
    const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n
  })

  const salvar = async () => {
    if (!edit) return
    setErroForm(null)
    if (!edit.tipo) return setErroForm('Escolha o documento.')
    if (!edit.validade) return setErroForm('Informe a validade.')
    setSalvando(true)
    try {
      await api.definirDocumento(edit.tecnico, edit.tipo, edit.validade)
      toast('Validade registrada.'); setEdit(null); await recarregar()
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const remover = async () => {
    if (!alvo) return
    setSalvando(true)
    try { await api.removerDocumentoTecnico(alvo.tecnico, alvo.tipo); setAlvo(null); await recarregar() }
    catch (e) { setErroForm(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <Input placeholder="Buscar por técnico, função ou documento..." value={filtro}
          onChange={e => setFiltro(e.target.value)} className="w-80" />
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <input type="checkbox" checked={soPendentes} onChange={e => setSoPendentes(e.target.checked)} />
          Só quem tem pendência
        </label>
      </div>

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="w-8 px-2 py-2.5" /><th className="px-3 py-2.5">Técnico</th>
              <th className="px-3 py-2.5">Função</th><th className="px-3 py-2.5">Documentos</th>
              <th className="w-28 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lista.length === 0 && (
              <tr><td colSpan={5} className="py-12 text-center text-muted-foreground">Nenhum técnico encontrado</td></tr>
            )}
            {lista.map(t => {
              const aberto = abertos.has(t.tecnico_id)
              return (
                <>
                  <tr key={t.tecnico_id} className={`cursor-pointer border-b hover:bg-muted/30 ${!t.ativo ? 'opacity-50' : ''}`}
                    onClick={() => alternar(t.tecnico_id)}>
                    <td className="px-2 py-2.5 text-muted-foreground">
                      {aberto ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}
                    </td>
                    <td className="px-3 py-2.5 font-medium">
                      {t.tecnico}
                      {t.perfil_teste && <span className="ml-2 rounded bg-purple-100 px-1 py-0.5 text-[10px] font-medium text-purple-800 dark:bg-purple-900/30 dark:text-purple-300">teste</span>}
                    </td>
                    <td className="px-3 py-2.5 text-xs text-muted-foreground">{t.funcao}</td>
                    <td className="px-3 py-2.5">
                      <div className="flex flex-wrap gap-1">
                        {t.documentos.length === 0 && <span className="text-xs text-muted-foreground">nenhum cadastrado</span>}
                        {t.vencidos > 0 && <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-900/30 dark:text-red-300">{t.vencidos} vencido(s)</span>}
                        {t.sem_data > 0 && <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800 dark:bg-red-900/30 dark:text-red-300">{t.sem_data} sem data</span>}
                        {t.vencendo > 0 && <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900/30 dark:text-amber-300">{t.vencendo} vencendo</span>}
                        {t.documentos.length > 0 && t.vencidos + t.sem_data + t.vencendo === 0 && (
                          <span className="inline-flex items-center gap-1 rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900/30 dark:text-green-300">
                            <ShieldCheck className="h-3 w-3" />{t.documentos.length} em dia
                          </span>
                        )}
                      </div>
                    </td>
                    <td className="px-3 py-2.5 text-right" onClick={e => e.stopPropagation()}>
                      {podeEditar && (
                        <div className="flex justify-end gap-1">
                          <Button variant="ghost" size="icon" aria-label="Enviar vários documentos" title="Enviar vários documentos ou uma pasta"
                            onClick={() => setLote({ id: t.tecnico_id, nome: t.tecnico })}>
                            <FileStack className="h-3.5 w-3.5" />
                          </Button>
                          <Button variant="ghost" size="icon" aria-label="Informar validade" title="Informar validade à mão"
                            onClick={() => { setEdit({ tecnico: t.tecnico_id, nome: t.tecnico, tipo: '', validade: '' }); setErroForm(null) }}>
                            <Plus className="h-3.5 w-3.5" />
                          </Button>
                        </div>
                      )}
                    </td>
                  </tr>
                  {aberto && (
                    <tr key={`${t.tecnico_id}-det`} className="border-b bg-muted/20">
                      <td />
                      <td colSpan={4} className="px-3 py-3">
                        {t.documentos.length === 0 ? (
                          <p className="text-xs text-muted-foreground">
                            Nenhum documento cadastrado.{podeEditar && ' Use os botões à direita para enviar arquivos ou informar a validade.'}
                          </p>
                        ) : (
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-left text-muted-foreground">
                                <th className="py-1 pr-3">Documento</th><th className="py-1 pr-3">Validade</th>
                                <th className="py-1 pr-3">Situação</th><th className="py-1 pr-3">Arquivos</th><th className="w-16 py-1" />
                              </tr>
                            </thead>
                            <tbody>
                              {t.documentos.map(d => {
                                const dias = diasAte(d.validade)
                                const s = SITUACAO_DOC[d.situacao]
                                return (
                                  <tr key={d.tipo_documento_id} className="border-t border-border/50">
                                    <td className="py-1.5 pr-3 font-medium">{d.documento}</td>
                                    <td className="py-1.5 pr-3 font-mono">{d.validade ? formatDate(d.validade) : '—'}</td>
                                    <td className="py-1.5 pr-3">
                                      <span className={`rounded-full px-2 py-0.5 font-medium ${s.classe}`}>
                                        {s.label}{dias !== null && dias >= 0 && dias <= 60 ? ` · ${dias}d` : ''}
                                      </span>
                                    </td>
                                    <td className="py-1.5 pr-3 text-muted-foreground">{d.arquivos > 0 ? `${d.arquivos} anexo(s)` : 'sem anexo'}</td>
                                    <td className="py-1.5 text-right">
                                      {podeEditar && (
                                        <div className="flex justify-end gap-1">
                                          <button type="button" title="Alterar validade"
                                            onClick={() => { setEdit({ tecnico: t.tecnico_id, nome: t.tecnico, tipo: d.tipo_documento_id, validade: d.validade ?? '' }); setErroForm(null) }}
                                            className="text-muted-foreground hover:text-foreground"><Edit2 className="h-3 w-3" /></button>
                                          <button type="button" title="Remover do técnico"
                                            onClick={() => setAlvo({ tecnico: t.tecnico_id, tipo: d.tipo_documento_id, nome: t.tecnico, documento: d.documento })}
                                            className="text-muted-foreground hover:text-destructive"><Trash2 className="h-3 w-3" /></button>
                                        </div>
                                      )}
                                    </td>
                                  </tr>
                                )
                              })}
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

      <DocumentosArquivos tecnicos={tecnicos} tiposDoc={tiposDoc} podeEditar={podeEditar} aoMudar={recarregar} />

      {lote && (
        <DocumentosLote aberto tecnicoId={lote.id} tecnicoNome={lote.nome} tipos={tiposDoc}
          aoFechar={() => setLote(null)} aoConcluir={recarregar} />
      )}

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} width="max-w-md"
        title={`Validade de documento — ${edit?.nome ?? ''}`}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="Documento *">
              <Select className="w-full" value={edit.tipo} disabled={salvando}
                onChange={e => setEdit({ ...edit, tipo: e.target.value })}>
                <option value="">Selecione...</option>
                {tiposDoc.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
              </Select>
            </Field>
            <Field label="Validade *" hint="Para anexar o arquivo junto, use o botão de envio de documentos.">
              <Input type="date" value={edit.validade} disabled={salvando}
                onChange={e => setEdit({ ...edit, validade: e.target.value })} />
            </Field>
            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Remover documento do técnico" confirmLabel="Remover" destructive busy={salvando}
        onCancel={() => setAlvo(null)} onConfirm={() => void remover()}>
        <p><strong className="text-foreground">{alvo?.documento}</strong> deixa de constar para {alvo?.nome}, e ele passa a aparecer como não apto nas atividades que o exigem. Os arquivos enviados continuam na lista abaixo.</p>
      </Confirm>
    </div>
  )
}

// ------------------------------------------------------------------ catálogo de habilidades
function Catalogo({ catalogo, podeEditar, recarregar }: { catalogo: Habilidade[]; podeEditar: boolean; recarregar: () => Promise<void> }) {
  const toast = useToast()
  const [edit, setEdit] = useState<Partial<Habilidade> | null>(null)
  const [alvo, setAlvo] = useState<Habilidade | null>(null)
  const [forcar, setForcar] = useState(false)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.salvarHabilidade(edit); setEdit(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }
  const excluir = async () => {
    if (!alvo) return
    setErro(null); setSalvando(true)
    try {
      const r = await api.excluirHabilidade(alvo.id, forcar)
      toast(`${r.nome} excluída.`); setAlvo(null); setForcar(false); await recarregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-3">
        <p className="text-xs text-muted-foreground">
          Habilidade é o que o técnico sabe fazer e <strong>não vence</strong>. Documentos com validade
          (NR, CNH, ASO) ficam na aba Documentos. A atribuição por técnico é feita no cadastro, em <strong>Técnicos</strong>.
        </p>
        {podeEditar && <Button size="sm" onClick={() => { setEdit({ nome: '', categoria: 'tecnica', ativo: true }); setErro(null) }}><Plus className="h-4 w-4" /> Nova habilidade</Button>}
      </div>

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Habilidade</th><th className="px-3 py-2.5">Categoria</th>
              <th className="px-3 py-2.5">Descrição</th><th className="px-3 py-2.5 text-center">Ativa</th>
              <th className="w-20 px-3 py-2.5" />
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
                  {podeEditar && (
                    <div className="flex justify-end gap-1">
                      <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...h }); setErro(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>
                      <Button variant="ghost" size="icon" aria-label="Excluir" className="text-destructive hover:bg-destructive/10"
                        onClick={() => { setAlvo(h); setForcar(false); setErro(null) }}><Trash2 className="h-3.5 w-3.5" /></Button>
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
            <Field label="Nome *"><Input value={edit.nome ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, nome: e.target.value })} placeholder="Ex: Solda de fibra" /></Field>
            <Field label="Categoria">
              <Select className="w-full" value={edit.categoria ?? 'tecnica'} disabled={salvando}
                onChange={e => setEdit({ ...edit, categoria: e.target.value as Habilidade['categoria'] })}>
                <option value="tecnica">Técnica</option><option value="seguranca">Segurança</option>
                <option value="habilitacao">Habilitação</option><option value="outra">Outra</option>
              </Select>
            </Field>
            <Field label="Descrição"><Textarea rows={2} value={edit.descricao ?? ''} disabled={salvando} onChange={e => setEdit({ ...edit, descricao: e.target.value })} /></Field>
            <ToggleRow label="Ativa" description="Inativa não aparece para atribuição nem nos requisitos."
              checked={edit.ativo !== false} onChange={v => setEdit({ ...edit, ativo: v })} disabled={salvando} />
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Excluir habilidade" confirmLabel={forcar ? 'Excluir mesmo assim' : 'Excluir'} destructive
        busy={salvando} onCancel={() => { setAlvo(null); setForcar(false) }} onConfirm={() => void excluir()}>
        <p><strong className="text-foreground">{alvo?.nome}</strong> sai do catálogo, junto com as atribuições aos técnicos e as exigências dos tipos de atividade.</p>
        <label className="flex items-center gap-2 text-xs">
          <input type="checkbox" checked={forcar} onChange={e => setForcar(e.target.checked)} disabled={salvando} />
          Excluir mesmo estando em uso
        </label>
        {erro && <ErrorBox>{erro}</ErrorBox>}
      </Confirm>
    </div>
  )
}

// ------------------------------------------------------------------ tipos de atividade
function Tipos({ tipos, catalogo, tiposDoc, podeEditar, recarregar }: {
  tipos: TipoAtividade[]; catalogo: Habilidade[]; tiposDoc: TipoDocumento[]
  podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const [edit, setEdit] = useState<{
    id?: string; nome: string; descricao: string; ativo: boolean
    requisitos: { habilidade_id: string; nivel_minimo: Nivel }[]
    documentos: { tipo_documento_id: string }[]
  } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const alternarHab = (id: string) => setEdit(e => {
    if (!e) return e
    const tem = e.requisitos.find(r => r.habilidade_id === id)
    return { ...e, requisitos: tem ? e.requisitos.filter(r => r.habilidade_id !== id) : [...e.requisitos, { habilidade_id: id, nivel_minimo: 'basico' }] }
  })
  const alternarDoc = (id: string) => setEdit(e => {
    if (!e) return e
    const tem = e.documentos.find(d => d.tipo_documento_id === id)
    return { ...e, documentos: tem ? e.documentos.filter(d => d.tipo_documento_id !== id) : [...e.documentos, { tipo_documento_id: id }] }
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
        <p className="text-xs text-muted-foreground">
          O tipo de atividade define o que o técnico precisa ter: <strong>habilidades</strong> no nível exigido e
          <strong> documentos</strong> válidos. Quem não atende aparece com aviso ao montar a escala.
        </p>
        {podeEditar && <Button size="sm" onClick={() => { setEdit({ nome: '', descricao: '', ativo: true, requisitos: [], documentos: [] }); setErro(null) }}><Plus className="h-4 w-4" /> Novo tipo</Button>}
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
                  onClick={() => { setEdit({ id: t.id, nome: t.nome, descricao: t.descricao ?? '', ativo: t.ativo,
                    requisitos: t.requisitos.map(r => ({ habilidade_id: r.habilidade_id, nivel_minimo: r.nivel_minimo })),
                    documentos: t.documentos.map(d => ({ tipo_documento_id: d.tipo_documento_id })) }); setErro(null) }}>
                  <Edit2 className="h-3.5 w-3.5" />
                </Button>
              )}
            </div>
            <div className="mt-2 flex flex-wrap gap-1.5">
              {t.requisitos.length === 0 && t.documentos.length === 0 && <span className="text-xs text-muted-foreground">Sem exigência</span>}
              {t.requisitos.map(r => (
                <span key={r.habilidade_id} className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 text-xs">
                  <ListChecks className="h-3 w-3" />{r.habilidade} · {NIVEL_LABEL[r.nivel_minimo]}
                </span>
              ))}
              {t.documentos.map(d => (
                <span key={d.tipo_documento_id} className="inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs text-amber-800 dark:bg-amber-900/30 dark:text-amber-300">
                  <Paperclip className="h-3 w-3" />{d.documento}
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
              <div className="max-h-44 space-y-1 overflow-y-auto rounded-md border p-2">
                {catalogo.filter(h => h.ativo).map(h => {
                  const req = edit.requisitos.find(r => r.habilidade_id === h.id)
                  return (
                    <div key={h.id} className="flex items-center gap-2 text-sm">
                      <input type="checkbox" checked={!!req} disabled={salvando} onChange={() => alternarHab(h.id)} />
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

            <div className="space-y-2">
              <p className="text-xs font-medium text-muted-foreground">Documentos exigidos (precisam estar válidos)</p>
              <div className="max-h-44 space-y-1 overflow-y-auto rounded-md border p-2">
                {tiposDoc.filter(d => d.ativo).map(d => (
                  <label key={d.id} className="flex items-center gap-2 text-sm">
                    <input type="checkbox" disabled={salvando}
                      checked={!!edit.documentos.find(x => x.tipo_documento_id === d.id)}
                      onChange={() => alternarDoc(d.id)} />
                    <span>{d.nome}</span>
                  </label>
                ))}
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
