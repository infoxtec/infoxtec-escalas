-- 118: multiempresa F2b, família de cadastros (docs/multiempresa-f2.md). Técnicos, empresas, locais, times, habilidades,
-- tipos de atividade e de documento, usuários do painel e as permissões do RH passam a ler e gravar só na conta da sessão
-- (`fn_conta_atual`, migration 117): leitura filtrada, registro novo com `conta_id` explícito, alteração só de registro da
-- conta e todo id recebido conferido na conta ("não encontrado" para id de outra conta, como para id inexistente).
-- `fn_papel_na_conta` substitui o papel global onde ele decide máscara e permissão (P1 da revisão da 117).
-- Nomes de habilidade e tipos passam a ser únicos por conta (catálogo, sem uso em login); CPF, telefone e CNPJ continuam
-- únicos no sistema inteiro até a F6. Usuários do painel: só a conta 1 grava até a F3 (usuários por conta).
-- Funções recriadas a partir da definição da homologação de 27/10 (md5 do conjunto conferido: aef75c9c…).

-- papel do usuário da sessão na conta da sessão
create or replace function interno.fn_papel_na_conta()
returns text
language sql
stable
set search_path = interno, public, extensions, pg_temp
as $$
  select m.papel from interno.conta_membros m
   where m.conta_id = interno.fn_conta_atual() and m.email = lower(nullif(auth.jwt() ->> 'email', '')) and m.ativo
$$;

-- unicidade de nome do catálogo por conta
alter table interno.habilidades drop constraint habilidades_nome_key;
create unique index habilidades_conta_nome_uq on interno.habilidades (conta_id, nome);
alter table interno.tipos_atividade drop constraint tipos_atividade_nome_key;
create unique index tipos_atividade_conta_nome_uq on interno.tipos_atividade (conta_id, nome);
alter table interno.tipos_documento drop constraint tipos_documento_nome_key;
create unique index tipos_documento_conta_nome_uq on interno.tipos_documento (conta_id, nome);

-- aptos para um tipo de atividade: só técnicos da conta do tipo
create or replace function interno.fn_aptidao(p_tipo uuid)
 returns jsonb
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
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
    ) as x from tecnicos t
    where t.ativo and t.conta_id = (select ta.conta_id from tipos_atividade ta where ta.id = p_tipo)
  ) s
$function$;

-- exclusão do técnico: único supervisor ativo contado na conta do técnico
create or replace function interno.fn_excluir_tecnico(p_ator text, p_tecnico_id text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_id      uuid := p_tecnico_id::uuid;
  v_ator    text := coalesce(nullif(p_ator, ''), 'painel');
  v_sup     boolean;
  v_conta   uuid;
  v_outros  int;
  v_abertas int;
  v_total   int;
  v_hoje    date := (now() at time zone fn_config('fuso'))::date;
begin
  perform fn_exigir_papel(p_ator, array['admin']);
  perform set_config('app.ator', v_ator, false);

  select is_supervisor, conta_id into v_sup, v_conta from tecnicos where id = v_id;
  if not found then
    raise exception 'Técnico não encontrado.';
  end if;

  if v_sup then
    select count(*) into v_outros from tecnicos where is_supervisor and ativo and id <> v_id and conta_id = v_conta;
    if v_outros = 0 then
      raise exception 'Não é possível excluir o único supervisor ativo. Cadastre outro supervisor antes.';
    end if;
  end if;

  select count(*) into v_abertas
  from escalas
  where tecnico_id = v_id and data_servico >= v_hoje
    and status in ('agendada', 'notificada', 'confirmada', 'reagendada', 'em_execucao');
  if v_abertas > 0 then
    raise exception 'Este técnico tem % programação(ões) em aberto a partir de hoje. Cancele ou conclua antes de excluir.', v_abertas;
  end if;

  select count(*) into v_total from escalas where tecnico_id = v_id;
  delete from escalas  where tecnico_id = v_id;
  delete from tecnicos where id = v_id;

  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas, conta_id)
  values ('tecnico', v_id, v_ator, v_total, v_conta);

  return jsonb_build_object('excluido', true, 'escalas_removidas', v_total);
end $function$;

-- time criado pela "equipe" do técnico nasce na conta da empresa (P1 da revisão da 118; md5 da homologação 81c12dd0…)
create or replace function interno.fn_tecnico_time()
 returns trigger
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_nome  text := nullif(trim(new.equipe), '');
  v_id    uuid;
  v_ativo boolean;
begin
  if v_nome is null or new.empresa_id is null then
    new.time_id := null;
    return new;
  end if;
  new.equipe := v_nome;
  insert into times (empresa_id, nome, conta_id)
  select new.empresa_id, v_nome, e.conta_id from empresas e where e.id = new.empresa_id
  on conflict do nothing;
  select id, ativo into v_id, v_ativo from times where empresa_id = new.empresa_id and lower(trim(nome)) = lower(v_nome);
  if not v_ativo and new.time_id is distinct from v_id then
    raise exception 'O time "%" está inativo. Reative-o em Escala / Carga Horária > Times ou escolha outro.', v_nome;
  end if;
  new.time_id := v_id;
  return new;
end $function$;

create or replace function public.app_aptidao(p_tipo uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if not exists (select 1 from tipos_atividade where id = p_tipo and conta_id = fn_conta_atual()) then
    raise exception 'Tipo de atividade não encontrado.';
  end if;
  return fn_aptidao(p_tipo);
end $function$;

create or replace function public.app_definir_habilidades(p_tecnico uuid, p_habilidades jsonb)
 returns integer
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  h       jsonb;
  v_ids   uuid[] := '{}';
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = v_conta) then
    raise exception 'Técnico não encontrado.';
  end if;

  for h in select * from jsonb_array_elements(coalesce(p_habilidades, '[]'::jsonb)) loop
    if not exists (select 1 from habilidades where id = (h->>'habilidade_id')::uuid and conta_id = v_conta) then
      raise exception 'Habilidade não encontrada.';
    end if;
    v_ids := v_ids || (h->>'habilidade_id')::uuid;
    insert into tecnico_habilidades (tecnico_id, habilidade_id, nivel, validade, observacao, conta_id)
    values (p_tecnico, (h->>'habilidade_id')::uuid,
            coalesce(nullif(h->>'nivel',''), 'basico'), null, nullif(trim(h->>'observacao'), ''), v_conta)
    on conflict (tecnico_id, habilidade_id) do update
      set nivel = excluded.nivel, validade = null,
          observacao = excluded.observacao, atualizado_em = now();
  end loop;

  delete from tecnico_habilidades
  where tecnico_id = p_tecnico and not (habilidade_id = any (v_ids));

  return coalesce(array_length(v_ids, 1), 0);
end $function$;

create or replace function public.app_definir_rh_folhas(p_email text, p_valor boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin']);
  v_conta uuid := fn_conta_atual();
  v_papel text;
begin
  select m.papel into v_papel from conta_membros m where m.conta_id = v_conta and m.email = lower(trim(p_email));
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if p_valor and v_papel not in ('admin', 'gestor') then raise exception 'Só admin ou gestor pode abrir o cofre de folhas.'; end if;
  update painel_usuarios set rh_folhas = p_valor, updated_at = now() where email = lower(trim(p_email));
  insert into painel_rh_folhas_log (email, valor, autor, conta_id) values (lower(trim(p_email)), p_valor, v_email, v_conta);
end $function$;

create or replace function public.app_definir_ve_saude(p_email text, p_valor boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin']);
  v_conta uuid := fn_conta_atual();
  v_papel text;
begin
  select m.papel into v_papel from conta_membros m where m.conta_id = v_conta and m.email = lower(trim(p_email));
  if not found then raise exception 'Usuário não encontrado.'; end if;
  if p_valor and v_papel not in ('admin', 'gestor') then raise exception 'Só admin ou gestor pode ver atestados.'; end if;
  update painel_usuarios set ve_saude = p_valor, updated_at = now() where email = lower(trim(p_email));
  insert into painel_ve_saude_log (email, valor, autor, conta_id) values (lower(trim(p_email)), p_valor, v_email, v_conta);
end $function$;

create or replace function public.app_empresas()
 returns setof interno.empresas
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from empresas where conta_id = fn_conta_atual() order by razao_social;
end $function$;

create or replace function public.app_excluir_habilidade(p_id uuid, p_forcar boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_nome text; v_tecnicos int; v_tipos int;
begin
  perform app_exigir(array['admin','gestor']);
  select nome into v_nome from habilidades where id = p_id and conta_id = fn_conta_atual();
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
end $function$;

create or replace function public.app_excluir_tecnico(p_tecnico uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin']);
begin
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = fn_conta_atual()) then
    raise exception 'Técnico não encontrado.';
  end if;
  return fn_excluir_tecnico(v_email, p_tecnico::text);
end $function$;

create or replace function public.app_excluir_tipo_documento(p_id uuid, p_forcar boolean default false)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_nome text; v_tecnicos int; v_tipos int; v_arquivos int;
begin
  perform app_exigir(array['admin','gestor']);
  select nome into v_nome from tipos_documento where id = p_id and conta_id = fn_conta_atual();
  if not found then raise exception 'Tipo de documento não encontrado.'; end if;
  select count(*) into v_tecnicos from tecnico_documentos where tipo_documento_id = p_id;
  select count(*) into v_tipos    from tipo_atividade_documentos where tipo_documento_id = p_id;
  select count(*) into v_arquivos from documentos where tipo_documento_id = p_id;
  if not p_forcar and (v_tecnicos > 0 or v_tipos > 0 or v_arquivos > 0) then
    raise exception '% está em uso: % técnico(s), % tipo(s) de atividade e % arquivo(s). Confirme para excluir mesmo assim, ou desative.',
      v_nome, v_tecnicos, v_tipos, v_arquivos;
  end if;
  delete from tipos_documento where id = p_id;
  return jsonb_build_object('excluido', true, 'nome', v_nome, 'tecnicos_afetados', v_tecnicos);
end $function$;

create or replace function public.app_habilidades()
 returns setof interno.habilidades
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from habilidades where conta_id = fn_conta_atual() order by categoria, nome;
end $function$;

create or replace function public.app_locais()
 returns setof interno.locais
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select * from locais where conta_id = fn_conta_atual() order by nome;
end $function$;

create or replace function public.app_remover_tecnico_habilidade(p_tecnico uuid, p_habilidade uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor']);
  delete from tecnico_habilidades
   where tecnico_id = p_tecnico and habilidade_id = p_habilidade and conta_id = fn_conta_atual();
end $function$;

create or replace function public.app_rh_folhas_historico()
 returns table(email text, valor boolean, autor text, em text)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin']);
  return query select l.email, l.valor, l.autor, to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')
                 from painel_rh_folhas_log l where l.conta_id = fn_conta_atual() order by l.id desc limit 100;
end $function$;

create or replace function public.app_salvar_empresa(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_cnpj  text := regexp_replace(coalesce(p->>'cnpj', ''), '\D', '', 'g');
  v_logo  text := nullif(trim(p->>'logo'), '');
  v_exige boolean := (p->>'exige_registro_intervalo')::boolean;
  -- CEI, CAEPF ou CNO (Art. 84, I, "se houver"): só dígitos, 12 a 14
  v_cei   text := nullif(regexp_replace(coalesce(p->>'cei_caepf_cno', ''), '\D', '', 'g'), '');
  v_antes boolean;
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;
  if v_logo is not null and v_logo !~ '^[a-z0-9-]{1,40}$' then raise exception 'Logotipo inválido.'; end if;
  if v_cei is not null and v_cei !~ '^\d{12,14}$' then raise exception 'CEI, CAEPF ou CNO inválido: informe de 12 a 14 dígitos.'; end if;
  if v_id is not null then
    select exige_registro_intervalo into v_antes from empresas where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  if v_exige is not null and v_exige is distinct from coalesce(v_antes, false)
     and coalesce(fn_papel_na_conta(), '') <> 'admin' then
    raise exception 'Só o administrador muda a exigência do registro do intervalo.';
  end if;

  if v_id is null then
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cidade, uf, empregadora, ativo, logo,
                          exige_registro_intervalo, cei_caepf_cno, conta_id)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true), v_logo,
            coalesce(v_exige, false), v_cei, v_conta)
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      uf = upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
      empregadora = coalesce((p->>'empregadora')::boolean, false),
      ativo = coalesce((p->>'ativo')::boolean, true),
      -- painel antigo não manda o logotipo nem a exigência: fica o que estava
      logo = case when p ? 'logo' then v_logo else logo end,
      exige_registro_intervalo = coalesce(v_exige, exige_registro_intervalo),
      cei_caepf_cno = case when p ? 'cei_caepf_cno' then v_cei else cei_caepf_cno end
    where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma empresa com este CNPJ.';
end $function$;

create or replace function public.app_salvar_habilidade(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_id    uuid := nullif(p->>'id','')::uuid;
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome da habilidade é obrigatório.'; end if;
  if v_id is null then
    insert into habilidades (nome, categoria, descricao, ativo, conta_id)
    values (trim(p->>'nome'), coalesce(nullif(p->>'categoria',''),'tecnica'),
            nullif(trim(p->>'descricao'),''), coalesce((p->>'ativo')::boolean,true), v_conta)
    returning id into v_id;
  else
    update habilidades set nome = trim(p->>'nome'),
      categoria = coalesce(nullif(p->>'categoria',''),'tecnica'),
      descricao = nullif(trim(p->>'descricao'),''),
      ativo = coalesce((p->>'ativo')::boolean,true)
    where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Habilidade não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma habilidade com esse nome.';
end $function$;

create or replace function public.app_salvar_local(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_lat   numeric := nullif(p->>'latitude', '')::numeric;
  v_lng   numeric := nullif(p->>'longitude', '')::numeric;
  v_cli   uuid := nullif(p->>'cliente_empresa_id', '')::uuid;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Informe latitude e longitude juntas.'; end if;
  if nullif(trim(p->>'link_maps'), '') !~* '^https?://' then
    raise exception 'Link do Google Maps inválido: precisa começar com https://';
  end if;
  if v_cli is not null and not exists (select 1 from empresas where id = v_cli and conta_id = v_conta) then
    raise exception 'Empresa não encontrada.';
  end if;

  if v_id is null then
    insert into locais (nome, cliente, endereco, cidade, referencia, link_maps, contato_local, telefone_contato, ativo,
                        latitude, longitude, raio_m, cliente_empresa_id, conta_id)
    values (trim(p->>'nome'), nullif(trim(p->>'cliente'), ''), nullif(trim(p->>'endereco'), ''),
            coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'), nullif(trim(p->>'referencia'), ''),
            nullif(trim(p->>'link_maps'), ''), nullif(trim(p->>'contato_local'), ''),
            nullif(trim(p->>'telefone_contato'), ''), coalesce((p->>'ativo')::boolean, true),
            v_lat, v_lng, coalesce(nullif(p->>'raio_m', '')::int, 200), v_cli, v_conta)
    returning id into v_id;
  else
    update locais set
      nome = trim(p->>'nome'), cliente = nullif(trim(p->>'cliente'), ''),
      endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
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
end $function$;

create or replace function public.app_salvar_tecnico(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_tel text := regexp_replace(coalesce(p->>'telefone_e164', ''), '\D', '', 'g');
  v_opt boolean := coalesce((p->>'opt_in')::boolean, false);
  v_mascarado boolean := coalesce(p->>'cpf', '') ~ '\*';
  v_cpf text := case when not v_mascarado then nullif(regexp_replace(coalesce(p->>'cpf', ''), '\D', '', 'g'), '') end;
  v_emp uuid := nullif(p->>'empresa_id', '')::uuid;
  v_optant boolean;
begin
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if coalesce(trim(p->>'funcao'), '') = '' then raise exception 'Função é obrigatória.'; end if;
  if v_tel !~ '^[1-9][0-9]{9,14}$' then
    raise exception 'Telefone inválido: use somente dígitos com código do país. Ex: 5571981776307';
  end if;
  if v_cpf is not null and not fn_cpf_valido(v_cpf) then raise exception 'CPF inválido.'; end if;
  if v_emp is not null and not exists (select 1 from empresas where id = v_emp and conta_id = v_conta) then
    raise exception 'Empresa não encontrada.';
  end if;

  if v_id is null then
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, opt_in_em, ativo,
                          perfil_teste, desligado_em, cpf, matricula, admissao, empresa_id, conta_id)
    values (trim(p->>'nome'), v_tel, trim(p->>'funcao'), nullif(trim(p->>'equipe'), ''),
            coalesce((p->>'is_supervisor')::boolean, false), v_opt,
            case when v_opt then now() end, coalesce((p->>'ativo')::boolean, true),
            coalesce((p->>'perfil_teste')::boolean, false),
            nullif(p->>'desligado_em', '')::date, v_cpf, nullif(trim(p->>'matricula'), ''),
            nullif(p->>'admissao', '')::date, v_emp, v_conta)
    returning id into v_id;
  else
    select opt_in into v_optant from tecnicos where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Técnico não encontrado.'; end if;
    update tecnicos set
      nome = trim(p->>'nome'), telefone_e164 = v_tel, funcao = trim(p->>'funcao'),
      equipe = nullif(trim(p->>'equipe'), ''),
      is_supervisor = coalesce((p->>'is_supervisor')::boolean, false),
      opt_in = v_opt,
      opt_in_em = case when v_opt and not v_optant then now() else opt_in_em end,
      ativo = coalesce((p->>'ativo')::boolean, true),
      perfil_teste = coalesce((p->>'perfil_teste')::boolean, false),
      desligado_em = case when p ? 'desligado_em' then nullif(p->>'desligado_em', '')::date else desligado_em end,
      cpf        = case when p ? 'cpf' and not v_mascarado then v_cpf else cpf end,
      matricula  = case when p ? 'matricula'  then nullif(trim(p->>'matricula'), '') else matricula end,
      admissao   = case when p ? 'admissao'   then nullif(p->>'admissao', '')::date else admissao end,
      empresa_id = case when p ? 'empresa_id' then v_emp else empresa_id end
    where id = v_id and conta_id = v_conta;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe um técnico com este telefone, este CPF ou esta matrícula na empresa.';
end $function$;

create or replace function public.app_salvar_time(p_id uuid, p_empresa uuid, p_nome text, p_ativo boolean default true)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_nome  text := nullif(trim(p_nome), '');
  v_id    uuid := p_id;
  v_emp   uuid;
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if v_nome is null then raise exception 'Dê um nome ao time.'; end if;
  if length(v_nome) > 60 then raise exception 'Nome do time: até 60 caracteres.'; end if;
  if v_id is null then
    if not exists (select 1 from empresas where id = p_empresa and ativo and conta_id = v_conta) then
      raise exception 'Escolha a empresa do time.';
    end if;
    v_emp := p_empresa;
  else
    select empresa_id into v_emp from times where id = v_id and conta_id = v_conta;
    if v_emp is null then raise exception 'Time não encontrado.'; end if;
  end if;
  if exists (select 1 from times where empresa_id = v_emp and lower(trim(nome)) = lower(v_nome) and id is distinct from v_id) then
    raise exception 'Já existe um time com este nome nesta empresa.';
  end if;
  if not coalesce(p_ativo, true) and exists (select 1 from tecnicos where time_id = v_id) then
    raise exception 'Tire os membros do time antes de inativá-lo.';
  end if;
  if v_id is null then
    insert into times (empresa_id, nome, ativo, conta_id) values (v_emp, v_nome, coalesce(p_ativo, true), v_conta)
    returning id into v_id;
  else
    update times set nome = v_nome, ativo = coalesce(p_ativo, true) where id = v_id;
    update tecnicos set equipe = v_nome where time_id = v_id and equipe is distinct from v_nome;
  end if;
  return v_id;
end $function$;

create or replace function public.app_salvar_tipo_atividade(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_id uuid := nullif(p->>'id','')::uuid; r jsonb; v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome do tipo de atividade é obrigatório.'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'requisitos','[]'::jsonb)) x
              where not exists (select 1 from habilidades h where h.id = (x->>'habilidade_id')::uuid and h.conta_id = v_conta)) then
    raise exception 'Habilidade não encontrada.';
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p->'documentos','[]'::jsonb)) x
              where not exists (select 1 from tipos_documento d where d.id = (x->>'tipo_documento_id')::uuid and d.conta_id = v_conta)) then
    raise exception 'Tipo de documento não encontrado.';
  end if;
  if v_id is null then
    insert into tipos_atividade (nome, descricao, ativo, conta_id)
    values (trim(p->>'nome'), nullif(trim(p->>'descricao'),''), coalesce((p->>'ativo')::boolean,true), v_conta)
    returning id into v_id;
  else
    update tipos_atividade set nome = trim(p->>'nome'), descricao = nullif(trim(p->>'descricao'),''),
           ativo = coalesce((p->>'ativo')::boolean,true) where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Tipo de atividade não encontrado.'; end if;
  end if;

  delete from tipo_atividade_requisitos where tipo_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p->'requisitos','[]'::jsonb)) loop
    insert into tipo_atividade_requisitos (tipo_id, habilidade_id, nivel_minimo, conta_id)
    values (v_id, (r->>'habilidade_id')::uuid, coalesce(nullif(r->>'nivel_minimo',''),'basico'), v_conta)
    on conflict do nothing;
  end loop;

  delete from tipo_atividade_documentos where tipo_id = v_id;
  for r in select * from jsonb_array_elements(coalesce(p->'documentos','[]'::jsonb)) loop
    insert into tipo_atividade_documentos (tipo_id, tipo_documento_id, conta_id)
    values (v_id, (r->>'tipo_documento_id')::uuid, v_conta) on conflict do nothing;
  end loop;
  return v_id;
exception when unique_violation then raise exception 'Já existe um tipo de atividade com esse nome.';
end $function$;

create or replace function public.app_salvar_tipo_documento(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_id uuid := nullif(p->>'id','')::uuid;
  v_chaves text[] := coalesce((select array_agg(lower(trim(x)))
    from jsonb_array_elements_text(coalesce(p->'palavras_chave','[]'::jsonb)) x where trim(x) <> ''), '{}');
  v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if coalesce(trim(p->>'nome'),'') = '' then raise exception 'Nome do documento é obrigatório.'; end if;
  if v_id is null then
    insert into tipos_documento (nome, descricao, palavras_chave, ativo, ordem, conta_id)
    values (trim(p->>'nome'), nullif(trim(p->>'descricao'),''), v_chaves,
            coalesce((p->>'ativo')::boolean, true), coalesce(nullif(p->>'ordem','')::int, 100), v_conta)
    returning id into v_id;
  else
    update tipos_documento set nome = trim(p->>'nome'), descricao = nullif(trim(p->>'descricao'),''),
      palavras_chave = v_chaves, ativo = coalesce((p->>'ativo')::boolean, true),
      ordem = coalesce(nullif(p->>'ordem','')::int, ordem) where id = v_id and conta_id = v_conta;
    if not found then raise exception 'Tipo de documento não encontrado.'; end if;
  end if;
  return v_id;
exception when unique_violation then raise exception 'Já existe um documento com esse nome.';
end $function$;

-- usuários do painel: até a F3 (usuários por conta), só a conta 1 grava; o resto segue em painel_usuarios + espelho
create or replace function public.app_salvar_usuario(p_email text, p_nome text, p_papel text, p_ativo boolean)
 returns text
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_exigir(array['admin']);
begin
  if fn_conta_atual() <> '00000000-0000-0000-0000-000000000001' then
    raise exception 'Usuários por conta chegam com o novo painel (F3).';
  end if;
  return fn_salvar_usuario_painel(v_email, p_email, p_nome, p_papel, p_ativo::text);
end $function$;

create or replace function public.app_tecnico_cpf(p_tecnico uuid)
 returns text
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_cpf text;
begin
  perform app_exigir(array['admin','gestor']);
  select cpf into v_cpf from tecnicos where id = p_tecnico and conta_id = fn_conta_atual();
  return v_cpf;
end $function$;

create or replace function public.app_tecnico_habilidades()
 returns setof interno.vw_tecnico_habilidades
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query select v.* from vw_tecnico_habilidades v
                where exists (select 1 from tecnicos t where t.id = v.tecnico_id and t.conta_id = fn_conta_atual())
                order by v.tecnico, v.habilidade;
end $function$;

create or replace function public.app_tecnicos()
 returns setof interno.tecnicos
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_leitura boolean;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  -- máscara pelo papel na conta da sessão (P1 da revisão da 117)
  v_leitura := fn_papel_na_conta() = 'leitura';
  return query
    select (jsonb_populate_record(null::tecnicos, to_jsonb(t) || jsonb_build_object('cpf',
             case when v_leitura or t.cpf is null then null
                  else '***.' || substr(t.cpf, 4, 3) || '.' || substr(t.cpf, 7, 3) || '-**' end))).*
    from tecnicos t where t.conta_id = fn_conta_atual() order by t.nome;
end $function$;

create or replace function public.app_time_definir_membros(p_time uuid, p_tecnicos uuid[])
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_x times;
begin
  perform app_exigir(array['admin','gestor']);
  select * into v_x from times where id = p_time and conta_id = fn_conta_atual();
  if not found then raise exception 'Time não encontrado.'; end if;
  if not v_x.ativo then raise exception 'Time inativo.'; end if;
  if exists (select 1 from tecnicos where id = any(coalesce(p_tecnicos, '{}')) and empresa_id is distinct from v_x.empresa_id) then
    raise exception 'O time só recebe funcionários da própria empresa.';
  end if;
  update tecnicos set equipe = null
   where time_id = p_time and not (id = any(coalesce(p_tecnicos, '{}'))) and conta_id = v_x.conta_id;
  update tecnicos set equipe = v_x.nome
   where id = any(coalesce(p_tecnicos, '{}')) and time_id is distinct from p_time and conta_id = v_x.conta_id;
end $function$;

create or replace function public.app_times(p_empresa uuid default null::uuid)
 returns table(id uuid, empresa_id uuid, empresa text, nome text, ativo boolean, membros bigint)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return query
    select x.id, x.empresa_id, coalesce(m.nome_fantasia, m.razao_social), x.nome, x.ativo,
           (select count(*) from tecnicos t where t.time_id = x.id and t.ativo and t.desligado_em is null)
      from times x join empresas m on m.id = x.empresa_id
     where (p_empresa is null or x.empresa_id = p_empresa) and x.conta_id = fn_conta_atual()
     order by coalesce(m.nome_fantasia, m.razao_social), x.nome;
end $function$;

create or replace function public.app_tipos_atividade()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', ta.id, 'nome', ta.nome, 'descricao', ta.descricao, 'ativo', ta.ativo,
      'requisitos', coalesce((
        select jsonb_agg(jsonb_build_object('habilidade_id', r.habilidade_id,
                 'habilidade', h.nome, 'nivel_minimo', r.nivel_minimo) order by h.nome)
        from tipo_atividade_requisitos r join habilidades h on h.id = r.habilidade_id
        where r.tipo_id = ta.id), '[]'::jsonb),
      'documentos', coalesce((
        select jsonb_agg(jsonb_build_object('tipo_documento_id', dr.tipo_documento_id, 'documento', tp.nome) order by tp.nome)
        from tipo_atividade_documentos dr join tipos_documento tp on tp.id = dr.tipo_documento_id
        where dr.tipo_id = ta.id), '[]'::jsonb)
    ) order by ta.nome) from tipos_atividade ta where ta.conta_id = fn_conta_atual()), '[]'::jsonb);
end $function$;

create or replace function public.app_tipos_documento()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id', id, 'nome', nome, 'descricao', descricao, 'palavras_chave', palavras_chave,
    'ativo', ativo, 'ordem', ordem) order by ordem, nome) from tipos_documento where conta_id = fn_conta_atual()), '[]'::jsonb);
end $function$;

create or replace function public.app_usuarios()
 returns setof interno.painel_usuarios
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin']);
  return query select u.* from painel_usuarios u
                where exists (select 1 from conta_membros m where m.conta_id = fn_conta_atual() and m.email = u.email)
                order by coalesce(u.nome, u.email);
end $function$;

create or replace function public.app_usuarios_mfa()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  return jsonb_build_object(
    'ativos', coalesce((
      select jsonb_agg(a.x order by a.x->>'email')
        from (select jsonb_build_object('email', lower(u.email),
                       'desde', to_char(min(f.created_at) at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')) as x
                from auth.mfa_factors f join auth.users u on u.id = f.user_id
               where f.status::text = 'verified'
                 and exists (select 1 from conta_membros m where m.conta_id = v_conta and m.email = lower(u.email))
               group by lower(u.email)) a), '[]'::jsonb),
    'historico', coalesce((
      select jsonb_agg(jsonb_build_object('email', l.email, 'acao', l.acao,
               'em', to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')) order by l.id desc)
        from (select * from painel_mfa_log g
               where exists (select 1 from conta_membros m where m.conta_id = v_conta and m.email = lower(g.email))
               order by id desc limit 100) l), '[]'::jsonb));
end $function$;

create or replace function public.app_ve_saude_historico()
 returns table(email text, valor boolean, autor text, em text)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform app_exigir(array['admin']);
  return query select l.email, l.valor, l.autor, to_char(l.em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI')
                 from painel_ve_saude_log l where l.conta_id = fn_conta_atual() order by l.id desc limit 100;
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
