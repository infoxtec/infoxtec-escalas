import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const configurado = Boolean(url && key)

// Tipo do link que trouxe o usuario (convite ou redefinicao de senha), lido antes do
// cliente limpar a URL.
const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''))
export const tipoDoLink: 'invite' | 'recovery' | null =
  hash.get('type') === 'invite' ? 'invite' : hash.get('type') === 'recovery' ? 'recovery' : null

// Multiempresa (F3b, decisão 117): a conta escolhida vai no cabeçalho x-conta de toda chamada à API, ao Storage e às
// Edge Functions; o banco confere se o usuário é membro dela (fn_conta_de). O login não leva o cabeçalho.
const CHAVE_CONTA = 'trilha.conta'
let contaEscolhida: string | null = null
try { contaEscolhida = localStorage.getItem(CHAVE_CONTA) } catch { /* navegador sem armazenamento */ }

export function contaAtual(): string | null { return contaEscolhida }

export function escolherConta(id: string | null) {
  contaEscolhida = id
  try {
    if (id) localStorage.setItem(CHAVE_CONTA, id)
    else localStorage.removeItem(CHAVE_CONTA)
  } catch { /* fica só nesta aba */ }
}

export const fetchComConta: typeof fetch = (entrada, init) => {
  const endereco = typeof entrada === 'string' ? entrada : entrada instanceof URL ? entrada.href : entrada.url
  if (!contaEscolhida || !/\/(rest|storage|functions)\/v1\//.test(endereco)) return fetch(entrada, init)
  const cabecalhos = new Headers(init?.headers ?? (entrada instanceof Request ? entrada.headers : undefined))
  cabecalhos.set('x-conta', contaEscolhida)
  return fetch(entrada, { ...init, headers: cabecalhos })
}

export const supabase = createClient(url ?? 'http://localhost', key ?? 'x', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  global: { fetch: fetchComConta },
})
