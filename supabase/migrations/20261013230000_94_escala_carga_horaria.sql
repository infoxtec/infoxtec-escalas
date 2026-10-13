-- Migration 94 (13/10/2026): Escala / Carga Horária e Times, etapa 1 (backlog 104, decisão 88).
-- A escala (carga horária contratual) pertence à empregadora e só se aplica a funcionário dela. Ela é atribuída à
-- empresa, a um time ou a um funcionário, com vigência (padrão: um ano); vale a mais específica (funcionário > time
-- > empresa). Sem escala, vale a jornada padrão (jornada_min de segunda a sexta, ponto_jornada_sabado_min no sábado).
-- A validação segue a Constituição e a CLT (parecer do jurídico, decisão 58): o ilegal é bloqueado; o que depende de
-- acordo ou norma coletiva só é salvo com o aceite de risco assinado no sistema por admin ou gestor (imutável).
-- O campo "equipe" do funcionário vira time: cada nome de equipe, por empresa, é um time.
-- Etapa 1 só cadastra e atribui: espelho, débito e hora extra continuam na jornada padrão até a etapa 2. O limite de
-- hora extra (backlog 105) usa fn_carga_minutos_dia. Também: rodapé do WhatsApp passa a "Trilha".

-- Times --------------------------------------------------------------------------------------------------
create table if not exists times (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references empresas(id),
  nome        text not null check (length(trim(nome)) between 1 and 60),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);
comment on table times is 'Time de funcionários de uma empresa (decisão 88). Vem do campo equipe do funcionário.';
alter table times enable row level security;
create unique index if not exists times_empresa_nome_uq on times (empresa_id, lower(trim(nome)));

alter table tecnicos add column if not exists time_id uuid references times(id);
create index if not exists tecnicos_time_idx on tecnicos (time_id);
comment on column tecnicos.time_id is 'Time do funcionário, resolvido pelo nome da equipe dentro da empresa (gatilho fn_tecnico_time).';

-- equipe → time: acha ou cria o time com esse nome na empresa do funcionário
create or replace function fn_tecnico_time()
returns trigger language plpgsql set search_path = public, extensions as $function$
declare
  v_nome text := nullif(trim(new.equipe), '');
  v_id   uuid;
begin
  if v_nome is null or new.empresa_id is null then
    new.time_id := null;
    return new;
  end if;
  new.equipe := v_nome;
  select id into v_id from times where empresa_id = new.empresa_id and lower(trim(nome)) = lower(v_nome);
  if v_id is null then
    insert into times (empresa_id, nome) values (new.empresa_id, v_nome) returning id into v_id;
  end if;
  new.time_id := v_id;
  return new;
end $function$;

create or replace trigger trg_tecnico_time before insert or update of equipe, empresa_id on tecnicos
  for each row execute function fn_tecnico_time();

-- times a partir das equipes que já existem
insert into times (empresa_id, nome)
select distinct on (t.empresa_id, lower(trim(t.equipe))) t.empresa_id, trim(t.equipe)
  from tecnicos t
 where nullif(trim(t.equipe), '') is not null and t.empresa_id is not null
on conflict do nothing;
update tecnicos t set time_id = x.id
  from times x
 where x.empresa_id = t.empresa_id and lower(trim(x.nome)) = lower(trim(t.equipe));

-- Escalas (carga horária contratual) -----------------------------------------------------------------------
create table if not exists cargas_horarias (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null references empresas(id),
  nome           text not null check (length(trim(nome)) between 1 and 80),
  tipo           text not null check (tipo in ('semanal', 'revezamento', '12x36')),
  minutos        int[],            -- semanal e revezamento: 7 dias, segunda a domingo
  plantao_min    int,              -- 12x36: duração do plantão
  intervalo_min  int not null,
  entrada        time,             -- opcional: hora de entrada, para o aviso de trabalho noturno
  semanal_min    int not null,     -- 12x36: média semanal
  riscos         jsonb not null default '[]',
  ativo          boolean not null default true,
  criado_por     text not null,
  created_at     timestamptz not null default now(),
  check ((tipo = '12x36' and plantao_min is not null and minutos is null)
      or (tipo <> '12x36' and plantao_min is null and array_length(minutos, 1) = 7))
);
comment on table cargas_horarias is 'Escala (carga horária contratual) da empregadora (decisão 88). Não muda depois de salva, só ativa ou inativa.';
alter table cargas_horarias enable row level security;
create unique index if not exists cargas_horarias_nome_uq on cargas_horarias (empresa_id, lower(trim(nome)));

create or replace function fn_carga_imutavel()
returns trigger language plpgsql set search_path = public, extensions as $function$
begin
  if tg_op = 'DELETE' or (to_jsonb(new) - 'ativo') <> (to_jsonb(old) - 'ativo') then
    raise exception 'Escala salva não muda: crie outra e atribua no lugar desta.';
  end if;
  return new;
end $function$;
create or replace trigger trg_cargas_horarias_imutavel before update or delete on cargas_horarias
  for each row execute function fn_carga_imutavel();
create or replace trigger trg_cargas_horarias_sem_truncate before truncate on cargas_horarias
  for each statement execute function fn_ponto_imutavel();

-- Aceite de risco: quem assinou, o texto exato e o hash. Só inclusão.
create table if not exists carga_aceites (
  id           uuid primary key default gen_random_uuid(),
  carga_id     uuid not null unique references cargas_horarias(id),
  empresa_id   uuid not null references empresas(id),
  riscos       jsonb not null,
  instrumento  text,
  texto        text not null,
  sha256       text not null,
  nome         text not null,
  email        text not null,
  papel        text not null,
  aceito_em    timestamptz not null default now()
);
comment on table carga_aceites is 'Aceite de risco da escala, assinado no sistema por admin ou gestor (decisão 88). Não supre acordo ou norma coletiva. Só inclusão.';
alter table carga_aceites enable row level security;
create or replace trigger trg_carga_aceites_imutavel before update or delete on carga_aceites
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_carga_aceites_sem_truncate before truncate on carga_aceites
  for each statement execute function fn_ponto_imutavel();

-- Atribuição: escala → empresa, time ou funcionário, com vigência
create table if not exists carga_atribuicoes (
  id            uuid primary key default gen_random_uuid(),
  carga_id      uuid not null references cargas_horarias(id),
  empresa_id    uuid not null references empresas(id),
  alvo          text not null check (alvo in ('empresa', 'time', 'tecnico')),
  time_id       uuid references times(id),
  tecnico_id    uuid references tecnicos(id),
  inicio        date not null,
  fim           date not null,
  criado_por    text not null,
  created_at    timestamptz not null default now(),
  cancelada_em  timestamptz,
  cancelada_por text,
  check (fim >= inicio),
  check ((alvo = 'empresa' and time_id is null and tecnico_id is null)
      or (alvo = 'time' and time_id is not null and tecnico_id is null)
      or (alvo = 'tecnico' and tecnico_id is not null and time_id is null))
);
comment on table carga_atribuicoes is 'Qual escala vale para a empresa, o time ou o funcionário, e de quando a quando (decisão 88). Vale a mais específica.';
alter table carga_atribuicoes enable row level security;
create index if not exists carga_atribuicoes_empresa_idx on carga_atribuicoes (empresa_id, inicio);
create index if not exists carga_atribuicoes_time_idx on carga_atribuicoes (time_id) where time_id is not null;
create index if not exists carga_atribuicoes_tecnico_idx on carga_atribuicoes (tecnico_id) where tecnico_id is not null;

-- Validação (CF art. 7º; CLT arts. 58, 59, 59-A, 66, 67, 71, 73; Lei 605/49; Súmula 423 do TST) ----------------
-- p: {tipo, minutos[7] (seg..dom), plantao_min, intervalo_min, entrada 'HH:MI'}
-- Devolve {semanal_min, bloqueios[], riscos[], avisos[]}; cada item {codigo, texto}. Bloqueio não salva; risco só
-- salva com aceite; aviso é só informação.
create or replace function fn_carga_validar(p jsonb)
returns jsonb language plpgsql immutable set search_path = public, extensions as $function$
declare
  v_tipo  text := coalesce(p->>'tipo', 'semanal');
  v_int   int  := coalesce((p->>'intervalo_min')::int, 0);
  v_ent   int;
  v_min   int[];
  v_pl    int;
  v_sem   int := 0;
  v_max   int := 0;
  v_zero  boolean := false;
  v_span  int;
  d       int;
  b jsonb := '[]'; r jsonb := '[]'; a jsonb := '[]';
begin
  if nullif(p->>'entrada', '') is not null then
    v_ent := extract(hour from (p->>'entrada')::time)::int * 60 + extract(minute from (p->>'entrada')::time)::int;
  end if;
  if v_int < 0 or v_int > 300 then
    b := b || jsonb_build_object('codigo', 'intervalo_invalido', 'texto', 'Intervalo entre 0 e 300 minutos.');
  end if;

  if v_tipo = '12x36' then
    v_pl := coalesce((p->>'plantao_min')::int, 0);
    v_sem := round(v_pl * 3.5)::int;  -- média: 7 dias, plantão em dia sim, dia não
    if v_pl <= 0 then
      b := b || jsonb_build_object('codigo', 'plantao_invalido', 'texto', 'Informe a duração do plantão.');
    elsif v_pl > 720 then
      b := b || jsonb_build_object('codigo', '12x36_acima_12h', 'texto',
        'Plantão acima de 12 horas na 12x36 (CLT art. 59-A).');
    end if;
    r := r || jsonb_build_object('codigo', '12x36', 'texto',
      'A 12x36 exige acordo individual escrito, convenção ou acordo coletivo (CLT art. 59-A).');
    if v_pl > 360 and v_int < 30 then
      b := b || jsonb_build_object('codigo', 'intervalo_menor_30', 'texto',
        'Mais de 6 horas com intervalo menor que 30 minutos (CLT art. 71 e art. 611-A, III).');
    end if;
    if v_ent is not null and (v_ent < 300 or v_ent + v_pl > 1320) then
      a := a || jsonb_build_object('codigo', 'noturno', 'texto',
        'Trabalho entre 22h e 5h tem hora reduzida (52min30s) e adicional de 20% (CLT art. 73).');
    end if;
    return jsonb_build_object('semanal_min', v_sem, 'bloqueios', b, 'riscos', r, 'avisos', a);
  end if;

  if v_tipo not in ('semanal', 'revezamento') then
    raise exception 'Tipo de escala inválido.';
  end if;
  select array_agg(x::int order by o) into v_min from jsonb_array_elements_text(p->'minutos') with ordinality as t(x, o);
  if coalesce(array_length(v_min, 1), 0) <> 7 then
    return jsonb_build_object('semanal_min', 0, 'riscos', r, 'avisos', a,
      'bloqueios', b || jsonb_build_object('codigo', 'dias_invalidos', 'texto', 'Informe os minutos dos 7 dias, de segunda a domingo.'));
  end if;
  foreach d in array v_min loop
    if d is null or d < 0 or d > 1440 then
      return jsonb_build_object('semanal_min', 0, 'riscos', r, 'avisos', a,
        'bloqueios', b || jsonb_build_object('codigo', 'dias_invalidos', 'texto', 'Minutos do dia entre 0 e 1440.'));
    end if;
    v_sem := v_sem + d;
    v_max := greatest(v_max, d);
    if d = 0 then v_zero := true; end if;
  end loop;

  if v_sem > 2640 then
    b := b || jsonb_build_object('codigo', 'semana_acima_44h', 'texto',
      'Soma da semana acima de 44 horas (Constituição, art. 7º, XIII).');
  end if;
  if not v_zero then
    b := b || jsonb_build_object('codigo', 'sem_dsr', 'texto',
      'Nenhuma folga na semana: o repouso de 24 horas a cada 7 dias é obrigatório (Constituição, art. 7º, XV; Lei 605/49; CLT art. 67).');
  end if;
  if v_max > 600 then
    b := b || jsonb_build_object('codigo', 'dia_acima_10h', 'texto',
      'Dia acima de 10 horas, fora da 12x36 (CLT art. 59).');
  end if;
  if v_max > 360 and v_int < 30 then
    b := b || jsonb_build_object('codigo', 'intervalo_menor_30', 'texto',
      'Mais de 6 horas com intervalo menor que 30 minutos (CLT art. 71 e art. 611-A, III).');
  elsif exists (select 1 from unnest(v_min) x where x > 240 and x <= 360) and v_int < 15 then
    b := b || jsonb_build_object('codigo', 'intervalo_menor_15', 'texto',
      'Mais de 4 horas sem 15 minutos de intervalo (CLT art. 71, § 1º).');
  end if;
  v_span := v_max + case when v_max > 240 then v_int else 0 end;
  if v_max > 0 and 1440 - v_span < 660 then
    b := b || jsonb_build_object('codigo', 'interjornada_menor_11h', 'texto',
      'Menos de 11 horas de descanso entre um dia e o seguinte (CLT art. 66).');
  end if;
  if v_tipo = 'revezamento' and v_max > 480 then
    b := b || jsonb_build_object('codigo', 'turno_acima_8h', 'texto',
      'Turno ininterrupto de revezamento acima de 8 horas (Constituição, art. 7º, XIV; Súmula 423 do TST).');
  end if;

  if v_tipo = 'revezamento' and v_max > 360 and v_max <= 480 then
    r := r || jsonb_build_object('codigo', 'turno_6_a_8h', 'texto',
      'Turno ininterrupto acima de 6 horas só vale com convenção ou acordo coletivo, até 8 horas (Constituição, art. 7º, XIV; Súmula 423 do TST).');
  end if;
  if v_max > 480 and v_max <= 600 then
    r := r || jsonb_build_object('codigo', 'dia_acima_8h', 'texto',
      'Dia acima de 8 horas exige acordo de compensação, de preferência escrito; sem acordo válido, o excedente pode ser cobrado como hora extra (CLT art. 59, § 2º e § 6º; Súmula 85 do TST).');
  end if;
  if v_max > 360 and v_int between 30 and 59 then
    r := r || jsonb_build_object('codigo', 'intervalo_30_59', 'texto',
      'Intervalo menor que 1 hora só vale com convenção ou acordo coletivo; acordo individual não basta. Sem a norma coletiva, o tempo suprimido é pago com acréscimo de 50% (CLT art. 611-A, III, e art. 71, § 4º).');
  end if;
  if v_max > 360 and v_int > 120 then
    r := r || jsonb_build_object('codigo', 'intervalo_acima_2h', 'texto',
      'Intervalo acima de 2 horas exige acordo escrito ou norma coletiva (CLT art. 71).');
  end if;
  if v_min[7] > 0 then
    r := r || jsonb_build_object('codigo', 'folga_fora_domingo', 'texto',
      'O repouso deve ser preferencialmente aos domingos; folga em outro dia exige escala de revezamento e autorização para trabalho aos domingos. No comércio, a folga cai no domingo ao menos 1 vez a cada 3 semanas (Lei 605/49; CLT art. 67; Lei 10.101/2000, art. 6º).');
  end if;
  if v_ent is not null and (v_ent < 300 or v_ent + v_span > 1320) then
    a := a || jsonb_build_object('codigo', 'noturno', 'texto',
      'Trabalho entre 22h e 5h tem hora reduzida (52min30s) e adicional de 20% (CLT art. 73).');
  end if;
  return jsonb_build_object('semanal_min', v_sem, 'bloqueios', b, 'riscos', r, 'avisos', a);
end $function$;

-- Escala vigente do funcionário num dia: funcionário > time > empresa (null: jornada padrão)
create or replace function fn_carga_atribuicao(p_tecnico uuid, p_data date)
returns uuid language sql stable set search_path = public, extensions as $function$
  select a.id
    from carga_atribuicoes a join tecnicos t on t.id = p_tecnico
   where a.cancelada_em is null and p_data between a.inicio and a.fim
     and a.empresa_id = t.empresa_id
     and ((a.alvo = 'tecnico' and a.tecnico_id = t.id)
       or (a.alvo = 'time' and a.time_id = t.time_id)
       or a.alvo = 'empresa')
   order by case a.alvo when 'tecnico' then 1 when 'time' then 2 else 3 end, a.inicio desc
   limit 1
$function$;

-- Minutos contratuais do funcionário num dia (base do limite de hora extra, backlog 105)
create or replace function fn_carga_minutos_dia(p_tecnico uuid, p_data date)
returns int language plpgsql stable set search_path = public, extensions as $function$
declare
  v_at  uuid := fn_carga_atribuicao(p_tecnico, p_data);
  v_c   cargas_horarias;
  v_ini date;
  v_dow int := extract(isodow from p_data)::int;
begin
  if v_at is null then
    return case when v_dow <= 5 then coalesce(nullif(fn_config('jornada_min'), '')::int, 480)
                when v_dow = 6 then coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240)
                else 0 end;
  end if;
  select c.* into v_c from carga_atribuicoes a join cargas_horarias c on c.id = a.carga_id where a.id = v_at;
  select a.inicio into v_ini from carga_atribuicoes a where a.id = v_at;
  if v_c.tipo = '12x36' then
    -- o primeiro dia da vigência é dia de plantão; depois, dia sim, dia não
    return case when (p_data - v_ini) % 2 = 0 then v_c.plantao_min else 0 end;
  end if;
  return v_c.minutos[v_dow];
end $function$;

-- API do painel -------------------------------------------------------------------------------------------
create or replace function app_cargas_modelos()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return jsonb_build_array(
    jsonb_build_object('nome', '44h 6x1 (8h + 4h sábado)', 'tipo', 'semanal', 'minutos', jsonb_build_array(480,480,480,480,480,240,0), 'intervalo_min', 60),
    jsonb_build_object('nome', '44h 6x1 (7h20)', 'tipo', 'semanal', 'minutos', jsonb_build_array(440,440,440,440,440,440,0), 'intervalo_min', 60),
    jsonb_build_object('nome', '44h 5x2 (8h48)', 'tipo', 'semanal', 'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 60),
    jsonb_build_object('nome', '40h 5x2 (8h)', 'tipo', 'semanal', 'minutos', jsonb_build_array(480,480,480,480,480,0,0), 'intervalo_min', 60),
    jsonb_build_object('nome', '36h 6x1 (6h)', 'tipo', 'semanal', 'minutos', jsonb_build_array(360,360,360,360,360,360,0), 'intervalo_min', 15),
    jsonb_build_object('nome', '12x36', 'tipo', '12x36', 'plantao_min', 720, 'intervalo_min', 60),
    jsonb_build_object('nome', 'Turno de revezamento 6h', 'tipo', 'revezamento', 'minutos', jsonb_build_array(360,360,360,360,360,360,0), 'intervalo_min', 15));
end $function$;

create or replace function app_carga_validar(p jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor']);
  return fn_carga_validar(p);
end $function$;

-- Salva a escala. Bloqueio não salva; risco só com o aceite (p_aceite: {aceito: true, instrumento: '...'}).
create or replace function app_salvar_carga(p jsonb, p_aceite jsonb default null)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_emp   uuid := (p->>'empresa_id')::uuid;
  v_nome  text := nullif(trim(p->>'nome'), '');
  v_tipo  text := coalesce(p->>'tipo', 'semanal');
  v_val   jsonb := fn_carga_validar(p);
  v_id    uuid;
  v_emp_nome text;
  v_usu   painel_usuarios;
  v_instr text := nullif(trim(p_aceite->>'instrumento'), '');
  v_resumo text;
  v_texto text;
  v_em    timestamptz := now();
begin
  select coalesce(nome_fantasia, razao_social) into v_emp_nome from empresas where id = v_emp and empregadora and ativo;
  if v_emp_nome is null then raise exception 'A escala pertence a uma empregadora ativa: escolha a empresa.'; end if;
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

  insert into cargas_horarias (empresa_id, nome, tipo, minutos, plantao_min, intervalo_min, entrada, semanal_min, riscos, criado_por)
  values (v_emp, v_nome, v_tipo,
          case when v_tipo = '12x36' then null else (select array_agg(x::int order by o) from jsonb_array_elements_text(p->'minutos') with ordinality t(x, o)) end,
          case when v_tipo = '12x36' then (p->>'plantao_min')::int end,
          coalesce((p->>'intervalo_min')::int, 0), nullif(p->>'entrada', '')::time,
          (v_val->>'semanal_min')::int, v_val->'riscos', v_email)
  returning id into v_id;

  if jsonb_array_length(v_val->'riscos') > 0 then
    select * into v_usu from painel_usuarios where email = v_email;
    v_resumo := case when v_tipo = '12x36' then '12x36, plantão de ' || fn_ponto_hm((p->>'plantao_min')::int)
                     else fn_ponto_hm((v_val->>'semanal_min')::int) || ' por semana' end
                || ', intervalo de ' || coalesce((p->>'intervalo_min')::int, 0) || ' min';
    v_texto := 'Eu, ' || coalesce(nullif(v_usu.nome, ''), v_email) || ', ' || v_usu.papel || ' da ' || v_emp_nome
      || ', declaro que revisei a escala ''' || v_nome || ''' (' || v_resumo || ') e fui informado pelo sistema dos seguintes pontos que dependem de acordo ou norma coletiva: '
      || (select string_agg(x->>'texto', ' ') from jsonb_array_elements(v_val->'riscos') x)
      || ' Declaro que ' || case when v_instr is not null then 'há o seguinte instrumento que os ampara: ' || v_instr || '.'
                                 else 'não há instrumento que os ampare e, ciente disso, decido aplicar a escala assumindo o risco em nome do empregador.' end
      || ' Sei que este aceite registra minha decisão e a informação recebida, mas não supre acordo ou norma coletiva, não afasta direitos do empregado nem elimina passivo trabalhista.'
      || ' Registrado em ' || to_char(v_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI') || '.';
    insert into carga_aceites (carga_id, empresa_id, riscos, instrumento, texto, sha256, nome, email, papel, aceito_em)
    values (v_id, v_emp, v_val->'riscos', v_instr, v_texto, encode(sha256(convert_to(v_texto, 'UTF8')), 'hex'),
            coalesce(nullif(v_usu.nome, ''), v_email), v_email, v_usu.papel, v_em);
  end if;
  return v_id;
end $function$;

create or replace function app_carga_ativar(p_id uuid, p_ativo boolean)
returns void language plpgsql volatile security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor']);
  if not p_ativo and exists (select 1 from carga_atribuicoes where carga_id = p_id and cancelada_em is null and fim >= current_date) then
    raise exception 'Esta escala está atribuída (agora ou no futuro). Atribua outra no lugar antes de inativar.';
  end if;
  update cargas_horarias set ativo = p_ativo where id = p_id;
  if not found then raise exception 'Escala não encontrada.'; end if;
end $function$;

create or replace function app_cargas(p_empresa uuid default null)
returns table (id uuid, empresa_id uuid, empresa text, nome text, tipo text, minutos int[], plantao_min int,
               intervalo_min int, entrada text, semanal_min int, riscos jsonb, ativo boolean, criado_por text,
               created_at timestamptz, atribuicoes bigint, aceite_nome text, aceite_em timestamptz,
               aceite_texto text, aceite_sha256 text)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select c.id, c.empresa_id, coalesce(m.nome_fantasia, m.razao_social), c.nome, c.tipo, c.minutos, c.plantao_min,
           c.intervalo_min, to_char(c.entrada, 'HH24:MI'), c.semanal_min, c.riscos, c.ativo, c.criado_por, c.created_at,
           (select count(*) from carga_atribuicoes a where a.carga_id = c.id and a.cancelada_em is null and a.fim >= current_date),
           k.nome, k.aceito_em, k.texto, k.sha256
      from cargas_horarias c join empresas m on m.id = c.empresa_id
      left join carga_aceites k on k.carga_id = c.id
     where p_empresa is null or c.empresa_id = p_empresa
     order by coalesce(m.nome_fantasia, m.razao_social), c.ativo desc, c.nome;
end $function$;

-- Atribui a escala. A vigência padrão é de um ano. A atribuição anterior do mesmo alvo termina na véspera.
create or replace function app_atribuir_carga(p_carga uuid, p_alvo text, p_alvo_id uuid, p_inicio date, p_fim date default null)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_c     cargas_horarias;
  v_emp   uuid;
  v_time  uuid;
  v_tec   uuid;
  v_fim   date := coalesce(p_fim, (p_inicio + interval '1 year' - interval '1 day')::date);
  v_id    uuid;
begin
  select * into v_c from cargas_horarias where id = p_carga;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_c.ativo then raise exception 'Escala inativa não pode ser atribuída.'; end if;
  if p_inicio is null or p_inicio < current_date then raise exception 'A vigência começa hoje ou depois.'; end if;
  if v_fim < p_inicio then raise exception 'O fim da vigência é depois do início.'; end if;

  if p_alvo = 'empresa' then
    v_emp := p_alvo_id;
  elsif p_alvo = 'time' then
    select empresa_id into v_emp from times where id = p_alvo_id and ativo;
    v_time := p_alvo_id;
  elsif p_alvo = 'tecnico' then
    select empresa_id into v_emp from tecnicos where id = p_alvo_id;
    v_tec := p_alvo_id;
  else
    raise exception 'Atribua a uma empresa, a um time ou a um funcionário.';
  end if;
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

-- Cancela uma atribuição que ainda não começou (a que já vale é substituída por outra atribuição)
create or replace function app_cancelar_atribuicao(p_id uuid)
returns void language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  update carga_atribuicoes set cancelada_em = now(), cancelada_por = v_email
   where id = p_id and cancelada_em is null and inicio > current_date;
  if not found then
    raise exception 'Só se cancela atribuição que ainda não começou. Para trocar a que já vale, atribua outra escala a partir de uma data.';
  end if;
end $function$;

create or replace function app_carga_atribuicoes(p_empresa uuid default null)
returns table (id uuid, carga_id uuid, carga text, empresa_id uuid, empresa text, alvo text, alvo_id uuid,
               alvo_nome text, inicio date, fim date, situacao text, criado_por text)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select a.id, a.carga_id, c.nome, a.empresa_id, coalesce(m.nome_fantasia, m.razao_social), a.alvo,
           coalesce(a.tecnico_id, a.time_id, a.empresa_id),
           case a.alvo when 'tecnico' then t.nome when 'time' then x.nome else coalesce(m.nome_fantasia, m.razao_social) end,
           a.inicio, a.fim,
           case when a.cancelada_em is not null then 'cancelada' when a.fim < current_date then 'encerrada'
                when a.inicio > current_date then 'futura' else 'vigente' end,
           a.criado_por
      from carga_atribuicoes a join cargas_horarias c on c.id = a.carga_id join empresas m on m.id = a.empresa_id
      left join tecnicos t on t.id = a.tecnico_id left join times x on x.id = a.time_id
     where p_empresa is null or a.empresa_id = p_empresa
     order by coalesce(m.nome_fantasia, m.razao_social), a.alvo, a.inicio desc;
end $function$;

-- Escala que vale para cada funcionário ativo numa data, e de onde ela vem
create or replace function app_cargas_funcionarios(p_empresa uuid default null, p_data date default null)
returns table (tecnico_id uuid, tecnico text, empresa text, time_nome text, carga text, origem text, semanal_min int)
language plpgsql stable security definer set search_path = public, extensions as $function$
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
     where t.ativo and t.desligado_em is null
       and (p_empresa is null or t.empresa_id = p_empresa)
     order by coalesce(m.nome_fantasia, m.razao_social), t.nome;
end $function$;

-- Times
create or replace function app_times(p_empresa uuid default null)
returns table (id uuid, empresa_id uuid, empresa text, nome text, ativo boolean, membros bigint)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select x.id, x.empresa_id, coalesce(m.nome_fantasia, m.razao_social), x.nome, x.ativo,
           (select count(*) from tecnicos t where t.time_id = x.id and t.ativo and t.desligado_em is null)
      from times x join empresas m on m.id = x.empresa_id
     where p_empresa is null or x.empresa_id = p_empresa
     order by coalesce(m.nome_fantasia, m.razao_social), x.nome;
end $function$;

-- Cria ou renomeia um time. O nome do time é o campo equipe dos membros.
create or replace function app_salvar_time(p_id uuid, p_empresa uuid, p_nome text, p_ativo boolean default true)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_nome text := nullif(trim(p_nome), '');
  v_id   uuid := p_id;
  v_emp  uuid;
begin
  perform app_exigir(array['admin','gestor']);
  if v_nome is null then raise exception 'Dê um nome ao time.'; end if;
  if v_id is null then
    if not exists (select 1 from empresas where id = p_empresa and ativo) then raise exception 'Escolha a empresa do time.'; end if;
    v_emp := p_empresa;
  else
    select empresa_id into v_emp from times where id = v_id;
    if v_emp is null then raise exception 'Time não encontrado.'; end if;
  end if;
  if exists (select 1 from times where empresa_id = v_emp and lower(trim(nome)) = lower(v_nome) and id is distinct from v_id) then
    raise exception 'Já existe um time com este nome nesta empresa.';
  end if;
  if not coalesce(p_ativo, true) and exists (select 1 from tecnicos where time_id = v_id) then
    raise exception 'Tire os membros do time antes de inativá-lo.';
  end if;
  if v_id is null then
    insert into times (empresa_id, nome, ativo) values (v_emp, v_nome, coalesce(p_ativo, true)) returning id into v_id;
  else
    update times set nome = v_nome, ativo = coalesce(p_ativo, true) where id = v_id;
    update tecnicos set equipe = v_nome where time_id = v_id and equipe is distinct from v_nome;
  end if;
  return v_id;
end $function$;

-- Define os membros do time: quem está na lista entra; quem era do time e não está, sai
create or replace function app_time_definir_membros(p_time uuid, p_tecnicos uuid[])
returns void language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_x times;
begin
  perform app_exigir(array['admin','gestor']);
  select * into v_x from times where id = p_time;
  if not found then raise exception 'Time não encontrado.'; end if;
  if not v_x.ativo then raise exception 'Time inativo.'; end if;
  if exists (select 1 from tecnicos where id = any(coalesce(p_tecnicos, '{}')) and empresa_id is distinct from v_x.empresa_id) then
    raise exception 'O time só recebe funcionários da própria empresa.';
  end if;
  update tecnicos set equipe = null where time_id = p_time and not (id = any(coalesce(p_tecnicos, '{}')));
  update tecnicos set equipe = v_x.nome where id = any(coalesce(p_tecnicos, '{}')) and time_id is distinct from p_time;
end $function$;

-- Escala padrão de cada empregadora ativa, atribuída à empresa a partir de hoje (jornada que já vale hoje)
insert into cargas_horarias (empresa_id, nome, tipo, minutos, intervalo_min, semanal_min, riscos, criado_por)
select e.id, '44h 6x1 (8h + 4h sábado)', 'semanal', array[480,480,480,480,480,240,0], 60, 2640, '[]', 'migração 94'
  from empresas e
 where e.empregadora and e.ativo
   and not exists (select 1 from cargas_horarias c where c.empresa_id = e.id);
insert into carga_atribuicoes (carga_id, empresa_id, alvo, inicio, fim, criado_por)
select c.id, c.empresa_id, 'empresa', current_date, (current_date + interval '1 year' - interval '1 day')::date, 'migração 94'
  from cargas_horarias c
 where c.criado_por = 'migração 94'
   and not exists (select 1 from carga_atribuicoes a where a.empresa_id = c.empresa_id);

-- Rodapé dos botões do WhatsApp: "Trilha" (recriada da migration 93; só o rodapé muda)
create or replace function fn_payload_escala(p_escala_id uuid, p_telefone text, p_lembrete boolean, p_botoes boolean)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions'
as $function$
declare
  v_inst text := fn_config('evolution_instancia');
begin
  if exists (select 1 from escalas where id = p_escala_id and local_id is null) then
    raise exception 'Programação sem local não é enviada. Escolha o local e reenvie.';
  end if;

  if p_botoes then
    return jsonb_build_object(
      'path', '/message/sendButtons/' || v_inst,
      'body', jsonb_build_object(
        'number', p_telefone,
        'title', case when p_lembrete then 'LEMBRETE — ' else '' end || fn_titulo_escala(p_escala_id),
        'description', fn_corpo_escala(p_escala_id) || E'\n\n'
                       || 'Confirme pelos botões abaixo ou responda *1* (confirmado) ou *2* (problema).',
        'footer', 'Trilha',
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
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
