-- Migration 72 (12/10/2026): justificativa de ponto, entrega E3 — reincidência, pedido parado e métrica.
--
-- Reincidência é só o fato ("3º pedido de Ponto em 30 dias"), nunca o rótulo (desídia, CLT 482 — o time
-- decidiu não usar, decisão 57), e conta só pedidos de Ponto (esqueci, app falhou, atraso): atestado e
-- falta prevista em lei nunca contam (LGPD art. 11; Lei 9.029/95). O papel leitura não vê. Pedido parado há mais de 2 dias úteis avisa os supervisores uma vez
-- por dia útil, pelo cron já existente do ponto (ponto-lembrete-almoco, a cada 15 min): nada muda no
-- cron da produção. Métrica de 30 dias do planejamento: decididos em até 2 dias úteis, parados agora e
-- inclusões manuais do gestor (o "incluir" que não veio de pedido).

-- Dias úteis (segunda a sexta, fora de feriado — a mesma regra da URA, migration 64) depois de p_de até p_ate
create or replace function fn_dias_uteis(p_de date, p_ate date)
returns int language sql stable set search_path = public, extensions as $$
  select count(*)::int from generate_series(p_de + 1, p_ate, interval '1 day') d
   where extract(isodow from d) between 1 and 5
     and not exists (select 1 from feriados f where f.data = d::date)
$$;

-- Lista de pedidos: mais a reincidência (fato) e há quantos dias úteis o pedido espera --------------------
drop function if exists app_ponto_justificativas(date, date, uuid);
create function app_ponto_justificativas(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, numero bigint, tecnico_id uuid, tecnico text, motivo text, motivo_nome text, grupo text,
               data date, detalhe text, tipo_marcacao text, hora text, hora_ini text, hora_fim text,
               observacao text, canal text, status text, decidido_por text, decidido_em text, resposta text, criado_em text,
               abono_estornado boolean, data_fim date, restrito boolean, pode_decidir boolean, anexos integer,
               alerta_limite text, fora_prazo boolean, ponto_30d integer, dias_uteis_espera integer)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor','leitura']);
  v_leitura boolean := fn_papel(v_email) = 'leitura';
  v_saude   boolean := fn_ve_saude(v_email);
begin
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select j.id, j.numero, j.tecnico_id, t.nome,
           case when m.saude and not v_saude then 'saude' else j.motivo end,
           case when m.saude and not v_saude then 'Justificativa de saúde' else m.nome end,
           m.grupo, j.data,
           fn_ponto_pedido_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim, j.data, j.data_fim),
           j.tipo_marcacao, to_char(j.hora, 'HH24:MI'), to_char(j.hora_ini, 'HH24:MI'), to_char(j.hora_fim, 'HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.observacao end, j.canal, j.status,
           case when v_leitura then null else j.decidido_por end,
           to_char(j.decidido_em at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.resposta end,
           to_char(j.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           exists (select 1 from ponto_abonos x where x.estorno_de = j.abono_id),
           j.data_fim,
           m.grupo <> 'ponto' and not v_saude,
           not v_leitura and (m.grupo = 'ponto' or v_saude),
           (select count(*)::int from ponto_justificativa_anexos a where a.justificativa_id = j.id),
           case when v_leitura or (m.saude and not v_saude) then null else j.alerta_limite end,
           m.grupo <> 'ponto' and j.created_at > ((coalesce(j.data_fim, j.data) + 1)::timestamp at time zone e.fuso) + interval '48 hours',
           -- pedidos de Ponto do funcionário nos 30 dias até este (este incluído), sem os cancelados
           case when not v_leitura and m.grupo = 'ponto' then
             (select count(*)::int from ponto_justificativas o join ponto_motivos om on om.codigo = o.motivo
               where o.tecnico_id = j.tecnico_id and o.status <> 'cancelada' and om.grupo = 'ponto'
                 and o.created_at between j.created_at - interval '30 days' and j.created_at) end,
           case when j.status = 'pendente'
                then fn_dias_uteis((j.created_at at time zone e.fuso)::date, (now() at time zone e.fuso)::date) end
      from ponto_justificativas j
      join tecnicos t on t.id = j.tecnico_id
      join empresas e on e.id = j.empresa_id
      join ponto_motivos m on m.codigo = j.motivo
     where (j.status = 'pendente' or j.data between p_de and p_ate)
       and (p_tecnico is null or j.tecnico_id = p_tecnico)
     order by (j.status = 'pendente') desc, j.created_at desc;
end $$;

-- Pedidos parados há mais de 2 dias úteis: um aviso por empresa por dia útil, das 08:00 às 18:00 ----------
create or replace function fn_ponto_alerta_pedidos_parados()
returns int language plpgsql volatile set search_path = public, extensions as $$
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
               or exists (select 1 from feriados f where f.data = (now() at time zone e.fuso)::date)
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
end $$;

-- O cron do ponto (a cada 15 min) passa a chamar o alerta; falha no alerta não derruba o lembrete -------
create or replace function fn_ponto_lembrete_almoco()
returns integer language plpgsql security definer set search_path to 'public', 'extensions' as $function$
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
  return v_n;
end $function$;

-- Métrica do período (planejamento de 11/10): decididos em até 2 dias úteis, parados e inclusões manuais ---
create or replace function app_ponto_justificativas_metricas(p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor','leitura']);
  r jsonb;
begin
  if p_ate < p_de or p_ate - p_de > 92 then raise exception 'Período de até 92 dias.'; end if;
  select jsonb_build_object(
    'recebidos', count(*) filter (where j.status <> 'cancelada'),
    'decididos', count(*) filter (where j.status in ('aprovada', 'negada')),
    'no_prazo', count(*) filter (where j.status in ('aprovada', 'negada')
                  and fn_dias_uteis((j.created_at at time zone x.fuso)::date, (j.decidido_em at time zone x.fuso)::date) <= 2),
    'pendentes', count(*) filter (where j.status = 'pendente'),
    'parados', count(*) filter (where j.status = 'pendente'
                  and fn_dias_uteis((j.created_at at time zone x.fuso)::date, (now() at time zone x.fuso)::date) > 2))
    into r
    from ponto_justificativas j
    join lateral (select coalesce(e.fuso, 'America/Bahia') as fuso from empresas e where e.id = j.empresa_id) x on true
   where (j.created_at at time zone x.fuso)::date between p_de and p_ate;
  -- "incluir" lançado pelo gestor sem pedido do funcionário (a meta é não usar para cobrir ausência)
  r := r || jsonb_build_object('inclusoes_manuais',
    (select count(*) from ponto_ajustes a join empresas e on e.id = a.empresa_id
      where a.acao = 'incluir' and (a.created_at at time zone coalesce(e.fuso, 'America/Bahia'))::date between p_de and p_ate
        and not exists (select 1 from ponto_justificativas j where j.ajuste_id = a.id)));
  return r;
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
