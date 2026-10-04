extends RefCounted
## Deterministic local cache and completed quote batches. Caller persists returned state.

const Contract = preload("res://scripts/quotes/quote_contract.gd")


static func new_state() -> Dictionary:
	return {"schema_version": 1, "cache": {}, "batches": {}}


static func refresh(state: Dictionary, requested: Array, provider: RefCounted,
		now_at: String, batch_id: String, cache_window_seconds: int = 300,
		stale_after_seconds: int = 86400) -> Dictionary:
	if batch_id.is_empty() or batch_id.contains("|") or batch_id.length() > 128 \
		or cache_window_seconds < 0 or stale_after_seconds <= 0:
		return _error("INVALID_REQUEST")
	var now_unix := Contract.utc_unix(now_at)
	if now_unix < 0:
		return _error("INVALID_TIME")
	if int(state.get("schema_version", -1)) != 1 \
		or typeof(state.get("cache", null)) != TYPE_DICTIONARY \
		or typeof(state.get("batches", null)) != TYPE_DICTIONARY:
		return _error("INVALID_STATE")
	var keys: Array[String] = []
	var identities := {}
	for raw_identity in requested:
		if typeof(raw_identity) != TYPE_DICTIONARY:
			return _error("INVALID_IDENTITY")
		var identity: Dictionary = Contract.normalize_identity(raw_identity)
		var key := Contract.identity_key(identity)
		if key.is_empty():
			return _error("INVALID_IDENTITY")
		if not identities.has(key):
			identities[key] = identity
			keys.append(key)
	if keys.is_empty():
		return _error("EMPTY_REQUEST")
	keys.sort()
	var fingerprint := "\n".join(keys).sha256_text()
	var existing_raw = state.batches.get(batch_id, {})
	if typeof(existing_raw) != TYPE_DICTIONARY:
		return _error("INVALID_STATE")
	var existing: Dictionary = existing_raw
	if not existing.is_empty():
		if existing.get("request_fingerprint", "") != fingerprint:
			return _error("BATCH_ID_CONFLICT")
		return {"ok": true, "duplicate": true, "state": state,
			"batch": existing.duplicate(true)}
	var next := state.duplicate(true)
	var need_fetch: Array = []
	var cache_hits := {}
	for key in keys:
		var cached_raw = next.cache.get(key, {})
		var cached: Dictionary = cached_raw if typeof(cached_raw) == TYPE_DICTIONARY else {}
		if not cached.is_empty():
			var validation := Contract.validate_quote(cached, identities[key], now_at)
			if validation.ok:
				var age := maxi(0, now_unix - Contract.utc_unix(str(cached.fetched_at)))
				if age < cache_window_seconds:
					cache_hits[key] = true
					continue
		need_fetch.append(identities[key])
	var response: Dictionary = {"ok": true, "provider_version": "cache-only", "quotes": {}, "failures": {}}
	if not need_fetch.is_empty():
		if provider == null:
			return _error("PROVIDER_NOT_CONFIGURED")
		response = provider.fetch_quotes(need_fetch, now_at)
		if typeof(response) != TYPE_DICTIONARY:
			return _error("INVALID_PROVIDER_RESPONSE")
	var provider_version := str(response.get("provider_version", "unknown"))
	var returned_quotes: Dictionary = response.get("quotes", {}) if typeof(response.get("quotes", {})) == TYPE_DICTIONARY else {}
	var failures: Dictionary = response.get("failures", {}) if typeof(response.get("failures", {})) == TYPE_DICTIONARY else {}
	var response_ok: bool = response.get("ok", false) == true
	var entries := {}
	var success_symbols: Array[String] = []
	var stale_symbols: Array[String] = []
	var failed_symbols: Array[String] = []
	var requested_symbols: Array = []
	for key in keys:
		var identity: Dictionary = identities[key]
		requested_symbols.append(identity)
		var cached_raw = next.cache.get(key, {})
		var cached: Dictionary = cached_raw if typeof(cached_raw) == TYPE_DICTIONARY else {}
		var candidate_raw = returned_quotes.get(key, {}) if not cache_hits.has(key) else cached
		var candidate: Dictionary = candidate_raw if typeof(candidate_raw) == TYPE_DICTIONARY else {}
		var reason := ""
		var valid := Contract.validate_quote(candidate, identity, now_at) if not candidate.is_empty() else {"ok": false, "error": "NO_QUOTE"}
		if not response_ok and not cache_hits.has(key):
			valid = {"ok": false, "error": str(response.get("error", "PROVIDER_UNAVAILABLE"))}
		if valid.ok and not cache_hits.has(key) and not cached.is_empty() \
			and str(candidate.quoted_at) < str(cached.quoted_at):
			valid = {"ok": false, "error": "OLDER_QUOTE"}
		if valid.ok:
			var quote: Dictionary = valid.quote
			var age := maxi(0, now_unix - Contract.utc_unix(str(quote.quoted_at)))
			if not cache_hits.has(key):
				next.cache[key] = quote.duplicate(true)
			if age >= stale_after_seconds:
				stale_symbols.append(key)
				entries[key] = {"identity": identity, "status": "STALE", "quote": quote,
					"cache_hit": cache_hits.has(key), "reason": "QUOTE_AGE_EXCEEDED"}
			else:
				success_symbols.append(key)
				entries[key] = {"identity": identity, "status": "SUCCESS", "quote": quote,
					"cache_hit": cache_hits.has(key)}
			continue
		reason = str(response.get("error", "PROVIDER_UNAVAILABLE")) if not response_ok \
			and not cache_hits.has(key) else str(failures.get(key, valid.get("error", "PROVIDER_UNAVAILABLE")))
		var fallback := Contract.validate_quote(cached, identity, now_at) if not cached.is_empty() else {"ok": false}
		if fallback.ok:
			stale_symbols.append(key)
			entries[key] = {"identity": identity, "status": "STALE_FALLBACK",
				"quote": fallback.quote, "cache_hit": true, "reason": reason}
		else:
			failed_symbols.append(key)
			entries[key] = {"identity": identity, "status": "FAILED", "reason": reason}
	var status := "COMPLETE"
	if not failed_symbols.is_empty():
		status = "INCOMPLETE"
	elif not stale_symbols.is_empty():
		status = "COMPLETE_WITH_STALE"
	var batch := {"schema_version": 1, "id": batch_id, "status": status,
		"request_fingerprint": fingerprint, "provider_versions": {"selected": provider_version},
		"requested_symbols": requested_symbols, "success_symbols": success_symbols,
		"stale_symbols": stale_symbols, "failed_symbols": failed_symbols,
		"entries": entries, "completed_at": now_at}
	next.batches[batch_id] = batch.duplicate(true)
	return {"ok": true, "duplicate": false, "state": next, "batch": batch}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
