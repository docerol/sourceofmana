extends WindowPanel

# SOM-IDLE: Boss — escada de bosses. mobs de farm dropam chaves; gastar uma chave
# abre um duelo AO VIVO contra o próximo boss (que escala ao nível do char, então
# "fica sempre difícil"). Ao desafiar, a janela some pra você VER a luta animada
# do seu char contra o boss; ela volta quando o resultado chega. Dados por
# BossState; o resultado chega por BossResult (push assíncrono na morte do boss).
@onready var keysLabel : Label			= $Layout/Keys
@onready var resultLabel : Label		= $Layout/Result
@onready var bossList : VBoxContainer	= $Layout/BossScroll/BossList
@onready var hintLabel : Label			= $Layout/Hint

var _watchingFight : bool = false

#
func _ready():
	visibility_changed.connect(_on_visibility_changed)
	if is_visible():
		RefreshState()

func _on_visibility_changed():
	if is_visible():
		RefreshState()

func RefreshState():
	ShowState(NetClient.LastBossState)
	ShowResult(NetClient.LastBossResult)
	Network.GetBossState()

func ShowState(state : Dictionary):
	if state.is_empty():
		return
	var keys : int = int(state.get("keys", 0))
	var beaten : int = int(state.get("beaten", 0))
	var count : int = int(state.get("count", 0))
	keysLabel.text = "Boss keys: %d    •    Bosses defeated: %d/%d" % [keys, beaten, count]
	for child in bossList.get_children():
		child.queue_free()
	for boss in state.get("bosses", []):
		var index : int = int(boss.get("index", 0))
		var isNext : bool = bool(boss.get("next", false))
		var isBeaten : bool = bool(boss.get("beaten", false))
		var btn : Button = Button.new()
		var tag : String = "✓" if isBeaten else ("▶" if isNext else "🔒")
		btn.text = "%s  %s — Lv %d  (%d HP)" % [tag, str(boss.get("name", "?")), int(boss.get("level", 1)), int(boss.get("hp", 0))]
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.disabled = not (isNext and keys >= 1)
		if isNext and keys >= 1:
			btn.pressed.connect(_on_challenge_pressed)
		bossList.add_child(btn)
	if count > 0 and beaten >= count:
		hintLabel.text = "Ladder complete — you defeated every boss!"
	elif keys < 1:
		hintLabel.text = "No boss keys. Farm mobs drop them (~%d%% per kill)." % int(round(float(BossService.KeyDropPPM) / 10000.0))
	else:
		hintLabel.text = "Challenge the highlighted boss. It matches your level — gear decides."

func ShowResult(result : Dictionary):
	if result.is_empty():
		return
	# duelo começando: o NetClient esconde a janela pra você assistir à luta.
	if bool(result.get("started", false)):
		return
	if not bool(result.get("ok", false)):
		resultLabel.text = "Boss: %s" % str(result.get("reason", "—"))
		return
	if bool(result.get("win", false)):
		resultLabel.text = "Victory over %s (Lv %d) — +%d xp, +%d gold, +%d chest(s)" % [
			str(result.get("boss", "?")), int(result.get("level", 1)), int(result.get("duration", 0)),
			int(result.get("xp", 0)), int(result.get("gold", 0)), int(result.get("chests", 0))]
	else:
		resultLabel.text = "Defeated by %s (Lv %d) — +%d xp consolation. Strengthen your build and retry." % [
			str(result.get("boss", "?")), int(result.get("level", 1)), int(result.get("xp", 0))]

# Chamado pelo NetClient quando o servidor confirma o início do duelo ao vivo.
func EnterSpectate():
	_watchingFight = true
	hide()

# Reabre a janela para mostrar o desfecho, mas só se fomos nós que a escondemos
# (não força de volta uma janela que o jogador abriu/fechou por conta própria).
func ExitSpectate():
	if _watchingFight:
		_watchingFight = false
		show()
		RefreshState()

func _on_challenge_pressed():
	Network.ChallengeBoss()
