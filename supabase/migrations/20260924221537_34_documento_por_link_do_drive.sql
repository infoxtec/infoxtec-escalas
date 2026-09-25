-- 34 | Documento pode estar no Storage privado OU ser um link do Google Drive.
-- Ressalva: no modo Drive, quem controla o acesso e a permissao do proprio Drive,
-- e a retencao de 5 anos passa a ser manual. O painel apenas guarda o vinculo.

alter table documentos add column if not exists origem text not null default 'storage'
  check (origem in ('storage','drive'));
alter table documentos add column if not exists url text;
alter table documentos alter column caminho drop not null;
alter table documentos alter column mime drop not null;
alter table documentos drop constraint if exists documentos_origem_coerente;
alter table documentos add constraint documentos_origem_coerente check (
  (origem = 'storage' and caminho is not null) or (origem = 'drive' and url is not null)
) not valid;

create or replace function app_registrar_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid; v_hab uuid := nullif(p->>'habilidade_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
  v_origem text := coalesce(nullif(p->>'origem',''), 'storage');
  v_url text := nullif(trim(p->>'url'), '');
begin
  if not exists (select 1 from tecnicos where id = v_tec) then raise exception 'Técnico não encontrado.'; end if;
  if v_origem = 'drive' then
    if v_url is null then raise exception 'Informe o link do documento no Google Drive.'; end if;
    if v_url !~* '^https://(drive|docs)\.google\.com/' then
      raise exception 'O link precisa ser do Google Drive (drive.google.com ou docs.google.com).';
    end if;
  elsif coalesce(trim(p->>'caminho'),'') = '' then
    raise exception 'Caminho do arquivo ausente.';
  end if;

  insert into documentos (tecnico_id, habilidade_id, origem, url, caminho, nome_arquivo, mime, tamanho_bytes, validade, enviado_por)
  values (v_tec, v_hab, v_origem, v_url, nullif(p->>'caminho',''),
          coalesce(nullif(trim(p->>'nome_arquivo'),''), 'documento'), nullif(p->>'mime',''),
          nullif(p->>'tamanho_bytes','')::int, v_validade, v_email)
  returning id into v_id;

  if v_hab is not null and v_validade is not null then
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade)
    values (v_tec, v_hab, 'basico', v_validade)
    on conflict (tecnico_id, habilidade_id) do update set validade = excluded.validade, atualizado_em = now();
  end if;
  return v_id;
end $$;

create or replace function app_documentos(p_tecnico uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', d.id, 'tecnico_id', d.tecnico_id, 'tecnico', t.nome,
    'habilidade_id', d.habilidade_id, 'habilidade', h.nome,
    'origem', d.origem, 'url', d.url, 'caminho', d.caminho,
    'nome_arquivo', d.nome_arquivo, 'mime', d.mime, 'tamanho_bytes', d.tamanho_bytes,
    'validade', d.validade, 'ocr_em', d.ocr_em, 'enviado_por', d.enviado_por, 'created_at', d.created_at)
    order by d.created_at desc)
    from documentos d join tecnicos t on t.id = d.tecnico_id
    left join habilidades h on h.id = d.habilidade_id
    where p_tecnico is null or d.tecnico_id = p_tecnico), '[]'::jsonb);
end $$;

create or replace function app_excluir_documento(p_id uuid)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_caminho text; v_origem text;
begin
  perform app_exigir(array['admin','gestor']);
  delete from documentos where id = p_id returning caminho, origem into v_caminho, v_origem;
  if v_origem is null then raise exception 'Documento não encontrado.'; end if;
  return case when v_origem = 'storage' then v_caminho else null end;
end $$;

drop view if exists vw_documentos_expirados;
create view vw_documentos_expirados as
select d.id, d.origem, d.caminho, d.url, d.nome_arquivo, t.nome as tecnico, t.desligado_em,
       (t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5)))::date as expurgar_em
from documentos d join tecnicos t on t.id = d.tecnico_id
where t.desligado_em is not null
  and t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5))
      <= (now() at time zone fn_config('fuso'))::date;
revoke all on vw_documentos_expirados from anon, authenticated;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
