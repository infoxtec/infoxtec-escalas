-- Migration 96 (14/10/2026): limite de hora extra pela escala e Alerta Crítico (backlog 105, decisão 90).
-- O limite de 2 horas extras por dia (CLT art. 59) passa a contar sobre a jornada do dia na escala do funcionário
-- (fn_carga_minutos_dia, migration 94; sem escala, a jornada padrão).
-- 1) Programação: criar ou mudar a data ou a hora de uma Programação que faz o dia previsto do funcionário passar
--    da jornada do dia + 2 h exige o aceite de risco da EMPRESA, assinado no painel por admin ou gestor, com motivo
--    (CLT art. 61) e justificativa. O termo é interno: o funcionário não vê nem assina (texto do juridico). Vale
--    para as Programações criadas ou alteradas depois da aplicação; as já enviadas não mudam.
-- 2) Ponto: o aviso "hora extra acima do limite" ao funcionário e o Alerta Crítico ao supervisor no WhatsApp
--    passam a contar sobre a jornada do dia na escala (antes, 8 h fixas, inclusive no sábado).
-- 3) Indicadores: quem passou do limite hoje e no mês (app_carga_excedida) e os aceites assinados.
-- O espelho mensal, o débito e o pagamento de HE continuam na jornada padrão até a etapa 2 do backlog 104.

-- Aceite da Programação acima do limite ----------------------------------------------------------------------
create table if not exists programacao_aceites (
  id              uuid primary key default gen_random_uuid(),
  escala_id       uuid not null references escalas(id),
  empresa_id      uuid references empresas(id),
  tecnico_id      uuid not null references tecnicos(id),
  data            date not null,
  previsto_min    int not null,
  contratual_min  int not null,
  excedente_min   int not null,
  motivo          text not null check (motivo in ('forca_maior', 'servico_inadiavel', 'prejuizo_evidente', 'outro')),
  justificativa   text not null,
  texto           text not null,
  sha256          text not null,
  nome            text not null,
  email           text not null,
  papel           text not null,
  aceito_em       timestamptz not null default now()
);
comment on table programacao_aceites is 'Aceite de risco da empresa para Programação que passa do limite de 2 h extras no dia (decisão 90). Interno; só inclusão.';
alter table programacao_aceites enable row level security;
create index if not exists programacao_aceites_data_idx on programacao_aceites (data);
create index if not exists programacao_aceites_tecnico_idx on programacao_aceites (tecnico_id, data);

create or replace function fn_programacao_aceite_imutavel()
returns trigger language plpgsql set search_path = public, extensions as $function$
begin
  raise exception 'O aceite de risco da programação não muda nem é apagado depois de assinado.';
end $function$;
create or replace trigger trg_programacao_aceites_imutavel before update or delete on programacao_aceites
  for each row execute function fn_programacao_aceite_imutavel();
create or replace trigger trg_programacao_aceites_sem_truncate before truncate on programacao_aceites
  for each statement execute function fn_programacao_aceite_imutavel();

-- Dia previsto pelas Programações: da primeira entrada à última saída, menos o maior intervalo. p_hora é a
-- Programação nova (jornada calculada como na criação); p_ignorar, a que está sendo alterada.
create or replace function fn_programacao_limite(p_tecnico uuid, p_data date, p_hora time default null, p_ignorar uuid default null)
returns jsonb language plpgsql stable set search_path = public, extensions as $function$
declare
  v_ini   timestamp;
  v_fim   timestamp;
  v_int   int := 0;
  j       record;
  v_prev  int := 0;
  v_contr int := fn_carga_minutos_dia(p_tecnico, p_data);
  v_lim   int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
begin
  select min(e.data_servico + e.hora_inicio),
         max(e.data_servico + e.hora_inicio + make_interval(mins => e.duracao_prevista_min + coalesce(e.intervalo_min, 0))),
         coalesce(max(coalesce(e.intervalo_min, 0)), 0)
    into v_ini, v_fim, v_int
    from escalas e
   where e.tecnico_id = p_tecnico and e.data_servico = p_data and e.status not in ('cancelada', 'recusada')
     and e.id is distinct from p_ignorar;
  if p_hora is not null then
    select * into j from fn_calcular_jornada(p_hora);
    v_ini := least(coalesce(v_ini, p_data + p_hora), p_data + p_hora);
    v_fim := greatest(coalesce(v_fim, p_data + p_hora + make_interval(mins => j.trabalho_min + j.intervalo_min)),
                      p_data + p_hora + make_interval(mins => j.trabalho_min + j.intervalo_min));
    v_int := greatest(v_int, j.intervalo_min);
  end if;
  if v_ini is not null then
    v_prev := greatest((extract(epoch from v_fim - v_ini) / 60)::int - v_int, 0);
  end if;
  return jsonb_build_object('previsto_min', v_prev, 'contratual_min', v_contr, 'limite_min', v_contr + v_lim,
                            'excedente_min', greatest(v_prev - (v_contr + v_lim), 0));
end $function$;

create or replace function fn_programacao_motivo(p text)
returns text language sql immutable set search_path = public, extensions as $function$
  select case p when 'forca_maior' then 'força maior'
                when 'servico_inadiavel' then 'serviço inadiável'
                when 'prejuizo_evidente' then 'prejuízo evidente se o serviço não for feito'
                when 'outro' then 'outro (fora das hipóteses do art. 61 da CLT)' end
$function$;

-- Termo da empresa (texto do juridico, 14/10). O painel mostra este texto; ao salvar, entra a hora.
create or replace function fn_programacao_termo(p_tecnico uuid, p_data date, p_lim jsonb, p_email text,
                                                p_motivo text, p_justificativa text)
returns text language plpgsql stable set search_path = public, extensions as $function$
declare
  v_usu painel_usuarios;
  v_emp empresas;
  v_tec tecnicos;
begin
  select * into v_tec from tecnicos where id = p_tecnico;
  select * into v_emp from empresas where id = v_tec.empresa_id;
  select * into v_usu from painel_usuarios where email = p_email;
  return 'Termo interno de aceite de risco: Programação / Jornada do dia. '
    || coalesce(v_emp.razao_social, '(empregadora)') || ', CNPJ ' || coalesce(v_emp.cnpj, '-') || ', empregadora, por meio de '
    || coalesce(nullif(v_usu.nome, ''), p_email) || ' (' || p_email || '), '
    || case v_usu.papel when 'admin' then 'administrador' when 'gestor' then 'gestor' else coalesce(v_usu.papel, '') end
    || ' do painel Infoxtec Escalas, que assina como representante da empregadora, registra a decisão da empregadora de manter a programação de serviço de '
    || coalesce(v_tec.nome, '(funcionário)') || ' para ' || to_char(p_data, 'DD/MM/YYYY') || '. '
    || 'Antes dessa decisão, o sistema alertou que a programação prevê ' || fn_ponto_hm((p_lim->>'previsto_min')::int)
    || ' de trabalho nesse dia. A jornada do dia pela escala é de ' || fn_ponto_hm((p_lim->>'contratual_min')::int)
    || ', e a programação passa em ' || fn_ponto_hm((p_lim->>'excedente_min')::int)
    || ' o limite de duas horas extras diárias (CLT, art. 59). Motivo indicado pela empregadora: '
    || coalesce(fn_programacao_motivo(p_motivo), '(não informado)') || '. Justificativa: ' || coalesce(nullif(trim(p_justificativa), ''), '(não informada)') || '. '
    || 'Estas horas são uma previsão. A jornada efetivamente trabalhada é a do registro de ponto, e as horas extraordinárias são pagas ou compensadas na forma da lei e da norma coletiva aplicável. '
    || 'Este termo é um documento interno de gestão da empregadora. Não é dirigido ao empregado, não é mostrado a ele nem assinado por ele, e não altera o contrato de trabalho. Registra só a decisão e o alerta recebido. Não substitui acordo ou norma coletiva, não afasta direitos do empregado e não é renúncia nem transação de direito.';
end $function$;

-- Confere o aceite: motivo do art. 61 (ou outro), justificativa com o fato concreto, e os excessos que o
-- painel mostrou (p_aceite.vistos: {tecnico_id: excedente_min}); se mudaram, recusa
create or replace function fn_programacao_conferir_aceite(p_aceite jsonb, p_tecnico uuid, p_lim jsonb, p_nome text)
returns void language plpgsql stable set search_path = public, extensions as $function$
declare
  v_mot text := p_aceite->>'motivo';
  v_jus text := trim(coalesce(p_aceite->>'justificativa', ''));
  v_min int;
begin
  if p_aceite is null or coalesce((p_aceite->>'aceito')::boolean, false) is not true then
    raise exception 'A programação de % passa do limite de 2 horas extras no dia (previsto %, limite %). A empresa precisa assinar o aceite de risco com motivo e justificativa.',
      p_nome, fn_ponto_hm((p_lim->>'previsto_min')::int), fn_ponto_hm((p_lim->>'limite_min')::int);
  end if;
  if v_mot is null or v_mot not in ('forca_maior', 'servico_inadiavel', 'prejuizo_evidente', 'outro') then
    raise exception 'Escolha o motivo do excesso (CLT art. 61).';
  end if;
  v_min := case when v_mot = 'outro' then 80 else 40 end;
  if length(v_jus) < v_min then
    raise exception 'Justificativa com pelo menos % caracteres: o que aconteceu, qual serviço, e por que não dava para remarcar ou trocar o técnico.', v_min;
  end if;
  if length(v_jus) > 1000 then raise exception 'Justificativa com no máximo 1000 caracteres.'; end if;
  if (select count(distinct c) from regexp_split_to_table(lower(regexp_replace(v_jus, '[^[:alpha:]]', '', 'g')), '') c) < 8 then
    raise exception 'Escreva a justificativa com o fato concreto.';
  end if;
  if (p_aceite->'vistos'->>p_tecnico::text)::int is distinct from (p_lim->>'excedente_min')::int then
    raise exception 'O excesso de % mudou desde a tela. Revise e assine o aceite de novo.', p_nome;
  end if;
end $function$;

create or replace function fn_programacao_registrar_aceite(p_escala uuid, p_aceite jsonb, p_lim jsonb, p_email text)
returns void language plpgsql volatile set search_path = public, extensions as $function$
declare
  e     escalas;
  v_usu painel_usuarios;
  v_txt text;
  v_em  timestamptz := now();
begin
  select * into e from escalas where id = p_escala;
  select * into v_usu from painel_usuarios where email = p_email;
  v_txt := fn_programacao_termo(e.tecnico_id, e.data_servico, p_lim, p_email, p_aceite->>'motivo', p_aceite->>'justificativa')
    || ' Registrado em ' || to_char(v_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (horário de Brasília, UTC-3).';
  insert into programacao_aceites (escala_id, empresa_id, tecnico_id, data, previsto_min, contratual_min, excedente_min,
                                   motivo, justificativa, texto, sha256, nome, email, papel, aceito_em)
  values (e.id, (select empresa_id from tecnicos where id = e.tecnico_id), e.tecnico_id, e.data_servico,
          (p_lim->>'previsto_min')::int, (p_lim->>'contratual_min')::int, (p_lim->>'excedente_min')::int,
          p_aceite->>'motivo', trim(p_aceite->>'justificativa'), v_txt, encode(sha256(convert_to(v_txt, 'UTF8')), 'hex'),
          coalesce(nullif(v_usu.nome, ''), p_email), p_email, coalesce(v_usu.papel, ''), v_em);
end $function$;

-- Painel: para cada técnico, o dia previsto com a Programação nova e, se passar, o termo a assinar
create or replace function app_programacao_limite(p_tecnicos uuid[], p_data date, p_hora time, p_ignorar uuid default null,
                                                  p_motivo text default null, p_justificativa text default null)
returns table (tecnico_id uuid, tecnico text, previsto_min int, contratual_min int, limite_min int, excedente_min int, termo text)
language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  t       record;
  j       jsonb;
begin
  for t in select x.id, x.nome from tecnicos x where x.id = any(coalesce(p_tecnicos, '{}')) order by x.nome loop
    j := fn_programacao_limite(t.id, p_data, p_hora, p_ignorar);
    tecnico_id := t.id; tecnico := t.nome;
    previsto_min := (j->>'previsto_min')::int; contratual_min := (j->>'contratual_min')::int;
    limite_min := (j->>'limite_min')::int; excedente_min := (j->>'excedente_min')::int;
    termo := case when excedente_min > 0 then fn_programacao_termo(t.id, p_data, j, v_email, p_motivo, p_justificativa) end;
    return next;
  end loop;
end $function$;

-- Aceites assinados no período (admin e gestor; o termo é prova do empregador)
create or replace function app_programacao_aceites(p_de date, p_ate date)
returns table (id uuid, data date, tecnico text, previsto_min int, contratual_min int, excedente_min int, motivo text,
               justificativa text, nome text, aceito_em timestamptz, texto text, sha256 text)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor']);
  return query
    select a.id, a.data, t.nome, a.previsto_min, a.contratual_min, a.excedente_min, fn_programacao_motivo(a.motivo),
           a.justificativa, a.nome, a.aceito_em, a.texto, a.sha256
      from programacao_aceites a join tecnicos t on t.id = a.tecnico_id
     where a.data between p_de and p_ate
     order by a.data desc, t.nome;
end $function$;

-- Criar Programações (recriada da homologação, migration 31): ganha p_aceite. A assinatura muda, então a
-- versão antiga sai (duas versões deixariam a chamada do painel ambígua)
drop function if exists app_criar_escalas(uuid[], uuid, date, time without time zone, text, integer, text, boolean, uuid, boolean);
create or replace function app_criar_escalas(p_tecnicos uuid[], p_local uuid, p_data date, p_hora time without time zone,
  p_tarefa text, p_duracao integer default 240, p_prioridade text default 'normal'::text, p_enviar boolean default true,
  p_tipo uuid default null::uuid, p_teste boolean default false, p_aceite jsonb default null)
 returns table(tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  r record;
  t record;
  v_lim jsonb := '{}';
  j jsonb;
begin
  if coalesce(trim(p_tarefa), '') = '' then raise exception 'Descreva a tarefa.'; end if;
  perform fn_validar_inicio(p_data, p_hora);

  -- limite de 2 h extras no dia, pela escala de cada técnico (decisão 90): passou, só com o aceite da empresa
  for t in select x.id, x.nome from tecnicos x where x.id = any(coalesce(p_tecnicos, '{}')) loop
    j := fn_programacao_limite(t.id, p_data, p_hora, null);
    if (j->>'excedente_min')::int > 0 then
      perform fn_programacao_conferir_aceite(p_aceite, t.id, j, t.nome);
      v_lim := v_lim || jsonb_build_object(t.id::text, j);
    end if;
  end loop;

  for r in
    select * from fn_criar_escalas_lote(
      v_email, to_jsonb(p_tecnicos)::text, p_local::text, p_data::text,
      to_char(p_hora, 'HH24:MI'), p_tarefa, p_duracao::text,
      coalesce(p_prioridade, 'normal'), p_enviar::text)
  loop
    if r.escala_id is not null then
      update escalas set
        tipo_atividade_id = coalesce(p_tipo, tipo_atividade_id),
        teste = teste or coalesce(p_teste, false)
      where id = r.escala_id;
      if v_lim ? r.tecnico_id::text then
        perform fn_programacao_registrar_aceite(r.escala_id, p_aceite, v_lim->(r.tecnico_id::text), v_email);
      end if;
    end if;
    tecnico_id := r.tecnico_id; tecnico := r.tecnico;
    escala_id := r.escala_id;   resultado := r.resultado;
    return next;
  end loop;
end $function$;

-- Editar Programação (recriada da homologação, migration 93): mudar a data ou a hora para um dia que passa do
-- limite pede o aceite da empresa (p->'aceite')
create or replace function app_editar_escala(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  e         escalas;
  v_data    date;
  v_hora    time;
  v_local   uuid;
  v_tarefa  text;
  v_mudou   boolean;
  v_reconf  boolean;
  v_tec     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
  v_lim     jsonb;
begin
  select * into e from escalas where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar programação em rascunho, agendada, aguardando resposta ou confirmada.';
  end if;
  perform fn_edicao_permitida(e.id);

  v_data   := coalesce(nullif(p->>'data_servico', '')::date, e.data_servico);
  v_hora   := coalesce(nullif(p->>'hora_inicio', '')::time, e.hora_inicio);
  v_local  := case when p ? 'local_id' then nullif(p->>'local_id', '')::uuid else e.local_id end;
  v_tarefa := coalesce(nullif(trim(p->>'descricao_tarefa'), ''), e.descricao_tarefa);
  v_mudou  := v_data <> e.data_servico or v_hora <> e.hora_inicio or v_local is distinct from e.local_id;

  if not v_mudou and v_tarefa = e.descricao_tarefa then
    return jsonb_build_object('alterada', false);
  end if;
  if v_data <> e.data_servico or v_hora <> e.hora_inicio then
    perform fn_validar_inicio(v_data, v_hora);
    -- limite de 2 h extras no novo dia (decisão 90)
    v_lim := fn_programacao_limite(e.tecnico_id, v_data, v_hora, e.id);
    if (v_lim->>'excedente_min')::int > 0 then
      perform fn_programacao_conferir_aceite(p->'aceite', e.tecnico_id, v_lim, (select nome from tecnicos where id = e.tecnico_id));
    else
      v_lim := null;
    end if;
  end if;

  -- decisao do responsavel (27/09): so data, hora ou local pedem nova confirmacao
  v_reconf := v_mudou and e.status in ('notificada', 'confirmada');
  perform set_config('app.ator', v_email, true);
  begin
    update escalas
       set data_servico = v_data, hora_inicio = v_hora, local_id = v_local, descricao_tarefa = v_tarefa,
           status = case when v_reconf then 'notificada'::escala_status else status end,
           confirmada_em = case when v_reconf then null else confirmada_em end,
           supervisor_avisado_em = case when v_mudou then null else supervisor_avisado_em end
     where id = e.id;
  exception when unique_violation then
    raise exception 'O técnico já tem outra programação ativa nesse dia e horário.';
  end;
  if v_lim is not null then
    perform fn_programacao_registrar_aceite(e.id, p->'aceite', v_lim, v_email);
  end if;

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (e.id, 'escala_editada', v_email, jsonb_build_object(
    'antes', jsonb_build_object('data', e.data_servico, 'hora', e.hora_inicio, 'local_id', e.local_id, 'tarefa', e.descricao_tarefa),
    'depois', jsonb_build_object('data', v_data, 'hora', v_hora, 'local_id', v_local, 'tarefa', v_tarefa),
    'nova_confirmacao', v_reconf));

  -- aviso ao tecnico quando a escala ja tinha saido
  if e.status in ('notificada', 'confirmada') and not e.teste then
    select telefone_e164, ativo, opt_in into v_tec from tecnicos where id = e.tecnico_id;
    if v_tec.ativo and v_tec.opt_in then
      if v_reconf then
        perform fn_wa_texto(v_tec.telefone_e164,
          '⚠️ *PROGRAMAÇÃO ALTERADA*' || E'\n\n' || 'Sua programação mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, v_tent,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua programação de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
          || ' foi atualizada: ' || left(v_tarefa, 500));
      end if;
    end if;
  end if;

  return jsonb_build_object('alterada', true, 'nova_confirmacao', v_reconf);
end $function$;

-- Substituir técnico (recriada da homologação, migration 93): se o novo técnico passaria do limite, recusa e
-- orienta a criar pela Nova Programação, onde a empresa assina o aceite
create or replace function app_substituir_tecnico(p_escala uuid, p_tecnico uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  e       escalas;
  v_novo  uuid;
  v_lim   jsonb;
begin
  select * into e from escalas where id = p_escala;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status <> 'recusada' then raise exception 'Só dá para substituir o técnico de uma programação recusada.'; end if;
  if p_tecnico = e.tecnico_id then raise exception 'Escolha outro técnico.'; end if;
  v_lim := fn_programacao_limite(p_tecnico, e.data_servico, e.hora_inicio, null);
  if (v_lim->>'excedente_min')::int > 0 then
    raise exception 'Esse técnico passaria do limite de 2 horas extras no dia (previsto %, limite %). Crie pela Nova Programação, com o aceite da empresa.',
      fn_ponto_hm((v_lim->>'previsto_min')::int), fn_ponto_hm((v_lim->>'limite_min')::int);
  end if;
  begin
    v_novo := fn_criar_escala(v_email, p_tecnico::text, coalesce(e.local_id::text, ''), e.data_servico::text,
                              e.hora_inicio::text, e.descricao_tarefa, e.duracao_prevista_min::text, e.prioridade, 'true');
  exception when unique_violation then
    raise exception 'Esse técnico já tem programação nesse dia e horário.';
  end;
  update escalas set tipo_atividade_id = e.tipo_atividade_id where id = v_novo;
  insert into escala_eventos (escala_id, evento, ator, detalhe) values
    (e.id, 'substituida', v_email, jsonb_build_object('nova_escala', v_novo, 'tecnico_id', p_tecnico)),
    (v_novo, 'substitui', v_email, jsonb_build_object('escala_anterior', e.id));
  return jsonb_build_object('escala', v_novo);
end $function$;

-- Jornada do dia (recriada da migration 83, conferida por MD5 com a homologação): limite de HE pela escala
create or replace function fn_ponto_jornada_dia(p_tecnico uuid, p_data date)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions'
as $function$
declare
  v_fuso    text;
  m         record;
  v_ent     timestamptz;
  v_sa      timestamptz;
  v_va      timestamptz;
  v_sai     timestamptz;
  v_he_ini  timestamptz;
  v_he      int := 0;
  v_normal  int;
  v_total   int;
  v_int     int;
  v_extra   int;
  v_inter   int;
  v_ant     timestamptz;
  v_esc     time;
  v_atraso  int;
  v_n       int := 0;
  v_ajustes int;
  v_hoje    boolean;
  v_ini     timestamptz;
  v_fim     timestamptz;
  v_al      text[] := '{}';
  v_jornada int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_int_min int := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  v_int_max int := coalesce(nullif(fn_config('ponto_intervalo_max_min'), '')::int, 120);
  v_int_cur int := coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15);
  v_he_lim  int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_ij_min  int := coalesce(nullif(fn_config('ponto_interjornada_min'), '')::int, 660);
  v_tol     int := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
  v_ab_dia  boolean := false;
  v_ab_min  int := 0;
  v_ab_txt  text;
  v_contr   int := fn_carga_minutos_dia(p_tecnico, p_data);  -- jornada do dia na escala (decisão 90)
  v_he_esc  int;
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_hoje := p_data >= (now() at time zone v_fuso)::date;
  v_ini := p_data::timestamp at time zone v_fuso;
  v_fim := (p_data + 1)::timestamp at time zone v_fuso;

  for m in select x.tipo, x.momento from fn_ponto_marcacoes_efetivas(p_tecnico, v_ini, v_fim) x
            order by x.momento, x.nsr nulls last loop
    v_n := v_n + 1;
    case m.tipo
      when 'entrada'      then v_ent := coalesce(v_ent, m.momento);
      when 'saida_almoco' then v_sa  := coalesce(v_sa, m.momento);
      when 'volta_almoco' then v_va  := coalesce(v_va, m.momento);
      when 'saida'        then v_sai := m.momento;
      when 'inicio_he'    then v_he_ini := m.momento;
      when 'fim_he'       then
        if v_he_ini is not null then
          v_he := v_he + (extract(epoch from m.momento - v_he_ini) / 60)::int;
          v_he_ini := null;
        end if;
      else null;
    end case;
  end loop;

  select count(*) into v_ajustes
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and coalesce(a.momento, x.momento, y.momento) >= v_ini and coalesce(a.momento, x.momento, y.momento) < v_fim;
  -- escala do dia e abonos (decisão 55): dia com escala já passado e sem marcação é falta
  select min(s.hora_inicio) into v_esc from escalas s
   where s.tecnico_id = p_tecnico and s.data_servico = p_data and s.status not in ('cancelada', 'recusada', 'rascunho');
  select coalesce(bool_or(a.inicio is null), false),
         coalesce(sum(extract(epoch from a.fim - a.inicio) / 60) filter (where a.inicio is not null), 0)::int,
         string_agg(case when a.inicio is null then 'dia inteiro'
                         else to_char(a.inicio, 'HH24:MI') || '–' || to_char(a.fim, 'HH24:MI') end, ', ' order by a.inicio nulls first)
    into v_ab_dia, v_ab_min, v_ab_txt
    from ponto_abonos a
   where a.tecnico_id = p_tecnico and a.data = p_data and a.estorno_de is null
     and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id);
  if v_n = 0 and v_ajustes = 0 and v_ab_txt is null and (v_esc is null or v_hoje) then return null; end if;

  -- trabalho normal: entrada → saída, descontado o intervalo
  if v_ent is not null and v_sai is not null then
    v_normal := (extract(epoch from v_sai - v_ent) / 60)::int;
    if v_sa is not null and v_va is not null then
      v_normal := v_normal - (extract(epoch from v_va - v_sa) / 60)::int;
    end if;
  end if;
  if v_sa is not null and v_va is not null then
    v_int := (extract(epoch from v_va - v_sa) / 60)::int;
  end if;
  v_total := coalesce(v_normal, 0) + v_he;
  v_extra := greatest(v_total - v_jornada, 0);

  -- intervalo intrajornada (CLT art. 71)
  if v_int is not null then
    if v_int < v_int_min and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_curto');
    elsif v_int < v_int_cur and v_normal > 240 then v_al := array_append(v_al, 'intervalo_curto');
    end if;
    if v_int > v_int_max and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_longo'); end if;
  elsif v_total > 240 then
    -- sem intervalo: acima de 4 h já exige 15 min (art. 71, §1º); acima de 6 h, 1 h (caput). Conta a
    -- jornada efetiva, com a hora extra (Súmula 437, IV, do TST), o mesmo valor que escolhe o texto do aviso
    v_al := array_append(v_al, 'sem_intervalo');
  end if;
  -- hora extra (CLT art. 59): o limite de 2 h conta sobre a jornada do dia na escala (decisão 90); he_min
  -- continua sobre a jornada padrão até a etapa 2 do backlog 104 (espelho e pagamento)
  v_he_esc := greatest(v_total - v_contr, 0);
  if v_he_esc > v_he_lim then v_al := array_append(v_al, 'he_acima_limite'); end if;
  -- interjornada (CLT art. 66): da última saída efetiva antes desta entrada
  if v_ent is not null then
    select max(x.momento) into v_ant from fn_ponto_marcacoes_efetivas(p_tecnico, v_ent - interval '2 days', v_ent) x
     where x.tipo in ('saida', 'fim_he');
    if v_ant is not null then
      v_inter := (extract(epoch from v_ent - v_ant) / 60)::int;
      if v_inter < v_ij_min then v_al := array_append(v_al, 'interjornada_curta'); end if;
    end if;
  end if;
  -- atraso em relação à escala (CLT art. 58, §1º)
  if v_esc is not null and v_ent is not null then
    v_atraso := (extract(epoch from (v_ent at time zone v_fuso)::time - v_esc) / 60)::int;
    if v_atraso > v_tol then
      v_al := array_append(v_al, case when v_ab_dia or v_ab_min >= v_atraso then 'atraso_abonado' else 'atraso' end);
    else v_atraso := null; end if;
  end if;
  -- dia já encerrado com marcação faltando
  if v_n = 0 and v_esc is not null and not v_hoje then
    v_al := array_append(v_al, case when v_ab_dia then 'falta_abonada' else 'falta' end);
  elsif v_n > 0 and not v_hoje and (v_ent is null or v_sai is null or (v_sa is null) <> (v_va is null) or v_he_ini is not null) then
    v_al := array_append(v_al, 'incompleta');
  end if;

  return jsonb_build_object(
    'entrada', to_char(v_ent at time zone v_fuso, 'HH24:MI'),
    'saida_almoco', to_char(v_sa at time zone v_fuso, 'HH24:MI'),
    'volta_almoco', to_char(v_va at time zone v_fuso, 'HH24:MI'),
    'saida', to_char(v_sai at time zone v_fuso, 'HH24:MI'),
    'trabalhado_min', case when v_normal is null and v_he = 0 then null else v_total end,
    'intervalo_min', v_int, 'he_min', v_extra, 'interjornada_min', v_inter,
    'contratual_min', v_contr, 'he_escala_min', v_he_esc, 'limite_min', v_contr + v_he_lim,
    'escala_hora', left(v_esc::text, 5), 'atraso_min', v_atraso,
    'marcacoes', v_n, 'ajustes', v_ajustes, 'alertas', to_jsonb(v_al),
    'abono', v_ab_txt, 'abonado_min', case when v_ab_dia then v_jornada else v_ab_min end);
end $function$;

-- Avisos de jornada (recriada da migration 83, conferida por MD5): HE pela escala e Alerta Crítico ao supervisor
create or replace function fn_ponto_avisar(p_tecnico uuid, p_tipo text)
 returns text[]
 language plpgsql
 set search_path to 'public', 'extensions'
as $function$
declare
  v_fuso  text;
  v_emp   uuid;
  v_data  date;
  v_nome  text;
  j       jsonb;
  a       text;
  s       record;
  v_func  text;
  v_gest  text;
  v_saida text[] := '{}';
  v_rel   text[];
  v_lim   int;
begin
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;
  j := fn_ponto_jornada_dia(p_tecnico, v_data);
  if j is null then return v_saida; end if;
  v_rel := case p_tipo
    when 'volta_almoco' then array['intervalo_curto', 'intervalo_longo']
    when 'entrada'      then array['interjornada_curta']
    when 'saida'        then array['he_acima_limite', 'sem_intervalo']
    when 'fim_he'       then array['he_acima_limite']
    else array[]::text[] end;
  for a in select x from jsonb_array_elements_text(j->'alertas') x where x = any(v_rel) loop
    v_func := case a
      when 'intervalo_curto'    then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                            || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
                                       else 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de '
                                            || coalesce(nullif(fn_config('ponto_intervalo_curto_min'), ''), '15')
                                            || ' min — mínimo da CLT para jornada acima de 4 horas (art. 71, §1º).' end
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_escala_min')::int) || ' hoje sobre a jornada de '
                                     || fn_ponto_hm((j->>'contratual_min')::int) || ' do dia, acima do limite de 2 horas por dia (CLT art. 59).'
      when 'sem_intervalo'      then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Jornada de mais de 6 horas sem intervalo registrado — mínimo de 1 hora (CLT art. 71).'
                                       else 'Jornada de mais de 4 horas sem o intervalo mínimo de 15 minutos (CLT art. 71, §1º).' end
      when 'interjornada_curta' then 'Descanso de ' || fn_ponto_hm((j->>'interjornada_min')::int) || ' desde a última saída, abaixo das 11 horas entre jornadas (CLT art. 66).'
    end;
    v_saida := v_saida || ('⚠️ ' || v_func || ' A marcação vale; o gestor será avisado.');
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_' || a || '_' || p_tecnico, v_data, now(), true, jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_gest := case when a = 'he_acima_limite'
                  -- Alerta Crítico (decisão 90; texto do juridico): sem motivo, sem saúde, só o primeiro nome
                  then '🚨 *Alerta crítico · carga horária excedida*' || E'\n' || 'O ponto de ' || v_nome || ' hoje ('
                       || to_char(v_data, 'DD/MM') || ') passou de ' || fn_ponto_hm((j->>'limite_min')::int)
                       || ' (jornada do dia + 2h extras). Confira no painel.'
                  else '⚠️ *Ponto · ' || v_nome || '* (' || to_char(v_data, 'DD/MM') || '): ' || v_func end;
      -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora; cadastrar a
      -- empresa do supervisor antes do segundo cliente (separação por cliente, backlog 074)
      for s in select telefone_e164 from tecnicos
                where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
                  and (empresa_id = v_emp or empresa_id is null) loop
        perform fn_ponto_wa(s.telefone_e164, v_gest);
      end loop;
    end if;
  end loop;
  return v_saida;
exception when others then
  raise warning 'ponto: avisos de jornada falharam: %', sqlerrm;
  return '{}';
end $function$;

-- Indicadores: Alerta Crítico — funcionário com carga horária excedida (hoje e no mês) -------------------------
create or replace function app_carga_excedida(p_mes date default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_hoje    date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date;
  v_ini     date := date_trunc('month', coalesce(p_mes, v_hoje))::date;
  v_fim     date;
  v_lim     int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_lista   jsonb;
begin
  v_fim := least((v_ini + interval '1 month' - interval '1 day')::date, v_hoje);
  if v_fim < v_ini then
    return jsonb_build_object('mes', to_char(v_ini, 'MM/YYYY'), 'hoje', 0, 'mes_total', 0, 'limite_dia_min', v_lim, 'funcionarios', '[]'::jsonb);
  end if;
  with t as (
    select x.id, x.nome, coalesce(m.nome_fantasia, m.razao_social) as empresa,
           greatest(v_ini, coalesce(x.admissao, x.created_at::date)) as ini, least(v_fim, coalesce(x.desligado_em, v_fim)) as fim
      from tecnicos x join empresas m on m.id = x.empresa_id
     where not x.perfil_teste and x.cpf is not null and (x.ativo or x.desligado_em >= v_ini)
  ), d as (
    select t.id, t.nome, t.empresa, g::date as dia, fn_ponto_jornada_dia(t.id, g::date) as j,
           fn_carga_minutos_dia(t.id, g::date) as contr
      from t cross join lateral generate_series(t.ini, t.fim, interval '1 day') g
     where t.ini <= t.fim
  ), f as (
    select id, nome, empresa,
           count(*) filter (where coalesce((j->>'he_escala_min')::int, 0) > v_lim) as dias_acima,
           max(coalesce((j->>'he_escala_min')::int, 0)) as maior_he_min,
           sum(coalesce((j->>'he_escala_min')::int, 0)) as he_mes_min,
           v_lim * count(*) filter (where contr > 0) as limite_mes_min,
           max(case when dia = v_hoje then coalesce((j->>'he_escala_min')::int, 0) end) as hoje_he_min,
           max(dia) filter (where coalesce((j->>'he_escala_min')::int, 0) > v_lim) as ultimo_dia
      from d group by id, nome, empresa
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'tecnico_id', f.id, 'tecnico', f.nome, 'empresa', f.empresa, 'dias_acima', f.dias_acima,
           'maior_he_min', f.maior_he_min, 'he_mes_min', f.he_mes_min, 'limite_mes_min', f.limite_mes_min,
           'hoje_he_min', coalesce(f.hoje_he_min, 0), 'hoje_acima', coalesce(f.hoje_he_min, 0) > v_lim,
           'ultimo_dia', f.ultimo_dia,
           'aceites', case when v_leitura then null else
                        (select count(*) from programacao_aceites a where a.tecnico_id = f.id and a.data between v_ini and v_fim) end)
         order by f.dias_acima desc, f.he_mes_min desc), '[]'::jsonb)
    into v_lista
    from f where f.dias_acima > 0 or f.he_mes_min > f.limite_mes_min;
  return jsonb_build_object(
    'mes', to_char(v_ini, 'MM/YYYY'), 'apurado_ate', v_fim, 'limite_dia_min', v_lim,
    'hoje', (select count(*) from jsonb_array_elements(v_lista) x where (x->>'hoje_acima')::boolean),
    'mes_total', jsonb_array_length(v_lista),
    'aceites_mes', case when v_leitura then null else (select count(*) from programacao_aceites a where a.data between v_ini and v_fim) end,
    'funcionarios', v_lista);
end $function$;

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
