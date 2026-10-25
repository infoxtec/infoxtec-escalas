-- 120: multiempresa F2d, família de documentos (docs/multiempresa-f2.md). Documentos dos técnicos, validade por tipo,
-- quadro por técnico e dossiê de conformidade por local passam a ler e alterar só na conta da sessão. O Storage (bucket
-- `documentos`, caminho `<técnico>/<arquivo>`) só deixa ler, gravar e apagar arquivo de técnico da conta, com o papel
-- na conta. Herança de conta (migration 119) também em `documentos`, `tecnico_documentos` e `dossie_geracoes`.
-- Funções recriadas a partir da definição da homologação de 28/10 (md5 do conjunto: 8b0b208a…).

create trigger tg_00_conta before insert on interno.documentos
  for each row execute function interno.fn_herdar_conta('tecnicos', 'tecnico_id');
create trigger tg_00_conta before insert on interno.tecnico_documentos
  for each row execute function interno.fn_herdar_conta('tecnicos', 'tecnico_id');
create trigger tg_00_conta before insert on interno.dossie_geracoes
  for each row execute function interno.fn_herdar_conta('locais', 'local_id');

-- Storage: arquivo de técnico da conta da sessão, papel admin ou gestor na conta e MFA quando obrigatório
create or replace function public.app_pode_gerir_documento(p_nome text)
 returns boolean
 language sql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(fn_papel_na_conta() in ('admin','gestor'), false)
     and (coalesce(fn_config('mfa_obrigatorio'), 'false') <> 'true' or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
     and exists (select 1 from tecnicos t
                  where t.id::text = split_part(coalesce(p_nome, ''), '/', 1) and t.conta_id = fn_conta_atual())
$function$;

drop policy documentos_leitura on storage.objects;
drop policy documentos_escrita on storage.objects;
drop policy documentos_exclusao on storage.objects;
create policy documentos_leitura on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.app_pode_gerir_documento(name));
create policy documentos_escrita on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.app_pode_gerir_documento(name));
create policy documentos_exclusao on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and public.app_pode_gerir_documento(name));

-- quem pode gerir documentos: papel na conta (o painel decide os botões por ela)
create or replace function public.app_pode_gerir_documentos()
 returns boolean
 language sql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce(fn_papel_na_conta() in ('admin','gestor'), false)
     and (coalesce(fn_config('mfa_obrigatorio'), 'false') <> 'true' or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2')
$function$;

create or replace function public.app_definir_documento(p_tecnico uuid, p_tipo uuid, p_validade date, p_documento uuid default null::uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = v_conta) then
    raise exception 'Técnico não encontrado.';
  end if;
  if not exists (select 1 from tipos_documento where id = p_tipo and conta_id = v_conta) then
    raise exception 'Tipo de documento não encontrado.';
  end if;
  if p_documento is not null and not exists (select 1 from documentos where id = p_documento and tecnico_id = p_tecnico) then
    raise exception 'Documento não encontrado.';
  end if;
  insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, documento_id)
  values (p_tecnico, p_tipo, p_validade, p_documento)
  on conflict (tecnico_id, tipo_documento_id) do update
    set validade = excluded.validade,
        documento_id = coalesce(excluded.documento_id, tecnico_documentos.documento_id),
        atualizado_em = now();
end $function$;

create or replace function public.app_documentos(p_tecnico uuid default null::uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', d.id, 'tecnico_id', d.tecnico_id, 'tecnico', t.nome,
    'tipo_documento_id', d.tipo_documento_id, 'documento', tp.nome,
    'caminho', d.caminho,
    'nome_arquivo', d.nome_arquivo, 'mime', d.mime, 'tamanho_bytes', d.tamanho_bytes,
    'validade', d.validade, 'enviado_por', d.enviado_por, 'created_at', d.created_at)
    order by d.created_at desc)
    from documentos d join tecnicos t on t.id = d.tecnico_id
    left join tipos_documento tp on tp.id = d.tipo_documento_id
    where (p_tecnico is null or d.tecnico_id = p_tecnico) and t.conta_id = fn_conta_atual()), '[]'::jsonb);
end $function$;

create or replace function public.app_documentos_por_tecnico()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
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
    ) order by t.ativo desc, t.nome) from tecnicos t where t.conta_id = fn_conta_atual()), '[]'::jsonb);
end $function$;

create or replace function public.app_dossie_local(p_local uuid, p_data date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email  text := app_exigir(array['admin','gestor','leitura']);
  v_aviso  int  := coalesce(fn_config_int('certificacao_aviso_dias'), 30);
  v_local  record;
  v_tecs   jsonb;
  v_id     bigint;
begin
  select l.nome, l.cliente, l.endereco, l.cidade into v_local from locais l
   where l.id = p_local and l.conta_id = fn_conta_atual();
  if not found then raise exception 'Local não encontrado.'; end if;
  if p_data is null then raise exception 'Informe a data.'; end if;

  -- um técnico por linha (várias escalas no dia somam as exigências); documento exigido pela atividade
  with esc as (
    select e.tecnico_id, min(e.hora_inicio) as hora,
           string_agg(distinct ta.nome, ', ') as atividades,
           array_remove(array_agg(distinct tad.tipo_documento_id), null) as exigidos,
           bool_or(e.tipo_atividade_id is null) as sem_atividade
      from escalas e
      left join tipos_atividade ta on ta.id = e.tipo_atividade_id
      left join tipo_atividade_documentos tad on tad.tipo_id = e.tipo_atividade_id
     where e.local_id = p_local and e.data_servico = p_data and not e.teste
       and e.status not in ('cancelada', 'recusada', 'rascunho')
     group by e.tecnico_id
  ), doc as (
    select x.tecnico_id, tp.id as tipo_id, tp.nome, tp.ordem, td.validade,
           case when td.tecnico_id is null then 'nao_cadastrado'
                when td.validade is null then 'sem_data'
                when td.validade < p_data then 'vencido'
                when td.validade < p_data + v_aviso then 'vencendo'
                else 'valido' end as situacao
      from esc x
      cross join lateral unnest(x.exigidos) as req(tipo_id)
      join tipos_documento tp on tp.id = req.tipo_id
      left join tecnico_documentos td on td.tecnico_id = x.tecnico_id and td.tipo_documento_id = req.tipo_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'tecnico', t.nome, 'funcao', t.funcao, 'hora', to_char(x.hora, 'HH24:MI'), 'atividades', x.atividades,
           'sem_atividade', x.sem_atividade,
           'apto', not x.sem_atividade and not exists (select 1 from doc d where d.tecnico_id = x.tecnico_id and d.situacao in ('vencido', 'nao_cadastrado', 'sem_data')),
           'documentos', coalesce((select jsonb_agg(jsonb_build_object('documento', d.nome,
                              'validade', to_char(d.validade, 'DD/MM/YYYY'), 'situacao', d.situacao) order by d.ordem, d.nome)
                            from doc d where d.tecnico_id = x.tecnico_id), '[]'::jsonb))
           order by x.hora, t.nome), '[]'::jsonb)
    into v_tecs
    from esc x join tecnicos t on t.id = x.tecnico_id;

  insert into dossie_geracoes (email, local_id, data, tecnicos)
  values (v_email, p_local, p_data, jsonb_array_length(v_tecs))
  returning id into v_id;

  return jsonb_build_object(
    'registro', v_id, 'gerado_em', to_char(now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'DD/MM/YYYY HH24:MI'),
    'gerado_por', v_email, 'data', to_char(p_data, 'DD/MM/YYYY'), 'aviso_dias', v_aviso,
    'local', jsonb_build_object('nome', v_local.nome, 'cliente', v_local.cliente,
                                'endereco', v_local.endereco, 'cidade', v_local.cidade),
    'tecnicos', v_tecs);
end $function$;

create or replace function public.app_excluir_documento(p_id uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_caminho text;
begin
  perform app_exigir(array['admin','gestor']);
  delete from documentos d where d.id = p_id
     and exists (select 1 from tecnicos t where t.id = d.tecnico_id and t.conta_id = fn_conta_atual())
  returning caminho into v_caminho;
  if not found then raise exception 'Documento não encontrado.'; end if;
  return v_caminho;
end $function$;

create or replace function public.app_registrar_documento(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid;
  v_tipo uuid := nullif(p->>'tipo_documento_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
begin
  if not exists (select 1 from tecnicos where id = v_tec and conta_id = v_conta) then raise exception 'Técnico não encontrado.'; end if;
  if coalesce(trim(p->>'caminho'),'') = '' then
    raise exception 'Caminho do arquivo ausente.';
  end if;
  -- o arquivo fica na pasta do técnico (é o que o Storage confere): registro não aponta para arquivo de outro
  if p->>'caminho' !~ ('^' || v_tec::text || '/[A-Za-z0-9._-]{1,200}$') or p->>'caminho' ~ '\.\.' then
    raise exception 'Caminho do arquivo inválido.';
  end if;
  if v_tipo is not null and not exists (select 1 from tipos_documento where id = v_tipo and conta_id = v_conta) then
    raise exception 'Tipo de documento não encontrado.';
  end if;

  insert into documentos (tecnico_id, tipo_documento_id, caminho, nome_arquivo, mime, tamanho_bytes, validade, enviado_por)
  values (v_tec, v_tipo, nullif(p->>'caminho',''),
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
end $function$;

create or replace function public.app_remover_documento_tecnico(p_tecnico uuid, p_tipo uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor']);
  delete from tecnico_documentos
   where tecnico_id = p_tecnico and tipo_documento_id = p_tipo and conta_id = fn_conta_atual();
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
