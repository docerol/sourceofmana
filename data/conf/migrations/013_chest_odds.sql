-- SOM-IDLE B2: chest compliance (loot-box regulatório) — snapshot de odds e
-- server seed persistidos por baú (dispute replay sem depender só do ledger).
ALTER TABLE chest_instance ADD COLUMN odds_snapshot TEXT NOT NULL DEFAULT '';
ALTER TABLE chest_instance ADD COLUMN server_seed TEXT NOT NULL DEFAULT '';
