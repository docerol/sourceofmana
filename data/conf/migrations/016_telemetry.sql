-- SOM-IDLE D2: product telemetry + reconcile history (dashboard mínimo).
-- kinds: login | settle | levelup. Economia (mint/burn/trade/VIP) já vive no
-- ledger — o dashboard cruza as duas fontes.
CREATE TABLE IF NOT EXISTS telemetry_event (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  account_id INTEGER NOT NULL DEFAULT 0,
  char_id INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,
  value INTEGER NOT NULL DEFAULT 0,
  meta TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS idx_telemetry_kind_time ON telemetry_event(kind, created_at);
CREATE TABLE IF NOT EXISTS reconcile_run (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  divergences INTEGER NOT NULL DEFAULT 0
);
