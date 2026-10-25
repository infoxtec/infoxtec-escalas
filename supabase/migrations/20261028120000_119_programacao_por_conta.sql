-- 119: multiempresa F2c, família da programação (docs/multiempresa-f2.md). Escalas, cargas horárias, envio, ligações,
-- linha do tempo, pendências, painel gerencial e indicadores passam a ler e alterar só na conta da sessão.
-- Garantia no dado: `fn_herdar_conta` (gatilho) põe em toda linha nova da família a conta do registro de origem
-- (técnico, escala, empresa ou carga), venha do painel, do motor ou do webhook; o default "conta 1" deixa de valer aqui.
-- `fn_pendencias_escala` e `fn_painel_locais` ganham a conta como parâmetro (sem ela, o motor segue vendo tudo até a F2f).
-- Funções recriadas a partir da definição da homologação de 28/10 (md5 do conjunto das app_*: 61323898…; fn_pendencias_escala
-- 05c444b7…, fn_painel_locais 63ffc5a1…).

-- herança de conta ------------------------------------------------------------------------------------------------------
create or replace function interno.fn_herdar_conta()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $$
declare
  v_pai   uuid := (to_jsonb(new) ->> tg_argv[1])::uuid;
  v_conta uuid;
begin
  if v_pai is not null then
    execute format('select conta_id from interno.%I where id = $1', tg_argv[0]) into v_conta using v_pai;
    -- origem informada e não achada: recusa (a linha não cai calada na conta 1; revisão do seguranca)
    if v_conta is null then
      raise exception 'Origem % não encontrada para herdar a conta.', tg_argv[0];
    end if;
    new.conta_id := v_conta;
  end if;
  return new;
end $$;

create trigger tg_00_conta before insert or update of tecnico_id on interno.escalas
  for each row execute function interno.fn_herdar_conta('tecnicos', 'tecnico_id');
create trigger tg_00_conta before insert on interno.escala_eventos
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.notificacoes
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.ligacoes
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.respostas
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.ocorrencias
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.programacao_aceites
  for each row execute function interno.fn_herdar_conta('escalas', 'escala_id');
create trigger tg_00_conta before insert on interno.cargas_horarias
  for each row execute function interno.fn_herdar_conta('empresas', 'empresa_id');
create trigger tg_00_conta before insert on interno.carga_atribuicoes
  for each row execute function interno.fn_herdar_conta('empresas', 'empresa_id');
create trigger tg_00_conta before insert on interno.carga_aceites
  for each row execute function interno.fn_herdar_conta('cargas_horarias', 'carga_id');

-- leitura interna com a conta ---------------------------------------------------------------------------------------------
drop function interno.fn_pendencias_escala(date);
create function interno.fn_pendencias_escala(p_data date, p_conta uuid default null)
 returns jsonb
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  with alvo as (
    select t.id, t.nome, t.funcao from tecnicos t
    where t.ativo and not t.perfil_teste and (p_conta is null or t.conta_id = p_conta)
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  afastados as (
    select a.id from alvo a where fn_ponto_afastado_ate(a.id, p_data) is not null
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data
                        and e.status not in ('cancelada', 'recusada') and not e.teste)
      and not exists (select 1 from afastados x where x.id = a.id)
  )
  select jsonb_build_object(
    'data', p_data, 'total_tecnicos', (select count(*) from alvo) - (select count(*) from afastados),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho' and not teste
                     and (p_conta is null or conta_id = p_conta)),
    'prazo', fn_config('alerta_escala_prazo'),
    'feriado', (select f.nome from feriados f where f.data = p_data),
    'afastados', (select count(*) from afastados),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
                    and not exists (select 1 from feriados f where f.data = p_data)
  )
$function$;

drop function interno.fn_painel_locais(date);
create function interno.fn_painel_locais(p_data date, p_conta uuid default null)
 returns jsonb
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(jsonb_agg(x order by x->>'primeira_hora' nulls last, x->>'local'), '[]'::jsonb) from (
    select jsonb_build_object(
      'local_id', l.id, 'local', coalesce(l.nome, 'Sem local definido'),
      'endereco', l.endereco, 'link_maps', l.link_maps,
      'primeira_hora', to_char(min(e.hora_inicio), 'HH24:MI'), 'total', count(*),
      'confirmadas', count(*) filter (where e.status in ('confirmada','em_execucao','concluida')),
      'aguardando', count(*) filter (where e.status in ('agendada','notificada')),
      'recusadas', count(*) filter (where e.status = 'recusada'),
      'em_execucao', count(*) filter (where e.status = 'em_execucao'),
      'concluidas', count(*) filter (where e.status = 'concluida'),
      'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
      'pct_aceite', round(100.0 * count(*) filter (where e.status in ('confirmada','em_execucao','concluida')) / count(*)),
      'pct_conclusao', round(100.0 * count(*) filter (where e.status = 'concluida') / count(*)),
      'tecnicos', jsonb_agg(jsonb_build_object(
          'escala_id', e.id, 'tecnico', t.nome, 'telefone', t.telefone_e164,
          'hora', to_char(e.hora_inicio, 'HH24:MI'), 'fim', to_char(e.hora_fim_prevista, 'HH24:MI'),
          'status', e.status::text,
          'status_envio', (select n.status_envio::text from notificacoes n
                           where n.escala_id = e.id order by n.created_at desc limit 1),
          'tarefa', e.descricao_tarefa, 'tipo', ta.nome) order by e.hora_inicio, t.nome)
    ) as x
    from escalas e
    join tecnicos t on t.id = e.tecnico_id
    left join locais l on l.id = e.local_id
    left join tipos_atividade ta on ta.id = e.tipo_atividade_id
    where e.data_servico = p_data and e.status <> 'cancelada'
      and not e.teste and not t.perfil_teste and not t.is_supervisor
      and (p_conta is null or e.conta_id = p_conta)
    group by l.id, l.nome, l.endereco, l.link_maps
  ) s
$function$;

-- cargas horárias ---------------------------------------------------------------------------------------------------------
create or replace function public.app_atribuir_carga(p_carga uuid, p_alvo text, p_alvo_id uuid, p_inicio date, p_fim date default null::date)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_c     cargas_horarias;
  v_emp   uuid;
  v_time  uuid;
  v_tec   uuid;
  v_fim   date := coalesce(p_fim, (p_inicio + interval '1 year' - interval '1 day')::date);
  v_id    uuid;
begin
  select * into v_c from cargas_horarias where id = p_carga and conta_id = fn_conta_atual();
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_c.ativo then raise exception 'Escala inativa não pode ser atribuída.'; end if;
  if p_inicio is null or p_inicio < current_date then raise exception 'A vigência começa hoje ou depois.'; end if;
  if v_fim < p_inicio then raise exception 'O fim da vigência é depois do início.'; end if;
  -- 12x36 (revisão do seguranca, decisão 91): o espelho conta o plantão por dia de calendário e alterna a partir do
  -- início da vigência; até isso ser tratado, só a um funcionário e com plantão que não vira a noite
  if v_c.tipo = '12x36' then
    if p_alvo <> 'tecnico' then
      raise exception 'A 12x36 é atribuída a cada funcionário (a alternância de plantão é de cada um), não a um time ou à empresa.';
    end if;
    if v_c.entrada is null
       or extract(epoch from v_c.entrada) / 60 + v_c.plantao_min + v_c.intervalo_min > 1440 then
      raise exception 'Plantão que vira a noite ainda não é calculado no espelho. Informe a entrada da 12x36 com plantão que termina no mesmo dia.';
    end if;
  end if;

  if p_alvo = 'empresa' then
    v_emp := p_alvo_id;
  elsif p_alvo = 'time' then
    select empresa_id into v_emp from times where id = p_alvo_id and ativo;
    v_time := p_alvo_id;
  elsif p_alvo = 'tecnico' then
    select empresa_id into v_emp from tecnicos where id = p_alvo_id and ativo and desligado_em is null;
    v_tec := p_alvo_id;
  else
    raise exception 'Atribua a uma empresa, a um time ou a um funcionário.';
  end if;
  -- a empresa da escala é da conta (conferida acima): alvo de outra conta nunca bate com ela
  if v_emp is distinct from v_c.empresa_id then
    raise exception 'A escala é da empregadora %: só se aplica à própria empresa, aos times e aos funcionários dela.',
      (select coalesce(nome_fantasia, razao_social) from empresas where id = v_c.empresa_id);
  end if;

  if exists (select 1 from carga_atribuicoes a
              where a.cancelada_em is null and a.alvo = p_alvo and a.empresa_id = v_emp
                and a.time_id is not distinct from v_time and a.tecnico_id is not distinct from v_tec
                and a.inicio >= p_inicio) then
    raise exception 'Já há uma atribuição para este alvo começando nesta data ou depois. Cancele-a antes.';
  end if;
  update carga_atribuicoes a set fim = p_inicio - 1
   where a.cancelada_em is null and a.alvo = p_alvo and a.empresa_id = v_emp
     and a.time_id is not distinct from v_time and a.tecnico_id is not distinct from v_tec
     and a.inicio < p_inicio and a.fim >= p_inicio;

  insert into carga_atribuicoes (carga_id, empresa_id, alvo, time_id, tecnico_id, inicio, fim, criado_por)
  values (p_carga, v_emp, p_alvo, v_time, v_tec, p_inicio, v_fim, v_email)
  returning id into v_id;
  return v_id;
end $function$;

create or replace function public.app_cancelar_atribuicao(p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  update carga_atribuicoes set cancelada_em = now(), cancelada_por = v_email
   where id = p_id and cancelada_em is null and inicio > current_date and conta_id = fn_conta_atual();
  if not found then
    raise exception 'Só se cancela atribuição que ainda não começou. Para trocar a que já vale, atribua outra escala a partir de uma data.';
  end if;
end $function$;

create or replace function public.app_carga_ativar(p_id uuid, p_ativo boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor']);
  if not exists (select 1 from cargas_horarias where id = p_id and conta_id = fn_conta_atual()) then
    raise exception 'Escala não encontrada.';
  end if;
  if not p_ativo and exists (select 1 from carga_atribuicoes where carga_id = p_id and cancelada_em is null and fim >= current_date) then
    raise exception 'Esta escala está atribuída (agora ou no futuro). Atribua outra no lugar antes de inativar.';
  end if;
  update cargas_horarias set ativo = p_ativo where id = p_id;
  if not found then raise exception 'Escala não encontrada.'; end if;
end $function$;

create or replace function public.app_carga_atribuicoes(p_empresa uuid default null::uuid)
 returns table(id uuid, carga_id uuid, carga text, empresa_id uuid, empresa text, alvo text, alvo_id uuid, alvo_nome text, inicio date, fim date, situacao text, criado_por text)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_leitura boolean;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_leitura := fn_papel_na_conta() = 'leitura';
  return query
    select a.id, a.carga_id, c.nome, a.empresa_id, coalesce(m.nome_fantasia, m.razao_social), a.alvo,
           coalesce(a.tecnico_id, a.time_id, a.empresa_id),
           case a.alvo when 'tecnico' then t.nome when 'time' then x.nome else coalesce(m.nome_fantasia, m.razao_social) end,
           a.inicio, a.fim,
           case when a.cancelada_em is not null then 'cancelada' when a.fim < current_date then 'encerrada'
                when a.inicio > current_date then 'futura' else 'vigente' end,
           case when v_leitura then null else a.criado_por end
      from carga_atribuicoes a join cargas_horarias c on c.id = a.carga_id join empresas m on m.id = a.empresa_id
      left join tecnicos t on t.id = a.tecnico_id left join times x on x.id = a.time_id
     where (p_empresa is null or a.empresa_id = p_empresa) and a.conta_id = fn_conta_atual()
     order by coalesce(m.nome_fantasia, m.razao_social), a.alvo, a.inicio desc;
end $function$;

create or replace function public.app_carga_excedida(p_mes date default null::date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_leitura boolean;
  v_conta   uuid;
  v_hoje    date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date;
  v_ini     date := date_trunc('month', coalesce(p_mes, v_hoje))::date;
  v_fim     date;
  v_lim     int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_lista   jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_leitura := fn_papel_na_conta() = 'leitura';
  v_conta := fn_conta_atual();
  v_fim := least((v_ini + interval '1 month' - interval '1 day')::date, v_hoje);
  if v_fim < v_ini then
    return jsonb_build_object('mes', to_char(v_ini, 'MM/YYYY'), 'hoje', 0, 'mes_total', 0, 'limite_dia_min', v_lim, 'funcionarios', '[]'::jsonb);
  end if;
  with t as (
    select x.id, x.nome, coalesce(m.nome_fantasia, m.razao_social) as empresa,
           greatest(v_ini, coalesce(x.admissao, x.created_at::date)) as ini, least(v_fim, coalesce(x.desligado_em, v_fim)) as fim
      from tecnicos x join empresas m on m.id = x.empresa_id
     where not x.perfil_teste and x.cpf is not null and (x.ativo or x.desligado_em >= v_ini) and x.conta_id = v_conta
  ), md as (
    -- só os dias com marcação ou ajuste precisam da jornada (sem marcação, não há hora extra)
    select distinct m.tecnico_id, (m.momento at time zone 'America/Bahia')::date as dia
      from ponto_marcacoes m
     where m.momento >= (v_ini - 1)::timestamp at time zone 'America/Bahia' and m.momento < (v_fim + 2)::timestamp at time zone 'America/Bahia'
       and m.conta_id = v_conta
    union
    select a.tecnico_id, (a.momento at time zone 'America/Bahia')::date
      from ponto_ajustes a
     where a.acao = 'incluir' and a.momento >= (v_ini - 1)::timestamp at time zone 'America/Bahia' and a.momento < (v_fim + 2)::timestamp at time zone 'America/Bahia'
       and a.conta_id = v_conta
  ), d as (
    select t.id, t.nome, t.empresa, g::date as dia,
           case when exists (select 1 from md where md.tecnico_id = t.id and md.dia = g::date)
                then fn_ponto_jornada_dia(t.id, g::date) end as j,
           fn_carga_minutos_dia(t.id, g::date) as contr
      from t cross join lateral generate_series(t.ini, t.fim, interval '1 day') g
     where t.ini <= t.fim
  ), f as (
    select id, nome, empresa,
           count(*) filter (where coalesce((j->>'he_escala_min')::int, 0) > v_lim) as dias_acima,
           max(coalesce((j->>'he_escala_min')::int, 0)) as maior_he_min,
           sum(coalesce((j->>'he_escala_min')::int, 0)) as he_mes_min,
           v_lim * count(*) filter (where contr > 0) as limite_mes_min,
           max(case when dia = v_hoje then coalesce((j->>'he_escala_min')::int, 0) end) as hoje_he_min,
           max(dia) filter (where coalesce((j->>'he_escala_min')::int, 0) > v_lim) as ultimo_dia
      from d group by id, nome, empresa
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'tecnico_id', f.id, 'tecnico', f.nome, 'empresa', f.empresa, 'dias_acima', f.dias_acima,
           'maior_he_min', f.maior_he_min, 'he_mes_min', f.he_mes_min, 'limite_mes_min', f.limite_mes_min,
           'hoje_he_min', coalesce(f.hoje_he_min, 0), 'hoje_acima', coalesce(f.hoje_he_min, 0) > v_lim,
           'ultimo_dia', f.ultimo_dia,
           'aceites', case when v_leitura then null else
                        (select count(*) from programacao_aceites a where a.tecnico_id = f.id and a.data between v_ini and v_fim) end)
         order by f.dias_acima desc, f.he_mes_min desc), '[]'::jsonb)
    into v_lista
    from f where f.dias_acima > 0 or f.he_mes_min > f.limite_mes_min;
  return jsonb_build_object(
    'mes', to_char(v_ini, 'MM/YYYY'), 'apurado_ate', v_fim, 'limite_dia_min', v_lim,
    'hoje', (select count(*) from jsonb_array_elements(v_lista) x where (x->>'hoje_acima')::boolean),
    'mes_total', jsonb_array_length(v_lista),
    'aceites_mes', case when v_leitura then null else
                     (select count(*) from programacao_aceites a where a.data between v_ini and v_fim and a.conta_id = v_conta) end,
    'funcionarios', v_lista);
end $function$;

create or replace function public.app_carga_validar(p jsonb, p_instrumento text default null::text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_val   jsonb;
begin
  -- o termo cita razão social e CNPJ da empresa: só da conta
  if nullif(p->>'empresa_id', '') is not null
     and not exists (select 1 from empresas where id = (p->>'empresa_id')::uuid and conta_id = fn_conta_atual()) then
    raise exception 'Empresa não encontrada.';
  end if;
  v_val := fn_carga_validar(p);
  return v_val || jsonb_build_object('termo', fn_carga_termo(p, v_val, v_email, p_instrumento));
end $function$;

create or replace function public.app_cargas(p_empresa uuid default null::uuid)
 returns table(id uuid, empresa_id uuid, empresa text, nome text, tipo text, minutos integer[], plantao_min integer, intervalo_min integer, entrada text, semanal_min integer, riscos jsonb, ativo boolean, criado_por text, created_at timestamp with time zone, atribuicoes bigint, aceite_nome text, aceite_em timestamp with time zone, aceite_texto text, aceite_sha256 text, dsr_dia integer)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  -- leitura não vê quem fez nem o termo (padrão das migrations 65 e 66; o termo é prova do empregador)
  v_leitura boolean;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_leitura := fn_papel_na_conta() = 'leitura';
  return query
    select c.id, c.empresa_id, coalesce(m.nome_fantasia, m.razao_social), c.nome, c.tipo, c.minutos, c.plantao_min,
           c.intervalo_min, to_char(c.entrada, 'HH24:MI'), c.semanal_min, c.riscos, c.ativo,
           case when v_leitura then null else c.criado_por end, c.created_at,
           (select count(*) from carga_atribuicoes a where a.carga_id = c.id and a.cancelada_em is null and a.fim >= current_date),
           case when v_leitura then null else k.nome end, k.aceito_em,
           case when v_leitura then null else k.texto end, case when v_leitura then null else k.sha256 end, c.dsr_dia
      from cargas_horarias c join empresas m on m.id = c.empresa_id
      left join carga_aceites k on k.carga_id = c.id
     where (p_empresa is null or c.empresa_id = p_empresa) and c.conta_id = fn_conta_atual()
     order by coalesce(m.nome_fantasia, m.razao_social), c.ativo desc, c.nome;
end $function$;

create or replace function public.app_cargas_funcionarios(p_empresa uuid default null::uuid, p_data date default null::date)
 returns table(tecnico_id uuid, tecnico text, empresa text, time_nome text, carga text, origem text, semanal_min integer)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_data date := coalesce(p_data, current_date);
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select t.id, t.nome, coalesce(m.nome_fantasia, m.razao_social), x.nome,
           coalesce(c.nome, 'Jornada padrão'),
           case a.alvo when 'tecnico' then 'funcionário' when 'time' then 'time' when 'empresa' then 'empresa' else 'padrão' end,
           coalesce(c.semanal_min, (select sum(fn_carga_minutos_dia(t.id, v_data + g))::int from generate_series(0, 6) g))
      from tecnicos t
      left join empresas m on m.id = t.empresa_id
      left join times x on x.id = t.time_id
      left join carga_atribuicoes a on a.id = fn_carga_atribuicao(t.id, v_data)
      left join cargas_horarias c on c.id = a.carga_id
     where t.ativo and t.desligado_em is null and t.conta_id = fn_conta_atual()
       and (p_empresa is null or t.empresa_id = p_empresa)
     order by coalesce(m.nome_fantasia, m.razao_social), t.nome;
end $function$;

create or replace function public.app_salvar_carga(p jsonb, p_aceite jsonb default null::jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_emp   uuid := (p->>'empresa_id')::uuid;
  v_nome  text := nullif(trim(p->>'nome'), '');
  v_tipo  text := coalesce(p->>'tipo', 'semanal');
  v_val   jsonb;
  v_id    uuid;
  v_emp_nome text;
  v_usu   painel_usuarios;
  v_instr text := nullif(trim(p_aceite->>'instrumento'), '');
  v_texto text;
  v_em    timestamptz := now();
  v_min   int[];
  v_dsr   int;
begin
  select coalesce(nome_fantasia, razao_social) into v_emp_nome from empresas
   where id = v_emp and empregadora and ativo and conta_id = fn_conta_atual();
  if v_emp_nome is null then raise exception 'A escala pertence a uma empregadora ativa: escolha a empresa.'; end if;
  v_val := fn_carga_validar(p);
  if v_nome is null then raise exception 'Dê um nome à escala.'; end if;
  if exists (select 1 from cargas_horarias where empresa_id = v_emp and lower(trim(nome)) = lower(v_nome)) then
    raise exception 'Já existe uma escala com este nome nesta empresa.';
  end if;
  if jsonb_array_length(v_val->'bloqueios') > 0 then
    raise exception 'Escala não permitida: %', (select string_agg(x->>'texto', ' ') from jsonb_array_elements(v_val->'bloqueios') x);
  end if;
  if jsonb_array_length(v_val->'riscos') > 0 and coalesce((p_aceite->>'aceito')::boolean, false) is not true then
    raise exception 'Esta escala depende de acordo ou norma coletiva: só é salva com o aceite de risco.';
  end if;
  if jsonb_array_length(v_val->'riscos') > 0
     and (select coalesce(array_agg(x->>'codigo' order by x->>'codigo'), '{}') from jsonb_array_elements(v_val->'riscos') x)
         is distinct from (select coalesce(array_agg(c order by c), '{}') from jsonb_array_elements_text(coalesce(p_aceite->'riscos', '[]')) c) then
    raise exception 'Os riscos da escala mudaram desde a tela. Revise e aceite de novo.';
  end if;
  if length(v_instr) > 200 then raise exception 'Acordo ou convenção: até 200 caracteres.'; end if;

  -- descanso semanal remunerado (DSR, decisão 91): um dos dias de folga; o domingo quando ele é folga
  if v_tipo <> '12x36' then
    v_min := (select array_agg(x::int order by o) from jsonb_array_elements_text(p->'minutos') with ordinality t(x, o));
    v_dsr := coalesce(nullif(p->>'dsr_dia', '')::int,
                      case when v_min[7] = 0 then 7 else (select min(i) from generate_series(1, 7) i where v_min[i] = 0) end);
    if v_dsr is null or v_dsr not between 1 and 7 or v_min[v_dsr] <> 0 then
      raise exception 'O descanso semanal (DSR) precisa cair num dia de folga da escala.';
    end if;
  end if;
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, plantao_min, intervalo_min, entrada, semanal_min, riscos, criado_por, dsr_dia)
  values (v_emp, v_nome, v_tipo,
          v_min,
          case when v_tipo = '12x36' then (p->>'plantao_min')::int end,
          coalesce((p->>'intervalo_min')::int, 0), nullif(p->>'entrada', '')::time,
          (v_val->>'semanal_min')::int, v_val->'riscos', v_email, v_dsr)
  returning id into v_id;

  if jsonb_array_length(v_val->'riscos') > 0 then
    select * into v_usu from painel_usuarios where email = v_email;
    v_texto := fn_carga_termo(p, v_val, v_email, v_instr)
      || ' Registrado em ' || to_char(v_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (horário de Brasília, UTC-3).';
    insert into carga_aceites (carga_id, empresa_id, riscos, instrumento, texto, sha256, nome, email, papel, aceito_em)
    values (v_id, v_emp, v_val->'riscos', v_instr, v_texto, encode(sha256(convert_to(v_texto, 'UTF8')), 'hex'),
            coalesce(nullif(v_usu.nome, ''), v_email), v_email, fn_papel_na_conta(), v_em);
  end if;
  return v_id;
end $function$;

-- programação --------------------------------------------------------------------------------------------------------------
create or replace function public.app_criar_escalas(p_tecnicos uuid[], p_local uuid, p_data date, p_hora time without time zone, p_tarefa text, p_duracao integer default 240, p_prioridade text default 'normal'::text, p_enviar boolean default true, p_tipo uuid default null::uuid, p_teste boolean default false, p_aceite jsonb default null::jsonb)
 returns table(tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  r record;
  t record;
  v_lim jsonb := '{}';
  j jsonb;
begin
  if coalesce(trim(p_tarefa), '') = '' then raise exception 'Descreva a tarefa.'; end if;
  -- técnicos, local e tipo da conta: id de outra conta é "não encontrado"
  if exists (select 1 from unnest(coalesce(p_tecnicos, '{}')) x(id)
              where not exists (select 1 from tecnicos t2 where t2.id = x.id and t2.conta_id = v_conta)) then
    raise exception 'Técnico não encontrado.';
  end if;
  if p_local is not null and not exists (select 1 from locais where id = p_local and conta_id = v_conta) then
    raise exception 'Local não encontrado.';
  end if;
  if p_tipo is not null and not exists (select 1 from tipos_atividade where id = p_tipo and conta_id = v_conta) then
    raise exception 'Tipo de atividade não encontrado.';
  end if;
  perform fn_validar_inicio(p_data, p_hora);

  -- limite de 2 h extras no dia, pela escala de cada técnico (decisão 90): passou, só com o aceite da empresa
  for t in select x.id, x.nome from tecnicos x where x.id = any(coalesce(p_tecnicos, '{}')) order by x.id loop
    -- uma criação por técnico e dia de cada vez: duas ao mesmo tempo não passam juntas do limite
    perform pg_advisory_xact_lock(hashtext(t.id::text || p_data::text));
    j := fn_programacao_limite(t.id, p_data, p_hora, null);
    if (j->>'excedente_min')::int > 0 then
      perform fn_programacao_conferir_aceite(p_aceite, t.id, j, t.nome);
      v_lim := v_lim || jsonb_build_object(t.id::text, j);
    end if;
  end loop;

  for r in
    select * from fn_criar_escalas_lote(
      v_email, to_jsonb(p_tecnicos)::text, p_local::text, p_data::text,
      to_char(p_hora, 'HH24:MI'), p_tarefa, p_duracao::text,
      coalesce(p_prioridade, 'normal'), p_enviar::text)
  loop
    if r.escala_id is not null then
      update escalas set
        tipo_atividade_id = coalesce(p_tipo, tipo_atividade_id),
        teste = teste or coalesce(p_teste, false)
      where id = r.escala_id;
      -- Programação de teste não gera termo (pode ser removida a qualquer momento)
      if v_lim ? r.tecnico_id::text and not (select x.teste from escalas x where x.id = r.escala_id) then
        perform fn_programacao_registrar_aceite(r.escala_id, p_aceite, v_lim->(r.tecnico_id::text), v_email);
      end if;
    end if;
    tecnico_id := r.tecnico_id; tecnico := r.tecnico;
    escala_id := r.escala_id;   resultado := r.resultado;
    return next;
  end loop;
end $function$;

create or replace function public.app_editar_escala(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_conta   uuid := fn_conta_atual();
  e         escalas;
  v_data    date;
  v_hora    time;
  v_local   uuid;
  v_tarefa  text;
  v_mudou   boolean;
  v_reconf  boolean;
  v_tec     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
  v_lim     jsonb;
begin
  select * into e from escalas where id = (p->>'id')::uuid and conta_id = v_conta for update;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar programação em rascunho, agendada, aguardando resposta ou confirmada.';
  end if;
  perform fn_edicao_permitida(e.id);

  v_data   := coalesce(nullif(p->>'data_servico', '')::date, e.data_servico);
  v_hora   := coalesce(nullif(p->>'hora_inicio', '')::time, e.hora_inicio);
  v_local  := case when p ? 'local_id' then nullif(p->>'local_id', '')::uuid else e.local_id end;
  v_tarefa := coalesce(nullif(trim(p->>'descricao_tarefa'), ''), e.descricao_tarefa);
  v_mudou  := v_data <> e.data_servico or v_hora <> e.hora_inicio or v_local is distinct from e.local_id;
  if v_local is distinct from e.local_id and v_local is not null
     and not exists (select 1 from locais where id = v_local and conta_id = v_conta) then
    raise exception 'Local não encontrado.';
  end if;

  if not v_mudou and v_tarefa = e.descricao_tarefa then
    return jsonb_build_object('alterada', false);
  end if;
  if v_data <> e.data_servico or v_hora <> e.hora_inicio then
    perform fn_validar_inicio(v_data, v_hora);
    -- limite de 2 h extras no novo dia (decisão 90)
    perform pg_advisory_xact_lock(hashtext(e.tecnico_id::text || v_data::text));
    v_lim := fn_programacao_limite(e.tecnico_id, v_data, v_hora, e.id);
    if (v_lim->>'excedente_min')::int > 0 then
      perform fn_programacao_conferir_aceite(p->'aceite', e.tecnico_id, v_lim, (select nome from tecnicos where id = e.tecnico_id));
      if e.teste then v_lim := null; end if;  -- teste não gera termo
    else
      v_lim := null;
    end if;
  end if;

  -- decisao do responsavel (27/09): so data, hora ou local pedem nova confirmacao
  v_reconf := v_mudou and e.status in ('notificada', 'confirmada');
  perform set_config('app.ator', v_email, true);
  begin
    update escalas
       set data_servico = v_data, hora_inicio = v_hora, local_id = v_local, descricao_tarefa = v_tarefa,
           status = case when v_reconf then 'notificada'::escala_status else status end,
           confirmada_em = case when v_reconf then null else confirmada_em end,
           supervisor_avisado_em = case when v_mudou then null else supervisor_avisado_em end
     where id = e.id;
  exception when unique_violation then
    raise exception 'O técnico já tem outra programação ativa nesse dia e horário.';
  end;
  if v_lim is not null then
    perform fn_programacao_registrar_aceite(e.id, p->'aceite', v_lim, v_email);
  end if;

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (e.id, 'escala_editada', v_email, jsonb_build_object(
    'antes', jsonb_build_object('data', e.data_servico, 'hora', e.hora_inicio, 'local_id', e.local_id, 'tarefa', e.descricao_tarefa),
    'depois', jsonb_build_object('data', v_data, 'hora', v_hora, 'local_id', v_local, 'tarefa', v_tarefa),
    'nova_confirmacao', v_reconf));

  -- aviso ao tecnico quando a escala ja tinha saido
  if e.status in ('notificada', 'confirmada') and not e.teste then
    select telefone_e164, ativo, opt_in into v_tec from tecnicos where id = e.tecnico_id;
    if v_tec.ativo and v_tec.opt_in then
      if v_reconf then
        perform fn_wa_texto(v_tec.telefone_e164,
          '⚠️ *PROGRAMAÇÃO ALTERADA*' || E'\n\n' || 'Sua programação mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, v_tent,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua programação de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
          || ' foi atualizada: ' || left(v_tarefa, 500));
      end if;
    end if;
  end if;

  return jsonb_build_object('alterada', true, 'nova_confirmacao', v_reconf);
end $function$;

create or replace function public.app_escala_edicao(p_escala uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor']);
  return (select jsonb_build_object('id', id, 'tecnico_id', tecnico_id, 'data_servico', data_servico,
            'hora_inicio', to_char(hora_inicio, 'HH24:MI'), 'local_id', local_id,
            'descricao_tarefa', descricao_tarefa, 'status', status)
          from escalas where id = p_escala and conta_id = fn_conta_atual());
end $function$;

create or replace function public.app_escalas(p_inicio date, p_fim date)
 returns setof interno.vw_escalas_painel
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select v.* from vw_escalas_painel v
    where v.data_servico between p_inicio and p_fim
      and exists (select 1 from escalas e where e.id = v.id and e.conta_id = fn_conta_atual())
    order by v.data_servico, v.hora_inicio;
end $function$;

create or replace function public.app_indicadores_resposta(p_dias integer default 30)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_desde date := (now() at time zone fn_config('fuso'))::date - greatest(coalesce(p_dias, 30), 1);
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  return jsonb_build_object(
    'dias', greatest(coalesce(p_dias, 30), 1),
    'recusas', coalesce((
      select jsonb_agg(jsonb_build_object('motivo', m, 'rotulo', fn_motivo_rotulo(m), 'total', n) order by n desc)
      from (select coalesce(o.motivo::text, 'nao_informado') m, count(*) n
              from escalas e
              left join lateral (select motivo from ocorrencias where escala_id = e.id
                                  order by created_at desc limit 1) o on true
             where e.status = 'recusada' and not e.teste and e.data_servico >= v_desde and e.conta_id = v_conta
             group by 1) x), '[]'::jsonb),
    'respostas', (select count(*) from escalas e
                   where e.confirmada_em is not null and not e.teste and e.data_servico >= v_desde and e.conta_id = v_conta),
    'mediana_resposta_min', (
      select round((percentile_cont(0.5) within group (order by extract(epoch from e.confirmada_em - n.primeira) / 60))::numeric, 0)
        from escalas e
        join lateral (select min(enviada_em) primeira from notificacoes
                       where escala_id = e.id and enviada_em is not null) n on n.primeira is not null
       where e.confirmada_em is not null and not e.teste and e.data_servico >= v_desde
         and e.confirmada_em >= n.primeira and e.conta_id = v_conta));
end $function$;

create or replace function public.app_ligacoes(p_escala uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if not exists (select 1 from escalas where id = p_escala and conta_id = fn_conta_atual()) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'tentativa', tentativa, 'status', status, 'digito', digito,
    'duracao_seg', duracao_seg, 'criada_em', criada_em, 'erro', erro) order by criada_em)
    from ligacoes where escala_id = p_escala), '[]'::jsonb);
end $function$;

create or replace function public.app_ligar_escala(p_escala uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin','gestor']); v_req bigint; v_lig jsonb;
begin
  if not exists (select 1 from escalas where id = p_escala and conta_id = fn_conta_atual()) then
    raise exception 'Programação não encontrada.';
  end if;
  v_lig := fn_preparar_ligacao(p_escala);
  v_req := net.http_post(url := fn_config('voz_url') || '?acao=iniciar&token=' || fn_segredo('VOZ_TOKEN'),
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('ligacao_id', v_lig->>'ligacao_id'));
  insert into escala_eventos (escala_id, evento, ator) values (p_escala, 'ligacao_manual', v_email);
  return jsonb_build_object('ligacao_id', v_lig->>'ligacao_id', 'enfileirada', true);
end $function$;

create or replace function public.app_linha_do_tempo(p_escala uuid)
 returns setof interno.vw_linha_do_tempo
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if not exists (select 1 from escalas where id = p_escala and conta_id = fn_conta_atual()) then
    return;
  end if;
  return query
    select * from vw_linha_do_tempo where escala_id = p_escala order by created_at desc;
end $function$;

create or replace function public.app_mudar_status(p_escala uuid, p_status text)
 returns text
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if not exists (select 1 from escalas where id = p_escala and conta_id = fn_conta_atual()) then
    raise exception 'Programação não encontrada.';
  end if;
  return fn_mudar_status(v_email, p_escala::text, p_status);
end $function$;

create or replace function public.app_painel_gerencial(p_de date, p_ate date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ontem   date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_jornada int  := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_sabado  int  := coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240);
  v_abona   boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_tol     int  := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
  v_conta   uuid;
  v_escala  jsonb;
  v_ponto   jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 62 then
    raise exception 'Período de até 62 dias.';
  end if;

  -- Escala: só escalas que de fato foram enviadas (com notificação), fora as de teste ----------------
  with esc as (
    select e.id, e.status, e.confirmada_em,
           exists (select 1 from respostas r where r.escala_id = e.id and r.wa_message_id is not null
                     and r.tipo in ('confirmacao', 'problema')) as pelo_whatsapp,
           exists (select 1 from respostas r where r.escala_id = e.id and r.wa_message_id is null
                     and r.tipo in ('confirmacao', 'problema')) as pela_ura,
           exists (select 1 from ligacoes l where l.escala_id = e.id) as ligou,
           (select min(n.enviada_em) from notificacoes n where n.escala_id = e.id and n.enviada_em is not null) as primeira
      from escalas e
     where not e.teste and e.data_servico between p_de and p_ate and e.conta_id = v_conta
       and exists (select 1 from notificacoes n where n.escala_id = e.id)
  )
  select jsonb_build_object(
    'enviadas', count(*),
    'respondidas_whatsapp', count(*) filter (where pelo_whatsapp),
    'respondidas_ura', count(*) filter (where pela_ura and not pelo_whatsapp),
    'sem_resposta', count(*) filter (where not pelo_whatsapp and not pela_ura),
    'precisaram_ura', count(*) filter (where ligou),
    'confirmadas', count(*) filter (where status in ('confirmada', 'em_execucao', 'concluida')),
    'recusadas', count(*) filter (where status = 'recusada'),
    'mediana_resposta_min', (select round((percentile_cont(0.5) within group
                               (order by extract(epoch from x.confirmada_em - x.primeira) / 60))::numeric, 0)
                               from esc x where x.confirmada_em is not null and x.primeira is not null
                                and x.confirmada_em >= x.primeira),
    'ligacoes', (select count(*) from ligacoes l join escalas e on e.id = l.escala_id
                  where not e.teste and e.data_servico between p_de and p_ate and e.conta_id = v_conta),
    'ligacoes_atendidas', (select count(*) from ligacoes l join escalas e on e.id = l.escala_id
                            where not e.teste and e.data_servico between p_de and p_ate and l.atendida_em is not null
                              and e.conta_id = v_conta))
    into v_escala
    from esc;

  -- Ponto: funcionários do ponto (CPF e empresa), cada um só entre a admissão (ou o cadastro) e o
  -- desligamento, dia a dia até ontem. Quem saiu no período entra até o desligamento
  with t as (
    select id, greatest(p_de, coalesce(admissao, created_at::date)) as ini,
           least(p_ate, v_ontem, coalesce(desligado_em, p_ate)) as fim
      from tecnicos
     where not perfil_teste and cpf is not null and empresa_id is not null
       and (ativo or desligado_em >= p_de) and conta_id = v_conta
  ), jd as (
    select t.id as tec, g::date as dia, fn_ponto_jornada_dia(t.id, g::date) as j, fn_carga_dia(t.id, g::date) as c
      from t cross join lateral generate_series(t.ini, t.fim, interval '1 day') g
     where t.ini <= t.fim
  ), base as (
    select tec, dia, j,
           coalesce((j->>'trabalhado_min')::int, 0) as trab,
           coalesce((j->>'abonado_min')::int, 0) as abon,
           coalesce((j->>'marcacoes')::int, 0) as marc,
           c->>'tipo' = '12x36' as plantonista,
           exists (select 1 from feriados f where f.data = dia and f.abrangencia <> 'facultativo') as feriado,
           coalesce((c->>'minutos')::int, 0) as contr
      from jd
  ), base2 as (
    -- jornada do dia pela escala (decisão 91): feriado zera, salvo na 12x36 (plantão no feriado é dia normal);
    -- folga e DSR já vêm com 0 da escala
    select *, case when feriado and not plantonista then 0 else contr end as bruto
      from base
  ), dia as (
    -- esperado: feriado não é devido; sábado sem expediente (nem marcação, nem escala, nem abono) é abonado pela
    -- decisão interna; sábado com escala e sem marcação continua devido
    select *, case when feriado then 0
                   when extract(isodow from dia) = 6 and j is null and v_abona then 0
                   else bruto end as esperado
      from base2
  ), semana as (
    -- só semanas inteiras (segunda a domingo) dentro do período e já fechadas
    select tec, date_trunc('week', dia)::date as ini, sum(trab) as trab, sum(greatest(esperado - abon, 0)) as esp,
           count(*) filter (where esperado > 0) as dias_uteis, bool_or(plantonista) as plantonista
      from dia
     group by 1, 2
    having min(dia) = date_trunc('week', min(dia))::date and max(dia) = date_trunc('week', min(dia))::date + 6
  )
  select jsonb_build_object(
    'funcionarios', (select count(*) from t where ini <= fim),
    'dias_apurados', greatest(least(p_ate, v_ontem) - p_de + 1, 0),
    'dias_trabalhados', (select count(*) from dia where trab > 0),
    'marcacoes', (select coalesce(sum(marc), 0) from dia),
    'ajustes', (select coalesce(sum((j->>'ajustes')::int), 0) from dia where j is not null),
    'dias_abonados', (select count(*) from dia where j->>'abono' is not null),
    'minutos_abonados', (select coalesce(sum(abon), 0) from dia),
    -- hora extra: o que passa da jornada do próprio dia na escala (folga, DSR e feriado, tudo; 12x36, acima do plantão)
    'minutos_hora_extra', (select coalesce(sum(greatest(trab - bruto, 0)), 0) from dia),
    -- saldo: trabalhado menos o esperado (abonos descontados); negativo é hora faltando
    'saldo_min', (select coalesce(sum(trab), 0) - coalesce(sum(greatest(esperado - abon, 0)), 0) from dia),
    'alertas', coalesce((select jsonb_object_agg(a, n) from (
                  select a, count(*) as n from dia, jsonb_array_elements_text(coalesce(j->'alertas', '[]'::jsonb)) a
                   group by a) x), '{}'::jsonb),
    'semanas', (select count(*) from semana),
    'semanas_acima_44h', (select count(*) from semana where trab > 44 * 60 and not plantonista),
    'semanas_abaixo_esperado', (select count(*) from semana where trab < esp - v_tol * dias_uteis),
    'jornada', jsonb_build_object('dia_util_min', v_jornada, 'sabado_min', v_sabado,
                                  'sabado_sem_expediente_abona', v_abona, 'semana_max_min', 44 * 60,
                                  'tolerancia_dia_min', v_tol, 'pela_escala', true,
                                  'escalas', (select count(distinct c->>'escala') from jd where c->>'escala' is not null)))
    into v_ponto;

  return jsonb_build_object('de', p_de, 'ate', p_ate, 'apurado_ate', least(p_ate, v_ontem),
                            'escala', v_escala, 'ponto', v_ponto);
end $function$;

create or replace function public.app_painel_locais(p_data date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return fn_painel_locais(p_data, fn_conta_atual());
end $function$;

create or replace function public.app_pendencias(p_data date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return fn_pendencias_escala(p_data, fn_conta_atual());
end $function$;

create or replace function public.app_programacao_aceites(p_de date, p_ate date)
 returns table(id uuid, data date, tecnico text, previsto_min integer, contratual_min integer, excedente_min integer, motivo text, justificativa text, nome text, aceito_em timestamp with time zone, texto text, sha256 text)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor']);
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select a.id, a.data, coalesce(t.nome, '(funcionário removido)'), a.previsto_min, a.contratual_min, a.excedente_min, fn_programacao_motivo(a.motivo),
           a.justificativa, a.nome, a.aceito_em, a.texto, a.sha256
      from programacao_aceites a left join tecnicos t on t.id = a.tecnico_id
     where a.data between p_de and p_ate and a.conta_id = fn_conta_atual()
     order by a.data desc, t.nome;
end $function$;

create or replace function public.app_programacao_limite(p_tecnicos uuid[], p_data date, p_hora time without time zone, p_ignorar uuid default null::uuid, p_motivo text default null::text, p_justificativa text default null::text)
 returns table(tecnico_id uuid, tecnico text, previsto_min integer, contratual_min integer, limite_min integer, excedente_min integer, termo text)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  t       record;
  j       jsonb;
begin
  for t in select x.id, x.nome from tecnicos x
            where x.id = any(coalesce(p_tecnicos, '{}')) and x.conta_id = v_conta order by x.nome loop
    j := fn_programacao_limite(t.id, p_data, p_hora, p_ignorar);
    tecnico_id := t.id; tecnico := t.nome;
    previsto_min := (j->>'previsto_min')::int; contratual_min := (j->>'contratual_min')::int;
    limite_min := (j->>'limite_min')::int; excedente_min := (j->>'excedente_min')::int;
    termo := case when excedente_min > 0 then fn_programacao_termo(t.id, p_data, j, v_email, p_motivo, p_justificativa) end;
    return next;
  end loop;
end $function$;

create or replace function public.app_reenviar_escala(p_escala uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_esc     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
begin
  select e.id, e.status, t.telefone_e164, t.ativo, t.opt_in
    into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.id = p_escala and e.conta_id = fn_conta_atual();

  if not found then raise exception 'Programação não encontrada.'; end if;
  if v_esc.status not in ('agendada', 'notificada') then
    raise exception 'Só é possível reenviar programações agendadas ou aguardando resposta.';
  end if;
  if not v_esc.ativo or not v_esc.opt_in then
    raise exception 'O técnico está inativo ou sem autorização para mensagens.';
  end if;
  if exists (select 1 from notificacoes where escala_id = p_escala and status_envio = 'enfileirada') then
    raise exception 'Já existe um envio em andamento para esta programação. Aguarde um minuto.';
  end if;

  select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = p_escala;
  v_payload := fn_payload_escala(p_escala, v_esc.telefone_e164, v_tent > 1, v_botoes);
  v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');

  insert into notificacoes
    (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
  values
    (p_escala, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo,
     v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
     'enfileirada', v_payload, now(), v_req);

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'reenvio_manual', v_email, jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('reenviada', true, 'tentativa', v_tent);
end $function$;

create or replace function public.app_remover_escala(p_escala uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if not exists (select 1 from escalas where id = p_escala and conta_id = fn_conta_atual()) then
    raise exception 'Programação não encontrada.';
  end if;
  return fn_remover_escala(v_email, p_escala::text);
end $function$;

create or replace function public.app_resumo(p_inicio date, p_fim date)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select jsonb_build_object(
    'total', count(*),
    'confirmadas', count(*) filter (where e.status = 'confirmada'),
    'recusadas', count(*) filter (where e.status = 'recusada'),
    'aguardando', count(*) filter (where e.status = 'notificada'),
    'nao_enviadas', count(*) filter (where e.status = 'agendada'),
    'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
    'pct_confirmacao', coalesce(round(100.0 * count(*) filter (where e.status = 'confirmada')
                        / nullif(count(*) filter (where e.status <> 'rascunho'), 0)), 0)
  ) into v
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.data_servico between p_inicio and p_fim
    and e.status <> 'cancelada' and not e.teste
    and not t.perfil_teste and not t.is_supervisor and e.conta_id = fn_conta_atual();
  return v;
end $function$;

create or replace function public.app_substituir_tecnico(p_escala uuid, p_tecnico uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  e       escalas;
  v_novo  uuid;
  v_lim   jsonb;
begin
  select * into e from escalas where id = p_escala and conta_id = v_conta;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = v_conta) then
    raise exception 'Técnico não encontrado.';
  end if;
  if e.status <> 'recusada' then raise exception 'Só dá para substituir o técnico de uma programação recusada.'; end if;
  if p_tecnico = e.tecnico_id then raise exception 'Escolha outro técnico.'; end if;
  v_lim := fn_programacao_limite(p_tecnico, e.data_servico, e.hora_inicio, null);
  if (v_lim->>'excedente_min')::int > 0 then
    raise exception 'Esse técnico passaria do limite de 2 horas extras no dia (previsto %, limite %). Crie pela Nova Programação, com o aceite da empresa.',
      fn_ponto_hm((v_lim->>'previsto_min')::int), fn_ponto_hm((v_lim->>'limite_min')::int);
  end if;
  begin
    v_novo := fn_criar_escala(v_email, p_tecnico::text, coalesce(e.local_id::text, ''), e.data_servico::text,
                              e.hora_inicio::text, e.descricao_tarefa, e.duracao_prevista_min::text, e.prioridade, 'true');
  exception when unique_violation then
    raise exception 'Esse técnico já tem programação nesse dia e horário.';
  end;
  update escalas set tipo_atividade_id = e.tipo_atividade_id where id = v_novo;
  insert into escala_eventos (escala_id, evento, ator, detalhe) values
    (e.id, 'substituida', v_email, jsonb_build_object('nova_escala', v_novo, 'tecnico_id', p_tecnico)),
    (v_novo, 'substitui', v_email, jsonb_build_object('escala_anterior', e.id));
  return jsonb_build_object('escala', v_novo);
end $function$;

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
