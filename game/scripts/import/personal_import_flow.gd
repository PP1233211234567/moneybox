extends RefCounted
## Personal CSV workflow. CsvImportService preflights every row; ProjectStore writes
## the whole project with one expected-generation check after explicit confirmation.
## PersonalFlow/UI must honor a nonempty valuation_pending marker as a stale display.

const CsvImport = preload("res://scripts/import/csv_import_service.gd")
const Store = preload("res://scripts/data/project_store.gd")

var _store: RefCounted


func _init(base_path: String = "user://personal/moneybox") -> void:
	_store = Store.new(base_path)


func preview_csv(csv_text: String, mapping: Dictionary) -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var eligibility := _eligibility(loaded)
	if not eligibility.ok:
		return eligibility
	var preview := CsvImport.preview_csv(loaded.state.ledger, csv_text, mapping)
	return {"ok": preview.ok, "error": preview.get("error", ""),
		"generation": int(loaded.generation),
		"source_project_sha256": _project_hash(loaded.state),
		"content_sha256": preview.content_sha256,
		"duplicate": preview.duplicate, "row_count": preview.row_count,
		"row_errors": preview.row_errors.duplicate(true),
		"rows": preview.rows.duplicate(true),
		"resulting_projection": preview.get("resulting_projection", {}).duplicate(true),
		"valuation_pending": loaded.state.get("valuation_pending", {}).duplicate(true),
		"csv_preview": preview}


func confirm_csv(csv_text: String, mapping: Dictionary, preview: Dictionary,
		confirmation: Dictionary) -> Dictionary:
	if confirmation.get("confirmed", false) != true:
		return _error("EXPLICIT_CONFIRMATION_REQUIRED")
	if not preview.get("ok", false) or typeof(preview.get("csv_preview", null)) != TYPE_DICTIONARY or \
			typeof(preview.get("generation", null)) not in [TYPE_INT, TYPE_FLOAT] or \
			int(preview.generation) < 1:
		return _error("VALID_PREVIEW_REQUIRED")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var eligibility := _eligibility(loaded)
	if not eligibility.ok:
		return eligibility
	if int(loaded.generation) != int(preview.generation):
		return _error("GENERATION_CONFLICT")
	if _project_hash(loaded.state) != str(preview.get("source_project_sha256", "")):
		return _error("SOURCE_PROJECT_CHANGED")
	var applied := CsvImport.confirm(loaded.state.ledger, csv_text, mapping,
		preview.csv_preview, confirmation)
	if not applied.ok:
		return applied
	if applied.duplicate:
		return {"ok": true, "duplicate": true, "generation": int(loaded.generation),
			"content_sha256": str(applied.content_sha256),
			"valuation_pending": loaded.state.get("valuation_pending", {}).duplicate(true)}
	var next: Dictionary = loaded.state.duplicate(true)
	next.ledger = applied.state
	next.valuation_pending = {"reason": "CSV_IMPORT",
		"ledger_hash": Store.canonical_ledger_hash(next.ledger)}
	var saved: Dictionary = _store.save_project(next, int(preview.generation))
	if not saved.ok:
		return saved
	return {"ok": true, "duplicate": false, "generation": int(saved.generation),
		"content_sha256": str(applied.content_sha256),
		"batch_id": str(applied.batch_id), "row_count": int(applied.row_count),
		"valuation_pending": next.valuation_pending.duplicate(true),
		"ledger_projection": applied.projection.duplicate(true)}


func _eligibility(loaded: Dictionary) -> Dictionary:
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return _error("PERSONAL_PROJECT_REQUIRED")
	if int(loaded.generation) < 1 or typeof(project.get("ledger", null)) != TYPE_DICTIONARY or \
			project.ledger.get("accounts", {}).is_empty() or \
			project.get("mappings", []).is_empty():
		return _error("PERSONAL_PROJECT_NOT_INITIALIZED")
	return {"ok": true}


func _project_hash(project: Dictionary) -> String:
	return JSON.stringify(project).sha256_text()


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
