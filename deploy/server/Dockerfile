# Shambleta game server (headless) — para Coolify.
# Build context: RAIZ do repositório (dockerfile: deploy/server/Dockerfile).
#
# Runtime:
#   - binda WebSocket plain na 6108 (SHAMBLETA_PROXY_TLS=1: o TLS é terminado
#     no proxy do Coolify — NUNCA expor a 6108 direto na internet).
#   - live.db e backups ficam em $HOME (user://) → volume /data (persistente
#     no Coolify). SHAMBLETA_OFFSITE_BACKUPS aponta p/ segunda montagem.
#   - Credenciais (Email/Discord): user://credential.cfg — criar como "File
#     Config" do Coolify e montar em
#     /data/.local/share/godot/app_userdata/Shambleta/credential.cfg
#     (sem isso o server sobe, mas reset de senha/email não funcionam).
FROM barichello/godot-ci:4.7.1 AS build
WORKDIR /project
COPY . .
RUN godot --headless --editor --import --quit || true
RUN mkdir -p /out \
 && godot --headless --path . --export-release "Linux/X11 Headless Server" /out/Shambleta.x86_64

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /out/Shambleta.x86_64 /app/Shambleta.x86_64

ENV HOME=/data
ENV SHAMBLETA_PROXY_TLS=1
VOLUME /data
EXPOSE 6108
CMD ["/app/Shambleta.x86_64", "--server"]
