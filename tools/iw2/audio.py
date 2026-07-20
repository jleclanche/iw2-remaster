"""Extract audio WAVs from resource.zip to data/audio (music MP3s stay in
the game's streams/ dir and are loaded from there directly).

WAVs are normalized to minimal RIFF (fmt + data only): the originals
carry trailing smpl/LIST chunks that Godot's parser over-reads, and loop
points are set in engine code anyway.

Usage:  python -m tools.iw2.audio [out_dir]
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

from .resources import ResourceFS


def clean_wav(data: bytes) -> bytes:
    """Rebuild a WAV keeping only the fmt and data chunks."""
    if len(data) < 12 or data[:4] != b"RIFF":
        return data
    fmt = b""
    payload = b""
    pos = 12
    while pos + 8 <= len(data):
        tag = data[pos:pos + 4]
        size = min(struct.unpack_from("<I", data, pos + 4)[0],
                   len(data) - pos - 8)
        if tag == b"fmt ":
            fmt = data[pos:pos + 8 + size]
        elif tag == b"data":
            payload = data[pos:pos + 8 + size]
        pos += 8 + size + (size & 1)
    if not fmt or not payload:
        return data
    body = fmt + payload
    # RIFF pads odd chunks to even; the originals omit the pad byte and
    # Godot's parser then seeks one past EOF (gatling.wav, 17251-byte data)
    if len(body) & 1:
        body += b"\x00"
    return b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body


def main(out_dir: str = "data/audio") -> None:
    fs = ResourceFS()
    out = Path(out_dir)
    n = 0
    for path in fs.list("audio/", ".wav") + fs.list("", ".wav"):
        dest = out / Path(path)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(clean_wav(fs.read_bytes(path)))
        n += 1
    print(f"extracted {n} wavs to {out}")


if __name__ == "__main__":
    main(*sys.argv[1:])
