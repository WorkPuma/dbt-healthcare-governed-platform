#!/usr/bin/env python3
"""Audit dbt model YAML test coverage across the healthcare_analytics project.

Usage:
  python3 scripts/audit_model_test_coverage.py
  python3 scripts/audit_model_test_coverage.py --json audit_report.json
"""

from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

import yaml

INCREMENTAL_RE = re.compile(
    r"materialized\s*=\s*['\"]incremental['\"]", re.IGNORECASE
)
ELEMENTARY_RE = re.compile(
    r"elementary\.(volume_anomalies|freshness_anomalies|event_freshness_anomalies)"
)
DBT_UTILS_COMPOUND_RE = re.compile(r"dbt_utils\.unique_combination_of_columns")
DBT_EXPECTATIONS_COMPOUND_RE = re.compile(
    r"dbt_expectations\.expect_compound_columns_to_be_unique"
)
RELATIONSHIPS_RE = re.compile(r"relationships\s*:", re.MULTILINE)


def load_yaml_models(models_dir: Path) -> dict[str, dict]:
    documented: dict[str, dict] = {}
    for yml in models_dir.rglob("*.yml"):
        try:
            text = yml.read_text()
            data = yaml.safe_load(text) or {}
        except yaml.YAMLError:
            continue
        for model in data.get("models", []) or []:
            name = model.get("name")
            if not name:
                continue
            model_tests = model.get("tests") or model.get("data_tests") or []
            col_tests = 0
            for col in model.get("columns", []) or []:
                col_tests += len(col.get("tests") or col.get("data_tests") or [])
            block = yaml.dump(model, default_flow_style=False)
            # Use raw YAML section for relationship counting (dump omits data_tests shape).
            model_section = ""
            if yml.exists():
                raw = yml.read_text()
                m = re.search(
                    rf"(  - name: {re.escape(name)}\n(?:.*?\n)*?)(?=  - name: |\Z)",
                    raw,
                    re.MULTILINE,
                )
                if m:
                    model_section = m.group(1)
            documented[name] = {
                "yaml_file": str(yml.relative_to(models_dir.parent)),
                "model_tests": len(model_tests),
                "column_tests": col_tests,
                "unit_tests": len(model.get("unit_tests") or []),
                "total_tests": len(model_tests)
                + col_tests
                + len(model.get("unit_tests") or []),
                "has_elementary": bool(ELEMENTARY_RE.search(block)),
                "has_dbt_utils_compound": bool(DBT_UTILS_COMPOUND_RE.search(block)),
                "has_dbt_expectations_compound": bool(
                    DBT_EXPECTATIONS_COMPOUND_RE.search(block)
                ),
                "relationships_count": len(
                    RELATIONSHIPS_RE.findall(model_section or block)
                ),
            }
    return documented


def domain_for(path: Path) -> str:
    parts = path.parts
    if "models" not in parts:
        return "other"
    idx = parts.index("models")
    rest = parts[idx + 1 :]
    if not rest:
        return "root"
    if rest[0] == "healthcare" and len(rest) > 1:
        return f"healthcare/{rest[1]}"
    return rest[0]


def scan_incremental_models(models_dir: Path) -> dict[str, bool]:
    result: dict[str, bool] = {}
    for sql in models_dir.rglob("*.sql"):
        try:
            text = sql.read_text()
        except OSError:
            continue
        if INCREMENTAL_RE.search(text):
            result[sql.stem] = True
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", default=".")
    parser.add_argument("--json", help="Write machine-readable report to path")
    args = parser.parse_args()

    root = Path(args.project_root)
    models_dir = root / "models"
    sql_models = {p.stem: p for p in models_dir.rglob("*.sql")}
    documented = load_yaml_models(models_dir)
    incrementals = scan_incremental_models(models_dir)

    no_yaml = sorted(set(sql_models) - set(documented))
    no_tests = sorted(
        n for n, m in documented.items() if m["total_tests"] == 0 and n in sql_models
    )

    incremental_without_elementary = sorted(
        name
        for name in incrementals
        if name in documented and not documented[name]["has_elementary"]
    )
    incremental_no_yaml = sorted(set(incrementals) - set(documented))

    dbt_utils_compound = sorted(
        name for name, m in documented.items() if m["has_dbt_utils_compound"]
    )

    relationships_total = sum(m["relationships_count"] for m in documented.values())

    by_domain: dict[str, dict[str, int]] = defaultdict(
        lambda: {
            "models": 0,
            "no_tests": 0,
            "no_yaml": 0,
            "incremental": 0,
            "incremental_no_elementary": 0,
        }
    )
    for stem, path in sql_models.items():
        dom = domain_for(path)
        by_domain[dom]["models"] += 1
        if stem not in documented:
            by_domain[dom]["no_yaml"] += 1
        elif documented[stem]["total_tests"] == 0:
            by_domain[dom]["no_tests"] += 1
        if stem in incrementals:
            by_domain[dom]["incremental"] += 1
            if stem in documented and not documented[stem]["has_elementary"]:
                by_domain[dom]["incremental_no_elementary"] += 1

    report = {
        "sql_models": len(sql_models),
        "yaml_documented": len(documented),
        "no_yaml_entry": len(no_yaml),
        "no_yaml_tests": len(no_tests),
        "incremental_total": len(incrementals),
        "incremental_without_elementary": len(incremental_without_elementary),
        "incremental_no_yaml": len(incremental_no_yaml),
        "models_with_dbt_utils_compound_grain": len(dbt_utils_compound),
        "relationships_count": relationships_total,
        "domains": dict(sorted(by_domain.items())),
        "gaps": {
            "no_yaml_entry": no_yaml,
            "no_yaml_tests": no_tests,
            "incremental_without_elementary": incremental_without_elementary,
            "incremental_no_yaml": incremental_no_yaml,
            "dbt_utils_compound_grain": dbt_utils_compound,
        },
    }

    print(f"SQL models: {report['sql_models']}")
    print(f"YAML documented: {report['yaml_documented']}")
    print(f"No YAML entry: {report['no_yaml_entry']}")
    print(f"No YAML tests: {report['no_yaml_tests']}")
    print(f"Incremental total: {report['incremental_total']}")
    print(
        f"Incremental without Elementary: {report['incremental_without_elementary']}"
    )
    print(f"dbt_utils compound grain (migrate): {report['models_with_dbt_utils_compound_grain']}")
    print(f"relationships tests: {report['relationships_count']}")
    print("\nDomains with highest no-test counts:")
    ranked = sorted(
        ((d, v["no_tests"], v["models"]) for d, v in by_domain.items()),
        key=lambda x: x[1],
        reverse=True,
    )
    for dom, gap, total in ranked[:12]:
        if gap:
            print(f"  {dom}: {gap}/{total} without tests")

    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2))
        print(f"\nWrote {args.json}")


if __name__ == "__main__":
    main()
