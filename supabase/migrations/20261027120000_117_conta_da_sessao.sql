-- 117: multiempresa F2a (decisões 108 e 113, docs/multiempresa-f2.md). A conta passa a vir da sessão: `fn_conta_atual`
-- acha a conta do usuário do painel em `conta_membros` (ativo, conta ativa); quem está em mais de uma conta escolhe pelo
-- cabeçalho `x-conta`, conferido contra os membros. `app_exigir` exige a conta e confere o papel naquela conta; para a
-- conta 1 o resultado é o mesmo de antes (conta_membros espelha painel_usuarios, migration 116). Nenhuma assinatura muda.
-- `fn_papel` continua global (Edge Functions sem sessão do usuário e 18 funções): cada família troca na sua etapa.
-- Funções recriadas a partir da definição da homologação de 26/10 (app_exigir e app_meu_acesso).

create or replace function interno.fn_conta_atual()
returns uuid
language plpgsql
stable
set search_path = interno, public, extensions, pg_temp
as $$
declare
  v_email  text := lower(nullif(auth.jwt() ->> 'email', ''));
  v_pedida text;
  v_conta  uuid;
  v_n      int;
begin
  if v_email is null then
    return null;
  end if;
  -- cabeçalho do PostgREST; ausente fora de uma chamada pela API (cron, Edge Function, teste)
  begin
    v_pedida := nullif(btrim(nullif(current_setting('request.headers', true), '')::json ->> 'x-conta'), '');
  exception when others then
    v_pedida := null;
  end;
  if v_pedida is not null then
    if v_pedida !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'Conta inválida.';
    end if;
    select m.conta_id into v_conta
      from interno.conta_membros m join interno.contas c on c.id = m.conta_id
     where m.email = v_email and m.ativo and c.ativa and m.conta_id = v_pedida::uuid;
    if v_conta is null then
      raise exception 'Sem acesso a esta conta.';
    end if;
    return v_conta;
  end if;
  select min(m.conta_id::text)::uuid, count(*) into v_conta, v_n
    from interno.conta_membros m join interno.contas c on c.id = m.conta_id
   where m.email = v_email and m.ativo and c.ativa;
  if v_n > 1 then
    raise exception 'Escolha a conta para continuar.';
  end if;
  return v_conta;
end $$;

-- Trava da F2 (revisão do seguranca): enquanto as famílias de funções não filtram pela conta, uma conta com membro
-- veria e mudaria dado da conta 1. Só a conta 1 aceita membros; a trava sai na etapa que fechar o T57 (F2f).
create or replace function interno.fn_trava_conta_unica()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $$
begin
  if new.conta_id <> '00000000-0000-0000-0000-000000000001' then
    raise exception 'Multiempresa em construção: só a conta 1 aceita membros até o fim da F2.';
  end if;
  return new;
end $$;

create trigger tg_trava_conta_unica before insert or update on interno.conta_membros
  for each row execute function interno.fn_trava_conta_unica();

create or replace function public.app_exigir(p_papeis text[])
 returns text
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_email();
  v_conta uuid;
begin
  if v_email is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  if coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true' and coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Confirme o código do aplicativo autenticador para continuar.';
  end if;
  v_conta := interno.fn_conta_atual();
  if v_conta is null then
    raise exception 'Sem permissão para esta ação.';
  end if;
  -- papel na conta da sessão (multiempresa F2a); falta de escopo nega
  if coalesce((select m.papel from interno.conta_membros m
                where m.conta_id = v_conta and m.email = v_email and m.ativo), '') <> all (p_papeis) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  return v_email;
end $function$;

create or replace function public.app_meu_acesso()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select jsonb_build_object(
    'email', app_email(),
    'papel', (select papel from painel_usuarios where email = app_email() and ativo),
    'nome',  (select nome  from painel_usuarios where email = app_email()),
    've_saude', fn_ve_saude(app_email()),
    'rh_folhas', fn_rh_folhas(app_email()),
    'mfa_obrigatorio', coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true',
    -- multiempresa: as contas do usuário (o painel passa a mostrar na F3); sem conta ativa, lista vazia
    'contas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'papel', m.papel) order by c.nome)
                          from interno.conta_membros m join interno.contas c on c.id = m.conta_id
                         where m.email = app_email() and m.ativo and c.ativa), '[]'::jsonb)
  )
$function$;

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
