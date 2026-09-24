export type Semaforo = 'verde' | 'ambar' | 'vermelho' | 'cinza'
export type Prioridade = 'baixa' | 'normal' | 'urgente'
export type Papel = 'admin' | 'gestor' | 'leitura'
export type StatusEscala =
  | 'rascunho' | 'agendada' | 'notificada' | 'confirmada' | 'recusada'
  | 'reagendada' | 'em_execucao' | 'concluida' | 'cancelada'

export interface Acesso { email: string | null; papel: Papel | null; nome: string | null }

export interface EscalaPainel {
  id: string
  data_servico: string
  hora_inicio: string
  tecnico: string
  telefone: string
  local: string
  endereco: string
  link_maps: string | null
  descricao_tarefa: string
  status: StatusEscala
  prioridade: Prioridade
  ultimo_envio_tipo: string | null
  tentativa: number | null
  status_envio: string | null
  enviada_em: string | null
  entregue_em: string | null
  lida_em: string | null
  resposta: string | null
  respondida_em: string | null
  supervisor_avisado_em: string | null
  semaforo: Semaforo
  pode_remover: boolean
  turno: Turno | null
  hora_fim_prevista: string | null
  duracao_prevista_min: number | null
  intervalo_min: number | null
  minutos_noturnos: number | null
}

export type Turno = 'diurno' | 'noturno' | 'misto'

export interface Jornada {
  turno: Turno; trabalho_min: number; intervalo_min: number; minutos_noturnos: number; hora_fim: string
}

export interface Pendencias {
  data: string
  total_tecnicos: number
  sem_escala: { id: string; nome: string; funcao: string }[]
  rascunhos: number
  prazo: string
  exige_escala: boolean
}

export interface Resumo {
  total: number; confirmadas: number; recusadas: number; aguardando: number
  nao_enviadas: number; criticas: number; pct_confirmacao: number
}

export interface LinhaTempo {
  escala_id: string; created_at: string; evento: string
  status_anterior: string | null; status_novo: string | null; ator: string | null
}

export interface Tecnico {
  id: string; nome: string; telefone_e164: string; funcao: string; equipe: string | null
  is_supervisor: boolean; opt_in: boolean; opt_in_em: string | null; ativo: boolean
  perfil_teste: boolean; created_at: string
}

export interface Local {
  id: string; nome: string; cliente: string | null; endereco: string | null; cidade: string | null
  referencia: string | null; link_maps: string | null; contato_local: string | null
  telefone_contato: string | null; ativo: boolean; created_at: string
}

export interface UsuarioPainel {
  email: string; nome: string | null; papel: Papel; ativo: boolean
  criado_por: string | null; created_at: string
}

export interface ResultadoLote { tecnico_id: string; tecnico: string | null; escala_id: string | null; resultado: string }

export function formatDate(d: string): string {
  const [y, m, dd] = d.split('-')
  return `${dd}/${m}/${y}`
}
export function formatTime(t: string): string { return t?.slice(0, 5) ?? '' }
export function formatDateTime(iso: string | null): string {
  if (!iso) return '—'
  return new Date(iso).toLocaleString('pt-BR', {
    timeZone: 'America/Bahia', day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit',
  })
}
export function hojeBahia(): string { return new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bahia' }) }
export function addDays(d: string, n: number): string {
  const x = new Date(d + 'T12:00:00')
  x.setDate(x.getDate() + n)
  return x.toLocaleDateString('en-CA')
}
export type Nivel = 'basico' | 'intermediario' | 'avancado'
export type SituacaoHabilidade = 'valida' | 'vencendo' | 'vencida' | 'sem_validade'

export interface Habilidade {
  id: string; nome: string; categoria: 'tecnica' | 'seguranca' | 'habilitacao' | 'outra'
  exige_validade: boolean; descricao: string | null; ativo: boolean
}
export interface TecnicoHabilidade {
  tecnico_id: string; tecnico: string; tecnico_ativo: boolean; funcao: string
  habilidade_id: string; habilidade: string; categoria: string; exige_validade: boolean
  nivel: Nivel; nivel_valor: number; validade: string | null; observacao: string | null
  atualizado_em: string; situacao: SituacaoHabilidade
}
export interface RequisitoTipo { habilidade_id: string; habilidade: string; nivel_minimo: Nivel }
export interface TipoAtividade {
  id: string; nome: string; descricao: string | null; ativo: boolean; requisitos: RequisitoTipo[]
}
export interface Aptidao { tecnico_id: string; nome: string; apto: boolean; faltando: string[] }

export interface TecnicoNoLocal {
  escala_id: string; tecnico: string; telefone: string; hora: string; fim: string | null
  status: StatusEscala; status_envio: string | null; tarefa: string; tipo: string | null
}
export interface PainelLocal {
  local_id: string | null; local: string; endereco: string | null; link_maps: string | null
  primeira_hora: string | null; total: number; confirmadas: number; aguardando: number
  recusadas: number; em_execucao: number; concluidas: number; criticas: number
  pct_aceite: number; pct_conclusao: number; tecnicos: TecnicoNoLocal[]
}

export const NIVEL_LABEL: Record<Nivel, string> = {
  basico: 'Básico', intermediario: 'Intermediário', avancado: 'Avançado',
}
export interface HabilidadeDoTecnico {
  habilidade_id: string; habilidade: string; categoria: string; exige_validade: boolean
  nivel: Nivel; validade: string | null; situacao: SituacaoHabilidade; observacao: string | null
}
export interface TecnicoAgrupado {
  tecnico_id: string; tecnico: string; funcao: string; equipe: string | null; ativo: boolean
  total: number; vencidos: number; vencendo: number; sem_data: number
  habilidades: HabilidadeDoTecnico[]
}

export const SITUACAO_HAB: Record<SituacaoHabilidade, { label: string; classe: string }> = {
  valida:       { label: 'Válido',        classe: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300' },
  vencendo:     { label: 'Vence em breve', classe: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300' },
  vencida:      { label: 'Vencido',        classe: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300' },
  sem_validade: { label: 'Sem data',       classe: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300' },
}
export function diasAte(data: string | null): number | null {
  if (!data) return null
  const hoje = new Date(new Date().toLocaleDateString('en-CA', { timeZone: 'America/Bahia' }) + 'T12:00:00')
  const alvo = new Date(data + 'T12:00:00')
  return Math.round((alvo.getTime() - hoje.getTime()) / 86400000)
}

export interface Ligacao {
  id: string; tentativa: number; digito: string | null; duracao_seg: number | null
  criada_em: string; erro: string | null
  status: 'criada' | 'discando' | 'atendida' | 'sem_resposta' | 'ocupado' | 'falha' | 'encerrada'
}
export const LIGACAO_LABEL: Record<Ligacao['status'], string> = {
  criada: 'preparando', discando: 'discando', atendida: 'atendida',
  sem_resposta: 'não atendeu', ocupado: 'ocupado', falha: 'falhou', encerrada: 'encerrada',
}

export type StatusBacklog = 'concluido' | 'parcial' | 'em_andamento' | 'bloqueado' | 'planejado'
export interface ItemBacklog {
  id: string; numero: number | null; tipo: 'backlog' | 'entrega' | 'divida'
  titulo: string; descricao: string | null; status: StatusBacklog
  esforco: 'P' | 'M' | 'G' | null; depende_de: string | null; observacao: string | null
  entregue_em: string | null; ordem: number; updated_at: string
  coluna: ColunaKanban; posicao: number
}
export type ColunaKanban = 'backlog' | 'a_fazer' | 'fazendo' | 'revisao' | 'feito'
export const COLUNAS_KANBAN: { id: ColunaKanban; titulo: string; dica: string }[] = [
  { id: 'backlog',  titulo: 'Backlog',  dica: 'Ideias e itens sem data' },
  { id: 'a_fazer',  titulo: 'A fazer',  dica: 'Priorizado para a próxima rodada' },
  { id: 'fazendo',  titulo: 'Fazendo',  dica: 'Em desenvolvimento agora' },
  { id: 'revisao',  titulo: 'Revisão',  dica: 'Construído, aguardando teste ou deploy' },
  { id: 'feito',    titulo: 'Feito',    dica: 'Em produção' },
]
export const STATUS_BACKLOG: Record<StatusBacklog, { label: string; classe: string; barra: string }> = {
  concluido:    { label: 'Concluído',   classe: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300', barra: 'bg-green-500' },
  parcial:      { label: 'Parcial',     classe: 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300',    barra: 'bg-blue-500' },
  em_andamento: { label: 'Em andamento', classe: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300', barra: 'bg-amber-500' },
  bloqueado:    { label: 'Bloqueado',   classe: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',        barra: 'bg-red-500' },
  planejado:    { label: 'Planejado',   classe: 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400',       barra: 'bg-gray-400' },
}
export const ESFORCO_LABEL: Record<string, string> = { P: 'até 3 dias', M: '1 a 2 semanas', G: '3 semanas ou mais' }

export const CATEGORIA_LABEL: Record<string, string> = {
  tecnica: 'Técnica', seguranca: 'Segurança', habilitacao: 'Habilitação', outra: 'Outra',
}

export function fmtDuracao(min: number | null | undefined): string {
  if (!min || min <= 0) return '—'
  const h = Math.floor(min / 60), m = min % 60
  return m === 0 ? `${h}h` : `${h}h${String(m).padStart(2, '0')}`
}
export const TURNO_LABEL: Record<Turno, string> = { diurno: 'Diurna', noturno: 'Noturna', misto: 'Mista' }
export function descricaoJornada(turno: Turno | null, trabalho: number | null, intervalo: number | null): string {
  if (!turno || !trabalho) return '—'
  const base = turno === 'diurno' ? `${fmtDuracao(trabalho)} de trabalho` : `8h CLT (${fmtDuracao(trabalho)} de relógio)`
  return `${TURNO_LABEL[turno]} · ${base}${intervalo ? ` + ${fmtDuracao(intervalo)} de intervalo` : ''}`
}

export function telefoneValido(t: string): boolean { return /^[1-9]\d{9,14}$/.test(t.replace(/\D/g, '')) }

export const SEMAFORO_CLASSES: Record<Semaforo, string> = {
  verde: 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300',
  ambar: 'bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300',
  vermelho: 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300',
  cinza: 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400',
}
export const SEMAFORO_DOT: Record<Semaforo, string> = {
  verde: 'bg-green-500', ambar: 'bg-amber-500', vermelho: 'bg-red-500', cinza: 'bg-gray-400',
}
export const STATUS_LABEL: Record<StatusEscala, string> = {
  rascunho: 'Rascunho', agendada: 'Agendada', notificada: 'Notificada', confirmada: 'Confirmada',
  recusada: 'Recusada', reagendada: 'Reagendada', em_execucao: 'Em execução',
  concluida: 'Concluída', cancelada: 'Cancelada',
}
export const PRIORIDADE_LABEL: Record<Prioridade, string> = { baixa: 'Baixa', normal: 'Normal', urgente: 'Urgente' }
export const PAPEL_LABEL: Record<Papel, string> = { admin: 'Administrador', gestor: 'Gestor', leitura: 'Somente leitura' }
export const ENVIO_LABEL: Record<string, string> = {
  enfileirada: 'enviando', enviada: 'enviada', entregue: 'entregue', lida: 'lida', falha: 'falha',
}
