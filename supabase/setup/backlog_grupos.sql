-- Reclassifica os itens de seguranca e SaaS nos grupos proprios.
-- Rodar SOMENTE depois que o painel na versao 3.1 (ou superior) estiver publicado:
-- versoes anteriores nao conhecem esses grupos e a aba Roadmap para de abrir.

update backlog_itens
   set tipo = 'seguranca', titulo = regexp_replace(titulo, '^Segurança · ', ''), updated_at = now()
 where titulo like 'Segurança · %';

update backlog_itens
   set tipo = 'saas', titulo = regexp_replace(titulo, '^SaaS · ', ''), updated_at = now()
 where titulo like 'SaaS · %';

select tipo, count(*) from backlog_itens group by tipo order by tipo;
