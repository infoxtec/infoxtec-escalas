// PDF do espelho de ponto assinado (migration 107, decisão 104).
// Chamada só pelo banco (pg_net), depois que o funcionário assina: lê o espelho congelado, monta o PDF com a
// assinatura desenhada, o QR de conferência e o selo de validação da empresa, e devolve o arquivo ao banco, que
// guarda (imutável, com SHA-256) e entrega ao funcionário pelo WhatsApp. Toda a regra fica em SQL: aqui só se
// desenha o documento. O token vem no cabeçalho x-espelho-token e é conferido no banco contra o Vault.
// A assinatura ICP-Brasil da empresa (PAdES, Portaria 671, art. 88) entra em assinarComCertificado quando o
// certificado existir; até lá o PDF sai com o selo do sistema.
// Deploy: supabase functions deploy espelho-pdf --no-verify-jwt
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.5";
import { PDFDocument, PDFFont, PDFPage, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import qrcode from "npm:qrcode-generator@2.0.4";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 1, idle_timeout: 20 });

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Dia = Record<string, unknown> & { data: string };
type Escala = { escala: string; de: string; ate: string; tipo?: string; entrada?: string | null; intervalo_min?: number | null;
  semanal_min?: number | null; plantao_min?: number | null; minutos?: number[] | null };
type Conteudo = {
  documento?: string;
  empregador: { razao_social: string; cnpj: string; cei_caepf_cno?: string | null; endereco?: string | null };
  trabalhador: { nome: string; cpf: string; admissao: string | null; funcao: string | null };
  competencia: string; de: string; ate: string;
  jornada: { dia_util_min: number; sabado_min: number; intervalo_min: number; escalas?: Escala[]; pre_assinalado?: boolean };
  dias: Dia[];
  ajustes: { acao: string; data: string; hora: string; tipo: string; motivo: string }[];
  resumo?: {
    a_pagar: Record<string, number>; a_descontar: Record<string, number>;
    informativo: Record<string, number | string[]>;
  };
  avisos?: string[];
};
type Dados = {
  id: string; registro: number; versao: number; codigo: string; sha256: string; emitido_em: string; assinado_em: string;
  assinatura_png: string; assinatura_sha256: string; conteudo: Conteudo; url_verificacao: string; ja_gerado: boolean;
};

// mesmos rótulos do painel (web/src/lib/types.ts)
const ROTULO: Record<string, string> = {
  entrada: "Entrada", saida_almoco: "Saída almoço", volta_almoco: "Volta almoço", saida: "Saída",
  inicio_he: "Início HE", fim_he: "Fim HE",
};
const ALERTA: Record<string, string> = {
  intervalo_curto: "Intervalo abaixo do mínimo", intervalo_longo: "Intervalo acima de 2 h", sem_intervalo: "Sem intervalo",
  he_acima_limite: "HE acima de 2 h", interjornada_curta: "Interjornada < 11 h", atraso: "Atraso",
  incompleta: "Marcação faltando", falta: "Falta", falta_abonada: "Falta abonada", atraso_abonado: "Atraso abonado",
};
const SEMANA = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];

// a fonte padrão do PDF só tem o alfabeto latino (WinAnsi): o resto vira "?"
const txt = (s: unknown) => String(s ?? "").normalize("NFC")
  .replace(/[^\x20-\x7E -ÿ–—‘’“”•…]/g, "?");
const hh = (m: unknown) => {
  const n = Number(m);
  if (m == null || Number.isNaN(n)) return "-";
  return `${String(Math.floor(n / 60)).padStart(2, "0")}:${String(n % 60).padStart(2, "0")}`;
};
const hhOu = (m: unknown) => (m ? hh(m) : "-");
// duração por extenso no cabeçalho (8h00), para não parecer horário
const hm = (m: unknown) => {
  const n = Number(m);
  if (m == null || Number.isNaN(n)) return "-";
  return `${Math.floor(n / 60)}h${String(n % 60).padStart(2, "0")}`;
};
const dataBr = (d: string | null | undefined) => (d ? d.slice(0, 10).split("-").reverse().join("/") : "-");
const cpfFmt = (c: string) => c.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, "$1.$2.$3-$4");
const cnpjFmt = (c: string) => c.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, "$1.$2.$3/$4-$5");

class Folha {
  page!: PDFPage;
  y = 0;
  readonly m = 28;
  readonly w = 595.28;
  readonly h = 841.89;
  constructor(readonly doc: PDFDocument, readonly f: PDFFont, readonly b: PDFFont, readonly rodape: string) {
    this.nova();
  }
  nova() {
    this.page = this.doc.addPage([this.w, this.h]);
    this.y = this.h - this.m;
    this.page.drawText(txt(this.rodape), { x: this.m, y: 14, size: 6.5, font: this.f, color: rgb(0.4, 0.4, 0.4) });
  }
  espaco(alt: number) {
    if (this.y - alt < this.m + 12) this.nova();
  }
  linha(s: string, size = 8, bold = false, x = this.m, cor = rgb(0, 0, 0)) {
    this.espaco(size + 3);
    this.page.drawText(txt(s), { x, y: this.y - size, size, font: bold ? this.b : this.f, color: cor });
    this.y -= size + 3;
  }
  // parágrafo com quebra por largura
  texto(s: string, size = 7.5, largura = this.w - 2 * this.m, x = this.m, bold = false, cor = rgb(0.15, 0.15, 0.15)) {
    const fonte = bold ? this.b : this.f;
    let atual = "";
    for (const p of txt(s).split(/\s+/)) {
      const tenta = atual ? `${atual} ${p}` : p;
      if (fonte.widthOfTextAtSize(tenta, size) > largura && atual) {
        this.linha(atual, size, bold, x, cor);
        atual = p;
      } else atual = tenta;
    }
    if (atual) this.linha(atual, size, bold, x, cor);
  }
  // célula de tabela truncada à largura
  celula(s: string, x: number, larg: number, size: number, bold = false) {
    const fonte = bold ? this.b : this.f;
    let t = txt(s);
    while (t.length > 1 && fonte.widthOfTextAtSize(t, size) > larg - 2) t = t.slice(0, -2) + "…";
    this.page.drawText(t, { x, y: this.y - size, size, font: fonte });
  }
  regua(cor = rgb(0.6, 0.6, 0.6)) {
    this.page.drawLine({ start: { x: this.m, y: this.y }, end: { x: this.w - this.m, y: this.y }, thickness: 0.5, color: cor });
    this.y -= 3;
  }
}

function desenharQr(page: PDFPage, texto: string, x: number, y: number, lado: number) {
  const qr = qrcode(0, "M");
  qr.addData(texto);
  qr.make();
  const n = qr.getModuleCount();
  const c = lado / (n + 2);
  page.drawRectangle({ x, y, width: lado, height: lado, color: rgb(1, 1, 1) });
  for (let r = 0; r < n; r++) {
    for (let k = 0; k < n; k++) {
      if (qr.isDark(r, k)) page.drawRectangle({ x: x + (k + 1) * c, y: y + lado - (r + 2) * c, width: c, height: c, color: rgb(0, 0, 0) });
    }
  }
}

function observacao(d: Dia): string {
  const al = (d.alertas as string[] | undefined) ?? [];
  const abono = d.abono as string | undefined;
  const motivo = d.abono_motivo as string | undefined;
  return [
    d.feriado ? `Feriado: ${d.feriado}` : null,
    d.folga_de ? `Folga compensatória do trabalho de ${d.folga_de}` : null,
    d.compensado_em ? `Compensado com folga em ${d.compensado_em}` : null,
    d.debito_min && !d.trabalhado_min && !d.entrada && !d.saida && !abono ? "Falta injustificada" : null,
    ...al.map((a) => ALERTA[a] ?? a),
    abono ? (motivo ? `Abono - ${motivo}${abono !== "dia inteiro" ? ` (${abono})` : ""}` : `Abono: ${abono}`) : null,
    d.ajustes ? "Ajustado" : null,
  ].filter(Boolean).join(" · ");
}

async function montarPdf(d: Dados): Promise<Uint8Array> {
  const c = d.conteudo;
  const doc = await PDFDocument.create();
  doc.setTitle(`Espelho de ponto ${c.competencia} - registro ${d.registro}`);
  doc.setAuthor(c.empregador.razao_social);
  doc.setCreator("Trilha Ponto");
  doc.setProducer("Trilha Ponto");
  const f = await doc.embedFont(StandardFonts.Helvetica);
  const b = await doc.embedFont(StandardFonts.HelveticaBold);
  const fl = new Folha(doc, f, b,
    `${c.empregador.razao_social} · Espelho ${c.competencia} · Registro nº ${d.registro} · código ${d.codigo} · SHA-256 ${d.sha256}`);

  // cabeçalho (Art. 84, I a IV) e QR
  const topo = fl.y;
  desenharQr(fl.page, d.url_verificacao, fl.w - fl.m - 78, topo - 78, 78);
  fl.page.drawText(txt(d.codigo), { x: fl.w - fl.m - 78, y: topo - 86, size: 5.5, font: f });
  const larg = fl.w - 2 * fl.m - 90;
  fl.linha(c.documento ?? "Espelho de Ponto Eletrônico (Portaria MTP 671/2021, art. 84)", 11, true);
  fl.linha(`Competência ${c.competencia} · período ${dataBr(c.de)} a ${dataBr(c.ate)}`, 8.5, true);
  fl.texto(`Empregador: ${c.empregador.razao_social} · CNPJ ${cnpjFmt(c.empregador.cnpj)}` +
    (c.empregador.cei_caepf_cno ? ` · CEI/CAEPF/CNO ${c.empregador.cei_caepf_cno}` : "") +
    (c.empregador.endereco ? ` · ${c.empregador.endereco}` : ""), 8, larg, fl.m, false, rgb(0, 0, 0));
  fl.texto(`Trabalhador: ${c.trabalhador.nome} · CPF ${cpfFmt(c.trabalhador.cpf)} · Admissão ${dataBr(c.trabalhador.admissao)} · ` +
    `Cargo/função: ${c.trabalhador.funcao ?? "-"}`, 8, larg, fl.m, false, rgb(0, 0, 0));
  const esc = c.jornada.escalas ?? [];
  const jornada = esc.length > 0
    ? esc.map((e) => `${e.escala} (${e.de} a ${e.ate})` +
        (e.entrada ? `, entrada ${e.entrada}` : "") +
        (e.tipo === "12x36" ? `, plantão de ${hm(e.plantao_min)}` : e.semanal_min ? `, ${hm(e.semanal_min)} semanais` : "") +
        (e.intervalo_min != null ? `, intervalo de ${hm(e.intervalo_min)}` : "")).join("; ")
    : `${hm(c.jornada.dia_util_min)} de segunda a sexta, ${hm(c.jornada.sabado_min)} no sábado, intervalo de ${hm(c.jornada.intervalo_min)}`;
  fl.texto(`Horário e jornada contratual: ${jornada}`, 8, larg, fl.m, false, rgb(0, 0, 0));
  if (c.jornada.pre_assinalado) {
    fl.texto("Intervalo pré-assinalado (CLT art. 74, §2º): quando não registrado, vale o intervalo da jornada contratual.", 7.5, larg);
  }
  fl.texto(`Registro nº ${d.registro}${d.versao > 1 ? ` (versão ${d.versao})` : ""} · emitido em ${d.emitido_em}`, 7.5, larg);
  fl.y = Math.min(fl.y, topo - 92);

  // tabela dos dias (Art. 84, V e VI)
  const cols: [string, number][] = [
    ["Dia", 52], ["Entrada", 34], ["Saída int.", 38], ["Volta", 32], ["Saída", 32], ["Trabalh.", 36], ["Duração*", 38],
    ["HE 50%", 32], ["HE 100%", 34], ["Noturno", 34], ["Débito", 32],
  ];
  const obsX = fl.m + cols.reduce((s, [, l]) => s + l, 0);
  const obsL = fl.w - fl.m - obsX;
  const cabecalho = () => {
    fl.espaco(14);
    let x = fl.m;
    for (const [t, l] of cols) { fl.celula(t, x, l, 6.8, true); x += l; }
    fl.celula("Observação", obsX, obsL, 6.8, true);
    fl.y -= 9;
    fl.regua();
  };
  fl.y -= 4;
  cabecalho();
  if (c.dias.length === 0) fl.linha("Sem marcações no mês", 7.5);
  for (const dia of c.dias) {
    if (fl.y - 10 < fl.m + 12) { fl.nova(); cabecalho(); }
    const sem = SEMANA[new Date(`${dia.data}T12:00:00`).getDay()];
    const v = [
      `${dataBr(dia.data)} ${sem}`, String(dia.entrada ?? "-"), String(dia.saida_almoco ?? "-"), String(dia.volta_almoco ?? "-"),
      String(dia.saida ?? "-"), hhOu(dia.trabalhado_min), hhOu(dia.duracao_min ?? dia.trabalhado_min), hhOu(dia.he50_min),
      hhOu(dia.he100_min), hhOu(dia.noturno_min), hhOu(dia.debito_min),
    ];
    let x = fl.m;
    v.forEach((s, i) => { fl.celula(s, x, cols[i][1], 6.8); x += cols[i][1]; });
    fl.celula(observacao(dia), obsX, obsL, 6.2);
    fl.y -= 9;
  }
  fl.regua();
  fl.texto("* Duração da jornada com a hora noturna reduzida (52'30\" entre 22 h e 5 h valem 1 hora).", 6.5);

  // resumo (decisão 83)
  if (c.resumo) {
    const p = c.resumo.a_pagar, ds = c.resumo.a_descontar, inf = c.resumo.informativo;
    fl.y -= 4;
    fl.linha("Resumo do mês", 8.5, true);
    fl.texto(`A pagar: hora extra 50% ${hh(p.he50_min)} · hora extra 100% ${hh(p.he100_min)} · adicional noturno (horas reduzidas) ` +
      `${hh(p.noturno_reduzidas_min)} · intervalo não concedido (+50%) ${hh(p.intervalo_nao_concedido_min)}`, 7.5);
    fl.texto(`A descontar: horas em débito ${hh(ds.debito_min)} · dias sem registro ${ds.dias_sem_registro} · semanas com falta (DSR) ` +
      `${ds.semanas_com_falta}`, 7.5);
    fl.texto(`Informativo: previstas ${hh(inf.previsto_min)} · trabalhadas ${hh(inf.trabalhado_min)} · abonadas com justificativa ` +
      `${hh(inf.abonado_justificado_min)} · abonadas pela empresa ${hh(inf.abonado_empresa_min)} · dias trabalhados ${inf.dias_trabalhados}`, 7.5);
  }

  // marcações tratadas (Art. 84, V)
  if (c.ajustes.length > 0) {
    fl.y -= 4;
    fl.linha("Marcações tratadas", 8.5, true);
    for (const a of c.ajustes) {
      fl.texto(`${dataBr(a.data)} ${a.hora} · ${ROTULO[a.tipo] ?? a.tipo} · ${a.acao === "incluir" ? "incluída" : "desconsiderada"} · ${a.motivo}`, 7.2);
    }
  }
  if (c.avisos && c.avisos.length > 0) {
    fl.y -= 4;
    for (const a of c.avisos) fl.texto(`• ${a}`, 6.5);
  }

  // assinatura do funcionário
  fl.espaco(80);
  fl.y -= 6;
  const png = await doc.embedPng(Uint8Array.from(atob(d.assinatura_png.split(",")[1] ?? ""), (ch) => ch.charCodeAt(0)));
  const esc2 = png.scaleToFit(200, 52);
  fl.page.drawImage(png, { x: fl.m, y: fl.y - esc2.height, width: esc2.width, height: esc2.height });
  fl.y -= esc2.height + 2;
  fl.page.drawLine({ start: { x: fl.m, y: fl.y }, end: { x: fl.m + 220, y: fl.y }, thickness: 0.5 });
  fl.y -= 2;
  fl.linha(`${c.trabalhador.nome} · assinado em ${d.assinado_em}, no app Trilha Ponto, após entrar com CPF e código`, 7.2);

  // selo de validação da empresa
  fl.espaco(70);
  fl.y -= 6;
  const selo = fl.y;
  fl.y -= 4;
  fl.linha("Validação da empresa", 8.5, true, fl.m + 6);
  const lx = fl.m + 6, ll = fl.w - 2 * fl.m - 12;
  fl.texto(`Documento emitido e validado por ${c.empregador.razao_social} (CNPJ ${cnpjFmt(c.empregador.cnpj)}) no sistema Trilha Ponto. ` +
    `Registro nº ${d.registro}${d.versao > 1 ? `, versão ${d.versao}` : ""}, emitido em ${d.emitido_em} e assinado pelo funcionário em ${d.assinado_em}.`,
    7, ll, lx);
  fl.texto(`SHA-256 do conteúdo do espelho: ${d.sha256}`, 6.5, ll, lx);
  fl.texto(`Selo da assinatura (HMAC-SHA256): ${d.assinatura_sha256}`, 6.5, ll, lx);
  fl.texto(`Confira a autenticidade pelo QR ou em ${d.url_verificacao}. A conferência mostra o registro, a empresa, o mês, ` +
    "se o documento está íntegro e assinado, e o SHA-256 deste PDF; não mostra dado pessoal.", 6.5, ll, lx);
  fl.y -= 3;
  if (fl.page === fl.doc.getPage(fl.doc.getPageCount() - 1) && selo > fl.y) {
    fl.page.drawRectangle({ x: fl.m, y: fl.y, width: fl.w - 2 * fl.m, height: selo - fl.y, borderColor: rgb(0.1, 0.2, 0.4), borderWidth: 0.8 });
  }

  const bytes = await doc.save({ useObjectStreams: false });
  return assinarComCertificado(bytes);
}

// ponto único da assinatura ICP-Brasil da empresa (PAdES); sem certificado, o PDF segue com o selo do sistema
function assinarComCertificado(pdf: Uint8Array): Uint8Array {
  return pdf;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const token = req.headers.get("x-espelho-token") ?? "";
  if (!token) return json({ ok: false, erro: "token ausente" }, 401);
  let id: string;
  try {
    const corpo = JSON.parse(await req.text());
    id = String(corpo?.id ?? "");
  } catch {
    return json({ ok: false, erro: "json invalido" }, 400);
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) return json({ ok: false, erro: "id invalido" }, 400);

  try {
    const [linha] = await sql<{ d: Dados | null }[]>`select fn_ponto_espelho_pdf_dados(${token}, ${id}::uuid) as d`;
    const d = linha?.d;
    if (!d) return json({ ok: false, erro: "espelho nao assinado" }, 404);
    if (d.ja_gerado) return json({ ok: true, info: "ja gerado" });
    const pdf = await montarPdf(d);
    const [r] = await sql<{ r: unknown }[]>`select fn_ponto_espelho_pdf_gravar(${token}, ${id}::uuid, ${pdf}) as r`;
    return json({ ok: true, resultado: r?.r ?? null });
  } catch (err) {
    // detalhe só no log da função, sem dado pessoal
    const msg = err instanceof Error ? err.message : "erro";
    console.error("espelho-pdf:", /token/.test(msg) ? "token invalido" : msg.slice(0, 200));
    return json({ ok: false, erro: /token/.test(msg) ? "nao autorizado" : "falha ao gerar o PDF" }, /token/.test(msg) ? 401 : 500);
  }
});
