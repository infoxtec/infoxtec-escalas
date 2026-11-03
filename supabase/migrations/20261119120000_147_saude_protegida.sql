-- Saúde protegida (pedido do responsável em 03/11; requisitos do seguranca, reunião de 03/11, decisão 131). O pacote de
-- saúde deixa de ser gerado junto com a exportação e guardado por 7 dias: passa a ser um download na hora, por pessoa.
-- Para baixar, o administrador da conta com ve_saude (nunca a plataforma nem o papel leitura) (1) aceita o termo de
-- confidencialidade da versão vigente (aceite gravado sem alteração possível: e-mail, versão, hash do texto, IP, hora);
-- (2) digita o código do autenticador na hora: a Edge Function confere no próprio token que a verificação TOTP tem no
-- máximo 5 minutos; (3) o banco autoriza e registra o download (limite de 5 por pessoa em 24 h); (4) a Edge Function
-- monta o ZIP com marca d'água em cada atestado e ASO (quem, quando, código do download), devolve um link de 60 s e o
-- arquivo é apagado em 15 minutos. Cada anexo decifrado fica em ponto_anexo_acessos.

set lock_timeout = '5s';

-- termos (da plataforma, versionados); o aceite é da pessoa na conta
create table interno.saude_termos (
  versao        int primary key,
  texto         text not null,
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  vigente_desde timestamptz not null default now()
);
alter table interno.saude_termos enable row level security;
insert into interno.saude_termos (versao, texto, sha256)
values (1, $termo$Termo de sigilo: dados de saúde dos funcionários

1. Só para o que a lei pede. Uso estes dados apenas para cumprir obrigações trabalhistas e legais e para a gestão da saúde ocupacional dos funcionários da própria empresa (LGPD, art. 11).
2. Só com quem precisa. Não mostro, envio nem repasso estes dados a quem não precise deles para essa finalidade, dentro ou fora da empresa. Não procuro saber o diagnóstico além do que o documento já traz.
3. Sem cópia desprotegida. Não copio, fotografo nem guardo estes arquivos em e-mail pessoal, WhatsApp, pen drive, nuvem particular ou qualquer outro meio sem proteção.
4. Sem discriminação. Não uso estes dados para decidir contratação, promoção, dispensa ou qualquer tratamento desigual (Lei 9.029/1995; LGPD, art. 6º, IX).
5. Guarda e descarte. Guardo os arquivos só no local protegido que a empresa indicar, pelo prazo que a lei exigir. Apago as cópias baixadas quando a finalidade terminar (LGPD, arts. 15 e 16).
6. Tudo fica registrado. Cada download registra meu nome, e-mail, data, hora e código. Cada arquivo sai com marca d'água que mostra quem baixou (LGPD, art. 37).
7. Sigilo permanente. Mantenho o sigilo mesmo depois de sair do cargo ou da empresa (LGPD, arts. 46 e 47).
8. Aviso imediato. Aviso na hora o encarregado de dados (DPO) da empresa se houver perda, acesso indevido, suspeita de vazamento ou perda do aparelho com o autenticador (LGPD, art. 48).
9. Responsabilidade. Sei que o uso indevido ou o vazamento pode gerar responsabilidade para a empresa (LGPD, arts. 42 e 52) e para mim, conforme a lei.

Li e aceito este termo. Comprometo-me a usar os dados de saúde só para as finalidades acima e a manter o sigilo.$termo$, encode(sha256(convert_to($termo$Termo de sigilo: dados de saúde dos funcionários

1. Só para o que a lei pede. Uso estes dados apenas para cumprir obrigações trabalhistas e legais e para a gestão da saúde ocupacional dos funcionários da própria empresa (LGPD, art. 11).
2. Só com quem precisa. Não mostro, envio nem repasso estes dados a quem não precise deles para essa finalidade, dentro ou fora da empresa. Não procuro saber o diagnóstico além do que o documento já traz.
3. Sem cópia desprotegida. Não copio, fotografo nem guardo estes arquivos em e-mail pessoal, WhatsApp, pen drive, nuvem particular ou qualquer outro meio sem proteção.
4. Sem discriminação. Não uso estes dados para decidir contratação, promoção, dispensa ou qualquer tratamento desigual (Lei 9.029/1995; LGPD, art. 6º, IX).
5. Guarda e descarte. Guardo os arquivos só no local protegido que a empresa indicar, pelo prazo que a lei exigir. Apago as cópias baixadas quando a finalidade terminar (LGPD, arts. 15 e 16).
6. Tudo fica registrado. Cada download registra meu nome, e-mail, data, hora e código. Cada arquivo sai com marca d'água que mostra quem baixou (LGPD, art. 37).
7. Sigilo permanente. Mantenho o sigilo mesmo depois de sair do cargo ou da empresa (LGPD, arts. 46 e 47).
8. Aviso imediato. Aviso na hora o encarregado de dados (DPO) da empresa se houver perda, acesso indevido, suspeita de vazamento ou perda do aparelho com o autenticador (LGPD, art. 48).
9. Responsabilidade. Sei que o uso indevido ou o vazamento pode gerar responsabilidade para a empresa (LGPD, arts. 42 e 52) e para mim, conforme a lei.

Li e aceito este termo. Comprometo-me a usar os dados de saúde só para as finalidades acima e a manter o sigilo.$termo$, 'UTF8')), 'hex'));

create table interno.saude_termo_aceites (
  id        bigint generated always as identity primary key,
  conta_id  uuid not null default interno.fn_conta_padrao() references interno.contas (id),
  email     text not null,
  versao    int not null references interno.saude_termos (versao),
  sha256    text not null,
  ip        text,
  aceito_em timestamptz not null default now(),
  unique (conta_id, email, versao)
);
alter table interno.saude_termo_aceites enable row level security;
create or replace function interno.fn_saude_aceite_imutavel()
 returns trigger
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  raise exception 'O termo de confidencialidade e os aceites são imutáveis (prova de auditoria). Versão nova é linha nova.';
end $function$;
create trigger trg_saude_termo_aceites_imutavel before update or delete on interno.saude_termo_aceites
  for each row execute function interno.fn_saude_aceite_imutavel();
create trigger trg_saude_termo_aceites_sem_truncate before truncate on interno.saude_termo_aceites
  for each statement execute function interno.fn_saude_aceite_imutavel();
create trigger trg_saude_termos_imutavel before update or delete on interno.saude_termos
  for each row execute function interno.fn_saude_aceite_imutavel();
create trigger trg_saude_termos_sem_truncate before truncate on interno.saude_termos
  for each statement execute function interno.fn_saude_aceite_imutavel();

create table interno.saude_downloads (
  id             uuid primary key default gen_random_uuid(),
  conta_id       uuid not null default interno.fn_conta_padrao() references interno.contas (id),
  email          text not null,
  termo_versao   int not null references interno.saude_termos (versao),
  autenticado_em timestamptz not null,   -- hora da verificação TOTP vista no token
  ip             text,
  criado_em      timestamptz not null default now(),
  estado         text not null default 'gerando' check (estado in ('gerando', 'pronto', 'falhou', 'expirando', 'expirado')),
  arquivo        text,
  tamanho        bigint,
  sha256         text,
  anexos         int,
  erro           text check (length(erro) <= 300),
  unique (conta_id, id)
);
alter table interno.saude_downloads enable row level security;
create index saude_downloads_email_idx on interno.saude_downloads (conta_id, email, criado_em desc);
create index saude_downloads_estado_idx on interno.saude_downloads (estado, criado_em) where estado in ('gerando', 'pronto', 'falhou', 'expirando');

-- o termo vigente e se a pessoa já aceitou (só administrador com ve_saude)
create or replace function public.app_saude_termo()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin']); t interno.saude_termos;
begin
  if not interno.fn_ve_saude(v_email) then raise exception 'Sem permissão para ver dados de saúde.'; end if;
  select * into t from interno.saude_termos order by versao desc limit 1;
  return jsonb_build_object('versao', t.versao, 'texto', t.texto,
    'aceito', exists (select 1 from interno.saude_termo_aceites a where a.conta_id = interno.fn_conta_atual() and a.email = v_email
                        and a.versao = t.versao));
end $function$;

create or replace function public.app_saude_aceitar_termo(p_versao int)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin']); t interno.saude_termos;
begin
  if not interno.fn_ve_saude(v_email) then raise exception 'Sem permissão para ver dados de saúde.'; end if;
  select * into t from interno.saude_termos order by versao desc limit 1;
  if t.versao is distinct from p_versao then raise exception 'O termo mudou. Leia a versão nova antes de aceitar.'; end if;
  insert into interno.saude_termo_aceites (conta_id, email, versao, sha256, ip)
  values (interno.fn_conta_atual(), v_email, t.versao, t.sha256, interno.fn_ponto_ip())
  on conflict (conta_id, email, versao) do nothing;
end $function$;

-- Edge Function: autoriza e registra o download (a conta vem do cabeçalho x-conta e é conferida aqui)
create or replace function interno.fn_saude_download_autorizar(p_email text, p_aal text, p_totp_em timestamptz, p_conta uuid, p_ip text)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  t saude_termos;
  v_id uuid;
begin
  if coalesce(p_aal, '') <> 'aal2' or p_totp_em is null or p_totp_em < now() - interval '5 minutes' or p_totp_em > now() + interval '1 minute' then
    raise exception 'Digite o código do autenticador para baixar os dados de saúde.';
  end if;
  if not exists (select 1 from conta_membros m join contas c on c.id = m.conta_id
                  where m.conta_id = p_conta and m.email = v_email and m.ativo and m.papel = 'admin' and m.ve_saude and c.ativa) then
    raise exception 'Sem permissão para ver dados de saúde.';
  end if;
  select * into t from saude_termos order by versao desc limit 1;
  if not exists (select 1 from saude_termo_aceites a where a.conta_id = p_conta and a.email = v_email and a.versao = t.versao) then
    raise exception 'Aceite o termo de confidencialidade antes de baixar.';
  end if;
  perform pg_advisory_xact_lock(hashtext('saude_download:' || p_conta::text || ':' || v_email));
  if (select count(*) from saude_downloads where conta_id = p_conta and email = v_email and criado_em > now() - interval '24 hours') >= 5 then
    raise exception 'Limite de 5 downloads de saúde em 24 horas atingido.';
  end if;
  insert into saude_downloads (conta_id, email, termo_versao, autenticado_em, ip)
  values (p_conta, v_email, t.versao, p_totp_em, p_ip) returning id into v_id;
  return jsonb_build_object('id', v_id, 'conta', p_conta, 'nome', (select nome from contas where id = p_conta),
    'quem', coalesce((select nullif(nome, '') from conta_membros where conta_id = p_conta and email = v_email), v_email),
    'csv', fn_saude_csv(p_conta),
    'anexos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo,
        'nome', 'saude/anexos/' || left(x.justificativa_id::text, 8) || '_' || left(x.id::text, 8) || '.pdf') order by x.created_at)
      from ponto_justificativa_anexos x where x.conta_id = p_conta), '[]'::jsonb),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('caminho', d.caminho, 'mime', d.mime,
        'nome', 'saude/documentos/' || left(d.id::text, 8) || '_' || regexp_replace(coalesce(d.nome_arquivo, 'arquivo'), '[^A-Za-z0-9._-]+', '_', 'g'))
        order by d.created_at)
      from documentos d join tipos_documento tp on tp.id = d.tipo_documento_id
     where d.conta_id = p_conta and d.caminho is not null and tp.saude), '[]'::jsonb));
end $function$;

create or replace function interno.fn_saude_csv(p_conta uuid)
 returns text
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select E'\ufeffid,numero,funcionario,tecnico_id,motivo,motivo_nome,data,data_fim,observacao,status,resposta,decidido_por,decidido_em,criado_em\r\n'
         || coalesce(string_agg(concat_ws(',', fn_csv(j.id::text), fn_csv(j.numero::text), fn_csv(fn_csv_texto(t.nome)), fn_csv(j.tecnico_id::text),
              fn_csv(j.motivo), fn_csv(fn_csv_texto(m.nome)), fn_csv(j.data::text), fn_csv(j.data_fim::text), fn_csv(fn_csv_texto(j.observacao)),
              fn_csv(j.status), fn_csv(fn_csv_texto(j.resposta)), fn_csv(fn_csv_texto(j.decidido_por)), fn_csv(j.decidido_em::text),
              fn_csv(j.created_at::text)), E'\r\n' order by j.data, j.numero) || E'\r\n', '')
    from ponto_justificativas j join ponto_motivos m on m.codigo = j.motivo join tecnicos t on t.id = j.tecnico_id
   where j.conta_id = p_conta and m.saude;
$function$;

-- um anexo decifrado, só durante o download autorizado (até 10 min), e o acesso registrado
create or replace function interno.fn_saude_anexo(p_download uuid, p_anexo uuid)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare g saude_downloads; x ponto_justificativa_anexos;
begin
  select * into g from saude_downloads where id = p_download and estado = 'gerando' and criado_em > now() - interval '10 minutes';
  if not found then raise exception 'download fora de andamento'; end if;
  select * into x from ponto_justificativa_anexos where id = p_anexo and conta_id = g.conta_id;
  if not found then return null; end if;
  insert into ponto_anexo_acessos (anexo_id, justificativa_id, sha256, email, conta_id)
  values (x.id, x.justificativa_id, x.sha256, 'download de saúde ' || g.email || ' (' || left(g.id::text, 8) || ')', g.conta_id);
  return encode(fn_ponto_cofre_decifrar(x.conteudo), 'base64');
end $function$;

create or replace function interno.fn_saude_resultado(p_download uuid, p_ok boolean, p_arquivo text, p_tamanho bigint, p_sha text,
                                                      p_anexos int, p_erro text)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  update saude_downloads set estado = case when p_ok then 'pronto' else 'falhou' end,
         arquivo = case when p_ok then p_arquivo end, tamanho = p_tamanho, sha256 = p_sha, anexos = p_anexos,
         erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_download and estado = 'gerando';
end $function$;

-- arquivos de saúde com mais de 15 minutos: a Edge Function apaga e confirma
create or replace function interno.fn_saude_vencidos(p_token text)
 returns table (id uuid, arquivo text)
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  return query update saude_downloads s set estado = 'expirando'
    -- também 'gerando' e 'falhou': o zip pode ter subido sem o resultado gravado; o caminho é previsível
    where s.estado in ('gerando', 'pronto', 'falhou', 'expirando') and s.criado_em < now() - interval '15 minutes'
    returning s.id, coalesce(s.arquivo, s.conta_id::text || '/saude/' || s.id::text || '.zip');
end $function$;

create or replace function interno.fn_saude_apagados(p_token text, p_ids uuid[])
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  update saude_downloads set estado = 'expirado' where id = any (p_ids) and estado = 'expirando';
end $function$;

-- as tabelas novas entram na lista branca da exportação (registro de aceite e de acesso, sem conteúdo de saúde)
CREATE OR REPLACE FUNCTION interno.fn_exportar_tabelas()
 RETURNS TABLE(tabela text, colunas text[], chave text[], folha text[])
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
  -- lista branca (auditoria de 01/11): só entra a tabela listada aqui; tabela nova com conta_id fica fora até ser
  -- classificada nesta lista (o T85 recusa tabela de conta sem classificação). 'folha' são as colunas que só saem para
  -- quem tem rh_folhas (o espelho assinado); para os outros, vão vazias
  with lista(tabela) as (values
      ('alertas_enviados'),
      ('carga_aceites'),
      ('carga_atribuicoes'),
      ('cargas_horarias'),
      ('conta_canais'),
      ('conta_exportacao_baixas'),
      ('conta_exportacoes'),
      ('conta_membros'),
      ('conta_modulos'),
      ('convites'),
      ('documentos'),
      ('dossie_geracoes'),
      ('empresas'),
      ('escala_eventos'),
      ('escalas'),
      ('habilidades'),
      ('ligacoes'),
      ('locais'),
      ('log_exclusoes'),
      ('notificacoes'),
      ('ocorrencias'),
      ('painel_mfa_log'),
      ('painel_rh_folhas_log'),
      ('painel_ve_saude_log'),
      ('ponto_abonos'),
      ('ponto_acessos'),
      ('ponto_afd_geracoes'),
      ('ponto_ajustes'),
      ('ponto_anexo_acessos'),
      ('ponto_anexos_descartados'),
      ('ponto_ciencias'),
      ('ponto_codigos'),
      ('ponto_conversas'),
      ('ponto_documento_registros'),
      ('ponto_documento_sequencia'),
      ('ponto_documento_verificacoes'),
      ('ponto_espelho_acessos'),
      ('ponto_espelho_pdfs'),
      ('ponto_espelho_sequencia'),
      ('ponto_espelhos'),
      ('ponto_folha_fechamentos'),
      ('ponto_he_autorizacoes'),
      ('ponto_justificativa_anexos'),
      ('ponto_justificativas'),
      ('ponto_marcacoes'),
      ('ponto_nsr'),
      ('ponto_sessoes'),
      ('programacao_aceites'),
      ('respostas'),
      ('saude_downloads'),
      ('saude_termo_aceites'),
      ('tecnico_documentos'),
      ('tecnico_habilidades'),
      ('tecnicos'),
      ('times'),
      ('tipo_atividade_documentos'),
      ('tipo_atividade_requisitos'),
      ('tipos_atividade'),
      ('tipos_documento'),
      ('usuarios_excluidos'),
      ('webhook_eventos'))
  select c.relname::text,
         array(select a.attname::text from pg_attribute a
                where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                  and a.atttypid <> 'bytea'::regtype
                  and a.attname not in ('segredo', 'webhook_segredo', 'token_hash', 'codigo_hash', 'assinatura_chave',
                                        'envio_req', 'http_req_id', 'webhook_req', 'vig_req')
                  and not (c.relname = 'ponto_conversas' and a.attname = 'dados')   -- pedido em andamento (pode ser de saúde)
                  and not (c.relname = 'conta_canais' and a.attname in ('url', 'instancia'))   -- endereço do nosso servidor
                order by a.attnum),
         array(select a.attname::text from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any (i.indkey)
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum)),
         case when c.relname = 'ponto_espelhos'
              then array['conteudo', 'conteudo_texto', 'assinatura_png', 'assinatura_origem', 'assinatura_sha256']
              else '{}'::text[] end
    from lista l join pg_class c on c.relname = l.tabela and c.relnamespace = 'interno'::regnamespace
   where c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$
;

-- o pacote de saúde da exportação deixa de existir
CREATE OR REPLACE FUNCTION public.app_conta_exportar()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_email text := app_exigir(array['admin']);
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'Ative e confirme a verificação em duas etapas para exportar os dados da conta.';
  end if;
  return interno.fn_exportar_pedir(interno.fn_conta_atual(), v_email, 'admin', false, interno.fn_rh_folhas(v_email));   -- saúde: só pelo download protegido (migration 147)
end $function$
;

CREATE OR REPLACE FUNCTION public.app_exportacoes()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_email text := app_exigir(array['admin']); v_conta uuid; v_saude boolean; v_folha boolean;
begin
  v_conta := interno.fn_conta_atual();
  v_saude := interno.fn_ve_saude(v_email);
  v_folha := interno.fn_rh_folhas(v_email);
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro,
      'pode_baixar', v_folha or not e.com_folha,   -- o pacote com o espelho assinado só para quem tem rh_folhas
      'saude', false, 'tamanho_saude', null,
      'baixas', (select count(*) from interno.conta_exportacao_baixas b where b.conta_id = e.conta_id and b.exportacao_id = e.id))
      order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = v_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportacao_link(p_email text, p_aal text, p_id uuid, p_saude boolean DEFAULT false)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  e conta_exportacoes;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_admin boolean;
  v_plat  boolean;
begin
  if coalesce(p_aal, '') <> 'aal2' then raise exception 'Confirme a verificação em duas etapas para baixar.'; end if;
  -- o pacote de saúde guardado deixou de existir: saúde só pelo download protegido (termo, código na hora, marca d'água)
  if coalesce(p_saude, false) then raise exception 'Os dados de saúde agora saem pelo download protegido de saúde.'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  v_plat := exists (select 1 from plataforma_admins where email = v_email);
  v_admin := e.id is not null and exists (select 1 from conta_membros m join contas c on c.id = m.conta_id
                                where m.conta_id = e.conta_id and m.email = v_email and m.papel = 'admin' and m.ativo and c.ativa
                                  and (not coalesce(p_saude, false) or m.ve_saude));
  -- o pacote com o espelho assinado só para quem tem rh_folhas na conta do pacote; a plataforma, só o pacote comum
  if e.id is null or not (
       (v_admin and (coalesce(p_saude, false) or not e.com_folha or exists (select 1 from conta_membros m
          where m.conta_id = e.conta_id and m.email = v_email and m.ativo and m.rh_folhas)))
    or (v_plat and not coalesce(p_saude, false) and not e.com_folha and not e.com_saude)) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  if e.estado <> 'pronta' or e.expira_em <= now() then raise exception 'Exportação vencida ou ainda não pronta.'; end if;
  if coalesce(p_saude, false) and e.arquivo_saude is null then raise exception 'Esta exportação não tem o pacote de saúde.'; end if;
  update conta_exportacoes set baixadas = baixadas + 1 where id = p_id;
  insert into conta_exportacao_baixas (conta_id, exportacao_id, email, saude) values (e.conta_id, e.id, v_email, coalesce(p_saude, false));
  return case when coalesce(p_saude, false) then e.arquivo_saude else e.arquivo end;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportacoes_manutencao()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare e record;
begin
  for e in select id from conta_exportacoes
            where tentativas < 3
              and ((estado = 'pendente' and coalesce(concluido_em, criado_em) < now() - interval '2 minutes')
                   or (estado = 'gerando' and iniciado_em < now() - interval '15 minutes'))
            order by criado_em limit 3 loop
    perform fn_exportacao_chamar(jsonb_build_object('id', e.id));
  end loop;
  -- travado na 3ª tentativa: falhou de vez (a final do encerramento avisa a plataforma)
  for e in update conta_exportacoes set estado = 'falhou', concluido_em = now(), erro = coalesce(erro, 'sem resposta da geração')
            where (estado = 'gerando' and tentativas >= 3 and iniciado_em < now() - interval '15 minutes')
               -- a geração nunca respondeu (função fora do ar ou URL errada): a final não espera mais que 1 hora
               or (estado = 'pendente' and origem = 'encerramento' and criado_em < now() - interval '1 hour')
           returning id, conta_id, origem, erro loop
    if e.origem = 'encerramento' then perform fn_exportacao_final_falhou(e.conta_id, e.erro); end if;
  end loop;
  if exists (select 1 from conta_exportacoes where estado in ('pronta', 'expirando') and expira_em <= now())
     or exists (select 1 from saude_downloads where estado in ('gerando', 'pronto', 'falhou', 'expirando') and criado_em < now() - interval '15 minutes') then
    perform fn_exportacao_chamar(jsonb_build_object('acao', 'limpar'));
  end if;
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
