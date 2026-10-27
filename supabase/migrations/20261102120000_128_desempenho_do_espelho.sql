-- Desempenho do espelho do ponto (achado 3 da revisão de 25/10). Medido com 50 funcionários × 1 mês:
--   app_ponto_espelho 14,3 s → 0,22 s; conteúdo do espelho (1 funcionário) 738 → 32 ms; prévia da folha 642 → 63 ms;
--   carga excedida 5,0 → 0,26 s; indicadores 1,3 → 0,34 s.
-- 1) A jornada do dia era recalculada a cada coluna lida: o PostgreSQL desdobra a CTE e chamava fn_ponto_jornada_dia
--    até 21 vezes por dia. As CTEs que chamam a jornada passam a "materialized" (uma chamada por dia).
-- 2) fn_ponto_marcacoes_efetivas perde o "set search_path" (tabelas com o esquema escrito) para o PostgreSQL incorporá-la
--    na consulta que a chama. É language sql, sem security definer: o T55 a lista como exceção nomeada.
-- Nenhuma regra muda: os resultados são os mesmos (regressão inteira).

set lock_timeout = '5s';

-- sem "set search_path" (tabelas com o esquema escrito): o PostgreSQL incorpora a função na consulta que a chama
create or replace function interno.fn_ponto_marcacoes_efetivas(p_tecnico uuid, p_ini timestamptz, p_fim timestamptz)
 returns table(tipo text, momento timestamptz, nsr bigint, ajuste boolean)
 language sql stable
as $function$
  select m.tipo, m.momento, m.nsr, false
    from interno.ponto_marcacoes m
   where m.tecnico_id = p_tecnico and m.momento >= p_ini and m.momento < p_fim
     and not exists (select 1 from interno.ponto_ajustes a where a.marcacao_id = m.id and a.acao = 'desconsiderar')
  union all
  select a.tipo, a.momento, null::bigint, true
    from interno.ponto_ajustes a
   where a.tecnico_id = p_tecnico and a.acao = 'incluir' and a.momento >= p_ini and a.momento < p_fim
     and not exists (select 1 from interno.ponto_ajustes d where d.ajuste_id = a.id and d.acao = 'desconsiderar')
$function$;

CREATE OR REPLACE FUNCTION public.app_ponto_espelho(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(tecnico_id uuid, tecnico text, data date, escala_hora text, entrada text, saida_almoco text, volta_almoco text, saida text, trabalhado_min integer, intervalo_min integer, he_min integer, atraso_min integer, interjornada_min integer, alertas text[], ajustes integer, abono text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    with dias as (
      select distinct m.tecnico_id as tid, (m.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date as dia
        from ponto_marcacoes m join empresas e on e.id = m.empresa_id
       where m.momento >= p_de::timestamp - interval '1 day' and m.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or m.tecnico_id = p_tecnico) and m.conta_id = v_conta
      union
      select a.tecnico_id, (a.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date
        from ponto_ajustes a join empresas e on e.id = a.empresa_id
       where a.acao = 'incluir'
         and a.momento >= p_de::timestamp - interval '1 day' and a.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or a.tecnico_id = p_tecnico) and a.conta_id = v_conta
      union
      -- dia com escala (falta aparece) e dia com abono
      select s.tecnico_id, s.data_servico
        from escalas s join tecnicos t on t.id = s.tecnico_id and t.empresa_id is not null and t.cpf is not null
       where s.data_servico between p_de and p_ate and s.status not in ('cancelada', 'recusada', 'rascunho')
         and (p_tecnico is null or s.tecnico_id = p_tecnico) and t.conta_id = v_conta
      union
      select b.tecnico_id, b.data from ponto_abonos b
       where b.data between p_de and p_ate and (p_tecnico is null or b.tecnico_id = p_tecnico) and b.conta_id = v_conta
    ), j as materialized (   -- uma jornada por dia: sem isso o PostgreSQL recalcula a função a cada coluna lida
      select d.tid, d.dia, fn_ponto_jornada_dia(d.tid, d.dia) as x from dias d where d.dia between p_de and p_ate
    )
    select j.tid, t.nome, j.dia, j.x->>'escala_hora', j.x->>'entrada', j.x->>'saida_almoco', j.x->>'volta_almoco',
           j.x->>'saida', (j.x->>'trabalhado_min')::int, (j.x->>'intervalo_min')::int, (j.x->>'he_min')::int,
           (j.x->>'atraso_min')::int, (j.x->>'interjornada_min')::int,
           array(select jsonb_array_elements_text(j.x->'alertas')), coalesce((j.x->>'ajustes')::int, 0), j.x->>'abono'
      from j join tecnicos t on t.id = j.tid
     where j.x is not null
     order by j.dia desc, t.nome;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_ponto_espelho_conteudo(p_tecnico uuid, p_mes date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  v_escalas jsonb;
begin
  select t.nome, t.cpf, t.admissao, t.funcao, t.created_at::date as criado, t.desligado_em,
         e.razao_social, e.cnpj, e.cei_caepf_cno, e.endereco, e.cidade, e.uf,
         coalesce(e.exige_registro_intervalo, false) as exige_intervalo,
         coalesce(e.fuso, 'America/Bahia') as fuso into v_t
    from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  -- lista do início do vínculo no mês; cobra jornada só a partir da primeira marcação do funcionário (dia
  -- anterior à implantação do ponto não vira débito; quem nunca marcou não tem débito)
  v_ini := greatest(p_mes, coalesce(v_t.admissao, v_t.criado));
  v_marca := (select min(m.momento at time zone v_t.fuso)::date from ponto_marcacoes m where m.tecnico_id = p_tecnico);
  v_ult := least(v_fim, coalesce(v_t.desligado_em, v_fim));

  with base as materialized (   -- uma jornada por dia: sem isso cada coluna lida recalcula as funções
    select g.d::date as dia, fn_ponto_jornada_dia(p_tecnico, g.d::date) as j,
           fn_carga_dia(p_tecnico, g.d::date) as esc,
           fn_ponto_noturno_dia(p_tecnico, g.d::date, v_t.fuso) as noturno,
           extract(isodow from g.d) = 6 as sabado,
           (select f.nome from feriados f where f.data = g.d::date and f.abrangencia <> 'facultativo' limit 1) as feriado,
           -- atestado de dia inteiro nunca gera débito (o parcial já desconta as horas pelo abono)
           exists (select 1 from ponto_abonos b join ponto_justificativas jj on jj.id = b.justificativa_id
                    where b.tecnico_id = p_tecnico and b.data = g.d::date and jj.motivo = 'atestado' and b.inicio is null
                      and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as atestado_dia,
           -- abono por liberalidade da empresa (lançado pelo gestor sem justificativa do funcionário)
           (select bool_or(b.inicio is null) or coalesce(sum(extract(epoch from b.fim - b.inicio) / 60), 0) > 0
              from ponto_abonos b where b.tecnico_id = p_tecnico and b.data = g.d::date and b.justificativa_id is null
               and b.folga_de is null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as ab_livre,
           -- folga compensatória (decisão 84): o dia de folga e o domingo ou feriado que ela compensa
           (select min(to_char(b.folga_de, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.data = g.d::date and b.folga_de is not null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as folga_de,
           -- só compensa a folga que já aconteceu sem trabalho; folga futura na emissão mantém o 100% (a favor do
           -- funcionário: o gestor reemite depois)
           (select min(to_char(b.data, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.folga_de = g.d::date
               and b.data <= (now() at time zone v_t.fuso)::date
               and coalesce((fn_ponto_jornada_dia(p_tecnico, b.data) ->> 'trabalhado_min')::int, 0) = 0
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as compensado_em
      from generate_series(v_ini, v_ult, interval '1 day') g(d)
     where v_ini <= v_ult
  ), calc0 as (
    -- jornada do dia pela escala (decisão 91): DSR e feriado trabalhados a 100%; outra folga da escala, 50%;
    -- 12x36 tem DSR e feriados compensados (CLT art. 59-A, parágrafo único). Sem escala, a regra de antes
    -- (8 h de segunda a sexta, 4 h no sábado, domingo de repouso)
    select b.*, (b.esc->>'minutos')::int as contr,
           b.esc->>'tipo' = '12x36' as plantonista,
           case when b.esc->>'tipo' = '12x36' then false
                else coalesce((b.esc->>'repouso')::boolean, false) or b.feriado is not null end as repouso_pago
      from base b
  ), calc as (
    select b.*,
           coalesce((b.j->>'trabalhado_min')::int, 0) as trab,
           coalesce((b.j->>'abonado_min')::int, 0) as abon,
           (b.j->>'intervalo_min')::int as intervalo,
           -- hora noturna reduzida: 52'30" valem 60 min de jornada
           round(b.noturno * 60 / 52.5)::int as noturno_red,
           -- domingo ou feriado compensado com folga é trabalho comum: só o que passa da jornada é extra
           case when b.repouso_pago and b.compensado_em is null then 0 when b.repouso_pago then coalesce(nullif(b.contr, 0), v_jorn)
                else b.contr end as bruto
      from calc0 b
  ), dia as (
    select c.*,
           c.trab + (c.noturno_red - c.noturno) as trab_ef,
           case when c.dia < coalesce(v_marca, v_ult + 1) or c.repouso_pago or c.feriado is not null then 0
                when c.sabado and c.contr > 0 and c.j is null and v_abona then 0 else c.bruto end as esperado,
           (c.sabado and not c.repouso_pago and c.contr > 0 and c.j is null and v_abona and c.dia >= coalesce(v_marca, v_ult + 1)) as sabado_abonado
      from calc c
  ), conta as (
    select d.*,
           case when d.repouso_pago and d.compensado_em is null then d.trab_ef else 0 end as he100,
           case when (not d.repouso_pago or d.compensado_em is not null) and d.trab_ef - d.bruto > v_tol
                then d.trab_ef - d.bruto else 0 end as he50,
           case when greatest(d.esperado - d.abon - d.trab_ef, 0) > v_tol and not d.atestado_dia
                then greatest(d.esperado - d.abon - d.trab_ef, 0) else 0 end as debito,
           case when d.trab > 360 then greatest(60 - coalesce(d.intervalo, 0), 0)
                when d.trab > 240 then greatest(15 - coalesce(d.intervalo, 0), 0) else 0 end as int_suprimido
      from dia d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('data', to_char(c.dia, 'YYYY-MM-DD')) || coalesce(c.j, '{}'::jsonb)
           || jsonb_build_object('previsto_min', c.esperado, 'he50_min', c.he50, 'he100_min', c.he100,
                                 'noturno_min', c.noturno, 'debito_min', c.debito, 'feriado', c.feriado,
                                 'folga_de', c.folga_de, 'compensado_em', c.compensado_em,
                                 'jornada_dia_min', c.contr, 'escala', c.esc->>'escala',
                                 -- duração da jornada com a hora noturna reduzida (Art. 84, VI)
                                 'duracao_min', c.trab_ef,
                                 'repouso', case when c.plantonista then null when c.feriado is not null then 'feriado'
                                                 when (c.esc->>'repouso')::boolean then 'dsr' when c.contr = 0 then 'folga' end)
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
        'abonado_justificado_min', coalesce(sum(c.abon) filter (where c.ab_livre is not true and c.folga_de is null), 0),
        'abonado_empresa_min', coalesce(sum(c.abon) filter (where c.ab_livre and c.folga_de is null), 0),
        'sabados_sem_expediente', count(*) filter (where c.sabado_abonado),
        'dias_abonados_justificados', count(*) filter (where c.abon > 0 and c.ab_livre is not true and c.folga_de is null),
        'folgas_compensatorias', count(*) filter (where c.folga_de is not null),
        'domingos_feriados_compensados', count(*) filter (where c.compensado_em is not null and c.trab > 0),
        'dias_trabalhados', count(*) filter (where c.trab > 0),
        'dias_he_acima_2h', count(*) filter (where c.he50 > 120),
        'interjornada_curta', count(*) filter (where c.j->'alertas' ? 'interjornada_curta'),
        'registros', count(*) filter (where c.j is not null),
        'feriados', coalesce(jsonb_agg(distinct to_char(c.dia, 'DD/MM') || ' ' || c.feriado) filter (where c.feriado is not null), '[]'::jsonb)))
    into v_dias, v_res
    from conta c;

  -- escalas que valeram no mês, com o horário e a jornada contratual (Art. 84, IV)
  select coalesce(jsonb_agg(jsonb_build_object('escala', x.escala, 'de', to_char(x.de, 'DD/MM'), 'ate', to_char(x.ate, 'DD/MM'),
                                               'tipo', x.tipo, 'entrada', to_char(x.entrada, 'HH24:MI'),
                                               'intervalo_min', x.intervalo_min, 'semanal_min', x.semanal_min,
                                               'plantao_min', x.plantao_min, 'minutos', x.minutos) order by x.de), '[]'::jsonb)
    into v_escalas
    from (select y.escala, y.tipo, y.entrada, y.intervalo_min, y.semanal_min, y.plantao_min, y.minutos,
                 min(y.d) as de, max(y.d) as ate
            from (select g.d::date as d, ch.nome as escala, ch.tipo, ch.entrada, ch.intervalo_min, ch.semanal_min,
                         ch.plantao_min, to_jsonb(ch.minutos) as minutos
                    from generate_series(v_ini, v_ult, interval '1 day') g(d)
                    join carga_atribuicoes a on a.id = fn_carga_atribuicao(p_tecnico, g.d::date)
                    join cargas_horarias ch on ch.id = a.carga_id
                   where v_ini <= v_ult) y
           group by y.escala, y.tipo, y.entrada, y.intervalo_min, y.semanal_min, y.plantao_min, y.minutos) x;

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
    'documento', 'Espelho de Ponto Eletrônico (Portaria MTP 671/2021, art. 84)',
    'empregador', jsonb_build_object('razao_social', v_t.razao_social, 'cnpj', v_t.cnpj,
                                     'cei_caepf_cno', v_t.cei_caepf_cno,
                                     'endereco', concat_ws(' - ', v_t.endereco, concat_ws('/', v_t.cidade, v_t.uf))),
    'trabalhador', jsonb_build_object('nome', v_t.nome, 'cpf', v_t.cpf, 'admissao', v_t.admissao, 'funcao', v_t.funcao),
    'competencia', to_char(p_mes, 'MM/YYYY'), 'de', p_mes, 'ate', v_fim,
    -- pré-assinalação do intervalo (CLT art. 74, §2º; Art. 84, V): empresa que não exige o registro
    'jornada', jsonb_build_object('dia_util_min', v_jorn, 'sabado_min', v_sab, 'escalas', v_escalas,
                                  'pre_assinalado', not v_t.exige_intervalo,
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
      'Percentuais mínimos da CLT e da Constituição: hora extra 50% (inclusive em folga da escala que não é o descanso semanal), descanso semanal (o domingo ou o dia da sua escala) e feriado trabalhados em dobro (100%) quando não há folga compensatória (na 12x36, descanso e feriados já são compensados pela própria escala), adicional noturno 20% sobre a hora reduzida. A convenção coletiva da sua categoria pode prever percentuais ou regras diferentes.',
      'Não há banco de horas: horas extras são pagas e horas em débito são descontadas separadamente; uma não compensa a outra.',
      'Faltas sem justificativa podem levar ao desconto do descanso semanal remunerado daquela semana (Lei 605/1949, art. 6º).',
      'Dias e horas abonados não são descontados.' || case when v_abona then ' Sábados sem expediente são abonados por decisão da empresa.' else '' end,
      'Feriados considerados: os do calendário cadastrado pela empresa.',
      'Sua assinatura registra que você recebeu e conferiu este espelho (ciência). Se algum horário estiver errado, peça a correção pelo app antes de assinar.',
      'Marcações registradas são as do relógio do ponto; marcações tratadas (incluídas, desconsideradas ou pré-assinaladas) aparecem separadas, com o motivo.'));
end $function$
;

CREATE OR REPLACE FUNCTION public.app_carga_excedida(p_mes date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  ), d as materialized (   -- uma jornada por dia: sem isso cada coluna lida recalcula a função
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
end $function$
;

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
