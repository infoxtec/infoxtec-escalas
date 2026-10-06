-- Migration 56 (07/10/2026): Módulo Registro de Ponto — WhatsApp (backlog 083) e acompanhamento do
-- gestor (backlog 090), decisão 48, docs/modulo-registro-de-ponto/plano.md F3.
--
-- WhatsApp: o funcionário escreve "ponto" (ou entrada, almoço, volta, saída, HE...), escolhe a
-- marcação, manda a LOCALIZAÇÃO ATUAL e recebe o comprovante (CPF mascarado: o canal passa pela
-- Evolution e pela Meta). Localização escolhida no mapa (com nome ou endereço) é recusada.
-- A conversa do ponto é interceptada antes do fluxo de escalas (fn_ponto_wh); o que não é do ponto
-- segue para fn_wh_mensagem, sem mudança.
-- Lembrete amigável da saída para o almoço (o retorno é do funcionário): fn_ponto_lembrete_almoco,
-- agendada no pg_cron só na produção (supabase/setup/cron.sql).
--
-- Painel: app_ponto_acompanhamento (marcações com origem do login) e app_ponto_hoje (quem já bateu,
-- quem tem escala e não bateu entrada, quantas fora da área).

-- Conversa do ponto no WhatsApp -------------------------------------------------------------------

create table if not exists ponto_conversas (
  tecnico_id  uuid primary key references tecnicos(id) on delete cascade,
  etapa       text not null check (etapa in ('escolher_tipo', 'aguardando_local')),
  tipo        text check (tipo in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he')),
  expira_em   timestamptz not null
);
comment on table ponto_conversas is 'Conversa do ponto em andamento no WhatsApp (10 minutos). Não guarda conteúdo de mensagem.';
alter table ponto_conversas enable row level security;
revoke all on ponto_conversas from anon, authenticated, service_role;

-- Uma mensagem do WhatsApp gera no máximo uma marcação (o webhook pode repetir a entrega)
create unique index if not exists ponto_marcacoes_msg_id_uk on ponto_marcacoes ((origem ->> 'msg_id'))
  where origem ? 'msg_id';

insert into config (chave, valor, descricao) values
  ('ponto_lembrete_almoco', '12:00', 'App do ponto: a partir desta hora (fuso da empresa), quem marcou entrada e ainda não saiu para o almoço recebe um lembrete amigável, uma vez por dia.')
on conflict (chave) do nothing;

create or replace function fn_ponto_rotulo(p_tipo text)
returns text language sql immutable set search_path = public, extensions as $$
  select case p_tipo when 'entrada' then 'Entrada' when 'saida_almoco' then 'Saída para almoço'
    when 'volta_almoco' then 'Volta do almoço' when 'saida' then 'Saída'
    when 'inicio_he' then 'Início de hora extra' when 'fim_he' then 'Fim de hora extra' end
$$;

-- Próxima marcação esperada, a partir da última do dia
create or replace function fn_ponto_proximo(p_ultima text)
returns text language sql immutable set search_path = public, extensions as $$
  select case coalesce(p_ultima, '') when '' then 'entrada' when 'entrada' then 'saida_almoco'
    when 'saida_almoco' then 'volta_almoco' when 'volta_almoco' then 'saida' when 'saida' then 'inicio_he'
    when 'inicio_he' then 'fim_he' else 'entrada' end
$$;

-- Envio do ponto pelo WhatsApp: falha de envio nunca desfaz a marcação (o envio é assíncrono, pelo
-- pg_net; o erro aqui é de configuração, como a chave ausente na homologação)
create or replace function fn_ponto_wa(p_tel text, p_texto text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  perform fn_wa_texto(p_tel, p_texto);
exception when others then
  raise warning 'ponto: envio pelo WhatsApp falhou: %', sqlerrm;
end $$;

-- Devolve null quando a mensagem não é do ponto (o fluxo de escalas segue normalmente).
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
  v_menu   text;
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
    -- localização encaminhada é de outra pessoa
    if coalesce(v_loc->'contextInfo'->>'isForwarded', '') = 'true'
       or coalesce(v_loc->'contextInfo'->>'forwardingScore', '0') <> '0' then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Localização encaminhada não vale para o ponto. Mande a *sua localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_encaminhada');
    end if;
    v_lat := (v_loc->>'degreesLatitude')::numeric;
    v_lng := (v_loc->>'degreesLongitude')::numeric;
    v_prec := nullif(v_loc->>'accuracyInMeters', '')::numeric::int;
    if v_lat is null or v_lng is null then return null; end if;
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
      || 'Autenticação: ' || (c->>'autenticacao'));
    return jsonb_build_object('acao', 'ponto_registrado', 'nsr', c->'nsr');
  end if;

  -- 2. Texto: palavra do ponto ou escolha do menu
  -- número só vale como escolha do menu se não for resposta citando outra mensagem (ex.: a escala)
  if v_conv.tecnico_id is not null and v_conv.etapa = 'escolher_tipo' and v_norm ~ '^[1-6]$'
     and v_msg->'extendedTextMessage'->'contextInfo'->>'stanzaId' is null then
    v_tipo := (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[v_norm::int];
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
    v_menu := 'Qual marcação, ' || split_part(v_tec.nome, ' ', 1) || '? Responda o número:' || E'\n'
      || '*1* Entrada' || E'\n' || '*2* Saída para almoço' || E'\n' || '*3* Volta do almoço' || E'\n'
      || '*4* Saída' || E'\n' || '*5* Início de hora extra' || E'\n' || '*6* Fim de hora extra' || E'\n\n'
      || 'Sugestão agora: *' || fn_ponto_rotulo(fn_ponto_proximo(v_ultima)) || '*';
    insert into ponto_conversas (tecnico_id, etapa, tipo, expira_em)
    values (v_tec.id, 'escolher_tipo', null, now() + interval '10 minutes')
    on conflict (tecnico_id) do update set etapa = 'escolher_tipo', tipo = null, expira_em = excluded.expira_em;
    perform fn_ponto_wa(v_tec.telefone_e164, v_menu);
    return jsonb_build_object('acao', 'ponto_menu');
  else
    return null;   -- não é do ponto: segue para as escalas
  end if;

  insert into ponto_conversas (tecnico_id, etapa, tipo, expira_em)
  values (v_tec.id, 'aguardando_local', v_tipo, now() + interval '10 minutes')
  on conflict (tecnico_id) do update set etapa = 'aguardando_local', tipo = excluded.tipo, expira_em = excluded.expira_em;
  perform fn_ponto_wa(v_tec.telefone_e164,
    '*' || fn_ponto_rotulo(v_tipo) || '*. Agora mande a sua *localização atual*:' || E'\n'
    || '📎 → Localização → *Enviar localização atual*.' || E'\n\n'
    || 'A hora registrada é a do recebimento da localização.');
  return jsonb_build_object('acao', 'ponto_pediu_localizacao', 'tipo', v_tipo);
end $$;

-- Webhook da Evolution: a conversa do ponto vem antes do fluxo de escalas
create or replace function fn_webhook_evolution(p_token text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_log    bigint;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
  v_pl     jsonb := p_payload - 'apikey';
begin
  if p_token is null or p_token = '' or p_token is distinct from fn_segredo('WEBHOOK_TOKEN') then
    raise exception 'token invalido';
  end if;

  -- LGPD: a localização do ponto já fica na marcação; o log do webhook não guarda outra cópia
  if v_pl->'data'->'message' ?| array['locationMessage', 'liveLocationMessage'] then
    v_pl := jsonb_set(v_pl, '{data,message}',
      ((v_pl->'data'->'message') - 'locationMessage' - 'liveLocationMessage') || '{"localizacao": true}');
  end if;
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
end $$;

-- Lembrete amigável da saída para o almoço: uma vez por dia, a quem marcou entrada e não saiu.
-- O retorno do almoço não tem lembrete (decisão do responsável, 06/10).
create or replace function fn_ponto_lembrete_almoco()
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  t record;
  v_n int := 0;
begin
  for t in
    select tc.id, tc.nome, tc.telefone_e164, e.fuso
      from tecnicos tc join empresas e on e.id = tc.empresa_id
     where tc.ativo and tc.opt_in and tc.cpf is not null
       and (now() at time zone e.fuso)::time >= coalesce(fn_config('ponto_lembrete_almoco'), '12:00')::time
       and (now() at time zone e.fuso)::time < time '15:00'
       and (select m.tipo from ponto_marcacoes m
             where m.tecnico_id = tc.id and (m.momento at time zone e.fuso)::date = (now() at time zone e.fuso)::date
             order by m.nsr desc limit 1) = 'entrada'
  loop
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_almoco_' || t.id, (now() at time zone t.fuso)::date, now(), true, '{}'::jsonb)
    on conflict do nothing;
    if found then
      perform fn_ponto_wa(t.telefone_e164,
        '🍽️ Bom almoço, ' || split_part(t.nome, ' ', 1) || '! Quando sair para o intervalo, lembre de marcar: escreva *almoço* aqui.');
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- Painel: acompanhamento do gestor (backlog 090) ---------------------------------------------------

create or replace function app_ponto_acompanhamento(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, nsr bigint, empresa text, tecnico_id uuid, tecnico text, momento timestamptz,
               data text, hora text, tipo text, canal text, local text, distancia_m int, dentro_area boolean,
               login_origem text, gestor text, autenticacao text, latitude numeric, longitude numeric,
               ajustada boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_leitura boolean;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
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
      left join locais l on l.id = m.local_id
     where (m.momento at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or m.tecnico_id = p_tecnico)
     order by m.momento desc;
end $$;

-- Situação de hoje por funcionário com ponto: escala do dia, última marcação, pendência de entrada
create or replace function app_ponto_hoje()
returns table (tecnico_id uuid, tecnico text, empresa text, escala_hora text, escala_local text,
               marcacoes int, ultima_tipo text, ultima_hora text, fora_area int, situacao text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    with base as (
      select t.id, t.nome, coalesce(e.nome_fantasia, e.razao_social) as emp, e.fuso,
             (now() at time zone e.fuso)::date as hoje
        from tecnicos t join empresas e on e.id = t.empresa_id
       where t.ativo and t.cpf is not null
    ), r as (
    select b.id, b.nome, b.emp,
           (select left(min(s.hora_inicio)::text, 5) from escalas s
             where s.tecnico_id = b.id and s.data_servico = b.hoje and s.status not in ('cancelada', 'recusada')) as esc_hora,
           (select l.nome from escalas s join locais l on l.id = s.local_id
             where s.tecnico_id = b.id and s.data_servico = b.hoje and s.status not in ('cancelada', 'recusada')
             order by s.hora_inicio limit 1) as esc_local,
           (select count(*)::int from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje) as qtd,
           (select m.tipo from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje order by m.nsr desc limit 1) as ult_tipo,
           (select to_char(m.momento at time zone b.fuso, 'HH24:MI') from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje order by m.nsr desc limit 1) as ult_hora,
           (select count(*)::int from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje and m.dentro_area is false) as fora,
           case
             when exists (select 1 from ponto_marcacoes m where m.tecnico_id = b.id
                           and (m.momento at time zone b.fuso)::date = b.hoje) then 'com_marcacao'
             when exists (select 1 from escalas s where s.tecnico_id = b.id and s.data_servico = b.hoje
                           and s.status not in ('cancelada', 'recusada')
                           and s.hora_inicio < (now() at time zone b.fuso)::time) then 'sem_entrada'
             else 'sem_marcacao'
           end as sit
      from base b
    )
    -- quem tem escala e não bateu entrada vem primeiro
    select r.* from r order by case r.sit when 'sem_entrada' then 0 when 'com_marcacao' then 1 else 2 end, r.nome;
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
