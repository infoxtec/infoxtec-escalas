import { useCallback, useEffect, useState } from 'react'
import { CheckCircle2, Clock, FileText, Loader2, LogOut, MapPin, ShieldCheck, XCircle } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Select, Textarea } from '../components/ui'
import { erroMsg, ponto } from '../lib/api'
import { formatCpf } from '../lib/types'
import { prepararArquivo } from '../lib/arquivo'
import EspelhosApp from './EspelhosApp'
import type { PontoComprovante, PontoEu, PontoMarcacao, PontoMeuPedido, PontoTipo } from '../lib/types'

// App do funcionário (Módulo Registro de Ponto, docs/modulo-registro-de-ponto/). Abre em /ponto.
// Login por CPF + código no WhatsApp; o token fica só neste aparelho; sessão única no banco.

const CHAVE_TOKEN = 'trilha.ponto.token'
const VERSAO_AVISO = 'v4-2026-10-11'
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
  const [previo, setPrevio] = useState<{ tipo: PontoTipo; texto: string } | null>(null)
  // link do WhatsApp do espelho mensal: /ponto?espelho=id abre direto nele (decisão 82)
  const [espelhoLink] = useState(() => new URLSearchParams(window.location.search).get('espelho'))
  const [aba, setAba] = useState<'ponto' | 'ajuste' | 'espelho'>(() => espelhoLink ? 'espelho' : 'ponto')

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

  // Antes da volta do almoço: avisa se o intervalo ainda está abaixo do mínimo (não bloqueia)
  const escolher = async (tipo: PontoTipo) => {
    setErro(null)
    if (tipo === 'volta_almoco') {
      try {
        const t = await ponto.avisoPrevio(token, tipo)
        if (t) { setPrevio({ tipo, texto: t.replace(/\*/g, '').replace(/^⚠️\s*/, '') }); return }
      } catch { /* sem aviso: segue para a marcação */ }
    }
    await bater(tipo)
  }

  const bater = async (tipo: PontoTipo) => {
    setErro(null); setPrevio(null); setBatendo(tipo)
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

      <div className="grid grid-cols-3 gap-1 rounded-lg border p-0.5">
        {([['ponto', 'Ponto'], ['ajuste', 'Ajuste'], ['espelho', 'Espelho']] as const).map(([id, rotulo]) => (
          <button key={id} type="button" onClick={() => setAba(id)}
            className={`rounded-md py-2 text-sm font-semibold ${aba === id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}>{rotulo}</button>
        ))}
      </div>
      {aba === 'espelho' ? <EspelhosApp token={token} onSair={onSair} inicial={espelhoLink} />
        : aba === 'ajuste' ? <Ajuste token={token} onSair={onSair} onMudou={() => void carregar()} /> : (<>
      {eu.afastado_ate && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Você está <strong>afastado por atestado até {eu.afastado_ate.slice(0, 5)}</strong>: não marca ponto nem recebe escala. Melhoras!
          Para voltar antes, tenha a <strong>liberação médica</strong> em mãos e fale com o seu gestor.
        </div>
      )}

      {lembrarAlmoco && (
        <div className="rounded-lg border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200">
          Hora do almoço? Bom apetite! Lembre de marcar a <strong>saída para o almoço</strong>.
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        {TIPOS.map(t => (
          <button key={t.id} onClick={() => void escolher(t.id)} disabled={!!batendo || !!eu.afastado_ate}
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

      </>)}
      {comprovante && <Comprovante c={comprovante} onFechar={() => setComprovante(null)} />}
      {previo && (
        <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-4 sm:items-center" onClick={() => setPrevio(null)}>
          <div className="w-full max-w-md space-y-3 rounded-xl bg-card p-5" onClick={e => e.stopPropagation()}>
            <p className="flex items-start gap-2 text-sm text-amber-900 dark:text-amber-200">
              <XCircle className="mt-0.5 h-5 w-5 shrink-0 text-amber-600" /> {previo.texto}
            </p>
            <div className="flex gap-2">
              <Button variant="outline" className="flex-1" onClick={() => setPrevio(null)}>Voltar</Button>
              <Button className="flex-1" onClick={() => void bater(previo.tipo)}>Registrar mesmo assim</Button>
            </div>
          </div>
        </div>
      )}
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
        {c.avisos?.map((a, i) => (
          <p key={i} className="flex items-start gap-1.5 rounded-md bg-amber-50 p-2 text-xs text-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
            <XCircle className="mt-0.5 h-4 w-4 shrink-0" /> {a.replace(/^⚠️\s*/, '')}
          </p>
        ))}
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
      <p>Em cada marcação guardamos: nome, CPF, data e hora (do servidor, na hora legal brasileira), tipo da marcação, canal e <strong>a sua localização no momento da marcação</strong> — nunca de forma contínua. A localização serve para confirmar o local de trabalho e prevenir fraude. Para mostrar ao gestor o bairro e a cidade, a localização arredondada (cerca de 100 metros), sem nada que identifique você, é consultada no OpenStreetMap, serviço público no Reino Unido. Não coletamos foto sua nem biometria. Para proteger o seu acesso, o endereço de internet (IP) de cada tentativa de entrada fica guardado por 30 dias.</p>
      <p><strong>Justificativas com documento.</strong> Se você pedir um ajuste por falta (atestado, certidão, convocação), o documento que você enviar fica guardado <strong>criptografado</strong>, para cumprir a lei trabalhista e permitir a defesa de direitos (LGPD art. 11, II, a e d). Só as pessoas autorizadas pelo seu empregador para ver atestados abrem o documento, sem baixar, e cada abertura fica registrada. Não precisa informar a doença nem o CID. A foto é reduzida no seu celular antes do envio, o que tira dela a localização.</p>
      <p>Os dados ficam guardados por 5 anos (prazo da prescrição trabalhista). A Infoxtec Tecnologia e Serviços Ltda opera o sistema em nome do seu empregador. Você pode pedir acesso e correção ao seu empregador, e suas marcações ficam disponíveis neste app.</p>
      <Button className="w-full" disabled={ocupado} onClick={async () => { setOcupado(true); try { await onCiente() } finally { setOcupado(false) } }}>
        {ocupado ? <Loader2 className="h-4 w-4 animate-spin" /> : null} Li e estou ciente
      </Button>
    </div>
  )
}

// Aba Ajuste (084 entrega 3, decisão 55; textos da persona marca, sem ameaça — decisão 57).
// Nesta entrega, só a categoria Ponto; Saúde, Família e Convocação chegam com o anexo (E2).
const GRUPOS = [
  { id: 'ponto', titulo: 'Ponto', ajuda: 'esqueci de marcar, atrasei ou o app falhou' },
  { id: 'saude', titulo: 'Saúde', ajuda: 'atestado, consulta ou exame' },
  { id: 'familia', titulo: 'Família', ajuda: 'falecimento, casamento ou nascimento' },
  { id: 'convocacao', titulo: 'Convocação', ajuda: 'justiça, eleição ou outra' },
] as const
const MOTIVOS_PONTO = [
  { id: 'esqueci_marcar', label: 'Esqueci de marcar' },
  { id: 'falha_registro', label: 'O app ou o WhatsApp não funcionou' },
  { id: 'atraso_saida', label: 'Cheguei atrasado ou saí mais cedo' },
] as const
// Faltas com documento (E2). horario: vale só o horário (das/às); senão, dias inteiros. doc: o que anexar
type MotivoFalta = { id: string; label: string; horario?: boolean; doc: string }
const MOTIVOS_FALTA: Record<string, MotivoFalta[]> = {
  saude: [
    { id: 'atestado', label: 'Atestado médico: vale o dia ou o período indicado', doc: 'atestado' },
    { id: 'alta_medica', label: 'Atestado de aptidão (alta médica): estou liberado para trabalhar', doc: 'atestado de aptidão' },
    { id: 'comparecimento', label: 'Declaração de comparecimento: vale só o horário da consulta', horario: true, doc: 'declaração de comparecimento' },
    { id: 'prenatal', label: 'Acompanhei consulta ou exame do pré-natal', horario: true, doc: 'declaração da consulta do pré-natal' },
    { id: 'filho_6_anos', label: 'Levei filho de até 6 anos ao médico', doc: 'declaração da consulta do seu filho' },
    { id: 'preventivo', label: 'Fiz exame preventivo de câncer', doc: 'comprovante do exame' },
    { id: 'doacao_sangue', label: 'Doei sangue', doc: 'comprovante de doação' },
  ],
  familia: [
    { id: 'falecimento', label: 'Falecimento de cônjuge, pais, avós, filhos, netos, irmão ou dependente: até 2 dias', doc: 'certidão de óbito' },
    { id: 'casamento', label: 'Casamento: até 3 dias', doc: 'certidão de casamento' },
    { id: 'nascimento', label: 'Nascimento ou adoção de filho', doc: 'certidão de nascimento ou termo de adoção' },
  ],
  convocacao: [
    { id: 'justica', label: 'Justiça: audiência, testemunha ou júri', doc: 'intimação ou declaração da audiência' },
    { id: 'eleitoral', label: 'Tirar ou regularizar o título de eleitor', doc: 'comprovante da Justiça Eleitoral' },
    { id: 'mesario', label: 'Trabalhei de mesário ou na eleição', doc: 'declaração da Justiça Eleitoral' },
    { id: 'outra_convocacao', label: 'Serviço militar, vestibular ou reunião sindical internacional', doc: 'convocação' },
  ],
}
const SITUACAO_PEDIDO: Record<PontoMeuPedido['status'], { label: string; cor: string }> = {
  pendente: { label: 'Em análise', cor: 'bg-amber-100 text-amber-800' },
  aprovada: { label: 'Aprovado', cor: 'bg-green-100 text-green-800' },
  negada: { label: 'Não aprovado', cor: 'bg-red-100 text-red-800' },
  cancelada: { label: 'Cancelado', cor: 'bg-muted text-muted-foreground' },
}
function hojeLocal() { const d = new Date(); return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10) }

function Ajuste({ token, onSair, onMudou }: { token: string; onSair: () => void; onMudou: () => void }) {
  const [pedidos, setPedidos] = useState<PontoMeuPedido[] | null>(null)
  const [grupo, setGrupo] = useState<string | null>(null)
  const [motivo, setMotivo] = useState<string>('')
  const [data, setData] = useState(hojeLocal())
  const [tipo, setTipo] = useState<PontoTipo>('entrada')
  const [hora, setHora] = useState('')
  const [ini, setIni] = useState('')
  const [fim, setFim] = useState('')
  const [obs, setObs] = useState('')
  const [dataFim, setDataFim] = useState('')
  const [arquivo, setArquivo] = useState<{ base64: string; tipo: string; nome: string } | null>(null)
  const [enviando, setEnviando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [enviado, setEnviado] = useState<string | null>(null)

  const carregar = useCallback(async () => {
    try { setPedidos(await ponto.meusPedidos(token)) }
    catch (e) { const m = erroMsg(e); if (/Sessão encerrada/.test(m)) onSair(); else setErro(m) }
  }, [token, onSair])
  useEffect(() => { void carregar() }, [carregar])

  const falta = grupo && grupo !== 'ponto' ? MOTIVOS_FALTA[grupo].find(m => m.id === motivo) : undefined
  const atraso = motivo === 'atraso_saida' || !!falta?.horario
  const ehAtestado = motivo === 'atestado', ehAlta = motivo === 'alta_medica'
  const pronto = !!motivo && !!data && (atraso ? !!ini && !!fim && ini < fim
    : falta ? (ehAtestado ? !!dataFim && dataFim >= data : ehAlta || !dataFim || dataFim >= data) : !!hora)
    && (!falta || !!arquivo)
  const escolherArquivo = async (f: File | undefined) => {
    setErro(null); setArquivo(null)
    if (!f) return
    try { const a = await prepararArquivo(f); setArquivo({ ...a, nome: f.name }) } catch (e) { setErro(erroMsg(e)) }
  }
  const enviar = async () => {
    setEnviando(true); setErro(null)
    try {
      if ((ehAtestado || ehAlta) && arquivo) {
        const r = await ponto.justificarAtestado(token, { motivo: ehAtestado ? 'atestado' : 'alta_medica', data, validoAte: ehAtestado ? dataFim : null,
          observacao: obs.trim() || null, anexo: arquivo.base64, anexoTipo: arquivo.tipo })
        setEnviado(ehAtestado
          ? `Pedido ${r.numero} enviado. Até ${dataFim.split('-').reverse().join('/')} você fica afastado: não marca ponto nem recebe escala. Melhoras! Para voltar antes, tenha a liberação médica em mãos e fale com o seu gestor.`
          : `Pedido ${r.numero} enviado. Você está liberado para marcar o ponto e receber escala.`)
        setGrupo(null); setMotivo(''); setObs(''); setDataFim(''); setArquivo(null)
        await carregar(); onMudou(); return
      }
      if (falta && arquivo) {
        const r = await ponto.justificarFalta(token, { motivo, data, dataFim: falta.horario ? null : (dataFim || null),
          ini: falta.horario ? ini : null, fim: falta.horario ? fim : null, observacao: obs.trim() || null, anexo: arquivo.base64, anexoTipo: arquivo.tipo })
        setEnviado(`Pedido ${r.numero} enviado com o documento. O gestor vai analisar. A resposta chega aqui e no WhatsApp.` + (r.alerta ? ` Atenção: ${r.alerta}` : ''))
        setGrupo(null); setMotivo(''); setIni(''); setFim(''); setObs(''); setDataFim(''); setArquivo(null)
        await carregar(); return
      }
      const r = await ponto.justificar(token, { motivo, data, tipo: atraso ? null : tipo, hora: atraso ? null : hora,
        ini: atraso ? ini : null, fim: atraso ? fim : null, observacao: obs.trim() || null })
      setEnviado(`Pedido ${r.numero} enviado. O gestor vai analisar. A resposta chega aqui e no WhatsApp.`)
      setGrupo(null); setMotivo(''); setHora(''); setIni(''); setFim(''); setObs('')
      await carregar()
    } catch (e) { const m = erroMsg(e); if (/Sessão encerrada/.test(m)) onSair(); else setErro(m) }
    finally { setEnviando(false) }
  }

  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-base font-semibold">Ajuste de ponto</h2>
        <p className="text-sm text-muted-foreground">Justifique uma falta, um atraso ou uma marcação que ficou faltando. O gestor analisa, e você acompanha aqui.</p>
      </div>
      {enviado && <div className="flex items-start gap-2 rounded-lg border border-green-300 bg-green-50 px-3 py-2 text-sm text-green-900"><CheckCircle2 className="mt-0.5 h-4 w-4 shrink-0" /> {enviado}</div>}

      <section className="space-y-3 rounded-xl border bg-card p-4">
        <p className="text-sm font-semibold">O que aconteceu?</p>
        <div className="grid grid-cols-2 gap-2">
          {GRUPOS.map(g => (
            <button key={g.id} type="button" onClick={() => { setGrupo(g.id); setMotivo(''); setEnviado(null); setErro(null) }}
              className={`rounded-lg border p-3 text-left ${grupo === g.id ? 'border-primary bg-primary/5' : 'hover:border-primary'}`}>
              <p className="text-sm font-semibold">{g.titulo}</p>
              <p className="text-xs text-muted-foreground">{g.ajuda}</p>
            </button>
          ))}
        </div>
        {grupo && grupo !== 'ponto' && (<>
          <p className="text-sm font-semibold">Escolha o motivo</p>
          <div className="space-y-1.5">
            {MOTIVOS_FALTA[grupo].map(m => (
              <label key={m.id} className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-sm ${motivo === m.id ? 'border-primary bg-primary/5' : ''}`}>
                <input type="radio" name="motivo" checked={motivo === m.id} onChange={() => { setMotivo(m.id); setArquivo(null) }} /> {m.label}
              </label>
            ))}
          </div>
          {grupo === 'saude' && <p className="text-xs text-muted-foreground">Não precisa informar a doença. (Lei 605/49, art. 6º; CLT art. 473)</p>}
          {falta && (<>
            <p className="text-sm font-semibold">Quando foi?</p>
            {falta.horario ? (<>
              <Field label="Dia"><Input type="date" value={data} max={hojeLocal()} onChange={e => setData(e.target.value)} /></Field>
              <div className="grid grid-cols-2 gap-2">
                <Field label="Das"><Input type="time" value={ini} onChange={e => setIni(e.target.value)} /></Field>
                <Field label="Às"><Input type="time" value={fim} onChange={e => setFim(e.target.value)} /></Field>
              </div>
            </>) : ehAlta ? (
              <Field label="Liberado a partir de"><Input type="date" value={data} max={hojeLocal()} onChange={e => setData(e.target.value)} /></Field>
            ) : (
              <div className="grid grid-cols-2 gap-2">
                <Field label={ehAtestado ? 'Primeiro dia' : 'Dia'}><Input type="date" value={data} max={hojeLocal()} onChange={e => setData(e.target.value)} /></Field>
                <Field label={ehAtestado ? 'Válido até (último dia)' : 'Até o dia (se mais de um)'}><Input type="date" value={dataFim} min={data} onChange={e => setDataFim(e.target.value)} /></Field>
              </div>
            )}
            {ehAtestado && <p className="text-xs text-amber-800">Durante a validade do atestado você não marca ponto nem recebe escala. Para voltar antes, tenha a liberação médica em mãos e fale com o seu gestor.</p>}
            <p className="text-sm font-semibold">Documento</p>
            <p className="text-xs text-muted-foreground">Foto ou PDF do {falta.doc}. {grupo === 'saude' && 'Se o documento tiver o CID (código da doença), você pode cobri-lo antes da foto. '}
              Fica guardado com segurança e só quem aprova vê.</p>
            <div className="grid grid-cols-2 gap-2">
              <label className="flex cursor-pointer items-center justify-center rounded-lg border px-3 py-2 text-sm font-medium hover:border-primary">
                Tirar foto<input type="file" accept="image/*" capture="environment" className="hidden" onChange={e => void escolherArquivo(e.target.files?.[0])} />
              </label>
              <label className="flex cursor-pointer items-center justify-center rounded-lg border px-3 py-2 text-sm font-medium hover:border-primary">
                Escolher arquivo<input type="file" accept="image/*,application/pdf" className="hidden" onChange={e => void escolherArquivo(e.target.files?.[0])} />
              </label>
            </div>
            {arquivo && <p className="flex items-center gap-1.5 text-xs text-green-800"><CheckCircle2 className="h-3.5 w-3.5" /> {arquivo.tipo === 'application/pdf' ? 'PDF' : 'Foto'} pronta: {arquivo.nome}</p>}
            <Field label="Observação (opcional)" hint="Não escreva doença nem CID.">
              <Textarea rows={2} maxLength={500} value={obs} onChange={e => setObs(e.target.value)} />
            </Field>
            {erro && <ErrorBox>{erro}</ErrorBox>}
            <Button className="w-full" disabled={!pronto || enviando} onClick={() => void enviar()}>
              {enviando && <Loader2 className="h-4 w-4 animate-spin" />} Enviar para o gestor
            </Button>
          </>)}
        </>)}
        {grupo === 'ponto' && (<>
          <p className="text-sm font-semibold">Escolha o motivo</p>
          <div className="space-y-1.5">
            {MOTIVOS_PONTO.map(m => (
              <label key={m.id} className={`flex items-center gap-2 rounded-lg border px-3 py-2 text-sm ${motivo === m.id ? 'border-primary bg-primary/5' : ''}`}>
                <input type="radio" name="motivo" checked={motivo === m.id} onChange={() => setMotivo(m.id)} /> {m.label}
              </label>
            ))}
          </div>
          {motivo && (<>
            <p className="text-sm font-semibold">Quando foi?</p>
            <Field label="Dia"><Input type="date" value={data} max={hojeLocal()} onChange={e => setData(e.target.value)} /></Field>
            {atraso ? (
              <div className="grid grid-cols-2 gap-2">
                <Field label="Das"><Input type="time" value={ini} onChange={e => setIni(e.target.value)} /></Field>
                <Field label="Às"><Input type="time" value={fim} onChange={e => setFim(e.target.value)} /></Field>
              </div>
            ) : (
              <div className="grid grid-cols-2 gap-2">
                <Field label="Marcação que faltou">
                  <Select value={tipo} onChange={e => setTipo(e.target.value as PontoTipo)}>
                    {TIPOS.map(t => <option key={t.id} value={t.id}>{t.label}</option>)}
                  </Select>
                </Field>
                <Field label="Horário"><Input type="time" value={hora} onChange={e => setHora(e.target.value)} /></Field>
              </div>
            )}
            <Field label="Observação (opcional)" hint="Não escreva doença nem CID.">
              <Textarea rows={2} maxLength={500} value={obs} onChange={e => setObs(e.target.value)}
                placeholder="Ex.: o app não abriu na obra; avisei o supervisor às 7h40." />
            </Field>
            {erro && <ErrorBox>{erro}</ErrorBox>}
            <Button className="w-full" disabled={!pronto || enviando} onClick={() => void enviar()}>
              {enviando && <Loader2 className="h-4 w-4 animate-spin" />} Enviar para o gestor
            </Button>
          </>)}
        </>)}
      </section>

      <section className="rounded-xl border bg-card">
        <h2 className="border-b px-4 py-2 text-sm font-semibold">Meus pedidos</h2>
        {!pedidos ? <div className="flex justify-center py-6"><Loader2 className="h-5 w-5 animate-spin" /></div>
          : pedidos.length === 0 ? <p className="px-4 py-6 text-center text-sm text-muted-foreground">Nenhum pedido ainda.</p> : (
          <ul className="divide-y text-sm">
            {pedidos.map(p => (
              <li key={p.numero} className="space-y-0.5 px-4 py-2">
                <div className="flex items-center justify-between gap-2">
                  <p className="flex items-center gap-1.5 font-medium"><FileText className="h-3.5 w-3.5" /> Pedido {p.numero}</p>
                  <span className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${SITUACAO_PEDIDO[p.status].cor}`}>{SITUACAO_PEDIDO[p.status].label}</span>
                </div>
                <p className="text-xs text-muted-foreground">{p.motivo} · {p.data} · {p.detalhe}</p>
                {p.resposta && <p className="text-xs">Gestor: {p.resposta}</p>}
                {p.alerta && p.status === 'pendente' && <p className="text-xs text-amber-700">{p.alerta}</p>}
              </li>
            ))}
          </ul>
        )}
      </section>

      <p className="text-xs text-muted-foreground">
        <strong>Seus direitos.</strong> Falta com motivo previsto em lei e comprovada é abonada: o período não é descontado (CLT art. 473; Lei 605/49, art. 6º).
        O atestado médico vale para o dia ou o período indicado; a declaração de comparecimento vale só para o horário da consulta.
        Falta ou atraso sem justificativa pode ser descontado, conforme as regras da empresa. Pelo WhatsApp, escreva <strong>ajuste</strong>.
      </p>
    </div>
  )
}
