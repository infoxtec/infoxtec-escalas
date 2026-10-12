-- Migration 90 (13/10/2026): resumo do espelho mensal — o que será pago e o que será descontado, em horas
-- (pedido do responsável; decisão 83). Entra no conteúdo congelado do espelho (fn_ponto_espelho_conteudo):
-- todos os dias do mês dentro do vínculo, e por dia a hora extra a 50% e a 100%, o adicional noturno, o débito
-- e o abono; no fim, o resumo "a pagar", "a descontar" e "informativo". Só vale para espelhos emitidos depois
-- desta migration (os já emitidos são cópias congeladas).

-- Minutos de relógio trabalhados entre 22h e 5h no dia (marcações efetivas, já com os ajustes) -------------
create or replace function fn_ponto_noturno_dia(p_tecnico uuid, p_data date, p_fuso text)
returns int language plpgsql stable set search_path = public, extensions as $function$
declare
  v_ini   timestamptz := p_data::timestamp at time zone p_fuso;
  v_fim   timestamptz := (p_data + 1)::timestamp at time zone p_fuso;
  m       record;
  v_abre  timestamptz;
  v_min   int := 0;
  -- janelas noturnas que tocam o dia: 00h–05h do dia e 22h do dia até 05h do dia seguinte
  v_n1a   timestamptz := p_data::timestamp at time zone p_fuso;
  v_n1b   timestamptz := (p_data + time '05:00') at time zone p_fuso;
  v_n2a   timestamptz := (p_data + time '22:00') at time zone p_fuso;
  v_n2b   timestamptz := (p_data + 1 + time '05:00') at time zone p_fuso;
begin
  for m in select x.tipo, x.momento from fn_ponto_marcacoes_efetivas(p_tecnico, v_ini, v_fim) x
            order by x.momento, x.nsr nulls last loop
    if m.tipo in ('entrada', 'volta_almoco', 'inicio_he') then
      v_abre := coalesce(v_abre, m.momento);
    elsif m.tipo in ('saida_almoco', 'saida', 'fim_he') and v_abre is not null then
      v_min := v_min
        + greatest(0, extract(epoch from least(m.momento, v_n1b) - greatest(v_abre, v_n1a)) / 60)::int
        + greatest(0, extract(epoch from least(m.momento, v_n2b) - greatest(v_abre, v_n2a)) / 60)::int;
      v_abre := null;
    end if;
  end loop;
  return v_min;
end $function$;

-- O motivo de saúde não entra no conteúdo (decisão 56): o espelho é visto por qualquer gestor, sai impresso e
-- fica congelado. O atestado só muda o cálculo; no documento o dia aparece como abono.
-- Conteúdo do espelho com o resumo de pagamento (Portaria 671 Art. 84; critérios do juridico, decisão 83) --
-- Por dia: jornada prevista (8 h útil, 4 h sábado, 0 domingo e feriado; ponto facultativo é dia útil), tempo
-- trabalhado com a hora noturna reduzida (52'30", CLT art. 73 §1º), HE 50% (o que passa da jornada do dia,
-- inclusive além de 2 h — art. 59, Súmula 376), HE 100% (todo o domingo e feriado trabalhado — Lei 605/49
-- art. 9º, Súmula 146), débito (falta, atraso e saída antecipada não abonados), com tolerância de 10 min no
-- dia (art. 58 §1º), e intervalo não concedido (art. 71 §4º). HE e débito não se compensam (sem banco de horas).
-- Limites assumidos: dias antes da primeira marcação não cobram jornada (mas aparecem se tiverem registro);
-- tolerância fixa de 10 min no dia (art. 58 §1º); prorrogação noturna após 5h não entra; jornada que cruza a meia-noite fica dividida;
-- folga compensatória de domingo/feriado ainda não é registrada (o domingo trabalhado sai sempre a 100%).
create or replace function fn_ponto_espelho_conteudo(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $function$
declare
  v_t      record;
  v_fim    date := (p_mes + interval '1 month')::date - 1;
  v_ini    date;
  v_ult    date;
  v_jorn   int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_sab    int := coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240);
  v_abona  boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_tol    int := 10;
  v_dias   jsonb;
  v_aj     jsonb;
  v_res    jsonb;
  v_reg    int;
  v_marca  date;
begin
  select t.nome, t.cpf, t.admissao, t.funcao, t.created_at::date as criado, t.desligado_em,
         e.razao_social, e.cnpj, coalesce(e.fuso, 'America/Bahia') as fuso into v_t
    from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  -- lista do início do vínculo no mês; cobra jornada só a partir da primeira marcação do funcionário (dia
  -- anterior à implantação do ponto não vira débito; quem nunca marcou não tem débito)
  v_ini := greatest(p_mes, coalesce(v_t.admissao, v_t.criado));
  v_marca := (select min(m.momento at time zone v_t.fuso)::date from ponto_marcacoes m where m.tecnico_id = p_tecnico);
  v_ult := least(v_fim, coalesce(v_t.desligado_em, v_fim));

  with base as (
    select g.d::date as dia, fn_ponto_jornada_dia(p_tecnico, g.d::date) as j,
           fn_ponto_noturno_dia(p_tecnico, g.d::date, v_t.fuso) as noturno,
           (extract(isodow from g.d) = 7
             or exists (select 1 from feriados f where f.data = g.d::date and f.abrangencia <> 'facultativo')) as dom_fer,
           extract(isodow from g.d) = 6 as sabado,
           (select f.nome from feriados f where f.data = g.d::date and f.abrangencia <> 'facultativo' limit 1) as feriado,
           -- atestado de dia inteiro nunca gera débito (o parcial já desconta as horas pelo abono)
           exists (select 1 from ponto_abonos b join ponto_justificativas jj on jj.id = b.justificativa_id
                    where b.tecnico_id = p_tecnico and b.data = g.d::date and jj.motivo = 'atestado' and b.inicio is null
                      and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as atestado_dia,
           -- abono por liberalidade da empresa (lançado pelo gestor sem justificativa do funcionário)
           (select bool_or(b.inicio is null) or coalesce(sum(extract(epoch from b.fim - b.inicio) / 60), 0) > 0
              from ponto_abonos b where b.tecnico_id = p_tecnico and b.data = g.d::date and b.justificativa_id is null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as ab_livre
      from generate_series(v_ini, v_ult, interval '1 day') g(d)
     where v_ini <= v_ult
  ), calc as (
    select b.*,
           coalesce((b.j->>'trabalhado_min')::int, 0) as trab,
           coalesce((b.j->>'abonado_min')::int, 0) as abon,
           (b.j->>'intervalo_min')::int as intervalo,
           -- hora noturna reduzida: 52'30" valem 60 min de jornada
           round(b.noturno * 60 / 52.5)::int as noturno_red,
           case when b.dom_fer then 0 when b.sabado then v_sab else v_jorn end as bruto
      from base b
  ), dia as (
    select c.*,
           c.trab + (c.noturno_red - c.noturno) as trab_ef,
           case when c.dia < coalesce(v_marca, v_ult + 1) then 0
                when c.sabado and not c.dom_fer and c.j is null and v_abona then 0 else c.bruto end as esperado,
           (c.sabado and not c.dom_fer and c.j is null and v_abona and c.dia >= coalesce(v_marca, v_ult + 1)) as sabado_abonado
      from calc c
  ), conta as (
    select d.*,
           case when d.dom_fer then d.trab_ef else 0 end as he100,
           case when not d.dom_fer and d.trab_ef - d.bruto > v_tol then d.trab_ef - d.bruto else 0 end as he50,
           case when greatest(d.esperado - d.abon - d.trab_ef, 0) > v_tol and not d.atestado_dia
                then greatest(d.esperado - d.abon - d.trab_ef, 0) else 0 end as debito,
           case when d.trab > 360 then greatest(60 - coalesce(d.intervalo, 0), 0)
                when d.trab > 240 then greatest(15 - coalesce(d.intervalo, 0), 0) else 0 end as int_suprimido
      from dia d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('data', to_char(c.dia, 'YYYY-MM-DD')) || coalesce(c.j, '{}'::jsonb)
           || jsonb_build_object('previsto_min', c.esperado, 'he50_min', c.he50, 'he100_min', c.he100,
                                 'noturno_min', c.noturno, 'debito_min', c.debito, 'feriado', c.feriado)
           order by c.dia) filter (where c.j is not null or c.esperado > 0 or c.feriado is not null), '[]'::jsonb),
    jsonb_build_object(
      'a_pagar', jsonb_build_object(
        'he50_min', coalesce(sum(c.he50), 0), 'he100_min', coalesce(sum(c.he100), 0),
        'noturno_reduzidas_min', coalesce(sum(c.noturno_red), 0),
        'intervalo_nao_concedido_min', coalesce(sum(c.int_suprimido), 0)),
      'a_descontar', jsonb_build_object(
        'debito_min', coalesce(sum(c.debito), 0),
        'dias_sem_registro', count(*) filter (where c.debito > 0 and coalesce((c.j->>'marcacoes')::int, 0) = 0),
        'semanas_com_falta', count(distinct date_trunc('week', c.dia))
                               filter (where c.debito > 0 and coalesce((c.j->>'marcacoes')::int, 0) = 0)),
      'informativo', jsonb_build_object(
        'previsto_min', coalesce(sum(c.esperado), 0), 'trabalhado_min', coalesce(sum(c.trab), 0),
        'noturno_relogio_min', coalesce(sum(c.noturno), 0),
        'abonado_justificado_min', coalesce(sum(c.abon) filter (where c.ab_livre is not true), 0),
        'abonado_empresa_min', coalesce(sum(c.abon) filter (where c.ab_livre), 0),
        'sabados_sem_expediente', count(*) filter (where c.sabado_abonado),
        'dias_abonados_justificados', count(*) filter (where c.abon > 0 and c.ab_livre is not true),
        'dias_trabalhados', count(*) filter (where c.trab > 0),
        'dias_he_acima_2h', count(*) filter (where c.he50 > 120),
        'interjornada_curta', count(*) filter (where c.j->'alertas' ? 'interjornada_curta'),
        'registros', count(*) filter (where c.j is not null),
        'feriados', coalesce(jsonb_agg(distinct to_char(c.dia, 'DD/MM') || ' ' || c.feriado) filter (where c.feriado is not null), '[]'::jsonb)))
    into v_dias, v_res
    from conta c;

  -- mês sem nenhum dia com registro, escala ou abono: não há espelho a emitir (o emissor pula)
  v_reg := (v_res->'informativo'->>'registros')::int;
  if v_reg = 0 then v_dias := '[]'::jsonb; end if;

  -- marcações tratadas (Art. 84, V): incluídas e desconsideradas, com o motivo; sem o e-mail de quem tratou
  select coalesce(jsonb_agg(jsonb_build_object(
           'acao', a.acao, 'data', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'YYYY-MM-DD'),
           'hora', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'HH24:MI'),
           'tipo', coalesce(a.tipo, x.tipo, y.tipo), 'motivo', a.motivo)
           order by coalesce(a.momento, x.momento, y.momento), a.created_at), '[]'::jsonb) into v_aj
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and (coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso)::date between p_mes and v_fim;
  if v_reg = 0 then v_aj := '[]'::jsonb; end if;

  return jsonb_build_object(
    'empregador', jsonb_build_object('razao_social', v_t.razao_social, 'cnpj', v_t.cnpj),
    'trabalhador', jsonb_build_object('nome', v_t.nome, 'cpf', v_t.cpf, 'admissao', v_t.admissao, 'funcao', v_t.funcao),
    'competencia', to_char(p_mes, 'MM/YYYY'), 'de', p_mes, 'ate', v_fim,
    'jornada', jsonb_build_object('dia_util_min', v_jorn, 'sabado_min', v_sab,
                                  'intervalo_min', coalesce(nullif(fn_config('intervalo_min'), '')::int, 60)),
    'dias', v_dias, 'ajustes', v_aj,
    'totais', jsonb_build_object(
                 'trabalhado_min', v_res->'informativo'->'trabalhado_min',
                 'he_min', (v_res->'a_pagar'->>'he50_min')::int + (v_res->'a_pagar'->>'he100_min')::int,
                 'faltas', (select count(*) from jsonb_array_elements(v_dias) x where x->'alertas' ? 'falta'),
                 'atrasos', (select count(*) from jsonb_array_elements(v_dias) x where x->'alertas' ? 'atraso'),
                 'dias_abonados', (select count(*) from jsonb_array_elements(v_dias) x where x->>'abono' is not null)),
    'resumo', v_res,
    'avisos', jsonb_build_array(
      'Resumo para conferência das horas do mês. Os valores em reais são calculados pela folha de pagamento.',
      'Percentuais mínimos da CLT e da Constituição: hora extra 50%, domingo e feriado trabalhados em dobro (100%), adicional noturno 20% sobre a hora reduzida. A convenção coletiva da sua categoria pode prever percentuais ou regras diferentes.',
      'Não há banco de horas: horas extras são pagas e horas em débito são descontadas separadamente; uma não compensa a outra.',
      'Faltas sem justificativa podem levar ao desconto do descanso semanal remunerado daquela semana (Lei 605/1949, art. 6º).',
      'Dias e horas abonados não são descontados.' || case when v_abona then ' Sábados sem expediente são abonados por decisão da empresa.' else '' end,
      'Feriados considerados: os do calendário cadastrado pela empresa.',
      'Sua assinatura confirma que você recebeu e conferiu este espelho. Se algum horário estiver errado, peça a correção pelo app antes de assinar.'));
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
