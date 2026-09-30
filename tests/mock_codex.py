#!/usr/bin/env python3
import json
import os
import sys
import time


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def trace(method):
    path = os.getenv("PAIR_MOCK_CODEX_TRACE")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(method + "\n")


def trace_params(method, params):
    path = os.getenv("PAIR_MOCK_CODEX_PARAMS")
    if path:
        with open(path, "a", encoding="utf-8") as log:
            log.write(json.dumps({"method": method, "params": params}) + "\n")


if sys.argv[1:] == ["mcp", "list", "--json"]:
    names = os.getenv("PAIR_MOCK_CODEX_MCP", "").split(",")
    print(json.dumps([{"name": name, "enabled": True} for name in names if name]))
    sys.exit(0)

if not sys.argv[1:] or sys.argv[1] != "app-server":
    sys.exit(1)

args_path = os.getenv("PAIR_MOCK_CODEX_ARGS")
if args_path:
    with open(args_path, "a", encoding="utf-8") as log:
        log.write(json.dumps(sys.argv[1:]) + "\n")

pending_thread = None

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method is None:
        continue
    trace(method)
    request_id = request.get("id")
    params = request.get("params") or {}
    trace_params(method, params)
    if method == "initialize":
        send({"id": request_id, "result": {}})
    elif method == "thread/start":
        if os.getenv("PAIR_MOCK_AUTH_FAIL") == "1":
            send({"id": request_id, "error": {"message": "login required"}})
        else:
            send({"id": request_id, "result": {"thread": {"id": "mock-codex-thread"}}})
    elif method == "model/list":
        send({"id": request_id, "result": {"data": [
            {"model": "mock-codex-default", "displayName": "Default", "isDefault": True},
            {"model": "mock-codex-alt", "displayName": "Alternative"},
        ], "nextCursor": None}})
    elif method == "thread/resume":
        if os.getenv("PAIR_MOCK_RESUME_DELAY"):
            time.sleep(float(os.getenv("PAIR_MOCK_RESUME_DELAY")))
        if os.getenv("PAIR_MOCK_FAIL_RESUME") == "1":
            send({"id": request_id, "error": {"message": "mock Codex restore failed"}})
        else:
            send({"id": request_id, "result": {
                "thread": {"id": params.get("threadId")}
            }})
    elif method == "turn/start":
        thread_id = params.get("threadId")
        prompt = "\n".join(item.get("text", "") for item in params.get("input", []))
        send({"id": request_id, "result": {"turn": {"id": "mock-turn"}}})
        send({"method": "turn/started", "params": {
            "threadId": thread_id, "turn": {"id": "mock-turn", "status": "inProgress"}
        }})
        if "mock file change" in prompt:
            send({"method": "item/started", "params": {
                "threadId": thread_id, "item": {"id": "unsafe", "type": "fileChange"}
            }})
            continue
        if "mock cancel" in prompt:
            pending_thread = thread_id
            send({"method": "item/agentMessage/delta", "params": {
                "threadId": thread_id, "itemId": "message", "delta": "partial"
            }})
            continue
        if "User request: pair-test-change" in prompt:
            reply = '{"replacement":"local changed = true","rationale":"Scoped mock change"}'
        elif "User request: pair-test-insert" in prompt:
            reply = '{"replacement":"local helper = true\\n","rationale":"Scoped mock insert"}'
        else:
            reply = "mock codex reply"
        halfway = max(1, len(reply) // 2)
        for index, delta in enumerate((reply[:halfway], reply[halfway:])):
            if index and "mock streaming" in prompt:
                time.sleep(0.25)
            send({"method": "item/agentMessage/delta", "params": {
                "threadId": thread_id, "itemId": "message", "delta": delta
            }})
        send({"method": "turn/completed", "params": {
            "threadId": thread_id, "turn": {"id": "mock-turn", "status": "completed"}
        }})
    elif method == "turn/interrupt":
        send({"id": request_id, "result": {}})
        if pending_thread == params.get("threadId"):
            send({"method": "item/completed", "params": {
                "threadId": pending_thread, "item": None
            }})
            send({"method": "turn/completed", "params": {
                "threadId": pending_thread,
                "turn": {"id": "mock-turn", "status": "interrupted", "error": None}
            }})
            pending_thread = None
