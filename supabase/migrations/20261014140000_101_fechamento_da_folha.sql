-- Migration 101: validação e fechamento da folha mensal, e logotipo da empresa no espelho (decisão 96).
-- Pedido do responsável (14/10): antes de fechar, o painel aponta o que falta ajustar em cada funcionário (dia sem
-- registro nem justificativa, marcação incompleta, pedido aguardando decisão) e a folha fecha num clique.
--   fn_ponto_folha_pendencias  o que falta em um funcionário num mês; "bloqueia" impede o fechamento
--   app_ponto_validar_folha    o painel de validação: todos os funcionários do mês, com pendências e espelho
--   app_ponto_fechar_folha     fecha um funcionário: sem bloqueio, e com as faltas confirmadas, emite o espelho e
--                              registra quem fechou e as faltas que confirmou (o painel chama um por funcionário, para
--                              caber no tempo de cada chamada, e envia pelo WhatsApp no fim)
--   app_ponto_emitir_espelhos  passa a recusar funcionário com pendência que bloqueia, e com falta sem confirmação;
--                              registra o fechamento de toda emissão e grava o logotipo da empresa (ganha o parâmetro
--                              p_confirmar_faltas: a assinatura muda, então a de dois parâmetros sai)
-- Logotipo: empresas.logo é o nome de um logotipo publicado com o painel (web/public); entra congelado no espelho, em
-- empregador.logo. A Infoxtec (CNPJ 04.309.223/0001-96, docs/marca.md) já sai com o dela nos dois ambientes.
-- Recriadas a partir da definição atual da homologação: app_ponto_emitir_espelhos (md5 a5865d7a5bf1337743a3250f5ecebf9f)
-- e app_salvar_empresa (md5 f2dd66af430e4ffb20e58b97b60206b4).

-- Logotipo da empresa -----------------------------------------------------------------------------------
alter table empresas add column if not exists logo text check (logo ~ '^[a-z0-9-]{1,40}$');
comment on column empresas.logo is 'Logotipo no espelho de ponto: nome de um logotipo publicado com o painel (decisão 96)';
update empresas set logo = 'infoxtec' where cnpj = '04309223000196' and logo is null;

-- Registro do fechamento --------------------------------------------------------------------------------
create table if not exists ponto_folha_fechamentos (
  id                  uuid primary key default gen_random_uuid(),
  empresa_id          uuid not null references empresas(id),
  tecnico_id          uuid not null references tecnicos(id),
  competencia         date not null check (extract(day from competencia) = 1),
  espelho_id          uuid not null references ponto_espelhos(id),
  faltas_confirmadas  jsonb not null default '[]'::jsonb,
  fechado_por         text not null,
  fechado_em          timestamptz not null default now()
);
create index if not exists ponto_folha_fechamentos_mes on ponto_folha_fechamentos (competencia, tecnico_id);
alter table ponto_folha_fechamentos enable row level security;
-- é o registro de quem fechou e de quais faltas confirmou: não se altera nem se apaga
create or replace trigger trg_ponto_folha_fechamentos_imutavel before update or delete on ponto_folha_fechamentos
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_folha_fechamentos_sem_truncate before truncate on ponto_folha_fechamentos
  for each statement execute function fn_ponto_imutavel();

-- Pendências de um funcionário no mês -------------------------------------------------------------------
-- bloqueia: pedido do funcionário aguardando decisão; marcação incompleta (falta entrada, saída ou volta).
-- não bloqueia, mas precisa de confirmação: dia devido sem marcação e sem abono, que sai como falta descontada.
-- Dia devido é o da escala (fn_carga_dia) com jornada; feriado não é devido, salvo o plantão da 12x36; sábado sem
-- escala e sem expediente é abonado pela decisão interna (como na aba Indicadores).
create or replace function fn_ponto_folha_pendencias(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_fim   date := (date_trunc('month', p_mes) + interval '1 month')::date - 1;
  v_ontem date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_abona boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_res   jsonb := '[]'::jsonb;
  v_dias  int := 0;
  t record; r record;
begin
  select coalesce(admissao, created_at::date) as adm, desligado_em into t from tecnicos where id = p_tecnico;
  if not found then return v_res; end if;

  select coalesce(jsonb_agg(jsonb_build_object('tipo', 'pedido_pendente', 'bloqueia', true, 'data', j.data,
           'numero', j.numero, 'motivo', j.motivo) order by j.data, j.numero), '[]'::jsonb)
    into v_res
    from ponto_justificativas j
   where j.tecnico_id = p_tecnico and j.status = 'pendente'
     and j.data <= v_fim and coalesce(j.data_fim, j.data) >= v_mes;

  for r in select g::date as dia, fn_ponto_jornada_dia(p_tecnico, g::date) as j, fn_carga_dia(p_tecnico, g::date) as c
             from generate_series(greatest(v_mes, t.adm), least(v_fim, v_ontem, coalesce(t.desligado_em, v_fim)),
                                  interval '1 day') g loop
    if r.j is not null then
      v_dias := v_dias + 1;
      if r.j->'alertas' ? 'incompleta' then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_incompleta', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
    elsif coalesce((r.c->>'minutos')::int, 0) > 0
      and not (r.c->>'tipo' is distinct from '12x36'
               and exists (select 1 from feriados f where f.data = r.dia and f.abrangencia <> 'facultativo'))
      and not (extract(isodow from r.dia) = 6 and r.c->>'escala' is null and v_abona) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'bloqueia', false,
                 'data', r.dia, 'minutos', (r.c->>'minutos')::int));
    end if;
  end loop;

  -- funcionário sem nenhum registro no mês não entra no fechamento (o espelho não é emitido): não há o que apontar
  if v_dias = 0 and not exists (select 1 from jsonb_array_elements(v_res) x where x->>'tipo' = 'pedido_pendente') then
    return '[]'::jsonb;
  end if;
  return v_res;
end $$;

-- Painel de validação da folha --------------------------------------------------------------------------
create or replace function app_ponto_validar_folha(p_competencia date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_mes date := date_trunc('month', p_competencia)::date;
  v_fim date := (date_trunc('month', p_competencia) + interval '1 month')::date - 1;
  v_res jsonb;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'A folha só é validada e fechada para mês já encerrado.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'tecnico_id', x.id, 'nome', x.nome, 'empresa', x.empresa, 'pendencias', x.p,
           'bloqueios', (select count(*) from jsonb_array_elements(x.p) e where (e->>'bloqueia')::boolean),
           'sem_registro', (select count(*) from jsonb_array_elements(x.p) e where e->>'tipo' = 'sem_registro'),
           'com_ponto', x.com_ponto,
           'espelho', x.espelho, 'fechado', x.fechado) order by x.nome), '[]'::jsonb)
    into v_res
    from (select tc.id, tc.nome, coalesce(em.nome_fantasia, em.razao_social) as empresa,
                 fn_ponto_folha_pendencias(tc.id, v_mes) as p,
                 exists (select 1 from ponto_marcacoes m where m.tecnico_id = tc.id
                          and m.momento >= v_mes::timestamp at time zone 'America/Bahia'
                          and m.momento < (v_fim + 1)::timestamp at time zone 'America/Bahia')
                   or exists (select 1 from ponto_abonos a where a.tecnico_id = tc.id and a.data between v_mes and v_fim) as com_ponto,
                 (select jsonb_build_object('id', e.id, 'versao', e.versao, 'registro', e.registro, 'emitido_em', e.emitido_em,
                         'enviado_em', e.enviado_em, 'assinado_em', e.assinado_em)
                    from ponto_espelhos e where e.tecnico_id = tc.id and e.competencia = v_mes and e.substituido_em is null) as espelho,
                 -- o papel leitura não vê quem fechou (como o autor dos ajustes, migrations 65 e 66)
                 (select jsonb_build_object('fechado_por', case when v_leitura then null else f.fechado_por end, 'fechado_em', f.fechado_em,
                         'faltas_confirmadas', jsonb_array_length(f.faltas_confirmadas))
                    from ponto_folha_fechamentos f where f.tecnico_id = tc.id and f.competencia = v_mes
                   order by f.fechado_em desc limit 1) as fechado
            from tecnicos tc join empresas em on em.id = tc.empresa_id
           where tc.cpf is not null and not tc.perfil_teste
             and coalesce(tc.admissao, tc.created_at::date) <= v_fim
             and (tc.ativo or tc.desligado_em >= v_mes)) x;

  return jsonb_build_object('competencia', v_mes, 'funcionarios', v_res);
end $$;

-- Emissão do espelho: recusa quem tem pendência que bloqueia ou falta não confirmada, registra o fechamento e grava
-- o logotipo da empresa. A assinatura ganha p_confirmar_faltas: a função de dois parâmetros sai.
drop function if exists app_ponto_emitir_espelhos(date, uuid);
create or replace function app_ponto_emitir_espelhos(p_competencia date, p_tecnico uuid default null,
                                                     p_confirmar_faltas boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_mes    date := date_trunc('month', p_competencia)::date;
  v_fim    date := (date_trunc('month', p_competencia) + interval '1 month')::date - 1;
  t        record;
  v_atual  record;
  v_cont   jsonb;
  v_sha    text;
  v_reg    bigint;
  v_p      jsonb;
  v_falt   jsonb;
  v_novo   uuid;
  v_emit   int := 0; v_igual int := 0; v_assin int := 0; v_vazio int := 0; v_pend int := 0; v_conf int := 0;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'O espelho só é emitido para mês já encerrado.';
  end if;
  for t in select tc.id, tc.empresa_id, em.logo from tecnicos tc join empresas em on em.id = tc.empresa_id
            where tc.cpf is not null and not tc.perfil_teste
              and (p_tecnico is null or tc.id = p_tecnico)
              and coalesce(tc.admissao, tc.created_at::date) <= v_fim
              and (tc.ativo or tc.desligado_em >= v_mes)
            order by tc.nome loop
    select e.id, e.sha256, e.versao, e.assinado_em into v_atual from ponto_espelhos e
     where e.tecnico_id = t.id and e.competencia = v_mes and e.substituido_em is null
       for update;   -- a assinatura (parte B) espera; e o gatilho não deixa substituir o assinado
    if v_atual.assinado_em is not null then v_assin := v_assin + 1; continue; end if;
    -- pedido aguardando decisão ou marcação incompleta: a folha desse funcionário não fecha; dia sem registro nem
    -- justificativa sai como falta descontada só com a confirmação de quem fecha (decisão 96)
    v_p := fn_ponto_folha_pendencias(t.id, v_mes);
    if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
      v_pend := v_pend + 1; continue;
    end if;
    select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_falt
      from jsonb_array_elements(v_p) x where x->>'tipo' = 'sem_registro';
    if jsonb_array_length(v_falt) > 0 and not coalesce(p_confirmar_faltas, false) then
      v_conf := v_conf + 1; continue;
    end if;
    v_cont := fn_ponto_espelho_conteudo(t.id, v_mes);
    if jsonb_array_length(v_cont->'dias') = 0 and jsonb_array_length(v_cont->'ajustes') = 0 then
      v_vazio := v_vazio + 1; continue;
    end if;
    if t.logo is not null then v_cont := jsonb_set(v_cont, '{empregador,logo}', to_jsonb(t.logo)); end if;
    -- o hash é dos bytes exatos guardados em conteudo_texto (a forma do jsonb pode mudar entre versões do Postgres)
    v_sha := encode(sha256(convert_to(v_cont::text, 'UTF8')), 'hex');
    if v_atual.id is not null and v_atual.sha256 = v_sha then v_igual := v_igual + 1; continue; end if;
    if v_atual.id is not null then update ponto_espelhos set substituido_em = now() where id = v_atual.id; end if;
    -- registro por empresa sem lacuna: a linha do contador fica travada até o fim da transação
    insert into ponto_espelho_sequencia (empresa_id) values (t.empresa_id) on conflict (empresa_id) do nothing;
    update ponto_espelho_sequencia set ultimo = ultimo + 1 where empresa_id = t.empresa_id returning ultimo into v_reg;
    insert into ponto_espelhos (empresa_id, tecnico_id, competencia, versao, registro, codigo, conteudo, conteudo_texto, sha256, emitido_por)
    values (t.empresa_id, t.id, v_mes, coalesce(v_atual.versao, 0) + 1, v_reg, fn_ponto_codigo_verificacao(), v_cont, v_cont::text, v_sha, v_email)
    returning id into v_novo;
    -- toda emissão é um fechamento: quem emitiu e as faltas que confirmou
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, faltas_confirmadas, fechado_por)
    values (t.empresa_id, t.id, v_mes, v_novo, v_falt, v_email);
    v_emit := v_emit + 1;
  end loop;
  return jsonb_build_object('emitidos', v_emit, 'sem_mudanca', v_igual, 'ja_assinados', v_assin, 'sem_dados', v_vazio,
                            'com_pendencia', v_pend, 'faltas_a_confirmar', v_conf);
end $$;

-- Fechamento de um funcionário --------------------------------------------------------------------------
create or replace function app_ponto_fechar_folha(p_competencia date, p_tecnico uuid, p_confirmar_faltas boolean default false)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_mes   date := date_trunc('month', p_competencia)::date;
  v_p     jsonb;
  v_falt  jsonb;
  v_r     jsonb;
  v_esp   record;
begin
  if p_tecnico is null then raise exception 'Informe o funcionário.'; end if;
  v_p := fn_ponto_folha_pendencias(p_tecnico, v_mes);
  if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
    return jsonb_build_object('situacao', 'pendente', 'pendencias', v_p);
  end if;
  select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_falt
    from jsonb_array_elements(v_p) x where x->>'tipo' = 'sem_registro';
  if jsonb_array_length(v_falt) > 0 and not coalesce(p_confirmar_faltas, false) then
    return jsonb_build_object('situacao', 'confirmar_faltas', 'faltas', v_falt);
  end if;

  v_r := app_ponto_emitir_espelhos(v_mes, p_tecnico, p_confirmar_faltas);   -- confere o mês encerrado e o papel de novo
  select e.id, e.empresa_id, e.assinado_em into v_esp from ponto_espelhos e
   where e.tecnico_id = p_tecnico and e.competencia = v_mes and e.substituido_em is null;
  if v_esp.id is null then
    return jsonb_build_object('situacao', 'sem_dados');
  end if;
  -- espelho emitido antes da migration 101 (sem registro de fechamento): o fechamento sem mudança registra agora
  if v_esp.assinado_em is null and not exists (select 1 from ponto_folha_fechamentos f where f.espelho_id = v_esp.id) then
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, faltas_confirmadas, fechado_por)
    values (v_esp.empresa_id, p_tecnico, v_mes, v_esp.id, v_falt, v_email);
  end if;
  return jsonb_build_object('situacao', case when v_esp.assinado_em is not null then 'ja_assinado'
                                             when (v_r->>'emitidos')::int > 0 then 'fechado' else 'sem_mudanca' end,
                            'espelho', v_esp.id, 'faltas_confirmadas', jsonb_array_length(v_falt));
end $$;

-- Cadastro da empresa com o logotipo --------------------------------------------------------------------
create or replace function app_salvar_empresa(p jsonb)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_cnpj  text := regexp_replace(coalesce(p->>'cnpj', ''), '\D', '', 'g');
  v_logo  text := nullif(trim(p->>'logo'), '');
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;
  if v_logo is not null and v_logo !~ '^[a-z0-9-]{1,40}$' then raise exception 'Logotipo inválido.'; end if;

  if v_id is null then
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cidade, uf, empregadora, ativo, logo)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true), v_logo)
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      uf = upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
      empregadora = coalesce((p->>'empregadora')::boolean, false),
      ativo = coalesce((p->>'ativo')::boolean, true),
      -- painel antigo não manda o logotipo: fica o que estava
      logo = case when p ? 'logo' then v_logo else logo end
    where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma empresa com este CNPJ.';
end $$;

-- Permissões por laço (decisão 12) ----------------------------------------------------------------
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
