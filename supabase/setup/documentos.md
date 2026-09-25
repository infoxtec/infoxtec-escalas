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

## Duas formas de guardar

| Modo | Onde fica | Quem controla o acesso | Retencao |
|---|---|---|---|
| **Enviar arquivo** | bucket privado do Supabase | papel no painel (admin/gestor), link de 2 min | automatica: 5 anos apos o desligamento |
| **Vincular do Drive** | Google Drive da Infoxtec | permissao do proprio Drive | manual |

O modo Drive e util quando a documentacao ja esta organizada la. A contrapartida e que o painel
deixa de controlar quem abre: se o arquivo estiver como "qualquer pessoa com o link", ele e
acessivel fora do sistema. Para documento pessoal, o modo bucket e o mais seguro.

## OCR (opcional)

### Padrao: leitura no navegador (tesseract.js)

Nao precisa de chave, conta nem cartao, e **o documento nao sai da maquina de quem cadastra** —
nada e enviado ao nosso servidor nem a terceiros. Na primeira leitura o navegador baixa o motor e
o idioma (~12 MB), que ficam em cache; cada leitura leva de 2 a 8 segundos.

Tres caminhos, escolhidos automaticamente pelo arquivo:

| Arquivo | Como e lido | Tempo |
|---|---|---|
| **PDF digital** (gerado por sistema) | texto extraido direto do arquivo, sem OCR | instantaneo e exato |
| **PDF escaneado** | pagina renderizada em imagem e lida por OCR | 3 a 10 s |
| **Imagem** (JPG/PNG) | OCR direto | 2 a 8 s |

Le ate 3 paginas do PDF procurando texto e, se nao achar data, ate 2 paginas por OCR. A escolha da
data segue a regra: a futura mais proxima; havendo so datas passadas, a maior — que e a validade
vencida, nao a emissao. A sugestao **nunca grava sozinha**: aparece no campo para conferencia.

### Opcional: leitura na nuvem (modo preciso)

Edge Function `documento-ocr`, com Google Cloud Vision. Mais rapida e mais precisa em foto ruim,
porem envia o documento ao Google e exige conta de faturamento mesmo na cota gratuita.
Fica disponivel como botao extra quando a chave estiver cadastrada.

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
