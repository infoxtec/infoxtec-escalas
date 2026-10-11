-- Migration 74 (12/10/2026): alta antecipada registrada pelo gestor no painel — decisão 64 (opção A).
--
-- O funcionário afastado (decisão 60) volta antes da validade com a liberação médica em mãos, falando com
-- o gestor (migration 73). O gestor com "vê atestados e documentos" registra a alta no painel: o documento
-- vai para o cofre (mesmo núcleo do app e do WhatsApp, canal "painel") e o pedido de alta já nasce
-- aprovado por ele. O caminho do próprio funcionário (app e WhatsApp) continua existindo. Revisão: quando
-- vier o parecer do especialista de RH (opção B, o funcionário envia e o gestor aprova).

alter table ponto_justificativas drop constraint ponto_justificativas_canal_check;
alter table ponto_justificativas add constraint ponto_justificativas_canal_check check (canal in ('app', 'whatsapp', 'painel'));

-- Afastados hoje: só "afastado até", nunca o motivo; admin e gestor ---------------------------------------
create or replace function app_ponto_afastados()
returns table (tecnico_id uuid, tecnico text, afastado_ate date, pode_registrar_alta boolean)
language plpgsql stable security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  v_saude boolean := fn_ve_saude(v_email);
begin
  return query
    select x.id, x.nome, x.ate, v_saude
      from (select t.id, t.nome,
                   fn_ponto_afastado_ate(t.id, (now() at time zone coalesce(e.fuso, 'America/Bahia'))::date) as ate
              from tecnicos t join empresas e on e.id = t.empresa_id
             where t.ativo) x
     where x.ate is not null
     order by x.ate, x.nome;
end $$;

-- Alta pelo gestor: documento obrigatório no cofre; pedido de alta aprovado na hora (sem abono) ------------
create or replace function app_ponto_registrar_alta(p_tecnico uuid, p_data date, p_anexo text, p_anexo_tipo text,
  p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  r       jsonb;
  v_id    uuid;
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos registra a alta.'; end if;
  if p_data is null or fn_ponto_afastado_ate(p_tecnico, p_data) is null then
    raise exception 'O funcionário não está afastado nesse dia.';
  end if;
  if p_anexo is null then raise exception 'Anexe a liberação médica (foto ou PDF).'; end if;
  r := fn_ponto_falta_criar(p_tecnico, 'alta_medica', p_data, null, null, null, p_observacao, p_anexo, p_anexo_tipo, 'painel');
  select j.id into v_id from ponto_justificativas j where j.numero = (r->>'numero')::bigint;
  perform app_ponto_decidir(v_id, true, 'Alta registrada pelo gestor com a liberação médica.');
  return jsonb_build_object('numero', r->'numero', 'data', r->'data',
    'afastado_ate', to_char(fn_ponto_afastado_ate(p_tecnico, p_data), 'DD/MM/YYYY'));
end $$;

-- WhatsApp: a confirmação do atestado orienta a falar com o gestor (base: migration 70 com a revisão) -------
create or replace function fn_ponto_midia_receber(p_tecnico uuid, p_midia_id text, p_base64 text, p_mime text)
returns jsonb language plpgsql volatile set search_path = public, extensions as $$
declare
  c      record;
  d      jsonb;
  r      jsonb;
  v_n    int;
begin
  select pc.dados, t.telefone_e164 as tel into c
    from ponto_conversas pc join tecnicos t on t.id = pc.tecnico_id
   where pc.tecnico_id = p_tecnico and pc.etapa = 'aj_documento' and pc.expira_em > now()
     and pc.dados->>'midia_id' = p_midia_id
     for update of pc;
  if not found then return jsonb_build_object('ignorado', 'ponto: conversa do documento não está mais aberta'); end if;
  d := c.dados;
  begin
    r := fn_ponto_falta_criar(p_tecnico, d->>'motivo', (d->>'data')::date, (d->>'data_fim')::date,
                              (d->>'hora_ini')::time, (d->>'hora_fim')::time, null,
                              p_base64, lower(trim(split_part(coalesce(p_mime, ''), ';', 1))), 'whatsapp');
  exception when others then
    if sqlstate = 'P0001' and (sqlerrm like 'Arquivo%' or sqlerrm like 'O documento%' or sqlerrm like 'Falta o documento%') then
      update ponto_conversas set dados = dados - 'midia_id' - 'midia_em' where tecnico_id = p_tecnico;
      perform fn_ponto_wa(c.tel, sqlerrm || ' Mande outro arquivo ou responda *0* para cancelar.');
      return jsonb_build_object('acao', 'ponto_documento_recusado', 'motivo', 'conteudo');
    end if;
    update ponto_conversas set expira_em = now() where tecnico_id = p_tecnico;
    perform fn_ponto_wa(c.tel, case when sqlstate = 'P0001' then 'Não foi possível registrar o pedido: ' || sqlerrm
                                    else 'Não foi possível registrar o pedido agora. Tente de novo ou fale com o gestor.' end);
    return jsonb_build_object('acao', 'ajuste_erro', 'erro', sqlerrm);
  end;
  if d->>'motivo' = 'atestado' then
    v_n := fn_ponto_avisar_afastamento(p_tecnico, (d->>'data')::date, (d->>'data_fim')::date, r->>'numero');
  end if;
  update ponto_conversas set expira_em = now(), dados = dados - 'midia_id' - 'midia_em' where tecnico_id = p_tecnico;
  -- motivo de saúde não vai por escrito no WhatsApp: só "Saúde"
  perform fn_ponto_wa(c.tel, '✅ *Pedido ' || (r->>'numero') || ' recebido*' || E'\n'
    || case when d->>'grupo' = 'saude' then 'Saúde' else r->>'motivo' end || ' · ' || (r->>'data') || ' · ' || (r->>'detalhe') || E'\n'
    || 'O documento está no cofre. O gestor vai analisar; a resposta chega aqui e na aba Ajuste do app.'
    || case when r->>'alerta' is not null then E'\n' || 'Esse pedido passa do limite da lei: o gestor decide se abona.' else '' end
    || case when d->>'motivo' = 'atestado' then E'\n\n' || 'Até ' || to_char((d->>'data_fim')::date, 'DD/MM')
         || ' vale o afastamento: o ponto e as escalas ficam bloqueados. Liberado antes? Tenha a liberação médica em mãos e fale com o seu gestor.'
         else '' end);
  return jsonb_build_object('acao', 'ajuste_registrado', 'numero', r->'numero', 'escalas_no_periodo', coalesce(v_n, 0));
end $$;

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
