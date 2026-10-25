# Multiempresa — F0: matriz de acesso e régua de isolamento

**Data:** 26/10/2026. **Base:** decisões 108 e 112, `docs/multiempresa-estimativa.md`. **Situação:** F0 entregue
(documento + T56 em modo relatório); F1 antecipada a pedido do responsável (26/10), produção só a partir de 06/11.

## 1. Quem é quem

| Papel | Onde vive | Escopo |
|---|---|---|
| **Admin da plataforma** | `plataforma_admins` (Infoxtec) | Todas as contas, só para suporte, com consentimento registrado da conta; funções `app_plataforma_*` |
| **Admin da conta** | `conta_membros.papel = 'admin'` | A própria conta: usuários, empresas, configuração, todos os módulos contratados |
| **Gestor** | `conta_membros.papel = 'gestor'` | A própria conta (opcional: só algumas empresas, F2) |
| **Leitura** | `conta_membros.papel = 'leitura'` | A própria conta, só consulta |
| **Supervisor** | `tecnicos.is_supervisor` | Avisos e decisões de HE da mesma empresa (decisão 107), pelo WhatsApp da conta |
| **Funcionário** | sessão do ponto (`ponto_sessoes`) | Só os próprios dados |

## 2. Matriz módulo × papel

`L` lê, `E` escreve, `—` não acessa. Escopo sempre a conta da sessão; nada atravessa conta.

| Módulo (funções) | Admin conta | Gestor | Leitura | Funcionário | Admin plataforma |
|---|---|---|---|---|---|
| Cadastros: técnicos, empresas, locais, habilidades, tipos (`app_salvar_*`, `app_tecnicos`…) | E | E | L | — | suporte |
| Programação: escalas, envio, ligações (`app_criar_escalas`, `app_escalas`, `app_ligar_escala`…) | E | E | L | — | suporte |
| Documentos e dossiê (`app_documentos`, `app_dossie_local`…) | E | E | L | — | suporte |
| Ponto: marcações, ajustes, abonos, espelhos, folha, AFD (`app_ponto_*`) | E | E | L | próprios (`ponto_*`) | suporte |
| Indicadores e painel gerencial (`app_indicadores_*`, `app_painel_*`) | L | L | L | — | suporte |
| Usuários da conta (`app_usuarios`, `app_salvar_usuario`) | E | — | — | — | E |
| Configuração da conta (F4: `config_conta`) | E | — | — | — | E |
| Plataforma: backlog, checklist, motor (`app_backlog*`, `app_checklist_*`, `app_estado_motor`) | — | — | — | — | E |

**Módulo contratado:** `conta_modulos` liga Escala e Ponto por conta; `app_exigir` recusa função de módulo não
contratado (F2). Ponto fica desligado para conta externa até o parecer V1 (decisão 108, item 5).

## 3. Classificação do catálogo (régua do T56)

- **Funções da plataforma** (não filtram por conta): `app_email`, `app_exigir`, `app_meu_acesso`, `app_backlog`,
  `app_salvar_backlog_item`, `app_mover_backlog_item`, `app_checklist_saude`, `app_checklist_testar`,
  `app_estado_motor`. Todas as outras `app_*` (≈100) filtram pela conta na F2; as `ponto_*` vêm da sessão.
- **Tabelas da plataforma** (sem `conta_id`): `config` (vira o padrão global), `backlog_itens`, `motor_estado`,
  `saude_testes`, `ponto_geo` (cache de endereço, sem dado pessoal), `webhook_token_trocas`. As outras 55 recebem
  `conta_id` na F1.
- **T56 (regressão):** confere que a lista acima existe no catálogo e informa quantas tabelas de cliente ainda estão
  sem `conta_id`. Em modo relatório agora; vira exigência (CI vermelho) quando a F1 terminar.

## 4. Para antecipar a F1 (o que preciso do responsável)

1. **Nome da conta 1** (a Infoxtec) como aparece no painel — proposta: "Infoxtec".
2. **Admins da plataforma**: os e-mails que entram em `plataforma_admins` (proposta: só o responsável).
3. **Papel de cada usuário atual na conta 1**: proposta — o papel atual de `painel_usuarios` vira o papel na conta 1
   (admin → admin, gestor → gestor, leitura → leitura), sem mudar nada para ninguém.
4. **Calendário**: F1 na homologação já nesta semana; **produção junto com a 115, a partir de 06/11** (nada vai à
   produção durante o fechamento de outubro). Confirmar.
5. **Unicidades**: na F1 as regras antigas ficam (CPF, telefone e CNPJ únicos no sistema inteiro); as novas, por
   conta, nascem ao lado. As antigas só caem na F6, quando login do ponto e WhatsApp já souberem a conta. Confirmar.

O que a F1 **não** muda: nenhuma tela, nenhuma assinatura de função, nenhum texto ao funcionário. É só estrutura e
preenchimento (expandir → preencher → `not null`), com a regressão inteira verde.
