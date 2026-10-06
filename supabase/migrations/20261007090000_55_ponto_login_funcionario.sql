-- Migration 55 (07/10/2026): Módulo Registro de Ponto, pacote 3 — login do funcionário e o app
-- (backlog 082, decisão 48 e 49, docs/modulo-registro-de-ponto/plano.md F2).
--
-- O funcionário não é usuário do painel: entra com CPF + código de 6 dígitos recebido no WhatsApp
-- (opção A do responsável, 06/10). Contingência: o gestor gera o código no painel.
-- Sessão única: um login novo encerra a anterior. O token só existe no aparelho; o banco guarda o
-- hash (SHA-256).
--
-- API do funcionário: funções ponto_* (decisão 49). Chamadas sem login do Supabase (papel anon),
-- validam o token na primeira linha (fn_ponto_sessao) e só enxergam o próprio funcionário.
-- O bloco de permissões passa a dar execute de ponto_* para anon e authenticated.

-- Tabelas -----------------------------------------------------------------------------------------

create table if not exists ponto_codigos (
  id           uuid primary key default gen_random_uuid(),
  tecnico_id   uuid not null references tecnicos(id) on delete cascade,
  codigo_hash  text not null,
  origem       text not null check (origem in ('whatsapp', 'gestor')),
  criado_por   text,
  expira_em    timestamptz not null,
  tentativas   int not null default 0,
  usado_em     timestamptz,
  created_at   timestamptz not null default now()
);
comment on table ponto_codigos is 'Códigos de acesso do app do ponto (6 dígitos, guardados só como hash). Origem gestor = contingência gerada no painel.';
create index if not exists ponto_codigos_tecnico_idx on ponto_codigos (tecnico_id, created_at desc);
alter table ponto_codigos enable row level security;

create table if not exists ponto_sessoes (
  id            uuid primary key default gen_random_uuid(),
  tecnico_id    uuid not null references tecnicos(id) on delete cascade,
  token_hash    text not null unique,
  criada_em     timestamptz not null default now(),
  expira_em     timestamptz not null,
  ultimo_uso    timestamptz,
  encerrada_em  timestamptz,
  motivo        text
);
comment on table ponto_sessoes is 'Sessões do app do ponto. Uma ativa por funcionário: novo login encerra a anterior.';
create index if not exists ponto_sessoes_tecnico_idx on ponto_sessoes (tecnico_id);
alter table ponto_sessoes enable row level security;

create table if not exists ponto_ciencias (
  tecnico_id  uuid not null references tecnicos(id) on delete cascade,
  versao      text not null,
  aceito_em   timestamptz not null default now(),
  primary key (tecnico_id, versao)
);
comment on table ponto_ciencias is 'Registro de que o funcionário viu o aviso de privacidade do ponto (LGPD), por versão do aviso.';
alter table ponto_ciencias enable row level security;

revoke all on ponto_codigos, ponto_sessoes, ponto_ciencias from anon, authenticated, service_role;

-- Apoio -------------------------------------------------------------------------------------------

create or replace function fn_sha256(p text)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(sha256(convert_to(p, 'UTF8')), 'hex')
$$;

-- Código de 6 dígitos com gerador criptográfico
create or replace function fn_ponto_novo_codigo()
returns text language sql volatile set search_path = public, extensions as $$
  select lpad((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint % 1000000)::text, 6, '0')
$$;

-- Primeira linha de toda função ponto_*: devolve o funcionário da sessão ou recusa.
create or replace function fn_ponto_sessao(p_token text)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_id uuid; v_tec uuid;
begin
  select s.id, s.tecnico_id into v_id, v_tec from ponto_sessoes s join tecnicos t on t.id = s.tecnico_id
   where s.token_hash = fn_sha256(coalesce(p_token, '')) and s.encerrada_em is null
     and s.expira_em > now() and t.ativo;
  if v_id is null then raise exception 'Sessão encerrada. Entre novamente.'; end if;
  update ponto_sessoes set ultimo_uso = now() where id = v_id;
  return v_tec;
end $$;

-- Pedir código --------------------------------------------------------------------------------------

-- Resposta sempre igual, exista ou não o CPF: não revela quem é funcionário.
create or replace function ponto_pedir_codigo(p_cpf text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_tec  record;
  v_cod  text;
  v_id   uuid := gen_random_uuid();
  v_resp jsonb := jsonb_build_object('mensagem',
    'Se o CPF estiver cadastrado, você recebe o código no WhatsApp em instantes. Ele vale por 5 minutos.');
begin
  if not fn_cpf_valido(v_cpf) then return v_resp; end if;
  select id, telefone_e164, opt_in into v_tec from tecnicos where cpf = v_cpf and ativo;
  if v_tec.id is null or not v_tec.opt_in then return v_resp; end if;
  -- no máximo 3 códigos por WhatsApp a cada 15 minutos
  if (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
        and created_at > now() - interval '15 minutes') >= 3 then
    return v_resp;
  end if;

  update ponto_codigos set expira_em = now() where tecnico_id = v_tec.id and usado_em is null and expira_em > now();
  v_cod := fn_ponto_novo_codigo();
  insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, expira_em)
  values (v_id, v_tec.id, fn_sha256(v_id::text || ':' || v_cod), 'whatsapp', now() + interval '5 minutes');

  begin
    perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
      jsonb_build_object('number', v_tec.telefone_e164,
        'text', 'Trilha Ponto: seu código de acesso é ' || v_cod || '. Vale por 5 minutos. Não compartilhe com ninguém.'));
  exception when others then
    -- sem Evolution (homologação) ou fora do ar: o gestor gera o código de contingência no painel
    raise warning 'ponto_pedir_codigo: envio do código falhou (%)', sqlerrm;
  end;
  return v_resp;
end $$;

-- Entrar ------------------------------------------------------------------------------------------

-- Erros voltam como {erro}, sem exceção, para a contagem de tentativas não ser desfeita.
create or replace function ponto_entrar(p_cpf text, p_codigo text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cpf    text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_codigo text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_tec    record;
  v_c      record;
  v_token  text;
  v_erro   jsonb := jsonb_build_object('erro', 'CPF ou código inválido.');
begin
  if not fn_cpf_valido(v_cpf) or v_codigo !~ '^[0-9]{6}$' then return v_erro; end if;
  select t.id, t.nome, e.razao_social, e.nome_fantasia into v_tec
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.cpf = v_cpf and t.ativo;
  if v_tec.id is null then return v_erro; end if;

  -- bloqueio: 10 tentativas erradas na última hora
  if (select coalesce(sum(tentativas), 0) from ponto_codigos
       where tecnico_id = v_tec.id and created_at > now() - interval '1 hour') >= 10 then
    return jsonb_build_object('erro', 'Muitas tentativas. Aguarde 1 hora ou peça um código ao seu gestor.');
  end if;

  select * into v_c from ponto_codigos
   where tecnico_id = v_tec.id and usado_em is null and expira_em > now()
   order by created_at desc limit 1 for update;
  if v_c.id is null then return jsonb_build_object('erro', 'Código vencido. Peça um novo.'); end if;

  if v_c.codigo_hash <> fn_sha256(v_c.id::text || ':' || v_codigo) then
    update ponto_codigos set tentativas = tentativas + 1,
           expira_em = case when tentativas + 1 >= 5 then now() else expira_em end
     where id = v_c.id;
    return v_erro;
  end if;

  update ponto_codigos set usado_em = now() where id = v_c.id;
  update ponto_sessoes set encerrada_em = now(), motivo = 'novo login'
   where tecnico_id = v_tec.id and encerrada_em is null;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into ponto_sessoes (tecnico_id, token_hash, expira_em)
  values (v_tec.id, fn_sha256(v_token), now() + interval '12 hours');

  return jsonb_build_object('token', v_token, 'nome', v_tec.nome,
    'empresa', coalesce(v_tec.nome_fantasia, v_tec.razao_social), 'expira_em', now() + interval '12 hours');
end $$;

create or replace function ponto_sair(p_token text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  update ponto_sessoes set encerrada_em = now(), motivo = 'saiu'
   where token_hash = fn_sha256(coalesce(p_token, '')) and encerrada_em is null;
end $$;

-- O funcionário logado --------------------------------------------------------------------------------

create or replace function ponto_eu(p_token text, p_versao_aviso text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v_r   jsonb;
begin
  select jsonb_build_object('nome', t.nome, 'empresa', coalesce(e.nome_fantasia, e.razao_social),
           'ciente', exists (select 1 from ponto_ciencias c where c.tecnico_id = t.id and c.versao = p_versao_aviso),
           'hoje', coalesce((select jsonb_agg(jsonb_build_object('nsr', m.nsr, 'tipo', m.tipo,
                     'hora', to_char(m.momento at time zone e.fuso, 'HH24:MI'), 'dentro_area', m.dentro_area)
                     order by m.momento)
                   from ponto_marcacoes m
                  where m.tecnico_id = t.id and (m.momento at time zone e.fuso)::date = (now() at time zone e.fuso)::date),
                  '[]'::jsonb))
    into v_r
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = v_tec;
  return v_r;
end $$;

create or replace function ponto_registrar_ciencia(p_token text, p_versao_aviso text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  if coalesce(trim(p_versao_aviso), '') = '' then raise exception 'Versão do aviso ausente.'; end if;
  insert into ponto_ciencias (tecnico_id, versao) values (v_tec, trim(p_versao_aviso)) on conflict do nothing;
end $$;

-- Bater o ponto pelo app: o funcionário vem da sessão, nunca de parâmetro (revisão do seguranca).
create or replace function ponto_bater(p_token text, p_tipo text, p_lat numeric, p_lng numeric,
  p_precisao int default null, p_app_versao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return fn_ponto_registrar(v_tec, p_tipo, 'app', p_lat, p_lng, p_precisao,
                            jsonb_build_object('app_versao', p_app_versao));
end $$;

create or replace function ponto_minhas_marcacoes(p_token text, p_dias int default 7)
returns table (nsr bigint, data text, hora text, tipo text, canal text, local text, dentro_area boolean, autenticacao text)
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return query
    select m.nsr, to_char(m.momento at time zone e.fuso, 'DD/MM/YYYY'), to_char(m.momento at time zone e.fuso, 'HH24:MI:SS'),
           m.tipo, m.canal, l.nome, m.dentro_area, left(m.hash, 16)
      from ponto_marcacoes m join empresas e on e.id = m.empresa_id left join locais l on l.id = m.local_id
     where m.tecnico_id = v_tec and m.momento > now() - make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 62))
     order by m.momento desc;
end $$;

-- Contingência no painel ----------------------------------------------------------------------------

create or replace function app_ponto_gerar_codigo(p_tecnico uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_cod   text := fn_ponto_novo_codigo();
  v_id    uuid := gen_random_uuid();
begin
  select id, nome, cpf, ativo into v_tec from tecnicos where id = p_tecnico;
  if v_tec.id is null then raise exception 'Técnico não encontrado.'; end if;
  if not v_tec.ativo or v_tec.cpf is null then raise exception 'O técnico precisa estar ativo e com CPF cadastrado.'; end if;
  update ponto_codigos set expira_em = now() where tecnico_id = p_tecnico and usado_em is null and expira_em > now();
  insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, criado_por, expira_em)
  values (v_id, p_tecnico, fn_sha256(v_id::text || ':' || v_cod), 'gestor', v_email, now() + interval '15 minutes');
  return jsonb_build_object('codigo', v_cod, 'nome', v_tec.nome, 'expira_em', now() + interval '15 minutes');
end $$;

-- Permissões por laço (decisão 12, ampliada pela decisão 49) ----------------------------------------
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
