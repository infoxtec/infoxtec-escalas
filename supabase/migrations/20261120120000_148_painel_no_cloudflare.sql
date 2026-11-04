-- Migration 148 (04/11/2026): virada do painel da produção para o Cloudflare (A5 da sprint 04–17/11, decisão 133).
-- A config `app_url` monta os links enviados pelo WhatsApp (ponto, espelho para assinar). Ela passa do endereço da
-- Vercel para o Worker `trilha` só onde ainda é o da Vercel: na produção (e num banco vazio, que nasce com o valor da
-- migration 89). A homologação já aponta para o Worker dela (24/10) e não muda. Sem função nova nem alterada.
-- Os QR dos espelhos já emitidos continuam com o endereço da Vercel impresso: a Vercel vira só redirecionamento (B7).
set lock_timeout = '5s';

update interno.config
   set valor = 'https://trilha.david-cerqueira.workers.dev'
 where chave = 'app_url'
   and rtrim(valor, '/') = 'https://infoxtec-escalas.vercel.app';
