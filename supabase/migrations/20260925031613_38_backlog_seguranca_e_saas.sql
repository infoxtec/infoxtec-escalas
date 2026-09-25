-- 38 | Dois grupos novos no Roadmap: seguranca/homologacao e transformacao em SaaS.
--
-- ATENCAO (licao aprendida): a constraint e os itens foram criados antes de o painel
-- publicado conhecer os grupos novos, e a aba Roadmap quebrou. Os itens foram entao
-- movidos para o grupo 'backlog', com prefixo no titulo, ate a versao 3.1 do painel
-- entrar no ar. Depois do deploy, rodar supabase/setup/backlog_grupos.sql para
-- reclassifica-los. Regra: alterar dados que a tela consome SO depois de a tela suportar.

alter table backlog_itens drop constraint if exists backlog_itens_tipo_check;
alter table backlog_itens add constraint backlog_itens_tipo_check
  check (tipo in ('backlog','entrega','divida','seguranca','saas'));

-- Os itens de seguranca e SaaS estao em supabase/setup/backlog_seguranca_saas.sql
-- (dados, nao estrutura), para poderem ser recarregados em outro ambiente.
