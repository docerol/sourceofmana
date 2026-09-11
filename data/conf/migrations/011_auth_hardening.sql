-- SOM-IDLE: A1 auth hardening (Trilha A — bloqueantes de lançamento)
-- KDF versioning, brute-force lockout, e-mail verification flag.
-- hash_ver: 0 = legacy single SHA-256 (verify-only, upgraded on next login),
--           1 = iterated KDF (Hasher.HashVersion).
-- locked_until / failed_attempts: exponential backoff enforced in SQLService.
-- email_verified: 0 = pending (default), 1 = verified via token flow (companion).
ALTER TABLE account ADD COLUMN hash_ver INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN failed_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN locked_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE account ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX IF NOT EXISTS idx_account_email_unique ON account(email) WHERE email <> '';
