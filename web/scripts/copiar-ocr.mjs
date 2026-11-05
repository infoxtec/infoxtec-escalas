// OCR no navegador servido pelo próprio site (B1, revisão do seguranca): copia do node_modules para public/ocr o worker
// do tesseract.js, o motor (variantes LSTM) e o português. Sem isso, o tesseract baixaria tudo do jsDelivr, e a CSP
// teria de liberar scripts de um CDN que serve qualquer pacote npm. public/ocr fica fora do Git (gerado no build).
import { copyFileSync, mkdirSync } from 'node:fs'
const destino = new URL('../public/ocr/', import.meta.url)
mkdirSync(destino, { recursive: true })
const nm = new URL('../node_modules/', import.meta.url)
const arquivos = [
  ['tesseract.js/dist/worker.min.js', 'worker.min.js'],
  ['tesseract.js-core/tesseract-core-lstm.wasm.js', 'tesseract-core-lstm.wasm.js'],
  ['tesseract.js-core/tesseract-core-simd-lstm.wasm.js', 'tesseract-core-simd-lstm.wasm.js'],
  ['tesseract.js-core/tesseract-core-relaxedsimd-lstm.wasm.js', 'tesseract-core-relaxedsimd-lstm.wasm.js'],
  ['@tesseract.js-data/por/4.0.0_best_int/por.traineddata.gz', 'por.traineddata.gz'],
]
for (const [de, para] of arquivos) copyFileSync(new URL(de, nm), new URL(para, destino))
console.log(`OCR: ${arquivos.length} arquivos em public/ocr`)
