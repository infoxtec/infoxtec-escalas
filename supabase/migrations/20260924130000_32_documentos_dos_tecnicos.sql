-- 32 | Item 10: documentos (NR, CNH, ASO) com armazenamento privado e retencao de 5 anos.
-- Arquivos no Storage do Supabase, criptografados em repouso (AES-256), em bucket privado:
-- sem URL publica; acesso so por link assinado de curta duracao e para admin/gestor.
-- app_registrar_documento recebe a versao final na migration 33.

create table if not exists documentos (
  id            uuid primary key default gen_random_uuid(),
  tecnico_id    uuid not null references tecnicos(id) on delete cascade,
  habilidade_id uuid references habilidades(id) on delete set null,
  caminho       text not null unique,
  nome_arquivo  text not null,
  mime          text not null,
  tamanho_bytes int,
  validade      date,
  ocr_texto     text,
  ocr_em        timestamptz,
  enviado_por   text not null,
  created_at    timestamptz not null default now()
);
alter table documentos enable row level security;
create index if not exists idx_documentos_tecnico on documentos (tecnico_id);

alter table tecnicos add column if not exists desligado_em date;
comment on column tecnicos.desligado_em is 'Data de desligamento: inicia a contagem de retencao dos documentos.';

insert into config (chave, valor, descricao) values
  ('retencao_documentos_anos', '5', 'Anos de guarda dos documentos apos o desligamento do tecnico'),
  ('documento_tamanho_max_mb', '8', 'Tamanho maximo por arquivo enviado')
on conflict (chave) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos', 'documentos', false, 8388608,
        array['application/pdf','image/jpeg','image/jpg','image/png'])
on conflict (id) do update set public = false,
  file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists documentos_leitura on storage.objects;
drop policy if exists documentos_escrita on storage.objects;
drop policy if exists documentos_exclusao on storage.objects;
create policy documentos_leitura on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and fn_papel(auth.jwt() ->> 'email') in ('admin','gestor'));
create policy documentos_escrita on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and fn_papel(auth.jwt() ->> 'email') in ('admin','gestor'));
create policy documentos_exclusao on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and fn_papel(auth.jwt() ->> 'email') in ('admin','gestor'));

create or replace view vw_documentos_expirados as
select d.id, d.caminho, d.nome_arquivo, t.nome as tecnico, t.desligado_em,
       (t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5)))::date as expurgar_em
from documentos d join tecnicos t on t.id = d.tecnico_id
where t.desligado_em is not null
  and t.desligado_em + make_interval(years => coalesce(fn_config_int('retencao_documentos_anos'), 5))
      <= (now() at time zone fn_config('fuso'))::date;

create or replace function app_documentos(p_tecnico uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', d.id, 'tecnico_id', d.tecnico_id, 'tecnico', t.nome,
    'habilidade_id', d.habilidade_id, 'habilidade', h.nome,
    'caminho', d.caminho, 'nome_arquivo', d.nome_arquivo, 'mime', d.mime,
    'tamanho_bytes', d.tamanho_bytes, 'validade', d.validade,
    'ocr_em', d.ocr_em, 'enviado_por', d.enviado_por, 'created_at', d.created_at)
    order by d.created_at desc)
    from documentos d join tecnicos t on t.id = d.tecnico_id
    left join habilidades h on h.id = d.habilidade_id
    where p_tecnico is null or d.tecnico_id = p_tecnico), '[]'::jsonb);
end $$;

create or replace function app_excluir_documento(p_id uuid)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare v_caminho text;
begin
  perform app_exigir(array['admin','gestor']);
  delete from documentos where id = p_id returning caminho into v_caminho;
  if v_caminho is null then raise exception 'Documento não encontrado.'; end if;
  return v_caminho;  -- o painel apaga o arquivo no Storage em seguida
end $$;

create or replace function app_documentos_expirados()
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin']);
  return coalesce((select jsonb_agg(to_jsonb(v)) from vw_documentos_expirados v), '[]'::jsonb);
end $$;
