// App do ponto instalável à parte (PWA, painel 3.68.0): em /ponto, o manifesto e o nome do app são os do ponto.
// Arquivo próprio (e não script no index.html) para a CSP aceitar só scripts do próprio site (B1, decisão 133).
if (location.pathname.indexOf('/ponto') === 0) {
  document.getElementById('manifesto').href = '/manifest-ponto.webmanifest'
  document.getElementById('titulo-app').content = 'Ponto'
}
