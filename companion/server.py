#!/usr/bin/env python3
"""Shambleta companion v0 — fronteira de dinheiro real (SOM-IDLE C1).

Recebe webhooks de pagamento (Stripe/Pix sandbox) e grava grants idempotentes
na tabela grant_queue do MESMO SQLite do game server (modo WAL). O game server
consome a fila e espelha tudo no ledger; o companion nunca toca em outras
tabelas e nunca recebe estado de jogo.

Uso:
    SHAMBLETA_WEBHOOK_SECRET=xxx python3 companion/server.py --db /path/live.db --port 8901
    curl localhost:8901/health
    curl -X POST localhost:8901/webhooks/payments \
      -H 'X-Signature: <hmac-sha256-hex do body>' \
      -d '{"idempotency_key":"tx1","username":"Hero","kind":"gems","amount":550}'

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
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

KINDS = ("gems", "gold", "vip_days")
DAY = 86400


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
        secret = self.server.secret.encode()
        sig = self.headers.get("X-Signature", "")
        expect = hmac.new(secret, raw, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expect):
            return self._send(401, {"error": "bad_signature"})
        try:
            data = json.loads(raw.decode())
        except (ValueError, UnicodeDecodeError):
            return self._send(400, {"error": "bad_json"})
        key = data.get("idempotency_key", "")
        kind = data.get("kind", "")
        amount = data.get("amount", 0)
        payload = data.get("payload", {})
        if not key or kind not in KINDS or not isinstance(amount, int) or amount <= 0:
            return self._send(400, {"error": "bad_grant"})
        if not isinstance(payload, dict):
            return self._send(400, {"error": "bad_payload"})
        try:
            with self.server.store.connect() as con:
                account_id = self.server.store.account_id(
                    con, data.get("account_id"), data.get("username"))
                if account_id is None:
                    return self._send(404, {"error": "unknown_account"})
                status = self.server.store.enqueue(
                    con, key, account_id, kind, amount, payload)
        except sqlite3.Error as e:
            return self._send(500, {"error": "db_error", "detail": str(e)})
        self._send(200, {"status": status})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", required=True, help="caminho do live.db do game server")
    ap.add_argument("--port", type=int, default=8901)
    ap.add_argument("--secret", default=os.environ.get("SHAMBLETA_WEBHOOK_SECRET", ""),
                    help="default: env SHAMBLETA_WEBHOOK_SECRET")
    args = ap.parse_args()
    if not args.secret:
        sys.stderr.write("companion: refuse to start without a webhook secret "
                         "(--secret ou SHAMBLETA_WEBHOOK_SECRET)\n")
        return 2
    if not os.path.exists(args.db):
        sys.stderr.write("companion: database not found: %s\n" % args.db)
        return 2
    server = HTTPServer(("127.0.0.1", args.port), Handler)
    server.store = Store(args.db)
    server.secret = args.secret
    print("companion: listening on 127.0.0.1:%d (db %s)" % (args.port, args.db),
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
