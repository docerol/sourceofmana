# Shambleta companion v0 — fronteira de dinheiro real (webhooks de pagamento).
# Build context: RAIZ do repositório (dockerfile: deploy/companion/Dockerfile).
#
# Requer (env no Coolify):
#   SHAMBLETA_WEBHOOK_SECRET — segredo HMAC dos webhooks (obrigatório).
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
