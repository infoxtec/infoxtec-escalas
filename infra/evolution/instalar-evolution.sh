#!/bin/bash
# Roda no SEU Linux. Instala a Evolution no servidor da Oracle, do zero, e deixa o acesso pronto.
# Uso:  bash instalar-evolution.sh IP_PUBLICO CAMINHO_DA_CHAVE [micro|ampere]
# Ex.:  bash instalar-evolution.sh 150.230.10.25 /mnt/mac/Users/david/Downloads/ssh-key-2026-09-28.key micro
set -euo pipefail
IP="${1:?informe o IP publico}"; CHAVE_ORIG="${2:?informe o caminho da chave .key}"; TIPO="${3:-micro}"
AQUI="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$AQUI/evolution-micro.sh"; [ "$TIPO" = ampere ] && SCRIPT="$AQUI/evolution-cloud-init.sh"
[ -f "$SCRIPT" ] || { echo "Nao achei $SCRIPT (deixe os scripts na mesma pasta deste)"; exit 1; }

# 1. chave SSH em ~/.ssh com permissao correta (o ssh recusa chave "aberta")
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp "$CHAVE_ORIG" ~/.ssh/oracle-evolution.key && chmod 600 ~/.ssh/oracle-evolution.key

# 2. atalho: depois disso basta "ssh evolution"
if ! grep -q "^Host evolution$" ~/.ssh/config 2>/dev/null; then
  printf '\nHost evolution\n  HostName %s\n  User ubuntu\n  IdentityFile ~/.ssh/oracle-evolution.key\n  StrictHostKeyChecking accept-new\n' "$IP" >> ~/.ssh/config
  chmod 600 ~/.ssh/config
else
  sed -i "/^Host evolution$/,/^Host /s/^  HostName .*/  HostName $IP/" ~/.ssh/config
fi

echo "== testando acesso"; ssh evolution "echo conectado em \$(hostname)"

# 3. instalar (5 a 10 min)
echo "== instalando (aguarde)"
scp "$SCRIPT" evolution:~/instalar.sh
ssh evolution "sudo bash ~/instalar.sh" || { echo "FALHOU. Ultimas linhas do log:"; ssh evolution "sudo tail -30 /var/log/evolution-instalacao.log"; exit 1; }

# 4. resultado
ssh evolution "sudo tail -3 /var/log/evolution-instalacao.log; cd ~/evolution && sudo docker compose ps --format '{{.Service}}: {{.State}}'"
echo
echo "== CHAVE-MESTRA (guarde no gerenciador de senhas, nao mande por chat):"
ssh evolution "sudo grep AUTHENTICATION_API_KEY /home/ubuntu/evolution/.env"
echo
echo "Manager: https://${IP//./-}.sslip.io/manager   (pode levar 1 min para o HTTPS ficar pronto)"
echo "Proximo passo: parte D do docs/evolution-propria.md (conectar o WhatsApp)."
