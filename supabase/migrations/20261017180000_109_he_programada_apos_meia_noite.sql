-- Migration 109 (17/10/2026): hora extra programada com a Programação que termina depois da meia-noite.
-- fn_ponto_he_inicio comparava só a hora do fim com a do início da HE: escala das 16:00 que termina à 01:00 do dia
-- seguinte não cobria a HE das 17:00, e o pedido ia ao gestor sem precisar. Achado no CI (T49 rodando à tarde).
-- Também passa a exigir que a Programação já tenha começado. Parte da definição atual da homologação.
CREATE OR REPLACE FUNCTION public.fn_ponto_he_inicio(p_tecnico uuid)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_fuso text; v_emp uuid; v_nome text;
  v_data date;
  m      record;
  e      record;
  v_id   uuid;
  v_num  bigint;
  v_txt  text;
  s      record;
begin
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(x.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas x on x.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;
  select x.id, x.momento into m from ponto_marcacoes x
   where x.tecnico_id = p_tecnico and x.tipo = 'inicio_he' and x.momento >= v_data::timestamp at time zone v_fuso
   order by x.nsr desc limit 1;
  if m.id is null or exists (select 1 from ponto_he_autorizacoes h where h.marcacao_id = m.id) then return null; end if;

  -- a Programação do dia cobre o horário do início: autorizada pela Programação
  select s2.id, coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0))) as fim
    into e
    from escalas s2
   where s2.tecnico_id = p_tecnico and s2.data_servico = v_data and not coalesce(s2.teste, false)
     and s2.status not in ('cancelada', 'recusada', 'rascunho')
     and s2.hora_inicio <= (m.momento at time zone v_fuso)::time
     -- fim depois da meia-noite (menor que o início) cobre até o fim do dia
     and (coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0)))
            > (m.momento at time zone v_fuso)::time
          or coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0)))
            < s2.hora_inicio)
   order by 2 desc limit 1;
  if e.id is not null then
    insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem, escala_id, status,
                                       decidido_por, decidido_em, canal_decisao)
    values (v_emp, p_tecnico, m.id, v_data, m.momento, 'programada', e.id, 'aprovada', 'Programação do dia', now(), 'programacao');
    return '✅ Hora extra autorizada pela Programação de hoje (até ' || to_char(e.fim, 'HH24:MI') || ').';
  end if;

  insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem)
  values (v_emp, p_tecnico, m.id, v_data, m.momento, 'pedido') returning id, numero into v_id, v_num;
  v_txt := '⏱️ *Hora extra · ' || v_nome || '* (pedido nº ' || v_num || ')' || E'\n'
        || 'Início às ' || to_char(m.momento at time zone v_fuso, 'HH24:MI') || ' de ' || to_char(v_data, 'DD/MM')
        || ', fora da Programação. Aprova a hora extra?';
  -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora (como os avisos de jornada)
  for s in select telefone_e164 from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and (empresa_id = v_emp or empresa_id is null) loop
    begin
      if coalesce(fn_config('usar_botoes'), 'false')::boolean then
        perform fn_evo_post('/message/sendButtons/' || fn_config('evolution_instancia'),
          jsonb_build_object('number', s.telefone_e164, 'title', 'Hora extra', 'description', v_txt, 'footer', 'Trilha Ponto',
            'buttons', jsonb_build_array(
              jsonb_build_object('type', 'reply', 'displayText', 'Aprovar', 'id', 'he:ok:' || v_id),
              jsonb_build_object('type', 'reply', 'displayText', 'Reprovar', 'id', 'he:nao:' || v_id))));
      else
        perform fn_ponto_wa(s.telefone_e164, v_txt || E'\n' || 'Decida no painel: Ponto › Ajustes e pedidos.');
      end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
    end;
  end loop;
  return '⏳ Início de hora extra registrado e enviado ao gestor para aprovação; a resposta chega aqui. A marcação já vale.';
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
