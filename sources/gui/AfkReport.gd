extends WindowPanel

# SOM-IDLE onboarding: AFK Report — último settle (preenchido pelo handler
# NetClient.AFKReport; auto-abre ao coletar). Somente leitura.
@onready var hoursLabel : Label = $Layout/Hours
@onready var xpLabel : Label = $Layout/XP
@onready var goldLabel : Label = $Layout/Gold
@onready var dropsLabel : Label = $Layout/Drops
@onready var chestsLabel : Label = $Layout/Chests
@onready var effLabel : Label = $Layout/Efficiency

func _ready():
	if NetClient.LastAFKReport.is_empty():
		Network.GetAFKReport()
	else:
		ShowReport(NetClient.LastAFKReport)

func ShowReport(report : Dictionary):
	if report.is_empty():
		return
	hoursLabel.text = tr("Away: %.1fh") % float(report.get("hours", 0.0))
	xpLabel.text = tr("+%s XP") % Util.FormatNumber(int(report.get("xp_earned", 0)))
	goldLabel.text = tr("+%s gold") % Util.FormatNumber(int(report.get("gold_earned", 0)))
	var drops : Dictionary = report.get("drops", {})
	var dropTotal : int = 0
	for itemHash in drops:
		dropTotal += int(drops[itemHash])
	dropsLabel.text = tr("Drops: %d") % dropTotal
	chestsLabel.text = tr("Chests: %d") % int(report.get("chests", 0))
	effLabel.text = tr("Efficiency: %d%%") % int(float(report.get("efficiency", 1.0)) * 100.0)

func _on_collect_pressed():
	Network.ClaimOfflineSettle()
