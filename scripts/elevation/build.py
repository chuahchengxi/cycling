"""Bundled elevation grid for offline climb charts.

Samples Mapzen/AWS Terrarium elevation tiles (public, z12, ~38 m/px, SRTM-based)
on a regular grid over Singapore at BUILD time only; the app reads the result
and never goes online. Output: cyclingskibidi/elevation.bin, little-endian
Int16 decimetres, row-major from the south-west corner. The grid constants
must match Elevation.swift.

    python3 scripts/elevation/build.py [tile-cache-dir]
"""
import io, math, os, struct, sys, urllib.request
from PIL import Image

LAT0, LON0, STEP = 1.15, 103.60, 0.0009   # ~100 m
ROWS, COLS = 380, 580                     # to 1.4911 N, 104.1211 E
Z = 12
OUT = os.path.join(os.path.dirname(__file__), "../../cyclingskibidi/elevation.bin")
cache = sys.argv[1] if len(sys.argv) > 1 else "terrarium-cache"
os.makedirs(cache, exist_ok=True)
tiles = {}

def tile(x, y):
    if (x, y) not in tiles:
        path = os.path.join(cache, f"{Z}-{x}-{y}.png")
        if not os.path.exists(path):
            url = f"https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{Z}/{x}/{y}.png"
            open(path, "wb").write(urllib.request.urlopen(url, timeout=60).read())
        tiles[(x, y)] = Image.open(path).convert("RGB").load()
    return tiles[(x, y)]

def elevation(lat, lon):
    n = 2 ** Z * 256
    px = (lon + 180) / 360 * n
    py = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    x, y = int(px), int(py)
    r, g, b = tile(x // 256, y // 256)[x % 256, y % 256]
    return max(0.0, r * 256 + g + b / 256 - 32768)   # sea and reclaimed edges read as 0

with open(OUT, "wb") as f:
    for r in range(ROWS):
        for c in range(COLS):
            f.write(struct.pack("<h", round(elevation(LAT0 + r * STEP, LON0 + c * STEP) * 10)))
print("wrote", OUT, ROWS * COLS * 2, "bytes;",
      "Bukit Timah", round(elevation(1.3546, 103.7764)), "m, Marina Bay", round(elevation(1.2834, 103.8607)), "m")
