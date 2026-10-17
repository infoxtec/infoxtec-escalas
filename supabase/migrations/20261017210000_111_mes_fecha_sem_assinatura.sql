-- Migration 111 (17/10/2026): o mês fecha na assinatura do espelho OU 10 dias depois da emissão (decisão 106).
-- O art. 84 da Portaria 671 não exige a assinatura do funcionário: se ele nunca assina, o mês não pode ficar aberto
-- para sempre a abono, estorno, desconsideração e decisão de hora extra (decisão 100, item 6). Depois do prazo
-- (config ponto_espelho_prazo_dias, padrão 10), fn_ponto_mes_espelho recusa com a explicação; a assinatura continua
-- possível, como ciência. O envio do espelho pelo WhatsApp avisa o prazo.

insert into config (chave, valor, descricao) values
  ('ponto_espelho_prazo_dias', '10', 'Dias depois da emissão do espelho em que o mês ainda aceita abono e ajuste sem a assinatura do funcionário (decisão 106)')
on conflict (chave) do nothing;

create or replace function fn_ponto_espelho_prazo_dias()
returns int language sql stable set search_path = public, extensions as $function$
  -- valor que não for número cai no padrão: configuração errada não trava abonos e ajustes
  select greatest(case when fn_config('ponto_espelho_prazo_dias') ~ '^\d{1,3}$' then fn_config('ponto_espelho_prazo_dias')::int else 10 end, 1)
$function$;

-- Situação do espelho do mês da data: 'assinado', 'emitido' (vigente, sem assinatura, dentro do prazo) ou
-- 'sem_espelho'. Emitido há mais do prazo sem assinatura: recusa aqui, com a data (todos os chamadores travariam)
create or replace function fn_ponto_mes_espelho(p_tecnico uuid, p_data date)
returns text language plpgsql set search_path = public, extensions as $function$
declare v_ass timestamptz; v_id uuid; v_emit timestamptz;
begin
  select e.id, e.assinado_em, e.emitido_em into v_id, v_ass, v_emit from ponto_espelhos e
   where e.tecnico_id = p_tecnico and e.competencia = date_trunc('month', p_data)::date and e.substituido_em is null
   for update;
  if v_id is not null and v_ass is null and v_emit < now() - make_interval(days => fn_ponto_espelho_prazo_dias()) then
    raise exception 'O mês de % está fechado: o espelho foi emitido em % e passaram % dias sem assinatura. O ponto do mês não muda mais.',
      to_char(p_data, 'MM/YYYY'), to_char(v_emit at time zone 'America/Bahia', 'DD/MM/YYYY'), fn_ponto_espelho_prazo_dias();
  end if;
  return case when v_id is null then 'sem_espelho' when v_ass is not null then 'assinado' else 'emitido' end;
end $function$;

-- envio do espelho com o prazo (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.app_ponto_enviar_espelhos(p_competencia date, p_espelho uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_url   text := rtrim(coalesce(nullif(fn_config('app_url'), ''), 'https://infoxtec-escalas.vercel.app'), '/');
  e       record;
  v_req   bigint;
  v_env   int := 0; v_sem int := 0; v_falha int := 0; v_desl int := 0;
begin
  for e in select p.id, p.enviado_em, p.emitido_em, t.nome, t.telefone_e164, t.opt_in, t.ativo, to_char(p.competencia, 'MM/YYYY') as mes
             from ponto_espelhos p join tecnicos t on t.id = p.tecnico_id
            where p.competencia = date_trunc('month', p_competencia)::date and p.substituido_em is null
              and p.assinado_em is null
              and (p.id = p_espelho or (p_espelho is null and p.enviado_em is null))
            order by t.nome
              for update of p loop
    if not e.ativo then v_desl := v_desl + 1; continue; end if;
    if not e.opt_in or e.telefone_e164 is null or not fn_pode_enviar(e.telefone_e164) then
      v_sem := v_sem + 1; continue;
    end if;
    begin
      v_req := fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', e.telefone_e164,
          'text', 'Trilha Ponto: ' || split_part(trim(e.nome), ' ', 1) || ', o seu espelho de ponto de ' || e.mes
                  || ' está pronto para conferir e assinar: ' || v_url || '/ponto?espelho=' || e.id
                  || chr(10) || 'Entre com o seu CPF e o código. Se algo estiver errado, peça o ajuste antes de assinar.'
                  || chr(10) || 'Confira e peça ajuste até ' || to_char((e.emitido_em + make_interval(days => fn_ponto_espelho_prazo_dias())) at time zone 'America/Bahia', 'DD/MM/YYYY') || '. Depois disso, o mês é fechado.'));
      -- nulo: envio barrado pela trava da homologação; o pedido ao WhatsApp é assíncrono (pg_net)
      if v_req is null then v_sem := v_sem + 1; continue; end if;
      if e.enviado_em is null then update ponto_espelhos set enviado_em = now() where id = e.id; end if;
      v_env := v_env + 1;
    exception when others then
      v_falha := v_falha + 1;
    end;
  end loop;
  return jsonb_build_object('enviados', v_env, 'sem_whatsapp', v_sem, 'falhas', v_falha, 'desligados', v_desl);
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
