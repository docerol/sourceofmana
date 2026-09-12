extends RefCounted
class_name IdlePolicyService

# SOM-IDLE: F2 idle-spike integration glue (TECH_SPEC_CORE §2/§6)
# Attaches IdlePolicy brains to online players inside dedicated farm instances.
# Instance id convention: ZoneInstanceBase + zoneID (zone 1..40 → ids 1001..1040).

const ZoneInstanceBase : int = 1000
const MaxFormationSlots : int = 6
const InstanceWaitTimeoutMS : int = 10000

#
static func GetFarmInstanceID(zoneID : int) -> int:
	return ZoneInstanceBase + zoneID

static func GetFarmInstance(zoneID : int) -> WorldInstance:
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash or Launcher.World == null:
		return null
	var map : WorldMap = Launcher.World.GetMap(zone.mapID)
	if map == null:
		return null
	return map.instances.get(GetFarmInstanceID(zoneID), null)

# Server-only guard: farm sessions only exist where the World service lives
static func IsServerSide() -> bool:
	return Launcher.World != null

# SOM-IDLE idle-first: login é farmando — char fresh entra na zona 1 e char
# zonado RETOMA a sessão da zona salva (spawn na cidade nunca fica exposto;
# instâncias de farm recriam no attach quando necessário).
# Retorna true se a sessão foi (re)iniciada ou está a caminho (retry timer).
static func AutoFarmOnLogin(charID : int, player : PlayerAgent) -> bool:
	if not IsServerSide() or player == null or not is_instance_valid(player):
		return false
	var sql : SQLService = Launcher.SQL
	var char : Dictionary = sql.GetCharacter(charID)
	if char.is_empty():
		return false
	var zone : int = int(char.get("farm_zone", 0) if char.get("farm_zone", 0) != null else 0)
	if zone <= 0:
		sql.SetCharacterFarmZone(charID, 1)
		zone = 1
		Util.PrintLog("Idle", "Onboarding: character %d auto-farming zone 1" % charID)
	else:
		# SOM-IDLE idle-first: gate de power no resume (mesma regra do
		# SetFarmZone) — sem isto, char fraco loga direto numa zona funda e
		# morre em loop (death tax a cada morte, no próprio login).
		var zoneData : FarmZoneData = FarmZoneData.GetZone(zone)
		if zoneData == null or zoneData.mapID == DB.UnknownHash or Formula.GetPowerScore(player.stat) < zoneData.minPower:
			Util.PrintLog("Idle", "Character %d power below zone %d gate — resuming in zone 1" % [charID, zone])
			sql.SetCharacterFarmZone(charID, 1)
			zone = 1
	return StartIdleSession(player, zone)

# ------------------------------------------------------------------ session lifecycle

# Creates (or reuses) the dedicated farm instance, warps the player into it and
# attaches a fresh IdlePolicy. Safe to call again to re-target a zone.
# Synchronous when the instance is already warm; otherwise arms a retry timer
# while the instance/navigation finishes initializing.
static func StartIdleSession(player : PlayerAgent, zoneID : int) -> bool:
	if not IsServerSide() or player == null or not is_instance_valid(player):
		return false

	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return false

	var map : WorldMap = Launcher.World.GetMap(zone.mapID)
	if map == null:
		return false

	var instID : int = GetFarmInstanceID(zoneID)
	if not map.instances.has(instID):
		map.CreateInstance(instID)

	if _IsInstanceWarm(map, instID):
		return _Attach(player, map, instID, zoneID)

	# The instance node is added deferred and navigation needs a first sync pass:
	# retry on a timer instead of blocking the caller (CommandManager/RPC path).
	var retries : int = ceili(float(InstanceWaitTimeoutMS) / 500.0)
	Callback.SelfDestructTimer(Launcher, 0.5, _RetryAttach, [player, zoneID, retries], "IdleRetry_" + str(player.get_rid().get_id()))
	Util.PrintLog("Idle", "Farm instance %d for zone %d is warming up" % [instID, zoneID])
	return true

static func _IsInstanceWarm(map : WorldMap, instID : int) -> bool:
	var inst : WorldInstance = map.instances.get(instID, null)
	return inst != null and inst.is_node_ready() and NavigationServer2D.map_get_iteration_id(map.mapRID) > 0

static func _RetryAttach(player : PlayerAgent, zoneID : int, retriesLeft : int):
	if player == null or not is_instance_valid(player) or not IsServerSide():
		return
	if retriesLeft <= 0:
		Util.PrintLog("Idle", "Farm instance for zone %d failed to initialize in time" % zoneID)
		return

	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return
	var map : WorldMap = Launcher.World.GetMap(zone.mapID)
	if map == null:
		return

	if _IsInstanceWarm(map, GetFarmInstanceID(zoneID)):
		_Attach(player, map, GetFarmInstanceID(zoneID), zoneID)
	else:
		Callback.SelfDestructTimer(Launcher, 0.5, _RetryAttach, [player, zoneID, retriesLeft - 1], "IdleRetry_" + str(player.get_rid().get_id()))

# Actual policy attach + warp (must run on a warm instance)
static func _Attach(player : PlayerAgent, map : WorldMap, instID : int, zoneID : int) -> bool:
	var inst : WorldInstance = map.instances.get(instID, null)
	if inst == null:
		return false

	StopIdleSession(player)

	var policy : IdlePolicy = IdlePolicy.new()
	policy.Setup(player, zoneID)

	# SOM-IDLE: F3 — formation overrides (loadout + auto-potion) from the slot
	# the character selected (character.formation_slot), not hardcoded slot 0.
	var accountID : int = Launcher.SQL.GetAccountIDForCharacter(player.GetCharacterID())
	var slotRow : Dictionary = Launcher.SQL.GetCharacter(player.GetCharacterID())
	var slot : int = clampi(int(slotRow.get("formation_slot", 0) if slotRow.get("formation_slot", 0) != null else 0), 0, MaxFormationSlots - 1)
	var formation : Dictionary = Launcher.SQL.GetFormationForSlot(accountID, slot) if accountID != NetworkCommons.PeerUnknownID else {}
	if not formation.is_empty():
		var loadoutRaw : String = str(formation.get("skill_loadout", ""))
		if not loadoutRaw.is_empty():
			var loadout : Variant = str_to_var(loadoutRaw)
			if loadout is Array:
				for skillID in loadout:
					policy.skillLoadout.append(int(skillID))
		policy.autoPotionPct = float(formation.get("auto_potion_pct", policy.autoPotionPct))

	var spawn : SpawnObject = SpawnObject.new()
	spawn.map = map
	spawn.type = ActorCommons.Type.PLAYER
	spawn.id = DB.PlayerHash
	spawn.is_global = true
	spawn.spawn_offset = Vector2i(96, 96)

	var pos : Vector2i = WorldNavigation.GetSpawnPosition(inst, spawn)
	if pos == Vector2i.ZERO:
		return false

	player.idlePolicy = policy
	inst.AttachIdlePolicy(policy)

	# Warp only when the player is not already entering this instance: a fresh
	# agent has a pending deferred add_child (CreateAgent → Warp already queued
	# it), and a second queued add_child for the same frame would collide.
	var currentInst : Node = player.get_parent()
	if currentInst == null or not (currentInst is WorldInstance) or (currentInst as WorldInstance).id != instID:
		Launcher.World.Warp(player, map, pos, ActorCommons.Direction.UNKNOWN, instID)

	Util.PrintLog("Idle", "Player %s is now farming zone %d on instance %d" % [player.nick, zoneID, instID])
	return true

static func StopIdleSession(player : PlayerAgent):
	if player and is_instance_valid(player):
		var policy : IdlePolicy = player.idlePolicy
		if policy:
			policy.Halt()
			player.idlePolicy = null
			var inst : WorldInstance = WorldAgent.GetInstanceFromAgent(player)
			if inst and inst is WorldInstance:
				inst.DetachIdlePolicy(policy)
