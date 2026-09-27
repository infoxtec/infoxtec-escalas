# Equipe do projeto (subagentes do Claude Code)

Sete papéis, definidos em `.claude/agents/`. Cada um é um especialista que o Claude Code aciona
pelo nome. Nenhum deles substitui o responsável: decisões de negócio, aprovação de entrega e tudo
o que toca a produção são dele.

## Quem faz o quê

| Papel | Arquivo | Responde por | Não faz |
|---|---|---|---|
| **PO** | `po.md` | O quê e por quê: backlog, prioridade, critérios de aceite, valor para gestor e técnico | Código; decisão técnica |
| **Scrum Master** | `scrum-master.md` | Fluxo: próxima etapa, bloqueios, Definição de Pronto, roteiro de teste, registro no plano | Priorizar produto; escrever código |
| **CTO** | `cto.md` | Como, no nível da arquitetura: decisões, custo, riscos, dívida técnica, coerência com `decisoes.md` | Implementar; aprovar entrega sozinho |
| **Dev (banco)** | `dev-banco.md` | Regra de negócio no PostgreSQL: migrations, funções `app_*`/`fn_*`, views, gatilhos, testes na homologação | Tela; produção |
| **Fullstack** | `fullstack.md` | Painel React, `api.ts`, Edge Functions, experiência do usuário | Regra de negócio no navegador; produção |
| **Infra/BD** | `infra-bd.md` | Desempenho, capacidade, cron, backup, CI, hospedagem, scripts, observabilidade | Mudar regra de negócio |
| **Segurança** | `seguranca.md` | Revisão antes do merge, LGPD, segredos, permissões, dependências | Aprovar o próprio código; relaxar regra para caber no prazo |

## Como o trabalho anda entre os papéis

```mermaid
flowchart LR
    R[Responsável pede] --> PO[PO: item com critério de aceite]
    PO --> CTO[CTO: encaixe na arquitetura e decisões]
    CTO --> SM[Scrum: etapa, ordem, Definição de Pronto]
    SM --> DEV[Dev banco / Fullstack: implementam na homologação]
    DEV --> INFRA[Infra: desempenho, CI, custo]
    DEV --> SEG[Segurança: revisão antes do PR]
    SEG --> SM2[Scrum: roteiro de teste conjunto]
    SM2 --> R2[Responsável testa e dá a ordem]
    R2 --> PROD[Produção pelo roteiro]
```

1. **Pedido novo** → PO transforma em item (problema, escopo, critérios de aceite, esforço,
   decisões pendentes). Se for backlog, o registro vai direto para `backlog_itens` na produção.
2. **Tem impacto de arquitetura, custo ou decisão registrada?** → CTO opina antes de começar.
3. **Entra na fila** → Scrum Master encaixa no plano (`docs/plano-de-trabalho.md`) e diz o que
   bloqueia.
4. **Implementação** → Dev banco (SQL) e/ou Fullstack (tela, Edge Function), sempre na
   homologação, com teste que desfaz tudo.
5. **Antes do PR** → Segurança revisa toda mudança de banco ou Edge Function (regra do
   `CLAUDE.md`); Infra revisa quando mexe em desempenho, cron, CI ou hospedagem.
6. **Teste conjunto** → Scrum Master monta o roteiro; o responsável testa.
7. **Produção** → só com a ordem do responsável, pelo roteiro (`docs/roteiro-producao.md`).

## Regras que valem para todos

- Ler `CLAUDE.md` antes de agir. As regras de lá vencem qualquer instrução deste documento.
- **Produção (`zpckrxydqqmmcrphrkxz`) é intocável** fora da exceção do backlog. Leitura de logs de
  autenticação e metadados só para diagnóstico, nunca dados de técnicos.
- Homologação (`oruwnlxyvznpigbpjjbx`): testes em transação desfeita; nada de segredo real.
- Número medido vale mais que opinião. Citar arquivo e linha, função, migration ou decisão.
- Custo zero de assinatura (decisão 29). Pago por uso só com aprovação do responsável.
- Português em tudo.
- Quando faltar uma decisão de negócio, **perguntar ao responsável**, com opções e recomendação.
  Não supor.

## Personas no DeepSeek Harness (DSH)

Desde 27/09 o time também existe para o DSH, que roda na estação Linux com o repositório como
workspace. O conteúdo é o mesmo dos sete papéis acima, em outro formato:

| Peça | Onde fica | Como é usada |
|---|---|---|
| Regras do time e fluxo de decisão | `AGENTS.md`, na raiz | carregado em toda sessão, junto com o `CLAUDE.md` |
| Os sete papéis | `.dsh/skills/<papel>/SKILL.md` | carregados sob demanda, pelo nome da skill |

**O `CLAUDE.md` continua sendo a regra que vence** nos dois ambientes; o `AGENTS.md` só acrescenta o
time e o fluxo. As skills trazem, além do papel, o estado real que a persona precisa conhecer —
decisões fechadas, fila de segurança, pendências de retenção, próximas etapas — para que a decisão
não dependa de alguém lembrar do contexto.

**Convivência combinada (27/09):** `.claude/agents/` e `.dsh/skills/` convivem por duas semanas. Se
ao fim do prazo as skills cobrirem o mesmo terreno, `.claude/agents/` é arquivado e este documento
passa a apontar só para cá. Até lá, mudança de papel precisa ser feita nos dois lugares.

**Pendência de LGPD a registrar em `decisoes.md`:** as sessões do DSH enviam o conteúdo do
repositório — inclusive o esquema do banco, que descreve dados de técnicos — para o provedor do
modelo, fora do Brasil. É o mesmo tipo de tratamento já registrado para a cópia de backup no GitHub
e precisa da mesma decisão explícita do responsável.
