-- Incluído pelos scripts da âncora (\ir): recusa conferir se ponto_marcacoes não for a tabela
-- da migration 54 com os tipos exatos das colunas que entram no hash. Quem trocasse uma coluna por um
-- tipo próprio (com "=" que sempre concorda) ou a tabela por uma view enganaria a conferência.
-- Os scripts rodam com search_path = pg_catalog, pg_temp: nada é chamado sem o nome do esquema.
-- O esquema das tabelas do ponto é `interno` desde a migration 115 (antes, `public`): fica na variável :esq
-- do psql e no parâmetro ancora.esq; as duas ao mesmo tempo é recusado (ninguém planta uma cópia no outro).
select case when pg_catalog.to_regclass('interno.ponto_marcacoes') is not null then 'interno' else 'public' end as esq \gset
select pg_catalog.set_config('ancora.esq', :'esq', false);
do $$
declare v_falta text; v_esq text := pg_catalog.current_setting('ancora.esq');
begin
  if pg_catalog.to_regclass('interno.ponto_marcacoes') is not null
     and pg_catalog.to_regclass('public.ponto_marcacoes') is not null then
    raise exception 'âncora: ponto_marcacoes em public e em interno ao mesmo tempo';
  end if;
  if (select c.relkind from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = v_esq and c.relname = 'ponto_marcacoes') is distinct from 'r' then
    raise exception 'âncora: %.ponto_marcacoes não é uma tabela comum', v_esq;
  end if;
  select pg_catalog.string_agg(e.col || ' ' || e.tipo, ', ') into v_falta
    from (values ('empresa_id','uuid'), ('nsr','bigint'), ('tecnico_id','uuid'), ('cpf','text'),
                 ('momento','timestamp with time zone'), ('tipo','text'), ('canal','text'),
                 ('latitude','numeric(9,6)'), ('longitude','numeric(9,6)'), ('precisao_m','integer'),
                 ('local_id','uuid'), ('distancia_m','integer'), ('dentro_area','boolean'),
                 ('escala_id','uuid'), ('origem','jsonb'), ('hash_anterior','text'), ('hash','text')) e(col, tipo)
   where not exists (select 1 from pg_catalog.pg_attribute a
                      where a.attrelid = pg_catalog.to_regclass(v_esq || '.ponto_marcacoes') and a.attnum > 0
                        and not a.attisdropped and a.attname = e.col
                        and pg_catalog.format_type(a.atttypid, a.atttypmod) = e.tipo);
  if v_falta is not null then
    raise exception 'âncora: colunas de ponto_marcacoes fora do esperado: %', v_falta;
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_attribute a
       where a.attrelid = pg_catalog.to_regclass(v_esq || '.ponto_nsr') and not a.attisdropped
         and (a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)) in
             (('empresa_id', 'uuid'), ('ultimo', 'bigint'), ('ultimo_hash', 'text'))) <> 3 then
    raise exception 'âncora: colunas de ponto_nsr fora do esperado';
  end if;
end $$;
