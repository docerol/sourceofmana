extends SceneTree

# SOM-IDLE D1: pacing diagnostic — ONE real-time farm run (no time compression)
# to measure the TRUE kill rate before recalibrating the par.
# Usage: godot --headless --path . -s tests/diag_pacing.gd
# Env: SOM_DIAG_SECS (default 120), SOM_DIAG_ZONE (default 1).
# NOTE: duck-typed like run_idle_tests.gd (no class_name refs at parse time).

func _initialize():
	_run()

func _getAutoload(nodeName : String) -> Node:
	return root.get_node_or_null(NodePath(nodeName))

func _run():
	print("== SOM-IDLE D1 pacing diagnostic ==")
	var launcher : Node = _getAutoload("Launcher")
	if launcher == null:
		print("FATAL: Launcher autoload missing")
		quit(1)
		return

	var waited : int = 0
	while waited < 30000:
		await create_timer(0.25).timeout
		waited += 250
		var sqlNode : Node = launcher.SQL
		var worldNode : Node = launcher.World
		if sqlNode != null and sqlNode.isInitialized and worldNode != null and worldNode.isInitialized:
			break

	var sql : Node = launcher.SQL
	var suitesScript : GDScript = load("res://tests/IdleTests.gd")
	var suites : RefCounted = suitesScript.new()
	var dbScript : GDScript = load("res://sources/db/DB.gd")
	for i in 40:
		if dbScript.isInitialized:
			break
		await create_timer(0.25).timeout

	var secs : int = int(OS.get_environment("SOM_DIAG_SECS")) if OS.get_environment("SOM_DIAG_SECS") != "" else 120
	var zone : int = int(OS.get_environment("SOM_DIAG_ZONE")) if OS.get_environment("SOM_DIAG_ZONE") != "" else 1
	suites.SuiteZoneCatalog()
	var charID : int = suites.CreateFixture(sql, "idle_diag_account", "IdleDiagTester")
	print("diag: fixture char %d, zone %d, %ds @1x" % [charID, zone, secs])
	var snapshot : Dictionary = await suites._SimRunDiag(charID, zone, secs)
	print("DIAG RESULT: %s" % str(snapshot))
	sql.db.delete_rows("character", "nickname = 'IdleDiagTester'")
	sql.db.delete_rows("account", "username = 'idle_diag_account'")
	quit(0)
