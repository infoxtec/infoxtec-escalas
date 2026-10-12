import { useState } from 'react'
import { FileDown } from 'lucide-react'
import { Button, ErrorBox, Field, Input } from './ui'
import { api, erroMsg } from '../lib/api'
import type { Empresa } from '../lib/types'

// Arquivo Fonte de Dados do REP-P (backlog 085, decisão 81). Versão de conferência: leiaute do Anexo V da
// Portaria 671, ainda sem a assinatura CAdES e sem o número do INPI. O texto vem do banco já em ISO 8859-1
// (cada caractere até 255) e com CR LF; aqui só vira bytes para baixar.

function baixar(nome: string, conteudo: string) {
  const bytes = new Uint8Array(conteudo.length)
  for (let i = 0; i < conteudo.length; i++) {
    const c = conteudo.charCodeAt(i)
    if (c > 255) throw new Error('O arquivo tem caractere fora da ISO 8859-1: não foi baixado.')
    bytes[i] = c
  }
  const url = URL.createObjectURL(new Blob([bytes], { type: 'text/plain;charset=iso-8859-1' }))
  const a = document.createElement('a')
  a.href = url
  a.download = nome
  a.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export default function PontoAfd({ empresas, hoje }: { empresas: Empresa[]; hoje: string }) {
  const [de, setDe] = useState(hoje.slice(0, 8) + '01')
  const [ate, setAte] = useState(hoje)
  const [gerando, setGerando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  const gerar = async (e: Empresa) => {
    setErro(null); setAviso(null); setGerando(true)
    try {
      const r = await api.pontoAfd(e.id, de, ate)
      baixar(r.nome, r.conteudo)
      setAviso(`${r.nome}: ${r.marcacoes} marcação(ões). ${r.aviso}`)
    } catch (x) { setErro(erroMsg(x)) }
    finally { setGerando(false) }
  }

  return (
    <section className="space-y-2">
      <h3 className="text-sm font-semibold">Arquivo Fonte de Dados (AFD)</h3>
      <p className="text-xs text-muted-foreground">
        Versão de conferência para a contadora validar o leiaute: ainda sem assinatura digital e sem o número do INPI.
        Não entregar à fiscalização. Cada geração fica registrada. O arquivo tem o CPF de todos: guarde em local protegido e apague depois do uso.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="De"><Input type="date" value={de} max={ate} onChange={x => setDe(x.target.value)} disabled={gerando} /></Field>
        <Field label="Até"><Input type="date" value={ate} min={de} max={hoje} onChange={x => setAte(x.target.value)} disabled={gerando} /></Field>
        {empresas.map(e => (
          <Button key={e.id} variant="outline" size="sm" disabled={gerando || !de || !ate} onClick={() => void gerar(e)}>
            <FileDown className="h-3.5 w-3.5" /> {e.nome_fantasia || e.razao_social}
          </Button>
        ))}
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {aviso && <p className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900">{aviso}</p>}
    </section>
  )
}
