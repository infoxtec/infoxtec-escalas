# Revisão de infraestrutura e de banco (25/10/2026)

Primeira rodada do `arquiteto-cloud` e do `arquiteto-dados` (decisão 115). Homologação lida só em leitura;
produção não tocada; medições do banco no ambiente local, com volume simulado (2 contas × 200 técnicos,
52.200 escalas e 102 mil marcações cada), em transação desfeita.

## Veredito

- **Infra:** com risco. A homologação está saudável e igual ao repositório. Os riscos são pontos únicos de
  falha sem plano de volta escrito.
- **Banco:** aprova com ajustes. O isolamento entre contas está garantido pelas funções. A garantia no próprio
  dado (chave composta, decisão 108) ainda não existe. Nada é P0 enquanto a trava da 117 estiver ligada.

## Medido na homologação (13h06 UTC)

- 123 migrations aplicadas, até a 122. Edge Functions publicadas depois do último commit de cada uma.
- Cron com 6 tarefas e zero falhas em 24 h. O `dispatcher-whatsapp` leva 28 ms em média (p95 44 ms).
- Fila do `pg_net` vazia. Banco com 33 MB de 500 MB.
- Advisors sem item novo.

## Achados e dono

| # | Nível | Achado | Dono e quando |
|---|---|---|---|
| 1 | **P0** | As versões das migrations 116–122 estão até 30/10, à frente da data real (25/10). Uma migration criada pelo `migration new` antes de 31/10 cairia antes delas e quebraria o CI e o `db push`. **Regra até 31/10:** a versão vai à mão, maior que `20261030120000`. | dev-banco, já |
| 2 | P1 | Não há chave composta `(conta_id, id)`: o banco aceita uma escala da conta 1 com local da conta B; só as funções recusam. Faltam a restrição única `(conta_id, id)` nas tabelas de origem e as chaves compostas (`not valid` e depois `validate`; `on delete set null (coluna)` nas 5 que zeram). | arquiteto-dados, F2f-2a |
| 3 | P1 | **Resolvido na 128 (27/10):** espelho de 50 funcionários × 1 mês de 14,3 s para 0,22 s. O espelho do ponto levava 447–491 ms por técnico por mês. `fn_ponto_jornada_dia` e `fn_ponto_marcacoes_efetivas` rodam centenas de vezes e não são incorporadas à consulta (`set search_path`). A prévia da folha de 200 técnicos ficaria perto de 90 s. | arquiteto-dados + dev-banco, antes do 2º cliente |
| 4 | P1 | Backup sem os arquivos do Storage e sem o banco da Evolution. As cópias ficam só no GitHub, por 30 dias. | po-plataforma, decisão do responsável |
| 5 | P1 | Sem lugar para restaurar num desastre: o plano gratuito permite 2 projetos e os dois estão em uso. | CTO, decisão do responsável |
| 6 | P1 | Servidor da Evolution (Oracle, 1 GB) é ponto único de falha, roda a versão `2.4.0-rc2`, e o tempo de volta não foi medido. | arquiteto-cloud |
| 7 | P1 | A produção está na Vercel Hobby, que proíbe uso comercial (decisões 29 e 110). Falta uma data para sair. | CTO, decisão do responsável |
| 8 | P1 | O conector do Cloudflare está sem permissão de leitura de Workers e Builds (403). | responsável |
| 9 | P2 | `fn_conta_atual()` dentro do SQL em 60 lugares roda uma vez por linha: 371 ms contra 28 ms. A correção é guardar numa variável ou usar `(select fn_conta_atual())`. | dev-banco, na próxima migration de cada família |
| 10 | P2 | Filtro do acompanhamento do ponto sem faixa de índice: 115 ms e 6.766 buffers. Com a faixa em `momento`, 14,7 ms e 667 buffers. | dev-banco |
| 11 | P2 | 8 chaves estrangeiras sem índice (ponto, cargas); 57 índices só em `conta_id`, com pouca seletividade, a trocar por compostos. | arquiteto-dados, F8 |
| 12 | P2 | Versões soltas: ações do `ci.yml` por etiqueta, Deno `v2.x`, wrangler fora do lock, Node 20 no doc contra 22. CLI do Supabase 2.118 contra 2.122. | arquiteto-cloud, um PR só |
| 13 | P3 | `fn_herdar_conta` converte a linha inteira em JSON: +3 ms em linha com PDF de 1 MB. A ordem dos gatilhos depende do nome. | arquiteto-dados |
| 14 | P3 | Falta alerta de saldo baixo na Twilio. O `docs/arquitetura.md` ainda fala em PostgreSQL 15. | po-plataforma |

## Plano da F2f-2 (decisão 114), proposto pelo arquiteto-dados

- **F2f-2a**, pode ir antes da F3: restrições únicas `(conta_id, id)` e chaves compostas validadas.
- **F2f-2b**, uma migration com `lock_timeout`:
  - gravar a conta de forma explícita onde hoje ela depende do default: `webhook_eventos`, `log_exclusoes`
    (`fn_remover_escala`), `painel_mfa_log`, `painel_usuarios` e o espelho da 116 (F3), `ponto_acessos`
    anônimo e o teto em `alertas_enviados`;
  - `ponto_motivos` e feriados nacionais passam a ser da plataforma;
  - tirar o default das 57 tabelas e apagar a trava.
- **Tempo estimado na produção:** abaixo de 1 s, sem bloquear leitura na validação.
- **Teste:** um T63 com a conta B passando por cada caminho, e o T56 exigindo pelo catálogo que nenhuma
  coluna `conta_id` tenha default.

## Antes do 2º cliente, lado do banco

1. **F4:** feriado por UF e município ligado ao local (hoje a chave é só a data) e `config_conta`.
2. **F6:** CPF, CNPJ e e-mail únicos por conta. O telefone só depois da F5, porque o webhook acha o técnico
   por ele. Numeração de pedidos e documentos por empresa.
3. Desempenho do espelho (achado 3).
4. **F8:** índices que faltam, exportação por conta e encerramento com anonimização. O ponto é imutável e tem
   guarda de 5 anos.
