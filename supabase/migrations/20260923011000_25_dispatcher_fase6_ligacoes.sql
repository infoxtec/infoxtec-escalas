-- 25 | Fase 6 do dispatcher: dispara as ligacoes da URA quando ligacao_ativa = true
-- O corpo completo do dispatcher (fases 1 a 6) esta aplicado no banco; aqui fica a
-- funcao de disparo e a chamada da fase 6 ao fim de fn_dispatcher_whatsapp.

create or replace function fn_disparar_ligacoes()
returns int language plpgsql volatile
set search_path = public, extensions as $$
declare
  p record; v_lig jsonb; v_n int := 0;
  v_max int := coalesce(fn_config_int('ligacao_por_execucao'), 2);
begin
  if not coalesce(fn_config('ligacao_ativa'), 'false')::boolean then return 0; end if;
  if coalesce(fn_config('twilio_caller_id'), '') = '' then return 0; end if;

  for p in select * from vw_ligacoes_pendentes order by tentativas_whatsapp desc loop
    exit when v_n >= v_max;
    begin
      v_lig := fn_preparar_ligacao(p.escala_id);
      perform net.http_post(
        url  := fn_config('voz_url') || '?acao=iniciar&token=' || fn_segredo('VOZ_TOKEN'),
        body := jsonb_build_object('ligacao_id', v_lig->>'ligacao_id'));
      v_n := v_n + 1;
    exception when others then
      raise warning 'ligacao falhou para escala %: %', p.escala_id, sqlerrm;
    end;
  end loop;
  return v_n;
end $$;

-- Ao fim de fn_dispatcher_whatsapp (apos as fases 4 e 5):
--   begin perform fn_disparar_ligacoes();
--   exception when others then raise warning 'ligacoes falharam: %', sqlerrm; end;
