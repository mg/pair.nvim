#!/usr/bin/env python3
import json
import os
import sys
import subprocess

if sys.argv[1:] == ["models"]:
    if os.environ.get("PAIR_AGY_MODELS_FAIL"):
        print("mock model catalog unavailable", file=sys.stderr)
        sys.exit(1)
    print("mock-first\tFirst model\nmock-second\tSecond model")
    sys.exit(0)

trace = os.environ.get("PAIR_AGY_TRACE")
if trace:
    with open(trace, "a", encoding="utf-8") as file:
        file.write(json.dumps({"args": sys.argv[1:], "home": os.environ.get("HOME"),
                               "gemini_home": os.environ.get("GEMINI_HOME")}) + "\n")

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
    command = None
    if "pair-test-write-command" in prompt:
        command = "printf 'changed' > source.txt"
    elif "pair-test-generate" in prompt:
        command = "printf 'generated' > generated/output.txt"
    elif "pair-test-command" in prompt:
        command = "python3 -c 'assert 1 + 1 == 2; print(\"test passed\")'"
    name = "run_command" if command else "write_to_file" if "pair-test-write" in prompt else "view_file"
    print(json.dumps({"event": "step_update", "step_update": {
        "conversation_id": conversation_id, "step_index": 1, "step_type": "tool",
        "tool_name": name, "state": "ACTIVE",
        "tool_info": {"parameters": {"CommandLine": command}}}}), flush=True)
    if name == "write_to_file":
        continue
    if command:
        result = subprocess.run(command, shell=True, capture_output=True, text=True)
        print(json.dumps({"event": "step_update", "step_update": {
            "step_index": 1, "step_type": "tool", "tool_name": name,
            "state": "DONE" if result.returncode == 0 else "ERROR",
            "tool_info": {"output": result.stdout, "error": {"message": result.stderr}}}}), flush=True)
    print(json.dumps({"event": "step_update", "step_update": {
        "conversation_id": conversation_id, "step_index": 2, "step_type": "agent_response",
        "state": "ACTIVE", "text_delta": "read complete"}}), flush=True)
    print(json.dumps({"event": "result", "result": {
        "conversation_id": conversation_id, "status": "SUCCESS", "response": "read complete"}}),
        flush=True)
