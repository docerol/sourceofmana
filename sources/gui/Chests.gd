extends WindowPanel

# SOM-IDLE beta GUI: Chests — baús fechados + odds públicas (compliance loot
# box) + último drop. Dados chegam pela RPC EconomyState (estado consolidado);
# abrir um baú devolve EconomyState fresco e esta janela se redesenha sozinha.
@onready var lastDropLabel : Label		= $Layout/LastDrop
@onready var oddsLabel : Label			= $Layout/Odds
@onready var chestList : VBoxContainer	= $Layout/ChestScroll/ChestList
@onready var hintLabel : Label			= $Layout/Hint

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshState()

func _on_visibility_changed():
	if is_visible():
		RefreshState()

func RefreshState():
	ShowLastDrop(NetClient.LastChestOpened)
	ShowState(NetClient.LastEconomyState)
	Network.GetEconomyState()

# Redesenho completo a partir do estado consolidado da conta.
func ShowState(state : Dictionary):
	if state.is_empty():
		return
	oddsLabel.text = "Odds: %s" % str(state.get("odds_text", "—"))
	for child in chestList.get_children():
		child.queue_free()
	var chests : Array = state.get("chests", [])
	hintLabel.text = "Closed chests: %d" % chests.size() if not chests.is_empty() else "No closed chests — earn via AFK settles or buy in the Shop."
	for chestID in chests:
		var btn : Button = Button.new()
		btn.text = "Open chest #%d" % int(chestID)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_chest_pressed.bind(int(chestID)))
		chestList.add_child(btn)

# Chamado pela NetClient.ChestOpened antes do EconomyState fresco chegar.
func ShowLastDrop(result : Dictionary):
	if result.is_empty():
		return
	var pityTag : String = " [PITY!]" if bool(result.get("pity", false)) else ""
	lastDropLabel.text = "Last drop: %s x%d%s" % [str(result.get("item_name", "?")), int(result.get("count", 1)), pityTag]

func _on_chest_pressed(chestID : int):
	Network.OpenChest(chestID)
