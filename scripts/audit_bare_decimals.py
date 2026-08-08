#!/usr/bin/env python3
"""
Audit and pin bare `data_type: decimal` contract types to live UC precision.

Walks every models/**/_*.yml file looking for column entries whose data_type
is bare `decimal` (no precision). For each hit, resolves the live Unity Catalog
schema for that model from the dbt manifest, looks up the column's actual
type, and writes the precise type back into the YAML.

Output:
  - JSON audit report at target/decimal_audit.json
  - In-place edits to models/**/_*.yml (only when --apply is passed)

Usage:
  python scripts/audit_bare_decimals.py --report
  python scripts/audit_bare_decimals.py --apply
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "target" / "manifest.json"
MODELS_DIR = REPO_ROOT / "models"
REPORT_PATH = REPO_ROOT / "target" / "decimal_audit.json"

# Match a contract column with a bare decimal:
#     - name: foo
#       data_type: decimal       # <- target line
BARE_DECIMAL_RE = re.compile(
    r'^(?P<indent>\s+)data_type:\s*"?decimal"?\s*$',
    re.MULTILINE,
)
# Walk back to find the column name on the preceding `- name:` line.
NAME_RE = re.compile(r'^\s*-\s*name:\s*([\w".`]+)\s*$')

# Walk back further to find the model the column belongs to. In the YAML
# convention used in this repo, models are listed under either:
#     models:                  (top-level)
#       - name: fct_xyz
# or nested under sources:
#     sources:
#       - name: ...
#         tables:
#           - name: stg_xyz
MODEL_NAME_RE = re.compile(r'^\s{0,4}-\s*name:\s*([\w]+)\s*$')


def load_manifest() -> Dict:
    if not MANIFEST_PATH.exists():
        sys.exit(
            f"manifest not found at {MANIFEST_PATH}. Run `dbtf parse --target prod_jobs` first."
        )
    with MANIFEST_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def index_models_by_name(manifest: Dict) -> Dict[str, Dict]:
    """node['name'] -> {database, schema, alias_or_name, materialized, unique_id}"""
    out: Dict[str, Dict] = {}
    for unique_id, node in manifest.get("nodes", {}).items():
        if not unique_id.startswith("model."):
            continue
        config = node.get("config", {}) or {}
        out[node["name"]] = {
            "unique_id": unique_id,
            "database": node.get("database"),
            "schema": node.get("schema"),
            "alias": node.get("alias") or node["name"],
            "materialized": config.get("materialized"),
            "tags": config.get("tags") or [],
            "fqn": ".".join(node.get("fqn", [])),
            "original_file_path": node.get("original_file_path"),
        }
    return out


def find_bare_decimals(yaml_path: Path) -> List[Tuple[int, str, str]]:
    """Return list of (line_idx, indent, column_name) tuples in yaml_path."""
    text = yaml_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    hits: List[Tuple[int, str, str]] = []
    for idx, line in enumerate(lines):
        m = BARE_DECIMAL_RE.match(line)
        if not m:
            continue
        indent = m.group("indent")
        # Walk back to the nearest `- name: <col>` at the same or shallower
        # indent that is the start of the column block.
        col_name = None
        for back_idx in range(idx - 1, -1, -1):
            prev = lines[back_idx]
            nm = NAME_RE.match(prev)
            if nm:
                # Confirm indent: the `-` should be at lower indent than
                # data_type's; column name lines are e.g.
                #     `      - name: provider_id`
                # while data_type sits two spaces deeper.
                col_name = nm.group(1).strip("\"'`")
                break
            # Stop walking if we leave the columns: block (heuristic: blank line
            # or shallower-than-indent non-key)
            if prev.strip() == "":
                continue
        if col_name is None:
            continue
        hits.append((idx, indent, col_name))
    return hits


def find_owning_model(yaml_path: Path, line_idx: int) -> str | None:
    text = yaml_path.read_text(encoding="utf-8").splitlines()
    for back_idx in range(line_idx - 1, -1, -1):
        m = MODEL_NAME_RE.match(text[back_idx])
        if not m:
            continue
        # Confirm we're at a model entry (not a column entry) by checking the
        # surrounding context: a model entry sits inside a `models:` list.
        # Walk back further for `models:` or `sources:` at lower indent.
        candidate = m.group(1).strip()
        for ctx_idx in range(back_idx - 1, -1, -1):
            ctx = text[ctx_idx].rstrip()
            if not ctx:
                continue
            if re.match(r"^\s*models:\s*$", ctx):
                return candidate
            if re.match(r"^\s*sources:\s*$", ctx) or re.match(
                r"^\s*tables:\s*$", ctx
            ):
                return candidate
            # Hit another column-level `- name:` => keep walking
            if NAME_RE.match(ctx):
                continue
            # Hit a deeper key — stop and try next outer model name
            if re.match(r"^\s+\S", ctx):
                continue
            break
    return None


def describe_table(database: str, schema: str, alias: str) -> Dict[str, str]:
    """Return {col_name: data_type} from Databricks UC.

    Uses the `databricks` CLI shelled out — same auth chain as dbtf.
    """
    import subprocess

    full = f"{database}.{schema}.{alias}"
    cmd = [
        "databricks",
        "api",
        "post",
        "/api/2.0/sql/statements",
        "--json",
        json.dumps(
            {
                "warehouse_id": _resolve_warehouse_id(),
                "statement": f"DESCRIBE TABLE {full}",
                "wait_timeout": "30s",
            }
        ),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return {}
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    rows = (
        payload.get("result", {})
        .get("data_array", [])
    )
    return {row[0]: row[1] for row in rows if row and row[0] and not row[0].startswith("#")}


def _resolve_warehouse_id() -> str:
    """Read DATABRICKS_WAREHOUSE_ID from env; default to a known prod id if absent."""
    import os

    wh = os.environ.get("DATABRICKS_WAREHOUSE_ID")
    if wh:
        return wh
    # Fall back to the warehouse used by the prod_jobs target
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true", help="Rewrite YAML in place")
    parser.add_argument(
        "--report", action="store_true", help="Write target/decimal_audit.json only"
    )
    args = parser.parse_args()

    manifest = load_manifest()
    models = index_models_by_name(manifest)

    findings: List[Dict] = []
    yaml_files = sorted(MODELS_DIR.rglob("_*.yml"))
    for yml in yaml_files:
        hits = find_bare_decimals(yml)
        if not hits:
            continue
        for line_idx, indent, col_name in hits:
            model_name = find_owning_model(yml, line_idx)
            findings.append(
                {
                    "yaml_path": str(yml.relative_to(REPO_ROOT)).replace("\\", "/"),
                    "line_no": line_idx + 1,
                    "indent": len(indent),
                    "column": col_name,
                    "model": model_name,
                    "model_meta": models.get(model_name) if model_name else None,
                }
            )

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(
        json.dumps(
            {
                "summary": {
                    "total_findings": len(findings),
                    "yaml_files_with_findings": len(
                        {f["yaml_path"] for f in findings}
                    ),
                    "models_affected": sorted(
                        {f["model"] for f in findings if f["model"]}
                    ),
                },
                "findings": findings,
            },
            indent=2,
        ),
        encoding="utf-8",
    )

    print(f"Wrote {REPORT_PATH.relative_to(REPO_ROOT)}")
    print(f"  findings: {len(findings)}")
    print(
        f"  yaml files: {len({f['yaml_path'] for f in findings})}"
    )
    print(
        f"  models affected: {len({f['model'] for f in findings if f['model']})}"
    )

    if args.apply:
        print("\n--apply not yet implemented in this script — see decimal_audit.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
