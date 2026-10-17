-- Migration 107 (17/10/2026): espelho de ponto com todas as exigências do art. 84 da Portaria MTP 671/2021 e PDF
-- assinado guardado no sistema e entregue ao funcionário (pedido do responsável, decisão 104).
--
-- 1. Conteúdo do espelho (Art. 84, conferido no texto compilado de 21/07/2026, docs/legislacao/):
--    I   empregador com CEI/CAEPF/CNO quando houver (coluna nova em empresas) e endereço;
--    IV  horário e jornada contratual: entrada, intervalo, jornada semanal e minutos por dia de cada escala do mês;
--    V   intervalo pré-assinalado (empresa que não exige o registro do intervalo, CLT art. 74, §2º), além das
--        marcações incluídas e desconsideradas que já saíam;
--    VI  duração de cada jornada com a hora noturna reduzida (duracao_min por dia).
--    II e III (nome, CPF, admissão, cargo/função, emissão e período) já estavam. Espelho já emitido não muda
--    (conteúdo congelado): vale para os emitidos a partir desta versão.
-- 2. PDF assinado: depois que o funcionário assina, o banco pede à Edge Function espelho-pdf que monte o PDF do
--    espelho congelado (com a assinatura desenhada, o QR e o selo de validação da empresa: registro, SHA-256 do
--    conteúdo e selo HMAC da assinatura). O PDF volta ao banco, fica guardado em ponto_espelho_pdfs (imutável,
--    com SHA-256), vai ao WhatsApp do funcionário como documento e fica para baixar no app (ponto_meu_espelho_pdf)
--    e no cofre do RH (app_ponto_espelho_pdf, com registro de acesso). A conferência pública mostra o SHA-256 do
--    PDF. A assinatura digital ICP-Brasil da empresa (PAdES, art. 88) entra quando houver o certificado: a
--    função monta o PDF num ponto só, onde a assinatura será aplicada.
-- 3. A Edge Function se autentica com um token do Vault (ESPELHO_PDF_TOKEN), criado sozinho no primeiro pedido e
--    conferido no banco; ela não guarda nada.

-- 1. Empregador: CEI, CAEPF ou CNO --------------------------------------------------------------------------
alter table empresas add column if not exists cei_caepf_cno text;
do $$ begin
  alter table empresas add constraint empresas_cei_caepf_cno_ck check (cei_caepf_cno is null or cei_caepf_cno ~ '^\d{12,14}$');
exception when duplicate_object then null; end $$;
comment on column empresas.cei_caepf_cno is 'CEI, CAEPF ou CNO do empregador, quando houver (Portaria 671, art. 84, I). Só dígitos.';

-- conteúdo do espelho com o art. 84 completo (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.fn_ponto_espelho_conteudo(p_tecnico uuid, p_mes date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_t      record;
  v_fim    date := (p_mes + interval '1 month')::date - 1;
  v_ini    date;
  v_ult    date;
  v_jorn   int := coalesce(nullif(fn_config('jornada_min'), '')::int, 480);
  v_sab    int := coalesce(nullif(fn_config('ponto_jornada_sabado_min'), '')::int, 240);
  v_abona  boolean := coalesce(fn_config('ponto_sabado_sem_expediente_abona'), 'true') = 'true';
  v_tol    int := 10;
  v_dias   jsonb;
  v_aj     jsonb;
  v_res    jsonb;
  v_reg    int;
  v_marca  date;
  v_escalas jsonb;
begin
  select t.nome, t.cpf, t.admissao, t.funcao, t.created_at::date as criado, t.desligado_em,
         e.razao_social, e.cnpj, e.cei_caepf_cno, e.endereco, e.cidade, e.uf,
         coalesce(e.exige_registro_intervalo, false) as exige_intervalo,
         coalesce(e.fuso, 'America/Bahia') as fuso into v_t
    from tecnicos t join empresas e on e.id = t.empresa_id where t.id = p_tecnico;
  -- lista do início do vínculo no mês; cobra jornada só a partir da primeira marcação do funcionário (dia
  -- anterior à implantação do ponto não vira débito; quem nunca marcou não tem débito)
  v_ini := greatest(p_mes, coalesce(v_t.admissao, v_t.criado));
  v_marca := (select min(m.momento at time zone v_t.fuso)::date from ponto_marcacoes m where m.tecnico_id = p_tecnico);
  v_ult := least(v_fim, coalesce(v_t.desligado_em, v_fim));

  with base as (
    select g.d::date as dia, fn_ponto_jornada_dia(p_tecnico, g.d::date) as j,
           fn_carga_dia(p_tecnico, g.d::date) as esc,
           fn_ponto_noturno_dia(p_tecnico, g.d::date, v_t.fuso) as noturno,
           extract(isodow from g.d) = 6 as sabado,
           (select f.nome from feriados f where f.data = g.d::date and f.abrangencia <> 'facultativo' limit 1) as feriado,
           -- atestado de dia inteiro nunca gera débito (o parcial já desconta as horas pelo abono)
           exists (select 1 from ponto_abonos b join ponto_justificativas jj on jj.id = b.justificativa_id
                    where b.tecnico_id = p_tecnico and b.data = g.d::date and jj.motivo = 'atestado' and b.inicio is null
                      and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as atestado_dia,
           -- abono por liberalidade da empresa (lançado pelo gestor sem justificativa do funcionário)
           (select bool_or(b.inicio is null) or coalesce(sum(extract(epoch from b.fim - b.inicio) / 60), 0) > 0
              from ponto_abonos b where b.tecnico_id = p_tecnico and b.data = g.d::date and b.justificativa_id is null
               and b.folga_de is null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as ab_livre,
           -- folga compensatória (decisão 84): o dia de folga e o domingo ou feriado que ela compensa
           (select min(to_char(b.folga_de, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.data = g.d::date and b.folga_de is not null
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as folga_de,
           -- só compensa a folga que já aconteceu sem trabalho; folga futura na emissão mantém o 100% (a favor do
           -- funcionário: o gestor reemite depois)
           (select min(to_char(b.data, 'DD/MM')) from ponto_abonos b
             where b.tecnico_id = p_tecnico and b.folga_de = g.d::date
               and b.data <= (now() at time zone v_t.fuso)::date
               and coalesce((fn_ponto_jornada_dia(p_tecnico, b.data) ->> 'trabalhado_min')::int, 0) = 0
               and b.estorno_de is null and not exists (select 1 from ponto_abonos x where x.estorno_de = b.id)) as compensado_em
      from generate_series(v_ini, v_ult, interval '1 day') g(d)
     where v_ini <= v_ult
  ), calc0 as (
    -- jornada do dia pela escala (decisão 91): DSR e feriado trabalhados a 100%; outra folga da escala, 50%;
    -- 12x36 tem DSR e feriados compensados (CLT art. 59-A, parágrafo único). Sem escala, a regra de antes
    -- (8 h de segunda a sexta, 4 h no sábado, domingo de repouso)
    select b.*, (b.esc->>'minutos')::int as contr,
           b.esc->>'tipo' = '12x36' as plantonista,
           case when b.esc->>'tipo' = '12x36' then false
                else coalesce((b.esc->>'repouso')::boolean, false) or b.feriado is not null end as repouso_pago
      from base b
  ), calc as (
    select b.*,
           coalesce((b.j->>'trabalhado_min')::int, 0) as trab,
           coalesce((b.j->>'abonado_min')::int, 0) as abon,
           (b.j->>'intervalo_min')::int as intervalo,
           -- hora noturna reduzida: 52'30" valem 60 min de jornada
           round(b.noturno * 60 / 52.5)::int as noturno_red,
           -- domingo ou feriado compensado com folga é trabalho comum: só o que passa da jornada é extra
           case when b.repouso_pago and b.compensado_em is null then 0 when b.repouso_pago then coalesce(nullif(b.contr, 0), v_jorn)
                else b.contr end as bruto
      from calc0 b
  ), dia as (
    select c.*,
           c.trab + (c.noturno_red - c.noturno) as trab_ef,
           case when c.dia < coalesce(v_marca, v_ult + 1) or c.repouso_pago or c.feriado is not null then 0
                when c.sabado and c.contr > 0 and c.j is null and v_abona then 0 else c.bruto end as esperado,
           (c.sabado and not c.repouso_pago and c.contr > 0 and c.j is null and v_abona and c.dia >= coalesce(v_marca, v_ult + 1)) as sabado_abonado
      from calc c
  ), conta as (
    select d.*,
           case when d.repouso_pago and d.compensado_em is null then d.trab_ef else 0 end as he100,
           case when (not d.repouso_pago or d.compensado_em is not null) and d.trab_ef - d.bruto > v_tol
                then d.trab_ef - d.bruto else 0 end as he50,
           case when greatest(d.esperado - d.abon - d.trab_ef, 0) > v_tol and not d.atestado_dia
                then greatest(d.esperado - d.abon - d.trab_ef, 0) else 0 end as debito,
           case when d.trab > 360 then greatest(60 - coalesce(d.intervalo, 0), 0)
                when d.trab > 240 then greatest(15 - coalesce(d.intervalo, 0), 0) else 0 end as int_suprimido
      from dia d
  )
  select
    coalesce(jsonb_agg(jsonb_build_object('data', to_char(c.dia, 'YYYY-MM-DD')) || coalesce(c.j, '{}'::jsonb)
           || jsonb_build_object('previsto_min', c.esperado, 'he50_min', c.he50, 'he100_min', c.he100,
                                 'noturno_min', c.noturno, 'debito_min', c.debito, 'feriado', c.feriado,
                                 'folga_de', c.folga_de, 'compensado_em', c.compensado_em,
                                 'jornada_dia_min', c.contr, 'escala', c.esc->>'escala',
                                 -- duração da jornada com a hora noturna reduzida (Art. 84, VI)
                                 'duracao_min', c.trab_ef,
                                 'repouso', case when c.plantonista then null when c.feriado is not null then 'feriado'
                                                 when (c.esc->>'repouso')::boolean then 'dsr' when c.contr = 0 then 'folga' end)
           order by c.dia) filter (where c.j is not null or c.esperado > 0 or c.feriado is not null), '[]'::jsonb),
    jsonb_build_object(
      'a_pagar', jsonb_build_object(
        'he50_min', coalesce(sum(c.he50), 0), 'he100_min', coalesce(sum(c.he100), 0),
        'noturno_reduzidas_min', coalesce(sum(c.noturno_red), 0),
        'intervalo_nao_concedido_min', coalesce(sum(c.int_suprimido), 0)),
      'a_descontar', jsonb_build_object(
        'debito_min', coalesce(sum(c.debito), 0),
        'dias_sem_registro', count(*) filter (where c.debito > 0 and coalesce((c.j->>'marcacoes')::int, 0) = 0),
        'semanas_com_falta', count(distinct date_trunc('week', c.dia))
                               filter (where c.debito > 0 and coalesce((c.j->>'marcacoes')::int, 0) = 0)),
      'informativo', jsonb_build_object(
        'previsto_min', coalesce(sum(c.esperado), 0), 'trabalhado_min', coalesce(sum(c.trab), 0),
        'noturno_relogio_min', coalesce(sum(c.noturno), 0),
        'abonado_justificado_min', coalesce(sum(c.abon) filter (where c.ab_livre is not true and c.folga_de is null), 0),
        'abonado_empresa_min', coalesce(sum(c.abon) filter (where c.ab_livre and c.folga_de is null), 0),
        'sabados_sem_expediente', count(*) filter (where c.sabado_abonado),
        'dias_abonados_justificados', count(*) filter (where c.abon > 0 and c.ab_livre is not true and c.folga_de is null),
        'folgas_compensatorias', count(*) filter (where c.folga_de is not null),
        'domingos_feriados_compensados', count(*) filter (where c.compensado_em is not null and c.trab > 0),
        'dias_trabalhados', count(*) filter (where c.trab > 0),
        'dias_he_acima_2h', count(*) filter (where c.he50 > 120),
        'interjornada_curta', count(*) filter (where c.j->'alertas' ? 'interjornada_curta'),
        'registros', count(*) filter (where c.j is not null),
        'feriados', coalesce(jsonb_agg(distinct to_char(c.dia, 'DD/MM') || ' ' || c.feriado) filter (where c.feriado is not null), '[]'::jsonb)))
    into v_dias, v_res
    from conta c;

  -- escalas que valeram no mês, com o horário e a jornada contratual (Art. 84, IV)
  select coalesce(jsonb_agg(jsonb_build_object('escala', x.escala, 'de', to_char(x.de, 'DD/MM'), 'ate', to_char(x.ate, 'DD/MM'),
                                               'tipo', x.tipo, 'entrada', to_char(x.entrada, 'HH24:MI'),
                                               'intervalo_min', x.intervalo_min, 'semanal_min', x.semanal_min,
                                               'plantao_min', x.plantao_min, 'minutos', x.minutos) order by x.de), '[]'::jsonb)
    into v_escalas
    from (select y.escala, y.tipo, y.entrada, y.intervalo_min, y.semanal_min, y.plantao_min, y.minutos,
                 min(y.d) as de, max(y.d) as ate
            from (select g.d::date as d, ch.nome as escala, ch.tipo, ch.entrada, ch.intervalo_min, ch.semanal_min,
                         ch.plantao_min, to_jsonb(ch.minutos) as minutos
                    from generate_series(v_ini, v_ult, interval '1 day') g(d)
                    join carga_atribuicoes a on a.id = fn_carga_atribuicao(p_tecnico, g.d::date)
                    join cargas_horarias ch on ch.id = a.carga_id
                   where v_ini <= v_ult) y
           group by y.escala, y.tipo, y.entrada, y.intervalo_min, y.semanal_min, y.plantao_min, y.minutos) x;

  -- mês sem nenhum dia com registro, escala ou abono: não há espelho a emitir (o emissor pula)
  v_reg := (v_res->'informativo'->>'registros')::int;
  if v_reg = 0 then v_dias := '[]'::jsonb; end if;

  -- marcações tratadas (Art. 84, V): incluídas e desconsideradas, com o motivo; sem o e-mail de quem tratou
  select coalesce(jsonb_agg(jsonb_build_object(
           'acao', a.acao, 'data', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'YYYY-MM-DD'),
           'hora', to_char(coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso, 'HH24:MI'),
           'tipo', coalesce(a.tipo, x.tipo, y.tipo), 'motivo', a.motivo)
           order by coalesce(a.momento, x.momento, y.momento), a.created_at), '[]'::jsonb) into v_aj
    from ponto_ajustes a
    left join ponto_marcacoes x on x.id = a.marcacao_id
    left join ponto_ajustes y on y.id = a.ajuste_id
   where a.tecnico_id = p_tecnico
     and (coalesce(a.momento, x.momento, y.momento) at time zone v_t.fuso)::date between p_mes and v_fim;
  if v_reg = 0 then v_aj := '[]'::jsonb; end if;

  return jsonb_build_object(
    'documento', 'Espelho de Ponto Eletrônico (Portaria MTP 671/2021, art. 84)',
    'empregador', jsonb_build_object('razao_social', v_t.razao_social, 'cnpj', v_t.cnpj,
                                     'cei_caepf_cno', v_t.cei_caepf_cno,
                                     'endereco', concat_ws(' - ', v_t.endereco, concat_ws('/', v_t.cidade, v_t.uf))),
    'trabalhador', jsonb_build_object('nome', v_t.nome, 'cpf', v_t.cpf, 'admissao', v_t.admissao, 'funcao', v_t.funcao),
    'competencia', to_char(p_mes, 'MM/YYYY'), 'de', p_mes, 'ate', v_fim,
    -- pré-assinalação do intervalo (CLT art. 74, §2º; Art. 84, V): empresa que não exige o registro
    'jornada', jsonb_build_object('dia_util_min', v_jorn, 'sabado_min', v_sab, 'escalas', v_escalas,
                                  'pre_assinalado', not v_t.exige_intervalo,
                                  'intervalo_min', coalesce(nullif(fn_config('intervalo_min'), '')::int, 60)),
    'dias', v_dias, 'ajustes', v_aj,
    'totais', jsonb_build_object(
                 'trabalhado_min', v_res->'informativo'->'trabalhado_min',
                 'he_min', (v_res->'a_pagar'->>'he50_min')::int + (v_res->'a_pagar'->>'he100_min')::int,
                 'faltas', (select count(*) from jsonb_array_elements(v_dias) x where x->'alertas' ? 'falta'),
                 'atrasos', (select count(*) from jsonb_array_elements(v_dias) x where x->'alertas' ? 'atraso'),
                 'dias_abonados', (select count(*) from jsonb_array_elements(v_dias) x where x->>'abono' is not null)),
    'resumo', v_res,
    'avisos', jsonb_build_array(
      'Resumo para conferência das horas do mês. Os valores em reais são calculados pela folha de pagamento.',
      'Percentuais mínimos da CLT e da Constituição: hora extra 50% (inclusive em folga da escala que não é o descanso semanal), descanso semanal (o domingo ou o dia da sua escala) e feriado trabalhados em dobro (100%) quando não há folga compensatória (na 12x36, descanso e feriados já são compensados pela própria escala), adicional noturno 20% sobre a hora reduzida. A convenção coletiva da sua categoria pode prever percentuais ou regras diferentes.',
      'Não há banco de horas: horas extras são pagas e horas em débito são descontadas separadamente; uma não compensa a outra.',
      'Faltas sem justificativa podem levar ao desconto do descanso semanal remunerado daquela semana (Lei 605/1949, art. 6º).',
      'Dias e horas abonados não são descontados.' || case when v_abona then ' Sábados sem expediente são abonados por decisão da empresa.' else '' end,
      'Feriados considerados: os do calendário cadastrado pela empresa.',
      'Sua assinatura registra que você recebeu e conferiu este espelho (ciência). Se algum horário estiver errado, peça a correção pelo app antes de assinar.',
      'Marcações registradas são as do relógio do ponto; marcações tratadas (incluídas, desconsideradas ou pré-assinaladas) aparecem separadas, com o motivo.'));
end $function$

;

-- cadastro da empresa com o CEI/CAEPF/CNO (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.app_salvar_empresa(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_cnpj  text := regexp_replace(coalesce(p->>'cnpj', ''), '\D', '', 'g');
  v_logo  text := nullif(trim(p->>'logo'), '');
  v_exige boolean := (p->>'exige_registro_intervalo')::boolean;
  -- CEI, CAEPF ou CNO (Art. 84, I, "se houver"): só dígitos, 12 a 14
  v_cei   text := nullif(regexp_replace(coalesce(p->>'cei_caepf_cno', ''), '\D', '', 'g'), '');
  v_antes boolean;
begin
  if not fn_cnpj_valido(v_cnpj) then raise exception 'CNPJ inválido.'; end if;
  if coalesce(trim(p->>'razao_social'), '') = '' then raise exception 'Razão social é obrigatória.'; end if;
  if v_logo is not null and v_logo !~ '^[a-z0-9-]{1,40}$' then raise exception 'Logotipo inválido.'; end if;
  if v_cei is not null and v_cei !~ '^\d{12,14}$' then raise exception 'CEI, CAEPF ou CNO inválido: informe de 12 a 14 dígitos.'; end if;
  if v_id is not null then
    select exige_registro_intervalo into v_antes from empresas where id = v_id;
  end if;
  if v_exige is not null and v_exige is distinct from coalesce(v_antes, false) then
    begin
      perform fn_exigir_papel(v_email, array['admin']);
    exception when others then
      raise exception 'Só o administrador muda a exigência do registro do intervalo.';
    end;
  end if;

  if v_id is null then
    insert into empresas (cnpj, razao_social, nome_fantasia, endereco, cidade, uf, empregadora, ativo, logo,
                          exige_registro_intervalo, cei_caepf_cno)
    values (v_cnpj, trim(p->>'razao_social'), nullif(trim(p->>'nome_fantasia'), ''),
            nullif(trim(p->>'endereco'), ''), coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
            upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
            coalesce((p->>'empregadora')::boolean, false), coalesce((p->>'ativo')::boolean, true), v_logo,
            coalesce(v_exige, false), v_cei)
    returning id into v_id;
  else
    update empresas set
      cnpj = v_cnpj, razao_social = trim(p->>'razao_social'),
      nome_fantasia = nullif(trim(p->>'nome_fantasia'), ''), endereco = nullif(trim(p->>'endereco'), ''),
      cidade = coalesce(nullif(trim(p->>'cidade'), ''), 'Salvador'),
      uf = upper(coalesce(nullif(trim(p->>'uf'), ''), 'BA')),
      empregadora = coalesce((p->>'empregadora')::boolean, false),
      ativo = coalesce((p->>'ativo')::boolean, true),
      -- painel antigo não manda o logotipo nem a exigência: fica o que estava
      logo = case when p ? 'logo' then v_logo else logo end,
      exige_registro_intervalo = coalesce(v_exige, exige_registro_intervalo),
      cei_caepf_cno = case when p ? 'cei_caepf_cno' then v_cei else cei_caepf_cno end
    where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'Já existe uma empresa com este CNPJ.';
end $function$

;

-- 2. PDF assinado do espelho ----------------------------------------------------------------------------------
create table if not exists ponto_espelho_pdfs (
  espelho_id  uuid primary key references ponto_espelhos(id),
  empresa_id  uuid not null references empresas(id),
  pdf         bytea check (pdf is null or (octet_length(pdf) between 1000 and 5242880 and substr(pdf, 1, 5) = '\x255044462d'::bytea)),
  sha256      text,
  gerado_em   timestamptz,
  pedido_em   timestamptz,
  pedidos     int not null default 0,
  enviado_em  timestamptz,
  envio_req   bigint
);
alter table ponto_espelho_pdfs enable row level security;
comment on table ponto_espelho_pdfs is 'PDF do espelho assinado (migration 107): gerado pela Edge Function espelho-pdf, imutável depois de gravado, guarda de 5 anos como o resto do ponto.';

-- o PDF gravado não muda nem some (como a folha assinada)
create or replace function fn_ponto_espelho_pdf_imutavel()
returns trigger language plpgsql set search_path = public, extensions as $function$
begin
  if tg_op = 'DELETE' then raise exception 'O PDF do espelho assinado não pode ser apagado.'; end if;
  if old.pdf is not null and (new.pdf is distinct from old.pdf or new.sha256 is distinct from old.sha256
                              or new.gerado_em is distinct from old.gerado_em or new.espelho_id <> old.espelho_id
                              or new.empresa_id <> old.empresa_id) then
    raise exception 'O PDF do espelho assinado não pode ser alterado.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $function$;
drop trigger if exists trg_ponto_espelho_pdf_imutavel on ponto_espelho_pdfs;
create trigger trg_ponto_espelho_pdf_imutavel before update or delete on ponto_espelho_pdfs
  for each row execute function fn_ponto_espelho_pdf_imutavel();

-- abertura do PDF assinado pelo RH também fica registrada
alter table ponto_espelho_acessos drop constraint if exists ponto_espelho_acessos_acao_check;
alter table ponto_espelho_acessos add constraint ponto_espelho_acessos_acao_check check (acao in ('ver', 'prova', 'pdf'));

-- endereço da Edge Function, do mesmo projeto da URA (produção e homologação têm o seu)
insert into config (chave, valor, descricao)
select 'espelho_pdf_url', replace(c.valor, '/voz-escala', '/espelho-pdf'),
       'Endereço da Edge Function que monta o PDF do espelho assinado (migration 107). Vazio desliga o PDF.'
  from config c where c.chave = 'voz_url' and c.valor like '%/voz-escala%'
on conflict (chave) do nothing;

-- o Vault passa a aceitar também o token da Edge Function do PDF (parte da definição atual da homologação)
create or replace function fn_segredo_gravar(p_nome text, p_valor text)
returns void language plpgsql set search_path = public, extensions as $$
declare v_id uuid;
begin
  if p_nome not in ('WEBHOOK_TOKEN', 'WEBHOOK_TOKEN_ANTERIOR', 'ESPELHO_PDF_TOKEN') then raise exception 'segredo não permitido'; end if;
  select id into v_id from vault.secrets where name = p_nome;
  if v_id is null then
    perform vault.create_secret(p_valor, p_nome);
  else
    perform vault.update_secret(v_id, p_valor);
  end if;
end $$;

-- o token só é conferido aqui: a Edge Function manda, o banco compara com o Vault
create or replace function fn_ponto_espelho_pdf_token_ok(p_token text)
returns boolean language plpgsql stable set search_path = public, extensions as $function$
declare v text := fn_segredo('ESPELHO_PDF_TOKEN');
begin
  return v is not null and coalesce(p_token, '') <> ''
         and extensions.digest(p_token, 'sha256') = extensions.digest(v, 'sha256');
end $function$;

-- pede o PDF de um espelho assinado; no máximo um pedido por minuto por espelho
create or replace function fn_ponto_espelho_pdf_pedir(p_id uuid)
returns bigint language plpgsql set search_path = public, extensions as $function$
declare
  v_url text := nullif(trim(coalesce(fn_config('espelho_pdf_url'), '')), '');
  v_tok text;
  v_e   record;
  v_f   record;
begin
  select e.id, e.empresa_id, e.assinado_em, e.substituido_em into v_e from ponto_espelhos e where e.id = p_id;
  if not found or v_e.assinado_em is null or v_e.substituido_em is not null then return null; end if;
  select * into v_f from ponto_espelho_pdfs where espelho_id = p_id for update;
  if found and (v_f.pdf is not null or v_f.pedido_em > now() - interval '1 minute') then return null; end if;
  insert into ponto_espelho_pdfs (espelho_id, empresa_id, pedido_em, pedidos) values (p_id, v_e.empresa_id, now(), 1)
  on conflict (espelho_id) do update set pedido_em = now(), pedidos = ponto_espelho_pdfs.pedidos + 1;
  if v_url is null then return null; end if;
  v_tok := fn_segredo('ESPELHO_PDF_TOKEN');
  if v_tok is null then
    v_tok := encode(extensions.gen_random_bytes(32), 'hex');
    perform fn_segredo_gravar('ESPELHO_PDF_TOKEN', v_tok);
  end if;
  return net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-espelho-token', v_tok),
    body := jsonb_build_object('id', p_id),
    timeout_milliseconds := 30000);
end $function$;

-- o que a Edge Function precisa para montar o PDF (só espelho assinado e vigente)
create or replace function fn_ponto_espelho_pdf_dados(p_token text, p_id uuid)
returns jsonb language plpgsql stable set search_path = public, extensions as $function$
declare v jsonb;
begin
  if not fn_ponto_espelho_pdf_token_ok(p_token) then raise exception 'token inválido'; end if;
  select jsonb_build_object(
           'id', e.id, 'registro', e.registro, 'versao', e.versao, 'codigo', e.codigo, 'sha256', e.sha256,
           'emitido_em', to_char(e.emitido_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
           'assinado_em', to_char(e.assinado_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
           'assinatura_png', e.assinatura_png, 'assinatura_sha256', e.assinatura_sha256,
           'conteudo', e.conteudo,
           'url_verificacao', rtrim(coalesce(nullif(fn_config('app_url'), ''), ''), '/') || '/v?c=' || e.codigo,
           'ja_gerado', exists (select 1 from ponto_espelho_pdfs f where f.espelho_id = e.id and f.pdf is not null))
    into v
    from ponto_espelhos e
   where e.id = p_id and e.assinado_em is not null and e.substituido_em is null;
  return v;
end $function$;

-- grava o PDF montado e o entrega ao funcionário pelo WhatsApp, como documento
create or replace function fn_ponto_espelho_pdf_gravar(p_token text, p_id uuid, p_pdf bytea)
returns jsonb language plpgsql set search_path = public, extensions as $function$
declare
  v_e   record;
  v_sha text;
  v_req bigint;
  v_env boolean := false;
begin
  if not fn_ponto_espelho_pdf_token_ok(p_token) then raise exception 'token inválido'; end if;
  if p_pdf is null or octet_length(p_pdf) < 1000 or octet_length(p_pdf) > 5242880
     or substr(p_pdf, 1, 5) <> '\x255044462d'::bytea then
    raise exception 'Arquivo inválido: não é um PDF.';
  end if;
  select e.id, e.empresa_id, e.competencia, e.registro, e.assinado_em, e.substituido_em,
         t.nome, t.telefone_e164, t.ativo, t.opt_in
    into v_e from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id where e.id = p_id;
  if not found or v_e.assinado_em is null or v_e.substituido_em is not null then
    raise exception 'Espelho não assinado ou substituído.';
  end if;
  v_sha := encode(sha256(p_pdf), 'hex');
  insert into ponto_espelho_pdfs (espelho_id, empresa_id) values (p_id, v_e.empresa_id) on conflict (espelho_id) do nothing;
  update ponto_espelho_pdfs set pdf = p_pdf, sha256 = v_sha, gerado_em = now()
   where espelho_id = p_id and pdf is null;
  if not found then return jsonb_build_object('gravado', false, 'motivo', 'ja_gerado'); end if;

  if v_e.ativo and v_e.opt_in and v_e.telefone_e164 is not null and fn_pode_enviar(v_e.telefone_e164) then
    begin
      v_req := fn_evo_post('/message/sendMedia/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', v_e.telefone_e164, 'mediatype', 'document', 'mimetype', 'application/pdf',
          'fileName', 'espelho-de-ponto-' || to_char(v_e.competencia, 'MM-YYYY') || '-registro-' || v_e.registro || '.pdf',
          'caption', 'Trilha Ponto: ' || split_part(trim(v_e.nome), ' ', 1) || ', aqui está a sua cópia do espelho de ponto de '
                     || to_char(v_e.competencia, 'MM/YYYY') || ', assinado por você e validado pela empresa. Guarde este arquivo.',
          'media', encode(p_pdf, 'base64')));
      if v_req is not null then
        update ponto_espelho_pdfs set enviado_em = now(), envio_req = v_req where espelho_id = p_id;
        v_env := true;
      end if;
    exception when others then
      raise warning 'espelho-pdf: envio pelo WhatsApp falhou (%)', sqlerrm;
    end;
  end if;
  return jsonb_build_object('gravado', true, 'sha256', v_sha, 'enviado', v_env);
end $function$;

-- cópia do funcionário no app (só a dele, só assinada); sem PDF ainda, pede de novo
create or replace function ponto_meu_espelho_pdf(p_token text, p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_tec uuid := fn_ponto_sessao(p_token);
  v_e   record;
  v_f   record;
begin
  select e.id, e.competencia, e.registro, e.assinado_em, e.substituido_em into v_e
    from ponto_espelhos e where e.id = p_id and e.tecnico_id = v_tec;
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_e.assinado_em is null then raise exception 'O PDF assinado sai depois que você assina o espelho.'; end if;
  select pdf, sha256 into v_f from ponto_espelho_pdfs where espelho_id = p_id and pdf is not null;
  if not found then
    perform fn_ponto_espelho_pdf_pedir(p_id);
    return jsonb_build_object('pronto', false);
  end if;
  return jsonb_build_object('pronto', true, 'pdf', encode(v_f.pdf, 'base64'), 'sha256', v_f.sha256,
           'nome', 'espelho-de-ponto-' || to_char(v_e.competencia, 'MM-YYYY') || '-registro-' || v_e.registro || '.pdf');
end $function$;

-- cópia no cofre do RH (folha assinada: só com a permissão, e a abertura fica registrada)
create or replace function app_ponto_espelho_pdf(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public, extensions as $function$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_e     record;
  v_f     record;
begin
  if not fn_rh_folhas(v_email) then raise exception 'Só quem tem a permissão do cofre de folhas assinadas (RH) baixa o PDF.'; end if;
  select e.id, e.competencia, e.registro, e.assinado_em, t.nome into v_e
    from ponto_espelhos e join tecnicos t on t.id = e.tecnico_id where e.id = p_id;
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
end $function$;

-- assinatura pede o PDF (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.ponto_assinar_espelho(p_token text, p_id uuid, p_sha256 text, p_assinatura text, p_ciente boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_tec    uuid := fn_ponto_sessao(p_token);
  v_e      record;
  v_agora  timestamptz;
  v_origem jsonb;
begin
  if p_ciente is not true then raise exception 'Confirme que conferiu o espelho antes de assinar.'; end if;
  if p_assinatura is null or length(p_assinatura) > 300000 then raise exception 'Assinatura inválida ou grande demais: desenhe de novo.'; end if;
  -- data URL de PNG, e os bytes começam com a assinatura de arquivo PNG
  if p_assinatura !~ '^data:image/png;base64,[A-Za-z0-9+/=]+$'
     or substr(decode(split_part(p_assinatura, ',', 2), 'base64'), 1, 8) <> '\x89504e470d0a1a0a'::bytea then
    raise exception 'Assinatura inválida: desenhe de novo.';
  end if;
  select e.id, e.sha256, e.substituido_em, e.assinado_em into v_e from ponto_espelhos e
   where e.id = p_id and e.tecnico_id = v_tec for update;
  if not found then raise exception 'Espelho não encontrado.'; end if;
  if v_e.assinado_em is not null then raise exception 'Este espelho já foi assinado.'; end if;
  if v_e.substituido_em is not null or v_e.sha256 is distinct from p_sha256 then
    raise exception 'O espelho mudou depois que você abriu: abra de novo e confira antes de assinar.';
  end if;
  v_agora := now();
  v_origem := jsonb_build_object('ip', fn_ponto_ip(),
                'aparelho', left(coalesce(current_setting('request.headers', true)::jsonb ->> 'user-agent', ''), 300));
  update ponto_espelhos
     set assinado_em = v_agora, assinatura_png = p_assinatura, assinatura_origem = v_origem,
         assinatura_sha256 = fn_ponto_assinatura_hash(v_e.sha256, p_assinatura, v_agora, v_origem),
         assinatura_chave = fn_ponto_assinatura_chave()
   where id = p_id;
  -- PDF assinado: pedido à Edge Function espelho-pdf (assíncrono, sai depois do commit); falha não desfaz a assinatura
  begin
    perform fn_ponto_espelho_pdf_pedir(p_id);
  exception when others then
    raise warning 'espelho-pdf: pedido não enviado (%)', sqlerrm;
  end;
  return jsonb_build_object('assinado_em', to_char(v_agora at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
                            'pdf', 'gerando');
end $function$

;

-- conferência pública com o SHA-256 do PDF (parte da definição atual da homologação)
CREATE OR REPLACE FUNCTION public.ponto_verificar_espelho(p_codigo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v record;
begin
  select e.registro, e.versao, e.competencia, e.emitido_em, e.substituido_em, e.assinado_em, e.sha256,
         e.assinatura_png, e.assinatura_sha256, e.assinatura_origem, e.assinatura_chave,
         encode(sha256(convert_to(e.conteudo_texto, 'UTF8')), 'hex') as sha_atual, m.razao_social, m.cnpj,
         f.sha256 as pdf_sha256, f.gerado_em as pdf_gerado_em
    into v
    from ponto_espelhos e join empresas m on m.id = e.empresa_id
    left join ponto_espelho_pdfs f on f.espelho_id = e.id and f.pdf is not null
   where e.codigo = upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z2-7]', '', 'g'));
  if not found then return jsonb_build_object('encontrado', false); end if;
  return jsonb_build_object(
    'encontrado', true, 'registro', v.registro, 'versao', v.versao,
    'empresa', v.razao_social, 'cnpj', v.cnpj, 'competencia', to_char(v.competencia, 'MM/YYYY'),
    'emitido_em', to_char(v.emitido_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'substituido', v.substituido_em is not null,
    'integro', v.sha_atual = v.sha256,
    'assinado_em', to_char(v.assinado_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    -- nulo quando a chave que assinou não está neste banco (restauração sem a chave): não é adulteração
    'assinatura_integra', case when v.assinado_em is null or v.assinatura_chave is distinct from fn_ponto_assinatura_chave() then null
                               else fn_ponto_assinatura_hash(v.sha256, v.assinatura_png, v.assinado_em, v.assinatura_origem)
                                    = v.assinatura_sha256 end,
    'assinatura_chave_indisponivel', v.assinado_em is not null and v.assinatura_chave is distinct from fn_ponto_assinatura_chave(),
    'sha256', v.sha256,
    -- PDF assinado entregue ao funcionário (migration 107): só o hash, para conferir o arquivo
    'pdf_sha256', v.pdf_sha256,
    'pdf_gerado_em', to_char(v.pdf_gerado_em at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'));
end $function$

;

-- permissões (decisão 12): as fn_ do PDF ficam sem execute para os papéis da API; a Edge Function entra como postgres
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
