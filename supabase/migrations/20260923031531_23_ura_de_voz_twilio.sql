-- 23 | Item 2: URA de voz (Twilio). O banco decide quem ligar; a Edge Function
--      "voz-escala" faz a chamada e serve o TwiML. Fraseologia final na migration 24.
-- Conteudo completo aplicado no banco: ver funcoes fn_preparar_ligacao, fn_voz_twiml,
-- fn_voz_resposta, fn_voz_status, app_ligacoes, app_ligar_escala e a tabela ligacoes.

create table if not exists ligacoes (
  id           uuid primary key default gen_random_uuid(),
  escala_id    uuid not null references escalas(id) on delete cascade,
  tecnico_id   uuid not null references tecnicos(id) on delete cascade,
  telefone     text not null,
  tentativa    int  not null default 1,
  call_sid     text unique,
  status       text not null default 'criada'
               check (status in ('criada','discando','atendida','sem_resposta','ocupado','falha','encerrada')),
  digito       text,
  duracao_seg  int,
  preco        numeric(10,4),
  erro         text,
  criada_em    timestamptz not null default now(),
  atendida_em  timestamptz,
  encerrada_em timestamptz
);
alter table ligacoes enable row level security;
create index if not exists idx_ligacoes_escala on ligacoes (escala_id);

insert into config (chave, valor, descricao) values
  ('ligacao_ativa',           'false', 'Liga o disparo automatico de ligacoes'),
  ('ligacao_apos_tentativas', '2',     'Tentativas de WhatsApp sem resposta antes de ligar'),
  ('ligacao_janela_inicio',   '08:00', 'Nao liga antes deste horario'),
  ('ligacao_janela_fim',      '20:00', 'Nao liga depois deste horario'),
  ('ligacao_max_por_escala',  '2',     'Maximo de ligacoes por escala'),
  ('ligacao_intervalo_min',   '45',    'Minutos entre duas ligacoes para a mesma escala'),
  ('ligacao_por_execucao',    '2',     'Maximo de ligacoes disparadas por execucao do dispatcher'),
  ('twilio_caller_id',        '',      'Numero verificado que aparece no visor do tecnico (+55...)'),
  ('voz_url',                 'https://zpckrxydqqmmcrphrkxz.supabase.co/functions/v1/voz-escala',
                                       'Edge Function que faz a ligacao e serve o TwiML'),
  ('voz_voice',               'Polly.Camila-Neural', 'Voz da Twilio usada na URA'),
  ('voz_timeout_dtmf',        '6',     'Segundos aguardando o tecnico digitar')
on conflict (chave) do nothing;

create or replace function fn_xml_escape(p text)
returns text language sql immutable set search_path = public, extensions as $$
  select replace(replace(replace(replace(coalesce(p,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

create or replace view vw_ligacoes_pendentes as
with agora as (select (now() at time zone fn_config('fuso')) as local_ts)
select
  e.id as escala_id, t.id as tecnico_id, t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(n.tentativa, 0) as tentativas_whatsapp,
  (select count(*) from ligacoes l where l.escala_id = e.id) as ligacoes_feitas
from escalas e
join tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in
left join lateral (select * from notificacoes where escala_id = e.id order by created_at desc limit 1) n on true
cross join agora g
where e.status = 'notificada'
  and (e.data_servico + e.hora_inicio) > now()
  and coalesce(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas')
  and n.status_envio in ('enviada','entregue','lida')
  and not exists (select 1 from respostas r where r.escala_id = e.id)
  and (select count(*) from ligacoes l where l.escala_id = e.id) < fn_config_int('ligacao_max_por_escala')
  and not exists (select 1 from ligacoes l where l.escala_id = e.id
                    and (l.status in ('criada','discando')
                         or l.criada_em > now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'))))
  and g.local_ts::time between fn_config('ligacao_janela_inicio')::time and fn_config('ligacao_janela_fim')::time;

create or replace function fn_preparar_ligacao(p_escala uuid)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A escala já foi respondida (%).', v_esc.status; end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
end $$;

create or replace function fn_registrar_call_sid(p_ligacao uuid, p_sid text, p_erro text default null)
returns void language plpgsql volatile set search_path = public, extensions as $$
begin
  if p_erro is not null then
    update ligacoes set status = 'falha', erro = left(p_erro, 500), encerrada_em = now() where id = p_ligacao;
  else
    update ligacoes set call_sid = p_sid, status = 'discando' where id = p_ligacao;
  end if;
end $$;

create or replace function fn_voz_resposta(p_ligacao uuid, p_digito text)
returns text language plpgsql volatile set search_path = public, extensions as $$
declare
  r record; v_voz text := coalesce(fn_config('voz_voice'), 'Polly.Camila-Neural');
  v_nome text; v_fala text; v_quando text;
begin
  select l.id, l.escala_id, l.tecnico_id, t.nome, e.status, e.data_servico, e.hora_inicio,
         coalesce(loc.nome, 'local a confirmar') as local_nome, t.telefone_e164 into r
  from ligacoes l join escalas e on e.id = l.escala_id join tecnicos t on t.id = l.tecnico_id
  left join locais loc on loc.id = e.local_id where l.id = p_ligacao;
  if not found then return '<?xml version="1.0" encoding="UTF-8"?><Response><Hangup/></Response>'; end if;

  v_nome := split_part(r.nome, ' ', 1);
  v_quando := to_char(r.data_servico, 'DD/MM') || ' às ' || to_char(r.hora_inicio, 'HH24:MI');
  update ligacoes set digito = p_digito, atendida_em = coalesce(atendida_em, now()),
         status = case when status in ('criada','discando') then 'atendida' else status end where id = p_ligacao;
  perform set_config('app.ator', 'ura: ' || r.nome, true);

  if p_digito = '1' and r.status in ('agendada','notificada') then
    update escalas set status = 'confirmada' where id = r.escala_id;
    insert into respostas (escala_id, tipo, texto_livre) values (r.escala_id, 'confirmacao', 'Confirmado por telefone (digitou 1)');
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_confirmada', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_wa_texto(r.telefone_e164, '✅ Confirmado, ' || v_nome || '! Escala de ' || v_quando || ' — ' || r.local_nome || '.');
    v_fala := 'Perfeito, ' || v_nome || ', escala confirmada! Bom trabalho amanhã. Até mais!';
  elsif p_digito = '2' and r.status in ('agendada','notificada') then
    update escalas set status = 'recusada' where id = r.escala_id;
    insert into respostas (escala_id, tipo, texto_livre) values (r.escala_id, 'problema', 'Recusado por telefone (digitou 2)');
    insert into ocorrencias (escala_id) values (r.escala_id);
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_recusada', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_wa_texto(r.telefone_e164, 'Recebido, ' || v_nome || '. Você negou a escala de ' || v_quando
      || ' pelo telefone. O supervisor já foi avisado. Se puder, descreva o problema em uma mensagem.');
    perform fn_avisar_supervisores('❌ *ESCALA NEGADA POR TELEFONE*' || E'\n\n' || r.nome || ' negou a escala de '
      || v_quando || ' — ' || r.local_nome || E'\n' || 'Telefone: ' || r.telefone_e164, r.tecnico_id);
    v_fala := 'Entendi. Vou avisar o supervisor, ele entra em contato. Obrigado, ' || v_nome || '!';
  elsif p_digito in ('1','2') then
    v_fala := 'Essa escala já tinha sido respondida. Obrigado, ' || v_nome || '!';
  else
    update ligacoes set status = case when status = 'atendida' then 'atendida' else 'sem_resposta' end where id = p_ligacao;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (r.escala_id, 'ligacao_sem_resposta', 'ura', jsonb_build_object('ligacao', p_ligacao));
    perform fn_avisar_supervisores('📞 *LIGAÇÃO SEM RESPOSTA*' || E'\n\n' || r.nome
      || ' não respondeu à ligação sobre a escala de ' || v_quando || ' — ' || r.local_nome
      || E'\n' || 'Telefone: ' || r.telefone_e164 || E'\n\n' || 'Vale ligar pessoalmente.', r.tecnico_id);
    v_fala := 'Sem problema. Vou pedir pro supervisor entrar em contato. Até mais!';
  end if;

  return '<?xml version="1.0" encoding="UTF-8"?><Response><Say voice="' || v_voz
      || '" language="pt-BR">' || fn_xml_escape(v_fala) || '</Say><Hangup/></Response>';
end $$;

create or replace function fn_voz_status(p_ligacao uuid, p_status text, p_duracao text, p_preco text)
returns void language plpgsql volatile set search_path = public, extensions as $$
declare
  v_map text := case lower(coalesce(p_status,''))
    when 'completed' then 'encerrada' when 'busy' then 'ocupado'
    when 'no-answer' then 'sem_resposta' when 'failed' then 'falha'
    when 'canceled' then 'falha' else null end;
begin
  update ligacoes set status = coalesce(v_map, status),
    duracao_seg = coalesce(nullif(p_duracao,'')::int, duracao_seg),
    preco = coalesce(abs(nullif(p_preco,'')::numeric), preco),
    encerrada_em = coalesce(encerrada_em, now())
  where id = p_ligacao;
end $$;

create or replace function app_ligacoes(p_escala uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'tentativa', tentativa, 'status', status, 'digito', digito,
    'duracao_seg', duracao_seg, 'criada_em', criada_em, 'erro', erro) order by criada_em)
    from ligacoes where escala_id = p_escala), '[]'::jsonb);
end $$;

create or replace function app_ligar_escala(p_escala uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_email text := app_exigir(array['admin','gestor']); v_req bigint; v_lig jsonb;
begin
  v_lig := fn_preparar_ligacao(p_escala);
  v_req := net.http_post(url := fn_config('voz_url') || '?acao=iniciar&token=' || fn_segredo('VOZ_TOKEN'),
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('ligacao_id', v_lig->>'ligacao_id'));
  insert into escala_eventos (escala_id, evento, ator) values (p_escala, 'ligacao_manual', v_email);
  return jsonb_build_object('ligacao_id', v_lig->>'ligacao_id', 'enfileirada', true);
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function app_ligacoes(uuid), app_ligar_escala(uuid) to authenticated;
