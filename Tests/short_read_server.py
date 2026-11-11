"""SFTP fixture: short, out-of-order READ replies; no network or dependencies."""
import os
import select
import struct

SIZE = 700123
pending = []


def u32(n):
    return struct.pack(">I", n)


def string(data):
    return u32(len(data)) + data


def send(kind, data):
    packet = bytes([kind]) + data
    os.write(1, u32(len(packet)) + packet)


def read_exact(n):
    result = b""
    while len(result) < n:
        part = os.read(0, n - len(result))
        if not part:
            raise EOFError
        result += part
    return result


try:
    while True:
        if pending and not select.select([0], [], [], 0.005)[0]:
            for request_id, offset, length in reversed(pending):
                length = min(length, 7001, SIZE - offset)
                data = bytes(((offset + i) * 31) % 256 for i in range(length))
                send(103, request_id + string(data))
            pending.clear()
        packet = read_exact(struct.unpack(">I", read_exact(4))[0])
        kind, request_id = packet[0], packet[1:5]
        if kind == 1:
            send(2, u32(3))
        elif kind == 17:
            send(105, request_id + u32(13) + struct.pack(">QIII", SIZE, 0o100600, 1, 1))
        elif kind == 3:
            send(102, request_id + string(b"file"))
        elif kind == 5:
            offset, length = struct.unpack(">QI", packet[13:25])
            pending.append((request_id, offset, length))
        elif kind == 4:
            send(101, request_id + u32(0) + string(b"") + string(b""))
        else:
            raise AssertionError(kind)
except EOFError:
    pass
