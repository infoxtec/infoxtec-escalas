-- 155: reinício do módulo de ponto antes do uso oficial (decisão 138).
--
-- Pedido do responsável (13/11): apagar todos os registros do módulo de ponto de todas as contas da produção, sem
-- cópia, antes do uso oficial em 01/12/2026. Todos eram teste (confirmado pelo responsável; parecer do juridico com as
-- quatro confirmações: nenhum registro de jornada real, nada usado em folha, nenhum atestado real, nenhuma reclamação
-- ou fiscalização). Técnicos, escalas, motivos de ajuste e configurações das empresas ficam.
--
-- Esta migration só CRIA o registro e a função. A execução e a remoção da função vêm na 156, pelo Aplicar aprovado.
-- Travas da função: frase exata, motivo de 20 a 500 caracteres, recusa a partir de 01/12/2026 (ou com qualquer
-- marcação nessa data ou depois), security invoker sem execute para ninguém (só o dono: truncate e alter table).
set lock_timeout = '5s';

-- registro de cada reinício: a âncora da cadeia por empresa antes de apagar (sem horário nem pessoa) e as contagens.
-- É a prova para a conferência do backup (scripts/backup) e diante de fiscalização do NSR recomeçado em 1.
create table if not exists interno.ponto_reinicios (
  id         bigint generated always as identity primary key,
  feito_em   timestamptz not null default now(),
  motivo     text not null check (length(motivo) between 20 and 500),
  feito_por  text not null,
  empresas   jsonb not null default '[]',
  contagens  jsonb not null
);
alter table interno.ponto_reinicios enable row level security;
revoke all on interno.ponto_reinicios from public, anon, authenticated, service_role;
drop trigger if exists trg_ponto_reinicios_imutavel on interno.ponto_reinicios;
create trigger trg_ponto_reinicios_imutavel before update or delete on interno.ponto_reinicios
  for each row execute function interno.fn_ponto_imutavel();
drop trigger if exists trg_ponto_reinicios_sem_truncate on interno.ponto_reinicios;
create trigger trg_ponto_reinicios_sem_truncate before truncate on interno.ponto_reinicios
  for each statement execute function interno.fn_ponto_imutavel();

create or replace function interno.fn_ponto_reiniciar_modulo(p_frase text, p_motivo text)
returns jsonb
language plpgsql
security invoker
set search_path = interno, public, extensions, pg_temp
as $function$
declare
  c_frase  constant text := 'APAGAR TODOS OS REGISTROS DE PONTO DE TODAS AS CONTAS';
  c_limite constant timestamptz := '2026-12-01 00:00:00 America/Sao_Paulo';
  -- tudo o que o uso do ponto gera; ficam ponto_motivos (configuração) e ponto_reinicios (este registro)
  v_tabelas text[] := array['ponto_abonos', 'ponto_acessos', 'ponto_afd_geracoes', 'ponto_ajustes', 'ponto_anexo_acessos',
    'ponto_anexos_descartados', 'ponto_ciencias', 'ponto_codigos', 'ponto_conversas', 'ponto_documento_registros',
    'ponto_documento_sequencia', 'ponto_documento_verificacoes', 'ponto_espelho_acessos', 'ponto_espelho_pdfs',
    'ponto_espelho_sequencia', 'ponto_espelhos', 'ponto_folha_fechamentos', 'ponto_geo', 'ponto_he_autorizacoes',
    'ponto_justificativa_anexos', 'ponto_justificativas', 'ponto_marcacoes', 'ponto_nsr', 'ponto_sessoes'];
  v_lista    text;
  v_rels     regclass[];
  v_tec      bigint;
  v_esc      bigint;
  v_cont     jsonb := '{}';
  v_emp      jsonb;
  v_id       bigint;
  v_n        bigint;
  t          text;
  r          record;
begin
  if p_frase is distinct from c_frase then
    raise exception 'Reinício recusado: frase de confirmação diferente';
  end if;
  if p_motivo is null or length(p_motivo) not between 20 and 500 then
    raise exception 'Reinício recusado: motivo de 20 a 500 caracteres';
  end if;
  if now() >= c_limite then
    raise exception 'Reinício recusado: desde 01/12/2026 o ponto é oficial e não pode ser apagado (Portaria MTP 671/2021)';
  end if;
  if exists (select 1 from ponto_marcacoes where momento >= c_limite) then
    raise exception 'Reinício recusado: há marcação a partir de 01/12/2026 (Portaria MTP 671/2021)';
  end if;

  select string_agg('interno.' || quote_ident(x), ', ' order by x), array_agg(('interno.' || quote_ident(x))::regclass)
    into v_lista, v_rels from unnest(v_tabelas) x;
  perform set_config('lock_timeout', '5s', true);
  -- técnicos e escalas não podem mudar durante a conferência; o ponto fica parado até a confirmação
  lock table interno.tecnicos, interno.escalas in share mode;
  execute 'lock table ' || v_lista || ' in access exclusive mode';
  select count(*) into v_tec from tecnicos;
  select count(*) into v_esc from escalas;

  for t in select x from unnest(v_tabelas) x loop
    execute format('select count(*) from interno.%I', t) into v_n;
    v_cont := v_cont || jsonb_build_object(t, v_n);
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('empresa_id', n.empresa_id, 'ultimo_nsr', n.ultimo, 'ultimo_hash', n.ultimo_hash)
                            order by n.empresa_id), '[]')
    into v_emp from ponto_nsr n;
  insert into ponto_reinicios (motivo, feito_por, empresas, contagens)
  values (p_motivo, current_user || coalesce(' / ' || nullif(current_setting('application_name', true), ''), ''), v_emp, v_cont)
  returning id into v_id;

  -- só os gatilhos de TRUNCATE (bit 32) das tabelas do ponto; os de linha nem disparam no truncate. Tudo dentro desta
  -- transação, com a trava exclusiva: ninguém grava no meio, e qualquer erro desfaz inclusive o desligar
  for r in select tgrelid::regclass as tb, tgname from pg_trigger
            where not tgisinternal and tgrelid = any (v_rels) and (tgtype & 32) <> 0 loop
    execute format('alter table %s disable trigger %I', r.tb, r.tgname);
  end loop;
  -- um truncate só: há ciclos de chave (ajustes, justificativas e abonos); restart identity zera as numerações;
  -- o arquivo físico é trocado, então atestados e PDFs não ficam como linha morta no disco
  execute 'truncate ' || v_lista || ' restart identity restrict';
  for r in select tgrelid::regclass as tb, tgname from pg_trigger
            where not tgisinternal and tgrelid = any (v_rels) and (tgtype & 32) <> 0 loop
    execute format('alter table %s enable trigger %I', r.tb, r.tgname);
  end loop;

  -- conferência: tudo vazio, técnicos e escalas iguais, nenhum gatilho desligado
  for t in select x from unnest(v_tabelas) x loop
    execute format('select count(*) from interno.%I', t) into v_n;
    if v_n <> 0 then raise exception 'Reinício desfeito: % ainda tem linhas', t; end if;
  end loop;
  if (select count(*) from tecnicos) <> v_tec or (select count(*) from escalas) <> v_esc then
    raise exception 'Reinício desfeito: técnicos ou escalas mudaram';
  end if;
  if exists (select 1 from pg_trigger where not tgisinternal and tgrelid = any (v_rels) and tgenabled = 'D') then
    raise exception 'Reinício desfeito: gatilho de proteção desligado';
  end if;
  return jsonb_build_object('reinicio', v_id, 'apagadas', v_cont, 'tecnicos', v_tec, 'escalas', v_esc);
end $function$;

reset lock_timeout;

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
