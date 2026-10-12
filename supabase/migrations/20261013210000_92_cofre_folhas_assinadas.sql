-- Migration 92 (13/10/2026): cofre das folhas de ponto assinadas, só para o RH (pedido do responsável, decisão 86).
-- A folha assinada já é imutável em ponto_espelhos (conteúdo congelado com SHA-256, assinatura com HMAC). O que
-- muda é quem a abre: a folha ASSINADA (com a imagem da assinatura, o IP e o aparelho) passa a ser aberta só por
-- quem tem a permissão "cofre de folhas assinadas" (painel_usuarios.rh_folhas), dada por nome pelo admin, e cada
-- abertura fica registrada. Para uma ação judicial, o RH baixa a cópia (PDF pela impressão) e a "prova": os bytes
-- exatos do documento, os hashes e os dados da assinatura, para um perito conferir. A folha ainda não assinada
-- continua com admin e gestor (conferir antes de enviar).

-- Permissão "cofre de folhas assinadas" -----------------------------------------------------------------
alter table painel_usuarios add column if not exists rh_folhas boolean not null default false;
comment on column painel_usuarios.rh_folhas is 'Abre o cofre das folhas de ponto assinadas (decisão 86). Dado por nome pelo admin; só admin ou gestor.';

create or replace function fn_rh_folhas(p_email text)
returns boolean language sql stable set search_path = public, extensions as $function$
  select coalesce((select rh_folhas from painel_usuarios where email = lower(trim(p_email)) and ativo
                    and papel in ('admin', 'gestor')), false)
$function$;

create or replace function app_meu_acesso()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
  select jsonb_build_object(
    'email', app_email(),
    'papel', (select papel from painel_usuarios where email = app_email() and ativo),
    'nome',  (select nome  from painel_usuarios where email = app_email()),
    've_saude', fn_ve_saude(app_email()),
    'rh_folhas', fn_rh_folhas(app_email()),
    'mfa_obrigatorio', coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true'
  )
$function$;

create table if not exists painel_rh_folhas_log (
  id     bigint generated always as identity primary key,
  email  text not null,
  valor  boolean not null,
  autor  text not null,
  em     timestamptz not null default now()
);
comment on table painel_rh_folhas_log is 'Quem deu ou tirou "cofre de folhas assinadas", para quem e quando (LGPD art. 37). Só inclusão.';
alter table painel_rh_folhas_log enable row level security;
create or replace trigger trg_painel_rh_folhas_log_imutavel before update or delete on painel_rh_folhas_log
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_painel_rh_folhas_log_sem_truncate before truncate on painel_rh_folhas_log
  for each statement execute function fn_ponto_imutavel();

create or replace function app_definir_rh_folhas(p_email text, p_valor boolean)
returns void language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin']);
  v_papel text;
begin
  select papel into v_papel from painel_usuarios where email = lower(trim(p_email));
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if p_valor and v_papel not in ('admin', 'gestor') then raise exception 'Só admin ou gestor pode abrir o cofre de folhas.'; end if;
  update painel_usuarios set rh_folhas = p_valor, updated_at = now() where email = lower(trim(p_email));
  insert into painel_rh_folhas_log (email, valor, autor) values (lower(trim(p_email)), p_valor, v_email);
end $function$;

create or replace function app_rh_folhas_historico()
returns table (email text, valor boolean, autor text, em text)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin']);
  return query select l.email, l.valor, l.autor, to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')
                 from painel_rh_folhas_log l order by l.id desc limit 100;
end $function$;

-- Registro de cada abertura de folha assinada -----------------------------------------------------------
create table if not exists ponto_espelho_acessos (
  id          bigint generated always as identity primary key,
  espelho_id  uuid not null references ponto_espelhos(id),
  email       text not null,
  acao        text not null check (acao in ('ver', 'prova')),
  em          timestamptz not null default now()
);
comment on table ponto_espelho_acessos is 'Quem abriu (ver) ou baixou a prova de uma folha de ponto assinada, e quando (decisão 86). Só inclusão.';
alter table ponto_espelho_acessos enable row level security;
create index if not exists ponto_espelho_acessos_espelho_idx on ponto_espelho_acessos (espelho_id);
create or replace trigger trg_ponto_espelho_acessos_imutavel before update or delete on ponto_espelho_acessos
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_espelho_acessos_sem_truncate before truncate on ponto_espelho_acessos
  for each statement execute function fn_ponto_imutavel();

-- Ver o espelho no painel: o não assinado com admin e gestor; o assinado só com o cofre de RH (e fica registrado)
-- (recriada da migration 89)
create or replace function app_ponto_espelho_ver(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v       jsonb;
  v_ass   timestamptz;
begin
  select e.assinado_em into v_ass from ponto_espelhos e where e.id = p_id;
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_ass is not null then
    if not fn_rh_folhas(v_email) then
      raise exception 'Folha assinada: fica no cofre de folhas assinadas, aberto só por quem tem essa permissão (RH).';
    end if;
    insert into ponto_espelho_acessos (espelho_id, email, acao) values (p_id, v_email, 'ver');
  end if;
  select jsonb_build_object('id', e.id, 'registro', e.registro, 'versao', e.versao, 'codigo', e.codigo, 'sha256', e.sha256,
           'emitido_em', e.emitido_em, 'substituido', e.substituido_em is not null, 'conteudo', e.conteudo,
           'assinado_em', e.assinado_em, 'assinatura_png', e.assinatura_png)
    into v from ponto_espelhos e where e.id = p_id;
  return v;
end $function$;

-- Cofre: folhas assinadas, por mês e funcionário (só RH) ---------------------------------------------------
create or replace function app_ponto_cofre_folhas(p_competencia date default null, p_tecnico uuid default null)
returns table (id uuid, tecnico_id uuid, tecnico text, empresa text, competencia text, registro bigint, versao int,
               codigo text, assinado_em timestamptz, acessos bigint)
language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) abre o cofre.'; end if;
  return query
    select e.id, e.tecnico_id, t.nome, coalesce(m.nome_fantasia, m.razao_social), to_char(e.competencia, 'MM/YYYY'),
           e.registro, e.versao, e.codigo, e.assinado_em,
           (select count(*) from ponto_espelho_acessos a where a.espelho_id = e.id)
      from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
     where e.assinado_em is not null
       and (p_competencia is null or e.competencia = date_trunc('month', p_competencia)::date)
       and (p_tecnico is null or e.tecnico_id = p_tecnico)
     order by e.competencia desc, t.nome;
end $function$;

-- Prova da folha assinada, para perícia ou ação judicial (só RH; fica registrado): os bytes exatos do conteúdo
-- (conteudo_texto, sobre o qual o SHA-256 foi calculado), os hashes recalculados agora e os dados da assinatura
create or replace function app_ponto_espelho_prova(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v       record;
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) baixa a prova.'; end if;
  select e.*, t.nome as tecnico_nome, m.razao_social, m.cnpj into v
    from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
   where e.id = p_id;
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v.assinado_em is null then raise exception 'Este espelho ainda não foi assinado.'; end if;
  insert into ponto_espelho_acessos (espelho_id, email, acao) values (p_id, v_email, 'prova');
  return jsonb_build_object(
    'documento', 'Espelho de ponto mensal assinado (Portaria MTP 671/2021, art. 84)',
    'empregador', jsonb_build_object('razao_social', v.razao_social, 'cnpj', v.cnpj),
    -- só o nome, para identificar o arquivo: o CPF já está no conteúdo (minimização, revisão do seguranca)
    'trabalhador', v.tecnico_nome,
    'competencia', to_char(v.competencia, 'MM/YYYY'), 'registro', v.registro, 'versao', v.versao,
    'codigo_verificacao', v.codigo, 'url_verificacao', rtrim(coalesce(nullif(fn_config('app_url'), ''), ''), '/') || '/v?c=' || v.codigo,
    'emitido_em', to_char(v.emitido_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'conteudo_texto', v.conteudo_texto,
    'sha256_conteudo', v.sha256,
    'sha256_conteudo_recalculado', encode(sha256(convert_to(v.conteudo_texto, 'UTF8')), 'hex'),
    'assinatura', jsonb_build_object(
      'assinado_em_utc', to_char(v.assinado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'imagem_png', v.assinatura_png,
      'origem', v.assinatura_origem,
      'hmac_sha256', v.assinatura_sha256,
      'chave_impressao', v.assinatura_chave,
      'hmac_confere', case when v.assinatura_chave is distinct from fn_ponto_assinatura_chave() then null
                           else fn_ponto_assinatura_hash(v.sha256, v.assinatura_png, v.assinado_em, v.assinatura_origem)
                                = v.assinatura_sha256 end,
      'como_conferir', 'sha256_conteudo = SHA-256 de conteudo_texto em UTF-8. hmac_sha256 = HMAC-SHA256, com a chave ESPELHO_ASSINATURA, de: sha256_conteudo|imagem_png|assinado_em_utc|ip|aparelho.'),
    'gerado_em', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'gerado_por', v_email);
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
