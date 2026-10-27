-- Multiempresa F3d (F2f-2b, decisões 114 e 117): fim do default "conta 1" e da trava da 117.
-- conta_id passa a ter como default a conta da sessão (fn_conta_atual): no painel, a linha nova nasce na conta de quem
-- grava; sem sessão (cron, webhook, app do ponto), o default é nulo e o banco recusa, a não ser que a origem informe a
-- conta (gatilhos de herança da 119) ou que o caminho grave a conta de forma explícita (abaixo). Nada cai calado na
-- conta 1. As chaves compostas da 123 continuam recusando referência entre contas.

set lock_timeout = '5s';

-- 0. Default: a conta da sessão, sem lançar erro (quem está em duas contas sem escolher recebe nulo; em tabela filha
-- o gatilho de herança põe a conta da origem, nas outras o not null recusa)
create or replace function interno.fn_conta_padrao()
 returns uuid language plpgsql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  return interno.fn_conta_atual();
exception when raise_exception then
  return null;
end $function$;

-- herança (119) com a sessão: origem de outra conta é recusada (revisão do seguranca); sem sessão, vale a origem
create or replace function interno.fn_herdar_conta()
 returns trigger language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_pai    uuid := (to_jsonb(new) ->> tg_argv[1])::uuid;
  v_conta  uuid;
  v_sessao uuid;
begin
  if v_pai is not null then
    execute format('select conta_id from interno.%I where id = $1', tg_argv[0]) into v_conta using v_pai;
    -- origem informada e não achada: recusa (a linha não cai calada em conta nenhuma)
    if v_conta is null then
      raise exception 'Origem % não encontrada para herdar a conta.', tg_argv[0];
    end if;
    v_sessao := interno.fn_conta_padrao();
    if v_sessao is not null and v_sessao <> v_conta then
      raise exception 'Origem de outra conta.';
    end if;
    new.conta_id := v_conta;
  end if;
  return new;
end $function$;

-- 1. Catálogos da plataforma: feriados nacionais e motivos do ponto valem para todas as contas (feriado por local: F4)
alter table interno.feriados drop column conta_id;
alter table interno.ponto_motivos drop column conta_id;

-- 2. Caminhos sem sessão que dependiam do default
-- o canal do WhatsApp e a cota de tentativas do app do ponto são da operadora até a F5 (instância por conta)
create or replace function interno.fn_conta_operadora()
 returns trigger language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if new.conta_id is null then
    new.conta_id := '00000000-0000-0000-0000-000000000001';
  end if;
  return new;
end $function$;

-- webhook_eventos: evento do canal da operadora
create trigger tg_00_conta before insert on interno.webhook_eventos
  for each row execute function interno.fn_conta_operadora();
-- ponto_acessos: tentativa com funcionário herda a conta dele (tg_00_conta); sem funcionário (CPF desconhecido), operadora
create trigger tg_01_conta_operadora before insert on interno.ponto_acessos
  for each row when (new.tecnico_id is null) execute function interno.fn_conta_operadora();

-- alertas: o teto do app do ponto é da operadora (122); alerta sem funcionário nem empresa é recusado, não cai na conta 1
create or replace function interno.fn_alerta_conta()
 returns trigger language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_id    uuid;
  v_conta uuid;
begin
  -- só converte o que tem forma de UUID: detalhe malformado não derruba o alerta
  v_id := coalesce((regexp_match(coalesce(new.detalhe ->> 'tecnico', ''),
                                 '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'))[1]::uuid,
                   (regexp_match(new.tipo, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'))[1]::uuid);
  if v_id is not null then
    select conta_id into v_conta from interno.tecnicos where id = v_id;
    if v_conta is null then
      select conta_id into v_conta from interno.empresas where id = v_id;
    end if;
    if v_conta is not null then
      new.conta_id := v_conta;
    else
      raise warning 'alertas_enviados: % não é funcionário nem empresa; fica na conta informada', v_id;
    end if;
  end if;
  if new.conta_id is null and new.tipo like 'ponto\_teto\_%' then
    new.conta_id := '00000000-0000-0000-0000-000000000001';
  end if;
  return new;
end $function$;

-- duas etapas: o registro vai para cada conta de que o usuário é membro (a tela de MFA lista por conta)
create or replace function interno.fn_mfa_registrar()
 returns trigger language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
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
      insert into painel_mfa_log (conta_id, email, acao)
      select distinct m.conta_id, coalesce(v_email, '(usuário removido)'), v_acao
        from conta_membros m where m.email = v_email;
      -- quem não é membro de conta nenhuma: registro na operadora, para o evento não se perder
      if not found then
        insert into painel_mfa_log (conta_id, email, acao)
        values ('00000000-0000-0000-0000-000000000001', coalesce(v_email, '(usuário removido)'), v_acao);
      end if;
    end if;
  exception when others then
    raise warning 'registro das duas etapas falhou: %', sqlerrm;
  end;
  return null;
end $function$;

-- 3. Fim da trava: conta de cliente aceita membro
drop trigger tg_trava_conta_unica on interno.conta_membros;
drop function interno.fn_trava_conta_unica();

-- 4. Default "conta 1" vira a conta da sessão
do $$
declare r record;
begin
  for r in select c.relname from pg_attribute a join pg_class c on c.oid = a.attrelid
             join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'interno' and a.attname = 'conta_id' and c.relkind in ('r', 'p') and not a.attisdropped
              and c.relname not in ('contas', 'conta_membros', 'conta_modulos') loop
    execute format('alter table interno.%I alter column conta_id set default interno.fn_conta_padrao()', r.relname);
  end loop;
end $$;

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
