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

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  app_meu_acesso(), app_escalas(date, date), app_resumo(date, date), app_linha_do_tempo(uuid),
  app_tecnicos(), app_locais(), app_pendencias(date), app_config(), app_simular_jornada(time),
  app_criar_escalas(uuid[], uuid, date, time, text, int, text, boolean, uuid),
  app_mudar_status(uuid, text), app_remover_escala(uuid), app_reenviar_escala(uuid),
  app_salvar_tecnico(jsonb), app_excluir_tecnico(uuid), app_salvar_local(jsonb),
  app_usuarios(), app_salvar_usuario(text, text, text, boolean),
  app_habilidades(), app_salvar_habilidade(jsonb), app_tecnico_habilidades(),
  app_salvar_tecnico_habilidade(jsonb), app_remover_tecnico_habilidade(uuid, uuid),
  app_definir_habilidades(uuid, jsonb),
  app_tipos_atividade(), app_salvar_tipo_atividade(jsonb), app_aptidao(uuid),
  app_painel_locais(date)
to authenticated;
