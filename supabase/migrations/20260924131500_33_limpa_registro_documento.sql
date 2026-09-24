-- 33 | Versao final de app_registrar_documento (sem a linha morta da 32)

create or replace function app_registrar_documento(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid; v_tec uuid := (p->>'tecnico_id')::uuid; v_hab uuid := nullif(p->>'habilidade_id','')::uuid;
  v_validade date := nullif(p->>'validade','')::date;
begin
  if coalesce(trim(p->>'caminho'),'') = '' then raise exception 'Caminho do arquivo ausente.'; end if;
  if not exists (select 1 from tecnicos where id = v_tec) then raise exception 'Técnico não encontrado.'; end if;

  insert into documentos (tecnico_id, habilidade_id, caminho, nome_arquivo, mime, tamanho_bytes, validade, enviado_por)
  values (v_tec, v_hab, p->>'caminho', p->>'nome_arquivo', p->>'mime',
          nullif(p->>'tamanho_bytes','')::int, v_validade, v_email)
  returning id into v_id;

  if v_hab is not null and v_validade is not null then
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade)
    values (v_tec, v_hab, 'basico', v_validade)
    on conflict (tecnico_id, habilidade_id) do update set validade = excluded.validade, atualizado_em = now();
  end if;
  return v_id;
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
