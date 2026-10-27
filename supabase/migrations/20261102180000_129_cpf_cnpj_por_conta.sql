-- Multiempresa F6: CPF do funcionário e CNPJ da empresa únicos por conta (antes, no sistema inteiro).
-- A mesma pessoa pode ser funcionária de dois clientes, e o aviso de duplicidade deixa de revelar dado de outra conta.
-- Login do app do ponto: o código vai para cada cadastro ativo com o CPF (com o nome da empresa) e o código digitado
-- escolhe o cadastro. O telefone continua único no sistema até a F5 (o webhook acha o funcionário por ele).

set lock_timeout = '5s';

drop index interno.tecnicos_cpf_uk;
create unique index tecnicos_conta_cpf_uk on interno.tecnicos (conta_id, cpf) where cpf is not null;
alter table interno.empresas drop constraint empresas_cnpj_key;
alter table interno.empresas add constraint empresas_conta_cnpj_key unique (conta_id, cnpj);
-- o login acha o funcionário pelo CPF sem a conta
create index tecnicos_cpf_idx on interno.tecnicos (cpf) where cpf is not null;

CREATE OR REPLACE FUNCTION public.ponto_pedir_codigo(p_cpf text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_ip   text := fn_ponto_ip();
  v_tec  record;
  v_cod  text;
  v_id   uuid := gen_random_uuid();
  v_resp jsonb := jsonb_build_object('ok', true, 'mensagem',
    'Se o CPF estiver cadastrado, você recebe o código no WhatsApp em instantes. Ele vale por 5 minutos.');
  v_aviso text;
begin
  insert into ponto_acessos (tipo, ip) values ('pedir_codigo', v_ip);
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'pedir_codigo'
                            and momento > now() - interval '1 hour') > 10 then
    return v_resp;
  end if;
  if (select count(*) from ponto_codigos where origem = 'whatsapp' and created_at > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_codigos_hora'), 60) then
    perform fn_ponto_alerta_teto('codigos');
    return v_resp;
  end if;
  if not fn_cpf_valido(v_cpf) then
    return jsonb_build_object('ok', false, 'mensagem', 'CPF inválido. Confira os 11 números.');
  end if;
  -- F6 (129): o mesmo CPF pode estar em mais de uma conta (funcionário de dois clientes); cada cadastro ativo com
  -- WhatsApp autorizado recebe o próprio código, com o nome da empresa na mensagem
  if not exists (select 1 from tecnicos where cpf = v_cpf and ativo) then
    v_aviso := 'CPF não encontrado. Confira os números ou fale com o seu gestor.';
  elsif not exists (select 1 from tecnicos where cpf = v_cpf and ativo and opt_in) then
    v_aviso := 'Seu WhatsApp ainda não foi autorizado para receber o código. Fale com o seu gestor.';
  end if;
  if v_aviso is not null then
    if fn_ponto_cpf_aviso_liberado(v_ip) then
      return jsonb_build_object('ok', false, 'mensagem', v_aviso);
    end if;
    return v_resp;
  end if;
  for v_tec in select t.id, t.telefone_e164, coalesce(e.nome_fantasia, e.razao_social) as empresa
                 from tecnicos t left join empresas e on e.id = t.empresa_id
                where t.cpf = v_cpf and t.ativo and t.opt_in order by t.id loop
    perform pg_advisory_xact_lock(hashtextextended(v_tec.id::text, 0));
    continue when (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
                     and created_at > now() - interval '15 minutes') >= 3
               or (select count(*) from ponto_codigos where tecnico_id = v_tec.id and origem = 'whatsapp'
                     and created_at > now() - interval '1 day') >= 6;

    -- só vence os códigos de WhatsApp anteriores: o código do gestor continua valendo
    update ponto_codigos set expira_em = now()
     where tecnico_id = v_tec.id and origem = 'whatsapp' and usado_em is null and expira_em > now();
    v_id := gen_random_uuid();
    v_cod := fn_ponto_novo_codigo();
    insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, expira_em)
    values (v_id, v_tec.id, fn_sha256(v_id::text || ':' || v_cod), 'whatsapp', now() + interval '5 minutes');

    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_tec.telefone_e164,
          'text', 'Trilha Ponto' || coalesce(' (' || v_tec.empresa || ')', '') || ': seu código de acesso é ' || v_cod
                  || '. Vale por 5 minutos. Não compartilhe com ninguém.'));
    exception when others then
      -- sem Evolution (homologação) ou fora do ar: o gestor gera o código de contingência no painel
      raise warning 'ponto_pedir_codigo: envio do código falhou (%)', sqlerrm;
    end;
  end loop;
  return v_resp;
end $function$
;


CREATE OR REPLACE FUNCTION public.ponto_entrar(p_cpf text, p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_cpf    text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_codigo text := regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g');
  v_ip     text := fn_ponto_ip();
  v_tec    record;
  v_tecs   uuid[];
  v_t      uuid;
  v_c      record;
  v_desde  timestamptz;
  v_token  text;
  v_restrito boolean := false;
  v_erro   jsonb := jsonb_build_object('erro', 'Não foi possível entrar. Confira o CPF e o código, ou peça um código novo.');
begin
  -- Teto total ou do IP estourado: só o código do gestor entra (ninguém trava a empresa inteira)
  if (select count(*) from ponto_acessos where tipo = 'entrar_erro' and momento > now() - interval '1 hour')
       >= coalesce(fn_config_int('ponto_max_erros_hora'), 300) then
    v_restrito := true;
    perform fn_ponto_alerta_teto('erros');
  end if;
  if v_ip is not null and (select count(*) from ponto_acessos where ip = v_ip and tipo = 'entrar_erro'
                            and momento > now() - interval '1 hour') >= 20 then
    v_restrito := true;
  end if;

  -- F6 (129): o mesmo CPF pode estar em mais de uma conta; o código digitado escolhe o cadastro (cada código é de um só)
  v_tecs := array(select t.id from tecnicos t
                   where fn_cpf_valido(v_cpf) and v_codigo ~ '^[0-9]{6}$' and t.cpf = v_cpf and t.ativo order by t.id);
  if cardinality(v_tecs) = 0 then
    insert into ponto_acessos (tipo, ip) values ('entrar_erro', v_ip);
    -- migration 114: os mesmos avisos do pedido de código, com o mesmo freio (decisão 111)
    if not fn_cpf_valido(v_cpf) then
      return jsonb_build_object('erro', 'CPF inválido. Confira os 11 números.');
    end if;
    if not exists (select 1 from tecnicos where cpf = v_cpf and ativo) and fn_ponto_cpf_aviso_liberado(v_ip) then
      return jsonb_build_object('erro', 'CPF não encontrado. Confira os números ou fale com o seu gestor.');
    end if;
    return v_erro;
  end if;

  -- uma tentativa por vez por funcionário (na mesma ordem para todos): sem corrida entre requisições paralelas
  foreach v_t in array v_tecs loop
    perform pg_advisory_xact_lock(hashtextextended(v_t::text, 0));
  end loop;

  -- 10 erros na hora no cadastro (contados depois do último código do gestor): só o código do gestor entra
  select c.* into v_c from ponto_codigos c
   where c.tecnico_id = any (v_tecs) and c.usado_em is null and c.expira_em > clock_timestamp() and c.tentativas < 5
     and c.codigo_hash = fn_sha256(c.id::text || ':' || v_codigo)
     and (c.origem = 'gestor' or not (v_restrito or (
           select count(*) from ponto_acessos a
            where a.tecnico_id = c.tecnico_id and a.tipo = 'entrar_erro'
              and a.momento > greatest(now() - interval '1 hour',
                                       coalesce((select max(g.created_at) from ponto_codigos g
                                                  where g.tecnico_id = c.tecnico_id and g.origem = 'gestor'), '-infinity'))) >= 10))
   order by c.created_at desc limit 1 for update;
  if v_c.id is null then
    -- erro gasta as tentativas só do código de WhatsApp: ninguém esgota o código do gestor de fora
    -- (ele vale 15 min e continua sob os limites por IP e total)
    update ponto_codigos set tentativas = tentativas + 1,
           expira_em = case when tentativas + 1 >= 5 then now() else expira_em end
     where tecnico_id = any (v_tecs) and origem = 'whatsapp' and usado_em is null and expira_em > clock_timestamp();
    insert into ponto_acessos (tipo, ip, tecnico_id) select 'entrar_erro', v_ip, x from unnest(v_tecs) x;
    return v_erro;
  end if;

  select t.id, t.nome, e.razao_social, e.nome_fantasia into v_tec
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = v_c.tecnico_id;

  update ponto_codigos set usado_em = now() where id = v_c.id;
  update ponto_sessoes set encerrada_em = now(), motivo = 'novo login'
   where tecnico_id = v_tec.id and encerrada_em is null;
  v_token := encode(gen_random_bytes(32), 'hex');
  insert into ponto_sessoes (tecnico_id, token_hash, expira_em, codigo_id, criado_por, login_origem)
  values (v_tec.id, fn_sha256(v_token), now() + interval '12 hours', v_c.id, v_c.criado_por, v_c.origem);
  insert into ponto_acessos (tipo, ip, tecnico_id) values ('entrar_ok', v_ip, v_tec.id);

  return jsonb_build_object('token', v_token, 'nome', v_tec.nome,
    'empresa', coalesce(v_tec.nome_fantasia, v_tec.razao_social), 'expira_em', now() + interval '12 hours');
end $function$
;


CREATE OR REPLACE FUNCTION public.app_salvar_tecnico(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  -- CPF e matrícula são únicos na conta (129); o telefone ainda é único no sistema (o webhook acha o funcionário
  -- por ele) até a F5: a mensagem não diz em qual conta
  raise exception 'Já existe um técnico com este CPF ou esta matrícula na empresa, ou este telefone já está em uso.';
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
