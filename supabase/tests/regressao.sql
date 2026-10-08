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
begin
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 900000 + i, v_tec, (select cpf from tecnicos where id = v_tec), m, tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (values (1, (d + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (2, (d + time '12:00') at time zone 'America/Bahia', 'saida_almoco'),
                 (3, (d + time '12:40') at time zone 'America/Bahia', 'volta_almoco'),
                 (4, (d + time '20:30') at time zone 'America/Bahia', 'saida'),
                 (5, (d + 1 + time '06:00') at time zone 'America/Bahia', 'entrada'),
                 (6, now() - interval '25 minutes', 'saida_almoco')) v(i, m, tp);
  alter table ponto_marcacoes enable trigger user;
  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(j->'alertas' ? 'intervalo_curto' and j->'alertas' ? 'he_acima_limite'
                     and (j->>'trabalhado_min')::int = 710, '[T7] dia com intervalo curto e HE: ' || j::text);
  j := fn_ponto_jornada_dia(v_tec, d + 1);
  perform pg_temp.ok(j->'alertas' ? 'interjornada_curta', '[T7] interjornada: ' || j::text);
  perform pg_temp.ok(fn_ponto_aviso_previo(v_tec, 'volta_almoco') like '%25 min%', '[T7] aviso antes da volta');
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

select 'REGRESSÃO OK: T1 a T9' as resultado,
       (select v from qa where k = 't5_seg') as t5_2000_marcacoes_seg,
       (select v from qa where k = 't6_seg') as t6_300_mensagens_seg;
rollback;
