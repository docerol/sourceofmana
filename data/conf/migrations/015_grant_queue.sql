-- SOM-IDLE C1: companion → server grants (dinheiro real nunca toca o game server).
-- O companion (REST) grava aqui; o game server consome e espelha no ledger.
-- Idempotência: idempotency_key UNIQUE + status CAS (pending→processed|failed).
CREATE TABLE IF NOT EXISTS grant_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  idempotency_key TEXT NOT NULL UNIQUE,
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  kind TEXT NOT NULL,
  amount INTEGER NOT NULL,
  payload TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'pending',
  error TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  processed_at INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_grant_pending ON grant_queue(status, id);
