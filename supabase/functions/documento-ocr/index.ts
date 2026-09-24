// OCR de documentos (item 10) — lê a validade de NR, CNH e ASO a partir da imagem.
// Protegida pelo login do Supabase (verify_jwt) e pelo papel do usuário no painel.
// O arquivo chega em base64 do navegador: não passa por chave de serviço nem fica em disco.
// Deploy: supabase functions deploy documento-ocr
// Requer o segredo GOOGLE_VISION_KEY no Vault; sem ele, a função avisa que o OCR não está ligado.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2, idle_timeout: 20 });

const json = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { "Content-Type": "application/json" } });

/** E-mail do usuário logado, lido do JWT já validado pelo runtime. */
function emailDoToken(req: Request): string | null {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  const parte = token.split(".")[1];
  if (!parte) return null;
  try {
    const dados = JSON.parse(atob(parte.replace(/-/g, "+").replace(/_/g, "/")));
    return typeof dados.email === "string" ? dados.email.toLowerCase() : null;
  } catch {
    return null;
  }
}

/** Datas em dd/mm/aaaa, dd-mm-aaaa ou aaaa-mm-dd. Devolve em ISO, sem repetir. */
function datasEncontradas(texto: string): string[] {
  const achadas = new Set<string>();
  const brasileiro = /(\d{2})[\/.-](\d{2})[\/.-](\d{4})/g;
  const iso = /(\d{4})-(\d{2})-(\d{2})/g;
  let m: RegExpExecArray | null;
  while ((m = brasileiro.exec(texto)) !== null) {
    const [, d, mes, a] = m;
    if (+mes >= 1 && +mes <= 12 && +d >= 1 && +d <= 31) achadas.add(`${a}-${mes}-${d}`);
  }
  while ((m = iso.exec(texto)) !== null) achadas.add(`${m[1]}-${m[2]}-${m[3]}`);
  return [...achadas].sort();
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);

  const email = emailDoToken(req);
  if (!email) return json({ ok: false, erro: "sessao invalida" }, 401);

  const [acesso] = await sql<{ papel: string | null }[]>`select fn_papel(${email}) as papel`;
  if (!acesso?.papel || !["admin", "gestor"].includes(acesso.papel)) {
    return json({ ok: false, erro: "sem permissao" }, 403);
  }

  let corpo: { base64?: string; mime?: string };
  try {
    corpo = await req.json();
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
    const resp = await fetch(`https://vision.googleapis.com/v1/images:annotate?key=${chave.k}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        requests: [{
          image: { content: corpo.base64 },
          features: [{ type: "DOCUMENT_TEXT_DETECTION" }],
          imageContext: { languageHints: ["pt"] },
        }],
      }),
    });
    const dados = await resp.json();
    if (!resp.ok) {
      const msg = dados?.error?.message ?? `HTTP ${resp.status}`;
      return json({ ok: false, configurado: true, erro: msg });
    }

    const texto: string = dados?.responses?.[0]?.fullTextAnnotation?.text ?? "";
    const datas = datasEncontradas(texto);
    const hoje = new Date().toISOString().slice(0, 10);
    // a validade costuma ser a data futura mais próxima; sem futuras, a maior encontrada
    const futuras = datas.filter(d => d >= hoje);
    const sugestao = futuras[0] ?? datas[datas.length - 1] ?? null;

    return json({ ok: true, configurado: true, sugestao, datas, trecho: texto.slice(0, 400) });
  } catch (err) {
    return json({ ok: false, configurado: true, erro: err instanceof Error ? err.message : String(err) });
  }
});
