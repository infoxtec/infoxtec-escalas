-- Pacote de cadastro (CNPJ, CEP e CPF): CNPJ alfanumérico (IN RFB 2.229/2024, emitido desde julho de 2026), CEP em
-- empresas e locais (preenchimento do endereço pela Edge Function consulta-cadastro) e o AFD com o CNPJ novo.

set lock_timeout = '5s';

-- CNPJ: 12 posições com letras maiúsculas ou dígitos e 2 dígitos verificadores; o caractere vale o código ASCII menos
-- 48 (A = 17), o que mantém o cálculo antigo para os CNPJs só com números
create or replace function interno.fn_cnpj_valido(p text)
 returns boolean language plpgsql immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  pesos1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  pesos2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s int; r int; i int;
begin
  if p is null or p !~ '^[0-9A-Z]{12}[0-9]{2}$' or p ~ '^(.)\1{13}$' then return false; end if;
  s := 0;
  for i in 1..12 loop s := s + (ascii(substr(p, i, 1)) - 48) * pesos1[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(p, 13, 1)::int then return false; end if;
  s := 0;
  for i in 1..13 loop s := s + (ascii(substr(p, i, 1)) - 48) * pesos2[i]; end loop;
  r := s % 11; r := case when r < 2 then 0 else 11 - r end;
  return r = substr(p, 14, 1)::int;
end $function$;

-- CNPJ para o AFD: mantém as letras (fn_afd_n tira tudo que não é dígito, o que serve ao número do INPI)
create or replace function interno.fn_afd_cnpj(p text)
 returns text language sql immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select lpad(right(upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')), 14), 14, '0')
$function$;

alter table interno.empresas add column cep char(8) check (cep ~ '^[0-9]{8}$');
alter table interno.locais add column cep char(8) check (cep ~ '^[0-9]{8}$');


CREATE OR REPLACE FUNCTION public.app_salvar_empresa(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
  v_id    uuid := nullif(p->>'id', '')::uuid;
  -- CNPJ alfanumérico (migration 133): só letras e dígitos, em maiúsculas
  v_cnpj  text := upper(regexp_replace(coalesce(p->>'cnpj', ''), '[^0-9A-Za-z]', '', 'g'));
  v_cep   text := nullif(regexp_replace(coalesce(p->>'cep', ''), '\D', '', 'g'), '');
  v_logo  text := nullif(trim(p->>'logo'), '');
  v_exige boolean := (p->>'exige_registro_intervalo')::boolean;
  -- CEI, CAEPF ou CNO (Art. 84, I, "se houver"): só dígitos, 12 a 14
  v_cei   text := nullif(regexp_replace(coalesce(p->>'cei_caepf_cno', ''), '\D', '', 'g'), '');
  v_antes boolean;
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;
  if v_cep is not null and v_cep !~ '^[0-9]{8}$' then raise exception 'CEP inválido: informe os 8 dígitos.'; end if;
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
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cep, cidade, uf, empregadora, ativo, logo,
                          exige_registro_intervalo, cei_caepf_cno, conta_id)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), v_cep, coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true), v_logo,
            coalesce(v_exige, false), v_cei, v_conta)
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cep = case when p ? 'cep' then v_cep else cep end,
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
end $function$
;


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
  v_cep   text := nullif(regexp_replace(coalesce(p->>'cep', ''), '\D', '', 'g'), '');
begin
  if nullif(trim(p->>'uf'), '') is not null and upper(trim(p->>'uf')) !~ '^[A-Z]{2}$' then
    raise exception 'UF inválida: use a sigla com duas letras (ex.: BA).';
  end if;
  if v_cep is not null and v_cep !~ '^[0-9]{8}$' then raise exception 'CEP inválido: informe os 8 dígitos.'; end if;
  if coalesce(trim(p->>'nome'), '') = '' then raise exception 'Nome é obrigatório.'; end if;
  if (v_lat is null) <> (v_lng is null) then raise exception 'Informe latitude e longitude juntas.'; end if;
  if nullif(trim(p->>'link_maps'), '') !~* '^https?://' then
    raise exception 'Link do Google Maps inválido: precisa começar com https://';
  end if;
  if v_cli is not null and not exists (select 1 from empresas where id = v_cli and conta_id = v_conta) then
    raise exception 'Empresa não encontrada.';
  end if;

  if v_id is null then
    insert into locais (nome, cliente, endereco, cep, cidade, uf, referencia, link_maps, contato_local, telefone_contato, ativo,
                        latitude, longitude, raio_m, cliente_empresa_id, conta_id)
    values (trim(p->>'nome'), nullif(trim(p->>'cliente'), ''), nullif(trim(p->>'endereco'), ''), v_cep,
            coalesce(nullif(trim(p->>'cidade'), ''), (select municipio from contas where id = v_conta)),
            coalesce(upper(nullif(trim(p->>'uf'), '')),
                     (select c.uf from contas c where c.id = v_conta
                         and (nullif(trim(p->>'cidade'), '') is null or fn_norm_lugar(p->>'cidade') = fn_norm_lugar(c.municipio)))),
            nullif(trim(p->>'referencia'), ''),
            nullif(trim(p->>'link_maps'), ''), nullif(trim(p->>'contato_local'), ''),
            nullif(trim(p->>'telefone_contato'), ''), coalesce((p->>'ativo')::boolean, true),
            v_lat, v_lng, coalesce(nullif(p->>'raio_m', '')::int, 200), v_cli, v_conta)
    returning id into v_id;
  else
    update locais set
      nome = trim(p->>'nome'), cliente = nullif(trim(p->>'cliente'), ''),
      endereco = nullif(trim(p->>'endereco'), ''),
      cep    = case when p ? 'cep' then v_cep else cep end,
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


-- AFD: o CNPJ da empresa (e o do desenvolvedor) sai com as letras; o resto igual à definição da homologação
CREATE OR REPLACE FUNCTION public.app_ponto_afd(p_empresa uuid, p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email   text := app_exigir(array['admin']);
  v_emp     record;
  v_fuso    text;
  v_hoje    date;
  v_inpi    text := fn_afd_n(fn_config('rep_p_inpi'), 17);
  v_dev     text;
  v_conf    boolean := coalesce(fn_config('afd_leiaute_conferido'), 'false') <> 'true';
  v_dh      text;
  v_linhas  text[] := '{}';
  v_campos  text;
  v_hash    text;
  v_ant     text := '';
  v_n7      int := 0;
  v_cab     text;
  v_fim     text;
  v_texto   text;
  v_sha     text;
  m         record;
begin
  select e.id, e.cnpj, e.razao_social, coalesce(e.fuso, 'America/Bahia') as fuso into v_emp
    from empresas e where e.id = p_empresa and e.empregadora and e.conta_id = fn_conta_atual();
  if not found then raise exception 'Empresa empregadora não encontrada.'; end if;
  v_fuso := v_emp.fuso;
  v_hoje := (now() at time zone v_fuso)::date;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate > v_hoje then
    raise exception 'Período inválido: a data final não pode passar de hoje.';
  end if;
  v_dev := fn_afd_cnpj(coalesce(nullif(fn_config('rep_p_desenvolvedor_cnpj'), ''), v_emp.cnpj));

  -- Cabeçalho (tipo 1): 298 posições + CRC-16
  v_cab := '000000000' || '1' || '1' || fn_afd_cnpj(v_emp.cnpj) || repeat(' ', 14)
        || fn_afd_a(v_emp.razao_social, 150) || v_inpi
        || to_char(p_de, 'YYYY-MM-DD') || to_char(p_ate, 'YYYY-MM-DD') || fn_afd_dh(now(), v_fuso)
        || '003' || '1' || v_dev || repeat(' ', 30);
  v_linhas := v_linhas || (v_cab || fn_afd_crc16(convert_to(v_cab, 'LATIN1')));

  -- Marcações (tipo 7): o hash encadeia desde a primeira marcação da empresa, mesmo fora do período
  for m in select k.nsr, k.cpf, k.momento, k.canal from ponto_marcacoes k
            where k.empresa_id = p_empresa order by k.nsr loop
    v_dh := fn_afd_dh(m.momento, v_fuso);
    v_campos := fn_afd_n(m.nsr::text, 9) || '7' || v_dh || fn_afd_n(m.cpf, 12)
             || v_dh                                                           -- gravação = marcação (on-line)
             || case m.canal when 'app' then '02' else '05' end               -- app web: navegador; WhatsApp e URA: outro
             || '0';                                                           -- on-line
    v_hash := encode(sha256(convert_to(v_campos || v_ant, 'LATIN1')), 'hex');
    v_ant := v_hash;
    if (m.momento at time zone v_fuso)::date between p_de and p_ate then
      v_linhas := v_linhas || (v_campos || v_hash);
      v_n7 := v_n7 + 1;
    end if;
  end loop;

  -- Trailer (tipo 9)
  v_fim := '999999999' || repeat('000000000', 5) || lpad(v_n7::text, 9, '0') || '9';
  v_linhas := v_linhas || v_fim;

  v_texto := array_to_string(v_linhas, E'\r\n') || E'\r\n';
  v_sha := encode(sha256(convert_to(v_texto, 'LATIN1')), 'hex');
  insert into ponto_afd_geracoes (email, empresa_id, de, ate, registros, sha256)
  values (v_email, p_empresa, p_de, p_ate, v_n7, v_sha);

  return jsonb_build_object(
    'nome', 'AFD' || v_inpi || fn_afd_cnpj(v_emp.cnpj) || 'REP_P' || case when v_conf then '_CONFERENCIA' else '' end || '.txt',
    'conteudo', v_texto, 'marcacoes', v_n7, 'sha256', v_sha,
    'conferencia', v_conf,
    'aviso', case when v_conf then 'Versão de conferência: leiaute do Anexo V da Portaria 671 (a conferir contra o do gov.br), '
             || 'sem assinatura CAdES' || case when v_inpi = repeat('0', 17) then ' e sem o número do INPI' else '' end
             || '. Não entregar à fiscalização antes da conferência da contadora. ' else '' end
             || 'O arquivo tem o CPF de todos os funcionários: guarde em local protegido e apague depois do uso.');
end $function$
;


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
