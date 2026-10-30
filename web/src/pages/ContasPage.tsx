import { useCallback, useEffect, useState } from 'react'
import { Edit2, Loader2, Plus, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, ToggleRow, useToast } from '../components/ui'
import { api, convidarUsuario, erroMsg, mensagemConvite } from '../lib/api'
import type { ContaPlataforma } from '../lib/types'

const MODULOS: { id: 'escala' | 'ponto'; nome: string }[] = [
  { id: 'escala', nome: 'Escala (agenda e WhatsApp)' },
  { id: 'ponto', nome: 'Registro de ponto' },
]

interface Edicao {
  id?: string; nome: string; ativa: boolean; modulos: string[]; admin_email: string; admin_nome: string; uf: string; municipio: string
  // canal de WhatsApp da conta (F5a, migration 137); a chave nunca volta do banco
  canal_instancia: string; canal_chave: string; canal_ativo: boolean; canal_com_chave: boolean; canal_original: string
}

// Contas dos clientes (multiempresa F3c, decisão 117): só a plataforma cria e altera. O administrador da conta nova
// recebe o convite por e-mail ao salvar (decisão 120).
export default function ContasPage() {
  const toast = useToast()
  const [contas, setContas] = useState<ContaPlataforma[] | null>(null)
  const [edit, setEdit] = useState<Edicao | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [canais, setCanais] = useState<Awaited<ReturnType<typeof api.plataformaCanais>>>([])

  const carregar = useCallback(async () => {
    try { setContas(await api.plataformaContas()) } catch (e) { setErro(erroMsg(e)) }
    api.plataformaCanais().then(setCanais).catch(() => setCanais([]))
  }, [])

  useEffect(() => { void carregar() }, [carregar])

  const alternarModulo = (m: string, v: boolean) =>
    setEdit(p => p && ({ ...p, modulos: v ? [...p.modulos, m] : p.modulos.filter(x => x !== m) }))

  const salvar = async () => {
    if (!edit) return
    setErro(null)
    if (edit.nome.trim().length < 2) return setErro('Informe o nome da conta.')
    if (edit.modulos.length === 0) return setErro('Escolha ao menos um módulo.')
    if (!edit.id && !edit.admin_email.includes('@')) return setErro('Informe o e-mail do administrador.')
    if (edit.uf && !/^[A-Z]{2}$/.test(edit.uf)) return setErro('UF com duas letras (ex.: BA).')
    if (edit.municipio.trim() && !edit.uf) return setErro('Informe a UF da sede junto com o município.')
    setSalvando(true)
    try {
      if (edit.id) {
        await api.plataformaSalvarConta(edit.id, edit.nome, edit.ativa, edit.modulos, edit.uf, edit.municipio)
        const mudouCanal = edit.canal_instancia.trim() && (edit.canal_instancia.trim() !== edit.canal_original || edit.canal_chave.trim()
          || edit.canal_ativo !== (canais.find(k => k.conta_id === edit.id)?.ativo ?? true))
        if (mudouCanal) await api.plataformaSalvarCanal(edit.id, edit.canal_instancia, edit.canal_chave, edit.canal_ativo)
      } else {
        const id = await api.plataformaCriarConta(edit.nome, edit.admin_email, edit.admin_nome, edit.modulos, edit.uf, edit.municipio)
        const email = edit.admin_email.trim().toLowerCase()
        toast(mensagemConvite(email, await convidarUsuario(email, id)))
      }
      await carregar(); setEdit(null)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold">Contas</h2>
          <p className="text-xs text-muted-foreground">Clientes da plataforma. Cada conta vê só os próprios dados.</p>
        </div>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
          <Button size="sm" onClick={() => { setEdit({ nome: '', ativa: true, modulos: ['escala', 'ponto'], admin_email: '', admin_nome: '', uf: '', municipio: '', canal_instancia: '', canal_chave: '', canal_ativo: true, canal_com_chave: false, canal_original: '' }); setErro(null) }}>
            <Plus className="h-4 w-4" /> Nova conta
          </Button>
        </div>
      </div>

      {erro && !edit && <ErrorBox>{erro}</ErrorBox>}
      {!contas ? (erro ? null : <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>) : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Conta</th><th className="px-3 py-2">Sede</th><th className="px-3 py-2">Administradores</th><th className="px-3 py-2">Módulos</th>
              <th className="px-3 py-2">WhatsApp</th><th className="px-3 py-2 text-center">Usuários</th><th className="px-3 py-2 text-center">Ativa</th><th className="w-12" />
            </tr></thead>
            <tbody>
              {contas.map(c => (
                <tr key={c.id} className={`border-b last:border-0 hover:bg-muted/30 ${!c.ativa ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2.5"><p className="font-medium">{c.nome}</p>
                    <p className="text-xs text-muted-foreground">desde {new Date(c.criada_em).toLocaleDateString('pt-BR')}</p></td>
                  <td className="px-3 py-2.5 text-xs">{c.uf ? [c.municipio, c.uf].filter(Boolean).join(' / ') : <span className="text-muted-foreground">sem sede</span>}</td>
                  <td className="px-3 py-2.5 text-xs">{c.admins.join(', ') || <span className="text-muted-foreground">nenhum</span>}</td>
                  <td className="px-3 py-2.5 text-xs">{c.modulos.join(', ')}</td>
                  <td className="px-3 py-2.5 text-xs">{(() => { const k = canais.find(x => x.conta_id === c.id)
                    return !k?.instancia ? <span className="text-amber-600">sem canal</span>
                      : <span className={k.ativo ? '' : 'text-muted-foreground line-through'}>{k.instancia}{k.da_instalacao ? ' (instalação)' : ''}</span> })()}</td>
                  <td className="px-3 py-2.5 text-center text-xs">{c.membros}</td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${c.ativa ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-right">
                    <Button variant="ghost" size="icon" aria-label="Editar"
                      onClick={() => { const k = canais.find(x => x.conta_id === c.id); setEdit({ id: c.id, nome: c.nome, ativa: c.ativa, modulos: c.modulos, admin_email: '', admin_nome: '', uf: c.uf ?? '', municipio: c.municipio ?? '', canal_instancia: k?.da_instalacao ? '' : k?.instancia ?? '', canal_chave: '', canal_ativo: k?.ativo ?? true, canal_com_chave: !!k?.com_chave, canal_original: k?.da_instalacao ? '' : k?.instancia ?? '' }); setErro(null) }}>
                      <Edit2 className="h-3.5 w-3.5" />
                    </Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar conta' : 'Nova conta'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <Field label="Nome da conta *"><Input value={edit.nome} onChange={e => setEdit({ ...edit, nome: e.target.value })} disabled={salvando} /></Field>
            {!edit.id && (<>
              <Field label="E-mail do administrador *" hint="Ao salvar, ele recebe por e-mail o convite para criar a senha.">
                <Input type="email" value={edit.admin_email} onChange={e => setEdit({ ...edit, admin_email: e.target.value })} disabled={salvando} />
              </Field>
              <Field label="Nome do administrador"><Input value={edit.admin_nome} onChange={e => setEdit({ ...edit, admin_nome: e.target.value })} disabled={salvando} /></Field>
            </>)}
            <div className="grid grid-cols-[1fr_5rem] gap-3">
              <Field label="Município da sede" hint="Com a UF, define os feriados estaduais e municipais da conta.">
                <Input value={edit.municipio} onChange={e => setEdit({ ...edit, municipio: e.target.value })} disabled={salvando} />
              </Field>
              <Field label="UF"><Input value={edit.uf} maxLength={2} onChange={e => setEdit({ ...edit, uf: e.target.value.toUpperCase() })} disabled={salvando} /></Field>
            </div>
            {MODULOS.map(m => (
              <ToggleRow key={m.id} label={m.nome} checked={edit.modulos.includes(m.id)} onChange={v => alternarModulo(m.id, v)} disabled={salvando} />
            ))}
            {edit.id && (canais.find(k => k.conta_id === edit.id)?.da_instalacao
              ? <p className="text-xs text-muted-foreground">WhatsApp: canal da instalação ({canais.find(k => k.conta_id === edit.id)?.instancia}).</p>
              : <div className="space-y-2 rounded-md border p-3">
                  <p className="text-sm font-medium">WhatsApp da conta</p>
                  <p className="text-xs text-muted-foreground">Cada cliente tem a sua instância na Evolution (decisão 108). Sem canal, a conta não envia mensagens.</p>
                  <div className="grid grid-cols-2 gap-3">
                    <Field label="Instância"><Input value={edit.canal_instancia} onChange={e => setEdit({ ...edit, canal_instancia: e.target.value.toLowerCase() })} placeholder="cliente-x" disabled={salvando} /></Field>
                    <Field label="Chave (token) da instância" hint={edit.canal_com_chave ? 'Guardada. Em branco mantém a atual.' : 'Obrigatória no primeiro cadastro.'}>
                      <Input type="password" autoComplete="off" value={edit.canal_chave} onChange={e => setEdit({ ...edit, canal_chave: e.target.value })} disabled={salvando} />
                    </Field>
                  </div>
                  <ToggleRow label="Canal ativo" checked={edit.canal_ativo} onChange={v => setEdit({ ...edit, canal_ativo: v })} disabled={salvando} />
                </div>)}
            {edit.id && <ToggleRow label="Ativa" description="Conta desativada: ninguém dela entra no painel; os dados ficam guardados."
              checked={edit.ativa} onChange={v => setEdit({ ...edit, ativa: v })} disabled={salvando} />}
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
