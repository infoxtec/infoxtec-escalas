-- Migration 95 (13/10/2026): o gestor não inclui marcação (pedido do responsável, decisão 89).
-- "Incluir marcação esquecida" sai de Gestão de Ponto > Ajustes e pedidos > Novo ajuste e do banco. A marcação
-- esquecida só entra pelo pedido de ajuste do próprio funcionário (app do ponto), aprovado pelo gestor; se o
-- funcionário não pedir, o supervisor abona a falta ou o atraso com justificativa (app_ponto_abonar). Continua:
-- desconsiderar marcação errada (inclusive uma inclusão vinda de pedido aprovado), abono e folga compensatória.
-- As inclusões já lançadas não mudam (ponto_ajustes é imutável) e seguem no espelho.
-- Recriada a partir da definição da homologação (migration 65), só sem o ramo 'incluir'.
create or replace function app_ponto_ajustar(p_tecnico uuid, p_acao text, p_motivo text,
  p_marcacao uuid default null, p_ajuste uuid default null, p_data date default null,
  p_hora time without time zone default null, p_tipo text default null)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
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
    raise exception 'O gestor não inclui marcação. A marcação esquecida entra pelo pedido de ajuste do funcionário; sem pedido, abone a falta ou o atraso com justificativa.';
  elsif p_acao <> 'desconsiderar' or p_acao is null then
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
  if v_mom < now() - interval '62 days' then raise exception 'Ajuste só para os últimos 62 dias.'; end if;

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
