-- 123: multiempresa F2f-2a, chave composta por conta (revisão de 25/10, docs/revisao-infra-dados-2026-10-25.md).
-- A decisão 108 pede que o próprio banco recuse um registro de uma conta apontando para outro de outra conta, mesmo
-- com bug numa função. A F1 (116) só ligou cada tabela a `contas`; aqui as 70 chaves entre tabelas de conta passam a
-- ser compostas, (conta_id, coluna) → (conta_id, id), com a mesma regra de exclusão (set null só da coluna).
-- Fica de fora a chave de `ponto_justificativas.motivo`: `ponto_motivos` é catálogo da plataforma.
-- Também: o acompanhamento do ponto passa a usar o índice de `momento` (115 ms → 15 ms com um ano simulado).
-- Versão dada à mão, maior que a 122 (regra de numeração até 31/10, CLAUDE.md).
-- Função recriada a partir da definição da homologação de 25/10 (md5 34795c71…).

set local lock_timeout = '5s';

-- 1. chave única (conta_id, id) em cada tabela de origem: é o que a chave composta referencia
alter table interno.cargas_horarias add constraint cargas_horarias_conta_id_uk unique (conta_id, id);
alter table interno.documentos add constraint documentos_conta_id_uk unique (conta_id, id);
alter table interno.empresas add constraint empresas_conta_id_uk unique (conta_id, id);
alter table interno.escalas add constraint escalas_conta_id_uk unique (conta_id, id);
alter table interno.habilidades add constraint habilidades_conta_id_uk unique (conta_id, id);
alter table interno.locais add constraint locais_conta_id_uk unique (conta_id, id);
alter table interno.notificacoes add constraint notificacoes_conta_id_uk unique (conta_id, id);
alter table interno.ponto_abonos add constraint ponto_abonos_conta_id_uk unique (conta_id, id);
alter table interno.ponto_ajustes add constraint ponto_ajustes_conta_id_uk unique (conta_id, id);
alter table interno.ponto_espelhos add constraint ponto_espelhos_conta_id_uk unique (conta_id, id);
alter table interno.ponto_justificativas add constraint ponto_justificativas_conta_id_uk unique (conta_id, id);
alter table interno.ponto_marcacoes add constraint ponto_marcacoes_conta_id_uk unique (conta_id, id);
alter table interno.tecnicos add constraint tecnicos_conta_id_uk unique (conta_id, id);
alter table interno.times add constraint times_conta_id_uk unique (conta_id, id);
alter table interno.tipos_atividade add constraint tipos_atividade_conta_id_uk unique (conta_id, id);
alter table interno.tipos_documento add constraint tipos_documento_conta_id_uk unique (conta_id, id);

-- 2. chave composta no lugar da simples: o filho só aponta para registro da mesma conta.
--    Entra sem conferir (not valid) e é conferida no passo 3, sem travar leitura nem escrita.
alter table interno.carga_aceites drop constraint carga_aceites_carga_id_fkey,
  add constraint carga_aceites_carga_id_conta_fkey foreign key (conta_id, carga_id) references interno.cargas_horarias (conta_id, id) not valid;
alter table interno.carga_atribuicoes drop constraint carga_atribuicoes_carga_id_fkey,
  add constraint carga_atribuicoes_carga_id_conta_fkey foreign key (conta_id, carga_id) references interno.cargas_horarias (conta_id, id) not valid;
alter table interno.tecnico_documentos drop constraint tecnico_documentos_documento_id_fkey,
  add constraint tecnico_documentos_documento_id_conta_fkey foreign key (conta_id, documento_id) references interno.documentos (conta_id, id) on delete set null (documento_id) not valid;
alter table interno.carga_aceites drop constraint carga_aceites_empresa_id_fkey,
  add constraint carga_aceites_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.carga_atribuicoes drop constraint carga_atribuicoes_empresa_id_fkey,
  add constraint carga_atribuicoes_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.cargas_horarias drop constraint cargas_horarias_empresa_id_fkey,
  add constraint cargas_horarias_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.locais drop constraint locais_cliente_empresa_id_fkey,
  add constraint locais_cliente_empresa_id_conta_fkey foreign key (conta_id, cliente_empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_abonos drop constraint ponto_abonos_empresa_id_fkey,
  add constraint ponto_abonos_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_afd_geracoes drop constraint ponto_afd_geracoes_empresa_id_fkey,
  add constraint ponto_afd_geracoes_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_ajustes drop constraint ponto_ajustes_empresa_id_fkey,
  add constraint ponto_ajustes_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_documento_registros drop constraint ponto_documento_registros_empresa_id_fkey,
  add constraint ponto_documento_registros_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_documento_sequencia drop constraint ponto_documento_sequencia_empresa_id_fkey,
  add constraint ponto_documento_sequencia_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_espelho_pdfs drop constraint ponto_espelho_pdfs_empresa_id_fkey,
  add constraint ponto_espelho_pdfs_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_espelho_sequencia drop constraint ponto_espelho_sequencia_empresa_id_fkey,
  add constraint ponto_espelho_sequencia_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_espelhos drop constraint ponto_espelhos_empresa_id_fkey,
  add constraint ponto_espelhos_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_folha_fechamentos drop constraint ponto_folha_fechamentos_empresa_id_fkey,
  add constraint ponto_folha_fechamentos_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_he_autorizacoes drop constraint ponto_he_autorizacoes_empresa_id_fkey,
  add constraint ponto_he_autorizacoes_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_justificativas drop constraint ponto_justificativas_empresa_id_fkey,
  add constraint ponto_justificativas_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_marcacoes drop constraint ponto_marcacoes_empresa_id_fkey,
  add constraint ponto_marcacoes_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.ponto_nsr drop constraint ponto_nsr_empresa_id_fkey,
  add constraint ponto_nsr_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.tecnicos drop constraint tecnicos_empresa_id_fkey,
  add constraint tecnicos_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.times drop constraint times_empresa_id_fkey,
  add constraint times_empresa_id_conta_fkey foreign key (conta_id, empresa_id) references interno.empresas (conta_id, id) not valid;
alter table interno.escala_eventos drop constraint escala_eventos_escala_id_fkey,
  add constraint escala_eventos_escala_id_conta_fkey foreign key (conta_id, escala_id) references interno.escalas (conta_id, id) on delete cascade not valid;
alter table interno.ligacoes drop constraint ligacoes_escala_id_fkey,
  add constraint ligacoes_escala_id_conta_fkey foreign key (conta_id, escala_id) references interno.escalas (conta_id, id) on delete cascade not valid;
alter table interno.notificacoes drop constraint notificacoes_escala_id_fkey,
  add constraint notificacoes_escala_id_conta_fkey foreign key (conta_id, escala_id) references interno.escalas (conta_id, id) on delete cascade not valid;
alter table interno.ocorrencias drop constraint ocorrencias_escala_id_fkey,
  add constraint ocorrencias_escala_id_conta_fkey foreign key (conta_id, escala_id) references interno.escalas (conta_id, id) on delete cascade not valid;
alter table interno.respostas drop constraint respostas_escala_id_fkey,
  add constraint respostas_escala_id_conta_fkey foreign key (conta_id, escala_id) references interno.escalas (conta_id, id) on delete cascade not valid;
alter table interno.tecnico_habilidades drop constraint tecnico_habilidades_habilidade_id_fkey,
  add constraint tecnico_habilidades_habilidade_id_conta_fkey foreign key (conta_id, habilidade_id) references interno.habilidades (conta_id, id) on delete cascade not valid;
alter table interno.tipo_atividade_requisitos drop constraint tipo_atividade_requisitos_habilidade_id_fkey,
  add constraint tipo_atividade_requisitos_habilidade_id_conta_fkey foreign key (conta_id, habilidade_id) references interno.habilidades (conta_id, id) on delete cascade not valid;
alter table interno.escalas drop constraint escalas_local_id_fkey,
  add constraint escalas_local_id_conta_fkey foreign key (conta_id, local_id) references interno.locais (conta_id, id) on delete set null (local_id) not valid;
alter table interno.ponto_marcacoes drop constraint ponto_marcacoes_local_id_fkey,
  add constraint ponto_marcacoes_local_id_conta_fkey foreign key (conta_id, local_id) references interno.locais (conta_id, id) not valid;
alter table interno.respostas drop constraint respostas_notificacao_id_fkey,
  add constraint respostas_notificacao_id_conta_fkey foreign key (conta_id, notificacao_id) references interno.notificacoes (conta_id, id) on delete set null (notificacao_id) not valid;
alter table interno.ponto_abonos drop constraint ponto_abonos_estorno_de_fkey,
  add constraint ponto_abonos_estorno_de_conta_fkey foreign key (conta_id, estorno_de) references interno.ponto_abonos (conta_id, id) not valid;
alter table interno.ponto_justificativas drop constraint ponto_justificativas_abono_fk,
  add constraint ponto_justificativas_abono_fk_conta_fkey foreign key (conta_id, abono_id) references interno.ponto_abonos (conta_id, id) not valid;
alter table interno.ponto_ajustes drop constraint ponto_ajustes_ajuste_id_fkey,
  add constraint ponto_ajustes_ajuste_id_conta_fkey foreign key (conta_id, ajuste_id) references interno.ponto_ajustes (conta_id, id) not valid;
alter table interno.ponto_justificativas drop constraint ponto_justificativas_ajuste_id_fkey,
  add constraint ponto_justificativas_ajuste_id_conta_fkey foreign key (conta_id, ajuste_id) references interno.ponto_ajustes (conta_id, id) not valid;
alter table interno.ponto_espelho_acessos drop constraint ponto_espelho_acessos_espelho_id_fkey,
  add constraint ponto_espelho_acessos_espelho_id_conta_fkey foreign key (conta_id, espelho_id) references interno.ponto_espelhos (conta_id, id) not valid;
alter table interno.ponto_espelho_pdfs drop constraint ponto_espelho_pdfs_espelho_id_fkey,
  add constraint ponto_espelho_pdfs_espelho_id_conta_fkey foreign key (conta_id, espelho_id) references interno.ponto_espelhos (conta_id, id) not valid;
alter table interno.ponto_folha_fechamentos drop constraint ponto_folha_fechamentos_espelho_id_fkey,
  add constraint ponto_folha_fechamentos_espelho_id_conta_fkey foreign key (conta_id, espelho_id) references interno.ponto_espelhos (conta_id, id) not valid;
alter table interno.ponto_abonos drop constraint ponto_abonos_justificativa_id_fkey,
  add constraint ponto_abonos_justificativa_id_conta_fkey foreign key (conta_id, justificativa_id) references interno.ponto_justificativas (conta_id, id) not valid;
alter table interno.ponto_ajustes drop constraint ponto_ajustes_justificativa_id_fkey,
  add constraint ponto_ajustes_justificativa_id_conta_fkey foreign key (conta_id, justificativa_id) references interno.ponto_justificativas (conta_id, id) not valid;
alter table interno.ponto_justificativa_anexos drop constraint ponto_justificativa_anexos_justificativa_id_fkey,
  add constraint ponto_justificativa_anexos_justificativa_id_conta_fkey foreign key (conta_id, justificativa_id) references interno.ponto_justificativas (conta_id, id) not valid;
alter table interno.ponto_ajustes drop constraint ponto_ajustes_marcacao_id_fkey,
  add constraint ponto_ajustes_marcacao_id_conta_fkey foreign key (conta_id, marcacao_id) references interno.ponto_marcacoes (conta_id, id) not valid;
alter table interno.ponto_he_autorizacoes drop constraint ponto_he_autorizacoes_marcacao_id_fkey,
  add constraint ponto_he_autorizacoes_marcacao_id_conta_fkey foreign key (conta_id, marcacao_id) references interno.ponto_marcacoes (conta_id, id) not valid;
alter table interno.carga_atribuicoes drop constraint carga_atribuicoes_tecnico_id_fkey,
  add constraint carga_atribuicoes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.documentos drop constraint documentos_tecnico_id_fkey,
  add constraint documentos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.escalas drop constraint escalas_tecnico_id_fkey,
  add constraint escalas_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete restrict not valid;
alter table interno.ligacoes drop constraint ligacoes_tecnico_id_fkey,
  add constraint ligacoes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.ponto_abonos drop constraint ponto_abonos_tecnico_id_fkey,
  add constraint ponto_abonos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_acessos drop constraint ponto_acessos_tecnico_id_fkey,
  add constraint ponto_acessos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.ponto_ajustes drop constraint ponto_ajustes_tecnico_id_fkey,
  add constraint ponto_ajustes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_ciencias drop constraint ponto_ciencias_tecnico_id_fkey,
  add constraint ponto_ciencias_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.ponto_codigos drop constraint ponto_codigos_tecnico_id_fkey,
  add constraint ponto_codigos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.ponto_conversas drop constraint ponto_conversas_tecnico_id_fkey,
  add constraint ponto_conversas_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.ponto_espelhos drop constraint ponto_espelhos_tecnico_id_fkey,
  add constraint ponto_espelhos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_folha_fechamentos drop constraint ponto_folha_fechamentos_tecnico_id_fkey,
  add constraint ponto_folha_fechamentos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_he_autorizacoes drop constraint ponto_he_autorizacoes_tecnico_id_fkey,
  add constraint ponto_he_autorizacoes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_justificativas drop constraint ponto_justificativas_tecnico_id_fkey,
  add constraint ponto_justificativas_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_marcacoes drop constraint ponto_marcacoes_tecnico_id_fkey,
  add constraint ponto_marcacoes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) not valid;
alter table interno.ponto_sessoes drop constraint ponto_sessoes_tecnico_id_fkey,
  add constraint ponto_sessoes_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.tecnico_documentos drop constraint tecnico_documentos_tecnico_id_fkey,
  add constraint tecnico_documentos_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.tecnico_habilidades drop constraint tecnico_habilidades_tecnico_id_fkey,
  add constraint tecnico_habilidades_tecnico_id_conta_fkey foreign key (conta_id, tecnico_id) references interno.tecnicos (conta_id, id) on delete cascade not valid;
alter table interno.carga_atribuicoes drop constraint carga_atribuicoes_time_id_fkey,
  add constraint carga_atribuicoes_time_id_conta_fkey foreign key (conta_id, time_id) references interno.times (conta_id, id) not valid;
alter table interno.tecnicos drop constraint tecnicos_time_id_fkey,
  add constraint tecnicos_time_id_conta_fkey foreign key (conta_id, time_id) references interno.times (conta_id, id) not valid;
alter table interno.escalas drop constraint escalas_tipo_atividade_id_fkey,
  add constraint escalas_tipo_atividade_id_conta_fkey foreign key (conta_id, tipo_atividade_id) references interno.tipos_atividade (conta_id, id) on delete set null (tipo_atividade_id) not valid;
alter table interno.tipo_atividade_documentos drop constraint tipo_atividade_documentos_tipo_id_fkey,
  add constraint tipo_atividade_documentos_tipo_id_conta_fkey foreign key (conta_id, tipo_id) references interno.tipos_atividade (conta_id, id) on delete cascade not valid;
alter table interno.tipo_atividade_requisitos drop constraint tipo_atividade_requisitos_tipo_id_fkey,
  add constraint tipo_atividade_requisitos_tipo_id_conta_fkey foreign key (conta_id, tipo_id) references interno.tipos_atividade (conta_id, id) on delete cascade not valid;
alter table interno.documentos drop constraint documentos_tipo_documento_id_fkey,
  add constraint documentos_tipo_documento_id_conta_fkey foreign key (conta_id, tipo_documento_id) references interno.tipos_documento (conta_id, id) on delete set null (tipo_documento_id) not valid;
alter table interno.tecnico_documentos drop constraint tecnico_documentos_tipo_documento_id_fkey,
  add constraint tecnico_documentos_tipo_documento_id_conta_fkey foreign key (conta_id, tipo_documento_id) references interno.tipos_documento (conta_id, id) on delete cascade not valid;
alter table interno.tipo_atividade_documentos drop constraint tipo_atividade_documentos_tipo_documento_id_fkey,
  add constraint tipo_atividade_documentos_tipo_documento_id_conta_fkey foreign key (conta_id, tipo_documento_id) references interno.tipos_documento (conta_id, id) on delete cascade not valid;

-- 3. conferência das chaves (share update exclusive: leitura e escrita continuam)
alter table interno.carga_aceites validate constraint carga_aceites_carga_id_conta_fkey;
alter table interno.carga_atribuicoes validate constraint carga_atribuicoes_carga_id_conta_fkey;
alter table interno.tecnico_documentos validate constraint tecnico_documentos_documento_id_conta_fkey;
alter table interno.carga_aceites validate constraint carga_aceites_empresa_id_conta_fkey;
alter table interno.carga_atribuicoes validate constraint carga_atribuicoes_empresa_id_conta_fkey;
alter table interno.cargas_horarias validate constraint cargas_horarias_empresa_id_conta_fkey;
alter table interno.locais validate constraint locais_cliente_empresa_id_conta_fkey;
alter table interno.ponto_abonos validate constraint ponto_abonos_empresa_id_conta_fkey;
alter table interno.ponto_afd_geracoes validate constraint ponto_afd_geracoes_empresa_id_conta_fkey;
alter table interno.ponto_ajustes validate constraint ponto_ajustes_empresa_id_conta_fkey;
alter table interno.ponto_documento_registros validate constraint ponto_documento_registros_empresa_id_conta_fkey;
alter table interno.ponto_documento_sequencia validate constraint ponto_documento_sequencia_empresa_id_conta_fkey;
alter table interno.ponto_espelho_pdfs validate constraint ponto_espelho_pdfs_empresa_id_conta_fkey;
alter table interno.ponto_espelho_sequencia validate constraint ponto_espelho_sequencia_empresa_id_conta_fkey;
alter table interno.ponto_espelhos validate constraint ponto_espelhos_empresa_id_conta_fkey;
alter table interno.ponto_folha_fechamentos validate constraint ponto_folha_fechamentos_empresa_id_conta_fkey;
alter table interno.ponto_he_autorizacoes validate constraint ponto_he_autorizacoes_empresa_id_conta_fkey;
alter table interno.ponto_justificativas validate constraint ponto_justificativas_empresa_id_conta_fkey;
alter table interno.ponto_marcacoes validate constraint ponto_marcacoes_empresa_id_conta_fkey;
alter table interno.ponto_nsr validate constraint ponto_nsr_empresa_id_conta_fkey;
alter table interno.tecnicos validate constraint tecnicos_empresa_id_conta_fkey;
alter table interno.times validate constraint times_empresa_id_conta_fkey;
alter table interno.escala_eventos validate constraint escala_eventos_escala_id_conta_fkey;
alter table interno.ligacoes validate constraint ligacoes_escala_id_conta_fkey;
alter table interno.notificacoes validate constraint notificacoes_escala_id_conta_fkey;
alter table interno.ocorrencias validate constraint ocorrencias_escala_id_conta_fkey;
alter table interno.respostas validate constraint respostas_escala_id_conta_fkey;
alter table interno.tecnico_habilidades validate constraint tecnico_habilidades_habilidade_id_conta_fkey;
alter table interno.tipo_atividade_requisitos validate constraint tipo_atividade_requisitos_habilidade_id_conta_fkey;
alter table interno.escalas validate constraint escalas_local_id_conta_fkey;
alter table interno.ponto_marcacoes validate constraint ponto_marcacoes_local_id_conta_fkey;
alter table interno.respostas validate constraint respostas_notificacao_id_conta_fkey;
alter table interno.ponto_abonos validate constraint ponto_abonos_estorno_de_conta_fkey;
alter table interno.ponto_justificativas validate constraint ponto_justificativas_abono_fk_conta_fkey;
alter table interno.ponto_ajustes validate constraint ponto_ajustes_ajuste_id_conta_fkey;
alter table interno.ponto_justificativas validate constraint ponto_justificativas_ajuste_id_conta_fkey;
alter table interno.ponto_espelho_acessos validate constraint ponto_espelho_acessos_espelho_id_conta_fkey;
alter table interno.ponto_espelho_pdfs validate constraint ponto_espelho_pdfs_espelho_id_conta_fkey;
alter table interno.ponto_folha_fechamentos validate constraint ponto_folha_fechamentos_espelho_id_conta_fkey;
alter table interno.ponto_abonos validate constraint ponto_abonos_justificativa_id_conta_fkey;
alter table interno.ponto_ajustes validate constraint ponto_ajustes_justificativa_id_conta_fkey;
alter table interno.ponto_justificativa_anexos validate constraint ponto_justificativa_anexos_justificativa_id_conta_fkey;
alter table interno.ponto_ajustes validate constraint ponto_ajustes_marcacao_id_conta_fkey;
alter table interno.ponto_he_autorizacoes validate constraint ponto_he_autorizacoes_marcacao_id_conta_fkey;
alter table interno.carga_atribuicoes validate constraint carga_atribuicoes_tecnico_id_conta_fkey;
alter table interno.documentos validate constraint documentos_tecnico_id_conta_fkey;
alter table interno.escalas validate constraint escalas_tecnico_id_conta_fkey;
alter table interno.ligacoes validate constraint ligacoes_tecnico_id_conta_fkey;
alter table interno.ponto_abonos validate constraint ponto_abonos_tecnico_id_conta_fkey;
alter table interno.ponto_acessos validate constraint ponto_acessos_tecnico_id_conta_fkey;
alter table interno.ponto_ajustes validate constraint ponto_ajustes_tecnico_id_conta_fkey;
alter table interno.ponto_ciencias validate constraint ponto_ciencias_tecnico_id_conta_fkey;
alter table interno.ponto_codigos validate constraint ponto_codigos_tecnico_id_conta_fkey;
alter table interno.ponto_conversas validate constraint ponto_conversas_tecnico_id_conta_fkey;
alter table interno.ponto_espelhos validate constraint ponto_espelhos_tecnico_id_conta_fkey;
alter table interno.ponto_folha_fechamentos validate constraint ponto_folha_fechamentos_tecnico_id_conta_fkey;
alter table interno.ponto_he_autorizacoes validate constraint ponto_he_autorizacoes_tecnico_id_conta_fkey;
alter table interno.ponto_justificativas validate constraint ponto_justificativas_tecnico_id_conta_fkey;
alter table interno.ponto_marcacoes validate constraint ponto_marcacoes_tecnico_id_conta_fkey;
alter table interno.ponto_sessoes validate constraint ponto_sessoes_tecnico_id_conta_fkey;
alter table interno.tecnico_documentos validate constraint tecnico_documentos_tecnico_id_conta_fkey;
alter table interno.tecnico_habilidades validate constraint tecnico_habilidades_tecnico_id_conta_fkey;
alter table interno.carga_atribuicoes validate constraint carga_atribuicoes_time_id_conta_fkey;
alter table interno.tecnicos validate constraint tecnicos_time_id_conta_fkey;
alter table interno.escalas validate constraint escalas_tipo_atividade_id_conta_fkey;
alter table interno.tipo_atividade_documentos validate constraint tipo_atividade_documentos_tipo_id_conta_fkey;
alter table interno.tipo_atividade_requisitos validate constraint tipo_atividade_requisitos_tipo_id_conta_fkey;
alter table interno.documentos validate constraint documentos_tipo_documento_id_conta_fkey;
alter table interno.tecnico_documentos validate constraint tecnico_documentos_tipo_documento_id_conta_fkey;
alter table interno.tipo_atividade_documentos validate constraint tipo_atividade_documentos_tipo_documento_id_conta_fkey;

-- acompanhamento do ponto com faixa de índice -----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_ponto_acompanhamento(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, nsr bigint, empresa text, tecnico_id uuid, tecnico text, momento timestamp with time zone, data text, hora text, tipo text, canal text, local text, distancia_m integer, dentro_area boolean, login_origem text, gestor text, autenticacao text, latitude numeric, longitude numeric, ajustada boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_leitura boolean;
  v_conta   uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_leitura := coalesce(fn_papel_na_conta(), 'leitura') = 'leitura';   -- sem papel na conta, máscara fechada
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select m.id, m.nsr, coalesce(e.nome_fantasia, e.razao_social), m.tecnico_id, t.nome, m.momento,
           to_char(m.momento at time zone e.fuso, 'DD/MM/YYYY'), to_char(m.momento at time zone e.fuso, 'HH24:MI:SS'),
           m.tipo, m.canal, l.nome, m.distancia_m, m.dentro_area,
           coalesce(m.origem ->> 'login_origem', case when m.canal = 'app' then 'whatsapp' end),
           case when v_leitura then null else m.origem ->> 'gestor' end,
           left(m.hash, 16),
           case when v_leitura then null else m.latitude end,
           case when v_leitura then null else m.longitude end,
           exists (select 1 from ponto_ajustes a where a.marcacao_id = m.id)
      from ponto_marcacoes m
      join tecnicos t on t.id = m.tecnico_id
      join empresas e on e.id = m.empresa_id
      left join locais l on l.id = m.local_id and l.conta_id = m.conta_id
     where (m.momento at time zone e.fuso)::date between p_de and p_ate
       -- faixa larga em momento (um dia a mais de cada lado cobre qualquer fuso) para usar o índice
       and m.momento >= (p_de - 1)::timestamptz and m.momento < (p_ate + 2)::timestamptz
       and (p_tecnico is null or m.tecnico_id = p_tecnico)
       and m.conta_id = v_conta
     order by m.momento desc;
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
