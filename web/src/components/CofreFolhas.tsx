import { useCallback, useEffect, useState } from 'react'
import { Download, Eye, FileText, Lock, Printer, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal } from './ui'
import EspelhoDocumento from './EspelhoDocumento'
import { api, erroMsg } from '../lib/api'
import { baixarPdf } from '../lib/types'
import type { EspelhoCompleto, FolhaCofre } from '../lib/types'

// Cofre das folhas de ponto assinadas (decisão 86): só quem tem a permissão de RH vê. Cada abertura e cada prova
// baixada ficam registradas. Para uma ação judicial: a cópia (PDF pela impressão, com o QR e a assinatura) e a
// prova (os bytes exatos do documento, os hashes e os dados da assinatura, para um perito conferir).

const dataHora = (s: string) => new Date(s).toLocaleString('pt-BR', { timeZone: 'America/Bahia', dateStyle: 'short', timeStyle: 'short' })

export default function CofreFolhas({ hoje }: { hoje: string }) {
  const [mes, setMes] = useState('')
  const [lista, setLista] = useState<FolhaCofre[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [visto, setVisto] = useState<EspelhoCompleto | null>(null)
  const [baixando, setBaixando] = useState<string | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    setErro(null)
    try { setLista(await api.pontoCofreFolhas(mes ? `${mes}-01` : null, null)) }
    catch (e) { setErro(erroMsg(e)); setLista([]) }
  }, [mes])
  useEffect(() => { void carregar() }, [carregar])

  const ver = async (id: string) => {
    setErro(null)
    try { setVisto(await api.pontoEspelhoVer(id)); await carregar() } catch (e) { setErro(erroMsg(e)) }
  }
  const prova = async (f: FolhaCofre) => {
    setErro(null); setBaixando(f.id)
    try {
      const p = await api.pontoEspelhoProva(f.id)
      const blob = new Blob([JSON.stringify(p, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = `prova-folha-ponto-${f.competencia.replace('/', '-')}-registro-${f.registro}.json`
      a.click()
      URL.revokeObjectURL(url)
      await carregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setBaixando(null) }
  }

  // PDF assinado guardado no sistema (migration 107): o mesmo arquivo que o funcionário recebeu
  const pdf = async (f: FolhaCofre) => {
    setErro(null); setAviso(null); setBaixando(f.id)
    try {
      const r = await api.pontoEspelhoPdf(f.id)
      if (r.pronto) baixarPdf(r)
      else setAviso('O PDF assinado desta folha está sendo gerado. Tente de novo em alguns segundos.')
      await carregar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setBaixando(null) }
  }

  return (
    <section className="space-y-2">
      <h3 className="flex items-center gap-1.5 text-sm font-semibold"><Lock className="h-4 w-4" /> Cofre de folhas assinadas (RH)</h3>
      <p className="text-xs text-muted-foreground">
        As folhas de ponto assinadas pelos funcionários, guardadas como foram assinadas (não mudam). Para uma ação judicial:
        <strong> Ver</strong> e imprimir ou salvar o PDF (com o QR e a assinatura) e <strong>Baixar prova</strong> (o documento exato,
        os hashes e os dados da assinatura, para perícia). Só quem tem esta permissão vê; cada abertura fica registrada.
      </p>
      <p className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900">
        A prova e o PDF têm dados pessoais do funcionário (nome, CPF, assinatura, IP e aparelho). Guarde só na pasta do
        processo, envie ao advogado por canal seguro e apague da pasta de downloads.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Mês (vazio: todos)"><Input type="month" value={mes} max={hoje.slice(0, 7)} onChange={e => setMes(e.target.value)} /></Field>
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {aviso && <p className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-800">{aviso}</p>}
      {lista && (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Mês</th><th className="px-3 py-2">Registro</th>
              <th className="px-3 py-2">Assinada em</th><th className="px-3 py-2">Aberturas</th><th className="px-3 py-2" />
            </tr></thead>
            <tbody>
              {lista.length === 0 ? (
                <tr><td colSpan={6} className="py-8 text-center text-muted-foreground">Nenhuma folha assinada{mes ? ' neste mês' : ''}</td></tr>
              ) : lista.map(f => (
                <tr key={f.id} className="border-b last:border-0">
                  <td className="px-3 py-2"><p className="font-medium">{f.tecnico}</p><p className="text-xs text-muted-foreground">{f.empresa}</p></td>
                  <td className="px-3 py-2 text-xs">{f.competencia}</td>
                  <td className="px-3 py-2 text-xs">nº {f.registro}{f.versao > 1 && <span className="text-muted-foreground"> · versão {f.versao}</span>}
                    <p className="font-mono text-[11px] text-muted-foreground">{f.codigo}</p></td>
                  <td className="px-3 py-2 text-xs">{dataHora(f.assinado_em)}</td>
                  <td className="px-3 py-2 text-xs">{f.acessos}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right">
                    <Button variant="ghost" size="sm" onClick={() => void ver(f.id)}><Eye className="h-3.5 w-3.5" /> Ver</Button>
                    <Button variant="ghost" size="sm" disabled={baixando === f.id} onClick={() => void pdf(f)}><FileText className="h-3.5 w-3.5" /> PDF assinado</Button>
                    <Button variant="ghost" size="sm" disabled={baixando === f.id} onClick={() => void prova(f)}><Download className="h-3.5 w-3.5" /> Baixar prova</Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Modal open={!!visto} onClose={() => setVisto(null)} width="max-w-3xl" title="Folha de ponto assinada"
        footer={<>
          <Button variant="outline" onClick={() => setVisto(null)}>Fechar</Button>
          <Button onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir ou salvar PDF</Button>
        </>}>
        {visto && <EspelhoDocumento e={visto} />}
      </Modal>
    </section>
  )
}
