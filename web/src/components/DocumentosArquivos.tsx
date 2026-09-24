import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Download, FileText, Loader2, Paperclip, ScanLine, Trash2 } from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, useToast } from './ui'
import { abrirDocumento, api, enviarDocumento, erroMsg, lerValidadePorOCR, removerDocumento } from '../lib/api'
import { formatDate, formatDateTime } from '../lib/types'
import type { Documento, Habilidade, Tecnico } from '../lib/types'

const MAX_MB = 8

/** Item 10: arquivos de NR, CNH e ASO em armazenamento privado, com leitura opcional da validade. */
export default function DocumentosArquivos({ tecnicos, catalogo, podeEditar }: {
  tecnicos: Tecnico[]; catalogo: Habilidade[]; podeEditar: boolean
}) {
  const toast = useToast()
  const arquivoRef = useRef<HTMLInputElement>(null)
  const [lista, setLista] = useState<Documento[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [novo, setNovo] = useState<{ tecnico: string; habilidade: string; validade: string; arquivo: File | null } | null>(null)
  const [enviando, setEnviando] = useState(false)
  const [lendo, setLendo] = useState(false)
  const [erroForm, setErroForm] = useState<string | null>(null)
  const [alvo, setAlvo] = useState<Documento | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try { setLista(await api.documentos()) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const comValidade = useMemo(() => catalogo.filter(h => h.ativo && h.exige_validade), [catalogo])

  const escolher = async (f: File | null) => {
    if (!novo || !f) return
    if (f.size > MAX_MB * 1024 * 1024) { setErroForm(`Arquivo acima de ${MAX_MB} MB.`); return }
    setErroForm(null)
    setNovo({ ...novo, arquivo: f })
    if (!f.type.startsWith('image/')) return
    setLendo(true)
    try {
      const r = await lerValidadePorOCR(f)
      if (r.sugestao) { setNovo(n => (n ? { ...n, arquivo: f, validade: r.sugestao! } : n)); toast('Validade sugerida pela leitura — confira antes de salvar.') }
      else if (r.erro) setErroForm(r.erro)
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setLendo(false) }
  }

  const enviar = async () => {
    if (!novo) return
    setErroForm(null)
    if (!novo.tecnico) return setErroForm('Escolha o técnico.')
    if (!novo.arquivo) return setErroForm('Selecione o arquivo.')
    setEnviando(true)
    try {
      await enviarDocumento({
        tecnicoId: novo.tecnico, habilidadeId: novo.habilidade || null,
        arquivo: novo.arquivo, validade: novo.validade || null,
      })
      toast('Documento enviado.')
      setNovo(null); await carregar()
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setEnviando(false) }
  }

  const abrir = async (d: Documento) => {
    try { window.open(await abrirDocumento(d.caminho), '_blank', 'noopener') }
    catch (e) { setErro(erroMsg(e)) }
  }

  const excluir = async () => {
    if (!alvo) return
    setEnviando(true)
    try { await removerDocumento(alvo.id); setAlvo(null); await carregar() }
    catch (e) { setErro(erroMsg(e)) }
    finally { setEnviando(false) }
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-semibold">Arquivos ({lista.length})</p>
        {podeEditar && (
          <Button size="sm" onClick={() => { setNovo({ tecnico: '', habilidade: '', validade: '', arquivo: null }); setErroForm(null) }}>
            <Paperclip className="h-4 w-4" /> Enviar documento
          </Button>
        )}
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Técnico</th><th className="px-3 py-2.5">Documento</th>
              <th className="px-3 py-2.5">Arquivo</th><th className="px-3 py-2.5">Validade</th>
              <th className="px-3 py-2.5">Enviado</th><th className="w-20 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lista.length === 0 && (
              <tr><td colSpan={6} className="py-10 text-center text-muted-foreground">
                {carregando ? 'Carregando...' : 'Nenhum arquivo enviado'}
              </td></tr>
            )}
            {lista.map(d => (
              <tr key={d.id} className="border-b last:border-0">
                <td className="px-3 py-2.5 font-medium">{d.tecnico}</td>
                <td className="px-3 py-2.5 text-xs">{d.habilidade ?? '—'}</td>
                <td className="px-3 py-2.5 text-xs">
                  <button type="button" onClick={() => void abrir(d)} className="inline-flex items-center gap-1 text-primary hover:underline">
                    <FileText className="h-3.5 w-3.5" />{d.nome_arquivo}
                  </button>
                  {d.tamanho_bytes && <span className="ml-1 text-muted-foreground">({Math.round(d.tamanho_bytes / 1024)} KB)</span>}
                </td>
                <td className="px-3 py-2.5 font-mono text-xs">{d.validade ? formatDate(d.validade) : '—'}</td>
                <td className="px-3 py-2.5 text-xs text-muted-foreground">{formatDateTime(d.created_at)} · {d.enviado_por}</td>
                <td className="px-3 py-2.5 text-right">
                  <div className="flex justify-end gap-1">
                    <Button variant="ghost" size="icon" aria-label="Abrir" onClick={() => void abrir(d)}><Download className="h-3.5 w-3.5" /></Button>
                    {podeEditar && <Button variant="ghost" size="icon" aria-label="Excluir" className="text-destructive hover:bg-destructive/10" onClick={() => setAlvo(d)}><Trash2 className="h-3.5 w-3.5" /></Button>}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        Os arquivos ficam em armazenamento privado, criptografados em repouso, e só abrem por link temporário de 2 minutos.
        A guarda é de 5 anos após o desligamento do técnico — informe a data de desligamento no cadastro para a contagem começar.
      </p>

      <Modal open={!!novo} onClose={() => { if (!enviando) setNovo(null) }} title="Enviar documento" width="max-w-md"
        footer={<>
          <Button variant="outline" onClick={() => setNovo(null)} disabled={enviando}>Cancelar</Button>
          <Button onClick={() => void enviar()} disabled={enviando || lendo}>{enviando ? 'Enviando...' : 'Enviar'}</Button>
        </>}>
        {novo && (
          <div className="space-y-3">
            <Field label="Técnico *">
              <Select className="w-full" value={novo.tecnico} disabled={enviando}
                onChange={e => setNovo({ ...novo, tecnico: e.target.value })}>
                <option value="">Selecione...</option>
                {tecnicos.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
              </Select>
            </Field>
            <Field label="Documento" hint="Ao informar a validade, a habilidade do técnico é atualizada junto.">
              <Select className="w-full" value={novo.habilidade} disabled={enviando}
                onChange={e => setNovo({ ...novo, habilidade: e.target.value })}>
                <option value="">— não vincular —</option>
                {comValidade.map(h => <option key={h.id} value={h.id}>{h.nome}</option>)}
              </Select>
            </Field>
            <Field label="Arquivo *" hint={`PDF ou imagem, até ${MAX_MB} MB. Em imagens, a validade é lida automaticamente.`}>
              <input ref={arquivoRef} type="file" accept=".pdf,.jpg,.jpeg,.png" disabled={enviando}
                onChange={e => void escolher(e.target.files?.[0] ?? null)}
                className="w-full text-sm file:mr-3 file:rounded-md file:border file:bg-background file:px-3 file:py-1.5 file:text-sm" />
            </Field>
            {lendo && (
              <p className="flex items-center gap-2 text-xs text-muted-foreground">
                <Loader2 className="h-3.5 w-3.5 animate-spin" /> Lendo a validade do documento...
              </p>
            )}
            <Field label="Validade" hint="Confira sempre: a leitura automática sugere, quem confirma é você.">
              <Input type="date" value={novo.validade} disabled={enviando}
                onChange={e => setNovo({ ...novo, validade: e.target.value })} />
            </Field>
            {novo.arquivo?.type.startsWith('image/') && !lendo && (
              <Button variant="outline" size="sm" onClick={() => void escolher(novo.arquivo)} disabled={enviando}>
                <ScanLine className="h-3.5 w-3.5" /> Ler validade de novo
              </Button>
            )}
            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Excluir documento" confirmLabel="Excluir" destructive busy={enviando}
        onCancel={() => setAlvo(null)} onConfirm={() => void excluir()}>
        <p>O arquivo <strong className="text-foreground">{alvo?.nome_arquivo}</strong> de {alvo?.tecnico} será apagado do armazenamento. A validade cadastrada na habilidade não é alterada.</p>
      </Confirm>
    </div>
  )
}
