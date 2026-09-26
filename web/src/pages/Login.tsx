import { useState } from 'react'
import type { FormEvent } from 'react'
import { Button, ErrorBox, Field, Input, SuccessBox } from '../components/ui'
import { supabase } from '../lib/supabase'

function Moldura({ titulo, children }: { titulo: string; children: React.ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 p-4">
      <div className="w-full max-w-sm overflow-hidden rounded-lg border bg-card shadow-sm">
        <div className="flex justify-center bg-[#0d1e3c] px-6 py-5">
          <img src="/logo-infoxtec.png" alt="Infoxtec" className="h-12 w-auto" />
        </div>
        <div className="p-6">
          <div className="mb-5">
            <p className="text-sm font-semibold">Escalas</p>
            <p className="text-xs text-muted-foreground">{titulo}</p>
          </div>
          {children}
        </div>
      </div>
    </div>
  )
}

export function Login() {
  const [avisoInatividade] = useState(() => {
    const houve = sessionStorage.getItem('motivoSaida') === 'inatividade'
    sessionStorage.removeItem('motivoSaida')
    return houve
  })
  const [email, setEmail] = useState('')
  const [senha, setSenha] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [modo, setModo] = useState<'entrar' | 'esqueci'>('entrar')

  const entrar = async (e: FormEvent) => {
    e.preventDefault()
    setErro(null); setBusy(true)
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password: senha })
    setBusy(false)
    if (error) setErro(/invalid login/i.test(error.message) ? 'E-mail ou senha incorretos.' : error.message)
  }

  const recuperar = async (e: FormEvent) => {
    e.preventDefault()
    setErro(null); setBusy(true)
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: window.location.origin })
    setBusy(false)
    if (error) setErro(error.message)
    else setAviso('Se o e-mail estiver cadastrado, você vai receber um link para criar uma nova senha.')
  }

  if (modo === 'esqueci') {
    return (
      <Moldura titulo="Recuperar senha">
        <form onSubmit={recuperar} className="space-y-3">
          <Field label="E-mail"><Input type="email" required value={email} onChange={e => setEmail(e.target.value)} autoFocus /></Field>
          {erro && <ErrorBox>{erro}</ErrorBox>}
          {aviso && <SuccessBox>{aviso}</SuccessBox>}
          <Button type="submit" className="w-full" disabled={busy}>{busy ? 'Enviando...' : 'Enviar link'}</Button>
          <button type="button" className="w-full text-xs text-primary" onClick={() => { setModo('entrar'); setErro(null); setAviso(null) }}>Voltar para o login</button>
        </form>
      </Moldura>
    )
  }

  return (
    <Moldura titulo="Entre com seu e-mail e senha">
      <form onSubmit={entrar} className="space-y-3">
        {avisoInatividade && (
          <p className="rounded-md bg-amber-50 p-2.5 text-xs text-amber-800 dark:bg-amber-900/20 dark:text-amber-300">
            Sua sessão foi encerrada após 30 minutos sem atividade. Entre novamente.
          </p>
        )}
        <Field label="E-mail"><Input type="email" required autoComplete="email" value={email} onChange={e => setEmail(e.target.value)} autoFocus /></Field>
        <Field label="Senha"><Input type="password" required autoComplete="current-password" value={senha} onChange={e => setSenha(e.target.value)} /></Field>
        {erro && <ErrorBox>{erro}</ErrorBox>}
        <Button type="submit" className="w-full" disabled={busy}>{busy ? 'Entrando...' : 'Entrar'}</Button>
        <button type="button" className="w-full text-xs text-primary" onClick={() => { setModo('esqueci'); setErro(null) }}>Esqueci minha senha</button>
      </form>
    </Moldura>
  )
}

export function DefinirSenha({ convite, onPronto }: { convite: boolean; onPronto: () => void }) {
  const [senha, setSenha] = useState('')
  const [confirma, setConfirma] = useState('')
  const [erro, setErro] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const salvar = async (e: FormEvent) => {
    e.preventDefault()
    setErro(null)
    if (senha.length < 8) return setErro('A senha precisa ter pelo menos 8 caracteres.')
    if (senha !== confirma) return setErro('As senhas não conferem.')
    setBusy(true)
    const { error } = await supabase.auth.updateUser({ password: senha })
    setBusy(false)
    if (error) setErro(error.message)
    else { window.history.replaceState(null, '', window.location.pathname); onPronto() }
  }

  return (
    <Moldura titulo={convite ? 'Bem-vindo! Crie sua senha' : 'Crie uma nova senha'}>
      <form onSubmit={salvar} className="space-y-3">
        <Field label="Nova senha" hint="Mínimo de 8 caracteres."><Input type="password" autoComplete="new-password" value={senha} onChange={e => setSenha(e.target.value)} autoFocus /></Field>
        <Field label="Repita a senha"><Input type="password" autoComplete="new-password" value={confirma} onChange={e => setConfirma(e.target.value)} /></Field>
        {erro && <ErrorBox>{erro}</ErrorBox>}
        <Button type="submit" className="w-full" disabled={busy}>{busy ? 'Salvando...' : 'Salvar senha'}</Button>
      </form>
    </Moldura>
  )
}
