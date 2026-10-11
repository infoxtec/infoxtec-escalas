-- Migration 68 (11/10/2026): justificativa com documento — 084 entrega 3, E2 (decisões 55, 56, 58, 59).
--
-- Saúde, Família e Convocação passam a valer pelo app do funcionário (aba Ajuste), com a foto ou o PDF do
-- documento obrigatório. Pelo WhatsApp essas opções orientam a usar o app (receber mídia pela Evolution
-- é a E2b). Regras:
--   * Cofre (decisão 56): o documento é cifrado no banco (pgcrypto, AES-256, chave no Vault — nunca no
--     repositório nem no navegador), em tabela com RLS e sem políticas. Sem Storage, sem chave secreta
--     nova, sem OCR, sem CID. A chave precisa ficar guardada também fora do Supabase (backup).
--   * Quem vê o documento e o motivo de saúde: usuário do painel com "vê atestados" (painel_usuarios.ve_saude),
--     dado por nome pelo admin. Só ele decide pedido de saúde. Cada visualização fica registrada.
--     O papel leitura nunca vê. O documento só é mostrado no painel (sem baixar nem imprimir).
--   * Limite legal (ponto_motivos) alerta e nunca bloqueia (decisão 55); atestado fora de 48 h é sinalizado.
--   * Aprovado: abono do período (dias inteiros ou horário), nunca marcação.
--   * Revisão do seguranca (11/10): código do motivo de saúde mascarado para quem não vê; pedido com
--     documento (saúde, família, convocação) só é decidido por quem tem "vê atestados e documentos";
--     foto/arquivo mandado pelo WhatsApp não fica no log do webhook e o funcionário é orientado a usar o
--     app; registro de acesso independente do anexo e descarte controlado (enviado por engano, pedido do
--     titular); histórico de quem deu a permissão.

-- Permissão "vê atestados" -----------------------------------------------------------------------------
alter table painel_usuarios add column if not exists ve_saude boolean not null default false;
comment on column painel_usuarios.ve_saude is 'Vê atestados e documentos: decide pedidos com documento, vê motivo de saúde e abre o cofre (decisão 56). Dado por nome pelo admin.';

create or replace function fn_ve_saude(p_email text)
returns boolean language sql stable set search_path = public, extensions as $$
  select coalesce((select ve_saude from painel_usuarios where email = lower(trim(p_email)) and ativo
                    and papel in ('admin', 'gestor')), false)
$$;

create or replace function app_meu_acesso()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
  select jsonb_build_object(
    'email', app_email(),
    'papel', (select papel from painel_usuarios where email = app_email() and ativo),
    'nome',  (select nome  from painel_usuarios where email = app_email()),
    've_saude', fn_ve_saude(app_email())
  )
$function$;

create table if not exists painel_ve_saude_log (
  id     bigint generated always as identity primary key,
  email  text not null,
  valor  boolean not null,
  autor  text not null,
  em     timestamptz not null default now()
);
comment on table painel_ve_saude_log is 'Quem deu ou tirou "vê atestados e documentos", para quem e quando (prestação de contas, LGPD art. 37). Só inclusão.';
alter table painel_ve_saude_log enable row level security;
create or replace trigger trg_painel_ve_saude_log_imutavel before update or delete on painel_ve_saude_log
  for each row execute function fn_ponto_imutavel();

create or replace function app_definir_ve_saude(p_email text, p_valor boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin']);
  v_papel text;
begin
  select papel into v_papel from painel_usuarios where email = lower(trim(p_email));
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if p_valor and v_papel not in ('admin', 'gestor') then raise exception 'Só admin ou gestor pode ver atestados.'; end if;
  update painel_usuarios set ve_saude = p_valor, updated_at = now() where email = lower(trim(p_email));
  insert into painel_ve_saude_log (email, valor, autor) values (lower(trim(p_email)), p_valor, v_email);
end $$;

create or replace function app_ve_saude_historico()
returns table (email text, valor boolean, autor text, em text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin']);
  return query select l.email, l.valor, l.autor, to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')
                 from painel_ve_saude_log l order by l.id desc limit 100;
end $$;

-- Chave do cofre: gerada no próprio banco, guardada no Vault --------------------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'COFRE_PONTO') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'COFRE_PONTO',
                                'Chave do cofre de documentos do ponto (decisão 56). Guardar cópia fora do Supabase.');
  end if;
end $$;

create or replace function fn_ponto_cofre_cifrar(p_dados bytea)
returns bytea language plpgsql volatile set search_path = public, extensions as $$
declare v_chave text := fn_segredo('COFRE_PONTO');
begin
  if coalesce(v_chave, '') = '' then raise exception 'Cofre sem chave.'; end if;
  return extensions.pgp_sym_encrypt_bytea(p_dados, v_chave, 'cipher-algo=aes256, compress-algo=0');
end $$;

create or replace function fn_ponto_cofre_decifrar(p_cifrado bytea)
returns bytea language plpgsql stable set search_path = public, extensions as $$
declare v_chave text := fn_segredo('COFRE_PONTO');
begin
  if coalesce(v_chave, '') = '' then raise exception 'Cofre sem chave.'; end if;
  return extensions.pgp_sym_decrypt_bytea(p_cifrado, v_chave);
end $$;

-- Pedido com período de dias e alerta de limite ------------------------------------------------------
alter table ponto_justificativas add column if not exists data_fim date;
alter table ponto_justificativas add column if not exists alerta_limite text;
alter table ponto_justificativas drop constraint if exists ponto_justificativas_data_fim_ck;
alter table ponto_justificativas add constraint ponto_justificativas_data_fim_ck check (data_fim is null or data_fim >= data);

create or replace function fn_ponto_justificativa_guarda()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if (new.empresa_id, new.tecnico_id, new.motivo, new.data, new.data_fim, new.tipo_marcacao, new.hora, new.hora_ini, new.hora_fim,
      new.canal, new.created_at, new.numero, new.alerta_limite)
     is distinct from (old.empresa_id, old.tecnico_id, old.motivo, old.data, old.data_fim, old.tipo_marcacao, old.hora, old.hora_ini, old.hora_fim,
      old.canal, old.created_at, old.numero, old.alerta_limite)
     or (old.status <> 'pendente' and (new.status, new.decidido_por, new.decidido_em, new.ajuste_id, new.abono_id)
          is distinct from (old.status, old.decidido_por, old.decidido_em, old.ajuste_id, old.abono_id)) then
    raise exception 'Pedido de ajuste decidido não muda (só a anonimização do texto livre ao fim da guarda).';
  end if;
  return new;
end $$;

-- Documento cifrado (cofre) e registro de cada visualização ------------------------------------------
create table if not exists ponto_justificativa_anexos (
  id               uuid primary key default gen_random_uuid(),
  justificativa_id uuid not null references ponto_justificativas(id),
  tipo             text not null check (tipo in ('image/jpeg', 'image/png', 'application/pdf')),
  tamanho          int not null check (tamanho between 1 and 5242880),
  sha256           text not null,
  conteudo         bytea not null,
  chave_versao     int not null default 1,
  created_at       timestamptz not null default now()
);
comment on table ponto_justificativa_anexos is 'Cofre: documento da justificativa cifrado (AES-256, chave no Vault). Só visualização no painel por quem tem ve_saude (decisão 56).';
alter table ponto_justificativa_anexos enable row level security;
create index if not exists ponto_justificativa_anexos_just_idx on ponto_justificativa_anexos (justificativa_id);
create or replace trigger trg_ponto_anexos_imutavel before update on ponto_justificativa_anexos
  for each row execute function fn_ponto_imutavel();

-- registro de acesso não depende do anexo: o anexo pode ser descartado e o histórico fica
create table if not exists ponto_anexo_acessos (
  id               bigint generated always as identity primary key,
  anexo_id         uuid not null,
  justificativa_id uuid not null,
  sha256           text not null,
  email            text not null,
  em               timestamptz not null default now()
);
comment on table ponto_anexo_acessos is 'Quem viu cada documento do cofre e quando (decisão 56). Só inclusão.';
alter table ponto_anexo_acessos enable row level security;
create index if not exists ponto_anexo_acessos_anexo_idx on ponto_anexo_acessos (anexo_id);
create or replace trigger trg_ponto_anexo_acessos_imutavel before update or delete on ponto_anexo_acessos
  for each row execute function fn_ponto_imutavel();

-- Descarte controlado (enviado por engano, pedido do titular, fim da guarda): o documento sai, a marca fica
create table if not exists ponto_anexos_descartados (
  id               bigint generated always as identity primary key,
  anexo_id         uuid not null,
  justificativa_id uuid not null,
  sha256           text not null,
  motivo           text not null check (length(trim(motivo)) between 10 and 500),
  autor            text not null,
  em               timestamptz not null default now()
);
comment on table ponto_anexos_descartados is 'Marca de documento do cofre descartado (quem, quando, por quê). Só inclusão.';
alter table ponto_anexos_descartados enable row level security;
create or replace trigger trg_ponto_anexos_descartados_imutavel before update or delete on ponto_anexos_descartados
  for each row execute function fn_ponto_imutavel();

create or replace function fn_ponto_anexo_descartar(p_anexo uuid, p_motivo text, p_autor text)
returns void language plpgsql volatile set search_path = public, extensions as $$
declare a record;
begin
  select id, justificativa_id, sha256 into a from ponto_justificativa_anexos where id = p_anexo;
  if not found then raise exception 'Documento não encontrado.'; end if;
  insert into ponto_anexos_descartados (anexo_id, justificativa_id, sha256, motivo, autor)
  values (a.id, a.justificativa_id, a.sha256, trim(p_motivo), p_autor);
  delete from ponto_justificativa_anexos where id = p_anexo;
end $$;

create or replace function app_ponto_anexo_descartar(p_anexo uuid, p_motivo text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_email text := app_exigir(array['admin','gestor']);
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos descarta documentos.'; end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do descarte (10 a 500 letras).'; end if;
  perform fn_ponto_anexo_descartar(p_anexo, p_motivo, v_email);
end $$;

-- Motivos da E2 passam a valer
update ponto_motivos set ativo = true where grupo in ('saude', 'familia', 'convocacao');

-- Texto do pedido: "Saída às 17:05", "das 08:00 às 08:30", "11/10 a 13/10", "dia inteiro"
create or replace function fn_ponto_pedido_detalhe(p_motivo text, p_tipo text, p_hora time, p_ini time, p_fim time, p_data date, p_data_fim date)
returns text language sql immutable set search_path = public, extensions as $$
  select case
    when p_motivo in ('esqueci_marcar', 'falha_registro') then fn_ponto_rotulo(p_tipo) || ' às ' || to_char(p_hora, 'HH24:MI')
    when p_ini is not null then 'das ' || to_char(p_ini, 'HH24:MI') || ' às ' || to_char(p_fim, 'HH24:MI')
    when p_data_fim is not null and p_data_fim > p_data then to_char(p_data, 'DD/MM') || ' a ' || to_char(p_data_fim, 'DD/MM')
       || ' (' || (p_data_fim - p_data + 1) || ' dias)'
    else 'dia inteiro' end
$$;

-- Limite legal já usado (alerta, nunca bloqueia) ------------------------------------------------------
create or replace function fn_ponto_limite_alerta(p_tecnico uuid, p_motivo text, p_data date, p_data_fim date)
returns text language plpgsql stable set search_path = public, extensions as $$
declare
  m       record;
  v_pedido numeric;
  v_usado numeric;
  v_desde date;
begin
  select * into m from ponto_motivos where codigo = p_motivo;
  if not found or m.quantidade is null then return null; end if;
  v_pedido := case when m.unidade = 'consultas' then 1 else coalesce(p_data_fim, p_data) - p_data + 1 end;
  v_desde := case m.janela when '12_meses' then p_data - 365 when 'ano' then date_trunc('year', p_data)::date
                           when 'gestacao' then p_data - 300 else null end;
  if v_desde is null then
    v_usado := 0;   -- por evento: compara só o próprio pedido
  else
    select coalesce(sum(case when m.unidade = 'consultas' then 1 else coalesce(j.data_fim, j.data) - j.data + 1 end), 0)
      into v_usado from ponto_justificativas j
     where j.tecnico_id = p_tecnico and j.motivo = p_motivo and j.status in ('aprovada', 'pendente')
       and j.data >= v_desde and j.data <= p_data;
  end if;
  if v_usado + v_pedido > m.quantidade then
    return 'A lei garante ' || m.quantidade || ' ' || case m.unidade when 'consultas' then 'consultas' else 'dias' end
      || case m.janela when '12_meses' then ' a cada 12 meses' when 'ano' then ' por ano' when 'gestacao' then ' por gestação'
                       else ' por ocorrência' end
      || ' (' || m.base_legal || '). Já usado: ' || v_usado || '; pedido: ' || v_pedido || '. O gestor decide se abona.';
  end if;
  return null;
end $$;

-- Cria o pedido (app e WhatsApp). Recriada com o período de dias (data_fim) e o alerta de limite ------
drop function if exists fn_ponto_justificativa_criar(uuid, text, date, text, time, time, time, text, text);
create function fn_ponto_justificativa_criar(p_tecnico uuid, p_motivo text, p_data date,
  p_tipo_marcacao text, p_hora time, p_hora_ini time, p_hora_fim time, p_observacao text, p_canal text,
  p_data_fim date default null)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_tec    record;
  v_mot    record;
  v_hoje   date;
  v_id     uuid;
  v_num    bigint;
  v_obs    text := nullif(trim(coalesce(p_observacao, '')), '');
  v_fim    date;
  v_alerta text;
begin
  select t.id, t.nome, t.empresa_id, t.ativo, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found or not v_tec.ativo or v_tec.empresa_id is null then raise exception 'Funcionário sem ponto cadastrado.'; end if;
  select * into v_mot from ponto_motivos where codigo = p_motivo and ativo;
  if not found then raise exception 'Escolha um motivo válido.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Informe um dia até hoje.'; end if;
  if p_data < v_hoje - 62 then raise exception 'Pedido só para os últimos 62 dias.'; end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'Observação com no máximo 500 letras.'; end if;

  if p_motivo in ('esqueci_marcar', 'falha_registro') then
    if p_tipo_marcacao is null or p_tipo_marcacao not in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he') then
      raise exception 'Escolha a marcação que ficou faltando.';
    end if;
    if p_hora is null then raise exception 'Informe o horário da marcação.'; end if;
    if (p_data + p_hora) at time zone v_tec.fuso > now() then raise exception 'O horário ainda não chegou.'; end if;
  elsif p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then
    if p_hora_ini is null or p_hora_fim is null or p_hora_ini >= p_hora_fim then
      raise exception 'Informe o período: das ... às ... (o início antes do fim).';
    end if;
    if p_motivo = 'atraso_saida' and (p_data + p_hora_fim) at time zone v_tec.fuso > now() then
      raise exception 'O horário ainda não chegou.';
    end if;
  else
    -- falta de dias inteiros: o atestado pode cobrir dias seguintes (até 30 dias no pedido)
    v_fim := coalesce(p_data_fim, p_data);
    if v_fim < p_data then raise exception 'O último dia vem depois do primeiro.'; end if;
    if v_fim - p_data > 30 then raise exception 'Pedido de até 31 dias. Acima de 15 dias de atestado, o caso vai ao INSS: fale com o gestor.'; end if;
    if v_fim > v_hoje + 30 then raise exception 'O último dia está longe demais.'; end if;
  end if;

  if exists (select 1 from ponto_justificativas j where j.tecnico_id = p_tecnico and j.status = 'pendente'
              and j.motivo = p_motivo and j.data = p_data and j.data_fim is not distinct from v_fim
              and j.tipo_marcacao is not distinct from p_tipo_marcacao and j.hora is not distinct from p_hora
              and j.hora_ini is not distinct from p_hora_ini and j.hora_fim is not distinct from p_hora_fim) then
    raise exception 'Já existe um pedido igual em análise.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and status = 'pendente') >= 10 then
    raise exception 'Você já tem 10 pedidos em análise. Aguarde a resposta do gestor.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'Limite de 5 pedidos em 24 horas. Fale com o seu gestor.';
  end if;

  v_alerta := fn_ponto_limite_alerta(p_tecnico, p_motivo, p_data, v_fim);
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, data_fim, tipo_marcacao, hora, hora_ini, hora_fim,
                                    observacao, canal, alerta_limite)
  values (v_tec.empresa_id, p_tecnico, p_motivo, p_data, v_fim,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_tipo_marcacao end,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_hora end,
          case when p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then p_hora_ini end,
          case when p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then p_hora_fim end,
          v_obs, p_canal, v_alerta)
  returning id, numero into v_id, v_num;

  -- supervisores: no máximo um aviso por funcionário por hora, só com o primeiro nome (nunca o motivo)
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_pedido_' || p_tecnico || '_' || to_char(now(), 'HH24'), current_date, now(), true,
          jsonb_build_object('tecnico', p_tecnico))
  on conflict do nothing;
  if found then
    perform fn_ponto_avisar_supervisores(p_tecnico,
      '📝 *Ponto · ' || split_part(trim(v_tec.nome), ' ', 1) || '*: pedido de ajuste nº ' || v_num
      || ' (' || to_char(p_data, 'DD/MM') || '). Veja em Registro de Ponto › Ajustes.');
  end if;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'motivo', v_mot.nome, 'data', to_char(p_data, 'DD/MM/YYYY'),
    'detalhe', fn_ponto_pedido_detalhe(p_motivo, p_tipo_marcacao, p_hora, p_hora_ini, p_hora_fim, p_data, v_fim),
    'alerta', v_alerta, 'exige_anexo', v_mot.exige_anexo);
end $$;

-- App: falta com documento (foto já reduzida pelo app, sem EXIF; ou PDF), tudo numa transação --------
create or replace function ponto_justificar_falta(p_token text, p_motivo text, p_data date, p_data_fim date default null,
  p_hora_ini time default null, p_hora_fim time default null, p_observacao text default null,
  p_anexo text default null, p_anexo_tipo text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec   uuid := fn_ponto_sessao(p_token);
  v_mot   record;
  v_bin   bytea;
  r       jsonb;
begin
  select * into v_mot from ponto_motivos where codigo = p_motivo and ativo and grupo <> 'ponto';
  if not found then raise exception 'Escolha um motivo válido.'; end if;
  if p_anexo is not null then
    if length(p_anexo) > 7200000 then raise exception 'Arquivo grande demais: até 5 MB.'; end if;
    begin v_bin := decode(p_anexo, 'base64');
    exception when others then raise exception 'Arquivo inválido. Tire a foto de novo ou escolha outro PDF.'; end;
    if octet_length(v_bin) > 5242880 then raise exception 'Arquivo grande demais: até 5 MB.'; end if;
    -- tipo pelos primeiros bytes, nunca pelo que o aparelho diz
    if not ((p_anexo_tipo = 'image/jpeg' and substring(v_bin from 1 for 3) = '\xffd8ff'::bytea)
         or (p_anexo_tipo = 'image/png' and substring(v_bin from 1 for 8) = '\x89504e470d0a1a0a'::bytea)
         or (p_anexo_tipo = 'application/pdf' and substring(v_bin from 1 for 5) = '\x255044462d'::bytea)) then
      raise exception 'O documento precisa ser foto (JPG ou PNG) ou PDF.';
    end if;
  elsif v_mot.exige_anexo then
    raise exception 'Falta o documento: tire a foto ou escolha o PDF.';
  end if;

  r := fn_ponto_justificativa_criar(v_tec, p_motivo, p_data, null, null, p_hora_ini, p_hora_fim, p_observacao, 'app', p_data_fim);
  if v_bin is not null then
    insert into ponto_justificativa_anexos (justificativa_id, tipo, tamanho, sha256, conteudo)
    values ((r->>'id')::uuid, p_anexo_tipo, octet_length(v_bin), encode(extensions.digest(v_bin, 'sha256'), 'hex'),
            fn_ponto_cofre_cifrar(v_bin));
  end if;
  return r - 'id' - 'exige_anexo';
end $$;

-- Lista do funcionário com o período de dias
drop function if exists ponto_minhas_justificativas(text);
create function ponto_minhas_justificativas(p_token text)
returns table (numero bigint, motivo text, data text, detalhe text, status text, resposta text, criado_em text, alerta text)
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return query
    select j.numero, m.nome, to_char(j.data, 'DD/MM/YYYY'),
           fn_ponto_pedido_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim, j.data, j.data_fim),
           j.status, j.resposta, to_char(j.created_at at time zone coalesce(e.fuso, 'America/Bahia'), 'DD/MM HH24:MI'),
           j.alerta_limite
      from ponto_justificativas j join ponto_motivos m on m.codigo = j.motivo
      join empresas e on e.id = j.empresa_id
     where j.tecnico_id = v_tec and j.created_at > now() - interval '90 days'
     order by j.created_at desc limit 50;
end $$;

-- Painel: pedidos. Saúde fica restrita a quem tem ve_saude; leitura nunca vê motivo de saúde -----------
drop function if exists app_ponto_justificativas(date, date, uuid);
create function app_ponto_justificativas(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, numero bigint, tecnico_id uuid, tecnico text, motivo text, motivo_nome text, grupo text,
               data date, detalhe text, tipo_marcacao text, hora text, hora_ini text, hora_fim text,
               observacao text, canal text, status text, decidido_por text, decidido_em text, resposta text, criado_em text,
               abono_estornado boolean, data_fim date, restrito boolean, pode_decidir boolean, anexos integer,
               alerta_limite text, fora_prazo boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor','leitura']);
  v_leitura boolean := fn_papel(v_email) = 'leitura';
  v_saude   boolean := fn_ve_saude(v_email);
begin
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select j.id, j.numero, j.tecnico_id, t.nome,
           case when m.saude and not v_saude then 'saude' else j.motivo end,
           case when m.saude and not v_saude then 'Justificativa de saúde' else m.nome end,
           m.grupo, j.data,
           fn_ponto_pedido_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim, j.data, j.data_fim),
           j.tipo_marcacao, to_char(j.hora, 'HH24:MI'), to_char(j.hora_ini, 'HH24:MI'), to_char(j.hora_fim, 'HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.observacao end, j.canal, j.status,
           case when v_leitura then null else j.decidido_por end,
           to_char(j.decidido_em at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.resposta end,
           to_char(j.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           exists (select 1 from ponto_abonos x where x.estorno_de = j.abono_id),
           j.data_fim,
           m.grupo <> 'ponto' and not v_saude,
           not v_leitura and (m.grupo = 'ponto' or v_saude),
           (select count(*)::int from ponto_justificativa_anexos a where a.justificativa_id = j.id),
           case when v_leitura or (m.saude and not v_saude) then null else j.alerta_limite end,
           m.grupo <> 'ponto' and j.created_at > ((coalesce(j.data_fim, j.data) + 1)::timestamp at time zone e.fuso) + interval '48 hours'
      from ponto_justificativas j
      join tecnicos t on t.id = j.tecnico_id
      join empresas e on e.id = j.empresa_id
      join ponto_motivos m on m.codigo = j.motivo
     where (j.status = 'pendente' or j.data between p_de and p_ate)
       and (p_tecnico is null or j.tecnico_id = p_tecnico)
     order by (j.status = 'pendente') desc, j.created_at desc;
end $$;

-- Decidir (recriada da migration 66): saúde só com ve_saude; falta aprovada vira abono de cada dia --------
create or replace function app_ponto_decidir(p_id uuid, p_aprovar boolean, p_resposta text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  j       record;
  v_tec   record;
  v_mot   record;
  v_resp  text := nullif(trim(coalesce(p_resposta, '')), '');
  v_mom   timestamptz;
  v_aj    uuid;
  v_ab    uuid;
  v_txt   text;
  v_motx  text;
  v_dia   date;
  v_id    uuid;
begin
  select * into j from ponto_justificativas where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  select * into v_mot from ponto_motivos where codigo = j.motivo;
  if v_mot.grupo <> 'ponto' and not fn_ve_saude(v_email) then
    raise exception 'Pedido com documento: só quem tem permissão de ver atestados e documentos decide.';
  end if;
  if j.status <> 'pendente' then raise exception 'Este pedido já foi decidido.'; end if;
  select t.nome, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = j.tecnico_id;
  if length(coalesce(v_resp, '')) > 500 then raise exception 'Resposta com no máximo 500 letras.'; end if;
  v_motx := 'Pedido nº ' || j.numero || ' do funcionário, aprovado';
  -- ao funcionário pelo WhatsApp: motivo de saúde não vai no texto (canal de terceiros)
  v_txt := case when v_mot.saude then 'Justificativa' else v_mot.nome end;

  if not p_aprovar then
    if length(coalesce(v_resp, '')) < 10 then raise exception 'Escreva o motivo da negativa (pelo menos 10 letras). Ele vai para o funcionário.'; end if;
    update ponto_justificativas set status = 'negada', decidido_por = v_email, decidido_em = now(), resposta = v_resp where id = p_id;
    v_txt := '*Pedido ' || j.numero || ' não aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Motivo do gestor: ' || v_resp || E'\n' || 'Tem como comprovar? Faça um novo pedido (WhatsApp: *ajuste*; ou pelo app).';
  elsif j.motivo in ('esqueci_marcar', 'falha_registro') then
    v_mom := (j.data + j.hora) at time zone v_tec.fuso;
    if exists (select 1 from ponto_ajustes a where a.tecnico_id = j.tecnico_id and a.acao = 'incluir'
                and a.tipo = j.tipo_marcacao and a.momento = v_mom
                and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id)) then
      raise exception 'Esta marcação já foi incluída. Negue o pedido como repetido.';
    end if;
    insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor, justificativa_id)
    values (j.empresa_id, j.tecnico_id, 'incluir', v_mom, j.tipo_marcacao, v_motx, v_email, j.id)
    returning id into v_aj;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, ajuste_id = v_aj
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Marcação incluída: ' || fn_ponto_rotulo(j.tipo_marcacao) || ' às ' || to_char(j.hora, 'HH24:MI') || '.';
  elsif j.hora_ini is not null then
    -- período de horas (atraso, consulta, pré-natal)
    if exists (select 1 from ponto_abonos a where a.tecnico_id = j.tecnico_id and a.data = j.data and a.estorno_de is null
                and a.inicio is not distinct from j.hora_ini and a.fim is not distinct from j.hora_fim
                and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
      raise exception 'Este período já está abonado. Negue o pedido como repetido.';
    end if;
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, motivo, autor)
    values (j.empresa_id, j.tecnico_id, j.data, j.hora_ini, j.hora_fim, j.id, v_motx, v_email)
    returning id into v_ab;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, abono_id = v_ab
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Abonado ' || fn_ponto_pedido_detalhe(j.motivo, null, null, j.hora_ini, j.hora_fim, j.data, null) || ': esse período não é descontado.';
  else
    -- dias inteiros: um abono por dia (dia já abonado fica como está)
    for v_dia in select g::date from generate_series(j.data, coalesce(j.data_fim, j.data), interval '1 day') g loop
      if not exists (select 1 from ponto_abonos a where a.tecnico_id = j.tecnico_id and a.data = v_dia and a.inicio is null
                      and a.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
        insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
        values (j.empresa_id, j.tecnico_id, v_dia, j.id, v_motx, v_email) returning id into v_id;
        v_ab := coalesce(v_ab, v_id);
      end if;
    end loop;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, abono_id = v_ab
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · '
      || fn_ponto_pedido_detalhe(j.motivo, null, null, null, null, j.data, j.data_fim) || E'\n'
      || 'Abonado: esse período não é descontado.';
  end if;

  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, v_txt);
  end if;
  return jsonb_build_object('numero', j.numero, 'status', case when p_aprovar then 'aprovada' else 'negada' end,
                            'ajuste_id', v_aj, 'abono_id', v_ab);
end $$;

-- Documentos de um pedido (só os dados do arquivo) e visualização com registro --------------------------
create or replace function app_ponto_anexos(p_justificativa uuid)
returns table (id uuid, tipo text, tamanho int, criado_em text, visualizacoes bigint)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos vê os documentos.'; end if;
  return query
    select a.id, a.tipo, a.tamanho, to_char(a.created_at at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
           (select count(*) from ponto_anexo_acessos x where x.anexo_id = a.id)
      from ponto_justificativa_anexos a where a.justificativa_id = p_justificativa order by a.created_at;
end $$;

create or replace function app_ponto_anexo_ver(p_anexo uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos vê os documentos.'; end if;
  select x.id, x.justificativa_id, x.tipo, x.conteudo, x.sha256 into a from ponto_justificativa_anexos x where x.id = p_anexo;
  if not found then raise exception 'Documento não encontrado.'; end if;
  insert into ponto_anexo_acessos (anexo_id, justificativa_id, sha256, email) values (a.id, a.justificativa_id, a.sha256, v_email);
  return jsonb_build_object('tipo', a.tipo, 'conteudo', encode(fn_ponto_cofre_decifrar(a.conteudo), 'base64'),
    'visto_por', v_email, 'em', to_char(now() at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'));
end $$;

-- WhatsApp: Saúde, Família e Convocação orientam a usar o app (mídia pelo WhatsApp é a E2b) ------------
create or replace function fn_ponto_wh_ajuste(p_tecnico uuid, p_nome text, p_tel text, p_fuso text,
  p_etapa text, p_dados jsonb, p_norm text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_dados jsonb := coalesce(p_dados, '{}');
  v_hoje  date := (now() at time zone p_fuso)::date;
  v_data  date;
  v_hora  time;
  v_ini   time;
  v_fim   time;
  v_par   text[];
  r       jsonb;
  v_menu  text := 'Ajuste de ponto, ' || split_part(trim(p_nome), ' ', 1) || '. O que aconteceu? Responda o número:' || E'\n'
    || '*1* Saúde: atestado, consulta ou exame' || E'\n'
    || '*2* Família: falecimento, casamento ou nascimento' || E'\n'
    || '*3* Convocação: justiça, eleição ou outra' || E'\n'
    || '*4* Ponto: esqueci de marcar, atrasei ou o app falhou' || E'\n'
    || '*0* Cancelar';
  v_marc  text := 'Qual marcação ficou faltando?' || E'\n'
    || '*1* Entrada  *2* Saída para almoço  *3* Volta do almoço' || E'\n'
    || '*4* Saída  *5* Início de hora extra  *6* Fim de hora extra';
begin
  if p_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Pedido de ajuste cancelado. Para recomeçar, escreva *ajuste*.');
    return jsonb_build_object('acao', 'ajuste_cancelado');
  end if;

  if p_etapa is null or p_norm in ('ajuste', 'justificar', 'justificativa') then
    insert into ponto_conversas (tecnico_id, etapa, tipo, dados, expira_em)
    values (p_tecnico, 'aj_menu', null, jsonb_build_object('inicio', now()), now() + interval '15 minutes')
    on conflict (tecnico_id) do update set etapa = 'aj_menu', tipo = null, dados = excluded.dados, expira_em = excluded.expira_em;
    perform fn_ponto_wa(p_tel, v_menu);
    return jsonb_build_object('acao', 'ajuste_menu');
  end if;

  if p_etapa = 'aj_menu' then
    if p_norm in ('1', '2', '3') then
      update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Para esse pedido é preciso a foto ou o PDF do documento. Faça pelo *app do ponto*, aba *Ajuste*: '
        || 'escolha o motivo, o dia e tire a foto do documento.' || E'\n'
        || 'Não precisa informar a doença. O documento fica guardado com segurança e só quem aprova vê.');
      return jsonb_build_object('acao', 'ajuste_pelo_app');
    elsif p_norm = '4' then
      update ponto_conversas set etapa = 'aj_motivo', expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, '*Ponto.* O que aconteceu?' || E'\n' || '*1* Esqueci de marcar' || E'\n'
        || '*2* O app ou o WhatsApp não funcionou' || E'\n' || '*3* Cheguei atrasado ou saí mais cedo' || E'\n'
        || '*0* Cancelar' || E'\n' || 'O gestor analisa cada caso.');
      return jsonb_build_object('acao', 'ajuste_ponto');
    end if;
    perform fn_ponto_wa(p_tel, 'Não entendi essa opção.' || E'\n\n' || v_menu);
    return jsonb_build_object('acao', 'ajuste_menu_repetido');
  end if;

  if p_etapa = 'aj_motivo' then
    if p_norm not in ('1', '2', '3') then
      perform fn_ponto_wa(p_tel, 'Responda *1*, *2* ou *3*, ou *0* para cancelar.');
      return jsonb_build_object('acao', 'ajuste_motivo_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('motivo', (array['esqueci_marcar', 'falha_registro', 'atraso_saida'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_dia', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Qual dia? Ex.: *15/10*. Responda *hoje* ou *ontem*, se for o caso.');
    return jsonb_build_object('acao', 'ajuste_pediu_dia');
  end if;

  if p_etapa = 'aj_dia' then
    v_data := fn_ponto_ler_data(p_norm, v_hoje);
    if v_data is null or v_data > v_hoje or v_data < v_hoje - 62 then
      perform fn_ponto_wa(p_tel, 'Não entendi o dia. Responda como *15/10*, *hoje* ou *ontem* (até 62 dias atrás).');
      return jsonb_build_object('acao', 'ajuste_dia_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('data', v_data);
    if v_dados->>'motivo' = 'atraso_saida' then
      update ponto_conversas set etapa = 'aj_periodo', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Qual período? Ex.: *8h às 9h*.');
      return jsonb_build_object('acao', 'ajuste_pediu_periodo');
    end if;
    update ponto_conversas set etapa = 'aj_marcacao', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, v_marc);
    return jsonb_build_object('acao', 'ajuste_pediu_marcacao');
  end if;

  if p_etapa = 'aj_marcacao' then
    if p_norm !~ '^[1-6]$' then
      perform fn_ponto_wa(p_tel, 'Responda o número de *1* a *6*.' || E'\n\n' || v_marc);
      return jsonb_build_object('acao', 'ajuste_marcacao_repetida');
    end if;
    v_dados := v_dados || jsonb_build_object('tipo', (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_hora', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Que horas foi? Ex.: *7h30*.');
    return jsonb_build_object('acao', 'ajuste_pediu_hora');
  end if;

  if p_etapa = 'aj_hora' then
    v_hora := fn_ponto_ler_hora(p_norm);
    if v_hora is null then
      perform fn_ponto_wa(p_tel, 'Não entendi o horário. Responda como *7h30* ou *17:05*.');
      return jsonb_build_object('acao', 'ajuste_hora_repetida');
    end if;
  elsif p_etapa = 'aj_periodo' then
    v_par := regexp_split_to_array(p_norm, '\s*(?:as|a|ate|-)\s+|\s*-\s*');
    if array_length(v_par, 1) = 2 then v_ini := fn_ponto_ler_hora(v_par[1]); v_fim := fn_ponto_ler_hora(v_par[2]); end if;
    if v_ini is null or v_fim is null or v_ini >= v_fim then
      perform fn_ponto_wa(p_tel, 'Não entendi o período. Responda como *8h às 9h* (o início antes do fim).');
      return jsonb_build_object('acao', 'ajuste_periodo_repetido');
    end if;
  else
    return null;
  end if;

  begin
    r := fn_ponto_justificativa_criar(p_tecnico, v_dados->>'motivo', (v_dados->>'data')::date, v_dados->>'tipo',
                                      v_hora, v_ini, v_fim, null, 'whatsapp');
  exception when others then
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, case when sqlstate = 'P0001' then 'Não foi possível registrar o pedido: ' || sqlerrm
                                    else 'Não foi possível registrar o pedido agora. Tente de novo ou fale com o gestor.' end);
    return jsonb_build_object('acao', 'ajuste_erro', 'erro', sqlerrm);
  end;
  update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
  perform fn_ponto_wa(p_tel, '✅ *Pedido ' || (r->>'numero') || ' recebido*' || E'\n'
    || (r->>'motivo') || ' · ' || (r->>'data') || ' · ' || (r->>'detalhe') || E'\n'
    || 'O gestor vai analisar. A resposta chega aqui e na aba Ajuste do app.');
  return jsonb_build_object('acao', 'ajuste_registrado', 'numero', r->'numero');
end $$;

-- Log do webhook sem mídia (base: definição atual da homologação) ---------------------------------------
create or replace function fn_webhook_evolution(p_token text, p_payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_log    bigint;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
  v_pl     jsonb := p_payload - 'apikey';
  v_msg    jsonb;
  v_permitidas text[] := array['conversation', 'extendedTextMessage', 'buttonsResponseMessage', 'templateButtonReplyMessage',
                               'interactiveResponseMessage', 'listResponseMessage', 'messageContextInfo', 'localizacao',
                               'reactionMessage', 'protocolMessage'];
begin
  if p_token is null or p_token = '' or p_token is distinct from fn_segredo('WEBHOOK_TOKEN') then
    raise exception 'token invalido';
  end if;

  -- LGPD: a localização do ponto já fica na marcação; o log do webhook não guarda outra cópia
  if v_pl->'data'->'message' ?| array['locationMessage', 'liveLocationMessage'] then
    v_pl := jsonb_set(v_pl, '{data,message}',
      ((v_pl->'data'->'message') - 'locationMessage' - 'liveLocationMessage') || '{"localizacao": true}');
  end if;
  -- LGPD (decisão 56): o log guarda só texto, botão e a marca da localização (tirada acima). Foto, vídeo,
  -- áudio, arquivo, mensagem temporária ou de visualização única e a mensagem citada saem (miniatura,
  -- legenda, URL e chave da mídia); fica só a marca "midia"
  if jsonb_typeof(v_pl->'data'->'message') = 'object' then
    select coalesce(jsonb_object_agg(e.k, case when e.k = 'extendedTextMessage' then e.v #- '{contextInfo,quotedMessage}' else e.v end), '{}')
      into v_msg
      from jsonb_each(v_pl->'data'->'message') e(k, v)
     where e.k = any(v_permitidas);
    if exists (select 1 from jsonb_object_keys(v_pl->'data'->'message') k where k <> all(v_permitidas)) then
      v_msg := v_msg || '{"midia": true}';
    end if;
    v_pl := jsonb_set(v_pl, '{data,message}', v_msg);
  end if;
  v_pl := v_pl #- '{data,contextInfo,quotedMessage}';
  insert into webhook_eventos (evento, payload)
  values (v_evento, v_pl)
  returning id into v_log;

  begin
    if v_evento = 'messages.update' then
      v_res := fn_wh_status(p_payload->'data');
    elsif v_evento = 'messages.upsert' then
      begin
        v_res := fn_ponto_wh(p_payload->'data');
      exception when others then
        -- falha no ponto não pode derrubar a resposta das escalas
        v_res := null;
        raise warning 'ponto: %', sqlerrm;
      end;
      if v_res is null then
        v_res := fn_wh_mensagem(p_payload->'data');
      end if;
    else
      v_res := jsonb_build_object('ignorado', v_evento);
    end if;
    update webhook_eventos set resultado = v_res::text where id = v_log;
  exception when others then
    update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
    v_res := jsonb_build_object('erro', sqlerrm);
  end;

  return v_res;
end $function$;


-- Conversa do ponto (definição da migration 66) recusando mídia: documento só pelo app -----------------
create or replace function fn_ponto_wh(p_data jsonb)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_key    jsonb := p_data->'key';
  v_msg    jsonb := p_data->'message';
  v_wa_id  text  := p_data->'key'->>'id';
  v_jid    text;
  v_tec    record;
  v_conv   record;
  v_norm   text;
  v_ultima text;
  v_tipo   text;
  v_loc    jsonb;
  v_lat    numeric;
  v_lng    numeric;
  v_prec   int;
  c        jsonb;
  v_btn    text;
  v_citou  boolean;
  v_aviso  text;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) or v_wa_id is null then return null; end if;
  -- grupo, status e canal não são do ponto
  if coalesce(v_key->>'remoteJid', '') ~ '@(g\.us|broadcast|newsletter)$' then return null; end if;
  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                                        v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  if v_jid is null then return null; end if;

  select t.id, t.nome, t.telefone_e164, t.cpf, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id
   where fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1)) and t.ativo;
  -- telefone canônico ambíguo (com e sem o 9): não arrisca marcar no funcionário errado
  if (select count(*) from tecnicos t where t.ativo
        and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1))) > 1 then
    return null;
  end if;
  -- só quem está cadastrado para o ponto (CPF e empresa) conversa com o ponto
  if v_tec.id is null or v_tec.cpf is null or v_tec.empresa_id is null then return null; end if;

  -- trava a conversa: duas localizações simultâneas não geram duas marcações
  select * into v_conv from ponto_conversas where tecnico_id = v_tec.id and expira_em > now() for update;
  v_norm := lower(trim(translate(coalesce(v_msg->>'conversation', v_msg->'extendedTextMessage'->>'text', ''),
                                 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouc' || 'aaaaeeiooouc')));
  v_norm := regexp_replace(v_norm, '[.!?]+$', '');
  v_loc := coalesce(v_msg->'liveLocationMessage', v_msg->'locationMessage');
  -- resposta de botão (mesmos formatos de fn_wh_mensagem) e mensagem que cita outra
  v_btn := coalesce(v_msg->'buttonsResponseMessage'->>'selectedButtonId',
                    v_msg->'templateButtonReplyMessage'->>'selectedId');
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then v_btn := null; end;
  end if;
  v_citou := v_msg->'extendedTextMessage'->'contextInfo'->>'stanzaId' is not null;

  -- Foto, vídeo ou arquivo pelo WhatsApp: o documento vai só pelo app (cofre, decisão 56). Nada é guardado
  if v_msg ?| array['imageMessage', 'documentMessage', 'documentWithCaptionMessage', 'videoMessage', 'stickerMessage']
     or exists (select 1 from unnest(array['ephemeralMessage', 'viewOnceMessage', 'viewOnceMessageV2', 'viewOnceMessageV2Extension']) w
                 where v_msg->w->'message' ?| array['imageMessage', 'documentMessage', 'documentWithCaptionMessage', 'videoMessage']) then
    perform fn_ponto_wa(v_tec.telefone_e164, 'Por aqui não recebemos fotos nem arquivos. Para enviar atestado ou outro documento, '
      || 'use o *app do ponto*, aba *Ajuste*: é mais seguro e só quem aprova vê.');
    return jsonb_build_object('acao', 'ponto_midia_recusada');
  end if;

  -- 0. Pedido de ajuste (decisão 55): a palavra "ajuste" abre a conversa; dentro dela, as respostas
  -- são do pedido (resposta citando outra mensagem segue para as escalas)
  -- escala enviada ou ocorrência aberta depois do início do pedido: a resposta é da escala, e a conversa
  -- de ajuste termina (o funcionário recomeça com "ajuste")
  if v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%'
     and (exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                   where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                     and o.created_at > now() - interval '2 hours')
          or exists (select 1 from notificacoes n join escalas e on e.id = n.escala_id
                      where e.tecnico_id = v_tec.id
                        and n.created_at > coalesce((v_conv.dados->>'inicio')::timestamptz, now() - interval '15 minutes'))) then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    v_conv.tecnico_id := null;
  end if;
  if v_loc is null and v_btn is null and not v_citou
     and (v_norm in ('ajuste', 'justificar', 'justificativa')
          or (v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%' and v_norm <> '')) then
    return fn_ponto_wh_ajuste(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_tec.fuso,
                              case when v_conv.etapa like 'aj\_%' then v_conv.etapa end, v_conv.dados, v_norm);
  end if;

  select m.tipo into v_ultima from ponto_marcacoes m
   where m.tecnico_id = v_tec.id and (m.momento at time zone v_tec.fuso)::date = (now() at time zone v_tec.fuso)::date
   order by m.nsr desc limit 1;

  -- 1. Localização
  if v_loc is not null then
    if exists (select 1 from ponto_marcacoes where origem ->> 'msg_id' = v_wa_id) then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');
    end if;
    if v_conv.tecnico_id is null or v_conv.etapa <> 'aguardando_local' then
      -- atualização da localização em tempo real fora da conversa: ignora em silêncio
      if v_msg ? 'liveLocationMessage' then return jsonb_build_object('ignorado', 'ponto: localização sem conversa'); end if;
      perform fn_ponto_wa(v_tec.telefone_e164, 'Para bater o ponto, escreva *ponto* primeiro e depois mande a localização.');
      return jsonb_build_object('acao', 'ponto_localizacao_sem_conversa');
    end if;
    -- lugar escolhido no mapa traz nome ou endereço; a localização atual não
    if v_msg ? 'locationMessage' and (coalesce(v_loc->>'name', '') <> '' or coalesce(v_loc->>'address', '') <> '') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é um lugar escolhido no mapa. Mande a sua *localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_recusada');
    end if;
    -- localização encaminhada (de outra pessoa ou uma antiga do próprio funcionário). A Evolution 2.x
    -- traz o contexto em data.contextInfo; o protocolo o põe dentro da localização (messageContextInfo
    -- fica por garantia)
    if exists (select 1 from (values (v_loc->'contextInfo'), (p_data->'contextInfo'), (v_msg->'messageContextInfo')) x(ci)
                where coalesce(ci->>'isForwarded', '') = 'true'
                   or coalesce(nullif(ci->>'forwardingScore', ''), '0') <> '0') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Localização encaminhada não vale para o ponto. Mande a *sua localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_encaminhada');
    end if;
    v_lat := (v_loc->>'degreesLatitude')::numeric;
    v_lng := (v_loc->>'degreesLongitude')::numeric;
    v_prec := nullif(v_loc->>'accuracyInMeters', '')::numeric::int;
    if v_lat is null or v_lng is null then return null; end if;
    -- localização FIXA com a coordenada exata (6 casas, ~10 cm) de uma marcação anterior: pode ser
    -- reenviada. Pede a localização em tempo real, que não pode ser encaminhada e é sempre leitura nova
    -- (GPS com cache dentro de prédio também repete coordenada: o funcionário honesto tem saída)
    if v_msg ? 'locationMessage' and exists (select 1 from ponto_marcacoes m
                where m.tecnico_id = v_tec.id and m.momento > now() - interval '60 days'
                  and m.latitude = round(v_lat, 6) and m.longitude = round(v_lng, 6)) then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é igual à de uma marcação anterior. Mande a sua *localização em tempo real*: 📎 → Localização → *Compartilhar localização em tempo real* (pode ser por 15 minutos).');
      return jsonb_build_object('acao', 'ponto_localizacao_repetida');
    end if;
    begin
      c := fn_ponto_registrar(v_tec.id, v_conv.tipo, 'whatsapp', v_lat, v_lng, v_prec,
                              jsonb_build_object('msg_id', v_wa_id));
    exception when unique_violation then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');   -- entrega simultânea
    when others then
      -- só a mensagem de regra (raise exception) vai ao funcionário; o detalhe técnico fica no log
      perform fn_ponto_wa(v_tec.telefone_e164, case when sqlstate = 'P0001'
        then 'Não foi possível registrar o ponto: ' || sqlerrm
        else 'Não foi possível registrar o ponto agora. Tente de novo ou fale com o gestor.' end);
      return jsonb_build_object('acao', 'ponto_erro', 'erro', sqlerrm);
    end;
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    -- comprovante no WhatsApp: CPF mascarado (o canal passa por terceiros)
    perform fn_ponto_wa(v_tec.telefone_e164,
      '✅ *Ponto registrado*' || E'\n\n'
      || '*' || fn_ponto_rotulo(c->>'tipo') || '* — ' || (c->>'data') || ' às ' || (c->>'hora') || E'\n'
      || 'NSR ' || (c->>'nsr') || ' · ' || (c->>'empresa') || E'\n'
      || (c->>'trabalhador') || ' · CPF ***.' || substr(c->>'cpf', 4, 3) || '.' || substr(c->>'cpf', 7, 3) || '-**' || E'\n'
      || coalesce('Local: ' || (c->>'local') || case when (c->>'dentro_area')::boolean is false
                   then ' (a ' || (c->>'distancia_m') || ' m: o gestor será avisado)' else '' end || E'\n', '')
      || 'Autenticação: ' || (c->>'autenticacao')
      -- avisos de jornada (intervalo, hora extra, interjornada): a marcação vale, o gestor é avisado
      || coalesce(E'\n\n' || array_to_string(fn_ponto_avisar(v_tec.id, c->>'tipo'), E'\n'), ''));
    return jsonb_build_object('acao', 'ponto_registrado', 'nsr', c->'nsr');
  end if;

  -- 2. Botão, número do menu ou palavra do ponto
  if v_btn is not null then
    -- botão de outro fluxo (escala) segue para as escalas
    if v_btn !~ '^ponto:(entrada|saida_almoco|volta_almoco|saida|inicio_he|fim_he)$' then return null; end if;
    v_tipo := substring(v_btn from 7);
  elsif v_conv.tecnico_id is not null and v_conv.etapa = 'escolher_tipo' and v_norm ~ '^[1-6]$' and not v_citou then
    -- número só vale como escolha do menu se não for resposta citando outra mensagem (ex.: a escala)
    v_tipo := (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[v_norm::int];
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    perform fn_ponto_wa(v_tec.telefone_e164, 'Registro de ponto cancelado. Para recomeçar, escreva *ponto*.');
    return jsonb_build_object('acao', 'ponto_cancelado');
  elsif v_norm in ('entrada', 'entrei', 'cheguei', 'inicio do expediente') then
    v_tipo := 'entrada';
  elsif v_norm in ('almoco', 'saida almoco', 'saida para almoco', 'saida para o almoco', 'sai para almoco', 'intervalo') then
    v_tipo := case when v_ultima = 'saida_almoco' then 'volta_almoco' else 'saida_almoco' end;
  elsif v_norm in ('volta', 'volta do almoco', 'voltei', 'retorno', 'retorno do almoco') then
    v_tipo := 'volta_almoco';
  elsif v_norm in ('saida', 'fim do expediente') then
    v_tipo := 'saida';
  elsif v_norm in ('he', 'hora extra', 'horas extras') then
    v_tipo := case when v_ultima = 'inicio_he' then 'fim_he' else 'inicio_he' end;
  elsif v_norm in ('ponto', 'bater ponto', 'registro de ponto', 'registrar ponto', 'marcar ponto') then
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, null);
    return jsonb_build_object('acao', 'ponto_menu');
  elsif v_norm ~ '^(1|2|s|n|sim|nao|ok|ciente|confirmado|confirmada|confirmo|ciente, confirmado|problema|tenho um problema)$'
     or exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                 where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                   and o.created_at > now() - interval '2 hours') then
    -- resposta típica de escala, ou detalhe de ocorrência aberta (como em fn_wh_mensagem): segue
    -- para as escalas mesmo dentro da conversa do ponto
    return null;
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm <> '' then
    -- dentro da conversa do ponto, resposta que não é opção válida volta para o menu
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, 'Não entendi essa opção.');
    return jsonb_build_object('acao', 'ponto_menu_repetido');
  else
    return null;   -- não é do ponto: segue para as escalas
  end if;

  insert into ponto_conversas (tecnico_id, etapa, tipo, expira_em)
  values (v_tec.id, 'aguardando_local', v_tipo, now() + interval '10 minutes')
  on conflict (tecnico_id) do update set etapa = 'aguardando_local', tipo = excluded.tipo, expira_em = excluded.expira_em;
  -- aviso ANTES de registrar a volta do almoço com intervalo abaixo do mínimo (não bloqueia)
  v_aviso := fn_ponto_aviso_previo(v_tec.id, v_tipo);
  perform fn_ponto_wa(v_tec.telefone_e164,
    coalesce(v_aviso || E'\n\n', '')
    || '*' || fn_ponto_rotulo(v_tipo) || '*. Agora mande a sua *localização atual*:' || E'\n'
    || '📎 → Localização → *Enviar localização atual*.' || E'\n\n'
    || 'A hora registrada é a do recebimento da localização.');
  return jsonb_build_object('acao', 'ponto_pediu_localizacao', 'tipo', v_tipo);
end $$;

-- Permissões por laço (decisões 12, 49 e 51) -------------------------------------------------------
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
