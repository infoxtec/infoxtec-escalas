// OCR de documentos (item 10) — lê a validade de NR, CNH e ASO a partir da imagem.
// Protegida pelo login do Supabase: o token é conferido aqui dentro, no servidor de autenticação,
// além do verify_jwt da plataforma, e o papel do usuário no painel precisa ser admin ou gestor.
// O arquivo chega em base64 do navegador: não passa por chave de serviço nem fica em disco.
// Deploy: supabase functions deploy documento-ocr
// Requer o segredo GOOGLE_VISION_KEY no Vault; sem ele, a função avisa que o OCR não está ligado.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2, idle_timeout: 20 });

// base64 de um arquivo de até 8 MB (documento_tamanho_max_mb) ocupa cerca de 11 MB
const CORPO_MAX_BYTES = 12 * 1024 * 1024;
const TIMEOUT_MS = 15_000;

// o painel chama do navegador, em outro domínio: sem estes cabeçalhos o navegador bloqueia
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });

/** E-mail do usuário, conferido no servidor de autenticação (assinatura e expiração do token). */
async function emailVerificado(req: Request): Promise<string | null> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return null;
  const apikey = Deno.env.get("SUPABASE_ANON_KEY") ?? req.headers.get("apikey") ?? "";
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

/** Datas em dd/mm/aaaa, dd-mm-aaaa ou aaaa-mm-dd. Mesma regra de web/src/lib/ocr.ts. */
function datasEncontradas(texto: string): string[] {
  const achadas = new Set<string>();
  const limpo = texto.replace(/\s+/g, " ");
  const brasileiro = /(\d{2})\s*[\/.-]\s*(\d{2})\s*[\/.-]\s*(\d{4})/g;
  const iso = /(\d{4})-(\d{2})-(\d{2})/g;
  let m: RegExpExecArray | null;
  while ((m = brasileiro.exec(limpo)) !== null) {
    const [, d, mes, a] = m;
    if (+mes >= 1 && +mes <= 12 && +d >= 1 && +d <= 31 && +a >= 2000 && +a <= 2100) {
      achadas.add(`${a}-${mes}-${d}`);
    }
  }
  while ((m = iso.exec(limpo)) !== null) achadas.add(`${m[1]}-${m[2]}-${m[3]}`);
  return [...achadas].sort();
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);

  if (Number(req.headers.get("content-length") ?? 0) > CORPO_MAX_BYTES) {
    return json({ ok: false, erro: "arquivo grande demais para leitura na nuvem" }, 413);
  }

  const email = await emailVerificado(req);
  if (!email) return json({ ok: false, erro: "sessao invalida" }, 401);

  const [acesso] = await sql<{ papel: string | null }[]>`select fn_papel(${email}) as papel`;
  if (!acesso?.papel || !["admin", "gestor"].includes(acesso.papel)) {
    return json({ ok: false, erro: "sem permissao" }, 403);
  }

  let corpo: { base64?: string; mime?: string };
  try {
    const bruto = await req.text();
    if (bruto.length > CORPO_MAX_BYTES) {
      return json({ ok: false, erro: "arquivo grande demais para leitura na nuvem" }, 413);
    }
    corpo = JSON.parse(bruto);
  } catch {
    return json({ ok: false, erro: "json invalido" }, 400);
  }
  if (!corpo.base64) return json({ ok: false, erro: "arquivo ausente" }, 400);
  if (corpo.mime === "application/pdf") {
    return json({ ok: false, configurado: true, erro: "PDF ainda nao e lido automaticamente. Informe a validade manualmente ou envie uma foto da pagina." });
  }

  const [chave] = await sql<{ k: string | null }[]>`select fn_segredo('GOOGLE_VISION_KEY') as k`;
  if (!chave?.k) {
    return json({ ok: false, configurado: false, erro: "OCR nao configurado. Cadastre GOOGLE_VISION_KEY no Vault." });
  }

  try {
    // a chave vai no cabeçalho, nunca na URL: mensagens de erro de rede costumam repetir a URL
    const resp = await fetch("https://vision.googleapis.com/v1/images:annotate", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Goog-Api-Key": chave.k },
      body: JSON.stringify({
        requests: [{
          image: { content: corpo.base64 },
          features: [{ type: "DOCUMENT_TEXT_DETECTION" }],
          imageContext: { languageHints: ["pt"] },
        }],
      }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const dados = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      console.error("documento-ocr: Google Vision HTTP", resp.status, dados?.error?.status ?? "");
      return json({ ok: false, configurado: true, erro: "O serviço de leitura recusou o arquivo. Informe a validade manualmente." });
    }

    const texto: string = dados?.responses?.[0]?.fullTextAnnotation?.text ?? "";
    const datas = datasEncontradas(texto);
    const hoje = new Date().toLocaleDateString("en-CA", { timeZone: "America/Bahia" });
    // a validade costuma ser a data futura mais próxima; sem futuras, a maior encontrada
    const futuras = datas.filter(d => d >= hoje);
    const sugestao = futuras[0] ?? datas[datas.length - 1] ?? null;

    return json({ ok: true, configurado: true, sugestao, datas, trecho: texto.slice(0, 400) });
  } catch (err) {
    // detalhe só no log da função; ao navegador, mensagem genérica
    console.error("documento-ocr:", err instanceof Error ? err.name : "erro");
    return json({ ok: false, configurado: true, erro: "Leitura na nuvem indisponível agora. Informe a validade manualmente." });
  }
});
