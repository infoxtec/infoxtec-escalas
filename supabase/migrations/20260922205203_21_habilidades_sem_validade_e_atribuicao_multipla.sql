-- 21 | Habilidades sem controle de validade + atribuicao de varias habilidades de uma vez.
-- As colunas de validade continuam existindo (dormentes) para o caso de o controle voltar.

update habilidades set exige_validade = false where exige_validade;
update tecnico_habilidades set validade = null where validade is not null;

update config set valor = '0',
       descricao = 'Dia ISO do alerta de certificacoes. 0 = desligado (controle de validade desativado)'
 where chave = 'alerta_certificacoes_dow';

-- Define de uma vez todas as habilidades do tecnico: o que nao estiver na lista e removido.
-- p_habilidades: [{"habilidade_id": "...", "nivel": "basico|intermediario|avancado"}]
create or replace function app_definir_habilidades(p_tecnico uuid, p_habilidades jsonb)
returns int language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  h jsonb;
  v_ids uuid[] := '{}';
begin
  perform app_exigir(array['admin','gestor']);
  if not exists (select 1 from tecnicos where id = p_tecnico) then
    raise exception 'Técnico não encontrado.';
  end if;

  for h in select * from jsonb_array_elements(coalesce(p_habilidades, '[]'::jsonb)) loop
    v_ids := v_ids || (h->>'habilidade_id')::uuid;
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade, observacao)
    values (p_tecnico, (h->>'habilidade_id')::uuid,
            coalesce(nullif(h->>'nivel',''), 'basico'), null, nullif(trim(h->>'observacao'), ''))
    on conflict (tecnico_id, habilidade_id) do update
      set nivel = excluded.nivel, observacao = excluded.observacao, atualizado_em = now();
  end loop;

  delete from tecnico_habilidades
  where tecnico_id = p_tecnico and not (habilidade_id = any (v_ids));

  return coalesce(array_length(v_ids, 1), 0);
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
