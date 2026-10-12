-- Migration 81 (13/10/2026): endurecimento, pendência da revisão de segurança do PR #3.
-- monitor_ping_url passa a aceitar só https://hc-ping.com/<uuid> (ou vazio): o motor chama essa URL a cada
-- minuto, e um endereço qualquer viraria um vazamento de sinal para terceiros. A produção já usa esse
-- formato (conferido em 12/10). Base: definição da migration 80.

create or replace function fn_validar_config()
returns trigger language plpgsql set search_path to 'public', 'extensions' as $function$
declare
  v text := coalesce(new.valor, '');
begin
  begin
    if new.chave in ('envios_por_execucao','max_tentativas','avisar_supervisor_na','intervalo_reenvio_min',
                     'timeout_entrega_min','motor_alerta_min','jornada_min','intervalo_min','intervalo_apos_min',
                     'antecedencia_minima_min','certificacao_aviso_dias','documento_tamanho_max_mb',
                     'ligacao_apos_tentativas','ligacao_intervalo_min','ligacao_max_por_escala',
                     'ligacao_por_execucao','voz_timeout_dtmf','retencao_webhook_dias','retencao_cron_dias',
                     'retencao_documentos_anos','retencao_payload_dias','conclusao_automatica_min',
                     'banco_alerta_mb','alerta_certificacoes_dow') then
      if v !~ '^\d+$' then raise exception 'inteiro'; end if;
      -- 0 desliga; 1 (segunda) a 7 (domingo), o mesmo dia ISO que fn_alerta_certificacoes compara como
      -- texto: um dígito só ('07' passaria no inteiro e nunca dispararia)
      if new.chave = 'alerta_certificacoes_dow' and v !~ '^[0-7]$' then raise exception 'dia'; end if;
    elsif new.chave = 'hora_noturna_min' then
      if v::numeric <= 0 then raise exception 'positivo'; end if;
    elsif new.chave in ('janela_envio_inicio','janela_envio_fim','alerta_escala_aviso','alerta_escala_prazo',
                        'alerta_certificacoes_hora','ligacao_janela_inicio','ligacao_janela_fim',
                        'noturno_inicio','noturno_fim') then
      if v !~ '^\d{2}:\d{2}$' then raise exception 'hora'; end if;
      perform v::time;
    elsif new.chave in ('webhook_ativo','usar_botoes','ligacao_ativa','sem_escala_incluir_supervisores') then
      if v not in ('true','false') then raise exception 'booleano'; end if;
    elsif new.chave = 'fuso' then
      if not exists (select 1 from pg_timezone_names where name = v) then raise exception 'fuso'; end if;
    elsif new.chave = 'alerta_dias_semana' then
      if v !~ '^[1-7](,[1-7])*$' then raise exception 'dias'; end if;
    elsif new.chave = 'alerta_tecnico_telefones' then
      if v <> '' and v !~ '^\d{12,13}(\s*,\s*\d{12,13})*$' then raise exception 'telefones'; end if;
    elsif new.chave = 'monitor_ping_url' then
      -- só o endereço de ping do healthchecks.io: a URL é chamada pelo motor a cada minuto
      if v <> '' and v !~ '^https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'url';
      end if;
    end if;
  exception when others then
    raise exception 'Valor inválido para %: "%"', new.chave, new.valor
      using hint = case new.chave
        when 'alerta_dias_semana' then 'Use dias de 1 (segunda) a 7, separados por vírgula: 1,2,3,4,5'
        when 'alerta_certificacoes_dow' then 'Use 1 (segunda) a 7 (domingo); 0 desliga o alerta'
        when 'monitor_ping_url' then 'Use o endereço de ping do healthchecks.io: https://hc-ping.com/<uuid>, ou vazio'
        when 'alerta_tecnico_telefones' then 'Use telefones com DDI e DDD, só números, separados por vírgula: 5571999999999'
        when 'fuso' then 'Use um fuso válido, por exemplo America/Bahia'
        else 'Confira o formato: inteiro, hora HH:MM ou true/false' end;
  end;
  return new;
end $function$;

-- o gatilho só valida o que se grava daqui em diante: avisa se o valor atual já estiver fora do padrão
do $$
begin
  if coalesce((select valor from config where chave = 'monitor_ping_url'), '') !~
     '^(|https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$' then
    raise warning 'monitor_ping_url atual fora do padrão hc-ping.com/<uuid>: corrigir pelo painel';
  end if;
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
