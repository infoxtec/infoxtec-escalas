-- Limpeza da homologação e carga geral nova (pedido do responsável, 13/10; backlog 104). SÓ NA HOMOLOGAÇÃO.
-- AINDA NÃO RODAR: em teste pelo Claude (transação desfeita) depois que a homologação tiver as migrations 96 e 97.
-- Script de uma vez só: sai do repositório depois de aplicado e validado (CLAUDE.md).
--
-- Roda DEPOIS das migrations 96 e 97 (limite de HE e espelho pela escala). Uso: no SQL Editor da homologação
-- (infoxtec-escalas-dev), colar tudo e executar. Dura alguns segundos.
--
-- 1) LIMPA os dados de operação: empresas, locais, funcionários, times, escalas e atribuições, Programações (com
--    notificações, respostas, ligações e eventos) e todo o ponto (marcações, ajustes, pedidos, abonos, espelhos,
--    documentos, AFD, sessões). As travas de imutabilidade do ponto saem só dentro desta transação.
--    FICAM: usuários do painel e seus registros, config (inclusive telefones de homologação), feriados, motivos
--    do ponto, habilidades, tipos de atividade e de documento, backlog. Arquivos de anexos no Storage não são
--    apagados (ficam órfãos; não aparecem em lugar nenhum).
-- 2) CARREGA o mês corrente até ontem, com dados fictícios (CPF e CNPJ de exemplo, telefone com DDD 00, sem
--    autorização de WhatsApp: nada é enviado a ninguém):
--    - Infoxtec (empregadora; o CNPJ cadastrado hoje é mantido) com os times Instalação e Manutenção;
--      escala "Jornada padrão" na empresa e "40h 5x2 (8h)" no time Manutenção;
--    - Alfa Serviços Técnicos (fictícia, empregadora) com o time Plantão: "44h 6x1 (7h20)" na empresa e
--      12x36 diurna (07h) para dois funcionários, em dias alternados;
--    - Condomínio Atlântico (fictício, cliente) com 3 locais em Salvador;
--    - 10 funcionários, 1 supervisor por empregadora; Programação em cada dia de trabalho;
--    - marcações com casos do dia a dia: jornada normal, atraso, hora extra acima do limite (Alerta Crítico),
--      falta, sábado e domingo trabalhados, plantão 12x36; um atestado aprovado e um pedido pendente;
--    - Programações dos próximos 7 dias como rascunho (não saem pelo WhatsApp).

-- CPF de exemplo: 9 dígitos + os dois verificadores (função temporária, some ao fim da sessão)
create or replace function pg_temp.fn_carga_cpf_exemplo(p_base text) returns text language plpgsql as $f$
declare s int := 0; d1 int; d2 int; i int;
begin
  for i in 1..9 loop s := s + substr(p_base, i, 1)::int * (11 - i); end loop;
  d1 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  s := 0;
  for i in 1..9 loop s := s + substr(p_base, i, 1)::int * (12 - i); end loop;
  s := s + d1 * 2;
  d2 := case when s % 11 < 2 then 0 else 11 - s % 11 end;
  return p_base || d1 || d2;
end $f$;

do $carga$
declare
  v_n      int := 0;
  v_cnpj   text;
  v_inf    uuid; v_alfa uuid; v_cli uuid;
  v_l1     uuid; v_l2 uuid; v_l3 uuid;
  v_pad    uuid; v_5x2 uuid; v_6x1 uuid; v_12  uuid;
  v_tm     uuid;
  v_ini    date := date_trunc('month', current_date)::date;
  v_ontem  date := current_date - 1;
  v_aut    text := 'Carga geral da homologação';
  t        record;
  d        date;
  c        jsonb;
  v_r      int;
  v_ent    time;
  v_min    int;
  v_loc    uuid;
  v_esc    uuid;
  m        record;
  v_m      ponto_marcacoes;
  v_nsr    bigint;
  v_ant    text;
  v_j      uuid;
  v_ab     uuid;
  v_tab    text;
begin
  -- trava dupla: só na homologação (config ambiente e nenhuma tarefa no pg_cron)
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job' into v_n; end if;
  if v_n > 0 or coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    raise exception 'Este banco não é a homologação. A limpeza e a carga só rodam na homologação.';
  end if;
  if to_regprocedure('fn_carga_dia(uuid,date)') is null or to_regclass('public.programacao_aceites') is null then
    raise exception 'Aplique antes as migrations 96 e 97 (./scripts/aplicar-homologacao.sh).';
  end if;
  if v_ontem < v_ini then
    raise exception 'Hoje é o primeiro dia do mês: rode a partir de amanhã para ter dias passados no mês.';
  end if;
  v_cnpj := coalesce((select e.cnpj from empresas e where e.razao_social ilike 'infoxtec%' and e.empregadora order by e.created_at limit 1),
                     '11444777000161');

  -- 1) Limpeza ---------------------------------------------------------------------------------------------
  foreach v_tab in array array[
    'ponto_espelho_acessos', 'ponto_espelhos', 'ponto_espelho_sequencia', 'ponto_documento_verificacoes',
    'ponto_documento_registros', 'ponto_documento_sequencia', 'ponto_afd_geracoes', 'ponto_anexo_acessos',
    'ponto_anexos_descartados', 'ponto_justificativa_anexos', 'ponto_justificativas', 'ponto_abonos', 'ponto_ajustes',
    'ponto_marcacoes', 'ponto_nsr', 'ponto_geo', 'ponto_ciencias', 'ponto_codigos', 'ponto_conversas', 'ponto_sessoes',
    'ponto_acessos', 'programacao_aceites', 'carga_aceites', 'carga_atribuicoes', 'cargas_horarias',
    'respostas', 'ligacoes', 'notificacoes', 'escala_eventos', 'ocorrencias', 'escalas', 'webhook_eventos',
    'alertas_enviados', 'log_exclusoes', 'dossie_geracoes', 'documentos', 'tecnico_documentos', 'tecnico_habilidades',
    'tecnicos', 'times', 'locais', 'empresas'] loop
    if to_regclass('public.' || v_tab) is not null then
      execute format('alter table %I disable trigger user', v_tab);
    end if;
  end loop;
  execute 'truncate ponto_espelho_acessos, ponto_espelhos, ponto_espelho_sequencia, ponto_documento_verificacoes,
    ponto_documento_registros, ponto_documento_sequencia, ponto_afd_geracoes, ponto_anexo_acessos, ponto_anexos_descartados,
    ponto_justificativa_anexos, ponto_justificativas, ponto_abonos, ponto_ajustes, ponto_marcacoes, ponto_nsr, ponto_geo,
    ponto_ciencias, ponto_codigos, ponto_conversas, ponto_sessoes, ponto_acessos, programacao_aceites, carga_aceites,
    carga_atribuicoes, cargas_horarias, respostas, ligacoes, notificacoes, escala_eventos, ocorrencias, escalas,
    webhook_eventos, alertas_enviados, log_exclusoes, dossie_geracoes, documentos, tecnico_documentos, tecnico_habilidades,
    tecnicos, times, locais, empresas';
  foreach v_tab in array array[
    'ponto_espelho_acessos', 'ponto_espelhos', 'ponto_documento_verificacoes', 'ponto_documento_registros',
    'ponto_documento_sequencia', 'ponto_afd_geracoes', 'ponto_anexo_acessos', 'ponto_anexos_descartados',
    'ponto_justificativa_anexos', 'ponto_justificativas', 'ponto_abonos', 'ponto_ajustes', 'ponto_marcacoes', 'ponto_nsr',
    'programacao_aceites', 'carga_aceites', 'carga_atribuicoes', 'cargas_horarias', 'escalas', 'dossie_geracoes', 'tecnicos'] loop
    execute format('alter table %I enable trigger user', v_tab);
  end loop;
  -- a porta única (marcação na hora de agora) fica desligada até o fim da carga
  execute 'alter table ponto_marcacoes disable trigger trg_ponto_marcacoes_porta_unica';

  -- 2) Carga -----------------------------------------------------------------------------------------------
  insert into empresas (cnpj, razao_social, nome_fantasia, cidade, uf, fuso, empregadora, ativo)
  values (v_cnpj, 'Infoxtec Tecnologia (homologação)', 'Infoxtec', 'Salvador', 'BA', 'America/Bahia', true, true) returning id into v_inf;
  insert into empresas (cnpj, razao_social, nome_fantasia, cidade, uf, fuso, empregadora, ativo)
  values ('11222333000181', 'Alfa Serviços Técnicos Ltda (fictícia)', 'Alfa Serviços', 'Salvador', 'BA', 'America/Bahia', true, true) returning id into v_alfa;
  insert into empresas (cnpj, razao_social, nome_fantasia, cidade, uf, fuso, empregadora, ativo)
  values ('88888888000191', 'Condomínio Atlântico (fictício)', 'Condomínio Atlântico', 'Salvador', 'BA', 'America/Bahia', false, true) returning id into v_cli;

  insert into locais (nome, cliente, endereco, cidade, referencia, ativo, latitude, longitude, raio_m, cliente_empresa_id) values
    ('Torre A – Atlântico (fictícia)', 'Condomínio Atlântico', 'Av. Oceânica, 100', 'Salvador', 'Portaria principal', true, -13.004000, -38.523000, 200, v_cli)
    returning id into v_l1;
  insert into locais (nome, cliente, endereco, cidade, referencia, ativo, latitude, longitude, raio_m, cliente_empresa_id) values
    ('Torre B – Atlântico (fictícia)', 'Condomínio Atlântico', 'Av. Oceânica, 120', 'Salvador', 'Garagem', true, -13.004500, -38.522000, 200, v_cli)
    returning id into v_l2;
  insert into locais (nome, cliente, endereco, cidade, referencia, ativo, latitude, longitude, raio_m, cliente_empresa_id) values
    ('Central de Monitoramento (fictícia)', 'Condomínio Atlântico', 'Rua da Central, 5', 'Salvador', 'Sala técnica', true, -12.980000, -38.460000, 200, v_cli)
    returning id into v_l3;

  -- funcionários (CPF de exemplo com dígito válido, telefone DDD 00, sem autorização de WhatsApp)
  create temp table carga_tec (id uuid, nome text, empresa uuid, equipe text, sup boolean, ordem int) on commit drop;
  insert into carga_tec (nome, empresa, equipe, sup, ordem) values
    ('Ana Souza (homologação)', v_inf, 'Instalação', false, 1),
    ('Bruno Lima (homologação)', v_inf, 'Instalação', false, 2),
    ('Carla Dias (homologação)', v_inf, 'Instalação', true, 3),
    ('Diego Rocha (homologação)', v_inf, 'Manutenção', false, 4),
    ('Elisa Matos (homologação)', v_inf, 'Manutenção', false, 5),
    ('Fábio Nunes (homologação)', v_inf, 'Manutenção', false, 6),
    ('Gabriela Reis (homologação)', v_alfa, 'Plantão', false, 7),
    ('Hugo Santos (homologação)', v_alfa, 'Plantão', false, 8),
    ('Íris Pinto (homologação)', v_alfa, 'Plantão', true, 9),
    ('João Freitas (homologação)', v_alfa, 'Plantão', false, 10);
  for t in select * from carga_tec order by ordem loop
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, ativo, perfil_teste, empresa_id, cpf, matricula, admissao)
    values (t.nome, '55009000091' || lpad(t.ordem::text, 2, '0'), case when t.sup then 'Supervisor' else 'Técnico de campo' end,
            t.equipe, t.sup, false, true, false, t.empresa, pg_temp.fn_carga_cpf_exemplo('9000000' || lpad(t.ordem::text, 2, '0')),
            'H' || lpad(t.ordem::text, 3, '0'), v_ini - 400)
    returning id into v_j;
    update carga_tec set id = v_j where ordem = t.ordem;
  end loop;

  -- escalas e atribuições desde o 1º dia do mês (a função do painel só aceita de hoje em diante; aqui é carga)
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, intervalo_min, semanal_min, riscos, criado_por, dsr_dia)
  values (v_inf, 'Jornada padrão (8h00 + 4h00 sábado)', 'semanal', array[480,480,480,480,480,240,0], 60, 2640, '[]', v_aut, 7) returning id into v_pad;
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, intervalo_min, semanal_min, riscos, criado_por, dsr_dia)
  values (v_inf, '40h 5x2 (8h)', 'semanal', array[480,480,480,480,480,0,0], 60, 2400, '[]', v_aut, 7) returning id into v_5x2;
  insert into cargas_horarias (empresa_id, nome, tipo, minutos, intervalo_min, semanal_min, riscos, criado_por, dsr_dia)
  values (v_alfa, '44h 6x1 (7h20)', 'semanal', array[440,440,440,440,440,440,0], 60, 2640, '[]', v_aut, 7) returning id into v_6x1;
  insert into cargas_horarias (empresa_id, nome, tipo, plantao_min, intervalo_min, entrada, semanal_min, riscos, criado_por)
  values (v_alfa, '12x36 diurna (07h)', '12x36', 660, 60, '07:00', 2310,
          '[{"codigo": "12x36", "texto": "A 12x36 exige acordo individual escrito, convenção ou acordo coletivo (CLT art. 59-A)."}]', v_aut)
  returning id into v_12;
  insert into carga_aceites (carga_id, empresa_id, riscos, instrumento, texto, sha256, nome, email, papel)
  select v_12, v_alfa, riscos, 'Acordo individual escrito (fictício, homologação)', 'Aceite de exemplo da carga da homologação.',
         encode(sha256(convert_to('Aceite de exemplo da carga da homologação.', 'UTF8')), 'hex'), v_aut, 'carga@homologacao', 'admin'
    from cargas_horarias where id = v_12;
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, inicio, fim, criado_por) values
    (v_pad, v_inf, 'empresa', v_ini, v_ini + 364, v_aut),
    (v_6x1, v_alfa, 'empresa', v_ini, v_ini + 364, v_aut);
  select id into v_tm from times where empresa_id = v_inf and nome = 'Manutenção';
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, time_id, inicio, fim, criado_por)
  values (v_5x2, v_inf, 'time', v_tm, v_ini, v_ini + 364, v_aut);
  -- 12x36: Gabriela começa no dia 1, Hugo no dia 2 (dias alternados)
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, tecnico_id, inicio, fim, criado_por)
  select v_12, v_alfa, 'tecnico', id, v_ini + case when ordem = 7 then 0 else 1 end, v_ini + 364, v_aut
    from carga_tec where ordem in (7, 8);

  -- Programações e marcações, dia a dia, pela escala de cada um ------------------------------------------
  create temp table carga_m (tec uuid, emp uuid, dia date, hora time, tipo text, canal text, loc uuid) on commit drop;
  for t in select * from carga_tec order by ordem loop
    for d in select g::date from generate_series(v_ini, v_ontem, interval '1 day') g loop
      c := fn_carga_dia(t.id, d);
      v_min := (c->>'minutos')::int;
      v_r := abs(hashtext(t.id::text || d::text)) % 100;   -- sorteio fixo por funcionário e dia
      v_loc := case t.ordem % 3 when 0 then v_l3 when 1 then v_l1 else v_l2 end;
      v_ent := case when c->>'tipo' = '12x36' then time '07:00' when t.ordem in (4, 5) then time '07:30' else time '08:00' end;
      -- casos fora da escala: Bruno trabalha um domingo; Diego (5x2) trabalha um sábado
      if v_min = 0 then
        if (t.ordem = 2 and extract(isodow from d) = 7 and extract(day from d) between 8 and 14)
           or (t.ordem = 4 and extract(isodow from d) = 6 and extract(day from d) between 1 and 7) then
          insert into carga_m values (t.id, t.empresa, d, '08:00', 'entrada', 'app', v_loc), (t.id, t.empresa, d, '12:00', 'saida', 'app', v_loc);
        end if;
        continue;
      end if;
      if not exists (select 1 from feriados f where f.data = d and f.abrangencia <> 'facultativo') then
        insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, duracao_prevista_min, descricao_tarefa, status, criado_por)
        values (t.id, v_loc, d, v_ent, v_min, 'Manutenção preventiva (homologação)', 'confirmada', v_aut);
      else
        continue;
      end if;
      continue when v_r < 4 and not t.sup;                       -- falta (cerca de 4%)
      if v_r between 4 and 11 then v_ent := v_ent + interval '17 minutes'; end if;   -- atraso
      insert into carga_m values (t.id, t.empresa, d, v_ent, 'entrada', case when v_r % 5 = 0 then 'whatsapp' else 'app' end, v_loc);
      if v_min > 360 then   -- almoço de 1 h depois de 4 h
        insert into carga_m values (t.id, t.empresa, d, v_ent + interval '4 hours', 'saida_almoco', 'app', v_loc),
                                   (t.id, t.empresa, d, v_ent + interval '5 hours', 'volta_almoco', 'app', v_loc);
      end if;
      insert into carga_m values (t.id, t.empresa, d, v_ent + make_interval(mins => v_min + case when v_min > 360 then 60 else 0 end
                + case when v_r between 90 and 95 then 190          -- hora extra acima do limite (Alerta Crítico)
                       when v_r between 80 and 89 then 60 else 0 end), 'saida', 'app', v_loc);
    end loop;
  end loop;

  -- grava como o fn_ponto_registrar: NSR + 1 e hash encadeado por empresa, na ordem do tempo
  insert into ponto_nsr (empresa_id) values (v_inf), (v_alfa);
  for m in select * from carga_m order by (dia + hora), tec loop
    select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = m.emp for update;
    select e.id into v_esc from escalas e where e.tecnico_id = m.tec and e.data_servico = m.dia limit 1;
    v_m := row(gen_random_uuid(), m.emp, v_nsr, m.tec, (select cpf from tecnicos where id = m.tec),
               (m.dia + m.hora) at time zone 'America/Bahia', m.tipo, m.canal,
               case when m.canal = 'ura' then null else -13.004100 end, case when m.canal = 'ura' then null else -38.523100 end,
               case when m.canal = 'ura' then null else 12 end, m.loc, case when m.canal = 'ura' then null else 15 end,
               case when m.canal = 'ura' then null else true end,
               v_esc, jsonb_build_object('app_versao', 'carga-homologacao'), v_ant, null)::ponto_marcacoes;
    v_m.hash := fn_ponto_hash(v_m);
    insert into ponto_marcacoes select v_m.*;
    update ponto_nsr set ultimo = v_nsr, ultimo_hash = v_m.hash where empresa_id = m.emp;
  end loop;
  execute 'alter table ponto_marcacoes enable trigger trg_ponto_marcacoes_porta_unica';

  -- uma falta com atestado aprovado (Ana) e um pedido pendente de inclusão de marcação (Elisa)
  select e.data_servico into d from escalas e join carga_tec x on x.id = e.tecnico_id
   where x.ordem = 1 and not exists (select 1 from carga_m m2 where m2.tec = e.tecnico_id and m2.dia = e.data_servico)
   order by e.data_servico limit 1;
  if d is not null then
    insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, data_fim, canal, observacao, created_at)
    values (v_inf, (select id from carga_tec where ordem = 1), 'atestado', d, d, 'app', 'Atestado de 1 dia.', (d + time '09:00') at time zone 'America/Bahia')
    returning id into v_j;
    insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
    values (v_inf, (select id from carga_tec where ordem = 1), d, v_j, 'Atestado médico apresentado.', v_aut) returning id into v_ab;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_aut, decidido_em = (d + time '10:00') at time zone 'America/Bahia', abono_id = v_ab
     where id = v_j;
  end if;
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, tipo_marcacao, hora, canal, observacao)
  select v_inf, id, 'esqueci_marcar', v_ontem - 1, 'saida', '17:30', 'app', 'Esqueci de marcar a saída.'
    from carga_tec where ordem = 5;

  -- próximos 7 dias: Programações em rascunho (não saem pelo WhatsApp)
  for t in select * from carga_tec order by ordem loop
    for d in select g::date from generate_series(current_date + 1, current_date + 7, interval '1 day') g loop
      v_min := (fn_carga_dia(t.id, d)->>'minutos')::int;
      continue when v_min = 0;
      insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, duracao_prevista_min, descricao_tarefa, status, criado_por)
      values (t.id, case t.ordem % 3 when 0 then v_l3 when 1 then v_l1 else v_l2 end, d,
              case when fn_carga_dia(t.id, d)->>'tipo' = '12x36' then time '07:00' else time '08:00' end, v_min,
              'Programação da semana (homologação)', 'rascunho', v_aut);
    end loop;
  end loop;

  raise notice 'Carga geral pronta: % empresas, % times, % funcionários, % escalas, % Programações, % marcações (de % a %).',
    (select count(*) from empresas), (select count(*) from times), (select count(*) from tecnicos),
    (select count(*) from cargas_horarias), (select count(*) from escalas), (select count(*) from ponto_marcacoes),
    to_char(v_ini, 'DD/MM'), to_char(v_ontem, 'DD/MM');
end $carga$;
