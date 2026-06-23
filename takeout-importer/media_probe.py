"""
Probe video duration without external dependencies.

Supports MP4, MOV, 3GP, M4V (ISOBMFF containers) by parsing the
`mvhd` box directly. Returns milliseconds, or None for unsupported
formats or corrupt files.
"""

import struct


def probe_duration_ms(path: str) -> int | None:
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    if ext not in {"mp4", "mov", "3gp", "m4v", "m4p", "mp"}:
        return None
    try:
        with open(path, "rb") as f:
            return _parse_isobmff(f)
    except Exception:
        return None


def _parse_isobmff(f) -> int | None:
    """Walk top-level boxes, recurse into moov, read mvhd."""
    while True:
        header = f.read(8)
        if len(header) < 8:
            return None
        size, box_type = struct.unpack(">I4s", header)
        box_type = box_type.decode("latin-1")

        if size == 1:
            # 64-bit extended size
            ext_size = struct.unpack(">Q", f.read(8))[0]
            payload_size = ext_size - 16
        elif size == 0:
            # box extends to EOF
            payload_size = -1
        else:
            payload_size = size - 8

        if box_type == "moov":
            return _parse_moov(f, payload_size)

        # Skip this box
        if payload_size < 0:
            return None
        f.seek(payload_size, 1)


def _parse_moov(f, size: int) -> int | None:
    """Scan moov children for mvhd."""
    end = f.tell() + size
    while f.tell() < end:
        header = f.read(8)
        if len(header) < 8:
            return None
        child_size, child_type = struct.unpack(">I4s", header)
        child_type = child_type.decode("latin-1")

        if child_size == 1:
            ext_size = struct.unpack(">Q", f.read(8))[0]
            payload_size = ext_size - 16
        elif child_size == 0:
            payload_size = end - f.tell()
        else:
            payload_size = child_size - 8

        if child_type == "mvhd":
            return _read_mvhd(f)

        f.seek(payload_size, 1)
    return None


def _read_mvhd(f) -> int | None:
    """Parse mvhd box and return duration in milliseconds."""
    version = struct.unpack(">B", f.read(1))[0]
    f.read(3)  # flags
    if version == 1:
        f.read(8)  # creation_time (64-bit)
        f.read(8)  # modification_time (64-bit)
        timescale = struct.unpack(">I", f.read(4))[0]
        duration = struct.unpack(">Q", f.read(8))[0]
    else:
        f.read(4)  # creation_time (32-bit)
        f.read(4)  # modification_time (32-bit)
        timescale = struct.unpack(">I", f.read(4))[0]
        duration = struct.unpack(">I", f.read(4))[0]

    if timescale == 0:
        return None
    return int(duration * 1000 // timescale)
