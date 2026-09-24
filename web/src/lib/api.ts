import { supabase } from './supabase'
import type {
  Acesso, EscalaPainel, Resumo, LinhaTempo, Tecnico, Local, UsuarioPainel, ResultadoLote, Papel, Pendencias, Jornada, Habilidade, TecnicoHabilidade, TipoAtividade, Aptidao, PainelLocal, TecnicoAgrupado, Ligacao, ItemBacklog, Documento,
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
    tarefa: string; duracao: number; prioridade: string; enviar: boolean; tipo?: string | null; teste?: boolean
  }) => rpc<ResultadoLote[]>('app_criar_escalas', {
    p_tecnicos: p.tecnicos, p_local: p.local, p_data: p.data, p_hora: p.hora,
    p_tarefa: p.tarefa, p_duracao: p.duracao, p_prioridade: p.prioridade, p_enviar: p.enviar,
    p_tipo: p.tipo ?? null, p_teste: p.teste ?? false,
  }),
  mudarStatus: (escalaId: string, status: string) =>
    rpc<string>('app_mudar_status', { p_escala: escalaId, p_status: status }),
  removerEscala: (escalaId: string) =>
    rpc<{ removida: boolean; aviso_enviado: boolean }>('app_remover_escala', { p_escala: escalaId }),
  ligarEscala: (escalaId: string) =>
    rpc<{ ligacao_id: string; enfileirada: boolean }>('app_ligar_escala', { p_escala: escalaId }),
  ligacoes: (escalaId: string) => rpc<Ligacao[]>('app_ligacoes', { p_escala: escalaId }),

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

  painelLocais: (data: string) => rpc<PainelLocal[]>('app_painel_locais', { p_data: data }),

  habilidades: () => rpc<Habilidade[]>('app_habilidades'),
  salvarHabilidade: (h: Partial<Habilidade>) => rpc<string>('app_salvar_habilidade', { p: h }),
  tecnicoHabilidades: () => rpc<TecnicoHabilidade[]>('app_tecnico_habilidades'),
  definirHabilidades: (tecnicoId: string, habilidades: { habilidade_id: string; nivel: string; validade?: string | null }[]) =>
    rpc<number>('app_definir_habilidades', { p_tecnico: tecnicoId, p_habilidades: habilidades }),
  habilidadesPorTecnico: () => rpc<TecnicoAgrupado[]>('app_habilidades_por_tecnico'),
  excluirHabilidade: (id: string, forcar = false) =>
    rpc<{ excluida: boolean; nome: string; tecnicos_afetados: number; tipos_afetados: number }>(
      'app_excluir_habilidade', { p_id: id, p_forcar: forcar }),
  removerTecnicoHabilidade: (tecnico: string, habilidade: string) =>
    rpc<void>('app_remover_tecnico_habilidade', { p_tecnico: tecnico, p_habilidade: habilidade }),
  tiposAtividade: () => rpc<TipoAtividade[]>('app_tipos_atividade'),
  salvarTipoAtividade: (t: { id?: string; nome: string; descricao?: string | null; ativo?: boolean; requisitos: { habilidade_id: string; nivel_minimo: string }[] }) =>
    rpc<string>('app_salvar_tipo_atividade', { p: t }),
  aptidao: (tipoId: string) => rpc<Aptidao[]>('app_aptidao', { p_tipo: tipoId }),

  backlog: () => rpc<ItemBacklog[]>('app_backlog'),
  salvarBacklogItem: (i: Partial<ItemBacklog>) => rpc<string>('app_salvar_backlog_item', { p: i }),
  moverBacklogItem: (id: string, coluna: string, posicao?: number) =>
    rpc<void>('app_mover_backlog_item', { p_id: id, p_coluna: coluna, p_posicao: posicao ?? null }),

  documentos: (tecnicoId?: string) => rpc<Documento[]>('app_documentos', { p_tecnico: tecnicoId ?? null }),
  registrarDocumento: (d: Record<string, unknown>) => rpc<string>('app_registrar_documento', { p: d }),
  excluirDocumento: (id: string) => rpc<string>('app_excluir_documento', { p_id: id }),

  usuarios: () => rpc<UsuarioPainel[]>('app_usuarios'),
  salvarUsuario: (u: { email: string; nome: string; papel: Papel; ativo: boolean }) =>
    rpc<string>('app_salvar_usuario', { p_email: u.email, p_nome: u.nome, p_papel: u.papel, p_ativo: u.ativo }),
}

/** Envia o arquivo ao Storage privado e registra os metadados. */
export async function enviarDocumento(p: {
  tecnicoId: string; habilidadeId: string | null; arquivo: File; validade: string | null
}): Promise<string> {
  const ext = p.arquivo.name.split('.').pop()?.toLowerCase() ?? 'bin'
  const caminho = `${p.tecnicoId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`
  const { error } = await supabase.storage.from('documentos')
    .upload(caminho, p.arquivo, { contentType: p.arquivo.type, upsert: false })
  if (error) throw new Error(`Falha no envio do arquivo: ${error.message}`)
  try {
    return await api.registrarDocumento({
      tecnico_id: p.tecnicoId, habilidade_id: p.habilidadeId, caminho,
      nome_arquivo: p.arquivo.name, mime: p.arquivo.type,
      tamanho_bytes: p.arquivo.size, validade: p.validade,
    })
  } catch (e) {
    // metadado falhou: nao deixa arquivo orfao no Storage
    await supabase.storage.from('documentos').remove([caminho])
    throw e
  }
}

export async function abrirDocumento(caminho: string): Promise<string> {
  const { data, error } = await supabase.storage.from('documentos').createSignedUrl(caminho, 120)
  if (error || !data) throw new Error('Não foi possível abrir o documento.')
  return data.signedUrl
}

export async function removerDocumento(id: string): Promise<void> {
  const caminho = await api.excluirDocumento(id)
  await supabase.storage.from('documentos').remove([caminho])
}

/** OCR: manda o arquivo para a Edge Function e recebe a data sugerida. */
export async function lerValidadePorOCR(arquivo: File): Promise<{ sugestao: string | null; erro?: string }> {
  const base64 = await new Promise<string>((ok, falha) => {
    const r = new FileReader()
    r.onload = () => ok(String(r.result).split(',')[1] ?? '')
    r.onerror = () => falha(new Error('Não consegui ler o arquivo.'))
    r.readAsDataURL(arquivo)
  })
  const { data: sessao } = await supabase.auth.getSession()
  const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/documento-ocr`
  const resp = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${sessao.session?.access_token ?? ''}` },
    body: JSON.stringify({ base64, mime: arquivo.type }),
  })
  const r = await resp.json().catch(() => ({}))
  if (!r.ok) return { sugestao: null, erro: r.erro ?? 'OCR indisponível.' }
  return { sugestao: r.sugestao ?? null }
}

export function erroMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
