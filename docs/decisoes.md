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

## 45. WhatsApp em dois canais no SaaS: Evolution e API oficial da Meta

**Decisão (responsável, 01/10):** complementa a decisão 33. Na operação da Infoxtec, o canal continua
sendo a **Evolution**, e o responsável aceita o risco (biblioteca não oficial, possibilidade de
bloqueio do número). Quando o Trilha virar SaaS, ele **nasce com os dois canais prontos e integrados**,
Evolution e API oficial da Meta, e **cada cliente escolhe** qual usar, com ciência e aceite registrados do
risco da Evolution.
**Consequência:** o envio precisa de uma camada de canal por cliente (hoje `fn_evo_post` é a porta
única); entra junto com o multi-tenant (backlog 029). Backlog 027 e 023 deixam de ser "migração" e
passam a ser a fase SaaS. O custo da API da Meta é do cliente que a escolher.

## 46. Identidade da marca Trilha

**Decisão (responsável, 04/10):** assinatura *Trilha. Cada passo conta.*; grito de campanha *Trilha em
campo, operação em dia.*; logo com o sinal **∴** em três pontos (verde, azul e amarelo) à esquerda, o
nome em **Montserrat** azul `#2563eb` e o **check verde** depois do nome, sem sombra, borda nem caixa.
A chamada para ação segue em definição. Detalhes e razões em `docs/marca.md`.
**Consequência:** o painel (3.7.0) usa a logo e a assinatura. A fonte é servida pelo próprio painel
(`web/public/fontes/`), sem chamada ao Google Fonts: nenhum dado do usuário vai a terceiro só para
desenhar o nome. Frase de marca nova só entra no repositório depois de aprovada pelo responsável.

## 47. Papéis dos agentes no banco (cenário A)

**Decisão (responsável, 05/10):** o **DeepSeek Harness não executa SQL em banco nenhum**, nem
consulta, e todo pacote dele só segue com a **validação e a revisão do Claude** no pull request. O
**Claude Code** continua como no `CLAUDE.md`: aplica na homologação pelo script, roda o
`plpgsql_check` e grava na produção só o backlog. Merge e produção são do responsável.
**Por quê:** o incidente de 28–29/09 (decisão 44) mostrou o custo de dois agentes mexendo no banco
por caminhos diferentes; concentrar a homologação num agente só mantém o histórico de versões igual ao
repositório. Protocolo em `docs/equipe.md`.

**Atualizado em 05/10, por autorização do responsável:** o DeepSeek **pode consultar** os bancos —
leitura, para diagnóstico — e continua **proibido de alterar** qualquer coisa, em qualquer ambiente.
A leitura é sempre dentro de uma **transação somente-leitura** (`begin read only; … rollback;`), que é
o próprio banco impondo o limite, e não a disciplina do agente. Duas medições de 05/10 ficam
registradas porque a primeira tentativa não funcionou: `PGOPTIONS='-c
default_transaction_read_only=on'` **não** é respeitado (a sessão abriu com
`default_transaction_read_only = off`), enquanto `begin read only` devolve
`transaction_read_only = on`. Seguem proibidos: escrever, alterar estrutura ou função, `migration
repair`, `db pull` e despejar dados. Em produção, a leitura continua só de metadado — **dado de
técnico não se lê** — e a alteração é do responsável, pelo script.

## 48. Módulo Registro de Ponto (Trilha Ponto)

**Decisão (responsável, 06/10):** o Trilha ganha o módulo de ponto eletrônico, **vendável**, começando
pela avaliação na Infoxtec. Enquadramento pretendido **REP-P** (Portaria MTP 671/2021), a confirmar
no parecer jurídico. **App web** é o canal principal, **WhatsApp** complementar e **URA** só de
contingência. Hora do servidor; **localização obrigatória** no momento da marcação, conferida contra a
área do local, que **sinaliza e nunca bloqueia**; **sem selfie nem biometria**. Marcações **só de
inclusão**, NSR por empresa, guarda de 5 anos fora de qualquer limpeza. Login do funcionário com
sessão única. Tabela de **empresas (CNPJ)** desde já; separação por cliente (074) antes do primeiro
cliente externo. Mesmo banco e mesma Evolution. Custos aprovados: INPI, e-CNPJ, número de entrada da
Twilio. Nenhuma promessa comercial sem lastro ("homologado pelo MTE" não existe para software).
**Consequência:** plano, parte legal e aviso de privacidade em `docs/modulo-registro-de-ponto/`;
backlog 075 a 089; etapas 26 a 31 do plano de trabalho. Supera a opção de só integrar (backlog 4).

**Limite conhecido do canal WhatsApp (07/10, revisão da migration 56):** o ponto recusa lugar escolhido no mapa (com nome ou endereço) e localização encaminhada, mas não detecta GPS falso, WhatsApp modificado nem alfinete arrastado e enviado sem nome. Mitigação: conferência pela área do local, precisão guardada na marcação e sinalização ao gestor; o app web segue como canal principal.

## 49. API do funcionário no app do ponto: funções `ponto_*`

**Decisão (Claude, dentro do plano aprovado em 06/10; a confirmar pelo responsável no PR #56):** o
funcionário não é usuário do painel nem do Supabase Auth. Ele entra no app do ponto com **CPF + código
de 6 dígitos** (WhatsApp; contingência: código gerado pelo gestor) e recebe um token de sessão que só
existe no aparelho — o banco guarda o hash. **Sessão única**: login novo encerra a anterior; validade
de 12 horas. A API dele é uma família própria, **`ponto_*`**, executável pelo papel `anon`, e toda
função valida o token na primeira linha (`fn_ponto_sessao`) e tira o funcionário da sessão, nunca de
parâmetro. Pedir código e entrar respondem igual com ou sem cadastro, código errado, vencido ou
bloqueio (não revelam quem é funcionário). Limites (revisão do `seguranca`): códigos por WhatsApp — 3
a cada 15 min e 6 por dia por funcionário, 10 pedidos por IP na hora e teto total por hora
(`config.ponto_max_codigos_hora`); login — trava por funcionário, 5 erros vencem o código, 10 erros na
hora bloqueiam o funcionário (o código do gestor destrava), 20 por IP e teto total
(`config.ponto_max_erros_hora`). **Login pelo código do gestor fica marcado** na sessão, em cada
marcação (`origem.login_origem`) e no comprovante, e o funcionário é avisado pelo WhatsApp. O CI
confere que só `ponto_*` abre para `anon` e que toda `ponto_*` valida a sessão.
**Consequência:** o bloco de permissões por laço do `CLAUDE.md` ganha a segunda volta (`ponto_*` para
`anon` e `authenticated`). Migration que usar o bloco antigo derruba o app do ponto — o CI e a revisão
do Claude conferem.

## 50. Bairro e cidade das marcações pelo OpenStreetMap (Nominatim), não pelo Google

**Data:** 08/10/2026. **Contexto:** o responsável pediu bairro e cidade de cada marcação, a partir da
latitude e longitude, no Registro de Ponto. **Decisão:** geocodificação reversa no banco, pelo
**Nominatim (OpenStreetMap)**: gratuito, sem cartão e sem chave, com dados ODbL que podem ser
guardados com atribuição. O Google Geocoding foi descartado: exige conta de faturamento com cartão e
os termos proíbem guardar o resultado por mais de 30 dias. **Como:** `ponto_geo` guarda bairro e
cidade por coordenada **arredondada em 3 casas (~110 m)** — só isso sai do banco, sem nome, CPF ou
horário (minimização, LGPD); `fn_ponto_geo_processar` faz uma consulta por minuto (política do
Nominatim: até 1 por segundo, User-Agent identificado, cache). A marcação não muda (é imutável).
**LGPD:** a coordenada arredondada, sem identificador e enviada a quem não tem as marcações (a OSMF,
no Reino Unido), é tratada como dado anonimizado (art. 12): a OSMF não tem meio razoável de ligar o
ponto a uma pessoa. O momento da consulta (até um minuto depois da marcação) não acompanha nome nem
CPF. O papel `leitura` não vê bairro nem cidade, como já não via as coordenadas. **Consequência:**
aviso de privacidade menciona a consulta e o país (avisar os funcionários já cadastrados da nova
versão do texto, junto com a revisão do Gabriel); o painel mostra a atribuição do OpenStreetMap. Se o volume passar do razoável para o serviço público, troca-se `geocodificacao_url`
por um Nominatim próprio ou outro provedor, sem mudar o painel.

## 51. Nenhuma função interna executável pelo `service_role`; suíte de regressão no CI

**Data:** 09/10/2026. **Contexto:** reavaliação do pacote de segurança do DeepSeek (08/10), conferida
pelo dev-banco, fullstack e QA: o bloco de permissões revogava de `public`, `anon` e `authenticated`,
mas não do `service_role`, e o Supabase concede execute ao `service_role` em toda função nova. Quem
tivesse a chave `service_role` chamaria `fn_ponto_registrar` (que recebe o funcionário por parâmetro)
ou `fn_segredo`. **Decisão:** (1) o bloco de permissões revoga também do `service_role`; nada
legítimo usa esse papel (painel → `app_*` como `authenticated`, app do ponto → `ponto_*` como `anon`,
Edge Functions, pg_cron e backup → `postgres`); (2) `alter default privileges` faz função nova nascer
fechada (o execute do `public` vem do padrão global do `postgres` e também é revogado); (3)
`supabase/tests/regressao.sql` roda no CI a cada PR, num banco vazio com todas as migrations: permissões
(T1), escala exige local, login e app do ponto, imutabilidade, carga de 2.000 marcações com NSR e
cadeia de hash íntegros, conversa do WhatsApp com 300 mensagens, jornada, webhook e painel.
É defesa em profundidade **nas funções**: a chave `service_role` continuava com acesso total às
tabelas (ignora o RLS) até a migration 63, e segue sendo segredo de nível máximo. **Consequência:** migration nova que esquecer o bloco não abre função; o CI recusa qualquer função
fora de `app_*`/`ponto_*` executável por papel da API. Partes 2 (âncora da cadeia no backup) e 3
(token do webhook no cabeçalho) seguem em PRs próprios. **Parte 2 (09/10):** âncora da cadeia do ponto no backup diário, conferida na restauração (`docs/operacao.md`, Backup). Tabelas e sequências do `public` revogadas do `service_role` (e as sequências também de `anon` e `authenticated`) na migration 63, de 10/10. Pendente (20/10): desativar a chave `service_role` antiga no Supabase, que nada usa.

## 52. Sprint de 13 a 23/10 e as três regras da 084 entrega 2

**Data:** 10/10/2026. **Contexto:** revisão do backlog pelo PO e pelo Scrum Master; sprint aprovada pelo
responsável (`docs/sprint-13-23-out.html`), seguindo a recomendação do time nas três decisões que
bloqueavam a 084 entrega 2. **Decisão:**
- **A. Papel leitura e o espelho de jornada:** vê os totais e os avisos, **sem localização** (coerente
  com a decisão 50: a leitura já não vê coordenadas, bairro nem cidade).
- **B. Aviso ao gestor:** leva o **primeiro nome** do funcionário, nunca o CPF.
- **C. Ajuste de ponto:** lançado por **admin e gestor**, sempre com justificativa; a marcação original
  não muda e o funcionário é avisado do ajuste pelo WhatsApp.
**Consequência:** A e B mudam funções da migration 61 e entram com C na 084 entrega 2 (painel 3.14.0),
com revisão do `seguranca` sobre quem vê o ajuste e por quanto tempo fica guardado (proposta: 5 anos,
como as marcações). *Na implementação (migration 65, revisão do `seguranca` em 10/10):* o motivo
**não deve conter dado de saúde** — o painel orienta "atestado apresentado", nunca diagnóstico, CID ou
doença (minimização, LGPD art. 6º, III); inclusão com hora errada se corrige com outro ajuste que a
desconsidera, porque nada em `ponto_ajustes` se altera ou apaga. Ficam para a revisão de 23/10: repositório público, persona engenheiro-saas,
parecer REP-P (076) e o bloqueio da assinatura da Twilio (prazo 27/10).

## 53. Assinatura da Twilio: ligar o bloqueio por teste controlado, não por espera

**Data:** 10/10/2026. **Contexto:** a etapa 12 (27/09) previa ligar o bloqueio da assinatura
`X-Twilio-Signature` na `voz-escala` depois de 10 ligações reais com "assinatura da Twilio ok", no
máximo em 30 dias (27/10). Em 14 dias houve **zero** ligações: o disparo automático da URA está
desligado, então o critério nunca se cumpriria sozinho, e a URA segue protegida só pelo token da URL.
**Decisão:** trocar a espera por **teste controlado**: duas ligações pelo "Ligar agora" do painel para o
técnico de teste; com "assinatura da Twilio ok" nas duas, ligar o bloqueio
(`TWILIO_ASSINATURA=obrigatoria`) e confirmar com uma terceira ligação. Prazo: até 13/10. Se a
assinatura falhar, corrigir antes de ligar o bloqueio. **Consequência:** o prazo de 27/10 deixa de ser
o limite; a regra geral fica no papel do PO — decisão com os dados disponíveis é tomada na hora, e
critério que depende de evento que não vai ocorrer é trocado por um teste que produza a evidência.
**Revogada em 10/10 pela decisão 54:** o responsável decidiu não ligar o bloqueio.

## 54. URA automática ativada, sem bloqueio da assinatura da Twilio, só em dia útil

**Data:** 10/10/2026. **Decisão do responsável:** (1) **não** ligar o bloqueio da assinatura da Twilio
— a `voz-escala` segue conferindo a assinatura em modo observação (só registra no log) e protegida pelo
`VOZ_TOKEN`; (2) **ativar o disparo automático** da URA (`ligacao_ativa = true`) para ligações reais;
(3) ligações **só em dia útil, das 08:00 às 20:00, nunca em sábado, domingo ou feriado**.
**Como:** migration 64 — tabela `feriados` (nacionais, 2 de Julho, 24/06 e 08/12 de Salvador, Sexta-feira
Santa, e Carnaval e Corpus Christi como ponto facultativo, de 2026 a 2030, editável) e a regra única
`fn_ligacao_permitida()`, aplicada ao disparo automático (`vw_ligacoes_pendentes`) e ao "Ligar agora"
(`fn_preparar_ligacao`); a `voz-escala` só disca uma ligação recém-criada, uma vez, e no horário
permitido. **Risco aceito pelo responsável** (achados S4, S5 e S9 de `analise-seguranca.md`): sem o
bloqueio, a URA fica protegida só pelo `VOZ_TOKEN`, que viaja na URL de cada chamada e aparece no
console e nos registros da Twilio (quem tem acesso à conta Twilio ou a esses registros o vê). Com ele,
alguém poderia chamar `?acao=digito` e **registrar confirmação ou recusa de escala em nome do
técnico** — exatamente o que a assinatura bloquearia. O abuso de custo (repetir `?acao=iniciar` com um
id antigo) foi fechado nesta mesma entrega. **Revisão:** no próximo rodízio do `VOZ_TOKEN` ou se
aparecer `assinatura da Twilio invalida` no log com ligações legítimas fora do esperado. **Também:**
escala de segunda-feira antes das 08:00, notificada na sexta à noite, não recebe ligação (o primeiro
horário permitido já é depois do início); feriados a partir de 2031 precisam ser incluídos antes do fim
de 2030.

## 55. Justificativa de ponto pelo funcionário: abono como registro próprio

**Data:** 11/10/2026. **Contexto:** planejamento com o time todo (PO, CTO, `seguranca`, `marca`) do
pedido do responsável — o funcionário justifica falta, atraso ou falha no registro pelo WhatsApp
(palavra *ajuste*) ou pelo app (aba Ajuste), e o gestor aprova ou nega. Análise e textos em
`docs/modulo-registro-de-ponto/justificativas.md`. **Decisão (todas as recomendações do PO
aprovadas pelo responsável):** ausência ou atraso aprovado vira **abono** (`ponto_abonos`, só
inclusão), nunca marcação; falha de registro aprovada vira `ponto_ajustes incluir` ligado ao pedido;
o espelho passa a mostrar falta (dia com escala e sem marcação) e abonado. Menu em dois níveis com 4
opções (Saúde, Família, Convocação, Ponto); limite legal em tabela editável por empresa, que **alerta
e nunca bloqueia**; atestado depois de 48 h aceito como "fora do prazo"; declaração de comparecimento
abona só o horário; comprovante opcional em Ponto e obrigatório nas faltas; reincidência só como fato.
Entregas: E1 (Ponto, sem dado de saúde) na sprint de 13 a 23/10; E2 (saúde, família, convocação, com
anexo); E3 (reincidência e alertas).

## 56. Anexo de justificativa: cofre criptografado, só visualização dentro do sistema

**Data:** 11/10/2026. **Decisão do responsável:** o documento da justificativa (atestado, certidão,
convocação) fica num **repositório secreto e criptografado**, visto **só por pessoa autorizada**,
**dentro do sistema**, para aprovar ou negar — nunca impresso nem baixado. **Como:** o arquivo é
cifrado no banco (chave no Vault, nunca no repositório nem no navegador), em tabela com RLS e sem
políticas, sem Storage e sem chave secreta nova (coerente com a decisão 51); entra no backup
criptografado e é apagado junto com o funcionário e ao fim da guarda (5 anos). Quem vê: usuário do
painel com a permissão **"vê saúde"**, dada por nome pelo admin (fecha a consequência 3 da decisão
39); o papel `leitura` nunca vê motivo de saúde nem anexo. Visualização por uma função `app_*` que
confere a permissão e **registra cada acesso**; o painel mostra o documento numa área de
visualização sem botão de baixar ou imprimir, com marca d'água (nome de quem vê, data e hora).
Sem OCR e sem CID. **Limite técnico, registrado:** nenhum sistema impede foto da tela; a marca d'água
e o registro de acesso tornam o vazamento rastreável.

## 57. Texto da justificativa sem ameaça de punição

**Data:** 11/10/2026. **Decisão do responsável**, seguindo o time: justa causa e desídia (CLT 482)
**não aparecem** no WhatsApp nem no app. O aviso legal diz só que falta ou atraso sem justificativa
pode ser descontado, conforme as regras da empresa. Medida disciplinar é ato do empregador e cabe no
regulamento interno.

## 58. Seguir sem o parecer do advogado, com consultor jurídico de apoio

**Data:** 11/10/2026. **Decisão do responsável:** seguir com a justificativa de ponto, inclusive até a
produção, **sem esperar** as respostas do Gabriel (076). Criada a persona **`juridico`**
(`.claude/agents/juridico.md`, `.dsh/skills/juridico/`): perfil de advogado trabalhista e cível, com
domínio da CLT, da Constituição e de convenções coletivas, que confere base legal, prazos e textos.
**Limite registrado:** é uma persona de IA, sem inscrição na OAB; não assina parecer nem substitui o
advogado da empresa. **Risco aceito pelo responsável:** valor legal errado na tabela de motivos ou texto
impreciso ao funcionário. **Mitigação:** os valores ficam em `ponto_motivos` (corrigir é dado, não
código), o sistema alerta e não bloqueia, e as perguntas seguem para o Gabriel quando ele puder
responder.

## 59. Texto livre do pedido de ajuste: guarda e descarte

**Data:** 11/10/2026. **Contexto:** revisão do `seguranca` da migration 66 (P2). A observação do
funcionário e a resposta do gestor em `ponto_justificativas` são texto livre: mesmo com o aviso "não
escreva doença nem CID", podem conter dado de saúde, e a resposta vai pelo WhatsApp. **Decisão:**
finalidade — registrar e decidir o ajuste de ponto (Portaria 671; base legal: obrigação legal e
exercício de direitos, LGPD art. 7º II e VI); quem vê — admin e gestor (o papel `leitura` não vê);
guarda — **5 anos depois da decisão** (prescrição trabalhista), como as marcações; descarte — a linha
não se apaga (trilha do ajuste), mas `observacao` e `resposta` são **anonimizadas por update** ao fim da
guarda (o gatilho `fn_ponto_justificativa_guarda` permite só isso num pedido decidido). O executor do
descarte entra com a rotina de guarda do cofre de anexos (E2, decisão 56); o primeiro texto vence em
10/2031. No painel, o campo da negativa avisa que o texto vai ao funcionário pelo WhatsApp.
**Decisão 56, implementação (11/10, migration 68):** pgcrypto AES-256 com chave `COFRE_PONTO` gerada no próprio banco
e guardada no Vault; permissão `ve_saude` em `painel_usuarios`; visualização em canvas com marca d'água
de quem vê, sem botão de baixar e com a impressão bloqueada enquanto o documento está aberto; foto
reduzida e regravada no aparelho (sai a localização da foto). **Consequência operacional:** a chave
precisa de cópia fora do Supabase (`docs/operacao.md`), senão um backup restaurado não abre os
documentos. Mídia pelo WhatsApp fica para a E2b; até lá, Saúde, Família e Convocação são pelo app, e foto ou
arquivo mandado pelo WhatsApp é recusado e não fica no log do webhook. **Da revisão do `seguranca`:** pedido com
documento (saúde, família e convocação) só é decidido por quem tem "vê atestados e documentos" — o
repositório é visto só por pessoa autorizada, como pedido; o código do motivo de saúde sai mascarado;
cada concessão da permissão fica registrada; documento enviado por engano ou a pedido do titular é
descartado pelo painel, ficando a marca. **Limites registrados:** "sem baixar" é dissuasão (o conteúdo passa
pelo navegador de quem vê, e a tela pode ser fotografada); a limpeza dos dados da foto é feita no app —
quem contornar o app pode enviar PDF ou JPEG com metadados.

## 60. Atestado com validade: sem ponto e sem escala no afastamento

**Data:** 11/10/2026. **Decisão do responsável:** o atestado tem **validade obrigatória** ("válido até").
Do primeiro dia até a validade, o funcionário **não marca ponto** (app, WhatsApp, qualquer canal) e **não
recebe escala**, salvo se passar por nova avaliação médica e der entrada no **atestado de aptidão (alta
médica)**, que encerra o afastamento na data da alta. **Como (migration 69):** `fn_ponto_afastado_ate`
(atestado pendente ou aprovado, sem alta posterior); gatilho em `ponto_marcacoes` recusa a marcação;
gatilho em `escalas` recusa criar ou mover escala para o técnico afastado; o motor (WhatsApp e URA) não
envia nem liga para escala já existente no período, e os supervisores são avisados das escalas a
substituir ("afastado", nunca o motivo); o app mostra o afastamento e desliga os botões. Atestado negado
deixa de bloquear. **Risco aceito pelo responsável:** a Portaria MTP 671/2021 trata de restrição à
marcação de ponto; bloquear a marcação no afastamento pode ser questionado em fiscalização. A
alternativa (alertar sem bloquear) foi levantada e não escolhida. **Revisão:** parecer do advogado (076).

## 61. Documento da justificativa também pelo WhatsApp, direto ao cofre

**Data:** 11/10/2026. **Contexto:** a decisão 56 levou o documento só para o app, e o WhatsApp recusava
foto e arquivo. Muitos funcionários usam só o WhatsApp. **Decisão (E2b, aprovada pelo responsável):** o
pedido de ajuste no WhatsApp aceita Saúde, Família e Convocação e pede a foto ou o PDF na última etapa.
**Como (migration 70):** o arquivo só é aceito nessa etapa; a Edge Function `webhook-evolution`, que até
aqui só repassava, passa a baixar o arquivo da Evolution quando o banco pede (`ponto_baixar_midia`),
tira os metadados da imagem e entrega ao banco, que confere o tipo pelos bytes e cifra no cofre. O log
do webhook continua sem mídia (lista de chaves da migration 68); a chave da mídia não é guardada; o
texto ao funcionário diz só "Saúde". **Limites aceitos:** o arquivo passa pelo WhatsApp (Meta) e pela
Evolution antes do cofre, como a foto que hoje vai ao celular do gestor; a remoção de EXIF vale para JPG
e PNG (PDF vai como veio, com o tipo conferido pelos bytes; o painel desenha em canvas, sem executar
nada do PDF nem oferecer download); o aviso de escalas aos supervisores, só no atestado, deixa deduzir
que foi saúde — aceito, porque precisam remanejar. **Condição para a produção (revisão `seguranca`,
P2):** conferir que a Evolution não guarda a mídia (`S3_ENABLED` desligado, `WEBHOOK_BASE64` desligado,
o que `DATABASE_SAVE_DATA_NEW_MESSAGE` grava) e desligar o download automático de mídia no celular da
empresa; se algo guardar, definir a limpeza e o prazo aqui. **Conferido em 11/10 (responsável, opção A
com o CTO):** download automático de mídia desligado no celular da empresa e atestados já baixados
apagados; no servidor em execução, `DATABASE_SAVE_DATA_NEW_MESSAGE=false` e `S3_ENABLED` e
`WEBHOOK_BASE64` ausentes (desligados por padrão), igual a `infra/evolution/docker-compose.yml`. Nada no
sistema depende de mensagem guardada na Evolution. **Revisão:** quando sair a API oficial (decisão 33)
ou ao trocar a configuração da Evolution.

## 62. Timbre com registro e QR de verificação no documento do cofre

**Data:** 12/10/2026. **Pedido do responsável:** além da marca d'água, um timbre com QR, número de
registro sequencial e data e hora do envio, para comprovar a autenticidade. **Decisão (PO e `seguranca`):**
o QR comprova o **registro**, não o atestado: prova que o sistema recebeu *aquele arquivo*, *naquela
hora*, sem alteração (SHA-256 gravado no recebimento e conferido a cada abertura). A emissão do documento
se confere com quem o emitiu; o timbre diz isso. **Como (migration 71, painel 3.18.0):** número de registro
**por empresa, sem lacuna** (contador na mesma transação do documento), código de verificação aleatório de
16 caracteres (80 bits, não dá para adivinhar nem percorrer), registro imutável que sobrevive ao descarte.
Timbre e QR são desenhados **só na tela**, por cima da imagem: o arquivo do cofre não muda, porque mudar
quebraria a prova de integridade. O QR leva ao próprio painel (`/?verificar=código`), **com login**: mostra
registro, pedido, recebimento, canal e integridade, nunca o documento; motivo de saúde só para quem vê
atestados; cada conferência fica registrada; só admin e gestor conferem (minimização: o QR lido quase sempre
vem de uma foto da tela, e o registro da conferência com a marca d'água ajuda a achar quem vazou); até 20
conferências por minuto por usuário. **Limite assumido (revisão `seguranca`):** o SHA-256 fica no mesmo
banco do arquivo: detecta alteração acidental ou fora do sistema, não quem administra o banco; prova contra
o próprio administrador pede carimbo de tempo de terceiros (RFC 3161), com custo, a decidir. A conferência
vale para o arquivo guardado, não para a foto ou cópia em mãos de quem confere. **Guarda:** registro e
conferências seguem a guarda da justificativa (5 anos, executor pendente no plano). **Não escolhido:**
página pública de verificação (exporia dado de saúde de um empregado a quem tivesse a foto do QR).

## 63. Print de tela no cofre: dificultar e rastrear, não bloquear

**Data:** 12/10/2026. **Pedido do responsável:** impedir o print de tela do documento do cofre no Windows
e no Mac (o teste mostrou que a captura funcionava). **Fato técnico:** uma página no navegador não consegue
impedir a captura do sistema operacional (PrintScreen, Win+Shift+S, Cmd+Shift+3/4/5, ferramentas de
terceiros) nem a foto com o celular; nenhum navegador oferece isso. **Decisão (painel 3.19.0):** dificultar
e rastrear: (1) termo de sigilo antes de abrir; (2) documento oculto quando a janela perde o foco, quando o
cursor sai dela, quando a aba fica escondida e ao apertar teclas de captura (PrintScreen, Win/Cmd, Shift
com Ctrl ou Alt), e só volta com um clique; (3) fechamento automático em 3 minutos; (4) a marca d'água com
usuário, data e hora e o registro de cada abertura continuam sendo o controle que identifica quem vazou.
**Limite aceito:** a captura feita no instante exato de uma tecla que o sistema não repassa ao navegador
(ex.: PrintScreen no Windows) e a foto com celular passam. **Bloqueio real, a decidir (custo):** (a)
aplicativo de desktop próprio para o cofre, com a janela excluída da captura (`setContentProtection` no
Windows e no macOS); (b) política de DLP/MDM nas máquinas da empresa (ex.: Microsoft Intune/Purview).

## 64. Alta antecipada do afastamento: o gestor registra, com a liberação médica

**Data:** 12/10/2026. **Decisão do responsável (opção A):** o funcionário afastado (decisão 60) que quer voltar
antes da validade do atestado tem a **liberação médica em mãos e fala com o gestor**; o gestor com "vê
atestados e documentos" registra a alta no painel (Registro de Ponto › Ajustes › Afastados agora), anexando
o documento, que vai para o cofre (canal `painel`). A alta já nasce aprovada por quem registrou; o atestado
é abonado até a véspera, como na decisão 60. A recusa da marcação (migration 73) e os textos do app e do
WhatsApp passam a orientar assim. O caminho do próprio funcionário (enviar a alta pelo app ou pelo
WhatsApp) continua existindo. **Revisão (opção B, o funcionário envia e o gestor aprova):** quando o modelo
estiver maduro ou quando vier o parecer do especialista de RH, que o **PO busca** (backlog), para decidir
com base em quem conhece a rotina de afastamento e retorno. **Revisão `seguranca` (P3, registrados):** quem
registrou e quem aprovou coincidem por construção (separar quando vier a opção B); o pedido do gestor conta
na cota do funcionário (5 em 24 h, 10 em análise); afastamento de 30 dias ou mais pede exame de retorno
(ASO, NR-7), não só a liberação médica — levar ao `juridico` junto com o parecer de RH.

## 65. Véspera de feriado sem alerta de escala

**Data:** 11/10/2026. **Decisão do responsável:** trabalho em feriado é excepcional; na véspera de feriado
não sai o alerta da escala de amanhã (aviso das 16h e prazo das 18h). Saiu na véspera de 12/10 porque o
alerta só olhava o dia da semana. **Como (migration 75):** `fn_alerta_prazo_escala` consulta a tabela
`feriados` (a mesma da URA, migration 64). Escala para feriado continua podendo ser criada e enviada.
Teste T21.

## 66. Limpeza da estrutura: tarefas obrigatórias conferidas e objetos sem uso removidos

**Data:** 11/10/2026. **Origem:** diagnóstico do DeepSeek (item 3) aprofundado pelo time. **Achado
principal:** a tarefa `limpeza-logs` nunca foi agendada na produção — o histórico do agendador crescia
cerca de 3 mil linhas por dia e o log do webhook passaria do prazo de 30 dias em 21/10. **Decisão do
responsável:** agendar a limpeza (feito pelo responsável em 11/10: tarefa 8, 03:17 em Salvador) e, na migration 76: o Checklist Sistema passa a
apontar tarefa obrigatória faltando; saem 6 objetos sem chamador (conferidos no painel, Edge Functions,
gatilhos, funções e views): `app_config`, `app_documentos_expirados`, `app_salvar_tecnico_habilidade`,
`app_ponto_marcacoes`, `vw_resumo_dia`, `fn_set_ator`. `vw_documentos_expirados` fica (consulta de
retenção da operação). `banco-de-dados.md` ganha o mapa por domínio. **Não feito, de propósito:** índices
sem uso ficam (as tabelas ainda são pequenas e eles sustentam as chaves estrangeiras); colunas e chaves de
`config` sem uso só depois de levantamento uma a uma (remover coluna não tem volta).

## 67. Verificação em duas etapas (MFA) no painel

**Data:** 11/10/2026. **Origem:** backlog 037 (P0): uma senha vazada entregava o banco inteiro, agora
incluindo os atestados do cofre. **Decisão do responsável:** MFA com código de aplicativo autenticador
(TOTP do Supabase Auth), entregue junto com o ajuste de feriado (decisão 65) num pacote pequeno.
**Como (migration 77, painel 3.22.0):** o painel cadastra o aplicativo (QR) e pede o código quando o
usuário tem fator cadastrado; `app_exigir` exige a sessão confirmada (aal2) quando
`config.mfa_obrigatorio = 'true'`. **Nasce desligado:** o responsável cadastra o próprio código, os
demais usuários cadastram, e só então liga a obrigatoriedade — ninguém fica sem acesso. **Perda do
celular:** um administrador remove o fator do usuário no Supabase (Authentication › Users), e o usuário
cadastra de novo. **Também (decisão 65 ampliada):** o painel "Técnicos sem escala" e o alerta deixam de
cobrar escala em feriado e de contar técnico afastado como "sem escala".


## 68. Duas etapas opcional por usuário; teto nos avisos aos supervisores

**Data:** 12/10/2026. **Decisão do responsável:** a verificação em duas etapas fica **opcional por
gestor**: cada usuário ativa ou desativa a sua no topo do painel ("Ativar duas etapas" / "Duas etapas
ativas"); desativar pede um código atual do aplicativo. `config.mfa_obrigatorio` continua `false`; ligá-la segue possível (decisão 67), e aí o botão
de desativar some. Desativar exige a sessão já confirmada com o código (regra do Supabase Auth): quem
só tem a senha não consegue tirar o código de outra pessoa. **Teto (diagnóstico do DeepSeek, item 2):**
a fase 3 do motor avisa no máximo `config.supervisor_avisos_por_execucao` escalas (5) por execução, as
mais antigas primeiro; o resto vai no minuto seguinte (o teto conta escalas: o pico é 5 × supervisores
ativos por minuto; escala que falha não ocupa o teto). Evita rajada no número do WhatsApp depois de uma
queda da Evolution ou do motor (migration 78, painel 3.23.0, teste T24).

## 69. Avisos aos supervisores só da empresa do técnico

**Data:** 12/10/2026. **Origem:** diagnóstico do DeepSeek, item 1; pré-requisito do segundo cliente.
**Decisão do responsável:** seguir agora, num pacote pequeno. **Regra única** (a mesma do ponto desde a
migration 66): o supervisor recebe aviso de técnico da própria empresa; **supervisor sem empresa** recebe
de todas e **técnico sem empresa** avisa todos, até o cadastro estar completo. **Onde (migration 79):**
`fn_avisar_supervisores` (recusa, detalhe, URA — filtra pela empresa do técnico; ganha `p_empresa`), fase
3 do motor, escala de amanhã e documentos a vencer (uma mensagem por empresa, só com os técnicos dela,
quando houver mais de uma cadastrada). **Continuam para todos:** alertas de sistema (motor parado, teto do
app do ponto). **Antes do 2º cliente:** cadastrar a empresa de todo supervisor e técnico — supervisor sem
empresa veria nomes dos dois clientes.

## 70. Cópia cifrada do banco guardada no GitHub (tratamento LGPD)

**Data:** 13/10/2026. **Origem:** pendência da revisão de segurança do PR #3. **Registro:** o backup
diário (`.github/workflows/backup.yml`) leva ao GitHub uma cópia do banco de produção (sem `webhook_eventos`
e sem os arquivos do Storage), com dados
pessoais dos funcionários (nome, telefone, CPF, marcações de ponto e documentos já cifrados no cofre),
**cifrada com `BACKUP_SENHA`** e guardada 30 dias como artefato (âncora do ponto, 90 dias). O GitHub atua
como operador de armazenamento (LGPD art. 39); a medida de segurança é a cifra (art. 46). **Repositório
público:** artefato de repositório público pode ser baixado por qualquer conta do GitHub — por isso a cifra
é obrigatória, a senha fica só no ambiente `producao-backup` (segredo de ambiente, liberado só para a
`main`) e com o responsável, nunca em log, e a restauração mensal
(`restauracao.yml`) prova que a cópia abre com ela. Tornar o repositório privado é a decisão E (21/10).
**Se a senha vazar:** trocar `BACKUP_SENHA`, apagar os artefatos antigos na aba Actions e rodar um backup
novo. Entra no registro de operações de tratamento quando ele for feito (legalização, etapa 26).

## 71. Registro do pacote vai no próprio pacote

**Data:** 13/10/2026. **Decisão do responsável:** plano, README, backlog, sprint e documentação são
atualizados **no mesmo PR** da entrega, antes do merge — nunca num PR depois da produção. O que só se sabe
depois da produção (conferência) é registrado no PR seguinte que já vai abrir, sem PR próprio.

## 72. Gatilho nosso no schema `auth` (registro das duas etapas)

**Data:** 13/10/2026. **Contexto:** backlog 097, migration 82. O registro de quem ativa e desativa a
verificação em duas etapas nasce num gatilho em `auth.mfa_factors`, tabela do Supabase Auth: assim não
depende do painel nem pode ser pulado por quem chama a API do Auth direto. **Cuidados:** é o primeiro
objeto nosso em `auth.*`; o gatilho não lista colunas (não prende `status` a uma migration do Auth), toda a
lógica fica dentro de um bloco que só avisa em caso de erro (nunca barra login nem cadastro) e grava só
e-mail, ação e hora. **Plano B:** se uma atualização do Supabase Auth falhar por causa dele, `drop trigger
trg_mfa_registrar on auth.mfa_factors` (`docs/operacao.md`) — perde-se só o histórico daí em diante.


## 73. Não se envia escala sem local definido

**Data:** 13/10/2026. **Decisão do responsável, sem negociação:** escala sem local definido não é
enviada (a regra já vale desde a migration 57). A pendência P3 "confirmação de escala antiga sem local
diz 'local a confirmar'" fica encerrada sem mudança: não gera valor.

## 74. WhatsApp na venda: o cliente escolhe o canal e assume o risco (G1)

**Data:** 13/10/2026. **Decisão do responsável, que assume o risco e a responsabilidade:** a venda
oferece dois canais e **o cliente decide na contratação**: (1) **Evolution**, com aceite por escrito do
risco de bloqueio do número — adequado a operação pequena (até cerca de 20 funcionários: poucas
mensagens por dia, e o número bloqueado é trocado por um novo rapidamente); (2) **API oficial da Meta**,
com o custo por conversa repassado. A Infoxtec (10 funcionários) segue na Evolution. **Estado real:** o
conector da API oficial **ainda não existe** no produto — é construído quando o primeiro cliente
escolher essa opção; até lá, a proposta diz "sob demanda" (`docs/plano-comercial.md` §3). Complementa a
decisão 33 (que valia só para o uso interno).

## 75. Painel segue na Vercel gratuita até haver demanda (G2)

**Data:** 13/10/2026. **Decisão do responsável:** a infraestrutura e a validação seguem na Vercel
gratuita; a migração para o Cloudflare Pages (etapa 17) acontece quando houver demanda comercial — o
painel é estático e não depende do provedor. **A primeira venda exige a migração** (o plano gratuito da
Vercel proíbe uso comercial). Item no backlog, **aguardando aprovação** do responsável,
que quer conhecer a ferramenta antes de validar.

## 76. Multiempresa: estimativa até 30/11/2026 (G4)

**Data:** 13/10/2026. **Decisão do responsável:** o CTO entrega a estimativa da multiempresa (opção B
do `docs/plano-comercial.md` §5, backlog 029, com o 074 como pré-requisito) até **30/11/2026**: esforço em semanas, risco de
segurança e plano de migração. Já preparado: avisos aos supervisores por empresa (decisão 69) e o
Checklist do cadastro sem empresa (migration 80).

## 77. Ajustes de processo do Scrum Master

**Data:** 13/10/2026. Depois da rodada de pacotes de 11 a 13/10: (1) no máximo **2 pacotes abertos**;
item fora da sprint passa pelo PO; (2) **um pacote por PR**, saindo da `main` atualizada, e nunca
force-push em branch com PR aberto; (3) script na produção **só depois de o PR aparecer "Merged"** no
GitHub; (4) teste que depende do relógio usa stub ou fixa a hora dentro da transação.

## 78. Painel gerencial de aderência: critérios da jornada

**Data:** 13/10/2026. **Decisão do responsável:** o gestor mede a aderência da escala e do ponto com
dados (backlog 099; migration 85, painel 3.25.0, aba **Indicadores**). **Escala:** % resolvida pelo
WhatsApp, % que precisou da URA, ligações atendidas, sem resposta e tempo de resposta. **Ponto:** %
de marcações ajustadas, dias e horas abonados, hora extra, desvios por tipo (alertas da CLT) e as
semanas e meses fora da jornada. **Jornada de referência** (CLT art. 58; Constituição art. 7º, XIII):
8 h de segunda a sexta, **4 h no sábado** (44 h na semana); feriado e domingo, 0 (ponto facultativo não
zera). **As 220 h mensais são o divisor do salário (CLT art. 64), não limite de horas trabalhadas** — a
jornada normal de um mês fica perto de 191 h; por isso o mês aparece como **saldo de horas** (trabalhado
menos esperado), não como "acima de 220 h" (revisão do `seguranca`). **Sábado
sem expediente** (sem nenhuma marcação) é **abonado por decisão gerencial interna da Infoxtec**
(`config.ponto_sabado_sem_expediente_abona`, ligada). Sábado com escala e sem marcação continua devido. Abono
lançado desconta do esperado. Cada funcionário conta só entre a admissão e o desligamento. Contam só
semanas inteiras já fechadas; período de até 62 dias, carregado no botão Atualizar. **Só números do conjunto:** nenhum nome de funcionário sai da
função, e o papel leitura vê o mesmo.

## 79. Dossiê de conformidade por local: situação, nunca o arquivo

**Data:** 13/10/2026. **Pedido do responsável** (pacote comercial, backlog 100; migration 86, painel
3.26.0, botão **Dossiê** em Locais). O RH entrega ao cliente tomador, para um local e uma data, cada
funcionário escalado e a situação de cada documento que a atividade exige (`tipo_atividade_documentos`):
**válido, vence em breve** (até `certificacao_aviso_dias`, padrão 30, depois da data), **vencido, sem
validade ou não cadastrado**. A situação é calculada **na data do serviço**, não na de hoje: um ASO que
vence antes da obra já aparece vencido. Funcionário com documento vencido, sem validade ou não cadastrado
sai como **pendente**; escala sem tipo de atividade também (exigência desconhecida: "atividade não informada", nunca apto). **Só a situação:** o arquivo nunca é aberto, anexado nem citado (ASO é dado de
saúde, LGPD art. 11), e o dossiê não traz CPF nem telefone. Entram as escalas do local na data, fora as de
teste, canceladas, recusadas e rascunhos. **Cada geração fica registrada** em `dossie_geracoes` (quem,
local, data, quantos funcionários, quando; só inclusão, sem update, delete nem truncate) e só o número do registro sai
impresso — o e-mail de quem gerou não vai ao cliente. Finalidade: prestação de contas ao tomador (LGPD art.
7º, II e IX); guarda alinhada à dos documentos trabalhistas (5 anos). Papéis admin, gestor e leitura
(gerar só lê e registra; o responsável confirma no teste da homologação se o leitura deve entregar o dossiê). A impressão é do navegador (salvar como PDF); PDF assinado fica para quando um
cliente pedir.

## 80. Demonstração com dados fictícios, só na homologação

**Data:** 13/10/2026. **Pedido do responsável** (pacote comercial, backlog 101). Para mostrar o produto a
um cliente sem expor ninguém real, `./scripts/demo-homologacao.sh criar` monta na homologação uma empresa
fictícia (CNPJ 99.999.999/0001-91) com 10 técnicos de nomes inventados, 5 locais de clientes fictícios e
uma semana de escalas com respostas, ligações da URA e documentos; `apagar` remove tudo. **Nunca na
produção:** o comando só aponta para o projeto de homologação, e o SQL exige `config.ambiente =
homologacao` (migration 39) e nenhuma tarefa no pg_cron — mesmo colado no editor da produção, recusa. **Nada sai para fora:** telefones com DDD 00, que
não existe, e a homologação não tem o motor no cron nem os segredos da Evolution e da Twilio. **Sem CPF:**
os técnicos da demonstração não entram no ponto, porque marcação de ponto é imutável e impediria apagar.
Diferente dos scripts de uma vez só de `supabase/setup/`, este fica no repositório (`supabase/demo/`)
porque é reusado a cada apresentação; o T33 do CI cria e apaga para ele não envelhecer com o esquema.
O `apagar` só remove tipo "(demo)" que nada fora da demonstração usa, e recusa se houver ponto da empresa.
Nomes de locais e clientes inventados, sem lembrar empresa real. Pendente: conferir na Receita que o CNPJ
de exemplo não pertence a empresa ativa (os dígitos precisam ser válidos para o cadastro aceitar).

## 81. AFD do REP-P: primeiro em versão de conferência

**Data:** 13/10/2026. **Pedido do responsável** (F5, backlog 085; migration 87, painel 3.27.0). Sem o
Arquivo Fonte de Dados o Trilha Ponto não se vende como REP-P (Portaria 671, Art. 81). A base é o Anexo V do
texto consolidado (`docs/AFD.pdf`, enviado pelo responsável), que a Portaria 1.486/2022 **revogou**, passando
o leiaute para o portal gov.br (inacessível deste ambiente). Por isso o arquivo sai como **versão de
conferência**: a Andreia confere contra o leiaute vigente antes de valer. **Escolhas a confirmar nessa
conferência:** CRC-16 na variante KERMIT (o anexo não nomeia); hash SHA-256 em hexadecimal minúsculo sobre os
campos 1 a 7 formatados mais o hash anterior; CNO/CAEPF ausente preenchido com espaço; coletor "02" (navegador)
para o app web e "05" (outro) para WhatsApp e URA; gravação igual à marcação (on-line, "0"). **Fica fora
agora:** a linha de assinatura do anexo antigo (o Art. 88 §2º pede CAdES em `.p7s` destacado, com e-CNPJ, após
o parecer L1), o número do INPI (zerado até o registro, backlog 078), os tipos 2, 5 e 6 (entrega 2: precisam
da mesma sequência de NSR das marcações, mudança na `fn_ponto_registrar`) e o AEJ. Só o admin gera, porque o
arquivo tem o CPF de todos; cada geração fica registrada com o sha256. **Nunca confundido com o oficial**
(revisão do `seguranca`): enquanto `config.afd_leiaute_conferido` não for ligada pelo responsável — depois da
conferência da contadora e da assinatura CAdES —, o nome sai com `_CONFERENCIA`; ter o número do INPI não
basta. **LGPD:** base legal é obrigação legal (art. 7º, II; Portaria 671, Art. 81 §2º); `ponto_afd_geracoes`
não guarda CPF e segue a guarda de 5 anos do ponto; o painel avisa para guardar o arquivo baixado em local
protegido e apagar depois do uso. **Desempenho:** o hash encadeia desde a primeira marcação, então o custo
cresce com a história: 4,2 s com 100 mil marcações (homologação, 13/10), dentro do limite de 8 s das chamadas
do painel. Antes de um cliente passar de uns 50 mil registros, guardar o hash do AFD por marcação ou um ponto
de controle (item no plano).

## 82. Espelho de ponto mensal com QR público e assinatura do funcionário

**Data:** 13/10/2026. **Pedido e decisões do responsável:** o documento do ponto vai ao funcionário pelo
WhatsApp, com hash auditável em QR, e ele assina. Documento: **o espelho mensal** (Portaria 671, Art. 84).
Assinatura: **desenho com o dedo e ciência** no app do ponto, já logado pelo CPF e código (assinatura
eletrônica simples, Lei 14.063, art. 4º, I; vale como ciência do funcionário). QR: **conferência pública sem
dado pessoal**. **Parte A (migration 88, painel 3.28.0):** o gestor emite o espelho de um mês encerrado; o
conteúdo fica congelado com SHA-256, número de registro por empresa sem lacuna e código de 80 bits.
Reemissão gera nova versão e marca a anterior como substituída; espelho assinado não é reemitido. O QR leva
a `/v?c=código`, que qualquer pessoa abre sem login (o fiscal, um juiz, o próprio funcionário) e que mostra
só registro, empresa, mês, emissão, integridade e se foi assinado — nunca nome, CPF ou horário. Diferente do
cofre (decisão 62, conferência só com login), porque aqui o documento não tem dado de saúde e a conferência
não revela nada além do que a cópia em mãos já mostra. A função pública é da família `ponto_*`
(executável por `anon`) e entra na lista de exceções à sessão do CI, como `ponto_entrar`. **Limite assumido:**
o hash fica no mesmo banco (como na decisão 62): prova contra alteração fora do sistema, não contra quem o
administra. **Revisão do `seguranca` (aplicada):** o hash é dos bytes exatos guardados em `conteudo_texto`
(forma canônica gravada na emissão, que não depende da versão do Postgres); marcações desconsideradas entram
com a hora da marcação desfeita (Art. 84, V); espelho assinado não é substituído (gatilho, trava na emissão e
uma só versão vigente por mês); assinatura entra inteira ou não entra. **Guarda:** obrigação legal (LGPD art.
7º, II), 5 anos como o resto do ponto; o descarte, quando houver executor, passa por migration própria.
**Requisito da parte B:** o hash da assinatura amarra a versão assinada (SHA-256 do hash do espelho com o PNG,
a hora e a origem), para a assinatura não poder ser transplantada. **Parte B:** envio do link pelo WhatsApp, tela do espelho no app do funcionário, desenho da
assinatura, registro de quando e de qual aparelho, e o espelho assinado para baixar em PDF com o QR.

**Parte B (13/10/2026, migration 89, painel 3.29.0):** o gestor envia o link pelo WhatsApp
(`/ponto?espelho=id`, só para quem tem WhatsApp liberado; a trava da homologação vale). O funcionário entra
no app pelo CPF e código, confere o espelho, desenha a assinatura e marca a ciência; só assina se o hash do
que viu for o da versão vigente. Ficam gravados a imagem (PNG validado, até 300 KB), a hora, o IP e o
aparelho, e o hash da assinatura amarra o hash do espelho, a imagem, a hora e a origem — a conferência
pública diz se a assinatura confere, sem mostrar a imagem. A informação ao titular é dada no momento da
coleta, na própria tela de assinatura. O espelho (assinado ou não) sai em PDF pela impressão do navegador,
com o QR. O gestor vê e imprime o espelho com a assinatura; o papel leitura não. **Revisão do `seguranca`
(aplicada):** as funções do app que abrem o espelho são `volatile` (a sessão grava o último uso; `stable` roda
só leitura no PostgREST); desligado não recebe o link (não entra no app; recebe em papel); envio barrado não
marca enviado, e o gestor pode reenviar um espelho; o PNG é conferido pelos bytes; o hash da assinatura usa IP
e aparelho como texto. **Pendentes (decisão do responsável e do `juridico`):** ~~base legal da origem~~ e ~~HMAC com chave no
Vault~~ resolvidos na decisão 84; testar a impressão de um mês cheio no Chrome e no Safari do iOS.

## 83. Resumo de pagamento no espelho mensal, em horas

**Data:** 13/10/2026. **Pedido do responsável:** o AFD foi validado; o espelho para assinatura deve contar
HE total, 50% e 100%, adicional noturno, horas em débito, horas abonadas e dias com atestado, e trazer um
resumo do que será pago e do que será descontado do funcionário, em horas (HH:MM). **Decisão (migration 90,
painel 3.30.0):** o conteúdo congelado do espelho passa a ter, por dia, a jornada prevista, HE 50%, HE 100%,
minutos noturnos e débito, e no fim um bloco `resumo` com **a pagar**, **a descontar** e **informativo**, mais
sete avisos ao funcionário. Em reais, nada: o valor é da folha. **Critérios (parecer do `juridico`):**
jornada prevista de 8 h de segunda a sexta e 4 h no sábado (decisão 78), domingo e feriado 0, ponto
facultativo é dia útil; HE 50% é o que passa da jornada do dia (art. 59), inclusive além de 2 h, que vira só
contagem de alerta (Súmula 376); HE 100% é todo o domingo e feriado trabalhado (Lei 605/49, art. 9º; Súmula
146); adicional noturno pela hora reduzida de 52'30" entre 22 h e 5 h (art. 73), que também conta na jornada
do dia; débito é falta, atraso e saída antecipada não abonados, com tolerância de 10 min no dia (art. 58, §1º);
atestado de dia inteiro nunca gera débito (o parcial desconta só as horas abonadas); abono separado entre o justificado pelo funcionário e o dado pela empresa
(liberalidade); intervalo não concedido sai a pagar (art. 71, §4º, indenização de 50%); faltas aparecem
como semanas que podem perder o DSR (Lei 605/49, art. 6º), só a contagem; interjornada curta é só alerta;
HE e débito não se compensam (não há banco de horas). **Motivo de saúde fora do documento (revisão do `seguranca`, escolha do responsável):** o espelho é
visto por qualquer gestor, sai impresso para a contabilidade e fica congelado depois de assinado, então não
diz "atestado" (decisão 56): o dia aparece como abono, sem débito, e o resumo conta "dias abonados com
justificativa". A contagem de atestados, inclusive os 15 dias do INSS, fica no módulo de justificativas, para
quem tem "vê atestados". **Limites assumidos:** a jornada só é cobrada a partir da primeira marcação do
funcionário (implantação do ponto no meio do mês, ou quem nunca marcou, não vira débito), mas os dias com
registro antes dela continuam listados; tolerância fixa de 10 min no dia; prorrogação após as 5 h da
jornada noturna não entra como noturna; jornada que cruza a meia-noite fica dividida entre os dois dias;
folga compensatória de domingo ou feriado ainda não é registrada, então o domingo trabalhado sai sempre a
100%; convenção coletiva com percentual diferente não é lida (o aviso diz isso). Espelhos emitidos antes da
migration 90 são cópias congeladas e continuam mostrando os totais antigos. **AFD:** a Andreia validou o
arquivo; `afd_leiaute_conferido` continua `false` até a assinatura CAdES (decisão 81) — ligar é decisão do
responsável. **Pendentes:** ~~folga compensatória~~ e ~~débito em dia útil sem escala~~ resolvidos na decisão 84;
medir a emissão de um mês cheio com muitos funcionários (duas leituras de marcações por dia).

## 84. Respostas do responsável sobre o espelho: débito, folga, base legal, HMAC e AFD

**Data:** 13/10/2026. **Decisões do responsável:**
- **Débito:** dia útil sem ponto é débito do funcionário, com ou sem escala ("pode até ocorrer sem escala,
  mas nunca sem ponto"). É a regra da decisão 83, agora confirmada; segue valendo só a partir da primeira
  marcação do funcionário.
- **Folga compensatória (migration 91, painel 3.31.0):** o gestor lança, em Ponto › Ajustes, a folga de um
  domingo ou feriado trabalhado (`app_ponto_folga_compensatoria`). O dia de folga fica abonado inteiro
  (`ponto_abonos.folga_de` aponta o dia trabalhado) e o domingo ou feriado deixa de sair a 100%: vira
  trabalho comum, e só o que passa de 8 h é HE 50% (Lei 605/1949, art. 9º; Súmula 146). A folga fica a até 6
  dias do trabalho (OJ 410 da SDI-1: repouso depois do 7º dia seguido é pago em dobro), em dia que não é
  domingo nem feriado, até 7 dias à frente, uma por domingo ou feriado, e só se houver trabalho no ponto
  naquele dia. Não conta como abono por liberalidade; o espelho mostra a folga e o dia compensado. O motivo
  `folga_compensatoria` entra no catálogo inativo (o funcionário não pede folga pelo app; o gestor lança).
  **Revisão do `seguranca` (aplicada):** a folga precisa ser descanso de verdade — recusada em sábado sem
  expediente, fora do vínculo e em dia com trabalho no ponto; e o espelho só tira o 100% quando a folga já
  aconteceu sem trabalho (folga futura na emissão mantém o 100%, a favor do funcionário; o gestor reemite
  depois). **Folga retroativa (padrão adotado, o responsável pode afrouxar):** folga passada só até 7 dias
  depois, e nunca em mês com espelho já emitido — para uma falta não virar "folga" semanas depois.
- **Base legal da assinatura:** cumprimento de obrigação legal (LGPD art. 7º, II): o registro de horas
  mensal precisa ser assinado pelo empregado. Fecha a pendência da decisão 82.
- **HMAC (migration 91):** o hash da assinatura passa a ser HMAC-SHA256 com chave `ESPELHO_ASSINATURA` no
  Vault, gerada no próprio banco (nunca no repositório). Quem só altera a tabela não consegue refazer o hash
  de uma assinatura. **Limite assumido:** quem lê o Vault (o administrador do projeto Supabase) ainda poderia;
  a defesa contra ele é a cópia assinada que o funcionário baixa. Cada assinatura guarda a impressão da chave
  (`assinatura_chave`, 8 hexadecimais do SHA-256): restauração sem a chave aparece como "chave indisponível",
  nunca como "assinatura não confere". Procedimento de guarda em `docs/operacao.md`. Não havia espelho assinado em nenhum
  ambiente (conferido em 13/10), então nenhuma assinatura antiga deixou de conferir. **Guardar cópia da
  chave fora do Supabase**, como a do cofre: sem ela as assinaturas não conferem mais.
- **AFD:** segue em versão de conferência na produção até a confirmação do responsável; o uso continua na
  homologação.
- **Pendente (P3 do `seguranca`):** `app_ponto_abonar` não trava a linha do funcionário como a folga; um abono e
  uma folga no mesmo dia, ao mesmo tempo, podem duplicar o abono. Corrigir na próxima migration que tocar o abono.

## 85. O ponto é visto por mês e por funcionário

**Data:** 13/10/2026. **Pedido do responsável (validação de setembro):** marcações, espelho de jornada e
ajustes são filtrados sempre pelo **mês** (e pelo funcionário), nunca por um período de dias: o filtro por dia
induz ao erro, e não existe fechamento que cruze meses. O mês corrente vai até hoje. As datas mostram o dia da
semana. **Decisão (painel 3.32.0):** o filtro "De/Até" da página Ponto vira "Mês"; as funções do banco não
mudam (recebem o primeiro e o último dia do mês). **Validação de setembro (roteiro):** marcações, espelho de
jornada e ajustes OK; AFD em análise; emissão, QR e assinatura ainda por testar.

## 86. Cofre das folhas de ponto assinadas, só para o RH

**Data:** 13/10/2026. **Pedido do responsável:** a folha assinada precisa estar à mão numa ação judicial, num
cofre que só os gestores de RH abrem. **Não há restrição da CLT nem da Portaria 671 para o empregador ver a folha
assinada** — ela é dele e precisa ser apresentada em juízo (Súmula 338 do TST: a prova da jornada é do
empregador). O painel já mostrava a folha no botão "Ver"; o que faltava era guarda e acesso de RH. **Decisão
(migration 92, painel 3.33.0):** permissão "Cofre de folhas assinadas (RH)" por nome, dada pelo admin
(`painel_usuarios.rh_folhas`, com histórico, como o "vê atestados" da decisão 56). A folha **assinada** — com a
imagem da assinatura, o IP e o aparelho — só abre para quem tem a permissão; admin e gestor sem ela veem só a
situação ("No cofre do RH"). A folha ainda não assinada continua com admin e gestor. O cofre lista as folhas
assinadas por mês, com **Ver** (imprimir ou salvar o PDF, com o QR e a assinatura) e **Baixar prova**: um arquivo
com os bytes exatos do documento, o SHA-256 guardado e o recalculado, a imagem, a hora UTC, a origem, o HMAC e a
impressão da chave, e se o HMAC confere — para um perito refazer a conta. Cada abertura e cada prova ficam
registradas (`ponto_espelho_acessos`, só inclusão). O documento em si não muda de lugar: continua imutável em
`ponto_espelhos`, com o backup diário cifrado (decisão 51), pelos 5 anos do ponto. **Revisão do `seguranca` (aplicada):** aviso no cofre de que a prova e o PDF têm dados pessoais (guardar só na
pasta do processo, enviar por canal seguro, apagar dos downloads); o aviso de privacidade cobre a extração para
defesa em processo (LGPD art. 7º, VI); a prova não repete o CPF (já está no documento). **Pendentes:** consulta
de quem abriu cada folha (hoje só a contagem); descarte depois dos 5 anos, junto com o resto do ponto.

## 87. "Escala" vira "Programação"; o ponto ganha menu próprio (Gestão de Ponto)

**Data:** 13/10/2026. **Pedidos do responsável (1 e 4; backlog 102 e 103):** a ordem de serviço enviada ao
técnico (dia, hora, local e tarefa) passa a se chamar **Programação** em todo o painel e já nas mensagens do
WhatsApp e da URA. "Escala" fica reservada para a **carga horária** do funcionário (Pedido 2, backlog 104). O
botão azul "+ Nova escala" sai; fica a aba "Nova Programação". O Registro de Ponto sai da Agenda e vira o menu
**Gestão de Ponto**, com abas: Hoje, Marcações, Espelho de jornada, Ajustes e pedidos, Folhas mensais, Cofre
(RH) e AFD (as duas últimas só para quem tem a permissão). **Decisão (migration 93, painel 3.34.0):** só
textos — nenhuma regra, tabela, nome interno ou permissão muda (a tabela continua `escalas`). As 21 funções
do banco com texto ao técnico, ao supervisor ou de erro foram recriadas a partir da definição atual (idêntica
à da homologação, conferida pelo MD5 do corpo) trocando só o que está entre aspas; a marca "Trilha Escala" e
os registros internos ("escala ja respondida") ficam como estão. **Respostas do responsável aos Pedidos 2 e 3**
(escala da empresa, times opcionais, vigência anual, modelos, validação CLT com aceite de risco, limites de HE
pela CLT, alerta crítico no painel e no WhatsApp, limpeza da homologação com carga nova) estão nos itens 104 e
105 do backlog; a implantação é decidida depois desta entrega.

## 88. Escala / Carga Horária: da empregadora, validada pela CLT, com aceite de risco; equipe vira time

**Data:** 13/10/2026. **Pedido do responsável (Pedido 2; backlog 104), respostas de 13/10:** a escala (carga
horária contratual) pertence à empregadora e não se aplica a funcionário de outra; times opcionais, vários por
empresa; prioridade funcionário > time > empresa; vigência com início, anual por padrão; modelos prontos;
validação pela CLT, bloqueando o ilegal e pedindo aceite de risco, assinado no sistema por admin ou gestor, para o
que depende de acordo ou norma coletiva; o campo "equipe" vira time; rodapé dos botões do WhatsApp "Trilha".
**Parecer do `juridico` (decisão 58):** a validação vem da Constituição e da CLT (a Portaria 671 trata do registro,
não dos limites); intervalo de 30 a 59 min só com convenção ou acordo coletivo, nunca individual; turno de
revezamento acima de 8h é bloqueio; o aceite registra a decisão, mas não supre a norma coletiva nem afasta
passivo — e o texto do termo diz isso. **Decisão (migration 94, painel 3.35.0):** tabelas novas `times`,
`cargas_horarias`, `carga_aceites` e `carga_atribuicoes` (RLS sem políticas, acesso só pelas funções). Escala salva
e aceite não mudam (gatilhos); para mudar, cria-se outra escala e atribui-se no lugar, o que preserva o histórico
do que valia em cada data. A validação (`fn_carga_validar`) fica no banco e o painel só mostra a resposta. A
atribuição começa hoje ou depois (não reescreve o passado) e encerra a anterior do mesmo alvo na véspera. O time
é resolvido pelo nome da equipe na empresa do funcionário (gatilho), para a importação e o cadastro continuarem
funcionando como hoje. Cada empregadora ativa recebe a escala da regra atual (44h 6x1, 8h + 4h no sábado), para
nada mudar até alguém atribuir outra. `fn_carga_minutos_dia` dá os minutos contratuais do dia, base do limite de
HE (backlog 105). **Fora desta etapa:** espelho, débito e HE pela escala (etapa 2); aviso de vencimento; menor e
aprendiz e domingo a cada 3 semanas no comércio (o cadastro não tem idade nem setor).
