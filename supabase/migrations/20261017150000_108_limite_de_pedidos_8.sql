-- Migration 108 (17/10/2026): o funcionário pode fazer até 8 pedidos de ajuste ou justificativa em 24 horas (eram 5),
-- pedido do responsável no teste de setembro do Renato: corrigir um mês com várias marcações esquecidas passava do
-- limite. O teto de 10 pedidos em análise ao mesmo tempo continua. Parte da definição atual da homologação.
CREATE OR REPLACE FUNCTION public.fn_ponto_justificativa_criar(p_tecnico uuid, p_motivo text, p_data date, p_tipo_marcacao text, p_hora time without time zone, p_hora_ini time without time zone, p_hora_fim time without time zone, p_observacao text, p_canal text, p_data_fim date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_tec    record;
  v_mot    record;
  v_hoje   date;
  v_id     uuid;
  v_num    bigint;
  v_obs    text := nullif(trim(coalesce(p_observacao, '')), '');
  v_fim    date;
  v_alerta text;
begin
  select t.id, t.nome, t.empresa_id, t.ativo, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found or not v_tec.ativo or v_tec.empresa_id is null then raise exception 'Funcionário sem ponto cadastrado.'; end if;
  select * into v_mot from ponto_motivos where codigo = p_motivo and ativo;
  if not found then raise exception 'Escolha um motivo válido.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Informe um dia até hoje.'; end if;
  if p_data < v_hoje - 62 then raise exception 'Pedido só para os últimos 62 dias.'; end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'Observação com no máximo 500 letras.'; end if;

  if p_motivo in ('esqueci_marcar', 'falha_registro') then
    if p_tipo_marcacao is null or p_tipo_marcacao not in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he') then
      raise exception 'Escolha a marcação que ficou faltando.';
    end if;
    if p_hora is null then raise exception 'Informe o horário da marcação.'; end if;
    if (p_data + p_hora) at time zone v_tec.fuso > now() then raise exception 'O horário ainda não chegou.'; end if;
  elsif p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then
    if p_hora_ini is null or p_hora_fim is null or p_hora_ini >= p_hora_fim then
      raise exception 'Informe o período: das ... às ... (o início antes do fim).';
    end if;
    if p_motivo = 'atraso_saida' and (p_data + p_hora_fim) at time zone v_tec.fuso > now() then
      raise exception 'O horário ainda não chegou.';
    end if;
  else
    -- falta de dias inteiros: o atestado pode cobrir dias seguintes (até 30 dias no pedido)
    v_fim := coalesce(p_data_fim, p_data);
    if v_fim < p_data then raise exception 'O último dia vem depois do primeiro.'; end if;
    if v_fim - p_data > 30 then raise exception 'Pedido de até 31 dias. Acima de 15 dias de atestado, o caso vai ao INSS: fale com o gestor.'; end if;
    if v_fim > v_hoje + 30 then raise exception 'O último dia está longe demais.'; end if;
  end if;

  if exists (select 1 from ponto_justificativas j where j.tecnico_id = p_tecnico and j.status = 'pendente'
              and j.motivo = p_motivo and j.data = p_data and j.data_fim is not distinct from v_fim
              and j.tipo_marcacao is not distinct from p_tipo_marcacao and j.hora is not distinct from p_hora
              and j.hora_ini is not distinct from p_hora_ini and j.hora_fim is not distinct from p_hora_fim) then
    raise exception 'Já existe um pedido igual em análise.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and status = 'pendente') >= 10 then
    raise exception 'Você já tem 10 pedidos em análise. Aguarde a resposta do gestor.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and created_at > now() - interval '24 hours') >= 8 then
    raise exception 'Limite de 8 pedidos em 24 horas. Fale com o seu gestor.';
  end if;

  v_alerta := fn_ponto_limite_alerta(p_tecnico, p_motivo, p_data, v_fim);
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, data_fim, tipo_marcacao, hora, hora_ini, hora_fim,
                                    observacao, canal, alerta_limite)
  values (v_tec.empresa_id, p_tecnico, p_motivo, p_data, v_fim,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_tipo_marcacao end,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_hora end,
          case when p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then p_hora_ini end,
          case when p_motivo = 'atraso_saida' or v_mot.abrange = 'horario' then p_hora_fim end,
          v_obs, p_canal, v_alerta)
  returning id, numero into v_id, v_num;

  -- supervisores: no máximo um aviso por funcionário por hora, só com o primeiro nome (nunca o motivo)
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_pedido_' || p_tecnico || '_' || to_char(now(), 'HH24'), current_date, now(), true,
          jsonb_build_object('tecnico', p_tecnico))
  on conflict do nothing;
  if found then
    perform fn_ponto_avisar_supervisores(p_tecnico,
      '📝 *Ponto · ' || split_part(trim(v_tec.nome), ' ', 1) || '*: pedido de ajuste nº ' || v_num
      || ' (' || to_char(p_data, 'DD/MM') || '). Veja em Registro de Ponto › Ajustes.');
  end if;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'motivo', v_mot.nome, 'data', to_char(p_data, 'DD/MM/YYYY'),
    'detalhe', fn_ponto_pedido_detalhe(p_motivo, p_tipo_marcacao, p_hora, p_hora_ini, p_hora_fim, p_data, v_fim),
    'alerta', v_alerta, 'exige_anexo', v_mot.exige_anexo);
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
