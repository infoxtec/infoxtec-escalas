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
-- T26 Checklist aponta supervisor ou técnico sem empresa; alerta de documentos aceita domingo (7)
-- T27 monitor_ping_url só aceita https://hc-ping.com/<uuid> ou vazio
-- T28 quem ativou e desativou a verificação em duas etapas fica registrado; o admin vê
-- T29 jornada de mais de 4 h e até 6 h sem intervalo gera aviso (CLT art. 71, §1º)
-- T30 palavra e número do ponto não são capturados enquanto o técnico explica uma recusa de escala
-- T31 painel gerencial: semanas acima de 44 h, sábado sem expediente abonado, escala por WhatsApp e URA
-- T32 dossiê de conformidade por local: documento vencido na data do serviço, vencendo, não cadastrado
-- T33 demonstração com dados fictícios: criar e apagar (supabase/demo) não deixam resto
-- T34 AFD do REP-P (versão de conferência): tamanhos do leiaute, CRC-16, hash encadeado, trailer e permissão
-- T35 espelho mensal congelado: emissão, registro sem lacuna, imutável, conferência pública sem dado pessoal
-- T36 assinatura do espelho pelo funcionário: só o próprio, só a versão vista, uma vez, hash amarrado; envio
-- T37 resumo do espelho: HE 50% e 100%, noturno reduzido, débito com tolerância, atestado e abono da empresa
-- T38 assinatura por HMAC com chave no Vault; folga compensatória tira o 100% do domingo trabalhado
-- T39 cofre de folhas assinadas: só RH abre a folha assinada e baixa a prova; cada abertura fica registrada
-- T40 escala / carga horária e times: bloqueio, aceite de risco, prioridade funcionário > time > empresa, equipe vira time
-- T41 limite de 2 h extras pela escala: aceite da empresa na Programação, substituição recusada, Alerta Crítico
-- T42 espelho pela escala: folga a 50%, DSR a 100%, débito pela jornada do dia, 12x36 com feriado compensado
-- T43 Indicadores pela escala: hora extra pela jornada do dia (folga e DSR inteiros, 12x36 acima do plantão)
-- T44 trava de envio da homologação: só a lista libera; instância conferida; mensagem sem destinatário recusada;
--     texto sem prévia de link (decisão 95)
-- T45 validação e fechamento da folha: pendência bloqueia, faltas pedem confirmação, registro de quem fechou, logotipo
-- T46 checagens do fechamento: duplicada, intervalo, pedido aberto não é falta, abono do atestado no espelho, prévia
-- T47 token do webhook trocado sozinho: janela com os dois, confirmação, limpeza, reversão em falha, espera de um dia
-- T48 intervalo não registrado bloqueia o fechamento (opção da empresa), abono libera, gestor não cria marcação,
--     retorno do intervalo no comprovante, só o administrador muda a opção
-- T49 hora extra com aprovação: Programação autoriza, pedido ao supervisor, botões Aprovar/Reprovar, fechamento

\set ON_ERROR_STOP on
begin;

-- Trava: não roda com tarefas ativas no pg_cron. A produção sempre tem; a homologação tem desde a decisão 94 e
-- precisa pausar o agendador antes (o T7 trava ponto_marcacoes até o rollback e seguraria as batidas dos testes).
do $$
declare n int := 0;
begin
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job where active' into n; end if;
  if n > 0 then
    raise exception 'regressao.sql: banco com tarefas ativas no pg_cron (produção?). Na homologação, pause antes: select cron.alter_job(jobid, active := false) from cron.job; e religue depois com active := true.';
  end if;
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

-- T55 esquema privado: a API só vê app_* e ponto_* (migration 115, backlog 074) ----------------------------------
do $$
declare v text;
begin
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
     and c.relname not like 'qa\_%'
     and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e');
  perform pg_temp.ok(v is null, '[T55] tabela, view ou sequência no public: ' || coalesce(v, ''));
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname !~ '^(app|ponto)_' and p.proname not like 'fn\_qa%'
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
  perform pg_temp.ok(v is null, '[T55] função interna no public: ' || coalesce(v, ''));
  select string_agg(r, ', ') into v from unnest(array['anon', 'authenticated', 'service_role']) r
   where has_schema_privilege(r, 'interno', 'usage');
  perform pg_temp.ok(v is null, '[T55] papel da API com acesso ao esquema interno: ' || coalesce(v, ''));
  select string_agg(r, ', ') into v from unnest(array['anon', 'authenticated', 'service_role']) r
   where has_schema_privilege(r, 'public', 'create');
  perform pg_temp.ok(v is null, '[T55] papel da API cria objeto no public: ' || coalesce(v, ''));
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'interno' and p.proname ~ '^(app|ponto)_';
  perform pg_temp.ok(v is null, '[T55] app_* ou ponto_* no esquema interno (a API não alcança): ' || coalesce(v, ''));
  select string_agg(p.proname, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'interno') and p.proname not like 'fn\_qa%'
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and not coalesce(array_to_string(p.proconfig, ',') like '%search_path=interno, public, extensions, pg_temp%', false);
  perform pg_temp.ok(v is null, '[T55] função sem o caminho interno, public, extensions, pg_temp: ' || coalesce(v, ''));
end $$;

-- T56 régua do multiempresa (F0, docs/multiempresa-f0.md): o catálogo bate com a classificação; exigência desde a F1 --
do $$
declare
  v_fn_plataforma text[] := array['app_email', 'app_exigir', 'app_meu_acesso', 'app_backlog', 'app_salvar_backlog_item',
    'app_mover_backlog_item', 'app_checklist_saude', 'app_checklist_testar', 'app_estado_motor'];
  v_tb_plataforma text[] := array['config', 'backlog_itens', 'motor_estado', 'saude_testes', 'ponto_geo', 'webhook_token_trocas'];
  v text; n int;
begin
  -- a lista da plataforma precisa existir (função ou tabela renomeada/removida obriga a revisar a classificação)
  select string_agg(f, ', ') into v from unnest(v_fn_plataforma) f
   where not exists (select 1 from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = f);
  perform pg_temp.ok(v is null, '[T56] função da plataforma sumiu do catálogo: ' || coalesce(v, ''));
  select string_agg(t, ', ') into v from unnest(v_tb_plataforma) t where to_regclass('interno.' || t) is null;
  perform pg_temp.ok(v is null, '[T56] tabela da plataforma sumiu do catálogo: ' || coalesce(v, ''));
  -- F1 (migration 116): toda tabela de cliente tem conta_id não nulo com chave para contas; a plataforma não tem
  select count(*), string_agg(c.relname, ', ' order by c.relname) into n, v
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'interno' and c.relkind in ('r', 'p') and not c.relispartition
     and c.relname <> all (v_tb_plataforma || array['contas', 'conta_membros', 'plataforma_admins', 'conta_modulos'])
     and c.relname not like 'qa\_%'
     and not exists (select 1 from pg_attribute a join pg_constraint k on k.conrelid = a.attrelid and k.contype = 'f'
                      and k.confrelid = 'interno.contas'::regclass and k.conkey = array[a.attnum]
                     where a.attrelid = c.oid and a.attname = 'conta_id' and a.attnotnull and not a.attisdropped);
  perform pg_temp.ok(n = 0, '[T56] tabela de cliente sem conta_id (não nulo, chave para contas): ' || coalesce(v, ''));
  select string_agg(t, ', ') into v from unnest(v_tb_plataforma) t
   where exists (select 1 from pg_attribute a where a.attrelid = to_regclass('interno.' || t) and a.attname = 'conta_id');
  perform pg_temp.ok(v is null, '[T56] tabela da plataforma com conta_id: ' || coalesce(v, ''));
  perform pg_temp.ok(exists (select 1 from contas where id = '00000000-0000-0000-0000-000000000001' and ativa),
                     '[T56] conta 1 ausente');
  perform pg_temp.ok((select count(*) from plataforma_admins
                       where email in ('david.cerqueira@infoxtec.com.br', 'sergio.dorea@infoxtec.com.br')) = 2,
                     '[T56] admins da plataforma');
  perform pg_temp.ok((select count(*) from conta_modulos where conta_id = '00000000-0000-0000-0000-000000000001' and ativo) = 2,
                     '[T56] módulos da conta 1');
  -- linha nova sem conta explícita cai na conta 1 (até a F2 trazer a conta da sessão)
  perform pg_temp.ok((select bool_and(conta_id = '00000000-0000-0000-0000-000000000001') from tecnicos), '[T56] técnico fora da conta 1');
  -- as tabelas novas seguem a regra: RLS ligado, sem política e sem privilégio para os papéis da API
  select string_agg(c.relname, ', ') into v from pg_class c
   where c.oid in ('interno.contas'::regclass, 'interno.conta_membros'::regclass, 'interno.plataforma_admins'::regclass,
                   'interno.conta_modulos'::regclass)
     and (not c.relrowsecurity or exists (select 1 from pg_policy p where p.polrelid = c.oid)
          or exists (select 1 from unnest(array['anon', 'authenticated', 'service_role']) r
                      where has_table_privilege(r, c.oid, 'select, insert, update, delete')));
  perform pg_temp.ok(v is null, '[T56] tabela de conta exposta: ' || coalesce(v, ''));
  -- conta_membros espelha painel_usuarios até a F2 (gatilho da 116): incluir, mudar papel e apagar
  insert into painel_usuarios (email, nome, papel) values ('qa-t56@exemplo.com', 'QA', 'leitura');
  update painel_usuarios set papel = 'gestor', ativo = false where email = 'qa-t56@exemplo.com';
  perform pg_temp.ok(exists (select 1 from conta_membros where email = 'qa-t56@exemplo.com' and papel = 'gestor' and not ativo),
                     '[T56] espelho de conta_membros na alteração');
  delete from painel_usuarios where email = 'qa-t56@exemplo.com';
  select count(*) into n from (
    (select email, papel, ativo from painel_usuarios except
     select email, papel, ativo from conta_membros where conta_id = '00000000-0000-0000-0000-000000000001')
    union all
    (select email, papel, ativo from conta_membros where conta_id = '00000000-0000-0000-0000-000000000001' except
     select email, papel, ativo from painel_usuarios)) d;
  perform pg_temp.ok(n = 0, '[T56] conta_membros diferente de painel_usuarios: ' || n);
end $$;

-- T44 trava de envio da homologação (migration 99, decisão 94) ----------------------------------------------
do $$
declare v_ok boolean; v_msg text;
  v_amb text := fn_config('ambiente'); v_inst text := fn_config('evolution_instancia');
  v_lista text := fn_config('telefones_homologacao');
  v_tec uuid := (select v::uuid from qa where k = 'tec1');
  v_tel text := (select telefone_e164 from tecnicos where id = (select v::uuid from qa where k = 'tec1'));
  v_teste boolean := (select perfil_teste from tecnicos where id = (select v::uuid from qa where k = 'tec1'));
begin
  -- roda antes do stub de fn_evo_post (T13) e devolve a configuração como estava
  update config set valor = 'homologacao' where chave = 'ambiente';
  insert into config (chave, valor) values ('telefones_homologacao', '5571900000044'), ('evolution_instancia', 'trilha-homologacao')
  on conflict (chave) do update set valor = excluded.valor;
  update tecnicos set perfil_teste = true, telefone_e164 = '5571988880044' where id = (select v::uuid from qa where k = 'tec1');
  perform pg_temp.ok(fn_pode_enviar('5571900000044'), '[T44] número liberado');
  perform pg_temp.ok(not fn_pode_enviar('5571988880044'), '[T44] técnico de teste com número real liberado');
  v_ok := false;
  begin perform fn_evo_post('/message/sendText/infoxtec', '{"number":"5571900000044","text":"x"}');
  exception when others then v_msg := sqlerrm; v_ok := sqlerrm like '%instância configurada%'; end;
  perform pg_temp.ok(v_ok, '[T44] envio por outra instância: ' || coalesce(v_msg, 'sem erro')); v_msg := null;
  v_ok := false;
  begin perform fn_evo_post('/message/sendText/trilha-homologacao', '{"text":"x"}');
  exception when others then v_msg := sqlerrm; v_ok := sqlerrm like '%sem destinatário%'; end;
  perform pg_temp.ok(v_ok, '[T44] mensagem sem destinatário: ' || coalesce(v_msg, 'sem erro')); v_msg := null;
  update config set valor = 'infoxtec' where chave = 'evolution_instancia';
  v_ok := false;
  begin perform fn_evo_post('/message/sendText/infoxtec', '{"number":"5571900000044","text":"x"}');
  exception when others then v_msg := sqlerrm; v_ok := sqlerrm like '%só usa a instância trilha-homologacao%'; end;
  perform pg_temp.ok(v_ok, '[T44] homologação pela instância da produção: ' || coalesce(v_msg, 'sem erro')); v_msg := null;
  update config set valor = 'producao' where chave = 'ambiente';
  update config set valor = 'trilha-homologacao' where chave = 'evolution_instancia';
  v_ok := false;
  begin perform fn_evo_post('/message/sendText/trilha-homologacao', '{"number":"5571900000044","text":"x"}');
  exception when others then v_msg := sqlerrm; v_ok := sqlerrm like '%não serve à produção%'; end;
  perform pg_temp.ok(v_ok, '[T44] produção pela instância da homologação: ' || coalesce(v_msg, 'sem erro')); v_msg := null;
  perform pg_temp.ok(fn_pode_enviar('5571988880044'), '[T44] produção libera qualquer número');
  -- texto sai sem prévia de link, salvo pedido explícito (migration 100, decisão 95): o envio de verdade não roda no CI
  perform pg_temp.ok((select prosrc ~ $re$p_path like '/message/sendText/%' and not \(v_body \? 'linkPreview'\)$re$
                             and prosrc ~ $re$jsonb_build_object\('linkPreview', false\)$re$ and prosrc ~ 'body +:= v_body'
                        from pg_proc where oid = 'fn_evo_post(text,jsonb)'::regprocedure), '[T44] texto com prévia de link');
  -- devolve o estado para os testes seguintes
  delete from config where chave in ('ambiente', 'evolution_instancia', 'telefones_homologacao');
  insert into config (chave, valor) select k, v from (values ('ambiente', v_amb), ('evolution_instancia', v_inst),
    ('telefones_homologacao', v_lista)) x(k, v) where v is not null;
  update tecnicos set telefone_e164 = v_tel, perfil_teste = v_teste where id = v_tec;
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
  -- motivo curto ou longo, ação inválida, inclusão pelo gestor (decisão 89), marcação de outro funcionário: recusados
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'curto', p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%pelo menos 10%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou motivo curto');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', repeat('x', 501), p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%500%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou motivo de 501 letras');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'apagar', 'motivo suficiente aqui');
  exception when others then v_ok := sqlerrm like '%inválida%'; end;
  perform pg_temp.ok(v_ok, '[T11] aceitou ação inválida');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'Esqueceu de bater a saída');   -- sem os parâmetros da inclusão desde a 104
  exception when others then v_ok := sqlerrm like '%não inclui marcação%'; end;
  perform pg_temp.ok(v_ok, '[T11] gestor incluiu marcação (decisão 89)');
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  values (v_emp, 910009, v_tec, (select cpf from tecnicos where id = v_tec), now() - interval '70 days', 'entrada', 'app', -12.9, -38.4, 'qa', md5(random()::text));
  alter table ponto_marcacoes enable trigger user;
  v_ok := false;
  -- mês sem espelho emitido: desconsiderar (contra o funcionário) segue limitado a 62 dias (migration 105)
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'motivo suficiente aqui', p_marcacao => (select id from ponto_marcacoes where nsr = 910009 and tecnico_id = v_tec));
  exception when others then v_ok := sqlerrm like '%62 dias%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou marcação de 70 dias atrás em mês sem espelho');
  v_ok := false;
  begin perform app_ponto_ajustar(v_outro, 'desconsiderar', 'motivo suficiente aqui', p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%não encontrada%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou marcação de outro funcionário');

  -- a saída esquecida entra como na aprovação do pedido do funcionário (hora local da empresa); a entrada
  -- repetida é desconsiderada pelo gestor
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_tec, 'incluir', (d + time '17:00') at time zone 'America/Bahia', 'saida', 'Pedido do funcionário aprovado', 'qa-admin@teste.local');
  x := app_ponto_ajustar(v_tec, 'desconsiderar', 'Entrada batida em duplicidade', p_marcacao => v_dup);
  perform pg_temp.ok((x->>'avisado')::boolean and x->>'hora' = '07:00', '[T11] desconsiderar avisa o funcionário: ' || x::text);
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'De novo a mesma marcação', p_marcacao => v_dup);
  exception when others then v_ok := sqlerrm like '%já foi desconsiderada%'; end;
  perform pg_temp.ok(v_ok, '[T11] desconsiderou duas vezes');

  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(not j->'alertas' ? 'incompleta' and j->>'entrada' = '08:00' and j->>'saida' = '17:00'
                     and (j->>'trabalhado_min')::int = 480 and (j->>'ajustes')::int = 2, '[T11] depois do ajuste: ' || j::text);
  perform pg_temp.ok((select count(*) from ponto_marcacoes where tecnico_id = v_tec) = 5, '[T11] marcação original sumiu');
  select * into r from app_ponto_espelho(d, d, v_tec);
  perform pg_temp.ok(r.ajustes = 2 and r.trabalhado_min = 480, '[T11] espelho: ' || coalesce(r.ajustes, -1));

  -- inclusão errada se desfaz desconsiderando a inclusão; a certa entra em seguida
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_tec, 'incluir', (d - 1 + time '09:00') at time zone 'America/Bahia', 'entrada', 'Pedido: trabalhou sem celular', 'qa-admin@teste.local')
  returning id into v_inc;
  select count(*) into v_n from app_ponto_espelho(d - 1, d - 1, v_tec) e where e.entrada = '09:00';
  perform pg_temp.ok(v_n = 1, '[T11] dia só com ajuste fora do espelho');
  x := app_ponto_ajustar(v_tec, 'desconsiderar', 'Hora digitada errada', p_ajuste => v_inc);
  perform pg_temp.ok(not (x->>'avisado')::boolean, '[T11] segundo aviso em menos de 5 min');
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_tec, 'incluir', (d - 1 + time '08:00') at time zone 'America/Bahia', 'entrada', 'Pedido: hora certa', 'qa-admin@teste.local');
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
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'motivo suficiente aqui', p_marcacao => v_dup);
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
-- o envio é stub nesta transação: entre 0h e 2h locais o aviso sai de verdade, e o CI não tem a Evolution
create or replace function fn_wa_texto(p_telefone text, p_texto text) returns bigint language sql as $$ select 0::bigint $$;
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
-- Só o supervisor da empresa do técnico recebe; de outra empresa ou sem empresa, não (migration 112, decisão 107).
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
  perform pg_temp.ok(not exists (select 1 from qa where k = 'wa:5579999990003'), '[T25] supervisor sem empresa recebeu aviso de outra empresa');
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
  perform pg_temp.ok(not exists (select 1 from qa where k = 'evo:5579999990003'), '[T25] motor: supervisor sem empresa recebeu');
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

  -- documentos vencidos dos dois (domingo = 7, aceito desde a migration 80)
  begin
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
  end;

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
  perform pg_temp.ok(coalesce(v_txt, '') not like '%QA Tecnico Alfa%' and coalesce(v_txt, '') not like '%QA Tecnico Beta%',
                     '[T25b] escala: supervisor sem empresa recebeu técnico de empresa (migration 112)');
end $$;

-- T26 Checklist aponta cadastro sem empresa; alerta de documentos aceita domingo (migration 80) ------------
do $$
declare r jsonb; x jsonb; v_ok boolean;
begin
  -- o T25 deixou duas empresas ativas e um supervisor sem empresa (de teste, mas recebe avisos): é falha
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_checklist_saude();
  select e into x from jsonb_array_elements(r->'itens') e where e->>'item' = 'Supervisores e técnicos sem empresa';
  perform pg_temp.ok(x->>'estado' = 'falha' and x->>'grupo' = 'Erros em tabelas', '[T26] Checklist sem o cadastro sem empresa: ' || coalesce(x::text, 'null'));

  update config set valor = '7' where chave = 'alerta_certificacoes_dow';
  update config set valor = '0' where chave = 'alerta_certificacoes_dow';
  v_ok := false;
  begin update config set valor = '8' where chave = 'alerta_certificacoes_dow';
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T26] alerta de documentos aceitou dia 8');
  v_ok := false;
  begin update config set valor = '07' where chave = 'alerta_certificacoes_dow';
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T26] alerta de documentos aceitou 07 (nunca dispararia)');
  update config set valor = '1' where chave = 'alerta_certificacoes_dow';
end $$;

-- T27 monitor_ping_url só aceita o ping do healthchecks.io (migration 81) --------------------------------
do $$
declare v_ok boolean;
begin
  update config set valor = 'https://hc-ping.com/0f0e0d0c-0b0a-4908-8706-050403020100' where chave = 'monitor_ping_url';
  update config set valor = '' where chave = 'monitor_ping_url';
  v_ok := false;
  begin update config set valor = 'https://exemplo.com/coleta' where chave = 'monitor_ping_url';
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T27] monitor_ping_url aceitou endereço fora do healthchecks.io');
end $$;

-- T28 registro da verificação em duas etapas (migration 82, backlog 097) ---------------------------------
-- Cadastro abandonado não conta; confirmar = ativou; remover o fator confirmado = desativou. Admin vê.
do $$
declare v_user uuid := gen_random_uuid(); v_fator uuid := gen_random_uuid(); v_n int; r jsonb;
begin
  insert into auth.users (id, email) values (v_user, 'qa-mfa@teste.local');
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
  values (v_fator, v_user, 'QA', 'totp', 'unverified', now(), now());
  select count(*) into v_n from painel_mfa_log where email = 'qa-mfa@teste.local';
  perform pg_temp.ok(v_n = 0, '[T28] cadastro não confirmado registrado');
  update auth.mfa_factors set status = 'verified', updated_at = now() where id = v_fator;
  -- um segundo usuário ativo: a lista tem mais de uma linha
  insert into auth.users (id, email) values (gen_random_uuid(), 'qa-mfa2@teste.local');
  insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
  select gen_random_uuid(), id, 'QA2', 'totp', 'verified', now(), now() from auth.users where email = 'qa-mfa2@teste.local';
  perform pg_temp.ok(exists (select 1 from painel_mfa_log where email = 'qa-mfa@teste.local' and acao = 'ativou'), '[T28] ativação não registrada');

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_usuarios_mfa();
  perform pg_temp.ok(r->'ativos' @> '[{"email":"qa-mfa@teste.local"}]', '[T28] admin não vê a verificação ativa');

  delete from auth.mfa_factors where id = v_fator;
  perform pg_temp.ok(exists (select 1 from painel_mfa_log where email = 'qa-mfa@teste.local' and acao = 'desativou'), '[T28] desativação não registrada');
  r := app_usuarios_mfa();
  perform pg_temp.ok(not (r->'ativos' @> '[{"email":"qa-mfa@teste.local"}]')
                     and r->'historico' @> '[{"email":"qa-mfa@teste.local","acao":"desativou"}]', '[T28] tela não reflete a desativação');
end $$;

-- T29 jornada de mais de 4 h sem intervalo gera aviso (migration 83, CLT art. 71, §1º) ---------------------
do $$
declare
  v_tec uuid;
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  d date := current_date - 20; j jsonb;
begin
  -- funcionário e datas só deste teste: sem marcação nem ajuste de outro teste no mesmo dia
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Intervalo', '557999990929', true, true, pg_temp.cpf('929929901'), v_emp, true) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 929000 + i, v_tec, (select cpf from tecnicos where id = v_tec), m, tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (values (1, (d + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (2, (d + time '13:00') at time zone 'America/Bahia', 'saida'),       -- 5 h sem intervalo
                 (3, (d + 1 + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (4, (d + 1 + time '12:00') at time zone 'America/Bahia', 'saida'),   -- 4 h: não exige
                 (5, (d + 2 + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (6, (d + 2 + time '10:00') at time zone 'America/Bahia', 'saida_almoco'),
                 (7, (d + 2 + time '10:10') at time zone 'America/Bahia', 'volta_almoco'),
                 (8, (d + 2 + time '13:10') at time zone 'America/Bahia', 'saida'),    -- 5 h com 10 min: curto
                 (9, (d + 3 + time '08:00') at time zone 'America/Bahia', 'entrada'),
                 (10, (d + 3 + time '12:01') at time zone 'America/Bahia', 'saida')    -- 4 h 01 sem intervalo
         ) v(i, m, tp);
  alter table ponto_marcacoes enable trigger user;
  j := fn_ponto_jornada_dia(v_tec, d);
  perform pg_temp.ok(j->'alertas' ? 'sem_intervalo', '[T29] 5 h sem intervalo sem aviso: ' || j::text);
  j := fn_ponto_jornada_dia(v_tec, d + 1);
  perform pg_temp.ok(not (j->'alertas' ? 'sem_intervalo'), '[T29] 4 h sem intervalo com aviso: ' || j::text);
  j := fn_ponto_jornada_dia(v_tec, d + 2);
  perform pg_temp.ok(j->'alertas' ? 'intervalo_curto', '[T29] 5 h com 10 min de intervalo sem aviso: ' || j::text);
  j := fn_ponto_jornada_dia(v_tec, d + 3);
  perform pg_temp.ok(j->'alertas' ? 'sem_intervalo', '[T29] 4 h 01 sem intervalo sem aviso: ' || j::text);
end $$;

-- T30 palavra do ponto não é interceptada enquanto o técnico explica uma recusa (migration 84) -----------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_tec uuid; v_esc uuid; v_tel text := '5579999993030'; r jsonb;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Recusa Ponto', v_tel, true, true, pg_temp.cpf('303030301'), v_emp, true) returning id into v_tec;
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, current_date + 2, time '09:00', 'QA recusa', 'notificada', 'qa') returning id into v_esc;

  -- menu do ponto aberto; o técnico recusa a escala pelo botão: a recusa fecha a conversa do ponto
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'P1', '{"conversation":"ponto"}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_menu', '[T30] menu: ' || coalesce(r::text, 'null'));
  r := fn_wh_mensagem(pg_temp.msg(v_tel, 'P2', jsonb_build_object('buttonsResponseMessage', jsonb_build_object('selectedButtonId', 'prob:' || v_esc))));
  perform pg_temp.ok(r->>'acao' = 'recusada', '[T30] recusa: ' || coalesce(r::text, 'null'));
  perform pg_temp.ok(not exists (select 1 from ponto_conversas where tecnico_id = v_tec and expira_em > now()), '[T30] conversa do ponto seguiu aberta');

  -- antes do motivo: "almoço" é a resposta do técnico e "1" é o motivo, não a Entrada
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'P3', '{"conversation":"almoço"}'));
  perform pg_temp.ok(r is null, '[T30] resposta à recusa virou ponto: ' || coalesce(r::text, 'null'));
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'P4', '{"conversation":"1"}'));
  perform pg_temp.ok(r is null, '[T30] motivo virou ponto: ' || coalesce(r::text, 'null'));
  r := fn_wh_mensagem(pg_temp.msg(v_tel, 'P4', '{"conversation":"1"}'));
  perform pg_temp.ok(r->>'acao' = 'motivo_recusa', '[T30] motivo não registrado: ' || coalesce(r::text, 'null'));
  -- o botão do ponto vale sempre
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'P5', '{"buttonsResponseMessage":{"selectedButtonId":"ponto:entrada"}}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_pediu_localizacao', '[T30] botão do ponto barrado: ' || coalesce(r::text, 'null'));
  update ponto_conversas set expira_em = now() where tecnico_id = v_tec;
  -- motivo dado (detalhe é opcional): o atalho do ponto volta a valer
  r := fn_ponto_wh(pg_temp.msg(v_tel, 'P6', '{"conversation":"entrada"}'));
  perform pg_temp.ok(r->>'acao' = 'ponto_pediu_localizacao', '[T30] atalho do ponto barrado depois do motivo: ' || coalesce(r::text, 'null'));
end $$;

-- T31 painel gerencial de aderência (migration 85, backlog 099) --------------------------------------------
-- Duas semanas inteiras de um funcionário: a 1ª com 8 h de segunda a sexta e sábado sem expediente
-- (abonado: dentro do esperado), a 2ª com 9 h de segunda a sábado (54 h: acima de 44 h). Uma escala
-- resolvida pelo WhatsApp e outra pela URA. Os outros funcionários do ponto saem da conta (desfeito no fim).
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_seg date := date_trunc('week', current_date - 21)::date;
  v_tec uuid; v_e1 uuid; v_e2 uuid; r jsonb; v_ok boolean;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Gerencial', '5579999993131', true, true, pg_temp.cpf('313131301'), v_emp, false, v_seg - 30) returning id into v_tec;
  update tecnicos set ativo = false where id <> v_tec and cpf is not null and empresa_id is not null and ativo;
  delete from feriados where data between v_seg and v_seg + 13;

  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 931000 + row_number() over (), v_tec, (select cpf from tecnicos where id = v_tec),
         (dia + h) at time zone 'America/Bahia', tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (select v_seg + n as dia, n from generate_series(0, 12) n
           where n not in (5, 6) or n = 12) d                       -- semana 1: seg a sex; semana 2: seg a sáb
    cross join lateral (values (time '08:00', 'entrada'), (time '12:00', 'saida_almoco'), (time '13:00', 'volta_almoco'),
                               (case when d.n >= 7 then time '18:00' else time '17:00' end, 'saida')) m(h, tp);
  alter table ponto_marcacoes enable trigger user;

  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, v_seg + 1, time '08:00', 'QA gerencial 1', 'confirmada', 'qa') returning id into v_e1;
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por)
  values (v_tec, v_loc, v_seg + 2, time '08:00', 'QA gerencial 2', 'confirmada', 'qa') returning id into v_e2;
  insert into notificacoes (escala_id, status_envio, enviada_em) values (v_e1, 'lida', now()), (v_e2, 'lida', now());
  insert into respostas (escala_id, wa_message_id, tipo) values (v_e1, 'QA-G1', 'confirmacao');
  insert into ligacoes (escala_id, tecnico_id, telefone, status, digito, atendida_em) values (v_e2, v_tec, '5579999993131', 'atendida', '1', now());
  insert into respostas (escala_id, tipo, texto_livre) values (v_e2, 'confirmacao', 'Confirmado por telefone (digitou 1)');

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_painel_gerencial(v_seg, v_seg + 13);
  perform pg_temp.ok((r->'ponto'->>'semanas')::int = 2, '[T31] semanas inteiras: ' || (r->'ponto')::text);
  perform pg_temp.ok((r->'ponto'->>'semanas_acima_44h')::int = 1, '[T31] semana de 54 h não acusada: ' || (r->'ponto')::text);
  perform pg_temp.ok((r->'ponto'->>'semanas_abaixo_esperado')::int = 0, '[T31] sábado sem expediente não foi abonado: ' || (r->'ponto')::text);
  perform pg_temp.ok((r->'ponto'->>'marcacoes')::int = 44, '[T31] marcações: ' || (r->'ponto')::text);
  perform pg_temp.ok((r->'escala'->>'respondidas_whatsapp')::int >= 1 and (r->'escala'->>'precisaram_ura')::int >= 1
                     and (r->'escala'->>'ligacoes_atendidas')::int >= 1, '[T31] escala: ' || (r->'escala')::text);
  perform pg_temp.ok((r->'ponto'->>'minutos_hora_extra')::int = 600, '[T31] hora extra (5 × 1 h + sábado 5 h): ' || (r->'ponto')::text);
  perform pg_temp.ok((r->'ponto'->>'saldo_min')::int = 600, '[T31] saldo: ' || (r->'ponto')::text);
  perform pg_temp.ok(r::text not like '%QA Gerencial%', '[T31] nome de funcionário no painel');
  -- sem o abono do sábado, a 1ª semana fica 4 h abaixo do esperado
  update config set valor = 'false' where chave = 'ponto_sabado_sem_expediente_abona';
  r := app_painel_gerencial(v_seg, v_seg + 13);
  perform pg_temp.ok((r->'ponto'->>'semanas_abaixo_esperado')::int = 1, '[T31] sábado não abonado não contou: ' || (r->'ponto')::text);
  update config set valor = 'true' where chave = 'ponto_sabado_sem_expediente_abona';
  -- o papel leitura vê o mesmo painel; período acima de 62 dias é recusado
  insert into painel_usuarios (email, nome, papel, ativo) values ('qa-leitura@teste.local', 'QA leitura', 'leitura', true) on conflict do nothing;
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok(app_painel_gerencial(v_seg, v_seg + 13) is not null, '[T31] leitura barrado');
  v_ok := false;
  begin perform app_painel_gerencial(v_seg, v_seg + 63);
  exception when others then v_ok := sqlerrm like '%62 dias%'; end;
  perform pg_temp.ok(v_ok, '[T31] período de 64 dias aceito');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T32 dossiê de conformidade por local (migration 86, backlog 100) -----------------------------------------
-- A atividade exige dois documentos. O 1º técnico tem um vencido na data do serviço (não apto); o 2º tem um
-- válido e um que vence em até 30 dias (apto, com aviso); o 3º, sem atividade na escala, fica pendente.
-- Escala cancelada e de outro local ficam de fora.
do $$
declare
  v_dia date := current_date + 10;
  v_loc uuid; v_ta uuid; v_d1 uuid; v_d2 uuid; v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t4 uuid; v_loc2 uuid; r jsonb; v_ok boolean;
begin
  insert into tipos_atividade (nome) values ('QA Dossiê altura') returning id into v_ta;
  insert into tipos_documento (nome, ordem) values ('QA T32 NR-35', 1) returning id into v_d1;
  insert into tipos_documento (nome, ordem) values ('QA T32 ASO', 2) returning id into v_d2;
  insert into tipo_atividade_documentos (tipo_id, tipo_documento_id) values (v_ta, v_d1), (v_ta, v_d2);
  insert into locais (nome, cliente, cidade) values ('QA Dossiê local', 'QA', 'Aracaju') returning id into v_loc;
  insert into locais (nome, cliente, cidade) values ('QA Dossiê outro local', 'QA', 'Aracaju') returning id into v_loc2;

  insert into tecnicos (nome, telefone_e164, ativo, opt_in) values ('QA Dossiê Um', '5579999993201', true, true) returning id into v_t1;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in) values ('QA Dossiê Dois', '5579999993202', true, true) returning id into v_t2;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in) values ('QA Dossiê Três', '5579999993203', true, true) returning id into v_t3;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in) values ('QA Dossiê Quatro', '5579999993204', true, true) returning id into v_t4;
  insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade) values
    (v_t1, v_d1, v_dia - 1), (v_t1, v_d2, v_dia + 400),
    (v_t2, v_d1, v_dia + 400), (v_t2, v_d2, v_dia + 20);

  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, status, criado_por, tipo_atividade_id) values
    (v_t1, v_loc, v_dia, time '07:00', 'QA dossiê', 'agendada', 'qa', v_ta),
    (v_t2, v_loc, v_dia, time '08:00', 'QA dossiê', 'confirmada', 'qa', v_ta),
    (v_t3, v_loc, v_dia, time '09:00', 'QA dossiê', 'cancelada', 'qa', v_ta),
    (v_t3, v_loc2, v_dia, time '09:00', 'QA dossiê', 'agendada', 'qa', v_ta),
    (v_t4, v_loc, v_dia, time '10:00', 'QA dossiê', 'agendada', 'qa', null);

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_dossie_local(v_loc, v_dia);
  perform pg_temp.ok(not (r->'tecnicos')::text like '%QA Dossiê Três%', '[T32] escala cancelada ou de outro local entrou: ' || r::text);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r->'tecnicos') t
                              where t->>'tecnico' = 'QA Dossiê Um' and not (t->>'apto')::boolean
                                and t->'documentos' @> '[{"documento":"QA T32 NR-35","situacao":"vencido"}]'
                                and t->'documentos' @> '[{"documento":"QA T32 ASO","situacao":"valido"}]'),
                     '[T32] vencido na data do serviço não barrou: ' || r::text);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r->'tecnicos') t
                              where t->>'tecnico' = 'QA Dossiê Dois' and (t->>'apto')::boolean
                                and t->'documentos' @> '[{"documento":"QA T32 ASO","situacao":"vencendo"}]'),
                     '[T32] documento vencendo: ' || r::text);
  -- escala sem tipo de atividade: exigência desconhecida, nunca apto
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r->'tecnicos') t
                              where t->>'tecnico' = 'QA Dossiê Quatro' and not (t->>'apto')::boolean and (t->>'sem_atividade')::boolean),
                     '[T32] escala sem atividade saiu apta: ' || r::text);
  perform pg_temp.ok(exists (select 1 from dossie_geracoes g where g.id = (r->>'registro')::bigint
                              and g.email = 'qa-admin@teste.local' and g.local_id = v_loc and g.tecnicos = 3),
                     '[T32] geração não registrada');
  -- sem documento cadastrado o técnico não está apto
  delete from tecnico_documentos where tecnico_id = v_t2 and tipo_documento_id = v_d1;
  r := app_dossie_local(v_loc, v_dia);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r->'tecnicos') t
                              where t->>'tecnico' = 'QA Dossiê Dois' and not (t->>'apto')::boolean
                                and t->'documentos' @> '[{"documento":"QA T32 NR-35","situacao":"nao_cadastrado"}]'),
                     '[T32] documento não cadastrado: ' || r::text);
  -- o papel leitura gera o dossiê; sem sessão do painel é barrado
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok(app_dossie_local(v_loc, v_dia) is not null, '[T32] leitura barrado');
  perform set_config('request.jwt.claims', '', true);
  v_ok := false;
  begin perform app_dossie_local(v_loc, v_dia); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T32] dossiê sem sessão');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T33 demonstração com dados fictícios (supabase/demo, backlog 101) -----------------------------------------
-- O mesmo SQL do ./scripts/demo-homologacao.sh: cria, confere, apaga e confere que não sobrou nada.
-- a demonstração pode estar montada na homologação: apaga antes (o rollback do fim a devolve)
update config set valor = 'homologacao' where chave = 'ambiente';
\ir ../demo/apagar.sql
create temp view t33_contagem as
  select (select count(*) from tecnicos) as tec, (select count(*) from locais) as loc, (select count(*) from escalas) as esc,
         (select count(*) from empresas) as emp, (select count(*) from tipos_documento) as tdoc, (select count(*) from tipos_atividade) as tati,
         (select count(*) from tecnico_documentos) as tdocs, (select count(*) from tipo_atividade_documentos) as tad,
         (select count(*) from notificacoes) as notif, (select count(*) from respostas) as resp, (select count(*) from ligacoes) as lig,
         (select count(*) from escala_eventos) as ev;
create temp table t33_antes on commit drop as select * from t33_contagem;
\ir ../demo/criar.sql
do $$
declare v_emp uuid := (select id from empresas where cnpj = '99999999000191');
begin
  perform pg_temp.ok(v_emp is not null, '[T33] empresa da demonstração');
  perform pg_temp.ok((select count(*) from tecnicos where empresa_id = v_emp) = 10, '[T33] 10 técnicos');
  perform pg_temp.ok((select count(*) from locais where cliente_empresa_id = v_emp) = 5, '[T33] 5 locais');
  perform pg_temp.ok((select count(*) from escalas e join tecnicos t on t.id = e.tecnico_id where t.empresa_id = v_emp) >= 45, '[T33] uma semana de escalas');
  perform pg_temp.ok(not exists (select 1 from tecnicos where empresa_id = v_emp and telefone_e164 not like '550090000%'), '[T33] telefone fora do DDD 00');
  perform pg_temp.ok(not exists (select 1 from tecnicos where empresa_id = v_emp and cpf is not null), '[T33] técnico da demonstração com CPF');
end $$;
\ir ../demo/apagar.sql
do $$
begin
  perform pg_temp.ok(not exists (select 1 from empresas where cnpj = '99999999000191'), '[T33] empresa ficou');
  perform pg_temp.ok((select row(a.*) = row(c.*) from t33_antes a, t33_contagem c), '[T33] apagar deixou resto: '
                     || (select row_to_json(a)::text || ' depois ' || row_to_json(c)::text from t33_antes a, t33_contagem c));
end $$;
\ir ../demo/apagar.sql

-- T34 AFD do REP-P, versão de conferência (migration 87, backlog 085) ---------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  r jsonb; r2 jsonb; l text[]; l2 text[]; i int; v_ok boolean; v_n int;
begin
  perform pg_temp.ok(fn_afd_crc16(convert_to('123456789', 'LATIN1')) = '2189', '[T34] CRC-16/KERMIT de referência');
  perform pg_temp.ok(fn_afd_a('Ação ✓', 7) = 'Ação   ', '[T34] campo alfanumérico fora da ISO 8859-1: ' || fn_afd_a('Ação ✓', 7));
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_ponto_afd(v_emp, current_date - 40, current_date - 1);
  perform pg_temp.ok(right(r->>'conteudo', 2) = E'\r\n', '[T34] última linha sem CR LF');
  l := string_to_array(left(r->>'conteudo', -2), E'\r\n');
  v_n := array_length(l, 1);
  perform pg_temp.ok((r->>'marcacoes')::int >= 1 and v_n = (r->>'marcacoes')::int + 2, '[T34] linhas: ' || v_n || ' para ' || (r->>'marcacoes'));
  perform pg_temp.ok(length(l[1]) = 302 and left(l[1], 10) = '0000000001'
                     and right(l[1], 4) = fn_afd_crc16(convert_to(left(l[1], 298), 'LATIN1')), '[T34] cabeçalho fora do leiaute (tamanho ' || length(l[1]) || ')');
  for i in 2 .. v_n - 1 loop
    perform pg_temp.ok(length(l[i]) = 137 and substr(l[i], 10, 1) = '7', '[T34] marcação fora do leiaute: NSR ' || left(l[i], 9) || ', tamanho ' || length(l[i]));
    if i > 2 then
      perform pg_temp.ok(left(l[i], 9) > left(l[i - 1], 9), '[T34] NSR fora de ordem');
    end if;
  end loop;
  -- o hash do 2º registro é o SHA-256 dos campos 1 a 7 dele mais o hash do 1º (quando são consecutivos)
  if v_n > 3 and left(l[3], 9)::bigint = left(l[2], 9)::bigint + 1 then
    perform pg_temp.ok(right(l[3], 64) = encode(sha256(convert_to(left(l[3], 73) || right(l[2], 64), 'LATIN1')), 'hex'), '[T34] hash não encadeado');
  end if;
  perform pg_temp.ok(length(l[v_n]) = 64 and left(l[v_n], 9) = '999999999' and right(l[v_n], 1) = '9'
                     and substr(l[v_n], 55, 9)::int = (r->>'marcacoes')::int, '[T34] trailer fora do leiaute (tamanho ' || length(l[v_n]) || ')');
  perform pg_temp.ok(r->>'nome' ~ '^AFD[0-9]{17}[0-9]{14}REP_P_CONFERENCIA\.txt$' and (r->>'conferencia')::boolean, '[T34] nome: ' || (r->>'nome'));
  -- o encadeamento vem de antes do período: o último registro do período mais curto tem a mesma linha (e o mesmo
  -- hash) no período longo; procura pelo NSR, porque o arquivo vai por NSR e a massa não tem NSR em ordem de data
  r2 := app_ponto_afd(v_emp, current_date - 10, current_date - 1);
  l2 := string_to_array(left(r2->>'conteudo', -2), E'\r\n');
  if array_length(l2, 1) > 2 then
    v_ok := false;
    for i in 2 .. v_n - 1 loop
      if left(l[i], 9) = left(l2[array_length(l2, 1) - 1], 9) then
        v_ok := l[i] = l2[array_length(l2, 1) - 1];
      end if;
    end loop;
    perform pg_temp.ok(v_ok, '[T34] hash depende do início do período');
  end if;
  perform pg_temp.ok(exists (select 1 from ponto_afd_geracoes where empresa_id = v_emp and sha256 = r->>'sha256'), '[T34] geração não registrada');
  -- data futura recusada; o papel leitura não gera (o arquivo tem o CPF de todos)
  v_ok := false;
  begin perform app_ponto_afd(v_emp, current_date, current_date + 1); exception when others then v_ok := sqlerrm like '%Período inválido%'; end;
  perform pg_temp.ok(v_ok, '[T34] período futuro aceito');
  insert into painel_usuarios (email, nome, papel, ativo) values ('qa-gestor-afd@teste.local', 'QA gestor', 'gestor', true) on conflict do nothing;
  perform set_config('request.jwt.claims', '{"email":"qa-gestor-afd@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_afd(v_emp, current_date - 1, current_date - 1); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T34] gestor gerou o AFD');
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_afd(v_emp, current_date - 1, current_date - 1); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T34] leitura gerou o AFD');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T35 espelho de ponto mensal com registro e QR (migration 88, decisão 82) -----------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_tec uuid; r jsonb; v jsonb; v_cod text; v_reg bigint; v_ok boolean;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Espelho Mensal', '5579999993535', true, true, pg_temp.cpf('353535301'), v_emp, false, v_mes - 60) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 935000 + k, v_tec, (select cpf from tecnicos where id = v_tec), ((v_mes + 2) + h) at time zone 'America/Bahia',
         tp, 'ura', 'qa', md5(random()::text)
    from (values (1, time '08:00', 'entrada'), (2, time '12:00', 'saida_almoco'), (3, time '13:00', 'volta_almoco'),
                 (4, time '17:00', 'saida')) x(k, h, tp);
  alter table ponto_marcacoes enable trigger user;

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform pg_temp.ok((r->>'emitidos')::int = 1, '[T35] emissão: ' || r::text);
  select codigo, registro into v_cod, v_reg from ponto_espelhos where tecnico_id = v_tec;
  perform pg_temp.ok((select (conteudo->'totais'->>'trabalhado_min')::int from ponto_espelhos where tecnico_id = v_tec) = 480,
                     '[T35] total do mês');
  perform pg_temp.ok((select conteudo->'trabalhador'->>'nome' from ponto_espelhos where tecnico_id = v_tec) = 'QA Espelho Mensal',
                     '[T35] trabalhador no espelho');
  -- reemitir sem mudança não cria versão; mudança no ponto cria a versão 2 e substitui a 1
  r := app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform pg_temp.ok((r->>'sem_mudanca')::int = 1, '[T35] reemissão igual: ' || r::text);
  -- o dia incluído vem inteiro: marcação incompleta barra o fechamento (decisão 96)
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_tec, 'incluir', ((v_mes + 3) + time '08:00') at time zone 'America/Bahia', 'entrada', 'Esqueceu de marcar', 'qa-admin@teste.local'),
         (v_emp, v_tec, 'incluir', ((v_mes + 3) + time '12:00') at time zone 'America/Bahia', 'saida', 'Esqueceu de marcar', 'qa-admin@teste.local');
  -- desconsiderada não tem momento próprio: precisa aparecer no espelho com a hora da marcação (Art. 84, V)
  insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, acao, motivo, autor)
  values (v_emp, v_tec, (select id from ponto_marcacoes where tecnico_id = v_tec and nsr = 935002), 'desconsiderar',
          'Marcou a saída do almoço por engano', 'qa-admin@teste.local'),
         (v_emp, v_tec, (select id from ponto_marcacoes where tecnico_id = v_tec and nsr = 935003), 'desconsiderar',
          'Marcou a volta do almoço por engano', 'qa-admin@teste.local');
  r := app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform pg_temp.ok((r->>'emitidos')::int = 1 and (select count(*) from ponto_espelhos where tecnico_id = v_tec) = 2
                     and (select registro from ponto_espelhos where tecnico_id = v_tec and versao = 2) = v_reg + 1,
                     '[T35] nova versão com registro seguinte: ' || r::text);
  perform pg_temp.ok((ponto_verificar_espelho(v_cod)->>'substituido')::boolean, '[T35] versão antiga não aparece substituída');
  perform pg_temp.ok((select conteudo->'ajustes' @> '[{"acao":"desconsiderar","hora":"12:00","tipo":"saida_almoco"}]'::jsonb
                        from ponto_espelhos where tecnico_id = v_tec and versao = 2), '[T35] marcação desconsiderada fora do espelho');
  -- versão substituída não é assinada
  v_ok := false;
  begin update ponto_espelhos set assinado_em = now(), assinatura_png = 'x', assinatura_sha256 = 'x' where tecnico_id = v_tec and versao = 1;
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] versão substituída assinada');
  -- conteúdo emitido não muda nem é apagado
  v_ok := false;
  begin update ponto_espelhos set conteudo = '{}' where tecnico_id = v_tec and versao = 2; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] conteúdo do espelho alterado');
  v_ok := false;
  begin delete from ponto_espelhos where tecnico_id = v_tec; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] espelho apagado');
  -- conferência pública: só para anon, sem nome nem CPF; mês aberto não emite
  select codigo into v_cod from ponto_espelhos where tecnico_id = v_tec and versao = 2;
  perform set_config('request.jwt.claims', '', true);
  v := ponto_verificar_espelho(lower(v_cod));
  perform pg_temp.ok((v->>'encontrado')::boolean and (v->>'integro')::boolean and (v->>'registro')::bigint = v_reg + 1,
                     '[T35] conferência: ' || (v - 'sha256')::text);
  perform pg_temp.ok(v::text not like '%QA Espelho Mensal%' and v::text not like '%' || (select cpf from tecnicos where id = v_tec) || '%',
                     '[T35] dado pessoal na conferência pública');
  perform pg_temp.ok(not (ponto_verificar_espelho('AAAAAAAAAAAAAAAA')->>'encontrado')::boolean, '[T35] código inexistente');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_emitir_espelhos(current_date, v_tec); exception when others then v_ok := sqlerrm like '%mês já encerrado%'; end;
  perform pg_temp.ok(v_ok, '[T35] mês em aberto emitido');
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_emitir_espelhos(v_mes, v_tec, true); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] leitura emitiu espelho');
  perform pg_temp.ok((select count(*) from app_ponto_espelhos(v_mes) e where e.tecnico_id = v_tec) = 1, '[T35] lista mostra só a versão atual');
  -- assinado não é substituído nem reemitido; a assinatura é gravada uma vez só
  update ponto_espelhos set assinado_em = now(), assinatura_png = 'x', assinatura_sha256 = 'x' where tecnico_id = v_tec and versao = 2;
  v_ok := false;
  begin update ponto_espelhos set substituido_em = now() where tecnico_id = v_tec and versao = 2; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] espelho assinado substituído');
  v_ok := false;
  begin update ponto_espelhos set assinatura_png = 'y' where tecnico_id = v_tec and versao = 2; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T35] assinatura regravada');
  -- a conferência é aberta ao anon; a emissão não
  perform pg_temp.ok(has_function_privilege('anon', 'ponto_verificar_espelho(text)', 'execute')
                     and not has_function_privilege('anon', 'app_ponto_emitir_espelhos(date,uuid,boolean)', 'execute')
                     and not has_function_privilege('anon', 'app_ponto_espelhos(date)', 'execute'), '[T35] permissões do anon');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T36 assinatura do espelho pelo funcionário e envio pelo WhatsApp (migration 89, decisão 82) -----------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  v_tec uuid; v_tec2 uuid; v_cpf text := pg_temp.cpf('363636301'); v_tok text; c jsonb; r jsonb; v_id uuid; v_sha text;
  v_cod text; v_ok boolean; v_n int;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Assina Espelho', '5579999993636', true, true, v_cpf, v_emp, false, v_mes - 60) returning id into v_tec;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Recebe Espelho', '5579999993637', true, true, pg_temp.cpf('363636302'), v_emp, false, v_mes - 60) returning id into v_tec2;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 936000 + k, x.t, (select cpf from tecnicos where id = x.t), ((v_mes + 5) + h) at time zone 'America/Bahia',
         tp, 'ura', 'qa', md5(random()::text)
    from (values (1, v_tec, time '08:00', 'entrada'), (2, v_tec2, time '08:05', 'entrada'),
                 (3, v_tec, time '12:00', 'saida'), (4, v_tec2, time '12:05', 'saida')) x(k, t, h, tp);
  alter table ponto_marcacoes enable trigger user;

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform app_ponto_emitir_espelhos(v_mes, v_tec2, true);
  c := app_ponto_gerar_codigo(v_tec);
  v_tok := ponto_entrar(v_cpf, c->>'codigo')->>'token';

  r := ponto_meus_espelhos(v_tok);
  perform pg_temp.ok(jsonb_array_length(r) = 1, '[T36] meus espelhos: ' || r::text);
  v_id := (r->0->>'id')::uuid;
  r := ponto_meu_espelho(v_tok, v_id);
  v_sha := r->>'sha256';
  perform pg_temp.ok(r->'conteudo'->'trabalhador'->>'nome' = 'QA Assina Espelho' and r->>'codigo' is not null, '[T36] espelho do funcionário');
  -- o espelho de outro funcionário não abre
  v_ok := false;
  begin perform ponto_meu_espelho(v_tok, (select id from ponto_espelhos where tecnico_id = v_tec2)); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T36] abriu espelho de outro funcionário');
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, (select id from ponto_espelhos where tecnico_id = v_tec2),
                                      (select sha256 from ponto_espelhos where tecnico_id = v_tec2), v_png, true);
  exception when others then v_ok := sqlerrm like '%não encontrado%'; end;
  perform pg_temp.ok(v_ok, '[T36] assinou espelho de outro funcionário');
  -- data URL de PNG com bytes que não são PNG: recusado
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, v_id, v_sha, 'data:image/png;base64,QUJDREVGR0g=', true); exception when others then v_ok := sqlerrm like '%inválida%'; end;
  perform pg_temp.ok(v_ok, '[T36] PNG falso aceito');
  -- sem ciência, desenho inválido ou versão diferente da vista: recusado
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, v_id, v_sha, v_png, false); exception when others then v_ok := sqlerrm like '%Confirme%'; end;
  perform pg_temp.ok(v_ok, '[T36] assinou sem ciência');
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, v_id, v_sha, 'javascript:alert(1)', true); exception when others then v_ok := sqlerrm like '%inválida%'; end;
  perform pg_temp.ok(v_ok, '[T36] assinatura que não é PNG aceita');
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, v_id, repeat('0', 64), v_png, true); exception when others then v_ok := sqlerrm like '%mudou%'; end;
  perform pg_temp.ok(v_ok, '[T36] assinou versão diferente da vista');
  -- assina; a segunda vez é recusada; a conferência pública confirma a assinatura amarrada à versão
  r := ponto_assinar_espelho(v_tok, v_id, v_sha, v_png, true);
  perform pg_temp.ok(r->>'assinado_em' is not null, '[T36] assinatura');
  v_ok := false;
  begin perform ponto_assinar_espelho(v_tok, v_id, v_sha, v_png, true); exception when others then v_ok := sqlerrm like '%já foi assinado%'; end;
  perform pg_temp.ok(v_ok, '[T36] assinou duas vezes');
  select codigo into v_cod from ponto_espelhos where id = v_id;
  r := ponto_verificar_espelho(v_cod);
  perform pg_temp.ok((r->>'assinatura_integra')::boolean and r->>'assinado_em' is not null, '[T36] conferência da assinatura: ' || (r - 'sha256')::text);
  perform pg_temp.ok(r::text not like '%iVBOR%', '[T36] imagem da assinatura na conferência pública');
  -- assinado não é reemitido; o envio só considera os pendentes
  r := app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform pg_temp.ok((r->>'ja_assinados')::int = 1, '[T36] assinado reemitido: ' || r::text);
  -- desligado não recebe o link; sem WhatsApp liberado não fica marcado como enviado
  update tecnicos set ativo = false, desligado_em = current_date where id = v_tec2;
  r := app_ponto_enviar_espelhos(v_mes, (select id from ponto_espelhos where tecnico_id = v_tec2));
  perform pg_temp.ok((r->>'desligados')::int = 1 and (r->>'enviados')::int = 0, '[T36] envio a desligado: ' || r::text);
  update tecnicos set ativo = true, desligado_em = null, opt_in = false where id = v_tec2;
  r := app_ponto_enviar_espelhos(v_mes, (select id from ponto_espelhos where tecnico_id = v_tec2));
  perform pg_temp.ok((r->>'sem_whatsapp')::int = 1 and (select enviado_em from ponto_espelhos where tecnico_id = v_tec2) is null,
                     '[T36] envio sem opt-in: ' || r::text);
  select count(*) into v_n from ponto_espelhos where competencia = v_mes and substituido_em is null and assinado_em is null and enviado_em is null;
  r := app_ponto_enviar_espelhos(v_mes);
  perform pg_temp.ok((r->>'enviados')::int + (r->>'sem_whatsapp')::int + (r->>'falhas')::int + (r->>'desligados')::int = v_n,
                     '[T36] envio: ' || r::text || ' de ' || v_n);
  perform pg_temp.ok((select enviado_em from ponto_espelhos where id = v_id) is null, '[T36] envio de espelho já assinado');
  -- as funções do app gravam o uso da sessão: não podem ser stable (PostgREST roda stable só leitura)
  perform pg_temp.ok(not exists (select 1 from pg_proc where proname like 'ponto\_%' and provolatile <> 'v'
                                   and pg_get_functiondef(oid) ilike '%fn_ponto_sessao(p_token)%'), '[T36] função de sessão marcada stable');
  -- a folha assinada só abre para quem tem o cofre de RH (migration 92, decisão 86); o leitura nunca
  v_ok := false;
  begin perform app_ponto_espelho_ver(v_id); exception when others then v_ok := sqlerrm like '%cofre%'; end;
  perform pg_temp.ok(v_ok, '[T39] admin sem o cofre de RH abriu a folha assinada');
  perform app_definir_rh_folhas('qa-admin@teste.local', true);
  perform pg_temp.ok((select count(*) from painel_rh_folhas_log where email = 'qa-admin@teste.local' and valor) = 1, '[T39] histórico da permissão');
  v_ok := false;
  begin perform app_definir_rh_folhas('qa-leitura@teste.local', true); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T39] permissão do cofre dada a usuário leitura');
  perform pg_temp.ok(app_ponto_espelho_ver(v_id)->>'assinatura_png' = v_png, '[T36] RH vê a assinatura');
  perform pg_temp.ok((select count(*) from app_ponto_cofre_folhas(v_mes, v_tec)) = 1, '[T39] cofre lista a folha assinada');
  r := app_ponto_espelho_prova(v_id);
  perform pg_temp.ok(r->>'sha256_conteudo' = r->>'sha256_conteudo_recalculado' and (r->'assinatura'->>'hmac_confere')::boolean,
                     '[T39] prova da folha: ' || (r - 'conteudo_texto' - 'assinatura')::text);
  perform pg_temp.ok((select count(*) from ponto_espelho_acessos where espelho_id = v_id and email = 'qa-admin@teste.local') = 2,
                     '[T39] aberturas registradas');
  perform pg_temp.ok(not has_function_privilege('anon', 'app_ponto_espelho_prova(uuid)', 'execute'), '[T39] anon baixa a prova');
  v_ok := false;
  begin update ponto_espelho_acessos set email = 'x' where espelho_id = v_id; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T39] registro de abertura alterado');
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_espelho_prova(v_id); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T39] leitura baixou a prova');
  v_ok := false;
  begin perform app_definir_rh_folhas('qa-leitura@teste.local', true); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T39] leitura deu a permissão do cofre');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform app_definir_rh_folhas('qa-admin@teste.local', false);
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_espelho_ver(v_id); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T36] leitura viu o espelho');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T37 resumo de pagamento do espelho (migration 90, decisão 83) ------------------------------------------------
-- Setembro de 2026: ter 01 com 2 h extras, qua 02 das 17h às 23h (1 h noturna), qui 03 com atestado, sex 04 com
-- 2 h abonadas pela empresa, dom 06 trabalhado, seg 07 feriado, ter 08 sem registro.
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_tec uuid; v_tec2 uuid; v_j uuid; c jsonb; d jsonb; n int := 937000;
begin
  insert into feriados (data, nome, abrangencia) values ('2026-09-07', 'Independência do Brasil', 'nacional') on conflict do nothing;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Resumo Espelho', '5579999993737', true, true, pg_temp.cpf('373737301'), v_emp, false, '2026-08-01') returning id into v_tec;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Resumo Vazio', '5579999993738', true, true, pg_temp.cpf('373737302'), v_emp, false, '2026-08-01') returning id into v_tec2;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, n + row_number() over (), v_tec, (select cpf from tecnicos where id = v_tec),
         (x.dia + x.h) at time zone 'America/Bahia', x.tipo, 'ura', 'qa', md5(random()::text)
    from (values (date '2026-09-01', time '08:00', 'entrada'), ('2026-09-01', '12:00', 'saida_almoco'),
                 ('2026-09-01', '13:00', 'volta_almoco'), ('2026-09-01', '19:00', 'saida'),
                 ('2026-09-02', '17:00', 'entrada'), ('2026-09-02', '23:00', 'saida'),
                 ('2026-09-04', '10:00', 'entrada'), ('2026-09-04', '12:00', 'saida_almoco'),
                 ('2026-09-04', '13:00', 'volta_almoco'), ('2026-09-04', '17:00', 'saida'),
                 ('2026-09-06', '08:00', 'entrada'), ('2026-09-06', '12:00', 'saida')) x(dia, h, tipo);
  alter table ponto_marcacoes enable trigger user;
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, canal, status)
  values (v_emp, v_tec, 'atestado', '2026-09-03', 'app', 'aprovada') returning id into v_j;
  insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
  values (v_emp, v_tec, '2026-09-03', v_j, 'Atestado médico apresentado', 'qa');
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor)
  values (v_emp, v_tec, '2026-09-04', '08:00', '10:00', 'Liberado pela empresa de manhã', 'qa');

  c := fn_ponto_espelho_conteudo(v_tec, '2026-09-01');
  perform pg_temp.ok((c->'resumo'->'a_pagar'->>'he50_min')::int = 120, '[T37] HE 50%: ' || (c->'resumo'->'a_pagar')::text);
  perform pg_temp.ok((c->'resumo'->'a_pagar'->>'he100_min')::int = 240, '[T37] HE 100% do domingo');
  perform pg_temp.ok((c->'resumo'->'a_pagar'->>'noturno_reduzidas_min')::int = 69
                     and (c->'resumo'->'informativo'->>'noturno_relogio_min')::int = 60, '[T37] hora noturna reduzida');
  perform pg_temp.ok((c->'resumo'->'a_pagar'->>'intervalo_nao_concedido_min')::int = 15, '[T37] intervalo não concedido');
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-02';
  perform pg_temp.ok((d->>'debito_min')::int = 111, '[T37] débito com a hora noturna reduzida: ' || d::text);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-03';
  perform pg_temp.ok((d->>'debito_min')::int = 0 and d->>'abono' is not null, '[T37] atestado descontado');
  perform pg_temp.ok(c::text not ilike '%atestado%', '[T37] motivo de saúde no espelho');
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-04';
  perform pg_temp.ok((d->>'debito_min')::int = 0 and (c->'resumo'->'informativo'->>'abonado_empresa_min')::int = 120,
                     '[T37] abono da empresa');
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-07';
  perform pg_temp.ok(d->>'feriado' is not null and (d->>'debito_min')::int = 0, '[T37] feriado');
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-08';
  perform pg_temp.ok((d->>'debito_min')::int = (c->'jornada'->>'dia_util_min')::int, '[T37] dia útil sem registro');
  perform pg_temp.ok((c->'resumo'->'informativo'->>'dias_abonados_justificados')::int = 1 and jsonb_array_length(c->'avisos') = 8,
                     '[T37] informativo e avisos');
  -- funcionário sem nenhum registro no mês: espelho vazio (o emissor pula)
  c := fn_ponto_espelho_conteudo(v_tec2, '2026-09-01');
  perform pg_temp.ok(jsonb_array_length(c->'dias') = 0, '[T37] mês sem registro gerou dias: ' || (c->'dias')::text);
  -- quem nunca marcou ponto, mas tem abono no mês: aparece, sem débito (o ponto ainda não foi implantado para ele)
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor)
  values (v_emp, v_tec2, '2026-09-10', '08:00', '09:00', 'Liberado pela empresa de manhã', 'qa');
  c := fn_ponto_espelho_conteudo(v_tec2, '2026-09-01');
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(c->'dias') x where x->>'data' = '2026-09-10')
                     and (c->'resumo'->'a_descontar'->>'debito_min')::int = 0,
                     '[T37] débito antes da primeira marcação: ' || (c->'resumo'->'a_descontar')::text);
end $$;

-- T38 HMAC da assinatura e folga compensatória (migration 91, decisão 84) -------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_dom date; v_folga date; v_tec uuid; v_tec2 uuid; v_ok boolean; r jsonb; c jsonb; d jsonb;
  v_ts timestamptz := now();
begin
  -- HMAC: depende da chave; não é o SHA-256 simples dos mesmos dados; a impressão da chave tem 8 hexadecimais
  perform pg_temp.ok(exists (select 1 from vault.secrets where name = 'ESPELHO_ASSINATURA'), '[T38] chave do HMAC no Vault');
  perform pg_temp.ok(fn_ponto_assinatura_hash('abc', 'png', v_ts, '{"ip":"1.2.3.4"}')
                     <> encode(sha256(convert_to('abc|png|' || to_char(v_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
                                                 || '|1.2.3.4|', 'UTF8')), 'hex')
                     and length(fn_ponto_assinatura_hash('abc', 'png', v_ts, '{}')) = 64
                     and fn_ponto_assinatura_chave() ~ '^[0-9a-f]{8}$', '[T38] hash da assinatura sem chave');

  -- domingo recente com um dia útil de folga já passado, na mesma semana e nos últimos 7 dias
  select s, f into v_dom, v_folga
    from (select (current_date - extract(isodow from current_date)::int - k)::date as s from (values (0), (7)) x(k)) dom
    cross join lateral (select min(g)::date as f from generate_series(dom.s + 1, dom.s + 5, interval '1 day') g
                         where g::date between current_date - 7 and current_date - 1
                           and not exists (select 1 from feriados fe where fe.data = g::date and fe.abrangencia <> 'facultativo')) fo
   where fo.f is not null order by s desc limit 1;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Folga Compensatória', '5579999993838', true, false, pg_temp.cpf('383838301'), v_emp, false, v_dom - 60) returning id into v_tec;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Folga Trabalhada', '5579999993839', true, false, pg_temp.cpf('383838302'), v_emp, false, v_dom - 60) returning id into v_tec2;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 938000 + k, x.t, (select cpf from tecnicos where id = x.t), (x.dia + x.h) at time zone 'America/Bahia',
         x.tipo, 'ura', 'qa', md5(random()::text)
    from (values (1, v_tec, v_dom, time '08:00', 'entrada'), (2, v_tec, v_dom, time '12:00', 'saida'),
                 (3, v_tec2, v_dom, time '08:00', 'entrada'), (4, v_tec2, v_dom, time '12:00', 'saida'),
                 (5, v_tec2, v_folga, time '08:00', 'entrada'), (6, v_tec2, v_folga, time '17:00', 'saida')) x(k, t, dia, h, tipo);
  alter table ponto_marcacoes enable trigger user;

  -- recusas: dia útil como trabalhado, fora da semana, sábado, domingo sem trabalho, dia de folga trabalhado
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_folga, v_folga); exception when others then v_ok := sqlerrm ~ 'domingo ou feriado|Não há trabalho'; end;
  perform pg_temp.ok(v_ok, '[T38] folga de dia útil trabalhado');
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_dom + 10, v_dom); exception when others then v_ok := sqlerrm ~ 'mesma semana|7 dias|domingo ou feriado'; end;
  perform pg_temp.ok(v_ok, '[T38] folga fora da semana');
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_dom + 6, v_dom); exception when others then v_ok := sqlerrm ~ 'Sábado|domingo ou feriado'; end;
  perform pg_temp.ok(v_ok, '[T38] folga em sábado sem expediente');
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_folga, v_dom - 7); exception when others then v_ok := sqlerrm like '%Não há trabalho%'; end;
  perform pg_temp.ok(v_ok, '[T38] folga de domingo não trabalhado');
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec2, v_folga, v_dom); exception when others then v_ok := sqlerrm like '%não foi folga%'; end;
  perform pg_temp.ok(v_ok, '[T38] folga em dia trabalhado');
  -- só admin e gestor; anon nem executa
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_folga, v_dom); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T38] leitura lançou folga');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok(not has_function_privilege('anon', 'app_ponto_folga_compensatoria(uuid,date,date)', 'execute'), '[T38] anon executa a folga');

  r := app_ponto_folga_compensatoria(v_tec, v_folga, v_dom);
  perform pg_temp.ok(r->>'id' is not null, '[T38] folga lançada');
  v_ok := false;
  begin perform app_ponto_folga_compensatoria(v_tec, v_folga, v_dom); exception when others then v_ok := sqlerrm like '%já tem folga%'; end;
  perform pg_temp.ok(v_ok, '[T38] duas folgas para o mesmo domingo');

  -- o domingo compensado não sai a 100%; a folga não gera débito nem conta como liberalidade
  c := fn_ponto_espelho_conteudo(v_tec, date_trunc('month', v_dom)::date);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_dom, 'YYYY-MM-DD');
  perform pg_temp.ok((d->>'he100_min')::int = 0 and (d->>'he50_min')::int = 0 and d->>'compensado_em' is not null,
                     '[T38] domingo compensado: ' || coalesce(d::text, 'sem linha'));
  c := fn_ponto_espelho_conteudo(v_tec, date_trunc('month', v_folga)::date);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_folga, 'YYYY-MM-DD');
  perform pg_temp.ok((d->>'debito_min')::int = 0 and d->>'folga_de' is not null
                     and (c->'resumo'->'informativo'->>'abonado_empresa_min')::int = 0
                     and (c->'resumo'->'informativo'->>'folgas_compensatorias')::int = 1, '[T38] dia de folga: ' || coalesce(d::text, 'sem linha'));
  -- se o funcionário trabalhou no dia da folga, o domingo volta a sair a 100%
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  values (v_emp, 938010, v_tec, (select cpf from tecnicos where id = v_tec), (v_folga + time '09:00') at time zone 'America/Bahia', 'entrada', 'ura', 'qa', md5(random()::text)),
         (v_emp, 938011, v_tec, (select cpf from tecnicos where id = v_tec), (v_folga + time '13:00') at time zone 'America/Bahia', 'saida', 'ura', 'qa', md5(random()::text));
  alter table ponto_marcacoes enable trigger user;
  c := fn_ponto_espelho_conteudo(v_tec, date_trunc('month', v_dom)::date);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_dom, 'YYYY-MM-DD');
  perform pg_temp.ok((d->>'he100_min')::int = 240 and d->>'compensado_em' is null, '[T38] folga trabalhada manteve compensação: ' || d::text);
end $$;

-- T40 escala / carga horária e times (migration 94, decisão 88) ------------------------------------------------
do $$
declare
  v_emp  uuid := (select v::uuid from qa where k = 'emp');
  v_inativo uuid := (select v::uuid from qa where k = 'tec3');  -- desativado no T31
  v_seg  date := current_date + (8 - extract(isodow from current_date)::int);  -- próxima segunda
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_outra uuid; v_c1 uuid; v_c2 uuid; v_c3 uuid; v_tm uuid; v_ok boolean; r jsonb;
begin
  -- funcionários ativos só deste teste (os da carga inicial foram desativados por testes anteriores)
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Escala Um', '5579999994041', true, true, pg_temp.cpf('404040401'), v_emp, true) returning id into v_t1;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Escala Dois', '5579999994042', true, true, pg_temp.cpf('404040402'), v_emp, true) returning id into v_t2;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Escala Três', '5579999994043', true, true, pg_temp.cpf('404040403'), v_emp, true) returning id into v_t3;
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- sem escala: jornada padrão (8 h de segunda a sexta, sábado meio período, domingo 0)
  perform pg_temp.ok(fn_carga_minutos_dia(v_t1, v_seg) = coalesce(nullif(fn_config('jornada_min'), '')::int, 480)
                     and fn_carga_minutos_dia(v_t1, v_seg + 6) = 0, '[T40] jornada padrão sem escala');
  -- bloqueios da CLT
  r := fn_carga_validar('{"tipo":"semanal","minutos":[480,480,480,480,480,480,480],"intervalo_min":60}');
  perform pg_temp.ok(r->'bloqueios' @> '[{"codigo":"sem_dsr"}]' and r->'bloqueios' @> '[{"codigo":"semana_acima_44h"}]', '[T40] 7 dias sem folga: ' || r::text);
  r := fn_carga_validar('{"tipo":"revezamento","minutos":[540,360,360,360,360,0,0],"intervalo_min":60}');
  perform pg_temp.ok(r->'bloqueios' @> '[{"codigo":"turno_acima_8h"}]', '[T40] turno acima de 8 h');
  r := fn_carga_validar('{"tipo":"semanal","minutos":[300,300,300,300,300,0,0],"intervalo_min":0}');
  perform pg_temp.ok(r->'bloqueios' @> '[{"codigo":"intervalo_menor_15"}]', '[T40] 5 h sem intervalo');
  r := fn_carga_validar('{"tipo":"semanal","minutos":[480,480,480,480,480,240,0],"intervalo_min":60}');
  perform pg_temp.ok(jsonb_array_length(r->'bloqueios') = 0 and jsonb_array_length(r->'riscos') = 0, '[T40] 44 h 6x1 sem risco: ' || r::text);
  v_ok := false;
  begin perform app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA ilegal', 'tipo', 'semanal',
                   'minutos', jsonb_build_array(660,660,660,660,0,0,0), 'intervalo_min', 60), '{"aceito":true}');
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] escala ilegal salva mesmo com aceite');
  -- risco: só com aceite, que fica imutável e com hash
  v_ok := false;
  begin perform app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 5x2', 'tipo', 'semanal',
                   'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 60));
  exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] escala com risco salva sem aceite');
  v_ok := false;
  begin perform app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 5x2', 'tipo', 'semanal',
                   'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 45), '{"aceito":true,"riscos":["dia_acima_8h"]}');
  exception when others then v_ok := sqlerrm like '%riscos da escala mudaram%'; end;
  perform pg_temp.ok(v_ok, '[T40] aceite de riscos diferentes dos mostrados');
  r := app_carga_validar(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 5x2', 'tipo', 'semanal',
         'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 60), 'ACT QA');
  perform pg_temp.ok(r->>'termo' like 'Termo interno de aceite de risco%QA Regressão Ltda, CNPJ 11444777000161, empregadora, por meio de%representante da empregadora%ACT QA%não é mostrado a ele nem assinado por ele%',
                     '[T40] termo da empregadora montado pelo banco: ' || coalesce(r->>'termo', 'nulo'));
  perform pg_temp.ok(not exists (select 1 from pg_proc where proname like 'ponto\_%'
                                    and (pg_get_functiondef(oid) ilike '%carga_aceites%' or pg_get_functiondef(oid) ilike '%fn_carga_termo%')),
                     '[T40] termo exposto ao funcionário (API do ponto)');
  v_c1 := app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 5x2', 'tipo', 'semanal',
            'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 60), '{"aceito":true,"instrumento":"ACT QA","riscos":["dia_acima_8h"]}');
  perform pg_temp.ok((select sha256 = encode(sha256(convert_to(texto, 'UTF8')), 'hex') and texto like '%ACT QA%' and email = 'qa-admin@teste.local'
                        from carga_aceites where carga_id = v_c1), '[T40] aceite com texto e hash');
  v_ok := false;
  begin update carga_aceites set texto = 'x' where carga_id = v_c1; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] aceite alterado');
  v_ok := false;
  begin update cargas_horarias set intervalo_min = 30 where id = v_c1; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] escala salva alterada');
  v_c2 := app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 12x36', 'tipo', '12x36', 'plantao_min', 720, 'intervalo_min', 60, 'entrada', '07:00'), '{"aceito":true,"riscos":["12x36"]}');
  v_c3 := app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 40h', 'tipo', 'semanal',
            'minutos', jsonb_build_array(480,480,480,480,480,0,0), 'intervalo_min', 60));
  perform pg_temp.ok(not exists (select 1 from carga_aceites where carga_id = v_c3), '[T40] escala sem risco não pede aceite');
  -- a escala só se aplica à própria empregadora
  v_outra := (select id from empresas where cnpj = '11222333000181');  -- criada no T25
  perform pg_temp.ok(v_outra is not null, '[T40] outra empregadora');
  v_ok := false;
  begin perform app_atribuir_carga(v_c1, 'empresa', v_outra, current_date); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] escala aplicada a outra empregadora');
  v_ok := false;
  begin perform app_atribuir_carga(v_c1, 'empresa', v_emp, current_date - 1); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] atribuição com início no passado');
  -- equipe vira time; o time pertence à empresa
  update tecnicos set equipe = ' QA Time ' where id = v_t2;
  select time_id into v_tm from tecnicos where id = v_t2;
  perform pg_temp.ok(v_tm is not null and (select nome from times where id = v_tm) = 'QA Time', '[T40] equipe virou time');
  perform app_time_definir_membros(v_tm, array[v_t2, v_t3]);
  perform pg_temp.ok((select count(*) from tecnicos where time_id = v_tm) = 2, '[T40] membros do time');
  insert into times (empresa_id, nome, ativo) values (v_emp, 'QA Inativo', false);
  v_ok := false;
  begin update tecnicos set equipe = 'qa inativo' where id = v_t1; exception when others then v_ok := sqlerrm like '%inativo%'; end;
  perform pg_temp.ok(v_ok, '[T40] funcionário posto em time inativo');
  -- prioridade: funcionário > time > empresa
  perform app_atribuir_carga(v_c3, 'empresa', v_emp, v_seg);
  perform app_atribuir_carga(v_c1, 'time', v_tm, v_seg);
  perform app_atribuir_carga(v_c2, 'tecnico', v_t3, v_seg);  -- a 12x36 é de cada funcionário (migration 97)
  perform pg_temp.ok(fn_carga_minutos_dia(v_t1, v_seg) = 480 and fn_carga_minutos_dia(v_t1, v_seg + 5) = 0, '[T40] empresa: 40 h');
  perform pg_temp.ok(fn_carga_minutos_dia(v_t2, v_seg) = 528, '[T40] time: 5x2');
  perform pg_temp.ok(fn_carga_minutos_dia(v_t3, v_seg) = 720 and fn_carga_minutos_dia(v_t3, v_seg + 1) = 0
                     and fn_carga_minutos_dia(v_t3, v_seg + 2) = 720, '[T40] funcionário: 12x36');
  v_ok := false;
  begin perform app_atribuir_carga(v_c1, 'tecnico', v_inativo, v_seg); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok or (select not ativo from tecnicos where id = v_inativo) is not true, '[T40] escala atribuída a funcionário inativo');
  v_ok := false;
  begin update carga_atribuicoes set inicio = inicio - 30 where tecnico_id = v_t3; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] início da atribuição alterado');
  perform pg_temp.ok((select alvo from carga_atribuicoes where id = fn_carga_atribuicao(v_t3, v_seg)) = 'tecnico'
                     and (select alvo from carga_atribuicoes where id = fn_carga_atribuicao(v_t2, v_seg)) = 'time', '[T40] origem da escala');
  -- nova atribuição encerra a anterior na véspera; a vigência padrão é de um ano
  perform app_atribuir_carga(v_c1, 'empresa', v_emp, v_seg + 7);
  perform pg_temp.ok((select fim from carga_atribuicoes where empresa_id = v_emp and alvo = 'empresa' and carga_id = v_c3) = v_seg + 6
                     and (select fim from carga_atribuicoes where empresa_id = v_emp and alvo = 'empresa' and carga_id = v_c1)
                         = (v_seg + 7 + interval '1 year' - interval '1 day')::date, '[T40] vigência');
  v_ok := false;
  begin perform app_carga_ativar(v_c1, false); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] escala atribuída inativada');
  perform pg_temp.ok(not has_function_privilege('anon', 'app_salvar_carga(jsonb,jsonb)', 'execute'), '[T40] anon salva escala');
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok((select count(*) from app_cargas(v_emp)) = 3
                     and not exists (select 1 from app_cargas(v_emp) where aceite_texto is not null or aceite_nome is not null or criado_por is not null)
                     and exists (select 1 from app_cargas(v_emp) where aceite_em is not null), '[T40] leitura vê as escalas, sem autor nem termo');
  v_ok := false;
  begin perform app_atribuir_carga(v_c3, 'tecnico', v_t1, v_seg); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T40] leitura atribuiu escala');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T41 limite de 2 h extras no dia pela escala e Alerta Crítico (migration 96, decisão 90) ---------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_sab date := current_date + (13 - extract(isodow from current_date)::int) % 7 + 7;  -- sábado da semana que vem
  v_seg date := current_date + (8 - extract(isodow from current_date)::int);        -- próxima segunda
  v_t uuid; v_t2 uuid; l record; x record; r jsonb; v_ok boolean; v_id uuid; a jsonb; v_d date; v_exc int;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- fora do perfil de teste e com admissão antiga, para entrar no Alerta Crítico do mês
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Limite Um', '5579999994141', true, false, pg_temp.cpf('414141401'), v_emp, false, current_date - 90) returning id into v_t;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste)
  values ('QA Limite Dois', '5579999994142', true, true, pg_temp.cpf('414141402'), v_emp, true) returning id into v_t2;
  -- sábado: a jornada do dia vem da escala da empresa (o T40 deixou uma 5x2: sábado de folga) ou da padrão (4 h);
  -- em qualquer caso, uma Programação de 8 h passa do limite (jornada do dia + 2 h)
  select * into l from app_programacao_limite(array[v_t], v_sab, '08:00', null, 'servico_inadiavel', 'Parada de linha do cliente, reparo só no sábado, sem outro técnico.');
  v_exc := l.excedente_min;
  perform pg_temp.ok(l.contratual_min = fn_carga_minutos_dia(v_t, v_sab) and l.contratual_min <= 240 and l.previsto_min = 480
                     and v_exc = 480 - (l.contratual_min + 120) and v_exc > 0
                     and l.termo like 'Termo interno de aceite de risco: Programação%representante da empregadora%não é mostrado a ele nem assinado por ele%',
                     '[T41] limite do sábado: ' || row_to_json(l)::text);
  -- segunda: 8 h cabem na jornada; não pede aceite
  select * into l from app_programacao_limite(array[v_t], v_seg, '08:00');
  perform pg_temp.ok(l.excedente_min = 0 and l.termo is null, '[T41] dia útil sem excesso');
  v_ok := false;
  begin perform app_criar_escalas(array[v_t], v_loc, v_sab, '08:00', 'QA limite', 480, 'normal', false, null, true);
  exception when others then v_ok := sqlerrm like '%passa do limite de 2 horas extras%'; end;
  perform pg_temp.ok(v_ok, '[T41] Programação acima do limite sem aceite');
  a := jsonb_build_object('aceito', true, 'motivo', 'servico_inadiavel', 'justificativa', 'curta demais', 'vistos', jsonb_build_object(v_t::text, v_exc));
  v_ok := false;
  begin perform app_criar_escalas(array[v_t], v_loc, v_sab, '08:00', 'QA limite', 480, 'normal', false, null, true, a);
  exception when others then v_ok := sqlerrm like '%pelo menos 40%'; end;
  perform pg_temp.ok(v_ok, '[T41] justificativa curta');
  a := jsonb_build_object('aceito', true, 'motivo', 'servico_inadiavel',
         'justificativa', 'Parada de linha do cliente, o reparo só pode ser feito no sábado e não há outro técnico.',
         'vistos', jsonb_build_object(v_t::text, v_exc - 1));
  v_ok := false;
  begin perform app_criar_escalas(array[v_t], v_loc, v_sab, '08:00', 'QA limite', 480, 'normal', false, null, true, a);
  exception when others then v_ok := sqlerrm like '%mudou desde a tela%'; end;
  perform pg_temp.ok(v_ok, '[T41] excesso diferente do mostrado');
  a := jsonb_set(a, '{vistos}', jsonb_build_object(v_t::text, v_exc));
  select * into x from app_criar_escalas(array[v_t], v_loc, v_sab, '08:00', 'QA limite', 480, 'normal', false, null, false, a);
  perform pg_temp.ok(x.resultado = 'criada', '[T41] criada com aceite: ' || x.resultado);
  perform pg_temp.ok((select count(*) = 1 and bool_and(sha256 = encode(sha256(convert_to(texto, 'UTF8')), 'hex'))
                             and bool_and(email = 'qa-admin@teste.local' and excedente_min = v_exc and motivo = 'servico_inadiavel')
                        from programacao_aceites where escala_id = x.escala_id), '[T41] aceite gravado com hash');
  v_ok := false;
  begin update programacao_aceites set justificativa = 'trocada' where escala_id = x.escala_id; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T41] aceite alterado');
  -- Programação de teste acima do limite: pede o aceite, mas não gera termo e continua removível
  select * into x from app_criar_escalas(array[v_t2], v_loc, v_sab, '08:00', 'QA limite teste', 480, 'normal', false, null, true,
                                         jsonb_set(a, '{vistos}', jsonb_build_object(v_t2::text, (fn_programacao_limite(v_t2, v_sab, '08:00')->>'excedente_min')::int)));
  perform pg_temp.ok(x.resultado = 'criada' and not exists (select 1 from programacao_aceites where escala_id = x.escala_id), '[T41] teste sem termo');
  perform app_remover_escala(x.escala_id);
  perform pg_temp.ok(not exists (select 1 from escalas where id = x.escala_id and status not in ('cancelada')), '[T41] Programação de teste removida');
  -- segunda: duas Programações (08:00 e 14:00) passam do limite; mudar a data para sábado também pede aceite
  select * into x from app_criar_escalas(array[v_t2], v_loc, v_seg, '08:00', 'QA limite seg', 480, 'normal', false, null, true);
  v_id := x.escala_id;
  select * into l from app_programacao_limite(array[v_t2], v_seg, '14:00');
  perform pg_temp.ok(l.excedente_min > 0, '[T41] duas programações no mesmo dia');
  v_ok := false;
  begin perform app_editar_escala(jsonb_build_object('id', v_id, 'data_servico', v_sab));
  exception when others then v_ok := sqlerrm like '%passa do limite%'; end;
  perform pg_temp.ok(v_ok, '[T41] edição para sábado sem aceite');
  -- substituir técnico de uma recusada: o novo técnico passaria do limite no sábado
  update escalas set status = 'recusada' where tecnico_id = v_t and data_servico = v_sab;
  v_ok := false;
  begin perform app_substituir_tecnico((select id from escalas where tecnico_id = v_t and data_servico = v_sab limit 1), v_t2);
  exception when others then v_ok := sqlerrm like '%passaria do limite%'; end;
  perform pg_temp.ok(v_ok, '[T41] substituição acima do limite');
  -- ponto: sábado com 7 h trabalhadas passa do limite (4 h + 2 h) pela escala; he_min segue na jornada padrão
  v_d := current_date - ((extract(isodow from current_date)::int + 1) % 7) - 7;  -- sábado retrasado
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, latitude, longitude, hash_anterior, hash)
  select v_emp, 941000 + i, v_t, (select cpf from tecnicos where id = v_t), m, tp, 'app', -12.9, -38.4, 'qa', md5(random()::text)
    from (values (1, (v_d + time '07:00') at time zone 'America/Bahia', 'entrada'),
                 (2, (v_d + time '11:00') at time zone 'America/Bahia', 'saida_almoco'),
                 (3, (v_d + time '12:00') at time zone 'America/Bahia', 'volta_almoco'),
                 (4, (v_d + time '15:00') at time zone 'America/Bahia', 'saida')) v(i, m, tp);
  alter table ponto_marcacoes enable trigger user;
  r := fn_ponto_jornada_dia(v_t, v_d);
  perform pg_temp.ok(extract(isodow from v_d) = 6 and (r->>'contratual_min')::int = 240 and (r->>'he_escala_min')::int = 180
                     and r->'alertas' ? 'he_acima_limite', '[T41] ponto do sábado acima do limite: ' || r::text);
  r := app_carga_excedida(v_d);
  perform pg_temp.ok(exists (select 1 from jsonb_array_elements(r->'funcionarios') f where f->>'tecnico_id' = v_t::text and (f->>'dias_acima')::int = 1),
                     '[T41] Alerta Crítico do mês: ' || left(r::text, 300));
  -- papel leitura: vê o alerta sem os aceites; não vê os termos nem consulta o limite
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  r := app_carga_excedida(v_d);
  perform pg_temp.ok(r->>'aceites_mes' is null, '[T41] leitura viu os aceites');
  v_ok := false;
  begin perform app_programacao_aceites(v_sab, v_sab); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T41] leitura abriu os termos');
  perform pg_temp.ok(not has_function_privilege('anon', 'app_programacao_limite(uuid[],date,time,uuid,text,text)', 'execute'), '[T41] anon consulta o limite');
  v_ok := false;
  begin perform app_programacao_limite(array[v_t], v_sab, '08:00'); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T41] leitura consultou o limite');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T42 espelho de ponto pela escala (migration 97, decisão 91) ------------------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := (date_trunc('month', current_date) - interval '2 months')::date;  -- mês fechado, antes das escalas do T40
  v_sab date; v_seg date; v_t uuid; v_t2 uuid; c5 uuid; c12 uuid; c jsonb; d jsonb; v_ok boolean; v_id uuid; n int := 942000;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- DSR: precisa cair numa folga; sem informar, vai para o domingo
  v_ok := false;
  begin perform app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA DSR errado', 'tipo', 'semanal',
                   'minutos', jsonb_build_array(480,480,480,480,480,0,0), 'intervalo_min', 60, 'dsr_dia', 3));
  exception when others then v_ok := sqlerrm like '%descanso semanal%'; end;
  perform pg_temp.ok(v_ok, '[T42] DSR em dia de trabalho');
  v_id := app_salvar_carga(jsonb_build_object('empresa_id', v_emp, 'nome', 'QA 5x2 DSR', 'tipo', 'semanal',
            'minutos', jsonb_build_array(480,480,480,480,480,0,0), 'intervalo_min', 60));
  perform pg_temp.ok((select dsr_dia from cargas_horarias where id = v_id) = 7, '[T42] DSR padrão no domingo');
  perform pg_temp.ok((select dsr_dia from app_cargas(v_emp) where id = v_id) = 7, '[T42] DSR na lista');
  -- escalas atribuídas no passado (só o teste faz isso; a função exige início de hoje em diante)
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, intervalo_min, semanal_min, riscos, criado_por, dsr_dia)
  values (v_emp, 'QA T42 5x2', 'semanal', array[480,480,480,480,480,0,0], 60, 2400, '[]', 'qa', 7) returning id into c5;
  insert into cargas_horarias (empresa_id, nome, tipo, plantao_min, intervalo_min, semanal_min, riscos, criado_por)
  values (v_emp, 'QA T42 12x36', '12x36', 720, 60, 2520, '[]', 'qa') returning id into c12;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Espelho 5x2', '5579999994241', true, false, pg_temp.cpf('424242401'), v_emp, false, v_mes - 30) returning id into v_t;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Espelho 12x36', '5579999994242', true, false, pg_temp.cpf('424242402'), v_emp, false, v_mes - 30) returning id into v_t2;
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, tecnico_id, inicio, fim, criado_por)
  values (c5, v_emp, 'tecnico', v_t, v_mes, v_mes + 60, 'qa'), (c12, v_emp, 'tecnico', v_t2, v_mes, v_mes + 60, 'qa');
  v_seg := v_mes + (8 - extract(isodow from v_mes)::int) % 7;   -- primeira segunda do mês
  v_sab := v_seg + 5;
  -- 5x2: segunda 8 h (normal), terça 6 h (2 h de débito), sábado 4 h (folga: 50%), domingo 3 h (DSR: 100%)
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, n + row_number() over (), v_t, (select cpf from tecnicos where id = v_t),
         (x.dia + x.h) at time zone 'America/Bahia', x.tipo, 'ura', 'qa', md5(random()::text)
    from (values (v_seg, time '08:00', 'entrada'), (v_seg, '12:00', 'saida_almoco'), (v_seg, '13:00', 'volta_almoco'), (v_seg, '17:00', 'saida'),
                 (v_seg + 1, '08:00', 'entrada'), (v_seg + 1, '12:00', 'saida_almoco'), (v_seg + 1, '13:00', 'volta_almoco'), (v_seg + 1, '15:00', 'saida'),
                 (v_sab, '08:00', 'entrada'), (v_sab, '12:00', 'saida'),
                 (v_sab + 1, '08:00', 'entrada'), (v_sab + 1, '11:00', 'saida')) x(dia, h, tipo);
  -- 12x36: plantão no primeiro dia do mês (07:00 às 19:00, 1 h de intervalo = 11 h) e um plantão de 13 h no 3º dia
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, n + 100 + row_number() over (), v_t2, (select cpf from tecnicos where id = v_t2),
         (x.dia + x.h) at time zone 'America/Bahia', x.tipo, 'ura', 'qa', md5(random()::text)
    from (values (v_mes, time '07:00', 'entrada'), (v_mes, '12:00', 'saida_almoco'), (v_mes, '13:00', 'volta_almoco'), (v_mes, '19:00', 'saida'),
                 (v_mes + 2, '06:00', 'entrada'), (v_mes + 2, '12:00', 'saida_almoco'), (v_mes + 2, '13:00', 'volta_almoco'), (v_mes + 2, '20:00', 'saida')) x(dia, h, tipo);
  alter table ponto_marcacoes enable trigger user;
  c := fn_ponto_espelho_conteudo(v_t, v_mes);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_seg + 1, 'YYYY-MM-DD');
  perform pg_temp.ok((d->>'debito_min')::int = 120 and (d->>'jornada_dia_min')::int = 480, '[T42] débito pela jornada do dia: ' || coalesce(d::text, '-'));
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_sab, 'YYYY-MM-DD');
  perform pg_temp.ok(d->>'repouso' = 'folga' and (d->>'he50_min')::int = 240 and (d->>'he100_min')::int = 0, '[T42] folga da escala a 50%: ' || coalesce(d::text, '-'));
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_sab + 1, 'YYYY-MM-DD');
  perform pg_temp.ok(d->>'repouso' = 'dsr' and (d->>'he100_min')::int = 180, '[T42] DSR a 100%: ' || coalesce(d::text, '-'));
  perform pg_temp.ok(c->'jornada'->'escalas'->0->>'escala' = 'QA T42 5x2', '[T42] escala no cabeçalho: ' || (c->'jornada')::text);
  c := fn_ponto_espelho_conteudo(v_t2, v_mes);
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_mes + 2, 'YYYY-MM-DD');
  perform pg_temp.ok((d->>'jornada_dia_min')::int = 720 and (d->>'he100_min')::int = 0 and d->>'repouso' is null,
                     '[T42] 12x36 sem 100% no plantão: ' || coalesce(d::text, '-'));
  select x into d from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_mes + 1, 'YYYY-MM-DD');
  perform pg_temp.ok(d is null or (d->>'debito_min')::int = 0, '[T42] folga da 12x36 sem débito: ' || coalesce(d::text, '-'));
  -- 12x36 só a um funcionário e com plantão que termina no mesmo dia (revisão do seguranca)
  v_ok := false;
  begin perform app_atribuir_carga(c12, 'empresa', v_emp, current_date + 1); exception when others then v_ok := sqlerrm like '%cada funcionário%'; end;
  perform pg_temp.ok(v_ok, '[T42] 12x36 atribuída à empresa');
  v_ok := false;
  begin perform app_atribuir_carga(c12, 'tecnico', v_t2, current_date + 70); exception when others then v_ok := sqlerrm like '%vira a noite%'; end;
  perform pg_temp.ok(v_ok, '[T42] 12x36 sem entrada (plantão que pode virar a noite)');
end $$;

-- T43 Indicadores pela escala (migration 98, decisão 93) ----------------------------------------------------
do $$
declare
  v_mes date := (date_trunc('month', current_date) - interval '2 months')::date;  -- o mesmo mês do T42
  v_ids uuid[] := array(select id from tecnicos where nome in ('QA Espelho 5x2', 'QA Espelho 12x36'));
  a jsonb; b jsonb;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok(cardinality(v_ids) = 2, '[T43] funcionários do T42');
  -- a diferença entre o painel com e sem os dois funcionários do T42 é a hora extra deles
  update tecnicos set perfil_teste = true where id = any(v_ids);
  a := app_painel_gerencial(v_mes, v_mes + 20)->'ponto';
  update tecnicos set perfil_teste = false where id = any(v_ids);
  b := app_painel_gerencial(v_mes, v_mes + 20)->'ponto';
  -- 5x2: sábado de folga 4 h + domingo (DSR) 3 h = 420; 12x36: plantão de 11 h sem extra, plantão de 13 h = 60
  perform pg_temp.ok((b->>'minutos_hora_extra')::int - (a->>'minutos_hora_extra')::int = 480,
                     '[T43] hora extra pela escala: ' || ((b->>'minutos_hora_extra')::int - (a->>'minutos_hora_extra')::int));
  perform pg_temp.ok((b->>'semanas_acima_44h')::int = (a->>'semanas_acima_44h')::int,
                     '[T43] semanas acima de 44 h: ' || (b->>'semanas_acima_44h') || ' contra ' || (a->>'semanas_acima_44h'));
  perform pg_temp.ok((b->'jornada'->>'pela_escala')::boolean and (b->'jornada'->>'escalas')::int >= 2,
                     '[T43] jornada pela escala: ' || (b->'jornada')::text);
end $$;

-- T45 validação e fechamento da folha (migration 101, decisão 96) ------------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_tec uuid; v_j uuid; p jsonb; r jsonb; v jsonb;
begin
  update empresas set logo = 'infoxtec' where id = v_emp;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Fecha Folha', '5579999994545', true, true, pg_temp.cpf('454545401'), v_emp, false, v_mes - 60) returning id into v_tec;
  -- dia 3 completo; dia 5 só com a entrada (incompleta); os outros dias da escala ficam sem registro
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 945000 + k, v_tec, (select cpf from tecnicos where id = v_tec), ((v_mes + d) + h) at time zone 'America/Bahia',
         tp, 'ura', 'qa', md5(random()::text)
    from (values (1, 2, time '08:00', 'entrada'), (2, 2, time '12:00', 'saida'), (3, 4, time '08:00', 'entrada')) x(k, d, h, tp);
  alter table ponto_marcacoes enable trigger user;
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, tipo_marcacao, hora, canal)
  values (v_emp, v_tec, 'esqueci_marcar', v_mes + 4, 'saida', '12:00', 'app') returning id into v_j;

  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(p @> '[{"tipo":"pedido_pendente","bloqueia":true}]' and p @> '[{"tipo":"marcacao_incompleta","bloqueia":true}]'
                     and p @> '[{"tipo":"sem_registro","bloqueia":false}]', '[T45] pendências: ' || p::text);
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  v := app_ponto_validar_folha(v_mes);
  perform pg_temp.ok((select (f->>'bloqueios')::int = 2 and (f->>'sem_registro')::int > 0 and (f->>'com_ponto')::boolean
                        from jsonb_array_elements(v->'funcionarios') f where f->>'tecnico_id' = v_tec::text), '[T45] painel de validação');
  -- pendência que bloqueia: não fecha nem emite
  r := app_ponto_fechar_folha(v_mes, v_tec, true);
  perform pg_temp.ok(r->>'situacao' = 'pendente', '[T45] fechou com pendência: ' || r::text);
  r := app_ponto_emitir_espelhos(v_mes, v_tec, true);
  perform pg_temp.ok((r->>'com_pendencia')::int = 1 and (r->>'emitidos')::int = 0, '[T45] emitiu com pendência: ' || r::text);

  -- o pedido é decidido e a saída entra: sobram só as faltas, que pedem confirmação
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_tec, 'incluir', ((v_mes + 4) + time '12:00') at time zone 'America/Bahia', 'saida', 'Pedido aprovado', 'qa-admin@teste.local');
  update ponto_justificativas set status = 'aprovada', decidido_por = 'qa-admin@teste.local', decidido_em = now() where id = v_j;
  -- a emissão direta também não desconta falta sem confirmação
  r := app_ponto_emitir_espelhos(v_mes, v_tec);
  perform pg_temp.ok((r->>'a_confirmar')::int = 1 and (r->>'emitidos')::int = 0, '[T45] emitiu falta sem confirmação: ' || r::text);
  r := app_ponto_fechar_folha(v_mes, v_tec, false);
  perform pg_temp.ok(r->>'situacao' = 'confirmar' and jsonb_array_length(r->'ocorrencias') > 0, '[T45] faltas sem confirmação: ' || r::text);
  r := app_ponto_fechar_folha(v_mes, v_tec, true);
  perform pg_temp.ok(r->>'situacao' = 'fechado', '[T45] fechamento: ' || r::text);
  perform pg_temp.ok((select jsonb_array_length(ocorrencias_confirmadas) > 0 and fechado_por = 'qa-admin@teste.local'
                        from ponto_folha_fechamentos where tecnico_id = v_tec), '[T45] registro do fechamento');
  perform pg_temp.ok((select conteudo->'empregador'->>'logo' from ponto_espelhos where tecnico_id = v_tec and substituido_em is null) = 'infoxtec',
                     '[T45] logotipo no espelho');
  -- fechar de novo sem mudança não duplica o registro; o registro não se altera
  r := app_ponto_fechar_folha(v_mes, v_tec, true);
  perform pg_temp.ok(r->>'situacao' = 'sem_mudanca' and (select count(*) from ponto_folha_fechamentos where tecnico_id = v_tec) = 1,
                     '[T45] refechamento: ' || r::text);
  begin
    update ponto_folha_fechamentos set fechado_por = 'x' where tecnico_id = v_tec;
    raise exception 'FALHA [T45] registro do fechamento alterado';
  exception when others then
    if sqlerrm like 'FALHA%' then raise; end if;
  end;
  -- o papel leitura vê a validação, mas não fecha
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok((select f->'fechado'->>'fechado_por' is null and (f->'fechado'->>'ocorrencias_confirmadas')::int > 0
                        from jsonb_array_elements(app_ponto_validar_folha(v_mes)->'funcionarios') f where f->>'tecnico_id' = v_tec::text),
                     '[T45] leitura vê quem fechou');
  begin
    perform app_ponto_fechar_folha(v_mes, v_tec, true);
    raise exception 'FALHA [T45] leitura fechou a folha';
  exception when others then
    if sqlerrm like 'FALHA%' then raise; end if;
  end;
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T46 checagens do fechamento (migration 102, decisão 97) ------------------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_tec uuid; v_j uuid; p jsonb; r jsonb; v_ok boolean; v_dia date;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Checagens Folha', '5579999994646', true, true, pg_temp.cpf('464646401'), v_emp, false, v_mes - 60) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 946000 + k, v_tec, (select cpf from tecnicos where id = v_tec), ((v_mes + d) + h) at time zone 'America/Bahia',
         tp, 'ura', 'qa', md5(random()::text)
    from (values -- dia 2: entrada duplicada (1 min depois)
                 (1, 1, time '08:00', 'entrada'), (2, 1, time '08:01', 'entrada'), (3, 1, time '12:00', 'saida'),
                 -- dia 3: intervalo de 20 min numa jornada de 8 h
                 (4, 2, time '08:00', 'entrada'), (5, 2, time '12:00', 'saida_almoco'), (6, 2, time '12:20', 'volta_almoco'),
                 (7, 2, time '16:20', 'saida')) x(k, d, h, tp);
  alter table ponto_marcacoes enable trigger user;
  -- dia 5: atestado aprovado (abono pelo pedido); dia 7: pedido aberto, não é falta injustificada
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, canal, status, decidido_por, decidido_em)
  values (v_emp, v_tec, 'atestado', v_mes + 4, 'app', 'pendente', null, null) returning id into v_j;
  insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
  values (v_emp, v_tec, v_mes + 4, v_j, 'Atestado médico (pedido aprovado)', 'qa-admin@teste.local');
  update ponto_justificativas set status = 'aprovada', decidido_por = 'qa-admin@teste.local', decidido_em = now() where id = v_j;
  -- o pedido aberto vai num dia devido do mês (o primeiro que hoje sai como falta injustificada)
  select min((x->>'data')::date) into v_dia from jsonb_array_elements(fn_ponto_folha_pendencias(v_tec, v_mes)) x
   where x->>'tipo' = 'sem_registro' and (x->>'data')::date > v_mes + 4;
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, canal)
  values (v_emp, v_tec, 'comparecimento', v_dia, 'app');

  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(p @> jsonb_build_array(jsonb_build_object('tipo', 'marcacao_duplicada', 'data', v_mes + 1, 'bloqueia', true)),
                     '[T46] duplicada: ' || p::text);
  perform pg_temp.ok(p @> jsonb_build_array(jsonb_build_object('tipo', 'intervalo_curto', 'data', v_mes + 2, 'nivel', 'confirmar')),
                     '[T46] intervalo abaixo do mínimo');
  perform pg_temp.ok(not p @> jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'data', v_mes + 4)), '[T46] dia do atestado como falta');
  perform pg_temp.ok(not p @> jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'data', v_dia))
                     and p @> jsonb_build_array(jsonb_build_object('tipo', 'pedido_pendente', 'data', v_dia)),
                     '[T46] dia com pedido aberto como falta injustificada');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(p) x where x->>'tipo' = 'pedido_pendente') = 1, '[T46] pedido repetido');
  -- o papel leitura vê a validação com o pedido em aberto, mas não o motivo (código de saúde é dado sensível)
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  perform pg_temp.ok((select count(*) from jsonb_array_elements(app_ponto_validar_folha(v_mes)->'funcionarios') f,
                             jsonb_array_elements(f->'pendencias') x
                       where f->>'tecnico_id' = v_tec::text and x->>'tipo' = 'pedido_pendente' and not x ? 'motivo') = 1,
                     '[T46] motivo do pedido na validação');

  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- a prévia diz de onde vem o abono, sem o motivo de saúde
  r := app_ponto_previa_folha(v_mes, v_tec);
  perform pg_temp.ok((select d->>'abono_motivo' from jsonb_array_elements(r->'conteudo'->'dias') d where (d->>'data')::date = v_mes + 4) = 'Atestado',
                     '[T46] abono do atestado na prévia');
  -- duplicada bloqueia; o gestor desconsidera a segunda entrada e sobra o que confirmar
  r := app_ponto_fechar_folha(v_mes, v_tec, true);
  perform pg_temp.ok(r->>'situacao' = 'pendente', '[T46] fechou com duplicada');
  insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, acao, motivo, autor)
  values (v_emp, v_tec, (select id from ponto_marcacoes where tecnico_id = v_tec and nsr = 946002), 'desconsiderar', 'Entrada em dobro', 'qa-admin@teste.local');
  update ponto_justificativas set status = 'negada', decidido_por = 'qa-admin@teste.local', decidido_em = now()
   where tecnico_id = v_tec and status = 'pendente';
  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(not p @> '[{"bloqueia":true}]' and p @> jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'data', v_dia)),
                     '[T46] depois dos ajustes: ' || p::text);
  r := app_ponto_fechar_folha(v_mes, v_tec, false);
  perform pg_temp.ok(r->>'situacao' = 'confirmar', '[T46] fechou sem confirmar: ' || r::text);
  -- confirmou menos ocorrências do que há agora (apareceu uma depois da validação): volta para conferir
  r := app_ponto_fechar_folha(v_mes, v_tec, true, jsonb_array_length(r->'ocorrencias') - 1);
  perform pg_temp.ok(r->>'situacao' = 'confirmar', '[T46] fechou com ocorrência não vista: ' || r::text);
  r := app_ponto_fechar_folha(v_mes, v_tec, true, jsonb_array_length(r->'ocorrencias'));
  perform pg_temp.ok(r->>'situacao' = 'fechado'
                     and (select ocorrencias_confirmadas @> '[{"tipo":"intervalo_curto"}]' from ponto_folha_fechamentos where tecnico_id = v_tec),
                     '[T46] fechamento com as ocorrências: ' || r::text);
  perform pg_temp.ok((select d->>'abono_motivo' from ponto_espelhos e, jsonb_array_elements(e.conteudo->'dias') d
                       where e.tecnico_id = v_tec and e.substituido_em is null and (d->>'data')::date = v_mes + 4) = 'Atestado',
                     '[T46] abono do atestado no espelho');
  -- o papel leitura não abre a prévia (o espelho tem o CPF)
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_previa_folha(v_mes, v_tec); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T46] leitura abriu a prévia');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
end $$;

-- T47 troca automática do token do webhook (migration 103, decisão 98) -----------------------------------
do $$
declare r jsonb; v_a text := 'token-antigo-qa-0000'; v_n text; v_ok boolean;
begin
  insert into config (chave, valor) values ('evolution_instancia', 'infoxtec'), ('webhook_url', 'https://exemplo.invalid/webhook')
  on conflict (chave) do update set valor = excluded.valor;
  perform fn_segredo_gravar('WEBHOOK_TOKEN', v_a);
  delete from webhook_token_trocas;
  delete from net._http_response where id = 0;   -- o stub de fn_evo_post devolve o pedido 0

  -- primeira passada: troca (é a T09), o novo vale e o anterior segue aceito na janela
  r := fn_webhook_token_manutencao();
  v_n := fn_segredo('WEBHOOK_TOKEN');
  perform pg_temp.ok(r->>'situacao' = 'iniciada' and v_n <> v_a and length(v_n) = 64, '[T47] primeira troca: ' || r::text);
  perform pg_temp.ok(fn_webhook_token_ok(v_n) and fn_webhook_token_ok(v_a) and not fn_webhook_token_ok('outro') and not fn_webhook_token_ok(''),
                     '[T47] tokens aceitos na janela');
  perform pg_temp.ok(fn_webhook_token_manutencao()->>'situacao' = 'aguardando resposta', '[T47] sem resposta da Evolution');
  -- com a troca pendente, o anterior segue aceito mesmo depois dos 15 minutos; e não começa outra troca
  update webhook_token_trocas set anterior_ate = now() - interval '1 minute';
  perform pg_temp.ok(fn_webhook_token_ok(v_a), '[T47] anterior recusado com troca pendente');
  perform pg_temp.ok(fn_webhook_token_trocar('manual')->>'situacao' = 'troca em andamento', '[T47] segunda troca simultânea');
  v_ok := false;
  begin insert into webhook_token_trocas (motivo, anterior_ate) values ('manual', now()); exception when unique_violation then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T47] duas trocas abertas');
  v_ok := false;
  begin perform fn_segredo_gravar('EVOLUTION_API_KEY', 'x'); exception when others then v_ok := sqlerrm like '%não permitido%'; end;
  perform pg_temp.ok(v_ok, '[T47] fn_segredo_gravar gravou outro segredo');
  -- a Evolution aceitou: confirma e apaga a resposta (ela repete o token)
  insert into net._http_response (id, status_code, content, created) values (0, 201, '{"webhook":{"headers":{}}}', now());
  r := fn_webhook_token_manutencao();   -- em comando separado: a conferência abaixo precisa enxergar o que ela apagou
  perform pg_temp.ok(r->>'situacao' = 'confirmada' and not exists (select 1 from net._http_response where id = 0),
                     '[T47] confirmação: ' || r::text);
  -- passou a janela: o anterior sai do Vault e deixa de valer
  update webhook_token_trocas set anterior_ate = now() - interval '1 minute';
  r := fn_webhook_token_manutencao();
  perform pg_temp.ok(r->>'situacao' = 'em dia' and fn_segredo('WEBHOOK_TOKEN_ANTERIOR') is null and not fn_webhook_token_ok(v_a),
                     '[T47] fim da janela: ' || r::text);
  v_ok := false;
  begin perform fn_webhook_evolution(v_a, '{}'); exception when others then v_ok := sqlerrm like '%token invalido%'; end;
  perform pg_temp.ok(v_ok, '[T47] webhook aceitou o token antigo');

  -- troca vencida que falha: volta ao token que valia, reaponta e não tenta de novo no mesmo dia
  update webhook_token_trocas set confirmada_em = now() - interval '100 days';
  perform pg_temp.ok(fn_webhook_token_manutencao()->>'situacao' = 'iniciada', '[T47] troca agendada');
  insert into net._http_response (id, status_code, content, created) values (0, 500, 'erro', now());
  r := fn_webhook_token_manutencao();
  perform pg_temp.ok(r->>'situacao' = 'falhou' and fn_segredo('WEBHOOK_TOKEN') = v_n
                     and exists (select 1 from webhook_token_trocas where motivo = 'reversao' and confirmada_em is null),
                     '[T47] reversão: ' || r::text);
  insert into net._http_response (id, status_code, content, created) values (0, 201, '{}', now());
  perform pg_temp.ok(fn_webhook_token_manutencao()->>'situacao' = 'confirmada', '[T47] reversão confirmada');
  perform pg_temp.ok(fn_webhook_token_manutencao()->>'situacao' like 'aguardando um dia%', '[T47] nova troca logo depois da falha');
  -- a volta também falhou: os dois seguem aceitos e nada novo começa até o suporte resolver
  update webhook_token_trocas set falhou_em = now() - interval '2 days' where falhou_em is not null;
  update webhook_token_trocas set falhou_em = now() - interval '2 days', anterior_ate = now() + interval '7 days', falha = 'teste'
   where motivo = 'reversao';
  perform pg_temp.ok(fn_webhook_token_manutencao()->>'situacao' = 'aguardando suporte', '[T47] troca nova com a volta falhada');
  -- nada disso é executável pela API
  perform pg_temp.ok(not has_function_privilege('authenticated', 'fn_webhook_token_manutencao()', 'execute')
                     and not has_function_privilege('anon', 'fn_segredo_gravar(text,text)', 'execute')
                     and not has_function_privilege('service_role', 'fn_webhook_token_trocar(text)', 'execute'), '[T47] permissões');
end $$;

-- T48 inconsistências do ponto, parte 1 (migration 104, decisão 100) ------------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_tec uuid; p jsonb; r jsonb; v_ok boolean; v_av text[];
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Intervalo', '5579999994848', true, true, pg_temp.cpf('484848401'), v_emp, false, v_mes - 60) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 948000 + k, v_tec, (select cpf from tecnicos where id = v_tec), ((v_mes + d) + h) at time zone 'America/Bahia',
         tp, 'ura', 'qa', md5(random()::text)
    from (values -- dia 2: 9 h seguidas, sem intervalo
                 (1, 1, time '08:00', 'entrada'), (2, 1, time '17:00', 'saida'),
                 -- dia 3: 4 h, dois registros bastam
                 (3, 2, time '08:00', 'entrada'), (4, 2, time '12:00', 'saida'),
                 -- dia 4: 5 h sem os 15 min
                 (5, 3, time '08:00', 'entrada'), (6, 3, time '13:00', 'saida')) x(k, d, h, tp);
  alter table ponto_marcacoes enable trigger user;

  -- empresa sem a exigência: segue "confirmar", como antes
  update empresas set exige_registro_intervalo = false where id = v_emp;
  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(p @> jsonb_build_array(jsonb_build_object('tipo', 'sem_intervalo', 'data', v_mes + 1, 'nivel', 'confirmar'))
                     and not p @> '[{"bloqueia":true}]', '[T48] sem a exigência: ' || p::text);
  -- com a exigência: acima de 4 h sem o par bloqueia; até 4 h não aponta nada
  update empresas set exige_registro_intervalo = true where id = v_emp;
  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(p @> jsonb_build_array(jsonb_build_object('tipo', 'intervalo_nao_registrado', 'data', v_mes + 1, 'bloqueia', true))
                     and p @> jsonb_build_array(jsonb_build_object('tipo', 'intervalo_nao_registrado', 'data', v_mes + 3, 'bloqueia', true))
                     and not exists (select 1 from jsonb_array_elements(p) x where (x->>'data')::date = v_mes + 2
                                       and x->>'tipo' in ('intervalo_nao_registrado', 'sem_intervalo')),
                     '[T48] com a exigência: ' || p::text);
  r := app_ponto_fechar_folha(v_mes, v_tec, true);
  perform pg_temp.ok(r->>'situacao' = 'pendente', '[T48] fechou com intervalo não registrado: ' || r::text);
  -- o abono do gestor no dia libera (vira ocorrência a confirmar), sem criar marcação
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor) values
    (v_emp, v_tec, v_mes + 1, '12:00', '13:00', 'Intervalo abonado pelo gestor', 'qa-admin@teste.local'),
    (v_emp, v_tec, v_mes + 3, '10:00', '10:15', 'Intervalo abonado pelo gestor', 'qa-admin@teste.local');
  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  perform pg_temp.ok(not p @> '[{"tipo":"intervalo_nao_registrado"}]'
                     and p @> jsonb_build_array(jsonb_build_object('tipo', 'sem_intervalo', 'data', v_mes + 1, 'nivel', 'confirmar'))
                     and (select count(*) from ponto_marcacoes where tecnico_id = v_tec) = 6,
                     '[T48] abono do intervalo: ' || p::text);

  -- o gestor nunca cria marcação: não há mais a assinatura com a inclusão, e "incluir" é recusado
  perform pg_temp.ok(not exists (select 1 from pg_proc where proname = 'app_ponto_ajustar' and pronargs = 8), '[T48] assinatura antiga');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'incluir', 'Marcação esquecida pelo gestor');
  exception when others then v_ok := sqlerrm like '%não inclui marcação%'; end;
  perform pg_temp.ok(v_ok, '[T48] gestor incluiu marcação');

  -- comprovante da saída para o intervalo: "retorno a partir de" (só em dia com jornada acima de 4 h)
  if fn_carga_minutos_dia(v_tec, (now() at time zone 'America/Bahia')::date) > 240 then
    alter table ponto_marcacoes disable trigger user;
    insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
    values (v_emp, 948010, v_tec, (select cpf from tecnicos where id = v_tec), now() - interval '1 minute', 'saida_almoco', 'ura', 'qa', 'qa');
    alter table ponto_marcacoes enable trigger user;
    v_av := fn_ponto_avisar(v_tec, 'saida_almoco');
    perform pg_temp.ok(array_to_string(v_av, ' ') like '%Retorno a partir de%', '[T48] retorno no comprovante: ' || coalesce(array_to_string(v_av, ' '), '-'));
    perform pg_temp.ok(fn_ponto_aviso_previo(v_tec, 'volta_almoco') like '%registrada normalmente%', '[T48] aviso da volta informativo');
  end if;

  -- só o administrador muda a exigência
  insert into painel_usuarios (email, nome, papel, ativo) values ('qa-gestor@teste.local', 'QA Gestor', 'gestor', true)
  on conflict (email) do update set papel = 'gestor', ativo = true;
  perform set_config('request.jwt.claims', '{"email":"qa-gestor@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin
    perform app_salvar_empresa(jsonb_build_object('id', v_emp, 'cnpj', '11444777000161', 'razao_social', 'QA Regressão Ltda',
                                                  'empregadora', true, 'exige_registro_intervalo', false));
  exception when others then v_ok := sqlerrm like '%administrador%'; end;
  perform pg_temp.ok(v_ok, '[T48] gestor mudou a exigência');
  -- o gestor salva o cadastro sem mexer na opção (painel antigo não manda o campo)
  perform app_salvar_empresa(jsonb_build_object('id', v_emp, 'cnpj', '11444777000161', 'razao_social', 'QA Regressão Ltda', 'empregadora', true));
  perform pg_temp.ok((select exige_registro_intervalo from empresas where id = v_emp), '[T48] cadastro sem o campo perdeu a opção');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  perform app_salvar_empresa(jsonb_build_object('id', v_emp, 'cnpj', '11444777000161', 'razao_social', 'QA Regressão Ltda',
                                                'empregadora', true, 'exige_registro_intervalo', false));
  perform pg_temp.ok(not (select exige_registro_intervalo from empresas where id = v_emp), '[T48] administrador mudou a exigência');
  perform pg_temp.ok(not has_function_privilege('authenticated', 'fn_ponto_aviso_intervalo_pendente()', 'execute'), '[T48] permissões');

  -- migration 105: abono vale enquanto o espelho do mês não foi assinado (não mais 62 dias)
  v_ok := false;
  begin perform app_ponto_abonar(v_tec, current_date - 70, 'Abono de mês antigo sem espelho assinado'); raise exception 'aceito';
  exception when others then v_ok := sqlerrm = 'aceito'; end;
  perform pg_temp.ok(v_ok, '[T48] recusou abono de 70 dias atrás em mês sem espelho assinado');
  p := fn_ponto_folha_pendencias(v_tec, v_mes);
  r := app_ponto_fechar_folha(v_mes, v_tec, true, (select count(*)::int from jsonb_array_elements(p) x where not (x->>'bloqueia')::boolean));
  perform pg_temp.ok(r->>'situacao' = 'fechado', '[T48] fechamento para a assinatura: ' || r::text);
  -- espelho emitido e não assinado: abono entra e avisa que o espelho ficou desatualizado (desfeito em seguida)
  v_ok := false;
  begin
    r := app_ponto_abonar(v_tec, v_mes + 5, 'Abono depois da emissão do espelho');
    v_ok := (r->>'espelho_desatualizado')::boolean;
    raise exception 'desfaz';
  exception when others then null; end;
  perform pg_temp.ok(v_ok, '[T48] abono em mês com espelho emitido sem aviso de desatualizado');
  update ponto_espelhos set assinado_em = now(), assinatura_png = 'x', assinatura_sha256 = 'x' where tecnico_id = v_tec and substituido_em is null;
  v_ok := false;
  begin perform app_ponto_abonar(v_tec, v_mes + 5, 'Abono depois da assinatura do espelho');
  exception when others then v_ok := sqlerrm like '%assinado%'; end;
  perform pg_temp.ok(v_ok, '[T48] abonou mês com espelho assinado');
  v_ok := false;
  begin perform app_ponto_estornar_abono((select id from ponto_abonos where tecnico_id = v_tec and data = v_mes + 1 limit 1), 'Estorno depois da assinatura');
  exception when others then v_ok := sqlerrm like '%assinado%'; end;
  perform pg_temp.ok(v_ok, '[T48] estornou abono de mês com espelho assinado');
  v_ok := false;
  begin perform app_ponto_ajustar(v_tec, 'desconsiderar', 'Depois da assinatura do espelho', p_marcacao => (select id from ponto_marcacoes where nsr = 948001));
  exception when others then v_ok := sqlerrm like '%assinado%'; end;
  perform pg_temp.ok(v_ok, '[T48] desconsiderou marcação de mês com espelho assinado');
end $$;

-- T49 hora extra com aprovação do gestor (migration 106, decisão 100 parte 2) ---------------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_loc uuid := (select v::uuid from qa where k = 'loc');
  v_agora timestamp := now() at time zone 'America/Bahia';
  v_a uuid; v_b uuid; v_sup uuid; v_h uuid; v_t text; r jsonb; p jsonb; v_ok boolean;
begin
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA HE Pedido', '5579999994901', true, true, pg_temp.cpf('494949401'), v_emp, false, current_date - 90) returning id into v_a;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA HE Programada', '5579999994902', true, true, pg_temp.cpf('494949402'), v_emp, false, current_date - 90) returning id into v_b;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, empresa_id, perfil_teste, is_supervisor)
  values ('QA Supervisor HE', '5579999994909', true, true, v_emp, false, true) returning id into v_sup;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  values (v_emp, 949001, v_a, (select cpf from tecnicos where id = v_a), now() - interval '2 minutes', 'inicio_he', 'ura', 'qa', 'qa1');
  alter table ponto_marcacoes enable trigger user;

  -- sem Programação: pedido ao supervisor; a marcação já vale
  v_t := fn_ponto_he_inicio(v_a);
  select id into v_h from ponto_he_autorizacoes where tecnico_id = v_a;
  perform pg_temp.ok(v_t like '%enviado ao gestor%' and (select status from ponto_he_autorizacoes where id = v_h) = 'pendente',
                     '[T49] pedido de HE: ' || coalesce(v_t, '-'));
  perform pg_temp.ok(fn_ponto_he_inicio(v_a) is null, '[T49] pedido em dobro para a mesma marcação');
  p := fn_ponto_folha_pendencias(v_a, date_trunc('month', current_date)::date);
  perform pg_temp.ok(p @> '[{"tipo":"he_pendente","bloqueia":true}]', '[T49] HE pendente no fechamento: ' || p::text);

  -- só supervisor decide pelo botão; a decisão vale uma vez
  r := fn_ponto_he_resposta(pg_temp.msg('5579999994902', 'HE0', jsonb_build_object('buttonsResponseMessage',
         jsonb_build_object('selectedButtonId', 'he:ok:' || v_h))));
  perform pg_temp.ok(r->>'ignorado' like '%supervisor%' and (select status from ponto_he_autorizacoes where id = v_h) = 'pendente',
                     '[T49] funcionário aprovou HE: ' || coalesce(r::text, '-'));
  r := fn_ponto_he_resposta(pg_temp.msg('5579999994909', 'HE1', jsonb_build_object('buttonsResponseMessage',
         jsonb_build_object('selectedButtonId', 'he:ok:' || v_h))));
  perform pg_temp.ok(r->>'acao' = 'he_aprovada' and (select status || canal_decisao from ponto_he_autorizacoes where id = v_h) = 'aprovadawhatsapp',
                     '[T49] aprovação pelo botão: ' || coalesce(r::text, '-'));
  r := fn_ponto_he_resposta(pg_temp.msg('5579999994909', 'HE2', jsonb_build_object('buttonsResponseMessage',
         jsonb_build_object('selectedButtonId', 'he:nao:' || v_h))));
  perform pg_temp.ok(r->>'acao' = 'he_ja_decidida' and (select status from ponto_he_autorizacoes where id = v_h) = 'aprovada',
                     '[T49] segunda decisão: ' || coalesce(r::text, '-'));
  perform pg_temp.ok(fn_ponto_he_resposta(pg_temp.msg('5579999994909', 'HE3', '{"conversation":"ok"}')) is null, '[T49] texto comum interceptado');
  -- supervisor de outra empresa e botão montado fora do formato não decidem
  insert into empresas (cnpj, razao_social, empregadora, ativo) values ('11222333000181', 'QA Outra Empresa', true, true)
  on conflict (cnpj) do nothing;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, empresa_id, perfil_teste, is_supervisor)
  values ('QA Supervisor Outra', '5579999994908', true, true, (select id from empresas where cnpj = '11222333000181'), false, true);
  perform fn_ponto_he_inicio(v_a);   -- sem marcação nova: nada muda
  perform pg_temp.ok(fn_ponto_he_resposta(pg_temp.msg('5579999994908', 'HE4', jsonb_build_object('buttonsResponseMessage',
                       jsonb_build_object('selectedButtonId', 'he:nao:' || v_h))))->>'ignorado' like '%outra empresa%',
                     '[T49] supervisor de outra empresa decidiu');
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, perfil_teste, is_supervisor)
  values ('QA Supervisor Sem Empresa', '5579999994907', true, true, false, true);
  perform pg_temp.ok(fn_ponto_he_resposta(pg_temp.msg('5579999994907', 'HE5', jsonb_build_object('buttonsResponseMessage',
                       jsonb_build_object('selectedButtonId', 'he:nao:' || v_h))))->>'ignorado' like '%outra empresa%',
                     '[T49] supervisor sem empresa decidiu (migration 112)');
  perform pg_temp.ok(fn_ponto_he_resposta(pg_temp.msg('5579999994909', 'HE5', jsonb_build_object('buttonsResponseMessage',
                       jsonb_build_object('selectedButtonId', 'he:ok:' || repeat('-', 36))))) is null, '[T49] botão fora do formato');
  v_ok := false;
  begin update ponto_he_autorizacoes set status = 'reprovada' where id = v_h; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T49] decisão alterada');
  v_ok := false;
  begin delete from ponto_he_autorizacoes where id = v_h; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T49] autorização apagada');

  -- reprovada pelo painel: a marcação fica; no fechamento sai para confirmar
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  values (v_emp, 949002, v_a, (select cpf from tecnicos where id = v_a), now() - interval '1 minute', 'inicio_he', 'ura', 'qa', 'qa2');
  alter table ponto_marcacoes enable trigger user;
  perform fn_ponto_he_inicio(v_a);
  select id into v_h from ponto_he_autorizacoes where tecnico_id = v_a and status = 'pendente';
  perform set_config('request.jwt.claims', '{"email":"qa-leitura@teste.local","role":"authenticated"}', true);
  v_ok := false;
  begin perform app_ponto_he_decidir(v_h, false); exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T49] leitura decidiu HE');
  perform pg_temp.ok(not (app_ponto_he_autorizacoes(current_date - 1, current_date)->0 ? 'decidido_por')
                     or app_ponto_he_autorizacoes(current_date - 1, current_date)->0->>'decidido_por' is null, '[T49] leitura vê quem decidiu');
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  r := app_ponto_he_decidir(v_h, false);
  p := fn_ponto_folha_pendencias(v_a, date_trunc('month', current_date)::date);
  perform pg_temp.ok(r->>'situacao' = 'reprovada' and p @> '[{"tipo":"he_reprovada","nivel":"confirmar"}]'
                     and not p @> '[{"tipo":"he_pendente"}]' and (select count(*) from ponto_marcacoes where tecnico_id = v_a) = 2,
                     '[T49] reprovada pelo painel: ' || p::text);

  -- Programação do dia cobrindo o horário: autorizada sem pedido (só fora da virada do dia, para não falhar à meia-noite)
  if v_agora::time between time '01:00' and time '22:00' then
    insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, hora_fim_prevista, descricao_tarefa, status, criado_por)
    values (v_b, v_loc, v_agora::date, (v_agora - interval '1 hour')::time(0), (v_agora + interval '1 hour')::time(0), 'QA HE programada', 'agendada', 'qa');
    alter table ponto_marcacoes disable trigger user;
    insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
    values (v_emp, 949003, v_b, (select cpf from tecnicos where id = v_b), now() - interval '1 minute', 'inicio_he', 'ura', 'qa', 'qa3');
    alter table ponto_marcacoes enable trigger user;
    v_t := fn_ponto_he_inicio(v_b);
    perform pg_temp.ok(v_t like '%autorizada pela Programação%'
                       and (select status || origem from ponto_he_autorizacoes where tecnico_id = v_b) = 'aprovadaprogramada',
                       '[T49] HE programada: ' || coalesce(v_t, '-'));
  end if;
  perform pg_temp.ok(not has_function_privilege('anon', 'fn_ponto_he_resposta(jsonb)', 'execute')
                     and not has_function_privilege('authenticated', 'fn_ponto_he_decidir(uuid,boolean,text,text)', 'execute'), '[T49] permissões');
end $$;

-- T50 espelho com o art. 84 completo e PDF assinado guardado e entregue (migration 107, decisão 104) -------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  v_cpf text := pg_temp.cpf('505050501');
  v_pdf bytea := convert_to('%PDF-1.4 teste', 'UTF8') || decode(repeat('00', 1200), 'hex');
  v_tec uuid; v_tec2 uuid; v_tok text; v_tok2 text; c jsonb; r jsonb; v_id uuid; v_ok boolean;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  -- sem chamada de rede no teste: o pedido do PDF só registra
  update config set valor = '' where chave = 'espelho_pdf_url';
  -- CEI/CAEPF/CNO: só dígitos, 12 a 14
  v_ok := false;
  begin perform app_salvar_empresa((select to_jsonb(e) from empresas e where id = v_emp) || '{"cei_caepf_cno":"12345"}');
  exception when others then v_ok := sqlerrm like '%CEI, CAEPF ou CNO inválido%'; end;
  perform pg_temp.ok(v_ok, '[T50] CEI inválido aceito');
  perform app_salvar_empresa((select to_jsonb(e) from empresas e where id = v_emp) || '{"cei_caepf_cno":"12.345.67890/12"}');
  perform pg_temp.ok((select cei_caepf_cno from empresas where id = v_emp) = '123456789012', '[T50] CEI gravado só com dígitos');

  insert into tecnicos (nome, telefone_e164, funcao, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Espelho PDF', '5579999995050', 'Técnico de campo', true, true, v_cpf, v_emp, false, v_mes - 60) returning id into v_tec;
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Outro PDF', '5579999995051', true, true, pg_temp.cpf('505050502'), v_emp, false, v_mes - 60) returning id into v_tec2;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 950000 + k, v_tec, v_cpf, ((v_mes + 6) + h) at time zone 'America/Bahia', tp, 'ura', 'qa', md5(random()::text)
    from (values (1, time '14:00', 'entrada'), (2, time '23:30', 'saida')) x(k, h, tp);
  alter table ponto_marcacoes enable trigger user;

  -- conteúdo do art. 84: título, CEI, cargo, duração com a hora noturna reduzida, pré-assinalação conforme a empresa
  perform app_ponto_emitir_espelhos(v_mes, v_tec, true);
  select id, conteudo into v_id, c from ponto_espelhos where tecnico_id = v_tec and substituido_em is null;
  perform pg_temp.ok(c->>'documento' like 'Espelho de Ponto Eletrônico%' and c->'empregador'->>'cei_caepf_cno' = '123456789012'
                     and c->'trabalhador'->>'funcao' = 'Técnico de campo', '[T50] cabeçalho do art. 84: ' || (c - 'dias' - 'resumo' - 'avisos')::text);
  perform pg_temp.ok((c->'jornada'->>'pre_assinalado')::boolean = not (select exige_registro_intervalo from empresas where id = v_emp),
                     '[T50] pré-assinalação');
  r := (select x from jsonb_array_elements(c->'dias') x where x->>'data' = to_char(v_mes + 6, 'YYYY-MM-DD'));
  perform pg_temp.ok((r->>'duracao_min')::int > (r->>'trabalhado_min')::int, '[T50] duração com hora noturna reduzida: ' || coalesce(r::text, '-'));

  -- assinar pede o PDF; sem PDF, o app responde "gerando"
  v_tok := ponto_entrar(v_cpf, app_ponto_gerar_codigo(v_tec)->>'codigo')->>'token';
  r := ponto_assinar_espelho(v_tok, v_id, (select sha256 from ponto_espelhos where id = v_id), v_png, true);
  perform pg_temp.ok(r->>'pdf' = 'gerando' and (select pedidos from ponto_espelho_pdfs where espelho_id = v_id) = 1, '[T50] pedido do PDF: ' || r::text);
  perform pg_temp.ok(not (ponto_meu_espelho_pdf(v_tok, v_id)->>'pronto')::boolean, '[T50] PDF pronto antes de gerar');

  -- a Edge Function só entra com o token do Vault; só PDF; grava uma vez e não muda
  perform fn_segredo_gravar('ESPELHO_PDF_TOKEN', 'qa-token-pdf');
  v_ok := false;
  begin perform fn_ponto_espelho_pdf_dados('errado', v_id); exception when others then v_ok := sqlerrm like '%token%'; end;
  perform pg_temp.ok(v_ok, '[T50] dados com token errado');
  perform pg_temp.ok(fn_ponto_espelho_pdf_dados('qa-token-pdf', v_id)->>'assinatura_png' = v_png, '[T50] dados para o PDF');
  perform pg_temp.ok(fn_ponto_espelho_pdf_dados('qa-token-pdf', (select id from ponto_espelhos where tecnico_id = v_tec2 limit 1)) is null,
                     '[T50] dados de espelho não assinado');
  v_ok := false;
  begin perform fn_ponto_espelho_pdf_gravar('qa-token-pdf', v_id, convert_to(repeat('x', 2000), 'UTF8'));
  exception when others then v_ok := sqlerrm like '%não é um PDF%'; end;
  perform pg_temp.ok(v_ok, '[T50] arquivo que não é PDF aceito');
  r := fn_ponto_espelho_pdf_gravar('qa-token-pdf', v_id, v_pdf);
  perform pg_temp.ok((r->>'gravado')::boolean and r->>'sha256' = encode(sha256(v_pdf), 'hex'), '[T50] PDF gravado: ' || r::text);
  perform pg_temp.ok(fn_ponto_espelho_pdf_gravar('qa-token-pdf', v_id, v_pdf || '\x00'::bytea)->>'motivo' = 'ja_gerado', '[T50] PDF trocado');
  v_ok := false;
  begin update ponto_espelho_pdfs set pdf = v_pdf || '\x00'::bytea where espelho_id = v_id; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T50] PDF alterado');
  v_ok := false;
  begin delete from ponto_espelho_pdfs where espelho_id = v_id; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T50] PDF apagado');
  v_ok := false;
  begin truncate ponto_espelho_pdfs; exception when others then v_ok := true; end;
  perform pg_temp.ok(v_ok, '[T50] PDFs apagados por truncate');
  perform pg_temp.ok((select enviar from ponto_espelho_pdfs where espelho_id = v_id), '[T50] pedido da assinatura marcado para entregar');
  perform pg_temp.ok(fn_ponto_espelho_pdf_varrer() = 0, '[T50] varredura sem pendência');

  -- cópia do funcionário (só a dele), do RH (com a permissão, registrada) e o hash na conferência pública
  r := ponto_meu_espelho_pdf(v_tok, v_id);
  perform pg_temp.ok((r->>'pronto')::boolean and decode(r->>'pdf', 'base64') = v_pdf and r->>'nome' like 'espelho-de-ponto-%.pdf', '[T50] cópia no app');
  v_tok2 := ponto_entrar(pg_temp.cpf('505050502'), app_ponto_gerar_codigo(v_tec2)->>'codigo')->>'token';
  v_ok := false;
  begin perform ponto_meu_espelho_pdf(v_tok2, v_id); exception when others then v_ok := sqlerrm like '%não encontrado%'; end;
  perform pg_temp.ok(v_ok, '[T50] PDF de outro funcionário');
  update painel_usuarios set rh_folhas = false where email = 'qa-admin@teste.local';
  v_ok := false;
  begin perform app_ponto_espelho_pdf(v_id); exception when others then v_ok := sqlerrm like '%cofre de folhas%'; end;
  perform pg_temp.ok(v_ok, '[T50] PDF sem a permissão do RH');
  update painel_usuarios set rh_folhas = true where email = 'qa-admin@teste.local';
  r := app_ponto_espelho_pdf(v_id);
  perform pg_temp.ok((r->>'pronto')::boolean and exists (select 1 from ponto_espelho_acessos where espelho_id = v_id and acao = 'pdf'),
                     '[T50] PDF no cofre do RH');
  perform pg_temp.ok(ponto_verificar_espelho((select codigo from ponto_espelhos where id = v_id))->>'pdf_sha256' = encode(sha256(v_pdf), 'hex'),
                     '[T50] hash do PDF na conferência pública');
  perform pg_temp.ok(not has_function_privilege('anon', 'fn_ponto_espelho_pdf_gravar(text,uuid,bytea)', 'execute')
                     and not has_function_privilege('authenticated', 'fn_ponto_espelho_pdf_dados(text,uuid)', 'execute')
                     and not has_function_privilege('anon', 'app_ponto_espelho_pdf(uuid)', 'execute')
                     and has_function_privilege('anon', 'ponto_meu_espelho_pdf(text,uuid)', 'execute'), '[T50] permissões');
end $$;

-- T51 comprovante do art. 79 em 48 horas e pedido com o tipo trocado barrado (migration 110, decisão 105) ----------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_cpf text := pg_temp.cpf('515151501');
  v_tec uuid; v_tok text; r jsonb; v_ok boolean; d date := current_date - 2;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Comprovante', '5579999995151', true, true, v_cpf, v_emp, false, current_date - 90) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash) values
    (v_emp, 951001, v_tec, v_cpf, now() - interval '1 hour', 'entrada', 'ura', 'qa', repeat('a', 64)),
    (v_emp, 951002, v_tec, v_cpf, now() - interval '3 days', 'saida', 'ura', 'qa', repeat('b', 64)),
    (v_emp, 951003, v_tec, v_cpf, (d + time '12:00') at time zone 'America/Bahia', 'saida_almoco', 'ura', 'qa', repeat('c', 64));
  alter table ponto_marcacoes enable trigger user;
  v_tok := ponto_entrar(v_cpf, app_ponto_gerar_codigo(v_tec)->>'codigo')->>'token';

  r := ponto_meus_comprovantes(v_tok);
  perform pg_temp.ok(r @> '[{"nsr":951001}]' and not r @> '[{"nsr":951002}]', '[T51] só as últimas 48 horas: ' || r::text);
  perform pg_temp.ok(jsonb_array_length(ponto_meus_comprovantes(v_tok, 951001)) = 1, '[T51] filtro por NSR');
  r := (select x from jsonb_array_elements(r) x where (x->>'nsr')::int = 951001);
  perform pg_temp.ok(r->>'titulo' = 'Comprovante de Registro de Ponto do Trabalhador' and r->>'cpf' = v_cpf
                     and r->>'sha256' = repeat('a', 64) and r->>'hora' ~ '^\d{2}:\d{2}:\d{2}$' and r->>'cnpj' is not null,
                     '[T51] campos do art. 79: ' || r::text);

  -- saída do almoço já marcada no dia: pedir outra é recusado com a dica; a volta passa
  v_ok := false;
  begin perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', d, 'saida_almoco', '12:05', null, null, 'teste', 'app');
  exception when others then v_ok := sqlerrm like 'Você já tem%12:00%volta%'; end;
  perform pg_temp.ok(v_ok, '[T51] saída do almoço repetida aceita');
  perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', d, 'volta_almoco', '13:00', null, null, 'teste', 'app');
  v_ok := false;
  begin perform fn_ponto_justificativa_criar(v_tec, 'esqueci_marcar', d, 'volta_almoco', '13:10', null, null, 'teste', 'app');
  exception when others then v_ok := sqlerrm like 'Você já tem%13:00%'; end;
  perform pg_temp.ok(v_ok, '[T51] volta repetida com pedido pendente aceita');
end $$;

-- T52 o mês fecha 10 dias depois da emissão sem assinatura (migration 111, decisão 106) ---------------------------
do $$
declare
  v_emp uuid := (select v::uuid from qa where k = 'emp');
  v_mes date := date_trunc('month', current_date - interval '1 month')::date;
  v_png text := 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  v_cpf text := pg_temp.cpf('525252501');
  v_tec uuid; v_tok text; v_ok boolean; v_msg text;
begin
  perform set_config('request.jwt.claims', '{"email":"qa-admin@teste.local","role":"authenticated"}', true);
  update config set valor = '' where chave = 'espelho_pdf_url';
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf, empresa_id, perfil_teste, admissao)
  values ('QA Prazo Espelho', '5579999995252', true, true, v_cpf, v_emp, false, v_mes - 60) returning id into v_tec;
  alter table ponto_marcacoes disable trigger user;
  insert into ponto_marcacoes (empresa_id, nsr, tecnico_id, cpf, momento, tipo, canal, hash_anterior, hash)
  select v_emp, 952000 + k, v_tec, v_cpf, ((v_mes + 6) + h) at time zone 'America/Bahia', tp, 'ura', 'qa', md5(random()::text)
    from (values (1, time '08:00', 'entrada'), (2, time '12:00', 'saida')) x(k, h, tp);
  alter table ponto_marcacoes enable trigger user;
  perform app_ponto_emitir_espelhos(v_mes, v_tec, true);
  -- dentro do prazo o abono passa
  perform app_ponto_abonar(v_tec, v_mes + 7, 'Abono dentro do prazo');
  -- emitido há 11 dias, sem assinatura: o mês está fechado
  alter table ponto_espelhos disable trigger user;
  update ponto_espelhos set emitido_em = now() - interval '11 days' where tecnico_id = v_tec and substituido_em is null;
  alter table ponto_espelhos enable trigger user;
  v_ok := false;
  begin perform app_ponto_abonar(v_tec, v_mes + 8, 'Abono fora do prazo');
  exception when others then v_msg := sqlerrm; v_ok := sqlerrm like '%está fechado%passaram 10 dias%'; end;
  perform pg_temp.ok(v_ok, '[T52] abono depois do prazo: ' || coalesce(v_msg, 'aceito'));
  -- a assinatura continua possível (ciência)
  v_tok := ponto_entrar(v_cpf, app_ponto_gerar_codigo(v_tec)->>'codigo')->>'token';
  perform ponto_assinar_espelho(v_tok, e.id, e.sha256, v_png, true) from ponto_espelhos e where e.tecnico_id = v_tec and e.substituido_em is null;
  perform pg_temp.ok((select assinado_em from ponto_espelhos where tecnico_id = v_tec and substituido_em is null) is not null,
                     '[T52] assinatura depois do prazo');
  perform pg_temp.ok(fn_ponto_espelho_prazo_dias() = 10, '[T52] prazo padrão');
end $$;

-- T53 pedido de código avisa CPF não encontrado e WhatsApp não autorizado, até 3 vezes por IP (migration 113) -------
do $$
declare
  v_r jsonb; v_cpf text := pg_temp.cpf('535353501');
begin
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.53"}', true);
  v_r := ponto_pedir_codigo('123');
  perform pg_temp.ok(v_r->>'ok' = 'false' and v_r->>'mensagem' like 'CPF inválido%', '[T53] CPF inválido avisado: ' || v_r::text);
  v_r := ponto_pedir_codigo(v_cpf);
  perform pg_temp.ok(v_r->>'ok' = 'false' and v_r->>'mensagem' like 'CPF não encontrado%', '[T53] CPF não encontrado: ' || v_r::text);
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf) values ('QA Sem Opt-in', '5579999995353', true, false, v_cpf);
  v_r := ponto_pedir_codigo(v_cpf);
  perform pg_temp.ok(v_r->>'mensagem' like '%ainda não foi autorizado%', '[T53] WhatsApp não autorizado: ' || v_r::text);
  perform ponto_pedir_codigo(pg_temp.cpf('535353502'));
  -- 4º aviso do mesmo IP na hora: volta a resposta única
  v_r := ponto_pedir_codigo(pg_temp.cpf('535353503'));
  perform pg_temp.ok(v_r->>'ok' = 'true' and v_r->>'mensagem' like 'Se o CPF estiver cadastrado%', '[T53] teto de avisos por IP: ' || v_r::text);
  -- teto geral de avisos na hora: volta a resposta única para qualquer IP
  perform set_config('request.headers', '{"cf-connecting-ip":"2001:db8:53::1"}', true);
  insert into config (chave, valor) values ('ponto_max_avisos_hora', '3')
    on conflict (chave) do update set valor = excluded.valor;
  v_r := ponto_pedir_codigo(pg_temp.cpf('535353505'));
  perform pg_temp.ok(v_r->>'ok' = 'true', '[T53] teto geral de avisos: ' || v_r::text);
  -- sem IP: resposta única
  perform set_config('request.headers', '{}', true);
  v_r := ponto_pedir_codigo(pg_temp.cpf('535353504'));
  perform pg_temp.ok(v_r->>'ok' = 'true', '[T53] sem IP, resposta única');
end $$;

-- T54 "Recebi o código do meu gestor" avisa CPF inválido e não encontrado, com o mesmo freio (migration 114) --------
do $$
declare v_r jsonb;
begin
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.54"}', true);
  delete from config where chave = 'ponto_max_avisos_hora';
  v_r := ponto_entrar('123', '123456');
  perform pg_temp.ok(v_r->>'erro' like 'CPF inválido%', '[T54] CPF inválido: ' || v_r::text);
  v_r := ponto_entrar(pg_temp.cpf('545454501'), '123456');
  perform pg_temp.ok(v_r->>'erro' like 'CPF não encontrado%', '[T54] CPF não encontrado: ' || v_r::text);
  perform ponto_entrar(pg_temp.cpf('545454502'), '123456');
  perform ponto_entrar(pg_temp.cpf('545454503'), '123456');
  v_r := ponto_entrar(pg_temp.cpf('545454504'), '123456');
  perform pg_temp.ok(v_r->>'erro' like 'Não foi possível entrar%', '[T54] teto de avisos por IP: ' || v_r::text);
  -- CPF ativo com código errado: resposta genérica (não revela nada); e a cota é a mesma do pedido de código
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.55"}', true);
  insert into tecnicos (nome, telefone_e164, ativo, opt_in, cpf) values ('QA Entrar', '5579999995454', true, true, pg_temp.cpf('545454505'));
  v_r := ponto_entrar(pg_temp.cpf('545454505'), '000000');
  perform pg_temp.ok(v_r->>'erro' like 'Não foi possível entrar%', '[T54] CPF ativo, código errado: ' || v_r::text);
  perform ponto_pedir_codigo(pg_temp.cpf('545454506'));
  perform ponto_pedir_codigo(pg_temp.cpf('545454507'));
  perform ponto_pedir_codigo(pg_temp.cpf('545454508'));
  v_r := ponto_entrar(pg_temp.cpf('545454509'), '123456');
  perform pg_temp.ok(v_r->>'erro' like 'Não foi possível entrar%', '[T54] cota compartilhada com o pedido de código: ' || v_r::text);
end $$;

select 'REGRESSÃO OK: T1 a T56' as resultado,
       (select v from qa where k = 't5_seg') as t5_2000_marcacoes_seg,
       (select v from qa where k = 't6_seg') as t6_300_mensagens_seg;
rollback;
