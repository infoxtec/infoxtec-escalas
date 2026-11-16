import { useEffect, useState } from 'react'
import { FileDown } from 'lucide-react'
import { Button, ErrorBox, Field, Input } from './ui'
import { api, erroMsg } from '../lib/api'
import type { Empresa } from '../lib/types'

// AFD (Art. 81) e AEJ (Art. 83) do REP-P (decisões 81 e 139). Versão de conferência: leiaute dos Anexos V e VI da
// Portaria 671 (a conferir contra o do gov.br), sem o número do INPI. A assinatura CAdES é feita fora do painel, no
// Assinador do ITI/Serpro, sobre o arquivo baixado: nenhum código daqui toca o certificado (decisão do seguranca).
// O texto vem do banco já em ISO 8859-1 (cada caractere até 255) e com CR LF; aqui só vira bytes para baixar.

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

const soDigitos = (s: string) => s.replace(/\D/g, '')

/** CPF de quem responde pelas inclusões e alterações de empresa e empregado no AFD (tipos 2 e 5). Só o admin vê. */
function Responsavel({ empresa }: { empresa: Empresa }) {
  const [cpf, setCpf] = useState('')
  const [salvo, setSalvo] = useState<string | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  useEffect(() => {
    api.pontoResponsavel(empresa.id).then(r => { setSalvo(r?.cpf ?? null); setCpf(r?.cpf ?? '') }).catch(x => setErro(erroMsg(x)))
  }, [empresa.id])
  const salvar = async () => {
    setErro(null); setOcupado(true)
    try { await api.pontoDefinirResponsavel(empresa.id, cpf); setSalvo(soDigitos(cpf)) }
    catch (x) { setErro(erroMsg(x)) }
    finally { setOcupado(false) }
  }
  return (
    <div className="flex flex-wrap items-end gap-2">
      <Field label={`CPF do responsável — ${empresa.nome_fantasia || empresa.razao_social}`}>
        <Input value={cpf} inputMode="numeric" maxLength={14} onChange={x => setCpf(x.target.value)} disabled={ocupado} />
      </Field>
      <Button variant="outline" size="sm" disabled={ocupado || soDigitos(cpf).length !== 11 || soDigitos(cpf) === salvo} onClick={() => void salvar()}>
        Salvar
      </Button>
      {!salvo && <span className="text-xs text-amber-700">Sem CPF: os registros de empresa e de empregado saem com zeros.</span>}
      {erro && <ErrorBox>{erro}</ErrorBox>}
    </div>
  )
}

export default function PontoAfd({ empresas, hoje }: { empresas: Empresa[]; hoje: string }) {
  const [de, setDe] = useState(hoje.slice(0, 8) + '01')
  const [ate, setAte] = useState(hoje)
  const [completo, setCompleto] = useState(false)
  const [gerando, setGerando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [aviso, setAviso] = useState<{ texto: string; nome: string; sha256: string } | null>(null)

  const gerarAfd = async (e: Empresa) => {
    setErro(null); setAviso(null); setGerando(true)
    try {
      const r = await api.pontoAfd(e.id, completo ? null : de, ate)
      baixar(r.nome, r.conteudo)
      setAviso({ nome: r.nome, sha256: r.sha256, texto: `${r.registros} registro(s), ${r.marcacoes} marcação(ões), desde ${r.de}. ${r.aviso}` })
    } catch (x) { setErro(erroMsg(x)) }
    finally { setGerando(false) }
  }
  const gerarAej = async (e: Empresa) => {
    setErro(null); setAviso(null); setGerando(true)
    try {
      const r = await api.pontoAej(e.id, de, ate)
      baixar(r.nome, r.conteudo)
      const c = r.contagens
      setAviso({ nome: r.nome, sha256: r.sha256, texto: `${c.vinculos} funcionário(s), ${c.marcacoes} marcação(ões), ${c.ausencias} ausência(s). ${r.aviso}` })
    } catch (x) { setErro(erroMsg(x)) }
    finally { setGerando(false) }
  }

  return (
    <section className="space-y-3">
      <h3 className="text-sm font-semibold">AFD e AEJ</h3>
      <p className="text-xs text-muted-foreground">
        Versão de conferência para a contadora validar o leiaute: ainda sem o número do INPI. Não entregar à fiscalização.
        A assinatura digital é feita fora do painel, no Assinador do ITI ou do Serpro, sobre o arquivo baixado (gera o .p7s).
        Cada geração fica registrada. Os arquivos têm o CPF de todos: guarde em local protegido e apague depois do uso.
      </p>
      <div className="space-y-2">
        {empresas.map(e => <Responsavel key={e.id} empresa={e} />)}
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="De"><Input type="date" value={de} max={ate} onChange={x => setDe(x.target.value)} disabled={gerando || completo} /></Field>
        <Field label="Até"><Input type="date" value={ate} min={de} max={hoje} onChange={x => setAte(x.target.value)} disabled={gerando} /></Field>
        <label className="flex items-center gap-1 text-xs">
          <input type="checkbox" checked={completo} onChange={x => setCompleto(x.target.checked)} disabled={gerando} />
          AFD desde o primeiro registro
        </label>
      </div>
      {empresas.map(e => (
        <div key={e.id} className="flex flex-wrap items-center gap-2">
          <span className="text-sm">{e.nome_fantasia || e.razao_social}</span>
          <Button variant="outline" size="sm" disabled={gerando || !ate || (!completo && !de)} onClick={() => void gerarAfd(e)}>
            <FileDown className="h-3.5 w-3.5" /> AFD
          </Button>
          <Button variant="outline" size="sm" disabled={gerando || !de || !ate || completo} onClick={() => void gerarAej(e)}
                  title="O AEJ é gerado por até 31 dias">
            <FileDown className="h-3.5 w-3.5" /> AEJ
          </Button>
        </div>
      ))}
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {aviso && (
        <div className="space-y-1 rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900">
          <p><strong>{aviso.nome}</strong>: {aviso.texto}</p>
          <p className="break-all">SHA-256 (para conferir o arquivo assinado): <code>{aviso.sha256}</code></p>
        </div>
      )}
    </section>
  )
}
