#!/usr/bin/env python3
"""Package resized PNGs as a macOS ICNS file using only the standard library."""
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = root / "Resources/AppIcon.png"
variants = [("icp4", 16), ("icp5", 32), ("icp6", 64),
            ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
            ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
chunks = []
with tempfile.TemporaryDirectory(prefix="oplus-icon-") as temp:
    for kind, size in variants:
        target = Path(temp) / f"{kind}.png"
        subprocess.run(["sips", "-z", str(size), str(size), str(source),
                        "--out", str(target)], check=True, stdout=subprocess.DEVNULL)
        png = target.read_bytes()
        if png[:8] != b"\x89PNG\r\n\x1a\n" or struct.unpack(">II", png[16:24]) != (size, size):
            raise ValueError(f"Invalid resized PNG: {kind}")
        chunks.append(kind.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
body = b"".join(chunks)
output = root / "Resources/AppIcon.icns"
output.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
print(f"Built icon: {output}")
