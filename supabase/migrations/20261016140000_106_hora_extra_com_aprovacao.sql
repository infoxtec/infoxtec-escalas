-- Migration 106 (16/10/2026): hora extra com aprovação do gestor — parte 2 da decisão 100.
-- Ao registrar o início de hora extra (app ou WhatsApp), a marcação vale sempre (Portaria MTP 671/2021: sem autorização
-- prévia para marcar). Depois dela:
--   - se a Programação do dia cobre o horário do início, a HE fica autorizada pela Programação e o funcionário é avisado;
--   - senão, vai na hora aos supervisores da empresa pelo WhatsApp, com os botões Aprovar e Reprovar (e no painel, aba
--     Ajustes e pedidos); decidida, o funcionário recebe "HE aprovada" ou "HE não autorizada".
-- A aprovação é da hora extra, nunca da marcação: reprovar não apaga marcação nem tempo trabalhado. No fechamento, HE
-- aguardando decisão bloqueia; HE não autorizada sai para confirmar (decisão do responsável em 16/10).
-- Base: fn_webhook_evolution da migration 103, fn_ponto_avisar e fn_ponto_folha_pendencias da 104 (iguais à homologação).

create table if not exists ponto_he_autorizacoes (
  id            uuid primary key default gen_random_uuid(),
  numero        bigint generated always as identity,
  empresa_id    uuid not null references empresas(id),
  tecnico_id    uuid not null references tecnicos(id),
  marcacao_id   uuid not null unique references ponto_marcacoes(id),
  data          date not null,
  inicio        timestamptz not null,
  origem        text not null check (origem in ('programada', 'pedido')),
  escala_id     uuid,   -- sem chave estrangeira: a Programação continua removível
  status        text not null default 'pendente' check (status in ('pendente', 'aprovada', 'reprovada')),
  decidido_por  text,
  decidido_em   timestamptz,
  canal_decisao text check (canal_decisao in ('programacao', 'whatsapp', 'painel')),
  created_at    timestamptz not null default now()
);
create index if not exists ponto_he_autorizacoes_tec_data on ponto_he_autorizacoes (tecnico_id, data);
alter table ponto_he_autorizacoes enable row level security;
comment on table ponto_he_autorizacoes is
  'Decisão 100, parte 2: autorização da hora extra iniciada pelo funcionário (Programação, ou aprovação do gestor). Uma decisão só; nada se apaga.';

-- uma decisão só, e nada se apaga
create or replace function fn_ponto_he_guarda()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if tg_op = 'DELETE' then raise exception 'Autorização de hora extra não se apaga.'; end if;
  if old.status <> 'pendente' or new.marcacao_id <> old.marcacao_id or new.tecnico_id <> old.tecnico_id
     or new.inicio <> old.inicio or new.data <> old.data or new.origem <> old.origem or new.empresa_id <> old.empresa_id
     or new.escala_id is distinct from old.escala_id then
    raise exception 'Autorização de hora extra já decidida não muda.';
  end if;
  return new;
end $$;
drop trigger if exists trg_ponto_he_guarda on ponto_he_autorizacoes;
create trigger trg_ponto_he_guarda before update or delete on ponto_he_autorizacoes
  for each row execute function fn_ponto_he_guarda();

-- Depois do registro do início de HE: autorização pela Programação, ou pedido aos supervisores. Devolve o texto ao
-- funcionário (vai no comprovante do app e do WhatsApp)
create or replace function fn_ponto_he_inicio(p_tecnico uuid)
returns text language plpgsql set search_path = public, extensions as $$
declare
  v_fuso text; v_emp uuid; v_nome text;
  v_data date;
  m      record;
  e      record;
  v_id   uuid;
  v_num  bigint;
  v_txt  text;
  s      record;
begin
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(x.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas x on x.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;
  select x.id, x.momento into m from ponto_marcacoes x
   where x.tecnico_id = p_tecnico and x.tipo = 'inicio_he' and x.momento >= v_data::timestamp at time zone v_fuso
   order by x.nsr desc limit 1;
  if m.id is null or exists (select 1 from ponto_he_autorizacoes h where h.marcacao_id = m.id) then return null; end if;

  -- a Programação do dia cobre o horário do início: autorizada pela Programação
  select s2.id, coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0))) as fim
    into e
    from escalas s2
   where s2.tecnico_id = p_tecnico and s2.data_servico = v_data and not coalesce(s2.teste, false)
     and s2.status not in ('cancelada', 'recusada', 'rascunho')
     and coalesce(s2.hora_fim_prevista, s2.hora_inicio + make_interval(mins => coalesce(s2.duracao_prevista_min, 0)))
         > (m.momento at time zone v_fuso)::time
   order by 2 desc limit 1;
  if e.id is not null then
    insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem, escala_id, status,
                                       decidido_por, decidido_em, canal_decisao)
    values (v_emp, p_tecnico, m.id, v_data, m.momento, 'programada', e.id, 'aprovada', 'Programação do dia', now(), 'programacao');
    return '✅ Hora extra autorizada pela Programação de hoje (até ' || to_char(e.fim, 'HH24:MI') || ').';
  end if;

  insert into ponto_he_autorizacoes (empresa_id, tecnico_id, marcacao_id, data, inicio, origem)
  values (v_emp, p_tecnico, m.id, v_data, m.momento, 'pedido') returning id, numero into v_id, v_num;
  v_txt := '⏱️ *Hora extra · ' || v_nome || '* (pedido nº ' || v_num || ')' || E'\n'
        || 'Início às ' || to_char(m.momento at time zone v_fuso, 'HH24:MI') || ' de ' || to_char(v_data, 'DD/MM')
        || ', fora da Programação. Aprova a hora extra?';
  -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora (como os avisos de jornada)
  for s in select telefone_e164 from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and (empresa_id = v_emp or empresa_id is null) loop
    begin
      if coalesce(fn_config('usar_botoes'), 'false')::boolean then
        perform fn_evo_post('/message/sendButtons/' || fn_config('evolution_instancia'),
          jsonb_build_object('number', s.telefone_e164, 'title', 'Hora extra', 'description', v_txt, 'footer', 'Trilha Ponto',
            'buttons', jsonb_build_array(
              jsonb_build_object('type', 'reply', 'displayText', 'Aprovar', 'id', 'he:ok:' || v_id),
              jsonb_build_object('type', 'reply', 'displayText', 'Reprovar', 'id', 'he:nao:' || v_id))));
      else
        perform fn_ponto_wa(s.telefone_e164, v_txt || E'\n' || 'Decida no painel: Ponto › Ajustes e pedidos.');
      end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
    end;
  end loop;
  return '⏳ Início de hora extra registrado e enviado ao gestor para aprovação; a resposta chega aqui. A marcação já vale.';
end $$;

-- Decisão do gestor (WhatsApp ou painel): uma vez só; avisa o funcionário. Mês com espelho assinado não muda
create or replace function fn_ponto_he_decidir(p_id uuid, p_aprovar boolean, p_por text, p_canal text)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare
  h      record;
  t      record;
  v_fuso text;
begin
  select * into h from ponto_he_autorizacoes where id = p_id for update;
  if not found then raise exception 'Pedido de hora extra não encontrado.'; end if;
  if h.status <> 'pendente' then
    return jsonb_build_object('situacao', 'ja_decidida', 'status', h.status, 'numero', h.numero);
  end if;
  if fn_ponto_mes_espelho(h.tecnico_id, h.data) = 'assinado' then
    raise exception 'O espelho deste mês já foi assinado pelo funcionário: o ponto do mês não muda mais.';
  end if;
  update ponto_he_autorizacoes
     set status = case when p_aprovar then 'aprovada' else 'reprovada' end,
         decidido_por = left(p_por, 200), decidido_em = now(), canal_decisao = p_canal
   where id = p_id;
  select tc.telefone_e164, tc.ativo, tc.opt_in, split_part(trim(tc.nome), ' ', 1) as nome, coalesce(e.fuso, 'America/Bahia') as fuso
    into t from tecnicos tc left join empresas e on e.id = tc.empresa_id where tc.id = h.tecnico_id;
  v_fuso := t.fuso;
  if t.ativo and t.opt_in and t.telefone_e164 is not null then
    perform fn_ponto_wa(t.telefone_e164, case when p_aprovar
      then '✅ *Hora extra aprovada*' || E'\n' || 'Seu início de hora extra de ' || to_char(h.data, 'DD/MM') || ' às '
           || to_char(h.inicio at time zone v_fuso, 'HH24:MI') || ' foi aprovado pelo gestor.'
      else '❌ *Hora extra não autorizada*' || E'\n' || 'O gestor não autorizou a hora extra iniciada em ' || to_char(h.data, 'DD/MM')
           || ' às ' || to_char(h.inicio at time zone v_fuso, 'HH24:MI') || '. Registre o fim da hora extra. '
           || 'O tempo já trabalhado continua registrado.' end);
  end if;
  return jsonb_build_object('situacao', case when p_aprovar then 'aprovada' else 'reprovada' end, 'numero', h.numero, 'nome', t.nome);
end $$;

-- Resposta do supervisor aos botões (he:ok:<id> / he:nao:<id>). Fora disso devolve null e a mensagem segue o fluxo normal
create or replace function fn_ponto_he_resposta(p_data jsonb)
returns jsonb language plpgsql set search_path = public, extensions as $$
declare
  v_key jsonb := p_data->'key';
  v_msg jsonb := p_data->'message';
  v_btn text;
  v_jid text;
  v_sup record;
  v_id  uuid;
  h     record;
  r     jsonb;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) then return null; end if;
  v_btn := coalesce(v_msg->'buttonsResponseMessage'->>'selectedButtonId', v_msg->'templateButtonReplyMessage'->>'selectedId');
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then v_btn := null;
    end;
  end if;
  if v_btn is null or v_btn !~ '^he:(ok|nao):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return null; end if;
  v_id := split_part(v_btn, ':', 3)::uuid;

  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt', v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  select t.id, t.nome, t.telefone_e164, t.empresa_id into v_sup from tecnicos t
   where t.is_supervisor and t.ativo and t.opt_in and not t.perfil_teste and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(coalesce(v_jid, ''), '@', 1));
  if v_sup.id is null then return jsonb_build_object('ignorado', 'hora extra: resposta de quem não é supervisor'); end if;
  select * into h from ponto_he_autorizacoes where id = v_id;
  if h.id is null or h.tecnico_id = v_sup.id or (v_sup.empresa_id is not null and v_sup.empresa_id <> h.empresa_id) then
    return jsonb_build_object('ignorado', 'hora extra: pedido de outra empresa ou inexistente');
  end if;
  begin
    r := fn_ponto_he_decidir(v_id, split_part(v_btn, ':', 2) = 'ok', 'WhatsApp · ' || v_sup.nome, 'whatsapp');
  exception when others then
    perform fn_ponto_wa(v_sup.telefone_e164, 'Não foi possível registrar a decisão da hora extra: ' || sqlerrm);
    return jsonb_build_object('acao', 'he_erro');
  end;
  perform fn_ponto_wa(v_sup.telefone_e164, case r->>'situacao'
    when 'ja_decidida' then 'O pedido de hora extra nº ' || (r->>'numero') || ' já tinha sido decidido.'
    when 'aprovada' then '✅ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' aprovada. O funcionário foi avisado.'
    else '❌ Hora extra nº ' || (r->>'numero') || ' de ' || (r->>'nome') || ' não autorizada. O funcionário foi avisado.' end);
  return jsonb_build_object('acao', 'he_' || (r->>'situacao'), 'numero', r->'numero');
end $$;

-- Painel: lista e decisão (aba Ajustes e pedidos)
create or replace function app_ponto_he_autorizacoes(p_de date, p_ate date)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
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
   where h.data between p_de and p_ate), '[]'::jsonb);
end $$;

create or replace function app_ponto_he_decidir(p_id uuid, p_aprovar boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
begin
  return fn_ponto_he_decidir(p_id, p_aprovar, v_email, 'painel');
end $$;

create or replace function fn_ponto_avisar(p_tecnico uuid, p_tipo text)
returns text[] language plpgsql set search_path = public, extensions as $$
declare
  v_fuso  text;
  v_emp   uuid;
  v_data  date;
  v_nome  text;
  j       jsonb;
  a       text;
  s       record;
  v_func  text;
  v_gest  text;
  v_saida text[] := '{}';
  v_rel   text[];
  v_lim   int;
  v_contr int;
  v_minimo int;
  v_sa    timestamptz;
  v_he    text;
begin
  v_lim := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  select split_part(trim(t.nome), ' ', 1), t.empresa_id, coalesce(e.fuso, 'America/Bahia') into v_nome, v_emp, v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_data := (now() at time zone v_fuso)::date;

  -- saída para o intervalo: quando pode voltar (15 min de 4 a 6 h, 1 h acima de 6 h na jornada do dia)
  if p_tipo = 'saida_almoco' then
    v_contr := fn_carga_minutos_dia(p_tecnico, v_data);
    v_minimo := case when v_contr > 360 then v_lim
                     when v_contr > 240 then coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15) end;
    if v_minimo is not null then
      select max(momento) into v_sa from ponto_marcacoes
       where tecnico_id = p_tecnico and tipo = 'saida_almoco' and momento >= v_data::timestamp at time zone v_fuso;
      if v_sa is not null then
        v_saida := v_saida || ('🍽️ Bom intervalo! Retorno a partir de '
          || to_char((v_sa + make_interval(mins => v_minimo)) at time zone v_fuso, 'HH24:MI')
          || ' (intervalo mínimo de ' || fn_ponto_hm(v_minimo) || ', CLT art. 71).');
      end if;
    end if;
    return v_saida;
  end if;

  -- início de hora extra: autorizada pela Programação ou enviada ao gestor para aprovar (decisão 100, parte 2)
  -- bloco próprio: uma falha aqui não desfaz os avisos, e uma falha nos avisos não desfaz o pedido (seguranca)
  if p_tipo = 'inicio_he' then
    begin
      v_he := fn_ponto_he_inicio(p_tecnico);
      if v_he is not null then v_saida := v_saida || v_he; end if;
    exception when others then
      raise warning 'ponto: pedido de aprovação de hora extra falhou: %', sqlerrm;
      begin
        perform fn_avisar_tecnico('⚠️ *HORA EXTRA*' || E'\n\n' || 'O pedido de aprovação de uma hora extra iniciada agora '
          || 'falhou e não foi enviado ao gestor. Confira em Ponto › Marcações e decida no painel.');
      exception when others then null;
      end;
      v_saida := v_saida || 'Início de hora extra registrado. Avise o seu gestor para aprovar.'::text;
    end;
    return v_saida;
  end if;

  j := fn_ponto_jornada_dia(p_tecnico, v_data);
  if j is null then return v_saida; end if;
  v_rel := case p_tipo
    when 'volta_almoco' then array['intervalo_curto', 'intervalo_longo']
    when 'entrada'      then array['interjornada_curta']
    when 'saida'        then array['he_acima_limite', 'sem_intervalo']
    when 'fim_he'       then array['he_acima_limite']
    else array[]::text[] end;
  for a in select x from jsonb_array_elements_text(j->'alertas') x where x = any(v_rel) loop
    v_func := case a
      when 'intervalo_curto'    then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de ' || fn_ponto_hm(v_lim)
                                            || ' — mínimo da CLT para jornada acima de 6 horas (art. 71).'
                                       else 'Intervalo de ' || (j->>'intervalo_min') || ' min, abaixo de '
                                            || coalesce(nullif(fn_config('ponto_intervalo_curto_min'), ''), '15')
                                            || ' min — mínimo da CLT para jornada acima de 4 horas (art. 71, §1º).' end
      when 'intervalo_longo'    then 'Intervalo de ' || fn_ponto_hm((j->>'intervalo_min')::int)
                                     || ', acima de 2 horas — permitido só com acordo escrito ou convenção coletiva (CLT art. 71).'
      when 'he_acima_limite'    then 'Hora extra de ' || fn_ponto_hm((j->>'he_escala_min')::int) || ' hoje sobre a jornada de '
                                     || fn_ponto_hm((j->>'contratual_min')::int) || ' do dia, acima do limite de 2 horas por dia (CLT art. 59).'
      when 'sem_intervalo'      then case when coalesce((j->>'trabalhado_min')::int, 0) > 360
                                       then 'Jornada de mais de 6 horas sem intervalo registrado — mínimo de 1 hora (CLT art. 71).'
                                       else 'Jornada de mais de 4 horas sem o intervalo mínimo de 15 minutos (CLT art. 71, §1º).' end
      when 'interjornada_curta' then 'Descanso de ' || fn_ponto_hm((j->>'interjornada_min')::int) || ' desde a última saída, abaixo das 11 horas entre jornadas (CLT art. 66).'
    end;
    v_saida := v_saida || ('⚠️ ' || v_func || ' A marcação vale; o gestor será avisado.');
    insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
    values ('ponto_' || a || '_' || p_tecnico, v_data, now(), true, jsonb_build_object('tecnico', p_tecnico))
    on conflict do nothing;
    if found then
      v_gest := case when a = 'he_acima_limite'
                  -- Alerta Crítico (decisão 90; texto do juridico): sem motivo, sem saúde, só o primeiro nome
                  then '🚨 *Alerta crítico · carga horária excedida*' || E'\n' || 'O ponto de ' || v_nome || ' hoje ('
                       || to_char(v_data, 'DD/MM') || ') passou de ' || fn_ponto_hm((j->>'limite_min')::int)
                       || ' (jornada do dia + 2h extras). Confira no painel.'
                  else '⚠️ *Ponto · ' || v_nome || '* (' || to_char(v_data, 'DD/MM') || '): ' || v_func end;
      -- supervisor sem empresa cadastrada recebe enquanto houver uma só empregadora; cadastrar a
      -- empresa do supervisor antes do segundo cliente (separação por cliente, backlog 074)
      for s in select telefone_e164 from tecnicos
                where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
                  and (empresa_id = v_emp or empresa_id is null) loop
        perform fn_ponto_wa(s.telefone_e164, v_gest);
      end loop;
    end if;
  end loop;
  return v_saida;
exception when others then
  raise warning 'ponto: avisos de jornada falharam: %', sqlerrm;
  return '{}';
end $$;

create or replace function fn_ponto_folha_pendencias(p_tecnico uuid, p_mes date)
returns jsonb language plpgsql stable set search_path = public, extensions as $$
declare
  v_mes   date := date_trunc('month', p_mes)::date;
  v_fim   date := (date_trunc('month', p_mes) + interval '1 month')::date - 1;
  v_fuso  text := coalesce(fn_config('fuso'), 'America/Bahia');
  v_ontem date := (now() at time zone coalesce(fn_config('fuso'), 'America/Bahia'))::date - 1;
  v_abona boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_res   jsonb := '[]'::jsonb;
  v_dias  int := 0;
  v_dup   date[];
  v_ped   date[];
  v_exige boolean;
  a       text;
  t record; r record;
begin
  select coalesce(tc.admissao, tc.created_at::date) as adm, tc.desligado_em, coalesce(e.exige_registro_intervalo, false) as exige
    into t from tecnicos tc left join empresas e on e.id = tc.empresa_id where tc.id = p_tecnico;
  if not found then return v_res; end if;
  v_exige := t.exige;

  -- pedidos aguardando decisão (e os dias que eles cobrem: lá não é falta injustificada, é pendência). Sem o motivo:
  -- o código de saúde (pré-natal, preventivo...) é dado sensível e a validação é aberta ao papel leitura (decisão 56)
  select coalesce(jsonb_agg(jsonb_build_object('tipo', 'pedido_pendente', 'nivel', 'bloqueia', 'bloqueia', true,
           'data', j.data, 'numero', j.numero) order by j.data, j.numero), '[]'::jsonb),
         coalesce(array_agg(distinct g::date), '{}')
    into v_res, v_ped
    from ponto_justificativas j
    cross join lateral generate_series(j.data, coalesce(j.data_fim, j.data), interval '1 day') g
   where j.tecnico_id = p_tecnico and j.status = 'pendente'
     and j.data <= v_fim and coalesce(j.data_fim, j.data) >= v_mes;
  -- o agregado acima repete o pedido por dia coberto: um item por pedido
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;

  -- hora extra (decisão 100, parte 2): aguardando o gestor bloqueia; não autorizada sai para confirmar (o tempo
  -- trabalhado continua no espelho: a reprovação não apaga a hora)
  v_res := v_res || coalesce((select jsonb_agg(jsonb_build_object(
             'tipo', case when h.status = 'pendente' then 'he_pendente' else 'he_reprovada' end,
             'nivel', case when h.status = 'pendente' then 'bloqueia' else 'confirmar' end,
             'bloqueia', h.status = 'pendente', 'data', h.data, 'numero', h.numero,
             'hora', to_char(h.inicio at time zone v_fuso, 'HH24:MI')) order by h.data, h.numero)
           from ponto_he_autorizacoes h
          where h.tecnico_id = p_tecnico and h.status in ('pendente', 'reprovada') and h.data between v_mes and v_fim), '[]'::jsonb);

  -- marcações duplicadas: o mesmo tipo em seguida no dia, ou duas a menos de 3 min (as desconsideradas não contam).
  -- As inclusões vêm só de pedido do funcionário aprovado (o gestor não cria marcação, decisões 89 e 100)
  with m as (
    select (x.momento at time zone v_fuso) as h, x.tipo from ponto_marcacoes x
     where x.tecnico_id = p_tecnico
       and x.momento >= v_mes::timestamp at time zone v_fuso and x.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.marcacao_id = x.id)
    union all
    select (a.momento at time zone v_fuso), a.tipo from ponto_ajustes a
     where a.tecnico_id = p_tecnico and a.acao = 'incluir'
       and a.momento >= v_mes::timestamp at time zone v_fuso and a.momento < (v_fim + 1)::timestamp at time zone v_fuso
       and not exists (select 1 from ponto_ajustes d where d.acao = 'desconsiderar' and d.ajuste_id = a.id)
  ), o as (
    select h, tipo, lag(h) over (partition by h::date order by h) as h_ant, lag(tipo) over (partition by h::date order by h) as tipo_ant
      from m
  )
  select coalesce(array_agg(distinct h::date), '{}') into v_dup
    from o where h_ant is not null and (tipo = tipo_ant or h - h_ant < interval '3 minutes');

  for r in select g::date as dia, fn_ponto_jornada_dia(p_tecnico, g::date) as j, fn_carga_dia(p_tecnico, g::date) as c
             from generate_series(greatest(v_mes, t.adm), least(v_fim, v_ontem, coalesce(t.desligado_em, v_fim)),
                                  interval '1 day') g loop
    if r.j is not null then
      v_dias := v_dias + 1;
      if r.dia = any(v_dup) then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_duplicada', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      elsif r.j->'alertas' ? 'incompleta' then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'marcacao_incompleta', 'nivel', 'bloqueia', 'bloqueia', true,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
      foreach a in array array['intervalo_curto', 'sem_intervalo', 'he_acima_limite', 'interjornada_curta'] loop
        if r.j->'alertas' ? a then
          if a = 'sem_intervalo' and v_exige and r.j->>'abono' is null then
            -- decisão 100: sem o par de intervalo, não fecha até o pedido do funcionário ou o abono do gestor
            v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'intervalo_nao_registrado', 'nivel', 'bloqueia',
                       'bloqueia', true, 'data', r.dia, 'trabalhado_min', (r.j->>'trabalhado_min')::int));
          else
            v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', a, 'nivel', 'confirmar', 'bloqueia', false, 'data', r.dia,
                       'intervalo_min', (r.j->>'intervalo_min')::int, 'he_min', (r.j->>'he_min')::int,
                       'interjornada_min', (r.j->>'interjornada_min')::int));
          end if;
        end if;
      end loop;
      if r.j->>'abono' = 'dia inteiro' and coalesce((r.j->>'marcacoes')::int, 0) > 0 then
        v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'abono_em_dia_trabalhado', 'nivel', 'confirmar', 'bloqueia', false,
                   'data', r.dia, 'marcacoes', (r.j->>'marcacoes')::int));
      end if;
    elsif coalesce((r.c->>'minutos')::int, 0) > 0
      and not (r.dia = any(v_ped))
      and not (r.c->>'tipo' is distinct from '12x36'
               and exists (select 1 from feriados f where f.data = r.dia and f.abrangencia <> 'facultativo'))
      and not (extract(isodow from r.dia) = 6 and r.c->>'escala' is null and v_abona) then
      v_res := v_res || jsonb_build_array(jsonb_build_object('tipo', 'sem_registro', 'nivel', 'confirmar', 'bloqueia', false,
                 'data', r.dia, 'minutos', (r.c->>'minutos')::int));
    end if;
  end loop;

  -- funcionário sem nenhum registro no mês não entra no fechamento (o espelho não é emitido): não há o que apontar
  if v_dias = 0 and not exists (select 1 from jsonb_array_elements(v_res) x where x->>'tipo' in ('pedido_pendente', 'he_pendente', 'he_reprovada')) then
    return '[]'::jsonb;
  end if;
  select coalesce(jsonb_agg(x order by x->>'data', x->>'tipo'), '[]'::jsonb) into v_res from jsonb_array_elements(v_res) x;
  return v_res;
end $$;

-- Resposta aos botões de hora extra antes do fluxo do ponto e das escalas
create or replace function fn_webhook_evolution(p_token text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_log    bigint;
  v_evento text := lower(replace(coalesce(p_payload->>'event', ''), '_', '.'));
  v_res    jsonb;
  v_pl     jsonb := p_payload - 'apikey';
  v_msg    jsonb;
  v_permitidas text[] := array['conversation', 'extendedTextMessage', 'buttonsResponseMessage', 'templateButtonReplyMessage',
                               'interactiveResponseMessage', 'listResponseMessage', 'messageContextInfo', 'localizacao',
                               'reactionMessage', 'protocolMessage'];
begin
  if not fn_webhook_token_ok(p_token) then
    raise exception 'token invalido';
  end if;

  -- LGPD: a localização do ponto já fica na marcação; o log do webhook não guarda outra cópia
  if v_pl->'data'->'message' ?| array['locationMessage', 'liveLocationMessage'] then
    v_pl := jsonb_set(v_pl, '{data,message}',
      ((v_pl->'data'->'message') - 'locationMessage' - 'liveLocationMessage') || '{"localizacao": true}');
  end if;
  -- LGPD (decisão 56): o log guarda só texto, botão e a marca da localização (tirada acima). Foto, vídeo,
  -- áudio, arquivo, mensagem temporária ou de visualização única e a mensagem citada saem (miniatura,
  -- legenda, URL e chave da mídia); fica só a marca "midia"
  if jsonb_typeof(v_pl->'data'->'message') = 'object' then
    select coalesce(jsonb_object_agg(e.k, case when e.k = 'extendedTextMessage' then e.v #- '{contextInfo,quotedMessage}' else e.v end), '{}')
      into v_msg
      from jsonb_each(v_pl->'data'->'message') e(k, v)
     where e.k = any(v_permitidas);
    if exists (select 1 from jsonb_object_keys(v_pl->'data'->'message') k where k <> all(v_permitidas)) then
      v_msg := v_msg || '{"midia": true}';
    end if;
    v_pl := jsonb_set(v_pl, '{data,message}', v_msg);
  end if;
  v_pl := v_pl #- '{data,contextInfo,quotedMessage}';
  insert into webhook_eventos (evento, payload)
  values (v_evento, v_pl)
  returning id into v_log;

  begin
    if v_evento = 'messages.update' then
      v_res := fn_wh_status(p_payload->'data');
    elsif v_evento = 'messages.upsert' then
      -- resposta do gestor aos botões de aprovação de hora extra (decisão 100, parte 2)
      v_res := fn_ponto_he_resposta(p_payload->'data');
      if v_res is null then
      begin
        v_res := fn_ponto_wh(p_payload->'data');
      exception when others then
        -- falha no ponto não pode derrubar a resposta das escalas
        v_res := null;
        raise warning 'ponto: %', sqlerrm;
      end;
      if v_res is null then
        v_res := fn_wh_mensagem(p_payload->'data');
      end if;
      end if;
    else
      v_res := jsonb_build_object('ignorado', v_evento);
    end if;
    update webhook_eventos set resultado = v_res::text where id = v_log;
  exception when others then
    update webhook_eventos set resultado = 'ERRO: ' || sqlerrm where id = v_log;
    v_res := jsonb_build_object('erro', sqlerrm);
  end;

  return v_res;
end $function$;

do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated, service_role';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
