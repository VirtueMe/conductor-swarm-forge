#!/usr/bin/env python3
"""Run one prompt through `pi --mode rpc` and write what happened to a JSON file.

Used by adapter_dispatch in adapters/pi.sh. It only holds the protocol conversation,
which needs a clock and two-way traffic. Deciding what the outcome means (exit codes)
stays in the adapter.

    pi-rpc-run.py --prompt-file F --out F --deadline SECONDS [--grace SECONDS] -- [pi args]

The conversation: get_state, prompt, read events until agent_settled (not agent_end, which
can be followed by retries), then get_session_stats. If the deadline passes first it
sends abort and waits up to --grace seconds for the run to settle. Pi reports a failed
model call inside the run (the prompt is accepted and the run settles), so the last
assistant message's stopReason and errorMessage are recorded.

The output file holds: settled, aborted, deadline_hit, prompt_rejected, stop_reason,
error_message, auto_retry_failed, final_text, model, stats, pi_exit, stderr. The exit
status is 0 whenever the file was written; 3 means pi could not be started.
"""
import argparse
import json
import queue
import subprocess
import sys
import threading
import time


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt-file", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--deadline", type=float, required=True)
    ap.add_argument("--grace", type=float, default=5.0)
    ap.add_argument("pi_args", nargs="*")
    a = ap.parse_args()

    prompt = open(a.prompt_file).read()
    result = {
        "settled": False, "aborted": False, "deadline_hit": False, "prompt_rejected": None,
        "stop_reason": None, "error_message": None, "auto_retry_failed": None,
        "final_text": "", "model": None, "stats": None, "pi_exit": None, "stderr": "",
    }

    try:
        proc = subprocess.Popen(
            ["pi", "--mode", "rpc", "--no-session", "--no-context-files"] + a.pi_args,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as e:
        sys.stderr.write("pi-rpc-run: cannot start pi: %s\n" % e)
        return 3

    lines = queue.Queue()

    def read_stdout():
        for raw in proc.stdout:           # strict LF framing: split on b"\n" only
            lines.put(raw)
        lines.put(None)

    threading.Thread(target=read_stdout, daemon=True).start()
    stderr_buf = []
    threading.Thread(target=lambda: stderr_buf.append(proc.stderr.read()), daemon=True).start()

    def send(cmd):
        try:
            proc.stdin.write(json.dumps(cmd).encode() + b"\n")
            proc.stdin.flush()
        except (BrokenPipeError, OSError):
            pass

    def last_assistant_text(msg):
        return "".join(b.get("text", "") for b in msg.get("content", []) if b.get("type") == "text")

    def note_assistant(msg):
        result["stop_reason"] = msg.get("stopReason")
        result["error_message"] = msg.get("errorMessage")
        result["final_text"] = last_assistant_text(msg)

    start = time.time()
    send({"id": "state", "type": "get_state"})
    send({"id": "prompt", "type": "prompt", "message": prompt})

    abort_sent_at = None
    stats_requested = False
    stats_deadline = None

    while True:
        now = time.time()
        if not result["settled"] and abort_sent_at is None and now - start >= a.deadline:
            result["deadline_hit"] = True
            abort_sent_at = now
            send({"type": "abort"})
        if abort_sent_at is not None and not result["settled"] and now - abort_sent_at >= a.grace:
            break                          # did not settle after abort: give up
        if stats_deadline is not None and now >= stats_deadline:
            break

        try:
            raw = lines.get(timeout=0.2)
        except queue.Empty:
            continue
        if raw is None:
            break                          # pi closed its stdout
        try:
            r = json.loads(raw)
        except ValueError:
            continue
        t = r.get("type")

        if t == "response":
            if r.get("id") == "state" and r.get("success"):
                result["model"] = (r.get("data") or {}).get("model", {}).get("id")
            elif r.get("id") == "prompt" and not r.get("success"):
                result["prompt_rejected"] = r.get("error") or "the prompt was rejected"
                break
            elif r.get("id") == "stats":
                if r.get("success"):
                    result["stats"] = r.get("data")
                break
        elif t == "message_end":
            msg = r.get("message") or {}
            if msg.get("role") == "assistant":
                note_assistant(msg)
        elif t == "agent_end":
            msgs = [m for m in r.get("messages", []) if m.get("role") == "assistant"]
            if msgs:
                note_assistant(msgs[-1])
        elif t == "auto_retry_end" and not r.get("success"):
            result["auto_retry_failed"] = r.get("finalError") or "retries exhausted"
        elif t == "agent_settled":
            result["settled"] = True
            result["aborted"] = bool(r.get("aborted"))
            if not stats_requested:
                stats_requested = True
                stats_deadline = time.time() + 2.0
                send({"id": "stats", "type": "get_session_stats"})

    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    result["pi_exit"] = proc.returncode
    time.sleep(0.05)
    result["stderr"] = (stderr_buf[0].decode("utf-8", "replace")[:400] if stderr_buf else "")

    with open(a.out, "w") as f:
        json.dump(result, f)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
