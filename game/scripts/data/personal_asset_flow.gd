extends RefCounted
## Structure-first personal ledger entry. Preview has no writes or market value;
## confirmation saves the ledger and current valuation_pending marker together.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")

const MAX_COMMANDS := 100
const PENDING_REASON := "ASSET_STRUCTURE_CHANGE"

var _store: RefCounted


func _init(base_path: String = "user://personal/moneybox") -> void:
	_store = Store.new(base_path)


func preview(commands: Array, expected_generation: int) -> Dictionary:
	if expected_generation < 0:
		return _error("GENERATION_REQUIRED")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return _error("PERSONAL_PROJECT_REQUIRED")
	if expected_generation == 0 or project.get("mappings", []).is_empty():
		return _error("PERSONAL_PROJECT_NOT_INITIALIZED")
	var simulated := _simulate(project.ledger, commands)
	if not simulated.ok:
		return simulated
	var source_hash := JSON.stringify(project).sha256_text()
	var command_hash := JSON.stringify(simulated.commands).sha256_text()
	var ledger_hash := Store.canonical_ledger_hash(simulated.ledger)
	return {"ok": true, "generation": expected_generation,
		"source_project_sha256": source_hash,
		"commands_sha256": command_hash,
		"projected_ledger_hash": ledger_hash,
		"preview_id": _preview_id(expected_generation, source_hash,
			command_hash, ledger_hash),
		"duplicate": simulated.duplicate,
		"command_count": simulated.commands.size(),
		"cash_balances": simulated.cash_balances,
		"restricted_balances": simulated.restricted_balances,
		"other_asset_values": simulated.other_asset_values,
		"position_quantities": simulated.position_quantities,
		"missing_valuation_inputs": simulated.missing_valuation_inputs,
		"valuation_status": _valuation_status(project) if simulated.duplicate else \
			"NEEDS_VALUATION"}


func confirm(commands: Array, shown_preview: Dictionary,
		confirmation: Dictionary) -> Dictionary:
	if confirmation.get("confirmed", null) != true or \
			typeof(confirmation.get("preview_id", null)) != TYPE_STRING or \
			str(confirmation.preview_id).is_empty():
		return _error("EXPLICIT_CONFIRMATION_REQUIRED")
	if shown_preview.get("ok", false) != true or \
			typeof(shown_preview.get("generation", null)) != TYPE_INT or \
			int(shown_preview.generation) < 0 or \
			str(shown_preview.get("preview_id", "")) != str(confirmation.preview_id):
		return _error("VALID_PREVIEW_REQUIRED")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != int(shown_preview.generation):
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return _error("PERSONAL_PROJECT_REQUIRED")
	if int(loaded.generation) == 0 or project.get("mappings", []).is_empty():
		return _error("PERSONAL_PROJECT_NOT_INITIALIZED")
	var source_hash := JSON.stringify(project).sha256_text()
	if source_hash != str(shown_preview.get("source_project_sha256", "")):
		return _error("SOURCE_PROJECT_CHANGED")
	var simulated := _simulate(project.ledger, commands)
	if not simulated.ok:
		return simulated
	var command_hash := JSON.stringify(simulated.commands).sha256_text()
	var ledger_hash := Store.canonical_ledger_hash(simulated.ledger)
	var expected_id := _preview_id(int(loaded.generation), source_hash,
		command_hash, ledger_hash)
	if command_hash != str(shown_preview.get("commands_sha256", "")) or \
			ledger_hash != str(shown_preview.get("projected_ledger_hash", "")) or \
			expected_id != str(shown_preview.preview_id):
		return _error("PREVIEW_INPUT_CHANGED")
	if simulated.duplicate:
		return {"ok": true, "duplicate": true, "generation": int(loaded.generation),
			"ledger_hash": Store.canonical_ledger_hash(project.ledger),
			"valuation_status": _valuation_status(project)}
	var next: Dictionary = project.duplicate(true)
	next.ledger = simulated.ledger
	next.valuation_pending = {"reason": PENDING_REASON, "ledger_hash": ledger_hash}
	var saved: Dictionary = _store.save_project(next, int(loaded.generation))
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "generation": int(saved.generation),
		"ledger_hash": ledger_hash,
		"valuation_pending": next.valuation_pending.duplicate(true),
		"valuation_status": "NEEDS_VALUATION"}


func _simulate(ledger: Dictionary, commands: Array) -> Dictionary:
	if commands.is_empty() or commands.size() > MAX_COMMANDS:
		return _error("COMMAND_BATCH_SIZE_INVALID")
	var next: Dictionary = ledger.duplicate(true)
	var normalized: Array = []
	var duplicate_count := 0
	for raw in commands:
		var parsed := _normalize_command(raw)
		if not parsed.ok:
			return parsed
		var command: Dictionary = parsed.command
		var applied := Ledger.apply(next, command)
		if not applied.ok:
			return applied
		if applied.duplicate:
			duplicate_count += 1
		next = applied.state
		normalized.append(command)
	if duplicate_count > 0 and duplicate_count != normalized.size():
		return _error("MIXED_DUPLICATE_COMMANDS")
	var projection := Ledger.project(next)
	if not projection.ok:
		return projection
	var quantities := {}
	for key in projection.positions:
		quantities[key] = str(projection.positions[key].quantity)
	return {"ok": true, "ledger": next, "commands": normalized,
		"duplicate": duplicate_count == normalized.size(),
		"cash_balances": projection.cash.duplicate(true),
		"restricted_balances": projection.restricted_balances.duplicate(true),
		"other_asset_values": projection.other_asset_values.duplicate(true),
		"position_quantities": quantities,
		"missing_valuation_inputs": projection.incomplete.duplicate()}


func _normalize_command(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return _error("INVALID_COMMAND")
	var command: Dictionary = raw
	var command_id := str(command.get("command_id", ""))
	var kind := str(command.get("type", ""))
	if not _id(command_id):
		return _error("COMMAND_ID_REQUIRED")
	match kind:
		"account_create":
			if not _allowed(command, ["command_id", "type", "account"]) or \
					typeof(command.get("account", null)) != TYPE_DICTIONARY:
				return _error("INVALID_ACCOUNT_INPUT")
			var account: Dictionary = command.account
			if not _allowed(account, ["id", "name", "currency", "mode", "cost_method",
					"asset_kind",
					"source_id", "custodian_id", "channel_id", "plan_id"]) or \
					not _id(str(account.get("id", ""))) or \
					typeof(account.get("name", null)) != TYPE_STRING or \
					str(account.name).strip_edges().is_empty() or \
					not _currency(str(account.get("currency", ""))) or \
					not ["detail", "aggregate"].has(str(account.get("mode", ""))) or \
					not ["CASH", "PROVIDENT_FUND", "PENSION"].has(str(account.get("asset_kind", "CASH"))) or \
					(str(account.get("asset_kind", "CASH")) != "CASH" and str(account.get("mode", "")) != "detail") or \
					not ["FIFO", "MOVING_AVERAGE"].has(str(account.get("cost_method", ""))):
				return _error("INVALID_ACCOUNT_INPUT")
			var cleaned := {"id": str(account.id), "name": str(account.name).strip_edges(),
				"currency": str(account.currency), "mode": str(account.mode),
				"cost_method": str(account.cost_method)}
			if account.has("asset_kind"):
				cleaned.asset_kind = str(account.asset_kind)
			for field in ["source_id", "custodian_id", "channel_id", "plan_id"]:
				if account.has(field):
					if typeof(account[field]) != TYPE_STRING:
						return _error("INVALID_ACCOUNT_INPUT")
					cleaned[field] = str(account[field])
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "account": cleaned}}
		"instrument_create":
			if not _allowed(command, ["command_id", "type", "instrument"]) or \
					typeof(command.get("instrument", null)) != TYPE_DICTIONARY:
				return _error("INVALID_INSTRUMENT_INPUT")
			var instrument: Dictionary = command.instrument
			if not _allowed(instrument, ["id", "name", "kind", "market", "symbol",
					"currency", "share_class"]) or not _id(str(instrument.get("id", ""))) or \
					not ["STOCK", "ETF", "FUND"].has(str(instrument.get("kind", ""))):
				return _error("INVALID_INSTRUMENT_INPUT")
			var identity := QuoteContract.normalize_identity({"kind": instrument.kind,
				"market": instrument.get("market", ""),
				"symbol": instrument.get("symbol", ""),
				"currency": instrument.get("currency", ""),
				"share_class": instrument.get("share_class", "")})
			if identity.is_empty():
				return _error("INVALID_INSTRUMENT_INPUT")
			var cleaned := identity.duplicate(true)
			cleaned.id = str(instrument.id)
			if instrument.has("name"):
				if typeof(instrument.name) != TYPE_STRING:
					return _error("INVALID_INSTRUMENT_INPUT")
				cleaned.name = str(instrument.name).strip_edges()
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "instrument": cleaned}}
		"other_asset_create":
			if not _allowed(command, ["command_id", "type", "asset", "opening_value"]) or \
					typeof(command.get("asset", null)) != TYPE_DICTIONARY or \
					typeof(command.get("opening_value", null)) != TYPE_DICTIONARY:
				return _error("INVALID_OTHER_ASSET_INPUT")
			var asset: Dictionary = command.asset
			var opening: Dictionary = command.opening_value
			if not _allowed(asset, ["id", "name", "currency", "ownership_scope",
					"ownership_note", "dedup_key"]) or \
					not _id(str(asset.get("id", ""))) or \
					typeof(asset.get("name", null)) != TYPE_STRING or \
					str(asset.name).strip_edges().is_empty() or \
					str(asset.name).length() > 128 or \
					not _currency(str(asset.get("currency", ""))) or \
					not ["SOLE", "OWNED_SHARE"].has(str(asset.get("ownership_scope", ""))) or \
					typeof(asset.get("ownership_note", null)) != TYPE_STRING or \
					str(asset.ownership_note).strip_edges().is_empty() or \
					str(asset.ownership_note).length() > 256 or \
					typeof(asset.get("dedup_key", null)) != TYPE_STRING or \
					str(asset.dedup_key).strip_edges().is_empty() or \
					str(asset.dedup_key).length() > 128 or \
					not _valid_other_value(opening):
				return _error("INVALID_OTHER_ASSET_INPUT")
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind,
				"asset": {"id": str(asset.id), "name": str(asset.name).strip_edges(),
					"currency": str(asset.currency),
					"ownership_scope": str(asset.ownership_scope),
					"ownership_note": str(asset.ownership_note).strip_edges(),
					"dedup_key": str(asset.dedup_key).strip_edges().to_upper()},
				"opening_value": _clean_other_value(opening)}}
		"other_asset_value_set":
			if not _allowed(command, ["command_id", "type", "asset_id", "amount",
					"valuation_basis", "effective_at"]) or \
					not _id(str(command.get("asset_id", ""))) or \
					not _valid_other_value(command):
				return _error("INVALID_OTHER_ASSET_VALUE_INPUT")
			var cleaned := _clean_other_value(command)
			cleaned["command_id"] = command_id
			cleaned["type"] = kind
			cleaned["asset_id"] = str(command.asset_id)
			return {"ok": true, "command": cleaned}
		"opening_cash":
			if not _allowed(command, ["command_id", "type", "account_id", "amount",
					"effective_at"]) or not _id(str(command.get("account_id", ""))) or \
					not _amount(command.get("amount", null), false) or \
					QuoteContract.utc_unix(str(command.get("effective_at", ""))) < 0:
				return _error("INVALID_OPENING_CASH_INPUT")
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "account_id": str(command.account_id),
				"amount": Decimal.canonical(str(command.amount)),
				"effective_at": str(command.effective_at)}}
		"restricted_balance_set":
			if not _allowed(command, ["command_id", "type", "account_id", "amount",
					"source_note", "effective_at"]) or \
					not _id(str(command.get("account_id", ""))) or \
					not _amount(command.get("amount", null), false) or \
					typeof(command.get("source_note", null)) != TYPE_STRING or \
					str(command.source_note).strip_edges().is_empty() or \
					str(command.source_note).length() > 256 or \
					QuoteContract.utc_unix(str(command.get("effective_at", ""))) < 0:
				return _error("INVALID_RESTRICTED_BALANCE_INPUT")
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "account_id": str(command.account_id),
				"amount": Decimal.canonical(str(command.amount)),
				"source_note": str(command.source_note).strip_edges(),
				"effective_at": str(command.effective_at)}}
		"opening_position":
			if not _allowed(command, ["command_id", "type", "account_id", "instrument_id",
					"quantity", "reference_price", "cost_basis", "effective_at"]) or \
					not _id(str(command.get("account_id", ""))) or \
					not _id(str(command.get("instrument_id", ""))) or \
					not _amount(command.get("quantity", null), true) or \
					not _amount(command.get("reference_price", null), true) or \
					typeof(command.get("cost_basis", null)) != TYPE_STRING or \
					(not str(command.cost_basis).is_empty() and \
					 not _amount(command.cost_basis, false)) or \
					QuoteContract.utc_unix(str(command.get("effective_at", ""))) < 0:
				return _error("INVALID_OPENING_POSITION_INPUT")
			var cost_basis := str(command.cost_basis)
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "account_id": str(command.account_id),
				"instrument_id": str(command.instrument_id),
				"quantity": Decimal.canonical(str(command.quantity)),
				"reference_price": Decimal.canonical(str(command.reference_price)),
				"cost_basis": Decimal.canonical(cost_basis) if not cost_basis.is_empty() else "",
				"effective_at": str(command.effective_at)}}
		"transfer":
			if not _allowed(command, ["command_id", "type", "account_id", "to_account_id",
					"amount", "effective_at"]) or \
					not _id(str(command.get("account_id", ""))) or \
					not _id(str(command.get("to_account_id", ""))) or \
					not _amount(command.get("amount", null), true) or \
					QuoteContract.utc_unix(str(command.get("effective_at", ""))) < 0:
				return _error("INVALID_TRANSFER_INPUT")
			return {"ok": true, "command": {"command_id": command_id,
				"type": kind, "account_id": str(command.account_id),
				"to_account_id": str(command.to_account_id),
				"amount": Decimal.canonical(str(command.amount)),
				"effective_at": str(command.effective_at)}}
		_:
			return _error("UNSUPPORTED_ASSET_COMMAND")


func _preview_id(generation: int, source_hash: String,
		command_hash: String, ledger_hash: String) -> String:
	return JSON.stringify([generation, source_hash, command_hash, ledger_hash]).sha256_text()


func _valuation_status(project: Dictionary) -> String:
	if not project.get("valuation_pending", {}).is_empty() or \
			project.get("mappings", []).is_empty():
		return "NEEDS_VALUATION"
	var latest: Dictionary = project.mappings.back()
	return "CURRENT" if str(latest.get("ledger_hash", "")) == \
		Store.canonical_ledger_hash(project.ledger) else "NEEDS_VALUATION"


func _allowed(data: Dictionary, keys: Array) -> bool:
	for key in data:
		if not keys.has(key):
			return false
	return true


func _id(value: String) -> bool:
	return not value.is_empty() and value.length() <= 128 and not value.contains("|")


func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in 3:
		var character := value.substr(index, 1)
		if character < "A" or character > "Z":
			return false
	return true


func _amount(value: Variant, positive: bool) -> bool:
	return typeof(value) == TYPE_STRING and Decimal.is_valid(value) and \
		(Decimal.compare(value, "0") > 0 if positive else Decimal.compare(value, "0") >= 0)


func _valid_other_value(value: Dictionary) -> bool:
	var allowed := _allowed(value, ["amount", "valuation_basis", "effective_at"]) or \
		_allowed(value, ["command_id", "type", "asset_id", "amount",
			"valuation_basis", "effective_at"])
	return allowed and _amount(value.get("amount", null), false) and \
		typeof(value.get("valuation_basis", null)) == TYPE_STRING and \
		not str(value.valuation_basis).strip_edges().is_empty() and \
		str(value.valuation_basis).length() <= 256 and \
		QuoteContract.utc_unix(str(value.get("effective_at", ""))) >= 0


func _clean_other_value(value: Dictionary) -> Dictionary:
	return {"amount": Decimal.canonical(str(value.amount)),
		"valuation_basis": str(value.valuation_basis).strip_edges(),
		"effective_at": str(value.effective_at)}


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
