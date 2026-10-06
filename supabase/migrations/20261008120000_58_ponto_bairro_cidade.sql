-- Migration 58 (08/10/2026): bairro e cidade de cada marcação do ponto, a partir da latitude e
-- longitude (pedido do responsável), para o Registro de Ponto do painel. Decisão 50.
--
-- Geocodificação reversa pelo Nominatim (OpenStreetMap): gratuito, sem cartão e sem chave; dados
-- ODbL, que podem ser guardados com atribuição (o Google proíbe guardar o resultado por mais de 30
-- dias e exige cartão). Política de uso do Nominatim: no máximo 1 consulta por segundo, User-Agent
-- identificado e cache — aqui, uma consulta por minuto e cache por coordenada arredondada.
--
-- LGPD (minimização): só sai a coordenada ARREDONDADA em 3 casas (cerca de 110 m), nunca a exata,
-- sem nome, CPF ou qualquer identificador; o serviço (OSMF) fica no Reino Unido e não tem as
-- marcações — ver decisão 50. A marcação não muda (é imutável): bairro e cidade ficam em
-- ponto_geo, ligados pela coordenada arredondada.

create table if not exists ponto_geo (
  lat3          numeric(8,3) not null,
  lng3          numeric(9,3) not null,
  bairro        text,
  cidade        text,
  uf            text,
  status        text not null default 'pendente' check (status in ('pendente', 'enviado', 'ok', 'erro')),
  tentativas    int  not null default 0,
  req_id        bigint,
  enviado_em    timestamptz,
  atualizado_em timestamptz not null default now(),
  primary key (lat3, lng3)
);
comment on table ponto_geo is 'Bairro e cidade por coordenada arredondada (3 casas, ~110 m), do Nominatim/OpenStreetMap (ODbL). Não guarda quem marcou.';
alter table ponto_geo enable row level security;
revoke all on ponto_geo from anon, authenticated, service_role;
create index if not exists ponto_geo_status_idx on ponto_geo (status) where status in ('pendente', 'enviado');

insert into config (chave, valor, descricao) values
  ('geocodificacao_url', 'https://nominatim.openstreetmap.org/reverse',
   'Ponto: serviço de geocodificação reversa (Nominatim/OpenStreetMap) para bairro e cidade das marcações. Vazio desliga.')
on conflict (chave) do nothing;

-- Coordenadas já marcadas entram na fila (vale para a produção, que já tem marcações)
insert into ponto_geo (lat3, lng3)
select distinct round(latitude, 3), round(longitude, 3) from ponto_marcacoes
 where latitude is not null and longitude is not null
on conflict do nothing;

create index if not exists ponto_marcacoes_momento_idx on ponto_marcacoes (momento);

-- Roda a cada minuto (pg_cron, só na produção): lê as respostas, enfileira coordenadas novas e
-- envia UMA consulta por execução (política do Nominatim). Devolve quantas ficaram prontas.
-- Bloqueio do serviço (403/429) pausa as consultas por 1 hora sem gastar tentativa; coordenada em
-- erro volta a ser tentada depois de 24 horas.
create or replace function fn_ponto_geo_processar()
returns int language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  g      record;
  r      record;
  j      jsonb;
  a      jsonb;
  v_ok   int := 0;
  v_url  text := nullif(fn_config('geocodificacao_url'), '');
  v_req  bigint;
begin
  if v_url is null then return 0; end if;

  -- 1. Respostas que chegaram
  for g in select * from ponto_geo where status = 'enviado' for update skip locked loop
    select status_code, content into r from net._http_response where id = g.req_id;
    if not found then
      if g.enviado_em < now() - interval '5 minutes' then
        update ponto_geo set status = case when tentativas >= 3 then 'erro' else 'pendente' end,
               atualizado_em = now() where lat3 = g.lat3 and lng3 = g.lng3;
      end if;
      continue;
    end if;
    if r.status_code in (403, 429) then
      -- serviço recusou (limite ou bloqueio): pausa e devolve à fila sem gastar tentativa
      insert into config (chave, valor, descricao)
      values ('geocodificacao_pausa_ate', (now() + interval '1 hour')::text,
              'Ponto: consultas ao OpenStreetMap pausadas até esta hora (o serviço recusou com 403/429).')
      on conflict (chave) do update set valor = excluded.valor;
      update ponto_geo set status = 'pendente', tentativas = greatest(tentativas - 1, 0), atualizado_em = now()
       where lat3 = g.lat3 and lng3 = g.lng3;
      continue;
    end if;
    begin
      j := case when r.status_code = 200 then r.content::jsonb end;
    exception when others then j := null; end;
    a := j -> 'address';
    if j is null then
      update ponto_geo set status = case when tentativas >= 3 then 'erro' else 'pendente' end,
             atualizado_em = now() where lat3 = g.lat3 and lng3 = g.lng3;
    else
      -- 200 sem endereço (mar, área sem dado) também é resposta final: bairro e cidade ficam vazios
      update ponto_geo set
        bairro = left(coalesce(a->>'suburb', a->>'neighbourhood', a->>'quarter', a->>'hamlet'), 120),
        cidade = left(coalesce(a->>'city', a->>'town', a->>'village', a->>'municipality'), 120),
        uf     = left(nullif(replace(coalesce(a->>'ISO3166-2-lvl4', ''), 'BR-', ''), ''), 2),
        status = 'ok', atualizado_em = now()
       where lat3 = g.lat3 and lng3 = g.lng3;
      v_ok := v_ok + 1;
    end if;
  end loop;

  -- 2. Coordenadas novas (marcações dos últimos 2 dias; as antigas entraram pela migration)
  insert into ponto_geo (lat3, lng3)
  select distinct round(m.latitude, 3), round(m.longitude, 3) from ponto_marcacoes m
   where m.momento > now() - interval '2 days' and m.latitude is not null and m.longitude is not null
  on conflict do nothing;

  -- 3. Uma consulta por execução, fora da pausa
  if coalesce(nullif(fn_config('geocodificacao_pausa_ate'), '')::timestamptz, '-infinity') > now() then
    return v_ok;
  end if;
  select * into g from ponto_geo
   where (status = 'pendente' and tentativas < 3)
      or (status = 'erro' and atualizado_em < now() - interval '24 hours')
   order by atualizado_em limit 1 for update skip locked;
  if found then
    v_req := net.http_get(url := v_url,
      params := jsonb_build_object('format', 'jsonv2', 'lat', g.lat3::text, 'lon', g.lng3::text,
                                   'zoom', '16', 'addressdetails', '1', 'accept-language', 'pt-BR'),
      headers := jsonb_build_object('User-Agent', 'TrilhaPonto/1.0 (+https://infoxtec.com.br)'),
      timeout_milliseconds := 10000);
    update ponto_geo set status = 'enviado', req_id = v_req, enviado_em = now(),
           tentativas = case when g.status = 'erro' then 1 else tentativas + 1 end, atualizado_em = now()
     where lat3 = g.lat3 and lng3 = g.lng3;
  end if;
  return v_ok;
end $$;

-- Painel: bairro e cidade das marcações do período (mesmo filtro de app_ponto_acompanhamento).
-- Só admin e gestor: o papel leitura não vê onde a marcação foi feita (como em app_ponto_acompanhamento).
create or replace function app_ponto_geo(p_de date, p_ate date, p_tecnico uuid default null)
returns table (id uuid, bairro text, cidade text, uf text, geo_status text)
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform app_exigir(array['admin','gestor']);
  if p_ate < p_de or p_ate - p_de > 62 then raise exception 'Período de até 62 dias.'; end if;
  return query
    select m.id, g.bairro, g.cidade, g.uf, coalesce(g.status, 'pendente')
      from ponto_marcacoes m
      join empresas e on e.id = m.empresa_id
      left join ponto_geo g on g.lat3 = round(m.latitude, 3) and g.lng3 = round(m.longitude, 3)
     where m.latitude is not null
       and (m.momento at time zone e.fuso)::date between p_de and p_ate
       and (p_tecnico is null or m.tecnico_id = p_tecnico);
end $$;

-- Permissões por laço (decisões 12 e 49) -----------------------------------------------------------
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
  end loop;
end $$;
