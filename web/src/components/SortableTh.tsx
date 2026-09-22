import { useMemo, useState } from 'react'
import type { ReactNode } from 'react'
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

export function SortableTh({ sortKey, activeKey, dir, onSort, children, align = 'left', className = '' }: {
  sortKey: string; activeKey: string; dir: SortDir; onSort: (k: string) => void
  children: ReactNode; align?: 'left' | 'center'; className?: string
}) {
  const ativo = sortKey === activeKey
  const Icone = !ativo ? ArrowUpDown : dir === 'asc' ? ArrowUp : ArrowDown
  return (
    <th className={`px-3 py-2.5 text-xs font-semibold text-muted-foreground ${align === 'center' ? 'text-center' : 'text-left'} ${className}`}
      aria-sort={ativo ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
      <button type="button" onClick={() => onSort(sortKey)}
        className={`inline-flex select-none items-center gap-1 transition-colors hover:text-foreground ${ativo ? 'text-foreground' : ''}`}>
        {children}
        <Icone className={`h-3 w-3 ${ativo ? 'opacity-100' : 'opacity-40'}`} />
      </button>
    </th>
  )
}
