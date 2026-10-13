-- Agendador da HOMOLOGAÇÃO (decisão 94). Só no projeto infoxtec-escalas-dev, depois de
-- supabase/setup/homologacao-whatsapp.sql e dos segredos da instância trilha-homologacao no Vault.
-- As mesmas tarefas do cron.sql da produção; o envio fica preso aos números de teste pela trava de
-- ambiente (decisão 44) e a ligação automática segue desligada (config ligacao_ativa = false).
-- Nunca rode o supabase/setup/cron.sql da produção aqui, nem este arquivo na produção: ele recusa.
do $$
begin
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao'
     or coalesce(fn_config('webhook_url'), '') not like '%oruwnlxyvznpigbpjjbx%'
     or coalesce(fn_config('evolution_instancia'), '') <> 'trilha-homologacao' then
    raise exception 'Este banco não é a homologação configurada para o WhatsApp (rode antes o homologacao-whatsapp.sql).';
  end if;
  if coalesce(fn_config('ligacao_ativa'), 'false') <> 'false' then
    raise exception 'A ligação automática precisa ficar desligada na homologação (config ligacao_ativa = false).';
  end if;
  perform cron.schedule('dispatcher-whatsapp', '* * * * *', 'select fn_dispatcher_whatsapp()');
  perform cron.schedule('limpeza-logs', '17 6 * * *', 'select fn_limpeza_logs()');
  perform cron.schedule('vigia-motor', '*/5 * * * *', 'select fn_vigiar_motor()');
  perform cron.schedule('ponto-lembrete-almoco', '*/15 * * * *', 'select fn_ponto_lembrete_almoco()');
  perform cron.schedule('ponto-geo', '* * * * *', 'select fn_ponto_geo_processar()');
  raise notice 'Agendador da homologação ligado: % tarefas ativas.', (select count(*) from cron.job where active);
end $$;

-- Para desligar tudo (parar os testes de WhatsApp):
-- select cron.unschedule(jobname) from cron.job;
