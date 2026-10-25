# Multiempresa — F2: a conta vem da sessão e toda função filtra por ela

**Base:** decisões 108, 112 e 113; `docs/multiempresa-estimativa.md` (F2, 2,5–3,5 semanas); matriz em
`docs/multiempresa-f0.md`. **Regra do período:** nenhuma funcionalidade nova nas `app_*` (decisão 108, item 7); um PR
por família, regressão inteira verde em todos; nenhuma assinatura de função muda (a conta vem do contexto).

## Etapas

| Etapa | Família | O que muda | Situação |
|---|---|---|---|
| F2a | Base | `fn_conta_atual` (sessão do painel; cabeçalho `x-conta` para quem está em mais de uma conta); `app_exigir` exige a conta e confere o papel nela; `app_meu_acesso` lista as contas; T57 | Migration 117 |
| F2b | Cadastros | técnicos, empresas, locais, times, habilidades, tipos, usuários e permissões do RH: leitura e escrita só da conta; registro novo nasce com a conta da sessão | A fazer |
| F2c | Programação | escalas, cargas, envio, ligações, pendências, linha do tempo, painel gerencial e indicadores | A fazer |
| F2d | Documentos | documentos, dossiê, OCR (Edge Function com o papel da conta) | A fazer |
| F2e | Ponto | `app_ponto_*`, AFD sem empresa livre, `ponto_*` pela conta do funcionário, login do ponto com o identificador da conta, Storage com prefixo | A fazer |
| F2f | Motor e canais | `fn_*` do motor, webhook e cron por conta; `fn_papel` por conta; fim do default "conta 1" em `conta_id` | A fazer |

## Régua (T57)

O admin de uma conta B chama **toda** `app_*` com argumentos da conta A, montados do catálogo pelo nome e tipo de cada
parâmetro, cada chamada numa subtransação desfeita. Conta como vazamento quem devolve identificador ou nome da conta A
(leitura) ou muda dado dela (escrita). Em modo relatório até a F2f; depois, vazamento derruba o CI e função nova entra
coberta sozinha.

**Linha de base (F2a, 26/10, banco vazio com o seed):** o T57 escolhe a linha da conta A pelo menor id (aleatório),
então o resultado varia um pouco a cada rodada. **Escrita (3 a 4 por rodada):** `app_definir_rh_folhas`,
`app_remover_escala`, `app_salvar_time`, `app_salvar_usuario`, `app_time_definir_membros`. **Leitura (13 ou 14):**
`app_aptidao`, `app_carga_excedida`, `app_documentos_por_tecnico`, `app_dossie_local`, `app_empresas`,
`app_escala_edicao`, `app_escalas`, `app_linha_do_tempo`, `app_locais`, `app_painel_locais`, `app_pendencias`,
`app_tecnico_habilidades`, `app_tecnicos` e, conforme o teto de códigos por hora, `app_ponto_gerar_codigo`. Cerca de 64
recusam e 26 não devolvem dado da A. **Recusa não prova isolamento:** parte recusa pelo argumento genérico; cada família melhora os
argumentos das suas funções até a recusa ser pela conta.

## Pontos em aberto

- **Trava (revisão do `seguranca`, P1):** gatilho `tg_trava_conta_unica` recusa membro fora da conta 1 enquanto as
  famílias não filtram pela conta. **Condição para criar a primeira conta de cliente:** T57 em exigência e a trava
  removida, na F2f. Até lá, nenhuma conta além da 1 ganha membro.
- **Papel por conta (P1, na mesma trava):** seis funções e a política do Storage decidem máscara e aprovação de hora
  extra por `fn_papel` (global); cada família troca por `fn_papel_na_conta` na sua etapa.
- **`app_meu_acesso` (P2):** o campo `papel` ainda vem de `painel_usuarios`; o papel por conta está em `contas`. O
  painel passa a usar o da conta na F3.

- **Várias contas por usuário no Supabase Auth (P1 da estimativa):** resolvido pelo cabeçalho `x-conta`, conferido no
  banco. Falta provar no painel (F3) que o gateway da API deixa o cabeçalho passar (CORS).
- `fn_papel` segue global até a F2f: Edge Functions e 18 funções o usam; para a conta 1 é o mesmo papel (espelho).
