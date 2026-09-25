import { useEffect, useRef } from 'react'

export const MINUTOS_INATIVIDADE = 30
const EVENTOS = ['mousemove', 'mousedown', 'keydown', 'touchstart', 'scroll', 'visibilitychange']

/** Desconecta o usuario apos N minutos sem nenhuma interacao na tela. */
export function useInatividade(aoExpirar: () => void, minutos = MINUTOS_INATIVIDADE) {
  const ultimo = useRef(Date.now())
  const callback = useRef(aoExpirar)
  callback.current = aoExpirar

  useEffect(() => {
    const marcar = () => { if (document.visibilityState === 'visible') ultimo.current = Date.now() }
    EVENTOS.forEach(e => window.addEventListener(e, marcar, { passive: true }))

    // confere a cada 30s: pega tambem o computador que ficou suspenso
    const relogio = setInterval(() => {
      if (Date.now() - ultimo.current >= minutos * 60_000) callback.current()
    }, 30_000)

    return () => {
      EVENTOS.forEach(e => window.removeEventListener(e, marcar))
      clearInterval(relogio)
    }
  }, [minutos])
}

/**
 * A cada publicacao nova, o navegador que estiver aberto recarrega sozinho.
 * Evita telas antigas conversando com um banco ja atualizado.
 */
export function useVersaoPublicada(versaoAtual: string, intervaloMin = 3) {
  useEffect(() => {
    let parado = false
    const conferir = async () => {
      if (parado || document.visibilityState !== 'visible') return
      try {
        const r = await fetch(`/version.json?t=${Date.now()}`, { cache: 'no-store' })
        if (!r.ok) return
        const { build } = await r.json() as { build?: string }
        if (build && build !== versaoAtual) {
          parado = true
          window.location.reload()
        }
      } catch { /* sem rede: tenta de novo depois */ }
    }
    const relogio = setInterval(conferir, intervaloMin * 60_000)
    window.addEventListener('focus', conferir)
    void conferir()
    return () => { clearInterval(relogio); window.removeEventListener('focus', conferir) }
  }, [versaoAtual, intervaloMin])
}
