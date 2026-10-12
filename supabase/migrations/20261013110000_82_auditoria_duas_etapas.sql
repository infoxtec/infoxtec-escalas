-- Migration 82 (13/10/2026): registro de quem ativou e desativou a verificação em duas etapas (backlog 097,
-- P3 do seguranca na migration 78). Decisão 68 deixou as duas etapas opcionais por gestor; o administrador
-- passa a ver, na tela Usuários, quem tem a verificação ativa e o histórico de ativação e desativação.
-- O registro nasce no banco, por gatilho em auth.mfa_factors: não depende do painel nem pode ser pulado
-- por quem chama a API do Supabase Auth direto. Só e-mail, ação e hora; nunca o segredo nem o código.

create table if not exists painel_mfa_log (
  id     bigint generated always as identity primary key,
  email  text not null,
  acao   text not null check (acao in ('ativou', 'desativou')),
  em     timestamptz not null default now()
);
comment on table painel_mfa_log is 'Quem ativou ou desativou a verificação em duas etapas e quando (decisão 68, backlog 097). Só inclusão.';
alter table painel_mfa_log enable row level security;
create or replace trigger trg_painel_mfa_log_imutavel before update or delete on painel_mfa_log
  for each row execute function fn_ponto_imutavel();

-- Fator confirmado = ativou; fator confirmado removido = desativou. Cadastro iniciado e abandonado
-- (unverified) não conta. Falha aqui nunca impede o login: só avisa no log do banco.
create or replace function fn_mfa_registrar()
returns trigger language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_email text;
  v_acao  text;
begin
  -- tudo dentro do bloco protegido: nem uma mudança de coluna no Auth pode barrar login ou cadastro
  begin
    if tg_op = 'UPDATE' and new.status::text = 'verified' and old.status::text is distinct from 'verified' then
      v_acao := 'ativou';
    elsif tg_op = 'DELETE' and old.status::text = 'verified' then
      v_acao := 'desativou';
    end if;
    if v_acao is not null then
      select lower(u.email) into v_email from auth.users u
       where u.id = case when tg_op = 'DELETE' then old.user_id else new.user_id end;
      insert into painel_mfa_log (email, acao) values (coalesce(v_email, '(usuário removido)'), v_acao);
    end if;
  exception when others then
    raise warning 'registro das duas etapas falhou: %', sqlerrm;
  end;
  return null;
end $function$;

drop trigger if exists trg_mfa_registrar on auth.mfa_factors;
-- sem lista de colunas: "update of status" prenderia a coluna do Auth e uma migration do Supabase que a
-- mudasse falharia (o login cairia junto). Se uma atualização do Auth falhar por causa dele:
-- drop trigger trg_mfa_registrar on auth.mfa_factors;  (docs/operacao.md)
create trigger trg_mfa_registrar after update or delete on auth.mfa_factors
  for each row execute function fn_mfa_registrar();

-- Tela Usuários: quem tem a verificação ativa (desde quando) e o histórico. Só administrador.
create or replace function app_usuarios_mfa()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin']);
  return jsonb_build_object(
    'ativos', coalesce((
      select jsonb_agg(a.x order by a.x->>'email')
        from (select jsonb_build_object('email', lower(u.email),
                       'desde', to_char(min(f.created_at) at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')) as x
                from auth.mfa_factors f join auth.users u on u.id = f.user_id
               where f.status::text = 'verified'
               group by lower(u.email)) a), '[]'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('email', l.email, 'acao', l.acao,
               'em', to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')) order by l.id desc)
        from (select * from painel_mfa_log order by id desc limit 100) l), '[]'::jsonb));
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
