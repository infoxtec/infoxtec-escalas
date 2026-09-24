import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { Calendar, Clock, ExternalLink, FileText, MapPin, Moon, Phone, SendHorizonal, Trash2, User } from 'lucide-react'
import { Button, Confirm, ErrorBox, Sheet, SuccessBox, useToast } from './ui'
import { api, erroMsg } from '../lib/api'
import {
  descricaoJornada, ENVIO_LABEL, formatDate, formatDateTime, formatTime, LIGACAO_LABEL, PRIORIDADE_LABEL, SEMAFORO_CLASSES, STATUS_LABEL,
} from '../lib/types'
import type { EscalaPainel, Ligacao, LinhaTempo, StatusEscala } from '../lib/types'

const PRIORIDADE_BADGE: Record<string, string> = {
  baixa: 'bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300',
  normal: 'bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300',
  urgente: 'bg-red-50 text-red-700 dark:bg-red-900/30 dark:text-red-300',
}

const EVENTO_LABEL: Record<string, string> = {
  criada: 'Escala criada', status_alterado: 'Status alterado', mensagem_enviada: 'Mensagem enviada',
  entregue_no_aparelho: 'Entregue no aparelho', lida: 'Lida', supervisor_acionado: 'Supervisor acionado',
  reenvio_manual: 'Reenvio manual', resposta_confirmacao: 'Técnico confirmou', resposta_problema: 'Técnico informou problema',
  resposta_motivo: 'Técnico detalhou o problema', resposta_texto_livre: 'Técnico escreveu uma mensagem',
}

type Acao =
  | { tipo: 'status'; status: StatusEscala; label: string; destrutiva?: boolean; texto: string }
  | { tipo: 'reenviar' } | { tipo: 'remover' } | { tipo: 'ligar' }

export default function EscalaDrawer({ escala, open, onClose, onRefresh, podeEditar }: {
  escala: EscalaPainel | null; open: boolean; onClose: () => void; onRefresh: () => void; podeEditar: boolean
}) {
  const toast = useToast()
  const [timeline, setTimeline] = useState<LinhaTempo[] | null>(null)
  const [ligacoes, setLigacoes] = useState<Ligacao[]>([])
  const [acao, setAcao] = useState<Acao | null>(null)
  const [busy, setBusy] = useState(false)
  const [erro, setErro] = useState<string | null>(null)
  const [sucesso, setSucesso] = useState<string | null>(null)

  const carregarTimeline = useCallback(async (id: string) => {
    setTimeline(null)
    try {
      const [tl, lg] = await Promise.all([api.linhaDoTempo(id), api.ligacoes(id)])
      setTimeline(tl); setLigacoes(lg)
    } catch (e) { setErro(erroMsg(e)); setTimeline([]) }
  }, [])

  useEffect(() => {
    if (open && escala) { setErro(null); setSucesso(null); void carregarTimeline(escala.id) }
  }, [open, escala?.id, carregarTimeline])

  if (!escala) return null

  const executar = async () => {
    if (!acao) return
    setBusy(true); setErro(null); setSucesso(null)
    try {
      if (acao.tipo === 'status') {
        await api.mudarStatus(escala.id, acao.status)
        setSucesso('Status atualizado.')
        onRefresh(); void carregarTimeline(escala.id)
      } else if (acao.tipo === 'ligar') {
        await api.ligarEscala(escala.id)
        setSucesso('Ligação disparada. O técnico deve receber a chamada em alguns segundos.')
        onRefresh(); void carregarTimeline(escala.id)
      } else if (acao.tipo === 'reenviar') {
        const r = await api.reenviarEscala(escala.id)
        setSucesso(`Reenvio disparado (tentativa ${r.tentativa}). O status atualiza em até 1 minuto.`)
        onRefresh(); void carregarTimeline(escala.id)
      } else {
        const r = await api.removerEscala(escala.id)
        toast(r.aviso_enviado ? 'Escala removida. Aviso de cancelamento enviado ao técnico.' : 'Escala removida.')
        setAcao(null); onRefresh(); onClose()
        return
      }
    } catch (e) { setErro(erroMsg(e)) }
    finally { setBusy(false) }
    setAcao(null)
  }

  const s = escala.status
  const podeLiberar = s === 'rascunho'
  const podeReenviar = s === 'agendada' || s === 'notificada'
  const podeExecucao = ['agendada', 'notificada', 'confirmada', 'reagendada'].includes(s)
  const podeConcluir = s === 'em_execucao'
  const podeCancelar = !['cancelada', 'concluida'].includes(s)
  const envioSaiu = escala.status_envio === 'enviada' || escala.status_envio === 'enfileirada'

  return (
    <>
      <Sheet open={open} onClose={onClose} title="Detalhes da escala">
        <div className="space-y-4">
          <div className="flex flex-wrap items-center gap-2">
            <span className={`rounded-full px-2.5 py-1 text-xs font-medium ${SEMAFORO_CLASSES[escala.semaforo]}`}>
              {STATUS_LABEL[s] ?? s}
            </span>
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${PRIORIDADE_BADGE[escala.prioridade] ?? ''}`}>
              {PRIORIDADE_LABEL[escala.prioridade] ?? escala.prioridade}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-3 text-sm">
            <Info icone={<Calendar className="h-4 w-4" />} label="Data" valor={formatDate(escala.data_servico)} />
            <Info icone={escala.turno && escala.turno !== 'diurno' ? <Moon className="h-4 w-4" /> : <Clock className="h-4 w-4" />} label="Horário"
              valor={`${formatTime(escala.hora_inicio)}${escala.hora_fim_prevista ? ` → ${formatTime(escala.hora_fim_prevista)}` : ''}`} />
            <Info icone={<User className="h-4 w-4" />} label="Técnico" valor={escala.tecnico} />
            <Info icone={<MapPin className="h-4 w-4" />} label="Local" valor={escala.local} />
          </div>

          <p className="-mt-1 text-xs text-muted-foreground">Jornada: {descricaoJornada(escala.turno, escala.duracao_prevista_min, escala.intervalo_min)}</p>

          {escala.endereco && (
            <div className="text-sm">
              <span className="text-xs text-muted-foreground">Endereço</span>
              <p className="mt-0.5">{escala.endereco}</p>
              {escala.link_maps && (
                <a href={escala.link_maps} target="_blank" rel="noopener noreferrer"
                  className="mt-1 inline-flex items-center gap-1 text-xs text-primary hover:underline">
                  <ExternalLink className="h-3 w-3" /> Ver no Google Maps
                </a>
              )}
            </div>
          )}

          <div className="text-sm">
            <span className="flex items-center gap-1 text-xs text-muted-foreground"><FileText className="h-3.5 w-3.5" /> Tarefa</span>
            <p className="mt-0.5 whitespace-pre-wrap">{escala.descricao_tarefa}</p>
          </div>

          <div className="space-y-1.5 rounded-md border bg-muted/30 p-3 text-xs">
            <p className="mb-2 text-sm font-semibold">Envio WhatsApp</p>
            <Linha label="Situação" valor={escala.status_envio ? (ENVIO_LABEL[escala.status_envio] ?? escala.status_envio) : '—'} />
            <Linha label="Tentativas" valor={escala.tentativa != null ? String(escala.tentativa) : '—'} />
            <Linha label="Enviada" valor={formatDateTime(escala.enviada_em)} />
            <Linha label="Entregue" valor={formatDateTime(escala.entregue_em)} />
            <Linha label="Lida" valor={formatDateTime(escala.lida_em)} />
            <Linha label="Resposta" valor={escala.resposta ?? '—'} />
            <Linha label="Respondida" valor={formatDateTime(escala.respondida_em)} />
            {escala.supervisor_avisado_em && <Linha label="Supervisor avisado" valor={formatDateTime(escala.supervisor_avisado_em)} />}
          </div>

          {erro && <ErrorBox>{erro}</ErrorBox>}
          {sucesso && !erro && <SuccessBox>{sucesso}</SuccessBox>}

          {podeEditar && (
            <div className="space-y-2">
              <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Ações</p>
              <div className="flex flex-wrap gap-2">
                {podeLiberar && <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => setAcao({ tipo: 'status', status: 'agendada', label: 'Liberar envio', texto: 'A escala sai pelo WhatsApp em até 1 minuto.' })}>Liberar envio</Button>}
                {podeReenviar && <Button size="sm" variant="outline" disabled={busy} onClick={() => setAcao({ tipo: 'reenviar' })}>
                  <SendHorizonal className="h-3.5 w-3.5" /> Reenviar WhatsApp</Button>}
                {podeReenviar && <Button size="sm" variant="outline" disabled={busy} onClick={() => setAcao({ tipo: 'ligar' })}>
                  <Phone className="h-3.5 w-3.5" /> Ligar agora</Button>}
                {podeExecucao && <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => setAcao({ tipo: 'status', status: 'em_execucao', label: 'Marcar em execução', texto: 'O técnico está no local executando o serviço.' })}>Marcar em execução</Button>}
                {podeConcluir && <Button size="sm" variant="outline" disabled={busy}
                  onClick={() => setAcao({ tipo: 'status', status: 'concluida', label: 'Concluir', texto: 'O serviço foi finalizado.' })}>Concluir</Button>}
                {podeCancelar && <Button size="sm" variant="destructive" disabled={busy}
                  onClick={() => setAcao({ tipo: 'status', status: 'cancelada', label: 'Cancelar escala', destrutiva: true, texto: 'A escala fica no histórico como cancelada e o motor para de cobrar o técnico.' })}>Cancelar</Button>}
                {escala.pode_remover && <Button size="sm" variant="destructive-outline" disabled={busy} onClick={() => setAcao({ tipo: 'remover' })}>
                  <Trash2 className="h-3.5 w-3.5" /> Remover escala</Button>}
              </div>
            </div>
          )}

          {ligacoes.length > 0 && (
            <div className="space-y-1.5 rounded-md border bg-muted/30 p-3 text-xs">
              <p className="mb-2 text-sm font-semibold">Ligações</p>
              {ligacoes.map(l => (
                <div key={l.id} className="flex justify-between gap-2">
                  <span className="text-muted-foreground">{formatDateTime(l.criada_em)} · tentativa {l.tentativa}</span>
                  <span className="text-right font-medium">
                    {LIGACAO_LABEL[l.status]}
                    {l.digito ? ` · digitou ${l.digito}` : ''}
                    {l.duracao_seg ? ` · ${l.duracao_seg}s` : ''}
                    {l.erro ? ` · ${l.erro}` : ''}
                  </span>
                </div>
              ))}
            </div>
          )}

          <hr />

          <div>
            <p className="mb-3 text-sm font-semibold">Linha do tempo</p>
            {timeline === null ? <p className="text-sm text-muted-foreground">Carregando...</p>
              : timeline.length === 0 ? <p className="text-sm text-muted-foreground">Nenhum evento registrado.</p>
              : (
                <ol>
                  {timeline.map((ev, i) => (
                    <li key={i} className="flex gap-3 text-xs">
                      <div className="flex flex-col items-center">
                        <div className="mt-1.5 h-2 w-2 shrink-0 rounded-full bg-primary" />
                        {i < timeline.length - 1 && <div className="my-1 w-px flex-1 bg-border" />}
                      </div>
                      <div className="pb-3">
                        <p className="font-medium">{EVENTO_LABEL[ev.evento] ?? ev.evento}</p>
                        <p className="text-muted-foreground">{formatDateTime(ev.created_at)}{ev.ator ? ` · ${ev.ator}` : ''}</p>
                        {ev.status_anterior && ev.status_novo && (
                          <p className="text-muted-foreground">
                            {STATUS_LABEL[ev.status_anterior as StatusEscala] ?? ev.status_anterior} → {STATUS_LABEL[ev.status_novo as StatusEscala] ?? ev.status_novo}
                          </p>
                        )}
                      </div>
                    </li>
                  ))}
                </ol>
              )}
          </div>
        </div>
      </Sheet>

      <Confirm
        open={!!acao}
        busy={busy}
        onCancel={() => setAcao(null)}
        onConfirm={() => void executar()}
        destructive={acao?.tipo === 'remover' || (acao?.tipo === 'status' && acao.destrutiva)}
        title={acao?.tipo === 'remover' ? 'Remover escala definitivamente'
          : acao?.tipo === 'reenviar' ? 'Reenviar pelo WhatsApp'
          : acao?.tipo === 'ligar' ? 'Ligar para o técnico'
          : (acao?.tipo === 'status' ? acao.label : '')}
        confirmLabel={acao?.tipo === 'remover' ? 'Remover' : acao?.tipo === 'reenviar' ? 'Reenviar agora'
          : acao?.tipo === 'ligar' ? 'Ligar agora' : 'Confirmar'}
      >
        {acao?.tipo === 'remover' && <>
          <p>O técnico ainda não recebeu esta escala, então ela pode ser apagada sem deixar histórico.</p>
          {envioSaiu && <p className="font-medium text-foreground">A mensagem já saiu: o técnico vai receber um aviso de cancelamento logo em seguida.</p>}
        </>}
        {acao?.tipo === 'reenviar' && <p>A mensagem sai agora de novo, com os botões, e conta como uma nova tentativa.</p>}
        {acao?.tipo === 'ligar' && <>
          <p>O sistema liga para o técnico agora. Uma voz lê a escala e pede para digitar <strong className="text-foreground">1 para aprovar</strong> ou <strong className="text-foreground">2 para negar</strong>.</p>
          <p>A resposta cai no mesmo lugar da resposta do WhatsApp e o status muda na hora.</p>
        </>}
        {acao?.tipo === 'status' && <p>{acao.texto}</p>}
      </Confirm>
    </>
  )
}

function Info({ icone, label, valor }: { icone: ReactNode; label: string; valor: string }) {
  return (
    <div>
      <span className="flex items-center gap-1 text-xs text-muted-foreground">{icone}{label}</span>
      <p className="mt-0.5 font-medium">{valor}</p>
    </div>
  )
}
function Linha({ label, valor }: { label: string; valor: string }) {
  return (
    <div className="flex justify-between gap-2">
      <span className="text-muted-foreground">{label}</span>
      <span className="max-w-[60%] break-words text-right font-medium">{valor}</span>
    </div>
  )
}
