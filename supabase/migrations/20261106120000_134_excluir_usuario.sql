-- Exclusão definitiva de usuário do painel (pedido do responsável em 30/10): o administrador da conta (ou a plataforma)
-- tira a pessoa da conta de vez, e não só desativa. Se ela não for de nenhuma outra conta nem da plataforma, a Edge
-- Function excluir-usuario apaga também o login no Supabase Auth. Fica só o registro da exclusão (quem, quando, de
-- qual conta), o mesmo cuidado dos outros históricos de acesso.

set lock_timeout = '5s';

create table interno.usuarios_excluidos (
  id bigint generated always as identity primary key,
  conta_id uuid not null references interno.contas (id) default interno.fn_conta_padrao(),
  email text not null check (email = lower(btrim(email))),
  papel text not null check (papel in ('admin', 'gestor', 'leitura')),
  autor text not null,
  em timestamptz not null default now(),
  -- mantido: o login segue (outra conta ou plataforma); pendente: a apagar pela Edge Function (login_id guardado para
  -- repetir se ela cair no meio); apagado ou falhou: o resultado
  situacao text not null check (situacao in ('mantido', 'pendente', 'apagado', 'falhou')),
  login_id uuid
);
alter table interno.usuarios_excluidos enable row level security;
create index usuarios_excluidos_conta_idx on interno.usuarios_excluidos (conta_id, em desc);

-- o histórico de convites fica depois da exclusão (limite de envio e prova); a conferência de que o e-mail é membro
-- continua na fn_convite_autorizar
alter table interno.convites drop constraint convites_conta_id_email_fkey;

-- Quem pode, o que sai e se o login some. Chamada só pela Edge Function excluir-usuario, com o autor já conferido no
-- servidor de autenticação (mesmo desenho da fn_convite_autorizar). Devolve o id do login a apagar, ou null.
create or replace function interno.fn_usuario_excluir(p_autor text, p_aal text, p_conta uuid, p_email text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_autor text := lower(btrim(p_autor));
  v_email text := lower(btrim(p_email));
  v_plataforma boolean;
  m conta_membros;
  v_resta boolean;
  v_login uuid;
  v_id bigint;
begin
  if not exists (select 1 from contas where id = p_conta) then
    raise exception 'Conta não encontrada.';
  end if;
  v_plataforma := exists (select 1 from plataforma_admins where email = v_autor);
  if v_plataforma then
    if coalesce(p_aal, 'aal1') <> 'aal2' then
      raise exception 'Ative e confirme a verificação em duas etapas para excluir.';
    end if;
  elsif not exists (select 1 from conta_membros where conta_id = p_conta and email = v_autor and ativo and papel = 'admin') then
    raise exception 'Sem permissão para esta ação.';
  elsif coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true' and coalesce(p_aal, 'aal1') <> 'aal2' then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  if v_email = v_autor then
    raise exception 'Você não pode excluir o próprio usuário.';
  end if;

  -- o último administrador ativo não sai (linhas travadas: duas exclusões ao mesmo tempo)
  perform 1 from conta_membros where conta_id = p_conta and papel = 'admin' and ativo order by email for update;
  select * into m from conta_membros where conta_id = p_conta and email = v_email for update;
  if not found then raise exception 'Usuário não encontrado nesta conta.'; end if;
  if m.papel = 'admin' and m.ativo
     and (select count(*) from conta_membros where conta_id = p_conta and papel = 'admin' and ativo) = 1 then
    raise exception 'Este é o único administrador ativo. Cadastre outro administrador antes.';
  end if;

  -- retenção (LGPD, legítimo interesse: prova de quem tirou o acesso): o registro da exclusão vale 5 anos
  delete from usuarios_excluidos where em < now() - interval '5 years';
  delete from conta_membros where conta_id = p_conta and email = v_email;

  -- o login só some se a pessoa não for de outra conta nem da plataforma
  v_resta := exists (select 1 from conta_membros where email = v_email)
             or exists (select 1 from plataforma_admins where email = v_email);
  if not v_resta then
    select u.id into v_login from auth.users u where lower(u.email) = v_email limit 1;
  end if;
  insert into usuarios_excluidos (conta_id, email, papel, autor, situacao, login_id)
  values (p_conta, v_email, m.papel, v_autor, case when v_login is null then 'mantido' else 'pendente' end, v_login)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'login', v_login, 'email', v_email, 'plataforma', v_plataforma);
end $function$;

-- conferida de novo logo antes de apagar o login: um convite de outra conta pode ter chegado depois da exclusão
create or replace function interno.fn_usuario_login_livre(p_email text)
 returns boolean
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select not exists (select 1 from interno.conta_membros where email = lower(btrim(p_email)))
     and not exists (select 1 from interno.plataforma_admins where email = lower(btrim(p_email)))
$function$;

create or replace function interno.fn_usuario_excluir_resultado(p_id bigint, p_apagado boolean)
 returns void
 language sql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  -- null: a pessoa voltou a ser membro no meio (convite de outra conta) e o login fica
  update interno.usuarios_excluidos set situacao = case when p_apagado is null then 'mantido' when p_apagado then 'apagado' else 'falhou' end
   where id = p_id and situacao = 'pendente'
$function$;

-- histórico de exclusões da conta (tela Usuários)
create or replace function public.app_usuarios_excluidos()
 returns table(email text, papel text, autor text, em timestamptz)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin']);
  return query select x.email, x.papel, x.autor, x.em from interno.usuarios_excluidos x
                where x.conta_id = fn_conta_atual() order by x.em desc limit 50;
end $function$;


do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
