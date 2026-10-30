import { useCallback, useEffect, useState } from 'react'
import { Edit2, Loader2, Mail, Plus, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, ToggleRow, useToast } from '../components/ui'
import { api, convidarUsuario, erroMsg, mensagemConvite } from '../lib/api'
import type { ContaPlataforma } from '../lib/types'

const MODULOS: { id: 'escala' | 'ponto'; nome: string }[] = [
  { id: 'escala', nome: 'Escala (agenda e WhatsApp)' },
  { id: 'ponto', nome: 'Registro de ponto' },
]

interface Edicao { id?: string; nome: string; ativa: boolean; modulos: string[]; admin_email: string; admin_nome: string; uf: string; municipio: string }

// Contas dos clientes (multiempresa F3c, decisão 117): só a plataforma cria e altera. O administrador da conta nova
// recebe o convite por e-mail ao salvar (decisão 120).
export default function ContasPage() {
  const toast = useToast()
  const [contas, setContas] = useState<ContaPlataforma[] | null>(null)
  const [edit, setEdit] = useState<Edicao | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [alertas, setAlertas] = useState<Awaited<ReturnType<typeof api.plataformaAlertas>> | null>(null)
  const [testando, setTestando] = useState(false)
  const [monitor, setMonitor] = useState<{ ligado: boolean; final: string | null } | null>(null)
  const [pingUrl, setPingUrl] = useState('')

  const carregar = useCallback(async () => {
    try { setContas(await api.plataformaContas()) } catch (e) { setErro(erroMsg(e)) }
    api.plataformaAlertas().then(setAlertas).catch(() => setAlertas(null))
    api.plataformaMonitor().then(setMonitor).catch(() => setMonitor(null))
  }, [])

  // e-mail de teste pela fila dos alertas (Edge Function alerta-email, migration 135)
  const testarAlerta = async () => {
    setTestando(true)
    try { await api.plataformaTestarAlerta(); toast('Teste enviado. Confira a caixa em 1 a 2 minutos e clique em Atualizar.') }
    catch (e) { toast(erroMsg(e)) }
    finally { setTestando(false) }
  }
  // monitor externo (healthchecks.io, migration 136): o motor chama o endereço a cada minuto
  const salvarMonitor = async (url: string) => {
    try { await api.plataformaSalvarMonitor(url); setPingUrl(''); toast(url ? 'Monitor externo ligado.' : 'Monitor externo desligado.'); await carregar() }
    catch (e) { toast(erroMsg(e)) }
  }
  const quando = (t: string | null) => t ? new Date(t).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—'
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
      if (edit.id) await api.plataformaSalvarConta(edit.id, edit.nome, edit.ativa, edit.modulos, edit.uf, edit.municipio)
      else {
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
          <Button size="sm" onClick={() => { setEdit({ nome: '', ativa: true, modulos: ['escala', 'ponto'], admin_email: '', admin_nome: '', uf: '', municipio: '' }); setErro(null) }}>
            <Plus className="h-4 w-4" /> Nova conta
          </Button>
        </div>
      </div>

      {alertas && (
        <div className="space-y-2 rounded-md border p-3 text-xs">
          <div className="flex items-center justify-between">
            <p className="text-sm font-medium">Alerta do WhatsApp por e-mail</p>
            <Button variant="outline" size="sm" onClick={() => void testarAlerta()} disabled={testando}><Mail className="h-3.5 w-3.5" /> Testar e-mail</Button>
          </div>
          <p className="text-muted-foreground">
            {alertas.vigia
              ? <>Última verificação {quando(alertas.vigia.verificado_em)}: <strong className={alertas.vigia.estado === 'open' ? 'text-green-700' : 'text-amber-600'}>{alertas.vigia.estado === 'open' ? 'conectado' : alertas.vigia.estado ?? 'aguardando'}</strong>{alertas.vigia.fora_desde && <> · fora desde {quando(alertas.vigia.fora_desde)}</>}</>
              : 'O vigia ainda não rodou (roda a cada 5 minutos).'}
          </p>
          {monitor && (
            <div className="space-y-1 border-t pt-2">
              <p className="font-medium text-foreground">Monitor externo (healthchecks.io): {monitor.ligado ? <span className="text-green-700">ligado (…{monitor.final})</span> : <span className="text-amber-600">desligado</span>}</p>
              <p className="text-muted-foreground">Avisa por e-mail quando o Supabase ou o motor param. Cole o endereço de ping do check (https://hc-ping.com/...).</p>
              <div className="flex gap-2">
                <Input value={pingUrl} onChange={e => setPingUrl(e.target.value)} placeholder="https://hc-ping.com/..." className="h-8 text-xs" />
                <Button size="sm" onClick={() => void salvarMonitor(pingUrl.trim())} disabled={!pingUrl.trim()}>Salvar</Button>
                {monitor.ligado && <Button variant="outline" size="sm" onClick={() => void salvarMonitor('')}>Desligar</Button>}
              </div>
            </div>
          )}
          {alertas.alertas.map((a, i) => (
            <p key={i} className="text-muted-foreground">{quando(a.criado_em)} · {a.assunto} · {a.enviado_em ? <span className="text-green-700">enviado</span> : a.erro ? <span className="text-amber-600">não enviado: {a.erro}</span> : 'na fila'}</p>
          ))}
        </div>
      )}

      {erro && !edit && <ErrorBox>{erro}</ErrorBox>}
      {!contas ? (erro ? null : <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>) : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Conta</th><th className="px-3 py-2">Sede</th><th className="px-3 py-2">Administradores</th><th className="px-3 py-2">Módulos</th>
              <th className="px-3 py-2 text-center">Usuários</th><th className="px-3 py-2 text-center">Ativa</th><th className="w-12" />
            </tr></thead>
            <tbody>
              {contas.map(c => (
                <tr key={c.id} className={`border-b last:border-0 hover:bg-muted/30 ${!c.ativa ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2.5"><p className="font-medium">{c.nome}</p>
                    <p className="text-xs text-muted-foreground">desde {new Date(c.criada_em).toLocaleDateString('pt-BR')}</p></td>
                  <td className="px-3 py-2.5 text-xs">{c.uf ? [c.municipio, c.uf].filter(Boolean).join(' / ') : <span className="text-muted-foreground">sem sede</span>}</td>
                  <td className="px-3 py-2.5 text-xs">{c.admins.join(', ') || <span className="text-muted-foreground">nenhum</span>}</td>
                  <td className="px-3 py-2.5 text-xs">{c.modulos.join(', ')}</td>
                  <td className="px-3 py-2.5 text-center text-xs">{c.membros}</td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${c.ativa ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-right">
                    <Button variant="ghost" size="icon" aria-label="Editar"
                      onClick={() => { setEdit({ id: c.id, nome: c.nome, ativa: c.ativa, modulos: c.modulos, admin_email: '', admin_nome: '', uf: c.uf ?? '', municipio: c.municipio ?? '' }); setErro(null) }}>
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
            {edit.id && <ToggleRow label="Ativa" description="Conta desativada: ninguém dela entra no painel; os dados ficam guardados."
              checked={edit.ativa} onChange={v => setEdit({ ...edit, ativa: v })} disabled={salvando} />}
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
