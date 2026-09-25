-- 02 | Indices, parametros operacionais e funcoes base

create index idx_escalas_data_status  on escalas (data_servico, status);
create index idx_escalas_tecnico_data on escalas (tecnico_id, data_servico);
create index idx_notif_escala         on notificacoes (escala_id);
create index idx_notif_wa             on notificacoes (wa_message_id);
create index idx_respostas_escala     on respostas (escala_id);
create index idx_eventos_escala       on escala_eventos (escala_id, created_at desc);

insert into config (chave, valor, descricao) values
  ('intervalo_reenvio_min',  '30',    'Minutos entre reenvios quando nao ha resposta'),
  ('max_tentativas',         '3',     'Total de envios por escala antes de parar'),
  ('timeout_entrega_min',    '10',    'Minutos em enviada sem entrega = nao recebeu'),
  ('avisar_supervisor_na',   '2',     'Numero da tentativa que aciona o supervisor'),
  ('janela_envio_inicio',    '06:00', 'Nao envia antes deste horario'),
  ('janela_envio_fim',       '21:00', 'Nao envia depois deste horario'),
  ('fuso',                   'America/Bahia', 'Fuso da operacao'),
  ('template_escala',        'escala_diaria',   'Nome do template na Meta'),
  ('template_lembrete',      'escala_lembrete', 'Nome do template de lembrete');

create or replace function fn_config(p_chave text)
returns text language sql stable as $$
  select valor from config where chave = p_chave
$$;

create or replace function fn_config_int(p_chave text)
returns int language sql stable as $$
  select valor::int from config where chave = p_chave
$$;

create or replace function fn_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function fn_log_escala_evento()
returns trigger language plpgsql as $$
declare
  v_ator text := coalesce(current_setting('app.ator', true), 'sistema');
begin
  if tg_op = 'INSERT' then
    insert into escala_eventos (escala_id, evento, status_novo, ator)
    values (new.id, 'criada', new.status, v_ator);
  elsif new.status is distinct from old.status then
    insert into escala_eventos (escala_id, evento, status_anterior, status_novo, ator)
    values (new.id, 'status_alterado', old.status, new.status, v_ator);
  end if;
  return new;
end $$;

create or replace function fn_carimba_confirmacao()
returns trigger language plpgsql as $$
begin
  if new.status in ('confirmada','recusada')
     and old.status not in ('confirmada','recusada') then
    new.confirmada_em := now();
  end if;
  return new;
end $$;
