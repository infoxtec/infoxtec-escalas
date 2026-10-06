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
--
-- Revisão do seguranca (07/10), corrigido aqui: resposta única no login (sem revelar cadastro);
-- trava por funcionário contra corrida; limites por funcionário, por IP e no total (força bruta e
-- disparo de WhatsApp em massa); login pelo código do gestor fica marcado na sessão e na marcação, e
-- o funcionário é avisado; código do gestor não é invalidado por pedido de WhatsApp nem herda erros
-- anteriores; guarda de códigos (24 h), sessões (90 dias) e acessos (30 dias).
-- Segunda rodada: IP pelo cf-connecting-ip ou pelo último endereço do x-forwarded-for; com o teto
-- estourado, o código do gestor continua entrando e os supervisores são avisados; o gestor que gerou
-- o código vai para a sessão e para a marcação.

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
  motivo        text,
  codigo_id     uuid,
  criado_por    text,
  login_origem  text not null default 'whatsapp' check (login_origem in ('whatsapp', 'gestor'))
);
comment on table ponto_sessoes is 'Sessões do app do ponto. Uma ativa por funcionário: novo login encerra a anterior.';
comment on column ponto_sessoes.criado_por is 'Gestor que gerou o código, quando o login foi por contingência: vai para a marcação (guarda de 5 anos).';
comment on column ponto_sessoes.login_origem is 'gestor = entrou com código gerado no painel: fica registrado em cada marcação feita na sessão.';
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

create table if not exists ponto_acessos (
  id          bigint generated always as identity primary key,
  momento     timestamptz not null default now(),
  tipo        text not null check (tipo in ('pedir_codigo', 'entrar_erro', 'entrar_ok')),
  ip          text,
  tecnico_id  uuid references tecnicos(id) on delete cascade
);
comment on table ponto_acessos is 'Pedidos de código e tentativas de login do app do ponto: base dos limites por IP e no total. Guarda de 30 dias.';
create index if not exists ponto_acessos_momento_idx on ponto_acessos (momento);
create index if not exists ponto_acessos_ip_idx on ponto_acessos (ip, momento);
create index if not exists ponto_acessos_tecnico_idx on ponto_acessos (tecnico_id);
alter table ponto_acessos enable row level security;

revoke all on ponto_codigos, ponto_sessoes, ponto_ciencias, ponto_acessos from anon, authenticated, service_role;

insert into config (chave, valor, descricao) values
  ('ponto_max_codigos_hora', '60', 'App do ponto: teto de códigos enviados por WhatsApp por hora, em toda a base (protege o número).'),
  ('ponto_max_erros_hora', '300', 'App do ponto: teto de logins errados por hora, em toda a base; acima disso o login fica suspenso.')
on conflict (chave) do nothing;

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

-- IP de quem chama. Nunca o primeiro endereço do x-forwarded-for (quem chama escolhe): vale o
-- cf-connecting-ip, que a borda do Supabase preenche, ou o último endereço, que o proxy acrescenta.
create or replace function fn_ponto_ip()
returns text language sql stable set search_path = public, extensions as $$
  with h as (select current_setting('request.headers', true)::json as j)
  select coalesce(nullif(trim(j ->> 'cf-connecting-ip'), ''),
                  nullif(trim((regexp_split_to_array(coalesce(j ->> 'x-forwarded-for', ''), ','))
                    [array_length(regexp_split_to_array(coalesce(j ->> 'x-forwarded-for', ''), ','), 1)]), ''))
    from h
$$;

-- Teto total atingido (ataque ou pico): avisa os supervisores pelo WhatsApp, no máximo uma vez por hora.
create or replace function fn_ponto_alerta_teto(p_qual text)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  s record;
begin
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_teto_' || p_qual || '_' || to_char(now() at time zone 'America/Bahia', 'HH24'),
          (now() at time zone 'America/Bahia')::date, now(), true, jsonb_build_object('teto', p_qual))
  on conflict do nothing;
  if not found then return; end if;
  raise warning 'app do ponto: teto de % por hora atingido', p_qual;
  for s in select telefone_e164 from tecnicos where is_supervisor and ativo and opt_in and not perfil_teste loop
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', s.telefone_e164,
          'text', 'Trilha Ponto: o limite de ' || case when p_qual = 'erros' then 'tentativas de login'
                  else 'códigos por WhatsApp' end || ' por hora foi atingido (possível ataque). '
                  || 'Enquanto durar, o funcionário entra com o código gerado pelo gestor no painel.'));
    exception when others then null;
    end;
  end loop;
end $$;

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

-- Resposta sempre igual, exista ou não o CPF: não revela quem é funcionário. Limites: 3 por
-- funcionário a cada 15 min e 6 por dia; 10 por IP por hora; teto total por hora (config). Estourou:
-- não envia, responde igual e deixa aviso no log do banco.
create or replace function ponto_pedir_codigo(p_cpf text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_ip   text := fn_ponto_ip();
  v_tec  record;
  v_cod  text;
  v_id   uuid := gen_random_uuid();
  v_resp jsonb := jsonb_build_object('mensagem',
    'Se o CPF estiver cadastrado, você recebe o código no WhatsApp em instantes. Ele vale por 5 minutos.');
begin
  insert into ponto_acessos (tipo, ip) values ('pedir_codigo', v_ip);
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'pedir_codigo'
                            and momento > now() - interval '1 hour') > 10 then
    return v_resp;
  end if;
  if (select count(*) from ponto_codigos where origem = 'whatsapp' and created_at > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_codigos_hora'), 60) then
    perform fn_ponto_alerta_teto('codigos');
    return v_resp;
  end if;
  if not fn_cpf_valido(v_cpf) then return v_resp; end if;
  select id, telefone_e164, opt_in into v_tec from tecnicos where cpf = v_cpf and ativo;
  if v_tec.id is null or not v_tec.opt_in then return v_resp; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));
  if (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
        and created_at > now() - interval '15 minutes') >= 3
     or (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
        and created_at > now() - interval '1 day') >= 6 then
    return v_resp;
  end if;

  -- só vence os códigos de WhatsApp anteriores: o código do gestor continua valendo
  update ponto_codigos set expira_em = now()
   where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > now();
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

-- Uma única resposta de erro para tudo (CPF inexistente, código errado, vencido, bloqueio): não
-- revela cadastro. Erros voltam como {erro}, sem exceção, para a contagem não ser desfeita.
-- Bloqueios: 10 erros por funcionário na hora (contados depois do último código do gestor), 20 por IP
-- na hora, e um teto total por hora (config) que suspende o login e avisa no log do banco.
create or replace function ponto_entrar(p_cpf text, p_codigo text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cpf    text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_codigo text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_ip     text := fn_ponto_ip();
  v_tec    record;
  v_c      record;
  v_desde  timestamptz;
  v_token  text;
  v_restrito boolean := false;
  v_erro   jsonb := jsonb_build_object('erro', 'Não foi possível entrar. Confira o CPF e o código, ou peça um código novo.');
begin
  -- Teto total ou do IP estourado: só o código do gestor entra (ninguém trava a empresa inteira)
  if (select count(*) from ponto_acessos where tipo = 'entrar_erro' and momento > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_erros_hora'), 300) then
    v_restrito := true;
    perform fn_ponto_alerta_teto('erros');
  end if;
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'entrar_erro'
                            and momento > now() - interval '1 hour') >= 20 then
    v_restrito := true;
  end if;

  select t.id, t.nome, e.razao_social, e.nome_fantasia into v_tec
    from tecnicos t left join empresas e on e.id = t.empresa_id
   where fn_cpf_valido(v_cpf) and v_codigo ~ '^[0-9]{6}$' and t.cpf = v_cpf and t.ativo;
  if v_tec.id is null then
    insert into ponto_acessos (tipo, ip) values ('entrar_erro', v_ip);
    return v_erro;
  end if;

  -- uma tentativa por vez por funcionário: sem corrida entre requisições paralelas
  perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));

  -- 10 erros na hora (contados depois do último código do gestor): só o código do gestor entra
  select max(created_at) into v_desde from ponto_codigos where tecnico_id = v_tec.id and origem = 'gestor';
  if (select count(*) from ponto_acessos where tecnico_id = v_tec.id and tipo = 'entrar_erro'
        and momento > greatest(now() - interval '1 hour', coalesce(v_desde, '-infinity'))) >= 10 then
    v_restrito := true;
  end if;

  select * into v_c from ponto_codigos
   where tecnico_id = v_tec.id and usado_em is null and expira_em > clock_timestamp() and tentativas < 5
     and codigo_hash = fn_sha256(id::text || ':' || v_codigo) and (not v_restrito or origem = 'gestor')
   order by created_at desc limit 1 for update;
  if v_c.id is null then
    -- erro gasta as tentativas só do código de WhatsApp: ninguém esgota o código do gestor de fora
    -- (ele vale 15 min e continua sob os limites por IP e total)
    update ponto_codigos set tentativas = tentativas + 1,
           expira_em = case when tentativas + 1 >= 5 then now() else expira_em end
     where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > clock_timestamp();
    insert into ponto_acessos (tipo, ip, tecnico_id) values ('entrar_erro', v_ip, v_tec.id);
    return v_erro;
  end if;

  update ponto_codigos set usado_em = now() where id = v_c.id;
  update ponto_sessoes set encerrada_em = now(), motivo = 'novo login'
   where tecnico_id = v_tec.id and encerrada_em is null;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into ponto_sessoes (tecnico_id, token_hash, expira_em, codigo_id, criado_por, login_origem)
  values (v_tec.id, fn_sha256(v_token), now() + interval '12 hours', v_c.id, v_c.criado_por, v_c.origem);
  insert into ponto_acessos (tipo, ip, tecnico_id) values ('entrar_ok', v_ip, v_tec.id);

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
  if coalesce(trim(p_versao_aviso), '') !~ '^[A-Za-z0-9._-]{1,40}$' then raise exception 'Versão do aviso inválida.'; end if;
  insert into ponto_ciencias (tecnico_id, versao) values (v_tec, trim(p_versao_aviso)) on conflict do nothing;
end $$;

-- Bater o ponto pelo app: o funcionário vem da sessão, nunca de parâmetro (revisão do seguranca).
create or replace function ponto_bater(p_token text, p_tipo text, p_lat numeric, p_lng numeric,
  p_precisao int default null, p_app_versao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v_login text;
  v_gestor text;
begin
  select login_origem, criado_por into v_login, v_gestor from ponto_sessoes where token_hash = fn_sha256(p_token);
  return fn_ponto_registrar(v_tec, p_tipo, 'app', p_lat, p_lng, p_precisao,
                            jsonb_build_object('app_versao', p_app_versao, 'login_origem', v_login, 'gestor', v_gestor));
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
  v_email text;
  v_tec   record;
  v_cod   text := fn_ponto_novo_codigo();
  v_id    uuid := gen_random_uuid();
begin
  v_email := app_exigir(array['admin','gestor']);
  select t.id, t.nome, t.cpf, t.ativo, t.opt_in, t.telefone_e164, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if v_tec.id is null then raise exception 'Técnico não encontrado.'; end if;
  if not v_tec.ativo or v_tec.cpf is null then raise exception 'O técnico precisa estar ativo e com CPF cadastrado.'; end if;
  update ponto_codigos set expira_em = now() where tecnico_id = p_tecnico and usado_em is null and expira_em > now();
  insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, criado_por, expira_em)
  values (v_id, p_tecnico, fn_sha256(v_id::text || ':' || v_cod), 'gestor', v_email, now() + interval '15 minutes');
  -- o funcionário fica sabendo: marcação feita com código do gestor nunca passa despercebida
  if v_tec.opt_in then
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_tec.telefone_e164,
          'text', 'Trilha Ponto: o seu gestor gerou um código de acesso ao seu ponto em ' ||
                  to_char(now() at time zone v_tec.fuso, 'DD/MM HH24:MI') ||
                  '. Se não foi a seu pedido, avise o RH.'));
    exception when others then
      raise warning 'app_ponto_gerar_codigo: aviso ao funcionário falhou (%)', sqlerrm;
    end;
  end if;
  return jsonb_build_object('codigo', v_cod, 'nome', v_tec.nome, 'expira_em', now() + interval '15 minutes');
end $$;

-- fn_ponto_registrar (migration 54): origem passa a aceitar login_origem, que também vai no comprovante
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
   where k in ('msg_id', 'call_sid', 'app_versao', 'login_origem', 'gestor') and jsonb_typeof(v) <> 'null';

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
    'login_origem', v_origem ->> 'login_origem',
    'autenticacao', left(v_hash, 16));
end $$;

-- Guarda (LGPD): códigos 24 h, sessões encerradas ou vencidas 90 dias, acessos 30 dias. A limpeza
-- diária que já existe passa a cuidar disso; marcações e ajustes continuam fora dela.
create or replace function fn_limpeza_logs()
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_webhook int; v_alertas int; v_cron int; v_payload int; v_codigos int; v_sessoes int; v_acessos int;
begin
  delete from webhook_eventos
   where recebido_em < now() - make_interval(days => coalesce(fn_config_int('retencao_webhook_dias'), 30));
  get diagnostics v_webhook = row_count;
  delete from alertas_enviados where data_ref < current_date - 90;
  get diagnostics v_alertas = row_count;
  delete from cron.job_run_details
   where end_time < now() - make_interval(days => coalesce(fn_config_int('retencao_cron_dias'), 7));
  get diagnostics v_cron = row_count;
  -- o conteudo enviado so serve para conferencia recente; a notificacao (status, datas) fica
  update notificacoes set payload_envio = null
   where payload_envio is not null
     and created_at < now() - make_interval(days => coalesce(fn_config_int('retencao_payload_dias'), 90));
  get diagnostics v_payload = row_count;
  delete from ponto_codigos where created_at < now() - interval '24 hours';
  get diagnostics v_codigos = row_count;
  delete from ponto_sessoes where coalesce(encerrada_em, expira_em) < now() - interval '90 days';
  get diagnostics v_sessoes = row_count;
  delete from ponto_acessos where momento < now() - interval '30 days';
  get diagnostics v_acessos = row_count;
  return jsonb_build_object('webhook_eventos', v_webhook, 'alertas_enviados', v_alertas,
                            'cron', v_cron, 'payload_notificacoes', v_payload,
                            'ponto_codigos', v_codigos, 'ponto_sessoes', v_sessoes, 'ponto_acessos', v_acessos);
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
