-- Agendamento do dispatcher (pg_cron). NAO e migration: rode uma vez por projeto,
-- depois de aplicar as migrations e cadastrar os segredos no Vault.
-- No projeto atual ja existe (job criado em 21/09/2026).
select cron.schedule('dispatcher-whatsapp', '* * * * *', $$select fn_dispatcher_whatsapp()$$);
