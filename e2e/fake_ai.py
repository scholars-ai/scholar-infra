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


def _writer_article(prompt: str) -> tuple[str, str]:
    if "平台：xiaohongshu" in prompt:
        title = "AI工程链路如何避坑"
        paragraph = "这条工程实践从状态机、任务队列和追踪信息三个角度解释如何减少改动风险。"
        content = "## 先看结论\n\n" + paragraph * 18
        content += "\n\n## 三个检查点\n\n" + paragraph * 8
        content += "\n\n建议先保存这份检查清单，再结合真实任务逐项验证。\n\n#人工智能 #工程实践 #可观测性"
        return title, content
    if "平台：wechat" in prompt:
        title = "一条可追踪的 AI 流水线意味着什么"
        paragraph = "可观测性不是额外装饰，而是把状态变化、队列交接和模型调用连成一条可验证证据链。"
        content = "## 从一次状态变化说起\n\n" + paragraph * 22
        content += "\n\n## 队列为什么需要留痕\n\n" + paragraph * 18
        content += "\n\n## 把判断变成日常动作\n\n" + paragraph * 12
        return title, content
    title = "如何判断一条 AI 内容流水线是否可靠？"
    paragraph = "判断这类系统是否可靠，关键不是看某个服务能否单独运行，而是验证状态机、事务消息和追踪上下文是否共同维持一致性。"
    content = "## 先给结论\n\n" + paragraph * 24
    content += "\n\n## 状态机提供业务边界\n\n" + paragraph * 18
    content += "\n\n## 事务消息避免半完成状态\n\n" + paragraph * 16
    content += "\n\n## 最后检查可观测证据\n\n" + paragraph * 10
    return title, content


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
        schema_text = json.dumps(schema)
        properties = schema.get("properties", {}) if isinstance(schema, dict) else {}
        if "sections" in properties:
            raw_ids = list(dict.fromkeys(re.findall(r"[0-9a-f]{8}-[0-9a-f-]{27,}", prompt, re.I)))
            result = {
                "title": _writer_article(prompt)[0],
                "sections": [
                    {"heading": "先给结论", "purpose": "回应核心问题", "evidenceRawItemIds": raw_ids[:1]},
                    {"heading": "拆解机制", "purpose": "解释证据链", "evidenceRawItemIds": raw_ids[:1]},
                    {"heading": "行动清单", "purpose": "给出验证方法", "evidenceRawItemIds": raw_ids[:1]},
                ],
            }
        elif "contentMarkdown" in properties:
            title, content = _writer_article(prompt)
            result = {"title": title, "contentMarkdown": content}
            if "changes" in properties:
                result["changes"] = ["核对事实边界", "按平台档案统一结构"]
        elif "timeliness" in schema_text:
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
