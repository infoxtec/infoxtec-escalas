-- 39 | Trava de ambiente: em homologacao, so fala com cadastro de teste.
-- Em producao nada muda (ambiente = 'producao' libera todos os numeros).
-- A trava mora no banco de proposito: um ambiente local apontado por engano para as
-- credenciais de producao ainda assim nao consegue mandar mensagem para tecnico real.

insert into config (chave, valor, descricao) values
  ('ambiente', 'producao',
   'producao | homologacao. Em homologacao so envia para tecnico com perfil_teste ou numero liberado.'),
  ('telefones_homologacao', '',
   'Numeros extras liberados em homologacao, separados por virgula, so digitos. Ex: 5571999998888')
on conflict (chave) do nothing;

create or replace function fn_pode_enviar(p_telefone text)
returns boolean language plpgsql stable
set search_path = public, extensions as $$
declare
  v_tel  text := fn_tel_canonico(p_telefone);
  v_lista text := coalesce(fn_config('telefones_homologacao'), '');
begin
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    return true;
  end if;
  -- tecnico marcado como perfil de teste
  if exists (select 1 from tecnicos where perfil_teste and fn_tel_canonico(telefone_e164) = v_tel) then
    return true;
  end if;
  -- numero liberado manualmente na configuracao
  return exists (
    select 1 from unnest(string_to_array(v_lista, ',')) x
    where fn_tel_canonico(trim(x)) = v_tel and trim(x) <> '');
end $$;

-- Porta unica de saida do WhatsApp: o numero esta sempre no corpo da requisicao
create or replace function fn_evo_post(p_path text, p_body jsonb)
returns bigint language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_key  text := fn_segredo('EVOLUTION_API_KEY');
  v_num  text := p_body ->> 'number';
begin
  if v_key is null then
    raise exception 'EVOLUTION_API_KEY nao encontrada no Vault';
  end if;

  if v_num is not null and not fn_pode_enviar(v_num) then
    raise warning 'HOMOLOGACAO: envio bloqueado para % (nao e cadastro de teste)', v_num;
    return null;
  end if;

  return net.http_post(
    url     := fn_config('evolution_url') || p_path,
    headers := jsonb_build_object('apikey', v_key, 'Content-Type', 'application/json'),
    body    := p_body
  );
end $$;

-- Ligacao: bloqueia antes de registrar a tentativa, com mensagem clara no painel
create or replace function fn_preparar_ligacao(p_escala uuid)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A escala já foi respondida (%).', v_esc.status; end if;

  if not fn_pode_enviar(v_esc.telefone_e164) then
    raise exception 'Ambiente de homologação: só é possível ligar para cadastros de teste. % não é um.', v_esc.nome;
  end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
end $$;

-- Mostra o ambiente no painel, para ninguem confundir as telas
create or replace function app_config()
returns jsonb language plpgsql stable security definer
set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  return (select jsonb_object_agg(chave, valor) from config
          where chave in ('jornada_min','intervalo_min','intervalo_apos_min','noturno_inicio',
                          'noturno_fim','hora_noturna_min','alerta_escala_aviso','alerta_escala_prazo',
                          'alerta_dias_semana','ambiente'));
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
