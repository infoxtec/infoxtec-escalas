import { useCallback, useEffect, useState } from 'react'
import { Edit2, Loader2, Plus, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, ToggleRow } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import { cnpjValido, formatCnpj } from '../lib/types'
import type { Empresa } from '../lib/types'

const NOVA: Partial<Empresa> = { cnpj: '', razao_social: '', nome_fantasia: '', endereco: '', cidade: 'Salvador', uf: 'BA', empregadora: false, ativo: true }

// Empresas: empregadoras (dono do ponto dos funcionários) e clientes (dono dos locais).
// Base do Módulo Registro de Ponto (docs/modulo-registro-de-ponto/).
export default function EmpresasPage({ podeEditar }: { podeEditar: boolean }) {
  const [empresas, setEmpresas] = useState<Empresa[] | null>(null)
  const [edit, setEdit] = useState<Partial<Empresa> | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    try { setEmpresas(await api.empresas()) } catch (e) { setErro(erroMsg(e)) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const set = (k: keyof Empresa, v: string | boolean) => setEdit(p => ({ ...p, [k]: v }))

  const salvar = async () => {
    if (!edit) return
    setErro(null)
    if (!cnpjValido(edit.cnpj ?? '')) return setErro('CNPJ inválido.')
    if (!edit.razao_social?.trim()) return setErro('Razão social é obrigatória.')
    setSalvando(true)
    try { await api.salvarEmpresa(edit); await carregar(); setEdit(null) }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold">Empresas</h2>
          <p className="text-xs text-muted-foreground">Empregadoras (o ponto dos funcionários sai no CNPJ delas) e clientes (donas dos locais).</p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
          {podeEditar && <Button size="sm" onClick={() => { setEdit({ ...NOVA }); setErro(null) }}><Plus className="h-4 w-4" /> Nova empresa</Button>}
        </div>
      </div>

      {erro && !edit && <ErrorBox>{erro}</ErrorBox>}
      {!empresas ? <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Razão social</th><th className="px-3 py-2">CNPJ</th><th className="px-3 py-2">Cidade</th>
              <th className="px-3 py-2 text-center">Empregadora</th><th className="px-3 py-2 text-center">Ativa</th><th className="w-12" />
            </tr></thead>
            <tbody>
              {empresas.length === 0 ? (
                <tr><td colSpan={6} className="py-12 text-center text-muted-foreground">Nenhuma empresa cadastrada</td></tr>
              ) : empresas.map(e => (
                <tr key={e.id} className={`border-b last:border-0 hover:bg-muted/30 ${!e.ativo ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2.5"><p className="font-medium">{e.razao_social}</p>{e.nome_fantasia && <p className="text-xs text-muted-foreground">{e.nome_fantasia}</p>}</td>
                  <td className="px-3 py-2.5 font-mono text-xs">{formatCnpj(e.cnpj)}</td>
                  <td className="px-3 py-2.5 text-xs">{e.cidade}/{e.uf}</td>
                  <td className="px-3 py-2.5 text-center text-xs">{e.empregadora ? <span className="font-medium text-primary">Sim</span> : <span className="text-muted-foreground">Não</span>}</td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${e.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-right">{podeEditar && <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...e, cnpj: formatCnpj(e.cnpj) }); setErro(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar empresa' : 'Nova empresa'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="CNPJ *"><Input value={edit.cnpj ?? ''} onChange={e => set('cnpj', e.target.value)} placeholder="00.000.000/0000-00" disabled={salvando} /></Field>
            <Field label="Razão social *"><Input value={edit.razao_social ?? ''} onChange={e => set('razao_social', e.target.value)} disabled={salvando} /></Field>
            <Field label="Nome fantasia"><Input value={edit.nome_fantasia ?? ''} onChange={e => set('nome_fantasia', e.target.value)} disabled={salvando} /></Field>
            <Field label="Endereço"><Input value={edit.endereco ?? ''} onChange={e => set('endereco', e.target.value)} disabled={salvando} /></Field>
            <div className="grid grid-cols-[1fr_80px] gap-3">
              <Field label="Cidade"><Input value={edit.cidade ?? ''} onChange={e => set('cidade', e.target.value)} disabled={salvando} /></Field>
              <Field label="UF"><Input value={edit.uf ?? ''} maxLength={2} onChange={e => set('uf', e.target.value.toUpperCase())} disabled={salvando} /></Field>
            </div>
            <ToggleRow label="Empregadora" description="Os funcionários desta empresa batem ponto no CNPJ dela."
              checked={!!edit.empregadora} onChange={v => set('empregadora', v)} disabled={salvando} />
            {edit.id && <ToggleRow label="Ativa" checked={!!edit.ativo} onChange={v => set('ativo', v)} disabled={salvando} />}
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
