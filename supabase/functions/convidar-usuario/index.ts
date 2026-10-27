// Convite por e-mail pelo painel (decisão 120). O administrador da conta, ou a plataforma ao criar uma conta, convida
// quem já é membro dela: o banco confere quem pode e registra (fn_convite_autorizar), e esta função chama o convite do
// Supabase Auth, que manda o e-mail com o link para criar a senha. Quem já tem login não recebe convite: entra com a
// senha atual e vê a conta nova no seletor.
// A chave de serviço só existe aqui (SUPABASE_SECRET_KEYS, ou a antiga SUPABASE_SERVICE_ROLE_KEY): nunca sai da função.
// Deploy: supabase functions deploy convidar-usuario
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

// para onde o link do e-mail volta: na produção, só o painel oficial (pré-visualização é domínio que terceiros podem
// criar na Vercel); na homologação, os painéis da lista. Painel da produção no Cloudflare (decisão 116): incluir aqui
const PAINEL_PRODUCAO = "https://infoxtec-escalas.vercel.app";
function destinoDoLink(req: Request): string | null {
  const origem = origemDoPainel(req);
  if (!origem) return null;
  return HOMOLOGACAO || origem === PAINEL_PRODUCAO ? origem : null;
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
  try { corpo = JSON.parse(await req.text()); } catch { return json({ ok: false, erro: "pedido inválido" }, 400); }
  const email = typeof corpo.email === "string" ? corpo.email.trim().toLowerCase() : "";
  const conta = typeof corpo.conta === "string" ? corpo.conta : "";
  if (!EMAIL.test(email) || !UUID.test(conta)) return json({ ok: false, erro: "Informe o e-mail e a conta." }, 400);

  // quem pode, limites e registro: tudo no banco; a mensagem de recusa é a do banco (texto nosso, sem dado de outros)
  let id: string;
  let plataforma: boolean;
  try {
    const [linha] = await sql<{ id: string; plataforma: boolean }[]>`
      select fn_convite_autorizar(${autor}, ${nivelDaSessao(req)}, ${conta}::uuid, ${email})::text as id,
             exists (select 1 from plataforma_admins where email = ${autor}) as plataforma`;
    id = linha.id;
    plataforma = linha.plataforma;
  } catch (err) {
    // só as recusas nossas (raise, P0001) voltam ao painel; outro erro do banco vira a mensagem genérica
    const e = err as { code?: string; message?: string };
    console.error("convidar-usuario: recusado", e?.code ?? "erro");
    return json({ ok: false, erro: e?.code === "P0001" && e.message ? e.message : "Sem permissão para esta ação." }, 403);
  }

  const admin = cabecalhosAdmin();
  if (!admin) {
    await sql`select fn_convite_resultado(${id}::bigint, 'falhou')`;
    return json({ ok: false, erro: "Convite indisponível: falta a chave de serviço na função." }, 500);
  }
  // o link do e-mail volta para o painel de onde o convite saiu (se for um painel conhecido); senão, o Site URL do Auth
  const origem = destinoDoLink(req);
  const destino = `${Deno.env.get("SUPABASE_URL")}/auth/v1/invite${origem ? `?redirect_to=${encodeURIComponent(origem)}` : ""}`;
  try {
    const resp = await fetch(destino, {
      method: "POST",
      headers: { ...admin, "Content-Type": "application/json" },
      body: JSON.stringify({ email }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (resp.ok) {
      await sql`select fn_convite_resultado(${id}::bigint, 'enviado')`;
      return json({ ok: true, enviado: true });
    }
    const erro = await resp.json().catch(() => ({}));
    const codigo = String(erro?.error_code ?? erro?.code ?? "");
    if (resp.status === 422 && /exists|registered/i.test(`${codigo} ${erro?.msg ?? ""}`)) {
      await sql`select fn_convite_resultado(${id}::bigint, 'ja_tinha_login')`;
      // só a plataforma sabe que a pessoa já tinha login (o admin de um cliente não descobre quem usa outras contas)
      return json(plataforma ? { ok: true, enviado: false, ja_tinha_login: true } : { ok: true, enviado: true });
    }
    console.error("convidar-usuario: auth respondeu", resp.status, codigo);
    await sql`select fn_convite_resultado(${id}::bigint, 'falhou')`;
    const limite = resp.status === 429 || /rate/i.test(codigo);
    return json({ ok: false, erro: limite ? "Limite de e-mails do Supabase atingido. Tente mais tarde." : "O e-mail de convite não pôde ser enviado." }, 502);
  } catch (err) {
    console.error("convidar-usuario: falha", err instanceof Error ? err.name : "erro");
    await sql`select fn_convite_resultado(${id}::bigint, 'falhou')`;
    return json({ ok: false, erro: "O e-mail de convite não pôde ser enviado." }, 502);
  }
});
