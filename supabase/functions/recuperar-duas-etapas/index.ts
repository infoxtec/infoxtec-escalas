// Recuperação da verificação em duas etapas (migration 140, decisão 128). Quem perdeu o autenticador entra com a senha
// (sessão aal1) e pede um código por e-mail ou WhatsApp; com o código certo (os dois, se for da plataforma), esta função
// apaga os fatores do login no Supabase Auth e o painel pede o autenticador novo. Quem pode, limites, códigos e avisos:
// tudo no banco (fn_mfa_recuperacao_pedir, _confirmar e _concluir). A chave de serviço só existe aqui.
// Deploy: supabase functions deploy recuperar-duas-etapas
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { connection: { search_path: "interno, public, extensions" }, prepare: false, max: 2, idle_timeout: 20 });

const TIMEOUT_MS = 15_000;
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

/** Cabeçalhos de administrador do Auth: a chave secreta nova vai só no apikey; a antiga (JWT), também no Authorization. */
function cabecalhosAdmin(): Record<string, string> | null {
  try {
    const nova = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")?.default;
    if (typeof nova === "string" && nova.startsWith("sb_secret_")) return { apikey: nova };
  } catch { /* segue para a antiga */ }
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  return antiga ? { apikey: antiga, Authorization: `Bearer ${antiga}` } : null;
}

const CODIGO = /^[0-9]{6}$/;

Deno.serve(async (req: Request) => {
  const CORS = cabecalhosCors(req);
  const json = (corpo: unknown, status = 200) =>
    new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > 1024) return json({ ok: false, erro: "pedido grande demais" }, 413);

  const email = await emailVerificado(req);
  if (!email) return json({ ok: false, erro: "Sessão expirada. Entre novamente com a senha." }, 401);

  let corpo: { acao?: unknown; canal?: unknown; codigo_email?: unknown; codigo_whatsapp?: unknown };
  const texto = await req.text();
  if (texto.length > 1024) return json({ ok: false, erro: "pedido grande demais" }, 413);
  try { corpo = JSON.parse(texto); } catch { return json({ ok: false, erro: "pedido inválido" }, 400); }

  try {
    if (corpo.acao === "pedir") {
      const canal = corpo.canal === "whatsapp" ? "whatsapp" : corpo.canal === "email" ? "email" : "";
      if (!canal) return json({ ok: false, erro: "Escolha e-mail ou WhatsApp." }, 400);
      const [linha] = await sql<{ r: unknown }[]>`select fn_mfa_recuperacao_pedir(${email}, ${canal}) as r`;
      return json({ ok: true, ...(linha.r as Record<string, unknown>) });
    }
    if (corpo.acao === "confirmar") {
      const ce = typeof corpo.codigo_email === "string" && CODIGO.test(corpo.codigo_email) ? corpo.codigo_email : null;
      const cw = typeof corpo.codigo_whatsapp === "string" && CODIGO.test(corpo.codigo_whatsapp) ? corpo.codigo_whatsapp : null;
      if (!ce && !cw) return json({ ok: false, erro: "Digite o código de 6 dígitos." }, 400);
      const [linha] = await sql<{ r: { usuario?: string; erro?: string; email_ok?: boolean; whatsapp_ok?: boolean } }[]>`
        select fn_mfa_recuperacao_confirmar(${email}, ${ce}, ${cw}) as r`;
      if (linha.r.erro || !linha.r.usuario || !UUID.test(linha.r.usuario)) {
        return json({ ok: false, erro: linha.r.erro ?? "Código errado ou vencido." }, 400);
      }
      const admin = cabecalhosAdmin();
      if (!admin) return json({ ok: false, erro: "Recuperação indisponível: falta a chave de serviço na função." }, 500);
      const base = `${Deno.env.get("SUPABASE_URL")}/auth/v1/admin/users/${linha.r.usuario}/factors`;
      const lista = await fetch(base, { headers: admin, signal: AbortSignal.timeout(TIMEOUT_MS) });
      if (!lista.ok) throw new Error(`auth ${lista.status}`);
      const fatores = await lista.json() as { id?: string }[];
      for (const f of Array.isArray(fatores) ? fatores : []) {
        if (!f.id || !UUID.test(f.id)) continue;
        const del = await fetch(`${base}/${f.id}`, { method: "DELETE", headers: admin, signal: AbortSignal.timeout(TIMEOUT_MS) });
        if (!del.ok && del.status !== 404) throw new Error(`auth ${del.status}`);
      }
      // só depois de o autenticador sair de fato: códigos dados como usados e avisos (à pessoa e à plataforma)
      await sql`select fn_mfa_recuperacao_concluir(${email}, ${!!linha.r.email_ok}, ${!!linha.r.whatsapp_ok})`;
      return json({ ok: true, removidos: Array.isArray(fatores) ? fatores.length : 0 });
    }
    return json({ ok: false, erro: "Ação desconhecida." }, 400);
  } catch (err) {
    const e = err as { code?: string; message?: string };
    // recusa nossa (raise P0001) volta como está; o resto vira a mensagem genérica
    if (e?.code === "P0001" && e.message) return json({ ok: false, erro: e.message }, 400);
    console.error("recuperar-duas-etapas:", e?.code ?? (err instanceof Error ? err.message.slice(0, 120) : "erro"));
    return json({ ok: false, erro: "Não foi possível concluir agora. Tente de novo em alguns minutos." }, 500);
  }
});
