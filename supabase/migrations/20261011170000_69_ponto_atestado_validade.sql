-- Migration 69 (11/10/2026): validade do atestado bloqueia ponto e escala — decisão 60.
--
-- Pedido do responsável: o atestado tem validade obrigatória ("válido até"); do primeiro dia até a
-- validade o funcionário NÃO bate ponto (app, WhatsApp) e NÃO recebe escala, salvo se passar por nova
-- avaliação médica e der entrada no atestado de aptidão (alta médica), que encerra o afastamento na data
-- da alta. Vale a partir do envio (pedido pendente ou aprovado); atestado negado deixa de bloquear.
-- Risco aceito pelo responsável (decisão 60): a Portaria 671 trata de restrição à marcação de ponto.
-- O texto ao gestor diz só "afastado" (nunca o motivo de saúde).

insert into ponto_motivos (codigo, grupo, nome, base_legal, abrange, quantidade, unidade, janela, exige_anexo, saude, ativo, ordem)
values ('alta_medica', 'saude', 'Atestado de aptidão (alta médica): liberado para trabalhar',
        'NR-7 (PCMSO): avaliação médica de retorno; encerra o afastamento antes da validade do atestado',
        'periodo', null, null, null, true, true, true, 16)
on conflict (codigo) do nothing;

-- Até quando o funcionário está afastado no dia (null = não está) ------------------------------------
create or replace function fn_ponto_afastado_ate(p_tecnico uuid, p_data date)
returns date language sql stable set search_path = public, extensions as $$
  select max(j.data_fim) from ponto_justificativas j
   where j.tecnico_id = p_tecnico and j.motivo = 'atestado' and j.status in ('pendente', 'aprovada')
     and p_data between j.data and coalesce(j.data_fim, j.data)
     and not exists (select 1 from ponto_justificativas a
                      where a.tecnico_id = p_tecnico and a.motivo = 'alta_medica' and a.status in ('pendente', 'aprovada')
                        and a.data <= p_data and a.data >= j.data)
$$;

-- Ponto: nenhuma marcação dentro do afastamento (vale para app, WhatsApp e qualquer outro canal) --------
create or replace function fn_ponto_bloquear_afastado()
returns trigger language plpgsql set search_path = public, extensions as $$
declare v_ate date; v_fuso text;
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso from empresas e where e.id = new.empresa_id;
  v_ate := fn_ponto_afastado_ate(new.tecnico_id, (new.momento at time zone coalesce(v_fuso, 'America/Bahia'))::date);
  if v_ate is not null then
    raise exception 'Você está afastado por atestado até %. Para voltar antes, envie o atestado de aptidão (alta médica) no app do ponto, aba Ajuste.',
      to_char(v_ate, 'DD/MM');
  end if;
  return new;
end $$;
create or replace trigger trg_ponto_marcacoes_afastado before insert on ponto_marcacoes
  for each row execute function fn_ponto_bloquear_afastado();

-- Escala: não se escala técnico afastado (criar ou trocar técnico/data) -----------------------------------
create or replace function fn_escala_bloquear_afastado()
returns trigger language plpgsql set search_path = public, extensions as $$
declare v_ate date;
begin
  if new.status in ('cancelada', 'recusada', 'concluida') then return new; end if;
  v_ate := fn_ponto_afastado_ate(new.tecnico_id, new.data_servico);
  if v_ate is not null then
    raise exception 'Técnico afastado até %: escolha outro técnico para este dia.', to_char(v_ate, 'DD/MM');
  end if;
  return new;
end $$;
create or replace trigger trg_escalas_afastado before insert or update of tecnico_id, data_servico on escalas
  for each row execute function fn_escala_bloquear_afastado();

-- O motor não envia nem liga para escala de técnico afastado (escala criada antes do atestado) ---------
create or replace view vw_acoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE fn_config('fuso'::text)) AS local_ts
        ), alvo AS (
         SELECT e.id AS escala_id,
            e.status,
            e.supervisor_avisado_em,
            t.nome AS tecnico,
            t.telefone_e164 AS telefone,
            n.id AS notificacao_id,
            n.tentativa,
            n.status_envio,
            n.enviada_em
           FROM escalas e
             JOIN tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in
             LEFT JOIN LATERAL ( SELECT notificacoes.id,
                    notificacoes.escala_id,
                    notificacoes.tipo,
                    notificacoes.tentativa,
                    notificacoes.wa_message_id,
                    notificacoes.template_nome,
                    notificacoes.status_envio,
                    notificacoes.erro_codigo,
                    notificacoes.erro_mensagem,
                    notificacoes.payload_envio,
                    notificacoes.enviada_em,
                    notificacoes.entregue_em,
                    notificacoes.lida_em,
                    notificacoes.created_at,
                    notificacoes.http_req_id
                   FROM notificacoes
                  WHERE notificacoes.escala_id = e.id
                  ORDER BY notificacoes.created_at DESC
                 LIMIT 1) n ON true
          WHERE (e.status = ANY (ARRAY['agendada'::escala_status, 'notificada'::escala_status])) AND (e.data_servico + e.hora_inicio) > (( SELECT agora.local_ts
                   FROM agora))
            AND fn_ponto_afastado_ate(e.tecnico_id, e.data_servico) IS NULL
        )
 SELECT a.escala_id,
    a.status,
    a.tecnico,
    a.telefone,
    a.notificacao_id,
    a.tentativa,
    a.status_envio,
    a.enviada_em,
        CASE
            WHEN a.notificacao_id IS NULL THEN 'enviar_primeira'::text
            WHEN a.tentativa >= fn_config_int('max_tentativas'::text) THEN 'escalonar'::text
            WHEN a.status_envio = 'falha'::envio_status AND a.enviada_em < (now() - make_interval(mins => fn_config_int('timeout_entrega_min'::text))) THEN 'reenviar_falha'::text
            WHEN a.status_envio = 'enviada'::envio_status AND a.enviada_em < (now() - make_interval(mins => fn_config_int('timeout_entrega_min'::text))) THEN 'nao_recebeu'::text
            WHEN (a.status_envio = ANY (ARRAY['entregue'::envio_status, 'lida'::envio_status])) AND a.enviada_em < (now() - make_interval(mins => fn_config_int('intervalo_reenvio_min'::text))) THEN 'reenviar'::text
            ELSE NULL::text
        END AS acao,
        CASE
            WHEN a.status_envio = 'lida'::envio_status THEN 'leu e nao respondeu'::text
            WHEN a.status_envio = 'entregue'::envio_status THEN 'recebeu e nao leu'::text
            WHEN a.status_envio = 'enviada'::envio_status THEN 'nao recebeu'::text
            WHEN a.status_envio = 'falha'::envio_status THEN 'falha no envio'::text
            ELSE NULL::text
        END AS diagnostico,
    a.tentativa >= fn_config_int('avisar_supervisor_na'::text) AND a.supervisor_avisado_em IS NULL AS avisar_supervisor
   FROM alvo a,
    agora g
  WHERE g.local_ts::time without time zone >= fn_config('janela_envio_inicio'::text)::time without time zone AND g.local_ts::time without time zone <= fn_config('janela_envio_fim'::text)::time without time zone;
revoke all on vw_acoes_pendentes from anon, authenticated, service_role;

-- Ligações da URA: mesma regra (base: migration 64)
create or replace view vw_ligacoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE COALESCE(NULLIF(fn_config('fuso'::text), ''), 'America/Bahia')) AS local_ts
        )
 SELECT e.id AS escala_id,
    t.id AS tecnico_id,
    t.nome AS tecnico,
    t.telefone_e164 AS telefone,
    COALESCE(n.tentativa, 0) AS tentativas_whatsapp,
    ( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id) AS ligacoes_feitas
   FROM escalas e
     JOIN tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in AND NOT t.perfil_teste
     LEFT JOIN LATERAL ( SELECT notificacoes.id,
            notificacoes.escala_id,
            notificacoes.tipo,
            notificacoes.tentativa,
            notificacoes.wa_message_id,
            notificacoes.template_nome,
            notificacoes.status_envio,
            notificacoes.erro_codigo,
            notificacoes.erro_mensagem,
            notificacoes.payload_envio,
            notificacoes.enviada_em,
            notificacoes.entregue_em,
            notificacoes.lida_em,
            notificacoes.created_at,
            notificacoes.http_req_id
           FROM notificacoes
          WHERE notificacoes.escala_id = e.id
          ORDER BY notificacoes.created_at DESC
         LIMIT 1) n ON true
     CROSS JOIN agora g
  WHERE e.status = 'notificada'::escala_status AND e.local_id IS NOT NULL AND (e.data_servico + e.hora_inicio) > g.local_ts AND COALESCE(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas'::text) AND (n.status_envio = ANY (ARRAY['enviada'::envio_status, 'entregue'::envio_status, 'lida'::envio_status])) AND NOT (EXISTS ( SELECT 1
           FROM respostas r
          WHERE r.escala_id = e.id)) AND (( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id)) < fn_config_int('ligacao_max_por_escala'::text) AND NOT (EXISTS ( SELECT 1
           FROM ligacoes l
          WHERE l.escala_id = e.id AND ((l.status = ANY (ARRAY['criada'::text, 'discando'::text])) OR l.criada_em > (now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'::text)))))) AND COALESCE(fn_ligacao_permitida(), false)
    AND fn_ponto_afastado_ate(t.id, e.data_servico) IS NULL;
revoke all on vw_ligacoes_pendentes from anon, authenticated, service_role;

-- App: atestado exige a validade; alta médica é de um dia. Gestor avisado das escalas no afastamento ----
create or replace function ponto_justificar_atestado(p_token text, p_motivo text, p_data date, p_valido_ate date default null,
  p_observacao text default null, p_anexo text default null, p_anexo_tipo text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec   uuid := fn_ponto_sessao(p_token);
  r       jsonb;
  v_n     int;
  v_nome  text;
begin
  if p_motivo not in ('atestado', 'alta_medica') then raise exception 'Use este envio só para atestado ou alta médica.'; end if;
  if p_motivo = 'atestado' and p_valido_ate is null then raise exception 'Informe até quando vale o atestado.'; end if;
  r := ponto_justificar_falta(p_token, p_motivo, p_data, case when p_motivo = 'atestado' then p_valido_ate end,
                              null, null, p_observacao, p_anexo, p_anexo_tipo);
  if p_motivo = 'atestado' then
    select count(*), min(t.nome) into v_n, v_nome from escalas e join tecnicos t on t.id = e.tecnico_id
     where e.tecnico_id = v_tec and e.data_servico between p_data and p_valido_ate
       and e.status not in ('cancelada', 'recusada', 'concluida');
    if v_n > 0 then
      perform fn_ponto_avisar_supervisores(v_tec, '⚠️ *Ponto · ' || split_part(trim(v_nome), ' ', 1) || '*: afastado de '
        || to_char(p_data, 'DD/MM') || ' a ' || to_char(p_valido_ate, 'DD/MM') || ' (pedido nº ' || (r->>'numero') || '). '
        || v_n || ' escala(s) no período: escolha outro técnico.');
    end if;
  end if;
  return r || jsonb_build_object('escalas_no_periodo', coalesce(v_n, 0));
end $$;

-- Funcionário: o app sabe se ele está afastado (e até quando) -------------------------------------------
create or replace function ponto_eu(p_token text, p_versao_aviso text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v_r   jsonb;
begin
  select jsonb_build_object('nome', t.nome, 'empresa', coalesce(e.nome_fantasia, e.razao_social),
           'ciente', exists (select 1 from ponto_ciencias c where c.tecnico_id = t.id and c.versao = p_versao_aviso),
           'hoje', coalesce((select jsonb_agg(jsonb_build_object('nsr', m.nsr, 'tipo', m.tipo,
                     'hora', to_char(m.momento at time zone e.fuso, 'HH24:MI'), 'dentro_area', m.dentro_area)
                     order by m.momento)
                   from ponto_marcacoes m
                  where m.tecnico_id = t.id and (m.momento at time zone e.fuso)::date = (now() at time zone e.fuso)::date),
                  '[]'::jsonb),
           'afastado_ate', to_char(fn_ponto_afastado_ate(t.id, (now() at time zone coalesce(e.fuso, 'America/Bahia'))::date), 'DD/MM/YYYY'))
    into v_r
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = v_tec;
  return v_r;
end $function$;

-- Decidir (recriada da migration 68): alta médica só registra a liberação --------------------------------
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
  elsif j.motivo = 'alta_medica' then
    -- atestado de aptidão: só registra a liberação (o afastamento termina na data da alta); não abona
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || 'Liberação para o trabalho a partir de '
      || to_char(j.data, 'DD/MM') || ' registrada.';
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
