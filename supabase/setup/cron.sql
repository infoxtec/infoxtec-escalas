-- Agendamento do dispatcher (pg_cron). NAO e migration: rode uma vez por projeto,
-- depois de aplicar as migrations e cadastrar os segredos no Vault.
-- No projeto atual ja existe (job criado em 21/09/2026).
select cron.schedule('dispatcher-whatsapp', '* * * * *', $$select fn_dispatcher_whatsapp()$$);

-- Limpeza de logs (migration 39): todo dia as 03h17 da Bahia (06h17 UTC).
select cron.schedule('limpeza-logs', '17 6 * * *', $$select fn_limpeza_logs()$$);
