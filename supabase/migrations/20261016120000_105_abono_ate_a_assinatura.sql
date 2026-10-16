-- Migration 105 (16/10/2026): abono, estorno e "desconsiderar" valem enquanto o espelho do mês não foi assinado
-- (decisão 100, pedido do responsável em 16/10). Antes, o limite era de 62 dias: um dia travado no fechamento por
-- intervalo não registrado ou marcação duplicada, mais antigo que isso, não tinha como ser resolvido. Agora o limite é
-- a assinatura do espelho do mês pelo funcionário (depois dela o espelho não muda, decisão 82). Abono continua só até hoje.
-- Base: definições atuais da homologação em 16/10 (app_ponto_abonar e app_ponto_estornar_abono da migration 66;
-- app_ponto_ajustar da 104).

-- O espelho do mês da data já foi assinado pelo funcionário (versão vigente)
create or replace function fn_ponto_mes_assinado(p_tecnico uuid, p_data date)
returns boolean language sql stable set search_path = public, extensions as $$
  select exists (select 1 from ponto_espelhos e
                  where e.tecnico_id = p_tecnico and e.competencia = date_trunc('month', p_data)::date
                    and e.assinado_em is not null and e.substituido_em is null)
$$;

create or replace function app_ponto_abonar(p_tecnico uuid, p_data date, p_motivo text,
  p_inicio time without time zone default null, p_fim time without time zone default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_det   text;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Abono só até hoje.'; end if;
  if fn_ponto_mes_assinado(p_tecnico, p_data) then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: não cabe mais abono.';
  end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do abono (10 a 500 letras).'; end if;
  if (p_inicio is null) <> (p_fim is null) or p_inicio >= p_fim then raise exception 'Período inválido: das ... às ... ou dia inteiro.'; end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.data = p_data and a.estorno_de is null
              and a.inicio is not distinct from p_inicio and a.fim is not distinct from p_fim
              and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'Este abono já foi lançado.';
  end if;
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor)
  values (v_tec.empresa_id, p_tecnico, p_data, p_inicio, p_fim, trim(p_motivo), v_email) returning id into v_id;
  v_det := fn_ponto_justificativa_detalhe('abono', null, null, p_inicio, p_fim);
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, '📝 *Ponto · abono do gestor*' || E'\n' || 'Seu registro de ' || to_char(p_data, 'DD/MM')
      || ' foi abonado (' || v_det || '): esse período não é descontado.');
  end if;
  return jsonb_build_object('id', v_id, 'data', to_char(p_data, 'DD/MM/YYYY'), 'detalhe', v_det);
end $$;

create or replace function app_ponto_estornar_abono(p_abono uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
  v_id    uuid;
begin
  select * into a from ponto_abonos where id = p_abono;
  if not found or a.estorno_de is not null then raise exception 'Abono não encontrado.'; end if;
  if fn_ponto_mes_assinado(a.tecnico_id, a.data) then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: o abono não pode mais ser estornado.';
  end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do estorno (10 a 500 letras).'; end if;
  begin
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, estorno_de, motivo, autor)
    values (a.empresa_id, a.tecnico_id, a.data, a.inicio, a.fim, a.justificativa_id, a.id, trim(p_motivo), v_email)
    returning id into v_id;
  exception when unique_violation then raise exception 'Este abono já foi estornado.';
  end;
  return jsonb_build_object('id', v_id);
end $$;

-- O gestor só desconsidera marcação (decisão 100), agora enquanto o espelho do mês não foi assinado
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
  if fn_ponto_mes_assinado(p_tecnico, (v_mom at time zone v_fuso)::date) then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: o ponto do mês não muda mais.';
  end if;

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
