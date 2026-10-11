import { useEffect, useRef, useState } from 'react'
import { Loader2, ShieldCheck, X } from 'lucide-react'
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import { Button, ErrorBox } from './ui'
import { api, erroMsg } from '../lib/api'

// Visualizador do cofre (decisão 56): o documento da justificativa só é visto aqui, desenhado em tela
// (canvas) com marca d'água de quem vê, sem botão de baixar e sem impressão. Cada abertura fica
// registrada no banco. Limite registrado na decisão: nada impede foto da tela; a marca d'água torna
// o vazamento rastreável.
export default function Cofre({ justificativa, numero, onFechar }: { justificativa: string; numero: number; onFechar: () => void }) {
  const area = useRef<HTMLDivElement>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [carregando, setCarregando] = useState(true)
  const [marca, setMarca] = useState('')

  useEffect(() => {
    document.body.classList.add('cofre-aberto')
    let cancelado = false
    const desenhar = async () => {
      try {
        const lista = await api.pontoAnexos(justificativa)
        if (lista.length === 0) { setErro('Este pedido não tem documento.'); return }
        for (const item of lista) {
          const doc = await api.pontoAnexoVer(item.id)
          if (cancelado || !area.current) return
          const texto = `${doc.visto_por} · ${doc.em} · pedido ${numero}`
          setMarca(texto)
          const bytes = Uint8Array.from(atob(doc.conteudo), c => c.charCodeAt(0))
          if (doc.tipo === 'application/pdf') {
            const pdfjs = await import('pdfjs-dist')
            pdfjs.GlobalWorkerOptions.workerSrc = workerUrl
            const pdf = await pdfjs.getDocument({ data: bytes }).promise
            for (let i = 1; i <= Math.min(pdf.numPages, 10); i++) {
              const pagina = await pdf.getPage(i)
              const base = pagina.getViewport({ scale: 1 })
              const viewport = pagina.getViewport({ scale: Math.min(2, 1100 / base.width) })
              const canvas = novoCanvas(viewport.width, viewport.height)
              const ctx = canvas.getContext('2d')!
              await pagina.render({ canvas, canvasContext: ctx, viewport }).promise
              marcaDagua(ctx, canvas.width, canvas.height, texto)
              area.current?.appendChild(canvas)
            }
          } else {
            const url = URL.createObjectURL(new Blob([bytes], { type: doc.tipo }))
            const img = new Image()
            await new Promise<void>((ok, falha) => { img.onload = () => ok(); img.onerror = () => falha(new Error('Imagem inválida.')); img.src = url })
            const escala = Math.min(1, 1100 / img.width)
            const canvas = novoCanvas(img.width * escala, img.height * escala)
            const ctx = canvas.getContext('2d')!
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height)
            URL.revokeObjectURL(url)
            marcaDagua(ctx, canvas.width, canvas.height, texto)
            area.current?.appendChild(canvas)
          }
        }
      } catch (e) { setErro(erroMsg(e)) } finally { setCarregando(false) }
    }
    void desenhar()
    return () => { cancelado = true; document.body.classList.remove('cofre-aberto') }
  }, [justificativa, numero])

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/70 p-4 select-none"
      onContextMenu={e => e.preventDefault()} onClick={onFechar}>
      {/* sem impressão enquanto o cofre está aberto */}
      <style>{'@media print { body.cofre-aberto * { display: none !important; } }'}</style>
      <div className="w-full max-w-3xl space-y-3 rounded-xl bg-card p-4" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between gap-2">
          <p className="flex items-center gap-1.5 text-sm font-semibold"><ShieldCheck className="h-4 w-4 text-green-700" /> Documento do pedido {numero}</p>
          <Button variant="ghost" size="sm" onClick={onFechar}><X className="h-4 w-4" /> Fechar</Button>
        </div>
        <p className="text-xs text-muted-foreground">Cofre criptografado: só visualização, sem baixar nem imprimir. Esta abertura ficou registrada{marca ? ` (${marca})` : ''}. Não fotografe nem compartilhe a tela.</p>
        {erro && <ErrorBox>{erro}</ErrorBox>}
        {carregando && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>}
        <div ref={area} className="space-y-3 [&>canvas]:mx-auto [&>canvas]:max-w-full [&>canvas]:rounded [&>canvas]:border" />
      </div>
    </div>
  )
}

function novoCanvas(w: number, h: number) {
  const c = document.createElement('canvas')
  c.width = Math.floor(w); c.height = Math.floor(h)
  c.draggable = false
  return c
}

// Marca d'água diagonal repetida com quem vê, quando e o pedido
function marcaDagua(ctx: CanvasRenderingContext2D, w: number, h: number, texto: string) {
  ctx.save()
  ctx.globalAlpha = 0.18
  ctx.fillStyle = '#b91c1c'
  ctx.font = `bold ${Math.max(14, Math.round(w / 45))}px sans-serif`
  ctx.translate(w / 2, h / 2)
  ctx.rotate(-Math.PI / 6)
  const passo = Math.max(90, Math.round(h / 6))
  for (let y = -h; y < h; y += passo) {
    for (let x = -w; x < w; x += ctx.measureText(texto).width + 80) ctx.fillText(texto, x, y)
  }
  ctx.restore()
}
