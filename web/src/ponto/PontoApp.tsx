import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, Clock, Loader2, LogOut, MapPin, ShieldCheck, XCircle } from 'lucide-react'
import { Button, ErrorBox, Field, Input } from '../components/ui'
import { erroMsg, ponto } from '../lib/api'
import { formatCpf } from '../lib/types'
import type { PontoComprovante, PontoEu, PontoMarcacao, PontoTipo } from '../lib/types'

// App do funcionário (Módulo Registro de Ponto, docs/modulo-registro-de-ponto/). Abre em /ponto.
// Login por CPF + código no WhatsApp; o token fica só neste aparelho; sessão única no banco.

const CHAVE_TOKEN = 'trilha.ponto.token'
const VERSAO_AVISO = 'v1-2026-10-06'
const APP_VERSAO = __APP_VERSION__

const TIPOS: { id: PontoTipo; label: string }[] = [
  { id: 'entrada', label: 'Entrada' },
  { id: 'saida_almoco', label: 'Saída para almoço' },
  { id: 'volta_almoco', label: 'Volta do almoço' },
  { id: 'saida', label: 'Saída' },
  { id: 'inicio_he', label: 'Início de hora extra' },
  { id: 'fim_he', label: 'Fim de hora extra' },
]
const LABEL = Object.fromEntries(TIPOS.map(t => [t.id, t.label])) as Record<PontoTipo, string>
// Sugestão do próximo botão, a partir da última marcação do dia (só sugere: todos ficam disponíveis)
const PROXIMO: Record<string, PontoTipo> = { '': 'entrada', entrada: 'saida_almoco', saida_almoco: 'volta_almoco', volta_almoco: 'saida', saida: 'inicio_he', inicio_he: 'fim_he', fim_he: 'entrada' }

function lerToken() { try { return localStorage.getItem(CHAVE_TOKEN) } catch { return null } }
function gravarToken(t: string | null) { try { t ? localStorage.setItem(CHAVE_TOKEN, t) : localStorage.removeItem(CHAVE_TOKEN) } catch { /* sem armazenamento */ } }

function Marca() {
  return (
    <div className="flex items-center justify-center gap-2 py-5">
      <img src="/trilha-icone.svg" alt="" className="h-7 w-7" />
      <span className="font-[Montserrat] text-2xl font-bold text-[#2563eb]">Trilha</span>
      <span className="text-lg font-medium text-muted-foreground">Ponto</span>
    </div>
  )
}

export default function PontoApp() {
  const [token, setToken] = useState<string | null>(lerToken)
  const sair = useCallback(() => { const t = lerToken(); if (t) void ponto.sair(t).catch(() => {}); gravarToken(null); setToken(null) }, [])
  return (
    <div className="mx-auto min-h-screen max-w-md px-4 pb-10">
      <Marca />
      {token ? <Painel token={token} onSair={sair} /> : <Entrar onEntrou={t => { gravarToken(t); setToken(t) }} />}
    </div>
  )
}

function Entrar({ onEntrou }: { onEntrou: (t: string) => void }) {
  const [cpf, setCpf] = useState('')
  const [codigo, setCodigo] = useState('')
  const [etapa, setEtapa] = useState<'cpf' | 'codigo'>('cpf')
  const [msg, setMsg] = useState<string | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)

  const pedir = async () => {
    setErro(null); setOcupado(true)
    try { const r = await ponto.pedirCodigo(cpf); setMsg(r.mensagem); setEtapa('codigo') }
    catch (e) { setErro(erroMsg(e)) } finally { setOcupado(false) }
  }
  const entrar = async () => {
    setErro(null); setOcupado(true)
    try { const r = await ponto.entrar(cpf, codigo); if (r.erro) setErro(r.erro); else if (r.token) onEntrou(r.token) }
    catch (e) { setErro(erroMsg(e)) } finally { setOcupado(false) }
  }

  return (
    <div className="space-y-4 rounded-xl border bg-card p-5">
      <h1 className="text-base font-semibold">Bater ponto</h1>
      <Field label="CPF"><Input inputMode="numeric" value={formatCpf(cpf.replace(/\D/g, '').slice(0, 11))} placeholder="000.000.000-00"
        onChange={e => setCpf(e.target.value.replace(/\D/g, ''))} disabled={ocupado || etapa === 'codigo'} /></Field>
      {etapa === 'cpf' ? (
        <>
          <Button className="w-full" onClick={() => void pedir()} disabled={ocupado || cpf.length !== 11}>
            {ocupado ? <Loader2 className="h-4 w-4 animate-spin" /> : null} Receber código no WhatsApp
          </Button>
          <button className="w-full text-center text-xs text-primary hover:underline" onClick={() => { setEtapa('codigo'); setMsg('Digite o código que o seu gestor passou.') }}
            disabled={cpf.length !== 11}>Recebi o código do meu gestor</button>
        </>
      ) : (
        <>
          {msg && <p className="text-sm text-muted-foreground">{msg}</p>}
          <Field label="Código de 6 dígitos"><Input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={codigo}
            onChange={e => setCodigo(e.target.value.replace(/\D/g, ''))} disabled={ocupado} /></Field>
          <Button className="w-full" onClick={() => void entrar()} disabled={ocupado || codigo.length !== 6}>
            {ocupado ? <Loader2 className="h-4 w-4 animate-spin" /> : null} Entrar
          </Button>
          <button className="w-full text-center text-xs text-muted-foreground hover:underline" onClick={() => { setEtapa('cpf'); setCodigo(''); setMsg(null) }}>Trocar CPF ou pedir outro código</button>
        </>
      )}
      {erro && <ErrorBox>{erro}</ErrorBox>}
    </div>
  )
}

function posicao(): Promise<GeolocationPosition> {
  return new Promise((ok, falha) => {
    if (!navigator.geolocation) return falha(new Error('Este aparelho não informa a localização.'))
    navigator.geolocation.getCurrentPosition(ok, e => falha(new Error(
      e.code === 1 ? 'Permita o acesso à localização para bater o ponto. Ela é usada só neste momento.'
        : 'Não foi possível obter a localização. Vá para um lugar aberto e tente de novo.')),
      { enableHighAccuracy: true, timeout: 20000, maximumAge: 0 })
  })
}

function Painel({ token, onSair }: { token: string; onSair: () => void }) {
  const [eu, setEu] = useState<PontoEu | null>(null)
  const [historico, setHistorico] = useState<PontoMarcacao[]>([])
  const [erro, setErro] = useState<string | null>(null)
  const [batendo, setBatendo] = useState<PontoTipo | null>(null)
  const [comprovante, setComprovante] = useState<PontoComprovante | null>(null)

  const carregar = useCallback(async () => {
    try {
      const [e, h] = await Promise.all([ponto.eu(token, VERSAO_AVISO), ponto.minhasMarcacoes(token, 7)])
      setEu(e); setHistorico(h)
    } catch (e) {
      const m = erroMsg(e)
      if (/Sessão encerrada/.test(m)) onSair(); else setErro(m)
    }
  }, [token, onSair])
  useEffect(() => { void carregar() }, [carregar])

  const bater = async (tipo: PontoTipo) => {
    setErro(null); setBatendo(tipo)
    try {
      const p = await posicao()
      const c = await ponto.bater(token, tipo, p.coords.latitude, p.coords.longitude, Math.round(p.coords.accuracy), APP_VERSAO)
      setComprovante(c); await carregar()
    } catch (e) {
      const m = erroMsg(e)
      if (/Sessão encerrada/.test(m)) onSair(); else setErro(m)
    } finally { setBatendo(null) }
  }

  if (!eu) return <div className="flex justify-center py-10">{erro ? <ErrorBox>{erro}</ErrorBox> : <Loader2 className="h-5 w-5 animate-spin" />}</div>
  if (!eu.ciente) return <Aviso empresa={eu.empresa} onCiente={async () => { await ponto.registrarCiencia(token, VERSAO_AVISO); await carregar() }} />

  const ultima = eu.hoje.length ? eu.hoje[eu.hoje.length - 1].tipo : ''
  const sugerido = PROXIMO[ultima]
  const hora = new Date().getHours() * 60 + new Date().getMinutes()
  const lembrarAlmoco = ultima === 'entrada' && hora >= 11 * 60 + 30 && hora <= 14 * 60

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <div className="leading-tight"><p className="text-sm font-semibold">Olá, {eu.nome.split(' ')[0]}</p><p className="text-xs text-muted-foreground">{eu.empresa}</p></div>
        <Button variant="ghost" size="sm" onClick={onSair}><LogOut className="h-4 w-4" /> Sair</Button>
      </div>

      {lembrarAlmoco && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          Hora do almoço? Bom apetite! Lembre de marcar a <strong>saída para o almoço</strong>.
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        {TIPOS.map(t => (
          <button key={t.id} onClick={() => void bater(t.id)} disabled={!!batendo}
            className={`flex min-h-[88px] flex-col items-center justify-center gap-1 rounded-xl border p-3 text-center text-sm font-semibold transition-colors disabled:opacity-60 ${t.id === sugerido ? 'border-primary bg-primary text-primary-foreground' : 'bg-card hover:border-primary'}`}>
            {batendo === t.id ? <Loader2 className="h-6 w-6 animate-spin" /> : <Clock className="h-6 w-6" />}
            {t.label}
          </button>
        ))}
      </div>
      <p className="flex items-center gap-1.5 text-xs text-muted-foreground"><MapPin className="h-3.5 w-3.5" /> A localização é registrada só no momento da marcação.</p>
      {erro && <ErrorBox>{erro}</ErrorBox>}

      <section className="rounded-xl border bg-card">
        <h2 className="border-b px-4 py-2 text-sm font-semibold">Minhas marcações (7 dias)</h2>
        {historico.length === 0 ? <p className="px-4 py-6 text-center text-sm text-muted-foreground">Nenhuma marcação ainda.</p> : (
          <ul className="divide-y text-sm">
            {historico.map(m => (
              <li key={m.nsr} className="flex items-center justify-between gap-2 px-4 py-2">
                <div><p className="font-medium">{LABEL[m.tipo]}</p><p className="text-xs text-muted-foreground">{m.data} {m.hora} · NSR {m.nsr}{m.local ? ` · ${m.local}` : ''}</p></div>
                {m.dentro_area === false && <span className="rounded bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-800">fora da área</span>}
              </li>
            ))}
          </ul>
        )}
      </section>

      {comprovante && <Comprovante c={comprovante} onFechar={() => setComprovante(null)} />}
    </div>
  )
}

function Comprovante({ c, onFechar }: { c: PontoComprovante; onFechar: () => void }) {
  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-4 sm:items-center" onClick={onFechar}>
      <div className="w-full max-w-md space-y-3 rounded-xl bg-card p-5" onClick={e => e.stopPropagation()}>
        <div className="flex items-center gap-2 text-green-700 dark:text-green-400"><CheckCircle2 className="h-6 w-6" /><p className="text-base font-semibold">Ponto registrado</p></div>
        <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
          <dt className="text-muted-foreground">Marcação</dt><dd className="font-medium">{LABEL[c.tipo]}</dd>
          <dt className="text-muted-foreground">Data e hora</dt><dd className="font-medium">{c.data} {c.hora}</dd>
          <dt className="text-muted-foreground">NSR</dt><dd>{c.nsr}</dd>
          <dt className="text-muted-foreground">Trabalhador</dt><dd>{c.trabalhador}</dd>
          <dt className="text-muted-foreground">CPF</dt><dd>{formatCpf(c.cpf)}</dd>
          <dt className="text-muted-foreground">Empregador</dt><dd>{c.empresa}</dd>
          <dt className="text-muted-foreground">CNPJ</dt><dd>{c.cnpj.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5')}</dd>
          {c.local && <><dt className="text-muted-foreground">Local</dt><dd>{c.local}</dd></>}
          <dt className="text-muted-foreground">Autenticação</dt><dd className="font-mono text-xs">{c.autenticacao}</dd>
          {c.login_origem === 'gestor' && <><dt className="text-muted-foreground">Acesso</dt><dd>com código gerado pelo gestor</dd></>}
        </dl>
        {c.dentro_area === false && (
          <p className="flex items-start gap-1.5 rounded-md bg-amber-50 p-2 text-xs text-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
            <XCircle className="mt-0.5 h-4 w-4 shrink-0" /> Você está a {c.distancia_m} m do local. A marcação foi registrada normalmente e o gestor será avisado.
          </p>
        )}
        <Button className="w-full" onClick={onFechar}>Fechar</Button>
      </div>
    </div>
  )
}

function Aviso({ empresa, onCiente }: { empresa: string; onCiente: () => Promise<void> }) {
  const [ocupado, setOcupado] = useState(false)
  return (
    <div className="space-y-3 rounded-xl border bg-card p-5 text-sm">
      <div className="flex items-center gap-2"><ShieldCheck className="h-5 w-5 text-primary" /><h1 className="text-base font-semibold">Aviso de privacidade</h1></div>
      <p><strong>{empresa}</strong> registra a sua jornada de trabalho para cumprir a obrigação legal do art. 74 da CLT e da Portaria MTP 671/2021.</p>
      <p>Em cada marcação guardamos: nome, CPF, data e hora (do servidor, na hora legal brasileira), tipo da marcação, canal e <strong>a sua localização no momento da marcação</strong> — nunca de forma contínua. A localização serve para confirmar o local de trabalho e prevenir fraude. Não coletamos foto nem biometria.</p>
      <p>Os dados ficam guardados por 5 anos (prazo da prescrição trabalhista). A Infoxtec Tecnologia e Serviços Ltda opera o sistema em nome do seu empregador. Você pode pedir acesso e correção ao seu empregador, e suas marcações ficam disponíveis neste app.</p>
      <Button className="w-full" disabled={ocupado} onClick={async () => { setOcupado(true); try { await onCiente() } finally { setOcupado(false) } }}>
        {ocupado ? <Loader2 className="h-4 w-4 animate-spin" /> : null} Li e estou ciente
      </Button>
    </div>
  )
}
