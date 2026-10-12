import { useState } from 'react'
import { FileCheck2, Printer } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal } from './ui'
import { api, erroMsg } from '../lib/api'
import { hojeBahia } from '../lib/types'
import type { DossieLocal as Dossie, Local, SituacaoDossie } from '../lib/types'

// Dossiê de conformidade por local (backlog 100, decisão 79): o que o RH entrega ao cliente tomador.
// Só a situação de cada documento na data do serviço; o arquivo nunca é aberto (ASO é dado de saúde).

const ROTULO: Record<SituacaoDossie, string> = {
  valido: 'Válido', vencendo: 'Vence em breve', vencido: 'Vencido', sem_data: 'Sem validade', nao_cadastrado: 'Não cadastrado',
}
const COR: Record<SituacaoDossie, string> = {
  valido: 'text-green-700', vencendo: 'text-amber-700', vencido: 'text-red-700', sem_data: 'text-red-700', nao_cadastrado: 'text-red-700',
}

const situacaoTexto = (d: Dossie['tecnicos'][number]['documentos'][number]) =>
  ROTULO[d.situacao] + (d.validade ? ` (${d.validade})` : '')

// Janela de impressão montada só com textContent: nenhum dado entra como HTML.
function imprimir(d: Dossie) {
  const w = window.open('', '_blank')
  if (!w) return
  const doc = w.document
  doc.title = `Dossiê ${d.local.nome} ${d.data}`
  const el = (tag: string, texto?: string, pai: HTMLElement = doc.body) => {
    const e = doc.createElement(tag)
    if (texto != null) e.textContent = texto
    pai.appendChild(e)
    return e
  }
  const estilo = doc.createElement('style')
  estilo.textContent = 'body{font:12px system-ui,sans-serif;margin:24px;color:#111}h1{font-size:16px;margin:0 0 4px}'
    + 'p{margin:2px 0}table{border-collapse:collapse;width:100%;margin-top:12px}th,td{border:1px solid #999;padding:4px 6px;text-align:left;vertical-align:top}'
    + 'th{background:#eee}.rodape{margin-top:16px;color:#555;font-size:11px}'
  doc.head.appendChild(estilo)
  el('h1', 'Dossiê de conformidade')
  el('p', `Local: ${d.local.nome}${d.local.cliente ? ` — ${d.local.cliente}` : ''}`)
  if (d.local.endereco || d.local.cidade) el('p', [d.local.endereco, d.local.cidade].filter(Boolean).join(', '))
  el('p', `Data do serviço: ${d.data}`)
  const tabela = el('table')
  const cab = el('tr', undefined, el('thead', undefined, tabela))
  for (const c of ['Funcionário', 'Função', 'Hora', 'Atividade', 'Documentos exigidos', 'Situação']) el('th', c, cab)
  const corpo = el('tbody', undefined, tabela)
  if (d.tecnicos.length === 0) el('td', 'Nenhum funcionário escalado neste local e data.', el('tr', undefined, corpo)).setAttribute('colspan', '6')
  for (const t of d.tecnicos) {
    const tr = el('tr', undefined, corpo)
    el('td', t.tecnico, tr); el('td', t.funcao ?? '—', tr); el('td', t.hora, tr); el('td', t.atividades ?? '—', tr)
    const docs = el('td', undefined, tr)
    if (t.sem_atividade) el('div', 'Atividade não informada na escala', docs)
    else if (t.documentos.length === 0) docs.textContent = 'Nenhum exigido pela atividade'
    for (const x of t.documentos) el('div', `${x.documento}: ${situacaoTexto(x)}`, docs)
    el('td', t.apto ? 'Apto' : 'Pendente', tr)
  }
  el('p', `Situação na data do serviço. "Vence em breve": até ${d.aviso_dias} dias depois dela. Os documentos ficam com o empregador e não são anexados.`).className = 'rodape'
  // quem gerou fica no registro interno; o e-mail não vai ao cliente (revisão do seguranca)
  el('p', `Gerado em ${d.gerado_em} — registro nº ${d.registro}.`).className = 'rodape'
  w.focus()
  w.print()
}

export default function DossieLocal({ local, onClose }: { local: Local; onClose: () => void }) {
  const [data, setData] = useState(hojeBahia())
  const [dossie, setDossie] = useState<Dossie | null>(null)
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  const gerar = async () => {
    setErro(null); setCarregando(true)
    try { setDossie(await api.dossieLocal(local.id, data)) }
    catch (e) { setErro(erroMsg(e)); setDossie(null) }
    finally { setCarregando(false) }
  }

  const pendentes = dossie?.tecnicos.filter(t => !t.apto).length ?? 0

  return (
    <Modal open onClose={onClose} width="max-w-4xl" title={`Dossiê de conformidade — ${local.nome}`}
      footer={<>
        <Button variant="outline" onClick={onClose}>Fechar</Button>
        <Button onClick={() => dossie && imprimir(dossie)} disabled={!dossie}><Printer className="h-4 w-4" /> Imprimir</Button>
      </>}>
      <div className="space-y-3">
        <p className="text-xs text-muted-foreground">
          Para entregar ao cliente: cada funcionário escalado neste local e a situação, na data do serviço, dos documentos que a
          atividade exige. Só a situação; nenhum arquivo é anexado. Cada geração fica registrada.
        </p>
        <div className="flex items-end gap-2">
          <Field label="Data do serviço"><Input type="date" value={data} onChange={e => { setData(e.target.value); setDossie(null) }} disabled={carregando} /></Field>
          <Button onClick={() => void gerar()} disabled={carregando || !data}><FileCheck2 className="h-4 w-4" /> {carregando ? 'Gerando...' : 'Gerar'}</Button>
        </div>
        {erro && <ErrorBox>{erro}</ErrorBox>}
        {dossie && (
          <>
            <p className="text-sm">
              {dossie.tecnicos.length} funcionário(s) escalado(s) em {dossie.data}
              {dossie.tecnicos.length > 0 && (pendentes === 0
                ? <span className="ml-2 font-medium text-green-700">todos aptos</span>
                : <span className="ml-2 font-medium text-red-700">{pendentes} com pendência</span>)}
            </p>
            <div className="overflow-x-auto rounded-md border">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b bg-muted/50 text-left text-xs">
                    <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Hora</th>
                    <th className="px-3 py-2">Atividade</th><th className="px-3 py-2">Documentos exigidos</th>
                    <th className="px-3 py-2">Situação</th>
                  </tr>
                </thead>
                <tbody>
                  {dossie.tecnicos.length === 0 ? (
                    <tr><td colSpan={5} className="py-8 text-center text-muted-foreground">Nenhum funcionário escalado neste local e data</td></tr>
                  ) : dossie.tecnicos.map((t, i) => (
                    <tr key={i} className="border-b align-top last:border-0">
                      <td className="px-3 py-2"><p className="font-medium">{t.tecnico}</p>{t.funcao && <p className="text-xs text-muted-foreground">{t.funcao}</p>}</td>
                      <td className="px-3 py-2 font-mono text-xs">{t.hora}</td>
                      <td className="px-3 py-2 text-xs">{t.atividades ?? '—'}</td>
                      <td className="px-3 py-2 text-xs">
                        {t.sem_atividade && <p className="text-red-700">Atividade não informada na escala</p>}
                        {t.documentos.length === 0 ? (!t.sem_atividade && <span className="text-muted-foreground">Nenhum exigido pela atividade</span>)
                          : t.documentos.map((x, j) => <p key={j}>{x.documento}: <span className={COR[x.situacao]}>{situacaoTexto(x)}</span></p>)}
                      </td>
                      <td className={`px-3 py-2 text-xs font-medium ${t.apto ? 'text-green-700' : 'text-red-700'}`}>{t.apto ? 'Apto' : 'Pendente'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="text-xs text-muted-foreground">Registro nº {dossie.registro}, gerado em {dossie.gerado_em}. "Vence em breve": até {dossie.aviso_dias} dias depois da data do serviço.</p>
          </>
        )}
      </div>
    </Modal>
  )
}
