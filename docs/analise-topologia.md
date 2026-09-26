# Análise crítica da topologia e do banco

Feita em 26/09/2026. Cobre desempenho, estrutura do banco, relações, a questão dos microserviços,
a comparação entre produção e repositório e o que foi corrigido nas migrations 39 a 41.

## Resumo

| Pergunta | Resposta |
|---|---|
| O banco tem bom desempenho? | **Sim, medido.** Com um ano de operação simulado, as consultas levam de 8 a 76 ms. Não é o gargalo |
| As relações estão bem modeladas? | **Sim, no essencial.** Modelo normalizado, chaves e restrições corretas. Os problemas estão em como o **tempo** é guardado e em pontos de higiene |
| Vale separar em microserviços? | **Não.** Para uma equipe de uma pessoa, multiplicaria deploys, custos e pontos de falha. A exceção útil é isolar o **provedor de WhatsApp** num adaptador (seção 3) |
| O que é grave? | Um bug de fuso que impedia o envio de escalas marcadas para as 3 horas seguintes; três telas quebradas em produção (documentos, cadastro de habilidade, habilidades do técnico); e um motor que para por inteiro com um único dado ruim |

## Como foi analisado

- Leitura das 38 migrations, das Edge Functions e do painel.
- Testes no projeto de **homologação** (`infoxtec-escalas-dev`), com dados simulados gravados e
  desfeitos na mesma transação. **A produção não foi acessada.**
- Relatórios de desempenho e segurança do próprio Supabase (advisors) sobre a homologação.
- `plpgsql_check`, verificador estático do Postgres, sobre todas as funções.
- Comparação da estrutura da produção com a do repositório por uma consulta que só lê definições,
  rodada pelo responsável no SQL Editor da produção (seção 4).

## 1. Desempenho

Volume simulado: 200 técnicos, 52 mil escalas (um ano), 156 mil mensagens e 52 mil eventos de
auditoria.

| Consulta | Quem usa | Tempo |
|---|---|---|
| `vw_acoes_pendentes` | Motor, 1 vez por minuto | 71 a 76 ms |
| `vw_ligacoes_pendentes` | Motor, fase de ligações | 43 a 51 ms |
| `vw_escalas_painel`, 15 dias | Agenda do painel | 40 ms |
| `vw_escalas_painel`, 30 dias | Agenda do painel | 70 ms |
| `fn_painel_locais` | Painel por local | 23 ms |
| `fn_pendencias_escala` | Alerta das 16h/18h | 8 ms |
| `fn_calcular_jornada` | Cada escala criada | 0,74 ms (500 linhas importadas ≈ 0,4 s) |

**Conclusão:** folga de pelo menos dez vezes o volume atual. As views do motor percorrem todas as
escalas abertas e buscam a última mensagem de cada uma. Isso só vai pesar com algumas centenas de
milhares de escalas; quando chegar lá, a saída é um índice parcial por status e arquivar escalas
antigas, não trocar de arquitetura.

## 2. Estrutura do banco

### Pontos fortes

- Modelo normalizado: `tecnicos`, `locais`, `escalas`, `notificacoes`, `respostas`,
  `ocorrencias`, com chaves estrangeiras e `on delete` coerentes.
- Índice único parcial impede dois horários iguais para o mesmo técnico e ignora as canceladas.
- Auditoria automática por gatilho (`escala_eventos`), com o autor da mudança.
- Enums para status, `check` em telefone e prioridade.
- RLS ligado em todas as tabelas e acesso só por funções que conferem o papel.

### Problemas

**Tempo local sem fuso (crítico, corrigido na 39).** A escala guarda `data_servico` (date) e
`hora_inicio` (time), que são hora local da Bahia. As views do motor comparavam
`data_servico + hora_inicio` com `now()`. Como o servidor roda em UTC, o Postgres tratava a hora
local como se fosse UTC. Testado na homologação às 11h52 da Bahia:

| Escala marcada para | Antes da 39 | Depois da 39 |
|---|---|---|
| +1 hora | **não aparecia para o motor** | enviar_primeira |
| +2 horas | **não aparecia para o motor** | enviar_primeira |
| +4 horas | enviar_primeira | enviar_primeira |
| Começou há 10 minutos | fora | fora |

Na prática: **escala criada para as próximas 3 horas nunca era enviada**, e lembretes, alerta ao
supervisor e ligação paravam 3 horas antes do início. A 39 compara hora local com hora local,
calculada uma vez por execução. O mesmo desvio existe no webhook (`fn_wh_mensagem`): a resposta
"1" solta vale para escalas até 9 horas depois do início, não 12. Fica para a migration de
sincronização (seção 4), porque essa função é grande e pode divergir da produção.

**Recomendação de longo prazo:** guardar o início como instante (`inicio_em timestamptz`, gerado
a partir da data e hora) e usar essa coluna em tudo que compara com o relógio.

**Estados sem fluxo automático.** `em_execucao` e `concluida` dependem de clique no painel;
`rascunho` e `reagendada` não são usados. Na prática, escala passada fica `confirmada` para
sempre, o que limita indicadores de execução. Decisão de negócio: fechar automaticamente depois do
término previsto, ou manter manual.

**`config` sem validação.** Os parâmetros são texto convertido na hora do uso. Um
`update config set valor = 'abc' where chave = 'max_tentativas'` quebra o motor a cada minuto,
sem aviso. Recomendação: função de gravação que valida o tipo, ou `check` por chave.

**Campo legado.** `escalas.duracao_prevista_min` perdeu sentido com a jornada CLT calculada; o
painel ainda envia 480 fixo.

**Duas tabelas de pessoas.** Supervisores são linhas de `tecnicos` (`is_supervisor`) e usuários do
painel ficam em `painel_usuarios`, por e-mail. Funciona, mas a mesma pessoa pode estar nos dois
cadastros com dados diferentes. Aceitável no tamanho atual.

**Índices.** O Supabase aponta 10 chaves estrangeiras sem índice; nenhuma pesa nesse volume.
`idx_notif_wa` duplica o índice que a restrição `unique` de `notificacoes.wa_message_id` já cria
e pode ser removido.

**Logs sem retenção (corrigido na 39).** `webhook_eventos` guarda o conteúdo de todas as
mensagens recebidas, e o `pg_cron` grava 1.440 execuções por dia. A limpeza era manual.

## 3. Topologia e a questão dos microserviços

```mermaid
flowchart LR
    P[Painel React<br/>Vercel] -->|RPC app_*| DB[(Postgres Supabase<br/>regras + motor)]
    CR[pg_cron 1/min] --> DB
    DB -->|pg_net HTTP| EVO[Evolution API<br/>VPS]
    EVO -->|webhook| EF1[Edge webhook-evolution] --> DB
    DB -->|pg_net| EF2[Edge voz-escala] --> TW[Twilio]
    TW -->|TwiML e teclas| EF2
    P -->|imagem| EF3[Edge documento-ocr] --> GV[Google Vision]
```

**Por que não microserviços.** Hoje há um núcleo (o banco) e três funções finas. Separar escalas,
mensagens, voz e documentos em serviços próprios traria chamadas de rede entre eles, autenticação
entre serviços, deploys coordenados e mais contas para pagar, sem ganho: o volume é pequeno e a
equipe é uma pessoa. A decisão 1 (regra no banco) continua certa para este tamanho.

**Os pontos fracos reais da topologia:**

1. **O motor não isola falhas.** `fn_dispatcher_whatsapp` roda as fases 1 a 3 numa única
   transação, sem tratamento por escala. Um dado ruim numa escala (por exemplo, erro ao montar a
   mensagem) derruba a execução inteira, e como o `pg_net` também é transacional, nenhuma mensagem
   sai até alguém corrigir o dado. Correção: tratamento de erro por item, registrando a falha na
   própria notificação. Depende da sincronização da seção 4.
2. **O provedor de WhatsApp está embutido no SQL.** `fn_payload_escala` e `fn_evo_post` montam o
   formato e o endereço da Evolution. A migração para a API oficial da Meta, que é a primeira
   tarefa do Bloco 1 de [segurança e homologação](seguranca-homologacao.md), exigiria reescrever
   essas funções. Proposta: uma tabela de saída (`mensagens_saida`) que o banco preenche com o
   conteúdo neutro, e **uma** Edge Function que lê essa fila e fala com o provedor. Trocar a
   Evolution pela Meta vira mudança numa função. É o único "serviço" que vale separar, e deve ser
   feito junto com a migração para a Meta, não antes.
3. **Ninguém é avisado quando o motor falha.** Uma falha do dispatcher fica registrada em
   `cron.job_run_details` e em nenhum outro lugar. Recomendação: indicador na aba Operação e
   alerta ao supervisor quando a última execução bem-sucedida tiver mais de 5 minutos.

## 4. Produção comparada com o repositório

Uma consulta que só lê definições (sem dados) foi rodada na produção e comparou 199 objetos com o
repositório até a migration 38: 97 funções, 8 views, 22 tabelas com colunas, restrições, índices
e gatilhos, e 6 tipos. A mesma consulta rodada na homologação não acusou nenhum falso alarme.

| Resultado | Objetos |
|---|---|
| Idênticos | Todas as tabelas, colunas, restrições, índices, gatilhos, tipos e views |
| Só comentários e espaçamento diferentes | 21 funções (conferido com o texto normalizado) |
| Mesma saída, texto escrito de outro jeito | `fn_voz_twiml` (testado lado a lado: saída idêntica em 4 casos) |
| **Diferença real** | `fn_dispatcher_whatsapp`: a produção tem a fase 6, que chama as ligações da URA |

**A única divergência real era a fase 6 do motor**, aplicada direto no banco na época da migration
25. A migration 40 traz essa versão para o repositório, byte a byte igual à da produção (conferido
por hash). Em produção ela não muda nada.

**Correção de uma suposição anterior:** a análise inicial supunha que a produção tinha as
políticas de documentos ajustadas. Não tem. Elas são iguais às do repositório, e `fn_papel` também
não tem permissão para o usuário logado. Isso significa que, na produção, **abrir e enviar
arquivos de documento pelo painel falham** com `permission denied for function fn_papel`.
Documentos vinculados por link do Drive não passam pelo Storage e não são afetados. A migration 39
corrige.

### Duas telas quebradas, encontradas pelo verificador

O `plpgsql_check` analisou todas as funções e encontrou exatamente dois erros, presentes na
produção e no repositório:

| Função | Tela | Erro |
|---|---|---|
| `app_salvar_habilidade` | Habilidades: criar ou editar | `column "exige_validade" of relation "habilidades" does not exist` |
| `app_definir_habilidades` | Técnicos: marcar habilidades | `column "exige_validade" does not exist` |

A migration 36 removeu a coluna e essas duas funções continuaram usando-a. Corrigidas na 41; depois
dela, o verificador aponta zero erros.

## 5. Achados por prioridade

| # | Achado | Gravidade | Situação |
|---|---|---|---|
| 1 | Fuso: escalas das próximas 3 horas nunca enviadas | Crítica | **Corrigido na 39** |
| 2 | Documentos: abrir e enviar arquivo falham (produção e repositório) | Alta | **Corrigido na 39** |
| 3 | Habilidades: criar, editar e atribuir falham (produção e repositório) | Alta | **Corrigido na 41** |
| 4 | Motor sem isolamento: um dado ruim trava todos os envios | Alta | **Corrigido na 41** |
| 5 | Fase 6 do motor (ligações) fora do repositório | Crítica para o processo | **Sincronizado na 40** |
| 6 | `vw_ligacoes_pendentes` e tabelas com permissão para `anon` | Média | **Corrigido na 39** |
| 7 | Logs sem retenção | Média | **Corrigido na 39** + `setup/cron.sql` |
| 8 | Desvio de fuso no webhook (9h em vez de 12h) | Baixa | **Corrigido na 41** |
| 9 | Provedor de WhatsApp embutido no SQL | Média | Proposta: fila de saída + adaptador, junto com a API Meta |
| 10 | Motor falha em silêncio | Média | A fazer |
| 11 | `config` sem validação | Média | A fazer |
| 12 | Estados sem fluxo, campo legado, índice duplicado | Baixa | A decidir |

## 6. As migrations 39, 40 e 41

Todas aplicadas e testadas na homologação, com dados simulados desfeitos ao final de cada teste.

| Migration | Parte | Teste |
|---|---|---|
| 39 | Fuso: views do motor comparam hora local com hora local | Escalas de +1h e +2h passam a aparecer; escala já iniciada continua fora |
| 39 | Documentos: `app_pode_gerir_documentos()` nas políticas do bucket | Admin lê; e-mail fora de `painel_usuarios` não lê |
| 39 | Permissões: nada do schema `public` acessível direto pela API | `anon` bloqueado na view e em `tecnicos`; 9 funções do painel testadas como admin |
| 39 | Limpeza: `fn_limpeza_logs()` | Executa; sem permissão para `anon` e `authenticated` |
| 39 | Desempenho | 76 ms com um ano de dados, igual ao anterior |
| 40 | Motor igual ao da produção (fases 1 a 6) | Hash da definição idêntico ao da produção |
| 41 | Habilidades sem a coluna removida | Criar, editar, atribuir e reatribuir como admin; usuário sem papel barrado |
| 41 | Motor isola falha por escala | Três escalas, a do meio com erro forçado: as duas boas foram enviadas, a ruim ficou registrada como falha `interno` |
| 41 | Webhook: janela de 12 horas no fuso certo | "1" solto para escala iniciada há 10 horas confirma a escala |
| 41 | Verificador estático | Zero erros em todas as funções |

### Aplicar em produção

As três de uma vez, na ordem. Cada migration roda numa transação: se uma falhar, ela é desfeita
inteira e o `db push` para.

1. Merge do PR em `main`.
2. Na máquina Linux, no repositório atualizado:
   ```bash
   npx supabase link --project-ref zpckrxydqqmmcrphrkxz
   cat supabase/.temp/project-ref        # tem que mostrar zpckrxydqqmmcrphrkxz
   npx supabase db push                  # lista 39, 40 e 41; confirmar com Y
   ```
3. No SQL Editor da produção, agendar a limpeza (última linha de `supabase/setup/cron.sql`).
4. Testar no painel de produção: abrir um documento, salvar uma habilidade, marcar as habilidades de
   um técnico.
5. Voltar o `link` para a homologação: `npx supabase link --project-ref oruwnlxyvznpigbpjjbx`.

**Efeitos imediatos em produção:** escalas das próximas 3 horas que estavam presas são enviadas no
minuto seguinte, se estiverem dentro da janela de envio; documentos e habilidades voltam a
funcionar no painel. O painel não precisa de nova publicação.

**Como desfazer, se necessário:** o motor anterior está, na íntegra, na migration 40; o webhook
anterior é o da migration 41 com a linha do fuso revertida; as views anteriores estão nas
migrations 10 e 29.

## 7. Próximas etapas

| Etapa | O quê | Situação |
|---|---|---|
| A | Migrations 39, 40 e 41 na homologação | **Feito** |
| B | Comparar a produção com o repositório | **Feito** (seção 4) |
| C | Aplicar 39 a 41 em produção | Revisão, merge e `db push` (seção 6) |
| D | Alerta de motor parado (item 10) | A fazer |
| E | Validação de `config` (item 11) | A fazer |
| F | Testes automatizados (pgTAP) para fuso, motor, permissões e habilidades, e `plpgsql_check` no CI | Fase 2 do [fluxo](fluxo-de-desenvolvimento.md) |
| G | Fila de saída e adaptador de WhatsApp | Junto com a migração para a API Meta |
