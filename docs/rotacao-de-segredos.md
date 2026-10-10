# Rotação de segredos

**Por que este documento existe:** entre **21/09/2026 01:31** (migration 07, que criou `fn_segredo`) e
**21/09/2026 19:52:28** (migration 12, que revogou `EXECUTE`), a função que lê o Vault era executável
por `anon` — a chave publicável, que fica no navegador por design. A apuração de **27/09** mostrou que
**uma** credencial esteve de fato nessa janela (`EVOLUTION_API_KEY`, por 3 h 14 min) e que uma segunda
ficou na margem de segundos (`WEBHOOK_TOKEN`). Este é o roteiro para fechar isso.

Quem executa: **o responsável**, no SQL Editor da produção, no painel da Evolution e no console da
Twilio. Nada aqui é migration.

---

## 0. Baseline: quais segredos foram expostos (2 minutos)

```sql
select name,
       created_at at time zone 'America/Bahia' as criado_em,
       updated_at at time zone 'America/Bahia' as atualizado_em,
       case when created_at < timestamptz '2026-09-21 19:52:28+00'
            then 'EXPOSTO — rotacionar'
            when updated_at > created_at
            then 'já rotacionado'
            else 'criado depois da correção' end as situacao
  from vault.secrets
 order by created_at;
```

Se a consulta for negada, o mesmo inventário está em **Project Settings → Vault** no painel.

**Como ler o resultado:** `created_at` anterior a 21/09 19:52 = criado enquanto a leitura do Vault era
pública. `updated_at` maior que `created_at` = já foi trocado alguma vez. **Atenção à ordem do CASE:**
um segredo criado depois da correção e depois reajustado aparece como "já rotacionado" — o que importa
é a data de criação.

### Resultado da apuração — 27/09/2026

| Segredo | Criado (Bahia) | Situação real |
|---|---|---|
| `EVOLUTION_API_KEY` | 21/09 13:38 | **EXPOSTO — rotacionar.** Ficou 3 h 14 min na janela (criado às 16:38 UTC, revogado às 19:52 UTC) |
| `WEBHOOK_TOKEN` | 21/09 16:52 | **Margem de 5,8 segundos** depois do carimbo da migration 12. Rotacionar por precaução (§1) |
| `VOZ_TOKEN` | 23/09 00:15 | Nunca exposto — nasceu dois dias depois da correção |
| `TWILIO_ACCOUNT_SID` | 23/09 01:00 | Nunca exposto; e **não é rotável** (identificador) |
| `TWILIO_AUTH_TOKEN` | 23/09 01:00 | Nunca exposto |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` | — | **Não existem no Vault** (nem o `GOOGLE_VISION_KEY`, porque o OCR na nuvem nunca foi ligado) |

### Conclusão: o resgate é de **dois** segredos

O escopo caiu de "seis credenciais" para **duas**, e as duas são baratas:

1. **`EVOLUTION_API_KEY` — rotacionar hoje.** Foi a única credencial comprovadamente exposta, e o que
   ela dá a quem a tem é mais do que enviar mensagem: é **operar a instância do WhatsApp** (estado da
   conexão, envio e leitura pela API da Evolution). Não há como saber se alguém a leu naquelas 3 h 14;
   há como tornar a leitura inútil.
2. **`WEBHOOK_TOKEN` — rotacionar por precaução.** A margem é de 5,8 segundos contra o **carimbo do
   arquivo** da migration 12 — e o carimbo não é a hora em que ela foi aplicada. Se a aplicação
   demorou alguns minutos, o token ficou exposto nesse intervalo. O custo de rotacionar é de 15
   minutos; o de não rotacionar é uma credencial que permite forjar eventos.

**As demais rotações (§5, §6) deixam de ser resgate e passam a ser higiene e continuidade** — devem
entrar no calendário, não na urgência.

---

## 1. Inventário e o que cada rotação arrasta

Situação apurada em 27/09: **só `EVOLUTION_API_KEY` esteve comprovadamente exposto**;
`WEBHOOK_TOKEN` entra por precaução. Os demais nasceram depois da correção — a rotação deles é
preventiva.

| Segredo | Onde vive | Quem lê | Rotável? | O que pode quebrar |
|---|---|---|---|---|
| `EVOLUTION_API_KEY` | Vault | `fn_evo_post`/`fn_evo_get` | **Sim**, procedimento já documentado | Nada além do envio, se o valor estiver errado |
| `WEBHOOK_TOKEN` | Vault **e** a URL registrada na Evolution | `fn_webhook_evolution` | Sim, em **3 passos** | Entre atualizar o Vault e reapontar a Evolution, o webhook responde 401 e a resposta do técnico se perde |
| `VOZ_TOKEN` | Vault | motor (`net.http_post`) e Edge Function `voz-escala` | **Sim, em 1 passo** (os dois lados leem o Vault) | Ligações em andamento no momento da troca |
| `TWILIO_AUTH_TOKEN` | Vault | `voz-escala` (Basic auth e assinatura) | **Sim**, e a Twilio permite dois tokens ao mesmo tempo | Se `TWILIO_ASSINATURA=obrigatoria`, callbacks assinados com o token antigo falham na janela |
| `TWILIO_ACCOUNT_SID` | Vault | `voz-escala` | **Não** — é identificador, não credencial | — |
| `GOOGLE_VISION_KEY` | Vault (só se o OCR foi ligado) | `documento-ocr` | Sim, no Google Cloud | O botão "leitura na nuvem" |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID` | Vault | **ninguém** (a bancada `fn_teste_wa_*` foi removida na migration 45) | **Apagar** | Nada |
| Senha do banco | gerenciador de senhas | scripts, `psql`, e a cópia de segurança | Sim | **A cópia de segurança para de funcionar até atualizar `PRODUCAO_DB_URL`** |
| `BACKUP_SENHA` | GitHub (environment `producao-backup`) | workflows de backup e restauração | Sim | Trocar **invalida todos os artefatos existentes** (as 30 cópias) |
| `TWILIO_ASSINATURA` | segredo de ambiente da função | `voz-escala` | Não é segredo rotativo: é um **interruptor** (`obrigatoria` ou vazio) | — |
| Chave publicável do Supabase | Vercel + `web/.env.*` + script | painel | Sim (opcional, P2) | Exige atualizar Vercel, os dois `.env` versionados e `scripts/configurar-vercel-homologacao.sh` |

---

## 2. Preparação (20 minutos, sem risco)

1. Rodar o baseline da §0 e **guardar o resultado**.
2. Deixar abertas as abas: SQL Editor da produção, **Manager da Evolution**, **console da Twilio**,
   **GitHub → Settings → Environments → producao-backup** e o gerenciador de senhas.
3. Escolher a janela: **fora do horário de envio (06:00–21:00)** e longe do prazo das 18h. Sugestão:
   21h30 de uma terça.
4. Ter à mão um **técnico de perfil de teste** com WhatsApp para conferir o webhook de ponta a ponta.
5. Conferir que não há ligação em andamento:

```sql
select count(*) as ligacoes_em_curso from ligacoes where status in ('criada','discando');
```

---

## 3. Fase 1 — sem impacto funcional (15 minutos)

**3.1 Órfãos da bancada antiga — conferido em 27/09: não existem no Vault**

Nada a fazer. Se um dia forem criados por engano, o comando é:

```sql
delete from vault.secrets
 where name in ('WHATSAPP_TOKEN','WHATSAPP_PHONE_NUMBER_ID')
returning name;
```

Se a permissão for negada, apague pelo painel (**Project Settings → Vault**).

**3.2 Rotacionar `EVOLUTION_API_KEY`** — tema **SEG-01**. Há script, com ensaio:

```bash
./scripts/rotacionar-evolution.sh --conferir   # estado atual: a chave no Vault e a conexão da Evolution
./scripts/rotacionar-evolution.sh --ensaiar    # troca por um valor de teste, confere e DESFAZ
./scripts/rotacionar-evolution.sh --aplicar    # grava a chave nova (pedida na tela, sem eco)
```

O valor **nunca é impresso**: o script mostra só a **impressão digital** (md5) e o tamanho. A chave
nova é lida com eco desligado, então não fica no histórico do shell nem na lista de processos.

**Por que ensaiar antes.** O `--ensaiar` grava um valor de teste no Vault, lê de volta e faz
`rollback` — e **confere que voltou**, comparando a impressão digital. Se a digital mudar depois do
rollback, ele para e avisa: significa que `vault.update_secret` não é transacional nesta versão, e o
ensaio acabou de evitar uma troca pela metade.

**O que não tem volta.** A chave da instância no Manager é **invalidada** quando você gera outra. Não
existe "restaurar a antiga" — se algo der errado, o caminho é **gerar outra e repetir o `--aplicar`**.
Por isso a janela é curta: gere no Manager e aplique no mesmo minuto.

**Pelo SQL Editor** (se preferir; uma instrução por vez, com limite de espera):

```sql
set lock_timeout = '5s';
set statement_timeout = '30s';

select vault.update_secret(
  (select id from vault.secrets where name = 'EVOLUTION_API_KEY'),
  'COLE_A_CHAVE_NOVA_AQUI') is not null as gravado;
```

**Verificação** (o script faz sozinho): `fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'))`
e a leitura de `fn_http_resposta(<numero>)` — esperado `status 200` e `"state":"open"`. A chave viaja no
**cabeçalho** (`apikey`), não na URL, então a resposta não a carrega; ainda assim, apague o registro
depois de conferir (`delete from net._http_response where id = <numero>;`).

**Ponta a ponta, depois:** envie uma mensagem de teste pelo painel (reenviar uma escala ou "Ligar
agora") e confirme que saiu. É a prova de que a Evolution aceitou a chave nova.

> **Cuidado que não se aplica aqui, mas se aplica ao `WEBHOOK_TOKEN`:** no passo 4.3 a limpeza é
> **obrigatória**, porque a resposta do `/webhook/set/` devolve a configuração gravada — **com o token
> no cabeçalho**. É a diferença entre higiene e vazamento.

---

## 4. Fase 2 — `WEBHOOK_TOKEN` (15 minutos, janela de segundos)

Esta é a única rotação com **três passos que precisam acontecer em sequência rápida**.

**4.0 Guardar o token atual no próprio Vault** (para a volta; nunca copie o valor para fora):

```sql
-- PRODUÇÃO. Esperado: um uuid
select vault.create_secret(fn_segredo('WEBHOOK_TOKEN'), 'WEBHOOK_TOKEN_ANTERIOR');
```

**4.1 Gerar o token novo e gravar no Vault**

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'WEBHOOK_TOKEN'),
  encode(extensions.gen_random_bytes(32), 'hex')) is not null as atualizado;
```

**4.2 Reapontar a Evolution com o token novo** (lê o Vault, então já pega o valor novo)

```sql
select fn_evo_post('/webhook/set/' || fn_config('evolution_instancia'),
  jsonb_build_object('webhook', jsonb_build_object(
    'enabled', true,
    'url', fn_config('webhook_url'),
    'headers', jsonb_build_object('x-webhook-token', fn_segredo('WEBHOOK_TOKEN')),
    'byEvents', false, 'base64', false,
    'events', jsonb_build_array('MESSAGES_UPSERT','MESSAGES_UPDATE')))) as numero_da_requisicao;
```

**4.3 Apagar a resposta dessa chamada** — ela guarda a configuração **com o token**:

```sql
delete from net._http_response where id = <numero_da_requisicao>;
```

**4.4 Verificar de ponta a ponta** (é o teste que vale — não confie no `webhook/find`, que também
devolve o token): peça ao técnico de teste para responder `1` e confira:

```sql
select recebido_em at time zone 'America/Bahia' as quando, evento, left(resultado, 80) as resultado
  from webhook_eventos order by recebido_em desc limit 5;
```

**Esperado:** um evento `messages.upsert` novo, com resultado de confirmação. Se vier vazio, a
Evolution ainda está com o token antigo — repita o 4.2 e confira o webhook no Manager.

**Se der errado:** volte o token guardado no 4.0 e reaponte a Evolution (4.2 e 4.3):

```sql
select vault.update_secret((select id from vault.secrets where name = 'WEBHOOK_TOKEN'),
                           fn_segredo('WEBHOOK_TOKEN_ANTERIOR')) is not null as voltou;
```

**Depois de alguns dias estável** (na sprint de outubro, junto com a remoção do token pela URL em
22/10), apague o segredo guardado:

```sql
delete from vault.secrets where name = 'WEBHOOK_TOKEN_ANTERIOR';
```

---

## 5. Fase 3 — Twilio e voz (20 minutos) · higiene, não resgate

A apuração mostrou que `TWILIO_AUTH_TOKEN`, `TWILIO_ACCOUNT_SID` e `VOZ_TOKEN` **nasceram depois da
correção** — não há exposição a reparar. Esta fase entra no calendário semestral.

**5.1 Rotacionar `TWILIO_AUTH_TOKEN` com dois tokens (sem janela)**

1. No console da Twilio: **Account → API keys & tokens → Auth Token → Create secondary token**.
2. No SQL Editor:

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'TWILIO_AUTH_TOKEN'),
  'COLE_O_TOKEN_SECUNDARIO_AQUI');
```

3. Testar uma ligação manual pelo painel (**Ligar agora** numa escala) e conferir:

```sql
select criada_em at time zone 'America/Bahia' as quando, status, digito, duracao_seg, left(coalesce(erro,'—'),80) as erro
  from ligacoes order by criada_em desc limit 3;
```

4. **Só depois de a ligação funcionar**, promover o token secundário a primário no console da Twilio
   — é o que invalida o antigo.

**5.2 Rotacionar `VOZ_TOKEN`** (passo único: os dois lados leem o Vault)

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'VOZ_TOKEN'),
  encode(extensions.gen_random_bytes(32), 'hex')) is not null as atualizado;
```

Confirme que não há ligação em curso (§2, passo 5) antes de rodar, e verifique com outra ligação
manual pelo painel, como no 5.1.3.

**Atenção:** a URL com o token antigo continua no registro de chamadas da Twilio e no
`net._http_response` das chamadas do motor — não há como apagar o que já saiu; a mitigação é a
rotação em si.

---

## 6. Fase 4 — senha do banco e backup (30 minutos) · higiene, não resgate

A senha do banco **já foi rotacionada em 27/09** (junto com o desligamento do Retool), e `BACKUP_SENHA`
nunca esteve na janela exposta (não vive no Vault). O valor desta fase é **fechar a lacuna do
`PRODUCAO_DB_URL`** e deixar o procedimento escrito para a próxima vez.

**6.1 Senha do banco**

1. Supabase → **Settings → Database → Reset database password**.
2. Guardar no gerenciador de senhas.
3. **Atualizar `PRODUCAO_DB_URL`** no GitHub (environment `producao-backup`) — é o passo que a
   documentação atual **não tem**, e sem ele a cópia de segurança falha em silêncio.
4. Rodar o backup à mão (Actions → *Backup da produção* → Run workflow) e conferir que ele passou.
5. **Testar o webhook e o OCR** logo depois: as Edge Functions usam `SUPABASE_DB_URL`, que a
   plataforma injeta, e **não é certo que ela acompanhe a senha nova**. Se o webhook falhar com erro
   de autenticação, **republicar as três funções**:

```bash
npx supabase functions deploy webhook-evolution --no-verify-jwt
npx supabase functions deploy voz-escala --no-verify-jwt
npx supabase functions deploy documento-ocr
```

**6.2 `BACKUP_SENHA`**

1. Gerar a senha nova e gravá-la **primeiro** no gerenciador de senhas.
2. Atualizar o secret no GitHub.
3. **Manter a senha antiga por 30 dias**, identificada com a data de validade — sem ela, as cópias
   anteriores não abrem.
4. Rodar o backup e o teste de restauração à mão para confirmar.

---

## 7. Fase 5 — registrar (10 minutos)

Preencha e mantenha esta tabela. Ela é o **inventário de segredos** que o bloco 3 de segurança pede e
que hoje não existe.

| Segredo | Última rotação | Responsável | Próxima | Observação |
|---|---|---|---|---|
| `EVOLUTION_API_KEY` | | | 6 meses | |
| `WEBHOOK_TOKEN` | | | 6 meses | apagar sempre o `net._http_response` da chamada |
| `VOZ_TOKEN` | | | 6 meses | |
| `TWILIO_AUTH_TOKEN` | | | 6 meses | usar o token secundário |
| `GOOGLE_VISION_KEY` | | | 12 meses | hoje não existe |
| Senha do banco | 27/09/2026 | | 12 meses | atualizar `PRODUCAO_DB_URL` junto |
| `BACKUP_SENHA` | | | 12 meses | manter a anterior por 30 dias |

Depois de rotacionar, atualize também:

- `docs/seguranca.md` §Segredos — hoje ele lista três itens, omite Twilio, `VOZ_TOKEN` e Google, e diz
  que a senha do banco vive "só no Retool" (desligado em 27/09);
- `supabase/setup/segredos.md`, `twilio.md` e `documentos.md` com o procedimento de **rotação** de
  cada um (hoje só `EVOLUTION_API_KEY` tem).

---

## 8. Melhoria opcional (P2): rotação sem janela no webhook

Hoje o webhook aceita **um** token. Uma migration pequena pode aceitar o atual **e** o anterior
(`WEBHOOK_TOKEN_ANTERIOR`), o que permite trocar sem nenhum segundo de 401 — o mesmo padrão que a
Twilio usa com o token secundário. Vale quando a rotação virar rotina (a cada 6 meses); não é
necessário para a primeira vez.

---

## 9. Checklist final

**Resgate (o que fecha a janela exposta):**

- [x] Baseline rodado em 27/09 — resultado na §0
- [x] Órfãos `WHATSAPP_*` conferidos: **não existem** no Vault
- [ ] `EVOLUTION_API_KEY` rotacionada e envio verificado
- [ ] `WEBHOOK_TOKEN` rotacionado nos 3 passos + resposta com o token apagada + webhook verificado com resposta real

**Higiene (calendário semestral, sem exposição a reparar):**

- [ ] `TWILIO_AUTH_TOKEN` rotacionado com token secundário e ligação verificada
- [ ] `VOZ_TOKEN` rotacionado e ligação verificada
- [ ] Senha do banco rotacionada + `PRODUCAO_DB_URL` atualizado + backup e Edge Functions testados
- [ ] `BACKUP_SENHA` rotacionada (anterior guardada por 30 dias)
- [ ] Tabela da §7 preenchida
- [ ] `docs/seguranca.md` e `supabase/setup/` atualizados
