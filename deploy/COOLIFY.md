# Runbook de deploy — Coolify (beta fechado web)

Stack: 3 serviços em `deploy/docker-compose.yml` — `web` (client Godot Web +
nginx), `game` (server headless Godot, WebSocket plain :6108), `companion`
(webhooks de pagamento → `grant_queue`).

```
Browser ──wss 443──▶ Coolify proxy (TLS) ──ws──▶ game:6108
Browser ──https 443─▶ Coolify proxy (TLS) ──80──▶ web (nginx, COOP/COEP)
Stripe/Pix sandbox ──webhook──▶ companion:8901 ──SQLite WAL──▶ live.db ◀── game
```

## 1. Pré-requisitos

- Coolify ≥ 4.x com proxy Traefik ativo.
- Dois domínios (ou subdomínios) apontando para o servidor:
  `seudominio.com` (client web) e `ws.seudominio.com` (WebSocket do jogo).
- Um segredo para webhooks: `openssl rand -hex 32`.

## 2. Criar o projeto

1. New Resource → **Docker Compose** → aponte para o repositório (branch
   `master`), compose path: `deploy/docker-compose.yml`.
2. No ambiente do compose, defina:
   - `SHAMBLETA_WEBHOOK_SECRET` = segredo gerado (obrigatório — o companion
     recusa subir sem ele).
   - `SHAMBLETA_SERVER_ADDRESS` = `ws.seudominio.com`.
   - `SHAMBLETA_OFFSITE_BACKUPS` = vazio (ou caminho de montagem offsite).
3. Domínios por serviço (aba Domains):
   - `web` → `https://seudominio.com` (porta 80 do container).
   - `game` → `https://ws.seudominio.com` (porta **6108** do container). O
     proxy termina o TLS e encaminha ws plain — o server roda com
     `SHAMBLETA_PROXY_TLS=1` (já no compose) e por isso aceita bind sem cert.
   - `companion` → sem domínio público.
4. Volumes: o compose já declara `game-data:/data` (live.db + backups). Garanta
   que o Coolify o trate como volume persistente (não remova em redeploys).
5. Deploy. O build do `web` leva vários minutos (import + export Godot).

## 3. Credenciais do game server (e-mail/Discord)

O server lê `user://credential.cfg` = `/data/.local/share/godot/app_userdata/Shambleta/credential.cfg`
(`HOME=/data` no container). Sem esse arquivo o server sobe normalmente, mas
reset de senha não envia e-mail.

1. Coolify → serviço `game` → **Persistent Storage / File Config**: crie um
   arquivo montado no caminho acima com o conteúdo:

   ```ini
   [Discord]
   Discord-Enabled=false
   Discord-Token=""
   Discord-ChannelID=""
   [Email]
   Email-ApiKey="<brevo api key>"
   Email-SenderName="Shambleta"
   Email-SenderAddress="noreply@seudominio.com"
   ```

2. Restart no serviço `game`.

> O `credential.cfg` do **client web** é gravado pelo build (só seção
> `[Network]`, sem segredos) — nunca coloque chaves de API no settings.cfg
> do repositório.

## 4. Smoke test pós-deploy

1. `https://seudominio.com` abre o jogo (splash → login). No DevTools,
   confirme headers: `Cross-Origin-Opener-Policy: same-origin` e
   `Cross-Origin-Embedder-Policy: require-corp` no HTML **e** nos .wasm/.pck
   (sem COOP/COEP o browser bloqueia SharedArrayBuffer e o jogo não sobe).
2. Crie conta no client → deve entrar e auto-farmar zona 1.
3. `curl https://ws.seudominio.com` deve responder (upgrade de WS recusado em
   HTTP "puro" é esperado; o que importa é o handshake do jogo).
4. Webhook de teste:
   ```bash
   BODY='{"idempotency_key":"smoke1","username":"SeuNick","kind":"gems","amount":550}'
   SIG=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SHAMBLETA_WEBHOOK_SECRET" | awk '{print $2}')
   curl -X POST https://<url-do-companion>/webhooks/payments -H "X-Signature: $SIG" -d "$BODY"
   ```
   O saldo aparece no jogo com `/gems` (o server consome a fila a cada poucos
   segundos). `/health` e `/metrics` do companion ficam na rede interna —
   consulte via `docker compose exec companion wget -qO- localhost:8901/metrics`
   ou exponha atrás de auth se precisar.

## 5. Operação

| Tarefa | Como |
|---|---|
| Backup | Automático: diário local em `/data/.../sql-backups/daily/` + offsite (se configurado) com **restore probe** embutido. |
| Reconciliação | Diária pós-backup (`RunReconcileJob`); divergências aparecem em `/metrics` → `reconcile.divergences`. |
| Wipe de progresso (pré-beta) | migration `014_reset_progress_idle` ou reset do volume `game-data` antes dos convites. |
| Logs do server | Logs do container `game` (Util.PrintLog vai ao stdout). |
| Atualizar jogo | Push no branch → rebuild (client web é imutável por build; o server ignora clientes com protocol version diferente — força refresh). |

## 6. Limitações conhecidas (beta)

- **Peso do primeiro load**: ~62 MB gzip hoje (meta <25 MB).Principal culpado:
  `data/music` (26 MB embutidos no pck). Mitigação futura: stream/cache de
  música via PWA. Navegador moderno + boa conexão suportam; avise os testers.
- **SQLite compartilhado game+companion** só é válido em single-node (é o
  desenho do companion v0). Multi-node/CCU alto → Postgres (ARCHITECTURE §15).
- `ws.seudominio.com` publica o WebSocket do jogo **atrás do proxy**; nunca
  abra a 6108 do container na internet.
