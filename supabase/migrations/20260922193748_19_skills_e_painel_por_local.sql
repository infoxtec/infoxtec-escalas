-- 19 | Item 5: habilidades dos tecnicos e requisitos por tipo de atividade
--      Item 3: painel de acompanhamento agrupado por local

create table if not exists habilidades (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null unique,
  categoria      text not null default 'tecnica'
                 check (categoria in ('tecnica','seguranca','habilitacao','outra')),
  exige_validade boolean not null default false,
  descricao      text,
  ativo          boolean not null default true,
  created_at     timestamptz not null default now()
);
alter table habilidades enable row level security;

create table if not exists tecnico_habilidades (
  tecnico_id    uuid not null references tecnicos(id) on delete cascade,
  habilidade_id uuid not null references habilidades(id) on delete cascade,
  nivel         text not null default 'basico' check (nivel in ('basico','intermediario','avancado')),
  validade      date,
  observacao    text,
  atualizado_em timestamptz not null default now(),
  primary key (tecnico_id, habilidade_id)
);
alter table tecnico_habilidades enable row level security;

create table if not exists tipos_atividade (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique, descricao text,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);
alter table tipos_atividade enable row level security;

create table if not exists tipo_atividade_requisitos (
  tipo_id       uuid not null references tipos_atividade(id) on delete cascade,
  habilidade_id uuid not null references habilidades(id) on delete cascade,
  nivel_minimo  text not null default 'basico' check (nivel_minimo in ('basico','intermediario','avancado')),
  primary key (tipo_id, habilidade_id)
);
alter table tipo_atividade_requisitos enable row level security;

alter table escalas add column if not exists tipo_atividade_id uuid references tipos_atividade(id) on delete set null;
create index if not exists idx_escalas_tipo on escalas (tipo_atividade_id);

insert into config (chave, valor, descricao) values
  ('certificacao_aviso_dias',  '30',   'Dias de antecedencia para avisar certificacao vencendo'),
  ('alerta_certificacoes_hora','08:00','Horario do alerta semanal de certificacoes'),
  ('alerta_certificacoes_dow', '1',    'Dia da semana do alerta de certificacoes (ISO: 1=segunda)')
on conflict (chave) do nothing;

create or replace function fn_nivel_valor(p_nivel text)
returns int language sql immutable set search_path = public, extensions as $$
  select case p_nivel when 'avancado' then 3 when 'intermediario' then 2 else 1 end
$$;

create or replace view vw_tecnico_habilidades as
select
  th.tecnico_id, t.nome as tecnico, t.ativo as tecnico_ativo, t.funcao,
  th.habilidade_id, h.nome as habilidade, h.categoria, h.exige_validade,
  th.nivel, fn_nivel_valor(th.nivel) as nivel_valor, th.validade, th.observacao, th.atualizado_em,
  case
    when h.exige_validade and th.validade is null then 'sem_validade'
    when th.validade is null then 'valida'
    when th.validade < (now() at time zone fn_config('fuso'))::date then 'vencida'
    when th.validade < (now() at time zone fn_config('fuso'))::date
         + make_interval(days => coalesce(fn_config_int('certificacao_aviso_dias'), 30)) then 'vencendo'
    else 'valida'
  end as situacao
from tecnico_habilidades th
join tecnicos t on t.id = th.tecnico_id
join habilidades h on h.id = th.habilidade_id;
revoke all on vw_tecnico_habilidades from anon, authenticated;

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
            and v.nivel_valor >= fn_nivel_valor(r.nivel_minimo)
            and v.situacao in ('valida','vencendo'))),
      'faltando', coalesce((
        select jsonb_agg(h.nome || case when v2.situacao = 'vencida' then ' (vencida)'
                                        when v2.situacao = 'sem_validade' then ' (sem validade)'
                                        when v2.tecnico_id is null then ''
                                        else ' (nível abaixo)' end order by h.nome)
        from tipo_atividade_requisitos r
        join habilidades h on h.id = r.habilidade_id
        left join vw_tecnico_habilidades v2 on v2.tecnico_id = t.id and v2.habilidade_id = r.habilidade_id
        where r.tipo_id = p_tipo
          and (v2.tecnico_id is null or v2.nivel_valor < fn_nivel_valor(r.nivel_minimo)
               or v2.situacao not in ('valida','vencendo'))), '[]'::jsonb)
    ) as x from tecnicos t where t.ativo
  ) s
$$;

-- fn_painel_locais: versao final na migration 20

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

  select count(*), string_agg('• ' || tecnico || ' — ' || habilidade ||
           case when situacao = 'vencida' then ' (VENCIDA em ' || to_char(validade,'DD/MM') || ')'
                else ' (vence em ' || to_char(validade,'DD/MM') || ')' end, E'\n' order by validade)
    into v_qtd, v_linhas
  from vw_tecnico_habilidades where tecnico_ativo and situacao in ('vencida','vencendo');

  insert into alertas_enviados (tipo, data_ref, enviado, detalhe)
  values ('certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
  if coalesce(v_qtd,0) = 0 then return; end if;

  perform fn_avisar_supervisores('📋 *CERTIFICAÇÕES A VENCER*' || E'\n\n' || v_linhas || E'\n\n'
    || 'Técnico com certificação vencida não deve ser escalado para atividades que a exigem.');
end $$;

-- Dispatcher: acrescenta a fase 5 (certificacoes) ao corpo da migration 17
create or replace function fn_dispatcher_whatsapp()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_limite int := coalesce(fn_config_int('envios_por_execucao'), 3);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst text := fn_config('evolution_instancia');
begin
  perform set_config('app.ator', 'dispatcher', true);

  for n in select id, escala_id, http_req_id, created_at from notificacoes
           where status_envio = 'enfileirada' and http_req_id is not null loop
    select status_code, content, error_msg into r_resp from net._http_response where id = n.http_req_id;
    if not found then
      if n.created_at < now() - interval '5 minutes' then
        update notificacoes set status_envio = 'falha', erro_codigo = 'timeout',
               erro_mensagem = 'Sem resposta da Evolution em 5 minutos' where id = n.id;
      end if;
      continue;
    end if;
    if r_resp.status_code in (200, 201) then
      begin v_wa_id := (r_resp.content::jsonb) -> 'key' ->> 'id'; exception when others then v_wa_id := null; end;
      update notificacoes set status_envio = 'enviada', wa_message_id = v_wa_id where id = n.id;
      update escalas set status = 'notificada' where id = n.escala_id and status = 'agendada';
    else
      update notificacoes set status_envio = 'falha',
             erro_codigo = coalesce(r_resp.status_code::text, 'rede'),
             erro_mensagem = left(coalesce(r_resp.content, r_resp.error_msg, 'erro desconhecido'), 500)
       where id = n.id;
    end if;
  end loop;

  for a in select * from vw_acoes_pendentes
           where acao in ('enviar_primeira','reenviar_falha','reenviar','nao_recebeu')
           order by enviada_em nulls first loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar','nao_recebeu') then continue; end if;
    v_tent := coalesce(a.tentativa, 0) + 1;
    v_botoes := v_usar_botoes and a.acao <> 'reenviar_falha';
    v_payload := fn_payload_escala(a.escala_id, a.telefone, a.acao = 'reenviar', v_botoes);
    v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
    insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id)
    values (a.escala_id,
      (case when v_tent = 1 then 'primeira' when a.acao = 'reenviar_falha' then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
      v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
      'enfileirada', v_payload, now(), v_req);
    v_sent := v_sent + 1;
  end loop;

  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor) loop
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    for s in select telefone_e164 from tecnicos where is_supervisor and ativo loop
      perform fn_evo_post('/message/sendText/' || v_inst,
                          jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
    end loop;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('diagnostico', a.diagnostico, 'tentativa', a.tentativa));
  end loop;

  begin perform fn_alerta_prazo_escala();
  exception when others then raise warning 'alerta de prazo falhou: %', sqlerrm; end;

  begin perform fn_alerta_certificacoes();
  exception when others then raise warning 'alerta de certificacoes falhou: %', sqlerrm; end;
end $$;

create or replace function app_habilidades()
returns setof habilidades language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from habilidades order by categoria, nome;
end $$;

create or replace function app_salvar_habilidade(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid;
begin
  perform app_exigir(array['admin','gestor']);
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome da habilidade é obrigatório.'; end if;
  if v_id is null then
    insert into habilidades (nome, categoria, exige_validade, descricao, ativo)
    values (trim(p->>'nome'), coalesce(nullif(p->>'categoria',''),'tecnica'),
            coalesce((p->>'exige_validade')::boolean,false), nullif(trim(p->>'descricao'),''),
            coalesce((p->>'ativo')::boolean,true)) returning id into v_id;
  else
    update habilidades set nome = trim(p->>'nome'),
      categoria = coalesce(nullif(p->>'categoria',''),'tecnica'),
      exige_validade = coalesce((p->>'exige_validade')::boolean,false),
      descricao = nullif(trim(p->>'descricao'),''), ativo = coalesce((p->>'ativo')::boolean,true)
    where id = v_id;
    if not found then raise exception 'Habilidade não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Já existe uma habilidade com esse nome.';
end $$;

create or replace function app_tecnico_habilidades()
returns setof vw_tecnico_habilidades language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from vw_tecnico_habilidades order by tecnico, habilidade;
end $$;

create or replace function app_salvar_tecnico_habilidade(p jsonb)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade, observacao)
  values ((p->>'tecnico_id')::uuid, (p->>'habilidade_id')::uuid,
          coalesce(nullif(p->>'nivel',''),'basico'), nullif(p->>'validade','')::date,
          nullif(trim(p->>'observacao'),''))
  on conflict (tecnico_id, habilidade_id) do update
    set nivel = excluded.nivel, validade = excluded.validade,
        observacao = excluded.observacao, atualizado_em = now();
end $$;

create or replace function app_remover_tecnico_habilidade(p_tecnico uuid, p_habilidade uuid)
returns void language plpgsql volatile security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  delete from tecnico_habilidades where tecnico_id = p_tecnico and habilidade_id = p_habilidade;
end $$;

create or replace function app_tipos_atividade()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ta.id, 'nome', ta.nome, 'descricao', ta.descricao, 'ativo', ta.ativo,
      'requisitos', coalesce((
        select jsonb_agg(jsonb_build_object('habilidade_id', r.habilidade_id,
                 'habilidade', h.nome, 'nivel_minimo', r.nivel_minimo) order by h.nome)
        from tipo_atividade_requisitos r join habilidades h on h.id = r.habilidade_id
        where r.tipo_id = ta.id), '[]'::jsonb)
    ) order by ta.nome) from tipos_atividade ta), '[]'::jsonb);
end $$;

create or replace function app_salvar_tipo_atividade(p jsonb)
returns uuid language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_id uuid := nullif(p->>'id','')::uuid; r jsonb;
begin
  perform app_exigir(array['admin','gestor']);
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome do tipo de atividade é obrigatório.'; end if;
  if v_id is null then
    insert into tipos_atividade (nome, descricao, ativo)
    values (trim(p->>'nome'), nullif(trim(p->>'descricao'),''), coalesce((p->>'ativo')::boolean,true))
    returning id into v_id;
  else
    update tipos_atividade set nome = trim(p->>'nome'), descricao = nullif(trim(p->>'descricao'),''),
           ativo = coalesce((p->>'ativo')::boolean,true) where id = v_id;
    if not found then raise exception 'Tipo de atividade não encontrado.'; end if;
  end if;
  delete from tipo_atividade_requisitos where tipo_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p->'requisitos','[]'::jsonb)) loop
    insert into tipo_atividade_requisitos (tipo_id, habilidade_id, nivel_minimo)
    values (v_id, (r->>'habilidade_id')::uuid, coalesce(nullif(r->>'nivel_minimo',''),'basico'))
    on conflict do nothing;
  end loop;
  return v_id;
exception when unique_violation then raise exception 'Já existe um tipo de atividade com esse nome.';
end $$;

create or replace function app_aptidao(p_tipo uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return fn_aptidao(p_tipo);
end $$;

create or replace function app_painel_locais(p_data date)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return fn_painel_locais(p_data);
end $$;

create or replace function app_criar_escalas(
  p_tecnicos uuid[], p_local uuid, p_data date, p_hora time, p_tarefa text,
  p_duracao int default 240, p_prioridade text default 'normal', p_enviar boolean default true,
  p_tipo uuid default null
) returns table (tecnico_id uuid, tecnico text, escala_id uuid, resultado text)
language plpgsql volatile security definer
set search_path = public, extensions as $$
declare v_email text := app_exigir(array['admin','gestor']);
begin
  if coalesce(trim(p_tarefa), '') = '' then raise exception 'Descreva a tarefa.'; end if;
  return query
    with r as (
      select * from fn_criar_escalas_lote(
        v_email, to_jsonb(p_tecnicos)::text, p_local::text, p_data::text,
        to_char(p_hora, 'HH24:MI'), p_tarefa, p_duracao::text,
        coalesce(p_prioridade, 'normal'), p_enviar::text)
    ), upd as (
      update escalas e set tipo_atividade_id = p_tipo
      from r where e.id = r.escala_id and p_tipo is not null returning 1
    )
    select r.tecnico_id, r.tecnico, r.escala_id, r.resultado from r;
end $$;
