"""Deterministic OpenAI-compatible fake for cross-repository E2E tests."""

from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

DIMENSIONS = (
    "timeliness",
    "audience_value",
    "platform_fit",
    "differentiation",
    "material_richness",
    "history_signal",
)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._json({"status": "ok"})
            return
        if self.path == "/article":
            body = (
                "<html><body><article><h1>Deterministic E2E Article</h1>"
                "<p>Scholars AI validates ingestion, embedding, topic scouting, "
                "evaluation and observability without calling a real provider. "
                "This paragraph is deliberately long enough to be useful source material.</p>"
                "</article></body></html>"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(404)

    def do_POST(self) -> None:
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if self.path == "/v1/embeddings":
            self._json(
                {
                    "object": "list",
                    "model": body.get("model", "fake-embedding"),
                    "data": [{"object": "embedding", "index": 0, "embedding": [1.0] + [0.0] * 1023}],
                    "usage": {"prompt_tokens": 8, "total_tokens": 8},
                }
            )
            return
        if self.path == "/v1/chat/completions":
            self._chat(body)
            return
        self.send_error(404)

    def _chat(self, body: dict[str, Any]) -> None:
        messages = body.get("messages") or []
        prompt = "\n".join(str(message.get("content") or "") for message in messages)
        tools = body.get("tools") or []
        schema = tools[0]["function"].get("parameters", {}) if tools else {}
        if "timeliness" in json.dumps(schema):
            result: dict[str, Any] = {
                "dimensionScores": {
                    key: {"score": 8, "reason": f"deterministic reason for {key}"}
                    for key in DIMENSIONS
                },
                "rationale": "Deterministic E2E evaluation passed.",
                "suggestedPlatforms": ["zhihu"],
            }
        else:
            raw_ids = list(dict.fromkeys(re.findall(r"[0-9a-f]{8}-[0-9a-f-]{27,}", prompt, re.I)))
            result = {
                "topics": [
                    {
                        "title": "Deterministic E2E Topic",
                        "angle": "Explain why a fully observable AI pipeline is safer to evolve.",
                        "summary": "A fake-provider E2E topic produced from the ingested article.",
                        "rawItemIds": raw_ids[:1],
                        "targetPlatforms": ["zhihu"],
                    }
                ],
                "discardReason": None,
            }
        self._json(
            {
                "id": "chatcmpl-e2e",
                "object": "chat.completion",
                "created": 0,
                "model": body.get("model", "fake-model"),
                "choices": [
                    {
                        "index": 0,
                        "finish_reason": "tool_calls",
                        "message": {
                            "role": "assistant",
                            "content": None,
                            "tool_calls": [
                                {
                                    "id": "call-e2e",
                                    "type": "function",
                                    "function": {
                                        "name": "emit_structured_output",
                                        "arguments": json.dumps(result),
                                    },
                                }
                            ],
                        },
                    }
                ],
                "usage": {"prompt_tokens": 12, "completion_tokens": 18, "total_tokens": 30},
            }
        )

    def _json(self, value: dict[str, Any]) -> None:
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8081), Handler).serve_forever()
