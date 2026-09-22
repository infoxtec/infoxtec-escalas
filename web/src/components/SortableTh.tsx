import { useMemo, useState } from 'react'
import type { PointerEvent as ReactPointerEvent, ReactNode } from 'react'
import { ArrowUp, ArrowDown, ArrowUpDown } from 'lucide-react'

export type SortDir = 'asc' | 'desc'
type Valor = string | number | boolean | null | undefined

/** Ordenacao no navegador: texto em pt-BR sem diferenciar acentos, vazios sempre no fim. */
export function useSortable<T>(items: T[], getters: Record<string, (i: T) => Valor>, inicial: { key: string; dir?: SortDir }) {
  const [sort, setSort] = useState<{ key: string; dir: SortDir }>({ key: inicial.key, dir: inicial.dir ?? 'asc' })

  const sorted = useMemo(() => {
    const get = getters[sort.key]
    if (!get) return items
    const mult = sort.dir === 'asc' ? 1 : -1
    return [...items].sort((a, b) => {
      const va = get(a), vb = get(b)
      const ea = va === null || va === undefined || va === ''
      const eb = vb === null || vb === undefined || vb === ''
      if (ea && eb) return 0
      if (ea) return 1
      if (eb) return -1
      if (typeof va === 'number' && typeof vb === 'number') return (va - vb) * mult
      if (typeof va === 'boolean' && typeof vb === 'boolean') return (Number(vb) - Number(va)) * mult
      return String(va).localeCompare(String(vb), 'pt-BR', { numeric: true, sensitivity: 'base' }) * mult
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, sort])

  const onSort = (key: string) =>
    setSort(s => (s.key === key ? { key, dir: s.dir === 'asc' ? 'desc' : 'asc' } : { key, dir: 'asc' }))
  const thProps = (key: string) => ({ sortKey: key, activeKey: sort.key, dir: sort.dir, onSort })
  return { sorted, thProps }
}

/**
 * Larguras de coluna ajustaveis, salvas no navegador (por tabela).
 * Arraste a borda direita do titulo; duplo clique volta ao padrao.
 */
export function useColumnWidths(tabela: string, padrao: Record<string, number>) {
  const chave = `colunas:${tabela}`
  const [larguras, setLarguras] = useState<Record<string, number>>(() => {
    try { return { ...padrao, ...(JSON.parse(localStorage.getItem(chave) ?? '{}') as Record<string, number>) } }
    catch { return { ...padrao } }
  })

  const definir = (col: string, w: number) => setLarguras(l => {
    const n = { ...l, [col]: Math.max(60, Math.min(900, Math.round(w))) }
    try { localStorage.setItem(chave, JSON.stringify(n)) } catch { /* navegador sem armazenamento */ }
    return n
  })

  const restaurarTudo = () => {
    try { localStorage.removeItem(chave) } catch { /* ignora */ }
    setLarguras({ ...padrao })
  }

  const col = (c: string) => ({
    width: larguras[c] ?? padrao[c],
    onResize: (w: number) => definir(c, w),
    onReset: () => definir(c, padrao[c]),
  })
  const total = Object.keys(padrao).reduce((s, c) => s + (larguras[c] ?? padrao[c]), 0)
  return { col, total, restaurarTudo }
}

interface ThBase {
  children?: ReactNode
  align?: 'left' | 'center'
  className?: string
  width?: number
  onResize?: (w: number) => void
  onReset?: () => void
}

function AlcaDeLargura({ width, onResize, onReset }: { width: number; onResize: (w: number) => void; onReset?: () => void }) {
  const iniciar = (e: ReactPointerEvent<HTMLSpanElement>) => {
    e.preventDefault()
    e.stopPropagation()
    const x0 = e.clientX
    const w0 = width
    const mover = (ev: PointerEvent) => onResize(w0 + (ev.clientX - x0))
    const soltar = () => {
      window.removeEventListener('pointermove', mover)
      window.removeEventListener('pointerup', soltar)
      document.body.style.cursor = ''
      document.body.style.userSelect = ''
    }
    document.body.style.cursor = 'col-resize'
    document.body.style.userSelect = 'none'
    window.addEventListener('pointermove', mover)
    window.addEventListener('pointerup', soltar)
  }
  return (
    <span
      role="separator"
      aria-orientation="vertical"
      title="Arraste para ajustar a largura · duplo clique volta ao padrão"
      onPointerDown={iniciar}
      onDoubleClick={onReset}
      onClick={e => e.stopPropagation()}
      className="absolute right-0 top-0 z-10 h-full w-2 cursor-col-resize touch-none after:absolute after:right-0 after:top-1/4 after:h-1/2 after:w-px after:bg-border hover:bg-primary/20 active:bg-primary/40"
    />
  )
}

/** Titulo de coluna clicavel para ordenar, com alca de largura opcional. */
export function SortableTh({ sortKey, activeKey, dir, onSort, children, align = 'left', className = '', width, onResize, onReset }: ThBase & {
  sortKey: string; activeKey: string; dir: SortDir; onSort: (k: string) => void
}) {
  const ativo = sortKey === activeKey
  const Icone = !ativo ? ArrowUpDown : dir === 'asc' ? ArrowUp : ArrowDown
  return (
    <th style={width ? { width } : undefined}
      className={`relative overflow-hidden px-3 py-2.5 text-xs font-semibold text-muted-foreground ${align === 'center' ? 'text-center' : 'text-left'} ${className}`}
      aria-sort={ativo ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
      <button type="button" onClick={() => onSort(sortKey)}
        className={`inline-flex max-w-full select-none items-center gap-1 transition-colors hover:text-foreground ${ativo ? 'text-foreground' : ''}`}>
        <span className="truncate">{children}</span>
        <Icone className={`h-3 w-3 shrink-0 ${ativo ? 'opacity-100' : 'opacity-40'}`} />
      </button>
      {onResize && width && <AlcaDeLargura width={width} onResize={onResize} onReset={onReset} />}
    </th>
  )
}

/** Titulo de coluna sem ordenacao (ex.: coluna de acoes), com largura ajustavel opcional. */
export function PlainTh({ children, align = 'left', className = '', width, onResize, onReset }: ThBase) {
  return (
    <th style={width ? { width } : undefined}
      className={`relative px-3 py-2.5 text-xs font-semibold text-muted-foreground ${align === 'center' ? 'text-center' : 'text-left'} ${className}`}>
      {children}
      {onResize && width && <AlcaDeLargura width={width} onResize={onResize} onReset={onReset} />}
    </th>
  )
}
