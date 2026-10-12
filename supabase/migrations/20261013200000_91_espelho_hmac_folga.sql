-- Migration 91 (13/10/2026): decisões do responsável sobre o espelho mensal (decisão 84).
-- 1. A assinatura do funcionário passa a ser amarrada por HMAC-SHA256 com chave no Vault (gerada no próprio
--    banco, nunca no repositório): quem só altera a tabela não consegue refazer o hash de uma assinatura. Não
--    há espelho assinado em nenhum ambiente (conferido em 13/10), então nenhum hash antigo deixa de conferir.
-- 2. Folga compensatória: o gestor lança a folga de um domingo ou feriado trabalhado; o dia de folga é
--    abonado e o domingo ou feriado deixa de sair a 100% (Lei 605/1949, art. 9º; Súmula 146 do TST).

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'ESPELHO_ASSINATURA') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'ESPELHO_ASSINATURA',
                                'Chave do HMAC da assinatura do espelho de ponto (decisão 84). Guardar cópia fora do Supabase.');
  end if;
end $$;

-- Hash da assinatura: HMAC-SHA256 do hash do espelho, da imagem, da hora (UTC, microssegundos), do IP e do
-- aparelho, com a chave do Vault. Mesma assinatura da função (as chamadoras não mudam)
create or replace function fn_ponto_assinatura_hash(p_sha_espelho text, p_png text, p_assinado_em timestamptz, p_origem jsonb)
returns text language plpgsql stable set search_path = public, extensions as $function$
declare
  v_chave text := fn_segredo('ESPELHO_ASSINATURA');
begin
  if coalesce(v_chave, '') = '' then raise exception 'Assinatura do espelho sem chave.'; end if;
  return encode(extensions.hmac(convert_to(
    p_sha_espelho || '|' || p_png || '|' || to_char(p_assinado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
    || '|' || coalesce(p_origem ->> 'ip', '') || '|' || coalesce(p_origem ->> 'aparelho', ''), 'UTF8'),
    convert_to(v_chave, 'UTF8'), 'sha256'), 'hex');
end $function$;

-- Folga compensatória ---------------------------------------------------------------------------------
insert into ponto_motivos (codigo, grupo, nome, base_legal, abrange, quantidade, unidade, janela, exige_anexo, saude, ativo, ordem) values
  ('folga_compensatoria', 'ponto', 'Folga compensatória de domingo ou feriado trabalhado',
   'Lei 605/1949, art. 9º; Súmula 146 e OJ 410 da SDI-1 do TST (folga na mesma semana)', 'gestor',
   null, null, null, false, false, false, 4)
on conflict (codigo) do nothing;

alter table ponto_abonos add column if not exists folga_de date;
comment on column ponto_abonos.folga_de is 'Folga compensatória: o domingo ou feriado trabalhado que este dia de folga compensa (decisão 84).';
create index if not exists ponto_abonos_folga_idx on ponto_abonos (tecnico_id, folga_de) where folga_de is not null;

-- O gestor lança a folga: dia inteiro abonado, ligado ao domingo ou feriado trabalhado. A folga fica a até 6
-- dias do trabalho (mesma semana: depois do 7º dia seguido o repouso é pago em dobro, OJ 410)
create or replace function app_ponto_folga_compensatoria(p_tecnico uuid, p_folga date, p_trabalhado date)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_dom_fer boolean;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  -- uma folga por domingo ou feriado: a trava da linha do funcionário evita dois lançamentos ao mesmo tempo
  perform 1 from tecnicos where id = p_tecnico for update;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_folga is null or p_trabalhado is null then raise exception 'Informe o domingo ou feriado trabalhado e o dia da folga.'; end if;
  if p_trabalhado > v_hoje or p_trabalhado < v_hoje - 62 then
    raise exception 'O domingo ou feriado trabalhado precisa estar nos últimos 62 dias.';
  end if;
  v_dom_fer := extract(isodow from p_trabalhado) = 7
               or exists (select 1 from feriados f where f.data = p_trabalhado and f.abrangencia <> 'facultativo');
  if not v_dom_fer then raise exception 'O dia trabalhado precisa ser domingo ou feriado.'; end if;
  if coalesce((fn_ponto_jornada_dia(p_tecnico, p_trabalhado) ->> 'trabalhado_min')::int, 0) = 0 then
    raise exception 'Não há trabalho registrado no ponto em %.', to_char(p_trabalhado, 'DD/MM');
  end if;
  if extract(isodow from p_folga) = 7
     or exists (select 1 from feriados f where f.data = p_folga and f.abrangencia <> 'facultativo') then
    raise exception 'A folga precisa cair em dia de trabalho, não em domingo ou feriado.';
  end if;
  if abs(p_folga - p_trabalhado) > 6 then
    raise exception 'A folga precisa ficar na mesma semana do trabalho (até 6 dias de distância).';
  end if;
  if p_folga > v_hoje + 7 then raise exception 'Folga só até 7 dias à frente.'; end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.folga_de = p_trabalhado and a.estorno_de is null
              and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'O trabalho de % já tem folga compensatória.', to_char(p_trabalhado, 'DD/MM');
  end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.data = p_folga and a.inicio is null
              and a.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'O dia % já está abonado inteiro.', to_char(p_folga, 'DD/MM');
  end if;
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor, folga_de)
  values (v_tec.empresa_id, p_tecnico, p_folga,
          'Folga compensatória do trabalho em ' || to_char(p_trabalhado, 'DD/MM/YYYY') || ' (Lei 605/1949, art. 9º)',
          v_email, p_trabalhado) returning id into v_id;
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, '📝 *Ponto · folga compensatória*' || E'\n' || 'Sua folga de '
      || to_char(p_folga, 'DD/MM') || ' compensa o trabalho de ' || to_char(p_trabalhado, 'DD/MM')
      || ': esse dia não é descontado.');
  end if;
  return jsonb_build_object('id', v_id, 'folga', to_char(p_folga, 'DD/MM/YYYY'), 'trabalhado', to_char(p_trabalhado, 'DD/MM/YYYY'));
end $function$;

-- Conteúdo do espelho: a folga compensatória tira o 100% do domingo ou feriado compensado (decisão 84) e não
-- conta como abono por liberalidade. Base: migration 90 (decisão 83).
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
               and b.folga_de is null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as ab_livre,
           -- folga compensatória (decisão 84): o dia de folga e o domingo ou feriado que ela compensa
           (select min(to_char(b.folga_de, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.data = g.d::date and b.folga_de is not null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as folga_de,
           (select min(to_char(b.data, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.folga_de = g.d::date
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as compensado_em
      from generate_series(v_ini, v_ult, interval '1 day') g(d)
     where v_ini <= v_ult
  ), calc as (
    select b.*,
           coalesce((b.j->>'trabalhado_min')::int, 0) as trab,
           coalesce((b.j->>'abonado_min')::int, 0) as abon,
           (b.j->>'intervalo_min')::int as intervalo,
           -- hora noturna reduzida: 52'30" valem 60 min de jornada
           round(b.noturno * 60 / 52.5)::int as noturno_red,
           -- domingo ou feriado compensado com folga é trabalho comum: só o que passa da jornada é extra
           case when b.dom_fer and b.compensado_em is null then 0 when b.dom_fer then v_jorn
                when b.sabado then v_sab else v_jorn end as bruto
      from base b
  ), dia as (
    select c.*,
           c.trab + (c.noturno_red - c.noturno) as trab_ef,
           case when c.dia < coalesce(v_marca, v_ult + 1) or c.dom_fer then 0
                when c.sabado and not c.dom_fer and c.j is null and v_abona then 0 else c.bruto end as esperado,
           (c.sabado and not c.dom_fer and c.j is null and v_abona and c.dia >= coalesce(v_marca, v_ult + 1)) as sabado_abonado
      from calc c
  ), conta as (
    select d.*,
           case when d.dom_fer and d.compensado_em is null then d.trab_ef else 0 end as he100,
           case when (not d.dom_fer or d.compensado_em is not null) and d.trab_ef - d.bruto > v_tol
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
                                 'folga_de', c.folga_de, 'compensado_em', c.compensado_em)
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
        'abonado_empresa_min', coalesce(sum(c.abon) filter (where c.ab_livre), 0),
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
      'Percentuais mínimos da CLT e da Constituição: hora extra 50%, domingo e feriado trabalhados em dobro (100%) quando não há folga compensatória, adicional noturno 20% sobre a hora reduzida. A convenção coletiva da sua categoria pode prever percentuais ou regras diferentes.',
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
