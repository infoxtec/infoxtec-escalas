-- Migration 86 (13/10/2026): dossiê de conformidade por local (backlog 100, decisão 79).
-- O que o RH entrega ao cliente tomador: para um local e uma data, cada técnico escalado e a situação, NA
-- DATA DO SERVIÇO, de cada documento que a atividade exige (tipo_atividade_documentos): válido, vence em
-- até 30 dias, vencido, sem data ou não cadastrado. Só a situação — o arquivo nunca é aberto nem citado
-- (LGPD: ASO é dado de saúde). Cada geração fica registrada (quem, local, data, quando). Escala sem tipo
-- de atividade não tem exigência conhecida: o técnico sai pendente ("atividade não informada"), nunca apto.

create table if not exists dossie_geracoes (
  id        bigint generated always as identity primary key,
  email     text not null,
  local_id  uuid not null,
  data      date not null,
  tecnicos  int not null,
  gerado_em timestamptz not null default now()
);
comment on table dossie_geracoes is 'Quem gerou o dossiê de conformidade de qual local e data (backlog 100, decisão 79). Só inclusão.';
alter table dossie_geracoes enable row level security;
create or replace trigger trg_dossie_geracoes_imutavel before update or delete on dossie_geracoes
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_dossie_geracoes_sem_truncate before truncate on dossie_geracoes
  for each statement execute function fn_ponto_imutavel();

create or replace function app_dossie_local(p_local uuid, p_data date)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email  text := app_exigir(array['admin','gestor','leitura']);
  v_aviso  int  := coalesce(fn_config_int('certificacao_aviso_dias'), 30);
  v_local  record;
  v_tecs   jsonb;
  v_id     bigint;
begin
  select l.nome, l.cliente, l.endereco, l.cidade into v_local from locais l where l.id = p_local;
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

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
