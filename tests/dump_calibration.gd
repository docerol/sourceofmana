extends SceneTree

# SOM-IDLE: calibration dump — inventário real de zonas × mapas × mobs × curva
# de nível, para a recalibração de pacing (XP_PROGRESSION §4, F3 knobs).
# Usage: godot --headless --path . -s tests/dump_calibration.gd
# Duck-typed like run_idle_tests.gd (-s scripts compile before autoloads).

func _initialize():
	_dump()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _dump():
	var launcher : Node = _getAutoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var worldNode : Node = launcher.World
		if worldNode != null and worldNode.isInitialized:
			break
	print("== boot wait done (%d ms) ==" % waited)

	var farmScript : GDScript = load("res://sources/idle/FarmZoneData.gd")
	var commonsScript : GDScript = load("res://sources/actor/ActorCommons.gd")
	var monsterType : int = commonsScript.Type.MONSTER
	# SOM-IDLE: resolve mapID das zonas contra o DB carregado (idempotente)
	farmScript.SyncWithDB()
	var formulaScript : GDScript = load("res://sources/actor/stat/Formula.gd")
	var expScript : GDScript = load("res://sources/actor/stat/Experience.gd")
	var dbScript : GDScript = load("res://sources/db/DB.gd")

	print("\n=== A. CURVA DE NÍVEL (XP necessário L->L+1) ===")
	var cum : int = 0
	for lvl in [1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 60, 75, 100, 125, 150]:
		var need : int = expScript.GetNeededExperienceForNextLevel(lvl)
		print("L%-4d needed=%-14d cumToReach~%d" % [lvl, need, cum])
		cum += need

	print("\n=== B. ZONAS (catálogo F3) ===")
	print("zone | map                        | mapLevel(field) | tier | minPower | xp/kill   | gold/kill | par/h | spawnMul | respawn")
	var zoneCount : int = farmScript.ZONE_COUNT
	for z in range(1, zoneCount + 1):
		var zone = farmScript.GetZone(z)
		if zone == null:
			continue
		var realMap : bool = zone.mapID != dbScript.UnknownHash
		var mapName : String = zone.mapName if realMap else "(sem mapa)"
		var mul : int = farmScript.GetFarmSpawnMultiplier(z) if realMap else 0
		var rsp : float = farmScript.GetFarmRespawnDelay(z) if realMap else 0.0
		print("%-5d| %-26s | %-15s | %-4d | %-8d | %-9d | %-9d | %-5d | %-8d | %.0fs %s" % [
			z, mapName, str(zone.mapLevel), zone.tier, zone.minPower,
			zone.xpPerKill, zone.goldPerKill, zone.parKillsPerHour, mul, rsp,
			("" if realMap else "<-- OCULTA (mapID Unknown)")])

	print("\n=== C. ROSTER DE MOBS POR MAPA (WorldMap runtime) ===")
	var worldNode : Node = launcher.World
	for z in range(1, zoneCount + 1):
		var zone = farmScript.GetZone(z)
		if zone == null or zone.mapID == dbScript.UnknownHash:
			continue
		var worldMap = worldNode.GetMap(zone.mapID)
		if worldMap == null:
			print("zone %d %s: MAPA NAO CARREGADO" % [z, zone.mapName])
			continue
		var lines : Array[String] = []
		var census : Dictionary = {}
		for spawn in worldMap.spawns:
			if spawn == null or spawn.type != monsterType:
				continue
			var entity = dbScript.EntitiesDB.get(spawn.id, null)
			var ename : String = entity._name if entity else "?"
			var elvl : int = int(entity._stats.get("level", 0)) if entity else 0
			var key : String = "%s L%d" % [ename, elvl]
			census[key] = int(census.get(key, 0)) + spawn.count
		for key in census.keys():
			lines.append("%s x%d" % [key, census[key]])
		print("zone %-3d %-26s mobs: %s" % [z, zone.mapName, "; ".join(lines)])

	print("\n=== D. STATS DE COMBATE POR MOB (síntese ActorStats sobre entidade mesclada) ===")
	var statScript2 : GDScript = load("res://sources/actor/Stats.gd")
	var mobNames : Dictionary = {}
	for z in range(1, zoneCount + 1):
		var zone = farmScript.GetZone(z)
		if zone == null or zone.mapID == dbScript.UnknownHash:
			continue
		var worldMap = worldNode.GetMap(zone.mapID)
		if worldMap == null:
			continue
		for spawn in worldMap.spawns:
			if spawn == null or spawn.type != monsterType:
				continue
			var entity = dbScript.EntitiesDB.get(spawn.id, null)
			if entity == null:
				continue
			if not mobNames.has(entity._name):
				mobNames[entity._name] = spawn.id
	for mobName in mobNames.keys():
		var entity = dbScript.EntitiesDB.get(mobNames[mobName], null)
		if entity == null:
			continue
		var merged = entity.GetMergedEntity() if entity.has_method("GetMergedEntity") else entity
		var stat = statScript2.new()
		var statsDict : Dictionary = merged._stats
		stat.SetStats(statsDict)
		stat.SetEntityStats(statsDict)
		var lvl : int = stat.level
		var hp : int = stat.current.maxHealth
		var atk : int = stat.current.attack
		var dfn : int = stat.current.defense
		var rng : float = stat.current.attackRange
		var castDelay : float = stat.current.castAttackDelay
		var cooldown : float = stat.current.cooldownAttackDelay
		print("%-24s hash=%-11d L%-3d hp=%-5d atk=%-4d def=%-3d range=%-3d castDelay=%.2f cooldown=%.2f" % [
			mobName, mobNames[mobName], lvl, hp, atk, dfn, rng, castDelay, cooldown])

	# --- E: power score de char nu por nível (calibração de minPower) ---
	print("\n=== E. POWER DE CHAR NU POR NIVEL ===")
	var playerEntity = dbScript.EntitiesDB.get(dbScript.PlayerHash, null)
	for lvl in [1, 2, 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150]:
		var stat = statScript2.new()
		var base : Dictionary = {"level": lvl}
		if playerEntity:
			for k in playerEntity.GetMergedEntity()._stats:
				if k != "level":
					base[k] = playerEntity.GetMergedEntity()._stats[k]
		stat.SetStats(base)
		stat.SetEntityStats(base)
		var power : int = formulaScript.GetPowerScore(stat)
		print("L%-4d power=%d" % [lvl, power])

	quit(0)
