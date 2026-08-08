#!/usr/bin/env python3
"""Quick script to inspect manifest dependencies."""
import json
from pathlib import Path

manifest = json.load(open("target/manifest.json"))
nodes = manifest.get("nodes", {})
sources = manifest.get("sources", {})

print("=" * 70)
print("MANIFEST INSPECTION")
print("=" * 70)

# Show sources
print(f"\nSOURCES ({len(sources)}):")
for src_id in sorted(sources.keys())[:20]:
    print(f"  {src_id}")
if len(sources) > 20:
    print(f"  ... and {len(sources) - 20} more")

# Show models with their source dependencies
print("\nMODELS WITH SOURCE DEPENDENCIES:")
models_with_sources = []
for node_id, node in nodes.items():
    if node.get("resource_type") != "model":
        continue
    deps = node.get("depends_on", {}).get("nodes", [])
    source_deps = [d for d in deps if d.startswith("source.")]
    if source_deps:
        models_with_sources.append({
            "name": node.get("name"),
            "path": node.get("original_file_path"),
            "source_deps": source_deps
        })

if not models_with_sources:
    print("  (No models have direct source dependencies)")
else:
    for m in models_with_sources[:20]:
        print(f"\n  {m['name']} ({m['path']}):")
        for dep in m["source_deps"]:
            print(f"    - {dep}")

print("\n" + "=" * 70)
