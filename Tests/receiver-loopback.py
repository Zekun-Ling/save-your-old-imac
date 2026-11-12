#!/usr/bin/env python3
"""Exercise receiver stream ordering and reconnect without Screen Recording."""

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time


def packet(kind, payload):
    return struct.pack("<BI", kind, len(payload)) + payload


def hello(width):
    return packet(1, json.dumps({"v": 2, "w": width, "h": 32, "fps": 60, "name": "test"}).encode())


def parameter_sets(sps, pps):
    return packet(3, struct.pack("<H", len(sps)) + sps + struct.pack("<H", len(pps)) + pps)


def frame(seconds, keyframe, nal, length=None):
    avcc = struct.pack(">I", len(nal) if length is None else length) + nal
    return packet(4, struct.pack("<qB", seconds * 1_000_000, keyframe) + avcc)


# Two frames of a 32x32 black image encoded with libx264. No ffmpeg is
# needed to run this test.
PARAMS = parameter_sets(
    bytes.fromhex("6742c00ada25b011000003000100000300788f1226a0"),
    bytes.fromhex("68ce0fc8"),
)
IDR = bytes.fromhex("6588843a2628000902c9d75e")
P_FRAME = bytes.fromhex("419a206a2c")


def read_exact(peer, size):
    data = b""
    while len(data) < size:
        chunk = peer.recv(size - len(data))
        if not chunk:
            raise EOFError("receiver closed before sending capabilities")
        data += chunk
    return data


def connect():
    peer = socket.create_connection(("127.0.0.1", 52525), timeout=3)
    try:
        kind, size = struct.unpack("<BI", read_exact(peer, 5))
        assert kind == 2 and size <= 4096, "missing receiver capabilities"
        read_exact(peer, size)
        return peer
    except BaseException:
        peer.close()
        raise


def wait_for(log, marker):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if marker in log.read_text():
            return
        time.sleep(0.02)
    raise AssertionError(f"receiver did not log {marker!r}\n{log.read_text()}")


def check_rejected(log, seconds):
    pts = seconds * 1_000_000
    wait_for(log, f"received pts_us={pts} ")
    assert f"enqueued pts_us={pts} " not in log.read_text(), "invalid frame enqueued"


def exercise(log):
    wait_for(log, "listening at 127.0.0.1:52525")
    with connect() as peer:
        peer.sendall(parameter_sets(b"", b"") + PARAMS + hello(0) + frame(1, True, IDR))
        check_rejected(log, 1)
        peer.sendall(hello(32) + frame(2, True, IDR))
        check_rejected(log, 2)
        peer.sendall(PARAMS + frame(3, True, P_FRAME) + frame(4, True, IDR, length=999))
        check_rejected(log, 3)
        check_rejected(log, 4)
        peer.sendall(frame(5, True, IDR) + frame(6, False, P_FRAME))
        wait_for(log, "streaming 32x32@60")
        wait_for(log, "enqueued pts_us=6000000 ")
        peer.sendall(parameter_sets(b"", b"") + frame(7, False, P_FRAME))
        check_rejected(log, 7)
        peer.shutdown(socket.SHUT_WR)
        assert not peer.recv(1), "receiver failed to close after EOF"

    with connect() as peer:
        peer.sendall(hello(32) + frame(8, True, IDR))
        check_rejected(log, 8)
        peer.settimeout(15)
        assert not peer.recv(1), "incomplete session held the only connection slot"
        wait_for(log, "no usable video within 12 seconds")

    with connect() as peer:
        peer.sendall(hello(32) + PARAMS + frame(9, True, IDR))
        wait_for(log, "enqueued pts_us=9000000 ")

    # Negative assertions after the positive barriers above verify that the
    # main-queue callback had time to run for each rejected frame.
    contents = log.read_text()
    for seconds in (1, 2, 3, 4, 7, 8):
        assert f"enqueued pts_us={seconds * 1_000_000} " not in contents
    assert contents.count("streaming 32x32@60") == 2


if __name__ == "__main__":
    receiver = sys.argv[1] if len(sys.argv) > 1 else ".build-swiftc/universal/LunaReceiver"
    with tempfile.TemporaryDirectory() as folder:
        log = Path(folder) / "receiver.log"
        with log.open("wb") as output:
            process = subprocess.Popen(
                [receiver, "--headless", "--loopback-only"],
                stderr=output,
                env={**os.environ, "LUNA_TRACE_LATENCY": "1"},
            )
            try:
                exercise(log)
            finally:
                process.terminate()
                process.wait(timeout=3)
    print("receiver-loopback: PASS (order, malformed input, timeout and reconnect)")
