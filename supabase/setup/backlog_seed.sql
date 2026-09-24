-- Carga inicial do backlog exibido na aba Roadmap. Rodar uma vez por ambiente.
delete from backlog_itens;

insert into backlog_itens (numero, tipo, titulo, descricao, status, esforco, depende_de, observacao, entregue_em, ordem) values
 (1, 'backlog', 'Checklist e laudo pelo WhatsApp',
    'Link seguro no celular do tecnico com checklist, fotos e assinatura; laudo em PDF.',
    'planejado', 'G', null,
    'Proxima entrega grande. Destrava o percentual real de conclusao do item 3.', null, 10),
 (2, 'backlog', 'Ligacao de voz (URA)',
    'Quem nao responde duas mensagens recebe ligacao: 1 aprova, 2 nega.',
    'concluido', 'M', null,
    'Twilio com Verified Caller ID. ~R$ 0,24 por ligacao atendida. Disparo automatico controlado por ligacao_ativa.',
    '2026-09-23', 20),
 (3, 'backlog', 'Painel por local e % de conclusao',
    'Aba Operacao: escalas do dia agrupadas por local, aceite e conclusao.',
    'parcial', 'M', 'item 1',
    'Entregue com % de aceite real. O % de conclusao depende do checklist para deixar de ser manual.',
    '2026-09-22', 30),
 (4, 'backlog', 'Integracao com ponto VRmais',
    'Conciliar aceite da escala com as batidas de ponto.',
    'bloqueado', 'M', 'API VRmais + parecer juridico',
    'Bloquear o registro de ponto tem risco trabalhista; a recomendacao e conciliar e alertar divergencias.',
    null, 40),
 (5, 'backlog', 'Habilidades e certificacoes',
    'Skills por tecnico, requisitos por tipo de atividade e gestao de documentos.',
    'concluido', 'M', null,
    'Inclui NRs, CNH e ASO com validade, aviso de vencimento e alerta semanal aos supervisores.',
    '2026-09-22', 50),
 (6, 'backlog', 'IA que sugere a escala',
    'Sugestao de tecnico por aptidao, disponibilidade, rodizio e deslocamento.',
    'planejado', 'G', 'itens 5 e 3',
    'Destravado pelo item 5. Primeiro estagio possivel: motor de regras sem IA.', null, 60),
 (7, 'backlog', 'Predicao e pre-programacao',
    'Projeta demanda futura e reserva pessoas e recursos com antecedencia.',
    'planejado', 'G', 'itens 6 e 8', 'Fora da janela de 60 dias.', null, 70),
 (8, 'backlog', 'Integracao com chamados Infoxtec',
    'Chamado agendado vira escala; desfecho da escala volta ao chamado.',
    'bloqueado', null, 'levantamento da API',
    'Maior ganho de produtividade da lista. Depende de saber se o sistema atual tem API.', null, 80),
 (9, 'backlog', 'Integracao com almoxarifado Infoxtec',
    'Material previsto na escala, reserva e baixa vinculadas.',
    'bloqueado', null, 'levantamento da API', 'Mesmo levantamento do item 8.', null, 90);

insert into backlog_itens (tipo, titulo, descricao, status, entregue_em, ordem) values
 ('entrega', 'Banco e motor de escalas', 'Tabelas, regras em SQL e agendamento a cada minuto.', 'concluido', '2026-09-21', 200),
 ('entrega', 'Envio e resposta pelo WhatsApp', 'Evolution API com botoes e resposta 1/2; webhook de entrega, leitura e resposta.', 'concluido', '2026-09-21', 210),
 ('entrega', 'Lembretes e alerta ao supervisor', 'Reenvio a cada 30 min, ate 3 tentativas, com escalonamento.', 'concluido', '2026-09-21', 220),
 ('entrega', 'Painel proprio na Vercel', 'Migracao do Retool: React, login Supabase, papeis admin/gestor/leitura.', 'concluido', '2026-09-22', 230),
 ('entrega', 'Jornada CLT automatica', 'Termino calculado por turno diurno, noturno e misto, com intervalo.', 'concluido', '2026-09-22', 240),
 ('entrega', 'Prazo da escala do dia seguinte', 'Aviso as 16h e prazo as 18h para os supervisores.', 'concluido', '2026-09-22', 250),
 ('entrega', 'Tecnicos sem escala e importacao por planilha', 'Painel de pendencias do dia e importacao em lote.', 'concluido', '2026-09-22', 260);

insert into backlog_itens (tipo, titulo, descricao, status, observacao, ordem) values
 ('divida', 'Desligar o painel Retool', 'O app antigo continua ativo e com acesso ao banco.', 'planejado',
  'Quem tem permissao de edicao no Retool executa SQL no banco. Prioridade de seguranca.', 300),
 ('divida', 'Remover funcoes da bancada de teste', 'fn_teste_wa_* da migration 07 seguem no banco.', 'planejado',
  'Sem uso desde que o dispatcher entrou.', 310),
 ('divida', 'Consolidar o repositorio do Vercel', 'Confirmar se o deploy vem do repositorio infoxtec-escalas.', 'planejado',
  'Enquanto houver dois repositorios, o deploy pode publicar codigo antigo.', 320);
