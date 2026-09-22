-- 17 | Jornada CLT calculada automaticamente, tecnicos sem escala,
--      alerta aos supervisores com prazo (18h) da escala do dia seguinte

insert into config (chave, valor, descricao) values
  ('jornada_min',          '480',   'Jornada diaria normal sem hora extra, em minutos legais (CLT: 8h = 480)'),
  ('intervalo_min',        '60',    'Intervalo intrajornada quando a jornada passa de 6h (CLT art. 71)'),
  ('intervalo_apos_min',   '240',   'Minutos trabalhados antes do intervalo'),
  ('noturno_inicio',       '22:00', 'Inicio do horario noturno urbano (CLT art. 73)'),
  ('noturno_fim',          '05:00', 'Fim do horario noturno urbano'),
  ('hora_noturna_min',     '52.5',  'Duracao da hora noturna reduzida em minutos de relogio'),
  ('alerta_escala_aviso',  '16:00', 'Horario do lembrete aos supervisores sobre a escala do dia seguinte'),
  ('alerta_escala_prazo',  '18:00', 'Prazo para enviar a escala do dia seguinte'),
  ('alerta_dias_semana',   '1,2,3,4,5', 'Dias que exigem escala (ISO: 1=seg ... 7=dom). O alerta sai na vespera.'),
  ('sem_escala_incluir_supervisores', 'false', 'true: supervisores tambem contam como tecnicos sem escala')
on conflict (chave) do nothing;

create or replace function fn_calcular_jornada(p_inicio time)
returns table (turno text, trabalho_min int, intervalo_min int, minutos_noturnos int, hora_fim time)
language plpgsql stable
set search_path = public, extensions as $$
declare
  v_alvo      numeric := coalesce(fn_config_int('jornada_min'), 480);
  v_interv    int     := coalesce(fn_config_int('intervalo_min'), 60);
  v_apos      int     := coalesce(fn_config_int('intervalo_apos_min'), 240);
  v_n_ini     int     := extract(hour from fn_config('noturno_inicio')::time)::int * 60
                         + extract(minute from fn_config('noturno_inicio')::time)::int;
  v_n_fim     int     := extract(hour from fn_config('noturno_fim')::time)::int * 60
                         + extract(minute from fn_config('noturno_fim')::time)::int;
  v_fator     numeric := 60.0 / coalesce(fn_config('hora_noturna_min')::numeric, 52.5);
  v_ini       int     := extract(hour from p_inicio)::int * 60 + extract(minute from p_inicio)::int;
  -- Sumula 60 TST: jornada iniciada entre o inicio do noturno e meia-noite, prorrogada apos o fim
  v_prorroga  boolean := v_ini >= v_n_ini or v_ini = 0;
  v_legal     numeric := 0;
  v_t         int := 0;
  v_trab      int := 0;
  v_not       int := 0;
  v_pausou    boolean := false;
  v_m         int;
  v_noite     boolean;
begin
  while v_legal < v_alvo and v_t < 1440 loop
    if not v_pausou and v_alvo > 360 and v_trab >= v_apos then
      v_t := v_t + v_interv;
      v_pausou := true;
      continue;
    end if;
    v_m := (v_ini + v_t) % 1440;
    v_noite := v_prorroga or v_m >= v_n_ini or v_m < v_n_fim;
    v_legal := v_legal + case when v_noite then v_fator else 1 end;
    v_trab := v_trab + 1;
    if v_noite then v_not := v_not + 1; end if;
    v_t := v_t + 1;
  end loop;

  turno := case when v_not = 0 then 'diurno' when v_not = v_trab then 'noturno' else 'misto' end;
  trabalho_min := v_trab;
  intervalo_min := case when v_pausou then v_interv else 0 end;
  minutos_noturnos := v_not;
  hora_fim := (p_inicio + make_interval(mins => v_t))::time;
  return next;
end $$;

alter table escalas add column if not exists turno text;
alter table escalas add column if not exists hora_fim_prevista time;
alter table escalas add column if not exists intervalo_min int;
alter table escalas add column if not exists minutos_noturnos int;

create or replace function fn_aplicar_jornada()
returns trigger language plpgsql
set search_path = public, extensions as $$
declare
  j record;
begin
  select * into j from fn_calcular_jornada(new.hora_inicio);
  new.turno                := j.turno;
  new.duracao_prevista_min := j.trabalho_min;
  new.intervalo_min        := j.intervalo_min;
  new.minutos_noturnos     := j.minutos_noturnos;
  new.hora_fim_prevista    := j.hora_fim;
  return new;
end $$;

drop trigger if exists trg_escalas_jornada on escalas;
create trigger trg_escalas_jornada
  before insert or update of hora_inicio on escalas
  for each row execute function fn_aplicar_jornada();

update escalas set hora_inicio = hora_inicio;

create or replace function fn_corpo_escala(p_escala_id uuid)
returns text language plpgsql stable
set search_path = public, extensions as $$
declare
  r record;
  v_jornada text;
begin
  select e.hora_inicio, e.hora_fim_prevista, e.turno, e.duracao_prevista_min, e.intervalo_min,
         e.descricao_tarefa, t.nome as tecnico, l.nome as local_nome, l.endereco, l.link_maps
    into r
  from escalas e
  join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id
  where e.id = p_escala_id;

  v_jornada := case r.turno
    when 'noturno' then 'Jornada noturna: 8h CLT (' || fn_fmt_duracao(r.duracao_prevista_min) || ' de relógio)'
    when 'misto'   then 'Jornada mista: 8h CLT (' || fn_fmt_duracao(r.duracao_prevista_min) || ' de relógio)'
    else 'Jornada: ' || fn_fmt_duracao(r.duracao_prevista_min)
  end || case when coalesce(r.intervalo_min, 0) > 0
              then ' + ' || fn_fmt_duracao(r.intervalo_min) || ' de intervalo' else '' end;

  return 'Técnico: ' || r.tecnico || E'\n'
    || 'Início: ' || to_char(r.hora_inicio, 'HH24:MI')
    || coalesce(' · Término previsto: ' || to_char(r.hora_fim_prevista, 'HH24:MI'), '') || E'\n'
    || v_jornada || E'\n'
    || 'Local: ' || coalesce(r.local_nome, 'a confirmar') || E'\n'
    || case when coalesce(r.endereco, '') <> '' then 'Endereço: ' || r.endereco || E'\n' else '' end
    || case when coalesce(r.link_maps, '') <> '' then 'Mapa: ' || r.link_maps || E'\n' else '' end
    || 'Tarefa: ' || r.descricao_tarefa;
end $$;

create or replace view vw_escalas_painel as
select
  e.id, e.data_servico, e.hora_inicio,
  t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(l.nome, '-') as local, coalesce(l.endereco, '') as endereco, l.link_maps,
  e.descricao_tarefa, e.status, e.prioridade,
  n.tipo as ultimo_envio_tipo, n.tentativa, n.status_envio, n.enviada_em, n.entregue_em, n.lida_em,
  r.tipo as resposta, r.recebida_em as respondida_em,
  e.supervisor_avisado_em,
  case
    when e.status in ('confirmada','concluida','em_execucao') then 'verde'
    when e.status in ('recusada','cancelada')                 then 'vermelho'
    when e.supervisor_avisado_em is not null                  then 'vermelho'
    when e.status = 'notificada'                              then 'ambar'
    else 'cinza'
  end as semaforo,
  (e.status not in ('confirmada','recusada','em_execucao','concluida')
   and r.tipo is null
   and not exists (select 1 from notificacoes x
                   where x.escala_id = e.id
                     and (x.status_envio in ('entregue','lida') or x.entregue_em is not null))
  ) as pode_remover,
  e.turno, e.hora_fim_prevista, e.duracao_prevista_min, e.intervalo_min, e.minutos_noturnos
from escalas e
join tecnicos t on t.id = e.tecnico_id
left join locais l on l.id = e.local_id
left join lateral (
  select * from notificacoes where escala_id = e.id order by created_at desc limit 1
) n on true
left join lateral (
  select * from respostas where escala_id = e.id order by recebida_em desc limit 1
) r on true;
revoke all on vw_escalas_painel from anon, authenticated;

create or replace function fn_pendencias_escala(p_data date)
returns jsonb language sql stable
set search_path = public, extensions as $$
  with alvo as (
    select t.id, t.nome, t.funcao
    from tecnicos t
    where t.ativo
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data and e.status <> 'cancelada')
  )
  select jsonb_build_object(
    'data', p_data,
    'total_tecnicos', (select count(*) from alvo),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho'),
    'prazo', fn_config('alerta_escala_prazo'),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
  )
$$;

create table if not exists alertas_enviados (
  tipo       text not null,
  data_ref   date not null,
  enviado_em timestamptz not null default now(),
  enviado    boolean not null default true,
  detalhe    jsonb,
  primary key (tipo, data_ref)
);
alter table alertas_enviados enable row level security;

create or replace function fn_alerta_prazo_escala()
returns void language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
begin
  if not (extract(isodow from v_amanha)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))) then
    return;
  end if;

  foreach v_tipo in array array['aviso', 'prazo'] loop
    v_hora := fn_config(case v_tipo when 'aviso' then 'alerta_escala_aviso' else 'alerta_escala_prazo' end)::time;
    continue when v_agora::time < v_hora;
    continue when exists (select 1 from alertas_enviados where tipo = v_tipo and data_ref = v_amanha);

    if v_agora::time > v_hora + interval '2 hours'
       or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
      insert into alertas_enviados (tipo, data_ref, enviado) values (v_tipo, v_amanha, false);
      continue;
    end if;

    v_p    := fn_pendencias_escala(v_amanha);
    v_qtd  := jsonb_array_length(v_p->'sem_escala');
    v_rasc := (v_p->>'rascunhos')::int;
    insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
    values (v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

    continue when v_qtd = 0 and v_rasc = 0;

    select string_agg('• ' || (x->>'nome'), E'\n')
      into v_nomes
    from (select x from jsonb_array_elements(v_p->'sem_escala') x limit 15) s;
    if v_qtd > 15 then v_nomes := v_nomes || E'\n• e mais ' || (v_qtd - 15); end if;

    v_texto := case v_tipo
      when 'aviso' then '⏰ *ESCALA DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
      else '⚠️ *PRAZO DA ESCALA ENCERRADO*'
    end || E'\n\n'
      || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
      || case when v_qtd > 0 then v_qtd || ' técnico(s) sem escala:' || E'\n' || v_nomes || E'\n\n' else '' end
      || case when v_rasc > 0 then v_rasc || ' escala(s) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
      || case v_tipo
           when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
           else 'A equipe precisa receber a escala ainda hoje.'
         end;

    perform fn_avisar_supervisores(v_texto);
  end loop;
end $$;

-- Dispatcher com a fase 4 (fases 1 a 3 identicas a migration 11)
create or replace function fn_dispatcher_whatsapp()
returns void
language plpgsql security definer
set search_path = public, extensions
as $$
declare
  n         record;
  r_resp    record;
  a         record;
  s         record;
  v_wa_id   text;
  v_req     bigint;
  v_tent    int;
  v_texto   text;
  v_payload jsonb;
  v_botoes  boolean;
  v_sent    int := 0;
  v_limite  int := coalesce(fn_config_int('envios_por_execucao'), 3);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst    text := fn_config('evolution_instancia');
begin
  perform set_config('app.ator', 'dispatcher', true);

  for n in
    select id, escala_id, http_req_id, created_at
    from notificacoes
    where status_envio = 'enfileirada' and http_req_id is not null
  loop
    select status_code, content, error_msg into r_resp
    from net._http_response where id = n.http_req_id;

    if not found then
      if n.created_at < now() - interval '5 minutes' then
        update notificacoes
           set status_envio = 'falha', erro_codigo = 'timeout',
               erro_mensagem = 'Sem resposta da Evolution em 5 minutos'
         where id = n.id;
      end if;
      continue;
    end if;

    if r_resp.status_code in (200, 201) then
      begin
        v_wa_id := (r_resp.content::jsonb) -> 'key' ->> 'id';
      exception when others then
        v_wa_id := null;
      end;
      update notificacoes set status_envio = 'enviada', wa_message_id = v_wa_id where id = n.id;
      update escalas set status = 'notificada' where id = n.escala_id and status = 'agendada';
    else
      update notificacoes
         set status_envio  = 'falha',
             erro_codigo   = coalesce(r_resp.status_code::text, 'rede'),
             erro_mensagem = left(coalesce(r_resp.content, r_resp.error_msg, 'erro desconhecido'), 500)
       where id = n.id;
    end if;
  end loop;

  for a in
    select * from vw_acoes_pendentes
    where acao in ('enviar_primeira', 'reenviar_falha', 'reenviar', 'nao_recebeu')
    order by enviada_em nulls first
  loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar', 'nao_recebeu') then
      continue;
    end if;

    v_tent    := coalesce(a.tentativa, 0) + 1;
    v_botoes  := v_usar_botoes and a.acao <> 'reenviar_falha';
    v_payload := fn_payload_escala(a.escala_id, a.telefone, a.acao = 'reenviar', v_botoes);
    v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');

    insert into notificacoes
      (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
    values
      (a.escala_id,
       (case when v_tent = 1 then 'primeira'
             when a.acao = 'reenviar_falha' then 'reenvio_falha'
             else 'lembrete' end)::notificacao_tipo,
       v_tent,
       case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
       'enfileirada', v_payload, now(), v_req);

    v_sent := v_sent + 1;
  end loop;

  for a in
    select * from vw_acoes_pendentes
    where acao = 'escalonar' or (v_webhook and avisar_supervisor)
  loop
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then
      continue;
    end if;
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    for s in select telefone_e164 from tecnicos where is_supervisor and ativo loop
      perform fn_evo_post('/message/sendText/' || v_inst,
                          jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
    end loop;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
  end loop;

  begin
    perform fn_alerta_prazo_escala();
  exception when others then
    raise warning 'alerta de prazo falhou: %', sqlerrm;
  end;
end $$;

create or replace function app_pendencias(p_data date)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return fn_pendencias_escala(p_data);
end $$;

create or replace function app_config()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return (select jsonb_object_agg(chave, valor) from config
          where chave in ('jornada_min','intervalo_min','intervalo_apos_min','noturno_inicio',
                          'noturno_fim','hora_noturna_min','alerta_escala_aviso','alerta_escala_prazo',
                          'alerta_dias_semana'));
end $$;

create or replace function app_simular_jornada(p_inicio time)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  j record;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select * into j from fn_calcular_jornada(p_inicio);
  return to_jsonb(j);
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  app_meu_acesso(), app_escalas(date, date), app_resumo(date, date), app_linha_do_tempo(uuid),
  app_tecnicos(), app_locais(),
  app_criar_escalas(uuid[], uuid, date, time, text, int, text, boolean),
  app_mudar_status(uuid, text), app_remover_escala(uuid), app_reenviar_escala(uuid),
  app_salvar_tecnico(jsonb), app_excluir_tecnico(uuid), app_salvar_local(jsonb),
  app_usuarios(), app_salvar_usuario(text, text, text, boolean),
  app_pendencias(date), app_config(), app_simular_jornada(time)
to authenticated;
