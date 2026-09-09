-- SOM-IDLE: F2 idle-spike schema (TECH_SPEC_CORE.md §3/§4 + ECONOMY_STUDY.md)
-- Minimal ledger/wallet/settle/formation layer. F1 will extend, never edit.

-- Per-account wallet (gems reserved; gold remains stat.gp per ARCHITECTURE §9)
CREATE TABLE IF NOT EXISTS wallet (
	account_id INTEGER NOT NULL,
	gems BIGINT NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (account_id)
);

-- Append-only transaction ledger
CREATE TABLE IF NOT EXISTS ledger_transaction (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	account_id INTEGER NOT NULL,
	char_id INTEGER NOT NULL,
	kind TEXT NOT NULL,
	amount BIGINT NOT NULL,
	balance_after BIGINT NOT NULL DEFAULT 0,
	reason TEXT NOT NULL DEFAULT '',
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ledger_char ON ledger_transaction (char_id, id);
CREATE INDEX IF NOT EXISTS idx_ledger_account ON ledger_transaction (account_id, id);

CREATE TRIGGER IF NOT EXISTS ledger_transaction_no_update
BEFORE UPDATE ON ledger_transaction
BEGIN
	SELECT RAISE(ABORT, 'ledger_transaction is append-only (UPDATE denied)');
END;

CREATE TRIGGER IF NOT EXISTS ledger_transaction_no_delete
BEFORE DELETE ON ledger_transaction
BEGIN
	SELECT RAISE(ABORT, 'ledger_transaction is append-only (DELETE denied)');
END;

-- Settle anchor per character (idempotency + efficiency tracking)
ALTER TABLE character ADD COLUMN farm_zone INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN last_settled_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN session_efficiency REAL NOT NULL DEFAULT 1.0;

-- Per-account formation slots (loadout + auto-potion)
CREATE TABLE IF NOT EXISTS formation (
	account_id INTEGER NOT NULL,
	slot INTEGER NOT NULL,
	char_id INTEGER NOT NULL DEFAULT 0,
	skill_loadout TEXT NOT NULL DEFAULT '',
	auto_potion_pct REAL NOT NULL DEFAULT 35.0,
	PRIMARY KEY (account_id, slot)
);

-- Chest instances granted by settles (rows kept in F2; opening is F4 scope)
CREATE TABLE IF NOT EXISTS chest_instance (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	char_id INTEGER NOT NULL,
	chest_hash INTEGER NOT NULL DEFAULT 0,
	origin TEXT NOT NULL DEFAULT 'settle',
	item_state TEXT NOT NULL DEFAULT 'closed',
	created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chest_char ON chest_instance (char_id);
