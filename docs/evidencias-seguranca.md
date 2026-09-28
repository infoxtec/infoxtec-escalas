# Evidências de segurança

Para quê: responder ao questionário de segurança de um cliente com **prova**, não com adjetivo. Cada
afirmação aqui tem uma consulta que a comprova e uma ressalva honesta quando existe limite.

**Todas as consultas da §2 são de leitura de estrutura e permissão — nenhuma lê dado de técnico.**
Rodam no SQL Editor da produção e levam menos de um minuto.

---

## 1. Como usar (10 minutos, uma vez por cliente)

1. Rodar as consultas da §2 no SQL Editor da **produção**.
2. Salvar o resultado em PDF ou print, **com a data visível** (o print do SQL Editor já traz).
3. Anexar ao questionário o quadro da §1 e, se o cliente pedir detalhe, o resultado das consultas.
4. **Não reescrever a §1 à mão.** Ela é o que as consultas provam — a única coisa que muda é a data.

---

## 2. As consultas de prova

### Q1 · Todas as tabelas têm RLS ligado e nenhuma política

```sql
select c.relname as tabela,
       c.relrowsecurity as rls_ligado,
       (select count(*) from pg_policies p
         where p.schemaname = 'public' and p.tablename = c.relname) as politicas
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by 1;
```

**Esperado:** 23 linhas, todas com `rls_ligado = true` e `politicas = 0`.

**O que isso prova:** nada é legível nem gravável pela API pública. RLS ligado **sem política** nega
tudo por padrão; o acesso existe só por função que confere papel.

### Q2 · Nenhuma tabela ou visão está acessível a `anon` e `authenticated`

```sql
select grantee, table_name, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public' and grantee in ('anon','authenticated')
 order by 1,2,3;
```

**Esperado:** **zero linhas.** Qualquer linha aqui é um achado a corrigir antes de enviar.

### Q3 · Só as funções `app_*` podem ser executadas pelo usuário logado

```sql
select p.proname,
       has_function_privilege('anon', p.oid, 'execute')          as anon,
       has_function_privilege('authenticated', p.oid, 'execute')  as authenticated
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname not like 'app\_%'
 order by 3 desc, 2 desc, 1;
```

**Esperado:** todas as colunas `anon` e `authenticated` em `false`. Complemento:

```sql
select count(*) filter (where has_function_privilege('authenticated', p.oid, 'execute')) as app_executaveis,
       count(*) as app_total
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname like 'app\_%';
```

**Esperado:** os dois números iguais (as 53 `app_*` acessíveis ao usuário logado — e nenhuma outra).

### Q4 · O bucket de documentos é privado, com política por papel

```sql
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'documentos';

select policyname, cmd, roles::text as papeis, qual is not null as tem_condicao
  from pg_policies where schemaname = 'storage' and tablename = 'objects' order by 1;
```

**Esperado:** `public = false`, limite de 8 MB, tipos PDF/JPG/PNG; e três políticas
(`select`, `insert`, `delete`) para `authenticated` **com condição**.

### Q5 · A autorização é conferida no banco, não na tela

```sql
select p.proname as funcao,
       p.prosecdef as security_definer,
       pg_get_functiondef(p.oid) ilike '%search_path%' as search_path_fixo,
       pg_get_functiondef(p.oid) ilike '%app_exigir%'  as exige_papel
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname like 'app\_%'
 order by 4, 1;
```

**Esperado:** `exige_papel = true` em todas, exceto as quatro auxiliares conhecidas
(`app_exigir`, `app_email`, `app_meu_acesso`, `app_pode_gerir_documentos`); `search_path_fixo = true`.

### Q6 · Existe trilha de auditoria

```sql
select evento, count(*) as registros from escala_eventos group by 1 order by 2 desc;
select count(*) as exclusoes_registradas from log_exclusoes;
```

**Esperado:** eventos de criação, mudança de status, envio, resposta, edição e exclusão; e o registro
de exclusões **sem nome nem telefone**.

---

## 3. Respostas prontas para o questionário

> **Revisado em 28/09/2026**, depois das decisões 40 (sem motivo de saúde) e 41 (sem vínculo por
> Drive). O que mudou está nas linhas 2, 5 e 9.

| # | Pergunta típica do cliente | Resposta | Prova | Ressalva honesta |
|---|---|---|---|---|
| 1 | Há autenticação? | Supabase Auth, e-mail e senha; cadastro público desligado; sessão encerra após 30 min de inatividade | config dos projetos + `docs/seguranca.md` | **MFA ainda não está ligado** (em implantação) |
| 2 | Há controle de acesso por papel? | `admin`, `gestor` e `leitura`, em `painel_usuarios`; conferido no banco em cada chamada | Q5 | o papel `leitura` ainda vê a **existência** dos documentos (SEG-14, em correção). O motivo de saúde **deixou de existir** em 28/09 (decisão 40) |
| 3 | O banco é acessível direto pela API? | **Não.** RLS ligado nas 23 tabelas, sem políticas, e privilégios revogados | Q1 e Q2 | — |
| 4 | As permissões são mínimas? | Só as funções `app_*` são executáveis pelo usuário logado; privilégios de tabela e os padrão de tabela e de função estão revogados | Q3 | as **`sequences` não são revogadas** em nenhuma migration — em correção (SEG-06) |
| 5 | Como os documentos são protegidos? | Bucket privado, sem URL pública, **link assinado de 2 minutos**, política por papel. Desde 28/09 **não existe vínculo por link externo** (Drive descontinuado, decisão 41): acesso e retenção ficam sob controle do sistema | Q4 | não há trilha de quem abriu; o expurgo é manual |
| 6 | Há trilha de auditoria? | Sim: quem mudou o quê e quando, em `escala_eventos`, mais registro de exclusões | Q6 | não há exportação pronta (item 018 do backlog) |
| 7 | Há criptografia? | Em trânsito (TLS) e em repouso, pela infraestrutura | documentação do Supabase | é do **provedor**; não é controle nosso |
| 8 | Há backup? | Diário, cifrado AES-256, 30 dias, com teste de restauração mensal | `.github/workflows/backup.yml` e `restauracao.yml` | **cobre só o schema `public`** (não Auth, Vault, cron) e **não cobre os arquivos** — em correção |
| 9 | Há política de retenção? | Quatro prazos automáticos (log 30 d, conteúdo enviado 90 d, alertas 90 d, cron 7 d) e guarda declarada de documentos. Sem o Drive, **a guarda volta a ser executável pelo sistema** | `fn_limpeza_logs`; `docs/analise-seguranca.md` §4.1 | o expurgo dos documentos **não roda sozinho** — em correção (SEG-10) |
| 10 | Quem são os subprocessadores? | Supabase (banco), Vercel (painel), GitHub (cópia de segurança), Twilio (voz), Evolution em VPS própria (WhatsApp) e Google (OCR, hoje desligado) | `docs/analise-seguranca.md` §4.2 (L8) | as transferências **não têm registro formal de base legal** |
| 11 | Há plano de resposta a incidente? | **Ainda não** está formalizado | bloco 2 de `docs/seguranca-homologacao.md` | é item aberto, com dono e prazo a definir |
| 12 | Quem tem acesso ao ambiente de produção? | Uma pessoa, com credenciais em gerenciador de senhas | `docs/analise-infraestrutura.md` §2 | **MFA nas contas administrativas** ainda não |

---

## 4. O que **não** afirmar

| Não dizer | Dizer |
|---|---|
| "Somos certificados ISO 27001" | "Hospedado em infraestrutura com ISO/IEC 27001 e SOC 2" — a certificação é da organização, não do software |
| "Somos 100% conformes à LGPD" | O que o produto faz (papel, retenção, exclusão, trilha) e o que depende do contratante |
| "Garantimos disponibilidade" | O que existe: aviso automático de motor parado e plano de contingência manual. SLA só com contrato |
| "Backup completo do banco" | "Cópia diária cifrada dos dados de negócio, com teste de restauração" — e o que fica fora |
| "Documentos com retenção de 5 anos garantida" | "Política declarada de 5 anos; o expurgo é manual hoje" |

---

## 5. O que falta para responder o questionário difícil

| Lacuna | Onde fecha | Bloqueia venda para |
|---|---|---|
| **MFA** | bloco 1 de segurança (etapa 3) | cliente médio e grande — é a primeira pergunta |
| **Plano de resposta a incidente** | bloco 2, item 8 | qualquer questionário completo |
| **Retenção e expurgo automatizados** | `analise-seguranca.md` §6 (ordem 6) | RH e construção, que perguntam por prazo |
| **Inventário de segredos rotacionados** | [`rotacao-de-segredos.md`](rotacao-de-segredos.md) | questionário que pede gestão de credenciais |
| **Restauração ensaiada de ponta a ponta** | `analise-infraestrutura.md` §4 | pergunta "vocês testam restauração?" com o sistema voltando |
| **Trilha de acesso a documento** | item 015 do backlog | quem trata ASO (dado de saúde) |

**Sugestão de sequência:** MFA primeiro (barato, é a pergunta nº 1), depois o plano de incidente
(uma página), depois a rotação dos segredos — que é o que o
[`rotacao-de-segredos.md`](rotacao-de-segredos.md) resolve.
