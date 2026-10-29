import { useCallback, useEffect, useState } from 'react'
import { Edit2, Loader2, Plus, Trash2 } from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, useToast } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import type { Feriado } from '../lib/types'

const ABRANGENCIA: Record<Feriado['abrangencia'], string> = {
  nacional: 'Nacional', estadual: 'Estadual', municipal: 'Municipal', facultativo: 'Ponto facultativo',
}

// Feriados por lugar (F4, migration 131): os nacionais vêm do sistema; estaduais, municipais e pontos facultativos
// são da plataforma. Valem para a conta, a empresa, o local ou o técnico daquele lugar (fn_feriado_da_escala).
export default function FeriadosPage() {
  const toast = useToast()
  const anoAtual = new Date().getFullYear()
  const [ano, setAno] = useState(anoAtual)
  const [lista, setLista] = useState<Feriado[] | null>(null)
  const [edit, setEdit] = useState<Partial<Feriado> | null>(null)
  const [remover, setRemover] = useState<Feriado | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setLista(null)
    try { setLista(await api.plataformaFeriados(ano)) } catch (e) { setErro(erroMsg(e)) }
  }, [ano])
  useEffect(() => { void carregar() }, [carregar])

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.plataformaSalvarFeriado(edit); toast('Feriado salvo.'); setEdit(null); await carregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const confirmarRemocao = async () => {
    if (!remover) return
    setSalvando(true)
    try { await api.plataformaRemoverFeriado(remover.id); toast('Feriado removido.'); setRemover(null); await carregar() }
    catch (e) { setErro(erroMsg(e)); setRemover(null) }
    finally { setSalvando(false) }
  }

  const set = (k: keyof Feriado, v: string) => setEdit(p => p && ({ ...p, [k]: v }))

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold">Feriados</h2>
          <p className="text-xs text-muted-foreground">Nacionais vêm do sistema. Estaduais e municipais valem para quem tem sede, local ou cidade naquele lugar.</p>
        </div>
        <div className="flex gap-2">
          <Select value={ano} onChange={e => setAno(Number(e.target.value))} aria-label="Ano">
            {[anoAtual - 1, anoAtual, anoAtual + 1].map(a => <option key={a} value={a}>{a}</option>)}
          </Select>
          <Button size="sm" onClick={() => { setEdit({ data: '', nome: '', abrangencia: 'municipal', uf: '', municipio: '' }); setErro(null) }}>
            <Plus className="h-4 w-4" /> Novo feriado
          </Button>
        </div>
      </div>

      {erro && !edit && <ErrorBox>{erro}</ErrorBox>}
      {!lista ? (erro ? null : <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>) : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Data</th><th className="px-3 py-2">Feriado</th><th className="px-3 py-2">Abrangência</th>
              <th className="px-3 py-2">Lugar</th><th className="w-20" />
            </tr></thead>
            <tbody>
              {lista.length === 0 && <tr><td colSpan={5} className="px-3 py-6 text-center text-xs text-muted-foreground">Nenhum feriado em {ano}.</td></tr>}
              {lista.map(f => (
                <tr key={f.id} className="border-b last:border-0 hover:bg-muted/30">
                  <td className="px-3 py-2.5 text-xs">{new Date(f.data + 'T12:00:00').toLocaleDateString('pt-BR', { weekday: 'short', day: '2-digit', month: '2-digit' })}</td>
                  <td className="px-3 py-2.5 font-medium">{f.nome}</td>
                  <td className="px-3 py-2.5 text-xs">{ABRANGENCIA[f.abrangencia]}</td>
                  <td className="px-3 py-2.5 text-xs">{[f.municipio, f.uf].filter(Boolean).join(' / ') || <span className="text-muted-foreground">Brasil</span>}</td>
                  <td className="px-3 py-2.5 text-right">
                    {f.abrangencia !== 'nacional' && (<>
                      <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...f, uf: f.uf ?? '', municipio: f.municipio ?? '' }); setErro(null) }}>
                        <Edit2 className="h-3.5 w-3.5" />
                      </Button>
                      <Button variant="ghost" size="icon" aria-label="Remover" onClick={() => setRemover(f)}>
                        <Trash2 className="h-3.5 w-3.5" />
                      </Button>
                    </>)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar feriado' : 'Novo feriado'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <Field label="Data *"><Input type="date" value={edit.data ?? ''} onChange={e => set('data', e.target.value)} disabled={salvando} /></Field>
              <Field label="Abrangência *">
                <Select value={edit.abrangencia} onChange={e => set('abrangencia', e.target.value)} disabled={salvando}>
                  <option value="estadual">Estadual</option>
                  <option value="municipal">Municipal</option>
                  <option value="facultativo">Ponto facultativo</option>
                </Select>
              </Field>
            </div>
            <Field label="Nome *"><Input value={edit.nome ?? ''} onChange={e => set('nome', e.target.value)} disabled={salvando} /></Field>
            <div className="grid grid-cols-[5rem_1fr] gap-3">
              <Field label="UF"><Input value={edit.uf ?? ''} maxLength={2} onChange={e => set('uf', e.target.value.toUpperCase())} disabled={salvando} /></Field>
              <Field label="Município" hint="Estadual: só a UF. Municipal: UF e município. Ponto facultativo: em branco vale para o país.">
                <Input value={edit.municipio ?? ''} onChange={e => set('municipio', e.target.value)} disabled={salvando} />
              </Field>
            </div>
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!remover} title="Remover feriado" confirmLabel="Remover" destructive busy={salvando}
        onConfirm={() => void confirmarRemocao()} onCancel={() => setRemover(null)}>
        {remover && <p className="text-sm">Remover <strong>{remover.nome}</strong> ({[remover.municipio, remover.uf].filter(Boolean).join(' / ')})? A agenda e o ponto deixam de tratar o dia como feriado.</p>}
      </Confirm>
    </div>
  )
}
