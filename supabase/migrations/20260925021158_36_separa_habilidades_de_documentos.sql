-- 36 | Habilidade e documento passam a ser coisas diferentes.
--   habilidades      -> o que o tecnico sabe fazer. Nunca vence.
--   tipos_documento  -> NR, CNH, ASO. Vencem e podem bloquear a atividade.
-- Os dados existentes sao migrados; nada e perdido.
-- ATENCAO: o nome real da migration no banco e gerado pelo Supabase; conferir com
--   select version || '_' || name from supabase_migrations.schema_migrations;

create table if not exists tipos_documento (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique, descricao text,
  palavras_chave text[] not null default '{}',
  ativo boolean not null default true, ordem int not null default 100,
  created_at timestamptz not null default now()
);
alter table tipos_documento enable row level security;

create table if not exists tecnico_documentos (
  tecnico_id uuid not null references tecnicos(id) on delete cascade,
  tipo_documento_id uuid not null references tipos_documento(id) on delete cascade,
  validade date, documento_id uuid references documentos(id) on delete set null,
  observacao text, atualizado_em timestamptz not null default now(),
  primary key (tecnico_id, tipo_documento_id)
);
alter table tecnico_documentos enable row level security;

create table if not exists tipo_atividade_documentos (
  tipo_id uuid not null references tipos_atividade(id) on delete cascade,
  tipo_documento_id uuid not null references tipos_documento(id) on delete cascade,
  primary key (tipo_id, tipo_documento_id)
);
alter table tipo_atividade_documentos enable row level security;

alter table documentos add column if not exists tipo_documento_id uuid references tipos_documento(id) on delete set null;

insert into tipos_documento (nome, descricao, palavras_chave, ordem)
select h.nome, h.descricao,
  case
    when h.nome ~* '^NR-' then array[lower(h.nome), lower(replace(h.nome, '-', '')), lower(replace(h.nome, '-', ' '))]
    when h.nome ~* '^CNH'  then array['cnh','habilitacao','habilitação','carteira de motorista']
    when h.nome = 'ASO'    then array['aso','atestado','ocupacional','saude ocupacional','saúde ocupacional']
    else array[lower(h.nome)] end,
  (row_number() over (order by h.nome))::int * 10
from habilidades h where h.exige_validade
on conflict (nome) do nothing;

update tipos_documento set palavras_chave = palavras_chave || array['altura','trabalho em altura']    where nome = 'NR-35';
update tipos_documento set palavras_chave = palavras_chave || array['eletricidade','eletrico','elétrico'] where nome = 'NR-10';
update tipos_documento set palavras_chave = palavras_chave || array['espaco confinado','espaço confinado'] where nome = 'NR-33';
update tipos_documento set palavras_chave = palavras_chave || array['epi']                             where nome = 'NR-6';
update tipos_documento set palavras_chave = palavras_chave || array['maquinas','máquinas']             where nome = 'NR-12';
update tipos_documento set palavras_chave = palavras_chave || array['construcao','construção']         where nome = 'NR-18';
update tipos_documento set palavras_chave = palavras_chave || array['movimentacao','movimentação','transporte'] where nome = 'NR-11';
update tipos_documento set palavras_chave = palavras_chave || array['riscos','pgr']                    where nome = 'NR-1';

insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, observacao, atualizado_em)
select th.tecnico_id, td.id, th.validade, th.observacao, th.atualizado_em
from tecnico_habilidades th
join habilidades h on h.id = th.habilidade_id and h.exige_validade
join tipos_documento td on td.nome = h.nome
on conflict do nothing;

update documentos d set tipo_documento_id = td.id
from habilidades h join tipos_documento td on td.nome = h.nome
where d.habilidade_id = h.id and d.tipo_documento_id is null;

insert into tipo_atividade_documentos (tipo_id, tipo_documento_id)
select r.tipo_id, td.id
from tipo_atividade_requisitos r
join habilidades h on h.id = r.habilidade_id and h.exige_validade
join tipos_documento td on td.nome = h.nome
on conflict do nothing;

drop view if exists vw_tecnico_habilidades cascade;
delete from habilidades where exige_validade;
alter table habilidades drop column if exists exige_validade;
alter table documentos  drop column if exists habilidade_id;

create view vw_tecnico_habilidades as
select th.tecnico_id, t.nome as tecnico, t.ativo as tecnico_ativo, t.funcao,
       th.habilidade_id, h.nome as habilidade, h.categoria,
       th.nivel, fn_nivel_valor(th.nivel) as nivel_valor, th.observacao, th.atualizado_em
from tecnico_habilidades th
join tecnicos t on t.id = th.tecnico_id
join habilidades h on h.id = th.habilidade_id;
revoke all on vw_tecnico_habilidades from anon, authenticated;

create or replace view vw_tecnico_documentos as
select td.tecnico_id, t.nome as tecnico, t.ativo as tecnico_ativo, t.funcao, t.perfil_teste,
       td.tipo_documento_id, tp.nome as documento, td.validade, td.documento_id, td.atualizado_em,
       case
         when td.validade is null then 'sem_data'
         when td.validade < (now() at time zone fn_config('fuso'))::date then 'vencido'
         when td.validade < (now() at time zone fn_config('fuso'))::date
              + make_interval(days => coalesce(fn_config_int('certificacao_aviso_dias'), 30)) then 'vencendo'
         else 'valido' end as situacao
from tecnico_documentos td
join tecnicos t on t.id = td.tecnico_id
join tipos_documento tp on tp.id = td.tipo_documento_id;
revoke all on vw_tecnico_documentos from anon, authenticated;

create or replace function fn_aptidao(p_tipo uuid)
returns jsonb language sql stable set search_path = public, extensions as $$
  select coalesce(jsonb_agg(x order by x->>'nome'), '[]'::jsonb) from (
    select jsonb_build_object(
      'tecnico_id', t.id, 'nome', t.nome,
      'apto', not exists (
          select 1 from tipo_atividade_requisitos r
          where r.tipo_id = p_tipo and not exists (
            select 1 from vw_tecnico_habilidades v
            where v.tecnico_id = t.id and v.habilidade_id = r.habilidade_id
              and v.nivel_valor >= fn_nivel_valor(r.nivel_minimo)))
        and not exists (
          select 1 from tipo_atividade_documentos dr
          where dr.tipo_id = p_tipo and not exists (
            select 1 from vw_tecnico_documentos vd
            where vd.tecnico_id = t.id and vd.tipo_documento_id = dr.tipo_documento_id
              and vd.situacao in ('valido','vencendo'))),
      'faltando', (
        select coalesce(jsonb_agg(item order by item), '[]'::jsonb) from (
          select h.nome || case when v2.tecnico_id is null then '' else ' (nível abaixo)' end as item
          from tipo_atividade_requisitos r
          join habilidades h on h.id = r.habilidade_id
          left join vw_tecnico_habilidades v2 on v2.tecnico_id = t.id and v2.habilidade_id = r.habilidade_id
          where r.tipo_id = p_tipo
            and (v2.tecnico_id is null or v2.nivel_valor < fn_nivel_valor(r.nivel_minimo))
          union all
          select tp.nome || case
                   when vd.tecnico_id is null then ' (não cadastrado)'
                   when vd.situacao = 'vencido' then ' (vencido)'
                   else ' (sem data)' end
          from tipo_atividade_documentos dr
          join tipos_documento tp on tp.id = dr.tipo_documento_id
          left join vw_tecnico_documentos vd on vd.tecnico_id = t.id and vd.tipo_documento_id = dr.tipo_documento_id
          where dr.tipo_id = p_tipo
            and (vd.tecnico_id is null or vd.situacao not in ('valido','vencendo'))
        ) f)
    ) as x from tecnicos t where t.ativo
  ) s
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

  select count(*), string_agg('• ' || tecnico || ' — ' || documento ||
           case when situacao = 'vencido' then ' (VENCIDO em ' || to_char(validade,'DD/MM') || ')'
                when situacao = 'sem_data' then ' (sem data cadastrada)'
                else ' (vence em ' || to_char(validade,'DD/MM') || ')' end, E'\n' order by validade nulls first)
    into v_qtd, v_linhas
  from vw_tecnico_documentos
  where tecnico_ativo and not perfil_teste and situacao in ('vencido','vencendo','sem_data');

  insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
  values ('certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
  if coalesce(v_qtd,0) = 0 then return; end if;

  perform fn_avisar_supervisores('📋 *DOCUMENTOS A VENCER*' || E'\n\n' || v_linhas || E'\n\n'
    || 'Técnico com documento vencido não deve ser escalado para atividades que o exigem.');
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
