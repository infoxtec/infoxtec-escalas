import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

export const configurado = Boolean(url && key)

// Tipo do link que trouxe o usuario (convite ou redefinicao de senha), lido antes do
// cliente limpar a URL.
const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''))
export const tipoDoLink: 'invite' | 'recovery' | null =
  hash.get('type') === 'invite' ? 'invite' : hash.get('type') === 'recovery' ? 'recovery' : null

export const supabase = createClient(url ?? 'http://localhost', key ?? 'x', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
})
