-- Migration 150: sábado de 4h e a nova régua de avisos depois do envio (pedido do responsável, 09/11; decisão 135).
-- Desenho revisado antes do código pelo arquiteto-dados e pelo seguranca (ajustes incorporados).
--
-- 1. Sábado: a escala usa os minutos da carga do funcionário no dia (sem carga, ponto_jornada_sabado_min = 240):
--    08:00 às 12:00, sem intervalo. Dias úteis continuam com jornada_min (8h). Vale também na Programação e na prévia.
-- 2. Régua, contada da entrega da escala (lida ou não; sem entrega, do envio):
--    +1h lembrete; +2h uma ligação (08:00 às 18:00); +3h último lembrete e aviso ao gestor que criou a escala.
--    Nada novo a partir das 18:00, nem no dia seguinte. Cada passo fica gravado na notificação (coluna passo) e um
--    índice único recusa o mesmo passo duas vezes.
-- 3. URA: uma ligação por escala, só da conta da operadora (a Twilio é da Infoxtec, decisão 108), nunca de escala de
--    teste, e no máximo ligacao_max_por_dia (20) por dia; ao estourar, um aviso técnico por dia.
-- 4. Gestor: o aviso sai pelo canal da conta da escala; quem desligar "receber avisos de programação"
--    (conta_membros.recebe_avisos) não recebe, e o aviso vai aos supervisores, como antes.

set lock_timeout = '5s';

-- notificacoes antes de escalas: a mesma ordem de travas do motor (fase 1), para não cruzar com ele
-- passo da régua de cada envio: 0 a escala, 1 o lembrete, 3 o último (nulo nos registros anteriores à 150)
alter table interno.notificacoes add column if not exists passo smallint;
-- ciclo de confirmação: a edição que pede nova confirmação (data, hora ou local) abre outro e a régua recomeça
alter table interno.notificacoes add column if not exists ciclo smallint not null default 1;

-- o mesmo passo não sai duas vezes; reenvio por falha de entrega (reenvio_falha) repete o passo e fica fora
create unique index if not exists notificacoes_passo_uk on interno.notificacoes (escala_id, ciclo, passo)
  where passo is not null and status_envio <> 'falha' and tipo <> 'reenvio_falha';

-- a view do motor lê a escala com a última e a primeira notificação: índice composto no lugar do simples
create index if not exists notificacoes_escala_criada_idx on interno.notificacoes (escala_id, created_at);
drop index if exists interno.idx_notif_escala;


-- ---------------------------------------------------------------------------------------------------------------
-- Configurações
-- ---------------------------------------------------------------------------------------------------------------
insert into interno.config (chave, valor, descricao) values
  ('regua_lembrete_min', '60',  'Minutos depois da entrega da escala para o lembrete pelo WhatsApp (migration 150)'),
  ('regua_ligacao_min',  '120', 'Minutos depois da entrega da escala para a ligação da URA (migration 150)'),
  ('regua_final_min',    '180', 'Minutos depois da entrega da escala para o último lembrete e o aviso ao gestor (migration 150)'),
  ('regua_fim',          '18:00', 'Depois desta hora a régua não envia nem liga; o passo vencido depois dela é perdido (migration 150)'),
  ('ligacao_max_por_dia', '20', 'Teto de ligações automáticas da URA por dia; ao estourar, um aviso técnico (migration 150)')
on conflict (chave) do nothing;

-- só muda o valor padrão antigo: um valor já ajustado à mão fica
update interno.config set valor = '18:00' where chave = 'ligacao_janela_fim' and valor = '20:00';
update interno.config set valor = '1' where chave = 'ligacao_max_por_escala' and valor = '2';
-- 3 envios da régua (escala, lembrete, último) + até 2 reenvios por falha de entrega
update interno.config set valor = '5' where chave = 'max_tentativas' and valor = '3';

create or replace function interno.fn_validar_config()
 returns trigger
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v text := coalesce(new.valor, '');
begin
  begin
    if new.chave in ('envios_por_execucao','envios_por_conta_por_execucao','max_tentativas','avisar_supervisor_na','intervalo_reenvio_min',
                     'timeout_entrega_min','motor_alerta_min','jornada_min','intervalo_min','intervalo_apos_min',
                     'antecedencia_minima_min','certificacao_aviso_dias','documento_tamanho_max_mb',
                     'ligacao_apos_tentativas','ligacao_intervalo_min','ligacao_max_por_escala',
                     'ligacao_por_execucao','voz_timeout_dtmf','retencao_webhook_dias','retencao_cron_dias',
                     'retencao_documentos_anos','retencao_payload_dias','conclusao_automatica_min',
                     'banco_alerta_mb','alerta_certificacoes_dow',
                     'regua_lembrete_min','regua_ligacao_min','regua_final_min','ligacao_max_por_dia') then
      if v !~ '^\d+$' then raise exception 'inteiro'; end if;
      -- 0 desliga; 1 (segunda) a 7 (domingo), o mesmo dia ISO que fn_alerta_certificacoes compara como
      -- texto: um dígito só ('07' passaria no inteiro e nunca dispararia)
      if new.chave = 'alerta_certificacoes_dow' and v !~ '^[0-7]$' then raise exception 'dia'; end if;
      -- régua: passo zero dispararia junto com a escala
      if new.chave in ('regua_lembrete_min','regua_ligacao_min','regua_final_min') and v::int < 1 then
        raise exception 'positivo';
      end if;
    elsif new.chave = 'hora_noturna_min' then
      if v::numeric <= 0 then raise exception 'positivo'; end if;
    elsif new.chave in ('janela_envio_inicio','janela_envio_fim','alerta_escala_aviso','alerta_escala_prazo',
                        'alerta_certificacoes_hora','ligacao_janela_inicio','ligacao_janela_fim',
                        'noturno_inicio','noturno_fim','regua_fim') then
      if v !~ '^\d{2}:\d{2}$' then raise exception 'hora'; end if;
      perform v::time;
    elsif new.chave in ('webhook_ativo','usar_botoes','ligacao_ativa','sem_escala_incluir_supervisores') then
      if v not in ('true','false') then raise exception 'booleano'; end if;
    elsif new.chave = 'fuso' then
      if not exists (select 1 from pg_timezone_names where name = v) then raise exception 'fuso'; end if;
    elsif new.chave = 'alerta_dias_semana' then
      if v !~ '^[1-7](,[1-7])*$' then raise exception 'dias'; end if;
    elsif new.chave = 'alerta_tecnico_telefones' then
      if v <> '' and v !~ '^\d{12,13}(\s*,\s*\d{12,13})*$' then raise exception 'telefones'; end if;
    elsif new.chave = 'monitor_ping_url' then
      -- só o endereço de ping do healthchecks.io: a URL é chamada pelo motor a cada minuto
      if v <> '' and v !~ '^https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        raise exception 'url';
      end if;
    end if;
  exception when others then
    raise exception 'Valor inválido para %: "%"', new.chave, new.valor
      using hint = case new.chave
        when 'alerta_dias_semana' then 'Use dias de 1 (segunda) a 7, separados por vírgula: 1,2,3,4,5'
        when 'alerta_certificacoes_dow' then 'Use 1 (segunda) a 7 (domingo); 0 desliga o alerta'
        when 'monitor_ping_url' then 'Use o endereço de ping do healthchecks.io: https://hc-ping.com/<uuid>, ou vazio'
        when 'alerta_tecnico_telefones' then 'Use telefones com DDI e DDD, só números, separados por vírgula: 5571999999999'
        when 'fuso' then 'Use um fuso válido, por exemplo America/Bahia'
        else 'Confira o formato: inteiro, hora HH:MM ou true/false' end;
  end;
  return new;
end $function$;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Jornada do sábado
-- ---------------------------------------------------------------------------------------------------------------
-- Versão com o alvo do dia; nulo ou menor que 1 = jornada_min (a de um argumento repassa para esta)
create or replace function interno.fn_calcular_jornada(p_inicio time without time zone, p_alvo_min integer)
 returns table(turno text, trabalho_min integer, intervalo_min integer, minutos_noturnos integer, hora_fim time without time zone)
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_alvo      numeric := case when coalesce(p_alvo_min, 0) >= 1 then p_alvo_min
                              else coalesce(fn_config_int('jornada_min'), 480) end;
  v_interv    int     := coalesce(fn_config_int('intervalo_min'), 60);
  v_apos      int     := coalesce(fn_config_int('intervalo_apos_min'), 240);
  -- CLT art. 71: acima de 6h, o intervalo configurado; de mais de 4h até 6h, 15 minutos; até 4h, nenhum
  v_pausa     int;
  v_n_ini     int     := extract(hour from fn_config('noturno_inicio')::time)::int * 60
                         + extract(minute from fn_config('noturno_inicio')::time)::int;
  v_n_fim     int     := extract(hour from fn_config('noturno_fim')::time)::int * 60
                         + extract(minute from fn_config('noturno_fim')::time)::int;
  v_fator     numeric := 60.0 / coalesce(fn_config('hora_noturna_min')::numeric, 52.5);
  v_ini       int     := extract(hour from p_inicio)::int * 60 + extract(minute from p_inicio)::int;
  -- Sumula 60 TST: jornada iniciada entre o inicio do noturno e meia-noite, prorrogada apos o fim
  v_prorroga  boolean := v_ini >= v_n_ini or v_ini = 0;
  v_legal     numeric := 0;
  v_t         int := 0;
  v_trab      int := 0;
  v_not       int := 0;
  v_pausou    boolean := false;
  v_m         int;
  v_noite     boolean;
begin
  v_pausa := case when v_alvo > 360 then v_interv when v_alvo > 240 then 15 else 0 end;
  while v_legal < v_alvo and v_t < 1440 loop
    if not v_pausou and v_pausa > 0 and v_trab >= v_apos then
      v_t := v_t + v_pausa;
      v_pausou := true;
      continue;
    end if;
    v_m := (v_ini + v_t) % 1440;
    v_noite := v_prorroga or v_m >= v_n_ini or v_m < v_n_fim;
    v_legal := v_legal + case when v_noite then v_fator else 1 end;
    v_trab := v_trab + 1;
    if v_noite then v_not := v_not + 1; end if;
    v_t := v_t + 1;
  end loop;

  turno := case when v_not = 0 then 'diurno' when v_not = v_trab then 'noturno' else 'misto' end;
  trabalho_min := v_trab;
  intervalo_min := case when v_pausou then v_pausa else 0 end;
  minutos_noturnos := v_not;
  hora_fim := (p_inicio + make_interval(mins => v_t))::time;
  return next;
end $function$;

create or replace function interno.fn_calcular_jornada(p_inicio time without time zone)
 returns table(turno text, trabalho_min integer, intervalo_min integer, minutos_noturnos integer, hora_fim time without time zone)
 language sql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
  select * from interno.fn_calcular_jornada(p_inicio, null::integer)
$function$;

-- Alvo do dia: só o sábado muda (a carga diz quanto completa a semana; sem carga, ponto_jornada_sabado_min).
-- Nulo = jornada_min. Sábado sem expediente na carga (0) ou acima da jornada: segue a regra de sempre.
create or replace function interno.fn_jornada_alvo_min(p_tecnico uuid, p_data date)
 returns integer
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_min int;
begin
  if p_data is null or extract(isodow from p_data) <> 6 then return null; end if;
  v_min := fn_carga_minutos_dia(p_tecnico, p_data);
  if v_min between 1 and coalesce(fn_config_int('jornada_min'), 480) then return v_min; end if;
  return null;
end $function$;

create or replace function interno.fn_aplicar_jornada()
 returns trigger
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  j record;
begin
  select * into j from fn_calcular_jornada(new.hora_inicio, fn_jornada_alvo_min(new.tecnico_id, new.data_servico));
  new.turno                := j.turno;
  new.duracao_prevista_min := j.trabalho_min;
  new.intervalo_min        := j.intervalo_min;
  new.minutos_noturnos     := j.minutos_noturnos;
  new.hora_fim_prevista    := j.hora_fim;
  return new;
end $function$;

-- o dia e o funcionário agora decidem a jornada: mover a escala ou trocar o técnico recalcula
drop trigger if exists trg_escalas_jornada on interno.escalas;
create trigger trg_escalas_jornada before insert or update of hora_inicio, data_servico, tecnico_id
  on interno.escalas for each row execute function interno.fn_aplicar_jornada();

create or replace function interno.fn_programacao_limite(p_tecnico uuid, p_data date, p_hora time without time zone default null::time without time zone, p_ignorar uuid default null::uuid)
 returns jsonb
 language plpgsql
 stable
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ini   timestamp;
  v_fim   timestamp;
  v_int   int := 0;
  j       record;
  v_prev  int := 0;
  v_contr int := fn_carga_minutos_dia(p_tecnico, p_data);
  v_lim   int := coalesce(nullif(fn_config('ponto_he_limite_min'), '')::int, 120);
begin
  select min(e.data_servico + e.hora_inicio),
         max(e.data_servico + e.hora_inicio + make_interval(mins => e.duracao_prevista_min + coalesce(e.intervalo_min, 0))),
         coalesce(max(coalesce(e.intervalo_min, 0)), 0)
    into v_ini, v_fim, v_int
    from escalas e
   where e.tecnico_id = p_tecnico and e.data_servico = p_data and e.status not in ('cancelada', 'recusada')
     and e.id is distinct from p_ignorar;
  if p_hora is not null then
    -- a mesma jornada que o gatilho vai gravar (sábado pela carga, migration 150)
    select * into j from fn_calcular_jornada(p_hora, fn_jornada_alvo_min(p_tecnico, p_data));
    v_ini := least(coalesce(v_ini, p_data + p_hora), p_data + p_hora);
    v_fim := greatest(coalesce(v_fim, p_data + p_hora + make_interval(mins => j.trabalho_min + j.intervalo_min)),
                      p_data + p_hora + make_interval(mins => j.trabalho_min + j.intervalo_min));
    v_int := greatest(v_int, j.intervalo_min);
  end if;
  if v_ini is not null then
    v_prev := greatest((extract(epoch from v_fim - v_ini) / 60)::int - v_int, 0);
  end if;
  return jsonb_build_object('previsto_min', v_prev, 'contratual_min', v_contr, 'limite_min', v_contr + v_lim,
                            'excedente_min', greatest(v_prev - (v_contr + v_lim), 0));
end $function$;

-- prévia do painel: com a data, mostra o sábado de 4h (sem técnico: a regra padrão do sábado)
drop function if exists public.app_simular_jornada(time without time zone);
create or replace function public.app_simular_jornada(p_inicio time without time zone, p_data date default null)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  j record;
begin
  perform app_exigir(array['admin','gestor','leitura']);
  select * into j from fn_calcular_jornada(p_inicio, fn_jornada_alvo_min(null, p_data));
  return to_jsonb(j);
end $function$;

-- sábados futuros ainda não enviados passam a 4h (os já enviados ficam como foram)
do $$
begin
  perform set_config('app.ator', 'migração 150', true);
  update interno.escalas set hora_inicio = hora_inicio
   where status in ('rascunho', 'agendada')
     and extract(isodow from data_servico) = 6
     and data_servico >= (now() at time zone coalesce(nullif(interno.fn_config('fuso'), ''), 'America/Bahia'))::date;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Régua de avisos
-- ---------------------------------------------------------------------------------------------------------------
create or replace view interno.vw_acoes_pendentes as
 with agora as materialized (
   select (now() at time zone coalesce(nullif(interno.fn_config('fuso'), ''), 'America/Bahia')) as local_ts,
          coalesce(nullif(interno.fn_config('fuso'), ''), 'America/Bahia') as fuso,
          interno.fn_config_int('max_tentativas') as max_tent,
          make_interval(mins => interno.fn_config_int('timeout_entrega_min')) as timeout_entrega,
          make_interval(mins => coalesce(interno.fn_config_int('regua_lembrete_min'), 60)) as lembrete,
          make_interval(mins => coalesce(interno.fn_config_int('regua_final_min'), 180)) as final,
          coalesce(nullif(interno.fn_config('regua_fim'), ''), '18:00')::time as fim,
          interno.fn_config('janela_envio_inicio')::time as janela_ini,
          interno.fn_config('janela_envio_fim')::time as janela_fim
 ), alvo as (
   select e.id as escala_id,
          e.status,
          e.supervisor_avisado_em,
          t.nome as tecnico,
          t.telefone_e164 as telefone,
          n.id as notificacao_id,
          n.tentativa,
          n.status_envio,
          n.enviada_em,
          n.ciclo,
          n.passo_ultimo,
          n.passo_feito,
          n.reenvios,
          (n.ancora at time zone g.fuso) as ancora_local,
          (n.primeira_em at time zone g.fuso)::date as dia_primeira
     from interno.escalas e
     join interno.tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in
     join interno.contas c on c.id = e.conta_id and c.ativa
     cross join agora g
     -- só o ciclo atual (a reconfirmação depois de editar abre outro)
     left join lateral (
       select (array_agg(x.id order by x.created_at desc))[1] as id,
              (array_agg(x.tentativa order by x.created_at desc))[1] as tentativa,
              (array_agg(x.status_envio order by x.created_at desc))[1] as status_envio,
              (array_agg(x.enviada_em order by x.created_at desc))[1] as enviada_em,
              (array_agg(x.passo_eff order by x.created_at desc))[1] as passo_ultimo,
              max(x.ciclo) as ciclo,
              max(x.passo_eff) filter (where x.status_envio <> 'falha') as passo_feito,
              count(*) filter (where x.tipo = 'reenvio_falha') as reenvios,
              -- âncora: a entrega do 1º envio do ciclo que não falhou (lido ou não); sem entrega, o envio
              (array_agg(coalesce(x.entregue_em, x.lida_em, x.enviada_em) order by x.created_at)
                 filter (where x.status_envio in ('enviada', 'entregue', 'lida')))[1] as ancora,
              min(x.created_at) as primeira_em
         from (select nn.*,
                      -- registros anteriores à 150 não têm passo: o lembrete conta como o passo 1
                      coalesce(nn.passo, case when nn.tipo = 'lembrete' then 1 else 0 end) as passo_eff,
                      max(nn.ciclo) over () as ciclo_atual
                 from interno.notificacoes nn where nn.escala_id = e.id) x
        where x.ciclo = x.ciclo_atual
     ) n on true
    where e.status in ('agendada', 'notificada')
      and (e.data_servico + e.hora_inicio) > g.local_ts
      and interno.fn_ponto_afastado_ate(e.tecnico_id, e.data_servico) is null
 ), regua as (
   select a.*,
          -- a régua só anda no mesmo dia do ciclo, antes do fim (nada vira lembrete no dia seguinte)
          (g.local_ts::time < g.fim and a.dia_primeira = g.local_ts::date) as regua_aberta,
          -- a entrega falhou de novo depois de 2 reenvios: para de reenviar e avisa
          (a.reenvios >= 2 and (a.status_envio = 'falha'
                                or (a.status_envio = 'enviada' and a.enviada_em < now() - g.timeout_entrega))) as falhas_esgotadas,
          case
            when a.ancora_local is null then null
            when coalesce(a.passo_feito, 0) < 3 and g.local_ts >= a.ancora_local + g.final
                 and (a.ancora_local + g.final)::date = g.local_ts::date and (a.ancora_local + g.final)::time < g.fim then 3
            when coalesce(a.passo_feito, 0) < 1 and g.local_ts >= a.ancora_local + g.lembrete
                 and (a.ancora_local + g.lembrete)::date = g.local_ts::date and (a.ancora_local + g.lembrete)::time < g.fim then 1
          end as passo_vencido
     from alvo a cross join agora g
 )
 select r.escala_id,
        r.status,
        r.tecnico,
        r.telefone,
        r.notificacao_id,
        r.tentativa,
        r.status_envio,
        r.enviada_em,
        case
          when r.notificacao_id is null then 'enviar_primeira'
          -- último passo saiu, falhas esgotadas ou teto de segurança: aviso (falha de canal avisa como antes, na janela)
          when coalesce(r.passo_feito, 0) >= 3 or r.falhas_esgotadas or r.tentativa >= g.max_tent then 'escalonar'
          -- falha de entrega: repete o mesmo passo (a escala em si sai na janela de envio; lembretes, só com a régua aberta)
          when r.status_envio = 'falha' and r.enviada_em < now() - g.timeout_entrega
               and (r.passo_ultimo = 0 or r.regua_aberta) then 'reenviar_falha'
          when r.status_envio = 'enviada' and r.enviada_em < now() - g.timeout_entrega
               and (r.passo_ultimo = 0 or r.regua_aberta) then 'nao_recebeu'
          when r.status_envio in ('enviada', 'entregue', 'lida') and r.passo_vencido is not null and r.regua_aberta then 'reenviar'
          else null
        end as acao,
        case
          when r.status_envio = 'lida' then 'leu e nao respondeu'
          when r.status_envio = 'entregue' then 'recebeu e nao leu'
          when r.status_envio = 'enviada' then 'nao recebeu'
          when r.status_envio = 'falha' then 'falha no envio'
          else null
        end as diagnostico,
        -- o aviso antecipado (avisar_supervisor_na) saiu: só o passo final ou as falhas esgotadas avisam
        false as avisar_supervisor,
        case
          when r.notificacao_id is null then 0
          when r.status_envio in ('falha', 'enviada') and r.enviada_em < now() - g.timeout_entrega then r.passo_ultimo
          else r.passo_vencido
        end::smallint as passo,
        coalesce(r.ciclo, 1)::smallint as ciclo
   from regua r cross join agora g
  where g.local_ts::time >= g.janela_ini and g.local_ts::time <= g.janela_fim;

create or replace view interno.vw_ligacoes_pendentes as
 with agora as materialized (
   select (now() at time zone coalesce(nullif(interno.fn_config('fuso'), ''), 'America/Bahia')) as local_ts,
          coalesce(nullif(interno.fn_config('fuso'), ''), 'America/Bahia') as fuso,
          make_interval(mins => coalesce(interno.fn_config_int('regua_ligacao_min'), 120)) as espera,
          interno.fn_config('ligacao_janela_fim')::time as janela_fim,
          coalesce(interno.fn_config_int('ligacao_max_por_escala'), 1) as max_lig,
          make_interval(mins => interno.fn_config_int('ligacao_intervalo_min')) as intervalo
 )
 select e.id as escala_id,
        t.id as tecnico_id,
        t.nome as tecnico,
        t.telefone_e164 as telefone,
        coalesce(n.tentativa, 0) as tentativas_whatsapp,
        (select count(*) from interno.ligacoes l where l.escala_id = e.id) as ligacoes_feitas
   from interno.escalas e
   join interno.tecnicos t on t.id = e.tecnico_id and t.ativo and t.opt_in and not t.perfil_teste
   join interno.contas c on c.id = e.conta_id and c.ativa
   cross join agora g
   -- âncora do ciclo atual, a mesma da régua (a ligação continua uma por escala, em qualquer ciclo)
   join lateral (
     select max(x.tentativa) as tentativa,
            (array_agg(coalesce(x.entregue_em, x.lida_em, x.enviada_em) order by x.created_at)
               filter (where x.status_envio in ('enviada', 'entregue', 'lida')))[1] as ancora
       from (select nn.*, max(nn.ciclo) over () as ciclo_atual
               from interno.notificacoes nn where nn.escala_id = e.id) x
      where x.ciclo = x.ciclo_atual
   ) n on true
  where e.status = 'notificada'
    and e.local_id is not null
    and not e.teste
    -- a Twilio é da Infoxtec: ligação só da conta da operadora até existir telefonia por conta (decisão 108)
    and e.conta_id = '00000000-0000-0000-0000-000000000001'
    and (e.data_servico + e.hora_inicio) > g.local_ts
    and n.ancora is not null
    -- 2h depois da entrega, no mesmo dia e antes do fim da janela (nunca fica para a manhã seguinte)
    and g.local_ts >= (n.ancora at time zone g.fuso) + g.espera
    and ((n.ancora at time zone g.fuso) + g.espera)::date = g.local_ts::date
    and ((n.ancora at time zone g.fuso) + g.espera)::time < g.janela_fim
    and not exists (select 1 from interno.respostas r where r.escala_id = e.id)
    and (select count(*) from interno.ligacoes l where l.escala_id = e.id) < g.max_lig
    and not exists (select 1 from interno.ligacoes l
                     where l.escala_id = e.id
                       and (l.status in ('criada', 'discando') or l.criada_em > now() - g.intervalo))
    and coalesce(interno.fn_ligacao_permitida(now(), e.id), false)
    and interno.fn_ponto_afastado_ate(t.id, e.data_servico) is null;

-- URA: só a conta da operadora (vale também para o "Ligar agora")
create or replace function interno.fn_preparar_ligacao(p_escala uuid)
 returns jsonb
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  if not coalesce(fn_ligacao_permitida(now(), p_escala), false) then   -- config faltando nunca libera
    raise exception 'Ligações só em dias úteis, das % às %, fora de sábado, domingo e feriado.',
      fn_config('ligacao_janela_inicio'), fn_config('ligacao_janela_fim');
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status, e.local_id, e.conta_id, e.teste into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Programação não encontrada.'; end if;
  -- a Twilio é da Infoxtec (decisão 108): cliente só liga quando tiver telefonia própria
  if v_esc.conta_id <> '00000000-0000-0000-0000-000000000001' then
    raise exception 'A ligação pela URA ainda não está disponível para esta conta.';
  end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  -- escala de teste nunca vira ligação real (nem pelo "Ligar agora")
  if v_esc.teste then raise exception 'Programação de teste não recebe ligação.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A programação já foi respondida (%).', v_esc.status; end if;
  if v_esc.local_id is null then
    raise exception 'Programação sem local não é enviada nem ligada. Escolha o local.';
  end if;

  if not fn_pode_enviar(v_esc.telefone_e164) then
    raise exception 'Ambiente de homologação: só é possível ligar para cadastros de teste. % não é um.', v_esc.nome;
  end if;

  select count(*) + 1 into v_tent from ligacoes where escala_id = p_escala;
  insert into ligacoes (escala_id, tecnico_id, telefone, tentativa)
  values (p_escala, v_esc.tecnico_id, v_esc.telefone_e164, v_tent) returning id into v_id;
  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'ligacao_iniciada', 'ura', jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('ligacao_id', v_id, 'para', '+' || v_esc.telefone_e164, 'de', v_caller,
    'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
    'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN'));
end $function$;

-- teto diário de ligações automáticas (conta todas as do dia, inclusive o "Ligar agora")
create or replace function interno.fn_disparar_ligacoes()
 returns integer
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  p record; v_lig jsonb; v_n int := 0;
  v_max int := coalesce(fn_config_int('ligacao_por_execucao'), 2);
  v_teto int := coalesce(fn_config_int('ligacao_max_por_dia'), 20);
  v_fuso text := coalesce(nullif(fn_config('fuso'), ''), 'America/Bahia');
  v_hoje date := (now() at time zone v_fuso)::date;
  v_feitas int;
begin
  if not coalesce(fn_config('ligacao_ativa'), 'false')::boolean then return 0; end if;
  if coalesce(fn_config('twilio_caller_id'), '') = '' then return 0; end if;

  select count(*) into v_feitas from ligacoes
   where criada_em >= (v_hoje::timestamp at time zone v_fuso) and criada_em < ((v_hoje + 1)::timestamp at time zone v_fuso);

  for p in select * from vw_ligacoes_pendentes order by tentativas_whatsapp desc loop
    if v_feitas + v_n >= v_teto then
      -- um aviso técnico por dia (sem nome nem telefone)
      insert into alertas_enviados (conta_id, tipo, data_ref, detalhe)
      values ('00000000-0000-0000-0000-000000000001', 'ligacao_teto_dia', v_hoje, jsonb_build_object('teto', v_teto))
      on conflict do nothing;
      if found then
        begin
          perform fn_avisar_tecnico('⚠️ Trilha: a URA chegou ao teto de ' || v_teto
            || ' ligações hoje. As próximas ligações automáticas ficam para os avisos pelo WhatsApp. '
            || 'Ajuste ligacao_max_por_dia se for o caso.');
        exception when others then raise warning 'aviso do teto de ligações falhou: %', sqlerrm; end;
      end if;
      exit;
    end if;
    exit when v_n >= v_max;
    begin
      v_lig := fn_preparar_ligacao(p.escala_id);
      perform net.http_post(
        url  := fn_config('voz_url') || '?acao=iniciar&token=' || fn_segredo('VOZ_TOKEN'),
        body := jsonb_build_object('ligacao_id', v_lig->>'ligacao_id'));
      v_n := v_n + 1;
    exception when others then
      raise warning 'ligacao falhou para escala %: %', p.escala_id, sqlerrm;
    end;
  end loop;
  return v_n;
end $function$;

-- ---------------------------------------------------------------------------------------------------------------
-- Gestor: "receber avisos de programação" (o telefone é o mesmo da recuperação das duas etapas; finalidade nova
-- registrada na decisão 135, base legal: execução do contrato e legítimo interesse do empregador)
-- ---------------------------------------------------------------------------------------------------------------
alter table interno.conta_membros add column if not exists recebe_avisos boolean not null default true;

drop function if exists public.app_usuarios();
create function public.app_usuarios()
 returns table(email text, nome text, papel text, ativo boolean, criado_por text, created_at timestamp with time zone, updated_at timestamp with time zone, ve_saude boolean, rh_folhas boolean, telefone_e164 text, recebe_avisos boolean)
 language plpgsql
 stable security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_conta uuid;
begin
  perform app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  return query select m.email, m.nome, m.papel, m.ativo, m.criado_por, m.criado_em, m.atualizado_em, m.ve_saude, m.rh_folhas,
                      m.telefone_e164, m.recebe_avisos
                 from interno.conta_membros m
                where m.conta_id = v_conta
                order by coalesce(m.nome, m.email);
end $function$;

create or replace function public.app_definir_avisos_usuario(p_email text, p_recebe boolean)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text;
  v_conta uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_novo  boolean := coalesce(p_recebe, true);
  v_antes boolean;
begin
  v_ator := app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  select recebe_avisos into v_antes from conta_membros where conta_id = v_conta and email = v_email for update;
  if not found then raise exception 'Usuário não encontrado nesta conta.'; end if;
  if v_antes = v_novo then return; end if;
  update conta_membros set recebe_avisos = v_novo, atualizado_em = now() where conta_id = v_conta and email = v_email;
  -- o dono do número fica sabendo (LGPD, art. 9º): quem mudou e o que muda
  perform fn_alerta_email('Trilha: avisos de programação no seu WhatsApp',
    'Os avisos de programação sem confirmação no seu WhatsApp (' || v_email || ') foram '
    || case when v_novo then 'ligados' else 'desligados' end || ' por ' || v_ator || '. '
    || case when v_novo then 'Quando uma programação criada por você ficar 3 horas sem confirmação do funcionário, até as 18h, o aviso chega no WhatsApp cadastrado.'
            else 'Os avisos das programações criadas por você passam a ir aos supervisores.' end
    || ' Se você não esperava essa mudança, avise o administrador da sua conta.',
    array[v_email]);
end $function$;

-- o e-mail da troca de número passa a dizer as duas finalidades (recuperação e avisos de programação)
create or replace function public.app_definir_telefone_usuario(p_email text, p_telefone text)
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_ator  text;
  v_conta uuid;
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_tel   text := nullif(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g'), '');
  v_antes text;
begin
  v_ator := app_exigir(array['admin']);
  v_conta := fn_conta_atual();
  if v_tel is not null and v_tel !~ '^[0-9]{12,13}$' then
    raise exception 'WhatsApp inválido: use DDI e DDD, só números. Ex: 5571981776307';
  end if;
  select telefone_e164 into v_antes from conta_membros where conta_id = v_conta and email = v_email for update;
  if not found then raise exception 'Usuário não encontrado nesta conta.'; end if;
  if v_antes is not distinct from v_tel then return; end if;
  update conta_membros set telefone_e164 = v_tel, atualizado_em = now() where conta_id = v_conta and email = v_email;
  perform fn_alerta_email('Trilha: WhatsApp de recuperação e avisos alterado',
    'O WhatsApp de recuperação da verificação em duas etapas e dos avisos de programação do seu login (' || v_email || ') foi '
    || case when v_tel is null then 'removido' else 'alterado para o final ' || right(v_tel, 4) end
    || ' por ' || v_ator || '. Esse número recebe o código se você perder o aplicativo autenticador e, se os avisos '
    || 'estiverem ligados, o aviso das programações criadas por você que ficarem sem confirmação. '
    || 'Se você não esperava essa mudança, avise o suporte.',
    array[v_email]);
end $function$;

-- Painel: editar com nova confirmação abre outro ciclo; reenviar à mão repete o passo (a partir da homologação)
create or replace function public.app_editar_escala(p jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_conta   uuid := fn_conta_atual();
  e         escalas;
  v_data    date;
  v_hora    time;
  v_local   uuid;
  v_tarefa  text;
  v_mudou   boolean;
  v_reconf  boolean;
  v_tec     record;
  v_tent    int;
  v_ciclo   int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
  v_lim     jsonb;
begin
  select * into e from escalas where id = (p->>'id')::uuid and conta_id = v_conta for update;
  if not found then raise exception 'Programação não encontrada.'; end if;
  if e.status not in ('rascunho', 'agendada', 'notificada', 'confirmada') then
    raise exception 'Só dá para editar programação em rascunho, agendada, aguardando resposta ou confirmada.';
  end if;
  perform fn_edicao_permitida(e.id);

  v_data   := coalesce(nullif(p->>'data_servico', '')::date, e.data_servico);
  v_hora   := coalesce(nullif(p->>'hora_inicio', '')::time, e.hora_inicio);
  v_local  := case when p ? 'local_id' then nullif(p->>'local_id', '')::uuid else e.local_id end;
  v_tarefa := coalesce(nullif(trim(p->>'descricao_tarefa'), ''), e.descricao_tarefa);
  v_mudou  := v_data <> e.data_servico or v_hora <> e.hora_inicio or v_local is distinct from e.local_id;
  if v_local is distinct from e.local_id and v_local is not null
     and not exists (select 1 from locais where id = v_local and conta_id = v_conta) then
    raise exception 'Local não encontrado.';
  end if;

  if not v_mudou and v_tarefa = e.descricao_tarefa then
    return jsonb_build_object('alterada', false);
  end if;
  if v_data <> e.data_servico or v_hora <> e.hora_inicio then
    perform fn_validar_inicio(v_data, v_hora);
    -- limite de 2 h extras no novo dia (decisão 90)
    perform pg_advisory_xact_lock(hashtext(e.tecnico_id::text || v_data::text));
    v_lim := fn_programacao_limite(e.tecnico_id, v_data, v_hora, e.id);
    if (v_lim->>'excedente_min')::int > 0 then
      perform fn_programacao_conferir_aceite(p->'aceite', e.tecnico_id, v_lim, (select nome from tecnicos where id = e.tecnico_id));
      if e.teste then v_lim := null; end if;  -- teste não gera termo
    else
      v_lim := null;
    end if;
  end if;

  -- decisao do responsavel (27/09): so data, hora ou local pedem nova confirmacao
  v_reconf := v_mudou and e.status in ('notificada', 'confirmada');
  perform set_config('app.ator', v_email, true);
  begin
    update escalas
       set data_servico = v_data, hora_inicio = v_hora, local_id = v_local, descricao_tarefa = v_tarefa,
           status = case when v_reconf then 'notificada'::escala_status else status end,
           confirmada_em = case when v_reconf then null else confirmada_em end,
           supervisor_avisado_em = case when v_mudou then null else supervisor_avisado_em end
     where id = e.id;
  exception when unique_violation then
    raise exception 'O técnico já tem outra programação ativa nesse dia e horário.';
  end;
  if v_lim is not null then
    perform fn_programacao_registrar_aceite(e.id, p->'aceite', v_lim, v_email);
  end if;

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (e.id, 'escala_editada', v_email, jsonb_build_object(
    'antes', jsonb_build_object('data', e.data_servico, 'hora', e.hora_inicio, 'local_id', e.local_id, 'tarefa', e.descricao_tarefa),
    'depois', jsonb_build_object('data', v_data, 'hora', v_hora, 'local_id', v_local, 'tarefa', v_tarefa),
    'nova_confirmacao', v_reconf));

  -- aviso ao tecnico quando a escala ja tinha saido
  if e.status in ('notificada', 'confirmada') and not e.teste then
    select telefone_e164, ativo, opt_in into v_tec from tecnicos where id = e.tecnico_id;
    if v_tec.ativo and v_tec.opt_in then
      if v_reconf then
        perform fn_wa_texto(v_tec.telefone_e164,
          '⚠️ *PROGRAMAÇÃO ALTERADA*' || E'\n\n' || 'Sua programação mudou. Confira os novos dados na mensagem a seguir e responda de novo.');
        -- nova confirmação = novo ciclo: a régua (lembrete, ligação, último e aviso) recomeça deste envio (migration 150)
        select coalesce(max(tentativa), 0) + 1, coalesce(max(ciclo), 0) + 1 into v_tent, v_ciclo from notificacoes where escala_id = e.id;
        v_payload := fn_payload_escala(e.id, v_tec.telefone_e164, false, v_botoes);
        v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id, passo, ciclo)
        values (e.id, (case when v_tent = 1 then 'primeira' else 'lembrete' end)::notificacao_tipo, 1,
                case when v_botoes then 'botoes_evolution' else 'texto_evolution' end, 'enfileirada', v_payload, now(), v_req, 0, v_ciclo);
      else
        perform fn_wa_texto(v_tec.telefone_e164,
          '📝 A tarefa da sua programação de ' || to_char(v_data, 'DD/MM') || ' às ' || to_char(v_hora, 'HH24:MI')
          || ' foi atualizada: ' || left(v_tarefa, 500));
      end if;
    end if;
  end if;

  return jsonb_build_object('alterada', true, 'nova_confirmacao', v_reconf);
end $function$;

create or replace function public.app_reenviar_escala(p_escala uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_email   text := app_exigir(array['admin','gestor']);
  v_esc     record;
  v_tent    int;
  v_ciclo   int;
  v_passo   int;
  v_botoes  boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_payload jsonb;
  v_req     bigint;
begin
  select e.id, e.status, t.telefone_e164, t.ativo, t.opt_in
    into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id
  where e.id = p_escala and e.conta_id = fn_conta_atual();

  if not found then raise exception 'Programação não encontrada.'; end if;
  if v_esc.status not in ('agendada', 'notificada') then
    raise exception 'Só é possível reenviar programações agendadas ou aguardando resposta.';
  end if;
  if not v_esc.ativo or not v_esc.opt_in then
    raise exception 'O técnico está inativo ou sem autorização para mensagens.';
  end if;
  if exists (select 1 from notificacoes where escala_id = p_escala and status_envio = 'enfileirada') then
    raise exception 'Já existe um envio em andamento para esta programação. Aguarde um minuto.';
  end if;

  -- reenvio manual repete o passo atual do ciclo, sem avançar a régua (migration 150)
  select coalesce(max(ciclo), 1) into v_ciclo from notificacoes where escala_id = p_escala;
  select coalesce(max(tentativa), 0) + 1 into v_tent from notificacoes where escala_id = p_escala and ciclo = v_ciclo;
  select coalesce(n.passo, case when n.tipo = 'lembrete' then 1 else 0 end) into v_passo
    from notificacoes n where n.escala_id = p_escala and n.ciclo = v_ciclo order by n.created_at desc limit 1;
  v_payload := fn_payload_escala(p_escala, v_esc.telefone_e164, coalesce(v_passo, 0) > 0, v_botoes);
  v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');

  insert into notificacoes
    (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id, passo, ciclo)
  values
    (p_escala, (case when v_tent = 1 then 'primeira' else 'reenvio_falha' end)::notificacao_tipo,
     v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
     'enfileirada', v_payload, now(), v_req, coalesce(v_passo, 0), v_ciclo);

  insert into escala_eventos (escala_id, evento, ator, detalhe)
  values (p_escala, 'reenvio_manual', v_email, jsonb_build_object('tentativa', v_tent));

  return jsonb_build_object('reenviada', true, 'tentativa', v_tent);
end $function$;

-- ---------------------------------------------------------------------------------------------------------------
-- Motor: passo gravado no envio; aviso ao gestor que criou a escala, pelo canal da conta dela
-- ---------------------------------------------------------------------------------------------------------------
create or replace function interno.fn_dispatcher_whatsapp()
 returns void
 language plpgsql
 security definer
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
declare
  n record; r_resp record; a record; s record;
  v_wa_id text; v_req bigint; v_tent int; v_texto text; v_payload jsonb; v_botoes boolean;
  v_sent int := 0;
  v_avisos int := 0;
  v_emp uuid;
  v_conta uuid;
  v_gestor text;
  v_destino text;
  v_limite int := coalesce(fn_config_int('envios_por_execucao'), 3);
  -- F5c: fila justa; cada conta envia no máximo isto por execução (padrão: o limite geral)
  v_limite_conta int := greatest(coalesce(fn_config_int('envios_por_conta_por_execucao'), coalesce(fn_config_int('envios_por_execucao'), 3)), 1);
  v_limite_sup int := greatest(coalesce(fn_config_int('supervisor_avisos_por_execucao'), 5), 1);
  v_webhook boolean := coalesce(fn_config('webhook_ativo'), 'false')::boolean;
  v_usar_botoes boolean := coalesce(fn_config('usar_botoes'), 'false')::boolean;
  v_inst text := fn_config('evolution_instancia');
  v_ping text := nullif(fn_config('monitor_ping_url'), '');
begin
  -- uma execucao por vez: uma chamada manual junto com o cron nao envia a mesma escala duas vezes
  if not pg_try_advisory_xact_lock(hashtext('fn_dispatcher_whatsapp')) then
    return;
  end if;
  -- nunca preso mais que 20 s esperando lock: a proxima execucao tenta de novo
  perform set_config('lock_timeout', '20s', true);
  perform set_config('app.ator', 'dispatcher', true);

  -- FASE 1: conferir o que a Evolution respondeu
  for n in select id, escala_id, http_req_id, created_at from notificacoes
           where status_envio = 'enfileirada' and http_req_id is not null loop
   begin
    select status_code, content, error_msg into r_resp from net._http_response where id = n.http_req_id;
    if not found then
      if n.created_at < now() - interval '5 minutes' then
        update notificacoes set status_envio = 'falha', erro_codigo = 'timeout',
               erro_mensagem = 'Sem resposta da Evolution em 5 minutos' where id = n.id;
      end if;
      continue;
    end if;
    if r_resp.status_code in (200, 201) then
      begin v_wa_id := (r_resp.content::jsonb) -> 'key' ->> 'id'; exception when others then v_wa_id := null; end;
      update notificacoes set status_envio = 'enviada', wa_message_id = v_wa_id where id = n.id;
      update escalas set status = 'notificada' where id = n.escala_id and status = 'agendada';
    else
      update notificacoes set status_envio = 'falha',
             erro_codigo = coalesce(r_resp.status_code::text, 'rede'),
             erro_mensagem = left(coalesce(r_resp.content, r_resp.error_msg, 'erro desconhecido'), 500)
       where id = n.id;
    end if;
   exception when others then
    raise warning 'fase 1, notificacao %: %', n.id, sqlerrm;
   end;
  end loop;

  -- FASE 2: enviar (a escala e os passos da régua da migration 150: lembrete em +1h e último em +3h)
  -- F5c: rodízio entre as contas (a 1ª de cada conta, depois a 2ª...), com teto por conta
  for a in select f.* from (
             select p.*, row_number() over (partition by e.conta_id order by p.enviada_em nulls first) as ordem_conta
               from vw_acoes_pendentes p join escalas e on e.id = p.escala_id
              where p.acao in ('enviar_primeira','reenviar_falha','reenviar','nao_recebeu')
                -- sem webhook, lembrete e "não recebeu" não ocupam vaga na fila da conta
                and (v_webhook or p.acao not in ('reenviar','nao_recebeu'))) f
            where f.ordem_conta <= v_limite_conta
            order by f.ordem_conta, f.enviada_em nulls first loop
    exit when v_sent >= v_limite;
    if not v_webhook and a.acao in ('reenviar','nao_recebeu') then continue; end if;
    v_tent := coalesce(a.tentativa, 0) + 1;
    v_botoes := v_usar_botoes and a.acao <> 'reenviar_falha';
    begin
      -- F5b: a conta da escala decide o canal (o telefone é único só dentro da conta)
      perform set_config('trilha.conta', (select conta_id from escalas where id = a.escala_id)::text, true);
      v_payload := fn_payload_escala(a.escala_id, a.telefone, coalesce(a.passo, 0) > 0, v_botoes);
      -- conta sem canal de WhatsApp (F5a): falha registrada, em vez de ficar enfileirada sem pedido
      if fn_evo_destino(v_payload ->> 'path', v_payload -> 'body' ->> 'number') is null then
        raise exception 'A conta do técnico não tem canal de WhatsApp ativo.';
      end if;
      v_req := fn_evo_post(v_payload ->> 'path', v_payload -> 'body');
      insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, payload_envio, enviada_em, http_req_id, passo, ciclo)
      values (a.escala_id,
        (case when v_tent = 1 then 'primeira' when a.acao in ('reenviar_falha','nao_recebeu') then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
        v_tent, case when v_botoes then 'botoes_evolution' else 'texto_evolution' end,
        'enfileirada', v_payload, now(), v_req, a.passo, a.ciclo);
    exception
    when unique_violation then
      -- o mesmo passo já saiu: o pedido à Evolution é desfeito junto e nada vira falha (que seria reenviada depois)
      raise warning 'fase 2, escala %: passo % já enviado', a.escala_id, a.passo;
    when others then
      -- registra a falha na propria escala: o motor tenta de novo e, esgotadas as tentativas,
      -- aciona o gestor. As outras escalas seguem normalmente.
      begin
        insert into notificacoes (escala_id, tipo, tentativa, template_nome, status_envio, erro_codigo, erro_mensagem, enviada_em, passo, ciclo)
        values (a.escala_id,
          (case when v_tent = 1 then 'primeira' when a.acao in ('reenviar_falha','nao_recebeu') then 'reenvio_falha' else 'lembrete' end)::notificacao_tipo,
          v_tent, 'erro_interno', 'falha', 'interno', left(sqlerrm, 500), now(), a.passo, a.ciclo);
      exception when others then
        raise warning 'fase 2, escala %: %', a.escala_id, sqlerrm;
      end;
    end;
    v_sent := v_sent + 1;
  end loop;

  -- FASE 3: aviso de escala sem confirmação, no maximo v_limite_sup escalas por execucao (as mais antigas primeiro);
  -- o resto fica para a proxima execucao, porque so a escala avisada ganha supervisor_avisado_em.
  -- Vai ao gestor que criou a escala (migration 150); sem ele, aos supervisores da empresa do técnico (107, 122).
  for a in select * from vw_acoes_pendentes
           where acao = 'escalonar' or (v_webhook and avisar_supervisor)
           order by enviada_em nulls first loop
    exit when v_avisos >= v_limite_sup;
    if exists (select 1 from escalas where id = a.escala_id and supervisor_avisado_em is not null) then continue; end if;
   begin
    v_texto := fn_msg_supervisor(a.escala_id, a.diagnostico, a.tentativa);
    select t.empresa_id, e.conta_id into v_emp, v_conta from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = a.escala_id;
    perform set_config('trilha.conta', v_conta::text, true);
    -- gestor da mesma conta da escala, ativo, com WhatsApp e sem ter desligado os avisos
    select m.telefone_e164 into v_gestor
      from escalas e
      join conta_membros m on m.conta_id = e.conta_id and m.email = lower(btrim(e.criado_por))
     where e.id = a.escala_id and m.ativo and m.papel in ('admin', 'gestor')
       and m.telefone_e164 is not null and m.recebe_avisos;
    if v_gestor is not null then
      perform fn_evo_post_na_conta(v_conta, '/message/sendText/' || v_inst,
                                   jsonb_build_object('number', v_gestor, 'text', v_texto));
      v_destino := 'gestor';
    else
      for s in select telefone_e164 from tecnicos
                where is_supervisor and ativo and (v_emp is null or empresa_id = v_emp) and conta_id = v_conta loop
        perform fn_evo_post('/message/sendText/' || v_inst,
                            jsonb_build_object('number', s.telefone_e164, 'text', v_texto));
      end loop;
      v_destino := 'supervisores';
    end if;
    update escalas set supervisor_avisado_em = now() where id = a.escala_id;
    -- sem telefone nem e-mail no histórico: só para quem foi
    insert into escala_eventos (escala_id, evento, ator, detalhe)
    values (a.escala_id, 'supervisor_acionado', 'dispatcher',
            jsonb_build_object('destino', v_destino, 'diagnostico', a.diagnostico, 'tentativa', a.tentativa));
    -- conta só o aviso que deu certo: escala que falha sempre não ocupa o teto das outras
    v_avisos := v_avisos + 1;
   exception when others then
    raise warning 'fase 3, escala %: %', a.escala_id, sqlerrm;
   end;
  end loop;

  perform set_config('trilha.conta', '', true);

  -- FASE 4: prazo da escala de amanha
  begin perform fn_alerta_prazo_escala();
  exception when others then raise warning 'alerta de prazo falhou: %', sqlerrm; end;

  -- FASE 5: documentos vencidos
  begin perform fn_alerta_certificacoes();
  exception when others then raise warning 'alerta de certificacoes falhou: %', sqlerrm; end;

  -- FASE 6: ligacoes da URA
  begin perform fn_disparar_ligacoes();
  exception when others then raise warning 'ligacoes falharam: %', sqlerrm; end;

  -- FASE 7: escalas encerradas viram concluidas (decisao 30)
  begin perform fn_concluir_escalas();
  exception when others then raise warning 'conclusao automatica falhou: %', sqlerrm; end;

  -- FASE 8: exportações das contas (F8c): retomar o que falhou ou travou e apagar os pacotes vencidos
  begin perform fn_exportacoes_manutencao();
  exception when others then raise warning 'manutencao das exportacoes falhou: %', sqlerrm; end;
  perform set_config('app.ator', 'dispatcher', true);

  -- Execucao concluida: registro lido pelo vigia (fn_vigiar_motor). Se algo acima falhar sem
  -- tratamento, a transacao inteira e desfeita e este registro tambem.
  update motor_estado set ultima_execucao_ok = now(), atualizado_em = now() where id;

  -- Monitor externo: sinal a cada execucao. Sem sinal (motor parado, Supabase fora ou pausado),
  -- o healthchecks.io avisa por e-mail/Telegram. Evolution falhando: sinal de falha (/fail).
  if v_ping is not null then
    begin
      perform net.http_get(v_ping || case when fn_evolution_falhando() then '/fail' else '' end,
                           timeout_milliseconds => 5000);
    exception when others then raise warning 'ping do monitor falhou: %', sqlerrm; end;
  end if;
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
