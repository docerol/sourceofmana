# Shambleta companion v0 — fronteira de dinheiro real (webhooks de pagamento).
# Build context: RAIZ do repositório (dockerfile: deploy/companion/Dockerfile).
#
# Requer (env no Coolify):
#   SHAMBLETA_WEBHOOK_PROVIDER = stripe (produção) | shared (sandbox, exige allow-dev)
#   stripe:  SHAMBLETA_STRIPE_WEBHOOK_SECRET (whsec_...) obrigatório
#   shared:  SHAMBLETA_WEBHOOK_SECRET + SHAMBLETA_ALLOW_DEV_WEBHOOK=1 (nunca p/ real)
#   opcional: SHAMBLETA_CATALOG_FILE (JSON SKU->grant), SHAMBLETA_WEBHOOK_TOLERANCE
#   (sem catálogo = catálogo embutido; ver DEFAULT_CATALOG em server.py)

#
# Compartilha o volume /data com o serviço `game`: o companion grava em
# grant_queue no MESMO SQLite (WAL). Só vale em single-node; multi-node = Postgres.
FROM python:3.12-alpine
WORKDIR /app
COPY companion/server.py .
EXPOSE 8901
# user:// do game server = $HOME/.local/share/godot/app_userdata/Shambleta/
CMD ["python3", "server.py", \
     "--db", "/data/.local/share/godot/app_userdata/Shambleta/live.db", \
     "--port", "8901"]
