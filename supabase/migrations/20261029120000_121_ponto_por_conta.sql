-- 121: multiempresa F2e, família do ponto no painel (docs/multiempresa-f2.md). Marcações, ajustes, abonos, pedidos,
-- espelhos, fechamento da folha, cofre de folhas, horas extras, AFD e conferência de documentos passam a ler e alterar
-- só na conta da sessão; funcionário, empresa, pedido, abono, espelho e documento recebidos são conferidos na conta.
-- Herança de conta (migration 119) em todas as tabelas do ponto: a linha nova leva a conta da empresa, do funcionário,
-- do pedido ou do espelho de origem, venha do painel, do app do funcionário, do WhatsApp ou do agendador.
-- As funções `ponto_*` (app do funcionário) já ficam presas ao funcionário da sessão e não mudam aqui.
-- Funções recriadas a partir da definição da homologação de 29/10 (md5 do conjunto das app_ponto_*: 43580781…).

-- herança de conta --------------------------------------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select * from (values
      ('ponto_abonos', 'empresas', 'empresa_id'), ('ponto_afd_geracoes', 'empresas', 'empresa_id'),
      ('ponto_ajustes', 'empresas', 'empresa_id'), ('ponto_documento_registros', 'empresas', 'empresa_id'),
      ('ponto_documento_sequencia', 'empresas', 'empresa_id'), ('ponto_espelho_pdfs', 'empresas', 'empresa_id'),
      ('ponto_espelho_sequencia', 'empresas', 'empresa_id'), ('ponto_espelhos', 'empresas', 'empresa_id'),
      ('ponto_folha_fechamentos', 'empresas', 'empresa_id'), ('ponto_he_autorizacoes', 'empresas', 'empresa_id'),
      ('ponto_justificativas', 'empresas', 'empresa_id'), ('ponto_marcacoes', 'empresas', 'empresa_id'),
      ('ponto_nsr', 'empresas', 'empresa_id'),
      ('ponto_acessos', 'tecnicos', 'tecnico_id'), ('ponto_ciencias', 'tecnicos', 'tecnico_id'),
      ('ponto_codigos', 'tecnicos', 'tecnico_id'), ('ponto_conversas', 'tecnicos', 'tecnico_id'),
      ('ponto_sessoes', 'tecnicos', 'tecnico_id'),
      ('ponto_anexo_acessos', 'ponto_justificativas', 'justificativa_id'),
      ('ponto_anexos_descartados', 'ponto_justificativas', 'justificativa_id'),
      ('ponto_justificativa_anexos', 'ponto_justificativas', 'justificativa_id'),
      ('ponto_espelho_acessos', 'ponto_espelhos', 'espelho_id')) as x(tabela, pai, coluna) loop
    execute format('create trigger tg_00_conta before insert on interno.%I for each row execute function '
                   'interno.fn_herdar_conta(%L, %L)', r.tabela, r.pai, r.coluna);
  end loop;
end $$;

-- funções do painel -------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_ponto_abonar(p_tecnico uuid, p_data date, p_motivo text, p_inicio time without time zone DEFAULT NULL::time without time zone, p_fim time without time zone DEFAULT NULL::time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_det   text;
  v_esp   text;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico and t.conta_id = fn_conta_atual();
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Abono só até hoje.'; end if;
  v_esp := fn_ponto_mes_espelho(p_tecnico, p_data);
  if v_esp = 'assinado' then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: não cabe mais abono.';
  end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do abono (10 a 500 letras).'; end if;
  if (p_inicio is null) <> (p_fim is null) or p_inicio >= p_fim then raise exception 'Período inválido: das ... às ... ou dia inteiro.'; end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.data = p_data and a.estorno_de is null
              and a.inicio is not distinct from p_inicio and a.fim is not distinct from p_fim
              and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'Este abono já foi lançado.';
  end if;
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor)
  values (v_tec.empresa_id, p_tecnico, p_data, p_inicio, p_fim, trim(p_motivo), v_email) returning id into v_id;
  v_det := fn_ponto_justificativa_detalhe('abono', null, null, p_inicio, p_fim);
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, '📝 *Ponto · abono do gestor*' || E'\n' || 'Seu registro de ' || to_char(p_data, 'DD/MM')
      || ' foi abonado (' || v_det || '): esse período não é descontado.');
  end if;
  return jsonb_build_object('id', v_id, 'data', to_char(p_data, 'DD/MM/YYYY'), 'detalhe', v_det,
                            'espelho_desatualizado', v_esp = 'emitido');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_abonos(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, tecnico_id uuid, tecnico text, data date, detalhe text, pedido bigint, estornado boolean, motivo text, autor text, criado_em text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_leitura boolean; v_conta uuid;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select a.id, a.tecnico_id, t.nome, a.data, fn_ponto_justificativa_detalhe('abono', null, null, a.inicio, a.fim),
           j.numero, exists (select 1 from ponto_abonos x where x.estorno_de = a.id),
           case when v_leitura then null else a.motivo end, case when v_leitura then null else a.autor end,
           to_char(a.created_at at time zone coalesce(e.fuso, 'America/Bahia'), 'DD/MM/YYYY HH24:MI')
      from ponto_abonos a join tecnicos t on t.id = a.tecnico_id join empresas e on e.id = a.empresa_id
      left join ponto_justificativas j on j.id = a.justificativa_id
     where a.estorno_de is null and a.data between p_de and p_ate and (p_tecnico is null or a.tecnico_id = p_tecnico)
       and a.conta_id = v_conta
     order by a.data desc, a.created_at desc;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_acompanhamento(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, nsr bigint, empresa text, tecnico_id uuid, tecnico text, momento timestamp with time zone, data text, hora text, tipo text, canal text, local text, distancia_m integer, dentro_area boolean, login_origem text, gestor text, autenticacao text, latitude numeric, longitude numeric, ajustada boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_leitura boolean;
  v_conta   uuid;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select m.id, m.nsr, coalesce(e.nome_fantasia, e.razao_social), m.tecnico_id, t.nome, m.momento,
           to_char(m.momento at time zone e.fuso, 'DD/MM/YYYY'), to_char(m.momento at time zone e.fuso, 'HH24:MI:SS'),
           m.tipo, m.canal, l.nome, m.distancia_m, m.dentro_area,
           coalesce(m.origem ->> 'login_origem', case when m.canal = 'app' then 'whatsapp' end),
           case when v_leitura then null else m.origem ->> 'gestor' end,
           left(m.hash, 16),
           case when v_leitura then null else m.latitude end,
           case when v_leitura then null else m.longitude end,
           exists (select 1 from ponto_ajustes a where a.marcacao_id = m.id)
      from ponto_marcacoes m
      join tecnicos t on t.id = m.tecnico_id
      join empresas e on e.id = m.empresa_id
      left join locais l on l.id = m.local_id
     where (m.momento at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or m.tecnico_id = p_tecnico)
       and m.conta_id = v_conta
     order by m.momento desc;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_afastados()
 RETURNS TABLE(tecnico_id uuid, tecnico text, afastado_ate date, pode_registrar_alta boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_saude boolean := fn_ve_saude(v_email);
  v_conta uuid := fn_conta_atual();
begin
  return query
    select x.id, x.nome, x.ate, v_saude
      from (select t.id, t.nome,
                   fn_ponto_afastado_ate(t.id, (now() at time zone coalesce(e.fuso, 'America/Bahia'))::date) as ate
              from tecnicos t join empresas e on e.id = t.empresa_id
             where t.ativo and t.conta_id = v_conta) x
     where x.ate is not null
     order by x.ate, x.nome;
end $function$

;

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
  v_dev := fn_afd_n(coalesce(nullif(fn_config('rep_p_desenvolvedor_cnpj'), ''), v_emp.cnpj), 14);

  -- Cabeçalho (tipo 1): 298 posições + CRC-16
  v_cab := '000000000' || '1' || '1' || fn_afd_n(v_emp.cnpj, 14) || repeat(' ', 14)
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
    'nome', 'AFD' || v_inpi || fn_afd_n(v_emp.cnpj, 14) || 'REP_P' || case when v_conf then '_CONFERENCIA' else '' end || '.txt',
    'conteudo', v_texto, 'marcacoes', v_n7, 'sha256', v_sha,
    'conferencia', v_conf,
    'aviso', case when v_conf then 'Versão de conferência: leiaute do Anexo V da Portaria 671 (a conferir contra o do gov.br), '
             || 'sem assinatura CAdES' || case when v_inpi = repeat('0', 17) then ' e sem o número do INPI' else '' end
             || '. Não entregar à fiscalização antes da conferência da contadora. ' else '' end
             || 'O arquivo tem o CPF de todos os funcionários: guarde em local protegido e apague depois do uso.');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_ajustar(p_tecnico uuid, p_acao text, p_motivo text, p_marcacao uuid DEFAULT NULL::uuid, p_ajuste uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_tec     record;
  v_alvo    record;
  v_mom     timestamptz;
  v_tipo    text;
  v_emp     uuid;
  v_id      uuid;
  v_texto   text;
  v_fuso    text;
  v_avisado boolean := false;
  v_esp     text;
begin
  select t.id, t.nome, t.telefone_e164, t.opt_in, t.ativo, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico and t.conta_id = fn_conta_atual();
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  v_fuso := v_tec.fuso;
  v_emp := v_tec.empresa_id;
  if length(trim(coalesce(p_motivo, ''))) < 10 then
    raise exception 'Escreva o motivo do ajuste (pelo menos 10 letras).';
  end if;
  if length(trim(p_motivo)) > 500 then raise exception 'Motivo com no máximo 500 letras.'; end if;
  if p_acao = 'incluir' then
    raise exception 'O gestor não inclui marcação: só desconsidera a errada. A marcação vem sempre do funcionário (decisão 100).';
  elsif p_acao is distinct from 'desconsiderar' then
    raise exception 'Ação de ajuste inválida.';
  end if;

  if num_nonnulls(p_marcacao, p_ajuste) <> 1 then raise exception 'Escolha a marcação a desconsiderar.'; end if;
  if p_marcacao is not null then
    select m.tipo, m.momento, m.tecnico_id, m.empresa_id into v_alvo from ponto_marcacoes m where m.id = p_marcacao;
    if not found or v_alvo.tecnico_id <> p_tecnico then raise exception 'Marcação não encontrada para este funcionário.'; end if;
  else
    select a.tipo, a.momento, a.tecnico_id, a.empresa_id into v_alvo from ponto_ajustes a
     where a.id = p_ajuste and a.acao = 'incluir';
    if not found or v_alvo.tecnico_id <> p_tecnico then raise exception 'Marcação não encontrada para este funcionário.'; end if;
  end if;
  if exists (select 1 from ponto_ajustes a where a.acao = 'desconsiderar'
              and (a.marcacao_id = p_marcacao or a.ajuste_id = p_ajuste)) then
    raise exception 'Esta marcação já foi desconsiderada.';
  end if;
  v_mom := v_alvo.momento; v_tipo := v_alvo.tipo; v_emp := v_alvo.empresa_id;
  v_esp := fn_ponto_mes_espelho(p_tecnico, (v_mom at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date);
  if v_esp = 'assinado' then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: o ponto do mês não muda mais.';
  end if;
  if v_esp = 'sem_espelho' and v_mom < now() - interval '62 days' then
    raise exception 'Ajuste só para os últimos 62 dias, ou para mês com espelho emitido e ainda não assinado.';
  end if;

  begin
    insert into ponto_ajustes (empresa_id, tecnico_id, marcacao_id, ajuste_id, acao, motivo, autor)
    values (v_emp, p_tecnico, p_marcacao, p_ajuste, 'desconsiderar', trim(p_motivo), v_email)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Esta marcação já foi desconsiderada.';
  end;

  -- aviso ao funcionário: o que mudou, sem o motivo (LGPD); no máximo um a cada 5 minutos
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_ajuste_' || p_tecnico || '_' || floor(extract(epoch from now()) / 300)::bigint, current_date, now(), true,
            jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_texto := '📝 *Ponto · ajuste do gestor*' || E'\n' || 'Seu registro de '
        || to_char(v_mom at time zone v_fuso, 'DD/MM') || ' foi ajustado: '
        || 'desconsiderada a marcação ' || fn_ponto_rotulo(v_tipo) || ' das '
        || to_char(v_mom at time zone v_fuso, 'HH24:MI') || '.' || E'\n'
        || 'As marcações originais continuam guardadas. Dúvidas, fale com seu gestor.';
      perform fn_ponto_wa(v_tec.telefone_e164, v_texto);
      v_avisado := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'acao', p_acao, 'tipo', v_tipo, 'avisado', v_avisado,
    'espelho_desatualizado', v_esp = 'emitido',
    'data', to_char(v_mom at time zone v_fuso, 'DD/MM/YYYY'), 'hora', to_char(v_mom at time zone v_fuso, 'HH24:MI'));
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_ajustes(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, tecnico_id uuid, tecnico text, data text, hora text, acao text, tipo text, marcacao_nsr bigint, desfaz_inclusao boolean, desconsiderado boolean, motivo text, autor text, criado_em text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_leitura boolean; v_conta uuid;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select a.id, a.tecnico_id, t.nome,
           to_char(coalesce(a.momento, m.momento, y.momento) at time zone e.fuso, 'DD/MM/YYYY'),
           to_char(coalesce(a.momento, m.momento, y.momento) at time zone e.fuso, 'HH24:MI'),
           a.acao, coalesce(a.tipo, m.tipo, y.tipo), m.nsr, a.ajuste_id is not null,
           a.acao = 'incluir' and exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id),
           case when v_leitura then null else a.motivo end,
           case when v_leitura then null else a.autor end,
           to_char(a.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI')
      from ponto_ajustes a
      join tecnicos t on t.id = a.tecnico_id
      join empresas e on e.id = a.empresa_id
      left join ponto_marcacoes m on m.id = a.marcacao_id
      left join ponto_ajustes y on y.id = a.ajuste_id
     where (coalesce(a.momento, m.momento, y.momento) at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or a.tecnico_id = p_tecnico)
       and a.conta_id = v_conta
     order by a.created_at desc;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_anexo_descartar(p_anexo uuid, p_motivo text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_email text := app_exigir(array['admin','gestor']);
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos descarta documentos.'; end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do descarte (10 a 500 letras).'; end if;
  if not exists (select 1 from ponto_justificativa_anexos x join ponto_justificativas j on j.id = x.justificativa_id
                  where x.id = p_anexo and j.conta_id = fn_conta_atual()) then
    raise exception 'Documento não encontrado.';
  end if;
  perform fn_ponto_anexo_descartar(p_anexo, p_motivo, v_email);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_anexo_ver(p_anexo uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
  v_bin   bytea;
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos vê os documentos.'; end if;
  select x.id, x.justificativa_id, x.tipo, x.conteudo, x.sha256, r.registro, r.codigo, r.recebido_em, r.canal,
         j.numero, coalesce(e.nome_fantasia, e.razao_social) as empresa, coalesce(e.fuso, 'America/Bahia') as fuso
    into a
    from ponto_justificativa_anexos x
    join ponto_justificativas j on j.id = x.justificativa_id
    join empresas e on e.id = j.empresa_id
    left join ponto_documento_registros r on r.anexo_id = x.id
   where x.id = p_anexo and j.conta_id = fn_conta_atual();
  if not found then raise exception 'Documento não encontrado.'; end if;
  insert into ponto_anexo_acessos (anexo_id, justificativa_id, sha256, email) values (a.id, a.justificativa_id, a.sha256, v_email);
  v_bin := fn_ponto_cofre_decifrar(a.conteudo);
  return jsonb_build_object('tipo', a.tipo, 'conteudo', encode(v_bin, 'base64'),
    'visto_por', v_email, 'em', to_char(now() at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'registro', lpad(a.registro::text, 6, '0'), 'codigo', a.codigo, 'empresa', a.empresa, 'pedido', a.numero,
    'recebido_em', to_char(a.recebido_em at time zone a.fuso, 'DD/MM/YYYY HH24:MI:SS'),
    'canal', case a.canal when 'whatsapp' then 'WhatsApp' else 'App' end,
    'sha256', a.sha256, 'integro', encode(extensions.digest(v_bin, 'sha256'), 'hex') = a.sha256);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_anexos(p_justificativa uuid)
 RETURNS TABLE(id uuid, tipo text, tamanho integer, criado_em text, visualizacoes bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid := fn_conta_atual();
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos vê os documentos.'; end if;
  return query
    select a.id, a.tipo, a.tamanho, to_char(a.created_at at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
           (select count(*) from ponto_anexo_acessos x where x.anexo_id = a.id)
      from ponto_justificativa_anexos a
     where a.justificativa_id = p_justificativa
       and exists (select 1 from ponto_justificativas j where j.id = a.justificativa_id and j.conta_id = v_conta)
     order by a.created_at;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_cofre_folhas(p_competencia date DEFAULT NULL::date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, tecnico_id uuid, tecnico text, empresa text, competencia text, registro bigint, versao integer, codigo text, assinado_em timestamp with time zone, acessos bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_conta uuid;
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) abre o cofre.'; end if;
  v_conta := fn_conta_atual();
  return query
    select e.id, e.tecnico_id, t.nome, coalesce(m.nome_fantasia, m.razao_social), to_char(e.competencia, 'MM/YYYY'),
           e.registro, e.versao, e.codigo, e.assinado_em,
           (select count(*) from ponto_espelho_acessos a where a.espelho_id = e.id)
      from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
     where e.assinado_em is not null and e.conta_id = v_conta
       and (p_competencia is null or e.competencia = date_trunc('month', p_competencia)::date)
       and (p_tecnico is null or e.tecnico_id = p_tecnico)
     order by e.competencia desc, t.nome;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_decidir(p_id uuid, p_aprovar boolean, p_resposta text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  j       record;
  v_tec   record;
  v_mot   record;
  v_resp  text := nullif(trim(coalesce(p_resposta, '')), '');
  v_mom   timestamptz;
  v_aj    uuid;
  v_ab    uuid;
  v_txt   text;
  v_motx  text;
  v_dia   date;
  v_id    uuid;
begin
  select * into j from ponto_justificativas where id = p_id and conta_id = fn_conta_atual() for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  select * into v_mot from ponto_motivos where codigo = j.motivo;
  if v_mot.grupo <> 'ponto' and not fn_ve_saude(v_email) then
    raise exception 'Pedido com documento: só quem tem permissão de ver atestados e documentos decide.';
  end if;
  if j.status <> 'pendente' then raise exception 'Este pedido já foi decidido.'; end if;
  select t.nome, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = j.tecnico_id;
  if length(coalesce(v_resp, '')) > 500 then raise exception 'Resposta com no máximo 500 letras.'; end if;
  v_motx := 'Pedido nº ' || j.numero || ' do funcionário, aprovado';
  -- ao funcionário pelo WhatsApp: motivo de saúde não vai no texto (canal de terceiros)
  v_txt := case when v_mot.saude then 'Justificativa' else v_mot.nome end;

  if not p_aprovar then
    if length(coalesce(v_resp, '')) < 10 then raise exception 'Escreva o motivo da negativa (pelo menos 10 letras). Ele vai para o funcionário.'; end if;
    update ponto_justificativas set status = 'negada', decidido_por = v_email, decidido_em = now(), resposta = v_resp where id = p_id;
    v_txt := '*Pedido ' || j.numero || ' não aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Motivo do gestor: ' || v_resp || E'\n' || 'Tem como comprovar? Faça um novo pedido (WhatsApp: *ajuste*; ou pelo app).';
  elsif j.motivo in ('esqueci_marcar', 'falha_registro') then
    v_mom := (j.data + j.hora) at time zone v_tec.fuso;
    if exists (select 1 from ponto_ajustes a where a.tecnico_id = j.tecnico_id and a.acao = 'incluir'
                and a.tipo = j.tipo_marcacao and a.momento = v_mom
                and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id)) then
      raise exception 'Esta marcação já foi incluída. Negue o pedido como repetido.';
    end if;
    insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor, justificativa_id)
    values (j.empresa_id, j.tecnico_id, 'incluir', v_mom, j.tipo_marcacao, v_motx, v_email, j.id)
    returning id into v_aj;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, ajuste_id = v_aj
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Marcação incluída: ' || fn_ponto_rotulo(j.tipo_marcacao) || ' às ' || to_char(j.hora, 'HH24:MI') || '.';
  elsif j.motivo = 'alta_medica' then
    -- atestado de aptidão: só registra a liberação (o afastamento termina na data da alta); não abona
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || 'Liberação para o trabalho a partir de '
      || to_char(j.data, 'DD/MM') || ' registrada.';
  elsif j.hora_ini is not null then
    -- período de horas (atraso, consulta, pré-natal)
    if exists (select 1 from ponto_abonos a where a.tecnico_id = j.tecnico_id and a.data = j.data and a.estorno_de is null
                and a.inicio is not distinct from j.hora_ini and a.fim is not distinct from j.hora_fim
                and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
      raise exception 'Este período já está abonado. Negue o pedido como repetido.';
    end if;
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, motivo, autor)
    values (j.empresa_id, j.tecnico_id, j.data, j.hora_ini, j.hora_fim, j.id, v_motx, v_email)
    returning id into v_ab;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, abono_id = v_ab
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Abonado ' || fn_ponto_pedido_detalhe(j.motivo, null, null, j.hora_ini, j.hora_fim, j.data, null) || ': esse período não é descontado.';
  else
    -- dias inteiros: um abono por dia (dia já abonado fica como está)
    -- atestado com alta antes da validade: abona só até a véspera da alta (depois ele trabalhou)
    for v_dia in select g::date from generate_series(j.data,
                   case when j.motivo = 'atestado' then coalesce(
                     (select min(a.data) - 1 from ponto_justificativas a
                       where a.tecnico_id = j.tecnico_id and a.motivo = 'alta_medica' and a.status in ('pendente', 'aprovada')
                         and a.data >= j.data and a.data <= coalesce(j.data_fim, j.data) and a.numero > j.numero),
                     coalesce(j.data_fim, j.data)) else coalesce(j.data_fim, j.data) end, interval '1 day') g loop
      if not exists (select 1 from ponto_abonos a where a.tecnico_id = j.tecnico_id and a.data = v_dia and a.inicio is null
                      and a.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
        insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
        values (j.empresa_id, j.tecnico_id, v_dia, j.id, v_motx, v_email) returning id into v_id;
        v_ab := coalesce(v_ab, v_id);
      end if;
    end loop;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, abono_id = v_ab
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · '
      || fn_ponto_pedido_detalhe(j.motivo, null, null, null, null, j.data, j.data_fim) || E'\n'
      || 'Abonado: esse período não é descontado.';
  end if;

  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, v_txt);
  end if;
  return jsonb_build_object('numero', j.numero, 'status', case when p_aprovar then 'aprovada' else 'negada' end,
                            'ajuste_id', v_aj, 'abono_id', v_ab);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_emitir_espelhos(p_competencia date, p_tecnico uuid DEFAULT NULL::uuid, p_confirmar_faltas boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_mes    date := date_trunc('month', p_competencia)::date;
  v_fim    date := (date_trunc('month', p_competencia) + interval '1 month')::date - 1;
  t        record;
  v_atual  record;
  v_cont   jsonb;
  v_sha    text;
  v_reg    bigint;
  v_p      jsonb;
  v_conf_l jsonb;
  v_novo   uuid;
  v_emit   int := 0; v_igual int := 0; v_assin int := 0; v_vazio int := 0; v_pend int := 0; v_conf int := 0;
  v_conta  uuid := fn_conta_atual();
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'O espelho só é emitido para mês já encerrado.';
  end if;
  for t in select tc.id, tc.empresa_id from tecnicos tc join empresas em on em.id = tc.empresa_id
            where tc.cpf is not null and not tc.perfil_teste and tc.conta_id = v_conta
              and (p_tecnico is null or tc.id = p_tecnico)
              and coalesce(tc.admissao, tc.created_at::date) <= v_fim
              and (tc.ativo or tc.desligado_em >= v_mes)
            order by tc.nome loop
    select e.id, e.sha256, e.versao, e.assinado_em into v_atual from ponto_espelhos e
     where e.tecnico_id = t.id and e.competencia = v_mes and e.substituido_em is null
       for update;   -- a assinatura espera; e o gatilho não deixa substituir o assinado
    if v_atual.assinado_em is not null then v_assin := v_assin + 1; continue; end if;
    -- bloqueio: a folha desse funcionário não fecha; ocorrência a confirmar: só com a confirmação de quem fecha
    v_p := fn_ponto_folha_pendencias(t.id, v_mes);
    if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
      v_pend := v_pend + 1; continue;
    end if;
    select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_conf_l
      from jsonb_array_elements(v_p) x where x->>'nivel' = 'confirmar';
    if jsonb_array_length(v_conf_l) > 0 and not coalesce(p_confirmar_faltas, false) then
      v_conf := v_conf + 1; continue;
    end if;
    v_cont := fn_ponto_folha_conteudo(t.id, v_mes);
    if jsonb_array_length(v_cont->'dias') = 0 and jsonb_array_length(v_cont->'ajustes') = 0 then
      v_vazio := v_vazio + 1; continue;
    end if;
    -- o hash é dos bytes exatos guardados em conteudo_texto (a forma do jsonb pode mudar entre versões do Postgres)
    v_sha := encode(sha256(convert_to(v_cont::text, 'UTF8')), 'hex');
    if v_atual.id is not null and v_atual.sha256 = v_sha then v_igual := v_igual + 1; continue; end if;
    if v_atual.id is not null then update ponto_espelhos set substituido_em = now() where id = v_atual.id; end if;
    -- registro por empresa sem lacuna: a linha do contador fica travada até o fim da transação
    insert into ponto_espelho_sequencia (empresa_id) values (t.empresa_id) on conflict (empresa_id) do nothing;
    update ponto_espelho_sequencia set ultimo = ultimo + 1 where empresa_id = t.empresa_id returning ultimo into v_reg;
    insert into ponto_espelhos (empresa_id, tecnico_id, competencia, versao, registro, codigo, conteudo, conteudo_texto, sha256, emitido_por)
    values (t.empresa_id, t.id, v_mes, coalesce(v_atual.versao, 0) + 1, v_reg, fn_ponto_codigo_verificacao(), v_cont, v_cont::text, v_sha, v_email)
    returning id into v_novo;
    -- toda emissão é um fechamento: quem emitiu e as ocorrências que confirmou
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, ocorrencias_confirmadas, fechado_por)
    values (t.empresa_id, t.id, v_mes, v_novo, v_conf_l, v_email);
    v_emit := v_emit + 1;
  end loop;
  return jsonb_build_object('emitidos', v_emit, 'sem_mudanca', v_igual, 'ja_assinados', v_assin, 'sem_dados', v_vazio,
                            'com_pendencia', v_pend, 'a_confirmar', v_conf);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_enviar_espelhos(p_competencia date, p_espelho uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_url   text := rtrim(coalesce(nullif(fn_config('app_url'), ''), 'https://infoxtec-escalas.vercel.app'), '/');
  e       record;
  v_req   bigint;
  v_env   int := 0; v_sem int := 0; v_falha int := 0; v_desl int := 0;
  v_conta uuid := fn_conta_atual();
begin
  for e in select p.id, p.enviado_em, p.emitido_em, t.nome, t.telefone_e164, t.opt_in, t.ativo, to_char(p.competencia, 'MM/YYYY') as mes
             from ponto_espelhos p join tecnicos t on t.id = p.tecnico_id
            where p.competencia = date_trunc('month', p_competencia)::date and p.substituido_em is null
              and p.assinado_em is null and p.conta_id = v_conta
              and (p.id = p_espelho or (p_espelho is null and p.enviado_em is null))
            order by t.nome
              for update of p loop
    if not e.ativo then v_desl := v_desl + 1; continue; end if;
    if not e.opt_in or e.telefone_e164 is null or not fn_pode_enviar(e.telefone_e164) then
      v_sem := v_sem + 1; continue;
    end if;
    begin
      v_req := fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', e.telefone_e164,
          'text', 'Trilha Ponto: ' || split_part(trim(e.nome), ' ', 1) || ', o seu espelho de ponto de ' || e.mes
                  || ' está pronto para conferir e assinar: ' || v_url || '/ponto?espelho=' || e.id
                  || chr(10) || 'Entre com o seu CPF e o código. Se algo estiver errado, peça o ajuste antes de assinar.'
                  || chr(10) || 'Confira e peça ajuste até ' || to_char((e.emitido_em + make_interval(days => fn_ponto_espelho_prazo_dias())) at time zone 'America/Bahia', 'DD/MM/YYYY') || '. Depois disso, o mês é fechado.'));
      -- nulo: envio barrado pela trava da homologação; o pedido ao WhatsApp é assíncrono (pg_net)
      if v_req is null then v_sem := v_sem + 1; continue; end if;
      if e.enviado_em is null then update ponto_espelhos set enviado_em = now() where id = e.id; end if;
      v_env := v_env + 1;
    exception when others then
      v_falha := v_falha + 1;
    end;
  end loop;
  return jsonb_build_object('enviados', v_env, 'sem_whatsapp', v_sem, 'falhas', v_falha, 'desligados', v_desl);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_espelho(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(tecnico_id uuid, tecnico text, data date, escala_hora text, entrada text, saida_almoco text, volta_almoco text, saida text, trabalhado_min integer, intervalo_min integer, he_min integer, atraso_min integer, interjornada_min integer, alertas text[], ajustes integer, abono text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    with dias as (
      select distinct m.tecnico_id as tid, (m.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date as dia
        from ponto_marcacoes m join empresas e on e.id = m.empresa_id
       where m.momento >= p_de::timestamp - interval '1 day' and m.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or m.tecnico_id = p_tecnico) and m.conta_id = v_conta
      union
      select a.tecnico_id, (a.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date
        from ponto_ajustes a join empresas e on e.id = a.empresa_id
       where a.acao = 'incluir'
         and a.momento >= p_de::timestamp - interval '1 day' and a.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or a.tecnico_id = p_tecnico) and a.conta_id = v_conta
      union
      -- dia com escala (falta aparece) e dia com abono
      select s.tecnico_id, s.data_servico
        from escalas s join tecnicos t on t.id = s.tecnico_id and t.empresa_id is not null and t.cpf is not null
       where s.data_servico between p_de and p_ate and s.status not in ('cancelada', 'recusada', 'rascunho')
         and (p_tecnico is null or s.tecnico_id = p_tecnico) and t.conta_id = v_conta
      union
      select b.tecnico_id, b.data from ponto_abonos b
       where b.data between p_de and p_ate and (p_tecnico is null or b.tecnico_id = p_tecnico) and b.conta_id = v_conta
    ), j as (
      select d.tid, d.dia, fn_ponto_jornada_dia(d.tid, d.dia) as x from dias d where d.dia between p_de and p_ate
    )
    select j.tid, t.nome, j.dia, j.x->>'escala_hora', j.x->>'entrada', j.x->>'saida_almoco', j.x->>'volta_almoco',
           j.x->>'saida', (j.x->>'trabalhado_min')::int, (j.x->>'intervalo_min')::int, (j.x->>'he_min')::int,
           (j.x->>'atraso_min')::int, (j.x->>'interjornada_min')::int,
           array(select jsonb_array_elements_text(j.x->'alertas')), coalesce((j.x->>'ajustes')::int, 0), j.x->>'abono'
      from j join tecnicos t on t.id = j.tid
     where j.x is not null
     order by j.dia desc, t.nome;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_espelho_pdf(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_e     record;
  v_f     record;
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) baixa o PDF.'; end if;
  select e.id, e.competencia, e.registro, e.assinado_em, t.nome into v_e
    from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id where e.id = p_id and e.conta_id = fn_conta_atual();
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_e.assinado_em is null then raise exception 'Este espelho ainda não foi assinado.'; end if;
  select pdf, sha256 into v_f from ponto_espelho_pdfs where espelho_id = p_id and pdf is not null;
  if not found then
    perform fn_ponto_espelho_pdf_pedir(p_id);
    return jsonb_build_object('pronto', false);
  end if;
  insert into ponto_espelho_acessos (espelho_id, email, acao) values (p_id, v_email, 'pdf');
  return jsonb_build_object('pronto', true, 'pdf', encode(v_f.pdf, 'base64'), 'sha256', v_f.sha256,
           'nome', 'espelho-' || to_char(v_e.competencia, 'MM-YYYY') || '-registro-' || v_e.registro || '-'
                   || regexp_replace(lower(split_part(trim(v_e.nome), ' ', 1)), '[^a-z0-9]', '', 'g') || '.pdf');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_espelho_prova(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v       record;
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) baixa a prova.'; end if;
  select e.*, t.nome as tecnico_nome, m.razao_social, m.cnpj into v
    from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
   where e.id = p_id and e.conta_id = fn_conta_atual();
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v.assinado_em is null then raise exception 'Este espelho ainda não foi assinado.'; end if;
  insert into ponto_espelho_acessos (espelho_id, email, acao) values (p_id, v_email, 'prova');
  return jsonb_build_object(
    'documento', 'Espelho de ponto mensal assinado (Portaria MTP 671/2021, art. 84)',
    'empregador', jsonb_build_object('razao_social', v.razao_social, 'cnpj', v.cnpj),
    -- só o nome, para identificar o arquivo: o CPF já está no conteúdo (minimização, revisão do seguranca)
    'trabalhador', v.tecnico_nome,
    'competencia', to_char(v.competencia, 'MM/YYYY'), 'registro', v.registro, 'versao', v.versao,
    'codigo_verificacao', v.codigo, 'url_verificacao', rtrim(coalesce(nullif(fn_config('app_url'), ''), ''), '/') || '/v?c=' || v.codigo,
    'emitido_em', to_char(v.emitido_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
    'conteudo_texto', v.conteudo_texto,
    'sha256_conteudo', v.sha256,
    'sha256_conteudo_recalculado', encode(sha256(convert_to(v.conteudo_texto, 'UTF8')), 'hex'),
    'assinatura', jsonb_build_object(
      'assinado_em_utc', to_char(v.assinado_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      'imagem_png', v.assinatura_png,
      'origem', v.assinatura_origem,
      'hmac_sha256', v.assinatura_sha256,
      'chave_impressao', v.assinatura_chave,
      'hmac_confere', case when v.assinatura_chave is distinct from fn_ponto_assinatura_chave() then null
                           else fn_ponto_assinatura_hash(v.sha256, v.assinatura_png, v.assinado_em, v.assinatura_origem)
                                = v.assinatura_sha256 end,
      'como_conferir', 'sha256_conteudo = SHA-256 de conteudo_texto em UTF-8. hmac_sha256 = HMAC-SHA256, com a chave ESPELHO_ASSINATURA, de: sha256_conteudo|imagem_png|assinado_em_utc|ip|aparelho.'),
    'gerado_em', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'gerado_por', v_email);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_espelho_ver(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v       jsonb;
  v_ass   timestamptz;
begin
  select e.assinado_em into v_ass from ponto_espelhos e where e.id = p_id and e.conta_id = fn_conta_atual();
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_ass is not null then
    if not fn_rh_folhas(v_email) then
      raise exception 'Folha assinada: fica no cofre de folhas assinadas, aberto só por quem tem essa permissão (RH).';
    end if;
    insert into ponto_espelho_acessos (espelho_id, email, acao) values (p_id, v_email, 'ver');
  end if;
  select jsonb_build_object('id', e.id, 'registro', e.registro, 'versao', e.versao, 'codigo', e.codigo, 'sha256', e.sha256,
           'emitido_em', e.emitido_em, 'substituido', e.substituido_em is not null, 'conteudo', e.conteudo,
           'assinado_em', e.assinado_em, 'assinatura_png', e.assinatura_png)
    into v from ponto_espelhos e where e.id = p_id;
  return v;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_espelhos(p_competencia date)
 RETURNS TABLE(id uuid, tecnico_id uuid, tecnico text, empresa text, versao integer, registro bigint, codigo text, emitido_em timestamp with time zone, enviado_em timestamp with time zone, assinado_em timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  return query
    select e.id, e.tecnico_id, t.nome, coalesce(m.nome_fantasia, m.razao_social), e.versao, e.registro, e.codigo,
           e.emitido_em, e.enviado_em, e.assinado_em
      from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id join empresas m on m.id = e.empresa_id
     where e.competencia = date_trunc('month', p_competencia)::date and e.substituido_em is null and e.conta_id = v_conta
     order by t.nome;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_estornar_abono(p_abono uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
  v_id    uuid;
  v_esp   text;
begin
  select * into a from ponto_abonos where id = p_abono and conta_id = fn_conta_atual();
  if not found or a.estorno_de is not null then raise exception 'Abono não encontrado.'; end if;
  v_esp := fn_ponto_mes_espelho(a.tecnico_id, a.data);
  if v_esp = 'assinado' then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: o abono não pode mais ser estornado.';
  end if;
  if v_esp = 'sem_espelho' and a.data < (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 62 then
    raise exception 'Estorno só para os últimos 62 dias, ou para mês com espelho emitido e ainda não assinado.';
  end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do estorno (10 a 500 letras).'; end if;
  begin
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, estorno_de, motivo, autor)
    values (a.empresa_id, a.tecnico_id, a.data, a.inicio, a.fim, a.justificativa_id, a.id, trim(p_motivo), v_email)
    returning id into v_id;
  exception when unique_violation then raise exception 'Este abono já foi estornado.';
  end;
  return jsonb_build_object('id', v_id, 'espelho_desatualizado', v_esp = 'emitido');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_fechar_folha(p_competencia date, p_tecnico uuid, p_confirmar_faltas boolean DEFAULT false, p_ocorrencias_vistas integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_mes   date := date_trunc('month', p_competencia)::date;
  v_p     jsonb;
  v_conf  jsonb;
  v_r     jsonb;
  v_esp   record;
begin
  if p_tecnico is null then raise exception 'Informe o funcionário.'; end if;
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = fn_conta_atual()) then
    raise exception 'Funcionário não encontrado.';
  end if;
  v_p := fn_ponto_folha_pendencias(p_tecnico, v_mes);
  if exists (select 1 from jsonb_array_elements(v_p) x where (x->>'bloqueia')::boolean) then
    return jsonb_build_object('situacao', 'pendente', 'pendencias', v_p);
  end if;
  select coalesce(jsonb_agg(x order by x->>'data'), '[]'::jsonb) into v_conf
    from jsonb_array_elements(v_p) x where x->>'nivel' = 'confirmar';
  if jsonb_array_length(v_conf) > 0 and (not coalesce(p_confirmar_faltas, false)
       or (p_ocorrencias_vistas is not null and p_ocorrencias_vistas <> jsonb_array_length(v_conf))) then
    return jsonb_build_object('situacao', 'confirmar', 'ocorrencias', v_conf);
  end if;

  v_r := app_ponto_emitir_espelhos(v_mes, p_tecnico, p_confirmar_faltas);   -- confere o mês encerrado e o papel de novo
  select e.id, e.empresa_id, e.assinado_em into v_esp from ponto_espelhos e
   where e.tecnico_id = p_tecnico and e.competencia = v_mes and e.substituido_em is null;
  if v_esp.id is null then
    return jsonb_build_object('situacao', 'sem_dados');
  end if;
  -- espelho emitido antes da migration 101 (sem registro de fechamento): o fechamento sem mudança registra agora
  if v_esp.assinado_em is null and not exists (select 1 from ponto_folha_fechamentos f where f.espelho_id = v_esp.id) then
    insert into ponto_folha_fechamentos (empresa_id, tecnico_id, competencia, espelho_id, ocorrencias_confirmadas, fechado_por)
    values (v_esp.empresa_id, p_tecnico, v_mes, v_esp.id, v_conf, v_email);
  end if;
  return jsonb_build_object('situacao', case when v_esp.assinado_em is not null then 'ja_assinado'
                                             when (v_r->>'emitidos')::int > 0 then 'fechado' else 'sem_mudanca' end,
                            'espelho', v_esp.id, 'ocorrencias_confirmadas', jsonb_array_length(v_conf));
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_folga_compensatoria(p_tecnico uuid, p_folga date, p_trabalhado date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_dom_fer boolean;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso,
         coalesce(t.admissao, t.created_at::date) as inicio, t.desligado_em
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico and t.conta_id = fn_conta_atual();
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  -- uma folga por domingo ou feriado: a trava da linha do funcionário evita dois lançamentos ao mesmo tempo
  perform 1 from tecnicos where id = p_tecnico for update;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_folga is null or p_trabalhado is null then raise exception 'Informe o domingo ou feriado trabalhado e o dia da folga.'; end if;
  if p_trabalhado > v_hoje or p_trabalhado < v_hoje - 62 then
    raise exception 'O domingo ou feriado trabalhado precisa estar nos últimos 62 dias.';
  end if;
  v_dom_fer := extract(isodow from p_trabalhado) = 7
               or exists (select 1 from feriados f where f.data = p_trabalhado and f.abrangencia <> 'facultativo');
  if not v_dom_fer then raise exception 'O dia trabalhado precisa ser domingo ou feriado.'; end if;
  if coalesce((fn_ponto_jornada_dia(p_tecnico, p_trabalhado) ->> 'trabalhado_min')::int, 0) = 0 then
    raise exception 'Não há trabalho registrado no ponto em %.', to_char(p_trabalhado, 'DD/MM');
  end if;
  if extract(isodow from p_folga) = 7
     or exists (select 1 from feriados f where f.data = p_folga and f.abrangencia <> 'facultativo') then
    raise exception 'A folga precisa cair em dia de trabalho, não em domingo ou feriado.';
  end if;
  if abs(p_folga - p_trabalhado) > 6 then
    raise exception 'A folga precisa ficar na mesma semana do trabalho (até 6 dias de distância).';
  end if;
  if p_folga > v_hoje + 7 then raise exception 'Folga só até 7 dias à frente.'; end if;
  -- a folga é descanso de verdade: não em sábado que já é de descanso, fora do vínculo nem em dia trabalhado
  -- (revisão do seguranca: senão o 100% sairia sem o funcionário descansar)
  if extract(isodow from p_folga) = 6 and coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true' then
    raise exception 'Sábado já é dia sem expediente: a folga precisa cair de segunda a sexta.';
  end if;
  if p_folga < v_tec.inicio or p_folga > coalesce(v_tec.desligado_em, p_folga) then
    raise exception 'A folga precisa cair dentro do vínculo do funcionário.';
  end if;
  if p_folga <= v_hoje and coalesce((fn_ponto_jornada_dia(p_tecnico, p_folga) ->> 'trabalhado_min')::int, 0) > 0 then
    raise exception 'Há trabalho registrado no ponto em %: não foi folga.', to_char(p_folga, 'DD/MM');
  end if;
  -- folga lançada na hora, não rótulo posto depois numa falta: no máximo 7 dias para trás, e nunca em mês com
  -- espelho já emitido (reemitir depois de lançar)
  if p_folga < v_hoje - 7 then raise exception 'Folga já passada só pode ser lançada até 7 dias depois.'; end if;
  if exists (select 1 from ponto_espelhos e where e.tecnico_id = p_tecnico and e.substituido_em is null
              and e.competencia in (date_trunc('month', p_folga)::date, date_trunc('month', p_trabalhado)::date)) then
    raise exception 'O espelho desse mês já foi emitido: a folga precisa ser lançada antes da emissão.';
  end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.folga_de = p_trabalhado and a.estorno_de is null
              and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'O trabalho de % já tem folga compensatória.', to_char(p_trabalhado, 'DD/MM');
  end if;
  if exists (select 1 from ponto_abonos a where a.tecnico_id = p_tecnico and a.data = p_folga and a.inicio is null
              and a.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
    raise exception 'O dia % já está abonado inteiro.', to_char(p_folga, 'DD/MM');
  end if;
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor, folga_de)
  values (v_tec.empresa_id, p_tecnico, p_folga,
          'Folga compensatória do trabalho em ' || to_char(p_trabalhado, 'DD/MM/YYYY') || ' (Lei 605/1949, art. 9º)',
          v_email, p_trabalhado) returning id into v_id;
  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, '📝 *Ponto · folga compensatória*' || E'\n' || 'Sua folga de '
      || to_char(p_folga, 'DD/MM') || ' compensa o trabalho de ' || to_char(p_trabalhado, 'DD/MM')
      || ': esse dia não é descontado.');
  end if;
  return jsonb_build_object('id', v_id, 'folga', to_char(p_folga, 'DD/MM/YYYY'), 'trabalhado', to_char(p_trabalhado, 'DD/MM/YYYY'));
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_geo(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, bairro text, cidade text, uf text, geo_status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin','gestor']);
  v_conta := fn_conta_atual();
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select m.id, g.bairro, g.cidade, g.uf, coalesce(g.status, 'pendente')
      from ponto_marcacoes m
      join empresas e on e.id = m.empresa_id
      left join ponto_geo g on g.lat3 = round(m.latitude, 3) and g.lng3 = round(m.longitude, 3)
     where m.latitude is not null and m.conta_id = v_conta
       and (m.momento at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or m.tecnico_id = p_tecnico);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_gerar_codigo(p_tecnico uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text;
  v_tec   record;
  v_cod   text := fn_ponto_novo_codigo();
  v_id    uuid := gen_random_uuid();
begin
  v_email := app_exigir(array['admin','gestor']);
  select t.id, t.nome, t.cpf, t.ativo, t.opt_in, t.telefone_e164, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico and t.conta_id = fn_conta_atual();
  if v_tec.id is null then raise exception 'Técnico não encontrado.'; end if;
  if not v_tec.ativo or v_tec.cpf is null then raise exception 'O técnico precisa estar ativo e com CPF cadastrado.'; end if;
  update ponto_codigos set expira_em = now() where tecnico_id = p_tecnico and usado_em is null and expira_em > now();
  insert into ponto_codigos (id, tecnico_id, codigo_hash, origem, criado_por, expira_em)
  values (v_id, p_tecnico, fn_sha256(v_id::text || ':' || v_cod), 'gestor', v_email, now() + interval '15 minutes');
  -- o funcionário fica sabendo: marcação feita com código do gestor nunca passa despercebida
  if v_tec.opt_in then
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_tec.telefone_e164,
          'text', 'Trilha Ponto: o seu gestor gerou um código de acesso ao seu ponto em ' ||
                  to_char(now() at time zone v_tec.fuso, 'DD/MM HH24:MI') ||
                  '. Se não foi a seu pedido, avise o RH.'));
    exception when others then
      raise warning 'app_ponto_gerar_codigo: aviso ao funcionário falhou (%)', sqlerrm;
    end;
  end if;
  return jsonb_build_object('codigo', v_cod, 'nome', v_tec.nome, 'expira_em', now() + interval '15 minutes');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_he_autorizacoes(p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor','leitura']);
  v_ger   boolean := fn_papel(v_email) in ('admin', 'gestor');
begin
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período inválido (até 62 dias).'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', h.id, 'numero', h.numero, 'tecnico_id', h.tecnico_id, 'nome', t.nome, 'data', h.data,
      'hora', to_char(h.inicio at time zone coalesce(e.fuso, 'America/Bahia'), 'HH24:MI'),
      'origem', h.origem, 'status', h.status, 'decidido_em', h.decidido_em, 'canal', h.canal_decisao,
      -- o papel leitura não vê quem decidiu (e-mail)
      'decidido_por', case when v_ger then h.decidido_por end) order by h.status <> 'pendente', h.data desc, h.numero desc)
    from ponto_he_autorizacoes h join tecnicos t on t.id = h.tecnico_id left join empresas e on e.id = h.empresa_id
   where h.data between p_de and p_ate and h.conta_id = fn_conta_atual()), '[]'::jsonb);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_he_decidir(p_id uuid, p_aprovar boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  if not exists (select 1 from ponto_he_autorizacoes where id = p_id and conta_id = fn_conta_atual()) then
    raise exception 'Pedido de hora extra não encontrado.';
  end if;
  return fn_ponto_he_decidir(p_id, p_aprovar, v_email, 'painel');
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_hoje()
 RETURNS TABLE(tecnico_id uuid, tecnico text, empresa text, escala_hora text, escala_local text, marcacoes integer, ultima_tipo text, ultima_hora text, fora_area integer, situacao text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare v_conta uuid;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  v_conta := fn_conta_atual();
  return query
    with base as (
      select t.id, t.nome, coalesce(e.nome_fantasia, e.razao_social) as emp, e.fuso,
             (now() at time zone e.fuso)::date as hoje
        from tecnicos t join empresas e on e.id = t.empresa_id
       where t.ativo and t.cpf is not null and t.conta_id = v_conta
    ), r as (
    select b.id, b.nome, b.emp,
           (select left(min(s.hora_inicio)::text, 5) from escalas s
             where s.tecnico_id = b.id and s.data_servico = b.hoje and s.status not in ('cancelada', 'recusada')) as esc_hora,
           (select l.nome from escalas s join locais l on l.id = s.local_id
             where s.tecnico_id = b.id and s.data_servico = b.hoje and s.status not in ('cancelada', 'recusada')
             order by s.hora_inicio limit 1) as esc_local,
           (select count(*)::int from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje) as qtd,
           (select m.tipo from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje order by m.nsr desc limit 1) as ult_tipo,
           (select to_char(m.momento at time zone b.fuso, 'HH24:MI') from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje order by m.nsr desc limit 1) as ult_hora,
           (select count(*)::int from ponto_marcacoes m where m.tecnico_id = b.id
             and (m.momento at time zone b.fuso)::date = b.hoje and m.dentro_area is false) as fora,
           case
             when exists (select 1 from ponto_marcacoes m where m.tecnico_id = b.id
                           and (m.momento at time zone b.fuso)::date = b.hoje) then 'com_marcacao'
             when exists (select 1 from escalas s where s.tecnico_id = b.id and s.data_servico = b.hoje
                           and s.status not in ('cancelada', 'recusada')
                           and s.hora_inicio < (now() at time zone b.fuso)::time) then 'sem_entrada'
             else 'sem_marcacao'
           end as sit
      from base b
    )
    -- quem tem escala e não bateu entrada vem primeiro
    select r.* from r order by case r.sit when 'sem_entrada' then 0 when 'com_marcacao' then 1 else 2 end, r.nome;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_justificativas(p_de date, p_ate date, p_tecnico uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, numero bigint, tecnico_id uuid, tecnico text, motivo text, motivo_nome text, grupo text, data date, detalhe text, tipo_marcacao text, hora text, hora_ini text, hora_fim text, observacao text, canal text, status text, decidido_por text, decidido_em text, resposta text, criado_em text, abono_estornado boolean, data_fim date, restrito boolean, pode_decidir boolean, anexos integer, alerta_limite text, fora_prazo boolean, ponto_30d integer, dias_uteis_espera integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email   text := app_exigir(array['admin','gestor','leitura']);
  v_leitura boolean := fn_papel(v_email) = 'leitura';
  v_saude   boolean := fn_ve_saude(v_email);
  v_conta   uuid := fn_conta_atual();
begin
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select j.id, j.numero, j.tecnico_id, t.nome,
           case when m.saude and not v_saude then 'saude' else j.motivo end,
           case when m.saude and not v_saude then 'Justificativa de saúde' else m.nome end,
           m.grupo, j.data,
           fn_ponto_pedido_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim, j.data, j.data_fim),
           j.tipo_marcacao, to_char(j.hora, 'HH24:MI'), to_char(j.hora_ini, 'HH24:MI'), to_char(j.hora_fim, 'HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.observacao end, j.canal, j.status,
           case when v_leitura then null else j.decidido_por end,
           to_char(j.decidido_em at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           case when v_leitura or (m.saude and not v_saude) then null else j.resposta end,
           to_char(j.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           exists (select 1 from ponto_abonos x where x.estorno_de = j.abono_id),
           j.data_fim,
           m.grupo <> 'ponto' and not v_saude,
           not v_leitura and (m.grupo = 'ponto' or v_saude),
           (select count(*)::int from ponto_justificativa_anexos a where a.justificativa_id = j.id),
           case when v_leitura or (m.saude and not v_saude) then null else j.alerta_limite end,
           m.grupo <> 'ponto' and j.created_at > ((coalesce(j.data_fim, j.data) + 1)::timestamp at time zone e.fuso) + interval '48 hours',
           -- pedidos de Ponto do funcionário nos 30 dias até este (este incluído), sem os cancelados
           case when not v_leitura and m.grupo = 'ponto' then
             (select count(*)::int from ponto_justificativas o join ponto_motivos om on om.codigo = o.motivo
               where o.tecnico_id = j.tecnico_id and o.status <> 'cancelada' and om.grupo = 'ponto'
                 and o.created_at between j.created_at - interval '30 days' and j.created_at) end,
           case when j.status = 'pendente'
                then fn_dias_uteis((j.created_at at time zone e.fuso)::date, (now() at time zone e.fuso)::date) end
      from ponto_justificativas j
      join tecnicos t on t.id = j.tecnico_id
      join empresas e on e.id = j.empresa_id
      join ponto_motivos m on m.codigo = j.motivo
     where (j.status = 'pendente' or j.data between p_de and p_ate)
       and (p_tecnico is null or j.tecnico_id = p_tecnico)
       and j.conta_id = v_conta
     order by (j.status = 'pendente') desc, j.created_at desc;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_justificativas_metricas(p_de date, p_ate date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor','leitura']);
  v_conta uuid := fn_conta_atual();
  r jsonb;
begin
  if p_ate < p_de or p_ate - p_de > 92 then raise exception 'Período de até 92 dias.'; end if;
  select jsonb_build_object(
    'recebidos', count(*) filter (where j.status <> 'cancelada'),
    'decididos', count(*) filter (where j.status in ('aprovada', 'negada')),
    'no_prazo', count(*) filter (where j.status in ('aprovada', 'negada')
                  and fn_dias_uteis((j.created_at at time zone x.fuso)::date, (j.decidido_em at time zone x.fuso)::date) <= 2),
    'pendentes', count(*) filter (where j.status = 'pendente'),
    'parados', count(*) filter (where j.status = 'pendente'
                  and fn_dias_uteis((j.created_at at time zone x.fuso)::date, (now() at time zone x.fuso)::date) > 2))
    into r
    from ponto_justificativas j
    join lateral (select coalesce(e.fuso, 'America/Bahia') as fuso from empresas e where e.id = j.empresa_id) x on true
   where (j.created_at at time zone x.fuso)::date between p_de and p_ate and j.conta_id = v_conta;
  -- "incluir" lançado pelo gestor sem pedido do funcionário (a meta é não usar para cobrir ausência)
  r := r || jsonb_build_object('inclusoes_manuais',
    (select count(*) from ponto_ajustes a join empresas e on e.id = a.empresa_id
      where a.acao = 'incluir' and a.conta_id = v_conta and (a.created_at at time zone coalesce(e.fuso, 'America/Bahia'))::date between p_de and p_ate
        and not exists (select 1 from ponto_justificativas j where j.ajuste_id = a.id)));
  return r;
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_previa_folha(p_competencia date, p_tecnico uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_mes   date := date_trunc('month', p_competencia)::date;
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'A prévia é de mês já encerrado.';
  end if;
  if not exists (select 1 from tecnicos where id = p_tecnico and cpf is not null and empresa_id is not null
                  and conta_id = fn_conta_atual()) then
    raise exception 'Funcionário não encontrado.';
  end if;
  return jsonb_build_object('conteudo', fn_ponto_folha_conteudo(p_tecnico, v_mes),
                            'pendencias', fn_ponto_folha_pendencias(p_tecnico, v_mes));
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_registrar_alta(p_tecnico uuid, p_data date, p_anexo text, p_anexo_tipo text, p_observacao text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  r       jsonb;
  v_id    uuid;
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos registra a alta.'; end if;
  if not exists (select 1 from tecnicos where id = p_tecnico and conta_id = fn_conta_atual()) then
    raise exception 'Funcionário não encontrado.';
  end if;
  if p_data is null or fn_ponto_afastado_ate(p_tecnico, p_data) is null then
    raise exception 'O funcionário não está afastado nesse dia.';
  end if;
  if p_anexo is null then raise exception 'Anexe a liberação médica (foto ou PDF).'; end if;
  r := fn_ponto_falta_criar(p_tecnico, 'alta_medica', p_data, null, null, null, p_observacao, p_anexo, p_anexo_tipo, 'painel');
  select j.id into v_id from ponto_justificativas j where j.numero = (r->>'numero')::bigint;
  perform app_ponto_decidir(v_id, true, 'Alta registrada pelo gestor com a liberação médica.');
  return jsonb_build_object('numero', r->'numero', 'data', r->'data',
    'afastado_ate', to_char(fn_ponto_afastado_ate(p_tecnico, p_data), 'DD/MM/YYYY'));
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_validar_folha(p_competencia date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_leitura boolean := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  v_mes date := date_trunc('month', p_competencia)::date;
  v_fim date := (date_trunc('month', p_competencia) + interval '1 month')::date - 1;
  v_res jsonb;
  v_conta uuid := fn_conta_atual();
begin
  if p_competencia is null or v_mes >= date_trunc('month', (now() at time zone 'America/Bahia'))::date then
    raise exception 'A folha só é validada e fechada para mês já encerrado.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'tecnico_id', x.id, 'nome', x.nome, 'empresa', x.empresa, 'pendencias', x.p,
           'bloqueios', (select count(*) from jsonb_array_elements(x.p) e where (e->>'bloqueia')::boolean),
           'a_confirmar', (select count(*) from jsonb_array_elements(x.p) e where e->>'nivel' = 'confirmar'),
           'sem_registro', (select count(*) from jsonb_array_elements(x.p) e where e->>'tipo' = 'sem_registro'),
           'com_ponto', x.com_ponto,
           'espelho', x.espelho, 'fechado', x.fechado) order by x.nome), '[]'::jsonb)
    into v_res
    from (select tc.id, tc.nome, coalesce(em.nome_fantasia, em.razao_social) as empresa,
                 fn_ponto_folha_pendencias(tc.id, v_mes) as p,
                 exists (select 1 from ponto_marcacoes m where m.tecnico_id = tc.id
                          and m.momento >= v_mes::timestamp at time zone 'America/Bahia'
                          and m.momento < (v_fim + 1)::timestamp at time zone 'America/Bahia')
                   or exists (select 1 from ponto_abonos a where a.tecnico_id = tc.id and a.data between v_mes and v_fim) as com_ponto,
                 (select jsonb_build_object('id', e.id, 'versao', e.versao, 'registro', e.registro, 'emitido_em', e.emitido_em,
                         'enviado_em', e.enviado_em, 'assinado_em', e.assinado_em)
                    from ponto_espelhos e where e.tecnico_id = tc.id and e.competencia = v_mes and e.substituido_em is null) as espelho,
                 -- o papel leitura não vê quem fechou (como o autor dos ajustes, migrations 65 e 66)
                 (select jsonb_build_object('fechado_por', case when v_leitura then null else f.fechado_por end, 'fechado_em', f.fechado_em,
                         'ocorrencias_confirmadas', jsonb_array_length(f.ocorrencias_confirmadas))
                    from ponto_folha_fechamentos f where f.tecnico_id = tc.id and f.competencia = v_mes
                   order by f.fechado_em desc limit 1) as fechado
            from tecnicos tc join empresas em on em.id = tc.empresa_id
           where tc.cpf is not null and not tc.perfil_teste and tc.conta_id = v_conta
             and coalesce(tc.admissao, tc.created_at::date) <= v_fim
             and (tc.ativo or tc.desligado_em >= v_mes)) x;

  return jsonb_build_object('competencia', v_mes, 'funcionarios', v_res);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_verificar(p_empresa uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  m ponto_marcacoes;
  v_ant text := repeat('0', 64);
  v_esperado bigint := 1;
  v_total int := 0;
begin
  perform app_exigir(array['admin']);
  if not exists (select 1 from empresas where id = p_empresa and conta_id = fn_conta_atual()) then
    raise exception 'Empresa não encontrada.';
  end if;
  for m in select * from ponto_marcacoes where empresa_id = p_empresa order by nsr loop
    if m.nsr <> v_esperado then
      return jsonb_build_object('integra', false, 'nsr', v_esperado, 'motivo', 'lacuna no NSR', 'conferidas', v_total);
    end if;
    if m.hash_anterior <> v_ant or m.hash <> fn_ponto_hash(m) then
      return jsonb_build_object('integra', false, 'nsr', m.nsr, 'motivo', 'hash não confere', 'conferidas', v_total);
    end if;
    v_ant := m.hash; v_esperado := v_esperado + 1; v_total := v_total + 1;
  end loop;
  return jsonb_build_object('integra', true, 'conferidas', v_total);
end $function$

;

CREATE OR REPLACE FUNCTION public.app_ponto_verificar_documento(p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_cod    text;
  r        record;
  v_bin    bytea;
  v_integro boolean;
  v_desc_em timestamptz;
  v_conta  uuid := fn_conta_atual();
begin
  if length(coalesce(p_codigo, '')) > 64 then raise exception 'Código inválido.'; end if;
  if (select count(*) from ponto_documento_verificacoes where email = v_email and em > now() - interval '1 minute') >= 20 then
    raise exception 'Muitas conferências seguidas. Aguarde um minuto.';
  end if;
  v_cod := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z2-7]', '', 'g'));
  select d.*, j.numero, j.status, j.data, j.data_fim, j.decidido_por, j.decidido_em, t.nome as tecnico,
         coalesce(e.nome_fantasia, e.razao_social) as empresa, coalesce(e.fuso, 'America/Bahia') as fuso,
         case when m.saude and not fn_ve_saude(v_email) then 'Justificativa de saúde' else m.nome end as motivo
    into r
    from ponto_documento_registros d
    join ponto_justificativas j on j.id = d.justificativa_id
    join tecnicos t on t.id = j.tecnico_id
    join empresas e on e.id = d.empresa_id
    join ponto_motivos m on m.codigo = j.motivo
   where d.codigo = v_cod and j.conta_id = v_conta;
  if not found then
    insert into ponto_documento_verificacoes (codigo, email, achou, conta_id) values (left(v_cod, 16), v_email, false, v_conta);
    return jsonb_build_object('encontrado', false);
  end if;
  select x.conteudo into v_bin from ponto_justificativa_anexos x where x.id = r.anexo_id;
  if found then
    v_integro := encode(extensions.digest(fn_ponto_cofre_decifrar(v_bin), 'sha256'), 'hex') = r.sha256;
  else
    select pd.em into v_desc_em from ponto_anexos_descartados pd where pd.anexo_id = r.anexo_id order by pd.id desc limit 1;
  end if;
  insert into ponto_documento_verificacoes (codigo, email, achou, integro, conta_id) values (v_cod, v_email, true, v_integro, v_conta);
  return jsonb_build_object('encontrado', true,
    'registro', lpad(r.registro::text, 6, '0'), 'empresa', r.empresa, 'pedido', r.numero, 'tecnico', r.tecnico,
    'motivo', r.motivo, 'periodo', to_char(r.data, 'DD/MM/YYYY') || case when r.data_fim > r.data then ' a ' || to_char(r.data_fim, 'DD/MM/YYYY') else '' end,
    'recebido_em', to_char(r.recebido_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI:SS'),
    'canal', case r.canal when 'whatsapp' then 'WhatsApp' else 'App' end,
    'status', r.status, 'decidido_por', r.decidido_por,
    'decidido_em', to_char(r.decidido_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI'),
    'sha256', r.sha256, 'integro', v_integro,
    'descartado', v_desc_em is not null,
    'descartado_em', to_char(v_desc_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI'));
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
