#!/usr/bin/env python3
"""Static lint for dbt test YAML/SQL anti-patterns.

Fails on:
  - Vacuous not_null tests with where: "<same_column> is not null"
  - Vacuous expression_is_true("1=1") on enabled models
  - Documented threshold mismatches vs HAVING count(*) > N (warn)

Usage:
  python3 scripts/check_test_lint.py
  python3 scripts/check_test_lint.py --warn-only
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
EXPR_TRUE = re.compile(
    r"(?:dbt_utils\.)?expression_is_true:[\s\S]*?expression:\s*[\"']1\s*=\s*1[\"']",
    re.IGNORECASE,
)
ALWAYS_TRUE = re.compile(
    r"(?:dbt_utils\.)?expression_is_true:[\s\S]*?expression:\s*[\"']"
    r"(?:true|1\s*=\s*1|0\s*=\s*0)[\"']",
    re.IGNORECASE,
)
HEADER_FAILS = re.compile(
    r"Fails if\s*>\s*(\d+)|fails? when[^\n]*exceeds?\s+(\d+)|ideal is closer to\s+(\d+)",
    re.IGNORECASE,
)
HAVING_GT = re.compile(r"having\s+count\(\*\)\s*>\s*(\d+)", re.IGNORECASE)
WHERE_NOT_NULL = re.compile(r"^(\w+)\s+is\s+not\s+null$", re.IGNORECASE)


def iter_yml(root: Path):
    for p in (root / "models").rglob("*.yml"):
        yield p
    for p in (root / "seeds").rglob("*.yml"):
        yield p


def model_enabled(sql_path: Path | None, yml_model: dict | None = None) -> bool:
    """False when SQL config or YAML config sets enabled=false / enabled: false."""
    if isinstance(yml_model, dict):
        cfg = yml_model.get("config") or {}
        if isinstance(cfg, dict) and cfg.get("enabled") is False:
            return False
        dumped = yaml.dump(yml_model)
        if re.search(r"enabled\s*[=:]\s*false", dumped, re.I):
            return False
    if sql_path is None or not sql_path.exists():
        return True
    text = sql_path.read_text(errors="ignore")
    return not re.search(r"enabled\s*[=:]\s*false", text, re.I)


def _test_entries(node: dict | list | str | None) -> list:
    if node is None:
        return []
    if isinstance(node, list):
        return node
    return []


def find_vacuous_not_null(yml_path: Path, root: Path) -> list[str]:
    """Flag not_null where the filter column equals the tested column."""
    errors: list[str] = []
    try:
        data = yaml.safe_load(yml_path.read_text(errors="ignore")) or {}
    except yaml.YAMLError:
        return errors

    def check_column(owner: str, col_name: str, tests: list) -> None:
        for t in tests:
            if t == "not_null":
                continue
            if not isinstance(t, dict) or "not_null" not in t:
                continue
            cfg = t.get("not_null") or {}
            if not isinstance(cfg, dict):
                continue
            # Fusion nesting: not_null: {config: {where: ...}} or where at top
            where = cfg.get("where")
            if where is None and isinstance(cfg.get("config"), dict):
                where = cfg["config"].get("where")
            if not isinstance(where, str):
                continue
            m = WHERE_NOT_NULL.match(where.strip())
            if m and m.group(1).lower() == col_name.lower():
                errors.append(
                    f"{yml_path.relative_to(root)}: vacuous not_null on "
                    f"{owner}.{col_name} where '{where}'"
                )

    for model in data.get("models") or []:
        name = model.get("name") or "?"
        for col in model.get("columns") or []:
            cname = col.get("name")
            if not cname:
                continue
            tests = _test_entries(col.get("tests") or col.get("data_tests"))
            check_column(name, cname, tests)

    for source in data.get("sources") or []:
        sname = source.get("name") or "?"
        for table in source.get("tables") or []:
            tname = table.get("name") or "?"
            for col in table.get("columns") or []:
                cname = col.get("name")
                if not cname:
                    continue
                tests = _test_entries(col.get("tests") or col.get("data_tests"))
                check_column(f"{sname}.{tname}", cname, tests)

    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--warn-only", action="store_true")
    parser.add_argument("--project-root", type=Path, default=ROOT)
    args = parser.parse_args()
    root = args.project_root

    errors: list[str] = []
    warnings: list[str] = []

    for yml in iter_yml(root):
        errors.extend(find_vacuous_not_null(yml, root))
        text = yml.read_text(errors="ignore")
        if ALWAYS_TRUE.search(text):
            try:
                data = yaml.safe_load(text) or {}
            except yaml.YAMLError:
                data = {}
            for model in data.get("models") or []:
                if not isinstance(model, dict):
                    continue
                name = model.get("name")
                block = yaml.dump(model)
                if not ALWAYS_TRUE.search(block):
                    continue
                sql = None
                for cand in (root / "models").rglob(f"{name}.sql"):
                    sql = cand
                    break
                if model_enabled(sql, model):
                    errors.append(
                        f"{yml.relative_to(root)}: enabled model {name} has "
                        f"vacuous expression_is_true — use enabled=false + deferred meta"
                    )

    for sql in (root / "tests").rglob("*.sql"):
        text = sql.read_text(errors="ignore")
        having = HAVING_GT.search(text)
        if not having:
            continue
        header_nums = []
        for tup in HEADER_FAILS.findall(text):
            for part in tup:
                if part:
                    header_nums.append(int(part))
        thresh = int(having.group(1))
        if header_nums and any(h != thresh for h in header_nums):
            if "Operational baseline" not in text and "recalibrated" not in text.lower():
                warnings.append(
                    f"{sql.relative_to(root)}: header threshold(s) {header_nums} "
                    f"differ from HAVING > {thresh} without operational-baseline note"
                )

    for msg in errors:
        print(f"ERROR: {msg}")
    for msg in warnings:
        print(f"WARN: {msg}")

    if errors and not args.warn_only:
        print(f"\ncheck_test_lint FAILED: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1
    print(f"\ncheck_test_lint OK: {len(errors)} error(s), {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
