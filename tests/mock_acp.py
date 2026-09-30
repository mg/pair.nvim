import json
import os
import sys
import time

args_trace = os.getenv("PAIR_MOCK_ARGS_TRACE")
if args_trace:
    with open(args_trace, "w", encoding="utf-8") as log:
        log.write(json.dumps(sys.argv[1:]))


def send(value):
    sys.stdout.write(json.dumps(value) + "\n")
    sys.stdout.flush()


pending = None
ignore_cancel = False
modern_modes = os.getenv("PAIR_MOCK_MODES") == "modern"
mode = "ask" if modern_modes else "plan"
model = "mock/default"


def session_state():
    state = {"configOptions": [
        {"id": "model", "currentValue": model, "options": [
            {"value": "mock/default", "name": "Default"},
            {"value": "mock/model", "name": "Alternative"},
        ]},
    ]}
    if modern_modes:
        state["modes"] = {"currentModeId": mode, "availableModes": [
            {"id": "ask", "name": "Ask"}, {"id": "plan", "name": "Plan"},
        ]}
    else:
        state["configOptions"].append(
            {"id": "mode", "currentValue": "plan", "options": [{"value": "plan"}]}
        )
    return state


for line in sys.stdin:
    event = json.loads(line)
    method = event.get("method")
    request_id = event.get("id")
    trace = os.getenv("PAIR_MOCK_TRACE")
    if trace and method:
        with open(trace, "a", encoding="utf-8") as log:
            log.write(method + "\n")
    request_trace = os.getenv("PAIR_MOCK_REQUEST_TRACE")
    if request_trace and method:
        with open(request_trace, "a", encoding="utf-8") as log:
            log.write(json.dumps({"method": method, "params": event.get("params")}) + "\n")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": 1, "agentCapabilities": {
                "loadSession": os.getenv("PAIR_MOCK_NO_LOAD") != "1"
            }
        }})
    elif method == "session/new":
        if os.getenv("PAIR_MOCK_START_DELAY"):
            time.sleep(float(os.getenv("PAIR_MOCK_START_DELAY")))
        if os.getenv("PAIR_MOCK_AUTH_FAIL") == "1":
            send({"jsonrpc": "2.0", "id": request_id,
                  "error": {"message": "login required"}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "sessionId": "mock-session", **session_state()
            }})
    elif method == "session/load":
        if os.getenv("PAIR_MOCK_FAIL_LOAD") == "1":
            send({"jsonrpc": "2.0", "id": request_id, "error": {"message": "mock restore failed"}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "result": session_state()})
    elif method == "session/set_mode":
        mode = event["params"].get("modeId")
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "mock-session", "update": {
                "sessionUpdate": "current_mode_update", "currentModeId": mode
            }
        }})
    elif method == "session/set_config_option":
        if event["params"].get("configId") == "model" and event["params"].get("value") in ("mock/default", "mock/model"):
            model = event["params"]["value"]
            send({"jsonrpc": "2.0", "id": request_id, "result": session_state()})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"message": "wrong model"}})
    elif method == "session/prompt":
        pending = request_id
        prompt = event["params"]["prompt"][0]["text"]
        ignore_cancel = "stuck cancel" in prompt
        prompt_trace = os.getenv("PAIR_MOCK_PROMPT_TRACE")
        if prompt_trace:
            with open(prompt_trace, "a", encoding="utf-8") as log:
                log.write(json.dumps(prompt) + "\n")
        if prompt == "unsafe tool" or "pair-test-unsafe" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "unsafe-write",
                    "name": "Write", "title": "Write sample.lua", "status": "in_progress"
                }
            }})
            pending = None
            continue
        if "pair-test-gemini-read" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "gemini-read",
                    "name": "read_file", "kind": "read", "title": "Read sample.lua",
                    "status": "in_progress"
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "read complete"}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            pending = None
            continue
        if "pair-test-unnamed-read" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "read-sample",
                    "kind": "read", "title": "Viewing sample.lua", "status": "pending"
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call_update", "toolCallId": "read-sample",
                    "status": "completed"
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "read complete"}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            pending = None
            continue
        if "pair-test-unnamed-edit" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "edit-sample",
                    "kind": "edit", "title": "Editing sample.lua", "status": "pending"
                }
            }})
            pending = None
            continue
        if "pair-test-stream" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "first"}
                }
            }})
            time.sleep(0.25)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": " second"}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            pending = None
            continue
        if "User request: pair-test-change" in prompt or "User request: pair-test-insert" in prompt:
            replacement = (
                "local changed = true"
                if "User request: pair-test-change" in prompt
                else "local helper = true\n"
            )
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": json.dumps({
                        "replacement": replacement, "rationale": "Scoped test proposal"
                    })}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            pending = None
            continue
        if "slow reply" in prompt:
            time.sleep(0.3)
        if "late edit" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "late-read",
                    "title": "Read for late edit", "status": "in_progress"
                }
            }})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "{\"replacement\":"}
                }
            }})
            time.sleep(0.3)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "\"-- unsafe late code\",\"rationale\":\"late\"}"}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
            pending = None
            continue
        if "stuck cancel" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "partial"}
                }
            }})
            continue
        if "agent cancels" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "cancel-read",
                    "title": "Read before agent cancellation", "status": "in_progress"
                }
            }})
            time.sleep(0.15)
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "cancelled"}})
            pending = None
            continue
        if "fail turn" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "fail-read",
                    "title": "Read before failure", "status": "in_progress"
                }
            }})
            time.sleep(0.15)
            send({"jsonrpc": "2.0", "id": pending, "error": {"message": "mock turn failure"}})
            pending = None
            continue
        if "status tool" in prompt:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "read-1",
                    "title": "Read sample.lua", "status": "in_progress"
                }
            }})
            time.sleep(0.5)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "tool_call_update", "toolCallId": "read-1",
                    "status": "completed", "content": [{
                        "type": "content", "content": {"type": "text", "text": "sample contents"}
                    }]
                }
            }})
        if "cancel me" in prompt:
            continue
        if prompt == "leave plan":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "current_mode_update", "currentModeId": "build"
                }
            }})
            continue
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": "mock-session", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello"}
            }
        }})
        send({"jsonrpc": "2.0", "id": 99, "method": "session/request_permission", "params": {
            "sessionId": "mock-session", "options": [
                {"kind": "allow_once", "optionId": "yes", "name": "Allow"},
                {"kind": "reject_once", "optionId": "no", "name": "Reject"},
            ], "toolCall": {"toolCallId": "unsafe"}
        }})
    elif request_id == 99 and pending is not None:
        if event.get("result", {}).get("outcome") != {"outcome": "selected", "optionId": "no"}:
            send({"jsonrpc": "2.0", "id": pending, "error": {"message": "permission granted"}})
        else:
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": "mock-session", "update": {
                    "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " world"}
                }
            }})
            send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "end_turn"}})
        pending = None
    elif method == "session/cancel" and pending is not None:
        if ignore_cancel:
            continue
        send({"jsonrpc": "2.0", "id": pending, "result": {"stopReason": "cancelled"}})
        pending = None
