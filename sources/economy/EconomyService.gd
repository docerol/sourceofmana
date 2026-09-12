extends ServiceBase
class_name EconomyService

# SOM-IDLE: F2 idle-spike economy service (TECH_SPEC_CORE.md §4 + ECONOMY_STUDY.md)
# Spike scope: settle-path ledger writes + balance/audit helpers.
# ExecuteTrade/OpenChest are documented stubs (F4 scope) and always return false.

const LedgerKindGold : String = "gold"
const LedgerKindXP : String = "xp"
const LedgerKindItem : String = "item"
const LedgerKindGems : String = "gems"
const LedgerKindBossKey : String = "boss_key"

var settleMutex : Mutex						= Mutex.new()

# SOM-IDLE C1: companion grant poll (main thread, vazio = no-op barato).
const GrantPollSec : float = 30.0
var _grantPollAccum : float = 0.0

func _process(delta : float) -> void:
	if not isInitialized:
		return
	_grantPollAccum += delta
	if _grantPollAccum >= GrantPollSec:
		_grantPollAccum = 0.0
		ProcessPendingGrants(20)

#
func _post_launch():
	isInitialized = true

func Destroy():
	isInitialized = false

# ------------------------------------------------------------------ wallet

func GetBalance(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT balance_after FROM ledger_transaction WHERE account_id = ? ORDER BY id DESC LIMIT 1;",
		[accountID])
	return int(rows[0]["balance_after"]) if not rows.is_empty() else 0

func GetGoldLedgerSum(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COALESCE(SUM(amount), 0) AS total FROM ledger_transaction WHERE account_id = ? AND kind = ?;",
		[accountID, LedgerKindGold])
	return int(rows[0]["total"]) if not rows.is_empty() else 0

# ------------------------------------------------------------------ ledger

# Append-only ledger write; MUST be called inside the same transaction as the
# state mutation it mirrors (see OfflineSettle._Apply). Uses db.* directly —
# it runs inside SQL.Transaction() which already holds queryMutex.
func LedgerAppend(charID : int, accountID : int, kind : String, amount : int, balanceAfter : int, reason : String = "") -> bool:
	var dbNode : SQLite = Launcher.SQL.db
	return dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[accountID, charID, kind, amount, balanceAfter, reason, SQLCommons.Timestamp()])

# ------------------------------------------------------------------ item ops (account-bound stash paths, used by F3/F4)

func GrantItem(accountID : int, itemHash : int, count : int, reason : String = "") -> bool:
	settleMutex.lock()
	var dbNode : SQLite = Launcher.SQL.db
	var ok : bool = dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, 0, ?, ?, 0, ?, ?);",
		[accountID, LedgerKindItem, count, reason, SQLCommons.Timestamp()])
	settleMutex.unlock()
	return ok

func RemoveItem(uid : int) -> bool:
	# Item rows are hard-owned by the item table; F2 does not delete items here.
	return false

# ------------------------------------------------------------------ settle path

func SettleTransaction(charID : int, report : Dictionary) -> bool:
	settleMutex.lock()
	var ok : bool = not OfflineSettle.SettlePending(charID).is_empty()
	settleMutex.unlock()
	return ok

# ------------------------------------------------------------------ wallet (gems; gold remains stat.gp per ARCHITECTURE §9)

func GetGems(accountID : int) -> int:
	return Launcher.SQL.GetGems(accountID)

# Single gems mutation path: wallet.gems is the source of truth, the ledger
# row mirrors it (invariant 1). Composed mutations inside an open transaction
# (ExecuteTrade fee) use SetGems + _LedgerAppendLocked directly.
func AddGems(accountID : int, amount : int, reason : String) -> bool:
	if amount == 0:
		return false
	settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetGemsRaw(accountID)
		var newBalance : int = current + amount
		if newBalance < 0:
			return false
		if not Launcher.SQL.SetGemsRaw(accountID, newBalance):
			return false
		return _LedgerAppendLocked(accountID, 0, LedgerKindGems, amount, newBalance, reason)):
		ok = true
	settleMutex.unlock()
	return ok

# ------------------------------------------------------------------ boss keys (character column + ledger mirror)
# SOM-IDLE: boss-key ladder. boss_keys vive no character (progressão por char,
# como farm_zone); o ledger só espelha os fluxos para auditoria. GrantBossKey é o
# único caminho de drop; SpendBossKey retorna false se não houver chave (nunca
# negativa). Retorna o saldo novo (>=0) ou -1 em falha.
func GrantBossKey(charID : int, amount : int, reason : String) -> int:
	if amount == 0:
		return Launcher.SQL.GetCharacterBossKeys(charID)
	var applied : bool = false
	settleMutex.lock()
	# GDScript closures capture by VALUE: we cannot read `result` back out of the
	# transaction closure, so we re-query the (now committed) column after commit.
	if Launcher.SQL.Transaction(func() -> bool:
		var next : int = Launcher.SQL.AddCharacterBossKeys(charID, amount)
		if next < 0:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindBossKey, amount, next, reason)):
		applied = true
	settleMutex.unlock()
	return Launcher.SQL.GetCharacterBossKeys(charID) if applied else -1

func SpendBossKey(charID : int, amount : int, reason : String) -> bool:
	if amount <= 0:
		return false
	settleMutex.lock()
	var ok : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var current : int = Launcher.SQL.GetCharacterBossKeys(charID)
		if current < amount:
			return false
		var next : int = current - amount
		if Launcher.SQL.AddCharacterBossKeys(charID, -amount) == -1:
			return false
		var acct : int = _AccountIDForCharacterRaw(charID)
		return _LedgerAppendLocked(acct, charID, LedgerKindBossKey, -amount, next, reason)):
		ok = true
	settleMutex.unlock()
	return ok

# ------------------------------------------------------------------ boss ladder (state + challenge)
# SOM-IDLE: a escada é sequencial — o próximo boss desafiável é sempre o índice
# `beaten`. O boss escala ao nível do char. A resolução é a sim de duelo do
# BossService (determinística); aqui só validamos, gastamos a chave, entregamos
# xp/gold/chance de drop e persistimos o progresso.

func GetBossState(charID : int, playerLevel : int) -> Dictionary:
	var beaten : int = Launcher.SQL.GetCharacterBossesBeaten(charID)
	var bosses : Array = []
	for i in BossService.GetBossCount():
		var bl : int = BossService.GetBossLevel(playerLevel, i)
		bosses.append({
			"index" = i,
			"name" = BossService.GetBossName(i),
			"level" = bl,
			"hp" = BossService.GetBossMaxHealth(bl),
			"beaten" = i < beaten,
			"next" = i == beaten,
		})
	return {
		"keys" = Launcher.SQL.GetCharacterBossKeys(charID),
		"beaten" = beaten,
		"count" = BossService.GetBossCount(),
		"level" = playerLevel,
		"bosses" = bosses,
	}

# Retorna o resultado do desafio (ok=false + reason em falha de validação).
# `player` é o PlayerAgent online (precisamos das stats reais para a sim e para
# entregar xp/gold no agente).
func ChallengeBoss(charID : int, player) -> Dictionary:
	if player == null or not is_instance_valid(player) or player.stat == null:
		return {"ok" = false, "reason" = "not_online"}

	var index : int = Launcher.SQL.GetCharacterBossesBeaten(charID)
	if index >= BossService.GetBossCount():
		return {"ok" = false, "reason" = "ladder_complete"}

	# A escada é sequencial: o índice é fixo (próximo não-vencido). Se o cliente
	# quiser insistir num boss já vencido, nada a fazer.
	if Launcher.SQL.GetCharacterBossKeys(charID) < 1:
		return {"ok" = false, "reason" = "no_key"}

	if not SpendBossKey(charID, 1, "boss_challenge"):
		return {"ok" = false, "reason" = "spend_failed"}

	var bossLevel : int = BossService.GetBossLevel(player.stat.level, index)
	var snapshot : Dictionary = BossService.PlayerFightSnapshot(player)
	var duel : Dictionary = BossService.Resolve(snapshot, bossLevel)
	var win : bool = bool(duel.get("win", false))

	# referência de xp = zona de farm atual do char
	var charRow : Dictionary = Launcher.SQL.GetCharacter(charID)
	var zoneID : int = int(charRow.get("farm_zone", 1) if charRow.get("farm_zone", 1) != null else 1)
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	var zoneXp : int = zone.xpPerKill if zone != null else FarmZoneData.XpBasePerKill
	var accountID : int = Launcher.SQL.GetAccountIDForCharacter(charID)
	var vipActive : bool = Launcher.SQL.GetVIPUntil(accountID) > SQLCommons.Timestamp()
	var vipMult : float = OfflineSettle.VIPModFactor if vipActive else 1.0
	var newbie : bool = player.stat.level < FarmZoneData.NewbieBoostMaxLevel
	var nb : float = float(FarmZoneData.NewbieBoostFactor) if newbie else 1.0

	var baseXp : int = BossService.VictoryXp(zoneXp) if win else BossService.ConsolationXp(zoneXp)
	var xpGrant : int = maxi(1, roundi(float(baseXp) * nb * vipMult))
	player.stat.AddExperience(xpGrant, false)
	var goldGrant : int = 0
	if win:
		goldGrant = roundi(float(BossService.VictoryGold(zoneXp)) * nb * vipMult)
		player.stat.AddGP(goldGrant, false)

	var chestsGranted : int = 0
	if win:
		for i in BossService.BossChestReward:
			if Launcher.SQL.AddChestInstance(charID, FarmZoneData.DefaultDropItemHash, "boss"):
				chestsGranted += 1
		Launcher.SQL.SetCharacterBossesBeaten(charID, index + 1)

	return {
		"ok" = true,
		"win" = win,
		"index" = index,
		"boss" = BossService.GetBossName(index),
		"level" = bossLevel,
		"duration" = roundf(float(duel.get("duration", 0.0))),
		"xp" = xpGrant,
		"gold" = goldGrant,
		"chests" = chestsGranted,
		"keys" = Launcher.SQL.GetCharacterBossKeys(charID),
		"beaten" = Launcher.SQL.GetCharacterBossesBeaten(charID),
	}

# ------------------------------------------------------------------ F4: real implementations

# Locked variant for use INSIDE an open SQL.Transaction() (no mutex re-entry).
# wallet.gems is the gems source of truth; ledger rows mirror every mutation.
func _LedgerAppendLocked(accountID : int, charID : int, kind : String, amount : int, balanceAfter : int, reason : String) -> bool:
	var dbNode : SQLite = Launcher.SQL.db
	return dbNode.query_with_bindings(
		"INSERT INTO ledger_transaction (account_id, char_id, kind, amount, balance_after, reason, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
		[accountID, charID, kind, amount, balanceAfter, reason, SQLCommons.Timestamp()])

# Transaction-internal raw helpers (no mutex, no implicit transactions)
func _AccountIDForCharacterRaw(charID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.db.select_rows("character", "char_id = %d" % charID, ["account_id"])
	return int(rows[0]["account_id"]) if not rows.is_empty() else NetworkCommons.PeerUnknownID

func _ItemCountRaw(charID : int, itemID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	return 0 if rows.is_empty() else int(rows[0].get("count", 0) if rows[0].get("count", 0) != null else 0)

func _MoveStack(charFrom : int, charTo : int, itemID : int, count : int) -> bool:
	return not _MoveStackUIDs(charFrom, charTo, itemID, count).is_empty()

# SOM-IDLE B1: move com identidade de lote — consome lotes FIFO (somente
# unbound: cosméticos bound não negociam), move o agregado e concede lote
# encadeado (parent_uid) no receptor. Retorna {"consumed": [...], "granted": uid}.
func _MoveStackUIDs(charFrom : int, charTo : int, itemID : int, count : int) -> Dictionary:
	var sql : SQLService = Launcher.SQL
	var consumed : Array = sql.ConsumeItemLotsRaw(charFrom, itemID, count, false)
	if consumed.is_empty():
		return {}
	var sourceCount : int = _ItemCountRaw(charFrom, itemID)
	var moved : bool = false
	if sourceCount > count:
		moved = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom], {"count" = sourceCount - count})
	elif sourceCount == count:
		moved = sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom])
	if not moved:
		return {}
	var targetCount : int = _ItemCountRaw(charTo, itemID)
	if targetCount > 0:
		moved = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charTo], {"count" = targetCount + count})
	else:
		moved = sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charTo, "count" = count, "storage" = 0, "customfield" = ""})
	if not moved:
		return {}
	var granted : int = sql.GrantItemLotRaw(charTo, itemID, count, "trade_in", 0, "", int(consumed[0]))
	if granted == 0:
		return {}
	return {"consumed" = consumed, "granted" = granted}

func _UIDList(uids : Array) -> String:
	var parts : PackedStringArray = PackedStringArray()
	for uid in uids:
		parts.append(str(uid))
	return ",".join(parts)

# SOM-IDLE B1: upsert agregado + lote + espelho no ledger. Para uso DENTRO de
# Transaction(). Retorna o uid do lote ou 0.
func _GrantStackRaw(charID : int, accountID : int, itemID : int, count : int, ledgerReason : String, grantReason : String = "", bound : int = 0, parentUID : int = 0) -> int:
	var sql : SQLService = Launcher.SQL
	var existing : Array[Dictionary] = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], ["count"])
	var delivered : bool = false
	if not existing.is_empty():
		delivered = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = int(existing[0]["count"]) + count})
	else:
		delivered = sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charID, "count" = count, "storage" = 0, "customfield" = ""})
	if not delivered:
		return 0
	var uid : int = sql.GrantItemLotRaw(charID, itemID, count, grantReason if not grantReason.is_empty() else ledgerReason, bound, "", parentUID)
	if uid == 0:
		return 0
	if not _LedgerAppendLocked(accountID, charID, LedgerKindItem, count, 0, ledgerReason + ":uid%d" % uid):
		return 0
	return uid

# Executes a direct character-to-character item trade: all-or-nothing escrow
# (invariant 3), fee burned from the initiating account's gems (ECONOMY_STUDY
# §6: trade fee é o sink primário; gems não-cashable). Items are stack rows
# {item_id, count} validated against the FROM character's inventory.
const TradeFeeGems : int = 10
# SOM-IDLE D3: velocity knobs (static var = sintonizável sem rebuild).
static var TradeCooldownSec : int = 60
static var TradeDailyCap : int = 20
const TradeRequireVerifiedEmail : bool = true

func ExecuteTrade(charIDFrom : int, charIDTo : int, itemsFrom : Array, itemsTo : Array) -> bool:
	settleMutex.lock()
	var traded : bool = false
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		# No self-trade: both sides must belong to different players
		if charIDFrom == charIDTo:
			return false
		var accountFrom : int = _AccountIDForCharacterRaw(charIDFrom)
		var accountTo : int = _AccountIDForCharacterRaw(charIDTo)
		if accountFrom == NetworkCommons.PeerUnknownID or accountTo == NetworkCommons.PeerUnknownID:
			return false

		# SOM-IDLE D3: antifraud gates — identidade verificada, cooldown, cap diário.
		if TradeRequireVerifiedEmail and (not sql.IsEmailVerifiedRaw(accountFrom) or not sql.IsEmailVerifiedRaw(accountTo)):
			return false
		var nowSec : int = SQLCommons.Timestamp()
		if nowSec - sql.LastTradeTimestampRaw(charIDFrom) < TradeCooldownSec:
			return false
		if nowSec - sql.LastTradeTimestampRaw(charIDTo) < TradeCooldownSec:
			return false
		if sql.TradeCountTodayRaw(accountFrom, nowSec) >= TradeDailyCap:
			return false

		# Escrow check: every offered stack must exist with the offered count
		for stack : Dictionary in itemsFrom:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _ItemCountRaw(charIDFrom, itemID) < count:
				return false
		for stack : Dictionary in itemsTo:
			var itemID : int = int(stack.get("item_id", 0))
			var count : int = int(stack.get("count", 0))
			if itemID <= 0 or count <= 0 or _ItemCountRaw(charIDTo, itemID) < count:
				return false

		# Fee burn first (all-or-nothing: a failed fee aborts the whole trade).
		# wallet.gems is the source of truth; the ledger row mirrors the burn.
		var feeBalance : int = sql.GetGemsRaw(accountFrom)
		if feeBalance < TradeFeeGems:
			return false
		if not sql.SetGemsRaw(accountFrom, feeBalance - TradeFeeGems):
			return false
		if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindGems, -TradeFeeGems, feeBalance - TradeFeeGems, "trade_fee"):
			return false

		# Move the stacks (remove from source, add to target) — raw db ops only.
		# SOM-IDLE B1: cada perna consome lotes (FIFO, unbound) e concede lote
		# encadeado; o espelho no ledger carrega os uids (invariant 1 + history).
		for stack : Dictionary in itemsFrom:
			var mv : Dictionary = _MoveStackUIDs(charIDFrom, charIDTo, int(stack["item_id"]), int(stack["count"]))
			if mv.is_empty():
				return false
			if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _UIDList(mv["consumed"])]):
				return false
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv["granted"])]):
				return false
		for stack : Dictionary in itemsTo:
			var mv2 : Dictionary = _MoveStackUIDs(charIDTo, charIDFrom, int(stack["item_id"]), int(stack["count"]))
			if mv2.is_empty():
				return false
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d:uids%s" % [int(stack["item_id"]), _UIDList(mv2["consumed"])]):
				return false
			if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d:lot%d" % [int(stack["item_id"]), int(mv2["granted"])]):
				return false
		return true):
		traded = true
	settleMutex.unlock()
	if traded:
		Util.PrintLog("Economy", "Trade %d -> %d executed (%d/%d stacks, fee %d gems)" % [charIDFrom, charIDTo, itemsFrom.size(), itemsTo.size(), TradeFeeGems])
	return traded

# Opens a settle-granted chest with an odds snapshot + provably-fair seeds
# (TECH_SPEC §4 invariant 4; ECONOMY_STUDY §7). The roll is deterministic:
# hash(server_seed + client_seed + nonce) selects a stack from the tier pool
# of the character's farm zone (or zone 1 when unbound).
const ChestPityEvery : int = 10		# guaranteed rare (T3+) every N opens

func OpenChest(charID : int, chestID : int) -> Dictionary:
	var result : Dictionary = {}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array[Dictionary] = sql.db.select_rows("chest_instance", "id = %d AND char_id = %d AND item_state = 'closed'" % [chestID, charID], ["*"])
		if rows.is_empty():
			return false
		var chest : Dictionary = rows[0]
		var accountID : int = _AccountIDForCharacterRaw(charID)
		if accountID == NetworkCommons.PeerUnknownID:
			return false

		# Nonce = open count for this character (pity timer input)
		var nonceRows : Array[Dictionary] = sql.db.select_rows("chest_instance", "char_id = %d AND item_state = 'opened'" % charID, ["id"])
		var nonce : int = nonceRows.size()
		var serverSeed : String = str(chest["id"]) + ":" + str(chest["created_at"]) + ":shambleta"
		var clientSeed : String = str(charID) + ":" + str(nonce)
		var roll : int = Hasher.HashPassword(serverSeed, clientSeed).substr(0, 8).hex_to_int()

		# Farm zone of the character decides the item pool band
		var char : Dictionary = sql.GetCharacter(charID)
		var zoneID : int = int(char.get("farm_zone", 0) if char.get("farm_zone", 0) != null else 0)
		if zoneID <= 0:
			zoneID = 1
		var pity : bool = (nonce + 1) % ChestPityEvery == 0
		var itemHash : int = _RollChestItem(zoneID, roll, pity)
		var count : int = 1

		# SOM-IDLE B2: snapshot de odds + server seed persistidos (dispute replay).
		var odds : Dictionary = GetChestOdds(zoneID)
		var snapshot : String = JSON.stringify({"zone" = zoneID, "pool" = odds["pool"], "tiers" = odds["tiers"], "nonce" = nonce, "pity" = pity, "pity_every" = ChestPityEvery})

		# SOM-IDLE B1: entrega com lote (uid) + espelho no ledger (invariante 1).
		if _GrantStackRaw(charID, accountID, itemHash, count, "chest:%d|%d|%s" % [chestID, itemHash, clientSeed], "chest_open") == 0:
			return false
		if not sql.UpdateRowsRaw("chest_instance", "id = %d" % chestID, {"item_state" = "opened", "odds_snapshot" = snapshot, "server_seed" = serverSeed}):
			return false

		result.clear()
		result.merge({"chest_id" = chestID, "item_id" = itemHash, "count" = count, "pity" = pity, "nonce" = nonce, "server_seed" = serverSeed, "client_seed" = clientSeed, "odds" = odds})
		return true):
		pass
	settleMutex.unlock()
	return result

# SOM-IDLE B2: public chest odds (loot-box compliance). Tier distribution of
# the zone pool + pity rule — shown BEFORE opening (/chests) and snapshotted
# per chest at open time (dispute replay: snapshot + seeds + roll algorithm).
func GetChestOdds(zoneID : int) -> Dictionary:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	var tiers : Dictionary = {}
	for itemHash in pool:
		var item : ItemCell = DB.ItemsDB.get(itemHash, null)
		var tier : int = item.tier if item != null else 0
		tiers[tier] = int(tiers.get(tier, 0)) + 1
	return {"zone" = zoneID, "pool" = pool.size(), "tiers" = tiers, "pity_every" = ChestPityEvery}

func GetChestOddsForCharacter(charID : int) -> Dictionary:
	var zoneID : int = 1
	var rows : Array = Launcher.SQL.db.select_rows("character", "char_id = %d" % charID, ["farm_zone"])
	if not rows.is_empty() and rows[0].get("farm_zone", null) != null:
		zoneID = maxi(1, int(rows[0]["farm_zone"]))
	return GetChestOdds(zoneID)

func FormatChestOdds(odds : Dictionary) -> String:
	var parts : PackedStringArray = PackedStringArray()
	var tiers : Dictionary = odds.get("tiers", {})
	var total : int = maxi(1, int(odds.get("pool", 1)))
	var keys : Array = tiers.keys()
	keys.sort()
	for tier in keys:
		parts.append("T%d %.1f%%" % [int(tier), 100.0 * float(tiers[tier]) / float(total)])
	return "Zona %d (pool %d: %s; pity T3+ a cada %d)" % [int(odds.get("zone", 1)), int(odds.get("pool", 0)), ", ".join(parts), int(odds.get("pity_every", ChestPityEvery))]

# Deterministic chest roll: pity forces a T3+ band, otherwise the zone band.
func _RollChestItem(zoneID : int, roll : int, pity : bool) -> int:
	var pool : Array = FarmZoneData.GetDropPool(zoneID)
	if pity:
		var rare : Array[int] = []
		for itemHash in pool:
			var item : ItemCell = DB.ItemsDB.get(itemHash, null)
			if item != null and item.tier >= 3:
				rare.append(itemHash)
		if not rare.is_empty():
			return rare[roll % rare.size()]
	# Fall back to the zone pool (Apple included)
	return FarmZoneData.GetDropForRoll(zoneID, roll)

# ------------------------------------------------------------------ F4: VIP checkout (MONETIZATION §2.2)

# Placeholder pricing (tuning pós-beta; MONETIZATION: R$19.90 / R$39.90 tiers)
const VIP1CostGems : int = 440
const VIP2CostGems : int = 880
const VIPDays : int = 30

# Gems -> vip_until. Extends from the current window when still active.
func PurchaseVIP(accountID : int, tier : int) -> bool:
	if tier != 1 and tier != 2:
		return false
	var cost : int = VIP1CostGems if tier == 1 else VIP2CostGems
	var now : int = SQLCommons.Timestamp()
	var currentUntil : int = Launcher.SQL.GetVIPUntil(accountID)
	var base : int = maxi(now, currentUntil)		# stack time when already VIP
	var until : int = base + VIPDays * 86400
	if not AddGems(accountID, -cost, "vip%d_purchase" % tier):
		return false
	return Launcher.SQL.SetVIPUntil(accountID, until)

# ------------------------------------------------------------------ C1: companion grants

# Kinds aceitos na v0 (outros → failed, sem parcial). gold exige
# {"char_id": N} no payload, e o char deve pertencer à conta.
const GrantKinds : Array[String] = ["gems", "gold", "vip_days"]

# ------------------------------------------------------------------ beta GUI: shop (sink de gems) + estado consolidado das janelas

# Placeholder pricing (mesmo regime do VIP — tuning pós-beta).
const ChestCostGems : int = 120
const MaxChestsPerPurchase : int = 10

# Gems -> N baús fechados (origin 'shop'). Atômico: débito, ledger e rows no
# MESMO Transaction com ops db-diretas (regra F4 — nada de update_rows aninhado;
# settleMutex não re-entra em AddGems, por isso o path é raw).
# Retorna {"count", "cost", "balance"} ou {} quando rejeitado.
func BuyChests(accountID : int, charID : int, count : int) -> Dictionary:
	var result : Dictionary = {}
	if count < 1 or count > MaxChestsPerPurchase:
		return result
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var balance : int = sql.GetGemsRaw(accountID)
		var cost : int = ChestCostGems * count
		if balance < cost:
			return false
		if not sql.SetGemsRaw(accountID, balance - cost):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGems, -cost, balance - cost, "chest_buy:%d" % count):
			return false
		for i in count:
			if not sql.AddChestInstance(charID, 0, "shop"):
				return false
		result.clear()
		result.merge({"count" = count, "cost" = cost, "balance" = balance - cost})
		return true):
		pass
	settleMutex.unlock()
	return result

# Estado consolidado das janelas de economia (Shop/Chests): wallet, baús
# fechados, odds públicas (texto pré-formatado, compliance loot box) e preços.
# Uma RPC única — as janelas pedem ao abrir e as ações devolvem o estado novo.
func GetEconomyState(accountID : int, charID : int) -> Dictionary:
	var chestIDs : Array = []
	for chest in Launcher.SQL.GetClosedChests(charID):
		chestIDs.append(int(chest["id"]))
	var until : int = Launcher.SQL.GetVIPUntil(accountID)
	var now : int = SQLCommons.Timestamp()
	var vipActive : bool = until > now
	var odds : Dictionary = GetChestOddsForCharacter(charID)
	return {
		"gems" = GetGems(accountID),
		"chests" = chestIDs,
		"odds" = odds,
		"odds_text" = FormatChestOdds(odds),
		"chest_cost" = ChestCostGems,
		"vip" = {"active" = vipActive, "until" = until, "mods" = OfflineSettle.VIPModFactor if vipActive else 1.0},
		"vip1_cost" = VIP1CostGems,
		"vip2_cost" = VIP2CostGems,
	}

# Boards da temporada ativa em um shot, já com nomes resolvidos (GUI de
# leaderboard). {} quando não há temporada ativa.
func GetSeasonBoardsState(limit : int = 10) -> Dictionary:
	var season : Dictionary = ActiveSeason()
	if season.is_empty():
		return {}
	var seasonID : int = int(season["season_id"])
	return {
		"season_id" = seasonID,
		"ends_at" = int(season["ends_at"]),
		"power" = _NamedSeasonBoard(seasonID, "power", limit),
		"spend" = _NamedSeasonBoard(seasonID, "spend", limit),
	}

# subject_id → nome legível: power é por char (nickname), spend por conta
# (username). ≤ limit rows por board, chamada rate-limited — queries por linha OK.
func _NamedSeasonBoard(seasonID : int, kind : String, limit : int) -> Array:
	var named : Array = []
	for row in GetSeasonBoard(seasonID, kind, limit):
		var name : String = "?"
		if kind == "power":
			var chars : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT nickname FROM character WHERE char_id = ?;", [int(row["subject_id"])])
			name = str(chars[0]["nickname"]) if not chars.is_empty() else "?"
		else:
			var accounts : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT username FROM account WHERE account_id = ?;", [int(row["subject_id"])])
			name = str(accounts[0]["username"]) if not accounts.is_empty() else "?"
		named.append({"name" = name, "value" = int(row["value"])})
	return named


# Enfileira um grant (idempotente pela chave: duplicada = já na fila, sem erro).
func EnqueueGrant(accountID : int, kind : String, amount : int, idempotencyKey : String, payload : String = "{}") -> bool:
	if idempotencyKey.is_empty() or amount <= 0 or not GrantKinds.has(kind):
		return false
	var sql : SQLService = Launcher.SQL
	if sql.QueryBindings("SELECT id FROM grant_queue WHERE idempotency_key = ?;", [idempotencyKey]).size() > 0:
		return true
	if sql.QueryBindings("SELECT account_id FROM account WHERE account_id = ?;", [accountID]).is_empty():
		return false
	return sql.ExecuteBindings("INSERT INTO grant_queue (idempotency_key, account_id, kind, amount, payload, status, created_at) VALUES (?, ?, ?, ?, ?, 'pending', ?);", [idempotencyKey, accountID, kind, amount, payload, SQLCommons.Timestamp()])

# Consome a fila: cada grant na própria transação (um ruim não trava os outros).
# Retorna {"processed": N, "failed": M}.
func ProcessPendingGrants(limit : int = 50) -> Dictionary:
	var done : Dictionary = {"processed" = 0, "failed" = 0}
	settleMutex.lock()
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id, idempotency_key, account_id, kind, amount, payload FROM grant_queue WHERE status = 'pending' ORDER BY id LIMIT ?;", [limit])
	for row in rows:
		var grantID : int = int(row["id"])
		if Launcher.SQL.Transaction(func() -> bool: return _ApplyGrantRaw(row)):
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'processed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["processed"] = int(done["processed"]) + 1
		else:
			Launcher.SQL.ExecuteBindings("UPDATE grant_queue SET status = 'failed', error = 'apply_failed', processed_at = ? WHERE id = ? AND status = 'pending';", [SQLCommons.Timestamp(), grantID])
			done["failed"] = int(done["failed"]) + 1
	settleMutex.unlock()
	return done

# Aplica um grant DENTRO de Transaction() — só ops raw (db direto, sem mutex).
func _ApplyGrantRaw(grant : Dictionary) -> bool:
	var sql : SQLService = Launcher.SQL
	var dbNode : SQLite = sql.db
	var accountID : int = int(grant["account_id"])
	var kind : String = str(grant["kind"])
	var amount : int = int(grant["amount"])
	var now : int = SQLCommons.Timestamp()
	if dbNode.select_rows("account", "account_id = %d" % accountID, ["account_id"]).is_empty():
		return false
	if kind == "gems":
		var balance : int = sql.GetGemsRaw(accountID)
		if not sql.SetGemsRaw(accountID, balance + amount):
			return false
		return _LedgerAppendLocked(accountID, 0, LedgerKindGems, amount, balance + amount, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "gold":
		var parsed : Variant = JSON.parse_string(str(grant.get("payload", "")))
		if not (parsed is Dictionary):
			return false
		var charID : int = int((parsed as Dictionary).get("char_id", 0))
		if charID <= 0 or _AccountIDForCharacterRaw(charID) != accountID:
			return false
		var statRows : Array = dbNode.select_rows("stat", "char_id = %d" % charID, ["gp"])
		if statRows.is_empty():
			return false
		var gp : int = int(statRows[0].get("gp", 0)) if statRows[0].get("gp", null) != null else 0
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp + amount}):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindGold, amount, gp + amount, "grant:%s" % str(grant["idempotency_key"]))
	if kind == "vip_days":
		var vipRows : Array = dbNode.select_rows("account", "account_id = %d" % accountID, ["vip_until"])
		var current : int = int(vipRows[0].get("vip_until", 0)) if not vipRows.is_empty() and vipRows[0].get("vip_until", null) != null else 0
		var until : int = maxi(now, current) + amount * 86400
		if not sql.UpdateRowsRaw("account", "account_id = %d" % accountID, {"vip_until" = until}):
			return false
		return _LedgerAppendLocked(accountID, 0, "vip", amount, until, "grant:%s" % str(grant["idempotency_key"]))
	return false

# ------------------------------------------------------------------ E1: guilds

const GuildCreateCostGold : int = 5000
const GuildMaxLevel : int = 10
# Custo de nível 1→2 .. 9→10 (índice = nível atual). Pontos: coluna pronta,
# acúmulo via settle = fast follow (v0 = gold+gems).
const GuildLevelCostGold : Array[int] = [0, 5000, 15000, 40000, 100000, 250000, 600000, 1500000, 4000000, 10000000]
const GuildLevelCostGems : Array[int] = [0, 50, 120, 300, 700, 1500, 3000, 6000, 12000, 25000]
const GuildBuffPerLevel : float = 0.02

func GetGuildForAccount(accountID : int) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id FROM guild_member WHERE account_id = ?;", [accountID])
	return int(rows[0]["guild_id"]) if not rows.is_empty() else 0

func GetGuild(guildID : int) -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT guild_id, name, level, points, leader_account, created_at FROM guild WHERE guild_id = ?;", [guildID])
	return {} if rows.is_empty() else rows[0]

func GetMemberRank(accountID : int) -> String:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT rank FROM guild_member WHERE account_id = ?;", [accountID])
	return str(rows[0]["rank"]) if not rows.is_empty() else ""

func GuildBuffForAccount(accountID : int) -> float:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT g.level FROM guild g INNER JOIN guild_member m ON m.guild_id = g.guild_id WHERE m.account_id = ?;", [accountID])
	if rows.is_empty():
		return 1.0
	return 1.0 + GuildBuffPerLevel * float(maxi(0, int(rows[0]["level"]) - 1))

func GetGuildLeaderboard(limit : int = 10) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT g.guild_id, g.name, g.level, g.points, COUNT(m.account_id) AS members FROM guild g LEFT JOIN guild_member m ON m.guild_id = g.guild_id GROUP BY g.guild_id ORDER BY g.level DESC, g.points DESC, members DESC LIMIT ?;", [limit])

func _CharGoldRaw(charID : int) -> int:
	var rows : Array = Launcher.SQL.db.select_rows("stat", "char_id = %d" % charID, ["gp"])
	if rows.is_empty() or rows[0].get("gp", null) == null:
		return 0
	return int(rows[0]["gp"])

func CreateGuild(accountID : int, charID : int, guildName : String) -> int:
	var clean : String = guildName.strip_edges()
	if not NetworkCommons.CheckSize(clean, 3, 30) or GetGuildForAccount(accountID) != 0:
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		if _CharGoldRaw(charID) < GuildCreateCostGold:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild (name, level, points, leader_account, created_at) VALUES (?, 1, 0, ?, ?);", [clean, accountID, SQLCommons.Timestamp()]):
			return false
		var guildID : int = sql.LastInsertRowIDRaw()
		if guildID <= 0:
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'leader', ?);", [guildID, accountID, SQLCommons.Timestamp()]):
			return false
		var gp : int = _CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - GuildCreateCostGold}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -GuildCreateCostGold, gp - GuildCreateCostGold, "guild_create"):
			return false
		out["id"] = guildID
		return true):
		pass
	settleMutex.unlock()
	return int(out["id"])

func JoinGuild(accountID : int, guildID : int) -> bool:
	if GetGuildForAccount(accountID) != 0 or GetGuild(guildID).is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO guild_member (guild_id, account_id, rank, joined_at) VALUES (?, ?, 'member', ?);", [guildID, accountID, SQLCommons.Timestamp()])

func LeaveGuild(accountID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var left : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var members : Array = sql.db.select_rows("guild_member", "guild_id = %d ORDER BY joined_at" % guildID, ["account_id", "rank"])
		if members.is_empty():
			return false
		var isLeader : bool = false
		for m in members:
			if int(m["account_id"]) == accountID and str(m["rank"]) == "leader":
				isLeader = true
		if members.size() == 1:
			# Último membro dissolve a guild — vault precisa estar vazio (sem perda).
			if not sql.db.select_rows("guild_vault", "guild_id = %d" % guildID, ["item_id"]).is_empty():
				return false
			if not sql.DeleteRowsRaw("guild_member", "guild_id = %d" % guildID):
				return false
			return sql.DeleteRowsRaw("guild", "guild_id = %d" % guildID)
		if not sql.DeleteRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, accountID]):
			return false
		if isLeader:
			# Promove o membro mais antigo a líder.
			for m in members:
				if int(m["account_id"]) != accountID:
					return sql.UpdateRowsRaw("guild_member", "guild_id = %d AND account_id = %d" % [guildID, int(m["account_id"])], {"rank" = "leader"}) \
						and sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"leader_account" = int(m["account_id"])})
			return false
		return true):
		left = true
	settleMutex.unlock()
	return left

func DepositToVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var consumed : Array = sql.ConsumeItemLotsRaw(charID, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _ItemCountRaw(charID, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charID]):
			return false
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty():
			if not sql.db.insert_row("guild_vault", {"guild_id" = guildID, "item_id" = itemID, "count" = count}):
				return false
		elif not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = int(vault[0]["count"]) + count}):
			return false
		if not sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'deposit', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()]):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindItem, -count, 0, "vault_deposit:%d:%d" % [guildID, itemID])):
		ok = true
	settleMutex.unlock()
	return ok

func WithdrawFromVault(accountID : int, charID : int, itemID : int, count : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0 or itemID <= 0 or count <= 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var vault : Array = sql.db.select_rows("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], ["count"])
		if vault.is_empty() or int(vault[0]["count"]) < count:
			return false
		var remain : int = int(vault[0]["count"]) - count
		if remain > 0:
			if not sql.UpdateRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID], {"count" = remain}):
				return false
		elif not sql.DeleteRowsRaw("guild_vault", "guild_id = %d AND item_id = %d" % [guildID, itemID]):
			return false
		if _GrantStackRaw(charID, accountID, itemID, count, "vault_withdraw:%d:%d" % [guildID, itemID], "vault_withdraw") == 0:
			return false
		return sql.db.query_with_bindings("INSERT INTO guild_vault_log (guild_id, account_id, char_id, item_id, count, kind, created_at) VALUES (?, ?, ?, ?, ?, 'withdraw', ?);", [guildID, accountID, charID, itemID, count, SQLCommons.Timestamp()])):
		ok = true
	settleMutex.unlock()
	return ok

func LevelUpGuild(accountID : int, charID : int) -> bool:
	var guildID : int = GetGuildForAccount(accountID)
	if guildID == 0:
		return false
	var rank : String = GetMemberRank(accountID)
	if rank != "leader" and rank != "officer":
		return false
	var ok : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("guild", "guild_id = %d" % guildID, ["level"])
		if rows.is_empty():
			return false
		var level : int = int(rows[0]["level"])
		if level < 1 or level >= GuildMaxLevel:
			return false
		var costGold : int = GuildLevelCostGold[level]
		var costGems : int = GuildLevelCostGems[level]
		if _CharGoldRaw(charID) < costGold:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < costGems:
			return false
		var gp : int = _CharGoldRaw(charID)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % charID, {"gp" = gp - costGold}):
			return false
		if not sql.SetGemsRaw(accountID, gems - costGems):
			return false
		if not sql.UpdateRowsRaw("guild", "guild_id = %d" % guildID, {"level" = level + 1}):
			return false
		if not _LedgerAppendLocked(accountID, charID, LedgerKindGold, -costGold, gp - costGold, "guild_level"):
			return false
		return _LedgerAppendLocked(accountID, charID, LedgerKindGems, -costGems, gems - costGems, "guild_level")):
		ok = true
	settleMutex.unlock()
	return ok

func PromoteMember(leaderAccount : int, targetAccount : int) -> bool:
	if GetMemberRank(leaderAccount) != "leader":
		return false
	if GetGuildForAccount(targetAccount) != GetGuildForAccount(leaderAccount) or GetGuildForAccount(leaderAccount) == 0:
		return false
	return Launcher.SQL.ExecuteBindings("UPDATE guild_member SET rank = 'officer' WHERE account_id = ?;", [targetAccount])

# ------------------------------------------------------------------ E2: seasons (corridas power + spend; premiação manual/GM na v0)

func ActiveSeason() -> Dictionary:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT season_id, starts_at, ends_at, rules_frozen, status FROM season WHERE status = 'active' ORDER BY season_id DESC LIMIT 1;", [])
	return {} if rows.is_empty() else rows[0]

func CreateSeason(days : int, rules : String = "{}") -> int:
	if days <= 0 or not ActiveSeason().is_empty():
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var now : int = SQLCommons.Timestamp()
		if not sql.db.query_with_bindings("INSERT INTO season (starts_at, ends_at, rules_frozen, status) VALUES (?, ?, ?, 'active');", [now, now + days * 86400, rules]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		return int(out["id"]) > 0):
		pass
	settleMutex.unlock()
	return int(out["id"])

func CloseSeason(seasonID : int) -> bool:
	return Launcher.SQL.ExecuteBindings("UPDATE season SET status = 'closed' WHERE season_id = ? AND status = 'active';", [seasonID])

func SnapshotSeasonPower(seasonID : int, limit : int = 100) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT char_id, power_score FROM character WHERE power_score > 0 ORDER BY power_score DESC LIMIT ?;", [limit])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'power', ?, ?);", [seasonID, int(row["char_id"]), int(row["power_score"])]):
			n += 1
	return n

func SnapshotSeasonSpend(seasonID : int) -> int:
	var season : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT starts_at FROM season WHERE season_id = ?;", [seasonID])
	if season.is_empty():
		return 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, SUM(-amount) AS spent FROM ledger_transaction WHERE kind = 'gems' AND amount < 0 AND created_at >= ? GROUP BY account_id;", [int(season[0]["starts_at"])])
	var n : int = 0
	for row in rows:
		if Launcher.SQL.ExecuteBindings("INSERT OR REPLACE INTO season_score (season_id, kind, subject_id, value) VALUES (?, 'spend', ?, ?);", [seasonID, int(row["account_id"]), int(row["spent"])]):
			n += 1
	return n

func GetSeasonBoard(seasonID : int, kind : String, limit : int = 20) -> Array[Dictionary]:
	if kind != "power" and kind != "spend":
		return []
	return Launcher.SQL.QueryBindings("SELECT subject_id, value FROM season_score WHERE season_id = ? AND kind = ? ORDER BY value DESC LIMIT ?;", [seasonID, kind, limit])

# ------------------------------------------------------------------ E2: auction house (escrow em lots, taxa flat queimada)

const AHListFeeGems : int = 5
const AHMaxOpenPerAccount : int = 5

func BrowseListings(limit : int = 20) -> Array[Dictionary]:
	return Launcher.SQL.QueryBindings("SELECT id, seller_char, item_id, count, price_gold, created_at FROM auction_listing WHERE status = 'open' ORDER BY id DESC LIMIT ?;", [limit])

func ListItemForSale(sellerChar : int, itemID : int, count : int, priceGold : int) -> int:
	if itemID <= 0 or count <= 0 or priceGold <= 0:
		return 0
	var out : Dictionary = {"id" = 0}
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var accountID : int = _AccountIDForCharacterRaw(sellerChar)
		if accountID == NetworkCommons.PeerUnknownID:
			return false
		var openRows : Array = sql.db.select_rows("auction_listing", "seller_account = %d AND status = 'open'" % accountID, ["id"])
		if openRows.size() >= AHMaxOpenPerAccount:
			return false
		if _ItemCountRaw(sellerChar, itemID) < count:
			return false
		var gems : int = sql.GetGemsRaw(accountID)
		if gems < AHListFeeGems:
			return false
		var consumed : Array = sql.ConsumeItemLotsRaw(sellerChar, itemID, count, false)
		if consumed.is_empty():
			return false
		var stock : int = _ItemCountRaw(sellerChar, itemID)
		if stock < count:
			return false
		if stock > count:
			if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar], {"count" = stock - count}):
				return false
		elif not sql.DeleteRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, sellerChar]):
			return false
		if not sql.SetGemsRaw(accountID, gems - AHListFeeGems):
			return false
		if not _LedgerAppendLocked(accountID, sellerChar, LedgerKindGems, -AHListFeeGems, gems - AHListFeeGems, "ah_list_fee"):
			return false
		if not sql.db.query_with_bindings("INSERT INTO auction_listing (seller_char, seller_account, item_id, count, price_gold, escrow_uids, status, created_at) VALUES (?, ?, ?, ?, ?, ?, 'open', ?);", [sellerChar, accountID, itemID, count, priceGold, _UIDList(consumed), SQLCommons.Timestamp()]):
			return false
		out["id"] = sql.LastInsertRowIDRaw()
		if int(out["id"]) <= 0:
			return false
		return _LedgerAppendLocked(accountID, sellerChar, LedgerKindItem, -count, 0, "ah_list:%d:uids%s" % [itemID, _UIDList(consumed)])):
		pass
	settleMutex.unlock()
	return int(out["id"])

func BuyListing(buyerChar : int, listingID : int) -> bool:
	var bought : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty():
			return false
		var listing : Dictionary = rows[0]
		var sellerChar : int = int(listing["seller_char"])
		var sellerAccount : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		var price : int = int(listing["price_gold"])
		var buyerAccount : int = _AccountIDForCharacterRaw(buyerChar)
		if buyerAccount == NetworkCommons.PeerUnknownID or buyerAccount == sellerAccount or buyerChar == sellerChar:
			return false
		var buyerGold : int = _CharGoldRaw(buyerChar)
		if buyerGold < price:
			return false
		var sellerGold : int = _CharGoldRaw(sellerChar)
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % buyerChar, {"gp" = buyerGold - price}):
			return false
		if not sql.UpdateRowsRaw("stat", "char_id = %d" % sellerChar, {"gp" = sellerGold + price}):
			return false
		var parentUID : int = int(str(listing.get("escrow_uids", "0")).split(",")[0])
		var granted : int = sql.GrantItemLotRaw(buyerChar, itemID, count, "ah_buy", 0, "", parentUID)
		if granted == 0:
			return false
		var existing : Array = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], ["count"])
		if existing.is_empty():
			if not sql.db.insert_row("item", {"item_id" = itemID, "char_id" = buyerChar, "count" = count, "storage" = 0, "customfield" = ""}):
				return false
		elif not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, buyerChar], {"count" = int(existing[0]["count"]) + count}):
			return false
		if not sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "sold"}):
			return false
		if not _LedgerAppendLocked(buyerAccount, buyerChar, LedgerKindGold, -price, buyerGold - price, "ah_buy:%d" % listingID):
			return false
		if not _LedgerAppendLocked(sellerAccount, sellerChar, LedgerKindGold, price, sellerGold + price, "ah_sell:%d" % listingID):
			return false
		return _LedgerAppendLocked(buyerAccount, buyerChar, LedgerKindItem, count, 0, "trade_in:%d:lot%d" % [itemID, granted])):
		bought = true
	settleMutex.unlock()
	return bought

func CancelListing(charID : int, listingID : int) -> bool:
	var done : bool = false
	settleMutex.lock()
	if Launcher.SQL.Transaction(func() -> bool:
		var sql : SQLService = Launcher.SQL
		var rows : Array = sql.db.select_rows("auction_listing", "id = %d AND status = 'open'" % listingID, ["*"])
		if rows.is_empty() or int(rows[0]["seller_char"]) != charID:
			return false
		var listing : Dictionary = rows[0]
		var accountID : int = int(listing["seller_account"])
		var itemID : int = int(listing["item_id"])
		var count : int = int(listing["count"])
		if _GrantStackRaw(charID, accountID, itemID, count, "ah_cancel:%d" % listingID, "ah_cancel") == 0:
			return false
		return sql.UpdateRowsRaw("auction_listing", "id = %d" % listingID, {"status" = "cancelled"})):
		done = true
	settleMutex.unlock()
	return done

# Daily reconciliation: ledger gold sums must match stat.gp deltas per account;
# no account may hold a negative balance. Returns number of divergences found.
func ReconcileDaily() -> int:
	var divergences : int = 0
	# SOM-IDLE E: escopo em contas existentes (linhas de fixtures deletados em
	# test-runs não são reconciliáveis — mesma regra dos lots).
	var negatives : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'gold' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += negatives.size()

	# XP rows must never be negative either
	var xpNeg : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'xp' AND EXISTS (SELECT 1 FROM account WHERE account.account_id = ledger_transaction.account_id) GROUP BY account_id HAVING total < 0;")
	divergences += xpNeg.size()

	# SOM-IDLE B1: soma dos lotes ativos deve espelhar a stack agregada
	# (storage 0, personagens existentes — órfãos de runs/fixtures excluídos).
	var stackMismatch : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT i.char_id FROM item i WHERE i.storage = 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = i.char_id) AND i.count != COALESCE((SELECT SUM(count) FROM item_instance WHERE item_instance.char_id = i.char_id AND item_instance.item_id = i.item_id AND item_instance.storage = i.storage AND item_instance.customfield = i.customfield), -1);")
	divergences += stackMismatch.size()
	var orphanLots : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT s.char_id FROM (SELECT char_id, item_id, storage, customfield, SUM(count) AS lots FROM item_instance GROUP BY char_id, item_id, storage, customfield) AS s WHERE s.lots != 0 AND EXISTS (SELECT 1 FROM character WHERE character.char_id = s.char_id) AND NOT EXISTS (SELECT 1 FROM item WHERE item.char_id = s.char_id AND item.item_id = s.item_id AND item.storage = s.storage AND item.customfield = s.customfield);")
	divergences += orphanLots.size()

	return divergences

# SOM-IDLE D2: daily reconcile job — roda após o backup diário (SQLBackups)
# e registra a divergência para o dashboard. Best-effort, nunca derruba o loop.
func RunReconcileJob() -> int:
	var divergences : int = ReconcileDaily()
	Launcher.SQL.ExecuteBindings("INSERT INTO reconcile_run (created_at, divergences) VALUES (?, ?);", [SQLCommons.Timestamp(), divergences])
	if divergences > 0:
		Util.PrintLog("Economy", "Reconcile found %d divergences" % divergences)
	var flagged : int = RunFraudScan()
	if flagged > 0:
		Util.PrintLog("Economy", "Fraud scan opened %d flags" % flagged)
	return divergences

# SOM-IDLE D3: heuristic fraud scan (roda no job diário; revisão é manual via
# /cs_flags). Heurísticas v1: rajada de trades, velocidade de level impossível,
# flip do mesmo item (compra/vende em <1h — padrão RMT/laundering).
const FraudTradeBurstPerDay : int = 10
const FraudLevelJump : int = 20
const FraudLevelJumpHours : float = 2.0

func RunFraudScan() -> int:
	var opened : int = 0
	var now : int = SQLCommons.Timestamp()
	opened += _FlagTradeBursts(now)
	opened += _FlagLevelVelocity(now)
	opened += _FlagFlipTrades(now)
	return opened

func _FlagOpen(accountID : int, charID : int, kind : String, detail : String) -> bool:
	var dup : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM fraud_flag WHERE account_id = ? AND kind = ? AND detail = ? AND status = 'open';", [accountID, kind, detail])
	if not dup.is_empty():
		return false
	return Launcher.SQL.ExecuteBindings("INSERT INTO fraud_flag (created_at, account_id, char_id, kind, detail, status) VALUES (?, ?, ?, ?, ?, 'open');", [SQLCommons.Timestamp(), accountID, charID, kind, detail])

func _FlagTradeBursts(now : int) -> int:
	var opened : int = 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, COUNT(*) AS n FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ? GROUP BY account_id HAVING n > ?;", [now - 86400, FraudTradeBurstPerDay])
	for row in rows:
		if _FlagOpen(int(row["account_id"]), 0, "trade_burst", "trades_24h=%d" % int(row["n"])):
			opened += 1
	return opened

func _FlagLevelVelocity(now : int) -> int:
	var opened : int = 0
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, char_id, value, meta FROM telemetry_event WHERE kind = 'levelup' AND created_at >= ? AND value >= ?;", [now - 86400, FraudLevelJump])
	for row in rows:
		var meta : Variant = JSON.parse_string(str(row.get("meta", "")))
		if meta is Dictionary and float((meta as Dictionary).get("hours", 99.0)) < FraudLevelJumpHours:
			if _FlagOpen(int(row["account_id"]), int(row["char_id"]), "level_velocity", "jump=%d levels in %sh" % [int(row["value"]), str((meta as Dictionary).get("hours", "?"))]):
				opened += 1
	return opened

func _FlagFlipTrades(now : int) -> int:
	# Flip = char enviou o item X e RECEBEU o mesmo X em <1h (padrão
	# laundering/RMT). Trade bilateral normal (X por Y) não casa: itens diferem.
	var opened : int = 0
	var outs : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT account_id, char_id, reason, created_at FROM ledger_transaction WHERE reason LIKE 'trade_out:%' AND created_at >= ?;", [now - 86400])
	for row in outs:
		var parts : PackedStringArray = str(row["reason"]).split(":")
		if parts.size() < 2:
			continue
		var item : String = parts[1]
		var back : Array[Dictionary] = Launcher.SQL.QueryBindings("SELECT id FROM ledger_transaction WHERE char_id = ? AND reason LIKE ? AND ABS(created_at - ?) < 3600 LIMIT 1;", [int(row["char_id"]), "trade_in:" + item + ":%", int(row["created_at"])])
		if not back.is_empty():
			if _FlagOpen(int(row["account_id"]), int(row["char_id"]), "flip_trade", "item=%s" % item):
				opened += 1
	return opened
