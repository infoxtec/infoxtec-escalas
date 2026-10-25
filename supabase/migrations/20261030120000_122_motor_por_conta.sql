-- 122: multiempresa F2f-1, motor por conta (docs/multiempresa-f2.md). Os avisos que o motor manda a supervisores
-- (programação de amanhã, documentos a vencer, recusa e ligação sem resposta, comandos do WhatsApp) passam a ir só a
-- supervisores da mesma conta, e os avisos do dia são calculados e registrados por conta. O alerta de segurança do app
-- do ponto (teto por hora) é da plataforma e vai só aos supervisores da conta 1 (operadora). O alerta de motor parado
-- segue para todos (decisão 107: alerta de sistema, sem dado de cliente).
-- Funções recriadas a partir da definição da homologação de 30/10 (md5 do conjunto das quatro: 8c2270d3…).

-- registro de alertas por conta --------------------------------------------------------------------------------------------
-- a chave passa a incluir a conta: o mesmo aviso do dia existe uma vez em cada conta
alter table interno.alertas_enviados drop constraint alertas_enviados_pkey;
alter table interno.alertas_enviados add primary key (conta_id, tipo, data_ref);

-- alerta por funcionário ou por empresa (o identificador vai no tipo ou no detalhe): a conta vem dele
create or replace function interno.fn_alerta_conta()
returns trigger
language plpgsql
set search_path = interno, public, extensions, pg_temp
as $$
declare
  v_id    uuid;
  v_conta uuid;
begin
  v_id := coalesce(nullif(new.detalhe ->> 'tecnico', '')::uuid,
                   (regexp_match(new.tipo, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'))[1]::uuid);
  if v_id is not null then
    select conta_id into v_conta from interno.tecnicos where id = v_id;
    if v_conta is null then
      select conta_id into v_conta from interno.empresas where id = v_id;
    end if;
    if v_conta is not null then new.conta_id := v_conta; end if;
  end if;
  return new;
end $$;

create trigger tg_00_conta before insert on interno.alertas_enviados
  for each row execute function interno.fn_alerta_conta();

-- aviso a supervisores: da empresa informada, ou da do funcionário; sem empresa, só da mesma conta ---------------------
drop function interno.fn_avisar_supervisores(text, uuid, uuid);
create function interno.fn_avisar_supervisores(p_texto text, p_exceto uuid DEFAULT NULL::uuid, p_empresa uuid DEFAULT NULL::uuid,
                                               p_conta uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
  v_n int := 0;
  v_emp uuid := coalesce(p_empresa, (select t.empresa_id from tecnicos t where t.id = p_exceto));
  -- sem conta (alerta de sistema, como o motor parado): todos, como antes (decisão 107)
  v_conta uuid := coalesce(p_conta, (select t.conta_id from tecnicos t where t.id = p_exceto),
                           (select e.conta_id from empresas e where e.id = p_empresa));
begin
  for s in
    select telefone_e164 from tecnicos
    where is_supervisor and ativo and id is distinct from p_exceto
      and (v_emp is null or empresa_id = v_emp)
      and (v_conta is null or conta_id = v_conta)
  loop
    perform fn_wa_texto(s.telefone_e164, p_texto);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- documentos a vencer: uma lista por conta (e por empresa, quando a conta tem mais de uma) -----------------------------
CREATE OR REPLACE FUNCTION interno.fn_alerta_certificacoes()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_agora timestamp := now() at time zone fn_config('fuso');
  v_hoje date := (now() at time zone fn_config('fuso'))::date;
  v_hora time := coalesce(fn_config('alerta_certificacoes_hora')::time, '08:00');
  v_multi boolean;
  v_qtd int;
  c record;
  g record;
begin
  if extract(isodow from v_hoje)::text <> coalesce(fn_config('alerta_certificacoes_dow'), '1') then return; end if;
  if v_agora::time < v_hora or v_agora::time > v_hora + interval '2 hours' then return; end if;

  for c in select x.id from contas x where x.ativa order by x.criada_em loop
    continue when exists (select 1 from alertas_enviados where conta_id = c.id and tipo = 'certificacoes' and data_ref = v_hoje);
    v_multi := (select count(*) from empresas where ativo and conta_id = c.id) > 1;

    select count(*) into v_qtd from vw_tecnico_documentos d join tecnicos t on t.id = d.tecnico_id
     where d.tecnico_ativo and not d.perfil_teste and d.situacao in ('vencido','vencendo','sem_data') and t.conta_id = c.id;

    insert into alertas_enviados (conta_id, tipo, data_ref, enviado, detalhe)
    values (c.id, 'certificacoes', v_hoje, coalesce(v_qtd,0) > 0, jsonb_build_object('qtd', coalesce(v_qtd,0)));
    continue when coalesce(v_qtd,0) = 0;

    for g in
      select case when v_multi then t.empresa_id end as emp,
             string_agg('• ' || d.tecnico || ' — ' || d.documento ||
               case when d.situacao = 'vencido' then ' (VENCIDO em ' || to_char(d.validade,'DD/MM') || ')'
                    when d.situacao = 'sem_data' then ' (sem data cadastrada)'
                    else ' (vence em ' || to_char(d.validade,'DD/MM') || ')' end, E'\n' order by d.validade nulls first) as linhas
        from vw_tecnico_documentos d join tecnicos t on t.id = d.tecnico_id
       where d.tecnico_ativo and not d.perfil_teste and d.situacao in ('vencido','vencendo','sem_data') and t.conta_id = c.id
       group by 1
    loop
      perform fn_avisar_supervisores('📋 *DOCUMENTOS A VENCER*' || E'\n\n' || g.linhas || E'\n\n'
        || 'Técnico com documento vencido não deve ser escalado para atividades que o exigem.', null, g.emp, c.id);
    end loop;
  end loop;
end $function$;

-- programação de amanhã: pendências e aviso por conta ------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION interno.fn_alerta_prazo_escala()
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_agora  timestamp := now() at time zone fn_config('fuso');
  v_amanha date := (now() at time zone fn_config('fuso'))::date + 1;
  v_dias   text[] := array['domingo','segunda','terça','quarta','quinta','sexta','sábado'];
  v_multi  boolean;
  v_p      jsonb;
  v_nomes  text;
  v_qtd    int;
  v_rasc   int;
  v_texto  text;
  v_tipo   text;
  v_hora   time;
  c        record;
  g        record;
begin
  if not (extract(isodow from v_amanha)::text = any (string_to_array(fn_config('alerta_dias_semana'), ','))) then
    return;
  end if;
  -- véspera de feriado: sem cobrança de escala (trabalho em feriado é excepcional)
  if exists (select 1 from feriados f where f.data = v_amanha) then
    return;
  end if;

  foreach v_tipo in array array['aviso', 'prazo'] loop
    v_hora := fn_config(case v_tipo when 'aviso' then 'alerta_escala_aviso' else 'alerta_escala_prazo' end)::time;
    continue when v_agora::time < v_hora;

    for c in select x.id from contas x where x.ativa order by x.criada_em loop
      continue when exists (select 1 from alertas_enviados where conta_id = c.id and tipo = v_tipo and data_ref = v_amanha);

      -- passou da janela (ou o aviso ficou para depois do prazo): registra sem enviar
      if v_agora::time > v_hora + interval '2 hours'
         or (v_tipo = 'aviso' and v_agora::time >= fn_config('alerta_escala_prazo')::time) then
        insert into alertas_enviados (conta_id, tipo, data_ref, enviado) values (c.id, v_tipo, v_amanha, false);
        continue;
      end if;

      v_multi := (select count(*) from empresas where ativo and conta_id = c.id) > 1;
      v_p    := fn_pendencias_escala(v_amanha, c.id);
      v_qtd  := jsonb_array_length(v_p->'sem_escala');
      v_rasc := (v_p->>'rascunhos')::int;
      insert into alertas_enviados (conta_id, tipo, data_ref, enviado, detalhe)
      values (c.id, v_tipo, v_amanha, v_qtd > 0 or v_rasc > 0, v_p);

      continue when v_qtd = 0 and v_rasc = 0;

      for g in
        with sem as (
          select case when v_multi then t.empresa_id end as emp, t.nome, 0 as rasc
            from jsonb_array_elements(v_p->'sem_escala') x join tecnicos t on t.id = (x->>'id')::uuid
        ), rasc as (
          select case when v_multi then t.empresa_id end as emp, null::text as nome, count(*)::int as rasc
            from escalas e join tecnicos t on t.id = e.tecnico_id
           where e.data_servico = v_amanha and e.status = 'rascunho' and not e.teste and e.conta_id = c.id
           group by 1
        )
        select emp, array_agg(nome order by nome) filter (where nome is not null) as nomes, sum(rasc)::int as rasc
          from (select * from sem union all select * from rasc) u
         group by emp
      loop
        v_qtd  := coalesce(array_length(g.nomes, 1), 0);
        v_rasc := coalesce(g.rasc, 0);
        continue when v_qtd = 0 and v_rasc = 0;
        select string_agg('• ' || n, E'\n') into v_nomes from unnest(g.nomes[1:15]) n;
        if v_qtd > 15 then v_nomes := v_nomes || E'\n• e mais ' || (v_qtd - 15); end if;

        v_texto := case v_tipo
          when 'aviso' then '⏰ *PROGRAMAÇÃO DE AMANHÃ — prazo ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '*'
          else '⚠️ *PRAZO DA PROGRAMAÇÃO ENCERRADO*'
        end || E'\n\n'
          || initcap(v_dias[extract(dow from v_amanha)::int + 1]) || ', ' || to_char(v_amanha, 'DD/MM') || E'\n\n'
          || case when v_qtd > 0 then v_qtd || ' técnico(s) sem programação:' || E'\n' || v_nomes || E'\n\n' else '' end
          || case when v_rasc > 0 then v_rasc || ' programação(ões) em rascunho, ainda não enviada(s).' || E'\n\n' else '' end
          || case v_tipo
               when 'aviso' then 'Envie pelo painel até as ' || to_char(fn_config('alerta_escala_prazo')::time, 'HH24"h"') || '.'
               else 'A equipe precisa receber a programação ainda hoje.'
             end;

        perform fn_avisar_supervisores(v_texto, null, g.emp, c.id);
      end loop;
    end loop;
  end loop;
end $function$;

-- teto do app do ponto: alerta de segurança da plataforma, só à operadora (conta 1) --------------------------------------
CREATE OR REPLACE FUNCTION interno.fn_ponto_alerta_teto(p_qual text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  s record;
begin
  insert into alertas_enviados (tipo, data_ref, enviado_em, enviado, detalhe)
  values ('ponto_teto_' || p_qual || '_' || to_char(now() at time zone 'America/Bahia', 'HH24'),
          (now() at time zone 'America/Bahia')::date, now(), true, jsonb_build_object('teto', p_qual))
  on conflict do nothing;
  if not found then return; end if;
  raise warning 'app do ponto: teto de % por hora atingido', p_qual;
  for s in select telefone_e164 from tecnicos where is_supervisor and ativo and opt_in and not perfil_teste
                                               and conta_id = '00000000-0000-0000-0000-000000000001' loop
    begin
      perform fn_evo_post('/message/sendText/' || fn_config('evolution_instancia'),
        jsonb_build_object('number', s.telefone_e164,
          'text', case when p_qual = 'avisos'
            then 'Trilha Ponto: muitos CPFs não encontrados no app do ponto nesta hora (possível tentativa de descobrir '
                 || 'funcionários). O app voltou à resposta única até a próxima hora; o código continua chegando para quem é cadastrado.'
            else 'Trilha Ponto: o limite de ' || case when p_qual = 'erros' then 'tentativas de login'
                  else 'códigos por WhatsApp' end || ' por hora foi atingido (possível ataque). '
                  || 'Enquanto durar, o funcionário entra com o código gerado pelo gestor no painel.' end));
    exception when others then null;
    end;
  end loop;
end $function$;

-- papel na conta para quem chama de fora do PostgREST (Edge Functions): a sessão vem do token já conferido ---------------
create or replace function interno.fn_papel_na_conta_de(p_email text, p_conta_cabecalho text default null)
 returns text
 language plpgsql
 set search_path to 'interno', 'public', 'extensions', 'pg_temp'
as $function$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('email', lower(p_email), 'role', 'authenticated')::text, true);
  perform set_config('request.headers', case when p_conta_cabecalho is null then '{}'
                                             else jsonb_build_object('x-conta', p_conta_cabecalho)::text end, true);
  return fn_papel_na_conta();
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
