-- Multiempresa F8c-2, os arquivos da exportação da conta (decisão 129). O ZIP da F8c-1 passa a levar também os
-- espelhos de ponto emitidos (PDF), os documentos dos técnicos (bucket documentos) e o AFD de cada empregadora, do
-- primeiro registro até hoje. O que é de saúde vai num segundo ZIP: as justificativas de saúde sem máscara e os anexos
-- do cofre, decifrados; ele só é gerado quando quem pede tem ve_saude (ou, no encerramento, se algum administrador tem),
-- só baixa quem tem ve_saude na conta (a plataforma nunca) e cada anexo exportado fica em ponto_anexo_acessos.
-- Pendências da F8c-1: escape de fórmula nas células de texto, registro de quem baixou (conta_exportacao_baixas), o
-- pacote só sai da lista depois de o Storage confirmar a remoção, e url/instância do canal ficam fora.

set lock_timeout = '5s';

alter table interno.conta_exportacoes
  add column com_saude boolean not null default false,
  add column arquivo_saude text,
  add column tamanho_saude bigint,
  drop constraint conta_exportacoes_estado_check,
  add constraint conta_exportacoes_estado_check check (estado in ('pendente', 'gerando', 'pronta', 'falhou', 'expirando', 'expirada'));

-- quem baixou e quando (o pacote todo ou o de saúde)
create table interno.conta_exportacao_baixas (
  id            bigint generated always as identity primary key,
  conta_id      uuid not null default interno.fn_conta_padrao() references interno.contas (id),
  exportacao_id uuid not null,
  email         text not null,
  saude         boolean not null default false,
  em            timestamptz not null default now(),
  foreign key (conta_id, exportacao_id) references interno.conta_exportacoes (conta_id, id) on delete cascade
);
alter table interno.conta_exportacao_baixas enable row level security;
create index conta_exportacao_baixas_exp_idx on interno.conta_exportacao_baixas (conta_id, exportacao_id, em desc);

create or replace function interno.fn_csv_texto(p text)
 returns text
 language sql
 immutable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select case when p ~ '^[=+\-@\t\r]' then '''' || p else p end;
$function$;

CREATE OR REPLACE FUNCTION interno.fn_afd_gerar(p_empresa uuid, p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
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
    from empresas e where e.id = p_empresa and e.empregadora;
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

CREATE OR REPLACE FUNCTION public.app_ponto_afd(p_empresa uuid, p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin']);
  v_r     jsonb;
begin
  if not exists (select 1 from empresas e where e.id = p_empresa and e.empregadora and e.conta_id = fn_conta_atual()) then
    raise exception 'Empresa empregadora não encontrada.';
  end if;
  v_r := fn_afd_gerar(p_empresa, p_de, p_ate);
  insert into ponto_afd_geracoes (email, empresa_id, de, ate, registros, sha256)
  values (v_email, p_empresa, p_de, p_ate, (v_r->>'marcacoes')::int, v_r->>'sha256');
  return v_r;
end $function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportar_tabelas()
 RETURNS TABLE(tabela text, colunas text[], chave text[])
 LANGUAGE sql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
                where i.indrelid = c.oid and i.indisprimary order by array_position(i.indkey::int2[], a.attnum))
    from pg_class c
   where c.relnamespace = 'interno'::regnamespace and c.relkind in ('r', 'p') and not c.relispartition
     and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname = 'conta_id' and not a.attisdropped)
   order by 1;
$function$
;

CREATE OR REPLACE FUNCTION interno.fn_exportar_csv(p_token text, p_id uuid, p_tabela text, p_offset integer, p_limite integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  -- saúde com a máscara do painel: o motivo vira 'saude' e os textos da justificativa ficam vazios
  execute format('select string_agg(l, E''\n'' order by n) from (select row_number() over () as n, concat_ws('','', %s) as l
                    from (select * from interno.%I where conta_id = $1 order by %s limit $2 offset $3) z) y',
                 (select string_agg(case
                     when p_tabela = 'ponto_justificativas' and c = 'motivo'
                       then 'interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then ''saude'' else z.motivo end)'
                     when p_tabela = 'ponto_justificativas' and c in ('observacao', 'resposta', 'alerta_limite')
                       then format('interno.fn_csv(case when interno.fn_motivo_saude(z.motivo) then null else z.%I::text end)', c)
                     -- texto livre: célula que começa com = + - @ (ou tab, CR) ganha um apóstrofo, para a planilha não executar
                     when exists (select 1 from pg_attribute a where a.attrelid = ('interno.' || p_tabela)::regclass and a.attname = c
                                    and a.atttypid in ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype))
                       then format('interno.fn_csv(interno.fn_csv_texto(z.%I))', c)
                     else format('interno.fn_csv(z.%I::text)', c) end, ', ') from unnest(t.colunas) c),
                 p_tabela,
                 (select string_agg(format('%I', c), ', ') from unnest(t.chave) c))
    into v using v_conta, least(greatest(coalesce(p_limite, 5000), 1), 20000), greatest(coalesce(p_offset, 0), 0);
  return v;
end $function$
;

drop function interno.fn_exportar_pedir(uuid, text, text);
CREATE OR REPLACE FUNCTION interno.fn_exportar_pedir(p_conta uuid, p_autor text, p_origem text, p_com_saude boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_id uuid;
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
  insert into conta_exportacoes (conta_id, pedido_por, origem, com_saude) values (p_conta, p_autor, p_origem, coalesce(p_com_saude, false))
    returning id into v_id;
  perform fn_exportacao_chamar(jsonb_build_object('id', v_id));
  return v_id;
end $function$
;

-- administrador da conta da sessão, sempre com as duas etapas; o pacote de saúde só se ele tem ve_saude
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
  return interno.fn_exportar_pedir(interno.fn_conta_atual(), v_email, 'admin', interno.fn_ve_saude(v_email));
end $function$;

create or replace function public.app_exportacoes()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v_email text := app_exigir(array['admin']); v_conta uuid; v_saude boolean;
begin
  v_conta := interno.fn_conta_atual();
  v_saude := interno.fn_ve_saude(v_email);
  return coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'origem', e.origem, 'estado', e.estado, 'pedido_por', e.pedido_por,
      'criado_em', e.criado_em, 'concluido_em', e.concluido_em, 'expira_em', e.expira_em, 'tamanho', e.tamanho,
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro,
      'saude', v_saude and e.arquivo_saude is not null, 'tamanho_saude', case when v_saude then e.tamanho_saude end,
      'baixas', (select count(*) from interno.conta_exportacao_baixas b where b.conta_id = e.conta_id and b.exportacao_id = e.id))
      order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = v_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

-- a plataforma exporta qualquer conta, nunca o pacote de saúde (é dado sensível do cliente, não da operadora)
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
  return interno.fn_exportar_pedir(p_conta, v_ator, 'plataforma', false);
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
      'manifesto_sha256', e.manifesto_sha256, 'erro', e.erro, 'saude', false,
      'baixas', (select count(*) from interno.conta_exportacao_baixas b where b.conta_id = e.conta_id and b.exportacao_id = e.id))
      order by e.criado_em desc)
    from (select * from interno.conta_exportacoes where conta_id = p_conta order by criado_em desc limit 20) e), '[]'::jsonb);
end $function$;

-- o pedido diz se leva o pacote de saúde
CREATE OR REPLACE FUNCTION interno.fn_exportacao_dados(p_token text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  if not found or e.tentativas >= 3
     or not (e.estado = 'pendente' or (e.estado = 'gerando' and e.iniciado_em < now() - interval '15 minutes')) then
    return null;
  end if;
  update conta_exportacoes set estado = 'gerando', iniciado_em = now(), tentativas = tentativas + 1 where id = p_id;
  return jsonb_build_object('conta', e.conta_id, 'origem', e.origem, 'com_saude', e.com_saude,
    'nome', (select nome from contas where id = e.conta_id),
    'tabelas', (select jsonb_agg(jsonb_build_object('tabela', t.tabela, 'colunas', t.colunas)) from fn_exportar_tabelas() t));
end $function$
;

-- Edge Function: os arquivos do pedido (espelhos emitidos, documentos, AFD de cada empregadora e, com saúde, os anexos)
create or replace function interno.fn_exportar_arquivos(p_token text, p_id uuid)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id and estado = 'gerando';
  if not found then raise exception 'exportação fora de andamento'; end if;
  return jsonb_build_object(
    'espelhos', coalesce((select jsonb_agg(jsonb_build_object('id', p.espelho_id,
        'nome', 'espelhos/' || to_char(s.competencia, 'YYYY-MM') || '_' || regexp_replace(lower(translate(t.nome, 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑáàâãäéèêëíìîïóòôõöúùûüçñ', 'AAAAAEEEEIIIIOOOOOUUUUCNaaaaaeeeeiiiiooooouuuucn')), '[^a-z0-9]+', '_', 'g')
                || '_v' || s.versao || '_' || left(s.id::text, 8) || '.pdf') order by s.competencia, t.nome)
      from ponto_espelho_pdfs p join ponto_espelhos s on s.id = p.espelho_id join tecnicos t on t.id = s.tecnico_id
     where p.conta_id = e.conta_id and p.pdf is not null), '[]'::jsonb),
    'documentos', coalesce((select jsonb_agg(jsonb_build_object('caminho', d.caminho,
        'nome', 'documentos/' || left(d.id::text, 8) || '_' || regexp_replace(coalesce(d.nome_arquivo, 'arquivo'), '[^A-Za-z0-9._-]+', '_', 'g'))
        order by d.created_at)
      from documentos d where d.conta_id = e.conta_id and d.caminho is not null), '[]'::jsonb),
    'afd', coalesce((select jsonb_agg(m.id order by m.razao_social) from empresas m
                      where m.conta_id = e.conta_id and m.empregadora
                        and exists (select 1 from ponto_marcacoes k where k.empresa_id = m.id)), '[]'::jsonb),
    'anexos', case when e.com_saude then coalesce((select jsonb_agg(jsonb_build_object('id', x.id,
        'nome', 'saude/anexos/' || left(x.justificativa_id::text, 8) || '_' || left(x.id::text, 8) || '.' ||
                case x.tipo when 'application/pdf' then 'pdf' when 'image/png' then 'png' else 'jpg' end) order by x.created_at)
      from ponto_justificativa_anexos x where x.conta_id = e.conta_id), '[]'::jsonb) else '[]'::jsonb end);
end $function$;

-- um espelho em PDF (base64), só da conta do pedido
create or replace function interno.fn_exportar_espelho(p_token text, p_id uuid, p_espelho uuid)
 returns text
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare v text;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select encode(p.pdf, 'base64') into v from ponto_espelho_pdfs p join conta_exportacoes e on e.conta_id = p.conta_id
   where e.id = p_id and e.estado = 'gerando' and p.espelho_id = p_espelho;
  return v;
end $function$;

-- AFD de uma empregadora da conta do pedido, do primeiro registro até hoje (mesmo gerador do painel), registrado
create or replace function interno.fn_exportar_afd(p_token text, p_id uuid, p_empresa uuid)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_de date; v_ate date; v_fuso text; v_r jsonb;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id and estado = 'gerando';
  if not found then raise exception 'exportação fora de andamento'; end if;
  select coalesce(m.fuso, 'America/Bahia') into v_fuso from empresas m where m.id = p_empresa and m.conta_id = e.conta_id and m.empregadora;
  if v_fuso is null then raise exception 'empresa fora da exportação'; end if;
  v_ate := (now() at time zone v_fuso)::date;
  select (min(momento) at time zone v_fuso)::date into v_de from ponto_marcacoes where empresa_id = p_empresa;
  v_r := fn_afd_gerar(p_empresa, coalesce(v_de, v_ate), v_ate);
  insert into ponto_afd_geracoes (email, empresa_id, de, ate, registros, sha256, conta_id)
  values ('exportação ' || e.pedido_por, p_empresa, coalesce(v_de, v_ate), v_ate, (v_r->>'marcacoes')::int, v_r->>'sha256', e.conta_id);
  return jsonb_build_object('nome', 'afd/' || (v_r->>'nome'), 'conteudo', v_r->>'conteudo');
end $function$;

-- saúde: as justificativas de saúde sem máscara (CSV) e cada anexo decifrado, só no pedido com saúde e registrado
create or replace function interno.fn_exportar_saude_csv(p_token text, p_id uuid)
 returns text
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v text;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id and estado = 'gerando' and com_saude;
  if not found then raise exception 'exportação sem saúde'; end if;
  select string_agg(concat_ws(',', fn_csv(j.id::text), fn_csv(j.numero::text), fn_csv(t.nome), fn_csv(j.tecnico_id::text),
           fn_csv(j.motivo), fn_csv(m.nome), fn_csv(j.data::text), fn_csv(j.data_fim::text), fn_csv(fn_csv_texto(j.observacao)),
           fn_csv(j.status), fn_csv(fn_csv_texto(j.resposta)), fn_csv(j.decidido_por), fn_csv(j.decidido_em::text),
           fn_csv(j.created_at::text)), E'\r\n' order by j.data, j.numero)
    into v
    from ponto_justificativas j join ponto_motivos m on m.codigo = j.motivo join tecnicos t on t.id = j.tecnico_id
   where j.conta_id = e.conta_id and m.saude;
  return E'﻿id,numero,funcionario,tecnico_id,motivo,motivo_nome,data,data_fim,observacao,status,resposta,decidido_por,decidido_em,criado_em\r\n'
         || coalesce(v || E'\r\n', '');
end $function$;

create or replace function interno.fn_exportar_anexo(p_token text, p_id uuid, p_anexo uuid)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; x ponto_justificativa_anexos;
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  select * into e from conta_exportacoes where id = p_id and estado = 'gerando' and com_saude;
  if not found then raise exception 'exportação sem saúde'; end if;
  select * into x from ponto_justificativa_anexos where id = p_anexo and conta_id = e.conta_id;
  if not found then return null; end if;
  insert into ponto_anexo_acessos (anexo_id, justificativa_id, sha256, email, conta_id)
  values (x.id, x.justificativa_id, x.sha256, 'exportação ' || e.pedido_por, e.conta_id);
  return encode(fn_ponto_cofre_decifrar(x.conteudo), 'base64');
end $function$;

-- resultado: pronta (vence em 7 dias) ou falhou; na final do encerramento, o link vai aos administradores (o de saúde,
-- só aos que têm ve_saude)
drop function interno.fn_exportacao_resultado(text, uuid, boolean, text, bigint, text, text, text);
create or replace function interno.fn_exportacao_resultado(p_token text, p_id uuid, p_ok boolean, p_arquivo text, p_tamanho bigint,
                                                           p_sha text, p_erro text, p_link text default null,
                                                           p_arquivo_saude text default null, p_tamanho_saude bigint default null,
                                                           p_link_saude text default null)
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare e conta_exportacoes; v_para text[]; v_fuso text := coalesce(fn_config('fuso'), 'America/Bahia');
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  update conta_exportacoes set
         estado = case when p_ok then 'pronta' when tentativas >= 3 then 'falhou' else 'pendente' end,
         concluido_em = now(), expira_em = case when p_ok then now() + interval '7 days' end,
         arquivo = case when p_ok then p_arquivo end, tamanho = case when p_ok then p_tamanho end,
         arquivo_saude = case when p_ok and com_saude then p_arquivo_saude end,
         tamanho_saude = case when p_ok and com_saude then p_tamanho_saude end,
         manifesto_sha256 = case when p_ok then p_sha end, erro = case when p_ok then null else left(p_erro, 300) end
   where id = p_id and estado = 'gerando' returning * into e;
  if found and e.estado = 'falhou' and e.origem = 'encerramento' then perform fn_exportacao_final_falhou(e.conta_id, e.erro); end if;
  if not found or not p_ok or e.origem <> 'encerramento' or coalesce(p_link, '') !~ '^https://' then return; end if;
  select array_agg(email order by email) into v_para from conta_membros where conta_id = e.conta_id and papel = 'admin' and ativo;
  if v_para is null then return; end if;
  perform fn_alerta_email('Trilha: exportação final dos dados da sua conta',
    'A conta ' || (select nome from contas where id = e.conta_id) || ' foi encerrada no Trilha. A cópia completa dos dados '
    || 'está pronta para baixar até ' || to_char(e.expira_em at time zone v_fuso, 'DD/MM/YYYY')
    || ':' || E'\n\n' || p_link || E'\n\n'
    || 'O arquivo tem uma planilha (CSV) por tabela, o dicionário dos campos (esquema.json), os espelhos de ponto emitidos, '
    || 'os documentos dos técnicos, o AFD de cada empregadora e o manifesto com o hash de cada arquivo. Os dados da conta '
    || 'serão apagados em ' || to_char((select apagar_em from contas where id = e.conta_id) at time zone v_fuso, 'DD/MM/YYYY')
    || '. Guarde a cópia: depois disso ela não poderá ser gerada de novo.',
    v_para, true);
  -- saúde: só a quem tem ve_saude na conta, em e-mail à parte
  select array_agg(email order by email) into v_para from conta_membros
   where conta_id = e.conta_id and papel = 'admin' and ativo and ve_saude;
  if v_para is null or coalesce(p_link_saude, '') !~ '^https://' then return; end if;
  perform fn_alerta_email('Trilha: exportação final dos dados de saúde da sua conta',
    'Este link traz os dados de saúde da conta ' || (select nome from contas where id = e.conta_id) || ' (justificativas de '
    || 'saúde e atestados), separados por serem dado sensível (LGPD, art. 11). Vale até '
    || to_char(e.expira_em at time zone v_fuso, 'DD/MM/YYYY') || ':' || E'\n\n' || p_link_saude || E'\n\n'
    || 'Guarde em local protegido e com acesso restrito.',
    v_para, true);
end $function$;

-- link para baixar: o pacote, administrador ativo da conta ou plataforma; o de saúde, só administrador com ve_saude;
-- sempre com duas etapas, antes de vencer, e registrado
drop function interno.fn_exportacao_link(text, text, uuid);
create or replace function interno.fn_exportacao_link(p_email text, p_aal text, p_id uuid, p_saude boolean default false)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  e conta_exportacoes;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_admin boolean;
  v_plat  boolean;
begin
  if coalesce(p_aal, '') <> 'aal2' then raise exception 'Confirme a verificação em duas etapas para baixar.'; end if;
  select * into e from conta_exportacoes where id = p_id for update;
  v_plat := exists (select 1 from plataforma_admins where email = v_email);
  v_admin := e.id is not null and exists (select 1 from conta_membros m join contas c on c.id = m.conta_id
                                where m.conta_id = e.conta_id and m.email = v_email and m.papel = 'admin' and m.ativo and c.ativa
                                  and (not coalesce(p_saude, false) or m.ve_saude));
  if e.id is null or not (v_admin or (v_plat and not coalesce(p_saude, false))) then
    raise exception 'Sem permissão para esta ação.';
  end if;
  if e.estado <> 'pronta' or e.expira_em <= now() then raise exception 'Exportação vencida ou ainda não pronta.'; end if;
  if coalesce(p_saude, false) and e.arquivo_saude is null then raise exception 'Esta exportação não tem o pacote de saúde.'; end if;
  update conta_exportacoes set baixadas = baixadas + 1 where id = p_id;
  insert into conta_exportacao_baixas (conta_id, exportacao_id, email, saude) values (e.conta_id, e.id, v_email, coalesce(p_saude, false));
  return case when coalesce(p_saude, false) then e.arquivo_saude else e.arquivo end;
end $function$;

-- pacotes vencidos: a Edge Function apaga os arquivos e confirma (fn_exportacoes_apagadas); só então saem da lista.
-- Sem confirmação, ficam 'expirando' e o motor manda apagar de novo
drop function interno.fn_exportacoes_vencidas(text);
create or replace function interno.fn_exportacoes_vencidas(p_token text)
 returns table (id uuid, arquivo text)
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  return query
    with v as (update conta_exportacoes x set estado = 'expirando'
                where x.estado in ('pronta', 'expirando') and x.expira_em <= now() and x.arquivo is not null
               returning x.id, x.arquivo, x.arquivo_saude)
    select v.id, v.arquivo from v union all select v.id, v.arquivo_saude from v where v.arquivo_saude is not null;
end $function$;

create or replace function interno.fn_exportacoes_apagadas(p_token text, p_ids uuid[])
 returns void
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not fn_exportacao_token_ok(p_token) then raise exception 'token inválido'; end if;
  update conta_exportacoes set estado = 'expirada' where id = any (p_ids) and estado = 'expirando';
end $function$;

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
  if exists (select 1 from conta_exportacoes where estado in ('pronta', 'expirando') and expira_em <= now()) then
    perform fn_exportacao_chamar(jsonb_build_object('acao', 'limpar'));
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
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
  perform interno.fn_exportar_pedir(p_conta, v_ator, 'encerramento',
    exists (select 1 from interno.conta_membros where conta_id = p_conta and papel = 'admin' and ativo and ve_saude));
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
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
