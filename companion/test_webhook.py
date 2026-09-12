#!/usr/bin/env python3
"""Testes do hardening do webhook (SOM-IDLE 1c). Sem pytest: python3
companion/test_webhook.py. Sai !=0 se falhar."""
import hashlib
import hmac
import os
import sqlite3
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import server  # noqa: E402

FAILS = []
CHECKS = 0


def ok(cond, label):
    global CHECKS
    CHECKS += 1
    print(("  PASS" if cond else "  FAIL") + " · " + label)
    if not cond:
        FAILS.append(label)


def raises(exc, fn, label):
    try:
        fn()
        ok(False, label + " (no raise)")
    except exc:
        ok(True, label)


# --- catálogo (amount autoritativo) ---
cat = server.DEFAULT_CATALOG
kind, amount = server.resolve_grant(cat, "gems.1200")
ok(kind == "gems" and amount == 1200, "catalog resolves known sku")
ok(server.resolve_grant(cat, "vip.1mo")[0] == "vip_days", "catalog vip kind")
raises(server.CatalogError, lambda: server.resolve_grant(cat, "gems.9999999"),
       "unknown sku rejected")
raises(server.CatalogError, lambda: server.resolve_grant(cat, None), "null sku rejected")
raises(server.CatalogError, lambda: server.resolve_grant(cat, "gems.550", 600),
       "amount mismatch rejected")
ok(server.resolve_grant(cat, "gems.550", 550) == ("gems", 550),
   "matching claimed amount accepted")

# --- assinatura compartilhada (sandbox) ---
body = b'{"sku":"gems.550"}'
sec = "s3cr3t"
good = hmac.new(sec.encode(), body, hashlib.sha256).hexdigest()
ok(server.verify_shared_secret(sec, good, body), "shared secret valid")
ok(not server.verify_shared_secret(sec, "deadbeef", body), "shared secret bad")
ok(not server.verify_shared_secret("", good, body), "shared secret empty -> deny")
ok(not server.verify_shared_secret(sec, good, body + b"x"), "shared secret tampered body")

# --- assinatura Stripe (esquema oficial + anti-replay) ---
whsec = "whsec_test"
ts = int(time.time())
signed = ("%d." % ts).encode() + body
v1 = hmac.new(whsec.encode(), signed, hashlib.sha256).hexdigest()
hdr = "t=%d,v1=%s" % (ts, v1)
ok(server.verify_stripe_signature(whsec, hdr, body), "stripe valid signature")
ok(not server.verify_stripe_signature(whsec, hdr, body + b" "), "stripe tampered body")
ok(not server.verify_stripe_signature(whsec, "t=%d,v1=bad" % ts, body), "stripe bad sig")
ok(not server.verify_stripe_signature(whsec, "v1=%s" % v1, body), "stripe missing t")
# replay: timestamp fora da janela
old = ts - 10_000
oldsigned = ("%d." % old).encode() + body
oldv1 = hmac.new(whsec.encode(), oldsigned, hashlib.sha256).hexdigest()
ok(not server.verify_stripe_signature(whsec, "t=%d,v1=%s" % (old, oldv1), body, 300),
   "stripe replay rejected (ts too old)")
ok(not server.verify_stripe_signature("", hdr, body), "stripe no secret -> deny")

# --- normalização de evento ---
stripe_evt = {
    "id": "evt_123",
    "type": "checkout.session.completed",
    "data": {"object": {
        "id": "cs_x",
        "client_reference_id": "42",
        "metadata": {"shambleta_sku": "gems.1200"},
    }},
}
n = server.normalize_event("stripe", stripe_evt)
ok(n["account_id"] == 42 and n["sku"] == "gems.1200" and n["idempotency_key"] == "evt_123",
   "stripe event -> canonical grant")
flat = {"idempotency_key": "tx1", "username": "Hero", "sku": "gems.550"}
nf = server.normalize_event("shared", flat)
ok(nf["username"] == "Hero" and nf["sku"] == "gems.550" and nf["account_id"] is None,
   "sandbox flat -> canonical grant")

# --- idempotência do enqueue (schema grant_queue real) ---
tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
tmp.close()
con = sqlite3.connect(tmp.name)
con.execute("CREATE TABLE account (account_id INTEGER PRIMARY KEY, username TEXT);")
con.execute("INSERT INTO account (account_id, username) VALUES (1, 'Hero');")
con.execute(
    "CREATE TABLE grant_queue (id INTEGER PRIMARY KEY AUTOINCREMENT,"
    " idempotency_key TEXT NOT NULL UNIQUE, account_id INTEGER NOT NULL,"
    " kind TEXT NOT NULL, amount INTEGER NOT NULL, payload TEXT,"
    " status TEXT NOT NULL DEFAULT 'pending', created_at INTEGER NOT NULL);")
st = server.Store(tmp.name)
ok(st.account_id(con, username="Hero") == 1, "store resolves account by username")
ok(st.account_id(con, username="Ghost") is None, "store rejects unknown account")
ok(st.enqueue(con, "k1", 1, "gems", 550, {"sku": "gems.550"}) == "queued", "first enqueue queued")
ok(st.enqueue(con, "k1", 1, "gems", 550, {"sku": "gems.550"}) == "duplicate",
   "replayed key deduped")
ok(st.pending(con) == 1, "only one pending grant")
con.close()
os.unlink(tmp.name)

# resumo
if FAILS:
    print("== COMPANION: %d failures ==" % len(FAILS))
    for f in FAILS:
        print("  - " + f)
    sys.exit(1)
print("== COMPANION: %d checks, 0 failures ==" % CHECKS)
sys.exit(0)
