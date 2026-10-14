import qrcode from 'qrcode-generator'
import { ALERTA_JORNADA, PONTO_ROTULO, logoEmpresa, minutosHm } from '../lib/types'
import type { EspelhoCompleto, EspelhoResumo } from '../lib/types'

// Espelho de ponto mensal como documento (decisão 82): conteúdo congelado, registro, QR de conferência pública
// e, quando houver, a assinatura do funcionário. O mesmo componente serve ao app do funcionário, ao painel do
// gestor e à impressão (classe area-impressao: só ela sai no papel ou no PDF).

function Qr({ texto, lado = 104 }: { texto: string; lado?: number }) {
  const qr = qrcode(0, 'M')
  qr.addData(texto)
  qr.make()
  const n = qr.getModuleCount()
  const cel: [number, number][] = []
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) cel.push([c, r])
  return (
    <svg viewBox={`-1 -1 ${n + 2} ${n + 2}`} width={lado} height={lado} shapeRendering="crispEdges" role="img" aria-label="QR de conferência">
      <rect x={-1} y={-1} width={n + 2} height={n + 2} fill="#fff" />
      {cel.map(([x, y]) => <rect key={`${x}-${y}`} x={x} y={y} width={1} height={1} fill="#000" />)}
    </svg>
  )
}

const dataBr = (d: string | null | undefined) => d ? d.slice(0, 10).split('-').reverse().join('/') : '—'
const cpfFmt = (c: string) => c.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4')
const cnpjFmt = (c: string) => c.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5')
const dataHora = (s: string) => new Date(s).toLocaleString('pt-BR', { timeZone: 'America/Bahia', dateStyle: 'short', timeStyle: 'short' })
const SEMANA = ['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb']
// horas no formato HH:MM, como a folha de pagamento lê (decisão 83)
const hh = (m: number | null | undefined) => m == null ? '—' : `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
const hhOu = (m: number | null | undefined) => m ? hh(m) : '—'

function Linha({ rotulo, valor, forte }: { rotulo: string; valor: string; forte?: boolean }) {
  return (
    <div className={`flex justify-between gap-2 ${forte ? 'font-semibold' : ''}`}>
      <span>{rotulo}</span><span className="font-mono">{valor}</span>
    </div>
  )
}

function Resumo({ r }: { r: EspelhoResumo }) {
  const p = r.a_pagar, d = r.a_descontar, i = r.informativo
  return (
    <div className="grid gap-3 sm:grid-cols-3 print:grid-cols-3">
      <div className="space-y-0.5 rounded border border-gray-400 p-2">
        <p className="font-semibold">A pagar ao funcionário</p>
        <Linha rotulo="Hora extra 50%" valor={hh(p.he50_min)} />
        <Linha rotulo="Hora extra 100% (descanso semanal e feriado)" valor={hh(p.he100_min)} />
        <Linha rotulo="Adicional noturno (horas reduzidas)" valor={hh(p.noturno_reduzidas_min)} />
        <Linha rotulo="Intervalo não concedido (+50%)" valor={hh(p.intervalo_nao_concedido_min)} />
        <Linha rotulo="Total de horas extras" valor={hh(p.he50_min + p.he100_min)} forte />
      </div>
      <div className="space-y-0.5 rounded border border-gray-400 p-2">
        <p className="font-semibold">A descontar</p>
        <Linha rotulo="Horas em débito" valor={hh(d.debito_min)} forte />
        <Linha rotulo="Dias sem registro" valor={String(d.dias_sem_registro)} />
        <Linha rotulo="Semanas com falta (DSR)" valor={String(d.semanas_com_falta)} />
        <p className="pt-1 text-[10px] text-gray-600">Débito: falta, atraso e saída antecipada não abonados, acima de 10 min no dia.</p>
      </div>
      <div className="space-y-0.5 rounded border border-gray-400 p-2">
        <p className="font-semibold">Informativo</p>
        <Linha rotulo="Horas previstas" valor={hh(i.previsto_min)} />
        <Linha rotulo="Horas trabalhadas" valor={hh(i.trabalhado_min)} />
        <Linha rotulo="Noturnas (relógio)" valor={hh(i.noturno_relogio_min)} />
        <Linha rotulo="Abonadas com justificativa" valor={hh(i.abonado_justificado_min)} />
        <Linha rotulo="Abonadas pela empresa" valor={hh(i.abonado_empresa_min)} />
        <Linha rotulo="Dias abonados com justificativa" valor={String(i.dias_abonados_justificados)} />
        {!!i.folgas_compensatorias && <Linha rotulo="Folgas compensatórias" valor={String(i.folgas_compensatorias)} />}
        <Linha rotulo="Dias trabalhados" valor={String(i.dias_trabalhados)} />
        {i.sabados_sem_expediente > 0 && <Linha rotulo="Sábados sem expediente (abonados)" valor={String(i.sabados_sem_expediente)} />}
        {i.dias_he_acima_2h > 0 && <Linha rotulo="Dias com mais de 2 h extras" valor={String(i.dias_he_acima_2h)} />}
        {i.interjornada_curta > 0 && <Linha rotulo="Descanso entre jornadas abaixo de 11 h" valor={String(i.interjornada_curta)} />}
        {i.feriados.length > 0 && <p className="pt-1 text-[10px] text-gray-600">Feriados: {i.feriados.join(', ')}</p>}
      </div>
    </div>
  )
}

export default function EspelhoDocumento({ e, previa }: { e: EspelhoCompleto; previa?: boolean }) {
  const c = e.conteudo
  if (!c) return <p className="text-sm text-muted-foreground">Esta versão do espelho foi substituída por uma mais nova.</p>
  const url = `${window.location.origin}/v?c=${e.codigo}`
  const novo = !!c.resumo   // espelhos emitidos antes da migration 90 não têm o resumo de pagamento
  const logo = logoEmpresa(c.empregador.logo)
  return (
    <div className="area-impressao space-y-3 bg-white text-[12px] text-black">
      <div className="flex items-start justify-between gap-3">
        <div className="space-y-0.5">
          {/* logotipo da empresa, congelado no espelho na emissão (decisão 96); fundo escuro do próprio logotipo */}
          {logo && (
            <img src={logo.src} alt={logo.nome}
                 className="mb-1 h-8 w-auto rounded bg-[#0d1e3c] px-1.5 py-1 print:[-webkit-print-color-adjust:exact] print:[print-color-adjust:exact]" />
          )}
          <p className="text-sm font-semibold">Espelho de ponto · {c.competencia}</p>
          <p>{c.empregador.razao_social} · CNPJ {cnpjFmt(c.empregador.cnpj)}</p>
          <p>{c.trabalhador.nome} · CPF {cpfFmt(c.trabalhador.cpf)}</p>
          <p>Função: {c.trabalhador.funcao ?? '—'} · Admissão: {dataBr(c.trabalhador.admissao)}</p>
          {c.jornada.escalas && c.jornada.escalas.length > 0
            ? <p>Escala: {c.jornada.escalas.map(x => `${x.escala} (${x.de} a ${x.ate})`).join('; ')} · intervalo de {minutosHm(c.jornada.intervalo_min)}</p>
            : <p>Jornada: {minutosHm(c.jornada.dia_util_min)} de segunda a sexta, {minutosHm(c.jornada.sabado_min)} no sábado, intervalo de {minutosHm(c.jornada.intervalo_min)}</p>}
          {previa
            ? <p className="text-[11px] font-semibold text-amber-700">Período {dataBr(c.de)} a {dataBr(c.ate)} · PRÉVIA, ainda não emitida: é o que sai ao fechar a folha</p>
            : <p className="text-[11px] text-gray-600">Período {dataBr(c.de)} a {dataBr(c.ate)} · Registro nº {e.registro}{e.versao > 1 ? ` (versão ${e.versao})` : ''} · emitido em {dataHora(e.emitido_em)}</p>}
        </div>
        {!previa && <div className="shrink-0 text-center">
          <Qr texto={url} />
          <p className="font-mono text-[9px]">{e.codigo}</p>
        </div>}
      </div>

      <table className="w-full border-collapse text-[11px]">
        <thead><tr className="border-b border-gray-400 text-left">
          <th className="py-1 pr-2">Dia</th><th className="pr-2">Entrada</th><th className="pr-2">Saída almoço</th><th className="pr-2">Volta</th>
          <th className="pr-2">Saída</th><th className="pr-2">Trabalhado</th>
          {novo ? <><th className="pr-2">HE 50%</th><th className="pr-2">HE 100%</th><th className="pr-2">Noturno</th><th className="pr-2">Débito</th></>
                : <th className="pr-2">HE</th>}
          <th>Observação</th>
        </tr></thead>
        <tbody>
          {c.dias.length === 0 ? <tr><td colSpan={novo ? 11 : 8} className="py-2 text-center text-gray-600">Sem marcações no mês</td></tr>
            : c.dias.map(d => (
              <tr key={d.data} className="border-b border-gray-200">
                <td className="py-0.5 pr-2 whitespace-nowrap">{dataBr(d.data)} {SEMANA[new Date(d.data + 'T12:00:00').getDay()]}</td>
                <td className="pr-2">{d.entrada ?? '—'}</td><td className="pr-2">{d.saida_almoco ?? '—'}</td>
                <td className="pr-2">{d.volta_almoco ?? '—'}</td><td className="pr-2">{d.saida ?? '—'}</td>
                <td className="pr-2">{novo ? hhOu(d.trabalhado_min) : minutosHm(d.trabalhado_min)}</td>
                {novo ? <><td className="pr-2">{hhOu(d.he50_min)}</td><td className="pr-2">{hhOu(d.he100_min)}</td>
                          <td className="pr-2">{hhOu(d.noturno_min)}</td><td className="pr-2">{hhOu(d.debito_min)}</td></>
                      : <td className="pr-2">{d.he_min ? minutosHm(d.he_min) : '—'}</td>}
                <td>{[d.feriado ? `Feriado: ${d.feriado}` : null,
                      d.folga_de ? `Folga compensatória do trabalho de ${d.folga_de}` : null,
                      d.compensado_em ? `Compensado com folga em ${d.compensado_em}` : null,
                      // dia da escala sem marcação nem abono: falta injustificada (decisão 97)
                      novo && d.debito_min && !d.trabalhado_min && !d.entrada && !d.saida && !d.abono ? 'Falta injustificada' : null,
                      ...(d.alertas ?? []).map(a => ALERTA_JORNADA[a] ?? a), d.abono ? (d.abono_motivo ? `Abono - ${d.abono_motivo}${d.abono !== 'dia inteiro' ? ` (${d.abono})` : ''}` : `Abono: ${d.abono}`) : null,
                      d.ajustes ? 'Ajustado' : null].filter(Boolean).join(' · ') || ''}</td>
              </tr>
            ))}
        </tbody>
      </table>

      {c.resumo ? <Resumo r={c.resumo} /> : (
        <p>
          <strong>Totais:</strong> trabalhado {minutosHm(c.totais.trabalhado_min)} · hora extra {minutosHm(c.totais.he_min)} ·
          faltas {c.totais.faltas} · atrasos {c.totais.atrasos} · dias abonados {c.totais.dias_abonados}
        </p>
      )}

      {c.avisos && c.avisos.length > 0 && (
        <ul className="list-disc space-y-0.5 pl-5 text-[10px] text-gray-700">
          {c.avisos.map((a, i) => <li key={i}>{a}</li>)}
        </ul>
      )}

      {c.ajustes.length > 0 && (
        <div>
          <p className="font-semibold">Marcações tratadas pelo gestor</p>
          <ul className="list-disc pl-5">
            {c.ajustes.map((a, i) => (
              <li key={i}>{dataBr(a.data)} {a.hora} · {PONTO_ROTULO[a.tipo as keyof typeof PONTO_ROTULO] ?? a.tipo} · {a.acao === 'incluir' ? 'incluída' : 'desconsiderada'} · {a.motivo}</li>
            ))}
          </ul>
        </div>
      )}

      {!previa && <div className="flex items-end justify-between gap-4 border-t border-gray-400 pt-2">
        <div>
          {e.assinado_em && e.assinatura_png
            ? <><img src={e.assinatura_png} alt="Assinatura do funcionário" className="h-16 max-w-[240px] object-contain" />
                <p className="border-t border-gray-500 pt-0.5">{c.trabalhador.nome} · assinado em {dataHora(e.assinado_em)}</p></>
            : <p className="text-gray-600">Ainda não assinado pelo funcionário.</p>}
        </div>
        <p className="max-w-[45%] text-right text-[9px] text-gray-600">
          Confira a autenticidade pelo QR ou em {window.location.host}/v com o código {e.codigo}. SHA-256 {e.sha256.slice(0, 16)}…
        </p>
      </div>}
    </div>
  )
}
