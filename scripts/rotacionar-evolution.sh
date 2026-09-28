#!/usr/bin/env bash
# Rotaciona a EVOLUTION_API_KEY na PRODUCAO — tema SEG-01 no painel de controle.
#
# Por que existe: esta chave ficou 3 h 14 min exposta em 21/09, quando fn_segredo ainda era
# executavel por anon. Rotacionar e barato; nao rotacionar deixa uma credencial que permite operar
# a instancia do WhatsApp.
#
# Uso:
#   ./scripts/rotacionar-evolution.sh --conferir   estado atual: a chave no Vault e a conexao da Evolution
#   ./scripts/rotacionar-evolution.sh --ensaiar    grava uma chave de teste, le de volta e DESFAZ (nada muda)
#   ./scripts/rotacionar-evolution.sh --aplicar    grava a chave nova (pedida na tela, sem eco) e confirma
#
# O valor nunca aparece: o script imprime so a impressao digital (md5) e o tamanho. A chave nova e
# lida com eco desligado, entao nao fica no historico do shell nem na lista de processos.
#
# Precisa de psql e da conexao da producao em PRODUCAO_DB_URL (~/.infoxtec/producao.env).
set -euo pipefail

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"

ARQ_CONEXAO="${HOME}/.infoxtec/producao.env"
ACESSO="${1:-}"

ajuda() {
  cat <<'FIM'
Rotaciona a EVOLUTION_API_KEY na producao. Tema SEG-01.

Uso:
  ./scripts/rotacionar-evolution.sh --conferir   estado atual da chave e da conexao da Evolution
  ./scripts/rotacionar-evolution.sh --ensaiar    grava uma chave de teste, le de volta e DESFAZ
  ./scripts/rotacionar-evolution.sh --aplicar    grava a chave nova (pedida na tela) e confirma
  ./scripts/rotacionar-evolution.sh --ajuda      esta ajuda

Ordem recomendada: --conferir, depois --ensaiar (prova que a troca funciona e volta atras), e so
entao o --aplicar, com a chave nova gerada no Manager da Evolution na mesma hora.

O valor nunca e impresso: so a impressao digital (md5) e o tamanho.
FIM
  exit 0
}
case "$ACESSO" in
  --ajuda|-h|--help) ajuda ;;
  --conferir|--ensaiar|--aplicar) ;;
  *) echo "Escolha um modo: --conferir, --ensaiar ou --aplicar. Veja --ajuda."; exit 1 ;;
esac

# --- Ferramenta ---------------------------------------------------------------------------------
if ! command -v psql >/dev/null 2>&1; then
  cat <<'FIM'
psql nao esta instalado. Instale com:

  sudo apt update && sudo apt install -y postgresql-client
FIM
  exit 1
fi

# --- Conexao ------------------------------------------------------------------------------------
if [ -f "$ARQ_CONEXAO" ]; then
  # shellcheck disable=SC1090
  source "$ARQ_CONEXAO"
fi
if [ -z "${PRODUCAO_DB_URL:-}" ]; then
  cat <<FIM
Falta a string de conexao da producao. Ela nao fica no repositorio (e segredo).

Pegue em: painel do Supabase -> projeto infoxtec-escalas -> Connect -> Session pooler.
A senha e a do banco, guardada no gerenciador de senhas.

Nao digite a senha em comando nenhum: ela ficaria no historico do shell. Cole a string com o
comando abaixo, que le sem eco e nao guarda o que foi digitado:

  mkdir -p ~/.infoxtec && chmod 700 ~/.infoxtec
  read -rsp 'Cole a string de conexao (nao aparece na tela): ' URL && \
    printf '%s\n' "PRODUCAO_DB_URL='$URL'" > $ARQ_CONEXAO && chmod 600 $ARQ_CONEXAO && unset URL

A string completa (com a senha no lugar de [YOUR-PASSWORD]) esta no painel do Supabase, em
Connect -> Session pooler. Confira a regiao no que ele mostra - nao invente.
FIM
  exit 1
fi

echo "Producao: $(printf '%s' "$PRODUCAO_DB_URL" | sed -E 's#://([^:]+):[^@]+@#://\1:***@#')"
echo

PSQL=(psql "$PRODUCAO_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off -q)
TRAVAS=(-c "set lock_timeout = '5s'" -c "set statement_timeout = '30s'")

# A impressao digital: prova que o valor mudou sem nunca mostra-lo.
DIGITAL="select left(md5(coalesce(fn_segredo('EVOLUTION_API_KEY'),'')),12) from current_schema();"

digital() { "${PSQL[@]}" "${TRAVAS[@]}" -At -c "$DIGITAL"; }

# --- Conferir -----------------------------------------------------------------------------------
conferir() {
  echo "== 1. A chave no Vault =="
  "${PSQL[@]}" "${TRAVAS[@]}" <<'SQL'
select name,
       created_at  at time zone 'America/Bahia' as criada_em,
       updated_at  at time zone 'America/Bahia' as atualizada_em,
       left(md5(coalesce(fn_segredo('EVOLUTION_API_KEY'),'')), 12) as digital,
       length(fn_segredo('EVOLUTION_API_KEY')) as tamanho,
       case when fn_segredo('EVOLUTION_API_KEY') is null then 'NAO EXISTE' else 'ok' end as situacao
  from vault.secrets where name = 'EVOLUTION_API_KEY';
SQL

  echo
  echo "== 2. A Evolution responde com esta chave? (prova de que o estado atual funciona) =="
  local req
  req=$("${PSQL[@]}" "${TRAVAS[@]}" -At -c \
    "select fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'));")
  echo "   requisicao enfileirada: $req (aguardando a resposta...)"
  sleep 4
  "${PSQL[@]}" "${TRAVAS[@]}" -c \
    "select status, left(coalesce(corpo,''), 120) as corpo, erro from fn_http_resposta($req);" || true
  cat <<FIM

   Esperado: status 200 e corpo com "state":"open".
   Se vier 401, a chave do Vault nao confere com a do Manager — resolva isso ANTES de rotacionar.
   Limpe o rastro desta consulta quando terminar:

     delete from net._http_response where id = $req;
FIM
}

# --- Ensaiar (grava, le de volta e desfaz) -------------------------------------------------------
ensaiar() {
  echo "== Ensaio: troca a chave por um valor de teste, confere e DESFAZ =="
  local antes depois
  antes=$(digital)
  echo "   digital antes: $antes"

  "${PSQL[@]}" "${TRAVAS[@]}" <<'SQL'
begin;
\echo '   gravando um valor de teste (nao e a chave real)...'
select vault.update_secret(
  (select id from vault.secrets where name = 'EVOLUTION_API_KEY'),
  encode(extensions.gen_random_bytes(16), 'hex')) is not null as gravado;
select left(md5(coalesce(fn_segredo('EVOLUTION_API_KEY'),'')),12) as digital_durante_o_ensaio,
       length(fn_segredo('EVOLUTION_API_KEY')) as tamanho;
\echo '   desfazendo...'
rollback;
SQL

  depois=$(digital)
  echo
  echo "   digital depois: $depois"
  if [ "$antes" = "$depois" ]; then
    cat <<'FIM'
   ENSAIO SEGURO: o valor voltou ao que era. A troca funciona e o desfazer tambem.
   Pode aplicar quando tiver a chave nova em maos: --aplicar
FIM
  else
    cat <<'FIM'
   ATENCAO: a digital mudou depois do rollback — a troca NAO foi desfeita.
   NAO siga para o --aplicar. Grave de volta a chave antiga no Vault e me avise:
   e sinal de que vault.update_secret nao e transacional nesta versao.
FIM
    exit 1
  fi
}

# --- Aplicar ------------------------------------------------------------------------------------
aplicar() {
  local antes nova confirma
  antes=$(digital)
  echo "Digital da chave atual: $antes"
  echo
  echo "Gere a chave nova no Manager da Evolution AGORA (instancia, nao a global) e cole aqui."
  printf 'Chave nova (nao aparece na tela): '
  read -rs nova
  echo
  if [ -z "$nova" ]; then echo "Nada digitado. Cancelado."; exit 1; fi

  local digital_nova
  digital_nova=$(printf '%s' "$nova" | md5sum | cut -c1-12)
  echo "Digital do que voce colou: $digital_nova"
  if [ "$digital_nova" = "$antes" ]; then
    echo "Essa chave e igual a atual. Nada a fazer."; exit 1
  fi
  echo
  echo "A janela em que a Evolution e o Vault discordam dura o tempo deste comando (segundos)."
  read -r -p "Para gravar no Vault da PRODUCAO, digite ROTACIONAR: " confirma
  [ "$confirma" = "ROTACIONAR" ] || { echo "Cancelado. Nada foi gravado."; exit 1; }

  "${PSQL[@]}" "${TRAVAS[@]}" -v nova="$nova" <<'SQL'
begin;
select vault.update_secret(
  (select id from vault.secrets where name = 'EVOLUTION_API_KEY'),
  :'nova') is not null as gravado;
select left(md5(coalesce(fn_segredo('EVOLUTION_API_KEY'),'')),12) as digital_gravada;
commit;
SQL

  echo
  echo "== Conferindo na Evolution =="
  local req
  req=$("${PSQL[@]}" "${TRAVAS[@]}" -At -c \
    "select fn_evo_get('/instance/connectionState/' || fn_config('evolution_instancia'));")
  sleep 4
  "${PSQL[@]}" "${TRAVAS[@]}" -c \
    "select status, left(coalesce(corpo,''), 120) as corpo, erro from fn_http_resposta($req);" || true
  cat <<FIM

   Esperado: status 200 e "state":"open".
   - Se veio isso, a rotacao terminou. Limpe o rastro: delete from net._http_response where id = $req;
   - Se veio 401, a chave gravada nao e a que a Evolution espera: gere outra no Manager e repita
     o --aplicar. Nao tente "voltar a antiga": ela ja foi invalidada no Manager.
   - Depois, envie uma mensagem de teste pelo painel (Ligar agora / reenviar) para fechar o teste
     de ponta a ponta.

   Registre a data no inventario: docs/rotacao-de-segredos.md §7.
FIM
}

case "$ACESSO" in
  --conferir) conferir ;;
  --ensaiar)  ensaiar ;;
  --aplicar)  aplicar ;;
esac
