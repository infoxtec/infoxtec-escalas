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

-- Cópia fiel de fn_ponto_rep_hash(ponto_rep_registros) da migration 157 (registros do REP, tipos 2 e 5, decisão 139).
-- Antes da 157 a tabela não existe: a cópia vira um stub que nunca é chamado (a cadeia só tem marcações).
select pg_catalog.current_setting('ancora.rep') = 'true' as tem_rep \gset
\if :tem_rep
create function pg_temp.hash_ref_rep(r :"esq".ponto_rep_registros) returns text language sql immutable
  set search_path = pg_catalog, pg_temp as $$
  select encode(sha256(convert_to(array_to_string(array[
           'REP', r.hash_anterior, r.conta_id::text, r.empresa_id::text, r.nsr::text, r.tipo::text,
           to_char(r.momento at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
           coalesce(r.operacao, ''), coalesce(r.tecnico_id::text, ''),
           coalesce(r.dados ->> 'cnpj', ''), coalesce(r.dados ->> 'cno_caepf', ''), coalesce(r.dados ->> 'razao', ''),
           coalesce(r.dados ->> 'local', ''), coalesce(r.dados ->> 'cpf', ''), coalesce(r.dados ->> 'nome', ''),
           coalesce(r.dados ->> 'cpf_responsavel', '')], '|'), 'UTF8')), 'hex')
$$;
do $$
begin
  if (select pg_catalog.md5(p.prosrc) || '/' || l.lanname from pg_catalog.pg_proc p
        join pg_catalog.pg_language l on l.oid = p.prolang
       where p.oid = pg_catalog.format('%1$s.fn_ponto_rep_hash(%1$s.ponto_rep_registros)',
                                       pg_catalog.current_setting('ancora.esq'))::pg_catalog.regprocedure)
     is distinct from 'ed3798d3e904f48996f26f6bacf445fa/sql' then
    raise exception 'fn_ponto_rep_hash do backup difere da fórmula da migration 157';
  end if;
end $$;
\endif

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
  v_rep boolean := pg_catalog.current_setting('ancora.rep') = 'true';
  -- todos os registros da cadeia: marcações e, depois da 157, os registros do REP (mesmo NSR, mesma cadeia)
  v_reg text := case when pg_catalog.current_setting('ancora.rep') = 'true'
                     then pg_catalog.format('(select empresa_id, nsr, hash, hash_anterior, momento, pg_temp.hash_ref(x) as calculado
                                                from %1$I.ponto_marcacoes x
                                              union all
                                              select empresa_id, nsr, hash, hash_anterior, momento, pg_temp.hash_ref_rep(y)
                                                from %1$I.ponto_rep_registros y)', v_esq)
                     else pg_catalog.format('(select empresa_id, nsr, hash, hash_anterior, momento, pg_temp.hash_ref(x) as calculado
                                                from %I.ponto_marcacoes x)', v_esq) end;
begin
  execute pg_catalog.format('select exists (select 1 from %I.ponto_marcacoes)', v_esq) into v_ha;
  if not exists (select 1 from ancora) and v_ha then
    raise exception 'âncora vazia num backup com marcações';
  end if;
  for a in select * from ancora where ultimo > 0 loop
    execute pg_catalog.format('select exists (select 1 from %s r where empresa_id = $1 and nsr = $2 and hash = $3)', v_reg)
       into v_ha using a.empresa_id, a.ultimo, a.ultimo_hash;
    -- âncora anterior ao reinício autorizado do módulo de ponto (decisão 138): a marcação dela foi apagada; vale se o
    -- banco restaurado tem o registro do reinício, feito depois dela, com aquela empresa e NSR igual ou maior (a
    -- autorização fora do banco é conferida no backup diário, ancora-anterior.sh)
    if not v_ha and pg_catalog.to_regclass(v_esq || '.ponto_reinicios') is not null then
      execute pg_catalog.format('select exists (select 1 from %1$I.ponto_reinicios r
          cross join lateral pg_catalog.jsonb_to_recordset(r.empresas) e(empresa_id uuid, ultimo_nsr bigint, ultimo_hash text)
          where r.feito_em > $3::timestamptz and e.empresa_id = $1 and e.ultimo_nsr >= $2
            and coalesce((select pg_catalog.min(m.nsr) from %2$s m where m.empresa_id = $1), 1) = 1
            and not exists (select 1 from %2$s m where m.empresa_id = $1 and m.momento <= r.feito_em))', v_esq, v_reg)
         into v_ha using a.empresa_id, a.ultimo, a.gerada_em;
      if v_ha then
        raise notice 'âncora de % anterior ao reinício do módulo de ponto: empresa %, NSR % (não conferida)', a.gerada_em, a.empresa_id, a.ultimo;
        continue;
      end if;
    end if;
    if not v_ha then
      raise exception 'âncora de % não confere: empresa %, NSR %', a.gerada_em, a.empresa_id, a.ultimo;
    end if;
  end loop;
  for a in execute pg_catalog.format('select distinct empresa_id from %s r', v_reg) loop
    v_ant := repeat('0', 64); v_esp := 1;
    for m in execute pg_catalog.format('select x.nsr, x.hash_anterior, x.hash, x.calculado
                                          from %s x where x.empresa_id = $1 order by x.nsr', v_reg)
             using a.empresa_id loop
      if m.nsr <> v_esp or m.hash_anterior <> v_ant or m.hash <> m.calculado then
        raise exception 'cadeia quebrada: empresa %, NSR %', a.empresa_id, m.nsr;
      end if;
      v_ant := m.hash; v_esp := v_esp + 1; v_total := v_total + 1;
    end loop;
  end loop;
  raise notice 'Âncoras conferidas: % (de % a %); % registro(s) com cadeia íntegra',
    (select count(*) from ancora), (select min(gerada_em) from ancora), (select max(gerada_em) from ancora), v_total;
end $$;
