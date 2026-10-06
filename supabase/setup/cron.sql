-- Agendamento do dispatcher (pg_cron). NAO e migration: rode uma vez por projeto,
-- depois de aplicar as migrations e cadastrar os segredos no Vault.
-- No projeto atual ja existe (job criado em 21/09/2026).
select cron.schedule('dispatcher-whatsapp', '* * * * *', $$select fn_dispatcher_whatsapp()$$);

-- Limpeza de logs (migration 39): todo dia as 03h17 da Bahia (06h17 UTC).
select cron.schedule('limpeza-logs', '17 6 * * *', $$select fn_limpeza_logs()$$);

-- Vigia do motor (migration 44): a cada 5 minutos, avisa os supervisores se o motor parou.
select cron.schedule('vigia-motor', '*/5 * * * *', $$select fn_vigiar_motor()$$);

-- Lembrete da saída para o almoço do ponto (migration 56): a cada 15 minutos; a função só envia
-- entre o horário de config ponto_lembrete_almoco e 15h, uma vez por dia por funcionário.
select cron.schedule('ponto-lembrete-almoco', '*/15 * * * *', $$select fn_ponto_lembrete_almoco()$$);

-- Bairro e cidade das marcações do ponto (migration 58): uma consulta ao OpenStreetMap por minuto.
select cron.schedule('ponto-geo', '* * * * *', $$select fn_ponto_geo_processar()$$);
