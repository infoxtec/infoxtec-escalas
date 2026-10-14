-- Carga de ponto de junho a setembro de 2026 na HOMOLOGAÇÃO, para o fechamento da folha e a assinatura dos
-- espelhos (pedido do responsável, 14/10). Só registro de ponto: não cria Programação e não envia WhatsApp.
-- Script de uma vez só: sai do repositório depois de aplicado (CLAUDE.md).
--
-- Três funcionários da carga geral, os que têm WhatsApp de teste:
--   Ana Souza    (Infoxtec)  Jornada padrão 44h 6x1 (8h + 4h sábado), atribuída à empresa de 01/06 a 30/09
--   Bruno Lima   (Infoxtec)  40h 5x2 (sábado é folga, domingo é DSR), atribuída a ele de 01/06 a 30/09
--   Gabriela Reis (Alfa)     12x36 diurna 07h (plantão de 11 h), atribuída a ela de 01/06 a 30/09, plantão em 01/06
-- Situações (lista completa em docs/plano-de-trabalho.md, 14/10): atraso dentro e fora da tolerância, saída
-- antecipada, HE 50% de 1h30, 2h e 3h30 (acima do limite), HE noturna (saída às 23h) e interjornada de 9h no dia
-- seguinte, intervalo de 40 min, jornada sem intervalo, marcação incompleta, falta, falta abonada (comparecimento
-- como testemunha, CLT art. 473, VIII), sábado de folga trabalhado (50%), domingo DSR trabalhado (100%), domingo com
-- folga compensatória (sem 100%), feriado trabalhado (100%), feriado não trabalhado (sem débito), Corpus Christi
-- (ponto facultativo, dia normal), 12x36 com plantão no feriado (compensado), folga da 12x36 trabalhada (50%).
-- Ana fica SEM marcação de 01/09 a 08/09: o atestado entra pelo WhatsApp (pedido de ajuste do funcionário).
--
-- Também libera na trava de envio o WhatsApp da Gabriela (5571987279976), para ela receber o espelho.
do $carga$
declare
  v_ini   date := date '2026-06-01';
  v_fim   date := date '2026-09-30';
  v_aut   text := 'Carga de ponto jun-set da homologação';
  v_inf   uuid; v_alfa uuid;
  v_ana   uuid; v_bruno uuid; v_gabi uuid;
  v_pad   uuid; v_5x2 uuid; v_12 uuid;
  v_loc   uuid;
  t       record; m record;
  d       date;
  c       jsonb;
  v_contr int; v_plant boolean; v_fer boolean;
  k       text;
  v_ent   time; v_sai time; v_alm int;
  v_m     ponto_marcacoes;
  v_nsr   bigint; v_ant text;
  v_esc   uuid;
  n_marc  int := 0;
begin
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    raise exception 'Este banco não é a homologação. Nada foi alterado.';
  end if;
  select id into v_inf from empresas where nome_fantasia = 'Infoxtec';
  select id into v_alfa from empresas where nome_fantasia = 'Alfa Serviços';
  select id into v_ana from tecnicos where nome = 'Ana Souza (homologação)';
  select id into v_bruno from tecnicos where nome = 'Bruno Lima (homologação)';
  select id into v_gabi from tecnicos where nome = 'Gabriela Reis (homologação)';
  select id into v_pad from cargas_horarias where empresa_id = v_inf and nome like 'Jornada padrão%';
  select id into v_5x2 from cargas_horarias where empresa_id = v_inf and nome like '40h 5x2%';
  select id into v_12 from cargas_horarias where empresa_id = v_alfa and nome like '12x36%';
  if v_inf is null or v_alfa is null or v_ana is null or v_bruno is null or v_gabi is null
     or v_pad is null or v_5x2 is null or v_12 is null then
    raise exception 'A carga geral da homologação (empresas, funcionários e escalas) não foi encontrada.';
  end if;
  if exists (select 1 from ponto_marcacoes where tecnico_id in (v_ana, v_bruno, v_gabi)
              and momento < (date '2026-10-01')::timestamp at time zone 'America/Bahia') then
    raise exception 'Já existe ponto antes de outubro para esses funcionários: a carga já foi aplicada.';
  end if;
  select id into v_loc from locais order by nome limit 1;

  -- escalas de junho a setembro (a atribuição de outubro em diante, da carga geral, continua)
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, inicio, fim, criado_por)
  values (v_pad, v_inf, 'empresa', v_ini, v_fim, v_aut);
  insert into carga_atribuicoes (carga_id, empresa_id, alvo, tecnico_id, inicio, fim, criado_por) values
    (v_5x2, v_inf, 'tecnico', v_bruno, v_ini, v_fim, v_aut),
    (v_12, v_alfa, 'tecnico', v_gabi, v_ini, v_fim, v_aut);

  -- o que muda em cada dia (o resto é jornada normal pela escala)
  create temp table cp_ov (tec uuid, dia date, k text) on commit drop;
  insert into cp_ov values
    -- Ana, 6x1
    (v_ana, '2026-06-02', 'atraso7'), (v_ana, '2026-06-03', 'atraso25'), (v_ana, '2026-06-05', 'he90'),
    (v_ana, '2026-06-09', 'he120'), (v_ana, '2026-06-10', 'he210'), (v_ana, '2026-06-12', 'saida_cedo'),
    (v_ana, '2026-06-16', 'intervalo40'), (v_ana, '2026-06-18', 'noturno'), (v_ana, '2026-06-21', 'extra4'),
    (v_ana, '2026-06-26', 'falta'),
    (v_ana, '2026-07-02', 'extra8'), (v_ana, '2026-07-07', 'he120'), (v_ana, '2026-07-12', 'extra6'),
    (v_ana, '2026-07-15', 'falta'), (v_ana, '2026-07-20', 'atraso25'), (v_ana, '2026-07-22', 'sem_intervalo'),
    (v_ana, '2026-07-28', 'incompleta'),
    (v_ana, '2026-08-04', 'he90'), (v_ana, '2026-08-08', 'he120'), (v_ana, '2026-08-11', 'falta'),
    (v_ana, '2026-08-13', 'saida_cedo'), (v_ana, '2026-08-16', 'extra4'), (v_ana, '2026-08-19', 'atraso7'),
    (v_ana, '2026-08-25', 'he210'), (v_ana, '2026-08-27', 'noturno'),
    (v_ana, '2026-09-01', 'falta'), (v_ana, '2026-09-02', 'falta'), (v_ana, '2026-09-03', 'falta'),
    (v_ana, '2026-09-04', 'falta'), (v_ana, '2026-09-05', 'falta'), (v_ana, '2026-09-07', 'falta'),
    (v_ana, '2026-09-08', 'falta'),
    (v_ana, '2026-09-10', 'he120'), (v_ana, '2026-09-15', 'atraso25'), (v_ana, '2026-09-22', 'intervalo40'),
    (v_ana, '2026-09-29', 'he90'),
    -- Bruno, 5x2
    (v_bruno, '2026-06-06', 'extra4'), (v_bruno, '2026-06-11', 'atraso25'), (v_bruno, '2026-06-17', 'he120'),
    (v_bruno, '2026-06-24', 'extra8'), (v_bruno, '2026-06-30', 'he210'),
    (v_bruno, '2026-07-04', 'extra5'), (v_bruno, '2026-07-09', 'falta'), (v_bruno, '2026-07-14', 'intervalo40'),
    (v_bruno, '2026-07-19', 'extra4'), (v_bruno, '2026-07-21', 'falta'), (v_bruno, '2026-07-30', 'noturno'),
    (v_bruno, '2026-08-03', 'atraso7'), (v_bruno, '2026-08-12', 'he90'), (v_bruno, '2026-08-15', 'extra4'),
    (v_bruno, '2026-08-23', 'extra4'), (v_bruno, '2026-08-26', 'saida_cedo'), (v_bruno, '2026-08-28', 'incompleta'),
    (v_bruno, '2026-09-07', 'extra8'), (v_bruno, '2026-09-12', 'extra4'), (v_bruno, '2026-09-16', 'he120'),
    (v_bruno, '2026-09-24', 'atraso25'),
    -- Gabriela, 12x36 (plantão nos dias pares contados de 01/06)
    (v_gabi, '2026-06-03', 'he120'), (v_gabi, '2026-06-09', 'atraso25'), (v_gabi, '2026-06-15', 'sem_intervalo'),
    (v_gabi, '2026-06-21', 'falta'),
    (v_gabi, '2026-07-01', 'he90'), (v_gabi, '2026-07-13', 'intervalo40'), (v_gabi, '2026-07-21', 'noturno'),
    (v_gabi, '2026-08-02', 'he210'), (v_gabi, '2026-08-10', 'atraso7'), (v_gabi, '2026-08-17', 'extra6'),
    (v_gabi, '2026-08-24', 'saida_cedo'),
    (v_gabi, '2026-09-15', 'he120'), (v_gabi, '2026-09-23', 'incompleta');

  create temp table cp_m (tec uuid, emp uuid, dia date, hora time, tipo text) on commit drop;
  for t in select v_ana as id, v_inf as emp union all select v_bruno, v_inf union all select v_gabi, v_alfa loop
    for d in select g::date from generate_series(v_ini, v_fim, interval '1 day') g loop
      c := fn_carga_dia(t.id, d);
      v_contr := coalesce((c->>'minutos')::int, 0);
      v_plant := c->>'tipo' = '12x36';
      v_fer := exists (select 1 from feriados f where f.data = d and f.abrangencia <> 'facultativo');
      select o.k into k from cp_ov o where o.tec = t.id and o.dia = d;
      continue when k = 'falta';
      -- trabalho fora da jornada: folga, DSR ou feriado (extraN = N horas; 8 h com 1 h de almoço)
      if k like 'extra%' then
        v_ent := case when v_plant then time '07:00' else time '08:00' end;
        if substr(k, 6)::int > 6 then
          insert into cp_m values (t.id, t.emp, d, v_ent, 'entrada'), (t.id, t.emp, d, v_ent + interval '4 hours', 'saida_almoco'),
            (t.id, t.emp, d, v_ent + interval '5 hours', 'volta_almoco'),
            (t.id, t.emp, d, v_ent + make_interval(hours => substr(k, 6)::int + 1), 'saida');
        else
          insert into cp_m values (t.id, t.emp, d, v_ent, 'entrada'),
            (t.id, t.emp, d, v_ent + make_interval(hours => substr(k, 6)::int), 'saida');
        end if;
        continue;
      end if;
      continue when v_contr = 0 or (v_fer and not v_plant);
      v_ent := case when v_plant then time '07:00' else time '08:00' end;
      v_alm := case when v_contr > 360 then 60 else 0 end;
      if k = 'intervalo40' then v_alm := 40; elsif k = 'sem_intervalo' then v_alm := 0; end if;
      v_sai := v_ent + make_interval(mins => v_contr + v_alm);
      if k = 'atraso7' then v_ent := v_ent + interval '7 minutes';
      elsif k = 'atraso25' then v_ent := v_ent + interval '25 minutes';
      elsif k = 'saida_cedo' then v_sai := v_sai - interval '1 hour';
      elsif k = 'he90' then v_sai := v_sai + interval '90 minutes';
      elsif k = 'he120' then v_sai := v_sai + interval '2 hours';
      elsif k = 'he210' then v_sai := v_sai + interval '210 minutes';
      elsif k = 'noturno' then v_sai := time '23:00';
      end if;
      insert into cp_m values (t.id, t.emp, d, v_ent, 'entrada');
      if v_alm > 0 then
        insert into cp_m values (t.id, t.emp, d, time '12:00', 'saida_almoco'),
          (t.id, t.emp, d, time '12:00' + make_interval(mins => v_alm), 'volta_almoco');
      end if;
      if k is distinct from 'incompleta' then
        insert into cp_m values (t.id, t.emp, d, v_sai, 'saida');
      end if;
    end loop;
  end loop;

  -- grava como o fn_ponto_registrar: NSR + 1 e hash encadeado por empresa (continua a cadeia de cada empresa)
  execute 'alter table ponto_marcacoes disable trigger trg_ponto_marcacoes_porta_unica';
  for m in select * from cp_m order by (dia + hora), tec loop
    select ultimo + 1, ultimo_hash into v_nsr, v_ant from ponto_nsr where empresa_id = m.emp for update;
    v_m := row(gen_random_uuid(), m.emp, v_nsr, m.tec, (select cpf from tecnicos where id = m.tec),
               (m.dia + m.hora) at time zone 'America/Bahia', m.tipo, 'app',
               -13.004100, -38.523100, 12, v_loc, 15, true,
               null, jsonb_build_object('app_versao', 'carga-homologacao-jun-set'), v_ant, null)::ponto_marcacoes;
    v_m.hash := fn_ponto_hash(v_m);
    insert into ponto_marcacoes select v_m.*;
    update ponto_nsr set ultimo = v_nsr, ultimo_hash = v_m.hash where empresa_id = m.emp;
    n_marc := n_marc + 1;
  end loop;
  execute 'alter table ponto_marcacoes enable trigger trg_ponto_marcacoes_porta_unica';

  -- folgas compensatórias (decisão 84) e um abono do gestor, direto na tabela (sem aviso pelo WhatsApp)
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor, folga_de) values
    (v_inf, v_ana, '2026-07-15', 'Folga compensatória do trabalho em 12/07/2026 (Lei 605/1949, art. 9º)', v_aut, '2026-07-12'),
    (v_inf, v_bruno, '2026-07-21', 'Folga compensatória do trabalho em 19/07/2026 (Lei 605/1949, art. 9º)', v_aut, '2026-07-19');
  insert into ponto_abonos (empresa_id, tecnico_id, data, motivo, autor) values
    (v_inf, v_ana, '2026-08-11', 'Comparecimento como testemunha em processo judicial (CLT art. 473, VIII)', v_aut);

  -- o WhatsApp da Gabriela entra na lista de envio da homologação (para receber o espelho)
  update config set valor = valor || ',5571987279976'
   where chave = 'telefones_homologacao' and valor not like '%5571987279976%';

  raise notice 'Carga jun-set pronta: % marcações, 3 escalas atribuídas, 3 abonos.', n_marc;
end $carga$;
