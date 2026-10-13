#!/usr/bin/env node
// Previews de PR do projeto da produção na Vercel ("web") passam a usar o banco da HOMOLOGAÇÃO (decisão 92).
// As variáveis da produção ficam só em Production; Preview recebe as da homologação. Development não é usado
// (o painel local lê web/.env.homologacao e web/.env.producao, não a Vercel).
//
// Uso, no terminal da máquina, dentro de ~/infoxtec-escalas:
//   VERCEL_TOKEN=<token> node scripts/vercel-preview-homologacao.mjs            # só mostra o que faria
//   VERCEL_TOKEN=<token> node scripts/vercel-preview-homologacao.mjs --aplicar  # aplica
// Token: vercel.com → Account Settings → Tokens → Create (escopo do time infoxtec-escalas). Apagar depois do uso.
// O script nunca lê nem mostra o valor das variáveis da produção.

const TOKEN = process.env.VERCEL_TOKEN;
const APLICAR = process.argv.includes('--aplicar');
const TIME = 'team_ha0hV8QKoQZ0MuUgRXhuKdO1';
const PROJ_PRODUCAO = 'prj_Fx4BLVgIsupyvsHvAPT64KWGULLa';     // "web" → infoxtec-escalas.vercel.app
const PROJ_HOMOLOGACAO = 'prj_LHevW0JW8QeJHwkGoVdNb4mPZuVU';  // infoxtec-escalas-homologacao.vercel.app
// valores públicos da homologação (os mesmos de web/.env.homologacao; a chave é a publicável)
const PREVIEW = {
  VITE_SUPABASE_URL: 'https://oruwnlxyvznpigbpjjbx.supabase.co',
  VITE_SUPABASE_ANON_KEY: 'sb_publishable_aMlvBNYhUoGGsohsEfiFTA_6So6G1p_',
  VITE_AMBIENTE: 'homologacao',
};
const CHAVES = Object.keys(PREVIEW);

if (!TOKEN) {
  console.error('Falta o token. Rode assim: VERCEL_TOKEN=<token> node scripts/vercel-preview-homologacao.mjs');
  process.exit(1);
}

async function api(metodo, caminho, corpo) {
  const sep = caminho.includes('?') ? '&' : '?';
  const r = await fetch(`https://api.vercel.com${caminho}${sep}teamId=${TIME}`, {
    method: metodo,
    headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
    body: corpo ? JSON.stringify(corpo) : undefined,
  });
  const dados = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${metodo} ${caminho}: HTTP ${r.status} ${dados?.error?.message ?? ''}`);
  return dados;
}

const alvo = e => [...e.target].sort().join(', ');

// 1) projeto da produção: o que tem hoje e o que muda
const { envs } = await api('GET', `/v10/projects/${PROJ_PRODUCAO}/env`);
const nossas = envs.filter(e => CHAVES.includes(e.key) && !e.gitBranch);
console.log('\nProjeto da produção ("web") — hoje:');
for (const e of nossas) console.log(`  ${e.key.padEnd(24)} ${alvo(e)}`);

const passos = [];
for (const e of nossas) {
  const temProd = e.target.includes('production');
  const outros = e.target.filter(t => t !== 'production');
  if (temProd && outros.length) passos.push({ txt: `${e.key}: deixar só em Production (tirar ${outros.join(', ')})`,
    fazer: () => api('PATCH', `/v9/projects/${PROJ_PRODUCAO}/env/${e.id}`, { target: ['production'] }) });
  else if (!temProd) passos.push({ txt: `${e.key}: apagar a de ${outros.join(', ')} (recriada abaixo com a homologação)`,
    fazer: () => api('DELETE', `/v9/projects/${PROJ_PRODUCAO}/env/${e.id}`) });
}
passos.push({ txt: `criar em Preview: ${CHAVES.join(', ')} → homologação (oruwnlxyvznpigbpjjbx)`,
  fazer: () => api('POST', `/v10/projects/${PROJ_PRODUCAO}/env`,
    CHAVES.map(k => ({ key: k, value: PREVIEW[k], type: 'plain', target: ['preview'] }))) });

console.log('\nO que o script faz:');
passos.forEach((p, i) => console.log(`  ${i + 1}. ${p.txt}`));

// 2) projeto da homologação: só confere
const h = await api('GET', `/v10/projects/${PROJ_HOMOLOGACAO}/env`);
console.log('\nProjeto da homologação — conferência (sem mudança):');
for (const k of CHAVES) {
  const e = h.envs.find(x => x.key === k && !x.gitBranch && x.target.includes('production'));
  console.log(`  ${k.padEnd(24)} ${e ? 'ok (' + alvo(e) + ')' : 'FALTA em Production'}`);
}

if (!APLICAR) {
  console.log('\nNada foi alterado. Para aplicar, rode de novo com --aplicar no final.\n');
  process.exit(0);
}
for (const p of passos) { await p.fazer(); console.log(`  feito: ${p.txt}`); }
const depois = (await api('GET', `/v10/projects/${PROJ_PRODUCAO}/env`)).envs.filter(e => CHAVES.includes(e.key) && !e.gitBranch);
console.log('\nProjeto da produção ("web") — depois:');
for (const e of depois) console.log(`  ${e.key.padEnd(24)} ${alvo(e)}`);
console.log('\nPronto. Vale a partir do próximo preview de PR. A produção (infoxtec-escalas.vercel.app) não muda.');
console.log('Agora apague o token em vercel.com → Account Settings → Tokens.\n');
