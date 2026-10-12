// Webhook da Evolution API -> Supabase
// Autenticacao: token no cabecalho x-webhook-token (decisao 51, parte 3), conferido dentro do banco
// contra o Vault. Cabecalho presente e errado = 401, sem tentar a URL. Transicao: sem o cabecalho,
// ainda aceita o token na URL (?token=...) e registra um aviso no log, sem o valor. A aceitacao pela
// URL sai depois de 3 a 7 dias sem esse aviso.
// Toda a regra de negocio mora em SQL (fn_webhook_evolution). Esta funcao so repassa, com uma excecao:
// quando o banco pede (acao ponto_baixar_midia, so na etapa do documento do pedido de ajuste), baixa o
// arquivo da Evolution e entrega a fn_ponto_midia_receber, que confere e cifra no cofre (migration 70).
// O arquivo nao passa pelo log nem fica guardado aqui.
// Deploy: supabase functions deploy webhook-evolution --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false,
  max: 1,
  idle_timeout: 20,
});

// mensagens de texto e botões têm poucos KB; mídia em base64 pode chegar a alguns MB
const CORPO_MAX_BYTES = 5 * 1024 * 1024;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: true, info: "webhook evolution" });

  const doCabecalho = req.headers.get("x-webhook-token");
  let token: string;
  if (doCabecalho !== null) {
    token = doCabecalho;
  } else {
    token = new URL(req.url).searchParams.get("token") ?? "";
    if (token) console.warn("webhook: token pela URL (legado)");
  }
  if (!token) return json({ ok: false, erro: "token ausente" }, 401);

  // lido em fluxo com teto: sem content-length (envio em partes) também não passa de CORPO_MAX_BYTES
  let payload: Record<string, unknown>;
  try {
    payload = JSON.parse(await lerComTeto(req, CORPO_MAX_BYTES));
  } catch (e) {
    if (e instanceof Error && e.message === "grande demais") {
      return json({ ok: false, erro: "payload grande demais" }, 413);
    }
    return json({ ok: false, erro: "json invalido" }, 400);
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    return json({ ok: false, erro: "payload deve ser um objeto" }, 400);
  }

  try {
    // sql.json envia o objeto como jsonb uma unica vez (sem dupla serializacao)
    const rows = await sql`
      select fn_webhook_evolution(${token}, ${sql.json(payload as Parameters<typeof sql.json>[0])}) as resultado
    `;
    const resultado = rows[0]?.resultado ?? null;
    if (resultado?.acao === "ponto_baixar_midia") {
      // responde já à Evolution; o download segue em segundo plano (sem o runtime, espera aqui)
      const tarefa = receberMidia(resultado.tecnico, resultado.midia_id, payload.data);
      const runtime = (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime;
      if (runtime) runtime.waitUntil(tarefa);
      else await tarefa;
    }
    return json({ ok: true, resultado });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("token invalido")) return json({ ok: false, erro: "nao autorizado" }, 401);
    console.error("webhook evolution:", msg);
    // 200 para a Evolution nao reenviar em loop; o erro fica no log da funcao
    return json({ ok: false, erro: "falha interna" });
  }
});

// 5 MB em base64 (~6,7 MB) mais o envelope JSON: acima disso, o download é abortado
const MIDIA_MAX_BYTES = 7_500_000;

// Lê o corpo em fluxo e aborta acima do teto (o tamanho declarado não é confiável nem obrigatório).
// Serve à requisição recebida e à resposta da Evolution; acima do teto, erro "grande demais".
async function lerComTeto(msg: Request | Response, teto: number): Promise<string> {
  if (Number(msg.headers.get("content-length") ?? 0) > teto) throw new Error("grande demais");
  if (!msg.body) throw new Error("sem corpo");
  const leitor = msg.body.getReader();
  const partes: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await leitor.read();
    if (done) break;
    total += value.length;
    if (total > teto) {
      await leitor.cancel();
      throw new Error("grande demais");
    }
    partes.push(value);
  }
  const tudo = new Uint8Array(total);
  let pos = 0;
  for (const p of partes) {
    tudo.set(p, pos);
    pos += p.length;
  }
  return new TextDecoder().decode(tudo);
}

// Baixa o arquivo da mensagem pela Evolution (getBase64FromMediaMessage) e entrega ao banco
async function receberMidia(tecnico: string, midiaId: string, data: unknown) {
  try {
    const d = data as { key?: unknown; message?: unknown };
    const [cfg] = await sql`
      select fn_config('evolution_url') as url, fn_config('evolution_instancia') as inst,
             fn_segredo('EVOLUTION_API_KEY') as chave
    `;
    if (!cfg?.url || !cfg?.inst || !cfg?.chave) throw new Error("evolution sem configuracao");
    const resp = await fetch(`${cfg.url}/chat/getBase64FromMediaMessage/${encodeURIComponent(cfg.inst)}`, {
      method: "POST",
      headers: { apikey: cfg.chave, "Content-Type": "application/json" },
      body: JSON.stringify({ message: { key: d.key, message: d.message }, convertToMp4: false }),
      signal: AbortSignal.timeout(20_000),
      redirect: "error", // a chave não segue redirecionamento
    });
    if (!resp.ok) throw new Error(`evolution ${resp.status}`);
    const corpo = JSON.parse(await lerComTeto(resp, MIDIA_MAX_BYTES)) as { base64?: string; mimetype?: string };
    if (!corpo.base64) throw new Error("evolution sem base64");
    if (corpo.base64.length > 7_200_000) throw new Error("midia grande demais");
    const mime = (corpo.mimetype ?? "").split(";")[0].trim().toLowerCase();
    const base64 = semMetadados(corpo.base64.replace(/^data:[^,]*,/, ""), mime);
    await sql`select fn_ponto_midia_receber(${tecnico}::uuid, ${midiaId}, ${base64}, ${mime})`;
  } catch (err) {
    // só a mensagem técnica vai ao log, nunca o conteúdo
    console.error("ponto midia:", err instanceof Error ? err.message : String(err));
    try {
      await sql`select fn_ponto_midia_falhou(${tecnico}::uuid, ${midiaId})`;
    } catch (e) {
      console.error("ponto midia falhou:", e instanceof Error ? e.message : String(e));
    }
  }
}

// Tira metadados da imagem (EXIF com GPS, XMP, IPTC, textos do PNG), como o app faz ao reduzir a foto.
// Arquivo que não é imagem, ou fora do padrão, volta como veio (o banco confere o tipo pelos bytes)
function semMetadados(base64: string, mime: string): string {
  const original = () => {
    console.warn("ponto midia: metadados mantidos"); // só o marcador, nunca o conteúdo
    return base64;
  };
  if (mime !== "image/jpeg" && mime !== "image/png") return base64;
  let b: Uint8Array;
  try {
    b = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
  } catch {
    return original();
  }
  const partes: Uint8Array[] = [];
  if (mime === "image/jpeg") {
    if (b[0] !== 0xff || b[1] !== 0xd8) return original();
    partes.push(b.subarray(0, 2));
    let i = 2;
    while (i + 4 <= b.length && b[i] === 0xff) {
      if (b[i + 1] === 0xff) { // bytes de preenchimento entre segmentos
        i++;
        continue;
      }
      const marca = b[i + 1];
      if (marca === 0xda) break; // início da imagem: o resto vai inteiro
      const tam = (b[i + 2] << 8) | b[i + 3];
      if (tam < 2 || i + 2 + tam > b.length) return original();
      // APP1 (EXIF, XMP) e APP13 (IPTC) saem; o resto (JFIF, ICC, tabelas) fica
      if (marca !== 0xe1 && marca !== 0xed) partes.push(b.subarray(i, i + 2 + tam));
      i += 2 + tam;
    }
    partes.push(b.subarray(i));
  } else {
    const assinatura = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (!assinatura.every((v, k) => b[k] === v)) return original();
    partes.push(b.subarray(0, 8));
    let i = 8;
    while (i + 12 <= b.length) {
      const tam = ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
      const tipo = String.fromCharCode(b[i + 4], b[i + 5], b[i + 6], b[i + 7]);
      if (i + 12 + tam > b.length) return original();
      if (!["eXIf", "tEXt", "zTXt", "iTXt"].includes(tipo)) partes.push(b.subarray(i, i + 12 + tam));
      i += 12 + tam;
      if (tipo === "IEND") break;
    }
  }
  const total = partes.reduce((s, p) => s + p.length, 0);
  const saida = new Uint8Array(total);
  let pos = 0;
  for (const p of partes) {
    saida.set(p, pos);
    pos += p.length;
  }
  let bin = "";
  for (let k = 0; k < saida.length; k += 0x8000) bin += String.fromCharCode(...saida.subarray(k, k + 0x8000));
  return btoa(bin);
}
