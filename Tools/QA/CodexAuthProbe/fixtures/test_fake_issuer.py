"""Local self-tests for the fake issuer only; never invoke Rust or Keychain."""
import base64
import json
import time
from pathlib import Path
import socket
import sys
import unittest
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener
from urllib.error import HTTPError

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_issuer import (CLIENT_ID, OFFICIAL_CLIENT_ID, EXCHANGE, POLL, REVOKE,
                         RESPONSES, TRANSLATION_INSTRUCTIONS, USERCODE, FakeIssuer)


class FixtureTests(unittest.TestCase):
    def request(self, issuer, path, body, *, form=False, headers=None):
        data = urlencode(body).encode() if form else json.dumps(body).encode()
        request = Request(issuer.issuer + path, data=data, headers={
            "Content-Type": "application/x-www-form-urlencoded" if form else "application/json",
            **(headers or {})})
        try:
            response = build_opener(ProxyHandler({})).open(request, timeout=2)
        except HTTPError as error:
            response = error
        with response:
            return response.status, response.read()

    def device(self, issuer):
        status, body = self.request(issuer, USERCODE, {"client_id": CLIENT_ID})
        self.assertEqual(status, 200)
        return json.loads(body)

    def login(self, issuer):
        code = self.device(issuer)
        status, body = self.request(issuer, POLL, {
            "device_auth_id": code["device_auth_id"], "user_code": code["user_code"]})
        self.assertEqual(status, 200)
        grant = json.loads(body)
        status, body = self.request(issuer, EXCHANGE, {
            "grant_type": "authorization_code", "client_id": CLIENT_ID,
            "code": grant["authorization_code"], "code_verifier": grant["code_verifier"],
            "redirect_uri": issuer.issuer + "/deviceauth/callback",
        }, form=True)
        self.assertEqual(status, 200)
        return json.loads(body)

    def model_body(self, issuer):
        return {"model": "fixture-model", "instructions": TRANSLATION_INSTRUCTIONS,
                "input": [{"type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": issuer.translation_input()}]}],
                "tools": [], "tool_choice": "none", "parallel_tool_calls": False,
                "store": False, "stream": True}

    def model_headers(self, issuer, tokens):
        return {"Authorization": "Bearer " + tokens["access_token"],
                "ChatGPT-Account-ID": issuer.expected_identity()["account_id"]}

    def refresh_body(self, tokens):
        return {"grant_type": "refresh_token", "client_id": OFFICIAL_CLIENT_ID,
                "refresh_token": tokens["refresh_token"]}

    def completed_event(self, body):
        lines = body.decode().splitlines()
        self.assertTrue(lines[0] == "event: response.completed")
        return json.loads(next(line[6:] for line in lines if line.startswith("data: ")))

    def test_full_contract_and_safe_evidence(self):
        with FakeIssuer("success") as issuer:
            code = self.device(issuer)
            status, body = self.request(issuer, POLL, {
                "device_auth_id": code["device_auth_id"], "user_code": code["user_code"]})
            self.assertEqual(status, 200)
            grant = json.loads(body)
            status, body = self.request(issuer, EXCHANGE, {
                "grant_type": "authorization_code", "client_id": CLIENT_ID,
                "code": grant["authorization_code"], "code_verifier": grant["code_verifier"],
                "redirect_uri": issuer.issuer + "/deviceauth/callback",
            }, form=True)
            self.assertEqual(status, 200)
            self.assertTrue(set(json.loads(body)) == {"id_token", "access_token", "refresh_token"})
            self.assertTrue(issuer.contains_secret(body))
            evidence = issuer.snapshot()
            self.assertTrue(evidence["all_contracts_valid"])
            self.assertFalse(issuer.contains_secret(json.dumps(evidence).encode()))

    def test_pending_then_success(self):
        with FakeIssuer("pending_404") as issuer:
            code = self.device(issuer)
            request = {"device_auth_id": code["device_auth_id"], "user_code": code["user_code"]}
            self.assertEqual(self.request(issuer, POLL, request)[0], 404)
            self.assertEqual(self.request(issuer, POLL, request)[0], 200)
            self.assertEqual(issuer.snapshot()["requests"].get(POLL), 2)

    def test_contract_rejects_unrelated_request(self):
        with FakeIssuer() as issuer:
            status, _ = self.request(issuer, USERCODE, {"client_id": "unrelated"})
            self.assertEqual(status, 400)
            self.assertFalse(issuer.snapshot()["all_contracts_valid"])

    def test_held_poll_observes_client_closure(self):
        with FakeIssuer("cancel_poll", hold_seconds=2) as issuer:
            code = self.device(issuer)
            payload = json.dumps({"device_auth_id": code["device_auth_id"], "user_code": code["user_code"]}).encode()
            port = int(issuer.issuer.rsplit(":", 1)[1])
            connection = socket.create_connection(("127.0.0.1", port), timeout=2)
            connection.sendall(("POST " + POLL + " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
                                + str(len(payload)) + "\r\nConnection: close\r\n\r\n").encode() + payload)
            self.assertTrue(issuer.hold_entered.wait(1))
            connection.close()
            self.assertTrue(issuer.closed_during_hold.wait(1))
            self.assertFalse(issuer.snapshot()["violations"])

    def test_held_device_request_observes_client_closure_before_ready(self):
        with FakeIssuer("cancel_usercode", hold_seconds=2) as issuer:
            payload = json.dumps({"client_id": CLIENT_ID}).encode()
            port = int(issuer.issuer.rsplit(":", 1)[1])
            connection = socket.create_connection(("127.0.0.1", port), timeout=2)
            connection.sendall(("POST " + USERCODE + " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
                                + str(len(payload)) + "\r\nConnection: close\r\n\r\n").encode() + payload)
            self.assertTrue(issuer.hold_entered.wait(1))
            connection.close()
            self.assertTrue(issuer.closed_during_hold.wait(1))
            self.assertEqual(issuer.snapshot()["requests"], {USERCODE: 1})
            self.assertFalse(issuer.snapshot()["violations"])

    def test_poll_rejects_a_different_ready_code(self):
        with FakeIssuer() as issuer:
            code = self.device(issuer)
            self.assertTrue(issuer.valid_device_response({
                "user_code": code["user_code"], "verification_url": issuer.issuer + "/codex/device"}))
            status, _ = self.request(issuer, POLL, {
                "device_auth_id": code["device_auth_id"], "user_code": "unrelated-code"})
            self.assertEqual(status, 400)
            self.assertFalse(issuer.snapshot()["all_contracts_valid"])

    def test_socket_is_closed_on_context_exit(self):
        with FakeIssuer() as issuer:
            port = int(issuer.issuer.rsplit(":", 1)[1])
        with socket.socket() as connection:
            connection.settimeout(1)
            self.assertNotEqual(connection.connect_ex(("127.0.0.1", port)), 0)

    def test_server_shutdown_is_not_client_cancellation(self):
        issuer = FakeIssuer("cancel_poll", hold_seconds=2).start()
        connection = None
        try:
            code = self.device(issuer)
            payload = json.dumps({"device_auth_id": code["device_auth_id"], "user_code": code["user_code"]}).encode()
            port = int(issuer.issuer.rsplit(":", 1)[1])
            connection = socket.create_connection(("127.0.0.1", port), timeout=2)
            connection.sendall(("POST " + POLL + " HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
                                + str(len(payload)) + "\r\nConnection: close\r\n\r\n").encode() + payload)
            self.assertTrue(issuer.hold_entered.wait(1))
            issuer.close()
            self.assertFalse(issuer.closed_during_hold.is_set())
            self.assertFalse(issuer.snapshot()["violations"])
        finally:
            if connection is not None:
                connection.close()
            issuer.close()

    def test_error_marker_is_only_in_response_memory(self):
        with FakeIssuer("device_issuer_error") as issuer:
            status, body = self.request(issuer, USERCODE, {"client_id": CLIENT_ID})
            self.assertEqual(status, 500)
            self.assertTrue(issuer.contains_secret(body))
            self.assertFalse(issuer.contains_secret(json.dumps(issuer.snapshot()).encode()))

    def test_responses_contract_uses_exact_constructed_identity_and_translation(self):
        with FakeIssuer() as issuer:
            tokens = self.login(issuer)
            status, body = self.request(issuer, RESPONSES, self.model_body(issuer),
                                        headers=self.model_headers(issuer, tokens))
            self.assertEqual(status, 200)
            event = self.completed_event(body)
            text = event["response"]["output"][0]["content"][0]["text"]
            self.assertTrue(issuer.valid_translation_result({"status": "ok", "text": text}))
            self.assertFalse(issuer.valid_translation_result({"status": "ok", "text": "unrelated"}))
            self.assertTrue(issuer.contains_secret(body))
            self.assertTrue(issuer.contains_secret(text.encode()))
            evidence = issuer.snapshot()
            self.assertEqual(evidence["requests"], {USERCODE: 1, POLL: 1, EXCHANGE: 1, RESPONSES: 1})
            self.assertEqual(evidence["oauth_grants"], {"authorization_code": 1})
            self.assertTrue(evidence["all_contracts_valid"])
            self.assertFalse(evidence["authorization_header_absent"])
            self.assertTrue(evidence["headers_valid"])
            self.assertTrue(evidence["model_authorization_headers_valid"])
            self.assertFalse(issuer.contains_secret(json.dumps(evidence).encode()))

    def test_responses_rejects_wrong_headers_or_unsafe_request_body(self):
        for case in ("missing_bearer", "wrong_bearer", "wrong_account", "cookie", "tools", "store", "numeric_boolean"):
            with self.subTest(case=case), FakeIssuer() as issuer:
                tokens = self.login(issuer)
                headers = self.model_headers(issuer, tokens)
                body = self.model_body(issuer)
                if case == "missing_bearer":
                    del headers["Authorization"]
                elif case == "wrong_bearer":
                    headers["Authorization"] = "Bearer unrelated"
                elif case == "wrong_account":
                    headers["ChatGPT-Account-ID"] = "unrelated"
                elif case == "cookie":
                    headers["Cookie"] = "unrelated=fixture"
                elif case == "tools":
                    body["tools"] = [{"type": "function", "name": "unexpected"}]
                elif case == "store":
                    body["store"] = True
                else:
                    body["store"] = 0
                self.assertEqual(self.request(issuer, RESPONSES, body, headers=headers)[0], 400)
                self.assertFalse(issuer.snapshot()["all_contracts_valid"])
                self.assertFalse(issuer.contains_secret(json.dumps(issuer.snapshot()).encode()))

    def test_model_unauthorized_and_tool_scenarios_have_one_response(self):
        for case in ("model401", "modeltool"):
            with self.subTest(case=case), FakeIssuer(case) as issuer:
                tokens = self.login(issuer)
                status, body = self.request(issuer, RESPONSES, self.model_body(issuer),
                                            headers=self.model_headers(issuer, tokens))
                self.assertEqual(status, 401 if case == "model401" else 200)
                if case == "model401":
                    self.assertTrue(issuer.contains_secret(body))
                else:
                    event = self.completed_event(body)
                    self.assertEqual(event["response"]["output"][0]["type"], "function_call")
                self.assertEqual(issuer.snapshot()["requests"][RESPONSES], 1)
                self.assertTrue(issuer.snapshot()["all_contracts_valid"])

    def test_json_refresh_rotates_tokens_and_detects_old_and_new_secrets(self):
        with FakeIssuer() as issuer:
            old = self.login(issuer)
            status, body = self.request(issuer, EXCHANGE, self.refresh_body(old))
            self.assertEqual(status, 200)
            new = json.loads(body)
            self.assertTrue(set(new) == {"id_token", "access_token", "refresh_token"})
            self.assertTrue(all(old[key] != new[key] for key in old))
            for tokens in (old, new):
                self.assertTrue(all(issuer.contains_secret(value.encode()) for value in tokens.values()))
            status, body = self.request(issuer, RESPONSES, self.model_body(issuer),
                                        headers=self.model_headers(issuer, new))
            self.assertEqual(status, 200)
            event = self.completed_event(body)
            self.assertTrue(issuer.valid_translation_result({"status": "ok",
                "text": event["response"]["output"][0]["content"][0]["text"]}))
            evidence = issuer.snapshot()
            self.assertEqual(evidence["oauth_grants"], {"authorization_code": 1, "refresh_token": 1})
            self.assertTrue(evidence["all_contracts_valid"])
            self.assertFalse(issuer.contains_secret(json.dumps(evidence).encode()))
            self.assertEqual(self.request(issuer, EXCHANGE, self.refresh_body(old))[0], 400)
            self.assertEqual(self.request(issuer, RESPONSES, self.model_body(issuer),
                headers=self.model_headers(issuer, old))[0], 400)

    def test_refresh_rejects_device_client_id_form_and_bearer_header(self):
        for case in ("device_client_id", "form", "authorization"):
            with self.subTest(case=case), FakeIssuer() as issuer:
                tokens = self.login(issuer)
                payload = self.refresh_body(tokens)
                headers = None
                if case == "device_client_id":
                    payload["client_id"] = CLIENT_ID
                elif case == "authorization":
                    headers = self.model_headers(issuer, tokens)
                status, _ = self.request(issuer, EXCHANGE, payload, form=case == "form", headers=headers)
                self.assertEqual(status, 400)
                self.assertFalse(issuer.snapshot()["all_contracts_valid"])

    def test_refresh_error_malformed_and_different_identity_scenarios(self):
        for case in ("refresh_failed", "refresh_malformed", "refresh_wrong_account", "refresh_wrong_account_only"):
            with self.subTest(case=case), FakeIssuer(case) as issuer:
                old = self.login(issuer)
                status, body = self.request(issuer, EXCHANGE, self.refresh_body(old))
                self.assertEqual(status, 401 if case == "refresh_failed" else 200)
                value = json.loads(body)
                if case in ("refresh_wrong_account", "refresh_wrong_account_only"):
                    segment = value["id_token"].split(".")[1]
                    claims = json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))
                    identity = claims["https://api.openai.com/auth"]
                    self.assertTrue(identity["chatgpt_account_id"] != issuer.expected_identity()["account_id"])
                    self.assertEqual(identity["chatgpt_user_id"] == issuer.expected_identity()["user_id"],
                                     case == "refresh_wrong_account_only")
                    self.assertTrue(issuer.contains_secret(json.dumps(identity).encode()))
                elif case == "refresh_malformed":
                    self.assertIs(type(value["id_token"]), int)
                else:
                    self.assertEqual(value["error"], "invalid_grant")
                self.assertTrue(issuer.contains_secret(body))
                self.assertTrue(issuer.snapshot()["all_contracts_valid"])
                self.assertFalse(issuer.contains_secret(json.dumps(issuer.snapshot()).encode()))

    def test_expired_access_token_scenarios_exercise_proactive_refresh(self):
        def claims(token):
            segment = token.split(".")[1]
            return json.loads(base64.urlsafe_b64decode(segment + "=" * (-len(segment) % 4)))

        for case in ("expired_access", "expired_refresh_failed", "expired_refresh_malformed", "expired_refresh_still_expired"):
            with self.subTest(case=case), FakeIssuer(case) as issuer:
                old = self.login(issuer)
                self.assertLess(claims(old["access_token"])["exp"], time.time())
                status, body = self.request(issuer, EXCHANGE, self.refresh_body(old))
                self.assertEqual(status, 401 if case == "expired_refresh_failed" else 200)
                value = json.loads(body)
                if case in ("expired_access", "expired_refresh_still_expired"):
                    self.assertEqual(claims(value["access_token"])["exp"] < time.time(),
                                     case == "expired_refresh_still_expired")
                self.assertTrue(issuer.snapshot()["all_contracts_valid"])
                self.assertTrue(issuer.contains_secret(body))

    def test_revoke_exact_current_token_pair_and_failure(self):
        for case in ("success", "revoke_failure"):
            with self.subTest(case=case), FakeIssuer(case) as issuer:
                tokens = self.login(issuer)
                payload = {"token": tokens["refresh_token"], "token_type_hint": "refresh_token",
                           "client_id": OFFICIAL_CLIENT_ID}
                self.assertEqual(self.request(issuer, REVOKE, payload)[0], 200 if case == "success" else 500)
                evidence = issuer.snapshot()
                self.assertTrue(evidence["all_contracts_valid"])
                self.assertTrue(evidence["authorization_header_absent"])
                self.assertFalse(issuer.contains_secret(json.dumps(evidence).encode()))
                # A rejected revoke does not silently revoke the fixture token.
                status, _ = self.request(issuer, RESPONSES, self.model_body(issuer),
                                         headers=self.model_headers(issuer, tokens))
                self.assertEqual(status, 400 if case == "success" else 200)

    def test_auth_endpoints_still_reject_authorization_and_cookie(self):
        for headers in ({"Authorization": "Bearer unrelated"}, {"Cookie": "unrelated=fixture"}):
            with FakeIssuer() as issuer:
                status, _ = self.request(issuer, USERCODE, {"client_id": CLIENT_ID}, headers=headers)
                self.assertEqual(status, 400)
                self.assertFalse(issuer.snapshot()["all_contracts_valid"])


if __name__ == "__main__":
    unittest.main()
