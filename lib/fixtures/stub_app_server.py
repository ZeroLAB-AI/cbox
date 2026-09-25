#!/usr/bin/env python3
import json
import os
import sys
import time

MODE = os.environ.get("STUB_APP_SERVER_MODE", "happy")
STATE_FILE = os.environ.get("STUB_APP_SERVER_STATE_FILE", "")
METHODS_FILE = os.environ.get("STUB_APP_SERVER_METHODS_FILE", "")


def record_method(method):
    if not METHODS_FILE or not isinstance(method, str):
        return
    with open(METHODS_FILE, "a", encoding="utf-8") as fh:
        fh.write(method + "\n")

thread_counter = [0]
turn_counter = [0]
threads = {}


def now_ms():
    return int(time.time() * 1000)


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(rid, result):
    send({"id": rid, "result": result})


def reply_error(rid, code, message):
    send({"id": rid, "error": {"code": code, "message": message}})


def notify(method, params):
    send({"method": method, "params": params, "emittedAtMs": now_ms()})


def load_state():
    if not STATE_FILE or not os.path.isfile(STATE_FILE):
        return {}
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_state(state):
    if not STATE_FILE:
        return
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)


def remember_thread(thread_id, model, cwd):
    state = load_state()
    state[thread_id] = {"model": model, "cwd": cwd}
    save_state(state)


def handle_initialize(msg):
    rid = msg.get("id")
    if MODE == "init_error":
        reply_error(rid, -32000, "stub induced initialize failure")
        return
    reply(rid, {
        "userAgent": "stub-app-server/0.0.1",
        "codexHome": "/tmp/stub-codex-home",
        "platformFamily": "unix",
        "platformOs": "linux",
    })
    if MODE == "exit_after_init":
        time.sleep(0.6)
        sys.stdout.flush()
        os._exit(0)
    if MODE == "crash_on_init":
        sys.stdout.flush()
        os._exit(0)


def handle_thread_start(msg):
    rid = msg.get("id")
    params = msg.get("params") or {}
    if MODE == "thread_start_fail":
        reply_error(rid, -32000, "usageLimitExceeded: rate limit reached")
        return
    thread_counter[0] += 1
    thread_id = "thread-%d" % thread_counter[0]
    requested_model = params.get("model")
    reported_model = requested_model
    if MODE == "mismatch":
        reported_model = str(requested_model) + "-WRONG"
    threads[thread_id] = {"model": reported_model, "cwd": params.get("cwd")}
    remember_thread(thread_id, reported_model, params.get("cwd"))
    reply(rid, {
        "thread": {"id": thread_id, "model": reported_model,
                   "cwd": params.get("cwd"), "turns": []},
        "model": reported_model,
    })
    if MODE == "crash_after_thread_start":
        sys.stdout.flush()
        os._exit(0)


def handle_thread_resume(msg):
    rid = msg.get("id")
    params = msg.get("params") or {}
    tid = params.get("threadId")
    if MODE == "resume_fail":
        reply_error(rid, -32000, "rate_limit_reached: try again later")
        return
    state = load_state()
    rec = threads.get(tid) or state.get(tid)
    if rec is None:
        reply_error(rid, -32600, "no rollout found for thread id %s" % tid)
        return
    reported_model = params.get("model", rec.get("model"))
    if MODE == "resume_mismatch":
        reported_model = str(params.get("model")) + "-WRONG"
    threads[tid] = {"model": reported_model, "cwd": params.get("cwd", rec.get("cwd"))}
    reply(rid, {
        "thread": {"id": tid, "model": reported_model,
                    "cwd": params.get("cwd", rec.get("cwd")), "turns": []},
        "model": reported_model,
    })


def emit_progress_items(thread_id, turn_id):
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "commandExecution", "id": "cx1",
                                      "command": "ls -la"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "commandExecution", "id": "cx1",
                                        "command": "ls -la", "status": "completed"}})
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "fileChange", "id": "fc1"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "fileChange", "id": "fc1",
                                        "status": "completed"}})
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "mcpToolCall", "id": "mc1",
                                      "server": "srv", "tool": "tool1"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "mcpToolCall", "id": "mc1",
                                        "server": "srv", "tool": "tool1",
                                        "status": "completed"}})
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "webSearch", "id": "ws1",
                                      "query": "test query"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "webSearch", "id": "ws1",
                                        "query": "test query", "status": "completed"}})
    notify("item/agentMessage/delta", {"threadId": thread_id, "turnId": turn_id,
                                        "itemId": "am1", "delta": "P"})


def final_agent_message(prompt):
    return "STUB-REPLY:" + str(prompt)[:60]


def big_final_agent_message(prompt):
    base = "STUB-REPLY:" + str(prompt)[:40]
    return base * ((2 << 20) // len(base) + 1)


def handle_turn_start(msg):
    rid = msg.get("id")
    params = msg.get("params") or {}
    thread_id = params.get("threadId")
    turn_counter[0] += 1
    turn_id = "turn-%d" % turn_counter[0]
    text_input = ""
    inputs = params.get("input") or []
    if inputs and isinstance(inputs[0], dict):
        text_input = inputs[0].get("text", "")

    reply(rid, {"turn": {"id": turn_id, "items": [], "status": "inProgress"}})
    notify("turn/started", {"threadId": thread_id,
                             "turn": {"id": turn_id, "status": "inProgress"}})

    if MODE == "fail_turn":
        notify("turn/completed", {
            "threadId": thread_id,
            "turn": {"id": turn_id, "status": "failed",
                     "error": {"additionalDetails": "stub induced failure"},
                     "items": []},
        })
        return

    if MODE in ("cancel", "interrupt_fails", "interrupt_no_confirmation"):
        pending_interrupts[(thread_id, turn_id)] = rid
        return

    if MODE == "approval":
        approval_id = "approval-req-1"
        pending_approvals[approval_id] = (thread_id, turn_id, text_input)
        send({"id": approval_id, "method": "execCommandApproval",
              "params": {"callId": "c1", "command": ["ls"], "cwd": "/tmp",
                         "conversationId": thread_id, "parsedCmd": []}})
        return

    if MODE == "progress":
        emit_progress_items(thread_id, turn_id)

    text = (big_final_agent_message(text_input) if MODE == "big"
            else final_agent_message(text_input))
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "agentMessage", "id": "am1", "text": "",
                                      "phase": "final_answer"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "agentMessage", "id": "am1",
                                        "text": text, "phase": "final_answer"}})
    notify("turn/completed", {
        "threadId": thread_id,
        "turn": {"id": turn_id, "status": "completed",
                 "items": [{"type": "agentMessage", "id": "am1", "text": text,
                            "phase": "final_answer"}]},
    })
    if MODE == "rate_limits_notify":
        notify("account/rateLimits/updated", {"rateLimits": default_rate_limits()})


pending_approvals = {}
pending_interrupts = {}


def handle_turn_interrupt(msg):
    rid = msg.get("id")
    params = msg.get("params") or {}
    thread_id = params.get("threadId")
    turn_id = params.get("turnId")
    if MODE == "interrupt_fails":
        reply_error(rid, -32000, "stub induced interrupt failure")
        return
    reply(rid, {})
    key = (thread_id, turn_id)
    pending_interrupts.pop(key, None)
    if MODE == "interrupt_no_confirmation":
        return
    notify("turn/completed", {
        "threadId": thread_id,
        "turn": {"id": turn_id, "status": "interrupted", "items": []},
    })


def default_rate_limits():
    return {
        "limitId": "codex",
        "primary": {"usedPercent": 38, "resetsAt": 1790340325, "windowDurationMins": 300},
        "secondary": {"usedPercent": 12, "resetsAt": 1790842078, "windowDurationMins": 10080},
        "planType": "plus",
    }


def reached_rate_limits():
    return {
        "limitId": "codex",
        "primary": {"usedPercent": 100, "resetsAt": 1790340325, "windowDurationMins": 300},
        "secondary": {"usedPercent": 44, "resetsAt": 1790842078, "windowDurationMins": 10080},
        "planType": "plus",
        "rateLimitReachedType": "rate_limit_reached",
    }


def handle_rate_limits_read(msg):
    rid = msg.get("id")
    if MODE == "rate_limits_fail":
        reply_error(rid, -32000, "stub induced rate limit read failure")
        return
    if MODE in ("rate_limits_reached", "thread_start_fail", "resume_fail"):
        reply(rid, {"rateLimits": reached_rate_limits(), "ordinaryUsageAllowed": False})
        return
    reply(rid, {"rateLimits": default_rate_limits()})


def handle_approval_response(msg):
    rid = msg.get("id")
    entry = pending_approvals.pop(rid, None)
    if entry is None:
        return
    thread_id, turn_id, text_input = entry
    text = final_agent_message(text_input)
    notify("item/started", {"threadId": thread_id, "turnId": turn_id,
                             "item": {"type": "agentMessage", "id": "am1", "text": "",
                                      "phase": "final_answer"}})
    notify("item/completed", {"threadId": thread_id, "turnId": turn_id,
                               "item": {"type": "agentMessage", "id": "am1",
                                        "text": text, "phase": "final_answer"}})
    notify("turn/completed", {
        "threadId": thread_id,
        "turn": {"id": turn_id, "status": "completed",
                 "items": [{"type": "agentMessage", "id": "am1", "text": text,
                            "phase": "final_answer"}]},
    })


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        if MODE == "exit_after_init":
            time.sleep(0.05)
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if MODE == "exit_after_init" and msg.get("method") != "initialized":
            sys.stdout.flush()
            os._exit(0)
        method = msg.get("method")
        record_method(method)
        if method is None and "id" in msg:
            handle_approval_response(msg)
            continue
        if method == "initialize":
            handle_initialize(msg)
        elif method == "initialized":
            continue
        elif method == "thread/start":
            handle_thread_start(msg)
        elif method == "thread/resume":
            handle_thread_resume(msg)
        elif method == "turn/start":
            handle_turn_start(msg)
        elif method == "turn/interrupt":
            handle_turn_interrupt(msg)
        elif method == "account/rateLimits/read":
            handle_rate_limits_read(msg)
        elif msg.get("id") is not None:
            reply_error(msg.get("id"), -32600, "unknown method: %s" % method)
    return 0


if __name__ == "__main__":
    sys.exit(main())
