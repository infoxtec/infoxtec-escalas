import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Award, CalendarDays, LayoutGrid, Loader2, LogOut, MapPin, ShieldCheck, Users } from 'lucide-react'
import { Button, ErrorBox } from './components/ui'
import { configurado, supabase, tipoDoLink } from './lib/supabase'
import { api, erroMsg } from './lib/api'
import { PAPEL_LABEL } from './lib/types'
import type { Acesso, Local, Tecnico, TipoAtividade } from './lib/types'
import { DefinirSenha, Login } from './pages/Login'
import AgendaPage from './pages/AgendaPage'
import TecnicosPage from './pages/TecnicosPage'
import LocaisPage from './pages/LocaisPage'
import UsuariosPage from './pages/UsuariosPage'
import OperacaoPage from './pages/OperacaoPage'
import HabilidadesPage from './pages/HabilidadesPage'

type Aba = 'agenda' | 'operacao' | 'tecnicos' | 'locais' | 'habilidades' | 'usuarios'

function Centro({ children }: { children: ReactNode }) {
  return <div className="flex min-h-screen items-center justify-center p-6 text-sm text-muted-foreground">{children}</div>
}

export default function App() {
  const [sessao, setSessao] = useState<Session | null | undefined>(undefined)
  const [definirSenha, setDefinirSenha] = useState<'invite' | 'recovery' | null>(tipoDoLink)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSessao(data.session))
    const { data } = supabase.auth.onAuthStateChange((evento, s) => {
      setSessao(s)
      if (evento === 'PASSWORD_RECOVERY') setDefinirSenha('recovery')
    })
    return () => data.subscription.unsubscribe()
  }, [])

  if (!configurado) return <Centro>Configuração ausente: defina VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY no Vercel.</Centro>
  if (sessao === undefined) return <Centro><Loader2 className="h-5 w-5 animate-spin" /></Centro>
  if (!sessao) return <Login />
  if (definirSenha) return <DefinirSenha convite={definirSenha === 'invite'} onPronto={() => setDefinirSenha(null)} />
  return <Painel email={sessao.user.email ?? ''} />
}

function Painel({ email }: { email: string }) {
  const [acesso, setAcesso] = useState<Acesso | null>(null)
  const [erro, setErro] = useState<string | null>(null)
  const [aba, setAba] = useState<Aba>('agenda')
  const [tecnicos, setTecnicos] = useState<Tecnico[]>([])
  const [locais, setLocais] = useState<Local[]>([])
  const [tipos, setTipos] = useState<TipoAtividade[]>([])

  const sair = () => { void supabase.auth.signOut() }

  const recarregarCadastros = useCallback(async () => {
    try {
      const [t, l, ta] = await Promise.all([api.tecnicos(), api.locais(), api.tiposAtividade()])
      setTecnicos(t); setLocais(l); setTipos(ta)
    } catch (e) { setErro(erroMsg(e)) }
  }, [])

  useEffect(() => {
    api.meuAcesso()
      .then(a => { setAcesso(a); if (a.papel) void recarregarCadastros() })
      .catch(e => setErro(erroMsg(e)))
  }, [recarregarCadastros])

  if (erro && !acesso) return <Centro><div className="max-w-md space-y-3"><ErrorBox>{erro}</ErrorBox><Button variant="outline" onClick={sair}>Sair</Button></div></Centro>
  if (!acesso) return <Centro><Loader2 className="h-5 w-5 animate-spin" /></Centro>
  if (!acesso.papel) {
    return (
      <Centro>
        <div className="max-w-md space-y-4 rounded-lg border bg-card p-6 text-center">
          <ShieldCheck className="mx-auto h-8 w-8 text-muted-foreground" />
          <p className="text-base font-semibold text-foreground">Acesso não autorizado</p>
          <p>Seu usuário (<strong className="text-foreground">{email}</strong>) ainda não tem acesso ao painel de escalas. Peça a um administrador para liberar seu acesso.</p>
          <Button variant="outline" onClick={sair}><LogOut className="h-4 w-4" /> Sair</Button>
        </div>
      </Centro>
    )
  }

  const papel = acesso.papel
  const podeEditar = papel === 'admin' || papel === 'gestor'
  const abas: { id: Aba; label: string; icone: ReactNode }[] = [
    { id: 'agenda', label: 'Agenda', icone: <CalendarDays className="h-4 w-4" /> },
    { id: 'operacao', label: 'Operação', icone: <LayoutGrid className="h-4 w-4" /> },
    { id: 'tecnicos', label: 'Técnicos', icone: <Users className="h-4 w-4" /> },
    { id: 'locais', label: 'Locais', icone: <MapPin className="h-4 w-4" /> },
    { id: 'habilidades', label: 'Habilidades', icone: <Award className="h-4 w-4" /> },
    ...(papel === 'admin' ? [{ id: 'usuarios' as Aba, label: 'Usuários', icone: <ShieldCheck className="h-4 w-4" /> }] : []),
  ]

  return (
    <div className="flex min-h-screen flex-col">
      <header className="sticky top-0 z-40 border-b bg-card/90 backdrop-blur">
        <div className="mx-auto flex h-12 max-w-screen-2xl items-center gap-3 px-4">
          <div className="flex shrink-0 items-center gap-2">
            <CalendarDays className="h-5 w-5 text-primary" />
            <span className="hidden text-sm font-semibold sm:inline">Infoxtec Escalas</span>
            <span className="rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground" title={`Build de ${__APP_BUILD__}`}>
              v{__APP_VERSION__} · {__APP_BUILD__}
            </span>
          </div>
          <div className="h-5 w-px bg-border" />
          <nav className="flex gap-1 overflow-x-auto">
            {abas.map(a => (
              <button key={a.id} onClick={() => setAba(a.id)}
                className={`flex items-center gap-1.5 whitespace-nowrap rounded-md px-3 py-1.5 text-sm font-medium transition-colors ${aba === a.id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground hover:bg-muted hover:text-foreground'}`}>
                {a.icone}<span className="hidden md:inline">{a.label}</span>
              </button>
            ))}
          </nav>
          <div className="flex-1" />
          <div className="hidden text-right leading-tight sm:block">
            <p className="text-xs font-medium">{acesso.nome ?? email}</p>
            <p className="text-[11px] text-muted-foreground">{PAPEL_LABEL[papel]}</p>
          </div>
          <Button variant="ghost" size="icon" onClick={sair} aria-label="Sair" title="Sair"><LogOut className="h-4 w-4" /></Button>
        </div>
      </header>
      <main className="mx-auto w-full max-w-screen-2xl flex-1 px-4 py-5">
        {erro && <div className="mb-4"><ErrorBox>{erro}</ErrorBox></div>}
        {aba === 'agenda' && <AgendaPage tecnicos={tecnicos} locais={locais} tipos={tipos} podeEditar={podeEditar} />}
        {aba === 'operacao' && <OperacaoPage />}
        {aba === 'habilidades' && <HabilidadesPage tecnicos={tecnicos} podeEditar={podeEditar} />}
        {aba === 'tecnicos' && <TecnicosPage tecnicos={tecnicos} recarregar={recarregarCadastros} podeEditar={podeEditar} podeExcluir={papel === 'admin'} />}
        {aba === 'locais' && <LocaisPage locais={locais} recarregar={recarregarCadastros} podeEditar={podeEditar} />}
        {aba === 'usuarios' && papel === 'admin' && <UsuariosPage />}
      </main>
    </div>
  )
}
