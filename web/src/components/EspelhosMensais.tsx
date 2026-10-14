import { useCallback, useEffect, useState } from 'react'
import { Eye, ExternalLink, Lock, Printer, RefreshCw, Send } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, SuccessBox } from './ui'
import EspelhoDocumento from './EspelhoDocumento'
import { api, erroMsg } from '../lib/api'
import type { EspelhoCompleto, PontoEspelhoEmitido } from '../lib/types'

// Espelho de ponto mensal congelado (decisão 82): cada funcionário tem registro, código de verificação e hash, e
// assina no app do ponto. A emissão e o envio em lote saíram daqui para a aba Fechamento da folha, que valida antes
// (decisão 96); aqui ficam a consulta, o reenvio e a impressão.

function mesAnterior(hoje: string) {
  const [a, m] = hoje.split('-').map(Number)
  return m === 1 ? `${a - 1}-12` : `${a}-${String(m - 1).padStart(2, '0')}`
}
const dataHora = (s: string | null) => s ? new Date(s).toLocaleString('pt-BR', { timeZone: 'America/Bahia', dateStyle: 'short', timeStyle: 'short' }) : null

export default function EspelhosMensais({ hoje, podeEmitir, rhFolhas }: { hoje: string; podeEmitir: boolean; rhFolhas: boolean }) {
  const [mes, setMes] = useState(mesAnterior(hoje))
  const [lista, setLista] = useState<PontoEspelhoEmitido[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [enviando, setEnviando] = useState(false)
  const [visto, setVisto] = useState<EspelhoCompleto | null>(null)

  const carregar = useCallback(async () => {
    setErro(null)
    try { setLista(await api.pontoEspelhosEmitidos(`${mes}-01`)) }
    catch (e) { setErro(erroMsg(e)); setLista([]) }
  }, [mes])
  useEffect(() => { void carregar() }, [carregar])

  const enviar = async (espelho: string) => {
    setErro(null); setOk(null); setEnviando(true)
    try {
      const r = await api.pontoEnviarEspelhos(`${mes}-01`, espelho)
      setOk(`${r.enviados} enviado(s) pelo WhatsApp; ${r.sem_whatsapp} sem WhatsApp liberado; ${r.desligados} desligado(s), entregar em papel; ${r.falhas} falha(s).`)
      await carregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setEnviando(false) }
  }
  const ver = async (id: string) => {
    setErro(null)
    try { setVisto(await api.pontoEspelhoVer(id)) } catch (e) { setErro(erroMsg(e)) }
  }

  return (
    <section className="space-y-2">
      <h3 className="text-sm font-semibold">Espelho mensal assinado</h3>
      <p className="text-xs text-muted-foreground">
        Os espelhos emitidos no fechamento do mês: conteúdo congelado, com número de registro e código de verificação (QR). Para
        fechar o mês, emitir ou enviar em lote, use a aba Fechamento da folha, que confere antes o que falta em cada funcionário.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Mês"><Input type="month" value={mes} max={mesAnterior(hoje)} onChange={e => setMes(e.target.value)} /></Field>
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}
      {lista && (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Registro</th><th className="px-3 py-2">Emitido</th>
              <th className="px-3 py-2">Situação</th><th className="px-3 py-2">Verificação</th>{podeEmitir && <th className="px-3 py-2" />}
            </tr></thead>
            <tbody>
              {lista.length === 0 ? (
                <tr><td colSpan={6} className="py-8 text-center text-muted-foreground">Nenhum espelho emitido neste mês</td></tr>
              ) : lista.map(e => (
                <tr key={e.id} className="border-b last:border-0">
                  <td className="px-3 py-2"><p className="font-medium">{e.tecnico}</p><p className="text-xs text-muted-foreground">{e.empresa}</p></td>
                  <td className="px-3 py-2 text-xs">nº {e.registro}{e.versao > 1 && <span className="text-muted-foreground"> · versão {e.versao}</span>}</td>
                  <td className="px-3 py-2 text-xs">{dataHora(e.emitido_em)}</td>
                  <td className="px-3 py-2 text-xs">
                    {e.assinado_em ? <span className="font-medium text-green-700">Assinado em {dataHora(e.assinado_em)}</span>
                      : e.enviado_em ? <span className="text-amber-700">Enviado, aguardando assinatura</span>
                      : <span className="text-muted-foreground">Emitido, não enviado</span>}
                  </td>
                  <td className="px-3 py-2 font-mono text-[11px]">
                    <a href={`/v?c=${e.codigo}`} target="_blank" rel="noopener noreferrer" className="inline-flex items-center gap-1 text-primary hover:underline">
                      {e.codigo} <ExternalLink className="h-3 w-3" />
                    </a>
                  </td>
                  {podeEmitir && <td className="whitespace-nowrap px-3 py-2 text-right">
                    {e.enviado_em && !e.assinado_em && <Button variant="ghost" size="sm" disabled={enviando} onClick={() => void enviar(e.id)} title="Reenviar o link pelo WhatsApp"><Send className="h-3.5 w-3.5" /> Reenviar</Button>}
                    {/* assinada: só no cofre de RH (decisão 86) */}
                    {e.assinado_em && !rhFolhas
                      ? <span className="inline-flex items-center gap-1 px-2 text-xs text-muted-foreground" title="A folha assinada fica no cofre de folhas assinadas, aberto só pelo RH"><Lock className="h-3.5 w-3.5" /> No cofre do RH</span>
                      : <Button variant="ghost" size="sm" onClick={() => void ver(e.id)}><Eye className="h-3.5 w-3.5" /> Ver</Button>}
                  </td>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Modal open={!!visto} onClose={() => setVisto(null)} width="max-w-3xl" title="Espelho de ponto"
        footer={<>
          <Button variant="outline" onClick={() => setVisto(null)}>Fechar</Button>
          <Button onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir ou salvar PDF</Button>
        </>}>
        {visto && <EspelhoDocumento e={visto} />}
      </Modal>
    </section>
  )
}
