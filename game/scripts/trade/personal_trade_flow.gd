extends RefCounted
## Personal-only, local trade drafts. A confirmed trade and its pending valuation marker
## are committed in one ProjectStore generation; old beans must not be shown as current.

const Store = preload("res://scripts/data/project_store.gd")
const Drafts = preload("res://scripts/trade/trade_draft_service.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")

var _store: RefCounted


func _init(base_path: String = "user://personal/moneybox") -> void:
	_store = Store.new(base_path)


func list_candidates() -> Dictionary:
	var loaded := _load_personal()
	if not loaded.ok:
		return loaded
	return {"ok": true, "generation": loaded.generation,
		"candidates": _candidates(loaded.state.ledger)}


func create_draft(source_text: String, source_text_local_ref: String, draft_id: String,
		created_at: String, reference_date: String, expected_generation: int) -> Dictionary:
	if not _valid_id(source_text_local_ref) or not _valid_id(draft_id) \
		or source_text.strip_edges().is_empty() or source_text.length() > 500 \
		or QuoteContract.utc_unix(created_at) < 0 or expected_generation < 1:
		return _error("INVALID_DRAFT_INPUT")
	var loaded := _load_personal()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	var candidates := _candidates(project.ledger)
	var draft := Drafts.parse_local(source_text, source_text_local_ref, draft_id,
		created_at, reference_date, candidates)
	var drafts: Dictionary = project.get("trade_drafts", {})
	var source_fingerprint := JSON.stringify([draft_id, source_text_local_ref, source_text]).sha256_text()
	var source_hashes: Dictionary = project.get("trade_draft_source_hashes", {})
	if drafts.has(draft_id):
		var stored_draft := _hydrate_draft(drafts[draft_id])
		if str(source_hashes.get(draft_id, "")) != source_fingerprint \
			or JSON.stringify(stored_draft) != JSON.stringify(draft):
			return _error("DRAFT_ID_CONFLICT")
		return {"ok": true, "duplicate": true, "generation": loaded.generation,
			"draft": stored_draft, "candidates": candidates,
			"validation": Drafts.validate(stored_draft, project.ledger, candidates)}
	var next: Dictionary = project.duplicate(true)
	if not next.has("trade_drafts"):
		next.trade_drafts = {}
	next.trade_drafts[draft_id] = draft
	if not next.has("trade_draft_source_hashes"):
		next.trade_draft_source_hashes = {}
	next.trade_draft_source_hashes[draft_id] = source_fingerprint
	var saved: Dictionary = _store.save_project(next, expected_generation)
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "generation": saved.generation,
		"draft": draft.duplicate(true), "candidates": candidates,
		"validation": Drafts.validate(draft, project.ledger, candidates)}


func load_draft(draft_id: String, reviewed_tax_amount: String = "") -> Dictionary:
	var loaded := _load_personal()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	var drafts: Dictionary = project.get("trade_drafts", {})
	if not drafts.has(draft_id) or typeof(drafts[draft_id]) != TYPE_DICTIONARY:
		return _error("DRAFT_NOT_FOUND")
	var candidates := _candidates(project.ledger)
	var draft: Dictionary = _hydrate_draft(drafts[draft_id])
	return {"ok": true, "generation": loaded.generation,
		"draft": draft.duplicate(true), "candidates": candidates,
		"validation": Drafts.validate(draft, project.ledger, candidates, reviewed_tax_amount),
		"valuation_pending": project.get("valuation_pending", {}).duplicate(true)}


func revise_draft(draft_id: String, changed_values: Dictionary,
		expected_generation: int) -> Dictionary:
	if expected_generation < 1:
		return _error("GENERATION_REQUIRED")
	var loaded := _load_personal()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	var drafts: Dictionary = project.get("trade_drafts", {})
	if not drafts.has(draft_id) or typeof(drafts[draft_id]) != TYPE_DICTIONARY:
		return _error("DRAFT_NOT_FOUND")
	var revised := Drafts.revise(_hydrate_draft(drafts[draft_id]), changed_values)
	if not revised.ok:
		return revised
	var next: Dictionary = project.duplicate(true)
	next.trade_drafts[draft_id] = revised.draft
	var saved: Dictionary = _store.save_project(next, expected_generation)
	if not saved.ok:
		return saved
	var candidates := _candidates(project.ledger)
	return {"ok": true, "generation": saved.generation, "draft": revised.draft,
		"candidates": candidates,
		"validation": Drafts.validate(revised.draft, project.ledger, candidates)}


func confirm_trade(confirmation: Dictionary, expected_generation: int) -> Dictionary:
	if expected_generation < 1 or confirmation.get("confirmed", false) != true \
		or typeof(confirmation.get("draft_id")) != TYPE_STRING \
		or typeof(confirmation.get("draft_revision")) != TYPE_INT \
		or typeof(confirmation.get("idempotency_key")) != TYPE_STRING \
		or typeof(confirmation.get("tax_amount")) != TYPE_STRING:
		return _error("INVALID_CONFIRMATION")
	var key: String = confirmation.idempotency_key
	if not _valid_id(key) or not Decimal.is_valid(confirmation.tax_amount):
		return _error("INVALID_CONFIRMATION")
	var fingerprint := _confirmation_fingerprint(confirmation)
	var loaded := _load_personal()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	var drafts: Dictionary = project.get("trade_drafts", {})
	var draft_id: String = confirmation.draft_id
	if not drafts.has(draft_id) or typeof(drafts[draft_id]) != TYPE_DICTIONARY:
		return _error("DRAFT_NOT_FOUND")
	var draft: Dictionary = _hydrate_draft(drafts[draft_id])
	var confirmations: Dictionary = project.get("trade_confirmations", {})
	if confirmations.has(key):
		if typeof(confirmations[key]) != TYPE_DICTIONARY:
			return _error("INVALID_TRADE_STATE")
		var prior: Dictionary = confirmations[key]
		if str(prior.get("fingerprint", "")) != fingerprint \
			or draft.get("status", "") != "confirmed" \
			or draft.get("confirmed_command_id", "") != key \
			or not project.ledger.command_fingerprints.has(key):
			return _error("IDEMPOTENCY_KEY_CONFLICT")
		# The same confirmed request can be retried after a lost response. It never writes.
		return {"ok": true, "duplicate": true, "generation": loaded.generation,
			"committed_generation": prior.committed_generation,
			"preview": prior.preview.duplicate(true),
			"valuation_pending": project.get("valuation_pending", {}).duplicate(true),
			"display_ready": project.get("valuation_pending", {}).is_empty()}
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	if draft.get("status", "") == "confirmed":
		return _error("ALREADY_CONFIRMED")
	var candidates := _candidates(project.ledger)
	var applied := Drafts.confirm(project.ledger, draft, candidates, confirmation)
	if not applied.ok:
		return applied
	if applied.duplicate:
		return _error("LEDGER_KEY_ALREADY_USED")
	var next: Dictionary = project.duplicate(true)
	next.ledger = applied.state
	next.trade_drafts[draft_id] = applied.draft
	if not next.has("trade_confirmations"):
		next.trade_confirmations = {}
	var ledger_hash := Store.canonical_ledger_hash(next.ledger)
	next.trade_confirmations[key] = {"fingerprint": fingerprint,
		"draft_id": draft_id, "draft_revision": draft.revision,
		"committed_generation": expected_generation + 1,
		"ledger_hash": ledger_hash, "preview": applied.preview.duplicate(true)}
	next.valuation_pending = {"reason": "TRADE_CONFIRM", "ledger_hash": ledger_hash}
	var saved: Dictionary = _store.save_project(next, expected_generation)
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "generation": saved.generation,
		"committed_generation": saved.generation,
		"preview": applied.preview.duplicate(true),
		"valuation_pending": next.valuation_pending.duplicate(true),
		"display_ready": false}


func _load_personal() -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if loaded.state.get("data_kind", "") != "personal":
		return _error("NOT_PERSONAL_DATA")
	for name in ["trade_drafts", "trade_draft_source_hashes", "trade_confirmations"]:
		if typeof(loaded.state.get(name, {})) != TYPE_DICTIONARY:
			return _error("INVALID_TRADE_STATE")
	return loaded


func _candidates(ledger: Dictionary) -> Dictionary:
	var accounts := []
	var account_ids: Array = ledger.get("accounts", {}).keys()
	account_ids.sort()
	for id in account_ids:
		var account: Dictionary = ledger.accounts[id]
		var aliases := []
		_add_alias(aliases, str(account.get("name", "")))
		_add_alias(aliases, str(account.get("institution_name", "")))
		accounts.append({"id": str(id), "currency": str(account.get("currency", "")),
			"aliases": aliases})
	var instruments := []
	var instrument_ids: Array = ledger.get("instruments", {}).keys()
	instrument_ids.sort()
	for id in instrument_ids:
		var instrument: Dictionary = ledger.instruments[id]
		var aliases := []
		_add_alias(aliases, str(instrument.get("name", "")))
		instruments.append({"id": str(id), "symbol": str(instrument.get("symbol", "")),
			"market": str(instrument.get("market", "")),
			"currency": str(instrument.get("currency", "")), "aliases": aliases})
	return {"accounts": accounts, "instruments": instruments}


func _add_alias(aliases: Array, value: String) -> void:
	var cleaned := value.strip_edges()
	if not cleaned.is_empty() and not aliases.has(cleaned):
		aliases.append(cleaned)


func _hydrate_draft(raw: Variant) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return {}
	var draft: Dictionary = raw.duplicate(true)
	# JSON roundtrips represent all numbers as floats; TradeDraft v1 still requires
	# integer version and revision and numeric confidence before deterministic review.
	draft.schema_version = int(draft.get("schema_version", -1))
	draft.revision = int(draft.get("revision", -1))
	draft.confidence = float(draft.get("confidence", -1.0))
	if typeof(draft.get("fields")) == TYPE_DICTIONARY:
		for name in draft.fields:
			if typeof(draft.fields[name]) == TYPE_DICTIONARY:
				draft.fields[name].confidence = float(draft.fields[name].get("confidence", -1.0))
	return draft


func _confirmation_fingerprint(confirmation: Dictionary) -> String:
	return JSON.stringify([confirmation.draft_id, confirmation.draft_revision,
		Decimal.canonical(confirmation.tax_amount), confirmation.idempotency_key]).sha256_text()


func _valid_id(value: String) -> bool:
	return not value.is_empty() and not value.contains("|") and value.length() <= 128


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
