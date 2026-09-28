# Evolution própria (servidor da Infoxtec na Oracle Cloud)

Tirar a Evolution do servidor de terceiros (`evo.vluma.com.br`) e colocá-la num servidor seu, com a
chave-mestra sob seu controle. Custo zero: Oracle Cloud **Always Free** (decisão 29). Arquivos
prontos em `infra/evolution/`.

**De quebra, fecha dois temas de segurança:** `SEG-01` (chave da Evolution exposta em 21/09) e
`SEG-02` (token do webhook), porque a virada gera chave e token novos.

| Parte | O quê | Quem | Tempo |
|---|---|---|---|
| A | Criar o servidor na Oracle | responsável | 20 min |
| B | Endereço pelo IP (sslip.io), sem DNS | responsável | 2 min |
| C | Instalar e subir a Evolution | responsável, colando comandos | 20 min |
| D | Conectar o número e testar, **sem mexer no sistema** | responsável | 10 min |
| E | Virada do sistema para a Evolution nova (produção) | responsável | 15 min, depois das 21h |
| F | Desligar a antiga | responsável | 5 min |

---

## A. Servidor na Oracle Cloud

1. Console da Oracle → **Compute → Instances → Create instance**.
2. **Image:** Canonical **Ubuntu 22.04** (ou 24.04).
3. **Shape:** *Change shape* → **Ampere** → `VM.Standard.A1.Flex` com **2 OCPUs e 12 GB** (dentro do
   Always Free; a Evolution usa bem menos).
4. **Networking:** deixe criar a VCN com **IP público**.
5. **SSH keys:** *Generate a key pair* e **baixe a chave privada** (sem ela você não entra no servidor).
6. **Create.** Anote o **IP público**.
7. **Abrir as portas 80 e 443:** na instância → *Subnet* → *Security List* → **Add Ingress Rules**:
   origem `0.0.0.0/0`, TCP, portas `80` e depois `443`.

Se a Oracle disser "out of capacity" para Ampere, tente outra *availability domain* ou mais tarde.

## B. Endereço (sem DNS próprio)

Decisão de 28/09: usar o **IP público da Oracle**, sem subdomínio da Infoxtec por enquanto. Como a
chave da Evolution não pode trafegar sem criptografia, o endereço usa o **sslip.io**, serviço
gratuito que transforma o IP num nome com HTTPS automático:

| IP público da Oracle | Endereço da Evolution |
|---|---|
| `150.230.10.25` (exemplo) | `150-230-10-25.sslip.io` |

Troque os pontos do seu IP por traços e acrescente `.sslip.io`. **Esse é o `DOMINIO` do `.env`** e,
com `https://` na frente, o `evolution_url` da parte E. Nos comandos abaixo, onde estiver
`ENDERECO`, use esse nome.

**Não deixe o IP mudar:** não use *Terminate* na instância. Se possível, em *Networking → Reserved
public IPs*, reserve o IP atual. Se um dia ele mudar, basta trocar o `DOMINIO`, rodar
`docker compose up -d` e atualizar o `evolution_url`.

Confira no seu Linux (deve devolver o seu IP):

```bash
getent hosts ENDERECO
```

Para usar `whatsapp.infoxtec.com.br` no futuro: registro **A** no DNS apontando para o IP, trocar o
`DOMINIO` e o `evolution_url`. Nada mais muda.

## C. Instalar (no seu Linux, entrando no servidor)

```bash
# 1. entrar no servidor (troque o caminho da chave e o IP)
chmod 600 ~/Downloads/ssh-key-*.key
ssh -i ~/Downloads/ssh-key-*.key ubuntu@IP_DO_SERVIDOR
```

Já **dentro do servidor**:

```bash
# 2. liberar 80 e 443 no firewall interno da imagem Ubuntu da Oracle (bloqueia por padrão)
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo netfilter-persistent save

# 3. Docker
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker ubuntu && newgrp docker

# 4. os arquivos do repositório
git clone https://github.com/infoxtec/infoxtec-escalas.git
cd infoxtec-escalas/infra/evolution
cp .env.exemplo .env

# 5. o seu endereço (troque ENDERECO, ex.: 150-230-10-25.sslip.io)
sed -i "s/^DOMINIO=.*/DOMINIO=ENDERECO/" .env

# 6. gerar a chave-mestra e a senha do Postgres (anote a chave no gerenciador de senhas)
sed -i "s/^AUTHENTICATION_API_KEY=.*/AUTHENTICATION_API_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^POSTGRES_SENHA=.*/POSTGRES_SENHA=$(openssl rand -hex 24)/" .env
grep AUTHENTICATION_API_KEY .env     # copie esta chave para o gerenciador de senhas

# 7. subir
docker compose up -d
docker compose ps                    # os 4 serviços "running"
```

O repositório é privado: se o `git clone` pedir senha, use um *Personal Access Token* do GitHub, ou
copie a pasta `infra/evolution` do seu Linux com `scp -i CHAVE -r infra/evolution ubuntu@IP:~/`.

**Conferir:** abra `https://ENDERECO/manager` no navegador. Deve abrir o Manager da
Evolution com cadeado (HTTPS). Entre com a chave-mestra.

## D. Conectar o número e testar (o sistema continua na Evolution antiga)

1. No Manager novo: **Create Instance** → nome **igual ao de hoje** (confira em `evolution_instancia`,
   consulta da parte E), integração **WHATSAPP-BAILEYS**.
2. **Connect** → aparece o QR Code.
3. No celular do número da empresa: WhatsApp → **Aparelhos conectados → Conectar aparelho** → leia o
   QR. O número pode ter até 4 aparelhos: a Evolution antiga continua funcionando.
4. **Teste de envio** para o seu próprio celular (no seu Linux, trocando CHAVE, INSTANCIA e o número):

```bash
curl -s -X POST "https://ENDERECO/message/sendText/INSTANCIA" \
  -H "apikey: CHAVE" -H "Content-Type: application/json" \
  -d '{"number":"5571981776307","text":"Teste da Evolution própria da Infoxtec"}'
```

**Esperado:** a mensagem chega no seu WhatsApp. Até aqui nada mudou no sistema.

## E. Virada do sistema (produção, depois das 21h)

Fora da janela de envio (06h–21h) o motor não manda escala; a virada fica invisível para os técnicos.

**E1. Conferir antes** — SQL Editor da **produção** (`infoxtec-escalas`). Anote o resultado: é o
plano de volta.

```sql
select chave, valor from config
 where chave in ('evolution_url', 'evolution_instancia', 'webhook_url')
 order by chave;
```

*Esperado:* `evolution_url` = `https://evo.vluma.com.br`, a instância de hoje e a URL do webhook no
Supabase.

**E2. Apontar para o servidor novo** — SQL Editor da **produção**:

```sql
update config set valor = 'https://ENDERECO' where chave = 'evolution_url';
select chave, valor from config where chave = 'evolution_url';
```

*Esperado:* uma linha com `https://ENDERECO` (o seu endereço sslip.io).

**E3. Gravar a chave nova no Vault** — no seu Linux, com o script que já existe (a chave é pedida na
tela, sem aparecer, e o script confirma a conexão com a Evolution):

```bash
cd ~/infoxtec-escalas && git pull
./scripts/rotacionar-evolution.sh --conferir
./scripts/rotacionar-evolution.sh --aplicar     # cole a AUTHENTICATION_API_KEY do servidor novo
```

*Esperado:* `connectionState` = `open`. Isso fecha o **SEG-01**.

**E4. Token novo do webhook e reapontar** — SQL Editor da **produção**, os três comandos em seguida
(fecha o **SEG-02**):

```sql
select vault.update_secret(
  (select id from vault.secrets where name = 'WEBHOOK_TOKEN'),
  encode(extensions.gen_random_bytes(32), 'hex')) is not null as atualizado;

select fn_evo_post('/webhook/set/' || fn_config('evolution_instancia'),
  jsonb_build_object('webhook', jsonb_build_object(
    'enabled', true,
    'url', fn_config('webhook_url') || '?token=' || fn_segredo('WEBHOOK_TOKEN'),
    'byEvents', false, 'base64', false,
    'events', jsonb_build_array('MESSAGES_UPSERT', 'MESSAGES_UPDATE')))) as numero_da_requisicao;
```

*Esperado:* `atualizado = true` e um número. Depois, apague a resposta (ela guarda a URL com o token),
trocando `N` pelo número:

```sql
delete from net._http_response where id = N;
```

**E5. Teste de ponta a ponta:** no painel de produção, crie uma **escala de teste** para você mesmo
(técnico com perfil de teste), responda **1** no WhatsApp e confira — SQL Editor da **produção**:

```sql
select recebido_em at time zone 'America/Bahia' as quando, evento, left(resultado, 80) as resultado
  from webhook_eventos order by recebido_em desc limit 5;
```

*Esperado:* um `messages.upsert` novo com a confirmação, e a escala como **Confirmada** no painel.

**Se algo falhar (plano de volta):** grave de volta o `evolution_url` anotado no E1 e rode
`./scripts/rotacionar-evolution.sh --aplicar` com a chave antiga. A Evolution antiga continua
conectada até a parte F, então o sistema volta como estava.

## F. Desligar a antiga (depois de um dia funcionando)

1. No celular: WhatsApp → **Aparelhos conectados** → toque no aparelho antigo (o da Evolution da
   vluma) → **Desconectar**. A partir daqui, **só o seu servidor** fala por esse número.
2. Registre no plano de trabalho e no painel de temas (`SEG-01` e `SEG-02` concluídos).

---

## Como foi instalado (28/09) e lições

- **Servidor:** Oracle São Paulo, `VM.Standard.E2.1.Micro` (1 GB, x86): a Ampere A1 estava sem capacidade.
  Endereço `https://163-176-68-206.sslip.io`, pasta `~/evolution` no servidor (não o repositório).
- **Instalação pelo Linux local:** `bash infra/evolution/instalar-evolution.sh IP CHAVE_SSH micro` (ou
  `ampere`). Ele copia `evolution-micro.sh` (sem Redis, 2 GB de swap) ou `evolution-cloud-init.sh`
  para o servidor e roda. Colar o script como cloud-init no console da Oracle deu erro de formato.
- **Portas:** o assistente de VCN só libera a 22; as regras de entrada 80 e 443 são obrigatórias.
- **Instância:** criar com integração **WHATSAPP-BAILEYS**. O canal "Evolution" do Manager aceita o
  envio, responde `open` e não entrega nada.
- **Pareamento na v2.3.7:** exige `CONFIG_SESSION_PHONE_VERSION` no `.env` (já no `.env.exemplo`) e
  QR Code. Logo depois de conectar, a primeira mensagem pode não sair até a sincronização terminar
  (`recv ... chats` no log); o `stream:error 515` logo após o pareamento é normal.

## Operação do servidor

| Tarefa | Comando (dentro do servidor, em `~/infoxtec-escalas/infra/evolution`) |
|---|---|
| Ver se está no ar | `docker compose ps` |
| Ver erros | `docker compose logs --tail 100 evolution` |
| **Trocar a chave-mestra** | editar `AUTHENTICATION_API_KEY` no `.env`, `docker compose up -d`, e no seu Linux `./scripts/rotacionar-evolution.sh --aplicar` |
| Atualizar a Evolution | trocar `EVOLUTION_IMAGEM` no `.env` por outra versão fixa, `docker compose pull && docker compose up -d` |
| Atualizações do Ubuntu | `sudo apt update && sudo apt upgrade -y`, uma vez por mês |

O monitor externo (`INF-02`, healthchecks.io) passa a ser ainda mais importante: ele avisa se este
servidor cair.
