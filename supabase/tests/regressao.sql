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

select 'REGRESSÃO OK: T1 a T13' as resultado,
       (select v from qa where k = 't5_seg') as t5_2000_marcacoes_seg,
       (select v from qa where k = 't6_seg') as t6_300_mensagens_seg;
rollback;
