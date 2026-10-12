import { useCallback, useEffect, useState } from 'react'
import { ExternalLink, FileSignature, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, SuccessBox } from './ui'
import { api, erroMsg } from '../lib/api'
import type { PontoEspelhoEmitido } from '../lib/types'

// Espelho de ponto mensal congelado (decisão 82, parte A): o gestor emite o espelho de um mês encerrado; cada
// funcionário ganha registro, código de verificação e hash. Envio pelo WhatsApp e assinatura: parte B.

function mesAnterior(hoje: string) {
  const [a, m] = hoje.split('-').map(Number)
  return m === 1 ? `${a - 1}-12` : `${a}-${String(m - 1).padStart(2, '0')}`
}
const dataHora = (s: string | null) => s ? new Date(s).toLocaleString('pt-BR', { timeZone: 'America/Bahia', dateStyle: 'short', timeStyle: 'short' }) : null

export default function EspelhosMensais({ hoje, podeEmitir }: { hoje: string; podeEmitir: boolean }) {
  const [mes, setMes] = useState(mesAnterior(hoje))
  const [lista, setLista] = useState<PontoEspelhoEmitido[] | null>(null)
  const [emitindo, setEmitindo] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setErro(null)
    try { setLista(await api.pontoEspelhosEmitidos(`${mes}-01`)) }
    catch (e) { setErro(erroMsg(e)); setLista([]) }
  }, [mes])
  useEffect(() => { void carregar() }, [carregar])

  const emitir = async () => {
    setErro(null); setOk(null); setEmitindo(true)
    try {
      const r = await api.pontoEmitirEspelhos(`${mes}-01`)
      setOk(`${r.emitidos} emitido(s); ${r.sem_mudanca} sem mudança desde a última emissão; ${r.ja_assinados} já assinado(s), não reemitidos; ${r.sem_dados} sem marcação no mês.`)
      await carregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setEmitindo(false) }
  }

  return (
    <section className="space-y-2">
      <h3 className="text-sm font-semibold">Espelho mensal assinado</h3>
      <p className="text-xs text-muted-foreground">
        Emite o espelho de ponto de um mês encerrado para cada funcionário: o conteúdo fica congelado, com número de registro e
        código de verificação (QR). Se algo mudar no ponto do mês, emitir de novo gera uma nova versão; espelho já assinado não é
        reemitido. O envio pelo WhatsApp e a assinatura do funcionário chegam na próxima etapa.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Mês"><Input type="month" value={mes} max={mesAnterior(hoje)} onChange={e => setMes(e.target.value)} disabled={emitindo} /></Field>
        {podeEmitir && <Button size="sm" disabled={emitindo || !mes} onClick={() => void emitir()}><FileSignature className="h-3.5 w-3.5" /> {emitindo ? 'Emitindo...' : 'Emitir espelhos do mês'}</Button>}
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}
      {lista && (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Registro</th><th className="px-3 py-2">Emitido</th>
              <th className="px-3 py-2">Situação</th><th className="px-3 py-2">Verificação</th>
            </tr></thead>
            <tbody>
              {lista.length === 0 ? (
                <tr><td colSpan={5} className="py-8 text-center text-muted-foreground">Nenhum espelho emitido neste mês</td></tr>
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
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
