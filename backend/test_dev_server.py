"""Real loopback HTTP checks for the development-only transport stub."""

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import http.client
import io
import json
from pathlib import Path
import threading
import unittest

from backend.dev_server import create_server


QUOTE_REQUEST = {
    "schema_version": 1,
    "request_id": "request.quote.1",
    "idempotency_key": "quote-test-1",
    "identities": [{
        "kind": "ETF", "market": "ARCA", "symbol": "VOO", "currency": "USD", "share_class": ""
    }],
}
DRAFT_REQUEST = {
    "schema_version": 1,
    "request_id": "request.draft.1",
    "idempotency_key": "draft-test-1",
    "locale": "zh-CN",
    "timezone": "Asia/Shanghai",
    "input_text": "今天用3001美元买了5股VOO，其中手续费1美元",
    "candidate_account_ids": ["acct_a1"],
    "candidate_instrument_ids": ["inst_i1"],
}


class DevServerHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = create_server(0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.port = cls.server.server_port

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=3)

    def request_json(self, method: str, path: str, payload: object | None = None,
                     content_type: str = "application/json") -> tuple[int, dict]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            body = None if payload is None else json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers = {} if body is None else {"Content-Type": content_type}
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read()
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertEqual(response.getheader("Connection"), "close")
            return response.status, json.loads(raw)
        finally:
            connection.close()

    def raw_post(self, path: str, headers: list[tuple[str, str]],
                 body: bytes = b"") -> tuple[int, dict]:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.putrequest("POST", path)
            for name, value in headers:
                connection.putheader(name, value)
            connection.endheaders()
            if body:
                connection.send(body)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def assert_error(self, result: tuple[int, dict], status: int, code: str) -> None:
        actual_status, body = result
        self.assertEqual(actual_status, status)
        self.assertEqual(body, {"schema_version": 1, "error": {"code": code}})

    def test_loopback_health_and_capabilities(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        status, health = self.request_json("GET", "/v1/health")
        self.assertEqual(status, 200)
        self.assertEqual(health, {"schema_version": 1, "status": "ok",
                                  "environment": "development", "production_ready": False})
        status, capabilities = self.request_json("GET", "/v1/capabilities")
        self.assertEqual(status, 200)
        self.assertTrue(all(value is False for name, value in capabilities.items()
                            if name.endswith("_configured") or name == "production_ready"))

    def test_valid_minimal_requests_return_stable_unconfigured_errors(self) -> None:
        self.assert_error(self.request_json("POST", "/v1/quote-batches", QUOTE_REQUEST),
                          503, "PROVIDER_NOT_CONFIGURED")
        self.assert_error(self.request_json("POST", "/v1/trade-drafts", DRAFT_REQUEST),
                          503, "AI_NOT_CONFIGURED")
        self.assert_error(self.request_json("POST", "/v1/quote-batches", QUOTE_REQUEST),
                          503, "PROVIDER_NOT_CONFIGURED")

    def test_extra_financial_data_is_rejected_and_never_echoed(self) -> None:
        quote = dict(QUOTE_REQUEST, asset_total="999999.99", ledger={"events": []})
        status, body = self.request_json("POST", "/v1/quote-batches", quote)
        self.assert_error((status, body), 400, "INVALID_REQUEST")
        self.assertNotIn("999999", json.dumps(body))
        draft = dict(DRAFT_REQUEST, account_number="1234567890123456", portfolio={})
        self.assert_error(self.request_json("POST", "/v1/trade-drafts", draft),
                          400, "INVALID_REQUEST")
        private_sentence = dict(DRAFT_REQUEST, input_text="账号1234567890123456买入VOO")
        self.assert_error(self.request_json("POST", "/v1/trade-drafts", private_sentence),
                          400, "INVALID_REQUEST")
        real_candidate = dict(DRAFT_REQUEST, candidate_account_ids=["1234567890123456"])
        self.assert_error(self.request_json("POST", "/v1/trade-drafts", real_candidate),
                          400, "INVALID_REQUEST")

    def test_no_request_text_in_response_or_standard_log(self) -> None:
        sentence = DRAFT_REQUEST["input_text"]
        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            status, body = self.request_json("POST", "/v1/trade-drafts", DRAFT_REQUEST)
        self.assertEqual(status, 503)
        self.assertNotIn(sentence, json.dumps(body, ensure_ascii=False))
        self.assertNotIn(sentence, stdout.getvalue())
        self.assertNotIn(sentence, stderr.getvalue())

    def test_length_media_type_and_transfer_framing(self) -> None:
        self.assert_error(self.raw_post("/v1/quote-batches", [("Content-Type", "application/json")]),
                          411, "CONTENT_LENGTH_REQUIRED")
        self.assert_error(self.raw_post("/v1/quote-batches", [
            ("Content-Type", "application/json"), ("Content-Length", "4097")
        ]), 413, "REQUEST_TOO_LARGE")
        self.assert_error(self.raw_post("/v1/trade-drafts", [
            ("Content-Type", "application/json"), ("Content-Length", "2049")
        ]), 413, "REQUEST_TOO_LARGE")
        self.assert_error(self.raw_post("/v1/quote-batches", [
            ("Content-Type", "application/json"), ("Content-Length", "2"),
            ("Content-Length", "2")
        ], b"{}"), 400, "INVALID_CONTENT_LENGTH")
        self.assert_error(self.raw_post("/v1/quote-batches", [
            ("Content-Type", "application/json"), ("Content-Length", "9" * 5000)
        ]), 400, "INVALID_CONTENT_LENGTH")
        self.assert_error(self.raw_post("/v1/quote-batches", [
            ("Content-Type", "application/json"), ("Transfer-Encoding", "chunked")
        ]), 400, "UNSUPPORTED_TRANSFER_ENCODING")
        self.assert_error(self.request_json("POST", "/v1/quote-batches", QUOTE_REQUEST,
                                            "text/plain"), 415, "UNSUPPORTED_MEDIA_TYPE")

    def test_version_idempotency_and_duplicate_json_keys(self) -> None:
        future = dict(QUOTE_REQUEST, schema_version=2)
        self.assert_error(self.request_json("POST", "/v1/quote-batches", future),
                          426, "UNSUPPORTED_SCHEMA_VERSION")
        no_key = dict(QUOTE_REQUEST, idempotency_key="")
        self.assert_error(self.request_json("POST", "/v1/quote-batches", no_key),
                          400, "INVALID_IDEMPOTENCY_KEY")
        duplicate_key_json = b'{"schema_version":1,"schema_version":1,"request_id":"r","idempotency_key":"k","identities":[]}'
        self.assert_error(self.raw_post("/v1/quote-batches", [
            ("Content-Type", "application/json"),
            ("Content-Length", str(len(duplicate_key_json)))
        ], duplicate_key_json), 400, "INVALID_REQUEST")

    def test_routes_and_openapi_contract(self) -> None:
        self.assert_error(self.request_json("GET", "/v1/health?input=private"),
                          400, "QUERY_NOT_ALLOWED")
        self.assert_error(self.request_json("GET", "/not-a-route"),
                          404, "ROUTE_NOT_FOUND")
        self.assert_error(self.request_json("POST", "/v1/health", {}),
                          405, "METHOD_NOT_ALLOWED")
        contract_path = Path(__file__).resolve().parents[1] / "contracts" / "openapi" / "dev_backend_v1.openapi.json"
        contract = json.loads(contract_path.read_text(encoding="utf-8"))
        self.assertEqual(contract["openapi"], "3.1.0")
        self.assertTrue(contract["x-development-only"])
        self.assertEqual(set(contract["paths"]), {
            "/v1/health", "/v1/capabilities", "/v1/quote-batches", "/v1/trade-drafts"
        })


if __name__ == "__main__":
    unittest.main()
