-- Convite por e-mail pelo painel (decisão 120): o administrador da conta, ou a plataforma ao criar uma conta, convida
-- quem já é membro; a Edge Function convidar-usuario confere aqui e chama o convite do Supabase Auth. Ninguém cria
-- usuário à mão no Supabase.

set lock_timeout = '5s';

create table interno.convites (
  id bigint generated always as identity primary key,
  conta_id uuid not null references interno.contas (id) default interno.fn_conta_padrao(),
  email text not null,
  autor text not null,
  em timestamptz not null default now(),
  resultado text not null default 'pendente' check (resultado in ('pendente', 'enviado', 'ja_tinha_login', 'falhou')),
  -- só se convida quem é membro da conta (garantido no dado; membros são desativados, não apagados)
  foreign key (conta_id, email) references interno.conta_membros (conta_id, email)
);
alter table interno.convites enable row level security;
create index convites_autor_idx on interno.convites (autor, em desc);
create index convites_conta_idx on interno.convites (conta_id, email, em desc);

-- quem convida: a plataforma (duas etapas) em qualquer conta, ou o administrador da conta (duas etapas se a conta
-- exigir); o convidado precisa ser membro ativo da conta ativa. Limites: 20 convites por hora por autor e um por
-- e-mail a cada 10 minutos. Devolve o id do registro, que a Edge Function fecha com o resultado.
create or replace function interno.fn_convite_autorizar(p_autor text, p_aal text, p_conta uuid, p_email text)
 returns bigint language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_autor text := lower(btrim(p_autor));
  v_email text := lower(btrim(p_email));
  v_plataforma boolean;
  v_id bigint;
begin
  if not exists (select 1 from contas where id = p_conta and ativa) then
    raise exception 'Conta não encontrada.';
  end if;
  if not exists (select 1 from conta_membros where conta_id = p_conta and email = v_email and ativo) then
    raise exception 'Cadastre o usuário na conta antes de convidar.';
  end if;
  v_plataforma := exists (select 1 from plataforma_admins where email = v_autor);
  if v_plataforma then
    if coalesce(p_aal, 'aal1') <> 'aal2' then
      raise exception 'Ative e confirme a verificação em duas etapas para convidar.';
    end if;
  elsif not exists (select 1 from conta_membros where conta_id = p_conta and email = v_autor and ativo and papel = 'admin') then
    raise exception 'Sem permissão para esta ação.';
  elsif coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true' and coalesce(p_aal, 'aal1') <> 'aal2' then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  -- pedidos simultâneos do mesmo autor ou para o mesmo e-mail esperam um ao outro (limites sem corrida)
  perform pg_advisory_xact_lock(hashtext('convite:' || v_autor));
  perform pg_advisory_xact_lock(hashtext('convite:' || p_conta || ':' || v_email));
  -- retenção (LGPD): o registro do convite vale 90 dias
  delete from convites where em < now() - interval '90 days';
  if (select count(*) from convites where autor = v_autor and em > now() - interval '1 hour') >= 20 then
    raise exception 'Muitos convites na última hora. Tente mais tarde.';
  end if;
  if exists (select 1 from convites where conta_id = p_conta and email = v_email and em > now() - interval '10 minutes'
               and resultado in ('pendente', 'enviado')) then
    raise exception 'Convite já enviado há pouco para este e-mail. Aguarde alguns minutos.';
  end if;
  insert into convites (conta_id, email, autor) values (p_conta, v_email, v_autor) returning id into v_id;
  return v_id;
end $function$;

create or replace function interno.fn_convite_resultado(p_id bigint, p_resultado text)
 returns void language sql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  update interno.convites set resultado = p_resultado where id = p_id and resultado = 'pendente'
$function$;

-- convites da conta para a tela de usuários (último por e-mail)
create or replace function public.app_convites()
 returns table (email text, em timestamptz, resultado text)
 language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  return query select distinct on (c.email) c.email, c.em, c.resultado from interno.convites c
                where c.conta_id = v_conta order by c.email, c.em desc;
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
