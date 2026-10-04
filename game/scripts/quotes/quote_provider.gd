extends RefCounted
## Adapter boundary. A production provider must implement this contract via BackendApi.
## Only normalized identities reach a provider: never holdings, account IDs, or amounts.


func fetch_quotes(_identities: Array, _now_at: String) -> Dictionary:
	return {"ok": false, "provider_version": "unconfigured", "error": "PROVIDER_NOT_CONFIGURED"}
