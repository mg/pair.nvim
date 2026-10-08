#!/usr/bin/env python3
"""Deterministic Pi RPC fixture; no provider or credentials required."""
import json
import os
import sys
import time

args = sys.argv[1:]
assert args[:4] == ["--mode", "rpc", "--tools", "read,grep,find,ls"]
for flag in ("--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files", "--no-approve"):
    assert flag in args
session = (args[args.index("--session") + 1] if "--session" in args
           else os.path.join(args[args.index("--session-dir") + 1], "mock.jsonl"))
model = {"provider": "mock", "id": "default", "name": "Mock default"}
pending = False


def send(event):
    # Deliberately split UTF-8 and JSON records across reads, and use CRLF.
    data = (json.dumps(event, ensure_ascii=False) + "\r\n").encode()
    os.write(1, data[:13])
    os.write(1, data[13:])


def reply(req, data=None, error=None):
    send({"type": "response", "id": req["id"], "command": req["type"],
          "success": error is None, "data": data, "error": error})


def text(value):
    send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": value}})


def end(reason="stop", error=None):
    send({"type": "message_end", "message": {"role": "assistant", "stopReason": reason, "errorMessage": error}})
    send({"type": "agent_end", "messages": []})
    send({"type": "agent_settled"})


for line in sys.stdin:
    req = json.loads(line)
    kind = req["type"]
    if kind == "get_state":
        reply(req, {"sessionFile": session, "sessionId": "mock-id", "model": model})
    elif kind == "get_available_models":
        reply(req, {"models": [{"provider": "mock", "id": "default"}, {"provider": "mock", "id": "other"}]})
    elif kind == "set_model":
        if req["provider"] != "mock" or req["modelId"] not in ("default", "other"):
            reply(req, error="Model not found")
        else:
            model = {"provider": "mock", "id": req["modelId"]}
            reply(req, model)
    elif kind == "prompt":
        message = req["message"]
        if message == "reject":
            reply(req, error="Prompt rejected")
            continue
        with open(session, "a") as f:
            f.write(json.dumps({"message": message}) + "\n")
        reply(req, {"disposition": "started"})
        send({"type": "agent_start"})
        if message == "unsafe":
            send({"type": "tool_execution_start", "toolName": "write"})
        elif message == "error":
            end("error", "Authentication required")
        elif message == "exit":
            sys.exit(2)
        elif message == "cancel":
            text("waiting")
            pending = True
        elif message == "retry":
            text("failed attempt")
            send({"type": "message_end", "message": {"role": "assistant", "stopReason": "error", "errorMessage": "temporary"}})
            send({"type": "agent_end", "willRetry": True})
            send({"type": "auto_retry_start", "attempt": 1})
            text("recovered")
            end()
        else:
            send({"type": "tool_execution_start", "toolCallId": "read-1", "toolName": "read", "args": {}})
            send({"type": "tool_execution_end", "toolCallId": "read-1", "toolName": "read", "result": {"content": [{"type": "text", "text": "saved file"}]}})
            text('{"replacement":"changed", "rationale":"test"}' if "Respond with one JSON object" in message else "hello π\u2028world")
            send({"type": "agent_end", "willRetry": False})
            # Completion must not occur on agent_end.
            time.sleep(0.1)
            send({"type": "agent_settled"})
    elif kind == "abort":
        if pending:
            pending = False
            end("aborted")
        reply(req)
    else:
        reply(req, error="Unknown command")
