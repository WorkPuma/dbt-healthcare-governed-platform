#!/usr/bin/env python3
"""Validate docs/testing/boundary_coverage_registry.yml against project YAML/SQL.

For each required control on a model node, checks that a matching test pattern
exists in the model's YAML or in tests/*.sql that reference the model.

Usage:
  python3 scripts/check_boundary_coverage.py
  python3 scripts/check_boundary_coverage.py --warn-only
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "docs" / "testing" / "boundary_coverage_registry.yml"

CONTROL_PATTERNS = {
    "freshness": re.compile(
        r"freshness|volume_anomalies|event_freshness|freshness_anomalies", re.I
    ),
    "conservation": re.compile(r"raw_stage_row_conservation|equal_rowcount|conservation", re.I),
    "grain": re.compile(
        r"unique_combination_of_columns|expect_compound_columns_to_be_unique|"
        r"^\s*-\s*unique\b|unique_key",
        re.I | re.M,
    ),
    "reconciliation": re.compile(
        r"reconciliation|equal_rowcount|parity|tie.?out|collapse|rollup|"
        r"raw_stage_row_conservation",
        re.I,
    ),
    "relationships": re.compile(r"relationships\s*:", re.I),
    "transformation_invariant": re.compile(
        r"reconciliation|hierarchy|component|invariant|unit_tests", re.I
    ),
    # SQL config enabled=false OR YAML enabled: false / meta.deferred
    "deferred": re.compile(r"deferred\s*:\s*true|enabled\s*[=:]\s*false", re.I),
}

REF_RE = re.compile(r"""ref\(\s*['"]([^'"]+)['"]\s*\)""")


def iter_model_yaml(models_dir: Path):
    for ext in ("*.yml", "*.yaml"):
        yield from models_dir.rglob(ext)


def model_name_from_node(node: str) -> str:
    """Accept model.<name> or model.<package>.<name>; return bare model name."""
    parts = node.split(".")
    if parts and parts[0] == "model":
        parts = parts[1:]
    return parts[-1] if parts else node


def load_model_yaml_blob(models_dir: Path, model_name: str) -> str:
    for yml in iter_model_yaml(models_dir):
        try:
            data = yaml.safe_load(yml.read_text(errors="ignore")) or {}
        except yaml.YAMLError:
            continue
        for model in data.get("models") or []:
            if not isinstance(model, dict):
                continue
            if model.get("name") == model_name:
                return yaml.dump(model, sort_keys=False)
    return ""


def load_model_sql(models_dir: Path, model_name: str) -> str:
    for sql in models_dir.rglob(f"{model_name}.sql"):
        return sql.read_text(errors="ignore")
    return ""


def build_ref_index(tests_dir: Path) -> dict[str, str]:
    """One-pass index of model name -> concatenated singular test SQL."""
    index: dict[str, list[str]] = defaultdict(list)
    for sql in tests_dir.rglob("*.sql"):
        text = sql.read_text(errors="ignore")
        for name in set(REF_RE.findall(text)):
            index[name].append(text)
    return {k: "\n".join(v) for k, v in index.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--warn-only", action="store_true")
    parser.add_argument("--registry", type=Path, default=REGISTRY)
    args = parser.parse_args()

    reg = yaml.safe_load(args.registry.read_text()) or {}
    models_dir = ROOT / "models"
    tests_dir = ROOT / "tests"
    ref_index = build_ref_index(tests_dir)
    missing: list[str] = []

    for pname, pipe in (reg.get("pipelines") or {}).items():
        if pipe.get("status") == "deferred":
            for layer in pipe.get("layers") or []:
                node = layer["node"]
                if not node.startswith("model."):
                    continue
                name = model_name_from_node(node)
                blob = load_model_yaml_blob(models_dir, name) + "\n" + load_model_sql(
                    models_dir, name
                )
                if not CONTROL_PATTERNS["deferred"].search(blob):
                    missing.append(f"{pname}/{name}: missing deferred governance")
            continue

        for layer in pipe.get("layers") or []:
            node = layer["node"]
            controls = layer.get("required_controls") or []
            if node.startswith("source."):
                continue
            if not node.startswith("model."):
                continue
            name = model_name_from_node(node)
            blob = (
                load_model_yaml_blob(models_dir, name)
                + "\n"
                + load_model_sql(models_dir, name)
                + "\n"
                + ref_index.get(name, "")
            )
            for ctrl in controls:
                pat = CONTROL_PATTERNS.get(ctrl)
                if pat is None:
                    missing.append(f"{pname}/{name}: unknown control {ctrl}")
                    continue
                if not pat.search(blob):
                    missing.append(f"{pname}/{name}: missing control '{ctrl}'")

    for msg in missing:
        print(f"MISSING: {msg}")
    if missing and not args.warn_only:
        print(f"\ncheck_boundary_coverage FAILED: {len(missing)} gap(s)")
        return 1
    print(f"\ncheck_boundary_coverage OK: {len(missing)} gap(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
