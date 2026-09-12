extends RefCounted
class_name IdlePolicyService

# SOM-IDLE: F2 idle-spike integration glue (TECH_SPEC_CORE §2/§6)
# Attaches IdlePolicy brains to online players inside dedicated farm instances.
# Instance id convention: ZoneInstanceBase + zoneID (zone 1..40 → ids 1001..1040).

const ZoneInstanceBase : int = 1000
const BossInstanceBase : int = 9000		# arena PRIVADA de boss por char (id = base + charID)
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

# ------------------------------------------------------------------ boss-key ladder (live fight)

# Abre um duelo de boss VISÍVEL: cria uma arena PRIVADA (instância dedicada só
# deste char), move o farmer pra lá e spawnia o boss ESCALADO ao nível do char.
# O IdlePolicy já anima o combate, a câmera segue o char → o jogador VÊ a luta.
# A recompensa é liquidada em OnBossResult (vitória: morte do boss via ApplyXp;
# derrota: morte do char via IdlePolicy.Tick). Retorna {started} p/ o chamador.
static func StartBossFight(player : PlayerAgent, index : int) -> Dictionary:
	if not IsServerSide() or player == null or not is_instance_valid(player) or player.idlePolicy == null:
		return {"started" = false}
	var policy : IdlePolicy = player.idlePolicy
	if policy.bossIndex >= 0:
		return {"started" = false}	# já está num duelo

	var zoneID : int = policy.zoneID
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return {"started" = false}
	var map : WorldMap = Launcher.World.GetMap(zone.mapID)
	if map == null:
		return {"started" = false}
	if BossService.GetBossEntityHash(index) == DB.UnknownHash:
		return {"started" = false}

	var binstID : int = BossInstanceBase + player.GetCharacterID()
	if not map.instances.has(binstID):
		map.CreateInstance(binstID)

	if _IsInstanceWarm(map, binstID):
		_BeginArena(player, map, binstID, index)
		return {"started" = true, "index" = index}

	var retries : int = ceili(float(InstanceWaitTimeoutMS) / 500.0)
	Callback.SelfDestructTimer(Launcher, 0.5, _RetryArena, [player, index, binstID, zoneID, retries], "BossArena_" + str(player.GetCharacterID()))
	return {"started" = true, "index" = index}

static func _RetryArena(player : PlayerAgent, index : int, binstID : int, zoneID : int, retriesLeft : int):
	if player == null or not is_instance_valid(player) or not IsServerSide() or player.idlePolicy == null:
		return
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone == null or zone.mapID == DB.UnknownHash:
		return
	var map : WorldMap = Launcher.World.GetMap(zone.mapID)
	if map == null or not map.instances.has(binstID):
		return
	if _IsInstanceWarm(map, binstID):
		_BeginArena(player, map, binstID, index)
	elif retriesLeft > 0:
		Callback.SelfDestructTimer(Launcher, 0.5, _RetryArena, [player, index, binstID, zoneID, retriesLeft - 1], "BossArena_" + str(player.GetCharacterID()))
	else:
		# A arena nunca aqueceu: nunca movemos o char (ele seguiu farm), então
		# liquidamos pela sim de fallback para ele NÃO ficar com a chave gasta e
		# o duelo pendurado. Libera a instância parcial.
		_BossWarmupFailed(player, map, binstID, index)

# Recuperação de warmup: resolve o duelo já gasto pela sim e entrega o resultado.
static func _BossWarmupFailed(player : PlayerAgent, map : WorldMap, binstID : int, index : int):
	map.DestroyInstance(binstID)
	if player.idlePolicy != null:
		player.idlePolicy.bossIndex = -1
		player.idlePolicy.bossRID = 0
	if Launcher.Economy != null and player.stat != null:
		var duel : Dictionary = BossService.Resolve(BossService.PlayerFightSnapshot(player), BossService.GetBossLevel(player.stat.level, index))
		var result : Dictionary = Launcher.Economy.SettleBossResult(player.GetCharacterID(), player, index, bool(duel.get("win", false)))
		if player.peerID != NetworkCommons.PeerUnknownID:
			Network.BossResult(result, player.peerID)
			Network.BossState(Launcher.Economy.GetBossState(player.GetCharacterID(), player.stat.level), player.peerID)
	Util.PrintLog("Idle", "Boss arena failed to warm for char %d — resolved via sim" % player.GetCharacterID())

# Warp do farmer pra arena + spawn/escalamento do boss na frente dele.
static func _BeginArena(player : PlayerAgent, map : WorldMap, binstID : int, index : int):
	var inst : WorldInstance = map.instances.get(binstID, null)
	if inst == null:
		return
	var data : EntityData = DB.EntitiesDB.get(BossService.GetBossEntityHash(index), null)
	if data == null:
		_BossWarmupFailed(player, map, binstID, index)	# não move o char p/ arena morta
		return

	var pSpawn : SpawnObject = SpawnObject.new()
	pSpawn.map = map
	pSpawn.type = ActorCommons.Type.PLAYER
	pSpawn.id = DB.PlayerHash
	pSpawn.is_global = true
	pSpawn.spawn_offset = Vector2i(96, 96)
	var playerPos : Vector2i = WorldNavigation.GetSpawnPosition(inst, pSpawn)
	if playerPos == Vector2i.ZERO:
		playerPos = player.position
	Launcher.World.Warp(player, map, playerPos, ActorCommons.Direction.RIGHT, binstID)

	var bSpawn : SpawnObject = SpawnObject.new()
	bSpawn.map = map
	bSpawn.type = ActorCommons.Type.MONSTER
	bSpawn.id = data._id
	bSpawn.is_global = false
	bSpawn.spawn_offset = Vector2i(64, 0)
	var boss : BaseAgent = WorldAgent.CreateAgent(bSpawn, binstID, BossService.GetBossName(index))
	if not (boss is MonsterAgent):
		# o char já foi movido pra arena; devolve ao farm e liquida pela sim
		var backZone : int = player.idlePolicy.zoneID if player.idlePolicy != null else 1
		StartIdleSession(player, backZone)
		_BossWarmupFailed(player, map, binstID, index)
		return
	_ScaleBoss(boss as MonsterAgent, player.stat.level, index)
	(boss as MonsterAgent).idleBossIndex = index
	# cola o boss na frente do char (espetacularidade; pos dentro do nav da arena)
	Launcher.World.Warp(boss, map, playerPos + Vector2i(48, 0), ActorCommons.Direction.LEFT, binstID)

	if player.idlePolicy != null:
		player.idlePolicy.bossRID = boss.get_rid().get_id()
		player.idlePolicy.bossIndex = index
	Util.PrintLog("Idle", "Player %s challenges boss #%d (%s L%d) in arena %d" % [player.nick, index, BossService.GetBossName(index), player.stat.level, binstID])

# Escala o mob do boss ao nível do char + tanque de HP (×BossHpMult) pra a luta
# renderizada durar alguns swings e "ficar sempre difícil". Runtime-only.
static func _ScaleBoss(boss : MonsterAgent, playerLevel : int, index : int):
	if boss.stat == null:
		return
	boss.stat.level = maxi(1, playerLevel)
	boss.stat.RefreshEntityStats()
	var extra : int = roundi(float(boss.stat.current.maxHealth) * float(BossService.BossHpMult - 1))
	if extra > 0:
		var mod : StatModifier = StatModifier.new()
		mod._effect = CellCommons.Modifier.MaxHealth
		mod._value = extra
		mod._persistent = true
		boss.stat.modifiers.Add(mod)
		boss.stat.RefreshEntityStats()
	boss.stat.health = boss.stat.current.maxHealth
	boss.SetData()

# Liquida o duelo (vitória ou derrota), entrega a recompensa e devolve o char pro
# farm. Chamado por Formula.ApplyXp (boss morreu) e por IdlePolicy.Tick (char
# morreu). Guardado por bossIndex: só o primeiro resultado vale.
static func OnBossResult(player : PlayerAgent, index : int, victory : bool):
	if player == null or not is_instance_valid(player) or player.idlePolicy == null:
		return
	var policy : IdlePolicy = player.idlePolicy
	if policy.bossIndex != index:
		return	# duelo já resolvido (evita dupla contagem vitória+derrota)
	var charID : int = player.GetCharacterID()
	var zoneID : int = policy.zoneID
	policy.bossIndex = -1
	policy.bossRID = 0

	var result : Dictionary = {}
	if Launcher.Economy != null:
		result = Launcher.Economy.SettleBossResult(charID, player, index, victory)
	if result.is_empty():
		result = {"ok" = true, "started" = false, "win" = victory, "index" = index, "boss" = BossService.GetBossName(index)}

	# push assíncrono pro cliente que está assistindo a luta
	if player.peerID != NetworkCommons.PeerUnknownID:
		Network.BossResult(result, player.peerID)
		if Launcher.Economy != null and player.stat != null:
			Network.BossState(Launcher.Economy.GetBossState(charID, player.stat.level), player.peerID)

	# volta pro farm (na thread da morte é tarde demais p/ warp; delega 1 frame)
	Callback.SelfDestructTimer(Launcher, 0.1, _ReturnAfterBoss, [player, zoneID], "BossReturn_" + str(charID))

static func _ReturnAfterBoss(player : PlayerAgent, zoneID : int):
	if player == null or not is_instance_valid(player) or not IsServerSide():
		return
	StartIdleSession(player, zoneID)
	var charID : int = player.GetCharacterID()
	var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
	if zone != null and zone.mapID != DB.UnknownHash and Launcher.World != null:
		var map : WorldMap = Launcher.World.GetMap(zone.mapID)
		var binstID : int = BossInstanceBase + charID
		if map != null and map.instances.has(binstID):
			map.DestroyInstance(binstID)
