extends WindowPanel

# SOM-IDLE onboarding: Formation — slot (0-5), skill desbloqueada e poção
# automática do char atual; salva via SetFormation (v0 write-only, sem
# leitura: o servidor confirma com "formation_saved").
@onready var slotOption : OptionButton = $Layout/SlotRow/Slot
@onready var charLabel : Label = $Layout/CharRow/CharName
@onready var skillOption : OptionButton = $Layout/SkillRow/Skill
@onready var potionSlider : HSlider = $Layout/PotionRow/Potion
@onready var potionLabel : Label = $Layout/PotionRow/PotionPct

func _ready():
	visibility_changed.connect(_on_visibility_changed)
	for slot in IdlePolicyService.MaxFormationSlots:
		slotOption.add_item("Slot %d" % slot, slot)
	potionSlider.value_changed.connect(_on_potion_changed)
	if is_visible():
		RefreshFormation()

func _on_visibility_changed():
	if is_visible():
		RefreshFormation()

func _on_potion_changed(value : float):
	potionLabel.text = "%d%%" % int(value)

func RefreshFormation():
	if Launcher.Player:
		charLabel.text = str(Launcher.Player.nick) if str(Launcher.Player.nick) != "" else "?"
	skillOption.clear()
	if Launcher.Player and Launcher.Player.progress:
		for skillID in Launcher.Player.progress.skills:
			var skill : SkillCell = DB.GetSkill(int(skillID))
			if skill is SkillCell:
				skillOption.add_item(str(skill.name) if str(skill.name) != "" else str(skillID), int(skillID))
	if skillOption.item_count == 0:
		skillOption.add_item("Melee", SkillCommons.SkillMeleeName.hash())
	potionSlider.value = 35.0
	_on_potion_changed(35.0)

func _on_save_pressed():
	if not Launcher.Player:
		return
	var slot : int = slotOption.get_selected_id()
	var skillID : int = skillOption.get_selected_id()
	Network.SetFormation(slot, Launcher.Player.characterID, PackedInt64Array([skillID]), float(potionSlider.value))
