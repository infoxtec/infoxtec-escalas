-- Migration 102: checagens mínimas do fechamento da folha (decisão 97, pedido do responsável em 14/10).
-- Amplia a validação da migration 101:
--   bloqueia   pedido aguardando decisão; marcação incompleta; marcação duplicada (mesmo tipo seguido, ou duas a menos
--              de 3 min uma da outra)
--   confirmar  falta injustificada (dia da escala sem marcação, sem abono e sem pedido em aberto); intervalo abaixo do
--              mínimo ou jornada sem intervalo; hora extra acima de 2 h; descanso entre jornadas abaixo de 11 h; abono de
--              dia inteiro em dia com marcação
-- O espelho passa a dizer de onde vem cada abono (Atestado, licença legal, convocação, folga compensatória, abono da
-- empresa), sem o motivo de saúde em detalhe (LGPD); o dia sem registro sai como "Falta injustificada" (painel).
-- Prévia do espelho antes de fechar (app_ponto_previa_folha), para conferir HE, abonos e débitos.
-- O registro do fechamento guarda todas as ocorrências confirmadas, não só as faltas: a coluna muda de nome.
-- Efeito: o espelho ainda não assinado que tem abono sai em versão nova no próximo fechamento (o rótulo do abono muda o
-- conteúdo e o hash), com novo número de registro.
-- Recriadas a partir da definição atual da homologação (migration 101): fn_ponto_folha_pendencias,
-- app_ponto_validar_folha, app_ponto_emitir_espelhos e app_ponto_fechar_folha.

alter table ponto_folha_fechamentos rename column faltas_confirmadas to ocorrencias_confirmadas;

-- De onde vem o abono do dia, para o espelho ---------------------------------------------------------------------
-- Saúde sai só como "Atestado" (o motivo de saúde não vai ao espelho, decisão 56); o texto livre do gestor não sai.
create or replace function fn_ponto_abono_rotulo(p_tecnico uuid, p_dia date)
returns text language sql stable set search_path = public, extensions as $$
  select case when a.folga_de is not null then 'Folga compensatória'
              when j.id is not null and (j.motivo = 'atestado' or m.grupo = 'saude') then 'Atestado'
              when j.id is not null and m.grupo = 'familia' then 'Licença legal (CLT art. 473)'
              when j.id is not null and m.grupo = 'convocacao' then 'Convocação legal'
              when j.id is not null then 'Justificativa aprovada'
              else 'Abono da empresa' end
    from ponto_abonos a
    left join ponto_justificativas j on j.id = a.justificativa_id
    left join ponto_motivos m on m.codigo = j.motivo
   where a.tecnico_id = p_tecnico and a.data = p_dia and a.estorno_de is null
     and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)
   order by (a.justificativa_id is not null) desc, a.folga_de is not null desc
   limit 1
$$;

-- Conteúdo do espelho como é emitido: o cálculo do mês, o logotipo da empresa e a origem de cada abono ------------
create or replace function fn_ponto_folha_conteudo(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_cont jsonb := fn_ponto_espelho_conteudo(p_tecnico, date_trunc('month', p_mes)::date);
  v_logo text;
begin
  select e.logo into v_logo from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if v_logo is not null then v_cont := jsonb_set(v_cont, '{empregador,logo}', to_jsonb(v_logo)); end if;
  if jsonb_typeof(v_cont->'dias') = 'array' then
    v_cont := jsonb_set(v_cont, '{dias}', (
      select coalesce(jsonb_agg(case when d->>'abono' is not null
                                     then d || jsonb_build_object('abono_motivo', fn_ponto_abono_rotulo(p_tecnico, (d->>'data')::date))
                                     else d end order by n), '[]'::jsonb)
        from jsonb_array_elements(v_cont->'dias') with ordinality x(d, n)));
  end if;
  return v_cont;
end $$;

-- Pendências de um funcionário no mês ----------------------------------------------------------------------------
create or replace function fn_ponto_folha_pendencias(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_fim   date := (date_trunc('month', p_mes) + interval '1 month')::date - 1;
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_ontem date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_abona boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_res   jsonb := '[]'::jsonb;
  v_dias  int := 0;
  v_dup   date[];
  v_ped   date[];
  a       text;
  t record; r record;
begin
  select coalesce(admissao, created_at::date) as adm, desligado_em into t from tecnicos where id = p_tecnico;
  if not found then return v_res; end if;

  -- pedidos aguardando decisão (e os dias que eles cobrem: lá não é falta injustificada, é pendência). Sem o motivo:
  -- o código de saúde (pré-natal, preventivo...) é dado sensível e a validação é aberta ao papel leitura (decisão 56)
  select coalesce(jsonb_agg(jsonb_build_object('tipo', 'pedido_pendente', 'nivel', 'bloqueia', 'bloqueia', true,
           'data', j.data, 'numero', j.numero) order by j.data, j.numero), '[]'::jsonb),
         coalesce(array_agg(distinct g::date), '{}')
    into v_res, v_ped
    from ponto_justificativas j
    cross join lateral generate_series(j.data, coalesce(j.data_fim, j.data), interval '1 day') g
   where j.tecnico_id = p_tecnico and j.status = 'pendente'
     and j.data <= v_fim and coalesce(j.data_fim, j.data) >= v_mes;
  -- o agregado acima repete o pedido por dia coberto: um item por pedido
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;

  -- marcações duplicadas: o mesmo tipo em seguida no dia, ou duas a menos de 3 min (as desconsideradas não contam)
  with m as (
    select (x.momento at time zone v_fuso) as h, x.tipo from ponto_marcacoes x
     where x.tecnico_id = p_tecnico
       and x.momento >= v_mes::timestamp at time zone v_fuso and x.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.marcacao_id = x.id)
    union all
    select (a.momento at time zone v_fuso), a.tipo from ponto_ajustes a
     where a.tecnico_id = p_tecnico and a.acao = 'incluir'
       and a.momento >= v_mes::timestamp at time zone v_fuso and a.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.ajuste_id = a.id)
  ), o as (
    select h, tipo, lag(h) over (partition by h::date order by h) as h_ant, lag(tipo) over (partition by h::date order by h) as tipo_ant
      from m
  )
  select coalesce(array_agg(distinct h::date), '{}') into v_dup
    from o where h_ant is not null and (tipo = tipo_ant or h - h_ant < interval '3 minutes');

  for r in select g::date as dia, fn_ponto_jornada_dia(p_tecnico, g::date) as j, fn_carga_dia(p_tecnico, g::date) as c
             from generate_series(greatest(v_mes, t.adm), least(v_fim, v_ontem, coalesce(t.desligado_em, v_fim)),
                                  interval '1 day') g loop
    if r.j is not null then
      v_dias := v_dias + 1;
      if r.dia = any(v_dup) then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_duplicada', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      elsif r.j->'alertas' ? 'incompleta' then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_incompleta', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
      foreach a in array array['intervalo_curto', 'sem_intervalo', 'he_acima_limite', 'interjornada_curta'] loop
        if r.j->'alertas' ? a then
          v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', a, 'nivel', 'confirmar', 'bloqueia', false, 'data', r.dia,
                     'intervalo_min', (r.j->>'intervalo_min')::int, 'he_min', (r.j->>'he_min')::int,
                     'interjornada_min', (r.j->>'interjornada_min')::int));
        end if;
      end loop;
      if r.j->>'abono' = 'dia inteiro' and coalesce((r.j->>'marcacoes')::int, 0) > 0 then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'abono_em_dia_trabalhado', 'nivel', 'confirmar', 'bloqueia', false,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
    elsif coalesce((r.c->>'minutos')::int, 0) > 0
      and not (r.dia = any(v_ped))
      and not (r.c->>'tipo' is distinct from '12x36'
               and exists (select 1 from feriados f where f.data = r.dia and f.abrangencia <> 'facultativo'))
      and not (extract(isodow from r.dia) = 6 and r.c->>'escala' is null and v_abona) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'nivel', 'confirmar', 'bloqueia', false,
                 'data', r.dia, 'minutos', (r.c->>'minutos')::int));
    end if;
  end loop;

  -- funcionário sem nenhum registro no mês não entra no fechamento (o espelho não é emitido): não há o que apontar
  if v_dias = 0 and not exists (select 1 from jsonb_array_elements(v_res) x where x->>'tipo' = 'pedido_pendente') then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(x order by x->>'data', x->>'tipo'), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;
  return v_res;
end $$;

-- Painel de validação da folha ---------------------------------------------------------------------------------
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
           'a_confirmar', (select count(*) from jsonb_array_elements(x.p) e where e->>'nivel' = 'confirmar'),
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
                         'ocorrencias_confirmadas', jsonb_array_length(f.ocorrencias_confirmadas))
                    from ponto_folha_fechamentos f where f.tecnico_id = tc.id and f.competencia = v_mes
                   order by f.fechado_em desc limit 1) as fechado
            from tecnicos tc join empresas em on em.id = tc.empresa_id
           where tc.cpf is not null and not tc.perfil_teste
             and coalesce(tc.admissao, tc.created_at::date) <= v_fim
             and (tc.ativo or tc.desligado_em >= v_mes)) x;

  return jsonb_build_object('competencia', v_mes, 'funcionarios', v_res);
end $$;

-- Prévia do espelho, para conferir HE, abonos e débitos antes de fechar (admin e gestor: o espelho tem o CPF) -----
create or replace function app_ponto_previa_folha(p_competencia date, p_tecnico uuid)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_mes   date := date_trunc('month', p_competencia)::date;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'A prévia é de mês já encerrado.';
  end if;
  if not exists (select 1 from tecnicos where id = p_tecnico and cpf is not null and empresa_id is not null) then
    raise exception 'Funcionário não encontrado.';
  end if;
  return jsonb_build_object('conteudo', fn_ponto_folha_conteudo(p_tecnico, v_mes),
                            'pendencias', fn_ponto_folha_pendencias(p_tecnico, v_mes));
end $$;

-- Emissão do espelho: recusa quem tem bloqueio ou ocorrência não confirmada; registra o fechamento ---------------
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
  v_conf_l jsonb;
  v_novo   uuid;
  v_emit   int := 0; v_igual int := 0; v_assin int := 0; v_vazio int := 0; v_pend int := 0; v_conf int := 0;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'O espelho só é emitido para mês já encerrado.';
  end if;
  for t in select tc.id, tc.empresa_id from tecnicos tc join empresas em on em.id = tc.empresa_id
            where tc.cpf is not null and not tc.perfil_teste
              and (p_tecnico is null or tc.id = p_tecnico)
              and coalesce(tc.admissao, tc.created_at::date) <= v_fim
              and (tc.ativo or tc.desligado_em >= v_mes)
            order by tc.nome loop
    select e.id, e.sha256, e.versao, e.assinado_em into v_atual from ponto_espelhos e
     where e.tecnico_id = t.id and e.competencia = v_mes and e.substituido_em is null
       for update;   -- a assinatura espera; e o gatilho não deixa substituir o assinado
    if v_atual.assinado_em is not null then v_assin := v_assin + 1; continue; end if;
    -- bloqueio: a folha desse funcionário não fecha; ocorrência a confirmar: só com a confirmação de quem fecha
    v_p := fn_ponto_folha_pendencias(t.id, v_mes);
    if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
      v_pend := v_pend + 1; continue;
    end if;
    select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_conf_l
      from jsonb_array_elements(v_p) x where x->>'nivel' = 'confirmar';
    if jsonb_array_length(v_conf_l) > 0 and not coalesce(p_confirmar_faltas, false) then
      v_conf := v_conf + 1; continue;
    end if;
    v_cont := fn_ponto_folha_conteudo(t.id, v_mes);
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
    values (t.empresa_id, t.id, v_mes, coalesce(v_atual.versao, 0) + 1, v_reg, fn_ponto_codigo_verificacao(), v_cont, v_cont::text, v_sha, v_email)
    returning id into v_novo;
    -- toda emissão é um fechamento: quem emitiu e as ocorrências que confirmou
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, ocorrencias_confirmadas, fechado_por)
    values (t.empresa_id, t.id, v_mes, v_novo, v_conf_l, v_email);
    v_emit := v_emit + 1;
  end loop;
  return jsonb_build_object('emitidos', v_emit, 'sem_mudanca', v_igual, 'ja_assinados', v_assin, 'sem_dados', v_vazio,
                            'com_pendencia', v_pend, 'a_confirmar', v_conf);
end $$;

-- Fechamento de um funcionário: a confirmação vale para as ocorrências que quem fecha viu (p_ocorrencias_vistas, a
-- quantidade mostrada no painel); se apareceu ocorrência nova desde a validação, devolve para conferir de novo
drop function if exists app_ponto_fechar_folha(date, uuid, boolean);
create or replace function app_ponto_fechar_folha(p_competencia date, p_tecnico uuid, p_confirmar_faltas boolean default false,
                                                  p_ocorrencias_vistas int default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_mes   date := date_trunc('month', p_competencia)::date;
  v_p     jsonb;
  v_conf  jsonb;
  v_r     jsonb;
  v_esp   record;
begin
  if p_tecnico is null then raise exception 'Informe o funcionário.'; end if;
  v_p := fn_ponto_folha_pendencias(p_tecnico, v_mes);
  if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
    return jsonb_build_object('situacao', 'pendente', 'pendencias', v_p);
  end if;
  select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_conf
    from jsonb_array_elements(v_p) x where x->>'nivel' = 'confirmar';
  if jsonb_array_length(v_conf) > 0 and (not coalesce(p_confirmar_faltas, false)
       or (p_ocorrencias_vistas is not null and p_ocorrencias_vistas <> jsonb_array_length(v_conf))) then
    return jsonb_build_object('situacao', 'confirmar', 'ocorrencias', v_conf);
  end if;

  v_r := app_ponto_emitir_espelhos(v_mes, p_tecnico, p_confirmar_faltas);   -- confere o mês encerrado e o papel de novo
  select e.id, e.empresa_id, e.assinado_em into v_esp from ponto_espelhos e
   where e.tecnico_id = p_tecnico and e.competencia = v_mes and e.substituido_em is null;
  if v_esp.id is null then
    return jsonb_build_object('situacao', 'sem_dados');
  end if;
  -- espelho emitido antes da migration 101 (sem registro de fechamento): o fechamento sem mudança registra agora
  if v_esp.assinado_em is null and not exists (select 1 from ponto_folha_fechamentos f where f.espelho_id = v_esp.id) then
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, ocorrencias_confirmadas, fechado_por)
    values (v_esp.empresa_id, p_tecnico, v_mes, v_esp.id, v_conf, v_email);
  end if;
  return jsonb_build_object('situacao', case when v_esp.assinado_em is not null then 'ja_assinado'
                                             when (v_r->>'emitidos')::int > 0 then 'fechado' else 'sem_mudanca' end,
                            'espelho', v_esp.id, 'ocorrencias_confirmadas', jsonb_array_length(v_conf));
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
