// Webhook da Evolution API -> Supabase
// Autenticacao: token na URL (?token=...), conferido dentro do banco contra o Vault.
// Toda a regra de negocio mora em SQL (fn_webhook_evolution). Esta funcao so repassa.
// Deploy: supabase functions deploy webhook-evolution --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false,
  max: 1,
  idle_timeout: 20,
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: true, info: "webhook evolution" });

  const token = new URL(req.url).searchParams.get("token") ?? "";
  if (!token) return json({ ok: false, erro: "token ausente" }, 401);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, erro: "json invalido" }, 400);
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return json({ ok: false, erro: "payload deve ser um objeto" }, 400);
  }

  try {
    // sql.json envia o objeto como jsonb uma unica vez (sem dupla serializacao)
    const rows = await sql`
      select fn_webhook_evolution(${token}, ${sql.json(payload)}) as resultado
    `;
    return json({ ok: true, resultado: rows[0]?.resultado ?? null });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("token invalido")) return json({ ok: false, erro: "nao autorizado" }, 401);
    console.error("webhook evolution:", msg);
    // 200 para a Evolution nao reenviar em loop; o erro fica no log da funcao
    return json({ ok: false, erro: "falha interna" });
  }
});
