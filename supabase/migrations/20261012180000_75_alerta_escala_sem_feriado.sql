-- Migration 75 (11/10/2026): o alerta da escala de amanhã não sai na véspera de feriado — decisão 65.
--
-- O aviso das 16h ("ESCALA DE AMANHÃ — prazo 18h") e o das 18h ("PRAZO DA ESCALA ENCERRADO") só olhavam
-- o dia da semana (alerta_dias_semana) e saíram na véspera de 12/10, feriado. Trabalho em feriado é
-- excepcional: escala para feriado continua podendo ser criada e enviada, mas não há cobrança de
-- escala para o dia. Usa a mesma tabela de feriados da URA (migration 64). Base: definição da produção
-- (igual à da homologação, fora uma linha de comentário).

create or replace function fn_alerta_prazo_escala()
returns void language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
begin
  if not (extract(isodow from v_amanha)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))) then
    return;
  end if;
  -- véspera de feriado: sem cobrança de escala (trabalho em feriado é excepcional)
  if exists (select 1 from feriados f where f.data = v_amanha) then
    return;
  end if;

  foreach v_tipo in array array['aviso', 'prazo'] loop
    v_hora := fn_config(case v_tipo when 'aviso' then 'alerta_escala_aviso' else 'alerta_escala_prazo' end)::time;
    continue when v_agora::time < v_hora;
    continue when exists (select 1 from alertas_enviados where tipo = v_tipo and data_ref = v_amanha);

    -- passou da janela (ou o aviso ficou para depois do prazo): registra sem enviar
    if v_agora::time > v_hora + interval '2 hours'
       or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
      insert into alertas_enviados (tipo, data_ref, enviado) values (v_tipo, v_amanha, false);
      continue;
    end if;

    v_p    := fn_pendencias_escala(v_amanha);
    v_qtd  := jsonb_array_length(v_p->'sem_escala');
    v_rasc := (v_p->>'rascunhos')::int;
    insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
    values (v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

    continue when v_qtd = 0 and v_rasc = 0;

    select string_agg('• ' || (x->>'nome'), E'\n')
      into v_nomes
    from (select x from jsonb_array_elements(v_p->'sem_escala') x limit 15) s;
    if v_qtd > 15 then v_nomes := v_nomes || E'\n• e mais ' || (v_qtd - 15); end if;

    v_texto := case v_tipo
      when 'aviso' then '⏰ *ESCALA DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
      else '⚠️ *PRAZO DA ESCALA ENCERRADO*'
    end || E'\n\n'
      || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
      || case when v_qtd > 0 then v_qtd || ' técnico(s) sem escala:' || E'\n' || v_nomes || E'\n\n' else '' end
      || case when v_rasc > 0 then v_rasc || ' escala(s) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
      || case v_tipo
           when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
           else 'A equipe precisa receber a escala ainda hoje.'
         end;

    perform fn_avisar_supervisores(v_texto);
  end loop;
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
