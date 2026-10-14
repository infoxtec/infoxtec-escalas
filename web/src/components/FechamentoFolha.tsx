import { useCallback, useEffect, useState } from 'react'
import { AlertTriangle, CheckCircle2, ClipboardCheck, Eye, Lock, Printer, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, SuccessBox } from './ui'
import EspelhoDocumento from './EspelhoDocumento'
import { api, erroMsg } from '../lib/api'
import type { EspelhoCompleto, FuncionarioFolha, PendenciaFolha, ValidacaoFolha } from '../lib/types'

// Validação e fechamento da folha mensal (decisões 96 e 97). Antes de fechar, o painel aponta por funcionário o que
// falta: pedido aguardando decisão, marcação incompleta e marcação duplicada impedem o fechamento; falta injustificada,
// intervalo abaixo do mínimo, HE acima de 2 h, descanso curto entre jornadas e abono em dia trabalhado precisam da
// confirmação do gestor. A prévia mostra o espelho como vai sair (HE, abonos, débitos). O fechamento emite o espelho de
// cada funcionário pronto (uma chamada por funcionário) e, no fim, envia pelo WhatsApp para assinatura.

function mesAnterior(hoje: string) {
  const [a, m] = hoje.split('-').map(Number)
  return m === 1 ? `${a - 1}-12` : `${a}-${String(m - 1).padStart(2, '0')}`
}
const SEMANA = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb']
const dia = (d: string) => `${d.slice(8, 10)}/${d.slice(5, 7)} ${SEMANA[new Date(d + 'T12:00:00').getDay()]}`
const hm = (m: number) => `${Math.floor(m / 60)}h${m % 60 ? String(m % 60).padStart(2, '0') : ''}`
const dataHora = (s: string) => new Date(s).toLocaleString('pt-BR', { timeZone: 'America/Bahia', dateStyle: 'short', timeStyle: 'short' })

function textoPendencia(p: PendenciaFolha) {
  const d = dia(p.data)
  switch (p.tipo) {
    case 'pedido_pendente': return `${d} · pedido nº ${p.numero} aguardando aprovação`
    case 'marcacao_incompleta': return `${d} · marcação faltando (${p.marcacoes} registrada${p.marcacoes === 1 ? '' : 's'})`
    case 'marcacao_duplicada': return `${d} · marcação duplicada: desconsidere a repetida`
    case 'sem_registro': return `${d} · falta injustificada (${hm(p.minutos)} sem registro nem pedido)`
    case 'intervalo_curto': return `${d} · intervalo abaixo do mínimo${p.intervalo_min != null ? ` (${hm(p.intervalo_min)})` : ''}`
    case 'sem_intervalo': return `${d} · jornada sem intervalo`
    case 'he_acima_limite': return `${d} · hora extra acima de 2 h${p.he_min ? ` (${hm(p.he_min)})` : ''}`
    case 'interjornada_curta': return `${d} · descanso entre jornadas abaixo de 11 h${p.interjornada_min ? ` (${hm(p.interjornada_min)})` : ''}`
    case 'abono_em_dia_trabalhado': return `${d} · abono do dia inteiro em dia com marcação: confira`
  }
}

type Situacao = 'assinado' | 'sem_ponto' | 'pendente' | 'confirmar' | 'pronto' | 'fechado'
function situacao(f: FuncionarioFolha): Situacao {
  if (f.espelho?.assinado_em) return 'assinado'
  if (!f.com_ponto && f.pendencias.length === 0) return 'sem_ponto'
  if (f.bloqueios > 0) return 'pendente'
  if (f.espelho) return 'fechado'
  if (f.a_confirmar > 0) return 'confirmar'
  return 'pronto'
}
const ROTULO: Record<Situacao, { texto: string; cor: string }> = {
  pendente: { texto: 'Ajustar antes de fechar', cor: 'bg-red-100 text-red-800' },
  confirmar: { texto: 'Confirmar ocorrências', cor: 'bg-amber-100 text-amber-800' },
  pronto: { texto: 'Pronto para fechar', cor: 'bg-green-100 text-green-800' },
  fechado: { texto: 'Fechado', cor: 'bg-blue-100 text-blue-800' },
  assinado: { texto: 'Assinado', cor: 'bg-emerald-100 text-emerald-800' },
  sem_ponto: { texto: 'Sem ponto no mês', cor: 'bg-muted text-muted-foreground' },
}

function Cartao({ titulo, valor, cor }: { titulo: string; valor: number | undefined; cor?: string }) {
  return (
    <div className="rounded-md border p-3">
      <p className="text-xs text-muted-foreground">{titulo}</p>
      <p className={`text-xl font-semibold ${cor ?? ''}`}>{valor ?? '—'}</p>
    </div>
  )
}

export default function FechamentoFolha({ hoje, podeFechar }: { hoje: string; podeFechar: boolean }) {
  const [mes, setMes] = useState(mesAnterior(hoje))
  const [v, setV] = useState<ValidacaoFolha | null>(null)
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [confirmo, setConfirmo] = useState(false)
  const [enviar, setEnviar] = useState(true)
  const [progresso, setProgresso] = useState<string | null>(null)
  const [previa, setPrevia] = useState<{ nome: string; e: EspelhoCompleto } | null>(null)

  // o espelho como vai sair ao fechar: HE, abonos (de onde vem cada um) e débitos
  const verPrevia = async (f: FuncionarioFolha) => {
    setErro(null)
    try {
      const r = await api.pontoPreviaFolha(`${mes}-01`, f.tecnico_id)
      setPrevia({ nome: f.nome, e: { id: '', registro: 0, versao: 1, codigo: '', sha256: '', emitido_em: new Date().toISOString(),
                                    substituido: false, conteudo: r.conteudo, assinado_em: null, assinatura_png: null } })
    } catch (e) { setErro(erroMsg(e)) }
  }

  const carregar = useCallback(async () => {
    setErro(null); setCarregando(true)
    try { setV(await api.pontoValidarFolha(`${mes}-01`)) }
    catch (e) { setErro(erroMsg(e)); setV(null) }
    finally { setCarregando(false) }
  }, [mes])
  useEffect(() => { void carregar(); setConfirmo(false); setOk(null) }, [carregar])

  const lista = v?.funcionarios ?? []
  const conta = (s: Situacao) => lista.filter(f => situacao(f) === s).length
  // fechado e ainda sem assinatura entra de novo: se algo mudou no ponto, sai uma nova versão do espelho
  const fechavel = (f: FuncionarioFolha) => ['pronto', 'confirmar', 'fechado'].includes(situacao(f))
  const aFechar = lista.filter(f => fechavel(f) && (f.a_confirmar === 0 || confirmo))
  const comFaltas = lista.filter(f => fechavel(f) && f.a_confirmar > 0)
  const faltasAConfirmar = comFaltas.reduce((n, f) => n + f.a_confirmar, 0)

  const fechar = async () => {
    setErro(null); setOk(null)
    let fechados = 0, pendentes = 0, semDados = 0, outros = 0
    try {
      for (let i = 0; i < aFechar.length; i++) {
        const f = aFechar[i]
        setProgresso(`Fechando ${i + 1} de ${aFechar.length}: ${f.nome}`)
        const r = await api.pontoFecharFolha(`${mes}-01`, f.tecnico_id, confirmo, f.a_confirmar)
        if (r.situacao === 'fechado') fechados++
        else if (r.situacao === 'pendente' || r.situacao === 'confirmar') pendentes++
        else if (r.situacao === 'sem_dados') semDados++
        else outros++
      }
      let envio = ''
      if (enviar && fechados > 0) {
        setProgresso('Enviando pelo WhatsApp...')
        const e = await api.pontoEnviarEspelhos(`${mes}-01`)
        envio = ` WhatsApp: ${e.enviados} enviado(s), ${e.sem_whatsapp} sem WhatsApp liberado, ${e.desligados} desligado(s) (entregar em papel), ${e.falhas} falha(s).`
      }
      setOk(`${fechados} folha(s) fechada(s).` + (pendentes ? ` ${pendentes} com pendência nova, não fechada(s).` : '')
        + (semDados ? ` ${semDados} sem dados.` : '') + (outros ? ` ${outros} sem mudança.` : '') + envio)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setProgresso(null); setConfirmo(false); await carregar() }
  }

  return (
    <section className="space-y-3">
      <div>
        <h3 className="flex items-center gap-1.5 text-sm font-semibold"><ClipboardCheck className="h-4 w-4" /> Validação e fechamento da folha</h3>
        <p className="text-xs text-muted-foreground">
          Antes de fechar, confira o que falta em cada funcionário. Em vermelho, o que impede o fechamento (pedido aguardando
          aprovação, marcação faltando ou duplicada): resolva na aba Ajustes e pedidos. Em amarelo, o que precisa da sua
          confirmação (falta injustificada, intervalo abaixo do mínimo, hora extra acima de 2 h, descanso curto entre
          jornadas, abono em dia trabalhado). Em <strong>Prévia</strong>, veja o espelho como vai sair, com HE, abonos e
          débitos. Fechar emite o espelho de cada funcionário pronto e envia o link pelo WhatsApp para assinatura.
        </p>
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Field label="Mês"><Input type="month" value={mes} max={mesAnterior(hoje)} onChange={e => e.target.value && setMes(e.target.value)} disabled={!!progresso} /></Field>
        <Button variant="outline" size="sm" onClick={() => void carregar()} disabled={carregando || !!progresso}><RefreshCw className="h-3.5 w-3.5" /> Validar de novo</Button>
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {ok && <SuccessBox>{ok}</SuccessBox>}

      {v && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
          <Cartao titulo="Ajustar antes de fechar" valor={conta('pendente')} cor="text-red-700" />
          <Cartao titulo="Confirmar ocorrências" valor={conta('confirmar')} cor="text-amber-700" />
          <Cartao titulo="Prontos para fechar" valor={conta('pronto')} cor="text-green-700" />
          <Cartao titulo="Fechados, sem assinatura" valor={conta('fechado')} cor="text-blue-700" />
          <Cartao titulo="Assinados" valor={conta('assinado')} cor="text-emerald-700" />
        </div>
      )}

      {v && (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Situação</th>
              <th className="px-3 py-2">O que falta</th><th className="px-3 py-2">Espelho</th>{podeFechar && <th className="px-3 py-2" />}
            </tr></thead>
            <tbody>
              {lista.length === 0 ? (
                <tr><td colSpan={5} className="py-8 text-center text-muted-foreground">Nenhum funcionário com ponto neste mês</td></tr>
              ) : lista.map(f => {
                const s = situacao(f)
                const bloq = f.pendencias.filter(p => p.bloqueia)
                const falt = f.pendencias.filter(p => !p.bloqueia)
                return (
                  <tr key={f.tecnico_id} className="border-b align-top last:border-0">
                    <td className="px-3 py-2"><p className="font-medium">{f.nome}</p><p className="text-xs text-muted-foreground">{f.empresa}</p></td>
                    <td className="whitespace-nowrap px-3 py-2"><span className={`rounded px-2 py-0.5 text-xs font-medium ${ROTULO[s].cor}`}>{ROTULO[s].texto}</span></td>
                    <td className="px-3 py-2 text-xs">
                      {f.pendencias.length === 0 ? <span className="text-muted-foreground">—</span> : (
                        <ul className="space-y-0.5">
                          {bloq.map((p, i) => <li key={`b${i}`} className="flex items-start gap-1 text-red-800"><AlertTriangle className="mt-0.5 h-3 w-3 shrink-0" /> {textoPendencia(p)}</li>)}
                          {falt.slice(0, 6).map((p, i) => <li key={`f${i}`} className="text-amber-800">{textoPendencia(p)}</li>)}
                          {falt.length > 6 && <li className="text-amber-800">e mais {falt.length - 6} ocorrência(s)</li>}
                        </ul>
                      )}
                    </td>
                    <td className="px-3 py-2 text-xs">
                      {f.espelho?.assinado_em ? <span className="inline-flex items-center gap-1 text-emerald-700"><Lock className="h-3 w-3" /> assinado em {dataHora(f.espelho.assinado_em)}</span>
                        : f.espelho?.enviado_em ? <span className="text-amber-700">nº {f.espelho.registro}, enviado, aguardando assinatura</span>
                        : f.espelho ? <span>nº {f.espelho.registro}, emitido em {dataHora(f.espelho.emitido_em)}</span>
                        : <span className="text-muted-foreground">não emitido</span>}
                      {f.fechado && <p className="text-muted-foreground">fechado{f.fechado.fechado_por && ` por ${f.fechado.fechado_por}`}{f.fechado.ocorrencias_confirmadas > 0 && `, ${f.fechado.ocorrencias_confirmadas} ocorrência(s) confirmada(s)`}</p>}
                    </td>
                    {podeFechar && <td className="px-3 py-2 text-right">
                      {f.com_ponto && !f.espelho?.assinado_em && <Button variant="ghost" size="sm" onClick={() => void verPrevia(f)} title="O espelho como vai sair ao fechar"><Eye className="h-3.5 w-3.5" /> Prévia</Button>}
                    </td>}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {v && podeFechar && (
        <div className="space-y-2 rounded-md border p-3">
          {faltasAConfirmar > 0 && (
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" className="mt-1" checked={confirmo} onChange={e => setConfirmo(e.target.checked)} disabled={!!progresso} />
              <span>Conferi as {faltasAConfirmar} ocorrência(s) em amarelo de {comFaltas.length} funcionário(s) e confirmo: falta injustificada sai
                descontada; intervalo, hora extra e descanso saem como calculados no espelho. Meu nome e as ocorrências ficam registrados no fechamento.</span>
            </label>
          )}
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={enviar} onChange={e => setEnviar(e.target.checked)} disabled={!!progresso} />
            Enviar o espelho pelo WhatsApp para assinatura ao fechar
          </label>
          <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" disabled={!!progresso || aFechar.length === 0} onClick={() => void fechar()}>
              <CheckCircle2 className="h-3.5 w-3.5" /> {progresso ? 'Fechando...' : `Fechar a folha de ${mes.slice(5, 7)}/${mes.slice(0, 4)} (${aFechar.length})`}
            </Button>
            {progresso && <span className="text-xs text-muted-foreground">{progresso}</span>}
            {!progresso && conta('pendente') > 0 && <span className="text-xs text-red-700">{conta('pendente')} funcionário(s) ficam de fora até ajustar.</span>}
            {!progresso && faltasAConfirmar > 0 && !confirmo && <span className="text-xs text-amber-700">Quem tem ocorrência em amarelo só fecha com a confirmação.</span>}
          </div>
        </div>
      )}
      <Modal open={!!previa} onClose={() => setPrevia(null)} width="max-w-3xl" title={`Prévia do espelho · ${previa?.nome ?? ''}`}
        footer={<>
          <Button variant="outline" onClick={() => setPrevia(null)}>Fechar</Button>
          <Button onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
        </>}>
        {previa && <EspelhoDocumento e={previa.e} previa />}
      </Modal>
    </section>
  )
}
