/**
 * Senha forte sem custo (etapa 6). A proteção nativa do Supabase contra senha vazada é paga; aqui
 * o painel consulta a base pública do Have I Been Pwned por k-anonimato: só os 5 primeiros
 * caracteres do SHA-1 da senha saem do navegador, nunca a senha nem o hash inteiro.
 */

/** Mesma regra configurada no Supabase (os dois projetos): 8 caracteres, com letras e números. */
export const SENHA_MINIMA = 8
export const REGRA_SENHA = `Mínimo de ${SENHA_MINIMA} caracteres, com letras e números.`

/** Mensagem de erro, ou null se a senha cumpre a regra. */
export function problemaNaSenha(senha: string): string | null {
  if (senha.length < SENHA_MINIMA) return `A senha precisa ter pelo menos ${SENHA_MINIMA} caracteres.`
  if (!/[A-Za-zÀ-ÿ]/.test(senha) || !/\d/.test(senha)) return 'A senha precisa ter letras e números.'
  return null
}

/** true se a senha aparece em vazamentos conhecidos. Sem conexão com a base, não bloqueia. */
export async function senhaVazada(senha: string): Promise<boolean> {
  try {
    const bytes = new Uint8Array(await crypto.subtle.digest('SHA-1', new TextEncoder().encode(senha)))
    const hash = [...bytes].map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase()
    const prefixo = hash.slice(0, 5)
    const sufixo = hash.slice(5)
    const resp = await fetch(`https://api.pwnedpasswords.com/range/${prefixo}`, {
      headers: { 'Add-Padding': 'true' },   // respostas de tamanho uniforme
      signal: AbortSignal.timeout(8000),
    })
    if (!resp.ok) return false
    const linhas = (await resp.text()).split('\n')
    return linhas.some(l => {
      const [suf, qtd] = l.trim().split(':')
      return suf === sufixo && Number(qtd) > 0   // o preenchimento vem com contagem 0
    })
  } catch {
    return false
  }
}
