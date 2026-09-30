from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import sys
import time


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        route = self.path.strip("/").split("/")
        provider = route[0]
        failure = route[1] if len(route) > 1 else None
        expected = {
            "openai": ("Authorization", "Bearer test-key"),
            "anthropic": ("x-api-key", "test-key"),
            "gemini": ("x-goog-api-key", "test-key"),
        }.get(provider)
        if not expected or self.headers.get(expected[0]) != expected[1]:
            self.send_error(401)
            return
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if failure:
            code = {"context": 400, "auth": 401, "quota": 429,
                    "server": 503}.get(failure, 400)
            payload = ({"error": {"message": "context window exceeded"}}
                       if failure == "context" else {"error": {"message": failure}})
            encoded = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
            return
        if provider != "gemini" and body.get("model") not in (
            "gpt-4.1-mini", "claude-sonnet-5-5"
        ):
            self.send_error(400)
            return
        prompt = ""
        if provider == "openai":
            for item in body.get("input", []):
                if item.get("role") == "user" and isinstance(item.get("content"), str):
                    prompt = item["content"]
        elif provider == "anthropic":
            for item in body.get("messages", []):
                if item.get("role") == "user" and isinstance(item.get("content"), str):
                    prompt = item["content"]
        else:
            for item in body.get("contents", []):
                if item.get("role") == "user":
                    for part in item.get("parts", []):
                        if "text" in part:
                            prompt = part["text"]
        if "Pair scoped code proposal" in prompt:
            replacement = ("local helper = true\n" if "Insert at this exact" in prompt
                           else "local changed = true")
            reply = json.dumps({"replacement": replacement, "rationale": "Mock proposal"})
        elif "Pair editor question" in prompt:
            reply = "Mock answer"
        else:
            reply = "Hello from HTTP"
        midpoint = len(reply) // 2
        pieces = (reply[:midpoint], reply[midpoint:])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        if provider == "openai":
            events = (
                {"type": "response.output_text.delta", "delta": pieces[0]},
                {"type": "response.output_text.delta", "delta": pieces[1]},
                {"type": "response.completed"},
            )
        elif provider == "anthropic":
            events = (
                {"type": "content_block_start", "index": 0,
                 "content_block": {"type": "text", "text": ""}},
                {"type": "content_block_delta", "index": 0,
                 "delta": {"type": "text_delta", "text": pieces[0]}},
                {"type": "content_block_delta", "index": 0,
                 "delta": {"type": "text_delta", "text": pieces[1]}},
                {"type": "content_block_stop", "index": 0},
                {"type": "message_stop"},
            )
        else:
            events = (
                {"candidates": [{"content": {"role": "model", "parts":
                 [{"text": pieces[0]}]}}]},
                {"candidates": [{"content": {"role": "model", "parts":
                 [{"text": pieces[1]}]}, "finishReason": "STOP"}]},
            )
        for event in events:
            self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
            self.wfile.flush()
            time.sleep(0.02)


server = HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
