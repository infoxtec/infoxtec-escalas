---
name: arquivos
description: "Lê e converte arquivos do responsável — plantas DWG/DXF, PDF, imagens e planilhas — entregando PDF vetorial e também PNG e JPG, sempre a partir da estrutura original do arquivo."
whenToUse: "Quando o responsável pedir para abrir, ler, analisar ou converter um arquivo dele (planta, desenho, documento, imagem, planilha)."
---

# Arquivos — como ler e converter o que o responsável manda

Regra combinada com o responsável em 25/10/2026, depois da planta do Leo Madeira: **este é o padrão** para
qualquer arquivo dele.

## O padrão de entrega

1. **Ler a estrutura nativa primeiro.** Nunca confiar num conversor intermediário sem conferir contra o
   original: a contagem de entidades do original é o teste. Conversor que "perdeu 80% do desenho" se
   denuncia pelo número, não pela aparência.
2. **Entregar PDF vetorial** (não rasterizado) **e também PNG e JPG** da mesma página.
3. **Olhar o resultado antes de entregar.** Rasterizar uma prévia e conferir: tinta ≤ 0,5% da página é
   sinal de desenho vazio ou fora do enquadramento.
4. **Dizer os limites em uma linha cada** — cores, hachuras, fontes, espessuras, escala.
5. **Não commitar o deliverable.** Fica no workspace como arquivo não versionado; o responsável baixa e
   apaga.

## DWG → PDF (o caminho que funciona)

O DXF do LibreDWG **corrompe** este tipo de arquivo: perde a seção BLOCKS (o desenho inteiro pode morar
dentro de um bloco), grava handle 0, duplica handles e corrompe dicionários de extensão. Não usar
`dwg2dxf` nem `dwg2SVG` como fonte do render. O caminho certo:

```bash
dwgread -O json planta.dwg > planta.json    # leitor nativo do LibreDWG, íntegro
python3 render.py                           # parser próprio -> matplotlib -> PDF
pdftoppm -r 150 -png "saida.pdf" "saida"     # PNG
pdftoppm -r 150 -jpeg -jpegopt quality=90 "saida.pdf" "saida"   # JPG
```

O parser precisa de, nesta ordem:

1. **Handle** no JSON do LibreDWG vem como lista `[code, size, value, ref]`: o valor é o índice **2**.
2. **Blocos**: `object == "BLOCK_HEADER"`; o `name` diz qual é (`*Model_Space`, `*Paper_Space`, os demais).
3. **Quem pertence a quem**: o `ownerhandle` de cada entidade aponta para o **handle do bloco**, não para a
   `first_entity` dele. Foi o erro que gerou a primeira entrega errada.
4. **O modelo é o que vale**: desenhar as entidades do `*Model_Space` **mais** cada `INSERT` do modelo com a
   transformação do bloco aplicada — `ins_pt`, `scale[0]`, `rotation`, `base_pt`. Ignorar a inserção
   desenha o desenho no espaço interno do bloco: escala errada e sem as anotações do modelo.
5. **Enquadramento por massa**: `percentile` de 0,2 a 99,8 nos vértices. Um punhado de entidades órfãs em
   (0,0) estica a página e achata o desenho (o sintoma é tinta < 0,5%).
6. **Tipos**: LINE (`start`/`end`), LWPOLYLINE (`points`, bit 1 do `flag` = fechada), SPLINE
   (`control_points`/`fit_points` — aproximação), TEXT (`ins_pt`, `height`, `text_value`), INSERT (recursão
   no bloco), HATCH (só o contorno).
7. **Desenho de linha em monocromático** para conferência; `MPLCONFIGDIR` num diretório gravável.

## Formatos de imagem

Para desenho técnico, **PNG é menor e mais fiel que JPG** (o JPG gera artefato em linha fina e costuma sair
maior). Entregar os dois assim mesmo, quando o responsável pedir, e avisar qual é o bom para impressão.

## Planilhas, PDF e imagens

Mesma lógica: ler a origem, converter para PDF quando fizer sentido, rasterizar para PNG/JPG, conferir
visualmente antes de entregar e declarar o que não foi preservado.
