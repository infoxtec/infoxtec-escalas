-- Parametros de ambiente que nao entram nas migrations (variam por projeto).
insert into config (chave, valor, descricao) values
  ('evolution_instancia', 'infoxtec', 'Nome da instancia na Evolution API'),
  ('whatsapp_provedor',   'evolution', 'evolution ou meta'),
  ('webhook_url', 'https://<ref-do-projeto>.supabase.co/functions/v1/webhook-evolution',
   'Endereco da Edge Function que recebe os eventos da Evolution (o token vai no Vault)')
on conflict (chave) do update set valor = excluded.valor;
