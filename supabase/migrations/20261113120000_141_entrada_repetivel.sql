-- Multiempresa F8a, entrada do cliente (decisão 129). Criar a conta de novo com os mesmos dados devolve a mesma conta:
-- se o convite ou a rede falharam depois de criar, o painel repete e reenvia o convite, sem "Já existe uma conta". Dado
-- diferente do que foi gravado continua recusado, com a diferença dita. A lista de contas passa a dizer o que falta
-- para cada uma operar (admin, login aceito, sede, canal, empresa, equipe) e o estado do ciclo de vida, que as
-- próximas entregas usam (encerrar, apagar, custódia).

set lock_timeout = '5s';

-- ciclo de vida: 'ativa' é a única que opera; suspensão manual continua sendo ativa = false com estado 'ativa'
alter table interno.contas
  add column estado text not null default 'ativa' check (estado in ('ativa', 'encerrada', 'apagando', 'custodia', 'apagada')),
  add constraint contas_ativa_so_no_estado_ativa check (not ativa or estado = 'ativa');

create or replace function public.app_plataforma_criar_conta(p_nome text, p_admin_email text, p_admin_nome text, p_modulos text[],
                                                             p_uf text default null::text, p_municipio text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text := interno.fn_exigir_plataforma();
  v_nome  text := btrim(p_nome);
  v_email text := lower(btrim(p_admin_email));
  v_uf    text := upper(nullif(btrim(p_uf), ''));
  v_mun   text := nullif(btrim(p_municipio), '');
  v_mods  text[];
  v_id    uuid;
  c       interno.contas;
begin
  if v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if v_mun is not null and v_uf is null then
    raise exception 'Informe a UF da sede junto com o município.';
  end if;
  if length(v_mun) > 120 then
    raise exception 'Município com no máximo 120 caracteres.';
  end if;
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Informe um e-mail válido para o administrador.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;
  select array_agg(distinct m order by m) into v_mods from unnest(p_modulos) m;

  -- repetição: mesma conta, mesmo admin, mesmos módulos e mesma sede devolvem o id, sem gravar nada
  perform pg_advisory_xact_lock(hashtext('criar_conta:' || lower(v_nome)));
  select * into c from interno.contas where lower(btrim(nome)) = lower(v_nome);   -- a mesma expressão do índice único
  if found then
    if c.estado <> 'ativa' then
      raise exception 'Já existe uma conta com este nome, encerrada. Escolha outro nome.';
    end if;
    if not exists (select 1 from interno.conta_membros where conta_id = c.id and email = v_email and papel = 'admin' and ativo) then
      raise exception 'Já existe uma conta com este nome, com outro administrador. Para mudar, use Editar.';
    end if;
    if v_mods is distinct from (select array_agg(modulo order by modulo) from interno.conta_modulos where conta_id = c.id and ativo) then
      raise exception 'Já existe uma conta com este nome, com outros módulos. Para mudar, use Editar.';
    end if;
    if (v_uf is not null or v_mun is not null) and (c.uf is distinct from v_uf or c.municipio is distinct from v_mun) then
      raise exception 'Já existe uma conta com este nome, com outra sede. Para mudar, use Editar.';
    end if;
    return c.id;
  end if;

  begin
    insert into interno.contas (nome, uf, municipio) values (v_nome, v_uf, v_mun) returning id into v_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo) select v_id, m from unnest(v_mods) m;
  insert into interno.conta_membros (conta_id, email, nome, papel, criado_por)
  values (v_id, v_email, nullif(btrim(p_admin_nome), ''), 'admin', v_ator);
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'criar_conta', v_id, jsonb_build_object('nome', v_nome, 'admin', v_email, 'modulos', v_mods));
  return v_id;
end $function$;

-- o que falta para a conta operar: cada item com ok e um detalhe curto (sem dado pessoal além do e-mail do admin)
create or replace function interno.fn_conta_provisionamento(p_conta uuid)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  c        contas;
  v_admins int;
  v_entrou int;
  v_inst   text;
  v_chave  boolean;
  v_ativo  boolean;
  v_estado text;
  v_ponto  boolean;
  v_emp    int;
  v_tec    int;
begin
  select * into c from contas where id = p_conta;
  if not found then return '[]'::jsonb; end if;
  select count(*), count(*) filter (where exists (select 1 from auth.users u where u.email = m.email and u.last_sign_in_at is not null))
    into v_admins, v_entrou
    from conta_membros m where m.conta_id = p_conta and m.ativo and m.papel = 'admin';
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    v_inst := fn_config('evolution_instancia'); v_ativo := v_inst is not null; v_chave := exists (select 1 from vault.secrets where name = 'EVOLUTION_API_KEY');
    select estado into v_estado from evolution_vigia limit 1;
  else
    -- só se a chave existe: o Vault não é decifrado para isso
    select k.instancia, k.ativo, exists (select 1 from vault.secrets s where s.name = k.segredo), k.vig_estado
      into v_inst, v_ativo, v_chave, v_estado
      from conta_canais k where k.conta_id = p_conta;
  end if;
  v_ponto := exists (select 1 from conta_modulos where conta_id = p_conta and modulo = 'ponto' and ativo);
  select count(*) into v_emp from empresas where conta_id = p_conta and ativo and (empregadora or not v_ponto);
  select count(*) into v_tec from tecnicos where conta_id = p_conta and ativo;
  return jsonb_build_array(
    jsonb_build_object('item', 'admin', 'ok', v_admins > 0,
      'detalhe', case when v_admins > 0 then v_admins || ' administrador(es)' else 'nenhum administrador ativo' end),
    jsonb_build_object('item', 'login', 'ok', v_entrou > 0,
      'detalhe', case when v_entrou > 0 then 'administrador já entrou' else 'convite ainda não aceito' end),
    jsonb_build_object('item', 'sede', 'ok', c.uf is not null,
      'detalhe', coalesce(concat_ws(' / ', c.municipio, c.uf), 'sem sede: só feriados nacionais')),
    jsonb_build_object('item', 'canal', 'ok', coalesce(v_ativo and v_chave, false),
      'detalhe', case when v_inst is null then 'sem WhatsApp' when not v_chave then 'instância sem chave'
                      when not v_ativo then 'canal desligado'
                      else v_inst || coalesce(' (' || v_estado || ')', '') end),
    jsonb_build_object('item', 'empresa', 'ok', v_emp > 0,
      'detalhe', case when v_emp > 0 then v_emp || ' empresa(s)' when v_ponto then 'nenhuma empregadora (o ponto precisa)'
                      else 'nenhuma empresa' end),
    jsonb_build_object('item', 'equipe', 'ok', v_tec > 0,
      'detalhe', case when v_tec > 0 then v_tec || ' funcionário(s)' else 'nenhum funcionário' end));
end $function$;

create or replace function public.app_plataforma_contas()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'ativa', c.ativa, 'estado', c.estado, 'criada_em', c.criada_em, 'uf', c.uf, 'municipio', c.municipio,
      'membros', (select count(*) from interno.conta_membros m where m.conta_id = c.id and m.ativo),
      'admins', coalesce((select jsonb_agg(m.email order by m.email) from interno.conta_membros m
                           where m.conta_id = c.id and m.ativo and m.papel = 'admin'), '[]'::jsonb),
      'modulos', coalesce((select jsonb_agg(cm.modulo order by cm.modulo) from interno.conta_modulos cm
                            where cm.conta_id = c.id and cm.ativo), '[]'::jsonb),
      'provisionamento', interno.fn_conta_provisionamento(c.id))
    order by c.criada_em) from interno.contas c), '[]'::jsonb);
end $function$;


do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  execute 'revoke execute on all functions in schema interno from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
