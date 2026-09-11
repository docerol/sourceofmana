extends WindowPanel

# SOM-IDLE onboarding: Zone Map — lista as 40 zonas com gate de poder e
# recompensa/hora; clicar chama SetFarmZone (servidor valida e inicia a sessão).
@onready var zoneList : VBoxContainer = $Layout/ZoneScroll/ZoneList

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshZones()

func _on_visibility_changed():
	if is_visible():
		RefreshZones()

func RefreshZones():
	if zoneList == null:
		return
	for child in zoneList.get_children():
		child.queue_free()
	var power : int = 0
	if Launcher.Player and Launcher.Player.stat:
		power = Formula.GetPowerScore(Launcher.Player.stat)
	for zoneID in range(1, FarmZoneData.GetZoneCount() + 1):
		var zone : FarmZoneData = FarmZoneData.GetZone(zoneID)
		if zone == null:
			continue
		var btn : Button = Button.new()
		var open : bool = zone.mapID != DB.UnknownHash and (zone.tier <= 1 or power >= zone.minPower)
		var why : String = ""
		if zone.mapID == DB.UnknownHash:
			why = "undiscovered"
		elif zone.tier > 1 and power < zone.minPower:
			why = "need power %d" % zone.minPower
		else:
			why = "%d kills/h" % zone.parKillsPerHour
		btn.text = "Z%d %s [T%d] — %s" % [zoneID, zone.mapName, zone.tier, why]
		btn.disabled = not open
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if open:
			btn.pressed.connect(_on_zone_pressed.bind(zoneID))
		zoneList.add_child(btn)

func _on_zone_pressed(zoneID : int):
	Network.SetFarmZone(zoneID)
	ToggleControl()
