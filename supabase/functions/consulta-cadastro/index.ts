// Consulta de CNPJ e CEP para o preenchimento automático do cadastro (pacote de cadastro, migration 133). Só para quem
// está logado no painel: CNPJ nos dados abertos da Receita (BrasilAPI; reserva: CNPJ.ws pública) e CEP na base dos
// Correios (ViaCEP; reserva: BrasilAPI). Não grava nada: devolve os campos e o painel preenche o formulário.
// O quadro de sócios e os contatos da Receita não saem daqui.
// Deploy: supabase functions deploy consulta-cadastro
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const TIMEOUT_MS = 6_000;

// mesmos domínios do painel que a convidar-usuario aceita
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

/** Sessão conferida no servidor de autenticação (assinatura e expiração do token). */
async function logado(req: Request): Promise<boolean> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return false;
  const doCliente = req.headers.get("apikey") ?? "";
  const apikey = /^sb_publishable_[A-Za-z0-9_-]{1,100}$/.test(doCliente) ? doCliente : (Deno.env.get("SUPABASE_ANON_KEY") ?? "");
  try {
    const resp = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, { headers: { Authorization: auth, apikey }, signal: AbortSignal.timeout(TIMEOUT_MS) });
    return resp.ok;
  } catch {
    return false;
  }
}

async function buscar(url: string): Promise<Record<string, unknown> | null> {
  try {
    const resp = await fetch(url, { headers: { Accept: "application/json", "User-Agent": "Trilha/1.0" }, signal: AbortSignal.timeout(TIMEOUT_MS) });
    if (!resp.ok) return null;
    const j = await resp.json();
    return j && typeof j === "object" ? j as Record<string, unknown> : null;
  } catch {
    return null;
  }
}

const txt = (v: unknown, max = 150) => typeof v === "string" && v.trim() ? v.trim().slice(0, max) : null;
const PEQUENAS = new Set(["de", "da", "do", "das", "dos", "e"]);
/** A Receita manda em maiúsculas: "SALVADOR" vira "Salvador", "LAURO DE FREITAS" vira "Lauro de Freitas". */
const nome = (v: unknown) => {
  const t = txt(v);
  if (!t || t !== t.toUpperCase()) return t;
  return t.toLowerCase().split(/\s+/).map((p, i) => i > 0 && PEQUENAS.has(p) ? p : p.charAt(0).toUpperCase() + p.slice(1)).join(" ");
};
const so = (v: unknown, re: RegExp) => { const t = typeof v === "string" ? v.replace(/\D/g, "") : ""; return re.test(t) ? t : null; };

async function consultarCnpj(cnpj: string) {
  const b = await buscar(`https://brasilapi.com.br/api/cnpj/v1/${cnpj}`);
  if (b && txt(b.razao_social)) {
    const rua = [txt(b.descricao_tipo_de_logradouro), txt(b.logradouro)].filter(Boolean).join(" ");
    return {
      razao_social: txt(b.razao_social), nome_fantasia: nome(b.nome_fantasia), situacao: nome(b.descricao_situacao_cadastral),
      logradouro: nome(rua), numero: txt(b.numero, 20), complemento: nome(b.complemento), bairro: nome(b.bairro),
      cidade: nome(b.municipio), uf: txt(b.uf, 2)?.toUpperCase() ?? null, cep: so(b.cep, /^\d{8}$/), fonte: "Receita Federal (BrasilAPI)",
    };
  }
  const w = await buscar(`https://publica.cnpj.ws/cnpj/${cnpj}`);
  const e = (w?.estabelecimento ?? null) as Record<string, unknown> | null;
  if (w && e && txt(w.razao_social)) {
    const rua = [txt(e.tipo_logradouro), txt(e.logradouro)].filter(Boolean).join(" ");
    return {
      razao_social: txt(w.razao_social), nome_fantasia: nome(e.nome_fantasia), situacao: nome(e.situacao_cadastral),
      logradouro: nome(rua), numero: txt(e.numero, 20), complemento: nome(e.complemento), bairro: nome(e.bairro),
      cidade: nome((e.cidade as Record<string, unknown> | null)?.nome), uf: txt((e.estado as Record<string, unknown> | null)?.sigla, 2),
      cep: so(e.cep, /^\d{8}$/), fonte: "Receita Federal (CNPJ.ws)",
    };
  }
  return null;
}

async function consultarCep(cep: string) {
  const v = await buscar(`https://viacep.com.br/ws/${cep}/json/`);
  if (v && !v.erro && txt(v.localidade)) {
    return { logradouro: txt(v.logradouro), bairro: txt(v.bairro), cidade: txt(v.localidade), uf: txt(v.uf, 2), cep, fonte: "Correios (ViaCEP)" };
  }
  const b = await buscar(`https://brasilapi.com.br/api/cep/v2/${cep}`);
  if (b && txt(b.city)) {
    return { logradouro: txt(b.street), bairro: txt(b.neighborhood), cidade: txt(b.city), uf: txt(b.state, 2), cep, fonte: "Correios (BrasilAPI)" };
  }
  return null;
}

Deno.serve(async (req: Request) => {
  const CORS = cabecalhosCors(req);
  const json = (corpo: unknown, status = 200) =>
    new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  if (Number(req.headers.get("content-length") ?? 0) > 512) return json({ ok: false, erro: "pedido grande demais" }, 413);
  if (!await logado(req)) return json({ ok: false, erro: "Sessão expirada. Entre novamente." }, 401);

  let corpo: { tipo?: unknown; valor?: unknown };
  try { corpo = JSON.parse(await req.text()); } catch { return json({ ok: false, erro: "pedido inválido" }, 400); }
  const valor = typeof corpo.valor === "string" ? corpo.valor.toUpperCase().replace(/[^0-9A-Z]/g, "") : "";

  if (corpo.tipo === "cnpj" && /^[0-9A-Z]{12}\d{2}$/.test(valor)) {
    const r = await consultarCnpj(valor);
    return r ? json({ ok: true, ...r }) : json({ ok: false, erro: "CNPJ não encontrado na base da Receita (ou o serviço está fora). Preencha à mão." });
  }
  if (corpo.tipo === "cep" && /^\d{8}$/.test(valor)) {
    const r = await consultarCep(valor);
    return r ? json({ ok: true, ...r }) : json({ ok: false, erro: "CEP não encontrado (ou o serviço está fora). Preencha à mão." });
  }
  return json({ ok: false, erro: "Informe um CNPJ ou um CEP válido." }, 400);
});
