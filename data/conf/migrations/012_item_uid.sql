-- SOM-IDLE B1: per-grant item identity (anti-duplicação, trade history / RMT graph).
-- Cada concessão cria um lote (uid); consumos decrementam em FIFO e apagam
-- lotes zerados. Invariante: soma dos lotes ativos == stack agregada em item.
CREATE TABLE IF NOT EXISTS item_instance (
  uid INTEGER PRIMARY KEY AUTOINCREMENT,
  char_id INTEGER NOT NULL REFERENCES character(char_id),
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  storage INTEGER NOT NULL DEFAULT 0,
  bound INTEGER NOT NULL DEFAULT 0,
  customfield TEXT NOT NULL DEFAULT '',
  reason TEXT NOT NULL DEFAULT '',
  parent_uid INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_item_instance_char ON item_instance(char_id, item_id);
CREATE INDEX IF NOT EXISTS idx_item_instance_parent ON item_instance(parent_uid);
-- Backfill: cada stack agregada vira um lote de origem (reconciliação desde o dia 1).
INSERT INTO item_instance (char_id, item_id, count, storage, bound, customfield, reason, parent_uid, created_at)
SELECT char_id, item_id, count, storage, 0, customfield, 'backfill_012', 0, strftime('%s','now') FROM item;
