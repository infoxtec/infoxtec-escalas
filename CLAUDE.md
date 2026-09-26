# Infoxtec Escalas — regras para o Claude Code

Gestão de escalas de técnicos de campo com envio pelo WhatsApp. Painel React em `web/`, toda a
regra de negócio em PostgreSQL (Supabase) em `supabase/migrations/`. Visão geral no `README.md`;
arquitetura e decisões em `docs/arquitetura.md` e `docs/decisoes.md`; fluxo de trabalho em
`docs/fluxo-de-desenvolvimento.md`.

## Ambientes

- **Produção:** projeto Supabase `zpckrxydqqmmcrphrkxz`. Nunca aplicar migration, rodar SQL,
  publicar Edge Function nem ler dados de técnicos na produção. Isso é feito por uma pessoa,
  depois do merge.
- **Homologação:** projeto Supabase `infoxtec-escalas-dev`. É onde se testa. Nunca cadastrar nele
  segredos da Evolution ou da Twilio, nem rodar `supabase/setup/cron.sql`.
- Antes de qualquer `npx supabase db push`, conferir `supabase/.temp/project-ref`.

## Comandos

```bash
cd web && npm ci && npm run build   # checagem de tipos + build; precisa passar antes de todo commit
cd web && npm run dev               # painel local; exige web/.env.local
npx supabase migration new 39_descricao   # nova migration (numeração segue a última)
```

Não há testes automatizados ainda.

## Regras do banco

- Toda regra de negócio fica no banco. O painel só chama funções `app_*` (`web/src/lib/api.ts`).
- **Nunca editar uma migration já existente.** Mudança nova é sempre um arquivo novo. O nome do
  arquivo precisa coincidir com a versão gravada no banco.
- Toda função `app_*`: `security definer`, `set search_path = public, extensions`, e a primeira
  linha é `perform app_exigir(array[...papéis...]);` (`admin`, `gestor`, `leitura`).
- Toda migration que cria ou altera função termina com o bloco de permissões por laço, nunca com
  `grant` citando assinatura (decisão 12):

```sql
do $$
declare f record;
begin
  execute 'revoke execute on all functions in schema public from public, anon, authenticated';
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'app\_%' loop
    execute format('grant execute on function %s to authenticated', f.a);
  end loop;
end $$;
```

- Tabela nova: RLS ligado e sem políticas. O acesso passa pelas funções.
- Migration precisa rodar num banco vazio: não depender de dado que só existe na produção.
- Depois de aplicar uma migration na homologação, rodar o `plpgsql_check` em todas as funções
  (dentro de uma transação desfeita, como em `docs/analise-topologia.md`) e exigir zero erros.
- Ao recriar uma função que já existe, partir da definição atual do banco de homologação, não de
  uma migration antiga: a produção foi conferida contra a homologação em 26/09 (migration 40).
- Dado novo que o painel precisa exibir só entra depois de o painel que sabe exibi-lo estar
  publicado (decisão 24).

## Regras do painel

- React 18 + TypeScript + Tailwind, sem roteador e sem biblioteca de estado. Seguir o padrão das
  páginas existentes em `web/src/pages/`.
- Ao mudar a versão exibida, atualizar `__APP_VERSION__` em `web/vite.config.ts` e `version` em
  `web/package.json`.

## Convenções

- Português em código, comentários, documentação e mensagens de commit.
- Segredos nunca no repositório. Variáveis do painel ficam em `web/.env.local`.
- Mudança de regra, tabela ou função: atualizar `docs/banco-de-dados.md`. Decisão de arquitetura:
  registrar em `docs/decisoes.md`. Entrega relevante: marcar no histórico do `README.md`.
- Trabalhar sempre em branch e abrir pull request. Nada vai direto para `main`.
