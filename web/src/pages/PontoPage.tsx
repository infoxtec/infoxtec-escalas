import { useCallback, useEffect, useState } from 'react'
import { KeyRound, Loader2, MapPin, RefreshCw, ShieldCheck } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Select, SuccessBox } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import { ALERTA_JORNADA, PONTO_ROTULO, hojeBahia, minutosHm } from '../lib/types'
import type { Empresa, PontoAcompanhamento, PontoEspelho, PontoGeo, PontoHoje } from '../lib/types'

const SITUACAO: Record<PontoHoje['situacao'], { label: string; cor: string }> = {
  sem_entrada: { label: 'Escala sem entrada', cor: 'bg-red-100 text-red-800' },
  com_marcacao: { label: 'Com marcação', cor: 'bg-green-100 text-green-800' },
  sem_marcacao: { label: 'Sem marcação', cor: 'bg-muted text-muted-foreground' },
}
const CANAL: Record<string, string> = { app: 'App', whatsapp: 'WhatsApp', ura: 'Telefone' }

// Registro de Ponto (submenu da Agenda): acompanhamento online (hoje, atualiza sozinho) e histórico das marcações (backlog 090).
// As marcações são imutáveis; esta tela só lê. Docs: docs/modulo-registro-de-ponto/.
export default function PontoPage({ papel }: { papel: 'admin' | 'gestor' | 'leitura' }) {
  const hoje = hojeBahia()
  const [situacao, setSituacao] = useState<PontoHoje[] | null>(null)
  const [lista, setLista] = useState<PontoAcompanhamento[] | null>(null)
  const [geo, setGeo] = useState<Record<string, PontoGeo>>({})
  const [espelho, setEspelho] = useState<PontoEspelho[] | null>(null)
  const [vista, setVista] = useState<'marcacoes' | 'espelho'>('marcacoes')
  const [de, setDe] = useState(hoje)
  const [ate, setAte] = useState(hoje)
  const [tecnico, setTecnico] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [atualizado, setAtualizado] = useState<string | null>(null)
  const [empresas, setEmpresas] = useState<Empresa[]>([])
  const [cadeia, setCadeia] = useState<{ ok: boolean; texto: string } | null>(null)
  const [conferindo, setConferindo] = useState(false)

  const carregar = useCallback(async () => {
    setErro(null)
    try {
      const [s, l, g, j] = await Promise.all([api.pontoHoje(), api.pontoAcompanhamento(de, ate, tecnico || null),
        papel === 'leitura' ? Promise.resolve([]) : api.pontoGeo(de, ate, tecnico || null),
        api.pontoEspelho(de, ate, tecnico || null)])
      setSituacao(s); setLista(l); setGeo(Object.fromEntries(g.map(x => [x.id, x]))); setEspelho(j)
      setAtualizado(new Date().toLocaleTimeString('pt-BR', { timeZone: 'America/Bahia' }))
    } catch (e) { setErro(erroMsg(e)) }
  }, [de, ate, tecnico, papel])

  useEffect(() => { void carregar() }, [carregar])
  // Online: com o período terminando hoje, atualiza a cada 30 s
  useEffect(() => {
    if (ate !== hoje) return
    const t = setInterval(() => { if (!document.hidden) void carregar() }, 30_000)
    return () => clearInterval(t)
  }, [carregar, ate, hoje])
  useEffect(() => {
    if (papel === 'admin') api.empresas().then(e => setEmpresas(e.filter(x => x.empregadora && x.ativo))).catch(() => {})
  }, [papel])

  const conferir = async (empresa: Empresa) => {
    setConferindo(true); setCadeia(null)
    try {
      const r = await api.pontoVerificar(empresa.id)
      setCadeia(r.integra
        ? { ok: true, texto: `${empresa.nome_fantasia || empresa.razao_social}: cadeia íntegra, ${r.conferidas} marcações conferidas.` }
        : { ok: false, texto: `${empresa.nome_fantasia || empresa.razao_social}: ${r.motivo} no NSR ${r.nsr} (${r.conferidas} conferidas antes).` })
    } catch (e) { setCadeia({ ok: false, texto: erroMsg(e) }) }
    finally { setConferindo(false) }
  }

  const conta = (s: PontoHoje['situacao']) => situacao?.filter(x => x.situacao === s).length ?? 0
  const fora = situacao?.reduce((n, x) => n + x.fora_area, 0) ?? 0

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold">Registro de Ponto</h2>
          <p className="text-xs text-muted-foreground">
            Marcações pelo app e pelo WhatsApp, na hora do servidor.{atualizado && ` Atualizado às ${atualizado}.`}
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      {/* Hoje */}
      <section className="space-y-3">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Cartao titulo="Funcionários com ponto" valor={situacao?.length} />
          <Cartao titulo="Com marcação hoje" valor={situacao && conta('com_marcacao')} cor="text-green-700" />
          <Cartao titulo="Escala sem entrada" valor={situacao && conta('sem_entrada')} cor="text-red-700" />
          <Cartao titulo="Fora da área hoje" valor={situacao && fora} cor="text-amber-700" />
        </div>
        {!situacao ? <Carregando /> : (
          <div className="overflow-x-auto rounded-md border">
            <table className="w-full text-sm">
              <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Escala de hoje</th>
                <th className="px-3 py-2">Última marcação</th><th className="px-3 py-2 text-center">Marcações</th>
                <th className="px-3 py-2">Situação</th>
              </tr></thead>
              <tbody>
                {situacao.length === 0 ? (
                  <tr><td colSpan={5} className="py-10 text-center text-muted-foreground">Nenhum funcionário com CPF e empresa cadastrados</td></tr>
                ) : situacao.map(s => (
                  <tr key={s.tecnico_id} className="border-b last:border-0 hover:bg-muted/30">
                    <td className="px-3 py-2"><p className="font-medium">{s.tecnico}</p><p className="text-xs text-muted-foreground">{s.empresa}</p></td>
                    <td className="px-3 py-2 text-xs">{s.escala_hora ? `${s.escala_hora} · ${s.escala_local ?? ''}` : <span className="text-muted-foreground">sem escala</span>}</td>
                    <td className="px-3 py-2 text-xs">{s.ultima_tipo ? `${PONTO_ROTULO[s.ultima_tipo]} às ${s.ultima_hora}` : '—'}</td>
                    <td className="px-3 py-2 text-center text-xs">
                      {s.marcacoes}{s.fora_area > 0 && <span className="ml-1 rounded bg-amber-100 px-1 text-amber-800">{s.fora_area} fora</span>}
                    </td>
                    <td className="px-3 py-2"><span className={`rounded px-2 py-0.5 text-xs font-medium ${SITUACAO[s.situacao].cor}`}>{SITUACAO[s.situacao].label}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* Histórico */}
      <section className="space-y-3">
        <div className="flex items-center gap-1 rounded-md border p-0.5 w-fit">
          {([['marcacoes', 'Marcações'], ['espelho', 'Espelho de jornada']] as const).map(([id, rotulo]) => (
            <button key={id} type="button" onClick={() => setVista(id)}
              className={`rounded px-3 py-1.5 text-sm font-medium ${vista === id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
              {rotulo}
            </button>
          ))}
        </div>
        <div className="flex flex-wrap items-end gap-3">
          <Field label="De"><Input type="date" value={de} max={ate} onChange={e => setDe(e.target.value)} /></Field>
          <Field label="Até"><Input type="date" value={ate} min={de} max={hoje} onChange={e => setAte(e.target.value)} /></Field>
          <Field label="Funcionário">
            <Select value={tecnico} onChange={e => setTecnico(e.target.value)}>
              <option value="">Todos</option>
              {situacao?.map(s => <option key={s.tecnico_id} value={s.tecnico_id}>{s.tecnico}</option>)}
            </Select>
          </Field>
          <p className="pb-2 text-xs text-muted-foreground">Período de até 62 dias. Bairro e cidade: © colaboradores do <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer" className="underline">OpenStreetMap</a>.</p>
        </div>
        {vista === 'espelho' ? <Espelho linhas={espelho} /> : !lista ? <Carregando /> : (
          <div className="overflow-x-auto rounded-md border">
            <table className="w-full text-sm">
              <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2">Data e hora</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Marcação</th>
                <th className="px-3 py-2">Canal</th><th className="px-3 py-2">Local</th><th className="px-3 py-2">GPS</th><th className="px-3 py-2">NSR · autenticação</th>
              </tr></thead>
              <tbody>
                {lista.length === 0 ? (
                  <tr><td colSpan={7} className="py-10 text-center text-muted-foreground">Nenhuma marcação no período</td></tr>
                ) : lista.map(m => (
                  <tr key={m.id} className="border-b last:border-0 hover:bg-muted/30">
                    <td className="whitespace-nowrap px-3 py-2 text-xs">{m.data} <span className="font-medium">{m.hora}</span></td>
                    <td className="px-3 py-2 text-xs">{m.tecnico}</td>
                    <td className="px-3 py-2 text-xs font-medium">
                      {PONTO_ROTULO[m.tipo] ?? m.tipo}
                      {m.ajustada && <span className="ml-1 rounded bg-blue-100 px-1 font-normal text-blue-800">ajuste</span>}
                    </td>
                    <td className="px-3 py-2 text-xs">
                      {CANAL[m.canal] ?? m.canal}
                      {m.login_origem === 'gestor' && (
                        <span title={m.gestor ? `Código gerado por ${m.gestor}` : 'Entrou com código gerado pelo gestor'}
                          className="ml-1 inline-flex items-center gap-0.5 rounded bg-purple-100 px-1 text-purple-800"><KeyRound className="h-3 w-3" /> gestor</span>
                      )}
                    </td>
                    <td className="px-3 py-2 text-xs">
                      {papel !== 'leitura' && <p className="font-medium">{bairroCidade(geo[m.id])}</p>}
                      <p className="text-muted-foreground">
                        {m.local ?? 'sem local cadastrado'}
                        {m.dentro_area === false && <span className="ml-1 rounded bg-amber-100 px-1 text-amber-800">fora da área · {m.distancia_m} m</span>}
                      </p>
                    </td>
                    <td className="px-3 py-2 text-xs">
                      {m.latitude != null && m.longitude != null ? (
                        <a href={`https://www.google.com/maps?q=${m.latitude},${m.longitude}`} target="_blank" rel="noreferrer"
                          className="inline-flex items-center gap-0.5 text-primary hover:underline" title={`${m.latitude}, ${m.longitude}`}>
                          <MapPin className="h-3 w-3" /> Abrir no mapa
                        </a>
                      ) : <span className="text-muted-foreground">—</span>}
                    </td>
                    <td className="px-3 py-2 font-mono text-[11px] text-muted-foreground">{m.nsr} · {m.autenticacao}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {papel === 'admin' && empresas.length > 0 && (
        <section className="space-y-2">
          <h3 className="text-sm font-semibold">Conferir a cadeia de marcações</h3>
          <p className="text-xs text-muted-foreground">Confere NSR sem lacunas e o encadeamento do hash desde a primeira marcação.</p>
          <div className="flex flex-wrap gap-2">
            {empresas.map(e => (
              <Button key={e.id} variant="outline" size="sm" disabled={conferindo} onClick={() => void conferir(e)}>
                <ShieldCheck className="h-3.5 w-3.5" /> {e.nome_fantasia || e.razao_social}
              </Button>
            ))}
          </div>
          {cadeia && (cadeia.ok ? <SuccessBox>{cadeia.texto}</SuccessBox> : <ErrorBox>{cadeia.texto}</ErrorBox>)}
        </section>
      )}
    </div>
  )
}

function Cartao({ titulo, valor, cor }: { titulo: string; valor: number | null | undefined; cor?: string }) {
  return (
    <div className="rounded-md border p-3">
      <p className="text-xs text-muted-foreground">{titulo}</p>
      <p className={`text-2xl font-semibold ${cor ?? ''}`}>{valor ?? '—'}</p>
    </div>
  )
}

function Carregando() {
  return <div className="flex justify-center py-8"><Loader2 className="h-5 w-5 animate-spin" /></div>
}

// Bairro e cidade da marcação (OpenStreetMap, migration 58); a consulta leva até alguns minutos
function bairroCidade(g: PontoGeo | undefined) {
  if (!g || g.geo_status === 'pendente' || g.geo_status === 'enviado') return 'Localizando bairro...'
  if (g.geo_status === 'erro' || (!g.bairro && !g.cidade)) return 'Bairro não identificado'
  return [g.bairro, g.cidade && `${g.cidade}${g.uf ? '/' + g.uf : ''}`].filter(Boolean).join(', ')
}

// Espelho de jornada: previsto (escala) × realizado (marcações), com os avisos da CLT (backlog 084)
function Espelho({ linhas }: { linhas: PontoEspelho[] | null }) {
  if (!linhas) return <Carregando />
  return (
    <div className="space-y-2">
      <div className="overflow-x-auto rounded-md border">
        <table className="w-full text-sm">
          <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
            <th className="px-3 py-2">Data</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Escala</th>
            <th className="px-3 py-2">Entrada</th><th className="px-3 py-2">Almoço</th><th className="px-3 py-2">Saída</th>
            <th className="px-3 py-2">Trabalhado</th><th className="px-3 py-2">Intervalo</th><th className="px-3 py-2">Hora extra</th>
            <th className="px-3 py-2">Avisos</th>
          </tr></thead>
          <tbody>
            {linhas.length === 0 ? (
              <tr><td colSpan={10} className="py-10 text-center text-muted-foreground">Nenhuma jornada no período</td></tr>
            ) : linhas.map(l => (
              <tr key={`${l.tecnico_id}-${l.data}`} className="border-b last:border-0 hover:bg-muted/30">
                <td className="whitespace-nowrap px-3 py-2 text-xs">{l.data.split('-').reverse().join('/')}</td>
                <td className="px-3 py-2 text-xs">{l.tecnico}</td>
                <td className="px-3 py-2 text-xs">{l.escala_hora ?? '—'}{l.atraso_min != null && <span className="ml-1 text-red-700">+{l.atraso_min} min</span>}</td>
                <td className="px-3 py-2 text-xs">{l.entrada ?? '—'}</td>
                <td className="whitespace-nowrap px-3 py-2 text-xs">{l.saida_almoco || l.volta_almoco ? `${l.saida_almoco ?? '—'} – ${l.volta_almoco ?? '—'}` : '—'}</td>
                <td className="px-3 py-2 text-xs">{l.saida ?? '—'}</td>
                <td className="px-3 py-2 text-xs font-medium">{minutosHm(l.trabalhado_min)}</td>
                <td className={`px-3 py-2 text-xs ${l.alertas.some(a => a.startsWith('intervalo') || a === 'sem_intervalo') ? 'font-medium text-amber-700' : ''}`}>{minutosHm(l.intervalo_min)}</td>
                <td className={`px-3 py-2 text-xs ${l.alertas.includes('he_acima_limite') ? 'font-medium text-red-700' : ''}`}>{l.he_min ? minutosHm(l.he_min) : '—'}</td>
                <td className="px-3 py-2 text-xs">
                  {l.alertas.length === 0 ? <span className="text-green-700">ok</span> : l.alertas.map(a => (
                    <span key={a} className={`mr-1 inline-block rounded px-1 ${a === 'he_acima_limite' || a === 'interjornada_curta' ? 'bg-red-100 text-red-800' : 'bg-amber-100 text-amber-800'}`}>{ALERTA_JORNADA[a] ?? a}</span>
                  ))}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-muted-foreground">
        Avisos pela CLT: intervalo de 1 h a 2 h para jornada acima de 6 h (art. 71), hora extra de até 2 h por dia (art. 59),
        11 h entre jornadas (art. 66) e atraso acima de 5 min na entrada (art. 58: até 5 min por marcação, no máximo 10 min no dia). Intervalo e jornada podem ter regra própria na convenção coletiva. Avisos não bloqueiam a marcação; ajustes vêm na próxima entrega.
      </p>
    </div>
  )
}

