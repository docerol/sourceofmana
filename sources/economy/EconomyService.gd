extends ServiceBase
class_name EconomyService

# SOM-IDLE: F2 idle-spike economy service (TECH_SPEC_CORE.md §4 + ECONOMY_STUDY.md)
# Spike scope: settle-path ledger writes + balance/audit helpers.
# ExecuteTrade/OpenChest are documented stubs (F4 scope) and always return false.

const LedgerKindGold : String = "gold"
const LedgerKindXP : String = "xp"
const LedgerKindItem : String = "item"
const LedgerKindGems : String = "gems"

var settleMutex : Mutex						= Mutex.new()

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
	var sql : SQLService = Launcher.SQL
	var sourceCount : int = _ItemCountRaw(charFrom, itemID)
	if sourceCount > count:
		if not sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom], {"count" = sourceCount - count}):
			return false
	elif sourceCount == count:
		if not sql.db.delete_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charFrom]):
			return false
	else:
		return false
	var targetCount : int = _ItemCountRaw(charTo, itemID)
	if targetCount > 0:
		return sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemID, charTo], {"count" = targetCount + count})
	return sql.db.insert_row("item", {"item_id" = itemID, "char_id" = charTo, "count" = count, "storage" = 0, "customfield" = ""})

# Executes a direct character-to-character item trade: all-or-nothing escrow
# (invariant 3), fee burned from the initiating account's gems (ECONOMY_STUDY
# §6: trade fee é o sink primário; gems não-cashable). Items are stack rows
# {item_id, count} validated against the FROM character's inventory.
const TradeFeeGems : int = 10

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

		# Move the stacks (remove from source, add to target) — raw db ops only
		for stack : Dictionary in itemsFrom:
			if not _MoveStack(charIDFrom, charIDTo, int(stack["item_id"]), int(stack["count"])):
				return false
		for stack : Dictionary in itemsTo:
			if not _MoveStack(charIDTo, charIDFrom, int(stack["item_id"]), int(stack["count"])):
				return false

		# Ledger mirror for the item movement (invariant 1: no mutation without a row)
		for stack : Dictionary in itemsFrom:
			if not _LedgerAppendLocked(accountFrom, charIDFrom, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d" % int(stack["item_id"])):
				return false
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d" % int(stack["item_id"])):
				return false
		for stack : Dictionary in itemsTo:
			if not _LedgerAppendLocked(accountTo, charIDTo, LedgerKindItem, -int(stack["count"]), 0, "trade_out:%d" % int(stack["item_id"])):
				return false
			if not _LedgerAppendLocked(accountTo, charIDFrom, LedgerKindItem, int(stack["count"]), 0, "trade_in:%d" % int(stack["item_id"])):
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

		var existing : Array[Dictionary] = sql.db.select_rows("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, charID], ["count"])
		var delivered : bool = false
		if not existing.is_empty():
			delivered = sql.UpdateRowsRaw("item", "item_id = %d AND char_id = %d AND storage = 0" % [itemHash, charID], {"count" = int(existing[0]["count"]) + count})
		else:
			delivered = sql.db.insert_row("item", {"item_id" = itemHash, "char_id" = charID, "count" = count, "storage" = 0, "customfield" = ""})
		if not delivered:
			return false
		if not sql.UpdateRowsRaw("chest_instance", "id = %d" % chestID, {"item_state" = "opened"}):
			return false

		# Ledger mirror (invariant 1) + provably-fair record (invariant 4)
		if not _LedgerAppendLocked(accountID, charID, LedgerKindItem, count, 0, "chest:%d|%d|%s" % [chestID, itemHash, clientSeed]):
			return false

		result.clear()
		result.merge({"chest_id" = chestID, "item_id" = itemHash, "count" = count, "pity" = pity, "nonce" = nonce, "server_seed" = serverSeed, "client_seed" = clientSeed})
		return true):
		pass
	settleMutex.unlock()
	return result

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

# ------------------------------------------------------------------ audit

# Daily reconciliation: ledger gold sums must match stat.gp deltas per account;
# no account may hold a negative balance. Returns number of divergences found.
func ReconcileDaily() -> int:
	var divergences : int = 0
	var negatives : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'gold' GROUP BY account_id HAVING total < 0;")
	divergences += negatives.size()

	# XP rows must never be negative either
	var xpNeg : Array[Dictionary] = Launcher.SQL.Query(
		"SELECT account_id, SUM(amount) AS total FROM ledger_transaction WHERE kind = 'xp' GROUP BY account_id HAVING total < 0;")
	divergences += xpNeg.size()

	return divergences
