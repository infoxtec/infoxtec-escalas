import { supabase } from './supabase'
import type {
  Acesso, EscalaPainel, Resumo, LinhaTempo, Tecnico, Local, UsuarioPainel, ResultadoLote, Papel, Pendencias, Jornada, Habilidade, TecnicoHabilidade, TipoAtividade, Aptidao, PainelLocal, Ligacao, ItemBacklog, Documento, TipoDocumento, TecnicoDocumentos, EstadoMotor, ChecklistSaude, IndicadoresResposta, EscalaEdicao, Empresa, PontoComprovante, PontoEu, PontoMarcacao, PontoTipo, PontoHoje, PontoAcompanhamento, PontoGeo, PontoEspelho, PontoAjuste, PontoJustificativa, PontoAbono, PontoMeuPedido, PontoDocumento, PontoVerificacao, PontoMetricas, PainelGerencial, DossieLocal, PontoAfd, PontoEspelhoEmitido, ConferenciaEspelho, EspelhoCompleto, FolhaCofre, ValidacaoCarga, ModeloCarga, CargaHoraria, CargaAtribuicao, CargaFuncionario, TimeEquipe, AlvoCarga, ProgramacaoLimite, AceiteProgramacao, AceiteProgramacaoAssinado, CargaExcedida, ValidacaoFolha, FechamentoFolha, PreviaFolha, PontoHeAutorizacao, EspelhoPdf } from './types'

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

// API do funcionário (funções ponto_*, decisão 49): sem login do Supabase, validada pelo token da sessão
export const ponto = {
  pedirCodigo: (cpf: string) => rpc<{ mensagem: string }>('ponto_pedir_codigo', { p_cpf: cpf }),
  meusEspelhos: (token: string) =>
    rpc<{ id: string; competencia: string; registro: number; assinado_em: string | null }[]>('ponto_meus_espelhos', { p_token: token }),
  meuEspelho: (token: string, id: string) => rpc<EspelhoCompleto>('ponto_meu_espelho', { p_token: token, p_id: id }),
  meuEspelhoPdf: (token: string, id: string) => rpc<EspelhoPdf>('ponto_meu_espelho_pdf', { p_token: token, p_id: id }),
  assinarEspelho: (token: string, id: string, sha256: string, assinatura: string) =>
    rpc<{ assinado_em: string }>('ponto_assinar_espelho', { p_token: token, p_id: id, p_sha256: sha256, p_assinatura: assinatura, p_ciente: true }),
  entrar: (cpf: string, codigo: string) =>
    rpc<{ token?: string; nome?: string; empresa?: string; erro?: string }>('ponto_entrar', { p_cpf: cpf, p_codigo: codigo }),
  sair: (token: string) => rpc<void>('ponto_sair', { p_token: token }),
  eu: (token: string, versaoAviso: string) => rpc<PontoEu>('ponto_eu', { p_token: token, p_versao_aviso: versaoAviso }),
  registrarCiencia: (token: string, versaoAviso: string) => rpc<void>('ponto_registrar_ciencia', { p_token: token, p_versao_aviso: versaoAviso }),
  bater: (token: string, tipo: PontoTipo, lat: number, lng: number, precisao: number, appVersao: string) =>
    rpc<PontoComprovante>('ponto_bater', { p_token: token, p_tipo: tipo, p_lat: lat, p_lng: lng, p_precisao: precisao, p_app_versao: appVersao }),
  avisoPrevio: (token: string, tipo: PontoTipo) => rpc<string | null>('ponto_aviso_previo', { p_token: token, p_tipo: tipo }),
  minhasMarcacoes: (token: string, dias: number) => rpc<PontoMarcacao[]>('ponto_minhas_marcacoes', { p_token: token, p_dias: dias }),
  // pedido de ajuste (084 entrega 3): o funcionário vem da sessão
  justificar: (token: string, p: { motivo: string; data: string; tipo?: string | null; hora?: string | null; ini?: string | null; fim?: string | null; observacao?: string | null }) =>
    rpc<{ numero: number; motivo: string; data: string; detalhe: string }>('ponto_justificar', {
      p_token: token, p_motivo: p.motivo, p_data: p.data, p_tipo_marcacao: p.tipo ?? null, p_hora: p.hora ?? null,
      p_hora_ini: p.ini ?? null, p_hora_fim: p.fim ?? null, p_observacao: p.observacao ?? null }),
  // falta com documento (E2): foto já reduzida no aparelho (sem EXIF) ou PDF, em base64
  justificarFalta: (token: string, p: { motivo: string; data: string; dataFim?: string | null; ini?: string | null; fim?: string | null; observacao?: string | null; anexo: string; anexoTipo: string }) =>
    rpc<{ numero: number; motivo: string; data: string; detalhe: string; alerta: string | null }>('ponto_justificar_falta', {
      p_token: token, p_motivo: p.motivo, p_data: p.data, p_data_fim: p.dataFim ?? null, p_hora_ini: p.ini ?? null, p_hora_fim: p.fim ?? null,
      p_observacao: p.observacao ?? null, p_anexo: p.anexo, p_anexo_tipo: p.anexoTipo }),
  // atestado (validade obrigatória) e alta médica: bloqueio do ponto e da escala no afastamento (decisão 60)
  justificarAtestado: (token: string, p: { motivo: 'atestado' | 'alta_medica'; data: string; validoAte?: string | null; observacao?: string | null; anexo: string; anexoTipo: string }) =>
    rpc<{ numero: number; motivo: string; data: string; detalhe: string; alerta: string | null; escalas_no_periodo: number }>('ponto_justificar_atestado', {
      p_token: token, p_motivo: p.motivo, p_data: p.data, p_valido_ate: p.validoAte ?? null, p_observacao: p.observacao ?? null,
      p_anexo: p.anexo, p_anexo_tipo: p.anexoTipo }),
  meusPedidos: (token: string) => rpc<PontoMeuPedido[]>('ponto_minhas_justificativas', { p_token: token }),
}

export const api = {
  meuAcesso: () => rpc<Acesso>('app_meu_acesso'),
  estadoMotor: () => rpc<EstadoMotor>('app_estado_motor'),
  checklistSaude: () => rpc<ChecklistSaude>('app_checklist_saude'),
  checklistTestar: () => rpc<{ enfileirado: boolean; recente?: boolean; erro: string | null }>('app_checklist_testar'),
  indicadoresResposta: (dias = 30) => rpc<IndicadoresResposta>('app_indicadores_resposta', { p_dias: dias }),
  painelGerencial: (de: string, ate: string) => rpc<PainelGerencial>('app_painel_gerencial', { p_de: de, p_ate: ate }),
  dossieLocal: (local: string, data: string) => rpc<DossieLocal>('app_dossie_local', { p_local: local, p_data: data }),
  escalaEdicao: (id: string) => rpc<EscalaEdicao>('app_escala_edicao', { p_escala: id }),
  editarEscala: (p: { id: string; data_servico: string; hora_inicio: string; local_id: string; descricao_tarefa: string; aceite?: AceiteProgramacao | null }) =>
    rpc<{ alterada: boolean; nova_confirmacao?: boolean }>('app_editar_escala', { p }),
  substituirTecnico: (escala: string, tecnico: string) =>
    rpc<{ escala: string }>('app_substituir_tecnico', { p_escala: escala, p_tecnico: tecnico }),

  escalas: (inicio: string, fim: string) =>
    rpc<EscalaPainel[]>('app_escalas', { p_inicio: inicio, p_fim: fim }),
  resumo: (inicio: string, fim: string) =>
    rpc<Resumo>('app_resumo', { p_inicio: inicio, p_fim: fim }),
  linhaDoTempo: (escalaId: string) =>
    rpc<LinhaTempo[]>('app_linha_do_tempo', { p_escala: escalaId }),

  criarEscalas: (p: {
    tecnicos: string[]; local: string; data: string; hora: string
    tarefa: string; duracao: number; prioridade: string; enviar: boolean; tipo?: string | null; teste?: boolean
    aceite?: AceiteProgramacao | null
  }) => rpc<ResultadoLote[]>('app_criar_escalas', {
    p_tecnicos: p.tecnicos, p_local: p.local, p_data: p.data, p_hora: p.hora,
    p_tarefa: p.tarefa, p_duracao: p.duracao, p_prioridade: p.prioridade, p_enviar: p.enviar,
    p_tipo: p.tipo ?? null, p_teste: p.teste ?? false, p_aceite: p.aceite ?? null,
  }),
  // Limite de 2 h extras no dia pela escala e aceite da empresa (decisão 90)
  programacaoLimite: (tecnicos: string[], data: string, hora: string, ignorar: string | null, motivo: string | null, justificativa: string | null) =>
    rpc<ProgramacaoLimite[]>('app_programacao_limite', { p_tecnicos: tecnicos, p_data: data, p_hora: hora, p_ignorar: ignorar,
      p_motivo: motivo, p_justificativa: justificativa }),
  programacaoAceites: (de: string, ate: string) => rpc<AceiteProgramacaoAssinado[]>('app_programacao_aceites', { p_de: de, p_ate: ate }),
  cargaExcedida: (mes: string | null) => rpc<CargaExcedida>('app_carga_excedida', { p_mes: mes }),
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
  tecnicoCpf: (id: string) => rpc<string | null>('app_tecnico_cpf', { p_tecnico: id }),
  empresas: () => rpc<Empresa[]>('app_empresas'),
  pontoGerarCodigo: (tecnico: string) => rpc<{ codigo: string; nome: string; expira_em: string }>('app_ponto_gerar_codigo', { p_tecnico: tecnico }),
  salvarEmpresa: (e: Partial<Empresa>) => rpc<string>('app_salvar_empresa', { p: e }),
  pontoHoje: () => rpc<PontoHoje[]>('app_ponto_hoje'),
  pontoAcompanhamento: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoAcompanhamento[]>('app_ponto_acompanhamento', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  pontoEspelho: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoEspelho[]>('app_ponto_espelho', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  pontoJustificativas: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoJustificativa[]>('app_ponto_justificativas', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  pontoMetricas: (de: string, ate: string) => rpc<PontoMetricas>('app_ponto_justificativas_metricas', { p_de: de, p_ate: ate }),
  pontoAfastados: () => rpc<{ tecnico_id: string; tecnico: string; afastado_ate: string; pode_registrar_alta: boolean }[]>('app_ponto_afastados'),
  pontoRegistrarAlta: (tecnico: string, data: string, anexo: string, tipo: string, observacao: string | null) =>
    rpc<{ numero: number; data: string; afastado_ate: string | null }>('app_ponto_registrar_alta', { p_tecnico: tecnico, p_data: data, p_anexo: anexo, p_anexo_tipo: tipo, p_observacao: observacao }),
  pontoDecidir: (id: string, aprovar: boolean, resposta: string | null) =>
    rpc<{ numero: number; status: string }>('app_ponto_decidir', { p_id: id, p_aprovar: aprovar, p_resposta: resposta }),
  pontoAbonar: (tecnico: string, data: string, motivo: string, inicio: string | null, fim: string | null) =>
    rpc<{ id: string; data: string; detalhe: string; espelho_desatualizado?: boolean }>('app_ponto_abonar', { p_tecnico: tecnico, p_data: data, p_motivo: motivo, p_inicio: inicio, p_fim: fim }),
  pontoFolgaCompensatoria: (tecnico: string, folga: string, trabalhado: string) =>
    rpc<{ id: string; folga: string; trabalhado: string }>('app_ponto_folga_compensatoria', { p_tecnico: tecnico, p_folga: folga, p_trabalhado: trabalhado }),
  pontoAbonos: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoAbono[]>('app_ponto_abonos', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  pontoAnexos: (justificativa: string) =>
    rpc<{ id: string; tipo: string; tamanho: number; criado_em: string; visualizacoes: number }[]>('app_ponto_anexos', { p_justificativa: justificativa }),
  pontoAnexoVer: (anexo: string) => rpc<PontoDocumento>('app_ponto_anexo_ver', { p_anexo: anexo }),
  pontoVerificarDocumento: (codigo: string) => rpc<PontoVerificacao>('app_ponto_verificar_documento', { p_codigo: codigo }),
  pontoAnexoDescartar: (anexo: string, motivo: string) => rpc<void>('app_ponto_anexo_descartar', { p_anexo: anexo, p_motivo: motivo }),
  veSaudeHistorico: () => rpc<{ email: string; valor: boolean; autor: string; em: string }[]>('app_ve_saude_historico'),
  usuariosMfa: () => rpc<{ ativos: { email: string; desde: string }[]; historico: { email: string; acao: 'ativou' | 'desativou'; em: string }[] }>('app_usuarios_mfa'),
  pontoEstornarAbono: (abono: string, motivo: string) => rpc<{ id: string; espelho_desatualizado?: boolean }>('app_ponto_estornar_abono', { p_abono: abono, p_motivo: motivo }),
  pontoAjustes: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoAjuste[]>('app_ponto_ajustes', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  // desconsiderar: marcação ou inclusão vinda de pedido aprovado (o gestor não inclui marcação, decisão 89)
  pontoAjustar: (a: { tecnico: string; acao: 'desconsiderar'; motivo: string; marcacao?: string; ajuste?: string }) =>
    rpc<{ id: string; data: string; hora: string; avisado: boolean; espelho_desatualizado?: boolean }>('app_ponto_ajustar', {
      p_tecnico: a.tecnico, p_acao: a.acao, p_motivo: a.motivo, p_marcacao: a.marcacao ?? null, p_ajuste: a.ajuste ?? null }),
  pontoGeo: (de: string, ate: string, tecnico: string | null) =>
    rpc<PontoGeo[]>('app_ponto_geo', { p_de: de, p_ate: ate, p_tecnico: tecnico }),
  // Hora extra com aprovação do gestor (decisão 100, parte 2)
  pontoHeAutorizacoes: (de: string, ate: string) => rpc<PontoHeAutorizacao[]>('app_ponto_he_autorizacoes', { p_de: de, p_ate: ate }),
  pontoHeDecidir: (id: string, aprovar: boolean) =>
    rpc<{ situacao: 'aprovada' | 'reprovada' | 'ja_decidida'; numero: number }>('app_ponto_he_decidir', { p_id: id, p_aprovar: aprovar }),
  pontoAfd: (empresa: string, de: string, ate: string) => rpc<PontoAfd>('app_ponto_afd', { p_empresa: empresa, p_de: de, p_ate: ate }),
  pontoEmitirEspelhos: (competencia: string, tecnico: string | null = null) =>
    rpc<{ emitidos: number; sem_mudanca: number; ja_assinados: number; sem_dados: number; com_pendencia: number; a_confirmar: number }>('app_ponto_emitir_espelhos', { p_competencia: competencia, p_tecnico: tecnico }),
  // Validação e fechamento da folha (decisão 96): o fechamento vai um funcionário por chamada
  pontoValidarFolha: (competencia: string) => rpc<ValidacaoFolha>('app_ponto_validar_folha', { p_competencia: competencia }),
  pontoFecharFolha: (competencia: string, tecnico: string, confirmar: boolean, vistas: number) =>
    rpc<FechamentoFolha>('app_ponto_fechar_folha', { p_competencia: competencia, p_tecnico: tecnico, p_confirmar_faltas: confirmar, p_ocorrencias_vistas: vistas }),
  pontoPreviaFolha: (competencia: string, tecnico: string) => rpc<PreviaFolha>('app_ponto_previa_folha', { p_competencia: competencia, p_tecnico: tecnico }),
  pontoEspelhosEmitidos: (competencia: string) => rpc<PontoEspelhoEmitido[]>('app_ponto_espelhos', { p_competencia: competencia }),
  verificarEspelho: (codigo: string) => rpc<ConferenciaEspelho>('ponto_verificar_espelho', { p_codigo: codigo }),
  pontoEnviarEspelhos: (competencia: string, espelho: string | null = null) =>
    rpc<{ enviados: number; sem_whatsapp: number; falhas: number; desligados: number }>('app_ponto_enviar_espelhos', { p_competencia: competencia, p_espelho: espelho }),
  pontoEspelhoVer: (id: string) => rpc<EspelhoCompleto>('app_ponto_espelho_ver', { p_id: id }),
  // Cofre das folhas assinadas, só RH (decisão 86)
  pontoCofreFolhas: (competencia: string | null, tecnico: string | null) =>
    rpc<FolhaCofre[]>('app_ponto_cofre_folhas', { p_competencia: competencia, p_tecnico: tecnico }),
  pontoEspelhoProva: (id: string) => rpc<Record<string, unknown>>('app_ponto_espelho_prova', { p_id: id }),
  pontoEspelhoPdf: (id: string) => rpc<EspelhoPdf>('app_ponto_espelho_pdf', { p_id: id }),
  // Escala / Carga Horária e Times (decisão 88)
  cargasModelos: () => rpc<ModeloCarga[]>('app_cargas_modelos'),
  cargaValidar: (p: Record<string, unknown>, instrumento: string | null) =>
    rpc<ValidacaoCarga>('app_carga_validar', { p, p_instrumento: instrumento }),
  salvarCarga: (p: Record<string, unknown>, aceite: { aceito: boolean; instrumento: string | null; riscos: string[] } | null) =>
    rpc<string>('app_salvar_carga', { p, p_aceite: aceite }),
  cargaAtivar: (id: string, ativo: boolean) => rpc<void>('app_carga_ativar', { p_id: id, p_ativo: ativo }),
  cargas: (empresa: string | null) => rpc<CargaHoraria[]>('app_cargas', { p_empresa: empresa }),
  atribuirCarga: (carga: string, alvo: AlvoCarga, alvoId: string, inicio: string, fim: string | null) =>
    rpc<string>('app_atribuir_carga', { p_carga: carga, p_alvo: alvo, p_alvo_id: alvoId, p_inicio: inicio, p_fim: fim }),
  cancelarAtribuicao: (id: string) => rpc<void>('app_cancelar_atribuicao', { p_id: id }),
  cargaAtribuicoes: (empresa: string | null) => rpc<CargaAtribuicao[]>('app_carga_atribuicoes', { p_empresa: empresa }),
  cargasFuncionarios: (empresa: string | null, data: string) =>
    rpc<CargaFuncionario[]>('app_cargas_funcionarios', { p_empresa: empresa, p_data: data }),
  times: (empresa: string | null) => rpc<TimeEquipe[]>('app_times', { p_empresa: empresa }),
  salvarTime: (id: string | null, empresa: string | null, nome: string, ativo: boolean) =>
    rpc<string>('app_salvar_time', { p_id: id, p_empresa: empresa, p_nome: nome, p_ativo: ativo }),
  timeDefinirMembros: (time: string, tecnicos: string[]) => rpc<void>('app_time_definir_membros', { p_time: time, p_tecnicos: tecnicos }),

  pontoVerificar: (empresa: string) =>
    rpc<{ integra: boolean; conferidas: number; nsr?: number; motivo?: string }>('app_ponto_verificar', { p_empresa: empresa }),

  pendencias: (data: string) => rpc<Pendencias>('app_pendencias', { p_data: data }),
  simularJornada: (hora: string) => rpc<Jornada>('app_simular_jornada', { p_inicio: hora }),

  painelLocais: (data: string) => rpc<PainelLocal[]>('app_painel_locais', { p_data: data }),

  habilidades: () => rpc<Habilidade[]>('app_habilidades'),
  salvarHabilidade: (h: Partial<Habilidade>) => rpc<string>('app_salvar_habilidade', { p: h }),
  tecnicoHabilidades: () => rpc<TecnicoHabilidade[]>('app_tecnico_habilidades'),
  definirHabilidades: (tecnicoId: string, habilidades: { habilidade_id: string; nivel: string; validade?: string | null }[]) =>
    rpc<number>('app_definir_habilidades', { p_tecnico: tecnicoId, p_habilidades: habilidades }),
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

  tiposDocumento: () => rpc<TipoDocumento[]>('app_tipos_documento'),
  salvarTipoDocumento: (d: Partial<TipoDocumento>) => rpc<string>('app_salvar_tipo_documento', { p: d }),
  excluirTipoDocumento: (id: string, forcar = false) =>
    rpc<{ excluido: boolean; nome: string; tecnicos_afetados: number }>('app_excluir_tipo_documento', { p_id: id, p_forcar: forcar }),
  documentosPorTecnico: () => rpc<TecnicoDocumentos[]>('app_documentos_por_tecnico'),
  definirDocumento: (tecnico: string, tipo: string, validade: string | null, documento?: string | null) =>
    rpc<void>('app_definir_documento', { p_tecnico: tecnico, p_tipo: tipo, p_validade: validade, p_documento: documento ?? null }),
  removerDocumentoTecnico: (tecnico: string, tipo: string) =>
    rpc<void>('app_remover_documento_tecnico', { p_tecnico: tecnico, p_tipo: tipo }),

  documentos: (tecnicoId?: string) => rpc<Documento[]>('app_documentos', { p_tecnico: tecnicoId ?? null }),
  registrarDocumento: (d: Record<string, unknown>) => rpc<string>('app_registrar_documento', { p: d }),
  excluirDocumento: (id: string) => rpc<string>('app_excluir_documento', { p_id: id }),

  usuarios: () => rpc<UsuarioPainel[]>('app_usuarios'),
  definirVeSaude: (email: string, valor: boolean) => rpc<void>('app_definir_ve_saude', { p_email: email, p_valor: valor }),
  definirRhFolhas: (email: string, valor: boolean) => rpc<void>('app_definir_rh_folhas', { p_email: email, p_valor: valor }),
  rhFolhasHistorico: () => rpc<{ email: string; valor: boolean; autor: string; em: string }[]>('app_rh_folhas_historico'),
  salvarUsuario: (u: { email: string; nome: string; papel: Papel; ativo: boolean }) =>
    rpc<string>('app_salvar_usuario', { p_email: u.email, p_nome: u.nome, p_papel: u.papel, p_ativo: u.ativo }),
}

/** Envia o arquivo ao Storage privado e registra os metadados. */
export async function enviarDocumento(p: {
  tecnicoId: string; tipoDocumentoId: string | null; arquivo: File; validade: string | null
}): Promise<string> {
  const ext = p.arquivo.name.split('.').pop()?.toLowerCase() ?? 'bin'
  const caminho = `${p.tecnicoId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${ext}`
  const { error } = await supabase.storage.from('documentos')
    .upload(caminho, p.arquivo, { contentType: p.arquivo.type, upsert: false })
  if (error) throw new Error(`Falha no envio do arquivo: ${error.message}`)
  try {
    return await api.registrarDocumento({
      tecnico_id: p.tecnicoId, tipo_documento_id: p.tipoDocumentoId, caminho,
      nome_arquivo: p.arquivo.name, mime: p.arquivo.type,
      tamanho_bytes: p.arquivo.size, validade: p.validade,
    })
  } catch (e) {
    // metadado falhou: nao deixa arquivo orfao no Storage
    await supabase.storage.from('documentos').remove([caminho])
    throw e
  }
}

/** Abre o documento por link assinado de 2 minutos. Todo documento vive no bucket
 *  privado: o vinculo por link externo saiu do sistema na decisao 41 (migration 50). */
export async function abrirDocumento(caminho: string): Promise<string> {
  const { data, error } = await supabase.storage.from('documentos').createSignedUrl(caminho, 120)
  if (error || !data) throw new Error('Não foi possível abrir o documento.')
  return data.signedUrl
}

export async function removerDocumento(id: string): Promise<void> {
  const caminho = await api.excluirDocumento(id)
  if (caminho) await supabase.storage.from('documentos').remove([caminho])
}

/** OCR na nuvem (modo preciso, opcional): so usado se GOOGLE_VISION_KEY estiver cadastrada. */
export async function lerValidadePorOCR(arquivo: File): Promise<{ sugestao: string | null; erro?: string }> {
  const base64 = await new Promise<string>((ok, falha) => {
    const r = new FileReader()
    r.onload = () => ok(String(r.result).split(',')[1] ?? '')
    r.onerror = () => falha(new Error('Não consegui ler o arquivo.'))
    r.readAsDataURL(arquivo)
  })
  const { data: sessao } = await supabase.auth.getSession()
  const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/documento-ocr`
  try {
    const resp = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${sessao.session?.access_token ?? ''}`,
        apikey: import.meta.env.VITE_SUPABASE_ANON_KEY,
      },
      body: JSON.stringify({ base64, mime: arquivo.type }),
      signal: AbortSignal.timeout(30000),
    })
    const r = await resp.json().catch(() => ({}))
    if (!r.ok) return { sugestao: null, erro: r.erro ?? 'OCR indisponível.' }
    return { sugestao: r.sugestao ?? null }
  } catch {
    return { sugestao: null, erro: 'Leitura na nuvem indisponível agora. Informe a validade manualmente.' }
  }
}

export function erroMsg(e: unknown): string {
  return e instanceof Error ? e.message : String(e)
}
