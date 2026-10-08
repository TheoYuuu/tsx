#!/usr/bin/env python3
"""Exercise production networking against an isolated HTTP server on 127.0.0.1.

Run from any working directory with Python 3 and the installed Xcode toolchain.
Only synthetic text and a fake key are used. No credentials or product settings
are accessed. The fixture never proxies requests or connects to external hosts.
"""

from __future__ import annotations

import json
import platform
import select
import socket
import subprocess
import threading
import time
from collections import Counter
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / ".build" / "QA" / "RemoteTranslationNetwork"
SAMPLE = "A clear sentence is easy to understand."
TRANSLATION = "清晰的句子很容易理解。 🌍"
FAKE_KEY = "Bearer translatex-network-fixture-key"
FIXTURES = {
    "chat-sse", "responses-sse", "chat-json", "responses-json",
    "redirect-same", "redirect-other", "chat-truncated", "responses-truncated",
    "cancel-before-headers", "cancel-during-body", "cookie-followup",
    "deepl-json", "azure-json",
    "claude-sse", "claude-json", "claude-truncated", "qwen-json", "google-json",
    "claude-cancel-before-headers", "claude-cancel-during-body",
    "dedicated-cancel-before-headers", "dedicated-cancel-during-body",
    "tencent-json", "tencent-truncated-json",
}
CANCELLATIONS = {name for name in FIXTURES if "cancel-" in name}


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.requests = Counter()
        self.started = set()
        self.disconnected = set()
        self.failures = []
        self.stopping = threading.Event()

    def fail(self, message):
        with self.lock:
            self.failures.append(message)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def frame(value):
    data = value.encode() if isinstance(value, str) else json_bytes(value)
    return b"data: " + data + b"\r\n\r\n"


def response_output():
    return {
        "status": "completed", "error": None,
        "output": [{"type": "message", "role": "assistant", "status": "completed",
                    "content": [{"type": "output_text", "text": TRANSLATION}]}],
    }


def chat_body():
    return {"choices": [{"index": 0, "message": {"role": "assistant", "content": TRANSLATION}, "finish_reason": "stop"}]}


def claude_body():
    return {"id": "msg_fixture", "type": "message", "role": "assistant", "model": "fixture-model",
            "content": [{"type": "text", "text": TRANSLATION}], "stop_reason": "end_turn",
            "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 20}}


def claude_stream(complete=True):
    message = claude_body() | {"content": [], "stop_reason": None}
    events = [
        {"type": "message_start", "message": message},
        {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "清晰的句子"}},
        {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "很容易理解。 🌍"}},
        {"type": "content_block_stop", "index": 0},
        {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 20}},
    ]
    if complete:
        events.append({"type": "message_stop"})
    return b"".join(b"event: " + event["type"].encode() + b"\r\n" + frame(event) for event in events)


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass  # Do not log bodies, credentials, or request metadata.

    @property
    def state(self):
        return self.server.fixture_state

    def do_GET(self):
        fixture = self.path.removeprefix("/status/")
        with self.state.lock:
            ready = fixture in self.state.started
        body = b"started" if ready else b"waiting"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        fixture = self.path.split("/")[1]
        with self.state.lock:
            self.state.requests[fixture] += 1
        if fixture not in FIXTURES:
            self.state.fail("An unexpected endpoint received a request.")
            self.send_error(400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length < 32_768:
            self.state.fail("Unexpected request body size.")
            self.send_error(400)
            return
        try:
            body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeError):
            self.state.fail("Request was not valid JSON.")
            self.send_error(400)
            return
        self.check_request(fixture, body)
        try:
            if fixture.endswith("cancel-before-headers"):
                self.mark_started(fixture)
                self.wait_for_disconnect(fixture)
                return
            if fixture.startswith("redirect-"):
                host = "127.0.0.1" if fixture == "redirect-same" else "localhost"
                self.send_response(307)
                self.send_header("Location", f"http://{host}:{self.server.server_port}/redirect-target/v1/chat/completions")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if fixture.endswith("json"):
                if fixture == "deepl-json":
                    response = {"translations": [{"text": TRANSLATION, "detected_source_language": "EN"}]}
                elif fixture == "azure-json":
                    response = [{"detectedLanguage": {"language": "en", "score": 1.0},
                                 "translations": [{"text": TRANSLATION, "to": "zh-Hans"}]}]
                elif fixture == "google-json":
                    response = {"data": {"translations": [{"translatedText": TRANSLATION, "detectedSourceLanguage": "en"}]}}
                elif fixture == "claude-json":
                    response = claude_body()
                elif fixture.startswith("tencent-"):
                    response = chat_body() | {"id": "fixture-translation", "created": 1, "source": "en", "target": "zh", "usage": {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}}
                    if fixture == "tencent-truncated-json":
                        response["choices"][0]["finish_reason"] = "length"
                else:
                    response = response_output() if fixture.startswith("responses-") else chat_body()
                data = json_bytes(response)
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Set-Cookie", "translatex_fixture_cookie=synthetic; Path=/")
                self.end_headers()
                self.wfile.write(data)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json" if fixture.startswith("dedicated-cancel") else "text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Set-Cookie", "translatex_fixture_cookie=synthetic; Path=/")
            self.end_headers()
            if fixture.endswith("cancel-during-body"):
                if fixture.startswith("claude-"):
                    self.chunk(claude_stream(complete=False))
                elif fixture.startswith("dedicated-"):
                    self.chunk(b'{"data":{"translations":[')
                else:
                    self.chunk(frame({"choices": [{"index": 0, "delta": {"content": "未完成的构造译文"}, "finish_reason": None}]}))
                self.mark_started(fixture)
                self.wait_for_disconnect(fixture)
                return
            if fixture.startswith("claude-"):
                data = claude_stream(complete=fixture != "claude-truncated")
            elif fixture.startswith("responses-"):
                data = frame({"type": "response.output_text.delta", "delta": "清晰的句子"})
                data += frame({"type": "response.output_text.delta", "delta": "很容易理解。 🌍"})
                if fixture != "responses-truncated":
                    data += frame({"type": "response.completed", "response": response_output()})
            else:
                data = frame({"choices": [{"index": 0, "delta": {"content": "清晰的句子"}, "finish_reason": None}]})
                data += frame({"choices": [{"index": 0, "delta": {"content": "很容易理解。 🌍"}, "finish_reason": "stop"}]})
                if fixture != "chat-truncated":
                    data += frame("[DONE]")
            # Tiny HTTP chunks intentionally split UTF-8 characters and CRLF.
            for index in range(0, len(data), 3):
                self.chunk(data[index:index + 3])
                time.sleep(0.001)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The production provider closes a stream once it sees completion.
            pass
        finally:
            self.close_connection = True

    def check_request(self, fixture, body):
        if self.headers.get("Cookie") is not None:
            self.state.fail("A production request sent cookies.")
        if fixture.startswith("claude-"):
            if self.headers.get("x-api-key") != "translatex-network-fixture-key" or self.headers.get("anthropic-version") != "2023-06-01" or self.headers.get("Authorization") is not None:
                self.state.fail("Incorrect Claude authentication headers.")
            if not self.path.endswith("/v1/messages") or body.get("model") != "fixture-model" or body.get("max_tokens") != 8192 or body.get("stream") is not True:
                self.state.fail("Incorrect native Claude request.")
            if body.get("messages") != [{"role": "user", "content": SAMPLE}] or not body.get("system"):
                self.state.fail("Claude raw sample and system instructions were not separate.")
            if any(key in body for key in ["thinking", "temperature", "top_p", "top_k"]):
                self.state.fail("Unexpected Claude sampling or thinking setting.")
            return
        if fixture == "google-json" or fixture.startswith("dedicated-cancel-"):
            if self.headers.get("x-goog-api-key") != "translatex-network-fixture-key" or self.headers.get("Authorization") is not None:
                self.state.fail("Incorrect Google authentication headers.")
            if self.path != "/" + fixture or body.get("q") not in [SAMPLE, [SAMPLE]] or body.get("target") != "zh-CN" or body.get("format") != "text" or body.get("model") != "nmt" or "source" in body:
                self.state.fail("Incorrect Basic v2 URL or single text request.")
            return
        if fixture == "qwen-json":
            if self.headers.get("Authorization") != FAKE_KEY or not self.path.endswith("/v1/chat/completions"):
                self.state.fail("Incorrect Qwen authentication or operation URL.")
            if body.get("model") != "qwen-mt-flash" or body.get("stream") is not False or body.get("messages") != [{"role": "user", "content": SAMPLE}] or body.get("translation_options") != {"source_lang": "auto", "target_lang": "zh"}:
                self.state.fail("Incorrect Qwen dedicated translation parameters.")
            return
        if fixture.startswith("tencent-"):
            if self.headers.get("Authorization") != FAKE_KEY or self.path != "/" + fixture + "/v1/api/translations":
                self.state.fail("Incorrect Tencent authentication or operation URL.")
            if body != {"model": "hy-mt2-plus", "text": SAMPLE, "target": "zh", "stream": False}:
                self.state.fail("Incorrect Tencent translation request or unexpected instructions.")
            return
        if fixture == "deepl-json":
            if self.headers.get("Authorization") != "DeepL-Auth-Key translatex-network-fixture-key":
                self.state.fail("Incorrect dedicated authentication.")
            if not self.path.endswith("/v2/translate") or body != {
                "text": [SAMPLE], "target_lang": "ZH-HANS", "preserve_formatting": True
            }:
                self.state.fail("Incorrect DeepL path or auto-source request.")
            return
        if fixture == "azure-json":
            url = urlsplit(self.path)
            if self.headers.get("Authorization") is not None or self.headers.get("Ocp-Apim-Subscription-Key") != "translatex-network-fixture-key":
                self.state.fail("Incorrect dedicated authentication.")
            query = parse_qs(url.query)
            if not url.path.endswith("/translate") or query != {"api-version": ["3.0"], "to": ["zh-Hans"], "textType": ["plain"]} or body != [{"Text": SAMPLE}]:
                self.state.fail("Incorrect Azure path or auto-source request.")
            return
        expected_auth = None if fixture == "cookie-followup" else FAKE_KEY
        if self.headers.get("Authorization") != expected_auth:
            self.state.fail("The fixture Authorization header did not match.")
        if body.get("model") != "fixture-model" or body.get("stream") is not True:
            self.state.fail("Incorrect model or streaming request.")
        if "max_tokens" in body or "max_output_tokens" in body:
            self.state.fail("A generic fixed token budget was sent.")
        responses = fixture.startswith("responses-")
        if responses:
            if not self.path.endswith("/v1/responses") or body.get("store") is not False or body.get("tools") != []:
                self.state.fail("Responses request was not stateless and tool-free.")
            if body.get("input") != [{"role": "user", "content": SAMPLE}]:
                self.state.fail("Incorrect Responses sample input.")
        else:
            if not self.path.endswith("/v1/chat/completions"):
                self.state.fail("Incorrect Chat operation path.")
            messages = body.get("messages", [])
            if len(messages) != 2 or messages[1] != {"role": "user", "content": SAMPLE}:
                self.state.fail("Incorrect Chat sample input.")

    def chunk(self, data):
        self.wfile.write(f"{len(data):X}\r\n".encode() + data + b"\r\n")
        self.wfile.flush()

    def mark_started(self, fixture):
        with self.state.lock:
            self.state.started.add(fixture)

    def wait_for_disconnect(self, fixture):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not self.state.stopping.is_set():
            readable, _, _ = select.select([self.connection], [], [], 0.05)
            if readable:
                try:
                    closed = self.connection.recv(1, socket.MSG_PEEK) == b""
                except ConnectionResetError:
                    closed = True
                if closed:
                    with self.state.lock:
                        self.state.disconnected.add(fixture)
                    return
        self.state.fail(f"Cancellation did not close the network connection: {fixture}")


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = [
        "Tools/QA/RemoteTranslationNetworkProbe.swift",
        "TranslateX/Support/L10n.swift",
        "TranslateX/Translation/LanguageCatalog.swift",
        "TranslateX/Translation/TranslationProvider.swift",
        "TranslateX/Translation/Services/TranslationServiceConfiguration.swift",
        "TranslateX/Translation/Services/RemoteTranslationProvider.swift",
        "TranslateX/Translation/Services/RemoteTranslationError.swift",
        "TranslateX/Translation/Services/RemoteTranslationResponseParser.swift",
        "TranslateX/Translation/Services/TranslationHTTPPolicy.swift",
        "TranslateX/Translation/Services/DedicatedTranslationLanguages.swift",
        "TranslateX/Translation/Services/DedicatedTranslationProvider.swift",
        "TranslateX/Translation/Services/BoundedTranslationHTTPTransport.swift",
        "TranslateX/Translation/Services/TranslationProviderFactory.swift",
        "TranslateX/Translation/Services/Codex/CodexAccountController.swift",
        "TranslateX/Translation/Services/Codex/CodexRuntimeSession.swift",
        "TranslateX/Translation/Services/Codex/CodexTranslationProvider.swift",
        "TranslateX/Translation/Services/ClaudeTranslationProvider.swift",
        "TranslateX/Translation/Services/ClaudeTranslationResponseParser.swift",
        "TranslateX/Translation/Services/GoogleCloudTranslationProvider.swift",
        "TranslateX/Translation/Services/TencentTranslationProvider.swift",
        "TranslateX/Translation/Services/TencentTranslationLanguages.swift",
        "TranslateX/Translation/Services/GoogleTranslationLanguages.swift",
        "TranslateX/Translation/Services/QwenMTTranslationProvider.swift",
        "TranslateX/Translation/Services/QwenMTTranslationLanguages.swift",
    ]
    executable = OUTPUT / "network-probe"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", "-strict-concurrency=complete",
        "-warnings-as-errors", "-target", f"{platform.machine()}-apple-macos15.0", "-O",
        *sources, "-o", str(executable),
    ], cwd=ROOT, check=True, timeout=90)
    state = State()
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    server.daemon_threads = True
    server.fixture_state = state
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        result = subprocess.run([str(executable), f"http://127.0.0.1:{server.server_port}"],
                                cwd=ROOT, capture_output=True, text=True, timeout=25)
        # Cancellation is only a pass once the HTTP server observes socket closure.
        deadline = time.monotonic() + 2
        while len(state.disconnected) < len(CANCELLATIONS) and time.monotonic() < deadline:
            time.sleep(0.025)
        with state.lock:
            failures = list(state.failures)
            if state.requests != Counter({fixture: 1 for fixture in FIXTURES}):
                failures.append("Requests were retried, omitted, or redirected to another endpoint.")
            if state.disconnected != CANCELLATIONS:
                failures.append("Not all cancellation sockets were observed closing.")
            report = {
                "passed": result.returncode == 0 and not failures,
                "checkedAt": datetime.now(timezone.utc).isoformat(),
                "scope": "Production URLSession to a loopback HTTP fixture; not provider-account or translation-quality validation.",
                "fixtures": sorted(FIXTURES),
                "requestCounts": dict(state.requests),
                "cancellationDisconnects": sorted(state.disconnected),
                "cookiesSent": False if not any("cookies" in failure for failure in failures) else True,
                "failures": failures,
            }
        (OUTPUT / "latest.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(result.stdout, end="")
        if result.returncode:
            print(result.stderr)
        if not report["passed"]:
            raise RuntimeError("Network fixture failed; inspect .build/QA/RemoteTranslationNetwork/latest.json")
        print("PASS server assertions: single requests, no redirects followed, no cookies, all cancellation sockets closed")
        print("Report: .build/QA/RemoteTranslationNetwork/latest.json")
    finally:
        state.stopping.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        print("Fixture server stopped.")


if __name__ == "__main__":
    main()
