-- Migration 65 (10/10/2026): ajustes de ponto com justificativa — backlog 084, entrega 2 (decisão 52).
--
-- O gestor corrige o espelho sem tocar na marcação, que é imutável (Portaria 671): cada ajuste é um
-- registro novo em ponto_ajustes (tabela da migration 54, só inclusão, motivo de no mínimo 10 letras,
-- guarda de 5 anos como as marcações). Dois tipos:
--   incluir       — marcação esquecida (tipo + horário), lançada pelo gestor;
--   desconsiderar — marcação errada ou repetida sai do cálculo, mas continua guardada e visível.
-- Regras da decisão 52: C) só admin e gestor lançam, e o funcionário é avisado pelo WhatsApp do que
-- mudou, SEM o motivo (texto livre pode ter dado de saúde: "atestado"); A) o papel leitura vê espelho,
-- totais e avisos, e a lista de ajustes sem motivo nem autor; B) o aviso de jornada ao gestor leva só o
-- primeiro nome do funcionário.
--
-- Da revisão do seguranca (10/10): inclusão errada se desfaz com outro ajuste — "desconsiderar" pode
-- apontar para uma inclusão (coluna ajuste_id); o mesmo alvo só é desconsiderado uma vez (índice único,
-- seguro contra dois cliques simultâneos); inclusão repetida é recusada; motivo de 10 a 500 letras e
-- sem diagnóstico (orientação no painel); data e hora chegam locais e o fuso é o da empresa; aviso ao
-- funcionário no máximo um a cada 5 minutos.

alter table ponto_ajustes add column if not exists ajuste_id uuid references ponto_ajustes(id);
comment on column ponto_ajustes.ajuste_id is 'Desconsiderar uma inclusão feita por ajuste (alvo é outro ajuste, não uma marcação).';

-- Alvo do "desconsiderar": uma marcação OU uma inclusão, nunca os dois (troca o check da migration 54)
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'ponto_ajustes'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%desconsiderar%marcacao_id%' loop
    execute format('alter table ponto_ajustes drop constraint %I', c.conname);
  end loop;
end $$;
alter table ponto_ajustes add constraint ponto_ajustes_alvo_ck
  check ((acao = 'desconsiderar' and num_nonnulls(marcacao_id, ajuste_id) = 1)
      or (acao = 'incluir' and marcacao_id is null and ajuste_id is null));
alter table ponto_ajustes add constraint ponto_ajustes_motivo_max_ck check (length(motivo) <= 500);
create unique index if not exists ponto_ajustes_desc_marcacao_uq on ponto_ajustes (marcacao_id) where acao = 'desconsiderar';
create unique index if not exists ponto_ajustes_desc_ajuste_uq on ponto_ajustes (ajuste_id) where acao = 'desconsiderar';

-- Marcações que valem para o cálculo: as originais não desconsideradas + as incluídas por ajuste
create or replace function fn_ponto_marcacoes_efetivas(p_tecnico uuid, p_ini timestamptz, p_fim timestamptz)
returns table (tipo text, momento timestamptz, nsr bigint, ajuste boolean)
language sql stable set search_path = public, extensions as $$
  select m.tipo, m.momento, m.nsr, false
    from ponto_marcacoes m
   where m.tecnico_id = p_tecnico and m.momento >= p_ini and m.momento < p_fim
     and not exists (select 1 from ponto_ajustes a where a.marcacao_id = m.id and a.acao = 'desconsiderar')
  union all
  select a.tipo, a.momento, null::bigint, true
    from ponto_ajustes a
   where a.tecnico_id = p_tecnico and a.acao = 'incluir' and a.momento >= p_ini and a.momento < p_fim
     and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id and d.acao = 'desconsiderar')
$$;

-- Jornada do dia sobre as marcações efetivas (mesmo cálculo da migration 61) + quantos ajustes houve
create or replace function fn_ponto_jornada_dia(p_tecnico uuid, p_data date)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions'
as $function$
declare
  v_fuso    text;
  m         record;
  v_ent     timestamptz;
  v_sa      timestamptz;
  v_va      timestamptz;
  v_sai     timestamptz;
  v_he_ini  timestamptz;
  v_he      int := 0;
  v_normal  int;
  v_total   int;
  v_int     int;
  v_extra   int;
  v_inter   int;
  v_ant     timestamptz;
  v_esc     time;
  v_atraso  int;
  v_n       int := 0;
  v_ajustes int;
  v_hoje    boolean;
  v_ini     timestamptz;
  v_fim     timestamptz;
  v_al      text[] := '{}';
  v_jornada int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_int_min int := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  v_int_max int := coalesce(nullif(fn_config('ponto_intervalo_max_min'), '')::int, 120);
  v_int_cur int := coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15);
  v_he_lim  int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_ij_min  int := coalesce(nullif(fn_config('ponto_interjornada_min'), '')::int, 660);
  v_tol     int := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_hoje := p_data >= (now() at time zone v_fuso)::date;
  v_ini := p_data::timestamp at time zone v_fuso;
  v_fim := (p_data + 1)::timestamp at time zone v_fuso;

  for m in select x.tipo, x.momento from fn_ponto_marcacoes_efetivas(p_tecnico, v_ini, v_fim) x
            order by x.momento, x.nsr nulls last loop
    v_n := v_n + 1;
    case m.tipo
      when 'entrada'      then v_ent := coalesce(v_ent, m.momento);
      when 'saida_almoco' then v_sa  := coalesce(v_sa, m.momento);
      when 'volta_almoco' then v_va  := coalesce(v_va, m.momento);
      when 'saida'        then v_sai := m.momento;
      when 'inicio_he'    then v_he_ini := m.momento;
      when 'fim_he'       then
        if v_he_ini is not null then
          v_he := v_he + (extract(epoch from m.momento - v_he_ini) / 60)::int;
          v_he_ini := null;
        end if;
      else null;
    end case;
  end loop;

  select count(*) into v_ajustes
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and coalesce(a.momento, x.momento, y.momento) >= v_ini and coalesce(a.momento, x.momento, y.momento) < v_fim;
  if v_n = 0 and v_ajustes = 0 then return null; end if;

  -- trabalho normal: entrada → saída, descontado o intervalo
  if v_ent is not null and v_sai is not null then
    v_normal := (extract(epoch from v_sai - v_ent) / 60)::int;
    if v_sa is not null and v_va is not null then
      v_normal := v_normal - (extract(epoch from v_va - v_sa) / 60)::int;
    end if;
  end if;
  if v_sa is not null and v_va is not null then
    v_int := (extract(epoch from v_va - v_sa) / 60)::int;
  end if;
  v_total := coalesce(v_normal, 0) + v_he;
  v_extra := greatest(v_total - v_jornada, 0);

  -- intervalo intrajornada (CLT art. 71)
  if v_int is not null then
    if v_int < v_int_min and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_curto');
    elsif v_int < v_int_cur and v_normal > 240 then v_al := array_append(v_al, 'intervalo_curto');
    end if;
    if v_int > v_int_max and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_longo'); end if;
  elsif v_normal > 360 then
    v_al := array_append(v_al, 'sem_intervalo');
  end if;
  -- hora extra (CLT art. 59)
  if v_extra > v_he_lim then v_al := array_append(v_al, 'he_acima_limite'); end if;
  -- interjornada (CLT art. 66): da última saída efetiva antes desta entrada
  if v_ent is not null then
    select max(x.momento) into v_ant from fn_ponto_marcacoes_efetivas(p_tecnico, v_ent - interval '2 days', v_ent) x
     where x.tipo in ('saida', 'fim_he');
    if v_ant is not null then
      v_inter := (extract(epoch from v_ent - v_ant) / 60)::int;
      if v_inter < v_ij_min then v_al := array_append(v_al, 'interjornada_curta'); end if;
    end if;
  end if;
  -- atraso em relação à escala (CLT art. 58, §1º)
  select min(s.hora_inicio) into v_esc from escalas s
   where s.tecnico_id = p_tecnico and s.data_servico = p_data and s.status not in ('cancelada', 'recusada');
  if v_esc is not null and v_ent is not null then
    v_atraso := (extract(epoch from (v_ent at time zone v_fuso)::time - v_esc) / 60)::int;
    if v_atraso > v_tol then v_al := array_append(v_al, 'atraso'); else v_atraso := null; end if;
  end if;
  -- dia já encerrado com marcação faltando
  if not v_hoje and (v_ent is null or v_sai is null or (v_sa is null) <> (v_va is null) or v_he_ini is not null) then
    v_al := array_append(v_al, 'incompleta');
  end if;

  return jsonb_build_object(
    'entrada', to_char(v_ent at time zone v_fuso, 'HH24:MI'),
    'saida_almoco', to_char(v_sa at time zone v_fuso, 'HH24:MI'),
    'volta_almoco', to_char(v_va at time zone v_fuso, 'HH24:MI'),
    'saida', to_char(v_sai at time zone v_fuso, 'HH24:MI'),
    'trabalhado_min', case when v_normal is null and v_he = 0 then null else v_total end,
    'intervalo_min', v_int, 'he_min', v_extra, 'interjornada_min', v_inter,
    'escala_hora', left(v_esc::text, 5), 'atraso_min', v_atraso,
    'marcacoes', v_n, 'ajustes', v_ajustes, 'alertas', to_jsonb(v_al));
end $function$;

-- Espelho: mesmas colunas + ajustes do dia; dia só com marcação incluída por ajuste também aparece
drop function if exists app_ponto_espelho(date, date, uuid);
create function app_ponto_espelho(p_de date, p_ate date, p_tecnico uuid default null)
 returns table(tecnico_id uuid, tecnico text, data date, escala_hora text, entrada text, saida_almoco text,
               volta_almoco text, saida text, trabalhado_min integer, intervalo_min integer, he_min integer,
               atraso_min integer, interjornada_min integer, alertas text[], ajustes integer)
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    with dias as (
      select distinct m.tecnico_id as tid, (m.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date as dia
        from ponto_marcacoes m join empresas e on e.id = m.empresa_id
       where m.momento >= p_de::timestamp - interval '1 day' and m.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or m.tecnico_id = p_tecnico)
      union
      select a.tecnico_id, (a.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date
        from ponto_ajustes a join empresas e on e.id = a.empresa_id
       where a.acao = 'incluir'
         and a.momento >= p_de::timestamp - interval '1 day' and a.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or a.tecnico_id = p_tecnico)
    ), j as (
      select d.tid, d.dia, fn_ponto_jornada_dia(d.tid, d.dia) as x from dias d where d.dia between p_de and p_ate
    )
    select j.tid, t.nome, j.dia, j.x->>'escala_hora', j.x->>'entrada', j.x->>'saida_almoco', j.x->>'volta_almoco',
           j.x->>'saida', (j.x->>'trabalhado_min')::int, (j.x->>'intervalo_min')::int, (j.x->>'he_min')::int,
           (j.x->>'atraso_min')::int, (j.x->>'interjornada_min')::int,
           array(select jsonb_array_elements_text(j.x->'alertas')), coalesce((j.x->>'ajustes')::int, 0)
      from j join tecnicos t on t.id = j.tid
     where j.x is not null
     order by j.dia desc, t.nome;
end $function$;

-- Rótulo de cada tipo de marcação, para as mensagens
create or replace function fn_ponto_rotulo(p_tipo text)
returns text language sql immutable set search_path = public, extensions as $$
  select case p_tipo when 'entrada' then 'Entrada' when 'saida_almoco' then 'Saída para o almoço'
    when 'volta_almoco' then 'Volta do almoço' when 'saida' then 'Saída'
    when 'inicio_he' then 'Início de hora extra' when 'fim_he' then 'Fim de hora extra' else p_tipo end
$$;

-- Lançar ajuste (admin e gestor). O funcionário é avisado do que mudou, nunca do motivo.
-- incluir: p_tipo + p_data + p_hora (hora local da empresa). desconsiderar: p_marcacao OU p_ajuste (inclusão).
create or replace function app_ponto_ajustar(p_tecnico uuid, p_acao text, p_motivo text,
  p_marcacao uuid default null, p_ajuste uuid default null,
  p_data date default null, p_hora time default null, p_tipo text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_tec     record;
  v_alvo    record;
  v_mom     timestamptz;
  v_tipo    text;
  v_emp     uuid;
  v_id      uuid;
  v_texto   text;
  v_fuso    text;
  v_avisado boolean := false;
begin
  select t.id, t.nome, t.telefone_e164, t.opt_in, t.ativo, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  v_fuso := v_tec.fuso;
  v_emp := v_tec.empresa_id;
  if length(trim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Escreva o motivo do ajuste (pelo menos 10 letras).';
  end if;
  if length(trim(p_motivo)) > 500 then raise exception 'Motivo com no máximo 500 letras.'; end if;

  if p_acao = 'desconsiderar' then
    if num_nonnulls(p_marcacao, p_ajuste) <> 1 then raise exception 'Escolha a marcação a desconsiderar.'; end if;
    if p_marcacao is not null then
      select m.tipo, m.momento, m.tecnico_id, m.empresa_id into v_alvo from ponto_marcacoes m where m.id = p_marcacao;
      if not found or v_alvo.tecnico_id <> p_tecnico then raise exception 'Marcação não encontrada para este funcionário.'; end if;
    else
      select a.tipo, a.momento, a.tecnico_id, a.empresa_id into v_alvo from ponto_ajustes a
       where a.id = p_ajuste and a.acao = 'incluir';
      if not found or v_alvo.tecnico_id <> p_tecnico then raise exception 'Marcação não encontrada para este funcionário.'; end if;
    end if;
    if exists (select 1 from ponto_ajustes a where a.acao = 'desconsiderar'
                and (a.marcacao_id = p_marcacao or a.ajuste_id = p_ajuste)) then
      raise exception 'Esta marcação já foi desconsiderada.';
    end if;
    v_mom := v_alvo.momento; v_tipo := v_alvo.tipo; v_emp := v_alvo.empresa_id;
  elsif p_acao = 'incluir' then
    if p_tipo is null or p_tipo not in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he') then
      raise exception 'Escolha o tipo da marcação a incluir.';
    end if;
    if p_data is null or p_hora is null then raise exception 'Informe a data e a hora da marcação a incluir.'; end if;
    v_mom := (p_data + p_hora) at time zone v_fuso;
    if v_mom > now() then raise exception 'Não é possível incluir marcação no futuro.'; end if;
    if exists (select 1 from ponto_ajustes a where a.tecnico_id = p_tecnico and a.acao = 'incluir'
                and a.tipo = p_tipo and a.momento = v_mom
                and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id)) then
      raise exception 'Esta marcação já foi incluída.';
    end if;
    v_tipo := p_tipo;
  else
    raise exception 'Ação de ajuste inválida.';
  end if;
  if v_mom < now() - interval '62 days' then raise exception 'Ajuste só para os últimos 62 dias.'; end if;

  begin
    insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, ajuste_id, acao, momento, tipo, motivo, autor)
    values (v_emp, p_tecnico, case when p_acao = 'desconsiderar' then p_marcacao end,
            case when p_acao = 'desconsiderar' then p_ajuste end, p_acao,
            case when p_acao = 'incluir' then v_mom end, case when p_acao = 'incluir' then v_tipo end,
            trim(p_motivo), v_email)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Esta marcação já foi desconsiderada.';
  end;

  -- aviso ao funcionário: o que mudou, sem o motivo (LGPD); no máximo um a cada 5 minutos
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_ajuste_' || p_tecnico || '_' || floor(extract(epoch from now()) / 300)::bigint, current_date, now(), true,
            jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_texto := '📝 *Ponto · ajuste do gestor*' || E'\n' || 'Seu registro de '
        || to_char(v_mom at time zone v_fuso, 'DD/MM') || ' foi ajustado: '
        || case when p_acao = 'incluir' then 'incluída a marcação ' || fn_ponto_rotulo(v_tipo) || ' às '
                else 'desconsiderada a marcação ' || fn_ponto_rotulo(v_tipo) || ' das ' end
        || to_char(v_mom at time zone v_fuso, 'HH24:MI') || '.' || E'\n'
        || 'As marcações originais continuam guardadas. Dúvidas, fale com seu gestor.';
      perform fn_ponto_wa(v_tec.telefone_e164, v_texto);
      v_avisado := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'acao', p_acao, 'tipo', v_tipo, 'avisado', v_avisado,
    'data', to_char(v_mom at time zone v_fuso, 'DD/MM/YYYY'), 'hora', to_char(v_mom at time zone v_fuso, 'HH24:MI'));
end $$;

-- Ajustes do período. Leitura vê a lista sem motivo nem autor (decisão 52 A; motivo pode ter dado de saúde).
create or replace function app_ponto_ajustes(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, tecnico_id uuid, tecnico text, data text, hora text, acao text, tipo text,
               marcacao_nsr bigint, desfaz_inclusao boolean, desconsiderado boolean,
               motivo text, autor text, criado_em text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_leitura boolean;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select a.id, a.tecnico_id, t.nome,
           to_char(coalesce(a.momento, m.momento, y.momento) at time zone e.fuso, 'DD/MM/YYYY'),
           to_char(coalesce(a.momento, m.momento, y.momento) at time zone e.fuso, 'HH24:MI'),
           a.acao, coalesce(a.tipo, m.tipo, y.tipo), m.nsr, a.ajuste_id is not null,
           a.acao = 'incluir' and exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id),
           case when v_leitura then null else a.motivo end,
           case when v_leitura then null else a.autor end,
           to_char(a.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI')
      from ponto_ajustes a
      join tecnicos t on t.id = a.tecnico_id
      join empresas e on e.id = a.empresa_id
      left join ponto_marcacoes m on m.id = a.marcacao_id
      left join ponto_ajustes y on y.id = a.ajuste_id
     where (coalesce(a.momento, m.momento, y.momento) at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or a.tecnico_id = p_tecnico)
     order by a.created_at desc;
end $$;

-- Decisão 52 B: o aviso de jornada ao gestor leva só o primeiro nome (resto igual à migration 61)
create or replace function fn_ponto_avisar(p_tecnico uuid, p_tipo text)
 returns text[]
 language plpgsql
 set search_path to 'public', 'extensions'
as $function$
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
begin
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;
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
      when 'intervalo_curto'    then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                     || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_min')::int) || ' hoje, acima do limite de 2 horas por dia (CLT art. 59).'
      when 'sem_intervalo'      then 'Jornada de mais de 6 horas sem intervalo registrado (CLT art. 71).'
      when 'interjornada_curta' then 'Descanso de ' || fn_ponto_hm((j->>'interjornada_min')::int) || ' desde a última saída, abaixo das 11 horas entre jornadas (CLT art. 66).'
    end;
    v_saida := v_saida || ('⚠️ ' || v_func || ' A marcação vale; o gestor será avisado.');
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_' || a || '_' || p_tecnico, v_data, now(), true, jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_gest := '⚠️ *Ponto · ' || v_nome || '* (' || to_char(v_data, 'DD/MM') || '): ' || v_func;
      -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora; cadastrar a
      -- empresa do supervisor antes do segundo cliente (separação por cliente, backlog 074)
      for s in select telefone_e164 from tecnicos
                where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
                  and (empresa_id = v_emp or empresa_id is null) loop
        perform fn_ponto_wa(s.telefone_e164, v_gest);
      end loop;
    end if;
  end loop;
  return v_saida;
exception when others then
  raise warning 'ponto: avisos de jornada falharam: %', sqlerrm;
  return '{}';
end $function$;

-- Permissões por laço (decisões 12, 49 e 51) -------------------------------------------------------
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
