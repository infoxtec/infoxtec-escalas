-- Dados de desenvolvimento. NAO rodar em producao.
-- Cadastros reais entram pelo painel Retool.
set search_path = interno, public, extensions;  -- tabelas no esquema interno (migration 115)

-- sem sessão não há conta padrão (migration 126): os exemplos vão para a conta 1
insert into tecnicos (conta_id, nome, telefone_e164, funcao, is_supervisor, opt_in, opt_in_em) values
  ('00000000-0000-0000-0000-000000000001', 'Supervisor Exemplo', '5571900000001', 'Supervisor', true,  true, now()),
  ('00000000-0000-0000-0000-000000000001', 'Tecnico Exemplo',    '5571900000002', 'Instalador', false, true, now())
on conflict (telefone_e164) do nothing;

insert into locais (conta_id, nome, cliente, endereco, referencia) values
  ('00000000-0000-0000-0000-000000000001', 'Obra Exemplo - Torre A', 'Cliente Exemplo', 'Endereco de teste - Salvador/BA', 'Portaria');
