import { useCallback, useEffect, useState } from 'react'
import { Check, KeyRound, Loader2, MapPin, PencilLine, RefreshCw, ShieldCheck, Undo2, X } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Select, SuccessBox, Textarea } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import Cofre from '../components/Cofre'
import PontoAfd from '../components/PontoAfd'
import EspelhosMensais from '../components/EspelhosMensais'
import FechamentoFolha from '../components/FechamentoFolha'
import CofreFolhas from '../components/CofreFolhas'
import { prepararArquivo } from '../lib/arquivo'
import { ALERTA_JORNADA, PONTO_ROTULO, hojeBahia, minutosHm } from '../lib/types'
import type { Empresa, PontoAbono, PontoAcompanhamento, PontoAjuste, PontoEspelho, PontoGeo, PontoHoje, PontoJustificativa, PontoMetricas } from '../lib/types'

const SITUACAO: Record<PontoHoje['situacao'], { label: string; cor: string }> = {
  sem_entrada: { label: 'Programação sem entrada', cor: 'bg-red-100 text-red-800' },
  com_marcacao: { label: 'Com marcação', cor: 'bg-green-100 text-green-800' },
  sem_marcacao: { label: 'Sem marcação', cor: 'bg-muted text-muted-foreground' },
}
const CANAL: Record<string, string> = { app: 'App', whatsapp: 'WhatsApp', ura: 'Telefone' }
const SEMANA = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb']
// "AAAA-MM-DD" ou "DD/MM/AAAA" → "DD/MM/AAAA ter"
function dataComDia(d: string) {
  const iso = d.includes('/') ? d.split('/').reverse().join('-') : d
  return `${iso.split('-').reverse().join('/')} ${SEMANA[new Date(iso + 'T12:00:00').getDay()]}`
}
const MESES = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']
// último dia do mês "AAAA-MM", sem passar de hoje
function fimDoMes(mes: string, hoje: string) {
  const [a, m] = mes.split('-').map(Number)
  const fim = `${mes}-${String(new Date(a, m, 0).getDate()).padStart(2, '0')}`
  return fim > hoje ? hoje : fim
}

// Registro de Ponto (submenu da Agenda): acompanhamento online (hoje, atualiza sozinho) e histórico das marcações (backlog 090).
// As marcações são imutáveis: correção é ajuste com justificativa, registro à parte (migration 65). Docs: docs/modulo-registro-de-ponto/.
export default function PontoPage({ papel }: { papel: 'admin' | 'gestor' | 'leitura' }) {
  const hoje = hojeBahia()
  const [situacao, setSituacao] = useState<PontoHoje[] | null>(null)
  const [lista, setLista] = useState<PontoAcompanhamento[] | null>(null)
  const [geo, setGeo] = useState<Record<string, PontoGeo>>({})
  const [espelho, setEspelho] = useState<PontoEspelho[] | null>(null)
  const [ajustes, setAjustes] = useState<PontoAjuste[] | null>(null)
  const [pedidos, setPedidos] = useState<PontoJustificativa[] | null>(null)
  const [metricas, setMetricas] = useState<PontoMetricas | null>(null)
  const [abonos, setAbonos] = useState<PontoAbono[] | null>(null)
  // Gestão de Ponto (pedido do responsável, 13/10): cada assunto numa aba
  const [vista, setVista] = useState<'hoje' | 'marcacoes' | 'espelho' | 'ajustes' | 'fechamento' | 'folhas' | 'cofre' | 'afd'>('hoje')
  // O ponto é visto sempre por mês (pedido do responsável, 13/10): não há fechamento que cruze meses
  const [mes, setMes] = useState(hoje.slice(0, 7))
  const de = `${mes}-01`
  const ate = fimDoMes(mes, hoje)
  const [tecnico, setTecnico] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [atualizado, setAtualizado] = useState<string | null>(null)
  const [empresas, setEmpresas] = useState<Empresa[]>([])
  const [cadeia, setCadeia] = useState<{ ok: boolean; texto: string } | null>(null)
  const [conferindo, setConferindo] = useState(false)
  const [rhFolhas, setRhFolhas] = useState(false)

  const carregar = useCallback(async () => {
    setErro(null)
    try {
      const [s, l, g, j, a, pd, ab, mt] = await Promise.all([api.pontoHoje(), api.pontoAcompanhamento(de, ate, tecnico || null),
        papel === 'leitura' ? Promise.resolve([]) : api.pontoGeo(de, ate, tecnico || null),
        api.pontoEspelho(de, ate, tecnico || null), api.pontoAjustes(de, ate, tecnico || null),
        api.pontoJustificativas(de, ate, tecnico || null), api.pontoAbonos(de, ate, tecnico || null), api.pontoMetricas(de, ate)])
      setSituacao(s); setLista(l); setGeo(Object.fromEntries(g.map(x => [x.id, x]))); setEspelho(j); setAjustes(a)
      setPedidos(pd); setAbonos(ab); setMetricas(mt)
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
  useEffect(() => { api.meuAcesso().then(a => setRhFolhas(!!a.rh_folhas)).catch(() => {}) }, [])
  useEffect(() => { if (vista === 'cofre' && !rhFolhas) setVista('hoje') }, [vista, rhFolhas])
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

  const pendentes = pedidos?.filter(p => p.status === 'pendente').length ?? 0
  const conta = (s: PontoHoje['situacao']) => situacao?.filter(x => x.situacao === s).length ?? 0
  const fora = situacao?.reduce((n, x) => n + x.fora_area, 0) ?? 0

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold">Gestão de Ponto</h2>
          <p className="text-xs text-muted-foreground">
            Marcações pelo app e pelo WhatsApp, na hora do servidor.{atualizado && ` Atualizado às ${atualizado}.`}
          </p>
        </div>
        <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="flex flex-wrap items-center gap-1 rounded-md border p-0.5 lg:w-fit">
        {([['hoje', 'Hoje'], ['marcacoes', 'Marcações'], ['espelho', 'Espelho de jornada'], ['ajustes', 'Ajustes e pedidos'],
           ['fechamento', 'Fechamento da folha'], ['folhas', 'Folhas mensais'], ...(rhFolhas ? [['cofre', 'Cofre (RH)']] : []), ...(papel === 'admin' ? [['afd', 'AFD']] : [])] as [typeof vista, string][])
          .map(([id, rotulo]) => (
          <button key={id} type="button" onClick={() => setVista(id)}
            className={`rounded px-3 py-1.5 text-sm font-medium ${vista === id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
            {rotulo}
            {id === 'ajustes' && pendentes > 0 && <span className="ml-1.5 rounded-full bg-amber-500 px-1.5 text-[11px] text-white">{pendentes}</span>}
          </button>
        ))}
      </div>

      {/* Hoje */}
      {vista === 'hoje' && <section className="space-y-3">
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <Cartao titulo="Funcionários com ponto" valor={situacao?.length} />
          <Cartao titulo="Com marcação hoje" valor={situacao && conta('com_marcacao')} cor="text-green-700" />
          <Cartao titulo="Programação sem entrada" valor={situacao && conta('sem_entrada')} cor="text-red-700" />
          <Cartao titulo="Fora da área hoje" valor={situacao && fora} cor="text-amber-700" />
        </div>
        {!situacao ? <Carregando /> : (
          <div className="overflow-x-auto rounded-md border">
            <table className="w-full text-sm">
              <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
                <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Programação de hoje</th>
                <th className="px-3 py-2">Última marcação</th><th className="px-3 py-2 text-center">Marcações</th>
                <th className="px-3 py-2">Situação</th>
              </tr></thead>
              <tbody>
                {situacao.length === 0 ? (
                  <tr><td colSpan={5} className="py-10 text-center text-muted-foreground">Nenhum funcionário com CPF e empresa cadastrados</td></tr>
                ) : situacao.map(s => (
                  <tr key={s.tecnico_id} className="border-b last:border-0 hover:bg-muted/30">
                    <td className="px-3 py-2"><p className="font-medium">{s.tecnico}</p><p className="text-xs text-muted-foreground">{s.empresa}</p></td>
                    <td className="px-3 py-2 text-xs">{s.escala_hora ? `${s.escala_hora} · ${s.escala_local ?? ''}` : <span className="text-muted-foreground">sem programação</span>}</td>
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
      </section>}

      {/* Histórico do mês: marcações, espelho de jornada e ajustes */}
      {(vista === 'marcacoes' || vista === 'espelho' || vista === 'ajustes') && <section className="space-y-3">
        <div className="flex flex-wrap items-end gap-3">
          <Field label="Mês"><Input type="month" value={mes} max={hoje.slice(0, 7)} onChange={e => e.target.value && setMes(e.target.value)} /></Field>
          <Field label="Funcionário">
            <Select value={tecnico} onChange={e => setTecnico(e.target.value)}>
              <option value="">Todos</option>
              {situacao?.map(s => <option key={s.tecnico_id} value={s.tecnico_id}>{s.tecnico}</option>)}
            </Select>
          </Field>
          <p className="pb-2 text-xs text-muted-foreground">
            {MESES[Number(mes.slice(5, 7)) - 1]} de {mes.slice(0, 4)}{mes === hoje.slice(0, 7) ? `, até hoje` : ''}. Bairro e cidade: © colaboradores do <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer" className="underline">OpenStreetMap</a>.</p>
        </div>
        {vista === 'ajustes' ? (
          <div className="space-y-5">
            {papel !== 'leitura' && <Afastados hoje={hoje} aoRegistrar={carregar} />}
            <Pedidos linhas={pedidos} metricas={metricas} podeDecidir={papel !== 'leitura'} aoDecidir={carregar} />
            <Ajustes linhas={ajustes} marcacoes={lista} funcionarios={situacao ?? []} tecnico={tecnico} hoje={hoje}
              podeAjustar={papel !== 'leitura'} aoAjustar={carregar} />
            <Abonos linhas={abonos} podeEstornar={papel !== 'leitura'} aoEstornar={carregar} />
          </div>
        ) : vista === 'espelho' ? <Espelho linhas={espelho} /> : !lista ? <Carregando /> : (
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
                    <td className="whitespace-nowrap px-3 py-2 text-xs">{dataComDia(m.data)} <span className="font-medium">{m.hora}</span></td>
                    <td className="px-3 py-2 text-xs">{m.tecnico}</td>
                    <td className="px-3 py-2 text-xs font-medium">
                      {PONTO_ROTULO[m.tipo] ?? m.tipo}
                      {m.ajustada && <span title="Desconsiderada por ajuste do gestor; continua guardada" className="ml-1 rounded bg-blue-100 px-1 font-normal text-blue-800">desconsiderada</span>}
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
      </section>}

      {vista === 'afd' && papel === 'admin' && empresas.length > 0 && (
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

      {vista === 'fechamento' && <FechamentoFolha hoje={hoje} podeFechar={papel !== 'leitura'} />}
      {vista === 'folhas' && <EspelhosMensais hoje={hoje} podeEmitir={papel !== 'leitura'} rhFolhas={rhFolhas} />}

      {vista === 'cofre' && rhFolhas && <CofreFolhas hoje={hoje} />}

      {vista === 'afd' && papel === 'admin' && empresas.length > 0 && <PontoAfd empresas={empresas} hoje={hoje} />}
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
            <th className="px-3 py-2">Data</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Programação</th>
            <th className="px-3 py-2">Entrada</th><th className="px-3 py-2">Almoço</th><th className="px-3 py-2">Saída</th>
            <th className="px-3 py-2">Trabalhado</th><th className="px-3 py-2">Intervalo</th><th className="px-3 py-2">Hora extra</th>
            <th className="px-3 py-2">Avisos</th>
          </tr></thead>
          <tbody>
            {linhas.length === 0 ? (
              <tr><td colSpan={10} className="py-10 text-center text-muted-foreground">Nenhuma jornada no período</td></tr>
            ) : linhas.map(l => (
              <tr key={`${l.tecnico_id}-${l.data}`} className="border-b last:border-0 hover:bg-muted/30">
                <td className="whitespace-nowrap px-3 py-2 text-xs">{dataComDia(l.data)}</td>
                <td className="px-3 py-2 text-xs">
                  {l.tecnico}
                  {l.ajustes > 0 && <span title={`${l.ajustes} ajuste(s) do gestor neste dia`} className="ml-1 rounded bg-blue-100 px-1 text-blue-800">ajustado</span>}
                </td>
                <td className="px-3 py-2 text-xs">{l.escala_hora ?? '—'}{l.atraso_min != null && <span className="ml-1 text-red-700">+{l.atraso_min} min</span>}</td>
                <td className="px-3 py-2 text-xs">{l.entrada ?? '—'}</td>
                <td className="whitespace-nowrap px-3 py-2 text-xs">{l.saida_almoco || l.volta_almoco ? `${l.saida_almoco ?? '—'} – ${l.volta_almoco ?? '—'}` : '—'}</td>
                <td className="px-3 py-2 text-xs">{l.saida ?? '—'}</td>
                <td className="px-3 py-2 text-xs font-medium">{minutosHm(l.trabalhado_min)}</td>
                <td className={`px-3 py-2 text-xs ${l.alertas.some(a => a.startsWith('intervalo') || a === 'sem_intervalo') ? 'font-medium text-amber-700' : ''}`}>{minutosHm(l.intervalo_min)}</td>
                <td className={`px-3 py-2 text-xs ${l.alertas.includes('he_acima_limite') ? 'font-medium text-red-700' : ''}`}>{l.he_min ? minutosHm(l.he_min) : '—'}</td>
                <td className="px-3 py-2 text-xs">
                  {l.alertas.length === 0 ? <span className="text-green-700">ok</span> : l.alertas.map(a => (
                    <span key={a} className={`mr-1 inline-block rounded px-1 ${a.endsWith('_abonada') || a.endsWith('_abonado') ? 'bg-blue-100 text-blue-800' : a === 'he_acima_limite' || a === 'interjornada_curta' || a === 'falta' ? 'bg-red-100 text-red-800' : 'bg-amber-100 text-amber-800'}`}>{ALERTA_JORNADA[a] ?? a}</span>
                  ))}
                  {l.abono && <span className="block text-[11px] text-blue-800">abono: {l.abono}</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-xs text-muted-foreground">
        Avisos pela CLT: intervalo de 1 h a 2 h para jornada acima de 6 h (art. 71), hora extra de até 2 h por dia (art. 59),
        11 h entre jornadas (art. 66) e atraso acima de 5 min na entrada (art. 58: até 5 min por marcação, no máximo 10 min no dia). Intervalo e jornada podem ter regra própria na convenção coletiva. Avisos não bloqueiam a marcação. Falta é dia com escala, já passado, sem marcação. Dia marcado como ajustado foi corrigido pelo gestor na aba Ajustes, e o abono cobre falta ou atraso sem criar marcação; as marcações originais continuam guardadas.
      </p>
    </div>
  )
}

// Ajustes de ponto com justificativa (backlog 084 entrega 2, decisão 52): desconsiderar marcação errada, abonar e
// folga compensatória. O gestor não inclui marcação (decisão 89): a esquecida entra pelo pedido do funcionário; sem
// pedido, o gestor abona com justificativa. Nada é apagado; o funcionário recebe aviso no WhatsApp, sem o motivo.
function Ajustes({ linhas, marcacoes, funcionarios, tecnico, hoje, podeAjustar, aoAjustar }: {
  linhas: PontoAjuste[] | null; marcacoes: PontoAcompanhamento[] | null; funcionarios: PontoHoje[]
  tecnico: string; hoje: string; podeAjustar: boolean; aoAjustar: () => Promise<void>
}) {
  const [func, setFunc] = useState(tecnico)
  const [acao, setAcao] = useState<'desconsiderar' | 'abonar' | 'folga'>('desconsiderar')
  const [trabalhado, setTrabalhado] = useState('')
  const [diaInteiro, setDiaInteiro] = useState(true)
  const [ini, setIni] = useState('')
  const [fim, setFim] = useState('')
  const [data, setData] = useState(hoje)
  const [marcacao, setMarcacao] = useState('')
  const [motivo, setMotivo] = useState('')
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)

  useEffect(() => { setFunc(tecnico) }, [tecnico])
  useEffect(() => { setMarcacao('') }, [func])

  // alvo do desconsiderar: marcação original (m:) ou inclusão feita por ajuste (a:)
  const candidatas = [
    ...(marcacoes ?? []).filter(m => m.tecnico_id === func && !m.ajustada)
      .map(m => ({ valor: `m:${m.id}`, texto: `${m.data} ${m.hora} · ${PONTO_ROTULO[m.tipo] ?? m.tipo} · NSR ${m.nsr}` })),
    ...(linhas ?? []).filter(a => a.tecnico_id === func && a.acao === 'incluir' && !a.desconsiderado)
      .map(a => ({ valor: `a:${a.id}`, texto: `${a.data} ${a.hora} · ${PONTO_ROTULO[a.tipo] ?? a.tipo} · incluída por ajuste` })),
  ]
  const motivoOk = motivo.trim().length >= 10
  const pronto = !!func && (acao === 'folga' ? !!data && !!trabalhado : motivoOk && (
    acao === 'abonar' ? !!data && (diaInteiro || (!!ini && !!fim && ini < fim)) : !!marcacao))

  const salvar = async () => {
    setSalvando(true); setErro(null); setOk(null)
    try {
      if (acao === 'folga') {
        const f = await api.pontoFolgaCompensatoria(func, data, trabalhado)
        setOk(`Folga de ${f.folga} registrada, compensando o trabalho de ${f.trabalhado}: o domingo ou feriado deixa de sair a 100%.`)
        setTrabalhado(''); await aoAjustar(); return
      }
      if (acao === 'abonar') {
        const a = await api.pontoAbonar(func, data, motivo.trim(), diaInteiro ? null : ini, diaInteiro ? null : fim)
        setOk(`Abono de ${a.data} (${a.detalhe}) registrado. O funcionário foi avisado, sem o motivo.`)
        setMotivo(''); setIni(''); setFim(''); await aoAjustar(); return
      }
      const r = await api.pontoAjustar({ tecnico: func, acao, motivo: motivo.trim(),
        ...(marcacao.startsWith('a:') ? { ajuste: marcacao.slice(2) } : { marcacao: marcacao.slice(2) }) })
      setOk(`Ajuste de ${r.data} às ${r.hora} registrado. ` + (r.avisado
        ? 'O funcionário foi avisado pelo WhatsApp (sem o motivo).'
        : 'Sem novo aviso ao funcionário: ele não autorizou mensagens, está inativo ou já foi avisado de um ajuste nos últimos 5 minutos.'))
      setMotivo(''); setMarcacao('')
      await aoAjustar()
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  return (
    <div className="space-y-4">
      {podeAjustar && (
        <div className="space-y-3 rounded-md border p-3">
          <h3 className="flex items-center gap-1.5 text-sm font-semibold"><PencilLine className="h-4 w-4" /> Novo ajuste</h3>
          <div className="flex flex-wrap items-end gap-3">
            <Field label="Funcionário">
              <Select value={func} onChange={e => setFunc(e.target.value)}>
                <option value="">Escolha</option>
                {funcionarios.map(f => <option key={f.tecnico_id} value={f.tecnico_id}>{f.tecnico}</option>)}
              </Select>
            </Field>
            <Field label="Ajuste">
              <Select value={acao} onChange={e => setAcao(e.target.value as 'desconsiderar' | 'abonar' | 'folga')}>
                <option value="desconsiderar">Desconsiderar marcação errada</option>
                <option value="abonar">Abonar falta ou atraso</option>
                <option value="folga">Folga compensatória (domingo ou feriado trabalhado)</option>
              </Select>
            </Field>
            {acao === 'folga' ? (<>
              <Field label="Domingo ou feriado trabalhado"><Input type="date" value={trabalhado} max={hoje} onChange={e => setTrabalhado(e.target.value)} /></Field>
              <Field label="Dia da folga (mesma semana)"><Input type="date" value={data} onChange={e => setData(e.target.value)} /></Field>
            </>) : acao === 'abonar' ? (<>
              <Field label="Data"><Input type="date" value={data} max={hoje} onChange={e => setData(e.target.value)} /></Field>
              <label className="flex items-center gap-1.5 pb-2 text-sm"><input type="checkbox" checked={diaInteiro} onChange={e => setDiaInteiro(e.target.checked)} /> Dia inteiro</label>
              {!diaInteiro && <>
                <Field label="Das"><Input type="time" value={ini} onChange={e => setIni(e.target.value)} /></Field>
                <Field label="Às"><Input type="time" value={fim} onChange={e => setFim(e.target.value)} /></Field>
              </>}
            </>) : (
              <Field label="Marcação do período">
                <Select value={marcacao} onChange={e => setMarcacao(e.target.value)} disabled={!func}>
                  <option value="">{func ? (candidatas.length ? 'Escolha' : 'Nenhuma marcação no período') : 'Escolha o funcionário'}</option>
                  {candidatas.map(c => <option key={c.valor} value={c.valor}>{c.texto}</option>)}
                </Select>
              </Field>
            )}
          </div>
          {acao === 'folga' ? (
            <p className="text-xs text-muted-foreground">
              A folga abona o dia inteiro e tira o pagamento em dobro do domingo ou feriado (Lei 605/1949, art. 9º). Ela precisa
              ficar a até 6 dias do trabalho; depois disso o repouso é devido em dobro. O motivo é registrado sozinho.
            </p>
          ) : <Field label="Motivo (obrigatório, fica guardado 5 anos; não vai para o funcionário)">
            <Textarea rows={2} value={motivo} maxLength={500} onChange={e => setMotivo(e.target.value)}
              placeholder="Ex.: esqueceu de marcar a saída e não pediu o ajuste; jornada confirmada com o supervisor da obra. Não escreva diagnóstico, CID nem doença: use “atestado apresentado”." />
          </Field>}
          <div className="flex flex-wrap items-center gap-3">
            <Button size="sm" disabled={!pronto || salvando} onClick={() => void salvar()}>
              {salvando && <Loader2 className="h-3.5 w-3.5 animate-spin" />} Registrar ajuste
            </Button>
            {acao !== 'folga' && !motivoOk && motivo.length > 0 && <span className="text-xs text-amber-700">Motivo com pelo menos 10 letras.</span>}
          </div>
          {erro && <ErrorBox>{erro}</ErrorBox>}
          {ok && <SuccessBox>{ok}</SuccessBox>}
          <p className="text-xs text-muted-foreground">
            O ajuste não apaga nem altera a marcação original (Portaria 671): fica registrado com autor, data e motivo, e o
            espelho passa a considerá-lo. O gestor não inclui marcação: a esquecida entra pelo pedido de ajuste do
            funcionário (aprovado aqui); se ele não pedir, abone a falta ou o atraso com a justificativa. Não escreva dado
            de saúde no motivo (diagnóstico, CID, doença).
          </p>
        </div>
      )}
      {!linhas ? <Carregando /> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Marcação de</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Ajuste</th>
              {podeAjustar && <><th className="px-3 py-2">Motivo</th><th className="px-3 py-2">Por</th></>}
              <th className="px-3 py-2">Lançado em</th>
            </tr></thead>
            <tbody>
              {linhas.length === 0 ? (
                <tr><td colSpan={podeAjustar ? 6 : 4} className="py-10 text-center text-muted-foreground">Nenhum ajuste no período</td></tr>
              ) : linhas.map(a => (
                <tr key={a.id} className="border-b last:border-0 hover:bg-muted/30">
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{dataComDia(a.data)} <span className="font-medium">{a.hora}</span></td>
                  <td className="px-3 py-2 text-xs">{a.tecnico}</td>
                  <td className="px-3 py-2 text-xs">
                    <span className={`rounded px-1 ${a.acao === 'incluir' ? 'bg-green-100 text-green-800' : 'bg-blue-100 text-blue-800'}`}>
                      {a.acao === 'incluir' ? 'incluída' : 'desconsiderada'}
                    </span>{' '}
                    {PONTO_ROTULO[a.tipo] ?? a.tipo}{a.marcacao_nsr != null && <span className="text-muted-foreground"> · NSR {a.marcacao_nsr}</span>}
                    {a.desfaz_inclusao && <span className="text-muted-foreground"> · inclusão anterior</span>}
                    {a.desconsiderado && <span className="ml-1 rounded bg-muted px-1 text-muted-foreground">desfeita</span>}
                  </td>
                  {podeAjustar && <>
                    <td className="max-w-xs px-3 py-2 text-xs">{a.motivo}</td>
                    <td className="px-3 py-2 text-xs text-muted-foreground">{a.autor}</td>
                  </>}
                  <td className="whitespace-nowrap px-3 py-2 text-xs text-muted-foreground">{a.criado_em}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

const STATUS_PEDIDO: Record<PontoJustificativa['status'], { label: string; cor: string }> = {
  pendente: { label: 'Em análise', cor: 'bg-amber-100 text-amber-800' },
  aprovada: { label: 'Aprovado', cor: 'bg-green-100 text-green-800' },
  negada: { label: 'Não aprovado', cor: 'bg-red-100 text-red-800' },
  cancelada: { label: 'Cancelado', cor: 'bg-muted text-muted-foreground' },
}

// Afastados agora (decisão 60) e alta antecipada registrada pelo gestor com a liberação médica (decisão 64):
// o documento vai para o cofre e a alta já sai aprovada. Só quem vê atestados registra.
function Afastados({ hoje, aoRegistrar }: { hoje: string; aoRegistrar: () => Promise<void> }) {
  const [lista, setLista] = useState<{ tecnico_id: string; tecnico: string; afastado_ate: string; pode_registrar_alta: boolean }[] | null>(null)
  const [aberto, setAberto] = useState<string | null>(null)
  const [data, setData] = useState(hoje)
  const [arquivo, setArquivo] = useState<File | null>(null)
  const [obs, setObs] = useState('')
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const carregar = useCallback(async () => {
    try { setLista(await api.pontoAfastados()) } catch (e) { setErro(erroMsg(e)) }
  }, [])
  useEffect(() => { void carregar() }, [carregar])
  if (!lista || lista.length === 0) return erro ? <ErrorBox>{erro}</ErrorBox> : null
  const registrar = async (tecnico: string) => {
    if (!arquivo) return
    setSalvando(true); setErro(null); setOk(null)
    try {
      const f = await prepararArquivo(arquivo)
      const r = await api.pontoRegistrarAlta(tecnico, data, f.base64, f.tipo, obs.trim() || null)
      setOk(`Alta registrada (pedido ${r.numero}). ${r.afastado_ate ? `Ainda afastado até ${r.afastado_ate}: confira a data da alta.` : 'O funcionário já pode marcar o ponto e receber programação.'}`)
      setAberto(null); setArquivo(null); setObs('')
      await carregar(); await aoRegistrar()
    } catch (e) { setErro(erroMsg(e)) } finally { setSalvando(false) }
  }
  return (
    <div className="space-y-2 rounded-md border border-amber-300 bg-amber-50/40 p-3">
      <h3 className="text-sm font-semibold">Afastados agora <span className="font-normal text-muted-foreground">· sem ponto e sem programação até a data</span></h3>
      {lista.map(a => (
        <div key={a.tecnico_id} className="space-y-2 text-sm">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-medium">{a.tecnico}</span>
            <span className="text-muted-foreground">até {a.afastado_ate.split('-').reverse().join('/')}</span>
            {a.pode_registrar_alta && aberto !== a.tecnico_id && (
              <Button size="sm" variant="outline" onClick={() => { setAberto(a.tecnico_id); setData(hoje); setArquivo(null); setObs(''); setErro(null) }}>Registrar alta</Button>
            )}
          </div>
          {aberto === a.tecnico_id && (
            <div className="space-y-2 rounded border bg-card p-2">
              <div className="flex flex-wrap items-end gap-3">
                <Field label="Data da alta"><Input type="date" value={data} max={hoje} onChange={e => setData(e.target.value)} /></Field>
                <Field label="Liberação médica (foto ou PDF, até 5 MB)">
                  <Input type="file" accept="image/*,application/pdf" onChange={e => setArquivo(e.target.files?.[0] ?? null)} />
                </Field>
              </div>
              <Textarea rows={2} value={obs} maxLength={500} onChange={e => setObs(e.target.value)}
                placeholder="Observação (opcional). Não escreva diagnóstico, CID nem doença." />
              <div className="flex gap-2">
                <Button size="sm" disabled={!arquivo || !data || salvando} onClick={() => void registrar(a.tecnico_id)}>
                  {salvando && <Loader2 className="h-3.5 w-3.5 animate-spin" />} Registrar alta
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setAberto(null)}>Cancelar</Button>
              </div>
              <p className="text-xs text-muted-foreground">O documento vai para o cofre criptografado. A partir da data da alta, o funcionário volta a marcar o ponto e a receber programação; o atestado é abonado até a véspera.</p>
            </div>
          )}
        </div>
      ))}
      {!lista[0].pode_registrar_alta && <p className="text-xs text-muted-foreground">Para registrar a alta é preciso a permissão “Vê atestados e documentos”.</p>}
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}
    </div>
  )
}

// Pedidos de ajuste dos funcionários (app e WhatsApp, decisão 55): o gestor aprova ou nega.
// Aprovado: esqueci/falha vira marcação incluída por ajuste; atraso vira abono do período.
function Pedidos({ linhas, metricas, podeDecidir, aoDecidir }: { linhas: PontoJustificativa[] | null; metricas: PontoMetricas | null; podeDecidir: boolean; aoDecidir: () => Promise<void> }) {
  const [cofre, setCofre] = useState<PontoJustificativa | null>(null)
  const [negando, setNegando] = useState<string | null>(null)
  const [resposta, setResposta] = useState('')
  const [ocupado, setOcupado] = useState<string | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const decidir = async (p: PontoJustificativa, aprovar: boolean) => {
    setOcupado(p.id); setErro(null)
    try { await api.pontoDecidir(p.id, aprovar, aprovar ? null : resposta.trim()); setNegando(null); setResposta(''); await aoDecidir() }
    catch (e) { setErro(erroMsg(e)) } finally { setOcupado(null) }
  }
  if (!linhas) return <Carregando />
  return (
    <div className="space-y-2">
      <h3 className="text-sm font-semibold">Pedidos dos funcionários <span className="font-normal text-muted-foreground">· pelo app (aba Ajuste) ou pelo WhatsApp (palavra "ajuste")</span></h3>
      {metricas && metricas.recebidos > 0 && (
        <div className="flex flex-wrap gap-2 text-xs">
          <span className="rounded border px-2 py-1">Recebidos no período: <strong>{metricas.recebidos}</strong></span>
          <span className="rounded border px-2 py-1" title="Meta: 90% decididos em até 2 dias úteis">Decididos em até 2 dias úteis: <strong>{metricas.decididos ? Math.round(100 * metricas.no_prazo / metricas.decididos) : 0}%</strong> ({metricas.no_prazo} de {metricas.decididos})</span>
          <span className={`rounded border px-2 py-1 ${metricas.parados > 0 ? 'border-red-300 bg-red-50 text-red-800' : ''}`}>Parados há mais de 2 dias úteis: <strong>{metricas.parados}</strong></span>
          <span className={`rounded border px-2 py-1 ${metricas.inclusoes_manuais > 0 ? 'border-amber-300 bg-amber-50 text-amber-800' : ''}`} title="Marcação incluída pelo gestor sem pedido do funcionário. Meta: não usar para cobrir ausência — use abono.">Inclusões manuais do gestor: <strong>{metricas.inclusoes_manuais}</strong></span>
        </div>
      )}
      {erro && <ErrorBox>{erro}</ErrorBox>}
      <div className="overflow-x-auto rounded-md border">
        <table className="w-full text-sm">
          <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
            <th className="px-3 py-2">Nº</th><th className="px-3 py-2">Dia</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Pedido</th>
            <th className="px-3 py-2">Situação</th><th className="px-3 py-2">{podeDecidir ? 'Decisão' : ''}</th>
          </tr></thead>
          <tbody>
            {linhas.length === 0 ? (
              <tr><td colSpan={6} className="py-8 text-center text-muted-foreground">Nenhum pedido em análise nem no período</td></tr>
            ) : linhas.map(p => (
              <tr key={p.id} className="border-b align-top last:border-0 hover:bg-muted/30">
                <td className="px-3 py-2 font-mono text-xs">{p.numero}</td>
                <td className="whitespace-nowrap px-3 py-2 text-xs">{dataComDia(p.data)}</td>
                <td className="px-3 py-2 text-xs">{p.tecnico}<p className="text-muted-foreground">{p.canal === 'app' ? 'App' : 'WhatsApp'} · {p.criado_em}</p>
                  {p.ponto_30d !== null && p.ponto_30d > 1 && <p className={p.ponto_30d >= 3 ? 'text-amber-700' : 'text-muted-foreground'} title="Pedidos de Ponto (esqueci, app falhou, atraso) nos 30 dias até este. Só o fato; atestado e falta prevista em lei não contam">{p.ponto_30d}º pedido de Ponto em 30 dias</p>}</td>
                <td className="max-w-xs px-3 py-2 text-xs"><p className="font-medium">{p.motivo_nome}</p><p>{p.detalhe}</p>
                  {p.observacao && <p className="text-muted-foreground">“{p.observacao}”</p>}
                  {p.restrito && <p className="text-muted-foreground">Restrito: só quem vê atestados abre e decide.</p>}
                  {p.alerta_limite && <p className="mt-1 rounded bg-amber-50 px-1.5 py-0.5 text-amber-800">{p.alerta_limite}</p>}
                  {p.fora_prazo && <p className="mt-1 text-amber-700">Enviado depois de 48 h.</p>}
                  {p.anexos > 0 && !p.restrito && podeDecidir && (
                    <Button size="sm" variant="outline" className="mt-1" onClick={() => setCofre(p)}><ShieldCheck className="h-3.5 w-3.5" /> Ver documento</Button>
                  )}</td>
                <td className="px-3 py-2 text-xs"><span className={`rounded px-1.5 py-0.5 font-medium ${STATUS_PEDIDO[p.status].cor}`}>{STATUS_PEDIDO[p.status].label}</span>
                  {p.decidido_em && <p className="mt-1 text-muted-foreground">{p.decidido_por ?? ''} · {p.decidido_em}</p>}
                  {p.resposta && <p className="mt-1 text-muted-foreground">{p.resposta}</p>}
                  {p.abono_estornado && <p className="mt-1 text-red-700">abono estornado depois</p>}
                  {p.dias_uteis_espera !== null && (p.dias_uteis_espera > 2
                    ? <p className="mt-1 font-medium text-red-700">parado há {p.dias_uteis_espera} dias úteis</p>
                    : <p className="mt-1 text-muted-foreground">aguardando há {p.dias_uteis_espera} dia(s) útil(eis)</p>)}</td>
                <td className="px-3 py-2 text-xs">
                  {podeDecidir && p.pode_decidir && p.status === 'pendente' && (negando === p.id ? (
                    <div className="w-80 space-y-1.5">
                      <Textarea rows={3} value={resposta} maxLength={500} autoFocus onChange={e => setResposta(e.target.value)}
                        placeholder="Ex.: não há registro de você na obra nesse horário." />
                      <p className={`text-[11px] ${resposta.trim().length < 10 ? 'text-amber-700' : 'text-muted-foreground'}`}>
                        {resposta.trim().length < 10 ? `Motivo com pelo menos 10 letras (faltam ${10 - resposta.trim().length}).` : 'Pronto para negar.'}
                        {' '}Vai ao funcionário pelo WhatsApp: não escreva doença nem CID.
                      </p>
                      <div className="flex gap-1.5">
                        <Button size="sm" variant="outline" onClick={() => { setNegando(null); setResposta(''); setErro(null) }}>Voltar</Button>
                        <Button size="sm" disabled={ocupado === p.id}
                          onClick={() => resposta.trim().length < 10 ? setErro('Escreva o motivo da negativa com pelo menos 10 letras.') : void decidir(p, false)}>
                          {ocupado === p.id && <Loader2 className="h-3.5 w-3.5 animate-spin" />} Negar
                        </Button>
                      </div>
                      {erro && negando === p.id && <p className="text-[11px] text-red-700">{erro}</p>}
                    </div>
                  ) : (
                    <div className="flex gap-1.5">
                      <Button size="sm" disabled={ocupado === p.id} onClick={() => void decidir(p, true)}>
                        {ocupado === p.id ? <Loader2 className="h-3.5 w-3.5 animate-spin" /> : <Check className="h-3.5 w-3.5" />} Aprovar
                      </Button>
                      <Button size="sm" variant="outline" onClick={() => { setNegando(p.id); setResposta('') }}><X className="h-3.5 w-3.5" /> Negar</Button>
                    </div>
                  ))}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {cofre && <Cofre justificativa={cofre.id} numero={cofre.numero} onFechar={() => setCofre(null)} />}
      {podeDecidir && <p className="text-xs text-muted-foreground">Aprovar "Esqueci de marcar" ou "App falhou" inclui a marcação (registro à parte, Portaria 671). Aprovar atraso ou saída antecipada abona o período, sem criar marcação. O funcionário recebe a resposta pelo WhatsApp.</p>}
    </div>
  )
}

// Abonos do período (estorno quando lançado por engano; o abono continua guardado)
function Abonos({ linhas, podeEstornar, aoEstornar }: { linhas: PontoAbono[] | null; podeEstornar: boolean; aoEstornar: () => Promise<void> }) {
  const [alvo, setAlvo] = useState<string | null>(null)
  const [motivo, setMotivo] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  if (!linhas || linhas.length === 0) return null
  const estornar = async (id: string) => {
    setErro(null)
    try { await api.pontoEstornarAbono(id, motivo.trim()); setAlvo(null); setMotivo(''); await aoEstornar() }
    catch (e) { setErro(erroMsg(e)) }
  }
  return (
    <div className="space-y-2">
      <h3 className="text-sm font-semibold">Abonos</h3>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      <div className="overflow-x-auto rounded-md border">
        <table className="w-full text-sm">
          <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
            <th className="px-3 py-2">Dia</th><th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Abono</th>
            {podeEstornar && <><th className="px-3 py-2">Motivo</th><th className="px-3 py-2">Por</th></>}<th className="px-3 py-2">Lançado em</th><th className="px-3 py-2" />
          </tr></thead>
          <tbody>
            {linhas.map(a => (
              <tr key={a.id} className={`border-b last:border-0 ${a.estornado ? 'text-muted-foreground line-through' : ''}`}>
                <td className="whitespace-nowrap px-3 py-2 text-xs">{dataComDia(a.data)}</td>
                <td className="px-3 py-2 text-xs">{a.tecnico}</td>
                <td className="px-3 py-2 text-xs">{a.detalhe}{a.pedido != null && <span className="text-muted-foreground"> · pedido {a.pedido}</span>}</td>
                {podeEstornar && <><td className="max-w-xs px-3 py-2 text-xs">{a.motivo}</td><td className="px-3 py-2 text-xs">{a.autor}</td></>}
                <td className="whitespace-nowrap px-3 py-2 text-xs">{a.criado_em}{a.estornado && ' · estornado'}</td>
                <td className="px-3 py-2 text-xs no-underline">
                  {podeEstornar && !a.estornado && (alvo === a.id ? (
                    <div className="flex items-center gap-1.5">
                      <Input value={motivo} onChange={e => setMotivo(e.target.value)} placeholder="Motivo do estorno" className="h-8 w-48" />
                      <Button size="sm" disabled={motivo.trim().length < 10} onClick={() => void estornar(a.id)}>Estornar</Button>
                    </div>
                  ) : <Button size="sm" variant="outline" onClick={() => { setAlvo(a.id); setMotivo('') }}><Undo2 className="h-3.5 w-3.5" /> Estornar</Button>)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
