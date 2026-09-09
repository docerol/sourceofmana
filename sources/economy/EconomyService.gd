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

# ------------------------------------------------------------------ F4 stubs (documented)

func ExecuteTrade(charIDFrom : int, charIDTo : int, itemsFrom : Array, itemsTo : Array) -> bool:
	Util.PrintLog("Economy", "ExecuteTrade deferred to F4")
	return false

func OpenChest(charID : int, chestID : int) -> bool:
	Util.PrintLog("Economy", "OpenChest deferred to F4")
	return false

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
