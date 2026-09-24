import { useCallback, useEffect, useMemo, useState } from 'react'
import { Download, ExternalLink, FileText, HardDrive, Link2, Loader2, Paperclip, ScanLine, Trash2 } from 'lucide-react'
import { Button, Confirm, ErrorBox, Field, Input, Modal, Select, useToast } from './ui'
import {
  abrirDocumento, api, enviarDocumento, erroMsg, lerValidadePorOCR, removerDocumento, vincularDocumentoDrive,
} from '../lib/api'
import { lerValidadeLocal } from '../lib/ocr'
import { formatDate, formatDateTime } from '../lib/types'
import type { Documento, Habilidade, Tecnico } from '../lib/types'

const MAX_MB = 8
type Origem = 'storage' | 'drive'

interface Formulario {
  origem: Origem
  tecnico: string
  habilidade: string
  validade: string
  arquivo: File | null
  url: string
  nome: string
}

/** Item 10: documentos em armazenamento privado ou vinculados ao Google Drive,
 *  com leitura da validade feita no proprio navegador. */
export default function DocumentosArquivos({ tecnicos, catalogo, podeEditar }: {
  tecnicos: Tecnico[]; catalogo: Habilidade[]; podeEditar: boolean
}) {
  const toast = useToast()
  const [lista, setLista] = useState<Documento[]>([])
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [form, setForm] = useState<Formulario | null>(null)
  const [enviando, setEnviando] = useState(false)
  const [lendo, setLendo] = useState(false)
  const [progresso, setProgresso] = useState(0)
  const [erroForm, setErroForm] = useState<string | null>(null)
  const [alvo, setAlvo] = useState<Documento | null>(null)

  const carregar = useCallback(async () => {
    setCarregando(true); setErro(null)
    try { setLista(await api.documentos()) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])

  const comValidade = useMemo(() => catalogo.filter(h => h.ativo && h.exige_validade), [catalogo])

  const abrirForm = (origem: Origem) => {
    setErroForm(null); setProgresso(0)
    setForm({ origem, tecnico: '', habilidade: '', validade: '', arquivo: null, url: '', nome: '' })
  }

  /** Leitura local: o documento nao sai do navegador. */
  const lerValidade = async (f: File) => {
    if (!f.type.startsWith('image/')) {
      setErroForm('PDF não é lido automaticamente. Informe a validade ou envie uma foto da página.')
      return
    }
    setLendo(true); setProgresso(0); setErroForm(null)
    try {
      const r = await lerValidadeLocal(f, setProgresso)
      if (r.sugestao) {
        setForm(n => (n ? { ...n, validade: r.sugestao! } : n))
        toast(r.datas.length > 1
          ? `Encontrei ${r.datas.length} datas; sugeri a mais provável. Confira antes de salvar.`
          : 'Validade sugerida pela leitura — confira antes de salvar.')
      } else {
        setErroForm('Não encontrei data no documento. Informe a validade manualmente.')
      }
    } catch (e) { setErroForm(`Falha na leitura: ${erroMsg(e)}`) }
    finally { setLendo(false) }
  }

  const escolherArquivo = async (f: File | null) => {
    if (!form || !f) return
    if (f.size > MAX_MB * 1024 * 1024) { setErroForm(`Arquivo acima de ${MAX_MB} MB.`); return }
    setErroForm(null)
    setForm({ ...form, arquivo: f, nome: f.name })
    if (f.type.startsWith('image/')) await lerValidade(f)
  }

  const salvar = async () => {
    if (!form) return
    setErroForm(null)
    if (!form.tecnico) return setErroForm('Escolha o técnico.')
    setEnviando(true)
    try {
      if (form.origem === 'storage') {
        if (!form.arquivo) { setEnviando(false); return setErroForm('Selecione o arquivo.') }
        await enviarDocumento({
          tecnicoId: form.tecnico, habilidadeId: form.habilidade || null,
          arquivo: form.arquivo, validade: form.validade || null,
        })
      } else {
        if (!form.url.trim()) { setEnviando(false); return setErroForm('Cole o link do Google Drive.') }
        await vincularDocumentoDrive({
          tecnicoId: form.tecnico, habilidadeId: form.habilidade || null,
          url: form.url, nome: form.nome, validade: form.validade || null,
        })
      }
      toast('Documento registrado.')
      setForm(null); await carregar()
    } catch (e) { setErroForm(erroMsg(e)) }
    finally { setEnviando(false) }
  }

  const abrir = async (d: Documento) => {
    try {
      const url = d.origem === 'drive' ? d.url! : await abrirDocumento(d.caminho!)
      window.open(url, '_blank', 'noopener')
    } catch (e) { setErro(erroMsg(e)) }
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
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={() => abrirForm('drive')}>
              <Link2 className="h-4 w-4" /> Vincular do Drive
            </Button>
            <Button size="sm" onClick={() => abrirForm('storage')}>
              <Paperclip className="h-4 w-4" /> Enviar arquivo
            </Button>
          </div>
        )}
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="overflow-hidden rounded-md border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b bg-muted/50 text-left text-xs font-semibold text-muted-foreground">
              <th className="px-3 py-2.5">Técnico</th><th className="px-3 py-2.5">Documento</th>
              <th className="px-3 py-2.5">Arquivo</th><th className="px-3 py-2.5">Onde está</th>
              <th className="px-3 py-2.5">Validade</th><th className="px-3 py-2.5">Registrado</th>
              <th className="w-20 px-3 py-2.5" />
            </tr>
          </thead>
          <tbody>
            {lista.length === 0 && (
              <tr><td colSpan={7} className="py-10 text-center text-muted-foreground">
                {carregando ? 'Carregando...' : 'Nenhum documento registrado'}
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
                </td>
                <td className="px-3 py-2.5 text-xs">
                  {d.origem === 'drive'
                    ? <span className="inline-flex items-center gap-1 text-muted-foreground"><Link2 className="h-3 w-3" /> Google Drive</span>
                    : <span className="inline-flex items-center gap-1 text-muted-foreground"><HardDrive className="h-3 w-3" /> Privado</span>}
                </td>
                <td className="px-3 py-2.5 font-mono text-xs">{d.validade ? formatDate(d.validade) : '—'}</td>
                <td className="px-3 py-2.5 text-xs text-muted-foreground">{formatDateTime(d.created_at)} · {d.enviado_por}</td>
                <td className="px-3 py-2.5 text-right">
                  <div className="flex justify-end gap-1">
                    <Button variant="ghost" size="icon" aria-label="Abrir" onClick={() => void abrir(d)}>
                      {d.origem === 'drive' ? <ExternalLink className="h-3.5 w-3.5" /> : <Download className="h-3.5 w-3.5" />}
                    </Button>
                    {podeEditar && <Button variant="ghost" size="icon" aria-label="Excluir" className="text-destructive hover:bg-destructive/10" onClick={() => setAlvo(d)}><Trash2 className="h-3.5 w-3.5" /></Button>}
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        <strong>Arquivo enviado:</strong> fica em armazenamento privado, criptografado, e abre por link temporário de 2 minutos —
        só administrador e gestor acessam. <strong>Vinculado do Drive:</strong> o arquivo permanece no seu Drive e quem controla
        o acesso é a permissão de lá; a guarda de 5 anos também passa a ser manual. A leitura da validade acontece
        no seu navegador: o documento não é enviado a nenhum servidor.
      </p>

      <Modal open={!!form} onClose={() => { if (!enviando && !lendo) setForm(null) }} width="max-w-md"
        title={form?.origem === 'drive' ? 'Vincular documento do Google Drive' : 'Enviar documento'}
        footer={<>
          <Button variant="outline" onClick={() => setForm(null)} disabled={enviando || lendo}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={enviando || lendo}>{enviando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {form && (
          <div className="space-y-3">
            <Field label="Técnico *">
              <Select className="w-full" value={form.tecnico} disabled={enviando}
                onChange={e => setForm({ ...form, tecnico: e.target.value })}>
                <option value="">Selecione...</option>
                {tecnicos.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
              </Select>
            </Field>

            <Field label="Documento" hint="Ao informar a validade, a habilidade do técnico é atualizada junto.">
              <Select className="w-full" value={form.habilidade} disabled={enviando}
                onChange={e => setForm({ ...form, habilidade: e.target.value })}>
                <option value="">— não vincular —</option>
                {comValidade.map(h => <option key={h.id} value={h.id}>{h.nome}</option>)}
              </Select>
            </Field>

            {form.origem === 'storage' ? (
              <Field label="Arquivo *" hint={`PDF ou imagem, até ${MAX_MB} MB. Em imagens, a validade é lida no seu navegador.`}>
                <input type="file" accept=".pdf,.jpg,.jpeg,.png" disabled={enviando || lendo}
                  onChange={e => void escolherArquivo(e.target.files?.[0] ?? null)}
                  className="w-full text-sm file:mr-3 file:rounded-md file:border file:bg-background file:px-3 file:py-1.5 file:text-sm" />
              </Field>
            ) : (
              <>
                <Field label="Link do Google Drive *" hint="Abra o arquivo no Drive, clique em Compartilhar e copie o link.">
                  <Input value={form.url} placeholder="https://drive.google.com/file/d/..." disabled={enviando}
                    onChange={e => setForm({ ...form, url: e.target.value })} />
                </Field>
                <Field label="Nome do documento" hint="Como vai aparecer na lista.">
                  <Input value={form.nome} placeholder="Ex: ASO 2026 — José Roberto" disabled={enviando}
                    onChange={e => setForm({ ...form, nome: e.target.value })} />
                </Field>
                <Field label="Ler a validade de uma imagem (opcional)" hint="Escolha aqui a mesma foto que está no Drive: ela é lida no navegador e não é enviada nem guardada.">
                  <input type="file" accept=".jpg,.jpeg,.png" disabled={enviando || lendo}
                    onChange={e => { const f = e.target.files?.[0]; if (f) void lerValidade(f) }}
                    className="w-full text-sm file:mr-3 file:rounded-md file:border file:bg-background file:px-3 file:py-1.5 file:text-sm" />
                </Field>
              </>
            )}

            {lendo && (
              <div className="space-y-1">
                <p className="flex items-center gap-2 text-xs text-muted-foreground">
                  <Loader2 className="h-3.5 w-3.5 animate-spin" />
                  {progresso < 0.15 ? 'Preparando o leitor (só na primeira vez)...' : 'Lendo o documento...'}
                </p>
                <div className="h-1.5 w-full overflow-hidden rounded-full bg-muted">
                  <div className="h-full bg-primary transition-all" style={{ width: `${Math.round(progresso * 100)}%` }} />
                </div>
              </div>
            )}

            <Field label="Validade" hint="A leitura sugere; quem confirma é você.">
              <Input type="date" value={form.validade} disabled={enviando}
                onChange={e => setForm({ ...form, validade: e.target.value })} />
            </Field>

            {form.origem === 'storage' && form.arquivo?.type.startsWith('image/') && !lendo && (
              <div className="flex gap-2">
                <Button variant="outline" size="sm" onClick={() => void lerValidade(form.arquivo!)} disabled={enviando}>
                  <ScanLine className="h-3.5 w-3.5" /> Ler de novo
                </Button>
                <Button variant="ghost" size="sm" disabled={enviando}
                  onClick={async () => {
                    const r = await lerValidadePorOCR(form.arquivo!)
                    if (r.sugestao) { setForm(f => (f ? { ...f, validade: r.sugestao! } : f)); toast('Leitura na nuvem concluída.') }
                    else setErroForm(r.erro ?? 'Leitura na nuvem indisponível.')
                  }}>
                  Tentar leitura na nuvem
                </Button>
              </div>
            )}

            {erroForm && <ErrorBox>{erroForm}</ErrorBox>}
          </div>
        )}
      </Modal>

      <Confirm open={!!alvo} title="Excluir documento" confirmLabel="Excluir" destructive busy={enviando}
        onCancel={() => setAlvo(null)} onConfirm={() => void excluir()}>
        <p>
          {alvo?.origem === 'drive'
            ? <>O vínculo com <strong className="text-foreground">{alvo?.nome_arquivo}</strong> sai do painel. O arquivo continua no seu Google Drive.</>
            : <>O arquivo <strong className="text-foreground">{alvo?.nome_arquivo}</strong> de {alvo?.tecnico} será apagado do armazenamento.</>}
        </p>
        <p>A validade cadastrada na habilidade não é alterada.</p>
      </Confirm>
    </div>
  )
}
