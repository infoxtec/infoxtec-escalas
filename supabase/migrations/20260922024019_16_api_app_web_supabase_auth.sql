-- 16 | API do app web (React no Vercel) com Supabase Auth.
-- O usuario vem do token de login (auth.jwt), nunca de parametro da tela.
-- Todas as funcoes: SECURITY DEFINER, papel conferido, EXECUTE so para authenticated.

create or replace function app_email()
returns text language sql stable
set search_path = public, extensions as $$
  select lower(nullif(auth.jwt() ->> 'email', ''))
$$;

create or replace function app_exigir(p_papeis text[])
returns text language plpgsql stable
set search_path = public, extensions as $$
declare
  v_email text := app_email();
begin
  if v_email is null then
    raise exception 'Sessão expirada. Entre novamente.';
  end if;
  perform fn_exigir_papel(v_email, p_papeis);
  return v_email;
end $$;

create or replace function app_meu_acesso()
returns jsonb language sql stable security definer
set search_path = public, extensions as $$
  select jsonb_build_object(
    'email', app_email(),
    'papel', (select papel from painel_usuarios where email = app_email() and ativo),
    'nome',  (select nome  from painel_usuarios where email = app_email())
  )
$$;

create or replace function app_escalas(p_inicio date, p_fim date)
returns setof vw_escalas_painel language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select * from vw_escalas_painel
    where data_servico between p_inicio and p_fim
    order by data_servico, hora_inicio;
end $$;

create or replace function app_resumo(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
declare
  v jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select jsonb_build_object(
    'total',        count(*),
    'confirmadas',  count(*) filter (where status = 'confirmada'),
    'recusadas',    count(*) filter (where status = 'recusada'),
    'aguardando',   count(*) filter (where status = 'notificada'),
    'nao_enviadas', count(*) filter (where status = 'agendada'),
    'criticas',     count(*) filter (where supervisor_avisado_em is not null),
    'pct_confirmacao', coalesce(round(100.0 * count(*) filter (where status = 'confirmada')
                        / nullif(count(*) filter (where status <> 'rascunho'), 0)), 0)
  ) into v
  from escalas
  where data_servico between p_inicio and p_fim and status <> 'cancelada';
  return v;
end $$;

create or replace function app_linha_do_tempo(p_escala uuid)
returns setof vw_linha_do_tempo language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select * from vw_linha_do_tempo where escala_id = p_escala order by created_at desc;
end $$;

create or replace function app_tecnicos()
returns setof tecnicos language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from tecnicos order by nome;
end $$;

create or replace function app_locais()
returns setof locais language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from locais order by nome;
end $$;

create or replace function app_criar_escalas(
  p_tecnicos uuid[], p_local uuid, p_data date, p_hora time, p_tarefa text,
  p_duracao int default 240, p_prioridade text default 'normal', p_enviar boolean default true
) returns table (tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if coalesce(trim(p_tarefa), '') = '' then
    raise exception 'Descreva a tarefa.';
  end if;
  return query
    select * from fn_criar_escalas_lote(
      v_email, to_jsonb(p_tecnicos)::text, p_local::text, p_data::text,
      to_char(p_hora, 'HH24:MI'), p_tarefa, p_duracao::text,
      coalesce(p_prioridade, 'normal'), p_enviar::text);
end $$;

create or replace function app_mudar_status(p_escala uuid, p_status text)
returns text language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  return fn_mudar_status(app_exigir(array['admin','gestor']), p_escala::text, p_status);
end $$;

create or replace function app_remover_escala(p_escala uuid)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  return fn_remover_escala(app_exigir(array['admin','gestor']), p_escala::text);
end $$;

-- Reenvio real: dispara agora, com botoes, como nova tentativa.
create or replace function app_reenviar_escala(p_escala uuid)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_esc     record;
  v_tent    int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
begin
  select e.id, e.status, t.telefone_e164, t.ativo, t.opt_in
    into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.id = p_escala;

  if not found then raise exception 'Escala não encontrada.'; end if;
  if v_esc.status not in ('agendada', 'notificada') then
    raise exception 'Só é possível reenviar escalas agendadas ou aguardando resposta.';
  end if;
  if not v_esc.ativo or not v_esc.opt_in then
    raise exception 'O técnico está inativo ou sem autorização para mensagens.';
  end if;
  if exists (select 1 from notificacoes where escala_id = p_escala and status_envio = 'enfileirada') then
    raise exception 'Já existe um envio em andamento para esta escala. Aguarde um minuto.';
  end if;

  select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = p_escala;
  v_payload := fn_payload_escala(p_escala, v_esc.telefone_e164, v_tent > 1, v_botoes);
  v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');

  insert into notificacoes
    (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
  values
    (p_escala, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo,
     v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
     'enfileirada', v_payload, now(), v_req);

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'reenvio_manual', v_email, jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('reenviada', true, 'tentativa', v_tent);
end $$;

create or replace function app_salvar_tecnico(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_tel    text := regexp_replace(coalesce(p->>'telefone_e164', ''), '\D', '', 'g');
  v_opt    boolean := coalesce((p->>'opt_in')::boolean, false);
  v_optant boolean;
begin
  if coalesce(trim(p->>'nome'), '') = ''   then raise exception 'Nome é obrigatório.'; end if;
  if coalesce(trim(p->>'funcao'), '') = '' then raise exception 'Função é obrigatória.'; end if;
  if v_tel !~ '^[1-9][0-9]{9,14}$' then
    raise exception 'Telefone inválido: use somente dígitos com código do país. Ex: 5571981776307';
  end if;

  if v_id is null then
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, opt_in_em, ativo)
    values (trim(p->>'nome'), v_tel, trim(p->>'funcao'), nullif(trim(p->>'equipe'), ''),
            coalesce((p->>'is_supervisor')::boolean, false), v_opt,
            case when v_opt then now() end, coalesce((p->>'ativo')::boolean, true))
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
      ativo = coalesce((p->>'ativo')::boolean, true)
    where id = v_id;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe um técnico com este telefone.';
end $$;

create or replace function app_excluir_tecnico(p_tecnico uuid)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  return fn_excluir_tecnico(app_exigir(array['admin']), p_tecnico::text);
end $$;

create or replace function app_salvar_local(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;

  if v_id is null then
    insert into locais (nome, cliente, endereco, cidade, referencia, link_maps, contato_local, telefone_contato, ativo)
    values (trim(p->>'nome'), nullif(trim(p->>'cliente'), ''), nullif(trim(p->>'endereco'), ''),
            coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'), nullif(trim(p->>'referencia'), ''),
            nullif(trim(p->>'link_maps'), ''), nullif(trim(p->>'contato_local'), ''),
            nullif(trim(p->>'telefone_contato'), ''), coalesce((p->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update locais set
      nome = trim(p->>'nome'), cliente = nullif(trim(p->>'cliente'), ''),
      endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      referencia = nullif(trim(p->>'referencia'), ''), link_maps = nullif(trim(p->>'link_maps'), ''),
      contato_local = nullif(trim(p->>'contato_local'), ''),
      telefone_contato = nullif(trim(p->>'telefone_contato'), ''),
      ativo = coalesce((p->>'ativo')::boolean, true)
    where id = v_id;
    if not found then raise exception 'Local não encontrado.'; end if;
  end if;
  return v_id;
end $$;

create or replace function app_usuarios()
returns setof painel_usuarios language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin']);
  return query select * from painel_usuarios order by coalesce(nome, email);
end $$;

create or replace function app_salvar_usuario(p_email text, p_nome text, p_papel text, p_ativo boolean)
returns text language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  return fn_salvar_usuario_painel(app_exigir(array['admin']), p_email, p_nome, p_papel, p_ativo::text);
end $$;

-- Permissoes por laco: toda funcao app_* fica executavel por usuario logado.
-- Lista fixa de assinaturas quebra quando a assinatura muda ao longo do historico.
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
