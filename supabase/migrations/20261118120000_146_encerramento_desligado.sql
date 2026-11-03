-- Encerramento de conta desligado (D6, reunião de 03/11, decisão 131; auditoria de 01/11, itens 5 e 14). A F8b prometia
-- ao cliente a exclusão dos dados 30 dias depois do encerramento, e a exclusão (F8d) não existe. Até ela existir,
-- app_plataforma_encerrar_conta recusa; para parar um cliente, a plataforma desliga "Ativa" (suspensão, migration 142).
-- Reabrir continua valendo para as contas já encerradas. O interruptor é a config encerramento_ativo, que a F8d liga.

set lock_timeout = '5s';

insert into interno.config (chave, valor, descricao)
values ('encerramento_ativo', 'false', 'Encerramento de conta ligado (só com a exclusão da F8d pronta; decisão 131)')
on conflict (chave) do nothing;

CREATE OR REPLACE FUNCTION public.app_plataforma_encerrar_conta(p_conta uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'interno', 'public', 'extensions', 'pg_temp'
AS $function$
declare
  v_ator   text := interno.fn_exigir_plataforma();
  v_motivo text := btrim(coalesce(p_motivo, ''));
  c        interno.contas;
  v_sess   int;
begin
  -- desligado até a exclusão (F8d) existir: a conta encerrada prometia exclusão em 30 dias que ninguém fazia (decisão 131)
  if coalesce(interno.fn_config('encerramento_ativo'), 'false') <> 'true' then
    raise exception 'O encerramento de conta está desligado até a exclusão automática existir. Para parar um cliente, desligue "Ativa" na tela Contas.';
  end if;
  if p_conta = '00000000-0000-0000-0000-000000000001' then
    raise exception 'A conta da operadora não pode ser encerrada.';
  end if;
  if length(v_motivo) not between 3 and 300 then
    raise exception 'Informe o motivo do encerramento (3 a 300 caracteres).';
  end if;
  select * into c from interno.contas where id = p_conta for update;
  if not found then raise exception 'Conta não encontrada.'; end if;
  if c.estado <> 'ativa' then raise exception 'A conta já está encerrada.'; end if;
  update interno.contas set ativa = false, estado = 'encerrada', encerrada_em = now(), apagar_em = now() + interval '30 days'
   where id = p_conta returning * into c;
  -- app do ponto: sessões encerradas e códigos vencidos já agora
  update interno.ponto_sessoes s set encerrada_em = now(), motivo = 'conta encerrada'
    from interno.tecnicos t where t.id = s.tecnico_id and t.conta_id = p_conta and s.encerrada_em is null;
  get diagnostics v_sess = row_count;
  update interno.ponto_codigos k set expira_em = now()
    from interno.tecnicos t where t.id = k.tecnico_id and t.conta_id = p_conta and k.usado_em is null and k.expira_em > now();
  insert into interno.plataforma_log (autor, acao, conta_alvo, detalhe)
  values (v_ator, 'encerrar_conta', p_conta, jsonb_build_object('motivo', v_motivo, 'apagar_em', c.apagar_em, 'sessoes_ponto', v_sess));
  -- exportação final automática (F8c, decisão 129): o link vai por e-mail aos administradores da conta
  -- a final vai por e-mail a todos os administradores: só o pacote comum
  perform interno.fn_exportar_pedir(p_conta, v_ator, 'encerramento', false, false);
  return jsonb_build_object('estado', c.estado, 'apagar_em', c.apagar_em);
end $function$
;

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
