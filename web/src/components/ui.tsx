import { createContext, useCallback, useContext, useEffect, useState } from 'react'
import type { ButtonHTMLAttributes, InputHTMLAttributes, ReactNode, TextareaHTMLAttributes } from 'react'
import { AlertTriangle, CheckCircle2, X } from 'lucide-react'

function cx(...c: (string | false | null | undefined)[]) { return c.filter(Boolean).join(' ') }

// ---------------------------------------------------------------- Button
type Variant = 'default' | 'outline' | 'ghost' | 'destructive' | 'destructive-outline'
type Size = 'sm' | 'md' | 'icon'
const VARIANT: Record<Variant, string> = {
  default: 'bg-primary text-primary-foreground hover:opacity-90',
  outline: 'border bg-background hover:bg-muted',
  ghost: 'hover:bg-muted',
  destructive: 'bg-destructive text-destructive-foreground hover:opacity-90',
  'destructive-outline': 'border border-destructive/40 text-destructive hover:bg-destructive/10',
}
const SIZE: Record<Size, string> = { sm: 'h-8 px-3 text-sm', md: 'h-9 px-4 text-sm', icon: 'h-8 w-8' }

export function Button({ variant = 'default', size = 'md', className, ...p }:
  ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; size?: Size }) {
  return (
    <button
      type="button"
      {...p}
      className={cx('inline-flex items-center justify-center gap-1.5 rounded-md font-medium transition-colors',
        'disabled:opacity-50 disabled:pointer-events-none focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40',
        VARIANT[variant], SIZE[size], className)}
    />
  )
}

// ---------------------------------------------------------------- Campos
export function Input({ className, ...p }: InputHTMLAttributes<HTMLInputElement>) {
  return <input {...p} className={cx('h-9 w-full rounded-md border bg-background px-3 text-sm',
    'focus:outline-none focus:ring-2 focus:ring-primary/40 disabled:opacity-60', className)} />
}
export function Textarea({ className, ...p }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea {...p} className={cx('w-full rounded-md border bg-background px-3 py-2 text-sm',
    'focus:outline-none focus:ring-2 focus:ring-primary/40 disabled:opacity-60', className)} />
}
export function Label({ children, className }: { children: ReactNode; className?: string }) {
  return <label className={cx('text-xs font-medium text-muted-foreground', className)}>{children}</label>
}
export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) {
  return (
    <div className="space-y-1">
      <Label>{label}</Label>
      {children}
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
    </div>
  )
}
export function Select({ className, children, ...p }: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return <select {...p} className={cx('h-9 rounded-md border bg-background px-2 text-sm',
    'focus:outline-none focus:ring-2 focus:ring-primary/40', className)}>{children}</select>
}
export function Switch({ checked, onChange, disabled }: { checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <button type="button" role="switch" aria-checked={checked} disabled={disabled}
      onClick={() => onChange(!checked)}
      className={cx('relative inline-flex h-5 w-9 shrink-0 rounded-full transition-colors disabled:opacity-50',
        checked ? 'bg-primary' : 'bg-muted-foreground/30')}>
      <span className={cx('absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition-transform',
        checked ? 'translate-x-4' : 'translate-x-0.5')} />
    </button>
  )
}
export function ToggleRow({ label, description, checked, onChange, disabled }: {
  label: string; description?: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <p className="text-sm font-medium">{label}</p>
        {description && <p className="mt-0.5 text-xs text-muted-foreground">{description}</p>}
      </div>
      <Switch checked={checked} onChange={onChange} disabled={disabled} />
    </div>
  )
}

// ---------------------------------------------------------------- Mensagens
export function ErrorBox({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-start gap-2 rounded-md bg-destructive/10 p-3 text-sm text-destructive">
      <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" /><span>{children}</span>
    </div>
  )
}
export function SuccessBox({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-start gap-2 rounded-md bg-green-50 p-3 text-sm text-green-700 dark:bg-green-900/20 dark:text-green-400">
      <CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /><span>{children}</span>
    </div>
  )
}

// ---------------------------------------------------------------- Overlays
function useEsc(open: boolean, onClose: () => void) {
  useEffect(() => {
    if (!open) return
    const h = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    window.addEventListener('keydown', h)
    return () => window.removeEventListener('keydown', h)
  }, [open, onClose])
}

export function Modal({ open, onClose, title, children, footer, width = 'max-w-lg' }: {
  open: boolean; onClose: () => void; title: ReactNode; children: ReactNode; footer?: ReactNode; width?: string
}) {
  useEsc(open, onClose)
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div role="dialog" aria-modal="true" className={cx('relative flex max-h-[90vh] w-full flex-col rounded-lg border bg-card shadow-xl', width)}>
        <div className="flex items-center justify-between border-b px-5 py-3.5">
          <h2 className="text-base font-semibold">{title}</h2>
          <button onClick={onClose} className="rounded p-1 text-muted-foreground hover:bg-muted" aria-label="Fechar"><X className="h-4 w-4" /></button>
        </div>
        <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="flex justify-end gap-2 border-t px-5 py-3">{footer}</div>}
      </div>
    </div>
  )
}

export function Sheet({ open, onClose, title, children, footer, width = 'sm:max-w-xl' }: {
  open: boolean; onClose: () => void; title: ReactNode; children: ReactNode; footer?: ReactNode; width?: string
}) {
  useEsc(open, onClose)
  if (!open) return null
  return (
    <div className="fixed inset-0 z-50">
      <div className="absolute inset-0 bg-black/40" onClick={onClose} />
      <aside role="dialog" aria-modal="true" className={cx('absolute right-0 top-0 flex h-full w-full flex-col border-l bg-card shadow-xl', width)}>
        <div className="flex items-center justify-between border-b px-5 py-3.5">
          <h2 className="text-base font-semibold">{title}</h2>
          <button onClick={onClose} className="rounded p-1 text-muted-foreground hover:bg-muted" aria-label="Fechar"><X className="h-4 w-4" /></button>
        </div>
        <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="flex justify-end gap-2 border-t px-5 py-3">{footer}</div>}
      </aside>
    </div>
  )
}

export function Confirm({ open, title, children, confirmLabel, onConfirm, onCancel, destructive, busy, disabled }: {
  open: boolean; title: string; children: ReactNode; confirmLabel: string
  onConfirm: () => void; onCancel: () => void; destructive?: boolean; busy?: boolean; disabled?: boolean
}) {
  return (
    <Modal open={open} onClose={() => { if (!busy) onCancel() }} title={title} width="max-w-md"
      footer={<>
        <Button variant="outline" onClick={onCancel} disabled={busy}>Voltar</Button>
        <Button variant={destructive ? 'destructive' : 'default'} onClick={onConfirm} disabled={busy || disabled}>
          {busy ? 'Aguarde...' : confirmLabel}
        </Button>
      </>}>
      <div className="space-y-3 text-sm text-muted-foreground">{children}</div>
    </Modal>
  )
}

// ---------------------------------------------------------------- Toast
const ToastCtx = createContext<(msg: string) => void>(() => {})
export function ToastProvider({ children }: { children: ReactNode }) {
  const [msgs, setMsgs] = useState<{ id: number; msg: string }[]>([])
  const push = useCallback((msg: string) => {
    const id = Date.now() + Math.random()
    setMsgs(m => [...m, { id, msg }])
    setTimeout(() => setMsgs(m => m.filter(x => x.id !== id)), 4500)
  }, [])
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="fixed bottom-4 right-4 z-[60] flex flex-col gap-2">
        {msgs.map(m => (
          <div key={m.id} className="rounded-lg bg-foreground px-4 py-3 text-sm text-background shadow-lg">{m.msg}</div>
        ))}
      </div>
    </ToastCtx.Provider>
  )
}
export const useToast = () => useContext(ToastCtx)
