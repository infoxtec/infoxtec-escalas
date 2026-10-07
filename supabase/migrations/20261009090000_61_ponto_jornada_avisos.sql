-- Migration 61 (08/10/2026): Módulo Registro de Ponto — jornada e avisos (backlog 084, entrega 1).
--
-- Cálculo da jornada do dia a partir das marcações (fn_ponto_jornada_dia) e avisos pela CLT, que
-- NUNCA bloqueiam a marcação (decisão 48: sinaliza, nunca bloqueia):
--   * intervalo intrajornada (art. 71): abaixo de 1 h (pedido do responsável, 08/10) — aviso ao
--     funcionário ANTES de registrar a volta e, depois de registrada, ao funcionário e ao gestor;
--     acima de 2 h; jornada de mais de 6 h sem intervalo; de 4 a 6 h, mínimo de 15 min;
--   * hora extra acima de 2 h no dia (art. 59);
--   * interjornada abaixo de 11 h (art. 66);
--   * atraso na entrada em relação à escala, acima de 5 min (art. 58, §1º) — só no espelho.
-- Gestor avisado uma vez por dia por tipo de aviso (alertas_enviados). Painel: app_ponto_espelho.
-- Limite conhecido: o dia é a data local da marcação; jornada que cruza a meia-noite fica dividida
-- (tratar com a regra da convenção coletiva, L2).

insert into config (chave, valor, descricao) values
  ('ponto_intervalo_max_min', '120', 'Ponto: intervalo intrajornada máximo, em minutos (CLT art. 71).'),
  ('ponto_intervalo_curto_min', '15', 'Ponto: intervalo mínimo para jornada de 4 a 6 horas, em minutos (CLT art. 71, §1º).'),
  ('ponto_he_limite_min', '120', 'Ponto: limite de hora extra por dia, em minutos (CLT art. 59).'),
  ('ponto_interjornada_min', '660', 'Ponto: descanso mínimo entre jornadas, em minutos (CLT art. 66).'),
  ('ponto_tolerancia_min', '5', 'Ponto: tolerância de variação por marcação, em minutos (CLT art. 58, §1º: até 5 min por marcação, no máximo 10 min no dia).')
on conflict (chave) do nothing;

create or replace function fn_ponto_hm(p_min int)
returns text language sql immutable set search_path = public, extensions as $$
  select case when p_min is null then null
              else (p_min / 60)::text || 'h' || lpad((p_min % 60)::text, 2, '0') end
$$;

-- Jornada de um funcionário num dia (data local da empresa). Horários em HH:MI, durações em minutos.
create or replace function fn_ponto_jornada_dia(p_tecnico uuid, p_data date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
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
  v_hoje    boolean;
  v_al      text[] := '{}';
  v_jornada int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_int_min int := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  v_int_max int := coalesce(nullif(fn_config('ponto_intervalo_max_min'), '')::int, 120);
  v_int_cur int := coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15);
  v_he_lim  int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_ij_min  int := coalesce(nullif(fn_config('ponto_interjornada_min'), '')::int, 660);
  v_tol     int := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_hoje := p_data >= (now() at time zone v_fuso)::date;

  for m in select tipo, momento from ponto_marcacoes
            where tecnico_id = p_tecnico
              and momento >= (p_data::timestamp at time zone v_fuso)
              and momento < ((p_data + 1)::timestamp at time zone v_fuso)
            order by momento, nsr loop
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
  if v_n = 0 then return null; end if;

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
  elsif v_normal > 360 then
    v_al := array_append(v_al, 'sem_intervalo');
  end if;
  -- hora extra (CLT art. 59)
  if v_extra > v_he_lim then v_al := array_append(v_al, 'he_acima_limite'); end if;
  -- interjornada (CLT art. 66): da última saída antes desta entrada
  if v_ent is not null then
    select max(momento) into v_ant from ponto_marcacoes
     where tecnico_id = p_tecnico and tipo in ('saida', 'fim_he')
       and momento < v_ent and momento > v_ent - interval '2 days';
    if v_ant is not null then
      v_inter := (extract(epoch from v_ent - v_ant) / 60)::int;
      if v_inter < v_ij_min then v_al := array_append(v_al, 'interjornada_curta'); end if;
    end if;
  end if;
  -- atraso em relação à escala (CLT art. 58, §1º)
  select min(s.hora_inicio) into v_esc from escalas s
   where s.tecnico_id = p_tecnico and s.data_servico = p_data and s.status not in ('cancelada', 'recusada');
  if v_esc is not null and v_ent is not null then
    v_atraso := (extract(epoch from (v_ent at time zone v_fuso)::time - v_esc) / 60)::int;
    if v_atraso > v_tol then v_al := array_append(v_al, 'atraso'); else v_atraso := null; end if;
  end if;
  -- dia já encerrado com marcação faltando
  if not v_hoje and (v_ent is null or v_sai is null or (v_sa is null) <> (v_va is null) or v_he_ini is not null) then
    v_al := array_append(v_al, 'incompleta');
  end if;

  return jsonb_build_object(
    'entrada', to_char(v_ent at time zone v_fuso, 'HH24:MI'),
    'saida_almoco', to_char(v_sa at time zone v_fuso, 'HH24:MI'),
    'volta_almoco', to_char(v_va at time zone v_fuso, 'HH24:MI'),
    'saida', to_char(v_sai at time zone v_fuso, 'HH24:MI'),
    'trabalhado_min', case when v_normal is null and v_he = 0 then null else v_total end,
    'intervalo_min', v_int, 'he_min', v_extra, 'interjornada_min', v_inter,
    'escala_hora', left(v_esc::text, 5), 'atraso_min', v_atraso,
    'marcacoes', v_n, 'alertas', to_jsonb(v_al));
end $$;

-- Aviso ANTES de registrar: volta do almoço com intervalo ainda abaixo do mínimo. Não bloqueia.
create or replace function fn_ponto_aviso_previo(p_tecnico uuid, p_tipo text)
returns text language plpgsql stable set search_path = public, extensions as $$
declare
  v_fuso text;
  v_sa   timestamptz;
  v_min  int;
  v_lim  int;
begin
  if p_tipo is distinct from 'volta_almoco' then return null; end if;
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  select max(momento) into v_sa from ponto_marcacoes
   where tecnico_id = p_tecnico and tipo = 'saida_almoco'
     and momento >= ((now() at time zone v_fuso)::date::timestamp at time zone v_fuso);
  if v_sa is null then return null; end if;
  v_min := (extract(epoch from now() - v_sa) / 60)::int;
  if v_min >= v_lim then return null; end if;
  return '⚠️ *Atenção:* seu intervalo está em *' || v_min || ' min*, abaixo de *' || fn_ponto_hm(v_lim)
      || '* — mínimo da CLT para jornada acima de 6 horas (art. 71). '
      || 'Se registrar a volta agora, a marcação vale, mas o gestor será avisado.';
exception when others then
  -- aviso nunca atrapalha a marcação
  raise warning 'ponto: aviso prévio falhou: %', sqlerrm;
  return null;
end $$;

-- Depois de registrar: avisos de jornada ligados a esta marcação. Devolve as linhas para o
-- funcionário e avisa os supervisores DA MESMA EMPRESA (com autorização de contato, fora dos perfis
-- de teste) uma vez por dia por tipo de aviso. Qualquer erro aqui só vira warning: a marcação já
-- registrada nunca é desfeita por causa de um aviso.
create or replace function fn_ponto_avisar(p_tecnico uuid, p_tipo text)
returns text[] language plpgsql volatile set search_path = public, extensions as $$
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
  select t.nome, t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
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
      when 'intervalo_curto'    then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                     || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_min')::int) || ' hoje, acima do limite de 2 horas por dia (CLT art. 59).'
      when 'sem_intervalo'      then 'Jornada de mais de 6 horas sem intervalo registrado (CLT art. 71).'
      when 'interjornada_curta' then 'Descanso de ' || fn_ponto_hm((j->>'interjornada_min')::int) || ' desde a última saída, abaixo das 11 horas entre jornadas (CLT art. 66).'
    end;
    v_saida := v_saida || ('⚠️ ' || v_func || ' A marcação vale; o gestor será avisado.');
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_' || a || '_' || p_tecnico, v_data, now(), true, jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_gest := '⚠️ *Ponto · ' || v_nome || '* (' || to_char(v_data, 'DD/MM') || '): ' || v_func;
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
end $$;

-- App do funcionário: a resposta da marcação traz os avisos de jornada (definição da migration 55)
create or replace function ponto_bater(p_token text, p_tipo text, p_lat numeric, p_lng numeric,
                                       p_precisao integer default null, p_app_versao text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v_login text;
  v_gestor text;
  c jsonb;
begin
  select login_origem, criado_por into v_login, v_gestor from ponto_sessoes where token_hash = fn_sha256(p_token);
  c := fn_ponto_registrar(v_tec, p_tipo, 'app', p_lat, p_lng, p_precisao,
                          jsonb_build_object('app_versao', p_app_versao, 'login_origem', v_login, 'gestor', v_gestor));
  return c || jsonb_build_object('avisos', to_jsonb(fn_ponto_avisar(v_tec, p_tipo)));
end $$;

-- App do funcionário: aviso antes de registrar (intervalo abaixo do mínimo)
create or replace function ponto_aviso_previo(p_token text, p_tipo text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return fn_ponto_aviso_previo(v_tec, p_tipo);
end $$;

-- Painel: espelho de jornada (previsto × realizado) por funcionário e dia
create or replace function app_ponto_espelho(p_de date, p_ate date, p_tecnico uuid default null)
returns table (tecnico_id uuid, tecnico text, data date, escala_hora text, entrada text, saida_almoco text,
               volta_almoco text, saida text, trabalhado_min int, intervalo_min int, he_min int,
               atraso_min int, interjornada_min int, alertas text[])
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    with dias as (
      select distinct m.tecnico_id as tid, (m.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date as dia
        from ponto_marcacoes m join empresas e on e.id = m.empresa_id
       where m.momento >= p_de::timestamp - interval '1 day' and m.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or m.tecnico_id = p_tecnico)
    ), j as (
      select d.tid, d.dia, fn_ponto_jornada_dia(d.tid, d.dia) as x from dias d where d.dia between p_de and p_ate
    )
    select j.tid, t.nome, j.dia, j.x->>'escala_hora', j.x->>'entrada', j.x->>'saida_almoco', j.x->>'volta_almoco',
           j.x->>'saida', (j.x->>'trabalhado_min')::int, (j.x->>'intervalo_min')::int, (j.x->>'he_min')::int,
           (j.x->>'atraso_min')::int, (j.x->>'interjornada_min')::int,
           array(select jsonb_array_elements_text(j.x->'alertas'))
      from j join tecnicos t on t.id = j.tid
     order by j.dia desc, t.nome;
end $$;

-- Conversa do ponto (definição da migration 60, com o aviso antes da volta e os avisos no comprovante)
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

-- Permissões por laço (decisões 12 e 49) -----------------------------------------------------------
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
