-- SOM-IDLE D3: antifraud review queue (heuristic flags, revisão manual).
-- status: open | reviewed | dismissed. Dedup: 1 flag aberta por (account, kind, detail).
CREATE TABLE IF NOT EXISTS fraud_flag (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,
  account_id INTEGER NOT NULL REFERENCES account(account_id),
  char_id INTEGER NOT NULL DEFAULT 0,
  kind TEXT NOT NULL,
  detail TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open'
);
CREATE INDEX IF NOT EXISTS idx_fraud_open ON fraud_flag(status, account_id);
