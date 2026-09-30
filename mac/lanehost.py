#!/usr/bin/env python3
"""LaneHost for macOS/Linux: the per-lane pseudoterminal owner of Lanes Harness.

One process per lane. It opens a pty, runs the real CLI (claude / codex / grok / cursor-agent / anything)
inside it, tees every byte to <laneDir>/console.log, keeps <laneDir>/state.json current, serves a Unix
socket so the head agent, an attached terminal and the web viewer can type into the same session, and
appends a labelled event row to the owning head's queue when the lane needs input, finishes, stalls or dies.

Verbs:
  lanehost.py run --name N --dir D --cwd C --argv-json '[...]' [--cols 160 --rows 45 --head H --kind K ...]
  lanehost.py hook <laneDir> [json]      claude hook / codex notify target (payload on stdin or as an argument)
  lanehost.py grok-hook                  Grok lifecycle hook; inert outside a lane
  lanehost.py attach <name> [--tail-bytes N]
  lanehost.py serve [--port 7342] [--www DIR]
"""
import json
import os
import re
import select
import shutil
import signal
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lanes_common as lc  # noqa: E402

PROMPT_RX = (r"(\?\s*$)|(\(y/n\)|\[y/n\]|\[Y/n\]|\(y/N\)|yes/no)|(Do you want to|Would you like to|Press Enter|press enter|to continue)"
             r"|(❯\s*\d\.)|(^\s*>\s*$)|(^\s*[›>$#%]\s*$)|(\? for shortcuts)|(⏎ send)|(Esc to cancel)|(esc to cancel)"
             r"|(Enter to select)|(Enter to confirm)|(enter to confirm)|(\(Y\)es|\(N\)o)|(→ Add a follow-up)"
             r"|(^\S+@\S+ .{0,60}[%$#] ?$)|(^\S+@\S+:\S*[$#] ?$)")   # zsh and bash default prompts
RUNNING_RX = (r"(esc to interrupt)|(Esc to interrupt)|(⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)|(✻|✽|✶|✳|✢|·) (Thinking|Working|Running|Baking|Brewing"
              r"|Cooking|Computing|Crunching|Deliberating|Pondering|Processing|Reasoning|Musing|Cogitating|Noodling|Simmering"
              r"|Percolating|Mulling|Churning|Finagling|Hatching|Forging|Schlepping|Wibbling|Wrangling|Frolicking|Smooshing"
              r"|Herding|Synthesizing|Vibing|Sparkling|Moseying|Puttering|Shimmying|Honking|Jiving|Sprouting|Stewing|Ruminating|Contemplating)")
ERROR_RX = (r"(API Error: 5\d\d)|(overloaded_error)|(Overloaded)|(rate_limit)|(ECONNRESET)|(fatal error)|(Unhandled exception)"
            r"|(panicked at)|(out of memory)|(Segmentation fault)|(\berror\b.*\b(529|503|500)\b)")
QUESTION_RX = re.compile(r"(\?\s*$)|(Do you want|Would you like|Yes, |No, |\(y/n\)|\[Y/n\]|\(Y\)es|❯ \d\.|Enter to (select|confirm|continue)"
                         r"|Press Enter|Esc to cancel|esc to cancel|Tab to|to proceed)", re.M)
CURSOR_CHROME_RX = re.compile(r"Add a follow-up|Run Everything|ctrl\+c to stop|^\s*Tip:|^[⠀-⣿\s]*Working\b"
                              r"|Working\s+\d+ tokens|^\s*~/|^\s*/", re.I)
BP_ON, BP_OFF = b"\x1b[?2004h", b"\x1b[?2004l"
TAIL_MAX = 32768
SUB_MAX_PENDING = 8 * 1024 * 1024


def _gs(o, *keys):
    """First non-empty string among keys of dict o."""
    if not isinstance(o, dict):
        return None
    for k in keys:
        v = o.get(k)
        if isinstance(v, str) and v:
            return v
    return None


class Subscriber:
    def __init__(self, conn):
        self.conn = conn
        self.cond = threading.Condition()
        self.queue = []
        self.pending = 0
        self.dropped = 0
        self.dead = False

    def push(self, ftype, data):
        with self.cond:
            if self.dead:
                return
            if self.pending + len(data) > SUB_MAX_PENDING and ftype == lc.OUTPUT:
                self.dropped += len(data)
                return
            self.queue.append((ftype, data))
            self.pending += len(data)
            self.cond.notify()

    def pump(self):
        try:
            while True:
                with self.cond:
                    while not self.queue and not self.dead:
                        self.cond.wait()
                    if self.dead and not self.queue:
                        return
                    items, self.queue, self.pending = self.queue, [], 0
                    dropped, self.dropped = self.dropped, 0
                if dropped:
                    lc.write_frame(self.conn, lc.GAP, str(dropped).encode())
                for ftype, data in items:
                    lc.write_frame(self.conn, ftype, data)
                    if ftype == lc.EXIT:
                        return
        except OSError:
            pass
        finally:
            with self.cond:
                self.dead = True


class Host:
    def __init__(self, a):
        self.name = a["name"]
        self.lane_dir = a["dir"]
        self.cwd = a.get("cwd") or os.getcwd()
        self.argv = json.loads(a["argv-json"])
        self.cmdline = a.get("cmdline") or " ".join(self.argv)
        self.cols, self.rows = int(a.get("cols", 160)), int(a.get("rows", 45))
        self.head = a.get("head") or "user"
        self.kind = a.get("kind") or "other"
        self.model = a.get("model", "")
        self.brief = a.get("brief", "")
        self.session_id = a.get("session", "")
        self.stall_sec = int(a.get("stall-sec") or int(a.get("stall-min", 10)) * 60)
        self.stall_min = int(a.get("stall-min", 10))
        self.quiet_sec = int(a.get("quiet-sec", 4))
        self.meta = json.loads(a["meta-json"]) if a.get("meta-json") else None
        self.restart_of = a.get("restart-of", "")
        self.restart_count = int(a.get("restart-count") or 0)
        self.events_path = a.get("events") or os.path.join(lc.heads_root(), self.head, "events.jsonl")
        self.launch_id = a.get("launch-id", "")
        self.hooks_path = os.path.join(self.lane_dir, "hooks.jsonl")
        self.sock = lc.sock_path(self.lane_dir)

        self.state, self.why, self.label = "starting", "", ""
        self.exit_code, self.exited = 0, False
        self.bytes = 0
        self.episode_start = 0
        self.child = 0
        self.master = -1
        self.started = lc.now_iso()
        self.host_start = self.started
        self.last_output_iso = self.started
        self.last_output = time.monotonic()
        self.last_state_change = time.monotonic()
        self.log_lock = threading.Lock()
        self.input_lock = threading.Lock()
        self.tail = bytearray()
        self.subs = []
        self.hooks_read = 0
        self.last_assistant = ""
        self.transcript = ""
        self.session_seen = ""
        self.pending_input = False
        self.hook_turn_done = False
        self.hook_seen = False
        self.idle_at_prompt = False
        self.stalled_reported = False
        self.bracketed = False
        self.wake = threading.Event()
        self.event_n = 0
        self.prompt_rx = re.compile(PROMPT_RX, re.M)
        self.running_rx = re.compile(RUNNING_RX, re.M)
        self.error_rx = re.compile(ERROR_RX, re.M)
        self._load_patterns()

    def _load_patterns(self):
        pf = os.path.join(os.path.dirname(os.path.abspath(__file__)), "patterns.json")
        try:
            with open(pf, encoding="utf-8") as f:
                d = json.load(f)
            if d.get("prompt"):
                self.prompt_rx = re.compile(d["prompt"], re.M)
            if d.get("running"):
                self.running_rx = re.compile(d["running"], re.M)
            if d.get("error"):
                self.error_rx = re.compile(d["error"], re.M)
        except Exception:
            pass

    # ---- lifecycle ---------------------------------------------------------------------------------

    def main(self):
        os.makedirs(self.lane_dir, exist_ok=True)
        os.makedirs(os.path.dirname(self.events_path), exist_ok=True)
        try:
            os.remove(self.hooks_path)   # an older generation's hooks must not replay
        except FileNotFoundError:
            pass
        log_path = os.path.join(self.lane_dir, "console.log")
        self.log = open(log_path, "ab", buffering=0)
        self.bytes = os.path.getsize(log_path)   # a restart appends to the preserved transcript
        self.episode_start = self.bytes

        env = dict(os.environ)
        env.update(LANES_LANE=self.name, LANES_LANE_DIR=self.lane_dir, LANES_LANE_HEAD=self.head,
                   TERM="xterm-256color", COLORTERM="truecolor")
        env.setdefault("LANES_HEAD", self.head)

        exe = self.argv[0] if os.path.sep in self.argv[0] else shutil.which(self.argv[0], path=env.get("PATH"))
        if not exe or not os.access(exe, os.X_OK) or not os.path.isdir(self.cwd):
            self.state, self.why = "died", "spawn-failed"
            self.label = ("cwd does not exist: " + self.cwd) if not os.path.isdir(self.cwd) else ("command not found: " + self.argv[0])
            self.write_state()
            self.emit("died")
            return 3

        import pty
        pid, fd = pty.fork()
        if pid == 0:   # child: its stdin is the pty slave
            try:
                import fcntl
                import termios
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", self.rows, self.cols, 0, 0))
                os.chdir(self.cwd)
                os.execve(exe, self.argv, env)
            except Exception as e:
                os.write(2, ("exec failed: %s\r\n" % e).encode())
            os._exit(127)
        self.child, self.master = pid, fd
        self._set_winsize(self.cols, self.rows)
        self.log_marker("LANE %s START pid=%d model=%s cwd=%s cmd=%s" % (self.name, pid, self.model, self.cwd, self.cmdline))
        self.state, self.why = "running", "launched"
        self.last_state_change = time.monotonic()
        self.write_state()

        out = threading.Thread(target=self.output_loop, daemon=True)
        out.start()
        threading.Thread(target=self.accept_loop, daemon=True).start()
        threading.Thread(target=self.watch, daemon=True).start()

        _, status = os.waitpid(pid, 0)
        if os.WIFEXITED(status):
            self.exit_code = os.WEXITSTATUS(status)
        elif os.WIFSIGNALED(status):
            self.exit_code = 128 + os.WTERMSIG(status)
        self.exited = True
        out.join(10)   # read what the child left in the pty before labelling the exit
        tail_text = self.tail_text()
        errorish = bool(self.error_rx.search(tail_text))
        fin = "finished" if self.exit_code == 0 and not errorish else "died"
        screen = " | ".join(lc.tail_lines(tail_text, 4))
        lbl = self.last_assistant if (fin == "finished" and self.last_assistant) else screen
        why = ("exit-0-with-error" if errorish else "exit-0") if self.exit_code == 0 else "exit-%d" % self.exit_code
        self.set_state(fin, why, lc.truncate(lbl, 400), True)
        self.log_marker("LANE %s EXIT code=%d state=%s" % (self.name, self.exit_code, fin))
        for s in list(self.subs):
            s.push(lc.EXIT, str(self.exit_code).encode())
        time.sleep(0.3)
        try:
            os.close(self.master)
        except OSError:
            pass
        try:
            os.remove(self.sock)
        except OSError:
            pass
        self.log.close()
        return 0

    def _set_winsize(self, cols, rows):
        import fcntl
        import termios
        try:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            self.cols, self.rows = cols, rows
        except OSError:
            pass

    def log_marker(self, text):
        b = ("\r\n\x1b[2m[%s %s]\x1b[0m\r\n" % (lc.now_iso()[:23] + "Z", text)).encode("utf-8")
        with self.log_lock:
            try:
                self.log.write(b)
                self.bytes += len(b)
            except OSError:
                pass

    # ---- output --------------------------------------------------------------------------------------

    def output_loop(self):
        while True:
            try:
                r, _, _ = select.select([self.master], [], [], 1.0)
                if not r:
                    if self.exited:
                        break
                    continue
                buf = os.read(self.master, 65536)
            except OSError:
                break   # EIO: the child side closed
            if not buf:
                break
            with self.log_lock:
                try:
                    self.log.write(buf)
                    self.bytes += len(buf)
                except OSError:
                    pass
                self.tail += buf
                if len(self.tail) > TAIL_MAX:
                    del self.tail[: len(self.tail) - TAIL_MAX]
                for s in self.subs:
                    s.push(lc.OUTPUT, buf)
            self.last_output = time.monotonic()
            self.last_output_iso = lc.now_iso()
            on, off = buf.rfind(BP_ON), buf.rfind(BP_OFF)
            if on >= 0 or off >= 0:
                self.bracketed = on > off
            if self.pending_input:
                self.pending_input = False
                self.hook_turn_done = False
                if self.state in ("needs-input", "stalled"):
                    self.set_state("running", "input", "", False)
            elif self.state == "stalled":
                self.set_state("running", "output-resumed", "", False)

    def tail_text(self):
        with self.log_lock:
            data = bytes(self.tail)
        return lc.strip_vt(data.decode("utf-8", "replace"))

    # ---- input ---------------------------------------------------------------------------------------

    def write_input(self, data):
        if not data:
            return
        with self.input_lock:
            try:
                os.write(self.master, data)
            except OSError:
                pass
            self.pending_input = True

    def write_paste(self, text):
        """One message, one lock: the text (bracketed if the CLI asked for it), a short settle, then Enter."""
        submit = text.endswith(b"\r")
        body = text[:-1] if submit else text
        with self.input_lock:
            try:
                if body:
                    os.write(self.master, (b"\x1b[200~" + body + b"\x1b[201~") if self.bracketed else body)
                if submit:
                    if body:
                        time.sleep(0.12 if self.bracketed else 0.04)
                    os.write(self.master, b"\r")
            except OSError:
                pass
            self.pending_input = True

    # ---- state ---------------------------------------------------------------------------------------

    def set_state(self, st, why, label, emit):
        changed = st != self.state or why != self.why
        self.state, self.why, self.label = st, why, label or ""
        self.last_state_change = time.monotonic()
        self.write_state()
        if emit and changed:
            self.emit(st)
        if st == "running":
            self.episode_start = self.bytes

    def write_state(self):
        d = dict(name=self.name, head=self.head, kind=self.kind, model=self.model, cwd=self.cwd, cmd=self.cmdline,
                 brief=self.brief, pid=self.child, hostPid=os.getpid(), hostStart=self.host_start, started=self.started,
                 lastOutputAt=self.last_output_iso, bytes=self.bytes, state=self.state, why=self.why, label=self.label,
                 exitCode=self.exit_code if self.exited else None, sessionId=self.session_seen or self.session_id,
                 transcript=self.transcript, sock=self.sock, cols=self.cols, rows=self.rows, restartOf=self.restart_of,
                 restartCount=self.restart_count, episodeStart=self.episode_start, viewers=len(self.subs),
                 updated=lc.now_iso(), launchId=self.launch_id)
        if self.meta is not None:
            d["meta"] = self.meta
        try:
            lc.write_json(os.path.join(self.lane_dir, "state.json"), d)
        except OSError:
            pass

    def emit(self, st):
        self.event_n += 1
        row = dict(ts=lc.now_iso(), head=self.head, lane=self.name, state=st, why=self.why, label=self.label,
                   **{"from": self.episode_start}, to=self.bytes, pid=self.child, exit=self.exit_code if self.exited else None,
                   kind=self.kind, model=self.model, cwd=self.cwd, hostPid=os.getpid(), n=self.event_n)
        lc.append_line(self.events_path, json.dumps(row, ensure_ascii=False, separators=(",", ":")))

    # ---- watcher: hooks, quiescence, stall -------------------------------------------------------------

    def watch(self):
        tick = 0
        while not self.exited:
            woken = self.wake.wait(1.0)
            self.wake.clear()
            tick += 1
            try:
                self.poll_hooks()
            except Exception:
                pass
            if woken and self.hook_turn_done:
                time.sleep(1.0)   # let the CLI finish painting after its Stop hook
            if self.exited:
                break
            try:
                self._tick()
            except Exception:
                pass
            if self.state != "stalled":
                self.stalled_reported = False
            if tick % 3 == 0:
                self.write_state()

    def _tick(self):
        quiet = time.monotonic() - self.last_output
        since_change = time.monotonic() - self.last_state_change
        if self.state != "running":
            return
        if self.hook_turn_done and quiet >= 1.0:
            self.hook_turn_done = False
            self.set_state("needs-input", "turn-complete", lc.truncate(self.last_assistant or self.question_from_tail(), 400), True)
        elif self.idle_at_prompt and not self.hook_turn_done and quiet >= self.quiet_sec and since_change > self.quiet_sec:
            self.set_state("needs-input", "turn-complete", lc.truncate(self.last_assistant or self.question_from_tail(), 400), False)
        elif quiet >= self.quiet_sec and not self.hook_seen:
            t = self.tail_text()
            lines = lc.tail_lines(t, 6)
            last = lines[-1] if lines else ""
            joined = "\n".join(lines)
            cursor_busy = False
            if self.kind == "cursor":
                # Cursor keeps "→ Add a follow-up" on screen while it works; the busy frame also says "ctrl+c to stop".
                for line in reversed(lines):
                    if "Add a follow-up" in line:
                        cursor_busy = "ctrl+c to stop" in line.lower()
                        break
            if self.prompt_rx.search(joined) and not self.running_rx.search(last) and not cursor_busy:
                lbl = self.cursor_reply(t) if self.kind == "cursor" else joined
                self.set_state("needs-input", "prompt", lc.truncate(lbl, 400), True)
        elif quiet >= self.quiet_sec and self.hook_seen and since_change > self.quiet_sec:
            t = self.tail_text()
            lines = lc.tail_lines(t, 8)
            if QUESTION_RX.search("\n".join(lines)) and not self.running_rx.search(lines[-1] if lines else ""):
                self.set_state("needs-input", "question", lc.truncate(self.question_from_tail(), 400), True)
        if self.state == "running" and quiet >= self.stall_sec and not self.stalled_reported:
            self.stalled_reported = True
            span = "%dm" % (self.stall_sec // 60) if self.stall_sec % 60 == 0 else "%ds" % self.stall_sec
            self.set_state("stalled", "no-output-" + span, lc.truncate(" | ".join(lc.tail_lines(self.tail_text(), 2)), 200), True)

    def question_from_tail(self):
        lines = lc.tail_lines(self.tail_text(), 10)
        for i in range(len(lines) - 1, -1, -1):
            if "?" in lines[i]:
                return " | ".join(lines[max(0, i - 2):])
        return " | ".join(lines)

    @staticmethod
    def cursor_reply(t):
        keep = [s for s in (l.strip() for l in lc.tail_lines(t, 20)) if s and not CURSOR_CHROME_RX.search(s)]
        return " | ".join(keep[-3:]) if keep else " | ".join(lc.tail_lines(t, 4))

    def poll_hooks(self):
        try:
            size = os.path.getsize(self.hooks_path)
        except OSError:
            return
        if size <= self.hooks_read:
            return
        with open(self.hooks_path, "rb") as f:
            f.seek(self.hooks_read)
            chunk = f.read(size - self.hooks_read)
        nl = chunk.rfind(b"\n")
        if nl < 0:
            return
        self.hooks_read += nl + 1
        for line in chunk[: nl + 1].decode("utf-8", "replace").split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            self.on_hook(o)

    def on_hook(self, o):
        self.hook_seen = True
        ev = _gs(o, "hook_event_name", "hookEventName") or ""
        key = ev.replace("_", "").replace("-", "").lower()
        ty = _gs(o, "type")
        sid = _gs(o, "session_id", "sessionId")
        if sid:
            self.session_seen = sid
        tp = _gs(o, "transcript_path", "transcriptPath")
        if tp:
            self.transcript = tp
        tid = _gs(o, "thread-id", "thread_id")
        if tid:
            self.session_seen = tid
        tool = _gs(o, "tool_name", "toolName") or ""
        if key == "stop":
            m = _gs(o, "last_assistant_message", "lastAssistantMessage") or self.last_assistant_from_transcript()
            self.last_assistant = m or ""
            self.hook_turn_done = self.idle_at_prompt = True
        elif ty == "agent-turn-complete":
            self.last_assistant = _gs(o, "last-assistant-message", "last_assistant_message") or ""
            self.hook_turn_done = self.idle_at_prompt = True
        elif key == "notification":
            nt = _gs(o, "notification_type", "notificationType")
            msg = _gs(o, "message") or ""
            if nt in ("permission_prompt", "elicitation_dialog", "idle_prompt"):
                if self.state == "running" or (self.state == "needs-input" and self.why == "turn-complete"):
                    self.set_state("needs-input", "idle" if nt == "idle_prompt" else "permission",
                                   lc.truncate(msg or self.question_from_tail(), 400), True)
        elif key == "permissionrequest":
            ti = o.get("tool_input") or o.get("toolInput") or ""
            if not isinstance(ti, str):
                ti = json.dumps(ti)
            if self.state == "running":
                self.set_state("needs-input", "permission", lc.truncate("Permission: %s %s" % (tool, ti), 400), True)
        elif key == "pretooluse" and tool == "AskUserQuestion":
            self.idle_at_prompt = False
            ti = o.get("tool_input") or o.get("toolInput") or {}
            parts = []
            for q in (ti.get("questions") or []) if isinstance(ti, dict) else []:
                s = q.get("question") or ""
                for k, op in enumerate(q.get("options") or [], 1):
                    s += " [%d] %s" % (k, op.get("label", "") if isinstance(op, dict) else op)
                parts.append(s + " ‖ ")
            self.set_state("needs-input", "question", lc.truncate("".join(parts), 400), True)
        elif key == "posttooluse" and tool == "AskUserQuestion":
            if self.state == "needs-input":
                self.set_state("running", "answered", "", False)
        elif key == "userpromptsubmit":
            self.hook_turn_done = self.idle_at_prompt = False
            if self.state != "running":
                self.set_state("running", "prompt-submitted", "", False)

    def last_assistant_from_transcript(self):
        if not self.transcript or not os.path.exists(self.transcript):
            return None
        last = None
        try:
            with open(self.transcript, encoding="utf-8", errors="replace") as f:
                for line in f:
                    if '"type":"assistant"' not in line:
                        continue
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    content = (o.get("message") or {}).get("content") or []
                    txt = " ".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
                    if txt:
                        last = txt
        except OSError:
            return None
        return last

    # ---- control socket ------------------------------------------------------------------------------

    def accept_loop(self):
        try:
            os.remove(self.sock)
        except OSError:
            pass
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock)
        os.chmod(self.sock, 0o600)
        srv.listen(16)
        while not self.exited:
            try:
                conn, _ = srv.accept()
            except OSError:
                time.sleep(0.2)
                continue
            threading.Thread(target=self.serve_client, args=(conn,), daemon=True).start()

    def serve_client(self, conn):
        sub = None
        try:
            while True:
                fr = lc.read_frame(conn)
                if fr is None:
                    break
                ftype, payload = fr
                if ftype == lc.INPUT:
                    self.write_input(payload)
                elif ftype == lc.PASTE:
                    self.write_paste(payload)
                elif ftype == lc.WAKE:
                    self.wake.set()
                elif ftype == lc.RESIZE and len(payload) >= 4:
                    c, r = struct.unpack("<HH", payload[:4])
                    self._set_winsize(c, r)
                elif ftype == lc.SUBSCRIBE:
                    off = struct.unpack("<q", payload[:8])[0] if len(payload) >= 8 else 0
                    sub = Subscriber(conn)
                    with self.log_lock:   # register at the live edge so nothing falls between replay and live
                        live = self.bytes
                        self.subs.append(sub)
                    if off < 0:
                        off = max(0, live + off)
                    if off < live:
                        with open(os.path.join(self.lane_dir, "console.log"), "rb") as f:
                            f.seek(off)
                            data = f.read(live - off)
                        with sub.cond:
                            sub.queue[:0] = [(lc.OUTPUT, data[i:i + 65536]) for i in range(0, len(data), 65536)]
                            sub.pending += len(data)
                            sub.cond.notify()
                    if self.exited:
                        sub.push(lc.EXIT, str(self.exit_code).encode())
                    threading.Thread(target=sub.pump, daemon=True).start()
                elif ftype == lc.QUERY:
                    try:
                        with open(os.path.join(self.lane_dir, "state.json"), "rb") as f:
                            js = f.read()
                    except OSError:
                        js = b"{}"
                    lc.write_frame(conn, lc.JSONT, js)
                elif ftype == lc.KILL:
                    if payload == b"hard":
                        self.kill_tree()
                    else:
                        threading.Thread(target=self.soft_kill, daemon=True).start()
        except OSError:
            pass
        finally:
            if sub is not None:
                with self.log_lock:
                    if sub in self.subs:
                        self.subs.remove(sub)
                with sub.cond:
                    sub.dead = True
                    sub.cond.notify()
            else:
                try:
                    conn.close()
                except OSError:
                    pass

    def _wait_exit(self, sec):
        end = time.monotonic() + sec
        while time.monotonic() < end:
            if self.exited:
                return True
            time.sleep(0.1)
        return self.exited

    def kill_tree(self):
        for sig in (signal.SIGHUP, signal.SIGKILL):
            try:
                os.killpg(self.child, sig)
            except OSError:
                pass
            if sig == signal.SIGHUP and self._wait_exit(1.0):
                return

    def soft_kill(self):
        """Ask the CLI to leave on its own terms, then escalate."""
        if self.kind in ("claude", "codex"):
            self.write_input(b"\x1b")
            time.sleep(0.2)
            self.write_input(b"/exit\r")
            if self._wait_exit(8):
                return
            self.write_input(b"\x03")
            time.sleep(0.3)
            self.write_input(b"\x03")
            if self._wait_exit(4):
                return
        else:
            self.write_input(b"\x03")
            if self._wait_exit(3):
                return
            self.write_input(b"exit\r")
            if self._wait_exit(3):
                return
        self.kill_tree()


# ---- verbs -------------------------------------------------------------------------------------------------


def _opts(args):
    d, i = {}, 0
    while i < len(args):
        k = args[i]
        if k.startswith("--") and i + 1 < len(args):
            d[k[2:]] = args[i + 1]
            i += 2
        else:
            i += 1
    return d


def cmd_run(args):
    a = _opts(args)
    for req in ("name", "dir", "argv-json"):
        if req not in a:
            print("lanehost run: --%s is required" % req, file=sys.stderr)
            return 2
    # Detach: a head launches lanes from a tool whose stdout is a pipe. Double-fork so the host holds no
    # inherited descriptor and is not a child of whoever launched it.
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    return Host(a).main()


def cmd_hook(args):
    if not args:
        return 2
    lane_dir_path = args[0]
    payload = args[1] if len(args) >= 2 and args[1].lstrip().startswith("{") else None   # codex passes JSON as an argument
    if payload is None and not sys.stdin.isatty():
        try:
            payload = sys.stdin.read()
        except Exception:
            payload = None
    payload = (payload or "{}").replace("\r", " ").replace("\n", " ").strip()
    row = payload
    if row.startswith("{") and row.endswith("}"):
        row = '{"_t":"%s",' % lc.now_iso() + row[1:] if len(row) > 2 else '{"_t":"%s"}' % lc.now_iso()
    lc.append_line(os.path.join(lane_dir_path, "hooks.jsonl"), row)
    try:   # wake the host now rather than on its next one-second tick
        s = lc.connect(lane_dir_path, 0.5)
        lc.write_frame(s, lc.WAKE)
        time.sleep(0.02)
        s.close()
    except OSError:
        pass
    return 0


def cmd_grok_hook(args):
    d = os.environ.get("LANES_LANE_DIR")
    if not d:
        return 0   # a normal Grok terminal: stay inert
    return cmd_hook([d])


def cmd_attach(args):
    import termios
    import tty
    if not args:
        print("usage: lanehost.py attach <name> [--tail-bytes N]", file=sys.stderr)
        return 2
    name = args[0]
    tail_bytes = int(_opts(args[1:]).get("tail-bytes", 262144))
    d = lc.lane_dir(name)
    try:
        s = lc.connect(d)
    except OSError:
        st = lc.read_json(os.path.join(d, "state.json")) or {}
        print("lane %s: host not reachable (state %s %s)" % (name, st.get("state", "unknown"), st.get("why", "")))
        return 1
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)

    def send_size(*_):
        try:
            sz = os.get_terminal_size()
            lc.write_frame(s, lc.RESIZE, struct.pack("<HH", sz.columns, sz.lines))
        except OSError:
            pass

    sys.stdout.write("\x1b]0;lane %s\x07\x1b[2J\x1b[H" % name)
    sys.stdout.flush()
    send_size()
    signal.signal(signal.SIGWINCH, send_size)
    lc.write_frame(s, lc.SUBSCRIBE, struct.pack("<q", -tail_bytes))
    state = {"exit": None}

    def reader():
        out = sys.stdout.buffer
        while True:
            fr = lc.read_frame(s)
            if fr is None:
                break
            t, p = fr
            if t == lc.OUTPUT:
                out.write(p)
                out.flush()
            elif t == lc.GAP:
                out.write(b"\r\n\x1b[33m[viewer fell behind by " + p + b" bytes; the log is complete]\x1b[0m\r\n")
            elif t == lc.EXIT:
                state["exit"] = p.decode()
                break
        state["done"] = True

    th = threading.Thread(target=reader, daemon=True)
    th.start()
    tty.setraw(fd)
    try:
        while th.is_alive():
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                data = os.read(fd, 4096)
                if not data:
                    break
                lc.write_frame(s, lc.INPUT, data)
    except OSError:
        pass
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    if state["exit"] is not None:
        print("\r\n[lane %s exited with code %s]" % (name, state["exit"]))
    return 0


def cmd_serve(args):
    import serve_viewer
    a = _opts(args)
    www = a.get("www") or os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "viewer")
    if a.get("detach") == "1":
        if os.fork() > 0:
            os._exit(0)
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
    try:
        os.makedirs(lc.lanes_root(), exist_ok=True)
        with open(os.path.join(lc.lanes_root(), "_viewer.pid"), "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass
    return serve_viewer.serve(int(a.get("port", 7342)), www)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    verb, args = sys.argv[1], sys.argv[2:]
    fn = {"run": cmd_run, "hook": cmd_hook, "grok-hook": cmd_grok_hook, "attach": cmd_attach, "serve": cmd_serve}.get(verb)
    if not fn:
        print("unknown verb " + verb, file=sys.stderr)
        return 2
    return fn(args)


if __name__ == "__main__":
    sys.exit(main())
