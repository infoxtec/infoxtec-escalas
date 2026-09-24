# Twilio (URA de voz)

## Segredos (Supabase Vault)

Atencao a ordem dos parametros: `vault.create_secret(VALOR, NOME)`.

```sql
select vault.create_secret('AC...seu_account_sid', 'TWILIO_ACCOUNT_SID');
select vault.create_secret('seu_auth_token',       'TWILIO_AUTH_TOKEN');
select vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'), 'VOZ_TOKEN');

update config set valor = '+55DDDNUMERO' where chave = 'twilio_caller_id';
```

## No console da Twilio

1. **Trust Hub → Primary Customer Profile**: aprovado (obrigatorio, mesmo em conta paga).
2. **Voice → Settings → Geo Permissions**: Brazil habilitado para saida.
3. **Phone Numbers → Manage → Verified Caller IDs**: verificar o numero que aparece no visor
   do tecnico. O numero precisa atender a ligacao (ou receber o SMS) com o codigo de 6 digitos.

Nao e necessario comprar numero para operar com Verified Caller ID.

**Escolha do numero identificador:** precisa ser um numero que receba a ligacao (ou o SMS) com o
codigo de 6 digitos da Twilio. Numeros virtuais, ou linhas usadas so para WhatsApp Business, podem
nao completar a verificacao. Um celular comum da empresa e a escolha mais segura.

**Limitacao:** nao da para ligar do numero identificador para ele mesmo — origem e destino iguais
sao recusados. Se o identificador for o celular do supervisor, ele nao pode ser usado nos testes
como destino.

## Parametros (`config`)

| Chave | Padrao | Efeito |
|---|---|---|
| `ligacao_ativa` | false | Liga o disparo automatico |
| `ligacao_apos_tentativas` | 2 | Tentativas de WhatsApp sem resposta antes de ligar |
| `ligacao_janela_inicio` / `_fim` | 08:00 / 20:00 | Janela das ligacoes |
| `ligacao_max_por_escala` | 2 | Teto por escala |
| `ligacao_intervalo_min` | 45 | Minutos entre duas ligacoes da mesma escala |
| `ligacao_por_execucao` | 2 | Teto por execucao do dispatcher |
| `twilio_caller_id` | — | Numero verificado, com +55 |
| `voz_voice` | Polly.Camila-Neural | Voz em pt-BR |
| `voz_timeout_dtmf` | 6 | Segundos aguardando a tecla |

## Diagnostico

```sql
-- ultimas ligacoes
select l.criada_em at time zone 'America/Bahia' as quando, t.nome, l.status, l.digito,
       l.duracao_seg, l.preco, l.erro
from ligacoes l join tecnicos t on t.id = l.tecnico_id
order by l.criada_em desc limit 20;

-- quem esta na fila para receber ligacao agora
select * from vw_ligacoes_pendentes;
```

Consultar a Twilio direto do banco (status real de uma chamada):

```sql
select net.http_get(
  url := 'https://api.twilio.com/2010-04-01/Accounts/' || fn_segredo('TWILIO_ACCOUNT_SID')
         || '/Calls/CAxxxxxxxx.json',
  headers := jsonb_build_object('Authorization',
    'Basic ' || replace(encode(convert_to(fn_segredo('TWILIO_ACCOUNT_SID') || ':' ||
      fn_segredo('TWILIO_AUTH_TOKEN'), 'UTF8'), 'base64'), E'\n','')));
-- depois: select * from fn_http_resposta(<id devolvido>);
```

> O `replace(..., E'\n','')` e obrigatorio: o Postgres quebra o base64 em linhas e o cabecalho
> HTTP e recusado sem isso.

## Custo

US$ 0,0663 por minuto para celular no Brasil. Uma ligacao tipica de 40 segundos custa cerca de
R$ 0,24. Com 10 tecnicos, menos de R$ 20 por mes.
