-- Migration 104 (16/10/2026): critérios de inconsistência do ponto, parte 1 da decisão 100.
--   1. Registro do intervalo no fechamento: com a opção da empresa "exige registro do intervalo", o dia com
--      jornada acima de 4 h sem o par de intervalo (15 min de 4 a 6 h, 1 h acima de 6 h — CLT art. 71) passa de
--      "confirmar" a "bloqueia" (intervalo_nao_registrado). Resolve: pedido de ajuste do funcionário aprovado
--      ou abono do gestor no dia (o período ou o intervalo), que conta como hora abonada. A marcação do dia a
--      dia nunca é travada (Portaria MTP 671/2021). Opção ligada na Infoxtec; desligada para quem usa a
--      pré-assinalação do intervalo (CLT art. 74, §2º). Só o administrador muda a opção.
--   2. O gestor nunca cria marcação: sai de app_ponto_ajustar a ação "incluir" e os parâmetros dela.
--   3. Avisos: o comprovante da saída para o intervalo diz "retorno a partir de HH:MM"; o aviso da volta antes
--      do mínimo é só informativo; no dia seguinte, o funcionário cujo intervalo não foi registrado recebe o
--      convite para pedir o ajuste se fez o intervalo (texto revisado pelo juridico: sem cobrança).
-- A hora extra com aprovação do gestor (item 3 da decisão 100) vem na parte 2.
-- Base: definições atuais da homologação em 16/10 (iguais às das migrations 95, 96, 101, 102 e 56).

alter table empresas add column if not exists exige_registro_intervalo boolean not null default false;
comment on column empresas.exige_registro_intervalo is
  'Decisão 100: sem o par de intervalo em jornada acima de 4 h, o fechamento da folha bloqueia. Desligar para pré-assinalação (CLT art. 74, §2º).';
-- Infoxtec (no banco vazio não acha nada)
update empresas set exige_registro_intervalo = true where cnpj = '04309223000196';

-- Cadastro da empresa: a opção nova (painel antigo não manda: fica o que estava); só o administrador altera
create or replace function app_salvar_empresa(p jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_cnpj  text := regexp_replace(coalesce(p->>'cnpj', ''), '\D', '', 'g');
  v_logo  text := nullif(trim(p->>'logo'), '');
  v_exige boolean := (p->>'exige_registro_intervalo')::boolean;
  v_antes boolean;
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;
  if v_logo is not null and v_logo !~ '^[a-z0-9-]{1,40}$' then raise exception 'Logotipo inválido.'; end if;
  if v_id is not null then
    select exige_registro_intervalo into v_antes from empresas where id = v_id;
  end if;
  if v_exige is not null and v_exige is distinct from coalesce(v_antes, false) then
    begin
      perform fn_exigir_papel(v_email, array['admin']);
    exception when others then
      raise exception 'Só o administrador muda a exigência do registro do intervalo.';
    end;
  end if;

  if v_id is null then
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cidade, uf, empregadora, ativo, logo,
                          exige_registro_intervalo)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true), v_logo,
            coalesce(v_exige, false))
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      uf = upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
      empregadora = coalesce((p->>'empregadora')::boolean, false),
      ativo = coalesce((p->>'ativo')::boolean, true),
      -- painel antigo não manda o logotipo nem a exigência: fica o que estava
      logo = case when p ? 'logo' then v_logo else logo end,
      exige_registro_intervalo = coalesce(v_exige, exige_registro_intervalo)
    where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma empresa com este CNPJ.';
end $$;

-- Pendências da folha: intervalo não registrado bloqueia quando a empresa exige o registro
create or replace function fn_ponto_folha_pendencias(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_fim   date := (date_trunc('month', p_mes) + interval '1 month')::date - 1;
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_ontem date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_abona boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_res   jsonb := '[]'::jsonb;
  v_dias  int := 0;
  v_dup   date[];
  v_ped   date[];
  v_exige boolean;
  a       text;
  t record; r record;
begin
  select coalesce(tc.admissao, tc.created_at::date) as adm, tc.desligado_em, coalesce(e.exige_registro_intervalo, false) as exige
    into t from tecnicos tc left join empresas e on e.id = tc.empresa_id where tc.id = p_tecnico;
  if not found then return v_res; end if;
  v_exige := t.exige;

  -- pedidos aguardando decisão (e os dias que eles cobrem: lá não é falta injustificada, é pendência). Sem o motivo:
  -- o código de saúde (pré-natal, preventivo...) é dado sensível e a validação é aberta ao papel leitura (decisão 56)
  select coalesce(jsonb_agg(jsonb_build_object('tipo', 'pedido_pendente', 'nivel', 'bloqueia', 'bloqueia', true,
           'data', j.data, 'numero', j.numero) order by j.data, j.numero), '[]'::jsonb),
         coalesce(array_agg(distinct g::date), '{}')
    into v_res, v_ped
    from ponto_justificativas j
    cross join lateral generate_series(j.data, coalesce(j.data_fim, j.data), interval '1 day') g
   where j.tecnico_id = p_tecnico and j.status = 'pendente'
     and j.data <= v_fim and coalesce(j.data_fim, j.data) >= v_mes;
  -- o agregado acima repete o pedido por dia coberto: um item por pedido
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;

  -- marcações duplicadas: o mesmo tipo em seguida no dia, ou duas a menos de 3 min (as desconsideradas não contam).
  -- As inclusões vêm só de pedido do funcionário aprovado (o gestor não cria marcação, decisões 89 e 100)
  with m as (
    select (x.momento at time zone v_fuso) as h, x.tipo from ponto_marcacoes x
     where x.tecnico_id = p_tecnico
       and x.momento >= v_mes::timestamp at time zone v_fuso and x.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.marcacao_id = x.id)
    union all
    select (a.momento at time zone v_fuso), a.tipo from ponto_ajustes a
     where a.tecnico_id = p_tecnico and a.acao = 'incluir'
       and a.momento >= v_mes::timestamp at time zone v_fuso and a.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.ajuste_id = a.id)
  ), o as (
    select h, tipo, lag(h) over (partition by h::date order by h) as h_ant, lag(tipo) over (partition by h::date order by h) as tipo_ant
      from m
  )
  select coalesce(array_agg(distinct h::date), '{}') into v_dup
    from o where h_ant is not null and (tipo = tipo_ant or h - h_ant < interval '3 minutes');

  for r in select g::date as dia, fn_ponto_jornada_dia(p_tecnico, g::date) as j, fn_carga_dia(p_tecnico, g::date) as c
             from generate_series(greatest(v_mes, t.adm), least(v_fim, v_ontem, coalesce(t.desligado_em, v_fim)),
                                  interval '1 day') g loop
    if r.j is not null then
      v_dias := v_dias + 1;
      if r.dia = any(v_dup) then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_duplicada', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      elsif r.j->'alertas' ? 'incompleta' then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_incompleta', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
      foreach a in array array['intervalo_curto', 'sem_intervalo', 'he_acima_limite', 'interjornada_curta'] loop
        if r.j->'alertas' ? a then
          if a = 'sem_intervalo' and v_exige and r.j->>'abono' is null then
            -- decisão 100: sem o par de intervalo, não fecha até o pedido do funcionário ou o abono do gestor
            v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'intervalo_nao_registrado', 'nivel', 'bloqueia',
                       'bloqueia', true, 'data', r.dia, 'trabalhado_min', (r.j->>'trabalhado_min')::int));
          else
            v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', a, 'nivel', 'confirmar', 'bloqueia', false, 'data', r.dia,
                       'intervalo_min', (r.j->>'intervalo_min')::int, 'he_min', (r.j->>'he_min')::int,
                       'interjornada_min', (r.j->>'interjornada_min')::int));
          end if;
        end if;
      end loop;
      if r.j->>'abono' = 'dia inteiro' and coalesce((r.j->>'marcacoes')::int, 0) > 0 then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'abono_em_dia_trabalhado', 'nivel', 'confirmar', 'bloqueia', false,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
    elsif coalesce((r.c->>'minutos')::int, 0) > 0
      and not (r.dia = any(v_ped))
      and not (r.c->>'tipo' is distinct from '12x36'
               and exists (select 1 from feriados f where f.data = r.dia and f.abrangencia <> 'facultativo'))
      and not (extract(isodow from r.dia) = 6 and r.c->>'escala' is null and v_abona) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'nivel', 'confirmar', 'bloqueia', false,
                 'data', r.dia, 'minutos', (r.c->>'minutos')::int));
    end if;
  end loop;

  -- funcionário sem nenhum registro no mês não entra no fechamento (o espelho não é emitido): não há o que apontar
  if v_dias = 0 and not exists (select 1 from jsonb_array_elements(v_res) x where x->>'tipo' = 'pedido_pendente') then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(x order by x->>'data', x->>'tipo'), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;
  return v_res;
end $$;

-- O gestor nunca cria marcação (decisão 100): só desconsidera a errada. Sai a assinatura com os parâmetros da
-- inclusão; o painel chama pelos nomes que continuam (p_tecnico, p_acao, p_motivo, p_marcacao, p_ajuste)
drop function if exists app_ponto_ajustar(uuid, text, text, uuid, uuid, date, time without time zone, text);
create or replace function app_ponto_ajustar(p_tecnico uuid, p_acao text, p_motivo text,
  p_marcacao uuid default null, p_ajuste uuid default null)
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
  if p_acao = 'incluir' then
    raise exception 'O gestor não inclui marcação: só desconsidera a errada. A marcação vem sempre do funcionário (decisão 100).';
  elsif p_acao is distinct from 'desconsiderar' then
    raise exception 'Ação de ajuste inválida.';
  end if;

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
  if v_mom < now() - interval '62 days' then raise exception 'Ajuste só para os últimos 62 dias.'; end if;

  begin
    insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, ajuste_id, acao, motivo, autor)
    values (v_emp, p_tecnico, p_marcacao, p_ajuste, 'desconsiderar', trim(p_motivo), v_email)
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
        || 'desconsiderada a marcação ' || fn_ponto_rotulo(v_tipo) || ' das '
        || to_char(v_mom at time zone v_fuso, 'HH24:MI') || '.' || E'\n'
        || 'As marcações originais continuam guardadas. Dúvidas, fale com seu gestor.';
      perform fn_ponto_wa(v_tec.telefone_e164, v_texto);
      v_avisado := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'acao', p_acao, 'tipo', v_tipo, 'avisado', v_avisado,
    'data', to_char(v_mom at time zone v_fuso, 'DD/MM/YYYY'), 'hora', to_char(v_mom at time zone v_fuso, 'HH24:MI'));
end $$;

-- Aviso antes da volta do intervalo: só informativo (juridico: nada que pareça recusa ou cobrança)
create or replace function fn_ponto_aviso_previo(p_tecnico uuid, p_tipo text)
returns text language plpgsql stable set search_path = public, extensions as $$
declare
  v_fuso text;
  v_sa   timestamptz;
  v_min  int;
  v_lim  int;
begin
  if p_tipo is distinct from 'volta_almoco' then return null; end if;
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  select max(momento) into v_sa from ponto_marcacoes
   where tecnico_id = p_tecnico and tipo = 'saida_almoco'
     and momento >= ((now() at time zone v_fuso)::date::timestamp at time zone v_fuso);
  if v_sa is null then return null; end if;
  v_min := (extract(epoch from now() - v_sa) / 60)::int;
  if v_min >= v_lim then return null; end if;
  return 'ℹ️ Seu intervalo está em *' || v_min || ' min*. Para jornada acima de 6 horas, o mínimo é de *'
      || fn_ponto_hm(v_lim) || '* (CLT art. 71). A volta é registrada normalmente; o gestor será avisado.';
exception when others then
  -- aviso nunca atrapalha a marcação
  raise warning 'ponto: aviso prévio falhou: %', sqlerrm;
  return null;
end $$;

-- Avisos da marcação: na saída para o intervalo, o horário de retorno (decisão 100); o resto como antes
create or replace function fn_ponto_avisar(p_tecnico uuid, p_tipo text)
returns text[] language plpgsql set search_path = public, extensions as $$
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
end $$;

-- No dia seguinte, das 08:00 às 09:00 (fuso da empresa): convite para pedir o ajuste do intervalo não
-- registrado. Só se a empresa exige o registro, sem abono e sem pedido aberto no dia; uma vez por dia.
-- Texto do juridico: quem não fez o intervalo não precisa fazer nada (nada de cobrança)
create or replace function fn_ponto_aviso_intervalo_pendente()
returns integer language plpgsql set search_path = public, extensions as $$
declare
  t       record;
  v_ontem date;
  j       jsonb;
  v_n     int := 0;
begin
  for t in
    select tc.id, tc.telefone_e164, e.fuso
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
      perform fn_ponto_wa(t.telefone_e164,
        '📝 *Ponto · intervalo de ' || to_char(v_ontem, 'DD/MM') || '*' || E'\n'
        || 'Não há registro do seu intervalo nesse dia. Se você fez o intervalo e esqueceu de marcar, peça o ajuste: '
        || 'escreva *ajuste* aqui ou use o app (aba Ajuste). Se não fez, não precisa fazer nada.');
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

-- O lembrete do almoço (a cada 15 min) passa a chamar também o aviso do intervalo não registrado
create or replace function fn_ponto_lembrete_almoco()
returns integer language plpgsql security definer set search_path = public, extensions as $$
declare
  t record;
  v_n int := 0;
begin
  for t in
    select tc.id, tc.nome, tc.telefone_e164, e.fuso
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
      perform fn_ponto_wa(t.telefone_e164,
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
end $$;

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
