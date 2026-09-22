import { useState } from 'react'
import { Columns3, Edit2, ExternalLink, Plus, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, ToggleRow } from '../components/ui'
import { PlainTh, SortableTh, useColumnWidths, useSortable } from '../components/SortableTh'
import { api, erroMsg } from '../lib/api'
import type { Local } from '../lib/types'

const NOVO: Partial<Local> = { nome: '', cliente: '', endereco: '', cidade: 'Salvador', referencia: '', link_maps: '', contato_local: '', telefone_contato: '', ativo: true }

export default function LocaisPage({ locais, recarregar, podeEditar }: {
  locais: Local[]; recarregar: () => Promise<void>; podeEditar: boolean
}) {
  const [edit, setEdit] = useState<Partial<Local> | null>(null)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [atualizando, setAtualizando] = useState(false)

  const { sorted, thProps } = useSortable(locais, {
    nome: l => l.nome, cliente: l => l.cliente, endereco: l => l.endereco, cidade: l => l.cidade,
    referencia: l => l.referencia, contato: l => l.contato_local, maps: l => !!l.link_maps, ativo: l => l.ativo,
  }, { key: 'nome' })
  const { col, total, restaurarTudo } = useColumnWidths('locais', { nome: 200, cliente: 150, endereco: 280, cidade: 110, referencia: 160, contato: 160, maps: 80, ativo: 80, acoes: 70 })

  const set = (k: keyof Local, v: string | boolean) => setEdit(p => ({ ...p, [k]: v }))

  const salvar = async () => {
    if (!edit) return
    setErro(null)
    if (!edit.nome?.trim()) return setErro('Nome é obrigatório.')
    setSalvando(true)
    try { await api.salvarLocal(edit); await recarregar(); setEdit(null) }
    catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-base font-semibold">Locais de serviço</h2>
        <div className="flex gap-2">
          <Button variant="ghost" size="sm" onClick={restaurarTudo} title="Voltar todas as colunas à largura padrão"><Columns3 className="h-3.5 w-3.5" /> Larguras padrão</Button>
          <Button variant="outline" size="sm" disabled={atualizando} onClick={async () => { setAtualizando(true); await recarregar(); setAtualizando(false) }}>
            <RefreshCw className={`h-3.5 w-3.5 ${atualizando ? 'animate-spin' : ''}`} /> Atualizar
          </Button>
          {podeEditar && <Button size="sm" onClick={() => { setEdit({ ...NOVO }); setErro(null) }}><Plus className="h-4 w-4" /> Novo local</Button>}
        </div>
      </div>

      <div className="overflow-hidden rounded-md border">
        <div className="overflow-x-auto">
          <table className="table-fixed text-sm" style={{ width: total, minWidth: '100%' }}>
            <thead>
              <tr className="border-b bg-muted/50">
                <SortableTh {...thProps('nome')} {...col('nome')}>Nome</SortableTh>
                <SortableTh {...thProps('cliente')} {...col('cliente')}>Cliente</SortableTh>
                <SortableTh {...thProps('endereco')} {...col('endereco')}>Endereço</SortableTh>
                <SortableTh {...thProps('cidade')} {...col('cidade')}>Cidade</SortableTh>
                <SortableTh {...thProps('referencia')} {...col('referencia')}>Referência</SortableTh>
                <SortableTh {...thProps('contato')} {...col('contato')}>Contato</SortableTh>
                <SortableTh {...thProps('maps')} {...col('maps')} align="center">Maps</SortableTh>
                <SortableTh {...thProps('ativo')} {...col('ativo')} align="center">Ativo</SortableTh>
                <PlainTh {...col('acoes')} />
              </tr>
            </thead>
            <tbody>
              {sorted.length === 0 ? (
                <tr><td colSpan={9} className="py-12 text-center text-muted-foreground">Nenhum local cadastrado</td></tr>
              ) : sorted.map(l => (
                <tr key={l.id} className={`border-b last:border-0 hover:bg-muted/30 ${!l.ativo ? 'opacity-50' : ''}`}>
                  <td className="truncate px-3 py-2.5 font-medium" title={l.nome ?? ''}>{l.nome}</td>
                  <td className="truncate px-3 py-2.5 text-xs" title={l.cliente ?? ''}>{l.cliente ?? '—'}</td>
                  <td className="truncate px-3 py-2.5 text-xs text-muted-foreground" title={l.endereco ?? ''}>{l.endereco ?? '—'}</td>
                  <td className="truncate px-3 py-2.5 text-xs">{l.cidade ?? '—'}</td>
                  <td className="truncate px-3 py-2.5 text-xs text-muted-foreground" title={l.referencia ?? ''}>{l.referencia ?? '—'}</td>
                  <td className="truncate px-3 py-2.5 text-xs" title={l.contato_local ?? ''}>{l.contato_local ? <div><p>{l.contato_local}</p>{l.telefone_contato && <p className="font-mono text-muted-foreground">{l.telefone_contato}</p>}</div> : '—'}</td>
                  <td className="px-3 py-2.5 text-center">{l.link_maps ? <a href={l.link_maps} target="_blank" rel="noopener noreferrer" className="inline-flex text-primary"><ExternalLink className="h-3.5 w-3.5" /></a> : <span className="text-xs text-muted-foreground">—</span>}</td>
                  <td className="px-3 py-2.5 text-center"><span className={`inline-block h-2 w-2 rounded-full ${l.ativo ? 'bg-green-500' : 'bg-gray-400'}`} /></td>
                  <td className="px-3 py-2.5 text-right">{podeEditar && <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setEdit({ ...l }); setErro(null) }}><Edit2 className="h-3.5 w-3.5" /></Button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar local' : 'Novo local'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && (
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <Field label="Nome *"><Input value={edit.nome ?? ''} onChange={e => set('nome', e.target.value)} disabled={salvando} /></Field>
              <Field label="Cliente"><Input value={edit.cliente ?? ''} onChange={e => set('cliente', e.target.value)} disabled={salvando} /></Field>
            </div>
            <Field label="Endereço"><Input value={edit.endereco ?? ''} onChange={e => set('endereco', e.target.value)} disabled={salvando} /></Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Cidade"><Input value={edit.cidade ?? ''} onChange={e => set('cidade', e.target.value)} disabled={salvando} /></Field>
              <Field label="Referência"><Input value={edit.referencia ?? ''} onChange={e => set('referencia', e.target.value)} disabled={salvando} /></Field>
            </div>
            <Field label="Link do Google Maps" hint="Vai dentro da mensagem do WhatsApp."><Input value={edit.link_maps ?? ''} onChange={e => set('link_maps', e.target.value)} placeholder="https://maps.google.com/..." disabled={salvando} /></Field>
            <div className="grid grid-cols-2 gap-3">
              <Field label="Contato no local"><Input value={edit.contato_local ?? ''} onChange={e => set('contato_local', e.target.value)} disabled={salvando} /></Field>
              <Field label="Telefone do contato"><Input value={edit.telefone_contato ?? ''} onChange={e => set('telefone_contato', e.target.value)} disabled={salvando} /></Field>
            </div>
            {edit.id && <ToggleRow label="Ativo" checked={!!edit.ativo} onChange={v => set('ativo', v)} disabled={salvando} />}
            {erro && <ErrorBox>{erro}</ErrorBox>}
          </div>
        )}
      </Modal>
    </div>
  )
}
