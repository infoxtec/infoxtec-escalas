-- Migration 151: recuperação das duas etapas entre contas (B3, revisão da decisão 128, cenário A do responsável).
-- Desenho revisado antes do código pelo arquiteto-dados e pelo seguranca.
--
-- O autenticador é um só por login, mas o WhatsApp de recuperação é cadastrado por conta, pelo admin de cada uma.
-- Regra nova (interno.fn_mfa_recuperacao_regra):
--   plataforma ou administrador ativo de conta ativa -> 'dois'     (e-mail E WhatsApp)
--   membro de 2 ou mais empresas (ativo ou não, empresa ativa ou suspensa) -> 'email' (o WhatsApp de uma não destrava as outras)
--   demais                                           -> 'qualquer' (e-mail OU WhatsApp, como antes)
-- A regra NÃO depende de mfa_obrigatorio nem de mfa_obrigatorio_admin: desligar a obrigatoriedade numa emergência não
-- afrouxa a recuperação. O WhatsApp só sai de conta ativa (conta suspensa ou encerrada não destrava mais nada), e o do
-- administrador só das contas em que ele é administrador (o admin de outra conta não interfere nem trava).
-- Diferença proposital: 'dois' usa o predicado do fn_mfa_exigido (admin ativo de conta ativa, para não travar ex-admin);
-- 'email' conta também o vínculo desativado e a conta suspensa (uma desativação temporária não abre a janela do WhatsApp).

set lock_timeout = '5s';

create or replace function interno.fn_mfa_recuperacao_regra(p_email text)
 returns text
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select case
    when exists (select 1 from interno.plataforma_admins pa where pa.email = lower(btrim(p_email))) then 'dois'
    -- o mesmo predicado de administrador do fn_mfa_exigido (migration 149), sem o interruptor
    when exists (select 1 from interno.conta_membros m join interno.contas c on c.id = m.conta_id
                  where m.email = lower(btrim(p_email)) and m.ativo and m.papel = 'admin' and c.ativa) then 'dois'
    when (select count(*) from interno.conta_membros m join interno.contas c on c.id = m.conta_id
           where m.email = lower(btrim(p_email)) and c.estado = 'ativa') >= 2 then 'email'
    else 'qualquer'
  end
$function$;

-- o que a tela do código mostra (Edge, ação 'regra'): só informa; quem decide é o confirmar
create or replace function interno.fn_mfa_recuperacao_tela(p_email text)
 returns jsonb
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select jsonb_build_object(
    'acesso', exists (select 1 from interno.conta_membros where email = lower(btrim(p_email)) and ativo)
              or exists (select 1 from interno.plataforma_admins where email = lower(btrim(p_email))),
    'regra', interno.fn_mfa_recuperacao_regra(p_email))
$function$;

create or replace function interno.fn_mfa_recuperacao_pedir(p_email text, p_canal text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_tels text[];
  v_conta uuid;
  v_cod text;
  v_id uuid := gen_random_uuid();
  v_plat boolean;
  v_regra text;
begin
  if p_canal not in ('email', 'whatsapp') then raise exception 'Escolha e-mail ou WhatsApp.'; end if;
  if not exists (select 1 from conta_membros where email = v_email and ativo)
     and not exists (select 1 from plataforma_admins where email = v_email) then
    raise exception 'Usuário sem acesso ao painel.';
  end if;
  perform pg_advisory_xact_lock(hashtext('mfa_recuperacao:' || v_email));
  v_plat := exists (select 1 from plataforma_admins where email = v_email);
  v_regra := fn_mfa_recuperacao_regra(v_email);
  perform fn_mfa_limpar_envios(v_email);
  delete from mfa_recuperacoes where criado_em < now() - interval '1 year';
  -- recusa pela regra antes de qualquer conta de cota
  if p_canal = 'whatsapp' and v_regra = 'email' then
    raise exception 'Como você usa o Trilha em mais de uma empresa, a troca do autenticador é só pelo e-mail do login.';
  end if;
  -- 6 pedidos por dia por canal (na regra 'dois' cada tentativa usa os dois)
  if (select count(*) from mfa_recuperacoes where email = v_email and canal = p_canal and criado_em > now() - interval '1 day') >= 6 then
    raise exception 'Muitos pedidos hoje. Tente amanhã ou fale com o suporte.';
  end if;
  if exists (select 1 from mfa_recuperacoes where email = v_email and canal = p_canal and criado_em > now() - interval '1 minute') then
    raise exception 'Código enviado há pouco. Aguarde um minuto.';
  end if;
  if p_canal = 'whatsapp' then
    if v_plat then
      -- quem é da plataforma só recupera pelo número cadastrado na conta da operadora (o admin de um cliente não troca)
      select array_agg(distinct m.telefone_e164) into v_tels from conta_membros m join contas c on c.id = m.conta_id and c.ativa
       where m.email = v_email and m.ativo and m.telefone_e164 is not null
         and m.conta_id = '00000000-0000-0000-0000-000000000001';
    elsif v_regra = 'dois' then
      -- administrador: só o número das contas em que ele é administrador (cadastrado por ele ou por outro admin dela)
      select array_agg(distinct m.telefone_e164) into v_tels from conta_membros m join contas c on c.id = m.conta_id and c.ativa
       where m.email = v_email and m.ativo and m.papel = 'admin' and m.telefone_e164 is not null;
    else
      select array_agg(distinct m.telefone_e164) into v_tels from conta_membros m join contas c on c.id = m.conta_id and c.ativa
       where m.email = v_email and m.ativo and m.telefone_e164 is not null;
    end if;
    if v_tels is null then
      raise exception '%', case when v_plat
        then 'Nenhum WhatsApp cadastrado para você na conta da operadora. Fale com o suporte.'
        when v_regra = 'dois'
        then 'Administrador precisa também do código pelo WhatsApp. Peça a outro administrador da sua empresa para cadastrar o seu número na tela Usuários, ou fale com o suporte.'
        else 'Nenhum WhatsApp cadastrado para você. Use o e-mail ou peça ao administrador.' end;
    end if;
    if cardinality(v_tels) > 1 then
      raise exception '%', case when v_regra = 'dois'
        then 'Seu WhatsApp de recuperação está diferente entre as empresas que você administra. Peça para deixarem o mesmo número, ou fale com o suporte.'
        else 'Há mais de um WhatsApp cadastrado para você. Use o e-mail.' end;
    end if;
    select m.conta_id into v_conta from conta_membros m join contas c on c.id = m.conta_id and c.ativa
     where m.email = v_email and m.ativo and m.telefone_e164 = v_tels[1]
       and (v_regra <> 'dois' or v_plat or m.papel = 'admin')
     order by m.conta_id = '00000000-0000-0000-0000-000000000001' desc limit 1;
  end if;
  -- um pedido novo anula os códigos anteriores do mesmo canal
  update mfa_recuperacoes set expira_em = least(expira_em, now())
   where email = v_email and canal = p_canal and usado_em is null and expira_em > now();
  v_cod := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into mfa_recuperacoes (id, email, canal, codigo_hash, expira_em)
  values (v_id, v_email, p_canal, encode(extensions.digest(v_id::text || ':' || v_cod, 'sha256'), 'hex'), now() + interval '10 minutes');
  if p_canal = 'email' then
    perform fn_alerta_email('Trilha: código para trocar a verificação em duas etapas',
      'Seu código para trocar a verificação em duas etapas do Trilha é ' || v_cod || '. Ele vale por 10 minutos.' || E'\n\n'
      || 'Se não foi você quem pediu, ignore este e-mail e troque a sua senha: alguém pode estar tentando entrar com ela.',
      array[v_email], true);
  else
    update mfa_recuperacoes set envio_req = fn_evo_post_na_conta(v_conta, '/message/sendText/' || fn_config('evolution_instancia'),
      jsonb_build_object('number', v_tels[1], 'text',
        '🔐 Trilha: seu código para trocar a verificação em duas etapas é *' || v_cod || '* (vale 10 minutos). '
        || 'Se não foi você, troque a sua senha.'))
     where id = v_id;
  end if;
  return jsonb_build_object('enviado', p_canal,
    'destino', case when p_canal = 'email' then regexp_replace(v_email, '^(.)[^@]*', '\1***')
                    else '***' || right(v_tels[1], 4) end);
end $function$;

create or replace function interno.fn_mfa_recuperacao_confirmar(p_email text, p_codigo_email text, p_codigo_whatsapp text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_regra text;
  v_ok_email boolean := false;
  v_ok_whats boolean := false;
  v_user uuid;
begin
  perform pg_advisory_xact_lock(hashtext('mfa_recuperacao:' || v_email));
  perform fn_mfa_limpar_envios(v_email);
  if not exists (select 1 from conta_membros where email = v_email and ativo)
     and not exists (select 1 from plataforma_admins where email = v_email) then
    return jsonb_build_object('erro', 'Usuário sem acesso ao painel.');
  end if;
  -- a regra é recalculada aqui, depois da trava: vale o estado de agora, não o do pedido
  v_regra := fn_mfa_recuperacao_regra(v_email);
  v_ok_email := fn_mfa_codigo_ok(v_email, 'email', p_codigo_email);
  if v_regra = 'email' then
    -- o código do WhatsApp não conta nem é marcado como usado (nem gasta tentativa)
    if not v_ok_email then
      return jsonb_build_object('erro', case when coalesce(btrim(p_codigo_email), '') = ''
        then 'Como você usa o Trilha em mais de uma empresa, confirme o código do e-mail do login.' else 'Código errado ou vencido.' end);
    end if;
  else
    v_ok_whats := fn_mfa_codigo_ok(v_email, 'whatsapp', p_codigo_whatsapp);
    if v_regra = 'dois' and not (v_ok_email and v_ok_whats) then
      return jsonb_build_object('erro', 'Confirme os códigos do e-mail e do WhatsApp.');
    end if;
    if not (v_ok_email or v_ok_whats) then return jsonb_build_object('erro', 'Código errado ou vencido.'); end if;
  end if;
  select id into v_user from auth.users where lower(email) = v_email limit 1;
  if v_user is null then return jsonb_build_object('erro', 'Usuário sem acesso ao painel.'); end if;
  return jsonb_build_object('usuario', v_user, 'email_ok', v_ok_email, 'whatsapp_ok', v_ok_whats, 'regra', v_regra);
end $function$;

-- o aviso à plataforma diz qual regra valia
create or replace function interno.fn_mfa_recuperacao_concluir(p_email text, p_email_ok boolean, p_whatsapp_ok boolean)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_canais text := concat_ws(' e ', case when p_email_ok then 'e-mail' end, case when p_whatsapp_ok then 'WhatsApp' end);
  v_fuso text := coalesce(fn_config('fuso'), 'America/Bahia');
begin
  perform pg_advisory_xact_lock(hashtext('mfa_recuperacao:' || v_email));
  update mfa_recuperacoes set usado_em = now()
   where email = v_email and usado_em is null and expira_em > now()
     and ((canal = 'email' and p_email_ok) or (canal = 'whatsapp' and p_whatsapp_ok));
  perform fn_alerta_email('Trilha: sua verificação em duas etapas foi trocada',
    'A verificação em duas etapas do seu login no Trilha (' || v_email || ') foi removida às '
    || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI') || ', com código pelo ' || v_canais || '.' || E'\n\n'
    || 'Cadastre o aplicativo autenticador novo no próximo acesso. Se não foi você, troque a senha e avise o suporte agora.',
    array[v_email]);
  perform fn_alerta_email('Trilha: verificação em duas etapas trocada (' || left(v_email, 80) || ')',
    'O login ' || v_email || ' removeu a verificação em duas etapas às ' || to_char(now() at time zone v_fuso, 'DD/MM HH24:MI')
    || ', com código pelo ' || v_canais || ' (regra: ' || fn_mfa_recuperacao_regra(v_email) || ').');
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
