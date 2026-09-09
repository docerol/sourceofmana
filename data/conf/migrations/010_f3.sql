-- SOM-IDLE: F3 schema (TECH_SPEC_CORE.md §3/§5 + MONETIZATION.md §2.2)
-- VIP window, cached power score for the leaderboard, active formation slot.

-- VIP subscription window (epoch seconds; 0 = no VIP). Mods: +20% xp/gold/drops
-- while active (MONETIZATION §2.2: VIP sells offline cap respect, not power —
-- the +20% applies to the idle faucet only).
ALTER TABLE account ADD COLUMN vip_until INTEGER NOT NULL DEFAULT 0;

-- Cached power score (level*10 + attack + defense) for the leaderboard without
-- requiring players online; refreshed on connect/settle/disconnect.
ALTER TABLE character ADD COLUMN power_score INTEGER NOT NULL DEFAULT 0;

-- Active formation slot (0..MaxFormationSlots-1) chosen when entering a zone
ALTER TABLE character ADD COLUMN formation_slot INTEGER NOT NULL DEFAULT 0;
