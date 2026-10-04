extends "res://scripts/quotes/quote_provider.gd"
## Developer/manual adapter. Supplied values are explicitly MANUAL, never live market data.

const Contract = preload("res://scripts/quotes/quote_contract.gd")

var quotes: Dictionary = {}
var failures: Dictionary = {}
var enabled := true
var fetch_calls := 0
var requested_keys: Array[String] = []
var provider_version := "manual-development-v1"


func _init(configured_quotes: Dictionary = {}, configured_failures: Dictionary = {}) -> void:
	quotes = configured_quotes.duplicate(true)
	failures = configured_failures.duplicate(true)


func fetch_quotes(identities: Array, _now_at: String) -> Dictionary:
	fetch_calls += 1
	var result := {"ok": enabled, "provider_version": provider_version,
		"quotes": {}, "failures": {}, "error": "LICENSE_DISABLED" if not enabled else ""}
	for identity in identities:
		var key := Contract.identity_key(identity)
		requested_keys.append(key)
		if failures.has(key):
			result.failures[key] = str(failures[key])
		elif quotes.has(key):
			var supplied = quotes[key]
			if typeof(supplied) == TYPE_DICTIONARY:
				var manual: Dictionary = supplied.duplicate(true)
				manual.source = "USER_MANUAL"
				manual.delay = "MANUAL"
				manual.session = "MANUAL_INPUT"
				result.quotes[key] = manual
			else:
				result.failures[key] = "INVALID_MANUAL_QUOTE"
		else:
			result.failures[key] = "NO_MANUAL_QUOTE"
	return result
