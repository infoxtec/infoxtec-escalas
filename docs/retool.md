# Painel Retool (LEGADO)

> Substituido pelo app em `web/`. Mantido so ate o painel novo estar em uso;
> depois, desativar o app no Retool.


App React `infoxtec-escalas` no Retool (codigo hospedado no Retool).
Publicado em https://infoxtec--infoxtec-escalas.retool.app

## Conexao com o banco

Resource PostgreSQL usando a string **Session pooler** do Supabase (a conexao direta e so IPv6).
Usuario `postgres.<ref>`, porta 5432, database `postgres`, SSL ligado. A senha fica so no Retool.

## Regras do backend do app

- O e-mail de quem executa vem de `req.user.email` no servidor, nunca da tela.
- Escritas de escala passam pelas funcoes do banco (`fn_criar_escalas_lote`, `fn_mudar_status`,
  `fn_excluir_tecnico`), que conferem o papel.

## Pendente (creditos de IA do Retool esgotados em 21/09/2026)

- `/backend/escalas/_acesso.ts` com `getPapel`/`exigirPapel` (usa `fn_papel`), chamado no inicio
  de todas as funcoes de backend. Hoje `saveTecnico`, `saveLocal` e as leituras nao conferem papel.
- `getMeuAcesso` + tela "Acesso nao autorizado" para quem nao esta em `painel_usuarios`.
- Aba Usuarios (admin) usando `fn_salvar_usuario_painel`.

## Papeis

| Papel | Pode |
|---|---|
| leitura | Ver agenda, historico, tecnicos e locais |
| gestor | + criar escalas, mudar status, editar tecnicos e locais |
| admin | + excluir tecnicos e gerenciar usuarios do painel |
