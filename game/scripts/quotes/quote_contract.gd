extends RefCounted
## Local quote DTO validation. Prices stay decimal strings; timestamps are explicit UTC.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const KINDS := ["STOCK", "ETF", "FUND", "FX", "GOLD"]
const DELAYS := ["REALTIME", "DELAYED", "UNKNOWN", "MANUAL"]


static func identity_key(identity: Dictionary) -> String:
	var normalized := normalize_identity(identity)
	if normalized.is_empty():
		return ""
	return "|".join([normalized.kind, normalized.market, normalized.symbol,
		normalized.currency, normalized.share_class])


static func normalize_identity(identity: Dictionary) -> Dictionary:
	var kind := str(identity.get("kind", "")).strip_edges().to_upper()
	var market := str(identity.get("market", "")).strip_edges().to_upper()
	var symbol := str(identity.get("symbol", "")).strip_edges().to_upper()
	var currency := str(identity.get("currency", "")).strip_edges().to_upper()
	var share_class := str(identity.get("share_class", "")).strip_edges().to_upper()
	if not KINDS.has(kind) or not _token(market, false) or not _token(symbol, false) \
		or not _currency(currency) or not _token(share_class, true):
		return {}
	if kind == "FX":
		var parts := symbol.split("/")
		if market != "FX" or parts.size() != 2 or not _currency(parts[0]) \
			or not _currency(parts[1]) or parts[1] != currency or parts[0] == currency \
			or not share_class.is_empty():
			return {}
	if kind == "GOLD" and (market != "SPOT" or symbol != "XAU" or not share_class.is_empty()):
		return {}
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": share_class}


static func validate_quote(quote: Dictionary, requested_identity: Dictionary, now_at: String) -> Dictionary:
	var key := identity_key(requested_identity)
	var raw_identity = quote.get("identity", {})
	if key.is_empty() or typeof(raw_identity) != TYPE_DICTIONARY \
		or identity_key(raw_identity) != key:
		return _error("IDENTITY_MISMATCH")
	var price_value = quote.get("price", null)
	if typeof(price_value) != TYPE_STRING or not Decimal.is_valid(price_value) \
		or Decimal.compare(price_value, "0") <= 0:
		return _error("INVALID_PRICE")
	if not _token(str(quote.get("id", "")), false) \
		or not _token(str(quote.get("source", "")), false) \
		or not _token(str(quote.get("provider_symbol", "")), false):
		return _error("MISSING_PROVENANCE")
	if str(quote.get("currency", "")) != requested_identity.currency:
		return _error("CURRENCY_MISMATCH")
	var unit := str(quote.get("unit", ""))
	match str(requested_identity.kind):
		"FX":
			if unit != "CURRENCY_PER_FOREIGN_UNIT":
				return _error("INVALID_UNIT")
		"GOLD":
			if not ["CURRENCY_PER_GRAM", "CURRENCY_PER_TROY_OUNCE"].has(unit):
				return _error("INVALID_UNIT")
		_:
			if unit != "CURRENCY_PER_SHARE":
				return _error("INVALID_UNIT")
	if not DELAYS.has(str(quote.get("delay", ""))) or str(quote.get("session", "")).is_empty():
		return _error("MISSING_MARKET_STATUS")
	var quoted_unix := utc_unix(str(quote.get("quoted_at", "")))
	var fetched_unix := utc_unix(str(quote.get("fetched_at", "")))
	var now_unix := utc_unix(now_at)
	if quoted_unix < 0 or fetched_unix < 0 or now_unix < 0 or quoted_unix > fetched_unix \
		or fetched_unix > now_unix + 300:
		return _error("INVALID_TIME")
	var cleaned := quote.duplicate(true)
	cleaned.identity = normalize_identity(requested_identity)
	cleaned.price = Decimal.canonical(price_value)
	return {"ok": true, "quote": cleaned}


static func utc_unix(value: String) -> int:
	# Require seconds and UTC Z. Godot's parser reads the zone-free portion.
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-" \
		or value.substr(10, 1) != "T" or value.substr(13, 1) != ":" \
		or value.substr(16, 1) != ":" or not value.ends_with("Z"):
		return -1
	for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
		var character := value.substr(index, 1)
		if character < "0" or character > "9":
			return -1
	var year := value.substr(0, 4).to_int()
	var month := value.substr(5, 2).to_int()
	var day := value.substr(8, 2).to_int()
	var hour := value.substr(11, 2).to_int()
	var minute := value.substr(14, 2).to_int()
	var second := value.substr(17, 2).to_int()
	if year < 1970 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59:
		return -1
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and (year % 400 == 0 or (year % 4 == 0 and year % 100 != 0)):
		days[1] = 29
	if day < 1 or day > days[month - 1]:
		return -1
	var unix := int(Time.get_unix_time_from_datetime_string(value.substr(0, 19)))
	if unix < 0:
		return -1
	# Reject dates normalized by the engine, such as February 30.
	if Time.get_datetime_string_from_unix_time(unix) != value.substr(0, 19):
		return -1
	return unix


static func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if character < "A" or character > "Z":
			return false
	return true


static func _token(value: String, allow_empty: bool) -> bool:
	if value.is_empty():
		return allow_empty
	if value.length() > 128 or value.contains("|"):
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if (character >= "A" and character <= "Z") or (character >= "a" and character <= "z") \
			or (character >= "0" and character <= "9") or "._:/-".contains(character):
			continue
		return false
	return true


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
