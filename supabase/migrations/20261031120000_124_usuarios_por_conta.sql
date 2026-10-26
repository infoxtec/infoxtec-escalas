-- Multiempresa F3a (decisão 114): usuário do painel por conta.
-- O papel, o ativo e as permissões do RH (ve_saude, rh_folhas) passam a ser da conta, em conta_membros: quem for
-- membro de duas contas tem papel e permissões separados em cada uma. painel_usuarios, que era um cadastro único
-- por e-mail espelhado na conta 1 (116), sai: o nome vai para conta_membros.
-- A trava da 117 (membro só na conta 1) continua até a F3d; app_salvar_usuario já grava na conta da sessão.

set lock_timeout = '5s';

-- 1. Expandir conta_membros e copiar da conta 1 ------------------------------------------------------------------
alter table interno.conta_membros
  add column nome text,
  add column ve_saude boolean not null default false,
  add column rh_folhas boolean not null default false,
  add column criado_por text,
  add column atualizado_em timestamptz not null default now();

update interno.conta_membros m
   set nome = u.nome, ve_saude = u.ve_saude, rh_folhas = u.rh_folhas, criado_por = u.criado_por,
       criado_em = u.created_at, atualizado_em = u.updated_at
  from interno.painel_usuarios u
 where m.email = u.email and m.conta_id = u.conta_id;

-- as permissões do RH só valem para admin e gestor (como nas funções que as gravam)
alter table interno.conta_membros
  add constraint conta_membros_rh_papel_check check (papel in ('admin', 'gestor') or not (ve_saude or rh_folhas)) not valid;
update interno.conta_membros set ve_saude = false, rh_folhas = false where papel = 'leitura' and (ve_saude or rh_folhas);
alter table interno.conta_membros validate constraint conta_membros_rh_papel_check;

-- 2. Leitura pela conta da sessão --------------------------------------------------------------------------------
create or replace function interno.fn_papel(p_email text)
 returns text language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select m.papel from interno.conta_membros m
   where m.conta_id = interno.fn_conta_atual() and m.email = lower(trim(p_email)) and m.ativo
$function$;

create or replace function interno.fn_ve_saude(p_email text)
 returns boolean language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce((select m.ve_saude from interno.conta_membros m
                    where m.conta_id = interno.fn_conta_atual() and m.email = lower(trim(p_email)) and m.ativo
                      and m.papel in ('admin', 'gestor')), false)
$function$;

create or replace function interno.fn_rh_folhas(p_email text)
 returns boolean language sql stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select coalesce((select m.rh_folhas from interno.conta_membros m
                    where m.conta_id = interno.fn_conta_atual() and m.email = lower(trim(p_email)) and m.ativo
                      and m.papel in ('admin', 'gestor')), false)
$function$;

-- usuário de duas contas sem escolha (ou com conta recusada) recebe a lista para escolher, sem papel
create or replace function public.app_meu_acesso()
 returns jsonb language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := app_email();
  v_conta uuid;
  m interno.conta_membros;
begin
  begin
    v_conta := interno.fn_conta_atual();
  exception when others then
    v_conta := null;
  end;
  select * into m from interno.conta_membros where conta_id = v_conta and email = v_email and ativo;
  return jsonb_build_object(
    'email', v_email,
    'conta', v_conta,
    'papel', m.papel,
    'nome', m.nome,
    've_saude', coalesce(m.ve_saude and m.papel in ('admin', 'gestor'), false),
    'rh_folhas', coalesce(m.rh_folhas and m.papel in ('admin', 'gestor'), false),
    'mfa_obrigatorio', coalesce(fn_config('mfa_obrigatorio'), 'false') = 'true',
    'contas', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'papel', cm.papel) order by c.nome)
                          from interno.conta_membros cm join interno.contas c on c.id = cm.conta_id
                         where cm.email = v_email and cm.ativo and c.ativa), '[]'::jsonb)
  );
end $function$;

-- 3. Gravação na conta da sessão ---------------------------------------------------------------------------------
drop function public.app_usuarios();
create function public.app_usuarios()
 returns table (email text, nome text, papel text, ativo boolean, criado_por text, created_at timestamptz,
                updated_at timestamptz, ve_saude boolean, rh_folhas boolean)
 language plpgsql stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  return query select m.email, m.nome, m.papel, m.ativo, m.criado_por, m.criado_em, m.atualizado_em, m.ve_saude, m.rh_folhas
                 from interno.conta_membros m
                where m.conta_id = v_conta
                order by coalesce(m.nome, m.email);
end $function$;

drop function interno.fn_salvar_usuario_painel(text, text, text, text, text);
create or replace function public.app_salvar_usuario(p_email text, p_nome text, p_papel text, p_ativo boolean)
 returns text language plpgsql security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text := app_exigir(array['admin']);
  v_conta uuid := fn_conta_atual();
  v_email text := lower(trim(p_email));
  v_ativo boolean := coalesce(p_ativo, true);
begin
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+$' then
    raise exception 'Informe um e-mail válido.';
  end if;
  -- o último administrador ativo da conta não perde o papel nem o acesso
  if (p_papel <> 'admin' or not v_ativo)
     and exists (select 1 from conta_membros where conta_id = v_conta and email = v_email and papel = 'admin' and ativo)
     and (select count(*) from conta_membros where conta_id = v_conta and papel = 'admin' and ativo) = 1 then
    raise exception 'Este é o único administrador ativo. Cadastre outro administrador antes.';
  end if;

  insert into conta_membros (conta_id, email, nome, papel, ativo, criado_por)
  values (v_conta, v_email, nullif(trim(p_nome), ''), p_papel, v_ativo, v_ator)
  on conflict (conta_id, email) do update
     set nome = excluded.nome, papel = excluded.papel, ativo = excluded.ativo, atualizado_em = now(),
         -- leitura não vê atestados nem abre o cofre
         ve_saude = conta_membros.ve_saude and excluded.papel <> 'leitura',
         rh_folhas = conta_membros.rh_folhas and excluded.papel <> 'leitura';
  return v_email;
end $function$;

create or replace function public.app_definir_ve_saude(p_email text, p_valor boolean)
 returns void language plpgsql security definer
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
  update conta_membros set ve_saude = p_valor, atualizado_em = now() where conta_id = v_conta and email = lower(trim(p_email));
  insert into painel_ve_saude_log (email, valor, autor, conta_id) values (lower(trim(p_email)), p_valor, v_email, v_conta);
end $function$;

create or replace function public.app_definir_rh_folhas(p_email text, p_valor boolean)
 returns void language plpgsql security definer
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
  update conta_membros set rh_folhas = p_valor, atualizado_em = now() where conta_id = v_conta and email = lower(trim(p_email));
  insert into painel_rh_folhas_log (email, valor, autor, conta_id) values (lower(trim(p_email)), p_valor, v_email, v_conta);
end $function$;

-- 4. Termos de aceite: nome e papel de quem assina, na conta da sessão -------------------------------------------
CREATE OR REPLACE FUNCTION interno.fn_programacao_registrar_aceite(p_escala uuid, p_aceite jsonb, p_lim jsonb, p_email text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e     escalas;
  v_usu conta_membros;
  v_txt text;
  v_em  timestamptz := now();
begin
  select * into e from escalas where id = p_escala;
  select * into v_usu from conta_membros where conta_id = fn_conta_atual() and email = p_email;
  v_txt := fn_programacao_termo(e.tecnico_id, e.data_servico, p_lim, p_email, p_aceite->>'motivo', p_aceite->>'justificativa')
    || ' Registrado em ' || to_char(v_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (horário de Brasília, UTC-3).';
  insert into programacao_aceites (escala_id, empresa_id, tecnico_id, data, previsto_min, contratual_min, excedente_min,
                                   motivo, justificativa, texto, sha256, nome, email, papel, aceito_em)
  values (e.id, (select empresa_id from tecnicos where id = e.tecnico_id), e.tecnico_id, e.data_servico,
          (p_lim->>'previsto_min')::int, (p_lim->>'contratual_min')::int, (p_lim->>'excedente_min')::int,
          p_aceite->>'motivo', trim(p_aceite->>'justificativa'), v_txt, encode(sha256(convert_to(v_txt, 'UTF8')), 'hex'),
          coalesce(nullif(v_usu.nome, ''), p_email), p_email, coalesce(v_usu.papel, ''), v_em);
end $function$
;
CREATE OR REPLACE FUNCTION interno.fn_carga_termo(p jsonb, p_val jsonb, p_email text, p_instrumento text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_usu  conta_membros;
  v_emp  empresas;
  v_tipo text := coalesce(p->>'tipo', 'semanal');
begin
  if jsonb_array_length(p_val->'riscos') = 0 then return null; end if;
  select * into v_usu from conta_membros where conta_id = fn_conta_atual() and email = p_email;
  select * into v_emp from empresas where id = (p->>'empresa_id')::uuid;
  return 'Termo interno de aceite de risco: Escala / Carga Horária. '
    || coalesce(v_emp.razao_social, '(empregadora)') || ', CNPJ ' || coalesce(v_emp.cnpj, '-') || ', empregadora, por meio de '
    || coalesce(nullif(v_usu.nome, ''), p_email) || ' (' || p_email || '), '
    || case v_usu.papel when 'admin' then 'administrador' when 'gestor' then 'gestor' else coalesce(v_usu.papel, '') end
    || ' do painel Infoxtec Escalas, que assina como representante da empregadora, registra a decisão da empregadora de aplicar a escala '''
    || coalesce(nullif(trim(p->>'nome'), ''), '(sem nome)') || ''' ('
    || case when v_tipo = '12x36' then '12x36, plantão de ' || fn_ponto_hm(coalesce((p->>'plantao_min')::int, 0))
            else fn_ponto_hm((p_val->>'semanal_min')::int) || ' por semana' end
    || ', intervalo de ' || coalesce((p->>'intervalo_min')::int, 0) || ' min). '
    || 'Antes dessa decisão, o sistema alertou que os pontos a seguir dependem de acordo ou norma coletiva: '
    || (select string_agg(x->>'texto', ' ') from jsonb_array_elements(p_val->'riscos') x) || ' '
    || case when nullif(trim(p_instrumento), '') is not null
            then 'A empregadora indica como amparo desses pontos o seguinte instrumento: ' || trim(p_instrumento) || '.'
            else 'A empregadora não indicou instrumento coletivo que ampare esses pontos e, ciente do alerta, decide aplicar a escala sob sua responsabilidade.' end
    || ' Este termo é um documento interno de gestão da empregadora. Não é dirigido ao empregado, não é mostrado a ele nem assinado por ele, e não altera o contrato de trabalho. Registra só a decisão e o alerta recebido. Não substitui acordo ou norma coletiva, não afasta direitos do empregado e não é renúncia nem transação de direito.';
end $function$
;
CREATE OR REPLACE FUNCTION interno.fn_programacao_termo(p_tecnico uuid, p_data date, p_lim jsonb, p_email text, p_motivo text, p_justificativa text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_usu conta_membros;
  v_emp empresas;
  v_tec tecnicos;
begin
  select * into v_tec from tecnicos where id = p_tecnico;
  select * into v_emp from empresas where id = v_tec.empresa_id;
  select * into v_usu from conta_membros where conta_id = fn_conta_atual() and email = p_email;
  return 'Termo interno de aceite de risco: Programação / Jornada do dia. '
    || coalesce(v_emp.razao_social, '(empregadora)') || ', CNPJ ' || coalesce(v_emp.cnpj, '-') || ', empregadora, por meio de '
    || coalesce(nullif(v_usu.nome, ''), p_email) || ' (' || p_email || '), '
    || case v_usu.papel when 'admin' then 'administrador' when 'gestor' then 'gestor' else coalesce(v_usu.papel, '') end
    || ' do painel Infoxtec Escalas, que assina como representante da empregadora, registra a decisão da empregadora de manter a programação de serviço de '
    || coalesce(v_tec.nome, '(funcionário)') || ' para ' || to_char(p_data, 'DD/MM/YYYY') || '. '
    || 'Antes dessa decisão, o sistema alertou que a programação prevê ' || fn_ponto_hm((p_lim->>'previsto_min')::int)
    || ' de trabalho nesse dia. A jornada do dia pela escala é de ' || fn_ponto_hm((p_lim->>'contratual_min')::int)
    || ', e a programação passa em ' || fn_ponto_hm((p_lim->>'excedente_min')::int)
    || ' o limite de duas horas extras diárias (CLT, art. 59). Motivo indicado pela empregadora: '
    || coalesce(fn_programacao_motivo(p_motivo), '(não informado)') || '. Justificativa: ' || coalesce(nullif(trim(p_justificativa), ''), '(não informada)') || '. '
    || 'Estas horas são uma previsão. A jornada efetivamente trabalhada é a do registro de ponto, e as horas extraordinárias são pagas ou compensadas na forma da lei e da norma coletiva aplicável. '
    || 'Este termo é um documento interno de gestão da empregadora. Não é dirigido ao empregado, não é mostrado a ele nem assinado por ele, e não altera o contrato de trabalho. Registra só a decisão e o alerta recebido. Não substitui acordo ou norma coletiva, não afasta direitos do empregado e não é renúncia nem transação de direito.';
end $function$
;
CREATE OR REPLACE FUNCTION public.app_salvar_carga(p jsonb, p_aceite jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_emp   uuid := (p->>'empresa_id')::uuid;
  v_nome  text := nullif(trim(p->>'nome'), '');
  v_tipo  text := coalesce(p->>'tipo', 'semanal');
  v_val   jsonb;
  v_id    uuid;
  v_emp_nome text;
  v_usu   conta_membros;
  v_instr text := nullif(trim(p_aceite->>'instrumento'), '');
  v_texto text;
  v_em    timestamptz := now();
  v_min   int[];
  v_dsr   int;
begin
  select coalesce(nome_fantasia, razao_social) into v_emp_nome from empresas
   where id = v_emp and empregadora and ativo and conta_id = fn_conta_atual();
  if v_emp_nome is null then raise exception 'A escala pertence a uma empregadora ativa: escolha a empresa.'; end if;
  v_val := fn_carga_validar(p);
  if v_nome is null then raise exception 'Dê um nome à escala.'; end if;
  if exists (select 1 from cargas_horarias where empresa_id = v_emp and lower(trim(nome)) = lower(v_nome)) then
    raise exception 'Já existe uma escala com este nome nesta empresa.';
  end if;
  if jsonb_array_length(v_val->'bloqueios') > 0 then
    raise exception 'Escala não permitida: %', (select string_agg(x->>'texto', ' ') from jsonb_array_elements(v_val->'bloqueios') x);
  end if;
  if jsonb_array_length(v_val->'riscos') > 0 and coalesce((p_aceite->>'aceito')::boolean, false) is not true then
    raise exception 'Esta escala depende de acordo ou norma coletiva: só é salva com o aceite de risco.';
  end if;
  if jsonb_array_length(v_val->'riscos') > 0
     and (select coalesce(array_agg(x->>'codigo' order by x->>'codigo'), '{}') from jsonb_array_elements(v_val->'riscos') x)
         is distinct from (select coalesce(array_agg(c order by c), '{}') from jsonb_array_elements_text(coalesce(p_aceite->'riscos', '[]')) c) then
    raise exception 'Os riscos da escala mudaram desde a tela. Revise e aceite de novo.';
  end if;
  if length(v_instr) > 200 then raise exception 'Acordo ou convenção: até 200 caracteres.'; end if;

  -- descanso semanal remunerado (DSR, decisão 91): um dos dias de folga; o domingo quando ele é folga
  if v_tipo <> '12x36' then
    v_min := (select array_agg(x::int order by o) from jsonb_array_elements_text(p->'minutos') with ordinality t(x, o));
    v_dsr := coalesce(nullif(p->>'dsr_dia', '')::int,
                      case when v_min[7] = 0 then 7 else (select min(i) from generate_series(1, 7) i where v_min[i] = 0) end);
    if v_dsr is null or v_dsr not between 1 and 7 or v_min[v_dsr] <> 0 then
      raise exception 'O descanso semanal (DSR) precisa cair num dia de folga da escala.';
    end if;
  end if;
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, plantao_min, intervalo_min, entrada, semanal_min, riscos, criado_por, dsr_dia)
  values (v_emp, v_nome, v_tipo,
          v_min,
          case when v_tipo = '12x36' then (p->>'plantao_min')::int end,
          coalesce((p->>'intervalo_min')::int, 0), nullif(p->>'entrada', '')::time,
          (v_val->>'semanal_min')::int, v_val->'riscos', v_email, v_dsr)
  returning id into v_id;

  if jsonb_array_length(v_val->'riscos') > 0 then
    select * into v_usu from conta_membros where conta_id = fn_conta_atual() and email = v_email;
    v_texto := fn_carga_termo(p, v_val, v_email, v_instr)
      || ' Registrado em ' || to_char(v_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || ' (horário de Brasília, UTC-3).';
    insert into carga_aceites (carga_id, empresa_id, riscos, instrumento, texto, sha256, nome, email, papel, aceito_em)
    values (v_id, v_emp, v_val->'riscos', v_instr, v_texto, encode(sha256(convert_to(v_texto, 'UTF8')), 'hex'),
            coalesce(nullif(v_usu.nome, ''), v_email), v_email, fn_papel_na_conta(), v_em);
  end if;
  return v_id;
end $function$
;

-- 5. Contrair: painel_usuarios sai (o espelho da 116 vai junto) --------------------------------------------------
drop table interno.painel_usuarios;
drop function interno.fn_espelhar_conta_membro();

-- 6. Permissões (decisão 12) -------------------------------------------------------------------------------------
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
