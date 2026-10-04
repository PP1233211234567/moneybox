"""Loopback-only B0 transport stub. No provider, AI model, auth, or persistence."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
from typing import Any
from urllib.parse import urlsplit


API_VERSION = 1
LOOPBACK_HOST = "127.0.0.1"
QUOTE_BODY_LIMIT = 4096
DRAFT_BODY_LIMIT = 2048
TOKEN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$", re.ASCII)
MARKET_TOKEN = re.compile(r"^[A-Z0-9._:/-]{1,32}$", re.ASCII)
CURRENCY = re.compile(r"^[A-Z]{3}$", re.ASCII)
ACCOUNT_ALIAS = re.compile(r"^acct_[A-Za-z0-9_-]{1,16}$", re.ASCII)
INSTRUMENT_ALIAS = re.compile(r"^inst_[A-Za-z0-9_-]{1,16}$", re.ASCII)
OBVIOUS_PRIVATE_TEXT = re.compile(
    r"(?:账户号码|账号|银行卡|卡号|总资产|资产总额|净资产|持仓总额|账户余额|\d{8,})"
)


class RequestProblem(Exception):
    def __init__(self, status: int, code: str) -> None:
        super().__init__(code)
        self.status = status
        self.code = code


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_value: str) -> Any:
    raise ValueError("non-JSON numeric constant")


def _common_request(payload: dict[str, Any], expected_keys: set[str]) -> None:
    if set(payload) != expected_keys:
        raise RequestProblem(400, "INVALID_REQUEST")
    version = payload.get("schema_version")
    if type(version) is not int:
        raise RequestProblem(400, "INVALID_REQUEST")
    if version != API_VERSION:
        raise RequestProblem(426, "UNSUPPORTED_SCHEMA_VERSION")
    if not isinstance(payload.get("request_id"), str) or not TOKEN.fullmatch(payload["request_id"]):
        raise RequestProblem(400, "INVALID_REQUEST_ID")
    if not isinstance(payload.get("idempotency_key"), str) or not TOKEN.fullmatch(
        payload["idempotency_key"]
    ):
        raise RequestProblem(400, "INVALID_IDEMPOTENCY_KEY")


def _validate_quote_request(payload: dict[str, Any]) -> None:
    _common_request(payload, {"schema_version", "request_id", "idempotency_key", "identities"})
    identities = payload["identities"]
    if not isinstance(identities, list) or not 1 <= len(identities) <= 20:
        raise RequestProblem(400, "INVALID_REQUEST")
    seen: set[tuple[str, str, str, str, str]] = set()
    for identity in identities:
        if not isinstance(identity, dict) or set(identity) != {
            "kind", "market", "symbol", "currency", "share_class"
        }:
            raise RequestProblem(400, "INVALID_REQUEST")
        if any(not isinstance(value, str) for value in identity.values()):
            raise RequestProblem(400, "INVALID_REQUEST")
        kind = identity["kind"]
        market = identity["market"]
        symbol = identity["symbol"]
        currency = identity["currency"]
        share_class = identity["share_class"]
        if kind not in {"STOCK", "ETF", "FUND", "FX", "GOLD"} \
                or not MARKET_TOKEN.fullmatch(market) \
                or not MARKET_TOKEN.fullmatch(symbol) \
                or not CURRENCY.fullmatch(currency) \
                or (share_class and not MARKET_TOKEN.fullmatch(share_class)):
            raise RequestProblem(400, "INVALID_REQUEST")
        if kind == "FX":
            parts = symbol.split("/")
            if market != "FX" or len(parts) != 2 or not all(CURRENCY.fullmatch(p) for p in parts) \
                    or parts[1] != currency or parts[0] == currency or share_class:
                raise RequestProblem(400, "INVALID_REQUEST")
        if kind == "GOLD" and (market != "SPOT" or symbol != "XAU" or share_class):
            raise RequestProblem(400, "INVALID_REQUEST")
        key = (kind, market, symbol, currency, share_class)
        if key in seen:
            raise RequestProblem(400, "INVALID_REQUEST")
        seen.add(key)


def _validate_draft_request(payload: dict[str, Any]) -> None:
    _common_request(payload, {
        "schema_version", "request_id", "idempotency_key", "locale", "timezone",
        "input_text", "candidate_account_ids", "candidate_instrument_ids"
    })
    if not isinstance(payload["locale"], str) or payload["locale"] not in {"zh-CN", "en-US"} \
            or not isinstance(payload["timezone"], str) or payload["timezone"] != "Asia/Shanghai":
        raise RequestProblem(400, "INVALID_REQUEST")
    text = payload["input_text"]
    if not isinstance(text, str) or not 1 <= len(text) <= 500 \
            or any(ord(character) < 32 and character not in "\t\n" for character in text) \
            or OBVIOUS_PRIVATE_TEXT.search(text):
        raise RequestProblem(400, "INVALID_REQUEST")
    for key, pattern in (
        ("candidate_account_ids", ACCOUNT_ALIAS),
        ("candidate_instrument_ids", INSTRUMENT_ALIAS),
    ):
        aliases = payload[key]
        if not isinstance(aliases, list) or len(aliases) > 16 \
                or any(not isinstance(alias, str) or not pattern.fullmatch(alias) for alias in aliases) \
                or len(set(aliases)) != len(aliases):
            raise RequestProblem(400, "INVALID_REQUEST")


class _LoopbackServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class DevHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "MoneyboxDev/0.1"
    sys_version = ""

    def setup(self) -> None:
        self.request.settimeout(3)
        super().setup()

    def log_message(self, _format: str, *args: Any) -> None:
        # The path or body can contain financial text. This stub emits no request logs.
        return

    def send_error(self, code: int, _message: str | None = None,
                   _explain: str | None = None) -> None:
        # BaseHTTPRequestHandler's default HTML error may include request text.
        self._error(code, "INVALID_REQUEST")

    def _reply(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status: int, code: str) -> None:
        self._reply(status, {"schema_version": API_VERSION, "error": {"code": code}})

    def _route(self) -> str:
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            raise RequestProblem(400, "QUERY_NOT_ALLOWED")
        return parsed.path

    def _json_body(self, limit: int) -> dict[str, Any]:
        if self.headers.get("Transfer-Encoding") is not None:
            raise RequestProblem(400, "UNSUPPORTED_TRANSFER_ENCODING")
        lengths = self.headers.get_all("Content-Length", [])
        if not lengths:
            raise RequestProblem(411, "CONTENT_LENGTH_REQUIRED")
        if len(lengths) != 1 or len(lengths[0]) > 10 \
                or not re.fullmatch(r"[0-9]+", lengths[0], re.ASCII):
            raise RequestProblem(400, "INVALID_CONTENT_LENGTH")
        length = int(lengths[0])
        if length > limit:
            raise RequestProblem(413, "REQUEST_TOO_LARGE")
        if length == 0:
            raise RequestProblem(400, "INVALID_REQUEST")
        media_types = self.headers.get_all("Content-Type", [])
        if len(media_types) != 1 or media_types[0].lower().strip() not in {
            "application/json", "application/json; charset=utf-8"
        }:
            raise RequestProblem(415, "UNSUPPORTED_MEDIA_TYPE")
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise RequestProblem(400, "INVALID_REQUEST")
            payload = json.loads(
                raw.decode("utf-8", errors="strict"),
                object_pairs_hook=_unique_object,
                parse_constant=_reject_constant,
            )
        except (UnicodeDecodeError, ValueError, TimeoutError, OSError):
            raise RequestProblem(400, "INVALID_REQUEST") from None
        if not isinstance(payload, dict):
            raise RequestProblem(400, "INVALID_REQUEST")
        return payload

    def do_GET(self) -> None:
        try:
            path = self._route()
            if self.headers.get("Content-Length") not in (None, "0"):
                raise RequestProblem(400, "BODY_NOT_ALLOWED")
            if path == "/v1/health":
                self._reply(200, {"schema_version": API_VERSION, "status": "ok",
                                  "environment": "development", "production_ready": False})
            elif path == "/v1/capabilities":
                self._reply(200, {"schema_version": API_VERSION, "environment": "development",
                                  "quotes_configured": False, "ai_configured": False,
                                  "purchases_configured": False, "authentication_configured": False,
                                  "persistent_storage_configured": False,
                                  "production_ready": False})
            else:
                self._error(404, "ROUTE_NOT_FOUND")
        except RequestProblem as problem:
            self._error(problem.status, problem.code)

    def do_POST(self) -> None:
        try:
            path = self._route()
            if path == "/v1/quote-batches":
                payload = self._json_body(QUOTE_BODY_LIMIT)
                _validate_quote_request(payload)
                self._error(503, "PROVIDER_NOT_CONFIGURED")
            elif path == "/v1/trade-drafts":
                payload = self._json_body(DRAFT_BODY_LIMIT)
                _validate_draft_request(payload)
                self._error(503, "AI_NOT_CONFIGURED")
            elif path in {"/v1/health", "/v1/capabilities"}:
                self._error(405, "METHOD_NOT_ALLOWED")
            else:
                self._error(404, "ROUTE_NOT_FOUND")
        except RequestProblem as problem:
            self._error(problem.status, problem.code)

    def do_PUT(self) -> None:
        self._error(405, "METHOD_NOT_ALLOWED")

    def do_PATCH(self) -> None:
        self._error(405, "METHOD_NOT_ALLOWED")

    def do_DELETE(self) -> None:
        self._error(405, "METHOD_NOT_ALLOWED")

    def do_OPTIONS(self) -> None:
        self._error(405, "METHOD_NOT_ALLOWED")


def create_server(port: int = 8765) -> ThreadingHTTPServer:
    """Bind only loopback. The host cannot be overridden by callers or CLI flags."""
    if not 0 <= port <= 65535:
        raise ValueError("port outside valid range")
    return _LoopbackServer((LOOPBACK_HOST, port), DevHandler)


def main() -> None:
    parser = argparse.ArgumentParser(description="Moneybox development-only loopback API")
    parser.add_argument("--port", type=int, default=8765)
    options = parser.parse_args()
    with create_server(options.port) as server:
        print(f"Moneybox development API on {LOOPBACK_HOST}:{server.server_port}; no providers configured")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
