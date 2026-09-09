extends SceneTree

# SOM-IDLE: F2 idle-spike headless test runner
# Boots the project (autoloads + offline server services), waits for readiness,
# then executes the IdleTests suites against the real database and world.
# Usage: godot --headless --path . -s tests/run_idle_tests.gd
# Exit code: number of failed checks (0 = green).
#
# NOTE: the -s main-loop script is compiled BEFORE autoload globals are
# registered, so this file must be fully duck-typed: no class_name references
# and no autoload identifiers (Launcher/DB/...) at parse time. Project classes
# are loaded dynamically after the boot completes.

func _initialize():
	_run_tests()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _run_tests():
	print("== SOM-IDLE F2 test runner ==")

	# The autoloads boot themselves in -s mode (Launcher._ready starts the
	# offline server + client in debug builds) — just wait for readiness.
	var launcher : Node = _getAutoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return

	# Wait for DB + World services to finish initializing (max ~30s)
	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.SQL
		var worldNode : Node = launcher.World
		if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
			break

	print("== boot wait done (waited %d ms) ==" % waited)

	var sql : Node = launcher.SQL
	var economy : Node = launcher.Economy

	# Load suites dynamically (post-boot, so project classes compile fine)
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()

	suites.SuiteXpCurve()
	suites.SuiteZoneCatalog()
	suites.SuiteFormatter()

	# DB is a static class (not an autoload) — load it dynamically (post-boot,
	# when the autoload globals exist so it can compile) and poll the static var
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	var dbReady : bool = false
	for i in 40:
		if dbScript.isInitialized:
			dbReady = true
			break
		await create_timer(0.25).timeout

	if suites.Check(dbReady, "DB initialized (maps/items/skills loaded)"):
		suites.SuiteDBBacked(sql, economy)

		# SOM-IDLE: F3 suites (tiers, spawn table, VIP, leaderboard, slots)
		suites.SuiteItemTiers()
		suites.SuiteFarmSpawnTable()
		var f3char : int = suites.CreateFixture(sql, "idle_f3_account", "IdleF3Tester")
		if suites.Check(f3char != 0, "F3 fixture created (charID %d)" % f3char):
			suites.SuiteVIPMods(sql, f3char, sql.GetAccountIDForCharacter(f3char))
			suites.SuiteLeaderboard(sql, f3char)
			suites.SuiteFormationSlots(sql, f3char, sql.GetAccountIDForCharacter(f3char))

		# §7.4 deterministic live farm sim (zone 1) — after the DB suites so the
		# fixture character is already leveled by the settle
		await suites.SuiteIdlePolicySim(suites.lastCharID)
	else:
		print("FATAL: DB not initialized — DB-backed suites skipped")

	print("== RESULT: %d checks, %d failures ==" % [suites.checks, suites.failures])
	quit(suites.failures if suites.failures > 0 else 0)
