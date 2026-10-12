-- Migration 85 (13/10/2026): painel gerencial de aderência da escala e do ponto (backlog 099, decisão 78).
-- Prova de valor pedida pelo responsável: por período, quanto da escala se resolve pelo WhatsApp, quanto
-- precisou da URA, e como está a aderência do ponto (ajustes, abonos e desvios da jornada da CLT). Só
-- números agregados: nenhum nome de funcionário sai desta função, e o papel leitura vê o mesmo.
--
-- Jornada de referência (CLT art. 58 e Constituição art. 7º, XIII): segunda a sexta 8 h (jornada_min),
-- sábado 4 h (ponto_jornada_sabado_min), domingo e feriado 0 — 44 h na semana. As 220 h mensais (CLT
-- art. 64) são o divisor do salário, não limite de horas: o mês aparece como saldo (trabalhado menos
-- esperado). Sábado sem expediente conta como abonado quando ponto_sabado_sem_expediente_abona = 'true'
-- (decisão gerencial interna da Infoxtec). Abono lançado desconta do esperado. O dia de hoje e a semana
-- em curso ficam de fora (ainda não fecharam).

insert into config (chave, valor, descricao) values
  ('ponto_jornada_sabado_min', '240', 'Minutos esperados no sábado (meio período). Segunda a sexta usa jornada_min'),
  ('ponto_sabado_sem_expediente_abona', 'true',
   'true: sábado sem nenhuma marcação é abonado (decisão gerencial interna); false: conta como horas faltando')
on conflict (chave) do nothing;

create or replace function app_painel_gerencial(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v_ontem   date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_jornada int  := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_sabado  int  := coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240);
  v_abona   boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_tol     int  := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
  v_escala  jsonb;
  v_ponto   jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
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
     where not e.teste and e.data_servico between p_de and p_ate
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
                  where not e.teste and e.data_servico between p_de and p_ate),
    'ligacoes_atendidas', (select count(*) from ligacoes l join escalas e on e.id = l.escala_id
                            where not e.teste and e.data_servico between p_de and p_ate and l.atendida_em is not null))
    into v_escala
    from esc;

  -- Ponto: funcionários do ponto (CPF e empresa), cada um só entre a admissão (ou o cadastro) e o
  -- desligamento, dia a dia até ontem. Quem saiu no período entra até o desligamento
  with t as (
    select id, greatest(p_de, coalesce(admissao, created_at::date)) as ini,
           least(p_ate, v_ontem, coalesce(desligado_em, p_ate)) as fim
      from tecnicos
     where not perfil_teste and cpf is not null and empresa_id is not null
       and (ativo or desligado_em >= p_de)
  ), jd as (
    select t.id as tec, g::date as dia, fn_ponto_jornada_dia(t.id, g::date) as j
      from t cross join lateral generate_series(t.ini, t.fim, interval '1 day') g
     where t.ini <= t.fim
  ), base as (
    select tec, dia, j,
           coalesce((j->>'trabalhado_min')::int, 0) as trab,
           coalesce((j->>'abonado_min')::int, 0) as abon,
           coalesce((j->>'marcacoes')::int, 0) as marc,
           -- jornada do dia: útil 8 h, sábado 4 h, domingo e feriado 0 (ponto facultativo não zera)
           case when extract(isodow from dia) = 7
                  or exists (select 1 from feriados f where f.data = dia and f.abrangencia <> 'facultativo') then 0
                when extract(isodow from dia) = 6 then v_sabado
                else v_jornada end as bruto
      from jd
  ), dia as (
    -- sábado sem expediente (nem marcação, nem escala, nem abono: o dia não existe para o ponto) é
    -- abonado pela decisão interna; sábado com escala e sem marcação continua devido
    select *, case when extract(isodow from dia) = 6 and j is null and v_abona then 0 else bruto end as esperado
      from base
  ), semana as (
    -- só semanas inteiras (segunda a domingo) dentro do período e já fechadas
    select tec, date_trunc('week', dia)::date as ini, sum(trab) as trab, sum(greatest(esperado - abon, 0)) as esp,
           count(*) filter (where esperado > 0) as dias_uteis
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
    -- hora extra: o que passa da jornada do próprio dia (sábado acima de 4 h; domingo e feriado, tudo)
    'minutos_hora_extra', (select coalesce(sum(greatest(trab - bruto, 0)), 0) from dia),
    -- saldo: trabalhado menos o esperado (abonos descontados); negativo é hora faltando
    'saldo_min', (select coalesce(sum(trab), 0) - coalesce(sum(greatest(esperado - abon, 0)), 0) from dia),
    'alertas', coalesce((select jsonb_object_agg(a, n) from (
                  select a, count(*) as n from dia, jsonb_array_elements_text(coalesce(j->'alertas', '[]'::jsonb)) a
                   group by a) x), '{}'::jsonb),
    'semanas', (select count(*) from semana),
    'semanas_acima_44h', (select count(*) from semana where trab > 44 * 60),
    'semanas_abaixo_esperado', (select count(*) from semana where trab < esp - v_tol * dias_uteis),
    'jornada', jsonb_build_object('dia_util_min', v_jornada, 'sabado_min', v_sabado,
                                  'sabado_sem_expediente_abona', v_abona, 'semana_max_min', 44 * 60,
                                  'tolerancia_dia_min', v_tol))
    into v_ponto;

  return jsonb_build_object('de', p_de, 'ate', p_ate, 'apurado_ate', least(p_ate, v_ontem),
                            'escala', v_escala, 'ponto', v_ponto);
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
