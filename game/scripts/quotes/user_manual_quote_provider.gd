extends "res://scripts/quotes/quote_provider.gd"
## Local user-entered quotes only. No network access or fallback prices.

const Contract = preload("res://scripts/quotes/quote_contract.gd")

var _quotes: Dictionary


func _init(quotes: Dictionary) -> void:
	_quotes = quotes.duplicate(true)


func fetch_quotes(identities: Array, _now_at: String) -> Dictionary:
	var found := {}
	var failures := {}
	for identity in identities:
		var key := Contract.identity_key(identity)
		if _quotes.has(key):
			found[key] = _quotes[key].duplicate(true)
		else:
			failures[key] = "MANUAL_QUOTE_MISSING"
	return {"ok": true, "provider_version": "user-manual-entry-v1",
		"quotes": found, "failures": failures}
