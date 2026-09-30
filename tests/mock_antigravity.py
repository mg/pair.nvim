#!/usr/bin/env python3
import json
import os
import sys

trace = os.environ.get("PAIR_AGY_TRACE")
if trace:
    with open(trace, "a", encoding="utf-8") as file:
        file.write(json.dumps({"args": sys.argv[1:], "home": os.environ.get("GEMINI_HOME")}) + "\n")

conversation_id = "12345678-1234-1234-1234-123456789abc"
if "--conversation" in sys.argv:
    conversation_id = sys.argv[sys.argv.index("--conversation") + 1]

for line in sys.stdin:
    event = json.loads(line)
    if event.get("event") != "user":
        continue
    prompt = event["message"]["content"]
    print(json.dumps({"event": "init", "conversation_id": conversation_id,
                      "init": {"tools": ["view_file"], "permission_mode": "request-review"}}), flush=True)
    name = "write_to_file" if "pair-test-write" in prompt else "view_file"
    print(json.dumps({"event": "step_update", "step_update": {
        "conversation_id": conversation_id, "step_index": 1, "step_type": "tool",
        "tool_name": name, "state": "ACTIVE"}}), flush=True)
    if name == "write_to_file":
        continue
    print(json.dumps({"event": "step_update", "step_update": {
        "conversation_id": conversation_id, "step_index": 2, "step_type": "agent_response",
        "state": "ACTIVE", "text_delta": "read complete"}}), flush=True)
    print(json.dumps({"event": "result", "result": {
        "conversation_id": conversation_id, "status": "SUCCESS", "response": "read complete"}}),
        flush=True)
