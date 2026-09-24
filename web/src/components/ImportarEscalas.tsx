import { useRef, useState } from 'react'
import type { ChangeEvent } from 'react'
import * as XLSX from 'xlsx'
import { CheckCircle2, ChevronRight, Download, FileSpreadsheet, Loader2, Upload, XCircle } from 'lucide-react'
import { Button, ErrorBox, Sheet } from './ui'
import { api, erroMsg } from '../lib/api'
import { hojeBahia } from '../lib/types'
import type { Local, Tecnico } from '../lib/types'

interface Linha {
  n: number; tecnico_nome: string; local_nome: string; data: string; hora: string; tarefa: string
  duracao: number; prioridade: string; enviar: boolean
  tecnico_id?: string; local_id?: string
  status: 'pendente' | 'ok' | 'erro'; erro?: string
}

const COLUNAS = ['tecnico_nome', 'local_nome', 'data', 'hora', 'tarefa', 'prioridade', 'enviar']
const semAcento = (s: string) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase().trim()

/** Exato primeiro; depois "contem", mas so se houver um unico candidato (evita "Ana" casar com "Mariana"). */
function casar<T extends { nome: string }>(nome: string, lista: T[]): { item?: T; erro?: string } {
  const q = semAcento(nome)
  if (!q) return {}
  const exato = lista.filter(x => semAcento(x.nome) === q)
  if (exato.length === 1) return { item: exato[0] }
  const parcial = lista.filter(x => semAcento(x.nome).includes(q) || q.includes(semAcento(x.nome)))
  if (parcial.length === 1) return { item: parcial[0] }
  if (parcial.length > 1) return { erro: `"${nome}" é ambíguo (${parcial.map(p => p.nome).join(', ')})` }
  return { erro: `"${nome}" não encontrado` }
}

function normData(raw: unknown): string {
  if (typeof raw === 'number') {
    const d = XLSX.SSF.parse_date_code(raw)
    if (d) return `${d.y}-${String(d.m).padStart(2, '0')}-${String(d.d).padStart(2, '0')}`
  }
  const s = String(raw ?? '').trim()
  const br = s.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/)
  if (br) return `${br[3]}-${br[2].padStart(2, '0')}-${br[1].padStart(2, '0')}`
  return s
}
function normHora(raw: unknown): string {
  if (typeof raw === 'number') {
    const t = Math.round(raw * 24 * 60)
    return `${String(Math.floor(t / 60) % 24).padStart(2, '0')}:${String(t % 60).padStart(2, '0')}`
  }
  const m = String(raw ?? '').trim().match(/^(\d{1,2})[:h](\d{2})/)
  return m ? `${m[1].padStart(2, '0')}:${m[2]}` : String(raw ?? '').trim()
}

function baixarModelo() {
  const ws = XLSX.utils.aoa_to_sheet([COLUNAS, ['David Cerqueira', 'Cond. Vila Real - Torre B', hojeBahia().split('-').reverse().join('/'), '08:00', 'Manutenção preventiva do CFTV', 'normal', 'sim']])
  ws['!cols'] = COLUNAS.map(c => ({ wch: c === 'tarefa' ? 40 : 20 }))
  const wb = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(wb, ws, 'Escalas')
  XLSX.writeFile(wb, 'modelo_importacao_escalas.xlsx')
}
function baixarReferencia(tecnicos: Tecnico[], locais: Local[]) {
  const ws = XLSX.utils.aoa_to_sheet([
    ['TÉCNICOS ATIVOS'], ['nome', 'funcao', 'equipe'],
    ...tecnicos.filter(t => t.ativo).map(t => [t.nome, t.funcao, t.equipe ?? '']),
    [], ['LOCAIS ATIVOS'], ['nome', 'cliente', 'cidade'],
    ...locais.filter(l => l.ativo).map(l => [l.nome, l.cliente ?? '', l.cidade ?? '']),
  ])
  const wb = XLSX.utils.book_new()
  XLSX.utils.book_append_sheet(wb, ws, 'Referência')
  XLSX.writeFile(wb, 'referencia_tecnicos_locais.xlsx')
}

export default function ImportarEscalas({ open, onClose, onSuccess, tecnicos, locais, embutido }: {
  open: boolean; onClose: () => void; onSuccess: () => void; tecnicos: Tecnico[]; locais: Local[]; embutido?: boolean
}) {
  const arquivo = useRef<HTMLInputElement>(null)
  const [linhas, setLinhas] = useState<Linha[]>([])
  const [importando, setImportando] = useState(false)
  const [erroLeitura, setErroLeitura] = useState<string | null>(null)

  const limpar = () => { setLinhas([]); setErroLeitura(null); if (arquivo.current) arquivo.current.value = '' }
  const fechar = () => { if (!importando) { limpar(); onClose() } }

  const ler = (e: ChangeEvent<HTMLInputElement>) => {
    const f = e.target.files?.[0]
    if (!f) return
    setLinhas([]); setErroLeitura(null)
    const reader = new FileReader()
    reader.onload = ev => {
      try {
        const wb = XLSX.read(new Uint8Array(ev.target?.result as ArrayBuffer), { type: 'array' })
        const ws = wb.Sheets[wb.SheetNames[0] ?? '']
        if (!ws) return setErroLeitura('Planilha vazia ou inválida.')
        const raw = XLSX.utils.sheet_to_json<Record<string, unknown>>(ws, { defval: '', raw: true })
        if (raw.length === 0) return setErroLeitura('Nenhuma linha encontrada na planilha.')
        if (raw.length > 300) return setErroLeitura('Máximo de 300 linhas por importação.')

        const ativosT = tecnicos.filter(t => t.ativo)
        const ativosL = locais.filter(l => l.ativo)
        setLinhas(raw.map((r, i) => {
          const g = (...k: string[]) => {
            for (const key of Object.keys(r)) if (k.includes(semAcento(key))) return String(r[key] ?? '').trim()
            return ''
          }
          const gRaw = (...k: string[]) => {
            for (const key of Object.keys(r)) if (k.includes(semAcento(key))) return r[key]
            return ''
          }
          const tecnico_nome = g('tecnico_nome', 'tecnico')
          const local_nome = g('local_nome', 'local')
          const data = normData(gRaw('data'))
          const hora = normHora(gRaw('hora', 'hora_inicio'))
          const tarefa = g('tarefa', 'descricao_tarefa', 'descricao')
          const prio = semAcento(g('prioridade') || 'normal')
          const env = semAcento(g('enviar') || 'sim')
          const t = casar(tecnico_nome, ativosT)
          const l = local_nome ? casar(local_nome, ativosL) : {}
          const erros: string[] = []
          if (!tecnico_nome) erros.push('Técnico em branco')
          else if (t.erro) erros.push(`Técnico ${t.erro}`)
          if (local_nome && l.erro) erros.push(`Local ${l.erro}`)
          if (!/^\d{4}-\d{2}-\d{2}$/.test(data)) erros.push('Data inválida (use DD/MM/AAAA)')
          if (!/^\d{2}:\d{2}$/.test(hora)) erros.push('Hora inválida (use HH:MM)')
          if (!tarefa) erros.push('Tarefa em branco')
          return {
            n: i + 2, tecnico_nome, local_nome, data, hora, tarefa,
            duracao: 480, // jornada CLT calculada pelo banco a partir da hora
            prioridade: ['baixa', 'normal', 'urgente'].includes(prio) ? prio : 'normal',
            enviar: ['sim', 's', 'true', '1', 'yes'].includes(env),
            tecnico_id: t.item?.id, local_id: l.item?.id,
            status: erros.length ? 'erro' : 'pendente', erro: erros.join('. ') || undefined,
          }
        }))
      } catch (ex) { setErroLeitura(`Erro ao ler o arquivo: ${erroMsg(ex)}`) }
    }
    reader.readAsArrayBuffer(f)
  }

  const importar = async () => {
    setImportando(true)
    const atual = [...linhas]
    let ok = 0
    for (let i = 0; i < atual.length; i++) {
      const r = atual[i]
      if (r.status !== 'pendente') continue
      try {
        const res = await api.criarEscalas({
          tecnicos: [r.tecnico_id!], local: r.local_id ?? null, data: r.data, hora: r.hora,
          tarefa: r.tarefa, duracao: r.duracao, prioridade: r.prioridade, enviar: r.enviar,
        })
        const x = res[0]
        if (x?.resultado === 'criada') { atual[i] = { ...r, status: 'ok', erro: undefined }; ok++ }
        else atual[i] = { ...r, status: 'erro', erro: x?.resultado.startsWith('conflito') ? 'Já existe escala nesse dia e horário' : (x?.resultado ?? 'Erro') }
      } catch (e) { atual[i] = { ...r, status: 'erro', erro: erroMsg(e) } }
      setLinhas([...atual])
    }
    setImportando(false)
    if (ok > 0) onSuccess()
  }

  const pend = linhas.filter(l => l.status === 'pendente').length
  const errs = linhas.filter(l => l.status === 'erro').length
  const oks = linhas.filter(l => l.status === 'ok').length

  return (
    <Sheet open={open} embutido={embutido} onClose={fechar} width="sm:max-w-2xl"
      title={<span className="flex items-center gap-2"><FileSpreadsheet className="h-5 w-5 text-primary" /> Importar escalas</span>}
      footer={<>
        <Button variant="outline" onClick={fechar} disabled={importando}>{embutido ? 'Limpar' : 'Fechar'}</Button>
        <Button onClick={() => void importar()} disabled={importando || pend === 0}>
          {importando ? <><Loader2 className="h-4 w-4 animate-spin" /> Importando...</> : `Importar ${pend} escala${pend !== 1 ? 's' : ''}`}
        </Button>
      </>}>
      <div className="space-y-5">
        <div className="space-y-2 rounded-md border bg-muted/40 p-4 text-sm">
          <p className="font-medium">Como importar</p>
          <ol className="list-inside list-decimal space-y-1 text-xs text-muted-foreground">
            <li>Baixe o modelo e preencha uma linha por escala.</li>
            <li>Nomes de técnicos e locais devem ser os cadastrados (acentos e maiúsculas não importam).</li>
            <li>A coluna <strong>enviar</strong> aceita sim ou não. Local pode ficar em branco.</li>
            <li>O término é calculado sozinho pela jornada CLT a partir da hora de início.</li>
            <li>Revise a prévia; só as linhas sem erro são importadas.</li>
          </ol>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={baixarModelo}><Download className="h-3.5 w-3.5" /> Baixar modelo Excel</Button>
          <Button variant="outline" size="sm" onClick={() => baixarReferencia(tecnicos, locais)}><Download className="h-3.5 w-3.5" /> Lista de técnicos e locais</Button>
        </div>
        <label className="flex cursor-pointer items-center justify-center gap-3 rounded-md border-2 border-dashed p-6 hover:bg-muted/30">
          <Upload className="h-6 w-6 text-muted-foreground" />
          <div className="text-center">
            <p className="text-sm font-medium">Clique para selecionar o arquivo</p>
            <p className="mt-0.5 text-xs text-muted-foreground">Excel (.xlsx, .xls) ou CSV</p>
          </div>
          <input ref={arquivo} type="file" accept=".xlsx,.xls,.csv" className="sr-only" onChange={ler} disabled={importando} />
        </label>
        {erroLeitura && <ErrorBox>{erroLeitura}</ErrorBox>}
        {linhas.length > 0 && (
          <div className="space-y-2">
            <div className="flex items-center justify-between text-sm">
              <p className="font-medium">
                {linhas.length} linha{linhas.length !== 1 ? 's' : ''}
                {pend > 0 && <span className="text-muted-foreground"> · {pend} prontas</span>}
                {errs > 0 && <span className="text-destructive"> · {errs} com erro</span>}
                {oks > 0 && <span className="text-green-600"> · {oks} importadas</span>}
              </p>
              <Button variant="ghost" size="sm" onClick={limpar} disabled={importando}>Limpar</Button>
            </div>
            <div className="max-h-72 overflow-auto rounded-md border">
              <table className="w-full text-xs">
                <thead className="sticky top-0 bg-muted">
                  <tr className="border-b text-left text-muted-foreground">
                    <th className="px-2 py-2">#</th><th className="px-2 py-2">Técnico</th><th className="px-2 py-2">Local</th>
                    <th className="px-2 py-2">Data</th><th className="px-2 py-2">Hora</th><th className="px-2 py-2">WA</th><th className="px-2 py-2">Situação</th>
                  </tr>
                </thead>
                <tbody>
                  {linhas.map(r => (
                    <tr key={r.n} className="border-b last:border-0">
                      <td className="px-2 py-1.5 text-muted-foreground">{r.n}</td>
                      <td className={`px-2 py-1.5 ${r.tecnico_id ? '' : 'text-destructive'}`}>{r.tecnico_nome || '—'}</td>
                      <td className={`px-2 py-1.5 ${r.local_nome && !r.local_id ? 'text-destructive' : ''}`}>{r.local_nome || '—'}</td>
                      <td className="px-2 py-1.5 font-mono">{r.data || '—'}</td>
                      <td className="px-2 py-1.5 font-mono">{r.hora || '—'}</td>
                      <td className="px-2 py-1.5">{r.enviar ? 'Sim' : 'Não'}</td>
                      <td className="px-2 py-1.5">
                        {r.status === 'ok' && <CheckCircle2 className="h-4 w-4 text-green-600" />}
                        {r.status === 'pendente' && <ChevronRight className="h-4 w-4 text-muted-foreground" />}
                        {r.status === 'erro' && <span className="flex items-center gap-1 text-destructive" title={r.erro}><XCircle className="h-4 w-4 shrink-0" /><span className="max-w-[200px] truncate">{r.erro}</span></span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </Sheet>
  )
}
