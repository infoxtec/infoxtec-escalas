// E-mail de alerta da plataforma (migration 135): hoje, o WhatsApp (Evolution) fora do ar e de volta. Chamada só pelo
// banco (pg_net), com o token do Vault no cabeçalho x-alerta-token, conferido no banco. O banco devolve assunto, texto,
// destinatários e o SMTP (sem a senha); a senha da caixa fica só no segredo ALERTA_SMTP_SENHA desta função.
// A Edge Function do Supabase não sai pela porta 587: o padrão é a 465 (SSL).
// Deploy: supabase functions deploy alerta-email --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import nodemailer from "npm:nodemailer@6.9.16";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false, max: 1, idle_timeout: 20,
  connection: { statement_timeout: 15000, search_path: "interno, public, extensions" },
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Dados = { assunto: string; texto: string; para: string[]; smtp: { host: string; porta: string; usuario: string } };

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const token = req.headers.get("x-alerta-token") ?? "";
  if (!/^[0-9a-f]{64}$/.test(token)) return json({ ok: false, erro: "nao autorizado" }, 401);
  if (Number(req.headers.get("content-length") ?? 0) > 256) return json({ ok: false, erro: "corpo grande demais" }, 413);
  let id: number;
  try {
    const texto = await req.text();
    if (texto.length > 256) return json({ ok: false, erro: "corpo grande demais" }, 413);
    id = Number(JSON.parse(texto)?.id);
  } catch {
    return json({ ok: false, erro: "json invalido" }, 400);
  }
  if (!Number.isSafeInteger(id) || id <= 0) return json({ ok: false, erro: "id invalido" }, 400);

  let d: Dados | null;
  try {
    const [linha] = await sql<{ d: Dados | null }[]>`select fn_alerta_email_dados(${token}, ${id}) as d`;
    d = linha?.d ?? null;
  } catch (err) {
    const msg = err instanceof Error ? err.message : "erro";
    console.error("alerta-email:", /token/.test(msg) ? "token invalido" : msg.slice(0, 200));
    return json({ ok: false, erro: /token/.test(msg) ? "nao autorizado" : "falha" }, /token/.test(msg) ? 401 : 500);
  }
  if (!d) return json({ ok: true, info: "nada a enviar" });

  const senha = Deno.env.get("ALERTA_SMTP_SENHA");
  const porta = Number(d.smtp.porta) || 465;
  let erro: string | null = null;
  if (!senha) erro = "falta o segredo ALERTA_SMTP_SENHA na Edge Function";
  else if (d.para.length === 0) erro = "sem destinatário";
  else {
    try {
      const envio = nodemailer.createTransport({
        host: d.smtp.host, port: porta, secure: porta === 465,
        auth: { user: d.smtp.usuario, pass: senha },
        connectionTimeout: 15000, greetingTimeout: 10000, socketTimeout: 20000,
      });
      await envio.sendMail({ from: `Trilha <${d.smtp.usuario}>`, to: d.para.join(", "), subject: d.assunto, text: d.texto });
    } catch (err) {
      erro = (err instanceof Error ? err.message : "falha no envio").slice(0, 300);
    }
  }
  try {
    await sql`select fn_alerta_email_resultado(${token}, ${id}, ${erro === null}, ${erro})`;
  } catch (err) {
    console.error("alerta-email: resultado", err instanceof Error ? err.message.slice(0, 200) : "erro");
  }
  if (erro) console.error("alerta-email: não enviado:", erro);
  return json({ ok: erro === null, ...(erro ? { erro } : {}) });
});
