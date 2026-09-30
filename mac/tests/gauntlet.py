#!/usr/bin/env python3
"""Survival tests for the macOS/Linux port. Runs against a throwaway LANES_HOME in /tmp; no API usage.

    python3 mac/tests/gauntlet.py [--only 1,4] [--flood-mb 20]
"""
import base64
import json
import os
import shutil
import signal
import socket
import sys
import tempfile
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MAC = os.path.dirname(HERE)
sys.path.insert(0, MAC)
SCRATCH = os.path.join(tempfile.gettempdir(), "lanes-gauntlet-%d" % os.getuid())
shutil.rmtree(SCRATCH, ignore_errors=True)
os.makedirs(SCRATCH)
os.environ["LANES_HOME"] = os.path.join(SCRATCH, "home")
os.environ["LANES_HEAD"] = "gauntlet"
for k in ("LANES_ROOT", "LANES_HEADS_ROOT", "LANES_LANE", "LANES_CONSUMER"):
    os.environ.pop(k, None)

import lane as L  # noqa: E402
import lanes_common as lc  # noqa: E402

args = sys.argv[1:]
ONLY = set(int(x) for x in args[args.index("--only") + 1].split(",")) if "--only" in args else set()
FLOOD_MB = int(args[args.index("--flood-mb") + 1]) if "--flood-mb" in args else 20
Q = os.path.join(lc.heads_root(), "gauntlet", "events.jsonl")
os.makedirs(os.path.dirname(Q), exist_ok=True)
open(Q, "a").close()
results = []


def run(n):
    return not ONLY or n in ONLY


def result(n, name, ok, evidence):
    results.append(ok)
    print("%s T%d %s — %s" % ("PASS" if ok else "FAIL", n, name, evidence), flush=True)


def rows(lane=""):
    if not os.path.exists(Q):
        return []
    out = [json.loads(l) for l in open(Q, encoding="utf-8") if l.strip()]
    return [r for r in out if not lane or r["lane"] == lane]


def wait_event(lane, state, sec=30, why=""):
    end = time.time() + sec
    while time.time() < end:
        r = [x for x in rows(lane) if x["state"] == state and (not why or x["why"] == why)]
        if r:
            return r[-1]
        time.sleep(0.25)
    return None


def cleanup(*names):
    for n in names:
        try:
            st = L.get_state(n)
            if st and st.get("alive"):
                L.stop_lane(n, hard=True, force=True)
        except Exception:
            pass
        shutil.rmtree(os.path.join(lc.lanes_root(), n), ignore_errors=True)


def sh(cmd):
    return "sh -c " + L.shlex.quote(cmd)


try:
    if run(1):
        lines = FLOOD_MB * 10000   # ~100 bytes per line
        st = L.start_lane("g-flood", kind="other", command=sh("i=0; while [ $i -lt %d ]; do printf 'line %%08d %s\\n' $i; i=$((i+1)); done" % (lines, "x" * 80)), cwd=SCRATCH)
        fin = wait_event("g-flood", "finished", 600)
        text = open(os.path.join(lc.lanes_root(), "g-flood", "console.log"), "rb").read().decode("utf-8", "replace")
        seen = set(int(p[5:13]) for p in text.split("\n") if p.startswith("line ") and len(p) > 13 and p[5:13].isdigit())
        missing = lines - len(seen)
        result(1, "%d MB flood" % FLOOD_MB, fin is not None and missing == 0, "lines %d, distinct seen %d, missing %d, final %s" % (lines, len(seen), missing, fin and fin["why"]))
        cleanup("g-flood")

    if run(2):
        t0 = time.time()
        L.start_lane("g-yesno", kind="other", command=sh("printf 'Delete the old builds? (y/n): '; read a; echo answer=$a"), cwd=SCRATCH)
        ev = wait_event("g-yesno", "needs-input", 20)
        L.send_lane("g-yesno", text=["y"])
        fin = wait_event("g-yesno", "finished", 20)
        tail = L.read_lane("g-yesno", tail=6)
        result(2, "yes/no question (generic CLI)", ev is not None and fin is not None and "answer=y" in tail,
               "needs-input after %.1f s, label %r; finished=%s" % ((lc.parse_iso(ev["ts"]).timestamp() - t0) if ev else -1, ev and ev["label"], fin is not None))
        cleanup("g-yesno")

    if run(3):
        # A fake CLI that speaks the Claude hook protocol: proves hook -> host wake -> turn-complete label, then a question.
        fake = os.path.join(SCRATCH, "fakeclaude.sh")
        with open(fake, "w") as f:
            f.write('#!/bin/sh\n'
                    'H="%s %s hook $LANES_LANE_DIR"\n'
                    'echo "working..."\n'
                    'echo \'{"hook_event_name":"Stop","session_id":"sess-1","last_assistant_message":"All done: 3 files changed"}\' | $H\n'
                    'read line\n'
                    'echo \'{"hook_event_name":"UserPromptSubmit"}\' | $H\n'
                    'echo "got: $line"\n'
                    'echo \'{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which plan?","options":[{"label":"Plan A"},{"label":"Plan B"}]}]}}\' | $H\n'
                    'read choice\n'
                    'echo "chose $choice"\n' % (L.PY, L.HOST))
        os.chmod(fake, 0o755)
        L.start_lane("g-hooks", kind="other", command=fake, cwd=SCRATCH)
        tc = wait_event("g-hooks", "needs-input", 20, "turn-complete")
        L.send_lane("g-hooks", text=["next task"])
        q = wait_event("g-hooks", "needs-input", 20, "question")
        L.send_lane("g-hooks", text=["2"])
        fin = wait_event("g-hooks", "finished", 20)
        st = L.get_state("g-hooks")
        ok = tc is not None and tc["label"] == "All done: 3 files changed" and q is not None and "Which plan? [1] Plan A [2] Plan B" in q["label"] \
            and fin is not None and st.get("sessionId") == "sess-1"
        result(3, "hook protocol: Stop -> turn-complete, AskUserQuestion -> question", ok,
               "turn label %r; question %r; finished=%s; session %s" % (tc and tc["label"], q and q["label"], fin is not None, st.get("sessionId")))
        cleanup("g-hooks")

    if run(4):
        names = ["g-ten-%d" % i for i in range(10)]
        go = time.time() + 4
        for n in names:
            L.start_lane(n, kind="other", command=sh("while [ $(date +%%s) -lt %d ]; do sleep 0.05; done; echo done-%s" % (int(go) + 1, n)), cwd=SCRATCH)
        end = time.time() + 30
        while time.time() < end and len([r for r in rows() if r["lane"] in names and r["state"] == "finished"]) < 10:
            time.sleep(0.25)
        fin = [r for r in rows() if r["lane"] in names and r["state"] == "finished"]
        drained = L.get_events(drain=True)
        result(4, "ten lanes finishing within the same second", len(set(r["lane"] for r in fin)) == 10 and not any("\x1b" in l for l in drained),
               "finished rows %d (distinct %d); drain returned %d label lines, no escape codes" % (len(fin), len(set(r["lane"] for r in fin)), len(drained)))
        cleanup(*names)

    if run(5):
        L.start_lane("g-hostkill", kind="other", command=sh("sleep 300"), cwd=SCRATCH)
        st = L.get_state("g-hostkill")
        os.kill(int(st["hostPid"]), signal.SIGKILL)
        time.sleep(0.5)
        st2 = L.get_state("g-hostkill")
        L.get_lanes()
        lost = [r for r in rows("g-hostkill") if r["why"] == "host-lost"]
        result(5, "host killed: registry says died/host-lost, exactly one event", st2["state"] == "died" and st2["why"] == "host-lost" and len(lost) == 1,
               "state %s/%s alive=%s, host-lost events %d" % (st2["state"], st2["why"], st2["alive"], len(lost)))
        try:
            os.killpg(int(st["pid"]), signal.SIGKILL)
        except OSError:
            pass
        cleanup("g-hostkill")

    if run(6):
        L.start_lane("g-echo", kind="other", command="cat", cwd=SCRATCH)
        time.sleep(0.5)
        msgs = ["message-%d-%s" % (i, "abc" * 40) for i in range(5)]
        for m in msgs:
            L.send_lane("g-echo", text=[m])
        time.sleep(1)
        raw = L.read_lane("g-echo", raw=True)
        order = [raw.find(m) for m in msgs]
        result(6, "five sends arrive whole and in order", all(o >= 0 for o in order) and order == sorted(order), "positions %s" % order)
        cleanup("g-echo")

    if run(7):
        L.start_lane("g-reuse", kind="other", command=sh("echo OLD-GENERATION-MARKER; sleep 300"), cwd=SCRATCH)
        time.sleep(0.8)
        L.stop_lane("g-reuse", hard=True, force=True)
        old = open(os.path.join(lc.lanes_root(), "g-reuse", "console.log"), "rb").read()
        L.start_lane("g-reuse", kind="other", command=sh("echo NEW-GENERATION-MARKER; sleep 1"), cwd=SCRATCH)
        time.sleep(1.5)
        hist = os.path.join(lc.lanes_root(), "g-reuse", "history")
        gens = os.listdir(hist) if os.path.isdir(hist) else []
        moved = open(os.path.join(hist, gens[0], "console.log"), "rb").read() if gens else b""
        new = open(os.path.join(lc.lanes_root(), "g-reuse", "console.log"), "rb").read()
        result(7, "lane name reused: old transcript preserved byte-identical", moved == old and b"NEW-GENERATION" in new and b"OLD-GENERATION" not in new,
               "history gens %d, identical %s, new fresh %s" % (len(gens), moved == old, b"OLD-GENERATION" not in new))
        cleanup("g-reuse")

    if run(8):
        L.start_lane("g-restart", kind="other", command=sh("echo gen; sleep 300"), cwd=SCRATCH)
        time.sleep(0.8)
        st = L.get_state("g-restart")
        os.killpg(int(st["pid"]), signal.SIGKILL)
        died = wait_event("g-restart", "died", 15)
        st2 = L.restart_lane("g-restart")
        time.sleep(0.8)
        log = open(os.path.join(lc.lanes_root(), "g-restart", "console.log"), "rb").read()
        starts = log.count(b"LANE g-restart START")
        result(8, "child killed -> DIED; restart appends a second generation", died is not None and st2["alive"] and starts == 2,
               "died %s (%s); restarted pid %s -> %s; generations in one transcript: %d" % (died is not None, died and died["why"], st["pid"], st2["pid"], starts))
        cleanup("g-restart")

    if run(9):
        L.get_events(drain=True)
        names = ["g-mix-%02d" % i for i in range(25)]
        for n in names:
            L.start_lane(n, kind="other", command=sh("printf 'Continue? (y/n) '; read a; echo ok"), cwd=SCRATCH)
        end = time.time() + 40
        while time.time() < end and len([r for r in rows() if r["lane"] in names and r["state"] == "needs-input"]) < 25:
            time.sleep(0.25)
        for n in names:
            L.send_lane(n, text=["y"])
        end = time.time() + 30
        while time.time() < end and len([r for r in rows() if r["lane"] in names and r["state"] == "finished"]) < 25:
            time.sleep(0.25)
        drained = L.get_events(drain=True)
        chars = sum(len(l) for l in drained)
        result(9, "head drains 50 mixed events, labels only", len(drained) == 50 and not any("\x1b" in l for l in drained),
               "drained %d rows, %d chars total, max line %d" % (len(drained), chars, max((len(l) for l in drained), default=0)))
        cleanup(*names)

    if run(10):
        L.start_lane("g-stall", kind="other", command=sh("echo starting; sleep 10; echo awake"), cwd=SCRATCH, stall_seconds=5)
        stalled = wait_event("g-stall", "stalled", 15)
        fin = wait_event("g-stall", "finished", 15)
        result(10, "STALLED fires on silence, FINISHED after", stalled is not None and fin is not None, "stalled %s (%s); finished %s" % (stalled is not None, stalled and stalled["why"], fin is not None))
        cleanup("g-stall")

    if run(12):
        os.environ["LANES_HEAD"] = "user"
        L.start_lane("g-head-a", kind="other", command="cat", cwd=SCRATCH, is_head=True)
        L.start_lane("g-head-b", kind="other", command="cat", cwd=SCRATCH, is_head=True)
        third = None
        try:
            L.start_lane("g-head-c", kind="other", command="cat", cwd=SCRATCH, is_head=True)
        except L.LaneError as e:
            third = str(e)
        os.environ["LANES_HEAD"] = "g-head-a"
        L.start_lane("g-worker-a", kind="other", command="cat", cwd=SCRATCH)
        wa = L.get_state("g-worker-a")
        os.environ["LANES_HEAD"] = "g-head-b"
        refused = None
        try:
            L.send_lane("g-worker-a", text=["b-drove-a"])
        except L.LaneError as e:
            refused = str(e)
        L.send_lane("g-head-a", text=["hello from b"])
        time.sleep(1)
        a_tail = L.read_lane("g-head-a", tail=3)
        os.environ["LANES_HEAD"] = "gauntlet"
        ok = third is not None and "LANES_MAX_HEADS" in third and wa["head"] == "g-head-a" and refused is not None and "hello from b" in a_tail
        result(12, "two heads max; a head drives only its own lanes, messages the other's inbox", ok,
               "third refused %s; worker owner %s; cross-drive refused %s; inbox delivered %s" % (third is not None, wa["head"], refused is not None, "hello from b" in a_tail))
        cleanup("g-worker-a", "g-head-a", "g-head-b", "g-head-c")

    if run(13):
        L.start_lane("g-cons", kind="other", command=sh("printf 'Go? (y/n) '; read a"), cwd=SCRATCH)
        L.get_events(consumer="alpha")   # both consumers start now
        L.get_events(consumer="beta")
        L.send_lane("g-cons", text=["y"])
        wait_event("g-cons", "finished", 15)
        a1, b1 = L.get_events(drain=True, consumer="alpha", as_object=True), L.get_events(drain=True, consumer="beta", as_object=True)
        a2, b2 = L.get_events(drain=True, consumer="alpha", as_object=True), L.get_events(drain=True, consumer="beta", as_object=True)
        result(13, "two consumers of one queue each see every event once", len(a1) == len(b1) and len(a1) > 0 and not a2 and not b2,
               "first drains %d/%d, second drains %d/%d" % (len(a1), len(b1), len(a2), len(b2)))
        cleanup("g-cons")

    if run(14):
        L.start_lane("g-view", kind="other", command="cat", cwd=SCRATCH)
        port = 17342
        L.start_viewer(port)
        time.sleep(1.0)
        lanes = json.loads(urllib.request.urlopen("http://127.0.0.1:%d/api/lanes" % port, timeout=5).read())
        page = urllib.request.urlopen("http://127.0.0.1:%d/" % port, timeout=5).read()
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET /ws/g-view?tail=4096 HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
                   "Sec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        hs = s.recv(4096)
        payload = b"typed-through-websocket\r"
        mask = os.urandom(4)
        s.sendall(bytes([0x82, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        got, end = b"", time.time() + 5
        while time.time() < end and b"typed-through-websocket" not in got:
            try:
                got += s.recv(65536)
            except socket.timeout:
                break
        s.close()
        pid = open(os.path.join(lc.lanes_root(), "_viewer.pid")).read().strip()
        os.kill(int(pid), signal.SIGTERM)
        ok = any(x["name"] == "g-view" for x in lanes) and b"Lanes Harness" in page and b" 101 " in hs and b"typed-through-websocket" in got
        result(14, "browser viewer: /api/lanes, page, WebSocket typing round trip", ok,
               "api lanes %d, page ok %s, ws 101 %s, echo seen %s" % (len(lanes), b"Lanes Harness" in page, b" 101 " in hs, b"typed-through-websocket" in got))
        cleanup("g-view")
finally:
    for n in os.listdir(lc.lanes_root()) if os.path.isdir(lc.lanes_root()) else []:
        if n.startswith("g-"):
            cleanup(n)

failed = results.count(False)
print("%d tests, %d failed" % (len(results), failed))
sys.exit(1 if failed else 0)
