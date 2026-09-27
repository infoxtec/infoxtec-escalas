# Roteiro de produção (27/09)

Tudo o que precisa ser executado por você para levar à produção o que está pronto na homologação.
Siga as partes na ordem. Cada passo diz **onde** fazer, **o que** fazer e **como conferir**.
Se algo sair diferente do esperado, pare e traga a mensagem completa.

| Parte | O quê | Tempo | Depende de |
|---|---|---|---|
| A | Etapa 7 na produção: alerta de motor parado | 10 min | Nada (a `main` já tem a migration 44) |
| B | Configurações: login da homologação, senha mínima, Retool | 20 min | Nada |
| C | Teste conjunto na homologação do PR #3 | 20 min | Parte B1 (login da homologação) |
| D | PR #3 na produção: migrations 45 e 46, Edge Functions, backup, monitor | 40 min | Partes A, B e C |
| E | Troca da biblioteca de planilhas (`xlsx`) | 5 min | Liberar um endereço de rede |

---

## Parte A — Etapa 7 na produção

O painel 3.3 já foi publicado pela Vercel com o merge do PR #2. Falta o banco.

1. **No Linux**, com o painel local parado (`./scripts/painel.sh parar`):
   ```bash
   cd ~/infoxtec-escalas
   git fetch && git checkout main && git pull
   ./scripts/aplicar-producao.sh
   ```
   O script mostra a lista de migrations. **Só a 44 pode aparecer como pendente** (coluna Remote
   vazia). Se aparecer outra, pare. Estando certo, digite `PRODUCAO`.
2. **No Supabase da produção** (projeto `infoxtec-escalas`) → **SQL Editor** → cole e rode:
   ```sql
   select cron.schedule('vigia-motor', '*/5 * * * *', $$select fn_vigiar_motor()$$);
   ```
   Resultado esperado: um número (o id do agendamento).
3. **Conferir:** abra https://infoxtec-escalas.vercel.app, aperte Ctrl+Shift+R, entre e abra a aba
   **Operação**. O quadro do topo deve estar **verde**: "Motor de envio em dia".

---

## Parte B — Configurações (só cliques)

### B1. Login da homologação (etapa 5)

No Supabase, projeto **infoxtec-escalas-dev**:
1. **Authentication → URL Configuration**
   - *Site URL:* `http://localhost:5173`
   - *Redirect URLs* → **Add URL**: `http://localhost:5173/**` e depois `https://*.vercel.app/**`
   - **Save**.
2. **Authentication → Sign In / Providers** → desligue **Allow new users to sign up** → **Save**.

### B2. Senha mínima de 8 caracteres, com letras e números (etapa 6, decisão 36) — feito em 27/09

Nos **dois** projetos (`infoxtec-escalas` e `infoxtec-escalas-dev`):
**Authentication → Sign In / Providers → Email** → **Minimum password length** = `8` e exigência de letras e números → **Save**.

A outra metade da etapa 6 (recusar senha vazada) já está no painel 3.4.

### B3. Desligar o Retool (etapa 16)

Quem tem acesso ao Retool executa SQL direto na produção.
1. No Retool, apague o *resource* que conecta no Supabase (e os apps que o usam, se não servirem mais).
2. No Supabase da produção → **Project Settings → Database → Reset database password**. Gere uma
   senha nova e **guarde no seu gerenciador de senhas**. A senha antiga, que o Retool conhecia,
   deixa de funcionar. O motor, o webhook e as Edge Functions não usam essa senha e continuam.
3. Na próxima vez que rodar `aplicar-producao.sh`, o CLI pode pedir a senha nova: use a do passo 2.

Faça o B3 **antes** da parte D, porque o backup (D4) usa essa senha.

---

## Parte C — Teste conjunto na homologação (PR #3)

A homologação já tem as migrations 45 e 46 e as Edge Functions novas.

1. **No Linux:**
   ```bash
   cd ~/infoxtec-escalas
   ./scripts/painel.sh parar
   git fetch && git checkout claude/dreamy-lovelace-7cxxih && git pull
   ./scripts/painel.sh iniciar
   ```
   Abra http://localhost:5173: faixa amarela de homologação e **v3.4** no topo.
2. **Técnico que recusou volta para "sem escala":** deixei na homologação uma escala do **Tecnico
   Exemplo** em **30/09 às 08:00, já recusada** (a recusa vem do técnico pelo WhatsApp, por isso não
   há botão no painel). Na Agenda, vá para 30/09: o Tecnico Exemplo aparece em **Técnicos sem
   escala**.
3. **Recusa libera o horário:** crie uma escala para o Tecnico Exemplo em 30/09 às 08:00. **Deve
   ser aceita** (antes dava "conflito: já tem escala nesse dia e horário").
4. **Leitura na nuvem:** em Habilidades → documentos de um técnico, envie uma foto e clique em
   **Tentar leitura na nuvem**. Deve aparecer a mensagem "OCR não configurado" (a homologação não tem
   a chave do Google). Antes, o botão falhava sem mensagem nenhuma.
5. **Senha forte** (precisa do B1): na tela de login, **Esqueci minha senha** com o seu e-mail; abra
   o link recebido e tente a senha `Senha@123456`. Deve ser **recusada** por aparecer em vazamentos.
   Depois use uma senha sua, com 8 caracteres ou mais, com letras e números.
6. **Somente leitura:** entre com um usuário de papel `leitura` e confira que ele não altera nada.

O que eu já testei no banco da homologação (e não dá para ver no painel sem o motor agendado):

| Regra | Resultado |
|---|---|
| Escala que terminou há 3 min | Continua confirmada |
| Escala que terminou há 6 min | Vira concluída, com o registro "conclusao_automatica" na linha do tempo |
| Valor inválido em `config` (texto em número, hora 25:00, fuso inexistente) | Recusado com mensagem |
| Motor parado 12 min | Aviso ao supervisor e ao David, uma vez; aviso de normalizado na volta |
| Banco acima do limite | Um aviso por dia ao David |
| Sinal ao monitor externo | Enfileirado a cada execução; vira `/fail` com 2 falhas seguidas da Evolution |
| Limpeza | Apaga o conteúdo enviado com mais de 90 dias e mantém o recente |
| `plpgsql_check` | Zero erros |

Se tudo passar, me diga **"aprovado"**.

---

## Parte D — PR #3 na produção

### D1. Merge
No GitHub, abra o PR #3. Espere o **CI** ficar verde (quatro verificações; a de "Dependências"
pode ficar amarela até a parte E). Clique em **Merge pull request**. A Vercel publica o painel 3.4.

### D2. Banco
```bash
cd ~/infoxtec-escalas
./scripts/painel.sh parar
git checkout main && git pull
./scripts/aplicar-producao.sh
```
Devem aparecer como pendentes **só a 45 e a 46**. Digite `PRODUCAO`.

### D3. Edge Functions
```bash
npx --yes supabase@2.118.0 functions deploy documento-ocr     --project-ref zpckrxydqqmmcrphrkxz
npx --yes supabase@2.118.0 functions deploy voz-escala        --project-ref zpckrxydqqmmcrphrkxz
npx --yes supabase@2.118.0 functions deploy webhook-evolution --project-ref zpckrxydqqmmcrphrkxz
```
Cada uma termina com `Deployed Functions on project zpckrxydqqmmcrphrkxz`. A opção de login de cada
função vem do arquivo `supabase/config.toml`; não precisa digitar.

### D4. Backup diário
1. No Supabase da produção → botão **Connect** (topo) → **Session pooler** → copie a *URI* e troque
   `[YOUR-PASSWORD]` pela senha do B3.
2. Invente uma senha longa para o backup (seis palavras aleatórias ou 32 caracteres ou mais) e **guarde no
   gerenciador de senhas**. Sem ela, nenhum backup abre.
3. No GitHub → **Settings → Environments → New environment** → nome `producao-backup` →
   **Configure environment**:
   - **Deployment branches and tags** → *Selected branches and tags* → **Add** → `main`.
     Assim só o que está na `main` consegue ler os segredos; um workflow de outra branch não.
   - **Environment secrets → Add environment secret**:
     - `PRODUCAO_DB_URL` = a URI do passo 1
     - `BACKUP_SENHA` = a senha do passo 2

   Não cadastre esses dois como *repository secrets*: esses qualquer branch consegue ler.
4. GitHub → **Actions → Backup da produção → Run workflow**. Deve ficar verde e gerar o artefato
   `backup-producao`.
5. GitHub → **Actions → Teste de restauração do backup → Run workflow**. Deve ficar verde e mostrar
   as contagens de técnicos, escalas e documentos.

Daí em diante roda sozinho: backup todo dia às 03h37 e teste de restauração todo dia 1.

### D5. Monitor externo (e-mail e Telegram)
1. Crie uma conta gratuita em https://healthchecks.io (plano *Hobbyist*).
2. **Add Check** → nome `Motor Infoxtec` → **Period** `1 minute`, **Grace** `5 minutes` → Save.
3. Em **Integrations**, o e-mail já vem ligado. Para receber no celular, adicione **Telegram** e siga
   as instruções (o aviso por WhatsApp no healthchecks.io é pago; o seu WhatsApp já recebe os
   avisos pelo próprio sistema).
4. Copie a **ping URL** do check (começa com `https://hc-ping.com/`).
5. No **SQL Editor da produção**, rode trocando pela sua URL:
   ```sql
   update config set valor = 'https://hc-ping.com/COLE-AQUI' where chave = 'monitor_ping_url';
   ```
6. **Conferir:** em até 2 minutos o check fica verde (*up*) no healthchecks.io. Use **Send test
   notification** para ver chegar no e-mail e no Telegram.

O número 71 98177-6307 (David Cerqueira) já está cadastrado pela migration 45 para receber no
WhatsApp os avisos de motor parado, motor normalizado e banco perto do limite. Para trocar ou
incluir outro número, no SQL Editor da produção:
```sql
update config set valor = '5571981776307,5571999999999' where chave = 'alerta_tecnico_telefones';
```

### D6. Assinatura da Twilio
Nada a fazer agora: a conferência começa em observação. Depois de uns dias de ligações, siga
[telefonia.md → Assinatura da Twilio](telefonia.md#assinatura-da-twilio-etapa-12-2709).

### D7. Conferir na produção
- Painel mostra **v3.4**; login normal; aba Operação verde.
- Numa escala confirmada de hoje, depois do fim previsto + 5 min, o status vira **Concluída**.
- Me avise que terminou para eu marcar as etapas no plano.

---

## Parte E — Biblioteca de planilhas (`xlsx`, etapa 13)

A versão corrigida (0.20.3) só é distribuída pelo site da SheetJS (`cdn.sheetjs.com`), que está
bloqueado na rede do ambiente em que eu trabalho. Duas saídas:

- **Recomendada:** no claude.ai, no menu do ambiente da sessão (barra de título) → **Edit** →
  **Network access**: inclua `cdn.sheetjs.com` nos domínios permitidos. Me avise e eu faço a troca,
  com teste, num PR.
- **Alternativa, no Linux:**
  ```bash
  cd ~/infoxtec-escalas/web
  npm install --save https://cdn.sheetjs.com/xlsx-0.20.3/xlsx-0.20.3.tgz
  npm run build
  ```
  e me avise: eu confiro e subo pelo ciclo normal.
