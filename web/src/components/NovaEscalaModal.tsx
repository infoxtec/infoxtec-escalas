import { useEffect, useMemo, useState } from 'react'
import { AlertTriangle, CheckCircle2, XCircle } from 'lucide-react'
import MultiSelect from './MultiSelect'
import { Button, ErrorBox, Field, Input, Modal, Select, Textarea, useToast } from './ui'
import { api, erroMsg } from '../lib/api'
import { hojeBahia } from '../lib/types'
import type { Local, ResultadoLote, Tecnico } from '../lib/types'

export default function NovaEscalaModal({ open, onClose, onSuccess, tecnicos, locais }: {
  open: boolean; onClose: () => void; onSuccess: () => void; tecnicos: Tecnico[]; locais: Local[]
}) {
  const toast = useToast()
  const [ids, setIds] = useState<string[]>([])
  const [local, setLocal] = useState('')
  const [data, setData] = useState(hojeBahia())
  const [hora, setHora] = useState('08:00')
  const [duracao, setDuracao] = useState(240)
  const [prioridade, setPrioridade] = useState('normal')
  const [tarefa, setTarefa] = useState('')
  const [enviar, setEnviar] = useState(true)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [resultado, setResultado] = useState<ResultadoLote[] | null>(null)

  useEffect(() => {
    if (open) {
      setIds([]); setLocal(''); setData(hojeBahia()); setHora('08:00'); setDuracao(240)
      setPrioridade('normal'); setTarefa(''); setEnviar(true); setErro(null); setResultado(null)
    }
  }, [open])

  const ativos = useMemo(() => tecnicos.filter(t => t.ativo), [tecnicos])
  const semAutorizacao = ativos.filter(t => ids.includes(t.id) && !t.opt_in)

  const salvar = async () => {
    setErro(null)
    if (ids.length === 0) return setErro('Selecione pelo menos um técnico.')
    if (!data || !hora) return setErro('Informe data e hora.')
    if (!tarefa.trim()) return setErro('Descreva a tarefa.')
    setSalvando(true)
    try {
      const r = await api.criarEscalas({
        tecnicos: ids, local: local || null, data, hora, tarefa: tarefa.trim(),
        duracao: Number(duracao) || 240, prioridade, enviar,
      })
      onSuccess()
      if (r.every(x => x.resultado === 'criada')) {
        toast(r.length === 1 ? 'Escala criada.' : `${r.length} escalas criadas.`)
        onClose()
      } else {
        setResultado(r)
      }
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const n = ids.length
  return (
    <Modal open={open} onClose={() => { if (!salvando) onClose() }} title="Nova escala" width="max-w-xl"
      footer={resultado
        ? <Button onClick={onClose}>Fechar</Button>
        : <>
          <Button variant="outline" onClick={onClose} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>
            {salvando ? 'Salvando...' : n > 1 ? `Criar ${n} escalas` : 'Criar escala'}
          </Button>
        </>}>
      {resultado ? (
        <div className="space-y-2">
          <p className="text-sm font-medium">Resultado</p>
          <ul className="divide-y rounded-md border">
            {resultado.map(r => (
              <li key={r.tecnico_id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm">
                <span>{r.tecnico ?? r.tecnico_id}</span>
                {r.resultado === 'criada'
                  ? <span className="flex items-center gap-1 text-green-600"><CheckCircle2 className="h-4 w-4" /> Criada</span>
                  : r.resultado.startsWith('conflito')
                    ? <span className="flex items-center gap-1 text-amber-600"><AlertTriangle className="h-4 w-4" /> Conflito de horário</span>
                    : <span className="flex items-center gap-1 text-destructive" title={r.resultado}><XCircle className="h-4 w-4" /> Erro</span>}
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <div className="space-y-3">
          <Field label="Técnicos *">
            <MultiSelect
              opcoes={ativos.map(t => ({ value: t.id, label: t.nome, detalhe: t.funcao }))}
              valores={ids} onChange={setIds} placeholder="Selecione um ou mais técnicos" disabled={salvando} />
          </Field>
          {semAutorizacao.length > 0 && (
            <div className="flex items-start gap-2 rounded-md bg-amber-50 p-3 text-xs text-amber-800 dark:bg-amber-900/20 dark:text-amber-300">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>Sem autorização para mensagens: <strong>{semAutorizacao.map(t => t.nome).join(', ')}</strong>. As escalas serão salvas, mas nenhuma mensagem será enviada para eles.</span>
            </div>
          )}
          <Field label="Local">
            <Select value={local} onChange={e => setLocal(e.target.value)} disabled={salvando} className="w-full">
              <option value="">— a confirmar —</option>
              {locais.filter(l => l.ativo).map(l => <option key={l.id} value={l.id}>{l.nome}</option>)}
            </Select>
          </Field>
          <div className="grid grid-cols-3 gap-3">
            <Field label="Data *"><Input type="date" value={data} onChange={e => setData(e.target.value)} disabled={salvando} /></Field>
            <Field label="Hora *"><Input type="time" value={hora} onChange={e => setHora(e.target.value)} disabled={salvando} /></Field>
            <Field label="Duração (min)"><Input type="number" min={15} step={15} value={duracao} onChange={e => setDuracao(Number(e.target.value))} disabled={salvando} /></Field>
          </div>
          <Field label="Prioridade">
            <Select value={prioridade} onChange={e => setPrioridade(e.target.value)} disabled={salvando} className="w-full">
              <option value="baixa">Baixa</option><option value="normal">Normal</option><option value="urgente">Urgente</option>
            </Select>
          </Field>
          <Field label="Descrição da tarefa *">
            <Textarea rows={3} value={tarefa} onChange={e => setTarefa(e.target.value)} disabled={salvando}
              placeholder="Ex: instalação de 8 câmeras IP no hall e no subsolo" />
          </Field>
          <label className="flex items-start gap-2 text-sm">
            <input type="checkbox" className="mt-0.5" checked={enviar} onChange={e => setEnviar(e.target.checked)} disabled={salvando} />
            <span>Enviar WhatsApp agora
              <span className="block text-xs text-muted-foreground">Desmarcado, a escala fica como rascunho e nada é enviado.</span>
            </span>
          </label>
          {erro && <ErrorBox>{erro}</ErrorBox>}
        </div>
      )}
    </Modal>
  )
}
