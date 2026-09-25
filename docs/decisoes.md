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
**Por quê:** a migration 26 usou lista manual e esqueceu 34 funções, derrubando o acesso ao painel
com "Sem permissão para esta ação". Com o laço, função nova nasce liberada para usuário logado e
nada do schema fica aberto ao público.

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
