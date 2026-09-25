-- 28 | Kanban operacional do backlog

alter table backlog_itens add column if not exists coluna text not null default 'backlog'
  check (coluna in ('backlog','a_fazer','fazendo','revisao','feito'));
alter table backlog_itens add column if not exists posicao int not null default 0;

update backlog_itens set coluna = case
    when status = 'concluido' then 'feito'
    when status = 'parcial' then 'revisao'
    when status = 'em_andamento' then 'fazendo'
    else 'backlog' end
where coluna = 'backlog';

update backlog_itens b set posicao = s.pos
from (select id, row_number() over (partition by coluna order by ordem, numero) as pos
      from backlog_itens) s where s.id = b.id;

create or replace function app_mover_backlog_item(p_id uuid, p_coluna text, p_posicao int default null)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_status text;
begin
  perform app_exigir(array['admin']);
  if p_coluna not in ('backlog','a_fazer','fazendo','revisao','feito') then
    raise exception 'Coluna inválida.';
  end if;
  select status into v_status from backlog_itens where id = p_id;
  if not found then raise exception 'Item não encontrado.'; end if;

  update backlog_itens set
    coluna  = p_coluna,
    posicao = coalesce(p_posicao,
                (select coalesce(max(posicao), 0) + 1 from backlog_itens where coluna = p_coluna)),
    status = case
      when p_coluna = 'feito'   and v_status not in ('concluido','parcial') then 'concluido'
      when p_coluna = 'revisao' and v_status = 'planejado'                  then 'em_andamento'
      when p_coluna = 'fazendo' and v_status in ('planejado','bloqueado')   then 'em_andamento'
      when p_coluna in ('backlog','a_fazer') and v_status = 'em_andamento'  then 'planejado'
      else v_status end,
    entregue_em = case when p_coluna = 'feito'
                       then coalesce(entregue_em, (now() at time zone fn_config('fuso'))::date)
                       else entregue_em end,
    updated_at = now()
  where id = p_id;
end $$;

create or replace function app_backlog()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'numero', numero, 'tipo', tipo, 'titulo', titulo, 'descricao', descricao,
    'status', status, 'esforco', esforco, 'depende_de', depende_de, 'observacao', observacao,
    'entregue_em', entregue_em, 'ordem', ordem, 'coluna', coluna, 'posicao', posicao,
    'updated_at', updated_at) order by ordem, numero)
    from backlog_itens), '[]'::jsonb);
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
