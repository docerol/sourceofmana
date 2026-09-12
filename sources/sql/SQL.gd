extends ServiceBase
class_name SQLService

#
var db : Object						= null
var backups : SQLBackups			= null
var queryMutex : Mutex				= Mutex.new()

# Migrations
func HasVersion() -> bool:
	var result = Query("SELECT name FROM sqlite_master WHERE type=\"table\" AND name=\"migration\"")
	return not result.is_empty()

func GetVersion() -> int:
	if HasVersion():
		var result = Query("SELECT version FROM migration LIMIT 1;")
		if not result.is_empty():
			return result[0].get("version", 0)
	return 0

func SetVersion(version : int):
	Query("UPDATE migration SET version = %d;" % version)

func ApplyMigrations():
	var currentVersion : int = GetVersion()
	var patches : PackedStringArray = FileSystem.ParseSQL(Path.MigrationRsc)
	var patchCount : int = patches.size()
	if patchCount == currentVersion:
		return

	while patchCount > currentVersion:
		ApplyMigration(patches[currentVersion])
		currentVersion += 1
	SetVersion(currentVersion)

func ApplyMigration(migrationFile : String):
	var migration : String = FileAccess.get_file_as_string(migrationFile)
	Query(migration)

# Accounts
func AddAccount(username : String, password : String, email : String) -> bool:
	# SOM-IDLE A1: e-mail obrigatório e único (base do tier anti-RMT + recuperação).
	if email.is_empty() or HasEmail(email):
		return false
	var salt : String = Hasher.GenerateSalt()
	var hashedPassword : String = Hasher.HashPasswordV1(password, salt)

	var accountData : Dictionary = {
		"username" : username,
		"password_salt" : salt,
		"password" : hashedPassword,
		"hash_ver" : Hasher.HashVersion,
		"email" : email,
		"email_verified" : 0,
		"failed_attempts" : 0,
		"locked_until" : 0,
		"created_timestamp" : SQLCommons.Timestamp()
	}
	return db.insert_row("account", accountData)

func RemoveAccount(accountID : int) -> bool:
	return db.delete_rows("account", "account_id = %d" % accountID)

func HasAccount(username : String) -> bool:
	return not QueryBindings("SELECT account_id FROM account WHERE username = ?;", [username]).is_empty()

func ValidateAuthPassword(username : String, triedPassword : String) -> Peers.AccountData:
	var results : Array[Dictionary] = QueryBindings("SELECT account_id, password, password_salt, permission, hash_ver, failed_attempts, locked_until FROM account WHERE username = ?;", [username])
	assert(results.size() <= 1, "Duplicated account row")
	if results.is_empty():
		return null
	var row : Dictionary = results[0]
	# SOM-IDLE A1: conta travada recusa sem verificar a senha (anti-enumeration de timing).
	if int(row.get("locked_until", 0)) > SQLCommons.Timestamp():
		return null
	var salt = row.get("password_salt", null)
	var correctPassword = row.get("password", null)
	var accountID = row.get("account_id", null)
	if not (salt is String and correctPassword is String and accountID is int):
		return null
	var hashVer : int = int(row.get("hash_ver", 0))
	if not Hasher.VerifyPassword(triedPassword, salt, correctPassword, hashVer):
		RecordFailedLogin(accountID, int(row.get("failed_attempts", 0)))
		return null
	ResetFailedLogins(accountID)
	if hashVer < Hasher.HashVersion:
		var newSalt : String = Hasher.GenerateSalt()
		var newHash : String = Hasher.HashPasswordV1(triedPassword, newSalt)
		ExecuteBindings("UPDATE account SET password = ?, password_salt = ?, hash_ver = ? WHERE account_id = ?;", [newHash, newSalt, Hasher.HashVersion, accountID])
	var permission = row.get("permission", null)
	if not permission:
		permission = ActorCommons.Permission.NONE
	return Peers.AccountData.new(accountID, permission)

# SOM-IDLE A1: backoff exponencial anti-bruteforce + unicidade de e-mail + LGPD.
func RecordFailedLogin(accountID : int, prevAttempts : int) -> void:
	var attempts : int = prevAttempts + 1
	var lockedUntil : int = 0
	if attempts >= NetworkCommons.MaxLoginAttempts:
		var shift : int = mini(attempts - NetworkCommons.MaxLoginAttempts, 10)
		lockedUntil = SQLCommons.Timestamp() + mini(NetworkCommons.BaseLockoutSec * (1 << shift), NetworkCommons.MaxLockoutSec)
	ExecuteBindings("UPDATE account SET failed_attempts = ?, locked_until = ? WHERE account_id = ?;", [attempts, lockedUntil, accountID])

func ResetFailedLogins(accountID : int) -> void:
	ExecuteBindings("UPDATE account SET failed_attempts = 0, locked_until = 0 WHERE account_id = ?;", [accountID])

func IsLockedOut(accountID : int) -> bool:
	var rows : Array[Dictionary] = QueryBindings("SELECT locked_until FROM account WHERE account_id = ?;", [accountID])
	return not rows.is_empty() and int(rows[0].get("locked_until", 0)) > SQLCommons.Timestamp()

func HasEmail(email : String) -> bool:
	return not QueryBindings("SELECT account_id FROM account WHERE email = ?;", [email]).is_empty()

func GetAccountIDByEmail(email : String) -> int:
	var rows : Array[Dictionary] = QueryBindings("SELECT account_id FROM account WHERE email = ?;", [email])
	return int(rows[0].get("account_id", NetworkCommons.PeerUnknownID)) if not rows.is_empty() else NetworkCommons.PeerUnknownID

func IsEmailVerified(accountID : int) -> bool:
	var rows : Array[Dictionary] = QueryBindings("SELECT email_verified FROM account WHERE account_id = ?;", [accountID])
	return not rows.is_empty() and int(rows[0].get("email_verified", 0)) == 1

# SOM-IDLE D3: raw antifraud reads (db direto — chamáveis dentro de Transaction()).
func IsEmailVerifiedRaw(accountID : int) -> bool:
	var rows : Array = db.select_rows("account", "account_id = %d" % accountID, ["email_verified"])
	return not rows.is_empty() and int(rows[0].get("email_verified", 0)) == 1

func LastTradeTimestampRaw(charID : int) -> int:
	if not db.query_with_bindings("SELECT COALESCE(MAX(created_at), 0) AS t FROM ledger_transaction WHERE char_id = ? AND (reason LIKE 'trade_out:%' OR reason LIKE 'trade_in:%');", [charID]):
		return 0
	var res : Array = db.query_result
	return int(res[0].get("t", 0)) if not res.is_empty() else 0

func TradeCountTodayRaw(accountID : int, nowSec : int = 0) -> int:
	var now : int = nowSec if nowSec > 0 else SQLCommons.Timestamp()
	var dayStart : int = now - (now % 86400)
	if not db.query_with_bindings("SELECT COUNT(*) AS n FROM ledger_transaction WHERE account_id = ? AND reason LIKE 'trade_out:%' AND created_at >= ?;", [accountID, dayStart]):
		return 999
	var res : Array = db.query_result
	return int(res[0].get("n", 999)) if not res.is_empty() else 999

# SOM-IDLE D3: CS reads (suporte — fora de transação, via bindings).
func SearchLedger(accountID : int, limit : int = 20) -> Array[Dictionary]:
	return QueryBindings("SELECT id, char_id, kind, amount, balance_after, reason, created_at FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT ?;", [accountID, mini(limit, 100)])

func GetItemLot(uid : int) -> Dictionary:
	var rows : Array[Dictionary] = QueryBindings("SELECT uid, char_id, item_id, count, bound, reason, parent_uid, created_at FROM item_instance WHERE uid = ?;", [uid])
	return {} if rows.is_empty() else rows[0]

func LotHistory(uid : int, maxHops : int = 20) -> Array[Dictionary]:
	# Caminha parent_uid para cima (origem do item — grafo RMT).
	var chain : Array[Dictionary] = []
	var seen : Dictionary = {}
	var current : int = uid
	while current > 0 and chain.size() < maxHops and not seen.has(current):
		seen[current] = true
		var lot : Dictionary = GetItemLot(current)
		if lot.is_empty():
			break
		chain.append(lot)
		current = int(lot.get("parent_uid", 0))
	return chain

func ListFraudFlags(status : String = "open", limit : int = 50) -> Array[Dictionary]:
	return QueryBindings("SELECT id, created_at, account_id, char_id, kind, detail, status FROM fraud_flag WHERE status = ? ORDER BY id DESC LIMIT ?;", [status, mini(limit, 100)])

func ReviewFraudFlag(flagID : int, status : String) -> bool:
	if status != "reviewed" and status != "dismissed":
		return false
	# NOTE: query_with_bindings relata sucesso com 0 linhas afetadas (armadilha
	# F3) — o gate de existência garante que só flag aberta muda de estado.
	if QueryBindings("SELECT id FROM fraud_flag WHERE id = ? AND status = 'open';", [flagID]).is_empty():
		return false
	return ExecuteBindings("UPDATE fraud_flag SET status = ? WHERE id = ?;", [status, flagID])
func SetEmailVerified(accountID : int, verified : bool = true) -> bool:
	return ExecuteBindings("UPDATE account SET email_verified = ? WHERE account_id = ?;", [1 if verified else 0, accountID])

func DeleteAccountData(accountID : int) -> bool:
	# LGPD art. 18: anonimiza em vez de hard delete (ledger append-only preserva histórico).
	var salt : String = Hasher.GenerateSalt()
	var filler : String = Hasher.HashPasswordV1(salt, salt)
	return ExecuteBindings("UPDATE account SET username = ?, email = '', password = ?, password_salt = ?, hash_ver = ?, email_verified = 0, failed_attempts = 0, locked_until = 0 WHERE account_id = ?;", ["deleted_%d" % accountID, filler, salt, Hasher.HashVersion, accountID])

func UpdateAccount(accountID : int, platform : int = NetworkCommons.Platform.UNKNOWN) -> bool:
	var newTimestamp : int = SQLCommons.Timestamp()
	var data : Dictionary = {
		"last_timestamp": newTimestamp,
	}
	if platform != NetworkCommons.Platform.UNKNOWN:
		data["platform"] = platform
	return db.update_rows("account", "account_id = %d;" % accountID, data)

# Characters
func AddCharacter(accountID : int, nickname : String, stats : Dictionary, traits : Dictionary, attributes : Dictionary) -> bool:
	var charData : Dictionary = {
		"account_id": accountID,
		"nickname": nickname,
		"created_timestamp": SQLCommons.Timestamp()
	}
	var ret : bool = db.insert_row("character", charData)
	if ret:
		var charID : int = GetCharacterID(accountID, nickname)
		ret = ret and db.update_rows("stat", "char_id = %d" % charID, stats)
		ret = ret and db.update_rows("trait", "char_id = %d" % charID, traits)
		ret = ret and db.update_rows("attribute", "char_id = %d" % charID, attributes)
	return ret

func RemoveCharacter(charID : int) -> bool:
	if charID != NetworkCommons.PeerUnknownID:
		return db.delete_rows("character", "char_id = %d" % charID)
	return false

func GetCharacters(accountID : int) -> PackedInt64Array:
	var charIDs : Array[int] = []
	for result in db.select_rows("character", "account_id = %d" % accountID, ["char_id"]):
		charIDs.append(result["char_id"])
	return charIDs

func GetCharacterInfo(charID : int) -> Dictionary:
	var results : Array[Dictionary] = Query("SELECT * \
FROM character \
INNER JOIN stat ON character.char_id = stat.char_id \
INNER JOIN trait ON character.char_id = trait.char_id \
INNER JOIN attribute ON character.char_id = attribute.char_id \
WHERE character.char_id = %d;" % charID)
	assert(results.size() == 1, "Character information tables are missing")
	return {} if results.is_empty() else results[0]

func RefreshCharacter(player : PlayerAgent) -> bool:
	var charID : int = Peers.GetCharacter(player.peerID)
	if charID == NetworkCommons.PeerUnknownID:
		return false

	var success : bool = charID != NetworkCommons.PeerUnknownID
	success = success and UpdateAttribute(charID, player.stat)
	success = success and UpdateTrait(charID, player.stat)
	success = success and UpdateStat(charID, player.stat)
	success = success and UpdateCharacter(player)
	success = success and UpdateProgress(charID, player.progress)

	return success

func HasCharacter(nickname : String) -> bool:
	return not QueryBindings("SELECT char_id FROM character WHERE nickname = ?;", [nickname]).is_empty()

# SOM-IDLE: F4 — trade target lookup
func GetCharacterIDByName(nickname : String) -> int:
	var rows : Array[Dictionary] = QueryBindings("SELECT char_id FROM character WHERE nickname = ?;", [nickname])
	return int(rows[0]["char_id"]) if not rows.is_empty() else NetworkCommons.PeerUnknownID

func CharacterLogin(charID : int) -> bool:
	var newTimestamp : int = SQLCommons.Timestamp()
	var data : Dictionary = {
		"last_timestamp": newTimestamp
	}
	return db.update_rows("character", "char_id = %d;" % charID, data)

# Character
func GetCharacterID(accountID : int, nickname : String) -> int:
	var results : Array[Dictionary] = QueryBindings("SELECT char_id FROM character WHERE account_id = ? AND nickname = ?;", [accountID, nickname])
	assert(results.size() <= 1, "Duplicated character row for account %d and nickname '%s'" % [accountID, nickname])
	return NetworkCommons.PeerUnknownID if results.is_empty() else results[0]["char_id"]

func GetCharacter(charID : int) -> Dictionary:
	var results : Array[Dictionary] = db.select_rows("character", "char_id = %d" % charID, ["*"])
	assert(results.size() <= 1, "Duplicated character row %d" % charID)
	return {} if results.is_empty() else results[0]

func UpdateCharacter(player : PlayerAgent) -> bool:
	if player == null:
		return false

	var charID : int = Peers.GetCharacter(player.peerID)
	if charID == NetworkCommons.PeerUnknownID:
		return false

	var map : WorldMap = WorldAgent.GetMapFromAgent(player)
	var newTimestamp : int = SQLCommons.Timestamp()
	var data : Dictionary = GetCharacter(charID)

	data["total_time"] = SQLCommons.GetOrAddValue(data, "total_time", 0) + newTimestamp - SQLCommons.GetOrAddValue(data, "last_timestamp", newTimestamp)
	data["last_timestamp"] = newTimestamp

	if map != null and not map.HasFlags(WorldMap.Flags.NO_REJOIN) and ActorCommons.IsAlive(player):
		data["pos_x"] = player.position.x
		data["pos_y"] = player.position.y
		data["pos_map"] = map.id
	else:
		data["pos_x"] = player.respawnDestination.pos.x
		data["pos_y"] = player.respawnDestination.pos.y
		data["pos_map"] = player.respawnDestination.mapID

	data["respawn_x"] = player.respawnDestination.pos.x
	data["respawn_y"] = player.respawnDestination.pos.y
	data["respawn_map"] = player.respawnDestination.mapID

	if player.exploreOrigin != null:
		data["explore_x"] = player.exploreOrigin.pos.x
		data["explore_y"] = player.exploreOrigin.pos.y

	return db.update_rows("character", "char_id = %d;" % charID, data)

# Stats
func GetAttribute(charID : int) -> Dictionary:
	var results : Array[Dictionary] = db.select_rows("attribute", "char_id = %d" % charID, ["*"])
	assert(results.size() == 1, "Character attribute row is missing")
	return {} if results.is_empty() else results[0]

func UpdateAttribute(charID : int, stats : ActorStats) -> bool:
	if stats == null:
		return false

	var data : Dictionary = {
		"strength" = stats.strength,
		"vitality" = stats.vitality,
		"agility" = stats.agility,
		"endurance" = stats.endurance,
		"concentration" = stats.concentration
	}
	return db.update_rows("attribute", "char_id = %d" % charID, data)

func GetTrait(charID : int) -> Dictionary:
	var results : Array[Dictionary] = db.select_rows("trait", "char_id = %d" % charID, ["*"])
	assert(results.size() == 1, "Character trait row is missing")
	return {} if results.is_empty() else results[0]

func UpdateTrait(charID : int, stats : ActorStats) -> bool:
	if stats == null:
		return false

	var data : Dictionary = {
		"hairstyle" = stats.hairstyle,
		"haircolor" = stats.haircolor,
		"race" = stats.race,
		"skintone" = stats.skintone,
		"gender" = stats.gender,
		"shape" = stats.shape,
		"spirit" = stats.spirit
	}
	return db.update_rows("trait", "char_id = %d" % charID, data)

func GetStat(charID : int) -> Dictionary:
	var results : Array[Dictionary] = db.select_rows("stat", "char_id = %d" % charID, ["*"])
	assert(results.size() == 1, "Character stat row is missing")
	return {} if results.is_empty() else results[0]

# SOM-IDLE: F2 settle — atomic transaction wrapper for OfflineSettle
# NOTE: godot-sqlite's update_rows/delete_rows wrap their statement in their
# own BEGIN/END — calling them inside this lambda nests transactions and
# corrupts the commit sequence (nested END commits the outer work, outer
# COMMIT then fails). Inside a lambda, use UpdateRowsRaw/insert_row/
# select_rows/db.query_with_bindings ONLY — never update_rows/delete_rows
# and never the QueryBindings/ExecuteBindings helpers (queryMutex re-entry).
func Transaction(callable : Callable) -> bool:
	var committed : bool = false
	queryMutex.lock()
	if db.query("BEGIN TRANSACTION;"):
		var result : bool = callable.call()
		if result and db.query("COMMIT;"):
			committed = true
		else:
			db.query("ROLLBACK;")
	else:
		callable.call()
	queryMutex.unlock()
	return committed

# Transaction-safe UPDATE (no implicit BEGIN/END — unlike update_rows)
func UpdateRowsRaw(table : String, conditions : String, data : Dictionary) -> bool:
	var keys : PackedStringArray = PackedStringArray()
	var bindings : Array = []
	for key in data:
		keys.append("%s=?" % key)
		bindings.append(data[key])
	var query : String = "UPDATE %s SET %s WHERE %s;" % [table, ", ".join(keys), conditions]
	return db.query_with_bindings(query, bindings)

# Transaction-safe DELETE (no implicit BEGIN/END — unlike delete_rows)
func DeleteRowsRaw(table : String, conditions : String) -> bool:
	return db.query_with_bindings("DELETE FROM %s WHERE %s;" % [table, conditions], [])

# SOM-IDLE: last insert id, raw (para guild/listing criados dentro de Transaction).
func LastInsertRowIDRaw() -> int:
	if not db.query("SELECT last_insert_rowid() AS uid;"):
		return 0
	var res : Array = db.query_result
	return int(res[0].get("uid", 0)) if not res.is_empty() else 0

# SOM-IDLE B1: item lots — per-grant identity (anti-duplicação, trade history).
# Cada concessão cria um lote (uid); consumos decrementam em FIFO e apagam
# lotes zerados. Invariante: soma dos lotes ativos == stack agregada em item.
# Raw (db direto, sem mutex): chamável dentro de Transaction() e em paths com
# mutex próprio. Retorna o uid ou 0.
func GrantItemLotRaw(charID : int, itemID : int, count : int, reason : String, bound : int = 0, customfield : String = "", parentUID : int = 0) -> int:
	if count <= 0:
		return 0
	if not db.insert_row("item_instance", {
		"char_id" = charID, "item_id" = itemID, "count" = count,
		"storage" = 0, "bound" = bound, "customfield" = customfield,
		"reason" = reason, "parent_uid" = parentUID,
		"created_at" = SQLCommons.Timestamp()}):
		return 0
	if not db.query("SELECT last_insert_rowid() AS uid;"):
		return 0
	var res : Array = db.query_result
	return int(res[0].get("uid", 0)) if not res.is_empty() else 0

func _LotCondition(charID : int, itemID : int, allowBound : bool, customfield : String) -> String:
	var cond : String = "char_id = %d AND item_id = %d AND storage = 0 AND customfield = '%s'" % [charID, itemID, customfield.replace("'", "''")]
	if not allowBound:
		cond += " AND bound = 0"
	return cond

func GetLotBalanceRaw(charID : int, itemID : int, allowBound : bool = true, customfield : String = "") -> int:
	if not db.query_with_bindings("SELECT COALESCE(SUM(count), 0) AS total FROM item_instance WHERE " + _LotCondition(charID, itemID, allowBound, customfield) + ";", []):
		return 0
	var res : Array = db.query_result
	return int(res[0].get("total", 0)) if not res.is_empty() else 0

# Consome lotes em FIFO (mais antigo primeiro). Retorna os uids consumidos ou
# []. Dentro de Transaction(), falhar reverte parciais (all-or-nothing).
func ConsumeItemLotsRaw(charID : int, itemID : int, count : int, allowBound : bool = false, customfield : String = "") -> Array:
	if count <= 0:
		return []
	var cond : String = _LotCondition(charID, itemID, allowBound, customfield)
	if GetLotBalanceRaw(charID, itemID, allowBound, customfield) < count:
		return []
	if not db.query_with_bindings("SELECT uid, count FROM item_instance WHERE " + cond + " ORDER BY uid;", []):
		return []
	var lots : Array = (db.query_result as Array).duplicate()
	var consumed : Array = []
	var remaining : int = count
	for lot in lots:
		if remaining <= 0:
			break
		var uid : int = int(lot["uid"])
		var have : int = int(lot["count"])
		var take : int = mini(have, remaining)
		if take >= have:
			if not DeleteRowsRaw("item_instance", "uid = %d" % uid):
				return []
		elif not UpdateRowsRaw("item_instance", "uid = %d" % uid, {"count" = have - take}):
			return []
		consumed.append(uid)
		remaining -= take
	return consumed if remaining == 0 else []

# SOM-IDLE: F2 settle — direct stat row writes (level/xp/gold) without an agent
func UpdateStatDirect(charID : int, newLevel : int, newExperience : int, newGold : int) -> bool:
	var data : Dictionary = {
		"level" = newLevel,
		"experience" = newExperience,
		"gp" = newGold,
	}
	return UpdateRowsRaw("stat", "char_id = %d" % charID, data)

# SOM-IDLE: F2 settle — insert settled drops into the character inventory
# NOTE: uses db.* directly (never QueryBindings) so it stays callable inside
# Transaction() without re-locking queryMutex.
# SOM-IDLE B1: espelha a concessão em item_instance (lote com uid).
func AddItemToCharacter(charID : int, itemID : int, count : int, reason : String = "settle") -> bool:
	# NOTE: sem ";" final — select_rows ignora a query silenciosamente com ";" (bug F3).
	var existing : Array[Dictionary] = db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	var ok : bool = false
	if not existing.is_empty():
		ok = UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = int(existing[0]["count"]) + count})
	else:
		ok = db.insert_row("item", {"item_id" = itemID, "char_id" = charID, "count" = count, "storage" = 0, "customfield" = ""})
	return ok and GrantItemLotRaw(charID, itemID, count, reason) != 0

# SOM-IDLE: F2 settle — anchor + efficiency reset
func UpdateSettleAnchor(charID : int, lastSettledAt : int, efficiency : float) -> bool:
	return UpdateRowsRaw("character", "char_id = %d" % charID, {"last_settled_at" = lastSettledAt, "session_efficiency" = efficiency})

# SOM-IDLE: F2 chests — instance rows only (opening is F4 scope)
func AddChestInstance(charID : int, chestHash : int, origin : String) -> bool:
	return db.insert_row("chest_instance", {"char_id" = charID, "chest_hash" = chestHash, "origin" = origin, "item_state" = "closed", "created_at" = SQLCommons.Timestamp()})

# SOM-IDLE: F2 formations — loadout + auto-potion per account slot
func SaveFormation(accountID : int, slot : int, charID : int, skillLoadout : Array[int], autoPotionPct : float) -> bool:
	var loadout : String = var_to_str(skillLoadout)
	# NOTE: update_rows reports success even when no row matched, so an
	# update-or-insert chain short-circuits and silently writes nothing (F3 fix).
	if GetFormationForSlot(accountID, slot).is_empty():
		return db.insert_row("formation", {
			"account_id" = accountID,
			"slot" = slot,
			"char_id" = charID,
			"skill_loadout" = loadout,
			"auto_potion_pct" = autoPotionPct,
		})
	return db.update_rows("formation", "account_id = %d AND slot = %d" % [accountID, slot], {
		"char_id" = charID,
		"skill_loadout" = loadout,
		"auto_potion_pct" = autoPotionPct,
	})

func GetFormationForCharacter(charID : int) -> Dictionary:
	var rows : Array[Dictionary] = QueryBindings("SELECT * FROM formation WHERE char_id = ? ORDER BY slot LIMIT 1;", [charID])
	return {} if rows.is_empty() else rows[0]

# SOM-IDLE: F2 — character farm zone binding
func SetCharacterFarmZone(charID : int, zoneID : int) -> bool:
	return db.update_rows("character", "char_id = %d" % charID, {"farm_zone" = zoneID})

# SOM-IDLE: boss-key ladder (migration 019). boss_keys é coluna do character
# (progressão por char, como farm_zone). AddClamped nunca deixa ir abaixo de 0,
# então um gasto nunca fica negativo numa corrida de RPC.
# delta<0 = gastar. Retorna o saldo novo (>=0) ou -1 se o char não existe.
# NOTA: usa db.* CRU (select_rows/update_rows), não QueryBindings — estes
# métodos são chamados de dentro de SQL.Transaction() (GrantBossKey/offline
# settle), onde QueryBindings trava o queryMutex e corrompe a transação.
func GetCharacterBossKeys(charID : int) -> int:
	var rows : Array = db.select_rows("character", "char_id = %d" % charID, ["boss_keys"])
	if rows.is_empty():
		return -1
	var value : Variant = rows[0].get("boss_keys", 0)
	return 0 if value == null else int(value)

func AddCharacterBossKeys(charID : int, delta : int) -> int:
	var current : int = GetCharacterBossKeys(charID)
	if current < 0:
		return -1
	var next : int = maxi(0, current + delta)
	# UpdateRowsRaw: db.update_rows faz BEGIN/COMMIT implícitos e não pode rodar
	# dentro de um Transaction() (GrantBossKey/SpendBossKey/offline settle).
	UpdateRowsRaw("character", "char_id = %d" % charID, {"boss_keys" = next})
	return next

func GetCharacterBossesBeaten(charID : int) -> int:
	var rows : Array = db.select_rows("character", "char_id = %d" % charID, ["bosses_beaten"])
	if rows.is_empty():
		return 0
	var value : Variant = rows[0].get("bosses_beaten", 0)
	return 0 if value == null else int(value)

func SetCharacterBossesBeaten(charID : int, count : int) -> bool:
	return db.update_rows("character", "char_id = %d" % charID, {"bosses_beaten" = maxi(0, count)})

# SOM-IDLE: F2 — persist live session efficiency on disconnect (NetServer hook)
func PersistSessionEfficiency(charID : int, efficiency : float) -> bool:
	return db.update_rows("character", "char_id = %d" % charID, {"session_efficiency" = efficiency})

# SOM-IDLE: F2 — ownership check for formation RPCs
func GetAccountIDForCharacter(charID : int) -> int:
	var rows : Array[Dictionary] = QueryBindings("SELECT account_id FROM character WHERE char_id = ?;", [charID])
	return int(rows[0]["account_id"]) if not rows.is_empty() else NetworkCommons.PeerUnknownID

# SOM-IDLE: F3 — formation slot selector (multiple loadouts per account)
func GetFormationForSlot(accountID : int, slot : int) -> Dictionary:
	var rows : Array[Dictionary] = QueryBindings("SELECT * FROM formation WHERE account_id = ? AND slot = ?;", [accountID, slot])
	return {} if rows.is_empty() else rows[0]

func SetCharacterFormationSlot(charID : int, slot : int) -> bool:
	return db.update_rows("character", "char_id = %d" % charID, {"formation_slot" = slot})

# SOM-IDLE: F3 — VIP window (MONETIZATION §2.2: +20% idle faucet while active)
func GetVIPUntil(accountID : int) -> int:
	var rows : Array[Dictionary] = QueryBindings("SELECT vip_until FROM account WHERE account_id = ?;", [accountID])
	var value : Variant = rows[0].get("vip_until", 0) if not rows.is_empty() else 0
	return 0 if value == null else int(value)

func SetVIPUntil(accountID : int, untilTimestamp : int) -> bool:
	return db.update_rows("account", "account_id = %d" % accountID, {"vip_until" = untilTimestamp})

# SOM-IDLE: F3 — cached power score for the offline leaderboard
func UpdatePowerScore(charID : int, score : int) -> bool:
	return db.update_rows("character", "char_id = %d" % charID, {"power_score" = score})

func GetLeaderboard(limit : int = 50) -> Array[Dictionary]:
	return QueryBindings("SELECT c.char_id, c.nickname, s.level, c.power_score, a.username \
FROM character AS c INNER JOIN account AS a ON c.account_id = a.account_id \
INNER JOIN stat AS s ON s.char_id = c.char_id \
ORDER BY c.power_score DESC, c.char_id ASC LIMIT ?;", [limit])

# SOM-IDLE: F4 — chest instance queries
func GetClosedChests(charID : int) -> Array[Dictionary]:
	return QueryBindings("SELECT id, chest_hash, origin, created_at FROM chest_instance WHERE char_id = ? AND item_state = 'closed' ORDER BY id;", [charID])

func GetChestStats(charID : int) -> Dictionary:
	var opened : int = int(QueryBindings("SELECT COUNT(*) AS n FROM chest_instance WHERE char_id = ? AND item_state = 'opened';", [charID])[0]["n"])
	var closed : int = int(QueryBindings("SELECT COUNT(*) AS n FROM chest_instance WHERE char_id = ? AND item_state = 'closed';", [charID])[0]["n"])
	return {"opened" = opened, "closed" = closed}

func GetGems(accountID : int) -> int:
	var rows : Array[Dictionary] = QueryBindings("SELECT gems FROM wallet WHERE account_id = ?;", [accountID])
	var value : Variant = rows[0].get("gems", 0) if not rows.is_empty() else 0
	return 0 if value == null else int(value)

func SetGems(accountID : int, gems : int) -> bool:
	# NOTE: update_rows reports success on 0 matched rows — gate the insert on
	# row existence explicitly (same trap as SaveFormation, F3 report §bugs).
	if QueryBindings("SELECT account_id FROM wallet WHERE account_id = ?;", [accountID]).is_empty():
		return db.insert_row("wallet", {"account_id" = accountID, "gems" = gems, "updated_at" = SQLCommons.Timestamp()})
	return db.update_rows("wallet", "account_id = %d" % accountID, {"gems" = gems, "updated_at" = SQLCommons.Timestamp()})

# db-direct variants for use INSIDE SQL.Transaction() lambdas (no queryMutex,
# no implicit update_rows transaction wrapper)
func GetGemsRaw(accountID : int) -> int:
	var rows : Array[Dictionary] = db.select_rows("wallet", "account_id = %d" % accountID, ["gems"])
	var value : Variant = rows[0].get("gems", 0) if not rows.is_empty() else 0
	return 0 if value == null else int(value)

func SetGemsRaw(accountID : int, gems : int) -> bool:
	# NOTE: update_rows reports success on 0 matched rows — gate the insert on
	# row existence explicitly (same trap as SaveFormation, F3 report §bugs).
	if db.select_rows("wallet", "account_id = %d" % accountID, ["account_id"]).is_empty():
		return db.insert_row("wallet", {"account_id" = accountID, "gems" = gems, "updated_at" = SQLCommons.Timestamp()})
	return UpdateRowsRaw("wallet", "account_id = %d" % accountID, {"gems" = gems, "updated_at" = SQLCommons.Timestamp()})

func UpdateStat(charID : int, stats : ActorStats) -> bool:
	if stats == null:
		return false

	var data : Dictionary = {
		"level" = stats.level,
		"experience" = stats.experience,
		"gp" = stats.gp,
		"health" = max(1, stats.health),
		"mana" = stats.mana,
		"stamina" = stats.stamina,
		"karma" = stats.karma
	}
	return db.update_rows("stat", "char_id = %d" % charID, data)

# Inventory
func GetItem(charID : int, itemID : int, customfield : String, storageType : int = 0) -> Dictionary:
	var results : Array[Dictionary] = QueryBindings("SELECT * FROM item WHERE item_id = ? AND char_id = ? AND storage = ? AND customfield = ?;", [itemID, charID, storageType, customfield])
	assert(results.size() <= 1, "Duplicated item %d on character %d with storage %d" % [itemID, charID, storageType])
	return {} if results.is_empty() else results[0]

func AddItem(charID : int, itemID : int, customfield : String, itemCount : int = 1, storageType : int = 0) -> bool:
	var data : Dictionary = GetItem(charID, itemID, customfield, storageType)
	# Increment item count
	if not data.is_empty():
		if not ExecuteBindings("UPDATE item SET count = ? WHERE item_id = ? AND char_id = ? AND storage = ? AND customfield = ?;", [data["count"] + 1, itemID, charID, storageType, customfield]):
			return false
		# SOM-IDLE B1: journal da concessão (upstream incrementa de 1 em 1 aqui).
		return true if storageType != 0 else GrantItemLotRaw(charID, itemID, 1, "world", 0, customfield) != 0

	# Insert new item
	data = {
		"item_id": itemID,
		"char_id": charID,
		"count": itemCount,
		"storage": storageType,
		"customfield": customfield
	}
	if not db.insert_row("item", data):
		return false
	# SOM-IDLE B1: journal da concessão.
	return true if storageType != 0 else GrantItemLotRaw(charID, itemID, itemCount, "world", 0, customfield) != 0

func RemoveItem(charID : int, itemID : int, customfield : String, itemCount : int = 1, storageType : int = 0) -> bool:
	var data : Dictionary = GetItem(charID, itemID, customfield, storageType)
	if data.is_empty():
		return false
	# SOM-IDLE B1: consome os lotes primeiro (rejeita sem lotes suficientes).
	if storageType == 0 and ConsumeItemLotsRaw(charID, itemID, itemCount, true, customfield).is_empty():
		return false
	# Decrement item count
	if data["count"] > itemCount:
		return ExecuteBindings("UPDATE item SET count = ? WHERE item_id = ? AND char_id = ? AND storage = ? AND customfield = ?;", [data["count"] - itemCount, itemID, charID, storageType, customfield])
	# Remove item
	elif data["count"] == itemCount:
		return ExecuteBindings("DELETE FROM item WHERE item_id = ? AND char_id = ? AND storage = ? AND customfield = ?;", [itemID, charID, storageType, customfield])
	return false

func GetStorage(charID : int, storageType : int = 0) -> Array[Dictionary]:
	return db.select_rows("item", "char_id = %d AND storage = %d" % [charID, storageType], ["*"])

# Equipment
func GetEquipment(charID : int) -> Dictionary:
	var results : Array[Dictionary] = db.select_rows("equipment", "char_id = %d" % charID, ["*"])
	assert(results.size() <= 1, "Duplicated equipment on character %d" % charID)
	return {} if results.is_empty() else results[0]

func UpdateEquipment(charID : int, data : Dictionary) -> bool:
	return db.update_rows("equipment", "char_id = %d" % charID, data)

# Progress
func UpdateProgress(charID : int, progress : ActorProgress):
	progress.questMutex.lock()
	for entryID in progress.quests:
		Launcher.SQL.SetQuest(charID, entryID, progress.quests[entryID])
	progress.questMutex.unlock()

	progress.bestiaryMutex.lock()
	for entryID in progress.bestiary:
		Launcher.SQL.SetBestiary(charID, entryID, progress.bestiary[entryID])
	progress.bestiaryMutex.unlock()

	for entryID in progress.skills:
		Launcher.SQL.SetSkill(charID, entryID, progress.skills[entryID])

	return true

# Skill
func SetSkill(charID : int, skillID : int, value : int) -> bool:
	var results : Array[Dictionary] = db.select_rows("skill", "char_id = %d AND skill_id = %d" % [charID, skillID], ["*"])
	assert(results.size() <= 1, "Duplicated skill for %d on character %d" % [skillID, charID])

	if not results.is_empty():
		results[0]["level"] = value
		return db.update_rows("skill", "char_id = %d AND skill_id = %d" % [charID, skillID], results[0])

	var data : Dictionary = {
		"char_id": charID,
		"skill_id": skillID,
		"level": value,
	}
	return db.insert_row("skill", data)

func GetSkills(charID : int) -> Array[Dictionary]:
	return db.select_rows("skill", "char_id = %d" % [charID], ["*"])

# Bestiary
func SetBestiary(charID : int, mobID : int, value : int) -> bool:
	var results : Array[Dictionary] = db.select_rows("bestiary", "char_id = %d AND mob_id = %d" % [charID, mobID], ["*"])
	assert(results.size() <= 1, "Duplicated bestiary row for %d on character %d" % [mobID, charID])

	if not results.is_empty():
		results[0]["killed_count"] = value
		return db.update_rows("bestiary", "char_id = %d AND mob_id = %d" % [charID, mobID], results[0])

	var data : Dictionary = {
		"char_id": charID,
		"mob_id": mobID,
		"killed_count": value,
	}
	return db.insert_row("bestiary", data)

func GetBestiaries(charID : int) -> Array[Dictionary]:
	return db.select_rows("bestiary", "char_id = %d" % [charID], ["*"])

# Quest
func SetQuest(charID : int, questID : int, value : int) -> bool:
	var results : Array[Dictionary] = db.select_rows("quest", "char_id = %d AND quest_id = %d" % [charID, questID], ["*"])
	assert(results.size() <= 1, "Duplicated quest row for %d on character %d" % [questID, charID])

	if not results.is_empty():
		results[0]["state"] = value
		return db.update_rows("quest", "char_id = %d AND quest_id = %d" % [charID, questID], results[0])

	var data : Dictionary = {
		"char_id": charID,
		"quest_id": questID,
		"state": value,
	}
	return db.insert_row("quest", data)

func GetQuests(charID : int) -> Array[Dictionary]:
	return db.select_rows("quest", "char_id = %d" % [charID], ["*"])

# Auth Token
func AddAuthToken(accountID : int, tokenHash : String, ipAddress : String) -> bool:
	ExecuteBindings("DELETE FROM auth_token WHERE account_id = ? AND ip_address = ?;", [accountID, ipAddress])
	var now : int = SQLCommons.Timestamp()
	var data : Dictionary = {
		"token_hash": tokenHash,
		"account_id": accountID,
		"ip_address": ipAddress,
		"created_timestamp": now,
		"expires_timestamp": now + NetworkCommons.TokenExpirySec,
	}
	return db.insert_row("auth_token", data)

func ValidateAuthToken(accountID : int, tokenHash : String, ipAddress : String) -> Peers.AccountData:
	var results : Array[Dictionary] = QueryBindings("SELECT auth_token.account_id, auth_token.expires_timestamp, account.permission FROM auth_token INNER JOIN account ON auth_token.account_id = account.account_id WHERE auth_token.account_id = ? AND auth_token.token_hash = ? AND auth_token.ip_address = ?;", [accountID, tokenHash, ipAddress])
	if not results.is_empty():
		if results[0].get("expires_timestamp", 0) <= SQLCommons.Timestamp():
			RemoveAuthToken(accountID, tokenHash)
			return null
		var permission : Variant = results[0].get("permission", null)
		if not permission:
			permission = ActorCommons.Permission.NONE
		return Peers.AccountData.new(accountID, permission)
	return null

func RefreshAuthToken(accountID : int, ipAddress : String) -> bool:
	return ExecuteBindings("UPDATE auth_token SET expires_timestamp = ? WHERE account_id = ? AND ip_address = ?;", [SQLCommons.Timestamp() + NetworkCommons.TokenExpirySec, accountID, ipAddress])

func RemoveAuthToken(accountID : int, tokenHash : String) -> bool:
	return ExecuteBindings("DELETE FROM auth_token WHERE account_id = ? AND token_hash = ?;", [accountID, tokenHash])

func CleanExpiredTokens():
	db.delete_rows("auth_token", "expires_timestamp <= %d" % SQLCommons.Timestamp())

func GetAccountEmail(accountID : int) -> String:
	var results : Array[Dictionary] = QueryBindings("SELECT email FROM account WHERE account_id = ?;", [accountID])
	if not results.is_empty():
		var email : Variant = results[0].get("email", null)
		if email is String:
			return email
	return ""

func CheckAccountPassword(accountID : int, triedPassword : String) -> bool:
	var results : Array[Dictionary] = QueryBindings("SELECT password, password_salt, hash_ver FROM account WHERE account_id = ?;", [accountID])
	if results.is_empty():
		return false
	return Hasher.VerifyPassword(triedPassword, results[0]["password_salt"], results[0]["password"], int(results[0].get("hash_ver", 0)))

func UpdateAccountPassword(accountID : int, newPassword : String) -> bool:
	var salt : String = Hasher.GenerateSalt()
	var hashedPassword : String = Hasher.HashPasswordV1(newPassword, salt)
	return ExecuteBindings("UPDATE account SET password = ?, password_salt = ?, hash_ver = ?, failed_attempts = 0, locked_until = 0 WHERE account_id = ?;", [hashedPassword, salt, Hasher.HashVersion, accountID])

func RemoveAllAuthTokens(accountID : int) -> bool:
	return ExecuteBindings("DELETE FROM auth_token WHERE account_id = ?;", [accountID])

# Ban
func BanAccount(accountID : int, unbanTimestamp : int, reason : String = "") -> bool:
	var results : Array[Dictionary] = db.select_rows("ban", "account_id = %d" % accountID, ["*"])
	var data : Dictionary = {
		"account_id": accountID,
		"banned_timestamp": SQLCommons.Timestamp(),
		"unban_timestamp": unbanTimestamp,
		"reason": reason,
	}
	if not results.is_empty():
		return db.update_rows("ban", "account_id = %d" % accountID, data)
	return db.insert_row("ban", data)

func UnbanAccount(accountID : int) -> bool:
	return db.delete_rows("ban", "account_id = %d" % accountID)

func LoadBans() -> Dictionary[int, int]:
	var bans : Dictionary[int, int] = {}
	var now : int = SQLCommons.Timestamp()
	var results : Array[Dictionary] = Query("SELECT account_id, unban_timestamp FROM ban WHERE unban_timestamp > %d;" % now)
	for row in results:
		bans[row["account_id"]] = row["unban_timestamp"]
	return bans

# IP Ban
func BanIPRange(ipRange : String, reason : String = "") -> bool:
	var results : Array[Dictionary] = QueryBindings("SELECT ip_range FROM ip_ban WHERE ip_range = ?;", [ipRange])
	var data : Dictionary = {
		"ip_range": ipRange,
		"banned_timestamp": SQLCommons.Timestamp(),
		"reason": reason,
	}
	if not results.is_empty():
		return db.update_rows("ip_ban", "ip_range = '%s'" % ipRange, data)
	return db.insert_row("ip_ban", data)

func UnbanIPRange(ipRange : String) -> bool:
	return ExecuteBindings("DELETE FROM ip_ban WHERE ip_range = ?;", [ipRange])

func LoadIPBans() -> Dictionary[String, String]:
	var bans : Dictionary[String, String] = {}
	var results : Array[Dictionary] = Query("SELECT ip_range, reason FROM ip_ban;")
	for row in results:
		bans[row["ip_range"]] = row.get("reason", "")
	return bans

func GetIPBanList(filter : String = "") -> Array[Dictionary]:
	if filter.is_empty():
		return Query("SELECT ip_range, banned_timestamp, reason FROM ip_ban;")
	return QueryBindings("SELECT ip_range, banned_timestamp, reason FROM ip_ban WHERE ip_range LIKE ?;", ["%" + filter + "%"])

func GetAccountID(username : String) -> int:
	var results : Array[Dictionary] = QueryBindings("SELECT account_id FROM account WHERE username = ?;", [username])
	if not results.is_empty():
		return results[0].get("account_id", NetworkCommons.PeerUnknownID)
	return NetworkCommons.PeerUnknownID

func SetPermission(accountID : int, permission : int) -> bool:
	var data : Dictionary = { "permission": permission }
	return db.update_rows("account", "account_id = %d" % accountID, data)

func GetBanList(filter : String = "") -> Array[Dictionary]:
	var now : int = SQLCommons.Timestamp()
	if filter.is_empty():
		return Query("SELECT ban.account_id, account.username, ban.unban_timestamp, ban.reason FROM ban INNER JOIN account ON ban.account_id = account.account_id WHERE ban.unban_timestamp > %d;" % now)
	return QueryBindings("SELECT ban.account_id, account.username, ban.unban_timestamp, ban.reason FROM ban INNER JOIN account ON ban.account_id = account.account_id WHERE ban.unban_timestamp > ? AND account.username LIKE ?;", [now, "%" + filter + "%"])

# Commons
func Query(query : String) -> Array[Dictionary]:
	var data : Array[Dictionary] = []
	queryMutex.lock()
	if db.query(query):
		data = db.query_result
	queryMutex.unlock()
	return data

func QueryBindings(query : String, params : Array) -> Array[Dictionary]:
	var data : Array[Dictionary] = []
	queryMutex.lock()
	if db.query_with_bindings(query, params):
		data = db.query_result
	queryMutex.unlock()
	return data

func ExecuteBindings(query : String, params : Array) -> bool:
	queryMutex.lock()
	var ret : bool = db.query_with_bindings(query, params)
	queryMutex.unlock()
	return ret

#
func _post_launch():
	var dbPath : String = SQLCommons.GetDBPath()
	if not FileSystem.FileExists(dbPath) and not SQLCommons.CopyDatabase(dbPath):
		return

	db = SQLite.new()
	db.path = dbPath
	db.verbosity_level = SQLCommons.Verbosity

	if not db.open_db():
		assert(false, "Failed to open database: "+ db.error_message)
	else:
		if OS.is_debug_build() and not LauncherCommons.isWeb:
			Query("PRAGMA journal_mode=WAL;")
			Query("PRAGMA busy_timeout=5000;")
		if not Launcher.Debug and not LauncherCommons.isWeb:
			backups = SQLBackups.new()

	ApplyMigrations()
	Peers.bannedAccounts = LoadBans()
	Peers.bannedIPRanges = LoadIPBans()
	CleanExpiredTokens()

	isInitialized = true

func Destroy():
	if backups:
		backups.Stop()
	if db:
		db.close_db()

func Wipe():
	db.delete_rows("account", "")
	db.delete_rows("attribute", "")
	db.delete_rows("auth_token", "")
	db.delete_rows("ban", "")
	db.delete_rows("bestiary", "")
	db.delete_rows("character", "")
	db.delete_rows("equipment", "")
	db.delete_rows("ip_ban", "")
	db.delete_rows("item", "")
	db.delete_rows("item_instance", "")
	db.delete_rows("quest", "")
	db.delete_rows("skill", "")
	db.delete_rows("sqlite_sequence", "")
	db.delete_rows("stat", "")
	db.delete_rows("trait", "")
