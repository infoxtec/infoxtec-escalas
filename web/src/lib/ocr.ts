/**
 * OCR no proprio navegador (tesseract.js).
 * O documento NAO sai da maquina de quem esta cadastrando: nada e enviado para servidor,
 * nem para o nosso, nem para terceiros. Custo zero e sem chave de API.
 *
 * O motor e os dados do idioma (~12 MB) sao baixados de CDN na primeira leitura
 * e ficam em cache do navegador. Por isso a primeira vez demora mais.
 */
export interface ResultadoOCR {
  sugestao: string | null
  datas: string[]
  texto: string
}

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

/** A validade costuma ser a data futura mais proxima; sem futuras, a maior encontrada. */
export function escolherValidade(datas: string[]): string | null {
  if (datas.length === 0) return null
  const hoje = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bahia' })
  const futuras = datas.filter(d => d >= hoje)
  return futuras[0] ?? datas[datas.length - 1]
}

export async function lerValidadeLocal(
  arquivo: File,
  onProgresso?: (fracao: number) => void,
): Promise<ResultadoOCR> {
  const { default: Tesseract } = await import('tesseract.js')
  const { data } = await Tesseract.recognize(arquivo, 'por', {
    logger: (m: { status: string; progress: number }) => {
      if (m.status === 'recognizing text') onProgresso?.(m.progress)
      else onProgresso?.(Math.min(0.15, m.progress * 0.15)) // download do motor e do idioma
    },
  })
  const texto = data.text ?? ''
  const datas = datasEncontradas(texto)
  return { sugestao: escolherValidade(datas), datas, texto }
}
