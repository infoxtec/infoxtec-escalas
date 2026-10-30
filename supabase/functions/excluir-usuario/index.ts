// Exclusão definitiva de usuário pelo painel (migration 134). O administrador da conta, ou a plataforma, tira a pessoa
// da conta: o banco confere quem pode, apaga o vínculo e registra (fn_usuario_excluir); se ela não for de outra conta
// nem da plataforma, esta função apaga também o login no Supabase Auth (com os fatores de duas etapas).
// A chave de serviço só existe aqui (SUPABASE_SECRET_KEYS, ou a antiga SUPABASE_SERVICE_ROLE_KEY): nunca sai da função.
// Deploy: supabase functions deploy excluir-usuario
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { connection: { search_path: "interno, public, extensions" }, prepare: false, max: 2, idle_timeout: 20 });

const TIMEOUT_MS = 15_000;
const EMAIL = /^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// mesmos domínios do painel que a documento-ocr aceita (produção na Vercel; homologação local, Vercel e Cloudflare)
const ORIGEM_PAINEL = /^https:\/\/(infoxtec-escalas|web-[a-z0-9-]+-infoxtec-escalas)\.vercel\.app$/;
const ORIGENS_HOMOLOGACAO = ["http://localhost:5173", "https://infoxtec-escalas-homologacao.vercel.app"];
const ORIGEM_HOMOLOGACAO_CF = /^https:\/\/([a-z0-9][a-z0-9-]{0,62}-)?trilha-homologacao\.david-cerqueira\.workers\.dev$/;
const HOMOLOGACAO = /oruwnlxyvznpigbpjjbx|\/\/(127\.0\.0\.1|localhost|kong)[:/]/.test(Deno.env.get("SUPABASE_URL") ?? "");

function origemDoPainel(req: Request): string | null {
  const origem = req.headers.get("Origin") ?? "";
  return ORIGEM_PAINEL.test(origem) || (HOMOLOGACAO && (ORIGENS_HOMOLOGACAO.includes(origem) || ORIGEM_HOMOLOGACAO_CF.test(origem)))
    ? origem : null;
}

function cabecalhosCors(req: Request): Record<string, string> {
  const origem = origemDoPainel(req);
  return {
    ...(origem ? { "Access-Control-Allow-Origin": origem } : {}),
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-conta",
    "Vary": "Origin",
  };
}

/** E-mail do usuário, conferido no servidor de autenticação (assinatura e expiração do token). */
async function emailVerificado(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return null;
  const doCliente = req.headers.get("apikey") ?? "";
  const apikey = /^sb_publishable_[A-Za-z0-9_-]{1,100}$/.test(doCliente) ? doCliente : (Deno.env.get("SUPABASE_ANON_KEY") ?? "");
  try {
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, {
      headers: { Authorization: auth, apikey },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!resp.ok) return null;
    const usuario = await resp.json();
    return typeof usuario?.email === "string" ? usuario.email.toLowerCase() : null;
  } catch {
    return null;
  }
}

/** Nível da sessão (aal1 só senha; aal2 com o código do autenticador), lido do token já conferido. */
function nivelDaSessao(req: Request): string | null {
  try {
    const parte = (req.headers.get("Authorization") ?? "").split(/\s+/)[1]?.split(".")[1] ?? "";
    const json = atob(parte.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parte.length / 4) * 4, "="));
    const aal = JSON.parse(json)?.aal;
    return typeof aal === "string" ? aal : null;
  } catch {
    return null;
  }
}

/** Cabeçalhos de administrador do Auth: a chave secreta nova vai só no apikey; a antiga (JWT), também no Authorization. */
function cabecalhosAdmin(): Record<string, string> | null {
  try {
    const nova = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")?.default;
    if (typeof nova === "string" && nova.startsWith("sb_secret_")) return { apikey: nova };
  } catch { /* segue para a antiga */ }
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  return antiga ? { apikey: antiga, Authorization: `Bearer ${antiga}` } : null;
}

Deno.serve(async (req: Request) => {
  const CORS = cabecalhosCors(req);
  const json = (corpo: unknown, status = 200) =>
    new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > 2048) return json({ ok: false, erro: "pedido grande demais" }, 413);

  const autor = await emailVerificado(req);
  if (!autor) return json({ ok: false, erro: "Sessão expirada. Entre novamente." }, 401);

  let corpo: { email?: unknown; conta?: unknown };
  const texto = await req.text();
  if (texto.length > 2048) return json({ ok: false, erro: "pedido grande demais" }, 413);
  try { corpo = JSON.parse(texto); } catch { return json({ ok: false, erro: "pedido inválido" }, 400); }
  const email = typeof corpo.email === "string" ? corpo.email.trim().toLowerCase() : "";
  const conta = typeof corpo.conta === "string" ? corpo.conta : "";
  if (!EMAIL.test(email) || !UUID.test(conta)) return json({ ok: false, erro: "Informe o e-mail e a conta." }, 400);

  // quem pode e o que sai: tudo no banco, numa transação; a recusa é a mensagem do banco (texto nosso, sem dado de outros)
  let r: { id: string; login: string | null; email: string; plataforma: boolean };
  try {
    const [linha] = await sql<{ r: { id: string; login: string | null; email: string; plataforma: boolean } }[]>`
      select fn_usuario_excluir(${autor}, ${nivelDaSessao(req)}, ${conta}::uuid, ${email}) as r`;
    r = linha.r;
  } catch (err) {
    const e = err as { code?: string; message?: string };
    console.error("excluir-usuario: recusado", e?.code ?? "erro");
    return json({ ok: false, erro: e?.code === "P0001" && e.message ? e.message : "Sem permissão para esta ação." }, 403);
  }
  // o admin de um cliente não descobre se a pessoa usa outras contas: a resposta é a mesma
  const resposta = (login_apagado: boolean | null) =>
    json(r.plataforma ? { ok: true, login_apagado } : { ok: true });
  if (!r.login || !UUID.test(r.login)) return resposta(null);

  const admin = cabecalhosAdmin();
  if (!admin) {
    await sql`select fn_usuario_excluir_resultado(${r.id}::bigint, false)`;
    console.error("excluir-usuario: falta a chave de serviço");
    return resposta(false);
  }
  try {
    // entre a exclusão e aqui, outra conta pode ter convidado a pessoa: então o login fica
    const [livre] = await sql<{ ok: boolean }[]>`select fn_usuario_login_livre(${r.email}) as ok`;
    if (!livre?.ok) {
      await sql`select fn_usuario_excluir_resultado(${r.id}::bigint, null)`;
      return resposta(null);
    }
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/admin/users/${r.login}`, {
      method: "DELETE", headers: admin, signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const ok = resp.ok || resp.status === 404;
    if (!ok) console.error("excluir-usuario: auth respondeu", resp.status);
    await sql`select fn_usuario_excluir_resultado(${r.id}::bigint, ${ok})`;
    return resposta(ok);
  } catch (err) {
    console.error("excluir-usuario: falha", err instanceof Error ? err.name : "erro");
    await sql`select fn_usuario_excluir_resultado(${r.id}::bigint, false)`;
    return resposta(false);
  }
});
