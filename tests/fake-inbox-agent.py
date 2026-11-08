"""A CLI with bracketed paste and a capture file, for the real PTY notification tests."""
import json
import os
import sys
import time

if os.name == "nt":
    import ctypes
    kernel = ctypes.windll.kernel32
    kernel.SetConsoleMode(kernel.GetStdHandle(-10), 0x0200 | 0x0080)

    def read_char():
        return os.read(sys.stdin.fileno(), 1).decode("latin1")
else:
    import tty
    tty.setraw(sys.stdin.fileno())

    def read_char():
        return os.read(sys.stdin.fileno(), 1).decode("latin1")

print("\x1b[?2004hAgent ready", flush=True)
body = ""
while True:
    char = read_char()
    body += char
    if char == "\r":
        with open(os.path.join(os.environ["LANES_LANE_DIR"], "received.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(body) + "\n")
        print("accepted", flush=True)
        body = ""
