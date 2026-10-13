-- Apaga a demonstração com dados fictícios (backlog 101, decisão 80). SÓ NA HOMOLOGAÇÃO.
-- Uso: ./scripts/demo-homologacao.sh apagar
--
-- Remove só o que o criar.sql criou: a empresa de CNPJ 99.999.999/0001-91, os técnicos e locais dela, as
-- escalas desses técnicos (com notificações, respostas, ligações e eventos), as escalas de carga horária e os times
-- da empresa e os tipos com "(demo)" no nome.
-- Recusa se houver registro de ponto da empresa (imutável por lei) ou escala real num local da demonstração.

do $demo$
declare
  v_emp uuid;
  n int := 0;
  v_esc int; v_tec int; v_loc int;
begin
  if to_regclass('cron.job') is not null then execute 'select count(*) from cron.job' into n; end if;
  -- com agendador, só a homologação configurada (decisão 94: webhook_url do projeto de homologação)
  if coalesce(fn_config('ambiente'), 'producao') <> 'homologacao'
     or (n > 0 and coalesce(fn_config('webhook_url'), '') not like '%oruwnlxyvznpigbpjjbx%') then
    raise exception 'Este banco não é a homologação (config ambiente ou tarefas no pg_cron). A demonstração só roda na homologação.';
  end if;
  select id into v_emp from empresas where cnpj = '99999999000191';
  if v_emp is null then
    raise notice 'Não há demonstração para apagar.';
    return;
  end if;

  if exists (select 1 from ponto_marcacoes where empresa_id = v_emp)
     or exists (select 1 from ponto_ajustes where empresa_id = v_emp)
     or exists (select 1 from ponto_justificativas where empresa_id = v_emp)
     or exists (select 1 from ponto_abonos where empresa_id = v_emp)
     or exists (select 1 from ponto_nsr where empresa_id = v_emp)
     or exists (select 1 from ponto_documento_registros where empresa_id = v_emp)
     or exists (select 1 from ponto_documento_sequencia where empresa_id = v_emp)
     or exists (select 1 from ponto_marcacoes m join locais l on l.id = m.local_id where l.cliente_empresa_id = v_emp) then
    raise exception 'A empresa da demonstração tem registro de ponto, que é imutável: ela não pode ser apagada.';
  end if;
  if exists (select 1 from escalas e join locais l on l.id = e.local_id
              where l.cliente_empresa_id = v_emp
                and e.tecnico_id not in (select id from tecnicos where empresa_id = v_emp)) then
    raise exception 'Há escala de técnico real num local da demonstração. Troque o local dessa escala antes de apagar.';
  end if;

  delete from escalas where tecnico_id in (select id from tecnicos where empresa_id = v_emp);
  get diagnostics v_esc = row_count;
  -- escalas de carga horária e times da demonstração (decisão 88). As tabelas de escala não deixam apagar (histórico);
  -- aqui o dado é fictício e só da demonstração, então as travas saem só durante esta transação.
  alter table carga_atribuicoes disable trigger trg_carga_atribuicoes_guarda;
  alter table carga_aceites disable trigger trg_carga_aceites_imutavel;
  alter table cargas_horarias disable trigger trg_cargas_horarias_imutavel;
  delete from carga_atribuicoes where empresa_id = v_emp;
  delete from carga_aceites where empresa_id = v_emp;
  delete from cargas_horarias where empresa_id = v_emp;
  alter table carga_atribuicoes enable trigger trg_carga_atribuicoes_guarda;
  alter table carga_aceites enable trigger trg_carga_aceites_imutavel;
  alter table cargas_horarias enable trigger trg_cargas_horarias_imutavel;
  delete from tecnicos where empresa_id = v_emp;
  get diagnostics v_tec = row_count;
  delete from locais where cliente_empresa_id = v_emp;
  get diagnostics v_loc = row_count;
  -- tipos "(demo)" só saem se nada fora da demonstração os usa (senão a cascata levaria dado real junto)
  delete from tipos_atividade ta where ta.nome like '% (demo)'
    and not exists (select 1 from escalas e where e.tipo_atividade_id = ta.id)
    and not exists (select 1 from tipo_atividade_documentos tad join tipos_documento td on td.id = tad.tipo_documento_id
                     where tad.tipo_id = ta.id and td.nome not like '% (demo)')
    and not exists (select 1 from tipo_atividade_requisitos r where r.tipo_id = ta.id);
  delete from tipos_documento td where td.nome like '% (demo)'
    and not exists (select 1 from tecnico_documentos x where x.tipo_documento_id = td.id)
    and not exists (select 1 from documentos x where x.tipo_documento_id = td.id)
    and not exists (select 1 from tipo_atividade_documentos tad join tipos_atividade ta on ta.id = tad.tipo_id
                     where tad.tipo_documento_id = td.id and ta.nome not like '% (demo)');
  delete from times where empresa_id = v_emp;
  delete from empresas where id = v_emp;

  raise notice 'Demonstração apagada: % escalas, % técnicos, % locais.', v_esc, v_tec, v_loc;
end $demo$;
