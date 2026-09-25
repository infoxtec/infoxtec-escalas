import { useMemo, useState } from 'react'
import type { ChangeEvent } from 'react'
import { CheckCircle2, FileStack, Loader2, Trash2, Upload, XCircle } from 'lucide-react'
import { Button, ErrorBox, Modal, Select, useToast } from './ui'
import { enviarDocumento, erroMsg } from '../lib/api'
import { DESCRICAO_METODO, lerValidadeLocal } from '../lib/ocr'
import type { TipoDocumento } from '../lib/types'

const MAX_MB = 8

interface Linha {
  id: string
  arquivo: File
  tipoId: string
  origemTipo: 'nome do arquivo' | 'conteúdo' | 'manual' | 'não identificado'
  validade: string
  metodo: string
  estado: 'lendo' | 'pronto' | 'enviando' | 'enviado' | 'erro'
  erro?: string
}

const semAcento = (s: string) =>
  s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()

/** Acha o tipo de documento cujas palavras-chave aparecem no texto. */
function classificar(texto: string, tipos: TipoDocumento[]): TipoDocumento | null {
  const alvo = semAcento(texto)
  let melhor: { tipo: TipoDocumento; tamanho: number } | null = null
  for (const tipo of tipos) {
    for (const chave of tipo.palavras_chave) {
      const k = semAcento(chave)
      if (k.length >= 3 && alvo.includes(k) && (!melhor || k.length > melhor.tamanho)) {
        melhor = { tipo, tamanho: k.length }  // chave mais especifica ganha (nr-35 antes de nr-3)
      }
    }
  }
  return melhor?.tipo ?? null
}

/**
 * Envio em lote: vários arquivos ou uma pasta inteira. Para cada arquivo o sistema tenta
 * identificar o documento pelo nome e, não achando, pelo conteúdo lido; e sugere a validade.
 * Tudo é conferido numa tabela antes de qualquer envio.
 */
export default function DocumentosLote({ aberto, aoFechar, tecnicoId, tecnicoNome, tipos, aoConcluir }: {
  aberto: boolean; aoFechar: () => void; tecnicoId: string; tecnicoNome: string
  tipos: TipoDocumento[]; aoConcluir: () => Promise<void>
}) {
  const toast = useToast()
  const [linhas, setLinhas] = useState<Linha[]>([])
  const [processando, setProcessando] = useState(false)
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const ativos = useMemo(() => tipos.filter(t => t.ativo), [tipos])

  const receber = async (e: ChangeEvent<HTMLInputElement>) => {
    const escolhidos = Array.from(e.target.files ?? [])
      .filter(f => /\.(pdf|jpe?g|png)$/i.test(f.name))
    if (escolhidos.length === 0) { setErro('Nenhum PDF ou imagem encontrado na seleção.'); return }
    if (escolhidos.length > 40) { setErro('Máximo de 40 arquivos por vez.'); return }
    setErro(null)

    const novas: Linha[] = escolhidos.map((arquivo, i) => {
      const porNome = classificar(arquivo.name, ativos)
      return {
        id: `${Date.now()}-${i}`, arquivo,
        tipoId: porNome?.id ?? '',
        origemTipo: porNome ? 'nome do arquivo' : 'não identificado',
        validade: '', metodo: '',
        estado: arquivo.size > MAX_MB * 1024 * 1024 ? 'erro' : 'lendo',
        erro: arquivo.size > MAX_MB * 1024 * 1024 ? `acima de ${MAX_MB} MB` : undefined,
      }
    })
    setLinhas(novas)
    setProcessando(true)

    // um de cada vez: o OCR usa bastante processador
    for (const linha of novas) {
      if (linha.estado === 'erro') continue
      try {
        const r = await lerValidadeLocal(linha.arquivo)
        const porConteudo = linha.tipoId ? null : classificar(r.texto, ativos)
        setLinhas(l => l.map(x => x.id === linha.id ? {
          ...x,
          tipoId: x.tipoId || (porConteudo?.id ?? ''),
          origemTipo: x.tipoId ? x.origemTipo : (porConteudo ? 'conteúdo' : 'não identificado'),
          validade: r.sugestao ?? '',
          metodo: DESCRICAO_METODO[r.metodo],
          estado: 'pronto',
        } : x))
      } catch (ex) {
        setLinhas(l => l.map(x => x.id === linha.id
          ? { ...x, estado: 'erro', erro: erroMsg(ex) } : x))
      }
    }
    setProcessando(false)
  }

  const prontas = linhas.filter(l => l.estado === 'pronto' && l.tipoId && l.validade)
  const pendentes = linhas.filter(l => l.estado === 'pronto' && (!l.tipoId || !l.validade))

  const enviar = async () => {
    setEnviando(true)
    let ok = 0
    for (const linha of prontas) {
      setLinhas(l => l.map(x => x.id === linha.id ? { ...x, estado: 'enviando' } : x))
      try {
        await enviarDocumento({
          tecnicoId, tipoDocumentoId: linha.tipoId, arquivo: linha.arquivo, validade: linha.validade,
        })
        setLinhas(l => l.map(x => x.id === linha.id ? { ...x, estado: 'enviado' } : x))
        ok++
      } catch (e) {
        setLinhas(l => l.map(x => x.id === linha.id ? { ...x, estado: 'erro', erro: erroMsg(e) } : x))
      }
    }
    setEnviando(false)
    if (ok > 0) { toast(`${ok} documento(s) enviado(s).`); await aoConcluir() }
  }

  const fechar = () => { if (!processando && !enviando) { setLinhas([]); setErro(null); aoFechar() } }
  const mudar = (id: string, campo: 'tipoId' | 'validade', valor: string) =>
    setLinhas(l => l.map(x => x.id === id ? { ...x, [campo]: valor, origemTipo: campo === 'tipoId' ? 'manual' : x.origemTipo } : x))

  return (
    <Modal open={aberto} onClose={fechar} width="max-w-4xl"
      title={<span className="flex items-center gap-2"><FileStack className="h-4 w-4" />Enviar vários documentos — {tecnicoNome}</span>}
      footer={<>
        <Button variant="outline" onClick={fechar} disabled={processando || enviando}>Fechar</Button>
        <Button onClick={() => void enviar()} disabled={processando || enviando || prontas.length === 0}>
          {enviando ? 'Enviando...' : `Enviar ${prontas.length} documento(s)`}
        </Button>
      </>}>
      <div className="space-y-3">
        <div className="grid gap-2 sm:grid-cols-2">
          <label className="flex cursor-pointer items-center justify-center gap-2 rounded-md border-2 border-dashed p-4 text-sm hover:bg-muted/30">
            <Upload className="h-4 w-4 text-muted-foreground" /> Escolher arquivos
            <input type="file" multiple accept=".pdf,.jpg,.jpeg,.png" className="sr-only"
              disabled={processando || enviando} onChange={e => void receber(e)} />
          </label>
          <label className="flex cursor-pointer items-center justify-center gap-2 rounded-md border-2 border-dashed p-4 text-sm hover:bg-muted/30">
            <FileStack className="h-4 w-4 text-muted-foreground" /> Escolher uma pasta
            {/* @ts-expect-error atributo de pasta suportado pelos navegadores, fora do tipo padrão */}
            <input type="file" webkitdirectory="" directory="" multiple className="sr-only"
              disabled={processando || enviando} onChange={e => void receber(e)} />
          </label>
        </div>

        <p className="text-xs text-muted-foreground">
          O tipo é identificado pelo nome do arquivo (ex.: <code>NR35_JOSE.pdf</code>) e, quando o nome não ajuda,
          pelo conteúdo lido. A leitura acontece no seu navegador e nada é enviado antes de você conferir.
        </p>

        {erro && <ErrorBox>{erro}</ErrorBox>}

        {linhas.length > 0 && (
          <>
            <div className="max-h-80 overflow-auto rounded-md border">
              <table className="w-full text-xs">
                <thead className="sticky top-0 bg-muted">
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="px-2 py-2">Arquivo</th><th className="px-2 py-2">Documento</th>
                    <th className="px-2 py-2">Validade</th><th className="px-2 py-2">Identificado por</th>
                    <th className="px-2 py-2">Situação</th><th className="w-8 px-2 py-2" />
                  </tr>
                </thead>
                <tbody>
                  {linhas.map(l => (
                    <tr key={l.id} className="border-b last:border-0">
                      <td className="max-w-[180px] truncate px-2 py-1.5" title={l.arquivo.name}>{l.arquivo.name}</td>
                      <td className="px-2 py-1.5">
                        <Select className={`h-7 w-40 text-xs ${!l.tipoId ? 'border-destructive' : ''}`}
                          value={l.tipoId} disabled={enviando || l.estado === 'enviado'}
                          onChange={e => mudar(l.id, 'tipoId', e.target.value)}>
                          <option value="">— escolher —</option>
                          {ativos.map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
                        </Select>
                      </td>
                      <td className="px-2 py-1.5">
                        <input type="date" value={l.validade} disabled={enviando || l.estado === 'enviado'}
                          onChange={e => mudar(l.id, 'validade', e.target.value)}
                          className={`h-7 rounded border bg-background px-1.5 text-xs ${!l.validade ? 'border-destructive' : ''}`} />
                      </td>
                      <td className="px-2 py-1.5 text-muted-foreground">
                        {l.origemTipo}{l.metodo ? ` · ${l.metodo}` : ''}
                      </td>
                      <td className="px-2 py-1.5">
                        {l.estado === 'lendo' && <span className="inline-flex items-center gap-1 text-muted-foreground"><Loader2 className="h-3 w-3 animate-spin" /> lendo</span>}
                        {l.estado === 'pronto' && (l.tipoId && l.validade
                          ? <span className="text-green-600">pronto</span>
                          : <span className="text-amber-600">falta conferir</span>)}
                        {l.estado === 'enviando' && <span className="inline-flex items-center gap-1"><Loader2 className="h-3 w-3 animate-spin" /> enviando</span>}
                        {l.estado === 'enviado' && <span className="inline-flex items-center gap-1 text-green-600"><CheckCircle2 className="h-3 w-3" /> enviado</span>}
                        {l.estado === 'erro' && <span className="inline-flex items-center gap-1 text-destructive" title={l.erro}><XCircle className="h-3 w-3" /> {l.erro}</span>}
                      </td>
                      <td className="px-2 py-1.5 text-right">
                        {l.estado !== 'enviado' && (
                          <button type="button" disabled={enviando}
                            onClick={() => setLinhas(x => x.filter(y => y.id !== l.id))}
                            className="text-muted-foreground hover:text-destructive"><Trash2 className="h-3.5 w-3.5" /></button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <p className="text-xs text-muted-foreground">
              {linhas.length} arquivo(s) · {prontas.length} pronto(s) para enviar
              {pendentes.length > 0 && <span className="text-amber-600"> · {pendentes.length} precisam de documento ou validade</span>}
              {processando && ' · lendo os arquivos, aguarde'}
            </p>
          </>
        )}
      </div>
    </Modal>
  )
}
