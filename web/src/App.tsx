import { useCallback, useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { ArrowLeft, Award, Building2, CalendarDays, LayoutGrid, Settings, Loader2, LogOut, MapPin, Rocket, ShieldCheck, Users } from 'lucide-react'
import type { LucideIcon } from 'lucide-react'
import { Button, ErrorBox } from './components/ui'
import { configurado, supabase, tipoDoLink } from './lib/supabase'

// Definido só nos modos locais (npm run dev:homologacao / dev:producao); vazio no painel publicado
const AMBIENTE_LOCAL = import.meta.env.VITE_AMBIENTE as 'homologacao' | 'producao' | undefined
import { MINUTOS_INATIVIDADE, registrarAtividade, useInatividade, useVersaoPublicada } from './lib/sessao'
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
import RoadmapPage from './pages/RoadmapPage'
import AdminPage from './pages/AdminPage'
import EmpresasPage from './pages/EmpresasPage'

type Aba = 'inicio' | 'empresas' | 'agenda' | 'operacao' | 'tecnicos' | 'locais' | 'habilidades' | 'usuarios' | 'roadmap' | 'admin'

// Check verde da marca, que vem logo depois do nome (docs/marca.md)
function CheckVerde() {
  return (
    <svg viewBox="0 0 40 40" className="h-3.5 w-3.5" aria-hidden="true">
      <circle cx="20" cy="20" r="18" fill="#22c55e" />
      <path d="M11.5 20.5l6 6l11-12" fill="none" stroke="#fff" strokeWidth="4.2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function Centro({ children }: { children: ReactNode }) {
  return <div className="flex min-h-screen items-center justify-center p-6 text-sm text-muted-foreground">{children}</div>
}

export default function App() {
  const [sessao, setSessao] = useState<Session | null | undefined>(undefined)
  const [definirSenha, setDefinirSenha] = useState<'invite' | 'recovery' | null>(tipoDoLink)

  // Publicacao nova: recarrega o navegador que estiver aberto
  useVersaoPublicada(__APP_BUILD__)

  // 30 minutos parado: encerra a sessao
  useInatividade(() => {
    if (!sessao) return
    sessionStorage.setItem('motivoSaida', 'inatividade')
    // local: encerra so neste navegador; 'global' derrubaria tambem o celular e outros computadores
    void supabase.auth.signOut({ scope: 'local' })
  })

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => setSessao(data.session))
    const { data } = supabase.auth.onAuthStateChange((evento, s) => {
      if (evento === 'SIGNED_IN') registrarAtividade()
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
  const [aba, setAba] = useState<Aba>('inicio')
  const [tecnicos, setTecnicos] = useState<Tecnico[]>([])
  const [locais, setLocais] = useState<Local[]>([])
  const [tipos, setTipos] = useState<TipoAtividade[]>([])

  // local: sai só deste navegador, sem derrubar o painel aberto no celular ou em outro computador
  const sair = () => { void supabase.auth.signOut({ scope: 'local' }) }

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
  const abas: { id: Aba; label: string; Icone: LucideIcon }[] = [
    { id: 'agenda', label: 'Agenda', Icone: CalendarDays },
    { id: 'operacao', label: 'Operação', Icone: LayoutGrid },
    { id: 'tecnicos', label: 'Técnicos', Icone: Users },
    { id: 'locais', label: 'Locais', Icone: MapPin },
    { id: 'habilidades', label: 'Habilidades', Icone: Award },
    { id: 'empresas', label: 'Empresas', Icone: Building2 },
    ...(papel === 'admin' ? [
      { id: 'usuarios' as Aba, label: 'Usuários', Icone: ShieldCheck },
      { id: 'roadmap' as Aba, label: 'Roadmap', Icone: Rocket },
      { id: 'admin' as Aba, label: 'Checklist Sistema', Icone: Settings },
    ] : []),
  ]

  return (
    <div className="flex min-h-screen flex-col">
      {AMBIENTE_LOCAL && (
        <div className={`px-4 py-1 text-center text-xs font-semibold text-white ${AMBIENTE_LOCAL === 'producao' ? 'bg-red-600' : 'bg-amber-600'}`}>
          {AMBIENTE_LOCAL === 'producao'
            ? 'PRODUÇÃO — dados reais: escalas criadas aqui são enviadas aos técnicos pelo WhatsApp'
            : 'HOMOLOGAÇÃO — dados fictícios, sem WhatsApp nem ligações'}
        </div>
      )}
      <header className="sticky top-0 z-40 border-b bg-card/90 backdrop-blur">
        <div className="mx-auto flex h-12 max-w-screen-2xl items-center gap-3 px-4">
          <button onClick={() => setAba('inicio')} title="Tela principal" className="flex shrink-0 items-center gap-2">
            <img src="/trilha-icone.svg" alt="" className="h-6 w-6" />
            <div className="hidden leading-tight sm:block">
              <p className="flex items-center gap-1 text-sm"><span className="font-[Montserrat] font-bold text-[#2563eb]">Trilha</span><CheckVerde /> <span className="font-medium text-muted-foreground">Escala</span></p>
              <p className="text-[10px] text-muted-foreground">Cada passo conta.</p>
            </div>
            <span className="rounded bg-muted px-1.5 py-0.5 text-[10px] text-muted-foreground" title={`Build de ${__APP_BUILD__}`}>
              v{__APP_VERSION__} · {__APP_BUILD__}
            </span>
          </button>
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
        {aba === 'inicio' && (
          <div className="mx-auto grid max-w-4xl grid-cols-2 gap-4 py-4 sm:grid-cols-3 lg:grid-cols-4">
            {abas.map(a => (
              <button key={a.id} onClick={() => setAba(a.id)}
                className="flex aspect-square flex-col items-center justify-center gap-3 rounded-xl border bg-card p-4 text-center shadow-sm transition-colors hover:border-primary hover:bg-primary/5">
                <a.Icone className="h-12 w-12 text-primary" strokeWidth={1.75} />
                <span className="text-base font-semibold">{a.label}</span>
              </button>
            ))}
          </div>
        )}
        {aba !== 'inicio' && (
          <Button variant="outline" size="sm" className="mb-4" onClick={() => setAba('inicio')}>
            <ArrowLeft className="h-4 w-4" /> Tela principal
          </Button>
        )}
        {aba === 'agenda' && <AgendaPage tecnicos={tecnicos} locais={locais} tipos={tipos} podeEditar={podeEditar} papel={papel} />}
        {aba === 'operacao' && <OperacaoPage />}
        {aba === 'habilidades' && <HabilidadesPage tecnicos={tecnicos} podeEditar={podeEditar} />}
        {aba === 'tecnicos' && <TecnicosPage tecnicos={tecnicos} recarregar={recarregarCadastros} podeEditar={podeEditar} podeExcluir={papel === 'admin'} />}
        {aba === 'empresas' && <EmpresasPage podeEditar={podeEditar} />}
        {aba === 'locais' && <LocaisPage locais={locais} recarregar={recarregarCadastros} podeEditar={podeEditar} />}
        {aba === 'usuarios' && papel === 'admin' && <UsuariosPage />}
        {aba === 'roadmap' && papel === 'admin' && <RoadmapPage podeEditar />}
        {aba === 'admin' && papel === 'admin' && <AdminPage />}
      </main>
    </div>
  )
}
