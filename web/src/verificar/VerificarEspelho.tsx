import { useEffect, useState } from 'react'
import { api, erroMsg } from '../lib/api'
import type { ConferenciaEspelho } from '../lib/types'

// Conferência pública do QR do espelho de ponto (decisão 82): sem login e sem dado pessoal. Mostra só se o
// documento de número X da empresa Y, mês Z, está íntegro e se foi assinado. Quem tem a cópia confere o resto.

export default function VerificarEspelho() {
  const codigo = new URLSearchParams(window.location.search).get('c') ?? ''
  const [r, setR] = useState<ConferenciaEspelho | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => {
    if (!codigo) { setErro('Código de verificação ausente.'); return }
    api.verificarEspelho(codigo).then(setR).catch(e => setErro(erroMsg(e)))
  }, [codigo])

  return (
    <div className="mx-auto max-w-md space-y-4 p-6">
      <h1 className="text-lg font-semibold">Conferência de espelho de ponto</h1>
      <p className="font-mono text-xs text-muted-foreground">Código {codigo || '—'}</p>
      {erro && <p className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800">{erro}</p>}
      {!erro && !r && <p className="text-sm text-muted-foreground">Conferindo...</p>}
      {r && !r.encontrado && (
        <p className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800">
          Nenhum espelho com este código. Confira se o código foi digitado ou lido corretamente.
        </p>
      )}
      {r?.encontrado && (
        <div className="space-y-3">
          <p className={`rounded-md border p-3 text-sm font-medium ${r.integro ? 'border-green-300 bg-green-50 text-green-800' : 'border-red-300 bg-red-50 text-red-800'}`}>
            {r.integro ? 'Documento íntegro: o conteúdo é o mesmo da emissão.' : 'Atenção: o conteúdo registrado não confere com o da emissão.'}
          </p>
          {r.substituido && (
            <p className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
              Esta versão foi substituída por uma emissão mais nova do mesmo mês.
            </p>
          )}
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            <dt className="text-muted-foreground">Registro</dt><dd>nº {r.registro}{r.versao && r.versao > 1 ? ` · versão ${r.versao}` : ''}</dd>
            <dt className="text-muted-foreground">Empregador</dt><dd>{r.empresa}</dd>
            <dt className="text-muted-foreground">CNPJ</dt><dd>{r.cnpj}</dd>
            <dt className="text-muted-foreground">Mês</dt><dd>{r.competencia}</dd>
            <dt className="text-muted-foreground">Emitido em</dt><dd>{r.emitido_em}</dd>
            <dt className="text-muted-foreground">Assinatura</dt>
            <dd>{r.assinado_em ? `assinado pelo funcionário em ${r.assinado_em}${r.assinatura_integra === false ? ' (assinatura não confere)' : ''}` : 'ainda não assinado'}</dd>
          </dl>
          <p className="break-all font-mono text-[11px] text-muted-foreground">SHA-256 {r.sha256}</p>
          <p className="text-xs text-muted-foreground">
            Esta página não mostra nome, CPF nem horários. Confere apenas que o espelho de número {r.registro} foi emitido pelo
            sistema, com este conteúdo, e se o funcionário o assinou.
          </p>
        </div>
      )}
    </div>
  )
}
