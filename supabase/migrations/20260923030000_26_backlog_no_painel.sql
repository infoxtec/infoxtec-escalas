-- 26 | Backlog dentro do sistema: aba Roadmap (administradores)

create table if not exists backlog_itens (
  id          uuid primary key default gen_random_uuid(),
  numero      int,
  tipo        text not null default 'backlog' check (tipo in ('backlog','entrega','divida')),
  titulo      text not null,
  descricao   text,
  status      text not null default 'planejado'
              check (status in ('concluido','parcial','em_andamento','bloqueado','planejado')),
  esforco     text check (esforco in ('P','M','G')),
  depende_de  text,
  observacao  text,
  entregue_em date,
  ordem       int not null default 100,
  updated_at  timestamptz not null default now()
);
alter table backlog_itens enable row level security;

create or replace function app_backlog()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'numero', numero, 'tipo', tipo, 'titulo', titulo, 'descricao', descricao,
    'status', status, 'esforco', esforco, 'depende_de', depende_de, 'observacao', observacao,
    'entregue_em', entregue_em, 'ordem', ordem, 'updated_at', updated_at) order by ordem, numero)
    from backlog_itens), '[]'::jsonb);
end $$;

create or replace function app_salvar_backlog_item(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid;
begin
  perform app_exigir(array['admin']);
  if coalesce(trim(p->>'titulo'),'') = '' then raise exception 'Título é obrigatório.'; end if;
  if v_id is null then
    insert into backlog_itens (numero, tipo, titulo, descricao, status, esforco, depende_de, observacao, entregue_em, ordem)
    values (nullif(p->>'numero','')::int, coalesce(nullif(p->>'tipo',''),'backlog'), trim(p->>'titulo'),
            nullif(trim(p->>'descricao'),''), coalesce(nullif(p->>'status',''),'planejado'),
            nullif(p->>'esforco',''), nullif(trim(p->>'depende_de'),''), nullif(trim(p->>'observacao'),''),
            nullif(p->>'entregue_em','')::date, coalesce(nullif(p->>'ordem','')::int, 100))
    returning id into v_id;
  else
    update backlog_itens set
      numero = nullif(p->>'numero','')::int, tipo = coalesce(nullif(p->>'tipo',''), tipo),
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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function app_backlog(), app_salvar_backlog_item(jsonb) to authenticated;

-- A carga inicial dos 9 itens do backlog, das entregas e das dividas tecnicas
-- esta em supabase/setup/backlog_seed.sql (dados, nao estrutura).
