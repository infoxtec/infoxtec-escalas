-- 52. Índices nas chaves estrangeiras apontadas pelo linter do Supabase (unindexed_foreign_keys).
-- Sem eles, apagar ou alterar um tipo de documento ou uma habilidade varre a tabela filha inteira.
-- Só estrutura; nenhuma função muda.

create index if not exists idx_documentos_tipo_documento   on documentos (tipo_documento_id);
create index if not exists idx_tecdoc_tipo_documento       on tecnico_documentos (tipo_documento_id);
create index if not exists idx_techab_habilidade           on tecnico_habilidades (habilidade_id);
create index if not exists idx_tipoativ_doc_tipo_documento on tipo_atividade_documentos (tipo_documento_id);
create index if not exists idx_tipoativ_req_habilidade     on tipo_atividade_requisitos (habilidade_id);
