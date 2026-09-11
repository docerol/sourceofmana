-- SOM-IDLE B3: wipe da Era MMORPG (XP_PROGRESSION.md §7) — o idle é um produto
-- novo; nível/XP/gold/inventário/equipamentos legados não fazem sentido no novo
-- pacing. Contas, personagens, e-mail verificado e o ledger (auditoria) sobrevivem.
-- Precedente: 005_reset_positions_and_inventory, 006_reset_progress_veteran_legacy.
UPDATE stat SET level = 1, experience = 0, gp = 0;
DELETE FROM item;
DELETE FROM item_instance;
DELETE FROM wallet;
DELETE FROM chest_instance;
DELETE FROM formation;
UPDATE equipment SET
	weapon = -1, weaponCustom = '',
	shield = -1, shieldCustom = '',
	ammunition = -1, ammunitionCustom = '',
	hands = -1, handsCustom = '',
	chest = -1, chestCustom = '',
	neck = -1, neckCustom = '',
	feet = -1, feetCustom = '',
	head = -1, headCustom = '',
	legs = -1, legsCustom = '',
	accessory1 = -1, accessory1Custom = '',
	accessory2 = -1, accessory2Custom = '';
DELETE FROM skill WHERE skill_id NOT IN (229218829, 193470266);
INSERT INTO skill (char_id, skill_id, level)
	SELECT char_id, 193470266, 1 FROM character
	WHERE char_id NOT IN (SELECT char_id FROM skill WHERE skill_id = 193470266);
UPDATE character SET farm_zone = 0, last_settled_at = strftime('%s','now'), session_efficiency = 1.0, power_score = 0, formation_slot = 0;
