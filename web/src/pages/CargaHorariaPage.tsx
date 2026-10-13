import { useCallback, useEffect, useMemo, useState } from 'react'
import { AlertTriangle, Ban, Edit2, FileSignature, Info, Loader2, Plus, RefreshCw, Users, X } from 'lucide-react'
import { Button, ErrorBox, Field, Input, Modal, Select } from '../components/ui'
import { api, erroMsg } from '../lib/api'
import { hojeBahia, minutosHm } from '../lib/types'
import type {
  AlvoCarga, CargaAtribuicao, CargaFuncionario, CargaHoraria, Empresa, ModeloCarga, Tecnico, TimeEquipe, TipoCarga, ValidacaoCarga,
} from '../lib/types'

// Escala / Carga Horária e Times (decisão 88, backlog 104). A escala é da empregadora; vale a mais específica
// (funcionário > time > empresa); sem escala, vale a jornada padrão. A validação da CLT e o aceite de risco ficam no
// banco (fn_carga_validar, app_salvar_carga): aqui só se mostra o que ele responde.

const DIAS = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom']
const TIPO_ROTULO: Record<TipoCarga, string> = { semanal: 'Semanal', revezamento: 'Turno de revezamento', '12x36': '12x36' }
const ALVO_ROTULO: Record<AlvoCarga, string> = { empresa: 'Empresa', time: 'Time', tecnico: 'Funcionário' }
const SITUACAO_COR: Record<CargaAtribuicao['situacao'], string> = {
  vigente: 'bg-green-100 text-green-800', futura: 'bg-blue-100 text-blue-800', encerrada: 'bg-muted text-muted-foreground', cancelada: 'bg-muted text-muted-foreground line-through',
}

const paraHm = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
const deHm = (s: string) => { const [h, m] = s.split(':').map(Number); return (h || 0) * 60 + (m || 0) }
const dataBr = (s: string) => s.split('-').reverse().join('/')
const amanha = () => { const d = new Date(`${hojeBahia()}T12:00:00`); d.setDate(d.getDate() + 1); return d.toISOString().slice(0, 10) }
const DIA_LONGO = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo']
const resumoDias = (c: { tipo: TipoCarga; minutos: number[] | null; plantao_min: number | null }) =>
  c.tipo === '12x36' ? `Plantão de ${minutosHm(c.plantao_min)}, dia sim, dia não`
    : (c.minutos ?? []).map((m, i) => `${DIAS[i]} ${m ? minutosHm(m) : 'folga'}`).join(' · ')

interface Rascunho { empresa_id: string; nome: string; tipo: TipoCarga; minutos: number[]; plantao_min: number; intervalo_min: number; entrada: string; dsr_dia: number }
const RASCUNHO: Rascunho = { empresa_id: '', nome: '', tipo: 'semanal', minutos: [480, 480, 480, 480, 480, 240, 0], plantao_min: 720, intervalo_min: 60, entrada: '', dsr_dia: 7 }

type Vista = 'escalas' | 'atribuicoes' | 'funcionarios' | 'times'

export default function CargaHorariaPage({ tecnicos, recarregarTecnicos, podeEditar }: {
  tecnicos: Tecnico[]; recarregarTecnicos: () => Promise<void> | void; podeEditar: boolean
}) {
  const [vista, setVista] = useState<Vista>('escalas')
  const [empresas, setEmpresas] = useState<Empresa[]>([])
  const [empresa, setEmpresa] = useState('')
  const [cargas, setCargas] = useState<CargaHoraria[] | null>(null)
  const [atribuicoes, setAtribuicoes] = useState<CargaAtribuicao[] | null>(null)
  const [times, setTimes] = useState<TimeEquipe[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  const empregadoras = useMemo(() => empresas.filter(e => e.empregadora && e.ativo), [empresas])
  useEffect(() => { api.empresas().then(setEmpresas).catch(e => setErro(erroMsg(e))) }, [])

  const carregar = useCallback(async () => {
    setErro(null)
    const emp = empresa || null
    try {
      const [c, a, t] = await Promise.all([api.cargas(emp), api.cargaAtribuicoes(emp), api.times(emp)])
      setCargas(c); setAtribuicoes(a); setTimes(t)
    } catch (e) { setErro(erroMsg(e)) }
  }, [empresa])
  useEffect(() => { void carregar() }, [carregar])

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold">Escala / Carga Horária</h2>
          <p className="text-xs text-muted-foreground">
            A carga horária contratual de cada empregadora, atribuída à empresa, a um time ou a um funcionário. Vale a mais
            específica (funcionário, depois time, depois empresa); sem escala, vale a jornada padrão.
          </p>
        </div>
        <div className="flex items-end gap-2">
          <Field label="Empresa">
            <Select value={empresa} onChange={e => setEmpresa(e.target.value)}>
              <option value="">Todas as empregadoras</option>
              {empregadoras.map(e => <option key={e.id} value={e.id}>{e.nome_fantasia || e.razao_social}</option>)}
            </Select>
          </Field>
          <Button variant="outline" size="sm" onClick={() => void carregar()}><RefreshCw className="h-3.5 w-3.5" /> Atualizar</Button>
        </div>
      </div>

      <p className="flex items-start gap-1.5 rounded-md border border-blue-200 bg-blue-50 px-3 py-2 text-xs text-blue-900">
        <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" />
        Nesta etapa a escala é cadastrada e atribuída. O espelho de ponto, o débito e as horas extras ainda usam a jornada
        padrão (8h de segunda a sexta e 4h no sábado); passam a usar a escala na próxima etapa.
      </p>

      {erro && <ErrorBox>{erro}</ErrorBox>}

      <div className="flex flex-wrap items-center gap-1 rounded-md border p-0.5 lg:w-fit">
        {([['escalas', 'Escalas'], ['atribuicoes', 'Atribuições'], ['funcionarios', 'Por funcionário'], ['times', 'Times']] as [Vista, string][])
          .map(([id, rotulo]) => (
          <button key={id} type="button" onClick={() => setVista(id)}
            className={`rounded px-3 py-1.5 text-sm font-medium ${vista === id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted'}`}>
            {rotulo}
          </button>
        ))}
      </div>

      {vista === 'escalas' && <Escalas cargas={cargas} empregadoras={empregadoras} empresa={empresa} podeEditar={podeEditar} recarregar={carregar} />}
      {vista === 'atribuicoes' && <Atribuicoes atribuicoes={atribuicoes} cargas={cargas ?? []} times={times ?? []} tecnicos={tecnicos}
        empregadoras={empregadoras} podeEditar={podeEditar} recarregar={carregar} />}
      {vista === 'funcionarios' && <PorFuncionario empresa={empresa} />}
      {vista === 'times' && <Times times={times} tecnicos={tecnicos} empregadoras={empregadoras} empresa={empresa} podeEditar={podeEditar}
        recarregar={async () => { await carregar(); await recarregarTecnicos() }} />}
    </div>
  )
}

function Carregando() { return <div className="flex justify-center py-10"><Loader2 className="h-5 w-5 animate-spin" /></div> }

// Escalas ---------------------------------------------------------------------------------------------------
function Escalas({ cargas, empregadoras, empresa, podeEditar, recarregar }: {
  cargas: CargaHoraria[] | null; empregadoras: Empresa[]; empresa: string; podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const [nova, setNova] = useState(false)
  const [aceite, setAceite] = useState<CargaHoraria | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  const ativar = async (c: CargaHoraria) => {
    setErro(null)
    try { await api.cargaAtivar(c.id, !c.ativo); await recarregar() } catch (e) { setErro(erroMsg(e)) }
  }

  return (
    <section className="space-y-2">
      <div className="flex items-center justify-between">
        <p className="text-xs text-muted-foreground">Escala salva não muda: para alterar, crie outra e atribua no lugar.</p>
        {podeEditar && <Button size="sm" onClick={() => setNova(true)}><Plus className="h-4 w-4" /> Nova escala</Button>}
      </div>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!cargas ? <Carregando /> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Escala</th><th className="px-3 py-2">Dias</th><th className="px-3 py-2">Semana</th>
              <th className="px-3 py-2">Intervalo</th><th className="px-3 py-2">Aceite de risco</th><th className="px-3 py-2">Em uso</th><th className="px-3 py-2" />
            </tr></thead>
            <tbody>
              {cargas.length === 0 ? (
                <tr><td colSpan={7} className="py-10 text-center text-muted-foreground">Nenhuma escala cadastrada</td></tr>
              ) : cargas.map(c => (
                <tr key={c.id} className={`border-b last:border-0 ${!c.ativo ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2"><p className="font-medium">{c.nome}</p>
                    <p className="text-xs text-muted-foreground">{c.empresa} · {TIPO_ROTULO[c.tipo]}{!c.ativo && ' · inativa'}</p></td>
                  <td className="px-3 py-2 text-xs">{resumoDias(c)}{c.dsr_dia && <span className="text-muted-foreground"> · DSR {DIA_LONGO[c.dsr_dia - 1]}</span>}{c.entrada && <span className="text-muted-foreground"> · entrada {c.entrada}</span>}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{minutosHm(c.semanal_min)}{c.tipo === '12x36' && ' (média)'}</td>
                  <td className="px-3 py-2 text-xs">{c.intervalo_min} min</td>
                  <td className="px-3 py-2 text-xs">
                    {!c.aceite_em ? <span className="text-muted-foreground">sem risco</span>
                      : c.aceite_texto ? <button type="button" className="flex items-center gap-1 text-amber-800 underline" onClick={() => setAceite(c)}>
                          <FileSignature className="h-3.5 w-3.5" /> {c.aceite_nome}</button>
                      : <span className="text-amber-800">com aceite</span>}
                  </td>
                  <td className="px-3 py-2 text-xs">{c.atribuicoes}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right">
                    {podeEditar && <Button variant="ghost" size="sm" onClick={() => void ativar(c)}>{c.ativo ? 'Inativar' : 'Ativar'}</Button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {nova && <NovaEscala empregadoras={empregadoras} empresa={empresa} onFechar={() => setNova(false)}
        onSalva={async () => { setNova(false); await recarregar() }} />}
      <Modal open={!!aceite} onClose={() => setAceite(null)} width="max-w-2xl" title="Aceite de risco da empregadora"
        footer={<Button variant="outline" onClick={() => setAceite(null)}>Fechar</Button>}>
        {aceite && <div className="space-y-2 text-sm">
          <p className="whitespace-pre-wrap">{aceite.aceite_texto}</p>
          <p className="break-all font-mono text-[11px] text-muted-foreground">SHA-256 {aceite.aceite_sha256}</p>
        </div>}
      </Modal>
    </section>
  )
}

function ListaValidacao({ v }: { v: ValidacaoCarga }) {
  return (
    <div className="space-y-1.5 text-xs">
      {v.bloqueios.map(b => <p key={b.codigo} className="flex gap-1.5 rounded border border-red-300 bg-red-50 px-2 py-1.5 text-red-900">
        <Ban className="mt-0.5 h-3.5 w-3.5 shrink-0" /><span><strong>Não permitido.</strong> {b.texto}</span></p>)}
      {v.riscos.map(r => <p key={r.codigo} className="flex gap-1.5 rounded border border-amber-300 bg-amber-50 px-2 py-1.5 text-amber-900">
        <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /><span><strong>Exige aceite.</strong> {r.texto}</span></p>)}
      {v.avisos.map(a => <p key={a.codigo} className="flex gap-1.5 rounded border border-blue-200 bg-blue-50 px-2 py-1.5 text-blue-900">
        <Info className="mt-0.5 h-3.5 w-3.5 shrink-0" /><span>{a.texto}</span></p>)}
      {v.bloqueios.length + v.riscos.length + v.avisos.length === 0 &&
        <p className="rounded border border-green-300 bg-green-50 px-2 py-1.5 text-green-900">Dentro da CLT, sem ponto que dependa de acordo.</p>}
    </div>
  )
}

function NovaEscala({ empregadoras, empresa, onFechar, onSalva }: {
  empregadoras: Empresa[]; empresa: string; onFechar: () => void; onSalva: () => Promise<void>
}) {
  const [r, setR] = useState<Rascunho>({ ...RASCUNHO, empresa_id: empresa || (empregadoras.length === 1 ? empregadoras[0].id : '') })
  const [modelos, setModelos] = useState<ModeloCarga[]>([])
  const [v, setV] = useState<ValidacaoCarga | null>(null)
  const [aceito, setAceito] = useState(false)
  const [instrumento, setInstrumento] = useState('')
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => { api.cargasModelos().then(setModelos).catch(e => setErro(erroMsg(e))) }, [])
  const payload = useMemo(() => ({
    empresa_id: r.empresa_id, nome: r.nome, tipo: r.tipo, intervalo_min: r.intervalo_min, entrada: r.entrada || null,
    ...(r.tipo === '12x36' ? { plantao_min: r.plantao_min } : { minutos: r.minutos, dsr_dia: r.minutos[r.dsr_dia - 1] === 0 ? r.dsr_dia : null }),
  }), [r])
  useEffect(() => {
    const t = setTimeout(() => { api.cargaValidar(payload, instrumento.trim() || null).then(setV).catch(e => setErro(erroMsg(e))) }, 300)
    return () => clearTimeout(t)
  }, [payload, instrumento])
  // o aceite vale para o termo que está na tela: mudou o termo, marca de novo
  useEffect(() => { setAceito(false) }, [v?.termo])

  const usarModelo = (nome: string) => {
    const m = modelos.find(x => x.nome === nome)
    if (!m) return
    setR(p => ({ ...p, nome: p.nome || m.nome, tipo: m.tipo, intervalo_min: m.intervalo_min,
                 minutos: m.minutos ?? p.minutos, plantao_min: m.plantao_min ?? p.plantao_min, dsr_dia: m.dsr_dia ?? p.dsr_dia }))
  }
  const temRisco = (v?.riscos.length ?? 0) > 0
  const bloqueado = !v || v.bloqueios.length > 0
  const salvar = async () => {
    setErro(null)
    if (!r.empresa_id) return setErro('Escolha a empregadora.')
    if (!r.nome.trim()) return setErro('Dê um nome à escala.')
    setSalvando(true)
    try {
      await api.salvarCarga(payload, temRisco ? { aceito, instrumento: instrumento.trim() || null, riscos: (v?.riscos ?? []).map(x => x.codigo) } : null)
      await onSalva()
    } catch (e) { setErro(erroMsg(e)) } finally { setSalvando(false) }
  }

  return (
    <Modal open onClose={() => { if (!salvando) onFechar() }} width="max-w-2xl" title="Nova escala"
      footer={<>
        <Button variant="outline" onClick={onFechar} disabled={salvando}>Cancelar</Button>
        <Button onClick={() => void salvar()} disabled={salvando || bloqueado || (temRisco && !aceito)}>
          {salvando ? 'Salvando...' : temRisco ? 'Assinar o aceite e salvar' : 'Salvar'}
        </Button>
      </>}>
      <div className="space-y-3">
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Empregadora">
            <Select value={r.empresa_id} onChange={e => setR(p => ({ ...p, empresa_id: e.target.value }))}>
              <option value="">Escolha</option>
              {empregadoras.map(e => <option key={e.id} value={e.id}>{e.nome_fantasia || e.razao_social}</option>)}
            </Select>
          </Field>
          <Field label="Partir de um modelo">
            <Select value="" onChange={e => usarModelo(e.target.value)}>
              <option value="">Escolha um modelo (opcional)</option>
              {modelos.map(m => <option key={m.nome} value={m.nome}>{m.nome}</option>)}
            </Select>
          </Field>
          <Field label="Nome"><Input value={r.nome} maxLength={80} onChange={e => setR(p => ({ ...p, nome: e.target.value }))} /></Field>
          <Field label="Tipo">
            <Select value={r.tipo} onChange={e => setR(p => ({ ...p, tipo: e.target.value as TipoCarga }))}>
              {(Object.keys(TIPO_ROTULO) as TipoCarga[]).map(t => <option key={t} value={t}>{TIPO_ROTULO[t]}</option>)}
            </Select>
          </Field>
        </div>
        {r.tipo === '12x36' ? (
          <Field label="Plantão (horas, dia sim, dia não)" hint="O primeiro dia da vigência é dia de plantão.">
            <Input type="time" value={paraHm(r.plantao_min)} onChange={e => setR(p => ({ ...p, plantao_min: deHm(e.target.value) }))} />
          </Field>
        ) : (
          <div>
            <p className="mb-1 text-xs font-medium">Horas de trabalho por dia (00:00 é folga)</p>
            <div className="grid grid-cols-4 gap-2 sm:grid-cols-7">
              {DIAS.map((d, i) => (
                <Field key={d} label={d}>
                  <Input type="time" value={paraHm(r.minutos[i])}
                    onChange={e => setR(p => ({ ...p, minutos: p.minutos.map((m, j) => j === i ? deHm(e.target.value) : m) }))} />
                </Field>
              ))}
            </div>
          </div>
        )}
        <div className="grid gap-3 sm:grid-cols-2">
          <Field label="Intervalo (minutos)">
            <Input type="number" min={0} max={300} value={r.intervalo_min} onChange={e => setR(p => ({ ...p, intervalo_min: Number(e.target.value) }))} />
          </Field>
          {r.tipo !== '12x36' && (
            <Field label="Descanso semanal (DSR)" hint="Trabalho nesse dia paga 100%; nas outras folgas, 50%.">
              <Select value={r.minutos[r.dsr_dia - 1] === 0 ? r.dsr_dia : ''} onChange={e => setR(p => ({ ...p, dsr_dia: Number(e.target.value) }))}>
                <option value="" disabled>Escolha uma folga</option>
                {r.minutos.map((m, i) => m === 0 ? <option key={i} value={i + 1}>{DIA_LONGO[i]}</option> : null)}
              </Select>
            </Field>
          )}
          <Field label="Entrada (opcional)" hint="Para avisar trabalho noturno (22h às 5h).">
            <Input type="time" value={r.entrada} onChange={e => setR(p => ({ ...p, entrada: e.target.value }))} />
          </Field>
        </div>
        {v && <>
          <p className="text-xs">Semana: <strong>{minutosHm(v.semanal_min)}</strong>{r.tipo === '12x36' && ' (média)'}</p>
          <ListaValidacao v={v} />
        </>}
        {temRisco && !bloqueado && (
          <div className="space-y-2 rounded-md border border-amber-300 p-3">
            <p className="text-sm font-semibold">Aceite de risco da empregadora</p>
            <Field label="Acordo ou convenção que ampara (opcional)" hint="Número e vigência. Em branco: não há instrumento.">
              <Input value={instrumento} maxLength={200} onChange={e => setInstrumento(e.target.value)} />
            </Field>
            <label className="flex items-start gap-2 text-xs">
              <input type="checkbox" className="mt-0.5" checked={aceito} onChange={e => setAceito(e.target.checked)} />
              <span>
                <span className="block whitespace-pre-wrap">{v?.termo}</span>
                <span className="mt-1 block font-medium">
                  Quem assina: você, como representante de {empregadoras.find(e => e.id === r.empresa_id)?.razao_social ?? 'a empregadora'}.
                  O funcionário não vê nem assina este termo.
                </span>
                <span className="mt-1 block text-muted-foreground">
                  Fica registrado com o texto acima, meu nome, e-mail e papel, a data e a hora, e não pode ser alterado.
                </span>
              </span>
            </label>
          </div>
        )}
        {erro && <ErrorBox>{erro}</ErrorBox>}
      </div>
    </Modal>
  )
}

// Atribuições -----------------------------------------------------------------------------------------------
function Atribuicoes({ atribuicoes, cargas, times, tecnicos, empregadoras, podeEditar, recarregar }: {
  atribuicoes: CargaAtribuicao[] | null; cargas: CargaHoraria[]; times: TimeEquipe[]; tecnicos: Tecnico[]
  empregadoras: Empresa[]; podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const [nova, setNova] = useState<{ carga: string; alvo: AlvoCarga; alvo_id: string; inicio: string; fim: string } | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [salvando, setSalvando] = useState(false)

  const carga = cargas.find(c => c.id === nova?.carga)
  const opcoesAlvo = !carga || !nova ? [] :
    nova.alvo === 'empresa' ? empregadoras.filter(e => e.id === carga.empresa_id).map(e => ({ id: e.id, nome: e.nome_fantasia || e.razao_social }))
    : nova.alvo === 'time' ? times.filter(t => t.empresa_id === carga.empresa_id && t.ativo).map(t => ({ id: t.id, nome: t.nome }))
    : tecnicos.filter(t => t.empresa_id === carga.empresa_id && t.ativo).map(t => ({ id: t.id, nome: t.nome }))

  const salvar = async () => {
    if (!nova) return
    setErro(null)
    if (!nova.carga || !nova.alvo_id) return setErro('Escolha a escala e a quem ela se aplica.')
    setSalvando(true)
    try { await api.atribuirCarga(nova.carga, nova.alvo, nova.alvo_id, nova.inicio, nova.fim || null); setNova(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) } finally { setSalvando(false) }
  }
  const cancelar = async (a: CargaAtribuicao) => {
    setErro(null)
    try { await api.cancelarAtribuicao(a.id); await recarregar() } catch (e) { setErro(erroMsg(e)) }
  }

  return (
    <section className="space-y-2">
      <div className="flex items-center justify-between">
        <p className="text-xs text-muted-foreground">Vigência padrão de um ano. Uma nova atribuição encerra a anterior do mesmo alvo na véspera.</p>
        {podeEditar && <Button size="sm" onClick={() => { setErro(null); setNova({ carga: '', alvo: 'empresa', alvo_id: '', inicio: amanha(), fim: '' }) }}>
          <Plus className="h-4 w-4" /> Atribuir escala</Button>}
      </div>
      {erro && !nova && <ErrorBox>{erro}</ErrorBox>}
      {!atribuicoes ? <Carregando /> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Aplica-se a</th><th className="px-3 py-2">Escala</th><th className="px-3 py-2">Vigência</th>
              <th className="px-3 py-2">Situação</th><th className="px-3 py-2" />
            </tr></thead>
            <tbody>
              {atribuicoes.length === 0 ? (
                <tr><td colSpan={5} className="py-10 text-center text-muted-foreground">Nenhuma atribuição</td></tr>
              ) : atribuicoes.map(a => (
                <tr key={a.id} className="border-b last:border-0">
                  <td className="px-3 py-2"><p className="font-medium">{a.alvo_nome}</p>
                    <p className="text-xs text-muted-foreground">{ALVO_ROTULO[a.alvo]}{a.alvo !== 'empresa' && ` · ${a.empresa}`}</p></td>
                  <td className="px-3 py-2 text-xs">{a.carga}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-xs">{dataBr(a.inicio)} a {dataBr(a.fim)}</td>
                  <td className="px-3 py-2"><span className={`rounded px-1.5 py-0.5 text-[11px] ${SITUACAO_COR[a.situacao]}`}>{a.situacao}</span></td>
                  <td className="px-3 py-2 text-right">
                    {podeEditar && a.situacao === 'futura' && <Button variant="ghost" size="sm" onClick={() => void cancelar(a)}><X className="h-3.5 w-3.5" /> Cancelar</Button>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Modal open={!!nova} onClose={() => { if (!salvando) setNova(null) }} title="Atribuir escala"
        footer={<>
          <Button variant="outline" onClick={() => setNova(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Atribuir'}</Button>
        </>}>
        {nova && <div className="space-y-3">
          <Field label="Escala">
            <Select value={nova.carga} onChange={e => setNova({ ...nova, carga: e.target.value, alvo_id: '' })}>
              <option value="">Escolha</option>
              {cargas.filter(c => c.ativo).map(c => <option key={c.id} value={c.id}>{c.nome} · {c.empresa}</option>)}
            </Select>
          </Field>
          <div className="grid gap-3 sm:grid-cols-2">
            <Field label="Aplica-se a">
              <Select value={nova.alvo} onChange={e => setNova({ ...nova, alvo: e.target.value as AlvoCarga, alvo_id: '' })}>
                {(Object.keys(ALVO_ROTULO) as AlvoCarga[]).map(a => <option key={a} value={a}>{ALVO_ROTULO[a]}</option>)}
              </Select>
            </Field>
            <Field label={ALVO_ROTULO[nova.alvo]} hint={carga ? `Só da ${carga.empresa}.` : 'Escolha a escala primeiro.'}>
              <Select value={nova.alvo_id} disabled={!carga} onChange={e => setNova({ ...nova, alvo_id: e.target.value })}>
                <option value="">Escolha</option>
                {opcoesAlvo.map(o => <option key={o.id} value={o.id}>{o.nome}</option>)}
              </Select>
            </Field>
            <Field label="Início"><Input type="date" min={hojeBahia()} value={nova.inicio} onChange={e => setNova({ ...nova, inicio: e.target.value })} /></Field>
            <Field label="Fim (opcional)" hint="Em branco: um ano."><Input type="date" min={nova.inicio} value={nova.fim} onChange={e => setNova({ ...nova, fim: e.target.value })} /></Field>
          </div>
          {erro && <ErrorBox>{erro}</ErrorBox>}
        </div>}
      </Modal>
    </section>
  )
}

// Por funcionário -------------------------------------------------------------------------------------------
function PorFuncionario({ empresa }: { empresa: string }) {
  const [data, setData] = useState(hojeBahia())
  const [lista, setLista] = useState<CargaFuncionario[] | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  useEffect(() => {
    setLista(null)
    api.cargasFuncionarios(empresa || null, data).then(setLista).catch(e => { setErro(erroMsg(e)); setLista([]) })
  }, [empresa, data])
  return (
    <section className="space-y-2">
      <Field label="Escala que vale em"><Input type="date" value={data} onChange={e => setData(e.target.value)} /></Field>
      {erro && <ErrorBox>{erro}</ErrorBox>}
      {!lista ? <Carregando /> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Funcionário</th><th className="px-3 py-2">Time</th><th className="px-3 py-2">Escala</th>
              <th className="px-3 py-2">Vem de</th><th className="px-3 py-2">Semana</th>
            </tr></thead>
            <tbody>
              {lista.length === 0 ? (
                <tr><td colSpan={5} className="py-10 text-center text-muted-foreground">Nenhum funcionário ativo</td></tr>
              ) : lista.map(f => (
                <tr key={f.tecnico_id} className="border-b last:border-0">
                  <td className="px-3 py-2"><p className="font-medium">{f.tecnico}</p><p className="text-xs text-muted-foreground">{f.empresa ?? 'sem empresa'}</p></td>
                  <td className="px-3 py-2 text-xs">{f.time_nome ?? '—'}</td>
                  <td className="px-3 py-2 text-xs">{f.carga}</td>
                  <td className="px-3 py-2 text-xs">{f.origem}</td>
                  <td className="px-3 py-2 text-xs">{minutosHm(f.semanal_min)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

// Times -------------------------------------------------------------------------------------------------------
function Times({ times, tecnicos, empregadoras, empresa, podeEditar, recarregar }: {
  times: TimeEquipe[] | null; tecnicos: Tecnico[]; empregadoras: Empresa[]; empresa: string; podeEditar: boolean; recarregar: () => Promise<void>
}) {
  const [edit, setEdit] = useState<{ id: string | null; empresa_id: string; nome: string; ativo: boolean } | null>(null)
  const [membros, setMembros] = useState<{ time: TimeEquipe; ids: Set<string> } | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [salvando, setSalvando] = useState(false)

  const salvar = async () => {
    if (!edit) return
    setErro(null); setSalvando(true)
    try { await api.salvarTime(edit.id, edit.empresa_id || null, edit.nome, edit.ativo); setEdit(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) } finally { setSalvando(false) }
  }
  const abrirMembros = (t: TimeEquipe) => {
    setErro(null)
    setMembros({ time: t, ids: new Set(tecnicos.filter(x => x.equipe && x.empresa_id === t.empresa_id && x.equipe.trim().toLowerCase() === t.nome.trim().toLowerCase()).map(x => x.id)) })
  }
  const salvarMembros = async () => {
    if (!membros) return
    setErro(null); setSalvando(true)
    try { await api.timeDefinirMembros(membros.time.id, [...membros.ids]); setMembros(null); await recarregar() }
    catch (e) { setErro(erroMsg(e)) } finally { setSalvando(false) }
  }

  return (
    <section className="space-y-2">
      <div className="flex items-center justify-between">
        <p className="text-xs text-muted-foreground">O time é o campo Equipe do funcionário. Escala atribuída ao time vale para todos os membros.</p>
        {podeEditar && <Button size="sm" onClick={() => { setErro(null); setEdit({ id: null, empresa_id: empresa || (empregadoras.length === 1 ? empregadoras[0].id : ''), nome: '', ativo: true }) }}>
          <Plus className="h-4 w-4" /> Novo time</Button>}
      </div>
      {erro && !edit && !membros && <ErrorBox>{erro}</ErrorBox>}
      {!times ? <Carregando /> : (
        <div className="overflow-x-auto rounded-md border">
          <table className="w-full text-sm">
            <thead><tr className="border-b bg-muted/50 text-left text-xs text-muted-foreground">
              <th className="px-3 py-2">Time</th><th className="px-3 py-2">Empresa</th><th className="px-3 py-2">Membros</th><th className="px-3 py-2" />
            </tr></thead>
            <tbody>
              {times.length === 0 ? (
                <tr><td colSpan={4} className="py-10 text-center text-muted-foreground">Nenhum time</td></tr>
              ) : times.map(t => (
                <tr key={t.id} className={`border-b last:border-0 ${!t.ativo ? 'opacity-50' : ''}`}>
                  <td className="px-3 py-2 font-medium">{t.nome}{!t.ativo && <span className="text-xs text-muted-foreground"> · inativo</span>}</td>
                  <td className="px-3 py-2 text-xs">{t.empresa}</td>
                  <td className="px-3 py-2 text-xs">{t.membros}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-right">
                    {podeEditar && <>
                      {t.ativo && <Button variant="ghost" size="sm" onClick={() => abrirMembros(t)}><Users className="h-3.5 w-3.5" /> Membros</Button>}
                      <Button variant="ghost" size="icon" aria-label="Editar" onClick={() => { setErro(null); setEdit({ id: t.id, empresa_id: t.empresa_id, nome: t.nome, ativo: t.ativo }) }}>
                        <Edit2 className="h-3.5 w-3.5" /></Button>
                    </>}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Modal open={!!edit} onClose={() => { if (!salvando) setEdit(null) }} title={edit?.id ? 'Editar time' : 'Novo time'}
        footer={<>
          <Button variant="outline" onClick={() => setEdit(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvar()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {edit && <div className="space-y-3">
          <Field label="Empresa">
            <Select value={edit.empresa_id} disabled={!!edit.id} onChange={e => setEdit({ ...edit, empresa_id: e.target.value })}>
              <option value="">Escolha</option>
              {empregadoras.map(e => <option key={e.id} value={e.id}>{e.nome_fantasia || e.razao_social}</option>)}
            </Select>
          </Field>
          <Field label="Nome" hint={edit.id ? 'Renomear muda o campo Equipe dos membros.' : undefined}>
            <Input value={edit.nome} maxLength={60} onChange={e => setEdit({ ...edit, nome: e.target.value })} />
          </Field>
          {edit.id && <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" checked={edit.ativo} onChange={e => setEdit({ ...edit, ativo: e.target.checked })} /> Ativo
          </label>}
          {erro && <ErrorBox>{erro}</ErrorBox>}
        </div>}
      </Modal>
      <Modal open={!!membros} onClose={() => { if (!salvando) setMembros(null) }} title={`Membros do time ${membros?.time.nome ?? ''}`}
        footer={<>
          <Button variant="outline" onClick={() => setMembros(null)} disabled={salvando}>Cancelar</Button>
          <Button onClick={() => void salvarMembros()} disabled={salvando}>{salvando ? 'Salvando...' : 'Salvar'}</Button>
        </>}>
        {membros && <div className="space-y-2">
          <p className="text-xs text-muted-foreground">Funcionários ativos da {membros.time.empresa}. Quem está em outro time muda para este.</p>
          <div className="max-h-80 space-y-1 overflow-y-auto">
            {tecnicos.filter(t => t.empresa_id === membros.time.empresa_id && t.ativo).map(t => (
              <label key={t.id} className="flex items-center gap-2 text-sm">
                <input type="checkbox" checked={membros.ids.has(t.id)} onChange={e => {
                  const ids = new Set(membros.ids); if (e.target.checked) ids.add(t.id); else ids.delete(t.id); setMembros({ ...membros, ids })
                }} />
                {t.nome}{t.equipe && !membros.ids.has(t.id) && <span className="text-xs text-muted-foreground">· {t.equipe}</span>}
              </label>
            ))}
          </div>
          {erro && <ErrorBox>{erro}</ErrorBox>}
        </div>}
      </Modal>
    </section>
  )
}
