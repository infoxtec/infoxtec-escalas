-- 43 | Backlog numerado em sequencia unica (001, 002, ...)
--
-- Regra combinada em 26/09/2026: todo registro do backlog tem numero, em sequencia unica para
-- todos os grupos (backlog, entregas, dividas, seguranca, SaaS). O painel exibe com tres digitos.
-- 1. Itens sem numero recebem o proximo, na ordem em que aparecem no Roadmap (ordem, titulo).
-- 2. Numero repetido: o item que aparece primeiro fica com ele; os outros recebem o proximo livre.
-- 3. Numero passa a ser obrigatorio e unico, e e atribuido pelo banco: quem cria nao escolhe.

do $$
declare r record; v_prox int;
begin
  select coalesce(max(numero), 0) into v_prox from backlog_itens;
  for r in
    select id from (
      select id, numero, ordem, titulo,
             row_number() over (partition by numero order by ordem, titulo, id) as rep
      from backlog_itens
    ) x
    where numero is null or rep > 1
    -- primeiro os repetidos (na ordem do numero), depois os sem numero (na ordem do Roadmap)
    order by (numero is null), numero, ordem, titulo, id
  loop
    v_prox := v_prox + 1;
    update backlog_itens set numero = v_prox where id = r.id;
  end loop;
end $$;

alter table backlog_itens alter column numero set not null;
create unique index if not exists backlog_itens_numero_unico on backlog_itens (numero);

create or replace function fn_numerar_backlog()
returns trigger language plpgsql
set search_path = public, extensions as $$
begin
  if tg_op = 'UPDATE' then
    new.numero := old.numero;              -- numero nao muda depois de atribuido
  elsif new.numero is null then
    perform pg_advisory_xact_lock(hashtext('backlog_itens.numero'));
    select coalesce(max(numero), 0) + 1 into new.numero from backlog_itens;
  end if;
  return new;
end $$;

drop trigger if exists trg_backlog_numero on backlog_itens;
create trigger trg_backlog_numero before insert or update on backlog_itens
  for each row execute function fn_numerar_backlog();

create or replace function app_salvar_backlog_item(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid;
begin
  perform app_exigir(array['admin']);
  if coalesce(trim(p->>'titulo'),'') = '' then raise exception 'Título é obrigatório.'; end if;
  if v_id is null then
    -- numero atribuido pelo gatilho trg_backlog_numero
    insert into backlog_itens (tipo, titulo, descricao, status, esforco, depende_de, observacao, entregue_em, ordem)
    values (coalesce(nullif(p->>'tipo',''),'backlog'), trim(p->>'titulo'),
            nullif(trim(p->>'descricao'),''), coalesce(nullif(p->>'status',''),'planejado'),
            nullif(p->>'esforco',''), nullif(trim(p->>'depende_de'),''), nullif(trim(p->>'observacao'),''),
            nullif(p->>'entregue_em','')::date, coalesce(nullif(p->>'ordem','')::int, 100))
    returning id into v_id;
  else
    update backlog_itens set
      tipo = coalesce(nullif(p->>'tipo',''), tipo),
      titulo = trim(p->>'titulo'), descricao = nullif(trim(p->>'descricao'),''),
      status = coalesce(nullif(p->>'status',''), status), esforco = nullif(p->>'esforco',''),
      depende_de = nullif(trim(p->>'depende_de'),''), observacao = nullif(trim(p->>'observacao'),''),
      entregue_em = nullif(p->>'entregue_em','')::date,
      ordem = coalesce(nullif(p->>'ordem','')::int, ordem), updated_at = now()
    where id = v_id;
    if not found then raise exception 'Item não encontrado.'; end if;
  end if;
  return v_id;
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
