import { useState } from 'react'
import type { DragEvent } from 'react'
import { AlertTriangle, Ban, GripVertical } from 'lucide-react'
import { COLUNAS_KANBAN, STATUS_BACKLOG, grupoDe, numeroBacklog } from '../lib/types'
import type { ColunaKanban, ItemBacklog } from '../lib/types'

/** Kanban simples: arraste o cartão entre colunas. Sem biblioteca externa. */
export default function Kanban({ itens, podeEditar, onMover, onAbrir }: {
  itens: ItemBacklog[]
  podeEditar: boolean
  onMover: (id: string, coluna: ColunaKanban) => void
  onAbrir: (item: ItemBacklog) => void
}) {
  const [arrastando, setArrastando] = useState<string | null>(null)
  const [alvo, setAlvo] = useState<ColunaKanban | null>(null)

  const soltar = (e: DragEvent, coluna: ColunaKanban) => {
    e.preventDefault()
    const id = e.dataTransfer.getData('text/plain') || arrastando
    setAlvo(null); setArrastando(null)
    if (id) onMover(id, coluna)
  }

  return (
    <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
      {COLUNAS_KANBAN.map(col => {
        const lista = itens.filter(i => i.coluna === col.id).sort((a, b) => a.posicao - b.posicao)
        return (
          <div key={col.id}
            onDragOver={e => { if (podeEditar) { e.preventDefault(); setAlvo(col.id) } }}
            onDragLeave={() => setAlvo(a => (a === col.id ? null : a))}
            onDrop={e => podeEditar && soltar(e, col.id)}
            className={`flex min-h-[220px] flex-col rounded-lg border bg-muted/30 p-2 transition-colors ${alvo === col.id ? 'border-primary bg-primary/5' : ''}`}>
            <div className="mb-2 px-1">
              <p className="flex items-center justify-between text-sm font-semibold">
                {col.titulo}
                <span className="rounded-full bg-background px-1.5 text-xs text-muted-foreground">{lista.length}</span>
              </p>
              <p className="text-[11px] text-muted-foreground">{col.dica}</p>
            </div>

            <div className="flex flex-1 flex-col gap-2">
              {lista.map(i => {
                const st = STATUS_BACKLOG[i.status]
                const tag = grupoDe(i.tipo)
                return (
                  <div key={i.id}
                    draggable={podeEditar}
                    onDragStart={e => { setArrastando(i.id); e.dataTransfer.setData('text/plain', i.id); e.dataTransfer.effectAllowed = 'move' }}
                    onDragEnd={() => { setArrastando(null); setAlvo(null) }}
                    onClick={() => onAbrir(i)}
                    className={`cursor-pointer rounded-md border bg-card p-2.5 shadow-sm transition-opacity hover:border-primary/40 ${arrastando === i.id ? 'opacity-40' : ''} ${i.status === 'bloqueado' ? 'border-l-2 border-l-red-500' : ''}`}>
                    <div className="flex items-start gap-1.5">
                      {podeEditar && <GripVertical className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" />}
                      <p className="flex-1 text-sm font-medium leading-tight">
                        {i.numero !== null && <span className="font-mono text-muted-foreground">{numeroBacklog(i.numero)} </span>}
                        {i.titulo}
                      </p>
                    </div>
                    <div className="mt-2 flex flex-wrap items-center gap-1">
                      <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${tag.classe}`}>{tag.tag}</span>
                      {i.esforco && <span className="rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground">{i.esforco}</span>}
                      {i.status === 'bloqueado' && (
                        <span className="inline-flex items-center gap-0.5 rounded px-1.5 py-0.5 text-[10px] font-medium text-red-700 dark:text-red-400">
                          <Ban className="h-2.5 w-2.5" />bloqueado
                        </span>
                      )}
                      {i.status === 'parcial' && (
                        <span className={`rounded px-1.5 py-0.5 text-[10px] font-medium ${st.classe}`}>parcial</span>
                      )}
                    </div>
                    {i.depende_de && (
                      <p className="mt-1.5 flex items-start gap-1 text-[10px] text-muted-foreground">
                        <AlertTriangle className="mt-0.5 h-2.5 w-2.5 shrink-0" />depende de {i.depende_de}
                      </p>
                    )}
                  </div>
                )
              })}
              {lista.length === 0 && (
                <p className="rounded-md border border-dashed py-6 text-center text-[11px] text-muted-foreground">
                  {podeEditar ? 'Arraste um cartão para cá' : 'Vazio'}
                </p>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}
