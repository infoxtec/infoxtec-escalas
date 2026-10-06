-- Migration 53 (06/10/2026): Módulo Registro de Ponto, pacote 1 — cadastros-base (backlog 080,
-- decisão 48, docs/modulo-registro-de-ponto/plano.md F1).
--
-- 1. empresas: pessoa jurídica (empregador ou cliente), identificada pelo CNPJ.
-- 2. tecnicos: CPF, matrícula, admissão e empresa empregadora.
-- 3. locais: coordenadas e raio da área aceita para a marcação, e empresa cliente.
-- 4. Funções do painel: app_empresas, app_salvar_empresa; a lista de app_tecnicos nunca traz o CPF
--    inteiro (app_tecnico_cpf o entrega à ficha de edição); app_salvar_tecnico e app_salvar_local
--    passam a gravar os campos novos e só mexem num
--    campo quando ele vem no pedido (painel antigo não apaga o que não conhece). Corrige também a
--    data de desligamento, que a tela mandava e a função ignorava, e recusa link do Maps que não
--    seja http(s).

-- Dígitos verificadores ---------------------------------------------------------------------------

create or replace function fn_cpf_valido(p text)
returns boolean language plpgsql immutable set search_path = public, extensions as $$
declare
  s int; r int; i int;
begin
  if p is null or p !~ '^[0-9]{11}$' or p ~ '^(.)\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substr(p, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(p, 10, 1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(p, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(p, 11, 1)::int;
end $$;

create or replace function fn_cnpj_valido(p text)
returns boolean language plpgsql immutable set search_path = public, extensions as $$
declare
  pesos1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  pesos2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; r int; i int;
begin
  if p is null or p !~ '^[0-9]{14}$' or p ~ '^(.)\1{13}$' then return false; end if;
  s := 0;
  for i in 1..12 loop s := s + substr(p, i, 1)::int * pesos1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(p, 13, 1)::int then return false; end if;
  s := 0;
  for i in 1..13 loop s := s + substr(p, i, 1)::int * pesos2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(p, 14, 1)::int;
end $$;

-- 1. Empresas -------------------------------------------------------------------------------------

create table if not exists empresas (
  id            uuid primary key default gen_random_uuid(),
  cnpj          text not null unique check (fn_cnpj_valido(cnpj)),
  razao_social  text not null check (trim(razao_social) <> ''),
  nome_fantasia text,
  endereco      text,
  cidade        text not null default 'Salvador',
  uf            text not null default 'BA' check (uf ~ '^[A-Z]{2}$'),
  fuso          text not null default 'America/Bahia',
  empregadora   boolean not null default false,
  ativo         boolean not null default true,
  created_at    timestamptz not null default now()
);
comment on table empresas is 'Pessoa jurídica: empregadora (dona do ponto) ou cliente (dona do local). Módulo Registro de Ponto.';
comment on column empresas.empregadora is 'Empregadora: as marcações de ponto dos seus funcionários levam o CNPJ dela (AFD).';
alter table empresas enable row level security;

-- 2. Funcionário ----------------------------------------------------------------------------------

alter table tecnicos add column if not exists cpf        text check (cpf is null or fn_cpf_valido(cpf));
alter table tecnicos add column if not exists matricula  text;
alter table tecnicos add column if not exists admissao   date;
alter table tecnicos add column if not exists empresa_id uuid references empresas(id);
create unique index if not exists tecnicos_cpf_uk on tecnicos (cpf) where cpf is not null;
create unique index if not exists tecnicos_empresa_matricula_uk on tecnicos (empresa_id, matricula)
  where matricula is not null;
create index if not exists tecnicos_empresa_id_idx on tecnicos (empresa_id);
comment on column tecnicos.cpf is 'CPF, só dígitos. Dado pessoal: identifica o trabalhador no ponto (Portaria 671/2021). Fora da ficha de edição, só mascarado.';

-- 3. Local com área -------------------------------------------------------------------------------

alter table locais add column if not exists latitude  numeric(9,6) check (latitude between -90 and 90);
alter table locais add column if not exists longitude numeric(9,6) check (longitude between -180 and 180);
alter table locais add column if not exists raio_m    int not null default 200 check (raio_m between 20 and 5000);
alter table locais add column if not exists cliente_empresa_id uuid references empresas(id);
alter table locais drop constraint if exists locais_coordenadas_par;
alter table locais add constraint locais_coordenadas_par check ((latitude is null) = (longitude is null));
create index if not exists locais_cliente_empresa_id_idx on locais (cliente_empresa_id);
comment on column locais.raio_m is 'Raio, em metros, da área em que a marcação de ponto é considerada dentro do local.';

-- 4. Funções do painel ----------------------------------------------------------------------------

create or replace function app_empresas()
returns setof empresas language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from empresas order by razao_social;
end $$;

create or replace function app_salvar_empresa(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_cnpj  text := regexp_replace(coalesce(p->>'cnpj', ''), '\D', '', 'g');
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;

  if v_id is null then
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cidade, uf, empregadora, ativo)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      uf = upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
      empregadora = coalesce((p->>'empregadora')::boolean, false),
      ativo = coalesce((p->>'ativo')::boolean, true)
    where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma empresa com este CNPJ.';
end $$;

-- CPF nas listas (minimização, revisão do seguranca em 06/10): ninguém recebe o CPF inteiro na carga
-- do painel. Admin e gestor veem a máscara do padrão gov.br (***.456.789-**), que não expõe os
-- dígitos verificadores; leitura não recebe nada. O CPF inteiro só sai por app_tecnico_cpf, quando a
-- ficha de edição é aberta.
create or replace function app_tecnicos()
returns setof tecnicos language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
begin
  return query
    select (jsonb_populate_record(null::tecnicos, to_jsonb(t) || jsonb_build_object('cpf',
             case when v_leitura or t.cpf is null then null
                  else '***.' || substr(t.cpf, 4, 3) || '.' || substr(t.cpf, 7, 3) || '-**' end))).*
    from tecnicos t order by t.nome;
end $$;

create or replace function app_tecnico_cpf(p_tecnico uuid)
returns text language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  v_cpf text;
begin
  perform app_exigir(array['admin','gestor']);
  select cpf into v_cpf from tecnicos where id = p_tecnico;
  return v_cpf;
end $$;

-- CPF mascarado nunca volta para o banco: só grava quando vem completo, sem '*'.
create or replace function app_salvar_tecnico(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_tel text := regexp_replace(coalesce(p->>'telefone_e164', ''), '\D', '', 'g');
  v_opt boolean := coalesce((p->>'opt_in')::boolean, false);
  v_mascarado boolean := coalesce(p->>'cpf', '') ~ '\*';
  v_cpf text := case when not v_mascarado then nullif(regexp_replace(coalesce(p->>'cpf', ''), '\D', '', 'g'), '') end;
  v_optant boolean;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if coalesce(trim(p->>'funcao'), '') = '' then raise exception 'Função é obrigatória.'; end if;
  if v_tel !~ '^[1-9][0-9]{9,14}$' then
    raise exception 'Telefone inválido: use somente dígitos com código do país. Ex: 5571981776307';
  end if;
  if v_cpf is not null and not fn_cpf_valido(v_cpf) then raise exception 'CPF inválido.'; end if;

  if v_id is null then
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, opt_in_em, ativo,
                          perfil_teste, desligado_em, cpf, matricula, admissao, empresa_id)
    values (trim(p->>'nome'), v_tel, trim(p->>'funcao'), nullif(trim(p->>'equipe'), ''),
            coalesce((p->>'is_supervisor')::boolean, false), v_opt,
            case when v_opt then now() end, coalesce((p->>'ativo')::boolean, true),
            coalesce((p->>'perfil_teste')::boolean, false),
            nullif(p->>'desligado_em', '')::date, v_cpf, nullif(trim(p->>'matricula'), ''),
            nullif(p->>'admissao', '')::date, nullif(p->>'empresa_id', '')::uuid)
    returning id into v_id;
  else
    select opt_in into v_optant from tecnicos where id = v_id;
    if not found then raise exception 'Técnico não encontrado.'; end if;
    update tecnicos set
      nome = trim(p->>'nome'), telefone_e164 = v_tel, funcao = trim(p->>'funcao'),
      equipe = nullif(trim(p->>'equipe'), ''),
      is_supervisor = coalesce((p->>'is_supervisor')::boolean, false),
      opt_in = v_opt,
      opt_in_em = case when v_opt and not v_optant then now() else opt_in_em end,
      ativo = coalesce((p->>'ativo')::boolean, true),
      perfil_teste = coalesce((p->>'perfil_teste')::boolean, false),
      desligado_em = case when p ? 'desligado_em' then nullif(p->>'desligado_em', '')::date else desligado_em end,
      cpf        = case when p ? 'cpf' and not v_mascarado then v_cpf else cpf end,
      matricula  = case when p ? 'matricula'  then nullif(trim(p->>'matricula'), '') else matricula end,
      admissao   = case when p ? 'admissao'   then nullif(p->>'admissao', '')::date else admissao end,
      empresa_id = case when p ? 'empresa_id' then nullif(p->>'empresa_id', '')::uuid else empresa_id end
    where id = v_id;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe um técnico com este telefone, este CPF ou esta matrícula na empresa.';
end $$;

create or replace function app_salvar_local(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_lat   numeric := nullif(p->>'latitude', '')::numeric;
  v_lng   numeric := nullif(p->>'longitude', '')::numeric;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Informe latitude e longitude juntas.'; end if;
  if nullif(trim(p->>'link_maps'), '') !~* '^https?://' then
    raise exception 'Link do Google Maps inválido: precisa começar com https://';
  end if;

  if v_id is null then
    insert into locais (nome, cliente, endereco, cidade, referencia, link_maps, contato_local, telefone_contato, ativo,
                        latitude, longitude, raio_m, cliente_empresa_id)
    values (trim(p->>'nome'), nullif(trim(p->>'cliente'), ''), nullif(trim(p->>'endereco'), ''),
            coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'), nullif(trim(p->>'referencia'), ''),
            nullif(trim(p->>'link_maps'), ''), nullif(trim(p->>'contato_local'), ''),
            nullif(trim(p->>'telefone_contato'), ''), coalesce((p->>'ativo')::boolean, true),
            v_lat, v_lng, coalesce(nullif(p->>'raio_m', '')::int, 200), nullif(p->>'cliente_empresa_id', '')::uuid)
    returning id into v_id;
  else
    update locais set
      nome = trim(p->>'nome'), cliente = nullif(trim(p->>'cliente'), ''),
      endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      referencia = nullif(trim(p->>'referencia'), ''), link_maps = nullif(trim(p->>'link_maps'), ''),
      contato_local = nullif(trim(p->>'contato_local'), ''),
      telefone_contato = nullif(trim(p->>'telefone_contato'), ''),
      ativo = coalesce((p->>'ativo')::boolean, true),
      latitude  = case when p ? 'latitude'  then v_lat else latitude end,
      longitude = case when p ? 'longitude' then v_lng else longitude end,
      raio_m    = case when p ? 'raio_m' then coalesce(nullif(p->>'raio_m', '')::int, 200) else raio_m end,
      cliente_empresa_id = case when p ? 'cliente_empresa_id'
                                then nullif(p->>'cliente_empresa_id', '')::uuid else cliente_empresa_id end
    where id = v_id;
    if not found then raise exception 'Local não encontrado.'; end if;
  end if;
  return v_id;
end $$;

-- Permissões por laço (decisão 12) ----------------------------------------------------------------
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
