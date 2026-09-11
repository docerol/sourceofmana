extends WindowPanel

# SOM-IDLE beta GUI: Shop — sink de gems (chests) + checkout VIP. Compras são
# server-authoritative (EconomyService); a resposta traz ShopFeedback +
# EconomyState fresco, que redesenha esta janela via NetClient.
@onready var gemsLabel : Label	= $Layout/Gems
@onready var vipLabel : Label	= $Layout/VIP
@onready var buyChest1 : Button	= $Layout/BuyChest1
@onready var buyChest5 : Button	= $Layout/BuyChest5
@onready var buyVip1 : Button	= $Layout/BuyVip1
@onready var buyVip2 : Button	= $Layout/BuyVip2

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshState()

func _on_visibility_changed():
	if is_visible():
		RefreshState()

func RefreshState():
	ShowState(NetClient.LastEconomyState)
	Network.GetEconomyState()

# Redesenho a partir do estado consolidado (preços vivem no servidor).
func ShowState(state : Dictionary):
	if state.is_empty():
		return
	gemsLabel.text = "Gems: %s" % Util.FormatNumber(int(state.get("gems", 0)))
	var chestCost : int = int(state.get("chest_cost", 120))
	var vip1Cost : int = int(state.get("vip1_cost", 440))
	var vip2Cost : int = int(state.get("vip2_cost", 880))
	buyChest1.text = "Buy 1 Chest — %d gems" % chestCost
	buyChest5.text = "Buy 5 Chests — %d gems" % (chestCost * 5)
	buyVip1.text = "VIP 1 — %d gems / 30 days (+20%% AFK)" % vip1Cost
	buyVip2.text = "VIP 2 — %d gems / 30 days (+20%% AFK)" % vip2Cost

	var vip : Dictionary = state.get("vip", {})
	if bool(vip.get("active", false)):
		var daysLeft : int = ceili((int(vip.get("until", 0)) - Time.get_unix_time_from_system()) / 86400.0)
		vipLabel.text = "VIP: active (%d days left, idle faucet x%.1f)" % [maxi(daysLeft, 0), float(vip.get("mods", 1.0))]
	else:
		vipLabel.text = "VIP: inactive"

func _on_buy_chest_pressed(count : int):
	Network.BuyChests(count)

func _on_buy_vip_pressed(tier : int):
	Network.PurchaseVIP(tier)
