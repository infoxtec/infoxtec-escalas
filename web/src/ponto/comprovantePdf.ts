import type { ComprovanteRegistro } from '../lib/types'

// Comprovante de Registro de Ponto do Trabalhador em PDF (Portaria 671, arts. 79 e 80; migration 110). Os campos vêm
// do banco (ponto_meus_comprovantes, últimas 48 horas); aqui só se desenha. pdf-lib é carregado só quando usado.
// A assinatura PAdES do desenvolvedor (arts. 86 e 88) entra quando houver o certificado ICP-Brasil.

const ROTULO: Record<string, string> = {
  entrada: 'Entrada', saida_almoco: 'Saída para o almoço', volta_almoco: 'Volta do almoço', saida: 'Saída',
  inicio_he: 'Início de hora extra', fim_he: 'Fim de hora extra',
}
const cpfFmt = (c: string) => c.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4')
const cnpjFmt = (c: string) => c.replace(/^([0-9A-Z]{2})([0-9A-Z]{3})([0-9A-Z]{3})([0-9A-Z]{4})(\d{2})$/, '$1.$2.$3/$4-$5')
// a fonte padrão do PDF só tem o alfabeto latino (WinAnsi)
const txt = (s: unknown) => String(s ?? '').normalize('NFC').replace(/[^\x20-\x7E -ÿ–—…]/g, '?')

export async function baixarComprovante(c: ComprovanteRegistro) {
  const { PDFDocument, StandardFonts, rgb } = await import('pdf-lib')
  const doc = await PDFDocument.create()
  doc.setTitle(`${c.titulo} - NSR ${c.nsr}`)
  doc.setAuthor(c.empregador)
  doc.setCreator('Trilha Ponto')
  const f = await doc.embedFont(StandardFonts.Helvetica)
  const b = await doc.embedFont(StandardFonts.HelveticaBold)
  const page = doc.addPage([420, 400])
  let y = 370
  const linha = (s: string, size = 9, bold = false) => {
    page.drawText(txt(s), { x: 24, y, size, font: bold ? b : f, color: rgb(0, 0, 0), maxWidth: 372 })
    y -= size + 6
  }
  linha(c.titulo, 12, true)
  y -= 4
  linha(`NSR: ${c.nsr}`, 10, true)
  linha(`Empregador: ${c.empregador}`)
  linha(`CNPJ: ${cnpjFmt(c.cnpj)}${c.cei_caepf_cno ? ` · CEI/CAEPF/CNO: ${c.cei_caepf_cno}` : ''}`)
  if (c.local) linha(`Local: ${c.local}`)
  linha(`Trabalhador: ${c.trabalhador}`)
  linha(`CPF: ${cpfFmt(c.cpf)}`)
  linha(`Data e hora: ${c.data} ${c.hora} (${c.fuso})`, 10, true)
  linha(`Marcação: ${ROTULO[c.tipo] ?? c.tipo} · registrada pelo ${c.canal === 'app' ? 'app' : c.canal === 'whatsapp' ? 'WhatsApp' : 'telefone'}`)
  linha(`Registro do programa no INPI: ${c.inpi ?? 'em registro'}`)
  y -= 4
  linha('Código hash (SHA-256) da marcação:', 8, true)
  linha(c.sha256.slice(0, 32), 8)
  linha(c.sha256.slice(32), 8)
  page.drawText(txt('Trilha Ponto · registrador eletrônico de ponto via programa'), { x: 24, y: 20, size: 7, font: f, color: rgb(0.4, 0.4, 0.4) })
  const bytes = await doc.save()
  const url = URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: 'application/pdf' }))
  const a = document.createElement('a')
  a.href = url
  a.download = `comprovante-ponto-nsr-${c.nsr}.pdf`
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
