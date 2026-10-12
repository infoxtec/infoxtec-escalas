-- Suíte de regressão e carga do banco (decisão 51). Roda no CI, em banco vazio com todas as
-- migrations, e pode rodar na homologação: tudo acontece numa transação desfeita no fim (rollback),
-- com dados próprios (empresa, funcionários e local de teste). Qualquer falha interrompe com
-- "FALHA [Tn]: ...". Nunca rodar na produção.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/regressao.sql
--
-- T1 permissões das funções          T6 conversa do ponto no WhatsApp (fn_ponto_wh)
-- T2 escala exige local               T7 jornada e avisos da CLT
-- T3 login do funcionário e app       T8 webhook recusa token inválido
-- T4 marcações imutáveis              T9 funções do painel (gestor)
-- T5 carga: 2.000 marcações, NSR e cadeia de hash íntegros
-- T10 URA só em dia útil, das 08:00 às 20:00, fora de feriado
-- T11 ajustes de ponto com justificativa (incluir, desconsiderar, papéis, imutável)
-- T12 fuso do motor: fila do WhatsApp na hora local, não em UTC nem no fuso da sessão
-- T13 habilidades exigidas pelo tipo de atividade (apto, nível abaixo, faltando)
-- T14 justificativa de ponto: pedido no WhatsApp e no app, aprovar, negar, abono, falta no espelho
-- T15 atestado no cofre: documento cifrado, só quem vê atestados vê e decide, limite legal, abono por dia
-- T16 validade do atestado: sem ponto e sem escala no afastamento; alta médica libera
-- T17 documento pelo WhatsApp: falta com foto ou PDF, arquivo só na etapa do documento, direto ao cofre
-- T18 registro do documento: número sequencial por empresa, QR de verificação, integridade e descarte
-- T19 E3: dias úteis, reincidência (só o fato), pedido parado, alerta aos supervisores e métrica
-- T20 alta antecipada registrada pelo gestor: só com "vê atestados", documento no cofre, libera o ponto
-- T21 véspera de feriado: o alerta da escala de amanhã não sai
-- T22 limpeza da estrutura: objetos sem chamador removidos; Checklist aponta tarefa obrigatória faltando
-- T23 feriado não exige escala; MFA obrigatório barra sessão sem o código (aal1) e libera com ele (aal2)
-- T24 motor: no máximo 5 escalas avisadas aos supervisores por execução; o resto na seguinte
-- T25 avisos aos supervisores só da empresa do técnico (função comum e motor)

\set ON_ERROR_STOP on
begin;

-- Trava: a produção é o único banco com tarefas no pg_cron (supabase/setup/cron.sql). O T7 trava
-- ponto_marcacoes até o rollback, o que bloquearia as batidas reais.
do $$
declare n int := 0;
begin
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job' into n; end if;
  if n > 0 then raise exception 'regressao.sql: banco com pg_cron agendado (produção?). Abortado.'; end if;
end $$;

create temp table qa (k text primary key, v text) on commit drop;

create function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FALHA %', p_msg; end if;
end $$;

-- CPF válido a partir de 9 dígitos
create function pg_temp.cpf(p_base text) returns text language plpgsql as $$
declare d int[]; s int; i int; d1 int; d2 int;
begin
  d := array(select substr(p_base, g.x, 1)::int from generate_series(1, 9) g(x));
  s := 0; for i in 1..9 loop s := s + d[i] * (11 - i); end loop;
  d1 := 11 - s % 11; if d1 >= 10 then d1 := 0; end if;
  s := 0; for i in 1..9 loop s := s + d[i] * (12 - i); end loop; s := s + d1 * 2;
  d2 := 11 - s % 11; if d2 >= 10 then d2 := 0; end if;
  return p_base || d1 || d2;
end $$;

create function pg_temp.msg(p_tel text, p_id text, p_message jsonb, p_key jsonb default '{}') returns jsonb
language sql as $$
  select jsonb_build_object('key', jsonb_build_object('remoteJid', p_tel || '@s.whatsapp.net', 'id', p_id) || p_key,
                            'message', p_message)
$$;

-- Dados de teste ------------------------------------------------------------------------------------
do $$
declare v_emp uuid; v_loc uuid; i int; v_id uuid; v_base text;
begin
  perform pg_temp.ok(fn_cnpj_valido('11444777000161'), '[setup] CNPJ de teste');
  insert into empresas (cnpj, razao_social, nome_fantasia, fuso, empregadora, ativo)
  values ('11444777000161', 'QA Regressão Ltda', 'QA', 'America/Bahia', true, true) returning id into v_emp;
  insert into qa values ('emp', v_emp::text);

  insert into locais (nome, cliente, ativo, latitude, longitude, raio_m)
  values ('QA Obra', 'QA', true, -12.900000, -38.400000, 150) returning id into v_loc;
  insert into qa values ('loc', v_loc::text);

  -- 7 funcionários: 1 para os fluxos, 5 para a carga, 1 para a jornada
  for i in 1..7 loop
    v_base := lpad((800000000 + i * 7919 + (random() * 1000)::int)::text, 9, '0');
    insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
    values ('QA Funcionário ' || i, '5579' || lpad((90000000 + i * 101 + (random() * 50)::int)::text, 9, '0'),
            true, true, pg_temp.cpf(v_base), v_emp, true)
    returning id into v_id;
    insert into qa values ('tec' || i, v_id::text);
  end loop;

  insert into painel_usuarios (email, nome, papel, ativo) values ('qa-admin@teste.local', 'QA', 'admin', true);
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T1 permissões ---------------------------------------------------------------------------------------
do $$
declare v text;
begin
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('service_role', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  perform pg_temp.ok(v is null, '[T1] service_role executa: ' || coalesce(v, ''));
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname not like 'app\_%' and p.proname not like 'ponto\_%'
     and has_function_privilege('authenticated', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  perform pg_temp.ok(v is null, '[T1] authenticated executa função interna: ' || coalesce(v, ''));
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname not like 'ponto\_%'
     and has_function_privilege('anon', p.oid, 'execute')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  perform pg_temp.ok(v is null, '[T1] anon executa fora de ponto_*: ' || coalesce(v, ''));
  -- função nova nasce fechada (default privileges)
  execute 'create function public.fn_qa_nova() returns int language sql as ''select 1''';
  perform pg_temp.ok(not has_function_privilege('service_role', 'public.fn_qa_nova()', 'execute')
                     and not has_function_privilege('anon', 'public.fn_qa_nova()', 'execute'),
                     '[T1] função nova nasce com execute para service_role/anon');
  -- tabelas do ponto fechadas para escrita direta
  perform pg_temp.ok(not has_table_privilege('service_role', 'ponto_marcacoes', 'insert')
                     and not has_table_privilege('authenticated', 'ponto_marcacoes', 'select'),
                     '[T1] ponto_marcacoes aberta a papel da API');
  -- nenhuma tabela, view ou sequência do public alcançável por papel da API (migration 63)
  select string_agg(r.rolname || ':' || c.relname, ', ') into v
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    cross join (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
   where n.nspname = 'public'
     and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')
     and case when c.relkind in ('r','p','v','m','f')
                then has_table_privilege(r.rolname, c.oid, 'select,insert,update,delete,truncate,references,trigger')
                     or has_any_column_privilege(r.rolname, c.oid, 'select,insert,update,references')
              when c.relkind = 'S' then has_sequence_privilege(r.rolname, c.oid, 'usage,select,update')
              else false end;
  perform pg_temp.ok(v is null, '[T1] papel da API alcança tabela ou sequência: ' || coalesce(v, ''));
  -- tabela e sequência novas nascem fechadas
  execute 'create table public.qa_nova (id bigint generated always as identity primary key)';
  select string_agg(r.rolname, ', ') into v
    from (values ('anon'), ('authenticated'), ('service_role')) r(rolname)
   where has_table_privilege(r.rolname, 'public.qa_nova', 'select,insert,update,delete')
      or has_sequence_privilege(r.rolname, pg_get_serial_sequence('public.qa_nova', 'id'), 'usage,select,update');
  perform pg_temp.ok(v is null, '[T1] tabela nova nasce aberta para: ' || coalesce(v, ''));
end $$;

-- T2 escala exige local ----------------------------------------------------------------------------------
do $$
declare v_tec uuid := (select v::uuid from qa where k = 'tec1'); v_ok boolean := false;
begin
  begin
    insert into escalas (tecnico_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
    values (v_tec, current_date + 2, '08:00', 'QA sem local', 'rascunho', 'qa');
  exception when others then v_ok := sqlerrm like '%local%';
  end;
  perform pg_temp.ok(v_ok, '[T2] escala sem local foi aceita');
end $$;

-- T3 login do funcionário e app do ponto --------------------------------------------------------------------
do $$
declare
  v_tec uuid := (select v::uuid from qa where k = 'tec1');
  v_cpf text := (select cpf from tecnicos where id = (select v::uuid from qa where k = 'tec1'));
  c jsonb; e jsonb; t1 text; t2 text; v_ok boolean := false;
begin
  c := app_ponto_gerar_codigo(v_tec);
  e := ponto_entrar(v_cpf, '000000');
  perform pg_temp.ok(e ? 'erro', '[T3] código errado entrou');
  e := ponto_entrar(v_cpf, c->>'codigo');
  t1 := e->>'token';
  perform pg_temp.ok(t1 is not null, '[T3] código do gestor não entrou: ' || e::text);
  e := ponto_entrar(v_cpf, c->>'codigo');
  perform pg_temp.ok(e ? 'erro', '[T3] código usado duas vezes');
  perform ponto_registrar_ciencia(t1, 'qa');
  perform pg_temp.ok((ponto_eu(t1, 'qa')->>'ciente')::boolean, '[T3] ciência não registrada');
  c := ponto_bater(t1, 'entrada', -12.900100, -38.400100, 10, 'qa');
  perform pg_temp.ok((c->>'nsr')::int = 1 and (c->>'dentro_area')::boolean, '[T3] marcação pelo app: ' || c::text);
  perform pg_temp.ok((select count(*) from ponto_minhas_marcacoes(t1, 7)) = 1, '[T3] histórico do funcionário');
  -- sessão única: novo login derruba o anterior
  c := app_ponto_gerar_codigo(v_tec);
  t2 := ponto_entrar(v_cpf, c->>'codigo')->>'token';
  begin perform ponto_eu(t1, 'qa'); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok and t2 is not null, '[T3] sessão antiga continuou válida');
  -- token inválido não registra
  v_ok := false;
  begin perform ponto_bater('token-falso', 'saida', -12.9, -38.4, 10, 'qa'); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T3] token falso registrou ponto');
  insert into qa values ('token', t2);
end $$;

-- T4 marcações imutáveis ------------------------------------------------------------------------------
do $$
declare v_ok boolean;
begin
  v_ok := false;
  begin update ponto_marcacoes set tipo = 'saida' where empresa_id = (select v::uuid from qa where k = 'emp');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T4] update em marcação passou');
  v_ok := false;
  begin delete from ponto_marcacoes where empresa_id = (select v::uuid from qa where k = 'emp');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T4] delete em marcação passou');
  v_ok := false;
  begin
    insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, tipo, canal, latitude, longitude, hash_anterior, hash)
    select empresa_id, 999, id, cpf, 'entrada', 'app', -12.9, -38.4, 'x', 'y' from tecnicos where id = (select v::uuid from qa where k = 'tec1');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T4] inserção fora da porta única passou');
end $$;

-- T5 carga: 2.000 marcações (5 funcionários × 400), NSR sem lacuna e cadeia íntegra ---------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  t0 timestamptz := clock_timestamp(); i int; j int; v_tec uuid; r jsonb; v_seg numeric;
  tipos text[] := array['entrada','saida_almoco','volta_almoco','saida'];
begin
  for i in 1..400 loop
    for j in 2..6 loop
      v_tec := (select v::uuid from qa where k = 'tec' || j);
      perform fn_ponto_registrar(v_tec, tipos[1 + (i % 4)], 'app'::text, (-12.9 + random() / 1000)::numeric,
                                 (-38.4 + random() / 1000)::numeric,
                                 (random() * 30)::int, jsonb_build_object('app_versao', 'qa'));
    end loop;
  end loop;
  v_seg := extract(epoch from clock_timestamp() - t0);
  perform pg_temp.ok((select count(*) from ponto_marcacoes where empresa_id = v_emp) = 2001, '[T5] total de marcações');
  perform pg_temp.ok((select max(nsr) = count(*) and min(nsr) = 1 from ponto_marcacoes where empresa_id = v_emp),
                     '[T5] NSR com lacuna');
  perform pg_temp.ok((select ultimo from ponto_nsr where empresa_id = v_emp) = 2001, '[T5] ponto_nsr divergente');
  r := app_ponto_verificar(v_emp);
  perform pg_temp.ok((r->>'integra')::boolean and (r->>'conferidas')::int = 2001, '[T5] cadeia: ' || r::text);
  perform pg_temp.ok(v_seg < 120, '[T5] 2.000 marcações levaram ' || round(v_seg, 1) || ' s');
  raise notice 'T5 carga: 2.000 marcações em % s (% por segundo)', round(v_seg, 2), round(2000 / greatest(v_seg, 0.001));
  insert into qa values ('t5_seg', round(v_seg, 2)::text);
end $$;

-- T6 conversa do ponto no WhatsApp ------------------------------------------------------------------
do $$
declare
  v_tel text := (select telefone_e164 from tecnicos where id = (select v::uuid from qa where k = 'tec1'));
  r jsonb; i int; t0 timestamptz;
  loc jsonb := jsonb_build_object('degreesLatitude', -12.90012345, 'degreesLongitude', -38.40012345, 'accuracyInMeters', 8);
begin
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W1', '{"conversation":"bom dia"}'));
  perform pg_temp.ok(r is null, '[T6] texto comum capturado pelo ponto');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W2', '{"conversation":"Ponto"}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_menu', '[T6] menu: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W3', '{"conversation":"xpto"}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_menu_repetido', '[T6] inválido não voltou ao menu');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W4', '{"conversation":"sim"}'));
  perform pg_temp.ok(r is null, '[T6] resposta de escala capturada');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W5', '{"extendedTextMessage":{"text":"1","contextInfo":{"stanzaId":"X"}}}'));
  perform pg_temp.ok(r is null, '[T6] número citando a escala capturado');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W6', '{"buttonsResponseMessage":{"selectedButtonId":"ponto:saida_almoco"}}'));
  perform pg_temp.ok(r->>'tipo' = 'saida_almoco', '[T6] botão: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(jsonb_build_object('key', jsonb_build_object('remoteJid', v_tel || '@s.whatsapp.net', 'id', 'W7'),
         'contextInfo', jsonb_build_object('isForwarded', true), 'message', jsonb_build_object('locationMessage', loc)));
  perform pg_temp.ok(r->>'acao' = 'ponto_localizacao_encaminhada', '[T6] encaminhada aceita');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W8', jsonb_build_object('locationMessage', loc || '{"name":"Obra"}')));
  perform pg_temp.ok(r->>'acao' = 'ponto_localizacao_recusada', '[T6] lugar do mapa aceito');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W9', jsonb_build_object('locationMessage', loc)));
  perform pg_temp.ok(r->>'acao' = 'ponto_registrado', '[T6] localização atual: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W9', jsonb_build_object('locationMessage', loc)));
  perform pg_temp.ok(r ? 'ignorado', '[T6] mensagem repetida registrou de novo');
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'W10', '{"conversation":"volta"}'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W11', jsonb_build_object('locationMessage', loc)));
  perform pg_temp.ok(r->>'acao' = 'ponto_localizacao_repetida', '[T6] coordenada repetida aceita como fixa');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'W12', jsonb_build_object('liveLocationMessage', loc)));
  perform pg_temp.ok(r->>'acao' = 'ponto_registrado', '[T6] tempo real recusado');
  r := fn_ponto_wh(jsonb_build_object('key', jsonb_build_object('remoteJid', '123@g.us', 'senderPn', v_tel || '@s.whatsapp.net', 'id', 'W13'),
         'message', '{"conversation":"ponto"}'::jsonb));
  perform pg_temp.ok(r is null, '[T6] grupo capturado');
  r := fn_ponto_wh(jsonb_build_object('key', jsonb_build_object('remoteJid', v_tel || '@s.whatsapp.net'), 'message', '{"conversation":"ponto"}'::jsonb));
  perform pg_temp.ok(r is null, '[T6] mensagem sem id capturada');
  -- carga: 300 mensagens seguidas no fluxo
  t0 := clock_timestamp();
  for i in 1..300 loop
    perform fn_ponto_wh(pg_temp.msg(v_tel, 'C' || i, case i % 3 when 0 then '{"conversation":"ponto"}'::jsonb
                                                       when 1 then '{"conversation":"xyz"}'::jsonb
                                                       else '{"conversation":"0"}'::jsonb end));
  end loop;
  raise notice 'T6 carga: 300 mensagens em % s', round(extract(epoch from clock_timestamp() - t0), 2);
  insert into qa values ('t6_seg', round(extract(epoch from clock_timestamp() - t0), 2)::text);
end $$;

-- T7 jornada e avisos da CLT ---------------------------------------------------------------------------
do $$
declare
  v_tec uuid := (select v::uuid from qa where k = 'tec7');
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  d date := current_date - 3; j jsonb; v_av text[];
  v_almoco timestamptz := least(now(), greatest(now() - interval '25 minutes',
                          (now() at time zone 'America/Bahia')::date::timestamp at time zone 'America/Bahia' + interval '1 second'));
begin
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 900000 + i, v_tec, (select cpf from tecnicos where id = v_tec), m, tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (values (1, (d + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (2, (d + time '12:00') at time zone 'America/Bahia', 'saida_almoco'),
                 (3, (d + time '12:40') at time zone 'America/Bahia', 'volta_almoco'),
                 (4, (d + time '20:30') at time zone 'America/Bahia', 'saida'),
                 (5, (d + 1 + time '06:00') at time zone 'America/Bahia', 'entrada'),
                 -- saída para o almoço há 25 min, mas nunca antes da meia-noite local: o aviso prévio só
                 -- conta o almoço de hoje, e o CI pode rodar logo depois da meia-noite em Salvador
                 (6, v_almoco, 'saida_almoco')) v(i, m, tp);
  alter table ponto_marcacoes enable trigger user;
  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(j->'alertas' ? 'intervalo_curto' and j->'alertas' ? 'he_acima_limite'
                     and (j->>'trabalhado_min')::int = 710, '[T7] dia com intervalo curto e HE: ' || j::text);
  j := fn_ponto_jornada_dia(v_tec, d + 1);
  perform pg_temp.ok(j->'alertas' ? 'interjornada_curta', '[T7] interjornada: ' || j::text);
  perform pg_temp.ok(fn_ponto_aviso_previo(v_tec, 'volta_almoco')
                     like '%' || (extract(epoch from now() - v_almoco) / 60)::int || ' min%', '[T7] aviso antes da volta');
  perform pg_temp.ok(fn_ponto_aviso_previo(v_tec, 'entrada') is null, '[T7] aviso prévio fora da volta');
  v_av := fn_ponto_avisar(v_tec, 'saida');
  perform pg_temp.ok(v_av is not null, '[T7] avisos nulos');
end $$;

-- T8 webhook recusa token inválido --------------------------------------------------------------------
do $$
declare v_ok boolean := false;
begin
  begin perform fn_webhook_evolution('token-errado', '{"event":"messages.upsert","data":{}}');
  exception when others then v_ok := sqlerrm like '%token%'; end;
  perform pg_temp.ok(v_ok, '[T8] webhook aceitou token inválido');
  v_ok := false;
  begin perform fn_webhook_evolution('', '{}');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T8] webhook aceitou token vazio');
end $$;

-- T9 funções do painel -----------------------------------------------------------------------------------
do $$
declare v_n int;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  select count(*) into v_n from app_ponto_hoje();
  perform pg_temp.ok(v_n >= 6, '[T9] app_ponto_hoje');
  select count(*) into v_n from app_ponto_acompanhamento(current_date - 5, current_date);
  perform pg_temp.ok(v_n >= 2000, '[T9] app_ponto_acompanhamento: ' || v_n);
  select count(*) into v_n from app_ponto_espelho(current_date - 5, current_date);
  perform pg_temp.ok(v_n >= 6, '[T9] app_ponto_espelho: ' || v_n);
  perform app_ponto_geo(current_date - 5, current_date);
  -- sem sessão do painel, nada passa
  perform set_config('request.jwt.claims', '', true);
  begin perform app_ponto_hoje(); perform pg_temp.ok(false, '[T9] painel sem sessão respondeu');
  exception when others then
    if sqlerrm like 'FALHA%' then raise; end if;
  end;
end $$;

-- T10 URA só em dia útil, das 08:00 às 20:00, fora de feriado (migration 64) -----------------------
do $$
declare v text;
begin
  perform pg_temp.ok(fn_pascoa(2027) = date '2027-03-28', '[T10] Páscoa 2027');
  select string_agg(caso, ', ') into v from (values
    ('ter 10:00', '2026-10-13 10:00 America/Bahia', true),
    ('ter 07:59', '2026-10-13 07:59 America/Bahia', false),
    ('ter 20:01', '2026-10-13 20:01 America/Bahia', false),
    ('sábado', '2026-10-17 10:00 America/Bahia', false),
    ('domingo', '2026-10-18 10:00 America/Bahia', false),
    ('12/10', '2026-10-12 10:00 America/Bahia', false),
    ('Carnaval', '2027-02-09 10:00 America/Bahia', false),
    ('Sexta-feira Santa', '2027-03-26 10:00 America/Bahia', false),
    ('2 de Julho', '2026-07-02 10:00 America/Bahia', false)) c(caso, m, esperado)
   where fn_ligacao_permitida(m::timestamptz) is distinct from esperado;
  perform pg_temp.ok(v is null, '[T10] regra de ligação errada em: ' || coalesce(v, ''));
end $$;

-- T11 ajustes de ponto com justificativa (migration 65, decisão 52) ----------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_tec uuid; v_outro uuid := (select v::uuid from qa where k = 'tec7');
  d date := current_date - 10; j jsonb; v_dup uuid; v_inc uuid; v_ok boolean; v_n int; r record; x jsonb;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Ajuste Silva', '557999990808', true, true, pg_temp.cpf('808808801'), v_emp, true) returning id into v_tec;
  -- entrada repetida às 07:00 (erro), almoço completo, saída esquecida
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 910000 + i, v_tec, (select cpf from tecnicos where id = v_tec), m, tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (values (1, (d + time '07:00') at time zone 'America/Bahia', 'entrada'),
                 (2, (d + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (3, (d + time '12:00') at time zone 'America/Bahia', 'saida_almoco'),
                 (4, (d + time '13:00') at time zone 'America/Bahia', 'volta_almoco')) v(i, m, tp);
  alter table ponto_marcacoes enable trigger user;
  select id into v_dup from ponto_marcacoes where tecnico_id = v_tec and nsr = 910001;

  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(j->'alertas' ? 'incompleta' and j->>'entrada' = '07:00' and (j->>'ajustes')::int = 0,
                     '[T11] antes do ajuste: ' || j::text);

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- motivo curto ou longo, ação inválida, futuro, fora dos 62 dias, marcação de outro funcionário: recusados
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'curto', p_data => d, p_hora => '17:00', p_tipo => 'saida');
  exception when others then v_ok := sqlerrm like '%pelo menos 10%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou motivo curto');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', repeat('x', 501), p_data => d, p_hora => '17:00', p_tipo => 'saida');
  exception when others then v_ok := sqlerrm like '%500%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou motivo de 501 letras');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'apagar', 'motivo suficiente aqui');
  exception when others then v_ok := sqlerrm like '%inválida%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou ação inválida');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'motivo suficiente aqui', p_data => current_date + 1, p_hora => '08:00', p_tipo => 'saida');
  exception when others then v_ok := sqlerrm like '%futuro%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou marcação no futuro');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'motivo suficiente aqui', p_data => current_date - 70, p_hora => '08:00', p_tipo => 'entrada');
  exception when others then v_ok := sqlerrm like '%62 dias%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou ajuste de 70 dias atrás');
  v_ok := false;
  begin perform app_ponto_ajustar(v_outro, 'desconsiderar', 'motivo suficiente aqui', p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%não encontrada%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou marcação de outro funcionário');

  -- incluir a saída esquecida (hora local da empresa) e desconsiderar a entrada repetida
  x := app_ponto_ajustar(v_tec, 'incluir', 'Esqueceu de bater a saída', p_data => d, p_hora => '17:00', p_tipo => 'saida');
  perform pg_temp.ok(x->>'hora' = '17:00' and (x->>'avisado')::boolean, '[T11] inclusão: ' || x::text);
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'Clicou duas vezes no botão', p_data => d, p_hora => '17:00', p_tipo => 'saida');
  exception when others then v_ok := sqlerrm like '%já foi incluída%'; end;
  perform pg_temp.ok(v_ok, '[T11] incluiu a mesma marcação duas vezes');
  x := app_ponto_ajustar(v_tec, 'desconsiderar', 'Entrada batida em duplicidade', p_marcacao => v_dup);
  perform pg_temp.ok(not (x->>'avisado')::boolean, '[T11] segundo aviso em menos de 5 min');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'De novo a mesma marcação', p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%já foi desconsiderada%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou duas vezes');

  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(not j->'alertas' ? 'incompleta' and j->>'entrada' = '08:00' and j->>'saida' = '17:00'
                     and (j->>'trabalhado_min')::int = 480 and (j->>'ajustes')::int = 2, '[T11] depois do ajuste: ' || j::text);
  perform pg_temp.ok((select count(*) from ponto_marcacoes where tecnico_id = v_tec) = 4, '[T11] marcação original sumiu');
  select * into r from app_ponto_espelho(d, d, v_tec);
  perform pg_temp.ok(r.ajustes = 2 and r.trabalhado_min = 480, '[T11] espelho: ' || coalesce(r.ajustes, -1));

  -- inclusão errada se desfaz desconsiderando a inclusão; a certa entra em seguida
  x := app_ponto_ajustar(v_tec, 'incluir', 'Trabalhou sem celular', p_data => d - 1, p_hora => '09:00', p_tipo => 'entrada');
  v_inc := (x->>'id')::uuid;
  select count(*) into v_n from app_ponto_espelho(d - 1, d - 1, v_tec) e where e.entrada = '09:00';
  perform pg_temp.ok(v_n = 1, '[T11] dia só com ajuste fora do espelho');
  perform app_ponto_ajustar(v_tec, 'desconsiderar', 'Hora digitada errada', p_ajuste => v_inc);
  perform app_ponto_ajustar(v_tec, 'incluir', 'Trabalhou sem celular, hora certa', p_data => d - 1, p_hora => '08:00', p_tipo => 'entrada');
  select * into r from app_ponto_espelho(d - 1, d - 1, v_tec);
  perform pg_temp.ok(r.entrada = '08:00' and r.ajustes = 3, '[T11] inclusão desfeita: ' || coalesce(r.entrada, '-'));
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'De novo a mesma inclusão', p_ajuste => v_inc);
  exception when others then v_ok := sqlerrm like '%já foi desconsiderada%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou a inclusão duas vezes');
  -- índice único segura o alvo mesmo sem passar pela função (dois cliques ao mesmo tempo)
  v_ok := false;
  begin
    insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, acao, motivo, autor)
    values (v_emp, v_tec, v_dup, 'desconsiderar', 'concorrente simultâneo', 'qa');
  exception when unique_violation then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T11] índice único do desconsiderar');

  -- lista do gestor com motivo e autor
  select count(*) into v_n from app_ponto_ajustes(d - 1, d, v_tec) a where a.motivo is not null and a.autor = 'qa-admin@teste.local';
  perform pg_temp.ok(v_n = 5, '[T11] lista de ajustes do admin: ' || v_n);
  select count(*) into v_n from app_ponto_ajustes(d - 1, d, v_tec) a where a.desconsiderado or a.desfaz_inclusao;
  perform pg_temp.ok(v_n = 2, '[T11] inclusão desfeita na lista: ' || v_n);

  -- papel leitura: não lança, vê a lista sem motivo nem autor (decisão 52 A)
  insert into painel_usuarios (email, nome, papel, ativo) values ('qa-leitura@teste.local', 'QA Leitura', 'leitura', true);
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'motivo suficiente aqui', p_data => d, p_hora => '18:00', p_tipo => 'inicio_he');
  exception when others then v_ok := sqlerrm like '%Sem permissão%'; end;
  perform pg_temp.ok(v_ok, '[T11] leitura lançou ajuste');
  select count(*) into v_n from app_ponto_ajustes(d - 1, d, v_tec) a where a.motivo is null and a.autor is null;
  perform pg_temp.ok(v_n = 5, '[T11] leitura viu motivo ou autor');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);

  -- ajuste é imutável, como a marcação
  v_ok := false;
  begin update ponto_ajustes set motivo = 'trocado depois do fato' where tecnico_id = v_tec;
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T11] ajuste foi alterado');
end $$;

-- T12 fuso do motor (Bahia × UTC) ------------------------------------------------------------------------
-- A fila do WhatsApp (vw_acoes_pendentes) compara a escala, gravada em hora local, com now() no fuso da
-- config. Escala daqui a 2 h (hora local) está em UTC 1 h no passado: se o motor comparasse em UTC, ou no
-- fuso da sessão, ela sumiria da fila. A sessão vai para Tóquio de propósito.
do $$
declare
  v_tec uuid := (select v::uuid from qa where k = 'tec2');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_local timestamp := now() at time zone 'America/Bahia';
  v_fut uuid; v_pas uuid; v_acao text; v_n int;
begin
  perform set_config('timezone', 'Asia/Tokyo', true);
  update config set valor = 'America/Bahia' where chave = 'fuso';
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, (v_local + interval '2 hours')::date, (v_local + interval '2 hours')::time(0), 'QA fuso futuro', 'agendada', 'qa')
  returning id into v_fut;
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, (v_local - interval '1 hour')::date, (v_local - interval '1 hour')::time(0), 'QA fuso passado', 'agendada', 'qa')
  returning id into v_pas;

  if v_local::time >= time '23:59' then
    raise notice 'T12: 23:59 local, janela de envio não cobre o minuto; casos da janela pulados';
  else
    update config set valor = '00:00' where chave = 'janela_envio_inicio';
    update config set valor = '23:59' where chave = 'janela_envio_fim';
    select acao into v_acao from vw_acoes_pendentes where escala_id = v_fut;
    perform pg_temp.ok(v_acao = 'enviar_primeira', '[T12] escala daqui a 2 h (hora local) fora da fila: ' || coalesce(v_acao, 'ausente'));
    select count(*) into v_n from vw_acoes_pendentes where escala_id = v_pas;
    perform pg_temp.ok(v_n = 0, '[T12] escala de 1 h atrás (hora local) na fila');
    -- janela de envio também na hora local: fora dela, ninguém na fila
    update config set valor = case when v_local::time < time '12:00' then '13:00' else '01:00' end where chave = 'janela_envio_inicio';
    update config set valor = case when v_local::time < time '12:00' then '14:00' else '02:00' end where chave = 'janela_envio_fim';
    select count(*) into v_n from vw_acoes_pendentes where escala_id = v_fut;
    perform pg_temp.ok(v_n = 0, '[T12] fila ignorou a janela de envio');
  end if;
  -- o fuso da config manda: no Acre (UTC-5, 2 h atrás da Bahia) a escala de 1 h atrás da Bahia ainda não começou
  update config set valor = 'America/Rio_Branco' where chave = 'fuso';
  update config set valor = '00:00' where chave = 'janela_envio_inicio';
  update config set valor = '23:59' where chave = 'janela_envio_fim';
  if (now() at time zone 'America/Rio_Branco')::time < time '23:59' then
    select count(*) into v_n from vw_acoes_pendentes where escala_id = v_pas;
    perform pg_temp.ok(v_n = 1, '[T12] fuso da config não foi usado');
  end if;
  update config set valor = 'America/Bahia' where chave = 'fuso';
  perform set_config('timezone', 'UTC', true);
end $$;

-- T13 habilidades exigidas pelo tipo de atividade ---------------------------------------------------------
do $$
declare
  v_h uuid; v_tipo uuid; j jsonb; x jsonb;
  t1 uuid := (select v::uuid from qa where k = 'tec1');
  t2 uuid := (select v::uuid from qa where k = 'tec2');
  t3 uuid := (select v::uuid from qa where k = 'tec3');
begin
  insert into habilidades (nome, categoria) values ('QA Solda ' || gen_random_uuid(), 'tecnica') returning id into v_h;
  insert into tipos_atividade (nome) values ('QA Manutenção ' || gen_random_uuid()) returning id into v_tipo;
  insert into tipo_atividade_requisitos (tipo_id, habilidade_id, nivel_minimo) values (v_tipo, v_h, 'intermediario');
  insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel) values (t1, v_h, 'avancado'), (t2, v_h, 'basico');

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  j := app_aptidao(v_tipo);
  select e into x from jsonb_array_elements(j) e where e->>'tecnico_id' = t1::text;
  perform pg_temp.ok((x->>'apto')::boolean and jsonb_array_length(x->'faltando') = 0, '[T13] avançado não está apto: ' || coalesce(x::text, '-'));
  select e into x from jsonb_array_elements(j) e where e->>'tecnico_id' = t2::text;
  perform pg_temp.ok(not (x->>'apto')::boolean and x->>'faltando' like '%nível abaixo%', '[T13] básico passou como intermediário: ' || coalesce(x::text, '-'));
  select e into x from jsonb_array_elements(j) e where e->>'tecnico_id' = t3::text;
  perform pg_temp.ok(not (x->>'apto')::boolean and jsonb_array_length(x->'faltando') = 1
                     and x->>'faltando' not like '%nível abaixo%', '[T13] sem a habilidade passou: ' || coalesce(x::text, '-'));
  -- técnico inativo não aparece como opção
  update tecnicos set ativo = false where id = t3;
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(app_aptidao(v_tipo)) e where e->>'tecnico_id' = t3::text),
                     '[T13] técnico inativo na lista de aptos');
  update tecnicos set ativo = true where id = t3;
end $$;

-- T14 justificativa de ponto (migration 66, decisões 55 a 58) ----------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  d1 date := v_hoje - 5; d2 date := v_hoje - 3; d3 date := v_hoje - 2;
  v_tec uuid; v_tel text := '557999990909'; r jsonb; j jsonb; v_ok boolean; v_id uuid; v_ab uuid; v_n int; x record;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Justifica Souza', v_tel, true, true, pg_temp.cpf('909909901'), v_emp, true) returning id into v_tec;
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, d1, '08:00', 'QA falta', 'notificada', 'qa'), (v_tec, v_loc, d3, '08:00', 'QA atraso', 'notificada', 'qa');
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  values (v_emp, 920001, v_tec, (select cpf from tecnicos where id = v_tec), (d3 + time '08:40') at time zone 'America/Bahia',
          'entrada', 'app', -12.9, -38.4, 'qa', md5(random()::text));
  alter table ponto_marcacoes enable trigger user;

  -- falta: dia com escala, já passado, sem marcação
  j := fn_ponto_jornada_dia(v_tec, d1);
  perform pg_temp.ok(j->'alertas' ? 'falta', '[T14] falta não apareceu: ' || coalesce(j::text, 'null'));
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  select count(*) into v_n from app_ponto_espelho(d1, d1, v_tec) e where 'falta' = any(e.alertas);
  perform pg_temp.ok(v_n = 1, '[T14] falta fora do espelho');

  -- abono direto do gestor, repetido recusado, estorno devolve a falta
  r := app_ponto_abonar(v_tec, d1, 'Falta justificada com documento entregue ao RH');
  v_ab := (r->>'id')::uuid;
  perform pg_temp.ok(fn_ponto_jornada_dia(v_tec, d1)->'alertas' ? 'falta_abonada', '[T14] abono não cobriu a falta');
  v_ok := false;
  begin perform app_ponto_abonar(v_tec, d1, 'Falta justificada com documento entregue ao RH');
  exception when others then v_ok := sqlerrm like '%já foi lançado%'; end;
  perform pg_temp.ok(v_ok, '[T14] abono repetido aceito');
  perform app_ponto_estornar_abono(v_ab, 'Abono lançado no dia errado');
  perform pg_temp.ok(fn_ponto_jornada_dia(v_tec, d1)->'alertas' ? 'falta', '[T14] estorno não devolveu a falta');
  v_ok := false;
  begin perform app_ponto_estornar_abono(v_ab, 'Abono lançado no dia errado');
  exception when others then v_ok := sqlerrm like '%já foi estornado%'; end;
  perform pg_temp.ok(v_ok, '[T14] estorno repetido aceito');
  v_ok := false;
  begin update ponto_abonos set motivo = 'trocado depois do fato' where id = v_ab;
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T14] abono foi alterado');

  -- pedido pelo WhatsApp: ajuste -> 4 Ponto -> 1 Esqueci -> dia -> 4 Saída -> 17h05
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J1', '{"conversation":"Ajuste"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_menu', '[T14] menu: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J2', '{"conversation":"2"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_menu', '[T14] família: ' || coalesce(r::text, 'null'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'J3', '{"conversation":"ajuste"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'J4', '{"conversation":"4"}'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J5', '{"conversation":"1"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_pediu_dia', '[T14] motivo: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J6', '{"conversation":"amanhã"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_dia_repetido', '[T14] dia inválido aceito');
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'J7', jsonb_build_object('conversation', to_char(d2, 'DD/MM'))));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J8', '{"conversation":"4"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_pediu_hora', '[T14] marcação: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'J9', '{"conversation":"17h05"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_registrado', '[T14] pedido pelo WhatsApp: ' || coalesce(r::text, 'null'));
  select * into x from ponto_justificativas where tecnico_id = v_tec and canal = 'whatsapp';
  perform pg_temp.ok(x.status = 'pendente' and x.motivo = 'esqueci_marcar' and x.data = d2 and x.tipo_marcacao = 'saida'
                     and x.hora = time '17:05', '[T14] pedido gravado errado');
  -- fora da conversa, número volta a ser das escalas
  perform pg_temp.ok(fn_ponto_wh(pg_temp.msg(v_tel, 'J10', '{"conversation":"1"}')) is null, '[T14] conversa não terminou');

  -- aprovar: marcação incluída por ajuste ligado ao pedido; decidir de novo é recusado
  r := app_ponto_decidir(x.id, true);
  perform pg_temp.ok(exists (select 1 from ponto_ajustes where justificativa_id = x.id and acao = 'incluir' and tipo = 'saida'),
                     '[T14] aprovação sem ajuste');
  perform pg_temp.ok(fn_ponto_jornada_dia(v_tec, d2)->>'saida' = '17:05', '[T14] saída fora do espelho');
  v_ok := false;
  begin perform app_ponto_decidir(x.id, false, 'motivo qualquer longo');
  exception when others then v_ok := sqlerrm like '%já foi decidido%'; end;
  perform pg_temp.ok(v_ok, '[T14] pedido decidido duas vezes');

  -- atraso de 40 min: pedido pelo app (função comum), aprovado vira abono
  perform pg_temp.ok(fn_ponto_jornada_dia(v_tec, d3)->'alertas' ? 'atraso', '[T14] atraso não apareceu');
  r := fn_ponto_justificativa_criar(v_tec, 'atraso_saida', d3, null, null, '08:00', '08:40', 'Ônibus quebrou na BR', 'app');
  v_ok := false;
  begin perform fn_ponto_justificativa_criar(v_tec, 'atraso_saida', d3, null, null, '08:00', '08:40', null, 'app');
  exception when others then v_ok := sqlerrm like '%pedido igual%'; end;
  perform pg_temp.ok(v_ok, '[T14] pedido repetido aceito');
  perform app_ponto_decidir((r->>'id')::uuid, true);
  perform pg_temp.ok(fn_ponto_jornada_dia(v_tec, d3)->'alertas' ? 'atraso_abonado', '[T14] atraso não abonado: '
                     || (fn_ponto_jornada_dia(v_tec, d3))::text);

  -- negar exige motivo; dia futuro e sessão inválida recusados
  r := fn_ponto_justificativa_criar(v_tec, 'falha_registro', d1, 'entrada', '08:00', null, null, null, 'app');
  v_ok := false;
  begin perform app_ponto_decidir((r->>'id')::uuid, false, 'curto');
  exception when others then v_ok := sqlerrm like '%pelo menos 10%'; end;
  perform pg_temp.ok(v_ok, '[T14] negativa sem motivo aceita');
  perform app_ponto_decidir((r->>'id')::uuid, false, 'Não há registro do funcionário na obra nesse dia');
  perform pg_temp.ok((select status from ponto_justificativas where id = (r->>'id')::uuid) = 'negada', '[T14] negativa não gravou');
  v_ok := false;
  begin perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', v_hoje + 1, 'entrada', '08:00', null, null, null, 'app');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T14] pedido para o futuro aceito');
  v_ok := false;
  begin perform ponto_justificar('token-invalido', 'esqueci_marcar', d2, 'entrada', '08:00');
  exception when others then v_ok := sqlerrm like '%Sessão%'; end;
  perform pg_temp.ok(v_ok, '[T14] app sem sessão aceito');

  -- leitura: vê os pedidos sem observação nem resposta, e não decide
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  select count(*) into v_n from app_ponto_justificativas(d1, v_hoje, v_tec) a where a.observacao is null and a.resposta is null;
  perform pg_temp.ok(v_n = 3, '[T14] leitura viu observação ou resposta: ' || v_n);
  v_ok := false;
  begin perform app_ponto_abonar(v_tec, d1, 'Falta justificada com documento entregue');
  exception when others then v_ok := sqlerrm like '%Sem permissão%'; end;
  perform pg_temp.ok(v_ok, '[T14] leitura abonou');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T15 atestado no cofre (migration 68, decisão 56) -------------------------------------------------------
do $$
declare
  v_tok  text := (select v from qa where k = 'token');
  v_tec  uuid := (select v::uuid from qa where k = 'tec1');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  d date := v_hoje - 8;
  v_jpg  bytea := '\xffd8ffe000104a46494600010100000100010000ffd9'::bytea;
  r jsonb; v_id uuid; v_anexo uuid; v_ok boolean; x record; v_n int;
begin
  -- documento obrigatório e conferido pelos primeiros bytes
  v_ok := false;
  begin perform ponto_justificar_atestado(v_tok, 'atestado', d, d + 1);
  exception when others then v_ok := sqlerrm like '%Falta o documento%'; end;
  perform pg_temp.ok(v_ok, '[T15] atestado sem documento aceito');
  v_ok := false;
  begin perform ponto_justificar_atestado(v_tok, 'atestado', d, d + 1, null, encode(v_jpg, 'base64'), 'application/pdf');
  exception when others then v_ok := sqlerrm like '%foto (JPG ou PNG) ou PDF%'; end;
  perform pg_temp.ok(v_ok, '[T15] tipo falso aceito');
  r := ponto_justificar_atestado(v_tok, 'atestado', d, d + 1, 'Fui ao posto de saúde', encode(v_jpg, 'base64'), 'image/jpeg');
  select * into x from ponto_justificativas where numero = (r->>'numero')::bigint;
  v_id := x.id;
  perform pg_temp.ok(x.status = 'pendente' and x.data_fim = d + 1 and x.canal = 'app', '[T15] pedido de atestado gravado errado');
  select id into v_anexo from ponto_justificativa_anexos where justificativa_id = v_id;
  perform pg_temp.ok((select conteudo from ponto_justificativa_anexos where id = v_anexo) <> v_jpg
                     and position(v_jpg in (select conteudo from ponto_justificativa_anexos where id = v_anexo)) = 0,
                     '[T15] documento guardado sem cifrar');

  -- admin sem "vê atestados": vê só que existe, não decide, não abre o documento
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  select * into x from app_ponto_justificativas(d, d, v_tec) a where a.id = v_id;
  perform pg_temp.ok(x.restrito and not x.pode_decidir and x.motivo_nome = 'Justificativa de saúde' and x.motivo = 'saude'
                     and x.observacao is null, '[T15] saúde aberta para quem não vê atestados: ' || x.motivo);
  v_ok := false;
  begin perform app_ponto_decidir(v_id, true); exception when others then v_ok := sqlerrm like '%atestados%'; end;
  perform pg_temp.ok(v_ok, '[T15] decidiu saúde sem permissão');
  v_ok := false;
  begin perform app_ponto_anexo_ver(v_anexo); exception when others then v_ok := sqlerrm like '%atestados%'; end;
  perform pg_temp.ok(v_ok, '[T15] abriu documento sem permissão');

  -- com a permissão: abre (registrado), decide, abono de cada dia
  perform app_definir_ve_saude('qa-admin@teste.local', true);
  r := app_ponto_anexo_ver(v_anexo);
  perform pg_temp.ok(decode(r->>'conteudo', 'base64') = v_jpg and r->>'tipo' = 'image/jpeg', '[T15] documento não voltou igual');
  perform pg_temp.ok((select count(*) from ponto_anexo_acessos where anexo_id = v_anexo) = 1, '[T15] acesso não registrado');
  select * into x from app_ponto_justificativas(d, d, v_tec) a where a.id = v_id;
  perform pg_temp.ok(not x.restrito and x.pode_decidir and x.anexos = 1 and x.motivo_nome = 'Atestado médico', '[T15] visão de quem vê atestados');
  perform app_ponto_decidir(v_id, true);
  perform pg_temp.ok((select count(*) from ponto_abonos where justificativa_id = v_id and inicio is null) = 2, '[T15] abono dos 2 dias');

  -- limite legal alerta e não bloqueia: doação de sangue duas vezes em 12 meses
  r := ponto_justificar_falta(v_tok, 'doacao_sangue', d - 20, null, null, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(r->>'alerta' is null, '[T15] alerta na primeira doação');
  r := ponto_justificar_falta(v_tok, 'doacao_sangue', d - 10, null, null, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(r->>'alerta' like 'A lei garante 1 dias a cada 12 meses%', '[T15] limite não alertou: ' || coalesce(r->>'alerta', 'nulo'));

  -- leitura: nunca vê saúde nem ganha a permissão
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  select count(*) into v_n from app_ponto_justificativas(d - 20, d, v_tec) a where a.motivo_nome = 'Justificativa de saúde' and a.restrito;
  perform pg_temp.ok(v_n >= 1, '[T15] leitura viu motivo de saúde');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_definir_ve_saude('qa-leitura@teste.local', true); exception when others then v_ok := sqlerrm like '%admin ou gestor%'; end;
  perform pg_temp.ok(v_ok, '[T15] leitura ganhou ver atestados');
  -- descarte controlado: o documento sai, a marca e o histórico de acesso ficam
  perform app_definir_ve_saude('qa-admin@teste.local', true);
  perform app_ponto_anexo_descartar(v_anexo, 'Enviado por engano pelo funcionário');
  perform pg_temp.ok(not exists (select 1 from ponto_justificativa_anexos where id = v_anexo)
                     and exists (select 1 from ponto_anexos_descartados where anexo_id = v_anexo)
                     and (select count(*) from ponto_anexo_acessos where anexo_id = v_anexo) = 1, '[T15] descarte');
  perform pg_temp.ok((select count(*) from app_ve_saude_historico() h where h.email = 'qa-admin@teste.local') >= 2, '[T15] histórico da permissão');
  perform app_definir_ve_saude('qa-admin@teste.local', false);

  -- foto pelo WhatsApp: recusada (documento só pelo app)
  r := fn_ponto_wh(pg_temp.msg((select telefone_e164 from tecnicos where id = v_tec), 'F1',
                               '{"imageMessage":{"caption":"atestado","mimetype":"image/jpeg"}}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_midia_recusada', '[T15] foto pelo WhatsApp: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg((select telefone_e164 from tecnicos where id = v_tec), 'F2',
                               '{"ephemeralMessage":{"message":{"imageMessage":{"caption":"x"}}}}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_midia_recusada', '[T15] foto em mensagem temporária: ' || coalesce(r::text, 'null'));
  -- família sem a permissão: não decide (documento só para quem vê atestados e documentos)
  r := ponto_justificar_falta(v_tok, 'casamento', d - 30, d - 28, null, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  select * into x from app_ponto_justificativas(d - 30, d - 30, v_tec) a where a.numero = (r->>'numero')::bigint;
  perform pg_temp.ok(x.restrito and not x.pode_decidir and x.motivo = 'casamento', '[T15] família sem permissão decidível');
  v_ok := false;
  begin perform app_ponto_decidir(x.id, true); exception when others then v_ok := sqlerrm like '%documentos%'; end;
  perform pg_temp.ok(v_ok, '[T15] decidiu família sem permissão');
end $$;

-- T16 validade do atestado bloqueia ponto e escala; alta médica libera (migration 69, decisão 60) -------
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_loc  uuid := (select v::uuid from qa where k = 'loc');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  v_jpg  bytea := '\xffd8ffe000104a46494600010100000100010000ffd9'::bytea;
  v_tec uuid; v_cpf text := pg_temp.cpf('161616101'); v_tok text; r jsonb; ra jsonb; v_ok boolean; c jsonb;
  v_esc uuid; v_janela boolean := (now() at time zone 'America/Bahia')::time < time '23:59';
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Afastado Lima', '557999991616', true, true, v_cpf, v_emp, true) returning id into v_tec;
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  c := app_ponto_gerar_codigo(v_tec);
  v_tok := ponto_entrar(v_cpf, c->>'codigo')->>'token';
  perform ponto_registrar_ciencia(v_tok, 'qa');
  -- escala marcada antes do atestado, dentro do período
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, v_hoje + 2, '08:00', 'QA escala antes do atestado', 'agendada', 'qa') returning id into v_esc;

  -- validade obrigatória; o caminho genérico não aceita atestado
  v_ok := false;
  begin perform ponto_justificar_atestado(v_tok, 'atestado', v_hoje - 1, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  exception when others then v_ok := sqlerrm like '%até quando vale%'; end;
  perform pg_temp.ok(v_ok, '[T16] atestado sem validade aceito');
  v_ok := false;
  begin perform ponto_justificar_falta(v_tok, 'atestado', v_hoje - 1, v_hoje + 2, null, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  exception when others then v_ok := sqlerrm like '%envio próprio%'; end;
  perform pg_temp.ok(v_ok, '[T16] atestado pelo caminho genérico');
  r := ponto_justificar_atestado(v_tok, 'atestado', v_hoje - 1, v_hoje + 2, null, encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(ponto_eu(v_tok, 'qa')->>'afastado_ate' = to_char(v_hoje + 2, 'DD/MM/YYYY'), '[T16] app não sabe do afastamento');

  -- sem ponto, sem escala nova e o motor não envia a escala antiga
  v_ok := false;
  begin perform ponto_bater(v_tok, 'entrada', -12.900100, -38.400100, 10, 'qa');
  exception when others then v_ok := sqlerrm like '%afastado até%' and sqlerrm like '%liberação médica em mãos%gestor%'; end;
  perform pg_temp.ok(v_ok, '[T16] afastado bateu ponto');
  v_ok := false;
  begin
    insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
    values (v_tec, v_loc, v_hoje + 1, '08:00', 'QA afastado', 'agendada', 'qa');
  exception when others then v_ok := sqlerrm like '%afastado%'; end;
  perform pg_temp.ok(v_ok, '[T16] afastado recebeu escala');
  if v_janela then
    update config set valor = '00:00' where chave = 'janela_envio_inicio';
    update config set valor = '23:59' where chave = 'janela_envio_fim';
    perform pg_temp.ok(not exists (select 1 from vw_acoes_pendentes where escala_id = v_esc), '[T16] motor enviaria escala do afastado');
  end if;
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, v_hoje + 3, '08:00', 'QA depois do afastamento', 'agendada', 'qa');

  -- alta médica hoje libera ponto, escala e motor
  ra := ponto_justificar_atestado(v_tok, 'alta_medica', v_hoje, null, null, encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(ponto_eu(v_tok, 'qa')->>'afastado_ate' is null, '[T16] alta não liberou');
  c := ponto_bater(v_tok, 'entrada', -12.900100, -38.400100, 10, 'qa');
  perform pg_temp.ok(c ? 'nsr', '[T16] liberado não bateu ponto');
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, v_hoje + 1, '08:00', 'QA liberado', 'agendada', 'qa');
  if v_janela then
    perform pg_temp.ok(exists (select 1 from vw_acoes_pendentes where escala_id = v_esc), '[T16] motor não voltou a enviar');
  end if;

  -- aprovar: o atestado abona só até a véspera da alta; a alta não abona
  perform app_definir_ve_saude('qa-admin@teste.local', true);
  perform app_ponto_decidir((select id from ponto_justificativas where numero = (r->>'numero')::bigint), true);
  perform pg_temp.ok((select array_agg(a.data order by a.data) from ponto_abonos a join ponto_justificativas j on j.id = a.justificativa_id
                       where j.numero = (r->>'numero')::bigint) = array[v_hoje - 1], '[T16] abono depois da alta');
  perform app_ponto_decidir((select id from ponto_justificativas where numero = (ra->>'numero')::bigint), true);
  perform pg_temp.ok(not exists (select 1 from ponto_abonos a join ponto_justificativas j on j.id = a.justificativa_id
                                  where j.numero = (ra->>'numero')::bigint), '[T16] alta gerou abono');

  -- atestado novo depois da alta volta a bloquear; negado, libera
  r := ponto_justificar_atestado(v_tok, 'atestado', v_hoje, v_hoje + 1, null, encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(ponto_eu(v_tok, 'qa')->>'afastado_ate' is not null, '[T16] alta antiga anulou atestado novo');
  perform app_ponto_decidir((select id from ponto_justificativas where numero = (r->>'numero')::bigint), false, 'Documento ilegível, envie de novo');
  perform pg_temp.ok(ponto_eu(v_tok, 'qa')->>'afastado_ate' is null, '[T16] atestado negado continuou bloqueando');
  perform app_definir_ve_saude('qa-admin@teste.local', false);
end $$;

-- T17 documento pelo WhatsApp (migration 70, E2b) ----------------------------------------------------
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  v_jpg  bytea := '\xffd8ffe000104a46494600010100000100010000ffd9'::bytea;
  v_tel  text := '557999991717';
  v_tec  uuid; r jsonb; x record; n int := 0;
  img    jsonb := '{"imageMessage":{"mimetype":"image/jpeg","fileLength":{"low":1000,"high":0,"unsigned":true}}}';
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Documento Reis', v_tel, true, true, pg_temp.cpf('171717101'), v_emp, true) returning id into v_tec;

  -- fora do pedido, arquivo continua recusado
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K0', img));
  perform pg_temp.ok(r->>'acao' = 'ponto_midia_recusada', '[T17] arquivo fora do pedido: ' || coalesce(r::text, 'null'));

  -- ajuste -> 1 Saúde -> opção inválida -> 1 Atestado -> primeiro dia -> válido até -> documento
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K1', '{"conversation":"ajuste"}'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K2', '{"conversation":"1"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_menu' and r->>'grupo' = 'saude', '[T17] menu saúde: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K3', '{"conversation":"99"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_menu_repetido', '[T17] opção inexistente aceita');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K4', '{"conversation":"1"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_pediu_dia', '[T17] motivo: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K5', jsonb_build_object('conversation', to_char(v_hoje - 1, 'DD/MM'))));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_pediu_fim', '[T17] dia: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K6', jsonb_build_object('conversation', to_char(v_hoje + 60, 'DD/MM'))));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_fim_repetido', '[T17] validade longe demais aceita');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K7', jsonb_build_object('conversation', to_char(v_hoje + 1, 'DD/MM'))));
  perform pg_temp.ok(r->>'acao' = 'ajuste_pediu_documento', '[T17] validade: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K8', '{"conversation":"já mando"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_aguardando_documento', '[T17] texto na etapa do documento');

  -- formato, tipo e tamanho conferidos antes de baixar
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K9', '{"videoMessage":{"mimetype":"video/mp4"}}'));
  perform pg_temp.ok(r->>'motivo' = 'formato', '[T17] vídeo aceito: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K10', '{"viewOnceMessageV2":{"message":{"imageMessage":{"mimetype":"image/jpeg"}}}}'));
  perform pg_temp.ok(r->>'motivo' = 'formato', '[T17] visualização única aceita: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K11', '{"documentMessage":{"mimetype":"application/msword","fileLength":"1000"}}'));
  perform pg_temp.ok(r->>'motivo' = 'tipo', '[T17] Word aceito');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K12', '{"documentMessage":{"mimetype":"application/pdf","fileLength":"9000000"}}'));
  perform pg_temp.ok(r->>'motivo' = 'tamanho', '[T17] PDF de 9 MB aceito');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K12b', '{"imageMessage":{"mimetype":"image/jpeg"}}'));
  perform pg_temp.ok(r->>'motivo' = 'tamanho', '[T17] arquivo sem tamanho aceito');

  -- download falhou: libera para reenviar; conteúdo falso: recusado e a etapa continua
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K13', img));
  perform pg_temp.ok(r->>'acao' = 'ponto_baixar_midia' and r->>'midia_id' = 'K13' and r->>'tecnico' = v_tec::text,
                     '[T17] baixar: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K13', img));
  perform pg_temp.ok(r ? 'ignorado', '[T17] arquivo repetido baixado de novo');
  r := fn_ponto_midia_falhou(v_tec, 'K13');
  perform pg_temp.ok(r->>'acao' = 'ponto_documento_falhou', '[T17] falha no download: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K14', img));
  r := fn_ponto_midia_receber(v_tec, 'K14', encode('%PDF-1.4 x'::bytea, 'base64'), 'image/jpeg');
  perform pg_temp.ok(r->>'motivo' = 'conteudo', '[T17] PDF disfarçado de foto aceito: ' || coalesce(r::text, 'null'));
  perform pg_temp.ok((select etapa from ponto_conversas where tecnico_id = v_tec and expira_em > now()) = 'aj_documento',
                     '[T17] etapa do documento fechou depois de arquivo inválido');

  -- arquivo certo: pedido pelo WhatsApp, cifrado no cofre, afastamento valendo
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K15', img));
  perform pg_temp.ok(fn_ponto_midia_receber(v_tec, 'K13', encode(v_jpg, 'base64'), 'image/jpeg') ? 'ignorado',
                     '[T17] arquivo de outra mensagem aceito');
  r := fn_ponto_midia_receber(v_tec, 'K15', encode(v_jpg, 'base64'), 'image/jpeg');
  perform pg_temp.ok(r->>'acao' = 'ajuste_registrado', '[T17] pedido: ' || coalesce(r::text, 'null'));
  select * into x from ponto_justificativas where numero = (r->>'numero')::bigint;
  perform pg_temp.ok(x.motivo = 'atestado' and x.canal = 'whatsapp' and x.data = v_hoje - 1 and x.data_fim = v_hoje + 1,
                     '[T17] pedido gravado errado');
  perform pg_temp.ok((select count(*) from ponto_justificativa_anexos a where a.justificativa_id = x.id
                       and position(v_jpg in a.conteudo) = 0) = 1, '[T17] documento fora do cofre');
  perform pg_temp.ok(fn_ponto_afastado_ate(v_tec, v_hoje) = v_hoje + 1, '[T17] atestado pelo WhatsApp não afastou');
  perform pg_temp.ok(not exists (select 1 from ponto_conversas where tecnico_id = v_tec and expira_em > now()), '[T17] conversa ficou aberta');
  perform pg_temp.ok(fn_ponto_midia_receber(v_tec, 'K15', encode(v_jpg, 'base64'), 'image/jpeg') ? 'ignorado', '[T17] pedido duplicado');

  -- Família: falecimento, último dia "mesmo"; Saúde por horário: declaração de comparecimento
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K20', '{"conversation":"ajuste"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K21', '{"conversation":"2"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K22', '{"conversation":"1"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K23', '{"conversation":"ontem"}'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K24', '{"conversation":"Mesmo"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_pediu_documento', '[T17] família: ' || coalesce(r::text, 'null'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K25', '{"documentWithCaptionMessage":{"message":{"documentMessage":{"mimetype":"application/pdf","fileLength":2000}}}}'));
  r := fn_ponto_midia_receber(v_tec, 'K25', encode('%PDF-1.4 certidao'::bytea, 'base64'), 'application/pdf');
  select * into x from ponto_justificativas where numero = (r->>'numero')::bigint;
  perform pg_temp.ok(x.motivo = 'falecimento' and x.data = v_hoje - 1 and x.data_fim = v_hoje - 1, '[T17] falecimento: ' || coalesce(r::text, 'null'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K30', '{"conversation":"ajuste"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K31', '{"conversation":"1"}'));
  perform fn_ponto_wh(pg_temp.msg(v_tel, 'K32', '{"conversation":"2"}'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K33', jsonb_build_object('conversation', to_char(v_hoje - 2, 'DD/MM'))));
  perform pg_temp.ok(r->>'acao' = 'ajuste_falta_pediu_periodo', '[T17] comparecimento sem horário: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K34', '{"conversation":"8h às 10h"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_pediu_documento', '[T17] horário: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K35', '{"conversation":"0"}'));
  perform pg_temp.ok(r->>'acao' = 'ajuste_cancelado', '[T17] cancelar na etapa do documento');
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'K36', img));
  perform pg_temp.ok(r->>'acao' = 'ponto_midia_recusada', '[T17] arquivo aceito depois de cancelar');
end $$;

-- T18 registro do documento e QR de verificação (migration 71, decisão 62) ----------------------------
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_tec  uuid := (select id from tecnicos where telefone_e164 = '557999991717');
  v_anexo uuid; v_cod text; r jsonb; v_ok boolean; v_n int; v_max bigint; v_min bigint; x record;
begin
  -- todo documento do cofre tem registro; na empresa, a numeração não tem lacuna nem repetição
  perform pg_temp.ok(not exists (select 1 from ponto_justificativa_anexos a
                                  where not exists (select 1 from ponto_documento_registros d where d.anexo_id = a.id)),
                     '[T18] documento sem registro');
  select count(*), min(registro), max(registro) into v_n, v_min, v_max from ponto_documento_registros where empresa_id = v_emp;
  perform pg_temp.ok(v_n > 0 and v_min = 1 and v_max = v_n, '[T18] numeração com lacuna: ' || v_n || ' de ' || v_min || ' a ' || v_max);
  perform pg_temp.ok((select ultimo from ponto_documento_sequencia where empresa_id = v_emp) = v_max, '[T18] contador fora do último registro');
  perform pg_temp.ok(not exists (select 1 from ponto_documento_registros where codigo !~ '^[A-Z2-7]{16}$'), '[T18] código fora do formato');

  select a.id, d.codigo into v_anexo, v_cod
    from ponto_justificativa_anexos a join ponto_justificativas j on j.id = a.justificativa_id
    join ponto_documento_registros d on d.anexo_id = a.id
   where j.tecnico_id = v_tec and j.motivo = 'atestado';

  -- cofre: timbre com registro, recebimento e integridade
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform app_definir_ve_saude('qa-admin@teste.local', true);
  r := app_ponto_anexo_ver(v_anexo);
  perform pg_temp.ok(r->>'registro' ~ '^\d{6}$' and r->>'codigo' = v_cod and (r->>'integro')::boolean and r->>'canal' = 'WhatsApp'
                     and r->>'recebido_em' ~ '^\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2}$', '[T18] timbre: ' || (r - 'conteudo')::text);

  -- QR: confere com código digitado de qualquer jeito; não mostra o documento
  r := app_ponto_verificar_documento(lower(substr(v_cod, 1, 8)) || '-' || substr(v_cod, 9));
  perform pg_temp.ok((r->>'encontrado')::boolean and (r->>'integro')::boolean and r->>'motivo' = 'Atestado médico'
                     and not r ? 'conteudo', '[T18] verificação: ' || coalesce(r::text, 'null'));
  perform app_definir_ve_saude('qa-admin@teste.local', false);
  r := app_ponto_verificar_documento(v_cod);
  perform pg_temp.ok(r->>'motivo' = 'Justificativa de saúde', '[T18] motivo de saúde aberto na verificação');
  r := app_ponto_verificar_documento('AAAAAAAAAAAAAAAA');
  perform pg_temp.ok(not (r->>'encontrado')::boolean, '[T18] código inventado encontrado');
  perform pg_temp.ok((select count(*) from ponto_documento_verificacoes where email = 'qa-admin@teste.local') >= 3, '[T18] verificação sem registro');

  -- registro imutável; o documento descartado continua com o registro
  v_ok := false;
  begin update ponto_documento_registros set registro = 999 where anexo_id = v_anexo;
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T18] registro foi alterado');
  v_ok := false;
  begin update ponto_documento_sequencia set ultimo = ultimo + 5 where empresa_id = v_emp;
  exception when others then v_ok := sqlerrm like '%de um em um%'; end;
  perform pg_temp.ok(v_ok, '[T18] contador pulou números');
  perform app_definir_ve_saude('qa-admin@teste.local', true);
  perform app_ponto_anexo_descartar(v_anexo, 'Documento enviado por engano no teste');
  r := app_ponto_verificar_documento(v_cod);
  perform pg_temp.ok((r->>'descartado')::boolean and r->>'integro' is null, '[T18] descarte: ' || coalesce(r::text, 'null'));
  perform app_definir_ve_saude('qa-admin@teste.local', false);
end $$;

-- T19 reincidência, pedido parado e métrica (migration 72, E3) ----------------------------------------
do $$
declare
  v_tec  uuid := (select id from tecnicos where telefone_e164 = '557999991717');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  v_id   uuid; x record; m jsonb; v_n int;
  v_janela boolean := extract(isodow from now() at time zone 'America/Bahia') between 1 and 5
                      and (now() at time zone 'America/Bahia')::time between time '08:00' and time '18:00'
                      and not exists (select 1 from feriados f where f.data = (now() at time zone 'America/Bahia')::date);
begin
  -- 04/01/2030 é sexta; 08/01 vira feriado só neste teste: até a quarta, 09/01, sobram 2 dias úteis (07 e 09)
  insert into feriados (data, nome, abrangencia) values ('2030-01-08', 'QA', 'nacional') on conflict do nothing;
  perform pg_temp.ok(fn_dias_uteis('2030-01-04', '2030-01-09') = 2, '[T19] dias úteis: ' || fn_dias_uteis('2030-01-04', '2030-01-09'));
  perform pg_temp.ok(fn_dias_uteis('2030-01-09', '2030-01-04') = 0, '[T19] intervalo invertido');

  -- reincidência só de Ponto: atestado e falecimento (T17) não contam; dois pedidos de Ponto contam 2
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  select * into x from app_ponto_justificativas(v_hoje - 3, v_hoje, v_tec) a where a.motivo = 'falecimento';
  perform pg_temp.ok(x.ponto_30d is null and x.dias_uteis_espera is not null, '[T19] falta legal contada como reincidência');
  perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', v_hoje - 1, 'entrada', time '08:00', null, null, null, 'app');
  perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', v_hoje - 2, 'entrada', time '08:00', null, null, null, 'app');
  select max(a.ponto_30d) into v_n from app_ponto_justificativas(v_hoje - 3, v_hoje, v_tec) a where a.grupo = 'ponto';
  perform pg_temp.ok(v_n = 2, '[T19] reincidência de Ponto: ' || coalesce(v_n::text, 'null'));

  -- pedido parado: o falecimento passa a ter 10 dias
  v_id := x.id;
  alter table ponto_justificativas disable trigger user;
  update ponto_justificativas set created_at = now() - interval '10 days' where id = v_id;
  alter table ponto_justificativas enable trigger user;
  select * into x from app_ponto_justificativas(v_hoje - 3, v_hoje, v_tec) a where a.id = v_id;
  perform pg_temp.ok(x.dias_uteis_espera > 2, '[T19] pedido de 10 dias não aparece parado: ' || coalesce(x.dias_uteis_espera::text, 'null'));
  m := app_ponto_justificativas_metricas(v_hoje - 30, v_hoje);
  perform pg_temp.ok((m->>'parados')::int >= 1 and m ? 'no_prazo' and m ? 'inclusoes_manuais', '[T19] métrica: ' || m::text);

  -- alerta: um por empresa por dia útil, dentro do horário; o cron do ponto chama sem quebrar o lembrete
  delete from alertas_enviados where tipo like 'ponto_parados_%';
  v_n := fn_ponto_alerta_pedidos_parados();
  if v_janela then
    perform pg_temp.ok(v_n >= 1, '[T19] alerta de pedido parado não saiu');
    perform pg_temp.ok(fn_ponto_alerta_pedidos_parados() = 0, '[T19] alerta repetido no mesmo dia');
  else
    perform pg_temp.ok(v_n = 0, '[T19] alerta fora do dia útil ou do horário');
    raise notice 'T19: fora de dia útil ou do horário; envio do alerta não conferido';
  end if;
  perform fn_ponto_lembrete_almoco();
end $$;

-- T20 alta pelo gestor (migration 74, decisão 64) -------------------------------------------------------
do $$
declare
  v_tec  uuid := (select id from tecnicos where telefone_e164 = '557999991717');
  v_hoje date := (now() at time zone 'America/Bahia')::date;
  v_jpg  bytea := '\xffd8ffe000104a46494600010100000100010000ffd9'::bytea;
  r jsonb; x record; v_ok boolean;
begin
  -- o funcionário do T17 está afastado (atestado de ontem até amanhã)
  perform pg_temp.ok(fn_ponto_afastado_ate(v_tec, v_hoje) = v_hoje + 1, '[T20] funcionário do T17 não está afastado');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_registrar_alta(v_tec, v_hoje, encode(v_jpg, 'base64'), 'image/jpeg');
  exception when others then v_ok := sqlerrm like '%ver atestados%'; end;
  perform pg_temp.ok(v_ok, '[T20] alta registrada sem "vê atestados"');

  perform app_definir_ve_saude('qa-admin@teste.local', true);
  select * into x from app_ponto_afastados() a where a.tecnico_id = v_tec;
  perform pg_temp.ok(x.afastado_ate = v_hoje + 1 and x.pode_registrar_alta, '[T20] lista de afastados');
  v_ok := false;
  begin perform app_ponto_registrar_alta(v_tec, v_hoje, null, null);
  exception when others then v_ok := sqlerrm like '%liberação médica%'; end;
  perform pg_temp.ok(v_ok, '[T20] alta sem documento aceita');

  r := app_ponto_registrar_alta(v_tec, v_hoje, encode(v_jpg, 'base64'), 'image/jpeg', 'Liberação entregue ao gestor');
  select * into x from ponto_justificativas where numero = (r->>'numero')::bigint;
  perform pg_temp.ok(x.motivo = 'alta_medica' and x.canal = 'painel' and x.status = 'aprovada' and x.data = v_hoje,
                     '[T20] alta gravada errado: ' || r::text);
  perform pg_temp.ok(exists (select 1 from ponto_justificativa_anexos a join ponto_documento_registros d on d.anexo_id = a.id
                              where a.justificativa_id = x.id), '[T20] liberação fora do cofre');
  perform pg_temp.ok(fn_ponto_afastado_ate(v_tec, v_hoje) is null and r->>'afastado_ate' is null, '[T20] alta não liberou');
  perform pg_temp.ok(not exists (select 1 from app_ponto_afastados() a where a.tecnico_id = v_tec), '[T20] continua na lista de afastados');
  v_ok := false;
  begin perform app_ponto_registrar_alta(v_tec, v_hoje, encode(v_jpg, 'base64'), 'image/jpeg');
  exception when others then v_ok := sqlerrm like '%não está afastado%'; end;
  perform pg_temp.ok(v_ok, '[T20] alta repetida aceita');
  perform app_definir_ve_saude('qa-admin@teste.local', false);
end $$;

-- T21 alerta da escala de amanhã na véspera de feriado (migration 75, decisão 65) --------------------------
do $$
declare v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
begin
  insert into feriados (data, nome, abrangencia) values (v_amanha, 'QA feriado', 'nacional') on conflict do nothing;
  delete from alertas_enviados where tipo in ('aviso', 'prazo') and data_ref = v_amanha;
  update config set valor = '00:00' where chave = 'alerta_escala_aviso';
  update config set valor = '23:59' where chave = 'alerta_escala_prazo';
  update config set valor = '1,2,3,4,5,6,7' where chave = 'alerta_dias_semana';
  perform fn_alerta_prazo_escala();
  perform pg_temp.ok(not exists (select 1 from alertas_enviados where tipo in ('aviso', 'prazo') and data_ref = v_amanha),
                     '[T21] alerta da escala saiu na véspera de feriado');
  -- sem o feriado, o mesmo horário gera o registro do aviso
  delete from feriados where data = v_amanha and nome = 'QA feriado';
  if not exists (select 1 from feriados where data = v_amanha) then
    perform fn_alerta_prazo_escala();
    perform pg_temp.ok(exists (select 1 from alertas_enviados where tipo = 'aviso' and data_ref = v_amanha),
                       '[T21] sem feriado, o aviso não foi registrado');
  end if;
end $$;

-- T22 limpeza da estrutura (migration 76, decisão 66) -----------------------------------------------------
do $$
declare r jsonb; x jsonb;
begin
  perform pg_temp.ok(to_regprocedure('app_config()') is null and to_regprocedure('app_documentos_expirados()') is null
                     and to_regprocedure('app_salvar_tecnico_habilidade(jsonb)') is null
                     and to_regprocedure('app_ponto_marcacoes(date,date,uuid)') is null
                     and to_regprocedure('fn_set_ator(text)') is null and to_regclass('vw_resumo_dia') is null,
                     '[T22] objeto sem chamador continua no banco');
  perform pg_temp.ok(to_regclass('vw_documentos_expirados') is not null, '[T22] view da consulta de retenção removida');
  -- banco sem a tarefa limpeza-logs: o Checklist aponta a falta (só onde o pg_cron existe)
  if to_regclass('cron.job') is not null and not exists (select 1 from cron.job where jobname = 'limpeza-logs') then
    update config set valor = 'producao' where chave = 'ambiente';
    perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
    r := app_checklist_saude();
    select e into x from jsonb_array_elements(r->'itens') e where e->>'item' = 'Tarefas agendadas (cron)';
    perform pg_temp.ok(x->>'estado' = 'falha' and x->>'detalhe' like '%limpeza-logs%', '[T22] Checklist sem a tarefa faltando: ' || coalesce(x::text, 'null'));
  else
    raise notice 'T22: sem pg_cron ou com limpeza-logs agendada; item do Checklist não conferido';
  end if;
end $$;

-- T23 feriado no painel e MFA (migration 77, decisões 65 e 67) ---------------------------------------------
do $$
declare v_dia date := '2030-01-08'; r jsonb; v_ok boolean;
begin
  update config set valor = '1,2,3,4,5' where chave = 'alerta_dias_semana';
  insert into feriados (data, nome, abrangencia) values (v_dia, 'QA feriado', 'nacional') on conflict do nothing;
  r := fn_pendencias_escala(v_dia);
  perform pg_temp.ok(not (r->>'exige_escala')::boolean and r->>'feriado' is not null and r ? 'afastados', '[T23] feriado exigindo escala: ' || r::text);
  perform pg_temp.ok((fn_pendencias_escala('2030-01-09')->>'exige_escala')::boolean, '[T23] dia útil sem exigir escala');

  -- MFA: desligado não muda nada; ligado exige aal2
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated","aal":"aal1"}', true);
  perform app_exigir(array['admin']);
  update config set valor = 'true' where chave = 'mfa_obrigatorio';
  v_ok := false;
  begin perform app_exigir(array['admin']);
  exception when others then v_ok := sqlerrm like '%autenticador%'; end;
  perform pg_temp.ok(v_ok, '[T23] MFA obrigatório aceitou sessão sem o código');
  perform pg_temp.ok((app_meu_acesso()->>'mfa_obrigatorio')::boolean, '[T23] painel não sabe que o MFA é obrigatório');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated","aal":"aal2"}', true);
  perform pg_temp.ok(app_exigir(array['admin']) = 'qa-admin@teste.local', '[T23] sessão com o código barrada');
  perform pg_temp.ok(app_pode_gerir_documentos(), '[T23] documentos barrados com o código');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated","aal":"aal1"}', true);
  perform pg_temp.ok(not app_pode_gerir_documentos(), '[T23] documentos (Storage) liberados sem o código');
  update config set valor = 'false' where chave = 'mfa_obrigatorio';
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T24 teto dos avisos aos supervisores (migration 78) -----------------------------------------------------
-- 8 escalas esgotaram as tentativas ao mesmo tempo: a 1ª execução do motor avisa só 5 (o teto), a 2ª o resto.
-- O envio de verdade (fn_evo_post) vira um stub nesta transação, que é desfeita no fim.
create or replace function fn_evo_post(p_path text, p_body jsonb) returns bigint language sql as $$ select 0::bigint $$;
do $$
declare
  v_tec uuid := (select v::uuid from qa where k = 'tec2');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_ids uuid[] := '{}'; v_id uuid; v_n int;
begin
  if (now() at time zone 'America/Bahia')::time >= time '23:59' then
    raise notice 'T24: 23:59 local, janela de envio não cobre o minuto; teste pulado';
    return;
  end if;
  update config set valor = 'America/Bahia' where chave = 'fuso';
  update config set valor = '00:00' where chave = 'janela_envio_inicio';
  update config set valor = '23:59' where chave = 'janela_envio_fim';
  update config set valor = '5' where chave = 'supervisor_avisos_por_execucao';
  for i in 0..7 loop
    insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
    values (v_tec, v_loc, date '2031-03-03' + i, time '09:00', 'QA teto supervisor', 'notificada', 'qa')
    returning id into v_id;
    insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, enviada_em)
    values (v_id, 'lembrete', fn_config_int('max_tentativas'), 'texto_evolution', 'falha', now() - interval '2 hours');
    v_ids := v_ids || v_id;
  end loop;
  -- na homologação pode haver escala antiga esperando aviso: fora da conta (a transação é desfeita)
  update escalas set supervisor_avisado_em = now() where supervisor_avisado_em is null and not (id = any(v_ids));
  perform fn_dispatcher_whatsapp();
  select count(*) into v_n from escalas where id = any(v_ids) and supervisor_avisado_em is not null;
  perform pg_temp.ok(v_n = 5, '[T24] 1ª execução avisou ' || v_n || ' escalas (teto 5)');
  perform fn_dispatcher_whatsapp();
  select count(*) into v_n from escalas where id = any(v_ids) and supervisor_avisado_em is not null;
  perform pg_temp.ok(v_n = 8, '[T24] 2ª execução deixou escala sem aviso: ' || v_n || ' de 8');
end $$;

-- T25 avisos aos supervisores só da empresa do técnico (migration 79, decisão 69) ---------------------------
-- Supervisor da empresa do técnico e supervisor sem empresa recebem; supervisor de outra empresa, não.
-- Vale para a função comum (recusa, detalhe, URA) e para a fase 3 do motor. Envio por stub, desfeito no fim.
create or replace function fn_wa_texto(p_telefone text, p_texto text) returns bigint language sql as $$
  insert into qa values ('wa:' || p_telefone, '1') on conflict do nothing; select 0::bigint $$;
create or replace function fn_evo_post(p_path text, p_body jsonb) returns bigint language sql as $$
  insert into qa values ('evo:' || coalesce(p_body->>'number', ''), '1') on conflict do nothing; select 0::bigint $$;
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_tec  uuid := (select v::uuid from qa where k = 'tec2');
  v_loc  uuid := (select v::uuid from qa where k = 'loc');
  v_emp2 uuid; v_id uuid; v_n int;
begin
  insert into empresas (cnpj, razao_social, nome_fantasia, fuso, empregadora, ativo)
  values ('11222333000181', 'QA Outra Ltda', 'QA2', 'America/Bahia', true, true) returning id into v_emp2;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, is_supervisor) values
    ('QA Sup A',    '5579999990001', true, true, pg_temp.cpf('700000001'), v_emp,  true, true),
    ('QA Sup B',    '5579999990002', true, true, pg_temp.cpf('700000002'), v_emp2, true, true),
    ('QA Sup Todas','5579999990003', true, true, pg_temp.cpf('700000003'), null,   true, true);

  perform fn_avisar_supervisores('QA aviso', v_tec);
  perform pg_temp.ok(exists (select 1 from qa where k = 'wa:5579999990001'), '[T25] supervisor da empresa não recebeu');
  perform pg_temp.ok(exists (select 1 from qa where k = 'wa:5579999990003'), '[T25] supervisor sem empresa não recebeu');
  perform pg_temp.ok(not exists (select 1 from qa where k = 'wa:5579999990002'), '[T25] supervisor de outra empresa recebeu');
  -- alerta de sistema (sem técnico nem empresa) continua para todos
  perform fn_avisar_supervisores('QA sistema');
  perform pg_temp.ok(exists (select 1 from qa where k = 'wa:5579999990002'), '[T25] alerta de sistema não chegou a todos');

  if (now() at time zone 'America/Bahia')::time >= time '23:59' then
    raise notice 'T25: 23:59 local, fase 3 do motor não conferida';
    return;
  end if;
  update config set valor = '00:00' where chave = 'janela_envio_inicio';
  update config set valor = '23:59' where chave = 'janela_envio_fim';
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, date '2031-04-01', time '09:00', 'QA empresa supervisor', 'notificada', 'qa') returning id into v_id;
  insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, enviada_em)
  values (v_id, 'lembrete', fn_config_int('max_tentativas'), 'texto_evolution', 'falha', now() - interval '2 hours');
  update escalas set supervisor_avisado_em = now() where supervisor_avisado_em is null and id <> v_id;
  perform fn_dispatcher_whatsapp();
  select count(*) into v_n from escalas where id = v_id and supervisor_avisado_em is not null;
  perform pg_temp.ok(v_n = 1, '[T25] motor não avisou a escala');
  perform pg_temp.ok(exists (select 1 from qa where k = 'evo:5579999990001'), '[T25] motor: supervisor da empresa não recebeu');
  perform pg_temp.ok(not exists (select 1 from qa where k = 'evo:5579999990002'), '[T25] motor: supervisor de outra empresa recebeu');
  perform pg_temp.ok(exists (select 1 from qa where k = 'evo:5579999990003'), '[T25] motor: supervisor sem empresa não recebeu');
end $$;

-- T25b alertas agrupados por empresa: escala de amanhã e documentos a vencer, sem nome de outra empresa
create or replace function fn_wa_texto(p_telefone text, p_texto text) returns bigint language sql as $$
  insert into qa values ('txt:' || p_telefone, p_texto) on conflict (k) do update set v = qa.v || ' | ' || excluded.v;
  select 0::bigint $$;
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_emp2 uuid := (select id from empresas where cnpj = '11222333000181');
  v_fuso text := fn_config('fuso');
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_tipo uuid; v_a uuid; v_b uuid; v_txt text;
begin
  if v_agora::time not between time '00:02' and time '21:50' then
    raise notice 'T25b: fora da janela do teste (00:02 a 21:50 local); alertas por empresa não conferidos';
    return;
  end if;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste) values
    ('QA Tecnico Alfa', '5579999990011', true, true, pg_temp.cpf('700000011'), v_emp,  false) returning id into v_a;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste) values
    ('QA Tecnico Beta', '5579999990012', true, true, pg_temp.cpf('700000012'), v_emp2, false) returning id into v_b;

  -- documentos vencidos dos dois. No domingo não dá: a config aceita 0 a 6 e o alerta compara com o dia
  -- ISO (1 a 7), então o alerta de documentos nunca sai no domingo (inconsistência anterior, no backlog)
  if extract(isodow from v_agora) = 7 then
    raise notice 'T25b: domingo; alerta de documentos por empresa não conferido';
  else
    insert into tipos_documento (nome) values ('QA NR-35') returning id into v_tipo;
    insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade) values
      (v_a, v_tipo, v_agora::date - 1), (v_b, v_tipo, v_agora::date - 1);
    update config set valor = extract(isodow from v_agora)::text where chave = 'alerta_certificacoes_dow';
    update config set valor = to_char(v_agora - interval '1 minute', 'HH24:MI') where chave = 'alerta_certificacoes_hora';
    delete from alertas_enviados where tipo = 'certificacoes' and data_ref = v_agora::date;
    perform fn_alerta_certificacoes();
    v_txt := (select v from qa where k = 'txt:5579999990002');
    perform pg_temp.ok(v_txt like '%QA Tecnico Beta%', '[T25b] documentos: supervisor B não recebeu o técnico dele');
    perform pg_temp.ok(v_txt not like '%QA Tecnico Alfa%', '[T25b] documentos: supervisor B recebeu técnico de outra empresa');
    v_txt := (select v from qa where k = 'txt:5579999990001');
    perform pg_temp.ok(v_txt like '%QA Tecnico Alfa%' and v_txt not like '%QA Tecnico Beta%', '[T25b] documentos: supervisor A errado');
  end if;

  -- escala de amanhã: os dois sem escala
  if exists (select 1 from feriados where data = v_agora::date + 1) then
    raise notice 'T25b: amanhã é feriado; alerta da escala não conferido';
    return;
  end if;
  delete from qa where k like 'txt:%';
  update config set valor = '1,2,3,4,5,6,7' where chave = 'alerta_dias_semana';
  update config set valor = to_char(v_agora - interval '1 minute', 'HH24:MI') where chave = 'alerta_escala_aviso';
  update config set valor = '23:59' where chave = 'alerta_escala_prazo';
  delete from alertas_enviados where tipo in ('aviso', 'prazo') and data_ref = v_agora::date + 1;
  perform fn_alerta_prazo_escala();
  v_txt := (select v from qa where k = 'txt:5579999990002');
  perform pg_temp.ok(v_txt like '%QA Tecnico Beta%', '[T25b] escala: supervisor B não recebeu o técnico dele');
  perform pg_temp.ok(v_txt not like '%QA Tecnico Alfa%', '[T25b] escala: supervisor B recebeu técnico de outra empresa');
  v_txt := (select v from qa where k = 'txt:5579999990003');
  perform pg_temp.ok(v_txt like '%QA Tecnico Alfa%' and v_txt like '%QA Tecnico Beta%', '[T25b] escala: supervisor sem empresa não recebeu as duas');
end $$;

select 'REGRESSÃO OK: T1 a T25' as resultado,
       (select v from qa where k = 't5_seg') as t5_2000_marcacoes_seg,
       (select v from qa where k = 't6_seg') as t6_300_mensagens_seg;
rollback;
