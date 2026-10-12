import { useEffect, useRef, useState } from 'react'
import { Eraser } from 'lucide-react'
import { Button } from './ui'

// Campo de assinatura com o dedo ou o mouse (decisão 82). Devolve PNG em data URL, ou null enquanto vazio.

export default function AssinaturaCanvas({ onMudou, desabilitado }: { onMudou: (png: string | null) => void; desabilitado?: boolean }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const desenhando = useRef(false)
  const [vazio, setVazio] = useState(true)

  useEffect(() => {
    const cv = ref.current
    if (!cv) return
    const escala = window.devicePixelRatio || 1
    cv.width = cv.clientWidth * escala
    cv.height = cv.clientHeight * escala
    const ctx = cv.getContext('2d')!
    ctx.scale(escala, escala)
    ctx.lineWidth = 2.2
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    ctx.strokeStyle = '#111'
  }, [])

  const ponto = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }
  const inicio = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (desabilitado) return
    e.currentTarget.setPointerCapture(e.pointerId)
    const ctx = e.currentTarget.getContext('2d')!
    const p = ponto(e)
    ctx.beginPath(); ctx.moveTo(p.x, p.y)
    desenhando.current = true
  }
  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!desenhando.current) return
    const ctx = e.currentTarget.getContext('2d')!
    const p = ponto(e)
    ctx.lineTo(p.x, p.y); ctx.stroke()
  }
  const fim = () => {
    if (!desenhando.current) return
    desenhando.current = false
    setVazio(false)
    onMudou(ref.current!.toDataURL('image/png'))
  }
  const limpar = () => {
    const cv = ref.current!
    cv.getContext('2d')!.clearRect(0, 0, cv.width, cv.height)
    setVazio(true); onMudou(null)
  }

  return (
    <div className="space-y-1">
      <div className="relative">
        <canvas ref={ref} className="h-36 w-full touch-none rounded-md border-2 border-dashed bg-white"
          onPointerDown={inicio} onPointerMove={move} onPointerUp={fim} onPointerLeave={fim} onPointerCancel={fim} />
        {vazio && <p className="pointer-events-none absolute inset-0 flex items-center justify-center text-sm text-muted-foreground">Assine aqui com o dedo</p>}
      </div>
      <Button variant="ghost" size="sm" onClick={limpar} disabled={desabilitado || vazio}><Eraser className="h-3.5 w-3.5" /> Limpar</Button>
    </div>
  )
}
