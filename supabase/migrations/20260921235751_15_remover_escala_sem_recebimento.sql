-- 15 | Remocao definitiva de escala que o tecnico ainda nao recebeu + coluna pode_remover no painel

create or replace function fn_remover_escala(p_ator text, p_escala_id text)
returns jsonb
language plpgsql volatile
set search_path = public, extensions as $$
declare
  v_id    uuid := p_escala_id::uuid;
  v_ator  text := coalesce(nullif(p_ator, ''), 'painel');
  v_esc   record;
  v_saiu  boolean;
  v_aviso boolean := false;
begin
  perform fn_exigir_papel(p_ator, array['admin', 'gestor']);

  select e.id, e.status, e.data_servico, e.hora_inicio,
         t.telefone_e164, t.ativo, t.opt_in,
         coalesce(l.nome, 'local a confirmar') as local_nome
    into v_esc
  from escalas e
  join tecnicos t on t.id = e.tecnico_id
  left join locais l on l.id = e.local_id
  where e.id = v_id;

  if not found then
    raise exception 'Escala não encontrada.';
  end if;

  if v_esc.status in ('confirmada', 'recusada', 'em_execucao', 'concluida')
     or exists (select 1 from respostas where escala_id = v_id) then
    raise exception 'O técnico já respondeu esta escala. Use Cancelar para manter o histórico.';
  end if;

  if exists (select 1 from notificacoes
             where escala_id = v_id
               and (status_envio in ('entregue', 'lida') or entregue_em is not null)) then
    raise exception 'O técnico já recebeu esta escala no WhatsApp. Use Cancelar para manter o histórico.';
  end if;

  v_saiu := exists (select 1 from notificacoes
                    where escala_id = v_id and status_envio in ('enfileirada', 'enviada'));

  if v_saiu and v_esc.ativo then
    perform fn_wa_texto(v_esc.telefone_e164,
      '❌ A escala de ' || to_char(v_esc.data_servico, 'DD/MM') || ' às '
      || to_char(v_esc.hora_inicio, 'HH24:MI') || ' — ' || v_esc.local_nome
      || ' foi *cancelada*. Desconsidere a mensagem anterior.');
    v_aviso := true;
  end if;

  perform set_config('app.ator', v_ator, false);
  delete from escalas where id = v_id;

  insert into log_exclusoes (entidade, entidade_id, ator, escalas_removidas)
  values ('escala', v_id, v_ator, 1);

  return jsonb_build_object('removida', true, 'aviso_enviado', v_aviso);
end $$;

revoke execute on function fn_remover_escala(text, text) from public, anon, authenticated;

create or replace view vw_escalas_painel as
select
  e.id, e.data_servico, e.hora_inicio,
  t.nome as tecnico, t.telefone_e164 as telefone,
  coalesce(l.nome, '-') as local, coalesce(l.endereco, '') as endereco, l.link_maps,
  e.descricao_tarefa, e.status, e.prioridade,
  n.tipo as ultimo_envio_tipo, n.tentativa, n.status_envio, n.enviada_em, n.entregue_em, n.lida_em,
  r.tipo as resposta, r.recebida_em as respondida_em,
  e.supervisor_avisado_em,
  case
    when e.status in ('confirmada','concluida','em_execucao') then 'verde'
    when e.status in ('recusada','cancelada')                 then 'vermelho'
    when e.supervisor_avisado_em is not null                  then 'vermelho'
    when e.status = 'notificada'                              then 'ambar'
    else 'cinza'
  end as semaforo,
  (e.status not in ('confirmada','recusada','em_execucao','concluida')
   and r.tipo is null
   and not exists (select 1 from notificacoes x
                   where x.escala_id = e.id
                     and (x.status_envio in ('entregue','lida') or x.entregue_em is not null))
  ) as pode_remover
from escalas e
join tecnicos t on t.id = e.tecnico_id
left join locais l on l.id = e.local_id
left join lateral (
  select * from notificacoes where escala_id = e.id order by created_at desc limit 1
) n on true
left join lateral (
  select * from respostas where escala_id = e.id order by recebida_em desc limit 1
) r on true;

revoke all on vw_escalas_painel from anon, authenticated;
