// Foto: reduzida a 1600 px e regravada em JPEG no próprio aparelho (tira a localização e os dados da foto)
export async function prepararArquivo(f: File): Promise<{ base64: string; tipo: string }> {
  if (f.type === 'application/pdf') {
    if (f.size > 5 * 1024 * 1024) throw new Error('O PDF precisa ter até 5 MB.')
    const buf = new Uint8Array(await f.arrayBuffer())
    let bin = ''; for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000))
    return { base64: btoa(bin), tipo: 'application/pdf' }
  }
  if (!f.type.startsWith('image/')) throw new Error('O documento precisa ser foto ou PDF.')
  const bmp = await createImageBitmap(f)
  const escala = Math.min(1, 1600 / Math.max(bmp.width, bmp.height))
  const c = document.createElement('canvas')
  c.width = Math.round(bmp.width * escala); c.height = Math.round(bmp.height * escala)
  c.getContext('2d')!.drawImage(bmp, 0, 0, c.width, c.height)
  const url = c.toDataURL('image/jpeg', 0.85)
  return { base64: url.slice(url.indexOf(',') + 1), tipo: 'image/jpeg' }
}
