import { useEffect, useState } from 'react'
import { AlertOctagon } from 'lucide-react'
import { Field, Select, Textarea } from './ui'
import { api } from '../lib/api'
import { minutosHm } from '../lib/types'
import type { AceiteProgramacao, MotivoExcesso, ProgramacaoLimite } from '../lib/types'

// Programação que passa do limite de 2 h extras no dia, pela escala do técnico (decisão 90). Quem aceita o risco é a
// EMPRESA, pelo admin ou gestor que assina aqui; o termo é interno e o funcionário nunca o vê. O texto vem do banco
// (fn_programacao_termo) e é o mesmo que fica guardado, com a hora. Orientação do juridico (CLT arts. 59, 61 e 66).

const MOTIVOS: [MotivoExcesso, string][] = [
  ['forca_maior', 'Força maior'],
  ['servico_inadiavel', 'Serviço inadiável'],
  ['prejuizo_evidente', 'Prejuízo evidente se o serviço não for feito'],
  ['outro', 'Outro (fora das hipóteses do art. 61)'],
]

/** Consulta o limite e devolve o aceite pronto (ou null enquanto falta algo). excessos vazio: nada a assinar. */
export function useLimiteProgramacao(tecnicos: string[], data: string, hora: string, ignorar: string | null, ativo: boolean) {
  const [excessos, setExcessos] = useState<ProgramacaoLimite[]>([])
  const chave = `${tecnicos.join(',')}|${data}|${hora}|${ignorar ?? ''}`
  useEffect(() => {
    if (!ativo || tecnicos.length === 0 || !data || !/^\d{2}:\d{2}/.test(hora)) { setExcessos([]); return }
    const t = setTimeout(() => {
      api.programacaoLimite(tecnicos, data, hora, ignorar, null, null)
        .then(r => setExcessos(r.filter(x => x.excedente_min > 0))).catch(() => setExcessos([]))
    }, 300)
    return () => clearTimeout(t)
  }, [chave, ativo]) // eslint-disable-line react-hooks/exhaustive-deps
  return excessos
}

export default function AceiteExcesso({ excessos, data, hora, ignorar, onAceite }: {
  excessos: ProgramacaoLimite[]; data: string; hora: string; ignorar: string | null
  onAceite: (a: AceiteProgramacao | null) => void
}) {
  const [motivo, setMotivo] = useState<MotivoExcesso | ''>('')
  const [justificativa, setJustificativa] = useState('')
  const [aceito, setAceito] = useState(false)
  const [termos, setTermos] = useState<ProgramacaoLimite[]>([])
  const minimo = motivo === 'outro' ? 80 : 40
  const ids = excessos.map(x => x.tecnico_id)

  // o termo exato, com o motivo e a justificativa, vem do banco
  useEffect(() => {
    if (ids.length === 0) { setTermos([]); return }
    const t = setTimeout(() => {
      api.programacaoLimite(ids, data, hora, ignorar, motivo || null, justificativa.trim() || null)
        .then(r => setTermos(r.filter(x => x.excedente_min > 0))).catch(() => setTermos([]))
    }, 400)
    return () => clearTimeout(t)
  }, [ids.join(','), data, hora, ignorar, motivo, justificativa]) // eslint-disable-line react-hooks/exhaustive-deps
  // mudou o texto, assina de novo
  useEffect(() => { setAceito(false) }, [motivo, justificativa, ids.join(','), data, hora])
  useEffect(() => {
    const pronto = aceito && !!motivo && justificativa.trim().length >= minimo && termos.length === excessos.length
    onAceite(pronto ? { aceito: true, motivo: motivo as MotivoExcesso, justificativa: justificativa.trim(),
      vistos: Object.fromEntries(termos.map(x => [x.tecnico_id, x.excedente_min])) } : null)
  }, [aceito, motivo, justificativa, termos, excessos.length, minimo]) // eslint-disable-line react-hooks/exhaustive-deps

  if (excessos.length === 0) return null
  return (
    <div className="space-y-2 rounded-md border border-red-300 bg-red-50 p-3 text-xs text-red-900 dark:bg-red-900/20 dark:text-red-200">
      <p className="flex items-center gap-1.5 text-sm font-semibold"><AlertOctagon className="h-4 w-4" /> Passa do limite de 2 horas extras no dia</p>
      <ul className="space-y-0.5">
        {excessos.map(x => (
          <li key={x.tecnico_id}><strong>{x.tecnico}</strong>: previsto {minutosHm(x.previsto_min)}, jornada do dia pela escala {minutosHm(x.contratual_min)},
            limite {minutosHm(x.limite_min)} — passa {minutosHm(x.excedente_min)}</li>
        ))}
      </ul>
      <p className="rounded bg-white/60 p-2 text-[11px] text-red-950 dark:bg-black/20 dark:text-red-100">
        A lei limita as horas extras a 2 por dia (CLT, art. 59). Passar disso só é permitido em necessidade imperiosa: força
        maior, serviço inadiável ou serviço cuja não execução cause prejuízo evidente (art. 61). Fora da força maior, o dia não
        pode passar de 12 horas. Mantenha 11 horas de descanso entre um dia e outro (art. 66); as horas extras são pagas com
        adicional. Se o excesso se repete, deixa de ser exceção.
      </p>
      <div className="grid gap-2 sm:grid-cols-[220px_1fr]">
        <Field label="Motivo">
          <Select value={motivo} onChange={e => setMotivo(e.target.value as MotivoExcesso | '')} className="w-full">
            <option value="">Escolha</option>
            {MOTIVOS.map(([v, r]) => <option key={v} value={v}>{r}</option>)}
          </Select>
        </Field>
        <Field label={`Justificativa (mínimo ${minimo} caracteres)`}>
          <Textarea rows={3} value={justificativa} maxLength={1000} onChange={e => setJustificativa(e.target.value)}
            placeholder="O que aconteceu, qual cliente ou serviço, e por que não dava para remarcar ou trocar o técnico." />
        </Field>
      </div>
      {motivo === 'outro' && <p className="font-medium">Fora das hipóteses do art. 61 o excesso não tem cobertura legal. A decisão fica registrada.</p>}
      {excessos.some(x => x.previsto_min > 720) && motivo !== 'forca_maior' &&
        <p className="font-medium">O dia previsto passa de 12 horas: fora da força maior, a CLT não permite (art. 61, § 2º).</p>}
      {termos.length > 0 && justificativa.trim().length >= minimo && !!motivo && (
        <label className="flex items-start gap-2">
          <input type="checkbox" className="mt-0.5" checked={aceito} onChange={e => setAceito(e.target.checked)} />
          <span className="space-y-1">
            {termos.map(t => <span key={t.tecnico_id} className="block whitespace-pre-wrap">{t.termo}</span>)}
            <span className="block font-medium">Quem assina: você, como representante da empregadora. O funcionário não vê nem assina este termo.</span>
          </span>
        </label>
      )}
    </div>
  )
}
