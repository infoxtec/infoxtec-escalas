import { useEffect, useMemo, useRef, useState } from 'react'
import { Check, ChevronDown, X } from 'lucide-react'

export interface Opcao { value: string; label: string; detalhe?: string }

export default function MultiSelect({ opcoes, valores, onChange, placeholder = 'Selecione...', disabled }: {
  opcoes: Opcao[]; valores: string[]; onChange: (v: string[]) => void; placeholder?: string; disabled?: boolean
}) {
  const [aberto, setAberto] = useState(false)
  const [busca, setBusca] = useState('')
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const h = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) setAberto(false) }
    document.addEventListener('mousedown', h)
    return () => document.removeEventListener('mousedown', h)
  }, [])

  const filtradas = useMemo(() => {
    const q = busca.trim().toLocaleLowerCase('pt-BR')
    if (!q) return opcoes
    return opcoes.filter(o => `${o.label} ${o.detalhe ?? ''}`.toLocaleLowerCase('pt-BR').includes(q))
  }, [opcoes, busca])

  const alternar = (v: string) => onChange(valores.includes(v) ? valores.filter(x => x !== v) : [...valores, v])
  const selecionadas = opcoes.filter(o => valores.includes(o.value))

  return (
    <div ref={ref} className="relative">
      <button type="button" disabled={disabled} onClick={() => setAberto(a => !a)}
        className="flex min-h-9 w-full flex-wrap items-center gap-1 rounded-md border bg-background px-2 py-1 text-left text-sm disabled:opacity-60">
        {selecionadas.length === 0 && <span className="px-1 text-muted-foreground">{placeholder}</span>}
        {selecionadas.map(o => (
          <span key={o.value} className="inline-flex items-center gap-1 rounded bg-muted px-1.5 py-0.5 text-xs">
            {o.label}
            <X className="h-3 w-3 cursor-pointer" onClick={(e) => { e.stopPropagation(); alternar(o.value) }} />
          </span>
        ))}
        <ChevronDown className="ml-auto h-4 w-4 text-muted-foreground" />
      </button>
      {aberto && (
        <div className="absolute z-10 mt-1 w-full rounded-md border bg-card shadow-lg">
          <div className="border-b p-2">
            <input autoFocus value={busca} onChange={e => setBusca(e.target.value)} placeholder="Buscar..."
              className="h-8 w-full rounded border bg-background px-2 text-sm focus:outline-none" />
          </div>
          <div className="max-h-56 overflow-y-auto py-1">
            {filtradas.length === 0 && <p className="px-3 py-2 text-sm text-muted-foreground">Nada encontrado</p>}
            {filtradas.map(o => {
              const sel = valores.includes(o.value)
              return (
                <button type="button" key={o.value} onClick={() => alternar(o.value)}
                  className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-muted">
                  <span className={`flex h-4 w-4 items-center justify-center rounded border ${sel ? 'border-primary bg-primary text-primary-foreground' : ''}`}>
                    {sel && <Check className="h-3 w-3" />}
                  </span>
                  <span>{o.label}</span>
                  {o.detalhe && <span className="text-xs text-muted-foreground">· {o.detalhe}</span>}
                </button>
              )
            })}
          </div>
          {valores.length > 0 && (
            <div className="flex justify-between border-t px-3 py-1.5 text-xs">
              <span className="text-muted-foreground">{valores.length} selecionado(s)</span>
              <button type="button" className="text-primary" onClick={() => onChange([])}>Limpar</button>
            </div>
          )}
        </div>
      )}
    </div>
  )
}
