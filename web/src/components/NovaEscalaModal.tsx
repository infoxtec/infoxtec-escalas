import { useEffect, useMemo, useState } from 'react'
import { AlertTriangle, CheckCircle2, Clock, Moon, ShieldAlert, XCircle } from 'lucide-react'
import MultiSelect from './MultiSelect'
import { Button, ErrorBox, Field, Input, Modal, Select, Textarea, useToast } from './ui'
import { api, erroMsg } from '../lib/api'
import { addDays, descricaoJornada, formatTime, hojeBahia } from '../lib/types'
import type { Aptidao, Jornada, Local, ResultadoLote, Tecnico, TipoAtividade } from '../lib/types'

export default function NovaEscalaModal({ open, onClose, onSuccess, tecnicos, locais, tipos, inicialIds, inicialData, embutido }: {
  open: boolean; onClose: () => void; onSuccess: () => void; tecnicos: Tecnico[]; locais: Local[]
  tipos: TipoAtividade[]; inicialIds?: string[]; inicialData?: string; embutido?: boolean
}) {
  const toast = useToast()
  const [ids, setIds] = useState<string[]>([])
  const [local, setLocal] = useState('')
  const [data, setData] = useState(hojeBahia())
  const [hora, setHora] = useState('08:00')
  const [prioridade, setPrioridade] = useState('normal')
  const [tarefa, setTarefa] = useState('')
  const [enviar, setEnviar] = useState(true)
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [resultado, setResultado] = useState<ResultadoLote[] | null>(null)
  const [jornada, setJornada] = useState<Jornada | null>(null)
  const [tipo, setTipo] = useState('')
  const [teste, setTeste] = useState(false)
  const [aptidao, setAptidao] = useState<Aptidao[] | null>(null)

  useEffect(() => {
    if (open) {
      setIds(inicialIds ?? []); setLocal(''); setData(inicialData ?? hojeBahia()); setHora('08:00')
      setPrioridade('normal'); setTarefa(''); setEnviar(true); setErro(null); setResultado(null)
      setTipo(''); setAptidao(null); setTeste(false)
    }
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  // Jornada calculada pelo banco (mesma regra que vai na mensagem do WhatsApp)
  useEffect(() => {
    if (!open || !/^\d{2}:\d{2}$/.test(hora)) return
    const t = setTimeout(() => { api.simularJornada(hora).then(setJornada).catch(() => setJornada(null)) }, 250)
    return () => clearTimeout(t)
  }, [hora, open])

  // Aptidão: quem não tem a habilidade exigida pelo tipo de atividade
  useEffect(() => {
    if (!open || !tipo) { setAptidao(null); return }
    api.aptidao(tipo).then(setAptidao).catch(() => setAptidao(null))
  }, [tipo, open])

  const ativos = useMemo(() => tecnicos.filter(t => t.ativo), [tecnicos])
  const semHabilidade = (aptidao ?? []).filter(a => ids.includes(a.tecnico_id) && !a.apto)
  const semAutorizacao = ativos.filter(t => ids.includes(t.id) && !t.opt_in)
  const soTeste = ids.length > 0 && ativos.filter(t => ids.includes(t.id)).every(t => t.perfil_teste)
  const testeEfetivo = teste || soTeste

  // A escala nunca pode comecar no passado: minimo de 5 minutos a frente
  const agora = new Date()
  const horaMinima = new Date(agora.getTime() + 5 * 60000)
    .toLocaleTimeString('en-GB', { timeZone: 'America/Bahia', hour: '2-digit', minute: '2-digit' })
  const ehHoje = data === hojeBahia()
  const horaNoPassado = ehHoje && hora < horaMinima
  const dataNoPassado = data < hojeBahia()

  const salvar = async () => {
    setErro(null)
    if (ids.length === 0) return setErro('Selecione pelo menos um técnico.')
    if (!data || !hora) return setErro('Informe data e hora de início.')
    if (dataNoPassado) return setErro('A data não pode ser anterior a hoje.')
    if (horaNoPassado) return setErro(`A escala precisa começar pelo menos 5 minutos à frente. O mais cedo hoje é ${horaMinima}.`)
    if (!tarefa.trim()) return setErro('Descreva a tarefa.')
    setSalvando(true)
    try {
      const r = await api.criarEscalas({
        tecnicos: ids, local: local || null, data, hora, tarefa: tarefa.trim(),
        duracao: 480, prioridade, enviar, // duracao e recalculada pelo banco (jornada CLT)
      })
      onSuccess()
      if (r.every(x => x.resultado === 'criada')) {
        toast(r.length === 1 ? 'Escala criada.' : `${r.length} escalas criadas.`)
        onClose()
      } else setResultado(r)
    } catch (e) { setErro(erroMsg(e)) }
    finally { setSalvando(false) }
  }

  const n = ids.length
  return (
    <Modal open={open} embutido={embutido} onClose={() => { if (!salvando) onClose() }} title="Nova escala" width="max-w-xl"
      footer={resultado
        ? <Button onClick={onClose}>Fechar</Button>
        : <>
          <Button variant="outline" onClick={onClose} disabled={salvando}>{embutido ? 'Limpar e voltar' : 'Cancelar'}</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>
            {salvando ? 'Salvando...' : `${testeEfetivo ? 'Criar teste' : 'Criar'}${n > 1 ? ` (${n})` : n === 1 ? ' escala' : ' escala'}`}
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
            <MultiSelect opcoes={ativos.map(t => ({ value: t.id, label: t.nome, detalhe: t.perfil_teste ? `${t.funcao} · teste` : t.funcao }))}
              valores={ids} onChange={setIds} placeholder="Selecione um ou mais técnicos" disabled={salvando} />
          </Field>
          {semAutorizacao.length > 0 && (
            <div className="flex items-start gap-2 rounded-md bg-amber-50 p-3 text-xs text-amber-800 dark:bg-amber-900/20 dark:text-amber-300">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              <span>Sem autorização para mensagens: <strong>{semAutorizacao.map(t => t.nome).join(', ')}</strong>. As escalas serão salvas, mas nenhuma mensagem será enviada para eles.</span>
            </div>
          )}
          <Field label="Tipo de atividade" hint="Define as habilidades exigidas do técnico.">
            <Select value={tipo} onChange={e => setTipo(e.target.value)} disabled={salvando} className="w-full">
              <option value="">— não informado —</option>
              {tipos.filter(t => t.ativo).map(t => <option key={t.id} value={t.id}>{t.nome}</option>)}
            </Select>
          </Field>
          {semHabilidade.length > 0 && (
            <div className="flex items-start gap-2 rounded-md bg-red-50 p-3 text-xs text-red-800 dark:bg-red-900/20 dark:text-red-300">
              <ShieldAlert className="mt-0.5 h-4 w-4 shrink-0" />
              <div>
                <p className="font-medium">Habilidade exigida em falta</p>
                <ul className="mt-0.5 space-y-0.5">
                  {semHabilidade.map(a => <li key={a.tecnico_id}>{a.nome}: {a.faltando.join(', ')}</li>)}
                </ul>
                <p className="mt-1">A escala pode ser criada assim mesmo — o aviso fica registrado para o supervisor decidir.</p>
              </div>
            </div>
          )}
          <Field label="Local">
            <Select value={local} onChange={e => setLocal(e.target.value)} disabled={salvando} className="w-full">
              <option value="">— a confirmar —</option>
              {locais.filter(l => l.ativo).map(l => <option key={l.id} value={l.id}>{l.nome}</option>)}
            </Select>
          </Field>
          <div className="grid grid-cols-2 gap-3">
            <Field label="Data *"><Input type="date" min={hojeBahia()} max={addDays(hojeBahia(), 365)} value={data}
              onChange={e => setData(e.target.value)} disabled={salvando} /></Field>
            <Field label="Hora de início *" hint={ehHoje ? `Hoje, no mínimo ${horaMinima}` : undefined}>
              <Input type="time" value={hora} min={ehHoje ? horaMinima : undefined}
                className={horaNoPassado || dataNoPassado ? 'border-destructive' : ''}
                onChange={e => setHora(e.target.value)} disabled={salvando} /></Field>
          </div>
          <div className="flex items-start gap-2 rounded-md border bg-muted/40 p-3 text-xs">
            {jornada?.turno === 'diurno' || !jornada ? <Clock className="mt-0.5 h-4 w-4 shrink-0 text-primary" /> : <Moon className="mt-0.5 h-4 w-4 shrink-0 text-indigo-500" />}
            {jornada ? (
              <div>
                <p className="font-medium text-foreground">Término previsto: {formatTime(jornada.hora_fim)}</p>
                <p className="text-muted-foreground">{descricaoJornada(jornada.turno, jornada.trabalho_min, jornada.intervalo_min)} · jornada normal CLT, sem hora extra</p>
              </div>
            ) : <p className="text-muted-foreground">Calculando a jornada…</p>}
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
            <input type="checkbox" className="mt-0.5" checked={testeEfetivo} disabled={salvando || soTeste}
              onChange={e => setTeste(e.target.checked)} />
            <span>Escala de teste
              <span className="block text-xs text-muted-foreground">
                {soTeste
                  ? 'Marcada automaticamente: todos os técnicos selecionados são de perfil de teste.'
                  : 'Funciona igual a uma escala normal, mas fica fora de todos os indicadores e pode ser removida a qualquer momento.'}
              </span>
            </span>
          </label>
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
