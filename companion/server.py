#!/usr/bin/env python3
"""Shambleta companion v0 — fronteira de dinheiro real (SOM-IDLE C1).

Recebe webhooks de pagamento (Stripe/Pix sandbox) e grava grants idempotentes
na tabela grant_queue do MESMO SQLite do game server (modo WAL). O game server
consome a fila e espelha tudo no ledger; o companion nunca toca em outras
tabelas e nunca recebe estado de jogo.

Uso:
    # produção (assinatura Stripe + catálogo autoritativo):
    SHAMBLETA_WEBHOOK_PROVIDER=stripe \
    SHAMBLETA_STRIPE_WEBHOOK_SECRET=whsec_xxx \
    python3 companion/server.py --db /data/live.db --port 8901
      # Stripe manda Stripe-Signature: t=...,v1=... ; o checkout define
      # metadata.shambleta_sku + client_reference_id=<account_id>.
      # O grant usa amount/ kind do CATÁLOGO, nunca do corpo.

    # sandbox/dev (assinatura por segredo compartilhado, payload plano) — só
    # com opt-in explícito:
    SHAMBLETA_WEBHOOK_PROVIDER=shared SHAMBLETA_WEBHOOK_SECRET=xxx \
    SHAMBLETA_ALLOW_DEV_WEBHOOK=1 python3 companion/server.py --db /data/live.db
      curl -X POST localhost:8901/webhooks/payments \
        -H 'X-Signature: <hmac-sha256-hex do body>' \
        -d '{"idempotency_key":"tx1","username":"Hero","sku":"gems.550"}'

Contrato de promoção: reescrever em Go/Node + Postgres quando o CCU exigir
(ARCHITECTURE §11). A tabela grant_queue e a semântica de idempotência não mudam.
"""
import argparse
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

KINDS = ("gems", "gold", "vip_days")
DAY = 86400

# --------------------------------------------------------------------------
# SOM-IDLE (1c): webhook hardening — o companion é a fronteira de dinheiro
# real, então NÃO pode confiar num segredo compartilhado genérico nem num
# "amount" vindo do corpo (qualquer um com o segredo mintaria qualquer valor
# para qualquer conta). Duas garantias:
#   1. A assinatura é verificada com o esquema do PROVEDOR (Stripe hoje) com
#      janela anti-replay; o segredo compartilhado vira apenas "modo dev".
#   2. A quantidade concedida vem do CATÁLOGO de SKUs (server-authoritative);
#      o corpo só pode REFERENCIAR um SKU, nunca ditar o montante.
# --------------------------------------------------------------------------

# Catálogo canônico (SKU -> o que comprar). Sobrescreva com um JSON via
# SHAMBLETA_CATALOG_FILE / --catalog quando o checkout real existir. O preço
# (`price`) fica aqui só p/ auditoria/cross-check; o que vira grant é kind+amount.
DEFAULT_CATALOG = {
    "gems.550":   {"kind": "gems",     "amount": 550,   "currency": "BRL", "price": 19.90},
    "gems.1200":  {"kind": "gems",     "amount": 1200,  "currency": "BRL", "price": 39.90},
    "gems.3000":  {"kind": "gems",     "amount": 3000,  "currency": "BRL", "price": 79.90},
    "vip.1mo":    {"kind": "vip_days", "amount": 30,    "currency": "BRL", "price": 24.90},
    "vip.3mo":    {"kind": "vip_days", "amount": 90,    "currency": "BRL", "price": 59.90},
}


def load_catalog(path):
    if not path:
        return dict(DEFAULT_CATALOG)
    with open(path, "r", encoding="utf-8") as fh:
        raw = json.load(fh)
    for sku, e in raw.items():
        if e.get("kind") not in KINDS or not isinstance(e.get("amount"), int) or e["amount"] <= 0:
            raise ValueError("catalog entry %r invalid" % sku)
    return raw


class CatalogError(Exception):
    pass


# (3c) hook de alerta/uptime opt-in: se SHAMBLETA_ALERT_WEBHOOK estiver setado
# (ex.: healthchecks.io/Discord), melhor-esforço um POST JSON. Nunca bloqueia o
# request (thread própria + timeout curto) nem levanta — alertas são side-channel.
ALERT_URL = os.environ.get("SHAMBLETA_ALERT_WEBHOOK", "")


def alert(message, level="warn"):
    if not ALERT_URL:
        return
    import threading
    from urllib.request import Request, urlopen

    def _send():
        try:
            payload = json.dumps({"source": "shambleta-companion",
                                  "level": level, "message": message,
                                  "at": int(time.time())}).encode()
            req = Request(ALERT_URL, data=payload,
                          headers={"Content-Type": "application/json"})
            urlopen(req, timeout=5).read()
        except Exception:
            pass  # alertas nunca derrubam o serviço

    threading.Thread(target=_send, daemon=True).start()



def resolve_grant(catalog, sku, claimed_amount=None):
    """Devolve (kind, authoritative_amount). Nunca usa claimed_amount como fonte
    de verdade — só como cross-check (CDC: preço anunciado = preço cobrado)."""
    if not sku or sku not in catalog:
        raise CatalogError("unknown_sku")
    entry = catalog[sku]
    amount = entry["amount"]
    if claimed_amount is not None and claimed_amount != amount:
        raise CatalogError("amount_mismatch")
    return entry["kind"], amount


def _const_time(a, b):
    return hmac.compare_digest(a.encode() if isinstance(a, str) else a,
                               b.encode() if isinstance(b, str) else b)


def verify_shared_secret(secret, header_value, raw_body):
    """Esquema legado/sandbox: X-Signature = hex(HMAC-SHA256(secret, body))."""
    if not secret:
        return False
    expect = hmac.new(secret.encode(), raw_body, hashlib.sha256).hexdigest()
    return _const_time(header_value or "", expect)


def verify_stripe_signature(secret, header_value, raw_body, tolerance=300, now=None):
    """Esquema oficial Stripe: Stripe-Signature: 't=<ts>,v1=<sig>' onde
    sig = hex(HMAC-SHA256(secret, '<ts>.<body>')). Recusa ts fora da janela
    (anti-replay). Aceita se QUALQUER v1 bater."""
    if not secret or not header_value:
        return False
    ts = None
    v1 = []
    for part in header_value.split(","):
        part = part.strip()
        if part.startswith("t="):
            ts = part[2:]
        elif part.startswith("v1="):
            v1.append(part[3:])
    if ts is None or not v1:
        return False
    try:
        ts_int = int(ts)
    except ValueError:
        return False
    if now is None:
        now = int(time.time())
    if abs(now - ts_int) > tolerance:
        return False
    signed = ("%d." % ts_int).encode() + raw_body
    expect = hmac.new(secret.encode(), signed, hashlib.sha256).hexdigest()
    return any(_const_time(s, expect) for s in v1)


def normalize_event(provider, data):
    """Reduz o corpo (formato do provedor OU flat sandbox) a um grant canônico:
    {idempotency_key, account_id, username, sku}. Retorna None se não aplicável."""
    if provider == "stripe":
        # checkout.session.completed → entrega o SKU + a conta no metadata.
        obj = (data.get("data") or {}).get("object") or {}
        meta = obj.get("metadata") or {}
        sku = meta.get("shambleta_sku") or obj.get("sku")
        acct = obj.get("client_reference_id") or meta.get("shambleta_account_id")
        key = data.get("id") or obj.get("id")  # event id = chave idempotente
        user = meta.get("shambleta_username")
        if acct is not None:
            acct = int(acct)
        else:
            acct = None
        return {"idempotency_key": key, "account_id": acct,
                "username": user, "sku": sku}
    # sandbox / dev / pix-notify simples: payload plano
    acct = data.get("account_id")
    if acct is not None:
        acct = int(acct)
    return {"idempotency_key": data.get("idempotency_key", ""),
            "account_id": acct, "username": data.get("username"),
            "sku": data.get("sku")}


class Store:
    def __init__(self, db_path):
        self.db_path = db_path

    def connect(self):
        con = sqlite3.connect(self.db_path, timeout=5.0)
        con.execute("PRAGMA journal_mode=WAL;")
        con.execute("PRAGMA busy_timeout=5000;")
        return con

    def account_id(self, con, account_id=None, username=None):
        if account_id is not None:
            row = con.execute("SELECT account_id FROM account WHERE account_id = ?;",
                              (account_id,)).fetchone()
            return row[0] if row else None
        if username:
            row = con.execute("SELECT account_id FROM account WHERE username = ?;",
                              (username,)).fetchone()
            return row[0] if row else None
        return None

    def enqueue(self, con, key, account_id, kind, amount, payload):
        cur = con.execute(
            "INSERT OR IGNORE INTO grant_queue "
            "(idempotency_key, account_id, kind, amount, payload, status, created_at) "
            "VALUES (?, ?, ?, ?, ?, 'pending', strftime('%s','now'))",
            (key, account_id, kind, amount, json.dumps(payload)))
        con.commit()
        return "queued" if cur.rowcount == 1 else "duplicate"

    def pending(self, con):
        return con.execute(
            "SELECT COUNT(*) FROM grant_queue WHERE status = 'pending';").fetchone()[0]

    def metrics(self, con):
        # SOM-IDLE D2: dashboard mínimo — economia (ledger) x comportamento
        # (telemetry). Tudo derivado; nada é escrito aqui.
        now = int(time.time())
        gems = con.execute(
            "SELECT COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0), "
            "COALESCE(SUM(CASE WHEN amount < 0 THEN -amount END), 0) "
            "FROM ledger_transaction WHERE kind = 'gems';").fetchone()
        stock = con.execute("SELECT COALESCE(SUM(gems), 0) FROM wallet;").fetchone()
        gold7 = con.execute(
            "SELECT COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0) "
            "FROM ledger_transaction WHERE kind = 'gold' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        trades7 = con.execute(
            "SELECT COUNT(*) FROM ledger_transaction "
            "WHERE reason LIKE 'trade_out:%' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        fees7 = con.execute(
            "SELECT COALESCE(SUM(-amount), 0) FROM ledger_transaction "
            "WHERE reason = 'trade_fee' AND created_at > ?;",
            (now - 7 * DAY,)).fetchone()
        vip = con.execute("SELECT COUNT(*) FROM account WHERE vip_until > ?;",
                          (now,)).fetchone()
        accts = con.execute(
            "SELECT COUNT(*), COALESCE(SUM(last_timestamp > ?), 0) FROM account;",
            (now - DAY,)).fetchone()
        d1 = con.execute(
            "SELECT COUNT(*), COALESCE(SUM(last_timestamp > created_timestamp + 72000), 0) "
            "FROM account WHERE created_timestamp BETWEEN ? AND ?;",
            (now - 2 * DAY, now - DAY)).fetchone()
        settles = con.execute(
            "SELECT COUNT(*), COALESCE(AVG(CAST(json_extract(meta, '$.eff') AS REAL)), 0) "
            "FROM telemetry_event WHERE kind = 'settle' AND created_at > ?;",
            (now - DAY,)).fetchone()
        logins = con.execute(
            "SELECT COUNT(*) FROM telemetry_event "
            "WHERE kind = 'login' AND created_at > ?;", (now - DAY,)).fetchone()
        recon = con.execute(
            "SELECT divergences, created_at FROM reconcile_run "
            "ORDER BY id DESC LIMIT 1;").fetchone()
        guilds = con.execute("SELECT COUNT(*) FROM guild;").fetchone()
        ah = con.execute(
            "SELECT COUNT(*) FROM auction_listing WHERE status = 'open';").fetchone()
        season = con.execute(
            "SELECT season_id FROM season WHERE status = 'active' "
            "ORDER BY season_id DESC LIMIT 1;").fetchone()
        return {
            "gems": {"mint": gems[0], "burn": gems[1], "stock": stock[0]},
            "gold_7d": {"faucet": gold7[0]},
            "trades_7d": {"count": trades7[0], "fees_burned": fees7[0]},
            "vip_active": vip[0],
            "accounts": {"total": accts[0], "active_24h": accts[1]},
            "retention_d1": {"cohort": d1[0], "retained": d1[1]},
            "settles_24h": {"count": settles[0], "avg_eff": round(settles[1], 3)},
            "logins_24h": logins[0],
            "reconcile": {"divergences": recon[0], "at": recon[1]} if recon else None,
            "grants_pending": self.pending(con),
            "guilds": guilds[0],
            "ah_open": ah[0],
            "season_active": season[0] if season else None,
        }


class Handler(BaseHTTPRequestHandler):
    server_version = "ShambletaCompanion/0.1"

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        sys.stderr.write("companion: %s\n" % (args[0] % args[1:]))

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            with self.server.store.connect() as con:
                self._send(200, {"ok": True,
                                 "pending": self.server.store.pending(con)})
            return
        if path == "/metrics":
            try:
                with self.server.store.connect() as con:
                    self._send(200, self.server.store.metrics(con))
            except sqlite3.Error as e:
                self._send(500, {"error": "db_error", "detail": str(e)})
            return
        return self._send(404, {"error": "not_found"})

    def do_POST(self):
        if urlparse(self.path).path != "/webhooks/payments":
            return self._send(404, {"error": "not_found"})
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length > 0 else b""
        provider = self.server.provider
        # (1c) autentica a ORIGEM pelo esquema do provedor, não por segredo único.
        if provider == "stripe":
            ok = verify_stripe_signature(self.server.stripe_secret,
                                         self.headers.get("Stripe-Signature", ""),
                                         raw, self.server.tolerance)
        elif provider == "shared":
            # modo sandbox: só permitido explicitamente (nunca em produção).
            ok = self.server.allow_dev and verify_shared_secret(
                self.server.secret, self.headers.get("X-Signature", ""), raw)
        else:
            ok = False
        if not ok:
            return self._send(401, {"error": "bad_signature"})
        try:
            data = json.loads(raw.decode())
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {"error": "bad_json"})
        norm = normalize_event(provider, data)
        if not norm:
            return self._send(400, {"error": "bad_event"})
        # (1c) o montante vem do CATÁLOGO — nunca do corpo.
        try:
            kind, amount = resolve_grant(
                self.server.catalog, norm["sku"], norm.get("amount"))
        except CatalogError as e:
            alert("webhook grant rejected (%s) sku=%r" % (str(e), norm.get("sku")))
            return self._send(400, {"error": str(e)})
        key = norm["idempotency_key"]
        if not key:
            return self._send(400, {"error": "bad_grant"})
        payload = {"sku": norm["sku"], "provider": provider, "kind": kind}
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, norm.get("account_id"), norm.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                status = self.server.store.enqueue(
                    con, key, account_id, kind, amount, payload)
        except sqlite3.Error as e:
            alert("webhook DB error: %s" % e, "error")
            return self._send(500, {"error": "db_error", "detail": str(e)})
        self._send(200, {"status": status})



def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True, help="caminho do live.db do game server")
    ap.add_argument("--port", type=int, default=8901)
    ap.add_argument("--provider",
                    default=os.environ.get("SHAMBLETA_WEBHOOK_PROVIDER", "shared"),
                    choices=("stripe", "shared"),
                    help="esquema de assinatura a verificar (stripe = produção)")
    ap.add_argument("--secret",
                    default=os.environ.get("SHAMBLETA_WEBHOOK_SECRET", ""),
                    help="segredo do modo sandbox (provider=shared)")
    ap.add_argument("--stripe-secret",
                    default=os.environ.get("SHAMBLETA_STRIPE_WEBHOOK_SECRET", ""),
                    help="whsec_... do endpoint Stripe (provider=stripe)")
    ap.add_argument("--catalog",
                    default=os.environ.get("SHAMBLETA_CATALOG_FILE", ""),
                    help="JSON de catálogo SKU->grant; default: embutido")
    ap.add_argument("--tolerance", type=int,
                    default=int(os.environ.get("SHAMBLETA_WEBHOOK_TOLERANCE", "300")),
                    help="janela anti-replay (s)")
    ap.add_argument("--allow-dev",
                    default=os.environ.get("SHAMBLETA_ALLOW_DEV_WEBHOOK", "") == "1",
                    action="store_true",
                    help="permitir provider=shared (sandbox); NUNCA em produção")
    args = ap.parse_args()
    try:
        catalog = load_catalog(args.catalog)
    except (ValueError, OSError, json.JSONDecodeError) as e:
        sys.stderr.write("companion: bad catalog: %s\n" % e)
        return 2
    if args.provider == "stripe" and not args.stripe_secret:
        sys.stderr.write("companion: provider=stripe exige --stripe-secret "
                         "(SHAMBLETA_STRIPE_WEBHOOK_SECRET)\n")
        return 2
    if args.provider == "shared" and not (args.secret and args.allow_dev):
        sys.stderr.write("companion: provider=shared exige --secret E --allow-dev "
                         "(modo sandbox explícito; use provider=stripe em produção)\n")
        return 2
    if not os.path.exists(args.db):
        sys.stderr.write("companion: database not found: %s\n" % args.db)
        return 2
    host = os.environ.get("SHAMBLETA_COMPANION_HOST", "127.0.0.1")
    # (3c) servidor de produção: multi-thread (webhooks concorrentes não bloqueiam
    # /health nem entre si). Cada request abre a própria conexão SQLite (WAL), então
    # a troca HTTPServer→ThreadingHTTPServer não cruza conexões entre threads.
    server = ThreadingHTTPServer((host, args.port), Handler)
    server.daemon_threads = True   # não segura o processo em requests pendurados
    server.request_queue_size = 128
    server.store = Store(args.db)
    server.secret = args.secret
    server.provider = args.provider
    server.stripe_secret = args.stripe_secret
    server.catalog = catalog
    server.tolerance = args.tolerance
    server.allow_dev = bool(args.allow_dev)
    print("companion: listening on %s:%d (db %s, provider %s, %d SKUs)"
          % (host, args.port, args.db, args.provider, len(catalog)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0



if __name__ == "__main__":
    sys.exit(main())
