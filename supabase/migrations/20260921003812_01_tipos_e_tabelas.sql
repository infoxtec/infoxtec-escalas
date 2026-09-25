-- 01 | Tipos (enums) e tabelas do dominio + mensageria + auditoria

create type escala_status as enum (
  'rascunho','agendada','notificada','confirmada','recusada',
  'reagendada','em_execucao','concluida','cancelada'
);

create type envio_status as enum (
  'enfileirada','enviada','entregue','lida','falha'
);

create type notificacao_tipo as enum ('primeira','lembrete','reenvio_falha');

create type resposta_tipo as enum ('confirmacao','problema','motivo','texto_livre');

create type ocorrencia_motivo as enum (
  'saude','falta_material','conflito_agenda','transporte','outro'
);

create type ocorrencia_status as enum ('aberta','em_tratativa','resolvida');

create table tecnicos (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null,
  telefone_e164  text not null unique
                 check (telefone_e164 ~ '^[1-9][0-9]{9,14}$'),
  funcao         text,
  equipe         text,
  is_supervisor  boolean not null default false,
  opt_in         boolean not null default false,
  opt_in_em      timestamptz,
  ativo          boolean not null default true,
  created_at     timestamptz not null default now()
);

comment on column tecnicos.is_supervisor is
  'Recebe os alertas de escalonamento. Marque pelo menos um.';

create table locais (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null,
  cliente          text,
  endereco         text,
  cidade           text default 'Salvador',
  referencia       text,
  link_maps        text,
  contato_local    text,
  telefone_contato text,
  ativo            boolean not null default true,
  created_at       timestamptz not null default now()
);

create table escalas (
  id                    uuid primary key default gen_random_uuid(),
  tecnico_id            uuid not null references tecnicos(id) on delete restrict,
  local_id              uuid references locais(id) on delete set null,
  data_servico          date not null,
  hora_inicio           time not null,
  duracao_prevista_min  int default 240,
  descricao_tarefa      text not null,
  prioridade            text not null default 'normal'
                        check (prioridade in ('baixa','normal','urgente')),
  status                escala_status not null default 'rascunho',
  confirmada_em         timestamptz,
  supervisor_avisado_em timestamptz,
  observacao_gestor     text,
  criado_por            text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique (tecnico_id, data_servico, hora_inicio)
);

create table notificacoes (
  id             uuid primary key default gen_random_uuid(),
  escala_id      uuid not null references escalas(id) on delete cascade,
  tipo           notificacao_tipo not null default 'primeira',
  tentativa      int not null default 1,
  wa_message_id  text unique,
  template_nome  text,
  status_envio   envio_status not null default 'enfileirada',
  erro_codigo    text,
  erro_mensagem  text,
  payload_envio  jsonb,
  enviada_em     timestamptz,
  entregue_em    timestamptz,
  lida_em        timestamptz,
  created_at     timestamptz not null default now()
);

create table respostas (
  id              uuid primary key default gen_random_uuid(),
  notificacao_id  uuid references notificacoes(id) on delete set null,
  escala_id       uuid not null references escalas(id) on delete cascade,
  wa_message_id   text unique,
  wa_context_id   text,
  tipo            resposta_tipo not null,
  button_payload  text,
  texto_livre     text,
  recebida_em     timestamptz not null default now()
);

create table ocorrencias (
  id           uuid primary key default gen_random_uuid(),
  escala_id    uuid not null references escalas(id) on delete cascade,
  motivo       ocorrencia_motivo,
  detalhe      text,
  status       ocorrencia_status not null default 'aberta',
  resolvida_em timestamptz,
  created_at   timestamptz not null default now()
);

create table escala_eventos (
  id              uuid primary key default gen_random_uuid(),
  escala_id       uuid not null references escalas(id) on delete cascade,
  evento          text not null,
  status_anterior escala_status,
  status_novo     escala_status,
  ator            text not null default 'sistema',
  detalhe         jsonb,
  created_at      timestamptz not null default now()
);

create table config (
  chave     text primary key,
  valor     text not null,
  descricao text
);
