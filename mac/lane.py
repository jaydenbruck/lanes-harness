#!/usr/bin/env python3
"""lane - Lanes Harness for macOS (and Linux): run Claude Code, Codex, Grok and Cursor agents as headless lanes.

  lane launch --name N --kind claude|codex|grok|cursor|other [--model M] [--effort LEVEL] [--cwd DIR]
              [--brief PATH] [--prompt TEXT] [--command CMD] [--visible] [--is-head] [--head OWNER]
              [--stall-minutes 10] [--cols 160 --rows 45] [--extra-args "..."]
  lane list [--all] [--head H] [--json]          lane status N
  lane read N [--tail 40] [--from A --to B] [--raw] [--messages 3] [--events]
  lane send N TEXT...  |  --key enter|esc|up|down|tab|ctrl-c|y|n  |  --raw "2"  |  --file PATH  [--no-enter]
  lane kill N [--hard]     lane restart N [--prompt TEXT] [--fresh]
  lane events [--drain] [--peek] [--max 200] [--json] [--as CONSUMER] [--all]
  lane wait [--timeout 600] [--drain] [--as CONSUMER]
  lane tab N               (a Terminal window attached to the lane)      lane attach N   (attach in this terminal)
  lane serve [--port 7342] [--open]
  lane head N [--lane L]   lane heads     lane whoami
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lanes_common as lc  # noqa: E402

HOST = os.path.join(HERE, "lanehost.py")
PY = sys.executable or shutil.which("python3") or "python3"
MAX_HEADS = int(os.environ.get("LANES_MAX_HEADS") or 2)
KEYS = {"enter": "\r", "esc": "\x1b", "tab": "\t", "shift-tab": "\x1b[Z", "up": "\x1b[A", "down": "\x1b[B", "right": "\x1b[C",
        "left": "\x1b[D", "ctrl-c": "\x03", "ctrl-d": "\x04", "ctrl-z": "\x1a", "ctrl-l": "\x0c", "ctrl-u": "\x15", "space": " ",
        "backspace": "\x7f", "home": "\x1b[H", "end": "\x1b[F", "pgup": "\x1b[5~", "pgdn": "\x1b[6~", "y": "y", "n": "n"}


class LaneError(Exception):
    pass


def strict_privacy():
    return re.match(r"^(1|true|yes|on)$", os.environ.get("LANES_STRICT_PRIVACY", ""), re.I) is not None


# ---- identity ---------------------------------------------------------------------------------------------

def current_head():
    return os.environ.get("LANES_HEAD") or "user"


def current_consumer():
    """A registered head is its own consumer; a lane-hosted helper is its lane name; the human is 'user'."""
    if os.environ.get("LANES_CONSUMER"):
        return os.environ["LANES_CONSUMER"]
    if os.environ.get("LANES_HEAD") and os.environ["LANES_HEAD"] != "user":
        return os.environ["LANES_HEAD"]
    return os.environ.get("LANES_LANE") or "user"


def cursor_path(head, consumer):
    base = os.path.join(lc.heads_root(), head)
    if not consumer or consumer in (head, "user"):
        return os.path.join(base, "events.cursor")
    return os.path.join(base, "events.%s.cursor" % re.sub(r"[^A-Za-z0-9._-]", "_", consumer))


# ---- state -----------------------------------------------------------------------------------------------

def get_state(name):
    d = lc.lane_dir(name)
    st = lc.read_json(os.path.join(d, "state.json"))
    if st is None:
        return None
    alive = lc.host_alive(st)
    st["alive"] = alive
    if not alive and st.get("state") in ("running", "needs-input", "stalled", "starting"):
        # The host is gone without an exit row: the registry must not keep saying "running".
        st["state"], st["why"] = "died", "host-lost"
        try:
            fd = os.open(os.path.join(d, "host-lost.emitted"), os.O_CREAT | os.O_EXCL | os.O_WRONLY)   # one emitter, ever
            os.close(fd)
            st["label"] = "host process vanished (supervisor or host killed); transcript preserved"
            lc.write_json(os.path.join(d, "state.json"), {k: v for k, v in st.items() if k != "alive"})
            row = {"ts": lc.now_iso(), "head": st.get("head"), "lane": name, "state": "died", "why": "host-lost", "label": st["label"],
                   "from": st.get("episodeStart"), "to": st.get("bytes"), "pid": st.get("pid"), "exit": None, "kind": st.get("kind"),
                   "model": st.get("model"), "cwd": st.get("cwd"), "hostPid": st.get("hostPid"), "n": 0}
            lc.append_line(os.path.join(lc.heads_root(), st.get("head") or "user", "events.jsonl"), json.dumps(row, ensure_ascii=False))
        except FileExistsError:
            pass
        except OSError:
            pass
    return st


def assert_driveable(name, st, force=False):
    me = current_head()
    if force or me == "user" or st.get("head") == me:
        return
    if (st.get("meta") or {}).get("isHead"):
        return
    raise LaneError("lane '%s' belongs to head '%s'; '%s' may not drive it (it may only `lane send` to a head's inbox)" % (name, st.get("head"), me))


def send_frame(name, ftype, payload=b""):
    s = lc.connect(lc.lane_dir(name), 3.0)
    try:
        lc.write_frame(s, ftype, payload)
        time.sleep(0.03)
    finally:
        s.close()


# ---- heads -----------------------------------------------------------------------------------------------

def get_heads():
    h = lc.read_json(os.path.join(lc.heads_root(), "heads.json"))
    return list((h or {}).get("heads") or [])


def register_head(name, lane="", force=False):
    import fcntl
    lc.check_name(name)
    if name == "user":
        raise LaneError("'user' is the implicit owner of head lanes (the human), not a head")
    os.makedirs(lc.heads_root(), exist_ok=True)
    with open(os.path.join(lc.heads_root(), "heads.lock"), "w") as lk:
        fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
        f = os.path.join(lc.heads_root(), "heads.json")
        heads = get_heads()
        for x in heads:
            if x.get("name") == name:
                if lane:
                    x["lane"], x["updated"] = lane, lc.now_iso()
                lc.write_json(f, {"heads": heads})
                return x
        live = []
        for x in heads:
            alive = False
            if x.get("lane"):
                alive = lc.host_alive(lc.read_json(os.path.join(lc.lane_dir(x["lane"]), "state.json")))
            if alive or not force:
                live.append(x)
        if len(live) >= MAX_HEADS:
            raise LaneError("%d heads already registered (%s); LANES_MAX_HEADS is %d. Use --force to replace a dead one."
                            % (len(live), ", ".join(x.get("name", "") for x in live), MAX_HEADS))
        entry = {"name": name, "lane": lane, "created": lc.now_iso(), "updated": lc.now_iso()}
        live.append(entry)
        lc.write_json(f, {"heads": live})
        os.makedirs(os.path.join(lc.heads_root(), name), exist_ok=True)
        return entry


# ---- providers -------------------------------------------------------------------------------------------

def hook_command(lane_dir_path):
    return " ".join(shlex.quote(x) for x in (PY, HOST, "hook", lane_dir_path))


def claude_settings(lane_dir_path):
    hook = {"type": "command", "command": hook_command(lane_dir_path), "timeout": 20}
    plain = [{"hooks": [hook]}]
    settings = {"hooks": {"SessionStart": plain, "UserPromptSubmit": plain, "Stop": plain, "Notification": plain,
                          "PermissionRequest": plain, "SessionEnd": plain,
                          "PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [hook]}],
                          "PostToolUse": [{"matcher": "AskUserQuestion", "hooks": [hook]}]}}
    p = os.path.join(lane_dir_path, "claude-settings.json")
    with open(p, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)
    return p


def _toml_section(text, name):
    m = re.search(r"(?ms)^\[" + re.escape(name) + r"\]\s*\n(?P<body>.*?)(?=^\[|\Z)", text)
    return m.group("body") if m else ""


def assert_grok_privacy():
    """Opt-in (LANES_STRICT_PRIVACY=1): the account opted out of coding-data retention and local telemetry is off."""
    home = os.path.join(os.path.expanduser("~"), ".grok")
    auth_p, cfg_p = os.path.join(home, "auth.json"), os.path.join(home, "config.toml")
    if not os.path.exists(auth_p):
        raise LaneError("Grok is not logged in: %s is absent" % auth_p)
    if not os.path.exists(cfg_p):
        raise LaneError("Grok privacy config is absent: %s" % cfg_p)
    found = []

    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k == "coding_data_retention_opt_out":
                    found.append(bool(v))
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    with open(auth_p, encoding="utf-8") as f:
        walk(json.load(f))
    if not found or False in found:
        raise LaneError("Grok account setting coding_data_retention_opt_out is not proven true; opt out in Grok Settings > Data sharing")
    with open(cfg_p, encoding="utf-8") as f:
        cfg = f.read()
    feats, tele = _toml_section(cfg, "features"), _toml_section(cfg, "telemetry")
    pins = {"features.telemetry": re.search(r"(?m)^\s*telemetry\s*=\s*false\s*(#.*)?$", feats),
            "features.feedback": re.search(r"(?m)^\s*feedback\s*=\s*false\s*(#.*)?$", feats),
            "telemetry.mixpanel_enabled": re.search(r"(?m)^\s*mixpanel_enabled\s*=\s*false\s*(#.*)?$", tele),
            "telemetry.trace_upload": re.search(r"(?m)^\s*trace_upload\s*=\s*false\s*(#.*)?$", tele)}
    missing = [k for k, v in pins.items() if not v]
    if missing:
        raise LaneError("Grok local privacy pins are missing or not false: %s in %s" % (", ".join(missing), cfg_p))


def install_grok_hooks():
    """Grok reads user config only, so add a marked block to ~/.grok/config.toml. Inert outside a lane."""
    import fcntl
    cfg_p = os.path.join(os.path.expanduser("~"), ".grok", "config.toml")
    cmd = " ".join(shlex.quote(x) for x in (PY, HOST, "grok-hook"))
    if "'" in cmd:
        raise LaneError("Grok hook path cannot contain an apostrophe: %s" % HOST)
    tables = ["[[hooks.%s]]\n  [[hooks.%s.hooks]]\n  type = \"command\"\n  command = '%s'\n  timeout = 20" % (e, e, cmd)
              for e in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd")]
    block = "# BEGIN LANES HARNESS GROK HOOKS\n" + "\n\n".join(tables) + "\n# END LANES HARNESS GROK HOOKS"
    os.makedirs(os.path.dirname(cfg_p), exist_ok=True)
    with open(cfg_p + ".lanes.lock", "w") as lk:
        fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
        text = open(cfg_p, encoding="utf-8").read() if os.path.exists(cfg_p) else ""
        pat = re.compile(r"(?ms)^# BEGIN LANES HARNESS GROK HOOKS\n.*?^# END LANES HARNESS GROK HOOKS\s*")
        nxt = pat.sub(block + "\n", text) if pat.search(text) else text.rstrip() + "\n\n" + block + "\n"
        if nxt != text:
            with open(cfg_p + ".lanes.tmp", "w", encoding="utf-8") as f:
                f.write(nxt)
            os.replace(cfg_p + ".lanes.tmp", cfg_p)


def resolve_exe(kind):
    home = os.path.expanduser("~")
    cands = {"claude": ["claude", home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
             "codex": ["codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"],
             "grok": [home + "/.grok/bin/grok", "grok", "/opt/homebrew/bin/grok", "/usr/local/bin/grok"],
             "cursor": ["cursor-agent", home + "/.local/bin/cursor-agent", "/opt/homebrew/bin/cursor-agent", "/usr/local/bin/cursor-agent"]}[kind]
    for c in cands:
        p = c if os.path.isabs(c) else shutil.which(c)
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    raise LaneError("%s not found (looked on PATH and in %s)" % (kind, ", ".join(c for c in cands if os.path.isabs(c))))


def assert_cursor_zdr(model):
    if not model:
        return
    r = subprocess.run([resolve_exe("cursor"), "--list-models"], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise LaneError("cursor: cannot read the model list, so ZDR cannot be verified; refusing to launch. Run 'cursor-agent login'.")
    line = next((l for l in (r.stdout + r.stderr).splitlines() if re.match(r"^\s*%s\s+-" % re.escape(model), l)), None)
    if not line:
        raise LaneError("cursor: '%s' is not a model this account is offered; refusing rather than guessing." % model)
    if "(NO ZDR)" in line:
        raise LaneError("cursor: '%s' is OUTSIDE Cursor's zero-data-retention agreements (server says: %s). LANES_STRICT_PRIVACY is on, "
                        "so this lane is refused. Pick a model with no NO ZDR marker." % (model, line.strip()))


def read_effort_from_log(path, start=0, max_bytes=4 * 1024 * 1024):
    try:
        size = os.path.getsize(path)
    except OSError:
        return ""
    start = min(max(0, start), size)
    if size - start > max_bytes:
        start = size - max_bytes
    with open(path, "rb") as f:
        f.seek(start)
        text = f.read().decode("utf-8", "replace")
    text = re.sub(r"\x1b\[[0-9;?<=>!]*[ -/]*[@-~]", "", text)
    text = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)?", "", text)
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", " ", text)
    # Codex shows the effort in its startup card ("... /model to change") and its footer ("... · cwd").
    ms = re.findall(r"(?i)gpt[\w.\-]*\s+(none|minimal|low|medium|high|xhigh|max|ultra)\b(?=\s*(?:/model\b|·))", text)
    return ms[-1].lower() if ms else ""


def wait_effort_readback(name, expected, start, timeout):
    path = os.path.join(lc.lane_dir(name), "console.log")
    end = time.time() + timeout
    while time.time() < end:
        actual = read_effort_from_log(path, start)
        if actual:
            return {"requested": expected, "actual": actual, "status": "OK" if actual == expected else "DRIFT"}
        time.sleep(0.2)
    return {"requested": expected, "actual": "UNKNOWN", "status": "CANNOT-SEE"}


def format_readback(rb):
    if rb["status"] == "CANNOT-SEE":
        return "CANNOT-SEE effort requested=%s actual=UNKNOWN" % rb["requested"]
    return "%s effort requested=%s actual=%s" % (rb["status"], rb["requested"], rb["actual"])


# ---- launch ----------------------------------------------------------------------------------------------

def ensure_shim():
    bindir = os.path.join(lc.lanes_home(), "bin")
    shim = os.path.join(bindir, "lane")
    if not os.path.exists(shim):
        os.makedirs(bindir, exist_ok=True)
        with open(shim, "w") as f:
            f.write("#!/bin/sh\nexec %s %s \"$@\"\n" % (shlex.quote(PY), shlex.quote(os.path.join(HERE, "lane.py"))))
        os.chmod(shim, 0o755)
    return bindir


def start_lane(name, kind="claude", model="", cwd=None, brief="", prompt="", command="", extra_args=None, effort="high",
               head="", is_head=False, visible=False, cols=160, rows=45, stall_minutes=10, stall_seconds=0,
               resume_session="", restart_of="", restart_count=0, keep_log=False, force=False):
    lc.check_name(name)
    if kind not in ("claude", "codex", "grok", "cursor", "other"):
        raise LaneError("--kind must be claude, codex, grok, cursor or other")
    if not re.match(r"^[a-z][a-z0-9_-]*$", effort or ""):
        raise LaneError("--effort must look like 'high'")
    cwd = os.path.abspath(os.path.expanduser(cwd or os.getcwd()))
    if not os.path.isdir(cwd):
        raise LaneError("cwd '%s' does not exist" % cwd)
    extra_args = list(extra_args or [])
    head = head or current_head()
    if is_head:
        register_head(name, name, force)
        head = "user"
    d = lc.lane_dir(name)
    for p in (lc.lanes_root(), lc.heads_root(), os.path.join(lc.heads_root(), head)):
        os.makedirs(p, exist_ok=True)

    # Name reuse: alive -> refuse; dead -> preserve the old generation, never overwrite a transcript.
    if os.path.isdir(d):
        old = lc.read_json(os.path.join(d, "state.json"))
        if old and lc.host_alive(old):
            raise LaneError("lane '%s' is alive (host pid %s, state %s); kill it first or pick another name" % (name, old.get("hostPid"), old.get("state")))
        if not keep_log:
            t = lc.parse_iso((old or {}).get("started"))
            stamp = (t or lc.parse_iso(lc.now_iso())).strftime("%Y%m%d-%H%M%S")
            hist = os.path.join(d, "history", stamp)
            os.makedirs(hist, exist_ok=True)
            for f in ("console.log", "state.json", "hooks.jsonl", "launch.json", "claude-settings.json", "host-lost.emitted"):
                if os.path.exists(os.path.join(d, f)):
                    os.replace(os.path.join(d, f), os.path.join(hist, f))
        else:
            for f in ("host-lost.emitted", "hooks.jsonl"):
                if os.path.exists(os.path.join(d, f)):
                    os.remove(os.path.join(d, f))
    os.makedirs(d, exist_ok=True)
    log_path = os.path.join(d, "console.log")
    effort_offset = os.path.getsize(log_path) if os.path.exists(log_path) else 0

    first = ""
    if brief:
        bp = os.path.abspath(os.path.expanduser(brief))
        first = "Read %s. It is your brief. Carry it out completely." % (bp if os.path.exists(bp) else brief)
    if prompt:
        first = first + "\n\n" + prompt if first else prompt

    session_id = ""
    if command:
        argv = shlex.split(command) + extra_args + ([first] if first else [])
    elif kind == "claude":
        settings = claude_settings(d)
        argv = [resolve_exe("claude"), "--dangerously-skip-permissions"]
        if model:
            argv += ["--model", model]
        if resume_session:
            argv += ["--resume", resume_session]
            session_id = resume_session
        else:
            session_id = str(uuid.uuid4())
            argv += ["--session-id", session_id]
        argv += ["--settings", settings] + extra_args + ([first] if first else [])
    elif kind == "codex":
        notify_parts = [PY, HOST, "hook", d]
        if any("'" in x for x in notify_parts):
            raise LaneError("paths used in the Codex notify hook cannot contain an apostrophe")
        notify = "notify=[" + ",".join("'%s'" % x for x in notify_parts) + "]"
        argv = [resolve_exe("codex")] + (["resume", resume_session] if resume_session else []) + ["--yolo"]
        if model:
            argv += ["-m", model]
        argv += ["-c", notify, "-C", cwd] + extra_args + ["-c", "model_reasoning_effort=" + effort] + ([first] if first else [])
        session_id = resume_session
    elif kind == "grok":
        if strict_privacy():
            assert_grok_privacy()
        install_grok_hooks()
        argv = [resolve_exe("grok"), "--no-alt-screen", "--permission-mode", "bypassPermissions"]
        if model:
            argv += ["--model", model]
        if resume_session:
            argv += ["--resume", resume_session]
            session_id = resume_session
        else:
            session_id = str(uuid.uuid4())
            argv += ["--session-id", session_id]
        argv += extra_args + ([first] if first else [])
    elif kind == "cursor":
        if strict_privacy():
            assert_cursor_zdr(model)
        # --force is Cursor's "run everything"; --trust answers the workspace-trust prompt up front.
        argv = [resolve_exe("cursor"), "--force", "--trust", "--workspace", cwd]
        if model:
            argv += ["--model", model]
        if resume_session:   # Cursor mints its own chat id; there is no --session-id to pre-seed
            argv += ["--resume", resume_session]
            session_id = resume_session
        argv += extra_args + ([first] if first else [])
    else:
        raise LaneError("--kind other needs --command")
    cmdline = " ".join(shlex.quote(x) for x in argv)

    launch_id = uuid.uuid4().hex
    meta = {"isHead": bool(is_head), "visible": bool(visible), "launchedBy": current_head(), "launcherPid": os.getpid()}
    launch = {"name": name, "head": head, "kind": kind, "model": model, "effort": effort if kind == "codex" else "", "actualEffort": "",
              "effortStatus": "", "effortReadbackAt": "", "cwd": cwd, "brief": brief, "prompt": first, "cmd": cmdline, "argv": argv,
              "sessionId": session_id, "cols": cols, "rows": rows, "stallMinutes": stall_minutes, "isHead": bool(is_head),
              "visible": bool(visible), "restartOf": restart_of, "restartCount": restart_count, "launchedBy": current_head(),
              "launcherPid": os.getpid(), "strictPrivacy": strict_privacy(), "launchedAt": lc.now_iso(), "exe": HOST,
              "command": command}
    lc.write_json(os.path.join(d, "launch.json"), launch)
    lc.append_line(os.path.join(lc.lanes_root(), "_registry.jsonl"), json.dumps(launch, ensure_ascii=False))   # every launch is recorded

    host_args = [PY, HOST, "run", "--name", name, "--dir", d, "--cwd", cwd, "--cols", str(cols), "--rows", str(rows), "--head", head,
                 "--kind", kind, "--model", model, "--brief", brief, "--session", session_id, "--stall-min", str(stall_minutes),
                 "--meta-json", json.dumps(meta), "--restart-of", restart_of, "--restart-count", str(restart_count),
                 "--events", os.path.join(lc.heads_root(), head, "events.jsonl"), "--launch-id", launch_id,
                 "--cmdline", cmdline, "--argv-json", json.dumps(argv)]
    if stall_seconds > 0:
        host_args += ["--stall-sec", str(stall_seconds)]
    # A lane is a first-class session, not a child of whoever launched it: scrub the launcher's session markers
    # (inherited, a Claude lane would stop saving its transcript and --resume would have nothing to resume).
    env = {k: v for k, v in os.environ.items()
           if not re.match(r"^(CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_SESSION_ID|CLAUDE_PID|CLAUDECODE|"
                           r"CLAUDE_CODE_MAX_OUTPUT_TOKENS|CODEX_THREAD_ID|CODEX_SANDBOX.*|CODEX_CI)$", k)}
    bindir = ensure_shim()
    path = env.get("PATH", "")
    if bindir not in path.split(os.pathsep):
        path = bindir + os.pathsep + path   # `lane` is on every lane's PATH
    env.update(PATH=path, CLAUDE_CODE_FORCE_SESSION_PERSISTENCE="1", LANES_HEAD=name if is_head else head, LANES_LANE=name,
               LANES_LANE_DIR=d, LANES_ROOT=lc.lanes_root(), LANES_HEADS_ROOT=lc.heads_root(), LANES_HOME=lc.lanes_home(), LANES_MODULE=HERE)
    subprocess.run(host_args, env=env, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                   start_new_session=True, close_fds=True, timeout=30)   # the host double-forks and returns at once

    st, end = None, time.time() + 15
    while time.time() < end:
        st = lc.read_json(os.path.join(d, "state.json"))
        if st and st.get("launchId") == launch_id and st.get("state") != "starting":
            break
        time.sleep(0.1)
    if not st or st.get("launchId") != launch_id:
        raise LaneError("lane '%s': host did not report a state within 15 s" % name)
    if st.get("state") == "died" and st.get("why") == "spawn-failed":
        raise LaneError("lane '%s': spawn failed: %s" % (name, st.get("label")))
    if visible:
        try:
            open_tab(name)
        except LaneError as e:
            print("warning: could not open a terminal window: %s" % e, file=sys.stderr)
    st = get_state(name)
    if kind == "codex":
        rb = wait_effort_readback(name, effort, effort_offset, 120 if resume_session else 30)
        launch.update(actualEffort=rb["actual"], effortStatus=rb["status"], effortReadbackAt=lc.now_iso())
        lc.write_json(os.path.join(d, "launch.json"), launch)
        st.update(requestedEffort=rb["requested"], actualEffort=rb["actual"], effortStatus=rb["status"])
    return st


# ---- list / read -----------------------------------------------------------------------------------------

def get_lanes(show_all=False, head=""):
    root = lc.lanes_root()
    if not os.path.isdir(root):
        return []
    rows = []
    now = time.time()
    for n in sorted(os.listdir(root)):
        if n.startswith("_") or not os.path.isdir(os.path.join(root, n)):
            continue
        try:
            st = get_state(n)
        except ValueError:
            continue
        if not st or (head and st.get("head") != head):
            continue
        if not show_all and st.get("state") in ("finished", "died") and not st.get("alive"):
            t = lc.parse_iso(st.get("updated"))
            if t and now - t.timestamp() > 86400:
                continue   # finished lanes older than a day fall out of the default list
        rows.append(st)
    return rows


def format_table(lanes):
    now = time.time()
    rows = [("lane", "head", "state", "why", "kind", "model", "pid", "age", "quiet", "kb", "label")]
    for st in sorted(lanes, key=lambda s: s.get("started") or ""):
        s, lo = lc.parse_iso(st.get("started")), lc.parse_iso(st.get("lastOutputAt"))
        lbl = re.sub(r"\s+", " ", st.get("label") or "")
        rows.append((st.get("name", ""), st.get("head", ""), st.get("state", ""), st.get("why", ""), st.get("kind", ""), st.get("model", ""),
                     str(st.get("pid", "")), "%dm" % ((now - s.timestamp()) // 60) if s else "", "%ds" % (now - lo.timestamp()) if lo else "",
                     str(int((st.get("bytes") or 0) / 1024)), lbl if len(lbl) <= 70 else lbl[:69] + "…"))
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return "\n".join("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip() for r in rows)


def grok_messages(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                o = json.loads(line)
            except ValueError:
                continue
            u = ((o.get("params") or {}).get("update")) or {}
            c = u.get("content") or {}
            if u.get("sessionUpdate") == "agent_message_chunk" and c.get("type") == "text" and c.get("text"):
                out.append(c["text"])
    return out


def read_lane(name, tail=40, frm=-1, to=-1, raw=False, messages=0, nbytes=262144, events=False):
    d = lc.lane_dir(name)
    log = os.path.join(d, "console.log")
    st = get_state(name)
    if messages > 0:
        tp = (st or {}).get("transcript") or ""
        if not tp or not os.path.exists(tp):
            raise LaneError("lane '%s' has no known structured transcript" % name)
        if st.get("kind") == "grok":
            return "\n".join(grok_messages(tp)[-messages:])
        msgs = []
        with open(tp, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"type":"assistant"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                txt = [c.get("text", "") for c in ((o.get("message") or {}).get("content") or []) if isinstance(c, dict) and c.get("type") == "text"]
                if txt:
                    msgs.append("\n".join(txt))
        return "\n".join(msgs[-messages:])
    if events:
        hp = os.path.join(d, "hooks.jsonl")
        if not os.path.exists(hp):
            return ""
        with open(hp, encoding="utf-8", errors="replace") as f:
            return "".join(f.readlines()[-tail:]).rstrip("\n")
    if st and st.get("kind") == "grok" and not raw and frm < 0 and st.get("transcript") and os.path.exists(st["transcript"]):
        return "\n".join(grok_messages(st["transcript"])[-tail:])
    if not os.path.exists(log):
        raise LaneError("no transcript at %s" % log)
    size = os.path.getsize(log)
    if frm >= 0:
        start, end = min(frm, size), (min(to, size) if to >= 0 else size)
    else:
        start, end = max(0, size - nbytes), size
    with open(log, "rb") as f:
        f.seek(start)
        data = f.read(max(0, end - start)).decode("utf-8", "replace")
    if raw:
        return data
    text = lc.strip_vt(data)
    if frm >= 0:
        return text
    res, prev = [], None
    for line in reversed(text.split("\n")):
        s = line.strip()
        if not s or s == prev:
            continue
        prev = s
        res.insert(0, line)
        if len(res) >= tail:
            break
    return "\n".join(res)


# ---- send / kill / restart -------------------------------------------------------------------------------

def send_lane(name, text=None, keys=None, raw=False, no_enter=False, force=False, file=""):
    st = get_state(name)
    if st is None:
        raise LaneError("no lane '%s'" % name)
    if not st.get("alive"):
        raise LaneError("lane '%s' is not alive (state %s %s)" % (name, st.get("state"), st.get("why")))
    assert_driveable(name, st, force)
    if keys:
        seq = ""
        for k in keys:
            k = k.strip().lower()
            if k not in KEYS:
                raise LaneError("unknown key '%s' (known: %s)" % (k, ", ".join(KEYS)))
            seq += KEYS[k]
        send_frame(name, lc.INPUT, seq.encode())
        return
    msg = open(file, encoding="utf-8").read() if file else " ".join(text or [])
    if raw:
        send_frame(name, lc.INPUT, msg.encode("utf-8"))
        return
    msg = msg.replace("\r\n", "\n")
    if not no_enter:
        msg += "\r"
    send_frame(name, lc.PASTE, msg.encode("utf-8"))


def stop_lane(name, hard=False, force=False, wait=20):
    st = get_state(name)
    if st is None:
        raise LaneError("no lane '%s'" % name)
    if not st.get("alive"):
        return st
    assert_driveable(name, st, force)
    try:
        send_frame(name, lc.KILL, b"hard" if hard else b"soft")
    except OSError:
        _kill_host(st)
    end = time.time() + wait
    while time.time() < end:
        st = get_state(name)
        if not st.get("alive"):
            return st
        time.sleep(0.2)
    _kill_host(st)
    time.sleep(0.3)
    return get_state(name)


def _kill_host(st):
    import signal
    for pid in (st.get("pid"), st.get("hostPid")):
        try:
            os.killpg(int(pid), signal.SIGKILL)
        except (OSError, TypeError, ValueError):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (OSError, TypeError, ValueError):
                pass


def restart_lane(name, prompt="", force=False, fresh=False):
    paused = os.path.join(lc.lanes_home(), "paused-lanes.txt")
    if not force and os.path.exists(paused):
        with open(paused, encoding="utf-8") as f:
            names = [l.split("#", 1)[0].strip() for l in f]
        if name in names:
            raise LaneError("lane '%s' is intentionally parked in %s; remove it there or use --force to restart" % (name, paused))
    d = lc.lane_dir(name)
    launch = lc.read_json(os.path.join(d, "launch.json"))
    if launch is None:
        raise LaneError("lane '%s' has no launch record" % name)
    st = get_state(name)
    if st and st.get("alive"):
        stop_lane(name, force=force)
    sid = (st or {}).get("sessionId") or launch.get("sessionId") or ""
    resume = "" if fresh else sid
    p = prompt
    if not p:
        if resume and launch["kind"] == "claude":
            p = "You were restarted after an interruption; your previous context is above. Continue exactly where you left off."
        elif resume and launch["kind"] in ("codex", "grok", "cursor"):
            p = "You were restarted after an interruption; continue exactly where you left off."
        else:
            p = launch.get("prompt", "")
    return start_lane(name, kind=launch["kind"], model=launch.get("model", ""), effort=launch.get("effort") or "high", cwd=launch["cwd"],
                      head=launch["head"], prompt=p, command=launch.get("command", "") if launch["kind"] == "other" else "",
                      cols=launch.get("cols", 160), rows=launch.get("rows", 45), stall_minutes=launch.get("stallMinutes", 10),
                      resume_session=resume, restart_of=launch.get("restartOf") or name, restart_count=int(launch.get("restartCount") or 0) + 1,
                      keep_log=True, force=force, is_head=bool(launch.get("isHead")), visible=bool(launch.get("visible")))


# ---- events ----------------------------------------------------------------------------------------------

def get_events(drain=False, peek=False, max_rows=200, head="", as_object=False, label_chars=240, all_rows=False, consumer=""):
    head = head or current_head()
    consumer = consumer or current_consumer()
    qf = os.path.join(lc.heads_root(), head, "events.jsonl")
    cf = cursor_path(head, consumer)
    if not os.path.exists(qf):
        return [] if as_object else ["(no events for head '%s'; consumer '%s')" % (head, consumer)]
    get_lanes(head=head)   # repair host-lost lanes first, so the queue is truthful
    cursor = 0
    if not all_rows:
        if os.path.exists(cf):
            try:
                cursor = int(open(cf).read().strip() or 0)
            except ValueError:
                cursor = 0
        elif consumer not in ("user", head):
            cursor = os.path.getsize(qf)   # a new consumer starts now; --all reads history
            os.makedirs(os.path.dirname(cf), exist_ok=True)
            with open(cf, "w") as f:
                f.write(str(cursor))
    size = os.path.getsize(qf)
    if cursor > size:
        cursor = 0   # the queue was truncated; start over
    with open(qf, "rb") as f:
        f.seek(cursor)
        data = f.read(size - cursor)
    nl = data.rfind(b"\n")
    if nl < 0:
        return [] if as_object else ["(no new events for head '%s'; consumer '%s', cursor %d of %d bytes)" % (head, consumer, cursor, size)]
    rows, consumed = [], 0
    for line in data[: nl + 1].split(b"\n")[:-1]:
        if len(rows) >= max_rows:
            break
        consumed += len(line) + 1
        s = line.strip()
        if not s:
            continue
        try:
            rows.append(json.loads(s.decode("utf-8", "replace")))
        except ValueError:
            pass
    out = []
    for r in rows:
        lbl = str(r.get("label") or "")
        if len(lbl) > label_chars:
            lbl = lbl[: label_chars - 1] + "…"
        t = lc.parse_iso(r.get("ts"))
        ts = t.astimezone().strftime("%H:%M:%S") if t else str(r.get("ts"))
        ex = " exit=%s" % r["exit"] if r.get("exit") is not None else ""
        line = "[%s] %s  %s(%s)%s  %s  (log %s..%s)" % (ts, r.get("lane"), str(r.get("state", "")).upper(), r.get("why"), ex, lbl, r.get("from"), r.get("to"))
        if as_object:
            r["text"] = line
            out.append(r)
        else:
            out.append(line)
    if drain and not peek:   # only now, after the labels exist for the caller, is the cursor advanced
        os.makedirs(os.path.dirname(cf), exist_ok=True)
        with open(cf, "w") as f:
            f.write(str(cursor + consumed))
    return out


def wait_events(timeout=600, head="", drain=False, consumer=""):
    head = head or current_head()
    consumer = consumer or current_consumer()
    qf = os.path.join(lc.heads_root(), head, "events.jsonl")
    cf = cursor_path(head, consumer)
    end = time.time() + timeout
    while time.time() < end:
        size = os.path.getsize(qf) if os.path.exists(qf) else 0
        try:
            cur = int(open(cf).read().strip() or 0) if os.path.exists(cf) else 0
        except ValueError:
            cur = 0
        if size > cur:
            return get_events(drain=drain, head=head, consumer=consumer)
        get_lanes(head=head)   # also catch host-lost lanes
        time.sleep(1)
    return []


# ---- tabs / viewer ---------------------------------------------------------------------------------------

def attach_command(name):
    return "env %s %s %s %s attach %s" % (shlex.quote("LANES_ROOT=" + lc.lanes_root()), shlex.quote("LANES_HEADS_ROOT=" + lc.heads_root()),
                                           shlex.quote(PY), shlex.quote(HOST), shlex.quote(name))


def open_tab(name):
    lc.check_name(name)
    cmd = attach_command(name)
    if sys.platform == "darwin":
        script = 'tell application "Terminal"\n  do script "%s"\n  activate\nend tell' % cmd.replace("\\", "\\\\").replace('"', '\\"')
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
        if r.returncode != 0:
            raise LaneError("osascript failed: %s" % r.stderr.strip())
        return
    for term in (["x-terminal-emulator", "-e"], ["gnome-terminal", "--"], ["konsole", "-e"], ["xterm", "-e"]):
        if shutil.which(term[0]):
            subprocess.Popen(term + ["sh", "-c", cmd], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    raise LaneError("no terminal emulator found; run this in a terminal instead: lane attach %s" % name)


def start_viewer(port=7342, open_browser=False):
    www = os.path.join(os.path.dirname(HERE), "viewer")
    subprocess.run([PY, HOST, "serve", "--port", str(port), "--www", www, "--detach", "1"], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, timeout=30)
    url = "http://127.0.0.1:%d/" % port
    if open_browser:
        subprocess.Popen(["open" if sys.platform == "darwin" else "xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return url


# ---- command line ----------------------------------------------------------------------------------------

def parse(args, positional, switches):
    named, pos, i = {}, [], 0
    while i < len(args):
        t = args[i]
        if t.startswith("--"):
            k = t[2:].replace("-", "_")
            if k in switches or i + 1 >= len(args):
                named[k] = True
                i += 1
                continue
            named[k] = args[i + 1]
            i += 2
            continue
        pos.append(t)
        i += 1
    for j, p in enumerate(positional):
        if j < len(pos):
            named[p] = pos[j]
    named["_rest"] = pos[len(positional):]
    return named


def need(p, key):
    if key not in p:
        raise LaneError("missing <%s>; see `lane help`" % key)
    return p[key]


def main(argv):
    verb, rest = (argv[0], argv[1:]) if argv else ("help", [])
    if verb == "launch":
        p = parse(rest, ["name"], {"visible", "hidden", "is_head", "force"})
        st = start_lane(need(p, "name"), kind=p.get("kind", "claude"), model=p.get("model", ""), cwd=p.get("cwd"), brief=p.get("brief", ""),
                        prompt=p.get("prompt", ""), command=p.get("command", ""), extra_args=shlex.split(p.get("extra_args", "")),
                        effort=p.get("effort", "high"), head=p.get("head", ""), is_head=bool(p.get("is_head")), visible=bool(p.get("visible")),
                        cols=int(p.get("cols", 160)), rows=int(p.get("rows", 45)), stall_minutes=int(p.get("stall_minutes", 10)),
                        stall_seconds=int(p.get("stall_seconds", 0)), force=bool(p.get("force")))
        print("launched %s  head=%s state=%s pid=%s host=%s cwd=%s" % (st["name"], st.get("head"), st.get("state"), st.get("pid"), st.get("hostPid"), st.get("cwd")))
        if st.get("kind") == "codex":
            print(format_readback({"requested": st["requestedEffort"], "actual": st["actualEffort"], "status": st["effortStatus"]}))
            if st["effortStatus"] == "DRIFT":
                return 1
            if st["effortStatus"] == "CANNOT-SEE":
                return 3
        print("log  " + os.path.join(lc.lanes_root(), st["name"], "console.log"))
    elif verb in ("list", "ls"):
        p = parse(rest, [], {"all", "json"})
        lanes = get_lanes(bool(p.get("all")), p.get("head", ""))
        print(json.dumps(lanes, indent=2) if p.get("json") else (format_table(lanes) if lanes else "(no lanes)"))
    elif verb == "read":
        p = parse(rest, ["name"], {"raw", "events"})
        print(read_lane(need(p, "name"), tail=int(p.get("tail", 40)), frm=int(p.get("from", -1)), to=int(p.get("to", -1)), raw=bool(p.get("raw")),
                        messages=int(p.get("messages", 0)), nbytes=int(p.get("bytes", 262144)), events=bool(p.get("events"))))
    elif verb == "send":
        p = parse(rest, ["name"], {"raw", "no_enter", "force"})
        keys = p["key"].split(",") if isinstance(p.get("key"), str) else None
        text = p["_rest"]
        if isinstance(p.get("raw"), bool) and p.get("raw") and not text:
            raise LaneError("--raw needs text")
        send_lane(need(p, "name"), text=text, keys=keys, raw=bool(p.get("raw")), no_enter=bool(p.get("no_enter")), force=bool(p.get("force")),
                  file=p.get("file", "") if isinstance(p.get("file"), str) else "")
        print("sent to " + p["name"])
    elif verb == "kill":
        p = parse(rest, ["name"], {"hard", "force"})
        st = stop_lane(need(p, "name"), hard=bool(p.get("hard")), force=bool(p.get("force")))
        print("%s: %s (%s)" % (st.get("name"), st.get("state"), st.get("why")))
    elif verb == "restart":
        p = parse(rest, ["name"], {"force", "fresh"})
        st = restart_lane(need(p, "name"), prompt=p.get("prompt", ""), force=bool(p.get("force")), fresh=bool(p.get("fresh")))
        print("restarted %s  state=%s pid=%s host=%s resume=%s" % (st["name"], st.get("state"), st.get("pid"), st.get("hostPid"), st.get("sessionId")))
    elif verb == "events":
        p = parse(rest, [], {"drain", "peek", "json", "all"})
        ev = get_events(drain=bool(p.get("drain")), peek=bool(p.get("peek")), max_rows=int(p.get("max", 200)), head=p.get("head", ""),
                        as_object=bool(p.get("json")), label_chars=int(p.get("label_chars", 240)), all_rows=bool(p.get("all")), consumer=p.get("as", ""))
        print(json.dumps(ev, indent=2, ensure_ascii=False) if p.get("json") else "\n".join(ev))
    elif verb == "wait":
        p = parse(rest, [], {"drain"})
        ev = wait_events(timeout=int(p.get("timeout", 600)), head=p.get("head", ""), drain=bool(p.get("drain")), consumer=p.get("as", ""))
        if ev:
            print("\n".join(ev))
    elif verb == "tab":
        p = parse(rest, ["name"], {"new_window", "split_pane"})
        open_tab(need(p, "name"))
        print("tab opened for " + p["name"])
    elif verb == "attach":
        p = parse(rest, ["name"], set())
        os.execv(PY, [PY, HOST, "attach", need(p, "name")])
    elif verb == "serve":
        p = parse(rest, [], {"open", "foreground"})
        if p.get("foreground"):
            os.execv(PY, [PY, HOST, "serve", "--port", str(p.get("port", 7342)), "--www", os.path.join(os.path.dirname(HERE), "viewer")])
        print("viewer " + start_viewer(int(p.get("port", 7342)), bool(p.get("open"))))
    elif verb == "head":
        p = parse(rest, ["name"], {"force"})
        print(json.dumps(register_head(need(p, "name"), p.get("lane", ""), bool(p.get("force")))))
    elif verb == "heads":
        print(json.dumps(get_heads()))
    elif verb == "status":
        p = parse(rest, ["name"], set())
        print(json.dumps(get_state(need(p, "name")), indent=2))
    elif verb == "whoami":
        print("head: %s  consumer: %s  lane: %s  home: %s  root: %s" % (current_head(), current_consumer(), os.environ.get("LANES_LANE", ""),
                                                                      lc.lanes_home(), lc.lanes_root()))
    else:
        print(__doc__.strip())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (LaneError, ValueError) as e:
        print("lane: %s" % e, file=sys.stderr)
        sys.exit(2)
