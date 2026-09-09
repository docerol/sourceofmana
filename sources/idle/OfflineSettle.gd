extends RefCounted
class_name OfflineSettle

# SOM-IDLE: F2 idle-spike settle (TECH_SPEC_CORE.md §3)
# OfflineFactor = 0.6, BaseCapHours = 12, death tax 5%, chests floor(h/4) cap 3.
# The whole settle runs in ONE SQLite transaction; idempotency is enforced by
# re-reading last_settled_at INSIDE the transaction before any write.

const OfflineFactor : float = 0.6
const BaseCapHours : float = 12.0
const DeathTaxPct : int = 5
const MaxChests : int = 3
const ChestHoursPerChest : int = 4
const EfficiencyDecayPerDeath : float = 0.05
const MinEfficiency : float = 0.5

# Mods (VIP/season pass/potion) are F3/F4 scope: spike pins them to 1.0
const Mods : float = 1.0

#
class SettleReport:
	var charID : int = 0
	var zoneID : int = 0
	var hours : float = 0.0
	var efficiency : float = 1.0
	var deaths : int = 0
	var levelsGained : int = 0
	var newLevel : int = 0
	var xpEarned : int = 0
	var goldEarned : int = 0
	var goldTaxed : int = 0
	var drops : Dictionary[int, int] = {}
	var chests : int = 0
	var lastSettledAt : int = 0

	func to_dictionary() -> Dictionary:
		return {
			"char_id": charID,
			"zone_id": zoneID,
			"hours": hours,
			"efficiency": efficiency,
			"deaths": deaths,
			"levels_gained": levelsGained,
			"new_level": newLevel,
			"xp_earned": xpEarned,
			"gold_earned": goldEarned,
			"gold_taxed": goldTaxed,
			"drops": drops,
			"chests": chests,
			"last_settled_at": lastSettledAt,
		}

# Test seams (headless `-s` runs have no Launcher/SQL autoload context)
static var sqlOverride : SQLService		= null
static var economyOverride : EconomyService	= null
static var nowOverride : int				= 0

#
static func _sql() -> SQLService:
	return sqlOverride if sqlOverride else Launcher.SQL

static func _economy() -> EconomyService:
	return economyOverride if economyOverride else Launcher.Economy

static func _now() -> int:
	return nowOverride if nowOverride > 0 else SQLCommons.Timestamp()

# ------------------------------------------------------------------ public API

# Builds the AFK report preview WITHOUT applying anything.
static func BuildReport(charID : int, now : int = 0) -> SettleReport:
	var sql : SQLService = _sql()
	var report : SettleReport = SettleReport.new()
	var char : Dictionary = sql.GetCharacter(charID)
	if char.is_empty():
		return report

	var elapsed : int = (now if now > 0 else _now()) - int(char.get("last_settled_at", 0) if char.get("last_settled_at", 0) != null else 0)
	report.charID = charID
	report.zoneID = _statInt(char, "farm_zone", 0)
	report.lastSettledAt = _statInt(char, "last_settled_at", 0)
	report.hours = minf(float(elapsed) / 3600.0, BaseCapHours)
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0) if char.get("session_efficiency", 1.0) != null else 1.0), MinEfficiency, 1.0)
	_ApplyFormula(sql, report)
	return report

# Applies a pending settle for charID. Returns empty dict when nothing to settle.
static func SettlePending(charID : int) -> Dictionary:
	var sql : SQLService = _sql()
	var char : Dictionary = sql.GetCharacter(charID)
	if char.is_empty():
		return {}

	var lastSettled : int = int(char.get("last_settled_at", 0))
	var now : int = _now()
	if now <= lastSettled:
		return {}		# nothing elapsed (idempotent fast-path)

	var zoneID : int = int(char.get("farm_zone", 0))
	if zoneID <= 0:
		# No farming configured: just advance the anchor so time keeps flowing
		_UpdateAnchor(sql, charID, now)
		return {}

	var report : SettleReport = SettleReport.new()
	report.charID = charID
	report.zoneID = zoneID
	report.lastSettledAt = now
	report.hours = minf(float(now - lastSettled) / 3600.0, BaseCapHours)
	report.efficiency = clampf(float(char.get("session_efficiency", 1.0)), MinEfficiency, 1.0)
	# NOTE: session deaths are already baked into session_efficiency on disconnect
	# (NetServer SOM-IDLE hook); the spike does not track a separate death count.

	_ApplyFormula(sql, report)
	if not _Apply(sql, report):
		return {}
	return report.to_dictionary()

# ------------------------------------------------------------------ formula

static func _ApplyFormula(sql : SQLService, report : SettleReport):
	var zone : FarmZoneData = FarmZoneData.GetZone(report.zoneID)
	if zone == null:
		return

	var h : float = report.hours
	var eff : float = report.efficiency

	report.xpEarned = roundi(float(zone.xpPerKill) * float(zone.parKillsPerHour) * h * eff * OfflineFactor * Mods)
	report.goldEarned = roundi(float(zone.goldPerKill) * float(zone.parKillsPerHour) * h * eff * OfflineFactor * Mods)
	if eff < 1.0:
		report.goldTaxed = roundi(float(report.goldEarned) * float(DeathTaxPct) / 100.0)

	# Drops: rate_ppm * h * 3600 * eff * factor / 1e6 (expected value, deterministic in spike)
	var dropExpected : float = float(zone.dropRatePPM) * h * 3600.0 * eff * OfflineFactor / 1000000.0
	var dropCount : int = floori(dropExpected)
	var frac : float = dropExpected - float(dropCount)
	# Deterministic fractional carry (no RNG in the golden path)
	if frac >= 0.5:
		dropCount += 1
	if dropCount > 0:
		report.drops[zone.dropItemHash] = dropCount

	report.chests = mini(floori(h / float(ChestHoursPerChest)), MaxChests)

# ------------------------------------------------------------------ apply (transactional)

static func _Apply(sql : SQLService, report : SettleReport) -> bool:
	var sqlNode : SQLService = sql
	var applied : bool = false
	if not sqlNode.Transaction(func() -> bool:
		# Idempotency guard: re-read the anchor INSIDE the transaction
		var fresh : Dictionary = sqlNode.GetCharacter(report.charID)
		if fresh.is_empty() or int(fresh.get("last_settled_at", 0)) >= report.lastSettledAt:
			return false

		# 1) level recompute through the Experience curve
		# NOTE: sqlite columns may be NULL (fresh characters ship experience = NULL);
		# int(<null>) throws in Godot 4.7, so read through the null-safe helper.
		var stat : Dictionary = sqlNode.GetStat(report.charID)
		var level : int = _statInt(stat, "level", 1)
		var progressXP : int = _statInt(stat, "experience", 0) + report.xpEarned
		var newLevel : int = level
		while not Experience.IsMaxLevel(newLevel):
			var needed : int = Experience.GetNeededExperienceForNextLevel(newLevel)
			if needed == Experience.MAX_LEVEL_REACHED or progressXP < needed:
				break
			progressXP -= needed
			newLevel += 1
		report.levelsGained = newLevel - level
		report.newLevel = newLevel

		# 2) gold (5% tax when efficiency < 1.0)
		var goldNet : int = report.goldEarned - report.goldTaxed
		var newGold : int = _statInt(stat, "gp", 0) + goldNet

		if not sqlNode.UpdateStatDirect(report.charID, newLevel, progressXP, newGold):
			return false

		# 3) drop items straight into character inventory
		for itemHash in report.drops:
			if not sqlNode.AddItemToCharacter(report.charID, itemHash, report.drops[itemHash]):
				return false

		# 4) ledger rows (gold + xp; item rows appended per drop)
		var accountID : int = int(fresh.get("account_id", 0))
		var economy : EconomyService = _economy()
		if economy:
			if goldNet != 0 and not economy.LedgerAppend(report.charID, accountID, "gold", goldNet, newGold, "offline_settle"):
				return false
			if report.xpEarned > 0 and not economy.LedgerAppend(report.charID, accountID, "xp", report.xpEarned, progressXP, "offline_settle"):
				return false

		# 5) chests (rows only; opening is F4 scope)
		for i in report.chests:
			if not sqlNode.AddChestInstance(report.charID, 0, "settle"):
				return false

		# 6) anchor update
		if not sqlNode.UpdateSettleAnchor(report.charID, report.lastSettledAt, 1.0):
			return false

		return true):
		applied = true
	return applied

static func _UpdateAnchor(sql : SQLService, charID : int, now : int):
	sql.UpdateSettleAnchor(charID, now, 1.0)

# Null-safe sqlite int read (Godot 4.7 throws on int(<null>))
static func _statInt(row : Dictionary, key : String, fallback : int) -> int:
	var value : Variant = row.get(key, fallback)
	return fallback if value == null else int(value)
