# Decisões de arquitetura

Registro do que foi decidido, quando e por quê — inclusive o que foi descartado.

## 1. Regra de negócio no banco, não no painel

**Decisão:** toda regra em SQL (views e funções); o painel só chama funções.
**Por quê:** permite trocar de painel sem reescrever regra — o que de fato aconteceu na migração
do Retool para o Vercel. Mudanças de regra entram sem deploy.
**Custo:** quem mantém precisa saber SQL; depurar PL/pgSQL é mais chato que depurar TypeScript.

## 2. Supabase no lugar do n8n

**Decisão:** `pg_cron` + `pg_net` + Edge Function, sem orquestrador externo.
**Por quê:** o n8n era o único item pago (~R$ 130/mês) de uma stack que precisava custar zero.
**Descartado:** n8n Cloud (pago) e n8n auto-hospedado (servidor a manter).

## 3. Evolution API no lugar da API oficial da Meta

**Decisão:** Evolution API em VPS própria.
**Por quê:** decisão do cliente, com VPS já disponível.
**Ressalva registrada:** a Meta custaria cerca de R$ 8 a R$ 11 por mês para o volume atual,
sem risco de banimento e com botões garantidos. A Evolution usa biblioteca não oficial, o que
viola os termos do WhatsApp e expõe o número a bloqueio.
**Mitigações:** chip dedicado, no máximo 3 tentativas, envios espaçados, janela de silêncio.

## 4. Botões com resposta numérica junto

**Decisão:** enviar botões e, no mesmo texto, "responda 1 ou 2".
**Por quê:** na Evolution 2.3 os botões chegavam como "visualização única" e não abriam no
celular. Na 2.4 passaram a funcionar. Como isso pode quebrar de novo numa atualização do
WhatsApp, o caminho numérico sempre acompanha. `usar_botoes` desliga os botões sem deploy.

## 5. Envio em duas fases

**Decisão:** marcar `enviada` só depois de conferir a resposta da Evolution.
**Por quê:** o dispatcher anterior marcava como enviada antes da confirmação e o painel mostrava
"notificada" para mensagens que tinham falhado com erro 400.

## 6. Painel próprio no Vercel em vez do Retool

**Decisão:** React + Vite publicado no Vercel.
**Por quê:** o Retool travou em três limites — créditos de IA para qualquer alteração, código
somente leitura e teto de 5 usuários no plano gratuito.
**Ressalva registrada:** o plano Hobby do Vercel é restrito a uso não comercial pela definição
da própria Vercel, que considera comercial qualquer projeto produzido por funcionário pago.
O Cloudflare Pages não tem essa cláusula.

## 7. Jornada calculada, sem campo de duração

**Decisão:** o término vem da CLT, a partir da hora de início.
**Por quê:** evita que cada escala tenha uma duração digitada à mão, e garante coerência entre
o que o técnico recebe e a jornada legal.
**A validar:** a regra deve ser confirmada pelo RH. Não é parecer jurídico.

## 8. Exclusão definitiva apaga o histórico

**Decisão:** excluir técnico remove escalas, mensagens e auditoria dele.
**Por quê:** "removido" significa removido, e atende pedido de exclusão de dados pessoais.
**Travas:** não exclui quem tem escala aberta, nem o último supervisor ativo; exige digitar o
nome para confirmar; registra em `log_exclusoes`.

## 9. Cancelada libera o horário

**Decisão:** índice único parcial ignorando `cancelada`.
**Por quê:** escala cancelada não ocupa mais o horário do técnico.
**Em aberto:** escalas `recusadas` ainda bloqueiam o horário.

## 10. Validade só onde faz sentido

**Decisão:** o controle de vencimento vale para NRs, CNH e ASO; habilidades técnicas não expiram.
**Histórico:** a validade foi removida por completo na migration 21 e retomada com essa regra na 22.
**Como funciona:** `habilidades.exige_validade` liga a cobrança da data no cadastro e a classificação
em válido, vence em breve (30 dias), vencido e sem data. Toda segunda às 8h os supervisores recebem
a lista pelo WhatsApp.

## 11. Excluir habilidade exige confirmação em duas etapas

**Decisão:** excluir do catálogo é recusado quando a habilidade está em uso; o usuário precisa
marcar "excluir mesmo estando em uso" para prosseguir, e aí as atribuições e requisitos vão junto.
**Por quê:** apagar uma NR usada por 20 técnicos por engano é caro de reconstruir. Desativar
continua sendo o caminho recomendado.

## 12. Permissões concedidas por laço, não por lista

**Decisão:** ao fim de cada migration, revogar tudo e conceder `execute` percorrendo todas as
funções com prefixo `app_`.
**Por quê, na primeira vez:** a migration 26 usou lista manual e esqueceu 34 funções, derrubando o
acesso ao painel com "Sem permissão para esta ação".
**Por quê, na segunda:** a verificação do Supabase no GitHub reexecuta todo o histórico num banco
vazio. Listas fixas citam a assinatura que existia no dia — e `app_criar_escalas` mudou duas vezes
(ganhou `p_tipo` e depois `p_teste`). No banco real nunca quebrou, porque cada migration rodou
sobre o estado daquele momento; no replay, quebrava. Todas as listas antigas foram convertidas
para o laço.
**Regra:** nenhuma migration deve citar assinatura de função num `grant`.

## 13. Escala sempre no futuro

**Decisão:** a escala precisa começar no mínimo 5 minutos à frente, validado no banco e na tela.
**Por quê:** escala no passado não é enviada pelo motor (a view só considera escalas futuras) e
ficava presa no painel sem explicação.

## 14. Escala de teste

**Decisão:** escala marcada como teste funciona por completo, fica fora de todos os indicadores e
pode ser removida a qualquer momento, mesmo depois de entregue e respondida.
**Por quê:** homologar o fluxo de ponta a ponta sem sujar estatística. Escala de técnico com
perfil de teste já nasce marcada.

## 15. OCR sugere, pessoa confirma

**Decisão:** a leitura automática preenche o campo de validade, mas o salvamento exige
confirmação humana.
**Por quê:** uma data errada lida de um ASO vencido cria falsa conformidade — pior que campo
vazio. Também por isso PDF não é lido automaticamente em vez de arriscar leitura ruim.

## 16. OCR roda no navegador, não na nuvem

**Decisão:** o padrão é tesseract.js no navegador; o Google Vision fica como botão opcional.
**Por quê:** documento pessoal (ASO, CNH) não sai da máquina de quem cadastra, o custo é zero de
verdade e não exige conta de faturamento — o Google pede cartão mesmo na cota gratuita.
**Custo:** primeira leitura baixa ~12 MB de motor e idioma, e cada leitura leva de 2 a 8 segundos
contra menos de 1 na nuvem. Para ler datas, a precisão se mostrou suficiente.

## 17. Documento no Drive é vínculo, não cópia

**Decisão:** o modo Drive guarda só o link; o arquivo permanece no Google Drive da empresa.
**Consequência registrada:** o controle de acesso passa a ser do Drive e a retenção de 5 anos vira
manual. Para documento pessoal, o modo bucket continua sendo o recomendado.

## 18. Leitura de PDF em duas etapas

**Decisão:** tentar primeiro o texto embutido no PDF e só recorrer ao OCR quando não houver.
**Por quê:** PDF gerado por sistema (a maioria dos ASO e certificados de NR) tem o texto dentro do
arquivo — ler dali é instantâneo e sem erro, enquanto o OCR levaria segundos e poderia errar.

## 19. Sessão expira em 30 minutos e deploy recarrega o painel

**Decisão:** inatividade de 30 min encerra a sessão; publicação nova recarrega o navegador aberto.
**Por quê:** painel em operação fica aberto em computador compartilhado, e tela antiga conversando
com banco novo produz erro difícil de diagnosticar. O `version.json` é gerado no build e comparado
a cada 3 minutos e a cada foco na janela.

## 20. Indicadores contam só escala ativa de campo

**Decisão:** ficam fora das contagens as canceladas, as de teste, os técnicos de homologação e os
supervisores.
**Por quê:** supervisor é administração do sistema, não produção de campo; cancelada não ocupa o
técnico; e escala de teste existe justamente para não sujar estatística.

## 21. Habilidade e documento são entidades diferentes

**Decisão:** `habilidades` guarda o que o técnico sabe fazer e nunca vence; `tipos_documento`
guarda NR, CNH e ASO, que vencem e podem bloquear a atividade.
**Por quê:** misturar os dois num catálogo só com a marca "exige validade" confundia a tela e
obrigava a inventar situações ("habilidade vencida") que não existem no mundo real.
**Efeito colateral bom:** a aptidão passou a distinguir os motivos — "sem a habilidade", "nível
abaixo", "documento vencido", "documento não cadastrado".
**Migração:** os dados existentes foram convertidos na migration 36, sem perda.

## 22. Atribuição de habilidade mora no cadastro do técnico

**Decisão:** o submenu "Por técnico" saiu; marcar habilidades passou a ser parte de editar o
técnico.
**Por quê:** era uma tela a mais para fazer o que já se está fazendo ao cadastrar alguém.

## 23. Classificação de documento por nome, depois por conteúdo

**Decisão:** no envio em lote, o tipo é deduzido primeiro do nome do arquivo e só depois do texto
lido; a palavra-chave mais específica ganha (`nr-35` antes de `nr-3`).
**Por quê:** o nome é instantâneo e costuma bastar; ler o conteúdo de 30 arquivos leva minutos.
**Limite aceito:** nada é enviado sem conferência humana na tabela de revisão.

## 24. Dado novo só depois da tela que o suporta

**Decisão:** nunca inserir no banco um valor que o painel publicado não saiba exibir.
**Por quê:** a migration 38 criou os grupos `seguranca` e `saas` e inseriu 32 itens antes de a
versão 3.1 do painel estar no ar. A aba Roadmap procurava a etiqueta do grupo, não encontrava e
quebrava a tela inteira. Os itens foram movidos para `backlog` com prefixo no título até o deploy.
**Prevenção aplicada:** o painel passou a tratar grupo desconhecido como "Outros" em vez de falhar.

## 25. Hora da escala é local e se compara com hora local

**Decisão:** `data_servico + hora_inicio` é comparada com `now() at time zone fn_config('fuso')`,
calculado uma vez por consulta.
**Por quê:** a comparação com `now()` tratava a hora local como UTC. Escala marcada para as 3
horas seguintes nunca era enviada, e lembretes e alertas paravam 3 horas antes (migration 39).
**Descartado:** função auxiliar chamada por linha: correta, mas dobrava o tempo do motor (146 ms
contra 71 ms com um ano de dados), porque função com `search_path` fixo não é expandida na view.
**Longo prazo:** guardar o início como `timestamptz`.

## 26. Sem microserviços; o provedor de WhatsApp vira adaptador

**Decisão:** o núcleo continua no banco. O único componente a separar é o envio de mensagens:
uma fila de saída no banco e uma Edge Function que fala com o provedor.
**Por quê:** microserviços trariam rede, autenticação entre serviços e deploys coordenados sem
ganho no volume atual (consultas de 8 a 76 ms com um ano de dados). Já o formato da Evolution
embutido no SQL tornaria cara a migração para a API da Meta.
**Quando:** junto com a migração para a Meta. Análise completa em
[analise-topologia.md](analise-topologia.md).

## 27. Produção só muda por migration, e é conferida contra o repositório

**Decisão:** nenhuma alteração direta no banco de produção. Divergências são detectadas por uma
consulta que compara a estrutura da produção com a do repositório, só lendo definições.
**Por quê:** a fase 6 do motor foi aplicada direto na produção e ficou fora do repositório. Quem
recriasse o motor a partir do repositório desligaria as ligações sem perceber. A comparação de
26/09 mostrou que essa era a única divergência real (migration 40).
**Complemento:** o `plpgsql_check` encontrou duas funções que usavam uma coluna removida. Rodá-lo
depois de cada migration pega esse tipo de erro antes da produção.

## 28. Backlog direto na produção; o resto passa pela homologação

**Decisão:** registros do backlog vão direto para a produção, numerados em sequência única (001,
002...) pelo próprio banco. Qualquer outra mudança é aplicada primeiro na homologação, testada, e
só vai para a produção com o comando do responsável, pelo `scripts/aplicar-producao.sh`.
**Por quê:** o backlog é registro de trabalho, não parte do sistema: não há o que testar antes. Já
banco, painel e Edge Functions afetam a operação. O script mantém o histórico de migrations da
produção igual ao do repositório; aplicar por outro caminho gravaria outra versão e quebraria o
próximo `db push`.
**Numeração:** quem já tinha número manteve; os itens sem número foram numerados na ordem do id,
por escolha do responsável. O número deixou de ser digitado. Quem cria não escolhe, e o número não muda depois
(migration 43), para que "item 017" signifique sempre a mesma coisa.

## 29. Nenhuma assinatura paga

**Decisão:** o sistema roda só em planos gratuitos. O que o plano gratuito não oferece é resolvido
com alternativa gratuita ou sai do plano.
**Substituições:**
- Proteção contra senha vazada (paga no Supabase): senha mínima de 12 caracteres e consulta à base
  pública Have I Been Pwned feita pelo painel, sem enviar a senha.
- Backup com restauração (pago no Supabase): cópia diária criptografada pelo GitHub Actions, com
  teste mensal de restauração num banco temporário.
- Vercel Pro (o gratuito proíbe uso comercial): Cloudflare Pages gratuito.
**Fora do escopo desta regra:** serviços cobrados por uso, sem assinatura, que o sistema já usa ou
planeja usar (ligação pela Twilio, mensagens pela API oficial da Meta). Cada um é decidido à parte.

