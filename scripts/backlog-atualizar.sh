#!/usr/bin/env bash
# Atualiza o quadro do backlog (tabela backlog_itens) na PRODUCAO, com travas.
#
# Por que existe: o mesmo SQL rodado no SQL Editor travou. O editor nao tem limite de espera,
# entao um UPDATE que encontra a tabela bloqueada fica esperando para sempre. Aqui temos
# lock_timeout (falha em 5s dizendo quem esta travando), statement_timeout (30s) e
# ON_ERROR_STOP (nada aplica pela metade).
#
# Uso:
#   ./scripts/backlog-atualizar.sh              # confere: quem trava, como esta e o que mudaria (nao escreve)
#   ./scripts/backlog-atualizar.sh --aplicar    # aplica, pedindo confirmacao escrita
#   ./scripts/backlog-atualizar.sh --travados   # so lista quem esta segurando a tabela
#   ./scripts/backlog-atualizar.sh --ajuda
#
# Precisa de duas coisas, que o script confere e explica se faltarem:
#   1. psql  ->  sudo apt install -y postgresql-client
#   2. a string de conexao da producao, em PRODUCAO_DB_URL
set -euo pipefail

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"

ARQ_CONEXAO="${HOME}/.infoxtec/producao.env"

ajuda() {
  cat <<'FIM'
Atualiza o quadro do backlog (tabela backlog_itens) na PRODUCAO, com travas.

Por que existe: o mesmo SQL rodado no SQL Editor travou. O editor nao tem limite de espera,
entao um UPDATE que encontra a tabela bloqueada fica esperando para sempre. Aqui temos
lock_timeout (falha em 5s dizendo quem esta travando), statement_timeout (30s) e ON_ERROR_STOP
(nada aplica pela metade).

Uso:
  ./scripts/backlog-atualizar.sh              confere: quem trava, como esta e o que mudaria
  ./scripts/backlog-atualizar.sh --aplicar    aplica, pedindo confirmacao escrita
  ./scripts/backlog-atualizar.sh --travados   so lista quem esta segurando a tabela
  ./scripts/backlog-atualizar.sh --ajuda      esta ajuda

Precisa de duas coisas, que o script confere e explica se faltarem:
  1. psql  ->  sudo apt install -y postgresql-client
  2. a string de conexao da producao, em PRODUCAO_DB_URL (~/.infoxtec/producao.env)
FIM
  exit 0
}
case "${1:-}" in
  --ajuda|-h|--help) ajuda ;;
esac
ACESSO="${1:-}"

# --- 1. Ferramenta -----------------------------------------------------------------------------
if ! command -v psql >/dev/null 2>&1; then
  cat <<'FIM'
psql nao esta instalado. E ele que permite falar com o banco fora do SQL Editor (com limite de
espera). Instale com:

  sudo apt update && sudo apt install -y postgresql-client

Depois rode este script de novo.
FIM
  exit 1
fi

# --- 2. Conexao --------------------------------------------------------------------------------
if [ -f "$ARQ_CONEXAO" ]; then
  # shellcheck disable=SC1090
  source "$ARQ_CONEXAO"
fi

if [ -z "${PRODUCAO_DB_URL:-}" ]; then
  cat <<FIM
Falta a string de conexao da producao. Ela nao fica no repositorio (e segredo).

Pegue em: painel do Supabase -> projeto infoxtec-escalas -> Connect -> Session pooler.
A senha e a do banco, que voce guardou no gerenciador de senhas quando trocou em 27/09.

E salve assim (uma vez so):

  mkdir -p ~/.infoxtec && chmod 700 ~/.infoxtec
  printf '%s\n' "PRODUCAO_DB_URL='postgresql://postgres.zpckrxydqqmmcrphrkxz:SUA_SENHA@aws-0-REGIAO.pooler.supabase.com:5432/postgres'" > $ARQ_CONEXAO
  chmod 600 $ARQ_CONEXAO

Depois rode este script de novo.
FIM
  exit 1
fi

# Nunca mostra a senha: so o alvo.
alvo=$(printf '%s' "$PRODUCAO_DB_URL" | sed -E 's#://([^:]+):[^@]+@#://\1:***@#')
echo "Producao: $alvo"
echo

# Todas as consultas usam estas travas. lock_timeout curto e o que evita o travamento.
PSQL=(psql "$PRODUCAO_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off)

# --- 3. Quem esta travando a tabela --------------------------------------------------------------
travados() {
  "${PSQL[@]}" <<'SQL'
select l.pid,
       case when l.granted then 'SEGURA' else 'ESPERA' end as situacao,
       l.mode,
       a.state,
       coalesce((now() - a.xact_start)::text, '—') as tempo_da_transacao,
       left(regexp_replace(coalesce(a.query,''), '\s+', ' ', 'g'), 70) as consulta
  from pg_locks l
  join pg_stat_activity a on a.pid = l.pid
 where l.relation = 'backlog_itens'::regclass
 order by l.granted, l.pid;
SQL
  cat <<'FIM'

Leitura: SEGURA = quem esta com a tabela presa (pode ser uma aba antiga do SQL Editor com
transacao aberta). ESPERA = quem esta parado por causa dele — provavelmente era o seu script.

Para destravar, na consulta acima escolha o pid de quem SEGURA e rode no SQL Editor:

  select pg_cancel_backend(PID);     -- pede para encerrar (tenta primeiro este)
  select pg_terminate_backend(PID);  -- encerra a forca (se o primeiro nao resolver)
FIM
}

if [ "$ACESSO" = "--travados" ]; then
  echo "== Quem esta com a tabela backlog_itens =="
  travados
  exit 0
fi

# --- 4. Estado atual ---------------------------------------------------------------------------
estado() {
  "${PSQL[@]}" <<'SQL'
select numero, titulo, coluna, status, entregue_em
  from backlog_itens
 where numero in (2, 3, 5, 10, 11, 12, 13, 64, 65)
 order by numero;

select coluna, count(*) as itens from backlog_itens group by coluna order by coluna;
SQL
}

# A atualizacao, em um lugar so, usada nos dois modos (conferir e aplicar).
ATUALIZACAO=$(cat <<'SQL'
with alvo(numero, coluna, status, entregue_em, observacao) as (
  values
    ( 5, 'feito',   'concluido', date '2026-09-25', null),
    (10, 'feito',   'concluido', date '2026-09-24', null),
    (11, 'feito',   'concluido', date '2026-09-24', null),
    (12, 'feito',   'concluido', date '2026-09-24', null),
    (13, 'feito',   'concluido', date '2026-09-24', null),
    (64, 'feito',   'concluido', date '2026-09-28', null),
    (65, 'feito',   'concluido', date '2026-09-28', null),
    ( 2, 'revisao', 'parcial',   null,
     'URA de voz entregue em 23/09 e testada em producao. Falta ligar o bloqueio da assinatura da Twilio — tema SEG-05 no painel de temas.'),
    ( 3, 'revisao', 'parcial',   null,
     'Painel por local entregue em versao parcial; o percentual real de conclusao depende do item 001.')
)
update backlog_itens b
   set coluna      = a.coluna,
       status      = a.status,
       entregue_em = coalesce(b.entregue_em, a.entregue_em),
       observacao  = coalesce(a.observacao, b.observacao),
       updated_at  = now()
  from alvo a
 where b.numero = a.numero
returning b.numero, b.titulo, b.coluna, b.status, b.entregue_em;
SQL
)

# --- 5. Modo conferir (nao escreve nada) --------------------------------------------------------
if [ "$ACESSO" != "--aplicar" ]; then
  echo "== 1. Quem esta com a tabela =="
  travados
  echo
  echo "== 2. Como esta agora =="
  estado
  echo
  echo "== 3. O que a atualizacao mudaria (a transacao e desfeita no fim: nada e gravado) =="
  "${PSQL[@]}" <<SQL
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
$ATUALIZACAO
rollback;
SQL
  cat <<'FIM'

Nada foi gravado. Para aplicar de verdade:

  ./scripts/backlog-atualizar.sh --aplicar
FIM
  exit 0
fi

# --- 6. Modo aplicar ----------------------------------------------------------------------------
echo "== O que vai ser aplicado =="
"${PSQL[@]}" <<SQL
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
$ATUALIZACAO
rollback;
SQL
echo
echo "Sete itens vao para 'feito' (005, 010, 011, 012, 013, 064, 065) e dois para 'revisao' (002, 003)."
read -r -p "Para aplicar no quadro da PRODUCAO, digite ATUALIZAR: " resposta
[ "$resposta" = "ATUALIZAR" ] || { echo "Cancelado. Nada foi gravado."; exit 1; }

"${PSQL[@]}" <<SQL
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';
$ATUALIZACAO
commit;
SQL

echo
echo "== Como ficou =="
estado
