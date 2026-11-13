-- 156: executa o reinício do módulo de ponto e remove a função (decisão 138, migration 155).
--
-- Executa SÓ na produção de verdade (ambiente = producao e instância da conta 1 = infoxtec) e antes de 01/12/2026.
-- No banco vazio do CI e na homologação (onde os testes continuam) não apaga nada: só avisa. Depois do prazo também
-- só avisa, para nunca travar as migrations seguintes da produção. Em todos os casos a função é removida: nenhum
-- caminho de exclusão do ponto fica no banco (Portaria MTP 671/2021).
--
-- Operação (docs/operacao.md, decisão 138): o backup da produção é disparado à mão logo antes deste Aplicar, com
-- ninguém batendo ponto. Se a migration falhar por espera de trava ou impasse, nada muda: disparar o Aplicar de novo.
do $$
declare v_r jsonb;
begin
  if coalesce(interno.fn_config('ambiente'), 'producao') = 'producao'
     and interno.fn_config('evolution_instancia') = 'infoxtec'
     and now() < '2026-12-01 00:00:00 America/Sao_Paulo'::timestamptz then
    v_r := interno.fn_ponto_reiniciar_modulo('APAGAR TODOS OS REGISTROS DE PONTO DE TODAS AS CONTAS',
      'Reinício antes do uso oficial em 01/12/2026: registros de teste, autorizado pelo responsável em 13/11 (decisão 138)');
    raise notice 'reinício do módulo de ponto feito (registro %): técnicos %, escalas %, apagadas %',
      v_r->>'reinicio', v_r->>'tecnicos', v_r->>'escalas', v_r->'apagadas';
  else
    raise notice 'reinício do módulo de ponto não executado aqui (só na produção e antes de 01/12/2026)';
  end if;
end $$;

drop function if exists interno.fn_ponto_reiniciar_modulo(text, text);
