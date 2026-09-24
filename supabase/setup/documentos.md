# Documentos dos tecnicos (item 10)

## Onde os arquivos ficam

Bucket **privado** `documentos` no Storage do Supabase:

- criptografia em repouso (AES-256) e em transito (TLS), pela infraestrutura do Supabase
- sem URL publica: o painel gera **link assinado de 2 minutos** a cada abertura
- politicas de acesso no proprio banco: so `authenticated` com papel **admin** ou **gestor**
- limite de 8 MB por arquivo; apenas PDF, JPG e PNG

## Retencao

`retencao_documentos_anos` = 5. A contagem comeca na **data de desligamento** do tecnico,
informada no cadastro (`tecnicos.desligado_em`). A view `vw_documentos_expirados` lista o que ja
passou do prazo; `app_documentos_expirados()` expoe isso ao administrador.

```sql
select * from vw_documentos_expirados;
```

O expurgo e feito pelo painel (apaga o arquivo no Storage e o registro), para que a exclusao
fique registrada por quem a executou.

## OCR (opcional)

Edge Function `documento-ocr`. Le **imagens** (JPG/PNG) e sugere a data de validade; PDF nao e
lido automaticamente. A sugestao **nunca grava sozinha**: aparece no campo para conferencia.

Para ligar, cadastre a chave do Google Cloud Vision:

```sql
select vault.create_secret('SUA_CHAVE_DO_VISION', 'GOOGLE_VISION_KEY');
```

Sem a chave, o painel continua funcionando normalmente e apenas informa que o OCR nao esta ligado.
Cota gratuita do Vision: 1.000 paginas por mes.

## Sobre normas de seguranca

O Supabase mantem certificacao **ISO/IEC 27001** e **SOC 2 Tipo 2** para sua infraestrutura, o que
cobre datacenter, criptografia e gestao de acesso do provedor. Certificacao e da organizacao, nao
do codigo: o que este projeto garante e o desenho — bucket privado, acesso por papel, link
temporario, retencao definida e trilha de quem enviou cada arquivo. A conformidade da Infoxtec
como empresa depende de politica interna, contrato com os titulares e processo de resposta a
incidentes.
