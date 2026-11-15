#!/usr/bin/env python3

import sys
from pathlib import Path


GLOBAL_HEADER = b"!<arch>\n"
HEADER_LEN = 60


def parse_decimal(field: bytes) -> int:
    text = field.decode("ascii").strip()
    return int(text) if text else 0


def render_header(name: bytes, mode: bytes, size: int) -> bytes:
    return (
        name.ljust(16, b" ")[:16]
        + b"0".ljust(12, b" ")
        + b"0".ljust(6, b" ")
        + b"0".ljust(6, b" ")
        + mode.ljust(8, b" ")[:8]
        + str(size).encode("ascii").ljust(10, b" ")
        + b"`\n"
    )


def normalize(path: Path) -> None:
    source = path.read_bytes()
    if not source.startswith(GLOBAL_HEADER):
        raise SystemExit(f"{path}: not an ar archive")

    members: list[tuple[bytes, bytes, bytes, bytes]] = []
    offset = len(GLOBAL_HEADER)
    while offset < len(source):
        header = source[offset : offset + HEADER_LEN]
        if len(header) != HEADER_LEN:
            raise SystemExit(f"{path}: truncated ar header")
        if header[58:60] != b"`\n":
            raise SystemExit(f"{path}: invalid ar header")
        raw_name = header[0:16]
        mode = header[40:48]
        size = parse_decimal(header[48:58])
        payload_start = offset + HEADER_LEN
        payload_end = payload_start + size
        payload = source[payload_start:payload_end]
        if len(payload) != size:
            raise SystemExit(f"{path}: truncated ar member")
        members.append((raw_name, mode, payload, header))
        offset = payload_end + (size & 1)

    out = bytearray(GLOBAL_HEADER)
    for raw_name, mode, payload, original_header in members:
        if raw_name.startswith(b"#1/"):
            name_len = parse_decimal(raw_name[3:])
            # The Darwin linker expects Mach-O member payloads to start on an
            # 8-byte boundary. BSD extended names put the object after the name
            # bytes, so a normal even-byte ar pad is not enough.
            object_start = len(out) + HEADER_LEN + name_len
            pad = (-object_start) % 8
            if pad != 0:
                payload = payload[:name_len] + (b"\n" * pad) + payload[name_len:]
                raw_name = f"#1/{name_len + pad}".encode("ascii")
        out.extend(render_header(raw_name, mode, len(payload)))
        out.extend(payload)
        if len(payload) & 1:
            out.extend(b"\n")

    if bytes(out) != source:
        path.write_bytes(out)
    else:
        # Zig can reinstall a content-identical cached archive with its old
        # timestamp. The install step has just checked its current inputs.
        path.touch()


def main() -> int:
    if len(sys.argv) < 2:
        raise SystemExit("usage: normalize_darwin_archive.py ARCHIVE...")
    for arg in sys.argv[1:]:
        normalize(Path(arg))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
