extends RefCounted
## Local CSV import preflight for the LedgerCore event subset. The caller persists the
## returned ledger only after a successful, explicitly confirmed whole batch.

const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const FORMAT_VERSION := 1
const MAX_BYTES := 8 * 1024 * 1024
const MAX_ROWS := 10000
const FIELDS := ["type", "account", "to_account", "instrument", "effective_at",
	"amount", "delta", "quantity", "unit_price", "fee", "reference_price",
	"cost_basis", "external", "currency", "tax_amount", "total_amount", "amount_basis"]
const EVENT_TYPES := ["opening_cash", "cash_delta", "transfer", "buy", "sell", "opening_position"]


static func preview_csv(state: Dictionary, csv_text: String, mapping: Dictionary) -> Dictionary:
	var checked := _preflight(state, csv_text, mapping)
	checked.erase("proposed_state")
	return checked


static func confirm(state: Dictionary, csv_text: String, mapping: Dictionary,
		preview: Dictionary, confirmation: Dictionary) -> Dictionary:
	if confirmation.get("confirmed", false) != true:
		return {"ok": false, "error": "EXPLICIT_CONFIRMATION_REQUIRED"}
	if int(preview.get("format_version", -1)) != FORMAT_VERSION or not preview.get("ok", false):
		return {"ok": false, "error": "VALID_PREVIEW_REQUIRED"}
	var content_hash := csv_text.sha256_text()
	if str(confirmation.get("content_sha256", "")) != content_hash or \
			str(preview.get("content_sha256", "")) != content_hash:
		return {"ok": false, "error": "CSV_CHANGED"}
	if str(preview.get("source_state_sha256", "")) != _state_hash(state):
		return {"ok": false, "error": "CURRENT_STATE_CHANGED"}
	if str(preview.get("mapping_sha256", "")) != _mapping_hash(mapping):
		return {"ok": false, "error": "MAPPING_CHANGED"}
	var checked := _preflight(state, csv_text, mapping)
	if not checked.ok:
		return checked
	if checked.duplicate:
		return {"ok": true, "duplicate": true, "state": state,
			"projection": Ledger.project(state), "content_sha256": content_hash}
	if checked.row_count != preview.row_count or \
			checked.preview_sha256 != preview.get("preview_sha256", ""):
		return {"ok": false, "error": "PREVIEW_CHANGED"}
	var committed: Dictionary = checked.proposed_state
	var batches: Dictionary = committed.get("import_batches", {}).duplicate(true)
	batches[content_hash] = {"batch_id": "csv-" + content_hash,
		"content_sha256": content_hash, "mapping_sha256": checked.mapping_sha256,
		"row_count": checked.row_count, "format_version": FORMAT_VERSION}
	committed["import_batches"] = batches
	return {"ok": true, "duplicate": false, "state": committed,
		"projection": checked.resulting_projection, "content_sha256": content_hash,
		"batch_id": "csv-" + content_hash, "row_count": checked.row_count}


static func _preflight(state: Dictionary, csv_text: String, mapping: Dictionary) -> Dictionary:
	var content_hash := csv_text.sha256_text()
	var base := {"format_version": FORMAT_VERSION, "content_sha256": content_hash,
		"mapping_sha256": _mapping_hash(mapping), "source_state_sha256": _state_hash(state),
		"row_count": 0, "rows": [], "row_errors": [], "duplicate": false}
	if csv_text.is_empty() or csv_text.to_utf8_buffer().size() > MAX_BYTES:
		return _fail(base, "CSV_SIZE_INVALID", 0, 0)
	var imported: Dictionary = state.get("import_batches", {})
	if imported.has(content_hash):
		base.ok = true
		base.duplicate = true
		base.row_count = int(imported[content_hash].get("row_count", 0))
		base.resulting_projection = Ledger.project(state)
		base.preview_sha256 = _preview_hash(base)
		return base
	var mapping_error := _mapping_error(state, mapping)
	if not mapping_error.is_empty():
		return _fail(base, mapping_error, 0, 0)
	var parsed := _parse_csv(csv_text)
	if not parsed.ok:
		return _fail(base, str(parsed.error), int(parsed.get("line", 0)), 0)
	var records: Array = parsed.rows
	if records.size() < 2:
		return _fail(base, "CSV_DATA_ROWS_REQUIRED", 0, 0)
	if records.size() - 1 > MAX_ROWS:
		return _fail(base, "CSV_ROW_LIMIT", 0, 0)
	var header: Array = records[0].fields.duplicate()
	header[0] = str(header[0]).trim_prefix("\uFEFF")
	var columns := {}
	for index in header.size():
		var name := str(header[index])
		if name.is_empty() or columns.has(name):
			return _fail(base, "CSV_HEADER_INVALID", int(records[0].line), 0)
		columns[name] = index
	var indices := {}
	for canonical in mapping.column_map:
		var source: String = mapping.column_map[canonical]
		if not columns.has(source):
			return _fail(base, "MAPPED_COLUMN_MISSING", int(records[0].line), 0)
		indices[canonical] = columns[source]
	base.row_count = records.size() - 1
	var commands: Array[Dictionary] = []
	for record_index in range(1, records.size()):
		var record: Dictionary = records[record_index]
		var row_number := record_index
		if record.fields.size() != header.size():
			base.row_errors.append({"line": int(record.line), "row": row_number,
				"code": "CSV_COLUMN_COUNT_MISMATCH"})
			continue
		var converted := _row_to_command(state, record.fields, indices, mapping,
			content_hash, row_number)
		if not converted.ok:
			base.row_errors.append({"line": int(record.line), "row": row_number,
				"code": converted.error, "field": converted.get("field", "")})
			continue
		commands.append({"line": int(record.line), "row": row_number, "command": converted.command})
		base.rows.append({"line": int(record.line), "row": row_number,
			"command": converted.command.duplicate(true)})
	if not base.row_errors.is_empty():
		base.ok = false
		base.error = "ROW_VALIDATION_FAILED"
		return base
	var simulated := state.duplicate(true)
	for item in commands:
		var result := Ledger.apply(simulated, item.command)
		if not result.ok:
			base.row_errors.append({"line": item.line, "row": item.row,
				"code": str(result.error)})
		elif result.duplicate:
			# A row ID without its batch marker indicates an incomplete or foreign import.
			base.row_errors.append({"line": item.line, "row": item.row,
				"code": "PREEXISTING_ROW_COMMAND_ID"})
		else:
			simulated = result.state
	if not base.row_errors.is_empty():
		base.ok = false
		base.error = "ROW_VALIDATION_FAILED"
		return base
	base.ok = true
	base.resulting_projection = Ledger.project(simulated)
	base.preview_sha256 = _preview_hash(base)
	base.proposed_state = simulated
	return base


static func _mapping_error(state: Dictionary, mapping: Dictionary) -> String:
	if typeof(mapping.get("column_map", null)) != TYPE_DICTIONARY or \
			typeof(mapping.get("account_ids", null)) != TYPE_DICTIONARY or \
			typeof(mapping.get("instrument_ids", null)) != TYPE_DICTIONARY:
		return "EXPLICIT_ID_AND_COLUMN_MAPPING_REQUIRED"
	var column_map: Dictionary = mapping.column_map
	for field in ["type", "account", "effective_at"]:
		if not column_map.has(field):
			return "REQUIRED_COLUMN_MAPPING_MISSING"
	var used := {}
	for field in column_map:
		if typeof(field) != TYPE_STRING or not FIELDS.has(field) or \
				typeof(column_map[field]) != TYPE_STRING or str(column_map[field]).is_empty():
			return "INVALID_COLUMN_MAPPING"
		if used.has(column_map[field]):
			return "DUPLICATE_COLUMN_MAPPING"
		used[column_map[field]] = true
	for alias in mapping.account_ids:
		if typeof(alias) != TYPE_STRING or alias.is_empty() or \
				typeof(mapping.account_ids[alias]) != TYPE_STRING or \
				not state.get("accounts", {}).has(mapping.account_ids[alias]):
			return "INVALID_ACCOUNT_ID_MAPPING"
	for alias in mapping.instrument_ids:
		if typeof(alias) != TYPE_STRING or alias.is_empty() or \
				typeof(mapping.instrument_ids[alias]) != TYPE_STRING or \
				not state.get("instruments", {}).has(mapping.instrument_ids[alias]):
			return "INVALID_INSTRUMENT_ID_MAPPING"
	return ""


static func _row_to_command(state: Dictionary, cells: Array, indices: Dictionary,
		mapping: Dictionary, content_hash: String, row_number: int) -> Dictionary:
	var kind := _cell(cells, indices, "type")
	if not EVENT_TYPES.has(kind):
		return _row_error("UNSUPPORTED_EVENT_TYPE", "type")
	var allowed := ["type", "account", "effective_at", "currency", "tax_amount"]
	match kind:
		"opening_cash": allowed.append("amount")
		"cash_delta": allowed.append_array(["delta", "external"])
		"transfer": allowed.append_array(["to_account", "amount"])
		"buy", "sell": allowed.append_array(["instrument", "quantity", "unit_price",
			"fee", "total_amount", "amount_basis"])
		"opening_position": allowed.append_array(["instrument", "quantity",
			"reference_price", "cost_basis"])
	for field in indices:
		if not allowed.has(field) and not _cell(cells, indices, field).is_empty():
			return _row_error("UNSUPPORTED_FIELD_FOR_TYPE", field)
	var source_account := _cell(cells, indices, "account")
	if not mapping.account_ids.has(source_account):
		return _row_error("ACCOUNT_MAPPING_REQUIRED", "account")
	var account_id: String = mapping.account_ids[source_account]
	var effective_at := _cell(cells, indices, "effective_at")
	if not _valid_utc_timestamp(effective_at):
		return _row_error("INVALID_EFFECTIVE_AT", "effective_at")
	var command := {"command_id": "csv-" + content_hash + "-" + str(row_number),
		"type": kind, "account_id": account_id, "effective_at": effective_at}
	var currency := _cell(cells, indices, "currency")
	if not currency.is_empty() and currency != str(state.accounts[account_id].currency):
		return _row_error("ACCOUNT_CURRENCY_MISMATCH", "currency")
	var tax := _cell(cells, indices, "tax_amount")
	if not tax.is_empty() and (not Decimal.is_valid(tax) or Decimal.compare(tax, "0") != 0):
		return _row_error("UNSUPPORTED_TAX_LEDGER", "tax_amount")
	var needed := []
	match kind:
		"opening_cash", "transfer": needed = ["amount"]
		"cash_delta": needed = ["delta", "external"]
		"buy", "sell": needed = ["instrument", "quantity", "unit_price", "fee", "tax_amount"]
		"opening_position": needed = ["instrument", "quantity", "reference_price"]
	for field in needed:
		if _cell(cells, indices, field).is_empty():
			return _row_error("REQUIRED_FIELD_MISSING", field)
	if kind == "transfer":
		var destination := _cell(cells, indices, "to_account")
		if not mapping.account_ids.has(destination):
			return _row_error("DESTINATION_MAPPING_REQUIRED", "to_account")
		command.to_account_id = mapping.account_ids[destination]
	if kind in ["buy", "sell", "opening_position"]:
		var source_instrument := _cell(cells, indices, "instrument")
		if not mapping.instrument_ids.has(source_instrument):
			return _row_error("INSTRUMENT_MAPPING_REQUIRED", "instrument")
		command.instrument_id = mapping.instrument_ids[source_instrument]
		if not currency.is_empty() and currency != str(state.instruments[command.instrument_id].currency):
			return _row_error("INSTRUMENT_CURRENCY_MISMATCH", "currency")
	for field in ["amount", "delta", "quantity", "unit_price", "fee", "reference_price", "cost_basis"]:
		if allowed.has(field):
			var value := _cell(cells, indices, field)
			if not value.is_empty():
				if not Decimal.is_valid(value):
					return _row_error("INVALID_DECIMAL", field)
				command[field] = Decimal.canonical(value)
	if kind == "opening_position" and not command.has("cost_basis"):
		command.cost_basis = ""
	if kind == "cash_delta":
		var external := _cell(cells, indices, "external")
		if external not in ["true", "false"]:
			return _row_error("INVALID_EXTERNAL_FLAG", "external")
		command.external = external == "true"
	if kind in ["buy", "sell"]:
		var total := _cell(cells, indices, "total_amount")
		var basis := _cell(cells, indices, "amount_basis")
		if not total.is_empty():
			if not Decimal.is_valid(total) or basis not in ["gross_trade", "cash_flow"]:
				return _row_error("INVALID_TRADE_TOTAL", "total_amount")
			var gross := Decimal.multiply(str(command.quantity), str(command.unit_price))
			var expected := gross
			if basis == "cash_flow":
				expected = Decimal.add(gross, str(command.fee)) if kind == "buy" else \
					Decimal.subtract(gross, str(command.fee))
			if Decimal.compare(total, expected) != 0:
				return _row_error("AMOUNT_EQUATION_MISMATCH", "total_amount")
		elif not basis.is_empty():
			return _row_error("AMOUNT_BASIS_WITHOUT_TOTAL", "amount_basis")
	return {"ok": true, "command": command}


static func _parse_csv(csv_text: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	var fields: Array[String] = []
	var value := ""
	var in_quotes := false
	var quote_closed := false
	var line := 1
	var row_line := 1
	var index := 0
	while index < csv_text.length():
		var character := csv_text.substr(index, 1)
		if character == '"':
			if in_quotes:
				if index + 1 < csv_text.length() and csv_text.substr(index + 1, 1) == '"':
					value += '"'
					index += 1
				else:
					in_quotes = false
					quote_closed = true
			elif value.is_empty() and not quote_closed:
				in_quotes = true
			else:
				return {"ok": false, "error": "CSV_QUOTE_INVALID", "line": line}
		elif character == "," and not in_quotes:
			fields.append(value)
			value = ""
			quote_closed = false
		elif character == "\r" or character == "\n":
			if character == "\r":
				if index + 1 >= csv_text.length() or csv_text.substr(index + 1, 1) != "\n":
					return {"ok": false, "error": "CSV_LINE_ENDING_INVALID", "line": line}
				index += 1
			if in_quotes:
				value += "\n"
			else:
				fields.append(value)
				rows.append({"line": row_line, "fields": fields})
				if rows.size() > MAX_ROWS + 1:
					return {"ok": false, "error": "CSV_ROW_LIMIT", "line": line}
				fields = []
				value = ""
				quote_closed = false
			line += 1
			row_line = line if not in_quotes else row_line
		else:
			if quote_closed:
				return {"ok": false, "error": "CSV_QUOTE_INVALID", "line": line}
			value += character
		index += 1
	if in_quotes:
		return {"ok": false, "error": "CSV_QUOTE_UNCLOSED", "line": line}
	if not fields.is_empty() or not value.is_empty() or quote_closed:
		fields.append(value)
		rows.append({"line": row_line, "fields": fields})
		if rows.size() > MAX_ROWS + 1:
			return {"ok": false, "error": "CSV_ROW_LIMIT", "line": line}
	return {"ok": true, "rows": rows}


static func _valid_utc_timestamp(value: String) -> bool:
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-" or \
			value.substr(10, 1) != "T" or value.substr(13, 1) != ":" or \
			value.substr(16, 1) != ":" or value.substr(19, 1) != "Z":
		return false
	for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
		var digit := value.substr(index, 1)
		if digit < "0" or digit > "9":
			return false
	var year := int(value.substr(0, 4))
	var month := int(value.substr(5, 2))
	var day := int(value.substr(8, 2))
	var hour := int(value.substr(11, 2))
	var minute := int(value.substr(14, 2))
	var second := int(value.substr(17, 2))
	if year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59:
		return false
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
		return day >= 1 and day <= 29
	return day >= 1 and day <= days[month - 1]


static func _cell(cells: Array, indices: Dictionary, field: String) -> String:
	return str(cells[int(indices[field])]) if indices.has(field) else ""


static func _row_error(code: String, field: String) -> Dictionary:
	return {"ok": false, "error": code, "field": field}


static func _fail(base: Dictionary, code: String, line: int, row: int) -> Dictionary:
	base.ok = false
	base.error = code
	base.row_errors.append({"line": line, "row": row, "code": code})
	return base


static func _state_hash(state: Dictionary) -> String:
	return JSON.stringify(state).sha256_text()


static func _mapping_hash(mapping: Dictionary) -> String:
	return JSON.stringify(mapping).sha256_text()


static func _preview_hash(preview: Dictionary) -> String:
	return JSON.stringify({"content_sha256": preview.content_sha256,
		"mapping_sha256": preview.mapping_sha256, "source_state_sha256": preview.source_state_sha256,
		"row_count": preview.row_count, "rows": preview.rows,
		"resulting_projection": preview.resulting_projection}).sha256_text()
