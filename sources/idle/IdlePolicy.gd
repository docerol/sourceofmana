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
# SOM-IDLE D1: farm vigor — policy-driven agents regen stamina/mana fast
# enough to sustain auto-combat (a melee swing costs 10 stamina; base regen
# starves a L1 farmer after ~5 swings and 99% of casts fizzle). Farm instances
# are idle-only, so this never touches live balance, damage or power score.
const FarmVigorStaminaPct : float = 0.5
const FarmVigorManaPct : float = 0.5

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

# SOM-IDLE D1: pacing instrumentation (where does farm time go?).
var metricSeekTicks : int						= 0
var metricCombatTicks : int					= 0
var metricLootTicks : int						= 0
var metricNoTargetTicks : int					= 0
var metricAttacksCast : int					= 0
var metricWalkDistance : float					= 0.0
var _metricLastPos : Vector2					= Vector2.ZERO

var currentTargetRID : int					= 0
# SOM-IDLE: boss-key ladder — quando bossIndex>=0 o char está num duelo de boss:
# persegue e ataca SÓ o boss (bossRID) e uma morte do char é derrota (ApplyXp
# cuida da vitória quando o boss cai). Runtime-only.
var bossRID : int							= 0
var bossIndex : int							= -1
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
	metricSeekTicks = 0
	metricCombatTicks = 0
	metricLootTicks = 0
	metricNoTargetTicks = 0
	metricAttacksCast = 0
	metricWalkDistance = 0.0
	_lastPosition = agent.position if agent else Vector2.ZERO
	_metricLastPos = _lastPosition

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
	if agent:
		metricWalkDistance += agent.position.distance_to(_metricLastPos)
		_metricLastPos = agent.position
	_tickVigor(delta)

	# SOM-IDLE: boss duel — se o farmer caiu enquanto o boss ainda vive, é
	# derrota (a chave já foi gasta no desafio). Consolação + limpa o duelo; a
	# vitória chega por outro caminho (Formula.ApplyXp quando o boss morre).
	if bossIndex >= 0 and not ActorCommons.IsAlive(agent):
		var lostIndex : int = bossIndex
		bossIndex = -1
		bossRID = 0
		currentTargetRID = 0
		IdlePolicyService.OnBossResult(agent, lostIndex, false)
		return

	match state:
		State.IDLE:
			state = State.SEEK
		State.SEEK:
			metricSeekTicks += 1
			_tickSeek(delta)
		State.COMBAT:
			metricCombatTicks += 1
			_tickCombat(delta)
		State.LOOT:
			metricLootTicks += 1
			_tickLoot(delta)
		State.DEAD:
			_tickDead(delta)

	_tickStuck(delta)
	_tickPotion(delta)

func _tickVigor(delta : float):
	if agent == null or agent.stat == null or not ActorCommons.IsAlive(agent):
		return
	var maxStam : int = agent.stat.current.maxStamina
	if maxStam > 0 and agent.stat.stamina < maxStam:
		agent.stat.SetStamina(maxi(1, int(float(maxStam) * FarmVigorStaminaPct * delta)))
	var maxMana : int = agent.stat.current.maxMana
	if maxMana > 0 and agent.stat.mana < maxMana:
		agent.stat.SetMana(maxi(1, int(float(maxMana) * FarmVigorManaPct * delta)))

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

	metricNoTargetTicks += 1
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

	# SOM-IDLE: num duelo de boss, o alvo é SEMPRE o boss (ignora o resto do farm).
	if bossRID != 0:
		var boss : AIAgent = WorldAgent.GetAgent(bossRID) as AIAgent
		if boss != null and is_instance_valid(boss) and ActorCommons.IsAlive(boss):
			return boss

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
		# SOM-IDLE: nunca cancele um cast em progresso para perseguir. Melee é
		# static cast (castWalk=false) e WalkToward chama Skill.Stopped — na
		# borda de range o flicker de wander cancelava a esmagadora maioria dos
		# casts em real-time (probe: 995 casts / 1 kill; sims comprimidos não
		# sofrem porque o cast resolve em ~1,5 frames no timeScale 20). Deixa o
		# swing resolver e aproxima no tick seguinte; o failsafe STUCK cobre
		# casos patológicos.
		if not SkillCommons.IsCasting(agent) and not SkillCommons.HasAnyActionInProgress(agent):
			agent.WalkToward(target.position)
	else:
		# SOM-IDLE D1: chama Cast só quando um cast real pode começar
		# (predicados do próprio motor). Sem isso cada tick empilha um timer
		# que morre no Process — milhares de timers/seg por farmer no servidor.
		if not SkillCommons.HasAnyActionInProgress(agent) and not SkillCommons.IsCasting(agent) and not SkillCommons.IsCoolingDown(agent, skill):
			Skill.Cast(agent, target, skill)
			_attackedTarget = true
			metricAttacksCast += 1

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

# SOM-IDLE D1: pacing breakdown for the sim suites (all game-time based).
func SnapshotMetrics() -> Dictionary:
	var hours : float = maxf(1.0 / 3600.0, sessionGameTime / 3600.0)
	return {
		"kills" = sessionKills,
		"kills_per_hour" = float(sessionKills) / hours,
		"seek_ticks" = metricSeekTicks,
		"combat_ticks" = metricCombatTicks,
		"loot_ticks" = metricLootTicks,
		"no_target_ticks" = metricNoTargetTicks,
		"attacks_cast" = metricAttacksCast,
		"walk_distance" = metricWalkDistance,
		"secs_per_kill" = sessionGameTime / maxf(1.0, float(sessionKills)),
		"attacks_per_kill" = float(metricAttacksCast) / maxf(1.0, float(sessionKills)),
	}

# Used by tests to inject deterministic downtime
func _addDowntime(secs : float):
	sessionDowntimeSecs += secs
