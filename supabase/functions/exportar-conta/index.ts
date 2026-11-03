// Exportação completa da conta (migration 143, decisão 129; portabilidade, LGPD art. 18, V). Duas entradas:
// 1. O banco (pg_net) chama com x-exportacao-token e {id} (ou {acao: 'limpar'}, a manutenção do motor, que só apaga os
//    pacotes vencidos): a função responde logo e, em segundo plano, lê cada tabela da
//    conta em CSV (fn_exportar_csv, só as linhas da conta do pedido), junta os arquivos (espelhos emitidos, documentos dos
//    técnicos, AFD de cada empregadora; migration 144), monta o ZIP (dados/, espelhos/, documentos/, afd/, esquema.json,
//    LEIA-ME.txt, manifesto.sha256), guarda no bucket privado exportacoes e grava o resultado. Pedido com saúde gera um
//    segundo ZIP (justificativas de saúde sem máscara e anexos decifrados). Na exportação final do encerramento, manda
//    junto os links assinados de 7 dias, que o banco envia por e-mail aos administradores da conta.
// 2. O painel chama com a sessão e {acao: 'link', id}: o banco confere quem pode (fn_exportacao_link) e a função devolve
//    um link assinado de 10 minutos.
// 3. Saúde protegida (migration 147): o painel chama com a sessão, o cabeçalho x-conta e {acao: 'saude'} logo depois de
//    o administrador digitar o código do autenticador. A função lê no token a hora da verificação TOTP (amr), o banco
//    confere termo aceito, ve_saude, os 5 minutos e o limite, e registra o download; a função monta o ZIP na hora, com
//    marca d'água em cada atestado e ASO (quem, quando, código do download), e devolve um link de 60 s. O arquivo é
//    apagado em 15 minutos pela manutenção.
// Quem pode, o que entra e os limites ficam no banco. A chave de serviço só existe aqui.
// Deploy: supabase functions deploy exportar-conta --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import { zipSync } from "npm:fflate@0.8.2";
import { PDFDocument, StandardFonts, degrees, rgb } from "npm:pdf-lib@1.17.1";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  prepare: false, max: 2, idle_timeout: 20,
  connection: { statement_timeout: 60000, search_path: "interno, public, extensions" },
});

const TIMEOUT_MS = 15_000;
const PAGINA = 5000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BUCKET = "exportacoes";
const LIMITE_BYTES = 300 * 1024 * 1024;   // tudo em memória: acima disso, falha com aviso (medir antes de subir)

// mesmos domínios do painel das outras funções (produção na Vercel; homologação local, Vercel e Cloudflare)
// produção (A1 da sprint 04–17/11, origem dupla até a virada): o painel oficial na Vercel e o Worker do Cloudflare, por
// nome exato; pré-visualização não vale na produção (domínio que terceiros podem criar; versões do Worker também não)
const ORIGEM_PAINEL = /^https:\/\/(infoxtec-escalas\.vercel\.app|trilha\.david-cerqueira\.workers\.dev)$/;
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

/** Hora da última verificação TOTP vista no token (amr), já conferido no servidor de autenticação. */
function horaDoTotp(req: Request): string | null {
  try {
    const parte = (req.headers.get("Authorization") ?? "").split(/\s+/)[1]?.split(".")[1] ?? "";
    const amr = JSON.parse(atob(parte.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(parte.length / 4) * 4, "=")))?.amr;
    const ts = Array.isArray(amr) ? Math.max(...amr.filter((a: { method?: string }) => a?.method === "totp").map((a: { timestamp?: number }) => Number(a.timestamp) || 0)) : 0;
    return ts > 0 ? new Date(ts * 1000).toISOString() : null;
  } catch {
    return null;
  }
}

// a fonte padrão do PDF só tem Latin-1: o que ficar fora vira "?"
const latino = (t: string) => t.normalize("NFC").replace(/[^\x20-\xff]/g, "?");

/** Marca d'água em todas as páginas; imagem vira PDF de uma página. null se o arquivo não puder ser marcado. */
async function comMarca(bytes: Uint8Array, mime: string, marca: string): Promise<Uint8Array | null> {
  try {
    let doc: PDFDocument;
    if (mime === "application/pdf") {
      doc = await PDFDocument.load(bytes, { ignoreEncryption: true });
    } else {
      doc = await PDFDocument.create();
      const img = mime === "image/png" ? await doc.embedPng(bytes) : await doc.embedJpg(bytes);
      const pagina = doc.addPage([img.width, img.height]);
      pagina.drawImage(img, { x: 0, y: 0, width: img.width, height: img.height });
    }
    const fonte = await doc.embedFont(StandardFonts.HelveticaBold);
    const texto = latino(marca);
    for (const pagina of doc.getPages()) {
      const { width, height } = pagina.getSize();
      const grande = Math.max(10, Math.min(width, height) / 28);
      pagina.drawText(texto, { x: width * 0.12, y: height * 0.12, size: grande, font: fonte, color: rgb(0.8, 0.1, 0.1),
        opacity: 0.25, rotate: degrees(Math.atan2(height, width) * 180 / Math.PI), maxWidth: Math.hypot(width, height) * 0.7 });
      pagina.drawText(texto, { x: 12, y: 8, size: Math.max(6, grande / 3), font: fonte, color: rgb(0.6, 0.1, 0.1), opacity: 0.8 });
    }
    return await doc.save();
  } catch {
    return null;
  }
}

type Saude = { id: string; conta: string; nome: string; quem: string; csv: string; anexos: { id: string; tipo: string; nome: string }[];
  documentos: { caminho: string; mime: string | null; nome: string }[] };

/** Download protegido de saúde: autorizado e registrado no banco, montado na hora com marca d'água. */
async function gerarSaude(req: Request, email: string, admin: Record<string, string>): Promise<string> {
  const conta = req.headers.get("x-conta") ?? "";
  if (!UUID.test(conta)) throw Object.assign(new Error("Escolha a conta."), { code: "P0001" });
  const ip = req.headers.get("cf-connecting-ip") ?? req.headers.get("x-forwarded-for")?.split(",").pop()?.trim() ?? null;
  const [a] = await sql<{ r: Saude }[]>`select fn_saude_download_autorizar(${email}, ${nivelDaSessao(req)}, ${horaDoTotp(req)}::timestamptz, ${conta}::uuid, ${ip}) as r`;
  const g = a.r;
  const quando = new Date().toLocaleString("pt-BR", { timeZone: "America/Bahia" });
  const marca = `CONFIDENCIAL - dado de saude (LGPD, art. 11) - ${g.quem} <${email}> - ${quando} - codigo ${g.id.slice(0, 8)}`;
  const arquivos: Record<string, Uint8Array> = {};
  const enc = new TextEncoder();
  const naoMarcados: string[] = [];
  try {
    arquivos["saude/justificativas_saude.csv"] = enc.encode(g.csv);
    let total = 0;
    const guardar = (nome: string, b: Uint8Array | null) => {
      if (!b) return naoMarcados.push(nome);
      total += b.length;
      if (total > LIMITE_BYTES) throw new Error("pacote de saúde grande demais (mais de 300 MB): fale com o suporte");
      arquivos[nome] = b;
    };
    for (const x of g.anexos) {
      const [b] = await sql<{ b: string | null }[]>`select fn_saude_anexo(${g.id}::uuid, ${x.id}::uuid) as b`;
      if (b?.b) guardar(x.nome, await comMarca(deBase64(b.b), x.tipo, marca));
    }
    for (const d of g.documentos) {
      const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/documentos/${d.caminho.split("/").map(encodeURIComponent).join("/")}`,
        { headers: admin, signal: AbortSignal.timeout(60_000) }).catch(() => null);
      if (!resp?.ok) { naoMarcados.push(d.nome); continue; }
      const mime = (d.mime ?? resp.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
      guardar(d.nome.replace(/\.(png|jpe?g)$/i, ".pdf"), await comMarca(new Uint8Array(await resp.arrayBuffer()), mime, marca));
    }
    arquivos["LEIA-ME.txt"] = enc.encode([
      `Dados de saúde da conta "${g.nome}" no Trilha.`,
      `Baixado por ${g.quem} <${email}> em ${quando} (horário da Bahia), código do download ${g.id}.`,
      "Dado pessoal sensível (LGPD, art. 11), sob o termo de sigilo aceito no painel. Cada arquivo leva a marca d'água de quem baixou.",
      "saude/justificativas_saude.csv: as justificativas de saúde completas. saude/anexos/: os atestados. saude/documentos/: os ASO.",
      ...(naoMarcados.length ? ["", "Arquivos que não puderam receber a marca d'água e por isso não foram incluídos (peça ao suporte):", ...naoMarcados] : []),
    ].join("\r\n"));
    const caminho = `${g.conta}/saude/${g.id}.zip`;
    const pacote = await empacotar(admin, arquivos, caminho);
    await sql`select fn_saude_resultado(${g.id}::uuid, true, ${caminho}, ${pacote.tamanho}, ${pacote.sha}, ${Object.keys(arquivos).length}, null)`;
    return await linkAssinado(admin, caminho, 60);
  } catch (err) {
    const msg = (err instanceof Error ? err.message : "falha").slice(0, 200);
    await sql`select fn_saude_resultado(${g.id}::uuid, false, null, null, null, null, ${msg})`.catch(() => {});
    throw err;
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
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", dados as Uint8Array<ArrayBuffer>));
  return Array.from(h, (b) => b.toString(16).padStart(2, "0")).join("");
}

type Dados = { conta: string; origem: string; com_saude: boolean; nome: string; tabelas: { tabela: string; colunas: string[] }[] };
type Arquivos = { espelhos: { id: string; nome: string }[]; documentos: { caminho: string; nome: string }[]; afd: string[];
  anexos: { id: string; nome: string }[]; documentos_saude?: { caminho: string; nome: string }[] };

const deBase64 = (b: string) => Uint8Array.from(atob(b), (c) => c.charCodeAt(0));

/** AFD em ISO 8859-1, como o painel baixa (Portaria 671, Anexo V). */
function latin1(texto: string): Uint8Array {
  const b = new Uint8Array(texto.length);
  for (let i = 0; i < texto.length; i++) {
    const c = texto.charCodeAt(i);
    if (c > 255) throw new Error("AFD com caractere fora da ISO 8859-1");
    b[i] = c;
  }
  return b;
}

/** Manifesto SHA-256 dos arquivos, ZIP e envio ao bucket; devolve o tamanho e o hash do manifesto. */
async function empacotar(admin: Record<string, string>, arquivos: Record<string, Uint8Array>, caminho: string) {
  const nomes = Object.keys(arquivos).sort();
  const manifesto = (await Promise.all(nomes.map(async (n) => `${await sha256(arquivos[n])}  ${n}`))).join("\n") + "\n";
  arquivos["manifesto.sha256"] = new TextEncoder().encode(manifesto);
  const sha = await sha256(arquivos["manifesto.sha256"]);
  const zip = zipSync(arquivos, { level: 6 });
  const up = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}/${caminho}`, {
    method: "POST", headers: { ...admin, "Content-Type": "application/zip", "x-upsert": "true" },
    body: zip as Uint8Array<ArrayBuffer>, signal: AbortSignal.timeout(120_000),
  });
  if (!up.ok) throw new Error(`storage ${up.status}`);
  return { tamanho: zip.length, sha };
}

/** Pacotes vencidos (de qualquer conta): o banco tira da lista e o arquivo sai do bucket. */
async function limpar(token: string) {
  const admin = cabecalhosAdmin();
  try {
    // só depois de o Storage confirmar a remoção o pacote sai da lista; senão, o motor manda apagar de novo
    const vencidos = await sql<{ id: string; arquivo: string }[]>`select id, arquivo from fn_exportacoes_vencidas(${token})`;
    if (!admin || !vencidos.length) throw new Error("nada a apagar");
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}`, {
      method: "DELETE", headers: { ...admin, "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes: vencidos.map((v) => v.arquivo) }), signal: AbortSignal.timeout(TIMEOUT_MS),
    }).catch(() => null);
    if (!resp?.ok) throw new Error(`remoção ${resp?.status ?? "sem resposta"}`);
    await sql`select fn_exportacoes_apagadas(${token}, ${[...new Set(vencidos.map((v) => v.id))]}::uuid[])`;
  } catch (err) {
    if (!(err instanceof Error && err.message === "nada a apagar")) console.error("exportar-conta: vencidos", err instanceof Error ? err.message.slice(0, 120) : "erro");
  }
  // downloads de saúde com mais de 15 minutos
  try {
    const saude = await sql<{ id: string; arquivo: string }[]>`select id, arquivo from fn_saude_vencidos(${token})`;
    if (!admin || !saude.length) return;
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}`, {
      method: "DELETE", headers: { ...admin, "Content-Type": "application/json" },
      body: JSON.stringify({ prefixes: saude.map((v) => v.arquivo) }), signal: AbortSignal.timeout(TIMEOUT_MS),
    }).catch(() => null);
    if (!resp?.ok) throw new Error(`remoção ${resp?.status ?? "sem resposta"}`);
    await sql`select fn_saude_apagados(${token}, ${saude.map((v) => v.id)}::uuid[])`;
  } catch (err) {
    console.error("exportar-conta: saúde vencida", err instanceof Error ? err.message.slice(0, 120) : "erro");
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
    // arquivos: espelhos emitidos, documentos dos técnicos e o AFD de cada empregadora
    const [la] = await sql<{ a: Arquivos }[]>`select fn_exportar_arquivos(${token}, ${id}::uuid) as a`;
    const lista = la.a;
    let total = Object.values(arquivos).reduce((n, b) => n + b.length, 0);
    const somar = (b: Uint8Array) => {
      total += b.length;
      if (total > LIMITE_BYTES) throw new Error("exportação grande demais (mais de 300 MB): fale com o suporte");
      return b;
    };
    const faltando: string[] = [];
    for (const e of lista.espelhos) {
      const [p] = await sql<{ b: string | null }[]>`select fn_exportar_espelho(${token}, ${id}::uuid, ${e.id}::uuid) as b`;
      if (p?.b) arquivos[e.nome] = somar(deBase64(p.b));
    }
    // documento do bucket; o tamanho declarado é conferido antes de ler o arquivo inteiro
    const baixarDocumento = async (caminho: string): Promise<Uint8Array | null> => {
      const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/documentos/${caminho.split("/").map(encodeURIComponent).join("/")}`,
        { headers: admin, signal: AbortSignal.timeout(60_000) }).catch(() => null);
      if (!resp?.ok) return null;
      if (total + Number(resp.headers.get("content-length") ?? 0) > LIMITE_BYTES) {
        await resp.body?.cancel();
        throw new Error("exportação grande demais (mais de 300 MB): fale com o suporte");
      }
      return somar(new Uint8Array(await resp.arrayBuffer()));
    };
    for (const doc of lista.documentos) {
      const b = await baixarDocumento(doc.caminho);
      if (b) arquivos[doc.nome] = b;
      else faltando.push(doc.nome);
    }
    for (const emp of lista.afd) {
      const [f] = await sql<{ f: { nome: string; conteudo: string } }[]>`select fn_exportar_afd(${token}, ${id}::uuid, ${emp}::uuid) as f`;
      arquivos[f.f.nome] = somar(latin1(f.f.conteudo));
    }
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
      "espelhos/: os espelhos de ponto emitidos, em PDF (só para quem tem acesso às folhas assinadas; sem esse acesso, as",
      "colunas do espelho assinado em dados/ponto_espelhos.csv vão vazias). documentos/: os documentos dos técnicos, menos os",
      "de saúde (ASO), que vão no pacote de saúde.",
      "afd/: o Arquivo Fonte de Dados de cada empregadora, do primeiro registro até hoje (ISO 8859-1).",
      "Dados de saúde (justificativas e atestados) saem aqui com o motivo como \"saude\" e os textos vazios; o completo",
      "vem num pacote à parte, só para quem tem permissão de ver saúde.",
      "Não entram: senhas, chaves, códigos de acesso e identificadores internos de envio.",
      ...(faltando.length ? ["", "Documentos que não puderam ser lidos do armazenamento:", ...faltando] : []),
    ].join("\r\n"));
    const caminho = `${d.conta}/${id}.zip`;
    const pacote = await empacotar(admin, arquivos, caminho);

    // saúde: justificativas sem máscara e anexos decifrados (cada acesso fica registrado no banco)
    let saude: { caminho: string; tamanho: number } | null = null;
    if (d.com_saude) {
      const s: Record<string, Uint8Array> = {};
      const [c] = await sql<{ c: string }[]>`select fn_exportar_saude_csv(${token}, ${id}::uuid) as c`;
      s["saude/justificativas_saude.csv"] = enc.encode(c.c);
      for (const x of lista.anexos) {
        const [a] = await sql<{ b: string | null }[]>`select fn_exportar_anexo(${token}, ${id}::uuid, ${x.id}::uuid) as b`;
        if (a?.b) s[x.nome] = somar(deBase64(a.b));
      }
      // documentos de saúde (ASO), que não vão no pacote comum (migration 145)
      for (const doc of lista.documentos_saude ?? []) {
        const b = await baixarDocumento(doc.caminho);
        if (b) s[doc.nome] = b;
      }
      s["LEIA-ME.txt"] = enc.encode([
        `Dados de saúde da conta "${d.nome}" no Trilha, gerados em ${gerado} (UTC).`,
        "Dado pessoal sensível (LGPD, art. 11): guarde em local protegido e com acesso restrito.",
        "saude/justificativas_saude.csv: as justificativas de saúde completas. saude/anexos/: os atestados enviados.",
        "saude/documentos/: os documentos de saúde dos técnicos (ASO).",
      ].join("\r\n"));
      const cs = `${d.conta}/${id}_saude.zip`;
      saude = { caminho: cs, tamanho: (await empacotar(admin, s, cs)).tamanho };
    }
    const enc7 = 7 * 24 * 3600;
    const link = d.origem === "encerramento" ? await linkAssinado(admin, caminho, enc7) : null;
    const linkSaude = d.origem === "encerramento" && saude ? await linkAssinado(admin, saude.caminho, enc7) : null;
    await sql`select fn_exportacao_resultado(${token}, ${id}::uuid, true, ${caminho}, ${pacote.tamanho}, ${pacote.sha}, null, ${link},
                                             ${saude?.caminho ?? null}, ${saude?.tamanho ?? null}, ${linkSaude})`;
  } catch (err) {
    const msg = (err instanceof Error ? err.message : "falha").slice(0, 200);
    console.error("exportar-conta:", msg);
    // o que já subiu desta tentativa sai do bucket: sem resultado gravado, ninguém apagaria depois
    if (admin) {
      await fetch(`${Deno.env.get("SUPABASE_URL")}/storage/v1/object/${BUCKET}`, {
        method: "DELETE", headers: { ...admin, "Content-Type": "application/json" },
        body: JSON.stringify({ prefixes: [`${d.conta}/${id}.zip`, `${d.conta}/${id}_saude.zip`] }), signal: AbortSignal.timeout(TIMEOUT_MS),
      }).catch(() => console.error("exportar-conta: pacote da falha não apagado"));
    }
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
  let corpo: { id?: unknown; acao?: unknown; saude?: unknown };
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

  // 2. painel: link para baixar o pacote; 3. download protegido de saúde
  if (!(corpo.acao === "link" && id) && corpo.acao !== "saude") return json({ ok: false, erro: "Ação desconhecida." }, 400);
  const email = await emailVerificado(req);
  if (!email) return json({ ok: false, erro: "Sessão expirada. Entre novamente." }, 401);
  const admin = cabecalhosAdmin();
  if (!admin) return json({ ok: false, erro: "Exportação indisponível: falta a chave de serviço na função." }, 500);
  try {
    if (corpo.acao === "saude") return json({ ok: true, url: await gerarSaude(req, email, admin) });
    const [l] = await sql<{ a: string }[]>`select fn_exportacao_link(${email}, ${nivelDaSessao(req)}, ${id}::uuid, ${corpo.saude === true}) as a`;
    return json({ ok: true, url: await linkAssinado(admin, l.a, 600) });
  } catch (err) {
    const e = err as { code?: string; message?: string };
    if (e?.code === "P0001" && e.message) return json({ ok: false, erro: e.message }, 403);
    console.error("exportar-conta: link", e?.code ?? (err instanceof Error ? err.message.slice(0, 120) : "erro"));
    return json({ ok: false, erro: "Não foi possível gerar o link agora." }, 500);
  }
});
