# Infoxtec Escalas — regras para o Claude Code

Gestão de escalas de técnicos de campo com envio pelo WhatsApp. Painel React em `web/`, toda a
regra de negócio em PostgreSQL (Supabase) em `supabase/migrations/`. Visão geral no `README.md`;
arquitetura e decisões em `docs/arquitetura.md` e `docs/decisoes.md`; fluxo de trabalho em
`docs/fluxo-de-desenvolvimento.md`.

## Ambientes

- **Produção:** projeto Supabase `zpckrxydqqmmcrphrkxz`. Nunca aplicar migration, rodar SQL,
  publicar Edge Function nem ler dados de técnicos na produção. Isso é feito por uma pessoa,
  depois do merge, com `scripts/aplicar-producao.sh` (mantém o histórico de versões igual ao
  repositório; migration aplicada por outro caminho ganha outra versão e quebra o `db push`).
- **Exceção, combinada em 26/09: backlog.** Quando o responsável pedir para registrar algo no
  backlog, o registro vai **direto para a produção**, na tabela `backlog_itens` e só nela (inserir
  ou atualizar itens; nada de estrutura). O número é atribuído pelo banco, em sequência única,
  exibido com três dígitos (001, 002...). A análise do item vai para `docs/backlog.md`.
- **Todo o resto** (estrutura, funções, painel, Edge Functions) segue o ciclo: Claude aplica na
  homologação, os dois testam, e só com o comando do responsável vai para a produção.
- **Homologação:** projeto Supabase `infoxtec-escalas-dev`. É onde se testa. Nunca cadastrar nele
  segredos da Evolution ou da Twilio, nem rodar `supabase/setup/cron.sql`.
- Antes de qualquer `npx supabase db push`, conferir `supabase/.temp/project-ref`. O caminho normal
  é `scripts/aplicar-homologacao.sh` e `scripts/aplicar-producao.sh`.
- A lista de trabalho pendente, em ordem, está em `docs/plano-de-trabalho.md`. Ao concluir uma
  etapa, marcar `[x]` e registrar na tabela do fim do arquivo.

## Equipe de especialistas

Subagentes do projeto em `.claude/agents/`, carregados sozinhos em toda sessão. Acionar pelo nome
quando o assunto for da especialidade: `cto` (arquitetura e decisões), `po` (backlog e critérios de
aceite), `scrum-master` (próxima etapa e roteiro de teste), `dev-banco` (migrations e funções),
`fullstack` (painel e Edge Functions), `infra-bd` (desempenho, cron, hospedagem, backup),
`seguranca` (revisão antes do merge e LGPD), `marca` (estratégia de marca, identidade verbal e comercial). Toda mudança de banco ou de Edge Function passa pela
revisão do `seguranca` antes do pull request.
Papéis, fluxo entre eles e regras comuns: `docs/equipe.md`.

O mesmo time existe para o DeepSeek Harness, em `.dsh/skills/`, com as regras do time e o fluxo de
decisão em `AGENTS.md` (que não substitui este arquivo — este vence). Há uma persona a mais lá:
`comercial`, o Diretor Comercial e Branding, que é **cliente do CTO e do PO** e responde por mercado,
marca, preço, pacote e pelas palavras da proposta, em `docs/plano-comercial.md` e `docs/marca.md`.
Afirmação comercial só entra em proposta com lastro na matriz de capacidade daquele documento.

O DeepSeek **nunca executa SQL que altere** — leitura para diagnóstico é permitida, sempre em
transação somente-leitura — e todo pacote dele passa pela validação e revisão do Claude antes de
seguir (decisão 47, protocolo em `docs/equipe.md`).

## Comandos

```bash
cd web && npm ci && npm run build   # checagem de tipos + build; precisa passar antes de todo commit
./scripts/painel.sh iniciar        # painel local da homologação em segundo plano (porta 5173)
npx supabase migration new 39_descricao   # nova migration (numeração segue a última)
```

O CI (`.github/workflows/ci.yml`) roda em todo pull request: build do painel, `deno check` das
Edge Functions, todas as migrations num banco vazio e `plpgsql_check`. Precisa estar verde antes do merge.

## Regras do banco

- Toda regra de negócio fica no banco. O painel só chama funções `app_*` (`web/src/lib/api.ts`).
- **Nunca editar uma migration já existente.** Mudança nova é sempre um arquivo novo. O nome do
  arquivo precisa coincidir com a versão gravada no banco.
- Toda função `app_*`: `security definer`, `set search_path = public, extensions`, e a primeira
  linha é `perform app_exigir(array[...papéis...]);` (`admin`, `gestor`, `leitura`).
- Toda função `ponto_*` (API do funcionário no app do ponto, decisão 49): `security definer`, o mesmo
  `search_path`, e a primeira linha valida a sessão — `v_tec uuid := fn_ponto_sessao(p_token);`. O
  funcionário vem sempre da sessão, nunca de parâmetro. É a única família executável pelo papel `anon`.
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
  for f in select p.oid::regprocedure as a from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ponto\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.a);
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
- Segredos nunca no repositório. `web/.env.homologacao` e `web/.env.producao` só têm endereço e
  chave publicável, que não são segredo (ficam no navegador por design). Qualquer outra variável
  fica em `web/.env.local`, fora do Git.
- Mudança de regra, tabela ou função: atualizar `docs/banco-de-dados.md`. Decisão de arquitetura:
  registrar em `docs/decisoes.md`. Entrega relevante: marcar no histórico do `README.md`.
- Afirmação comercial — proposta, site, conversa de venda — só com lastro na matriz de
  `docs/plano-comercial.md`; nome, mote e posicionamento em `docs/marca.md`. Preço, SLA, garantia e
  aceitar risco são decisão do responsável, não do material de venda.
- Trabalhar sempre em branch e abrir pull request. Nada vai direto para `main`.
- **Toda instrução SQL vem com o comando pronto para executar** (exigência do responsável, 28/09):
  bloco cercado, completo, com o projeto onde roda (produção ou homologação) e o que se espera de
  resultado. Nunca só descrever a consulta em texto, nem entregar fragmento que precise ser montado.
  Quando a operação for de mais de um passo, vem com a conferência antes e depois. Script de uma vez
  só fica em `supabase/setup/` e some do repositório depois de aplicado — o registro durável é
  `docs/backlog.md`, `docs/decisoes.md` ou o painel, não o script.
