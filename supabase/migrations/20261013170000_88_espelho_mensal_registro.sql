-- Migration 88 (13/10/2026): espelho de ponto mensal com registro e QR de verificação (decisão 82, parte A).
-- Pedido do responsável: o espelho do mês vai ao funcionário pelo WhatsApp, com hash auditável em QR, e ele
-- assina. Esta parte cria a cópia congelada: o gestor emite o espelho de um mês já fechado; o conteúdo
-- (Portaria 671, Art. 84: empregador, trabalhador, jornada contratual, marcações e marcações tratadas,
-- duração) fica gravado com SHA-256, número de registro por empresa sem lacuna e código de verificação de
-- 80 bits. O QR leva a uma conferência PÚBLICA que não mostra dado pessoal: só registro, empresa, mês,
-- integridade e se foi assinado (decisão do responsável). Reemissão gera nova versão e marca a anterior como
-- substituída; espelho assinado não é reemitido. Assinatura, envio pelo WhatsApp e tela do funcionário: parte B
-- (as colunas já nascem aqui e só podem ser preenchidas uma vez).

create table if not exists ponto_espelho_sequencia (
  empresa_id uuid primary key references empresas(id),
  ultimo     bigint not null default 0
);
alter table ponto_espelho_sequencia enable row level security;

create table if not exists ponto_espelhos (
  id                 uuid primary key default gen_random_uuid(),
  empresa_id         uuid not null references empresas(id),
  tecnico_id         uuid not null references tecnicos(id),
  competencia        date not null check (extract(day from competencia) = 1),
  versao             int not null default 1,
  registro           bigint not null,
  codigo             text not null unique check (codigo ~ '^[A-Z2-7]{16}$'),
  conteudo           jsonb not null,
  conteudo_texto     text not null,
  sha256             text not null,
  emitido_em         timestamptz not null default now(),
  emitido_por        text not null,
  substituido_em     timestamptz,
  enviado_em         timestamptz,
  assinado_em        timestamptz,
  assinatura_png     text,
  assinatura_sha256  text,
  assinatura_origem  jsonb,
  unique (empresa_id, registro),
  unique (tecnico_id, competencia, versao),
  -- assinatura entra inteira ou não entra
  check ((assinado_em is null) = (assinatura_png is null) and (assinado_em is null) = (assinatura_sha256 is null))
);
comment on table ponto_espelhos is 'Espelho de ponto mensal congelado, com registro, código de verificação e assinatura do funcionário (decisão 82). Conteúdo imutável; envio, substituição e assinatura só uma vez.';
alter table ponto_espelhos enable row level security;
create index if not exists ponto_espelhos_competencia on ponto_espelhos (competencia, empresa_id);
-- uma só versão vigente por funcionário e mês
create unique index if not exists ponto_espelhos_vigente on ponto_espelhos (tecnico_id, competencia) where substituido_em is null;

-- Conteúdo, registro e código nunca mudam; envio, substituição e assinatura são gravados uma vez só.
-- Guarda: obrigação legal (LGPD art. 7º, II), 5 anos como o resto do ponto; o descarte, quando houver
-- executor, passa por migration própria que desliga este gatilho (decisão 82).
create or replace function fn_ponto_espelho_imutavel()
returns trigger language plpgsql set search_path = public, extensions as $function$
begin
  if tg_op = 'DELETE' then raise exception 'Espelho emitido não pode ser apagado.'; end if;
  if tg_op = 'INSERT' then
    if new.substituido_em is not null or new.enviado_em is not null or new.assinado_em is not null then
      raise exception 'Espelho nasce sem envio, substituição e assinatura.';
    end if;
    return new;
  end if;
  if (new.id, new.empresa_id, new.tecnico_id, new.competencia, new.versao, new.registro, new.codigo, new.conteudo,
      new.conteudo_texto, new.sha256, new.emitido_em, new.emitido_por)
     is distinct from
     (old.id, old.empresa_id, old.tecnico_id, old.competencia, old.versao, old.registro, old.codigo, old.conteudo,
      old.conteudo_texto, old.sha256, old.emitido_em, old.emitido_por) then
    raise exception 'O conteúdo do espelho emitido não muda: emita uma nova versão.';
  end if;
  if (old.substituido_em is not null and new.substituido_em is distinct from old.substituido_em)
     or (old.enviado_em is not null and new.enviado_em is distinct from old.enviado_em)
     or (old.assinado_em is not null and (new.assinado_em, new.assinatura_png, new.assinatura_sha256, new.assinatura_origem)
                                         is distinct from (old.assinado_em, old.assinatura_png, old.assinatura_sha256, old.assinatura_origem)) then
    raise exception 'Envio, substituição e assinatura do espelho são gravados uma vez só.';
  end if;
  if new.assinado_em is not null and old.assinado_em is null and old.substituido_em is not null then
    raise exception 'Este espelho foi substituído por uma versão mais nova.';
  end if;
  if new.substituido_em is not null and old.substituido_em is null and (old.assinado_em is not null or new.assinado_em is not null) then
    raise exception 'Espelho assinado não é substituído.';
  end if;
  return new;
end $function$;
create or replace trigger trg_ponto_espelhos_imutavel before insert or update or delete on ponto_espelhos
  for each row execute function fn_ponto_espelho_imutavel();
create or replace trigger trg_ponto_espelhos_sem_truncate before truncate on ponto_espelhos
  for each statement execute function fn_ponto_imutavel();

-- Conteúdo do espelho de um funcionário num mês (Portaria 671, Art. 84) -----------------------------------
create or replace function fn_ponto_espelho_conteudo(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $function$
declare
  v_t    record;
  v_fim  date := (p_mes + interval '1 month')::date - 1;
  v_dias jsonb;
  v_aj   jsonb;
begin
  select t.nome, t.cpf, t.admissao, t.funcao, e.razao_social, e.cnpj, coalesce(e.fuso, 'America/Bahia') as fuso into v_t
    from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  -- um dia entra quando tem marcação, escala, abono ou aviso
  select coalesce(jsonb_agg(jsonb_build_object('data', to_char(d, 'YYYY-MM-DD')) || x order by d), '[]'::jsonb) into v_dias
    from generate_series(p_mes, v_fim, interval '1 day') g(d)
    cross join lateral (select fn_ponto_jornada_dia(p_tecnico, g.d::date) as x) j(x)
   where j.x is not null
     and (coalesce((j.x->>'marcacoes')::int, 0) > 0 or j.x->>'escala_hora' is not null or j.x->>'abono' is not null
          or jsonb_array_length(coalesce(j.x->'alertas', '[]'::jsonb)) > 0);
  -- marcações tratadas (Art. 84, V): incluídas e desconsideradas, com o motivo; sem o e-mail de quem tratou.
  -- A desconsiderada não tem momento próprio: vale o da marcação ou do ajuste que ela desfaz
  select coalesce(jsonb_agg(jsonb_build_object(
           'acao', a.acao, 'data', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'YYYY-MM-DD'),
           'hora', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'HH24:MI'),
           'tipo', coalesce(a.tipo, x.tipo, y.tipo), 'motivo', a.motivo)
           order by coalesce(a.momento, x.momento, y.momento), a.created_at), '[]'::jsonb) into v_aj
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and (coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso)::date between p_mes and v_fim;
  return jsonb_build_object(
    'empregador', jsonb_build_object('razao_social', v_t.razao_social, 'cnpj', v_t.cnpj),
    'trabalhador', jsonb_build_object('nome', v_t.nome, 'cpf', v_t.cpf, 'admissao', v_t.admissao, 'funcao', v_t.funcao),
    'competencia', to_char(p_mes, 'MM/YYYY'), 'de', p_mes, 'ate', v_fim,
    'jornada', jsonb_build_object('dia_util_min', coalesce(nullif(fn_config('jornada_min'), '')::int, 480),
                                  'sabado_min', coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240),
                                  'intervalo_min', coalesce(nullif(fn_config('intervalo_min'), '')::int, 60)),
    'dias', v_dias, 'ajustes', v_aj,
    'totais', (select jsonb_build_object(
                 'trabalhado_min', coalesce(sum((x->>'trabalhado_min')::int), 0),
                 'he_min', coalesce(sum((x->>'he_min')::int), 0),
                 'faltas', count(*) filter (where x->'alertas' ? 'falta'),
                 'atrasos', count(*) filter (where x->'alertas' ? 'atraso'),
                 'dias_abonados', count(*) filter (where x->>'abono' is not null))
               from jsonb_array_elements(v_dias) x));
end $function$;

-- Emite (ou reemite) os espelhos de um mês fechado -------------------------------------------------------
create or replace function app_ponto_emitir_espelhos(p_competencia date, p_tecnico uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_mes    date := date_trunc('month', p_competencia)::date;
  v_fim    date := (date_trunc('month', p_competencia) + interval '1 month')::date - 1;
  t        record;
  v_atual  record;
  v_cont   jsonb;
  v_sha    text;
  v_reg    bigint;
  v_emit   int := 0; v_igual int := 0; v_assin int := 0; v_vazio int := 0;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'O espelho só é emitido para mês já encerrado.';
  end if;
  for t in select tc.id, tc.empresa_id from tecnicos tc
            where tc.cpf is not null and tc.empresa_id is not null and not tc.perfil_teste
              and (p_tecnico is null or tc.id = p_tecnico)
              and coalesce(tc.admissao, tc.created_at::date) <= v_fim
              and (tc.ativo or tc.desligado_em >= v_mes)
            order by tc.nome loop
    select e.id, e.sha256, e.versao, e.assinado_em into v_atual from ponto_espelhos e
     where e.tecnico_id = t.id and e.competencia = v_mes and e.substituido_em is null
       for update;   -- a assinatura (parte B) espera; e o gatilho não deixa substituir o assinado
    if v_atual.assinado_em is not null then v_assin := v_assin + 1; continue; end if;
    v_cont := fn_ponto_espelho_conteudo(t.id, v_mes);
    if jsonb_array_length(v_cont->'dias') = 0 and jsonb_array_length(v_cont->'ajustes') = 0 then
      v_vazio := v_vazio + 1; continue;
    end if;
    -- o hash é dos bytes exatos guardados em conteudo_texto (a forma do jsonb pode mudar entre versões do Postgres)
    v_sha := encode(sha256(convert_to(v_cont::text, 'UTF8')), 'hex');
    if v_atual.id is not null and v_atual.sha256 = v_sha then v_igual := v_igual + 1; continue; end if;
    if v_atual.id is not null then update ponto_espelhos set substituido_em = now() where id = v_atual.id; end if;
    -- registro por empresa sem lacuna: a linha do contador fica travada até o fim da transação
    insert into ponto_espelho_sequencia (empresa_id) values (t.empresa_id) on conflict (empresa_id) do nothing;
    update ponto_espelho_sequencia set ultimo = ultimo + 1 where empresa_id = t.empresa_id returning ultimo into v_reg;
    insert into ponto_espelhos (empresa_id, tecnico_id, competencia, versao, registro, codigo, conteudo, conteudo_texto, sha256, emitido_por)
    values (t.empresa_id, t.id, v_mes, coalesce(v_atual.versao, 0) + 1, v_reg, fn_ponto_codigo_verificacao(), v_cont, v_cont::text, v_sha, v_email);
    v_emit := v_emit + 1;
  end loop;
  return jsonb_build_object('emitidos', v_emit, 'sem_mudanca', v_igual, 'ja_assinados', v_assin, 'sem_dados', v_vazio);
end $function$;

-- Situação dos espelhos de um mês (painel) ---------------------------------------------------------------
create or replace function app_ponto_espelhos(p_competencia date)
returns table (id uuid, tecnico_id uuid, tecnico text, empresa text, versao int, registro bigint, codigo text,
               emitido_em timestamptz, enviado_em timestamptz, assinado_em timestamptz)
language plpgsql stable security definer set search_path = public, extensions as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select e.id, e.tecnico_id, t.nome, coalesce(m.nome_fantasia, m.razao_social), e.versao, e.registro, e.codigo,
           e.emitido_em, e.enviado_em, e.assinado_em
      from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
     where e.competencia = date_trunc('month', p_competencia)::date and e.substituido_em is null
     order by t.nome;
end $function$;

-- Conferência pública do QR: sem sessão e sem dado pessoal (decisão 82) ----------------------------------
create or replace function ponto_verificar_espelho(p_codigo text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $function$
declare
  v record;
begin
  select e.registro, e.versao, e.competencia, e.emitido_em, e.substituido_em, e.assinado_em, e.sha256,
         e.assinatura_png, e.assinatura_sha256,
         encode(sha256(convert_to(e.conteudo_texto, 'UTF8')), 'hex') as sha_atual, m.razao_social, m.cnpj
    into v
    from ponto_espelhos e join empresas m on m.id = e.empresa_id
   where e.codigo = upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z2-7]', '', 'g'));
  if not found then return jsonb_build_object('encontrado', false); end if;
  return jsonb_build_object(
    'encontrado', true, 'registro', v.registro, 'versao', v.versao,
    'empresa', v.razao_social, 'cnpj', v.cnpj, 'competencia', to_char(v.competencia, 'MM/YYYY'),
    'emitido_em', to_char(v.emitido_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'substituido', v.substituido_em is not null,
    'integro', v.sha_atual = v.sha256,
    'assinado_em', to_char(v.assinado_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'assinatura_integra', case when v.assinado_em is null then null
                               else encode(sha256(convert_to(coalesce(v.assinatura_png, ''), 'UTF8')), 'hex') = v.assinatura_sha256 end,
    'sha256', v.sha256);
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
