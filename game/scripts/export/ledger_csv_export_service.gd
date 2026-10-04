extends RefCounted
## Read-only, bounded export of the saved personal event journal. This is not a backup.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const MAX_EVENTS := 10000
const MAX_CSV_BYTES := 16 * 1024 * 1024
const COLUMNS := [
	"project_generation", "sequence", "id", "type", "effective_at", "account_id",
	"to_account_id", "instrument_id", "target_event_id", "replaces_event_id",
	"suggestion_event_id", "amount", "delta", "quantity", "unit_price", "fee",
	"reference_price", "cost_basis", "gross_amount", "withholding_tax", "net_cash",
	"asset_id", "valuation_basis", "source_note", "external", "raw_event_json",
]
const DECIMAL_COLUMNS := [
	"amount", "delta", "quantity", "unit_price", "fee", "reference_price",
	"cost_basis", "gross_amount", "withholding_tax", "net_cash",
]


func export_events(store: RefCounted, output_path: String) -> Dictionary:
	if output_path.is_empty():
		return _error("OUTPUT_PATH_REQUIRED")
	var absolute_output := ProjectSettings.globalize_path(output_path)
	if FileAccess.file_exists(absolute_output):
		return _error("OUTPUT_EXISTS")
	if not DirAccess.dir_exists_absolute(absolute_output.get_base_dir()):
		return _error("OUTPUT_DIRECTORY_UNAVAILABLE")
	var loaded: Dictionary = store.load_project()
	if not loaded.ok:
		return _error("SOURCE_UNAVAILABLE")
	if loaded.state.get("data_kind", "") != "personal":
		return _error("NOT_PERSONAL_DATA")
	if int(loaded.generation) < 1:
		return _error("NO_SAVED_PROJECT")
	var events: Array = loaded.state.get("ledger", {}).get("events", [])
	if events.size() > MAX_EVENTS:
		return _error("EVENT_LIMIT_EXCEEDED")
	var encoded := _encode(events, int(loaded.generation))
	if not encoded.ok:
		return encoded
	var bytes: PackedByteArray = encoded.bytes
	var expected_sha := _sha256_bytes(bytes)
	if expected_sha.is_empty():
		return _error("HASH_FAILED")
	var temp_path := absolute_output + ".partial-" + Crypto.new().generate_random_bytes(8).hex_encode()
	if FileAccess.file_exists(temp_path):
		return _error("TEMP_PATH_EXISTS")
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _error("OUTPUT_OPEN_FAILED")
	file.store_buffer(bytes)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_WRITE_FAILED")
	var verified := FileAccess.get_file_as_bytes(temp_path)
	if verified.size() != bytes.size() or _sha256_bytes(verified) != expected_sha:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_VERIFY_FAILED")
	if FileAccess.file_exists(absolute_output):
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_EXISTS")
	if DirAccess.rename_absolute(temp_path, absolute_output) != OK:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_RENAME_FAILED")
	return {"ok": true, "path": output_path, "generation": loaded.generation,
		"event_count": events.size(), "byte_count": bytes.size(), "sha256": expected_sha,
		"plaintext": true}


func _encode(events: Array, generation: int) -> Dictionary:
	var lines := PackedStringArray()
	lines.append(_row(COLUMNS))
	var byte_count := 3 + lines[0].to_utf8_buffer().size() + 2 # UTF-8 BOM + CRLF.
	for raw in events:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_EVENT")
		var event: Dictionary = raw
		var cells: Array[String] = []
		for column in COLUMNS:
			var value := ""
			if column == "project_generation":
				value = str(generation)
			elif column == "raw_event_json":
				value = JSON.stringify(event)
			elif column == "external":
				value = "true" if event.get("external", false) else "false" if event.has("external") else ""
			elif event.has(column):
				if typeof(event[column]) != TYPE_STRING and column != "sequence":
					return _error("INVALID_EVENT_FIELD")
				value = str(event[column])
			if DECIMAL_COLUMNS.has(column) and not value.is_empty() and not Decimal.is_valid(value):
				return _error("INVALID_DECIMAL_FIELD")
			if not DECIMAL_COLUMNS.has(column) and column != "sequence" and \
					column != "project_generation" and column != "raw_event_json":
				value = _spreadsheet_safe_text(value)
			cells.append(value)
		var line := _row(cells)
		byte_count += line.to_utf8_buffer().size() + 2
		if byte_count > MAX_CSV_BYTES:
			return _error("CSV_SIZE_LIMIT_EXCEEDED")
		lines.append(line)
	var data := ("\ufeff" + "\r\n".join(lines) + "\r\n").to_utf8_buffer()
	if data.size() != byte_count:
		return _error("CSV_SIZE_MISMATCH")
	return {"ok": true, "bytes": data}


func _row(cells: Array) -> String:
	var quoted := PackedStringArray()
	for value in cells:
		quoted.append('"' + str(value).replace('"', '""') + '"')
	return ",".join(quoted)


func _spreadsheet_safe_text(value: String) -> String:
	# Avoid formula execution when an identifier is opened in spreadsheet software.
	# The raw_event_json column retains the exact original event field.
	var trimmed := value.lstrip(" \t\r\n")
	if not trimmed.is_empty() and "=+-@".contains(trimmed[0]):
		return "'" + value
	return value


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()
