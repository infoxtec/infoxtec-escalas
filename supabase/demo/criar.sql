-- Demonstração com dados fictícios (backlog 101, decisão 80). SÓ NA HOMOLOGAÇÃO.
-- Uso: ./scripts/demo-homologacao.sh criar   (apagar com: ./scripts/demo-homologacao.sh apagar)
--
-- Cria uma empresa fictícia (CNPJ de exemplo 99.999.999/0001-91) com 10 técnicos, 5 locais e uma semana
-- de escalas (3 dias atrás a 3 dias à frente, sem domingo), com respostas pelo WhatsApp e pela URA, uma
-- recusa e documentos com validades variadas — para mostrar Escalas, Indicadores e o Dossiê sem expor
-- ninguém real. Telefones com DDD 00 (não existe no Brasil): nenhuma mensagem chega a ninguém; e a
-- homologação não tem o motor no cron nem os segredos da Evolution e da Twilio. Sem CPF: os técnicos da
-- demonstração não entram no app do ponto (marcação de ponto é imutável e impediria apagar).
-- Tudo num bloco só: ou cria tudo, ou nada.

do $demo$
declare
  v_emp   uuid;
  v_hoje  date := (now() at time zone 'America/Bahia')::date;
  v_tecs  uuid[] := '{}';
  v_locs  uuid[] := '{}';
  v_alt   uuid; v_ele uuid; v_nr35 uuid; v_nr10 uuid; v_aso uuid;
  v_id    uuid; v_esc uuid; v_not uuid; v_tel text;
  v_dia   date; v_st escala_status; v_env timestamptz; i int := 0; d int; n int := 0; v_recusou boolean := false; v_ura boolean;
  v_nomes text[] := array['Ana Ribeiro', 'Bruno Carvalho', 'Carla Menezes', 'Diego Santana', 'Elaine Souza',
                          'Fábio Nascimento', 'Gabriela Lima', 'Henrique Dantas', 'Isabela Rocha', 'João Pedreira'];
  v_funcs text[] := array['Técnica de manutenção', 'Eletricista', 'Técnica de manutenção', 'Eletricista',
                          'Técnica de climatização', 'Técnico de manutenção', 'Eletricista', 'Técnico de climatização',
                          'Técnica de manutenção', 'Supervisor de campo'];
begin
  -- trava dupla: config ambiente = homologacao (migration 39) e nenhuma tarefa no pg_cron (só a produção tem)
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job' into i; end if;
  if i > 0 or coalesce(fn_config('ambiente'), 'producao') <> 'homologacao' then
    raise exception 'Este banco não é a homologação (config ambiente ou tarefas no pg_cron). A demonstração só roda na homologação.';
  end if;
  if exists (select 1 from empresas where cnpj = '99999999000191') then
    raise exception 'A demonstração já existe. Para recriar, rode antes: ./scripts/demo-homologacao.sh apagar';
  end if;

  insert into empresas (cnpj, razao_social, nome_fantasia, cidade, uf, empregadora, ativo)
  values ('99999999000191', 'Demonstração Serviços Técnicos Ltda (fictícia)', 'Demo Serviços Técnicos', 'Salvador', 'BA', true, true)
  returning id into v_emp;

  -- documentos e atividades da demonstração (sufixo "(demo)" para o apagar achar)
  insert into tipos_documento (nome, descricao, ordem) values ('NR-35 Trabalho em altura (demo)', 'Fictício', 91) returning id into v_nr35;
  insert into tipos_documento (nome, descricao, ordem) values ('NR-10 Eletricidade (demo)', 'Fictício', 92) returning id into v_nr10;
  insert into tipos_documento (nome, descricao, ordem) values ('ASO (demo)', 'Fictício', 93) returning id into v_aso;
  insert into tipos_atividade (nome, descricao) values ('Manutenção em altura (demo)', 'Fictício') returning id into v_alt;
  insert into tipos_atividade (nome, descricao) values ('Manutenção elétrica (demo)', 'Fictício') returning id into v_ele;
  insert into tipo_atividade_documentos (tipo_id, tipo_documento_id) values (v_alt, v_nr35), (v_alt, v_aso), (v_ele, v_nr10), (v_ele, v_aso);

  -- 5 locais de clientes fictícios em Salvador, com área do ponto
  for i in 1..5 loop
    insert into locais (nome, cliente, endereco, cidade, referencia, ativo, latitude, longitude, raio_m, cliente_empresa_id)
    values ((array['Edifício Maré Alta', 'Torre Comercial Vento Leste', 'Clínica Horizonte Azul',
                   'Condomínio Parque das Dunas', 'Galpão Logístico BR-324'])[i],
            (array['Maré Alta Condomínios (fictício)', 'Vento Leste Empreendimentos (fictício)', 'Horizonte Azul Saúde (fictícia)',
                   'Parque das Dunas (fictício)', 'Rota Logística (fictícia)'])[i],
            'Endereço fictício, ' || i * 100, 'Salvador', 'Demonstração', true,
            -12.97 - i * 0.01, -38.45 - i * 0.01, 200, v_emp)
    returning id into v_id;
    v_locs := v_locs || v_id;
  end loop;

  -- 10 técnicos; o 10º é o supervisor. DDD 00: número que não existe
  for i in 1..10 loop
    v_tel := '550090000' || lpad(i::text, 4, '0');
    insert into tecnicos (nome, telefone_e164, funcao, equipe, is_supervisor, opt_in, opt_in_em, ativo, empresa_id, admissao)
    values (v_nomes[i], v_tel, v_funcs[i], 'Demonstração', i = 10, true, now(), true, v_emp, v_hoje - 400)
    returning id into v_id;
    v_tecs := v_tecs || v_id;
    -- documentos: quase todos em dia; alguns casos para o dossiê mostrar
    insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, observacao) values
      (v_id, v_aso, case when i = 6 then v_hoje + 15 else v_hoje + 180 + i * 10 end, 'Demonstração');
    if i % 2 = 1 then   -- ímpares trabalham em altura
      insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, observacao)
      values (v_id, v_nr35, case when i = 3 then v_hoje - 5 else v_hoje + 300 end, 'Demonstração');
    elsif i <> 8 then   -- pares na elétrica; o 8 está sem a NR-10 cadastrada
      insert into tecnico_documentos (tecnico_id, tipo_documento_id, validade, observacao)
      values (v_id, v_nr10, v_hoje + 250, 'Demonstração');
    end if;
  end loop;

  -- uma semana de escalas para os 9 técnicos de campo, sem domingo
  for d in -3..3 loop
    v_dia := v_hoje + d;
    continue when extract(isodow from v_dia) = 7;
    for i in 1..9 loop
      n := n + 1;
      v_st := case when d < 0 and i = 4 and not v_recusou then 'recusada'
                   when d < 0 then 'concluida'
                   when d = 0 then 'confirmada'
                   when d = 1 and i <= 6 then 'confirmada'
                   when d = 1 then 'notificada'
                   else 'agendada' end;
      v_recusou := v_recusou or v_st = 'recusada';
      v_ura := v_st in ('concluida', 'confirmada') and (i + d) % 6 = 0;   -- sem resposta no WhatsApp; a URA resolve
      v_env := (v_dia - 1 + time '18:00') at time zone 'America/Bahia';
      insert into escalas (tecnico_id, local_id, data_servico, hora_inicio, descricao_tarefa, prioridade, status,
                           confirmada_em, criado_por, tipo_atividade_id)
      values (v_tecs[i], v_locs[1 + (i + d + 3) % 5], v_dia, case when i % 3 = 0 then time '08:00' else time '07:00' end,
              (array['Manutenção preventiva', 'Inspeção de quadro elétrico', 'Troca de luminárias',
                     'Manutenção do ar-condicionado', 'Atendimento de chamado'])[1 + (i + d + 3) % 5],
              case when i = 2 and d = 2 then 'urgente' else 'normal' end, v_st,
              case when v_ura then v_env + interval '2 hours 40 seconds'
                   when v_st in ('concluida', 'confirmada', 'recusada') then v_env + make_interval(mins => 4 + (i * 7 + d * 3 + 21) % 50) end,
              'demonstracao', case when i % 2 = 1 then v_alt else v_ele end)
      returning id into v_esc;

      continue when v_st = 'agendada';
      insert into notificacoes (escala_id, tipo, wa_message_id, status_envio, enviada_em, entregue_em, lida_em)
      values (v_esc, 'primeira', 'DEMO-N-' || n, (case when v_st = 'notificada' then 'entregue' else 'lida' end)::envio_status,
              v_env, v_env + interval '5 seconds', case when v_st <> 'notificada' then v_env + interval '2 minutes' end)
      returning id into v_not;
      continue when v_st = 'notificada';

      if v_st = 'recusada' then
        insert into respostas (notificacao_id, escala_id, wa_message_id, tipo, button_payload, recebida_em)
        values (v_not, v_esc, 'DEMO-R-' || n, 'problema', 'problema', v_env + interval '10 minutes');
        insert into respostas (escala_id, wa_message_id, tipo, texto_livre, recebida_em)
        values (v_esc, 'DEMO-M-' || n, 'motivo', 'Motivo pessoal', v_env + interval '12 minutes');
      elsif v_ura then
        -- não respondeu no WhatsApp; a URA ligou e a confirmação veio pelo dígito 1
        insert into ligacoes (escala_id, tecnico_id, telefone, tentativa, status, digito, duracao_seg, criada_em, atendida_em, encerrada_em)
        values (v_esc, v_tecs[i], '550090000' || lpad(i::text, 4, '0'), 1, 'encerrada', '1', 42,
                v_env + interval '2 hours', v_env + interval '2 hours 10 seconds', v_env + interval '2 hours 52 seconds');
        insert into respostas (escala_id, tipo, texto_livre, recebida_em)
        values (v_esc, 'confirmacao', 'Confirmado por telefone (digitou 1)', v_env + interval '2 hours 40 seconds');
      else
        insert into respostas (notificacao_id, escala_id, wa_message_id, tipo, button_payload, recebida_em)
        values (v_not, v_esc, 'DEMO-R-' || n, 'confirmacao', 'confirmar',
                v_env + make_interval(mins => 4 + (i * 7 + d * 3 + 21) % 50));
      end if;
    end loop;
  end loop;

  raise notice 'Demonstração criada: empresa "Demo Serviços Técnicos", 10 técnicos, 5 locais, % escalas.', n;
end $demo$;
