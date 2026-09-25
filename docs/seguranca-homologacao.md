# Segurança, homologação e uso comercial

Roteiro para levar o sistema de "funciona na Infoxtec" para "pode ser vendido com segurança".
As tarefas estão no Roadmap do painel, grupo **Segurança e homologação**.

## O bloqueio principal

**A Evolution API viola os termos do WhatsApp.** Para uso interno, é um risco operacional que a
empresa assumiu conscientemente. Para vender a terceiros, muda de natureza: o número do cliente
pode ser banido, a operação dele para, e a responsabilidade recai sobre quem vendeu a solução.

Nenhuma outra tarefa desta lista compensa esse risco. A migração para a API oficial da Meta é a
primeira coisa a fazer antes de qualquer conversa comercial — e custa entre R$ 8 e R$ 11 por mês
no volume atual.

## Ordem recomendada

**Bloco 1 — o que impede vender (semanas 1 a 4)**

1. Migrar o WhatsApp para a API oficial
2. Ambiente de homologação separado
3. MFA em todas as contas administrativas
4. Backup testado com restauração cronometrada

O ambiente de homologação vem cedo de propósito: sem ele, toda mudança continua sendo testada em
produção, com mensagens reais indo para técnicos reais — e nenhuma homologação formal é possível.

**Bloco 2 — privacidade e operação (semanas 5 a 8)**

5. Inventário de dados pessoais e base legal
6. Política de privacidade e aviso aos técnicos
7. Encarregado de dados e canal do titular
8. Plano de resposta a incidentes
9. Monitoramento e alertas de operação
10. Varredura de vulnerabilidades e dependências

**Bloco 3 — evidência e contrato (semanas 9 a 12)**

11. Testes automatizados das regras críticas
12. Revisão formal de RLS e permissões
13. Trilha de auditoria exportável
14. Teste de intrusão (pentest)
15. Contrato, termo de uso e SLA
16. Validação jurídica da jornada CLT
17. Rotação e inventário de segredos

O pentest fica no fim por dois motivos: custa caro e só faz sentido sobre um sistema estável, com
ambiente de homologação pronto. Rodar em produção com dados reais é arriscado.

## Sobre certificações

**ISO 27001 é certificação da organização, não do software.** O Supabase e o Vercel já a possuem
para a infraestrutura deles, o que cobre datacenter, criptografia e gestão de acesso do provedor.
Para a Infoxtec dizer que é certificada, o caminho é outro: sistema de gestão de segurança da
informação implantado, auditoria de certificação e manutenção anual. É projeto de 12 a 18 meses e
custo relevante.

O que dá para afirmar com honestidade, cumprindo esta lista: sistema desenvolvido com controle de
acesso por papel, criptografia em repouso e em trânsito, trilha de auditoria, backup testado,
plano de resposta a incidentes e programa de privacidade conforme a LGPD — hospedado em
infraestrutura certificada ISO 27001 e SOC 2. Isso atende a maioria dos questionários de
fornecedor sem prometer o que não existe.

## O que dizer ao cliente sobre disponibilidade

Antes de assinar SLA, decidir e escrever: o que acontece quando o WhatsApp falha, quanto tempo a
operação pode ficar sem envio, e qual é o plano manual enquanto isso. É o ponto mais provável de
conflito comercial, porque depende de terceiros.
