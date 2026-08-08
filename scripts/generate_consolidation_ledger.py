#!/usr/bin/env python3
"""Generate the contract consolidation ledger for healthcare_analytics models.

Reads target/manifest.json (after parse) and YAML under models/ and emits
seeds/audit/ref_dbt_consolidation_ledger.csv.
If manifest.json is missing, falls back to walking models/**/*.sql and YAML.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = REPO_ROOT / "target" / "manifest.json"
DEFAULT_LEDGER = REPO_ROOT / "seeds" / "audit" / "ref_dbt_consolidation_ledger.csv"

# Pre-seeded Wave A/B candidates and overlays
OVERLAYS = {
    "int_spend__uhc_claims": {
        "wave": "A",
        "migration_status": "keep",
        "deprecation_ticket": "DEV-4538",
        "notes": "LIVE_OBSERVED; no ref() deps; do not soft-deprecate",
    },
    "vw_wbr_physician_visits_completed": {
        "wave": "A",
        "migration_status": "candidate_fix",
        "deprecation_ticket": "DEV-4538",
    },
    "vw_wbr_physician_visits_scheduled": {
        "wave": "A",
        "migration_status": "candidate_fix",
        "deprecation_ticket": "DEV-4538",
    },
    "vw_medicare_attribution_rate": {
        "wave": "A",
        "migration_status": "soft_deprecated",
        "deprecation_ticket": "DEV-4538",  # Default ticket since not in YAML
    },
    "vw_awv_metrics_payor_alpha": {
        "wave": "B",
        "migration_status": "candidate_consolidate",
        "deprecation_ticket": "DEV-4540",
        "target_canonical_model": "vw_awv_metrics",
    },
    "vw_awv_metrics_uhc": {
        "wave": "B",
        "migration_status": "candidate_consolidate",
        "deprecation_ticket": "DEV-4540",
        "target_canonical_model": "vw_awv_metrics",
    },
    "mart_uhc_settlement": {
        "wave": "B",
        "migration_status": "keep",
        "deprecation_ticket": "DEV-4540",
        "notes": "Keep dual with by_company; P&L v1 vs v2 consumers",
    },
}


def parse_sql_config(sql_content: str) -> dict[str, Any]:
    """Parse basic config block from a SQL file."""
    match = re.search(r"{{\s*config\s*\((.*?)\)\s*}}", sql_content, re.DOTALL)
    if not match:
        return {}
    config_str = match.group(1)
    configs: dict[str, Any] = {}

    # Extract enabled
    enabled_match = re.search(r"enabled\s*=\s*(true|false)", config_str, re.IGNORECASE)
    if enabled_match:
        configs["enabled"] = enabled_match.group(1).lower() == "true"

    # Extract materialized
    mat_match = re.search(r"materialized\s*=\s*['\"](.*?)['\"]", config_str)
    if mat_match:
        configs["materialized"] = mat_match.group(1)

    # Extract tags
    tags_match = re.search(r"tags\s*=\s*\[(.*?)\]", config_str, re.DOTALL)
    if tags_match:
        configs["tags"] = [t.strip().strip("'\"") for t in tags_match.group(1).split(",") if t.strip()]

    # Extract meta dict
    meta_match = re.search(r"meta\s*=\s*\{(.*?)\}", config_str, re.DOTALL)
    if meta_match:
        meta_str = meta_match.group(1)
        meta = {}
        # Extract simple string values from meta
        for k, v in re.findall(r"['\"](.*?)['\"]\s*:\s*['\"](.*?)['\"]", meta_str):
            meta[k] = v
        # Also extract boolean/other values
        for k, v in re.findall(r"['\"](.*?)['\"]\s*:\s*(true|false)", meta_str, re.IGNORECASE):
            meta[k] = v.lower() == "true"
        configs["meta"] = meta

    # Extract schema
    schema_match = re.search(r"schema\s*=\s*['\"](.*?)['\"]", config_str)
    if schema_match:
        configs["schema"] = schema_match.group(1)

    # Extract access
    access_match = re.search(r"access\s*=\s*['\"](.*?)['\"]", config_str)
    if access_match:
        configs["access"] = access_match.group(1)

    # Extract contract enforced
    contract_enforced = False
    if (
        re.search(r"contract\s*=\s*\{[^}]*?['\"]enforced['\"]\s*:\s*true", config_str, re.IGNORECASE | re.DOTALL) or
        re.search(r"contract\s*=\s*dict\([^)]*?enforced\s*=\s*true", config_str, re.IGNORECASE | re.DOTALL) or
        re.search(r"contract\.enforced\s*=\s*true", config_str, re.IGNORECASE)
    ):
        contract_enforced = True

    if contract_enforced:
        configs["contract"] = {"enforced": True}

    return configs


def apply_overlay_and_deprecation_defaults(
    model_name: str,
    *,
    deprecation_date: str,
    deprecation_ticket: str,
    is_disabled: bool,
    is_deprecated: bool,
) -> dict[str, Any]:
    """Apply OVERLAYS and default deprecation metadata for disabled/deprecated models."""
    overlay = OVERLAYS.get(model_name, {})
    if "deprecation_ticket" in overlay:
        deprecation_ticket = overlay["deprecation_ticket"]
    if "deprecation_date" in overlay:
        deprecation_date = overlay["deprecation_date"]
    if is_disabled or is_deprecated:
        if not deprecation_date:
            deprecation_date = "2026-08-18"
        if not deprecation_ticket:
            deprecation_ticket = "DEV-4539"
    return {
        "migration_status": overlay.get("migration_status", "active"),
        "target_canonical_model": overlay.get("target_canonical_model", ""),
        "compatibility_relation": overlay.get("compatibility_relation", ""),
        "wave": overlay.get("wave", ""),
        "notes": overlay.get("notes", ""),
        "deprecation_date": deprecation_date,
        "deprecation_ticket": deprecation_ticket,
    }


def load_yaml_configs() -> dict[str, dict[str, Any]]:
    """Walk models/ and load YAML files to index model-level configurations."""
    import yaml
    index: dict[str, dict[str, Any]] = {}
    for f in sorted(REPO_ROOT.glob("models/**/*.yml")) + sorted(REPO_ROOT.glob("models/**/*.yaml")):
        try:
            doc = yaml.safe_load(f.read_text(encoding="utf-8"))
        except yaml.YAMLError as e:
            print(f"YAML parse failure in {f}: {e}", file=sys.stderr)
            sys.exit(1)
        if not isinstance(doc, dict):
            continue
        for model in doc.get("models", []) or []:
            if not isinstance(model, dict) or not model.get("name"):
                continue
            name = model["name"]
            config = model.get("config") or {}
            meta = {**model.get("meta", {}), **config.get("meta", {})}
            index[name] = {
                "config": config,
                "meta": meta,
                "columns": model.get("columns") or [],
                "tags": model.get("tags") or config.get("tags") or [],
                "access": model.get("access") or config.get("access") or "protected",
            }
    return index


def infer_schema(path: Path) -> str:
    """Infer schema name from model file path."""
    parts = path.parts
    if "dimensions" in parts:
        return "healthcare"
    if "facts" in parts:
        return "healthcare"
    if "intermediate" in parts:
        return "intermediate"
    if "sources" in parts:
        return "staging"
    if "mdm" in parts:
        return "reference_data"
    if "historical" in parts:
        return "historical"
    if "marts_bi_v3" in parts:
        return "marts_bi_v3"
    if "healthcare" in parts:
        return "healthcare"
    return "healthcare"


def infer_materialization(path: Path, schema: str) -> str:
    """Infer default materialization based on path and schema."""
    if schema in ("staging", "intermediate", "historical"):
        return "view"
    return "table"


def generate_from_manifest(manifest_path: Path) -> list[dict[str, Any]]:
    """Generate ledger rows using target/manifest.json."""
    with manifest_path.open("r", encoding="utf-8") as f:
        manifest = json.load(f)
    nodes = manifest.get("nodes", {})
    disabled_nodes = manifest.get("disabled", {})
    child_map = manifest.get("child_map", {})
    project_name = (manifest.get("metadata") or {}).get("project_name", "healthcare_analytics")

    # Collect all model nodes (both enabled and disabled); one row per unique_id
    all_nodes: list[tuple[str, dict[str, Any]]] = []
    seen_unique_ids: set[str] = set()
    for unique_id, node in nodes.items():
        if node.get("resource_type") == "model" and node.get("package_name") == project_name:
            all_nodes.append((unique_id, node))
            seen_unique_ids.add(unique_id)

    for unique_id, node_list in disabled_nodes.items():
        if unique_id in seen_unique_ids:
            continue
        merged_node: dict[str, Any] | None = None
        merged_tags: set[str] = set()
        for node in node_list:
            if node.get("resource_type") != "model" or node.get("package_name") != project_name:
                continue
            # Iterate all configs under this unique_id (for tags/etc), emit one row
            if merged_node is None:
                merged_node = dict(node)
            merged_tags.update(node.get("tags") or [])
        if merged_node is not None:
            merged_node["tags"] = sorted(merged_tags)
            all_nodes.append((unique_id, merged_node))
            seen_unique_ids.add(unique_id)

    rows = []
    for unique_id, node in all_nodes:
        model_name = node.get("name")
        model_path = node.get("original_file_path")
        schema = node.get("schema")
        materialization = node.get("config", {}).get("materialized")
        resource_enabled = node.get("config", {}).get("enabled", True)
        contract_enforced = bool(node.get("config", {}).get("contract", {}).get("enforced", False))
        column_count = len(node.get("columns", {}))
        tags = ",".join(sorted(node.get("tags", [])))

        meta = {**node.get("meta", {}), **node.get("config", {}).get("meta", {})}
        owner = meta.get("owner")
        if isinstance(owner, dict):
            owner = owner.get("email") or owner.get("name")
        owner_str = str(owner) if owner else ""

        servingdb_sync = bool(meta.get("servingdb_sync", False))
        child_count = len(child_map.get(unique_id, []))
        parent_count = len(node.get("depends_on", {}).get("nodes", []))
        access = node.get("access", "protected")

        is_disabled = resource_enabled is False
        is_deprecated = "deprecated" in (node.get("tags") or [])
        overlay_fields = apply_overlay_and_deprecation_defaults(
            model_name,
            deprecation_date=meta.get("deprecation_date", "") or "",
            deprecation_ticket=meta.get("deprecation_ticket", "") or "",
            is_disabled=is_disabled,
            is_deprecated=is_deprecated,
        )

        rows.append({
            "model_name": model_name,
            "unique_id": unique_id,
            "model_path": model_path,
            "schema": schema,
            "materialization": materialization,
            "resource_enabled": resource_enabled,
            "contract_enforced": contract_enforced,
            "column_count": column_count,
            "tags": tags,
            "owner": owner_str,
            "servingdb_sync": servingdb_sync,
            "child_count": child_count,
            "parent_count": parent_count,
            "access": access,
            **overlay_fields,
        })

    return sorted(rows, key=lambda r: r["model_name"])


def generate_from_fallback() -> list[dict[str, Any]]:
    """Fallback: Generate ledger rows by walking models/**/*.sql and YAML."""
    yaml_configs = load_yaml_configs()
    rows = []

    for sql_file in sorted(REPO_ROOT.glob("models/**/*.sql")):
        model_name = sql_file.stem
        model_path = str(sql_file.relative_to(REPO_ROOT))
        unique_id = f"model.healthcare_analytics.{model_name}"

        sql_content = sql_file.read_text(encoding="utf-8")
        sql_config = parse_sql_config(sql_content)
        yaml_config = yaml_configs.get(model_name, {})

        # Merge configs: SQL overrides YAML, which overrides defaults
        schema = sql_config.get("schema") or yaml_config.get("config", {}).get("schema") or infer_schema(sql_file)
        materialization = sql_config.get("materialized") or yaml_config.get("config", {}).get("materialized") or infer_materialization(sql_file, schema)
        resource_enabled = sql_config.get("enabled", yaml_config.get("config", {}).get("enabled", True))

        contract_enforced = bool(
            sql_config.get("contract", {}).get("enforced", False) or
            yaml_config.get("config", {}).get("contract", {}).get("enforced", False)
        )

        column_count = len(yaml_config.get("columns", []))

        tags_set = set(sql_config.get("tags", [])) | set(yaml_config.get("tags", []))
        tags = ",".join(sorted(tags_set))

        meta = {**yaml_config.get("meta", {}), **sql_config.get("meta", {})}
        owner = meta.get("owner")
        if isinstance(owner, dict):
            owner = owner.get("email") or owner.get("name")
        owner_str = str(owner) if owner else ""

        servingdb_sync = bool(meta.get("servingdb_sync", False))
        access = sql_config.get("access") or yaml_config.get("access") or "protected"

        # In fallback mode, we don't resolve child/parent counts easily, so default them to 0
        child_count = 0
        parent_count = 0

        is_disabled = resource_enabled is False
        is_deprecated = "deprecated" in tags_set
        overlay_fields = apply_overlay_and_deprecation_defaults(
            model_name,
            deprecation_date=meta.get("deprecation_date", "") or "",
            deprecation_ticket=meta.get("deprecation_ticket", "") or "",
            is_disabled=is_disabled,
            is_deprecated=is_deprecated,
        )

        rows.append({
            "model_name": model_name,
            "unique_id": unique_id,
            "model_path": model_path,
            "schema": schema,
            "materialization": materialization,
            "resource_enabled": resource_enabled,
            "contract_enforced": contract_enforced,
            "column_count": column_count,
            "tags": tags,
            "owner": owner_str,
            "servingdb_sync": servingdb_sync,
            "child_count": child_count,
            "parent_count": parent_count,
            "access": access,
            **overlay_fields,
        })

    return sorted(rows, key=lambda r: r["model_name"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate dbt contract consolidation ledger.")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST, help="Path to manifest.json")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER, help="Path to output ledger CSV")
    parser.add_argument("--confirm", action="store_true", help="Confirm writing the ledger CSV")
    args = parser.parse_args()

    if args.manifest.exists():
        print(f"Generating ledger from manifest: {args.manifest}")
        rows = generate_from_manifest(args.manifest)
    else:
        print("WARNING: target/manifest.json not found! Parse is preferred.")
        print("Falling back to walking models/**/*.sql + YAML...")
        rows = generate_from_fallback()

    # Write CSV
    if args.confirm:
        args.ledger.parent.mkdir(parents=True, exist_ok=True)
        with args.ledger.open("w", newline="", encoding="utf-8") as f:
            if rows:
                writer = csv.DictWriter(f, fieldnames=rows[0].keys())
                writer.writeheader()
                writer.writerows(rows)
        print(f"Successfully wrote {len(rows)} rows to {args.ledger}")
    else:
        print("DRY RUN: `--confirm` was not specified. Preview of what would be written:")
        if rows:
            print(f"Would write {len(rows)} rows to {args.ledger}:")
            # Write CSV representation to stdout
            writer = csv.DictWriter(sys.stdout, fieldnames=rows[0].keys())
            writer.writeheader()
            writer.writerows(rows)
        else:
            print("No rows to write.")
        print("\nDRY RUN complete. Use `--confirm` to write.")
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
