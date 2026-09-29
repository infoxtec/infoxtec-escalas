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


## 30. Escala encerrada vira concluída sozinha

**Decisão (responsável, 27/09):** escala `confirmada` ou `em_execucao` passa a `concluida` 5 minutos
depois do término previsto (início + jornada + intervalo). Parâmetro `conclusao_automatica_min`.
**Por quê:** escala confirmada ficava "confirmada" para sempre e contaminava os indicadores.
**Como:** fase 7 do motor (`fn_concluir_escalas`), registrada na linha do tempo com o ator
`conclusao_automatica` (migration 45). Escala que ninguém confirmou não é tocada.

## 31. Recusa libera o horário

**Decisão (responsável, 27/09):** escala `recusada` não ocupa mais o horário do técnico. Fecha o
ponto em aberto da decisão 9.
**Como:** o índice único parcial ignora `cancelada` e `recusada`; o técnico que só tem escala
recusada no dia volta para "Técnicos sem escala" e para o alerta das 18h (migrations 45 e 46).
Reabrir uma recusada cujo horário já foi ocupado é recusado com mensagem.

## 32. Documentos disciplinares, CNH e CPF

**Decisão (responsável, 27/09), para as etapas 20 e 21:**
- Suspensão e advertência: só administradores veem; guardadas por 3 anos.
- CNH continua como categoria de documento.
- O cadastro do técnico passa a ter CPF, usado para identificar o técnico nos documentos.
**Consequência:** CPF e registros disciplinares são dados pessoais sensíveis para a LGPD; entram
com acesso restrito por papel e prazo de retenção, e o aviso de privacidade aos técnicos passa a
ser pré-requisito das etapas 20 e 21.

## 33. WhatsApp continua pela Evolution

**Decisão (responsável, 27/09):** o custo por uso da API oficial da Meta não foi aceito; a Evolution
continua. A etapa 22 sai do plano.
**Risco aceito:** a Evolution usa o WhatsApp de forma não oficial; o número pode ser bloqueado.
**Mitigação:** monitor externo (decisão 34), avisos técnicos, e o plano manual de contingência em
`docs/operacao.md`.

## 34. Avisos técnicos por dois caminhos

**Decisão (27/09):** falhas técnicas avisam o responsável por dois caminhos independentes:
1. **WhatsApp, pela Evolution:** motor parado, motor normalizado e banco perto do limite vão aos
   supervisores e aos telefones de `alerta_tecnico_telefones` (David Cerqueira).
2. **Monitor externo gratuito (healthchecks.io), por e-mail e Telegram:** o motor manda um sinal a
   cada minuto; sem sinal (motor parado, Supabase fora ou pausado) ou com sinal de falha (Evolution
   recusando envios), o monitor avisa.
**Por quê os dois:** quando a própria Evolution ou o Supabase caem, o WhatsApp não tem como avisar.
O aviso por WhatsApp no healthchecks.io é pago (decisão 29), por isso e-mail e Telegram.

## 35. Sessão do painel: inatividade medida no navegador, saída só local

**Problema (27/09):** o painel "deslogava sozinho" 3 a 60 segundos depois do login. Os `auth_logs`
mostraram que a saída era pedida pelo próprio navegador. Uma aba do painel esquecida em segundo
plano media a própria inatividade, achava que tinham passado 30 minutos e chamava `signOut()`,
cujo escopo padrão (`global`) encerra a sessão em todas as abas e aparelhos. Reproduzido num
navegador com duas abas.
**Decisão:**
- A inatividade é medida no navegador inteiro: toda aba grava a última atividade em
  `localStorage`, e nenhuma aba encerra a sessão enquanto houver uso em outra.
- O login conta como atividade.
- Toda saída do painel (por inatividade ou pelo botão Sair) usa `scope: 'local'`: encerra só
  aquele navegador. Para derrubar a sessão em todos os aparelhos, um administrador redefine a
  senha do usuário.

## 36. Senha: 8 caracteres, com letras e números

**Decisão (responsável, 27/09):** a senha do painel tem no mínimo 8 caracteres, com letras e
números, configurado nos dois projetos do Supabase. Substitui o mínimo de 12 da decisão 29. A
consulta à base de senhas vazadas (Have I Been Pwned) continua no painel.

## 38. Motivo da recusa por número e edição de escala

**Decisão (27/09, backlog 064 e 065):** depois do "2", o técnico escolhe o motivo por número (1 a 5).
O sistema só pergunta quando ele não tem outra escala aguardando resposta, para o número não ser
lido como 1/2 de outra escala. Editar escala já enviada pede nova confirmação só quando muda data,
hora ou local (responsável, 27/09); mudar a tarefa apenas avisa o técnico.
**LGPD (migration 48):** o motivo "saúde" é dado sensível. É gravado como `saude` para uso
restrito, mas aparece como "Motivo pessoal" no WhatsApp dos supervisores e no painel. Finalidade:
entender recusas e planejar escalas; nunca critério de punição. Retenção: a mesma das escalas.
Edições da mesma escala têm intervalo mínimo de 2 minutos, e escala de teste não avisa o técnico.

## 37. Biblioteca de planilhas guardada no repositório

**Decisão (27/09):** a versão corrigida do `xlsx` (0.20.3) só é distribuída pelo site da SheetJS,
fora do npm. O arquivo oficial foi baixado pelo GitHub Actions e guardado em
`web/vendor/xlsx-0.20.3.tgz`, forma recomendada pela própria SheetJS. O build não depende mais do
site deles. Para atualizar, trocar o arquivo e rodar `npm install file:vendor/<arquivo>`.

## 39. Documento não entra no fluxo da escala; o atestado é do módulo de ponto

**Decisão (responsável, 27/09):** a negação da escala **não pede nem aceita documento**. O técnico
informa o motivo por número (1 a 5) e, se quiser, o detalhe por texto — nada mais. O upload de
**atestado médico, com janela de 48 horas**, é requisito do **módulo de ponto**, que ainda não
começou, e **não** da gestão de escala.

**Por quê:** no momento da recusa o trabalhador não tem documento em mãos. Pedir anexo ali criaria
atrito e um caminho a mais para dado de saúde circular sem necessidade. O atestado pertence ao
registro de jornada, onde a ausência é justificada — não ao planejamento da escala.

**Consequência 1 — não há nada a remover.** Esse fluxo nunca existiu. O que existe hoje é o upload de
NR, CNH e ASO **pelo painel**, feito por admin/gestor (`web/src/lib/api.ts:113`), e a recusa gravando
apenas `ocorrencias.motivo` e `detalhe` (migration 47). A decisão vale como **proibição de construir**:
nem agora, nem quando o módulo de ponto chegar, o anexo entra no caminho da escala.

**Consequência 2 — o que continua aberto não é o fluxo, é o acesso.** O motivo `saude` e os documentos
(NR, CNH, ASO) seguem visíveis ao papel `leitura` — é o achado **SEG-03**, independente desta decisão.
Eliminar o fluxo de anexo **reduz o desenho**, não fecha o vazamento.

**Consequência 3 — o módulo de ponto nasce com um requisito de acesso.** Quando o atestado passar a
ser enviado pelo trabalhador, ele **não pode** cair na visibilidade dos documentos atuais, que é
`admin` + `gestor`: isso daria a qualquer gestor de operação acesso a atestado alheio. O módulo
precisa de uma classe de visibilidade própria (proposta: papel `rh`), que é o mesmo caminho do RBAC
com escopo da etapa de acesso por área. Fica registrado agora para não virar retrabalho depois.

## 40. Não existe motivo de saúde na recusa da escala

**Decisão (responsável, 27/09):** o aceite de escala **não tem motivo de saúde em lugar nenhum**. O
técnico que responde "2" escolhe entre **1 Transporte, 2 Conflito de agenda, 3 Falta de material e
4 Outro**. O valor `saude` sai do enum `ocorrencia_motivo` (migration 49) e o rótulo "Motivo pessoal"
deixa de existir, porque não há mais o que rotular.

**Por quê:** era o único dado de saúde do fluxo de escala, existia apenas para explicar uma recusa e
obrigava a LGPD a acompanhar dado sensível (art. 11) num lugar onde ele não é necessário. Eliminar o
motivo é mais barato e mais seguro do que classificar quem pode vê-lo.

**Consequência 1 — o vazamento do motivo fecha por desenho.** O papel `leitura` deixa de ter qualquer
contato com dado de saúde pela recusa. O achado S1 da análise de segurança deixa de existir.

**Consequência 2 — o atestado fica só no módulo de ponto**, com janela de 48 h e visibilidade própria
(decisão 39). Nada de saúde no caminho da escala.

**Ocorrências antigas:** as que tinham `saude` viram `outro`, com a contagem registrada no log da
migration. Não há exclusão de dado.

## 41. Vínculo de documento por link do Google Drive: descontinuado

**Decisão (responsável, 27/09):** o painel **não oferece mais** a opção de vincular documento por link
do Google Drive. Todo documento passa a ser enviado como arquivo para o bucket privado (PDF, JPG ou
PNG, até 8 MB), aberto por link assinado de 2 minutos.

**Por quê:** no modo Drive o acesso e a retenção saem do controle do sistema — quem manda é a permissão
do Drive, que muitas vezes é "qualquer pessoa com o link". Isso furava as duas promessas do módulo:
acesso restrito por papel e guarda definida.

**Consequência:** `app_registrar_documento` recusa `origem = 'drive'` com mensagem clara (migration 49)
e o botão saiu da tela. **Vínculos já existentes continuam listados e legíveis**, para não sumir com
dado sem decisão — a limpeza desses vínculos é decisão pendente e está no painel (SEG-14).

**Substitui** a decisão 17 na parte do vínculo por link.

## 42. O modo Drive sai do código, não só da tela

**Decisão (responsável, 28/09):** com o arquivo removido do Drive, o vínculo deixa de existir também
na estrutura: a **migration 50** apaga as linhas com `origem = 'drive'` (informando a contagem no log),
recria `vw_documentos_expirados` sem as duas colunas, simplifica `app_registrar_documento`,
`app_excluir_documento` e `app_documentos`, e **derruba as colunas `documentos.origem` e
`documentos.url`**, junto das restrições que as citavam.

**Por quê:** deixar a coluna viva sem uso é o padrão que a própria análise do código apontou como
dívida (12 colunas mortas no tema DEV-10). Uma coluna que existe convida a ser usada de novo por
engano, e a decisão 41 existe justamente para não haver mais esse caminho.

**Plano de volta:** as duas colunas não carregam informação — depois do passo 1, `url` é sempre nula
e `origem` é sempre `'storage'`. Reverter é uma migration que recria as colunas e as funções a partir
da definição da 49. Está escrito no cabeçalho da 50.

**Ordem de aplicação:** o painel que não usa mais os campos é publicado **antes** (merge do pull
request, publica na Vercel) — é a decisão 24 lida ao contrário: campo que sai do banco só sai depois
de o painel parar de pedi-lo. Na prática o painel antigo não quebraria (o teste `d.origem === 'drive'`
simplesmente seria falso), mas a ordem certa é painel primeiro.

## 43. Evolution própria, na Oracle Cloud Always Free

**Decisão (responsável, 28/09):** a Evolution sai do servidor de terceiros (`evo.vluma.com.br`), onde
não havia controle da chave, para um servidor da Infoxtec na Oracle Cloud Always Free (sem custo,
decisão 29). O Linux do Mac continua só para desenvolvimento: produção precisa de máquina ligada
24 h, com IP público.
**Como:** Docker com Evolution, Postgres e Redis internos e Caddy com HTTPS (`infra/evolution/`);
roteiro em `docs/evolution-propria.md`. A Evolution não guarda conversas, contatos nem chats
(minimização). A virada gera chave e token de webhook novos, o que fecha `SEG-01` e `SEG-02`.
**Consequência:** a Infoxtec passa a cuidar do servidor (atualização mensal, versão fixa da imagem);
o monitor externo (`INF-02`) vira pré-requisito prático.
**Como ficou (28/09, executado):** a Ampere A1 estava sem capacidade em São Paulo; o servidor é uma
`VM.Standard.E2.1.Micro` (1 GB), sem Redis e com swap. A v2.3.7 entrega botões como "visualização
única" (decisão 4), então a produção roda a `2.4.0-rc2`, que corrige isso mas **exige ativação de
licença** no Manager (gratuita, confirmado pelo responsável em 28/09). A 2.3.7 ficou no ar
como volta até a consolidação (backlog 073).

## 44. Trava de envio por ambiente, e nenhuma migration fora do repositório

**O que aconteceu (28–29/09):** a trava de ambiente foi aplicada direto nos bancos, sem passar pelo
repositório. Na produção entrou como `20260928235626_39_trava_de_envio_por_ambiente` (o "39" repete o
número de outra migration); na homologação, como `20260929001258_trava_de_ambiente_homologacao`, com
dados próprios daquele ambiente. O `db push` da produção passou a recusar a migration 51 porque o
histórico não batia com o repositório.
**Decisão:** a migration da produção entra no repositório com o conteúdo exato que foi aplicado
(conferido: nenhuma migration posterior redefine as funções que ela troca). A da homologação **não**
entra: ela grava `ambiente = homologacao` e um técnico de teste, e num `db push` para a produção
bloquearia todos os envios. Na homologação ela sai só do histórico (`migration repair --status
reverted`), mantendo os dados.
**O que a trava faz:** `fn_pode_enviar(telefone)` libera tudo quando `config.ambiente = 'producao'`;
em homologação, só técnico com `perfil_teste` ou número em `telefones_homologacao`. `fn_evo_post` e
`fn_preparar_ligacao` consultam a trava antes de enviar ou ligar; `app_config` passa a devolver
`ambiente`.
**Regra reforçada, para o Claude e para o DeepSeek:** estrutura e funções só pelo ciclo do `CLAUDE.md`
— arquivo no repositório, homologação, revisão do `seguranca`, PR, e só então
`scripts/aplicar-producao.sh`. Aplicar SQL direto num banco, mesmo que correto, quebra o `db push` de
todo mundo depois.
