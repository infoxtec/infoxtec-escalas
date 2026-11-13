-- 154: número oficial do WhatsApp da produção no portão do webhook (decisão 137, migration 153).
--
-- Grava evolution_numero só na produção de verdade: ambiente = producao **e** instância da conta 1 = infoxtec. O banco
-- vazio do CI (sem instância) e a homologação (trilha-homologacao) não mudam. Só preenche se estiver vazio: um valor
-- já cadastrado à mão não é sobrescrito.
-- Número da empresa (não de pessoa): pode ficar no repositório (seguranca, revisão da 153).
-- Volta imediata na produção, se recusar o número certo: update interno.config set valor = '' where chave = 'evolution_numero';
update interno.config set valor = '557141019605'
 where chave = 'evolution_numero' and valor = ''
   and coalesce(interno.fn_config('ambiente'), 'producao') = 'producao'
   and interno.fn_config('evolution_instancia') = 'infoxtec';
