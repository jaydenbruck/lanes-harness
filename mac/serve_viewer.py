"""The browser viewer's server for macOS/Linux: static files from viewer/, /api/lanes, /api/events,
/api/log/<name>, POST /api/send/<name>, and a WebSocket bridge /ws/<name> to each lane host.
Same endpoints as the Windows LaneHost, so the same viewer/index.html works. Stdlib only.
"""
import base64
import hashlib
import json
import os
import socket
import struct
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import lanes_common as lc

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
CTYPES = {".html": "text/html; charset=utf-8", ".js": "application/javascript", ".css": "text/css"}


def lanes_json():
    rows = []
    root = lc.lanes_root()
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            if name.startswith("_"):
                continue
            st = lc.read_json(os.path.join(root, name, "state.json"))
            if not st:
                continue
            alive = lc.host_alive(st)
            if not alive and st.get("state") in ("running", "needs-input", "stalled", "starting"):
                st["state"], st["why"] = "died", "host-lost"
            st["alive"] = alive
            rows.append(st)
    return rows


def ws_send(conn, data, opcode):
    n = len(data)
    if n < 126:
        hdr = struct.pack("!BB", 0x80 | opcode, n)
    elif n < 65536:
        hdr = struct.pack("!BBH", 0x80 | opcode, 126, n)
    else:
        hdr = struct.pack("!BBQ", 0x80 | opcode, 127, n)
    conn.sendall(hdr + data)


def ws_recv(rfile):
    """One complete client message: (opcode, payload), or None when the socket closes."""
    buf, opcode = b"", None
    while True:
        h = rfile.read(2)
        if len(h) < 2:
            return None
        fin, op = h[0] & 0x80, h[0] & 0x0F
        masked, n = h[1] & 0x80, h[1] & 0x7F
        if n == 126:
            n = struct.unpack("!H", rfile.read(2))[0]
        elif n == 127:
            n = struct.unpack("!Q", rfile.read(8))[0]
        mask = rfile.read(4) if masked else b"\0\0\0\0"
        data = bytearray(rfile.read(n))
        for i in range(len(data)):
            data[i] ^= mask[i % 4]
        if op in (8, 9, 10):
            return op, bytes(data)
        if op != 0:
            opcode = op
        buf += bytes(data)
        if fin:
            return opcode, buf


class Handler(BaseHTTPRequestHandler):
    www = ""

    def log_message(self, *a):
        pass

    def _send(self, body, ctype="application/json", code=200):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = u.path
        if path.startswith("/ws/") and self.headers.get("Upgrade", "").lower() == "websocket":
            return self.ws_bridge(urllib.parse.unquote(path[4:]), int(q.get("tail", ["131072"])[0]))
        if path == "/api/lanes":
            return self._send(json.dumps(lanes_json()))
        if path == "/api/events":
            head = q.get("head", ["user"])[0]
            n = int(q.get("n", ["100"])[0])
            f = os.path.join(lc.heads_root(), head, "events.jsonl")
            rows = []
            if os.path.exists(f):
                with open(f, encoding="utf-8", errors="replace") as fh:
                    rows = [l.strip() for l in fh if l.strip()][-n:]
            return self._send("[" + ",".join(rows) + "]")
        if path.startswith("/api/log/"):
            name = urllib.parse.unquote(path[9:])
            f = os.path.join(lc.lane_dir(name), "console.log")
            if not os.path.exists(f):
                return self._send(b"", code=404)
            tail = int(q.get("tail", ["65536"])[0])
            with open(f, "rb") as fh:
                size = os.path.getsize(f)
                fh.seek(max(0, size - tail))
                return self._send(fh.read(), "application/octet-stream")
        if path == "/":
            path = "/index.html"
        f = os.path.realpath(os.path.join(self.www, path.lstrip("/")))
        if not f.startswith(os.path.realpath(self.www)) or not os.path.isfile(f):
            return self._send(b"not found", "text/plain", 404)
        with open(f, "rb") as fh:
            return self._send(fh.read(), CTYPES.get(os.path.splitext(f)[1], "application/octet-stream"))

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not path.startswith("/api/send/"):
            return self._send(b"not found", "text/plain", 404)
        name = urllib.parse.unquote(path[10:])
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        s = lc.connect(lc.lane_dir(name), 2.0)
        lc.write_frame(s, lc.PASTE, body)
        s.close()
        return self._send('{"ok":true}')

    def ws_bridge(self, name, tail):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        conn = self.connection
        try:
            lane = lc.connect(lc.lane_dir(name), 3.0)
        except OSError:
            ws_send(conn, struct.pack("!H", 1011) + b"host not reachable", 8)
            return
        lc.write_frame(lane, lc.SUBSCRIBE, struct.pack("<q", -tail))
        send_lock = threading.Lock()

        def pump():
            try:
                while True:
                    fr = lc.read_frame(lane)
                    if fr is None:
                        break
                    t, p = fr
                    with send_lock:
                        if t == lc.OUTPUT:
                            ws_send(conn, p, 2)
                        elif t == lc.EXIT:
                            ws_send(conn, json.dumps({"exit": int(p or b"0")}).encode(), 1)
                            break
                        elif t == lc.GAP:
                            ws_send(conn, json.dumps({"gap": int(p or b"0")}).encode(), 1)
            except OSError:
                pass
            try:
                with send_lock:
                    ws_send(conn, struct.pack("!H", 1000), 8)
            except OSError:
                pass

        threading.Thread(target=pump, daemon=True).start()
        try:
            while True:
                m = ws_recv(self.rfile)
                if m is None or m[0] == 8:
                    break
                op, data = m
                if op == 9:
                    with send_lock:
                        ws_send(conn, data, 10)
                elif op == 2:
                    lc.write_frame(lane, lc.INPUT, data)
                elif op == 1:
                    try:
                        o = json.loads(data.decode("utf-8"))
                    except ValueError:
                        continue
                    if isinstance(o.get("resize"), list) and len(o["resize"]) == 2:
                        lc.write_frame(lane, lc.RESIZE, struct.pack("<HH", int(o["resize"][0]), int(o["resize"][1])))
                    if isinstance(o.get("input"), str):
                        lc.write_frame(lane, lc.INPUT, o["input"].encode("utf-8"))
        except OSError:
            pass
        finally:
            try:
                lane.shutdown(socket.SHUT_RDWR)
                lane.close()
            except OSError:
                pass
        self.close_connection = True


def serve(port, www):
    Handler.www = www
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.daemon_threads = True
    print("lanes viewer on http://127.0.0.1:%d/  (root %s)" % (port, lc.lanes_root()), flush=True)
    srv.serve_forever()
    return 0
