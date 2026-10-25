-- 116: multiempresa F1 (decisões 108 e 112, docs/multiempresa-f0.md). Nasce o cliente da plataforma — `contas` —, com
-- membros, módulos e os admins da plataforma, e toda tabela de cliente ganha `conta_id` não nulo apontando para a
-- conta 1 (Infoxtec). Nada muda para quem usa: o default é a conta 1 (na F2 passa a ser a conta da sessão), as
-- funções e o painel não mudam e as regras de unicidade antigas continuam (caem na F6). Coluna com default constante
-- não reescreve a tabela nem dispara gatilho: as tabelas imutáveis do ponto não são tocadas linha a linha.
-- Respostas do responsável em 26/10: conta 1 "Infoxtec"; admins da plataforma david.cerqueira@infoxtec.com.br e
-- sergio.dorea@infoxtec.com.br; cada usuário do painel entra na conta 1 com o papel que já tem.

-- 57 tabelas recebem coluna, chave e índice numa transação: sem esperar trava por muito tempo (cron e webhook rodando)
set lock_timeout = '5s';

create table interno.contas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(btrim(nome)) between 2 and 120),
  ativa boolean not null default true,
  criada_em timestamptz not null default now()
);
alter table interno.contas enable row level security;
insert into interno.contas (id, nome) values ('00000000-0000-0000-0000-000000000001', 'Infoxtec');

create table interno.conta_membros (
  conta_id uuid not null references interno.contas(id),
  email text not null check (email = lower(btrim(email)) and email like '%@%'),
  papel text not null check (papel in ('admin', 'gestor', 'leitura')),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  primary key (conta_id, email)
);
alter table interno.conta_membros enable row level security;
create index on interno.conta_membros (email);
insert into interno.conta_membros (conta_id, email, papel, ativo)
select '00000000-0000-0000-0000-000000000001', lower(btrim(email)), papel, ativo
  from interno.painel_usuarios
 where papel in ('admin', 'gestor', 'leitura');

-- até a F2 o painel grava só em painel_usuarios: o gatilho mantém a conta 1 igual (incluir, mudar papel, desativar, apagar)
create or replace function interno.fn_espelhar_conta_membro()
returns trigger
language plpgsql
security definer
set search_path = interno, public, extensions, pg_temp
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    delete from interno.conta_membros
     where conta_id = '00000000-0000-0000-0000-000000000001' and email = lower(btrim(old.email));
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    insert into interno.conta_membros (conta_id, email, papel, ativo)
    values ('00000000-0000-0000-0000-000000000001', lower(btrim(new.email)), new.papel, new.ativo);
  end if;
  return null;
end $$;

create trigger tg_espelhar_conta_membro after insert or update or delete on interno.painel_usuarios
  for each row execute function interno.fn_espelhar_conta_membro();

create table interno.plataforma_admins (
  email text primary key check (email = lower(btrim(email)) and email like '%_@_%'),
  criado_em timestamptz not null default now()
);
alter table interno.plataforma_admins enable row level security;
insert into interno.plataforma_admins (email) values
  ('david.cerqueira@infoxtec.com.br'), ('sergio.dorea@infoxtec.com.br');

create table interno.conta_modulos (
  conta_id uuid not null references interno.contas(id),
  modulo text not null check (modulo in ('escala', 'ponto')),
  ativo boolean not null default true,
  desde timestamptz not null default now(),
  primary key (conta_id, modulo)
);
alter table interno.conta_modulos enable row level security;
insert into interno.conta_modulos (conta_id, modulo) values
  ('00000000-0000-0000-0000-000000000001', 'escala'), ('00000000-0000-0000-0000-000000000001', 'ponto');

-- conta_id em toda tabela de cliente (as 6 da plataforma e as 4 novas ficam de fora; lista em docs/multiempresa-f0.md)
do $$
declare r record;
begin
  for r in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'interno' and c.relkind in ('r', 'p') and not c.relispartition
             and c.relname <> all (array['config', 'backlog_itens', 'motor_estado', 'saude_testes', 'ponto_geo',
                                         'webhook_token_trocas', 'contas', 'conta_membros', 'plataforma_admins', 'conta_modulos'])
             and not exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
           order by c.relname loop
    execute format('alter table interno.%I add column conta_id uuid not null default ''00000000-0000-0000-0000-000000000001''
                    references interno.contas(id)', r.relname);
    execute format('create index on interno.%I (conta_id)', r.relname);
  end loop;
end $$;


-- a marcação é montada por posição (row(...)::ponto_marcacoes): a coluna nova entra no fim, com a conta da empresa.
-- Recriada a partir da definição da homologação (md5 cc151666… conferido em 26/10); o hash (fn_ponto_hash) não muda
create or replace function interno.fn_ponto_registrar(p_tecnico uuid, p_tipo text, p_canal text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao integer DEFAULT NULL::integer, p_origem jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_tec          record;
  v_emp          record;
  v_nsr          bigint;
  v_ant          text;
  v_hash         text;
  v_agora        timestamptz := now();   -- para achar a escala; a hora da marcação é tomada depois da trava
  v_origem       jsonb;
  v_m            ponto_marcacoes;
  v_escala       uuid;
  v_escala_local uuid;
  v_local_id     uuid;
  v_local_nome   text;
  v_raio         int;
  v_dist         int;
  v_dentro       boolean;
  v_id           uuid;
  v_lat          numeric(9,6) := p_lat;
  v_lng          numeric(9,6) := p_lng;
begin
  if p_tipo not in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he') then
    raise exception 'Tipo de marcação inválido: %', p_tipo;
  end if;
  if p_canal not in ('app','whatsapp','ura') then raise exception 'Canal inválido: %', p_canal; end if;
  if p_canal <> 'ura' and (v_lat is null or v_lng is null) then
    raise exception 'A localização é obrigatória para bater o ponto pelo %.', p_canal;
  end if;

  select t.id, t.nome, t.cpf, t.ativo, t.empresa_id into v_tec from tecnicos t where t.id = p_tecnico;
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if not v_tec.ativo then raise exception 'Funcionário inativo: procure o seu gestor.'; end if;
  if v_tec.cpf is null or v_tec.empresa_id is null then
    raise exception 'Cadastro incompleto para o ponto (CPF e empresa): procure o seu gestor.';
  end if;
  select e.id, e.cnpj, e.razao_social, e.fuso, e.conta_id into v_emp from empresas e where e.id = v_tec.empresa_id;

  -- Escala de hoje mais próxima do horário (no fuso da empresa)
  select e.id, e.local_id into v_escala, v_escala_local from escalas e
   where e.tecnico_id = p_tecnico and e.data_servico = (v_agora at time zone v_emp.fuso)::date
     and e.status <> 'cancelada'
   order by abs(extract(epoch from (e.hora_inicio - (v_agora at time zone v_emp.fuso)::time)))
   limit 1;

  -- Local de referência: o da escala, se tiver área; senão, o local ativo com área mais perto
  if v_lat is not null then
    select l.id, l.nome, l.raio_m into v_local_id, v_local_nome, v_raio
      from locais l where l.id = v_escala_local and l.latitude is not null;
    if v_local_id is null then
      select l.id, l.nome, l.raio_m into v_local_id, v_local_nome, v_raio
        from locais l where l.latitude is not null and l.ativo
       order by fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude) limit 1;
    end if;
    if v_local_id is not null then
      select fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude) into v_dist from locais l where l.id = v_local_id;
      -- tolerância: a precisão informada pelo aparelho, até 100 m
      v_dentro := v_dist <= v_raio + least(coalesce(p_precisao, 0), 100);
    end if;
  end if;

  -- NSR: a linha da empresa fica travada até o fim da transação; rollback não deixa lacuna.
  insert into ponto_nsr (empresa_id) values (v_emp.id) on conflict (empresa_id) do nothing;
  select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = v_emp.id for update;
  -- hora tomada com a trava na mão: NSR maior nunca tem hora menor
  v_agora := clock_timestamp();
  -- origem: só identificadores técnicos do canal, nunca conteúdo
  select coalesce(jsonb_object_agg(k, left(v #>> '{}', 120)), '{}'::jsonb) into v_origem
    from jsonb_each(coalesce(p_origem, '{}'::jsonb)) e(k, v)
   where k in ('msg_id', 'call_sid', 'app_versao', 'login_origem', 'gestor') and jsonb_typeof(v) <> 'null';

  v_m := row(gen_random_uuid(), v_emp.id, v_nsr, p_tecnico, v_tec.cpf, v_agora, p_tipo, p_canal, v_lat, v_lng,
             p_precisao, v_local_id, v_dist, v_dentro, v_escala, v_origem, v_ant, null, v_emp.conta_id)::ponto_marcacoes;
  v_hash := fn_ponto_hash(v_m);
  v_m.hash := v_hash;
  insert into ponto_marcacoes select v_m.* returning id into v_id;
  update ponto_nsr set ultimo = v_nsr, ultimo_hash = v_hash where empresa_id = v_emp.id;

  -- Comprovante ao trabalhador (o dado é dele: CPF inteiro)
  return jsonb_build_object(
    'marcacao_id', v_id, 'nsr', v_nsr,
    'empresa', v_emp.razao_social, 'cnpj', v_emp.cnpj,
    'trabalhador', v_tec.nome, 'cpf', v_tec.cpf,
    'data', to_char(v_agora at time zone v_emp.fuso, 'DD/MM/YYYY'),
    'hora', to_char(v_agora at time zone v_emp.fuso, 'HH24:MI:SS'),
    'tipo', p_tipo, 'canal', p_canal,
    'local', v_local_nome, 'dentro_area', v_dentro, 'distancia_m', v_dist,
    'login_origem', v_origem ->> 'login_origem',
    'autenticacao', left(v_hash, 16));
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
