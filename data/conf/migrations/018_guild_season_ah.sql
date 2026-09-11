-- SOM-IDLE E: guilds + seasons + auction house (mínimo viável).
-- Vault usa tabela própria + guild_vault_log append-only (lots são char-bound;
-- RMT via vault exige officer+ e fica todo no log). Pontos de guild: coluna
-- pronta, acúmulo via settle = fast follow (níveis v0 custam gold+gems).
CREATE TABLE IF NOT EXISTS guild (
  guild_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  level INTEGER NOT NULL DEFAULT 1,
  points INTEGER NOT NULL DEFAULT 0,
  leader_account INTEGER NOT NULL REFERENCES account(account_id),
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS guild_member (
  guild_id INTEGER NOT NULL REFERENCES guild(guild_id),
  account_id INTEGER PRIMARY KEY REFERENCES account(account_id),
  rank TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_guild_member_guild ON guild_member(guild_id);
CREATE TABLE IF NOT EXISTS guild_vault (
  guild_id INTEGER NOT NULL REFERENCES guild(guild_id),
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (guild_id, item_id)
);
CREATE TABLE IF NOT EXISTS guild_vault_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  guild_id INTEGER NOT NULL,
  account_id INTEGER NOT NULL DEFAULT 0,
  char_id INTEGER NOT NULL DEFAULT 0,
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  kind TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS season (
  season_id INTEGER PRIMARY KEY AUTOINCREMENT,
  starts_at INTEGER NOT NULL,
  ends_at INTEGER NOT NULL,
  rules_frozen TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL DEFAULT 'active'
);
CREATE TABLE IF NOT EXISTS season_score (
  season_id INTEGER NOT NULL REFERENCES season(season_id),
  kind TEXT NOT NULL,
  subject_id INTEGER NOT NULL,
  value INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (season_id, kind, subject_id)
);
CREATE TABLE IF NOT EXISTS auction_listing (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seller_char INTEGER NOT NULL REFERENCES character(char_id),
  seller_account INTEGER NOT NULL REFERENCES account(account_id),
  item_id INTEGER NOT NULL,
  count INTEGER NOT NULL,
  price_gold INTEGER NOT NULL,
  escrow_uids TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auction_open ON auction_listing(status, id);
