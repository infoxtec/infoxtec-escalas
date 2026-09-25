-- 37 | API do painel para o modelo novo: habilidades de um lado, documentos do outro.

drop function if exists app_habilidades_por_tecnico();

create or replace function app_tecnico_habilidades()
returns setof vw_tecnico_habilidades language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from vw_tecnico_habilidades order by tecnico, habilidade;
end $$;

create or replace function app_tipos_documento()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'nome', nome, 'descricao', descricao, 'palavras_chave', palavras_chave,
    'ativo', ativo, 'ordem', ordem) order by ordem, nome) from tipos_documento), '[]'::jsonb);
end $$;

create or replace function app_salvar_tipo_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_id uuid := nullif(p->>'id','')::uuid;
  v_chaves text[] := coalesce((select array_agg(lower(trim(x)))
    from jsonb_array_elements_text(coalesce(p->'palavras_chave','[]'::jsonb)) x where trim(x) <> ''), '{}');
begin
  perform app_exigir(array['admin','gestor']);
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome do documento é obrigatório.'; end if;
  if v_id is null then
    insert into tipos_documento (nome, descricao, palavras_chave, ativo, ordem)
    values (trim(p->>'nome'), nullif(trim(p->>'descricao'),''), v_chaves,
            coalesce((p->>'ativo')::boolean, true), coalesce(nullif(p->>'ordem','')::int, 100))
    returning id into v_id;
  else
    update tipos_documento set nome = trim(p->>'nome'), descricao = nullif(trim(p->>'descricao'),''),
      palavras_chave = v_chaves, ativo = coalesce((p->>'ativo')::boolean, true),
      ordem = coalesce(nullif(p->>'ordem','')::int, ordem) where id = v_id;
    if not found then raise exception 'Tipo de documento não encontrado.'; end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Já existe um documento com esse nome.';
end $$;

create or replace function app_excluir_tipo_documento(p_id uuid, p_forcar boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_nome text; v_tecnicos int; v_tipos int; v_arquivos int;
begin
  perform app_exigir(array['admin','gestor']);
  select nome into v_nome from tipos_documento where id = p_id;
  if not found then raise exception 'Tipo de documento não encontrado.'; end if;
  select count(*) into v_tecnicos from tecnico_documentos where tipo_documento_id = p_id;
  select count(*) into v_tipos    from tipo_atividade_documentos where tipo_documento_id = p_id;
  select count(*) into v_arquivos from documentos where tipo_documento_id = p_id;
  if not p_forcar and (v_tecnicos > 0 or v_tipos > 0 or v_arquivos > 0) then
    raise exception '% está em uso: % técnico(s), % tipo(s) de atividade e % arquivo(s). Confirme para excluir mesmo assim, ou desative.',
      v_nome, v_tecnicos, v_tipos, v_arquivos;
  end if;
  delete from tipos_documento where id = p_id;
  return jsonb_build_object('excluido', true, 'nome', v_nome, 'tecnicos_afetados', v_tecnicos);
end $$;

create or replace function app_documentos_por_tecnico()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'tecnico_id', t.id, 'tecnico', t.nome, 'funcao', t.funcao, 'ativo', t.ativo,
      'perfil_teste', t.perfil_teste,
      'vencidos', (select count(*) from vw_tecnico_documentos v where v.tecnico_id = t.id and v.situacao = 'vencido'),
      'vencendo', (select count(*) from vw_tecnico_documentos v where v.tecnico_id = t.id and v.situacao = 'vencendo'),
      'sem_data', (select count(*) from vw_tecnico_documentos v where v.tecnico_id = t.id and v.situacao = 'sem_data'),
      'documentos', coalesce((
        select jsonb_agg(jsonb_build_object(
          'tipo_documento_id', v.tipo_documento_id, 'documento', v.documento,
          'validade', v.validade, 'situacao', v.situacao, 'documento_id', v.documento_id,
          'arquivos', (select count(*) from documentos d
                       where d.tecnico_id = t.id and d.tipo_documento_id = v.tipo_documento_id))
          order by v.validade nulls first, v.documento)
        from vw_tecnico_documentos v where v.tecnico_id = t.id), '[]'::jsonb)
    ) order by t.ativo desc, t.nome) from tecnicos t), '[]'::jsonb);
end $$;

create or replace function app_definir_documento(p_tecnico uuid, p_tipo uuid, p_validade date,
                                                 p_documento uuid default null)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, documento_id)
  values (p_tecnico, p_tipo, p_validade, p_documento)
  on conflict (tecnico_id, tipo_documento_id) do update
    set validade = excluded.validade,
        documento_id = coalesce(excluded.documento_id, tecnico_documentos.documento_id),
        atualizado_em = now();
end $$;

create or replace function app_remover_documento_tecnico(p_tecnico uuid, p_tipo uuid)
returns void language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  delete from tecnico_documentos where tecnico_id = p_tecnico and tipo_documento_id = p_tipo;
end $$;

create or replace function app_registrar_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid;
  v_tipo uuid := nullif(p->>'tipo_documento_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
  v_origem text := coalesce(nullif(p->>'origem',''), 'storage');
  v_url text := nullif(trim(p->>'url'), '');
begin
  if not exists (select 1 from tecnicos where id = v_tec) then raise exception 'Técnico não encontrado.'; end if;
  if v_origem = 'drive' then
    if v_url is null then raise exception 'Informe o link do documento no Google Drive.'; end if;
    if v_url !~* '^https://(drive|docs)\.google\.com/' then raise exception 'O link precisa ser do Google Drive.'; end if;
  elsif coalesce(trim(p->>'caminho'),'') = '' then
    raise exception 'Caminho do arquivo ausente.';
  end if;

  insert into documentos (tecnico_id, tipo_documento_id, origem, url, caminho, nome_arquivo, mime, tamanho_bytes, validade, enviado_por)
  values (v_tec, v_tipo, v_origem, v_url, nullif(p->>'caminho',''),
          coalesce(nullif(trim(p->>'nome_arquivo'),''), 'documento'), nullif(p->>'mime',''),
          nullif(p->>'tamanho_bytes','')::int, v_validade, v_email)
  returning id into v_id;

  if v_tipo is not null then
    insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, documento_id)
    values (v_tec, v_tipo, v_validade, v_id)
    on conflict (tecnico_id, tipo_documento_id) do update
      set validade = coalesce(excluded.validade, tecnico_documentos.validade),
          documento_id = v_id, atualizado_em = now();
  end if;
  return v_id;
end $$;

create or replace function app_documentos(p_tecnico uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', d.id, 'tecnico_id', d.tecnico_id, 'tecnico', t.nome,
    'tipo_documento_id', d.tipo_documento_id, 'documento', tp.nome,
    'origem', d.origem, 'url', d.url, 'caminho', d.caminho,
    'nome_arquivo', d.nome_arquivo, 'mime', d.mime, 'tamanho_bytes', d.tamanho_bytes,
    'validade', d.validade, 'enviado_por', d.enviado_por, 'created_at', d.created_at)
    order by d.created_at desc)
    from documentos d join tecnicos t on t.id = d.tecnico_id
    left join tipos_documento tp on tp.id = d.tipo_documento_id
    where p_tecnico is null or d.tecnico_id = p_tecnico), '[]'::jsonb);
end $$;

create or replace function app_tipos_atividade()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ta.id, 'nome', ta.nome, 'descricao', ta.descricao, 'ativo', ta.ativo,
      'requisitos', coalesce((
        select jsonb_agg(jsonb_build_object('habilidade_id', r.habilidade_id,
                 'habilidade', h.nome, 'nivel_minimo', r.nivel_minimo) order by h.nome)
        from tipo_atividade_requisitos r join habilidades h on h.id = r.habilidade_id
        where r.tipo_id = ta.id), '[]'::jsonb),
      'documentos', coalesce((
        select jsonb_agg(jsonb_build_object('tipo_documento_id', dr.tipo_documento_id, 'documento', tp.nome) order by tp.nome)
        from tipo_atividade_documentos dr join tipos_documento tp on tp.id = dr.tipo_documento_id
        where dr.tipo_id = ta.id), '[]'::jsonb)
    ) order by ta.nome) from tipos_atividade ta), '[]'::jsonb);
end $$;

create or replace function app_salvar_tipo_atividade(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid; r jsonb;
begin
  perform app_exigir(array['admin','gestor']);
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome do tipo de atividade é obrigatório.'; end if;
  if v_id is null then
    insert into tipos_atividade (nome, descricao, ativo)
    values (trim(p->>'nome'), nullif(trim(p->>'descricao'),''), coalesce((p->>'ativo')::boolean,true))
    returning id into v_id;
  else
    update tipos_atividade set nome = trim(p->>'nome'), descricao = nullif(trim(p->>'descricao'),''),
           ativo = coalesce((p->>'ativo')::boolean,true) where id = v_id;
    if not found then raise exception 'Tipo de atividade não encontrado.'; end if;
  end if;

  delete from tipo_atividade_requisitos where tipo_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p->'requisitos','[]'::jsonb)) loop
    insert into tipo_atividade_requisitos (tipo_id, habilidade_id, nivel_minimo)
    values (v_id, (r->>'habilidade_id')::uuid, coalesce(nullif(r->>'nivel_minimo',''),'basico'))
    on conflict do nothing;
  end loop;

  delete from tipo_atividade_documentos where tipo_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p->'documentos','[]'::jsonb)) loop
    insert into tipo_atividade_documentos (tipo_id, tipo_documento_id)
    values (v_id, (r->>'tipo_documento_id')::uuid) on conflict do nothing;
  end loop;
  return v_id;
exception when unique_violation then raise exception 'Já existe um tipo de atividade com esse nome.';
end $$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
