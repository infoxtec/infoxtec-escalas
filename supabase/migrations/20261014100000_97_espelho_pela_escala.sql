-- Migration 97 (14/10/2026): espelho de ponto pela escala do funcionário (backlog 104, etapa 2; decisão 91).
-- O espelho mensal (débito, hora extra 50% e 100%) passa a usar a jornada de cada dia na escala vigente do
-- funcionário (funcionário > time > empresa), em vez da regra única. Parecer do juridico (decisão 58):
--  - dia de trabalho da escala: débito = jornada do dia − (trabalhado + abonos); HE 50% = trabalhado − jornada;
--    tolerância de 10 min (CLT art. 58, § 1º);
--  - descanso semanal remunerado (DSR) trabalhado: 100% (Lei 605/49, art. 9º; Súmula 146 do TST), salvo folga
--    compensatória (decisão 84). A escala passa a dizer qual folga é o DSR (dsr_dia; domingo quando é folga);
--  - outra folga da escala trabalhada (ex.: sábado na 5x2): HE 50%; domingo que a escala marca como trabalho: dia normal;
--  - feriado: não trabalhado é repouso (sem débito); trabalhado, 100% salvo folga compensatória;
--  - 12x36: DSR e feriados já compensados (CLT art. 59-A, parágrafo único): só o que passa do plantão é HE 50%.
-- Sem escala atribuída (antes de 13/10 ou funcionário sem empresa), vale a regra de antes: 8 h de segunda a
-- sexta, 4 h no sábado e domingo de repouso. A "Jornada padrão" que a migration 94 atribuiu a cada empregadora
-- ([8 h × 5, 4 h, 0], DSR no domingo) dá os mesmos números (conferido em setembro e outubro na homologação). Antes
-- de aplicar na produção, conferir se há outra escala atribuída (risco do art. 468 da CLT). Espelho já emitido não
-- muda (o conteúdo é congelado na emissão). Feriado não trabalhado não é débito, nem na 12x36.

-- DSR da escala ---------------------------------------------------------------------------------------------
alter table cargas_horarias add column if not exists dsr_dia int check (dsr_dia between 1 and 7);
comment on column cargas_horarias.dsr_dia is 'Dia do descanso semanal remunerado (1 = segunda … 7 = domingo); um dos dias de folga. Nulo na 12x36 (decisão 91).';
-- escalas já salvas: o domingo quando é folga; senão, a primeira folga da semana (a escala salva não muda; a
-- trava sai só para preencher o campo novo)
do $$
begin
  alter table cargas_horarias disable trigger trg_cargas_horarias_imutavel;
  update cargas_horarias c
     set dsr_dia = case when c.minutos[7] = 0 then 7 else (select min(i) from generate_series(1, 7) i where c.minutos[i] = 0) end
   where c.tipo <> '12x36' and c.dsr_dia is null;
  alter table cargas_horarias enable trigger trg_cargas_horarias_imutavel;
end $$;

-- Jornada do dia e se é o DSR, pela escala vigente (sem escala: a regra de antes)
create or replace function fn_carga_dia(p_tecnico uuid, p_data date)
returns jsonb language plpgsql stable set search_path = public, extensions as $function$
declare
  v_at  uuid := fn_carga_atribuicao(p_tecnico, p_data);
  v_c   cargas_horarias;
  v_ini date;
  v_dow int := extract(isodow from p_data)::int;
begin
  if v_at is null then
    return jsonb_build_object('minutos', fn_carga_minutos_dia(p_tecnico, p_data), 'repouso', v_dow = 7,
                              'tipo', 'padrao', 'escala', null);
  end if;
  select c.* into v_c from carga_atribuicoes a join cargas_horarias c on c.id = a.carga_id where a.id = v_at;
  select a.inicio into v_ini from carga_atribuicoes a where a.id = v_at;
  if v_c.tipo = '12x36' then
    return jsonb_build_object('minutos', case when (p_data - v_ini) % 2 = 0 then v_c.plantao_min else 0 end,
                              'repouso', false, 'tipo', '12x36', 'escala', v_c.nome);
  end if;
  return jsonb_build_object('minutos', v_c.minutos[v_dow], 'repouso', v_dow = coalesce(v_c.dsr_dia, 7),
                            'tipo', v_c.tipo, 'escala', v_c.nome);
end $function$;

-- Salvar escala (recriada da migration 94, conferida por MD5): guarda o dia do DSR
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
  v_texto text;
  v_em    timestamptz := now();
  v_min   int[];
  v_dsr   int;
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
            coalesce(nullif(v_usu.nome, ''), v_email), v_email, v_usu.papel, v_em);
  end if;
  return v_id;
end $function$;

-- Lista de escalas (recriada da migration 94): ganha o dia do DSR; o retorno muda, então a versão antiga sai
drop function if exists app_cargas(uuid);
create or replace function app_cargas(p_empresa uuid default null)
returns table (id uuid, empresa_id uuid, empresa text, nome text, tipo text, minutos int[], plantao_min int,
               intervalo_min int, entrada text, semanal_min int, riscos jsonb, ativo boolean, criado_por text,
               created_at timestamptz, atribuicoes bigint, aceite_nome text, aceite_em timestamptz,
               aceite_texto text, aceite_sha256 text, dsr_dia int)
language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  -- leitura não vê quem fez nem o termo (padrão das migrations 65 e 66; o termo é prova do empregador)
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
begin
  return query
    select c.id, c.empresa_id, coalesce(m.nome_fantasia, m.razao_social), c.nome, c.tipo, c.minutos, c.plantao_min,
           c.intervalo_min, to_char(c.entrada, 'HH24:MI'), c.semanal_min, c.riscos, c.ativo,
           case when v_leitura then null else c.criado_por end, c.created_at,
           (select count(*) from carga_atribuicoes a where a.carga_id = c.id and a.cancelada_em is null and a.fim >= current_date),
           case when v_leitura then null else k.nome end, k.aceito_em,
           case when v_leitura then null else k.texto end, case when v_leitura then null else k.sha256 end, c.dsr_dia
      from cargas_horarias c join empresas m on m.id = c.empresa_id
      left join carga_aceites k on k.carga_id = c.id
     where p_empresa is null or c.empresa_id = p_empresa
     order by coalesce(m.nome_fantasia, m.razao_social), c.ativo desc, c.nome;
end $function$;

-- Modelos (recriada da migration 94): DSR no domingo
create or replace function app_cargas_modelos()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return jsonb_build_array(
    jsonb_build_object('nome', '44h 6x1 (8h + 4h sábado)', 'tipo', 'semanal', 'minutos', jsonb_build_array(480,480,480,480,480,240,0), 'intervalo_min', 60, 'dsr_dia', 7),
    jsonb_build_object('nome', '44h 6x1 (7h20)', 'tipo', 'semanal', 'minutos', jsonb_build_array(440,440,440,440,440,440,0), 'intervalo_min', 60, 'dsr_dia', 7),
    jsonb_build_object('nome', '44h 5x2 (8h48)', 'tipo', 'semanal', 'minutos', jsonb_build_array(528,528,528,528,528,0,0), 'intervalo_min', 60, 'dsr_dia', 7),
    jsonb_build_object('nome', '40h 5x2 (8h)', 'tipo', 'semanal', 'minutos', jsonb_build_array(480,480,480,480,480,0,0), 'intervalo_min', 60, 'dsr_dia', 7),
    jsonb_build_object('nome', '36h 6x1 (6h)', 'tipo', 'semanal', 'minutos', jsonb_build_array(360,360,360,360,360,360,0), 'intervalo_min', 15, 'dsr_dia', 7),
    jsonb_build_object('nome', '12x36', 'tipo', '12x36', 'plantao_min', 720, 'intervalo_min', 60),
    jsonb_build_object('nome', 'Turno de revezamento 6h', 'tipo', 'revezamento', 'minutos', jsonb_build_array(360,360,360,360,360,360,0), 'intervalo_min', 15, 'dsr_dia', 7));
end $function$;

-- Conteúdo do espelho (recriada da migration 91, conferida por MD5): jornada do dia pela escala (decisão 91)
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
  v_escalas jsonb;
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

  -- escalas que valeram no mês (cabeçalho do espelho)
  select coalesce(jsonb_agg(jsonb_build_object('escala', x.escala, 'de', to_char(x.de, 'DD/MM'), 'ate', to_char(x.ate, 'DD/MM')) order by x.de), '[]'::jsonb)
    into v_escalas
    from (select y.escala, min(y.d) as de, max(y.d) as ate
            from (select g.d::date as d, fn_carga_dia(p_tecnico, g.d::date)->>'escala' as escala
                    from generate_series(v_ini, v_ult, interval '1 day') g(d) where v_ini <= v_ult) y
           where y.escala is not null group by y.escala) x;

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
    'jornada', jsonb_build_object('dia_util_min', v_jorn, 'sabado_min', v_sab, 'escalas', v_escalas,
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
      'Sua assinatura confirma que você recebeu e conferiu este espelho. Se algum horário estiver errado, peça a correção pelo app antes de assinar.'));
end $function$;

-- Atribuir escala (recriada da migration 94, conferida por MD5): trava da 12x36 (revisão do seguranca)
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
