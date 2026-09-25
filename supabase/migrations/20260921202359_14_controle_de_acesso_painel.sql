-- 14 | Controle de acesso do painel
-- Autenticacao (usuario e senha) = login do Retool. Autorizacao = tabela painel_usuarios.
--   admin   : tudo, inclusive excluir tecnicos e gerenciar usuarios do painel
--   gestor  : criar escalas, mudar status, editar tecnicos e locais
--   leitura : so visualiza

create table if not exists painel_usuarios (
  email      text primary key check (email = lower(trim(email)) and email like '%@%'),
  nome       text,
  papel      text not null check (papel in ('admin', 'gestor', 'leitura')),
  ativo      boolean not null default true,
  criado_por text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table painel_usuarios enable row level security;

insert into painel_usuarios (email, nome, papel, criado_por)
values ('david.cerqueira@infoxtec.com.br', 'David Cerqueira', 'admin', 'setup')
on conflict (email) do nothing;

create or replace function fn_papel(p_email text)
returns text language sql stable
set search_path = public, extensions as $$
  select papel from painel_usuarios where email = lower(trim(p_email)) and ativo
$$;

create or replace function fn_exigir_papel(p_email text, p_papeis text[])
returns void language plpgsql stable
set search_path = public, extensions as $$
begin
  if coalesce(fn_papel(p_email), '') <> all (p_papeis) then
    raise exception 'Sem permissão para esta ação.';
  end if;
end $$;

create or replace function fn_salvar_usuario_painel(
  p_ator text, p_email text, p_nome text, p_papel text, p_ativo text default 'true'
) returns text
language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_email text := lower(trim(p_email));
  v_ativo boolean := coalesce(nullif(p_ativo, ''), 'true')::boolean;
begin
  perform fn_exigir_papel(p_ator, array['admin']);

  if (p_papel <> 'admin' or not v_ativo)
     and exists (select 1 from painel_usuarios where email = v_email and papel = 'admin' and ativo)
     and (select count(*) from painel_usuarios where papel = 'admin' and ativo) = 1 then
    raise exception 'Este é o único administrador ativo. Cadastre outro administrador antes.';
  end if;

  insert into painel_usuarios (email, nome, papel, ativo, criado_por)
  values (v_email, nullif(trim(p_nome), ''), p_papel, v_ativo, lower(p_ator))
  on conflict (email) do update
     set nome = excluded.nome, papel = excluded.papel,
         ativo = excluded.ativo, updated_at = now();

  return v_email;
end $$;

-- Travas de papel nas funcoes que alteram dados
create or replace function fn_criar_escala(
  p_ator text, p_tecnico_id text, p_local_id text, p_data text, p_hora text, p_tarefa text,
  p_duracao_min text default '240', p_prioridade text default 'normal', p_enviar text default 'true'
) returns uuid
language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_id uuid;
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  perform set_config('app.ator', coalesce(nullif(p_ator, ''), 'painel'), false);

  insert into escalas (
    tecnico_id, local_id, data_servico, hora_inicio,
    duracao_prevista_min, descricao_tarefa, prioridade, status, criado_por
  ) values (
    p_tecnico_id::uuid,
    nullif(p_local_id, '')::uuid,
    p_data::date,
    p_hora::time,
    coalesce(nullif(p_duracao_min, '')::int, 240),
    p_tarefa,
    coalesce(nullif(p_prioridade, ''), 'normal'),
    case when p_enviar::boolean then 'agendada'::escala_status else 'rascunho'::escala_status end,
    coalesce(nullif(p_ator, ''), 'painel')
  )
  returning id into v_id;
  return v_id;
end $$;

create or replace function fn_mudar_status(p_ator text, p_escala_id text, p_status text)
returns text
language plpgsql volatile
set search_path = public, extensions as $$
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);
  perform set_config('app.ator', coalesce(nullif(p_ator, ''), 'painel'), false);
  update escalas set status = p_status::escala_status where id = p_escala_id::uuid;
  if not found then
    raise exception 'Escala % nao encontrada', p_escala_id;
  end if;
  return p_status;
end $$;

create or replace function fn_excluir_tecnico(p_ator text, p_tecnico_id text)
returns jsonb
language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_id      uuid := p_tecnico_id::uuid;
  v_ator    text := coalesce(nullif(p_ator, ''), 'painel');
  v_sup     boolean;
  v_outros  int;
  v_abertas int;
  v_total   int;
  v_hoje    date := (now() at time zone fn_config('fuso'))::date;
begin
  perform fn_exigir_papel(p_ator, array['admin']);
  perform set_config('app.ator', v_ator, false);

  select is_supervisor into v_sup from tecnicos where id = v_id;
  if not found then
    raise exception 'Técnico não encontrado.';
  end if;

  if v_sup then
    select count(*) into v_outros from tecnicos where is_supervisor and ativo and id <> v_id;
    if v_outros = 0 then
      raise exception 'Não é possível excluir o único supervisor ativo. Cadastre outro supervisor antes.';
    end if;
  end if;

  select count(*) into v_abertas
  from escalas
  where tecnico_id = v_id and data_servico >= v_hoje
    and status in ('agendada', 'notificada', 'confirmada', 'reagendada', 'em_execucao');
  if v_abertas > 0 then
    raise exception 'Este técnico tem % escala(s) em aberto a partir de hoje. Cancele ou conclua antes de excluir.', v_abertas;
  end if;

  select count(*) into v_total from escalas where tecnico_id = v_id;
  delete from escalas  where tecnico_id = v_id;
  delete from tecnicos where id = v_id;

  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values ('tecnico', v_id, v_ator, v_total);

  return jsonb_build_object('excluido', true, 'escalas_removidas', v_total);
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
