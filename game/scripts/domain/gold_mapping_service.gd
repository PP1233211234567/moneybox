extends RefCounted
## Deterministic gold equivalence. Decimal strings are authoritative; physics never feeds this service.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const TROY_OUNCE_GRAMS := "31.1034768"
const GRAM_PRECISION := 30
const ALGORITHM_VERSION := 1


static func calculate(amount: String, price_per_gram: String, metric: String = "total_assets") -> Dictionary:
	var normalized_amount: String = Decimal.canonical(amount)
	var normalized_price: String = Decimal.canonical(price_per_gram)
	if normalized_amount.is_empty():
		return _error("INVALID_AMOUNT")
	if normalized_price.is_empty() or Decimal.compare(normalized_price, "0") <= 0:
		return _error("INVALID_GOLD_PRICE")
	if metric != "total_assets" and metric != "net_assets":
		return _error("INVALID_METRIC")
	if metric == "total_assets" and Decimal.compare(normalized_amount, "0") < 0:
		return _error("NEGATIVE_TOTAL_ASSETS")
	var raw_grams: String = Decimal.divide(normalized_amount, normalized_price, GRAM_PRECISION)
	if raw_grams.is_empty():
		return _error("DIVISION_FAILED")
	if Decimal.compare(normalized_amount, "0") < 0:
		return {"ok": true, "amount": normalized_amount, "price_per_gram": normalized_price,
			"metric": metric, "equivalent_grams": raw_grams, "whole_grams": "0",
			"fractional_grams": "0", "negative_net_assets": true}
	# Divide(..., precision) rounds. Correct its integer part against the exact decimal inputs,
	# so a value just below an integer cannot create an extra bean.
	var whole: String = Decimal.floor_nonnegative(raw_grams)
	while Decimal.compare(Decimal.multiply(whole, normalized_price), normalized_amount) > 0:
		whole = Decimal.subtract(whole, "1")
	while Decimal.compare(Decimal.multiply(Decimal.add(whole, "1"), normalized_price), normalized_amount) <= 0:
		whole = Decimal.add(whole, "1")
	var remainder: String = Decimal.subtract(normalized_amount, Decimal.multiply(whole, normalized_price))
	var fraction: String = Decimal.divide(remainder, normalized_price, GRAM_PRECISION)
	if fraction == "1":
		fraction = "0." + "9".repeat(GRAM_PRECISION)
	var projected: String = Decimal.add(whole, fraction)
	return {"ok": true, "amount": normalized_amount, "price_per_gram": normalized_price,
		"metric": metric, "equivalent_grams": projected, "whole_grams": whole,
		"fractional_grams": fraction, "fraction_remainder_amount": remainder,
		"negative_net_assets": false}


static func price_per_gram(quote: Dictionary, base_currency: String, fx: Dictionary = {}) -> Dictionary:
	var quote_price: String = Decimal.canonical(str(quote.get("price", "")))
	if quote_price.is_empty() or Decimal.compare(quote_price, "0") <= 0:
		return _error("INVALID_GOLD_PRICE")
	var unit: String = str(quote.get("unit", ""))
	if unit != "CURRENCY_PER_GRAM" and unit != "CURRENCY_PER_TROY_OUNCE":
		return _error("INVALID_GOLD_UNIT")
	var quote_currency: String = str(quote.get("currency", ""))
	if quote_currency.is_empty() or base_currency.is_empty():
		return _error("MISSING_CURRENCY")
	var converted: String = quote_price
	var fx_id := ""
	if quote_currency != base_currency:
		if str(fx.get("from_currency", "")) != quote_currency or str(fx.get("to_currency", "")) != base_currency:
			return _error("MISSING_FX_RATE")
		if str(fx.get("id", "")).is_empty() or str(fx.get("source", "")).is_empty() or \
				str(fx.get("quoted_at", "")).is_empty():
			return _error("MISSING_FX_PROVENANCE")
		var rate: String = Decimal.canonical(str(fx.get("rate", "")))
		if rate.is_empty() or Decimal.compare(rate, "0") <= 0:
			return _error("INVALID_FX_RATE")
		converted = Decimal.multiply(quote_price, rate)
		fx_id = str(fx.get("id", ""))
	if unit == "CURRENCY_PER_TROY_OUNCE":
		converted = Decimal.divide(converted, TROY_OUNCE_GRAMS, GRAM_PRECISION)
	return {"ok": true, "price_per_gram": converted, "fx_rate_id": fx_id,
		"quote_currency": quote_currency, "base_currency": base_currency}


static func create_revision(asset_snapshot_id: String, amount: String, base_currency: String,
		quote: Dictionary, fx: Dictionary = {}, metric: String = "total_assets",
		previous: Dictionary = {}, reason: String = "USER_ASSET_UPDATE") -> Dictionary:
	if asset_snapshot_id.is_empty() or str(quote.get("id", "")).is_empty():
		return _error("MISSING_SOURCE_ID")
	if str(quote.get("source", "")).is_empty() or str(quote.get("quoted_at", "")).is_empty():
		return _error("MISSING_QUOTE_PROVENANCE")
	var converted := price_per_gram(quote, base_currency, fx)
	if not converted.ok:
		return converted
	var result := calculate(amount, converted.price_per_gram, metric)
	if not result.ok:
		return result
	var fingerprint := JSON.stringify([ALGORITHM_VERSION, asset_snapshot_id, metric,
		base_currency, result.amount, str(quote.id), str(quote.get("unit", "")),
		Decimal.canonical(str(quote.price)), converted.fx_rate_id,
		Decimal.canonical(str(fx.get("rate", "1"))) if not converted.fx_rate_id.is_empty() else "1"])
	var mapping_key: String = fingerprint.sha256_text()
	if previous.get("mapping_key", "") == mapping_key:
		return {"ok": true, "changed": false, "revision": previous.duplicate(true)}
	var revision := {
		"id": "map-" + mapping_key.substr(0, 24),
		"sequence": int(previous.get("sequence", 0)) + 1,
		"mapping_key": mapping_key,
		"mapping_version": ALGORITHM_VERSION,
		"asset_snapshot_id": asset_snapshot_id,
		"metric": metric,
		"amount": result.amount,
		"base_currency": base_currency,
		"gold_quote_id": str(quote.id),
		"gold_quote_price": Decimal.canonical(str(quote.price)),
		"gold_quote_unit": str(quote.unit),
		"gold_quote_currency": str(quote.currency),
		"gold_quote_source": str(quote.get("source", "")),
		"gold_quote_quoted_at": str(quote.get("quoted_at", "")),
		"gold_quote_fetched_at": str(quote.get("fetched_at", "")),
		"fx_rate_id": converted.fx_rate_id,
		"fx_rate": Decimal.canonical(str(fx.get("rate", "1"))) if not converted.fx_rate_id.is_empty() else "1",
		"fx_rate_source": str(fx.get("source", "")) if not converted.fx_rate_id.is_empty() else "",
		"fx_rate_quoted_at": str(fx.get("quoted_at", "")) if not converted.fx_rate_id.is_empty() else "",
		"price_per_gram": converted.price_per_gram,
		"equivalent_grams": result.equivalent_grams,
		"whole_grams": result.whole_grams,
		"fractional_grams": result.fractional_grams,
		"fraction_remainder_amount": result.get("fraction_remainder_amount", "0"),
		"negative_net_assets": result.negative_net_assets,
		"reason": reason,
	}
	if not previous.is_empty() and str(previous.get("metric", "")) == metric and str(previous.get("base_currency", "")) == base_currency:
		var old_price: String = str(previous.get("price_per_gram", ""))
		var old_amount: String = str(previous.get("amount", ""))
		if Decimal.is_valid(old_price) and Decimal.compare(old_price, "0") > 0 and Decimal.is_valid(old_amount):
			var asset_delta: String = Decimal.divide(Decimal.subtract(result.amount, old_amount), old_price, GRAM_PRECISION)
			var total_delta: String = Decimal.subtract(result.equivalent_grams,
				str(previous.get("equivalent_grams", "0")))
			var repricing: String = Decimal.subtract(total_delta, asset_delta)
			revision["asset_change_grams"] = asset_delta
			revision["gold_price_change_grams"] = repricing
	return {"ok": true, "changed": true, "revision": revision}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
