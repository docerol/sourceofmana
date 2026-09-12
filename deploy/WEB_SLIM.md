# Payload web — medição e cortes (SOM-IDLE, etapa 2)

Primeiro load do cliente web em **gzip** (o que o navegador baixa). Medido com
export headless real (`godot --export-release "Web"`, template 4.7.stable) em
2026-09, comparando artefatos `gzip -9`.

## Antes

| Artefato | raw | gzip |
|---|---|---|
| `index.pck` | 62 MB | 46.3 MB |
| `index.side.wasm` (engine, threads/DLink) | 42 MB | 10.0 MB |
| `index.wasm` (stub loader) | 1.6 MB | 0.6 MB |
| `libgdsqlite…wasm` | 2.4 MB | 0.7 MB |
| `libsentry…wasm` | 2.6 MB | 0.4 MB |
| **total first-load** | — | **≈ 57.9 MB** |

Bate com o `BETA_DEPLOY_REPORT §2` (57.8 MB).

## Corte aplicado — música fora do export Web

Diagnóstico: a trilha sonora está **desligada no build idle** — `Audio.Load()`
(único ponto que lê/toca um `.ogg`) não tem chamador; só `SetVolume` é usado.
Os 7 `.ogg` (26 MB) eram **peso morto no pck**. Exclusão só no preset **Web**
(desktop/mobile mantêm), removendo `data/music/*` **e** `presets/music/*` juntos
(presets referenciam os `.ogg`; remover os dois mantém o `DB` carregando limpo —
sem asserts). `Audio.gd` ficou tolerante a trilha ausente (log no lugar de
`assert(false)`) como cinto de segurança.

## Depois (Web export atual)

| Artefato | raw | gzip |
|---|---|---|
| `index.pck` | 36 MB | 20.7 MB |
| `index.side.wasm` | 42 MB | 10.0 MB |
| outros wasm (sqlite+sentry+stub) | 6.6 MB | 1.7 MB |
| **total first-load** | — | **≈ 32.4 MB** (−44%)** |

Sem erros/asserts de música no boot do export. `maps`/`press`/`docs` já eram
excluídos no preset Web antes disto.

## Para chegar a <25 MB (follow-through — exige QA visual)

O piso sem mexer em arte é ~32 MB: `side.wasm` 10 MB (engine, fixo para o set de
features com threads+gdsqlite+webrtc) + `pck` 20.7 MB. Os ~7,4 MB restantes estão
no `data/graphics` (15 MB raw, sobretudo PNG de sprites/tiles, que quase não
comprime em gzip). Alavancas (cada uma precisa revisar o resultado no navegador):

- **Re-compressão de texturas p/ web**: forçar formatos compactados por GPU/ATF e
  lossless WebP no lugar de PNG no pipeline de import (per-texture `compress/*`);
  validar nitidez/paleta.
- **Pack de áudio opcional (patch `.pck`)** servido via HTTP e montado em runtime
  (`ProjectSettings.load_resource_pack` de um `audio.pck` baixado), caso a trilha
  volte a ser ligada — aí a música entra sem pesar no primeiro load. Requer
  `Cross-Origin-Resource-Policy` no host do `.pck` (o nginx já serve COOP/COEP).
- **Lazy/remote das artes não-criticas da zona 1** (mesma técnica do patch .pck).

Estas são escolhas de arte/pipeline com verificação visual — ficam como
handoff; o corte acima é o ganho grande, seguro e já medido.
