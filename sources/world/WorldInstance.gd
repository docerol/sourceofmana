class_name WorldInstance
extends SubViewport

#
var id : int							= 0
var npcs : Array[AIAgent]				= []
var mobs : Array[AIAgent]				= []
var players : Array[BaseAgent]			= []
var drops : Dictionary[int, Drop]		= {}
var map : WorldMap						= null
var timers : Node						= Node.new()
# SOM-IDLE: F2 — per-instance idle policies (server-only, ticked in _process)
var idlePolicies : Array[IdlePolicy]	= []

#
func _process(delta : float):
	# SOM-IDLE: F2 — tick idle policies; server-side only (Launcher.World guard)
	if Launcher.World != null and not idlePolicies.is_empty():
		for policy in idlePolicies:
			if policy and is_instance_valid(policy.agent):
				policy.Tick(delta)

# SOM-IDLE: F2 — register/unregister helpers for player policies
func AttachIdlePolicy(policy : IdlePolicy):
	if policy and not idlePolicies.has(policy):
		idlePolicies.append(policy)

func DetachIdlePolicy(policy : IdlePolicy):
	idlePolicies.erase(policy)

#
func _ready():
	timers.set_name("Timers")
	add_child.call_deferred(timers)

	if map.navPoly and not map.navPoly.get_vertices().is_empty():
		timers.tree_entered.connect(CheckNavReady)
	else:
		timers.tree_entered.connect(_map_loaded)

func CheckNavReady():
	if NavigationServer2D.map_get_iteration_id(map.mapRID) > 0 \
		and NavigationServer2D.region_owns_point(map.regionRID, map.navPoly.get_vertices()[0]):
		_map_loaded()
	else:
		Callback.SelfDestructTimer(timers, 0.1, CheckNavReady)

func _map_loaded():
	for spawn in map.spawns:
		if spawn:
			# SOM-IDLE: F2 — farm instances own their mob respawn loop so a
			# dedicated zone never depletes (ARCHITECTURE §7: instâncias dedicadas)
			if id >= IdlePolicyService.ZoneInstanceBase:
				# SOM-IDLE: F2 — farm instances own their mob respawn loop so a
				# dedicated zone never depletes (ARCHITECTURE §7: instâncias dedicadas)
				var farmSpawn : SpawnObject = spawn.duplicate()
				farmSpawn.map = map		# duplicate() copies only @export vars
				farmSpawn.is_persistant = true
				for i in farmSpawn.count:
					WorldAgent.CreateAgent(farmSpawn, id, farmSpawn.nick)
			else:
				for i in spawn.count:
					WorldAgent.CreateAgent(spawn, id, spawn.nick)
	RefreshProcessMode()

#
static func Create(_map : WorldMap, instanceID : int = 0) -> WorldInstance:
	assert(_map != null, "Could not create an instance on a non-valid map")
	if _map == null:
		return

	var inst : WorldInstance = WorldInstance.new()
	inst.id = instanceID
	inst.map = _map
	inst.name = _map.name + "_" + str(instanceID)

	WorldNavigation.CreateInstance(inst)
	Launcher.Root.add_child.call_deferred(inst)

	return inst

func Destroy():
	for i in range(players.size() - 1, -1, -1):
		WorldAgent.RemoveAgent(players[i])
	for i in range(mobs.size() - 1, -1, -1):
		WorldAgent.RemoveAgent(mobs[i])
	for i in range(npcs.size() - 1, -1, -1):
		WorldAgent.RemoveAgent(npcs[i])
	Launcher.Root.remove_child(self)
	queue_free()

#
func QueryProcessMode(delaySec : float = ActorCommons.MapProcessingToggleDelay):
	Callback.SelfDestructTimer(Launcher, delaySec, RefreshProcessMode, [], "ProcessMode_" + name)

func RefreshProcessMode():
	if players.is_empty() and timers.get_child_count() > 0:
		QueryProcessMode(ActorCommons.MapProcessingToggleExtraDelay)
	else:
		var toggle : bool = players.is_empty()
		set_process_mode(ProcessMode.PROCESS_MODE_DISABLED if toggle else ProcessMode.PROCESS_MODE_INHERIT)
		for npc in npcs:
			if npc.aiTimer:
				npc.aiTimer.set_paused(toggle)
			if npc.actionTimer:
				npc.actionTimer.set_paused(toggle)
		for mob in mobs:
			if mob.aiTimer:
				mob.aiTimer.set_paused(toggle)
			if mob.actionTimer:
				mob.actionTimer.set_paused(toggle)
