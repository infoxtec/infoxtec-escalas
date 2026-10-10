-- Migration 64 (10/10/2026): ligações da URA só em dia útil, das 08:00 às 20:00, nunca em sábado,
-- domingo ou feriado (pedido do responsável ao ativar o disparo automático; decisão 54).
--
-- Antes, a janela olhava só a hora (ligacao_janela_inicio/fim): ligaria num sábado ou num feriado.
-- Agora uma regra única, fn_ligacao_permitida(), vale para o disparo automático (vw_ligacoes_pendentes)
-- e para o botão "Ligar agora" (fn_preparar_ligacao, chamada por app_ligar_escala).
--
-- Feriados: tabela própria, preenchida de 2026 a 2030 com os nacionais, o 2 de Julho (Bahia), os
-- municipais de Salvador (24/06 e 08/12) e os móveis calculados pela Páscoa (Sexta-feira Santa,
-- Carnaval segunda e terça, Corpus Christi). Carnaval e Corpus Christi são ponto facultativo, mas não
-- se liga para técnico nesses dias. A tabela é editável (incluir um feriado novo é um insert).
-- O disparo automático (config ligacao_ativa) não é ligado aqui: é ligado na produção pelo responsável.

create table if not exists feriados (
  data        date primary key,
  nome        text not null,
  abrangencia text not null check (abrangencia in ('nacional', 'estadual', 'municipal', 'facultativo'))
);
revoke all on feriados from anon, authenticated, service_role;
comment on table feriados is 'Dias sem ligação da URA (e base para outras regras de dia útil). Nacionais, Bahia, Salvador e pontos facultativos de Carnaval e Corpus Christi.';
alter table feriados enable row level security;

-- Domingo de Páscoa (algoritmo gregoriano anônimo, Meeus/Jones/Butcher)
create or replace function fn_pascoa(p_ano int)
returns date language plpgsql immutable set search_path = public, extensions as $$
declare a int; b int; c int; d int; e int; f int; g int; h int; i int; k int; l int; m int; mes int; dia int;
begin
  a := p_ano % 19; b := p_ano / 100; c := p_ano % 100; d := b / 4; e := b % 4;
  f := (b + 8) / 25; g := (b - f + 1) / 3; h := (19 * a + b - d - g + 15) % 30;
  i := c / 4; k := c % 4; l := (32 + 2 * e + 2 * i - h - k) % 7; m := (a + 11 * h + 22 * l) / 451;
  mes := (h + l - 7 * m + 114) / 31; dia := ((h + l - 7 * m + 114) % 31) + 1;
  return make_date(p_ano, mes, dia);
end $$;

insert into feriados (data, nome, abrangencia)
select make_date(a.ano, f.mes, f.dia), f.nome, f.abrangencia
  from generate_series(2026, 2030) a(ano)
 cross join (values
   (1, 1, 'Confraternização Universal', 'nacional'),
   (4, 21, 'Tiradentes', 'nacional'),
   (5, 1, 'Dia do Trabalho', 'nacional'),
   (6, 24, 'São João', 'municipal'),
   (7, 2, 'Independência da Bahia', 'estadual'),
   (9, 7, 'Independência do Brasil', 'nacional'),
   (10, 12, 'Nossa Senhora Aparecida', 'nacional'),
   (11, 2, 'Finados', 'nacional'),
   (11, 15, 'Proclamação da República', 'nacional'),
   (11, 20, 'Dia Nacional de Zumbi e da Consciência Negra', 'nacional'),
   (12, 8, 'Nossa Senhora da Conceição da Praia', 'municipal'),
   (12, 25, 'Natal', 'nacional')) f(mes, dia, nome, abrangencia)
union all
select fn_pascoa(a.ano) + m.desloc, m.nome, m.abrangencia
  from generate_series(2026, 2030) a(ano)
 cross join (values
   (-48, 'Carnaval (segunda)', 'facultativo'),
   (-47, 'Carnaval (terça)', 'facultativo'),
   (-2, 'Sexta-feira Santa', 'nacional'),
   (60, 'Corpus Christi', 'facultativo')) m(desloc, nome, abrangencia)
on conflict (data) do nothing;

-- A regra: dia útil (segunda a sexta), fora de feriado, dentro da janela de horário (config).
create or replace function fn_ligacao_permitida(p_momento timestamptz default now())
returns boolean language sql stable set search_path = public, extensions as $$
  select extract(isodow from l.ts) between 1 and 5
     and not exists (select 1 from feriados f where f.data = l.ts::date)
     and l.ts::time >= fn_config('ligacao_janela_inicio')::time
     and l.ts::time <= fn_config('ligacao_janela_fim')::time
    from (select p_momento at time zone coalesce(nullif(fn_config('fuso'), ''), 'America/Bahia') as ts) l
$$;

-- Fila do disparo automático: a janela de hora vira a regra completa (mesmas colunas de antes)
create or replace view vw_ligacoes_pendentes as
 WITH agora AS (
         SELECT (now() AT TIME ZONE COALESCE(NULLIF(fn_config('fuso'::text), ''), 'America/Bahia')) AS local_ts
        )
 SELECT e.id AS escala_id,
    t.id AS tecnico_id,
    t.nome AS tecnico,
    t.telefone_e164 AS telefone,
    COALESCE(n.tentativa, 0) AS tentativas_whatsapp,
    ( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id) AS ligacoes_feitas
   FROM escalas e
     JOIN tecnicos t ON t.id = e.tecnico_id AND t.ativo AND t.opt_in AND NOT t.perfil_teste
     LEFT JOIN LATERAL ( SELECT notificacoes.id,
            notificacoes.escala_id,
            notificacoes.tipo,
            notificacoes.tentativa,
            notificacoes.wa_message_id,
            notificacoes.template_nome,
            notificacoes.status_envio,
            notificacoes.erro_codigo,
            notificacoes.erro_mensagem,
            notificacoes.payload_envio,
            notificacoes.enviada_em,
            notificacoes.entregue_em,
            notificacoes.lida_em,
            notificacoes.created_at,
            notificacoes.http_req_id
           FROM notificacoes
          WHERE notificacoes.escala_id = e.id
          ORDER BY notificacoes.created_at DESC
         LIMIT 1) n ON true
     CROSS JOIN agora g
  WHERE e.status = 'notificada'::escala_status AND e.local_id IS NOT NULL AND (e.data_servico + e.hora_inicio) > g.local_ts AND COALESCE(n.tentativa, 0) >= fn_config_int('ligacao_apos_tentativas'::text) AND (n.status_envio = ANY (ARRAY['enviada'::envio_status, 'entregue'::envio_status, 'lida'::envio_status])) AND NOT (EXISTS ( SELECT 1
           FROM respostas r
          WHERE r.escala_id = e.id)) AND (( SELECT count(*) AS count
           FROM ligacoes l
          WHERE l.escala_id = e.id)) < fn_config_int('ligacao_max_por_escala'::text) AND NOT (EXISTS ( SELECT 1
           FROM ligacoes l
          WHERE l.escala_id = e.id AND ((l.status = ANY (ARRAY['criada'::text, 'discando'::text])) OR l.criada_em > (now() - make_interval(mins => fn_config_int('ligacao_intervalo_min'::text)))))) AND COALESCE(fn_ligacao_permitida(), false);
revoke all on vw_ligacoes_pendentes from anon, authenticated, service_role;

-- "Ligar agora" e disparo automático passam pela mesma trava
create or replace function fn_preparar_ligacao(p_escala uuid)
 returns jsonb
 language plpgsql
 set search_path to 'public', 'extensions'
as $function$
declare
  v_esc record; v_id uuid; v_tent int; v_caller text := fn_config('twilio_caller_id');
begin
  if coalesce(v_caller, '') = '' then
    raise exception 'Configure twilio_caller_id com o número verificado na Twilio.';
  end if;
  if not coalesce(fn_ligacao_permitida(), false) then   -- config faltando nunca libera
    raise exception 'Ligações só em dias úteis, das % às %, fora de sábado, domingo e feriado.',
      fn_config('ligacao_janela_inicio'), fn_config('ligacao_janela_fim');
  end if;
  select e.id, e.tecnico_id, t.nome, t.telefone_e164, t.ativo, t.opt_in, e.status, e.local_id into v_esc
  from escalas e join tecnicos t on t.id = e.tecnico_id where e.id = p_escala;
  if not found then raise exception 'Escala não encontrada.'; end if;
  if not v_esc.ativo or not v_esc.opt_in then raise exception 'Técnico inativo ou sem autorização de contato.'; end if;
  if v_esc.status not in ('agendada','notificada') then raise exception 'A escala já foi respondida (%).', v_esc.status; end if;
  if v_esc.local_id is null then
    raise exception 'Escala sem local não é enviada nem ligada. Escolha o local.';
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
