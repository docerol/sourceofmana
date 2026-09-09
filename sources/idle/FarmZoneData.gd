extends RefCounted
class_name FarmZoneData

# SOM-IDLE: F2 idle-spike zone model (TECH_SPEC_CORE.md §2 + XP_PROGRESSION.md §4.1.2)
# Zone 1 must map to a real starting map with low-level mobs; zones 2..N follow the
# scan ordering by minimum mob level, cycling over each map's own level sets.
# Spike footprint: 40 declared zones (xp/gold curves + par pacing); 28 map-backed.

const ZONE_COUNT : int = 40
const MAX_TIER : int = 8

# XP_PROGRESSION.md §4.1.2
const XpBasePerKill : int = 1200
const XpGrowthPerZone : float = 1.25
const GoldPerKillDiv : int = 8
const ParBaseSeconds : int = 6
const ParPerZoneSeconds : float = 0.25

# Tier pacing (power score gates; F2 stores them, F3/F4 enforce soft gating)
const TierPowerStep : int = 30

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

# Map-backed zone ordering: scan of data/maps/**/*.tmx by minimum mob level
# (mob level read from presets/entities/*.tres), each map contributing one zone
# per distinct level set. Towns (no mobs) are intentionally excluded.
const MapBackedNames : Array[String] = [
	"Candor Cave", "Ship Second Deck", "Splatyna's Corridor", "Artis Sewer",
	"Desert Mines", "Drazil", "Manayir", "Tulimshar", "Tulimshar Bay",
	"Tulimshar Center", "Sandstorm", "Desert Mountains", "Manayir Beach",
	"Tulimshar Beach", "Tulimshar Eastern Hills", "Tulimshar Western Hills",
	"Desert Abandoned Level", "Desert Mountain Cave", "Tulimshar Western Cave",
	"Desert Pit", "Tulimshar Southern Hills", "Ship Alige Hide",
	"Splatyna's Dorian Dead End", "Splatyna's Gabriel Pit",
	"Splatyna's Marvin Hole", "Tulimshar West Wall Pathway",
	"Splatyna's Chamber", "Snake Pit",
]

# Zone 1 farm map: contract requires a known low-level hunting ground.
const Zone1MapName : String = "Tulimshar Eastern Hills"

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

# XP_PROGRESSION.md §4.1.2: round(1200 * 1.25^(z-1)), gold = xp/8, par = 3600/(6+0.25*(z-1))
static func _make(zoneID : int, mapName : String, mapLevel : int) -> FarmZoneData:
	var data : FarmZoneData = FarmZoneData.new()
	data.id = zoneID
	data.tier = ceili(float(zoneID) / 5.0)
	data.mapName = mapName
	data.mapLevel = mapLevel
	data.minPower = (data.tier - 1) * TierPowerStep
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
