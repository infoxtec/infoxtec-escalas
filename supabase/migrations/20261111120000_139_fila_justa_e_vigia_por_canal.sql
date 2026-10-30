-- Multiempresa F5c: fila justa e teto por conta no motor, avisos que dizem a conta e vigia do WhatsApp de cada cliente
-- (decisão 127). Os envios a partir de uma pessoa conhecida (supervisor, funcionário do ponto, espelho) passam a dizer a
-- conta dela, então o telefone repetido em duas contas não impede mais o aviso; avisos de sistema saem pela operadora.

set lock_timeout = '5s';

insert into interno.config (chave, valor, descricao) values
  ('envios_por_conta_por_execucao', '3', 'Fila justa: envios de escala por conta em cada execução do motor (rodízio entre as contas)')
on conflict (chave) do nothing;

-- vigia de cada canal de cliente
alter table interno.conta_canais
  add column vig_req bigint,
  add column vig_estado text,
  add column vig_falhas int not null default 0,
  add column vig_fora_desde timestamptz,
  add column vig_alertado_em timestamptz,
  add column vig_verificado_em timestamptz;

-- envios com a conta dita: o contexto vale só durante o envio e volta ao que era
create or replace function interno.fn_wa_texto_na_conta(p_conta uuid, p_telefone text, p_texto text)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ant text := current_setting('trilha.conta', true);
begin
  perform set_config('trilha.conta', coalesce(p_conta::text, ''), true);
  perform fn_wa_texto(p_telefone, p_texto);
  perform set_config('trilha.conta', coalesce(v_ant, ''), true);
end $function$;

create or replace function interno.fn_ponto_wa_na_conta(p_conta uuid, p_tel text, p_texto text)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ant text := current_setting('trilha.conta', true);
begin
  perform set_config('trilha.conta', coalesce(p_conta::text, ''), true);
  perform fn_ponto_wa(p_tel, p_texto);
  perform set_config('trilha.conta', coalesce(v_ant, ''), true);
end $function$;

create or replace function interno.fn_evo_post_na_conta(p_conta uuid, p_path text, p_body jsonb)
 returns bigint
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ant text := current_setting('trilha.conta', true); v_req bigint;
begin
  perform set_config('trilha.conta', coalesce(p_conta::text, ''), true);
  v_req := fn_evo_post(p_path, p_body);
  perform set_config('trilha.conta', coalesce(v_ant, ''), true);
  return v_req;
end $function$;

-- vigia dos canais dos clientes: mesma regra do vigia da operadora (2 voltas fora de "open" = e-mail, uma vez; outro
-- na volta); cada canal com a própria chave
create or replace function interno.fn_vigiar_canais()
 returns int
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  c record;
  v_resp record;
  v_estado text;
  v_limite int := greatest(coalesce(fn_config_int('evolution_alerta_falhas'), 2), 1);
  v_fuso text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_chave text;
  v_n int := 0;
begin
  for c in select k.*, ct.nome as conta_nome from conta_canais k join contas ct on ct.id = k.conta_id
            where k.ativo for update of k skip locked loop
    v_estado := null;
    if c.vig_req is not null then
      select r.status_code, r.content into v_resp from net._http_response r where r.id = c.vig_req;
      if found then
        begin
          v_estado := case when v_resp.status_code = 200 then left(coalesce(
                        (v_resp.content::jsonb #>> '{instance,state}'), (v_resp.content::jsonb ->> 'state'), 'desconhecido'), 30)
                      else 'sem_resposta' end;
        exception when others then v_estado := 'sem_resposta';
        end;
        delete from net._http_response where id = c.vig_req;
      elsif c.vig_verificado_em < now() - interval '4 minutes' then
        v_estado := 'sem_resposta';
      end if;
    end if;
    if v_estado = 'open' then
      if c.vig_alertado_em is not null then
        perform fn_alerta_email('Trilha: WhatsApp de ' || left(c.conta_nome, 60) || ' de volta',
          'O WhatsApp da conta ' || c.conta_nome || ' (instância ' || c.instancia || ') voltou às '
          || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || '. Ficou fora desde '
          || to_char(c.vig_fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || '.');
      end if;
      update conta_canais set vig_estado = v_estado, vig_falhas = 0, vig_fora_desde = null, vig_alertado_em = null
       where conta_id = c.conta_id;
    elsif v_estado is not null then
      update conta_canais set vig_estado = v_estado, vig_falhas = vig_falhas + 1, vig_fora_desde = coalesce(vig_fora_desde, now())
       where conta_id = c.conta_id returning vig_falhas, vig_fora_desde into c.vig_falhas, c.vig_fora_desde;
      if c.vig_falhas >= v_limite and c.vig_alertado_em is null then
        perform fn_alerta_email('Trilha: WhatsApp de ' || left(c.conta_nome, 60) || ' fora do ar',
          'O WhatsApp da conta ' || c.conta_nome || ' (instância ' || c.instancia || ') está fora do ar desde '
          || to_char(c.vig_fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || ' (estado: ' || v_estado || ').' || E'\n\n'
          || 'As programações e os avisos dessa conta não saem até o cliente reconectar o celular (QR code no Manager da '
          || 'Evolution). Quando voltar, você recebe outro e-mail.');
        update conta_canais set vig_alertado_em = now() where conta_id = c.conta_id;
      end if;
    end if;
    begin
      v_chave := fn_segredo(c.segredo);
      update conta_canais set vig_verificado_em = now(),
             vig_req = case when v_chave is null then null else net.http_get(
               url := c.url || '/instance/connectionState/' || c.instancia, headers := jsonb_build_object('apikey', v_chave)) end,
             vig_estado = case when v_chave is null then 'sem_chave' else vig_estado end
       where conta_id = c.conta_id;
    exception when others then
      update conta_canais set vig_req = null, vig_estado = 'erro_interno', vig_verificado_em = now() where conta_id = c.conta_id;
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- avisos que dizem a conta (o resto igual às definições da homologação)
CREATE OR REPLACE FUNCTION interno.fn_avisar_supervisores(p_texto text, p_exceto uuid DEFAULT NULL::uuid, p_empresa uuid DEFAULT NULL::uuid, p_conta uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
  v_n int := 0;
  v_emp uuid := coalesce(p_empresa, (select t.empresa_id from tecnicos t where t.id = p_exceto));
  -- sem conta (alerta de sistema, como o motor parado): todos, como antes (decisão 107)
  v_conta uuid := coalesce(p_conta, (select t.conta_id from tecnicos t where t.id = p_exceto),
                           (select e.conta_id from empresas e where e.id = p_empresa));
begin
  for s in
    select telefone_e164, conta_id from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
      and (v_emp is null or empresa_id = v_emp)
      and (v_conta is null or conta_id = v_conta)
  loop
    perform fn_wa_texto_na_conta(s.conta_id, s.telefone_e164, p_texto);   -- F5c: canal da conta do supervisor
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_avisar_tecnico(p_texto text)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_tel text;
  v_n   int := 0;
begin
  for v_tel in
    select distinct trim(t) from unnest(string_to_array(coalesce(fn_config('alerta_tecnico_telefones'), ''), ',')) t
     where trim(t) <> ''
       and trim(t) not in (select telefone_e164 from tecnicos where is_supervisor and ativo)  -- ja avisados
  loop
    perform fn_wa_texto_na_conta('00000000-0000-0000-0000-000000000001', v_tel, p_texto);   -- F5c: aviso de sistema sai pelo canal da operadora
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_avisar(p_tecnico uuid, p_tipo text)
 RETURNS text[]
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  v_contr int;
  v_minimo int;
  v_sa    timestamptz;
  v_he    text;
begin
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;

  -- saída para o intervalo: quando pode voltar (15 min de 4 a 6 h, 1 h acima de 6 h na jornada do dia)
  if p_tipo = 'saida_almoco' then
    v_contr := fn_carga_minutos_dia(p_tecnico, v_data);
    v_minimo := case when v_contr > 360 then v_lim
                     when v_contr > 240 then coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15) end;
    if v_minimo is not null then
      select max(momento) into v_sa from ponto_marcacoes
       where tecnico_id = p_tecnico and tipo = 'saida_almoco' and momento >= v_data::timestamp at time zone v_fuso;
      if v_sa is not null then
        v_saida := v_saida || ('🍽️ Bom intervalo! Retorno a partir de '
          || to_char((v_sa + make_interval(mins => v_minimo)) at time zone v_fuso, 'HH24:MI')
          || ' (intervalo mínimo de ' || fn_ponto_hm(v_minimo) || ', CLT art. 71).');
      end if;
    end if;
    return v_saida;
  end if;

  -- início de hora extra: autorizada pela Programação ou enviada ao gestor para aprovar (decisão 100, parte 2)
  -- bloco próprio: uma falha aqui não desfaz os avisos, e uma falha nos avisos não desfaz o pedido (seguranca)
  if p_tipo = 'inicio_he' then
    begin
      v_he := fn_ponto_he_inicio(p_tecnico);
      if v_he is not null then v_saida := v_saida || v_he; end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
      begin
        perform fn_avisar_tecnico('⚠️ *HORA EXTRA*' || E'\n\n' || 'O pedido de aprovação de uma hora extra iniciada agora '
          || 'falhou e não foi enviado ao gestor. Confira em Ponto › Marcações e decida no painel.');
      exception when others then null;
      end;
      v_saida := v_saida || 'Início de hora extra registrado. Avise o seu gestor para aprovar.'::text;
    end;
    return v_saida;
  end if;

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
      for s in select telefone_e164, conta_id from tecnicos
                where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
                  and empresa_id = v_emp loop
        perform fn_ponto_wa_na_conta(s.conta_id, s.telefone_e164, v_gest);
      end loop;
    end if;
  end loop;
  return v_saida;
exception when others then
  raise warning 'ponto: avisos de jornada falharam: %', sqlerrm;
  return '{}';
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_avisar_supervisores(p_tecnico uuid, p_texto text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare s record; v_emp uuid;
begin
  select empresa_id into v_emp from tecnicos where id = p_tecnico;
  for s in select telefone_e164, conta_id from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and empresa_id = v_emp loop
    perform fn_ponto_wa_na_conta(s.conta_id, s.telefone_e164, p_texto);
  end loop;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_lembrete_almoco()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  t record;
  v_n int := 0;
begin
  for t in
    select tc.id, tc.nome, tc.telefone_e164, tc.conta_id, e.fuso
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
      perform fn_ponto_wa_na_conta(t.conta_id, t.telefone_e164,
        '🍽️ Bom almoço, ' || split_part(t.nome, ' ', 1) || '! Quando sair para o intervalo, lembre de marcar: escreva *almoço* aqui.');
      v_n := v_n + 1;
    end if;
  end loop;
  begin
    perform fn_ponto_alerta_pedidos_parados();
  exception when others then
    raise warning 'ponto: alerta de pedidos parados falhou: %', sqlerrm;
  end;
  begin
    perform fn_ponto_aviso_intervalo_pendente();
  exception when others then
    raise warning 'ponto: aviso do intervalo não registrado falhou: %', sqlerrm;
  end;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_aviso_intervalo_pendente()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  t       record;
  v_ontem date;
  j       jsonb;
  v_n     int := 0;
begin
  for t in
    select tc.id, tc.telefone_e164, tc.conta_id, e.fuso
      from tecnicos tc join empresas e on e.id = tc.empresa_id
     where tc.ativo and tc.opt_in and tc.cpf is not null and tc.telefone_e164 is not null
       and e.exige_registro_intervalo
       and (now() at time zone e.fuso)::time >= time '08:00' and (now() at time zone e.fuso)::time < time '09:00'
  loop
    v_ontem := (now() at time zone t.fuso)::date - 1;
    continue when exists (select 1 from alertas_enviados where tipo = 'ponto_intervalo_pendente_' || t.id and data_ref = v_ontem);
    j := fn_ponto_jornada_dia(t.id, v_ontem);
    continue when j is null or not (j->'alertas' ? 'sem_intervalo') or j->>'abono' is not null;
    continue when exists (select 1 from ponto_justificativas p where p.tecnico_id = t.id and p.status = 'pendente'
                           and v_ontem between p.data and coalesce(p.data_fim, p.data));
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_intervalo_pendente_' || t.id, v_ontem, now(), true, '{}'::jsonb)
    on conflict do nothing;
    if found then
      perform fn_ponto_wa_na_conta(t.conta_id, t.telefone_e164,
        '📝 *Ponto · intervalo de ' || to_char(v_ontem, 'DD/MM') || '*' || E'\n'
        || 'Não há registro do seu intervalo nesse dia. Se você fez o intervalo e esqueceu de marcar, peça o ajuste: '
        || 'escreva *ajuste* aqui ou use o app (aba Ajuste). Se não fez, não precisa fazer nada.');
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_espelho_pdf_gravar(p_token text, p_id uuid, p_pdf bytea)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_e   record;
  v_sha text;
  v_req bigint;
  v_env boolean := false;
begin
  if not fn_ponto_espelho_pdf_token_ok(p_token) then raise exception 'token inválido'; end if;
  if p_pdf is null or octet_length(p_pdf) < 1000 or octet_length(p_pdf) > 1048576
     or substr(p_pdf, 1, 5) <> '\x255044462d'::bytea then
    raise exception 'Arquivo inválido: não é um PDF.';
  end if;
  select e.id, e.empresa_id, e.tecnico_id, e.competencia, e.registro, e.assinado_em, e.substituido_em,
         t.nome, t.telefone_e164, t.ativo, t.opt_in
    into v_e from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id where e.id = p_id;
  if not found or v_e.assinado_em is null or v_e.substituido_em is not null then
    raise exception 'Espelho não assinado ou substituído.';
  end if;
  v_sha := encode(sha256(p_pdf), 'hex');
  insert into ponto_espelho_pdfs (espelho_id, empresa_id) values (p_id, v_e.empresa_id) on conflict (espelho_id) do nothing;
  update ponto_espelho_pdfs set pdf = p_pdf, sha256 = v_sha, gerado_em = now()
   where espelho_id = p_id and pdf is null;
  if not found then return jsonb_build_object('gravado', false, 'motivo', 'ja_gerado'); end if;

  -- o arquivo (com o CPF, art. 84) só vai ao número que acabou de provar ser do funcionário: a assinatura pede login
  -- com código enviado a esse WhatsApp. Login pelo código do gestor: vai só o aviso, e o PDF fica no app (revisão
  -- do seguranca, 17/10)
  if (select enviar from ponto_espelho_pdfs where espelho_id = p_id)
     and v_e.ativo and v_e.opt_in and v_e.telefone_e164 is not null and fn_pode_enviar(v_e.telefone_e164) then
    begin
      if coalesce((select s.login_origem from ponto_sessoes s where s.tecnico_id = v_e.tecnico_id
                    order by s.criada_em desc limit 1), '') <> 'whatsapp' then
        v_req := fn_evo_post_na_conta((select conta_id from tecnicos where id = v_e.tecnico_id), '/message/sendText/' || fn_config('evolution_instancia'),
          jsonb_build_object('number', v_e.telefone_e164,
            'text', 'Trilha Ponto: ' || split_part(trim(v_e.nome), ' ', 1) || ', o seu espelho de ponto de '
                    || to_char(v_e.competencia, 'MM/YYYY') || ' assinado está no app, em Espelho, para baixar em PDF.'));
      else
      v_req := fn_evo_post_na_conta((select conta_id from tecnicos where id = v_e.tecnico_id), '/message/sendMedia/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_e.telefone_e164, 'mediatype', 'document', 'mimetype', 'application/pdf',
          'fileName', 'espelho-de-ponto-' || to_char(v_e.competencia, 'MM-YYYY') || '-registro-' || v_e.registro || '.pdf',
          'caption', 'Trilha Ponto: ' || split_part(trim(v_e.nome), ' ', 1) || ', aqui está a sua cópia do espelho de ponto de '
                     || to_char(v_e.competencia, 'MM/YYYY') || ', assinado por você e validado pela empresa. Guarde este arquivo.',
          'media', encode(p_pdf, 'base64')));
      end if;
      if v_req is not null then
        update ponto_espelho_pdfs set enviado_em = now(), envio_req = v_req where espelho_id = p_id;
        v_env := true;
      end if;
    exception when others then
      raise warning 'espelho-pdf: envio pelo WhatsApp falhou (%)', sqlerrm;
    end;
  end if;
  return jsonb_build_object('gravado', true, 'sha256', v_sha, 'enviado', v_env);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_alerta_teto(p_qual text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
begin
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_teto_' || p_qual || '_' || to_char(now() at time zone 'America/Bahia', 'HH24'),
          (now() at time zone 'America/Bahia')::date, now(), true, jsonb_build_object('teto', p_qual))
  on conflict do nothing;
  if not found then return; end if;
  raise warning 'app do ponto: teto de % por hora atingido', p_qual;
  for s in select telefone_e164 from tecnicos where is_supervisor and ativo and opt_in and not perfil_teste
                                               and conta_id = '00000000-0000-0000-0000-000000000001' loop
    begin
      perform fn_evo_post_na_conta('00000000-0000-0000-0000-000000000001', '/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', s.telefone_e164,
          'text', case when p_qual = 'avisos'
            then 'Trilha Ponto: muitos CPFs não encontrados no app do ponto nesta hora (possível tentativa de descobrir '
                 || 'funcionários). O app voltou à resposta única até a próxima hora; o código continua chegando para quem é cadastrado.'
            else 'Trilha Ponto: o limite de ' || case when p_qual = 'erros' then 'tentativas de login'
                  else 'códigos por WhatsApp' end || ' por hora foi atingido (possível ataque). '
                  || 'Enquanto durar, o funcionário entra com o código gerado pelo gestor no painel.' end));
    exception when others then null;
    end;
  end loop;
end $function$
;

-- motor com fila justa e teto por conta
CREATE OR REPLACE FUNCTION interno.fn_dispatcher_whatsapp()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_avisos int := 0;
  v_emp uuid;
  v_conta uuid;
  v_limite int := coalesce(fn_config_int('envios_por_execucao'), 3);
  -- F5c: fila justa; cada conta envia no máximo isto por execução (padrão: o limite geral)
  v_limite_conta int := greatest(coalesce(fn_config_int('envios_por_conta_por_execucao'), coalesce(fn_config_int('envios_por_execucao'), 3)), 1);
  v_limite_sup int := greatest(coalesce(fn_config_int('supervisor_avisos_por_execucao'), 5), 1);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst text := fn_config('evolution_instancia');
  v_ping text := nullif(fn_config('monitor_ping_url'), '');
begin
  -- uma execucao por vez: uma chamada manual junto com o cron nao envia a mesma escala duas vezes
  if not pg_try_advisory_xact_lock(hashtext('fn_dispatcher_whatsapp')) then
    return;
  end if;
  -- nunca preso mais que 20 s esperando lock: a proxima execucao tenta de novo
  perform set_config('lock_timeout', '20s', true);
  perform set_config('app.ator', 'dispatcher', true);

  -- FASE 1: conferir o que a Evolution respondeu
  for n in select id, escala_id, http_req_id, created_at from notificacoes
           where status_envio = 'enfileirada' and http_req_id is not null loop
   begin
    select status_code, content, error_msg into r_resp from net._http_response where id = n.http_req_id;
    if not found then
      if n.created_at < now() - interval '5 minutes' then
        update notificacoes set status_envio = 'falha', erro_codigo = 'timeout',
               erro_mensagem = 'Sem resposta da Evolution em 5 minutos' where id = n.id;
      end if;
      continue;
    end if;
    if r_resp.status_code in (200, 201) then
      begin v_wa_id := (r_resp.content::jsonb) -> 'key' ->> 'id'; exception when others then v_wa_id := null; end;
      update notificacoes set status_envio = 'enviada', wa_message_id = v_wa_id where id = n.id;
      update escalas set status = 'notificada' where id = n.escala_id and status = 'agendada';
    else
      update notificacoes set status_envio = 'falha',
             erro_codigo = coalesce(r_resp.status_code::text, 'rede'),
             erro_mensagem = left(coalesce(r_resp.content, r_resp.error_msg, 'erro desconhecido'), 500)
       where id = n.id;
    end if;
   exception when others then
    raise warning 'fase 1, notificacao %: %', n.id, sqlerrm;
   end;
  end loop;

  -- FASE 2: enviar
  -- F5c: rodízio entre as contas (a 1ª de cada conta, depois a 2ª...), com teto por conta
  for a in select f.* from (
             select p.*, row_number() over (partition by e.conta_id order by p.enviada_em nulls first) as ordem_conta
               from vw_acoes_pendentes p join escalas e on e.id = p.escala_id
              where p.acao in ('enviar_primeira','reenviar_falha','reenviar','nao_recebeu')) f
            where f.ordem_conta <= v_limite_conta
            order by f.ordem_conta, f.enviada_em nulls first loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar','nao_recebeu') then continue; end if;
    v_tent := coalesce(a.tentativa, 0) + 1;
    v_botoes := v_usar_botoes and a.acao <> 'reenviar_falha';
    begin
      -- F5b: a conta da escala decide o canal (o telefone é único só dentro da conta)
      perform set_config('trilha.conta', (select conta_id from escalas where id = a.escala_id)::text, true);
      v_payload := fn_payload_escala(a.escala_id, a.telefone, a.acao = 'reenviar', v_botoes);
      -- conta sem canal de WhatsApp (F5a): falha registrada, em vez de ficar enfileirada sem pedido
      if fn_evo_destino(v_payload ->> 'path', v_payload -> 'body' ->> 'number') is null then
        raise exception 'A conta do técnico não tem canal de WhatsApp ativo.';
      end if;
      v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
      insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
      values (a.escala_id,
        (case when v_tent = 1 then 'primeira' when a.acao = 'reenviar_falha' then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
        v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
        'enfileirada', v_payload, now(), v_req);
    exception when others then
      -- registra a falha na propria escala: o motor tenta de novo e, esgotadas as tentativas,
      -- aciona o supervisor. As outras escalas seguem normalmente.
      begin
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, erro_codigo, erro_mensagem, enviada_em)
        values (a.escala_id,
          (case when v_tent = 1 then 'primeira' when a.acao = 'reenviar_falha' then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
          v_tent, 'erro_interno', 'falha', 'interno', left(sqlerrm, 500), now());
      exception when others then
        raise warning 'fase 2, escala %: %', a.escala_id, sqlerrm;
      end;
    end;
    v_sent := v_sent + 1;
  end loop;

  -- FASE 3: supervisores, no maximo v_limite_sup escalas por execucao (as mais antigas primeiro);
  -- o resto fica para a proxima execucao, porque so a escala avisada ganha supervisor_avisado_em
  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor)
           order by enviada_em nulls first loop
    exit when v_avisos >= v_limite_sup;
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
   begin
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    -- só os supervisores da empresa do técnico (decisão 107); funcionário sem empresa avisa os da conta dele (122)
    select t.empresa_id, e.conta_id into v_emp, v_conta from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = a.escala_id;
    perform set_config('trilha.conta', v_conta::text, true);
    for s in select telefone_e164 from tecnicos
              where is_supervisor and ativo and (v_emp is null or empresa_id = v_emp) and conta_id = v_conta loop
      perform fn_evo_post('/message/sendText/' || v_inst,
                          jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
    end loop;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
    -- conta só o aviso que deu certo: escala que falha sempre não ocupa o teto das outras
    v_avisos := v_avisos + 1;
   exception when others then
    raise warning 'fase 3, escala %: %', a.escala_id, sqlerrm;
   end;
  end loop;

  perform set_config('trilha.conta', '', true);

  -- FASE 4: prazo da escala de amanha
  begin perform fn_alerta_prazo_escala();
  exception when others then raise warning 'alerta de prazo falhou: %', sqlerrm; end;

  -- FASE 5: documentos vencidos
  begin perform fn_alerta_certificacoes();
  exception when others then raise warning 'alerta de certificacoes falhou: %', sqlerrm; end;

  -- FASE 6: ligacoes da URA
  begin perform fn_disparar_ligacoes();
  exception when others then raise warning 'ligacoes falharam: %', sqlerrm; end;

  -- FASE 7: escalas encerradas viram concluidas (decisao 30)
  begin perform fn_concluir_escalas();
  exception when others then raise warning 'conclusao automatica falhou: %', sqlerrm; end;
  perform set_config('app.ator', 'dispatcher', true);

  -- Execucao concluida: registro lido pelo vigia (fn_vigiar_motor). Se algo acima falhar sem
  -- tratamento, a transacao inteira e desfeita e este registro tambem.
  update motor_estado set ultima_execucao_ok = now(), atualizado_em = now() where id;

  -- Monitor externo: sinal a cada execucao. Sem sinal (motor parado, Supabase fora ou pausado),
  -- o healthchecks.io avisa por e-mail/Telegram. Evolution falhando: sinal de falha (/fail).
  if v_ping is not null then
    begin
      perform net.http_get(v_ping || case when fn_evolution_falhando() then '/fail' else '' end,
                           timeout_milliseconds => 5000);
    exception when others then raise warning 'ping do monitor falhou: %', sqlerrm; end;
  end if;
end $function$
;

-- vigia da operadora chama o dos canais
CREATE OR REPLACE FUNCTION interno.fn_vigiar_evolution()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v       evolution_vigia;
  v_resp  record;
  v_estado text;
  v_limite int := greatest(coalesce(fn_config_int('evolution_alerta_falhas'), 2), 1);
  v_inst  text := fn_config('evolution_instancia');
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_manager text := rtrim(coalesce(fn_config('evolution_url'), ''), '/') || '/manager';
begin
  -- F5b: a resposta do /webhook/set das instâncias de cliente repete o token no cabeçalho; sai assim que chega
  with r as (delete from net._http_response h using conta_canais c where h.id = c.webhook_req returning h.id)
  update conta_canais set webhook_req = null where webhook_req in (select id from r);
  update conta_canais set webhook_req = null where webhook_req is not null and atualizado_em < now() - interval '1 day';
  if nullif(fn_config('evolution_url'), '') is null or nullif(v_inst, '') is null then
    return jsonb_build_object('situacao', 'sem evolution configurada');
  end if;
  insert into evolution_vigia (id) values (true) on conflict (id) do nothing;
  select * into v from evolution_vigia where id for update skip locked;
  if not found then return jsonb_build_object('situacao', 'outra volta em andamento'); end if;

  if v.req_id is not null then
    select r.status_code, r.content, r.timed_out, r.error_msg into v_resp from net._http_response r where r.id = v.req_id;
    if found then
      begin
        v_estado := case when v_resp.status_code = 200 then left(coalesce(
                      (v_resp.content::jsonb #>> '{instance,state}'), (v_resp.content::jsonb ->> 'state'), 'desconhecido'), 30)
                    else 'sem_resposta' end;
      exception when others then
        v_estado := 'sem_resposta';   -- resposta que não é JSON
      end;
    elsif v.verificado_em < now() - interval '4 minutes' then
      v_estado := 'sem_resposta';   -- o pg_net já descartou a resposta ou nunca respondeu
    end if;
  end if;

  if v_estado is not null then
    if v_estado = 'open' then
      if v.alertado_em is not null then
        perform fn_alerta_email('Trilha: WhatsApp de volta',
          'O WhatsApp do Trilha (instância ' || v_inst || ') voltou a funcionar às '
          || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || '.' || E'\n'
          || 'Ficou fora desde ' || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || '. '
          || 'Confira no painel as programações e os avisos desse período.');
      end if;
      update evolution_vigia set estado = v_estado, falhas = 0, fora_desde = null, alertado_em = null where id;
    else
      update evolution_vigia set estado = v_estado, falhas = falhas + 1, fora_desde = coalesce(fora_desde, now()) where id
        returning * into v;
      if v.falhas >= v_limite and v.alertado_em is null then
        perform fn_alerta_email('Trilha: WhatsApp fora do ar',
          'O WhatsApp do Trilha (instância ' || v_inst || ') está fora do ar desde '
          || to_char(v.fora_desde at time zone v_fuso, 'DD/MM HH24:MI') || ' (estado: ' || v_estado || ').' || E'\n\n'
          || 'Enquanto isso, programações, confirmações e avisos pelo WhatsApp não saem.' || E'\n\n'
          || 'Como resolver: abra ' || v_manager || ', entre na instância ' || v_inst
          || ' e leia o QR code com o WhatsApp do celular da operação. Se a página não abrir, o servidor da Evolution '
          || 'está fora: acione o suporte.' || E'\n\n'
          || 'Quando voltar, você recebe outro e-mail.');
        update evolution_vigia set alertado_em = now() where id;
      end if;
    end if;
  end if;

  begin
    update evolution_vigia set req_id = fn_evo_get('/instance/connectionState/' || v_inst), verificado_em = now() where id;
  exception when others then
    -- sem a chave da Evolution no Vault (ou o pg_net fora): aparece no quadro da plataforma, em vez de só um aviso no log
    update evolution_vigia set req_id = null, estado = 'erro_interno', verificado_em = now() where id;
  end;
  -- F5c: o WhatsApp de cada cliente (só na produção: na homologação só existe a instância da operadora)
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    perform fn_vigiar_canais();
  end if;
  return jsonb_build_object('estado', coalesce(v_estado, v.estado), 'falhas', (select falhas from evolution_vigia where id));
end $function$
;

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
