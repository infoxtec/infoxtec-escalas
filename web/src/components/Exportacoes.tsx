import { useCallback, useEffect, useState } from 'react'
import { Download, HeartPulse, Loader2, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, useToast } from './ui'
import { api, erroMsg, linkExportacao } from '../lib/api'
import type { Exportacao } from '../lib/types'

const ESTADO: Record<Exportacao['estado'], string> = {
  pendente: 'na fila', gerando: 'gerando', pronta: 'pronta', falhou: 'falhou', expirando: 'vencida', expirada: 'vencida',
}
const ORIGEM: Record<Exportacao['origem'], string> = { admin: 'administrador', plataforma: 'plataforma', encerramento: 'encerramento' }

function tamanho(n: number | null) {
  if (n == null) return '—'
  return n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`
}

// Exportação completa da conta (F8c, migrations 143 e 144): o administrador pede a da conta dele; a plataforma, a de
// qualquer conta (conta). O pacote fica 7 dias; o link para baixar é gerado na hora e vale 10 minutos. O pacote de
// saúde só aparece para o administrador com permissão de ver saúde; cada baixa fica registrada.
export default function Exportacoes({ conta }: { conta?: string }) {
  const toast = useToast()
  const [lista, setLista] = useState<Exportacao[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const carregar = useCallback(async () => {
    try { setLista(conta ? await api.plataformaExportacoes(conta) : await api.exportacoes()); setErro(null) }
    catch (e) { setErro(erroMsg(e)) }
  }, [conta])

  useEffect(() => { void carregar() }, [carregar])
  // enquanto há pedido na fila ou gerando, a lista se atualiza sozinha
  useEffect(() => {
    if (!lista?.some(e => e.estado === 'pendente' || e.estado === 'gerando')) return
    const t = setTimeout(() => void carregar(), 5000)
    return () => clearTimeout(t)
  }, [lista, carregar])

  const pedir = async () => {
    setOcupado(true); setErro(null)
    try { conta ? await api.plataformaExportarConta(conta) : await api.contaExportar(); toast('Exportação pedida. Fica pronta em alguns minutos.'); await carregar() }
    catch (e) { setErro(erroMsg(e)) } finally { setOcupado(false) }
  }

  const baixar = async (id: string, saude = false) => {
    setErro(null)
    try { window.location.assign(await linkExportacao(id, saude)); void carregar() } catch (e) { setErro(erroMsg(e)) }
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-xs text-muted-foreground">
          Cópia completa dos dados da conta: uma planilha (CSV) por tabela, os espelhos de ponto emitidos, os documentos dos
          técnicos, o AFD de cada empregadora e o manifesto com o hash de cada arquivo. Fica disponível por 7 dias. Os dados de
          saúde vêm num pacote à parte, só para quem tem permissão de ver saúde.
        </p>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
          <Button size="sm" onClick={() => void pedir()} disabled={ocupado}>
            {ocupado ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Download className="h-3.5 w-3.5" />} Gerar exportação
          </Button>
        </div>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!lista ? (erro ? null : <div className="flex justify-center py-6"><Loader2 className="h-5 w-5 animate-spin" /></div>)
        : lista.length === 0 ? <p className="text-sm text-muted-foreground">Nenhuma exportação ainda.</p> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Pedida em</th><th className="px-3 py-2">Por</th><th className="px-3 py-2">Situação</th>
              <th className="px-3 py-2">Tamanho</th><th className="px-3 py-2">Vale até</th><th className="w-40" />
            </tr></thead>
            <tbody>
              {lista.map(e => (
                <tr key={e.id} className="border-b last:border-0">
                  <td className="px-3 py-2 text-xs">{new Date(e.criado_em).toLocaleString('pt-BR')}</td>
                  <td className="px-3 py-2 text-xs">{ORIGEM[e.origem]}<span className="block text-muted-foreground">{e.pedido_por}</span></td>
                  <td className="px-3 py-2 text-xs">
                    <span className={e.estado === 'pronta' ? 'text-green-700' : e.estado === 'falhou' ? 'text-red-600' : ''}>{ESTADO[e.estado]}</span>
                    {e.erro && <span className="block text-muted-foreground" title={e.erro}>{e.erro.slice(0, 60)}</span>}
                  </td>
                  <td className="px-3 py-2 text-xs">{tamanho(e.tamanho)}
                    {!!e.baixas && <span className="block text-muted-foreground">baixada {e.baixas}x</span>}</td>
                  <td className="px-3 py-2 text-xs">{e.expira_em ? new Date(e.expira_em).toLocaleDateString('pt-BR') : '—'}</td>
                  <td className="px-3 py-2 text-right">
                    {e.estado === 'pronta' && <div className="flex justify-end gap-1">
                      {e.pode_baixar !== false && <Button variant="outline" size="sm" onClick={() => void baixar(e.id)}><Download className="h-3.5 w-3.5" /> Baixar</Button>}
                      {e.saude && <Button variant="outline" size="sm" onClick={() => void baixar(e.id, true)} title="Justificativas de saúde e atestados (dado sensível)">
                        <HeartPulse className="h-3.5 w-3.5" /> Saúde</Button>}
                    </div>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
