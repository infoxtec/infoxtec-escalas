-- Massa de validação do ponto de setembro/2026 (pedido do responsável, 13/10). SÓ NA HOMOLOGAÇÃO.
-- Roteiro: docs/roteiro-validacao-ponto-setembro.md. Script de uma vez só: sai do repositório depois de validado.
--
-- Empresa fictícia "Validação do Ponto" (CNPJ de exemplo 88.888.888/0001-91) com 2 funcionários fictícios
-- (CPF de exemplo, telefone com DDD 00, sem autorização de WhatsApp) e o mês de setembro inteiro com todas as
-- situações do espelho: HE 50% e 100%, adicional noturno, faltas, atrasos, tolerância, abonos do gestor,
-- afastamento por atestado, declaração de comparecimento, folga compensatória, ajustes, intervalo não
-- concedido, interjornada curta e sábado trabalhado.
--
-- As marcações são gravadas como o fn_ponto_registrar grava (NSR sem lacuna e hash encadeado da empresa), só
-- com a hora de setembro: a trava "porta única" (hora = agora) fica desligada dentro desta transação. Marcação
-- é imutável: esta empresa e estes funcionários ficam para sempre na homologação (não há "apagar").

do $val$
declare
  v_emp  uuid;
  v_loc  uuid;
  v_a    uuid;   -- Marcos (horas extras, noturno, domingo, feriado, faltas e atrasos)
  v_b    uuid;   -- Juliana (abonos, afastamento, comparecimento e faltas)
  v_j    uuid;
  v_ab   uuid;
  v_id   uuid;
  v_dup  uuid;
  v_n    int := 0;
  v_aut  text := 'Massa de validação (Claude, 13/10)';
  m      record;
  v_m    ponto_marcacoes;
  v_nsr  bigint;
  v_ant  text;
  v_esc  uuid;
begin
  -- trava dupla: só na homologação (config ambiente e nenhuma tarefa no pg_cron)
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job' into v_n; end if;
  if v_n > 0 or coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    raise exception 'Este banco não é a homologação. A massa de validação só roda na homologação.';
  end if;
  if exists (select 1 from empresas where cnpj = '88888888000191') then
    raise exception 'A massa de validação já existe (empresa 88.888.888/0001-91).';
  end if;

  insert into empresas (cnpj, razao_social, nome_fantasia, cidade, uf, fuso, empregadora, ativo)
  values ('88888888000191', 'Validação do Ponto Ltda (fictícia)', 'Validação do Ponto', 'Salvador', 'BA', 'America/Bahia', true, true)
  returning id into v_emp;
  insert into locais (nome, cliente, endereco, cidade, referencia, ativo, latitude, longitude, raio_m, cliente_empresa_id)
  values ('Sede Validação (fictícia)', 'Validação do Ponto (fictícia)', 'Endereço fictício, 1', 'Salvador', 'Validação do ponto',
          true, -12.980000, -38.460000, 200, v_emp)
  returning id into v_loc;

  insert into tecnicos (nome, telefone_e164, funcao, equipe, opt_in, ativo, empresa_id, cpf, admissao)
  values ('Marcos Teixeira (validação)', '5500900008801', 'Técnico de manutenção', 'Validação', false, true, v_emp, '80808080156', '2025-03-10')
  returning id into v_a;
  insert into tecnicos (nome, telefone_e164, funcao, equipe, opt_in, ativo, empresa_id, cpf, admissao)
  values ('Juliana Prado (validação)', '5500900008802', 'Técnica de climatização', 'Validação', false, true, v_emp, '80808080237', '2024-06-03')
  returning id into v_b;

  -- Escalas: dias úteis de setembro às 8h (sem o feriado de 07/09). Marcos tem turnos de tarde/noite em 24, 25
  -- e 28; não há escala na folga dele (22) nem na Juliana em 29 (dia útil sem ponto e sem escala).
  insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, duracao_prevista_min, descricao_tarefa, status, criado_por)
  select t.id, v_loc, d::date,
         case when t.id = v_a and d::date in ('2026-09-24', '2026-09-28') then time '14:00'
              when t.id = v_a and d::date = '2026-09-25' then time '13:00' else time '08:00' end,
         480, 'Manutenção preventiva (validação)', 'confirmada', v_aut
    from generate_series(date '2026-09-01', date '2026-09-30', interval '1 day') d
    cross join (values (v_a), (v_b)) t(id)
   where extract(isodow from d) between 1 and 5 and d::date <> '2026-09-07'
     and not (t.id = v_a and d::date = '2026-09-22')
     and not (t.id = v_b and d::date = '2026-09-29');

  -- Marcações (hora local de Salvador), em ordem: o NSR e o hash seguem a ordem do tempo
  create temp table val_m (tec uuid, dia date, hora time, tipo text, canal text);
  insert into val_m
  -- Marcos: jornada comum 8h–12h / 13h–17h, com as exceções do roteiro
  select v_a, d::date, h.hora, h.tipo, case when extract(day from d)::int % 3 = 0 then 'whatsapp' else 'app' end
    from generate_series(date '2026-09-01', date '2026-09-30', interval '1 day') d
    cross join (values (time '08:00', 'entrada'), (time '12:00', 'saida_almoco'), (time '13:00', 'volta_almoco'), (time '17:00', 'saida')) h(hora, tipo)
   where extract(isodow from d) between 1 and 5
     and d::date not in ('2026-09-01', '2026-09-03', '2026-09-04', '2026-09-07', '2026-09-08', '2026-09-10', '2026-09-15',
                         '2026-09-17', '2026-09-18', '2026-09-22', '2026-09-24', '2026-09-25', '2026-09-28', '2026-09-29');
  insert into val_m (tec, dia, hora, tipo, canal) values
    -- 01: 2 h extras (saída 19h)
    (v_a, '2026-09-01', '08:00', 'entrada', 'app'), (v_a, '2026-09-01', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-01', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-01', '19:00', 'saida', 'app'),
    -- 03: atraso de 40 min sem justificativa
    (v_a, '2026-09-03', '08:40', 'entrada', 'app'), (v_a, '2026-09-03', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-03', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-03', '17:00', 'saida', 'app'),
    -- 04: saída antecipada (16h)
    (v_a, '2026-09-04', '08:00', 'entrada', 'app'), (v_a, '2026-09-04', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-04', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-04', '16:00', 'saida', 'app'),
    -- 07 (feriado): trabalhou 6 h → 100%
    (v_a, '2026-09-07', '08:00', 'entrada', 'app'), (v_a, '2026-09-07', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-07', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-07', '15:00', 'saida', 'app'),
    -- 08: atraso de 7 min (aviso de atraso, mas dentro da tolerância de 10 min no dia: sem débito)
    (v_a, '2026-09-08', '08:07', 'entrada', 'app'), (v_a, '2026-09-08', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-08', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-08', '17:00', 'saida', 'app'),
    -- 10: falta sem justificativa (escala e nenhuma marcação) — nada a inserir
    -- 12 (sábado): 4 h, a jornada do sábado
    (v_a, '2026-09-12', '08:00', 'entrada', 'ura'), (v_a, '2026-09-12', '12:00', 'saida', 'ura'),
    -- 13 (domingo, sem folga): 4 h a 100%
    (v_a, '2026-09-13', '08:00', 'entrada', 'app'), (v_a, '2026-09-13', '12:00', 'saida', 'app'),
    -- 15: 3h30 extras (acima do limite de 2 h)
    (v_a, '2026-09-15', '08:00', 'entrada', 'app'), (v_a, '2026-09-15', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-15', '13:00', 'volta_almoco', 'app'), (v_a, '2026-09-15', '20:30', 'saida', 'app'),
    -- 17: 9 h sem intervalo (intervalo não concedido + 1 h extra)
    (v_a, '2026-09-17', '08:00', 'entrada', 'app'), (v_a, '2026-09-17', '17:00', 'saida', 'app'),
    -- 18: esqueceu a saída (o gestor inclui 17h por ajuste, abaixo)
    (v_a, '2026-09-18', '08:00', 'entrada', 'app'), (v_a, '2026-09-18', '12:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-18', '13:00', 'volta_almoco', 'app'),
    -- 20 (domingo): 4 h, compensado com folga em 22
    (v_a, '2026-09-20', '08:00', 'entrada', 'app'), (v_a, '2026-09-20', '12:00', 'saida', 'app'),
    -- 21: entrada repetida (08:02), desconsiderada por ajuste — vai na lista comum do dia, mais a repetida:
    (v_a, '2026-09-21', '08:02', 'entrada', 'app'),
    -- 24: turno 14h–23h30 com 1 h de intervalo (1h30 noturna)
    (v_a, '2026-09-24', '14:00', 'entrada', 'app'), (v_a, '2026-09-24', '18:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-24', '19:00', 'volta_almoco', 'app'), (v_a, '2026-09-24', '23:30', 'saida', 'app'),
    -- 25: turno 13h–22h
    (v_a, '2026-09-25', '13:00', 'entrada', 'app'), (v_a, '2026-09-25', '17:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-25', '18:00', 'volta_almoco', 'app'), (v_a, '2026-09-25', '22:00', 'saida', 'app'),
    -- 28: turno 14h–23h (1 h noturna)
    (v_a, '2026-09-28', '14:00', 'entrada', 'app'), (v_a, '2026-09-28', '18:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-28', '19:00', 'volta_almoco', 'app'), (v_a, '2026-09-28', '23:00', 'saida', 'app'),
    -- 29: entrada 7h, 8 h depois da saída de 28 (interjornada curta)
    (v_a, '2026-09-29', '07:00', 'entrada', 'app'), (v_a, '2026-09-29', '11:00', 'saida_almoco', 'app'),
    (v_a, '2026-09-29', '12:00', 'volta_almoco', 'app'), (v_a, '2026-09-29', '16:00', 'saida', 'app');

  -- Juliana: jornada comum, com as exceções do roteiro
  insert into val_m
  select v_b, d::date, h.hora, h.tipo, 'app'
    from generate_series(date '2026-09-01', date '2026-09-30', interval '1 day') d
    cross join (values (time '08:00', 'entrada'), (time '12:00', 'saida_almoco'), (time '13:00', 'volta_almoco'), (time '17:00', 'saida')) h(hora, tipo)
   where extract(isodow from d) between 1 and 5
     and d::date not in ('2026-09-02', '2026-09-04', '2026-09-07', '2026-09-08', '2026-09-09', '2026-09-10', '2026-09-15',
                         '2026-09-18', '2026-09-22', '2026-09-23', '2026-09-24', '2026-09-29', '2026-09-30');
  insert into val_m (tec, dia, hora, tipo, canal) values
    -- 02: chegou 9h; o gestor abona 8h–9h (liberalidade)
    (v_b, '2026-09-02', '09:00', 'entrada', 'app'), (v_b, '2026-09-02', '12:00', 'saida_almoco', 'app'),
    (v_b, '2026-09-02', '13:00', 'volta_almoco', 'app'), (v_b, '2026-09-02', '17:00', 'saida', 'app'),
    -- 04: 1 h extra
    (v_b, '2026-09-04', '08:00', 'entrada', 'app'), (v_b, '2026-09-04', '12:00', 'saida_almoco', 'app'),
    (v_b, '2026-09-04', '13:00', 'volta_almoco', 'app'), (v_b, '2026-09-04', '18:00', 'saida', 'app'),
    -- 08 a 10: afastada por atestado (sem marcação)
    -- 15: declaração de comparecimento 8h–10h; chegou às 10h
    (v_b, '2026-09-15', '10:00', 'entrada', 'app'), (v_b, '2026-09-15', '12:00', 'saida_almoco', 'app'),
    (v_b, '2026-09-15', '13:00', 'volta_almoco', 'app'), (v_b, '2026-09-15', '17:00', 'saida', 'app'),
    -- 18: dispensada pela empresa (abono do dia inteiro, sem marcação)
    -- 22 e 23: faltas sem justificativa (escala e nenhuma marcação)
    -- 24: trabalhou de manhã; atestado da tarde (13h–17h)
    (v_b, '2026-09-24', '08:00', 'entrada', 'app'), (v_b, '2026-09-24', '12:00', 'saida', 'app'),
    -- 26 (sábado): 6 h sem intervalo (2 h extras e 15 min de intervalo não concedido)
    (v_b, '2026-09-26', '08:00', 'entrada', 'app'), (v_b, '2026-09-26', '14:00', 'saida', 'app'),
    -- 27 (domingo): 4 h a 100%
    (v_b, '2026-09-27', '08:00', 'entrada', 'app'), (v_b, '2026-09-27', '12:00', 'saida', 'app'),
    -- 29: dia útil sem escala e sem ponto (débito, decisão 84) — nada a inserir
    -- 30: 3 min de atraso e 5 min de saída antecipada (8 min no dia: dentro da tolerância)
    (v_b, '2026-09-30', '08:03', 'entrada', 'app'), (v_b, '2026-09-30', '12:00', 'saida_almoco', 'app'),
    (v_b, '2026-09-30', '13:00', 'volta_almoco', 'app'), (v_b, '2026-09-30', '16:55', 'saida', 'app');

  -- grava como o fn_ponto_registrar: NSR + 1 e hash encadeado, com a hora de setembro
  execute 'alter table ponto_marcacoes disable trigger trg_ponto_marcacoes_porta_unica';
  insert into ponto_nsr (empresa_id) values (v_emp);
  for m in select * from val_m order by (dia + hora), tec loop
    select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = v_emp for update;
    select e.id into v_esc from escalas e where e.tecnico_id = m.tec and e.data_servico = m.dia limit 1;
    v_m := row(gen_random_uuid(), v_emp, v_nsr, m.tec, (select cpf from tecnicos where id = m.tec),
               (m.dia + m.hora) at time zone 'America/Bahia', m.tipo, m.canal,
               case when m.canal = 'ura' then null else -12.980100 end, case when m.canal = 'ura' then null else -38.460100 end,
               case when m.canal = 'ura' then null else 12 end, case when m.canal = 'ura' then null else v_loc end,
               case when m.canal = 'ura' then null else 15 end, case when m.canal = 'ura' then null else true end,
               v_esc, jsonb_build_object('app_versao', 'validacao-setembro'), v_ant, null)::ponto_marcacoes;
    v_m.hash := fn_ponto_hash(v_m);
    insert into ponto_marcacoes select v_m.*;
    update ponto_nsr set ultimo = v_nsr, ultimo_hash = v_m.hash where empresa_id = v_emp;
  end loop;
  execute 'alter table ponto_marcacoes enable trigger trg_ponto_marcacoes_porta_unica';

  -- Ajustes do gestor (Marcos): inclui a saída esquecida de 18 e desconsidera a entrada repetida de 21
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor)
  values (v_emp, v_a, 'incluir', (date '2026-09-18' + time '17:00') at time zone 'America/Bahia', 'saida',
          'Esqueceu de marcar a saída; confirmado com o supervisor do local.', v_aut);
  select id into v_dup from ponto_marcacoes where tecnico_id = v_a and momento = (date '2026-09-21' + time '08:02') at time zone 'America/Bahia';
  insert into ponto_ajustes (empresa_id, tecnico_id, acao, marcacao_id, motivo, autor)
  values (v_emp, v_a, 'desconsiderar', v_dup, 'Entrada marcada duas vezes por engano no app.', v_aut);

  -- Folga compensatória do domingo 20 (Marcos) na terça 22
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor, folga_de)
  values (v_emp, v_a, '2026-09-22', 'Folga compensatória do trabalho em 20/09/2026 (Lei 605/1949, art. 9º)', v_aut, '2026-09-20');

  -- Juliana: abono do gestor do atraso de 02 (8h–9h) e dispensa do dia 18 (liberalidade)
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, motivo, autor)
  values (v_emp, v_b, '2026-09-02', '08:00', '09:00', 'Atraso por pane no transporte da empresa.', v_aut);
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor)
  values (v_emp, v_b, '2026-09-18', 'Dispensada pela empresa (evento interno).', v_aut);

  -- Juliana: afastamento por atestado de 08 a 10 (pedido aprovado e um abono por dia)
  -- o pedido nasce pendente e é aprovado com o abono, como em app_ponto_decidir_justificativa
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, data_fim, canal, observacao, created_at)
  values (v_emp, v_b, 'atestado', '2026-09-08', '2026-09-10', 'app', 'Atestado de 3 dias apresentado.', '2026-09-08 09:00-03')
  returning id into v_j;
  for v_n in 8..10 loop
    insert into ponto_abonos (empresa_id, tecnico_id, data, justificativa_id, motivo, autor)
    values (v_emp, v_b, make_date(2026, 9, v_n), v_j, 'Atestado médico apresentado.', v_aut) returning id into v_ab;
  end loop;
  update ponto_justificativas set status = 'aprovada', decidido_por = v_aut, decidido_em = '2026-09-08 10:00-03', abono_id = v_ab where id = v_j;

  -- Juliana: declaração de comparecimento 8h–10h em 15
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, hora_ini, hora_fim, canal, created_at)
  values (v_emp, v_b, 'comparecimento', '2026-09-15', '08:00', '10:00', 'app', '2026-09-15 10:30-03')
  returning id into v_j;
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, motivo, autor)
  values (v_emp, v_b, '2026-09-15', '08:00', '10:00', v_j, 'Declaração de comparecimento apresentada.', v_aut) returning id into v_ab;
  update ponto_justificativas set status = 'aprovada', decidido_por = v_aut, decidido_em = '2026-09-15 11:00-03', abono_id = v_ab where id = v_j;

  -- Juliana: atestado da tarde de 24 (13h–17h)
  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, data_fim, hora_ini, hora_fim, canal, created_at)
  values (v_emp, v_b, 'atestado', '2026-09-24', '2026-09-24', '13:00', '17:00', 'app', '2026-09-24 12:30-03')
  returning id into v_j;
  insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, motivo, autor)
  values (v_emp, v_b, '2026-09-24', '13:00', '17:00', v_j, 'Atestado médico apresentado.', v_aut) returning id into v_ab;
  update ponto_justificativas set status = 'aprovada', decidido_por = v_aut, decidido_em = '2026-09-25 09:00-03', abono_id = v_ab where id = v_j;

  raise notice 'Massa de validação criada: empresa %, Marcos %, Juliana %, % marcações.',
    v_emp, v_a, v_b, (select count(*) from ponto_marcacoes where empresa_id = v_emp);
end $val$;
