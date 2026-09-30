"""Shared helpers for the macOS/Linux port of Lanes Harness (stdlib only, Python 3.9+).

The on-disk layout matches the Windows version: <LANES_HOME>/lanes/<name>/{console.log,state.json,
launch.json,hooks.jsonl}, <LANES_HOME>/lanes/_registry.jsonl and <LANES_HOME>/heads/<head>/events.jsonl.
LANES_HOME defaults to ~/.lanes.
"""
import datetime
import fcntl
import hashlib
import json
import os
import re
import socket
import struct
import subprocess

# ---- paths -------------------------------------------------------------------------------------------


def lanes_home():
    return os.environ.get("LANES_HOME") or os.path.join(os.path.expanduser("~"), ".lanes")


def lanes_root():
    return os.environ.get("LANES_ROOT") or os.path.join(lanes_home(), "lanes")


def heads_root():
    return os.environ.get("LANES_HEADS_ROOT") or os.path.join(lanes_home(), "heads")


def sock_path(lane_dir):
    """The host's control socket. Unix socket paths are limited to ~104 bytes on macOS, so it lives in a
    short per-user directory and is named by a hash of the lane directory (unique per LANES_HOME)."""
    d = "/tmp/lanes-%d" % os.getuid()
    os.makedirs(d, mode=0o700, exist_ok=True)
    h = hashlib.sha1(os.path.abspath(lane_dir).encode("utf-8")).hexdigest()[:16]
    return os.path.join(d, h + ".sock")


NAME_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def check_name(name):
    if not name or not NAME_RX.match(name):
        raise ValueError("lane name '%s' must be 1-64 chars of [A-Za-z0-9._-]" % name)


def lane_dir(name):
    check_name(name)
    return os.path.join(lanes_root(), name)


# ---- time / json ---------------------------------------------------------------------------------------


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_iso(s):
    if not s:
        return None
    s = str(s).strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    m = re.match(r"^(.*\.\d{6})\d*(.*)$", s)   # Windows writes 7 fractional digits
    if m:
        s = m.group(1) + m.group(2)
    try:
        d = datetime.datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d


def read_json(path):
    for _ in range(5):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            return None
        except (ValueError, OSError):
            import time
            time.sleep(0.04)
    return None


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def append_line(path, line):
    """One locked append, the same discipline the host uses for the event queue."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "ab") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write((line + "\n").encode("utf-8"))
            f.flush()
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)


# ---- processes -----------------------------------------------------------------------------------------


def pid_alive(pid):
    """True if pid is a live (non-zombie) process."""
    try:
        pid = int(pid)
        if pid <= 0:
            return False
        os.kill(pid, 0)
    except (ProcessLookupError, ValueError, TypeError):
        return False
    except PermissionError:
        return True
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
        return bool(out) and not out.startswith("Z")
    except Exception:
        return True


def host_alive(state):
    if not state or not state.get("hostPid"):
        return False
    if not pid_alive(state["hostPid"]):
        return False
    try:
        cmd = subprocess.run(["ps", "-o", "command=", "-p", str(int(state["hostPid"]))],
                             capture_output=True, text=True, timeout=5).stdout
        return "lanehost" in cmd
    except Exception:
        return True


# ---- frames (same wire format as the Windows host) -------------------------------------------------------

INPUT, RESIZE, SUBSCRIBE, KILL, QUERY = b"I", b"R", b"S", b"K", b"Q"
OUTPUT, EXIT, JSONT, GAP, WAKE, PASTE = b"O", b"X", b"J", b"G", b"H", b"P"


def write_frame(sock, ftype, payload=b""):
    sock.sendall(ftype + struct.pack("<I", len(payload)) + payload)


def _read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def read_frame(sock):
    hdr = _read_exact(sock, 5)
    if hdr is None:
        return None
    n = struct.unpack("<I", hdr[1:5])[0]
    payload = _read_exact(sock, n) if n else b""
    if payload is None:
        return None
    return hdr[0:1], payload


def connect(lane_dir_path, timeout=3.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path(lane_dir_path))
    s.settimeout(None)
    return s


# ---- terminal text -------------------------------------------------------------------------------------

_CSI_FWD = re.compile(r"\x1b\[(\d*)C")
_CSI = re.compile(r"\x1b\[[0-9;?<=>!]*[ -/]*[@-~]")
_OSC = re.compile(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)?")
_DCS = re.compile(r"\x1b[P^_][^\x1b]*(\x1b\\)?")
_CHARSET = re.compile(r"\x1b[()*+#][0-9A-Za-z]")
_ESC2 = re.compile(r"\x1b.")
_CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def strip_vt(s):
    """Visible text with line structure kept; cursor-forward becomes spaces; \\r overwrites resolved per line."""
    s = _CSI_FWD.sub(lambda m: " " * (min(1000, int(m.group(1))) if m.group(1) else 1), s)
    s = _CSI.sub("", s)
    s = _OSC.sub("", s)
    s = _DCS.sub("", s)
    s = _CHARSET.sub("", s)
    s = _ESC2.sub("", s)
    s = _CTRL.sub("", s)
    out = []
    for line in s.replace("\r\n", "\n").split("\n"):
        r = line.rfind("\r")
        if r >= 0:
            line = line[r + 1:]
        out.append(line.rstrip())
    return "\n".join(out)


def tail_lines(stripped, n):
    """Last n non-empty lines, immediate repeats collapsed."""
    res, prev = [], None
    for line in reversed(stripped.split("\n")):
        s = line.strip()
        if not s or s == prev:
            continue
        prev = s
        res.insert(0, s)
        if len(res) >= n:
            break
    return res


def truncate(s, n):
    if s is None:
        return ""
    s = s.replace("\r", " ").replace("\n", " ⏎ ")
    s = re.sub(r" {2,}", " ", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"
