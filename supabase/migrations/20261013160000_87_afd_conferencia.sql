-- Migration 87 (13/10/2026): Arquivo Fonte de Dados (AFD) do REP-P, versão de conferência (backlog 085, decisão 81).
-- Leiaute: Anexo V da Portaria MTP 671/2021 (docs/AFD.pdf). A Portaria 1.486/2022 revogou o anexo e passou o
-- leiaute para o portal gov.br; a versão de lá saiu deste texto, mas a conferência contra ela é da contadora
-- (backlog 077) antes de o arquivo valer. Por isso: sem a linha de assinatura do anexo antigo (a assinatura
-- agora é CAdES em .p7s destacado, Art. 88 §2º, e espera o e-CNPJ e o parecer — backlog 076 e 078) e com o
-- número do INPI zerado enquanto o programa não for registrado.
--
-- O que entra: cabeçalho (tipo 1), marcações do REP-P (tipo 7) e trailer (tipo 9). Inclusão de empresa e de
-- empregado (tipos 2 e 5) e eventos sensíveis (tipo 6) pedem que esses eventos passem a usar a mesma sequência
-- de NSR das marcações: fica para a entrega 2. Ajustes do gestor não entram no AFD (vão no AEJ, Art. 82).

insert into config (chave, valor, descricao) values
  ('rep_p_inpi', '', 'Número de registro do programa no INPI (17 dígitos). Vazio: AFD sai como versão de conferência'),
  ('rep_p_desenvolvedor_cnpj', '', 'CNPJ do desenvolvedor do REP-P no cabeçalho do AFD. Vazio: usa o CNPJ do próprio empregador'),
  ('afd_leiaute_conferido', 'false',
   'true só depois da conferência da contadora contra o leiaute do gov.br e da assinatura CAdES (decisão do responsável). Enquanto false, o AFD sai com _CONFERENCIA no nome')
on conflict (chave) do nothing;

create table if not exists ponto_afd_geracoes (
  id         bigint generated always as identity primary key,
  email      text not null,
  empresa_id uuid not null references empresas(id),
  de         date not null,
  ate        date not null,
  registros  int not null,
  sha256     text not null,
  gerado_em  timestamptz not null default now()
);
comment on table ponto_afd_geracoes is 'Quem gerou o AFD de qual empresa e período, com o sha256 do arquivo (backlog 085, decisão 81). Só inclusão.';
alter table ponto_afd_geracoes enable row level security;
create or replace trigger trg_ponto_afd_geracoes_imutavel before update or delete on ponto_afd_geracoes
  for each row execute function fn_ponto_imutavel();
create or replace trigger trg_ponto_afd_geracoes_sem_truncate before truncate on ponto_afd_geracoes
  for each statement execute function fn_ponto_imutavel();

-- CRC-16 do registro (itens 17 do anexo): CRC-16/KERMIT (polinômio 0x1021 refletido, início 0), 4 dígitos
-- hexadecimais maiúsculos. O anexo não nomeia a variante: conferir com o leiaute do gov.br.
create or replace function fn_afd_crc16(p bytea)
returns text language plpgsql immutable set search_path = public, extensions as $function$
declare
  v_crc int := 0;
  i int; j int;
begin
  for i in 0 .. length(p) - 1 loop
    v_crc := v_crc # get_byte(p, i);
    for j in 1 .. 8 loop
      if (v_crc & 1) = 1 then v_crc := (v_crc >> 1) # 33800;   -- 0x8408
      else v_crc := v_crc >> 1; end if;
    end loop;
  end loop;
  return upper(lpad(to_hex(v_crc), 4, '0'));
end $function$;

-- Campo alfanumérico: à esquerda, completado com espaço; só caracteres da ISO 8859-1, sem quebra de linha
create or replace function fn_afd_a(p text, n int)
returns text language sql immutable set search_path = public, extensions as $function$
  select rpad(left(regexp_replace(coalesce(p, ''), '[^\u0020-\u007E\u00A0-\u00FF]', ' ', 'g'), n), n, ' ')
$function$;

-- Campo numérico: só dígitos, zeros à esquerda
create or replace function fn_afd_n(p text, n int)
returns text language sql immutable set search_path = public, extensions as $function$
  select lpad(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), n), n, '0')
$function$;

-- Data e hora "AAAA-MM-ddThh:mm:00ZZZZZ" no fuso da empresa (segundos fixos em 00)
create or replace function fn_afd_dh(p timestamptz, p_fuso text)
returns text language sql stable set search_path = public, extensions as $function$
  with x as (select (p at time zone p_fuso) as l, extract(epoch from (p at time zone p_fuso) - (p at time zone 'UTC'))::int / 60 as m)
  select to_char(l, 'YYYY-MM-DD"T"HH24:MI":00"')
         || case when m < 0 then '-' else '+' end
         || lpad((abs(m) / 60)::text, 2, '0') || lpad((abs(m) % 60)::text, 2, '0')
    from x
$function$;

create or replace function app_ponto_afd(p_empresa uuid, p_de date, p_ate date)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $function$
declare
  v_email   text := app_exigir(array['admin']);
  v_emp     record;
  v_fuso    text;
  v_hoje    date;
  v_inpi    text := fn_afd_n(fn_config('rep_p_inpi'), 17);
  v_dev     text;
  v_conf    boolean := coalesce(fn_config('afd_leiaute_conferido'), 'false') <> 'true';
  v_dh      text;
  v_linhas  text[] := '{}';
  v_campos  text;
  v_hash    text;
  v_ant     text := '';
  v_n7      int := 0;
  v_cab     text;
  v_fim     text;
  v_texto   text;
  v_sha     text;
  m         record;
begin
  select e.id, e.cnpj, e.razao_social, coalesce(e.fuso, 'America/Bahia') as fuso into v_emp
    from empresas e where e.id = p_empresa and e.empregadora;
  if not found then raise exception 'Empresa empregadora não encontrada.'; end if;
  v_fuso := v_emp.fuso;
  v_hoje := (now() at time zone v_fuso)::date;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate > v_hoje then
    raise exception 'Período inválido: a data final não pode passar de hoje.';
  end if;
  v_dev := fn_afd_n(coalesce(nullif(fn_config('rep_p_desenvolvedor_cnpj'), ''), v_emp.cnpj), 14);

  -- Cabeçalho (tipo 1): 298 posições + CRC-16
  v_cab := '000000000' || '1' || '1' || fn_afd_n(v_emp.cnpj, 14) || repeat(' ', 14)
        || fn_afd_a(v_emp.razao_social, 150) || v_inpi
        || to_char(p_de, 'YYYY-MM-DD') || to_char(p_ate, 'YYYY-MM-DD') || fn_afd_dh(now(), v_fuso)
        || '003' || '1' || v_dev || repeat(' ', 30);
  v_linhas := v_linhas || (v_cab || fn_afd_crc16(convert_to(v_cab, 'LATIN1')));

  -- Marcações (tipo 7): o hash encadeia desde a primeira marcação da empresa, mesmo fora do período
  for m in select k.nsr, k.cpf, k.momento, k.canal from ponto_marcacoes k
            where k.empresa_id = p_empresa order by k.nsr loop
    v_dh := fn_afd_dh(m.momento, v_fuso);
    v_campos := fn_afd_n(m.nsr::text, 9) || '7' || v_dh || fn_afd_n(m.cpf, 12)
             || v_dh                                                           -- gravação = marcação (on-line)
             || case m.canal when 'app' then '02' else '05' end               -- app web: navegador; WhatsApp e URA: outro
             || '0';                                                           -- on-line
    v_hash := encode(sha256(convert_to(v_campos || v_ant, 'LATIN1')), 'hex');
    v_ant := v_hash;
    if (m.momento at time zone v_fuso)::date between p_de and p_ate then
      v_linhas := v_linhas || (v_campos || v_hash);
      v_n7 := v_n7 + 1;
    end if;
  end loop;

  -- Trailer (tipo 9)
  v_fim := '999999999' || repeat('000000000', 5) || lpad(v_n7::text, 9, '0') || '9';
  v_linhas := v_linhas || v_fim;

  v_texto := array_to_string(v_linhas, E'\r\n') || E'\r\n';
  v_sha := encode(sha256(convert_to(v_texto, 'LATIN1')), 'hex');
  insert into ponto_afd_geracoes (email, empresa_id, de, ate, registros, sha256)
  values (v_email, p_empresa, p_de, p_ate, v_n7, v_sha);

  return jsonb_build_object(
    'nome', 'AFD' || v_inpi || fn_afd_n(v_emp.cnpj, 14) || 'REP_P' || case when v_conf then '_CONFERENCIA' else '' end || '.txt',
    'conteudo', v_texto, 'marcacoes', v_n7, 'sha256', v_sha,
    'conferencia', v_conf,
    'aviso', case when v_conf then 'Versão de conferência: leiaute do Anexo V da Portaria 671 (a conferir contra o do gov.br), '
             || 'sem assinatura CAdES' || case when v_inpi = repeat('0', 17) then ' e sem o número do INPI' else '' end
             || '. Não entregar à fiscalização antes da conferência da contadora. ' else '' end
             || 'O arquivo tem o CPF de todos os funcionários: guarde em local protegido e apague depois do uso.');
end $function$;

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
