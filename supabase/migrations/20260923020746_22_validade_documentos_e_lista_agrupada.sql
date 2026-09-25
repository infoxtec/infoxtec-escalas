-- 22 | Validade volta para NRs, CNH e ASO; exclusao de habilidade;
--      atribuicao em lote com validade; lista agrupada por tecnico; alerta religado.

insert into habilidades (nome, categoria, exige_validade, descricao) values
  ('NR-1',  'seguranca', true, 'Disposições gerais e gerenciamento de riscos ocupacionais'),
  ('NR-6',  'seguranca', true, 'Equipamento de proteção individual (EPI)'),
  ('NR-11', 'seguranca', true, 'Transporte, movimentação, armazenagem e manuseio de materiais'),
  ('NR-12', 'seguranca', true, 'Segurança no trabalho em máquinas e equipamentos'),
  ('NR-18', 'seguranca', true, 'Condições de trabalho na indústria da construção'),
  ('ASO',   'seguranca', true, 'Atestado de Saúde Ocupacional')
on conflict (nome) do nothing;

update habilidades
   set exige_validade = (nome ~* '^NR-' or nome ~* '^CNH' or nome = 'ASO');

update config set valor = '1',
       descricao = 'Dia ISO do alerta de documentos vencidos/vencendo (1 = segunda). 0 desliga.'
 where chave = 'alerta_certificacoes_dow';

-- p_habilidades: [{"habilidade_id":"...","nivel":"basico","validade":"2027-05-30"}]
create or replace function app_definir_habilidades(p_tecnico uuid, p_habilidades jsonb)
returns int language plpgsql volatile security definer
set search_path = public, extensions as $$
declare
  h jsonb; v_ids uuid[] := '{}'; v_exige boolean; v_nome text; v_valid date;
begin
  perform app_exigir(array['admin','gestor']);
  if not exists (select 1 from tecnicos where id = p_tecnico) then
    raise exception 'Técnico não encontrado.';
  end if;

  for h in select * from jsonb_array_elements(coalesce(p_habilidades, '[]'::jsonb)) loop
    select exige_validade, nome into v_exige, v_nome
      from habilidades where id = (h->>'habilidade_id')::uuid;
    if not found then raise exception 'Habilidade não encontrada.'; end if;

    v_valid := nullif(h->>'validade', '')::date;
    if v_exige and v_valid is null then
      raise exception '% exige a data de validade.', v_nome;
    end if;
    if not v_exige then v_valid := null; end if;

    v_ids := v_ids || (h->>'habilidade_id')::uuid;
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade, observacao)
    values (p_tecnico, (h->>'habilidade_id')::uuid,
            coalesce(nullif(h->>'nivel',''), 'basico'), v_valid, nullif(trim(h->>'observacao'), ''))
    on conflict (tecnico_id, habilidade_id) do update
      set nivel = excluded.nivel, validade = excluded.validade,
          observacao = excluded.observacao, atualizado_em = now();
  end loop;

  delete from tecnico_habilidades
  where tecnico_id = p_tecnico and not (habilidade_id = any (v_ids));
  return coalesce(array_length(v_ids, 1), 0);
end $$;

create or replace function app_excluir_habilidade(p_id uuid, p_forcar boolean default false)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_nome text; v_tecnicos int; v_tipos int;
begin
  perform app_exigir(array['admin','gestor']);
  select nome into v_nome from habilidades where id = p_id;
  if not found then raise exception 'Habilidade não encontrada.'; end if;
  select count(*) into v_tecnicos from tecnico_habilidades where habilidade_id = p_id;
  select count(*) into v_tipos    from tipo_atividade_requisitos where habilidade_id = p_id;
  if not p_forcar and (v_tecnicos > 0 or v_tipos > 0) then
    raise exception '% está em uso: % técnico(s) e % tipo(s) de atividade. Confirme para excluir mesmo assim, ou desative a habilidade.',
      v_nome, v_tecnicos, v_tipos;
  end if;
  delete from habilidades where id = p_id;
  return jsonb_build_object('excluida', true, 'nome', v_nome,
                            'tecnicos_afetados', v_tecnicos, 'tipos_afetados', v_tipos);
end $$;

create or replace function app_habilidades_por_tecnico()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'tecnico_id', t.id, 'tecnico', t.nome, 'funcao', t.funcao, 'equipe', t.equipe, 'ativo', t.ativo,
      'total', (select count(*) from tecnico_habilidades th where th.tecnico_id = t.id),
      'vencidos', (select count(*) from vw_tecnico_habilidades v where v.tecnico_id = t.id and v.situacao = 'vencida'),
      'vencendo', (select count(*) from vw_tecnico_habilidades v where v.tecnico_id = t.id and v.situacao = 'vencendo'),
      'sem_data', (select count(*) from vw_tecnico_habilidades v where v.tecnico_id = t.id and v.situacao = 'sem_validade'),
      'habilidades', coalesce((
        select jsonb_agg(jsonb_build_object(
          'habilidade_id', v.habilidade_id, 'habilidade', v.habilidade, 'categoria', v.categoria,
          'exige_validade', v.exige_validade, 'nivel', v.nivel, 'validade', v.validade,
          'situacao', v.situacao, 'observacao', v.observacao)
          order by v.exige_validade desc, v.validade nulls last, v.habilidade)
        from vw_tecnico_habilidades v where v.tecnico_id = t.id), '[]'::jsonb)
    ) order by t.ativo desc, t.nome)
    from tecnicos t), '[]'::jsonb);
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
