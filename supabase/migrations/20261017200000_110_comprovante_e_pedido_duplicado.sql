-- Migration 110 (17/10/2026): comprovante de cada marcação com os campos do art. 79 da Portaria 671 e pedido de
-- ajuste com o tipo trocado barrado na origem (pedido do responsável, decisão 105).
-- 1. ponto_meus_comprovantes: as marcações do próprio funcionário nas últimas 48 horas (art. 80, III), com título,
--    NSR, empregador (CNPJ e CEI/CAEPF/CNO), local da prestação ou endereço do estabelecimento, nome e CPF completos,
--    data e hora com segundos, número do INPI (config rep_p_inpi, vazio até o registro) e o SHA-256 da marcação
--    (art. 79). O app monta o PDF; a assinatura PAdES do desenvolvedor (arts. 80, I, 86 e 88) entra com o e-CNPJ.
-- 2. fn_ponto_justificativa_criar: pedido de saída ou volta do almoço que já existe no dia (marcada, incluída ou
--    pedida) é recusado com a dica do tipo certo. Parte da definição atual da homologação.

create or replace function ponto_meus_comprovantes(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v     jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'titulo', 'Comprovante de Registro de Ponto do Trabalhador',
           'nsr', m.nsr, 'tipo', m.tipo, 'canal', m.canal,
           'empregador', e.razao_social, 'cnpj', e.cnpj, 'cei_caepf_cno', e.cei_caepf_cno,
           'local', coalesce(l.nome || coalesce(' - ' || nullif(l.endereco, ''), '') || coalesce(', ' || nullif(l.cidade, ''), ''),
                             nullif(concat_ws(' - ', e.endereco, concat_ws('/', e.cidade, e.uf)), '')),
           'trabalhador', t.nome, 'cpf', m.cpf,
           'data', to_char(m.momento at time zone coalesce(e.fuso, 'America/Bahia'), 'DD/MM/YYYY'),
           'hora', to_char(m.momento at time zone coalesce(e.fuso, 'America/Bahia'), 'HH24:MI:SS'),
           'fuso', coalesce(e.fuso, 'America/Bahia'),
           'inpi', nullif(trim(coalesce(fn_config('rep_p_inpi'), '')), ''),
           'sha256', m.hash) order by m.momento desc), '[]'::jsonb)
    into v
    from ponto_marcacoes m
    join tecnicos t on t.id = m.tecnico_id
    join empresas e on e.id = m.empresa_id
    left join locais l on l.id = m.local_id
   where m.tecnico_id = v_tec and m.momento > now() - interval '48 hours';
  return v;
end $function$;

-- pedido com o tipo trocado barrado na origem
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
  v_dup    text;
  v_fuso   text := coalesce((select e.fuso from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico), 'America/Bahia');
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
  -- saída e volta do almoço só uma de cada no dia: pedir uma que já existe (marcada, incluída ou pedida) costuma ser o
  -- tipo trocado, que depois trava o fechamento como duplicada (teste de setembro do Renato, 17/10)
  if p_motivo in ('esqueci_marcar', 'falha_registro') and p_tipo_marcacao in ('saida_almoco', 'volta_almoco') then
    select h.hora into v_dup from (
      select m.momento as quando from ponto_marcacoes m
       where m.tecnico_id = p_tecnico and m.tipo = p_tipo_marcacao
         and (m.momento at time zone v_fuso)::date = p_data
         and not exists (select 1 from ponto_ajustes d where d.marcacao_id = m.id and d.acao = 'desconsiderar')
      union all
      select a.momento from ponto_ajustes a
       where a.tecnico_id = p_tecnico and a.acao = 'incluir' and a.tipo = p_tipo_marcacao
         and (a.momento at time zone v_fuso)::date = p_data
         and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id and d.acao = 'desconsiderar')
      union all
      select (p_data + j.hora) at time zone v_fuso from ponto_justificativas j
       where j.tecnico_id = p_tecnico and j.status = 'pendente' and j.data = p_data and j.tipo_marcacao = p_tipo_marcacao
    ) x cross join lateral (select to_char(x.quando at time zone v_fuso, 'HH24:MI') as hora) h
    limit 1;
    if v_dup is not null then
      raise exception 'Você já tem % às % em %. Confira o tipo: talvez seja a %.',
        fn_ponto_rotulo(p_tipo_marcacao), v_dup, to_char(p_data, 'DD/MM'),
        lower(fn_ponto_rotulo(case p_tipo_marcacao when 'saida_almoco' then 'volta_almoco' else 'saida_almoco' end));
    end if;
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
