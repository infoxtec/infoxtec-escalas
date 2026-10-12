-- Migration 83 (13/10/2026): jornada de mais de 4 h e até 6 h sem intervalo passa a gerar aviso (CLT art. 71,
-- §1º: intervalo de 15 minutos). Antes, "sem intervalo" só valia acima de 6 h (pendência P3 da revisão da
-- migration 61). Conta a jornada efetiva, com hora extra. O aviso ao funcionário e ao gestor diz qual
-- intervalo faltou ou ficou curto (15 min ou 1 h). Base: definições atuais da
-- homologação (iguais às das migrations 66 e 65, conferido por hash em 13/10).

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
  v_ab_dia  boolean := false;
  v_ab_min  int := 0;
  v_ab_txt  text;
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
  -- escala do dia e abonos (decisão 55): dia com escala já passado e sem marcação é falta
  select min(s.hora_inicio) into v_esc from escalas s
   where s.tecnico_id = p_tecnico and s.data_servico = p_data and s.status not in ('cancelada', 'recusada', 'rascunho');
  select coalesce(bool_or(a.inicio is null), false),
         coalesce(sum(extract(epoch from a.fim - a.inicio) / 60) filter (where a.inicio is not null), 0)::int,
         string_agg(case when a.inicio is null then 'dia inteiro'
                         else to_char(a.inicio, 'HH24:MI') || '–' || to_char(a.fim, 'HH24:MI') end, ', ' order by a.inicio nulls first)
    into v_ab_dia, v_ab_min, v_ab_txt
    from ponto_abonos a
   where a.tecnico_id = p_tecnico and a.data = p_data and a.estorno_de is null
     and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id);
  if v_n = 0 and v_ajustes = 0 and v_ab_txt is null and (v_esc is null or v_hoje) then return null; end if;

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
  elsif v_total > 240 then
    -- sem intervalo: acima de 4 h já exige 15 min (art. 71, §1º); acima de 6 h, 1 h (caput). Conta a
    -- jornada efetiva, com a hora extra (Súmula 437, IV, do TST), o mesmo valor que escolhe o texto do aviso
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
  if v_esc is not null and v_ent is not null then
    v_atraso := (extract(epoch from (v_ent at time zone v_fuso)::time - v_esc) / 60)::int;
    if v_atraso > v_tol then
      v_al := array_append(v_al, case when v_ab_dia or v_ab_min >= v_atraso then 'atraso_abonado' else 'atraso' end);
    else v_atraso := null; end if;
  end if;
  -- dia já encerrado com marcação faltando
  if v_n = 0 and v_esc is not null and not v_hoje then
    v_al := array_append(v_al, case when v_ab_dia then 'falta_abonada' else 'falta' end);
  elsif v_n > 0 and not v_hoje and (v_ent is null or v_sai is null or (v_sa is null) <> (v_va is null) or v_he_ini is not null) then
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
    'marcacoes', v_n, 'ajustes', v_ajustes, 'alertas', to_jsonb(v_al),
    'abono', v_ab_txt, 'abonado_min', case when v_ab_dia then v_jornada else v_ab_min end);
end $function$;

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
      when 'intervalo_curto'    then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                            || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
                                       else 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de '
                                            || coalesce(nullif(fn_config('ponto_intervalo_curto_min'), ''), '15')
                                            || ' min — mínimo da CLT para jornada acima de 4 horas (art. 71, §1º).' end
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_min')::int) || ' hoje, acima do limite de 2 horas por dia (CLT art. 59).'
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
