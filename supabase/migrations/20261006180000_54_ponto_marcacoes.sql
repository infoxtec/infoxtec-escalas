-- Migration 54 (06/10/2026): Módulo Registro de Ponto, pacote 2 — o núcleo legal da marcação
-- (backlog 081, decisão 48, docs/modulo-registro-de-ponto/plano.md F1).
--
-- 1. ponto_marcacoes: SÓ INCLUSÃO. O banco recusa update, delete e truncate. NSR sequencial por
--    empresa, sem lacuna; hora do servidor; localização e distância ao local; hash encadeado (cada
--    marcação carrega o hash da anterior da mesma empresa), para provar que nada foi alterado.
-- 2. ponto_ajustes: correção separada, justificada e com autor. Também só inclusão.
-- 3. fn_ponto_registrar: a porta única que app, WhatsApp e URA vão chamar. Devolve o comprovante.
-- 4. Técnico com marcação não pode ser excluído (guarda legal de 5 anos): só desativado.
-- 5. Painel: app_ponto_marcacoes (consulta) e app_ponto_verificar (confere a cadeia de hash).
--
-- Guarda: nenhuma rotina de limpeza (fn_limpeza_logs) toca nestas tabelas, e o gatilho de
-- imutabilidade impede que alguma passe a tocar sem uma migration explícita. Descarte depois do prazo
-- legal (5 anos) só por migration própria, que desliga o gatilho de forma registrada.
-- Revisão do seguranca (06/10): service_role sem acesso direto, gatilho de porta única na inserção,
-- ponto_nsr só avança, origem restrita, hash cobrindo todos os campos.

-- Distância entre dois pontos (haversine), em metros ---------------------------------------------
create or replace function fn_distancia_m(lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric)
returns int language sql immutable set search_path = public, extensions as $$
  select round(2 * 6371000 * asin(sqrt(least(1,
           power(sin(radians((lat2 - lat1)::float8) / 2), 2) +
           cos(radians(lat1::float8)) * cos(radians(lat2::float8)) *
           power(sin(radians((lng2 - lng1)::float8) / 2), 2)))))::int
$$;

-- 1. Marcações ------------------------------------------------------------------------------------

create table if not exists ponto_marcacoes (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references empresas(id),
  nsr           bigint not null check (nsr > 0),
  tecnico_id    uuid not null references tecnicos(id),
  cpf           text not null check (fn_cpf_valido(cpf)),
  momento       timestamptz not null default now(),
  tipo          text not null check (tipo in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he')),
  canal         text not null check (canal in ('app','whatsapp','ura')),
  latitude      numeric(9,6) check (latitude between -90 and 90),
  longitude     numeric(9,6) check (longitude between -180 and 180),
  precisao_m    int check (precisao_m >= 0),
  local_id      uuid references locais(id),
  distancia_m   int,
  dentro_area   boolean,
  escala_id     uuid,          -- sem chave estrangeira: escala removida não pode mexer na marcação
  origem        jsonb not null default '{}'::jsonb check (pg_column_size(origem) <= 2048),
  hash_anterior text not null,
  hash          text not null unique,
  unique (empresa_id, nsr),
  check ((latitude is null) = (longitude is null)),
  check (canal = 'ura' or latitude is not null)
);
comment on table ponto_marcacoes is 'Registro de ponto (Portaria MTP 671/2021). Só inclusão: update, delete e truncate são recusados. Guarda mínima de 5 anos.';
comment on column ponto_marcacoes.momento is 'Hora do servidor no recebimento, nunca a do aparelho.';
comment on column ponto_marcacoes.cpf is 'CPF do trabalhador no momento da marcação: a marcação não muda se o cadastro mudar.';
comment on column ponto_marcacoes.origem is 'Só identificadores técnicos do canal (msg_id, call_sid, app_versao). Nunca o conteúdo da mensagem: a tabela não admite descarte antes de 5 anos.';
comment on column ponto_marcacoes.dentro_area is 'Dentro do raio do local. Fora (false) é sinalizado ao gestor, nunca bloqueado; nulo = sem localização ou sem local com área.';
create index if not exists ponto_marcacoes_tecnico_momento_idx on ponto_marcacoes (tecnico_id, momento);
create index if not exists ponto_marcacoes_local_id_idx on ponto_marcacoes (local_id);
alter table ponto_marcacoes enable row level security;

create table if not exists ponto_nsr (
  empresa_id uuid primary key references empresas(id),
  ultimo     bigint not null default 0,
  ultimo_hash text not null default repeat('0', 64)
);
comment on table ponto_nsr is 'Último NSR e último hash por empresa. A linha travada serializa as marcações da empresa: NSR sem lacuna.';
alter table ponto_nsr enable row level security;

-- 2. Ajustes --------------------------------------------------------------------------------------

create table if not exists ponto_ajustes (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references empresas(id),
  tecnico_id    uuid not null references tecnicos(id),
  marcacao_id   uuid references ponto_marcacoes(id),
  acao          text not null check (acao in ('incluir','desconsiderar')),
  momento       timestamptz,
  tipo          text check (tipo in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he')),
  motivo        text not null check (length(trim(motivo)) >= 10),
  autor         text not null,
  created_at    timestamptz not null default now(),
  check (acao <> 'desconsiderar' or marcacao_id is not null),
  check (acao <> 'incluir' or (momento is not null and tipo is not null))
);
comment on table ponto_ajustes is 'Ajuste do ponto: nunca altera a marcação original. Só inclusão, com motivo e autor.';
create index if not exists ponto_ajustes_tecnico_idx on ponto_ajustes (tecnico_id);
create index if not exists ponto_ajustes_marcacao_idx on ponto_ajustes (marcacao_id);
create index if not exists ponto_ajustes_empresa_idx on ponto_ajustes (empresa_id);
alter table ponto_ajustes enable row level security;

-- Imutabilidade -----------------------------------------------------------------------------------

create or replace function fn_ponto_imutavel()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  raise exception 'Registro de ponto não pode ser alterado nem apagado (Portaria MTP 671/2021). Use um ajuste.';
end $$;

create or replace trigger trg_ponto_marcacoes_imutavel before update or delete on ponto_marcacoes
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_marcacoes_sem_truncate before truncate on ponto_marcacoes
  for each statement execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_ajustes_imutavel before update or delete on ponto_ajustes
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_ajustes_sem_truncate before truncate on ponto_ajustes
  for each statement execute function fn_ponto_imutavel();

-- 4. Técnico com ponto não se exclui --------------------------------------------------------------

create or replace function fn_tecnico_com_ponto()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if exists (select 1 from ponto_marcacoes where tecnico_id = old.id) then
    raise exception 'Este técnico tem registro de ponto, que precisa ser guardado por 5 anos. Desative-o em vez de excluir.';
  end if;
  return old;
end $$;

create or replace trigger trg_tecnico_com_ponto before delete on tecnicos
  for each row execute function fn_tecnico_com_ponto();

-- 3. A porta única --------------------------------------------------------------------------------

-- Hash de uma marcação: todos os campos que a definem, em ordem fixa, mais o hash da anterior.
-- Cada campo vira texto (nulo = vazio) para as posições nunca se desalinharem.
create or replace function fn_ponto_hash(m ponto_marcacoes)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(sha256(convert_to(array_to_string(array[
           m.hash_anterior, m.empresa_id::text, m.nsr::text, m.tecnico_id::text, m.cpf,
           to_char(m.momento at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
           m.tipo, m.canal, coalesce(m.latitude::text, ''), coalesce(m.longitude::text, ''),
           coalesce(m.precisao_m::text, ''), coalesce(m.local_id::text, ''),
           coalesce(m.distancia_m::text, ''), coalesce(m.dentro_area::text, ''),
           coalesce(m.escala_id::text, ''), m.origem::text], '|'), 'UTF8')), 'hex')
$$;

-- Porta única garantida pelo banco: toda marcação precisa continuar a cadeia (NSR seguinte, hash
-- anterior certo, hash conferido, hora do servidor de agora). Quem inserir por fora — mesmo com a
-- chave de serviço — é recusado.
create or replace function fn_ponto_conferir_insercao()
returns trigger language plpgsql set search_path = public, extensions as $$
declare
  v_ultimo bigint; v_hash text;
begin
  select ultimo, ultimo_hash into v_ultimo, v_hash from ponto_nsr where empresa_id = new.empresa_id;
  if v_ultimo is null or new.nsr <> v_ultimo + 1 or new.hash_anterior <> v_hash
     or new.hash <> fn_ponto_hash(new)
     or abs(extract(epoch from (clock_timestamp() - new.momento))) > 5 then
    raise exception 'Marcação fora da porta única (fn_ponto_registrar): recusada.';
  end if;
  return new;
end $$;

create or replace trigger trg_ponto_marcacoes_porta_unica before insert on ponto_marcacoes
  for each row execute function fn_ponto_conferir_insercao();

-- ponto_nsr só avança de um em um, apontando para a marcação que acabou de entrar.
create or replace function fn_ponto_nsr_avanca()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if tg_op = 'DELETE' or new.empresa_id <> old.empresa_id or new.ultimo <> old.ultimo + 1
     or not exists (select 1 from ponto_marcacoes m where m.empresa_id = new.empresa_id
                     and m.nsr = new.ultimo and m.hash = new.ultimo_hash) then
    raise exception 'Controle de NSR não pode ser alterado por fora do registro de ponto.';
  end if;
  return new;
end $$;

create or replace trigger trg_ponto_nsr_avanca before update or delete on ponto_nsr
  for each row execute function fn_ponto_nsr_avanca();
create or replace trigger trg_ponto_nsr_sem_truncate before truncate on ponto_nsr
  for each statement execute function fn_ponto_imutavel();

-- Nem a chave de serviço (Edge Functions) escreve direto nas tabelas do ponto: só pela função.
revoke all on ponto_marcacoes, ponto_ajustes, ponto_nsr from anon, authenticated, service_role;

create or replace function fn_ponto_registrar(p_tecnico uuid, p_tipo text, p_canal text,
  p_lat numeric default null, p_lng numeric default null, p_precisao int default null,
  p_origem jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
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
  select e.id, e.cnpj, e.razao_social, e.fuso into v_emp from empresas e where e.id = v_tec.empresa_id;

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
   where k in ('msg_id', 'call_sid', 'app_versao');

  v_m := row(gen_random_uuid(), v_emp.id, v_nsr, p_tecnico, v_tec.cpf, v_agora, p_tipo, p_canal, v_lat, v_lng,
             p_precisao, v_local_id, v_dist, v_dentro, v_escala, v_origem, v_ant, null)::ponto_marcacoes;
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
    'autenticacao', left(v_hash, 16));
end $$;

-- 5. Painel ---------------------------------------------------------------------------------------

create or replace function app_ponto_marcacoes(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, nsr bigint, empresa text, tecnico_id uuid, tecnico text, momento timestamptz,
               tipo text, canal text, local text, distancia_m int, dentro_area boolean,
               latitude numeric, longitude numeric, ajustada boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
begin
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select m.id, m.nsr, coalesce(e.nome_fantasia, e.razao_social), m.tecnico_id, t.nome, m.momento,
           m.tipo, m.canal, l.nome, m.distancia_m, m.dentro_area,
           case when v_leitura then null else m.latitude end,
           case when v_leitura then null else m.longitude end,
           exists (select 1 from ponto_ajustes a where a.marcacao_id = m.id)
      from ponto_marcacoes m
      join tecnicos t on t.id = m.tecnico_id
      join empresas e on e.id = m.empresa_id
      left join locais l on l.id = m.local_id
     where (m.momento at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or m.tecnico_id = p_tecnico)
     order by m.momento;
end $$;

-- Recalcula a cadeia de uma empresa e aponta o primeiro NSR que não confere (ou lacuna).
create or replace function app_ponto_verificar(p_empresa uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  m ponto_marcacoes;
  v_ant text := repeat('0', 64);
  v_esperado bigint := 1;
  v_total int := 0;
begin
  perform app_exigir(array['admin']);
  for m in select * from ponto_marcacoes where empresa_id = p_empresa order by nsr loop
    if m.nsr <> v_esperado then
      return jsonb_build_object('integra', false, 'nsr', v_esperado, 'motivo', 'lacuna no NSR', 'conferidas', v_total);
    end if;
    if m.hash_anterior <> v_ant or m.hash <> fn_ponto_hash(m) then
      return jsonb_build_object('integra', false, 'nsr', m.nsr, 'motivo', 'hash não confere', 'conferidas', v_total);
    end if;
    v_ant := m.hash; v_esperado := v_esperado + 1; v_total := v_total + 1;
  end loop;
  return jsonb_build_object('integra', true, 'conferidas', v_total);
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
