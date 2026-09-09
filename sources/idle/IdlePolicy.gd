extends RefCounted
class_name IdlePolicy

# SOM-IDLE: F2 idle-spike policy (TECH_SPEC_CORE.md §2)
# Server-only per-player brain attached to a farming PlayerAgent. Uses exclusively
# existing world primitives: WalkToward, Skill.Cast, WorldDrop.PickupDrop,
# inventory.UseItem — it never writes stats directly.

enum State
{
	IDLE,
	SEEK,
	COMBAT,
	LOOT,
	DEAD,
}

const TickInterval : float = 0.25

const SeekInterval : float = 0.4			# re-evaluate target every 0.4s
const LootInterval : float = 0.4
const PotionCheckInterval : float = 1.0
const StuckTimeout : float = 8.0
const AttackRangeBuffer : float = 8.0		# walk slightly inside skill range
const EfficiencySampleMinInterval : float = 5.0
const DeathPenalty : float = 0.05
const MinEfficiency : float = 0.5
const RespawnDelay : float = 2.0

#
var agent : PlayerAgent						= null
var zoneID : int							= 0
var state : State							= State.IDLE
var halted : bool							= false

var sessionStartTime : int					= 0
var sessionGameTime : float					= 0.0
var sessionKills : int						= 0
var sessionDeaths : int						= 0
var sessionDowntimeSecs : float				= 0.0

var currentTargetRID : int					= 0
var skillLoadout : Array[int]				= []
var autoPotionPct : float					= 35.0
var autoPotionItemHash : int				= 215387671		# Apple spike default

# Internals
var _accumulator : float					= 0.0
var _seekAccumulator : float				= 0.0
var _lootAccumulator : float				= 0.0
var _potionAccumulator : float				= 0.0
var _stuckAccumulator : float				= 0.0
var _lastPosition : Vector2					= Vector2.ZERO
var _respawnAccumulator : float				= 0.0
var _deathDownAccumulator : float			= 0.0
var _lastEfficiencySample : float			= 0.0
var _retargets : int						= 0
var _attackedTarget : bool					= false

#
func Setup(pAgent : PlayerAgent, pZoneID : int):
	agent = pAgent
	zoneID = pZoneID
	state = State.IDLE
	halted = false
	_accumulator = 0.0
	_seekAccumulator = 0.0
	_lootAccumulator = 0.0
	_potionAccumulator = 0.0
	_stuckAccumulator = 0.0
	_respawnAccumulator = 0.0
	_deathDownAccumulator = 0.0
	_retargets = 0
	_attackedTarget = false
	sessionStartTime = Time.get_ticks_msec()
	sessionGameTime = 0.0
	sessionKills = 0
	sessionDeaths = 0
	sessionDowntimeSecs = 0.0
	_lastPosition = agent.position if agent else Vector2.ZERO

func Halt():
	halted = true

func Resume():
	halted = false

# ------------------------------------------------------------------ tick

func Tick(delta : float):
	if halted or not _isValid():
		return

	_accumulator += delta
	sessionGameTime += delta

	match state:
		State.IDLE:
			state = State.SEEK
		State.SEEK:
			_tickSeek(delta)
		State.COMBAT:
			_tickCombat(delta)
		State.LOOT:
			_tickLoot(delta)
		State.DEAD:
			_tickDead(delta)

	_tickStuck(delta)
	_tickPotion(delta)

func _isValid() -> bool:
	if agent == null or not is_instance_valid(agent):
		return false
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return false
	return true

func _getInst() -> WorldInstance:
	return WorldAgent.GetInstanceFromAgent(agent) as WorldInstance if agent else null

func _getSkill() -> SkillCell:
	var skillID : int = skillLoadout[0] if not skillLoadout.is_empty() else SkillCommons.SkillMeleeName.hash()
	var cell : SkillCell = DB.GetSkill(skillID)
	return cell

# ------------------------------------------------------------------ seek

func _tickSeek(delta : float):
	_seekAccumulator += delta
	if _seekAccumulator < SeekInterval:
		return
	_seekAccumulator = 0.0

	# Commit to the current target while it lives — re-picking the nearest mob
	# every tick makes the agent thrash between wandering mobs and never close
	# the distance. STUCK failsafe still breaks deadlocks.
	var current : AIAgent = WorldAgent.GetAgent(currentTargetRID) as AIAgent if currentTargetRID != 0 else null
	if current and is_instance_valid(current) and ActorCommons.IsAlive(current):
		state = State.COMBAT
		return
	currentTargetRID = 0

	var target : AIAgent = _findNearestMob()
	if target:
		_setTarget(target)
		state = State.COMBAT
		return

	# No mobs: wander toward instance center to stay in the farm area
	var inst : WorldInstance = _getInst()
	if inst and agent.agent and not agent.agent.is_navigation_finished():
		pass	# already walking
	elif inst:
		var center : Vector2 = WorldNavigation.GetPolygonCenter(inst.map.navPoly.get_vertices()) if inst.map.navPoly and inst.map.navPoly.get_polygon_count() > 0 else agent.position
		if agent.position.distance_squared_to(center) > 64.0:
			agent.WalkToward(center)

func _findNearestMob() -> AIAgent:
	var inst : WorldInstance = _getInst()
	if inst == null:
		return null

	var best : AIAgent = null
	var bestDist : float = INF
	for mob in inst.mobs:
		if mob and is_instance_valid(mob) and ActorCommons.IsAlive(mob):
			var dist : float = agent.position.distance_squared_to(mob.position)
			if dist < bestDist:
				bestDist = dist
				best = mob
	return best

func _setTarget(target : AIAgent):
	currentTargetRID = target.get_rid().get_id()
	_retargets += 1
	_lastPosition = agent.position

# ------------------------------------------------------------------ combat

func _tickCombat(delta : float):
	var target : BaseAgent = WorldAgent.GetAgent(currentTargetRID) as AIAgent if currentTargetRID != 0 else null
	if target == null or not is_instance_valid(target) or not ActorCommons.IsAlive(target):
		# Kill detection: if we attacked this target and it's now dead/gone, count
		# it (one-shot kills die between ticks — also covers mob corpse cleanup)
		if _attackedTarget:
			sessionKills += 1
			_attackedTarget = false
		currentTargetRID = 0
		state = State.SEEK
		return

	var skill : SkillCell = _getSkill()
	if skill == null:
		state = State.SEEK
		return

	var range : float = float(ActorCommons.GetSkillRange(agent, skill)) - AttackRangeBuffer
	var dist : float = agent.position.distance_to(target.position)

	if dist > range:
		agent.WalkToward(target.position)
	else:
		if not SkillCommons.HasAnyActionInProgress(agent):
			Skill.Cast(agent, target, skill)
			_attackedTarget = true

	# Kill detection: target died between ticks
	if not ActorCommons.IsAlive(target):
		sessionKills += 1
		_attackedTarget = false
		currentTargetRID = 0
		state = State.LOOT

# ------------------------------------------------------------------ loot

func _tickLoot(delta : float):
	_lootAccumulator += delta
	if _lootAccumulator < LootInterval:
		return
	_lootAccumulator = 0.0

	var drop : Drop = _findNearestDrop()
	if drop:
		var dist : float = agent.position.distance_squared_to(drop.position)
		if dist <= ActorCommons.PickupSquaredDistance:
			var dropID : int = drop.get_instance_id()
			WorldDrop.PickupDrop(dropID, agent)
			state = State.SEEK
		else:
			agent.WalkToward(drop.position)
		return

	state = State.SEEK

func _findNearestDrop() -> Drop:
	var inst : WorldInstance = _getInst()
	if inst == null or inst.drops.is_empty():
		return null

	var best : Drop = null
	var bestDist : float = INF
	for dropID in inst.drops:
		var drop : Drop = inst.drops[dropID]
		if drop and is_instance_valid(drop):
			var dist : float = agent.position.distance_squared_to(drop.position)
			if dist < bestDist:
				bestDist = dist
				best = drop
	return best

# ------------------------------------------------------------------ death

func _tickDead(delta : float):
	_deathDownAccumulator += delta
	_respawnAccumulator += delta
	if _respawnAccumulator >= RespawnDelay:
		_respawnAccumulator = 0.0
		# SOM-IDLE: revive IN PLACE — warping out would destroy the dedicated
		# farm instance when its last player leaves (WorldAgent.PopAgent).
		if not ActorCommons.IsAlive(agent):
			agent.Revive()
		if ActorCommons.IsAlive(agent):
			sessionDeaths += 1
			sessionDowntimeSecs += _deathDownAccumulator
			_deathDownAccumulator = 0.0
			state = State.SEEK

# ------------------------------------------------------------------ helpers

func _tickStuck(delta : float):
	if state == State.DEAD or agent == null:
		return

	if agent.position.distance_squared_to(_lastPosition) < 1.0:
		_stuckAccumulator += delta
		if _stuckAccumulator >= StuckTimeout:
			_stuckAccumulator = 0.0
			# Force re-target / re-route
			currentTargetRID = 0
			state = State.SEEK
			_retargets += 1
	else:
		_stuckAccumulator = 0.0
		_lastPosition = agent.position

func _tickPotion(delta : float):
	_potionAccumulator += delta
	if _potionAccumulator < PotionCheckInterval or agent == null or not ActorCommons.IsAlive(agent):
		return
	_potionAccumulator = 0.0

	var threshold : float = autoPotionPct / 100.0
	if agent.stat.current.maxHealth > 0 and float(agent.stat.health) / float(agent.stat.current.maxHealth) < threshold:
		_usePotion()

func _usePotion():
	if agent.inventory == null:
		return
	var cell : ItemCell = DB.GetItem(autoPotionItemHash)
	if cell == null or not cell.usable:
		return
	if agent.inventory.HasItem(cell, 1):
		agent.inventory.UseItem(cell)

# ------------------------------------------------------------------ metrics

func ComputeSessionEfficiency() -> float:
	if agent == null:
		return MinEfficiency

	if sessionGameTime <= 0.0:
		return 1.0

	var downtimeRatio : float = sessionDowntimeSecs / sessionGameTime
	var efficiency : float = 1.0 - downtimeRatio - float(sessionDeaths) * DeathPenalty
	return clampf(efficiency, MinEfficiency, 1.0)

func GetSessionDuration() -> float:
	return sessionGameTime

# Used by tests to inject deterministic downtime
func _addDowntime(secs : float):
	sessionDowntimeSecs += secs
