import { useCallback, useEffect, useState } from 'react'
import { ChevronLeft, Loader2, PenLine, Printer } from 'lucide-react'
import { Button, ErrorBox, SuccessBox } from '../components/ui'
import { ponto, erroMsg } from '../lib/api'
import EspelhoDocumento from '../components/EspelhoDocumento'
import AssinaturaCanvas from '../components/AssinaturaCanvas'
import type { EspelhoCompleto } from '../lib/types'

// Espelho mensal no app do funcionário (decisão 82): ele confere, desenha a assinatura e confirma. O link do
// WhatsApp abre direto no espelho (/ponto?espelho=id). A assinatura vale para a versão que ele viu na tela.

type Item = { id: string; competencia: string; registro: number; assinado_em: string | null }

export default function EspelhosApp({ token, onSair, inicial }: { token: string; onSair: () => void; inicial: string | null }) {
  const [lista, setLista] = useState<Item[] | null>(null)
  const [aberto, setAberto] = useState<EspelhoCompleto | null>(null)
  const [png, setPng] = useState<string | null>(null)
  const [ciente, setCiente] = useState(false)
  const [assinando, setAssinando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  const tratar = useCallback((e: unknown) => {
    const m = erroMsg(e)
    if (/Sessão encerrada/.test(m)) onSair(); else setErro(m)
  }, [onSair])

  const abrir = useCallback(async (id: string) => {
    setErro(null); setOk(null); setPng(null); setCiente(false)
    try { setAberto(await ponto.meuEspelho(token, id)) } catch (e) { tratar(e) }
  }, [token, tratar])

  useEffect(() => {
    ponto.meusEspelhos(token).then(setLista).catch(tratar)
    if (inicial) void abrir(inicial)
  }, [token, inicial, abrir, tratar])

  const assinar = async () => {
    if (!aberto || !png) return
    setErro(null); setAssinando(true)
    try {
      const r = await ponto.assinarEspelho(token, aberto.id, aberto.sha256, png)
      setOk(`Espelho assinado em ${r.assinado_em}. Você pode baixar uma cópia em PDF.`)
      await abrir(aberto.id)
      setLista(await ponto.meusEspelhos(token))
    } catch (e) { tratar(e) }
    finally { setAssinando(false) }
  }

  if (aberto) return (
    <div className="space-y-3">
      <Button variant="ghost" size="sm" onClick={() => { setAberto(null); setOk(null); setErro(null) }}><ChevronLeft className="h-4 w-4" /> Meus espelhos</Button>
      <div className="overflow-x-auto rounded-md border bg-white p-3"><EspelhoDocumento e={aberto} /></div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}
      {aberto.conteudo && !aberto.assinado_em && (
        <div className="space-y-3 rounded-md border p-3">
          <p className="text-sm font-semibold">Assinar o espelho</p>
          <p className="text-xs text-muted-foreground">
            Confira os dias acima. Se algo estiver errado, não assine: peça o ajuste na aba Ajuste ou ao seu gestor.
            Ao assinar, ficam guardados com este espelho, por 5 anos, o desenho da sua assinatura, a data, a hora, o endereço de
            internet (IP) e o tipo de aparelho, para comprovar a sua ciência. A conferência pública do QR não mostra nada disso.
          </p>
          <AssinaturaCanvas onMudou={setPng} desabilitado={assinando} />
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-1" checked={ciente} onChange={e => setCiente(e.target.checked)} disabled={assinando} />
            Conferi este espelho e confirmo que ele corresponde à minha jornada de {aberto.conteudo.competencia}.
          </label>
          <Button className="w-full" disabled={!png || !ciente || assinando} onClick={() => void assinar()}>
            {assinando ? <Loader2 className="h-4 w-4 animate-spin" /> : <PenLine className="h-4 w-4" />} Assinar
          </Button>
        </div>
      )}
      {aberto.conteudo && <Button variant="outline" className="w-full" onClick={() => window.print()}><Printer className="h-4 w-4" /> Baixar PDF ou imprimir</Button>}
    </div>
  )

  return (
    <div className="space-y-2">
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!lista ? <div className="flex justify-center py-6"><Loader2 className="h-5 w-5 animate-spin" /></div>
        : lista.length === 0 ? <p className="py-6 text-center text-sm text-muted-foreground">Nenhum espelho emitido para você ainda.</p>
        : lista.map(i => (
          <button key={i.id} type="button" onClick={() => void abrir(i.id)}
            className="flex w-full items-center justify-between rounded-md border p-3 text-left hover:bg-muted/40">
            <span><span className="font-medium">Espelho {i.competencia}</span><span className="block text-xs text-muted-foreground">Registro nº {i.registro}</span></span>
            {i.assinado_em ? <span className="text-xs font-medium text-green-700">Assinado</span> : <span className="text-xs font-medium text-amber-700">Assinar</span>}
          </button>
        ))}
    </div>
  )
}
