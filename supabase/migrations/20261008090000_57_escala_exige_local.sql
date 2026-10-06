-- Migration 57 (08/10/2026): escala nunca é criada nem enviada sem local (pedido urgente do
-- responsável). Até aqui o local era opcional ("a confirmar"): fn_criar_escala gravava nullif(local)
-- e a importação mandava null quando o local da planilha não casava.
--
-- 1. Gatilho em escalas: inserir sem local, ou apagar o local de uma escala, é recusado. Vale para
--    todos os caminhos (painel, importação, lote, edição), porque fica na tabela.
-- 2. fn_payload_escala (o único ponto que monta a mensagem da escala para o WhatsApp: motor,
--    reenvio e edição) recusa escala sem local. Escala antiga sem local não sai: o motor registra a
--    falha na própria escala e, esgotadas as tentativas, avisa o supervisor.
-- 3. URA: fn_preparar_ligacao (motor e botão "ligar" do painel) recusa escala sem local, e
--    vw_ligacoes_pendentes deixa de listá-la.
-- 4. fn_evolution_falhando não conta falha interna (como escala sem local) como Evolution caída.

create or replace function fn_escala_exige_local()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if new.local_id is null and (tg_op = 'INSERT' or old.local_id is not null) then
    raise exception 'Escolha o local da escala. Escala sem local não é criada nem enviada.';
  end if;
  return new;
end $$;

create or replace trigger trg_escalas_exige_local
  before insert or update of local_id on escalas
  for each row execute function fn_escala_exige_local();

create or replace function fn_payload_escala(p_escala_id uuid, p_telefone text, p_lembrete boolean, p_botoes boolean)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_inst text := fn_config('evolution_instancia');
begin
  if exists (select 1 from escalas where id = p_escala_id and local_id is null) then
    raise exception 'Escala sem local não é enviada. Escolha o local e reenvie.';
  end if;

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

-- URA: nunca liga para escala sem local (definição atual da homologação + guarda)
create or replace function fn_preparar_ligacao(p_escala uuid)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status, e.local_id into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A escala já foi respondida (%).', v_esc.status; end if;
  if v_esc.local_id is null then
    raise exception 'Escala sem local não é enviada nem ligada. Escolha o local.';
  end if;

  if not fn_pode_enviar(v_esc.telefone_e164) then
    raise exception 'Ambiente de homologação: só é possível ligar para cadastros de teste. % não é um.', v_esc.nome;
  end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
end $$;

create or replace view vw_ligacoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE fn_config('fuso'::text)) AS local_ts
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
          WHERE l.escala_id = e.id AND ((l.status = ANY (ARRAY['criada'::text, 'discando'::text])) OR l.criada_em > (now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'::text)))))) AND g.local_ts::time without time zone >= fn_config('ligacao_janela_inicio'::text)::time without time zone AND g.local_ts::time without time zone <= fn_config('ligacao_janela_fim'::text)::time without time zone;

-- Falha interna (ex.: escala sem local) não é Evolution caída: não dispara o /fail do monitor
create or replace function fn_evolution_falhando()
returns boolean language sql stable set search_path = public, extensions as $$
  select count(*) filter (where status_envio = 'falha' and erro_codigo is distinct from 'interno') >= 2
     and count(*) filter (where status_envio in ('enviada', 'entregue', 'lida')) = 0
    from notificacoes
   where created_at > now() - interval '15 minutes'
$$;

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
