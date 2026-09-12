extends RefCounted
class_name BossService

# SOM-IDLE: boss-key ladder (calibração 2026-09).
# Mobs de farm dropam chaves; gastar uma chave invoca o próximo boss da escada,
# ESCALADO ao nível do char (para "ficar sempre difícil"). A luta é resolvida
# por uma simulação determinística de auto-combat (mesma fórmula de dano do
# motor, sem RNG), então o resultado é uma corrida de TTK: quem derruba o outro
# primeiro. Vitória paga xp/gold/chest/drop turbinados; derrota dá consolação.
# Modelo escolhido em vez de fight-live-em-instance para manter o beta verde e
# testável; a resolução pode virar combate 3D ao vivo depois trocando só Resolve().

# Escada de bosses (nome do mapa da sala + nome de exibição + nível-piso).
const BossNames : Array[String] = ["Dorian", "Gabriel", "Marvin", "Splatyna"]
const BossFloorLevel : Array[int] = [5, 5, 5, 10]

# Drop de chave: ppm sobre kills de farm válidos (damageRatio>0.5). 2000 ppm =
# 0,2%/kill → ~1 chave por 500 kills; no par (~150/h) isso é ~1 chave a cada
# ~3h30 online, ou ~2 chaves por settle de 12h offline (acumula idle-first).
const KeyDropPPM : int = 2000

# Recompensa do boss (vitória). xp = xpPerKill da zona atual × BossXpKills — um
# boss vale uma boa sessão de farm. gold = xp/GoldPerKillDiv × BossGoldBonus.
const BossXpKills : int = 60
const BossGoldBonus : float = 1.5
const BossChestReward : int = 1			# cofres granted por vitória
const ConsolationXpKills : int = 8		# xp de "esforço" ao perder
const ConsolationKeepsKey : bool = false	# derrota consome a chave (sink real)

# Escala do boss. Boss fica ao nível do char (piso por índice), com HP multiplicado
# para ser uma luta longa e defesa/golpe acompanhandem — só passa quem tem build.
const BossHpBase : int = 120
const BossHpPerLevel : int = 46
const BossHpMult : int = 6
const BossAtkBase : int = 12
const BossAtkPerLevel : int = 3
const BossDefBase : int = 10
const BossDefPerLevel : int = 2
const BossAttackCycle : float = 1.5		# segundos por golpe do boss
const PlayerAttackCycle : float = 1.2	# fallback se o char não tiver ciclo próprio
const MeleeSkillValue : int = 6			# dano básico da skill do auto-combat

static func GetBossCount() -> int:
	return BossNames.size()

static func GetBossName(index : int) -> String:
	return BossNames[index] if index >= 0 and index < BossNames.size() else ""

# SOM-IDLE: hash da entidade do boss (para spawnar a luta ao vivo). Procurado
# pelo _name do preset (Dorian/Gabriel/Marvin/Splatyna são entidades reais com
# sprite+animação próprios). Cache por índice (DB não muda pós-boot).
static var _entityHashCache : Dictionary = {}
static func GetBossEntityHash(index : int) -> int:
	if index < 0 or index >= BossNames.size():
		return DB.UnknownHash
	if _entityHashCache.has(index):
		return int(_entityHashCache[index])
	var want : String = BossNames[index]
	var found : int = DB.UnknownHash
	for hash in DB.EntitiesDB:
		var data : EntityData = DB.EntitiesDB[hash]
		if data != null and data._name == want:
			found = int(hash)
			break
	_entityHashCache[index] = found
	return found

static func GetBossFloorLevel(index : int) -> int:
	return BossFloorLevel[index] if index >= 0 and index < BossFloorLevel.size() else 1

# Roll determinístico de drop de chave (chamador passa um rng em [0,1)).
static func RollsKeyDrop(rng : float) -> bool:
	return rng < float(KeyDropPPM) / 1000000.0

# ------------------------------------------------------------------ boss scaling

static func GetBossLevel(playerLevel : int, index : int) -> int:
	return maxi(playerLevel, GetBossFloorLevel(index))

static func GetBossMaxHealth(level : int) -> int:
	return (BossHpBase + BossHpPerLevel * level) * BossHpMult

static func GetBossAttack(level : int) -> int:
	return BossAtkBase + BossAtkPerLevel * level

static func GetBossDefense(level : int) -> int:
	return BossDefBase + BossDefPerLevel * level

# ------------------------------------------------------------------ duel sim

# Resolve o duelo char-vs-boss como corrida de TTK. `player` é um dicionário com
# attack/defense/maxHealth/cycle (vindo do stat.current do agent online, ou de um
# snapshot em teste). Determinístico: sem RNG, sem críticos, dmg min 1.
static func Resolve(player : Dictionary, bossLevel : int) -> Dictionary:
	var bossHP : int = GetBossMaxHealth(bossLevel)
	var bossAtk : int = GetBossAttack(bossLevel)
	var bossDef : int = GetBossDefense(bossLevel)

	var playerAtk : int = int(player.get("attack", 1))
	var playerDef : int = int(player.get("defense", 0))
	var playerHP : int = maxi(1, int(player.get("maxHealth", 1)))
	var playerCycle : float = float(player.get("cycle", PlayerAttackCycle))

	var dmgToBoss : int = maxi(1, playerAtk + MeleeSkillValue - bossDef)
	var dmgToPlayer : int = maxi(1, bossAtk - playerDef)

	var playerTTK : float = (float(bossHP) / float(dmgToBoss)) * playerCycle
	var bossTTK : float = (float(playerHP) / float(dmgToPlayer)) * BossAttackCycle

	var win : bool = playerTTK <= bossTTK
	return {
		"win" = win,
		"bossLevel" = bossLevel,
		"bossHP" = bossHP,
		"duration" = playerTTK if win else bossTTK,
		"playerTTK" = playerTTK,
		"bossTTK" = bossTTK,
	}

# Snapshot das stats do jogador para Resolve(). cycle = castDelay + cooldownAttack
# (o ciclo real do auto-combat), com fallback para PlayerAttackCycle.
static func PlayerFightSnapshot(player) -> Dictionary:
	if player == null or player.stat == null:
		return {}
	var cur = player.stat.current
	var cycle : float = float(cur.castAttackDelay) + float(cur.cooldownAttackDelay)
	if cycle <= 0.0:
		cycle = PlayerAttackCycle
	return {
		"attack" = int(cur.attack),
		"defense" = int(cur.defense),
		"maxHealth" = int(cur.maxHealth),
		"cycle" = cycle,
	}

# ------------------------------------------------------------------ rewards

# xp bruto de uma vitória, dado o xpPerKill da zona do char (o chamador aplica
# newbie boost/VIP e entrega; aqui é só a referência "N kills de farm").
static func VictoryXp(zoneXpPerKill : int) -> int:
	return maxi(1, zoneXpPerKill * BossXpKills)

static func VictoryGold(zoneXpPerKill : int) -> int:
	var xp : int = VictoryXp(zoneXpPerKill)
	return maxi(1, roundi(float(xp) / float(FarmZoneData.GoldPerKillDiv) * BossGoldBonus))

static func ConsolationXp(zoneXpPerKill : int) -> int:
	return maxi(1, zoneXpPerKill * ConsolationXpKills)
