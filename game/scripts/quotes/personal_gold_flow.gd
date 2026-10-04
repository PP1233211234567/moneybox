extends RefCounted
## Personal mapping consumes only a saved valuation bound to the current ledger hash.
## Batch gold/FX selection, Mapping and Inventory are committed in one ProjectStore generation.

const Store = preload("res://scripts/data/project_store.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")

const MAX_QUOTE_AGE_SECONDS := 86400
const REASONS := ["USER_ASSET_UPDATE", "USER_REPRICE"]

var _store: RefCounted


func _init(base_path: String) -> void:
	_store = Store.new(base_path)


func apply(selection: Dictionary, expected_generation: int, now_at: String = "") -> Dictionary:
	if expected_generation < 0:
		return _error("GENERATION_REQUIRED")
	if now_at.is_empty():
		now_at = Time.get_datetime_string_from_system(true, false) + "Z"
	var now_unix := Contract.utc_unix(now_at)
	if now_unix < 0:
		return _error("INVALID_TIME")
	var snapshot_id := str(selection.get("valuation_snapshot_id", ""))
	var batch_id := str(selection.get("gold_batch_id", ""))
	var gold_key := str(selection.get("gold_quote_key", ""))
	var gold_fx_key := str(selection.get("gold_fx_key", ""))
	var allow_stale = selection.get("allow_stale", null)
	var reason := str(selection.get("reason", ""))
	if snapshot_id.is_empty() or batch_id.is_empty() or gold_key.is_empty() \
			or typeof(allow_stale) != TYPE_BOOL or not REASONS.has(reason):
		return _error("INVALID_SELECTION")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return _error("PERSONAL_PROJECT_REQUIRED")
	var verified: Dictionary = _store.current_valuation_snapshot(project, snapshot_id)
	if not verified.ok:
		return verified
	var pending = project.get("valuation_pending", {})
	if typeof(pending) != TYPE_DICTIONARY:
		return _error("UNVERIFIED_ASSET_VERSION")
	if not pending.is_empty() and str(pending.get("ledger_hash", "")) != str(verified.ledger_hash):
		return _error("UNVERIFIED_ASSET_VERSION")
	var asset_quotes := _verify_snapshot_quotes(verified.snapshot, now_at, allow_stale)
	if not asset_quotes.ok:
		return asset_quotes
	var batch: Dictionary = project.quote_gateway.batches.get(batch_id, {})
	if batch.is_empty():
		return _error("GOLD_BATCH_NOT_FOUND")
	if Contract.utc_unix(str(batch.get("completed_at", ""))) > now_unix + 300:
		return _error("GOLD_BATCH_IN_FUTURE")
	if not ["COMPLETE", "COMPLETE_WITH_STALE"].has(str(batch.get("status", ""))) or \
			not batch.get("failed_symbols", []).is_empty():
		return _error("GOLD_BATCH_INCOMPLETE")
	if not batch.get("stale_symbols", []).is_empty() and not allow_stale:
		return _error("STALE_QUOTE_CONFIRMATION_REQUIRED")
	var gold_result := _selected_quote(batch, gold_key, "GOLD", allow_stale, now_at)
	if not gold_result.ok:
		return gold_result
	var gold: Dictionary = gold_result.quote
	var base_currency := str(verified.snapshot.base_currency)
	var fx := {}
	var gold_fx_stale := false
	if str(gold.currency) == base_currency:
		if not gold_fx_key.is_empty():
			return _error("UNEXPECTED_GOLD_FX")
	else:
		var expected_fx := Contract.identity_key({"kind": "FX", "market": "FX",
			"symbol": str(gold.currency) + "/" + base_currency,
			"currency": base_currency, "share_class": ""})
		if expected_fx.is_empty() or gold_fx_key != expected_fx:
			return _error("GOLD_FX_SELECTION_REQUIRED")
		var fx_result := _selected_quote(batch, gold_fx_key, "FX", allow_stale, now_at)
		if not fx_result.ok:
			return fx_result
		var fx_quote: Dictionary = fx_result.quote
		gold_fx_stale = fx_result.stale
		fx = {"id": fx_quote.id, "rate": fx_quote.price,
			"from_currency": gold.currency, "to_currency": base_currency,
			"source": fx_quote.source, "quoted_at": fx_quote.quoted_at,
			"fetched_at": fx_quote.fetched_at}
	var previous: Dictionary = project.mappings.back() if not project.mappings.is_empty() else {}
	var mapping := Mapping.create_revision(snapshot_id, str(verified.snapshot.asset_total),
		base_currency, gold, fx, "total_assets", previous, reason)
	if not mapping.ok:
		return mapping
	if not mapping.changed:
		# A legacy or previous-ledger mapping cannot clear pending merely because
		# its economic inputs happen to produce the same mapping key.
		if str(previous.get("ledger_hash", "")) != str(verified.ledger_hash):
			return _error("UNVERIFIED_ASSET_VERSION")
		if pending.is_empty():
			return {"ok": true, "duplicate": true, "changed": false,
				"generation": expected_generation, "mapping": mapping.revision}
		# A pending marker may be cleared only after the whole verified project is saved.
		var cleared := project.duplicate(true)
		cleared.erase("valuation_pending")
		var saved_clear: Dictionary = _store.save_project(cleared, expected_generation)
		if not saved_clear.ok:
			return saved_clear
		return {"ok": true, "duplicate": true, "changed": false,
			"generation": saved_clear.generation, "mapping": mapping.revision}
	# A key identifies one asset version plus one gold/FX input combination.
	# Replaying an older key after another reprice must not create a second
	# revision or silently revert the displayed jar.
	for prior in project.mappings:
		if str(prior.get("mapping_key", "")) == str(mapping.revision.mapping_key):
			return _error("MAPPING_KEY_ALREADY_APPLIED")
	var next := project.duplicate(true)
	var revision: Dictionary = mapping.revision.duplicate(true)
	_revision_unique_id(next.mappings, revision)
	revision.created_at = now_at
	revision.gold_quote_batch_id = batch_id
	revision.gold_quote_batch_completed_at = str(batch.completed_at)
	revision.gold_quote_status = gold_result.status
	revision.stale_confirmed = allow_stale and (asset_quotes.stale or \
		gold_result.stale or gold_fx_stale or not batch.stale_symbols.is_empty())
	revision.ledger_hash = str(verified.ledger_hash)
	revision.asset_ledger_hash = str(verified.ledger_hash)
	var inventory: Dictionary = next.inventory if not next.inventory.is_empty() else Inventory.new_state()
	var applied := Inventory.apply_mapping(inventory, revision,
		"apply-" + str(revision.id), int(inventory.revision))
	if not applied.ok or applied.get("duplicate", false):
		return _error("INVENTORY_MAPPING_FAILED")
	next.mappings.append(revision)
	next.inventory = applied.state
	var selected_jar := str(next.presentation.get("selected_jar", ""))
	var selected_exists := false
	for jar in next.inventory.jars:
		if str(jar.get("id", "")) == selected_jar:
			selected_exists = true
	if not selected_exists and not next.inventory.jars.is_empty():
		next.presentation.selected_jar = str(next.inventory.jars[0].id)
	next.erase("valuation_pending")
	var saved: Dictionary = _store.save_project(next, expected_generation)
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "changed": true,
		"generation": saved.generation, "mapping": revision,
		"inventory_revision": applied.state.revision}


func _selected_quote(batch: Dictionary, key: String, kind: String,
		allow_stale: bool, now_at: String) -> Dictionary:
	var entries: Dictionary = batch.get("entries", {})
	var entry: Dictionary = entries.get(key, {})
	if entry.is_empty() or str(entry.get("identity", {}).get("kind", "")) != kind:
		return _error("INVALID_QUOTE_SELECTION")
	var status := str(entry.get("status", ""))
	if not ["SUCCESS", "STALE", "STALE_FALLBACK"].has(status):
		return _error("SELECTED_QUOTE_FAILED")
	if status != "SUCCESS" and not allow_stale:
		return _error("STALE_QUOTE_CONFIRMATION_REQUIRED")
	var raw_quote = entry.get("quote", null)
	if typeof(raw_quote) != TYPE_DICTIONARY or Contract.identity_key(entry.identity) != key:
		return _error("INVALID_QUOTE_SELECTION")
	var checked := Contract.validate_quote(raw_quote, entry.identity, now_at)
	if not checked.ok:
		return _error("INVALID_SELECTED_QUOTE")
	var age := Contract.utc_unix(now_at) - \
		Contract.utc_unix(str(checked.quote.quoted_at))
	if age >= MAX_QUOTE_AGE_SECONDS and not allow_stale:
		return _error("STALE_QUOTE_CONFIRMATION_REQUIRED")
	if typeof(checked.quote.price) != TYPE_STRING or \
			Decimal.compare(str(checked.quote.price), "0") <= 0:
		return _error("INVALID_SELECTED_QUOTE")
	return {"ok": true, "quote": checked.quote, "status": status,
		"stale": status != "SUCCESS" or age >= MAX_QUOTE_AGE_SECONDS}


func _verify_snapshot_quotes(snapshot: Dictionary, now_at: String,
		allow_stale: bool) -> Dictionary:
	# Cash in the base currency needs no market quote. Every quote actually used
	# by the saved valuation is rechecked when the mapping is made.
	if typeof(snapshot.get("position_values", null)) != TYPE_ARRAY or \
			typeof(snapshot.get("cash_values", null)) != TYPE_ARRAY or \
			typeof(snapshot.get("stale_symbols", null)) != TYPE_ARRAY:
		return _error("UNVERIFIED_ASSET_VERSION")
	if not snapshot.stale_symbols.is_empty() and not allow_stale:
		return _error("STALE_ASSET_QUOTE_CONFIRMATION_REQUIRED")
	var any_stale: bool = not snapshot.stale_symbols.is_empty()
	var base_currency := str(snapshot.get("base_currency", ""))
	for raw in snapshot.position_values:
		if typeof(raw) != TYPE_DICTIONARY or \
				typeof(raw.get("instrument_identity", null)) != TYPE_DICTIONARY or \
				typeof(raw.get("quote", null)) != TYPE_DICTIONARY:
			return _error("UNVERIFIED_ASSET_VERSION")
		var quote_result := _verify_snapshot_quote(raw.quote, raw.instrument_identity,
				now_at, allow_stale)
		if not quote_result.ok:
			return quote_result
		any_stale = any_stale or quote_result.stale
		var fx_result := _verify_snapshot_fx(raw.get("fx_quote", null),
				str(raw.get("currency", "")), base_currency, now_at, allow_stale)
		if not fx_result.ok:
			return fx_result
		any_stale = any_stale or fx_result.stale
	for raw in snapshot.cash_values:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("UNVERIFIED_ASSET_VERSION")
		var fx_result := _verify_snapshot_fx(raw.get("fx_quote", null),
				str(raw.get("currency", "")), base_currency, now_at, allow_stale)
		if not fx_result.ok:
			return fx_result
		any_stale = any_stale or fx_result.stale
	return {"ok": true, "stale": any_stale}


func _verify_snapshot_fx(raw_fx: Variant, from_currency: String,
		base_currency: String, now_at: String, allow_stale: bool) -> Dictionary:
	if typeof(raw_fx) != TYPE_DICTIONARY:
		return _error("UNVERIFIED_ASSET_VERSION")
	if from_currency == base_currency:
		return {"ok": true, "stale": false} if raw_fx.is_empty() else \
			_error("UNVERIFIED_ASSET_VERSION")
	var fx_identity := {"kind": "FX", "market": "FX",
		"symbol": from_currency + "/" + base_currency,
		"currency": base_currency, "share_class": ""}
	if Contract.identity_key(fx_identity).is_empty():
		return _error("UNVERIFIED_ASSET_VERSION")
	return _verify_snapshot_quote(raw_fx, fx_identity, now_at, allow_stale)


func _verify_snapshot_quote(quote: Dictionary, identity: Dictionary,
		now_at: String, allow_stale: bool) -> Dictionary:
	var checked := Contract.validate_quote(quote, identity, now_at)
	if not checked.ok:
		return _error("UNVERIFIED_ASSET_VERSION")
	var age := Contract.utc_unix(now_at) - Contract.utc_unix(str(checked.quote.quoted_at))
	if age >= MAX_QUOTE_AGE_SECONDS and not allow_stale:
		return _error("STALE_ASSET_QUOTE_CONFIRMATION_REQUIRED")
	return {"ok": true, "stale": age >= MAX_QUOTE_AGE_SECONDS}


func _revision_unique_id(history: Array, revision: Dictionary) -> void:
	for prior in history:
		if str(prior.get("id", "")) == str(revision.id):
			revision.id = "map-" + (str(revision.mapping_key) + ":" + \
				str(revision.sequence)).sha256_text().substr(0, 24)
			return


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
