// Exportação completa da conta (migration 143, decisão 129; portabilidade, LGPD art. 18, V). Duas entradas:
// 1. O banco (pg_net) chama com x-exportacao-token e {id} (ou {acao: 'limpar'}, a manutenção do motor, que só apaga os
//    pacotes vencidos): a função responde logo e, em segundo plano, lê cada tabela da
//    conta em CSV (fn_exportar_csv, só as linhas da conta do pedido), monta o ZIP (dados/<tabela>.csv, esquema.json,
//    LEIA-ME.txt, manifesto.sha256), guarda no bucket privado exportacoes e grava o resultado. Na exportação final do
//    encerramento, manda junto um link assinado de 7 dias, que o banco envia por e-mail aos administradores da conta.
// 2. O painel chama com a sessão e {acao: 'link', id}: o banco confere quem pode (fn_exportacao_link) e a função devolve
//    um link assinado de 10 minutos.
// Quem pode, o que entra e os limites ficam no banco. A chave de serviço só existe aqui.
// Deploy: supabase functions deploy exportar-conta --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import { zipSync } from "npm:fflate@0.8.2";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false, max: 2, idle_timeout: 20,
  connection: { statement_timeout: 60000, search_path: "interno, public, extensions" },
});

const TIMEOUT_MS = 15_000;
const PAGINA = 5000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUCKET = "exportacoes";

// mesmos domínios do painel das outras funções (produção na Vercel; homologação local, Vercel e Cloudflare)
const ORIGEM_PAINEL = /^https:\/\/(infoxtec-escalas|web-[a-z0-9-]+-infoxtec-escalas)\.vercel\.app$/;
const ORIGENS_HOMOLOGACAO = ["http://localhost:5173", "https://infoxtec-escalas-homologacao.vercel.app"];
const ORIGEM_HOMOLOGACAO_CF = /^https:\/\/([a-z0-9][a-z0-9-]{0,62}-)?trilha-homologacao\.david-cerqueira\.workers\.dev$/;
const HOMOLOGACAO = /oruwnlxyvznpigbpjjbx|\/\/(127\.0\.0\.1|localhost|kong)[:/]/.test(Deno.env.get("SUPABASE_URL") ?? "");

function cabecalhosCors(req: Request): Record<string, string> {
  const origem = req.headers.get("Origin") ?? "";
  const ok = ORIGEM_PAINEL.test(origem) || (HOMOLOGACAO && (ORIGENS_HOMOLOGACAO.includes(origem) || ORIGEM_HOMOLOGACAO_CF.test(origem)));
  return {
    ...(ok ? { "Access-Control-Allow-Origin": origem } : {}),
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-conta",
    "Vary": "Origin",
  };
}

/** Cabeçalhos de administrador: a chave secreta nova vai só no apikey; a antiga (JWT), também no Authorization. */
function cabecalhosAdmin(): Record<string, string> | null {
  try {
    const nova = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}")?.default;
    if (typeof nova === "string" && nova.startsWith("sb_secret_")) return { apikey: nova };
  } catch { /* segue para a antiga */ }
  const antiga = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  return antiga ? { apikey: antiga, Authorization: `Bearer ${antiga}` } : null;
}

/** E-mail do usuário, conferido no servidor de autenticação (assinatura e expiração do token). */
async function emailVerificado(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return null;
  const doCliente = req.headers.get("apikey") ?? "";
  const apikey = /^sb_publishable_[A-Za-z0-9_-]{1,100}$/.test(doCliente) ? doCliente : (Deno.env.get("SUPABASE_ANON_KEY") ?? "");
  try {
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, { headers: { Authorization: auth, apikey }, signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!resp.ok) return null;
    const u = await resp.json();
    return typeof u?.email === "string" ? u.email.toLowerCase() : null;
  } catch {
    return null;
  }
}

/** Nível da sessão (aal1 só senha; aal2 com o autenticador), lido do token já conferido. */
function nivelDaSessao(req: Request): string | null {
  try {
    const parte = (req.headers.get("Authorization") ?? "").split(/\s+/)[1]?.split(".")[1] ?? "";
    const aal = JSON.parse(atob(parte.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parte.length / 4) * 4, "=")))?.aal;
    return typeof aal === "string" ? aal : null;
  } catch {
    return null;
  }
}

/** Link assinado do Storage para o arquivo (validade em segundos). */
async function linkAssinado(admin: Record<string, string>, arquivo: string, segundos: number): Promise<string> {
  const base = Deno.env.get("SUPABASE_URL");
  const resp = await fetch(`${base}/storage/v1/object/sign/${BUCKET}/${arquivo}`, {
    method: "POST", headers: { ...admin, "Content-Type": "application/json" },
    body: JSON.stringify({ expiresIn: segundos }), signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!resp.ok) throw new Error(`assinar ${resp.status}`);
  const r = await resp.json() as { signedURL?: string };
  if (!r.signedURL) throw new Error("assinar sem link");
  return `${base}/storage/v1${r.signedURL}`;
}

async function sha256(dados: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", dados));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

type Dados = { conta: string; origem: string; nome: string; tabelas: { tabela: string; colunas: string[] }[] };

/** Pacotes vencidos (de qualquer conta): o banco tira da lista e o arquivo sai do bucket. */
async function limpar(token: string) {
  const admin = cabecalhosAdmin();
  try {
    // pacotes vencidos de qualquer conta: o arquivo sai do bucket
    const vencidos = await sql<{ a: string }[]>`select fn_exportacoes_vencidas(${token}) as a`;
    if (admin && vencidos.length) {
      await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}`, {
        method: "DELETE", headers: { ...admin, "Content-Type": "application/json" },
        body: JSON.stringify({ prefixes: vencidos.map((v) => v.a) }), signal: AbortSignal.timeout(TIMEOUT_MS),
      }).catch(() => console.error("exportar-conta: vencidos não apagados"));
    }
  } catch (err) {
    console.error("exportar-conta: vencidos", err instanceof Error ? err.message.slice(0, 120) : "erro");
  }
}

async function gerar(token: string, id: string) {
  const admin = cabecalhosAdmin();
  await limpar(token);
  const [linha] = await sql<{ d: Dados | null }[]>`select fn_exportacao_dados(${token}, ${id}::uuid) as d`;
  const d = linha?.d;
  if (!d) return;
  try {
    if (!admin) throw new Error("falta a chave de serviço");
    const enc = new TextEncoder();
    const arquivos: Record<string, Uint8Array> = {};
    // todas as tabelas do mesmo instante do banco (uma transação só leitura): página a página não perde nem repete linha
    await sql.begin("isolation level repeatable read read only", async (tx) => {
      for (const t of d.tabelas) {
        const partes: string[] = ["\ufeff" + t.colunas.join(",")];
        // página a página pela chave primária, até a página vazia
        for (let offset = 0; ; offset += PAGINA) {
          const [p] = await tx<{ c: string | null }[]>`select fn_exportar_csv(${token}, ${id}::uuid, ${t.tabela}, ${offset}, ${PAGINA}) as c`;
          if (!p?.c) break;
          partes.push(p.c);
        }
        arquivos[`dados/${t.tabela}.csv`] = enc.encode(partes.join("\r\n") + "\r\n");
      }
    });
    const gerado = new Date().toISOString();
    arquivos["esquema.json"] = enc.encode(JSON.stringify({ conta: d.nome, conta_id: d.conta, gerado_em: gerado, tabelas: d.tabelas }, null, 2));
    arquivos["LEIA-ME.txt"] = enc.encode([
      `Exportação completa da conta "${d.nome}" no Trilha, gerada em ${gerado} (UTC).`,
      "",
      "dados/<tabela>.csv: uma planilha por tabela (UTF-8, separada por vírgula, primeira linha com os nomes dos campos).",
      "Datas e horas estão em UTC, no formato do PostgreSQL. Campos vazios são nulos.",
      "esquema.json: as tabelas e os campos de cada uma.",
      "manifesto.sha256: o hash SHA-256 de cada arquivo, para conferir que nada foi alterado.",
      "",
      "Não entram: senhas, chaves, códigos de acesso e identificadores internos de envio. Espelhos em PDF, documentos,",
      "anexos de atestados e o AFD vêm numa exportação de arquivos à parte.",
    ].join("\r\n"));
    const nomes = Object.keys(arquivos).sort();
    const manifesto = (await Promise.all(nomes.map(async (n) => `${await sha256(arquivos[n])}  ${n}`))).join("\n") + "\n";
    arquivos["manifesto.sha256"] = enc.encode(manifesto);
    const shaManifesto = await sha256(arquivos["manifesto.sha256"]);
    const zip = zipSync(arquivos, { level: 6 });

    const caminho = `${d.conta}/${id}.zip`;
    const up = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}/${caminho}`, {
      method: "POST", headers: { ...admin, "Content-Type": "application/zip", "x-upsert": "true" },
      body: zip, signal: AbortSignal.timeout(120_000),
    });
    if (!up.ok) throw new Error(`storage ${up.status}`);
    const link = d.origem === "encerramento" ? await linkAssinado(admin, caminho, 7 * 24 * 3600) : null;
    await sql`select fn_exportacao_resultado(${token}, ${id}::uuid, true, ${caminho}, ${zip.length}, ${shaManifesto}, null, ${link})`;
  } catch (err) {
    const msg = (err instanceof Error ? err.message : "falha").slice(0, 200);
    console.error("exportar-conta:", msg);
    await sql`select fn_exportacao_resultado(${token}, ${id}::uuid, false, null, null, null, ${msg})`.catch(() => {});
  }
}

Deno.serve(async (req: Request) => {
  const CORS = cabecalhosCors(req);
  const json = (corpo: unknown, status = 200) =>
    new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > 1024) return json({ ok: false, erro: "pedido grande demais" }, 413);
  const texto = await req.text();
  if (texto.length > 1024) return json({ ok: false, erro: "pedido grande demais" }, 413);
  let corpo: { id?: unknown; acao?: unknown };
  try { corpo = JSON.parse(texto); } catch { return json({ ok: false, erro: "pedido inválido" }, 400); }
  const id = typeof corpo.id === "string" && UUID.test(corpo.id) ? corpo.id : "";

  // 1. chamada do banco: gerar um pedido ou só apagar os vencidos (manutenção do motor)
  const token = req.headers.get("x-exportacao-token") ?? "";
  if (token) {
    if (!/^[0-9a-f]{64}$/.test(token)) return json({ ok: false, erro: "nao autorizado" }, 401);
    const [ok] = await sql<{ v: boolean }[]>`select fn_exportacao_token_ok(${token}) as v`;
    if (!ok?.v) return json({ ok: false, erro: "nao autorizado" }, 401);
    if (!id && corpo.acao !== "limpar") return json({ ok: false, erro: "pedido inválido" }, 400);
    const tarefa = (id ? gerar(token, id) : limpar(token)).catch((e) => console.error("exportar-conta:", e instanceof Error ? e.message.slice(0, 120) : "erro"));
    const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
    if (runtime) runtime.waitUntil(tarefa);
    else await tarefa;
    return json({ ok: true }, 202);
  }

  // 2. painel: link para baixar
  if (corpo.acao !== "link" || !id) return json({ ok: false, erro: "Ação desconhecida." }, 400);
  const email = await emailVerificado(req);
  if (!email) return json({ ok: false, erro: "Sessão expirada. Entre novamente." }, 401);
  const admin = cabecalhosAdmin();
  if (!admin) return json({ ok: false, erro: "Exportação indisponível: falta a chave de serviço na função." }, 500);
  try {
    const [l] = await sql<{ a: string }[]>`select fn_exportacao_link(${email}, ${nivelDaSessao(req)}, ${id}::uuid) as a`;
    return json({ ok: true, url: await linkAssinado(admin, l.a, 600) });
  } catch (err) {
    const e = err as { code?: string; message?: string };
    if (e?.code === "P0001" && e.message) return json({ ok: false, erro: e.message }, 403);
    console.error("exportar-conta: link", e?.code ?? (err instanceof Error ? err.message.slice(0, 120) : "erro"));
    return json({ ok: false, erro: "Não foi possível gerar o link agora." }, 500);
  }
});
