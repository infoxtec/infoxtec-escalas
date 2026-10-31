-- Multiempresa F8b, encerrar e reabrir a conta de um cliente (decisão 129). Encerrar para tudo na hora: o painel (a
-- conta some do seletor), o envio pelo WhatsApp (fn_evo_destino), o motor e a URA (as filas só veem contas ativas), o
-- app do ponto (sessões encerradas, códigos vencidos e fn_ponto_sessao) e a entrada do webhook. Os dados ficam; a
-- exclusão vem 30 dias depois (apagar_em, F8d). Até lá a plataforma reabre e tudo volta, menos as sessões do ponto
-- (o funcionário entra de novo). A suspensão manual (ativa = false, tela Contas) passa a parar o envio, o motor e a URA
-- também; o app do ponto e a entrada do webhook seguem (suspender não pode impedir o funcionário de bater o ponto).

set lock_timeout = '5s';

alter table interno.contas
  add column encerrada_em timestamptz,
  add column apagar_em timestamptz,
  add constraint contas_encerrada_tem_prazo check (estado <> 'encerrada' or (encerrada_em is not null and apagar_em is not null));

alter table interno.plataforma_log drop constraint plataforma_log_acao_check,
  add constraint plataforma_log_acao_check
  check (acao in ('criar_conta', 'alterar_conta', 'monitor_externo', 'canal_whatsapp', 'encerrar_conta', 'reabrir_conta'));

-- o ponto único de checagem: só a conta ativa (estado 'ativa' e não suspensa) opera
create or replace function interno.fn_conta_operante(p_conta uuid)
 returns boolean
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce((select ativa from interno.contas where id = p_conta), false);
$function$;

-- encerrar: só a plataforma; a operadora nunca encerra; motivo obrigatório; 30 dias até apagar
create or replace function public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator   text := interno.fn_exigir_plataforma();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  c        interno.contas;
  v_sess   int;
begin
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A conta da operadora não pode ser encerrada.';
  end if;
  if length(v_motivo) not between 3 and 300 then
    raise exception 'Informe o motivo do encerramento (3 a 300 caracteres).';
  end if;
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then raise exception 'A conta já está encerrada.'; end if;
  update interno.contas set ativa = false, estado = 'encerrada', encerrada_em = now(), apagar_em = now() + interval '30 days'
   where id = p_conta returning * into c;
  -- app do ponto: sessões encerradas e códigos vencidos já agora
  update interno.ponto_sessoes s set encerrada_em = now(), motivo = 'conta encerrada'
    from interno.tecnicos t where t.id = s.tecnico_id and t.conta_id = p_conta and s.encerrada_em is null;
  get diagnostics v_sess = row_count;
  update interno.ponto_codigos k set expira_em = now()
    from interno.tecnicos t where t.id = k.tecnico_id and t.conta_id = p_conta and k.usado_em is null and k.expira_em > now();
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'encerrar_conta', p_conta, jsonb_build_object('motivo', v_motivo, 'apagar_em', c.apagar_em, 'sessoes_ponto', v_sess));
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
end $function$;

-- reabrir: só dentro do prazo; a conta volta ativa e sem suspensão (canal e módulos não mudaram)
create or replace function public.app_plataforma_reabrir_conta(p_conta uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  c      interno.contas;
begin
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'encerrada' then raise exception 'Só uma conta encerrada pode ser reaberta.'; end if;
  if c.apagar_em <= now() then raise exception 'O prazo para reabrir acabou: a conta está na fila de exclusão.'; end if;
  update interno.contas set estado = 'ativa', ativa = true, encerrada_em = null, apagar_em = null where id = p_conta;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'reabrir_conta', p_conta, jsonb_build_object('encerrada_em', c.encerrada_em));
end $function$;

CREATE OR REPLACE FUNCTION interno.fn_evo_destino(p_path text, p_numero text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_inst  text := fn_config('evolution_instancia');
  v_conta uuid := fn_conta_do_numero(p_numero);
  c       conta_canais;
begin
  if v_conta is null then return null; end if;   -- número em mais de uma conta: não adivinha
  if not fn_conta_operante(v_conta) then return null; end if;   -- conta encerrada ou suspensa (F8b): nada sai
  if v_conta = '00000000-0000-0000-0000-000000000001' then
    return jsonb_build_object('conta', v_conta, 'url', fn_config('evolution_url'), 'path', p_path, 'instancia', v_inst,
                              'segredo', 'EVOLUTION_API_KEY');
  end if;
  select * into c from conta_canais where conta_id = v_conta and ativo;
  if not found then return null; end if;
  return jsonb_build_object('conta', v_conta, 'url', c.url, 'instancia', c.instancia, 'segredo', c.segredo,
                            'path', left(p_path, length(p_path) - length(coalesce(v_inst, ''))) || c.instancia);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_sessao(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_id uuid; v_tec uuid;
begin
  select s.id, s.tecnico_id into v_id, v_tec from ponto_sessoes s join tecnicos t on t.id = s.tecnico_id
     join contas c on c.id = t.conta_id and c.estado = 'ativa'   -- conta encerrada (F8b): o app não entra; suspensa, entra
   where s.token_hash = fn_sha256(coalesce(p_token, '')) and s.encerrada_em is null
     and s.expira_em > now() and t.ativo;
  if v_id is null then raise exception 'Sessão encerrada. Entre novamente.'; end if;
  update ponto_sessoes set ultimo_uso = now() where id = v_id;
  return v_tec;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_webhook_conta(p_token text, p_instancia text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare c conta_canais; v text;
begin
  if p_instancia is null or p_instancia = fn_config('evolution_instancia') then
    if fn_webhook_token_ok(p_token) then return '00000000-0000-0000-0000-000000000001'; end if;
    raise exception 'token invalido';
  end if;
  select * into c from conta_canais where instancia = p_instancia and ativo and webhook_segredo is not null;
  v := case when found then fn_segredo(c.webhook_segredo) end;
  if v is null or coalesce(p_token, '') = '' or extensions.digest(p_token, 'sha256') <> extensions.digest(v, 'sha256') then
    raise exception 'token invalido';
  end if;
  -- conta encerrada (F8b): o evento não entra (a resposta é a mesma do token errado); suspensa, entra
  if (select estado from contas where id = c.conta_id) is distinct from 'ativa' then raise exception 'token invalido'; end if;
  return c.conta_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.app_plataforma_salvar_conta(p_id uuid, p_nome text, p_ativa boolean, p_modulos text[], p_uf text DEFAULT NULL::text, p_municipio text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_nome text := btrim(p_nome);
  v_uf   text;
  v_mun  text;
  c      interno.contas;
begin
  select * into c from interno.contas where id = p_id for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then
    raise exception 'Conta encerrada: para voltar a usar, reabra a conta (até 30 dias depois do encerramento).';
  end if;
  -- parâmetro nulo (painel anterior à 3.52.0) mantém a sede; texto vazio limpa
  v_uf  := case when p_uf is null then c.uf else upper(nullif(btrim(p_uf), '')) end;
  v_mun := case when p_municipio is null then c.municipio else nullif(btrim(p_municipio), '') end;
  if v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if v_mun is not null and v_uf is null then
    raise exception 'Informe a UF da sede junto com o município.';
  end if;
  if length(v_mun) > 120 then
    raise exception 'Município com no máximo 120 caracteres.';
  end if;
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if exists (select 1 from interno.contas where lower(nome) = lower(v_nome) and id <> p_id) then
    raise exception 'Já existe uma conta com este nome.';
  end if;
  -- a operadora não se desliga (o motor e os alertas da plataforma rodam nela)
  if p_id = '00000000-0000-0000-0000-000000000001' and not coalesce(p_ativa, true) then
    raise exception 'A conta da operadora não pode ser desativada.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;

  begin
    update interno.contas set nome = v_nome, ativa = coalesce(p_ativa, ativa),
           uf = v_uf, municipio = v_mun where id = p_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo, ativo)
  select p_id, m, m = any (p_modulos) from unnest(array['escala', 'ponto']) m
  on conflict (conta_id, modulo) do update
     set ativo = excluded.ativo,
         desde = case when conta_modulos.ativo <> excluded.ativo then now() else conta_modulos.desde end;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'alterar_conta', p_id, jsonb_build_object(
    'nome', case when c.nome <> v_nome then jsonb_build_array(c.nome, v_nome) end,
    'ativa', case when c.ativa <> coalesce(p_ativa, c.ativa) then p_ativa end,
    'sede', case when c.uf is distinct from v_uf or c.municipio is distinct from v_mun
                 then jsonb_build_array(c.uf, c.municipio, v_uf, v_mun) end,
    'modulos', p_modulos));
end $function$
;

CREATE OR REPLACE FUNCTION public.app_plataforma_contas()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'ativa', c.ativa, 'estado', c.estado, 'encerrada_em', c.encerrada_em, 'apagar_em', c.apagar_em, 'criada_em', c.criada_em, 'uf', c.uf, 'municipio', c.municipio,
      'membros', (select count(*) from interno.conta_membros m where m.conta_id = c.id and m.ativo),
      'admins', coalesce((select jsonb_agg(m.email order by m.email) from interno.conta_membros m
                           where m.conta_id = c.id and m.ativo and m.papel = 'admin'), '[]'::jsonb),
      'modulos', coalesce((select jsonb_agg(cm.modulo order by cm.modulo) from interno.conta_modulos cm
                            where cm.conta_id = c.id and cm.ativo), '[]'::jsonb),
      'provisionamento', interno.fn_conta_provisionamento(c.id))
    order by c.criada_em) from interno.contas c), '[]'::jsonb);
end $function$
;

create or replace view interno.vw_acoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE interno.fn_config('fuso'::text)) AS local_ts
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
           FROM interno.escalas e
             JOIN interno.tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in
             JOIN interno.contas c ON c.id = e.conta_id AND c.ativa
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
                   FROM interno.notificacoes
                  WHERE notificacoes.escala_id = e.id
                  ORDER BY notificacoes.created_at DESC
                 LIMIT 1) n ON true
          WHERE (e.status = ANY (ARRAY['agendada'::public.escala_status, 'notificada'::public.escala_status])) AND (e.data_servico + e.hora_inicio) > (( SELECT agora.local_ts
                   FROM agora)) AND interno.fn_ponto_afastado_ate(e.tecnico_id, e.data_servico) IS NULL
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
            WHEN a.tentativa >= interno.fn_config_int('max_tentativas'::text) THEN 'escalonar'::text
            WHEN a.status_envio = 'falha'::public.envio_status AND a.enviada_em < (now() - make_interval(mins => interno.fn_config_int('timeout_entrega_min'::text))) THEN 'reenviar_falha'::text
            WHEN a.status_envio = 'enviada'::public.envio_status AND a.enviada_em < (now() - make_interval(mins => interno.fn_config_int('timeout_entrega_min'::text))) THEN 'nao_recebeu'::text
            WHEN (a.status_envio = ANY (ARRAY['entregue'::public.envio_status, 'lida'::public.envio_status])) AND a.enviada_em < (now() - make_interval(mins => interno.fn_config_int('intervalo_reenvio_min'::text))) THEN 'reenviar'::text
            ELSE NULL::text
        END AS acao,
        CASE
            WHEN a.status_envio = 'lida'::public.envio_status THEN 'leu e nao respondeu'::text
            WHEN a.status_envio = 'entregue'::public.envio_status THEN 'recebeu e nao leu'::text
            WHEN a.status_envio = 'enviada'::public.envio_status THEN 'nao recebeu'::text
            WHEN a.status_envio = 'falha'::public.envio_status THEN 'falha no envio'::text
            ELSE NULL::text
        END AS diagnostico,
    a.tentativa >= interno.fn_config_int('avisar_supervisor_na'::text) AND a.supervisor_avisado_em IS NULL AS avisar_supervisor
   FROM alvo a,
    agora g
  WHERE g.local_ts::time without time zone >= interno.fn_config('janela_envio_inicio'::text)::time without time zone AND g.local_ts::time without time zone <= interno.fn_config('janela_envio_fim'::text)::time without time zone;

create or replace view interno.vw_ligacoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE COALESCE(NULLIF(interno.fn_config('fuso'::text), ''::text), 'America/Bahia'::text)) AS local_ts
        )
 SELECT e.id AS escala_id,
    t.id AS tecnico_id,
    t.nome AS tecnico,
    t.telefone_e164 AS telefone,
    COALESCE(n.tentativa, 0) AS tentativas_whatsapp,
    ( SELECT count(*) AS count
           FROM interno.ligacoes l
          WHERE l.escala_id = e.id) AS ligacoes_feitas
   FROM interno.escalas e
     JOIN interno.tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in AND NOT t.perfil_teste
     JOIN interno.contas c ON c.id = e.conta_id AND c.ativa
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
           FROM interno.notificacoes
          WHERE notificacoes.escala_id = e.id
          ORDER BY notificacoes.created_at DESC
         LIMIT 1) n ON true
     CROSS JOIN agora g
  WHERE e.status = 'notificada'::public.escala_status AND e.local_id IS NOT NULL AND (e.data_servico + e.hora_inicio) > g.local_ts AND COALESCE(n.tentativa, 0) >= interno.fn_config_int('ligacao_apos_tentativas'::text) AND (n.status_envio = ANY (ARRAY['enviada'::public.envio_status, 'entregue'::public.envio_status, 'lida'::public.envio_status])) AND NOT (EXISTS ( SELECT 1
           FROM interno.respostas r
          WHERE r.escala_id = e.id)) AND (( SELECT count(*) AS count
           FROM interno.ligacoes l
          WHERE l.escala_id = e.id)) < interno.fn_config_int('ligacao_max_por_escala'::text) AND NOT (EXISTS ( SELECT 1
           FROM interno.ligacoes l
          WHERE l.escala_id = e.id AND ((l.status = ANY (ARRAY['criada'::text, 'discando'::text])) OR l.criada_em > (now() - make_interval(mins => interno.fn_config_int('ligacao_intervalo_min'::text)))))) AND COALESCE(interno.fn_ligacao_permitida(now(), e.id), false) AND interno.fn_ponto_afastado_ate(t.id, e.data_servico) IS NULL;


do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
