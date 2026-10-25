-- Confere, no banco restaurado pelo teste de restauração, as âncoras da cadeia do ponto
-- (scripts/backup/ancora-ponto.sql) reunidas em copia/ancoras.csv: a do próprio backup e a mais
-- antiga ainda guardada. Cada marcação ancorada tem de estar no backup com o mesmo hash, e a cadeia
-- inteira de cada empresa é recalculada (NSR sem lacuna, hash_anterior e hash). Como cada hash inclui
-- o anterior, uma âncora antiga que confere prova que nada até ela mudou.
--
-- O hash é recalculado por uma cópia de referência da fórmula (migration 54), não pela fn_ponto_hash
-- que veio no backup: quem trocasse a função na produção faria a cadeia "conferir" com dados
-- alterados. A fn_ponto_hash do backup nunca é executada (a conferência roda como superusuário):
-- só o texto dela é comparado com o da migration 54. Gatilhos e event triggers ficam desligados.
--   psql "$URL" -X -q -f scripts/backup/conferir-ancora.sql
\set ON_ERROR_STOP on
set search_path = pg_catalog, pg_temp;
set session_replication_role = replica;
\ir tipos-ponto.sql
create temp table ancora (empresa_id uuid, ultimo bigint, ultimo_hash text, gerada_em text);
\copy ancora from 'copia/ancoras.csv' with (format csv)

-- Cópia fiel de fn_ponto_hash(ponto_marcacoes) da migration 54. Se a fórmula mudar numa migration
-- nova, esta cópia muda junto (e as marcações antigas continuam conferindo pela fórmula delas).
create function pg_temp.hash_ref(m :"esq".ponto_marcacoes) returns text language sql immutable
  set search_path = pg_catalog, pg_temp as $$
  select encode(sha256(convert_to(array_to_string(array[
           m.hash_anterior, m.empresa_id::text, m.nsr::text, m.tecnico_id::text, m.cpf,
           to_char(m.momento at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
           m.tipo, m.canal, coalesce(m.latitude::text, ''), coalesce(m.longitude::text, ''),
           coalesce(m.precisao_m::text, ''), coalesce(m.local_id::text, ''),
           coalesce(m.distancia_m::text, ''), coalesce(m.dentro_area::text, ''),
           coalesce(m.escala_id::text, ''), m.origem::text], '|'), 'UTF8')), 'hex')
$$;

-- md5 do corpo de fn_ponto_hash(ponto_marcacoes) na migration 54 (muda junto com hash_ref)
do $$
begin
  if (select pg_catalog.md5(p.prosrc) || '/' || l.lanname from pg_catalog.pg_proc p
        join pg_catalog.pg_language l on l.oid = p.prolang
       where p.oid = pg_catalog.format('%1$s.fn_ponto_hash(%1$s.ponto_marcacoes)',
                                       pg_catalog.current_setting('ancora.esq'))::pg_catalog.regprocedure)
     is distinct from '247462d5b4ddf075d63b9008ed50d28a/sql' then
    raise exception 'fn_ponto_hash do backup difere da fórmula da migration 54';
  end if;
end $$;

do $$
declare a record; m record; v_ant text; v_esp bigint; v_total bigint := 0; v_ha boolean;
  v_esq text := pg_catalog.current_setting('ancora.esq');
begin
  execute pg_catalog.format('select exists (select 1 from %I.ponto_marcacoes)', v_esq) into v_ha;
  if not exists (select 1 from ancora) and v_ha then
    raise exception 'âncora vazia num backup com marcações';
  end if;
  for a in select * from ancora where ultimo > 0 loop
    execute pg_catalog.format('select exists (select 1 from %I.ponto_marcacoes where empresa_id = $1 and nsr = $2 and hash = $3)', v_esq)
       into v_ha using a.empresa_id, a.ultimo, a.ultimo_hash;
    if not v_ha then
      raise exception 'âncora de % não confere: empresa %, NSR %', a.gerada_em, a.empresa_id, a.ultimo;
    end if;
  end loop;
  for a in execute pg_catalog.format('select distinct empresa_id from %I.ponto_marcacoes', v_esq) loop
    v_ant := repeat('0', 64); v_esp := 1;
    for m in execute pg_catalog.format('select x.nsr, x.hash_anterior, x.hash, pg_temp.hash_ref(x) as calculado
                                          from %I.ponto_marcacoes x where x.empresa_id = $1 order by x.nsr', v_esq)
             using a.empresa_id loop
      if m.nsr <> v_esp or m.hash_anterior <> v_ant or m.hash <> m.calculado then
        raise exception 'cadeia quebrada: empresa %, NSR %', a.empresa_id, m.nsr;
      end if;
      v_ant := m.hash; v_esp := v_esp + 1; v_total := v_total + 1;
    end loop;
  end loop;
  raise notice 'Âncoras conferidas: % (de % a %); % marcação(ões) com cadeia íntegra',
    (select count(*) from ancora), (select min(gerada_em) from ancora), (select max(gerada_em) from ancora), v_total;
end $$;
