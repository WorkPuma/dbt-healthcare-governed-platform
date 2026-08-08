#!/usr/bin/env python3
"""CI validator for the contract consolidation ledger.

Ensures every enabled healthcare_analytics model in manifest is present in the ledger CSV.
Ensures any model with enabled:false or deprecated tags has deprecation_date and
deprecation_ticket populated.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "target" / "manifest.json"
DEFAULT_LEDGER = REPO_ROOT / "seeds" / "audit" / "ref_dbt_consolidation_ledger.csv"


def load_ledger(ledger_path: Path) -> dict[str, dict[str, str]]:
    """Load the ledger CSV into a dictionary indexed by model_name.

    Fails if the same model_name appears more than once (silent overwrite is unsafe).
    """
    ledger: dict[str, dict[str, str]] = {}
    with ledger_path.open("r", newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            name = row["model_name"]
            if name in ledger:
                raise ValueError(
                    f"Duplicate model_name '{name}' in ledger CSV {ledger_path}. "
                    "Each model_name must appear exactly once."
                )
            ledger[name] = row
    return ledger


def _collect_manifest_model_tags(
    nodes: dict,
    disabled_nodes: dict,
    project_name: str,
) -> dict[str, set[str]]:
    """Collect tags per model_name from manifest nodes (source of truth)."""
    tags_by_model: dict[str, set[str]] = {}

    def _add(node: dict) -> None:
        if node.get("resource_type") != "model" or node.get("package_name") != project_name:
            return
        name = node.get("name")
        if not name:
            return
        tags_by_model.setdefault(name, set()).update(node.get("tags") or [])

    for node in nodes.values():
        _add(node)
    for node_list in disabled_nodes.values():
        for node in node_list:
            _add(node)
    return tags_by_model


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate contract consolidation ledger.")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST, help="Path to manifest.json")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER, help="Path to ledger CSV")
    args = parser.parse_args()

    if not args.ledger.exists():
        print(f"Error: Ledger CSV not found at {args.ledger}", file=sys.stderr)
        return 1

    if not args.manifest.exists():
        print(f"Error: manifest.json not found at {args.manifest}. Run dbt parse first.", file=sys.stderr)
        return 1

    try:
        ledger = load_ledger(args.ledger)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    with args.manifest.open("r", encoding="utf-8") as f:
        manifest = json.load(f)
    nodes = manifest.get("nodes", {})
    disabled_nodes = manifest.get("disabled", {})
    project_name = (manifest.get("metadata") or {}).get("project_name", "healthcare_analytics")

    # Collect enabled models from manifest
    enabled_models_in_manifest = set()
    for unique_id, node in nodes.items():
        if node.get("resource_type") == "model" and node.get("package_name") == project_name:
            if node.get("config", {}).get("enabled", True) is not False:
                enabled_models_in_manifest.add(node.get("name"))

    # Collect disabled models from manifest
    disabled_models_in_manifest = set()
    for unique_id, node_list in disabled_nodes.items():
        for node in node_list:
            if node.get("resource_type") == "model" and node.get("package_name") == project_name:
                disabled_models_in_manifest.add(node.get("name"))

    # Manifest tags are source of truth for deprecation (not stale ledger CSV tags)
    manifest_tags_by_model = _collect_manifest_model_tags(nodes, disabled_nodes, project_name)

    violations = []

    # Check 1: Every enabled healthcare_analytics model in manifest must be present in the ledger CSV
    for model_name in sorted(enabled_models_in_manifest):
        if model_name not in ledger:
            violations.append(
                f"Model '{model_name}' is enabled in manifest but missing from the ledger CSV."
            )

    # Check 2: Any model with enabled:false / deprecated tags must have deprecation_date + deprecation_ticket populated
    # We check all models present in the ledger
    for model_name, row in sorted(ledger.items()):
        is_disabled = (
            row.get("resource_enabled") in (False, "False", "false") or
            model_name in disabled_models_in_manifest
        )
        is_deprecated = "deprecated" in manifest_tags_by_model.get(model_name, set())

        if is_disabled or is_deprecated:
            dep_date = row.get("deprecation_date", "").strip()
            dep_ticket = row.get("deprecation_ticket", "").strip()

            reasons = []
            if is_disabled:
                reasons.append("enabled:false")
            if is_deprecated:
                reasons.append("deprecated tag")

            reason_str = " and ".join(reasons)

            if not dep_date or not dep_ticket:
                violations.append(
                    f"Model '{model_name}' ({reason_str}) is missing deprecation metadata in ledger: "
                    f"deprecation_date='{dep_date}', deprecation_ticket='{dep_ticket}'."
                )

    if violations:
        print(f"Validation FAILED with {len(violations)} violation(s):", file=sys.stderr)
        for v in violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    print("Validation PASSED: Consolidation ledger is fully compliant.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
