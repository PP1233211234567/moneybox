extends RefCounted
## Event-ledger kernel. Inputs and outputs use decimal strings; projections are rebuilt from events.

const Decimal = preload("res://scripts/data/decimal_text.gd")

static func new_state(base_currency: String = "CNY") -> Dictionary:
	return {
		"schema_version": 1,
		"base_currency": base_currency,
		"accounts": {},
		"instruments": {},
		"other_assets": {},
		"events": [],
		"quotes": {},
		"quote_history": [],
		"fx_rates": {},
		"command_fingerprints": {},
	}


static func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	var command_id := str(command.get("command_id", ""))
	if command_id.is_empty() or command_id.contains("|"):
		return _error("COMMAND_ID_REQUIRED")
	var fingerprint := JSON.stringify(command)
	var existing: Dictionary = state.get("command_fingerprints", {})
	if existing.has(command_id):
		if existing[command_id] != fingerprint:
			return _error("IDEMPOTENCY_KEY_CONFLICT")
		return {"ok": true, "state": state, "duplicate": true, "projection": project(state)}
	var next := state.duplicate(true)
	var kind := str(command.get("type", ""))
	var validation := _apply_to_copy(next, command, kind)
	if not validation.ok:
		return validation
	var projection := project(next)
	if not projection.ok:
		return _error(str(projection.error))
	next.command_fingerprints[command_id] = fingerprint
	return {"ok": true, "state": next, "duplicate": false, "projection": projection}


static func project(state: Dictionary) -> Dictionary:
	var accounts: Dictionary = state.get("accounts", {})
	var instruments: Dictionary = state.get("instruments", {})
	if typeof(state.get("other_assets", {})) != TYPE_DICTIONARY:
		return _error("INVALID_OTHER_ASSETS")
	var other_assets: Dictionary = state.get("other_assets", {})
	var seen_other_dedup := {}
	for asset_id in other_assets:
		if typeof(other_assets[asset_id]) != TYPE_DICTIONARY or \
				not _valid_id(str(asset_id)) or \
				str(other_assets[asset_id].get("id", "")) != str(asset_id) or \
				not _valid_other_asset(other_assets[asset_id]):
			return _error("INVALID_OTHER_ASSETS")
		var dedup_key := str(other_assets[asset_id].dedup_key).strip_edges().to_upper()
		if seen_other_dedup.has(dedup_key):
			return _error("DUPLICATE_OTHER_ASSET")
		seen_other_dedup[dedup_key] = true
	var cash := {}
	var restricted_balances := {}
	var other_asset_values := {}
	var other_asset_checkpoints := {}
	var positions := {}
	var replaced_accounts := {}
	var voided := {}
	var external_net := "0"
	var dividends := {}
	var dividend_totals_by_currency := {}
	var events: Array = state.get("events", []).duplicate(true)
	for event in events:
		if event.type == "void":
			voided[event.target_event_id] = true
		elif event.type == "aggregate_replaced":
			replaced_accounts[event.account_id] = true
	for account_id in accounts:
		var asset_kind := str(accounts[account_id].get("asset_kind", "CASH"))
		if not ["CASH", "PROVIDENT_FUND", "PENSION"].has(asset_kind):
			return _error("INVALID_ACCOUNT_ASSET_KIND")
		if asset_kind == "CASH":
			cash[account_id] = "0"
		else:
			restricted_balances[account_id] = "0"
	events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.effective_at == b.effective_at:
			return int(a.sequence) < int(b.sequence)
		return str(a.effective_at) < str(b.effective_at)
	)
	for event in events:
		if voided.has(event.id):
			continue
		var kind: String = event.type
		if kind == "void" or kind == "aggregate_replaced":
			continue
		if kind == "other_asset_value_set":
			var asset_id := str(event.get("asset_id", ""))
			if not other_assets.has(asset_id) or \
					not _nonnegative_value(event.get("amount", null)):
				return _error("INVALID_OTHER_ASSET_EVENT")
			other_asset_values[asset_id] = str(event.amount)
			other_asset_checkpoints[asset_id] = {"event_id": str(event.id),
				"effective_at": str(event.effective_at),
				"valuation_basis": str(event.get("valuation_basis", ""))}
			continue
		var account_id: String = event.get("account_id", "")
		if not accounts.has(account_id):
			return _error("UNKNOWN_ACCOUNT")
		if kind != "restricted_balance_set" and not cash.has(account_id):
			return _error("INVALID_ACCOUNT_ASSET_KIND")
		match kind:
			"restricted_balance_set":
				if not restricted_balances.has(account_id):
					return _error("INVALID_ACCOUNT_ASSET_KIND")
				restricted_balances[account_id] = event.amount
			"opening_cash":
				cash[account_id] = Decimal.add(cash[account_id], event.amount)
			"dividend_suggest":
				if dividends.has(event.id):
					return _error("DUPLICATE_DIVIDEND_SUGGESTION")
				dividends[event.id] = {"status": "suggested", "account_id": account_id, "instrument_id": event.instrument_id, "currency": accounts[account_id].currency, "suggested_gross": event.gross_amount, "source": event.source, "suggested_at": event.effective_at, "confirmation_event_id": "", "gross_income": "0", "withholding_tax": "0", "net_cash": "0"}
			"dividend_confirm":
				var suggestion_id := str(event.suggestion_event_id)
				if not dividends.has(suggestion_id):
					return _error("DIVIDEND_SUGGESTION_NOT_FOUND")
				var dividend: Dictionary = dividends[suggestion_id]
				if dividend.status == "confirmed":
					return _error("DIVIDEND_ALREADY_CONFIRMED")
				if dividend.account_id != account_id or dividend.instrument_id != event.instrument_id or Decimal.subtract(event.gross_amount, event.withholding_tax) != event.net_cash:
					return _error("INVALID_DIVIDEND_CONFIRMATION")
				dividend.status = "confirmed"
				dividend.confirmation_event_id = event.id
				dividend.gross_income = event.gross_amount
				dividend.withholding_tax = event.withholding_tax
				dividend.net_cash = event.net_cash
				dividends[suggestion_id] = dividend
				cash[account_id] = Decimal.add(cash[account_id], event.net_cash)
				var currency: String = accounts[account_id].currency
				if not dividend_totals_by_currency.has(currency):
					dividend_totals_by_currency[currency] = {"gross_income": "0", "withholding_tax": "0", "net_cash": "0"}
				var totals: Dictionary = dividend_totals_by_currency[currency]
				totals.gross_income = Decimal.add(totals.gross_income, event.gross_amount)
				totals.withholding_tax = Decimal.add(totals.withholding_tax, event.withholding_tax)
				totals.net_cash = Decimal.add(totals.net_cash, event.net_cash)
				dividend_totals_by_currency[currency] = totals
			"cash_delta":
				cash[account_id] = Decimal.add(cash[account_id], event.delta)
				if event.get("external", false):
					external_net = Decimal.add(external_net, event.delta)
			"transfer":
				var destination: String = event.to_account_id
				if not cash.has(destination):
					return _error("UNKNOWN_ACCOUNT")
				cash[account_id] = Decimal.subtract(cash[account_id], event.amount)
				cash[destination] = Decimal.add(cash[destination], event.amount)
			"buy", "sell":
				var instrument_id: String = event.instrument_id
				if not instruments.has(instrument_id):
					return _error("UNKNOWN_INSTRUMENT")
				var key := account_id + "|" + instrument_id
				if not positions.has(key):
					positions[key] = {"account_id": account_id, "instrument_id": instrument_id, "quantity": "0", "cost": "0", "cost_known": true, "realized_gain": "0", "lots": [], "last_trade_price": ""}
				var position: Dictionary = positions[key]
				var gross := Decimal.multiply(event.quantity, event.unit_price)
				if kind == "buy":
					var full_cost := Decimal.add(gross, event.fee)
					cash[account_id] = Decimal.subtract(cash[account_id], full_cost)
					position.quantity = Decimal.add(position.quantity, event.quantity)
					position.cost = Decimal.add(position.cost, full_cost)
					position.lots.append({"quantity": event.quantity, "cost": full_cost, "event_id": event.id})
				else:
					if Decimal.compare(position.quantity, event.quantity) < 0:
						return _error("INSUFFICIENT_HOLDING")
					var consumed_cost := ""
					if position.cost_known:
						consumed_cost = _consume_cost(position, event.quantity, str(accounts[account_id].get("cost_method", "FIFO")))
						if consumed_cost.is_empty():
							return _error("INVALID_COST_LOTS")
					var proceeds := Decimal.subtract(gross, event.fee)
					cash[account_id] = Decimal.add(cash[account_id], proceeds)
					position.quantity = Decimal.subtract(position.quantity, event.quantity)
					if position.cost_known:
						position.cost = Decimal.subtract(position.cost, consumed_cost)
						position.realized_gain = Decimal.add(position.realized_gain, Decimal.subtract(proceeds, consumed_cost))
					else:
						position.realized_gain = ""
				position.last_trade_price = event.unit_price
				positions[key] = position
			"opening_position":
				var instrument_id: String = event.instrument_id
				if not instruments.has(instrument_id):
					return _error("UNKNOWN_INSTRUMENT")
				var key := account_id + "|" + instrument_id
				if not positions.has(key):
					positions[key] = {"account_id": account_id, "instrument_id": instrument_id, "quantity": "0", "cost": "0", "cost_known": true, "realized_gain": "0", "lots": [], "last_trade_price": ""}
				var position: Dictionary = positions[key]
				position.quantity = Decimal.add(position.quantity, event.quantity)
				position.last_trade_price = event.reference_price
				if str(event.get("cost_basis", "")).is_empty():
					position.cost_known = false
				else:
					position.cost = Decimal.add(position.cost, event.cost_basis)
					position.lots.append({"quantity": event.quantity, "cost": event.cost_basis, "event_id": event.id})
				positions[key] = position
			_:
				return _error("UNKNOWN_EVENT_TYPE")
		if cash.has(account_id) and Decimal.compare(cash[account_id], "0") < 0:
			return _error("INSUFFICIENT_CASH")
	var total := "0"
	var incomplete: Array[String] = []
	var account_assets := {}
	for account_id in accounts:
		if replaced_accounts.has(account_id):
			continue
		var currency: String = accounts[account_id].currency
		var amount: String = str(cash.get(account_id,
			restricted_balances.get(account_id, "0")))
		var converted := _to_base(state, amount, currency)
		if converted.is_empty():
			incomplete.append("FX:" + currency)
		else:
			total = Decimal.add(total, converted)
			account_assets[account_id] = converted
	for key in positions:
		var position: Dictionary = positions[key]
		if position.quantity == "0" or replaced_accounts.has(position.account_id):
			continue
		var instrument: Dictionary = instruments[position.instrument_id]
		var quote: Dictionary = state.get("quotes", {}).get(position.instrument_id, {})
		var price: String = str(quote.get("price", position.last_trade_price))
		if not Decimal.is_valid(price) or Decimal.compare(price, "0") <= 0:
			incomplete.append("QUOTE:" + position.instrument_id)
			continue
		var market_value := Decimal.multiply(position.quantity, price)
		var converted := _to_base(state, market_value, str(instrument.currency))
		if converted.is_empty():
			incomplete.append("FX:" + str(instrument.currency))
			continue
		total = Decimal.add(total, converted)
		account_assets[position.account_id] = Decimal.add(str(account_assets.get(position.account_id, "0")), converted)
	var other_asset_base_values := {}
	for asset_id in other_assets:
		if not other_asset_values.has(asset_id):
			incomplete.append("VALUE:" + str(asset_id))
			continue
		var asset: Dictionary = other_assets[asset_id]
		var converted := _to_base(state, str(other_asset_values[asset_id]),
			str(asset.get("currency", "")))
		if converted.is_empty():
			incomplete.append("FX:" + str(asset.get("currency", "")))
			continue
		total = Decimal.add(total, converted)
		other_asset_base_values[asset_id] = converted
	return {"ok": true, "cash": cash, "restricted_balances": restricted_balances,
		"other_asset_values": other_asset_values,
		"other_asset_checkpoints": other_asset_checkpoints,
		"other_asset_base_values": other_asset_base_values,
		"positions": positions, "account_assets": account_assets,
		"asset_total": total if incomplete.is_empty() else "",
		"external_net_invested": external_net, "incomplete": incomplete,
		"replaced_accounts": replaced_accounts, "dividends": dividends,
		"dividend_totals_by_currency": dividend_totals_by_currency}


static func _apply_to_copy(state: Dictionary, command: Dictionary, kind: String) -> Dictionary:
	var command_id: String = command.command_id
	match kind:
		"account_create":
			var account: Dictionary = command.get("account", {})
			var account_id := str(account.get("id", ""))
			if not _valid_id(account_id) or state.accounts.has(account_id):
				return _error("INVALID_ACCOUNT_ID")
			var asset_kind := str(account.get("asset_kind", "CASH"))
			if not _valid_currency(str(account.get("currency", ""))) or not ["detail", "aggregate"].has(account.get("mode", "")) or not ["FIFO", "MOVING_AVERAGE"].has(account.get("cost_method", "FIFO")) or not ["CASH", "PROVIDENT_FUND", "PENSION"].has(asset_kind) or (asset_kind != "CASH" and account.mode != "detail"):
				return _error("INVALID_ACCOUNT")
			state.accounts[account_id] = account.duplicate(true)
		"instrument_create":
			var instrument: Dictionary = command.get("instrument", {})
			var instrument_id := str(instrument.get("id", ""))
			if not _valid_id(instrument_id) or state.instruments.has(instrument_id) or str(instrument.get("market", "")).is_empty() or str(instrument.get("symbol", "")).is_empty() or not _valid_currency(str(instrument.get("currency", ""))):
				return _error("INVALID_INSTRUMENT")
			state.instruments[instrument_id] = instrument.duplicate(true)
		"other_asset_create":
			if typeof(command.get("asset", null)) != TYPE_DICTIONARY or \
					typeof(command.get("opening_value", null)) != TYPE_DICTIONARY:
				return _error("INVALID_OTHER_ASSET")
			var asset: Dictionary = command.get("asset", {})
			var asset_id := str(asset.get("id", ""))
			var dedup_key := str(asset.get("dedup_key", "")).strip_edges().to_upper()
			if not _valid_id(asset_id) or state.get("other_assets", {}).has(asset_id) or \
					not _valid_other_asset(asset) or \
					not _valid_other_value(command.get("opening_value", {})):
				return _error("INVALID_OTHER_ASSET")
			for existing in state.get("other_assets", {}).values():
				if str(existing.get("dedup_key", "")).to_upper() == dedup_key:
					return _error("DUPLICATE_OTHER_ASSET")
			var cleaned := asset.duplicate(true)
			cleaned.dedup_key = dedup_key
			if not state.has("other_assets"):
				state.other_assets = {}
			state.other_assets[asset_id] = cleaned
			var value: Dictionary = command.opening_value
			_append_event(state, {"id": command_id, "type": "other_asset_value_set",
				"asset_id": asset_id, "amount": Decimal.canonical(str(value.amount)),
				"valuation_basis": str(value.valuation_basis).strip_edges(),
				"effective_at": str(value.effective_at)})
		"other_asset_value_set":
			var asset_id := str(command.get("asset_id", ""))
			if not state.get("other_assets", {}).has(asset_id) or \
					not _valid_other_value(command):
				return _error("INVALID_OTHER_ASSET_VALUE")
			_append_event(state, {"id": command_id, "type": kind,
				"asset_id": asset_id,
				"amount": Decimal.canonical(str(command.amount)),
				"valuation_basis": str(command.valuation_basis).strip_edges(),
				"effective_at": str(command.effective_at)})
		"quote_update":
			var quote: Dictionary = command.get("quote", {})
			var instrument_id := str(quote.get("instrument_id", ""))
			if not state.instruments.has(instrument_id) or not _positive_value(quote.get("price")) or str(quote.get("quoted_at", "")).is_empty() or str(quote.get("source", "")).is_empty():
				return _error("INVALID_QUOTE")
			var existing_quote: Dictionary = state.quotes.get(instrument_id, {})
			quote = quote.duplicate(true)
			quote.price = Decimal.canonical(str(quote.price))
			state.quote_history.append(quote)
			if existing_quote.is_empty() or str(quote.quoted_at) >= str(existing_quote.quoted_at):
				state.quotes[instrument_id] = quote
		"fx_update":
			var fx: Dictionary = command.get("fx", {})
			var currency := str(fx.get("currency", ""))
			if not _valid_currency(currency) or not _positive_value(fx.get("rate_to_base")) or str(fx.get("quoted_at", "")).is_empty() or str(fx.get("source", "")).is_empty():
				return _error("INVALID_FX")
			var old: Dictionary = state.fx_rates.get(currency, {})
			if old.is_empty() or str(fx.quoted_at) >= str(old.quoted_at):
				fx = fx.duplicate(true)
				fx.rate_to_base = Decimal.canonical(str(fx.rate_to_base))
				state.fx_rates[currency] = fx
		"dividend_confirm":
			var suggestion_id := str(command.get("suggestion_event_id", ""))
			var suggestion: Dictionary = {}
			for event in state.events:
				if event.id == suggestion_id and event.type == "dividend_suggest":
					suggestion = event
				elif event.type == "dividend_confirm" and event.suggestion_event_id == suggestion_id:
					return _error("DIVIDEND_ALREADY_CONFIRMED")
			if suggestion.is_empty():
				return _error("DIVIDEND_SUGGESTION_NOT_FOUND")
			if str(command.get("effective_at", "")).is_empty() or str(command.effective_at) < str(suggestion.effective_at):
				return _error("INVALID_DIVIDEND_DATE")
			var gross_value: Variant = command.get("gross_amount")
			var tax_value: Variant = command.get("withholding_tax")
			if typeof(gross_value) != TYPE_STRING or typeof(tax_value) != TYPE_STRING or not _positive(gross_value) or not _nonnegative(tax_value) or Decimal.compare(tax_value, gross_value) > 0:
				return _error("INVALID_DIVIDEND_AMOUNT")
			var net_cash := Decimal.subtract(gross_value, tax_value)
			_append_event(state, {"id": command_id, "type": kind, "account_id": suggestion.account_id, "instrument_id": suggestion.instrument_id, "suggestion_event_id": suggestion_id, "gross_amount": Decimal.canonical(gross_value), "withholding_tax": Decimal.canonical(tax_value), "net_cash": net_cash, "effective_at": str(command.effective_at)})
		"aggregate_replace":
			var old_id := str(command.get("account_id", ""))
			if not state.accounts.has(old_id) or state.accounts[old_id].mode != "aggregate" or \
					str(state.accounts[old_id].get("asset_kind", "CASH")) != "CASH":
				return _error("INVALID_AGGREGATE")
			var before := project(state)
			if not before.ok or before.replaced_accounts.has(old_id):
				return _error("AGGREGATE_ALREADY_REPLACED")
			var entries: Array = command.get("detail_accounts", [])
			if entries.is_empty():
				return _error("DETAILS_REQUIRED")
			var sum := "0"
			for index in entries.size():
				var entry: Dictionary = entries[index]
				var account: Dictionary = entry.get("account", {})
				var account_id := str(account.get("id", ""))
				var amount_value: Variant = entry.get("opening_amount", "0")
				if not _valid_id(account_id) or state.accounts.has(account_id) or account.get("mode", "") != "detail" or account.get("currency", "") != state.accounts[old_id].currency or str(account.get("asset_kind", "CASH")) != "CASH" or not _nonnegative_value(amount_value):
					return _error("INVALID_REPLACEMENT_DETAIL")
				var amount: String = amount_value
				state.accounts[account_id] = account.duplicate(true)
				_append_event(state, {"id": command_id + ":opening:" + str(index), "type": "opening_cash", "account_id": account_id, "amount": Decimal.canonical(amount), "effective_at": str(command.get("effective_at", ""))})
				sum = Decimal.add(sum, amount)
				var holdings: Array = entry.get("opening_positions", [])
				for holding_index in holdings.size():
					var holding: Dictionary = holdings[holding_index]
					var instrument_id := str(holding.get("instrument_id", ""))
					var quantity_value: Variant = holding.get("quantity")
					var price_value: Variant = holding.get("reference_price")
					var cost_value: Variant = holding.get("cost_basis", "")
					if not state.instruments.has(instrument_id) or not _positive_value(quantity_value) or not _positive_value(price_value) or typeof(cost_value) != TYPE_STRING or (not cost_value.is_empty() and not _nonnegative(cost_value)):
						return _error("INVALID_REPLACEMENT_POSITION")
					var quantity: String = quantity_value
					var reference_price: String = price_value
					var cost_basis: String = cost_value
					if state.instruments[instrument_id].currency != account.currency:
						return _error("REPLACEMENT_CURRENCY_MISMATCH")
					_append_event(state, {"id": command_id + ":position:" + str(index) + ":" + str(holding_index), "type": "opening_position", "account_id": account_id, "instrument_id": instrument_id, "quantity": Decimal.canonical(quantity), "reference_price": Decimal.canonical(reference_price), "cost_basis": Decimal.canonical(cost_basis) if not cost_basis.is_empty() else "", "effective_at": str(command.get("effective_at", ""))})
					sum = Decimal.add(sum, Decimal.multiply(quantity, reference_price))
			if Decimal.compare(sum, before.cash[old_id]) != 0:
				return _error("REPLACEMENT_BALANCE_MISMATCH")
			_append_event(state, {"id": command_id, "type": "aggregate_replaced", "account_id": old_id, "effective_at": str(command.get("effective_at", ""))})
		"void_replace":
			var target := str(command.get("target_event_id", ""))
			var found := false
			for event in state.events:
				if event.id == target:
					if event.type != "opening_cash":
						return _error("UNSUPPORTED_REPLACEMENT")
					found = true
				elif event.type == "void" and event.target_event_id == target:
					return _error("ALREADY_VOIDED")
			if not found:
				return _error("EVENT_NOT_FOUND")
			var replacement: Dictionary = command.get("replacement", {})
			if replacement.get("type", "") != "opening_cash":
				return _error("UNSUPPORTED_REPLACEMENT")
			var validate := _validate_cash_event(state, replacement)
			if not validate.ok:
				return validate
			_append_event(state, {"id": command_id, "type": "void", "target_event_id": target, "effective_at": str(command.get("effective_at", ""))})
			_append_event(state, {"id": command_id + ":replacement", "type": "opening_cash", "account_id": replacement.account_id, "amount": Decimal.canonical(str(replacement.amount)), "effective_at": str(replacement.effective_at), "replaces_event_id": target})
		_:
			var validate := _validate_cash_event(state, command)
			if not validate.ok:
				return validate
			var event := command.duplicate(true)
			event.erase("command_id")
			event.id = command_id
			for field in ["amount", "delta", "quantity", "unit_price", "fee", "reference_price", "cost_basis", "gross_amount"]:
				if event.has(field):
					if not str(event[field]).is_empty():
						event[field] = Decimal.canonical(str(event[field]))
			_append_event(state, event)
	return {"ok": true}


static func _validate_cash_event(state: Dictionary, command: Dictionary) -> Dictionary:
	var kind := str(command.get("type", ""))
	var account_id := str(command.get("account_id", ""))
	if not state.accounts.has(account_id) or str(command.get("effective_at", "")).is_empty():
		return _error("ACCOUNT_OR_DATE_MISSING")
	var asset_kind := str(state.accounts[account_id].get("asset_kind", "CASH"))
	if kind == "restricted_balance_set":
		if not ["PROVIDENT_FUND", "PENSION"].has(asset_kind) or \
				not _nonnegative_value(command.get("amount")) or \
				typeof(command.get("source_note", null)) != TYPE_STRING or \
				str(command.source_note).strip_edges().is_empty() or \
				str(command.source_note).length() > 256:
			return _error("INVALID_RESTRICTED_BALANCE")
		return {"ok": true}
	if asset_kind != "CASH":
		return _error("INVALID_ACCOUNT_ASSET_KIND")
	match kind:
		"opening_cash":
			if not _nonnegative_value(command.get("amount")):
				return _error("INVALID_AMOUNT")
		"cash_delta":
			if not _decimal_value(command.get("delta")):
				return _error("INVALID_AMOUNT")
		"transfer":
			var destination := str(command.get("to_account_id", ""))
			if not _positive_value(command.get("amount")) or not state.accounts.has(destination) or destination == account_id or state.accounts[account_id].currency != state.accounts[destination].currency or str(state.accounts[destination].get("asset_kind", "CASH")) != "CASH":
				return _error("INVALID_TRANSFER")
		"buy", "sell":
			var instrument_id := str(command.get("instrument_id", ""))
			if not state.instruments.has(instrument_id) or state.instruments[instrument_id].currency != state.accounts[account_id].currency or not _positive_value(command.get("quantity")) or not _positive_value(command.get("unit_price")) or not _nonnegative_value(command.get("fee")):
				return _error("INVALID_TRADE")
		"opening_position":
			var instrument_id := str(command.get("instrument_id", ""))
			var cost_value: Variant = command.get("cost_basis", "")
			if not state.instruments.has(instrument_id) or state.accounts[account_id].mode != "detail" or state.instruments[instrument_id].currency != state.accounts[account_id].currency or not _positive_value(command.get("quantity")) or not _positive_value(command.get("reference_price")) or typeof(cost_value) != TYPE_STRING or (not cost_value.is_empty() and not _nonnegative(cost_value)):
				return _error("INVALID_OPENING_POSITION")
		"dividend_suggest":
			var instrument_id := str(command.get("instrument_id", ""))
			var gross_value: Variant = command.get("gross_amount")
			if not state.instruments.has(instrument_id) or state.accounts[account_id].mode != "detail" or state.instruments[instrument_id].currency != state.accounts[account_id].currency or typeof(gross_value) != TYPE_STRING or not _positive(gross_value) or typeof(command.get("source")) != TYPE_STRING or str(command.source).is_empty():
				return _error("INVALID_DIVIDEND_SUGGESTION")
		_:
			return _error("UNKNOWN_COMMAND_TYPE")
	return {"ok": true}


static func _consume_cost(position: Dictionary, sold_quantity: String, method: String) -> String:
	if method == "MOVING_AVERAGE":
		return Decimal.divide(Decimal.multiply(position.cost, sold_quantity), position.quantity, 12)
	var remaining := sold_quantity
	var consumed := "0"
	var lots: Array = position.lots
	for lot in lots:
		if remaining == "0":
			break
		if lot.quantity == "0":
			continue
		var take: String = lot.quantity if Decimal.compare(lot.quantity, remaining) <= 0 else remaining
		var lot_cost: String = lot.cost if take == lot.quantity else Decimal.divide(Decimal.multiply(lot.cost, take), lot.quantity, 12)
		lot.quantity = Decimal.subtract(lot.quantity, take)
		lot.cost = Decimal.subtract(lot.cost, lot_cost)
		consumed = Decimal.add(consumed, lot_cost)
		remaining = Decimal.subtract(remaining, take)
	if remaining != "0":
		return ""
	return consumed


static func _to_base(state: Dictionary, amount: String, currency: String) -> String:
	if currency == state.base_currency:
		return amount
	var fx: Dictionary = state.get("fx_rates", {}).get(currency, {})
	if fx.is_empty():
		return ""
	return Decimal.multiply(amount, str(fx.rate_to_base))


static func _append_event(state: Dictionary, event: Dictionary) -> void:
	event.sequence = state.events.size() + 1
	state.events.append(event)


static func _positive(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") > 0


static func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


static func _decimal_value(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and Decimal.is_valid(value)


static func _positive_value(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and _positive(value)


static func _nonnegative_value(value: Variant) -> bool:
	return typeof(value) == TYPE_STRING and _nonnegative(value)


static func _valid_currency(value: String) -> bool:
	return value.length() == 3 and value == value.to_upper()


static func _valid_id(value: String) -> bool:
	return not value.is_empty() and not value.contains("|")


static func _valid_other_asset(asset: Dictionary) -> bool:
	if typeof(asset.get("name", null)) != TYPE_STRING or \
			str(asset.name).strip_edges().is_empty() or str(asset.name).length() > 128 or \
			typeof(asset.get("ownership_scope", null)) != TYPE_STRING or \
			not ["SOLE", "OWNED_SHARE"].has(str(asset.ownership_scope)) or \
			typeof(asset.get("ownership_note", null)) != TYPE_STRING or \
			str(asset.ownership_note).strip_edges().is_empty() or \
			str(asset.ownership_note).length() > 256 or \
			typeof(asset.get("dedup_key", null)) != TYPE_STRING or \
			str(asset.dedup_key).strip_edges().is_empty() or \
			str(asset.dedup_key).length() > 128 or \
			not _valid_currency(str(asset.get("currency", ""))):
		return false
	return true


static func _valid_other_value(value: Dictionary) -> bool:
	return _nonnegative_value(value.get("amount", null)) and \
		typeof(value.get("valuation_basis", null)) == TYPE_STRING and \
		not str(value.valuation_basis).strip_edges().is_empty() and \
		str(value.valuation_basis).length() <= 256 and \
		typeof(value.get("effective_at", null)) == TYPE_STRING and \
		not str(value.effective_at).is_empty()


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
