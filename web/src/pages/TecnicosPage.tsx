import { useState } from 'react'
import { AlertTriangle, Columns3, Edit2, Plus, RefreshCw, Trash2 } from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Sheet, SuccessBox, ToggleRow, useToast } from '../components/ui'
import { PlainTh, SortableTh, useColumnWidths, useSortable } from '../components/SortableTh'
import { api, erroMsg } from '../lib/api'
import { telefoneValido } from '../lib/types'
import type { Tecnico } from '../lib/types'

const NOVO: Partial<Tecnico> = { nome: '', telefone_e164: '', funcao: '', equipe: '', is_supervisor: false, opt_in: false, ativo: true, perfil_teste: false }

export default function TecnicosPage({ tecnicos, recarregar, podeEditar, podeExcluir }: {
  tecnicos: Tecnico[]; recarregar: () => Promise<void>; podeEditar: boolean; podeExcluir: boolean
}) {
  const toast = useToast()
  const [edit, setEdit] = useState<Partial<Tecnico> | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [atualizando, setAtualizando] = useState(false)

  const [alvo, setAlvo] = useState<Tecnico | null>(null)
  const [confirmaNome, setConfirmaNome] = useState('')
  const [excluindo, setExcluindo] = useState(false)
  const [erroExcluir, setErroExcluir] = useState<string | null>(null)

  const { sorted, thProps } = useSortable(tecnicos, {
    nome: t => t.nome, telefone: t => t.telefone_e164, funcao: t => t.funcao, equipe: t => t.equipe,
    supervisor: t => t.is_supervisor, whatsapp: t => t.opt_in, ativo: t => t.ativo,
  }, { key: 'nome' })
  const { col, total, restaurarTudo } = useColumnWidths('tecnicos', { nome: 260, telefone: 150, funcao: 150, equipe: 140, supervisor: 115, whatsapp: 115, ativo: 90, acoes: 90 })

  const atualizar = async () => { setAtualizando(true); await recarregar(); setAtualizando(false) }

  const salvar = async () => {
    if (!edit) return
    setErro(null); setOk(null)
    if (!edit.nome?.trim()) return setErro('Nome é obrigatório.')
    if (!edit.funcao?.trim()) return setErro('Função é obrigatória.')
    if (!telefoneValido(edit.telefone_e164 ?? '')) return setErro('Telefone inválido: somente dígitos com código do país. Ex: 5571981776307')
    setSalvando(true)
    try {
      await api.salvarTecnico(edit)
      setOk(edit.id ? 'Técnico atualizado.' : 'Técnico criado.')
      await recarregar()
      setTimeout(() => setEdit(null), 700)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const excluir = async () => {
    if (!alvo) return
    setExcluindo(true); setErroExcluir(null)
    try {
      const r = await api.excluirTecnico(alvo.id)
      toast(`Técnico excluído. ${r.escalas_removidas} escala${r.escalas_removidas !== 1 ? 's' : ''} removida${r.escalas_removidas !== 1 ? 's' : ''}.`)
      setAlvo(null); await recarregar()
    } catch (e) { setErroExcluir(erroMsg(e)) }
    finally { setExcluindo(false) }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">Técnicos</h2>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" onClick={restaurarTudo} title="Voltar todas as colunas à largura padrão"><Columns3 className="h-3.5 w-3.5" /> Larguras padrão</Button>
          <Button variant="outline" size="sm" onClick={() => void atualizar()} disabled={atualizando}>
            <RefreshCw className={`h-3.5 w-3.5 ${atualizando ? 'animate-spin' : ''}`} /> Atualizar
          </Button>
          {podeEditar && <Button size="sm" onClick={() => { setEdit({ ...NOVO }); setErro(null); setOk(null) }}><Plus className="h-4 w-4" /> Novo técnico</Button>}
        </div>
      </div>

      <div className="overflow-hidden rounded-md border">
        <div className="overflow-x-auto">
          <table className="table-fixed text-sm" style={{ width: total, minWidth: '100%' }}>
            <thead>
              <tr className="border-b bg-muted/50">
                <SortableTh {...thProps('nome')} {...col('nome')}>Nome</SortableTh>
                <SortableTh {...thProps('telefone')} {...col('telefone')}>Telefone</SortableTh>
                <SortableTh {...thProps('funcao')} {...col('funcao')}>Função</SortableTh>
                <SortableTh {...thProps('equipe')} {...col('equipe')}>Equipe</SortableTh>
                <SortableTh {...thProps('supervisor')} {...col('supervisor')} align="center">Supervisor</SortableTh>
                <SortableTh {...thProps('whatsapp')} {...col('whatsapp')} align="center">WhatsApp</SortableTh>
                <SortableTh {...thProps('ativo')} {...col('ativo')} align="center">Ativo</SortableTh>
                <PlainTh {...col('acoes')} />
              </tr>
            </thead>
            <tbody>
              {sorted.length === 0 ? (
                <tr><td colSpan={8} className="py-12 text-center text-muted-foreground">Nenhum técnico cadastrado</td></tr>
              ) : sorted.map(t => (
                <tr key={t.id} className={`border-b last:border-0 hover:bg-muted/30 ${!t.ativo ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2.5">
                    <div className="flex min-w-0 items-center gap-2">
                      <span className="truncate font-medium" title={t.nome}>{t.nome}</span>
                      {!t.opt_in && t.ativo && <span className="inline-flex shrink-0 items-center gap-0.5 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"><AlertTriangle className="h-3 w-3" /> Sem autorização</span>}
                      {t.perfil_teste && <span className="shrink-0 rounded bg-purple-100 px-1.5 py-0.5 text-xs font-medium text-purple-800 dark:bg-purple-900/30 dark:text-purple-300">Teste</span>}
                      {!t.ativo && <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-500 dark:bg-gray-800">Inativo</span>}
                    </div>
                  </td>
                  <td className="truncate px-3 py-2.5 font-mono text-xs text-muted-foreground">{t.telefone_e164}</td>
                  <td className="truncate px-3 py-2.5 text-xs" title={t.funcao}>{t.funcao}</td>
                  <td className="truncate px-3 py-2.5 text-xs text-muted-foreground" title={t.equipe ?? ''}>{t.equipe ?? '—'}</td>
                  <td className="px-3 py-2.5 text-center text-xs">{t.is_supervisor ? <span className="font-medium text-primary">Sim</span> : <span className="text-muted-foreground">Não</span>}</td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${t.opt_in ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${t.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-right">
                    <div className="flex justify-end gap-1">
                      {podeEditar && <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...t }); setErro(null); setOk(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>}
                      {podeExcluir && <Button variant="ghost" size="icon" aria-label="Excluir" className="text-destructive hover:bg-destructive/10" onClick={() => { setAlvo(t); setConfirmaNome(''); setErroExcluir(null) }}><Trash2 className="h-3.5 w-3.5" /></Button>}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <Sheet open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} width="sm:max-w-md"
        title={edit?.id ? 'Editar técnico' : 'Novo técnico'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-4">
            <Field label="Nome *"><Input value={edit.nome ?? ''} onChange={e => setEdit(p => ({ ...p, nome: e.target.value }))} disabled={salvando} placeholder="Ex: João Silva" /></Field>
            <Field label="Telefone com DDI *" hint="Somente dígitos: país + DDD + número. Ex: 5571981776307">
              <Input value={edit.telefone_e164 ?? ''} maxLength={15} disabled={salvando}
                onChange={e => setEdit(p => ({ ...p, telefone_e164: e.target.value.replace(/\D/g, '') }))} />
            </Field>
            <Field label="Função *"><Input value={edit.funcao ?? ''} onChange={e => setEdit(p => ({ ...p, funcao: e.target.value }))} disabled={salvando} placeholder="Ex: Instalador, Cabista" /></Field>
            <Field label="Equipe"><Input value={edit.equipe ?? ''} onChange={e => setEdit(p => ({ ...p, equipe: e.target.value }))} disabled={salvando} /></Field>
            <hr />
            <ToggleRow label="Supervisor" description="Recebe os alertas quando um técnico recusa ou não responde."
              checked={!!edit.is_supervisor} onChange={v => setEdit(p => ({ ...p, is_supervisor: v }))} disabled={salvando} />
            <ToggleRow label="Autorização WhatsApp" description="Sem autorização, o sistema não envia nenhuma mensagem para este técnico."
              checked={!!edit.opt_in} onChange={v => setEdit(p => ({ ...p, opt_in: v }))} disabled={salvando} />
            <ToggleRow label="Perfil de teste" description="Para homologação: recebe mensagens e ligações manuais, mas fica fora dos indicadores, do painel de pendências, dos alertas e das ligações automáticas."
              checked={!!edit.perfil_teste} onChange={v => setEdit(p => ({ ...p, perfil_teste: v }))} disabled={salvando} />
            <Field label="Data de desligamento" hint="Inicia a contagem de guarda dos documentos (5 anos).">
              <Input type="date" value={edit.desligado_em ?? ''} disabled={salvando}
                onChange={e => setEdit(p => ({ ...p, desligado_em: e.target.value || null }))} />
            </Field>
            {edit.id && <ToggleRow label="Ativo" description={edit.ativo ? 'Aparece na seleção de novas escalas.' : 'Inativo: não aparece em novas escalas; o histórico fica preservado.'}
              checked={!!edit.ativo} onChange={v => setEdit(p => ({ ...p, ativo: v }))} disabled={salvando} />}
            {erro && <ErrorBox>{erro}</ErrorBox>}
            {ok && <SuccessBox>{ok}</SuccessBox>}
          </div>
        )}
      </Sheet>

      <Confirm open={!!alvo} title="Excluir técnico definitivamente" confirmLabel="Excluir definitivamente" destructive
        busy={excluindo} disabled={confirmaNome !== alvo?.nome} onCancel={() => setAlvo(null)} onConfirm={() => void excluir()}>
        <p>Esta ação não pode ser desfeita. <strong className="text-foreground">{alvo?.nome}</strong> e todo o histórico de escalas, mensagens e respostas serão apagados. Para só impedir novos envios, edite o técnico e desmarque <strong className="text-foreground">Ativo</strong>.</p>
        <Field label="Digite o nome do técnico para confirmar">
          <Input value={confirmaNome} onChange={e => setConfirmaNome(e.target.value)} placeholder={alvo?.nome} autoComplete="off" disabled={excluindo} />
        </Field>
        {erroExcluir && <ErrorBox>{erroExcluir}</ErrorBox>}
      </Confirm>
    </div>
  )
}
