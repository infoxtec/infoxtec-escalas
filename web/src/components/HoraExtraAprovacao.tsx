import { useCallback, useEffect, useState } from 'react'
import { Check, Clock, X } from 'lucide-react'
import { Button, ErrorBox, SuccessBox } from './ui'
import { api, erroMsg } from '../lib/api'
import type { PontoHeAutorizacao } from '../lib/types'

const dataBr = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)}`
const ORIGEM: Record<string, string> = { programada: 'Programação', pedido: 'pedido' }
const STATUS: Record<string, { texto: string; cor: string }> = {
  pendente: { texto: 'Aguardando', cor: 'bg-red-100 text-red-800' },
  aprovada: { texto: 'Aprovada', cor: 'bg-green-100 text-green-800' },
  reprovada: { texto: 'Não autorizada', cor: 'bg-amber-100 text-amber-800' },
}

// Hora extra iniciada pelo funcionário (decisão 100, parte 2): a Programação autoriza; o resto vai ao gestor, que
// aprova ou reprova aqui ou pelos botões no WhatsApp. A aprovação é da hora extra, nunca da marcação.
export default function HoraExtraAprovacao({ de, ate, podeDecidir }: { de: string; ate: string; podeDecidir: boolean }) {
  const [lista, setLista] = useState<PontoHeAutorizacao[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [decidindo, setDecidindo] = useState<string | null>(null)
  const carregar = useCallback(async () => {
    try { setLista(await api.pontoHeAutorizacoes(de, ate)) } catch (e) { setErro(erroMsg(e)) }
  }, [de, ate])
  useEffect(() => { void carregar() }, [carregar])

  const decidir = async (h: PontoHeAutorizacao, aprovar: boolean) => {
    setErro(null); setOk(null); setDecidindo(h.id)
    try {
      const r = await api.pontoHeDecidir(h.id, aprovar)
      setOk(r.situacao === 'ja_decidida' ? `O pedido nº ${h.numero} já tinha sido decidido.`
        : `Hora extra nº ${h.numero} de ${h.nome} ${aprovar ? 'aprovada' : 'não autorizada'}. O funcionário foi avisado pelo WhatsApp.`)
      await carregar()
    } catch (e) { setErro(erroMsg(e)) } finally { setDecidindo(null) }
  }

  if (!lista) return erro ? <ErrorBox>{erro}</ErrorBox> : null
  const pendentes = lista.filter(h => h.status === 'pendente').length
  return (
    <section className="space-y-2">
      <div>
        <h3 className="flex items-center gap-1.5 text-sm font-semibold"><Clock className="h-4 w-4" /> Hora extra
          {pendentes > 0 && <span className="rounded bg-red-100 px-1.5 text-xs text-red-800">{pendentes} aguardando</span>}</h3>
        <p className="text-xs text-muted-foreground">
          Início de hora extra fora da Programação vai ao gestor (aqui e pelos botões no WhatsApp). A decisão é da hora
          extra, não da marcação: reprovar não apaga o tempo trabalhado, que continua no espelho. Aguardando decisão
          impede o fechamento da folha.
        </p>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}
      {lista.length === 0 ? <p className="text-xs text-muted-foreground">Nenhuma hora extra iniciada no período.</p> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Nº</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Início</th>
              <th className="px-3 py-2">Origem</th><th className="px-3 py-2">Situação</th><th className="px-3 py-2" />
            </tr></thead>
            <tbody>
              {lista.map(h => (
                <tr key={h.id} className="border-b last:border-0">
                  <td className="px-3 py-2 tabular-nums">{h.numero}</td>
                  <td className="px-3 py-2">{h.nome}</td>
                  <td className="px-3 py-2 tabular-nums">{dataBr(h.data)} {h.hora}</td>
                  <td className="px-3 py-2 text-xs">{ORIGEM[h.origem] ?? h.origem}</td>
                  <td className="px-3 py-2">
                    <span className={`rounded px-1.5 py-0.5 text-xs ${STATUS[h.status].cor}`}>{STATUS[h.status].texto}</span>
                    {h.status !== 'pendente' && h.origem === 'pedido' && (
                      <span className="ml-1 text-xs text-muted-foreground">{h.canal === 'whatsapp' ? 'pelo WhatsApp' : 'no painel'}{h.decidido_por ? ` · ${h.decidido_por}` : ''}</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right">
                    {podeDecidir && h.status === 'pendente' && (
                      <div className="flex justify-end gap-1">
                        <Button size="sm" onClick={() => void decidir(h, true)} disabled={decidindo === h.id}><Check className="h-3.5 w-3.5" /> Aprovar</Button>
                        <Button size="sm" variant="outline" onClick={() => void decidir(h, false)} disabled={decidindo === h.id}><X className="h-3.5 w-3.5" /> Reprovar</Button>
                      </div>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
