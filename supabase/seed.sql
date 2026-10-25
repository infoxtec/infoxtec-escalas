-- Dados de desenvolvimento. NAO rodar em producao.
-- Cadastros reais entram pelo painel Retool.
set search_path = interno, public, extensions;  -- tabelas no esquema interno (migration 115)

insert into tecnicos (nome, telefone_e164, funcao, is_supervisor, opt_in, opt_in_em) values
  ('Supervisor Exemplo', '5571900000001', 'Supervisor', true,  true, now()),
  ('Tecnico Exemplo',    '5571900000002', 'Instalador', false, true, now())
on conflict (telefone_e164) do nothing;

insert into locais (nome, cliente, endereco, referencia) values
  ('Obra Exemplo - Torre A', 'Cliente Exemplo', 'Endereco de teste - Salvador/BA', 'Portaria');
