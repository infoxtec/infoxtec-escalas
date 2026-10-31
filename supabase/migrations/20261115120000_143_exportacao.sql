-- Multiempresa F8c-1, exportação completa dos dados da conta (decisão 129; portabilidade, LGPD art. 18, V). O
-- administrador da conta (com duas etapas) ou a plataforma pedem; a Edge Function exportar-conta lê cada tabela da conta
-- em CSV, monta um ZIP (dados/<tabela>.csv, esquema.json, LEIA-ME.txt, manifesto.sha256), guarda no bucket privado
-- exportacoes e grava o resultado; o link para baixar é assinado na hora, só para quem pode, e o pacote vence em 7
-- dias. Ao encerrar a conta, sai uma exportação final e o link vai por e-mail aos administradores dela. Ficam fora:
-- segredos, hashes de código e de sessão, identificadores de pedidos internos e arquivos binários (espelhos em PDF,
-- documentos, anexos de saúde e AFD entram na F8c-2).

set lock_timeout = '5s';

create table interno.conta_exportacoes (
  id               uuid primary key default gen_random_uuid(),
  conta_id         uuid not null default interno.fn_conta_padrao() references interno.contas (id),
  pedido_por       text not null,
  origem           text not null check (origem in ('admin', 'plataforma', 'encerramento')),
  estado           text not null default 'pendente' check (estado in ('pendente', 'gerando', 'pronta', 'falhou', 'expirada')),
  criado_em        timestamptz not null default now(),
  iniciado_em      timestamptz,
  concluido_em     timestamptz,
  expira_em        timestamptz,
  tentativas       int not null default 0,
  arquivo          text,
  tamanho          bigint,
  manifesto_sha256 text check (manifesto_sha256 ~ '^[0-9a-f]{64}$'),
  baixadas         int not null default 0,
  erro             text check (length(erro) <= 300),
  unique (conta_id, id)
);
alter table interno.conta_exportacoes enable row level security;
create index conta_exportacoes_conta_idx on interno.conta_exportacoes (conta_id, criado_em desc);

-- bucket privado: só a Edge Function (chave de serviço) grava e assina
insert into storage.buckets (id, name, public) values ('exportacoes', 'exportacoes', false)
on conflict (id) do update set public = false;

insert into interno.config (chave, valor, descricao)
select 'exportacao_url', replace(c.valor, '/espelho-pdf', '/exportar-conta'), 'Edge Function que gera a exportação completa da conta'
  from interno.config c where c.chave = 'espelho_pdf_url'
on conflict (chave) do nothing;

-- o token da exportação é gravado pelo próprio banco no primeiro pedido
CREATE OR REPLACE FUNCTION interno.fn_segredo_gravar(p_nome text, p_valor text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN', 'ALERTA_EMAIL_TOKEN', 'EXPORTACAO_TOKEN')
     and p_nome !~ '^(EVOLUTION_API_KEY|WEBHOOK_TOKEN)_[0-9a-f]{32}$' then
    raise exception 'segredo não permitido';
  end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $function$
;

create or replace function interno.fn_exportacao_token_ok(p_token text)
 returns boolean
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v text := fn_segredo('EXPORTACAO_TOKEN');
begin
  return v is not null and coalesce(p_token, '') <> ''
         and extensions.digest(p_token, 'sha256') = extensions.digest(v, 'sha256');
end $function$;

-- CSV (RFC 4180): nulo vira vazio, o resto entre aspas com as aspas dobradas
create or replace function interno.fn_csv(p text)
 returns text
 language sql
 immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select case when p is null then '' else '"' || replace(p, '"', '""') || '"' end;
$function$;

-- o que entra: toda tabela do interno com conta_id, menos colunas de segredo, hash de acesso, pedido interno e binário
create or replace function interno.fn_exportar_tabelas()
 returns table (tabela text, colunas text[], chave text[])
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select c.relname::text,
         array(select a.attname::text from pg_attribute a
                where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                  and a.atttypid <> 'bytea'::regtype
                  and a.attname not in ('segredo', 'webhook_segredo', 'token_hash', 'codigo_hash', 'assinatura_chave',
                                        'envio_req', 'http_req_id', 'webhook_req', 'vig_req')
                order by a.attnum),
         array(select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum))
    from pg_class c
   where c.relnamespace = 'interno'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$;

-- põe na fila e chama a Edge Function; sem URL configurada fica pendente (homologação sem a função, banco do CI)
create or replace function interno.fn_exportar_pedir(p_conta uuid, p_autor text, p_origem text)
 returns uuid
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_url text := nullif(trim(coalesce(fn_config('exportacao_url'), '')), '');
  v_tok text;
  v_id  uuid;
begin
  perform pg_advisory_xact_lock(hashtext('exportacao:' || p_conta));
  -- o encerramento nunca é barrado pela exportação: a final sai sempre
  if p_origem <> 'encerramento' and exists (select 1 from conta_exportacoes where conta_id = p_conta and estado in ('pendente', 'gerando')
               and criado_em > now() - interval '30 minutes') then
    raise exception 'Já há uma exportação desta conta em andamento. Aguarde alguns minutos.';
  end if;
  if p_origem = 'admin' and exists (select 1 from conta_exportacoes where conta_id = p_conta and origem = 'admin'
                                      and estado = 'pronta' and criado_em > now() - interval '1 day') then
    raise exception 'Já há uma exportação de hoje. Baixe a que está pronta ou peça de novo amanhã.';
  end if;
  insert into conta_exportacoes (conta_id, pedido_por, origem) values (p_conta, p_autor, p_origem) returning id into v_id;
  if v_url is not null then
    v_tok := fn_segredo('EXPORTACAO_TOKEN');
    if v_tok is null then
      v_tok := encode(extensions.gen_random_bytes(32), 'hex');
      perform fn_segredo_gravar('EXPORTACAO_TOKEN', v_tok);
    end if;
    perform net.http_post(url := v_url,
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-exportacao-token', v_tok),
      body := jsonb_build_object('id', v_id), timeout_milliseconds := 10000);
  end if;
  return v_id;
end $function$;

-- administrador da conta da sessão, sempre com as duas etapas (é a cópia de tudo)
create or replace function public.app_conta_exportar()
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin']);
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Ative e confirme a verificação em duas etapas para exportar os dados da conta.';
  end if;
  return interno.fn_exportar_pedir(interno.fn_conta_atual(), v_email, 'admin');
end $function$;

create or replace function public.app_exportacoes()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := interno.fn_conta_atual();
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro) order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = v_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

create or replace function public.app_plataforma_exportar_conta(p_conta uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_ator text := interno.fn_exigir_plataforma();
begin
  if not exists (select 1 from interno.contas where id = p_conta and estado in ('ativa', 'encerrada')) then
    raise exception 'Conta não encontrada ou já apagada.';
  end if;
  return interno.fn_exportar_pedir(p_conta, v_ator, 'plataforma');
end $function$;

create or replace function public.app_plataforma_exportacoes(p_conta uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform interno.fn_exigir_plataforma();
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro) order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = p_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

-- Edge Function: começa um pedido (pendente, ou gerando parado há mais de 15 min) e devolve o que exportar
create or replace function interno.fn_exportacao_dados(p_token text, p_id uuid)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or e.tentativas >= 3
     or not (e.estado = 'pendente' or (e.estado = 'gerando' and e.iniciado_em < now() - interval '15 minutes')) then
    return null;
  end if;
  update conta_exportacoes set estado = 'gerando', iniciado_em = now(), tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object('conta', e.conta_id, 'origem', e.origem,
    'nome', (select nome from contas where id = e.conta_id),
    'tabelas', (select jsonb_agg(jsonb_build_object('tabela', t.tabela, 'colunas', t.colunas)) from fn_exportar_tabelas() t));
end $function$;

-- uma página de uma tabela, em linhas CSV (sem cabeçalho), só da conta do pedido, na ordem da chave primária
create or replace function interno.fn_exportar_csv(p_token text, p_id uuid, p_tabela text, p_offset int, p_limite int)
 returns text
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
  t record;
  v text;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select conta_id into v_conta from conta_exportacoes where id = p_id and estado = 'gerando';
  if v_conta is null then raise exception 'exportação fora de andamento'; end if;
  select * into t from fn_exportar_tabelas() x where x.tabela = p_tabela;
  if not found then raise exception 'tabela fora da exportação'; end if;
  execute format('select string_agg(l, E''\n'' order by n) from (select row_number() over () as n, concat_ws('','', %s) as l
                    from (select * from interno.%I where conta_id = $1 order by %s limit $2 offset $3) z) y',
                 (select string_agg(format('interno.fn_csv(z.%I::text)', c), ', ') from unnest(t.colunas) c),
                 p_tabela,
                 (select string_agg(format('%I', c), ', ') from unnest(t.chave) c))
    into v using v_conta, least(greatest(coalesce(p_limite, 5000), 1), 20000), greatest(coalesce(p_offset, 0), 0);
  return v;
end $function$;

-- resultado: pronta (vence em 7 dias) ou falhou; na final do encerramento, o link vai aos administradores da conta
create or replace function interno.fn_exportacao_resultado(p_token text, p_id uuid, p_ok boolean, p_arquivo text, p_tamanho bigint,
                                                           p_sha text, p_erro text, p_link text default null)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_para text[];
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  update conta_exportacoes set
         estado = case when p_ok then 'pronta' when tentativas >= 3 then 'falhou' else 'pendente' end,
         concluido_em = now(), expira_em = case when p_ok then now() + interval '7 days' end,
         arquivo = case when p_ok then p_arquivo end, tamanho = case when p_ok then p_tamanho end,
         manifesto_sha256 = case when p_ok then p_sha end, erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_id and estado = 'gerando' returning * into e;
  if not found or not p_ok or e.origem <> 'encerramento' or coalesce(p_link, '') !~ '^https://' then return; end if;
  select array_agg(email order by email) into v_para from conta_membros where conta_id = e.conta_id and papel = 'admin' and ativo;
  if v_para is null then return; end if;
  perform fn_alerta_email('Trilha: exportação final dos dados da sua conta',
    'A conta ' || (select nome from contas where id = e.conta_id) || ' foi encerrada no Trilha. A cópia completa dos dados '
    || 'está pronta para baixar até ' || to_char(e.expira_em at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'DD/MM/YYYY')
    || ':' || E'\n\n' || p_link || E'\n\n'
    || 'O arquivo tem uma planilha (CSV) por tabela, o dicionário dos campos (esquema.json) e o manifesto com o hash de cada '
    || 'arquivo. Os dados da conta serão apagados em ' || to_char((select apagar_em from contas where id = e.conta_id)
       at time zone coalesce(fn_config('fuso'), 'America/Bahia'), 'DD/MM/YYYY') || '. Guarde a cópia: depois disso ela não '
    || 'poderá ser gerada de novo.',
    v_para, true);
end $function$;

-- link para baixar: só quem pode (administrador ativo da conta, com duas etapas, ou a plataforma) e só antes de vencer
create or replace function interno.fn_exportacao_link(p_email text, p_aal text, p_id uuid)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if coalesce(p_aal, '') <> 'aal2' then raise exception 'Confirme a verificação em duas etapas para baixar.'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or not (exists (select 1 from plataforma_admins where email = v_email)
                       or exists (select 1 from conta_membros m join contas c on c.id = m.conta_id
                                   where m.conta_id = e.conta_id and m.email = v_email and m.papel = 'admin' and m.ativo and c.ativa)) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  if e.estado <> 'pronta' or e.expira_em <= now() then raise exception 'Exportação vencida ou ainda não pronta.'; end if;
  update conta_exportacoes set baixadas = baixadas + 1 where id = p_id;
  return e.arquivo;
end $function$;

-- pacotes vencidos: saem da lista de prontos e a Edge Function apaga os arquivos
create or replace function interno.fn_exportacoes_vencidas(p_token text)
 returns setof text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  return query
    update conta_exportacoes set estado = 'expirada' where estado = 'pronta' and expira_em <= now() and arquivo is not null
    returning arquivo;
end $function$;

create or replace function public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator   text := interno.fn_exigir_plataforma();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  c        interno.contas;
  v_sess   int;
begin
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A conta da operadora não pode ser encerrada.';
  end if;
  if length(v_motivo) not between 3 and 300 then
    raise exception 'Informe o motivo do encerramento (3 a 300 caracteres).';
  end if;
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then raise exception 'A conta já está encerrada.'; end if;
  update interno.contas set ativa = false, estado = 'encerrada', encerrada_em = now(), apagar_em = now() + interval '30 days'
   where id = p_conta returning * into c;
  -- app do ponto: sessões encerradas e códigos vencidos já agora
  update interno.ponto_sessoes s set encerrada_em = now(), motivo = 'conta encerrada'
    from interno.tecnicos t where t.id = s.tecnico_id and t.conta_id = p_conta and s.encerrada_em is null;
  get diagnostics v_sess = row_count;
  update interno.ponto_codigos k set expira_em = now()
    from interno.tecnicos t where t.id = k.tecnico_id and t.conta_id = p_conta and k.usado_em is null and k.expira_em > now();
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'encerrar_conta', p_conta, jsonb_build_object('motivo', v_motivo, 'apagar_em', c.apagar_em, 'sessoes_ponto', v_sess));
  -- exportação final automática (F8c, decisão 129): o link vai por e-mail aos administradores da conta
  perform interno.fn_exportar_pedir(p_conta, v_ator, 'encerramento');
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
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
