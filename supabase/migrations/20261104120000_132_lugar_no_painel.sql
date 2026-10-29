-- Multiempresa F4b: lugar no painel. UF do local (padrão: a sede da conta, no lugar do "Salvador" fixo), sede da
-- conta (UF e município) na tela Contas e cadastro de feriados estaduais e municipais pela plataforma.

set lock_timeout = '5s';

-- locais já cadastrados na cidade da sede da conta recebem a UF dela (os outros caem no funcionário, 131)
update interno.locais l set uf = c.uf
  from interno.contas c
 where c.id = l.conta_id and l.uf is null and c.uf is not null
   and interno.fn_norm_lugar(l.cidade) = interno.fn_norm_lugar(c.municipio);


CREATE OR REPLACE FUNCTION public.app_salvar_local(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_lat   numeric := nullif(p->>'latitude', '')::numeric;
  v_lng   numeric := nullif(p->>'longitude', '')::numeric;
  v_cli   uuid := nullif(p->>'cliente_empresa_id', '')::uuid;
begin
  if nullif(trim(p->>'uf'), '') is not null and upper(trim(p->>'uf')) !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Informe latitude e longitude juntas.'; end if;
  if nullif(trim(p->>'link_maps'), '') !~* '^https?://' then
    raise exception 'Link do Google Maps inválido: precisa começar com https://';
  end if;
  if v_cli is not null and not exists (select 1 from empresas where id = v_cli and conta_id = v_conta) then
    raise exception 'Empresa não encontrada.';
  end if;

  if v_id is null then
    insert into locais (nome, cliente, endereco, cidade, uf, referencia, link_maps, contato_local, telefone_contato, ativo,
                        latitude, longitude, raio_m, cliente_empresa_id, conta_id)
    values (trim(p->>'nome'), nullif(trim(p->>'cliente'), ''), nullif(trim(p->>'endereco'), ''),
            coalesce(nullif(trim(p->>'cidade'), ''), (select municipio from contas where id = v_conta)),
            coalesce(upper(nullif(trim(p->>'uf'), '')), (select uf from contas where id = v_conta)), nullif(trim(p->>'referencia'), ''),
            nullif(trim(p->>'link_maps'), ''), nullif(trim(p->>'contato_local'), ''),
            nullif(trim(p->>'telefone_contato'), ''), coalesce((p->>'ativo')::boolean, true),
            v_lat, v_lng, coalesce(nullif(p->>'raio_m', '')::int, 200), v_cli, v_conta)
    returning id into v_id;
  else
    update locais set
      nome = trim(p->>'nome'), cliente = nullif(trim(p->>'cliente'), ''),
      endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), (select municipio from contas where id = v_conta)),
      uf     = case when p ? 'uf' then upper(nullif(trim(p->>'uf'), '')) else uf end,
      referencia = nullif(trim(p->>'referencia'), ''), link_maps = nullif(trim(p->>'link_maps'), ''),
      contato_local = nullif(trim(p->>'contato_local'), ''),
      telefone_contato = nullif(trim(p->>'telefone_contato'), ''),
      ativo = coalesce((p->>'ativo')::boolean, true),
      latitude  = case when p ? 'latitude'  then v_lat else latitude end,
      longitude = case when p ? 'longitude' then v_lng else longitude end,
      raio_m    = case when p ? 'raio_m' then coalesce(nullif(p->>'raio_m', '')::int, 200) else raio_m end,
      cliente_empresa_id = case when p ? 'cliente_empresa_id' then v_cli else cliente_empresa_id end
    where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Local não encontrado.'; end if;
  end if;
  return v_id;
end $function$
;


CREATE OR REPLACE FUNCTION public.app_plataforma_contas()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'ativa', c.ativa, 'criada_em', c.criada_em, 'uf', c.uf, 'municipio', c.municipio,
      'membros', (select count(*) from interno.conta_membros m where m.conta_id = c.id and m.ativo),
      'admins', coalesce((select jsonb_agg(m.email order by m.email) from interno.conta_membros m
                           where m.conta_id = c.id and m.ativo and m.papel = 'admin'), '[]'::jsonb),
      'modulos', coalesce((select jsonb_agg(cm.modulo order by cm.modulo) from interno.conta_modulos cm
                            where cm.conta_id = c.id and cm.ativo), '[]'::jsonb))
    order by c.criada_em) from interno.contas c), '[]'::jsonb);
end $function$
;


drop function public.app_plataforma_criar_conta(text, text, text, text[]);
CREATE OR REPLACE FUNCTION public.app_plataforma_criar_conta(p_nome text, p_admin_email text, p_admin_nome text, p_modulos text[], p_uf text DEFAULT NULL::text, p_municipio text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ator  text := interno.fn_exigir_plataforma();
  v_nome  text := btrim(p_nome);
  v_email text := lower(btrim(p_admin_email));
  v_id    uuid;
begin
  if nullif(btrim(p_uf), '') is not null and upper(btrim(p_uf)) !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if nullif(btrim(p_municipio), '') is not null and nullif(btrim(p_uf), '') is null then
    raise exception 'Informe a UF da sede junto com o município.';
  end if;
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if exists (select 1 from interno.contas where lower(nome) = lower(v_nome)) then
    raise exception 'Já existe uma conta com este nome.';
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Informe um e-mail válido para o administrador.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;

  begin
    insert into interno.contas (nome, uf, municipio) values (v_nome, upper(nullif(btrim(p_uf), '')), nullif(btrim(p_municipio), ''))
      returning id into v_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo) select v_id, m from unnest(p_modulos) m group by m;
  insert into interno.conta_membros (conta_id, email, nome, papel, criado_por)
  values (v_id, v_email, nullif(btrim(p_admin_nome), ''), 'admin', v_ator);
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'criar_conta', v_id, jsonb_build_object('nome', v_nome, 'admin', v_email, 'modulos', p_modulos));
  return v_id;
end $function$
;


drop function public.app_plataforma_salvar_conta(uuid, text, boolean, text[]);
CREATE OR REPLACE FUNCTION public.app_plataforma_salvar_conta(p_id uuid, p_nome text, p_ativa boolean, p_modulos text[], p_uf text DEFAULT NULL::text, p_municipio text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_nome text := btrim(p_nome);
  c      interno.contas;
begin
  if nullif(btrim(p_uf), '') is not null and upper(btrim(p_uf)) !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if nullif(btrim(p_municipio), '') is not null and nullif(btrim(p_uf), '') is null then
    raise exception 'Informe a UF da sede junto com o município.';
  end if;
  select * into c from interno.contas where id = p_id for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if v_nome is null or length(v_nome) not between 2 and 120 then
    raise exception 'Informe o nome da conta (2 a 120 caracteres).';
  end if;
  if exists (select 1 from interno.contas where lower(nome) = lower(v_nome) and id <> p_id) then
    raise exception 'Já existe uma conta com este nome.';
  end if;
  -- a operadora não se desliga (o motor e os alertas da plataforma rodam nela)
  if p_id = '00000000-0000-0000-0000-000000000001' and not coalesce(p_ativa, true) then
    raise exception 'A conta da operadora não pode ser desativada.';
  end if;
  if coalesce(cardinality(p_modulos), 0) = 0 or not (p_modulos <@ array['escala', 'ponto']) then
    raise exception 'Escolha os módulos da conta (escala, ponto).';
  end if;

  begin
    update interno.contas set nome = v_nome, ativa = coalesce(p_ativa, ativa),
           uf = upper(nullif(btrim(p_uf), '')), municipio = nullif(btrim(p_municipio), '') where id = p_id;
  exception when unique_violation then
    raise exception 'Já existe uma conta com este nome.';
  end;
  insert into interno.conta_modulos (conta_id, modulo, ativo)
  select p_id, m, m = any (p_modulos) from unnest(array['escala', 'ponto']) m
  on conflict (conta_id, modulo) do update
     set ativo = excluded.ativo,
         desde = case when conta_modulos.ativo <> excluded.ativo then now() else conta_modulos.desde end;
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'alterar_conta', p_id, jsonb_build_object(
    'nome', case when c.nome <> v_nome then jsonb_build_array(c.nome, v_nome) end,
    'ativa', case when c.ativa <> coalesce(p_ativa, c.ativa) then p_ativa end,
    'sede', case when c.uf is distinct from upper(nullif(btrim(p_uf), '')) or c.municipio is distinct from nullif(btrim(p_municipio), '')
                 then jsonb_build_array(c.uf, c.municipio, upper(nullif(btrim(p_uf), '')), nullif(btrim(p_municipio), '')) end,
    'modulos', p_modulos));
end $function$
;


-- feriados (catálogo da plataforma): lista do ano, cadastro e remoção; o nacional da carga não se altera aqui
create or replace function public.app_plataforma_feriados(p_ano int)
 returns jsonb language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'data', f.data, 'nome', f.nome, 'abrangencia', f.abrangencia,
                                                       'uf', f.uf, 'municipio', f.municipio) order by f.data, f.uf nulls first, f.municipio nulls first)
                     from interno.feriados f where extract(year from f.data) = p_ano), '[]'::jsonb);
end $function$;

create or replace function public.app_plataforma_salvar_feriado(p jsonb)
 returns bigint language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator text := interno.fn_exigir_plataforma();
  v_id   bigint := nullif(p->>'id', '')::bigint;
  v_abr  text := p->>'abrangencia';
  v_uf   text := upper(nullif(btrim(p->>'uf'), ''));
  v_mun  text := nullif(btrim(p->>'municipio'), '');
begin
  if nullif(p->>'data', '') is null or length(btrim(coalesce(p->>'nome', ''))) < 3 then
    raise exception 'Informe a data e o nome do feriado.';
  end if;
  if v_abr is null or v_abr not in ('estadual', 'municipal', 'facultativo') then
    raise exception 'Escolha: estadual, municipal ou facultativo (o nacional vem da carga da plataforma).';
  end if;
  if v_uf is not null and v_uf !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if v_abr = 'estadual' then v_mun := null; end if;
  begin
    if v_id is null then
      insert into interno.feriados (data, nome, abrangencia, uf, municipio)
      values ((p->>'data')::date, btrim(p->>'nome'), v_abr, v_uf, v_mun) returning id into v_id;
    else
      update interno.feriados set data = (p->>'data')::date, nome = btrim(p->>'nome'), abrangencia = v_abr, uf = v_uf, municipio = v_mun
       where id = v_id and abrangencia <> 'nacional';
      if not found then raise exception 'Feriado não encontrado (o nacional não se altera aqui).'; end if;
    end if;
  exception
    when unique_violation then raise exception 'Já existe feriado nesta data para este lugar.';
    when check_violation then raise exception 'Estadual precisa da UF; municipal precisa da UF e do município.';
  end;
  return v_id;
end $function$;

create or replace function public.app_plataforma_remover_feriado(p_id bigint)
 returns void language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  delete from interno.feriados where id = p_id and abrangencia <> 'nacional';
  if not found then raise exception 'Feriado não encontrado (o nacional não se remove aqui).'; end if;
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
