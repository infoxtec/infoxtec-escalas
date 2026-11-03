import { useEffect, useState } from 'react'
import { HeartPulse, Loader2 } from 'lucide-react'
import { Button, ErrorBox, Input, Modal } from './ui'
import { api, baixarSaude, erroMsg } from '../lib/api'
import { supabase } from '../lib/supabase'

// Download protegido de saúde (migration 147): termo de sigilo aceito, código do autenticador digitado na hora e pacote
// montado para quem baixa, com marca d'água. Só aparece para o administrador com permissão de ver saúde; quem decide é o
// servidor.
export default function SaudeProtegida() {
  const [termo, setTermo] = useState<{ versao: number; texto: string; aceito: boolean } | null>(null)
  const [aberto, setAberto] = useState(false)
  const [li, setLi] = useState(false)
  const [codigo, setCodigo] = useState('')
  const [ocupado, setOcupado] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  useEffect(() => { api.saudeTermo().then(setTermo).catch(() => setTermo(null)) }, [])
  if (!termo) return null

  const fechar = () => { if (!ocupado) { setAberto(false); setCodigo(''); setLi(false); setErro(null) } }

  const baixar = async () => {
    setErro(null); setOcupado(true)
    try {
      if (!termo.aceito) {
        await api.saudeAceitarTermo(termo.versao)
        setTermo({ ...termo, aceito: true })
      }
      // código novo do autenticador: o token passa a dizer a hora desta verificação
      const { data } = await supabase.auth.mfa.listFactors()
      const fator = data?.totp.find(f => f.status === 'verified')
      if (!fator) throw new Error('Ative o aplicativo autenticador para baixar dados de saúde.')
      const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: fator.id, code: codigo })
      if (error) throw new Error('Código inválido ou vencido. Confira o relógio do celular e digite o código novo.')
      window.location.assign(await baixarSaude())
      setAberto(false); setCodigo(''); setLi(false)
    } catch (e) { setErro(erroMsg(e)); setCodigo('') } finally { setOcupado(false) }
  }

  return (
    <div className="rounded-md border border-red-200 p-3 space-y-2">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="text-sm font-medium">Dados de saúde</p>
          <p className="text-xs text-muted-foreground">Justificativas de saúde, atestados e ASO. O pacote é montado na hora, para você, com
            marca d'água em cada arquivo; pede o código do autenticador a cada download e fica registrado.</p>
        </div>
        <Button variant="outline" size="sm" onClick={() => setAberto(true)}><HeartPulse className="h-3.5 w-3.5" /> Baixar dados de saúde</Button>
      </div>
      <Modal open={aberto} onClose={fechar} title="Baixar dados de saúde"
        footer={<>
          <Button variant="outline" onClick={fechar} disabled={ocupado}>Cancelar</Button>
          <Button onClick={() => void baixar()} disabled={ocupado || codigo.length !== 6 || (!termo.aceito && !li)}>
            {ocupado && <Loader2 className="h-4 w-4 animate-spin" />} Baixar
          </Button>
        </>}>
        <div className="space-y-3">
          {!termo.aceito && (<>
            <div className="max-h-72 overflow-y-auto whitespace-pre-line rounded-md border bg-muted/30 p-3 text-xs">{termo.texto}</div>
            <label className="flex items-start gap-2 text-sm">
              <input type="checkbox" checked={li} onChange={e => setLi(e.target.checked)} disabled={ocupado} className="mt-0.5" />
              Li e aceito o termo de sigilo (versão {termo.versao}).
            </label>
          </>)}
          {termo.aceito && <p className="text-xs text-muted-foreground">Termo de sigilo versão {termo.versao} aceito.</p>}
          <div className="space-y-1">
            <p className="text-sm">Código do aplicativo autenticador</p>
            <Input inputMode="numeric" autoComplete="one-time-code" maxLength={6} value={codigo}
              onChange={e => setCodigo(e.target.value.replace(/\D/g, ''))} disabled={ocupado} />
          </div>
          {erro && <ErrorBox>{erro}</ErrorBox>}
        </div>
      </Modal>
    </div>
  )
}
