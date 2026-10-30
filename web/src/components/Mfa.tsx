import { useEffect, useState } from 'react'
import { KeyRound, Loader2, LogOut, Mail, MessageCircle, ShieldCheck } from 'lucide-react'
import { Button, ErrorBox, Input } from './ui'
import { supabase } from '../lib/supabase'
import { erroMsg, recuperarDuasEtapas } from '../lib/api'

// Verificação em duas etapas (MFA, backlog 037, decisão 67): código de 6 dígitos de um aplicativo
// autenticador (Google Authenticator, Microsoft Authenticator, 1Password...). O fator é do Supabase Auth;
// o banco só exige a sessão confirmada (aal2) quando config.mfa_obrigatorio = 'true'.

export type EstadoMfa = 'ok' | 'verificar' | 'cadastrar'

// Decide a tela: código pendente nesta sessão, cadastro obrigatório ainda não feito, ou liberado
export async function estadoMfa(obrigatorio: boolean): Promise<{ estado: EstadoMfa; temFator: boolean }> {
  const [{ data: nivel }, { data: fatores }] = await Promise.all([
    supabase.auth.mfa.getAuthenticatorAssuranceLevel(), supabase.auth.mfa.listFactors()])
  const temFator = (fatores?.totp ?? []).length > 0
  if (nivel?.nextLevel === 'aal2' && nivel.currentLevel !== 'aal2') return { estado: 'verificar', temFator }
  if (obrigatorio && !temFator) return { estado: 'cadastrar', temFator }
  return { estado: 'ok', temFator }
}

function Codigo({ valor, onChange, onEnter }: { valor: string; onChange: (v: string) => void; onEnter: () => void }) {
  return (
    <Input inputMode="numeric" autoComplete="one-time-code" autoFocus maxLength={6} placeholder="000000"
      value={valor} onChange={e => onChange(e.target.value.replace(/\D/g, '').slice(0, 6))}
      onKeyDown={e => { if (e.key === 'Enter' && valor.length === 6) onEnter() }}
      className="text-center font-mono text-lg tracking-[0.4em]" />
  )
}

const sair = () => { void supabase.auth.signOut({ scope: 'local' }) }

// "Perdi meu autenticador" (migration 140, decisão 128): código por e-mail ou WhatsApp; administrador da plataforma
// precisa dos dois. Com o código certo, o autenticador antigo sai e o painel pede o novo.
function MfaRecuperar({ onOk, onVoltar }: { onOk: () => void; onVoltar: () => void }) {
  const [cEmail, setCEmail] = useState('')
  const [cWhats, setCWhats] = useState('')
  const [enviados, setEnviados] = useState<{ email?: string; whatsapp?: string }>({})
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const pedir = async (canal: 'email' | 'whatsapp') => {
    setOcupado(true); setErro(null)
    const r = await recuperarDuasEtapas({ acao: 'pedir', canal })
    if (r.ok) setEnviados(p => ({ ...p, [canal]: r.destino ?? 'enviado' })); else setErro(r.erro ?? 'Não foi possível enviar.')
    setOcupado(false)
  }
  const confirmar = async () => {
    setOcupado(true); setErro(null)
    const r = await recuperarDuasEtapas({ acao: 'confirmar', codigo_email: cEmail, codigo_whatsapp: cWhats })
    if (!r.ok) { setErro(r.erro ?? 'Código errado ou vencido.'); setOcupado(false); return }
    await supabase.auth.refreshSession()
    setOcupado(false)
    onOk()
  }
  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        Receba um código para trocar o aplicativo autenticador. Quem é administrador da plataforma precisa dos dois códigos.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button variant="outline" disabled={ocupado} onClick={() => void pedir('email')}><Mail className="h-4 w-4" /> Por e-mail</Button>
        <Button variant="outline" disabled={ocupado} onClick={() => void pedir('whatsapp')}><MessageCircle className="h-4 w-4" /> Por WhatsApp</Button>
      </div>
      {enviados.email && (<div className="space-y-1"><p className="text-xs text-muted-foreground">Código do e-mail (enviado para {enviados.email}):</p>
        <Codigo valor={cEmail} onChange={setCEmail} onEnter={() => void confirmar()} /></div>)}
      {enviados.whatsapp && (<div className="space-y-1"><p className="text-xs text-muted-foreground">Código do WhatsApp (enviado para {enviados.whatsapp}):</p>
        <Codigo valor={cWhats} onChange={setCWhats} onEnter={() => void confirmar()} /></div>)}
      {erro && <ErrorBox>{erro}</ErrorBox>}
      <div className="flex gap-2">
        <Button className="flex-1" disabled={ocupado || (cEmail.length !== 6 && cWhats.length !== 6)} onClick={() => void confirmar()}>
          {ocupado && <Loader2 className="h-4 w-4 animate-spin" />} Trocar o autenticador
        </Button>
        <Button variant="outline" onClick={onVoltar} disabled={ocupado}>Voltar</Button>
      </div>
    </div>
  )
}

export function MfaVerificar({ onOk }: { onOk: () => void }) {
  const [recuperando, setRecuperando] = useState(false)
  const [codigo, setCodigo] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const verificar = async () => {
    setOcupado(true); setErro(null)
    try {
      const { data } = await supabase.auth.mfa.listFactors()
      const fator = data?.totp[0]
      if (!fator) throw new Error('Nenhum aplicativo autenticador cadastrado.')
      const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo })
      if (error) throw new Error('Código inválido ou vencido. Confira o relógio do celular e tente o código novo.')
      onOk()
    } catch (e) { setErro(erroMsg(e)); setCodigo('') } finally { setOcupado(false) }
  }
  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-sm space-y-4 rounded-lg border bg-card p-6">
        <p className="flex items-center gap-2 font-semibold"><KeyRound className="h-5 w-5 text-primary" /> Verificação em duas etapas</p>
        {recuperando ? <MfaRecuperar onOk={onOk} onVoltar={() => setRecuperando(false)} /> : (<>
        <p className="text-sm text-muted-foreground">Digite o código de 6 dígitos do aplicativo autenticador.</p>
        <Codigo valor={codigo} onChange={setCodigo} onEnter={() => void verificar()} />
        {erro && <ErrorBox>{erro}</ErrorBox>}
        <div className="flex gap-2">
          <Button className="flex-1" disabled={codigo.length !== 6 || ocupado} onClick={() => void verificar()}>
            {ocupado && <Loader2 className="h-4 w-4 animate-spin" />} Confirmar
          </Button>
          <Button variant="outline" onClick={sair}><LogOut className="h-4 w-4" /> Sair</Button>
        </div>
        <button type="button" className="text-xs text-primary underline" onClick={() => setRecuperando(true)}>Perdi meu autenticador</button>
        </>)}
      </div>
    </div>
  )
}

// Desliga a verificação do próprio usuário (opcional por pessoa enquanto mfa_obrigatorio = 'false', decisão 68).
// Pede um código atual antes de remover: sessão aberta e esquecida não basta para tirar a segunda etapa.
export function MfaDesativar({ onOk, onCancelar }: { onOk: () => void; onCancelar: () => void }) {
  const [codigo, setCodigo] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)
  const desativar = async () => {
    setOcupado(true); setErro(null)
    try {
      const { data, error: eLista } = await supabase.auth.mfa.listFactors()
      if (eLista) throw eLista
      const fator = data?.totp[0]
      if (!fator) throw new Error('Nenhum aplicativo autenticador cadastrado.')
      const { error: eCodigo } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo })
      if (eCodigo) throw new Error('Código inválido ou vencido. Confira o relógio do celular e tente o código novo.')
      for (const f of data?.all ?? []) {
        const { error } = await supabase.auth.mfa.unenroll({ factorId: f.id })
        if (error) throw error
      }
      const { error: eSessao } = await supabase.auth.refreshSession()
      if (eSessao) throw eSessao
      onOk()
    } catch (e) { setErro(erroMsg(e)); setCodigo('') } finally { setOcupado(false) }
  }
  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-sm space-y-4 rounded-lg border bg-card p-6">
        <p className="flex items-center gap-2 font-semibold"><ShieldCheck className="h-5 w-5 text-green-700" /> Desativar duas etapas</p>
        <p className="text-sm text-muted-foreground">O login volta a pedir só a senha. Para confirmar, digite o código atual do aplicativo autenticador.</p>
        <Codigo valor={codigo} onChange={setCodigo} onEnter={() => void desativar()} />
        {erro && <ErrorBox>{erro}</ErrorBox>}
        <div className="flex gap-2">
          <Button variant="destructive" className="flex-1" disabled={codigo.length !== 6 || ocupado} onClick={() => void desativar()}>
            {ocupado && <Loader2 className="h-4 w-4 animate-spin" />} Desativar
          </Button>
          <Button variant="outline" onClick={onCancelar}>Manter ativa</Button>
        </div>
      </div>
    </div>
  )
}

export function MfaCadastrar({ obrigatorio, onOk, onCancelar }: { obrigatorio: boolean; onOk: () => void; onCancelar?: () => void }) {
  const [fator, setFator] = useState<{ id: string; qr: string; segredo: string } | null>(null)
  const [codigo, setCodigo] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [ocupado, setOcupado] = useState(false)

  useEffect(() => {
    let cancelado = false
    const iniciar = async () => {
      try {
        // cadastro anterior que não foi confirmado: descarta antes de gerar um novo QR
        const { data: lista } = await supabase.auth.mfa.listFactors()
        for (const f of lista?.all ?? []) {
          if (f.status !== 'verified') await supabase.auth.mfa.unenroll({ factorId: f.id })
        }
        const { data, error } = await supabase.auth.mfa.enroll({ factorType: 'totp', friendlyName: `Trilha ${new Date().toISOString().slice(0, 10)}` })
        if (error) throw error
        if (!cancelado) setFator({ id: data.id, qr: data.totp.qr_code, segredo: data.totp.secret })
      } catch (e) { if (!cancelado) setErro(erroMsg(e)) }
    }
    void iniciar()
    return () => { cancelado = true }
  }, [])

  const confirmar = async () => {
    if (!fator) return
    setOcupado(true); setErro(null)
    try {
      const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo })
      if (error) throw new Error('Código inválido. Confira se escaneou o QR deste cadastro e tente o código novo.')
      onOk()
    } catch (e) { setErro(erroMsg(e)); setCodigo('') } finally { setOcupado(false) }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-md space-y-4 rounded-lg border bg-card p-6">
        <p className="flex items-center gap-2 font-semibold"><ShieldCheck className="h-5 w-5 text-green-700" /> Ativar verificação em duas etapas</p>
        <p className="text-sm text-muted-foreground">
          {obrigatorio ? 'O painel exige um código do celular além da senha. ' : ''}
          1. Abra um aplicativo autenticador (Google Authenticator, Microsoft Authenticator ou outro).
          2. Escaneie o QR abaixo. 3. Digite o código de 6 dígitos que aparecer.
        </p>
        {!fator && !erro && <div className="flex justify-center py-8"><Loader2 className="h-5 w-5 animate-spin" /></div>}
        {fator && (
          <>
            <img src={fator.qr} alt="QR do aplicativo autenticador" className="mx-auto h-48 w-48 rounded border bg-white p-2" />
            <p className="break-all text-center font-mono text-xs text-muted-foreground">Sem câmera? Digite no aplicativo: {fator.segredo}</p>
            <Codigo valor={codigo} onChange={setCodigo} onEnter={() => void confirmar()} />
          </>
        )}
        {erro && <ErrorBox>{erro}</ErrorBox>}
        <div className="flex gap-2">
          <Button className="flex-1" disabled={!fator || codigo.length !== 6 || ocupado} onClick={() => void confirmar()}>
            {ocupado && <Loader2 className="h-4 w-4 animate-spin" />} Ativar
          </Button>
          {onCancelar && !obrigatorio
            ? <Button variant="outline" onClick={onCancelar}>Agora não</Button>
            : <Button variant="outline" onClick={sair}><LogOut className="h-4 w-4" /> Sair</Button>}
        </div>
      </div>
    </div>
  )
}
