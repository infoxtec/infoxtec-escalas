-- 157: AFD com os registros de empresa (tipo 2) e de empregado (tipo 5) no mesmo NSR das marcações, e o AEJ
-- (decisão 139). Leiaute: Anexos V e VI da Portaria MTP 671/2021 na redação original (revogados pela 1.486/2022; o
-- vigente está no gov.br). Conferência contra o gov.br e pela contadora antes de valer: a flag afd_leiaute_conferido
-- segue false e os dois arquivos saem com _CONFERENCIA no nome. Assinatura CAdES fora do painel (Assinador do
-- ITI/Serpro sobre o arquivo baixado), por decisão de segurança: nenhum código do painel toca o certificado.
--
-- Desenho revisado por seguranca, arquiteto-dados e juridico (15/11):
-- * ponto_rep_registros: tipos 2 e 5, imutável, na MESMA cadeia (NSR e hash) das marcações, pela trava de ponto_nsr;
-- * nascem na primeira marcação da empresa (tipo 2 + um tipo 5 "I" por funcionário elegível), não aqui: a produção
--   recomeçou o NSR em 1 (decisão 138) e o uso oficial começa em 01/12/2026;
-- * depois, gatilhos em tecnicos e empresas (só nas colunas que importam) e a porta da marcação garantem que nenhuma
--   marcação sai sem o "I" do funcionário;
-- * ordem das travas, sempre: empresas (key share) -> ponto_nsr (for update).
set lock_timeout = '5s';

insert into interno.config (chave, valor, descricao) values
  ('rep_p_desenvolvedor_razao', '', 'Razão social do desenvolvedor do PTRP no AEJ (tipo 08). Vazio: a do empregador'),
  ('rep_p_desenvolvedor_email', '', 'E-mail do desenvolvedor do PTRP no AEJ (tipo 08)')
on conflict (chave) do nothing;

-- registros do REP (tipos 2 e 5) ----------------------------------------------------------------------------------------
create table if not exists interno.ponto_rep_registros (
  id            uuid primary key default gen_random_uuid(),
  conta_id      uuid not null default interno.fn_conta_padrao() references interno.contas(id),
  empresa_id    uuid not null,
  nsr           bigint not null check (nsr > 0),
  tipo          smallint not null check (tipo in (2, 5)),
  momento       timestamptz not null,
  operacao      text check (operacao in ('I', 'A', 'E')),
  tecnico_id    uuid,
  dados         jsonb not null check (jsonb_typeof(dados) = 'object' and pg_column_size(dados) <= 2048),
  hash_anterior text not null,
  hash          text not null unique,
  unique (empresa_id, nsr),
  check ((tipo = 5) = (tecnico_id is not null and operacao is not null)),
  check (tipo = 5 or (tecnico_id is null and operacao is null)),
  foreign key (conta_id, empresa_id) references interno.empresas(conta_id, id),
  foreign key (conta_id, tecnico_id) references interno.tecnicos(conta_id, id)
);
comment on table interno.ponto_rep_registros is
  'Registros do REP-P no AFD além das marcações: tipo 2 (empresa) e tipo 5 (empregado I/A/E), no mesmo NSR e na mesma cadeia de hash das marcações (decisão 139). Só inclusão; guarda de 5 anos junto com as marcações.';
create index if not exists ponto_rep_registros_tecnico on interno.ponto_rep_registros (empresa_id, tecnico_id, nsr desc) where tipo = 5;
alter table interno.ponto_rep_registros enable row level security;
revoke all on interno.ponto_rep_registros from public, anon, authenticated, service_role;
drop trigger if exists tg_00_conta on interno.ponto_rep_registros;
create trigger tg_00_conta before insert on interno.ponto_rep_registros
  for each row execute function interno.fn_herdar_conta('empresas', 'empresa_id');
drop trigger if exists trg_ponto_rep_registros_imutavel on interno.ponto_rep_registros;
create trigger trg_ponto_rep_registros_imutavel before update or delete on interno.ponto_rep_registros
  for each row execute function interno.fn_ponto_imutavel();
drop trigger if exists trg_ponto_rep_registros_sem_truncate on interno.ponto_rep_registros;
create trigger trg_ponto_rep_registros_sem_truncate before truncate on interno.ponto_rep_registros
  for each statement execute function interno.fn_ponto_imutavel();

-- CPF do responsável pelas inclusões e alterações (tipos 2 e 5): um por empresa, só o admin vê (LGPD art. 7º, II)
create table if not exists interno.ponto_rep_responsaveis (
  empresa_id    uuid primary key,
  conta_id      uuid not null default interno.fn_conta_padrao() references interno.contas(id),
  cpf           text not null check (interno.fn_cpf_valido(cpf)),
  atualizado_por text not null,
  atualizado_em timestamptz not null default now(),
  foreign key (conta_id, empresa_id) references interno.empresas(conta_id, id)
);
comment on table interno.ponto_rep_responsaveis is
  'CPF de quem responde pelas inclusões e alterações de empresa e empregado no AFD (Anexo V, tipos 2 e 5). Só o admin lê e grava.';
alter table interno.ponto_rep_responsaveis enable row level security;
revoke all on interno.ponto_rep_responsaveis from public, anon, authenticated, service_role;
drop trigger if exists tg_00_conta on interno.ponto_rep_responsaveis;
create trigger tg_00_conta before insert on interno.ponto_rep_responsaveis
  for each row execute function interno.fn_herdar_conta('empresas', 'empresa_id');

-- quem gerou o AEJ, de qual empresa e período (o arquivo não fica no servidor) -------------------------------------------
create table if not exists interno.ponto_aej_geracoes (
  id         bigint generated always as identity primary key,
  conta_id   uuid not null default interno.fn_conta_padrao() references interno.contas(id),
  email      text not null,
  empresa_id uuid not null,
  de         date not null,
  ate        date not null,
  contagens  jsonb not null,
  sha256     text not null,
  gerado_em  timestamptz not null default now(),
  foreign key (conta_id, empresa_id) references interno.empresas(conta_id, id)
);
comment on table interno.ponto_aej_geracoes is 'Quem gerou o AEJ de qual empresa e período, com as contagens e o sha256 (decisão 139). Só inclusão.';
alter table interno.ponto_aej_geracoes enable row level security;
revoke all on interno.ponto_aej_geracoes from public, anon, authenticated, service_role;
drop trigger if exists tg_00_conta on interno.ponto_aej_geracoes;
create trigger tg_00_conta before insert on interno.ponto_aej_geracoes
  for each row execute function interno.fn_herdar_conta('empresas', 'empresa_id');
drop trigger if exists trg_ponto_aej_geracoes_imutavel on interno.ponto_aej_geracoes;
create trigger trg_ponto_aej_geracoes_imutavel before update or delete on interno.ponto_aej_geracoes
  for each row execute function interno.fn_ponto_imutavel();
drop trigger if exists trg_ponto_aej_geracoes_sem_truncate on interno.ponto_aej_geracoes;
create trigger trg_ponto_aej_geracoes_sem_truncate before truncate on interno.ponto_aej_geracoes
  for each statement execute function interno.fn_ponto_imutavel();

-- filtro por empresa e período (AFD e AEJ) sem percorrer a cadeia inteira
create index if not exists ponto_marcacoes_empresa_momento on interno.ponto_marcacoes (empresa_id, momento);

-- hash do registro do REP: lista fixa de campos, prefixo próprio (nunca coincide com o texto de uma marcação).
-- Fórmula fixa: o backup (scripts/backup/conferir-ancora.sql) guarda uma cópia e o md5 dela. Nunca recriar.
create or replace function interno.fn_ponto_rep_hash(r interno.ponto_rep_registros)
returns text language sql immutable set search_path = interno, public, extensions, pg_temp as $$
  select encode(sha256(convert_to(array_to_string(array[
           'REP', r.hash_anterior, r.conta_id::text, r.empresa_id::text, r.nsr::text, r.tipo::text,
           to_char(r.momento at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
           coalesce(r.operacao, ''), coalesce(r.tecnico_id::text, ''),
           coalesce(r.dados ->> 'cnpj', ''), coalesce(r.dados ->> 'cno_caepf', ''), coalesce(r.dados ->> 'razao', ''),
           coalesce(r.dados ->> 'local', ''), coalesce(r.dados ->> 'cpf', ''), coalesce(r.dados ->> 'nome', ''),
           coalesce(r.dados ->> 'cpf_responsavel', '')], '|'), 'UTF8')), 'hex')
$$;

-- porta única do registro do REP: continua a cadeia de ponto_nsr, com hash conferido e hora de agora
create or replace function interno.fn_ponto_rep_conferir_insercao()
returns trigger language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare v_ultimo bigint; v_hash text;
begin
  select ultimo, ultimo_hash into v_ultimo, v_hash from ponto_nsr where empresa_id = new.empresa_id;
  if v_ultimo is null or new.nsr <> v_ultimo + 1 or new.hash_anterior <> v_hash
     or new.hash <> fn_ponto_rep_hash(new)
     or abs(extract(epoch from (clock_timestamp() - new.momento))) > 5
     or exists (select 1 from ponto_marcacoes m where m.empresa_id = new.empresa_id and m.nsr = new.nsr) then
    raise exception 'Registro do REP fora da porta única: recusado.';
  end if;
  return new;
end $function$;
drop trigger if exists trg_ponto_rep_registros_porta_unica on interno.ponto_rep_registros;
create trigger trg_ponto_rep_registros_porta_unica before insert on interno.ponto_rep_registros
  for each row execute function interno.fn_ponto_rep_conferir_insercao();

-- marcação: o NSR também não pode existir entre os registros do REP
CREATE OR REPLACE FUNCTION interno.fn_ponto_conferir_insercao()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ultimo bigint; v_hash text;
begin
  select ultimo, ultimo_hash into v_ultimo, v_hash from ponto_nsr where empresa_id = new.empresa_id;
  if v_ultimo is null or new.nsr <> v_ultimo + 1 or new.hash_anterior <> v_hash
     or new.hash <> fn_ponto_hash(new)
     or abs(extract(epoch from (clock_timestamp() - new.momento))) > 5
     or exists (select 1 from ponto_rep_registros r where r.empresa_id = new.empresa_id and r.nsr = new.nsr) then
    raise exception 'Marcação fora da porta única (fn_ponto_registrar): recusada.';
  end if;
  return new;
end $function$;

-- ponto_nsr avança só para um registro gravado (marcação ou registro do REP) com aquele NSR e hash
CREATE OR REPLACE FUNCTION interno.fn_ponto_nsr_avanca()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
begin
  if tg_op = 'DELETE' or new.empresa_id <> old.empresa_id or new.ultimo <> old.ultimo + 1
     or not (exists (select 1 from ponto_marcacoes m where m.empresa_id = new.empresa_id
                      and m.nsr = new.ultimo and m.hash = new.ultimo_hash)
             or exists (select 1 from ponto_rep_registros r where r.empresa_id = new.empresa_id
                         and r.nsr = new.ultimo and r.hash = new.ultimo_hash)) then
    raise exception 'Controle de NSR não pode ser alterado por fora do registro de ponto.';
  end if;
  return new;
end $function$;

-- trava da cadeia da empresa, sempre na mesma ordem: empresa (key share) e depois ponto_nsr (for update)
create or replace function interno.fn_ponto_nsr_travar(p_empresa uuid)
returns void language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
begin
  perform 1 from empresas where id = p_empresa for key share;
  if not found then raise exception 'Empresa não encontrada.'; end if;
  insert into ponto_nsr (empresa_id) values (p_empresa) on conflict (empresa_id) do nothing;
  perform 1 from ponto_nsr where empresa_id = p_empresa for update;
end $function$;

-- dados congelados da empresa (tipo 2) e o CPF do responsável
create or replace function interno.fn_ponto_rep_dados_empresa(p_empresa uuid)
returns jsonb language sql stable set search_path = interno, public, extensions, pg_temp as $function$
  select jsonb_build_object(
           'cnpj', upper(regexp_replace(e.cnpj, '[^0-9A-Za-z]', '', 'g')),
           'cno_caepf', coalesce(regexp_replace(e.cei_caepf_cno, '\D', '', 'g'), ''),
           'razao', left(e.razao_social, 150),
           'local', left(concat_ws(', ', nullif(e.endereco, ''), nullif(concat_ws('/', nullif(e.cidade, ''), nullif(e.uf, '')), ''),
                                   case when e.cep is not null then 'CEP ' || e.cep end), 100),
           'cpf_responsavel', coalesce((select r.cpf from ponto_rep_responsaveis r where r.empresa_id = e.id), ''))
    from empresas e where e.id = p_empresa
$function$;

-- grava um registro do REP (quem chama já tem a trava da empresa)
create or replace function interno.fn_ponto_rep_gravar(p_empresa uuid, p_tipo smallint, p_operacao text, p_tecnico uuid, p_dados jsonb)
returns void language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare
  v_r     ponto_rep_registros;
  v_conta uuid := (select conta_id from empresas where id = p_empresa);
  v_nsr   bigint;
  v_ant   text;
begin
  select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = p_empresa;
  if v_nsr is null then raise exception 'Cadeia do ponto sem trava.'; end if;
  -- só textos em dados (a fórmula do hash lê com ->>)
  select coalesce(jsonb_object_agg(k, coalesce(v #>> '{}', '')), '{}') into p_dados from jsonb_each(p_dados) x(k, v);
  v_r := row(gen_random_uuid(), v_conta, p_empresa, v_nsr, p_tipo, clock_timestamp(), p_operacao, p_tecnico, p_dados,
             v_ant, null)::ponto_rep_registros;
  v_r.hash := fn_ponto_rep_hash(v_r);
  insert into ponto_rep_registros select v_r.*;
  update ponto_nsr set ultimo = v_nsr, ultimo_hash = v_r.hash where empresa_id = p_empresa;
end $function$;

-- tipo 2 quando a identificação da empresa mudou desde o último (ou não há nenhum e p_iniciar)
create or replace function interno.fn_ponto_rep_empresa(p_empresa uuid, p_iniciar boolean)
returns boolean language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare v_novo jsonb := fn_ponto_rep_dados_empresa(p_empresa); v_ult jsonb;
begin
  select dados into v_ult from ponto_rep_registros where empresa_id = p_empresa and tipo = 2 order by nsr desc limit 1;
  if v_ult is null and not p_iniciar then return false; end if;
  if v_ult is not null and (v_ult - 'cpf_responsavel') = (v_novo - 'cpf_responsavel') then return false; end if;
  perform fn_ponto_rep_gravar(p_empresa, 2::smallint, null, null, v_novo);
  return true;
end $function$;

-- tipo 5 do funcionário na empresa, derivado do último registrado e do cadastro de agora (quem chama tem a trava):
-- elegível e não incluído -> I; incluído com CPF ou nome diferente -> A; incluído e não mais elegível -> E.
-- p_garantir (porta da marcação): inclui quem ainda não está incluído, mesmo fora da regra de elegibilidade.
create or replace function interno.fn_ponto_rep_sincronizar(p_empresa uuid, p_tecnico uuid, p_garantir boolean)
returns text language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare
  v_t    record;
  v_ult  record;
  v_eleg boolean;
  v_inc  boolean;
  v_resp text := coalesce((select r.cpf from ponto_rep_responsaveis r where r.empresa_id = p_empresa), '');
  v_op   text;
begin
  -- nada antes do primeiro tipo 2 (a carga inicial inclui todos)
  if not exists (select 1 from ponto_rep_registros where empresa_id = p_empresa and tipo = 2) then return null; end if;
  select t.cpf, t.nome, t.ativo, t.empresa_id, t.desligado_em, coalesce(e.fuso, 'America/Bahia') as fuso into v_t
    from tecnicos t left join empresas e on e.id = p_empresa where t.id = p_tecnico;
  select r.operacao, r.dados into v_ult from ponto_rep_registros r
   where r.empresa_id = p_empresa and r.tipo = 5 and r.tecnico_id = p_tecnico order by r.nsr desc limit 1;
  v_inc := v_ult.operacao is not null and v_ult.operacao <> 'E';
  v_eleg := v_t.empresa_id is not distinct from p_empresa and coalesce(v_t.ativo, false) and v_t.cpf is not null
            and (v_t.desligado_em is null or v_t.desligado_em >= (now() at time zone v_t.fuso)::date);
  if not v_inc and (v_eleg or (p_garantir and v_t.cpf is not null)) then
    v_op := 'I';
  elsif v_inc and v_eleg and (v_ult.dados ->> 'cpf' is distinct from v_t.cpf or v_ult.dados ->> 'nome' is distinct from left(v_t.nome, 150)) then
    v_op := 'A';
  elsif v_inc and not v_eleg and not p_garantir then
    v_op := 'E';
  end if;
  if v_op is null then return null; end if;
  perform fn_ponto_rep_gravar(p_empresa, 5::smallint, v_op, p_tecnico, jsonb_build_object(
    'cpf', case when v_op = 'E' then v_ult.dados ->> 'cpf' else v_t.cpf end,
    'nome', case when v_op = 'E' then v_ult.dados ->> 'nome' else left(v_t.nome, 150) end,
    'cpf_responsavel', v_resp));
  return v_op;
end $function$;

-- carga inicial (quem chama tem a trava): tipo 2 e um tipo 5 "I" por funcionário elegível, lidos depois da trava
create or replace function interno.fn_ponto_rep_iniciar(p_empresa uuid)
returns int language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare t record; v_n int := 0;
begin
  if not fn_ponto_rep_empresa(p_empresa, true) then return 0; end if;
  for t in select id from tecnicos where empresa_id = p_empresa and ativo and cpf is not null order by nome, id loop
    if fn_ponto_rep_sincronizar(p_empresa, t.id, false) is not null then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end $function$;

-- gatilhos do cadastro: só as colunas que entram no AFD, só quando mudam (o "when" barra o resto sem custo)
create or replace function interno.fn_ponto_rep_tg_tecnico()
returns trigger language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare e uuid;
begin
  perform set_config('lock_timeout', '3s', true);
  -- troca de empresa: as duas cadeias, em ordem de id (nunca um impasse entre duas trocas cruzadas). Só empresa que já
  -- tem cadeia (ponto_nsr): o gatilho não cria a cadeia de quem nunca bateu ponto (a demonstração continua apagável); a
  -- corrida com a primeira marcação fica coberta pela porta, que inclui o funcionário antes do NSR dele
  for e in select x from unnest(array[case when tg_op = 'UPDATE' then old.empresa_id end, new.empresa_id]) x
            where x is not null and exists (select 1 from ponto_nsr n where n.empresa_id = x)
            group by x order by x loop
    perform fn_ponto_nsr_travar(e);
    perform fn_ponto_rep_sincronizar(e, new.id, false);
  end loop;
  return null;
exception when lock_not_available then
  raise exception 'O ponto da empresa está em uso agora: tente salvar de novo em instantes.';
end $function$;

create or replace function interno.fn_ponto_rep_tg_empresa()
returns trigger language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
begin
  -- só empresa que já tem cadeia; com a trava (a carga inicial concorrente lê a empresa depois dela; fn_ponto_rep_empresa
  -- não faz nada antes do primeiro tipo 2)
  if not exists (select 1 from ponto_nsr where empresa_id = new.id) then return null; end if;
  perform set_config('lock_timeout', '3s', true);
  perform fn_ponto_nsr_travar(new.id);
  perform fn_ponto_rep_empresa(new.id, false);
  return null;
exception when lock_not_available then
  raise exception 'O ponto da empresa está em uso agora: tente salvar de novo em instantes.';
end $function$;

drop trigger if exists trg_ponto_rep_tecnico_ins on interno.tecnicos;
create trigger trg_ponto_rep_tecnico_ins after insert on interno.tecnicos
  for each row when (new.empresa_id is not null and new.cpf is not null)
  execute function interno.fn_ponto_rep_tg_tecnico();
drop trigger if exists trg_ponto_rep_tecnico_upd on interno.tecnicos;
create trigger trg_ponto_rep_tecnico_upd after update of nome, cpf, ativo, empresa_id, desligado_em on interno.tecnicos
  for each row when (old.nome is distinct from new.nome or old.cpf is distinct from new.cpf or old.ativo is distinct from new.ativo
                     or old.empresa_id is distinct from new.empresa_id or old.desligado_em is distinct from new.desligado_em)
  execute function interno.fn_ponto_rep_tg_tecnico();
drop trigger if exists trg_ponto_rep_empresa_upd on interno.empresas;
create trigger trg_ponto_rep_empresa_upd after update of cnpj, razao_social, endereco, cidade, uf, cep, cei_caepf_cno on interno.empresas
  for each row when (old.cnpj is distinct from new.cnpj or old.razao_social is distinct from new.razao_social
                     or old.endereco is distinct from new.endereco or old.cidade is distinct from new.cidade
                     or old.uf is distinct from new.uf or old.cep is distinct from new.cep
                     or old.cei_caepf_cno is distinct from new.cei_caepf_cno)
  execute function interno.fn_ponto_rep_tg_empresa();
-- Nota de travas: tecnicos_conta_cpf_uk é parcial, então trocar o CPF não pede trava forte na linha do técnico. Se a
-- unicidade deixar de ser parcial, rever a ordem (a marcação segura ponto_nsr e lê o técnico).

-- porta única da marcação (a partir da definição da homologação, migration 156): trava na ordem, carga inicial e o
-- "I" do próprio funcionário antes do NSR da marcação
CREATE OR REPLACE FUNCTION interno.fn_ponto_registrar(p_tecnico uuid, p_tipo text, p_canal text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric, p_precisao integer DEFAULT NULL::integer, p_origem jsonb DEFAULT '{}'::jsonb)
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
      from locais l where l.id = v_escala_local and l.latitude is not null and l.conta_id = v_emp.conta_id;
    if v_local_id is null then
      select l.id, l.nome, l.raio_m into v_local_id, v_local_nome, v_raio
        from locais l where l.latitude is not null and l.ativo and l.conta_id = v_emp.conta_id
       order by fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude) limit 1;
    end if;
    if v_local_id is not null then
      select fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude) into v_dist from locais l where l.id = v_local_id;
      -- tolerância: a precisão informada pelo aparelho, até 100 m
      v_dentro := v_dist <= v_raio + least(coalesce(p_precisao, 0), 100);
    end if;
  end if;

  -- NSR: empresa (key share) e a linha de ponto_nsr ficam travadas até o fim da transação; rollback não deixa lacuna.
  perform fn_ponto_nsr_travar(v_emp.id);
  -- registros do REP antes da marcação (decisão 139): carga inicial na primeira vez e o "I" deste funcionário
  perform fn_ponto_rep_iniciar(v_emp.id);
  perform fn_ponto_rep_sincronizar(v_emp.id, p_tecnico, true);
  select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = v_emp.id;
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

-- verificação da cadeia: marcações e registros do REP juntos, em ordem de NSR, cada um com a sua fórmula
CREATE OR REPLACE FUNCTION public.app_ponto_verificar(p_empresa uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  r record;
  v_ant text := repeat('0', 64);
  v_esperado bigint := 1;
  v_total int := 0;
  v_marc int := 0;
begin
  perform app_exigir(array['admin']);
  if not exists (select 1 from empresas where id = p_empresa and conta_id = fn_conta_atual()) then
    raise exception 'Empresa não encontrada.';
  end if;
  for r in select m.nsr, m.hash_anterior, m.hash, fn_ponto_hash(m) as calc, true as marcacao
             from ponto_marcacoes m where m.empresa_id = p_empresa
           union all
           select x.nsr, x.hash_anterior, x.hash, fn_ponto_rep_hash(x), false
             from ponto_rep_registros x where x.empresa_id = p_empresa
           order by 1 loop
    if r.nsr <> v_esperado then
      return jsonb_build_object('integra', false, 'nsr', v_esperado, 'motivo', 'lacuna no NSR', 'conferidas', v_total, 'marcacoes', v_marc);
    end if;
    if r.hash_anterior <> v_ant or r.hash <> r.calc then
      return jsonb_build_object('integra', false, 'nsr', r.nsr, 'motivo', 'hash não confere', 'conferidas', v_total, 'marcacoes', v_marc);
    end if;
    v_ant := r.hash; v_esperado := v_esperado + 1; v_total := v_total + 1;
    if r.marcacao then v_marc := v_marc + 1; end if;
  end loop;
  return jsonb_build_object('integra', true, 'conferidas', v_total, 'marcacoes', v_marc);
end $function$;

-- CPF do responsável pelo AFD da empresa (só admin) ------------------------------------------------------------------
create or replace function public.app_ponto_responsavel(p_empresa uuid)
returns jsonb language plpgsql stable security definer set search_path = interno, public, extensions, pg_temp as $function$
begin
  perform app_exigir(array['admin']);
  if not exists (select 1 from empresas where id = p_empresa and conta_id = fn_conta_atual()) then
    raise exception 'Empresa não encontrada.';
  end if;
  return (select jsonb_build_object('cpf', r.cpf, 'atualizado_por', r.atualizado_por, 'atualizado_em', r.atualizado_em)
            from ponto_rep_responsaveis r where r.empresa_id = p_empresa);
end $function$;

create or replace function public.app_ponto_definir_responsavel(p_empresa uuid, p_cpf text)
returns void language plpgsql security definer set search_path = interno, public, extensions, pg_temp as $function$
declare
  v_email text := app_exigir(array['admin']);
  v_cpf text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
begin
  if not exists (select 1 from empresas where id = p_empresa and conta_id = fn_conta_atual() and empregadora) then
    raise exception 'Empresa empregadora não encontrada.';
  end if;
  if not fn_cpf_valido(v_cpf) then raise exception 'CPF inválido.'; end if;
  insert into ponto_rep_responsaveis (empresa_id, conta_id, cpf, atualizado_por)
  values (p_empresa, fn_conta_atual(), v_cpf, v_email)
  on conflict (empresa_id) do update set cpf = excluded.cpf, atualizado_por = excluded.atualizado_por, atualizado_em = now();
end $function$;

-- AFD: tipos 1, 2, 5, 7 e 9 em ordem de NSR ------------------------------------------------------------------------------
-- p_de nulo = desde o primeiro registro (AFD completo, Art. 81 §2º). O hash do tipo 7 no arquivo encadeia os tipos 7
-- (só eles têm o campo, "hash do registro anterior"); a cadeia gravada no banco é outra e não vai no arquivo.
CREATE OR REPLACE FUNCTION interno.fn_afd_gerar(p_empresa uuid, p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_emp     record;
  v_fuso    text;
  v_hoje    date;
  v_de      date := p_de;
  v_inpi    text := fn_afd_n(fn_config('rep_p_inpi'), 17);
  v_dev     text;
  v_conf    boolean := coalesce(fn_config('afd_leiaute_conferido'), 'false') <> 'true';
  v_dh      text;
  v_linhas  text[] := '{}';
  v_campos  text;
  v_hash    text;
  v_ant     text := '';
  v_n       int[] := array[0, 0, 0, 0, 0, 0];   -- tipos 2 a 7
  v_sem_resp boolean := false;
  v_cab     text;
  v_fim     text;
  v_texto   text;
  v_sha     text;
  m         record;
begin
  select e.id, e.cnpj, e.razao_social, coalesce(e.fuso, 'America/Bahia') as fuso into v_emp
    from empresas e where e.id = p_empresa and e.empregadora;
  if not found then raise exception 'Empresa empregadora não encontrada.'; end if;
  v_fuso := v_emp.fuso;
  v_hoje := (now() at time zone v_fuso)::date;
  if v_de is null then
    select (min(x.momento) at time zone v_fuso)::date into v_de
      from (select momento from ponto_marcacoes where empresa_id = p_empresa
            union all select momento from ponto_rep_registros where empresa_id = p_empresa) x;
    v_de := coalesce(v_de, p_ate);
  end if;
  if v_de is null or p_ate is null or p_ate < v_de or p_ate > v_hoje then
    raise exception 'Período inválido: a data final não pode passar de hoje.';
  end if;
  v_dev := fn_afd_cnpj(coalesce(nullif(fn_config('rep_p_desenvolvedor_cnpj'), ''), v_emp.cnpj));

  -- Cabeçalho (tipo 1): 298 posições + CRC-16
  v_cab := '000000000' || '1' || '1' || fn_afd_cnpj(v_emp.cnpj) || repeat(' ', 14)
        || fn_afd_a(v_emp.razao_social, 150) || v_inpi
        || to_char(v_de, 'YYYY-MM-DD') || to_char(p_ate, 'YYYY-MM-DD') || fn_afd_dh(now(), v_fuso)
        || '003' || '1' || v_dev || repeat(' ', 30);
  v_linhas := v_linhas || (v_cab || fn_afd_crc16(convert_to(v_cab, 'LATIN1')));

  for m in select k.nsr, 7::smallint as tipo, k.momento, k.cpf, k.canal, null::text as operacao, null::jsonb as dados
             from ponto_marcacoes k where k.empresa_id = p_empresa
           union all
           select r.nsr, r.tipo, r.momento, null, null, r.operacao, r.dados
             from ponto_rep_registros r where r.empresa_id = p_empresa
           order by 1 loop
    v_dh := fn_afd_dh(m.momento, v_fuso);
    if m.tipo = 7 then
      v_campos := fn_afd_n(m.nsr::text, 9) || '7' || v_dh || fn_afd_n(m.cpf, 12)
               || v_dh                                                           -- gravação = marcação (on-line)
               || case m.canal when 'app' then '02' else '05' end               -- app web: navegador; WhatsApp e URA: outro
               || '0';                                                           -- on-line
      v_hash := encode(sha256(convert_to(v_campos || v_ant, 'LATIN1')), 'hex');
      v_ant := v_hash;
    end if;
    if (m.momento at time zone v_fuso)::date between v_de and p_ate then
      if m.tipo = 7 then
        v_linhas := v_linhas || (v_campos || v_hash);
      elsif m.tipo = 2 then
        -- 331 posições: NSR, tipo, DH, CPF do responsável (14), tipo de identificador, CNPJ, CNO/CAEPF, razão, local, CRC
        v_campos := fn_afd_n(m.nsr::text, 9) || '2' || v_dh || fn_afd_n(m.dados ->> 'cpf_responsavel', 14) || '1'
                 || fn_afd_cnpj(m.dados ->> 'cnpj') || fn_afd_n(m.dados ->> 'cno_caepf', 14)
                 || fn_afd_a(m.dados ->> 'razao', 150) || fn_afd_a(m.dados ->> 'local', 100);
        v_linhas := v_linhas || (v_campos || fn_afd_crc16(convert_to(v_campos, 'LATIN1')));
      else
        -- 118 posições: NSR, tipo, DH, operação, CPF (12), nome (52), demais dados (4), CPF do responsável (11), CRC
        v_campos := fn_afd_n(m.nsr::text, 9) || '5' || v_dh || m.operacao || fn_afd_n(m.dados ->> 'cpf', 12)
                 || fn_afd_a(m.dados ->> 'nome', 52) || repeat(' ', 4) || fn_afd_n(m.dados ->> 'cpf_responsavel', 11);
        v_linhas := v_linhas || (v_campos || fn_afd_crc16(convert_to(v_campos, 'LATIN1')));
      end if;
      v_n[m.tipo - 1] := v_n[m.tipo - 1] + 1;
      if m.tipo in (2, 5) and coalesce(m.dados ->> 'cpf_responsavel', '') = '' then v_sem_resp := true; end if;
    end if;
  end loop;

  -- Trailer (tipo 9): quantidades dos tipos 2, 3, 4, 5, 6 e 7
  v_fim := '999999999' || lpad(v_n[1]::text, 9, '0') || lpad(v_n[2]::text, 9, '0') || lpad(v_n[3]::text, 9, '0')
        || lpad(v_n[4]::text, 9, '0') || lpad(v_n[5]::text, 9, '0') || lpad(v_n[6]::text, 9, '0') || '9';
  v_linhas := v_linhas || v_fim;

  v_texto := array_to_string(v_linhas, E'\r\n') || E'\r\n';
  v_sha := encode(sha256(convert_to(v_texto, 'LATIN1')), 'hex');
  return jsonb_build_object(
    'nome', 'AFD' || v_inpi || fn_afd_cnpj(v_emp.cnpj) || 'REP_P' || case when v_conf then '_CONFERENCIA' else '' end || '.txt',
    'conteudo', v_texto, 'marcacoes', v_n[6], 'registros', v_n[1] + v_n[4] + v_n[6], 'sha256', v_sha,
    'de', v_de, 'conferencia', v_conf,
    'aviso', case when v_conf then 'Versão de conferência: leiaute do Anexo V da Portaria 671 (a conferir contra o do gov.br), '
             || 'sem assinatura CAdES' || case when v_inpi = repeat('0', 17) then ' e sem o número do INPI' else '' end
             || '. Não entregar à fiscalização antes da conferência da contadora. ' else '' end
             || case when v_sem_resp then 'Falta o CPF do responsável da empresa (registros de empresa e empregado com zeros). ' else '' end
             || 'O arquivo tem o CPF de todos os funcionários: guarde em local protegido e apague depois do uso.');
end $function$;

CREATE OR REPLACE FUNCTION public.app_ponto_afd(p_empresa uuid, p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin']);
  v_r     jsonb;
begin
  if not exists (select 1 from empresas e where e.id = p_empresa and e.empregadora and e.conta_id = fn_conta_atual()) then
    raise exception 'Empresa empregadora não encontrada.';
  end if;
  v_r := fn_afd_gerar(p_empresa, p_de, p_ate);
  insert into ponto_afd_geracoes (email, empresa_id, de, ate, registros, sha256)
  values (v_email, p_empresa, (v_r->>'de')::date, p_ate, (v_r->>'registros')::int, v_r->>'sha256');
  return v_r;
end $function$;

-- AEJ (Anexo VI): campos separados por "|", ISO 8859-1, CRLF --------------------------------------------------------------
create or replace function interno.fn_aej_a(p text, n int)
returns text language sql immutable set search_path = interno, public, extensions, pg_temp as $function$
  select left(btrim(regexp_replace(coalesce(p, ''), '[^ -{}~ -ÿ]', ' ', 'g')), n)
$function$;

create or replace function interno.fn_aej_gerar(p_empresa uuid, p_de date, p_ate date)
returns jsonb language plpgsql set search_path = interno, public, extensions, pg_temp as $function$
declare
  v_emp    record;
  v_fuso   text;
  v_hoje   date;
  v_ini    timestamptz;
  v_fim    timestamptz;
  v_inpi   text := fn_afd_n(fn_config('rep_p_inpi'), 17);
  v_conf   boolean := coalesce(fn_config('afd_leiaute_conferido'), 'false') <> 'true';
  v_dev    text;
  v_cei    text;
  v_l      text[] := '{}';
  v_n      int[] := array[0, 0, 0, 0, 0, 0, 0, 0];
  v_vinc   jsonb := '{}';    -- tecnico_id -> id no AEJ
  v_hor    jsonb := '{}';    -- código -> já emitido
  v_marc   text[] := '{}';
  v_aus    text[] := '{}';
  v_seq    int;
  v_dia    date;
  v_tec    uuid;
  v_cod    text;
  v_tp     text;
  v_sem_escala int := 0;
  v_aberto int := 0;
  v_texto  text;
  v_sha    text;
  t        record;
  m        record;
  h        record;
  d        record;
begin
  select e.id, e.cnpj, e.razao_social, e.cei_caepf_cno, coalesce(e.fuso, 'America/Bahia') as fuso into v_emp
    from empresas e where e.id = p_empresa and e.empregadora;
  if not found then raise exception 'Empresa empregadora não encontrada.'; end if;
  v_fuso := v_emp.fuso;
  v_hoje := (now() at time zone v_fuso)::date;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate > v_hoje then
    raise exception 'Período inválido: a data final não pode passar de hoje.';
  end if;
  if p_ate - p_de > 30 then raise exception 'O AEJ é gerado por até 31 dias.'; end if;
  v_ini := p_de::timestamp at time zone v_fuso;
  v_fim := (p_ate + 1)::timestamp at time zone v_fuso;
  v_dev := coalesce(nullif(regexp_replace(fn_config('rep_p_desenvolvedor_cnpj'), '[^0-9A-Za-z]', '', 'g'), ''),
                    upper(regexp_replace(v_emp.cnpj, '[^0-9A-Za-z]', '', 'g')));
  v_cei := regexp_replace(coalesce(v_emp.cei_caepf_cno, ''), '\D', '', 'g');

  -- 01 cabeçalho e 02 o REP-P
  v_l := v_l || array_to_string(array['01', '1', upper(regexp_replace(v_emp.cnpj, '[^0-9A-Za-z]', '', 'g')),
           case when length(v_cei) = 14 then v_cei else '' end, case when length(v_cei) = 12 then v_cei else '' end,
           fn_aej_a(v_emp.razao_social, 150), to_char(p_de, 'YYYY-MM-DD'), to_char(p_ate, 'YYYY-MM-DD'),
           fn_afd_dh(now(), v_fuso), '001'], '|');
  v_l := v_l || array_to_string(array['02', '1', '3', v_inpi], '|');
  v_n[1] := 1; v_n[2] := 1;

  -- 03 vínculos: quem tem marcação, ajuste ou fechamento no período (CPF do registro, nome do cadastro)
  for t in select x.id, x.nome, x.cpf from tecnicos x
            where x.cpf is not null and (
                  exists (select 1 from ponto_marcacoes k where k.empresa_id = p_empresa and k.tecnico_id = x.id
                           and k.momento >= v_ini and k.momento < v_fim)
               or exists (select 1 from ponto_ajustes a where a.empresa_id = p_empresa and a.tecnico_id = x.id
                           and a.acao = 'incluir' and a.momento >= v_ini and a.momento < v_fim)
               or exists (select 1 from ponto_folha_fechamentos f where f.empresa_id = p_empresa and f.tecnico_id = x.id
                           and f.competencia <= p_ate and (f.competencia + interval '1 month')::date > p_de))
            order by x.nome, x.id loop
    v_n[3] := v_n[3] + 1;
    v_vinc := v_vinc || jsonb_build_object(t.id::text, v_n[3]);
    v_l := v_l || array_to_string(array['03', v_n[3]::text, fn_afd_n(t.cpf, 11), fn_aej_a(t.nome, 150)], '|');
  end loop;

  -- 05 marcações: originais (desconsideradas saem "D" com o motivo, nunca somem) e incluídas pelo gestor ("I")
  v_tec := null; v_dia := null; v_seq := 0;
  for m in select x.* from (
             select k.tecnico_id, k.momento, k.tipo, 'O' as fonte, k.nsr,
                    (select coalesce(mo.nome, a.motivo) from ponto_ajustes a
                       left join ponto_justificativas j on j.id = a.justificativa_id
                       left join ponto_motivos mo on mo.codigo = j.motivo
                      where a.marcacao_id = k.id and a.acao = 'desconsiderar' order by a.created_at limit 1) as desc_motivo,
                    null::text as inc_motivo
               from ponto_marcacoes k where k.empresa_id = p_empresa and k.momento >= v_ini and k.momento < v_fim
             union all
             select a.tecnico_id, a.momento, a.tipo, 'I', null,
                    (select coalesce(mo.nome, d2.motivo) from ponto_ajustes d2
                       left join ponto_justificativas j on j.id = d2.justificativa_id
                       left join ponto_motivos mo on mo.codigo = j.motivo
                      where d2.ajuste_id = a.id and d2.acao = 'desconsiderar' order by d2.created_at limit 1),
                    coalesce((select mo.nome from ponto_justificativas j
                                join ponto_motivos mo on mo.codigo = j.motivo where j.id = a.justificativa_id), a.motivo)
               from ponto_ajustes a where a.empresa_id = p_empresa and a.acao = 'incluir'
                and a.momento >= v_ini and a.momento < v_fim) x
           where v_vinc ? x.tecnico_id::text
           order by x.tecnico_id, x.momento, x.nsr nulls last loop
    if v_tec is distinct from m.tecnico_id or v_dia is distinct from (m.momento at time zone v_fuso)::date then
      v_tec := m.tecnico_id; v_dia := (m.momento at time zone v_fuso)::date; v_seq := 0;
    end if;
    v_cod := '';
    if m.desc_motivo is not null then
      v_tp := 'D';
    else
      v_tp := case when m.tipo in ('entrada', 'volta_almoco', 'inicio_he') then 'E' else 'S' end;
      if v_tp = 'E' then v_seq := v_seq + 1; end if;
      if v_tp = 'E' and v_seq = 1 then
        -- 04 horário contratual do dia, da escala: um par entrada/saída (o intervalo não tem hora marcada na escala)
        select s.hora_inicio, coalesce(s.hora_fim_prevista, (s.hora_inicio + make_interval(mins => coalesce(s.duracao_prevista_min, 0)))::time) as fim,
               coalesce(s.intervalo_min, 0) as intervalo into h
          from escalas s where s.tecnico_id = m.tecnico_id and s.data_servico = v_dia
           and s.status not in ('cancelada', 'recusada', 'rascunho') order by s.hora_inicio limit 1;
        if h.hora_inicio is null then
          v_sem_escala := v_sem_escala + 1;
        else
          v_cod := 'H' || to_char(h.hora_inicio, 'HH24MI') || to_char(h.fim, 'HH24MI') || lpad(h.intervalo::text, 3, '0');
          if not v_hor ? v_cod then
            v_hor := v_hor || jsonb_build_object(v_cod, true);
            v_n[4] := v_n[4] + 1;
            v_l := v_l || array_to_string(array['04', v_cod, fn_carga_minutos_dia(m.tecnico_id, v_dia)::text,
                                                to_char(h.hora_inicio, 'HH24MI'), to_char(h.fim, 'HH24MI')], '|');
          end if;
        end if;
      end if;
    end if;
    v_n[5] := v_n[5] + 1;
    v_marc := v_marc || array_to_string(array['05', v_vinc ->> m.tecnico_id::text, fn_afd_dh(m.momento, v_fuso),
                case when m.fonte = 'O' then '1' else '' end, v_tp, lpad(greatest(v_seq, 1)::text, 3, '0'), m.fonte,
                v_cod, fn_aej_a(case when v_tp = 'D' then m.desc_motivo when m.fonte = 'I' then m.inc_motivo end, 150)], '|');
  end loop;
  v_l := v_l || v_marc;

  -- 07 ausências: só de mês fechado (falta é decisão humana, confirmada no fechamento — decisão 106)
  for d in select f.tecnico_id, dia, f.ocorrencias_confirmadas as oc
             from ponto_folha_fechamentos f join ponto_espelhos e on e.id = f.espelho_id
             cross join lateral jsonb_array_elements(e.conteudo -> 'dias') dia
            where f.empresa_id = p_empresa and v_vinc ? f.tecnico_id::text
              and (dia ->> 'data')::date between p_de and p_ate
            order by f.tecnico_id, (dia ->> 'data')::date loop
    v_tp := case
      when d.dia ->> 'repouso' = 'dsr' then '1'
      when d.dia ->> 'folga_de' is not null then case when extract(dow from (d.dia ->> 'folga_de')::date) = 0 then '1' else '4' end
      when exists (select 1 from jsonb_array_elements(d.oc) o where o ->> 'tipo' = 'sem_registro' and o ->> 'data' = d.dia ->> 'data') then '2'
    end;
    if v_tp is not null then
      v_n[7] := v_n[7] + 1;
      v_aus := v_aus || array_to_string(array['07', v_vinc ->> d.tecnico_id::text, v_tp, d.dia ->> 'data', '', ''], '|');
    end if;
  end loop;
  v_l := v_l || v_aus;
  -- meses do período sem fechamento de quem tem vínculo: o tipo 07 sai parcial
  select count(*) into v_aberto
    from jsonb_object_keys(v_vinc) k
    cross join generate_series(date_trunc('month', p_de), date_trunc('month', p_ate), interval '1 month') c
   where not exists (select 1 from ponto_folha_fechamentos f where f.empresa_id = p_empresa
                      and f.tecnico_id = k::uuid and f.competencia = c::date);

  -- 08 o programa de tratamento e 99 o trailer
  v_l := v_l || array_to_string(array['08', 'Trilha', '157', '1', v_dev,
           fn_aej_a(coalesce(nullif(fn_config('rep_p_desenvolvedor_razao'), ''), v_emp.razao_social), 150),
           fn_aej_a(fn_config('rep_p_desenvolvedor_email'), 50)], '|');
  v_n[8] := 1;
  v_l := v_l || array_to_string(array['99', v_n[1]::text, v_n[2]::text, v_n[3]::text, v_n[4]::text, v_n[5]::text,
                                      v_n[6]::text, v_n[7]::text, v_n[8]::text], '|');

  v_texto := array_to_string(v_l, E'\r\n') || E'\r\n';
  v_sha := encode(sha256(convert_to(v_texto, 'LATIN1')), 'hex');
  return jsonb_build_object(
    'nome', 'AEJ_' || upper(regexp_replace(v_emp.cnpj, '[^0-9A-Za-z]', '', 'g')) || '_' || to_char(p_de, 'YYYYMMDD') || '_'
            || to_char(p_ate, 'YYYYMMDD') || case when v_conf then '_CONFERENCIA' else '' end || '.txt',
    'conteudo', v_texto, 'sha256', v_sha, 'conferencia', v_conf,
    'contagens', jsonb_build_object('vinculos', v_n[3], 'horarios', v_n[4], 'marcacoes', v_n[5], 'ausencias', v_n[7]),
    'aviso', case when v_conf then 'Este arquivo está em conferência e ainda não vale como documento oficial (leiaute do Anexo VI '
             || 'da Portaria 671, a conferir contra o do gov.br' || case when v_inpi = repeat('0', 17) then '; sem o número do INPI' else '' end
             || '). ' else '' end
             || case when v_aberto > 0 then 'Parcial: ' || v_aberto || ' mês(es) de funcionário sem fechamento da folha ficam sem ausências. ' else '' end
             || case when v_sem_escala > 0 then v_sem_escala || ' dia(s) com marcação sem escala ficam sem horário contratual. ' else '' end
             || 'Tem CPF e motivos de ajuste: guarde em local protegido, entregue só a quem tem direito e apague depois do uso.');
end $function$;

create or replace function public.app_ponto_aej(p_empresa uuid, p_de date, p_ate date)
returns jsonb language plpgsql security definer set search_path = interno, public, extensions, pg_temp as $function$
declare
  v_email text := app_exigir(array['admin']);
  v_r     jsonb;
begin
  if not exists (select 1 from empresas e where e.id = p_empresa and e.empregadora and e.conta_id = fn_conta_atual()) then
    raise exception 'Empresa empregadora não encontrada.';
  end if;
  v_r := fn_aej_gerar(p_empresa, p_de, p_ate);
  insert into ponto_aej_geracoes (email, empresa_id, de, ate, contagens, sha256)
  values (v_email, p_empresa, p_de, p_ate, v_r->'contagens', v_r->>'sha256');
  return v_r;
end $function$;

-- exportação da conta (migration 147): as três tabelas novas entram na lista branca
CREATE OR REPLACE FUNCTION interno.fn_exportar_tabelas()
 RETURNS TABLE(tabela text, colunas text[], chave text[], folha text[])
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  -- lista branca (auditoria de 01/11): só entra a tabela listada aqui; tabela nova com conta_id fica fora até ser
  -- classificada nesta lista (o T85 recusa tabela de conta sem classificação). 'folha' são as colunas que só saem para
  -- quem tem rh_folhas (o espelho assinado); para os outros, vão vazias
  with lista(tabela) as (values
      ('alertas_enviados'),
      ('carga_aceites'),
      ('carga_atribuicoes'),
      ('cargas_horarias'),
      ('conta_canais'),
      ('conta_exportacao_baixas'),
      ('conta_exportacoes'),
      ('conta_membros'),
      ('conta_modulos'),
      ('convites'),
      ('documentos'),
      ('dossie_geracoes'),
      ('empresas'),
      ('escala_eventos'),
      ('escalas'),
      ('habilidades'),
      ('ligacoes'),
      ('locais'),
      ('log_exclusoes'),
      ('notificacoes'),
      ('ocorrencias'),
      ('painel_mfa_log'),
      ('painel_rh_folhas_log'),
      ('painel_ve_saude_log'),
      ('ponto_abonos'),
      ('ponto_acessos'),
      ('ponto_afd_geracoes'),
      ('ponto_aej_geracoes'),
      ('ponto_ajustes'),
      ('ponto_anexo_acessos'),
      ('ponto_anexos_descartados'),
      ('ponto_ciencias'),
      ('ponto_codigos'),
      ('ponto_conversas'),
      ('ponto_documento_registros'),
      ('ponto_documento_sequencia'),
      ('ponto_documento_verificacoes'),
      ('ponto_espelho_acessos'),
      ('ponto_espelho_pdfs'),
      ('ponto_espelho_sequencia'),
      ('ponto_espelhos'),
      ('ponto_folha_fechamentos'),
      ('ponto_he_autorizacoes'),
      ('ponto_justificativa_anexos'),
      ('ponto_justificativas'),
      ('ponto_marcacoes'),
      ('ponto_nsr'),
      ('ponto_rep_registros'),
      ('ponto_rep_responsaveis'),
      ('ponto_sessoes'),
      ('programacao_aceites'),
      ('respostas'),
      ('saude_downloads'),
      ('saude_termo_aceites'),
      ('tecnico_documentos'),
      ('tecnico_habilidades'),
      ('tecnicos'),
      ('times'),
      ('tipo_atividade_documentos'),
      ('tipo_atividade_requisitos'),
      ('tipos_atividade'),
      ('tipos_documento'),
      ('usuarios_excluidos'),
      ('webhook_eventos'))
  select c.relname::text,
         array(select a.attname::text from pg_attribute a
                where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                  and a.atttypid <> 'bytea'::regtype
                  and a.attname not in ('segredo', 'webhook_segredo', 'token_hash', 'codigo_hash', 'assinatura_chave',
                                        'envio_req', 'http_req_id', 'webhook_req', 'vig_req')
                  and not (c.relname = 'ponto_conversas' and a.attname = 'dados')   -- pedido em andamento (pode ser de saúde)
                  and not (c.relname = 'conta_canais' and a.attname in ('url', 'instancia'))   -- endereço do nosso servidor
                order by a.attnum),
         array(select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum)),
         case when c.relname = 'ponto_espelhos'
              then array['conteudo', 'conteudo_texto', 'assinatura_png', 'assinatura_origem', 'assinatura_sha256']
              else '{}'::text[] end
    from lista l join pg_class c on c.relname = l.tabela and c.relnamespace = 'interno'::regnamespace
   where c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$;

reset lock_timeout;

-- a 157 precisa chegar antes do uso oficial: com marcação já existente, o tipo 2 sairia depois delas
do $$
begin
  if coalesce(interno.fn_config('ambiente'), 'producao') = 'producao'
     and exists (select 1 from interno.ponto_marcacoes)
     and not exists (select 1 from interno.ponto_rep_registros) then
    raise notice '157: já há marcação na produção sem registro de empresa; o tipo 2 sai na próxima marcação, depois delas';
  end if;
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
