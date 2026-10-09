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
create function pg_temp.hash_ref(m public.ponto_marcacoes) returns text language sql immutable
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
       where p.oid = 'public.fn_ponto_hash(public.ponto_marcacoes)'::pg_catalog.regprocedure)
     is distinct from '247462d5b4ddf075d63b9008ed50d28a/sql' then
    raise exception 'fn_ponto_hash do backup difere da fórmula da migration 54';
  end if;
end $$;

do $$
declare a record; m public.ponto_marcacoes; v_ant text; v_esp bigint; v_total bigint := 0;
begin
  if not exists (select 1 from ancora) and exists (select 1 from public.ponto_marcacoes) then
    raise exception 'âncora vazia num backup com marcações';
  end if;
  for a in select * from ancora where ultimo > 0 loop
    if not exists (select 1 from public.ponto_marcacoes
                    where empresa_id = a.empresa_id and nsr = a.ultimo and hash = a.ultimo_hash) then
      raise exception 'âncora de % não confere: empresa %, NSR %', a.gerada_em, a.empresa_id, a.ultimo;
    end if;
  end loop;
  for a in select distinct empresa_id from public.ponto_marcacoes loop
    v_ant := repeat('0', 64); v_esp := 1;
    for m in select * from public.ponto_marcacoes where empresa_id = a.empresa_id order by nsr loop
      if m.nsr <> v_esp or m.hash_anterior <> v_ant or m.hash <> pg_temp.hash_ref(m) then
        raise exception 'cadeia quebrada: empresa %, NSR %', a.empresa_id, m.nsr;
      end if;
      v_ant := m.hash; v_esp := v_esp + 1; v_total := v_total + 1;
    end loop;
  end loop;
  raise notice 'Âncoras conferidas: % (de % a %); % marcação(ões) com cadeia íntegra',
    (select count(*) from ancora), (select min(gerada_em) from ancora), (select max(gerada_em) from ancora), v_total;
end $$;
