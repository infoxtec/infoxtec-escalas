#!/usr/bin/env bash
# Confere o quadro do backlog (tabela backlog_itens) na PRODUCAO e mostra quem esta travando a tabela.
#
# Por que existe: o SQL Editor do Supabase nao tem limite de espera. Um UPDATE que encontra a tabela
# bloqueada nao falha — fica parado para sempre, sem dizer por que. Este script fala com o banco por
# psql, com lock_timeout, e por isso responde em segundos em vez de travar.
#
# Ele NAO escreve nada: e leitura e diagnostico. Mudanca no quadro e decisao do responsavel, feita
# pelo painel (arrastar o cartao) ou por SQL conferido antes.
#
# Uso:
#   ./scripts/backlog-conferir.sh            estado do quadro + quem esta com a tabela presa
#   ./scripts/backlog-conferir.sh --travados so o diagnostico de bloqueio, com o comando de cancelar
#   ./scripts/backlog-conferir.sh --ajuda
#
# Precisa de duas coisas, que o script confere e explica se faltarem:
#   1. psql  ->  sudo apt install -y postgresql-client
#   2. a string de conexao da producao, em PRODUCAO_DB_URL (~/.infoxtec/producao.env)
set -euo pipefail

raiz=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Rode dentro do repositorio (~/infoxtec-escalas)."; exit 1; }
cd "$raiz"

ARQ_CONEXAO="${HOME}/.infoxtec/producao.env"

ajuda() {
  cat <<'FIM'
Confere o quadro do backlog na PRODUCAO e mostra quem esta travando a tabela. Nao escreve nada.

Uso:
  ./scripts/backlog-conferir.sh            estado do quadro + quem esta com a tabela presa
  ./scripts/backlog-conferir.sh --travados so o diagnostico de bloqueio, com o comando de cancelar
  ./scripts/backlog-conferir.sh --ajuda    esta ajuda

Precisa de duas coisas, que o script confere e explica se faltarem:
  1. psql  ->  sudo apt install -y postgresql-client
  2. a string de conexao da producao, em PRODUCAO_DB_URL (~/.infoxtec/producao.env)

Leitura no SQL Editor tambem funciona (um SELECT nao espera lock). O que trava la e escrita: um
UPDATE bloqueado fica parado sem limite de espera. Para escrever, use SQL curto, uma instrucao por
vez, e confira depois.
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
psql nao esta instalado. E ele que permite falar com o banco fora do SQL Editor, com limite de
espera. Instale com:

  sudo apt update && sudo apt install -y postgresql-client

Depois rode este script de novo. (Para so ler o quadro, o SQL Editor resolve:

  select numero, titulo, coluna, status, entregue_em from backlog_itens order by ordem, numero;
)
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

Nao digite a senha em comando nenhum: ela ficaria no historico do shell. Cole a string com o
comando abaixo, que le sem eco e nao guarda o que foi digitado:

  mkdir -p ~/.infoxtec && chmod 700 ~/.infoxtec
  read -rsp 'Cole a string de conexao (nao aparece na tela): ' URL && \
    printf '%s\n' "PRODUCAO_DB_URL='$URL'" > $ARQ_CONEXAO && chmod 600 $ARQ_CONEXAO && unset URL

A string completa (com a senha no lugar de [YOUR-PASSWORD]) esta no painel do Supabase, em
Connect -> Session pooler. Confira a regiao no que ele mostra - nao invente.

Depois rode este script de novo.
FIM
  exit 1
fi

# Nunca mostra a senha: so o alvo.
alvo=$(printf '%s' "$PRODUCAO_DB_URL" | sed -E 's#://([^:]+):[^@]+@#://\1:***@#')
echo "Producao: $alvo"
echo

# lock_timeout curto: se a tabela estiver presa, falha em 5s e diz quem prende, em vez de esperar.
PSQL=(psql "$PRODUCAO_DB_URL" -X -v ON_ERROR_STOP=1 -P pager=off)
PSQL_TIMEOUT=(-c "set lock_timeout = '5s'" -c "set statement_timeout = '30s'")

# --- 3. Quem esta travando a tabela --------------------------------------------------------------
travados() {
  "${PSQL[@]}" "${PSQL_TIMEOUT[@]}" <<'SQL'
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

Leitura: SEGURA = quem esta com a tabela presa (pode ser uma aba antiga do SQL Editor com transacao
aberta). ESPERA = quem esta parado por causa dele.

Se nao aparecer nada e ainda houver duvida, veja as sessoes acordadas:

  select pid, state, wait_event_type, wait_event,
         coalesce((now() - xact_start)::text, '—') as tempo,
         left(regexp_replace(coalesce(query,''), '\s+', ' ', 'g'), 70) as consulta
    from pg_stat_activity
   where datname = current_database() and pid <> pg_backend_pid() and state <> 'idle'
   order by xact_start nulls first;

Para destravar, escolha o pid de quem SEGURA e rode no SQL Editor:

  select pg_cancel_backend(PID);     -- pede para encerrar (tente este primeiro)
  select pg_terminate_backend(PID);  -- encerra a forca, se o primeiro nao resolver
FIM
}

if [ "$ACESSO" = "--travados" ]; then
  echo "== Quem esta com a tabela backlog_itens =="
  travados
  exit 0
fi

# --- 4. Estado do quadro -------------------------------------------------------------------------
echo "== Como esta o quadro =="
"${PSQL[@]}" "${PSQL_TIMEOUT[@]}" <<'SQL'
select coluna, count(*) as itens from backlog_itens group by coluna order by coluna;

select numero, titulo, coluna, status, entregue_em
  from backlog_itens
 where coluna in ('feito', 'revisao')
 order by coluna, numero;
SQL

echo
echo "== Quem esta com a tabela =="
travados

cat <<'FIM'

Lembrete: `entregue_em` e a data em que o cartao entrou na coluna 'feito', nao a data da entrega
tecnica — essa fica em docs/backlog.md e no painel de controle.
FIM
