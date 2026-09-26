-- 42 | Backlog: tres pacotes para a gestao de documentos
--
-- Itens pedidos em 26/09/2026. Analise de viabilidade em docs/backlog.md (itens 14 a 16).
-- Grupo 'backlog', ja exibido pelo painel (decisao 24). Nao duplica se o titulo ja existir, e
-- numera a partir do maior numero do grupo, porque a producao pode ter itens criados pela tela.

insert into backlog_itens (numero, tipo, titulo, descricao, status, esforco, depende_de, observacao, ordem, coluna, posicao)
select base.n + v.seq, 'backlog', v.titulo, v.descricao, 'planejado', 'M', v.depende_de, v.observacao,
       (base.n + v.seq) * 10, 'backlog', 0
from (select coalesce(max(numero), 0) as n from backlog_itens where tipo = 'backlog') base,
     (values
       (1, 'Identificação automática do documento: tipo e técnico',
        'Ao carregar um ou vários arquivos, ler o título (nome do arquivo e texto da primeira página) e sugerir o tipo de documento e o técnico a que pertence. Nada é gravado sem conferência na tabela de revisão.',
        null,
        'Casamento por nome falha com homônimos; o seguro é pelo CPF, que não existe no cadastro (decisão de LGPD pendente).'),
       (2, 'Pré-visualização do documento e download com aviso de LGPD',
        'Documento visível ao lado dos campos no envio, para conferir tipo, técnico e validade. O mesmo visualizador depois de gravado. Download separado, só após aceite do aviso de responsabilidade, com registro de quem baixou, quando e qual documento.',
        null,
        'Reaproveita o leitor de PDF já existente. A trilha de downloads é uma tabela nova.'),
       (3, 'Classificação obrigatória: ASO, NR, suspensão ou advertência',
        'Nenhum documento lido é gravado sem categoria. A regra vale no banco. ASO e NR exigem validade; suspensão e advertência pedem a data do fato. Documentos antigos sem tipo entram numa lista para classificar.',
        'Pré-visualização do documento',
        'Pendente: quem vê suspensão e advertência (sugestão: só admin) e se CNH continua como categoria.')
     ) as v(seq, titulo, descricao, depende_de, observacao)
where not exists (select 1 from backlog_itens b where b.titulo = v.titulo);
