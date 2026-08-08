#!/usr/bin/env python3
"""List all incremental models grouped by their on-disk directory."""

import json
import re
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
manifest = json.loads((REPO / "target" / "manifest.json").read_text(encoding="utf-8"))

by_dir = defaultdict(list)
already_protected = []
unprotected = []

for uid, node in manifest["nodes"].items():
    if not uid.startswith("model."):
        continue
    cfg = node.get("config", {}) or {}
    if cfg.get("materialized") != "incremental":
        continue
    path = node.get("original_file_path", "")
    # Group by first 2-3 path segments under models/
    parts = Path(path).parts
    if parts and parts[0] == "models":
        key = "/".join(parts[1:-1])  # directory under models/
    else:
        key = "?"
    full_refresh = cfg.get("full_refresh")
    by_dir[key].append((node["name"], full_refresh))
    if full_refresh is False:
        already_protected.append(node["name"])
    else:
        unprotected.append((node["name"], path))

print(f"Total incremental models: {sum(len(v) for v in by_dir.values())}")
print(f"  already protected (+full_refresh=false): {len(already_protected)}")
print(f"  UNPROTECTED: {len(unprotected)}\n")

print("By directory (sorted):")
for d in sorted(by_dir):
    rows = by_dir[d]
    protected = sum(1 for _, fr in rows if fr is False)
    print(f"  {d:<60} {len(rows):3d} total, {protected:3d} protected")

print("\nUnprotected models (first 60):")
for name, path in sorted(unprotected)[:60]:
    print(f"  {path}  -> {name}")
if len(unprotected) > 60:
    print(f"  ... and {len(unprotected) - 60} more")
