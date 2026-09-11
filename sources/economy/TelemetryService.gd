extends ServiceBase
class_name TelemetryService

# SOM-IDLE D2: product telemetry — buffered event sink (login/settle/levelup).
# A economia (mint/burn/trade/VIP) já vive no ledger; o dashboard (/metrics no
# companion) cruza as duas fontes. Flush periódico em 1 transação; buffer
# limitado (drop-oldest) para nunca pressionar memória sob carga.

const FlushIntervalSec : float = 60.0
const BufferCap : int = 500

var _buffer : Array[Dictionary] = []
var _accum : float = 0.0

func _post_launch():
	isInitialized = true

func Destroy():
	Flush()
	isInitialized = false

func _process(delta : float) -> void:
	if not isInitialized:
		return
	_accum += delta
	if _accum >= FlushIntervalSec:
		_accum = 0.0
		Flush()

# kind: login | settle | levelup. value: xp (settle), níveis (levelup), 1 (login).
func Record(kind : String, accountID : int = 0, charID : int = 0, value : int = 0, meta : String = "{}") -> void:
	if _buffer.size() >= BufferCap:
		_buffer.pop_front()
	_buffer.append({
		"created_at" = SQLCommons.Timestamp(),
		"account_id" = accountID, "char_id" = charID,
		"kind" = kind, "value" = value, "meta" = meta,
	})

func BufferedCount() -> int:
	return _buffer.size()

# Esvazia o buffer em 1 transação. Retorna eventos persistidos.
func Flush() -> int:
	if _buffer.is_empty():
		return 0
	var batch : Array = _buffer.duplicate()
	var count : int = 0
	if Launcher.SQL.Transaction(func() -> bool:
		for event in batch:
			if not Launcher.SQL.db.query_with_bindings(
				"INSERT INTO telemetry_event (created_at, account_id, char_id, kind, value, meta) VALUES (?, ?, ?, ?, ?, ?);",
				[int(event["created_at"]), int(event["account_id"]), int(event["char_id"]), str(event["kind"]), int(event["value"]), str(event["meta"])]):
				return false
		return true):
		count = batch.size()
		_buffer = _buffer.slice(count)
	return count

func Count(kind : String, sinceSec : int = 0) -> int:
	var rows : Array[Dictionary] = Launcher.SQL.QueryBindings(
		"SELECT COUNT(*) AS n FROM telemetry_event WHERE kind = ? AND created_at >= ?;", [kind, sinceSec])
	return int(rows[0]["n"]) if not rows.is_empty() else 0
