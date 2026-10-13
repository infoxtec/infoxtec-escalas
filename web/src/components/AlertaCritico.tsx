import { useCallback, useEffect, useState } from 'react'
import { AlertOctagon, CheckCircle2, FileSignature, RefreshCw } from 'lucide-react'
import { Button, ErrorBox, Input, Modal } from './ui'
import { api, erroMsg } from '../lib/api'
import { formatDate, hojeBahia, minutosHm } from '../lib/types'
import type { AceiteProgramacaoAssinado, CargaExcedida } from '../lib/types'

// Alerta Crítico — funcionário com carga horária excedida (backlog 105, decisão 90): quem passou do limite de 2 h
// extras sobre a jornada do dia na escala, hoje e no mês, e os aceites de risco que a empresa assinou nas
// Programações. A conta é do banco (app_carga_excedida).

export default function AlertaCritico() {
  const [mes, setMes] = useState(hojeBahia().slice(0, 7))
  const [dados, setDados] = useState<CargaExcedida | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [carregando, setCarregando] = useState(false)
  const [aceites, setAceites] = useState<AceiteProgramacaoAssinado[] | null>(null)
  const [termo, setTermo] = useState<AceiteProgramacaoAssinado | null>(null)

  const carregar = useCallback(async (m: string) => {
    setCarregando(true); setErro(null)
    try { setDados(await api.cargaExcedida(`${m}-01`)) } catch (e) { setErro(erroMsg(e)) }
    finally { setCarregando(false) }
  }, [])
  useEffect(() => { void carregar(hojeBahia().slice(0, 7)) }, [carregar])

  const verAceites = async () => {
    const ini = `${mes}-01`
    const d = new Date(`${ini}T12:00:00`); d.setMonth(d.getMonth() + 1); d.setDate(0)
    try { setAceites(await api.programacaoAceites(ini, d.toISOString().slice(0, 10))) } catch (e) { setErro(erroMsg(e)) }
  }

  const f = dados?.funcionarios ?? []
  // vermelho só quando alguém passou do limite; zerado, o bloco fica neutro (não parece alarme)
  const critico = !!dados && (dados.hoje > 0 || dados.mes_total > 0)
  return (
    <section className="space-y-2">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <h3 className={`flex items-center gap-1.5 text-sm font-semibold ${critico ? 'text-red-700 dark:text-red-400' : ''}`}>
          {critico ? <AlertOctagon className="h-4 w-4" /> : <CheckCircle2 className="h-4 w-4 text-green-600 dark:text-green-400" />}
          Alerta Crítico – Funcionário com carga horária excedida
        </h3>
        <div className="flex items-end gap-2">
          <label className="text-xs">Mês <Input type="month" value={mes} max={hojeBahia().slice(0, 7)} onChange={e => setMes(e.target.value)} className="w-40" /></label>
          <Button variant="outline" size="sm" onClick={() => void carregar(mes)} disabled={carregando}>
            <RefreshCw className={`h-3.5 w-3.5 ${carregando ? 'animate-spin' : ''}`} /> Atualizar
          </Button>
          {dados?.aceites_mes != null && <Button variant="outline" size="sm" onClick={() => void verAceites()}>
            <FileSignature className="h-3.5 w-3.5" /> Aceites da empresa ({dados.aceites_mes})</Button>}
        </div>
      </div>
      <p className="text-xs text-muted-foreground">
        Limite de {minutosHm(dados?.limite_dia_min ?? 120)} de hora extra por dia (CLT art. 59), contado sobre a jornada do dia na escala de
        cada funcionário (sem escala, a jornada padrão). Domingo e folga da escala contam inteiros.
      </p>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {dados && (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
          <div className={`rounded-lg border p-4 ${dados.hoje > 0 ? 'border-red-300 bg-red-50 dark:bg-red-900/20' : 'bg-card'}`}>
            <p className="text-xs text-muted-foreground">Acima do limite hoje</p>
            <p className={`mt-1 text-2xl font-semibold tabular-nums ${dados.hoje > 0 ? 'text-red-700 dark:text-red-400' : ''}`}>{dados.hoje}</p>
          </div>
          <div className={`rounded-lg border p-4 ${dados.mes_total > 0 ? 'border-red-300 bg-red-50 dark:bg-red-900/20' : 'bg-card'}`}>
            <p className="text-xs text-muted-foreground">Acima do limite em {dados.mes}</p>
            <p className={`mt-1 text-2xl font-semibold tabular-nums ${dados.mes_total > 0 ? 'text-red-700 dark:text-red-400' : ''}`}>{dados.mes_total}</p>
            {dados.apurado_ate && <p className="mt-1 text-xs text-muted-foreground">Apurado até {formatDate(dados.apurado_ate)}</p>}
          </div>
          {dados.aceites_mes != null && <div className="rounded-lg border bg-card p-4">
            <p className="text-xs text-muted-foreground">Aceites de risco da empresa no mês</p>
            <p className="mt-1 text-2xl font-semibold tabular-nums">{dados.aceites_mes}</p>
            <p className="mt-1 text-xs text-muted-foreground">Programações acima do limite</p>
          </div>}
        </div>
      )}
      {f.length > 0 && (
        <div className="overflow-x-auto rounded-md border border-red-200">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-red-50 text-left text-xs text-red-900 dark:bg-red-900/20 dark:text-red-200">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Dias acima</th><th className="px-3 py-2">Maior HE no dia</th>
              <th className="px-3 py-2">HE no mês / limite</th><th className="px-3 py-2">Hoje</th><th className="px-3 py-2">Último dia</th>
              {dados?.aceites_mes != null && <th className="px-3 py-2">Aceites</th>}
            </tr></thead>
            <tbody>
              {f.map(x => (
                <tr key={x.tecnico_id} className="border-b last:border-0">
                  <td className="px-3 py-2"><p className="font-medium">{x.tecnico}</p><p className="text-xs text-muted-foreground">{x.empresa}</p></td>
                  <td className="px-3 py-2 text-xs font-semibold text-red-700 dark:text-red-400">{x.dias_acima}</td>
                  <td className="px-3 py-2 text-xs">{minutosHm(x.maior_he_min)}</td>
                  <td className="px-3 py-2 text-xs">{minutosHm(x.he_mes_min)} / {minutosHm(x.limite_mes_min)}</td>
                  <td className={`px-3 py-2 text-xs ${x.hoje_acima ? 'font-semibold text-red-700 dark:text-red-400' : ''}`}>{x.hoje_he_min ? minutosHm(x.hoje_he_min) : '—'}</td>
                  <td className="px-3 py-2 text-xs">{x.ultimo_dia ? formatDate(x.ultimo_dia) : '—'}</td>
                  {dados?.aceites_mes != null && <td className="px-3 py-2 text-xs">{x.aceites ?? 0}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {dados && f.length === 0 && <p className="flex items-center justify-center gap-1.5 rounded-md border bg-card px-3 py-4 text-center text-sm text-muted-foreground">
        <CheckCircle2 className="h-4 w-4 text-green-600 dark:text-green-400" /> Ninguém acima do limite de {minutosHm(dados.limite_dia_min ?? 120)} extras no mês.</p>}

      <Modal open={aceites !== null} onClose={() => setAceites(null)} width="max-w-3xl" title="Aceites de risco da empresa (Programações acima do limite)"
        footer={<Button variant="outline" onClick={() => setAceites(null)}>Fechar</Button>}>
        {aceites && (aceites.length === 0 ? <p className="text-sm text-muted-foreground">Nenhum aceite no mês.</p> : (
          <ul className="divide-y text-sm">
            {aceites.map(a => (
              <li key={a.id} className="space-y-0.5 py-2">
                <p><strong>{formatDate(a.data)}</strong> · {a.tecnico} · previsto {minutosHm(a.previsto_min)}, passa {minutosHm(a.excedente_min)}</p>
                <p className="text-xs text-muted-foreground">{a.motivo} · assinado por {a.nome} em {new Date(a.aceito_em).toLocaleString('pt-BR', { timeZone: 'America/Bahia' })}</p>
                <button type="button" className="text-xs underline" onClick={() => setTermo(a)}>Ver termo</button>
              </li>
            ))}
          </ul>
        ))}
      </Modal>
      <Modal open={!!termo} onClose={() => setTermo(null)} width="max-w-2xl" title="Termo interno de aceite de risco"
        footer={<Button variant="outline" onClick={() => setTermo(null)}>Fechar</Button>}>
        {termo && <div className="space-y-2 text-sm">
          <p className="whitespace-pre-wrap">{termo.texto}</p>
          <p className="break-all font-mono text-[11px] text-muted-foreground">SHA-256 {termo.sha256}</p>
        </div>}
      </Modal>
    </section>
  )
}
