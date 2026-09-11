extends WindowPanel

# SOM-IDLE beta GUI: Leaderboard — top power score global (RPC GetLeaderboard)
# + boards da temporada ativa (RPC GetSeasonBoards: power e spend com nomes
# resolvidos no servidor). Read-only; os dados chegam por push da NetClient.
@onready var topList : VBoxContainer		= $Layout/TopScroll/TopList
@onready var seasonLabel : Label			= $Layout/SeasonLabel
@onready var seasonList : VBoxContainer		= $Layout/SeasonScroll/SeasonList

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshBoards()

func _on_visibility_changed():
	if is_visible():
		RefreshBoards()

func RefreshBoards():
	# Render otimista do último snapshot (rate limits de 12s/60s podem engolir
	# reaberturas rápidas — a janela mostra o cache e atualiza quando chegar).
	ShowTop(NetClient.LastLeaderboard)
	ShowSeason(NetClient.LastSeasonBoards)
	Network.GetLeaderboard()
	Network.GetSeasonBoards()

# Top power global (NetClient.Leaderboard → ShowTop).
func ShowTop(entries : Array):
	for child in topList.get_children():
		child.queue_free()
	var rank : int = 1
	for entry in entries:
		if rank > 10:
			break
		var row : Label = Label.new()
		var level : int = int(entry.get("level", 0) if entry.get("level", 0) != null else 0)
		row.text = "#%d %s — L%d power %s" % [rank, str(entry.get("nickname", "?")), level, Util.FormatNumber(int(entry.get("power_score", 0) if entry.get("power_score", 0) != null else 0))]
		topList.add_child(row)
		rank += 1
	if rank == 1:
		var empty : Label = Label.new()
		empty.text = "No ranked players yet."
		topList.add_child(empty)

# Boards da temporada ativa (NetClient.SeasonBoards → ShowSeason).
func ShowSeason(data : Dictionary):
	for child in seasonList.get_children():
		child.queue_free()
	if data.is_empty():
		seasonLabel.text = "Season: none active"
		return
	var daysLeft : int = ceili((int(data.get("ends_at", 0)) - Time.get_unix_time_from_system()) / 86400.0)
	seasonLabel.text = "Season #%d — ends in %d day(s)" % [int(data.get("season_id", 0)), maxi(daysLeft, 0)]
	_FillBoard(seasonList, "Season power", data.get("power", []))
	_FillBoard(seasonList, "Season spend (gems)", data.get("spend", []))

func _FillBoard(parent : Container, title : String, rows : Array):
	var header : Label = Label.new()
	header.text = title
	parent.add_child(header)
	if rows.is_empty():
		var empty : Label = Label.new()
		empty.text = "  (no scores yet)"
		parent.add_child(empty)
		return
	var rank : int = 1
	for row in rows:
		var line : Label = Label.new()
		line.text = "  #%d %s — %s" % [rank, str(row.get("name", "?")), Util.FormatNumber(int(row.get("value", 0)))]
		parent.add_child(line)
		rank += 1
