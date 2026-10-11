-- Migration 71 (12/10/2026): registro do documento, QR de verificação e timbre no cofre — decisão 62.
--
-- Cada documento que entra no cofre ganha um número de registro sequencial por empresa (sem lacuna:
-- o contador anda na mesma transação do documento), a data e hora do recebimento e um código de
-- verificação aleatório. O painel desenha o timbre e o QR por cima da imagem, só na tela; o arquivo
-- original no cofre não muda, e é ele que o SHA-256 prova. O QR leva ao painel (exige login) e confere
-- o registro e a integridade: prova que o sistema recebeu aquele arquivo naquela hora, sem alteração.
-- Não prova que o médico emitiu o atestado.

-- Registro: só inclusão; sobrevive ao descarte do documento (sem FK, como ponto_anexo_acessos) -------------
create table if not exists ponto_documento_registros (
  anexo_id         uuid primary key,
  justificativa_id uuid not null,
  empresa_id       uuid not null references empresas(id),
  registro         bigint not null,
  codigo           text not null unique check (codigo ~ '^[A-Z2-7]{16}$'),
  sha256           text not null,
  recebido_em      timestamptz not null,
  canal            text not null,
  unique (empresa_id, registro)
);
comment on table ponto_documento_registros is 'Registro sequencial por empresa de cada documento do cofre, com código de verificação do QR (decisão 62). Só inclusão.';
alter table ponto_documento_registros enable row level security;
create or replace trigger trg_ponto_doc_registros_imutavel before update or delete on ponto_documento_registros
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_doc_registros_sem_truncate before truncate on ponto_documento_registros
  for each statement execute function fn_ponto_imutavel();

create table if not exists ponto_documento_sequencia (
  empresa_id uuid primary key references empresas(id),
  ultimo     bigint not null
);
alter table ponto_documento_sequencia enable row level security;

-- O contador só anda de um em um: a promessa de "sem lacuna" não depende de ninguém mexer nele
create or replace function fn_ponto_doc_sequencia_guarda()
returns trigger language plpgsql set search_path = public, extensions as $$
begin
  if tg_op <> 'UPDATE' or new.empresa_id <> old.empresa_id or new.ultimo <> old.ultimo + 1 then
    raise exception 'O contador de registro de documentos só avança de um em um.';
  end if;
  return new;
end $$;
create or replace trigger trg_ponto_doc_sequencia_guarda before update or delete on ponto_documento_sequencia
  for each row execute function fn_ponto_doc_sequencia_guarda();
create or replace trigger trg_ponto_doc_sequencia_sem_truncate before truncate on ponto_documento_sequencia
  for each statement execute function fn_ponto_imutavel();

create table if not exists ponto_documento_verificacoes (
  id       bigint generated always as identity primary key,
  codigo   text not null,
  email    text not null,
  achou    boolean not null,
  integro  boolean,
  em       timestamptz not null default now()
);
comment on table ponto_documento_verificacoes is 'Quem conferiu um QR de documento e o resultado (decisão 62). Só inclusão.';
alter table ponto_documento_verificacoes enable row level security;
create index if not exists ponto_documento_verificacoes_email_idx on ponto_documento_verificacoes (email, em);
create or replace trigger trg_ponto_doc_verificacoes_imutavel before update or delete on ponto_documento_verificacoes
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_doc_verificacoes_sem_truncate before truncate on ponto_documento_verificacoes
  for each statement execute function fn_ponto_imutavel();

-- Código de 16 letras e dígitos (base32, 80 bits): não dá para adivinhar nem percorrer ---------------
create or replace function fn_ponto_codigo_verificacao()
returns text language plpgsql volatile set search_path = public, extensions as $$
declare b bytea := extensions.gen_random_bytes(10); v text := ''; i int; acc bigint := 0; nb int := 0;
  alfa text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
begin
  for i in 0..9 loop
    acc := (acc << 8) | get_byte(b, i); nb := nb + 8;
    while nb >= 5 loop
      v := v || substr(alfa, ((acc >> (nb - 5)) & 31)::int + 1, 1); nb := nb - 5;
    end loop;
    acc := acc & ((1::bigint << nb) - 1);
  end loop;
  return v;
end $$;

-- Ao entrar no cofre: próximo número da empresa, na mesma transação (rollback não deixa lacuna) --------
create or replace function fn_ponto_documento_registrar()
returns trigger language plpgsql set search_path = public, extensions as $$
declare v_emp uuid; v_canal text; v_num bigint;
begin
  select j.empresa_id, j.canal into v_emp, v_canal from ponto_justificativas j where j.id = new.justificativa_id;
  insert into ponto_documento_sequencia (empresa_id, ultimo) values (v_emp, 1)
  on conflict (empresa_id) do update set ultimo = ponto_documento_sequencia.ultimo + 1
  returning ultimo into v_num;
  insert into ponto_documento_registros (anexo_id, justificativa_id, empresa_id, registro, codigo, sha256, recebido_em, canal)
  values (new.id, new.justificativa_id, v_emp, v_num, fn_ponto_codigo_verificacao(), new.sha256, new.created_at, v_canal);
  return new;
end $$;

create or replace trigger trg_ponto_documento_registrar after insert on ponto_justificativa_anexos
  for each row execute function fn_ponto_documento_registrar();

-- Documentos que já estão no cofre: numerados pela ordem de chegada ------------------------------------
do $$
declare a record; v_num bigint;
begin
  for a in select x.id, x.justificativa_id, x.sha256, x.created_at, j.empresa_id, j.canal
             from ponto_justificativa_anexos x join ponto_justificativas j on j.id = x.justificativa_id
            where not exists (select 1 from ponto_documento_registros r where r.anexo_id = x.id)
            order by x.created_at, x.id loop
    insert into ponto_documento_sequencia (empresa_id, ultimo) values (a.empresa_id, 1)
    on conflict (empresa_id) do update set ultimo = ponto_documento_sequencia.ultimo + 1
    returning ultimo into v_num;
    insert into ponto_documento_registros (anexo_id, justificativa_id, empresa_id, registro, codigo, sha256, recebido_em, canal)
    values (a.id, a.justificativa_id, a.empresa_id, v_num, fn_ponto_codigo_verificacao(), a.sha256, a.created_at, a.canal);
  end loop;
end $$;

-- Visualização no cofre: agora com os dados do timbre e a integridade conferida a cada abertura -------
create or replace function app_ponto_anexo_ver(p_anexo uuid)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email text := app_exigir(array['admin','gestor']);
  a       record;
  v_bin   bytea;
begin
  if not fn_ve_saude(v_email) then raise exception 'Só quem tem permissão de ver atestados e documentos vê os documentos.'; end if;
  select x.id, x.justificativa_id, x.tipo, x.conteudo, x.sha256, r.registro, r.codigo, r.recebido_em, r.canal,
         j.numero, coalesce(e.nome_fantasia, e.razao_social) as empresa, coalesce(e.fuso, 'America/Bahia') as fuso
    into a
    from ponto_justificativa_anexos x
    join ponto_justificativas j on j.id = x.justificativa_id
    join empresas e on e.id = j.empresa_id
    left join ponto_documento_registros r on r.anexo_id = x.id
   where x.id = p_anexo;
  if not found then raise exception 'Documento não encontrado.'; end if;
  insert into ponto_anexo_acessos (anexo_id, justificativa_id, sha256, email) values (a.id, a.justificativa_id, a.sha256, v_email);
  v_bin := fn_ponto_cofre_decifrar(a.conteudo);
  return jsonb_build_object('tipo', a.tipo, 'conteudo', encode(v_bin, 'base64'),
    'visto_por', v_email, 'em', to_char(now() at time zone 'America/Bahia', 'DD/MM/YYYY HH24:MI'),
    'registro', lpad(a.registro::text, 6, '0'), 'codigo', a.codigo, 'empresa', a.empresa, 'pedido', a.numero,
    'recebido_em', to_char(a.recebido_em at time zone a.fuso, 'DD/MM/YYYY HH24:MI:SS'),
    'canal', case a.canal when 'whatsapp' then 'WhatsApp' else 'App' end,
    'sha256', a.sha256, 'integro', encode(extensions.digest(v_bin, 'sha256'), 'hex') = a.sha256);
end $$;

-- Conferência do QR: registro, quando chegou e se o arquivo guardado continua íntegro. Não mostra o
-- documento; o motivo de saúde só para quem vê atestados (decisão 39). Admin e gestor (minimização: o QR
-- lido quase sempre vem de uma foto da tela). Até 20 conferências por minuto por usuário ----------------
create or replace function app_ponto_verificar_documento(p_codigo text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_email  text := app_exigir(array['admin','gestor']);
  v_cod    text;
  r        record;
  v_bin    bytea;
  v_integro boolean;
  v_desc_em timestamptz;
begin
  if length(coalesce(p_codigo, '')) > 64 then raise exception 'Código inválido.'; end if;
  if (select count(*) from ponto_documento_verificacoes where email = v_email and em > now() - interval '1 minute') >= 20 then
    raise exception 'Muitas conferências seguidas. Aguarde um minuto.';
  end if;
  v_cod := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z2-7]', '', 'g'));
  select d.*, j.numero, j.status, j.data, j.data_fim, j.decidido_por, j.decidido_em, t.nome as tecnico,
         coalesce(e.nome_fantasia, e.razao_social) as empresa, coalesce(e.fuso, 'America/Bahia') as fuso,
         case when m.saude and not fn_ve_saude(v_email) then 'Justificativa de saúde' else m.nome end as motivo
    into r
    from ponto_documento_registros d
    join ponto_justificativas j on j.id = d.justificativa_id
    join tecnicos t on t.id = j.tecnico_id
    join empresas e on e.id = d.empresa_id
    join ponto_motivos m on m.codigo = j.motivo
   where d.codigo = v_cod;
  if not found then
    insert into ponto_documento_verificacoes (codigo, email, achou) values (left(v_cod, 16), v_email, false);
    return jsonb_build_object('encontrado', false);
  end if;
  select x.conteudo into v_bin from ponto_justificativa_anexos x where x.id = r.anexo_id;
  if found then
    v_integro := encode(extensions.digest(fn_ponto_cofre_decifrar(v_bin), 'sha256'), 'hex') = r.sha256;
  else
    select pd.em into v_desc_em from ponto_anexos_descartados pd where pd.anexo_id = r.anexo_id order by pd.id desc limit 1;
  end if;
  insert into ponto_documento_verificacoes (codigo, email, achou, integro) values (v_cod, v_email, true, v_integro);
  return jsonb_build_object('encontrado', true,
    'registro', lpad(r.registro::text, 6, '0'), 'empresa', r.empresa, 'pedido', r.numero, 'tecnico', r.tecnico,
    'motivo', r.motivo, 'periodo', to_char(r.data, 'DD/MM/YYYY') || case when r.data_fim > r.data then ' a ' || to_char(r.data_fim, 'DD/MM/YYYY') else '' end,
    'recebido_em', to_char(r.recebido_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI:SS'),
    'canal', case r.canal when 'whatsapp' then 'WhatsApp' else 'App' end,
    'status', r.status, 'decidido_por', r.decidido_por,
    'decidido_em', to_char(r.decidido_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI'),
    'sha256', r.sha256, 'integro', v_integro,
    'descartado', v_desc_em is not null,
    'descartado_em', to_char(v_desc_em at time zone r.fuso, 'DD/MM/YYYY HH24:MI'));
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
