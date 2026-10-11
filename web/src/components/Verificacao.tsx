import { useEffect, useState } from 'react'
import { CheckCircle2, Loader2, ShieldAlert, X } from 'lucide-react'
import { Button, ErrorBox } from './ui'
import { api, erroMsg } from '../lib/api'
import type { PontoVerificacao } from '../lib/types'

const STATUS: Record<string, string> = { pendente: 'Em análise', aprovada: 'Aprovado', negada: 'Não aprovado', cancelada: 'Cancelado' }

// Conferência do QR do timbre (decisão 62): mostra o registro e se o arquivo do cofre continua íntegro.
// Não mostra o documento; ele só abre no cofre, para quem vê atestados
export default function Verificacao({ codigo, onFechar }: { codigo: string; onFechar: () => void }) {
  const [r, setR] = useState<PontoVerificacao | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => {
    api.pontoVerificarDocumento(codigo).then(setR).catch(e => setErro(erroMsg(e)))
  }, [codigo])

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/60 p-4" onClick={onFechar}>
      <div className="w-full max-w-lg space-y-3 rounded-xl bg-card p-5" onClick={e => e.stopPropagation()}>
        <div className="flex items-center justify-between gap-2">
          <p className="text-sm font-semibold">Conferência de documento</p>
          <Button variant="ghost" size="sm" onClick={onFechar}><X className="h-4 w-4" /> Fechar</Button>
        </div>
        {erro && <ErrorBox>{erro}</ErrorBox>}
        {!r && !erro && <div className="flex justify-center py-8"><Loader2 className="h-5 w-5 animate-spin" /></div>}
        {r && !r.encontrado && (
          <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800">
            <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" />
            <p>Código não encontrado. Este QR não foi gerado por este sistema, ou o código foi alterado.</p>
          </div>
        )}
        {r && r.encontrado && (
          <>
            {r.descartado ? (
              <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
                Registro válido, mas o documento foi <strong>descartado</strong> do cofre em {r.descartado_em}. Fica só o registro de que existiu.
              </div>
            ) : r.integro ? (
              <div className="flex items-start gap-2 rounded-lg border border-green-300 bg-green-50 p-3 text-sm text-green-800">
                <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0" />
                <p><strong>O registro existe e o arquivo guardado no cofre não foi alterado</strong> desde o recebimento, em {r.recebido_em}.</p>
              </div>
            ) : (
              <div className="flex items-start gap-2 rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800">
                <ShieldAlert className="mt-0.5 h-5 w-5 shrink-0" />
                <p><strong>O arquivo não confere</strong> com o SHA-256 gravado no recebimento. Avise o administrador.</p>
              </div>
            )}
            <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
              <dt className="text-muted-foreground">Registro</dt><dd className="font-semibold">nº {r.registro} · {r.empresa}</dd>
              <dt className="text-muted-foreground">Pedido</dt><dd>nº {r.pedido} · {STATUS[r.status] ?? r.status}{r.decidido_em ? ` em ${r.decidido_em}` : ''}</dd>
              <dt className="text-muted-foreground">Funcionário</dt><dd>{r.tecnico}</dd>
              <dt className="text-muted-foreground">Motivo</dt><dd>{r.motivo}</dd>
              <dt className="text-muted-foreground">Período</dt><dd>{r.periodo}</dd>
              <dt className="text-muted-foreground">Recebido</dt><dd>{r.recebido_em} · pelo {r.canal}</dd>
              <dt className="text-muted-foreground">SHA-256</dt><dd className="break-all font-mono text-xs">{r.sha256}</dd>
            </dl>
            <p className="text-xs text-muted-foreground">
              Confira se o registro, o funcionário e o período batem com o documento que você tem em mãos: a conferência
              vale para o arquivo guardado no cofre, não para uma foto ou cópia. A emissão do documento se confere com quem
              o emitiu. Esta conferência ficou registrada.
            </p>
          </>
        )}
      </div>
    </div>
  )
}
