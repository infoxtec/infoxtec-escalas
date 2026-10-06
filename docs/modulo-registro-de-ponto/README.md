# Módulo Registro de Ponto — Trilha Ponto

Tudo o que diz respeito ao registro de ponto mora nesta pasta. É a fonte única do módulo: plano,
regras, parte legal e decisões. Mudou algo do ponto, muda aqui.

| Arquivo | O que tem |
|---|---|
| [README.md](README.md) | Visão, escopo, decisões e estado (esta página) |
| [plano.md](plano.md) | Fases, tarefas, itens do backlog, dependências e critérios de aceite |
| [legal.md](legal.md) | Normas, tarefas jurídicas e contábeis, registro no INPI, o que podemos afirmar |
| [aviso-de-privacidade.md](aviso-de-privacidade.md) | Aviso ao trabalhador (LGPD), rascunho para revisão do advogado |

**Backlog:** item **075** (o módulo) e itens **076 a 089** (as tarefas), na aba Roadmap do painel.
**Decisão de arquitetura:** decisão **48** em [`docs/decisoes.md`](../decisoes.md).
**Responsáveis externos:** **Gabriel Pirolli** (advogado) e **Andreia Monteiro** (contadora).

---

## 1. O que é

Registro de ponto eletrônico do funcionário, **aderente à CLT e à Portaria MTP 671/2021**, ligado ao
que o Trilha já tem: funcionários (hoje `tecnicos`), escalas, locais e — novo — empresas (o
empregador, por CNPJ).

**Objetivo:** ponto rápido, ágil e dentro da lei, sem promessa falsa e sem aceitar risco — no máximo
mitigar.

## 2. Canais

| Canal | Papel | Localização |
|---|---|---|
| **App web** (instalável no celular) | **principal** | GPS do navegador, obrigatória |
| **WhatsApp** da Infoxtec (+55 71 4101-9605) | complementar | localização **em tempo real**, obrigatória |
| **URA receptiva** (ligação) | **contingência** | não existe por ligação: a marcação é sinalizada ao gestor |

**Palavras do WhatsApp:** ponto, bater ponto, registro de ponto, entrada, almoço, HE, hora extra,
saída.

**Almoço:** o sistema lembra, de forma amigável, a **saída** para o almoço; o **retorno** é
responsabilidade do funcionário — não há lembrete, para não criar risco trabalhista.

## 3. Decisões do responsável (06/10/2026)

1. Nasce **vendável**; começa com desenvolvimento, homologação e **período de avaliação na Infoxtec**.
2. **App web é o canal principal**; WhatsApp complementar; **URA só de contingência**.
3. **Carimbo do tempo do servidor**, na hora legal brasileira — nunca a hora do celular.
4. **Localização obrigatória para todos**, só no momento da marcação, conferida contra a área do
   local de trabalho. Fora da área: **sinaliza, nunca bloqueia** (a lei proíbe impedir a marcação).
5. **Sem selfie e sem biometria** (dado sensível, LGPD art. 11). Anti-fraude por área do local e
   vínculo do aparelho.
6. **Marcação só de inclusão**: nada se altera nem se apaga; ajuste é registro separado e justificado.
   **Guarda de 5 anos**; nenhuma rotina de limpeza alcança as marcações.
7. **Login do funcionário com sessão única**: um novo login derruba a sessão anterior.
8. Regra de jornada pela **CLT e pela convenção coletiva** da categoria, com **aviso de limite de
   hora extra** (2 h por dia, CLT art. 59).
9. **LGPD integral**: aviso de privacidade desde esta etapa, base legal registrada, minimização.
10. **Empresas (CNPJ) desde já**; separação completa por cliente (item 074) **antes do primeiro
    cliente externo**.
11. Usa o **banco atual**, em tabelas novas, e a **mesma instância da Evolution** — sem servidor novo.
12. **Custos aprovados:** registro no INPI, certificado e-CNPJ e número de entrada da URA na Twilio.
13. **Legalização corre em paralelo** ao desenvolvimento; nada vale como ponto oficial antes do
    parecer jurídico e do registro no INPI.
14. **Nenhuma promessa comercial falsa.** "Homologado pelo MTE" não existe para software e não será
    dito.

## 4. Estado

| Frente | Estado |
|---|---|
| Plano e decisões | aprovados em 06/10 |
| Legal (L1–L4) | a iniciar — Gabriel e Andreia |
| Desenvolvimento (F1–F8) | **F1 pacote 1 (080) na homologação em 06/10** (migration 53, painel 3.9.0); pacote 2 (081) a seguir |
| Ponto oficial na Infoxtec | só depois do parecer, do INPI e de 30 dias de avaliação |

## 5. O que já existe no Trilha e será reaproveitado

| Peça | Onde |
|---|---|
| Recebimento de texto e botões do WhatsApp | `fn_wh_mensagem` (webhook da Evolution) |
| Parâmetros de jornada CLT (480 min, intervalo, noturno 22h–5h, hora de 52,5 min, fuso) | `config` |
| Jornada prevista da escala | `escalas` (`hora_inicio`, `hora_fim_prevista`, `intervalo_min`, `minutos_noturnos`) |
| URA (hoje só de saída) | Edge Function `voz-escala` (Twilio) |
| Auditoria, papéis, cron, painel, backup | `escala_eventos`, `app_exigir`, `pg_cron`, `web/` |

O que **não existe** e é o núcleo do módulo: empregador (CNPJ), CPF e matrícula do funcionário,
coordenadas do local, marcações com NSR, comprovante, espelho, AFD e AEJ, login do funcionário.
