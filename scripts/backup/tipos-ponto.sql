-- Incluído pelos scripts da âncora (\ir): recusa conferir se public.ponto_marcacoes não for a tabela
-- da migration 54 com os tipos exatos das colunas que entram no hash. Quem trocasse uma coluna por um
-- tipo próprio (com "=" que sempre concorda) ou a tabela por uma view enganaria a conferência.
-- Os scripts rodam com search_path = pg_catalog, pg_temp: nada do schema public é chamado sem nome.
do $$
declare v_falta text;
begin
  if (select c.relkind from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'ponto_marcacoes') is distinct from 'r' then
    raise exception 'âncora: public.ponto_marcacoes não é uma tabela comum';
  end if;
  select pg_catalog.string_agg(e.col || ' ' || e.tipo, ', ') into v_falta
    from (values ('empresa_id','uuid'), ('nsr','bigint'), ('tecnico_id','uuid'), ('cpf','text'),
                 ('momento','timestamp with time zone'), ('tipo','text'), ('canal','text'),
                 ('latitude','numeric(9,6)'), ('longitude','numeric(9,6)'), ('precisao_m','integer'),
                 ('local_id','uuid'), ('distancia_m','integer'), ('dentro_area','boolean'),
                 ('escala_id','uuid'), ('origem','jsonb'), ('hash_anterior','text'), ('hash','text')) e(col, tipo)
   where not exists (select 1 from pg_catalog.pg_attribute a
                      where a.attrelid = 'public.ponto_marcacoes'::pg_catalog.regclass and a.attnum > 0
                        and not a.attisdropped and a.attname = e.col
                        and pg_catalog.format_type(a.atttypid, a.atttypmod) = e.tipo);
  if v_falta is not null then
    raise exception 'âncora: colunas de ponto_marcacoes fora do esperado: %', v_falta;
  end if;
  if (select pg_catalog.count(*) from pg_catalog.pg_attribute a
       where a.attrelid = 'public.ponto_nsr'::pg_catalog.regclass and not a.attisdropped
         and (a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod)) in
             (('empresa_id', 'uuid'), ('ultimo', 'bigint'), ('ultimo_hash', 'text'))) <> 3 then
    raise exception 'âncora: colunas de ponto_nsr fora do esperado';
  end if;
end $$;
