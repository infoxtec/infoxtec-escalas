import { useCallback, useEffect, useState } from 'react'
import { RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Input } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import AlertaCritico from '../components/AlertaCritico'
import { addDays, ALERTA_JORNADA, formatDate, hojeBahia, minutosHm } from '../lib/types'
import type { PainelGerencial } from '../lib/types'

// Painel gerencial de aderência da escala e do ponto (backlog 099, decisão 78). Toda a conta é do banco
// (app_painel_gerencial); a tela só desenha. Números agregados, sem nome de funcionário.

const pct = (parte: number, total: number) => (total > 0 ? Math.round((parte / total) * 100) : null)

function Cartao({ titulo, valor, detalhe, destaque }: { titulo: string; valor: string; detalhe?: string; destaque?: 'bom' | 'atencao' }) {
  const cor = destaque === 'bom' ? 'text-green-700 dark:text-green-400' : destaque === 'atencao' ? 'text-amber-700 dark:text-amber-400' : ''
  return (
    <div className="rounded-lg border bg-card p-4">
      <p className="text-xs text-muted-foreground">{titulo}</p>
      <p className={`mt-1 text-2xl font-semibold tabular-nums ${cor}`}>{valor}</p>
      {detalhe && <p className="mt-1 text-xs text-muted-foreground">{detalhe}</p>}
    </div>
  )
}

export default function GerencialPage() {
  const [de, setDe] = useState(addDays(hojeBahia(), -30))
  const [ate, setAte] = useState(addDays(hojeBahia(), -1))
  const [dados, setDados] = useState<PainelGerencial | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [carregando, setCarregando] = useState(false)

  // a conta percorre cada funcionário e cada dia: carrega ao abrir e só de novo no botão Atualizar
  const carregar = useCallback(async (inicio: string, fim: string) => {
    setCarregando(true); setErro(null)
    try { setDados(await api.painelGerencial(inicio, fim)) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar(addDays(hojeBahia(), -30), addDays(hojeBahia(), -1)) }, [carregar])

  const e = dados?.escala
  const p = dados?.ponto
  const pctWhats = e ? pct(e.respondidas_whatsapp, e.enviadas) : null
  const pctUra = e ? pct(e.precisaram_ura, e.enviadas) : null
  const pctAtendidas = e ? pct(e.ligacoes_atendidas, e.ligacoes) : null
  const pctAjustes = p ? pct(p.ajustes, p.marcacoes) : null
  const alertas = p ? Object.entries(p.alertas).sort((a, b) => b[1] - a[1]) : []

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold">Indicadores de aderência</h2>
          <p className="text-xs text-muted-foreground">Programação e ponto no período (até 62 dias). Números do conjunto; só o Alerta Crítico mostra o funcionário.</p>
        </div>
        <div className="flex flex-wrap items-end gap-2">
          <label className="text-xs">De <Input type="date" value={de} max={ate} onChange={ev => setDe(ev.target.value)} className="w-40" /></label>
          <label className="text-xs">Até <Input type="date" value={ate} min={de} onChange={ev => setAte(ev.target.value)} className="w-40" /></label>
          <Button variant="outline" size="sm" onClick={() => void carregar(de, ate)} disabled={carregando}>
            <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
          </Button>
        </div>
      </div>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <AlertaCritico />

      {e && (
        <section className="space-y-2">
          <h3 className="text-sm font-semibold">Programação</h3>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Cartao titulo="Programações enviadas" valor={String(e.enviadas)} detalhe={`${e.confirmadas} confirmadas · ${e.recusadas} recusadas`} />
            <Cartao titulo="Resolvidas pelo WhatsApp" valor={pctWhats == null ? '—' : `${pctWhats}%`}
              detalhe={`${e.respondidas_whatsapp} de ${e.enviadas}, sem ligação de ninguém`} destaque={pctWhats != null && pctWhats >= 80 ? 'bom' : undefined} />
            <Cartao titulo="Precisaram da URA" valor={pctUra == null ? '—' : `${pctUra}%`}
              detalhe={`${e.precisaram_ura} programações · ${e.respondidas_ura} respondidas por telefone`} />
            <Cartao titulo="Ligações atendidas" valor={pctAtendidas == null ? '—' : `${pctAtendidas}%`}
              detalhe={`${e.ligacoes_atendidas} de ${e.ligacoes} ligações`} />
            <Cartao titulo="Sem resposta" valor={String(e.sem_resposta)} destaque={e.sem_resposta > 0 ? 'atencao' : undefined}
              detalhe="Nem WhatsApp nem telefone" />
            <Cartao titulo="Tempo de resposta (mediana)" valor={e.mediana_resposta_min == null ? '—' : `${e.mediana_resposta_min} min`}
              detalhe="Do primeiro envio à confirmação" />
          </div>
        </section>
      )}

      {p && (
        <section className="space-y-2">
          <h3 className="text-sm font-semibold">Ponto</h3>
          <p className="text-xs text-muted-foreground">
            Apurado até {formatDate(dados!.apurado_ate)} · {p.funcionarios} funcionários · jornada de referência: {minutosHm(p.jornada.dia_util_min)} de segunda a sexta,
            {' '}{minutosHm(p.jornada.sabado_min)} no sábado{p.jornada.sabado_sem_expediente_abona ? ' (sábado sem expediente abonado)' : ''}, 44 h na semana.
          </p>
          <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
            <Cartao titulo="Marcações" valor={String(p.marcacoes)} detalhe={`${p.dias_trabalhados} dias trabalhados`} />
            <Cartao titulo="Marcações ajustadas" valor={pctAjustes == null ? '—' : `${pctAjustes}%`}
              detalhe={`${p.ajustes} ajustes`} destaque={pctAjustes != null && pctAjustes > 10 ? 'atencao' : undefined} />
            <Cartao titulo="Dias abonados" valor={String(p.dias_abonados)} detalhe={`${minutosHm(p.minutos_abonados)} abonadas`} />
            <Cartao titulo="Hora extra" valor={minutosHm(p.minutos_hora_extra)} detalhe="Acima da jornada de cada dia" />
            <Cartao titulo="Semanas acima de 44 h" valor={`${p.semanas_acima_44h} de ${p.semanas}`}
              destaque={p.semanas_acima_44h > 0 ? 'atencao' : undefined} detalhe="Semanas inteiras no período" />
            <Cartao titulo="Semanas abaixo do esperado" valor={`${p.semanas_abaixo_esperado} de ${p.semanas}`}
              destaque={p.semanas_abaixo_esperado > 0 ? 'atencao' : undefined} detalhe={`Tolerância de ${p.jornada.tolerancia_dia_min} min por dia`} />
            <Cartao titulo="Saldo de horas" valor={`${p.saldo_min < 0 ? '−' : '+'}${minutosHm(Math.abs(p.saldo_min))}`}
              destaque={p.saldo_min < 0 ? 'atencao' : undefined} detalhe="Trabalhado menos o esperado, com os abonos" />
          </div>
          <div className="rounded-lg border bg-card p-4">
            <p className="mb-2 text-xs font-semibold">Desvios no registro de ponto (dias)</p>
            {alertas.length === 0
              ? <p className="text-xs text-muted-foreground">Nenhum desvio no período.</p>
              : <ul className="grid gap-1 text-sm sm:grid-cols-2">
                  {alertas.map(([a, n]) => (
                    <li key={a} className="flex justify-between gap-3"><span>{ALERTA_JORNADA[a] ?? a}</span><span className="tabular-nums font-medium">{n}</span></li>
                  ))}
                </ul>}
          </div>
        </section>
      )}
    </div>
  )
}
