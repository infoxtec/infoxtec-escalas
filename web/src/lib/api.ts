import { supabase } from './supabase'
import type {
  Acesso, EscalaPainel, Resumo, LinhaTempo, Tecnico, Local, UsuarioPainel, ResultadoLote, Papel, Pendencias, Jornada,
} from './types'

function traduzir(msg: string): string {
  if (/JWT expired|invalid JWT|not authenticated/i.test(msg)) return 'Sessão expirada. Entre novamente.'
  if (/permission denied/i.test(msg)) return 'Sem permissão para esta ação.'
  if (/Failed to fetch|NetworkError/i.test(msg)) return 'Sem conexão com o servidor. Verifique a internet.'
  return msg
}

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args)
  if (error) throw new Error(traduzir(error.message))
  return data as T
}

export const api = {
  meuAcesso: () => rpc<Acesso>('app_meu_acesso'),

  escalas: (inicio: string, fim: string) =>
    rpc<EscalaPainel[]>('app_escalas', { p_inicio: inicio, p_fim: fim }),
  resumo: (inicio: string, fim: string) =>
    rpc<Resumo>('app_resumo', { p_inicio: inicio, p_fim: fim }),
  linhaDoTempo: (escalaId: string) =>
    rpc<LinhaTempo[]>('app_linha_do_tempo', { p_escala: escalaId }),

  criarEscalas: (p: {
    tecnicos: string[]; local: string | null; data: string; hora: string
    tarefa: string; duracao: number; prioridade: string; enviar: boolean
  }) => rpc<ResultadoLote[]>('app_criar_escalas', {
    p_tecnicos: p.tecnicos, p_local: p.local, p_data: p.data, p_hora: p.hora,
    p_tarefa: p.tarefa, p_duracao: p.duracao, p_prioridade: p.prioridade, p_enviar: p.enviar,
  }),
  mudarStatus: (escalaId: string, status: string) =>
    rpc<string>('app_mudar_status', { p_escala: escalaId, p_status: status }),
  removerEscala: (escalaId: string) =>
    rpc<{ removida: boolean; aviso_enviado: boolean }>('app_remover_escala', { p_escala: escalaId }),
  reenviarEscala: (escalaId: string) =>
    rpc<{ reenviada: boolean; tentativa: number }>('app_reenviar_escala', { p_escala: escalaId }),

  tecnicos: () => rpc<Tecnico[]>('app_tecnicos'),
  salvarTecnico: (t: Partial<Tecnico>) => rpc<string>('app_salvar_tecnico', { p: t }),
  excluirTecnico: (id: string) =>
    rpc<{ excluido: boolean; escalas_removidas: number }>('app_excluir_tecnico', { p_tecnico: id }),

  locais: () => rpc<Local[]>('app_locais'),
  salvarLocal: (l: Partial<Local>) => rpc<string>('app_salvar_local', { p: l }),

  pendencias: (data: string) => rpc<Pendencias>('app_pendencias', { p_data: data }),
  simularJornada: (hora: string) => rpc<Jornada>('app_simular_jornada', { p_inicio: hora }),

  usuarios: () => rpc<UsuarioPainel[]>('app_usuarios'),
  salvarUsuario: (u: { email: string; nome: string; papel: Papel; ativo: boolean }) =>
    rpc<string>('app_salvar_usuario', { p_email: u.email, p_nome: u.nome, p_papel: u.papel, p_ativo: u.ativo }),
}

export function erroMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
