-- 11 | Envio com botoes (Evolution 2.4.0) + opcao 1/2 no texto; reenvio apos falha em texto simples

update config set valor = '2.4.0' where chave = 'evolution_versao';

insert into config (chave, valor, descricao) values
  ('usar_botoes', 'true',
   'true: envia com botoes (e opcao 1/2 no texto). Reenvio apos falha sai sempre em texto simples.')
on conflict (chave) do update set valor = excluded.valor;

create or replace function fn_titulo_escala(p_escala_id uuid)
returns text language plpgsql stable as $$
declare
  v_data date;
  v_dias text[] := array['domingo','segunda-feira','terça-feira','quarta-feira',
                         'quinta-feira','sexta-feira','sábado'];
begin
  select data_servico into v_data from escalas where id = p_escala_id;
  return 'ESCALA — ' || to_char(v_data, 'DD/MM') || ', ' || v_dias[extract(dow from v_data)::int + 1];
end $$;

create or replace function fn_corpo_escala(p_escala_id uuid)
returns text language plpgsql stable as $$
declare
  r record;
begin
  select e.hora_inicio, e.duracao_prevista_min, e.descricao_tarefa,
         t.nome as tecnico, l.nome as local_nome, l.endereco, l.link_maps
    into r
  from escalas e
  join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id
  where e.id = p_escala_id;

  return 'Técnico: ' || r.tecnico || E'\n'
    || 'Início: ' || to_char(r.hora_inicio, 'HH24:MI')
    || coalesce(' (previsão ' || fn_fmt_duracao(r.duracao_prevista_min) || ')', '') || E'\n'
    || 'Local: ' || coalesce(r.local_nome, 'a confirmar') || E'\n'
    || case when coalesce(r.endereco, '') <> '' then 'Endereço: ' || r.endereco || E'\n' else '' end
    || case when coalesce(r.link_maps, '') <> '' then 'Mapa: ' || r.link_maps || E'\n' else '' end
    || 'Tarefa: ' || r.descricao_tarefa;
end $$;

create or replace function fn_msg_escala(p_escala_id uuid, p_lembrete boolean default false)
returns text language plpgsql stable as $$
begin
  return case when p_lembrete then '*LEMBRETE* — ainda sem sua confirmação' || E'\n\n' else '' end
    || '*' || fn_titulo_escala(p_escala_id) || '*' || E'\n\n'
    || fn_corpo_escala(p_escala_id) || E'\n\n'
    || 'Responda com o número:' || E'\n'
    || '*1* — Ciente, confirmado' || E'\n'
    || '*2* — Tenho um problema';
end $$;

create or replace function fn_payload_escala(
  p_escala_id uuid, p_telefone text, p_lembrete boolean, p_botoes boolean
) returns jsonb language plpgsql stable as $$
declare
  v_inst text := fn_config('evolution_instancia');
begin
  if p_botoes then
    return jsonb_build_object(
      'path', '/message/sendButtons/' || v_inst,
      'body', jsonb_build_object(
        'number', p_telefone,
        'title', case when p_lembrete then 'LEMBRETE — ' else '' end || fn_titulo_escala(p_escala_id),
        'description', fn_corpo_escala(p_escala_id) || E'\n\n'
                       || 'Confirme pelos botões abaixo ou responda *1* (confirmado) ou *2* (problema).',
        'footer', 'Infoxtec Escalas',
        'buttons', jsonb_build_array(
          jsonb_build_object('type', 'reply', 'displayText', 'Ciente, confirmado',
                             'id', 'conf:' || p_escala_id::text),
          jsonb_build_object('type', 'reply', 'displayText', 'Tenho um problema',
                             'id', 'prob:' || p_escala_id::text)
        )
      )
    );
  end if;

  return jsonb_build_object(
    'path', '/message/sendText/' || v_inst,
    'body', jsonb_build_object(
      'number', p_telefone,
      'text', fn_msg_escala(p_escala_id, p_lembrete),
      'delay', 1500
    )
  );
end $$;

-- Dispatcher (executado pelo pg_cron a cada minuto; ver supabase/setup/cron.sql)
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

  -- FASE 1: conferir o que a Evolution respondeu aos envios anteriores
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

  -- FASE 2: enviar
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

  -- FASE 3: acionar supervisores
  for a in
    select * from vw_acoes_pendentes
    where acao = 'escalonar' or (v_webhook and avisar_supervisor)
  loop
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then
      continue;
    end if;

    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);

    for s in select telefone_e164 from tecnicos where is_supervisor and ativo loop
      perform fn_evo_post(
        '/message/sendText/' || v_inst,
        jsonb_build_object('number', s.telefone_e164, 'text', v_texto)
      );
    end loop;

    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
  end loop;
end $$;
