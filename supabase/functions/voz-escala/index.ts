// URA de voz (Twilio) — item 2 do backlog
// O banco decide quem ligar (vw_ligacoes_pendentes) e monta o texto (fn_voz_twiml).
// Esta funcao faz a chamada na Twilio e serve o TwiML.
// Deploy: supabase functions deploy voz-escala --no-verify-jwt
//
// Rotas (todas exigem ?token= igual ao segredo VOZ_TOKEN do Vault):
//   ?acao=iniciar  { ligacao_id }  -> cria a chamada na Twilio
//   ?acao=twiml&ligacao=<id>       -> TwiML falado ao atender
//   ?acao=digito&ligacao=<id>      -> tecla digitada (ou sem_resposta=1)
//   ?acao=status&ligacao=<id>      -> callback de status da chamada
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2, idle_timeout: 20 });

const xml = (corpo: string) =>
  new Response(corpo, { status: 200, headers: { "Content-Type": "text/xml; charset=utf-8" } });

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

const desligar = () => xml('<?xml version="1.0" encoding="UTF-8"?><Response><Hangup/></Response>');

async function tokenValido(token: string): Promise<boolean> {
  if (!token) return false;
  const linhas = await sql<{ ok: boolean }[]>`select fn_segredo('VOZ_TOKEN') = ${token} as ok`;
  return linhas[0]?.ok === true;
}

/** Parametros da Twilio chegam como formulario; os nossos, na query string. */
async function parametros(req: Request): Promise<Record<string, string>> {
  if (req.method !== "POST") return {};
  const tipo = req.headers.get("content-type") ?? "";
  if (tipo.includes("application/x-www-form-urlencoded")) {
    return Object.fromEntries(new URLSearchParams(await req.text()));
  }
  if (tipo.includes("application/json")) {
    try { return (await req.json()) as Record<string, string>; } catch { return {}; }
  }
  return {};
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const acao = url.searchParams.get("acao") ?? "";
  const ligacao = url.searchParams.get("ligacao") ?? "";

  if (!(await tokenValido(url.searchParams.get("token") ?? ""))) {
    return acao === "iniciar" ? json({ ok: false, erro: "nao autorizado" }, 401) : desligar();
  }

  const form = await parametros(req);

  try {
    if (acao === "iniciar") {
      const id = String(form.ligacao_id ?? "");
      if (!id) return json({ ok: false, erro: "ligacao_id ausente" }, 400);

      const [dados] = await sql<{
        para: string; de: string; sid: string; token: string; url_base: string; voz_token: string;
      }[]>`
        select (d->>'para') as para, (d->>'de') as de, (d->>'sid') as sid,
               (d->>'token') as token, (d->>'url_base') as url_base, (d->>'voz_token') as voz_token
        from (select jsonb_build_object(
                'para', '+' || t.telefone_e164, 'de', fn_config('twilio_caller_id'),
                'sid', fn_segredo('TWILIO_ACCOUNT_SID'), 'token', fn_segredo('TWILIO_AUTH_TOKEN'),
                'url_base', fn_config('voz_url'), 'voz_token', fn_segredo('VOZ_TOKEN')) as d
              from ligacoes l join tecnicos t on t.id = l.tecnico_id
              where l.id = ${id}::uuid) x`;

      if (!dados?.sid || !dados?.token) {
        await sql`select fn_registrar_call_sid(${id}::uuid, null, 'Credenciais da Twilio ausentes no Vault')`;
        return json({ ok: false, erro: "credenciais twilio ausentes" }, 400);
      }
      if (!dados.de) {
        await sql`select fn_registrar_call_sid(${id}::uuid, null, 'twilio_caller_id nao configurado')`;
        return json({ ok: false, erro: "caller id ausente" }, 400);
      }

      const base = `${dados.url_base}?ligacao=${id}&token=${encodeURIComponent(dados.voz_token)}`;
      const corpo = new URLSearchParams({
        To: dados.para,
        From: dados.de,
        Url: `${base}&acao=twiml`,
        Method: "POST",
        StatusCallback: `${base}&acao=status`,
        StatusCallbackMethod: "POST",
        StatusCallbackEvent: "completed",
        Timeout: "30",
      });

      const resp = await fetch(
        `https://api.twilio.com/2010-04-01/Accounts/${dados.sid}/Calls.json`,
        {
          method: "POST",
          headers: {
            Authorization: "Basic " + btoa(`${dados.sid}:${dados.token}`),
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: corpo,
        },
      );
      const dadosTwilio = await resp.json().catch(() => ({}));

      if (!resp.ok) {
        const msg = (dadosTwilio as { message?: string }).message ?? `HTTP ${resp.status}`;
        await sql`select fn_registrar_call_sid(${id}::uuid, null, ${msg})`;
        return json({ ok: false, erro: msg }, 200);
      }

      const callSid = (dadosTwilio as { sid?: string }).sid ?? null;
      await sql`select fn_registrar_call_sid(${id}::uuid, ${callSid}, null)`;
      return json({ ok: true, call_sid: callSid });
    }

    if (!ligacao) return desligar();

    if (acao === "twiml") {
      const [r] = await sql<{ twiml: string }[]>`select fn_voz_twiml(${ligacao}::uuid) as twiml`;
      return xml(r?.twiml ?? "");
    }

    if (acao === "digito") {
      const digito = url.searchParams.get("sem_resposta") === "1" ? "" : String(form.Digits ?? "");
      const [r] = await sql<{ twiml: string }[]>`select fn_voz_resposta(${ligacao}::uuid, ${digito}) as twiml`;
      return xml(r?.twiml ?? "");
    }

    if (acao === "status") {
      await sql`select fn_voz_status(${ligacao}::uuid, ${String(form.CallStatus ?? "")},
                                    ${String(form.CallDuration ?? "")}, ${String(form.CallPrice ?? "")})`;
      return json({ ok: true });
    }

    return desligar();
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("voz-escala:", acao, msg);
    return acao === "iniciar" ? json({ ok: false, erro: msg }, 200) : desligar();
  }
});
