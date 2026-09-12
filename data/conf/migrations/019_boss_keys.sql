-- SOM-IDLE: boss-key ladder (calibração 2026-09, pedido do produto).
-- Mobs de farm dropam "boss keys"; uma chave invoca um boss escalado ao nível do
-- char (sempre difícil), que paga xp/gold/chest/drop turbinados. bosses_beaten
-- é o índice do chefe mais forte já vencido (0..N-1) e trava a escada sequencial.
ALTER TABLE character ADD COLUMN boss_keys INTEGER NOT NULL DEFAULT 0;
ALTER TABLE character ADD COLUMN bosses_beaten INTEGER NOT NULL DEFAULT 0;
