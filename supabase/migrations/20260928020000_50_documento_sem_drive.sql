-- 50 | Fecha o modo Drive: apaga o vinculo, derruba as colunas e limpa o que sobrou no codigo
--
-- A decisao 41 (28/09) descontinuou o vinculo por link do Google Drive, e a migration 49 passou a
-- recusar origem 'drive' em app_registrar_documento. Esta migration completa a limpeza:
--   1. apaga os vinculos existentes (o arquivo no Drive foi removido pelo responsavel em 28/09);
--   2. recria vw_documentos_expirados sem origem e url;
--   3. recria app_documentos, app_excluir_documento e app_registrar_documento sem os dois campos;
--   4. derruba as restricoes que citam origem/url e as colunas documentos.origem e documentos.url.
--
-- Plano de volta: as duas colunas nao carregam informacao — depois do passo 1, url e sempre nula e
-- origem e sempre 'storage'. Para reverter, basta uma migration que faca
--   alter table documentos add column origem text not null default 'storage';
--   alter table documentos add column url text;
-- e recrie as tres funcoes a partir da definicao da migration 49. O backup diario cobre a janela.
--
-- Roda num banco vazio sem erro: o passo 1 nao encontra linha e os demais sao idempotentes.

-- 1. Apaga os vinculos por link ---------------------------------------------------------------

do $$
declare v_vinculos int;
begin
  select count(*) into v_vinculos from documentos where origem = 'drive';
  if v_vinculos > 0 then
    raise notice 'Removendo % vinculo(s) por link do Google Drive', v_vinculos;
    delete from documentos where origem = 'drive';
  else
    raise notice 'Nenhum vinculo por link do Google Drive para remover';
  end if;
end $$;

-- 2. View dos expirados, sem origem e url ------------------------------------------------------
-- A view depende das colunas, entao precisa ser recriada antes do drop.

drop view if exists vw_documentos_expirados;
create view vw_documentos_expirados as
select d.id, d.caminho, d.nome_arquivo, t.nome as tecnico, t.desligado_em,
       (t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5)))::date as expurgar_em
from documentos d join tecnicos t on t.id = d.tecnico_id
where t.desligado_em is not null
  and t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5))
      <= (now() at time zone fn_config('fuso'))::date;
revoke all on vw_documentos_expirados from anon, authenticated;

-- 3. Funcoes -----------------------------------------------------------------------------------

create or replace function app_registrar_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid;
  v_tipo uuid := nullif(p->>'tipo_documento_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
begin
  if not exists (select 1 from tecnicos where id = v_tec) then raise exception 'Técnico não encontrado.'; end if;
  if coalesce(trim(p->>'caminho'),'') = '' then
    raise exception 'Caminho do arquivo ausente.';
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
end $$;

create or replace function app_excluir_documento(p_id uuid)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_caminho text;
begin
  perform app_exigir(array['admin','gestor']);
  delete from documentos where id = p_id returning caminho into v_caminho;
  if not found then raise exception 'Documento não encontrado.'; end if;
  return v_caminho;
end $$;

create or replace function app_documentos(p_tecnico uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
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
    where p_tecnico is null or d.tecnico_id = p_tecnico), '[]'::jsonb);
end $$;

-- 4. Restricoes e colunas ----------------------------------------------------------------------
-- As restricoes saem por nome encontrado no catalogo: assim a migration nao depende de o Postgres
-- ter gerado o nome que a gente espera.

do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'documentos'::regclass and contype = 'c'
              and (pg_get_constraintdef(oid) ilike '%origem%' or pg_get_constraintdef(oid) ilike '%url%')
  loop
    execute format('alter table documentos drop constraint %I', c.conname);
    raise notice 'Restricao removida de documentos: %', c.conname;
  end loop;
end $$;

alter table documentos drop column if exists url;
alter table documentos drop column if exists origem;

-- 5. Permissoes: so as funcoes app_* ficam acessiveis ao usuario logado (decisao 12) -----------

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
