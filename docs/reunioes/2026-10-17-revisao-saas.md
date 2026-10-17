# Reunião do time: revisão do produto com o engenheiro-saas (17/10/2026)

**Convocada pelo responsável** para o engenheiro-saas (decisão 102) entrar com visão completa do produto e do
código. **Participantes:** CTO, PO, Scrum Master, engenheiro-saas, dev-banco, fullstack, infra-bd, seguranca,
juridico e marca. Cada papel trouxe o briefing da sua área; o engenheiro-saas leu migrations, funções, painel,
Edge Functions e CI. Medições só na homologação, em leitura; nada da produção foi lido.

## 1. Veredito

**Pronto para uma empresa operando (a Infoxtec). Não pronto para o primeiro cliente externo na mesma
instalação. Não pronto para 50 clientes.** O produto é sólido onde já foi pensado (regra no banco, permissões
fechadas por padrão, CI com regressão, cadeia do ponto por empresa, backup testado). O isolamento entre clientes
**não existe**: hoje depende apenas de haver um cliente só.

## 2. O produto hoje, em números

| Item | Hoje |
|---|---|
| Módulos | Programação (M1, em uso), Documentos e Dossiê (M2, com lacunas), Ponto (M3, só uso interno até o G6), Indicadores; M4 não existe |
| Banco | 107 migrations, 60 tabelas, 7 views, 109 `app_*`, 16 `ponto_*`, 155 `fn_*`, 57 gatilhos, 5 tarefas agendadas, 70 chaves de `config` |
| Painel | 3.44.0; 13 telas, app do ponto e verificação pública; 122 chamadas em `api.ts` |
| Testes | `regressao.sql` T1 a T49 no CI, mais `plpgsql_check` e migrations do zero |
| Desempenho | Motor de 9 a 53 ms com um ano simulado; homologação com 23 MB |
| Custo | R$ 0 em assinaturas; Twilio por uso, menos de R$ 20 por mês |

## 3. O que trava a multiempresa (achados com evidência)

1. **Não existe o cliente da plataforma (tenant).** `empresas` mistura a empregadora (dona do ponto) com o tomador
   (`locais.cliente_empresa_id`). Só 18 das 60 tabelas têm `empresa_id`; escalas, notificações, respostas,
   ocorrências, locais, documentos e `painel_usuarios` não têm.
2. **O usuário do painel não tem empresa.** `app_exigir` confere só e-mail e papel global (migration 77); as `app_*`
   devolvem tudo (ex.: `app_tecnicos`, migration 53); `app_ponto_afd` recebe a empresa por parâmetro; qualquer
   gestor cria empresa. Um gestor de um cliente veria todos.
3. **Configuração global.** `fn_config` aparece em 56 funções; fuso, janelas de envio, jornada, URA, canal e MFA
   valem para todos. Há duas fontes de fuso (`config.fuso` e `empresas.fuso`); feriados só de Salvador.
4. **Unicidades globais.** Telefone e CPF únicos no sistema inteiro: a mesma pessoa não pode estar em dois clientes.
5. **Avisos abertos por padrão.** Supervisor ou técnico sem empresa recebe ou avisa todos (decisão 69, migration 79).
6. **Local de referência do ponto.** Sem escala no dia, a marcação guarda o local ativo mais perto de qualquer
   empresa (migration 55). Com um cliente é inofensivo; com vários, o nome do local de outro cliente entra na
   marcação imutável.
7. **Vizinho barulhento.** O motor envia 3 mensagens por minuto para a plataforma inteira, em ordem de chegada;
   um lote de 300 programações de um cliente atrasa os outros em cerca de 100 minutos. Um número de WhatsApp e
   uma VM de 1 GB para todos.
8. **Sem módulo contratado, sem provisionamento, sem exportação ou exclusão por cliente, sem restauração por
   cliente, sem teste de vazamento entre empresas.**

## 4. Limites de infraestrutura (infra-bd)

| Limite | 10 clientes | 50 clientes |
|---|---|---|
| Banco 500 MB | alerta em cerca de 2 anos | estoura antes de 1 ano |
| Cofre do ponto (arquivos dentro do banco) | maior fator de crescimento | estoura primeiro |
| Storage 1 GB (cerca de 80 técnicos) | no limite | estourado |
| Egress 5 GB/mês (backup completo diário) | chega ao limite | estourado |
| Artefatos do GitHub com repositório privado (500 MB) | backups disputam a cota | estourado |
| Painel Vercel Hobby | proíbe uso comercial; provável que não publique de repositório privado de organização | — |

Nada mede Storage nem egress hoje. RPO de 24 h; RTO nunca medido.

## 5. Legal e comercial

- **juridico:** o cliente é controlador e a Infoxtec operadora; contrato com anexo de dados, lista de
  subcontratados e transferência internacional por cliente. Fim de contrato: exportar ao cliente, confirmar e só
  então eliminar (o cliente guarda os 5 anos). O Atestado Técnico vale para todos os clientes, então **nenhuma
  configuração por cliente pode restringir a marcação**. O "uso exclusivo" do REP-P (V1) pode exigir separar o
  ponto: pendência bloqueante.
- **PO:** comprovante em PDF assinado (PAdES) é item novo, esforço M, depende do e-CNPJ; a assinatura do espelho
  passa a ciência opcional, e **o mês precisa fechar também sem assinatura** (proposta: na assinatura ou 10 dias
  depois da emissão), senão o abono fica aberto para sempre (decisão 100.6).
- **marca:** cobrança por assento, técnico ativo, mínimo mensal e implantação exige contar assentos e técnicos
  ativos por empresa, medir consumo de URA e OCR e ter módulo contratado. Conflito de nome: `marca.md` proíbe a
  palavra "ponto", e o módulo se chama Trilha Ponto; rever antes do G6.

## 6. Caminho proposto (CTO, com o engenheiro-saas)

Decisão a registrar quando o responsável aprovar: **"O cliente da plataforma é `contas`, distinta de `empresas`.
Todo dado de negócio leva `conta_id`. O isolamento é imposto em `app_exigir` e provado pelo teste de vazamento no
CI. Falta de escopo nega o acesso."**

0. Desenho: `contas` acima de `empresas` (uma conta com várias empregadoras, caso BPO); matriz módulo × papel ×
   escopo aprovada pelo `seguranca`.
1. Esquema privado (074).
2. Expandir: `conta_id` nulo em todas as tabelas, preencher com a Infoxtec, tornar obrigatório; unicidades
   compostas.
3. Contexto único (`fn_conta_atual`) no usuário, na sessão do ponto e na instância do webhook; `app_exigir`
   fixa a conta e confere o módulo (`conta_modulos`).
4. Teste de vazamento A × B em toda `app_*` e `ponto_*`: critério de merge.
5. Configuração por conta, com padrão global.
6. Motor e canal por conta (fila justa, instância por conta).
7. Contrair: remover "sem empresa vê tudo" e as unicidades antigas.

Ordem de grandeza: **6 a 10 semanas** (hipótese até o inventário; número firme em 30/11, decisão 76).
**Até isso existir, o primeiro cliente externo só entra numa instalação separada (opção A)**, com o plano pago
repassado.

## 7. Lacunas priorizadas

| P | Lacuna | Esforço |
|---|---|---|
| P0 | Tenant (`contas`) e papel por empresa; empresa resolvida no banco em toda `app_*` | G |
| P0 | Admin da plataforma separado do admin do cliente | M |
| P0 | Teste de vazamento A × B no `regressao.sql` | M |
| P0 | Avisos fechados por padrão; local do ponto restrito à empresa | P |
| P0 (50) | Fila justa no motor e canal por conta | G |
| P0 (50) | Plano pago do Supabase e medição de Storage e egress | P (custo do responsável) |
| P1 | Configuração por empresa (fuso, jornada, janelas, feriados) | M |
| P1 | Telefone e CPF únicos por conta | M |
| P1 | Painel em hospedagem comercial (Cloudflare Pages, etapa 17) | P |
| P1 | Esquema privado (074) | G |
| P1 | Provisionamento por função e roteiro de implantação | M |
| P1 | Módulos contratados no banco | M |
| P1 | Exportação e exclusão por cliente | M |
| P1 | Alertas e SLO por cliente; cotas | M |
| P1 | Comprovante do ponto em PDF PAdES | M |
| P1 | Fechar o mês sem depender da assinatura | P |
| P2 | Restauração por cliente, auditoria do suporte, liberação gradual, API pública | G |

## 8. Segurança aberta (seguranca)

SEG-05 (token da URA na URL), SEG-16 (`/manager` da Evolution aberto, correção de 30 min no Caddy), varredura de
segredos depois do repositório privado (decisão 101), RIPD e roteiro de incidente da ANPD, MFA obrigatório para
cliente externo, Storage com prefixo por empresa.

## 9. Próxima sprint proposta (Scrum Master): 24/10 a 06/11

Foco: **pacote pronto e prontidão SaaS**, sem funcionalidade nova do ponto (só correção).
1. PR de registro (commits desta branch) e atualização dos documentos defasados: "Onde estamos" do plano,
   `arquitetura.md` (fala em PG 15), `banco-de-dados.md`, roteiro do `fluxo-de-desenvolvimento.md`.
2. Painel no Cloudflare Pages (etapa 17), que também resolve o risco da decisão 101.
3. Inventário de prontidão do engenheiro-saas, documento para a estimativa de 30/11.
4. T50: teste de vazamento entre empresas no `regressao.sql` (vai falhar de propósito; vira a régua da 029).
5. Correções P0 pequenas: avisos fechados por padrão e local do ponto restrito à empresa.
6. Fechar o mês sem depender da assinatura do espelho; corrigir a base legal da assinatura (decisão 84 e aviso).
7. Do responsável: enviar a consulta ao Gabriel (prazo pedido 31/10), comprar o e-CNPJ, criar o monitor 10c e
   fechar o SEG-16.

## 10. Decisões que só o responsável toma

1. **Tenant:** a conta é quem contrata o Trilha e pode ter várias empregadoras (BPO)? A mesma pessoa pode estar em
   duas contas?
2. **Primeiro cliente externo:** opção A (projeto próprio, plano pago) agora, ou espera a multiempresa?
3. **Decisão 29 (só gratuito):** aceita o Supabase Pro (cerca de US$ 25 por mês) e hospedagem comercial na
   primeira venda?
4. **WhatsApp:** número próprio por cliente ou API oficial da Meta antes de vender?
5. **Ponto no primeiro pacote externo:** o time recomenda que não, até o G6.
6. **Congelar funcionalidade nova do ponto** por duas semanas para a prontidão SaaS?
7. **Mês fecha sem assinatura** (na assinatura ou 10 dias após a emissão)?
8. **Cofre do ponto** sai do banco para o Storage antes do segundo cliente?
9. **RPO e RTO** que podemos prometer em contrato.
10. **Nome:** "Trilha Ponto" contra a regra do `marca.md`.
