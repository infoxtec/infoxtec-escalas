# Incidente 2026-11-12: instância de homologação pareada no número oficial do WhatsApp

Registro interno de incidente com dados pessoais (art. 10 da Resolução CD/ANPD 15/2024; guardar por no mínimo 5 anos).
Sem telefone nem nome de titular neste arquivo. Decisão 137; controles na migration 153.

| Campo | Registro |
|---|---|
| Número | INC-2026-11-12 |
| Ocorrência | Ao menos de 13/10/2026 (o log tem retenção de 30 dias; pode ter começado antes) a 04/11/2026, e de 12/11/2026 a 13/11/2026 00:06 UTC |
| Descoberta | 12/11/2026, 13:31 UTC, no teste do B4 (banco travado): as mesmas mensagens, com o mesmo `key.id`, chegaram à homologação e à produção, e a produção respondeu em tempo real enquanto a homologação estava travada |
| Contenção | 12/11: logout da instância (insuficiente: voltou a se conectar). 13/11: instância `trilha-homologacao` **apagada** no servidor (`instance/logout` e `instance/delete`); `fetchInstances` só com a `infoxtec`; um aparelho a menos no celular oficial |
| Natureza | Confidencialidade e finalidade (dados da produção no ambiente de teste); integridade na produção (mensagens de teste processadas como reais) |
| Causa raiz | O QR da instância de homologação foi lido pelo celular do número oficial (final 9605), contra a decisão 94 ("outro número"). Duas instâncias no mesmo número recebem e respondem tudo |
| Dados na homologação | `interno.webhook_eventos`: 128 mensagens recebidas de 11 números (10 técnicos da produção, 9 ativos), 647 mensagens enviadas pela produção a técnicos (texto de escala: nome, local, horário), 53 de grupos e status do número oficial; mais 29 entre o logout e a exclusão. Sem mídia (filtro da decisão 56) e sem localização |
| Titulares | 11 números (10 técnicos) e os participantes dos grupos dos 53 eventos |
| Acesso | Banco de homologação: responsável e Claude. Conferido com o responsável em 13/11: ninguém leu mensagens com atestado, doença ou exame; o DeepSeek não leu o `webhook_eventos`; não houve dump, exportação ou cópia. O Claude leu só contagens e md5 dos 11 números, e o texto apenas do número do próprio responsável |
| Envio a terceiros | Nenhum: a trava da decisão 44 (migration 99) só deixa a homologação enviar aos 5 números de teste |
| Efeito na produção | Tudo o que os números de teste mandaram nos dois períodos chegou também à produção. O responsável confirmou que todos os registros desses números nos períodos foram teste (marcações, justificativas, respostas de escala). Serão removidos no reinício do módulo de ponto antes do uso oficial (01/12) |
| Avaliação de risco | Sem risco ou dano relevante (art. 5º da Res. 15/2024): poucos titulares, sem dado sensível, financeiro ou de autenticação, mesmo controlador e infraestrutura, sem divulgação, contenção no mesmo dia. **Não há comunicação à ANPD nem aos titulares.** Avaliação do `seguranca` em 12/11, confirmada pelo responsável em 13/11 |
| Limpeza | 857 linhas apagadas da homologação (828 em 12/11, 29 em 13/11), conferidas com zero restantes. Os backups automáticos da homologação ainda as contêm até expirarem: **não restaurar backup da homologação anterior a 13/11 sem repetir a limpeza** |
| Correções | Migration 153 (decisão 137): portão do webhook pelo número dono da instância, homologação só com os números de teste e retenção de 7 dias; caminho registrado na tabela 1 de `docs/caminhos-de-producao.md` (linha 16); checklist de pareamento em `docs/evolution-propria.md`; decisão 94 corrigida. Antes de parear de novo: número próprio para a homologação e token novo |
| Pendências | Vigia comparar o `ownerJid` de cada instância com o esperado; alerta na produção de mensagem `fromMe` que o sistema não enviou (P2) |
| Revisão | 13/11: travas (153) e número oficial (154) na produção; registros de teste apagados pelo reinício do módulo de ponto (decisão 138). Falta: número próprio para a homologação e token novo ao parear |
