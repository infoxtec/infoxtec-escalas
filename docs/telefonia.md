# Item 2 — Ligação automática para quem não responde

Roteiro de implantação, do trial ao piloto.

## A decisão que mais importa: URA antes de IA conversacional

O pedido original é um agente de IA que conversa. A análise de custo e de risco diz para começar
mais simples:

| Abordagem | Como funciona | Custo por ligação de 40s | Complexidade |
|---|---|---|---|
| **URA com voz sintetizada** | Uma voz lê a escala e pede "digite 1 para confirmar, 2 se tiver problema" | ~US$ 0,044 (**R$ 0,24**) | Baixa |
| IA conversacional | O agente entende a fala, responde, pergunta o motivo | ~US$ 0,09 a 0,15 (R$ 0,50 a 0,80) | Alta |

A URA resolve o mesmo problema porque **o técnico já sabe do que se trata** — ele recebeu a
escala pelo WhatsApp duas vezes. A ligação existe para furar o silêncio, não para conversar.
E o dígito é mais confiável que reconhecimento de fala em obra, com ruído de fundo.

A camada de IA continua no radar: quando a URA estiver rodando, trocar o "digite 2" por "me conte
o que houve" é uma mudança de endpoint, não um novo projeto.

## Fornecedor recomendado para o trial: Twilio

| Fornecedor | Trial | Celular Brasil | Observação |
|---|---|---|---|
| **Twilio** | **US$ 15 de crédito, sem cartão** | US$ 0,0663/min | Melhor documentação; voz em português (Polly Camila) |
| Telnyx | Conta trial + crédito de indicação | US$ 0,08/min com IA incluída | Bom para a fase de IA conversacional |
| Plivo | US$ 5 de crédito | Mais barato nos EUA, pouco vantajoso no Brasil | — |

Com US$ 15 e ligações de 40 segundos, o trial cobre **cerca de 340 ligações** — meses de piloto
sem pagar nada.

### Custo em produção

10 técnicos, supondo 3 ligações por dia útil: ~66 ligações/mês × R$ 0,24 = **menos de R$ 20/mês**.
Some ao WhatsApp e a operação inteira continua abaixo de R$ 30 mensais.

## Antes de começar: duas restrições do trial

1. **O trial só liga para números verificados.** Cada técnico do piloto precisa receber um código
   e confirmá-lo uma vez. Para o piloto com 2 ou 3 pessoas, é aceitável.
2. **Identificação de quem liga.** Comprar um número brasileiro na Twilio exige verificação
   regulatória com CNPJ e endereço, o que leva dias. O atalho é usar **Verified Caller ID**:
   verifica-se um número da Infoxtec e é ele que aparece no celular do técnico. Sem isso, a
   chamada chega como número internacional e quase ninguém atende.

## Roteiro de ações

### Etapa 1 — Conta e verificações (você, ~20 min)

1. Criar conta em `twilio.com/try-twilio`. Não pede cartão.
2. No console, em **Phone Numbers → Manage → Verified Caller IDs**, verificar o número da
   Infoxtec que vai aparecer no visor do técnico.
3. Em **Verified Caller IDs**, verificar também os números dos técnicos do piloto (exigência do
   trial).
4. Copiar **Account SID** e **Auth Token** do painel inicial.

### Etapa 2 — Segredos (você, 2 min)

No Supabase, SQL Editor:

```sql
select vault.create_secret('ACxxxxxxxx', 'TWILIO_ACCOUNT_SID');
select vault.create_secret('seu_auth_token', 'TWILIO_AUTH_TOKEN');
insert into config (chave, valor, descricao) values
  ('twilio_caller_id', '+5571XXXXXXXXX', 'Número que aparece no visor do técnico'),
  ('ligacao_ativa', 'false', 'Liga o disparo automático de ligações'),
  ('ligacao_apos_tentativas', '2', 'Tentativas de WhatsApp sem resposta antes de ligar'),
  ('ligacao_janela_inicio', '08:00', 'Não liga antes disso'),
  ('ligacao_janela_fim', '20:00', 'Não liga depois disso'),
  ('ligacao_max_por_escala', '2', 'Máximo de ligações por escala')
on conflict (chave) do nothing;
```

### Etapa 3 — Implementação (eu, ~1 dia)

1. Tabela `ligacoes`: escala, técnico, telefone, `call_sid`, status, dígito recebido, duração,
   custo, horários.
2. Edge Function `voz-escala`: devolve o TwiML que a Twilio executa e recebe o dígito digitado.
   Protegida por token, como o webhook da Evolution.
3. Função `fn_ligar_escala(escala_id)`: monta o texto, chama a API da Twilio por `pg_net`,
   registra em `ligacoes`.
4. Fase 6 do dispatcher: seleciona quem ligar — escala de amanhã, sem resposta, já com N
   tentativas de WhatsApp, dentro da janela, respeitando o máximo por escala.
5. O dígito 1 confirma a escala no mesmo caminho do WhatsApp; o 2 marca recusa e avisa o
   supervisor; sem resposta, registra e avisa o supervisor.
6. No painel: a linha do tempo da escala passa a mostrar "ligação atendida, digitou 1".

### Etapa 4 — Teste e piloto

1. Ligar para o seu próprio número com `ligacao_ativa = false` e disparo manual.
2. Ajustar velocidade da fala e texto.
3. Uma semana com 2 ou 3 técnicos; medir taxa de atendimento e de confirmação por telefone.
4. Se o número de ligações justificar, aí sim comprar o número brasileiro com a verificação
   regulatória e sair do trial.

## O roteiro falado

Voz **Polly.Camila-Neural**, em português do Brasil, velocidade um pouco reduzida.

> Oi, [primeiro nome]! Aqui é o assistente da Infoxtec, tudo bem?
>
> É sobre a sua escala de amanhã, [dia da semana], às [hora], no [local].
> A gente ainda não recebeu sua confirmação no WhatsApp.
>
> Se estiver tudo certo, digite 1 agora.
> Se tiver algum problema, digite 2 que o supervisor entra em contato.

Sem resposta em 6 segundos, repete uma vez:

> Só pra confirmar: digite 1 se estiver tudo certo com a escala de amanhã, ou 2 se tiver algum problema.

Fechamentos:

| Situação | Fala |
|---|---|
| Digitou 1 | Perfeito, [nome], escala confirmada! Bom trabalho amanhã. Até mais! |
| Digitou 2 | Entendi. Vou avisar o supervisor, ele te liga já já. Obrigado, [nome]! |
| Não digitou nada | Sem problema. Vou pedir pro supervisor te ligar. Até mais! |

Princípios do texto: trata pelo primeiro nome, diz quem está falando na primeira frase, vai
direto ao ponto em menos de 20 segundos, não cobra nem ameaça, e sempre termina com o próximo
passo claro.

## Regras de convivência

- **Só liga depois do WhatsApp**: mínimo de 2 tentativas sem resposta.
- **Janela 08h–20h**, mais estreita que a do WhatsApp.
- **No máximo 2 ligações por escala.** Depois disso o problema é humano.
- **Não grava a ligação** na v1: sem gravação, não há consentimento a colher nem áudio a guardar,
  o que simplifica a LGPD. Se um dia gravar, avisar no início da chamada é obrigatório.
- A ligação **não substitui o supervisor**: o alerta para ele continua existindo.

## Quando reavaliar a IA conversacional

Se o piloto mostrar que muita gente digita 2 e o motivo só aparece depois, aí a IA ganha valor:
ela colhe o motivo na hora. Nesse momento, Telnyx ou Twilio ConversationRelay entram como troca
de camada, aproveitando tudo o que já estiver construído.
