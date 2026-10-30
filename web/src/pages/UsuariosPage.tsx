import { useCallback, useEffect, useState } from 'react'
import { Columns3, Edit2, Info, Mail, Plus, RefreshCw, ShieldCheck } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, Select, ToggleRow, useToast } from '../components/ui'
import { PlainTh, SortableTh, useColumnWidths, useSortable } from '../components/SortableTh'
import { api, convidarUsuario, erroMsg, mensagemConvite } from '../lib/api'
import { contaAtual } from '../lib/supabase'
import { formatDateTime, PAPEL_LABEL } from '../lib/types'
import type { Papel, UsuarioPainel } from '../lib/types'

const DESCRICAO: Record<Papel, string> = {
  admin: 'Tudo, inclusive excluir técnicos e gerenciar usuários.',
  gestor: 'Cria programações, muda status, edita técnicos e locais.',
  leitura: 'Só visualiza.',
}

export default function UsuariosPage() {
  const toast = useToast()
  const [lista, setLista] = useState<UsuarioPainel[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [historico, setHistorico] = useState<{ email: string; valor: boolean; autor: string; em: string }[]>([])
  const [histRh, setHistRh] = useState<{ email: string; valor: boolean; autor: string; em: string }[]>([])
  // null = ainda sem a informação (ou o banco sem a migration 82): a coluna mostra "?", nunca "—" falso
  const [mfa, setMfa] = useState<{ ativos: Map<string, string>; historico: { email: string; acao: 'ativou' | 'desativou'; em: string }[] } | null>(null)
  const [edit, setEdit] = useState<{ email: string; nome: string; papel: Papel; ativo: boolean; novo: boolean; ve_saude: boolean; ve_saude_antes: boolean; rh_folhas: boolean; rh_folhas_antes: boolean } | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [convites, setConvites] = useState<Map<string, { em: string; resultado: string }>>(new Map())
  const [convidando, setConvidando] = useState<string | null>(null)
  const [erroForm, setErroForm] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    api.veSaudeHistorico().then(setHistorico).catch(() => setHistorico([]))
    api.rhFolhasHistorico().then(setHistRh).catch(() => setHistRh([]))
    api.usuariosMfa().then(m => setMfa({ ativos: new Map(m.ativos.map(a => [a.email, a.desde])), historico: m.historico }))
      .catch(() => setMfa(null))
    api.convites().then(c => setConvites(new Map(c.map(x => [x.email, { em: x.em, resultado: x.resultado }])))).catch(() => setConvites(new Map()))
    try { setLista(await api.usuarios()) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const { sorted, thProps } = useSortable(lista, {
    nome: u => u.nome ?? u.email, email: u => u.email, papel: u => PAPEL_LABEL[u.papel], ativo: u => u.ativo,
    mfa: u => !!mfa?.ativos.has(u.email.toLowerCase()),
  }, { key: 'nome' })
  const { col, total, restaurarTudo } = useColumnWidths('usuarios', { nome: 200, email: 260, papel: 150, ativo: 90, mfa: 120, criado: 260, acoes: 100 })

  const salvar = async () => {
    if (!edit) return
    setErroForm(null)
    if (!/^\S+@\S+\.\S+$/.test(edit.email.trim())) return setErroForm('Informe um e-mail válido.')
    setSalvando(true)
    try {
      await api.salvarUsuario({ email: edit.email.trim(), nome: edit.nome.trim(), papel: edit.papel, ativo: edit.ativo })
      const ve = edit.ve_saude && edit.papel !== 'leitura'
      if (ve !== edit.ve_saude_antes) await api.definirVeSaude(edit.email.trim(), ve)
      const rh = edit.rh_folhas && edit.papel !== 'leitura'
      if (rh !== edit.rh_folhas_antes) await api.definirRhFolhas(edit.email.trim(), rh)
      if (edit.novo) {
        const email = edit.email.trim().toLowerCase()
        const conta = contaAtual()
        toast(conta ? `Usuário liberado no painel. ${mensagemConvite(email, await convidarUsuario(email, conta))}` : 'Usuário liberado no painel.')
      } else toast('Usuário atualizado.')
      setEdit(null); await carregar()
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const convidar = async (email: string) => {
    const conta = contaAtual()
    if (!conta) return
    setConvidando(email)
    try { toast(mensagemConvite(email, await convidarUsuario(email, conta))); await carregar() }
    finally { setConvidando(null) }
  }
  const SITUACAO_CONVITE: Record<string, string> = { enviado: 'enviado', ja_tinha_login: 'já tinha login', falhou: 'falhou', pendente: 'pendente' }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">Usuários do painel</h2>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" onClick={restaurarTudo} title="Voltar todas as colunas à largura padrão"><Columns3 className="h-3.5 w-3.5" /> Larguras padrão</Button>
          <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando}><RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar</Button>
          <Button size="sm" onClick={() => { setEdit({ email: '', nome: '', papel: 'gestor', ativo: true, novo: true, ve_saude: false, ve_saude_antes: false, rh_folhas: false, rh_folhas_antes: false }); setErroForm(null) }}><Plus className="h-4 w-4" /> Adicionar usuário</Button>
        </div>
      </div>

      <div className="flex items-start gap-2 rounded-md border bg-muted/40 p-3 text-xs text-muted-foreground">
        <Info className="mt-0.5 h-4 w-4 shrink-0 text-primary" />
        <p>Em <strong className="text-foreground">Adicionar usuário</strong>, informe o e-mail e o papel: ao salvar, a pessoa recebe por e-mail o convite para criar a senha (quem já tem login entra com a senha atual). O envelope na linha reenvia o convite. Quem tem login mas não está nesta lista vê uma tela de acesso negado.</p>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="overflow-hidden rounded-md border">
        <table className="table-fixed text-sm" style={{ width: total, minWidth: '100%' }}>
          <thead>
            <tr className="border-b bg-muted/50">
              <SortableTh {...thProps('nome')} {...col('nome')}>Nome</SortableTh>
              <SortableTh {...thProps('email')} {...col('email')}>E-mail</SortableTh>
              <SortableTh {...thProps('papel')} {...col('papel')}>Papel</SortableTh>
              <SortableTh {...thProps('ativo')} {...col('ativo')} align="center">Ativo</SortableTh>
              <SortableTh {...thProps('mfa')} {...col('mfa')} align="center">Duas etapas</SortableTh>
              <PlainTh {...col('criado')}>Criado por</PlainTh>
              <PlainTh {...col('acoes')} />
            </tr>
          </thead>
          <tbody>
            {sorted.map(u => (
              <tr key={u.email} className={`border-b last:border-0 ${!u.ativo ? 'opacity-50' : ''}`}>
                <td className="truncate px-3 py-2.5 font-medium" title={u.nome ?? ''}>{u.nome ?? '—'}</td>
                <td className="truncate px-3 py-2.5 text-xs" title={u.email}>{u.email}</td>
                <td className="px-3 py-2.5 text-xs">{PAPEL_LABEL[u.papel]}{u.ve_saude && <span className="ml-1 rounded bg-blue-100 px-1 text-[10px] text-blue-800" title="Vê atestados e documentos; decide pedidos com documento">atestados</span>}{u.rh_folhas && <span className="ml-1 rounded bg-emerald-100 px-1 text-[10px] text-emerald-800" title="Abre o cofre das folhas de ponto assinadas">folhas</span>}</td>
                <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${u.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                <td className="px-3 py-2.5 text-center text-xs">
                  {!mfa ? <span className="text-muted-foreground" title="Informação indisponível">?</span>
                    : mfa.ativos.has(u.email.toLowerCase())
                      ? <span title={`Ativa desde ${mfa.ativos.get(u.email.toLowerCase())}`}><ShieldCheck className="inline h-4 w-4 text-green-700" /></span>
                      : <span className="text-muted-foreground">—</span>}
                </td>
                <td className="truncate px-3 py-2.5 text-xs text-muted-foreground">{u.criado_por ?? '—'} · {formatDateTime(u.created_at)}</td>
                <td className="whitespace-nowrap px-3 py-2.5 text-right">
                  {u.ativo && (
                    <Button variant="ghost" size="icon" aria-label="Enviar convite por e-mail" disabled={convidando === u.email}
                      title={convites.has(u.email) ? `Último convite: ${formatDateTime(convites.get(u.email)!.em)} (${SITUACAO_CONVITE[convites.get(u.email)!.resultado] ?? ''}). Clique para enviar de novo.` : 'Enviar convite por e-mail para criar a senha'}
                      onClick={() => void convidar(u.email)}><Mail className="h-3.5 w-3.5" /></Button>
                  )}
                  <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ email: u.email, nome: u.nome ?? '', papel: u.papel, ativo: u.ativo, novo: false, ve_saude: u.ve_saude, ve_saude_antes: u.ve_saude, rh_folhas: !!u.rh_folhas, rh_folhas_antes: !!u.rh_folhas }); setErroForm(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {histRh.length > 0 && (
        <div className="space-y-1 rounded-md border p-3 text-xs">
          <p className="font-semibold">Histórico de "Cofre de folhas assinadas"</p>
          <ul className="space-y-0.5 text-muted-foreground">
            {histRh.slice(0, 20).map((h, i) => (
              <li key={i}>{h.em} · {h.autor} {h.valor ? 'deu a permissão a' : 'tirou a permissão de'} <span className="text-foreground">{h.email}</span></li>
            ))}
          </ul>
        </div>
      )}

      {historico.length > 0 && (
        <div className="space-y-1 rounded-md border p-3 text-xs">
          <p className="font-semibold">Histórico de "Vê atestados e documentos"</p>
          <ul className="space-y-0.5 text-muted-foreground">
            {historico.slice(0, 20).map((h, i) => (
              <li key={i}>{h.em} · {h.autor} {h.valor ? 'deu a permissão a' : 'tirou a permissão de'} <span className="text-foreground">{h.email}</span></li>
            ))}
          </ul>
        </div>
      )}

      {mfa && mfa.historico.length > 0 && (
        <div className="space-y-1 rounded-md border p-3 text-xs">
          <p className="font-semibold">Histórico da verificação em duas etapas</p>
          <ul className="space-y-0.5 text-muted-foreground">
            {mfa.historico.slice(0, 20).map((h, i) => (
              <li key={i}>{h.em} · <span className="text-foreground">{h.email}</span> {h.acao === 'ativou' ? 'ativou' : 'desativou'} a verificação</li>
            ))}
          </ul>
        </div>
      )}

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
            {edit.papel !== 'leitura' && (
              <ToggleRow label="Vê atestados e documentos" description="Vê e decide pedidos com documento (atestado, certidão, convocação) e abre o cofre: só visualização, cada abertura fica registrada. Dê só a quem faz o RH."
                checked={edit.ve_saude} onChange={v => setEdit({ ...edit, ve_saude: v })} disabled={salvando} />
            )}
            {edit.papel !== 'leitura' && (
              <ToggleRow label="Cofre de folhas assinadas (RH)" description="Abre as folhas de ponto assinadas pelos funcionários, com a assinatura, e baixa a cópia e a prova para uma ação judicial. Cada abertura fica registrada. Dê só a quem faz o RH."
                checked={edit.rh_folhas} onChange={v => setEdit({ ...edit, rh_folhas: v })} disabled={salvando} />
            )}
            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
