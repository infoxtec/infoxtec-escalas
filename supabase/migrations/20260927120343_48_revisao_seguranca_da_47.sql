-- 48 | Revisão de segurança da 47
-- 1. LGPD: saúde é dado sensível. O rótulo exibido (WhatsApp dos supervisores, painel) passa a ser
--    "Motivo pessoal"; o valor gravado continua 'saude' para uso restrito (decisão 38).
-- 2. Edição de escala não vira canal de mensagem: no mínimo 2 minutos entre edições da mesma
--    escala, e escala de teste não manda mensagem ao técnico.

create or replace function fn_motivo_rotulo(p text)
returns text language sql immutable
set search_path = public, extensions as $$
  select case p
    when 'saude' then 'Motivo pessoal' when 'transporte' then 'Transporte'
    when 'conflito_agenda' then 'Conflito de agenda' when 'falta_material' then 'Falta de material'
    when 'outro' then 'Outro' else 'Não informado' end
$$;

create or replace function fn_edicao_permitida(p_escala uuid)
returns void language plpgsql
set search_path = public, extensions as $$
begin
  if exists (select 1 from escala_eventos where escala_id = p_escala and evento = 'escala_editada'
               and created_at > now() - interval '2 minutes') then
    raise exception 'Esta escala acabou de ser editada. Aguarde 2 minutos para editar de novo.';
  end if;
end $$;

create or replace function app_editar_escala(p jsonb)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
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
begin
  select * into e from escalas where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar escala em rascunho, agendada, aguardando resposta ou confirmada.';
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
    raise exception 'O técnico já tem outra escala ativa nesse dia e horário.';
  end;

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
          '⚠️ *ESCALA ALTERADA*' || E'\n\n' || 'Sua escala mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, v_tent,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua escala de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
          || ' foi atualizada: ' || left(v_tarefa, 500));
      end if;
    end if;
  end if;

  return jsonb_build_object('alterada', true, 'nova_confirmacao', v_reconf);
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
