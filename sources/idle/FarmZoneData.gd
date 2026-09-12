extends RefCounted
class_name FarmZoneData

# SOM-IDLE: F2 idle-spike zone model, RECALIBRADO (2026-09) contra o dump real de
# mapas/mobs (tests/dump_calibration.gd). Só 28 mapas têm mobs e o nível deles
# cap-a em L20; 4 salas de boss (Dorian/Gabriel/Marvin/Splatyna) saíram do
# rodízio de farm e viram conteúdo de boss-key. Restam 24 zonas de farm reais,
# reordenadas por dificuldade monotônica. O antigo catálogo de 40 zonas tinha 12
# placeholders sem mapa e ordem não-monotônica.

const ZONE_COUNT : int = 24
const ZonesPerTier : int = 3				# 8 tiers × 3 zonas = 24
const MAX_TIER : int = 8

# XP_PROGRESSION.md §4.1.2
const XpBasePerKill : int = 1200
const XpGrowthPerZone : float = 1.25
const GoldPerKillDiv : int = 8
# SOM-IDLE: par RECALIBRADO pós-fix do cancelamento de cast + dano-mínimo do
# idle (commit 0f56808 e SkillCommons.FarmDamageFloor). O probe em tempo real
# mede agora ~160–184 kills/h na zona 1 (era ~72 com os casts cancelados). O
# par alimenta o ganho OFFLINE (OfflineSettle: xpPerKill × par × h × eff), então
# precisa casar a taxa online real; ~24s/kill na zona 1, subindo suavemente com
# a densidade/nível das zonas fundas.
const ParBaseSeconds : float = 24.0
const ParPerZoneSeconds : float = 0.9

# Tier pacing. minPower era (tier-1)*30 — baixo demais (um char nu L2 já tem
# power ~35 e entrava em tier 2). Agora é uma escada suave por ZONA, amarrada
# ao power nu do nível-intenção da zona (fit medido: nakedPower ≈ 14 + 10.7*L).
# Gear soma attack/defense ao power, então loadout bom deixa "socar acima".
const MinPowerBase : int = 24
const MinPowerPerZone : int = 8

# SOM-IDLE: F3 — dedicated farm spawn table (TECH_SPEC_CORE §2, spike report §5.3).
# Farm instances stop copying the adventure-map spawn density: each zone scales
# its own map spawns to feed the pacing par, with tier-scaled respawn.
# multiplier = 2 + tier (t1 → 3x, t8 → 10x base group counts)
# respawn    = 18s - 2s*tier clamped to [4s, 16s] (t1 → 16s, t8 → 4s)
const FarmSpawnBaseMultiplier : int = 2
const FarmRespawnBaseSeconds : float = 18.0
const FarmRespawnStepSeconds : float = 2.0
const FarmRespawnMinSeconds : float = 4.0

# SOM-IDLE: F3 — item tier bands (ItemCell.tier 1..8). A zone drops items from
# its own tier band [tier, min(tier+1, 8)]; empty pools fall back to the Apple.
const DropTierBandSize : int = 2

# Spike drop catalog: zone 1 loots Apple (health potion) at 150 ppm ≈ 540/h
const DefaultDropItemHash : int = 215387671		# Apple
const DefaultDropRatePPM : int = 150

const DeathTaxPct : int = 5
const MaxChestsPerSettle : int = 3
const ChestHoursPerChest : int = 4

# XP_PROGRESSION.md §4.1.3: newbie boost x5 until level 10
const NewbieBoostMaxLevel : int = 10
const NewbieBoostFactor : int = 5

#
var id : int								= 0
var tier : int								= 1
var mapID : int								= DB.UnknownHash
var mapName : String						= ""
var mapLevel : int							= 0
var minPower : int							= 0
var xpPerKill : int							= 0
var goldPerKill : int						= 0
var parKillsPerHour : int					= 0
var goldPerHour : int						= 0
var dropItemHash : int						= DefaultDropItemHash
var dropRatePPM : int						= DefaultDropRatePPM
var deathTaxPct : int						= DeathTaxPct

# Farm zone ordering — RECALIBRADO: os 24 mapas reais com mobs (fora os 4 de
# boss) ordenados por dificuldade do mob dominante (nível, depois nível máx),
# do dump de calibração. Difficuldade agora é monotônica zona a zona.
const MapBackedNames : Array[String] = [
	"Candor Cave", "Splatyna's Corridor", "Ship Second Deck",
	"Tulimshar", "Tulimshar Center", "Artis Sewer",
	"Sandstorm", "Tulimshar Bay", "Desert Mines",
	"Desert Abandoned Level", "Tulimshar Western Cave", "Tulimshar Eastern Hills",
	"Ship Alige Hide", "Tulimshar West Wall Pathway", "Tulimshar Western Hills",
	"Manayir", "Drazil", "Tulimshar Beach",
	"Manayir Beach", "Tulimshar Southern Hills", "Desert Pit", "Snake Pit",
	"Desert Mountain Cave", "Desert Mountains",
]

# SOM-IDLE: salas de boss (mob único nomeado, sprite próprio) — fora do rodízio
# de farm, viram conteúdo de boss-key (chave dropada pelos mobs de farm abre a
# luta contra o boss; boss escala com o nível do char, recompensa com xp/drop
# turbinados). Índice i → level do boss para escalar.
const BossMapNames : Array[String] = [
	"Splatyna's Dorian Dead End", "Splatyna's Gabriel Pit",
	"Splatyna's Marvin Hole", "Splatyna's Chamber",
]
const BossBaseLevel : int = 5

static var _catalog : Array[FarmZoneData]			= []
static var _mapIndex : Dictionary[int, int]			= {}

#
static func _build():
	if not _catalog.is_empty():
		return

	var mapLevels : Dictionary[String, int] = _scanMapLevels()
	var zoneID : int = 1
	for mapName in MapBackedNames:
		if zoneID > ZONE_COUNT:
			break
		var mapLevel : int = mapLevels.get(mapName, 0)
		_catalog.append(_make(zoneID, mapName, mapLevel))
		zoneID += 1

	# Pad remaining zones with derived placeholders so the curve contract holds.
	while zoneID <= ZONE_COUNT:
		var name : String = "Zone %d (unmapped)" % zoneID
		var data : FarmZoneData = _make(zoneID, name, 0)
		data.mapID = DB.UnknownHash
		_catalog.append(data)
		zoneID += 1

	for data in _catalog:
		if data.mapID != DB.UnknownHash:
			_mapIndex[data.mapID] = data.id

# Curvas recalibradas sobre ZONE_COUNT (24) zonas reais:
#   tier       = ceil(z / ZonesPerTier)      (3 zonas/tier, 8 tiers)
#   minPower   = MinPowerBase + MinPowerPerZone*(z-1)   (escada suave, power nu
#                do nível-intenção; gear deixa socar acima)
#   xpPerKill  = round(1200 * 1.25^(z-1))    (curva do doc, agora termina em z24)
#   gold       = xp/8
#   par/h      = 3600/(24 + 0.9*(z-1))       (~150/h na z1, ~96/h na z24)
static func _make(zoneID : int, mapName : String, mapLevel : int) -> FarmZoneData:
	var data : FarmZoneData = FarmZoneData.new()
	data.id = zoneID
	data.tier = clampi(ceili(float(zoneID) / float(ZonesPerTier)), 1, MAX_TIER)
	data.mapName = mapName
	data.mapLevel = mapLevel
	data.minPower = MinPowerBase + MinPowerPerZone * (zoneID - 1)
	data.xpPerKill = roundi(XpBasePerKill * pow(XpGrowthPerZone, zoneID - 1))
	data.goldPerKill = roundi(float(data.xpPerKill) / float(GoldPerKillDiv))
	data.parKillsPerHour = roundi(3600.0 / (float(ParBaseSeconds) + ParPerZoneSeconds * float(zoneID - 1)))
	data.goldPerHour = data.parKillsPerHour * data.goldPerKill
	data.mapID = DB.UnknownHash
	return data

# Resolve a real map hash by display name from the generated map database.
static func _scanMapLevels() -> Dictionary[String, int]:
	var result : Dictionary[String, int] = {}
	if not DB.isInitialized:
		return result

	for mapID in DB.MapsDB:
		var mapData : FileData = DB.MapsDB[mapID]
		if mapData and not mapData._name.is_empty():
			result[mapData._name] = mapID
	return result

static func _resolveMapID(mapName : String) -> int:
	if not DB.isInitialized:
		return DB.UnknownHash
	for mapID in DB.MapsDB:
		if DB.MapsDB[mapID]._name == mapName:
			return mapID
	return DB.UnknownHash

#
static func GetZone(zoneID : int) -> FarmZoneData:
	_build()
	return _catalog[zoneID - 1] if zoneID >= 1 and zoneID <= _catalog.size() else null

static func GetZoneForMap(mapID : int) -> FarmZoneData:
	_build()
	var zoneID : int = _mapIndex.get(mapID, 0)
	return GetZone(zoneID) if zoneID > 0 else null

static func GetZoneCount() -> int:
	_build()
	return _catalog.size()

static func GetMapIDForZone(zoneID : int) -> int:
	var zone : FarmZoneData = GetZone(zoneID)
	return zone.mapID if zone else DB.UnknownHash

# Refresh map hashes once the database is up (idempotent, no-op before DB init).
static func SyncWithDB():
	_build()
	if _mapIndex.is_empty() and DB.isInitialized:
		for data in _catalog:
			if data.mapName != "" and data.mapID == DB.UnknownHash:
				data.mapID = _resolveMapID(data.mapName)
				if data.mapID != DB.UnknownHash:
					_mapIndex[data.mapID] = data.id

# ------------------------------------------------------------------ F3: dedicated farm spawn table

# Density multiplier applied to every spawn group of the zone's own map when
# the dedicated farm instance is populated (WorldInstance._map_loaded).
static func GetFarmSpawnMultiplier(zoneID : int) -> int:
	var zone : FarmZoneData = GetZone(zoneID)
	return FarmSpawnBaseMultiplier + (zone.tier if zone else 1)

# Respawn delay for farm-instance mobs (seconds) — tier-scaled: deeper zones
# replenish faster because mob kills are slower and walks are longer.
static func GetFarmRespawnDelay(zoneID : int) -> float:
	var zone : FarmZoneData = GetZone(zoneID)
	var tier : int = zone.tier if zone else 1
	return clampf(FarmRespawnBaseSeconds - FarmRespawnStepSeconds * float(tier), FarmRespawnMinSeconds, FarmRespawnBaseSeconds)

# ------------------------------------------------------------------ F3: tier-banded drop pools

static var _dropPoolCache : Dictionary[int, Array] = {}

# Item hashes whose tier falls inside the zone's band [tier, tier+band-1].
# Deterministic order (hash ascending) so rolls are reproducible.
static func GetDropPool(zoneID : int) -> Array:
	_build()
	var pool : Array = _dropPoolCache.get(zoneID, [])
	if not pool.is_empty():
		return pool

	var zone : FarmZoneData = GetZone(zoneID)
	if zone == null:
		return [DefaultDropItemHash]

	var tierMax : int = mini(zone.tier + DropTierBandSize - 1, MAX_TIER)
	var candidates : Array[int] = []
	for cellHash in DB.ItemsDB:
		var item : ItemCell = DB.ItemsDB[cellHash]
		if item != null and item.tier >= zone.tier and item.tier <= tierMax:
			candidates.append(cellHash)
	candidates.sort()

	if candidates.is_empty():
		# Band empty (early tiers have few items): fall one tier down, then Apple
		for fallbackTier in range(zone.tier - 1, 0, -1):
			for cellHash in DB.ItemsDB:
				var item : ItemCell = DB.ItemsDB[cellHash]
				if item != null and item.tier == fallbackTier:
					candidates.append(cellHash)
			if not candidates.is_empty():
				candidates.sort()
				break
		if candidates.is_empty():
			candidates = [DefaultDropItemHash]

	_dropPoolCache[zoneID] = candidates
	return candidates

# Deterministic pick for a zone drop roll (caller supplies a stable roll input)
static func GetDropForRoll(zoneID : int, roll : int) -> int:
	var pool : Array = GetDropPool(zoneID)
	return pool[roll % pool.size()] if not pool.is_empty() else DefaultDropItemHash

static func InvalidateDropPools():
	_dropPoolCache.clear()
