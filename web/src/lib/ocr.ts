/**
 * Leitura da validade no proprio navegador. O documento NAO sai da maquina de quem cadastra:
 * nada e enviado ao nosso servidor nem a terceiros. Custo zero, sem chave de API.
 *
 * Tres caminhos, do mais rapido ao mais lento:
 *   1. PDF digital  -> texto extraido direto do arquivo (instantaneo e exato)
 *   2. PDF escaneado -> pagina renderizada em imagem e lida por OCR
 *   3. Imagem       -> OCR direto
 *
 * O motor de OCR e o idioma (~12 MB) sao baixados de CDN na primeira leitura e ficam em cache.
 */
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url'

export type MetodoLeitura = 'texto-pdf' | 'ocr-pdf' | 'ocr-imagem'

export interface ResultadoOCR {
  sugestao: string | null
  datas: string[]
  texto: string
  metodo: MetodoLeitura
}

const PAGINAS_MAX = 3

/** Datas em dd/mm/aaaa, dd-mm-aaaa ou aaaa-mm-dd, devolvidas em ISO e sem repetir. */
export function datasEncontradas(texto: string): string[] {
  const achadas = new Set<string>()
  const limpo = texto.replace(/\s+/g, ' ')
  const brasileiro = /(\d{2})\s*[/.-]\s*(\d{2})\s*[/.-]\s*(\d{4})/g
  const iso = /(\d{4})-(\d{2})-(\d{2})/g
  let m: RegExpExecArray | null
  while ((m = brasileiro.exec(limpo)) !== null) {
    const [, d, mes, a] = m
    if (+mes >= 1 && +mes <= 12 && +d >= 1 && +d <= 31 && +a >= 2000 && +a <= 2100) {
      achadas.add(`${a}-${mes}-${d}`)
    }
  }
  while ((m = iso.exec(limpo)) !== null) achadas.add(`${m[1]}-${m[2]}-${m[3]}`)
  return [...achadas].sort()
}

/**
 * A validade e, em geral, a data futura mais proxima. Quando o documento so tem datas passadas
 * (certificado ja vencido), devolve a maior — que e a validade expirada, e nao a data de emissao.
 */
export function escolherValidade(datas: string[]): string | null {
  if (datas.length === 0) return null
  const hoje = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bahia' })
  const futuras = datas.filter(d => d >= hoje)
  return futuras[0] ?? datas[datas.length - 1]
}

async function ocrDeImagem(fonte: File | HTMLCanvasElement, onProgresso?: (f: number) => void): Promise<string> {
  const { default: Tesseract } = await import('tesseract.js')
  const { data } = await Tesseract.recognize(fonte, 'por', {
    logger: (m: { status: string; progress: number }) => {
      if (m.status === 'recognizing text') onProgresso?.(0.2 + m.progress * 0.8)
      else onProgresso?.(Math.min(0.2, m.progress * 0.2)) // baixando motor e idioma
    },
  })
  return data.text ?? ''
}

async function lerPdf(arquivo: File, onProgresso?: (f: number) => void): Promise<ResultadoOCR> {
  const pdfjs = await import('pdfjs-dist')
  pdfjs.GlobalWorkerOptions.workerSrc = workerUrl

  const doc = await pdfjs.getDocument({ data: await arquivo.arrayBuffer() }).promise
  const paginas = Math.min(PAGINAS_MAX, doc.numPages)

  // 1) PDF digital: o texto ja esta no arquivo
  let texto = ''
  for (let i = 1; i <= paginas; i++) {
    const pagina = await doc.getPage(i)
    const conteudo = await pagina.getTextContent()
    texto += conteudo.items.map(it => ('str' in it ? it.str : '')).join(' ') + '\n'
    onProgresso?.((i / paginas) * 0.3)
  }
  let datas = datasEncontradas(texto)
  if (datas.length > 0) {
    return { sugestao: escolherValidade(datas), datas, texto, metodo: 'texto-pdf' }
  }

  // 2) PDF escaneado: renderiza a pagina e passa pelo OCR
  let textoOcr = ''
  for (let i = 1; i <= Math.min(2, paginas); i++) {
    const pagina = await doc.getPage(i)
    const escala = pagina.getViewport({ scale: 1 })
    // ~1.600 px de largura da uma leitura boa sem estourar memoria no celular
    const zoom = Math.min(3, Math.max(1.5, 1600 / escala.width))
    const viewport = pagina.getViewport({ scale: zoom })
    const canvas = document.createElement('canvas')
    canvas.width = Math.floor(viewport.width)
    canvas.height = Math.floor(viewport.height)
    const ctx = canvas.getContext('2d')
    if (!ctx) continue
    await pagina.render({ canvas, canvasContext: ctx, viewport }).promise
    textoOcr += await ocrDeImagem(canvas, f => onProgresso?.(0.3 + f * 0.7)) + '\n'
    if (datasEncontradas(textoOcr).length > 0) break
  }
  datas = datasEncontradas(textoOcr)
  return { sugestao: escolherValidade(datas), datas, texto: textoOcr, metodo: 'ocr-pdf' }
}

/** Le a validade de um PDF ou de uma imagem. */
export async function lerValidadeLocal(
  arquivo: File,
  onProgresso?: (fracao: number) => void,
): Promise<ResultadoOCR> {
  if (arquivo.type === 'application/pdf' || /\.pdf$/i.test(arquivo.name)) {
    return lerPdf(arquivo, onProgresso)
  }
  const texto = await ocrDeImagem(arquivo, onProgresso)
  const datas = datasEncontradas(texto)
  return { sugestao: escolherValidade(datas), datas, texto, metodo: 'ocr-imagem' }
}

export const DESCRICAO_METODO: Record<MetodoLeitura, string> = {
  'texto-pdf': 'texto do PDF',
  'ocr-pdf': 'leitura da imagem do PDF',
  'ocr-imagem': 'leitura da imagem',
}
