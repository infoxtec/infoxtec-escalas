-- 29 | Item 11: tecnico com perfil de teste.
-- Continua recebendo mensagens e ligacoes manuais (e para isso que serve),
-- mas sai das pendencias, dos indicadores, dos alertas e das ligacoes automaticas.

alter table tecnicos add column if not exists perfil_teste boolean not null default false;
comment on column tecnicos.perfil_teste is
  'Tecnico de homologacao: fora do painel de pendencias, dos indicadores, dos alertas e das ligacoes automaticas.';

create or replace function fn_pendencias_escala(p_data date)
returns jsonb language sql stable set search_path = public, extensions as $$
  with alvo as (
    select t.id, t.nome, t.funcao from tecnicos t
    where t.ativo and not t.perfil_teste
      and (coalesce(fn_config('sem_escala_incluir_supervisores'), 'false')::boolean or not t.is_supervisor)
  ),
  sem as (
    select a.* from alvo a
    where not exists (select 1 from escalas e
                      where e.tecnico_id = a.id and e.data_servico = p_data and e.status <> 'cancelada')
  )
  select jsonb_build_object(
    'data', p_data,
    'total_tecnicos', (select count(*) from alvo),
    'sem_escala', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'funcao', funcao) order by nome) from sem), '[]'::jsonb),
    'rascunhos', (select count(*) from escalas where data_servico = p_data and status = 'rascunho'),
    'prazo', fn_config('alerta_escala_prazo'),
    'exige_escala', extract(isodow from p_data)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))
  )
$$;

create or replace function fn_alerta_certificacoes()
returns void language plpgsql volatile set search_path = public, extensions as $$
declare
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_hoje date := (now() at time zone fn_config('fuso'))::date;
  v_hora time := coalesce(fn_config('alerta_certificacoes_hora')::time, '08:00');
  v_linhas text; v_qtd int;
begin
  if extract(isodow from v_hoje)::text <> coalesce(fn_config('alerta_certificacoes_dow'), '1') then return; end if;
  if v_agora::time < v_hora or v_agora::time > v_hora + interval '2 hours' then return; end if;
  if exists (select 1 from alertas_enviados where tipo = 'certificacoes' and data_ref = v_hoje) then return; end if;

  select count(*), string_agg('• ' || v.tecnico || ' — ' || v.habilidade ||
           case when v.situacao = 'vencida' then ' (VENCIDA em ' || to_char(v.validade,'DD/MM') || ')'
                else ' (vence em ' || to_char(v.validade,'DD/MM') || ')' end, E'\n' order by v.validade)
    into v_qtd, v_linhas
  from vw_tecnico_habilidades v join tecnicos t on t.id = v.tecnico_id
  where v.tecnico_ativo and not t.perfil_teste and v.situacao in ('vencida','vencendo');

  insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
  values ('certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
  if coalesce(v_qtd,0) = 0 then return; end if;

  perform fn_avisar_supervisores('📋 *CERTIFICAÇÕES A VENCER*' || E'\n\n' || v_linhas || E'\n\n'
    || 'Técnico com certificação vencida não deve ser escalado para atividades que a exigem.');
end $$;

create or replace view vw_ligacoes_pendentes as
with agora as (select (now() at time zone fn_config('fuso')) as local_ts)
select
  e.id as escala_id, t.id as tecnico_id, t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(n.tentativa, 0) as tentativas_whatsapp,
  (select count(*) from ligacoes l where l.escala_id = e.id) as ligacoes_feitas
from escalas e
join tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in and not t.perfil_teste
left join lateral (select * from notificacoes where escala_id = e.id order by created_at desc limit 1) n on true
cross join agora g
where e.status = 'notificada'
  and (e.data_servico + e.hora_inicio) > now()
  and coalesce(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas')
  and n.status_envio in ('enviada','entregue','lida')
  and not exists (select 1 from respostas r where r.escala_id = e.id)
  and (select count(*) from ligacoes l where l.escala_id = e.id) < fn_config_int('ligacao_max_por_escala')
  and not exists (select 1 from ligacoes l where l.escala_id = e.id
                    and (l.status in ('criada','discando')
                         or l.criada_em > now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'))))
  and g.local_ts::time between fn_config('ligacao_janela_inicio')::time and fn_config('ligacao_janela_fim')::time;

create or replace function app_resumo(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
declare v jsonb;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select jsonb_build_object(
    'total', count(*),
    'confirmadas', count(*) filter (where e.status = 'confirmada'),
    'recusadas', count(*) filter (where e.status = 'recusada'),
    'aguardando', count(*) filter (where e.status = 'notificada'),
    'nao_enviadas', count(*) filter (where e.status = 'agendada'),
    'criticas', count(*) filter (where e.supervisor_avisado_em is not null),
    'pct_confirmacao', coalesce(round(100.0 * count(*) filter (where e.status = 'confirmada')
                        / nullif(count(*) filter (where e.status <> 'rascunho'), 0)), 0)
  ) into v
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.data_servico between p_inicio and p_fim and e.status <> 'cancelada' and not t.perfil_teste;
  return v;
end $$;

create or replace function app_salvar_tecnico(p jsonb)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_tel text := regexp_replace(coalesce(p->>'telefone_e164', ''), '\D', '', 'g');
  v_opt boolean := coalesce((p->>'opt_in')::boolean, false);
  v_optant boolean;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if coalesce(trim(p->>'funcao'), '') = '' then raise exception 'Função é obrigatória.'; end if;
  if v_tel !~ '^[1-9][0-9]{9,14}$' then
    raise exception 'Telefone inválido: use somente dígitos com código do país. Ex: 5571981776307';
  end if;

  if v_id is null then
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, opt_in_em, ativo, perfil_teste)
    values (trim(p->>'nome'), v_tel, trim(p->>'funcao'), nullif(trim(p->>'equipe'), ''),
            coalesce((p->>'is_supervisor')::boolean, false), v_opt,
            case when v_opt then now() end, coalesce((p->>'ativo')::boolean, true),
            coalesce((p->>'perfil_teste')::boolean, false))
    returning id into v_id;
  else
    select opt_in into v_optant from tecnicos where id = v_id;
    if not found then raise exception 'Técnico não encontrado.'; end if;
    update tecnicos set
      nome = trim(p->>'nome'), telefone_e164 = v_tel, funcao = trim(p->>'funcao'),
      equipe = nullif(trim(p->>'equipe'), ''),
      is_supervisor = coalesce((p->>'is_supervisor')::boolean, false),
      opt_in = v_opt,
      opt_in_em = case when v_opt and not v_optant then now() else opt_in_em end,
      ativo = coalesce((p->>'ativo')::boolean, true),
      perfil_teste = coalesce((p->>'perfil_teste')::boolean, false)
    where id = v_id;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe um técnico com este telefone.';
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
