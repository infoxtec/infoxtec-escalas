import { useCallback, useEffect, useState } from 'react'
import { Edit2, Info, Plus, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, Select, ToggleRow, useToast } from '../components/ui'
import { SortableTh, useSortable } from '../components/SortableTh'
import { api, erroMsg } from '../lib/api'
import { formatDateTime, PAPEL_LABEL } from '../lib/types'
import type { Papel, UsuarioPainel } from '../lib/types'

const DESCRICAO: Record<Papel, string> = {
  admin: 'Tudo, inclusive excluir técnicos e gerenciar usuários.',
  gestor: 'Cria escalas, muda status, edita técnicos e locais.',
  leitura: 'Só visualiza.',
}

export default function UsuariosPage() {
  const toast = useToast()
  const [lista, setLista] = useState<UsuarioPainel[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [edit, setEdit] = useState<{ email: string; nome: string; papel: Papel; ativo: boolean; novo: boolean } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erroForm, setErroForm] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try { setLista(await api.usuarios()) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const { sorted, thProps } = useSortable(lista, {
    nome: u => u.nome ?? u.email, email: u => u.email, papel: u => PAPEL_LABEL[u.papel], ativo: u => u.ativo,
  }, { key: 'nome' })

  const salvar = async () => {
    if (!edit) return
    setErroForm(null)
    if (!/^\S+@\S+\.\S+$/.test(edit.email.trim())) return setErroForm('Informe um e-mail válido.')
    setSalvando(true)
    try {
      await api.salvarUsuario({ email: edit.email.trim(), nome: edit.nome.trim(), papel: edit.papel, ativo: edit.ativo })
      toast(edit.novo ? 'Usuário liberado no painel.' : 'Usuário atualizado.')
      setEdit(null); await carregar()
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">Usuários do painel</h2>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}><RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar</Button>
          <Button size="sm" onClick={() => { setEdit({ email: '', nome: '', papel: 'gestor', ativo: true, novo: true }); setErroForm(null) }}><Plus className="h-4 w-4" /> Adicionar usuário</Button>
        </div>
      </div>

      <div className="flex items-start gap-2 rounded-md border bg-muted/40 p-3 text-xs text-muted-foreground">
        <Info className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
        <p>O acesso tem duas etapas: <strong className="text-foreground">1)</strong> convide a pessoa no Supabase em Authentication → Users → Invite user (ela recebe um e-mail e cria a própria senha); <strong className="text-foreground">2)</strong> cadastre aqui o mesmo e-mail com o papel desejado. Quem tem login mas não está nesta lista vê uma tela de acesso negado.</p>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50">
              <SortableTh {...thProps('nome')}>Nome</SortableTh>
              <SortableTh {...thProps('email')}>E-mail</SortableTh>
              <SortableTh {...thProps('papel')}>Papel</SortableTh>
              <SortableTh {...thProps('ativo')} align="center">Ativo</SortableTh>
              <th className="px-3 py-2.5 text-left text-xs font-semibold text-muted-foreground">Criado por</th>
              <th className="px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {sorted.map(u => (
              <tr key={u.email} className={`border-b last:border-0 ${!u.ativo ? 'opacity-50' : ''}`}>
                <td className="px-3 py-2.5 font-medium">{u.nome ?? '—'}</td>
                <td className="px-3 py-2.5 text-xs">{u.email}</td>
                <td className="px-3 py-2.5 text-xs">{PAPEL_LABEL[u.papel]}</td>
                <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${u.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                <td className="px-3 py-2.5 text-xs text-muted-foreground">{u.criado_por ?? '—'} · {formatDateTime(u.created_at)}</td>
                <td className="px-3 py-2.5 text-right">
                  <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ email: u.email, nome: u.nome ?? '', papel: u.papel, ativo: u.ativo, novo: false }); setErroForm(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.novo ? 'Adicionar usuário' : 'Editar usuário'} width="max-w-md"
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="E-mail *"><Input type="email" value={edit.email} disabled={!edit.novo || salvando} onChange={e => setEdit({ ...edit, email: e.target.value })} /></Field>
            <Field label="Nome"><Input value={edit.nome} disabled={salvando} onChange={e => setEdit({ ...edit, nome: e.target.value })} /></Field>
            <Field label="Papel" hint={DESCRICAO[edit.papel]}>
              <Select className="w-full" value={edit.papel} disabled={salvando} onChange={e => setEdit({ ...edit, papel: e.target.value as Papel })}>
                <option value="admin">Administrador</option><option value="gestor">Gestor</option><option value="leitura">Somente leitura</option>
              </Select>
            </Field>
            <ToggleRow label="Ativo" description="Desativado, o usuário perde o acesso ao painel na hora." checked={edit.ativo} onChange={v => setEdit({ ...edit, ativo: v })} disabled={salvando} />
            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
