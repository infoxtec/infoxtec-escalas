import { useEffect, useRef, useState } from 'react'
import { Loader2, ShieldCheck, X } from 'lucide-react'
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'
import qrcode from 'qrcode-generator'
import type { PontoDocumento } from '../lib/types'
import { Button, ErrorBox, Input } from './ui'
import { api, erroMsg } from '../lib/api'

// Visualizador do cofre (decisão 56): o documento da justificativa só é visto aqui, desenhado em tela
// (canvas) com marca d'água de quem vê, sem botão de baixar e sem impressão. Cada abertura fica
// registrada no banco. Limite registrado na decisão: nada impede foto da tela; a marca d'água torna
// o vazamento rastreável. Por cima de cada página vai o timbre com o registro do documento, a data e a
// hora do recebimento, a integridade (SHA-256) e o QR de verificação (decisão 62). O arquivo do cofre não
// muda: timbre e QR existem só na tela.
export default function Cofre({ justificativa, numero, onFechar }: { justificativa: string; numero: number; onFechar: () => void }) {
  const area = useRef<HTMLDivElement>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [carregando, setCarregando] = useState(true)
  const [marca, setMarca] = useState('')
  const [anexos, setAnexos] = useState<{ id: string; tipo: string }[]>([])
  const [aviso, setAviso] = useState<string | null>(null)
  const [descartando, setDescartando] = useState<string | null>(null)
  const [motivo, setMotivo] = useState('')
  const [timbre, setTimbre] = useState<PontoDocumento | null>(null)

  useEffect(() => {
    document.body.classList.add('cofre-aberto')
    let cancelado = false
    const desenhar = async () => {
      try {
        const lista = await api.pontoAnexos(justificativa)
        if (lista.length === 0) { setErro('Este pedido não tem documento (ou ele foi descartado).'); return }
        setAnexos(lista)
        for (const item of lista) {
          const doc = await api.pontoAnexoVer(item.id)
          if (cancelado || !area.current) return
          const texto = `${doc.visto_por} · ${doc.em} · pedido ${numero}`
          setMarca(texto)
          setTimbre(doc)
          const bytes = Uint8Array.from(atob(doc.conteudo), c => c.charCodeAt(0))
          if (doc.tipo === 'application/pdf') {
            const pdfjs = await import('pdfjs-dist')
            pdfjs.GlobalWorkerOptions.workerSrc = workerUrl
            const pdf = await pdfjs.getDocument({ data: bytes }).promise
            if (pdf.numPages > 10) setAviso(`O PDF tem ${pdf.numPages} páginas; aqui aparecem as 10 primeiras.`)
            for (let i = 1; i <= Math.min(pdf.numPages, 10); i++) {
              const pagina = await pdf.getPage(i)
              const base = pagina.getViewport({ scale: 1 })
              const viewport = pagina.getViewport({ scale: Math.min(2, 1100 / base.width) })
              const pag = novoCanvas(viewport.width, viewport.height)
              await pagina.render({ canvas: pag, canvasContext: pag.getContext('2d')!, viewport }).promise
              area.current?.appendChild(compor(pag, pag.width, pag.height, doc, texto, i, Math.min(pdf.numPages, 10)))
            }
          } else {
            const url = URL.createObjectURL(new Blob([bytes], { type: doc.tipo }))
            const img = new Image()
            await new Promise<void>((ok, falha) => { img.onload = () => ok(); img.onerror = () => falha(new Error('Imagem inválida.')); img.src = url })
            const escala = Math.min(1, 1100 / img.width)
            area.current?.appendChild(compor(img, img.width * escala, img.height * escala, doc, texto, 1, 1))
            URL.revokeObjectURL(url)
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
        {timbre && !timbre.integro && <ErrorBox>Atenção: o arquivo não confere com o SHA-256 gravado no recebimento. Não use este documento e avise o administrador.</ErrorBox>}
        {erro && <ErrorBox>{erro}</ErrorBox>}
        {aviso && <p className="text-xs text-amber-700">{aviso}</p>}
        {carregando && <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div>}
        <div ref={area} className="space-y-3 [&>canvas]:mx-auto [&>canvas]:max-w-full [&>canvas]:rounded [&>canvas]:border" />
        {anexos.length > 0 && (
          <div className="space-y-1.5 border-t pt-2 text-xs">
            <p className="text-muted-foreground">Documento errado (outra pessoa, com CID, foto ilegível) ou pedido do funcionário? Descarte: o arquivo sai do cofre e fica só o registro de que existiu.</p>
            {anexos.map((a, i) => descartando === a.id ? (
              <div key={a.id} className="flex items-center gap-1.5">
                <Input value={motivo} onChange={e => setMotivo(e.target.value)} placeholder="Motivo do descarte" className="h-8" />
                <Button size="sm" variant="outline" disabled={motivo.trim().length < 10} onClick={async () => {
                  try { await api.pontoAnexoDescartar(a.id, motivo.trim()); onFechar() } catch (e) { setErro(erroMsg(e)) }
                }}>Descartar</Button>
              </div>
            ) : <Button key={a.id} size="sm" variant="ghost" onClick={() => { setDescartando(a.id); setMotivo('') }}>Descartar documento {i + 1}</Button>)}
          </div>
        )}
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

// Página com o timbre em cima: empresa, registro, recebimento, integridade e o QR de verificação
const TIMBRE = 150
function compor(origem: CanvasImageSource, w: number, h: number, doc: PontoDocumento, texto: string, pagina: number, paginas: number) {
  const largura = Math.max(Math.floor(w), 560)
  const canvas = novoCanvas(largura, TIMBRE + h)
  const ctx = canvas.getContext('2d')!
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, canvas.width, canvas.height)
  ctx.drawImage(origem, Math.floor((largura - w) / 2), TIMBRE, w, h)

  // faixa do timbre
  ctx.fillStyle = '#f8fafc'
  ctx.fillRect(0, 0, largura, TIMBRE)
  ctx.fillStyle = '#2563eb'
  ctx.fillRect(0, 0, 6, TIMBRE)
  ctx.strokeStyle = '#cbd5e1'
  ctx.beginPath(); ctx.moveTo(0, TIMBRE - 0.5); ctx.lineTo(largura, TIMBRE - 0.5); ctx.stroke()

  const qrLado = TIMBRE - 20
  const x = 20
  ctx.textBaseline = 'top'
  ctx.fillStyle = '#0f172a'
  ctx.font = 'bold 17px Montserrat, sans-serif'
  ctx.fillText(`Trilha Ponto · ${doc.empresa}`, x, 16, largura - qrLado - 50)
  ctx.font = 'bold 15px sans-serif'
  ctx.fillText(`Registro nº ${doc.registro ?? '—'} · Pedido nº ${doc.pedido}${paginas > 1 ? ` · página ${pagina} de ${paginas}` : ''}`, x, 44, largura - qrLado - 50)
  ctx.font = '14px sans-serif'
  ctx.fillStyle = '#334155'
  ctx.fillText(`Recebido em ${doc.recebido_em ?? '—'} (horário local) · pelo ${doc.canal}`, x, 69, largura - qrLado - 50)
  ctx.fillStyle = doc.integro ? '#15803d' : '#b91c1c'
  ctx.font = 'bold 13px monospace'
  ctx.fillText(`${doc.integro ? '✓ Íntegro' : '✗ NÃO CONFERE'} · SHA-256 ${doc.sha256.slice(0, 16)}…${doc.sha256.slice(-8)}`, x, 94, largura - qrLado - 50)
  ctx.fillStyle = '#64748b'
  ctx.font = '11px sans-serif'
  ctx.fillText('Registra o recebimento e a integridade do arquivo guardado, não a emissão do documento. Confira pelo QR (exige login).', x, 120, largura - qrLado - 50)

  // QR: endereço de conferência no próprio painel, com o código aleatório do registro
  if (doc.codigo) {
    const qr = qrcode(0, 'M')
    qr.addData(`${window.location.origin}/?verificar=${doc.codigo}`)
    qr.make()
    const n = qr.getModuleCount()
    const cel = Math.max(1, Math.floor(qrLado / (n + 2)))
    const lado = cel * (n + 2)
    const qx = largura - lado - 10, qy = Math.floor((TIMBRE - lado) / 2)
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(qx, qy, lado, lado)
    ctx.fillStyle = '#000000'
    for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) ctx.fillRect(qx + (c + 1) * cel, qy + (r + 1) * cel, cel, cel)
  }
  marcaDagua(ctx, canvas.width, canvas.height, texto)
  return canvas
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
