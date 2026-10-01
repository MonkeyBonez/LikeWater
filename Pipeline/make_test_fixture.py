"""Writes the tiny bundle the Swift reader tests load.

Keeping the fixture on the writer's side means the Swift test is a real contract
test of the binary format, not a test of a second hand-written encoder.
"""
import sys
from pathlib import Path
import numpy as np
import bundle_format as bf

OUT = Path(__file__).parent.parent / "Engine/Tests/LikeWaterEngineTests/Fixtures/tiny.lwbundle"

# 4 nodes in a square, 60 m sides, one of them a crossing.
lat = [37.7800, 37.7800, 37.78054, 37.78054]
lon = [-122.4100, -122.40932, -122.40932, -122.4100]
edge_a = [0, 1, 2, 3]
edge_b = [1, 2, 3, 0]
edge_len = [60.0, 60.0, 60.0, 60.0]
edge_flags = [bf.FLAG_SIDEWALK, bf.FLAG_CROSSING, bf.FLAG_SIDEWALK, 0]
edge_interest = [0, 4, 9, 255]

node_count = len(lat)
degree = np.zeros(node_count + 1, dtype=np.int64)
for a, b in zip(edge_a, edge_b):
    degree[a] += 1
    degree[b] += 1
adj_start = np.zeros(node_count + 1, dtype=np.int64)
np.cumsum(degree[:-1], out=adj_start[1:])
cursor = adj_start.copy()
adj_node = np.zeros(2 * len(edge_a), dtype=np.int64)
adj_edge = np.zeros(2 * len(edge_a), dtype=np.int64)
for i, (a, b) in enumerate(zip(edge_a, edge_b)):
    adj_node[cursor[a]] = b; adj_edge[cursor[a]] = i; cursor[a] += 1
    adj_node[cursor[b]] = a; adj_edge[cursor[b]] = i; cursor[b] += 1

# One 30 m building just south of the square.
bld_start = [0, 4]
bld_lat = [37.77960, 37.77960, 37.77985, 37.77985]
bld_lon = [-122.40990, -122.40960, -122.40960, -122.40990]
bld_height = [30.0]

# A 4x4 terrain grid at ~60 m spacing: flat at 5 m except a 40 m hill in the SE corner.
import numpy as _np
terrain = dict(rows=4, cols=4, origin_lat=37.7790, origin_lon=-122.4110,
               step_lat=60 / 111320.0, step_lon=60 / (111320.0 * _np.cos(_np.radians(37.78))),
               elevation=_np.array([[5, 5, 5, 5], [5, 5, 5, 5], [5, 5, 5, 45], [5, 5, 45, 45]], dtype=_np.int16))
bld_ground = [5.0]

OUT.parent.mkdir(parents=True, exist_ok=True)
stats = bf.write_bundle(
    OUT, node_lat=lat, node_lon=lon,
    adj_start=adj_start, adj_node=adj_node, adj_edge=adj_edge,
    edge_a=edge_a, edge_b=edge_b, edge_len=edge_len,
    edge_flags=edge_flags, edge_interest=edge_interest,
    bld_start=bld_start, bld_lat=bld_lat, bld_lon=bld_lon, bld_height=bld_height,
    bbox=(min(lat), min(lon), max(lat), max(lon)),
    bld_ground=bld_ground, terrain=terrain)
print(OUT, stats, OUT.stat().st_size, "bytes")
