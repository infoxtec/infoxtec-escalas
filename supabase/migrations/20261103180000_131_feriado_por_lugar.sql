-- Multiempresa F4a: feriado por estado e município (antes, um calendário só: o São João de Salvador valia para todos).
-- Feriado nacional (e ponto facultativo nacional) vale para todos; estadual, só na UF; municipal, só no município.
-- O lugar: na programação e na ligação, o do local (sem cidade no local, o da empresa do funcionário, e sem ela, a sede
-- da conta); no ponto, o da empresa do funcionário (sem ela, a sede da conta). A conta ganha a sede (UF e município).
-- fn_dias_uteis (prazo dos pedidos, sem lugar) passa a contar só os feriados nacionais.

set lock_timeout = '5s';
set local search_path to interno, public, extensions;   -- só nesta migration: a view recriada cita funções sem o esquema

-- 1. Lugares: sede da conta e UF do local
alter table interno.contas add column uf char(2) check (uf ~ '^[A-Z]{2}$'), add column municipio text;
update interno.contas set uf = 'BA', municipio = 'Salvador' where id = '00000000-0000-0000-0000-000000000001';
alter table interno.locais add column uf char(2) check (uf ~ '^[A-Z]{2}$');

-- 2. Feriado com lugar: os estaduais da carga atual são da Bahia; os municipais, de Salvador
alter table interno.feriados drop constraint feriados_pkey;
alter table interno.feriados add column id bigint generated always as identity primary key,
  add column uf char(2) check (uf ~ '^[A-Z]{2}$'), add column municipio text;
update interno.feriados set uf = 'BA' where abrangencia in ('estadual', 'municipal');
update interno.feriados set municipio = 'Salvador' where abrangencia = 'municipal';
alter table interno.feriados add constraint feriados_lugar_check check (
  (abrangencia = 'nacional' and uf is null and municipio is null)
  or (abrangencia = 'estadual' and uf is not null and municipio is null)
  or (abrangencia = 'municipal' and uf is not null and municipio is not null)
  or (abrangencia = 'facultativo' and (municipio is null or uf is not null)));

-- nome de município comparado sem acento, caixa e espaços nas pontas
create or replace function interno.fn_norm_lugar(p text)
 returns text language sql immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select lower(translate(btrim(p), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç',
                                   'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'))
$function$;

create unique index feriados_data_lugar_uk on interno.feriados
  (data, coalesce(uf, ''), coalesce(interno.fn_norm_lugar(municipio), ''));
create index feriados_data_idx on interno.feriados (data);

-- 3. O feriado do dia num lugar (nome, ou nulo); p_facultativo = false ignora o ponto facultativo
create or replace function interno.fn_feriado(p_data date, p_uf text, p_municipio text, p_facultativo boolean default true)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select f.nome from interno.feriados f
   where f.data = p_data and (p_facultativo or f.abrangencia <> 'facultativo')
     and (f.uf is null
          or (f.uf = upper(p_uf) and (f.municipio is null or interno.fn_norm_lugar(f.municipio) = interno.fn_norm_lugar(p_municipio))))
   order by (f.municipio is not null) desc, (f.uf is not null) desc, f.abrangencia = 'facultativo'
   limit 1
$function$;

create or replace function interno.fn_feriado_da_conta(p_data date, p_conta uuid, p_facultativo boolean default true)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  -- conta sem sede (ou não informada): só os nacionais
  select interno.fn_feriado(p_data, (select c.uf from interno.contas c where c.id = p_conta),
                            (select c.municipio from interno.contas c where c.id = p_conta), p_facultativo)
$function$;

-- empresa (UF e cidade) ou, sem elas, a sede da conta
create or replace function interno.fn_feriado_da_empresa(p_data date, p_empresa uuid, p_facultativo boolean default true)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select interno.fn_feriado(p_data, case when e.uf is not null then e.uf else c.uf end,
                            case when e.uf is not null then e.cidade else c.municipio end, p_facultativo)
    from interno.empresas e join interno.contas c on c.id = e.conta_id where e.id = p_empresa
$function$;

-- funcionário: a empresa dele ou, sem empresa, a sede da conta
create or replace function interno.fn_feriado_do_tecnico(p_data date, p_tecnico uuid, p_facultativo boolean default true)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select case when t.empresa_id is not null then interno.fn_feriado_da_empresa(p_data, t.empresa_id, p_facultativo)
              else interno.fn_feriado_da_conta(p_data, t.conta_id, p_facultativo) end
    from interno.tecnicos t where t.id = p_tecnico
$function$;

-- programação: o local (com cidade e UF) ou, sem eles, o funcionário
create or replace function interno.fn_feriado_da_escala(p_data date, p_escala uuid, p_facultativo boolean default true)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  -- local sem UF não herda a UF da sede (um local em São Paulo de conta baiana teria os feriados da Bahia): cai no funcionário
  select case when nullif(btrim(l.cidade), '') is not null and l.uf is not null
              then interno.fn_feriado(p_data, l.uf, l.cidade, p_facultativo)
              else interno.fn_feriado_do_tecnico(p_data, e.tecnico_id, p_facultativo) end
    from interno.escalas e left join interno.locais l on l.id = e.local_id
   where e.id = p_escala
$function$;

-- 4. Quem consulta feriado passa a consultar o do lugar


CREATE OR REPLACE FUNCTION interno.fn_pendencias_escala(p_data date, p_conta uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
    'feriado', fn_feriado_da_conta(p_data, p_conta),
    'afastados', (select count(*) from afastados),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
                    and fn_feriado_da_conta(p_data, p_conta) is null
  )
$function$
;


CREATE OR REPLACE FUNCTION interno.fn_dias_uteis(p_de date, p_ate date)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  select count(*)::int from generate_series(p_de + 1, p_ate, interval '1 day') d
   where extract(isodow from d) between 1 and 5
     and not exists (select 1 from feriados f where f.data = d::date and f.uf is null)   -- sem lugar: só os nacionais
$function$
;


CREATE OR REPLACE FUNCTION interno.fn_ponto_alerta_pedidos_parados()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e   record;
  v_n int := 0;
begin
  for e in
    select j.empresa_id, coalesce(em.fuso, 'America/Bahia') as fuso, count(*)::int as qtd,
           (array_agg(j.numero order by j.created_at))[1] as mais_antigo,
           (array_agg(j.tecnico_id order by j.created_at))[1] as tecnico,
           min(j.created_at) as desde
      from ponto_justificativas j join empresas em on em.id = j.empresa_id
     where j.status = 'pendente'
       and fn_dias_uteis((j.created_at at time zone coalesce(em.fuso, 'America/Bahia'))::date,
                         (now() at time zone coalesce(em.fuso, 'America/Bahia'))::date) > 2
     group by j.empresa_id, em.fuso
  loop
    continue when extract(isodow from now() at time zone e.fuso) > 5
               or fn_feriado_da_empresa((now() at time zone e.fuso)::date, e.empresa_id) is not null
               or (now() at time zone e.fuso)::time not between time '08:00' and time '18:00';
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_parados_' || e.empresa_id, (now() at time zone e.fuso)::date, now(), true, jsonb_build_object('qtd', e.qtd))
    on conflict do nothing;
    if found then
      perform fn_ponto_avisar_supervisores(e.tecnico, '⏳ *Ponto*: ' || e.qtd || ' pedido(s) de ajuste aguardando há mais de 2 dias úteis '
        || '(o mais antigo é o nº ' || e.mais_antigo || ', de ' || to_char(e.desde at time zone e.fuso, 'DD/MM') || '). '
        || 'Veja em Registro de Ponto › Ajustes.');
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $function$
;


CREATE OR REPLACE FUNCTION interno.fn_alerta_prazo_escala()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_multi  boolean;
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
  c        record;
  g        record;
begin
  if not (extract(isodow from v_amanha)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))) then
    return;
  end if;

  foreach v_tipo in array array['aviso', 'prazo'] loop
    v_hora := fn_config(case v_tipo when 'aviso' then 'alerta_escala_aviso' else 'alerta_escala_prazo' end)::time;
    continue when v_agora::time < v_hora;

    for c in select x.id from contas x where x.ativa order by x.criada_em loop
     -- véspera de feriado na sede da conta: sem cobrança de escala (trabalho em feriado é excepcional)
     continue when fn_feriado_da_conta(v_amanha, c.id) is not null;
     -- erro numa conta não derruba o aviso das outras
     begin
      continue when exists (select 1 from alertas_enviados where conta_id = c.id and tipo = v_tipo and data_ref = v_amanha);

      -- passou da janela (ou o aviso ficou para depois do prazo): registra sem enviar
      if v_agora::time > v_hora + interval '2 hours'
         or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
        insert into alertas_enviados (conta_id, tipo, data_ref, enviado) values (c.id, v_tipo, v_amanha, false);
        continue;
      end if;

      v_multi := (select count(*) from empresas where ativo and conta_id = c.id) > 1;
      v_p    := fn_pendencias_escala(v_amanha, c.id);
      v_qtd  := jsonb_array_length(v_p->'sem_escala');
      v_rasc := (v_p->>'rascunhos')::int;
      insert into alertas_enviados (conta_id, tipo, data_ref, enviado, detalhe)
      values (c.id, v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

      continue when v_qtd = 0 and v_rasc = 0;

      for g in
        with sem as (
          select case when v_multi then t.empresa_id end as emp, t.nome, 0 as rasc
            from jsonb_array_elements(v_p->'sem_escala') x join tecnicos t on t.id = (x->>'id')::uuid
        ), rasc as (
          select case when v_multi then t.empresa_id end as emp, null::text as nome, count(*)::int as rasc
            from escalas e join tecnicos t on t.id = e.tecnico_id
           where e.data_servico = v_amanha and e.status = 'rascunho' and not e.teste and e.conta_id = c.id
           group by 1
        )
        select emp, array_agg(nome order by nome) filter (where nome is not null) as nomes, sum(rasc)::int as rasc
          from (select * from sem union all select * from rasc) u
         group by emp
      loop
        v_qtd  := coalesce(array_length(g.nomes, 1), 0);
        v_rasc := coalesce(g.rasc, 0);
        continue when v_qtd = 0 and v_rasc = 0;
        select string_agg('• ' || n, E'\n') into v_nomes from unnest(g.nomes[1:15]) n;
        if v_qtd > 15 then v_nomes := v_nomes || E'\n• e mais ' || (v_qtd - 15); end if;

        v_texto := case v_tipo
          when 'aviso' then '⏰ *PROGRAMAÇÃO DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
          else '⚠️ *PRAZO DA PROGRAMAÇÃO ENCERRADO*'
        end || E'\n\n'
          || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
          || case when v_qtd > 0 then v_qtd || ' técnico(s) sem programação:' || E'\n' || v_nomes || E'\n\n' else '' end
          || case when v_rasc > 0 then v_rasc || ' programação(ões) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
          || case v_tipo
               when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
               else 'A equipe precisa receber a programação ainda hoje.'
             end;

        perform fn_avisar_supervisores(v_texto, null, g.emp, c.id);
      end loop;
     exception when others then
      raise warning 'fn_alerta_prazo_escala: conta % falhou (%)', c.id, sqlerrm;
     end;
    end loop;
  end loop;
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
           fn_feriado_do_tecnico(g.d::date, p_tecnico, false) as feriado,
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


CREATE OR REPLACE FUNCTION interno.fn_ponto_folha_pendencias(p_tecnico uuid, p_mes date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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

  -- hora extra (decisão 100, parte 2): aguardando o gestor bloqueia; não autorizada sai para confirmar (o tempo
  -- trabalhado continua no espelho: a reprovação não apaga a hora)
  v_res := v_res || coalesce((select jsonb_agg(jsonb_build_object(
             'tipo', case when h.status = 'pendente' then 'he_pendente' else 'he_reprovada' end,
             'nivel', case when h.status = 'pendente' then 'bloqueia' else 'confirmar' end,
             'bloqueia', h.status = 'pendente', 'data', h.data, 'numero', h.numero,
             'hora', to_char(h.inicio at time zone v_fuso, 'HH24:MI')) order by h.data, h.numero)
           from ponto_he_autorizacoes h
          where h.tecnico_id = p_tecnico and h.status in ('pendente', 'reprovada') and h.data between v_mes and v_fim), '[]'::jsonb);

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
               and fn_feriado_do_tecnico(r.dia, p_tecnico, false) is not null)
      and not (extract(isodow from r.dia) = 6 and r.c->>'escala' is null and v_abona) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'nivel', 'confirmar', 'bloqueia', false,
                 'data', r.dia, 'minutos', (r.c->>'minutos')::int));
    end if;
  end loop;

  -- funcionário sem nenhum registro no mês não entra no fechamento (o espelho não é emitido): não há o que apontar
  if v_dias = 0 and not exists (select 1 from jsonb_array_elements(v_res) x where x->>'tipo' in ('pedido_pendente', 'he_pendente', 'he_reprovada')) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(x order by x->>'data', x->>'tipo'), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;
  return v_res;
end $function$
;


CREATE OR REPLACE FUNCTION public.app_painel_gerencial(p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
           fn_feriado_da_conta(dia, v_conta, false) is not null as feriado,
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
end $function$
;


CREATE OR REPLACE FUNCTION public.app_ponto_folga_compensatoria(p_tecnico uuid, p_folga date, p_trabalhado date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_dom_fer boolean;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso,
         coalesce(t.admissao, t.created_at::date) as inicio, t.desligado_em
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico and t.conta_id = fn_conta_atual();
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
               or fn_feriado_do_tecnico(p_trabalhado, p_tecnico, false) is not null;
  if not v_dom_fer then raise exception 'O dia trabalhado precisa ser domingo ou feriado.'; end if;
  if coalesce((fn_ponto_jornada_dia(p_tecnico, p_trabalhado) ->> 'trabalhado_min')::int, 0) = 0 then
    raise exception 'Não há trabalho registrado no ponto em %.', to_char(p_trabalhado, 'DD/MM');
  end if;
  if extract(isodow from p_folga) = 7
     or fn_feriado_do_tecnico(p_folga, p_tecnico, false) is not null then
    raise exception 'A folga precisa cair em dia de trabalho, não em domingo ou feriado.';
  end if;
  if abs(p_folga - p_trabalhado) > 6 then
    raise exception 'A folga precisa ficar na mesma semana do trabalho (até 6 dias de distância).';
  end if;
  if p_folga > v_hoje + 7 then raise exception 'Folga só até 7 dias à frente.'; end if;
  -- a folga é descanso de verdade: não em sábado que já é de descanso, fora do vínculo nem em dia trabalhado
  -- (revisão do seguranca: senão o 100% sairia sem o funcionário descansar)
  if extract(isodow from p_folga) = 6 and coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true' then
    raise exception 'Sábado já é dia sem expediente: a folga precisa cair de segunda a sexta.';
  end if;
  if p_folga < v_tec.inicio or p_folga > coalesce(v_tec.desligado_em, p_folga) then
    raise exception 'A folga precisa cair dentro do vínculo do funcionário.';
  end if;
  if p_folga <= v_hoje and coalesce((fn_ponto_jornada_dia(p_tecnico, p_folga) ->> 'trabalhado_min')::int, 0) > 0 then
    raise exception 'Há trabalho registrado no ponto em %: não foi folga.', to_char(p_folga, 'DD/MM');
  end if;
  -- folga lançada na hora, não rótulo posto depois numa falta: no máximo 7 dias para trás, e nunca em mês com
  -- espelho já emitido (reemitir depois de lançar)
  if p_folga < v_hoje - 7 then raise exception 'Folga já passada só pode ser lançada até 7 dias depois.'; end if;
  if exists (select 1 from ponto_espelhos e where e.tecnico_id = p_tecnico and e.substituido_em is null
              and e.competencia in (date_trunc('month', p_folga)::date, date_trunc('month', p_trabalhado)::date)) then
    raise exception 'O espelho desse mês já foi emitido: a folga precisa ser lançada antes da emissão.';
  end if;
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
end $function$
;


drop view interno.vw_ligacoes_pendentes;
drop function interno.fn_ligacao_permitida(timestamp with time zone);
CREATE OR REPLACE FUNCTION interno.fn_ligacao_permitida(p_momento timestamp with time zone DEFAULT now(), p_escala uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  select extract(isodow from l.ts) between 1 and 5
     -- feriado do lugar da programação; sem programação, só os nacionais
     and case when p_escala is null then not exists (select 1 from feriados f where f.data = l.ts::date and f.uf is null)
              else fn_feriado_da_escala(l.ts::date, p_escala) is null end
     and l.ts::time >= fn_config('ligacao_janela_inicio')::time
     and l.ts::time <= fn_config('ligacao_janela_fim')::time
    from (select p_momento at time zone coalesce(nullif(fn_config('fuso'), ''), 'America/Bahia') as ts) l
$function$
;


create or replace view interno.vw_ligacoes_pendentes as  WITH agora AS (
         SELECT (now() AT TIME ZONE COALESCE(NULLIF(fn_config('fuso'::text), ''::text), 'America/Bahia'::text)) AS local_ts
        )
 SELECT e.id AS escala_id,
    t.id AS tecnico_id,
    t.nome AS tecnico,
    t.telefone_e164 AS telefone,
    COALESCE(n.tentativa, 0) AS tentativas_whatsapp,
    ( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id) AS ligacoes_feitas
   FROM escalas e
     JOIN tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in AND NOT t.perfil_teste
     LEFT JOIN LATERAL ( SELECT notificacoes.id,
            notificacoes.escala_id,
            notificacoes.tipo,
            notificacoes.tentativa,
            notificacoes.wa_message_id,
            notificacoes.template_nome,
            notificacoes.status_envio,
            notificacoes.erro_codigo,
            notificacoes.erro_mensagem,
            notificacoes.payload_envio,
            notificacoes.enviada_em,
            notificacoes.entregue_em,
            notificacoes.lida_em,
            notificacoes.created_at,
            notificacoes.http_req_id
           FROM notificacoes
          WHERE notificacoes.escala_id = e.id
          ORDER BY notificacoes.created_at DESC
         LIMIT 1) n ON true
     CROSS JOIN agora g
  WHERE e.status = 'notificada'::escala_status AND e.local_id IS NOT NULL AND (e.data_servico + e.hora_inicio) > g.local_ts AND COALESCE(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas'::text) AND (n.status_envio = ANY (ARRAY['enviada'::envio_status, 'entregue'::envio_status, 'lida'::envio_status])) AND NOT (EXISTS ( SELECT 1
           FROM respostas r
          WHERE r.escala_id = e.id)) AND (( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id)) < fn_config_int('ligacao_max_por_escala'::text) AND NOT (EXISTS ( SELECT 1
           FROM ligacoes l
          WHERE l.escala_id = e.id AND ((l.status = ANY (ARRAY['criada'::text, 'discando'::text])) OR l.criada_em > (now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'::text)))))) AND COALESCE(fn_ligacao_permitida(now(), e.id), false) AND fn_ponto_afastado_ate(t.id, e.data_servico) IS NULL;


revoke all on interno.vw_ligacoes_pendentes from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION interno.fn_preparar_ligacao(p_escala uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  if not coalesce(fn_ligacao_permitida(now(), p_escala), false) then   -- config faltando nunca libera
    raise exception 'Ligações só em dias úteis, das % às %, fora de sábado, domingo e feriado.',
      fn_config('ligacao_janela_inicio'), fn_config('ligacao_janela_fim');
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status, e.local_id into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A programação já foi respondida (%).', v_esc.status; end if;
  if v_esc.local_id is null then
    raise exception 'Programação sem local não é enviada nem ligada. Escolha o local.';
  end if;

  if not fn_pode_enviar(v_esc.telefone_e164) then
    raise exception 'Ambiente de homologação: só é possível ligar para cadastros de teste. % não é um.', v_esc.nome;
  end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
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
