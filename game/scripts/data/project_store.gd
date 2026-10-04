extends RefCounted
## Two full, checksummed slots. A crash while writing the inactive slot leaves the previous generation readable.

const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")
const QuoteGateway = preload("res://scripts/quotes/quote_gateway.gd")
const Valuation = preload("res://scripts/quotes/valuation_batch_service.gd")
const Ecology = preload("res://scripts/ecology/ecology_service.gd")
const CURRENT_SCHEMA := 2

var _base_path: String


static func canonical_ledger_hash(ledger: Dictionary) -> String:
	# Godot parses JSON number fields as floats. Hash the form that is read from disk
	# so the same logical ledger version keeps one hash before and after a restart.
	var normalized = JSON.parse_string(JSON.stringify(ledger))
	if typeof(normalized) != TYPE_DICTIONARY:
		return ""
	return JSON.stringify(normalized).sha256_text()


func _init(base_path: String) -> void:
	_base_path = base_path


func new_project() -> Dictionary:
	return {
		"schema_version": CURRENT_SCHEMA,
		"data_kind": "personal",
		"ledger": Ledger.new_state(),
		"mappings": [],
		"inventory": {},
		"presentation": {"privacy_mode": "show_total", "selected_jar": "jar-1", "skin_id": "basic"},
		"ecology": _default_ecology(),
		"quote_gateway": QuoteGateway.new_state(),
		"valuation": Valuation.new_state(),
	}


func load_project() -> Dictionary:
	var valid: Array[Dictionary] = []
	var saw_file := false
	var saw_corrupt := false
	for index in 2:
		var slot_path := _slot_path(index)
		if not FileAccess.file_exists(slot_path):
			continue
		saw_file = true
		var candidate := _read_slot(slot_path)
		if candidate.ok:
			valid.append(candidate)
		else:
			saw_corrupt = true
	if valid.is_empty():
		if saw_file:
			return {"ok": false, "error": "NO_VALID_GENERATION"}
		return {"ok": true, "state": new_project(), "generation": 0, "migrated": false, "recovered": false}
	valid.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.generation) > int(b.generation))
	var newest: Dictionary = valid[0]
	if newest.schema_version > CURRENT_SCHEMA:
		return {"ok": false, "error": "UNSUPPORTED_FUTURE_SCHEMA"}
	var migration := _migrate(newest.state)
	if not migration.ok:
		return migration
	return {"ok": true, "state": migration.state, "generation": newest.generation, "migrated": migration.migrated, "recovered": saw_corrupt}


func save_project(state: Dictionary, expected_generation: int = -1) -> Dictionary:
	## Generic state persistence cannot prove whether a caller supplied every ledger holding.
	## New total-assets valuations must enter through commit_quote_valuation().
	var normalized := state.duplicate(true)
	_add_ecology_defaults(normalized)
	if int(normalized.get("schema_version", -1)) != CURRENT_SCHEMA or not _valid_state(normalized):
		return {"ok": false, "error": "INVALID_PROJECT_SCHEMA"}
	var current := load_project()
	if not current.ok:
		return current
	if expected_generation >= 0 and int(current.generation) != expected_generation:
		return {"ok": false, "error": "GENERATION_CONFLICT"}
	var next_generation: int = int(current.generation) + 1
	var target := _slot_path(next_generation % 2)
	var directory := target.get_base_dir()
	var absolute_directory := ProjectSettings.globalize_path(directory)
	var mkdir_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if mkdir_error != OK:
		return {"ok": false, "error": "DIRECTORY_CREATE_FAILED", "code": mkdir_error}
	var payload := JSON.stringify(normalized)
	var envelope := {
		"format": "moneybox-state",
		"schema_version": CURRENT_SCHEMA,
		"generation": next_generation,
		"payload": payload,
		"sha256": payload.sha256_text(),
	}
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "OPEN_FOR_WRITE_FAILED", "code": FileAccess.get_open_error()}
	file.store_string(JSON.stringify(envelope))
	file.flush()
	var file_error := file.get_error()
	file.close()
	if file_error != OK:
		return {"ok": false, "error": "WRITE_FAILED", "code": file_error}
	var verification := _read_slot(target)
	if not verification.ok or verification.generation != next_generation:
		return {"ok": false, "error": "WRITE_VERIFY_FAILED", "detail": verification.get("error", "GENERATION_MISMATCH")}
	return {"ok": true, "generation": next_generation, "path": target}


func commit_ecology_command(command: Dictionary, expected_generation: int) -> Dictionary:
	if expected_generation < 0:
		return {"ok": false, "error": "GENERATION_REQUIRED"}
	var loaded := load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return {"ok": false, "error": "GENERATION_CONFLICT"}
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return {"ok": false, "error": "PERSONAL_PROJECT_REQUIRED"}
	if not Ecology.validate(project.ecology):
		return {"ok": false, "error": "ECOLOGY_STATE_INVALID"}
	var applied := Ecology.apply(project.ecology, command)
	if not applied.ok:
		return applied
	if applied.duplicate:
		return {"ok": true, "duplicate": true, "generation": expected_generation,
			"ecology": project.ecology.duplicate(true)}
	var next := project.duplicate(true)
	next.ecology = applied.state
	if command.get("type", "") == "SET_SKIN":
		next.presentation.skin_id = applied.state.scene.settings.active_skin_id
	var saved := save_project(next, expected_generation)
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "generation": saved.generation,
		"ecology": applied.state.duplicate(true)}


func commit_quote_valuation(refresh_result: Dictionary, positions: Array,
		cash_balances: Array, allow_stale: bool, expected_generation: int,
		restricted_balances: Array = [], other_asset_values: Array = []) -> Dictionary:
	## Caller must supply the complete current ledger projection, including zero-cash accounts.
	## Only identity keys go to QuoteGateway's provider; holdings stay local here.
	if expected_generation < 0 or refresh_result.get("ok", false) != true \
		or typeof(refresh_result.get("state", null)) != TYPE_DICTIONARY \
		or typeof(refresh_result.get("batch", null)) != TYPE_DICTIONARY:
		return {"ok": false, "error": "INVALID_QUOTE_REFRESH"}
	var loaded := load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return {"ok": false, "error": "GENERATION_CONFLICT"}
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return {"ok": false, "error": "PERSONAL_PROJECT_REQUIRED"}
	var coverage := validate_valuation_coverage(project.ledger, positions,
		cash_balances, restricted_balances, other_asset_values)
	if not coverage.ok:
		return coverage
	var quote_state: Dictionary = refresh_result.state
	var batch: Dictionary = refresh_result.batch
	if not _valid_quote_gateway_state(quote_state) or \
		str(batch.get("id", "")).is_empty() or \
		JSON.stringify(quote_state.batches.get(str(batch.id), {})) != JSON.stringify(batch) \
		or not _quote_state_extends(project.quote_gateway, quote_state):
		return {"ok": false, "error": "QUOTE_STATE_CONFLICT"}
	var valued := Valuation.create_snapshot(project.valuation, batch, positions,
		cash_balances, str(project.ledger.base_currency), allow_stale,
		int(project.valuation.revision), restricted_balances, other_asset_values)
	if not valued.ok:
		return valued
	var ledger_hash := canonical_ledger_hash(project.ledger)
	var event_sequence: int = project.ledger.events.size()
	if valued.duplicate:
		# Legacy snapshots remain readable, but replay cannot certify a missing or old ledger version.
		if str(valued.snapshot.get("ledger_hash", "")) != ledger_hash or \
				int(valued.snapshot.get("ledger_event_sequence", -1)) != event_sequence:
			return {"ok": false, "error": "UNVERIFIED_ASSET_VERSION"}
	else:
		var stamped: Dictionary = valued.snapshot.duplicate(true)
		stamped.ledger_hash = ledger_hash
		stamped.ledger_event_sequence = event_sequence
		valued.state.snapshots[stamped.id] = stamped.duplicate(true)
		valued.snapshot = stamped
	if valued.duplicate and JSON.stringify(project.quote_gateway) == JSON.stringify(quote_state):
		return {"ok": true, "duplicate": true, "generation": expected_generation,
			"snapshot": valued.snapshot}
	var next := project.duplicate(true)
	next.quote_gateway = quote_state.duplicate(true)
	next.valuation = valued.state.duplicate(true)
	# A saved valuation is not yet an applied gold mapping. If mapping fails or the
	# process stops between the two saves, renderers must keep the last jar as old.
	next.valuation_pending = {"reason": "QUOTE_VALUATION_PENDING_MAPPING",
		"ledger_hash": ledger_hash}
	var saved := save_project(next, expected_generation)
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": valued.duplicate,
		"generation": saved.generation, "snapshot": valued.snapshot}


func current_valuation_snapshot(project: Dictionary, snapshot_id: String) -> Dictionary:
	if project.get("data_kind", "") != "personal":
		return {"ok": false, "error": "PERSONAL_PROJECT_REQUIRED"}
	var valuation: Dictionary = project.get("valuation", {})
	var snapshots: Dictionary = valuation.get("snapshots", {})
	if not snapshots.has(snapshot_id):
		return {"ok": false, "error": "NEEDS_VALUATION"}
	var snapshot: Dictionary = snapshots[snapshot_id]
	var ledger_hash := canonical_ledger_hash(project.ledger)
	if str(snapshot.get("ledger_hash", "")).is_empty():
		return {"ok": false, "error": "UNVERIFIED_ASSET_VERSION"}
	if str(snapshot.ledger_hash) != ledger_hash or \
			int(snapshot.get("ledger_event_sequence", -1)) != project.ledger.events.size():
		return {"ok": false, "error": "NEEDS_VALUATION"}
	var batches: Dictionary = project.get("quote_gateway", {}).get("batches", {})
	var batch: Dictionary = batches.get(str(snapshot.get("quote_batch_id", "")), {})
	if batch.is_empty() or not ["COMPLETE", "COMPLETE_WITH_STALE"].has(
			str(batch.get("status", ""))) or \
			(batch.status == "COMPLETE_WITH_STALE" and \
			snapshot.get("stale_confirmed", false) != true):
		return {"ok": false, "error": "NEEDS_VALUATION"}
	if typeof(snapshot.get("asset_total", null)) != TYPE_STRING or \
			not Decimal.is_valid(snapshot.asset_total) or \
			Decimal.compare(snapshot.asset_total, "0") < 0 or \
			str(snapshot.get("base_currency", "")) != str(project.ledger.base_currency):
		return {"ok": false, "error": "UNVERIFIED_ASSET_VERSION"}
	if not _snapshot_rows_cover_ledger(project.ledger, snapshot):
		return {"ok": false, "error": "UNVERIFIED_ASSET_VERSION"}
	return {"ok": true, "snapshot": snapshot.duplicate(true), "ledger_hash": ledger_hash}


func _snapshot_rows_cover_ledger(ledger: Dictionary, snapshot: Dictionary) -> bool:
	var position_rows: Variant = snapshot.get("position_values", null)
	var cash_rows: Variant = snapshot.get("cash_values", null)
	var restricted_rows: Variant = snapshot.get("restricted_values", [])
	var other_rows: Variant = snapshot.get("other_asset_values", [])
	if typeof(position_rows) != TYPE_ARRAY or typeof(cash_rows) != TYPE_ARRAY or \
			typeof(restricted_rows) != TYPE_ARRAY or typeof(other_rows) != TYPE_ARRAY:
		return false
	var positions := []
	var cash := []
	var restricted := []
	var other := []
	var sum := "0"
	for row in position_rows:
		if typeof(row) != TYPE_DICTIONARY or \
				typeof(row.get("instrument_identity", null)) != TYPE_DICTIONARY or \
				typeof(row.get("quantity", null)) != TYPE_STRING or \
				not _add_snapshot_value(row, sum).ok:
			return false
		sum = _add_snapshot_value(row, sum).value
		positions.append({"position_id": row.get("position_id", ""),
			"identity": row.instrument_identity, "quantity": row.quantity})
	for row in cash_rows:
		if typeof(row) != TYPE_DICTIONARY or \
				typeof(row.get("amount", null)) != TYPE_STRING or \
				not _add_snapshot_value(row, sum).ok:
			return false
		sum = _add_snapshot_value(row, sum).value
		cash.append({"balance_id": row.get("balance_id", ""),
			"amount": row.amount, "currency": row.get("currency", "")})
	for row in restricted_rows:
		if typeof(row) != TYPE_DICTIONARY or \
				typeof(row.get("amount", null)) != TYPE_STRING or \
				not _add_snapshot_value(row, sum).ok:
			return false
		sum = _add_snapshot_value(row, sum).value
		restricted.append({"balance_id": row.get("balance_id", ""),
			"amount": row.amount, "currency": row.get("currency", "")})
	for row in other_rows:
		if typeof(row) != TYPE_DICTIONARY or \
				typeof(row.get("amount", null)) != TYPE_STRING or \
				not _add_snapshot_value(row, sum).ok:
			return false
		sum = _add_snapshot_value(row, sum).value
		other.append({"asset_id": row.get("asset_id", ""),
			"amount": row.amount, "currency": row.get("currency", ""),
			"valuation_basis": row.get("valuation_basis", ""),
			"effective_at": row.get("effective_at", ""),
			"event_id": row.get("event_id", "")})
	return validate_valuation_coverage(ledger, positions, cash, restricted, other).ok and \
		Decimal.compare(sum, str(snapshot.asset_total)) == 0


func _add_snapshot_value(row: Dictionary, current: String) -> Dictionary:
	var value: Variant = row.get("base_value", null)
	if typeof(value) != TYPE_STRING or not Decimal.is_valid(value) or \
			Decimal.compare(value, "0") < 0:
		return {"ok": false}
	return {"ok": true, "value": Decimal.add(current, value)}


func validate_valuation_coverage(ledger: Dictionary, positions: Array,
		cash_balances: Array, restricted_balances: Array = [],
		other_asset_values: Array = []) -> Dictionary:
	## A ValuationBatchService input is only a total-assets input after this exact coverage check.
	var projection := Ledger.project(ledger)
	if not projection.ok:
		return {"ok": false, "error": "LEDGER_PROJECTION_INVALID"}
	var expected_positions := {}
	for key in projection.positions:
		var position: Dictionary = projection.positions[key]
		if position.quantity == "0" or projection.replaced_accounts.has(position.account_id):
			continue
		expected_positions[key] = position
	var supplied_positions := {}
	for raw in positions:
		if typeof(raw) != TYPE_DICTIONARY:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var id := str(raw.get("position_id", ""))
		if id.is_empty() or supplied_positions.has(id) or not expected_positions.has(id):
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var expected: Dictionary = expected_positions[id]
		var instrument: Dictionary = ledger.instruments.get(expected.instrument_id, {})
		var raw_identity = raw.get("identity", null)
		if typeof(raw_identity) != TYPE_DICTIONARY:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var identity := QuoteContract.normalize_identity(raw_identity)
		var kind := str(instrument.get("kind", ""))
		if not ["STOCK", "ETF", "FUND"].has(kind):
			return {"ok": false, "error": "INSTRUMENT_KIND_UNKNOWN"}
		var quantity = raw.get("quantity", null)
		if identity.is_empty() or identity.kind != kind \
			or identity.market != str(instrument.get("market", "")).to_upper() \
			or identity.symbol != str(instrument.get("symbol", "")).to_upper() \
			or identity.currency != str(instrument.get("currency", "")) \
			or identity.share_class != str(instrument.get("share_class", "")).to_upper() \
			or typeof(quantity) != TYPE_STRING or not Decimal.is_valid(quantity) \
			or Decimal.compare(quantity, str(expected.quantity)) != 0:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		supplied_positions[id] = true
	if supplied_positions.size() != expected_positions.size():
		return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
	var expected_cash := {}
	for account_id in projection.cash:
		if projection.replaced_accounts.has(account_id):
			continue
		expected_cash[account_id] = str(projection.cash[account_id])
	var supplied_cash := {}
	for raw in cash_balances:
		if typeof(raw) != TYPE_DICTIONARY:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var id := str(raw.get("balance_id", ""))
		var amount = raw.get("amount", null)
		if id.is_empty() or supplied_cash.has(id) or not expected_cash.has(id) \
			or str(raw.get("currency", "")) != str(ledger.accounts[id].currency) \
			or typeof(amount) != TYPE_STRING or not Decimal.is_valid(amount) \
			or Decimal.compare(amount, expected_cash[id]) != 0:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		supplied_cash[id] = true
	if supplied_cash.size() != expected_cash.size():
		return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
	var expected_restricted: Dictionary = projection.restricted_balances
	var supplied_restricted := {}
	for raw in restricted_balances:
		if typeof(raw) != TYPE_DICTIONARY:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var id := str(raw.get("balance_id", ""))
		var amount = raw.get("amount", null)
		if id.is_empty() or supplied_restricted.has(id) or \
				not expected_restricted.has(id) or \
				str(raw.get("currency", "")) != str(ledger.accounts[id].currency) or \
				typeof(amount) != TYPE_STRING or not Decimal.is_valid(amount) or \
				Decimal.compare(amount, str(expected_restricted[id])) != 0:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		supplied_restricted[id] = true
	if supplied_restricted.size() != expected_restricted.size():
		return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
	var expected_other: Dictionary = projection.other_asset_values
	var checkpoints: Dictionary = projection.other_asset_checkpoints
	var supplied_other := {}
	for raw in other_asset_values:
		if typeof(raw) != TYPE_DICTIONARY:
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		var id := str(raw.get("asset_id", ""))
		var amount = raw.get("amount", null)
		if id.is_empty() or supplied_other.has(id) or \
				not expected_other.has(id) or \
				str(raw.get("currency", "")) != str(ledger.get("other_assets", {})[id].currency) or \
				typeof(amount) != TYPE_STRING or not Decimal.is_valid(amount) or \
				Decimal.compare(amount, str(expected_other[id])) != 0 or \
				str(raw.get("valuation_basis", "")) != \
				str(checkpoints[id].valuation_basis) or \
				str(raw.get("effective_at", "")) != \
				str(checkpoints[id].effective_at) or \
				str(raw.get("event_id", "")) != str(checkpoints[id].event_id):
			return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
		supplied_other[id] = true
	if supplied_other.size() != expected_other.size():
		return {"ok": false, "error": "VALUATION_COVERAGE_MISMATCH"}
	return {"ok": true}


func _read_slot(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "SLOT_READ_FAILED"}
	var parser := JSON.new()
	var outer_error := parser.parse(file.get_as_text())
	file.close()
	if outer_error != OK:
		return {"ok": false, "error": "SLOT_FORMAT_INVALID"}
	var parsed: Variant = parser.data
	if not parsed is Dictionary or parsed.get("format", "") != "moneybox-state":
		return {"ok": false, "error": "SLOT_FORMAT_INVALID"}
	var payload: Variant = parsed.get("payload", null)
	if not payload is String or str(parsed.get("sha256", "")) != payload.sha256_text():
		return {"ok": false, "error": "SLOT_CHECKSUM_INVALID"}
	parser = JSON.new()
	if parser.parse(payload) != OK:
		return {"ok": false, "error": "SLOT_PAYLOAD_INVALID"}
	var state: Variant = parser.data
	if not state is Dictionary or not state.has("ledger") or int(state.get("schema_version", -1)) != int(parsed.get("schema_version", -2)):
		return {"ok": false, "error": "SLOT_PAYLOAD_INVALID"}
	if int(parsed.schema_version) <= CURRENT_SCHEMA and not _valid_state(state):
		return {"ok": false, "error": "SLOT_STATE_INVALID"}
	return {"ok": true, "state": state, "schema_version": int(parsed.schema_version), "generation": int(parsed.generation)}


func _migrate(state: Dictionary) -> Dictionary:
	var version := int(state.get("schema_version", -1))
	if version == CURRENT_SCHEMA:
		var completed := state.duplicate(true)
		var hydrated := _add_quote_defaults(completed)
		if _add_ecology_defaults(completed):
			hydrated = true
		return {"ok": true, "state": completed, "migrated": hydrated}
	if version != 1:
		return {"ok": false, "error": "UNSUPPORTED_OLD_SCHEMA"}
	# Developer-schema v1 was a ledger-only local state, never a released database.
	var migrated := state.duplicate(true)
	migrated["schema_version"] = CURRENT_SCHEMA
	if not migrated.has("data_kind"):
		migrated["data_kind"] = "personal"
	if not migrated.has("mappings"):
		migrated["mappings"] = []
	if not migrated.has("inventory"):
		migrated["inventory"] = {}
	if not migrated.has("presentation"):
		migrated["presentation"] = {"privacy_mode": "show_total", "selected_jar": "jar-1", "skin_id": "basic"}
	_add_ecology_defaults(migrated)
	_add_quote_defaults(migrated)
	return {"ok": true, "state": migrated, "migrated": true}


func _add_quote_defaults(state: Dictionary) -> bool:
	var changed := false
	if not state.has("quote_gateway"):
		state.quote_gateway = QuoteGateway.new_state()
		changed = true
	if not state.has("valuation"):
		state.valuation = Valuation.new_state()
		changed = true
	return changed


func _add_ecology_defaults(state: Dictionary) -> bool:
	if not state.has("ecology") or (typeof(state.ecology) == TYPE_DICTIONARY and state.ecology.is_empty()):
		state.ecology = _default_ecology()
		return true
	return false


func _default_ecology() -> Dictionary:
	var ecology := Ecology.new_state("ecology-default", "ecology", "1970-01-01T00:00:00Z")
	ecology.scene.settings.active_skin_id = "basic"
	return ecology


func _slot_path(index: int) -> String:
	return _base_path + ".%d.json" % index


func _valid_state(state: Dictionary) -> bool:
	if typeof(state.get("ledger", null)) != TYPE_DICTIONARY or \
			typeof(state.get("mappings", [])) != TYPE_ARRAY or \
			typeof(state.get("inventory", {})) != TYPE_DICTIONARY or \
			typeof(state.get("presentation", {})) != TYPE_DICTIONARY or \
			typeof(state.get("ecology", {})) != TYPE_DICTIONARY:
		return false
	var ecology: Dictionary = state.get("ecology", {})
	# Nonempty pre-service v2 ecology dictionaries remain opaque so old backups are not erased.
	# A dictionary claiming the EcologyService schema must pass its full invariant checks.
	if ecology.has("schema_version") and not Ecology.validate(ecology):
		return false
	var ledger: Dictionary = state.ledger
	if typeof(ledger.get("accounts", null)) != TYPE_DICTIONARY or \
			typeof(ledger.get("instruments", null)) != TYPE_DICTIONARY or \
			typeof(ledger.get("events", null)) != TYPE_ARRAY or \
			typeof(ledger.get("quotes", null)) != TYPE_DICTIONARY or \
			typeof(ledger.get("fx_rates", null)) != TYPE_DICTIONARY:
		return false
	if not Ledger.project(ledger).ok:
		return false
	if not _valid_valuation_pending(state.get("valuation_pending", {}), ledger):
		return false
	var quote_state = state.get("quote_gateway", QuoteGateway.new_state())
	var valuation_state = state.get("valuation", Valuation.new_state())
	if typeof(quote_state) != TYPE_DICTIONARY or \
			typeof(valuation_state) != TYPE_DICTIONARY or \
			not _valid_quote_gateway_state(quote_state) or \
			not _valid_valuation_state(valuation_state, quote_state):
		return false
	var mappings: Array = state.get("mappings", [])
	var inventory: Dictionary = state.get("inventory", {})
	if mappings.is_empty():
		return inventory.is_empty()
	if inventory.is_empty() or not Inventory.validate(inventory):
		return false
	var latest: Dictionary = mappings.back()
	# A versioned visible mapping must belong to the present ledger. Pending
	# explicitly permits the previous jar to remain while assets await remapping.
	if latest.has("ledger_hash") and state.get("valuation_pending", {}).is_empty() and \
			(typeof(latest.ledger_hash) != TYPE_STRING or \
			str(latest.ledger_hash) != canonical_ledger_hash(ledger)):
		return false
	var mapped_whole := str(latest.get("whole_grams", ""))
	var mapped_fraction := str(latest.get("fractional_grams", ""))
	var equivalent := str(latest.get("equivalent_grams", ""))
	if not Decimal.is_valid(mapped_whole) or mapped_whole.contains(".") or \
			Decimal.compare(mapped_whole, "0") < 0 or not Decimal.is_valid(mapped_fraction) or \
			Decimal.compare(mapped_fraction, "0") < 0 or Decimal.compare(mapped_fraction, "1") >= 0 or \
			not Decimal.is_valid(equivalent) or not Decimal.is_valid(str(latest.get("amount", ""))) or \
			not Decimal.is_valid(str(latest.get("price_per_gram", ""))) or \
			Decimal.compare(str(latest.price_per_gram), "0") <= 0:
		return false
	if latest.get("negative_net_assets", false):
		if Decimal.compare(equivalent, "0") >= 0 or mapped_whole != "0" or mapped_fraction != "0":
			return false
	elif Decimal.compare(Decimal.add(mapped_whole, mapped_fraction), equivalent) != 0:
		return false
	return str(inventory.mapping_id) == str(latest.get("id", "")) and \
		Decimal.compare(str(inventory.whole_grams), mapped_whole) == 0 and \
		Decimal.compare(str(inventory.fractional_grams), mapped_fraction) == 0


func _valid_valuation_pending(raw: Variant, ledger: Dictionary) -> bool:
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	var pending: Dictionary = raw
	if pending.is_empty():
		return true
	if pending.size() != 2 or typeof(pending.get("reason", null)) != TYPE_STRING or \
			typeof(pending.get("ledger_hash", null)) != TYPE_STRING or \
			str(pending.reason).strip_edges().is_empty():
		return false
	var hash_text := str(pending.ledger_hash)
	if hash_text.length() != 64 or hash_text != canonical_ledger_hash(ledger):
		return false
	for index in hash_text.length():
		var character := hash_text.substr(index, 1)
		if not ((character >= "0" and character <= "9") or \
				(character >= "a" and character <= "f")):
			return false
	return true


func _valid_quote_gateway_state(state: Dictionary) -> bool:
	if int(state.get("schema_version", -1)) != 1 or \
			typeof(state.get("cache", null)) != TYPE_DICTIONARY or \
			typeof(state.get("batches", null)) != TYPE_DICTIONARY:
		return false
	for key in state.cache:
		var quote_raw = state.cache[key]
		if typeof(quote_raw) != TYPE_DICTIONARY:
			return false
		var quote: Dictionary = quote_raw
		if typeof(quote.get("identity", null)) != TYPE_DICTIONARY or \
				QuoteContract.identity_key(quote.identity) != str(key) or \
				not QuoteContract.validate_quote(quote, quote.identity,
					str(quote.get("fetched_at", ""))).ok:
			return false
	for batch_id in state.batches:
		var batch_raw = state.batches[batch_id]
		if typeof(batch_raw) != TYPE_DICTIONARY:
			return false
		var batch: Dictionary = batch_raw
		if str(batch.get("id", "")) != str(batch_id) or not Valuation._valid_batch(batch):
			return false
	return true


func _valid_valuation_state(state: Dictionary, quote_state: Dictionary) -> bool:
	if int(state.get("schema_version", -1)) != 1 or int(state.get("revision", -1)) < 0 \
			or typeof(state.get("processed_batches", null)) != TYPE_DICTIONARY \
			or typeof(state.get("snapshots", null)) != TYPE_DICTIONARY:
		return false
	if state.processed_batches.size() != state.snapshots.size() or \
			int(state.revision) != state.snapshots.size():
		return false
	for batch_id in state.processed_batches:
		var processed_raw = state.processed_batches[batch_id]
		if typeof(processed_raw) != TYPE_DICTIONARY or not quote_state.batches.has(batch_id):
			return false
		var processed: Dictionary = processed_raw
		var snapshot_id := str(processed.get("snapshot_id", ""))
		var snapshot_raw = state.snapshots.get(snapshot_id, null)
		if typeof(snapshot_raw) != TYPE_DICTIONARY:
			return false
		var snapshot: Dictionary = snapshot_raw
		if str(snapshot.get("id", "")) != snapshot_id or \
				str(snapshot.get("quote_batch_id", "")) != str(batch_id) or \
				typeof(snapshot.get("asset_total", null)) != TYPE_STRING or \
				not Decimal.is_valid(snapshot.asset_total):
			return false
	return true


func _quote_state_extends(current: Dictionary, proposed: Dictionary) -> bool:
	for batch_id in current.batches:
		if not proposed.batches.has(batch_id) or \
				JSON.stringify(current.batches[batch_id]) != JSON.stringify(proposed.batches[batch_id]):
			return false
	for key in current.cache:
		if not proposed.cache.has(key) or \
				str(proposed.cache[key].get("quoted_at", "")) < \
				str(current.cache[key].get("quoted_at", "")):
			return false
	return true
