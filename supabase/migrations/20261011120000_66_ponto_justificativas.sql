-- Migration 66 (11/10/2026): justificativa de ponto pelo funcionário — 084 entrega 3, E1 (decisões 55 a 58).
--
-- O funcionário pede o ajuste pelo app (aba Ajuste) ou pelo WhatsApp (palavra "ajuste"); o gestor aprova
-- ou nega no painel. Nesta entrega, só a categoria Ponto (esqueci de marcar, o app falhou, atraso ou
-- saída antecipada): nenhum dado de saúde. Saúde, Família e Convocação (com anexo no cofre criptografado,
-- decisão 56) vêm na E2; os motivos já ficam cadastrados, inativos.
--
-- Aprovado:
--   esqueci de marcar / app falhou -> ponto_ajustes "incluir" ligado ao pedido (gestor como autor);
--   atraso ou saída antecipada     -> ABONO do período (ponto_abonos), nunca marcação inventada.
-- O espelho passa a mostrar falta (dia com escala, já passado, sem marcação) e o que foi abonado.
-- O gestor também abona direto, sem pedido (falta justificada fora do sistema), e pode estornar um abono.
-- Limite legal: alerta, nunca bloqueia (decisão 55). Texto sem ameaça de punição (decisão 57).

-- Motivos (limites em dado, não em código; conferência jurídica pela persona juridico, decisão 58) ------
create table if not exists ponto_motivos (
  codigo        text primary key,
  grupo         text not null check (grupo in ('saude', 'familia', 'convocacao', 'ponto')),
  nome          text not null,
  base_legal    text,
  abrange       text not null check (abrange in ('periodo', 'horario', 'gestor')),
  quantidade    numeric,
  unidade       text check (unidade in ('dias', 'consultas', 'tempo_necessario')),
  janela        text check (janela in ('evento', '12_meses', 'ano', 'gestacao')),
  exige_anexo   boolean not null default false,
  saude         boolean not null default false,
  ativo         boolean not null default false,
  ordem         int not null default 100
);
comment on table ponto_motivos is 'Motivos de justificativa de ponto e limites legais (alertam, nunca bloqueiam). Editável: valor legal corrigido é dado.';
alter table ponto_motivos enable row level security;

insert into ponto_motivos (codigo, grupo, nome, base_legal, abrange, quantidade, unidade, janela, exige_anexo, saude, ativo, ordem) values
  ('esqueci_marcar',  'ponto', 'Esqueci de marcar', 'Poder diretivo do empregador (CLT art. 2º)', 'gestor', null, null, null, false, false, true, 1),
  ('falha_registro',  'ponto', 'O app ou o WhatsApp não funcionou', 'Poder diretivo do empregador (CLT art. 2º)', 'gestor', null, null, null, false, false, true, 2),
  ('atraso_saida',    'ponto', 'Cheguei atrasado ou saí mais cedo', 'Poder diretivo do empregador (CLT art. 2º)', 'gestor', null, null, null, false, false, true, 3),
  ('atestado',        'saude', 'Atestado médico', 'CLT art. 473; Lei 605/1949, art. 6º, §1º', 'periodo', null, null, null, true, true, false, 10),
  ('comparecimento',  'saude', 'Declaração de comparecimento', 'CLT art. 473; Lei 605/1949, art. 6º, §1º', 'horario', null, null, null, true, true, false, 11),
  ('prenatal',        'saude', 'Acompanhei consulta ou exame do pré-natal', 'CLT art. 473, X', 'horario', 6, 'consultas', 'gestacao', true, true, false, 12),
  ('filho_6_anos',    'saude', 'Levei filho de até 6 anos ao médico', 'CLT art. 473, XI', 'periodo', 1, 'dias', 'ano', true, true, false, 13),
  ('preventivo',      'saude', 'Fiz exame preventivo de câncer', 'CLT art. 473, XII', 'periodo', 3, 'dias', '12_meses', true, true, false, 14),
  ('doacao_sangue',   'saude', 'Doei sangue', 'CLT art. 473, IV', 'periodo', 1, 'dias', '12_meses', true, true, false, 15),
  ('falecimento',     'familia', 'Falecimento de familiar próximo', 'CLT art. 473, I', 'periodo', 2, 'dias', 'evento', true, false, false, 20),
  ('casamento',       'familia', 'Casamento', 'CLT art. 473, II', 'periodo', 3, 'dias', 'evento', true, false, false, 21),
  ('nascimento',      'familia', 'Nascimento ou adoção de filho', 'CF art. 7º, XIX; CLT art. 473, III; Lei 15.371/2026 (ampliação gradual)', 'periodo', 5, 'dias', 'evento', true, false, false, 22),
  ('justica',         'convocacao', 'Justiça: audiência, testemunha ou júri', 'CLT art. 473, VIII', 'periodo', null, 'tempo_necessario', 'evento', true, false, false, 30),
  ('eleitoral',       'convocacao', 'Justiça Eleitoral: título ou mesário', 'CLT art. 473, V; Lei 9.504/1997, art. 98', 'periodo', 2, 'dias', 'evento', true, false, false, 31),
  ('outra_convocacao','convocacao', 'Outra: serviço militar, sindicato ou vestibular', 'CLT art. 473, VI, VII e IX', 'periodo', null, 'tempo_necessario', 'evento', true, false, false, 32)
on conflict (codigo) do nothing;

-- Pedido do funcionário --------------------------------------------------------------------------------
create table if not exists ponto_justificativas (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity unique,
  empresa_id     uuid not null references empresas(id),
  tecnico_id     uuid not null references tecnicos(id),
  motivo         text not null references ponto_motivos(codigo),
  data           date not null,
  tipo_marcacao  text check (tipo_marcacao in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he')),
  hora           time,
  hora_ini       time,
  hora_fim       time,
  observacao     text check (length(observacao) <= 500),
  canal          text not null check (canal in ('app', 'whatsapp')),
  status         text not null default 'pendente' check (status in ('pendente', 'aprovada', 'negada', 'cancelada')),
  decidido_por   text,
  decidido_em    timestamptz,
  resposta       text check (length(resposta) <= 500),
  ajuste_id      uuid references ponto_ajustes(id),
  abono_id       uuid,
  created_at     timestamptz not null default now()
);
comment on table ponto_justificativas is 'Pedido de ajuste do funcionário (app ou WhatsApp). Só muda de situação pela decisão do gestor; nunca é apagado.';
alter table ponto_justificativas enable row level security;
create index if not exists ponto_justificativas_tecnico_idx on ponto_justificativas (tecnico_id, data);
create index if not exists ponto_justificativas_pendentes_idx on ponto_justificativas (status) where status = 'pendente';
create index if not exists ponto_justificativas_empresa_idx on ponto_justificativas (empresa_id);
create index if not exists ponto_justificativas_motivo_idx on ponto_justificativas (motivo);
create index if not exists ponto_justificativas_ajuste_idx on ponto_justificativas (ajuste_id);
create or replace function fn_ponto_justificativa_guarda()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if (new.empresa_id, new.tecnico_id, new.motivo, new.data, new.tipo_marcacao, new.hora, new.hora_ini, new.hora_fim, new.canal, new.created_at, new.numero)
     is distinct from (old.empresa_id, old.tecnico_id, old.motivo, old.data, old.tipo_marcacao, old.hora, old.hora_ini, old.hora_fim, old.canal, old.created_at, old.numero)
     or (old.status <> 'pendente' and (new.status, new.decidido_por, new.decidido_em, new.ajuste_id, new.abono_id)
          is distinct from (old.status, old.decidido_por, old.decidido_em, old.ajuste_id, old.abono_id)) then
    raise exception 'Pedido de ajuste decidido não muda (só a anonimização do texto livre ao fim da guarda).';
  end if;
  return new;
end $$;
create or replace trigger trg_ponto_justificativas_guarda before update on ponto_justificativas
  for each row execute function fn_ponto_justificativa_guarda();
create or replace trigger trg_ponto_justificativas_sem_exclusao before delete on ponto_justificativas
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_justificativas_sem_truncate before truncate on ponto_justificativas
  for each statement execute function fn_ponto_imutavel();

-- Abono: período justificado, sem marcação. Só inclusão; o estorno é outra linha (como o desconsiderar) --
create table if not exists ponto_abonos (
  id               uuid primary key default gen_random_uuid(),
  empresa_id       uuid not null references empresas(id),
  tecnico_id       uuid not null references tecnicos(id),
  data             date not null,
  inicio           time,
  fim              time,
  justificativa_id uuid references ponto_justificativas(id),
  estorno_de       uuid references ponto_abonos(id),
  motivo           text not null check (length(trim(motivo)) between 10 and 500),
  autor            text not null,
  created_at       timestamptz not null default now(),
  check ((inicio is null and fim is null) or (inicio is not null and fim is not null and inicio < fim))
);
comment on table ponto_abonos is 'Abono de falta ou atraso (dia inteiro quando inicio e fim são nulos). Imutável; estorno é uma linha nova com estorno_de.';
alter table ponto_abonos enable row level security;
create index if not exists ponto_abonos_tecnico_idx on ponto_abonos (tecnico_id, data);
create index if not exists ponto_abonos_empresa_idx on ponto_abonos (empresa_id);
create index if not exists ponto_abonos_justificativa_idx on ponto_abonos (justificativa_id);
create unique index if not exists ponto_abonos_estorno_uq on ponto_abonos (estorno_de) where estorno_de is not null;
create or replace trigger trg_ponto_abonos_imutavel before update or delete on ponto_abonos
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_abonos_sem_truncate before truncate on ponto_abonos
  for each statement execute function fn_ponto_imutavel();

alter table ponto_justificativas drop constraint if exists ponto_justificativas_abono_fk;
alter table ponto_justificativas add constraint ponto_justificativas_abono_fk foreign key (abono_id) references ponto_abonos(id);
create index if not exists ponto_justificativas_abono_idx on ponto_justificativas (abono_id);

alter table ponto_ajustes add column if not exists justificativa_id uuid references ponto_justificativas(id);
create index if not exists ponto_ajustes_justificativa_idx on ponto_ajustes (justificativa_id);

-- Conversa do WhatsApp guarda as respostas do pedido em andamento (nunca texto livre) --------------------
alter table ponto_conversas add column if not exists dados jsonb;
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'ponto_conversas'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%escolher_tipo%' loop
    execute format('alter table ponto_conversas drop constraint %I', c.conname);
  end loop;
end $$;
alter table ponto_conversas add constraint ponto_conversas_etapa_ck
  check (etapa in ('escolher_tipo', 'aguardando_local', 'aj_menu', 'aj_motivo', 'aj_dia', 'aj_marcacao', 'aj_hora', 'aj_periodo'));

-- Aviso aos supervisores da empresa: só o primeiro nome e o número do pedido (decisão 52 B) ----------
create or replace function fn_ponto_avisar_supervisores(p_tecnico uuid, p_texto text)
returns void language plpgsql volatile set search_path = public, extensions as $$
declare s record; v_emp uuid;
begin
  select empresa_id into v_emp from tecnicos where id = p_tecnico;
  for s in select telefone_e164 from tecnicos
            where is_supervisor and ativo and opt_in and not perfil_teste and id <> p_tecnico
              and (empresa_id = v_emp or empresa_id is null) loop
    perform fn_ponto_wa(s.telefone_e164, p_texto);
  end loop;
end $$;

-- Hora digitada no WhatsApp: "7h30", "07:30", "7h", "7" -> time (null se não entender)
create or replace function fn_ponto_ler_hora(p text)
returns time language plpgsql immutable set search_path = public, extensions as $$
declare m text[];
begin
  m := regexp_match(trim(coalesce(p, '')), '^(\d{1,2})(?:\s*[h:]\s*(\d{2})?)?\s*h?$');
  if m is null or m[1]::int > 23 or coalesce(m[2], '0')::int > 59 then return null; end if;
  return make_time(m[1]::int, coalesce(m[2], '0')::int, 0);
end $$;

-- Data digitada: "hoje", "ontem", "15/10", "15/10/2026" -> date (null se não entender)
create or replace function fn_ponto_ler_data(p text, p_hoje date)
returns date language plpgsql immutable set search_path = public, extensions as $$
declare m text[]; v date;
begin
  if p in ('hoje') then return p_hoje; end if;
  if p in ('ontem') then return p_hoje - 1; end if;
  m := regexp_match(trim(coalesce(p, '')), '^(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?$');
  if m is null then return null; end if;
  begin
    v := make_date(case when m[3] is null then extract(year from p_hoje)::int
                        when length(m[3]) = 2 then 2000 + m[3]::int else m[3]::int end, m[2]::int, m[1]::int);
  exception when others then return null; end;
  -- "15/12" digitado em janeiro é do ano anterior
  if m[3] is null and v > p_hoje then v := (v - interval '1 year')::date; end if;
  return v;
end $$;

-- Cria o pedido (app e WhatsApp passam por aqui) -----------------------------------------------------
create or replace function fn_ponto_justificativa_criar(p_tecnico uuid, p_motivo text, p_data date,
  p_tipo_marcacao text, p_hora time, p_hora_ini time, p_hora_fim time, p_observacao text, p_canal text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_tec  record;
  v_mot  record;
  v_hoje date;
  v_id   uuid;
  v_num  bigint;
  v_obs  text := nullif(trim(coalesce(p_observacao, '')), '');
begin
  select t.id, t.nome, t.empresa_id, t.ativo, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found or not v_tec.ativo or v_tec.empresa_id is null then raise exception 'Funcionário sem ponto cadastrado.'; end if;
  select * into v_mot from ponto_motivos where codigo = p_motivo and ativo;
  if not found then raise exception 'Escolha um motivo válido.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Informe um dia até hoje.'; end if;
  if p_data < v_hoje - 62 then raise exception 'Pedido só para os últimos 62 dias.'; end if;
  if length(coalesce(v_obs, '')) > 500 then raise exception 'Observação com no máximo 500 letras.'; end if;

  if p_motivo in ('esqueci_marcar', 'falha_registro') then
    if p_tipo_marcacao is null or p_tipo_marcacao not in ('entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he') then
      raise exception 'Escolha a marcação que ficou faltando.';
    end if;
    if p_hora is null then raise exception 'Informe o horário da marcação.'; end if;
    if (p_data + p_hora) at time zone v_tec.fuso > now() then raise exception 'O horário ainda não chegou.'; end if;
  elsif p_motivo = 'atraso_saida' then
    if p_hora_ini is null or p_hora_fim is null or p_hora_ini >= p_hora_fim then
      raise exception 'Informe o período: das ... às ... (o início antes do fim).';
    end if;
    if (p_data + p_hora_fim) at time zone v_tec.fuso > now() then raise exception 'O horário ainda não chegou.'; end if;
  end if;

  if exists (select 1 from ponto_justificativas j where j.tecnico_id = p_tecnico and j.status = 'pendente'
              and j.motivo = p_motivo and j.data = p_data
              and j.tipo_marcacao is not distinct from p_tipo_marcacao and j.hora is not distinct from p_hora
              and j.hora_ini is not distinct from p_hora_ini and j.hora_fim is not distinct from p_hora_fim) then
    raise exception 'Já existe um pedido igual em análise.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and status = 'pendente') >= 10 then
    raise exception 'Você já tem 10 pedidos em análise. Aguarde a resposta do gestor.';
  end if;
  if (select count(*) from ponto_justificativas where tecnico_id = p_tecnico and created_at > now() - interval '24 hours') >= 5 then
    raise exception 'Limite de 5 pedidos em 24 horas. Fale com o seu gestor.';
  end if;

  insert into ponto_justificativas (empresa_id, tecnico_id, motivo, data, tipo_marcacao, hora, hora_ini, hora_fim, observacao, canal)
  values (v_tec.empresa_id, p_tecnico, p_motivo, p_data,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_tipo_marcacao end,
          case when p_motivo in ('esqueci_marcar', 'falha_registro') then p_hora end,
          case when p_motivo = 'atraso_saida' then p_hora_ini end,
          case when p_motivo = 'atraso_saida' then p_hora_fim end,
          v_obs, p_canal)
  returning id, numero into v_id, v_num;

  -- supervisores: no máximo um aviso por funcionário por hora; os seguintes aparecem no painel
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_pedido_' || p_tecnico || '_' || to_char(now(), 'HH24'), current_date, now(), true,
          jsonb_build_object('tecnico', p_tecnico))
  on conflict do nothing;
  if found then
    perform fn_ponto_avisar_supervisores(p_tecnico,
      '📝 *Ponto · ' || split_part(trim(v_tec.nome), ' ', 1) || '*: pedido de ajuste nº ' || v_num
      || ' (' || to_char(p_data, 'DD/MM') || '). Veja em Registro de Ponto › Ajustes.');
  end if;

  return jsonb_build_object('id', v_id, 'numero', v_num, 'motivo', v_mot.nome, 'data', to_char(p_data, 'DD/MM/YYYY'),
    'detalhe', fn_ponto_justificativa_detalhe(p_motivo, p_tipo_marcacao, p_hora, p_hora_ini, p_hora_fim));
end $$;

-- "Saída às 17:05" / "das 08:00 às 08:40"
create or replace function fn_ponto_justificativa_detalhe(p_motivo text, p_tipo text, p_hora time, p_ini time, p_fim time)
returns text language sql immutable set search_path = public, extensions as $$
  select case
    when p_motivo in ('esqueci_marcar', 'falha_registro') then fn_ponto_rotulo(p_tipo) || ' às ' || to_char(p_hora, 'HH24:MI')
    when p_ini is not null then 'das ' || to_char(p_ini, 'HH24:MI') || ' às ' || to_char(p_fim, 'HH24:MI')
    else 'dia inteiro' end
$$;

-- Conversa "ajuste" no WhatsApp (textos da persona marca; decisão 57: sem ameaça) ----------------------
create or replace function fn_ponto_wh_ajuste(p_tecnico uuid, p_nome text, p_tel text, p_fuso text,
  p_etapa text, p_dados jsonb, p_norm text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_dados jsonb := coalesce(p_dados, '{}');
  v_hoje  date := (now() at time zone p_fuso)::date;
  v_data  date;
  v_hora  time;
  v_ini   time;
  v_fim   time;
  v_par   text[];
  r       jsonb;
  v_menu  text := 'Ajuste de ponto, ' || split_part(trim(p_nome), ' ', 1) || '. O que aconteceu? Responda o número:' || E'\n'
    || '*1* Saúde: atestado, consulta ou exame' || E'\n'
    || '*2* Família: falecimento, casamento ou nascimento' || E'\n'
    || '*3* Convocação: justiça, eleição ou outra' || E'\n'
    || '*4* Ponto: esqueci de marcar, atrasei ou o app falhou' || E'\n'
    || '*0* Cancelar';
  v_marc  text := 'Qual marcação ficou faltando?' || E'\n'
    || '*1* Entrada  *2* Saída para almoço  *3* Volta do almoço' || E'\n'
    || '*4* Saída  *5* Início de hora extra  *6* Fim de hora extra';
begin
  -- conversa de ajuste: 15 minutos a partir da última resposta
  if p_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Pedido de ajuste cancelado. Para recomeçar, escreva *ajuste*.');
    return jsonb_build_object('acao', 'ajuste_cancelado');
  end if;

  if p_etapa is null or p_norm in ('ajuste', 'justificar', 'justificativa') then
    insert into ponto_conversas (tecnico_id, etapa, tipo, dados, expira_em)
    values (p_tecnico, 'aj_menu', null, jsonb_build_object('inicio', now()), now() + interval '15 minutes')
    on conflict (tecnico_id) do update set etapa = 'aj_menu', tipo = null, dados = excluded.dados, expira_em = excluded.expira_em;
    perform fn_ponto_wa(p_tel, v_menu);
    return jsonb_build_object('acao', 'ajuste_menu');
  end if;

  if p_etapa = 'aj_menu' then
    if p_norm in ('1', '2', '3') then
      update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Este tipo de pedido chega em breve por aqui e pelo app. Por enquanto, entregue o documento ao seu gestor.');
      return jsonb_build_object('acao', 'ajuste_em_breve');
    elsif p_norm = '4' then
      update ponto_conversas set etapa = 'aj_motivo', expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, '*Ponto.* O que aconteceu?' || E'\n' || '*1* Esqueci de marcar' || E'\n'
        || '*2* O app ou o WhatsApp não funcionou' || E'\n' || '*3* Cheguei atrasado ou saí mais cedo' || E'\n'
        || '*0* Cancelar' || E'\n' || 'O gestor analisa cada caso.');
      return jsonb_build_object('acao', 'ajuste_ponto');
    end if;
    perform fn_ponto_wa(p_tel, 'Não entendi essa opção.' || E'\n\n' || v_menu);
    return jsonb_build_object('acao', 'ajuste_menu_repetido');
  end if;

  if p_etapa = 'aj_motivo' then
    if p_norm not in ('1', '2', '3') then
      perform fn_ponto_wa(p_tel, 'Responda *1*, *2* ou *3*, ou *0* para cancelar.');
      return jsonb_build_object('acao', 'ajuste_motivo_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('motivo', (array['esqueci_marcar', 'falha_registro', 'atraso_saida'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_dia', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Qual dia? Ex.: *15/10*. Responda *hoje* ou *ontem*, se for o caso.');
    return jsonb_build_object('acao', 'ajuste_pediu_dia');
  end if;

  if p_etapa = 'aj_dia' then
    v_data := fn_ponto_ler_data(p_norm, v_hoje);
    if v_data is null or v_data > v_hoje or v_data < v_hoje - 62 then
      perform fn_ponto_wa(p_tel, 'Não entendi o dia. Responda como *15/10*, *hoje* ou *ontem* (até 62 dias atrás).');
      return jsonb_build_object('acao', 'ajuste_dia_repetido');
    end if;
    v_dados := v_dados || jsonb_build_object('data', v_data);
    if v_dados->>'motivo' = 'atraso_saida' then
      update ponto_conversas set etapa = 'aj_periodo', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(p_tel, 'Qual período? Ex.: *8h às 9h*.');
      return jsonb_build_object('acao', 'ajuste_pediu_periodo');
    end if;
    update ponto_conversas set etapa = 'aj_marcacao', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, v_marc);
    return jsonb_build_object('acao', 'ajuste_pediu_marcacao');
  end if;

  if p_etapa = 'aj_marcacao' then
    if p_norm !~ '^[1-6]$' then
      perform fn_ponto_wa(p_tel, 'Responda o número de *1* a *6*.' || E'\n\n' || v_marc);
      return jsonb_build_object('acao', 'ajuste_marcacao_repetida');
    end if;
    v_dados := v_dados || jsonb_build_object('tipo', (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[p_norm::int]);
    update ponto_conversas set etapa = 'aj_hora', dados = v_dados, expira_em = now() + interval '15 minutes' where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, 'Que horas foi? Ex.: *7h30*.');
    return jsonb_build_object('acao', 'ajuste_pediu_hora');
  end if;

  if p_etapa = 'aj_hora' then
    v_hora := fn_ponto_ler_hora(p_norm);
    if v_hora is null then
      perform fn_ponto_wa(p_tel, 'Não entendi o horário. Responda como *7h30* ou *17:05*.');
      return jsonb_build_object('acao', 'ajuste_hora_repetida');
    end if;
  elsif p_etapa = 'aj_periodo' then
    v_par := regexp_split_to_array(p_norm, '\s*(?:as|a|ate|-)\s+|\s*-\s*');
    if array_length(v_par, 1) = 2 then v_ini := fn_ponto_ler_hora(v_par[1]); v_fim := fn_ponto_ler_hora(v_par[2]); end if;
    if v_ini is null or v_fim is null or v_ini >= v_fim then
      perform fn_ponto_wa(p_tel, 'Não entendi o período. Responda como *8h às 9h* (o início antes do fim).');
      return jsonb_build_object('acao', 'ajuste_periodo_repetido');
    end if;
  else
    return null;
  end if;

  -- última resposta: cria o pedido
  begin
    r := fn_ponto_justificativa_criar(p_tecnico, v_dados->>'motivo', (v_dados->>'data')::date, v_dados->>'tipo',
                                      v_hora, v_ini, v_fim, null, 'whatsapp');
  exception when others then
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(p_tel, case when sqlstate = 'P0001' then 'Não foi possível registrar o pedido: ' || sqlerrm
                                    else 'Não foi possível registrar o pedido agora. Tente de novo ou fale com o gestor.' end);
    return jsonb_build_object('acao', 'ajuste_erro', 'erro', sqlerrm);
  end;
  update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
  perform fn_ponto_wa(p_tel, '✅ *Pedido ' || (r->>'numero') || ' recebido*' || E'\n'
    || (r->>'motivo') || ' · ' || (r->>'data') || ' · ' || (r->>'detalhe') || E'\n'
    || 'O gestor vai analisar. A resposta chega aqui e na aba Ajuste do app.');
  return jsonb_build_object('acao', 'ajuste_registrado', 'numero', r->'numero');
end $$;

-- App do funcionário (decisão 49: o funcionário vem sempre da sessão) ---------------------------------
create or replace function ponto_justificar(p_token text, p_motivo text, p_data date, p_tipo_marcacao text default null,
  p_hora time default null, p_hora_ini time default null, p_hora_fim time default null, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return fn_ponto_justificativa_criar(v_tec, p_motivo, p_data, p_tipo_marcacao, p_hora, p_hora_ini, p_hora_fim, p_observacao, 'app');
end $$;

create or replace function ponto_minhas_justificativas(p_token text)
returns table (numero bigint, motivo text, data text, detalhe text, status text, resposta text, criado_em text)
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
begin
  return query
    select j.numero, m.nome, to_char(j.data, 'DD/MM/YYYY'),
           fn_ponto_justificativa_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim),
           j.status, j.resposta, to_char(j.created_at at time zone coalesce(e.fuso, 'America/Bahia'), 'DD/MM HH24:MI')
      from ponto_justificativas j join ponto_motivos m on m.codigo = j.motivo
      join empresas e on e.id = j.empresa_id
     where j.tecnico_id = v_tec and j.created_at > now() - interval '90 days'
     order by j.created_at desc limit 50;
end $$;

-- Painel: pedidos (pendentes sempre; decididos do período). Leitura não vê observação nem resposta -----
create or replace function app_ponto_justificativas(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, numero bigint, tecnico_id uuid, tecnico text, motivo text, motivo_nome text, grupo text,
               data date, detalhe text, tipo_marcacao text, hora text, hora_ini text, hora_fim text,
               observacao text, canal text, status text, decidido_por text, decidido_em text, resposta text, criado_em text,
               abono_estornado boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_leitura boolean;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select j.id, j.numero, j.tecnico_id, t.nome, j.motivo, m.nome, m.grupo, j.data,
           fn_ponto_justificativa_detalhe(j.motivo, j.tipo_marcacao, j.hora, j.hora_ini, j.hora_fim),
           j.tipo_marcacao, to_char(j.hora, 'HH24:MI'), to_char(j.hora_ini, 'HH24:MI'), to_char(j.hora_fim, 'HH24:MI'),
           case when v_leitura then null else j.observacao end, j.canal, j.status,
           case when v_leitura then null else j.decidido_por end,
           to_char(j.decidido_em at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           case when v_leitura then null else j.resposta end,
           to_char(j.created_at at time zone e.fuso, 'DD/MM/YYYY HH24:MI'),
           exists (select 1 from ponto_abonos x where x.estorno_de = j.abono_id)
      from ponto_justificativas j
      join tecnicos t on t.id = j.tecnico_id
      join empresas e on e.id = j.empresa_id
      join ponto_motivos m on m.codigo = j.motivo
     where (j.status = 'pendente' or j.data between p_de and p_ate)
       and (p_tecnico is null or j.tecnico_id = p_tecnico)
     order by (j.status = 'pendente') desc, j.created_at desc;
end $$;

-- Aprovar ou negar (admin e gestor). Aprovado: marcação incluída por ajuste ou abono do período ----------
create or replace function app_ponto_decidir(p_id uuid, p_aprovar boolean, p_resposta text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  j       record;
  v_tec   record;
  v_resp  text := nullif(trim(coalesce(p_resposta, '')), '');
  v_mom   timestamptz;
  v_aj    uuid;
  v_ab    uuid;
  v_txt   text;
  v_mot   text;
begin
  select * into j from ponto_justificativas where id = p_id for update;
  if not found then raise exception 'Pedido não encontrado.'; end if;
  if j.status <> 'pendente' then raise exception 'Este pedido já foi decidido.'; end if;
  select t.nome, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = j.tecnico_id;
  if length(coalesce(v_resp, '')) > 500 then raise exception 'Resposta com no máximo 500 letras.'; end if;
  v_mot := 'Pedido nº ' || j.numero || ' do funcionário, aprovado';
  select nome into v_txt from ponto_motivos where codigo = j.motivo;

  if not p_aprovar then
    if length(coalesce(v_resp, '')) < 10 then raise exception 'Escreva o motivo da negativa (pelo menos 10 letras). Ele vai para o funcionário.'; end if;
    update ponto_justificativas set status = 'negada', decidido_por = v_email, decidido_em = now(), resposta = v_resp where id = p_id;
    v_txt := '*Pedido ' || j.numero || ' não aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Motivo do gestor: ' || v_resp || E'\n' || 'Tem como comprovar? Escreva *ajuste* e faça um novo pedido.';
  elsif j.motivo in ('esqueci_marcar', 'falha_registro') then
    v_mom := (j.data + j.hora) at time zone v_tec.fuso;
    if exists (select 1 from ponto_ajustes a where a.tecnico_id = j.tecnico_id and a.acao = 'incluir'
                and a.tipo = j.tipo_marcacao and a.momento = v_mom
                and not exists (select 1 from ponto_ajustes d where d.ajuste_id = a.id)) then
      raise exception 'Esta marcação já foi incluída. Negue o pedido como repetido.';
    end if;
    insert into ponto_ajustes (empresa_id, tecnico_id, acao, momento, tipo, motivo, autor, justificativa_id)
    values (j.empresa_id, j.tecnico_id, 'incluir', v_mom, j.tipo_marcacao, v_mot, v_email, j.id)
    returning id into v_aj;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, ajuste_id = v_aj
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Marcação incluída: ' || fn_ponto_rotulo(j.tipo_marcacao) || ' às ' || to_char(j.hora, 'HH24:MI') || '.';
  else
    if exists (select 1 from ponto_abonos a where a.tecnico_id = j.tecnico_id and a.data = j.data and a.estorno_de is null
                and a.inicio is not distinct from j.hora_ini and a.fim is not distinct from j.hora_fim
                and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id)) then
      raise exception 'Este período já está abonado. Negue o pedido como repetido.';
    end if;
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, motivo, autor)
    values (j.empresa_id, j.tecnico_id, j.data, j.hora_ini, j.hora_fim, j.id, v_mot, v_email)
    returning id into v_ab;
    update ponto_justificativas set status = 'aprovada', decidido_por = v_email, decidido_em = now(), resposta = v_resp, abono_id = v_ab
     where id = p_id;
    v_txt := '✅ *Pedido ' || j.numero || ' aprovado*' || E'\n' || v_txt || ' · ' || to_char(j.data, 'DD/MM') || E'\n'
      || 'Abonado ' || fn_ponto_justificativa_detalhe(j.motivo, null, null, j.hora_ini, j.hora_fim) || ': esse período não é descontado.';
  end if;

  if v_tec.ativo and v_tec.opt_in and v_tec.telefone_e164 is not null then
    perform fn_ponto_wa(v_tec.telefone_e164, v_txt);
  end if;
  return jsonb_build_object('numero', j.numero, 'status', case when p_aprovar then 'aprovada' else 'negada' end,
                            'ajuste_id', v_aj, 'abono_id', v_ab);
end $$;

-- Abono direto do gestor (falta justificada fora do sistema). Motivo sem dado de saúde (decisão 52) -----
create or replace function app_ponto_abonar(p_tecnico uuid, p_data date, p_motivo text,
  p_inicio time default null, p_fim time default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_tec   record;
  v_hoje  date;
  v_id    uuid;
  v_det   text;
begin
  select t.id, t.empresa_id, t.telefone_e164, t.ativo, t.opt_in, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  if not found then raise exception 'Funcionário não encontrado.'; end if;
  if v_tec.empresa_id is null then raise exception 'Funcionário sem empresa cadastrada não tem ponto.'; end if;
  v_hoje := (now() at time zone v_tec.fuso)::date;
  if p_data is null or p_data > v_hoje then raise exception 'Abono só até hoje.'; end if;
  if p_data < v_hoje - 62 then raise exception 'Abono só para os últimos 62 dias.'; end if;
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
  return jsonb_build_object('id', v_id, 'data', to_char(p_data, 'DD/MM/YYYY'), 'detalhe', v_det);
end $$;

-- Estorno de abono (lançado por engano). O abono continua guardado
create or replace function app_ponto_estornar_abono(p_abono uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
  v_id    uuid;
begin
  select * into a from ponto_abonos where id = p_abono;
  if not found or a.estorno_de is not null then raise exception 'Abono não encontrado.'; end if;
  if length(trim(coalesce(p_motivo, ''))) not between 10 and 500 then raise exception 'Escreva o motivo do estorno (10 a 500 letras).'; end if;
  begin
    insert into ponto_abonos (empresa_id, tecnico_id, data, inicio, fim, justificativa_id, estorno_de, motivo, autor)
    values (a.empresa_id, a.tecnico_id, a.data, a.inicio, a.fim, a.justificativa_id, a.id, trim(p_motivo), v_email)
    returning id into v_id;
  exception when unique_violation then raise exception 'Este abono já foi estornado.';
  end;
  return jsonb_build_object('id', v_id);
end $$;

-- Abonos do período (leitura vê sem motivo nem autor)
create or replace function app_ponto_abonos(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, tecnico_id uuid, tecnico text, data date, detalhe text, pedido bigint,
               estornado boolean, motivo text, autor text, criado_em text)
language plpgsql stable security definer set search_path = public, extensions as $$
declare v_leitura boolean;
begin
  v_leitura := fn_papel(app_exigir(array['admin','gestor','leitura'])) = 'leitura';
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select a.id, a.tecnico_id, t.nome, a.data, fn_ponto_justificativa_detalhe('abono', null, null, a.inicio, a.fim),
           j.numero, exists (select 1 from ponto_abonos x where x.estorno_de = a.id),
           case when v_leitura then null else a.motivo end, case when v_leitura then null else a.autor end,
           to_char(a.created_at at time zone coalesce(e.fuso, 'America/Bahia'), 'DD/MM/YYYY HH24:MI')
      from ponto_abonos a join tecnicos t on t.id = a.tecnico_id join empresas e on e.id = a.empresa_id
      left join ponto_justificativas j on j.id = a.justificativa_id
     where a.estorno_de is null and a.data between p_de and p_ate and (p_tecnico is null or a.tecnico_id = p_tecnico)
     order by a.data desc, a.created_at desc;
end $$;

-- Jornada com falta e abono (base: migration 65) ----------------------------------------------------
create or replace function fn_ponto_jornada_dia(p_tecnico uuid, p_data date)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'public', 'extensions'
as $function$
declare
  v_fuso    text;
  m         record;
  v_ent     timestamptz;
  v_sa      timestamptz;
  v_va      timestamptz;
  v_sai     timestamptz;
  v_he_ini  timestamptz;
  v_he      int := 0;
  v_normal  int;
  v_total   int;
  v_int     int;
  v_extra   int;
  v_inter   int;
  v_ant     timestamptz;
  v_esc     time;
  v_atraso  int;
  v_n       int := 0;
  v_ajustes int;
  v_hoje    boolean;
  v_ini     timestamptz;
  v_fim     timestamptz;
  v_al      text[] := '{}';
  v_jornada int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_int_min int := coalesce(nullif(fn_config('intervalo_min'), '')::int, 60);
  v_int_max int := coalesce(nullif(fn_config('ponto_intervalo_max_min'), '')::int, 120);
  v_int_cur int := coalesce(nullif(fn_config('ponto_intervalo_curto_min'), '')::int, 15);
  v_he_lim  int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
  v_ij_min  int := coalesce(nullif(fn_config('ponto_interjornada_min'), '')::int, 660);
  v_tol     int := coalesce(nullif(fn_config('ponto_tolerancia_min'), '')::int, 5);
  v_ab_dia  boolean := false;
  v_ab_min  int := 0;
  v_ab_txt  text;
begin
  select coalesce(e.fuso, 'America/Bahia') into v_fuso
    from tecnicos t left join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  v_fuso := coalesce(v_fuso, 'America/Bahia');
  v_hoje := p_data >= (now() at time zone v_fuso)::date;
  v_ini := p_data::timestamp at time zone v_fuso;
  v_fim := (p_data + 1)::timestamp at time zone v_fuso;

  for m in select x.tipo, x.momento from fn_ponto_marcacoes_efetivas(p_tecnico, v_ini, v_fim) x
            order by x.momento, x.nsr nulls last loop
    v_n := v_n + 1;
    case m.tipo
      when 'entrada'      then v_ent := coalesce(v_ent, m.momento);
      when 'saida_almoco' then v_sa  := coalesce(v_sa, m.momento);
      when 'volta_almoco' then v_va  := coalesce(v_va, m.momento);
      when 'saida'        then v_sai := m.momento;
      when 'inicio_he'    then v_he_ini := m.momento;
      when 'fim_he'       then
        if v_he_ini is not null then
          v_he := v_he + (extract(epoch from m.momento - v_he_ini) / 60)::int;
          v_he_ini := null;
        end if;
      else null;
    end case;
  end loop;

  select count(*) into v_ajustes
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and coalesce(a.momento, x.momento, y.momento) >= v_ini and coalesce(a.momento, x.momento, y.momento) < v_fim;
  -- escala do dia e abonos (decisão 55): dia com escala já passado e sem marcação é falta
  select min(s.hora_inicio) into v_esc from escalas s
   where s.tecnico_id = p_tecnico and s.data_servico = p_data and s.status not in ('cancelada', 'recusada', 'rascunho');
  select coalesce(bool_or(a.inicio is null), false),
         coalesce(sum(extract(epoch from a.fim - a.inicio) / 60) filter (where a.inicio is not null), 0)::int,
         string_agg(case when a.inicio is null then 'dia inteiro'
                         else to_char(a.inicio, 'HH24:MI') || '–' || to_char(a.fim, 'HH24:MI') end, ', ' order by a.inicio nulls first)
    into v_ab_dia, v_ab_min, v_ab_txt
    from ponto_abonos a
   where a.tecnico_id = p_tecnico and a.data = p_data and a.estorno_de is null
     and not exists (select 1 from ponto_abonos x where x.estorno_de = a.id);
  if v_n = 0 and v_ajustes = 0 and v_ab_txt is null and (v_esc is null or v_hoje) then return null; end if;

  -- trabalho normal: entrada → saída, descontado o intervalo
  if v_ent is not null and v_sai is not null then
    v_normal := (extract(epoch from v_sai - v_ent) / 60)::int;
    if v_sa is not null and v_va is not null then
      v_normal := v_normal - (extract(epoch from v_va - v_sa) / 60)::int;
    end if;
  end if;
  if v_sa is not null and v_va is not null then
    v_int := (extract(epoch from v_va - v_sa) / 60)::int;
  end if;
  v_total := coalesce(v_normal, 0) + v_he;
  v_extra := greatest(v_total - v_jornada, 0);

  -- intervalo intrajornada (CLT art. 71)
  if v_int is not null then
    if v_int < v_int_min and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_curto');
    elsif v_int < v_int_cur and v_normal > 240 then v_al := array_append(v_al, 'intervalo_curto');
    end if;
    if v_int > v_int_max and (v_normal is null or v_normal > 360) then v_al := array_append(v_al, 'intervalo_longo'); end if;
  elsif v_normal > 360 then
    v_al := array_append(v_al, 'sem_intervalo');
  end if;
  -- hora extra (CLT art. 59)
  if v_extra > v_he_lim then v_al := array_append(v_al, 'he_acima_limite'); end if;
  -- interjornada (CLT art. 66): da última saída efetiva antes desta entrada
  if v_ent is not null then
    select max(x.momento) into v_ant from fn_ponto_marcacoes_efetivas(p_tecnico, v_ent - interval '2 days', v_ent) x
     where x.tipo in ('saida', 'fim_he');
    if v_ant is not null then
      v_inter := (extract(epoch from v_ent - v_ant) / 60)::int;
      if v_inter < v_ij_min then v_al := array_append(v_al, 'interjornada_curta'); end if;
    end if;
  end if;
  -- atraso em relação à escala (CLT art. 58, §1º)
  if v_esc is not null and v_ent is not null then
    v_atraso := (extract(epoch from (v_ent at time zone v_fuso)::time - v_esc) / 60)::int;
    if v_atraso > v_tol then
      v_al := array_append(v_al, case when v_ab_dia or v_ab_min >= v_atraso then 'atraso_abonado' else 'atraso' end);
    else v_atraso := null; end if;
  end if;
  -- dia já encerrado com marcação faltando
  if v_n = 0 and v_esc is not null and not v_hoje then
    v_al := array_append(v_al, case when v_ab_dia then 'falta_abonada' else 'falta' end);
  elsif v_n > 0 and not v_hoje and (v_ent is null or v_sai is null or (v_sa is null) <> (v_va is null) or v_he_ini is not null) then
    v_al := array_append(v_al, 'incompleta');
  end if;

  return jsonb_build_object(
    'entrada', to_char(v_ent at time zone v_fuso, 'HH24:MI'),
    'saida_almoco', to_char(v_sa at time zone v_fuso, 'HH24:MI'),
    'volta_almoco', to_char(v_va at time zone v_fuso, 'HH24:MI'),
    'saida', to_char(v_sai at time zone v_fuso, 'HH24:MI'),
    'trabalhado_min', case when v_normal is null and v_he = 0 then null else v_total end,
    'intervalo_min', v_int, 'he_min', v_extra, 'interjornada_min', v_inter,
    'escala_hora', left(v_esc::text, 5), 'atraso_min', v_atraso,
    'marcacoes', v_n, 'ajustes', v_ajustes, 'alertas', to_jsonb(v_al),
    'abono', v_ab_txt, 'abonado_min', case when v_ab_dia then v_jornada else v_ab_min end);
end $function$;

-- Espelho: dias com escala (falta) e com abono também aparecem; coluna abono ---------------------------
drop function if exists app_ponto_espelho(date, date, uuid);
create function app_ponto_espelho(p_de date, p_ate date, p_tecnico uuid default null)
 returns table(tecnico_id uuid, tecnico text, data date, escala_hora text, entrada text, saida_almoco text,
               volta_almoco text, saida text, trabalhado_min integer, intervalo_min integer, he_min integer,
               atraso_min integer, interjornada_min integer, alertas text[], ajustes integer, abono text)
 language plpgsql
 stable security definer
 set search_path to 'public', 'extensions'
as $function$
begin
  perform app_exigir(array['admin','gestor','leitura']);
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    with dias as (
      select distinct m.tecnico_id as tid, (m.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date as dia
        from ponto_marcacoes m join empresas e on e.id = m.empresa_id
       where m.momento >= p_de::timestamp - interval '1 day' and m.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or m.tecnico_id = p_tecnico)
      union
      select a.tecnico_id, (a.momento at time zone coalesce(e.fuso, 'America/Bahia'))::date
        from ponto_ajustes a join empresas e on e.id = a.empresa_id
       where a.acao = 'incluir'
         and a.momento >= p_de::timestamp - interval '1 day' and a.momento < p_ate::timestamp + interval '2 days'
         and (p_tecnico is null or a.tecnico_id = p_tecnico)
      union
      -- dia com escala (falta aparece) e dia com abono
      select s.tecnico_id, s.data_servico
        from escalas s join tecnicos t on t.id = s.tecnico_id and t.empresa_id is not null and t.cpf is not null
       where s.data_servico between p_de and p_ate and s.status not in ('cancelada', 'recusada', 'rascunho')
         and (p_tecnico is null or s.tecnico_id = p_tecnico)
      union
      select b.tecnico_id, b.data from ponto_abonos b
       where b.data between p_de and p_ate and (p_tecnico is null or b.tecnico_id = p_tecnico)
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
end $function$;

-- Conversa do ponto (definição da migration 61) com o pedido de ajuste na frente ---------------------
create or replace function fn_ponto_wh(p_data jsonb)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  v_key    jsonb := p_data->'key';
  v_msg    jsonb := p_data->'message';
  v_wa_id  text  := p_data->'key'->>'id';
  v_jid    text;
  v_tec    record;
  v_conv   record;
  v_norm   text;
  v_ultima text;
  v_tipo   text;
  v_loc    jsonb;
  v_lat    numeric;
  v_lng    numeric;
  v_prec   int;
  c        jsonb;
  v_btn    text;
  v_citou  boolean;
  v_aviso  text;
begin
  if coalesce((v_key->>'fromMe')::boolean, false) or v_wa_id is null then return null; end if;
  -- grupo, status e canal não são do ponto
  if coalesce(v_key->>'remoteJid', '') ~ '@(g\.us|broadcast|newsletter)$' then return null; end if;
  select j into v_jid from unnest(array[v_key->>'remoteJid', v_key->>'remoteJidAlt',
                                        v_key->>'senderPn', p_data->>'sender']) as j
   where j like '%@s.whatsapp.net' limit 1;
  if v_jid is null then return null; end if;

  select t.id, t.nome, t.telefone_e164, t.cpf, t.empresa_id, coalesce(e.fuso, 'America/Bahia') as fuso
    into v_tec from tecnicos t left join empresas e on e.id = t.empresa_id
   where fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1)) and t.ativo;
  -- telefone canônico ambíguo (com e sem o 9): não arrisca marcar no funcionário errado
  if (select count(*) from tecnicos t where t.ativo
        and fn_tel_canonico(t.telefone_e164) = fn_tel_canonico(split_part(v_jid, '@', 1))) > 1 then
    return null;
  end if;
  -- só quem está cadastrado para o ponto (CPF e empresa) conversa com o ponto
  if v_tec.id is null or v_tec.cpf is null or v_tec.empresa_id is null then return null; end if;

  -- trava a conversa: duas localizações simultâneas não geram duas marcações
  select * into v_conv from ponto_conversas where tecnico_id = v_tec.id and expira_em > now() for update;
  v_norm := lower(trim(translate(coalesce(v_msg->>'conversation', v_msg->'extendedTextMessage'->>'text', ''),
                                 'áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ', 'aaaaeeiooouc' || 'aaaaeeiooouc')));
  v_norm := regexp_replace(v_norm, '[.!?]+$', '');
  v_loc := coalesce(v_msg->'liveLocationMessage', v_msg->'locationMessage');
  -- resposta de botão (mesmos formatos de fn_wh_mensagem) e mensagem que cita outra
  v_btn := coalesce(v_msg->'buttonsResponseMessage'->>'selectedButtonId',
                    v_msg->'templateButtonReplyMessage'->>'selectedId');
  if v_btn is null and v_msg ? 'interactiveResponseMessage' then
    begin
      v_btn := ((v_msg->'interactiveResponseMessage'->'nativeFlowResponseMessage'->>'paramsJson')::jsonb)->>'id';
    exception when others then v_btn := null; end;
  end if;
  v_citou := v_msg->'extendedTextMessage'->'contextInfo'->>'stanzaId' is not null;

  -- 0. Pedido de ajuste (decisão 55): a palavra "ajuste" abre a conversa; dentro dela, as respostas
  -- são do pedido (resposta citando outra mensagem segue para as escalas)
  -- escala enviada ou ocorrência aberta depois do início do pedido: a resposta é da escala, e a conversa
  -- de ajuste termina (o funcionário recomeça com "ajuste")
  if v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%'
     and (exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                   where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                     and o.created_at > now() - interval '2 hours')
          or exists (select 1 from notificacoes n join escalas e on e.id = n.escala_id
                      where e.tecnico_id = v_tec.id
                        and n.created_at > coalesce((v_conv.dados->>'inicio')::timestamptz, now() - interval '15 minutes'))) then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    v_conv.tecnico_id := null;
  end if;
  if v_loc is null and v_btn is null and not v_citou
     and (v_norm in ('ajuste', 'justificar', 'justificativa')
          or (v_conv.tecnico_id is not null and v_conv.etapa like 'aj\_%' and v_norm <> '')) then
    return fn_ponto_wh_ajuste(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_tec.fuso,
                              case when v_conv.etapa like 'aj\_%' then v_conv.etapa end, v_conv.dados, v_norm);
  end if;

  select m.tipo into v_ultima from ponto_marcacoes m
   where m.tecnico_id = v_tec.id and (m.momento at time zone v_tec.fuso)::date = (now() at time zone v_tec.fuso)::date
   order by m.nsr desc limit 1;

  -- 1. Localização
  if v_loc is not null then
    if exists (select 1 from ponto_marcacoes where origem ->> 'msg_id' = v_wa_id) then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');
    end if;
    if v_conv.tecnico_id is null or v_conv.etapa <> 'aguardando_local' then
      -- atualização da localização em tempo real fora da conversa: ignora em silêncio
      if v_msg ? 'liveLocationMessage' then return jsonb_build_object('ignorado', 'ponto: localização sem conversa'); end if;
      perform fn_ponto_wa(v_tec.telefone_e164, 'Para bater o ponto, escreva *ponto* primeiro e depois mande a localização.');
      return jsonb_build_object('acao', 'ponto_localizacao_sem_conversa');
    end if;
    -- lugar escolhido no mapa traz nome ou endereço; a localização atual não
    if v_msg ? 'locationMessage' and (coalesce(v_loc->>'name', '') <> '' or coalesce(v_loc->>'address', '') <> '') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é um lugar escolhido no mapa. Mande a sua *localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_recusada');
    end if;
    -- localização encaminhada (de outra pessoa ou uma antiga do próprio funcionário). A Evolution 2.x
    -- traz o contexto em data.contextInfo; o protocolo o põe dentro da localização (messageContextInfo
    -- fica por garantia)
    if exists (select 1 from (values (v_loc->'contextInfo'), (p_data->'contextInfo'), (v_msg->'messageContextInfo')) x(ci)
                where coalesce(ci->>'isForwarded', '') = 'true'
                   or coalesce(nullif(ci->>'forwardingScore', ''), '0') <> '0') then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Localização encaminhada não vale para o ponto. Mande a *sua localização atual*: 📎 → Localização → *Enviar localização atual*.');
      return jsonb_build_object('acao', 'ponto_localizacao_encaminhada');
    end if;
    v_lat := (v_loc->>'degreesLatitude')::numeric;
    v_lng := (v_loc->>'degreesLongitude')::numeric;
    v_prec := nullif(v_loc->>'accuracyInMeters', '')::numeric::int;
    if v_lat is null or v_lng is null then return null; end if;
    -- localização FIXA com a coordenada exata (6 casas, ~10 cm) de uma marcação anterior: pode ser
    -- reenviada. Pede a localização em tempo real, que não pode ser encaminhada e é sempre leitura nova
    -- (GPS com cache dentro de prédio também repete coordenada: o funcionário honesto tem saída)
    if v_msg ? 'locationMessage' and exists (select 1 from ponto_marcacoes m
                where m.tecnico_id = v_tec.id and m.momento > now() - interval '60 days'
                  and m.latitude = round(v_lat, 6) and m.longitude = round(v_lng, 6)) then
      perform fn_ponto_wa(v_tec.telefone_e164, 'Essa localização é igual à de uma marcação anterior. Mande a sua *localização em tempo real*: 📎 → Localização → *Compartilhar localização em tempo real* (pode ser por 15 minutos).');
      return jsonb_build_object('acao', 'ponto_localizacao_repetida');
    end if;
    begin
      c := fn_ponto_registrar(v_tec.id, v_conv.tipo, 'whatsapp', v_lat, v_lng, v_prec,
                              jsonb_build_object('msg_id', v_wa_id));
    exception when unique_violation then
      return jsonb_build_object('ignorado', 'ponto: evento duplicado');   -- entrega simultânea
    when others then
      -- só a mensagem de regra (raise exception) vai ao funcionário; o detalhe técnico fica no log
      perform fn_ponto_wa(v_tec.telefone_e164, case when sqlstate = 'P0001'
        then 'Não foi possível registrar o ponto: ' || sqlerrm
        else 'Não foi possível registrar o ponto agora. Tente de novo ou fale com o gestor.' end);
      return jsonb_build_object('acao', 'ponto_erro', 'erro', sqlerrm);
    end;
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    -- comprovante no WhatsApp: CPF mascarado (o canal passa por terceiros)
    perform fn_ponto_wa(v_tec.telefone_e164,
      '✅ *Ponto registrado*' || E'\n\n'
      || '*' || fn_ponto_rotulo(c->>'tipo') || '* — ' || (c->>'data') || ' às ' || (c->>'hora') || E'\n'
      || 'NSR ' || (c->>'nsr') || ' · ' || (c->>'empresa') || E'\n'
      || (c->>'trabalhador') || ' · CPF ***.' || substr(c->>'cpf', 4, 3) || '.' || substr(c->>'cpf', 7, 3) || '-**' || E'\n'
      || coalesce('Local: ' || (c->>'local') || case when (c->>'dentro_area')::boolean is false
                   then ' (a ' || (c->>'distancia_m') || ' m: o gestor será avisado)' else '' end || E'\n', '')
      || 'Autenticação: ' || (c->>'autenticacao')
      -- avisos de jornada (intervalo, hora extra, interjornada): a marcação vale, o gestor é avisado
      || coalesce(E'\n\n' || array_to_string(fn_ponto_avisar(v_tec.id, c->>'tipo'), E'\n'), ''));
    return jsonb_build_object('acao', 'ponto_registrado', 'nsr', c->'nsr');
  end if;

  -- 2. Botão, número do menu ou palavra do ponto
  if v_btn is not null then
    -- botão de outro fluxo (escala) segue para as escalas
    if v_btn !~ '^ponto:(entrada|saida_almoco|volta_almoco|saida|inicio_he|fim_he)$' then return null; end if;
    v_tipo := substring(v_btn from 7);
  elsif v_conv.tecnico_id is not null and v_conv.etapa = 'escolher_tipo' and v_norm ~ '^[1-6]$' and not v_citou then
    -- número só vale como escolha do menu se não for resposta citando outra mensagem (ex.: a escala)
    v_tipo := (array['entrada','saida_almoco','volta_almoco','saida','inicio_he','fim_he'])[v_norm::int];
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm in ('0', 'cancelar', 'sair') then
    update ponto_conversas set expira_em = now() where tecnico_id = v_tec.id;
    perform fn_ponto_wa(v_tec.telefone_e164, 'Registro de ponto cancelado. Para recomeçar, escreva *ponto*.');
    return jsonb_build_object('acao', 'ponto_cancelado');
  elsif v_norm in ('entrada', 'entrei', 'cheguei', 'inicio do expediente') then
    v_tipo := 'entrada';
  elsif v_norm in ('almoco', 'saida almoco', 'saida para almoco', 'saida para o almoco', 'sai para almoco', 'intervalo') then
    v_tipo := case when v_ultima = 'saida_almoco' then 'volta_almoco' else 'saida_almoco' end;
  elsif v_norm in ('volta', 'volta do almoco', 'voltei', 'retorno', 'retorno do almoco') then
    v_tipo := 'volta_almoco';
  elsif v_norm in ('saida', 'fim do expediente') then
    v_tipo := 'saida';
  elsif v_norm in ('he', 'hora extra', 'horas extras') then
    v_tipo := case when v_ultima = 'inicio_he' then 'fim_he' else 'inicio_he' end;
  elsif v_norm in ('ponto', 'bater ponto', 'registro de ponto', 'registrar ponto', 'marcar ponto') then
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, null);
    return jsonb_build_object('acao', 'ponto_menu');
  elsif v_norm ~ '^(1|2|s|n|sim|nao|ok|ciente|confirmado|confirmada|confirmo|ciente, confirmado|problema|tenho um problema)$'
     or exists (select 1 from ocorrencias o join escalas e on e.id = o.escala_id
                 where e.tecnico_id = v_tec.id and o.status = 'aberta' and o.detalhe is null
                   and o.created_at > now() - interval '2 hours') then
    -- resposta típica de escala, ou detalhe de ocorrência aberta (como em fn_wh_mensagem): segue
    -- para as escalas mesmo dentro da conversa do ponto
    return null;
  elsif v_conv.tecnico_id is not null and not v_citou and v_norm <> '' then
    -- dentro da conversa do ponto, resposta que não é opção válida volta para o menu
    perform fn_ponto_menu(v_tec.id, v_tec.nome, v_tec.telefone_e164, v_ultima, 'Não entendi essa opção.');
    return jsonb_build_object('acao', 'ponto_menu_repetido');
  else
    return null;   -- não é do ponto: segue para as escalas
  end if;

  insert into ponto_conversas (tecnico_id, etapa, tipo, expira_em)
  values (v_tec.id, 'aguardando_local', v_tipo, now() + interval '10 minutes')
  on conflict (tecnico_id) do update set etapa = 'aguardando_local', tipo = excluded.tipo, expira_em = excluded.expira_em;
  -- aviso ANTES de registrar a volta do almoço com intervalo abaixo do mínimo (não bloqueia)
  v_aviso := fn_ponto_aviso_previo(v_tec.id, v_tipo);
  perform fn_ponto_wa(v_tec.telefone_e164,
    coalesce(v_aviso || E'\n\n', '')
    || '*' || fn_ponto_rotulo(v_tipo) || '*. Agora mande a sua *localização atual*:' || E'\n'
    || '📎 → Localização → *Enviar localização atual*.' || E'\n\n'
    || 'A hora registrada é a do recebimento da localização.');
  return jsonb_build_object('acao', 'ponto_pediu_localizacao', 'tipo', v_tipo);
end $$;

-- Permissões por laço (decisões 12, 49 e 51) -------------------------------------------------------
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
