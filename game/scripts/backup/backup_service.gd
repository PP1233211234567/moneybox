extends RefCounted
## Local, plaintext JSON export for the current developer project schema.
## The caller must show preview_backup() and pass that exact preview to restore_project().

const Store = preload("res://scripts/data/project_store.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const FORMAT := "moneybox-full-json"
const BACKUP_VERSION := 1
const MAX_BACKUP_BYTES := 64 * 1024 * 1024
const SAFETY_DIRECTORY := "user://backups"

var _safety_directory: String


func _init(safety_directory: String = SAFETY_DIRECTORY) -> void:
	_safety_directory = safety_directory


func export_project(store: RefCounted, output_path: String) -> Dictionary:
	var loaded: Dictionary = store.load_project()
	if not loaded.ok:
		return _error("SOURCE_UNAVAILABLE")
	return _write_backup(loaded.state, output_path, int(loaded.generation))


func preview_backup(input_path: String, store: RefCounted) -> Dictionary:
	var parsed := _read_backup(input_path)
	if not parsed.ok:
		return parsed
	var current: Dictionary = store.load_project()
	if not current.ok:
		return _error("SOURCE_UNAVAILABLE")
	return {
		"ok": true,
		"backup_sha256": parsed.backup_sha256,
		"backup_schema_version": parsed.state.schema_version,
		"backup_generation": int(parsed.source_generation),
		"backup_counts": _counts(parsed.state),
		"current_generation": current.generation,
		"current_sha256": JSON.stringify(current.state).sha256_text(),
		"current_counts": _counts(current.state),
		"plaintext": true,
	}


func restore_project(store: RefCounted, input_path: String, confirmed_preview: Dictionary) -> Dictionary:
	# No restore is permitted without a preview of both the backup and the current state.
	if not confirmed_preview.get("ok", false) or not _is_sha256(confirmed_preview.get("backup_sha256", null)) or \
			not _is_sha256(confirmed_preview.get("current_sha256", null)) or \
			typeof(confirmed_preview.get("current_generation", null)) != TYPE_INT:
		return _error("PREVIEW_REQUIRED")
	var parsed := _read_backup(input_path)
	if not parsed.ok:
		return parsed
	if parsed.backup_sha256 != confirmed_preview.backup_sha256:
		return _error("BACKUP_CHANGED")
	var current: Dictionary = store.load_project()
	if not current.ok:
		return _error("SOURCE_UNAVAILABLE")
	if int(current.generation) != int(confirmed_preview.current_generation) or \
			JSON.stringify(current.state).sha256_text() != confirmed_preview.current_sha256:
		return _error("CURRENT_STATE_CHANGED")
	var safety_path := _new_safety_path()
	if safety_path.is_empty():
		return _error("SAFETY_PATH_UNAVAILABLE")
	var safety := _write_backup(current.state, safety_path, int(current.generation))
	if not safety.ok:
		return _error("SAFETY_BACKUP_FAILED")
	# ProjectStore validates and writes only the inactive slot. Its previous generation
	# remains readable if the new write is interrupted.
	var saved: Dictionary = store.save_project(parsed.state, int(confirmed_preview.current_generation))
	if not saved.ok:
		return _error("RESTORE_SAVE_FAILED")
	var checked: Dictionary = store.load_project()
	if not checked.ok or int(checked.generation) != int(saved.generation) or \
			JSON.stringify(checked.state).sha256_text() != JSON.stringify(parsed.state).sha256_text():
		return _error("RESTORE_VERIFY_FAILED")
	return {"ok": true, "generation": saved.generation, "safety_backup_path": safety_path}


func _write_backup(state: Dictionary, output_path: String,
		source_generation: int = -1) -> Dictionary:
	if output_path.is_empty() or FileAccess.file_exists(output_path):
		return _error("OUTPUT_EXISTS_OR_INVALID")
	if not _valid_project_shape(state):
		return _error("INVALID_PROJECT")
	var validator := Store.new("user://backup-shape-validation")
	if not validator._valid_state(state):
		return _error("INVALID_PROJECT")
	var payload := JSON.stringify(state)
	var manifest := {
		"project_schema_version": int(state.schema_version),
		"created_at_utc": Time.get_datetime_string_from_system(true, false) + "Z",
		"encryption": {"scheme": "none"},
		"content_sha256": payload.sha256_text(),
		"content_bytes": payload.to_utf8_buffer().size(),
		"counts": _counts(state),
	}
	# Optional in version 1. Older exports remain readable and report unknown.
	if source_generation >= 0:
		manifest["source_generation"] = source_generation
	var document := JSON.stringify({"format": FORMAT, "backup_version": BACKUP_VERSION,
		"manifest": manifest, "payload": payload})
	if document.to_utf8_buffer().size() > MAX_BACKUP_BYTES:
		return _error("BACKUP_TOO_LARGE")
	var absolute_output := ProjectSettings.globalize_path(output_path)
	var directory := absolute_output.get_base_dir()
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _error("OUTPUT_DIRECTORY_FAILED")
	var temp_path := absolute_output + ".partial-" + Crypto.new().generate_random_bytes(8).hex_encode()
	if FileAccess.file_exists(temp_path):
		return _error("TEMP_PATH_EXISTS")
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _error("OUTPUT_OPEN_FAILED")
	file.store_string(document)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_WRITE_FAILED")
	var verified := _read_backup(temp_path)
	if not verified.ok or verified.backup_sha256 != manifest.content_sha256:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_VERIFY_FAILED")
	if FileAccess.file_exists(absolute_output):
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_EXISTS_OR_INVALID")
	if DirAccess.rename_absolute(temp_path, absolute_output) != OK:
		DirAccess.remove_absolute(temp_path)
		return _error("OUTPUT_RENAME_FAILED")
	return {"ok": true, "path": output_path, "backup_sha256": manifest.content_sha256,
		"counts": manifest.counts, "plaintext": true}


func _read_backup(input_path: String) -> Dictionary:
	if input_path.is_empty():
		return _error("BACKUP_READ_FAILED")
	var file := FileAccess.open(input_path, FileAccess.READ)
	if file == null:
		return _error("BACKUP_READ_FAILED")
	var size := file.get_length()
	if size <= 0 or size > MAX_BACKUP_BYTES:
		file.close()
		return _error("BACKUP_SIZE_INVALID")
	var text_data := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(text_data) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return _error("BACKUP_FORMAT_INVALID")
	var document: Dictionary = parser.data
	if document.get("format", "") != FORMAT or not _is_json_integer(document.get("backup_version", null)):
		return _error("BACKUP_FORMAT_INVALID")
	if int(document.backup_version) != BACKUP_VERSION:
		return _error("BACKUP_VERSION_UNSUPPORTED")
	if typeof(document.get("manifest", null)) != TYPE_DICTIONARY or \
			typeof(document.get("payload", null)) != TYPE_STRING:
		return _error("BACKUP_FORMAT_INVALID")
	var manifest: Dictionary = document.manifest
	if not _is_json_integer(manifest.get("project_schema_version", null)) or \
			not _is_json_integer(manifest.get("content_bytes", null)) or \
			typeof(manifest.get("created_at_utc", null)) != TYPE_STRING or \
			typeof(manifest.get("encryption", null)) != TYPE_DICTIONARY or \
			manifest.encryption.get("scheme", "") != "none" or \
			not _is_sha256(manifest.get("content_sha256", null)) or \
			typeof(manifest.get("counts", null)) != TYPE_DICTIONARY:
		return _error("BACKUP_MANIFEST_INVALID")
	if int(manifest.project_schema_version) > Store.CURRENT_SCHEMA:
		return _error("FUTURE_SCHEMA_UNSUPPORTED")
	if manifest.has("source_generation") and (
			not _is_json_integer(manifest.source_generation) or
			int(manifest.source_generation) < 0):
		return _error("BACKUP_MANIFEST_INVALID")
	if int(manifest.project_schema_version) != Store.CURRENT_SCHEMA:
		return _error("SCHEMA_UNSUPPORTED")
	var payload: String = document.payload
	if payload.to_utf8_buffer().size() != int(manifest.content_bytes) or \
			payload.sha256_text() != manifest.content_sha256:
		return _error("BACKUP_CHECKSUM_INVALID")
	parser = JSON.new()
	if parser.parse(payload) != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return _error("BACKUP_PAYLOAD_INVALID")
	var state: Dictionary = parser.data
	if not _is_json_integer(state.get("schema_version", null)) or \
			int(state.schema_version) != int(manifest.project_schema_version) or \
			not _valid_project_shape(state):
		return _error("BACKUP_PAYLOAD_INVALID")
	var validator := Store.new("user://backup-shape-validation")
	if not validator._valid_state(state):
		return _error("BACKUP_STATE_INVALID")
	if not _counts_match(state, manifest.counts):
		return _error("BACKUP_MANIFEST_INVALID")
	return {"ok": true, "state": state, "backup_sha256": manifest.content_sha256,
		"source_generation": int(manifest.get("source_generation", -1))}


func _valid_project_shape(state: Dictionary) -> bool:
	if not _is_json_integer(state.get("schema_version", null)) or \
			int(state.schema_version) != Store.CURRENT_SCHEMA or \
			state.get("data_kind", "") != "personal" or \
			typeof(state.get("ledger", null)) != TYPE_DICTIONARY or \
			typeof(state.get("mappings", null)) != TYPE_ARRAY or \
			typeof(state.get("inventory", null)) != TYPE_DICTIONARY or \
			typeof(state.get("presentation", null)) != TYPE_DICTIONARY or \
			typeof(state.get("ecology", null)) != TYPE_DICTIONARY:
		return false
	var ledger: Dictionary = state.ledger
	if not _is_json_integer(ledger.get("schema_version", null)) or \
			typeof(ledger.get("base_currency", null)) != TYPE_STRING:
		return false
	for key in ["accounts", "instruments", "quotes", "fx_rates", "command_fingerprints"]:
		if typeof(ledger.get(key, null)) != TYPE_DICTIONARY:
			return false
	# Older v2 backups predate this collection. ProjectStore validates the
	# complete state after import, including any new assets when present.
	if ledger.has("other_assets") and typeof(ledger.other_assets) != TYPE_DICTIONARY:
		return false
	for key in ["events", "quote_history"]:
		if typeof(ledger.get(key, null)) != TYPE_ARRAY:
			return false
	for account in ledger.accounts.values():
		if typeof(account) != TYPE_DICTIONARY or typeof(account.get("currency", null)) != TYPE_STRING or \
				typeof(account.get("id", null)) != TYPE_STRING:
			return false
	for instrument in ledger.instruments.values():
		if typeof(instrument) != TYPE_DICTIONARY or typeof(instrument.get("currency", null)) != TYPE_STRING or \
				typeof(instrument.get("id", null)) != TYPE_STRING:
			return false
	for quote in ledger.quotes.values():
		if typeof(quote) != TYPE_DICTIONARY or not _valid_decimal_field(quote, "price"):
			return false
	for quote in ledger.quote_history:
		if typeof(quote) != TYPE_DICTIONARY or not _valid_decimal_field(quote, "price"):
			return false
	for fx in ledger.fx_rates.values():
		if typeof(fx) != TYPE_DICTIONARY or not _valid_decimal_field(fx, "rate_to_base"):
			return false
	for event in ledger.events:
		if typeof(event) != TYPE_DICTIONARY or typeof(event.get("type", null)) != TYPE_STRING or \
				typeof(event.get("id", null)) != TYPE_STRING or typeof(event.get("effective_at", null)) != TYPE_STRING or \
				not _is_json_integer(event.get("sequence", null)):
			return false
		for key in ["account_id", "target_event_id", "to_account_id", "instrument_id", "asset_id", "amount", "delta", "quantity", "unit_price", "fee", "reference_price", "cost_basis", "source_note", "valuation_basis", "source", "suggestion_event_id", "gross_amount", "withholding_tax", "net_cash"]:
			if event.has(key) and typeof(event[key]) != TYPE_STRING:
				return false
		if event.has("external") and typeof(event.external) != TYPE_BOOL:
			return false
		match event.type:
			"void":
				if typeof(event.get("target_event_id", null)) != TYPE_STRING:
					return false
			"aggregate_replaced":
				if typeof(event.get("account_id", null)) != TYPE_STRING:
					return false
			"other_asset_value_set":
				if typeof(event.get("asset_id", null)) != TYPE_STRING or \
						str(event.asset_id).is_empty() or not _valid_decimal_field(event, "amount") or \
						typeof(event.get("valuation_basis", null)) != TYPE_STRING or \
						str(event.valuation_basis).strip_edges().is_empty():
					return false
			"opening_cash", "cash_delta", "transfer", "buy", "sell", "opening_position", "restricted_balance_set", "dividend_suggest", "dividend_confirm":
				if typeof(event.get("account_id", null)) != TYPE_STRING:
					return false
				if event.type == "opening_cash" and not _valid_decimal_field(event, "amount"):
					return false
				if event.type == "cash_delta" and not _valid_decimal_field(event, "delta"):
					return false
				if event.type == "transfer" and (typeof(event.get("to_account_id", null)) != TYPE_STRING or \
						not _valid_decimal_field(event, "amount")):
					return false
				if event.type == "buy" or event.type == "sell":
					if typeof(event.get("instrument_id", null)) != TYPE_STRING or \
							not _valid_decimal_field(event, "quantity") or \
							not _valid_decimal_field(event, "unit_price") or \
							not _valid_decimal_field(event, "fee"):
						return false
				if event.type == "opening_position":
					if typeof(event.get("instrument_id", null)) != TYPE_STRING or \
							 not _valid_decimal_field(event, "quantity") or \
							 not _valid_decimal_field(event, "reference_price") or \
							 (event.has("cost_basis") and not str(event.cost_basis).is_empty() and \
							 not _valid_decimal_field(event, "cost_basis")):
						return false
				if event.type == "restricted_balance_set" and (
						not _valid_decimal_field(event, "amount") or
						typeof(event.get("source_note", null)) != TYPE_STRING or
						str(event.source_note).strip_edges().is_empty()):
					return false
				if event.type == "dividend_suggest" and (
						typeof(event.get("instrument_id", null)) != TYPE_STRING or
						not _valid_decimal_field(event, "gross_amount") or
						typeof(event.get("source", null)) != TYPE_STRING):
					return false
				if event.type == "dividend_confirm" and (
						typeof(event.get("instrument_id", null)) != TYPE_STRING or
						typeof(event.get("suggestion_event_id", null)) != TYPE_STRING or
						not _valid_decimal_field(event, "gross_amount") or
						not _valid_decimal_field(event, "withholding_tax") or
						not _valid_decimal_field(event, "net_cash")):
					return false
			_:
				return false
	for mapping in state.mappings:
		if typeof(mapping) != TYPE_DICTIONARY or typeof(mapping.get("id", null)) != TYPE_STRING or \
				not _valid_decimal_field(mapping, "whole_grams") or \
				not _valid_decimal_field(mapping, "fractional_grams"):
			return false
	if not state.inventory.is_empty():
		if typeof(state.inventory.get("beans", null)) != TYPE_ARRAY or \
				typeof(state.inventory.get("jars", null)) != TYPE_ARRAY:
			return false
		for bean in state.inventory.beans:
			if typeof(bean) != TYPE_DICTIONARY:
				return false
		for jar in state.inventory.jars:
			if typeof(jar) != TYPE_DICTIONARY:
				return false
	return true


func _counts(state: Dictionary) -> Dictionary:
	var ledger: Dictionary = state.ledger
	var counts := {"accounts": ledger.accounts.size(), "instruments": ledger.instruments.size(),
		"events": ledger.events.size(), "quotes": ledger.quotes.size(),
		"mappings": state.mappings.size(), "beans": state.inventory.get("beans", []).size(),
		"ecology_entries": state.ecology.size()}
	if ledger.has("other_assets"):
		counts["other_assets"] = ledger.other_assets.size()
	return counts


func _counts_match(state: Dictionary, claimed: Dictionary) -> bool:
	var actual := _counts(state)
	if claimed.size() != actual.size():
		return false
	for key in actual:
		if not _is_json_integer(claimed.get(key, null)) or int(claimed[key]) != int(actual[key]):
			return false
	return true


func _new_safety_path() -> String:
	for _attempt in 16:
		var name := "pre-restore-%d-%s.json" % [int(Time.get_unix_time_from_system()),
			Crypto.new().generate_random_bytes(8).hex_encode()]
		var path := _safety_directory.path_join(name)
		if not FileAccess.file_exists(path):
			return path
	return ""


func _is_sha256(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING or value.length() != 64:
		return false
	for character in value:
		if not "0123456789abcdef".contains(character):
			return false
	return true


func _is_json_integer(value: Variant) -> bool:
	if typeof(value) == TYPE_INT:
		return true
	if typeof(value) != TYPE_FLOAT:
		return false
	return is_finite(value) and absf(value) <= 9007199254740991.0 and value == floorf(value)


func _valid_decimal_field(value: Dictionary, key: String) -> bool:
	return typeof(value.get(key, null)) == TYPE_STRING and Decimal.is_valid(value[key])


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
