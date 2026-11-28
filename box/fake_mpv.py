#!/usr/bin/env python3
"""A stand-in for mpv in tests: answers the JSON IPC calls syncbox.py makes, with a picture
position that runs on the real clock. Shows nothing. Length: FAKE_MPV_DURATION (default 20 s)."""

import json
import os
import socket
import sys
import threading
import time

ipc = next(a.split("=", 1)[1] for a in sys.argv if a.startswith("--input-ipc-server="))
dur = float(os.environ.get("FAKE_MPV_DURATION", "20"))
loop = any(a == "--loop-file=inf" for a in sys.argv)
state = {"pos0": 0.0, "t0": time.monotonic(), "paused": True, "speed": 1.0, "loop": loop}
lock = threading.Lock()


def pos():
    p = state["pos0"]
    if not state["paused"]:
        p += (time.monotonic() - state["t0"]) * state["speed"]
    return p % dur if state["loop"] else min(p, dur)


def rebase():
    state["pos0"], state["t0"] = pos(), time.monotonic()


def handle(cmd):
    name = cmd[0]
    with lock:
        if name == "get_property":
            v = {"time-pos": int(pos() * 30) / 30, "duration": dur, "container-fps": 30.0,
                 "pause": state["paused"], "speed": state["speed"]}.get(cmd[1])
            return v, v is not None
        if name == "set_property":
            rebase()
            if cmd[1] == "pause":
                state["paused"] = bool(cmd[2])
            elif cmd[1] == "speed":
                state["speed"] = float(cmd[2])
            elif cmd[1] == "loop-file":
                state["loop"] = cmd[2] == "inf"
            return None, True
        if name == "seek":
            state["pos0"], state["t0"] = min(max(0.0, float(cmd[1])), dur), time.monotonic()
            return None, True
        if name == "quit":
            os._exit(0)
    return None, False


srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(ipc)
srv.listen(1)
conn, _ = srv.accept()
buf = b""
while True:
    chunk = conn.recv(65536)
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        m = json.loads(line)
        data, ok = handle(m["command"])
        conn.sendall(json.dumps({"data": data, "request_id": m.get("request_id"),
                                 "error": "success" if ok else "property unavailable"}).encode()
                     + b"\n")
