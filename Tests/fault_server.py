"""Bounded SFTP failure cases; no network, keys, or real server files."""
import os
import signal
import struct
import sys
import time

mode = sys.argv[1]

def exact(n):
    result = b""
    while len(result) < n:
        part = os.read(0, n - len(result))
        if not part:
            raise EOFError
        result += part
    return result

def packet():
    return exact(struct.unpack(">I", exact(4))[0])

def send(data):
    frame = struct.pack(">I", len(data)) + data
    while frame:
        frame = frame[os.write(1, frame):]

def string(value):
    return struct.pack(">I", len(value)) + value

try:
    packet()
    if mode == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(sys.argv[2], "w") as target:
            target.write(str(os.getpid()))
        time.sleep(20)
    elif mode == "bad-version":
        send(b"\x02" + struct.pack(">I", 99))
        time.sleep(20)
    else:
        send(b"\x02" + struct.pack(">I", 3))
        request = packet()
        request_id = request[1:5]
        if mode == "fragmented":
            reply = b"\x68" + request_id + struct.pack(">I", 1) + string(b"/slow") + string(b"") + struct.pack(">I", 0)
            frame = struct.pack(">I", len(reply)) + reply
            time.sleep(0.2)
            for byte in frame:
                os.write(1, bytes([byte]))
                time.sleep(0.01)
        elif mode == "disconnect":
            sys.exit(0)
        elif mode == "timeout":
            time.sleep(20)
        elif mode == "oversized":
            os.write(1, struct.pack(">I", 8 * 1024 * 1024))
        elif mode == "truncated":
            send(b"\x68\x00")
        elif mode == "wrong-id":
            send(b"\x68" + b"\xff" * 4 + struct.pack(">I", 1) + string(b"/"))
        elif mode == "relative-path":
            send(b"\x68" + request_id + struct.pack(">I", 1) + string(b"relative/path"))
        elif mode == "directory-limit":
            send(b"\x66" + request_id + string(b"directory"))
            batch = struct.pack(">I", 1000)
            for i in range(1000):
                batch += string(("file-%04d" % i).encode()) + string(b"") + struct.pack(">I", 0)
            while True:
                request = packet()
                if request[0] == 4:
                    send(b"\x65" + request[1:5] + struct.pack(">I", 0))
                    break
                send(b"\x68" + request[1:5] + batch)
        else:
            raise AssertionError(mode)
except (EOFError, BrokenPipeError):
    pass
